#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's review-round count — the number the convergence policy's
# threshold is read against (ludics-lite#12).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
HELPER="$SCRIPT_DIR/pr-review.sh"

export SHIP_PR_TEST_SOURCE_ONLY=1
export SHIP_PR_STATE_DIR=off
export SHIP_PR_API_ATTEMPTS=1
export SHIP_PR_API_BACKOFF=0
# shellcheck source=pr-review.sh
source "$HELPER"

REPO=example/repo
REVIEWS_JSON='[]'
COMMENTS_JSON='[]'
FAIL_READ=""

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

# Minimal gh fixture transport: the reviews feed is the only endpoint the counter reads. It is
# fetched with --paginate, which the fixture accepts and ignores (one page is the whole feed).
gh() {
  local endpoint="" arg
  [ "${1:-}" = api ] || fail "fixture received non-api gh call: $*"
  shift
  while [ $# -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
    --paginate) ;;
    --jq) shift || true ;;
    -*) ;;
    *) [ -n "$endpoint" ] || endpoint="$arg" ;;
    esac
  done
  case "$endpoint" in
  "repos/$REPO/pulls/7/reviews?per_page=100")
    if [ -n "$FAIL_READ" ]; then
      echo "gh: reviews unavailable (HTTP 500)" >&2
      return 1
    fi
    printf '%s\n' "$REVIEWS_JSON"
    ;;
  "repos/$REPO/issues/7/comments?per_page=100") printf '%s\n' "$COMMENTS_JSON" ;;
  *) fail "unexpected fixture endpoint: $endpoint" ;;
  esac
}

review() { # <login> <state> <commit> <submitted_at|null>
  jq -cn --arg u "$1" --arg s "$2" --arg c "$3" --arg t "$4" \
    '{user:{login:$u}, state:$s, commit_id:$c,
      submitted_at:(if $t == "null" then null else $t end)}'
}

set_reviews() {
  REVIEWS_JSON=$(printf '%s\n' "$@" | jq -cs .)
  COMMENTS_JSON='[]'
  FAIL_READ=""
}

comment() { # <login> <created_at> <body>
  jq -cn --arg u "$1" --arg t "$2" --arg b "$3" '{user:{login:$u}, created_at:$t, body:$b}'
}

set_comments() {
  COMMENTS_JSON=$(printf '%s\n' "$@" | jq -cs .)
}

run_rounds() {
  local capture rc
  set +e
  capture=$(rounds_line "$(review_rounds 7)" 2>&1)
  rc=$?
  set -e
  ROUNDS_OUTPUT="$capture"
  ROUNDS_RC="$rc"
}

# Two heads carry findings. The approval, the author's own reply (a COMMENTED review in the same
# feed), the pending draft and the second inline comment on head A must not add rounds.
test_counts_distinct_heads_with_findings() {
  set_reviews \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:00Z)" \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:01Z)" \
    "$(review "$REVIEWER" CHANGES_REQUESTED bbbb 2026-09-01T11:00:00Z)" \
    "$(review "$REVIEWER" APPROVED cccc 2026-09-01T12:00:00Z)" \
    "$(review lukstafi COMMENTED bbbb 2026-09-01T11:30:00Z)" \
    "$(review "$REVIEWER" COMMENTED dddd null)"
  ROUND_THRESHOLD=12
  run_rounds
  assert_eq "$ROUNDS_RC" 0 "two rounds under a threshold of 12 should exit 0"
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 2 of 12" "should count two heads"
  assert_not_contains "$ROUNDS_OUTPUT" "PAST" "two of twelve is not past the threshold"
}

# A re-requested round on the same head ('@codex review' without a push) is a separate burst of
# reviews minutes later; it must count, or twelve rounds on one head would read as one.
test_rerequested_round_on_same_head_counts() {
  set_reviews \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:00Z)" \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:03Z)" \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:40:00Z)" \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:40:02Z)" \
    "$(review "$REVIEWER" COMMENTED bbbb 2026-09-01T11:00:00Z)"
  ROUND_THRESHOLD=12
  run_rounds
  assert_eq "$ROUNDS_RC" 0 "three rounds under the threshold should exit 0"
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 3 of 12" \
    "two bursts on one head plus one on another are three rounds"
  assert_contains "$ROUNDS_OUTPUT" "over 2 head(s)" "should still report the heads"
}

# Order in the feed is not submission order, and a burst straddling the gap by one review is one
# round: the gap is measured review to review, not from the round's first review.
test_rounds_are_ordered_by_submission_and_chained() {
  set_reviews \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:20:00Z)" \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:00Z)" \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:10:00Z)"
  ROUND_THRESHOLD=12
  run_rounds
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 1 of 12" \
    "reviews 10 minutes apart in a chain are one round"
}

test_malformed_threshold_is_refused() {
  local out rc
  set +e
  out=$(SHIP_PR_ROUND_THRESHOLD=12x bash "$HELPER" rounds "$REPO#7" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" 2 "a malformed threshold is a usage error, not 'off'"
  assert_contains "$out" "SHIP_PR_ROUND_THRESHOLD must be a number of rounds or 'off', got '12x'" \
    "should name the bad value"
  set +e
  out=$(SHIP_PR_ROUND_THRESHOLD=off SHIP_PR_TEST_SOURCE_ONLY=1 bash "$HELPER" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" 0 "off is accepted"
}

test_malformed_gap_is_refused() {
  local out rc v
  for v in '"900"' true -1 900.5 x; do
    set +e
    out=$(SHIP_PR_ROUND_GAP="$v" bash "$HELPER" rounds "$REPO#7" 2>&1)
    rc=$?
    set -e
    assert_eq "$rc" 2 "a gap of '$v' is a usage error"
    assert_contains "$out" "SHIP_PR_ROUND_GAP must be a nonnegative number of seconds" \
      "should name the setting for '$v'"
  done
  set +e
  out=$(SHIP_PR_ROUND_GAP=0 SHIP_PR_TEST_SOURCE_ONLY=1 bash "$HELPER" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" 0 "a zero gap is accepted"
}

# A round delivered only as an issue comment is a round; the running placeholder and the clean
# verdict are not; a comment quoting the head it reviewed joins that head's burst.
test_comment_only_rounds_count() {
  set_reviews \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:00Z)" \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:02Z)"
  set_comments \
    "$(comment "$REVIEWER" 2026-09-01T09:59:00Z '<!-- codex-pull-request-review-summary --> 🔄 Running')" \
    "$(comment "$REVIEWER" 2026-09-01T10:00:05Z 'Summary for **Reviewed commit:** `aaaa111` with one finding')" \
    "$(comment "$REVIEWER" 2026-09-01T10:45:00Z 'Codex Review: one more thing about the lock, no lines')" \
    "$(comment lukstafi 2026-09-01T10:50:00Z 'Round 2, on the summary: fixed')" \
    "$(comment "$REVIEWER" 2026-09-01T11:30:00Z "Codex Review: Didn't find any major issues. **Reviewed commit:** \`bbbb\`")"
  ROUND_THRESHOLD=12
  run_rounds
  assert_eq "$ROUNDS_RC" 0 "two rounds under the threshold"
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 2 of 12" \
    "the inline round (with its summary comment) plus one comment-only round"
}

# The feeds travel on stdin, not the argument list: one 300 KB comment is over Linux's per-argument
# limit, and a long PR has many.
test_large_comment_feed_still_counts() {
  set_reviews "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:00Z)"
  local big
  big=$(head -c 300000 /dev/zero | tr '\0' x)
  set_comments \
    "$(comment "$REVIEWER" 2026-09-01T10:45:00Z "Codex Review: $big")" \
    "$(comment "$REVIEWER" 2026-09-01T11:30:00Z "Codex Review: $big")"
  ROUND_THRESHOLD=12
  run_rounds
  assert_eq "$ROUNDS_RC" 0 "a large comment feed still reads"
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 3 of 12" \
    "the inline round plus two comment-only rounds"
}

test_no_rounds_yet() {
  set_reviews "$(review "$REVIEWER" APPROVED cccc 2026-09-01T12:00:00Z)"
  ROUND_THRESHOLD=12
  run_rounds
  assert_eq "$ROUNDS_RC" 0 "an approval alone is zero rounds with findings"
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 0 of 12" "should count zero"
}

test_threshold() {
  set_reviews \
    "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:00Z)" \
    "$(review "$REVIEWER" COMMENTED bbbb 2026-09-01T11:00:00Z)" \
    "$(review "$REVIEWER" COMMENTED cccc 2026-09-01T12:00:00Z)"
  ROUND_THRESHOLD=3
  run_rounds
  assert_eq "$ROUNDS_RC" 0 "the threshold round itself is still addressed in full"
  assert_contains "$ROUNDS_OUTPUT" "3 of 3 — the last round addressed in full" \
    "should say the threshold round is the last full one"
  ROUND_THRESHOLD=2
  run_rounds
  assert_eq "$ROUNDS_RC" 1 "past the threshold should exit 1"
  assert_contains "$ROUNDS_OUTPUT" "3, PAST the 2-round threshold" "should say it is past"
  assert_contains "$ROUNDS_OUTPUT" "blocking-only from here" "should carry the triage rule"
  assert_contains "$ROUNDS_OUTPUT" "a bug as such does not" "should say a bug is not blocking"
  assert_not_contains "$ROUNDS_OUTPUT" "of 2" "past the threshold is not 'N of M'"
}

test_threshold_off() {
  set_reviews "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:00Z)"
  ROUND_THRESHOLD=off
  run_rounds
  assert_eq "$ROUNDS_RC" 0 "no threshold should exit 0"
  assert_contains "$ROUNDS_OUTPUT" "no threshold set" "should say there is no threshold"
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 1 " "should still count"
}

# An unread feed is not "no rounds yet": the count says UNKNOWN and the exit is 3, the same
# collapse the rest of the script refuses to make.
test_api_failure_is_unknown() {
  set_reviews "$(review "$REVIEWER" COMMENTED aaaa 2026-09-01T10:00:00Z)"
  FAIL_READ=1
  ROUND_THRESHOLD=12
  run_rounds
  assert_eq "$ROUNDS_RC" 3 "an unread feed should exit 3"
  assert_contains "$ROUNDS_OUTPUT" "UNKNOWN" "an unread feed should say UNKNOWN"
  assert_contains "$ROUNDS_OUTPUT" "NOT 'no rounds yet'" "should refuse the zero reading"
  assert_not_contains "$ROUNDS_OUTPUT" "rounds with findings: 0" "must not print a zero count"
}

tests=(
  test_counts_distinct_heads_with_findings
  test_rerequested_round_on_same_head_counts
  test_rounds_are_ordered_by_submission_and_chained
  test_malformed_threshold_is_refused
  test_malformed_gap_is_refused
  test_comment_only_rounds_count
  test_large_comment_feed_still_counts
  test_no_rounds_yet
  test_threshold
  test_threshold_off
  test_api_failure_is_unknown
)

for test_name in "${tests[@]}"; do
  "$test_name"
  echo "PASS: $test_name"
done
