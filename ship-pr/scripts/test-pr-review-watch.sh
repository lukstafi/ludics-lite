#!/usr/bin/env bash
# Fixture tests for what ends a `watch` (ludics-lite#72). The loop used to return 0 on any
# `--- ` line a poll rendered, whoever it was about: on this repository a round's watch exited on
# the inline findings and took its watermark from that poll, the reviewer's separate summary
# review landed seconds later with a higher id, and the NEXT window returned 0 on it at once —
# a wake, a re-arm, and nothing about the new head to act on. So the wait now ends only on
# reviewer activity about the head being watched, every exit says what it is exiting on, and a
# verdict that says nothing came polls once more before it says it.
#
# The `expected` clock is here too, the same issue's other half: it used to start at the head
# commit's committer date alone, which on a PR opened seconds earlier read "due for 22m" and
# recommended a nudge at a reviewer that had had no time at all.
#
# The fixture answers the feeds IN SEQUENCE across polls (see `schedule`), which is what a
# watch-level case needs and what the single-answer suites do not do: the round a final poll
# catches has to be absent from the round before it.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=test-pr-review-lib.sh
source "$SCRIPT_DIR/test-pr-review-lib.sh"
test_tmpdir TEST_ROOT watch-test

REPO=example/repo
REQUEST_LOG="$TEST_ROOT/requests"
FEEDS="$TEST_ROOT/feeds"

# Two heads: H2 is what the watch is bound to, H1 the head a previous round was about. Full
# 40-hex, as GitHub serves them, so the seven-character stamp poll renders is a real truncation.
H1=1111111aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
H2=2222222bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
HEAD_SHA="$H2"
MERGEABLE_STATE=clean
FAIL_PULLS=""
# The poll round from which the feeds stop answering (the transport failure a final poll can hit),
# and the one from which the PR read stops answering. 0 is never.
FAIL_FEEDS_FROM=0
FAIL_PULLS_FROM=0
# The head's committer date and the PR's creation, the two clocks the `expected` state runs on.
# Fresh by default, so a case about what ends a wait is never decided by the grace expiring
# underneath it; the clock cases set them where they need them.
HEAD_AT=""
PR_CREATED_AT=""

# --- the sequenced fixture ---------------------------------------------------------------------
# Every feed answers per POLL ROUND: `schedule <feed> <round> <json>` says what it answers from
# that round on, and a round with no schedule of its own answers the newest one below it. So a
# feed set once holds for the whole window, and one set at round 2 is invisible to round 1.
# The round counter lives in a file because the fixture runs inside the command substitution each
# poll is made in, where a variable would not survive to the next call.

reset_fixture() {
  rm -rf "$FEEDS"
  mkdir -p "$FEEDS"
  echo 0 >"$FEEDS/round"
  schedule reactions 1 '[]'
  schedule reviews 1 '[]'
  schedule comments 1 '[]'
  schedule inline 1 '[]'
  schedule review_comments 1 '[]'
  HEAD_SHA="$H2"
  MERGEABLE_STATE=clean
  FAIL_PULLS=""
  FAIL_FEEDS_FROM=0
  FAIL_PULLS_FROM=0
  HEAD_AT=$(jq -rn '(now - 60) | todate')
  PR_CREATED_AT=$(jq -rn '(now - 60) | todate')
  : >"$REQUEST_LOG"
}

schedule() { # <feed> <round> <json>
  printf '%s\n' "$3" >"$FEEDS/$1.$2"
}

# cmd_poll reads the inline feed first on every round, so that endpoint is the round boundary.
poll_rounds() { cat "$FEEDS/round"; }

feed_answer() { # <feed>
  local round n
  round=$(cat "$FEEDS/round")
  n="$round"
  while [ "$n" -ge 1 ]; do
    if [ -e "$FEEDS/$1.$n" ]; then
      cat "$FEEDS/$1.$n"
      return 0
    fi
    n=$((n - 1))
  done
  echo '[]'
}

reaction() { # <content> <created_at>
  jq -cn --arg c "$1" --arg at "$2" --arg rev "$REVIEWER" \
    '{user:{login:($rev + "[bot]")}, content:$c, created_at:$at}'
}

review() { # <id> <commit> <submitted_at> [body]
  jq -cn --argjson id "$1" --arg sha "$2" --arg at "$3" --arg b "${4:-findings}" --arg rev "$REVIEWER" \
    '{id:$id, user:{login:($rev + "[bot]")}, state:"COMMENTED", commit_id:$sha,
      submitted_at:$at, body:$b}'
}

# An inline comment carries BOTH commit fields, because they are what the head test turns on:
# GitHub migrates `commit_id` forward to the current head for a comment whose lines still exist,
# while `original_commit_id` stays the commit the reviewer wrote it against.
inline_comment() { # <id> <original commit> <current commit> [body] [path] [line]
  jq -cn --argjson id "$1" --arg orig "$2" --arg cur "$3" --arg b "${4:-a finding}" \
    --arg p "${5:-a.sh}" --argjson ln "${6:-3}" --arg rev "$REVIEWER" \
    '{id:$id, user:{login:($rev + "[bot]")}, path:$p, line:$ln, body:$b,
      original_commit_id:$orig, commit_id:$cur}'
}

# How many times a string occurs in the whole of what a watch printed. A fold is only a fold if
# the duplicated BODY is printed once, and "contains it" cannot tell one copy from three.
occurrences() { # <haystack> <needle>
  grep -c -F -- "$2" <<<"$1" || true
}

# A row as the PER-REVIEW comments endpoint serves it, which is not the shape the flat feed has:
# no `line` and no `original_line` at all — verified against this repository's live API on
# 2026-09-10 — with the location carried by position/original_position instead. poll renders such
# a row as `:0`, so two of them at different places in one file look identical.
positional_comment() { # <id> <original commit> <body> <position>
  jq -cn --argjson id "$1" --arg orig "$2" --arg b "$3" --argjson pos "$4" --arg rev "$REVIEWER" \
    '{id:$id, user:{login:($rev + "[bot]")}, path:"a.sh", body:$b, position:$pos,
      original_position:$pos, original_commit_id:$orig, commit_id:$orig}'
}

summary_comment() { # <id> <created_at> <body>
  jq -cn --argjson id "$1" --arg at "$2" --arg b "$3" --arg rev "$REVIEWER" \
    '{id:$id, user:{login:($rev + "[bot]")}, created_at:$at, updated_at:$at, body:$b}'
}

stamped_summary() { # <id> <created_at> <commit> <text>
  summary_comment "$1" "$2" "$(printf '%s\n\n**Reviewed commit:** `%s`\n' "$4" "${3:0:7}")"
}

# Whether the poll feeds answer this round: a transport failure that starts at a given round is
# how a final poll is made to fail while the loop rounds before it succeeded.
feeds_answering() {
  [ "$FAIL_FEEDS_FROM" -eq 0 ] || [ "$(cat "$FEEDS/round")" -lt "$FAIL_FEEDS_FROM" ]
}

compare_json() { # <behind> <ahead> <file>
  jq -cn --argjson behind "$1" --argjson ahead "$2" --arg f "$3" \
    '{behind_by:$behind, ahead_by:$ahead, merge_base_commit:{sha:"merge-base-sha"},
      files:[{filename:$f}]}'
}

gh() {
  local response=""
  gh_fixture_parse "$@"
  case "$FIXTURE_ENDPOINT" in
  "repos/$REPO/pulls/7/comments?per_page=100")
    # The round boundary: poll reads this feed first, before anything else it reads.
    echo $(($(cat "$FEEDS/round") + 1)) >"$FEEDS/round"
    feeds_answering || {
      echo "gh: 503 No server is currently available to service your request" >&2
      return 1
    }
    response=$(feed_answer inline)
    ;;
  "repos/$REPO/issues/7/reactions?per_page=100") response=$(feed_answer reactions) ;;
  "repos/$REPO/pulls/7/reviews?per_page=100") response=$(feed_answer reviews) ;;
  "repos/$REPO/issues/7/comments?per_page=100") response=$(feed_answer comments) ;;
  "repos/$REPO/pulls/7/reviews/"*"/comments?per_page=100") response=$(feed_answer review_comments) ;;
  "repos/$REPO/pulls/7")
    if [ -n "$FAIL_PULLS" ] ||
      { [ "$FAIL_PULLS_FROM" -ne 0 ] && [ "$(cat "$FEEDS/round")" -ge "$FAIL_PULLS_FROM" ]; }; then
      echo "gh: pull request unavailable (HTTP 500)" >&2
      return 1
    fi
    response=$(jq -cn --arg h "$HEAD_SHA" --arg m "$MERGEABLE_STATE" --arg c "$PR_CREATED_AT" \
      '{base:{ref:"main",sha:"stale-base-sha"}, head:{sha:$h}, mergeable_state:$m, created_at:$c}')
    ;;
  "repos/$REPO/commits/$H1" | "repos/$REPO/commits/$H2")
    response=$(jq -cn --arg d "$HEAD_AT" '{sha:"head-sha", commit:{committer:{date:$d}}}')
    ;;
  "repos/$REPO/commits/main") response='{"sha":"base-sha"}' ;;
  "repos/$REPO/compare/base-sha...$H1?per_page=1" | "repos/$REPO/compare/base-sha...$H2?per_page=1")
    response=$(compare_json 1 2 pr.txt)
    ;;
  "repos/$REPO/compare/$H1...base-sha?per_page=1" | "repos/$REPO/compare/$H2...base-sha?per_page=1")
    response=$(compare_json 2 1 base.txt)
    ;;
  *) bail "unexpected fixture endpoint: $FIXTURE_ENDPOINT" ;;
  esac
  gh_fixture_answer "$response"
}

# A watch over a short window. WATCH_INTERVAL above WATCH_TIMEOUT means exactly one loop poll and
# then the final one, which is the shape the final-poll cases need; the default pair here polls
# twice in the loop.
run_watch() { # [watermark] [interval] [timeout]
  local rc
  set +e
  WATCH_INTERVAL="${2:-1}" WATCH_TIMEOUT="${3:-1}" \
    cmd_watch 7 "${1:-0,0,0}" >"$TEST_ROOT/watch.out" 2>"$TEST_ROOT/watch.err"
  rc=$?
  set -e
  WATCH_RC="$rc"
  WATCH_OUT=$(cat "$TEST_ROOT/watch.out")
  WATCH_ERR=$(cat "$TEST_ROOT/watch.err")
}

run_status() {
  STATE=$(status_state 7)
  LINE=$(status_line "$STATE")
}

# --- what ends the wait -------------------------------------------------------------------------

# The shape the issue was filed on: the reviewer's summary review for the PREVIOUS head, sitting
# above the watermark the last window ended on. It is not this head's round and must not be
# mistaken for one — and the negative control right below is the same review on THIS head, which
# must still end the wait, or this test would pass on a watch that never returns.
test_a_review_of_another_head_does_not_end_the_wait() {
  reset_fixture
  schedule reviews 1 "[$(review 500 "$H1" 2026-09-01T00:01:00Z 'the previous round, summarised')]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 1 "a review of another head leaves the window quiet"
  assert_not_contains "$WATCH_OUT" "--- review id=500" \
    "stdout is what to act on, and a previous head's round is not it"
  assert_contains "$WATCH_ERR" "1 item(s) NOT about head ${H2:0:7}" \
    "the round that scrolled past should be named on stderr"
  assert_contains "$WATCH_ERR" "--- review id=500 state=COMMENTED commit=${H1:0:7}" \
    "and printed for the record, whole: nothing renders it again"
  assert_contains "$WATCH_ERR" "the previous round, summarised" "the body is part of the record"
  assert_contains "$WATCH_OUT" "watermark: 0,0,500" \
    "the watermark advances past it, or the next window sees it again"
  # The control: the same review, about the head being watched.
  reset_fixture
  schedule reviews 1 "[$(review 500 "$H2" 2026-09-01T00:01:00Z 'this head, reviewed')]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "a review of the head being watched is the round to act on"
  assert_contains "$WATCH_OUT" "--- review id=500 state=COMMENTED commit=${H2:0:7}" \
    "and it goes to stdout, as poll printed it"
}

# The stamp on an inline finding is `original_commit_id`, not `commit_id`: GitHub migrates the
# latter forward to the current head for a comment whose lines still exist, so a previous round's
# finding would stamp itself with the head being watched and pass any test put to it.
test_an_inline_finding_is_bound_by_the_commit_it_was_written_against() {
  reset_fixture
  schedule inline 1 "[$(inline_comment 900 "$H1" "$H2" 'a finding from the round before')]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 1 \
    "a finding written against the previous head is not this head's round, whatever commit_id says"
  assert_contains "$WATCH_ERR" "--- inline id=900 a.sh:3 commit=${H1:0:7}" \
    "the stamp is the commit the reviewer wrote it against"
  reset_fixture
  schedule inline 1 "[$(inline_comment 900 "$H2" "$H2" 'a finding on the head')]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "a finding written against this head ends the wait"
  assert_contains "$WATCH_OUT" "--- inline id=900 a.sh:3 commit=${H2:0:7}" "on stdout"
}

# A comment's only head association is the "Reviewed commit:" stamp. One naming another commit is
# a previous round's summary; one naming NOTHING is not evidence about any head, and is acted on
# — the reviewer's initialization failure is exactly that shape, and swallowing it would leave a
# watch waiting on a round that will never start.
test_a_summary_is_bound_by_the_commit_it_names() {
  reset_fixture
  schedule comments 1 "[$(stamped_summary 700 2026-09-01T00:01:00Z "$H1" 'Codex Review: the previous head')]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 1 "a summary naming another commit does not end the wait"
  assert_contains "$WATCH_ERR" "--- summary id=700 commit=${H1:0:7}" "it is recorded as what it is"
  reset_fixture
  schedule comments 1 "[$(summary_comment 700 2026-09-01T00:01:00Z 'Codex Review: no commit named here')]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "a summary that names no commit is acted on, never swallowed"
  assert_contains "$WATCH_OUT" "--- summary id=700 commit=-" "and its stamp says it names none"
}

# The head could not be read. Nothing can be held back for being about another commit, so
# everything is acted on and the line says why — the alternative is a watch that swallows a round
# because a PR read 500'd.
test_an_unread_head_holds_nothing_back() {
  reset_fixture
  schedule reviews 1 "[$(review 500 "$H1" 2026-09-01T00:01:00Z)]"
  FAIL_PULLS=1
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "with no head to compare against, the round is acted on"
  assert_contains "$WATCH_ERR" "the head did not read this round, so nothing was held back" \
    "and the exit line says which case it is in"
}

# The silent half of the fold, found in round 1 of #86. When the flat comments feed lags a new
# review, poll supplements it from the per-review endpoint, whose rows carry NO line at all — so
# every one of them renders `:0` and two findings at different places in one file look identical.
# Folded, the second is answered by a reply it never got and resolved with the first, and the
# watermark has advanced past its id, so nothing renders it again. The key therefore carries every
# location field the row has, and `:0` is never the thing two rows are folded on.
test_rows_with_no_line_are_folded_only_when_their_positions_agree() {
  reset_fixture
  local same="the same body, at two places in one file"
  schedule reviews 1 "[$(review 500 "$H2" 2026-09-01T00:01:00Z)]"
  schedule review_comments 1 "[$(positional_comment 900 "$H2" "$same" 12),$(positional_comment 901 "$H2" "$same" 40)]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "the round is acted on"
  assert_contains "$WATCH_OUT" "--- inline id=900 a.sh:0" "the first row renders with no line"
  assert_contains "$WATCH_OUT" "--- inline id=901 a.sh:0" "and so does the second: they LOOK alike"
  assert_not_contains "$WATCH_OUT" "id=900+901" \
    "but two positions in one file are two findings, and folding them loses the second for good"
  assert_eq "$(occurrences "$WATCH_OUT" "$same")" 2 "each is rendered, so each can be answered"
  # The control: rows agreeing on every anchor either of them has really are indistinguishable,
  # and do fold — or the case above would pass on a fold that had simply stopped working.
  reset_fixture
  schedule reviews 1 "[$(review 500 "$H2" 2026-09-01T00:01:00Z)]"
  schedule review_comments 1 "[$(positional_comment 900 "$H2" "$same" 12),$(positional_comment 901 "$H2" "$same" 12)]"
  run_watch 0,0,0
  assert_contains "$WATCH_OUT" "--- inline id=900+901 a.sh:0" \
    "with nothing to tell them apart, they are one finding and one reply"
  assert_eq "$(occurrences "$WATCH_OUT" "$same")" 1 "and one body"
}

# --- what each exit says it exits on --------------------------------------------------------------

test_the_acting_exit_names_the_item() {
  reset_fixture
  schedule reviews 1 "[$(review 500 "$H2" 2026-09-01T00:01:00Z)]"
  # Distinct bodies: two findings, not one posted twice. Identical ones fold into a single entry
  # (ludics-lite#76), which is the right count for a duplicate and the wrong fixture for a case
  # about how much else the exit is ending on.
  schedule inline 1 "[$(inline_comment 900 "$H2" "$H2" 'a finding'),$(inline_comment 901 "$H2" "$H2" 'another finding')]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "the round ends the wait"
  assert_contains "$WATCH_ERR" \
    "ending the wait on inline id=900 commit=${H2:0:7} by ${REVIEWER}[bot]" \
    "the exit names the item: its id, its short commit and its author"
  assert_contains "$WATCH_ERR" "(+2 more about this head)" \
    "and how much else it is ending on, so a truncated log still says how many"
  # A review carries a state, and the exit line names it: a COMMENTED round and an APPROVED one
  # are different windows.
  reset_fixture
  schedule reviews 1 "[$(review 500 "$H2" 2026-09-01T00:01:00Z)]"
  run_watch 0,0,0
  assert_contains "$WATCH_ERR" \
    "ending the wait on review id=500 state=COMMENTED commit=${H2:0:7} by ${REVIEWER}[bot]" \
    "a review's state is part of what the exit names"
}

# The two silences a log could not tell apart: a window in which the reviewer said nothing about
# anything, and one in which it spoke three times about a head that is no longer the head.
test_the_quiet_exit_names_the_head_and_what_scrolled_past() {
  reset_fixture
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 1 "nothing at all is a quiet window"
  assert_contains "$WATCH_OUT" "no reviewer activity about head ${H2:0:7} in 1s" \
    "the quiet exit names the head the wait was bound to"
  assert_not_contains "$WATCH_OUT" "scrolled past" "and claims no traffic that did not happen"
  reset_fixture
  schedule reviews 1 "[$(review 500 "$H1" 2026-09-01T00:01:00Z)]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 1 "an old round scrolling past is still a quiet window"
  assert_contains "$WATCH_OUT" \
    "1 item(s) about another commit scrolled past (last: review id=500 state=COMMENTED commit=${H1:0:7}" \
    "and the exit says so, with the item, so the two silences read differently"
}

# --- one final poll before any verdict ------------------------------------------------------------

# WATCH_INTERVAL above WATCH_TIMEOUT: the loop polls once and breaks. A round posted in the gap
# between that poll and the report is what the final poll is for — reported quiet, it costs a
# whole re-arm, and the round sits unread meanwhile.
test_a_round_landing_after_the_last_loop_poll_is_still_caught() {
  reset_fixture
  schedule reviews 2 "[$(review 500 "$H2" 2026-09-01T00:01:00Z 'landed in the gap')]"
  run_watch 0,0,0 5 1
  assert_eq "$(poll_rounds)" 2 "the window polls once in the loop and once more at the end"
  assert_eq "$WATCH_RC" 0 "the round the final poll found is acted on, not reported quiet"
  assert_contains "$WATCH_OUT" "--- review id=500" "and it reaches stdout like any other round"
  assert_contains "$WATCH_ERR" "ending the wait on review id=500" "named, like any other"
  # The control: the same window with nothing to find still polls that second time, and still
  # reports quiet — a final poll that only ever fires on a hit would prove nothing here.
  reset_fixture
  run_watch 0,0,0 5 1
  assert_eq "$(poll_rounds)" 2 "the final poll happens whether or not it changes the answer"
  assert_eq "$WATCH_RC" 1 "and an empty one leaves the window quiet"
}

# The same race on the loudest verdict there is: `expected` past its grace tells the caller to
# nudge the reviewer, and a nudge posted over a round that landed seconds earlier re-requests a
# review and CLEARS the 👍 it may be about to get.
test_a_verdict_polls_once_more_before_recommending_a_nudge() {
  reset_fixture
  # GRACE is read when pr-review.sh is sourced, so SHIP_PR_REVIEW_GRACE cannot reach it here.
  # The grace is one second, so the head is past due on the first round and the loop reaches the
  # verdict this case is about.
  local grace_was="$GRACE"
  GRACE=1
  schedule reviews 2 "[$(review 500 "$H2" 2026-09-01T00:01:00Z 'the round the nudge would have talked over')]"
  run_watch 0,0,0 5 1
  GRACE="$grace_was"
  assert_eq "$WATCH_RC" 0 "the round wins over the verdict that was about to be printed"
  assert_not_contains "$WATCH_OUT" "no review materialized" \
    "and the nudge is not recommended over a round that has landed"
  assert_contains "$WATCH_OUT" "--- review id=500" "the round is what the caller reads"
  assert_contains "$WATCH_ERR" "status: nothing in flight" \
    "the state beside it is re-read, not the one the dropped verdict was about"
}

test_a_verdict_that_still_stands_names_the_head_it_is_about() {
  reset_fixture
  local grace_was="$GRACE"
  GRACE=1
  run_watch 0,0,0 5 1
  GRACE="$grace_was"
  assert_eq "$WATCH_RC" 0 "a due round that never started is still something to act on"
  assert_contains "$WATCH_OUT" "no review materialized" "the verdict stands"
  assert_contains "$WATCH_OUT" "no reviewer activity about head ${H2:0:7}" \
    "and it says what it is exiting on"
  assert_contains "$WATCH_OUT" "review EXPECTED but not started" "beside the state itself"
}

# --- a verdict is only ever printed from calls that answered ---------------------------------------

# A final poll that does not answer rules nothing out. Printing the nudge anyway would be a claim
# about the PR made from a call that failed — the one thing this script must never do — and the
# nudge is the move that re-requests a review and CLEARS a standing 👍.
test_a_final_poll_that_did_not_answer_withholds_the_verdict() {
  reset_fixture
  local grace_was="$GRACE"
  GRACE=1
  FAIL_FEEDS_FROM=2 # the loop round answers; the final poll does not
  run_watch 0,0,0 5 1
  GRACE="$grace_was"
  assert_eq "$WATCH_RC" 3 "an unobserved tail is transport, not a verdict"
  assert_contains "$WATCH_OUT" "the verdict is WITHHELD" "and the line says the verdict was withheld"
  assert_not_contains "$WATCH_OUT" "no review materialized" "the nudge is not recommended"
  assert_contains "$WATCH_OUT" "watermark: " "the watch still ends on a watermark"
  # The control: the same window with a final poll that answers prints the verdict.
  reset_fixture
  GRACE=1
  run_watch 0,0,0 5 1
  GRACE="$grace_was"
  assert_eq "$WATCH_RC" 0 "with the tail observed, the verdict stands"
  assert_contains "$WATCH_OUT" "no review materialized" "and recommends the nudge"
}

# The 👍 is a REACTION, and cmd_poll reads comments and reviews. An approval landing in the same
# gap the final poll covers is invisible to that poll, so the state is re-read before the verdict
# is printed — or the loop recommends a nudge at a PR that has just been approved, and the
# re-request clears the approval.
test_an_approval_landing_during_the_final_poll_drops_the_verdict() {
  reset_fixture
  local grace_was="$GRACE"
  GRACE=1
  schedule reactions 2 "[$(reaction +1 2026-09-01T00:02:00Z)]"
  run_watch 0,0,0 5 1
  GRACE="$grace_was"
  assert_eq "$WATCH_RC" 0 "an approved PR is something to act on"
  assert_contains "$WATCH_OUT" "the 👍 landed while it was being read" "and the line says why"
  assert_contains "$WATCH_OUT" "approved (👍 from" "the approval is what the caller reads"
  assert_not_contains "$WATCH_OUT" "no review materialized" \
    "the nudge that would have cleared it is not recommended"
}

# Any other move of the state falsifies the verdict too, and the honest report is a quiet window:
# a round announcing itself (👀) between the poll and the print is not "no review is coming".
test_a_state_that_moved_drops_the_verdict_as_quiet() {
  reset_fixture
  local grace_was="$GRACE"
  GRACE=1
  schedule reactions 2 "[$(reaction eyes "$(jq -rn '(now - 5) | todate')")]"
  run_watch 0,0,0 5 1
  GRACE="$grace_was"
  assert_eq "$WATCH_RC" 1 "a round that just started is a quiet window, not a verdict"
  assert_contains "$WATCH_OUT" "the state moved to 'reviewing'" "and the line says what it moved to"
  assert_not_contains "$WATCH_OUT" "no review materialized" "no nudge over a round in flight"
}

# A state that cannot be re-read is not a state either: the verdict is withheld, exit 3.
test_a_state_that_could_not_be_re_read_withholds_the_verdict() {
  reset_fixture
  local grace_was="$GRACE"
  GRACE=1
  run_watch 0,0,0 5 1
  GRACE="$grace_was"
  assert_eq "$WATCH_RC" 0 "the control: with everything readable the verdict stands"
  # The PR read fails from the final poll on, so the loop reads its state and reaches the verdict
  # while the re-read behind it lands in `unknown`.
  reset_fixture
  GRACE=1
  FAIL_PULLS_FROM=2
  run_watch 0,0,0 5 1
  GRACE="$grace_was"
  assert_eq "$WATCH_RC" 3 "an unreadable state is not 'the reviewer stayed quiet'"
  assert_contains "$WATCH_OUT" "is WITHHELD" "and the verdict is withheld"
}

# --- a body is not an item -------------------------------------------------------------------------

# The reviewer quotes this script in its findings, output included. A body line that looks exactly
# like a rendered item header must not be classified as an item: read as one it carries no
# `commit=`, which counts as "about the head", and the watch would end on the very round it was
# skipping. So the classification reads the machine-readable `items:` line poll emits, never the
# rendering.
test_a_body_that_quotes_an_item_header_is_not_an_item() {
  reset_fixture
  local quoted
  quoted=$(printf 'Round 1, on the watch loop: the rendering below is a body, not a round.\n\n%s\n%s\n' \
    "--- review id=999 state=COMMENTED commit=${H2:0:7} by ${REVIEWER}[bot]" \
    "--- inline id=998 a.sh:1 commit=${H2:0:7} by ${REVIEWER}[bot]")
  schedule reviews 1 "[$(review 500 "$H1" 2026-09-01T00:01:00Z "$quoted")]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 1 \
    "a previous head's round that quotes item headers is still a previous head's round"
  assert_contains "$WATCH_ERR" "1 item(s) NOT about head" "exactly one item, the review itself"
  # Not a vacuous case: the header-shaped lines really are in what poll rendered, and the old
  # classification scanned exactly those lines.
  assert_contains "$WATCH_ERR" "--- review id=999 state=COMMENTED" \
    "the quoted header is in the rendering, where a scan would have found it"
  assert_not_contains "$WATCH_ERR" "id=999 commit=" \
    "but it is not an item: the index poll emits carries only the three real ones"
  # The control: the same quoted body on a round about THIS head still ends the wait, so the
  # refusal above is about the classification and not about the quoting.
  reset_fixture
  schedule reviews 1 "[$(review 500 "$H2" 2026-09-01T00:01:00Z "$quoted")]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "a round about this head ends the wait, quoted headers and all"
}

# The connector writes its "Reviewed commit:" stamp as a FOOTER, and a findings body can mention
# another commit above it — a review of this very parsing does. Taking the first match would stamp
# the round with a commit it merely mentions and discard it as an old head: a round lost in
# silence, which is worse than a false wake.
test_a_summary_is_stamped_by_its_footer_not_by_what_it_mentions() {
  reset_fixture
  schedule comments 1 "[$(summary_comment 700 2026-09-01T00:01:00Z \
    "$(printf 'Codex Review: the stamp reader takes the first match, so a body saying\n\n**Reviewed commit:** `%s`\n\nabove its own footer is misread.\n\n**Reviewed commit:** `%s`\n' \
      "${H1:0:7}" "${H2:0:7}")")]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "the footer names this head, so the summary is this head's round"
  assert_contains "$WATCH_OUT" "--- summary id=700 commit=${H2:0:7}" "and it is stamped with the footer"
  # The control: with the footer naming the OTHER head, the same body is a previous round.
  reset_fixture
  schedule comments 1 "[$(summary_comment 700 2026-09-01T00:01:00Z \
    "$(printf 'Codex Review: mentions\n\n**Reviewed commit:** `%s`\n\nand ends with\n\n**Reviewed commit:** `%s`\n' \
      "${H2:0:7}" "${H1:0:7}")")]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 1 "the last stamp decides, whichever head it names"
}

# --- the clock a due review is late against -------------------------------------------------------

# The report this issue was filed on: a PR opened seconds ago whose head commit was written 40
# minutes earlier read "due for 40m" and recommended a nudge. The committer date cannot bound the
# wait from underneath — a force-push to an older commit, or a first push of a morning's work,
# dates the head long before the push — and the PR's own creation can: nothing about a PR is due
# before the PR exists.
test_the_review_clock_starts_no_earlier_than_the_pr() {
  reset_fixture
  HEAD_AT=$(jq -rn '(now - 2400) | todate')
  PR_CREATED_AT=$(jq -rn '(now - 30) | todate')
  run_status
  assert_eq "$(state_tok "$STATE")" expected "an unreviewed head with no 👀 is expected"
  local age
  age=$(state_age "$STATE")
  [ "$age" -lt 120 ] ||
    bail "the clock should start at the PR's creation, not the commit's date (age ${age}s)"
  assert_contains "$LINE" "due for " "the line still says how late the review is"
  # The negative control on the same fixture: with the PR itself old, the committer date is the
  # newer bound and the clock runs from it — the floor must not become the answer.
  PR_CREATED_AT=$(jq -rn '(now - 86400) | todate')
  run_status
  age=$(state_age "$STATE")
  [ "$age" -ge 2400 ] && [ "$age" -lt 3000 ] ||
    bail "with an old PR the head's committer date is the clock (age ${age}s)"
}

# Each clock is validated on its own before the freshest wins: a committer date in the future
# (clock skew, or an explicit GIT_COMMITTER_DATE) is the newest timestamp there is and has no
# age at all, so taking it would leave the state with no clock and the grace unable to expire.
test_a_future_commit_date_does_not_blind_the_clock() {
  reset_fixture
  HEAD_AT=$(jq -rn '(now + 3600) | todate')
  PR_CREATED_AT=$(jq -rn '(now - 1800) | todate')
  run_status
  assert_eq "$(state_tok "$STATE")" expected "still a due review"
  local age
  age=$(state_age "$STATE")
  case "$age" in '' | *[!0-9]*) bail "a future commit date left the state with no clock ($age)" ;; esac
  [ "$age" -ge 1700 ] && [ "$age" -lt 2100 ] ||
    bail "the usable clock is the PR's creation (age ${age}s)"
}

# A PR read that fails costs the floor, not the state: the reviewer's own timestamps remain, and
# a state with no clock at all is what freshest_age exists to avoid.
test_a_clockless_expected_state_says_so_rather_than_guessing() {
  reset_fixture
  HEAD_AT=""
  PR_CREATED_AT=""
  run_status
  assert_eq "$(state_tok "$STATE")" expected "the state does not need a clock to be read"
  assert_eq "$(state_age "$STATE")" - "with nothing datable, the age is '-', never 0"
  assert_contains "$LINE" "due for an unknown time" "and the line says so rather than '0s'"
}

# --- duplicated inline threads ----------------------------------------------------------------

# Round 11 of ludics-lite#66 posted nine inline threads for four findings: the reviewer had
# duplicated several verbatim, and each duplicate cost its own composed reply and its own resolve.
# Identical here means identical in everything the entry shows — path, line, body, commit stamp and
# author — so the folded entry prints exactly what each of its members would have printed, once,
# under an id that lists them all.
test_identical_inline_threads_fold_into_one_entry() {
  reset_fixture
  local dup="the same finding, posted three times"
  schedule inline 1 "[$(inline_comment 900 "$H2" "$H2" "$dup"),$(inline_comment 901 "$H2" "$H2" "$dup"),$(inline_comment 902 "$H2" "$H2" "$dup")]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "a duplicated finding is still a round to act on"
  assert_contains "$WATCH_OUT" "--- inline id=900+901+902 a.sh:3 commit=${H2:0:7}" \
    "the three threads render as one entry naming every id, anchor first"
  assert_contains "$WATCH_OUT" "(3 identical threads, one reply answers all)" \
    "and the entry says why it carries three ids"
  assert_eq "$(occurrences "$WATCH_OUT" "$dup")" 1 \
    "the body is printed once: a fold that still printed it three times saves the caller nothing"
  assert_contains "$WATCH_OUT" "items: inline:900+901+902:${H2:0:7}:${REVIEWER}[bot]:-" \
    "the machine index folds with the rendering, and keeps its five fields"
  assert_contains "$WATCH_ERR" "ending the wait on inline id=900+901+902 commit=${H2:0:7}" \
    "the exit names the whole list, so it can be handed straight to reply"
  assert_not_contains "$WATCH_ERR" "more about this head" \
    "one finding is one item: the fold must not read as several"
  assert_contains "$WATCH_OUT" "watermark: 902,0,0" \
    "every duplicate's id is still advanced past — the watermark reads the unfolded feed"
}

# The negative control the fold's whole claim rests on: two threads that differ in the ONE field a
# reader would act on differently must stay two entries. Without this the fold could be collapsing
# distinct findings and every other case here would still pass.
test_threads_differing_only_in_body_are_not_folded() {
  reset_fixture
  schedule inline 1 "[$(inline_comment 900 "$H2" "$H2" 'the first finding'),$(inline_comment 901 "$H2" "$H2" 'the second finding')]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "two findings on the head are a round"
  assert_contains "$WATCH_OUT" "--- inline id=900 a.sh:3" "the first keeps its own entry"
  assert_contains "$WATCH_OUT" "--- inline id=901 a.sh:3" "and so does the second"
  assert_not_contains "$WATCH_OUT" "id=900+901" "same path and line is not enough to fold"
  assert_not_contains "$WATCH_OUT" "identical threads" "nor may the note claim they are identical"
  assert_contains "$WATCH_ERR" "(+1 more about this head)" "two entries are two findings"
  # Same body, different LINE: the other half of the key a reader acts on.
  reset_fixture
  schedule inline 1 "[$(inline_comment 900 "$H2" "$H2" 'a finding' a.sh 3),$(inline_comment 901 "$H2" "$H2" 'a finding' a.sh 9)]"
  run_watch 0,0,0
  assert_contains "$WATCH_OUT" "--- inline id=900 a.sh:3" "one line"
  assert_contains "$WATCH_OUT" "--- inline id=901 a.sh:9" "and another are two places to fix"
  # Same body and line, different PATH.
  reset_fixture
  schedule inline 1 "[$(inline_comment 900 "$H2" "$H2" 'a finding' a.sh 3),$(inline_comment 901 "$H2" "$H2" 'a finding' b.sh 3)]"
  run_watch 0,0,0
  assert_contains "$WATCH_OUT" "--- inline id=900 a.sh:3" "one file"
  assert_contains "$WATCH_OUT" "--- inline id=901 b.sh:3" "and another, likewise"
}

# The commit stamp is in the fold key because it is what `watch` classifies an item BY: folding a
# finding written against the previous head into one written against this head would force a
# single verdict onto two different head associations — and here it would drag a stale finding
# onto stdout as part of this head's round.
test_the_same_body_against_two_heads_is_not_folded() {
  reset_fixture
  local same="a finding the reviewer repeated after the push"
  schedule inline 1 "[$(inline_comment 900 "$H1" "$H2" "$same"),$(inline_comment 901 "$H2" "$H2" "$same")]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "the finding about this head ends the wait"
  assert_contains "$WATCH_OUT" "--- inline id=901 a.sh:3 commit=${H2:0:7}" \
    "this head's copy is what the caller acts on"
  assert_not_contains "$WATCH_OUT" "id=900+901" \
    "and the previous head's copy is not folded into it"
  assert_contains "$WATCH_ERR" "(+1 about another commit, below)" \
    "it stays a separate item, classified by its own stamp"
  assert_contains "$WATCH_OUT" "--- inline id=900 a.sh:3 commit=${H1:0:7}" \
    "and is rendered under the stamp it was written against, not this head's"
}

tests=(
  test_a_review_of_another_head_does_not_end_the_wait
  test_an_inline_finding_is_bound_by_the_commit_it_was_written_against
  test_identical_inline_threads_fold_into_one_entry
  test_threads_differing_only_in_body_are_not_folded
  test_the_same_body_against_two_heads_is_not_folded
  test_rows_with_no_line_are_folded_only_when_their_positions_agree
  test_a_summary_is_bound_by_the_commit_it_names
  test_an_unread_head_holds_nothing_back
  test_the_acting_exit_names_the_item
  test_the_quiet_exit_names_the_head_and_what_scrolled_past
  test_a_round_landing_after_the_last_loop_poll_is_still_caught
  test_a_verdict_polls_once_more_before_recommending_a_nudge
  test_a_verdict_that_still_stands_names_the_head_it_is_about
  test_a_final_poll_that_did_not_answer_withholds_the_verdict
  test_an_approval_landing_during_the_final_poll_drops_the_verdict
  test_a_state_that_moved_drops_the_verdict_as_quiet
  test_a_state_that_could_not_be_re_read_withholds_the_verdict
  test_a_body_that_quotes_an_item_header_is_not_an_item
  test_a_summary_is_stamped_by_its_footer_not_by_what_it_mentions
  test_the_review_clock_starts_no_earlier_than_the_pr
  test_a_future_commit_date_does_not_blind_the_clock
  test_a_clockless_expected_state_says_so_rather_than_guessing
)

run_tests "${tests[@]}"
