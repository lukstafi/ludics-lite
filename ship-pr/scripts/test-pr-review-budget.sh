#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's polling budget (ludics-lite#543): the pause an observer
# takes between reads, the quota hold every process on the host shares, and the one observer per
# PR. The 2026-10-04 OCANNL wave exhausted the account's REST quota while approved heads waited
# for hosted macOS runners. Each `merge --wait` re-read every minute, a quota 403 ended it with
# exit 3 and its caller armed another, and recovery took a coordinator-wide hold, one observer per
# issue, and 300 s and 600 s polls. The three fixtures the issue names are the acceptance:
#
#   - a quota or transport failure stays UNKNOWN and never permits a merge, and while the hold
#     stands no command calls GitHub at all;
#   - an observer resumes only after a successful request to the endpoint that failed, read from
#     that endpoint's own headers (never /rate_limit), and a second observer of the PR is refused;
#   - a meaningful failure still ends the wait at once, while an unchanged queued poll prints
#     nothing and backs off toward the cap.
#
# The clock is a file: `date +%s` and `sleep` are suite functions that read and advance it, so the
# hold's end, the probes and the pauses are exact, and nothing here sleeps for real. The fixture
# gh answers every request from that clock: before QUOTA_UNTIL, as GitHub answers an exhausted
# quota (a 403 whose first stderr line says so, and `-i` headers naming the reset); after it, as
# the endpoint.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=test-pr-review-lib.sh
source "$SCRIPT_DIR/test-pr-review-lib.sh"

# One brace group over everything below the preamble (ludics-lite#10, #247; the retry suite says
# why it opens below the sources).
{
test_tmpdir TEST_ROOT budget-test

REPO=example/repo
PR_NUM=7
HEAD_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
BASE_SHA=babababababababababababababababababababa
CALL_LOG="$TEST_ROOT/requests"
SLEEP_LOG="$TEST_ROOT/sleeps"
CLOCK="$TEST_ROOT/clock"
MERGE_LOG="$TEST_ROOT/merge-calls"
T0=$(command date +%s)

CHECKS_SEQ=()
QUOTA_UNTIL=0        # fake epoch before which every request answers quota
QUOTA_RESET=""       # the reset its headers name ("" = the quota's own end)
QUOTA_RESETS=()      # per probe, in order, when a case wants the reset to move
FAIL_502=""          # an endpoint glob that answers 502 (transport)

stub warn_multi_close warn_series_close merge_threads_gate warn_base_drift
warn_multi_close() { :; }
warn_series_close() { :; }
merge_threads_gate() { :; }
warn_base_drift() { :; }

# The clock. `date +%s` is every reader's (the budget's and the gate's); any other form is the
# real date's.
date() {
  if [ "$*" = "+%s" ]; then
    cat "$CLOCK"
  else
    command date "$@"
  fi
}
sleep() {
  printf '%s\n' "$1" >>"$SLEEP_LOG"
  printf '%s' "$(($(cat "$CLOCK") + $1))" >"$CLOCK"
}
now() { cat "$CLOCK"; }

next_check() {
  local counter="$TEST_ROOT/checks.calls" idx
  idx=$(cat "$counter" 2>/dev/null) || idx=0
  printf '%s' "$((idx + 1))" >"$counter"
  [ "$idx" -lt "${#CHECKS_SEQ[@]}" ] || idx=$((${#CHECKS_SEQ[@]} - 1))
  printf '%s' "${CHECKS_SEQ[$idx]}"
}
# The state the gate reads, one word per read: pending, green or red.
check_runs() {
  case "$1" in
  pending) printf '{"check_runs":[{"name":"build","status":"in_progress","conclusion":null,"html_url":"u","check_suite":{"id":1}}]}' ;;
  green) printf '{"check_runs":[{"name":"build","status":"completed","conclusion":"success","html_url":"u","check_suite":{"id":1}}]}' ;;
  red) printf '{"check_runs":[{"name":"build","status":"completed","conclusion":"failure","html_url":"u","check_suite":{"id":1}}]}' ;;
  esac
}
workflow_runs() {
  local status=completed conclusion=success
  case "$1" in
  pending) status=in_progress conclusion=null ;;
  red) conclusion=failure ;;
  esac
  jq -cn --arg s "$status" --arg c "$conclusion" --arg sha "$HEAD_SHA" \
    '{workflow_runs:[{id:101, workflow_id:1, name:"ci", event:"pull_request", head_sha:$sha,
       status:$s, conclusion:(if $c == "null" then null else $c end),
       created_at:"2026-10-04T00:00:00Z"}]}'
}

probe_reset() {
  local counter="$TEST_ROOT/probes" idx
  idx=$(cat "$counter" 2>/dev/null) || idx=0
  printf '%s' "$((idx + 1))" >"$counter"
  if [ "$idx" -lt "${#QUOTA_RESETS[@]}" ]; then
    printf '%s' "${QUOTA_RESETS[$idx]}"
  else
    printf '%s' "${QUOTA_RESET:-$QUOTA_UNTIL}"
  fi
}

gh() {
  local include="" a body state
  if [ "${1:-} ${2:-}" = "pr merge" ]; then
    printf '%s\n' "$*" >>"$MERGE_LOG"
    return 0
  fi
  if [ "${1:-} ${2:-}" = "run view" ]; then
    printf 'run %s\n' "$3" >>"$CALL_LOG"
    if [ "$(now)" -lt "$QUOTA_UNTIL" ]; then
      echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2
      return 1
    fi
    printf 'completed\tsuccess\n'
    return 0
  fi
  for a in "$@"; do case "$a" in -i | --include) include=1 ;; esac; done
  gh_fixture_parse "$@"
  if [ -n "$FAIL_502" ]; then
    # shellcheck disable=SC2254 # a glob on purpose
    case "$FIXTURE_ENDPOINT" in $FAIL_502)
      echo "gh: Bad Gateway (HTTP 502)" >&2
      return 1
      ;;
    esac
  fi
  if [ "$(now)" -lt "$QUOTA_UNTIL" ]; then
    if [ -n "$include" ]; then
      printf 'HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Limit: 5000\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: %s\r\n\r\n{"message":"API rate limit exceeded"}\n' "$(probe_reset)"
      printf 'probe %s\n' "$FIXTURE_ENDPOINT" >>"$CALL_LOG"
    else
      printf 'read %s quota\n' "$FIXTURE_ENDPOINT" >>"$CALL_LOG"
    fi
    echo "gh: API rate limit exceeded for user ID 1. If you reach out to GitHub Support for help, please include the request ID A:B. (HTTP 403)" >&2
    return 1
  fi
  if [ -n "$include" ]; then
    printf 'probe %s ok\n' "$FIXTURE_ENDPOINT" >>"$CALL_LOG"
    printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 4999\r\n\r\n{}\n'
    return 0
  fi
  printf 'read %s\n' "$FIXTURE_ENDPOINT" >>"$CALL_LOG"
  case "$FIXTURE_ENDPOINT" in
  "repos/$REPO/pulls/7")
    body=$(jq -cn --arg sha "$HEAD_SHA" --arg base "$BASE_SHA" \
      '{head:{sha:$sha, ref:"topic"}, base:{sha:$base}, updated_at:"2026-10-04T00:00:00Z",
        merged:false, state:"open", mergeable:true, mergeable_state:"clean"}')
    ;;
  "repos/$REPO/commits/$HEAD_SHA/check-runs?filter=latest&per_page=100")
    state=$(next_check)
    printf '%s' "$state" >"$TEST_ROOT/state"
    body=$(check_runs "$state")
    ;;
  "repos/$REPO/actions/runs?head_sha=$HEAD_SHA&per_page=100")
    body=$(workflow_runs "$(cat "$TEST_ROOT/state")")
    ;;
  "repos/$REPO/actions/runs/101/jobs?per_page=100")
    body='{"jobs":[{"name":"build","status":"in_progress","conclusion":null,"created_at":"2026-10-04T00:00:00Z","completed_at":null}]}'
    ;;
  *) bail "the fixture has no answer for $FIXTURE_ENDPOINT" ;;
  esac
  gh_fixture_answer "$body"
}

reset_fixture() {
  STATE_DIR="$TEST_ROOT/state-dir"
  rm -rf "$STATE_DIR"
  mkdir -p "$STATE_DIR"
  # Assigned, not retuned: on a base without the budget these names mean nothing, and the cases
  # must then fail on what the commands DO, not on a refused retune.
  BUDGET_DIR="$STATE_DIR"
  BUILD_POLL_CAP=600
  REVIEW_POLL_CAP=300
  retune CHECKS_INTERVAL=60 CHECKS_HEARTBEAT=7200 ADVISORY_FROM_ENV=1
  printf '%s' "$T0" >"$CLOCK"
  : >"$CALL_LOG"
  : >"$SLEEP_LOG"
  : >"$MERGE_LOG"
  rm -f "$TEST_ROOT/checks.calls" "$TEST_ROOT/probes" "$TEST_ROOT/state"
  CHECKS_SEQ=(green)
  QUOTA_UNTIL=0
  QUOTA_RESET=""
  QUOTA_RESETS=()
  FAIL_502=""
}

# run <var-prefix> <command...>: runs it in a subshell (the commands exit), keeping stdout, stderr
# and status.
run() {
  local name="$1" rc
  shift
  set +e
  ("$@") >"$TEST_ROOT/$name.out" 2>"$TEST_ROOT/$name.err"
  rc=$?
  set -e
  printf '%s' "$rc" >"$TEST_ROOT/$name.rc"
}
out() { cat "$TEST_ROOT/$1.out"; }
err() { cat "$TEST_ROOT/$1.err"; }
rc() { cat "$TEST_ROOT/$1.rc"; }
requests() { cat "$CALL_LOG"; }

# --- fixture 1: a quota or transport failure stays unknown and never permits a merge ------------

test_a_quota_refusal_is_unknown_and_holds_every_caller() {
  reset_fixture
  QUOTA_UNTIL=$((T0 + 1800))
  run merge1 cmd_merge "$REPO#7"
  assert_eq "$(rc merge1)" 3 "a merge whose gate read was refused on quota is UNKNOWN ($(err merge1))"
  assert_eq "$(cat "$MERGE_LOG")" "" "and it never calls the merge"
  assert_contains "$(err merge1)" "UNKNOWN" "the refusal says the signal is unknown"
  assert_contains "$(requests)" "probe repos/$REPO/pulls/7" \
    "the quota's end is read from the failing endpoint itself"
  assert_not_contains "$(requests)" "rate_limit" "and never from /rate_limit"
  assert_eq "$(cut -f1-2 "$STATE_DIR/quota-hold" 2>/dev/null)" "$((T0 + 1800))	repos/$REPO/pulls/7" \
    "the hold ends where that endpoint's X-RateLimit-Reset says, and names the endpoint"

  # Every later caller on the host, while the hold stands: no call at all, still UNKNOWN.
  : >"$CALL_LOG"
  printf '%s' "$((T0 + 600))" >"$CLOCK"
  run merge2 cmd_merge "$REPO#7"
  assert_eq "$(rc merge2)" 3 "a merge during the hold is UNKNOWN ($(err merge2))"
  assert_eq "$(requests)" "" "and makes no request while the hold stands"
  assert_eq "$(cat "$MERGE_LOG")" "" "and never merges"
  assert_contains "$(err merge2)" "quota hold until" "it says why nothing was read"
  run checks2 cmd_checks "$REPO#7"
  assert_eq "$(rc checks2)" 3 "a single checks read during the hold is UNKNOWN"
  assert_contains "$(out checks2)" "checks: verdict=unknown" "with the unknown trailer"
  assert_eq "$(requests)" "" "and makes no request either"

  # The await of one run: a quota answer about the run is not "no such run" (exit 2) either.
  rm -f "$STATE_DIR/quota-hold"
  : >"$CALL_LOG"
  printf '%s' "$T0" >"$CLOCK"
  BUDGET_DIR=""
  run await cmd_retry run watch "$REPO#55"
  assert_eq "$(rc await)" 3 "a quota refusal of the run read is UNKNOWN, not an invocation error ($(err await))"
  assert_not_contains "$(err await)" "has no run" "and is not reported as a missing run"
}

test_a_transport_failure_is_unknown_and_never_merges() {
  reset_fixture
  FAIL_502="repos/$REPO/commits/*/check-runs*"
  run merge cmd_merge "$REPO#7"
  assert_eq "$(rc merge)" 3 "a gate read that never answered is UNKNOWN ($(err merge))"
  assert_eq "$(cat "$MERGE_LOG")" "" "and it never calls the merge"
  assert_eq "$(cat "$STATE_DIR/quota-hold" 2>/dev/null)" "" "transport sets no quota hold"
}

# --- fixture 2: observers resume from verified endpoint recovery, without duplicates -----------

test_an_observer_resumes_only_after_the_failing_endpoint_answers() {
  local reads
  reset_fixture
  CHECKS_SEQ=(pending green)
  # The quota ends at +1800, but the first probe's headers name +1200: the probe at +1200 still
  # finds it exhausted (naming +1800 now), so the hold is set again from those headers.
  QUOTA_UNTIL=$((T0 + 1800))
  QUOTA_RESETS=($((T0 + 1200)) $((T0 + 1800)))
  run wait cmd_checks "$REPO#7" --wait
  assert_eq "$(rc wait)" 0 "the observer waits the hold out and reads the green ($(err wait))"
  assert_contains "$(out wait)" "green" "the verdict is the head's own"
  reads=$(requests)
  assert_eq "$(printf '%s\n' "$reads" | sed -n 1,4p)" "read repos/$REPO/pulls/7 quota
probe repos/$REPO/pulls/7
probe repos/$REPO/pulls/7
probe repos/$REPO/pulls/7 ok" \
    "after the refusal, nothing but probes of that endpoint until one answers"
  assert_eq "$(printf '%s\n' "$reads" | sed -n 5p)" "read repos/$REPO/pulls/7" \
    "and then the refused read is repeated"
  assert_eq "$(sed -n 1,2p "$SLEEP_LOG" | tr '\n' ' ')" "1200 600 " \
    "it sleeps to each reset its headers named, and calls nothing in between"
  assert_eq "$(err wait | grep -c 'quota hold:')" 2 "one line per hold"
  assert_eq "$(err wait | grep -c 'quota hold lifted')" 1 "and one when the endpoint answers again"
  assert_eq "$(cat "$STATE_DIR/quota-hold" 2>/dev/null)" "" "the hold is gone once it answered"
}

test_a_second_observer_of_the_pr_is_refused() {
  local holder
  reset_fixture
  command sleep 300 &
  holder=$!
  mkdir -p "$STATE_DIR/observers/example~repo#7.build"
  printf '%s\n%s\n' "$holder" "$T0" >"$STATE_DIR/observers/example~repo#7.build/owner"
  run second cmd_checks "$REPO#7" --wait
  kill "$holder" 2>/dev/null || :
  wait "$holder" 2>/dev/null || :
  assert_eq "$(rc second)" 2 "a second build observer of the PR is refused ($(err second))"
  assert_contains "$(err second)" "pid $holder" "naming the one already observing"
  assert_eq "$(requests)" "" "having read nothing"
  # The holder is gone now: its lock is replaced, and a single read never takes one.
  run third cmd_checks "$REPO#7" --wait
  assert_eq "$(rc third)" 0 "a holder that is no longer running is replaced ($(err third))"
  run plain cmd_checks "$REPO#7"
  assert_eq "$(rc plain)" 0 "a plain read is no observer and is never refused"
}

test_one_process_probes_an_ended_hold() {
  local holder
  reset_fixture
  printf '%s\t%s\t%s\t%s\n' "$((T0 - 1))" "repos/$REPO/pulls/7" 600 "its headers" >"$STATE_DIR/quota-hold"
  command sleep 300 &
  holder=$!
  mkdir -p "$STATE_DIR/quota-probe"
  printf '%s\n' "$holder" >"$STATE_DIR/quota-probe/pid"
  run single cmd_checks "$REPO#7"
  kill "$holder" 2>/dev/null || :
  wait "$holder" 2>/dev/null || :
  assert_eq "$(rc single)" 3 "while another process probes the ended hold, a read is UNKNOWN ($(err single))"
  assert_eq "$(requests)" "" "and sends nothing of its own"
  run after cmd_checks "$REPO#7"
  assert_eq "$(rc after)" 0 "once that prober is gone, the next caller probes and proceeds ($(err after))"
  assert_eq "$(requests | sed -n 1p)" "probe repos/$REPO/pulls/7 ok" "probing the held endpoint first"
}

# --- fixture 3: a meaningful failure notifies; an unchanged queued poll does not ---------------

test_a_still_queue_backs_off_and_a_red_still_ends_the_wait() {
  reset_fixture
  CHECKS_SEQ=(pending pending pending pending pending red)
  run wait cmd_checks "$REPO#7" --wait
  assert_eq "$(rc wait)" 1 "a red after a still queue ends the wait at once ($(err wait))"
  assert_contains "$(out wait)" "RED" "and says RED"
  assert_eq "$(tr '\n' ' ' <"$SLEEP_LOG")" "60 120 240 480 600 " \
    "unchanged polls double the pause from the interval up to the build cap"
  assert_eq "$(err wait)" "" "and an unchanged poll prints nothing"
}

test_a_moving_signal_is_read_at_the_interval() {
  reset_fixture
  CHECKS_SEQ=(pending pending green)
  run wait cmd_checks "$REPO#7" --wait
  assert_eq "$(rc wait)" 0 "the green is the verdict ($(err wait))"
  assert_eq "$(tr '\n' ' ' <"$SLEEP_LOG")" "60 120 " "the pause doubles only while nothing moves"
}

test_a_hold_inside_a_wait_is_one_line_and_no_exit() {
  reset_fixture
  CHECKS_SEQ=(pending pending red)
  QUOTA_UNTIL=$((T0 + 100))
  run wait cmd_checks "$REPO#7" --wait
  assert_eq "$(rc wait)" 1 "the wait outlives the hold and ends on the red ($(err wait))"
  assert_eq "$(err wait | grep -c .)" 2 "the hold and its lifting are the only lines on the way"
  assert_eq "$(cat "$MERGE_LOG")" "" "nothing merges from a checks read"
}

run_tests \
  test_a_quota_refusal_is_unknown_and_holds_every_caller \
  test_a_transport_failure_is_unknown_and_never_merges \
  test_an_observer_resumes_only_after_the_failing_endpoint_answers \
  test_a_second_observer_of_the_pr_is_refused \
  test_one_process_probes_an_ended_hold \
  test_a_still_queue_backs_off_and_a_red_still_ends_the_wait \
  test_a_moving_signal_is_read_at_the_interval \
  test_a_hold_inside_a_wait_is_one_line_and_no_exit \
  -- "$@"
exit "$?"
}
