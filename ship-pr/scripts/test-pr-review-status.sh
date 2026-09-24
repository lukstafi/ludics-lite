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
test_tmpdir TEST_ROOT status-test

REPO=example/repo
REQUEST_LOG="$TEST_ROOT/requests"
REACTIONS_JSON='[]'
REVIEWS_JSON='[]'
COMMENTS_JSON='[]'
INLINE_JSON='[]'
FAIL_INLINE=""
HEAD_SHA=head-sha
MERGEABLE_STATE=clean
FAIL_PULLS=""
# Which READS the two simulated pushes fire on, counted from the start of the case: a watch reads
# every feed once for its opening status and again for each round, so "the push landed on the
# round's read" is 2, and a bare `status` case's only read is 1.
PUSH_ON_REVIEWS_READ=""
# The same simulated push, one read later: the PR read itself arms it, so the FIRST PR read of the
# process answers the old head and every one after it answers the pushed one. That is a push landing
# in the gap between a round's head read and the state read beside it — the gap ludics-lite#95
# closes, and the one a state that re-read the PR would report the round through.
PUSH_AFTER_PULLS_READ=""
# The flat inline feed refusing to answer: the shape that fails a poll ROUND, so a case can ask what
# a round that did not answer leaves behind for the state read after it.
FAIL_INLINE_FEED=""
# The PR's review threads (review_thread rows), how the connection pages them, and GraphQL
# refusing to answer — the open-thread read an approval is checked with (ludics-lite#289).
THREADS_JSON='[]'
THREADS_FIXTURE_PAGE=""
THREADS_FIXTURE_TOTAL=""
FAIL_GRAPHQL=""
# The base's tip, and the head PUSH_ON_REVIEWS_READ swaps in. With HEAD_SHA these are the only
# SHAs the transport below spells out, so a case that needs a new head just sets HEAD_SHA.
BASE_SHA=base-sha
PUSHED_HEAD=new-head-sha
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
  INLINE_JSON='[]'
  FAIL_INLINE=""
  HEAD_SHA=head-sha
  MERGEABLE_STATE=clean
  HEAD_AT=2026-09-01T00:00:00Z
  FAIL_PULLS=""
  PUSH_ON_REVIEWS_READ=""
  PUSH_AFTER_PULLS_READ=""
  FAIL_INLINE_FEED=""
  THREADS_JSON='[]'
  THREADS_FIXTURE_PAGE=""
  THREADS_FIXTURE_TOTAL=""
  FAIL_GRAPHQL=""
  rm -f "$TEST_ROOT/pushed" "$TEST_ROOT"/nth.*
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

# Which read of <feed> this is, counted from the case's reset. gh runs in a subshell, so the count
# lives in a file for the same reason the pushed marker does.
FIXTURE_NTH=0
fixture_nth() { # <feed>
  local f="$TEST_ROOT/nth.$1"
  FIXTURE_NTH=$(($(cat "$f" 2>/dev/null || echo 0) + 1))
  echo "$FIXTURE_NTH" >"$f"
}

# Is this SHA a head the fixture is standing behind? The commit read and both compare directions
# ask, so the three of them agree on one answer and a case that needs a new head costs the one
# HEAD_SHA assignment it already makes — spelling a head into an endpoint pattern is what used to
# cost three edits or a `bail`.
fixture_head() { # <sha>
  [ "$1" = "$HEAD_SHA" ] || [ "$1" = "$PUSHED_HEAD" ]
}

# Minimal gh fixture transport for every feed `status` and `watch` read. The --jq filter matters
# here: the PR read asks gh to format its head/mergeability snapshot. --paginate is ignored (one
# page is the whole feed).
gh() {
  local response="" spec left right
  gh_fixture_parse "$@"
  case "$FIXTURE_ENDPOINT" in
  "repos/$REPO/issues/7/reactions?per_page=100") response="$REACTIONS_JSON" ;;
  "repos/$REPO/pulls/7/reviews?per_page=100")
    # The simulated push: gh runs in a subshell, so the "new head" travels through a file that
    # the PR read below consults.
    fixture_nth reviews
    [ "$PUSH_ON_REVIEWS_READ" != "$FIXTURE_NTH" ] || : >"$TEST_ROOT/pushed"
    response="$REVIEWS_JSON"
    ;;
  "repos/$REPO/issues/7/comments?per_page=100") response="$COMMENTS_JSON" ;;
  "repos/$REPO/pulls/7/comments?per_page=100")
    if [ -n "$FAIL_INLINE_FEED" ]; then
      echo "gh: 503 No server is currently available to service your request" >&2
      return 1
    fi
    response='[]'
    ;;
  "repos/$REPO/pulls/7/reviews/"*"/comments?per_page=100")
    [ -z "$FAIL_INLINE" ] || return 1
    response="$INLINE_JSON" ;;
  "repos/$REPO/pulls/7")
    if [ -n "$FAIL_PULLS" ]; then
      echo "gh: pull request unavailable (HTTP 500)" >&2
      return 1
    fi
    # base.sha is a stale snapshot on purpose, as on a conflicted PR (see the base-drift suite).
    [ ! -e "$TEST_ROOT/pushed" ] || HEAD_SHA="$PUSHED_HEAD"
    response=$(jq -cn --arg h "$HEAD_SHA" --arg m "$MERGEABLE_STATE" \
      '{base:{ref:"main",sha:"stale-base-sha"}, head:{sha:$h}, mergeable_state:$m}')
    # Armed AFTER the answer, so THIS read still sees the old head and the next one does not.
    fixture_nth pulls
    [ "$PUSH_AFTER_PULLS_READ" != "$FIXTURE_NTH" ] || : >"$TEST_ROOT/pushed"
    ;;
  # Before the head arm: `main` is a ref this fixture resolves, not a head it serves.
  "repos/$REPO/commits/main") response="{\"sha\":\"$BASE_SHA\"}" ;;
  "repos/$REPO/commits/"*)
    fixture_head "${FIXTURE_ENDPOINT#"repos/$REPO/commits/"}" ||
      bail "unexpected fixture endpoint: $FIXTURE_ENDPOINT"
    # The date is the whole answer here — this read is `--jq .commit.committer.date` — so the
    # `sha` stays the placeholder it has always been rather than echoing the head back.
    response=$(jq -cn --arg d "$HEAD_AT" '{sha:"head-sha", commit:{committer:{date:$d}}}') ;;
  # The query suffix is part of the endpoint, not decoration: matching it here is what keeps the
  # generalization to the head SHA alone, so a compare that lost its `?per_page=1` still bails.
  "repos/$REPO/compare/"*"?per_page=1")
    spec=${FIXTURE_ENDPOINT#"repos/$REPO/compare/"}
    spec=${spec%"?per_page=1"}
    left=${spec%%...*}
    right=${spec#*...}
    if [ "$left" = "$BASE_SHA" ] && fixture_head "$right"; then
      response=$(compare_json 7 15 pr.txt) # base...head, the forward read: 7 behind, 15 ahead
    elif [ "$right" = "$BASE_SHA" ] && fixture_head "$left"; then
      response=$(compare_json 15 7 base.txt) # head...base, the reverse read: the counts swap
    else
      bail "unexpected fixture endpoint: $FIXTURE_ENDPOINT"
    fi
    ;;
  graphql)
    case "$*" in *reviewThreads*) ;; *) bail "unexpected graphql call: $*" ;; esac
    if [ -n "$FAIL_GRAPHQL" ]; then
      echo "gh: 503 No server is currently available to service your request" >&2
      return 1
    fi
    response=$(review_threads_answer "$THREADS_JSON" "$@")
    ;;
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
# The interval and the timeout are arguments so a case can pin the number of ROUNDS a window makes:
# an interval past the timeout is exactly one loop round and then the settle.
run_watch() { # [watermark] [interval] [timeout]
  local rc
  set +e
  WATCH_INTERVAL="${2:-1}" WATCH_TIMEOUT="${3:-3}" cmd_watch 7 "${1:-0,0,0}" >"$TEST_ROOT/watch.out" 2>"$TEST_ROOT/watch.err"
  rc=$?
  set -e
  WATCH_RC="$rc"
  WATCH_OUT=$(cat "$TEST_ROOT/watch.out")
  WATCH_ERR=$(cat "$TEST_ROOT/watch.err")
}

pulls_reads() {
  grep -c "^repos/$REPO/pulls/7\$" "$REQUEST_LOG" || true
}

# How many times an endpoint was asked, for the cases that count a round's calls.
reads_of() { # <endpoint, without the repos/<repo>/ prefix>
  grep -c -F -x "repos/$REPO/$1" "$REQUEST_LOG" || true
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


# --- one observation per round (ludics-lite#95) ------------------------------------------------
# A watch round used to read the comments, the reviews and the PR twice: once for the round and
# once again, a second later, for the state reported beside it. The round now publishes what it
# read and the state takes it, so both halves of a round are about one pair of instants. These
# cases pin the three things that made the second read look necessary — the call count it cost,
# the ordering it kept, and the head it was anchored on — and the two it must not break: a failed
# round hands the state nothing, and a `status` on its own still reads for itself.

test_a_round_and_its_state_are_one_read() {
  idle_fixture
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "a review of the head is a round to act on"
  # Two of each, and both are reads the watch could not do without: one for the state the watch
  # opens with (nothing has been polled yet) and one for the round. Before the snapshot each of
  # these was read THREE times a window — the opening state, the round, and the state read again
  # beside it — which on a real watch is four duplicated calls every ninety seconds.
  assert_eq "$(reads_of 'issues/7/comments?per_page=100')" 2 \
    "the comments feed should be read once for the opening state and once for the round"
  assert_eq "$(reads_of 'pulls/7/reviews?per_page=100')" 2 \
    "the reviews feed should be read once for the opening state and once for the round"
  # Three PR reads, and the third is not a duplicate of either: `watch_act` reads the base drift
  # when a round lands, which asks the PR for its base branch and its mergeability at merge-advice
  # time. It is one read per ROUND THAT LANDS, not one per poll, and it is a different question.
  assert_eq "$(pulls_reads)" 3 \
    "one PR read for the opening state, one for the round, and the drift read a landing round makes"
  # The per-review comments endpoint is the other duplicate: poll re-reads a new review's own
  # comments because the flat feed lags it, and substantive_reviews asks the same question of the
  # same review to tell an envelope from findings.
  reset_fixture
  REVIEWS_JSON="[$(review 5 head-sha "$PAST" | jq '.body=""')]"
  INLINE_JSON="[$(jq -cn --arg rev "$REVIEWER" \
    '{id:41, user:{login:($rev + "[bot]")}, path:"a.sh", line:3, body:"a finding",
      original_commit_id:"head-sha", commit_id:"head-sha"}')]"
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "an empty-bodied review with findings of its own is still a round"
  assert_eq "$(reads_of 'pulls/7/reviews/5/comments?per_page=100')" 2 \
    "review 5's own comments should be read once for the opening state and once for the round"
}

test_a_round_reads_the_head_after_its_feeds() {
  # The #47 ordering, now a property of the ROUND: the push lands on the round's reviews read, so
  # the review on file is of the head as it was when the feeds were read and the head read after
  # them is the new one. The round holds its item back and the state is about the new head.
  # Reversed — the head read before the feeds — the round would have matched that review to the
  # head it named and acted on it, and the state beside it would have reported `idle` for a head
  # that had already been replaced.
  idle_fixture
  # A head pushed seconds ago, so the `expected` grace this leaves cannot expire underneath the
  # case and turn the quiet window into the nudge verdict.
  HEAD_AT=$(jq -rn 'now | todate')
  PUSH_ON_REVIEWS_READ=2
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 1 "a review of the head the feeds were read at is not a review of the new head"
  assert_contains "$WATCH_ERR" "NOT about head ${PUSHED_HEAD:0:7}" \
    "the round should classify its item against the head read after its feeds"
  assert_contains "$WATCH_ERR" "no review of head ${PUSHED_HEAD:0:7}" \
    "and the state beside it should be about that same head, never the one the push replaced"
  local order
  order=$(awk -v feed="repos/$REPO/pulls/7/reviews?per_page=100" -v pr="repos/$REPO/pulls/7" '
    $0 == feed { f = NR } $0 == pr { p = NR }
    END { if (f && p && p > f) print "after"; else print "feed=" f " pr=" p }' "$REQUEST_LOG")
  assert_eq "$order" after "the round's PR read should come after its feeds"
}

test_the_state_is_about_the_head_the_round_was_classified_against() {
  # The push lands in the gap the second read opened: after the round's head read, before the
  # state beside it. Re-anchoring there is what swallowed a round just delivered about the head
  # being watched (the P2 rebutted in the review of ludics-lite#84) — the watch would print the
  # round and, beside it, a state saying no review of the head exists.
  idle_fixture
  PUSH_AFTER_PULLS_READ=2
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "the round about the head the feeds were read at is still the round"
  assert_contains "$WATCH_ERR" "reviewed head ${HEAD_SHA:0:7}" \
    "the state should name the head the round was classified against"
  assert_not_contains "$WATCH_ERR" "no review of head" \
    "a push landing after the round's head read must not re-anchor the state to it"
}

test_a_failed_round_hands_the_state_nothing() {
  # Only a round that ANSWERED publishes. A poll that failed leaves no snapshot, so the state read
  # after it reads the feeds itself and reports what its own read says — the collapse api_list
  # refuses to make (a failed read as an empty feed) must not come back in through the snapshot.
  idle_fixture
  FAIL_INLINE_FEED=1
  run_watch 0,0,0 9 1
  assert_eq "$WATCH_RC" 3 "a window whose polls never answered is not a quiet window"
  assert_contains "$WATCH_ERR" "the next move is yours" \
    "the state beside a failed round is still read, and reads the reviewer's idle head"
  assert_eq "$(reads_of 'pulls/7/reviews?per_page=100')" 4 \
    "one read per failed poll and one per state read after it: nothing is shared from a round that failed"
}

test_status_after_a_watch_reads_for_itself() {
  # The snapshot belongs to its watch. A `status` asked afterwards — the same process, since these
  # suites source the script — must read the PR as it is now, not replay the window that ended.
  idle_fixture
  run_watch 0,0,0
  assert_eq "$WATCH_RC" 0 "the round lands and the watch returns"
  REVIEWS_JSON="[$(review 5 other-sha "$PAST")]"
  run_status
  assert_eq "$(state_tok "$STATE")" expected \
    "a status after the watch should read the feeds as they are now"
  assert_contains "$(state_detail "$STATE")" "no review of head ${HEAD_SHA:0:7}" \
    "and report the head it just read, not the one the watch was holding"
}

test_a_dead_watch_s_snapshot_directory_is_swept() {
  # A watch killed with SIGKILL runs no EXIT trap, so its snapshot files outlive it. They are one
  # directory per process, named with the owning pid, and the next watch to start sweeps the ones
  # whose owner is gone — without touching a CONCURRENT watch's, which is the failure mode that
  # matters: several watches share a TMPDIR routinely, one per PR in flight.
  idle_fixture
  local root live dead dead_dir live_dir own
  root="$TEST_ROOT/snap-root"
  mkdir -p "$root"
  # A pid that is certainly gone: a child that has already exited and been reaped.
  (exit 0) &
  dead=$!
  wait "$dead" 2>/dev/null || true
  # And one that is certainly alive for the length of this case.
  sleep 30 &
  live=$!
  dead_dir="$root/pr-review-snap.$dead.AAAAAA"
  live_dir="$root/pr-review-snap.$live.BBBBBB"
  mkdir -p "$dead_dir" "$live_dir"
  : >"$dead_dir/round.feeds.pr"
  : >"$live_dir/round.feeds.pr"
  # And the loose files the first cut of the snapshot left in TMPDIR, keyed the same way.
  : >"$root/pr-review-snap.$dead.feeds.pr"
  : >"$root/pr-review-snap.$live.feeds.pr"

  local saved_root="$SNAP_ROOT" saved_dir="$SNAP_DIR" saved_snap="$SNAP"
  SNAP_ROOT="$root" SNAP_DIR="" SNAP=""
  run_watch 0,0,0
  own="$SNAP_DIR"
  SNAP_ROOT="$saved_root" SNAP_DIR="$saved_dir" SNAP="$saved_snap"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true

  assert_eq "$WATCH_RC" 0 "the round still lands; the sweep is not part of what a watch reports"
  if [ -d "$dead_dir" ]; then
    bail "the snapshot directory of a pid that is gone should be swept at watch start"
  fi
  if [ ! -d "$live_dir" ]; then
    bail "a live watch's snapshot directory must survive another watch's sweep"
  fi
  if [ -e "$root/pr-review-snap.$dead.feeds.pr" ]; then
    bail "a loose snapshot file of a pid that is gone should be swept too"
  fi
  if [ ! -e "$root/pr-review-snap.$live.feeds.pr" ]; then
    bail "a live watch's loose snapshot file must survive another watch's sweep"
  fi
  # And the watch's own files went into a directory of its own, not loose into the root, so there
  # is nothing a SIGKILL could leave that a later sweep cannot collect as one unit.
  assert_eq "$(find "$root" -maxdepth 1 -type f -name "pr-review-snap.$$.*" | wc -l | tr -d ' ')" 0 \
    "the snapshot files should live inside a per-process directory, not beside it"
  case "$own" in "$root"/pr-review-snap.$$.*) ;;
  *) bail "the watch's own snapshot directory should be named for this process, got '$own'" ;;
  esac
  rm -rf "$root"
}

test_every_other_family_a_dead_process_leaves_is_swept_too() {
  # The snapshot directory was never the only thing a killed run leaves in TMPDIR, and until
  # ludics-lite#219 it was the only thing anything collected. GH_ERR_FILE, gh_retry's per-attempt
  # capture, the constants probe's stderr in test-pr-review-lib.sh and a fixture suite's scratch
  # directory all outlive an owner that never reached its trap, and the sweep did not know their
  # names: seven of them sat in this box's real TMPDIR, dated 09-10 to 09-14.
  #
  # The live half is the half that matters. Ten fixture suites and several watches share one
  # TMPDIR on a wave day, so a sweep that went by age rather than by owner would delete a sibling's
  # fixtures mid-run — which is why every family carries the owning pid, and why a name whose pid
  # field is not a number is left alone instead of being guessed about.
  idle_fixture
  local root live dead f
  root="$TEST_ROOT/tmp-root"
  mkdir -p "$root"
  # A pid that is certainly gone: a child that has already exited and been reaped.
  (exit 0) &
  dead=$!
  wait "$dead" 2>/dev/null || true
  # And one that is certainly alive for the length of this case.
  sleep 30 &
  live=$!
  for f in "err.$dead" "gh.$dead.AAAAAA" "probe.$dead.err" \
    "err.$live" "gh.$live.BBBBBB" "probe.$live.err"; do
    : >"$root/pr-review-$f"
  done
  # test_tmpdir's directories, which are swept whole rather than file by file.
  mkdir -p "$root/pr-review-test.$dead.cwd-checkout.AAAAAA" \
    "$root/pr-review-test.$live.cwd-checkout.BBBBBB"
  : >"$root/pr-review-test.$dead.cwd-checkout.AAAAAA/fixture"
  # The shape the two unkeyed templates used to make: a suffix where the pid should be. It names
  # no owner, so this sweep has nothing to decide about it and must leave it exactly where it is.
  : >"$root/pr-review-gh.vswQwU"

  local saved_root="$SNAP_ROOT" saved_dir="$SNAP_DIR" saved_snap="$SNAP"
  SNAP_ROOT="$root" SNAP_DIR="" SNAP=""
  run_watch 0,0,0
  SNAP_ROOT="$saved_root" SNAP_DIR="$saved_dir" SNAP="$saved_snap"
  kill "$live" 2>/dev/null || true
  wait "$live" 2>/dev/null || true

  assert_eq "$WATCH_RC" 0 "the round still lands; the sweep is not part of what a watch reports"
  for f in "err.$dead" "gh.$dead.AAAAAA" "probe.$dead.err"; do
    if [ -e "$root/pr-review-$f" ]; then
      bail "pr-review-$f: a file whose owning pid is gone should be swept at watch start"
    fi
  done
  if [ -d "$root/pr-review-test.$dead.cwd-checkout.AAAAAA" ]; then
    bail "a dead suite's scratch directory should be swept whole, fixtures and all"
  fi
  for f in "err.$live" "gh.$live.BBBBBB" "probe.$live.err"; do
    if [ ! -e "$root/pr-review-$f" ]; then
      bail "pr-review-$f: a LIVE sibling's file must survive another run's sweep"
    fi
  done
  if [ ! -d "$root/pr-review-test.$live.cwd-checkout.BBBBBB" ]; then
    bail "a live suite's scratch directory must survive another run's sweep"
  fi
  if [ ! -e "$root/pr-review-gh.vswQwU" ]; then
    bail "a name with no pid in it names no owner, and must be left alone rather than aged out"
  fi
  rm -rf "$root"
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
  # And a finding that gets as far as the retry instruction before diverging: the sentence is
  # matched through the command it names, not up to the last word they share.
  COMMENTS_JSON="[$(plain_comment 101 "$PAST" "$(printf '%s\n\n```\nProvided git ref %s does not exist\n```\n' \
    'Codex Review: Something went wrong. Try again later by commenting on the retry logic' \
    "$FAILED_HEAD")")]"
  run_status
  assert_eq "$(state_tok "$STATE")" expected \
    "the sentence runs through '@codex review', so a finding that stops short is a finding"
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

test_empty_reviews_need_their_own_findings() {
  reset_fixture
  REVIEWS_JSON="[$(review 88 "$HEAD_SHA" "$PAST" | jq '.body=" \n\t"')]"
  run_status
  assert_eq "$(state_tok "$STATE")" expected "empty envelope does not review the head"
  INLINE_JSON='[{"id":1,"body":"a real finding","pull_request_review_id":88}]'
  run_status
  assert_eq "$(state_tok "$STATE")" idle "own inline finding reviews head even while flat feed is empty"
  FAIL_INLINE=1
  run_status
  assert_eq "$(state_tok "$STATE")" unknown "unread own inline feed is not empty"
  FAIL_INLINE=""
  INLINE_JSON='[]'
  REACTIONS_JSON="[$(reaction +1 "$PAST")]"
  run_status
  assert_eq "$(state_tok "$STATE")" approved "empty envelope preserves approval"
  HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  REVIEWS_JSON="[$(review 88 "$HEAD_SHA" 2026-09-01T00:02:00Z | jq '.body=null')]"
  COMMENTS_JSON="[$(plain_comment 1 "$PAST" '<!-- codex-pull-request-review-summary -->
| Code Review | Running <relative-time datetime="2026-09-01T00:01:00Z"> | `aaaaaaa` |')]"
  run_status
  assert_eq "$(state_tok "$STATE")" stalled "newer empty envelope cannot supersede current-head Running row"
}

# --- a jq program that ERRORS must not render as a fact (ludics-lite#89) ------------------------
# Every jq program status_state runs is a literal inside pr-review.sh, so the way to make ONE of
# them fail without touching the tracked script is to shim `jq` itself. The shim and its
# `with_broken_jq <marker> <cmd>...` helper are the preamble's (ludics-lite#179), and so is the
# control that it breaks only the invocation the marker names.

# assert_unknown_when_broken <marker> <detail fragment> <site>: break the one program the marker
# names, on whatever fixture the caller has standing, and require the state to refuse rather than
# answer. Each case pairs this with a control run on the same fixture, so an `unknown` the shim
# itself produced could not pass for the site's own refusal.
assert_unknown_when_broken() {
  with_broken_jq "$1" run_status
  assert_eq "$(state_tok "$STATE")" unknown "$3: a jq program error must not render as a value"
  assert_contains "$(state_detail "$STATE")" "$2" "$3: the detail should name the read that did not answer"
  assert_contains "$LINE" "this is NOT 'not approved', retry" \
    "$3: the rendered line should refuse, not report"
}

test_a_broken_jq_program_is_unknown_not_a_value() {
  idle_fixture
  # The baseline the rest of this case rests on: read with nothing broken, this fixture is idle,
  # so every `unknown` below is a site refusing rather than the fixture's own reading.
  run_status
  assert_eq "$(state_tok "$STATE")" idle "the ordinary reading of this fixture"

  assert_unknown_when_broken 'any(.[]; .content == "+1")' \
    "the reactions feed did not parse" "the reactions feed"
  assert_unknown_when_broken 'sort_by(.submitted_at) | last' \
    "the reviews feed did not parse" "the reviews feed"
  assert_unknown_when_broken '.created_at] | max // ""' \
    "the comments feed did not parse" "the reviewer's last comment"
  # These two used to default to "|" — no verdict comment, no initialization failure — which is
  # a plausible fact about the PR and is the shape ludics-lite#89 was filed on.
  assert_unknown_when_broken 'sort_by(.at) | last' \
    "the verdict comments feed did not parse" "the no-findings verdict scan"
  # `$refre` rather than the `capture($refre)` that surrounds it: the marker is a literal in
  # THIS file, and scripts/check-jq-shapes.sh reads a bare `capture(` as jq source wherever it
  # finds one. The variable appears in no other program, so it names the site just as exactly.
  assert_unknown_when_broken '$refre' \
    "the initialization-failure comments feed did not parse" "the initialization-failure scan"
}

test_a_broken_jq_program_is_unknown_on_the_failed_head_read() {
  failed_fixture "$FAILED_HEAD"
  run_status
  assert_eq "$(state_tok "$STATE")" failed "control: this fixture reaches the failed-head read"
  # It used to default to "", which reads as "no review of this head" — the very question this
  # arm is asking, answered by a read that did not happen.
  assert_unknown_when_broken '(.commit_id // "") == $sha' \
    "the reviews feed did not parse for the failed head" "the failed-head review read"
}

test_a_broken_jq_program_is_unknown_on_the_pending_request_read() {
  idle_fixture
  # The watch watermark cmd_watch passes down; status_state reads it to identify the request a
  # round is owed to. A standalone `status` has none, so the site is reached by setting it here.
  local watch_nudge_after=0
  run_status
  assert_eq "$(state_tok "$STATE")" idle "control: the pending-request read changes nothing here"
  assert_unknown_when_broken '^@codex review' \
    "the pending-request comments feed did not parse" "the pending-request read"
}

test_a_broken_jq_program_is_unknown_on_the_current_head_evidence() {
  reset_fixture
  REACTIONS_JSON="[$(reaction +1 "$PAST")]"
  run_status
  assert_eq "$(state_tok "$STATE")" approved "control: this fixture reaches the evidence scan"
  assert_unknown_when_broken '$running | map(select(. == null))' \
    "the current-head review evidence did not parse" "the current-head evidence scan"
}

# The other half of ludics-lite#89: a `capture` that never errors, it just stops producing. The
# table test admits a Code Review Running row and the stamp pattern beside it re-matches the same
# row; unbracketed, a row the second pattern misses is deleted from the stream — with every row
# after it — and the older 👍 then stands unopposed. Bracketed, the miss is a null that is
# counted, and a table this script can only half read is not an approval.
test_a_running_row_the_stamp_pattern_misses_is_unknown() {
  reset_fixture
  HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  REACTIONS_JSON="[$(reaction +1 "$PAST")]"
  COMMENTS_JSON="[$(plain_comment 1 "$PAST" '<!-- codex-pull-request-review-summary -->
| Code Review | Running <relative-time datetime="2026-09-01T00:01:00Z"> | `aaaaaaa` |')]"
  run_status
  assert_eq "$(state_tok "$STATE")" stalled "control: a row both patterns read is read"
  # The same row with the `datetime` attribute the stamp pattern needs taken out: still a Running
  # row to the test beside it, no longer one the stamp can read.
  COMMENTS_JSON="[$(plain_comment 1 "$PAST" '<!-- codex-pull-request-review-summary -->
| Code Review | Running now | `aaaaaaa` |')]"
  run_status
  assert_eq "$(state_tok "$STATE")" unknown \
    "a Running row the stamp pattern cannot read is not an approval"
  assert_contains "$(state_detail "$STATE")" "matched the Running test but not the" \
    "the detail should name the two patterns that stopped agreeing"
}

# --- an approval over open review threads (ludics-lite#289) -----------------------------------
# PR #277, round 6: two findings written against the previous head, the 👍 on the base-merge commit
# above it, and a `status` that said `approved` over both. An open thread is a finding nobody
# closed, whatever head it cites, so an approval with one under it is reported as `unresolved`,
# naming each thread by the id `reply` and `resolve` take and saying what clears it.

graphql_reads() { grep -c -x graphql "$REQUEST_LOG" || true; }

approved_fixture() {
  reset_fixture
  REACTIONS_JSON="[$(reaction +1 "$PAST")]"
}

test_an_approval_over_open_threads_is_unresolved() {
  approved_fixture
  THREADS_JSON="[$(review_thread 4053098120 false),$(review_thread 4053098122 false b.sh),$(review_thread 4053098001 true)]"
  run_cmd_status
  assert_eq "$CMD_RC" 0 "a state the reads answered exits 0; merge is the gate that refuses it"
  assert_contains "$CMD_OUT" "approved (👍 from $REVIEWER) BUT 2 review thread(s) still UNRESOLVED" \
    "the approval is named and so are the open threads under it"
  assert_contains "$CMD_OUT" "4053098120 by codex[bot] on a.sh, 4053098122 by codex[bot] on b.sh" \
    "each open thread by the id reply and resolve take"
  assert_not_contains "$CMD_OUT" 4053098001 "a resolved thread is not open"
  assert_contains "$CMD_OUT" "pr-review.sh resolve $REPO#7 <id>" "and the line says what clears it"
  assert_eq "$(graphql_reads)" 1 "one read of the threads, for the one approval reported"
}

test_an_approval_with_every_thread_resolved_stays_approved() {
  approved_fixture
  THREADS_JSON="[$(review_thread 4053098001 true)]"
  run_cmd_status
  assert_eq "$CMD_RC" 0 "a clean approval"
  assert_contains "$CMD_OUT" "approved (👍 from $REVIEWER)" "reads as it always did"
  assert_not_contains "$CMD_OUT" UNRESOLVED "with nothing open under it"
}

test_only_an_approval_reads_the_threads() {
  # The read budget: every other state is reported without the GraphQL read, so a status (and a
  # watch round, which gates the same way) that is not about to report an approval costs nothing.
  idle_fixture
  THREADS_JSON="[$(review_thread 4053098120 false)]"
  run_cmd_status
  assert_contains "$CMD_OUT" "the next move is yours" "an idle head is reported as idle"
  assert_eq "$(graphql_reads)" 0 "and the threads are never read for it"
}

test_an_unread_thread_connection_is_unknown_not_approved() {
  approved_fixture
  FAIL_GRAPHQL=1
  run_cmd_status
  assert_eq "$CMD_RC" 3 "a thread read that did not answer is exit 3"
  assert_contains "$CMD_OUT" "UNKNOWN — GraphQL did not answer the review-threads read" \
    "and says it is transport, not an approval"
  assert_not_contains "$CMD_OUT" "approved (" "the approval is withheld, never granted on a failed read"
}

test_the_thread_read_pages_to_the_end() {
  approved_fixture
  THREADS_FIXTURE_PAGE=2
  THREADS_JSON="[$(review_thread 1 true),$(review_thread 2 true),$(review_thread 3 true),$(review_thread 4 true),$(review_thread 5 false)]"
  run_cmd_status
  assert_contains "$CMD_OUT" "BUT 1 review thread(s) still UNRESOLVED — NOT a clean approval, and \`merge\` refuses it: 5 by" \
    "an open thread on the third page is found"
  assert_eq "$(graphql_reads)" 3 "one read per page, and no more"
}

test_a_count_that_leads_the_rows_is_unread() {
  # #293's lesson: a connection that states more threads than it served is a partial read, and
  # the missing ones are exactly where an open thread could be.
  approved_fixture
  THREADS_FIXTURE_TOTAL=9
  THREADS_JSON="[$(review_thread 1 true),$(review_thread 2 true),$(review_thread 3 true)]"
  run_cmd_status
  assert_eq "$CMD_RC" 3 "a partial read is unread"
  assert_contains "$CMD_OUT" "ended at 3 thread(s) while the PR states 9" "and says how it was short"
}

test_a_read_still_paging_at_the_cap_is_unread() {
  approved_fixture
  retune THREADS_PAGE_CAP=2
  THREADS_FIXTURE_PAGE=2
  THREADS_JSON="[$(review_thread 1 true),$(review_thread 2 true),$(review_thread 3 true),$(review_thread 4 true),$(review_thread 5 true)]"
  run_cmd_status
  assert_eq "$CMD_RC" 3 "a prefix is not the connection"
  assert_contains "$CMD_OUT" "still paging after 2 pages of 100" "the cap refuses rather than judging a prefix"
  assert_eq "$(graphql_reads)" 2 "and stops at the cap"
}

test_a_thread_with_no_resolution_field_is_open() {
  approved_fixture
  THREADS_JSON="[$(review_thread 77 false | jq -c 'del(.isResolved)')]"
  run_cmd_status
  assert_contains "$CMD_OUT" "BUT 1 review thread(s) still UNRESOLVED" \
    "only an isResolved of true closes a thread"
}

test_a_thread_path_is_shell_quoted() {
  approved_fixture
  THREADS_JSON="[$(review_thread 77 false 'dir/a b;c.sh')]"
  run_cmd_status
  assert_contains "$CMD_OUT" "77 by codex[bot] on $(printf '%q' 'dir/a b;c.sh')" \
    "a repository-controlled path is quoted in the line"
}

test_a_broken_jq_program_is_unknown_on_the_thread_read() {
  approved_fixture
  THREADS_JSON="[$(review_thread 77 false)]"
  set +e
  CMD_OUT=$(with_broken_jq 'select(.isResolved != true)' cmd_status 7 2>&1)
  CMD_RC=$?
  set -e
  assert_eq "$CMD_RC" 3 "open threads that did not parse are not 'none are open'"
  assert_contains "$CMD_OUT" "threads that did not parse" "the site says so"
}

tests=(
  test_empty_reviews_need_their_own_findings
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
  test_a_round_and_its_state_are_one_read
  test_a_round_reads_the_head_after_its_feeds
  test_the_state_is_about_the_head_the_round_was_classified_against
  test_a_failed_round_hands_the_state_nothing
  test_status_after_a_watch_reads_for_itself
  test_a_dead_watch_s_snapshot_directory_is_swept
  test_every_other_family_a_dead_process_leaves_is_swept_too
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
  test_a_broken_jq_program_is_unknown_not_a_value
  test_a_broken_jq_program_is_unknown_on_the_failed_head_read
  test_a_broken_jq_program_is_unknown_on_the_pending_request_read
  test_a_broken_jq_program_is_unknown_on_the_current_head_evidence
  test_a_running_row_the_stamp_pattern_misses_is_unknown
  test_an_approval_over_open_threads_is_unresolved
  test_an_approval_with_every_thread_resolved_stays_approved
  test_only_an_approval_reads_the_threads
  test_an_unread_thread_connection_is_unknown_not_approved
  test_the_thread_read_pages_to_the_end
  test_a_count_that_leads_the_rows_is_unread
  test_a_read_still_paging_at_the_cap_is_unread
  test_a_thread_with_no_resolution_field_is_open
  test_a_thread_path_is_shell_quoted
  test_a_broken_jq_program_is_unknown_on_the_thread_read
)

run_tests "${tests[@]}"
exit "$?"
}
