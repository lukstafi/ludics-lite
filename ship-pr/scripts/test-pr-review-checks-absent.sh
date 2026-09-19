#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's build gate, and specifically for everything the CHECK
# list alone cannot say about a head: "no workflow covers this commit" versus "the run for this
# commit has not created its checks yet" (ludics-lite#24), a run that failed or was stopped before
# any check existed, and a green check standing over a sibling run that has not judged the head
# (ludics-lite#38, round 2). None of those may leave the gate as exit 0.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=test-pr-review-lib.sh
source "$SCRIPT_DIR/test-pr-review-lib.sh"

# One brace group over everything below the preamble, so bash parses the rest of this file WHOLE
# before the first case runs and an edit landing mid-run cannot resume the shell at a shifted
# offset; the `exit` at the foot means it never comes back to the file for a next command
# (ludics-lite#10, #247). The `{` opens BELOW the sources, not above them: bash binds a function's
# `declare -F` location when it PARSES the definition, so inside a group that also holds the
# sources every definition here is parsed first and the libraries' bindings land last -- and the
# shadow guard (ludics-lite#46) then reads every suite function as still the library's, refusing a
# declared stub and accepting an undeclared shadow in silence. scripts/check-parse-guards.sh
# checks the shape, and says what may stand above the `{`.
{
test_tmpdir TEST_ROOT checks-absent-test

REPO=example/repo
HEAD_SHA=deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
# The PR's base branch tip, and the fork point the compare answers with. They are different on
# purpose: the base branch moves under every sibling merge, so the range the paths-ignore
# recognition walks starts at the MERGE BASE and never at `base.sha` (ludics-lite#176).
BASE_SHA=babababababababababababababababababababa
MERGE_BASE=1111111111111111111111111111111111111111
# The PR's own branch. It decides whether a `push` trigger is REACHABLE at all, which is all that
# can be established about a push event here (review round 1): a push's changed files are computed
# between its own before and after, and after a force-push the before is not on the walked path.
HEAD_REF=claude/topic
# The head of the newest merged pull request, which is what the provider question is sampled from.
SAMPLE_SHA=5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a
REQUEST_LOG="$TEST_ROOT/requests"
PAGINATE_LOG="$TEST_ROOT/paginated"

# --- the fixture transport --------------------------------------------------------------------
# One canned answer per endpoint, each a list so a round can differ from the next: the wait loop
# re-reads, and a fixture that could only answer once could not tell a hold from a settle.
HEAD_SEQ=()
CHECK_RUNS_SEQ=()
RUNS_SEQ=()
COMMIT_AGE=""
PR_UPDATED_AGE=""
JOBS_JSON=""
FAIL_ENDPOINT=""
# --- the paths-ignore recognition's own feeds (ludics-lite#176) --------------------------------
# A run-less head inside the grace is the one place the gate can do better than the clock: if
# every workflow's own filter says no run can be created for this head, the absence is settled on
# the spot. These are the answers that question reads — the workflow list, each workflow's file at
# the head, the compare that names the merge base, and what each commit in the range changed.
# PR_BASE is the base SHA the PR read answers with; a case clears it to stand for a PR whose base
# could not be read, which refuses the recognition before any of the rest is asked.
PR_BASE=""
PR_HEAD_REF=""
WORKFLOWS_JSON=""
WORKFLOW_TOTAL=""
WORKFLOW_PATH=""
WORKFLOW_YAML=""
# The base tip's copy of the same file. A `pull_request` run uses the workflow from the MERGE
# context, so the head's copy only speaks for it when the base's copy is identical; a case that
# sets this differently stands for a base-side edit made after the branch diverged.
WORKFLOW_YAML_BASE=""
# What `.github/workflows/` holds at each end of the merge. The repository's workflow LIST is not
# that set — it is built from the default branch plus whatever has run — so a file only one side
# carries is a workflow nothing examines while its first run is on its way.
WORKFLOW_DIR_HEAD=""
WORKFLOW_DIR_BASE=""
# Entries in that directory that are not workflow files. They count towards the endpoint's cap
# just the same, which is what the cap guard has to be read against.
WORKFLOW_DIR_OTHER=""
# The newest merged pull request of this repository, and its head's check runs: where "does this
# repository have a provider other than Actions" is read. The recognition reads workflows, so it
# can answer for nothing else — and a merged PR's head is the population the question is about,
# where the base tip (round 2's sample) was not.
MERGED_PRS_JSON=""
SAMPLE_CHECKS_JSON=""
SAMPLE_CHECKS_TOTAL=""
COMPARE_COMMITS=""
FILES_JSON=""

# A workflow with NO path filter at all, which is what this repository's own CI looks like and
# what every case here that is about the CLOCK needs: nothing about it can explain an absence, so
# the recognition refuses and the grace answers, exactly as it did before #176.
UNFILTERED_YAML='name: ci
on:
  pull_request:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
'

# One trigger the branch cannot reach, one the filter covers — the shape a repository that runs CI
# on its default branch and on every pull request actually has.

# The same workflow with docs filtered out of BOTH triggers a pull request fires. Both, because
# one of them saying "no run for this diff" says nothing about the other: a repo whose push is
# filtered and whose pull_request is not still gets a run for every PR head.
DOCS_IGNORED_YAML='name: ci
on:
  pull_request:
    paths-ignore:
      - "docs/**"
      - "**.md"
  push:
    branches: [main]
    paths-ignore: ["docs/**", "**.md"]
jobs:
  build:
    runs-on: ubuntu-latest
'

check_runs_json() { jq -cn --argjson runs "$1" '{check_runs:$runs}'; }
# Each row gets a distinct workflow_id unless the case names one, because the gate folds the run
# list per workflow and a shared id means "these are the same workflow's runs" — which is what the
# superseded-run cases below say deliberately. Rows are newest-first, as the API returns them, and
# the default `created_at` says so too: one second earlier per row down the list, so the order and
# the timestamps agree. The gate sorts on (created_at desc, id desc), so a case meaning "these two
# were created in the SAME second" has to name `created_at` on both rows — which is what the tie
# case does. Note that the default ids ASCEND down the list while the times descend: the newest
# row carries the LOWEST id, so a fold that sorted by id alone would invert every superseded-run
# case below (test_newest_run_of_a_workflow_still_counts is where that shows).
RUNS_EPOCH=1767225600 # 2026-01-01T00:00:00Z, a fixed clock: nothing here measures a run's age
runs_json() {
  jq -cn --argjson runs "$1" --argjson t0 "$RUNS_EPOCH" \
    '{workflow_runs: [$runs | to_entries[] | .value + {
        id: (.value.id // (.key + 101)),
        workflow_id: (.value.workflow_id // (.key + 1)),
        created_at: (.value.created_at // (($t0 - .key) | todateiso8601)),
        event: (.value.event // "push")}]}'
}
jobs_json() { jq -cn --argjson jobs "$1" '{jobs:$jobs}'; }
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
  HEAD_SEQ=("$HEAD_SHA")
  CHECK_RUNS_SEQ=("$(check_runs_json '[]')")
  RUNS_SEQ=("$(runs_json '[]')")
  COMMIT_AGE=3600
  PR_UPDATED_AGE=3600
  JOBS_JSON=$(jobs_json '[]')
  FAIL_ENDPOINT=""
  PR_BASE="$BASE_SHA"
  PR_HEAD_REF="$HEAD_REF"
  WORKFLOWS_JSON=$(jq -cn '{workflows:[{id:1,name:"ci",state:"active"}]}')
  WORKFLOW_TOTAL=""
  WORKFLOW_PATH=".github/workflows/ci.yml"
  WORKFLOW_YAML="$UNFILTERED_YAML"
  WORKFLOW_YAML_BASE=""
  WORKFLOW_DIR_HEAD='[".github/workflows/ci.yml"]'
  WORKFLOW_DIR_BASE=""
  WORKFLOW_DIR_OTHER='[]'
  MERGED_PRS_JSON=$(jq -cn --arg s "$SAMPLE_SHA" \
    '[{merged_at:"2026-09-18T00:00:00Z", head:{sha:$s}}]')
  SAMPLE_CHECKS_JSON=$(check_runs_json '[{"name":"ci","app":{"slug":"github-actions"}}]')
  SAMPLE_CHECKS_TOTAL=""
  COMPARE_COMMITS=$(jq -cn --arg h "$HEAD_SHA" '[$h]')
  FILES_JSON='[{"filename":"docs/notes.md"}]'
  rm -f "$TEST_ROOT/CHECK_RUNS_SEQ.calls" "$TEST_ROOT/RUNS_SEQ.calls" "$TEST_ROOT/HEAD_SEQ.calls"
  retune ABSENT_GRACE=300 CHECKS_INTERVAL=1 CHECKS_HEARTBEAT=600
  : >"$REQUEST_LOG"
  : >"$PAGINATE_LOG"
}

gh() {
  local response="" fixture_head
  gh_fixture_parse "$@"
  # A GLOB, deliberately unquoted: "repos/o/n/commits/<sha>" is a prefix of the check-runs
  # endpoint, so a substring match could not fail the commit read alone — and a case that failed
  # both reads would pass for the wrong reason.
  if [ -n "$FAIL_ENDPOINT" ]; then
    # shellcheck disable=SC2254
    case "$FIXTURE_ENDPOINT" in
    $FAIL_ENDPOINT)
      echo "gh: $FIXTURE_ENDPOINT unavailable (HTTP 500)" >&2
      return 1
      ;;
    esac
  fi
  case "$FIXTURE_ENDPOINT" in
  "repos/$REPO/pulls/7")
    fixture_head=$(next_of HEAD_SEQ)
    if [ "$fixture_head" = UNREADABLE ]; then return 1; fi
    if [ -n "$PR_UPDATED_AGE" ]; then
      response=$(jq -cn --arg sha "$fixture_head" --arg at "$(iso_ago "$PR_UPDATED_AGE")" \
        --arg base "$PR_BASE" --arg ref "$PR_HEAD_REF" \
        '{head:({sha:$sha} + (if $ref == "" then {} else {ref:$ref} end)), updated_at:$at}
         + (if $base == "" then {} else {base:{sha:$base}} end)')
    else
      response=$(jq -cn --arg sha "$fixture_head" --arg base "$PR_BASE" --arg ref "$PR_HEAD_REF" \
        '{head:({sha:$sha} + (if $ref == "" then {} else {ref:$ref} end))}
         + (if $base == "" then {} else {base:{sha:$base}} end)')
    fi
    ;;
  "repos/$REPO/commits/$HEAD_SHA/check-runs?filter=latest&per_page=100")
    response=$(next_of CHECK_RUNS_SEQ)
    ;;
  "repos/$REPO/actions/runs?head_sha=$HEAD_SHA&per_page=100")
    response=$(next_of RUNS_SEQ)
    ;;
  "repos/$REPO/actions/runs/"*"/jobs?per_page=100") response="$JOBS_JSON" ;;
  "repos/$REPO/commits/$HEAD_SHA")
    response=$(jq -cn --arg at "$(iso_ago "$COMMIT_AGE")" '{commit:{committer:{date:$at}}}')
    ;;
  # --- the recognition's feeds; the exact commit read above wins over the glob below ------------
  "repos/$REPO/actions/workflows?per_page=100")
    response=$(jq -c --arg t "$WORKFLOW_TOTAL" \
      '. + {total_count: (if $t == "" then (.workflows | length) else ($t | tonumber) end)}' \
      <<<"$WORKFLOWS_JSON")
    ;;
  # The workflow's own file: where it lives, then what it says AT THE HEAD. Served raw, as the
  # library asks for it — the base64 JSON envelope's decoder is spelled differently on this
  # fleet's two platforms.
  "repos/$REPO/actions/workflows/"*) response=$(jq -cn --arg p "$WORKFLOW_PATH" '{path:$p}') ;;
  # Entries, not only files: the endpoint's cap is on the array, and a response holding
  # directories can carry fewer files than the cap and still be truncated.
  "repos/$REPO/contents/.github/workflows?ref=$BASE_SHA")
    response=$(jq -cn --argjson f "${WORKFLOW_DIR_BASE:-$WORKFLOW_DIR_HEAD}" \
      --argjson d "$WORKFLOW_DIR_OTHER" \
      '[$f[] | {type:"file", path:.}] + [$d[] | {type:"dir", path:.}]')
    ;;
  "repos/$REPO/contents/.github/workflows?ref="*)
    response=$(jq -cn --argjson f "$WORKFLOW_DIR_HEAD" --argjson d "$WORKFLOW_DIR_OTHER" \
      '[$f[] | {type:"file", path:.}] + [$d[] | {type:"dir", path:.}]')
    ;;
  "repos/$REPO/contents/"*"?ref=$BASE_SHA")
    response="${WORKFLOW_YAML_BASE:-$WORKFLOW_YAML}"
    ;;
  "repos/$REPO/contents/"*) response="$WORKFLOW_YAML" ;;
  "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=20")
    response="$MERGED_PRS_JSON"
    ;;
  "repos/$REPO/commits/$SAMPLE_SHA/check-runs?filter=latest&per_page=100")
    response=$(jq -c --arg t "$SAMPLE_CHECKS_TOTAL" \
      '. + {total_count: (if $t == "" then (.check_runs | length) else ($t | tonumber) end)}' \
      <<<"$SAMPLE_CHECKS_JSON")
    ;;
  # One answer for both compares the recognition makes: `base...head`, read for the merge base
  # alone, and `merge_base...head`, read for the commits. Oldest first, each commit the first
  # parent of the next and the first one's parent the merge base — the shape a linear range has.
  "repos/$REPO/compare/"*)
    response=$(jq -cn --argjson c "$COMPARE_COMMITS" --arg m "$MERGE_BASE" \
      '{merge_base_commit: {sha: $m}, total_commits: ($c | length), behind_by: 0,
        commits: [$c | to_entries[] |
          {sha: .value,
           parents: [{sha: (if .key == 0 then $m else $c[.key - 1] end)}]}]}')
    ;;
  "repos/$REPO/commits/"*) response=$(jq -cn --argjson f "$FILES_JSON" '{files:$f}') ;;
  *) bail "unexpected fixture endpoint: $FIXTURE_ENDPOINT" ;;
  esac
  gh_fixture_answer "$response"
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
  assert_contains "$GATE_OUTPUT" "1 workflow run(s) for this head have no conclusion yet" \
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
  retune ABSENT_GRACE=0
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

# --- a head no run can be created for (ludics-lite#176) ----------------------------------------
# `base --wait` has recognized a paths-ignore TIP since #156; the same head, on a PR, waited the
# full grace out before its absence was called. It is the same question with two differences: the
# range is the PR's own (from its merge base, not from a standing verdict's commit), and a PR head
# can be given a run by `pull_request` as readily as by `push`, so every trigger has to answer.
test_a_docs_only_head_is_absent_without_waiting_out_the_grace() {
  reset_fixture
  COMMIT_AGE=5 # seconds into a 300s grace: only the filter can settle this
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  run_gate
  assert_eq "$GATE_RC" 0 "a head whose whole range is paths-ignored is absence, not a wait"
  assert_contains "$GATE_OUTPUT" ": ABSENT" "the recognized absence is the verdict"
  assert_contains "$GATE_OUTPUT" "no workflow run exists for this head, and none can be created" \
    "the reason should say no run is coming, not that one may still appear"
  assert_contains "$GATE_OUTPUT" "none can be created by ci" \
    "and name the workflow that cannot create one"
  assert_not_contains "$GATE_OUTPUT" "creation grace" "the clock is not what settled this"
  # The range is the PR's own fork point, never the base branch tip, which moves under every
  # sibling merge: reading base.sha for the range would walk the base branch's commits too.
  assert_contains "$(cat "$REQUEST_LOG")" "compare/$MERGE_BASE...$HEAD_SHA?per_page=" \
    "the commits are read from the merge base up"
}

# The whole reason the trigger set is read before any filter is: one trigger's docs-only filter
# says nothing about the trigger beside it. A repository whose push is filtered and whose
# pull_request is not gets a run for every PR head, and settling this would be a green over an
# unbuilt one.
test_a_trigger_without_a_filter_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML='name: ci
on:
  pull_request:
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
'
  run_gate
  assert_eq "$GATE_RC" 4 "a trigger with no filter can still create the run"
  assert_contains "$GATE_OUTPUT" "creation grace" "so the clock is all that is left"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" "and the absence is not yet a fact"
}

# A dispatched or scheduled run CAN carry this head, and an empty run list does not say one is not
# on its way — that emptiness is the not-created-yet window, which is the whole question.
# `gh workflow run --ref <branch>` is a validation somebody asked for by hand, and merging inside
# its creation window is what the grace exists to prevent (review round 4).
test_a_dispatchable_trigger_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML='name: ci
on:
  schedule:
    - cron: "0 0 * * *"
  workflow_dispatch:
  pull_request:
    paths-ignore: ["docs/**", "**.md"]
jobs:
  build:
    runs-on: ubuntu-latest
'
  run_gate
  assert_eq "$GATE_RC" 4 "a run either of them creates would carry this head"
  assert_contains "$GATE_OUTPUT" "creation grace" "so the grace answers"
}

# Per COMMIT, as `base --wait` reads it and for the same reason: a path filter is evaluated per
# push, and a range that nets out to docs can still contain a push that touched source.
test_a_source_file_in_the_range_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  FILES_JSON='[{"filename":"docs/notes.md"},{"filename":"src/main.ml"}]'
  run_gate
  assert_eq "$GATE_RC" 4 "one source path in the range is a run that is coming"
  assert_contains "$GATE_OUTPUT" "creation grace" "the grace is what answers instead"
}

# Every way the recognition can be less than certain leaves the wait waiting rather than hand out
# an absence: the parser is narrow on purpose, and a refusal costs only the grace that was there
# before it. A tab is YAML this state machine will not claim to have read.
test_an_unreadable_workflow_file_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML=$(printf 'name: ci\non:\n\tpull_request:\n\t\tpaths-ignore: ["docs/**"]\n')
  run_gate
  assert_eq "$GATE_RC" 4 "a workflow file that does not parse explains nothing"
  assert_contains "$GATE_OUTPUT" "creation grace" "and the grace answers as before"
}

test_an_unreadable_workflow_list_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  FAIL_ENDPOINT="*actions/workflows*"
  run_gate
  assert_eq "$GATE_RC" 4 "a workflow list that could not be read is not evidence of anything"
  assert_contains "$GATE_OUTPUT" "creation grace" "the grace answers"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" "and a failed read never becomes an absence"
}

# A PR whose base SHA the read did not carry has no range to walk. The recognition refuses before
# it asks the API anything at all.
test_a_head_without_a_base_sha_is_never_recognized() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  PR_BASE=""
  run_gate
  assert_eq "$GATE_RC" 4 "with no base there is no range and nothing to recognize"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 "and nothing is asked of the API"
  # The branch is evidence too: without it a `push` trigger cannot be shown unreachable.
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  PR_HEAD_REF=""
  run_gate
  assert_eq "$GATE_RC" 4 "with no branch a push trigger cannot be shown out of reach"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 "and that too is settled before any read"
}

# --- review round 1: what the recognition must not read too widely ----------------------------
# A push event's changed files are computed between the push's own before and after. After a
# NON-fast-forward push the before is not on the path walked here at all — force-pushing a `src/`
# change away leaves a docs-only range whose push diff still carries that file, and still creates a
# run. The pre-push SHA is in no feed this reads, so a `push` trigger this branch REACHES is never
# explained, whatever its paths-ignore says.
test_a_push_trigger_this_branch_reaches_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML='name: ci
on:
  pull_request:
    paths-ignore: ["docs/**", "**.md"]
  push:
    paths-ignore: ["docs/**", "**.md"]
jobs:
  build:
    runs-on: ubuntu-latest
'
  run_gate
  assert_eq "$GATE_RC" 4 "a push trigger with no branches list can fire for this branch"
  assert_contains "$GATE_OUTPUT" "creation grace" "so the grace is what answers"
  # The same trigger, reachable by an explicit pattern rather than by the absence of one.
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML='name: ci
on:
  pull_request:
    paths-ignore: ["docs/**", "**.md"]
  push:
    branches: ["claude/**"]
    paths-ignore: ["docs/**", "**.md"]
jobs:
  build:
    runs-on: ubuntu-latest
'
  run_gate
  assert_eq "$GATE_RC" 4 "a branches list this branch matches is a trigger in reach"
}

# A branches-ignore is a filter with the opposite sense, and the list above it does not describe
# the workflow. Present at all refuses.
test_a_branches_ignore_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML='name: ci
on:
  pull_request:
    paths-ignore: ["docs/**", "**.md"]
  push:
    branches-ignore: ["gh-pages"]
jobs:
  build:
    runs-on: ubuntu-latest
'
  run_gate
  assert_eq "$GATE_RC" 4 "a branches-ignore is a shape this does not read"
}

# An event is inert only when it is NAMED inert. Rounds 1 and 3 each arrived with a member of the
# same class — merge_group wrongly counted, pull_request_review and pull_request_review_comment
# wrongly ignored — so the rule is inverted rather than patched a third time, and anything nobody
# reasoned about costs the grace instead of a wrong absence.
test_an_event_outside_the_inert_list_keeps_the_head_waiting() {
  local ev
  for ev in pull_request_target pull_request_review pull_request_review_comment release \
    schedule workflow_dispatch repository_dispatch workflow_run; do
    reset_fixture
    COMMIT_AGE=5
    WORKFLOW_YAML="name: ci
on:
  pull_request:
    paths-ignore: [\"docs/**\", \"**.md\"]
  $ev:
jobs:
  build:
    runs-on: ubuntu-latest
"
    run_gate
    assert_eq "$GATE_RC" 4 "an unreasoned trigger ($ev) is not inert"
    assert_contains "$GATE_OUTPUT" "creation grace" "the grace answers instead ($ev)"
  done
}

# The list itself, both of it. What earns a place is not "nothing has fired it yet" but "a run of
# this event can NEVER carry this commit as its head": a merge-group run is created at the queue's
# own temporary ref, and a called workflow produces no run of its own at all — its jobs appear
# inside the caller's.
test_the_named_inert_events_do_not_block_the_recognition() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML='name: ci
on:
  workflow_call:
  merge_group:
  pull_request:
    paths-ignore: ["docs/**", "**.md"]
jobs:
  build:
    runs-on: ubuntu-latest
'
  run_gate
  assert_eq "$GATE_RC" 0 "neither event can put a run on this head, whatever has happened yet"
  assert_contains "$GATE_OUTPUT" ": ABSENT" "so the pull_request filter answers alone"
}

# The repository's workflow list is not an inventory of the files on a non-default branch: a
# workflow the head ADDS is absent from it, so every listed workflow can pass while the newcomer's
# first run is on its way. Any path under the workflow directory anywhere in the range refuses,
# which closes that and the filter-that-moved-mid-range case with one rule and no extra read.
test_a_workflow_added_by_the_range_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  # A filter that ignores the workflow directory too, so nothing but the guard can refuse this.
  WORKFLOW_YAML='name: ci
on:
  pull_request:
    paths-ignore: ["docs/**", "**.md", ".github/workflows/**"]
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
'
  FILES_JSON='[{"filename":"docs/notes.md"},{"filename":".github/workflows/new.yml"}]'
  run_gate
  assert_eq "$GATE_RC" 4 "a workflow the repository list cannot carry was never examined"
  assert_contains "$GATE_OUTPUT" "creation grace" "the grace answers instead"
}

# A merge-group run is created only after the PR enters a merge queue, and its head is the queue's
# own temporary ref — never this one. An unfiltered merge_group beside a filtered pull_request is
# an ordinary shape, and counting it would make every docs-only PR wait the grace out.
test_an_unfiltered_merge_group_does_not_block_the_recognition() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML='name: ci
on:
  merge_group:
  pull_request:
    paths-ignore: ["docs/**", "**.md"]
  push:
    branches: [main]
jobs:
  build:
    runs-on: ubuntu-latest
'
  run_gate
  assert_eq "$GATE_RC" 0 "merge_group cannot create a run for this head"
  assert_contains "$GATE_OUTPUT" ": ABSENT" "so the pull_request filter still answers"
}

# --- review round 2: what a workflow filter cannot speak for -----------------------------------
# The recognition reads WORKFLOWS, so it can only ever answer for Actions — and `build_checks`
# accepts every provider's check runs, so a repository with a third-party CI app has a second way
# to grow a check on a fresh head that no workflow filter describes. That is the mirror of the
# rule the gate already holds in the other direction: an early Codecov green over an empty run
# list does not shortcut the grace either.
test_a_second_check_provider_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  SAMPLE_CHECKS_JSON=$(check_runs_json '[{"name":"ci","app":{"slug":"github-actions"}},
                                       {"name":"buildkite","app":{"slug":"buildkite"}}]')
  run_gate
  assert_eq "$GATE_RC" 4 "a provider the workflows do not describe keeps the creation window open"
  assert_contains "$GATE_OUTPUT" "creation grace" "so the grace answers, as it did before"
}

# The review app posts a check run of its own from a non-Actions app, and counting it would refuse
# on every repository this skill is used in. Advisory names are dropped first, as everywhere else.
test_an_advisory_provider_does_not_block_the_recognition() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  SAMPLE_CHECKS_JSON=$(check_runs_json '[{"name":"ci","app":{"slug":"github-actions"}},
                                       {"name":"claude","app":{"slug":"claude"}}]')
  run_gate
  assert_eq "$GATE_RC" 0 "the review app is advisory in this direction too"
  assert_contains "$GATE_OUTPUT" ": ABSENT" "and the recognition still answers"
}

# No non-advisory check run on the sampled pull request at all is no evidence about this
# repository's providers, so it is not evidence that Actions is the only one. Neither is a
# repository with no merged pull request to sample.
test_a_sample_without_checks_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  SAMPLE_CHECKS_JSON=$(check_runs_json '[]')
  run_gate
  assert_eq "$GATE_RC" 4 "an empty check list on the sample says nothing about providers"
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  MERGED_PRS_JSON=$(jq -cn '[{merged_at:null, head:{sha:"0000000000000000000000000000000000000000"}}]')
  run_gate
  assert_eq "$GATE_RC" 4 "a repository with no merged pull request has nothing to sample"
}

# A `pull_request` run uses the workflow from the MERGE context, base merged with head, so a
# base-side edit that removed a paths-ignore takes effect while the head's own copy still carries
# it — and that edit is outside the walked range, so the workflow-file guard never sees it. The
# two copies must be identical; when both sides of a merge hold the same content, that content is
# what the merge produces.
test_a_base_side_workflow_edit_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  WORKFLOW_YAML_BASE="$UNFILTERED_YAML" # main dropped the paths-ignore after the branch diverged
  run_gate
  assert_eq "$GATE_RC" 4 "the head's copy does not speak for the merge context"
  assert_contains "$GATE_OUTPUT" "creation grace" "the grace answers"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" "and nothing is settled on the stale copy"
}

# --- review round 6 ---------------------------------------------------------------------------
# The name in the repository's workflow list has no ref: it describes the DEFAULT branch's copy,
# while what runs for this PR is the copy at the head and the base. A workflow the list calls
# advisory is therefore not evidence that the file running here is, so every listed workflow is
# explained now — and one whose own filter cannot explain it costs the grace.
test_a_workflow_the_list_calls_advisory_is_still_explained() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  WORKFLOWS_JSON=$(jq -cn '{workflows:[{id:1,name:"ci",state:"active"},
                                       {id:2,name:"claude",state:"active"}]}')
  # Both ids answer with the same path and the same filtered body here, so the advisory-named one
  # is explained on its own terms and the settle stands.
  run_gate
  assert_eq "$GATE_RC" 0 "an advisory-named workflow whose filter explains it settles like any other"
  # The same list, with the file at that path unable to explain itself: no name skips it now.
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$UNFILTERED_YAML"
  WORKFLOWS_JSON=$(jq -cn '{workflows:[{id:2,name:"claude",state:"active"}]}')
  run_gate
  assert_eq "$GATE_RC" 4 "a name from the default branch does not excuse the file that runs here"
  assert_contains "$GATE_OUTPUT" "creation grace" "the grace answers instead"
}

# The Contents API caps a directory response and offers no pagination past it, so a directory at
# the cap is one this cannot read — and a workflow beyond it would be in neither inventory.
test_a_capped_workflow_directory_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  WORKFLOW_DIR_HEAD=$(jq -cn '[range(1000) | ".github/workflows/w\(.).yml"]')
  run_gate
  assert_eq "$GATE_RC" 4 "a directory response at the endpoint cap is not an inventory"
  assert_contains "$GATE_OUTPUT" "creation grace" "the grace answers instead"
  # The cap is on ENTRIES, so a response padded to it with directories is truncated even though
  # its FILE count is far below (review round 7).
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  WORKFLOW_DIR_OTHER=$(jq -cn '[range(999) | ".github/workflows/d\(.)"]')
  run_gate
  assert_eq "$GATE_RC" 4 "the cap is read against the whole array, not the files in it"
}

# --- review round 5: the list is not the file set, and the range is read once ------------------
# The repository's workflow list is built from the default branch plus whatever has run, so it is
# not an inventory of the files the merge context will hold. A workflow only the BASE carries —
# added there after the branch forked — is absent from the head and from the list, and the
# `.github/workflows/` guard over the range cannot see it either, since that range is head-side.
test_a_workflow_only_on_the_base_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  WORKFLOW_DIR_BASE='[".github/workflows/ci.yml", ".github/workflows/added-on-main.yml"]'
  run_gate
  assert_eq "$GATE_RC" 4 "a workflow the list does not carry was never examined"
  assert_contains "$GATE_OUTPUT" "creation grace" "the grace answers instead"
}

# The same the other way: a file only the head carries. The range guard already refuses this when
# the range shows it, and this is the belt to that brace — the range is capped, and a file added
# before the cap's window is still a file nothing examined.
test_a_workflow_only_on_the_head_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  WORKFLOW_DIR_HEAD='[".github/workflows/ci.yml", ".github/workflows/added-on-branch.yml"]'
  run_gate
  assert_eq "$GATE_RC" 4 "a file at the head that the list does not carry was never examined"
}

# Every workflow asks its own filter about the SAME range, so the range is read once and not once
# per workflow. At the supported limits the old shape was ~2100 requests per attempt, repeated
# every polling round inside the grace — which could turn the gate UNKNOWN on rate limits for
# exactly the heads this is meant to settle.
test_the_range_is_read_once_for_every_workflow() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  WORKFLOWS_JSON=$(jq -cn '{workflows:[{id:1,name:"ci",state:"active"},
                                       {id:2,name:"docs",state:"active"}]}')
  COMPARE_COMMITS=$(jq -cn --arg h "$HEAD_SHA" '["2222222222222222222222222222222222222222", $h]')
  run_gate
  assert_eq "$GATE_RC" 0 "two workflows, both filtered, still settle"
  # One compare for the merge base, one for the range, and one read per commit in it — whatever
  # the number of workflows.
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 2 "the range is compared once, not once per workflow"
  assert_eq "$(grep -cE "/commits/[0-9a-f]+\\?per_page=100$" "$REQUEST_LOG")" 2 \
    "each commit's files are read once, whatever the number of workflows"
}

# One page of 100 on the provider sample too: a large Actions matrix can fill it while the
# third-party provider this is looking for sits on the next page, which would read as exactly the
# answer that settles a head wrongly.
test_a_truncated_provider_sample_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  SAMPLE_CHECKS_TOTAL=2 # one row served, two claimed
  run_gate
  assert_eq "$GATE_RC" 4 "a page is not the sample"
  assert_contains "$GATE_OUTPUT" "creation grace" "the grace answers instead"
}

# One page of 100, and a repository with more workflows than that would have the later ones
# silently left out — the ones that CAN run for this head, while the ones read say they cannot.
test_a_truncated_workflow_list_keeps_the_head_waiting() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  WORKFLOW_TOTAL=2 # one row served, two claimed: a page, not the list
  run_gate
  assert_eq "$GATE_RC" 4 "a truncated workflow list is not a list of this repository's workflows"
  assert_contains "$GATE_OUTPUT" "creation grace" "the grace answers instead"
}

# A run that EXISTS is never explained by a filter: it was created, so the filter did not stop it,
# and only that run can answer for it. The question is not even asked.
test_a_head_with_a_run_never_consults_the_filter() {
  reset_fixture
  COMMIT_AGE=5
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"in_progress","conclusion":null}]')")
  run_gate
  assert_eq "$GATE_RC" 4 "an in-flight run is a verdict on its way"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 \
    "with a run in hand there is nothing for a filter to explain"
}

# Past the grace the absence is already the verdict, so the reads the recognition would make buy
# nothing and are not made.
test_a_head_past_the_grace_never_consults_the_filter() {
  reset_fixture
  COMMIT_AGE=1800
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  run_gate
  assert_eq "$GATE_RC" 0 "past the grace the clock has already settled it"
  assert_contains "$GATE_OUTPUT" "past the" "and says so on the clock's own terms"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 "no read is spent on an answer already given"
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

# Green checks over a finished, judged run list are green — and the head's age is nobody's
# business then: run rows for one event are created together, so a head showing a check has had
# its rows created, and holding every fresh green head for the grace would buy nothing.
test_green_over_finished_runs_is_green() {
  reset_fixture
  COMMIT_AGE=5
  PR_UPDATED_AGE=5
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"ci","conclusion":"success","html_url":"u"}]')")
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"completed","conclusion":"success"}]')")
  run_gate
  assert_eq "$GATE_RC" 0 "green checks over a finished run list are green"
  assert_contains "$GATE_OUTPUT" "green — 1 build checks passed" "green should headline green"
}

# Round 2 of the review of ludics-lite#38, P1: one workflow's green check says nothing about a
# SIBLING workflow whose run is queued and has yet to create its own.
test_green_over_a_queued_sibling_is_not_green() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"a","conclusion":"success","html_url":"u"}]')")
  RUNS_SEQ=("$(runs_json '[{"name":"a","status":"completed","conclusion":"success"},
                           {"name":"b","status":"queued","conclusion":null}]')")
  run_gate
  assert_eq "$GATE_RC" 4 "a queued sibling run leaves the head unjudged"
  assert_contains "$GATE_OUTPUT" "NO VERDICT YET" "the sibling should headline no verdict"
  assert_contains "$GATE_OUTPUT" "1 build check(s) have passed so far" \
    "the line should still say what passed"
  assert_not_contains "$GATE_OUTPUT" "green — " "a queued sibling must not read as green"
}

# Round 2, P1: a workflow that fails before its jobs start leaves no check run to be red. The check
# list cannot show it, so the run list has to.
test_checkless_red_run_is_red() {
  local concl
  for concl in startup_failure failure timed_out; do
    reset_fixture
    RUNS_SEQ=("$(runs_json "$(jq -cn --arg c "$concl" \
      '[{name:"ci", status:"completed", conclusion:$c}]')")")
    run_gate
    assert_eq "$GATE_RC" 1 "a checkless $concl run is a red build signal"
    assert_contains "$GATE_OUTPUT" ": RED" "a checkless $concl run should headline RED"
    assert_contains "$GATE_OUTPUT" "ci ($concl)" "the red run should be named"
    assert_not_contains "$GATE_OUTPUT" ": ABSENT" "a red run must not print ABSENT"
  done
}

# ... and it outranks a green check on the same head, for the same reason: nothing in the check
# list can carry that run's failure.
test_checkless_red_run_outranks_a_green_check() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"a","conclusion":"success","html_url":"u"}]')")
  RUNS_SEQ=("$(runs_json '[{"name":"a","status":"completed","conclusion":"success"},
                           {"name":"b","status":"completed","conclusion":"startup_failure"}]')")
  run_gate
  assert_eq "$GATE_RC" 1 "a checkless red sibling is red, not green"
  assert_contains "$GATE_OUTPUT" "b (startup_failure)" "the red sibling should be named"
}

# A red in the check list is a verdict the fold already has; the run list adds nothing to it.
test_red_checks_never_consult_the_run_list() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"ci","conclusion":"failure","html_url":"u"}]')")
  run_gate
  assert_eq "$GATE_RC" 1 "a failed check is red"
  assert_contains "$GATE_OUTPUT" "RED" "red should headline RED"
  assert_not_contains "$(cat "$REQUEST_LOG")" "actions/runs" \
    "a red check list should not need the run list"
}

# Round 3 of the review, P1: a pending or cancelled check on one workflow while a sibling has
# already concluded red without producing a check. Reporting 4 there would let --allow-no-verdict
# merge a failed head without facing the red-build --override.
test_checkless_red_run_outranks_a_pending_check() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"a","conclusion":null,"html_url":"u"}]')")
  RUNS_SEQ=("$(runs_json '[{"name":"a","status":"in_progress","conclusion":null},
                           {"name":"b","status":"completed","conclusion":"startup_failure"}]')")
  run_gate
  assert_eq "$GATE_RC" 1 "a checkless red sibling outranks a still-running check"
  assert_contains "$GATE_OUTPUT" ": RED" "the pending fold should still headline RED"
  assert_contains "$GATE_OUTPUT" "b (startup_failure)" "the red sibling should be named"
}

test_checkless_red_run_outranks_a_stopped_check() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"a","conclusion":"cancelled","html_url":"u"}]')")
  RUNS_SEQ=("$(runs_json '[{"name":"a","status":"completed","conclusion":"cancelled"},
                           {"name":"b","status":"completed","conclusion":"failure"}]')")
  run_gate
  assert_eq "$GATE_RC" 1 "a checkless red sibling outranks a stopped-not-judged fold"
  assert_contains "$GATE_OUTPUT" "b (failure)" "the red sibling should be named"
}

# An unread run list cannot rule out such a red, so even a plainly pending fold is UNKNOWN rather
# than the milder 4 it could have claimed on its own.
test_pending_with_an_unreadable_run_list_is_unknown() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"a","conclusion":null,"html_url":"u"}]')")
  FAIL_ENDPOINT="*actions/runs*"
  run_gate
  assert_eq "$GATE_RC" 3 "an unread run list under a pending fold is unknown"
  assert_contains "$GATE_OUTPUT" "UNKNOWN" "it should say UNKNOWN"
}

# Round 3, P1: build_checks accepts every provider's check runs, so an early non-Actions green
# proves nothing about whether Actions has created its rows.
test_non_actions_check_without_runs_keeps_the_grace() {
  reset_fixture
  COMMIT_AGE=20
  PR_UPDATED_AGE=20
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"codecov","conclusion":"success","html_url":"u"}]')")
  run_gate
  assert_eq "$GATE_RC" 4 "a green app check with no Actions run yet is not a build verdict"
  assert_contains "$GATE_OUTPUT" "run-creation grace" "the hold should name the grace"
  assert_not_contains "$GATE_OUTPUT" "green — " "an unbacked green must not read as green"
}

test_non_actions_check_past_the_grace_is_green() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"codecov","conclusion":"success","html_url":"u"}]')")
  run_gate
  assert_eq "$GATE_RC" 0 "past the grace the check fold's own verdict stands"
  assert_contains "$GATE_OUTPUT" "green — 1 build checks passed" "green should headline green"
}

# Round 3, P2: several runs of ONE workflow at one head — a queued invocation cancelled, then a
# fresh one. Only the newest counts, as `filter=latest` does for the check list.
test_superseded_stopped_run_does_not_hold() {
  reset_fixture
  RUNS_SEQ=("$(runs_json '[{"workflow_id":7,"name":"ci","status":"completed","conclusion":"success"},
                           {"workflow_id":7,"name":"ci","status":"completed","conclusion":"cancelled"}]')")
  run_gate
  assert_eq "$GATE_RC" 0 "a superseded cancelled run must not park the gate at no-verdict"
  assert_not_contains "$GATE_OUTPUT" "stopped-not-judged" \
    "the superseded row should not be the one classified"
}

test_superseded_red_run_does_not_stay_red() {
  reset_fixture
  RUNS_SEQ=("$(runs_json '[{"workflow_id":7,"name":"ci","status":"completed","conclusion":"success"},
                           {"workflow_id":7,"name":"ci","status":"completed","conclusion":"failure"}]')")
  run_gate
  assert_eq "$GATE_RC" 0 "a superseded failure must not hold the gate red"
  assert_not_contains "$GATE_OUTPUT" ": RED" "the superseded row should not be the one classified"
}

test_newest_run_of_a_workflow_still_counts() {
  reset_fixture
  RUNS_SEQ=("$(runs_json '[{"workflow_id":7,"name":"ci","status":"completed","conclusion":"failure"},
                           {"workflow_id":7,"name":"ci","status":"completed","conclusion":"success"}]')")
  run_gate
  assert_eq "$GATE_RC" 1 "the newest run of a workflow is the one that counts"
  assert_contains "$GATE_OUTPUT" "ci (failure)" "the newest row should be the one classified"
}

# ludics-lite#70: two runs of ONE workflow-and-event key created in the SAME second. Their order
# in the feed is documented nowhere and no fixture could encode it, so the fold does not take it:
# it sorts on (created_at desc, id desc), and the tie goes to the higher run id — the later
# allocation. Both orientations are here and they disagree about the verdict, which is what makes
# the claim able to fail: a fold that kept the feed's first row would answer each of them the
# wrong way round, and one that simply dropped a red twin would answer the second one wrong.
test_same_second_tie_prefers_the_higher_run_id() {
  local same=2026-01-01T00:00:00Z
  reset_fixture
  RUNS_SEQ=("$(runs_json "$(jq -cn --arg t "$same" '[
    {id:101, workflow_id:7, created_at:$t, name:"ci", status:"completed", conclusion:"failure"},
    {id:202, workflow_id:7, created_at:$t, name:"ci", status:"completed", conclusion:"success"}]')")")
  run_gate
  assert_eq "$GATE_RC" 0 "the higher run id wins the tie, so the lower-id failure is superseded"
  assert_not_contains "$GATE_OUTPUT" ": RED" "the lower-id row must not be the one classified"
  assert_contains "$GATE_OUTPUT" "1 workflow run(s) for this head finished" \
    "the tied rows should fold to one run, not two"
  # The control, and the reason this is not just "a red twin is always dropped": with the ids the
  # other way up — the feed order unchanged — the winner is the red one, and the gate must say so.
  reset_fixture
  RUNS_SEQ=("$(runs_json "$(jq -cn --arg t "$same" '[
    {id:101, workflow_id:7, created_at:$t, name:"ci", status:"completed", conclusion:"success"},
    {id:202, workflow_id:7, created_at:$t, name:"ci", status:"completed", conclusion:"failure"}]')")")
  run_gate
  assert_eq "$GATE_RC" 1 "the higher run id wins the tie the other way up too"
  assert_contains "$GATE_OUTPUT" "ci (failure)" "the higher-id row should be the one classified"
}

# Round 3, P2: a committer date in the future (clock skew, an explicit GIT_COMMITTER_DATE) is the
# newest timestamp there is, and its age is unreadable. The PR clock must still decide.
test_future_commit_date_falls_back_to_the_pr_clock() {
  reset_fixture
  COMMIT_AGE=-86400
  PR_UPDATED_AGE=7200
  run_gate
  assert_eq "$GATE_RC" 0 "a future commit date must not block the absence verdict"
  assert_contains "$GATE_OUTPUT" ": ABSENT" "the PR clock should carry it past the grace"
}

test_future_commit_date_still_holds_a_fresh_pr() {
  reset_fixture
  COMMIT_AGE=-86400
  PR_UPDATED_AGE=20
  run_gate
  assert_eq "$GATE_RC" 4 "a fresh PR clock still holds under a future commit date"
  assert_contains "$GATE_OUTPUT" "run-creation grace" "the hold should name the grace"
}

# Round 2, P2: a head with a long re-run history can push a queued run off the first page.
test_run_lookup_is_paginated() {
  reset_fixture
  run_gate
  assert_contains "$(cat "$PAGINATE_LOG")" "actions/runs" \
    "the run lookup should ask for every page"
}

# --wait must hold through the not-created-yet window and then read the verdict that appears,
# which is the whole point of backgrounding it.
test_wait_holds_until_the_checks_appear() {
  reset_fixture
  COMMIT_AGE=10
  retune CHECKS_HEARTBEAT=0
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
  assert_contains "$GATE_OUTPUT" "in place at most 2" \
    "the fresher clock (~20s) should be the one reported, not the day-old commit date"
  assert_not_contains "$GATE_OUTPUT" "in place at most 1440m" \
    "the committer date must not be the clock here"
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

# Round 4 of the review, P1: one workflow file triggered on both `push` and `pull_request`
# produces two INDEPENDENT runs at the same head, sharing a workflow id. Folding them together
# hides a queued invocation behind a newer one that finished.
test_two_events_of_one_workflow_are_two_runs() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"ci","conclusion":"success","html_url":"u"}]')")
  RUNS_SEQ=("$(runs_json '[{"workflow_id":7,"event":"pull_request","name":"ci",
                            "status":"completed","conclusion":"success"},
                           {"workflow_id":7,"event":"push","name":"ci",
                            "status":"queued","conclusion":null}]')")
  run_gate
  assert_eq "$GATE_RC" 4 "the queued push run is not superseded by the pull_request run"
  assert_contains "$GATE_OUTPUT" "NO VERDICT YET" "the queued invocation should hold the gate"
}

# Round 5 of the review, P2: two independent invocations of one workflow at one head share a
# workflow id AND an event, so no key tells them apart — but a queued row has not been superseded
# by anything, and only finished rows compete to be the answer.
test_queued_invocation_survives_a_finished_twin() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"ci","conclusion":"success","html_url":"u"}]')")
  RUNS_SEQ=("$(runs_json '[{"id":201,"workflow_id":7,"event":"workflow_dispatch","name":"ci",
                            "status":"completed","conclusion":"success"},
                           {"id":202,"workflow_id":7,"event":"workflow_dispatch","name":"ci",
                            "status":"queued","conclusion":null}]')")
  run_gate
  assert_eq "$GATE_RC" 4 "a queued invocation is not superseded by a finished twin"
  assert_contains "$GATE_OUTPUT" "NO VERDICT YET" "the queued invocation should hold the gate"
}

# Round 4, P2: a stopped check under a queued run used to break the wait loop at once.
test_stopped_checks_with_a_queued_run_keep_waiting() {
  reset_fixture
  retune CHECKS_HEARTBEAT=0
  CHECK_RUNS_SEQ=(
    "$(check_runs_json '[{"name":"a","conclusion":"cancelled","html_url":"u"}]')"
    "$(check_runs_json '[{"name":"a","conclusion":"cancelled","html_url":"u"},
                         {"name":"b","conclusion":"failure","html_url":"u"}]')"
  )
  RUNS_SEQ=("$(runs_json '[{"name":"a","status":"completed","conclusion":"cancelled"},
                           {"name":"b","status":"queued","conclusion":null}]')")
  run_gate 30
  assert_eq "$GATE_RC" 1 "the wait should have stayed for the queued run's verdict"
  assert_contains "$GATE_OUTPUT" "still waiting" "a mixed fold over a queued run should wait"
}

# Round 4, P2: `completed` with no conclusion recorded yet is not judged.
test_completed_run_without_a_conclusion_is_unjudged() {
  reset_fixture
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"completed","conclusion":null}]')")
  run_gate
  assert_eq "$GATE_RC" 4 "a completed run with no conclusion has judged nothing"
  assert_contains "$GATE_OUTPUT" "no conclusion yet" "the reason should say so"
  assert_not_contains "$GATE_OUTPUT" ": ABSENT" "it must not settle as absence"
}

# Round 4, P1: the advisory list is a deny-list of CHECK names, and build_checks applies it per
# check run. A non-advisory workflow whose only failing job is advisory must not come back as red
# through the run-level conclusion.
test_advisory_job_failure_is_not_a_red_run() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"build","conclusion":"success","html_url":"u"}]')")
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"completed","conclusion":"failure"}]')")
  JOBS_JSON=$(jobs_json '[{"name":"build","conclusion":"success"},
                          {"name":"claude","conclusion":"failure"}]')
  run_gate
  assert_eq "$GATE_RC" 0 "a red explained entirely by an advisory job is not a build red"
  assert_contains "$GATE_OUTPUT" "green — 1 build checks passed" "the check fold's verdict stands"
}

test_non_advisory_job_failure_is_a_red_run() {
  reset_fixture
  CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"lint","conclusion":"success","html_url":"u"}]')")
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"completed","conclusion":"failure"}]')")
  JOBS_JSON=$(jobs_json '[{"name":"lint","conclusion":"success"},
                          {"name":"build","conclusion":"failure"}]')
  run_gate
  assert_eq "$GATE_RC" 1 "a red job the gate does not ignore is still red"
  assert_contains "$GATE_OUTPUT" "ci (failure)" "the red run should be named"
}

# A red this cannot disprove stands: no jobs at all is the startup_failure shape, and an
# unreadable job list is not evidence of innocence.
test_unreadable_jobs_keep_the_red() {
  reset_fixture
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"completed","conclusion":"failure"}]')")
  FAIL_ENDPOINT="*/jobs?per_page=100"
  run_gate
  assert_eq "$GATE_RC" 1 "an unreadable job list leaves the red standing"
  assert_contains "$GATE_OUTPUT" ": RED" "the red should still headline"
}

# A successor never inherits the observed head's checks, even when those checks passed
# or were cancelled. The unchanged sequence is the control for the additional head reads.
test_wait_superseded_head() {
  local conclusion terminal_checks
  for conclusion in success cancelled; do
    reset_fixture
    HEAD_SEQ=("$HEAD_SHA" "$HEAD_SHA" feedbeeffeedbeeffeedbeeffeedbeeffeedbeef)
    terminal_checks=$(jq -cn --arg conclusion "$conclusion" \
      '{check_runs:[{name:"ci",conclusion:$conclusion}]}')
    CHECK_RUNS_SEQ=(
      "$(check_runs_json '[{"name":"ci","status":"in_progress"}]')"
      "$terminal_checks"
    )
    RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"completed","conclusion":"success"}]')")
    run_gate 30
    assert_eq "$GATE_RC" 5 "a moved head supersedes the old $conclusion verdict"
    assert_contains "$GATE_OUTPUT" "SUPERSEDED" "the distinct outcome is named"
    assert_contains "$GATE_OUTPUT" "$HEAD_SHA" "the observed head is named"
    assert_contains "$GATE_OUTPUT" "feedbeef" "the successor is named"
    assert_eq "$(cat "$TEST_ROOT/CHECK_RUNS_SEQ.calls")" 2 "the superseded wait ends promptly"
  done
}

test_wait_unchanged_head_turns_green() {
  reset_fixture
  CHECK_RUNS_SEQ=(
    "$(check_runs_json '[{"name":"ci","status":"in_progress"}]')"
    "$(check_runs_json '[{"name":"ci","conclusion":"success"}]')"
  )
  RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"completed","conclusion":"success"}]')")
  run_gate 30
  assert_eq "$GATE_RC" 0 "unchanged pending head settles green"
  assert_contains "$GATE_OUTPUT" "green —" "unchanged green is still reported"
}

test_head_reread_unknown() {
  local head
  for head in UNREADABLE ''; do
    reset_fixture
    HEAD_SEQ=("$HEAD_SHA" "$head")
    CHECK_RUNS_SEQ=("$(check_runs_json '[{"name":"ci","conclusion":"success"}]')")
    RUNS_SEQ=("$(runs_json '[{"name":"ci","status":"completed","conclusion":"success"}]')")
    run_gate 30
    assert_eq "$GATE_RC" 3 "unreadable or empty head remains unknown over green"
    assert_not_contains "$GATE_OUTPUT" "SUPERSEDED" "an unread head proves no movement"
    assert_not_contains "$GATE_OUTPUT" "green —" "an unread head never reports green"
  done
}

tests=(
  test_wait_superseded_head
  test_wait_unchanged_head_turns_green
  test_head_reread_unknown
  test_inflight_run_is_not_absent
  test_queued_run_is_not_absent
  test_fresh_push_without_a_run_waits
  test_stale_push_without_a_run_is_absent
  test_grace_of_zero_settles_at_once
  test_finished_run_without_checks_is_absent
  test_advisory_run_does_not_hold_the_gate
  test_a_docs_only_head_is_absent_without_waiting_out_the_grace
  test_a_trigger_without_a_filter_keeps_the_head_waiting
  test_a_dispatchable_trigger_keeps_the_head_waiting
  test_a_source_file_in_the_range_keeps_the_head_waiting
  test_an_unreadable_workflow_file_keeps_the_head_waiting
  test_an_unreadable_workflow_list_keeps_the_head_waiting
  test_a_head_without_a_base_sha_is_never_recognized
  test_a_push_trigger_this_branch_reaches_keeps_the_head_waiting
  test_a_branches_ignore_keeps_the_head_waiting
  test_an_event_outside_the_inert_list_keeps_the_head_waiting
  test_the_named_inert_events_do_not_block_the_recognition
  test_a_workflow_added_by_the_range_keeps_the_head_waiting
  test_an_unfiltered_merge_group_does_not_block_the_recognition
  test_a_truncated_workflow_list_keeps_the_head_waiting
  test_a_truncated_provider_sample_keeps_the_head_waiting
  test_a_workflow_only_on_the_base_keeps_the_head_waiting
  test_a_workflow_only_on_the_head_keeps_the_head_waiting
  test_the_range_is_read_once_for_every_workflow
  test_a_workflow_the_list_calls_advisory_is_still_explained
  test_a_capped_workflow_directory_keeps_the_head_waiting
  test_a_second_check_provider_keeps_the_head_waiting
  test_an_advisory_provider_does_not_block_the_recognition
  test_a_sample_without_checks_keeps_the_head_waiting
  test_a_base_side_workflow_edit_keeps_the_head_waiting
  test_a_head_with_a_run_never_consults_the_filter
  test_a_head_past_the_grace_never_consults_the_filter
  test_unreadable_run_list_is_unknown
  test_unreadable_push_time_is_unknown
  test_cancelled_run_is_not_absent
  test_one_finished_run_does_not_bypass_the_grace
  test_old_commit_freshly_pushed_waits
  test_old_commit_and_quiet_pr_is_absent
  test_unreadable_commit_still_decides_on_the_pr_clock
  test_green_over_finished_runs_is_green
  test_green_over_a_queued_sibling_is_not_green
  test_checkless_red_run_is_red
  test_checkless_red_run_outranks_a_green_check
  test_red_checks_never_consult_the_run_list
  test_run_lookup_is_paginated
  test_checkless_red_run_outranks_a_pending_check
  test_checkless_red_run_outranks_a_stopped_check
  test_pending_with_an_unreadable_run_list_is_unknown
  test_non_actions_check_without_runs_keeps_the_grace
  test_non_actions_check_past_the_grace_is_green
  test_superseded_stopped_run_does_not_hold
  test_superseded_red_run_does_not_stay_red
  test_newest_run_of_a_workflow_still_counts
  test_same_second_tie_prefers_the_higher_run_id
  test_future_commit_date_falls_back_to_the_pr_clock
  test_future_commit_date_still_holds_a_fresh_pr
  test_two_events_of_one_workflow_are_two_runs
  test_queued_invocation_survives_a_finished_twin
  test_stopped_checks_with_a_queued_run_keep_waiting
  test_completed_run_without_a_conclusion_is_unjudged
  test_advisory_job_failure_is_not_a_red_run
  test_non_advisory_job_failure_is_a_red_run
  test_unreadable_jobs_keep_the_red
  test_wait_holds_until_the_checks_appear
  test_wait_ceiling_with_a_queued_run_is_no_verdict
)

run_tests "${tests[@]}"
exit "$?"
}
