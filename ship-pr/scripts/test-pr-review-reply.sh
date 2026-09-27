#!/usr/bin/env bash
# Fixture tests for the WRITING commands, `reply` and `resolve`, the folded id token they take
# (ludics-lite#76), `body`, which replaces a PR's description over REST, and `comment`, which posts
# a plain PR comment. Until this suite they had no fixture coverage at all: every other
# suite drives a read path, and the writes were exercised only against the live API, where a
# double-posted reply is not something a test may risk.
#
# What the cases are about:
#   - one invocation answers a whole folded entry — the body to the ANCHOR thread, a one-line
#     pointer to that reply into each duplicate — because a duplicate that cost its own composed
#     answer is the whole complaint the fold came from (round 11 of ludics-lite#66: nine threads
#     for four findings);
#   - the token is refused unless it is a comment id or several joined by single `+`, since an id
#     that stayed "900+901" would address no comment and come back as a 404 the caller would read
#     as a missing thread;
#   - a failure MID-batch never reports "nothing was posted": a reply is the one write here that
#     cannot be repeated safely, so the refusal names what landed and what to retry with. That is
#     the case with a negative control on either side — the first id failing DOES say nothing was
#     posted — because a progress note that is always the same says nothing at all.
#
# `reply` and `resolve` refuse by calling `fail`, which EXITS; every case therefore runs the
# command in a subshell, with errexit off so the refusal's own exit code survives to be read.

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
test_tmpdir TEST_ROOT reply-test

# The repo the fixture IS, and the repo pr-review.sh is told about. Two names for one string
# because the cwd cases below clear REPO to drive `resolve_repo`'s inference, and the fixture must
# still know which repository it is answering for.
TARGET_REPO=example/repo
REPO="$TARGET_REPO"
REQUEST_LOG="$TEST_ROOT/requests"
BODIES="$TEST_ROOT/bodies"
UNEXPECTED="$TEST_ROOT/unexpected"

# What `gh repo view` answers, i.e. what `repo_from_cwd` infers. Empty = gh does not answer, and
# the inference falls through to the cwd's `origin` remote, as it does in production.
CWD_REPO=""
# The comment id whose write fails, and how. 0 is never.
FAIL_ID=0
FAIL_MSG=""
# The threads the PR has, as "<comment id>:<resolved>" pairs; a comment id absent from this list
# is a thread that does not exist, which is `resolve`'s one exit-1 answer. How the connection pages
# them, and a totalCount other than the rows it serves, are the library's THREADS_FIXTURE_PAGE and
# THREADS_FIXTURE_TOTAL (review_threads_answer).
THREADS="900:false 901:false 902:false 903:true"
THREADS_FIXTURE_PAGE=""
THREADS_FIXTURE_TOTAL=""
# How many PATCHes of the PR body fail (with FAIL_MSG) before one succeeds.
BODY_FAILS=0
# How many POSTs of a plain PR comment fail (with FAIL_MSG) before one succeeds.
COMMENT_FAILS=0

reset_fixture() {
  : >"$REQUEST_LOG"
  : >"$UNEXPECTED"
  rm -rf "$BODIES"
  mkdir -p "$BODIES"
  FAIL_ID=0
  FAIL_MSG=""
  CWD_REPO=""
  REPO="$TARGET_REPO"
  THREADS="900:false 901:false 902:false 903:true"
  THREADS_FIXTURE_PAGE=""
  THREADS_FIXTURE_TOTAL=""
  BODY_FAILS=0
  COMMENT_FAILS=0
}

# THREADS as review_thread rows (which serve `databaseId` null past 2^31, as GitHub does).
thread_rows() {
  local pair nodes=""
  for pair in $THREADS; do
    nodes="$nodes,$(review_thread "${pair%%:*}" "${pair##*:}")"
  done
  printf '[%s]\n' "${nodes#,}"
}

# What a write sent is read off the shared parser (FIXTURE_METHOD, FIXTURE_BODY and its kind):
# it takes every spelling pflag does and consumes each option's value, so a case pins the request,
# not how it was typed, and a call gh itself refuses -- a repeated field, a field with no `=` --
# is refused there rather than answered.
#
# The boundary is spelling, not ENCODING, and it fails closed. How a body is carried is part of what
# a command is responsible for, not a detail of how it was typed: `-f` sends a string as written,
# `-F` converts types, expands placeholders and reads `@file`, and `--input` replaces the body with
# a file. `body` sends a file on purpose, and refuses stdin because a retry would find it spent.
# So each branch requires the kind its command's encoding needs and refuses the others: a reply
# and a comment go out verbatim, so their body must be a RAW field -- a typed `-F body=…` would send
# `true`, `42` or `@notes.md` as something else -- while the PR PATCH reads `@file`, which only a
# typed field does (`-f body=@file` sends the literal string). A change of encoding is a change
# these cases are meant to notice, never one they pass in silence.
gh() {
  local body query id method
  # `repo view` is not an `api` call, so it is answered before gh_fixture_parse, which refuses
  # everything else. It is answered at all because `repo_from_cwd` asks it first and the cwd cases
  # below need the inference armed; with CWD_REPO empty it fails the way gh does when GraphQL is
  # down, and the inference falls through to the `origin` remote.
  if [ "${1:-}" = repo ] && [ "${2:-}" = view ]; then
    [ -n "$CWD_REPO" ] || return 1
    printf '%s\n' "$CWD_REPO"
    return 0
  fi
  gh_fixture_parse "$@"
  body="$FIXTURE_BODY" query="$FIXTURE_QUERY" method="$FIXTURE_METHOD"
  case "$FIXTURE_ENDPOINT" in
  "repos/$TARGET_REPO/pulls/7/comments/"*"/replies")
    id="${FIXTURE_ENDPOINT#repos/$TARGET_REPO/pulls/7/comments/}"
    id="${id%/replies}"
    [ "$FIXTURE_BODY_KIND" = raw ] || {
      printf 'a reply body sent as a %s field, not a raw one\n' "${FIXTURE_BODY_KIND:-missing}" >>"$UNEXPECTED"
      return 1
    }
    printf '%s' "$body" >>"$BODIES/$id"
    if [ "$FAIL_ID" != 0 ] && [ "$id" = "$FAIL_ID" ]; then
      echo "gh: $FAIL_MSG" >&2
      return 1
    fi
    gh_fixture_answer "$(jq -cn --arg id "$id" \
      '{html_url:("https://github.com/example/repo/pull/7#discussion_r" + $id)}')"
    ;;
  # `body`: the PR itself, PATCHed with a field gh reads from a file (`-F body=@<path>`). What the
  # fixture keeps is what gh would have SENT — the file's content — and the method, since the
  # same endpoint read with GET would be a different call answering 200 without changing a thing.
  "repos/$TARGET_REPO/pulls/7")
    printf '%s\n' "$method" >>"$BODIES/pr-methods"
    [ "$FIXTURE_BODY_KIND" = typed ] || {
      printf 'the PR body sent as a %s field, which does not read @file\n' "${FIXTURE_BODY_KIND:-missing}" >>"$UNEXPECTED"
      return 1
    }
    case "$body" in
    @*) cat "${body#@}" >"$BODIES/pr-body" 2>/dev/null || return 1 ;;
    *) printf 'the body was not sent as a file: %s\n' "$body" >>"$UNEXPECTED" && return 1 ;;
    esac
    # Counted off the log, not by decrementing BODY_FAILS: gh_retry calls gh in a command
    # substitution, a subshell whose assignments never reach the next attempt.
    if [ "$(wc -l <"$BODIES/pr-methods")" -le "$BODY_FAILS" ]; then
      echo "gh: $FAIL_MSG" >&2
      return 1
    fi
    gh_fixture_answer '{"html_url":"https://github.com/example/repo/pull/7","body":"ignored"}'
    ;;
  # `comment`: a plain PR comment, which on GitHub is an ISSUE comment. The pulls/7/comments
  # endpoint (inline review comments) is deliberately absent, so a call there lands in UNEXPECTED.
  # Attempts are counted off a log for the same reason as the PATCH above.
  "repos/$TARGET_REPO/issues/7/comments")
    printf '%s\n' "$method" >>"$BODIES/comment-methods"
    [ "$FIXTURE_BODY_KIND" = raw ] || {
      printf 'a comment body sent as a %s field, not a raw one\n' "${FIXTURE_BODY_KIND:-missing}" >>"$UNEXPECTED"
      return 1
    }
    printf '%s' "$body" >"$BODIES/comment"
    if [ "$(wc -l <"$BODIES/comment-methods")" -le "$COMMENT_FAILS" ]; then
      echo "gh: $FAIL_MSG" >&2
      return 1
    fi
    gh_fixture_answer '{"html_url":"https://github.com/example/repo/pull/7#issuecomment-4242","body":"ignored"}'
    ;;
  graphql)
    case "$query" in
    *resolveReviewThread*)
      printf '%s\n' "$query" >>"$BODIES/mutations"
      gh_fixture_answer '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
      ;;
    *) gh_fixture_answer "$(review_threads_answer "$(thread_rows)" "$@")" ;;
    esac
    ;;
  *)
    printf '%s\n' "$FIXTURE_ENDPOINT" >>"$UNEXPECTED"
    return 1
    ;;
  esac
}

# The command under test writes and may EXIT; the subshell keeps that exit from ending the suite,
# and errexit stays off across it so the refusal's code is what lands in RC.
run_cmd() { # <cmd_reply|cmd_resolve> <args...>
  local fn="$1"
  shift
  set +e
  ("$fn" 7 "$@") >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  RC=$?
  set -e
  OUT=$(cat "$TEST_ROOT/out")
  ERR=$(cat "$TEST_ROOT/err")
  [ ! -s "$UNEXPECTED" ] || bail "the fixture was asked for an endpoint it does not know: $(cat "$UNEXPECTED")"
}

posted_to() { # <comment id>: the body that reached that thread, empty if none did
  cat "$BODIES/$1" 2>/dev/null || true
}

writes_to() { # <comment id>: how many replies were posted into that thread
  grep -c -F "comments/$1/replies" "$REQUEST_LOG" || true
}

# --- one invocation per folded entry ------------------------------------------------------------

# The shape the issue was filed on. Three threads, one finding: the caller composes ONE answer and
# hands back the token poll rendered.
test_a_folded_entry_is_answered_by_one_invocation() {
  reset_fixture
  run_cmd cmd_reply 900+901+902 "Fixed in round 3 (abc1234): the guard now fires."
  assert_eq "$RC" 0 "answering a folded entry succeeds"
  assert_contains "$(posted_to 900)" "Fixed in round 3 (abc1234): the guard now fires." \
    "the anchor thread gets the composed answer"
  assert_contains "$(posted_to 900)" "Addressed by an automated coding agent" \
    "with the marker every reply from this script carries"
  assert_contains "$(posted_to 901)" \
    "Duplicate of the thread answered at https://github.com/example/repo/pull/7#discussion_r900" \
    "each duplicate gets a pointer to where the answer is"
  assert_not_contains "$(posted_to 901)" "the guard now fires" \
    "and not the body again: one composed answer is the point"
  assert_contains "$(posted_to 902)" "#discussion_r900" "every duplicate, not just the second"
  assert_contains "$OUT" "#discussion_r901" "every reply's url is printed, so the caller sees them"
  assert_eq "$(writes_to 900)" 1 "the anchor is written to once"
  assert_eq "$(writes_to 902)" 1 "and so is each duplicate"
}

# The control on all of the above: an ordinary single-thread reply is unchanged — the body, once,
# and no pointer anywhere. Without it the pointer could be leaking into every reply the loop posts.
test_a_single_thread_reply_is_unchanged() {
  reset_fixture
  run_cmd cmd_reply 900 "Fixed in round 3 (abc1234): the guard now fires."
  assert_eq "$RC" 0 "a single reply succeeds"
  assert_contains "$(posted_to 900)" "the guard now fires" "the body goes to the thread"
  assert_not_contains "$(posted_to 900)" "Duplicate of the thread" \
    "a lone thread is nobody's duplicate"
  assert_eq "$OUT" "https://github.com/example/repo/pull/7#discussion_r900" \
    "and its url is the whole of stdout"
}

# A token that names the same thread twice is one thread: the entry it came from is one finding
# either way, and a second write would post the pointer into the thread that holds the answer.
test_a_repeated_id_costs_one_write() {
  reset_fixture
  run_cmd cmd_reply 900+900 "Fixed in round 3 (abc1234)."
  assert_eq "$RC" 0 "a repeated id is not an error"
  assert_eq "$(writes_to 900)" 1 "it is written to once"
  assert_not_contains "$(posted_to 900)" "Duplicate of the thread" \
    "and never pointed at itself"
}

# --- the token ----------------------------------------------------------------------------------

# The split is new, and an id left as "900+901" would address no comment: the API would answer 404
# and the caller would read a missing thread. So anything that is not a `+`-joined list of comment
# ids is an invocation error (exit 2), before any write.
test_a_malformed_token_is_refused_before_anything_is_posted() {
  local token
  for token in 900+9a1 900++901 +900 900+ "" abc "900 901" "900,901"; do
    reset_fixture
    run_cmd cmd_reply "$token" "a body"
    assert_eq "$RC" 2 "'$token' is an invocation error, not a write ($ERR)"
    assert_contains "$ERR" "comment id" "the refusal should name what it wanted ($token)"
    assert_eq "$(wc -l <"$REQUEST_LOG" | tr -d ' ')" 0 "nothing may be posted for '$token'"
  done
  # The control: the shapes that ARE the token both go through, or the refusal above proves only
  # that the command refuses everything.
  reset_fixture
  run_cmd cmd_reply 900+901 "a body"
  assert_eq "$RC" 0 "the folded form is accepted ($ERR)"
  reset_fixture
  run_cmd cmd_resolve 900+901
  assert_eq "$RC" 0 "and resolve takes the same token ($ERR)"
}

# The token is matched WHOLE before it is split, because the split is an unquoted expansion: it
# word-splits, and it globs. "900 901" above is the first half; this is the second — a token of
# glob characters expanded against the caller's working directory, where a numeric FILENAME became
# a comment id the script replied to and resolved (round 1 of #86).
test_a_glob_token_cannot_take_its_ids_from_the_filesystem() {
  local dir="$TEST_ROOT/cwd"
  reset_fixture
  rm -rf "$dir"
  mkdir -p "$dir"
  : >"$dir/900"
  : >"$dir/901"
  [ -e "$dir/900" ] || bail "the case needs numeric filenames for the glob to find"
  set +e
  (cd "$dir" && cmd_reply 7 "*" "a body") >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  RC=$?
  set -e
  OUT=$(cat "$TEST_ROOT/out")
  ERR=$(cat "$TEST_ROOT/err")
  assert_eq "$RC" 2 "a glob is not a comment id"
  assert_contains "$ERR" "is not a comment id" "and is refused as the token it is"
  assert_eq "$(wc -l <"$REQUEST_LOG" | tr -d " ")" 0 \
    "with nothing written to the threads the directory listing happens to name"
  # The control: from that same directory, a real token still works — the refusal is about the
  # token and not about where the command was run.
  reset_fixture
  set +e
  (cd "$dir" && cmd_reply 7 900 "a body") >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  RC=$?
  set -e
  assert_eq "$RC" 0 "a real id from the same directory posts ($(cat "$TEST_ROOT/err"))"
  assert_eq "$(writes_to 900)" 1 "to the thread it names"
}

# An unquoted body arrives as several arguments, and the `${3:?body}` form these commands used to
# open with would have posted its first word and dropped the rest — which reads, in a log, as a
# posted reply. The arity is checked instead, as an invocation error (exit 2) rather than the
# exit 1 that means "the fact does not hold".
test_the_invocation_shape_is_a_usage_error() {
  reset_fixture
  run_cmd cmd_reply 900
  assert_eq "$RC" 2 "a reply with no body is an invocation error"
  assert_contains "$ERR" "got 2 argument(s)" "and the refusal counts what it got"
  assert_eq "$(wc -l <"$REQUEST_LOG" | tr -d " ")" 0 "with nothing posted"
  reset_fixture
  run_cmd cmd_reply 900 "Fixed in round 3" "and the rest of the sentence"
  assert_eq "$RC" 2 "an unquoted body is caught rather than posted in part"
  assert_eq "$(wc -l <"$REQUEST_LOG" | tr -d " ")" 0 "with nothing posted"
  reset_fixture
  run_cmd cmd_reply 900 "   "
  assert_eq "$RC" 2 "a blank body is nothing to post"
  assert_contains "$ERR" "the body is empty" "and says so"
  assert_eq "$(wc -l <"$REQUEST_LOG" | tr -d " ")" 0 "with nothing posted"
  reset_fixture
  run_cmd cmd_resolve
  assert_eq "$RC" 2 "resolve wants its comment id too"
  assert_eq "$(wc -l <"$REQUEST_LOG" | tr -d " ")" 0 "with nothing read or written"
  # The control: the shape they do want posts, so the refusals above are about the shape.
  reset_fixture
  run_cmd cmd_reply 900 "Fixed in round 3 (abc1234)."
  assert_eq "$RC" 0 "three arguments, one of them a quoted body ($ERR)"
}

# --- a failure mid-batch --------------------------------------------------------------------------

# The reply is the one write here that cannot be repeated safely. A refusal that said "nothing was
# posted" once the anchor had landed would invite the caller to post the same answer twice, so the
# refusal names the ids that DID get one and the ids to retry with.
test_a_failure_after_the_anchor_says_what_landed() {
  reset_fixture
  FAIL_ID=901
  FAIL_MSG="503 No server is currently available to service your request"
  run_cmd cmd_reply 900+901+902 "Fixed in round 3 (abc1234)."
  assert_eq "$RC" 3 "a gateway refusal is transport"
  assert_contains "$ERR" "The replies to 900 DID land, so do not repeat those" "what landed is named"
  assert_contains "$ERR" "retry with: 901+902 --anchor 900" \
    "and so is the retry — as a token that can be pasted, and keeping the anchor that answered"
  assert_eq "$(writes_to 902)" 0 "and the batch stops rather than skipping past the failure"
  # The negative control: the SAME failure on the first id really does say nothing landed, so the
  # progress note above is a report and not a fixed string.
  reset_fixture
  FAIL_ID=900
  FAIL_MSG="503 No server is currently available to service your request"
  run_cmd cmd_reply 900+901+902 "Fixed in round 3 (abc1234)."
  assert_eq "$RC" 3 "the same transport failure, at the anchor"
  assert_contains "$ERR" "Nothing was posted for comment 900, so retry with: 900+901+902" \
    "with nothing up, the whole invocation is the retry"
  assert_not_contains "$ERR" "--anchor" "and there is no answered thread to anchor to"
  assert_not_contains "$ERR" "DID land" "and nothing is claimed to have landed"
}

# A gateway refusal is a request no backend ran, and the message may say so. An AMBIGUOUS failure
# is not: a 500 or a dropped connection may be a reply that landed. The first cut of this said
# "nothing in this invocation was posted, so repeat it whole" directly under a sentence saying the
# reply may have landed (round 2 of #86) — a contradiction whose obedient reading posts the
# composed answer twice.
test_an_ambiguous_write_never_claims_nothing_was_posted() {
  reset_fixture
  FAIL_ID=900
  FAIL_MSG="Internal Server Error (HTTP 500)"
  run_cmd cmd_reply 900+901 "Fixed in round 3 (abc1234)."
  assert_eq "$RC" 3 "an ambiguous write is transport, not a verdict"
  assert_contains "$ERR" "the reply MAY have landed" "and is reported as the question it is"
  assert_not_contains "$ERR" "Nothing was posted" \
    "which is a claim a 500 does not support, and the one that invites a double post"
  assert_not_contains "$ERR" "repeat it whole" "nor may the instruction contradict the sentence"
  assert_contains "$ERR" "Read comment 900's thread" "the caller is sent to look"
  assert_contains "$ERR" "retry with: 900+901 if the reply is not there" "with both answers named"
  assert_contains "$ERR" "retry with: 901 --anchor 900 if it is" \
    "the second keeping the thread that may already hold the answer as the anchor"
  # The control on the pair: the gateway refusal at the same id DOES say nothing was posted, so
  # the two classifications are reported differently rather than by one hedged string.
  reset_fixture
  FAIL_ID=900
  FAIL_MSG="503 No server is currently available to service your request"
  run_cmd cmd_reply 900+901 "Fixed in round 3 (abc1234)."
  assert_contains "$ERR" "Nothing was posted for comment 900" "a refused request posted nothing"
  assert_not_contains "$ERR" "MAY have landed" "and that is not in question"
}

# The three exits a write can take are kept apart on a folded reply exactly as on a single one: a
# 4xx is the API ANSWERING (exit 1, retrying prints the same thing), anything else ambiguous
# (exit 3, and this script will not post it twice).
test_the_write_exits_stay_apart_inside_a_batch() {
  reset_fixture
  FAIL_ID=901
  FAIL_MSG="Not Found (HTTP 404)"
  run_cmd cmd_reply 900+901 "Fixed in round 3 (abc1234)."
  assert_eq "$RC" 1 "a 404 is the API answering about that comment"
  assert_contains "$ERR" "was REJECTED, not dropped" "and the message says so"
  assert_contains "$ERR" "The replies to 900 DID land" "with the batch's progress either way"
  assert_contains "$ERR" "Comment 901 got nothing, so once the id is right, retry with: 901 --anchor 900" \
    "a rejected write posted nothing, so its retry set is exact"
  reset_fixture
  FAIL_ID=901
  FAIL_MSG="Internal Server Error (HTTP 500)"
  run_cmd cmd_reply 900+901 "Fixed in round 3 (abc1234)."
  assert_eq "$RC" 3 "a 500 may or may not have posted"
  assert_contains "$ERR" "failed AMBIGUOUSLY" "and is reported as ambiguous, never as rejected"
}

# The retry a failed batch recommends has to be one that can be RUN: `--anchor` posts no body at
# all and points every id in the token at the thread that already holds the answer. Without it the
# suffix promotes its own first id to anchor, posting the composed body a second time and pointing
# the rest at the copy (round 3 of #86).
test_an_anchored_retry_points_at_the_thread_that_answered() {
  reset_fixture
  run_cmd cmd_reply 901+902 --anchor 900
  assert_eq "$RC" 0 "an anchored reply needs no body"
  assert_eq "$(writes_to 900)" 0 "the thread that answered is not written to again"
  assert_contains "$(posted_to 901)" \
    "Duplicate of the thread answered at https://github.com/example/repo/pull/7#discussion_r900" \
    "and every id in the token is pointed at it, by the url its comment id gives"
  assert_contains "$(posted_to 902)" "#discussion_r900" "every one of them"
  assert_not_contains "$(posted_to 902)" "#discussion_r901" \
    "never at each other: the answer is in 900, and a chain of pointers is not an answer"
  # The refusals around it: a body with --anchor is an invocation error (there is nothing to post
  # it as), and so is anchoring a thread to itself.
  reset_fixture
  run_cmd cmd_reply 901 --anchor 900 "a body nobody asked for"
  assert_eq "$RC" 2 "with --anchor the answer is already written"
  assert_contains "$ERR" "no body is taken" "and the refusal says so"
  reset_fixture
  run_cmd cmd_reply 900+901 --anchor 900
  assert_eq "$RC" 2 "a thread cannot be pointed at itself"
  assert_contains "$ERR" "is also in the token" "and the refusal names the collision"
  assert_eq "$(wc -l <"$REQUEST_LOG" | tr -d " ")" 0 "with nothing posted"
  reset_fixture
  run_cmd cmd_reply 901 --anchor 90x
  assert_eq "$RC" 2 "the anchor is one comment id"
}

# --- resolve --------------------------------------------------------------------------------------

test_resolve_closes_every_thread_the_token_names() {
  reset_fixture
  run_cmd cmd_resolve 900+901+902
  assert_eq "$RC" 0 "the whole folded entry is closed"
  assert_eq "$(grep -c resolveReviewThread "$BODIES/mutations")" 3 "one mutation per thread"
  assert_contains "$OUT" "900 true" "each answer names the thread it is about"
  assert_contains "$OUT" "902 true" "every one of them"
  # The control: one id keeps the output it always had, a bare verdict with no id in front.
  reset_fixture
  run_cmd cmd_resolve 900
  assert_eq "$OUT" true "a single resolve still answers 'true' and nothing else"
}

# An already-resolved thread is the goal state, not a write. Inside a batch it must not be an
# error either — replying then resolving across rounds leaves exactly this shape.
test_an_already_resolved_thread_costs_no_write() {
  reset_fixture
  run_cmd cmd_resolve 903+900
  assert_eq "$RC" 0 "a resolved thread beside an open one is not a failure"
  assert_contains "$OUT" "903 true (already resolved)" "it is reported as already resolved"
  assert_contains "$OUT" "900 true" "and the open one is closed"
  assert_eq "$(grep -c resolveReviewThread "$BODIES/mutations")" 1 "with one mutation, not two"
}

# Where a batch stopped is part of the answer: resolving is idempotent, so the whole token can be
# repeated, and the message says that rather than leaving the caller to work it out.
test_a_missing_thread_names_where_the_batch_stopped() {
  reset_fixture
  run_cmd cmd_resolve 900+999
  assert_eq "$RC" 1 "a thread that does not exist is a real answer"
  assert_contains "$ERR" "no review thread starts at comment 999" "named as itself"
  assert_contains "$ERR" "Already resolved in this invocation: 900" "with what was closed first"
  assert_contains "$ERR" "safe to repeat" "and what repeating the token would cost"
  # The control: the same refusal on the FIRST id carries no progress note to be read as one.
  reset_fixture
  run_cmd cmd_resolve 999
  assert_eq "$RC" 1 "still exit 1 on its own"
  assert_not_contains "$ERR" "Already resolved in this invocation" \
    "nothing was closed, so nothing may be claimed"
}

# `resolve` finds a thread by the id the open-thread gate names it by: `fullDatabaseId`, the BigInt
# string, since `databaseId` is a 32-bit Int and review comment ids already run past 2^31. A lookup
# matching `databaseId` alone answered "no review thread starts at comment N" for a thread `merge`
# had just refused over by that very N.
test_resolve_finds_a_thread_by_its_full_width_id() {
  reset_fixture
  THREADS="900:false 4095735684:false"
  run_cmd cmd_resolve 4095735684
  assert_eq "$RC" 0 "a thread past 2^31 is found"
  assert_contains "$(cat "$BODIES/mutations")" '"T4095735684"' "and it is that thread that is closed"
  # The id is matched as GitHub serves it, so a zero-padded token still names the same thread.
  reset_fixture
  run_cmd cmd_resolve 0900
  assert_eq "$RC" 0 "leading zeros do not make a thread missing"
  assert_contains "$(cat "$BODIES/mutations")" '"T900"' "the thread 900 starts"
}

# "No such thread" is a claim about the WHOLE connection, so a read that came up short of the
# totalCount it states is a retry, not an answer — the thread could be in the part never served.
test_a_short_read_is_a_retry_not_a_missing_thread() {
  reset_fixture
  THREADS_FIXTURE_TOTAL=9
  run_cmd cmd_resolve 999
  assert_eq "$RC" 3 "an incomplete lookup is transport"
  assert_contains "$ERR" "ended at 4 thread(s) while the PR states 9" "and says how it was short"
  assert_not_contains "$ERR" "no review thread starts" "never a missing thread"
  # The control: a thread that IS on the part served is found all the same.
  reset_fixture
  THREADS_FIXTURE_TOTAL=9
  run_cmd cmd_resolve 900
  assert_eq "$RC" 0 "a hit needs no count"
}

# The lookup walks the WHOLE connection, page by page through the `after=` cursor, since it reads
# through the same threads_walk as the open-thread gate: a thread the gate names from page 2 is one
# `resolve` must find there, not one it reports missing after reading page 1.
test_resolve_finds_a_thread_on_a_later_page() {
  reset_fixture
  THREADS_FIXTURE_PAGE=2
  run_cmd cmd_resolve 902
  assert_eq "$RC" 0 "a thread on page 2 is found"
  assert_contains "$(cat "$BODIES/mutations")" '"T902"' "and it is that thread that is closed"
  # The control: an id on no page is still missing, after every page was read.
  reset_fixture
  THREADS_FIXTURE_PAGE=2
  run_cmd cmd_resolve 999
  assert_eq "$RC" 1 "an id on no page is a missing thread"
  assert_contains "$ERR" "no review thread starts at comment 999" "named as itself"
}

# --- the repo a write lands on is NAMED, never inferred from the cwd (ludics-lite#92) -----------

# `resolve_repo` verified a CACHED repo against repos/<repo>/pulls/<n> before trusting it — its
# comment says why, in these words: a wrong repo would post a reply onto an unrelated PR. The cwd
# branch ABOVE it did no such check and cached its answer besides, so a bare `reply 7` typed from a
# shell sitting in another project's worktree posted into whatever PR 7 is over there, and then
# remembered that repo for every later call about 7.
#
# Verifying such a guess is the fix that looks right and is not one, which is why the collision
# case below has a case of its own: repos/<repo>/pulls/7 answers "this repository has a seventh
# PR", and every active repository does. So the guess is refused instead — the cwd, and the per-PR
# cache that carried the same ambiguity across checkouts and sessions (round 2 of #161).
# These cases run the writing commands with no repo named, from a scratch checkout whose `origin`
# names a third repository and with `gh repo view` answering a fourth: both halves of the inference
# armed, as in #74's control, and nothing read or written through either.
CWD_CHECKOUT=""
scratch_checkout() { # <owner/name the origin remote points at>
  test_tmpdir CWD_CHECKOUT cwd-checkout
  git -C "$CWD_CHECKOUT" init -q >/dev/null 2>&1 || bail "git init failed in $CWD_CHECKOUT"
  git -C "$CWD_CHECKOUT" remote add origin "https://github.com/$1.git" ||
    bail "git remote add failed in $CWD_CHECKOUT"
}

# run_cmd, but from the scratch checkout with REPO cleared and the PR spelled as the caller would,
# so the command has nothing but its argument to resolve from. The clearing happens INSIDE the
# subshell: resolve_repo assigns REPO, and a case that leaked that assignment would hand the next
# case a repo it never named.
run_cmd_from_cwd() { # <cmd_reply|cmd_resolve> <pr ref> <args...>
  local fn="$1" ref="$2"
  shift 2
  set +e
  (
    cd "$CWD_CHECKOUT" || exit 9
    REPO=""
    "$fn" "$ref" "$@"
  ) >"$TEST_ROOT/out" 2>"$TEST_ROOT/err"
  RC=$?
  set -e
  OUT=$(cat "$TEST_ROOT/out")
  ERR=$(cat "$TEST_ROOT/err")
  [ ! -s "$UNEXPECTED" ] || bail "the fixture was asked for an endpoint it does not know: $(cat "$UNEXPECTED")"
}

# The case the issue was filed on. On the code this replaces, the reply lands in cwd-inferred/repo's
# PR 7 and the command exits 0.
test_a_reply_never_takes_its_repo_from_the_cwd() {
  reset_fixture
  scratch_checkout cwd-git/repo
  CWD_REPO=cwd-inferred/repo
  run_cmd_from_cwd cmd_reply 7 900 "Fixed in round 3 (abc1234): the guard now fires."
  assert_eq "$RC" 2 "a bare PR number with no repo named is an invocation error ($ERR)"
  assert_contains "$ERR" "owner/name#7" "the refusal spells the form that names the repo"
  assert_contains "$ERR" "Nothing was read or written anywhere" "and says so plainly"
  assert_not_contains "$ERR" "cwd-inferred/repo" "the cwd's repo is not named as a target"
  assert_not_contains "$ERR" "cwd-git/repo" "and neither is the origin remote's"
  assert_eq "$(posted_to 900)" "" "no reply may reach the thread this number names anywhere"
  assert_eq "$(cat "$REQUEST_LOG")" "" "nothing may be read before the repo is known"
}

# The reviewer's case, and the reason the cwd is refused rather than verified: a checkout that DOES
# have a PR 7 passes repos/<repo>/pulls/7 exactly as a stranger's would. A verification that cannot
# fail on the invocation it exists for is not a safeguard, so it is not what stands here.
test_the_refusal_holds_when_the_cwd_repo_has_that_pr_number() {
  reset_fixture
  scratch_checkout "$TARGET_REPO"
  CWD_REPO="$TARGET_REPO"
  run_cmd_from_cwd cmd_reply 7 900 "Fixed in round 3 (abc1234): the guard now fires."
  assert_eq "$RC" 2 "a cwd whose repo really has PR 7 is refused just the same ($ERR)"
  assert_eq "$(posted_to 900)" "" "nothing is posted on the strength of the cwd"
  assert_eq "$(cat "$REQUEST_LOG")" "" \
    "and no verification is attempted: it would have PASSED, here and in the wrong repo alike"
}

# `resolve` is the other writing command and resolves through the same call, so it is refused on
# the same terms — and, being a GraphQL mutation, it would otherwise carry the guessed repo into
# the query itself. On the code this replaces it exits 0, having mutated the wrong repository.
test_a_resolve_never_takes_its_repo_from_the_cwd() {
  reset_fixture
  scratch_checkout cwd-git/repo
  CWD_REPO=cwd-inferred/repo
  run_cmd_from_cwd cmd_resolve 7 900
  assert_eq "$RC" 2 "resolve refuses a bare number too ($ERR)"
  assert_eq "$(cat "$REQUEST_LOG")" "" "no mutation, and no read, may be sent"
}

# The positive control: the refusal is about the repo being UNNAMED, not about the cwd. Naming it
# in the argument writes from the same wrong checkout, and writes to the repo the argument names.
test_a_named_repo_writes_from_any_cwd() {
  reset_fixture
  scratch_checkout cwd-git/repo
  CWD_REPO=cwd-inferred/repo
  run_cmd_from_cwd cmd_reply "$TARGET_REPO#7" 900 "Fixed in round 3 (abc1234): the guard now fires."
  assert_eq "$RC" 0 "an argument that names the repo is enough from anywhere ($ERR)"
  assert_contains "$(posted_to 900)" "the guard now fires." "and the reply lands where it names"
  assert_not_contains "$(cat "$REQUEST_LOG")" "cwd-inferred" "never where the cwd pointed"
}

# What round 2 of #161 caught, and the reason the per-PR repo cache is gone rather than kept as
# "the one inference left": it carries the same intent ambiguity the cwd did. It remembered a repo
# by NUMBER, across checkouts and across sessions, so once anything had named repo-a#7, a later
# bare `reply 7` meant for repo B resolved to repo A — and verification passed, because repo A does
# still have a PR 7. So a bare number is refused however many repos have been named before it.
test_a_bare_number_is_refused_even_after_a_named_call() {
  reset_fixture
  scratch_checkout cwd-git/repo
  CWD_REPO=cwd-inferred/repo
  run_cmd_from_cwd cmd_reply "$TARGET_REPO#7" 900 "Fixed in round 3 (abc1234)."
  assert_eq "$RC" 0 "naming the repo replies, and is what fills a memory if there is one ($ERR)"
  reset_fixture
  run_cmd_from_cwd cmd_reply 7 900 "Fixed in round 4 (def5678)."
  assert_eq "$RC" 2 "the next bare number is refused all the same ($ERR)"
  assert_eq "$(posted_to 900)" "" "nothing is posted on the strength of an earlier call"
  assert_eq "$(cat "$REQUEST_LOG")" "" "and nothing is read to try to make one stand up"
}

# --- `body`: the PR's description, over REST ------------------------------------------------------

# `gh pr edit --body-file` rides GraphQL and fails on lukstafi/ocannl-staging with the classic
# Projects deprecation error, so `body` PATCHes the pulls endpoint instead. The body is sent as the
# file gh reads (`-F body=@<file>`), byte for byte, backticks and all, and with no agent marker: it
# is the PR's own text, not a reply.
BODY_FILE=""
body_file() { # <content>
  BODY_FILE="$TEST_ROOT/new-body.md"
  printf '%s' "$1" >"$BODY_FILE"
}

test_body_patches_the_pr_from_the_file() {
  reset_fixture
  body_file $'## Summary\n\nUses `pr-review.sh body` — "quotes", $dollars and `ticks`.\n\nCloses #7\n'
  run_cmd cmd_body "$BODY_FILE"
  assert_eq "$RC" 0 "the body is replaced ($ERR)"
  assert_eq "$(cat "$BODIES/pr-methods")" PATCH "as a PATCH of the PR, the REST edit"
  assert_eq "$(cat "$BODIES/pr-body")" "$(cat "$BODY_FILE")" "with the file's content, exactly"
  assert_not_contains "$(cat "$BODIES/pr-body")" "Addressed by an automated coding agent" \
    "and no reply marker: the body is the PR's own text"
  assert_eq "$OUT" "https://github.com/example/repo/pull/7" "its url is the whole of stdout"
  assert_eq "$(cat "$REQUEST_LOG")" "repos/$TARGET_REPO/pulls/7" "one call, to the PR it names"
}

# The retry the other writes have: a gateway refusal is a request no backend ran, so it is
# repeated, and the edit that finally goes through is reported as done.
test_body_retries_a_gateway_refusal() {
  reset_fixture
  retune API_ATTEMPTS=3
  BODY_FAILS=2
  FAIL_MSG="503 No server is currently available to service your request"
  body_file "The body."
  run_cmd cmd_body "$BODY_FILE"
  assert_eq "$RC" 0 "the third attempt lands ($ERR)"
  assert_eq "$(wc -l <"$BODIES/pr-methods" | tr -d ' ')" 3 "after two refused ones"
  assert_contains "$ERR" "retrying" "each retry is announced on stderr"
  # Every attempt refused: transport, and the refusal may say nothing changed.
  reset_fixture
  retune API_ATTEMPTS=2
  BODY_FAILS=5
  FAIL_MSG="503 No server is currently available to service your request"
  run_cmd cmd_body "$BODY_FILE"
  assert_eq "$RC" 3 "a gateway refusal that outlives the attempts is transport"
  assert_contains "$ERR" "Nothing was changed, so retry" "and nothing was changed"
  assert_eq "$(wc -l <"$BODIES/pr-methods" | tr -d ' ')" 2 "after every attempt was spent"
}

# The other two exits, kept apart as on every write: a 4xx is the API answering (1, not retried —
# a retry answers the same), anything else ambiguous (3, not retried under the write policy).
# Unlike a reply, an ambiguous edit is safe to REPEAT, since the PATCH sets the body whole, and
# the message says so rather than sending the caller to read the PR first.
test_body_exits_stay_apart() {
  reset_fixture
  retune API_ATTEMPTS=3
  BODY_FAILS=1
  FAIL_MSG="Not Found (HTTP 404)"
  body_file "The body."
  run_cmd cmd_body "$BODY_FILE"
  assert_eq "$RC" 1 "a 404 is the API answering about that PR"
  assert_contains "$ERR" "was REJECTED, not dropped" "and the message says so"
  assert_eq "$(wc -l <"$BODIES/pr-methods" | tr -d ' ')" 1 "a rejection is not retried"
  reset_fixture
  retune API_ATTEMPTS=3
  BODY_FAILS=1
  FAIL_MSG="Internal Server Error (HTTP 500)"
  run_cmd cmd_body "$BODY_FILE"
  assert_eq "$RC" 3 "an ambiguous write is transport, not a verdict"
  assert_contains "$ERR" "repeating the same command is safe" "and a whole-body edit may be repeated"
  assert_eq "$(wc -l <"$BODIES/pr-methods" | tr -d ' ')" 1 "though the write policy does not repeat it itself"
}

# Every shape that is not `body <pr> <file>` is an invocation error, before any request: a missing
# file, stdin (gh reads `@-` once, so a retry would send its empty remainder as the body), an empty
# file (which would clear the description), a body passed inline, and a PR with no repo named.
test_body_invocation_errors_send_nothing() {
  reset_fixture
  run_cmd cmd_body "$TEST_ROOT/no-such-file"
  assert_eq "$RC" 2 "a missing file ($ERR)"
  assert_contains "$ERR" "is not a readable file" "is named as such"
  assert_eq "$(cat "$REQUEST_LOG")" "" "and sends no request"
  reset_fixture
  run_cmd cmd_body -
  assert_eq "$RC" 2 "stdin ($ERR)"
  assert_contains "$ERR" "stdin" "is refused by name"
  assert_eq "$(cat "$REQUEST_LOG")" "" "and sends no request"
  reset_fixture
  body_file $' \n\t\n'
  run_cmd cmd_body "$BODY_FILE"
  assert_eq "$RC" 2 "a blank file ($ERR)"
  assert_contains "$ERR" "is empty" "is nothing to set"
  assert_eq "$(cat "$REQUEST_LOG")" "" "and sends no request"
  reset_fixture
  body_file "The body."
  run_cmd cmd_body "$BODY_FILE" "and more"
  assert_eq "$RC" 2 "a stray argument ($ERR)"
  assert_contains "$ERR" "got 3 argument(s)" "is counted"
  assert_eq "$(cat "$REQUEST_LOG")" "" "and sends no request"
  reset_fixture
  scratch_checkout "$TARGET_REPO"
  CWD_REPO="$TARGET_REPO"
  run_cmd_from_cwd cmd_body 7 "$BODY_FILE"
  assert_eq "$RC" 2 "a bare PR number is refused here too, even from a checkout of the repo ($ERR)"
  assert_eq "$(cat "$REQUEST_LOG")" "" "and nothing is written on the strength of the cwd"
  # The control: the same file, with the repo named, goes through from that same checkout.
  reset_fixture
  run_cmd_from_cwd cmd_body "$TARGET_REPO#7" "$BODY_FILE"
  assert_eq "$RC" 0 "a named repo is enough from anywhere ($ERR)"
  assert_eq "$(cat "$BODIES/pr-body")" "The body." "and the body lands"
}

# --- `comment`: a plain PR comment, over REST -----------------------------------------------------

# A review's summary body has no thread to answer in, so its answer is a PR comment — posted to the
# ISSUES endpoint, since pulls/<n>/comments takes inline review comments, which need a commit and a
# path. It carries the same marker as `reply`.
comment_attempts() {
  wc -l <"$BODIES/comment-methods" 2>/dev/null | tr -d ' ' || echo 0
}

test_comment_posts_to_the_issues_endpoint() {
  reset_fixture
  run_cmd cmd_comment $'Addressed the summary:\n\n- `guard` now fires — "quoted", $dollars.'
  assert_eq "$RC" 0 "the comment is posted ($ERR)"
  assert_eq "$(cat "$REQUEST_LOG")" "repos/$TARGET_REPO/issues/7/comments" \
    "one call, to the issues endpoint and not pulls/7/comments"
  assert_eq "$(cat "$BODIES/comment-methods")" POST "as a POST"
  assert_eq "$(cat "$BODIES/comment")" \
    $'Addressed the summary:\n\n- `guard` now fires — "quoted", $dollars.\n\n_🤖 Addressed by an automated coding agent_' \
    "the body exactly as given, then the marker every reply from this script carries"
  assert_eq "$OUT" "https://github.com/example/repo/pull/7#issuecomment-4242" \
    "its url is the whole of stdout"
}

# A gateway refusal is a request no backend ran, so it is repeated; one that outlives the attempts
# is transport, and the refusal may say nothing was posted.
test_comment_retries_a_gateway_refusal() {
  reset_fixture
  retune API_ATTEMPTS=3
  COMMENT_FAILS=2
  FAIL_MSG="503 No server is currently available to service your request"
  run_cmd cmd_comment "The comment."
  assert_eq "$RC" 0 "the third attempt lands ($ERR)"
  assert_eq "$(comment_attempts)" 3 "after two refused ones"
  assert_contains "$ERR" "retrying" "each retry is announced on stderr"
  assert_eq "$OUT" "https://github.com/example/repo/pull/7#issuecomment-4242" \
    "and the url of the one that landed is printed"
  reset_fixture
  retune API_ATTEMPTS=2
  COMMENT_FAILS=5
  FAIL_MSG="503 No server is currently available to service your request"
  run_cmd cmd_comment "The comment."
  assert_eq "$RC" 3 "a gateway refusal that outlives the attempts is transport"
  assert_contains "$ERR" "on all 2 attempts" "the refusal counts the attempts"
  assert_contains "$ERR" "Nothing was posted, so retry" "and nothing was posted"
  assert_eq "$(comment_attempts)" 2 "after every attempt was spent"
}

# The other two exits, kept apart as on every write: a 4xx is the API answering (1, not retried),
# anything else ambiguous (3, not retried under the write policy). Unlike `body`, an ambiguous
# comment is NOT safe to repeat — a POST adds a comment — so the message sends the caller to read
# the PR first, and never says nothing was posted.
test_comment_exits_stay_apart() {
  reset_fixture
  retune API_ATTEMPTS=3
  COMMENT_FAILS=1
  FAIL_MSG="Not Found (HTTP 404)"
  run_cmd cmd_comment "The comment."
  assert_eq "$RC" 1 "a 404 is the API answering about that PR"
  assert_contains "$ERR" "was REJECTED, not dropped" "and the message says so"
  assert_eq "$(comment_attempts)" 1 "a rejection is not retried"
  reset_fixture
  retune API_ATTEMPTS=3
  COMMENT_FAILS=1
  FAIL_MSG="Internal Server Error (HTTP 500)"
  run_cmd cmd_comment "The comment."
  assert_eq "$RC" 3 "an ambiguous write is transport, not a verdict"
  assert_contains "$ERR" "failed AMBIGUOUSLY" "and is reported as ambiguous, never as rejected"
  assert_contains "$ERR" "will not post it twice" "it says it will not post twice"
  assert_not_contains "$ERR" "Nothing was posted" "a claim a 500 does not support"
  assert_eq "$(comment_attempts)" 1 "and the write policy does not repeat it itself"
}

# Every shape that is not `comment <pr> <body>` is an invocation error, before any request: a
# missing body, an unquoted one (which would otherwise post its first word), a blank one, and a
# PR with no repo named.
test_comment_invocation_errors_send_nothing() {
  reset_fixture
  run_cmd cmd_comment
  assert_eq "$RC" 2 "a comment with no body ($ERR)"
  assert_contains "$ERR" "got 1 argument(s)" "is counted"
  assert_eq "$(cat "$REQUEST_LOG")" "" "and sends no request"
  reset_fixture
  run_cmd cmd_comment "Fixed in round 3" "and the rest of the sentence"
  assert_eq "$RC" 2 "an unquoted body is caught rather than posted in part ($ERR)"
  assert_contains "$ERR" "got 3 argument(s)" "is counted"
  assert_contains "$ERR" "The body is ONE argument" "and the refusal says how to fix it"
  assert_eq "$(cat "$REQUEST_LOG")" "" "and sends no request"
  reset_fixture
  run_cmd cmd_comment $' \n\t '
  assert_eq "$RC" 2 "a blank body ($ERR)"
  assert_contains "$ERR" "the body is empty" "is nothing to post"
  assert_eq "$(cat "$REQUEST_LOG")" "" "and sends no request"
  reset_fixture
  scratch_checkout "$TARGET_REPO"
  CWD_REPO="$TARGET_REPO"
  run_cmd_from_cwd cmd_comment 7 "The comment."
  assert_eq "$RC" 2 "a bare PR number is refused here too, even from a checkout of the repo ($ERR)"
  assert_contains "$ERR" "owner/name#7" "the refusal spells the form that names the repo"
  assert_eq "$(cat "$REQUEST_LOG")" "" "and nothing is posted on the strength of the cwd"
  # The control: the same comment, with the repo named, goes through from that same checkout.
  reset_fixture
  run_cmd_from_cwd cmd_comment "$TARGET_REPO#7" "The comment."
  assert_eq "$RC" 0 "a named repo is enough from anywhere ($ERR)"
  assert_contains "$(cat "$BODIES/comment")" "The comment." "and the comment lands"
  assert_eq "$(cat "$REQUEST_LOG")" "repos/$TARGET_REPO/issues/7/comments" "on the PR it names"
}

tests=(
  test_a_folded_entry_is_answered_by_one_invocation
  test_a_single_thread_reply_is_unchanged
  test_a_repeated_id_costs_one_write
  test_a_malformed_token_is_refused_before_anything_is_posted
  test_a_glob_token_cannot_take_its_ids_from_the_filesystem
  test_the_invocation_shape_is_a_usage_error
  test_a_failure_after_the_anchor_says_what_landed
  test_an_ambiguous_write_never_claims_nothing_was_posted
  test_an_anchored_retry_points_at_the_thread_that_answered
  test_the_write_exits_stay_apart_inside_a_batch
  test_resolve_closes_every_thread_the_token_names
  test_an_already_resolved_thread_costs_no_write
  test_a_missing_thread_names_where_the_batch_stopped
  test_resolve_finds_a_thread_by_its_full_width_id
  test_a_short_read_is_a_retry_not_a_missing_thread
  test_resolve_finds_a_thread_on_a_later_page
  test_a_reply_never_takes_its_repo_from_the_cwd
  test_the_refusal_holds_when_the_cwd_repo_has_that_pr_number
  test_a_resolve_never_takes_its_repo_from_the_cwd
  test_a_named_repo_writes_from_any_cwd
  test_a_bare_number_is_refused_even_after_a_named_call
  test_body_patches_the_pr_from_the_file
  test_body_retries_a_gateway_refusal
  test_body_exits_stay_apart
  test_body_invocation_errors_send_nothing
  test_comment_posts_to_the_issues_endpoint
  test_comment_retries_a_gateway_refusal
  test_comment_exits_stay_apart
  test_comment_invocation_errors_send_nothing
)

run_tests "${tests[@]}"
exit "$?"
}
