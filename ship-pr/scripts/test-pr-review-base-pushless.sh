#!/usr/bin/env bash
# Focused fixture tests for `pr-review.sh base` on a default branch whose CI no longer runs on push
# (ludics-lite#401, for ahrefs/ocannl#1057).
#
# A workflow that ran on pushes to the branch and whose file at the tip no longer declares `push`
# leaves its last push runs standing forever — an `event=push` page never ages out — so before
# #401 the fold presented the last push run's verdict, days or months old, as the base's. These
# cases pin the replacement: such a workflow's push rows are history, and the tip's verdict for it
# comes from a NAMED source — an integration record handed in by `fleet-worker.sh gate`, or the
# merged PR's head run under the roll-forward rule, where the tip is GitHub's own clean merge of
# that head — or it is "no verdict", never an older green. The verdict line names the source.
#
# And the other direction, which is half the claim: a workflow whose file at the tip still runs on
# push, or whose file cannot be read for its triggers, reads exactly as before, and a covered tip
# does not so much as read its workflow file.
#
# The fixture transport is test-pr-review-base-lib.sh, shared with the other base suites.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=test-pr-review-lib.sh
source "$SCRIPT_DIR/test-pr-review-lib.sh"
# shellcheck source=test-pr-review-base-lib.sh
source "$SCRIPT_DIR/test-pr-review-base-lib.sh"

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

# The merged PR's head, and the commit the tip was merged onto.
SHA_H=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee

# ocannl's `ci` after #1057: pull requests, a schedule and manual runs — no push.
PUSHLESS_YAML='name: ci
on:
  pull_request:
    paths-ignore:
      - "docs/**"
  # Sunday and Wednesday.
  schedule:
    - cron: "0 3 * * 0,3"
  workflow_dispatch:
jobs:
  build:
    runs-on: ubuntu-latest
'

# pushless_fixture: `ci` has no push trigger at the tip SHA_C, its newest push run is a green at
# SHA_A from before the trigger went, and the tip is GitHub's merge of PR #7, whose head SHA_H has
# a green build signal. Each case then breaks exactly one of those facts.
pushless_fixture() {
  reset_fixture
  WORKFLOW_YAML="$PUSHLESS_YAML"
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:7001}]')")
  COMMIT_META=$(jq -cn --arg b "$SHA_B" --arg h "$SHA_H" \
    '{parents: [{sha: $b}, {sha: $h}],
      commit: {committer: {email: "noreply@github.com"}, verification: {verified: true}}}')
  TIP_PULLS=$(jq -cn --arg c "$SHA_C" --arg h "$SHA_H" \
    '[{number: 7, merged_at: "2026-09-26T08:00:53Z", merge_commit_sha: $c,
       head: {sha: $h, ref: "claude/topic"}, base: {ref: "main"}}]')
  HEAD_PR=$(jq -cn --arg h "$SHA_H" --arg b "$SHA_B" \
    '{head: {sha: $h, ref: "claude/topic"}, base: {sha: $b}, updated_at: "2026-09-26T07:40:00Z"}')
  head_signal '"success"'
}

# head_signal <conclusion as JSON — '"success"', or null for a run still going>:the merged head's one build check and one pull_request run.
head_signal() {
  local concl="$1" status=completed
  [ "$concl" != null ] || status=in_progress
  HEAD_CHECKS=$(jq -cn --argjson c "$concl" \
    '{check_runs: [{name: "build", conclusion: $c, html_url: "https://example.test/check/1"}]}')
  HEAD_RUNS=$(jq -cn --argjson c "$concl" --arg s "$status" \
    '{workflow_runs: [{created_at: "2026-09-26T07:41:00Z", id: 8001, workflow_id: 1,
                       event: "pull_request", name: "ci", status: $s, conclusion: $c}]}')
}

# records <row>...: an integration-records file, one tab-separated row per argument.
records() {
  local file="$TEST_ROOT/records"
  : >"$file"
  local row
  for row in "$@"; do printf '%s\n' "$row" >>"$file"; done
  printf '%s' "$file"
}

# --- source (a): the merged PR's head run, under the roll-forward rule ------------------------
# The shape #1057 creates: the only push run is a green from before the trigger went. Before #401
# this read "green", about SHA_A, forever. Now the tip is GitHub's clean merge of PR #7 and #7's
# head is green, so the tip is green BY THAT SOURCE, and both the verdict line and the workflow's
# own line say which source it was. Plain and under --wait alike: the gate's read is the second.
test_a_clean_merge_of_a_green_head_is_green_by_the_named_source() {
  local wait
  for wait in "" --wait=2; do
    pushless_fixture
    run_base ${wait:+"$wait"}
    assert_eq "$BASE_RC" 0 "a tip GitHub merged cleanly from a green head is green ($wait)"
    assert_contains "$BASE_OUTPUT" \
      "$REPO $BRANCH: green (tip ${SHA_C:0:8}; ci judged by PR #7's head run (roll-forward rule))" \
      "the verdict line names the source it used"
    assert_contains "$BASE_OUTPUT" "source (a): PR #7's head ${SHA_H:0:8}, which GitHub merged cleanly as the tip ${SHA_C:0:8}" \
      "and the workflow's line says what that source established"
    assert_contains "$BASE_OUTPUT" "retired  ci — no push trigger at the tip, so its newest judged push run (success at ${SHA_A:0:8}) is history" \
      "the old push verdict is shown as history, not as the tip's"
    assert_not_contains "$BASE_OUTPUT" "(that verdict is about ${SHA_A:0:8}" \
      "the old push run is not presented as a verdict at all"
  done
}

# The stale green this issue exists to refuse: the tip is not a merge commit at all (a direct
# push, or a squash or rebase merge, which keep no head in the history), so no PR head speaks for
# it — and the old push green must not either. Under --wait the answer comes at once: nothing this
# wait could receive would supply a source, so it does not sit out the ceiling.
test_a_tip_no_source_covers_is_no_verdict_never_the_old_green() {
  pushless_fixture
  COMMIT_META=$(jq -cn --arg b "$SHA_B" \
    '{parents: [{sha: $b}], commit: {committer: {email: "someone@example.test"}, verification: {verified: false}}}')
  run_base --wait=4
  assert_eq "$BASE_RC" 4 "a tip no named source judges has no verdict"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: NO VERDICT (tip ${SHA_C:0:8}) — ci no longer run(s) on push, and no named source has judged the tip" \
    "the headline says why, and that an older verdict is not the tip's"
  assert_contains "$BASE_OUTPUT" "no named source judges the tip: no integration record ran the tip ${SHA_C:0:8}, and the tip ${SHA_C:0:8} is not a merge commit (1 parent(s))" \
    "the workflow's line says which sources were tried and why each failed"
  assert_not_contains "$BASE_OUTPUT" ": green" "no green of any age is handed out"
  assert_eq "$(rounds_polled)" 1 "no source is coming, so the wait does not sit out its ceiling"
  assert_not_contains "$(cat "$REQUEST_LOG")" "/pulls" "a tip that is no merge has no PR to look up"
}

# A merge commit is not enough: one made elsewhere and pushed may carry a conflict resolution the
# head's run never saw. Only GitHub's own merge commit — committer noreply@github.com, signature
# verified — is a clean merge by construction, since GitHub merges only what merges cleanly.
test_a_merge_commit_github_did_not_make_is_not_a_clean_merge() {
  local meta
  for meta in \
    '{"email":"lukstafi@example.test","verified":false}' \
    '{"email":"noreply@github.com","verified":false}'; do
    pushless_fixture
    COMMIT_META=$(jq -cn --arg b "$SHA_B" --arg h "$SHA_H" --argjson m "$meta" \
      '{parents: [{sha: $b}, {sha: $h}],
        commit: {committer: {email: $m.email}, verification: {verified: $m.verified}}}')
    run_base
    assert_eq "$BASE_RC" 4 "a merge GitHub did not make and sign is no roll-forward source ($meta)"
    assert_contains "$BASE_OUTPUT" "is a merge commit GitHub did not make" "and the line says so"
  done
}

# The PR must be the one whose merge IS the tip, into this branch, with the head the merge carries.
test_the_pr_must_be_the_one_the_tip_merged() {
  pushless_fixture
  TIP_PULLS='[]'
  run_base
  assert_eq "$BASE_RC" 4 "a tip no merged PR names as its merge commit has no PR head to read"
  assert_contains "$BASE_OUTPUT" "no single merged pull request has the tip ${SHA_C:0:8} as its merge commit" \
    "the line names what was missing"
  pushless_fixture
  TIP_PULLS=$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{number: 7, merged_at: "2026-09-26T08:00:53Z", merge_commit_sha: $c,
       head: {sha: $a, ref: "claude/topic"}, base: {ref: "main"}}]')
  run_base
  assert_eq "$BASE_RC" 4 "a PR whose head is not the merge's second parent is not what the tip merged"
  assert_contains "$BASE_OUTPUT" "is not the merge's second parent" "and the line says so"
  assert_not_contains "$(cat "$REQUEST_LOG")" "check-runs" "no head is judged for a PR that did not make the tip"
  pushless_fixture
  TIP_PULLS=$(jq -cn --arg c "$SHA_C" --arg h "$SHA_H" \
    '[{number: 7, merged_at: "2026-09-26T08:00:53Z", merge_commit_sha: $c,
       head: {sha: $h, ref: "claude/topic"}, base: {ref: "release"}}]')
  run_base
  assert_eq "$BASE_RC" 4 "a PR merged into another branch does not speak for this one"
}

# The head's red is the tip's red under the same rule that made its green the tip's green, and
# it is a verdict: RED, exit 1, naming the source — never the old push green beneath it.
test_a_red_head_is_a_red_tip() {
  pushless_fixture
  head_signal '"failure"'
  run_base --wait=4
  assert_eq "$BASE_RC" 1 "the merged head's red is the tip's verdict"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH is RED" "and it headlines as red"
  assert_contains "$BASE_OUTPUT" "RED      ci — source (a): PR #7's head ${SHA_H:0:8}" \
    "naming the source"
  assert_eq "$(rounds_polled)" 1 "a red at the tip ends the wait on the round that saw it"
}

# A head whose run is still going is a source not yet in: the plain read says no verdict, and
# --wait keeps waiting for it (to its ceiling here), exactly as it would for a run in flight.
test_a_head_still_running_holds_the_wait() {
  pushless_fixture
  head_signal null
  run_base
  assert_eq "$BASE_RC" 4 "a head still running is no verdict yet"
  assert_contains "$BASE_OUTPUT" "no verdict  ci — not yet: source (a): PR #7's head ${SHA_H:0:8}" \
    "the line names the source it is waiting on"
  pushless_fixture
  head_signal null
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "at the ceiling a source still judging is no verdict"
  assert_contains "$BASE_OUTPUT" "NO VERDICT" "and says so"
  [ "$(rounds_polled)" -ge 2 ] || bail "a source still judging should hold the wait past one round (polled $(rounds_polled))"
}

# --- source (b): an integration record handed in by the gate ----------------------------------
# A coordinator's run concluded at exactly the tip judges the tip's own tree, so it goes first:
# a pass is green without a single PR read, and a fail is RED even over a green PR head.
test_an_integration_record_at_the_tip_is_the_first_source() {
  local file
  pushless_fixture
  file=$(records "$SHA_C	pass	w-integration-1	2026-09-26T09:00:00.000001+00:00")
  run_base --integration-records "$file"
  assert_eq "$BASE_RC" 0 "a passed integration record at the tip is green"
  assert_contains "$BASE_OUTPUT" "green (tip ${SHA_C:0:8}; ci judged by integration record w-integration-1)" \
    "the verdict line names the record"
  assert_not_contains "$(cat "$REQUEST_LOG")" "/pulls" "the record answered, so no PR is read"
  pushless_fixture
  file=$(records \
    "$SHA_C	pass	w-integration-1	2026-09-26T09:00:00+00:00" \
    "$SHA_C	fail	w-integration-2	2026-09-26T10:00:00+00:00")
  run_base "--integration-records=$file"
  assert_eq "$BASE_RC" 1 "the NEWEST record at the tip is its verdict, and it failed"
  assert_contains "$BASE_OUTPUT" "integration record w-integration-2 ran the tip ${SHA_C:0:8} and concluded fail" \
    "naming which record"
}

# A record about any other commit is not about the tip, and the next source answers.
test_a_record_at_another_commit_is_not_the_tips() {
  local file
  pushless_fixture
  file=$(records "$SHA_B	fail	w-integration-0	2026-09-26T09:00:00+00:00")
  run_base --integration-records "$file"
  assert_eq "$BASE_RC" 0 "a record at the tip's parent says nothing about the tip; its PR head does"
  assert_contains "$BASE_OUTPUT" "judged by PR #7's head run" "source (a) answered"
}

# A records file the gate hands in is refused WHOLE when any row does not parse: skipping a row
# could skip the red that was the tip's answer.
test_a_malformed_records_file_is_refused() {
  local file
  pushless_fixture
  file=$(records "$SHA_C	pass	w-integration-1	2026-09-26T09:00:00+00:00" "$SHA_C maybe w-2 now")
  run_base --integration-records "$file"
  assert_eq "$BASE_RC" 2 "a row that does not parse refuses the read"
  assert_contains "$BASE_OUTPUT" "--integration-records: a row is not" "and says what shape it wanted"
  run_base --integration-records "$TEST_ROOT/no-such-file"
  assert_eq "$BASE_RC" 2 "an unreadable records file refuses the read"
}

# --- the other direction: repositories that still run on push --------------------------------
# A workflow whose file at the tip still declares push reads exactly as before #401: an older
# verdict under a tip with no run of its own is still that older verdict, named as such, and no
# PR is looked up. And a covered tip does not read the workflow file at all.
test_a_workflow_that_still_runs_on_push_reads_as_before() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:7101}]')")
  run_base
  assert_eq "$BASE_RC" 0 "the plain read settles for the older verdict, as it always has"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" "with the old verdict line"
  assert_contains "$BASE_OUTPUT" "(that verdict is about ${SHA_A:0:8}, not the tip ${SHA_C:0:8})" \
    "naming the commit it is about"
  assert_not_contains "$BASE_OUTPUT" "retired" "a push workflow is not set aside"
  assert_not_contains "$(cat "$REQUEST_LOG")" "/pulls" "no named source is consulted"
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" '[{conclusion:"success", head_sha:$c, id:7102}]')")
  run_base --wait=2
  assert_eq "$BASE_RC" 0 "a tip with its own run is green"
  assert_not_contains "$(cat "$REQUEST_LOG")" "contents/" "and its workflow file is never read"
}

# A file the narrow trigger reader refuses (a tab here) is read as a push workflow, as before,
# and says so — the one direction every doubt about a file is allowed to take.
test_a_file_the_reader_refuses_is_read_as_a_push_workflow() {
  pushless_fixture
  WORKFLOW_YAML=$'on:\n\tpull_request:\n'
  run_base
  assert_eq "$BASE_RC" 0 "an unreadable file keeps the old reading"
  assert_contains "$BASE_OUTPUT" "(that verdict is about ${SHA_A:0:8}, not the tip ${SHA_C:0:8})" \
    "the old verdict line, as before"
  assert_contains "$BASE_OUTPUT" "(ci's file at the tip could not be read for its triggers, so it is read as a push workflow)" \
    "and a note that it was not read"
  assert_not_contains "$(cat "$REQUEST_LOG")" "/pulls" "no named source is consulted"
}

# A read of the file that outlives its retries is UNKNOWN, not a guess in either direction.
test_a_file_read_that_fails_is_unknown() {
  pushless_fixture
  retune API_ATTEMPTS=1
  FAIL_ENDPOINT="repos/$REPO/contents/*"
  run_base
  assert_eq "$BASE_RC" 3 "an unread trigger is UNKNOWN"
  assert_contains "$BASE_OUTPUT" "whether it still runs on push is UNKNOWN" "and says what is unknown"
}

# Mixed, as ocannl will be: its gh-pages deploy keeps its push trigger while `ci` drops it. The
# push workflow's own green at the tip does not speak for `ci`, so without a source the tip has
# no verdict; with one it is green, the push workflow's line unchanged beside it.
test_a_push_workflow_green_at_the_tip_does_not_speak_for_a_retired_one() {
  pushless_fixture
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"pages"}]')
  RUNS_2=$(runs_json 2 "$(jq -cn --arg c "$SHA_C" '[{conclusion:"success", head_sha:$c, id:7201, name:"pages"}]')")
  COMMIT_META=$(jq -cn --arg b "$SHA_B" '{parents: [{sha: $b}]}')
  run_base
  assert_eq "$BASE_RC" 4 "a push workflow's green at the tip is not the retired workflow's verdict"
  assert_contains "$BASE_OUTPUT" "green    pages — success at ${SHA_C:0:8}" "the push workflow reads as before"
  pushless_fixture
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"pages"}]')
  RUNS_2=$(runs_json 2 "$(jq -cn --arg c "$SHA_C" '[{conclusion:"success", head_sha:$c, id:7202, name:"pages"}]')")
  run_base --wait=2
  assert_eq "$BASE_RC" 0 "with a source for the retired workflow, the tip is green"
  assert_contains "$BASE_OUTPUT" "green (tip ${SHA_C:0:8}; ci judged by PR #7's head run (roll-forward rule))" \
    "naming the source for the workflow that needed one"
}

tests=(
  test_a_clean_merge_of_a_green_head_is_green_by_the_named_source
  test_a_tip_no_source_covers_is_no_verdict_never_the_old_green
  test_a_merge_commit_github_did_not_make_is_not_a_clean_merge
  test_the_pr_must_be_the_one_the_tip_merged
  test_a_red_head_is_a_red_tip
  test_a_head_still_running_holds_the_wait
  test_an_integration_record_at_the_tip_is_the_first_source
  test_a_record_at_another_commit_is_not_the_tips
  test_a_malformed_records_file_is_refused
  test_a_workflow_that_still_runs_on_push_reads_as_before
  test_a_file_the_reader_refuses_is_read_as_a_push_workflow
  test_a_file_read_that_fails_is_unknown
  test_a_push_workflow_green_at_the_tip_does_not_speak_for_a_retired_one
)

run_tests "${tests[@]}"
exit "$?"
}
