#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's merge-time base-drift file intersection.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
HELPER="$SCRIPT_DIR/pr-review.sh"
TEST_ROOT=$(mktemp -d "/tmp/pr-review-base-drift-test.XXXXXX") || exit 1
trap 'case "$TEST_ROOT" in /tmp/pr-review-base-drift-test.*) rm -rf "$TEST_ROOT" ;; esac' EXIT

export SHIP_PR_TEST_SOURCE_ONLY=1
export SHIP_PR_STATE_DIR=off
export SHIP_PR_API_ATTEMPTS=1
export SHIP_PR_API_BACKOFF=0
export SHIP_PR_STALE_BASE=20
# shellcheck source=pr-review.sh
source "$HELPER"
# pr-review.sh installs its own EXIT trap. Preserve that cleanup and restore this test's temporary
# root cleanup after sourcing it.
trap 'rm -f "$GH_ERR_FILE"; case "$TEST_ROOT" in /tmp/pr-review-base-drift-test.*) rm -rf "$TEST_ROOT" ;; esac' EXIT

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

# Not `fail`: pr-review.sh is sourced above and its refusals call ITS fail, whose exit code these
# tests read; a same-named helper here would turn every refusal into this reporter's 1.
bail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || bail "$3 (got '$1', expected '$2')"
}

assert_contains() {
  case "$1" in *"$2"*) ;; *) bail "$3 (missing '$2' in: $1)" ;; esac
}

assert_not_contains() {
  case "$1" in *"$2"*) bail "$3 (unexpected '$2' in: $1)" ;; *) ;; esac
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

# Minimal gh fixture transport. It honours --jq because the PR metadata read asks gh to format its
# stable base/head snapshot, while compare responses are deliberately parsed by local jq.
gh() {
  local endpoint="" filter="" response="" arg
  [ "${1:-}" = api ] || bail "fixture received non-api gh call: $*"
  shift
  endpoint="${1:-}"
  shift || true
  while [ $# -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
    --jq)
      filter="${1:-}"
      shift || true
      ;;
    esac
  done
  printf '%s\n' "$endpoint" >>"$REQUEST_LOG"
  case "$endpoint" in
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
  *) bail "unexpected fixture endpoint: $endpoint" ;;
  esac
  if [ -n "$filter" ]; then
    jq -r "$filter" <<<"$response"
  else
    printf '%s\n' "$response"
  fi
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

tests=(
  test_no_overlap
  test_exact_overlap
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

for test_name in "${tests[@]}"; do
  "$test_name"
  echo "PASS: $test_name"
done
