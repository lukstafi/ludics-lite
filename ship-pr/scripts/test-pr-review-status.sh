#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's `status` state line — the mergeability that rides on
# every state and turns "the next move is yours" into "merge the base in first" — and for `watch`
# reading the base drift the moment a round lands rather than at merge time (ludics-lite#44).
#
# Plus the `failed` state (ludics-lite#78): the reviewer answering with an initialization failure
# instead of a round, which used to read as `expected` and send `watch` into the grace. Its
# fixtures carry the comment body verbatim from lukstafi/ocannl-staging#677.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=test-pr-review-lib.sh
source "$SCRIPT_DIR/test-pr-review-lib.sh"
test_tmpdir TEST_ROOT status-test

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
# The head commit's own date, which is what a failure naming no ref is dated against.
HEAD_AT=2026-09-01T00:00:00Z
# The two refs ocannl-staging#677's failures named, and its third head, which reviewed normally.
FAILED_HEAD=0ac6fef8038e95481f82deddc1edfa2ab8ca8827
OTHER_REF=099131cc90960b2ad144f9f33c374c6be81035c8

reset_fixture() {
  REACTIONS_JSON='[]'
  REVIEWS_JSON='[]'
  COMMENTS_JSON='[]'
  HEAD_SHA=head-sha
  MERGEABLE_STATE=clean
  HEAD_AT=2026-09-01T00:00:00Z
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

plain_comment() { # <id> <created_at> <body>
  jq -cn --argjson id "$1" --arg at "$2" --arg b "$3" --arg rev "$REVIEWER" \
    '{id:$id, user:{login:($rev + "[bot]")}, created_at:$at, updated_at:$at, body:$b}'
}

# The initialization failure as the connector posts it: the curly quotes, the ref in a fenced
# block, and the "About Codex in GitHub" details block every one of its comments carries. Nothing
# machine-tags it, which is why it reads as the reviewer's last word. `-` for a failure that
# names no ref.
FAILURE_HEAD_LINE='Codex Review: Something went wrong. Try again later by commenting “@codex review”.'
FAILURE_TAIL='<details> <summary>ℹ️ About Codex in GitHub</summary>
Reviews are triggered when you open a pull request or comment "@codex review".
</details>'

failure_body() { # <ref|->
  printf '%s\n' "$FAILURE_HEAD_LINE" ""
  [ "$1" = - ] || printf '```\nProvided git ref %s does not exist\n```\n\n' "$1"
  printf '%s\n' "$FAILURE_TAIL"
}

failure_comment() { # <id> <ref|-> <created_at>
  plain_comment "$1" "$3" "$(failure_body "$2")"
}

compare_json() { # <behind> <ahead> <file>
  jq -cn --argjson behind "$1" --argjson ahead "$2" --arg f "$3" \
    '{behind_by:$behind, ahead_by:$ahead, merge_base_commit:{sha:"merge-base-sha"},
      files:[{filename:$f}]}'
}

# Minimal gh fixture transport for every feed `status` and `watch` read. The --jq filter matters
# here: the PR read asks gh to format its head/mergeability snapshot. --paginate is ignored (one
# page is the whole feed).
gh() {
  local response=""
  gh_fixture_parse "$@"
  case "$FIXTURE_ENDPOINT" in
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
  "repos/$REPO/commits/head-sha" | "repos/$REPO/commits/new-head-sha" | \
    "repos/$REPO/commits/$FAILED_HEAD")
    response=$(jq -cn --arg d "$HEAD_AT" '{sha:"head-sha", commit:{committer:{date:$d}}}') ;;
  "repos/$REPO/commits/main") response='{"sha":"base-sha"}' ;;
  "repos/$REPO/compare/base-sha...head-sha?per_page=1" | \
    "repos/$REPO/compare/base-sha...$FAILED_HEAD?per_page=1") response=$(compare_json 7 15 pr.txt) ;;
  "repos/$REPO/compare/head-sha...base-sha?per_page=1" | \
    "repos/$REPO/compare/$FAILED_HEAD...base-sha?per_page=1") response=$(compare_json 15 7 base.txt) ;;
  *) bail "unexpected fixture endpoint: $FIXTURE_ENDPOINT" ;;
  esac
  gh_fixture_answer "$response"
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

test_idle_draft_names_gh_pr_ready() {
  idle_fixture
  MERGEABLE_STATE=draft
  run_status
  assert_eq "$(state_tok "$STATE")" idle "a draft is not a review state: the head is still reviewed"
  assert_eq "$(state_merge "$STATE")" draft "the draft mergeability should ride on the state line"
  assert_contains "$LINE" "DRAFT (mergeable_state=draft)" "an idle draft should say DRAFT"
  assert_contains "$LINE" "gh pr ready" "the line should name the move that lands a draft"
  assert_contains "$LINE" "--repo $REPO" \
    "the command names the repository: a bare number cannot resolve it from a background shell"
  assert_not_contains "$LINE" "the next move is yours" \
    "a draft must not invite another push as the move that lands it"
  assert_not_contains "$LINE" "CONFLICTS" "a draft is not a conflict"
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
  assert_contains "$LINE" "the next move is yours" \
    "a mergeability still being computed does not take the move away: only a known conflict does"
  assert_not_contains "$LINE" "CONFLICTS" "unknown mergeability is not a conflict"
  assert_contains "$LINE" "mergeability NOT YET COMPUTED" \
    "the first status after a push that caused a conflict must not read as a clean bill of health"
  assert_contains "$LINE" "re-read status in a minute" \
    "the caveat should name the remedy: look again once GitHub has computed it"
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

# --- the reviewer that never started (ludics-lite#78) ------------------------------------------
# The head is the SHA the first ocannl-staging#677 failure named, so "the ref it could not fetch"
# and "the PR's head" are the same string, as they were there.
failed_fixture() { # <the ref the failure names, or - for none>
  reset_fixture
  HEAD_SHA="$FAILED_HEAD"
  COMMENTS_JSON="[$(failure_comment 100 "$1" "$PAST")]"
}

test_initialization_failure_is_its_own_state() {
  failed_fixture "$FAILED_HEAD"
  run_status
  assert_eq "$(state_tok "$STATE")" failed \
    "the reviewer's newest word saying it could not fetch the head is not a review that is due"
  assert_eq "$(state_merge "$STATE")" clean "the mergeability rides on this state line too"
  assert_contains "$LINE" "reviewer FAILED at initialization on head ${FAILED_HEAD:0:7} — " \
    "the line should name the state and the head it happened on"
  assert_contains "$LINE" "nudge it once with a '@codex review' comment" \
    "the line should name the move that usually gets the reviewer through"
  assert_contains "$LINE" "clone is behind, not your push" \
    "the line should say whose side the failure is on, since the push looks guilty"
  assert_not_contains "$LINE" "review EXPECTED" \
    "the failure must not read as a round that has yet to start"
  run_cmd_status
  assert_eq "$CMD_RC" 0 "a state that was READ is exit 0, whatever it says"
  assert_contains "$CMD_OUT" "reviewer FAILED at initialization" "cmd_status should print it"
  assert_contains "$CMD_OUT" "review rounds with findings: 0 of 12" \
    "an attempt that never ran is not a round with findings"
}

# A failure that names no ref at all is still about the head the round was due on: it is the
# reviewer's newest word and it contradicts nothing.
# A failure that names no ref is not attributed to any head. Two review rounds went into trying:
# the only clock is the head commit's committer date, which a force-push or a reset to an older
# commit dates BEFORE the failure, so the old failure would be reported against a head whose round
# is still inside its grace. The cost of not attributing it is one grace, on a shape the connector
# has never posted; the cost of attributing it wrongly is a nudge over a round that is coming.
test_a_failure_naming_no_ref_is_not_attributed() {
  failed_fixture -
  run_status
  assert_eq "$(state_tok "$STATE")" expected \
    "a failure that names no head is not evidence about this one"
  assert_contains "$LINE" "review EXPECTED but not started" "the ordinary due-round line"
  assert_not_contains "$LINE" "FAILED at initialization" "and no verdict is claimed from it"
  # The same body WITH the ref is the shape that fires: this case is about the ref, nothing else.
  COMMENTS_JSON="[$(failure_comment 100 "$FAILED_HEAD" "$PAST")]"
  run_status
  assert_eq "$(state_tok "$STATE")" failed "the ref is what attributes a failure to a head"
}

# The deliberate, loud miss. The matcher is the reviewer's own opening sentence and nothing
# looser, so a failure worded differently reads as `expected` and costs one grace. Every looser
# shape tried in review swallowed a comment-only ROUND whose finding quotes the ref error, which
# costs a finding and says nothing — the trade is stated in the matcher's comment.
test_a_differently_worded_failure_is_missed_not_guessed() {
  reset_fixture
  HEAD_SHA="$FAILED_HEAD"
  COMMENTS_JSON="[$(plain_comment 100 "$PAST" "$(printf '%s\n\n```\nProvided git ref %s does not exist\n```\n' \
    'Codex Review: the review could not be started.' "$FAILED_HEAD")")]"
  run_status
  assert_eq "$(state_tok "$STATE")" expected \
    "the opening sentence is the whole matcher: anything else waits out the grace"
}

# The finding this state could hide, and the reason the matcher is anchored to that sentence: a
# comment-only ROUND whose finding quotes the CURRENT head's ref error. Reported as `failed` it
# would send the caller to nudge while the round's finding sat unread in the same comment.
test_a_round_quoting_this_head_s_ref_error_is_not_a_failure() {
  reset_fixture
  HEAD_SHA="$FAILED_HEAD"
  COMMENTS_JSON="[$(plain_comment 100 "$PAST" "$(printf '%s\n\n```\nProvided git ref %s does not exist\n```\n\n%s\n' \
    'Codex Review: P2 — the matcher reads a quoted error as a failure' "$FAILED_HEAD" \
    'so a round about it disappears.')")]"
  run_status
  assert_not_contains "$LINE" "FAILED at initialization" \
    "a round that quotes this head's ref error is a round, not the reviewer failing"
  assert_eq "$(state_tok "$STATE")" expected "and it reads as the round it is"
  # The compound of that and the sentence: a finding whose own first words are the connector's,
  # over the same quoted error. The matcher takes the sentence WHOLE, through the retry
  # instruction, so "Something went wrong in the retry path" is a finding about a retry path.
  COMMENTS_JSON="[$(plain_comment 101 "$PAST" "$(printf '%s\n\n```\nProvided git ref %s does not exist\n```\n' \
    'Codex Review: Something went wrong in the retry path, and the head it names is this one' \
    "$FAILED_HEAD")")]"
  run_status
  assert_not_contains "$LINE" "FAILED at initialization" \
    "three shared words are not the failure sentence"
  assert_eq "$(state_tok "$STATE")" expected "the finding stands as a round"
}

# Both moves are on the line, in order, whatever the history: the nudge that usually works, and
# the new head for when it does not. No count decides between them — a reaction-only success
# leaves nothing to count from, and the re-request that fails clears the 👍 that was its only
# trace (review of #82, round 6), so a script that claimed to know which case you are in would
# be claiming more than the feeds can tell it.
test_the_line_states_both_moves() {
  failed_fixture "$FAILED_HEAD"
  run_status
  assert_contains "$LINE" "nudge it once with a '@codex review' comment" "the first move"
  assert_contains "$LINE" "if the SAME head fails again, push a new head instead" "the second"
  assert_contains "$LINE" "pr-review.sh comment $REPO#" "the nudge should be runnable"
  # A second failure on the same head does not change the line: it was already saying this.
  COMMENTS_JSON="[$(failure_comment 100 "$FAILED_HEAD" "$PAST"),$(
    failure_comment 101 "$FAILED_HEAD" 2026-09-01T00:03:00Z)]"
  run_status
  assert_eq "$(state_tok "$STATE")" failed "still a failure"
  assert_contains "$LINE" "if the SAME head fails again, push a new head instead" \
    "the escalation is stated the same way, not counted into"
}

# The head moved on after the failure: a round is due on the NEW head, and that is `expected`.
test_a_failure_naming_another_head_is_expected() {
  failed_fixture "$OTHER_REF"
  run_status
  assert_eq "$(state_tok "$STATE")" expected \
    "a failure about a head that has since been replaced is a round due on the new one"
  assert_contains "$LINE" "review EXPECTED but not started" "the ordinary due-round line"
  assert_not_contains "$LINE" "FAILED at initialization" \
    "the previous head's failure must not be reported against this one"
}

test_a_round_of_the_head_after_the_failure_wins() {
  failed_fixture "$FAILED_HEAD"
  REVIEWS_JSON="[$(review 5 "$FAILED_HEAD" 2026-09-01T01:00:00Z)]"
  run_status
  assert_eq "$(state_tok "$STATE")" idle \
    "a round that landed on this head after the failure is the newer truth"
  # The negative control on the same comparison: the round landed BEFORE the failed re-request
  # (a '@codex review' with no push), so it does not answer for it.
  REVIEWS_JSON="[$(review 5 "$FAILED_HEAD" 2026-08-31T23:00:00Z)]"
  run_status
  assert_eq "$(state_tok "$STATE")" failed \
    "a round from before the failure does not make the failed re-request a round"
  # And a review of some OTHER head is not a review of this one, whenever it landed.
  REVIEWS_JSON="[$(review 5 old-head-sha 2026-09-01T01:00:00Z)]"
  run_status
  assert_eq "$(state_tok "$STATE")" failed "the comparison is against reviews of THIS head"
}

test_a_newer_reviewer_word_supersedes_the_failure() {
  failed_fixture "$FAILED_HEAD"
  REACTIONS_JSON="[$(reaction eyes "$(jq -rn '(now - 60) | todate')")]"
  run_status
  assert_eq "$(state_tok "$STATE")" reviewing \
    "a 👀 raised after the failure is a round that started after it — wait that one out"
  failed_fixture "$FAILED_HEAD"
  COMMENTS_JSON="[$(failure_comment 100 "$FAILED_HEAD" "$PAST"),$(
    verdict_comment 101 "$FAILED_HEAD" 2026-09-01T01:00:00Z)]"
  run_status
  assert_eq "$(state_tok "$STATE")" approved \
    "a no-findings verdict after the failure is the reviewer's newest word"
  failed_fixture "$FAILED_HEAD"
  REACTIONS_JSON="[$(reaction +1 "$PAST")]"
  run_status
  assert_eq "$(state_tok "$STATE")" approved "the 👍 is the merge gate whatever followed it"
}

# The wrong verdict this state could produce, and the anchor that refuses it. A review QUOTING the
# failure — this repository's own reviewer reads these fixtures — must not be read as one.
test_a_quoted_failure_is_not_a_failure() {
  reset_fixture
  HEAD_SHA="$FAILED_HEAD"
  COMMENTS_JSON="[$(plain_comment 100 "$PAST" "$(printf '%s\n\n```\n%s\n```\n\n%s\n' \
    'Round 3, on the summary: the matcher is anchored to the body start, so' \
    "$FAILURE_HEAD_LINE" 'quoting it in a finding cannot fire the state.')")]"
  run_status
  assert_eq "$(state_tok "$STATE")" expected \
    "a finding that quotes the failure sentence is not the reviewer failing"
  # Quoted whole, ref line and all: still a quotation, since the sentence is not where the body
  # opens. (The ref-vs-head guard behind the anchor is what
  # test_a_failure_naming_another_head_is_expected exercises, on a genuine failure body.)
  COMMENTS_JSON="[$(plain_comment 101 "$PAST" "$(printf 'Round 4, the fixture body is\n\n%s\n' \
    "$(failure_body "$OTHER_REF")")")]"
  run_status
  assert_eq "$(state_tok "$STATE")" expected \
    "a failure quoted below the first line is a quotation, not the reviewer failing"
}

test_watch_exits_on_the_initialization_failure() {
  failed_fixture "$FAILED_HEAD"
  # The watermark is already past the comment: this is the SECOND window, the one that used to
  # report "review EXPECTED but not started" and wait the grace out.
  run_watch 0,200,0
  assert_eq "$WATCH_RC" 0 "the failure is something to act on, as a stall is"
  assert_contains "$WATCH_OUT" "reviewer FAILED at initialization on head ${FAILED_HEAD:0:7}" \
    "the verdict is on stdout, where the caller reads it"
  assert_contains "$WATCH_OUT" "watermark: 0,200,0" "the watch still ends on a watermark"
  assert_not_contains "$WATCH_OUT" "no review materialized" \
    "the grace is for a round that has not started, not for one the reviewer said it could not"
  assert_contains "$WATCH_ERR" "base freshness $REPO#7:" \
    "the drift read rides along, as it does on the other exits"
  # The first window, where the comment is itself the new activity: the round prints, and the
  # status context beside it already says what the comment means.
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "a new comment is a round to return on"
  assert_contains "$WATCH_OUT" "--- summary id=100" "the failure comment is what poll saw"
  assert_contains "$WATCH_ERR" "status: reviewer FAILED at initialization" \
    "the context should name the state, not leave the caller to read the body"
}

# The merge gate against a failure, both ways round — the deliberate part of the ranking. A round
# that ANNOUNCED itself and then failed closes the gate; a re-request that never announced itself
# does not withdraw the verdict this head already has, exactly as a 👍 would not be withdrawn.
test_a_standing_verdict_survives_a_failed_re_request() {
  failed_fixture "$FAILED_HEAD"
  COMMENTS_JSON="[$(verdict_comment 99 "$FAILED_HEAD" "$PAST"),$(
    failure_comment 100 "$FAILED_HEAD" 2026-09-01T01:00:00Z)]"
  run_status
  assert_eq "$(state_tok "$STATE")" approved \
    "a round that never ran does not take back the verdict this head already has"
  assert_contains "$LINE" "no-findings verdict for head" "the approval names the verdict it rests on"
  # With a 👀 between them — the re-request that did announce a round — the verdict is no longer
  # the reviewer's newest word about the attempt, and the failure is what the caller must act on.
  REACTIONS_JSON="[$(reaction eyes 2026-09-01T00:30:00Z)]"
  run_status
  assert_eq "$(state_tok "$STATE")" failed \
    "a round that announced itself and then failed leaves the failure as the newest word"
  assert_contains "$LINE" "reviewer FAILED at initialization" "and the line says so"
}

tests=(
  test_idle_clean_says_next_move_is_yours
  test_idle_dirty_says_conflicts_not_next_move
  test_idle_draft_names_gh_pr_ready
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
  test_initialization_failure_is_its_own_state
  test_a_failure_naming_no_ref_is_not_attributed
  test_a_differently_worded_failure_is_missed_not_guessed
  test_a_round_quoting_this_head_s_ref_error_is_not_a_failure
  test_the_line_states_both_moves
  test_a_failure_naming_another_head_is_expected
  test_a_round_of_the_head_after_the_failure_wins
  test_a_newer_reviewer_word_supersedes_the_failure
  test_a_quoted_failure_is_not_a_failure
  test_watch_exits_on_the_initialization_failure
  test_a_standing_verdict_survives_a_failed_re_request
)

run_tests "${tests[@]}"
