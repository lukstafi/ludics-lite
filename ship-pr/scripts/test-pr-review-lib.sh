#!/usr/bin/env bash
# The preamble the pr-review.sh fixture suites (test-pr-review-*.sh) share. A suite sources it
# right after `set -euo pipefail`, before defining anything of its own:
#
#   SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
#   # shellcheck source=test-pr-review-lib.sh
#   source "$SCRIPT_DIR/test-pr-review-lib.sh"
#
# Sourced, it exports the test environment and sources pr-review.sh in SHIP_PR_TEST_SOURCE_ONLY
# mode, and then provides what every suite used to copy (ludics-lite#46):
#
#   bail <msg>                          the reporter: FAIL: <msg> on stderr, exit 1
#   assert_eq <got> <want> <msg>        the assertion trio
#   assert_contains <hay> <needle> <msg>
#   assert_not_contains <hay> <needle> <msg>
#   test_tmpdir <var> <label>           a throwaway directory in <var> (any name but the two the
#                                       function itself uses, which it refuses), removed at exit —
#                                       this file owns the EXIT trap (pr-review.sh installs one of
#                                       its own when sourced, which the suites used to re-install
#                                       by hand), so a suite never touches `trap`. <label> is
#                                       interpolated into the created directory's NAME, so a case
#                                       that must prove something about a spaced path just asks
#                                       for one — test_the_guard_survives_a_path_with_spaces
#                                       hand-rolled its own mktemp and TEST_CLEANUP entry believing
#                                       it could not ask (ludics-lite#106, undone in #122)
#   gh_fixture_parse "$@"               inside a fixture `gh`: refuses anything but `gh api`, any
#   gh_fixture_answer <response>        option outside gh api's own table (below), and any
#                                       endpoint that is neither `graphql` nor a REST path with a
#                                       `/` (ludics-lite#86, #102); sets FIXTURE_ENDPOINT /
#                                       FIXTURE_FILTER / FIXTURE_PAGINATE,
#                                       logs the endpoint to $REQUEST_LOG (and, when paginated,
#                                       $PAGINATE_LOG) if the suite set them; the answer goes
#                                       through the --jq filter the call carried, if any
#   retune <NAME>=<value>...            moves pr-review.sh's source-time constants (GRACE, STALL,
#                                       ROUND_GAP, ABSENT_GRACE, CHECKS_INTERVAL, …) for the
#   restore_tuning                      current case; run_tests restores them when it ends, and a
#                                       case that wants them back sooner calls restore_tuning
#   stub <fn>...                        declares the library functions this suite redefines on
#                                       purpose (the merge suite's build_checks, run_signal and
#                                       warn_base_drift)
#   BREAK_JQ / jq()                     the shim that makes ONE named jq program fail, so a case
#   with_broken_jq <marker> <cmd>...    can prove a read that did not parse refuses instead of
#                                       rendering a plausible value (ludics-lite#89); three
#                                       suites carried a byte-identical copy (#179). Its scope —
#                                       the marked program and nothing else — is pinned by this
#                                       file's own controls, so a suite needs only the baseline
#                                       its broken runs are measured against
#   protect_library <file>              extends the guard over a second library sourced after
#                                       this one (test-pr-review-base-lib.sh), whose functions
#                                       the snapshot below could not see
#   run_tests <case>...                 the guard below, then each case with a PASS line — and,
#                                       after each case, the refusal of a BREAK_JQ left standing,
#                                       which would break a jq program for every case after it
#
# The guard is why the file exists. pr-review.sh defines some sixty top-level functions, every
# one in scope in every suite the moment it is sourced, and a suite helper that happens to share
# a name silently replaces the library's: a reporter named `fail` turned every refusal of the
# script under test into the reporter's exit 1 (ludics-lite#39, then #45 in three more suites),
# and a collision on `newest` or `age_of` would produce wrong test RESULTS instead, with nothing
# shouting. Shellcheck is silent about it at every severity. So the function table is snapshotted
# here — name, line and defining file for everything pr-review.sh and this file define — and
# `run_tests` reads it again before the first case: a protected function that is no longer the
# one its file defined is REFUSED (exit 2, naming the function, its owner and where the suite
# redefined it) unless the suite declared it with `stub`; and a `stub` that names a function the
# suite never redefined is refused too, so the declarations stay honest. A suite's fixture `gh`
# is outside the guard's scope on purpose: it shadows a command, not a function of the library.
#
# Executed rather than sourced, this file runs its own controls: throwaway suites that source it.
# The tests array below is the register of those controls. The negative controls prove the guard
# can fail; CI runs this file beside the fixture suites.
# `retune` is covered in the same run, by a pair of cases: one moves two constants, the next reads
# them back as pr-review.sh set them, which is the restore no case performs itself.
#
# The mutation controls below automate two recorded regressions: splitting the snapshot path
# into fields, and losing the failed probe status. Each runs only its target case, so there is
# no recursive self-test; an unchanged copy must pass before the mutant fails its named assertion.
# mutation_copy refuses patches that match zero or multiple sites, with its own refusal controls.
#
# To SHOW another guard can fail — which is how a control earns its place here — copy this file and
# pr-review.sh into a scratch directory, revert the fix in the COPY, and run the copy:
#
#   cp ship-pr/scripts/{test-pr-review-lib.sh,pr-review.sh} "$d"/ && mv "$d"/test-pr-review-lib.sh "$d"/lib-reverted.sh
#   $EDITOR "$d"/lib-reverted.sh && bash "$d"/lib-reverted.sh   # the control you added must fail
#
# The tracked file is never touched, so a session that dies mid-way leaves the repo clean; the
# alternative — mutating the tracked file in place and restoring it — does not have that property.
# The copy needs pr-review.sh beside it (TEST_LIB_DIR comes from BASH_SOURCE and HELPER from that)
# and nothing else: any directory will do, and the name of the copy does not matter, because this
# file names itself through LIB_BASENAME rather than spelling it. The last control is what keeps
# that true — it runs a renamed copy for real and holds it to this file's own PASS list, so a name
# spelled instead of derived fails here rather than under whoever next tries the route
# (ludics-lite#101). The PASS list alone would not do it: what a refusal SAYS is checked by the
# controls that provoke it, so `assert_refused` matches "$LIB_BASENAME: REFUSING" rather than the
# bare word, and the renamed inner run is where a re-spelled prefix then fails. `--inner-copy`,
# which that control passes, is the only argument this file takes — exactly, with no trailing
# word, since a marker that could be typed past would skip that control in silence.

TEST_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
TEST_LIB_FILE="$TEST_LIB_DIR/$(basename "${BASH_SOURCE[0]}")"
HELPER="$TEST_LIB_DIR/pr-review.sh"
# How this file names ITSELF, everywhere below: derived, never spelled. A copy is how a guard is
# shown to fail without touching the tracked file (see the executed section's copy control), and a
# copy is named something else — so every message and every assertion that spells the canonical
# name is a false failure waiting for whoever tries that route. One did: run as `lib-reverted.sh`,
# `test_lib_helpers_are_protected` asserted on a literal "test-pr-review-lib.sh's assert_eq" while
# the guard correctly reported `lib-reverted.sh's assert_eq`, and the case failed for a reason
# with nothing to do with the mutation under test. pr-review.sh keeps its literal name, in prose
# and in HELPER both: a copy has to sit beside a file of exactly that name to run at all.
LIB_BASENAME=$(basename "$TEST_LIB_FILE")

# Everything a suite defines must come AFTER this file: a function defined before pr-review.sh
# is sourced is replaced by the library's same-named one (the shadow in the other direction),
# and the snapshot below could not tell.
# `declare -f <name>` for an ordinary function, `declare -fx <name>` for one the ENVIRONMENT
# exported into this shell (`export -f`). Only the former is the suite's doing, so only the former
# is matched — printing just the matches, and not every line with a prefix stripped where it
# happened to occur. An inherited function is not something a suite can be asked to move below the
# source, and it is harmless besides: a library name among them is replaced when pr-review.sh is
# sourced a few lines down, and the snapshot then records the library's. Before this, any exported
# function in the environment refused every suite, naming "declare -fx <name>" as the definition.
lib_predefined=$(declare -F | sed -n 's/^declare -f \(.*\)/\1/p' | tr '\n' ' ')
if [ -n "$lib_predefined" ]; then
  echo "$LIB_BASENAME: REFUSING to run: the suite defined functions before sourcing this file (${lib_predefined% }); source it first, so the shadow guard sees every definition" >&2
  exit 2
fi
unset lib_predefined

export SHIP_PR_TEST_SOURCE_ONLY=1
export SHIP_PR_API_ATTEMPTS=1
export SHIP_PR_API_BACKOFF=0
# The set `retune` accepts: the names sourcing pr-review.sh ASSIGNS, asked of a probe that does
# exactly that in a pristine environment, where the names in scope before and after the source
# differ by precisely what the source set. Two cheaper answers were both wrong, in opposite ways.
#
# Differencing the names across THIS shell's source depends on who invoked the suite: a name the
# environment already carries — `env GRACE=777 ./test-pr-review-lib.sh`, or an exported
# `ABSENT_GRACE` — is in scope on both sides, so it read as the caller's, dropped out of the set,
# and every migrated `retune GRACE=1` was refused with "sets no GRACE".
#
# Reading the assignments out of pr-review.sh's TEXT is invoker-independent but cannot tell a
# source-time assignment from one inside a function body, and "is it set now" cannot separate them
# either for a name the shell itself always provides: `IFS=… read` appears in several of its
# functions and every shell has IFS set, so `retune IFS=x` was accepted and would have altered the
# harness's own word splitting — a typo guard that admits IFS is not a guard.
#
# The probe answers the question that was being approximated. `env -i` so nothing is inherited;
# PATH, HOME and TMPDIR because the source reads them; the same SHIP_PR_* the suites source under.
# Function bodies do not run, so their locals never appear. It is written inline rather than as a
# helper because a function defined before the source is the one shape this file refuses from a
# suite: pr-review.sh would replace a same-named one, and the snapshot could not tell.
#
# The shell creates variables of its own as it runs, and those are not the script's constants.
# `PIPESTATUS` is the one that reached the set: absent from the first snapshot, materialized by
# bash when the source ran a top-level pipeline, and so indistinguishable by name alone from
# something pr-review.sh assigned — `retune PIPESTATUS=x` was accepted, and did nothing. Both
# halves below are against that: the WARM-UP runs the constructs that materialize such variables
# before the first snapshot, so they are on the "before" side where they belong; the deny-list
# catches the ones no warm-up here triggers, and the two overlap on purpose, because a new bash
# maintaining one more name should be caught by the warm-up without anyone editing a list.
#
# The status is captured rather than propagated. `set -e` is on in every suite by the time this
# runs, so a probe that failed took the assignment's exit status with it and killed the suite
# where it stood — before the refusal below could say what happened, and with the source's own
# stderr discarded. The `|| lib_probe_rc=$?` is what lets the diagnostic run at all.
lib_probe_err="${TMPDIR:-/tmp}/pr-review-probe.$$.err"
lib_probe_rc=0
HELPER_CONSTANTS=" $(
  env -i "PATH=$PATH" "HOME=${HOME:-}" "TMPDIR=${TMPDIR:-/tmp}" \
    SHIP_PR_TEST_SOURCE_ONLY=1 \
    bash -c '
      # The warm-up: a pipeline for PIPESTATUS, a regex match for BASH_REMATCH, a read for REPLY.
      : | : >/dev/null
      [[ x =~ x ]] || :
      printf "%s\n" x | { read -r _ignored || :; }
      before=" $(compgen -v | tr "\n" " ")before n "
      . "$1" >/dev/null || exit 1
      for n in $(compgen -v); do
        case "$before" in *" $n "*) continue ;; esac
        # The names bash maintains, which a script does not assign and retune must not accept.
        case " BASH_ARGC BASH_ARGV BASH_ARGV0 BASH_COMMAND BASH_LINENO BASH_REMATCH BASH_SOURCE \
BASH_SUBSHELL COMP_CWORD COMP_KEY COMP_LINE COMP_POINT COMP_TYPE COMP_WORDBREAKS COMP_WORDS \
EPOCHREALTIME EPOCHSECONDS FUNCNAME GROUPS LINENO OPTARG OPTIND PIPESTATUS RANDOM REPLY SECONDS \
SRANDOM " in *" $n "*) continue ;; esac
        printf "%s " "$n"
      done
    ' _ "$HELPER" 2>"$lib_probe_err"
)" || lib_probe_rc=$?

# A probe that failed or answered nothing is a broken setup, not a script with no constants:
# retune would otherwise refuse every name and each suite would fail somewhere in its middle with
# "sets no GRACE" rather than here, where the reason is.
case "$lib_probe_rc$HELPER_CONSTANTS" in
0*[![:space:]]*) rm -f "$lib_probe_err" ;;
*)
  echo "$LIB_BASENAME: REFUSING to run: the probe that reads pr-review.sh's source-time constants exited $lib_probe_rc and named $(printf '%s' "$HELPER_CONSTANTS" | wc -w | tr -d ' ') constant(s), so \`retune\` could accept no name. What the source said:" >&2
  sed 's/^/  /' "$lib_probe_err" >&2 || :
  rm -f "$lib_probe_err"
  exit 2
  ;;
esac
unset lib_probe_err lib_probe_rc

# shellcheck source=pr-review.sh
source "$HELPER"

# What sourcing pr-review.sh installed on EXIT, read HERE because this file installs a trap of its
# own a few lines down and a trap is REPLACED, not chained: after that line the script's own is
# gone and unrecoverable. The guard under the snapshot holds this file's trap to it
# (ludics-lite#195).
LIB_HELPER_EXIT_TRAP=$(trap -p EXIT)

# --- the reporter and the assertions ----------------------------------------------------------
# Not `fail`: that is pr-review.sh's, and its refusals' exit codes are what the suites read.
bail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || bail "$3 (got '$1', expected '$2')"
}

assert_contains() {
  case "$1" in *"$2"*) ;; *) bail "$3 (missing '$2' in: $1)" ;; esac
}

assert_not_contains() {
  case "$1" in *"$2"*) bail "$3 (unexpected '$2' in: $1)" ;; *) ;; esac
}

# --- temporary paths and the one EXIT trap ----------------------------------------------------
# Sourcing pr-review.sh installed an EXIT trap, and this one REPLACES it — a trap is not chained.
# So this trap does both jobs, and the suite registers its scratch space through test_tmpdir
# instead of installing a trap of its own. Only paths mktemp created are ever removed.
TEST_CLEANUP=()
test_cleanup() {
  # pr-review.sh's cleanup, CALLED rather than restated: it removes GH_ERR_FILE and the snapshot
  # directory a sourced watch made, and what it removes changes. The restatement this line
  # replaced is how #191's snapshot directory leaked into the real TMPDIR from every suite run,
  # green throughout, until the copy was updated by hand (ludics-lite#195). The guard under the
  # function-table snapshot refuses the suites if this call goes away.
  pr_review_cleanup
  local p
  # bash 3.2 under `set -u` rejects "${TEST_CLEANUP[@]}" while it is empty.
  [ "${#TEST_CLEANUP[@]}" -eq 0 ] || for p in "${TEST_CLEANUP[@]}"; do rm -rf "$p"; done
}
trap test_cleanup EXIT

# test_tmpdir <var> <label>: a fresh directory under TMPDIR, its path in <var>. A function, not a
# `$(...)`, because the registration must reach this shell, and a command substitution's does not.
#
# Its own names are namespaced, because <var> is the caller's word and `printf -v` writes to
# whatever is in scope: a suite that asked for the obvious `dir` used to have the path land on the
# then-local of that name and never reach the suite, leaving an unbound variable one line later
# under `set -u`, or — worse, with a prior value — a stale path while the fresh directory sat
# registered in TEST_CLEANUP (ludics-lite#79). The two names it still cannot get out of the way of
# are refused instead of written past: its own local, and TEST_CLEANUP, which `printf -v` would
# overwrite as the array's first element and so drop every path already registered for removal.
# Refusing, rather than quietly renaming, is the register the preamble's own guards use.
test_tmpdir() {
  local __test_tmpdir_path
  case "$1" in
  __test_tmpdir_path | TEST_CLEANUP)
    bail "test_tmpdir: refusing to write the path into \$$1 — test_tmpdir uses that name itself; name the variable something else"
    ;;
  esac
  # `pr-review-test.<pid>.<label>.XXXXXX`, not `pr-review-<label>.XXXXXX`: the label alone names
  # no owner, so a directory a killed suite left behind was uncollectable by construction — the
  # `pr-review-cwd-checkout.VLoj1M` that sat in this box's TMPDIR from 09-10 is one, and it is
  # what put test_tmpdir in ludics-lite#219 alongside pr-review.sh's own temporaries. With the pid
  # in it, pr-review.sh's tmp_sweep_stale collects it on the same owner-gone test as everything
  # else. The label stays in the name, after the pid, because it is what makes a leftover
  # identifiable at a glance, and it may carry a space (`lib space`), which the quoting here and
  # the sweep's own quoting both survive.
  __test_tmpdir_path=$(mktemp -d "${TMPDIR:-/tmp}/pr-review-test.$$.$2.XXXXXX") || bail "mktemp -d failed for $2"
  # Physically resolved before anyone sees it, and here rather than in each suite: on macOS
  # $TMPDIR sits under /var, a symlink to /private/var, while pr-review.sh computes its own
  # paths with `pwd -P`. Unresolved, the two spellings of one directory differ, so a suite's
  # comparison against a $scratch path silently stops matching -- and the "must NOT appear"
  # half then passes over anything at all (ludics-lite#208).
  #
  # `CDPATH= cd`, not a bare `cd`: with CDPATH exported and a RELATIVE $TMPDIR, a successful `cd`
  # PRINTS the directory it chose, and the substitution then captures two lines while still
  # exiting zero -- a scratch path that does not exist, written into every case below. The
  # assignment prefix is temporary, `cd` being a regular builtin.
  __test_tmpdir_path=$(CDPATH= cd "$__test_tmpdir_path" && pwd -P) || bail "cannot resolve the scratch directory for $2"
  TEST_CLEANUP+=("$__test_tmpdir_path")
  printf -v "$1" '%s' "$__test_tmpdir_path"
}

# --- the fixture gh's argument parsing --------------------------------------------------------
FIXTURE_ENDPOINT=""
FIXTURE_FILTER=""
FIXTURE_PAGINATE=""

# gh api's OPTION TABLE, as of gh 2.99.0: every option the command accepts AS PART OF A REQUEST,
# split by whether it carries a value, each spelling its own entry and surrounded by spaces so a
# lookup is exact. `--help` is deliberately in neither list — it is an action, not an option, and
# is refused below.
#
# Two lists preceded this one and each was a guess about the options NOT named. #86 listed the
# value-taking options and let anything else stand alone, so a value-taking option it had missed
# put its value in the endpoint slot: `--input fixtures/body.json` even looks like a REST path,
# which is why a check of the slot's shape did not catch it (ludics-lite#102, round 1). Inverting
# it — list the booleans, assume everything else carries a value — moved the silence rather than
# ending it: an unknown boolean AFTER the endpoint left the endpoint intact and swallowed the
# NEXT option, so `repos/o/n/thing --future-boolean --jq .a` parsed with no filter and the
# fixture answered the raw body (round 2). Both guesses fail the same way, quietly, one gh
# release after they were written.
#
# So the fixture is exhaustive instead, and refuses what it has not been told: an option in
# neither list is a `bail` naming it. That is the right failure for a fixture — the calls it sees
# are the ones pr-review.sh makes, so an unknown option means the library grew a call this file
# has yet to learn, and one line here teaches it. A refusal is also the answer to a form the
# table cannot express (a boolean with an inline value, a bundled short): loud and unparsed beats
# parsed wrong, which is the whole lesson of the two lists above.
FIXTURE_GH_BOOLS=" -i --include --paginate --silent --slurp --verbose --allow-escape-sequences "
FIXTURE_GH_VALUED=" -X --method -f --raw-field -F --field -H --header -q --jq -t --template -p --preview --cache --hostname --input "

gh_fixture_parse() {
  local arg name value inline positional opts_ended="" positionals=0 call="$*"
  FIXTURE_ENDPOINT=""
  FIXTURE_FILTER=""
  FIXTURE_PAGINATE=""
  [ "${1:-}" = api ] || bail "fixture received non-api gh call: $*"
  shift
  while [ $# -gt 0 ]; do
    arg="$1"
    shift
    positional=""
    if [ -n "$opts_ended" ]; then
      positional=1
    else
      # Split the option's NAME from an inline value, in each of pflag's spellings: `--name=v`,
      # `-x=v`, and the attached short `-xv`. `--` ends option parsing, and everything after it is
      # positional however much it looks like an option; a lone `-` is the endpoint (gh reads a
      # body from stdin, not an option).
      case "$arg" in
      --) opts_ended=1 && continue ;;
      --*=*)
        name="${arg%%=*}"
        value="${arg#*=}"
        inline=1
        ;;
      --?*)
        name="$arg"
        value=""
        inline=""
        ;;
      -?=*)
        name="${arg%%=*}"
        value="${arg#*=}"
        inline=1
        ;;
      -?)
        name="$arg"
        value=""
        inline=""
        ;;
      -??*)
        name="${arg:0:2}"
        value="${arg:2}"
        inline=1
        ;;
      *) positional=1 ;;
      esac
    fi
    if [ -n "$positional" ]; then
      # `gh api <endpoint> [flags]` takes exactly ONE positional. A second is a call the CLI
      # would have refused outright, so a fixture that answered it would be answering a request
      # production cannot send — which a test could then pass against (ludics-lite#102, round 3;
      # round 2's own control had enshrined `api -- repos/o/n/thing --paginate` as valid).
      positionals=$((positionals + 1))
      [ "$positionals" -eq 1 ] ||
        bail "fixture received $positionals positional arguments in: gh $call — gh api takes exactly one, the endpoint; the real CLI answers 'accepts 1 arg(s), received $positionals' and makes no request"
      FIXTURE_ENDPOINT="$arg"
      continue
    fi
    # `--help` is a terminal ACTION, not part of a request: gh prints the help, exits 0 and calls
    # nothing, whichever side of the endpoint it sits on. It is kept out of the boolean list and
    # refused by name, so a library call that grew one by accident cannot find a fixture willing
    # to answer it (round 3).
    [ "$name" != --help ] ||
      bail "fixture received --help in: gh $call — gh api would have printed its help and made no request, so no answer here could be the right one"
    case "$FIXTURE_GH_BOOLS" in
    *" $name "*)
      # An inline value on a boolean is either pflag's `--bool=false` or a bundle of shorts, and
      # the table can express neither. Refuse it rather than pick a reading.
      [ -z "$inline" ] ||
        bail "fixture cannot parse '$arg' in: gh $call — $name takes no value, so this is either a boolean written as '$name=$value' or short options bundled as one word; write them apart"
      [ "$name" != --paginate ] || FIXTURE_PAGINATE=1
      continue
      ;;
    esac
    case "$FIXTURE_GH_VALUED" in
    *" $name "*) ;;
    *) bail "fixture does not know the gh api option $name in: gh $call — add it to FIXTURE_GH_BOOLS or FIXTURE_GH_VALUED, whichever it is; guessing is what put an option's value in the endpoint slot twice (ludics-lite#86, #102)" ;;
    esac
    if [ -z "$inline" ]; then
      value="${1:-}"
      shift || true
    fi
    case "$name" in
    --jq | -q) FIXTURE_FILTER="$value" ;;
    esac
  done
  # The endpoint's SHAPE, the last thing between a mis-parse and a fixture dispatching on it.
  # Every endpoint pr-review.sh addresses is `graphql` or a REST path, so anything else is a word
  # the caller never wrote as one — a `POST` the table failed to consume, or no endpoint at all —
  # and answering it would mean answering the wrong branch, which is the failure that PASSES.
  case "$FIXTURE_ENDPOINT" in
  graphql | */*) ;;
  *) bail "fixture parsed '$FIXTURE_ENDPOINT' as the endpoint of: gh $call — an endpoint is 'graphql' or a REST path carrying a '/'" ;;
  esac
  [ -z "${REQUEST_LOG:-}" ] || printf '%s\n' "$FIXTURE_ENDPOINT" >>"$REQUEST_LOG"
  [ -z "$FIXTURE_PAGINATE" ] || [ -z "${PAGINATE_LOG:-}" ] ||
    printf '%s\n' "$FIXTURE_ENDPOINT" >>"$PAGINATE_LOG"
}

gh_fixture_answer() {
  if [ -n "$FIXTURE_FILTER" ]; then
    jq -r "$FIXTURE_FILTER" <<<"$1"
  else
    printf '%s\n' "$1"
  fi
}

# --- breaking ONE jq program on purpose (ludics-lite#89, #179) --------------------------------
# Every jq program pr-review.sh runs is a literal inside the tracked script, so the way to make
# one of them — and only that one — fail is to shim `jq` itself: the shim refuses exactly the
# invocation whose command line carries the marker (nonzero status, nothing on stdout, which is
# what a rebinding error or a typo'd `$var` produces) and forwards every other call to the real
# jq through `command jq`, so it never calls itself. Like a suite's fixture `gh` it shadows a
# COMMAND rather than a library function — but it is defined HERE, above the snapshot, so it is a
# protected name like any other: a suite that wants its own jq declares `stub jq` and says why.
#
# Three suites carried a byte-identical copy of this (rounds, status, watch), each with its own
# "a marker no program carries" control to prove the shim breaks only what it is pointed at
# (ludics-lite#179). That claim is about the shim and not about any one suite's fixture, so it is
# pinned once, by this file's own controls below; a suite keeps only the baseline reading its
# broken-program cases are measured against, which it gets from an ordinary run with no marker
# set.
#
# The marker is matched against EVERY argument, not just the program text, because a program can
# be assembled from `--arg`s and because a filter is an argument too. That reach is the one thing
# to hold still when choosing a marker: `gh_fixture_answer` runs the suite's own `--jq` filter
# through this same shim, so a marker that also matches the fixture's filter breaks the fixture's
# ANSWER rather than the script's read of it, and the case then passes for the wrong reason. Pick
# a fragment that appears in exactly one program, and pick it out of pr-review.sh.
BREAK_JQ=""
jq() {
  local arg
  if [ -n "$BREAK_JQ" ]; then
    for arg in "$@"; do
      case "$arg" in
      *"$BREAK_JQ"*)
        echo "jq: error: \$broken is not defined at <top-level>" >&2
        return 3
        ;;
      esac
    done
  fi
  command jq "$@"
}

# with_broken_jq <marker> <command> [arg...]: run <command> with the marker standing, and clear it
# again whichever way the command goes. Set and cleared by hand — the three suites' idiom — the
# clearing line is skipped by any command that fails under `set -e`, and a marker left standing is
# not a failure but a WRONG RESULT: every later case in the suite runs with one of the script's
# programs broken. The status is the command's own, so a caller can still read it; `|| rc=$?`
# also means the command runs with `set -e` suspended, which is what the cases that drive a
# failing round used to write as a `set +e` / `set -e` pair around the call.
#
# Going through the helper is not left to discipline: `run_tests` refuses a case that ends with
# the marker still set, naming it, so the hand-rolled pair fails the case that wrote it instead
# of the cases after it silently passing on broken reads.
with_broken_jq() {
  local marker="$1" rc=0
  shift
  [ $# -gt 0 ] || bail "with_broken_jq: no command named"
  BREAK_JQ="$marker"
  "$@" || rc=$?
  BREAK_JQ=""
  return "$rc"
}

# --- retuning pr-review.sh's source-time constants --------------------------------------------
# GRACE, STALL, ROUND_GAP, ABSENT_GRACE, CHECKS_INTERVAL and the rest are read from the
# environment ONCE, when pr-review.sh is sourced. So `SHIP_PR_REVIEW_GRACE=1 run_watch ...` reaches
# nothing in a suite that sourced the script minutes earlier: a case that needs a different clock
# has to assign the constant itself. Done by hand that is a save, an assignment and a restore per
# case (the `grace_was` triple the watch suite carried six times over), and the restore is the part
# that gets forgotten — a constant left retuned leaks into every case after it, which is a wrong
# RESULT, not a failure. `retune` remembers the value as sourced and `run_tests` puts it back when
# the case ends, so no case has to.
TUNED_SAVED=()

# retune <NAME>=<value>...: move constants for the current case. A name pr-review.sh does not set
# when it is sourced is a typo — assigning it would invent a variable the script never reads, and
# the case would pass while proving nothing — so it is refused.
retune() {
  local assignment name
  [ $# -gt 0 ] || bail "retune: no constant named"
  for assignment in "$@"; do
    case "$assignment" in
    [A-Za-z_]*=*) ;;
    *) bail "retune: '$assignment' is not a NAME=value assignment" ;;
    esac
    name=${assignment%%=*}
    case "$HELPER_CONSTANTS" in
    *" $name "*) ;;
    *) bail "retune $name: pr-review.sh sets no $name when it is sourced — nothing to retune" ;;
    esac
    # Only the FIRST retune of a name is saved, so a case that moves one constant twice is still
    # restored to the value pr-review.sh gave it, not to the intermediate.
    case " $(lib_tuned_names) " in
    *" $name "*) ;;
    *) TUNED_SAVED+=("$name=${!name-}") ;;
    esac
    printf -v "$name" '%s' "${assignment#*=}"
  done
}

lib_tuned_names() {
  local assignment
  [ "${#TUNED_SAVED[@]}" -eq 0 ] || for assignment in "${TUNED_SAVED[@]}"; do
    printf '%s ' "${assignment%%=*}"
  done
}

# restore_tuning: every retuned constant back to the value it was sourced with. run_tests calls it
# after each case; a case that wants the constants back before its own assertions may call it too.
restore_tuning() {
  local assignment
  [ "${#TUNED_SAVED[@]}" -eq 0 ] || for assignment in "${TUNED_SAVED[@]}"; do
    printf -v "${assignment%%=*}" '%s' "${assignment#*=}"
  done
  TUNED_SAVED=()
}

# --- the stub declarations and the shadow guard -----------------------------------------------
# `declare -F <names>` under extdebug prints "<name> <line> <file>" per function; the option is
# set in a subshell so its debugger side effects (function and error tracing) touch nothing else.
lib_function_table() {
  local names
  names=$(declare -F | sed 's/^declare -f //')
  # shellcheck disable=SC2086 # the names are one word each, and the point is to split them
  (shopt -s extdebug && declare -F $names) || true
}

# lib_owner_of <name> <table>: the "<line> <file>" the table records for <name>, empty if none.
#
# A here-string, not `printf … | awk`: awk stops at the first match, and a reader that exits early
# closes the pipe under the writer. The writer then takes a SIGPIPE, `set -o pipefail` — which
# every suite runs under — makes that the pipeline's status, and the caller's `$(…)` assignment
# fails under `set -e`. It is a race on whether the table still fits the pipe buffer when awk
# leaves, so it fires once in many runs and reproduces nowhere: main went red on 2026-09-10 with
# `line 418: printf: write error: Broken pipe` out of test_own_functions_pass, a case that touches
# none of this. A here-string is fed from a temporary file rather than a pipe, so there is no
# reader to close and nothing to signal. Same output, same status, in all three cases the callers
# rely on — a match at either end of the table, and no match at all. This is ludics-lite#118's
# shape (`printf … | grep -q`) in the preamble that issue holds up as the model for the fix.
lib_owner_of() {
  awk -v n="$1" '$1 == n { sub(/^[^ ]+ /, ""); print; exit }' <<<"$2"
}

# The names below this point are not protected: the snapshot is taken once everything this file
# defines exists, at the end of the sourced part.
STUBS=""

# stub <fn>...: the suite redefines these on purpose. A name the library lacks is a typo, and a
# declaration never honoured is refused by the guard.
stub() {
  local fn
  [ $# -gt 0 ] || bail "stub: no function named"
  for fn in "$@"; do
    [ -n "$(lib_owner_of "$fn" "$LIB_SNAPSHOT")" ] ||
      bail "stub $fn: neither pr-review.sh nor $LIB_BASENAME defines $fn — nothing to stub"
    STUBS="$STUBS $fn "
  done
}

lib_declared_stub() { case "$STUBS" in *" $1 "*) ;; *) return 1 ;; esac; }

# The files whose functions are protected, one per line — pr-review.sh and this file to begin
# with, and whatever `protect_library` adds. Newline-separated rather than space-separated
# because a checkout's path can contain spaces, which is a shape this file's own controls run in.
LIB_PROTECTED_FILES="$HELPER
$TEST_LIB_FILE"

# A path as the suite's reader would write it: a protected library file by basename, the suite as
# it was invoked (which is what `declare -F` records).
lib_show_file() {
  case "
$LIB_PROTECTED_FILES
" in
  *"
$1
"*) basename "$1" ;;
  *) printf '%s' "$1" ;;
  esac
}

check_shadows() {
  local table name owner now file line owner_file owner_line problems=""
  table=$(lib_function_table)
  while read -r name owner_line owner_file; do
    [ -n "$name" ] || continue
    now=$(lib_owner_of "$name" "$table")
    if [ "$now" = "$owner_line $owner_file" ]; then
      ! lib_declared_stub "$name" ||
        problems="$problems
  - stub $name is declared, but $name is still $(lib_show_file "$owner_file")'s: drop the declaration or define the stub"
      continue
    fi
    lib_declared_stub "$name" && continue
    line=${now%% *}
    file=${now#* }
    problems="$problems
  - $(lib_show_file "$owner_file")'s $name ($(lib_show_file "$owner_file"):$owner_line) is redefined at $(lib_show_file "$file"):$line without \`stub $name\`"
  done <<<"$LIB_SNAPSHOT"
  [ -z "$problems" ] || {
    echo "$LIB_BASENAME: REFUSING to run the cases: a suite function replaces a library function it did not declare (ludics-lite#46) — a same-named helper silently takes over every call the library makes (a reporter named \`fail\` turns each refusal's exit code into 1); declare a deliberate override with \`stub <fn>\`, else rename the suite's function:$problems" >&2
    exit 2
  }
}

# run_tests <case>...: the guard, then the cases in order, each announced on stdout. A case's
# retuned constants are put back before the next one starts, whether or not it restored them.
#
# A marker left standing is the other leak between cases, and the one nothing can put back: the
# constants have a value as sourced to restore to, but a broken jq program is a claim about the
# case that set it, and a case that ends with BREAK_JQ set has already told every case after it
# to run with one of the script's programs refusing — each of them still reporting PASS, since
# what a broken read costs is a wrong RESULT and not a failure. `with_broken_jq` clears the
# marker whichever way its command goes, so a case that goes through it never trips this; what
# trips it is the hand-rolled set/clear pair the helper replaced, whose clearing line is skipped
# by any command that fails under `set -e`. So it is refused rather than silently restored: the
# case that leaked is named, and the cases after it do not run under it.
run_tests() {
  local test_name
  check_shadows
  [ $# -gt 0 ] || bail "run_tests: no cases named"
  for test_name in "$@"; do
    "$test_name"
    [ -z "$BREAK_JQ" ] || bail "$test_name left BREAK_JQ set to '$BREAK_JQ': every case after it would run with the jq programs matching that marker refusing, and report PASS anyway — break a program with \`with_broken_jq $BREAK_JQ <command>...\`, which clears the marker whichever way the command goes"
    restore_tuning
    echo "PASS: $test_name"
  done
}

# protect_library <file>: extend the guard over a SECOND library, sourced after this one — the
# base suites' shared fixture transport is the first (ludics-lite#179). The snapshot below is
# taken while this file is being sourced, so everything a later library defines is outside it, and
# a suite redefining one of those names was accepted in silence: the three suites over
# test-pr-review-base-lib.sh share `gh`, `reset_fixture`, `run_base` and the wall-clock setters,
# and a suite helper colliding with one of them replaces it for every call the transport makes —
# which is ludics-lite#46 exactly, one library further out (review of #212, round 1).
#
# <file> is the path as the shell records it, which is `${BASH_SOURCE[0]}` inside the library
# itself: `declare -F` prints the path the file was sourced through, and a resolved one would
# match nothing. A file that defines no function is refused rather than protecting nothing —
# an empty extension is the same silent pass as no extension at all.
protect_library() {
  local file="$1" added
  [ -n "$file" ] || bail "protect_library: no file named"
  added=$(lib_function_table |
    awk -v f="$file" '{ path = $0; sub(/^[^ ]+ [^ ]+ /, "", path); if (path == f) print }')
  case "$added" in
  *[![:space:]]*) ;;
  *) bail "protect_library: $file defines no function in this shell — name the file as \`\${BASH_SOURCE[0]}\` from inside it, after its definitions" ;;
  esac
  LIB_SNAPSHOT="$LIB_SNAPSHOT
$added"
  LIB_PROTECTED_FILES="$LIB_PROTECTED_FILES
$file"
}

# --- the second guard: this file's EXIT trap must still reach pr-review.sh's ------------------
# Sourcing pr-review.sh installs an EXIT trap; this file installs its own over it, and that is a
# REPLACEMENT — a trap is not chained. So the script's cleanup runs in a suite only if this file's
# trap calls it. It used to RESTATE it instead, as did pr-review-api-contract.sh, and the copies
# drifted: ludics-lite#191 added a snapshot directory to the script's trap alone, and from then on
# every suite run leaked one into the real TMPDIR while every suite and CI stayed green, because
# the only artifact of the failure is a directory nobody looks at (ludics-lite#195). The
# restatements are gone — both traps call `pr_review_cleanup` — and this is what keeps them gone.
#
# What is checked is reachability by NAME, in the same register as the shadow guard below: the
# script's trap must BE a function the script defines, this file's trap must be a function this
# file defines, and the script's name must appear in its body. A body-text check cannot prove the
# call runs, but it fails the moment the call is deleted or the function renamed on one side only,
# which is every way the copies drifted.
lib_trap_command() { # <`trap -p` output>: the command it installs, unquoted; empty if none
  local cmd="$1"
  cmd=${cmd#trap -- }
  cmd=${cmd% EXIT}
  case "$cmd" in
  "'"*"'")
    cmd=${cmd#\'}
    cmd=${cmd%\'}
    ;;
  esac
  printf '%s' "$cmd"
}

lib_refuse_trap() {
  echo "$LIB_BASENAME: REFUSING to run: $1 — sourcing pr-review.sh installs an EXIT trap and this file installs its own over it, REPLACING it, so pr-review.sh's cleanup runs in a suite only if this file's trap calls it by name. Restating what it does instead is how ludics-lite#191's snapshot directory leaked from every suite run in silence (ludics-lite#195)." >&2
  exit 2
}

lib_helper_trap_fn=$(lib_trap_command "$LIB_HELPER_EXIT_TRAP")
lib_own_trap_fn=$(lib_trap_command "$(trap -p EXIT)")
lib_trap_table=$(lib_function_table)
case "$lib_helper_trap_fn" in
'') lib_refuse_trap "sourcing pr-review.sh installed no EXIT trap at all, so there is nothing for this file's trap to call and the guard would check nothing" ;;
*[!A-Za-z0-9_]*) lib_refuse_trap "pr-review.sh's EXIT trap is \`$lib_helper_trap_fn\`, a command rather than a call to a named function: give it one (\`pr_review_cleanup\`) and trap that, so this file can call it" ;;
esac
case "$(lib_owner_of "$lib_helper_trap_fn" "$lib_trap_table")" in
*"$HELPER") ;;
*) lib_refuse_trap "pr-review.sh's EXIT trap names \`$lib_helper_trap_fn\`, which pr-review.sh does not define" ;;
esac
[ -n "$(lib_owner_of "$lib_own_trap_fn" "$lib_trap_table")" ] ||
  lib_refuse_trap "this file's EXIT trap is \`$lib_own_trap_fn\`, not a call to a function it defines"
case "
$(declare -f "$lib_own_trap_fn")
" in
*[!A-Za-z0-9_]"$lib_helper_trap_fn"[!A-Za-z0-9_]*) ;;
*) lib_refuse_trap "this file's EXIT trap (\`$lib_own_trap_fn\`) never calls \`$lib_helper_trap_fn\`, the function pr-review.sh's own trap runs" ;;
esac
unset lib_helper_trap_fn lib_own_trap_fn lib_trap_table

# What is PROTECTED is what these two files define, and only that — the table is filtered on the
# defining file rather than taken whole. A function the environment exported in (`export -f`) is
# in scope here too, and bash records it with no file at all; recorded as library-owned, it made a
# suite's own fixture `gh` read as a redefinition of it and refused the suite ("(null)'s gh
# ((null):0) is redefined at …"). An inherited function is not the library's, and a suite is free
# to define one of any name — which is the same ground the fixture `gh` has always stood on.
# Only the snapshot is filtered: `check_shadows` reads the CURRENT table unfiltered, because the
# file it reports a redefinition from is the suite's own.
#
# The path is the INTACT remainder of the record, not a field: `declare -F` prints "<name> <line>
# <file>", and a checkout under a path with a space in it — `/tmp/ludics review.XXXX`, which is
# what a scratch clone looks like — splits that file across awk's fields. Comparing `$3` then
# matched nothing, the snapshot came out EMPTY, and an empty snapshot does not fail: it protects
# no function at all, so every shadow is accepted and the file's own first control passes a
# deliberate `fail` through. Hence the check under it, which is the same guard the constants probe
# carries: this file's whole purpose is a refusal, and a refusal that quietly has nothing to say
# is the failure mode it was written against.
LIB_SNAPSHOT=$(lib_function_table |
  awk -v h="$HELPER" -v t="$TEST_LIB_FILE" '{
    path = $0
    sub(/^[^ ]+ [^ ]+ /, "", path)
    if (path == h || path == t) print
  }')
case "$LIB_SNAPSHOT" in
*[![:space:]]*) ;;
*)
  echo "$LIB_BASENAME: REFUSING to run: the function-table snapshot named nothing, so the shadow guard would protect no function and every ludics-lite#46 shadow would be accepted silently; pr-review.sh ($HELPER) and this file should between them define some sixty" >&2
  exit 2
  ;;
esac

# --- executed: this file's own controls -------------------------------------------------------
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -euo pipefail

# The copy control at the end runs this very file again, from a renamed copy. That inner run must
# not copy itself a third time, and the marker that stops it is an ARGUMENT rather than an
# exported variable on purpose: an argument cannot arrive from an ambient environment, so no stray
# `export` in a caller's shell can delete the control from an ordinary run and leave the file
# reporting a PASS for a case that did nothing. Anything else on the command line is a typo, and
# a typo that ran the whole suite anyway would look like the flag had been honoured.
#
# The COUNT is part of the match, not just the first word. Reading `$1` alone accepted
# `--inner-copy typo`: the trailing word was ignored, the copy control skipped itself, and the run
# reported all 19 PASS lines — the whole suite green with the one control it was told to refuse
# silently missing, which is the failure this parser exists to prevent.
LIB_INNER_RUN=""
case "$#:${1:-}" in
"0:") ;;
"1:--inner-copy") LIB_INNER_RUN=1 ;;
*)
  echo "$LIB_BASENAME: REFUSING to run: expected no arguments, or exactly \`--inner-copy\` (which this file passes to a copy of itself); got $# argument(s): $*" >&2
  exit 2
  ;;
esac

test_tmpdir CONTROL_ROOT lib-test
CONTROL_N=0

# control <body...>: a throwaway suite that sources this file and runs a passing case, with the
# given lines in between. Its exit code, stdout and stderr land in CONTROL_RC / _OUT / _ERR, and
# the suite it wrote in CONTROL_FILE.
control() {
  control_in "$CONTROL_ROOT" "$@"
}

# control_in <dir> <body...>: `control`, with the throwaway suite written in <dir> instead of
# beside the others. It sources the preamble copy in <dir> when the caller has put one there —
# and so runs against whatever pr-review.sh sits beside THAT copy, which is what a control over
# the source itself needs — and this file where it lives when <dir> holds no copy, which is the
# plain `control` above. A control wanting a directory of its own makes one with `test_tmpdir`,
# whose label is part of the name and so may carry a space, and copies in what it wants read.
#
# What is written is always a throwaway SUITE, never this file: a control that ran the preamble
# itself would re-enter the case that called it, and that one would run it again, forever. The one
# control that does run the preamble — test_the_self_test_runs_from_a_renamed_copy, which has to,
# since what it pins is that the file works when executed under another name — does not go through
# here for exactly that reason: it runs the copy itself, and passes `--inner-copy` to stop the
# recursion this paragraph describes.
control_in() {
  local dir file lib
  dir="$1"
  shift
  [ -d "$dir" ] || bail "control_in: $dir is not a directory"
  lib="$dir/$(basename "$TEST_LIB_FILE")"
  [ -f "$lib" ] || lib="$TEST_LIB_FILE"
  CONTROL_N=$((CONTROL_N + 1))
  file="$dir/control-$CONTROL_N.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'source %s\n' "\"$lib\""
    printf '%s\n' "$@"
    echo 'test_a_case() { assert_eq 1 1 "one is one"; }'
    echo 'run_tests test_a_case'
  } >"$file"
  CONTROL_FILE="$file"
  control_run "$file"
}

# control_run <script>: run <script> and land its exit code, stdout and stderr in CONTROL_RC /
# _OUT / _ERR. For the controls that cannot be a plain body — a wrapper that exports a function
# in before exec'ing a suite, a suite that defines one above the source — which need the capture
# and nothing else. The two capture files stay in $CONTROL_ROOT wherever <script> is, so a
# control with a directory of its own has in it only what it was given.
control_run() {
  local rc
  set +e
  bash "$1" >"$CONTROL_ROOT/out" 2>"$CONTROL_ROOT/err"
  rc=$?
  set -e
  CONTROL_RC="$rc"
  CONTROL_OUT=$(cat "$CONTROL_ROOT/out")
  CONTROL_ERR=$(cat "$CONTROL_ROOT/err")
}

# mutation_copy <destination> <case> <old> <new>: patch exactly one literal occurrence
# in the sourced preamble, then run only the named existing case. Restricting the patch to the
# sourced section keeps the mutation's own quoted recipe out of its match count. The tracked
# file is read only; a missing/ambiguous target refuses before any output file is written.
mutation_copy() {
  perl - "$TEST_LIB_FILE" "$@" <<'PERL'
use strict;
use warnings;
my ($source, $dest, $case, $old, $new) = @ARGV;
open my $in, '<', $source or die "$source: $!\n";
local $/;
my $text = <$in>;
my $boundary = index($text, '# --- executed:');
die "mutation_copy: missing executed boundary\n" if $boundary < 0;
my $preamble = substr($text, 0, $boundary);
my $count = 0;
my $pos = -1;
if (length $old) {
  while (($pos = index($preamble, $old, $pos + 1)) >= 0) { $count++; }
}
die "mutation_copy: expected exactly one patch target, found $count\n" if $count != 1;
substr($text, index($preamble, $old), length($old)) = $new;
die "mutation_copy: invalid case\n" unless $case =~ /^test_[a-z0-9_]+$/;
$text =~ s/\nrun_tests "\$\{tests\[\@\]\}"\n\z/\nrun_tests $case\n/
  or die "mutation_copy: missing final case runner\n";
open my $out, '>', $dest or die "$dest: $!\n";
print {$out} $text or die "$dest: $!\n";
close $out or die "$dest: $!\n";
PERL
}

# mutant <case> <old> <new> <failure>: prove the unmodified case passes first, then
# require its assertion failure, not a syntax/load failure or an unrelated earlier case.
mutant() {
  local root copy
  # The field-splitting mutant must load before the target case puts it in a spaced path.
  # Keep the outer copy outside an ambient TMPDIR with spaces. Each case creates its own
  # required path; confine even a broken probe's uncleaned diagnostics to this registered root.
  TMPDIR=/tmp test_tmpdir root mutation
  copy="$root/$LIB_BASENAME"
  cp "$HELPER" "$root/"
  mutation_copy "$copy" "$1" "$2" "$2"
  TMPDIR="$root" control_run "$copy"
  assert_eq "$CONTROL_RC" 0 "mutation baseline for $1 ($CONTROL_ERR)"
  assert_eq "$CONTROL_OUT" "PASS: $1" "the selected baseline case must run"
  assert_eq "$CONTROL_ERR" "" "the baseline must be clean"
  mutation_copy "$copy" "$1" "$2" "$3"
  TMPDIR="$root" control_run "$copy"
  assert_eq "$CONTROL_RC" 1 "mutant must fail the assertion in $1 ($CONTROL_ERR)"
  assert_eq "$CONTROL_OUT" "" "the mutated case must not report a pass"
  assert_contains "$CONTROL_ERR" "FAIL: $4" "the named case must fail for the intended reason"
}

# The refusal is matched WITH the name the file gives itself — "$LIB_BASENAME: REFUSING", not the
# bare word. Every refusal here opens with that prefix, and under a renamed copy the prefix is the
# copy's name, so this one line is what pins the LIB_BASENAME rendering in every refusal a control
# can reach: the early-definition guard, the shadow guard, and whatever refusal is added next.
# Matching only "REFUSING" left those prefixes free to be spelled again — with the literal restored
# in the early-definition refusal, the outer run and the renamed inner copy both passed all 19
# cases, so the copy control's PASS-list equality was asserting less than it claimed.
assert_refused() { # <msg>: the guard's refusal, with no case run
  assert_eq "$CONTROL_RC" 2 "$1: a refusal is exit 2 ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "$LIB_BASENAME: REFUSING" \
    "$1: the refusal should say so, under the name the file goes by"
  assert_not_contains "$CONTROL_OUT" "PASS:" "$1: no case may run under a refusal"
}

# The ludics-lite#46 shape itself: a reporter named `fail`, which is pr-review.sh's refusal path.
test_undeclared_shadow_is_refused() {
  control 'fail() { echo "FAIL: $*" >&2; exit 1; }'
  assert_refused "a suite-defined fail"
  assert_contains "$CONTROL_ERR" "pr-review.sh's fail (pr-review.sh:" "the owner and its line should be named"
  assert_contains "$CONTROL_ERR" "redefined at $CONTROL_FILE:4 without \`stub fail\`" \
    "the suite's definition should be located and the remedy named"
  assert_contains "$CONTROL_ERR" "ludics-lite#46" "the refusal should cite the trap"
}

# Every library function is protected, not a hand-picked list: a name that would corrupt results
# rather than exit codes is caught the same way, and so are two at once.
test_every_library_function_is_protected() {
  control 'newest() { echo 0; }' 'age_of() { echo 0; }'
  assert_refused "shadowed newest and age_of"
  assert_contains "$CONTROL_ERR" "pr-review.sh's newest (" "newest should be named"
  assert_contains "$CONTROL_ERR" "pr-review.sh's age_of (" "age_of should be named"
  assert_eq "$(grep -c 'redefined at' <<<"$CONTROL_ERR")" 2 "both shadows in one refusal"
}

# A suite may not quietly replace this file's helpers either.
test_lib_helpers_are_protected() {
  control 'assert_eq() { :; }'
  assert_refused "a redefined assert_eq"
  assert_contains "$CONTROL_ERR" "$LIB_BASENAME's assert_eq ($LIB_BASENAME:" \
    "the owner should be this file"
}

test_declared_stub_is_allowed() {
  control 'stub newest' 'newest() { echo 0; }'
  assert_eq "$CONTROL_RC" 0 "a declared stub runs ($CONTROL_ERR)"
  assert_contains "$CONTROL_OUT" "PASS: test_a_case" "the case should run"
  # The declaration may come after the definition too: the guard reads the table at run_tests.
  control 'build_checks() { :; }' 'run_signal() { :; }' 'stub build_checks run_signal'
  assert_eq "$CONTROL_RC" 0 "stubs declared after their definitions run ($CONTROL_ERR)"
}

test_stub_without_a_redefinition_is_refused() {
  control 'stub newest'
  assert_refused "a stub never honoured"
  assert_contains "$CONTROL_ERR" "stub newest is declared, but newest is still pr-review.sh's" \
    "the stale declaration should be named"
}

test_stub_of_an_unknown_name_is_refused() {
  control 'stub no_such_function'
  assert_eq "$CONTROL_RC" 1 "an unknown stub is the reporter's exit 1 ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "stub no_such_function: neither pr-review.sh nor $LIB_BASENAME defines no_such_function" \
    "the unknown name should be named"
  assert_not_contains "$CONTROL_OUT" "PASS:" "no case may run"
}

# The suite's own functions are its business: a fixture gh and helpers of any other name pass.
test_own_functions_pass() {
  control 'gh() { gh_fixture_parse "$@"; gh_fixture_answer "{}"; }' 'helper_of_my_own() { :; }'
  assert_eq "$CONTROL_RC" 0 "a suite with only its own functions runs ($CONTROL_ERR)"
  assert_contains "$CONTROL_OUT" "PASS: test_a_case" "the case should run"
  # And still when the ENVIRONMENT exported a function of the same name in. Bash records an
  # inherited function with no defining file, so a snapshot taken whole protected it and the
  # suite's own fixture `gh` read as a redefinition of it: every suite refused, from a shell that
  # merely had `gh` exported, with "(null)'s gh ((null):0) is redefined at …". The exporting shell
  # is a file of its own because `export -f` carries the definition's file and line with it.
  local exporter="$CONTROL_ROOT/exporter-gh.sh"
  {
    echo 'gh() { echo "an inherited gh"; }'
    echo 'export -f gh'
    printf 'exec bash %s\n' "\"$CONTROL_FILE\""
  } >"$exporter"
  control_run "$exporter"
  assert_eq "$CONTROL_RC" 0 "an inherited gh must not make the suite's own fixture a shadow ($CONTROL_ERR)"
  assert_contains "$CONTROL_OUT" "PASS: test_a_case" "the case should run"
  assert_not_contains "$CONTROL_ERR" "REFUSING" "and nothing should be refused"
}

test_definitions_before_sourcing_are_refused() {
  local file
  file="$CONTROL_ROOT/early.sh"
  {
    echo 'set -euo pipefail'
    echo 'early() { :; }'
    printf 'source %s\n' "\"$TEST_LIB_FILE\""
    echo 'run_tests early'
  } >"$file"
  control_run "$file"
  assert_refused "a function defined before the source"
  assert_contains "$CONTROL_ERR" "defined functions before sourcing this file (early)" \
    "the early definition should be named"
  # A function the ENVIRONMENT exported into the suite's shell is not the suite defining one, and
  # refusing it made every suite unrunnable from such a shell. The exporting shell is a file of its
  # own, because `export -f` carries the definition's file and line with it and defining these here
  # would attribute them to this file. One of the two is `fail` deliberately — the ludics-lite#46
  # name — to pin that an inherited library name is not a shadow either: pr-review.sh's own
  # definition replaces it when the preamble sources it, which is what the snapshot then records.
  local exporter="$CONTROL_ROOT/exporter.sh"
  control 'helper_of_my_own() { :; }'
  {
    echo 'fail() { echo "an inherited fail"; }'
    echo 'inherited_helper() { :; }'
    echo 'export -f fail inherited_helper'
    printf 'exec bash %s\n' "\"$CONTROL_FILE\""
  } >"$exporter"
  control_run "$exporter"
  assert_eq "$CONTROL_RC" 0 "an exported function in the environment must not refuse a suite ($CONTROL_ERR)"
  assert_contains "$CONTROL_OUT" "PASS: test_a_case" "the case should run"
  assert_not_contains "$CONTROL_ERR" "REFUSING" "and nothing should be refused"
}

# test_tmpdir writes to the CALLER's variable, whatever it is named — including `dir`, the name
# the function itself once held its scratch value in (ludics-lite#79). The target is pre-set, so
# the silent half of the trap is covered too: the caller's stale value must not survive, and the
# path that comes back must be the one registered for removal, in the caller's shell.
test_tmpdir_writes_to_a_target_named_dir() {
  local path pid
  control 'dir=stale' \
    'test_tmpdir dir tmpdir-target' \
    'printf "target=%s\n" "$dir"' \
    '[ -d "$dir" ] || bail "test_tmpdir did not return a directory: $dir"' \
    '[ "${TEST_CLEANUP[0]}" = "$dir" ] || bail "registered ${TEST_CLEANUP[0]}, returned $dir"'
  assert_eq "$CONTROL_RC" 0 "a caller's variable named dir is written ($CONTROL_ERR)"
  path=$(sed -n 's/^target=//p' <<<"$CONTROL_OUT")
  assert_not_contains "$path" stale "the caller's prior value must not survive the call"
  assert_contains "$path" ".tmpdir-target." "the label should still reach the caller's directory name"
  # And the owning pid, read back with the very parse pr-review.sh's tmp_sweep_stale uses on it:
  # a scratch directory whose name does not carry a pid cannot be told from a live sibling's, and
  # so is collectable by nothing at all once the suite that made it is killed (ludics-lite#219).
  # Pinning the SHAPE here rather than in prose is what stops the label-only spelling coming back.
  pid=${path##*/pr-review-test.}
  pid=${pid%%.*}
  case "$pid" in '' | *[!0-9]*)
    bail "the scratch directory should be keyed by the owning pid, so a killed suite's is swept: $path" ;;
  esac
  [ ! -d "$path" ] || bail "the control left $path behind: the registration did not reach its shell"
}

# The two names it cannot get out of the way of are refused by name rather than written past.
test_tmpdir_refuses_a_name_it_uses() {
  control 'test_tmpdir __test_tmpdir_path tmpdir-own-local'
  assert_eq "$CONTROL_RC" 1 "its own local as the target is the reporter's exit 1 ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" 'refusing to write the path into $__test_tmpdir_path' \
    "the refusal should name the variable asked for"
  assert_not_contains "$CONTROL_OUT" "PASS:" "no case may run"
  control 'test_tmpdir TEST_CLEANUP tmpdir-cleanup-list'
  assert_eq "$CONTROL_RC" 1 "the cleanup list as the target is refused too ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" 'refusing to write the path into $TEST_CLEANUP' \
    "the refusal should name the cleanup list"
}

# The EXIT trap's OTHER job, which is pr-review.sh's: a watch sourced into a suite leaves a
# snapshot directory and an error file in TMPDIR, and this file's trap — which replaced the
# script's — is what removes them. This is ludics-lite#191's leak measured directly: the paths are
# created in a registered root, so the case cannot itself leak whichever way it goes, and both
# must be gone once the suite that made them has exited.
test_the_exit_trap_removes_what_pr_review_sh_s_trap_removes() {
  local root snap err gh
  test_tmpdir root trap-removes
  # All THREE paths pr_review_cleanup removes. GH_TMP_FILE is gh_retry's per-attempt capture, and
  # it is here for the reason the other two are: what this trap removes is read off the script's
  # function rather than restated, so a path added there has to show up here or nothing proves the
  # addition runs (ludics-lite#219, the same shape as #191's snapshot directory).
  control "SNAP_DIR=\$(mktemp -d \"$root/snap.XXXXXX\")" \
    "GH_ERR_FILE=\$(mktemp \"$root/err.XXXXXX\")" \
    "GH_TMP_FILE=\$(mktemp \"$root/gh.XXXXXX\")" \
    'printf "snap=%s\nerr=%s\ngh=%s\n" "$SNAP_DIR" "$GH_ERR_FILE" "$GH_TMP_FILE"'
  assert_eq "$CONTROL_RC" 0 "the probe suite must run ($CONTROL_ERR)"
  snap=$(sed -n 's/^snap=//p' <<<"$CONTROL_OUT")
  err=$(sed -n 's/^err=//p' <<<"$CONTROL_OUT")
  gh=$(sed -n 's/^gh=//p' <<<"$CONTROL_OUT")
  assert_contains "$snap" "$root/snap." "the probe should report the directory it made"
  [ ! -e "$snap" ] || bail "the snapshot directory survived the suite's exit: $snap (ludics-lite#191)"
  [ ! -e "$err" ] || bail "the error file survived the suite's exit: $err"
  [ ! -e "$gh" ] || bail "gh_retry's capture survived the suite's exit: $gh"
}

# And the guard that keeps the above true as the script's trap grows. Three ways the wiring can
# come apart, each shown to refuse rather than to pass quietly — which is what the hand-copied
# trap bodies did for a whole release (ludics-lite#195).
test_a_trap_that_stops_reaching_pr_review_sh_s_is_refused() {
  local root copy inline
  test_tmpdir root trap-guard
  copy="$root/$LIB_BASENAME"
  cp "$HELPER" "$TEST_LIB_FILE" "$root/"

  # (1) The call deleted from this file's trap — the state the restatement decayed into, where
  # the script's cleanup simply never runs in a suite.
  perl -0777 -i -pe 'my $n = s/\n  pr_review_cleanup\n/\n/; die "expected one call to delete, found $n\n" unless $n == 1' "$copy"
  control_in "$root"
  assert_refused "a trap that no longer calls the script's cleanup"
  assert_contains "$CONTROL_ERR" 'never calls `pr_review_cleanup`' "the missing call should be named"
  assert_contains "$CONTROL_ERR" "ludics-lite#195" "the refusal should cite the trap it exists against"
  cp "$TEST_LIB_FILE" "$copy"

  # (2) pr-review.sh's trap written back as an inline body — the shape there is no way to call.
  inline='trap '\''rm -f "$GH_ERR_FILE"'\'' EXIT'
  NEW="$inline" perl -0777 -i -pe 'my $n = s/\Qtrap pr_review_cleanup EXIT\E/$ENV{NEW}/; die "expected one trap line, found $n\n" unless $n == 1' "$root/pr-review.sh"
  control_in "$root"
  assert_refused "an inline trap body in pr-review.sh"
  assert_contains "$CONTROL_ERR" "a command rather than a call to a named function" \
    "the refusal should say what shape is wanted instead"

  # (3) A trap naming a function pr-review.sh does not define — a rename landed on one side only.
  cp "$HELPER" "$root/"
  NEW='trap no_such_cleanup EXIT' perl -0777 -i -pe 'my $n = s/\Qtrap pr_review_cleanup EXIT\E/$ENV{NEW}/; die "expected one trap line, found $n\n" unless $n == 1' "$root/pr-review.sh"
  control_in "$root"
  assert_refused "a trap naming a function the script does not define"
  assert_contains "$CONTROL_ERR" 'names `no_such_cleanup`, which pr-review.sh does not define' \
    "the unknown name should be named"
}

# The parser the api-only suites share, pinned once: the endpoint, the filter, the pagination
# flag, and the two logs.
test_gh_fixture_parse() {
  local log="$CONTROL_ROOT/req" plog="$CONTROL_ROOT/pag" out
  REQUEST_LOG="$log"
  PAGINATE_LOG="$plog"
  : >"$log"
  : >"$plog"
  gh_fixture_parse api --paginate repos/o/n/thing --jq '.a' -X GET
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing "the first non-option argument is the endpoint"
  assert_eq "$FIXTURE_FILTER" .a "the --jq filter is kept"
  assert_eq "$FIXTURE_PAGINATE" 1 "--paginate is noted"
  assert_eq "$(cat "$log")" repos/o/n/thing "the endpoint is logged"
  assert_eq "$(cat "$plog")" repos/o/n/thing "a paginated read is logged as such"
  out=$(gh_fixture_answer '{"a":"x"}')
  assert_eq "$out" x "the answer goes through the filter"
  # A write: the method's value is not the endpoint, and neither is a field's.
  gh_fixture_parse api -X POST repos/o/n/thing/replies -f body=hello --jq .html_url
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing/replies "-X POST does not become the endpoint"
  assert_eq "$FIXTURE_FILTER" .html_url "the filter still parses after an option with a value"
  gh_fixture_parse api -f query=q graphql
  assert_eq "$FIXTURE_ENDPOINT" graphql "nor does a field's value, wherever the endpoint sits"
  gh_fixture_parse api repos/o/n/other
  assert_eq "$FIXTURE_FILTER" "" "no filter without --jq"
  assert_eq "$FIXTURE_PAGINATE" "" "not paginated without the flag"
  assert_eq "$(cat "$plog")" repos/o/n/thing "an unpaginated read is not logged as paginated"
  out=$(gh_fixture_answer '{"a":"x"}')
  assert_eq "$out" '{"a":"x"}' "the raw answer without a filter"
  set +e
  out=$(gh_fixture_parse pr merge 2>&1)
  assert_eq "$?" 1 "a non-api call is refused"
  set -e
  assert_contains "$out" "fixture received non-api gh call: pr merge" "the call should be quoted"
  REQUEST_LOG=""
  PAGINATE_LOG=""
}

# The option table, exercised in every spelling pflag accepts. Each case here is a form one of
# the two guessing lists parsed wrongly and silently.
test_gh_fixture_parse_knows_gh_s_option_table() {
  # A value that looks like a REST path (#102 round 1), and the four other value options #86's
  # list had missed.
  gh_fixture_parse api --input fixtures/body.json repos/o/n/thing
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing "a path-shaped option value is not the endpoint"
  gh_fixture_parse api --cache 5m --hostname github.com -t '{{.x}}' -p nebula repos/o/n/thing
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing "nor a duration, a host, a template or a preview"
  # The booleans, which must not consume what follows them — in either position.
  gh_fixture_parse api -i --silent --slurp --verbose --allow-escape-sequences repos/o/n/thing
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing "a boolean does not consume the endpoint"
  gh_fixture_parse api repos/o/n/thing --silent --jq .a
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing "nor when it stands after the endpoint"
  assert_eq "$FIXTURE_FILTER" .a "and it does not swallow the option after it (#102 round 2)"
  # The filter in every spelling gh accepts: separated long and short, and each attached form.
  gh_fixture_parse api repos/o/n/thing -q .a
  assert_eq "$FIXTURE_FILTER" .a "-q is --jq"
  gh_fixture_parse api --jq=.b repos/o/n/thing
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing "--jq=<filter> consumes nothing further"
  assert_eq "$FIXTURE_FILTER" .b "--jq=<filter> is the filter"
  gh_fixture_parse api repos/o/n/thing -q.c
  assert_eq "$FIXTURE_FILTER" .c "an attached short value is the filter (#102 round 2)"
  gh_fixture_parse api repos/o/n/thing -q=.d
  assert_eq "$FIXTURE_FILTER" .d "so is one attached with an ="
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing "and neither attached form loses the endpoint"
  gh_fixture_parse api --cache=5m repos/o/n/thing
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing "nor does any other inline-value long option"
  # `--` ends option parsing: what follows is the endpoint, and is not consumed as a value
  # (#102 round 2).
  gh_fixture_parse api -- repos/o/n/thing
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing "-- is the end of options, not an option"
  gh_fixture_parse api --jq .a -- repos/o/n/thing
  assert_eq "$FIXTURE_ENDPOINT" repos/o/n/thing "options before -- still parse"
  assert_eq "$FIXTURE_FILTER" .a "and their values are still read"
}

# What the table refuses. Every one of these was parsed, wrongly and in silence, by one of the
# two lists that guessed at the options they did not name.
test_gh_fixture_parse_refuses_what_it_cannot_parse() {
  local log="$CONTROL_ROOT/guard-req" out
  REQUEST_LOG="$log"
  : >"$log"
  # An option the table lacks, in the position where assuming it carries a value swallows the
  # endpoint...
  set +e
  out=$(gh_fixture_parse api --future-option repos/o/n/thing 2>&1)
  assert_eq "$?" 1 "an option the table lacks is refused before the endpoint"
  set -e
  assert_contains "$out" "does not know the gh api option --future-option" "the option should be named"
  assert_contains "$out" "gh api --future-option repos/o/n/thing" "the whole call should be quoted"
  assert_contains "$out" "FIXTURE_GH_BOOLS or FIXTURE_GH_VALUED" "the fix should be named"
  # ...and in the position where it leaves the endpoint intact and swallows the NEXT option
  # instead, which is the round-2 shape and the one no guard on the endpoint can see.
  set +e
  out=$(gh_fixture_parse api repos/o/n/thing --future-option --jq .a 2>&1)
  assert_eq "$?" 1 "an option the table lacks is refused after the endpoint too"
  set -e
  assert_contains "$out" "does not know the gh api option --future-option" "the option should be named"
  # A boolean carrying an inline value, and a bundle of shorts, are the same unparseable word.
  set +e
  out=$(gh_fixture_parse api --paginate=false repos/o/n/thing 2>&1)
  assert_eq "$?" 1 "a boolean with an inline value is refused"
  set -e
  assert_contains "$out" "cannot parse '--paginate=false'" "the word should be quoted"
  assert_contains "$out" "write them apart" "the fix should be named"
  set +e
  out=$(gh_fixture_parse api -iq .a repos/o/n/thing 2>&1)
  assert_eq "$?" 1 "bundled short options are refused"
  set -e
  assert_contains "$out" "cannot parse '-iq'" "the bundle should be quoted"
  # `gh api` takes exactly one positional. A second is a call the CLI refuses outright, so
  # answering it would be answering a request production cannot send — and round 2's own control
  # had pinned this very invocation as valid (round 3).
  set +e
  out=$(gh_fixture_parse api -- repos/o/n/thing --paginate 2>&1)
  assert_eq "$?" 1 "a second positional is refused, even past --"
  set -e
  assert_contains "$out" "received 2 positional arguments" "the count should be named"
  assert_contains "$out" "accepts 1 arg(s), received 2" "the CLI's own refusal should be quoted"
  set +e
  out=$(gh_fixture_parse api repos/o/n/thing repos/o/n/other 2>&1)
  assert_eq "$?" 1 "two endpoints are refused without a -- in sight"
  set -e
  assert_contains "$out" "received 2 positional arguments" "the count should be named"
  # `--help` is an ACTION: gh prints its help and makes no request, so no answer is the right one
  # (round 3). Refused from either side of the endpoint.
  set +e
  out=$(gh_fixture_parse api --help repos/o/n/thing 2>&1)
  assert_eq "$?" 1 "--help before the endpoint is refused"
  set -e
  assert_contains "$out" "fixture received --help" "the flag should be named"
  assert_contains "$out" "made no request" "why no answer can be right should be stated"
  set +e
  out=$(gh_fixture_parse api repos/o/n/thing --help 2>&1)
  assert_eq "$?" 1 "--help after the endpoint is refused too"
  set -e
  assert_contains "$out" "fixture received --help" "the flag should be named"
  # The shape guard under it all: a word that is no endpoint, and no endpoint at all.
  set +e
  out=$(gh_fixture_parse api POST 2>&1)
  assert_eq "$?" 1 "a word that is not an endpoint is refused"
  set -e
  assert_contains "$out" "fixture parsed 'POST' as the endpoint" "the bad endpoint should be named"
  set +e
  out=$(gh_fixture_parse api --paginate 2>&1)
  assert_eq "$?" 1 "an api call with no endpoint is refused"
  set -e
  assert_contains "$out" "fixture parsed '' as the endpoint" "the empty endpoint should be named"
  assert_eq "$(cat "$log")" "" "a refused call is not logged"
  REQUEST_LOG=""
}

# --- the jq shim, and the scope three suites used to re-prove a control each --------------------
# `probe_jq <program>` runs one real jq program through the shim and lands its status, stdout and
# stderr in PROBE_RC / _OUT / _ERR. The program is a trivial one of this file's own: what the
# controls below are about is the SHIM, so tying them to a program of pr-review.sh's would make
# them fail whenever that script's text moved.
PROBE_RC=0
PROBE_OUT=""
PROBE_ERR=""
probe_jq() {
  local rc=0
  PROBE_OUT=$(jq -cn --arg tag "$1" '{marked: $tag}' 2>"$CONTROL_ROOT/jq.err") || rc=$?
  PROBE_RC="$rc"
  PROBE_ERR=$(cat "$CONTROL_ROOT/jq.err")
  # The status is answered as well as recorded, so a case can read what `with_broken_jq` hands
  # back from the command it ran.
  return "$rc"
}

# Pointed at a fragment the call carries, the shim refuses it the way a broken program does:
# nonzero, nothing on stdout, the error on stderr. Nothing on stdout is the half that matters —
# a shim that failed but still printed would let a site's unguarded read carry on with a value.
test_the_jq_shim_breaks_the_program_it_is_pointed_at() {
  with_broken_jq 'marked' probe_jq mine || :
  assert_eq "$PROBE_RC" 3 "a marked program must fail"
  assert_eq "$PROBE_OUT" "" "and print nothing, or the site under test reads a value anyway"
  assert_contains "$PROBE_ERR" "jq: error:" "and say what a jq error says"
  # The marker reaches every argument, not only the program: a program assembled from `--arg`s,
  # and a suite's own `--jq` filter, both go through this same shim.
  with_broken_jq 'mine' probe_jq mine || :
  assert_eq "$PROBE_RC" 3 "a marker matching an argument breaks the call too"
}

# The claim each of the three suites used to carry its own control for: the shim breaks what it is
# pointed at and nothing else. Both halves are here — a marker that matches nothing leaves the
# call alone, and so does no marker at all — because they are different code paths through the
# shim, and it is the first that a suite's `BREAK_JQ='zzz-no-program-carries-this'` stood for.
test_the_jq_shim_leaves_every_other_program_alone() {
  # `|| :` on a call that must SUCCEED: a shim broken the other way — refusing everything while
  # any marker stands — would otherwise take the suite down at this line under `set -e`, with an
  # exit 3 and no FAIL naming the claim that failed.
  with_broken_jq 'zzz-no-program-carries-this' probe_jq mine || :
  assert_eq "$PROBE_RC" 0 "a marker no call carries must break nothing"
  assert_eq "$PROBE_OUT" '{"marked":"mine"}' "and the answer must be the real jq's"
  probe_jq mine || :
  assert_eq "$PROBE_RC" 0 "and with no marker standing the shim is transparent"
  assert_eq "$PROBE_OUT" '{"marked":"mine"}' "answering exactly as the real jq does"
}

# The leak the helper exists against. Set and cleared by hand, the clearing line is skipped by a
# command that fails under `set -e`, and a marker left standing is not a failure but a wrong
# RESULT: every case after it runs with one of the script's programs broken, and each of them
# still reports PASS.
test_with_broken_jq_clears_the_marker_whichever_way_the_command_goes() {
  local rc=0
  with_broken_jq 'marked' probe_jq mine || rc=$?
  assert_eq "$rc" 3 "the command's own status is what the helper answers"
  assert_eq "$BREAK_JQ" "" "a failing command must still leave the marker cleared"
  with_broken_jq 'zzz-no-program-carries-this' probe_jq mine
  assert_eq "$BREAK_JQ" "" "and so must one that succeeds"
  # A command that is not there at all is a typo in the case, not a broken jq program.
  set +e
  (with_broken_jq 'marked') 2>"$CONTROL_ROOT/err"
  rc=$?
  set -e
  assert_eq "$rc" 1 "with_broken_jq with no command must refuse"
  assert_contains "$(cat "$CONTROL_ROOT/err")" "with_broken_jq: no command named" \
    "and say what was missing"
}

# The refusal that makes the clearing above more than an idiom: a case that sets the marker by
# hand and returns is failed BY NAME, so the broken program never reaches the cases after it. It
# is written out as a throwaway suite because what is under test happens BETWEEN cases — a body
# line handed to `control` runs while the suite is sourced, not inside one — and the suite holds
# three cases, one per outcome the refusal has to tell apart: one that broke a program through
# the helper and must pass, the one that leaked, and one after it that must not run at all.
test_a_leaked_marker_fails_the_case_that_leaked_it() {
  local file="$CONTROL_ROOT/leaked-marker.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'source %s\n' "\"$TEST_LIB_FILE\""
    echo 'test_that_clears() { with_broken_jq zzz-no-program-carries-this true; }'
    echo 'test_that_leaks() { BREAK_JQ=".[] | select(.marked)"; }'
    echo 'test_after_the_leak() { :; }'
    echo 'run_tests test_that_clears test_that_leaks test_after_the_leak'
  } >"$file"
  control_run "$file"
  assert_eq "$CONTROL_RC" 1 "a leaked marker is the reporter's exit 1 ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "FAIL: test_that_leaks left BREAK_JQ set to '.[] | select(.marked)'" \
    "the leaking case and the marker it left standing should both be named"
  assert_contains "$CONTROL_ERR" "with_broken_jq .[] | select(.marked) <command>" \
    "and the remedy should be named, with the marker the case meant to break"
  # Only the case that went through the helper may pass: the leaking one is not a pass, and the
  # case after it never ran — which is the whole point, since under the leak it would have run
  # with that program refusing and reported PASS.
  assert_eq "$CONTROL_OUT" "PASS: test_that_clears" \
    "the cleared case passes, the leaking case does not, and nothing after it runs"
}

# --- protecting a second library ---------------------------------------------------------------
# The guard's snapshot is taken while this file is sourced, so a library sourced AFTER it — the
# base suites' shared fixture transport — is outside it until `protect_library` says otherwise.
# `extra_control <redefinition...>` builds that situation: a second library beside the throwaway
# suite, protecting itself the way the real one does, and a suite that sources it and then does
# whatever the caller passes.
extra_control() {
  local dir="$CONTROL_ROOT/extra"
  mkdir -p "$dir"
  {
    echo 'extra_helper() { echo library; }'
    echo 'protect_library "${BASH_SOURCE[0]}"'
  } >"$dir/extra-lib.sh"
  control "source \"$dir/extra-lib.sh\"" "$@"
}

# The shape the base transport was in when the review found it: its helpers outside the snapshot,
# so a suite could replace one and `run_tests` would accept it.
test_a_second_library_is_protected_once_it_says_so() {
  extra_control
  assert_eq "$CONTROL_RC" 0 "a suite over a second library still runs ($CONTROL_ERR)"
  assert_eq "$CONTROL_OUT" "PASS: test_a_case" "and its case passes"

  extra_control 'extra_helper() { echo suite; }'
  assert_refused "a suite-defined extra_helper"
  assert_contains "$CONTROL_ERR" "extra-lib.sh's extra_helper (extra-lib.sh:" \
    "the second library is named by its basename, like the other two"
  assert_contains "$CONTROL_ERR" "redefined at $CONTROL_FILE:" "and the suite's line is located"

  # And the declaration works over it, so a deliberate override is still available.
  extra_control 'stub extra_helper' 'extra_helper() { echo suite; }'
  assert_eq "$CONTROL_RC" 0 "a declared stub of the second library's function is allowed ($CONTROL_ERR)"
}

# A library that protects nothing is refused rather than passing: the whole value of the call is
# the names it adds, and a path that matches no record — a resolved one, say, where the shell
# recorded the path it was sourced through — adds none and would look exactly like success.
test_protect_library_refuses_a_file_that_defines_nothing() {
  control 'protect_library "/nowhere/not-a-library.sh"'
  assert_eq "$CONTROL_RC" 1 "a file defining nothing must refuse ($CONTROL_OUT)"
  assert_contains "$CONTROL_ERR" "protect_library: /nowhere/not-a-library.sh defines no function" \
    "the refusal should name the file"
  assert_not_contains "$CONTROL_OUT" "PASS:" "and no case may run under it"
}

# --- retune, and the restore no case performs itself -------------------------------------------
# The values pr-review.sh gave the two constants when this file sourced it, read once so the pair
# below asserts against the script's own defaults rather than a number copied out of it.
GRACE_AS_SOURCED="$GRACE"
ABSENT_GRACE_AS_SOURCED="$ABSENT_GRACE"

test_retune_moves_a_constant() {
  assert_eq "$GRACE" "$GRACE_AS_SOURCED" "the case starts from the grace pr-review.sh was sourced with"
  retune GRACE=1 ABSENT_GRACE=0
  assert_eq "$GRACE" 1 "the grace this case runs under"
  assert_eq "$ABSENT_GRACE" 0 "and a second constant in the same call"
  # Twice over, which is what a case with a control in it does: the saved value is still the one
  # pr-review.sh set, not the 1 above — restoring to that would leak the case's own clock.
  retune GRACE=2
  assert_eq "$GRACE" 2 "the second move takes"
  # A case may put them back mid-case; the next case proves it need not.
  restore_tuning
  assert_eq "$GRACE" "$GRACE_AS_SOURCED" "restore_tuning returns the value as sourced, not the first move"
  assert_eq "$ABSENT_GRACE" "$ABSENT_GRACE_AS_SOURCED" "and every name it held, not only the last moved"
  # BOTH are left moved, with nothing here restoring them, because the next case is judged on what
  # run_tests restores by itself. Leaving only GRACE moved — which this case used to do, the second
  # constant having been put back by the restore_tuning above — made that case's ABSENT_GRACE
  # assertion green whatever run_tests did with it, so it could not tell a restore of ONE retuned
  # constant from a restore of all of them.
  retune GRACE=3 ABSENT_GRACE=9
  assert_eq "$GRACE" 3 "and retuning again after a restore still works"
  assert_eq "$ABSENT_GRACE" 9 "for every name, so the case after this one has two to check"
}

# Listed immediately after the case above, and reading what that case left behind: nothing there
# restored GRACE=3 or ABSENT_GRACE=0, so anything but the sourced values here is the leak.
test_retune_is_undone_when_the_case_ends() {
  assert_eq "$GRACE" "$GRACE_AS_SOURCED" "run_tests restored the grace the case before it moved"
  assert_eq "$ABSENT_GRACE" "$ABSENT_GRACE_AS_SOURCED" "and every other constant that case moved"
}

# A typo would otherwise invent a variable pr-review.sh never reads, and the case would pass while
# running under the untouched constant it meant to move.
test_retune_of_a_name_the_script_does_not_set_is_refused() {
  control 'retune GARCE=1'
  assert_eq "$CONTROL_RC" 1 "an unknown constant is the reporter's exit 1 ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "retune GARCE: pr-review.sh sets no GARCE when it is sourced" \
    "the unknown name should be named"
  assert_not_contains "$CONTROL_OUT" "PASS:" "no case may run"
  # A bare name is the other way to write it wrong: `retune GRACE 1` would silently do nothing.
  control 'retune GRACE 1'
  assert_eq "$CONTROL_RC" 1 "a bare name is refused too ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "retune: 'GRACE' is not a NAME=value assignment" \
    "the malformed argument should be quoted"
  # A name the SHELL always provides is not a constant of pr-review.sh's, whatever its text says.
  # IFS is the one that matters: `IFS=… read` sits in several of its function bodies and every
  # shell has IFS set, so a set derived from the text plus "is it set now" accepted `retune IFS=x`
  # — which would have altered the word splitting of the harness doing the retuning.
  control 'retune IFS=x'
  assert_eq "$CONTROL_RC" 1 "IFS is not a source-time constant ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "retune IFS: pr-review.sh sets no IFS when it is sourced" \
    "IFS should be refused by name"
  # PIPESTATUS is the same class arriving by the other door: the shell CREATES it, mid-source,
  # when the script runs a top-level pipeline. It is absent from a naive first snapshot and
  # present in the second, so by name alone it is indistinguishable from something the script
  # assigned — and `retune PIPESTATUS=x` was accepted, and did nothing at all.
  control 'retune PIPESTATUS=x'
  assert_eq "$CONTROL_RC" 1 "a variable the shell creates is not a constant ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "retune PIPESTATUS: pr-review.sh sets no PIPESTATUS when it is sourced" \
    "PIPESTATUS should be refused by name"
  # The other side of that probe: the constants it must accept, from both ends of the file — the
  # block that runs as pr-review.sh is sourced, and the ones a subcommand's section sets hundreds
  # of lines further down, which a probe that stopped reading early would miss.
  control 'retune GRACE=1 STALL=2 ROUND_GAP=3 ABSENT_GRACE=4 CHECKS_INTERVAL=5 STALE_BASE=6' \
    '[ "$GRACE$STALL$ROUND_GAP$ABSENT_GRACE$CHECKS_INTERVAL$STALE_BASE" = 123456 ] ||
       bail "the constants did not take: $GRACE$STALL$ROUND_GAP$ABSENT_GRACE$CHECKS_INTERVAL$STALE_BASE"'
  assert_eq "$CONTROL_RC" 0 "every documented constant is retunable ($CONTROL_ERR)"
  assert_contains "$CONTROL_OUT" "PASS: test_a_case" "the case should run"
}

# A probe that cannot read pr-review.sh's constants must say so HERE, with the reason. Every
# suite has `set -e` on by the time the probe runs, so a failure that propagated through the
# assignment killed the suite where it stood — exit 1, no output, and the source's own stderr
# discarded — which reads as the suite failing rather than as a setup that never started. The
# control is a copy of this file beside a pr-review.sh that refuses to source.
test_a_probe_that_cannot_read_the_constants_refuses_with_the_reason() {
  local root
  test_tmpdir root probe-fail
  cp "$TEST_LIB_FILE" "$root/"
  printf '#!/usr/bin/env bash\necho "missing dependency: frobnicator not found" >&2\nreturn 1\n' \
    >"$root/pr-review.sh"
  control_in "$root"
  assert_eq "$CONTROL_RC" 2 "a probe that cannot read the constants is a refusal, not a suite failure ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "$LIB_BASENAME: REFUSING to run: the probe that reads pr-review.sh's source-time constants" \
    "the refusal should name what could not be read, under the name the file goes by"
  assert_contains "$CONTROL_ERR" "missing dependency: frobnicator not found" \
    "and carry what the source itself said, which is the only thing that localizes it"
  assert_eq "$CONTROL_OUT" "" "nothing may run"
}

# The probe writes the source's stderr to `pr-review-probe.<pid>.err` in TMPDIR and removes it on
# both of its paths — and neither removal was there at first. The debris is still on this box: a
# 0-byte file from 09-10 19:17, three minutes before the SUCCESS path learned to remove it
# (6de6cff), and four carrying this file's own "frobnicator" line from 09-12 19:07, four minutes
# before `mutant` gave a broken probe a TMPDIR of its own (ced18ba). Both leaks are fixed and
# nothing held them fixed; this case is what does. pr-review.sh's tmp_sweep_stale is the backstop
# behind it, for the one path no removal here can cover — a suite killed while the probe runs.
test_a_refused_probe_leaves_no_diagnostics_in_tmpdir() {
  local root
  test_tmpdir root probe-leak
  cp "$TEST_LIB_FILE" "$root/"
  printf '#!/usr/bin/env bash\necho "missing dependency: frobnicator not found" >&2\nreturn 1\n' \
    >"$root/pr-review.sh"
  # A TMPDIR of this case's own, so what is asserted empty is only what the refused probe put
  # there: control_in writes its throwaway suite in $root and control_run its capture files in
  # CONTROL_ROOT, and neither is under this one. The assignment prefix is the idiom `mutant`
  # already uses to point a control's temporaries somewhere registered.
  mkdir "$root/tmpdir"
  TMPDIR="$root/tmpdir" control_in "$root"
  assert_eq "$CONTROL_RC" 2 "the refusal is what this case provokes ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "missing dependency: frobnicator not found" \
    "the refusal must still carry what the source said"
  assert_eq "$(find "$root/tmpdir" -mindepth 1 -print | tr '\n' ' ')" "" \
    "a refused probe must leave nothing in TMPDIR"
}

# The guard has to survive the PATH it is checked out under. `declare -F` prints "<name> <line>
# <file>", and a directory with a space in it — a scratch clone at `/tmp/ludics review.XXXX` —
# splits that file across the fields of anything reading it positionally. Comparing a field rather
# than the intact remainder emptied the snapshot, and an EMPTY snapshot protects nothing and says
# nothing: this file's own first control passed a deliberate `fail` through.
#
# The control cannot be "run this file from a spaced directory" — it would run this case again,
# forever. It is a throwaway suite there instead, carrying the ludics-lite#46 shadow, which must
# still be refused.
test_the_guard_survives_a_path_with_spaces() {
  local root
  test_tmpdir root "lib space"
  case "$root" in *" "*) ;; *) bail "the control needs a path with a space in it: $root" ;; esac
  cp "$HELPER" "$TEST_LIB_FILE" "$root/"
  control_in "$root" 'fail() { echo "FAIL: $*" >&2; exit 1; }'
  assert_eq "$CONTROL_RC" 2 "the shadow guard must still refuse from a spaced path ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "without \`stub fail\`" "the refusal should name the shadow, not the snapshot"
  assert_not_contains "$CONTROL_OUT" "PASS:" "no case may run"
  # And the snapshot itself is not empty there — the refusal above would also fire if the file
  # merely failed to load, and this is the difference between the two.
  assert_not_contains "$CONTROL_ERR" "the function-table snapshot named nothing" \
    "the snapshot should be populated, not empty-and-refused"
}

test_mutation_copy_refuses_missing_or_ambiguous_targets() {
  local root rc err old
  test_tmpdir root mutation-target
  for old in 'no such preamble text' 'local'; do
    rc=0
    mutation_copy "$root/copy.sh" test_own_functions_pass "$old" broken 2>"$root/err" || rc=$?
    err=$(cat "$root/err")
    [ "$rc" -ne 0 ] || bail "a missing or ambiguous mutation target must fail"
    assert_contains "$err" 'mutation_copy: expected exactly one patch target, found' \
      "the patch count should explain the refusal"
    [ ! -e "$root/copy.sh" ] || bail "a refused mutation must not write a copy"
  done
}

test_snapshot_path_mutation_is_caught() {
  mutant test_the_guard_survives_a_path_with_spaces \
    '    path = $0
    sub(/^[^ ]+ [^ ]+ /, "", path)' '    path = $3' \
    'the refusal should name the shadow, not the snapshot'
}

test_probe_status_mutation_is_caught() {
  mutant test_a_probe_that_cannot_read_the_constants_refuses_with_the_reason \
    ')" || lib_probe_rc=$?' ')"' \
    "a probe that cannot read the constants is a refusal, not a suite failure ("
  assert_contains "$CONTROL_ERR" "got '1', expected '2'" "the probe must expose the lost status capture"
}

# And the other half of that probe: the diagnostics it writes. Reverting the refusal path's
# removal is a one-line change that leaves every existing case green — which is exactly how it
# went missing in the first place, and why the emptiness assertion needs a mutant of its own
# rather than the reader's trust (ludics-lite#219).
test_probe_diagnostics_mutation_is_caught() {
  mutant test_a_refused_probe_leaves_no_diagnostics_in_tmpdir \
    'rm -f "$lib_probe_err"
  exit 2' 'exit 2' \
    "a refused probe must leave nothing in TMPDIR (got '"
  assert_contains "$CONTROL_ERR" "pr-review-probe." \
    "the mutant must name the diagnostics file it left behind"
}

# The route the whole file depends on: to SHOW a guard can fail you copy this file and pr-review.sh
# into a scratch directory, revert the fix in the COPY, and run the copy — the tracked file is
# never touched, so a session that dies between mutating and restoring leaves the repo clean. The
# fallback when that route is broken is to mutate the tracked file in place and put it back, which
# does not have that property.
#
# It was broken by a single assertion that spelled this file's name where it meant "this file":
# run as `lib-reverted.sh`, `test_lib_helpers_are_protected` failed on the owner string rather than
# on the mutation (ludics-lite#101). Nothing caught it, because nothing here had ever run this file
# from anywhere but its own path. This case is what stops the spelling from creeping back: it runs
# the copy for real and holds it to the same PASS list, so a name spelled instead of derived fails
# HERE, in the file that spelled it.
#
# A copy needs pr-review.sh beside it — TEST_LIB_DIR comes from BASH_SOURCE and HELPER from that —
# and needs nothing else: any directory will do, which is why the copy goes to a test_tmpdir
# rather than into ship-pr/scripts/.
#
# The inner run is given `--inner-copy` so it skips this case instead of copying itself forever.
# It still reports a PASS line for it, so the two lists match exactly and a case silently lost
# from the copy is a diff rather than a shorter list nobody counted.
#
# What the equality below pins is the PASS list; what pins the diagnostics is the inner run's own
# controls, each of which asserts on the refusal it provoked. That is why `assert_refused` matches
# the "$LIB_BASENAME: REFUSING" prefix: the copies of those refusals rendered in the renamed run
# are the only place a re-spelled prefix shows up, and while it matched the bare word, restoring
# the literal in the early-definition refusal left both runs green through all 19 cases.
test_the_self_test_runs_from_a_renamed_copy() {
  local root copy out err rc want bad
  [ -z "$LIB_INNER_RUN" ] || return 0
  test_tmpdir root renamed-copy
  copy="$root/lib-reverted.sh"
  cp "$TEST_LIB_FILE" "$copy"
  cp "$HELPER" "$root/"
  set +e
  out=$(bash "$copy" --inner-copy 2>"$root/err")
  rc=$?
  set -e
  err=$(cat "$root/err")
  assert_eq "$rc" 0 "a renamed copy beside pr-review.sh must run its own controls ($err)"
  assert_eq "$err" "" "and say nothing on stderr"
  want=$(printf 'PASS: %s\n' "${tests[@]}")
  assert_eq "$out" "$want" "the copy should report every case this file runs, in the same order"
  # The marker's own guard, shown to refuse rather than assumed to. Reading `$1` alone accepted
  # `--inner-copy typo` — the trailing word ignored, this case skipped, and all 19 PASS lines
  # reported by a run that had silently dropped the one control the typo was meant to refuse.
  # A run that skips a case must not be reachable by anything but the exact marker.
  for bad in "--inner-copy typo" "--bogus" "--inner-copy --inner-copy"; do
    set +e
    # shellcheck disable=SC2086 # the point is to pass these as separate words
    out=$(bash "$copy" $bad 2>"$root/err")
    rc=$?
    set -e
    err=$(cat "$root/err")
    assert_eq "$rc" 2 "\`$bad\` must be refused, not honoured ($err)"
    assert_contains "$err" "lib-reverted.sh: REFUSING to run: expected no arguments" \
      "the refusal should carry the COPY's name, which is the prefix a renamed run renders"
    assert_eq "$out" "" "no case may run under a refused command line"
  done
}

tests=(
  test_undeclared_shadow_is_refused
  test_every_library_function_is_protected
  test_lib_helpers_are_protected
  test_declared_stub_is_allowed
  test_stub_without_a_redefinition_is_refused
  test_stub_of_an_unknown_name_is_refused
  test_own_functions_pass
  test_definitions_before_sourcing_are_refused
  test_tmpdir_writes_to_a_target_named_dir
  test_tmpdir_refuses_a_name_it_uses
  test_the_exit_trap_removes_what_pr_review_sh_s_trap_removes
  test_a_trap_that_stops_reaching_pr_review_sh_s_is_refused
  test_gh_fixture_parse
  test_gh_fixture_parse_knows_gh_s_option_table
  test_gh_fixture_parse_refuses_what_it_cannot_parse
  test_the_jq_shim_breaks_the_program_it_is_pointed_at
  test_the_jq_shim_leaves_every_other_program_alone
  test_with_broken_jq_clears_the_marker_whichever_way_the_command_goes
  test_a_leaked_marker_fails_the_case_that_leaked_it
  test_a_second_library_is_protected_once_it_says_so
  test_protect_library_refuses_a_file_that_defines_nothing
  test_retune_moves_a_constant
  test_retune_is_undone_when_the_case_ends # must stay directly after the case above
  test_retune_of_a_name_the_script_does_not_set_is_refused
  test_a_probe_that_cannot_read_the_constants_refuses_with_the_reason
  test_a_refused_probe_leaves_no_diagnostics_in_tmpdir
  test_the_guard_survives_a_path_with_spaces
  test_the_self_test_runs_from_a_renamed_copy
  test_mutation_copy_refuses_missing_or_ambiguous_targets
  test_snapshot_path_mutation_is_caught
  test_probe_status_mutation_is_caught
  test_probe_diagnostics_mutation_is_caught
)

run_tests "${tests[@]}"
