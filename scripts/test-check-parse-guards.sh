#!/usr/bin/env bash
# Exercises check-parse-guards.sh against scratch files and scratch CHECKOUTS: one probe per shape
# the guard exists to refuse, each with the passing shape beside it as the control -- a scan that
# cannot fail would prove nothing (ludics-lite#55). Two of the cases are not about the scan at all
# but about the rule it enforces, and they are what make the rest worth running: a script appended
# to WHILE IT RUNS reads the appended line and executes it, and the same script inside the brace
# group never does (ludics-lite#10, #247); a library that dispatches on `|| return 0` inside the
# group hands its caller back alive, and one that falls through to the foot's `exit` takes the
# caller down with it. Both are deterministic -- the running script does the appending itself, so
# there is no window to race -- and the second is the property the twelve pr-review suites rest on.
# It ends by running the guard on this checkout, which is the verdict CI's lint job reads, and on
# test-fleet-worker.sh as it stood before ludics-lite#247, where the guard must find what that PR
# fixed: a rule nobody has ever seen fire is a rule nobody can trust.
#
# Usage: test-check-parse-guards.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

# One brace group, so bash parses this file WHOLE before its first line runs and an edit landing
# while a run is in flight cannot resume the shell at a shifted offset; the `exit` at the foot
# means the shell never comes back to the file for a next command. Two lines here and two at the
# foot, with the body's own indentation untouched (ludics-lite#10, #247); scripts/check-parse-guards.sh
# checks the shape.
{
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
CP="$HERE/check-parse-guards.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-parse-guards-test.XXXXXX") || exit 1
# Resolved once, physically. On macOS $TMPDIR is under /var, a symlink to /private/var, and a guard
# installed in a scratch checkout computes its own ROOT with `pwd -P` -- so an unresolved $TMP here
# and the guard's idea of the same directory are spelled differently, and every assertion that
# compares the guard's output against a $TMP path silently stops matching. The ones phrased as
# "this must NOT appear" then pass over anything (ludics-lite#197, #214).
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  printf '%s\n' "PASS: $*"
}
ko() {
  fail=$((fail + 1))
  printf '%s\n' "FAIL: $*"
}

# expect <label> <want-rc> <want-substring> -- <cmd...>
expect() {
  local label="$1" want_rc="$2" want="$3" out rc
  shift 3
  [ "$1" = -- ] && shift
  out=$("$@" 2>&1)
  rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -qF -- "$want" <<<"$out"; then
    ok "$label"
  else
    ko "$label (rc=$rc want $want_rc; want /$want/) -- $out"
  fi
}

# probe <name>: the scratch file the next expect reads, written from stdin.
probe() {
  cat >"$TMP/$1.sh"
  printf '%s' "$TMP/$1.sh"
}

PASSED='every suite is one brace group'
NO_FOOT='must end in `exit "$?"` and `}`'
NOT_FIRST="the brace group must open as this file's first command"
NOT_THE_BRACE='is not the brace that the final `}` closes'

# --- the shape that must pass -------------------------------------------------------------------

expect "the house shape passes" 0 "$PASSED" -- \
  "$CP" "$(probe good <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{
echo "the body, at its own indentation"
[ 1 -eq 1 ]
exit "$?"
}
EOF
)"

# `set` is a builtin: it forks nothing, so no line of the file is read after any of it has run, and
# a second one below the first changes nothing about that. The guard lets them stand above the `{`.
expect "set lines above the group are allowed" 0 "$PASSED" -- \
  "$CP" "$(probe good_two_sets <<'EOF'
#!/usr/bin/env bash
# a comment, and a blank line, may stand above the group too

set -euo pipefail
set -m
{
echo body
exit "$?"
}
EOF
)"

# --- the shapes that must be refused --------------------------------------------------------

expect "a suite with no brace group is refused" 1 "$NO_FOOT" -- \
  "$CP" "$(probe bad_no_group <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo body
[ 1 -eq 1 ]
EOF
)"

# The group without the exit: the shell still comes back to the file at EOF for a next command,
# which is the offset an edit has moved.
expect "a group whose foot has no exit is refused" 1 "$NO_FOOT" -- \
  "$CP" "$(probe bad_no_exit <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{
echo body
}
EOF
)"

# The exit without the group only protects the tail of the file.
expect "an exit with no group is refused" 1 "$NO_FOOT" -- \
  "$CP" "$(probe bad_exit_only <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo body
exit "$?"
EOF
)"

# A command above the `{` that is not preamble has already run when the rest of the file is read.
expect "a command above the group is refused" 1 "$NOT_FIRST" -- \
  "$CP" "$(probe bad_command_above <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
echo "this line has already run when the rest of the file is parsed"
{
echo body
exit "$?"
}
EOF
)"

# --- the preamble --------------------------------------------------------------------------
# A suite that sources a sibling library must do it above the group; see the guard's header, and
# the declare -F controls below, for what happens when it does it inside. So the shapes the source
# needs are let through, and only those.
expect "a preamble that loads a library may stand above the group" 0 "$PASSED" -- \
  "$CP" "$(probe good_preamble <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
export SHIP_PR_STALE_BASE=20 # a builtin, and read when the library is sourced
# shellcheck source=fixture-lib.sh
source "$SCRIPT_DIR/fixture-lib.sh"

{
echo body
exit "$?"
}
EOF
)"

# A directory resolved and nothing sourced under it is a fork the file is read after for nothing.
expect "a preamble that sources nothing is refused" 1 "does not end in a \`source\`" -- \
  "$CP" "$(probe bad_preamble_no_source <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd -P)
{
echo "$HERE"
exit "$?"
}
EOF
)"

# The shape the preamble exists to avoid: the library sourced from inside the group. The probe's
# source line is spelled through a placeholder, because the guard reads LINES and a heredoc's are
# lines too -- written out verbatim here, it would refuse this file (the guard's header says so).
BAD_INSIDE=$(probe bad_source_inside <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
{
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
source "$SCRIPT_DIR/@LIBRARY@"
newest() { echo "a suite helper that shadows the library"; }
exit "$?"
}
EOF
)
sed 's|@LIBRARY@|test-pr-review-lib.sh|' "$BAD_INSIDE" >"$BAD_INSIDE.filled" && mv "$BAD_INSIDE.filled" "$BAD_INSIDE"
grep -q '^source "\$SCRIPT_DIR/test-' "$BAD_INSIDE" ||
  ko "the placeholder in the bad_source_inside probe was never filled in, so the case below proves nothing"
expect "a sibling library sourced inside the group is refused" 1 "sources a sibling test library from INSIDE" -- \
  "$CP" "$BAD_INSIDE"

# Rule 3, and the reason rules 1 and 2 are not enough between them: this file opens with `{` and
# ends with the required foot, and the group is closed halfway down all the same. Only deleting
# the two wrapper lines shows it -- the orphaned `}` is then a syntax error.
expect "a group closed midway is refused though the head and foot are right" 1 "$NOT_THE_BRACE" -- \
  "$CP" "$(probe bad_closed_midway <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{
echo "inside the first group"
}
echo "outside every group -- this line is read after the group above has run"
{
echo "inside a second group"
exit "$?"
}
EOF
)"

# A file that does not parse is refused rather than passed: the wrapper-removal probe below would
# otherwise report the file's own syntax error as a group that closes in the wrong place.
expect "a file that does not parse is refused, not passed" 1 "does not parse" -- \
  "$CP" "$(probe bad_syntax <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
{
if [ 1 -eq 1 ]; then
echo "no fi"
exit "$?"
}
EOF
)"

# --- what the rule is FOR: a file appended to while it runs ------------------------------------
# The mechanism of ludics-lite#10 and #247, with the race taken out of it: the script appends to
# its OWN file as its last act, so the shell is guaranteed to be mid-run when the file grows.
# Without the group it comes back to the file for a next command, finds the appended line at the
# offset it left off at, and runs it. With the group, the next command was parsed before any of
# this ran, and it is the `exit`.

cat >"$TMP/append_plain.sh" <<'EOF'
#!/usr/bin/env bash
echo BODY_RAN
printf 'echo APPENDED_RAN\n' >>"$0"
EOF
cat >"$TMP/append_guarded.sh" <<'EOF'
#!/usr/bin/env bash
{
echo BODY_RAN
printf 'echo APPENDED_RAN\n' >>"$0"
exit "$?"
}
EOF
# Both files are read by the guard BEFORE they are run: each of them appends to itself, so after
# the run neither file has the tail it was written with -- which is the mechanism, seen from the
# other side.
expect "the guard passes the group that ignores what is appended" 0 "$PASSED" -- \
  "$CP" "$TMP/append_guarded.sh"
expect "the guard refuses the file that will read it" 1 "$NO_FOOT" -- "$CP" "$TMP/append_plain.sh"

out=$(bash "$TMP/append_plain.sh" 2>&1)
if grep -qF BODY_RAN <<<"$out" && grep -qF APPENDED_RAN <<<"$out"; then
  ok "without the group, a line appended while the script runs is read and executed"
else
  ko "the negative control did not resume at the appended line, so the case below proves nothing -- $out"
fi

out=$(bash "$TMP/append_guarded.sh" 2>&1)
if grep -qF BODY_RAN <<<"$out" && ! grep -qF APPENDED_RAN <<<"$out"; then
  ok "with the group, a line appended while the script runs is never read"
else
  ko "a line appended past the closing brace ran -- $out"
fi
# --- the dual-mode libraries -------------------------------------------------------------------
# test-pr-review-lib.sh and test-pr-review-base-lib.sh are sourced by the suites over them AND run
# on their own. Inside the group, their `[ "${BASH_SOURCE[0]}" = "$0" ] || return 0` dispatch ends
# the sourcing before the foot's `exit` is reached, so the caller survives with the definitions it
# came for. A dual-mode file that LOST that dispatch would take its caller down at the foot -- so
# the negative control is here, next to the property, and not only in the twelve suites that would
# go red together.

cat >"$TMP/dual_lib.sh" <<'EOF'
#!/usr/bin/env bash
{
LIBVAR=set-by-the-library
helper() { echo "the library's helper ran"; }
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
set -euo pipefail
echo "the library ran its own controls"
exit "$?"
}
EOF
cat >"$TMP/dual_caller.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$1"
echo "the caller survived the source, LIBVAR=$LIBVAR"
helper
EOF
out=$(bash "$TMP/dual_caller.sh" "$TMP/dual_lib.sh" 2>&1)
rc=$?
if [ "$rc" -eq 0 ] && grep -qF "the caller survived the source, LIBVAR=set-by-the-library" <<<"$out" &&
  grep -qF "the library's helper ran" <<<"$out" && ! grep -qF "its own controls" <<<"$out"; then
  ok "a library in the group hands its caller back alive, with its definitions"
else
  ko "sourcing a library in the group did not hand the caller back (rc=$rc) -- $out"
fi
expect "that library runs its own controls when executed" 0 "the library ran its own controls" -- \
  bash "$TMP/dual_lib.sh"
expect "and the guard passes it" 0 "$PASSED" -- "$CP" "$TMP/dual_lib.sh"
# The control: the same library with the dispatch removed reaches the foot's `exit` while sourced,
# and the caller never gets its next line. Without this, the case above would also pass against a
# library that simply never reached the foot for some other reason.
grep -v 'BASH_SOURCE\[0\]' "$TMP/dual_lib.sh" >"$TMP/dual_lib_nodispatch.sh"
out=$(bash "$TMP/dual_caller.sh" "$TMP/dual_lib_nodispatch.sh" 2>&1)
if ! grep -qF "the caller survived the source" <<<"$out"; then
  ok "a library with no dispatch exits its caller at the foot, which is what the dispatch prevents"
else
  ko "the negative control survived the source, so the dispatch is not what the case above tests -- $out"
fi

# --- why the sources go above the group ---------------------------------------------------------
# Bash binds the location `declare -F` reports for a function when it PARSES the definition. Inside
# a group that also holds the sources, every definition in the file is parsed before the library is
# read, so the library's binding lands last and the ludics-lite#46 shadow guard reads the suite's
# function as still the library's -- it refuses a declared `stub` (which is how
# test-pr-review-merge.sh and test-pr-review-watch.sh went red while this guard was written) and
# accepts an undeclared shadow in silence.
#
# What is asserted here is the invariant the rule delivers and not the defect it avoids: with the
# source above the group, the attribution is the same as with no group at all. The third probe's
# answer is printed rather than asserted, because a bash that binds at execution time instead would
# give it the suite's file and the rule would merely be unnecessary, not wrong. On the fleet's bash
# 3.2 and on this run it is the library's.
cat >"$TMP/attrib_lib.sh" <<'EOF'
#!/usr/bin/env bash
newest() { echo "the library's newest"; }
EOF
attrib() { # <name>: the file declare -F attributes `newest` to, after the probe redefines it
  bash "$TMP/$1.sh" 2>&1
}
cat >"$TMP/attrib_plain.sh" <<EOF
#!/usr/bin/env bash
source "$TMP/attrib_lib.sh"
newest() { echo "the suite's newest"; }
(shopt -s extdebug && declare -F newest) | awk '{ print \$3 }'
EOF
cat >"$TMP/attrib_preamble.sh" <<EOF
#!/usr/bin/env bash
source "$TMP/attrib_lib.sh"
{
newest() { echo "the suite's newest"; }
(shopt -s extdebug && declare -F newest) | awk '{ print \$3 }'
exit "\$?"
}
EOF
cat >"$TMP/attrib_inside.sh" <<EOF
#!/usr/bin/env bash
{
source "$TMP/attrib_lib.sh"
newest() { echo "the suite's newest"; }
(shopt -s extdebug && declare -F newest) | awk '{ print \$3 }'
exit "\$?"
}
EOF
plain_at=$(attrib attrib_plain)
preamble_at=$(attrib attrib_preamble)
inside_at=$(attrib attrib_inside)
if [ "$plain_at" = "$TMP/attrib_plain.sh" ] && [ "$preamble_at" = "$TMP/attrib_preamble.sh" ]; then
  ok "with the source above the group, a redefinition is attributed to the file that redefines it, exactly as with no group at all (inside the group, this bash answers $(basename "$inside_at"))"
else
  ko "the source above the group changed the attribution: plain=$plain_at preamble=$preamble_at inside=$inside_at"
fi

# --- the default sweep's scope -------------------------------------------------------------------
# With no arguments the guard reads every `test-*.sh` under `scripts/`, `*/scripts/` and
# `*/hooks/` -- the globs check-prompts.sh walks for the register -- plus the files named in
# ALSO_GUARDED. Exercised against scratch checkouts, because what has to be pinned is which files
# the argument-less sweep OPENS, and a probe passed by path says nothing about that.

# scratch_tree <name>: a scratch checkout with the guard installed where it lives here, so that
# running it with no arguments exercises the real default sweep over a tree we control. It comes
# with one good suite (so the sweep is never empty for the wrong reason) and a good
# post-merge-cleanup.sh (which ALSO_GUARDED requires to exist).
scratch_tree() {
  local d="$TMP/$1"
  mkdir -p "$d/scripts" "$d/ship-pr/scripts"
  cp "$CP" "$d/scripts/check-parse-guards.sh"
  chmod +x "$d/scripts/check-parse-guards.sh"
  cp "$TMP/good.sh" "$d/scripts/test-good.sh"
  cp "$TMP/good.sh" "$d/ship-pr/scripts/post-merge-cleanup.sh"
  printf '%s' "$d/scripts/check-parse-guards.sh"
}

# in_tree <tree> <path>: a file inside a scratch checkout, written from stdin.
in_tree() {
  mkdir -p "$TMP/$1/$(dirname "$2")"
  cat >"$TMP/$1/$2"
}

T=$(scratch_tree scope_skill_scripts)
in_tree scope_skill_scripts other-skill/scripts/test-thing.sh <<'EOF'
#!/usr/bin/env bash
echo "a suite in a skill nobody had written when the glob was"
EOF
expect "a suite in a second scripts directory is swept" 1 "$NO_FOOT" -- "$T"

T=$(scratch_tree scope_top_level)
in_tree scope_top_level scripts/test-toolbox.sh <<'EOF'
#!/usr/bin/env bash
echo "a suite in the top-level scripts directory"
EOF
expect "a suite in the top-level scripts directory is swept" 1 "$NO_FOOT" -- "$T"

T=$(scratch_tree scope_hooks)
in_tree scope_hooks other-skill/hooks/test-hook.sh <<'EOF'
#!/usr/bin/env bash
echo "a suite under a hooks directory"
EOF
expect "a suite under a hooks directory is swept" 1 "$NO_FOOT" -- "$T"

# Out of scope, and deliberately: python and pwsh read a script whole before running any of it, so
# the trap this guard is about does not exist there. A `.py` suite with no group must pass.
T=$(scratch_tree scope_python)
in_tree scope_python other-skill/scripts/test-thing.py <<'EOF'
print("a python suite, which has no brace group and needs none")
EOF
expect "a .py suite is not asked for a brace group" 0 "$PASSED" -- "$T"

# The scope is `test-*.sh` and the ALSO_GUARDED list, not every script: a helper that runs and
# exits in a second has no window to be edited in, and asking it for the shape would be noise.
T=$(scratch_tree scope_helper)
in_tree scope_helper other-skill/scripts/do-thing.sh <<'EOF'
#!/usr/bin/env bash
echo "a helper, not a suite"
EOF
expect "a non-test script is not asked for a brace group" 0 "$PASSED" -- "$T"

# ALSO_GUARDED is read, and it is what carries ludics-lite#10's other file.
T=$(scratch_tree scope_also_guarded)
in_tree scope_also_guarded ship-pr/scripts/post-merge-cleanup.sh <<'EOF'
#!/usr/bin/env bash
echo "the helper the cleanup suite runs once per case"
EOF
expect "a file named in ALSO_GUARDED is swept" 1 "$NO_FOOT" -- "$T"

# Fail closed on a scope that has stopped describing the checkout. An entry naming a file that is
# not there is a list nobody updated; an empty sweep is a clean verdict over nothing, which every
# head afterwards would read as a pass.
T=$(scratch_tree stale_entry)
rm -f "$TMP/stale_entry/ship-pr/scripts/post-merge-cleanup.sh"
expect "an ALSO_GUARDED entry naming a file that is gone is a usage error" 2 "the list in" -- "$T"

T=$(scratch_tree empty_sweep)
rm -f "$TMP/empty_sweep/scripts/test-good.sh"
expect "a sweep that matches no suite is a usage error, not a pass" 2 "no suites matched" -- "$T"
# ... and the emptiness is counted over the test globs alone: ALSO_GUARDED is a fixed list, and a
# sweep that found no suite at all must not be rescued by it into printing a clean verdict.
out=$("$T" 2>&1)
if ! grep -qF "$PASSED" <<<"$out"; then
  ok "an empty sweep prints no clean verdict, ALSO_GUARDED notwithstanding"
else
  ko "an empty sweep printed a clean verdict -- $out"
fi

# The annotation a refusal prints must be repo-relative: GitHub Actions resolves an `::error file=`
# against the workspace root, so the absolute path the sweep builds from ROOT would anchor the
# comment to no file in the diff and degrade the refusal to a bare log line.
T=$(scratch_tree relative_annotation)
in_tree relative_annotation other-skill/scripts/test-thing.sh <<'EOF'
#!/usr/bin/env bash
echo "a suite with no group"
EOF
expect "a sweep refusal annotates a repo-relative path" 1 '::error file=other-skill/scripts/test-thing.sh' -- "$T"
out=$("$T" 2>&1)
if grep -qE -- '::error file=/' <<<"$out"; then
  ko "a sweep refusal must not annotate an absolute path -- $out"
else
  ok "a sweep refusal does not annotate an absolute path"
fi
# That "must NOT appear" is only worth something if the absolute spelling could appear at all --
# an earlier suite here passed such a check against a guard with the fix torn out, because the
# string it looked for could never match (ludics-lite#197). It can: a file passed by a path outside
# the checkout has no relative spelling and keeps the one it was given, which is the case below.
expect "a file passed from outside the checkout is annotated as given" 1 "::error file=$TMP/bad_no_group.sh" -- \
  "$CP" "$TMP/bad_no_group.sh"

# --- usage ---------------------------------------------------------------------------------------

expect "a missing file is a usage error, not a pass" 2 "no such file" -- \
  "$CP" "$TMP/there-is-no-such-file.sh"
expect "--help prints the header" 0 "Bash reads a script file by OFFSET" -- "$CP" --help

# --- this checkout, and the head this guard was written for ----------------------------------------

expect "this checkout passes the guard" 0 "$PASSED" -- "$CP"

# test-fleet-worker.sh as it stood before ludics-lite#247: a ~1000-line, four-minute suite ending in
# a bare `[ "$fail" -eq 0 ]`. If this ever stops failing, the guard has stopped guarding.
BEFORE=4bfc1e954c4fbdfe8ef8d26bd2ce85210d910505
if git -C "$ROOT" show "${BEFORE}:issue-wave/scripts/test-fleet-worker.sh" >"$TMP/fleet-worker-before.sh" 2>/dev/null &&
  [ -s "$TMP/fleet-worker-before.sh" ]; then
  expect "the suite this guard was written for is refused as it stood" 1 "$NO_FOOT" -- \
    "$CP" "$TMP/fleet-worker-before.sh"
else
  # CI checks out at depth 1, so the pre-#247 blob is usually absent there. The probes above are
  # what hold the guard honest on every head; this one is the historical witness.
  ok "the pre-#247 test-fleet-worker.sh is not in this checkout (shallow clone); skipped"
fi

echo
printf '%s\n' "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
exit "$?"
}
