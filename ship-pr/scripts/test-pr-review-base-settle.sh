#!/usr/bin/env bash
# Focused fixture tests for the TIP'S OWN ABSENCE under `pr-review.sh base --wait`: the one
# absence that is not a race (ludics-lite#156, #163).
#
# The shape that blocked a wave's dispatch on 2026-09-15: the default branch's tip was a docs-only
# push, `ci` carries `paths-ignore: docs/**`, so no run for the tip was ever going to exist — and
# `base --wait` sat on it to its ceiling and refused, while the plain read settled for the older
# green on the same tip. The settle reads the workflow's own filter and the range the tip adds
# over the judged commit, commit by commit, and answers "a run cannot be created for this tip"
# — or refuses, which is what most of these cases pin: every way the recognition can be less than
# certain (a pattern it cannot translate, a range longer than the cap, a truncated commit list, a
# judged commit that is not an ancestor, a run that exists after all) must leave the wait waiting
# rather than hand out a green.
#
# The fixture transport is test-pr-review-base-lib.sh, shared with the red-report and verdict
# suites (ludics-lite#179). Two cases here are on the clock, and the idiom that keeps them honest
# — `spend_grace`, `at_round`, `rounds_polled` — is written down in that file's header.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=test-pr-review-lib.sh
source "$SCRIPT_DIR/test-pr-review-lib.sh"
# shellcheck source=test-pr-review-base-lib.sh
source "$SCRIPT_DIR/test-pr-review-base-lib.sh"

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

# --- the tip's own absence, and the one absence that is not a race (ludics-lite#156) -----------
# The shape that blocked a wave's dispatch on 2026-09-15: the default branch's tip was a docs-only
# push, `ci` carries `paths-ignore: docs/**`, so no run for the tip was ever going to exist —
# and `base --wait` sat on it to its ceiling and refused, while the plain read settled for the
# older green on the same tip. Nothing here is about time: the workflow's own filter says a run
# cannot be created for this tip, so the wait has nothing to wait for and settles at once. The
# grace is left at its default so that only the recognition can end this wait.
test_a_paths_ignored_tip_settles_without_waiting_out_the_grace() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5001}]')")
  FILES_DEFAULT='[{"filename":"docs/agent-notes/build-and-test.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 0 "a tip whose whole diff is paths-ignored settles for the older verdict"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" \
    "the settle answers about the tip it settled for"
  assert_contains "$BASE_OUTPUT" "every commit on the first-parent path from the judged commit up to the tip changes only paths within the paths-ignore of ci" \
    "the settle should say WHY no run is coming, not just that it waited"
  assert_contains "$BASE_OUTPUT" "(that verdict is about ${SHA_A:0:8}, not the tip ${SHA_C:0:8})" \
    "the older commit the verdict is really about stays named"
  assert_not_contains "$BASE_OUTPUT" "NO VERDICT" "this is a settled verdict, not a refusal"
  assert_contains "$(cat "$REQUEST_LOG")" "compare/$SHA_A...$SHA_C?per_page=" \
    "the range read is from the JUDGED commit to the tip"
  assert_contains "$(cat "$REQUEST_LOG")" "commits/$SHA_C" \
    "and each commit in that range is read for its own diff"
}

# The recognition is about the WHOLE diff: one path the filter does not cover and a run is coming
# after all. Then the only thing that can settle this wait is the grace, which is left at its
# default here — so the wait runs to its ceiling and refuses, as it must.
test_a_tip_that_changed_a_source_file_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5002}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"},{"filename":"src/main.ml"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a diff the filter does not cover is a tip whose run is still coming"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" \
    "an unrecognized tip keeps the refusal"
  assert_not_contains "$BASE_OUTPUT" "paths-ignore of" "nothing was recognized here"
  # The three reads are per workflow, judged commit and tip — not per round.
  assert_eq "$(grep -c "contents/" "$REQUEST_LOG")" 1 \
    "the workflow file should be read once, not once per round"
}

# A commit's changed files are PAGINATED — 30 to a page by default, 300 in all — so an
# unpaginated read of a 45-file commit answers with 30 ignored paths and hides the source file
# behind them (ludics-lite#163 review, round 2). The read asks for every page, and a list at the
# endpoint's own 300-file cap is a truncated diff that settles nothing.
test_a_commits_files_are_read_whole() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5101}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 0 "the ordinary docs-only tip still settles"
  assert_contains "$(cat "$PAGINATE_LOG")" "commits/$SHA_C" \
    "the commit's files must be read across every page, not one page of thirty"
  # ... and a diff at the cap is not a diff.
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5102}]')")
  FILES_DEFAULT=$(jq -cn '[range(300) | {filename: ("docs/f" + (. | tostring) + ".md")}]')
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a file list at the endpoint's cap is truncated, and truncated is not evidence"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# The filter is read at the TIP, but a mid-range push was judged by the workflow file as it stood
# then: a filter the tip widened would explain away a run the older file had already asked for
# (ludics-lite#163 review, round 2). So no commit in the range may touch the workflow file — then
# the one filter read is the one that applied to every push in it.
test_a_workflow_file_touched_inside_the_range_is_not_recognized() {
  reset_fixture
  # A filter that ignores the workflow directory too, so that nothing BUT the moved-filter check
  # can refuse this range: the commit changing ci.yml is itself covered by the patterns.
  WORKFLOW_YAML='on:
  push:
    paths-ignore:
      - "docs/**"
      - ".github/workflows/**"
'
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5111}]')")
  COMPARE_COMMITS=$(jq -cn --arg b "$SHA_B" --arg c "$SHA_C" '[$b, $c]')
  FILES_b='[{"filename":".github/workflows/ci.yml"}]' # the commit that widened the filter
  FILES_c='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a filter that moved mid-range is not one filter"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# The counterexample that makes this a per-COMMIT question (ludics-lite#163 review, round 1): a
# path filter is evaluated per PUSH, over that push's own before/after diff, so a range whose
# CUMULATIVE diff nets out to docs can still contain a push that touched source — here a commit
# that changes src/main.ml, a later one that reverts it, and a docs commit on top. The net diff of
# the whole range is one doc; every push in it that carried src/main.ml would get a run.
test_a_source_change_reverted_inside_the_range_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5071}]')")
  COMPARE_COMMITS=$(jq -cn --arg z "$SHA_0" --arg b "$SHA_B" --arg c "$SHA_C" '[$z, $b, $c]')
  FILES_0='[{"filename":"src/main.ml"}]'                # changed source
  FILES_b='[{"filename":"src/main.ml"}]'                # ... and reverted it
  FILES_c='[{"filename":"docs/notes.md"}]'              # the tip itself is docs-only
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a commit that touched source is a run on its way, whatever the range nets to"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
  assert_contains "$(cat "$REQUEST_LOG")" "commits/$SHA_B" \
    "the walk has to reach the intervening commit, not stop at a clean tip"
}

# After a force-push the judged commit is not an ancestor of the tip at all: the three-dot range
# describes the tip side of a fork, and the deletions the push carried are nowhere in it
# (ludics-lite#163 review, round 3). `behind_by` is what says so.
test_a_judged_commit_that_is_not_an_ancestor_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5121}]')")
  COMPARE_BEHIND=2 # the judged commit carries two commits the tip does not
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a fork is not a range this recognition can read"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# A commit's file list is its diff against its FIRST parent, so only the first-parent chain is a
# path those diffs describe. A merge reached through its second parent hides, behind a docs-only
# first-parent diff, every source change the push carried from the judged tip — so the walk has to
# reach the judged commit by first parents or refuse (ludics-lite#163 review, round 3).
test_a_merge_reached_through_its_second_parent_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5131}]')")
  # The tip is a merge whose FIRST parent is an older commit outside the range; the judged commit
  # is its second parent, which is how it entered the range at all.
  COMPARE_PARENTS=$(jq -cn --arg z "$SHA_0" '[$z]')
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a first-parent diff does not describe a path that is not first-parent"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# GitHub creates a run for a push of more than 1000 commits whatever the filter says, and a range
# that long is not what this recognition is for besides: past the cap it goes to the grace rather
# than to a read per commit. Every commit here is docs-only, so nothing but the length refuses it.
test_a_range_longer_than_the_cap_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5081}]')")
  COMPARE_COMMITS=$(jq -cn '[range(21) | "cccccccccccccccccccccccccccccccccccc" + (1000 + . | tostring)]')
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a range past the cap explains no absence"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
  assert_eq "$(grep -c "commits/cccccccccccccccccccccccccccccccccccc1000" "$REQUEST_LOG")" 0 \
    "and it spends no per-commit read on a range it has already refused"
}

# A commit list the answer truncated is not evidence about the range either: the total says one
# thing and the rows another, and the recognition believes neither.
test_a_truncated_commit_list_is_not_recognized() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5091}]')")
  COMPARE_TOTAL=5 # the list below carries one
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a range only partly in hand explains no absence"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# A pattern the translation does not carry fails the WHOLE question rather than just itself: with
# `!docs/keep.md` in the filter, "the other pattern covered everything" is not an answer about a
# filter half of which was not read.
test_an_untranslatable_pattern_refuses_the_recognition() {
  reset_fixture
  WORKFLOW_YAML='on:
  push:
    paths-ignore: ["docs/**", "!docs/keep.md"]
'
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5003}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a filter that was not fully read cannot explain an absence"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
}

# A workflow file the narrow parser cannot read (`on: [push]` names no filter at all) is refused
# the same way: a refusal costs the grace, which is the settle that was already there.
test_a_workflow_file_without_a_filter_refuses_the_recognition() {
  reset_fixture
  WORKFLOW_YAML='on: [push]
jobs:
  build:
    runs-on: ubuntu-latest
'
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5004}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a workflow whose push filter cannot be read explains no absence"
  assert_not_contains "$BASE_OUTPUT" "within the paths-ignore of" "no recognition may be claimed"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 \
    "with no filter in hand there is nothing to compare the tip against"
}

# A run in flight ANYWHERE on this branch is judging a tree the tip contains, so the older green
# under it is not an all-clear for the tip: settling there hands out a verdict for a tree whose
# own run is minutes from answering (ludics-lite#163 review, round 1). Waiting also does BETTER
# than settling — when that run lands, its commit is what the tip's absence then trails.
test_a_run_in_flight_on_the_branch_keeps_the_wait() {
  reset_fixture
  retune ABSENT_GRACE=0
  RUNS_1=$(runs_json 1 "$(jq -cn --arg b "$SHA_B" --arg a "$SHA_A" \
    '[{status:"in_progress", conclusion:null, head_sha:$b, id:5011},
      {conclusion:"success", head_sha:$a, id:5010}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]' # would be recognized with nothing in flight
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "an unfinished run on the branch is a verdict still coming"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" "the refusal stands"
  assert_contains "$BASE_OUTPUT" "(ci is running now at ${SHA_B:0:8})" \
    "the run being waited for should be named"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 \
    "with a verdict in flight there is nothing for the filter to explain"
}

# The grace is a clock about the TIP, and it starts when the tip is first read — not when that
# round's last answer comes back. Re-stamping it on the first round spends the round's own API
# latency out of the grace, and `--wait=301` over a 300s grace then reaches its ceiling a few
# seconds before the clock it was sized against, every time: #156's dispatch refusal. The first
# read here is slow on purpose, which is what an API round is.
test_the_grace_runs_from_the_first_read_of_the_tip() {
  reset_fixture
  retune ABSENT_GRACE=3 CHECKS_INTERVAL=1
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5051}]')")
  FILES_DEFAULT='[{"filename":"src/main.ml"}]' # unrecognized: only the clock can settle this
  # The round's own reads take 3s, the grace is 3s and the ceiling 4s: measured from the first
  # READ the grace expires inside the wait, measured from the round's last answer it cannot.
  spend_grace 3
  run_base --wait=4
  assert_eq "$BASE_RC" 0 "the grace should expire inside a wait sized against it"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" \
    "the settle is for the verdicts in hand"
  assert_contains "$BASE_OUTPUT" "no run for the tip appeared" "the note should say what was waited for"
}

# --- the ceiling's own arithmetic (ludics-lite#175) --------------------------------------------
# The grace is tested ONCE PER ROUND, after that round's own API calls, and rounds are one poll
# interval apart. So between the last round before the grace expires and the first one after it
# lies a whole interval — and a ceiling landing inside that interval ends the wait at NO VERDICT
# for a tip the next round would have settled. `--wait=301` over a 300s grace was exactly that
# number, and it is what the wave gate spelled until #175. The refusal is arithmetic over the two
# knobs, not a blocklist of 301, so it holds wherever either of them is moved to.
test_a_wait_that_cannot_outlive_its_grace_is_refused() {
  reset_fixture
  retune ABSENT_GRACE=300 CHECKS_INTERVAL=60
  run_base --wait=301
  assert_eq "$BASE_RC" 2 "a ceiling one second over the grace is a usage error, not a wait"
  assert_contains "$BASE_OUTPUT" "--wait=301 cannot outlive the 300s absence grace" \
    "the refusal should name the ceiling and the grace it was sized against"
  assert_contains "$BASE_OUTPUT" "at least 360" "and the smallest ceiling that does reach the settle"
  assert_contains "$BASE_OUTPUT" "at most 300" "and the bounded peek that is still allowed"
  assert_eq "$(grep -c . "$REQUEST_LOG")" 0 \
    "the refusal is arithmetic over two knobs and must cost no API read at all"
}

# The other end of the same band: one whole round of margin is enough, and a wait sized that way
# is an ordinary wait — here it settles on the recognition, as any --wait would.
test_a_wait_of_one_round_over_the_grace_is_accepted() {
  reset_fixture
  retune ABSENT_GRACE=300 CHECKS_INTERVAL=60
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5071}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=360
  assert_eq "$BASE_RC" 0 "grace plus one round is the derived ceiling and is a valid wait"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" "and it waits as any other does"
}

# A ZERO grace is outside the band entirely: with nothing to outlive, the absence is eligible to
# settle on the first round, so every positive ceiling reaches it (review round 1). Refusing a
# short wait there would take away the bounded read that `SHIP_PR_BASE_ABSENT_GRACE=0` exists for.
test_a_zero_grace_admits_any_positive_wait() {
  reset_fixture
  retune ABSENT_GRACE=0 CHECKS_INTERVAL=60
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5091}]')")
  FILES_DEFAULT='[{"filename":"src/main.ml"}]' # unrecognized: the zero grace is what settles it
  run_base --wait=30
  assert_eq "$BASE_RC" 0 "a wait shorter than one interval is fine when there is no grace to outlive"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" "and it settles at once"
  assert_not_contains "$BASE_OUTPUT" "cannot outlive" "and is certainly not a usage error"
}

# A ceiling at or BELOW the grace is not the #175 mistake: it is a bounded peek — "tell me what
# you have within N seconds" — which cannot settle an absence and says so, exit 4. Refusing it
# would take away the only way to ask this command a time-boxed question, and every case in this
# suite that reads a refusal at the ceiling asks exactly that.
test_a_wait_inside_the_grace_is_a_bounded_peek_not_a_refusal() {
  reset_fixture
  retune ABSENT_GRACE=300 CHECKS_INTERVAL=60
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5081}]')")
  FILES_DEFAULT='[{"filename":"src/main.ml"}]' # unrecognized: only the clock could settle this
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a wait shorter than the grace reports no verdict, it is not refused"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" "and it says so about the tip"
}

# A listed workflow with NO push run on this branch at all is not in the fold, so no filter of its
# was read: it may be dispatch- or schedule-only, or a workflow the tip itself just added whose
# first run is on its way. One workflow's docs-only diff cannot speak for it, so the FAST settle
# has to hold — and the grace, which is exactly that newcomer's creation window, still settles.
test_a_workflow_with_no_run_history_holds_the_fast_settle() {
  reset_fixture
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"fresh"}]')
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5061}]')")
  RUNS_2=$(jq -cn '{workflow_runs: []}')
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a filter nobody read cannot be settled over"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" "the refusal stands"
  # ... and the grace, which is the newcomer's own creation window, settles it as it always did.
  reset_fixture
  retune ABSENT_GRACE=0
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"fresh"}]')
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5062}]')")
  RUNS_2=$(jq -cn '{workflow_runs: []}')
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 0 "the grace is the newcomer's creation window, and it still settles"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_C:0:8})" \
    "a repository carrying a dispatch-only workflow must not park on it forever"
}

# What a run FOR THE TIP means, in both of its shapes: it exists, so no filter explains it, and
# only that run can answer. In flight, the wait waits — past any grace, and without spending a
# read on a recognition that could not apply.
test_a_run_in_flight_at_the_tip_keeps_the_refusal() {
  reset_fixture
  retune ABSENT_GRACE=0
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{status:"in_progress", conclusion:null, head_sha:$c, id:5021},
      {conclusion:"success", head_sha:$a, id:5020}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]' # would be recognized if the tip had no run
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a run judging the tip is the answer to wait for"
  assert_contains "$BASE_OUTPUT" "NO VERDICT for the tip ${SHA_C:0:8}" "the refusal stands"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 \
    "an existing run is not an absence: nothing to recognize, and no read to spend on it"
}

# Stopped, the wait allows the grace for a superseding run to be created and then says the verdict
# is NONE — a cancelled run judged nothing, so it is neither absence nor an all-clear.
test_a_stopped_run_at_the_tip_is_no_verdict_not_an_absence() {
  reset_fixture
  retune ABSENT_GRACE=0
  RUNS_1=$(runs_json 1 "$(jq -cn --arg c "$SHA_C" --arg a "$SHA_A" \
    '[{conclusion:"cancelled", head_sha:$c, id:5031}, {conclusion:"success", head_sha:$a, id:5030}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  run_base --wait=2
  assert_eq "$BASE_RC" 4 "a stopped run at the tip is not an absence any filter explains"
  assert_contains "$BASE_OUTPUT" "stopped-not-judged and no replacement appeared" \
    "the report should say the workflow wants re-running"
  assert_eq "$(grep -c "compare/" "$REQUEST_LOG")" 0 "a run that existed is not a paths-ignore tip"
}

# This settle accepts a verdict about an OLDER commit, so the tip it settles for has to still be
# the tip: a push landing between the round's tip read and the settle would otherwise be answered
# with a green from two commits back. The branch moves right after the round's own read here, so
# the first tip is never settled for — the successor is judged on its own.
test_the_settle_reconfirms_the_tip_before_it_accepts_an_older_verdict() {
  reset_fixture
  RUNS_1=$(runs_json 1 "$(jq -cn --arg a "$SHA_A" '[{conclusion:"success", head_sha:$a, id:5041}]')")
  FILES_DEFAULT='[{"filename":"docs/notes.md"}]'
  # The round's tip read answers SHA_C; the re-confirm, and everything after that round's own
  # reads, answers SHA_B — as a push landing in that window would.
  at_round 1 "$SHA_B"
  COMPARE_COMMITS=$(jq -cn --arg b "$SHA_B" '[$b]') # the successor's own one-commit range
  run_base --wait=4
  assert_eq "$BASE_RC" 0 "the successor tip is itself paths-ignored, and settles on its own round"
  assert_contains "$BASE_OUTPUT" "$REPO $BRANCH: green (tip ${SHA_B:0:8})" \
    "the settle is for the tip that is still there"
  assert_not_contains "$BASE_OUTPUT" "green (tip ${SHA_C:0:8})" \
    "the tip that moved under the round must never be settled for"
  assert_contains "$(cat "$REQUEST_LOG")" "compare/$SHA_A...$SHA_B?per_page=" \
    "the successor is judged by its own range"
}

tests=(
  test_a_paths_ignored_tip_settles_without_waiting_out_the_grace
  test_a_tip_that_changed_a_source_file_is_not_recognized
  test_a_commits_files_are_read_whole
  test_a_workflow_file_touched_inside_the_range_is_not_recognized
  test_a_source_change_reverted_inside_the_range_is_not_recognized
  test_a_judged_commit_that_is_not_an_ancestor_is_not_recognized
  test_a_merge_reached_through_its_second_parent_is_not_recognized
  test_a_range_longer_than_the_cap_is_not_recognized
  test_a_truncated_commit_list_is_not_recognized
  test_an_untranslatable_pattern_refuses_the_recognition
  test_a_workflow_file_without_a_filter_refuses_the_recognition
  test_a_run_in_flight_on_the_branch_keeps_the_wait
  test_the_grace_runs_from_the_first_read_of_the_tip
  test_a_wait_that_cannot_outlive_its_grace_is_refused
  test_a_wait_of_one_round_over_the_grace_is_accepted
  test_a_wait_inside_the_grace_is_a_bounded_peek_not_a_refusal
  test_a_zero_grace_admits_any_positive_wait
  test_a_workflow_with_no_run_history_holds_the_fast_settle
  test_a_run_in_flight_at_the_tip_keeps_the_refusal
  test_a_stopped_run_at_the_tip_is_no_verdict_not_an_absence
  test_the_settle_reconfirms_the_tip_before_it_accepts_an_older_verdict
)

run_tests "${tests[@]}"
exit "$?"
}
