#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's review-round count — the number the convergence policy's
# threshold is read against (ludics-lite#12).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=test-pr-review-lib.sh
source "$SCRIPT_DIR/test-pr-review-lib.sh"

REPO=example/repo
REVIEWS_JSON='[]'
COMMENTS_JSON='[]'
FAIL_READ=""

# Minimal gh fixture transport: the reviews feed is the only endpoint the counter reads. It is
# fetched with --paginate, which the fixture accepts and ignores (one page is the whole feed).
gh() {
  local response=""
  gh_fixture_parse "$@"
  case "$FIXTURE_ENDPOINT" in
  "repos/$REPO/pulls/7/reviews?per_page=100")
    if [ -n "$FAIL_READ" ]; then
      echo "gh: reviews unavailable (HTTP 500)" >&2
      return 1
    fi
    response="$REVIEWS_JSON"
    ;;
  "repos/$REPO/issues/7/comments?per_page=100") response="$COMMENTS_JSON" ;;
  *) bail "unexpected fixture endpoint: $FIXTURE_ENDPOINT" ;;
  esac
  gh_fixture_answer "$response"
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

# The body goes to jq on stdin: a shell function's arguments are not exec arguments, but a
# `--arg` is, and the large-feed fixture below is over Linux's per-argument limit by design.
comment() { # <login> <created_at> <body>
  printf '%s' "$3" | jq -c -R -s --arg u "$1" --arg t "$2" \
    '{user:{login:$u}, created_at:$t, body:.}'
}

set_comments() {
  COMMENTS_JSON=$(printf '%s\n' "$@" | jq -cs .)
}

# The initialization failure, verbatim from lukstafi/ocannl-staging#677 (2026-09-09): a summary
# comment with no findings under it, because the review never ran (ludics-lite#78).
failure_body() { # <the ref the reviewer could not fetch>
  printf '%s\n\n```\nProvided git ref %s does not exist\n```\n' \
    'Codex Review: Something went wrong. Try again later by commenting “@codex review”.' "$1"
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

# What #677 actually read: two failed fetches, minutes apart, both landing in the comment feed
# with no "Reviewed commit" to attribute them to a head — counted as one comment-shaped round,
# reported as "1 round(s) of findings over 0 head(s)", and charged against the threshold.
test_initialization_failures_are_not_rounds() {
  set_reviews
  set_comments \
    "$(comment "$REVIEWER" 2026-09-09T17:00:54Z \
      "$(failure_body 0ac6fef8038e95481f82deddc1edfa2ab8ca8827)")" \
    "$(comment "$REVIEWER" 2026-09-09T17:03:22Z \
      "$(failure_body 099131cc90960b2ad144f9f33c374c6be81035c8)")"
  ROUND_THRESHOLD=12
  run_rounds
  assert_eq "$ROUNDS_RC" 0 "an unread threshold is not what a failed fetch produces"
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 0 of 12" \
    "a review that never started carries no findings"
  # Beside a real round, the failures still add nothing.
  set_reviews "$(review "$REVIEWER" COMMENTED aaaa 2026-09-09T10:00:00Z)"
  set_comments \
    "$(comment "$REVIEWER" 2026-09-09T17:00:54Z \
      "$(failure_body 0ac6fef8038e95481f82deddc1edfa2ab8ca8827)")" \
    "$(comment "$REVIEWER" 2026-09-09T17:03:22Z \
      "$(failure_body 099131cc90960b2ad144f9f33c374c6be81035c8)")"
  run_rounds
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 1 of 12" \
    "the inline round is the only round the two failures sit beside"
  # The negative control on the matcher: a comment-only round that merely says the words is a
  # round, and must not be swept up with them.
  set_comments "$(comment "$REVIEWER" 2026-09-09T17:00:54Z \
    'Codex Review: drop the lock — something went wrong in round 2 for a different reason')"
  run_rounds
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 2 of 12" \
    "a finding that mentions the wording is still a finding"
}

# The other side of that filter: a comment-only round whose finding QUOTES the ref error is a
# round. This function has no head to check a quoted ref against, so it drops a comment only when
# the body OPENS with the failure sentence itself — under the shape `status` uses, a round about
# this very matcher would vanish from the convergence count (review of #82, round 1).
test_a_round_quoting_the_ref_error_still_counts() {
  set_reviews
  set_comments "$(comment "$REVIEWER" 2026-09-09T17:00:54Z \
    "$(printf '%s\n\n```\nProvided git ref %s does not exist\n```\n\n%s\n' \
      'Codex Review: P2 — the matcher drops a round whose body quotes' \
      0ac6fef8038e95481f82deddc1edfa2ab8ca8827 'from the convergence count.')")"
  ROUND_THRESHOLD=12
  run_rounds
  assert_eq "$ROUNDS_RC" 0 "a round is a round"
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 1 of 12" \
    "a finding that quotes the ref error must not be swept up with the failures"
  # Nor one whose own opening words are the connector's: the sentence is matched whole, through
  # the retry instruction (review of #82, round 3).
  set_comments "$(comment "$REVIEWER" 2026-09-09T17:00:54Z \
    'Codex Review: Something went wrong in the retry path — the backoff is not reset')"
  run_rounds
  assert_contains "$ROUNDS_OUTPUT" "review rounds with findings: 1 of 12" \
    "three shared words are not the failure sentence"
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
  test_initialization_failures_are_not_rounds
  test_a_round_quoting_the_ref_error_still_counts
  test_no_rounds_yet
  test_threshold
  test_threshold_off
  test_api_failure_is_unknown
)

run_tests "${tests[@]}"
