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
#                                       by hand), so a suite never touches `trap`
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
#   run_tests <case>...                 the guard below, then each case with a PASS line
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
# Executed rather than sourced, this file runs its own controls: throwaway suites that source it
# and, respectively, redefine an undeclared library function (the ludics-lite#46 shape itself,
# a reporter named `fail`), declare a stub and honour it, declare one and do not, stub a name the
# library lacks, redefine one of this file's own helpers, and define a function before sourcing;
# then two over test_tmpdir's target variable (ludics-lite#79) and one over gh_fixture_parse.
# The negative controls are what prove the guard can fail; CI runs it beside the nine suites.
# `retune` is covered in the same run, by a pair of cases: one moves two constants, the next reads
# them back as pr-review.sh set them, which is the restore no case performs itself.

TEST_LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
TEST_LIB_FILE="$TEST_LIB_DIR/$(basename "${BASH_SOURCE[0]}")"
HELPER="$TEST_LIB_DIR/pr-review.sh"

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
  echo "test-pr-review-lib.sh: REFUSING to run: the suite defined functions before sourcing this file (${lib_predefined% }); source it first, so the shadow guard sees every definition" >&2
  exit 2
fi
unset lib_predefined

export SHIP_PR_TEST_SOURCE_ONLY=1
export SHIP_PR_STATE_DIR=off
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
    SHIP_PR_TEST_SOURCE_ONLY=1 SHIP_PR_STATE_DIR=off \
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
  echo "test-pr-review-lib.sh: REFUSING to run: the probe that reads pr-review.sh's source-time constants exited $lib_probe_rc and named $(printf '%s' "$HELPER_CONSTANTS" | wc -w | tr -d ' ') constant(s), so \`retune\` could accept no name. What the source said:" >&2
  sed 's/^/  /' "$lib_probe_err" >&2 || :
  rm -f "$lib_probe_err"
  exit 2
  ;;
esac
unset lib_probe_err lib_probe_rc

# shellcheck source=pr-review.sh
source "$HELPER"

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
# pr-review.sh's trap removes GH_ERR_FILE; sourcing it replaced whatever trap the suite had. This
# one does both jobs, and the suite registers its scratch space through test_tmpdir instead of
# installing a trap of its own. Only paths mktemp created are ever removed.
TEST_CLEANUP=()
test_cleanup() {
  rm -f "$GH_ERR_FILE"
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
  __test_tmpdir_path=$(mktemp -d "${TMPDIR:-/tmp}/pr-review-$2.XXXXXX") || bail "mktemp -d failed for $2"
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
lib_owner_of() {
  printf '%s\n' "$2" | awk -v n="$1" '$1 == n { sub(/^[^ ]+ /, ""); print; exit }'
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
      bail "stub $fn: neither pr-review.sh nor test-pr-review-lib.sh defines $fn — nothing to stub"
    STUBS="$STUBS $fn "
  done
}

lib_declared_stub() { case "$STUBS" in *" $1 "*) ;; *) return 1 ;; esac; }

# A path as the suite's reader would write it: the library files by basename, the suite as it was
# invoked (which is what `declare -F` records).
lib_show_file() {
  case "$1" in
  "$HELPER" | "$TEST_LIB_FILE") basename "$1" ;;
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
    echo "test-pr-review-lib.sh: REFUSING to run the cases: a suite function replaces a library function it did not declare (ludics-lite#46) — a same-named helper silently takes over every call the library makes (a reporter named \`fail\` turns each refusal's exit code into 1); declare a deliberate override with \`stub <fn>\`, else rename the suite's function:$problems" >&2
    exit 2
  }
}

# run_tests <case>...: the guard, then the cases in order, each announced on stdout. A case's
# retuned constants are put back before the next one starts, whether or not it restored them.
run_tests() {
  local test_name
  check_shadows
  [ $# -gt 0 ] || bail "run_tests: no cases named"
  for test_name in "$@"; do
    "$test_name"
    restore_tuning
    echo "PASS: $test_name"
  done
}

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
  echo "test-pr-review-lib.sh: REFUSING to run: the function-table snapshot named nothing, so the shadow guard would protect no function and every ludics-lite#46 shadow would be accepted silently; pr-review.sh ($HELPER) and this file should between them define some sixty" >&2
  exit 2
  ;;
esac

# --- executed: this file's own controls -------------------------------------------------------
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -euo pipefail

test_tmpdir CONTROL_ROOT lib-test
CONTROL_N=0

# control <body...>: a throwaway suite that sources this file and runs a passing case, with the
# given lines in between. Its exit code, stdout and stderr land in CONTROL_RC / _OUT / _ERR.
control() {
  local file rc
  CONTROL_N=$((CONTROL_N + 1))
  file="$CONTROL_ROOT/control-$CONTROL_N.sh"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'source %s\n' "\"$TEST_LIB_FILE\""
    printf '%s\n' "$@"
    echo 'test_a_case() { assert_eq 1 1 "one is one"; }'
    echo 'run_tests test_a_case'
  } >"$file"
  set +e
  bash "$file" >"$CONTROL_ROOT/out" 2>"$CONTROL_ROOT/err"
  rc=$?
  set -e
  CONTROL_RC="$rc"
  CONTROL_OUT=$(cat "$CONTROL_ROOT/out")
  CONTROL_ERR=$(cat "$CONTROL_ROOT/err")
  CONTROL_FILE="$file"
}

assert_refused() { # <msg>: the guard's refusal, with no case run
  assert_eq "$CONTROL_RC" 2 "$1: a refusal is exit 2 ($CONTROL_ERR)"
  assert_contains "$CONTROL_ERR" "REFUSING" "$1: the refusal should say so"
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
  assert_contains "$CONTROL_ERR" "test-pr-review-lib.sh's assert_eq (test-pr-review-lib.sh:" \
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
  assert_contains "$CONTROL_ERR" "stub no_such_function: neither pr-review.sh nor test-pr-review-lib.sh defines no_such_function" \
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
  set +e
  bash "$exporter" >"$CONTROL_ROOT/out" 2>"$CONTROL_ROOT/err"
  CONTROL_RC=$?
  set -e
  CONTROL_OUT=$(cat "$CONTROL_ROOT/out")
  CONTROL_ERR=$(cat "$CONTROL_ROOT/err")
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
  set +e
  bash "$file" >"$CONTROL_ROOT/out" 2>"$CONTROL_ROOT/err"
  CONTROL_RC=$?
  set -e
  CONTROL_OUT=$(cat "$CONTROL_ROOT/out")
  CONTROL_ERR=$(cat "$CONTROL_ROOT/err")
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
  set +e
  bash "$exporter" >"$CONTROL_ROOT/out" 2>"$CONTROL_ROOT/err"
  CONTROL_RC=$?
  set -e
  CONTROL_OUT=$(cat "$CONTROL_ROOT/out")
  CONTROL_ERR=$(cat "$CONTROL_ROOT/err")
  assert_eq "$CONTROL_RC" 0 "an exported function in the environment must not refuse a suite ($CONTROL_ERR)"
  assert_contains "$CONTROL_OUT" "PASS: test_a_case" "the case should run"
  assert_not_contains "$CONTROL_ERR" "REFUSING" "and nothing should be refused"
}

# test_tmpdir writes to the CALLER's variable, whatever it is named — including `dir`, the name
# the function itself once held its scratch value in (ludics-lite#79). The target is pre-set, so
# the silent half of the trap is covered too: the caller's stale value must not survive, and the
# path that comes back must be the one registered for removal, in the caller's shell.
test_tmpdir_writes_to_a_target_named_dir() {
  local path
  control 'dir=stale' \
    'test_tmpdir dir tmpdir-target' \
    'printf "target=%s\n" "$dir"' \
    '[ -d "$dir" ] || bail "test_tmpdir did not return a directory: $dir"' \
    '[ "${TEST_CLEANUP[0]}" = "$dir" ] || bail "registered ${TEST_CLEANUP[0]}, returned $dir"'
  assert_eq "$CONTROL_RC" 0 "a caller's variable named dir is written ($CONTROL_ERR)"
  path=$(sed -n 's/^target=//p' <<<"$CONTROL_OUT")
  assert_not_contains "$path" stale "the caller's prior value must not survive the call"
  assert_contains "$path" "/pr-review-tmpdir-target." "the fresh directory should reach the caller"
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
  # The other side of that probe: the constants it must accept, including one assigned inside a
  # top-level `case` rather than in a stanza of its own.
  control 'retune GRACE=1 STALL=2 ROUND_GAP=3 ABSENT_GRACE=4 CHECKS_INTERVAL=5 CACHE_OFF=6' \
    '[ "$GRACE$STALL$ROUND_GAP$ABSENT_GRACE$CHECKS_INTERVAL$CACHE_OFF" = 123456 ] ||
       bail "the constants did not take: $GRACE$STALL$ROUND_GAP$ABSENT_GRACE$CHECKS_INTERVAL$CACHE_OFF"'
  assert_eq "$CONTROL_RC" 0 "every documented constant is retunable ($CONTROL_ERR)"
  assert_contains "$CONTROL_OUT" "PASS: test_a_case" "the case should run"
}

# A probe that cannot read pr-review.sh's constants must say so HERE, with the reason. Every
# suite has `set -e` on by the time the probe runs, so a failure that propagated through the
# assignment killed the suite where it stood — exit 1, no output, and the source's own stderr
# discarded — which reads as the suite failing rather than as a setup that never started. The
# control is a copy of this file beside a pr-review.sh that refuses to source.
test_a_probe_that_cannot_read_the_constants_refuses_with_the_reason() {
  local root out err rc
  test_tmpdir root probe-fail
  cp "$TEST_LIB_FILE" "$root/"
  printf '#!/usr/bin/env bash\necho "missing dependency: frobnicator not found" >&2\nreturn 1\n' \
    >"$root/pr-review.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\nsource "%s"\n' \
    "$root/$(basename "$TEST_LIB_FILE")" >"$root/suite.sh"
  set +e
  out=$(bash "$root/suite.sh" 2>"$root/err")
  rc=$?
  set -e
  err=$(cat "$root/err")
  assert_eq "$rc" 2 "a probe that cannot read the constants is a refusal, not a suite failure ($err)"
  assert_contains "$err" "REFUSING to run: the probe that reads pr-review.sh's source-time constants" \
    "the refusal should name what could not be read"
  assert_contains "$err" "missing dependency: frobnicator not found" \
    "and carry what the source itself said, which is the only thing that localizes it"
  assert_eq "$out" "" "nothing may run"
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
  local root out err rc lib
  root=$(mktemp -d "${TMPDIR:-/tmp}/pr-review lib space.XXXXXX") || bail "mktemp -d failed"
  TEST_CLEANUP+=("$root")
  case "$root" in *" "*) ;; *) bail "the control needs a path with a space in it: $root" ;; esac
  lib="$root/$(basename "$TEST_LIB_FILE")"
  cp "$HELPER" "$TEST_LIB_FILE" "$root/"
  {
    echo '#!/usr/bin/env bash'
    echo 'set -euo pipefail'
    printf 'source %s\n' "\"$lib\""
    echo 'fail() { echo "FAIL: $*" >&2; exit 1; }'
    echo 'test_a_case() { assert_eq 1 1 "one is one"; }'
    echo 'run_tests test_a_case'
  } >"$root/suite.sh"
  set +e
  out=$(bash "$root/suite.sh" 2>"$root/err")
  rc=$?
  set -e
  err=$(cat "$root/err")
  assert_eq "$rc" 2 "the shadow guard must still refuse from a spaced path ($err)"
  assert_contains "$err" "without \`stub fail\`" "the refusal should name the shadow, not the snapshot"
  assert_not_contains "$out" "PASS:" "no case may run"
  # And the snapshot itself is not empty there — the refusal above would also fire if the file
  # merely failed to load, and this is the difference between the two.
  assert_not_contains "$err" "the function-table snapshot named nothing" \
    "the snapshot should be populated, not empty-and-refused"
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
  test_gh_fixture_parse
  test_gh_fixture_parse_knows_gh_s_option_table
  test_gh_fixture_parse_refuses_what_it_cannot_parse
  test_retune_moves_a_constant
  test_retune_is_undone_when_the_case_ends # must stay directly after the case above
  test_retune_of_a_name_the_script_does_not_set_is_refused
  test_a_probe_that_cannot_read_the_constants_refuses_with_the_reason
  test_the_guard_survives_a_path_with_spaces
)

run_tests "${tests[@]}"
