#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's build gate, and specifically for the two facts ABSENT
# used to wear at once: "no workflow covers this commit" and "the run for this commit has not
# created its checks yet" (ludics-lite#24). The second one must never leave the gate as exit 0.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
HELPER="$SCRIPT_DIR/pr-review.sh"
TEST_ROOT=$(mktemp -d "/tmp/pr-review-checks-absent-test.XXXXXX") || exit 1
trap 'case "$TEST_ROOT" in /tmp/pr-review-checks-absent-test.*) rm -rf "$TEST_ROOT" ;; esac' EXIT

export SHIP_PR_TEST_SOURCE_ONLY=1
export SHIP_PR_STATE_DIR=off
export SHIP_PR_API_ATTEMPTS=1
export SHIP_PR_API_BACKOFF=0
# shellcheck source=pr-review.sh
source "$HELPER"
# pr-review.sh installs its own EXIT trap. Preserve that cleanup and restore this test's temporary
# root cleanup after sourcing it.
trap 'rm -f "$GH_ERR_FILE"; case "$TEST_ROOT" in /tmp/pr-review-checks-absent-test.*) rm -rf "$TEST_ROOT" ;; esac' EXIT

REPO=example/repo
HEAD_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
REQUEST_LOG="$TEST_ROOT/requests"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (got '$1', expected '$2')"
}

assert_contains() {
  case "$1" in *"$2"*) ;; *) fail "$3 (missing '$2' in: $1)" ;; esac
}

assert_not_contains() {
  case "$1" in *"$2"*) fail "$3 (unexpected '$2' in: $1)" ;; *) ;; esac
}

# --- the fixture transport --------------------------------------------------------------------
# One canned answer per endpoint, each a list so a round can differ from the next: the wait loop
# re-reads, and a fixture that could only answer once could not tell a hold from a settle.
CHECK_RUNS_SEQ=()
RUNS_SEQ=()
COMMIT_AGE=""
PR_UPDATED_AGE=""
FAIL_ENDPOINT=""

check_runs_json() { jq -cn --argjson runs "$1" '{check_runs:$runs}'; }
runs_json() { jq -cn --argjson runs "$1" '{workflow_runs:$runs}'; }
iso_ago() { jq -rn --argjson n "$1" '(now - $n) | todateiso8601'; }

# Pops the next canned answer, and repeats the last one forever after: the round count is the
# behaviour under test, not something each case should have to predict. The round counter lives in
# a FILE because gh_retry runs `gh` inside a command substitution — a variable incremented there
# dies with the subshell, and every round would be served the first answer forever.
next_of() {
  local name="$1" counter="$TEST_ROOT/$1.calls" idx total
  idx=$(cat "$counter" 2>/dev/null) || idx=0
  case "$idx" in '' | *[!0-9]*) idx=0 ;; esac
  printf '%s' "$((idx + 1))" >"$counter"
  eval "total=\${#${name}[@]}"
  [ "$idx" -lt "$total" ] || idx=$((total - 1))
  eval "printf '%s' \"\${${name}[$idx]}\""
}

reset_fixture() {
  CHECK_RUNS_SEQ=("$(check_runs_json '[]')")
  RUNS_SEQ=("$(runs_json '[]')")
  COMMIT_AGE=3600
  PR_UPDATED_AGE=3600
  FAIL_ENDPOINT=""
  rm -f "$TEST_ROOT/CHECK_RUNS_SEQ.calls" "$TEST_ROOT/RUNS_SEQ.calls"
  ABSENT_GRACE=300
  CHECKS_INTERVAL=1
  CHECKS_HEARTBEAT=600
  : >"$REQUEST_LOG"
}

gh() {
  local endpoint="" filter="" response="" arg
  [ "${1:-}" = api ] || fail "fixture received non-api gh call: $*"
  shift
  while [ $# -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
    --jq)
      filter="${1:-}"
      shift || true
      ;;
    -*) ;;
    *) [ -n "$endpoint" ] || endpoint="$arg" ;;
    esac
  done
  printf '%s\n' "$endpoint" >>"$REQUEST_LOG"
  # A GLOB, deliberately unquoted: "repos/o/n/commits/<sha>" is a prefix of the check-runs
  # endpoint, so a substring match could not fail the commit read alone — and a case that failed
  # both reads would pass for the wrong reason.
  if [ -n "$FAIL_ENDPOINT" ]; then
    # shellcheck disable=SC2254
    case "$endpoint" in
    $FAIL_ENDPOINT)
      echo "gh: $endpoint unavailable (HTTP 500)" >&2
      return 1
      ;;
    esac
  fi
  case "$endpoint" in
  "repos/$REPO/pulls/7")
    if [ -n "$PR_UPDATED_AGE" ]; then
      response=$(jq -cn --arg sha "$HEAD_SHA" --arg at "$(iso_ago "$PR_UPDATED_AGE")" \
        '{head:{sha:$sha}, updated_at:$at}')
    else
      response=$(jq -cn --arg sha "$HEAD_SHA" '{head:{sha:$sha}}')
    fi
    ;;
  "repos/$REPO/commits/$HEAD_SHA/check-runs?filter=latest&per_page=100")
    response=$(next_of CHECK_RUNS_SEQ)
    ;;
  "repos/$REPO/actions/runs?head_sha=$HEAD_SHA&per_page=100")
    response=$(next_of RUNS_SEQ)
    ;;
  "repos/$REPO/commits/$HEAD_SHA")
    response=$(jq -cn --arg at "$(iso_ago "$COMMIT_AGE")" '{commit:{committer:{date:$at}}}')
    ;;
  *) fail "unexpected fixture endpoint: $endpoint" ;;
  esac
  if [ -n "$filter" ]; then
    jq -r "$filter" <<<"$response"
  else
    printf '%s\n' "$response"
  fi
}

run_gate() {
  local capture rc
  set +e
  capture=$(gate_checks 7 "${1:-0}" 2>&1)
  rc=$?
  set -e
  GATE_OUTPUT="$capture"
  GATE_RC="$rc"
}

# --- the cases --------------------------------------------------------------------------------

# The issue itself: `checks --wait` armed seconds after a push, `gh run list` showing the run for
# that head in_progress, and the gate answering exit 0 ABSENT.
test_inflight_run_is_not_absent() {
  reset_fixture
  COMMIT_AGE=20
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"in_progress"}]')")
  run_gate
  assert_eq "$GATE_RC" 4 "an in-flight run with no checks yet is no verdict, not absence"
  assert_contains "$GATE_OUTPUT" "NO VERDICT YET" "the in-flight run should headline no verdict"
  assert_contains "$GATE_OUTPUT" "1 workflow run(s) for this head have not finished" \
    "the reason should name the unfinished run"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" "an unfinished run must not print ABSENT"
}

test_queued_run_is_not_absent() {
  reset_fixture
  COMMIT_AGE=99999
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"queued"}]')")
  run_gate
  assert_eq "$GATE_RC" 4 "a queued run is no verdict even long after the push"
  assert_contains "$GATE_OUTPUT" "NO VERDICT YET" "a queued run should headline no verdict"
}

# No run at all, seconds after the push: the creation window, not path filters.
test_fresh_push_without_a_run_waits() {
  reset_fixture
  COMMIT_AGE=30
  run_gate
  assert_eq "$GATE_RC" 4 "a run-less head inside the grace is no verdict"
  assert_contains "$GATE_OUTPUT" "creation grace" "the reason should name the grace"
  assert_contains "$GATE_OUTPUT" "SHIP_PR_BASE_ABSENT_GRACE" "the reason should name the knob"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" "a head inside the grace must not print ABSENT"
}

# Past the grace with no run: this is the verdict the word ABSENT was always meant for.
test_stale_push_without_a_run_is_absent() {
  reset_fixture
  COMMIT_AGE=1800
  run_gate
  assert_eq "$GATE_RC" 0 "no run 30 min after the push is the absence verdict"
  assert_contains "$GATE_OUTPUT" ": ABSENT" "past the grace should print ABSENT"
  assert_contains "$GATE_OUTPUT" "no workflow run exists for this head in the 30m" \
    "the absence should say what was read and how long it waited"
}

test_grace_of_zero_settles_at_once() {
  reset_fixture
  COMMIT_AGE=1
  ABSENT_GRACE=0
  run_gate
  assert_eq "$GATE_RC" 0 "a zero grace is the escape hatch and must settle immediately"
  assert_contains "$GATE_OUTPUT" ": ABSENT" "a zero grace should print ABSENT"
}

# A finished run that left no build check is the path-filter case, and it needs no grace at all.
test_finished_run_without_checks_is_absent() {
  reset_fixture
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"completed","conclusion":"success"}]')")
  run_gate
  assert_eq "$GATE_RC" 0 "a finished run that produced no build check is absence"
  assert_contains "$GATE_OUTPUT" ": ABSENT" "a finished run with no checks should print ABSENT"
  assert_contains "$GATE_OUTPUT" "finished and left no build check behind" \
    "the absence should name the finished run"
}

# The advisory list is the same list in both directions: the review app's own run must not hold a
# build wait open.
test_advisory_run_does_not_hold_the_gate() {
  reset_fixture
  COMMIT_AGE=1800
  RUNS_SEQ=("$(runs_json '[{"name":"claude","status":"in_progress","conclusion":null}]')")
  run_gate
  assert_eq "$GATE_RC" 0 "an in-flight advisory run is not a build signal on the way"
  assert_contains "$GATE_OUTPUT" ": ABSENT" "an advisory-only run should still read as absence"
}

# A failed second read is UNKNOWN, like every other failed read on this path — the one thing it
# must not become is a reassuring exit 0.
test_unreadable_run_list_is_unknown() {
  reset_fixture
  COMMIT_AGE=1800
  FAIL_ENDPOINT="*actions/runs*"
  run_gate
  assert_eq "$GATE_RC" 3 "an unreadable run list is unknown"
  assert_contains "$GATE_OUTPUT" "UNKNOWN" "an unreadable run list should say UNKNOWN"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" "an unread absence must not print ABSENT"
}

test_unreadable_push_time_is_unknown() {
  reset_fixture
  PR_UPDATED_AGE=""
  FAIL_ENDPOINT="repos/$REPO/commits/$HEAD_SHA"
  run_gate
  assert_eq "$GATE_RC" 3 "with both clocks gone the absence is undecidable"
  assert_contains "$GATE_OUTPUT" "UNKNOWN" "an unreadable push time should say UNKNOWN"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" "an undecidable absence must not print ABSENT"
}

# The second read is only for absences: a commit that HAS checks is judged by them alone.
test_green_never_consults_the_run_list() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"ci","conclusion":"success","html_url":"u"}]')")
  run_gate
  assert_eq "$GATE_RC" 0 "green checks are green"
  assert_contains "$GATE_OUTPUT" "green — 1 build checks passed" "green should headline green"
  assert_not_contains "$(cat "$REQUEST_LOG")" "actions/runs" \
    "a commit with checks should not need the run list"
}

test_red_never_consults_the_run_list() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"ci","conclusion":"failure","html_url":"u"}]')")
  run_gate
  assert_eq "$GATE_RC" 1 "a failed check is red"
  assert_contains "$GATE_OUTPUT" "RED" "red should headline RED"
  assert_not_contains "$(cat "$REQUEST_LOG")" "actions/runs" \
    "a red commit should not need the run list"
}

# --wait must hold through the not-created-yet window and then read the verdict that appears,
# which is the whole point of backgrounding it.
test_wait_holds_until_the_checks_appear() {
  reset_fixture
  COMMIT_AGE=10
  CHECKS_HEARTBEAT=0
  CHECK_RUNS_SEQ=(
    "$(check_runs_json '[]')"
    "$(check_runs_json '[]')"
    "$(check_runs_json '[{"name":"ci","conclusion":"failure","html_url":"u"}]')"
  )
  RUNS_SEQ=(
    "$(runs_json '[]')"
    "$(runs_json '[{"name":"ci","status":"in_progress"}]')"
  )
  run_gate 30
  assert_eq "$GATE_RC" 1 "the wait should end on the red that appeared"
  assert_contains "$GATE_OUTPUT" "RED" "the verdict that appeared should be reported"
  assert_contains "$GATE_OUTPUT" "still waiting" "the hold should heartbeat"
  assert_contains "$GATE_OUTPUT" "creation grace" \
    "the heartbeat should say what it is waiting for, not '0 check(s) running'"
  assert_not_contains "$GATE_OUTPUT" "0 check(s) running" \
    "an unstarted hold has no running checks to count"
}

# The ceiling is not a pass: a wait that runs out with the run still queued exits 4, so the merge
# gate refuses instead of merging unread.
test_wait_ceiling_with_a_queued_run_is_no_verdict() {
  reset_fixture
  COMMIT_AGE=30
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"queued"}]')")
  run_gate 2
  assert_eq "$GATE_RC" 4 "a spent ceiling over a queued run is no verdict"
  assert_contains "$GATE_OUTPUT" "NO VERDICT YET" "the ceiling should report no verdict"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" "the ceiling must not turn a queued run into absence"
}

# Round 1 of the review of ludics-lite#38, P1: a run cancelled while still QUEUED reports
# `completed` with no check runs behind it. Stopped is not judged anywhere else in this file, and
# it is not absence here.
test_cancelled_run_is_not_absent() {
  local concl
  for concl in cancelled stale action_required; do
    reset_fixture
    RUNS_SEQ=("$(runs_json "$(jq -cn --arg c "$concl" \
      '[{name:"ci", status:"completed", conclusion:$c}]')")")
    run_gate
    assert_eq "$GATE_RC" 4 "a $concl run left no verdict, and no absence either"
    assert_contains "$GATE_OUTPUT" "stopped-not-judged" "the reason should name what happened"
    assert_contains "$GATE_OUTPUT" "re-run the workflow" "the remedy should be named"
    assert_not_contains "$GATE_OUTPUT" ": ABSENT" "a $concl run must not print ABSENT"
  done
}

# Round 1 of the same review, P1: one finished workflow is evidence about one workflow. A repo
# where A finishes with every job skipped while B's run row is not created yet must still hold.
test_one_finished_run_does_not_bypass_the_grace() {
  reset_fixture
  COMMIT_AGE=30
  PR_UPDATED_AGE=30
  RUNS_SEQ=("$(runs_json '[{"name":"a","status":"completed","conclusion":"skipped"}]')")
  run_gate
  assert_eq "$GATE_RC" 4 "a finished run inside the grace does not settle the whole head"
  assert_contains "$GATE_OUTPUT" "run-creation grace" "the hold should name the grace"
  assert_contains "$GATE_OUTPUT" "1 workflow run(s) for this head finished" \
    "the hold should still report what was seen"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" \
    "a finished run inside the grace must not print ABSENT"
}

# Round 1 of the same review, P1: an old commit pushed just now has a committer date older than any
# grace. The PR's updated_at moves with the push, so the fresher of the two clocks wins.
test_old_commit_freshly_pushed_waits() {
  reset_fixture
  COMMIT_AGE=86400
  PR_UPDATED_AGE=20
  run_gate
  assert_eq "$GATE_RC" 4 "a day-old commit pushed 20s ago is inside the creation window"
  assert_contains "$GATE_OUTPUT" "at most 20s" "the fresher clock should be the one reported"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" \
    "a freshly pushed old commit must not print ABSENT"
}

# ... and the converse: a stale PR whose head really has no CI still reaches its verdict.
test_old_commit_and_quiet_pr_is_absent() {
  reset_fixture
  COMMIT_AGE=86400
  PR_UPDATED_AGE=7200
  run_gate
  assert_eq "$GATE_RC" 0 "an old head on a quiet PR is the absence verdict"
  assert_contains "$GATE_OUTPUT" ": ABSENT" "a quiet old head should print ABSENT"
}

# The push clock has two sources, and only losing BOTH is unknown.
test_unreadable_commit_still_decides_on_the_pr_clock() {
  reset_fixture
  PR_UPDATED_AGE=20
  FAIL_ENDPOINT="repos/$REPO/commits/$HEAD_SHA"
  run_gate
  assert_eq "$GATE_RC" 4 "the PR's own clock is enough to hold"
  assert_contains "$GATE_OUTPUT" "run-creation grace" "the hold should name the grace"
}

tests=(
  test_inflight_run_is_not_absent
  test_queued_run_is_not_absent
  test_fresh_push_without_a_run_waits
  test_stale_push_without_a_run_is_absent
  test_grace_of_zero_settles_at_once
  test_finished_run_without_checks_is_absent
  test_advisory_run_does_not_hold_the_gate
  test_unreadable_run_list_is_unknown
  test_unreadable_push_time_is_unknown
  test_cancelled_run_is_not_absent
  test_one_finished_run_does_not_bypass_the_grace
  test_old_commit_freshly_pushed_waits
  test_old_commit_and_quiet_pr_is_absent
  test_unreadable_commit_still_decides_on_the_pr_clock
  test_green_never_consults_the_run_list
  test_red_never_consults_the_run_list
  test_wait_holds_until_the_checks_appear
  test_wait_ceiling_with_a_queued_run_is_no_verdict
)

for test_name in "${tests[@]}"; do
  "$test_name"
  echo "PASS: $test_name"
done
