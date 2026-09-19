#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's `merge`: the binding of the merge to the head the build
# signal was read for, the refusals of a --require-green (close-out) merge (ludics-lite#39), and the
# closing-keyword scan of the PR body that runs before the merge is issued (ludics-lite#227).
# The build signal itself is stubbed; the gate's own behaviour is test-pr-review-checks-absent.sh's.

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

REPO=example/repo
test_tmpdir TEST_ROOT merge-test
OUT_FILE="$TEST_ROOT/out"
ERR_FILE="$TEST_ROOT/err"
CALLS_FILE="$TEST_ROOT/calls"

CURRENT_HEAD=head-sha
SKIPS_ONLY=""                          # the head's checks all skipped/neutral
NO_CHECKS=""                           # the head carries no build check at all
RUN_REASON="every run for the head finished and was judged" # what the run list settled on
MERGE_STATE="merged=true state=MERGED" # what REST says after the merge call
MERGE_QUEUE=""                         # nonempty = the base has a merge queue
PR_BODY="A body with nothing to close."  # what the body read answers with
BODY_FAIL=""                           # nonempty = the body read answers with a 404

# The three library functions this suite replaces, declared so the shadow guard lets them through:
# the build signal is not under test here. gate_checks calls them inside command substitutions;
# they print, they do not set variables.
stub build_checks run_signal warn_base_drift
build_checks() {
  if [ -n "$NO_CHECKS" ]; then
    : # a head with no build check at all: the run list alone decides
  elif [ -n "$SKIPS_ONLY" ]; then
    printf 'green\tci\tskipped\thttps://example/run\ngreen\tdocs\tneutral\thttps://example/run2\n'
  else
    printf 'green\tci\tsuccess\thttps://example/run\n'
  fi
  return 0
}
run_signal() { printf '0\t%s\n' "$RUN_REASON"; return 0; }
warn_base_drift() { return 0; }

gh() {
  case "${1:-} ${2:-}" in
  "api repos/$REPO/pulls/7")
    case "$*" in
    # The gate reads the PR twice per round with DIFFERENT projections: `updated_at` rides on the
    # first, which binds the head, and the revalidation at the end of the round asks for the head,
    # the base and the head ref alone. The revalidation is the one that can answer with a
    # successor, so the two are told apart by `updated_at` rather than by field count.
    *'.updated_at'*) printf 'head-sha\t2026-09-01T00:00:00Z\tbase-sha\tclaude/topic\n' ;;
    *'.head.sha'*) printf '%s\tbase-sha\tclaude/topic\n' "$CURRENT_HEAD" ;;
    *'.base.ref'*) echo main ;;
    *'.body'*)
      if [ -n "$BODY_FAIL" ]; then
        printf 'gh: Not Found (HTTP 404)\n' >&2
        return 1
      fi
      printf '%s\n' "$PR_BODY"
      ;;
    *merged=*) echo "$MERGE_STATE" ;;
    *) bail "unexpected pulls read: $*" ;;
    esac
    ;;
  "api graphql")
    case "$*" in
    *mergeQueue*) printf 'CALL %s\n' "$*" >>"$CALLS_FILE"; echo "$MERGE_QUEUE" ;;
    *) bail "unexpected graphql call: $*" ;;
    esac
    ;;
  "pr merge") printf 'CALL %s\n' "$*" >>"$CALLS_FILE" ;;
  *) bail "unexpected fixture gh call: $*" ;;
  esac
}

# In a subshell: cmd_merge's refusals are `fail`, which exits the shell it runs in. The calls
# and output travel through files, so the subshell costs nothing the assertions need.
# The two streams are kept APART as well as together: the closing-keyword warning is required to
# reach BOTH, and a single merged capture cannot tell a line that went to one from a line that went
# to the other. MERGE_OUTPUT stays the pair, which is what every older case asserts against.
run_merge() {
  local rc
  : >"$CALLS_FILE"
  set +e
  (cmd_merge "$REPO#7" "$@") >"$OUT_FILE" 2>"$ERR_FILE"
  rc=$?
  set -e
  MERGE_STDOUT=$(cat "$OUT_FILE")
  MERGE_STDERR=$(cat "$ERR_FILE")
  MERGE_OUTPUT=$(cat "$OUT_FILE" "$ERR_FILE")
  MERGE_RC="$rc"
  MERGE_CALLS=$(cat "$CALLS_FILE")
}

assert_no_merge_call() {
  case "$MERGE_CALLS" in *"pr merge"*) bail "no merge call should have been made ($MERGE_CALLS)" ;; esac
}

reset() {
  CURRENT_HEAD=head-sha
  SKIPS_ONLY=""
  NO_CHECKS=""
  RUN_REASON="every run for the head finished and was judged"
  MERGE_STATE="merged=true state=MERGED"
  MERGE_QUEUE=""
  PR_BODY="A body with nothing to close."
  BODY_FAIL=""
}

# The merge is bound to the head the gate read: a push during a long --wait must not land a head
# with neither a read green nor a 👍.
test_merge_binds_to_the_gated_head() {
  reset
  run_merge
  assert_eq "$MERGE_RC" 0 "a green head merges ($MERGE_OUTPUT)"
  assert_contains "$MERGE_CALLS" "--match-head-commit head-sha " "merge is bound to the gated head"
  assert_contains "$MERGE_CALLS" " --merge" "the repo convention stays"
}

test_forwarded_head_binding_is_refused() {
  reset
  run_merge -- --match-head-commit other --merge
  assert_eq "$MERGE_RC" 2 "a forwarded --match-head-commit is a usage error"
  assert_contains "$MERGE_OUTPUT" "cannot be forwarded" "should say the flag is the script's"
  assert_no_merge_call
  run_merge -- --match-head-commit=other --merge
  assert_eq "$MERGE_RC" 2 "the = form is refused too"
}

# Skipped and neutral are green for the ordinary gate; a close-out merge needs a build that RAN.
test_require_green_refuses_green_by_skips_only() {
  reset
  SKIPS_ONLY=1
  run_merge
  assert_eq "$MERGE_RC" 0 "the ordinary gate lets skips-only through"
  run_merge --require-green
  assert_eq "$MERGE_RC" 4 "--require-green refuses skips-only"
  assert_contains "$MERGE_OUTPUT" "skipped or neutral — green, but no build RAN" "should say why"
  assert_no_merge_call
}

test_require_green_refuses_auto() {
  reset
  run_merge --require-green -- --auto --merge
  assert_eq "$MERGE_RC" 2 "--auto with --require-green is a usage error"
  assert_contains "$MERGE_OUTPUT" "cannot be combined with --auto" "should name the conflict"
  assert_no_merge_call
}

# On a base that defers merges, gh returns 0 having only ENABLED auto-merge; a close-out merge
# takes that back rather than leaving a later head armed to land ungated.
test_require_green_disables_a_deferred_auto_merge() {
  reset
  MERGE_STATE="merged=false state=OPEN"
  run_merge
  assert_eq "$MERGE_RC" 1 "an ordinary deferred merge is exit 1"
  case "$MERGE_CALLS" in *--disable-auto*) bail "the ordinary path must not disable auto-merge" ;; esac
  run_merge --require-green
  assert_eq "$MERGE_RC" 1 "a deferred close-out merge is exit 1"
  assert_contains "$MERGE_CALLS" "--disable-auto" "auto-merge should be disabled again"
  assert_contains "$MERGE_OUTPUT" "auto-merge DISABLED again" "should say it took it back"
}

# A merge queue makes `gh pr merge` an enqueue, which --disable-auto cannot undo: a close-out
# merge refuses before calling merge, and reads the queue again right before the call. The
# ordinary gate never asks.
test_require_green_refuses_a_merge_queue() {
  reset
  MERGE_QUEUE=MQ_1
  run_merge
  assert_eq "$MERGE_RC" 0 "the ordinary gate merges on a queued base as before"
  case "$MERGE_CALLS" in *mergeQueue*) bail "the ordinary path must not read the queue" ;; esac
  run_merge --require-green
  assert_eq "$MERGE_RC" 1 "--require-green refuses a base with a merge queue"
  assert_contains "$MERGE_OUTPUT" "has a merge queue" "should say why"
  assert_contains "$MERGE_CALLS" "mergeQueue(branch:" "should have read the queue"
  assert_no_merge_call
  MERGE_QUEUE=""
  run_merge --require-green
  assert_eq "$MERGE_RC" 0 "no queue: --require-green merges ($MERGE_OUTPUT)"
  assert_eq "$(grep -c 'mergeQueue(branch:' "$CALLS_FILE")" 2 "the queue is read before and after the gate"
  local calls
  calls=$(grep -n 'mergeQueue\|pr merge' "$CALLS_FILE" | cut -d: -f2- | cut -c1-14 | tr '\n' ',')
  assert_eq "$calls" "CALL api graph,CALL api graph,CALL pr merge ," "both reads precede the merge call"
}

# A docs-only PR head gets no workflow run at all, and since ludics-lite#176 the gate reads that
# off the workflows' own paths-ignore instead of waiting the absence grace out first: what reaches
# `merge` is an ABSENT verdict carrying that reason, minutes earlier than it used to. The
# recognition itself is test-pr-review-checks-absent.sh's subject, as every build-signal behaviour
# is here; what this pins is what `merge` does with it. The ordinary gate lands the gated head
# (nothing is red, and nothing is coming), and a close-out merge still refuses — a record-based
# merge is required to have READ a green, and a head nothing builds has none to read.
test_a_paths_ignored_head_merges_on_the_recognized_absence() {
  reset
  NO_CHECKS=1
  RUN_REASON="no workflow run exists for this head, and none can be created: every commit from the merge base up to it changes only paths within the paths-ignore of ci, under every trigger this push or this pull request fires"
  run_merge
  assert_eq "$MERGE_RC" 0 "the ordinary gate merges a head nothing can build ($MERGE_OUTPUT)"
  assert_contains "$MERGE_OUTPUT" ": ABSENT" "the verdict is the absence, not a green"
  assert_contains "$MERGE_OUTPUT" "none can be created" "carrying the reason the recognition gave"
  assert_contains "$MERGE_CALLS" "--match-head-commit head-sha " "still bound to the gated head"
  run_merge --require-green
  assert_eq "$MERGE_RC" 4 "a close-out merge needs a green it READ, which this head has none of"
  assert_contains "$MERGE_OUTPUT" "the build signal is absent" "the refusal names the verdict"
  assert_contains "$MERGE_OUTPUT" "path filters" "and points at the dispatch that would get one"
  assert_no_merge_call
}

test_superseded_head_never_merges() {
  reset
  CURRENT_HEAD=successor-sha
  run_merge --wait=30 --allow-no-verdict --override 'unrelated red on base'
  assert_eq "$MERGE_RC" 5 "superseded refuses even both verdict overrides"
  assert_contains "$MERGE_OUTPUT" "SUPERSEDED" "refusal names the transition"
  assert_no_merge_call
}

# ludics-lite#227. A closing keyword binds to every `#N` in its sentence, so one sentence naming two
# issues closes both -- which is how ludics-lite#205 was closed by a phase reference in #210. The
# scan says so before the merge lands, on both streams, naming the sentence and every issue.
test_one_sentence_closing_two_issues_warns() {
  reset
  PR_BODY='## What

The scanner lands. Closes #401 and #402
'
  run_merge
  assert_eq "$MERGE_RC" 0 "the warning is not a gate: the merge still lands ($MERGE_OUTPUT)"
  assert_contains "$MERGE_CALLS" "pr merge" "the merge call is still made"
  assert_contains "$MERGE_STDOUT" "CLOSING-KEYWORD WARNING" "warns on stdout"
  assert_contains "$MERGE_STDERR" "CLOSING-KEYWORD WARNING" "and on stderr"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #401 #402" "names every issue it closes"
  assert_contains "$MERGE_STDOUT" "Closes #401 and #402" "names the sentence"
  # The sentence, not the line: the half before the full stop carries no keyword of its own.
  assert_not_contains "$MERGE_STDOUT" "The scanner lands." "the unit is the sentence, not the line"
}

# The other half of #227, and the shape that closed #205 a SECOND time: a keyword inside a `> `
# quote or a fenced block closes exactly as a statement does, so there ONE reference is already one
# nobody meant to close. The single plain `Closes` line in the same body stays out of the report.
test_a_closing_keyword_in_a_quoted_or_fenced_line_warns() {
  reset
  PR_BODY='Review record: the reviewer asked about the shape

> Closes #205

and about the one the skill prescribes:

```
Fixes #206
```

Closes #403
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_CALLS" "pr merge" "the merge call is still made"
  assert_contains "$MERGE_STDOUT" "QUOTED or FENCED line, which closes just the same -- 1: #205" \
    "a quoted keyword is reported at ONE reference"
  assert_contains "$MERGE_STDOUT" "QUOTED or FENCED line, which closes just the same -- 1: #206" \
    "a fenced one too"
  assert_contains "$MERGE_STDERR" "#205" "the quoted finding reaches stderr as well"
  assert_not_contains "$MERGE_STDOUT" "403" "the plain single-issue Closes line is not reported"
}

# The control, and the one that decides the unit: the shape ship-pr/SKILL.md *Open* PRESCRIBES --
# one `Closes #N` per line -- is silent. Markdown joins those two lines into one paragraph, so a
# paragraph-sized unit would make the prescribed shape the loudest warning in the file.
test_the_prescribed_shape_stays_silent() {
  reset
  PR_BODY='Two issues, one PR, and a third this only partially addresses.

Closes #404
Closes #405

Refs #406 and #407. A close-out merge of #408 and #409 names neither as done.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "the control merges ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "two Closes lines, a keyword-free reference and a hyphenated close-out are all silent"
}

# A body that could not be READ is not a body with nothing in it. Without this line the scan's
# silence is indistinguishable from a clean body -- the false negative this file refuses everywhere
# else (an unread approval is never "no approval yet").
test_an_unread_body_is_not_a_clean_body() {
  reset
  BODY_FAIL=1
  run_merge
  assert_eq "$MERGE_RC" 0 "an unreadable body does not block the merge"
  assert_contains "$MERGE_CALLS" "pr merge" "the merge call is still made"
  assert_contains "$MERGE_STDERR" "the closing-keyword scan did NOT run" \
    "the silence is announced as unread, not as clean"
}

tests=(
  test_superseded_head_never_merges
  test_merge_binds_to_the_gated_head
  test_forwarded_head_binding_is_refused
  test_require_green_refuses_green_by_skips_only
  test_require_green_refuses_auto
  test_require_green_disables_a_deferred_auto_merge
  test_require_green_refuses_a_merge_queue
  test_a_paths_ignored_head_merges_on_the_recognized_absence
  test_one_sentence_closing_two_issues_warns
  test_a_closing_keyword_in_a_quoted_or_fenced_line_warns
  test_the_prescribed_shape_stays_silent
  test_an_unread_body_is_not_a_clean_body
)

run_tests "${tests[@]}"
exit "$?"
}
