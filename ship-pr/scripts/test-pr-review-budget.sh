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
PROBE_ANSWERS=""     # nonempty: a probe answers even during the quota (a secondary limit on the
                     # refused operation, which the probe's cheaper request does not meet)
PROBE_HOOK=""        # run as a probe answers: what lands meanwhile, e.g. another refusal's hold
REPO_VIEW_QUOTA=""   # nonempty: `gh repo view` is refused on quota
RUN_STATUSES=()      # the run await's reads, in order ("" = completed at once)
GRAPHQL_PROBE=""     # how GraphQL's probe answers: "" (200, quota left), exhausted (a 200 with
                     # Remaining 0), secondary (a 200 whose body says so, no header)

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
  if [ "${1:-} ${2:-}" = "repo view" ]; then
    printf 'repo view\n' >>"$CALL_LOG"
    if [ -n "$REPO_VIEW_QUOTA" ]; then
      echo "GraphQL: API rate limit exceeded for user ID 1." >&2
      return 1
    fi
    printf '%s\n' "$REPO"
    return 0
  fi
  if [ "${1:-} ${2:-}" = "run view" ]; then
    printf 'run %s\n' "$3" >>"$CALL_LOG"
    if [ "$(now)" -lt "$QUOTA_UNTIL" ]; then
      echo "gh: API rate limit exceeded for user ID 1. (HTTP 403)" >&2
      return 1
    fi
    if [ "${#RUN_STATUSES[@]}" -gt 0 ]; then
      a=$(cat "$TEST_ROOT/runs.calls" 2>/dev/null) || a=0
      printf '%s' "$((a + 1))" >"$TEST_ROOT/runs.calls"
      [ "$a" -lt "${#RUN_STATUSES[@]}" ] || a=$((${#RUN_STATUSES[@]} - 1))
      case "${RUN_STATUSES[$a]}" in
      completed) printf 'completed\tsuccess\n' ;;
      *) printf '%s\tpending\n' "${RUN_STATUSES[$a]}" ;;
      esac
      return 0
    fi
    printf 'completed\tsuccess\n'
    return 0
  fi
  local host="" next=""
  for a in "$@"; do
    [ -z "$next" ] || { host="$a" next=""; }
    case "$a" in -i | --include) include=1 ;; --hostname) next=1 ;; esac
  done
  # A probe names github.com itself, whatever GH_HOST says.
  [ -z "$include" ] || [ "$host" = github.com ] || printf 'probe to %s\n' "${host:-GH_HOST}" >>"$CALL_LOG"
  gh_fixture_parse "$@"
  if [ -n "$FAIL_502" ]; then
    # shellcheck disable=SC2254 # a glob on purpose
    case "$FIXTURE_ENDPOINT" in $FAIL_502)
      echo "gh: Bad Gateway (HTTP 502)" >&2
      return 1
      ;;
    esac
  fi
  if [ "$(now)" -lt "$QUOTA_UNTIL" ] && { [ -z "$include" ] || [ -z "$PROBE_ANSWERS" ]; }; then
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
    [ -z "$PROBE_HOOK" ] || eval "$PROBE_HOOK"
    case "$FIXTURE_ENDPOINT $GRAPHQL_PROBE" in
    "graphql exhausted")
      printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: %s\r\n\r\n{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded for user ID 1."}]}\n' "$((T0 + 2400))"
      ;;
    "graphql secondary")
      printf 'HTTP/2.0 200 OK\r\n\r\n{"errors":[{"message":"You have exceeded a secondary rate limit."}]}\n'
      ;;
    *) printf 'HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 4999\r\n\r\n{}\n' ;;
    esac
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
  "repos/$REPO/contents/.github/ship-pr-advisory-checks")
    body='^claude$'
    ;;
  "repos/ghe/repo") body='{}' ;;
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
  PROBE_ANSWERS=""
  PROBE_HOOK=""
  GRAPHQL_PROBE=""
  REPO_VIEW_QUOTA=""
  RUN_STATUSES=()
  rm -f "$TEST_ROOT/runs.calls"
  retune ADVISORY_FROM_ENV=1
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
# plant_hold <until> <endpoint> <length>: one hold entry, as a refusal leaves it.
plant_hold() {
  mkdir -p "$STATE_DIR/quota-holds"
  printf '%s\t%s\t%s\n' "$2" "$3" "its headers" >"$STATE_DIR/quota-holds/$1.planted.$RANDOM"
}
# The hold that stands, as every reader sees it: "<until> TAB <endpoint> TAB <length>", or nothing.
standing() { (hold_read && printf '%s\t%s\t%s' "$HOLD_UNTIL" "$HOLD_EP" "$HOLD_LEN") 2>/dev/null || :; }

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
  assert_eq "$(standing | cut -f1-2)" "$((T0 + 1800))	repos/$REPO/pulls/7" \
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
  rm -rf "$STATE_DIR/quota-holds"
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
  assert_eq "$(standing)" "" "transport sets no quota hold"
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
  assert_eq "$(standing)" "" "the hold is gone once it answered"
}

test_a_second_observer_of_the_pr_is_refused() {
  local holder
  reset_fixture
  command sleep 300 &
  holder=$!
  mkdir -p "$STATE_DIR/observers/example~repo#7.build"
  printf '%s\n%s\n' "$holder" "$T0" >"$STATE_DIR/observers/example~repo#7.build/owner"
  run second cmd_checks "$REPO#7" --wait
  assert_eq "$(rc second)" 2 "a second build observer of the PR is refused ($(err second))"
  assert_contains "$(err second)" "pid $holder" "naming the one already observing"
  assert_eq "$(requests)" "" "having read nothing"
  # Refused before the preflight reads too: the repository's advisory list, and merge's body.
  retune ADVISORY_FROM_ENV=
  run second_checks cmd_checks "$REPO#7" --wait
  run second_merge cmd_merge "$REPO#7" --wait
  retune ADVISORY_FROM_ENV=1
  kill "$holder" 2>/dev/null || :
  wait "$holder" 2>/dev/null || :
  assert_eq "$(rc second_checks) $(rc second_merge)" "2 2" \
    "checks --wait and merge --wait are refused alike ($(err second_checks) / $(err second_merge))"
  assert_eq "$(requests)" "" "before any read of their own"
  # The holder is gone now: its lock is replaced, and a single read never takes one.
  run third cmd_checks "$REPO#7" --wait
  assert_eq "$(rc third)" 0 "a holder that is no longer running is replaced ($(err third))"
  run plain cmd_checks "$REPO#7"
  assert_eq "$(rc plain)" 0 "a plain read is no observer and is never refused"
}

test_one_process_probes_an_ended_hold() {
  local holder
  reset_fixture
  plant_hold "$((T0 - 1))" "repos/$REPO/pulls/7" 600
  command sleep 300 &
  holder=$!
  mkdir -p "$STATE_DIR/quota-probe"
  printf '%s\n%s\n' "$holder" "$T0" >"$STATE_DIR/quota-probe/owner"
  run single cmd_checks "$REPO#7"
  kill "$holder" 2>/dev/null || :
  wait "$holder" 2>/dev/null || :
  assert_eq "$(rc single)" 3 "while another process probes the ended hold, a read is UNKNOWN ($(err single))"
  assert_eq "$(requests)" "" "and sends nothing of its own"
  run after cmd_checks "$REPO#7"
  assert_eq "$(rc after)" 0 "once that prober is gone, the next caller probes and proceeds ($(err after))"
  assert_eq "$(requests | sed -n 1p)" "probe repos/$REPO/pulls/7 ok" "probing the held endpoint first"
}

# A secondary limit can refuse the operation and not the probe's cheaper GET. The probe answering
# is then no evidence the operation may go again: the backoff hold is set all the same, and it
# doubles from the last one while the operation keeps being refused.
test_a_probe_that_answers_still_holds_the_refused_operation() {
  reset_fixture
  QUOTA_UNTIL=$((T0 + 7200))
  PROBE_ANSWERS=1
  run first cmd_checks "$REPO#7"
  assert_eq "$(rc first)" 3 "the refused read is UNKNOWN ($(err first))"
  assert_eq "$(standing | cut -f1,3)" "$((T0 + 60))	60" \
    "a minute's hold although the probe answered"
  printf '%s' "$((T0 + 60))" >"$CLOCK"
  : >"$CALL_LOG"
  run second cmd_checks "$REPO#7"
  assert_eq "$(rc second)" 3 "refused again after the lift ($(err second))"
  assert_eq "$(requests | sed -n 1,2p)" "probe repos/$REPO/pulls/7 ok
read repos/$REPO/pulls/7 quota" "the ended hold is probed, lifted, and the read refused again"
  assert_eq "$(standing | cut -f3)" 120 "so the next hold doubles"
}

# Requests in flight when the quota ran out each come back refused, and the last must not cut
# short a longer hold another one set: the hold is only ever extended while it stands.
test_a_later_refusal_never_shortens_the_hold() {
  reset_fixture
  plant_hold "$((T0 + 3600))" graphql 3600
  hold_set "repos/$REPO/pulls/7" "quota $((T0 + 60))"
  assert_eq "$(standing | cut -f1-2)" "$((T0 + 3600))	graphql" \
    "an earlier reset leaves the standing hold as it was"
  hold_set "repos/$REPO/pulls/7" "quota $((T0 + 5400))"
  assert_eq "$(standing | cut -f1-2)" "$((T0 + 5400))	repos/$REPO/pulls/7" \
    "a later one extends it"
}

# A write never waits a hold out: its caller read the write's preconditions just before it, and
# sending it after the hold would act on reads the hold has made stale. A read in the same
# observer does wait.
test_a_write_never_waits_a_hold() {
  reset_fixture
  plant_hold "$((T0 + 600))" "repos/$REPO/pulls/7" 600
  run write eval 'BUDGET_WAIT_UNTIL=$((T0 + 7200)); gh_retry write api -X POST "repos/$REPO/issues/7/comments" -f body=x'
  assert_eq "$(rc write)" 3 "a write during a hold is not sent ($(err write))"
  assert_eq "$(requests)" "" "no request at all"
  assert_eq "$(cat "$SLEEP_LOG")" "" "and no wait"
  run read eval 'BUDGET_WAIT_UNTIL=$((T0 + 7200)); gh_retry read api "repos/$REPO/pulls/7" --jq .head.sha'
  assert_eq "$(rc read)" 0 "a read in an observer waits the hold out ($(err read))"
  assert_eq "$(cat "$SLEEP_LOG")" 600 "for exactly the hold"
}

# A prober that died between taking the lock and writing its owner leaves an ownerless lock. It is
# given a second (a claimant mid-write), then replaced, rather than locking every caller out.
test_an_ownerless_probe_lock_is_recovered() {
  reset_fixture
  plant_hold "$((T0 - 1))" "repos/$REPO/pulls/7" 600
  mkdir -p "$STATE_DIR/quota-probe"
  run single cmd_checks "$REPO#7"
  assert_eq "$(rc single)" 0 "the ownerless lock is replaced and the hold probed ($(err single))"
  assert_eq "$(cat "$SLEEP_LOG")" 1 "after the second a claimant mid-write is owed"
  assert_eq "$(requests | sed -n 1p)" "probe repos/$REPO/pulls/7 ok" "probing the held endpoint first"
}

# The ceiling a hold is waited out within is the wait's own: both run from one timestamp taken
# before the first read, so a hold at the start uses up the wait rather than extending it.
test_a_hold_at_the_start_counts_toward_the_ceiling() {
  reset_fixture
  CHECKS_SEQ=(pending)
  QUOTA_UNTIL=$((T0 + 300))
  run wait cmd_checks "$REPO#7" --wait=600
  assert_eq "$(rc wait)" 4 "a queue still running at the ceiling is no verdict ($(err wait))"
  assert_eq "$(now)" "$((T0 + 600))" "and the ceiling is 600 s from the start, the hold included"
  # ... and from the command's start, not the gate's: a hold met by the preflight read of the
  # repository's advisory list uses the wait up too.
  reset_fixture
  retune ADVISORY_FROM_ENV=
  CHECKS_SEQ=(pending)
  QUOTA_UNTIL=$((T0 + 300))
  run wait cmd_checks "$REPO#7" --wait=600
  assert_eq "$(rc wait)" 4 "the same with the advisory list read first ($(err wait))"
  assert_contains "$(requests | sed -n 1p)" "contents/.github/ship-pr-advisory-checks" "which met the hold"
  assert_eq "$(now)" "$((T0 + 600))" "and the ceiling still runs from the command's start"
}

# `base` resolves a repository from the checkout with `gh repo view`, a call gh_retry never sees,
# so it passes the hold's gate itself. A standing hold is exit 3, never a fall back to the origin
# remote (in a fork that names the fork, not the repository gh resolved); an ended one is probed
# and lifted first, as for any read.
test_resolving_the_repo_passes_the_hold() {
  reset_fixture
  run control repo_from_cwd
  assert_eq "$(requests)" "repo view" "with no hold, gh is asked"
  : >"$CALL_LOG"
  plant_hold "$((T0 + 600))" graphql 600
  run held repo_from_cwd
  assert_eq "$(rc held)" 3 "a standing hold is exit 3 ($(err held))"
  assert_eq "$(out held)" "" "with no repository guessed from the remote"
  assert_eq "$(requests)" "" "and gh is not asked"
  printf '%s' "$((T0 + 600))" >"$CLOCK"
  run ended repo_from_cwd
  assert_eq "$(rc ended) $(out ended)" "0 $REPO" "an ended hold is probed and lifted ($(err ended))"
  assert_eq "$(requests | tr '\n' '|')" "probe graphql ok|repo view|" "the probe first, then gh"
  # gh repo view refused on quota itself: a hold like any other call's, and still no guess.
  reset_fixture
  REPO_VIEW_QUOTA=1
  run refused repo_from_cwd
  assert_eq "$(rc refused)" 3 "a quota refusal of gh repo view is exit 3 ($(err refused))"
  assert_eq "$(out refused)" "" "with no repository guessed from the remote"
  assert_eq "$(standing | cut -f2)" graphql "and it sets the hold, on GraphQL"
}

# Entries for different endpoints end separately and are probed separately: GraphQL and REST have
# separate quotas, so one answering lifts only its own entries, and the gate then probes the next.
test_each_endpoint_is_probed_before_its_hold_lifts() {
  reset_fixture
  plant_hold "$((T0 - 10))" "repos/$REPO/pulls/7" 600
  plant_hold "$((T0 - 1))" graphql 600
  run single cmd_checks "$REPO#7"
  assert_eq "$(rc single)" 0 "both answer, and the read goes out ($(err single))"
  assert_eq "$(requests | sed -n 1,3p | tr '\n' '|')" "probe graphql ok|probe repos/$REPO/pulls/7 ok|read repos/$REPO/pulls/7|" \
    "the latest entry's endpoint first, then the other's, each before its own entries go"
  assert_eq "$(standing)" "" "and nothing stands after"
}

# The run await is an observer too: a run that stays queued backs off toward the build cap.
test_the_run_await_backs_off_on_a_still_run() {
  reset_fixture
  RUN_STATUSES=(queued queued queued queued completed)
  run await cmd_retry run watch "$REPO#55"
  assert_eq "$(rc await)" 0 "the run's green is the verdict ($(err await))"
  assert_eq "$(tr '\n' ' ' <"$SLEEP_LOG")" "60 120 240 480 " "an unchanged status doubles the pause"
}

# The endpoint a `run view` probe addresses: every value-taking option's value is consumed first.
test_a_run_view_probe_finds_the_run_id() {
  assert_eq "$(budget_endpoint run view --json status 123 --repo o/r)" "repos/o/r/actions/runs/123" \
    "--json's value is not the run id"
  assert_eq "$(budget_endpoint run view -R o/r --jq .status --attempt 2 -t x 456)" "repos/o/r/actions/runs/456" \
    "nor --jq's, --attempt's or --template's"
}

# A lock that cannot be made at all (here: its parent is a file) is an error, status 2, at once:
# not a holder to wait on forever.
# Requests in flight when the quota ran out come back refused together. Only one of them probes:
# a refusal while a hold already stands, or while another probe runs, adds its endpoint's backoff
# entry unprobed, for the gate to probe in turn once it has ended.
test_refusals_behind_a_hold_or_a_probe_are_not_probed() {
  local holder
  reset_fixture
  QUOTA_UNTIL=$((T0 + 7200))
  plant_hold "$((T0 + 600))" graphql 600
  budget_quota_hit api "repos/$REPO/pulls/7" 2>/dev/null
  assert_eq "$(requests)" "" "no probe while a hold stands"
  assert_eq "$(cat "$STATE_DIR/quota-holds"/[0-9]* | cut -f1 | sort | tr '\n' ' ')" "graphql repos/$REPO/pulls/7 " \
    "but the endpoint's own entry is added beside the standing one, for its turn"
  reset_fixture
  QUOTA_UNTIL=$((T0 + 7200))
  command sleep 300 &
  holder=$!
  mkdir -p "$STATE_DIR/quota-probe"
  printf '%s\n%s\n' "$holder" "$T0" >"$STATE_DIR/quota-probe/owner"
  budget_quota_hit api "repos/$REPO/pulls/7" 2>/dev/null
  kill "$holder" 2>/dev/null || :
  wait "$holder" 2>/dev/null || :
  assert_eq "$(requests)" "" "no probe while another one runs"
  assert_eq "$(standing | cut -f2)" "repos/$REPO/pulls/7" "and the entry is there all the same"
  # A run view with no repository named anywhere has no endpoint to probe: no hold at all.
  reset_fixture
  QUOTA_UNTIL=$((T0 + 7200))
  (unset GH_REPO; budget_quota_hit run view 123) 2>/dev/null
  assert_eq "$(requests)$(standing)" "" "an endpoint that cannot be told sets nothing"
}

# GH_REPO names a run view's repository when no -R does, and GH_HOST never redirects a probe.
test_a_probe_follows_the_environment_gh_reads() {
  reset_fixture
  assert_eq "$(GH_REPO=o/r budget_endpoint run view 123)" "repos/o/r/actions/runs/123" "GH_REPO names the run's repository"
  assert_eq "$(GH_HOST=ghe.example.com budget_probe "repos/$REPO/pulls/7")" ok "the probe answers"
  assert_not_contains "$(requests)" "probe to" "on github.com, named on the probe itself"
}

# The hold is checked again once the probe lock is held: another refusal can probe and set a hold
# between the first check and the lock, and a second probe then would be the burst again.
test_a_hold_set_before_the_lock_stops_the_probe() {
  reset_fixture
  QUOTA_UNTIL=$((T0 + 7200))
  # The lock is taken by a stand-in that lets the other refusal win the race first. It is defined
  # inside the subshell, at run time, so it replaces the library's for this one call only.
  (
    eval 'lock_take() {
      plant_hold "$((T0 + 600))" graphql 600
      mkdir "$1" && printf "%s\n%s\n" "$$" "$T0" >"$1/owner"
    }'
    budget_quota_hit api "repos/$REPO/pulls/7"
  ) 2>/dev/null
  assert_eq "$(requests)" "" "no probe once a hold stands under the lock"
  assert_eq "$(cat "$STATE_DIR/quota-holds"/[0-9]* | cut -f1 | sort | tr '\n' ' ')" "graphql repos/$REPO/pulls/7 " \
    "the refusal's entry is added unprobed"
}

# GH_HOST names the host of a call that names none, so an Enterprise GH_HOST puts it out of scope,
# unless the call names github.com itself. A job-only run view reads the job.
test_the_scope_and_the_job_read_what_gh_reads() {
  local rc
  rc=0; GH_HOST=ghe.example.com budget_scope api "repos/$REPO/pulls/7" || rc=$?
  assert_eq "$rc" 1 "a GH_HOST naming another host puts a call out of scope"
  rc=0; GH_HOST=ghe.example.com budget_scope api --hostname github.com "repos/$REPO/pulls/7" || rc=$?
  assert_eq "$rc" 0 "unless the call names github.com"
  assert_eq "$(budget_endpoint run view --job 456 --repo o/r)" "repos/o/r/actions/jobs/456" "--job reads the job"
}

test_a_lock_that_cannot_be_made_is_an_error() {
  local rc=0
  reset_fixture
  : >"$STATE_DIR/a-file"
  lock_take "$STATE_DIR/a-file/lock" || rc=$?
  assert_eq "$rc" 2 "an unmakeable lock is status 2"
  assert_eq "$(cat "$SLEEP_LOG")" "" "without waiting"
}

# A refusal can land while an ended hold is being probed (a request already in flight). The lift
# removes only the entries that had ended when the probe started, so the new hold still stands.
test_a_refusal_during_the_probe_survives_the_lift() {
  reset_fixture
  plant_hold "$((T0 - 1))" "repos/$REPO/pulls/7" 600
  PROBE_HOOK='plant_hold "$((T0 + 900))" graphql 900'
  run single cmd_checks "$REPO#7"
  assert_eq "$(rc single)" 3 "the new hold stands after the lift ($(err single))"
  assert_eq "$(requests)" "probe repos/$REPO/pulls/7 ok" "and the read is not sent"
  assert_eq "$(standing | cut -f1-2)" "$((T0 + 900))	graphql" "the new hold is the one standing"
}

# Two processes can judge the same dead lock at once. The reap renames the lock aside and deletes
# it only if its owner is still the one judged, so the lock the first one took meanwhile survives.
test_a_reap_keeps_a_lock_retaken_meanwhile() {
  local live
  reset_fixture
  command sleep 300 &
  live=$!
  mkdir -p "$STATE_DIR/lock"
  printf '%s\n%s\n' "$live" "$T0" >"$STATE_DIR/lock/owner"
  lock_reap "$STATE_DIR/lock" 999999
  assert_eq "$(sed -n 1p "$STATE_DIR/lock/owner" 2>/dev/null)" "$live" "a lock judged by another owner is put back"
  lock_reap "$STATE_DIR/lock" "$live"
  kill "$live" 2>/dev/null || :
  wait "$live" 2>/dev/null || :
  assert_eq "$(ls -A "$STATE_DIR" | grep -c lock || true)" 0 "the judged one is removed, nothing left aside"
}

# A call to another host (`--hostname`, an Enterprise server) is outside the budget: its quota is
# its own, so it sets no github.com hold, and a github.com hold does not stop it.
test_another_host_is_outside_the_budget() {
  reset_fixture
  QUOTA_UNTIL=$((T0 + 600))
  run ghe gh_retry read api --hostname ghe.example.com repos/ghe/repo
  assert_eq "$(rc ghe)" 3 "its quota refusal is still UNKNOWN ($(err ghe))"
  assert_eq "$(standing)" "" "but sets no hold"
  assert_not_contains "$(requests)" "probe" "and probes nothing"
  QUOTA_UNTIL=0
  : >"$CALL_LOG"
  plant_hold "$((T0 + 600))" graphql 600
  run ghe2 gh_retry read api --hostname ghe.example.com repos/ghe/repo
  assert_eq "$(rc ghe2)" 0 "a github.com hold does not stop it ($(err ghe2))"
}

# GraphQL answers an exhausted quota with a 200 (GitHub's GraphQL rate-limit documentation), so the
# probe reads the quota headers, and the body's words, on every status.
test_a_graphql_200_can_still_be_quota() {
  reset_fixture
  GRAPHQL_PROBE=exhausted
  assert_eq "$(budget_probe graphql)" "quota $((T0 + 2400))" "Remaining 0 on a 200 is quota until its reset"
  GRAPHQL_PROBE=secondary
  assert_eq "$(budget_probe graphql)" "quota 0" "a 200 whose body names a secondary limit is quota"
  GRAPHQL_PROBE=""
  assert_eq "$(budget_probe graphql)" ok "a 200 with quota left is the answer"
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
  test_a_probe_that_answers_still_holds_the_refused_operation \
  test_a_later_refusal_never_shortens_the_hold \
  test_a_write_never_waits_a_hold \
  test_an_ownerless_probe_lock_is_recovered \
  test_a_hold_at_the_start_counts_toward_the_ceiling \
  test_resolving_the_repo_passes_the_hold \
  test_a_refusal_during_the_probe_survives_the_lift \
  test_a_reap_keeps_a_lock_retaken_meanwhile \
  test_another_host_is_outside_the_budget \
  test_a_graphql_200_can_still_be_quota \
  test_each_endpoint_is_probed_before_its_hold_lifts \
  test_the_run_await_backs_off_on_a_still_run \
  test_a_run_view_probe_finds_the_run_id \
  test_a_lock_that_cannot_be_made_is_an_error \
  test_refusals_behind_a_hold_or_a_probe_are_not_probed \
  test_a_probe_follows_the_environment_gh_reads \
  test_a_hold_set_before_the_lock_stops_the_probe \
  test_the_scope_and_the_job_read_what_gh_reads \
  test_a_still_queue_backs_off_and_a_red_still_ends_the_wait \
  test_a_moving_signal_is_read_at_the_interval \
  test_a_hold_inside_a_wait_is_one_line_and_no_exit \
  -- "$@"
exit "$?"
}
