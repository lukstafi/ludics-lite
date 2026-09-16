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
# What the fixture `gh` records as PAGINATED: a commit's files are served 30 to a page, so the
# read that walks them has to ask for every one.
PAGINATE_LOG="$TEST_ROOT/paginated"

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
# The settle path's three reads (ludics-lite#156): the workflow FILE (its path, then its body at
# the tip, served raw as the library asks for it) and the compare from the judged commit to the
# tip. One body and one file list for every workflow here: the cases that care which compare was
# asked for read $REQUEST_LOG, which records the endpoint.
WORKFLOW_PATH=""
WORKFLOW_YAML=""
# The range the tip adds over the judged commit, and what each of its commits changed: the
# recognition reads the commits ONE BY ONE, because a path filter is evaluated per push and the
# cumulative diff of a range can hide a push that touched source. COMPARE_TOTAL is the compare's
# own total_commits, which a case moves on its own to stand for a range too long or a list the
# answer truncated.
# The commits the tip adds over the judged commit, oldest first, each the first parent of the next
# — the shape a linear range has. COMPARE_PARENTS overrides the first parent of each of them, for
# the cases about a merge reached through its SECOND parent; COMPARE_BEHIND makes the judged commit
# a fork rather than an ancestor, as a force-push leaves it.
COMPARE_COMMITS=""
COMPARE_PARENTS=""
COMPARE_TOTAL=""
COMPARE_BEHIND=""
FILES_DEFAULT=""
# The delay one case needs: an API round takes time, and the grace has to be measured from when
# the tip was first READ, not from when that round's last answer came back. The marker file is
# what makes it happen once — every read is a command substitution, where a cleared variable
# would not survive.
FIRST_READ_DELAY=""

# A ci workflow as the fleet's repositories write one: docs are the paths-ignore.
DOCS_IGNORED_YAML='name: ci
on:
  push:
    branches: [main]
    paths-ignore:
      - "docs/**"
      - "**.md"
jobs:
  build:
    runs-on: ubuntu-latest
'

# The tip read answers TIP until TIP_SWITCH_AFTER reads have gone by, and TIP_NEXT after that: how
# a case moves the branch between the round's tip read and the settle's re-confirm of it. The
# counter lives in a FILE because every one of those reads happens inside a command substitution,
# where an incremented variable would die with the subshell.
TIP_SWITCH_AFTER=""
TIP_NEXT=""
TIP_READS="$TEST_ROOT/tip-reads"

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
# One commit's changed files: keyed by the first character of its sha, which is what tells this
# suite's commits apart (SHA_A, SHA_B, SHA_C, SHA_0 are runs of one character), falling back to
# FILES_DEFAULT for a case that gives every commit the same diff.
files_of() { eval "printf '%s' \"\${FILES_${1:0:1}:-\$FILES_DEFAULT}\""; }

reset_fixture() {
  local v
  TIP="$SHA_C"
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"}]')
  RUNS_1=$(runs_json 1 '[]')
  # Every RUNS_<n>/JOBS_<n> a previous case set is cleared, or a case that names none would be
  # served the last case's answers and pass for its neighbour's reasons.
  # Shell values can contain non-text bytes; only the ASCII variable names are parsed.
  for v in $(set | LC_ALL=C sed -n 's/^\(RUNS_[0-9][0-9]*\)=.*/\1/p;s/^\(JOBS_[0-9][0-9]*\)=.*/\1/p'); do
    [ "$v" = RUNS_1 ] || unset "$v"
  done
  JOBS_DEFAULT=$(jobs_json '[]')
  FAIL_ENDPOINT=""
  BASE_JOBS_CACHE=""
  BASE_RED_DETAIL=""
  BASE_IGNORE_CACHE=""
  WORKFLOW_PATH=".github/workflows/ci.yml"
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  COMPARE_COMMITS=$(jq -cn --arg c "$SHA_C" '[$c]')
  COMPARE_PARENTS=""
  COMPARE_TOTAL=""
  COMPARE_BEHIND=""
  FILES_DEFAULT='[]'
  FIRST_READ_DELAY=""
  for v in $(set | LC_ALL=C sed -n 's/^\(FILES_[0-9a-z]\)=.*/\1/p'); do unset "$v"; done
  rm -f "$TEST_ROOT/delayed"
  : >"$PAGINATE_LOG"
  TIP_SWITCH_AFTER=""
  TIP_NEXT=""
  : >"$TIP_READS"
  # The wait loop's clocks, for the one case that takes more than a single round.
  retune ABSENT_GRACE=300 CHECKS_INTERVAL=1 CHECKS_HEARTBEAT=600
  : >"$REQUEST_LOG"
}

gh() {
  local response="" rid wid reads sha base
  if [ -n "$FIRST_READ_DELAY" ] && [ ! -e "$TEST_ROOT/delayed" ]; then
    : >"$TEST_ROOT/delayed"
    sleep "$FIRST_READ_DELAY"
  fi
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
  "repos/$REPO/commits/$BRANCH")
    reads=$(($(wc -l <"$TIP_READS") + 1))
    printf 'x\n' >>"$TIP_READS"
    if [ -n "$TIP_SWITCH_AFTER" ] && [ "$reads" -gt "$TIP_SWITCH_AFTER" ]; then
      response=$(jq -cn --arg sha "$TIP_NEXT" '{sha: $sha}')
    else
      response=$(jq -cn --arg sha "$TIP" '{sha: $sha}')
    fi
    ;;
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
  # The workflow's own file: where it lives, then what it says at the tip. The body is served
  # verbatim — the library asks for the raw media type rather than the base64 JSON, whose decoder
  # is spelled differently on this fleet's two platforms.
  "repos/$REPO/actions/workflows/"*) response=$(jq -cn --arg p "$WORKFLOW_PATH" '{path: $p}') ;;
  "repos/$REPO/contents/"*) response="$WORKFLOW_YAML" ;;
  "repos/$REPO/compare/"*)
    # Oldest first, so each commit's first parent is the one before it and the first commit's is
    # the compare's base — the judged commit, which the endpoint names in the path.
    base=${FIXTURE_ENDPOINT#*/compare/}
    base=${base%%...*}
    response=$(jq -cn --argjson c "$COMPARE_COMMITS" --arg t "$COMPARE_TOTAL" \
      --arg b "$base" --arg behind "$COMPARE_BEHIND" --argjson p "${COMPARE_PARENTS:-null}" \
      '{total_commits: (if $t == "" then ($c | length) else ($t | tonumber) end),
        behind_by: (if $behind == "" then 0 else ($behind | tonumber) end),
        commits: [$c | to_entries[] |
          {sha: .value,
           parents: [{sha: (if $p != null then $p[.key]
                            else (if .key == 0 then $b else $c[.key - 1] end) end)}]}]}')
    ;;
  "repos/$REPO/commits/"*)
    sha=${FIXTURE_ENDPOINT#*/commits/}
    sha=${sha%%\?*}
    response=$(jq -cn --argjson f "$(files_of "$sha")" '{files: $f}')
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
  # ... and it says so INSTEAD of the red, not under it: at the ceiling with an older tip's red
  # standing, the red headline would claim "failed on the tip you are about to branch from" about
  # a commit that has no verdict yet, and send the caller fixing a fix already in flight.
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" \
    "the honest headline is about the tip, which nothing here has judged"
  assert_not_contains "$BASE_OUTPUT" "is RED" \
    "an older tip's red must not headline as the tip's own verdict"
  assert_contains "$BASE_OUTPUT" "RED      ci" \
    "and the older red stays visible in the per-workflow lines under that headline"
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

# --- the tip's own absence, and the one absence that is not a race (ludics-lite#156) -----------
# The shape that blocked a wave's dispatch on 2026-09-15: the default branch's tip was a docs-only
# push, `ci` carries `paths-ignore: docs/**`, so no run for the tip was ever going to exist —
# and `base --wait` sat on it to its ceiling and refused, while the plain read settled for the
# older green on the same tip. Nothing here is about time: the workflow's own filter says a run
# cannot be created for this tip, so the wait has nothing to wait for and settles at once. The
# grace is left at its default so that only the recognition can end this wait.
test_a_paths_ignored_tip_settles_without_waiting_out_the_grace() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5001}]')")
  FILES_DEFAULT='[{"filename":"docs/agent-notes/build-and-test.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 0 "a tip whose whole diff is paths-ignored settles for the older verdict"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" \
    "the settle answers about the tip it settled for"
  assert_contains "$BASE_OUTPUT" "every commit on the first-parent path from the judged commit up to the tip changes only paths within the paths-ignore of ci" \
    "the settle should say WHY no run is coming, not just that it waited"
  assert_contains "$BASE_OUTPUT" "(that verdict is about ${SHA_A:0:8}, not the tip ${SHA_C:0:8})" \
    "the older commit the verdict is really about stays named"
  assert_not_contains "$BASE_OUTPUT" "NO VERDICT" "this is a settled verdict, not a refusal"
  assert_contains "$(cat "$REQUEST_LOG")" "compare/$SHA_A...$SHA_C?per_page=" \
    "the range read is from the JUDGED commit to the tip"
  assert_contains "$(cat "$REQUEST_LOG")" "commits/$SHA_C" \
    "and each commit in that range is read for its own diff"
}

# The recognition is about the WHOLE diff: one path the filter does not cover and a run is coming
# after all. Then the only thing that can settle this wait is the grace, which is left at its
# default here — so the wait runs to its ceiling and refuses, as it must.
test_a_tip_that_changed_a_source_file_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5002}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"},{"filename":"src/main.ml"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a diff the filter does not cover is a tip whose run is still coming"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" \
    "an unrecognized tip keeps the refusal"
  assert_not_contains "$BASE_OUTPUT" "paths-ignore of" "nothing was recognized here"
  # The three reads are per workflow, judged commit and tip — not per round.
  assert_eq "$(grep -c "contents/" "$REQUEST_LOG")" 1 \
    "the workflow file should be read once, not once per round"
}

# A commit's changed files are PAGINATED — 30 to a page by default, 300 in all — so an
# unpaginated read of a 45-file commit answers with 30 ignored paths and hides the source file
# behind them (ludics-lite#163 review, round 2). The read asks for every page, and a list at the
# endpoint's own 300-file cap is a truncated diff that settles nothing.
test_a_commits_files_are_read_whole() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5101}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 0 "the ordinary docs-only tip still settles"
  assert_contains "$(cat "$PAGINATE_LOG")" "commits/$SHA_C" \
    "the commit's files must be read across every page, not one page of thirty"
  # ... and a diff at the cap is not a diff.
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5102}]')")
  FILES_DEFAULT=$(jq -cn '[range(300) | {filename: ("docs/f" + (. | tostring) + ".md")}]')
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a file list at the endpoint's cap is truncated, and truncated is not evidence"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# The filter is read at the TIP, but a mid-range push was judged by the workflow file as it stood
# then: a filter the tip widened would explain away a run the older file had already asked for
# (ludics-lite#163 review, round 2). So no commit in the range may touch the workflow file — then
# the one filter read is the one that applied to every push in it.
test_a_workflow_file_touched_inside_the_range_is_not_recognized() {
  reset_fixture
  # A filter that ignores the workflow directory too, so that nothing BUT the moved-filter check
  # can refuse this range: the commit changing ci.yml is itself covered by the patterns.
  WORKFLOW_YAML='on:
  push:
    paths-ignore:
      - "docs/**"
      - ".github/workflows/**"
'
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5111}]')")
  COMPARE_COMMITS=$(jq -cn --arg b "$SHA_B" --arg c "$SHA_C" '[$b, $c]')
  FILES_b='[{"filename":".github/workflows/ci.yml"}]' # the commit that widened the filter
  FILES_c='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a filter that moved mid-range is not one filter"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# The counterexample that makes this a per-COMMIT question (ludics-lite#163 review, round 1): a
# path filter is evaluated per PUSH, over that push's own before/after diff, so a range whose
# CUMULATIVE diff nets out to docs can still contain a push that touched source — here a commit
# that changes src/main.ml, a later one that reverts it, and a docs commit on top. The net diff of
# the whole range is one doc; every push in it that carried src/main.ml would get a run.
test_a_source_change_reverted_inside_the_range_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5071}]')")
  COMPARE_COMMITS=$(jq -cn --arg z "$SHA_0" --arg b "$SHA_B" --arg c "$SHA_C" '[$z, $b, $c]')
  FILES_0='[{"filename":"src/main.ml"}]'                # changed source
  FILES_b='[{"filename":"src/main.ml"}]'                # ... and reverted it
  FILES_c='[{"filename":"docs/notes.md"}]'              # the tip itself is docs-only
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a commit that touched source is a run on its way, whatever the range nets to"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
  assert_contains "$(cat "$REQUEST_LOG")" "commits/$SHA_B" \
    "the walk has to reach the intervening commit, not stop at a clean tip"
}

# After a force-push the judged commit is not an ancestor of the tip at all: the three-dot range
# describes the tip side of a fork, and the deletions the push carried are nowhere in it
# (ludics-lite#163 review, round 3). `behind_by` is what says so.
test_a_judged_commit_that_is_not_an_ancestor_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5121}]')")
  COMPARE_BEHIND=2 # the judged commit carries two commits the tip does not
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a fork is not a range this recognition can read"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# A commit's file list is its diff against its FIRST parent, so only the first-parent chain is a
# path those diffs describe. A merge reached through its second parent hides, behind a docs-only
# first-parent diff, every source change the push carried from the judged tip — so the walk has to
# reach the judged commit by first parents or refuse (ludics-lite#163 review, round 3).
test_a_merge_reached_through_its_second_parent_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5131}]')")
  # The tip is a merge whose FIRST parent is an older commit outside the range; the judged commit
  # is its second parent, which is how it entered the range at all.
  COMPARE_PARENTS=$(jq -cn --arg z "$SHA_0" '[$z]')
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a first-parent diff does not describe a path that is not first-parent"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# GitHub creates a run for a push of more than 1000 commits whatever the filter says, and a range
# that long is not what this recognition is for besides: past the cap it goes to the grace rather
# than to a read per commit. Every commit here is docs-only, so nothing but the length refuses it.
test_a_range_longer_than_the_cap_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5081}]')")
  COMPARE_COMMITS=$(jq -cn '[range(21) | "cccccccccccccccccccccccccccccccccccc" + (1000 + . | tostring)]')
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a range past the cap explains no absence"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
  assert_eq "$(grep -c "commits/cccccccccccccccccccccccccccccccccccc1000" "$REQUEST_LOG")" 0 \
    "and it spends no per-commit read on a range it has already refused"
}

# A commit list the answer truncated is not evidence about the range either: the total says one
# thing and the rows another, and the recognition believes neither.
test_a_truncated_commit_list_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5091}]')")
  COMPARE_TOTAL=5 # the list below carries one
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a range only partly in hand explains no absence"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# A pattern the translation does not carry fails the WHOLE question rather than just itself: with
# `!docs/keep.md` in the filter, "the other pattern covered everything" is not an answer about a
# filter half of which was not read.
test_an_untranslatable_pattern_refuses_the_recognition() {
  reset_fixture
  WORKFLOW_YAML='on:
  push:
    paths-ignore: ["docs/**", "!docs/keep.md"]
'
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5003}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a filter that was not fully read cannot explain an absence"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# A workflow file the narrow parser cannot read (`on: [push]` names no filter at all) is refused
# the same way: a refusal costs the grace, which is the settle that was already there.
test_a_workflow_file_without_a_filter_refuses_the_recognition() {
  reset_fixture
  WORKFLOW_YAML='on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
'
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5004}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a workflow whose push filter cannot be read explains no absence"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 \
    "with no filter in hand there is nothing to compare the tip against"
}

# A run in flight ANYWHERE on this branch is judging a tree the tip contains, so the older green
# under it is not an all-clear for the tip: settling there hands out a verdict for a tree whose
# own run is minutes from answering (ludics-lite#163 review, round 1). Waiting also does BETTER
# than settling — when that run lands, its commit is what the tip's absence then trails.
test_a_run_in_flight_on_the_branch_keeps_the_wait() {
  reset_fixture
  retune ABSENT_GRACE=0
  RUNS_1=$(runs_json 1 "$(jq -cn --arg b "$SHA_B" --arg a "$SHA_A" \
    '[{status:"in_progress", conclusion:null, head_sha:$b, id:5011},
      {conclusion:"success", head_sha:$a, id:5010}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]' # would be recognized with nothing in flight
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "an unfinished run on the branch is a verdict still coming"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" "the refusal stands"
  assert_contains "$BASE_OUTPUT" "(ci is running now at ${SHA_B:0:8})" \
    "the run being waited for should be named"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 \
    "with a verdict in flight there is nothing for the filter to explain"
}

# The grace is a clock about the TIP, and it starts when the tip is first read — not when that
# round's last answer comes back. Re-stamping it on the first round spends the round's own API
# latency out of the grace, and `--wait=301` over a 300s grace then reaches its ceiling a few
# seconds before the clock it was sized against, every time: #156's dispatch refusal. The first
# read here is slow on purpose, which is what an API round is.
test_the_grace_runs_from_the_first_read_of_the_tip() {
  reset_fixture
  retune ABSENT_GRACE=3 CHECKS_INTERVAL=1
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5051}]')")
  FILES_DEFAULT='[{"filename":"src/main.ml"}]' # unrecognized: only the clock can settle this
  # The round's own reads take 3s, the grace is 3s and the ceiling 4s: measured from the first
  # READ the grace expires inside the wait, measured from the round's last answer it cannot.
  FIRST_READ_DELAY=3
  run_base --wait=4
  assert_eq "$BASE_RC" 0 "the grace should expire inside a wait sized against it"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" \
    "the settle is for the verdicts in hand"
  assert_contains "$BASE_OUTPUT" "no run for the tip appeared" "the note should say what was waited for"
}

# A listed workflow with NO push run on this branch at all is not in the fold, so no filter of its
# was read: it may be dispatch- or schedule-only, or a workflow the tip itself just added whose
# first run is on its way. One workflow's docs-only diff cannot speak for it, so the FAST settle
# has to hold — and the grace, which is exactly that newcomer's creation window, still settles.
test_a_workflow_with_no_run_history_holds_the_fast_settle() {
  reset_fixture
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"fresh"}]')
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5061}]')")
  RUNS_2=$(jq -cn '{workflow_runs: []}')
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a filter nobody read cannot be settled over"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" "the refusal stands"
  # ... and the grace, which is the newcomer's own creation window, settles it as it always did.
  reset_fixture
  retune ABSENT_GRACE=0
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"fresh"}]')
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5062}]')")
  RUNS_2=$(jq -cn '{workflow_runs: []}')
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 0 "the grace is the newcomer's creation window, and it still settles"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" \
    "a repository carrying a dispatch-only workflow must not park on it forever"
}

# What a run FOR THE TIP means, in both of its shapes: it exists, so no filter explains it, and
# only that run can answer. In flight, the wait waits — past any grace, and without spending a
# read on a recognition that could not apply.
test_a_run_in_flight_at_the_tip_keeps_the_refusal() {
  reset_fixture
  retune ABSENT_GRACE=0
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{status:"in_progress", conclusion:null, head_sha:$c, id:5021},
      {conclusion:"success", head_sha:$a, id:5020}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]' # would be recognized if the tip had no run
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a run judging the tip is the answer to wait for"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" "the refusal stands"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 \
    "an existing run is not an absence: nothing to recognize, and no read to spend on it"
}

# Stopped, the wait allows the grace for a superseding run to be created and then says the verdict
# is NONE — a cancelled run judged nothing, so it is neither absence nor an all-clear.
test_a_stopped_run_at_the_tip_is_no_verdict_not_an_absence() {
  reset_fixture
  retune ABSENT_GRACE=0
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{conclusion:"cancelled", head_sha:$c, id:5031}, {conclusion:"success", head_sha:$a, id:5030}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a stopped run at the tip is not an absence any filter explains"
  assert_contains "$BASE_OUTPUT" "stopped-not-judged and no replacement appeared" \
    "the report should say the workflow wants re-running"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 "a run that existed is not a paths-ignore tip"
}

# This settle accepts a verdict about an OLDER commit, so the tip it settles for has to still be
# the tip: a push landing between the round's tip read and the settle would otherwise be answered
# with a green from two commits back. The branch moves right after the round's own read here, so
# the first tip is never settled for — the successor is judged on its own.
test_the_settle_reconfirms_the_tip_before_it_accepts_an_older_verdict() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5041}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  TIP_SWITCH_AFTER=1 # the round's tip read answers SHA_C; the re-confirm and everything after it
  TIP_NEXT=$SHA_B    # answer SHA_B, as a push landing in that window would
  COMPARE_COMMITS=$(jq -cn --arg b "$SHA_B" '[$b]') # the successor's own one-commit range
  run_base --wait=4
  assert_eq "$BASE_RC" 0 "the successor tip is itself paths-ignored, and settles on its own round"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_B:0:8})" \
    "the settle is for the tip that is still there"
  assert_not_contains "$BASE_OUTPUT" "green (tip ${SHA_C:0:8})" \
    "the tip that moved under the round must never be settled for"
  assert_contains "$(cat "$REQUEST_LOG")" "compare/$SHA_A...$SHA_B?per_page=" \
    "the successor is judged by its own range"
}

# --- what the WAIT LOOP decides, and the swap that decides a verdict (ludics-lite#93) ----------
# The cases above pin the red REPORT (#81) and the settle (#156). What follows is the VERDICT:
# which break ends the wait, what each break re-confirms before it trusts what it read, where the
# absence clock starts, and which run in a workflow's window is the one the verdict is taken from.

# A red AT THE TIP is the tip's own verdict, so nothing is owed to the wait any more: it ends on
# the round that saw it, without spending the ceiling on a workflow still running beside it. The
# second workflow here is in flight at the tip, so the covered break cannot be what ended this —
# only the red one can.
test_a_red_at_the_tip_ends_the_wait_at_once() {
  reset_fixture
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"fixtures"}]')
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{conclusion:"failure", head_sha:$c, id:6011}, {conclusion:"success", head_sha:$a, id:6010}]')")
  RUNS_2=$(runs_json 2 "$(jq -cn --arg c "$SHA_C" \
    '[{status:"in_progress", conclusion:null, head_sha:$c, id:6012, name:"fixtures"}]')")
  run_base --wait=4
  assert_eq "$BASE_RC" 1 "a red at the tip is a verdict for the tip, and the wait is over"
  assert_contains "$BASE_OUTPUT" "is RED" "the red headline is what a red tip gets"
  assert_not_contains "$BASE_OUTPUT" "NO VERDICT" \
    "the tip HAS a verdict here; the run still going beside it does not take it away"
  assert_eq "$(grep -c "actions/workflows/1/runs" "$REQUEST_LOG")" 1 \
    "the red should end the wait on the round that saw it, not after another poll"
}

# ... and that break re-confirms the tip first, for the reason the green break does: a fix-forward
# push landing between the round's tip read and this check turns the red into an OLDER tip's red,
# which is exactly the shape the wait exists to keep waiting on. Breaking anyway would report RED
# for a commit that has no verdict yet and send the caller fixing a fix already in flight.
test_the_red_break_reconfirms_the_tip() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg b "$SHA_B" --arg a "$SHA_A" \
    '[{status:"in_progress", conclusion:null, head_sha:$b, id:6022},
      {conclusion:"failure", head_sha:$c, id:6021},
      {conclusion:"success", head_sha:$a, id:6020}]')")
  TIP_SWITCH_AFTER=1 # the round reads SHA_C and sees its red; the re-confirm reads the successor
  TIP_NEXT=$SHA_B
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "the red belongs to a tip that moved, so the successor has no verdict yet"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_B:0:8}" \
    "the refusal should be about the tip that is actually there"
  assert_not_contains "$BASE_OUTPUT" "is RED" \
    "a red under a moved tip must not headline as the tip's own verdict"
  assert_contains "$BASE_OUTPUT" "RED      ci — failure at ${SHA_C:0:8}" \
    "the older red stays visible in the per-workflow lines under the honest headline"
  assert_contains "$BASE_OUTPUT" "(ci is running now at ${SHA_B:0:8})" \
    "and the run that will judge the successor is named as what the wait was owed"
}

# The green break's own re-confirm: coverage is judged against the tip read BEFORE the runs, and a
# sibling merge landing in that window is the integration loop's ordinary traffic. Accepting the
# coverage anyway hands out "green (tip X)" for a branch already pointing at Y.
test_the_covered_break_reconfirms_the_tip() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" '[{conclusion:"success", head_sha:$c, id:6031}]')")
  TIP_SWITCH_AFTER=1 # everything after the round's own tip read answers the successor
  TIP_NEXT=$SHA_B
  COMPARE_COMMITS=$(jq -cn --arg b "$SHA_B" '[$b]')
  FILES_DEFAULT='[{"filename":"src/main.ml"}]' # the successor is unrecognized: nothing settles it
  run_base --wait=3
  assert_eq "$BASE_RC" 4 "the successor is unjudged, and a green for its predecessor is not its verdict"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_B:0:8}" "the refusal is about the tip"
  assert_not_contains "$BASE_OUTPUT" "green (tip ${SHA_C:0:8})" \
    "the tip that moved under the round must never be broken green for"
}

# The absence clock starts at the last time the TIP MOVED. A merge landing after the grace has
# already elapsed would otherwise be declared integration-green on the spot — its run not yet
# created and the timer long spent — which is a green for a commit nothing has built. The tip
# moves here five rounds in, with the grace sized so that only a restart keeps the wait alive to
# its ceiling.
test_a_tip_that_moves_mid_wait_restarts_the_grace() {
  reset_fixture
  retune ABSENT_GRACE=6 CHECKS_INTERVAL=1
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:6061}]')")
  FILES_DEFAULT='[{"filename":"src/main.ml"}]' # unrecognized: only the clock can settle this
  TIP_SWITCH_AFTER=5 # about five seconds in, well after the wait began and before the grace is up
  TIP_NEXT=$SHA_B
  run_base --wait=8
  assert_eq "$BASE_RC" 4 "the successor's own creation window has not run out inside this wait"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_B:0:8}" "the refusal is about the successor"
  assert_contains "$BASE_OUTPUT" "--wait ceiling" "the wait ended at its ceiling, not at a settle"
  assert_not_contains "$BASE_OUTPUT" "no run for the tip appeared" \
    "a grace that restarted with the tip cannot also have expired for it"
}

# The `norun` ambiguity, with every OTHER workflow judged at the tip: a listed workflow with no
# push run on this branch is either dispatch- or schedule-only (never coming) or a workflow the
# tip itself just added (on its way). What separates them is whether that newcomer has had its
# creation window SINCE THE PUSH — and the push time is read off the sibling runs AT THE TIP, not
# off the wait's own observation clock. The three cases below differ in nothing but that
# timestamp, which is the whole claim.
test_the_norun_ambiguity_is_settled_by_the_tips_own_age() {
  local now_iso
  now_iso=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  # Old tip, workflow with no history: dispatch-only, and the wait breaks green at once. Reading
  # the observation clock instead would hold every late-started wait for the full grace.
  reset_fixture
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"nightly"}]')
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" \
    '[{conclusion:"success", head_sha:$c, id:6051, created_at:"2026-09-10T00:00:00Z"}]')")
  RUNS_2=$(jq -cn '{workflow_runs: []}')
  run_base --wait=4
  assert_eq "$BASE_RC" 0 "a tip older than the creation window is not waiting on a newcomer"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" \
    "a repository carrying a dispatch-only workflow must not park every wait on it"
  assert_eq "$(grep -c "actions/workflows/1/runs" "$REQUEST_LOG")" 1 \
    "and it must not spend a single extra round on it"

  # Same shape, a tip pushed just now: the newcomer's first run may still be on its way, and
  # breaking green here would hand out an all-clear over a workflow that has judged nothing.
  reset_fixture
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"nightly"}]')
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg n "$now_iso" \
    '[{conclusion:"success", head_sha:$c, id:6052, created_at:$n}]')")
  RUNS_2=$(jq -cn '{workflow_runs: []}')
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a tip inside the creation window is still owed the newcomer's first run"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" "the refusal stands"

  # And an age that cannot be read is not evidence to hold on: holding on it would park the wait
  # on a shape drift rather than on a workflow.
  reset_fixture
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"nightly"}]')
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" \
    '[{conclusion:"success", head_sha:$c, id:6053, created_at:"-"}]')")
  RUNS_2=$(jq -cn '{workflow_runs: []}')
  run_base --wait=2
  assert_eq "$BASE_RC" 0 "an unreadable timestamp holds nothing"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" \
    "the coverage in hand is what the verdict is taken from"
}

# Under cancel-in-progress concurrency the newest COMPLETED run on a busy default branch is
# routinely `cancelled` — stopped, not judged. The verdict is the newest JUDGED run, so a red
# underneath a cancelled one still stands: reading the cancellation as the answer would turn a
# broken base into "no verdict" and let a worker branch off it.
test_a_red_under_a_cancelled_run_at_the_tip_still_stands() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{conclusion:"cancelled", head_sha:$c, id:6041},
      {conclusion:"failure", head_sha:$c, id:6040},
      {conclusion:"success", head_sha:$a, id:6039}]')")
  JOBS_6040=$(jobs_json '[{"name":"fixtures (ubuntu)","conclusion":"failure"}]')
  run_base
  assert_eq "$BASE_RC" 1 "the newest judged run is red, and a cancellation over it judged nothing"
  assert_contains "$BASE_OUTPUT" "is RED" "the red is the verdict"
  assert_contains "$BASE_OUTPUT" \
    "(newest completed run: cancelled at ${SHA_C:0:8}, stopped not judged — verdict above is the newest judged run)" \
    "the cancelled run stays on the report as context for the verdict it did not give"
  assert_contains "$BASE_OUTPUT" "failed job(s): fixtures (ubuntu) (failure)" \
    "the jobs read is anchored on the judged red, not on the cancelled run over it"
  assert_not_contains "$BASE_OUTPUT" "NO VERDICT" "a judged red is a verdict"

  # The swap is about the newest JUDGED run, whichever way it went: a green under the cancellation
  # is the tip's coverage, and dropping it would leave the tip unjudged over a run that passed.
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" \
    '[{conclusion:"cancelled", head_sha:$c, id:6043}, {conclusion:"success", head_sha:$c, id:6042}]')")
  run_base
  assert_eq "$BASE_RC" 0 "a green under a cancelled re-run is still the tip's verdict"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" "and the tip is covered by it"
  assert_contains "$BASE_OUTPUT" "stopped not judged" "the cancelled run is still named"
}

# Under --wait the tip is the QUESTION — which commit needs the verdict — so a tip read that
# failed cannot be waited through: the wait would idle to the absent-run grace and then settle for
# an older green, exit 0, never having known what it was waiting for. Without --wait the same read
# only decorates the report, and its failure costs the "not the tip" notes and nothing else.
test_an_unreadable_tip_is_unknown_under_wait_and_decoration_without_it() {
  reset_fixture
  retune API_ATTEMPTS=1
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" '[{conclusion:"success", head_sha:$c, id:6081}]')")
  FAIL_ENDPOINT="repos/$REPO/commits/$BRANCH"
  run_base --wait=2
  assert_eq "$BASE_RC" 3 "a wait that cannot read the tip is UNKNOWN, which is not a verdict"
  assert_contains "$BASE_OUTPUT" "base --wait cannot know" "the refusal should say what is missing"
  assert_not_contains "$BASE_OUTPUT" "$REPO $BRANCH: green" \
    "no green headline may come out of a tip nobody read"

  reset_fixture
  retune API_ATTEMPTS=1
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" '[{conclusion:"success", head_sha:$c, id:6082}]')")
  FAIL_ENDPOINT="repos/$REPO/commits/$BRANCH"
  run_base
  assert_eq "$BASE_RC" 0 "the plain read's verdict comes from the runs, not from the tip"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green" "the green stands, without a tip to name"
  assert_not_contains "$BASE_OUTPUT" "cannot know" "nothing was being waited for"
}

# Two pushes to this branch inside one second give their runs the same `created_at`, and GitHub
# documents no order between them. The fold below keeps the first row of each workflow it sees, so
# an undocumented order used to decide the verdict: here the tie is a green and a red at the tip,
# and the RED is the later allocation (the higher run id). Ordering the rows on (created_at desc,
# id desc) before the fold settles it the same way run_signal has since ludics-lite#83.
test_a_same_second_tie_goes_to_the_higher_run_id() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{conclusion:"success",  head_sha:$c, id:6071, created_at:"2026-09-10T00:30:00Z"},
      {conclusion:"failure",  head_sha:$c, id:6072, created_at:"2026-09-10T00:30:00Z"},
      {conclusion:"success",  head_sha:$a, id:6070, created_at:"2026-09-10T00:29:00Z"}]')")
  JOBS_6072=$(jobs_json '[{"name":"syntax, shellcheck","conclusion":"failure"}]')
  run_base
  assert_eq "$BASE_RC" 1 "the later of two runs created in one second is the verdict, and it is red"
  assert_contains "$BASE_OUTPUT" "is RED" "the tie must not be decided by the feed's own order"
  assert_contains "$BASE_OUTPUT" "red since ${SHA_C:0:8}" "the red starts at the tip"
  assert_contains "$(cat "$REQUEST_LOG")" "actions/runs/6072/jobs" \
    "the jobs read follows the run the tie was settled for"
  assert_not_contains "$(cat "$REQUEST_LOG")" "actions/runs/6071/jobs" \
    "the superseded row of the tie is not what the report is about"
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
  test_a_paths_ignored_tip_settles_without_waiting_out_the_grace
  test_a_tip_that_changed_a_source_file_is_not_recognized
  test_a_commits_files_are_read_whole
  test_a_workflow_file_touched_inside_the_range_is_not_recognized
  test_a_source_change_reverted_inside_the_range_is_not_recognized
  test_a_judged_commit_that_is_not_an_ancestor_is_not_recognized
  test_a_merge_reached_through_its_second_parent_is_not_recognized
  test_a_range_longer_than_the_cap_is_not_recognized
  test_a_truncated_commit_list_is_not_recognized
  test_an_untranslatable_pattern_refuses_the_recognition
  test_a_workflow_file_without_a_filter_refuses_the_recognition
  test_a_run_in_flight_on_the_branch_keeps_the_wait
  test_the_grace_runs_from_the_first_read_of_the_tip
  test_a_workflow_with_no_run_history_holds_the_fast_settle
  test_a_run_in_flight_at_the_tip_keeps_the_refusal
  test_a_stopped_run_at_the_tip_is_no_verdict_not_an_absence
  test_the_settle_reconfirms_the_tip_before_it_accepts_an_older_verdict
  test_a_red_at_the_tip_ends_the_wait_at_once
  test_the_red_break_reconfirms_the_tip
  test_the_covered_break_reconfirms_the_tip
  test_a_tip_that_moves_mid_wait_restarts_the_grace
  test_the_norun_ambiguity_is_settled_by_the_tips_own_age
  test_a_red_under_a_cancelled_run_at_the_tip_still_stands
  test_an_unreadable_tip_is_unknown_under_wait_and_decoration_without_it
  test_a_same_second_tie_goes_to_the_higher_run_id
)

run_tests "${tests[@]}"
