#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's `status` state line — the mergeability that rides on
# every state and turns "the next move is yours" into "merge the base in first" — and for `watch`
# reading the base drift the moment a round lands rather than at merge time (ludics-lite#44).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
HELPER="$SCRIPT_DIR/pr-review.sh"
TEST_ROOT=$(mktemp -d "/tmp/pr-review-status-test.XXXXXX") || exit 1
trap 'case "$TEST_ROOT" in /tmp/pr-review-status-test.*) rm -rf "$TEST_ROOT" ;; esac' EXIT

export SHIP_PR_TEST_SOURCE_ONLY=1
export SHIP_PR_STATE_DIR=off
export SHIP_PR_API_ATTEMPTS=1
export SHIP_PR_API_BACKOFF=0
# shellcheck source=pr-review.sh
source "$HELPER"
# pr-review.sh installs its own EXIT trap. Preserve that cleanup and restore this test's temporary
# root cleanup after sourcing it.
trap 'rm -f "$GH_ERR_FILE"; case "$TEST_ROOT" in /tmp/pr-review-status-test.*) rm -rf "$TEST_ROOT" ;; esac' EXIT

REPO=example/repo
REQUEST_LOG="$TEST_ROOT/requests"
REACTIONS_JSON='[]'
REVIEWS_JSON='[]'
COMMENTS_JSON='[]'
HEAD_SHA=head-sha
MERGEABLE_STATE=clean
FAIL_PULLS=""
PUSH_ON_REVIEWS_READ=""
PAST=2026-09-01T00:00:00Z

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

reset_fixture() {
  REACTIONS_JSON='[]'
  REVIEWS_JSON='[]'
  COMMENTS_JSON='[]'
  HEAD_SHA=head-sha
  MERGEABLE_STATE=clean
  FAIL_PULLS=""
  PUSH_ON_REVIEWS_READ=""
  rm -f "$TEST_ROOT/pushed"
  : >"$REQUEST_LOG"
}

reaction() { # <content> <created_at>
  jq -cn --arg c "$1" --arg at "$2" --arg rev "$REVIEWER" \
    '{user:{login:($rev + "[bot]")}, content:$c, created_at:$at}'
}

review() { # <id> <commit> <submitted_at>
  jq -cn --argjson id "$1" --arg sha "$2" --arg at "$3" --arg rev "$REVIEWER" \
    '{id:$id, user:{login:($rev + "[bot]")}, state:"COMMENTED", commit_id:$sha,
      submitted_at:$at, body:"findings"}'
}

verdict_comment() { # <id> <sha> <created_at>
  jq -cn --argjson id "$1" --arg sha "$2" --arg at "$3" --arg rev "$REVIEWER" \
    '{id:$id, user:{login:($rev + "[bot]")}, created_at:$at, updated_at:$at,
      body:("Codex Review: Didn'"'"'t find any major issues.\n**Reviewed commit:** `" + $sha + "`")}'
}

compare_json() { # <behind> <ahead> <file>
  jq -cn --argjson behind "$1" --argjson ahead "$2" --arg f "$3" \
    '{behind_by:$behind, ahead_by:$ahead, merge_base_commit:{sha:"merge-base-sha"},
      files:[{filename:$f}]}'
}

# Minimal gh fixture transport for every feed `status` and `watch` read. It honours --jq because
# the PR read asks gh to format its head/mergeability snapshot, and ignores --paginate (one page
# is the whole feed).
gh() {
  local endpoint="" filter="" response="" arg
  [ "${1:-}" = api ] || bail "fixture received non-api gh call: $*"
  shift
  while [ $# -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
    --paginate) ;;
    --jq)
      filter="${1:-}"
      shift || true
      ;;
    -*) ;;
    *) [ -n "$endpoint" ] || endpoint="$arg" ;;
    esac
  done
  printf '%s\n' "$endpoint" >>"$REQUEST_LOG"
  case "$endpoint" in
  "repos/$REPO/issues/7/reactions?per_page=100") response="$REACTIONS_JSON" ;;
  "repos/$REPO/pulls/7/reviews?per_page=100")
    # The simulated push: gh runs in a subshell, so the "new head" travels through a file that
    # the PR read below consults.
    [ -z "$PUSH_ON_REVIEWS_READ" ] || : >"$TEST_ROOT/pushed"
    response="$REVIEWS_JSON"
    ;;
  "repos/$REPO/issues/7/comments?per_page=100") response="$COMMENTS_JSON" ;;
  "repos/$REPO/pulls/7/comments?per_page=100") response='[]' ;;
  "repos/$REPO/pulls/7/reviews/"*"/comments?per_page=100") response='[]' ;;
  "repos/$REPO/pulls/7")
    if [ -n "$FAIL_PULLS" ]; then
      echo "gh: pull request unavailable (HTTP 500)" >&2
      return 1
    fi
    # base.sha is a stale snapshot on purpose, as on a conflicted PR (see the base-drift suite).
    [ ! -e "$TEST_ROOT/pushed" ] || HEAD_SHA=new-head-sha
    response=$(jq -cn --arg h "$HEAD_SHA" --arg m "$MERGEABLE_STATE" \
      '{base:{ref:"main",sha:"stale-base-sha"}, head:{sha:$h}, mergeable_state:$m}')
    ;;
  "repos/$REPO/commits/head-sha" | "repos/$REPO/commits/new-head-sha")
    response='{"sha":"head-sha","commit":{"committer":{"date":"2026-09-01T00:00:00Z"}}}' ;;
  "repos/$REPO/commits/main") response='{"sha":"base-sha"}' ;;
  "repos/$REPO/compare/base-sha...head-sha?per_page=1") response=$(compare_json 7 15 pr.txt) ;;
  "repos/$REPO/compare/head-sha...base-sha?per_page=1") response=$(compare_json 15 7 base.txt) ;;
  *) bail "unexpected fixture endpoint: $endpoint" ;;
  esac
  if [ -n "$filter" ]; then
    jq -r "$filter" <<<"$response"
  else
    printf '%s\n' "$response"
  fi
}

# The state line and its rendering, as `status` and `watch` produce them.
run_status() {
  STATE=$(status_state 7)
  LINE=$(status_line "$STATE")
}

# cmd_status in a subshell: its exit code is the assertion, and it must not end this reporter.
run_cmd_status() {
  local rc
  set +e
  CMD_OUT=$(cmd_status 7 2>&1)
  rc=$?
  set -e
  CMD_RC="$rc"
}

# A watch that returns on its first poll. stdout and stderr are kept apart: the contract is that
# a round's stdout is byte-identical to poll's, so the drift read has to be on stderr.
run_watch() {
  local rc
  set +e
  WATCH_INTERVAL=1 WATCH_TIMEOUT=3 cmd_watch 7 "${1:-0,0,0}" >"$TEST_ROOT/watch.out" 2>"$TEST_ROOT/watch.err"
  rc=$?
  set -e
  WATCH_RC="$rc"
  WATCH_OUT=$(cat "$TEST_ROOT/watch.out")
  WATCH_ERR=$(cat "$TEST_ROOT/watch.err")
}

pulls_reads() {
  grep -c "^repos/$REPO/pulls/7\$" "$REQUEST_LOG" || true
}

idle_fixture() {
  reset_fixture
  REVIEWS_JSON="[$(review 5 head-sha "$PAST")]"
}

CONFLICT="CONFLICTS with the base (mergeable_state=dirty)"

test_idle_clean_says_next_move_is_yours() {
  idle_fixture
  run_status
  assert_eq "$(state_tok "$STATE")" idle "a reviewed head with no 👍 is idle"
  assert_eq "$(state_merge "$STATE")" clean "the mergeability rides on the state line"
  assert_contains "$LINE" "the next move is yours" "a clean idle PR hands the move to the caller"
  assert_not_contains "$LINE" "CONFLICTS" "a clean PR must not claim a conflict"
}

test_idle_dirty_says_conflicts_not_next_move() {
  idle_fixture
  MERGEABLE_STATE=dirty
  run_status
  assert_eq "$(state_tok "$STATE")" idle "a conflict is not a review state: the head is still reviewed"
  assert_eq "$(state_merge "$STATE")" dirty "the dirty mergeability should ride on the state line"
  assert_contains "$LINE" "$CONFLICT" "a conflicted idle PR should say CONFLICTS"
  assert_contains "$LINE" "no pull_request run tests that merge" \
    "the line should say what the conflict costs: the head merged with the base goes untested"
  assert_not_contains "$LINE" "no workflow runs on this head" \
    "a run that completed before the base moved may exist: do not claim nothing ran"
  assert_contains "$LINE" "merge the base in" "the line should name the remedy"
  assert_not_contains "$LINE" "the next move is yours" \
    "a conflicted PR must not invite another push as the next move"
  run_cmd_status
  assert_eq "$CMD_RC" 0 "the merge gate is the state, not the mergeability: idle stays exit 0"
  assert_contains "$CMD_OUT" "$CONFLICT" "cmd_status should print the conflict"
}

test_reviewing_dirty_still_says_conflicts() {
  reset_fixture
  MERGEABLE_STATE=dirty
  REACTIONS_JSON="[$(reaction eyes "$(jq -rn '(now - 60) | todate')")]"
  run_status
  assert_eq "$(state_tok "$STATE")" reviewing "a live 👀 with nothing posted is a round in flight"
  assert_contains "$LINE" "wait it out" "an in-flight round is still waited out"
  assert_contains "$LINE" "$CONFLICT" \
    "a round in flight on a conflicted PR is a round CI is not testing, and the line must say so"
}

test_expected_dirty_says_conflicts() {
  reset_fixture
  MERGEABLE_STATE=dirty
  run_status
  assert_eq "$(state_tok "$STATE")" expected "an unreviewed head with no 👀 is expected"
  assert_contains "$LINE" "review EXPECTED" "expected renders as before"
  assert_contains "$LINE" "$CONFLICT" "a push awaiting review on a conflicted PR should say CONFLICTS"
}

test_approved_dirty_says_conflicts_and_survives_a_failed_pr_read() {
  reset_fixture
  MERGEABLE_STATE=dirty
  REACTIONS_JSON="[$(reaction +1 "$PAST")]"
  run_status
  assert_eq "$(state_tok "$STATE")" approved "👍 is the merge gate"
  assert_contains "$LINE" "$CONFLICT" "an approved conflicted PR should say the merge will not build"
  FAIL_PULLS=1
  run_status
  assert_eq "$(state_tok "$STATE")" approved \
    "a failed PR read must not hide a 👍 behind unknown: the reactions feed alone answers it"
  assert_eq "$(state_merge "$STATE")" unread "a failed PR read is 'unread', not a value"
  assert_not_contains "$LINE" "CONFLICTS" "an unread mergeability must not claim a conflict"
  assert_contains "$LINE" "mergeability UNREAD" \
    "an approved line that could not read the mergeability must say so, not look clean"
}

test_reviewing_with_a_failed_pr_read_says_unread() {
  reset_fixture
  FAIL_PULLS=1
  REACTIONS_JSON="[$(reaction eyes "$(jq -rn '(now - 60) | todate')")]"
  run_status
  assert_eq "$(state_tok "$STATE")" reviewing "a live 👀 is a round in flight whatever the PR read did"
  assert_contains "$LINE" "wait it out" "the round is still waited out"
  assert_contains "$LINE" "mergeability UNREAD" \
    "a reviewing line that could not read the mergeability must say so"
  assert_contains "$LINE" "not 'no'" "unread must not read as 'does not conflict'"
}

test_head_is_read_after_the_feeds() {
  # A push lands between the feed reads and the PR read: the review on file is of the PREVIOUS
  # head. Read after the feeds, the PR read sees the new head and the state is expected; read
  # before them, the old head would have matched its own review and reported idle.
  idle_fixture
  PUSH_ON_REVIEWS_READ=1
  run_status
  PUSH_ON_REVIEWS_READ=""
  assert_eq "$(state_tok "$STATE")" expected \
    "a head pushed while the feeds were read is unreviewed, not idle"
  assert_contains "$(state_detail "$STATE")" "no review of head new-hea" \
    "the state should be about the head as read after the feeds"
  local order
  order=$(awk -v feed="repos/$REPO/pulls/7/reviews?per_page=100" -v pr="repos/$REPO/pulls/7" '
    $0 == feed { f = NR } $0 == pr { p = NR }
    END { if (f && p && p > f) print "after"; else print "feed=" f " pr=" p }' "$REQUEST_LOG")
  assert_eq "$order" after "the PR read should come after the reviews feed"
}

test_computing_mergeability_is_not_a_conflict() {
  idle_fixture
  MERGEABLE_STATE=unknown
  run_status
  assert_eq "$(state_merge "$STATE")" unknown "GitHub still computing is carried as is"
  assert_contains "$LINE" "the next move is yours" "unknown mergeability leaves the idle line alone"
  assert_not_contains "$LINE" "CONFLICTS" "unknown mergeability is not a conflict"
}

test_failed_pr_read_is_unknown_where_the_head_decides() {
  idle_fixture
  FAIL_PULLS=1
  run_status
  assert_eq "$(state_tok "$STATE")" unknown "idle needs the head SHA, and it was not read"
  assert_contains "$(state_detail "$STATE")" "the pulls API did not answer for the head SHA" \
    "the detail should say which read failed"
  assert_contains "$(state_detail "$STATE")" "HTTP 500" \
    "the detail should quote the PR read's own error, not a later call's"
  run_cmd_status
  assert_eq "$CMD_RC" 3 "an unread state is exit 3, not 'not approved'"
}

test_one_pr_read_per_status() {
  # A no-findings verdict for ANOTHER head used to cost a second PR read on the way to idle.
  idle_fixture
  COMMENTS_JSON="[$(verdict_comment 9 other-sha "$PAST")]"
  run_status
  assert_eq "$(state_tok "$STATE")" idle "a verdict naming another head does not approve this one"
  assert_eq "$(pulls_reads)" 1 "the head and the mergeability come from one PR read"
}

test_detail_is_the_last_field_and_keeps_pipes() {
  local line='unknown|-|-|gh: 502 | Bad Gateway'
  assert_eq "$(state_tok "$line")" unknown "token is the first field"
  assert_eq "$(state_age "$line")" - "age is the second field"
  assert_eq "$(state_merge "$line")" - "mergeability is the third field"
  assert_eq "$(state_detail "$line")" 'gh: 502 | Bad Gateway' "detail is everything after the third |"
}

test_watch_reads_the_drift_when_a_round_lands() {
  idle_fixture
  MERGEABLE_STATE=dirty
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "a review above the watermark is a round to act on"
  assert_contains "$WATCH_OUT" "--- review id=5" "the round is on stdout, as poll prints it"
  assert_contains "$WATCH_OUT" "watermark: " "the watermark is on stdout, last"
  assert_not_contains "$WATCH_OUT" "base freshness" "the drift read must not pollute poll's stdout"
  assert_contains "$WATCH_ERR" "base freshness $REPO#7: 7 commit(s) behind main, 15 ahead" \
    "the drift count should be read against the base's tip the round it matters"
  assert_contains "$WATCH_ERR" "!!! $REPO#7 CONFLICTS with main (mergeable_state=dirty)" \
    "the drift read should say the PR conflicts"
  assert_contains "$WATCH_ERR" "status: nothing in flight" "the status context still prints"
  assert_contains "$WATCH_ERR" "$CONFLICT" "the status context carries the conflict"
  assert_contains "$(cat "$REQUEST_LOG")" "repos/$REPO/compare/base-sha...head-sha?per_page=1" \
    "the forward compare should be read on a round"
}

test_watch_approved_leaves_the_drift_to_merge() {
  reset_fixture
  REACTIONS_JSON="[$(reaction +1 "$PAST")]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "an approval is something to act on"
  assert_contains "$WATCH_OUT" "approved (👍 from" "the approval is on stdout"
  assert_not_contains "$(cat "$REQUEST_LOG")" "compare/" \
    "merge prints the drift read next; the watch does not duplicate it"
}

tests=(
  test_idle_clean_says_next_move_is_yours
  test_idle_dirty_says_conflicts_not_next_move
  test_reviewing_dirty_still_says_conflicts
  test_expected_dirty_says_conflicts
  test_approved_dirty_says_conflicts_and_survives_a_failed_pr_read
  test_reviewing_with_a_failed_pr_read_says_unread
  test_head_is_read_after_the_feeds
  test_computing_mergeability_is_not_a_conflict
  test_failed_pr_read_is_unknown_where_the_head_decides
  test_one_pr_read_per_status
  test_detail_is_the_last_field_and_keeps_pipes
  test_watch_reads_the_drift_when_a_round_lands
  test_watch_approved_leaves_the_drift_to_merge
)

for test_name in "${tests[@]}"; do
  "$test_name"
  echo "PASS: $test_name"
done
