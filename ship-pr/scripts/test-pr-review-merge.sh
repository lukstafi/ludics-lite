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
MERGE_NOT_MERGEABLE=""                 # nonempty = the FIRST pr merge call fails as not mergeable
PR_BASE=main                           # the branch this PR targets
BASE_LATER=""                          # nonempty = the base read answers with this from the 2nd on
DEFAULT_BRANCH=main                    # the repository default branch
DEFAULT_BRANCH_FAIL=""                 # nonempty = the default-branch read answers with a 404
DEFAULT_BRANCH_FAIL_LATER=""           # nonempty = it answers with a 404 from the SECOND read on
PR_BODY="A body with nothing to close."  # what the body read answers with
PR_BODY_LATER=""                       # nonempty = what the SECOND body read on answers with
BODY_FAIL=""                           # nonempty = the body read answers with a 404
# The read counter travels in a FILE: gh_retry calls the fixture inside a command substitution,
# so a variable it increments dies with that subshell -- as CALLS_FILE already exists for.
READS_FILE="$TEST_ROOT/body-reads"
BASE_READS_FILE="$TEST_ROOT/base-reads"
DEF_READS_FILE="$TEST_ROOT/def-reads"

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
    *'.base.ref'*)
      printf 'base\n' >>"$BASE_READS_FILE"
      if [ -n "$BASE_LATER" ] && [ "$(wc -l <"$BASE_READS_FILE" | tr -d ' ')" -ge 2 ]; then
        printf '%s\n' "$BASE_LATER"
      else
        printf '%s\n' "$PR_BASE"
      fi
      ;;
    *'.body'*)
      printf 'read\n' >>"$READS_FILE"
      if [ -n "$BODY_FAIL" ]; then
        printf 'gh: Not Found (HTTP 404)\n' >&2
        return 1
      fi
      if [ -n "$PR_BODY_LATER" ] && [ "$(wc -l <"$READS_FILE" | tr -d ' ')" -ge 2 ]; then
        printf '%s\n' "$PR_BODY_LATER"
      else
        printf '%s\n' "$PR_BODY"
      fi
      ;;
    *merged=*) echo "$MERGE_STATE" ;;
    *'.mergeable'*) echo true ;;
    *) bail "unexpected pulls read: $*" ;;
    esac
    ;;
  "api repos/$REPO")
    printf 'def\n' >>"$DEF_READS_FILE"
    if [ -n "$DEFAULT_BRANCH_FAIL_LATER" ] && [ "$(wc -l <"$DEF_READS_FILE" | tr -d ' ')" -ge 2 ]; then
      printf 'gh: Not Found (HTTP 404)\n' >&2
      return 1
    fi
    if [ -n "$DEFAULT_BRANCH_FAIL" ]; then
      printf 'gh: Not Found (HTTP 404)\n' >&2
      return 1
    fi
    printf '%s\n' "$DEFAULT_BRANCH"
    ;;
  "api graphql")
    case "$*" in
    *mergeQueue*) printf 'CALL %s\n' "$*" >>"$CALLS_FILE"; echo "$MERGE_QUEUE" ;;
    *) bail "unexpected graphql call: $*" ;;
    esac
    ;;
  "pr merge")
    printf 'CALL %s\n' "$*" >>"$CALLS_FILE"
    # The stale pre-recompute verdict: the first attempt fails as not mergeable, await_mergeable
    # then reads mergeable=true and cmd_merge retries. One failure only, so the retry lands.
    if [ -n "$MERGE_NOT_MERGEABLE" ] && [ ! -f "$TEST_ROOT/merge-failed-once" ]; then
      : >"$TEST_ROOT/merge-failed-once"
      printf 'gh: Pull request is not mergeable\n' >&2
      return 1
    fi
    ;;
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
  : >"$READS_FILE"
  : >"$BASE_READS_FILE"
  : >"$DEF_READS_FILE"
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
  MERGE_NOT_MERGEABLE=""
  PR_BASE=main
  BASE_LATER=""
  DEFAULT_BRANCH=main
  DEFAULT_BRANCH_FAIL=""
  DEFAULT_BRANCH_FAIL_LATER=""
  rm -f "$TEST_ROOT/merge-failed-once"
  PR_BODY="A body with nothing to close."
  PR_BODY_LATER=""
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
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #205" \
    "a quoted keyword is reported at ONE reference"
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #206" \
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

# Review round 1, P2. A fence closes only on its own delimiter at its own length: a four-backtick
# fence exists so it can CONTAIN a three-backtick one, and an unconditional toggle reads the inner
# fence as the close -- after which the keyword inside the example reads as ordinary prose and the
# scan, whose whole subject is that example, says nothing.
test_a_longer_fence_is_not_closed_by_an_inner_one() {
  reset
  PR_BODY='How a body should NOT be written:

````markdown
```
Closes #410
```
````

Closes #411
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #410" \
    "the inner fence must not close the four-backtick one"
  assert_not_contains "$MERGE_STDOUT" "411" "the plain line after the real fence close is silent"
}

# Review rounds 1, 4 and 5 on one rule, and its removal. An abbreviation guard stood here for three
# rounds and was narrowed twice; both of its errors were FALSE POSITIVES, naming a reference that
# belonged to the next sentence and offering to reopen a live issue. Terminal punctuation now ends a
# unit outright: the cost is a missed warning when an abbreviation sits between two references, which
# is the fourth documented limitation, and the gain is that a sentence ending in a version number or
# a section letter can no longer produce wrong reopen advice.
test_a_period_ends_the_unit_with_no_abbreviation_guard() {
  reset
  # The two false positives the guard used to cause: both silent now.
  PR_BODY='Closes #616 in version 2. See #617 for follow-up.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" "a version number ends the sentence"
  PR_BODY='Closes #618 in appendix A. See #619 for context.
'
  run_merge
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" "a section letter ends it too"
  # The documented cost, asserted rather than merely described: this one IS missed.
  PR_BODY='Closes #621 and, e.g. #622
'
  run_merge
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "an abbreviation between two references is the fourth documented limitation"
  # And the rule the whole scan exists for is untouched.
  PR_BODY='Closes #623 and #624
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #623 #624" "the ordinary shape still warns"
}

# Review round 1, P2. A reference is reported as the body spells it, and `owner/tracker#123` names
# an issue this repository does not have: a remediation hardcoding the PR's own repo would reopen a
# same-numbered issue here, or fail.
test_the_reopen_remedy_does_not_hardcode_this_repo() {
  reset
  PR_BODY='Closes other/tracker#416 and other/tracker#417
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "other/tracker#416 other/tracker#417" \
    "the cross-repository form is reported whole"
  assert_contains "$MERGE_STDOUT" "in the repository its own reference names" \
    "the remedy sends the reader to the reference's own repository"
  assert_not_contains "$MERGE_STDOUT" "gh issue reopen <n> --repo $REPO" \
    "and never hardcodes this PR's repository"
}

# Review round 1, P2. A PR body stays editable through a --wait that can run two hours, and editing
# it does not move the head, so --match-head-commit cannot see it. The scan that matters is the one
# taken last; the early one is lead time.
test_the_body_is_scanned_again_before_the_merge() {
  reset
  PR_BODY='Nothing to see here.
'
  PR_BODY_LATER='Closes #418 and #419
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "was EDITED since the scan above" "the re-scan says what moved"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #418 #419" \
    "and reports the body that actually lands"
}

# The other side of the re-scan: an unchanged body is not the whole block printed twice.
test_an_unchanged_body_is_not_reported_twice() {
  reset
  PR_BODY='Closes #420 and #421
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_eq "$(grep -c 'ONE sentence, 2 issues: #420 #421' "$OUT_FILE")" 1 \
    "the findings block is printed once, by the scan that had lead time"
  assert_contains "$MERGE_STDOUT" "is UNCHANGED since the scan above" \
    "and the re-scan confirms the body that lands is that one"
  # And an edit that REMOVES the sentence retracts the warning rather than leaving it standing.
  reset
  PR_BODY='Closes #422 and #423
'
  PR_BODY_LATER='Closes #422
'
  run_merge
  assert_contains "$MERGE_STDOUT" "WARNING WITHDRAWN" "a fixed body retracts the earlier finding"
}

# Review round 2, P2. A repository NAME may lead with punctuation -- `github/.github` is real --
# while an owner, like a GitHub login, may not. Requiring an alphanumeric on both sides made a body
# naming two such references produce no warning at all.
test_a_repository_name_may_lead_with_punctuation() {
  reset
  PR_BODY='Closes github/.github#424 and github/.github#425
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: github/.github#424 github/.github#425" \
    "a dot-leading repository name is still a reference"
}

# Review round 2, P2. A CLOSING fence carries no info string: only spaces or tabs may follow its
# run. A content line that merely starts with the delimiter was ending the block, after which the
# rest of the example read as ordinary prose.
test_a_closing_fence_takes_no_info_string() {
  reset
  PR_BODY='An example of what not to write:

````markdown
````not-a-close
Closes #426
````

Closes #427
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #426" \
    "a delimiter with a suffix does not close the block"
  assert_not_contains "$MERGE_STDOUT" "427" "the line after the real close is outside the block"
}

# Review round 3, P2. A blockquote nested in a list item is still a blockquote, and the `>` test
# ran against a line the list marker still led -- so the quoted rule, which fires at ONE reference,
# never saw it and the ordinary rule ignores a single reference by design.
test_a_quote_nested_in_a_list_item_is_still_quoted() {
  reset
  PR_BODY='The shapes to avoid:

- > Closes #601
  1. > Fixes #602

Closes #603
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #601" \
    "a quote behind a list marker is quoted"
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #602" \
    "and behind an ordered one too"
  assert_not_contains "$MERGE_STDOUT" "603" "the plain line is still silent"
}

# Review round 3, P2. A closing quote sits between the full stop and the space often enough to
# matter: without it the two sentences stayed one unit and the warning named an issue belonging to
# the next one -- a false positive that would have sent the operator to reopen a live issue.
test_a_closing_quote_still_ends_the_sentence() {
  reset
  PR_BODY='The example says "Closes #604." See #605 for follow-up.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "the quoted full stop ends the sentence, so #605 is not bound"
}

# Review round 3, P2. A body here is full of run links. A fragment in one is not an issue, and a
# host with a path was even being reported as a cross-repository reference.
test_a_url_fragment_is_not_an_issue_reference() {
  reset
  PR_BODY='Closes #606; see https://example.com/docs/#607 and https://example.com/page#608 for details.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "one real reference and two URL fragments is one reference"
}

# Review round 3, P2. One issue named twice is one issue: counting occurrences made the count, the
# list and the reopen advice all false.
test_the_same_issue_named_twice_is_one_issue() {
  reset
  PR_BODY='The request in #609 is complete, so this closes #609.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "a repeated reference is not a second issue"
  # Two distinct ones in the same shape still warn, so the dedupe did not disarm the rule.
  # #610 stands BEFORE the keyword, so only #611 is bound -- see the forward-binding case below.
  PR_BODY='This closes #610 and #611.
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #610 #611" "two distinct ones still warn"
}

# Review round 4, P2. Four leading spaces make an indented CODE block, which SKILL.md names as a
# shape this scanner does not read. Stripping all leading whitespace made one a blockquote, so the
# scan warned about the very example the documentation says it ignores -- and an indented fence
# opened a phantom block that swallowed the ordinary text after it.
test_four_space_indentation_is_not_a_quote_or_a_fence() {
  reset
  PR_BODY='An indented example, which is code and is not read:

    > Closes #612
    ```
    Closes #613
    ```

Closes #614 and #615
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_STDOUT" "612" "an indented quote is code, not a blockquote"
  assert_not_contains "$MERGE_STDOUT" "613" "and the indented fence opens nothing"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #614 #615" \
    "the ordinary line after it is still read, so no phantom fence swallowed it"
}

# Review round 4, P2. GitHub numbers start at 1, so `#0` is prose -- and reopen advice for it would
# point at an issue that does not exist.
test_hash_zero_is_not_an_issue_reference() {
  reset
  PR_BODY='Closes #620; step #0 initializes the state.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" "#0 is not a second issue"
  # A number that merely starts with a zero digit later is untouched.
  PR_BODY='Closes #620 and #1024
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #620 #1024" "ordinary numbers still count"
}

# Review round 5, P2. A schemeless link produced a bogus cross-repository reference out of a host
# label and a path. Enumerating URL spellings was the wrong shape of fix; the boundary closes the
# genre instead -- a reference preceded by a dot or a slash is a path or a host, whatever scheme it
# carries or does not carry.
test_a_schemeless_link_is_not_an_issue_reference() {
  reset
  PR_BODY='Closes #625; see www.example.com/page#626 and https://example.com/docs/#627 for details.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "one real reference and two links is one reference"
}

# Review round 5, P2. The bare and the fully qualified spelling of an issue in THIS repository name
# one issue, and the repository is knowable here because the caller passes it in.
test_the_local_qualified_spelling_is_the_same_issue() {
  reset
  PR_BODY='Closes #628 (example/repo#628).
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "a bare and a locally qualified reference are one issue"
  # A reference to another repository is a different issue, and still counts.
  PR_BODY='Closes #629 (other/tracker#629).
'
  run_merge
  assert_contains "$MERGE_STDOUT" "2 issues: #629 other/tracker#629" \
    "another repository is another issue"
}

# Review round 5, P2. await_mergeable can hold for tens of seconds before the loop retries the
# merge, and a body edited in that window moves no head. The authoritative scan therefore runs
# before EVERY attempt, not once before the loop.
test_the_body_is_rescanned_before_a_retried_merge() {
  reset
  MERGE_NOT_MERGEABLE=1
  PR_BODY='Nothing to see here.
'
  PR_BODY_LATER='Closes #630 and #631
'
  run_merge
  assert_eq "$MERGE_RC" 0 "the retry still merges ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #630 #631" \
    "the body added during the mergeability wait is reported"
}

# Review round 6, P2. A body keyword binds only on a merge into the repository DEFAULT branch. On a
# PR targeting a release or staging branch it closes nothing, so warning there would name issues
# this merge leaves open and offer to reopen issues that were never closed -- the one thing this
# scan may never do.
test_no_warning_when_the_base_is_not_the_default_branch() {
  reset
  PR_BODY='Closes #632 and #633
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #632 #633" "on the default branch it warns"
  reset
  PR_BODY='Closes #632 and #633
'
  PR_BASE=release-1.2
  run_merge
  assert_eq "$MERGE_RC" 0 "the merge still lands ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "a keyword is inert on a merge into a non-default branch"
}

# ... and an unread comparison is not an inert one: the findings still print, with the doubt named.
test_an_unread_default_branch_is_not_an_inert_keyword() {
  reset
  PR_BODY='Closes #634 and #635
'
  DEFAULT_BRANCH_FAIL=1
  run_merge
  assert_eq "$MERGE_RC" 0 "the merge still lands ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #634 #635" "the findings still print"
  assert_contains "$MERGE_STDOUT" "could NOT be read" "with the doubt on the line"
}

# Review round 6, P2. An owner or a repository may be NAMED `closed`, and the keyword boundary
# accepted the `/` that follows it -- so a sentence carrying no closing directive at all produced a
# two-issue warning with reopen guidance.
test_a_repository_named_like_a_keyword_is_not_a_keyword() {
  reset
  PR_BODY='See closed/tracker#636 and closed/tracker#637 for context.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "a keyword that is a path component is not a directive"
}

# Review round 6, P2. Owner and repository names are case-insensitive on GitHub, so two spellings
# of one reference are one issue.
test_reference_case_does_not_make_a_second_issue() {
  reset
  PR_BODY='Closes Other/Tracker#638 and other/tracker#638
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "two spellings of one reference are one issue"
}

# Review round 6, P2. Indentation is COLUMNS: a tab advances to the next stop, so one to three
# spaces before one still reach column four, which is code and not a blockquote.
test_a_tab_after_spaces_is_still_code_indentation() {
  reset
  PR_BODY=$(printf 'An indented example:\n\n  \t> Closes #639\n\nCloses #640 and #641\n')
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_STDOUT" "639" "two spaces then a tab is column four, so code"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #640 #641" "the ordinary line still reads"
}

# Review round 6, P2. A backtick opener carries no backtick in its info string; such a line opens
# nothing, and treating it as an opener left the rest of the body in a phantom fenced block.
test_an_invalid_backtick_opener_opens_no_fence() {
  reset
  PR_BODY='An invalid opener:

```bad`info

Closes #642
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "the plain line after an invalid opener is not fenced"
  # A valid opener still opens one.
  PR_BODY='A valid opener:

```markdown
Closes #643
```
'
  run_merge
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #643" \
    "a valid info string still opens a fence"
}

# Review round 7, P2. A PR can be RETARGETED during a wait that runs two hours, so the base/default
# comparison is read every time rather than cached -- the same reason cmd_merge reads the merge
# queue twice. A cached answer would skip the scan on a PR moved ONTO the default branch.
test_a_retarget_during_the_gate_is_seen() {
  reset
  PR_BODY='Closes #644 and #645
'
  PR_BASE=release-1.2
  # The early scan sees a non-default base and says nothing; the fixture then reports the default
  # base from the second read on, which is what a retarget during the wait looks like.
  BASE_LATER=main
  run_merge
  assert_eq "$MERGE_RC" 0 "the merge still lands ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #644 #645" \
    "the authoritative scan re-reads the base and finds the keyword now binds"
}

# Review round 7, P2. The unknown state must carry the reason that caused it: the successful body
# read that follows clears the shared error file, so reading it back printed an empty cause.
test_an_unknown_comparison_names_its_cause() {
  reset
  PR_BODY='Closes #646 and #647
'
  DEFAULT_BRANCH_FAIL=1
  run_merge
  assert_contains "$MERGE_STDOUT" "the default branch could not be read: gh: Not Found (HTTP 404)" \
    "the cause of the uncertainty survives the body read"
}

# Review round 7, P2. A Markdown link destination sits between the terminator and the space, so the
# two sentences stayed one unit and the scan named a reference from the next one.
test_a_link_destination_does_not_join_two_sentences() {
  reset
  PR_BODY='[Closes #648.](https://example.test/x) See #649 for context.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "the link destination does not hold two sentences together"
  # A version number must still NOT split, which is what the alphanumeric guard is for.
  PR_BODY='Closes #650 and #651 in release 3.5 of the tool
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #650 #651" "a decimal is not a boundary"
}

# Review round 7, P2. "Unchanged" was decided on the FINDINGS, so a body that gained an ordinary
# single-reference `Closes` line compared equal -- and the re-scan confirmed the merge closed what
# it had listed while it was about to close one more.
test_an_added_plain_closes_line_is_not_an_unchanged_body() {
  reset
  PR_BODY='Closes #652 and #653
'
  PR_BODY_LATER='Closes #652 and #653

Closes #654
'
  run_merge
  assert_eq "$MERGE_RC" 0 "the merge still lands ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_STDOUT" "is UNCHANGED since the scan above" \
    "a body that gained a closing line is not unchanged"
  assert_contains "$MERGE_STDOUT" "was EDITED since the scan above" "the re-scan says the body moved"
}

# Review round 7, P2. A query string puts `=` or `&` in front of a hash, which two rounds of
# blacklisting the preceding character did not cover. The boundary is a whitelist now.
test_a_query_string_hash_is_not_an_issue_reference() {
  reset
  PR_BODY='Closes #655; see www.example.com/?issue=#656 for details.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" "a query-string hash is not a reference"
  # The shapes a human actually writes still count, including a reference in inline code or
  # brackets -- the whitelist has to admit those or the scan goes quiet on ordinary bodies.
  PR_BODY='Closes (#657) and `#658`
'
  run_merge
  assert_contains "$MERGE_STDOUT" "2 issues: #657 #658" "brackets and inline code still open a reference"
}

# Review round 8, P2. The mirror of the retarget case: when the lead-time scan warned and the PR is
# then moved OFF the default branch, returning silently leaves that warning standing in the
# transcript still saying issues are about to close.
test_a_retarget_off_the_default_branch_withdraws_the_warning() {
  reset
  PR_BODY='Closes #659 and #660
'
  PR_BASE=main
  BASE_LATER=release-1.2
  run_merge
  assert_eq "$MERGE_RC" 0 "the merge still lands ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #659 #660" "the lead-time scan warned"
  assert_contains "$MERGE_STDOUT" "no longer targets the default branch" \
    "and the authoritative scan retracts it"
}

# Review round 8, P2. A Markdown destination may be followed by a quoted title inside the same
# parentheses, so the group has to run to its closing paren and not to the next space.
test_a_titled_link_does_not_join_two_sentences() {
  reset
  PR_BODY='[Closes #661.](https://example.test/x "the title") See #662 for context.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "a titled link does not hold two sentences together"
}

# Review round 8, P2. A URL can CONTAIN the characters a human writes a reference after, so the
# boundary whitelist alone was not enough: schemeless hosts are stripped as well.
test_a_schemeless_url_containing_a_delimiter_is_stripped() {
  reset
  PR_BODY='Closes #663; see www.example.com/?issues=foo,#664 for details.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "a comma inside a URL does not open a reference"
}

# Review round 8, P2. An EXCLUDING character class is ASCII-shaped, so the first byte of a non-ASCII
# letter read as punctuation and a French past participle matched as a closing keyword.
test_a_non_ascii_word_is_not_a_keyword() {
  reset
  PR_BODY='Ceci fixes #665 et #666.
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #665 #666" \
    "the ASCII spelling really is a keyword, so the case has something to distinguish"
  reset
  PR_BODY=$(printf 'Ceci fix\303\251s #665 et #666.\n')
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "a keyword followed by a non-ASCII letter is part of another word"
}

# Review round 9, P2. The fourth Markdown link form to reach the sentence boundary in four rounds,
# and the one that ended the enumeration: the boundary no longer lists closers at all.
test_a_reference_style_link_does_not_join_two_sentences() {
  reset
  PR_BODY='[Closes #667.][details] See #668 for context.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "a reference-style link suffix does not hold two sentences together"
  # The three earlier forms, and the decimal that must still not split, all in one body.
  PR_BODY='[Closes #669.](https://example.test/x "t") See #670. "Closes #671." See #672.
'
  run_merge
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" "the earlier link forms still split"
  PR_BODY='Closes #673 and #674 in release 3.5 of the tool
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #673 #674" "a decimal is still not a boundary"
}

# Review round 9, P2. A boundary is owed on both sides of a reference: the numeric run stopped
# where the digits did, so a CSS colour was read as an issue and carried reopen advice for it.
test_a_reference_needs_a_boundary_after_its_digits() {
  reset
  PR_BODY='Closes #675 after changing #123abc.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" "a hex colour is not an issue"
  # A reference followed by ordinary punctuation, or ending the line, still counts.
  PR_BODY='Closes #676, #677.
'
  run_merge
  assert_contains "$MERGE_STDOUT" "2 issues: #676 #677" "punctuation and end of line are boundaries"
}

# Review round 10, P2. A query may follow a bare host with no path at all, so the schemeless-URL
# suffix has to start at a slash, a question mark or a hash.
test_a_query_only_schemeless_url_is_stripped() {
  reset
  PR_BODY='Closes #678; see www.example.com?issues=foo,#679 for details.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" \
    "a query with no path is still part of the URL"
}

# Review round 10, P2. Markdown allows at most nine digits in an ordered marker, so a longer run is
# ordinary text -- and peeling it made a line a list item it is not, after which a `>` behind it
# read as a blockquote.
test_an_over_long_numeric_prefix_is_not_a_list_marker() {
  reset
  PR_BODY='1234567890. > Closes #680
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD" \
    "a ten-digit prefix is text, not an ordered marker"
  # A marker of a length Markdown does accept still peels, so the round-3 fix survives.
  PR_BODY='123456789. > Closes #681
'
  run_merge
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #681" \
    "a nine-digit marker is still a list marker"
}

# Review round 10, P2. The close-out queue refusal has to be the LAST thing before the merge call:
# the body scan makes three REST reads, and a queue enabled during them would turn the call into an
# enqueue that --require-green exists to refuse.
test_the_queue_is_read_after_the_body_scan() {
  reset
  PR_BODY='Closes #682 and #683
'
  run_merge --require-green
  assert_eq "$MERGE_RC" 0 "a close-out merge still lands ($MERGE_OUTPUT)"
  # The queue read is made twice as before, and the LAST one now follows the scan.
  assert_eq "$(grep -c 'mergeQueue(branch:' "$CALLS_FILE")" 2 "still two queue reads on the happy path"
  local order
  order=$(grep -n 'mergeQueue\|pr merge' "$CALLS_FILE" | cut -d: -f2- | cut -c1-14 | tr '\n' ',')
  assert_eq "$order" "CALL api graph,CALL api graph,CALL pr merge ," "both reads still precede the merge"
}

# Review round 11, P2. The documentation says an indented code block is a shape this scanner does
# not read; suppressing only the quote and fence tests still had an indented ordinary sentence
# warned about, which contradicted it in the one direction that matters.
test_an_indented_code_line_is_not_scanned_at_all() {
  reset
  PR_BODY='An indented example:

    Closes #684 and #685

Closes #686 and #687
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_STDOUT" "684" "an indented sentence is code, and code is not read"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #686 #687" "the ordinary line still is"
}

# Review round 11, P2. A list marker takes ONE space of padding; four columns beyond it open an
# indented code block inside the item, so stripping the whole run made code look like a blockquote.
test_a_list_marker_does_not_swallow_code_indentation() {
  reset
  PR_BODY='-     > Closes #688
- > Closes #689
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_STDOUT" "688" "four columns past the padding is code"
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #689" \
    "one space of padding is still a list item with a quote in it"
}

# Review round 11, P2. A port stands between a schemeless host and its suffix.
test_a_port_in_a_schemeless_url_is_stripped() {
  reset
  PR_BODY='Closes #690; see www.example.com:8080/?issues=foo,#691 for details.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD WARNING" "a port does not end the URL"
}

# Review round 11, P2. Only a warning that was PRINTED can be withdrawn: a clean body edited to
# another clean body was producing a loud retraction of nothing at all.
test_a_clean_body_edited_to_another_clean_body_is_silent() {
  reset
  PR_BODY='Nothing here.
'
  PR_BODY_LATER='Still nothing here.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "the merge still lands ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "WITHDRAWN" "nothing was warned, so nothing is withdrawn"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD" "and the merge is silent throughout"
}

# Review round 11, P2. An unchanged BODY is not an unchanged answer: if the comparison can no
# longer be read, the last word on a finding the caller has already read must say so.
test_an_unchanged_body_still_reports_a_lost_comparison() {
  reset
  PR_BODY='Closes #692 and #693
'
  DEFAULT_BRANCH_FAIL_LATER=1
  run_merge
  assert_eq "$MERGE_RC" 0 "the merge still lands ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "is UNCHANGED since the scan above" "the body did not move"
  assert_contains "$MERGE_STDOUT" "whether they bind could NOT be re-read" \
    "but whether the keywords bind is no longer known"
}

# Review rounds 12 and 16 on one rule. Round 12 let an open fence close at any indentation, to
# reach a delimiter indented as a list-item continuation; round 16 showed that errs in the UNSAFE
# direction, because closing early turns fenced lines into ordinary prose and promotes a notice
# into a warning that says issues close. Leaving the fence OPEN is the safe error: what it swallows
# becomes a notice, which claims nothing. The round-12 shape is the documented cost.
test_an_indented_delimiter_leaves_the_fence_open() {
  reset
  PR_BODY='- ```
      example
      ```

Closes #694 and #695
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "CLOSING-KEYWORD NOTICE" \
    "the fence stays open, so what follows is read as an example"
  assert_not_contains "$MERGE_STDOUT" "CLOSING-KEYWORD WARNING" \
    "and is never promoted to a claim that issues close"
}

# Review round 12, convergence. The two findings make different claims, and only one of them rests
# on the block classifier: a quoted or fenced line is flagged to be READ, and says nothing about
# what closes, so a misreading of the Markdown cannot produce a false statement about a merge.
test_a_quoted_finding_claims_nothing_about_closing() {
  reset
  PR_BODY='> Closes #695
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "CLOSING-KEYWORD NOTICE" "a quoted-only body is a notice"
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #695" \
    "and names the line"
  assert_contains "$MERGE_STDOUT" "may be ordinary prose" "and says the reading is best-effort"
  assert_not_contains "$MERGE_STDOUT" "EDIT THE BODY now" "no reopen remedy for a flagged line"
  assert_not_contains "$MERGE_STDOUT" "gh issue reopen" "and no reopen command"
  # A multi-reference sentence still makes the strong claim, because it consults no Markdown.
  reset
  PR_BODY='Closes #696 and #697
'
  run_merge
  assert_contains "$MERGE_STDOUT" "CLOSING-KEYWORD WARNING" "a sentence finding is still a warning"
  assert_contains "$MERGE_STDOUT" "EDIT THE BODY now" "and still carries the remedy"
}

# Review round 13, P2 and BLOCKING: this path undid the guarantee round 12 established. An
# unchanged quoted-only body reached the re-scan shortcut and was reported with a WARNING saying
# the merge closes what it listed -- the exact claim the quoted class was stripped of.
test_an_unchanged_quoted_only_body_keeps_notice_wording() {
  reset
  PR_BODY='> Closes #702
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "CLOSING-KEYWORD NOTICE" "the lead-time scan is a notice"
  assert_not_contains "$MERGE_STDOUT" "CLOSING-KEYWORD WARNING" \
    "and the re-scan of the unchanged body must not promote it to a warning"
  assert_not_contains "$MERGE_STDOUT" "closes what it listed" "nor claim what the merge closes"
  assert_contains "$MERGE_STDOUT" "the line flagged there is the line that lands" \
    "it says the body did not move, in the register it said the rest in"
  # A body that DOES carry a sentence finding still gets the strong register on the re-scan.
  reset
  PR_BODY='Closes #703 and #704
'
  run_merge
  assert_contains "$MERGE_STDOUT" "is UNCHANGED since the scan above, so the merge closes what it listed" \
    "a sentence finding keeps the strong wording"
}

# Review round 13, P2. An intraword underscore is not an emphasis boundary, so admitting `_` as a
# keyword boundary made an ordinary identifier a closing directive -- a strong warning with reopen
# guidance on a sentence carrying no directive at all.
test_an_identifier_containing_a_keyword_is_not_a_keyword() {
  reset
  PR_BODY='The auto_closes_items helper covers #705 and #706.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD" "an identifier is not a directive"
  # Asterisk emphasis around a real keyword still is one.
  PR_BODY='*Closes #707 and #708*
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #707 #708" "emphasis still bounds a keyword"
}

# Review round 13, P2. The sentence is contributor-controlled text on its way to a terminal, and
# this warning is the whole product of the scan: an ESC or a carriage return could erase or forge
# it. printf stops format-string expansion; it does not neutralize terminal control bytes.
test_control_bytes_in_the_body_cannot_forge_the_warning() {
  reset
  PR_BODY=$(printf 'Closes #709 and #710\033[2K\rFORGED LINE\n')
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #709 #710" "the finding still reports"
  case "$MERGE_OUTPUT" in
  *$'\033'*) bail "an escape byte reached the output" ;;
  *$'\r'*) bail "a carriage return reached the output" ;;
  esac
  assert_contains "$MERGE_STDOUT" "?[2K?FORGED LINE" "the control bytes are shown, not executed"
}

# Review round 14, P2 and BLOCKING. The third of three lines that speak about a finding the caller
# has already read, and the last one still announcing a quoted-only finding as a WARNING that says
# what the merge closes -- directly against the guarantee the quoted class was given.
test_an_edited_body_with_a_quoted_only_finding_keeps_notice_wording() {
  reset
  PR_BODY='Nothing here.
'
  PR_BODY_LATER='> Closes #711
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "CLOSING-KEYWORD NOTICE" "the edited-body banner is a notice"
  assert_not_contains "$MERGE_STDOUT" "CLOSING-KEYWORD WARNING" "and never a warning"
  assert_not_contains "$MERGE_STDOUT" "what this merge closes is below" "nor a claim about closing"
  assert_contains "$MERGE_STDOUT" "reads as a QUOTED or FENCED example, 1 reference(s): #711" \
    "the finding itself still reports"
  # A body edited to carry a SENTENCE finding still gets the strong banner.
  reset
  PR_BODY='Nothing here.
'
  PR_BODY_LATER='Closes #712 and #713
'
  run_merge
  assert_contains "$MERGE_STDOUT" "what this merge closes is below, not there" \
    "a sentence finding keeps the strong banner"
}

# Review round 14, P2. A dot after a keyword makes a dotted TOKEN, not a boundary: a filename and a
# hostname were both being read as closing directives, with the strong warning and reopen guidance
# on prose carrying no directive at all.
test_a_dotted_token_containing_a_keyword_is_not_a_keyword() {
  reset
  PR_BODY='The fixes.md file covers #714 and #715.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD" "a filename is not a directive"
  PR_BODY='See fixes.co for #716 and #717.
'
  run_merge
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD" "nor is a hostname"
  # The boundaries a real directive uses are untouched -- including a full stop that ENDS the
  # sentence, whose references stand before the keyword, which dropping the dot outright would
  # have silenced. The suite caught that overreach.
  PR_BODY='Closes: #718, #719
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #718 #719" "a colon still bounds a keyword"
  # Round 15 corrected this: a keyword ENDING the sentence binds nothing, because GitHub closing
  # syntax is the keyword followed by the reference. Round 14 asserted the opposite here, on my
  # reasoning about the dot rather than about GitHub.
  PR_BODY='Issues #720 and #721 are now fixed.
'
  run_merge
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD" \
    "references standing before the keyword are not bound by it"
}

# Review round 15, P2. GitHub closing syntax is the keyword FOLLOWED BY the reference, so a
# reference standing before the keyword is not bound -- and reporting one as closed, with advice to
# reopen it, is the false claim this scan exists to avoid making.
test_references_before_the_keyword_are_not_bound() {
  reset
  PR_BODY='Issues #722 and #723 are now fixed.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD" "neither reference follows the keyword"
  # One before and one after binds only the one after, which is one issue and so silent.
  PR_BODY='#724 is done, and this closes #725.
'
  run_merge
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD" "only the reference after the keyword binds"
  # The incident this feature was built for had both references after the keyword.
  PR_BODY='Resolves #726 and #727 for the phase
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #726 #727" "forward binding still warns"
}

# Review round 15, P2. The fourth register path: a retarget off the default branch retracted a
# quoted-only finding with WARNING WITHDRAWN.
test_a_retarget_withdrawal_keeps_the_finding_register() {
  reset
  PR_BODY='> Closes #728
'
  PR_BASE=main
  BASE_LATER=release-1.2
  run_merge
  assert_eq "$MERGE_RC" 0 "the merge still lands ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "CLOSING-KEYWORD NOTICE WITHDRAWN" "a notice is withdrawn as one"
  assert_not_contains "$MERGE_STDOUT" "WARNING WITHDRAWN" "and never promoted to a warning"
}

# Review round 15, P2. A mixed body: "closes what it listed" swept the quoted entry into a claim
# the scan refuses to make about it.
test_a_mixed_unchanged_body_confirms_each_class_in_its_own_terms() {
  reset
  PR_BODY='Closes #729 and #730

> Closes #731
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "closes the issues its WARNING listed" \
    "the confirmation is scoped to the sentence finding"
  assert_contains "$MERGE_STDOUT" "still claims nothing" "and the quoted entry keeps its register"
  assert_not_contains "$MERGE_STDOUT" "so the merge closes what it listed" \
    "the unscoped wording is gone on a mixed body"
}

# Review round 15, P2. A dot followed by an identifier continuation is not a boundary either.
test_a_dot_underscore_token_is_not_a_keyword() {
  reset
  PR_BODY='#801 and #802 use fix._config
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD" "a dotted identifier is not a directive"
}

# Review round 16, P2. Inside a top-level fence an indented delimiter is CONTENT, so closing there
# would turn the fenced lines after it into ordinary prose -- promoting a notice that claims
# nothing into a warning that says issues close.
test_an_indented_delimiter_inside_a_fence_is_content() {
  reset
  PR_BODY='```
    ```
Closes #802 and #803
```
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_contains "$MERGE_STDOUT" "CLOSING-KEYWORD NOTICE" "the line stays inside the fence"
  assert_not_contains "$MERGE_STDOUT" "CLOSING-KEYWORD WARNING" "and is not a closing claim"
}

# Review round 16, P2. The keyword must be located in the SAME text the references are read from:
# scrubbing inside refs_of let a keyword match a word in a URL path, after which the forward slice
# handed refs_of a fragment with the scheme and host already cut away.
test_a_keyword_inside_a_url_path_is_not_a_directive() {
  reset
  PR_BODY='See https://example.com/path,closes,details for issues #804 and #805.
'
  run_merge
  assert_eq "$MERGE_RC" 0 "still not a gate ($MERGE_OUTPUT)"
  assert_not_contains "$MERGE_OUTPUT" "CLOSING-KEYWORD" "a word in a URL path is not a directive"
  # A real directive alongside a URL still reports.
  PR_BODY='Closes #806 and #807; see https://example.com/path,closes,details.
'
  run_merge
  assert_contains "$MERGE_STDOUT" "ONE sentence, 2 issues: #806 #807" "the real directive still binds"
}

# Review round 16, P2. When the body could not be read, the deferred-merge refusal may not claim
# the scan spoke for the body.
test_the_deferred_merge_note_does_not_claim_an_unread_scan() {
  reset
  BODY_FAIL=1
  MERGE_STATE="merged=false state=OPEN"
  run_merge
  assert_eq "$MERGE_RC" 1 "a deferred merge is exit 1"
  assert_contains "$MERGE_OUTPUT" "scan did NOT read the body for this attempt" \
    "the refusal says the scan did not run"
  assert_not_contains "$MERGE_OUTPUT" "spoke for the body as it is NOW" \
    "and never claims it did"
  # With a readable body the original wording stands.
  reset
  MERGE_STATE="merged=false state=OPEN"
  run_merge
  assert_contains "$MERGE_OUTPUT" "spoke for the body as it is NOW" "a read body keeps the claim"
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
  test_a_longer_fence_is_not_closed_by_an_inner_one
  test_a_period_ends_the_unit_with_no_abbreviation_guard
  test_the_reopen_remedy_does_not_hardcode_this_repo
  test_the_body_is_scanned_again_before_the_merge
  test_an_unchanged_body_is_not_reported_twice
  test_a_repository_name_may_lead_with_punctuation
  test_a_closing_fence_takes_no_info_string
  test_a_quote_nested_in_a_list_item_is_still_quoted
  test_a_closing_quote_still_ends_the_sentence
  test_a_url_fragment_is_not_an_issue_reference
  test_the_same_issue_named_twice_is_one_issue
  test_four_space_indentation_is_not_a_quote_or_a_fence
  test_hash_zero_is_not_an_issue_reference
  test_a_schemeless_link_is_not_an_issue_reference
  test_the_local_qualified_spelling_is_the_same_issue
  test_the_body_is_rescanned_before_a_retried_merge
  test_no_warning_when_the_base_is_not_the_default_branch
  test_an_unread_default_branch_is_not_an_inert_keyword
  test_a_repository_named_like_a_keyword_is_not_a_keyword
  test_reference_case_does_not_make_a_second_issue
  test_a_tab_after_spaces_is_still_code_indentation
  test_an_invalid_backtick_opener_opens_no_fence
  test_a_retarget_during_the_gate_is_seen
  test_an_unknown_comparison_names_its_cause
  test_a_link_destination_does_not_join_two_sentences
  test_an_added_plain_closes_line_is_not_an_unchanged_body
  test_a_query_string_hash_is_not_an_issue_reference
  test_a_retarget_off_the_default_branch_withdraws_the_warning
  test_a_titled_link_does_not_join_two_sentences
  test_a_schemeless_url_containing_a_delimiter_is_stripped
  test_a_non_ascii_word_is_not_a_keyword
  test_a_reference_style_link_does_not_join_two_sentences
  test_a_reference_needs_a_boundary_after_its_digits
  test_a_query_only_schemeless_url_is_stripped
  test_an_over_long_numeric_prefix_is_not_a_list_marker
  test_the_queue_is_read_after_the_body_scan
  test_an_indented_code_line_is_not_scanned_at_all
  test_a_list_marker_does_not_swallow_code_indentation
  test_a_port_in_a_schemeless_url_is_stripped
  test_a_clean_body_edited_to_another_clean_body_is_silent
  test_an_unchanged_body_still_reports_a_lost_comparison
  test_an_indented_delimiter_leaves_the_fence_open
  test_a_quoted_finding_claims_nothing_about_closing
  test_an_unchanged_quoted_only_body_keeps_notice_wording
  test_an_identifier_containing_a_keyword_is_not_a_keyword
  test_control_bytes_in_the_body_cannot_forge_the_warning
  test_an_edited_body_with_a_quoted_only_finding_keeps_notice_wording
  test_a_dotted_token_containing_a_keyword_is_not_a_keyword
  test_references_before_the_keyword_are_not_bound
  test_a_retarget_withdrawal_keeps_the_finding_register
  test_a_mixed_unchanged_body_confirms_each_class_in_its_own_terms
  test_a_dot_underscore_token_is_not_a_keyword
  test_an_indented_delimiter_inside_a_fence_is_content
  test_a_keyword_inside_a_url_path_is_not_a_directive
  test_the_deferred_merge_note_does_not_claim_an_unread_scan
)

run_tests "${tests[@]}"
exit "$?"
}
