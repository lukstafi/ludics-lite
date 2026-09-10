#!/usr/bin/env bash
# Fixture tests for the two WRITING commands, `reply` and `resolve`, and for the folded id token
# they take (ludics-lite#76). Until this suite they had no fixture coverage at all: every other
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
test_tmpdir TEST_ROOT reply-test

REPO=example/repo
REQUEST_LOG="$TEST_ROOT/requests"
BODIES="$TEST_ROOT/bodies"
UNEXPECTED="$TEST_ROOT/unexpected"

# The comment id whose write fails, and how. 0 is never.
FAIL_ID=0
FAIL_MSG=""
# The threads the PR has, as "<comment id>:<resolved>" pairs; a comment id absent from this list
# is a thread that does not exist, which is `resolve`'s one exit-1 answer.
THREADS="900:false 901:false 902:false 903:true"

reset_fixture() {
  : >"$REQUEST_LOG"
  : >"$UNEXPECTED"
  rm -rf "$BODIES"
  mkdir -p "$BODIES"
  FAIL_ID=0
  FAIL_MSG=""
  THREADS="900:false 901:false 902:false 903:true"
}

threads_json() {
  local pair nodes=""
  for pair in $THREADS; do
    nodes="$nodes,$(jq -cn --arg id "T${pair%%:*}" --argjson res "${pair##*:}" \
      --argjson db "${pair%%:*}" \
      '{id:$id, isResolved:$res, comments:{nodes:[{databaseId:$db}]}}')"
  done
  jq -cn --argjson nodes "[${nodes#,}]" \
    '{data:{repository:{pullRequest:{reviewThreads:
      {pageInfo:{hasNextPage:false, endCursor:null}, nodes:$nodes}}}}}'
}

# The body of a write is read off the raw arguments rather than out of the shared parser: the
# parser consumes an option's value on purpose (a `-f body=…` must not become the endpoint), and
# what these cases are about is exactly WHICH body reached WHICH thread.
gh() {
  local arg body="" query="" id
  for arg in "$@"; do
    case "$arg" in
    body=*) body="${arg#body=}" ;;
    query=*) query="${arg#query=}" ;;
    esac
  done
  gh_fixture_parse "$@"
  case "$FIXTURE_ENDPOINT" in
  "repos/$REPO/pulls/7/comments/"*"/replies")
    id="${FIXTURE_ENDPOINT#repos/$REPO/pulls/7/comments/}"
    id="${id%/replies}"
    printf '%s' "$body" >>"$BODIES/$id"
    if [ "$FAIL_ID" != 0 ] && [ "$id" = "$FAIL_ID" ]; then
      echo "gh: $FAIL_MSG" >&2
      return 1
    fi
    gh_fixture_answer "$(jq -cn --arg id "$id" \
      '{html_url:("https://github.com/example/repo/pull/7#discussion_r" + $id)}')"
    ;;
  graphql)
    case "$query" in
    *resolveReviewThread*)
      printf '%s\n' "$query" >>"$BODIES/mutations"
      gh_fixture_answer '{"data":{"resolveReviewThread":{"thread":{"isResolved":true}}}}'
      ;;
    *) gh_fixture_answer "$(threads_json)" ;;
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
  reset_fixture
  run_cmd cmd_reply 900 "Fixed in round 3" "and the rest of the sentence"
  assert_eq "$RC" 2 "an unquoted body is caught rather than posted in part"
  assert_eq "$(wc -l <"$REQUEST_LOG" | tr -d " ")" 0 "with nothing posted"
  reset_fixture
  run_cmd cmd_reply 900 "   "
  assert_eq "$RC" 2 "a blank body is nothing to post"
  assert_contains "$ERR" "the body is empty" "and says so"
  reset_fixture
  run_cmd cmd_resolve
  assert_eq "$RC" 2 "resolve wants its comment id too"
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
)

run_tests "${tests[@]}"
