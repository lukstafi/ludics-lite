#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's merge-time base-drift file intersection.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
export SHIP_PR_STALE_BASE=20 # read when pr-review.sh is sourced, so before the preamble
# shellcheck source=test-pr-review-lib.sh
source "$SCRIPT_DIR/test-pr-review-lib.sh"
test_tmpdir TEST_ROOT base-drift-test

REPO=example/repo
REQUEST_LOG="$TEST_ROOT/requests"
# The PR's base.sha is a STALE snapshot on purpose (ludics-lite#44): it is the base as of the last
# merge commit GitHub could build, and the drift read must not compare against it. The base's
# real tip is what the branch read below answers.
BASE_REF=main
MERGEABLE_STATE=clean
FORWARD_JSON=""
REVERSE_JSON=""
FAIL_DIRECTION=""
FAIL_TIP=""

pr_json() {
  jq -cn --arg ref "$BASE_REF" --arg m "$MERGEABLE_STATE" \
    '{base:{ref:$ref,sha:"stale-base-sha"},head:{label:"fork-owner:topic",sha:"head-sha"},mergeable_state:$m}'
}

compare_json() {
  jq -cn --argjson behind "$1" --argjson ahead "$2" --argjson files "$3" \
    '{behind_by:$behind, ahead_by:$ahead, merge_base_commit:{sha:"merge-base-sha"}, files:$files}'
}

set_compares() {
  FORWARD_JSON=$(compare_json "$1" "$2" "$3")
  REVERSE_JSON=$(compare_json "$2" "$1" "$4")
  FAIL_DIRECTION=""
  FAIL_TIP=""
  BASE_REF=main
  MERGEABLE_STATE=clean
  : >"$REQUEST_LOG"
  STALE_BASE=20
}

# Minimal gh fixture transport. The --jq filter matters here: the PR metadata read asks gh to
# format its stable base/head snapshot, while compare responses are deliberately parsed by local
# jq.
gh() {
  local response=""
  gh_fixture_parse "$@"
  case "$FIXTURE_ENDPOINT" in
  "repos/$REPO/pulls/7") response=$(pr_json) ;;
  # The base branch's tip: what the compares must be anchored on. A compare against the PR's
  # stale-base-sha snapshot has no fixture and bails below, which is the point.
  "repos/$REPO/commits/main" | "repos/$REPO/commits/wip%20x")
    if [ -n "$FAIL_TIP" ]; then
      echo "gh: commit unavailable (HTTP 500)" >&2
      return 1
    fi
    response='{"sha":"base-sha"}'
    ;;
  "repos/$REPO/compare/base-sha...head-sha?per_page=1")
    if [ "$FAIL_DIRECTION" = forward ]; then
      echo "gh: compare unavailable (HTTP 500)" >&2
      return 1
    fi
    response="$FORWARD_JSON"
    ;;
  "repos/$REPO/compare/head-sha...base-sha?per_page=1")
    if [ "$FAIL_DIRECTION" = reverse ]; then
      echo "gh: compare unavailable (HTTP 500)" >&2
      return 1
    fi
    response="$REVERSE_JSON"
    ;;
  *) bail "unexpected fixture endpoint: $FIXTURE_ENDPOINT" ;;
  esac
  gh_fixture_answer "$response"
}

run_drift() {
  local capture rc
  set +e
  capture=$(warn_base_drift 7 2>&1)
  rc=$?
  set -e
  DRIFT_OUTPUT="$capture"
  DRIFT_RC="$rc"
}

test_no_overlap() {
  set_compares 2 1 '[{"filename":"pr.txt"}]' '[{"filename":"base.txt"}]'
  run_drift
  assert_eq "$DRIFT_RC" 0 "no overlap below the threshold should be fresh"
  assert_contains "$DRIFT_OUTPUT" "base-drift file overlap $REPO#7: none" \
    "known empty overlap should say none"
  assert_not_contains "$DRIFT_OUTPUT" "UNKNOWN" "known empty overlap should not be unknown"
}

test_exact_overlap() {
  set_compares 2 1 '[{"filename":"pr.txt"},{"filename":"shared.txt"}]' \
    '[{"filename":"shared.txt"},{"filename":"base.txt"}]'
  run_drift
  assert_eq "$DRIFT_RC" 1 "an exact overlap should warn"
  assert_contains "$DRIFT_OUTPUT" "[\"shared.txt\"]" "only the exact common path should print"
  assert_not_contains "$DRIFT_OUTPUT" "base.txt\"]" "base-only path should not print"
}

test_spaces() {
  set_compares 2 1 '[{"filename":"dir/a file.txt"}]' '[{"filename":"dir/a file.txt"}]'
  run_drift
  assert_eq "$DRIFT_RC" 1 "an overlap containing spaces should warn"
  assert_contains "$DRIFT_OUTPUT" "[\"dir/a file.txt\"]" \
    "a path containing spaces should remain one JSON string"
}

test_rename_previous_filename() {
  set_compares 2 1 '[{"filename":"new name.txt","previous_filename":"old name.txt"}]' \
    '[{"filename":"old name.txt"}]'
  run_drift
  assert_eq "$DRIFT_RC" 1 "a base edit of a PR rename's old path should overlap"
  assert_contains "$DRIFT_OUTPUT" "[\"old name.txt\"]" \
    "previous_filename should participate in the intersection"
}

test_api_failure_is_unknown() {
  local direction
  for direction in forward reverse; do
    set_compares 2 1 '[{"filename":"pr.txt"}]' '[{"filename":"base.txt"}]'
    FAIL_DIRECTION="$direction"
    run_drift
    assert_eq "$DRIFT_RC" 3 "a failed $direction compare should be unknown"
    assert_contains "$DRIFT_OUTPUT" "base-drift file overlap $REPO#7: UNKNOWN" \
      "$direction API failure should print UNKNOWN"
    assert_not_contains "$DRIFT_OUTPUT" "overlap $REPO#7: none" \
      "$direction API failure must not print a reassuring none"
  done
}

test_truncated_data_is_unknown() {
  local capped direction
  capped=$(jq -cn '[range(0; 300) | {filename:("file-" + tostring)}]')
  for direction in forward reverse; do
    if [ "$direction" = forward ]; then
      set_compares 2 1 "$capped" '[{"filename":"unrelated.txt"}]'
    else
      set_compares 2 1 '[{"filename":"unrelated.txt"}]' "$capped"
    fi
    run_drift
    assert_eq "$DRIFT_RC" 3 "a potentially truncated $direction file list should be unknown"
    assert_contains "$DRIFT_OUTPUT" "300-file cap" \
      "$direction truncation reason should be explicit"
    assert_not_contains "$DRIFT_OUTPUT" "overlap $REPO#7: none" \
      "potential $direction truncation must not print none"
  done
}

test_malformed_file_entry_is_unknown() {
  local direction
  for direction in forward reverse; do
    if [ "$direction" = forward ]; then
      set_compares 2 1 '[{}]' '[{"filename":"base.txt"}]'
    else
      set_compares 2 1 '[{"filename":"pr.txt"}]' '[{"filename":null}]'
    fi
    run_drift
    assert_eq "$DRIFT_RC" 3 "a malformed $direction file entry should be unknown"
    assert_contains "$DRIFT_OUTPUT" "base-drift file overlap $REPO#7: UNKNOWN" \
      "malformed $direction data should print UNKNOWN"
    assert_not_contains "$DRIFT_OUTPUT" "overlap $REPO#7: none" \
      "malformed $direction data must not print none"
  done
}

test_json_escapes_survive_xpg_echo() {
  set_compares 2 1 '[{"filename":"dir/a\tb.txt"}]' '[{"filename":"dir/a\tb.txt"}]'
  shopt -s xpg_echo
  run_drift
  shopt -u xpg_echo
  assert_eq "$DRIFT_RC" 1 "a tab-bearing overlap should warn"
  assert_contains "$DRIFT_OUTPUT" '["dir/a\tb.txt"]' \
    "JSON escapes should remain printable under xpg_echo"
}

test_fork_head_uses_snapshot_shas() {
  set_compares 2 1 '[{"filename":"pr.txt"}]' '[{"filename":"base.txt"}]'
  run_drift
  assert_eq "$DRIFT_RC" 0 "fork-labelled PR with no overlap should be fresh"
  assert_contains "$(cat "$REQUEST_LOG")" \
    "repos/$REPO/compare/base-sha...head-sha?per_page=1" \
    "forward compare should use the head SHA and the base's tip SHA"
  assert_contains "$(cat "$REQUEST_LOG")" \
    "repos/$REPO/compare/head-sha...base-sha?per_page=1" \
    "reverse compare should use the head SHA and the base's tip SHA"
  assert_not_contains "$(cat "$REQUEST_LOG")" "fork-owner:topic" \
    "a fork's mutable head label should not enter compare URLs"
}

test_base_tip_not_the_pr_snapshot() {
  set_compares 7 15 '[{"filename":"pr.txt"}]' '[{"filename":"base.txt"}]'
  run_drift
  assert_eq "$DRIFT_RC" 0 "a branch behind a tip the snapshot does not know should read cleanly"
  assert_contains "$DRIFT_OUTPUT" "7 commit(s) behind main, 15 ahead" \
    "the count should be against the base's tip, which the PR's base.sha snapshot is not"
  assert_contains "$(cat "$REQUEST_LOG")" "repos/$REPO/commits/main" \
    "the base's tip should be read from the branch"
  assert_not_contains "$(cat "$REQUEST_LOG")" "stale-base-sha" \
    "the PR's base.sha snapshot must not anchor a compare"
}

test_tip_read_failure_is_unknown() {
  set_compares 2 1 '[{"filename":"pr.txt"}]' '[{"filename":"base.txt"}]'
  FAIL_TIP=1
  run_drift
  assert_eq "$DRIFT_RC" 3 "an unreadable base tip should be unknown"
  assert_contains "$DRIFT_OUTPUT" "base-drift file overlap $REPO#7: UNKNOWN" \
    "an unreadable tip should print UNKNOWN"
  assert_not_contains "$DRIFT_OUTPUT" "overlap $REPO#7: none" \
    "an unreadable tip must not print a reassuring none"
  assert_not_contains "$(cat "$REQUEST_LOG")" "compare/" \
    "no compare should be attempted without a tip to anchor it"
}

test_dirty_pr_is_loud() {
  set_compares 7 15 '[{"filename":"pr.txt"}]' '[{"filename":"base.txt"}]'
  MERGEABLE_STATE=dirty
  run_drift
  assert_eq "$DRIFT_RC" 1 "a conflicted PR should warn even with no file overlap"
  assert_contains "$DRIFT_OUTPUT" "!!! $REPO#7 CONFLICTS with main (mergeable_state=dirty)" \
    "a dirty mergeable_state should be said loudly"
  assert_contains "$DRIFT_OUTPUT" "head-sh merged with the current main" \
    "the conflict warning should say what it costs: nothing tests the head merged with the base"
  assert_not_contains "$DRIFT_OUTPUT" "no pull_request workflow has run" \
    "a run that completed before the base moved may exist: do not claim nothing ran"
  assert_contains "$DRIFT_OUTPUT" "7 commit(s) behind main" \
    "the count should still be read on a conflicted PR"
}

test_computing_mergeability_is_not_a_conflict() {
  set_compares 2 1 '[{"filename":"pr.txt"}]' '[{"filename":"base.txt"}]'
  MERGEABLE_STATE=unknown
  run_drift
  assert_eq "$DRIFT_RC" 0 "GitHub still computing mergeability is not a conflict"
  assert_not_contains "$DRIFT_OUTPUT" "CONFLICTS" "an unknown mergeable_state must not claim a conflict"
}

test_base_ref_is_encoded() {
  set_compares 2 1 '[{"filename":"pr.txt"}]' '[{"filename":"base.txt"}]'
  BASE_REF='wip x'
  run_drift
  assert_eq "$DRIFT_RC" 0 "a base ref needing encoding should still read"
  assert_contains "$(cat "$REQUEST_LOG")" "repos/$REPO/commits/wip%20x" \
    "the base ref should be percent-encoded in the tip read"
}

test_overlap_below_stale_threshold_is_loud() {
  set_compares 1 1 '[{"filename":"shared.txt"}]' '[{"filename":"shared.txt"}]'
  STALE_BASE=20
  run_drift
  assert_eq "$DRIFT_RC" 1 "overlap below SHIP_PR_STALE_BASE should still warn"
  assert_contains "$DRIFT_OUTPUT" "!!! BASE-DRIFT FILE OVERLAP" \
    "below-threshold overlap should be loud"
  assert_not_contains "$DRIFT_OUTPUT" "COMMITS BEHIND" \
    "below-threshold count should not trigger the count warning"
}

# Hunks: the compare response carries each file's patch, and the read splits an overlapping path by
# whether the two sides' old-side ranges meet (ludics-lite#54). Both compares share a merge base,
# so a forward hunk and a reverse hunk are ranges of the same text.
# [patched name patch [additions deletions]]: the counts default to what the patch shows, as a
# complete patch from the API has them; given explicitly, they model GitHub's whole-diff counts
# disagreeing with a patch cut between hunks.
patched() {
  jq -cn --arg name "$1" --arg patch "$2" --arg add "${3:-}" --arg del "${4:-}" '
    ($patch | split("\n")) as $lines
    | {filename: $name, patch: $patch,
       additions: (if $add == "" then ([$lines[] | select(startswith("+"))] | length) else ($add | tonumber) end),
       deletions: (if $del == "" then ([$lines[] | select(startswith("-"))] | length) else ($del | tonumber) end)}'
}

test_disjoint_hunks_are_not_loud() {
  set_compares 2 1 "[$(patched dune $'@@ -400,0 +401,2 @@\n+(test\n+ (name mine))')]" \
    "[$(patched dune $'@@ -120,0 +121,2 @@\n+(test\n+ (name theirs))')]"
  run_drift
  assert_eq "$DRIFT_RC" 0 "a shared path edited in disjoint hunks is nothing to act on"
  assert_contains "$DRIFT_OUTPUT" "all in DISJOINT hunks" "the line should say the hunks are disjoint"
  assert_contains "$DRIFT_OUTPUT" "[\"dune\"]" "the disjoint path should still be named"
  assert_not_contains "$DRIFT_OUTPUT" "!!!" "disjoint hunks earn no alarm"
  assert_not_contains "$DRIFT_OUTPUT" "Rebase" "a disjoint overlap suggests no rebase"
}

test_meeting_hunks_state_the_policy() {
  set_compares 2 1 "[$(patched README.md $'@@ -10,2 +10,3 @@\n context\n-old\n+new\n+newer')]" \
    "[$(patched README.md $'@@ -12,1 +12,1 @@\n-was\n+is')]"
  run_drift
  assert_eq "$DRIFT_RC" 1 "the same region edited on both sides should warn"
  assert_contains "$DRIFT_OUTPUT" "!!! BASE-DRIFT FILE OVERLAP: the base's advance touched the SAME REGIONS" \
    "meeting hunks should be loud and say what they are"
  assert_contains "$DRIFT_OUTPUT" "roll-forward policy" \
    "the guidance is the policy the merge follows, not an instruction the merge then ignores"
  assert_contains "$DRIFT_OUTPUT" "only if you want CI to test this head" \
    "the rebase is offered as an option, never as a prerequisite"
  assert_not_contains "$DRIFT_OUTPUT" "let checks re-run" \
    "the wording six wave workers read as an unmet instruction is gone"
}

test_adjacent_hunks_meet() {
  # Line 5 edited on one side, line 6 on the other: git merges it, a reader still wants to look.
  set_compares 2 1 "[$(patched a.txt $'@@ -5,1 +5,1 @@\n-x\n+y')]" \
    "[$(patched a.txt $'@@ -6,1 +6,1 @@\n-p\n+q')]"
  run_drift
  assert_eq "$DRIFT_RC" 1 "adjacent hunks count as meeting"
  assert_contains "$DRIFT_OUTPUT" "SAME REGIONS" "adjacent hunks should be reported as meeting"
}

test_mixed_paths_split_by_hunks() {
  set_compares 2 1 \
    "[$(patched dune $'@@ -400,0 +401,2 @@\n+a\n+b'),$(patched shared.ml $'@@ -3,1 +3,1 @@\n-a\n+b')]" \
    "[$(patched dune $'@@ -120,0 +121,2 @@\n+c\n+d'),$(patched shared.ml $'@@ -4,1 +4,1 @@\n-a\n+b')]"
  run_drift
  assert_eq "$DRIFT_RC" 1 "one meeting path is enough to warn"
  assert_contains "$DRIFT_OUTPUT" "SAME REGIONS of 1 path(s)" "only the meeting path counts as such"
  assert_contains "$DRIFT_OUTPUT" "[\"shared.ml\"]" "the meeting path is named"
  assert_contains "$DRIFT_OUTPUT" "1 more path(s) in disjoint hunks only: [\"dune\"]" \
    "the disjoint path is listed apart"
}

test_truncated_patch_is_unread() {
  # The header promises three old-side lines and the patch stops after one: GitHub cut it short,
  # and whatever hunk followed is unknown — unread, not disjoint.
  set_compares 2 1 "[$(patched big.ml $'@@ -10,3 +10,4 @@\n context')]" \
    "[$(patched big.ml $'@@ -400,1 +400,1 @@\n-a\n+b')]"
  run_drift
  assert_eq "$DRIFT_RC" 1 "a truncated patch stays loud"
  assert_contains "$DRIFT_OUTPUT" "hunks unread for 1 of them" "a truncated patch is reported unread"
  assert_not_contains "$DRIFT_OUTPUT" "DISJOINT hunks (" "a truncated patch must never read as disjoint"
}

test_boundary_truncated_patch_is_unread() {
  # One complete hunk retained, but the entry counts three additions: a later hunk was cut off.
  set_compares 2 1 "[$(patched big.ml $'@@ -10,1 +10,1 @@\n-a\n+b' 3 1)]" \
    "[$(patched big.ml $'@@ -400,1 +400,1 @@\n-a\n+b')]"
  run_drift
  assert_eq "$DRIFT_RC" 1 "a patch whose totals fall short of the entry counts stays loud"
  assert_contains "$DRIFT_OUTPUT" "hunks unread for 1 of them" \
    "a patch cut between hunks is reported unread"
  assert_not_contains "$DRIFT_OUTPUT" "DISJOINT hunks (" \
    "a patch cut between hunks must never read as disjoint"
}

test_count_omitted_headers_are_read() {
  # git omits the count on a one-line side: `@@ -5 +5,2 @@` and `@@ -5,2 +5 @@` are the shapes
  # where the header regex's two optional groups carry meaning, and all four combinations of
  # present and omitted appear across these two patches. compare_hunks matches the header ONCE;
  # a `test` guarding a second, near-identical `capture` would only have to disagree on a shape
  # like this for the capture to yield no output, and a zero-output sub-expression collapses the
  # whole fold to null — a patch that WAS read comes back as unread. A header the read silently
  # skips instead leaves the file with no ranges at all, which reads as disjoint. Both failures
  # are excluded here: these two hunks start on the same line, so only ranges actually derived
  # from these headers can produce the meeting verdict.
  set_compares 2 1 "[$(patched a.txt $'@@ -5 +5,2 @@\n-x\n+y\n+z')]" \
    "[$(patched a.txt $'@@ -5,2 +5 @@\n-p\n-q\n+r')]"
  run_drift
  assert_eq "$DRIFT_RC" 1 "count-omitted headers must still place the hunks, and these meet"
  assert_contains "$DRIFT_OUTPUT" "SAME REGIONS" \
    "a count-omitted header must yield a range like any other"
  assert_not_contains "$DRIFT_OUTPUT" "hunks unread" \
    "a header shape the read handles must never come back as unread"
  # The same shapes, hunks far apart: the range a count-omitted side yields is one line, not the
  # rest of the file, so this half of the pair must still read as disjoint.
  set_compares 2 1 "[$(patched a.txt $'@@ -5 +5,2 @@\n-x\n+y\n+z')]" \
    "[$(patched a.txt $'@@ -40,2 +40 @@\n-p\n-q\n+r')]"
  run_drift
  assert_eq "$DRIFT_RC" 0 "count-omitted headers forty lines apart are disjoint"
  assert_contains "$DRIFT_OUTPUT" "all in DISJOINT hunks" \
    "an omitted count is one line, not an unbounded range"
}

test_unread_hunks_count_as_meeting() {
  # No patch on the base side (binary, or past GitHub's size cap): unread is not disjoint.
  set_compares 2 1 "[$(patched img.bin $'@@ -1,1 +1,1 @@\n-a\n+b')]" '[{"filename":"img.bin"}]'
  run_drift
  assert_eq "$DRIFT_RC" 1 "a path whose hunks could not be read stays loud"
  assert_contains "$DRIFT_OUTPUT" "hunks unread for 1 of them" "the line should say the hunks were not read"
  assert_not_contains "$DRIFT_OUTPUT" "DISJOINT hunks (" "unread hunks must never read as disjoint"
}

tests=(
  test_no_overlap
  test_exact_overlap
  test_disjoint_hunks_are_not_loud
  test_meeting_hunks_state_the_policy
  test_adjacent_hunks_meet
  test_mixed_paths_split_by_hunks
  test_truncated_patch_is_unread
  test_boundary_truncated_patch_is_unread
  test_unread_hunks_count_as_meeting
  test_count_omitted_headers_are_read
  test_spaces
  test_rename_previous_filename
  test_api_failure_is_unknown
  test_truncated_data_is_unknown
  test_malformed_file_entry_is_unknown
  test_json_escapes_survive_xpg_echo
  test_fork_head_uses_snapshot_shas
  test_overlap_below_stale_threshold_is_loud
  test_base_tip_not_the_pr_snapshot
  test_tip_read_failure_is_unknown
  test_dirty_pr_is_loud
  test_computing_mergeability_is_not_a_conflict
  test_base_ref_is_encoded
)

run_tests "${tests[@]}"
