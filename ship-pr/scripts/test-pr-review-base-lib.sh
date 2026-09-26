#!/usr/bin/env bash
# The fixture transport the three `pr-review.sh base` suites share, and the wall-clock idiom they
# all have to get right. A suite sources it right after the preamble, and defines nothing of its
# own above either source (ludics-lite#179):
#
#   SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
#   # shellcheck source=test-pr-review-lib.sh
#   source "$SCRIPT_DIR/test-pr-review-lib.sh"
#   # shellcheck source=test-pr-review-base-lib.sh
#   source "$SCRIPT_DIR/test-pr-review-base-lib.sh"
#
# The suites over it, one subject each — `base` was one 900-line, 33-case file carrying the first
# three, where "which suite failed" said only "base":
#
#   test-pr-review-base-red.sh      the RED report: which job failed and where the red started
#                                   (ludics-lite#73, #81)
#   test-pr-review-base-settle.sh   the tip's own ABSENCE: the paths-ignore settle and the one
#                                   absence that is not a race (ludics-lite#156, #163)
#   test-pr-review-base-verdict.sh  what the WAIT LOOP decides: which break ends the wait, what
#                                   each break re-confirms, where the absence clock starts
#                                   (ludics-lite#93)
#   test-pr-review-base-pushless.sh a workflow that no longer runs on push: the tip judged by a
#                                   NAMED source or not at all (ludics-lite#401)
#
# What this file provides: the canned answers keyed the way `base` reads them (TIP, WORKFLOWS_JSON,
# RUNS_<id>, JOBS_<run id>, FILES_<sha initial>, the compare and the workflow file), the fixture
# `gh` that serves them, `reset_fixture` to clear every one of them between cases, `run_base` to
# capture a command's output and status, and the wall-clock idiom below.
#
# Executed rather than sourced, it runs its own controls over that transport: the round counter,
# the delay, and the tip move, each read directly off the fixture rather than through a `base`
# run, so they say what the transport does and not what the script made of it.

# Executed rather than sourced, this file sources the preamble ITSELF, before it defines anything:
# the preamble refuses a caller that defined functions above it (the shadow in the other
# direction), so its own controls could not otherwise run. Sourced by a suite that skipped the
# preamble it refuses instead, rather than sourcing it from under the suite — a suite's
# definitions belong below both files, and the preamble is the one that can say so.

# One brace group, so bash parses this file WHOLE before its first line runs and an edit landing
# while a run is in flight cannot resume the shell at a shifted offset; the `exit` at the foot
# means the shell never comes back to the file for a next command. Two lines here and two at the
# foot, with the body's own indentation untouched (ludics-lite#10, #247); scripts/check-parse-guards.sh
# checks the shape. Sourced by a sibling suite, the `|| return 0` dispatch below ends the source
# inside the group, before the foot's `exit` is reached, so the caller survives.
{
BASE_LIB_BASENAME=$(basename "${BASH_SOURCE[0]}")
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -euo pipefail
  BASE_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
  # shellcheck source=test-pr-review-lib.sh
  source "$BASE_LIB_DIR/test-pr-review-lib.sh"
elif [ -z "${LIB_BASENAME:-}" ]; then
  echo "$BASE_LIB_BASENAME: REFUSING to run: source test-pr-review-lib.sh first — it is what sources pr-review.sh and installs the shadow guard this file's fixture is checked by" >&2
  exit 2
fi

test_tmpdir TEST_ROOT base-fixture

REPO=example/repo
BRANCH=main
REQUEST_LOG="$TEST_ROOT/requests"
# What the fixture `gh` records as PAGINATED: a commit's files are served 30 to a page, so the
# read that walks them has to ask for every one.
PAGINATE_LOG="$TEST_ROOT/paginated"

# Four commits, oldest last, in the order the fixtures list their runs.
SHA_C=cccccccccccccccccccccccccccccccccccccccc
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_0=0000000000000000000000000000000000000000

# --- the fixture transport --------------------------------------------------------------------
# `base` reads the branch tip, the workflow list, then each workflow's runs SEPARATELY (a flat
# page of runs can postdate an infrequent workflow's newest run entirely), and finally — only on
# a red — that run's jobs. So the canned answers are keyed the same way: one per workflow id, one
# per run id. bash 3.2 has no associative arrays; the per-key answers are plain variables reached
# through `eval`, as the other suites' sequence pops are.
TIP=""
WORKFLOWS_JSON=""
JOBS_DEFAULT=""
FAIL_ENDPOINT=""
# The HTTP status a failed read reports: a 5xx is transport, which gh_retry retries, while a 4xx is
# the API's answer — a 404 or a 403 on the workflow file is how base_push_trigger meets a missing
# file and a token that may not read it (ludics-lite#401).
FAIL_STATUS=""
# The settle path's three reads (ludics-lite#156): the workflow FILE (its path, then its body at
# the tip, served raw as the library asks for it) and the compare from the judged commit to the
# tip. One body and one file list for every workflow here: the cases that care which compare was
# asked for read $REQUEST_LOG, which records the endpoint.
WORKFLOW_PATH=""
WORKFLOW_YAML=""
# The range the tip adds over the judged commit, and what each of its commits changed: the
# recognition reads the commits ONE BY ONE, because a path filter is evaluated per push and the
# cumulative diff of a range can hide a push that touched source. COMPARE_TOTAL is the compare's
# own total_commits, which a case moves on its own to stand for a range too long or a list the
# answer truncated.
# The commits the tip adds over the judged commit, oldest first, each the first parent of the next
# — the shape a linear range has. COMPARE_PARENTS overrides the first parent of each of them, for
# the cases about a merge reached through its SECOND parent; COMPARE_BEHIND makes the judged commit
# a fork rather than an ancestor, as a force-push leaves it.
COMPARE_COMMITS=""
COMPARE_PARENTS=""
COMPARE_TOTAL=""
COMPARE_BEHIND=""
FILES_DEFAULT=""
# Source (a) of a tip no push run judges (ludics-lite#401): what `commits/<sha>` says about the
# commit beyond its files (COMMIT_META, merged into that answer: its parents, its committer, its
# signature), the pull requests associated with it (TIP_PULLS), and the merged PR's head as
# `checks` reads it — the PR itself (HEAD_PR), its check runs (HEAD_CHECKS) and its workflow runs
# (HEAD_RUNS).
COMMIT_META=""
# The `.github/workflows` directory at a ref, as the Contents API lists it: what confirms that a
# workflow file answering 404 is really absent there.
WORKFLOW_DIR=""
TIP_PULLS=""
HEAD_PR=""
HEAD_CHECKS=""
HEAD_RUNS=""
# What the head's run list answers from its SECOND read on, when a case sets it: a re-run that
# started between the build signal's read and the one after it.
HEAD_RUNS_LATER=""
# The delay the wall-clock cases spend their grace with, in seconds; set through `spend_grace`
# below, which is where the idiom is written down. DELAY_LOG records each delay actually taken,
# so "once" is a fact the controls can read rather than a property of a marker file's existence.
FIRST_READ_DELAY=""
DELAY_LOG="$TEST_ROOT/delays"

# A ci workflow as the fleet's repositories write one: docs are the paths-ignore.
DOCS_IGNORED_YAML='name: ci
on:
  push:
    branches: [main]
    paths-ignore:
      - "docs/**"
      - "**.md"
jobs:
  build:
    runs-on: ubuntu-latest
'

# The tip read answers TIP until the wait has run TIP_AT_ROUND rounds, and TIP_NEXT from then on:
# how a case moves the branch between the round's own tip read and everything that round does
# after it, the settle's and the breaks' re-confirms included. Set through `at_round` below. The
# round counter is the lib's `fixture_call_count rounds`: a file, not a variable, because every
# one of these reads happens inside a command substitution, where an incremented variable would
# die with the subshell (test-pr-review-lib.sh, "counting a fixture's calls"). One count per read
# of the first listed workflow's runs feed, which is one per round; `rounds_polled` below reads
# it back.
TIP_AT_ROUND=""
TIP_NEXT=""
# The first listed workflow's id, cached: it is read off WORKFLOWS_JSON, which a case sets after
# reset_fixture, and every read that would compute it happens in a command substitution of its
# own. Cleared with the rest of the fixture.
FIRST_WID_CACHE="$TEST_ROOT/first-wid"

# runs_json <workflow id> <json array of run overrides>, newest first. Each row defaults to a
# completed push run of a workflow named "ci", with a distinct id and a created_at that decreases
# with the index, so the fixture reads the way the API's own newest-first page does.
runs_json() {
  jq -cn --argjson wf "$1" --argjson runs "$2" \
    '{workflow_runs: [$runs | to_entries[] | .value + {
        workflow_id: $wf,
        id: (.value.id // (1000 * $wf + .key)),
        name: (.value.name // "ci"),
        status: (.value.status // "completed"),
        head_sha: (.value.head_sha // "0000000000000000000000000000000000000000"),
        created_at: (.value.created_at // ("2026-09-10T00:" + ((59 - .key) | tostring) + ":00Z")),
        html_url: (.value.html_url //
                   ("https://example.test/runs/" + ((.value.id // (1000 * $wf + .key)) | tostring)))
      }]}'
}

workflows_json() { jq -cn --argjson wf "$1" '{workflows: $wf}'; }
jobs_json() { jq -cn --argjson jobs "$1" '{jobs: $jobs}'; }

# The canned answer for one key, empty when the case set none: `runs_of 2` reads RUNS_2, `jobs_of
# 3003` reads JOBS_3003 and falls back to JOBS_DEFAULT.
runs_of() { eval "printf '%s' \"\${RUNS_$1:-}\""; }
jobs_of() { eval "printf '%s' \"\${JOBS_$1:-\$JOBS_DEFAULT}\""; }
# One commit's changed files: keyed by the first character of its sha, which is what tells this
# suite's commits apart (SHA_A, SHA_B, SHA_C, SHA_0 are runs of one character), falling back to
# FILES_DEFAULT for a case that gives every commit the same diff.
files_of() { eval "printf '%s' \"\${FILES_${1:0:1}:-\$FILES_DEFAULT}\""; }

# The id of the first workflow the list answers with, cached in a file: see FIRST_WID_CACHE.
first_wid() {
  [ -s "$FIRST_WID_CACHE" ] ||
    jq -r '.workflows[0].id' <<<"$WORKFLOWS_JSON" >"$FIRST_WID_CACHE"
  cat "$FIRST_WID_CACHE"
}

reset_fixture() {
  local v
  TIP="$SHA_C"
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"}]')
  RUNS_1=$(runs_json 1 '[]')
  # Every RUNS_<n>/JOBS_<n> a previous case set is cleared, or a case that names none would be
  # served the last case's answers and pass for its neighbour's reasons.
  # Shell values can contain non-text bytes; only the ASCII variable names are parsed.
  for v in $(set | LC_ALL=C sed -n 's/^\(RUNS_[0-9][0-9]*\)=.*/\1/p;s/^\(JOBS_[0-9][0-9]*\)=.*/\1/p'); do
    [ "$v" = RUNS_1 ] || unset "$v"
  done
  JOBS_DEFAULT=$(jobs_json '[]')
  FAIL_ENDPOINT=""
  FAIL_STATUS=500
  BASE_JOBS_CACHE=""
  BASE_RED_DETAIL=""
  BASE_IGNORE_CACHE=""
  WORKFLOW_PATH=".github/workflows/ci.yml"
  WORKFLOW_YAML="$DOCS_IGNORED_YAML"
  COMPARE_COMMITS=$(jq -cn --arg c "$SHA_C" '[$c]')
  COMPARE_PARENTS=""
  COMPARE_TOTAL=""
  COMPARE_BEHIND=""
  FILES_DEFAULT='[]'
  COMMIT_META='{}'
  WORKFLOW_DIR='[{"type":"file","path":".github/workflows/ci.yml"}]'
  TIP_PULLS='[]'
  HEAD_PR='{}'
  HEAD_CHECKS='{"check_runs":[]}'
  HEAD_RUNS='{"workflow_runs":[]}'
  HEAD_RUNS_LATER=""
  fixture_call_reset headruns
  FIRST_READ_DELAY=""
  for v in $(set | LC_ALL=C sed -n 's/^\(FILES_[0-9a-z]\)=.*/\1/p'); do unset "$v"; done
  : >"$DELAY_LOG"
  : >"$PAGINATE_LOG"
  TIP_AT_ROUND=""
  TIP_NEXT=""
  fixture_call_reset rounds
  rm -f "$FIRST_WID_CACHE"
  # The wait loop's clocks, for the one case that takes more than a single round.
  retune ABSENT_GRACE=300 CHECKS_INTERVAL=1 CHECKS_HEARTBEAT=600
  : >"$REQUEST_LOG"
}

gh() {
  local response="" rid wid sha base reads
  # The delay, once — on the FIRST read of the run, which is the round's tip read.
  if [ -n "$FIRST_READ_DELAY" ] && [ ! -s "$DELAY_LOG" ]; then
    printf 'x\n' >>"$DELAY_LOG"
    sleep "$FIRST_READ_DELAY"
  fi
  gh_fixture_parse "$@"
  if [ -n "$FAIL_ENDPOINT" ]; then
    # A GLOB, deliberately unquoted, so a case can fail the jobs read alone: it is the read whose
    # failure must not touch the verdict, and a pattern that also failed the runs read would
    # prove that from the wrong end.
    # shellcheck disable=SC2254
    case "$FIXTURE_ENDPOINT" in
    $FAIL_ENDPOINT)
      echo "gh: $FIXTURE_ENDPOINT unavailable (HTTP $FAIL_STATUS)" >&2
      return 1
      ;;
    esac
  fi
  case "$FIXTURE_ENDPOINT" in
  "repos/$REPO/commits/$BRANCH")
    if [ -n "$TIP_AT_ROUND" ] && [ "$(rounds_polled)" -ge "$TIP_AT_ROUND" ]; then
      response=$(jq -cn --arg sha "$TIP_NEXT" '{sha: $sha}')
    else
      response=$(jq -cn --arg sha "$TIP" '{sha: $sha}')
    fi
    ;;
  "repos/$REPO/actions/workflows?per_page=100") response="$WORKFLOWS_JSON" ;;
  "repos/$REPO/actions/workflows/"*"/runs?branch=$BRANCH&event=push&per_page=10")
    wid=${FIXTURE_ENDPOINT#*/actions/workflows/}
    wid=${wid%%/*}
    # The round counter: `base` reads every listed non-advisory workflow's runs feed once per
    # round, so the FIRST listed workflow's read is one per round and nothing else here is.
    # (A fixture whose first workflow is advisory would never be read, and would count no
    # rounds — no case lists one, and `is_advisory` is pr-review.sh's own test for it.)
    # `|| return 1`: the fixture runs in gh_retry's command substitution, which does not inherit
    # errexit, so a count that bails must be turned into a failed read by hand.
    [ "$wid" != "$(first_wid)" ] || fixture_call_count rounds >/dev/null || return 1
    response=$(runs_of "$wid")
    [ -n "$response" ] || response=$(runs_json "$wid" '[]')
    ;;
  "repos/$REPO/actions/runs/"*"/jobs?per_page=100")
    rid=${FIXTURE_ENDPOINT#*/actions/runs/}
    rid=${rid%%/*}
    response=$(jobs_of "$rid")
    ;;
  # The workflow's own file: where it lives, then what it says at the tip. The body is served
  # verbatim — the library asks for the raw media type rather than the base64 JSON, whose decoder
  # is spelled differently on this fleet's two platforms.
  "repos/$REPO/actions/workflows/"*) response=$(jq -cn --arg p "$WORKFLOW_PATH" '{path: $p}') ;;
  "repos/$REPO/contents/.github/workflows?ref="*) response="$WORKFLOW_DIR" ;;
  "repos/$REPO/contents/"*) response="$WORKFLOW_YAML" ;;
  "repos/$REPO/compare/"*)
    # Oldest first, so each commit's first parent is the one before it and the first commit's is
    # the compare's base — the judged commit, which the endpoint names in the path.
    base=${FIXTURE_ENDPOINT#*/compare/}
    base=${base%%...*}
    response=$(jq -cn --argjson c "$COMPARE_COMMITS" --arg t "$COMPARE_TOTAL" \
      --arg b "$base" --arg behind "$COMPARE_BEHIND" --argjson p "${COMPARE_PARENTS:-null}" \
      '{total_commits: (if $t == "" then ($c | length) else ($t | tonumber) end),
        behind_by: (if $behind == "" then 0 else ($behind | tonumber) end),
        commits: [$c | to_entries[] |
          {sha: .value,
           parents: [{sha: (if $p != null then $p[.key]
                            else (if .key == 0 then $b else $c[.key - 1] end) end)}]}]}')
    ;;
  "repos/$REPO/commits/"*"/pulls?per_page=100") response="$TIP_PULLS" ;;
  "repos/$REPO/commits/"*"/check-runs?"*) response="$HEAD_CHECKS" ;;
  "repos/$REPO/pulls/"*) response="$HEAD_PR" ;;
  "repos/$REPO/actions/runs?head_sha="*)
    response="$HEAD_RUNS"
    if [ -n "$HEAD_RUNS_LATER" ]; then
      # `|| return 1`, as the round counter's: this runs in a substitution without errexit.
      reads=$(fixture_call_count headruns) || return 1
      [ "$reads" -le 1 ] || response="$HEAD_RUNS_LATER"
    fi
    ;;
  "repos/$REPO/commits/"*)
    sha=${FIXTURE_ENDPOINT#*/commits/}
    sha=${sha%%\?*}
    response=$(jq -cn --argjson f "$(files_of "$sha")" --argjson m "$COMMIT_META" '$m + {files: $f}')
    ;;
  *) bail "unexpected fixture endpoint: $FIXTURE_ENDPOINT" ;;
  esac
  gh_fixture_answer "$response"
}

run_base() {
  local capture rc
  set +e
  capture=$(cmd_base "$BRANCH" "$@" 2>&1)
  rc=$?
  set -e
  BASE_OUTPUT="$capture"
  BASE_RC="$rc"
}

# A window filled to its end with failures: <n> rows, each red, oldest at SHA_0.
all_red_runs() {
  jq -cn --argjson n "$1" '[range($n) | {conclusion: "failure"}]'
}

# --- the wall-clock idiom (ludics-lite#169, #179) ---------------------------------------------
# Five cases here depend on SECONDS: a retuned grace, a `--wait` ceiling, and a delay inside the
# fixture. They are the only cases in this repository whose fixture and whose subject are both on
# the clock, and they went red on a loaded machine twice before settling into one shape. It is
# three rules, and each of them is a thing that failed:
#
#   Put the clock in an explicit DELAY. The grace is spent by `spend_grace <seconds>`, which
#   holds up the round's FIRST read by that much, and never by "however long N rounds take".
#   `CHECKS_INTERVAL=1` makes a round about a second on an idle box and rather more on a busy
#   one, so a case counting rounds against a grace is a case that passes when the box is quiet.
#
#   Put the fixture's EVENT on round one. `at_round <n> <sha>` moves the branch on the runs-feed
#   read count, which is one per round by construction — but the `n` every case here passes is 1.
#   A tip that moved "five rounds in" was counted in tip READS, of which a round takes one or
#   two depending on which break re-confirms, and where a round launches a fixture and several
#   jq subprocesses: under load four rounds happened where five were counted on, and the move
#   landed on the wrong side of the clock (#169, round 2).
#
#   Keep the CEILING clear of both. `--wait=<n>` must not be able to arrive during the delay or
#   within a round of the grace it is sized against, in either direction; a ceiling that can
#   overtake the event is a case that reports the wrong reason for the right exit code.
#
# What is NOT on the clock stays off it: a case that wants an ordinary round asks for `--wait=2`
# and reads `rounds_polled`, not elapsed time.

# spend_grace <seconds>: hold up the fixture's FIRST read by <seconds>, once. An API round takes
# time, and the grace is measured from when the tip was first READ, so a case that needs the grace
# to expire inside the wait spends it here rather than waiting rounds out. Once, because every
# read is a command substitution where a cleared variable would not survive — so the count of
# delays taken is kept in a file, which is also what the control below reads.
spend_grace() {
  case "$1" in '' | *[!0-9]*) bail "spend_grace: seconds, got '$1'" ;; esac
  FIRST_READ_DELAY="$1"
}

# delays_taken: how many times the fixture has held up a read. One, for every case that asks.
delays_taken() { wc -l <"$DELAY_LOG" | tr -d ' '; }

# rounds_polled: how many rounds the wait loop has run, counted as the reads of the FIRST listed
# workflow's runs feed — one per round by construction, since `base` reads every listed
# non-advisory workflow's runs exactly once per round. Counting the runs feed as a whole would
# multiply by the number of workflows a case lists; counting tip reads would add the re-confirm
# read that only some breaks perform.
rounds_polled() { fixture_call_total rounds; }

# at_round <n> <sha>: from the <n>th round on, the branch tip answers <sha>. The move lands
# between that round's own tip read and everything the round does after it — which is where a
# push during the round lands, and so is what every re-confirm in these suites is pinned against.
at_round() {
  [ $# -eq 2 ] || bail "at_round: no sha — \`at_round <n> <sha>\`"
  case "$1" in '' | *[!0-9]* | 0) bail "at_round: a round number from 1, got '$1'" ;; esac
  TIP_AT_ROUND="$1"
  TIP_NEXT="$2"
}

# Everything above is in scope in all three suites, exactly as pr-review.sh's functions are, so it
# is protected exactly as they are: the preamble's snapshot was taken before this file existed, and
# `protect_library` extends it over what this file defines (review of ludics-lite#212, round 1).
# `${BASH_SOURCE[0]}` verbatim, because that is the path `declare -F` recorded.
protect_library "${BASH_SOURCE[0]}"

# --- executed: this file's own controls --------------------------------------------------------
# What is controlled here is the TRANSPORT, read directly — a `gh` call at a time, with no `base`
# run around it. The three wall-clock devices above are the whole reason: a control that drove
# them through `cmd_base` would be on the clock itself, which is the property that made the cases
# they exist for flaky in the first place.
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0

# The fixture, called the way `base` calls it: one endpoint, answered.
fixture_gh() { local ep="$1"; shift; gh api "repos/$REPO/$ep" "$@"; }
tip_read() { fixture_gh "commits/$BRANCH" --jq .sha; }
runs_read() { fixture_gh "actions/workflows/$1/runs?branch=$BRANCH&event=push&per_page=10" >/dev/null; }

# One read of the first listed workflow's runs feed is one round; nothing else is. A second
# workflow is listed here because counting the runs feed as a whole — the obvious reading — would
# count two, and a wait's rounds would then be double what a case asked for.
test_the_round_counter_counts_rounds_and_not_reads() {
  reset_fixture
  WORKFLOWS_JSON=$(workflows_json '[{"id":1,"name":"ci"},{"id":2,"name":"fixtures"}]')
  assert_eq "$(rounds_polled)" 0 "no round has been polled yet"
  tip_read >/dev/null
  assert_eq "$(rounds_polled)" 0 "a tip read is not a round: some breaks read it twice"
  runs_read 1
  runs_read 2
  assert_eq "$(rounds_polled)" 1 "a round is a round however many workflows it reads"
  tip_read >/dev/null
  runs_read 1
  runs_read 2
  assert_eq "$(rounds_polled)" 2 "and the next round is the next count"
  reset_fixture
  assert_eq "$(rounds_polled)" 0 "the counter is cleared with the rest of the fixture"
}

# The delay is the first READ's, and it happens once: a delay per read would multiply by the
# number of reads a round makes, which is the count nobody can hold still.
test_the_grace_is_spent_once_on_the_first_read() {
  local started elapsed
  reset_fixture
  spend_grace 1
  assert_eq "$(delays_taken)" 0 "nothing is delayed before the first read"
  started=$(date +%s)
  tip_read >/dev/null
  elapsed=$(($(date +%s) - started))
  assert_eq "$(delays_taken)" 1 "the first read is held up"
  [ "$elapsed" -ge 1 ] || bail "the delay should be real wall clock (took ${elapsed}s)"
  runs_read 1
  tip_read >/dev/null
  assert_eq "$(delays_taken)" 1 "and no read after it is"
  reset_fixture
  assert_eq "$(delays_taken)" 0 "the delay count is cleared with the rest of the fixture"
}

# Where the move lands: after the round's own tip read, before everything that round does next.
# That window is where a push during a round lands, and it is what every re-confirm in these
# suites is pinned against — the re-confirm must see the successor, not the tip its round opened
# with.
test_at_round_moves_the_tip_inside_the_round_it_names() {
  reset_fixture
  at_round 1 "$SHA_B"
  assert_eq "$(tip_read)" "$SHA_C" "round one opens on the tip it was given"
  runs_read 1
  assert_eq "$(tip_read)" "$SHA_B" "and the re-confirm after that round's reads sees the successor"

  reset_fixture
  at_round 2 "$SHA_B"
  assert_eq "$(tip_read)" "$SHA_C" "a later round's move leaves round one alone"
  runs_read 1
  assert_eq "$(tip_read)" "$SHA_C" "including its re-confirm"
  runs_read 1
  assert_eq "$(tip_read)" "$SHA_B" "and lands inside the round it names"

  reset_fixture
  assert_eq "$(tip_read)" "$SHA_C" "a move is cleared with the rest of the fixture"
}

# Both setters refuse what they cannot mean. `spend_grace 0.5` is the one that would pass for
# honoured: the fixture would sleep a fraction on the platforms whose sleep takes one and refuse
# on the fleet's others, so a case would spend a grace on one box and not on the next.
test_the_wall_clock_setters_refuse_what_they_cannot_mean() {
  local rc
  reset_fixture
  for rc in "spend_grace 0.5" "spend_grace x" "at_round 0 $SHA_B" "at_round x $SHA_B"; do
    set +e
    # shellcheck disable=SC2086 # two words, and they are meant to be two arguments
    (eval $rc) 2>"$TEST_ROOT/refusal"
    [ $? -eq 1 ] || bail "\`$rc\` should be refused"
    set -e
    assert_contains "$(cat "$TEST_ROOT/refusal")" "FAIL: ${rc%% *}:" \
      "the refusal should name the setter that was misused"
  done
  set +e
  (at_round 1) 2>"$TEST_ROOT/refusal"
  [ $? -eq 1 ] || bail "at_round with no sha should be refused"
  set -e
  assert_contains "$(cat "$TEST_ROOT/refusal")" "at_round: no sha" "and say what was missing"
}

# A suite that sources this file without the preamble is refused rather than quietly propped up:
# the preamble is what sources pr-review.sh and installs the shadow guard, and a fixture running
# without that guard is exactly ludics-lite#46's silence.
test_a_suite_that_skips_the_preamble_is_refused() {
  local dir rc out
  test_tmpdir dir base-lib-control
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'source %s\n' "\"$BASE_LIB_DIR/$BASE_LIB_BASENAME\""
  } >"$dir/no-preamble.sh"
  set +e
  out=$(bash "$dir/no-preamble.sh" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" 2 "a refusal is exit 2 ($out)"
  assert_contains "$out" "$BASE_LIB_BASENAME: REFUSING to run: source test-pr-review-lib.sh first" \
    "the refusal should say what is missing, under the name the file goes by"
}

# The reviewer's scenario, from the suite's side: a suite that redefines one of the transport's
# own helpers is refused rather than silently served its own. `reset_fixture` is the one that
# would hurt most — every case opens with it — and before `protect_library` the guard accepted it,
# since the preamble's snapshot was taken before this file was sourced.
test_a_suite_that_shadows_the_transport_is_refused() {
  local dir rc out
  test_tmpdir dir base-lib-shadow
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'source %s\n' "\"$BASE_LIB_DIR/test-pr-review-lib.sh\""
    printf 'source %s\n' "\"$BASE_LIB_DIR/$BASE_LIB_BASENAME\""
    echo 'reset_fixture() { :; }'
    echo 'test_a_case() { assert_eq 1 1 "one is one"; }'
    echo 'run_tests test_a_case'
  } >"$dir/shadow.sh"
  set +e
  out=$(bash "$dir/shadow.sh" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" 2 "a shadow of the transport is a refusal, exit 2 ($out)"
  assert_contains "$out" "$BASE_LIB_BASENAME's reset_fixture ($BASE_LIB_BASENAME:" \
    "the refusal should name this file as the owner, by basename"
  assert_contains "$out" "without \`stub reset_fixture\`" "and name the remedy"
  assert_not_contains "$out" "PASS:" "no case may run under a refusal"
}

tests=(
  test_the_round_counter_counts_rounds_and_not_reads
  test_the_grace_is_spent_once_on_the_first_read
  test_at_round_moves_the_tip_inside_the_round_it_names
  test_the_wall_clock_setters_refuse_what_they_cannot_mean
  test_a_suite_that_skips_the_preamble_is_refused
  test_a_suite_that_shadows_the_transport_is_refused
)

run_tests "${tests[@]}"
exit "$?"
}
