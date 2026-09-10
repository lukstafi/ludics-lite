#!/usr/bin/env bash
# Focused fixture tests for what `pr-review.sh base` says once it has decided a branch is RED:
# WHICH job failed, and WHERE the red started (ludics-lite#73). Those two facts are what an owner
# of a red main needs before anything else, and until this suite existed the command answered
# neither — it named the workflow and the newest failing run, and `.github/workflows/base-watch.yml`
# would have filed an issue saying "skill scripts failed", which is the part everybody already
# knows.
#
# The facts are DECORATION on a verdict already reached, and that is the property most of these
# cases pin. The streak walk may not claim a first red commit the run window does not support (a
# window that is red to its end knows only that the red is at least that old); a jobs read that
# fails may not soften the red, and may not quietly report "no failing job" either; and none of it
# may cost a call on a green base, which is the common case every worker pays for at session start.
#
# The window itself is the newest ten push runs per workflow, which is what `base` fetches; the
# suite's fixtures are sized against that, not against a repository's whole history.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=test-pr-review-lib.sh
source "$SCRIPT_DIR/test-pr-review-lib.sh"
test_tmpdir TEST_ROOT base-red-test

REPO=example/repo
BRANCH=main
REQUEST_LOG="$TEST_ROOT/requests"

# Four commits, oldest last, in the order the fixtures list their runs.
SHA_C=cccccccccccccccccccccccccccccccccccccccc
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_0=0000000000000000000000000000000000000000

# --- the fixture transport --------------------------------------------------------------------
# `base` reads the branch tip, the workflow list, then each workflow's runs SEPARATELY (a flat
# page of runs can postdate an infrequent workflow's newest run entirely), and finally — only on
# a red — that run's jobs. So the canned answers are keyed the same way: one per workflow id, one
# per run id. bash 3.2 has no associative arrays; the per-key answers are plain variables reached
# through `eval`, as the other suites' sequence pops are.
TIP=""
WORKFLOWS_JSON=""
JOBS_DEFAULT=""
FAIL_ENDPOINT=""

# runs_json <workflow id> <json array of run overrides>, newest first. Each row defaults to a
# completed push run of a workflow named "ci", with a distinct id and a created_at that decreases
# with the index, so the fixture reads the way the API's own newest-first page does.
runs_json() {
  jq -cn --argjson wf "$1" --argjson runs "$2" \
    '{workflow_runs: [$runs | to_entries[] | .value + {
        workflow_id: $wf,
        id: (.value.id // (1000 * $wf + .key)),
        name: (.value.name // "ci"),
        status: (.value.status // "completed"),
        head_sha: (.value.head_sha // "0000000000000000000000000000000000000000"),
        created_at: (.value.created_at // ("2026-09-10T00:" + ((59 - .key) | tostring) + ":00Z")),
        html_url: (.value.html_url //
                   ("https://example.test/runs/" + ((.value.id // (1000 * $wf + .key)) | tostring)))
      }]}'
}

workflows_json() { jq -cn --argjson wf "$1" '{workflows: $wf}'; }
jobs_json() { jq -cn --argjson jobs "$1" '{jobs: $jobs}'; }

# The canned answer for one key, empty when the case set none: `runs_of 2` reads RUNS_2, `jobs_of
# 3003` reads JOBS_3003 and falls back to JOBS_DEFAULT.
runs_of() { eval "printf '%s' \"\${RUNS_$1:-}\""; }
jobs_of() { eval "printf '%s' \"\${JOBS_$1:-\$JOBS_DEFAULT}\""; }

reset_fixture() {
  local v
  TIP="$SHA_C"
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"}]')
  RUNS_1=$(runs_json 1 '[]')
  # Every RUNS_<n>/JOBS_<n> a previous case set is cleared, or a case that names none would be
  # served the last case's answers and pass for its neighbour's reasons.
  for v in $(set | sed -n 's/^\(RUNS_[0-9][0-9]*\)=.*/\1/p;s/^\(JOBS_[0-9][0-9]*\)=.*/\1/p'); do
    [ "$v" = RUNS_1 ] || unset "$v"
  done
  JOBS_DEFAULT=$(jobs_json '[]')
  FAIL_ENDPOINT=""
  BASE_JOBS_CACHE=""
  BASE_RED_DETAIL=""
  # The wait loop's clocks, for the one case that takes more than a single round.
  retune ABSENT_GRACE=300 CHECKS_INTERVAL=1 CHECKS_HEARTBEAT=600
  : >"$REQUEST_LOG"
}

gh() {
  local response="" rid wid
  gh_fixture_parse "$@"
  if [ -n "$FAIL_ENDPOINT" ]; then
    # A GLOB, deliberately unquoted, so a case can fail the jobs read alone: it is the read whose
    # failure must not touch the verdict, and a pattern that also failed the runs read would
    # prove that from the wrong end.
    # shellcheck disable=SC2254
    case "$FIXTURE_ENDPOINT" in
    $FAIL_ENDPOINT)
      echo "gh: $FIXTURE_ENDPOINT unavailable (HTTP 500)" >&2
      return 1
      ;;
    esac
  fi
  case "$FIXTURE_ENDPOINT" in
  "repos/$REPO/commits/$BRANCH") response=$(jq -cn --arg sha "$TIP" '{sha: $sha}') ;;
  "repos/$REPO/actions/workflows?per_page=100") response="$WORKFLOWS_JSON" ;;
  "repos/$REPO/actions/workflows/"*"/runs?branch=$BRANCH&event=push&per_page=10")
    wid=${FIXTURE_ENDPOINT#*/actions/workflows/}
    wid=${wid%%/*}
    response=$(runs_of "$wid")
    [ -n "$response" ] || response=$(runs_json "$wid" '[]')
    ;;
  "repos/$REPO/actions/runs/"*"/jobs?per_page=100")
    rid=${FIXTURE_ENDPOINT#*/actions/runs/}
    rid=${rid%%/*}
    response=$(jobs_of "$rid")
    ;;
  *) bail "unexpected fixture endpoint: $FIXTURE_ENDPOINT" ;;
  esac
  gh_fixture_answer "$response"
}

run_base() {
  local capture rc
  set +e
  capture=$(cmd_base "$BRANCH" "$@" 2>&1)
  rc=$?
  set -e
  BASE_OUTPUT="$capture"
  BASE_RC="$rc"
}

# A window filled to its end with failures: <n> rows, each red, oldest at SHA_0.
all_red_runs() {
  jq -cn --argjson n "$1" '[range($n) | {conclusion: "failure"}]'
}

# --- the cases --------------------------------------------------------------------------------

# The report an owner is handed: the failing job by name, and the commit the red starts at — not
# the newest failing run, which is only where the red was noticed.
test_red_names_the_failing_job_and_the_first_red_commit() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg b "$SHA_B" --arg a "$SHA_A" \
    '[{conclusion:"failure", head_sha:$c, id:3003},
      {conclusion:"failure", head_sha:$b, id:3002},
      {conclusion:"success", head_sha:$a, id:3001}]')")
  JOBS_3003=$(jobs_json '[{"name":"bash 3.2 suites (macos)","conclusion":"failure"},
                          {"name":"prompt hygiene","conclusion":"success"},
                          {"name":"syntax, shellcheck","conclusion":"cancelled"}]')
  run_base
  assert_eq "$BASE_RC" 1 "a failing workflow on the tip is red"
  assert_contains "$BASE_OUTPUT" "is RED" "the verdict should still headline the red"
  assert_contains "$BASE_OUTPUT" "red since ${SHA_B:0:8}" \
    "the first red commit is where the streak starts, not where it was noticed"
  assert_contains "$BASE_OUTPUT" "2 run(s) back" "how far back the red goes should be counted"
  assert_contains "$BASE_OUTPUT" "the judged run before it was not red" \
    "a streak with a green under it should say the floor is known"
  assert_contains "$BASE_OUTPUT" "failed job(s): bash 3.2 suites (macos) (failure)" \
    "the failing job should be named"
  assert_not_contains "$BASE_OUTPUT" "prompt hygiene" "a job that passed is not a failing job"
  assert_not_contains "$BASE_OUTPUT" "syntax, shellcheck" \
    "a job that was cancelled was not judged, and is not a failing job either"
  # The jobs read is anchored on the run the RED line reports — the newest red — and not on the
  # oldest run of the streak, whose jobs would name a failure two commits stale.
  assert_contains "$(cat "$REQUEST_LOG")" "actions/runs/3003/jobs" \
    "the newest red run's jobs are the ones to read"
  assert_not_contains "$(cat "$REQUEST_LOG")" "actions/runs/3002/jobs" \
    "the first red run's jobs are not what the report is about"
}

# The claim that must be able to fail: with no green under the streak, the first red commit is
# NOT in evidence. Naming the oldest run the page happened to hold would send an owner bisecting
# from the wrong end.
test_a_window_of_only_reds_does_not_name_a_first_red_commit() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(all_red_runs 10)")
  TIP=$SHA_0
  run_base
  assert_eq "$BASE_RC" 1 "a window of failures is red"
  assert_contains "$BASE_OUTPUT" "red for all 10 judged run(s) in the window" \
    "the report should say how much of the window is red"
  assert_contains "$BASE_OUTPUT" "may start further back" \
    "an unbounded streak should say the first red commit is not known"
  assert_not_contains "$BASE_OUTPUT" "the judged run before it was not red" \
    "there is no such run: the bounded claim must not be printed here"
  assert_not_contains "$BASE_OUTPUT" "red since" \
    "'red since' names a first red commit, which this window cannot support"
}

# Nothing that was not JUDGED ends a streak: a cancelled run and a run still going both say
# nothing about the branch's health at their commit, so reading either as the streak's floor
# would report a red that started two commits later than it did.
test_an_unjudged_run_inside_the_streak_does_not_end_it() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg b "$SHA_B" --arg a "$SHA_A" \
    '[{status:"in_progress", conclusion:null, head_sha:$c, id:3010},
      {conclusion:"failure", head_sha:$c, id:3009},
      {conclusion:"cancelled", head_sha:$b, id:3008},
      {conclusion:"failure", head_sha:$b, id:3007},
      {conclusion:"success", head_sha:$a, id:3006}]')")
  run_base
  assert_eq "$BASE_RC" 1 "the newest judged run is red, whatever is running over it"
  assert_contains "$BASE_OUTPUT" "red since ${SHA_B:0:8}" \
    "the streak should reach past the cancelled run to the older red"
  assert_contains "$BASE_OUTPUT" "2 run(s) back" \
    "an unjudged run is not one of the red runs it sits between"
  assert_contains "$(cat "$REQUEST_LOG")" "actions/runs/3009/jobs" \
    "the jobs read is anchored on the newest run that was JUDGED red, not on the one in flight"
}

# The whole reason the jobs read is separate: it is one more call, and a call can fail. What it
# may not do is soften an established red, or come back as a clean bill of health.
test_an_unreadable_jobs_read_is_unknown_not_a_clean_bill() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{conclusion:"failure", head_sha:$c, id:3020}, {conclusion:"success", head_sha:$a}]')")
  FAIL_ENDPOINT="*/jobs?per_page=100"
  run_base
  assert_eq "$BASE_RC" 1 "a jobs read that failed must not turn an established red into transport"
  assert_contains "$BASE_OUTPUT" "is RED" "the red should still headline"
  assert_contains "$BASE_OUTPUT" "which job failed is UNKNOWN" \
    "a failed read should say what is unknown"
  assert_not_contains "$BASE_OUTPUT" "failed job(s)" "no job may be named off a read that failed"
  assert_not_contains "$BASE_OUTPUT" "no job in that run concluded red" \
    "an unread jobs list is not an empty one"
  # The first red commit comes from rows already in hand, so it survives the failed call.
  assert_contains "$BASE_OUTPUT" "red since ${SHA_C:0:8}" \
    "the streak walk needs no call of its own and should still report"
}

# A run can conclude red with no red job — startup_failure, or a matrix that could not expand.
# The honest line names that; an empty list would read as "nothing failed".
test_a_red_run_with_no_red_job_says_so() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{conclusion:"startup_failure", head_sha:$c, id:3030}, {conclusion:"success", head_sha:$a}]')")
  JOBS_3030=$(jobs_json '[{"name":"prompt hygiene","conclusion":"success"}]')
  run_base
  assert_eq "$BASE_RC" 1 "startup_failure is red"
  assert_contains "$BASE_OUTPUT" "no job in that run concluded red" \
    "a red run whose jobs are not red should say so rather than print an empty list"
  assert_not_contains "$BASE_OUTPUT" "failed job(s)" "there is no failing job to name"
}

# The negative control on the cost: `base` runs at every session start, and the extra call must
# be on the red path only.
test_a_green_base_asks_for_no_jobs() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" '[{conclusion:"success", head_sha:$c}]')")
  run_base
  assert_eq "$BASE_RC" 0 "a green tip is green"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green" "the green headline is unchanged"
  assert_not_contains "$(cat "$REQUEST_LOG")" "/jobs" \
    "a green base must not spend a call on which job failed"
  assert_not_contains "$BASE_OUTPUT" "red since" "nothing is red here"
}

# Two workflow FILES can share a display name. The fold groups by workflow id for that reason, and
# the streak walk has to select the same way: keyed by name, the second workflow's history would
# be read off the first's rows, and its report would name the wrong commit and the wrong run.
test_two_workflows_sharing_a_name_keep_their_streaks_apart() {
  reset_fixture
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"ci"}]')
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{conclusion:"failure", head_sha:$c, id:11}, {conclusion:"success", head_sha:$a, id:10}]')")
  RUNS_2=$(runs_json 2 "$(jq -cn --arg c "$SHA_C" --arg b "$SHA_B" --arg a "$SHA_A" \
    '[{conclusion:"failure", head_sha:$c, id:21},
      {conclusion:"failure", head_sha:$b, id:20},
      {conclusion:"failure", head_sha:$a, id:19}]')")
  JOBS_11=$(jobs_json '[{"name":"lint","conclusion":"failure"}]')
  JOBS_21=$(jobs_json '[{"name":"fixtures","conclusion":"failure"}]')
  run_base
  assert_eq "$BASE_RC" 1 "both workflows are red"
  assert_contains "$BASE_OUTPUT" "red since ${SHA_C:0:8}" \
    "the workflow with a green under its one failure starts its red at the tip"
  assert_contains "$BASE_OUTPUT" "1 run(s) back" "that streak is one run long"
  assert_contains "$BASE_OUTPUT" "red for all 3 judged run(s) in the window" \
    "the other workflow's own window is red to its end"
  assert_contains "$BASE_OUTPUT" "failed job(s): lint (failure)" "each workflow's jobs are its own"
  assert_contains "$BASE_OUTPUT" "failed job(s): fixtures (failure)" \
    "the second workflow's jobs must not be read off the first's run"
}

# `base --wait` re-reads and re-folds every round, so the jobs read is one call per round per red
# workflow unless it is remembered. It was not, for one round of review: the caller took the
# detail through a command substitution, and every cache record the function wrote died with that
# subshell — a cache that could never hit, which is invisible except in the call count.
test_a_standing_red_is_read_once_across_wait_rounds() {
  reset_fixture
  # The shape that keeps a wait going: the tip is still being judged, and the red standing behind
  # it belongs to an older commit, so nothing breaks the loop early.
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg b "$SHA_B" --arg a "$SHA_A" \
    '[{status:"in_progress", conclusion:null, head_sha:$c, id:3041},
      {conclusion:"failure", head_sha:$b, id:3040},
      {conclusion:"success", head_sha:$a, id:3039}]')")
  JOBS_3040=$(jobs_json '[{"name":"fixtures (macos)","conclusion":"failure"}]')
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a wait that ends with the tip unjudged is no verdict"
  # Two reads of the runs feed prove the loop really went round more than once, which is what
  # makes the single jobs read below evidence of anything.
  local rounds
  rounds=$(grep -c "actions/workflows/1/runs" "$REQUEST_LOG")
  [ "$rounds" -ge 2 ] || bail "the wait should have polled more than once (got $rounds rounds)"
  assert_eq "$(grep -c "actions/runs/3040/jobs" "$REQUEST_LOG")" 1 \
    "the standing red's jobs should be read once, not once per round"
  assert_contains "$BASE_OUTPUT" "failed job(s): fixtures (macos) (failure)" \
    "the remembered line should still be printed on the rounds that did not read"
}

tests=(
  test_red_names_the_failing_job_and_the_first_red_commit
  test_a_window_of_only_reds_does_not_name_a_first_red_commit
  test_an_unjudged_run_inside_the_streak_does_not_end_it
  test_an_unreadable_jobs_read_is_unknown_not_a_clean_bill
  test_a_red_run_with_no_red_job_says_so
  test_a_green_base_asks_for_no_jobs
  test_two_workflows_sharing_a_name_keep_their_streaks_apart
  test_a_standing_red_is_read_once_across_wait_rounds
)

run_tests "${tests[@]}"
