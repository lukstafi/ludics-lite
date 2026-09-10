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
#   gh_fixture_parse "$@"               inside a fixture `gh`: refuses anything but `gh api`,
#   gh_fixture_answer <response>        sets FIXTURE_ENDPOINT / FIXTURE_FILTER / FIXTURE_PAGINATE,
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
lib_predefined=$(declare -F | sed 's/^declare -f //' | tr '\n' ' ')
if [ -n "$lib_predefined" ]; then
  echo "test-pr-review-lib.sh: REFUSING to run: the suite defined functions before sourcing this file (${lib_predefined% }); source it first, so the shadow guard sees every definition" >&2
  exit 2
fi
unset lib_predefined

export SHIP_PR_TEST_SOURCE_ONLY=1
export SHIP_PR_STATE_DIR=off
export SHIP_PR_API_ATTEMPTS=1
export SHIP_PR_API_BACKOFF=0
# The variable names in scope on either side of the source, so what pr-review.sh sets when it is
# sourced can be named exactly: that difference is the set `retune` accepts. The seeds are the
# three names this stanza itself introduces — each is set after the snapshot it would spoil, so
# without them they would read as the library's.
lib_vars_before=" $(compgen -v | tr '\n' ' ')lib_vars_before lib_var HELPER_CONSTANTS "
# shellcheck source=pr-review.sh
source "$HELPER"
HELPER_CONSTANTS=""
for lib_var in $(compgen -v); do
  case "$lib_vars_before" in *" $lib_var "*) continue ;; esac
  HELPER_CONSTANTS="$HELPER_CONSTANTS $lib_var "
done
unset lib_vars_before lib_var

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

gh_fixture_parse() {
  local arg
  FIXTURE_ENDPOINT=""
  FIXTURE_FILTER=""
  FIXTURE_PAGINATE=""
  [ "${1:-}" = api ] || bail "fixture received non-api gh call: $*"
  shift
  while [ $# -gt 0 ]; do
    arg="$1"
    shift
    case "$arg" in
    --jq)
      FIXTURE_FILTER="${1:-}"
      shift || true
      ;;
    --paginate) FIXTURE_PAGINATE=1 ;;
    # The options that carry a VALUE, consumed with it. Without this the `POST` of a `gh api -X
    # POST repos/...` became the endpoint (it is the first argument that does not start with a
    # dash), so a suite over the writing commands addressed every call to "POST".
    -X | --method | -f | --field | -F | --raw-field | -H | --header) shift || true ;;
    -*) ;;
    *) [ -n "$FIXTURE_ENDPOINT" ] || FIXTURE_ENDPOINT="$arg" ;;
    esac
  done
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

LIB_SNAPSHOT=$(lib_function_table)

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
  retune GRACE=3
  assert_eq "$GRACE" 3 "and retuning again after a restore still works"
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
  test_retune_moves_a_constant
  test_retune_is_undone_when_the_case_ends # must stay directly after the case above
  test_retune_of_a_name_the_script_does_not_set_is_refused
)

run_tests "${tests[@]}"
