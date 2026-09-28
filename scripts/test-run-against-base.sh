#!/usr/bin/env bash
# Exercises run-against-base.sh against a scratch repo: a bare origin whose main is a base
# commit carrying a buggy toy library and its suite, and a clone whose WORKING TREE fixes the
# library and adds a case to the suite that the base's library fails. What it pins:
#   - the helper runs the working tree's suite against the base's library and reports the base
#     failure -- the suite's own exit status and its pass/fail line -- while the same suite passes
#     in the working tree (the control that the failure is the base's, not the suite's);
#   - only the suite is copied: the working tree's fixed library never reaches the base run;
#   - the base copy is a real git checkout (the `git archive` shape broke a case in the
#     2026-09-28 wave), a suite new in the working tree runs too, and suite arguments pass through;
#   - --base <ref> picks another base, and a fixed one passes;
#   - a refusal (unknown ref, a suite outside the checkout) exits 125, never the suite's status;
#   - every exit path, TERM and INT during the run included, leaves no worktree registered, no
#     scratch directory under $TMPDIR, the suite process gone, and the checkout's status as it was;
#   - nothing the suite does holds the helper: a suite that ignores TERM is killed after the grace,
#     an orphan that inherited its output is stopped with it, and a worktree it locked still goes;
#     a left-behind child with a TERM cleanup of its own gets the whole grace to finish it;
#   - whatever the base keeps on the suite's path -- a symlink out of the checkout at the leaf or
#     at a parent, a directory where the suite now is -- is replaced, never followed or written
#     through, and nothing is created outside the worktree;
#   - a suite named with a leading dash, or ending in a newline, runs that very file; a `--`
#     directory on the suite's path installs; a working-tree suite that is a symlink is refused
#     rather than followed;
#   - a path inside .git is refused, and a suite that cannot be started (a missing interpreter,
#     directly or behind `#!/usr/bin/env`) exits 125 rather than its exec error's 126/127;
#   - an unreadable directory the suite leaves behind does not leak the scratch;
#   - git's repository-local variables exported by the caller (GIT_DIR, GIT_WORK_TREE) do not
#     reach the suite;
#   - a second signal during the cleanup does not cut the teardown short;
#   - RUN_AGAINST_BASE_GRACE is validated up front, and a suite's own 125 exits 1.
#
# Usage: test-run-against-base.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

# One brace group, so bash parses this file WHOLE before its first line runs and an edit landing
# while a run is in flight cannot resume the shell at a shifted offset; the `exit` at the foot
# means the shell never comes back to the file for a next command (ludics-lite#10, #247).
{
HERE=$(cd "$(dirname "$0")" && pwd -P)
RAB="$HERE/run-against-base.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/run-against-base-test.XXXXXX") || exit 1
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

g() { git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main "$@"; }

# The helper's scratch directories go here, so "nothing left behind" is a directory listing.
HTMP="$TMP/htmp"
mkdir -p "$HTMP"

g init -q --bare "$TMP/origin.git"
R="$TMP/repo"
g init -q "$R"
mkdir -p "$R/scripts"
cat >"$R/scripts/lib.sh" <<'EOF'
add() { echo $(($1 - $2)); }
EOF
cat >"$R/scripts/test-toy.sh" <<'EOF'
#!/usr/bin/env bash
HERE=$(cd "$(dirname "$0")" && pwd -P)
. "$HERE/lib.sh"
pass=0; fail=0
[ "$(add 2 0)" = 2 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: add 2 0"; }
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
EOF
chmod +x "$R/scripts/test-toy.sh"
g -C "$R" add -A
g -C "$R" commit -qm base
g -C "$R" remote add origin "$TMP/origin.git"
g -C "$R" push -q origin main
g -C "$R" fetch -q origin
BASE_SHA=$(git -C "$R" rev-parse HEAD)

# A fixed library committed on a side branch, for --base.
g -C "$R" checkout -qb fixed
printf '%s\n' 'add() { echo $(($1 + $2)); }' >"$R/scripts/lib.sh"
g -C "$R" commit -qam fix
g -C "$R" checkout -q main

# A base that keeps a suite path as a symlink to a file outside the checkout.
printf '%s\n' 'VICTIM' >"$TMP/victim.sh"
g -C "$R" checkout -qb linked
ln -s "$TMP/victim.sh" "$R/scripts/test-link.sh"
# ...a parent directory kept as a symlink out of the checkout, and a directory where the working
# tree has a suite file.
mkdir -p "$TMP/outdir" "$R/scripts/test-dir"
ln -s "$TMP/outdir" "$R/scripts/lnk"
printf 'x\n' >"$R/scripts/test-dir/x"
g -C "$R" add -A
g -C "$R" commit -qm link
g -C "$R" checkout -q main

# The working tree: the fix, plus a case the base fails, a git probe, and an argument echo.
printf '%s\n' 'add() { echo $(($1 + $2)); }' >"$R/scripts/lib.sh"
cat >"$R/scripts/test-toy.sh" <<'EOF'
#!/usr/bin/env bash
HERE=$(cd "$(dirname "$0")" && pwd -P)
. "$HERE/lib.sh"
pass=0; fail=0
[ "$(add 2 0)" = 2 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: add 2 0"; }
[ "$(add 2 3)" = 5 ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: add 2 3"; }
top=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null) || top=NONE
echo "TOPLEVEL=$(cd "$top" 2>/dev/null && pwd -P || echo NONE) HERE=$HERE"
echo "ARGS=[$*]"
case "${1-}" in
--slow) echo "$$" >"$2"; exec sleep 60 ;;
--stubborn) trap '' TERM; echo "$$" >"$2"; while :; do sleep 1; done ;;
--orphan) sleep 60 & echo "$!" >"$2" ;;
--graceful)
  # The ready file is the handshake: the suite exits only once the child's TERM trap is armed,
  # or the helper's TERM can land before it and the default action skips the cleanup.
  ( trap 'sleep 1; echo done >"$2"; exit 0' TERM; : >"$2.ready"; sleep 60 & wait ) >/dev/null 2>&1 &
  for i in $(seq 1 300); do [ -e "$2.ready" ] && break; sleep 0.1; done ;;
--rc125) exit 125 ;;
--lockout) mkdir -p "$HERE/sealed/d" && : >"$HERE/sealed/d/f" && chmod 000 "$HERE/sealed/d" ;;
--lock) git -C "$HERE" worktree lock "$(git -C "$HERE" rev-parse --show-toplevel)" ;;
esac
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
EOF
cat >"$R/scripts/test-new.sh" <<'EOF'
#!/usr/bin/env bash
echo "1 passed, 0 failed"
EOF
chmod +x "$R/scripts/test-new.sh"
cat >"$R/scripts/test-link.sh" <<'EOF'
#!/usr/bin/env bash
echo "1 passed, 0 failed"
EOF
chmod +x "$R/scripts/test-link.sh"
cp -p "$R/scripts/test-link.sh" "$R/scripts/-check.sh"
# A name ending in a newline, beside the same name without it (which must not be the one run).
cp -p "$R/scripts/test-link.sh" "$R/scripts/test-nl.sh"$'\n'
printf '#!/usr/bin/env bash\necho "WRONG FILE"\nexit 3\n' >"$R/scripts/test-nl.sh"
chmod +x "$R/scripts/test-nl.sh"
printf '#!/usr/bin/env run-against-base-no-such-interpreter\nexit 1\n' >"$R/scripts/test-envmiss.sh"
chmod +x "$R/scripts/test-envmiss.sh"
printf '#!/usr/bin/env -S run-against-base-no-such-interpreter --flag\nexit 1\n' >"$R/scripts/test-envS.sh"
chmod +x "$R/scripts/test-envS.sh"
printf '#!/usr/bin/env -S bash -e\necho "ARGS=[$*]"\necho "1 passed, 0 failed"\n' >"$R/scripts/test-envSok.sh"
chmod +x "$R/scripts/test-envSok.sh"
mkdir -p "$TMP/interp-bin"
printf '#!/bin/sh\nexec bash "$@"\n' >"$TMP/interp-bin/rab-private-interp"
chmod +x "$TMP/interp-bin/rab-private-interp"
printf '#!/usr/bin/env -S PATH=/definitely/no/such/path bash\nexit 0\n' >"$R/scripts/test-envPATHbad.sh"
printf '#!/usr/bin/env -S PATH=%s:/usr/bin:/bin rab-private-interp\necho "1 passed, 0 failed"\n' "$TMP/interp-bin" >"$R/scripts/test-envPATHok.sh"
chmod +x "$R/scripts/test-envPATHbad.sh" "$R/scripts/test-envPATHok.sh"
mkdir -p "$R/scripts/--"
cp -p "$R/scripts/test-link.sh" "$R/scripts/--/test-dash.sh"
# An executable suite outside git, so only the symlink refusal can stop it running.
cp -p "$R/scripts/test-link.sh" "$TMP/outside-suite.sh"
ln -s "$TMP/outside-suite.sh" "$R/scripts/test-symleaf.sh"
printf '#!/nonexistent/interpreter\necho "1 passed, 1 failed"\nexit 1\n' >"$R/scripts/test-noexec.sh"
chmod +x "$R/scripts/test-noexec.sh"
printf '#!/usr/bin/env bash\nexit 0\n' >"$R/.git/hooks/test-meta"
chmod +x "$R/.git/hooks/test-meta"
mkdir -p "$R/scripts/lnk/deep"
cp -p "$R/scripts/test-link.sh" "$R/scripts/lnk/deep/test-deep.sh"
cp -p "$R/scripts/test-link.sh" "$R/scripts/test-dir"
status_before=$(git -C "$R" status --porcelain)

# worktrees_clean LABEL: nothing but the checkout itself registered, and no helper scratch left.
worktrees_clean() {
  local n left
  n=$(git -C "$R" worktree list --porcelain | grep -c '^worktree ')
  left=$(ls -A "$HTMP")
  if [ "$n" -eq 1 ] && [ -z "$left" ]; then
    ok "$1: no worktree registered, no scratch left"
  else
    ko "$1: $n worktrees registered, scratch left: [$left] -- $(git -C "$R" worktree list)"
  fi
}

# run_rab ARGS...: the helper from inside the scratch checkout; sets $out and $rc.
run_rab() {
  out=$(cd "$R/scripts" && TMPDIR="$HTMP" RUN_AGAINST_BASE_GRACE=1 "$RAB" "$@" 2>&1)
  rc=$?
}

# ---- the control: the working tree's suite passes on the working tree ------------------------
wt_out=$(cd "$R" && scripts/test-toy.sh 2>&1)
wt_rc=$?
if [ "$wt_rc" -eq 0 ] && grep -qF '2 passed, 0 failed' <<<"$wt_out"; then
  ok "control: the new suite passes in the working tree"
else
  ko "control: the new suite should pass in the working tree (rc=$wt_rc) -- $wt_out"
fi

# ---- the negative control: default base origin/main ----------------------------------------
run_rab test-toy.sh one two
if [ "$rc" -eq 1 ]; then ok "base run exits with the suite's status (1)"; else ko "base run rc=$rc want 1 -- $out"; fi
if grep -qF 'FAIL: add 2 3' <<<"$out"; then
  ok "the working tree's new case ran, against the base library"
else
  ko "the new case should fail on the base library -- $out"
fi
if grep -qF 'run-against-base: exit 1 on origin/main: 1 passed, 1 failed' <<<"$out"; then
  ok "reports exit status and pass/fail line"
else
  ko "missing the report line -- $out"
fi
if grep -qF "against origin/main ($(git -C "$R" rev-parse --short "$BASE_SHA"))" <<<"$out"; then
  ok "names the base and its commit"
else
  ko "should name origin/main and its short sha -- $out"
fi
here=$(sed -n 's/^TOPLEVEL=\([^ ]*\) HERE=\(.*\)$/\2/p' <<<"$out")
top=$(sed -n 's/^TOPLEVEL=\([^ ]*\) HERE=.*$/\1/p' <<<"$out")
if [ -n "$here" ] && [ "$top/scripts" = "$here" ] && case "$here" in "$HTMP"/*) true ;; *) false ;; esac; then
  ok "the base copy is a git checkout under \$TMPDIR, and the suite ran from it"
else
  ko "want a git toplevel under $HTMP holding the suite; got TOPLEVEL=$top HERE=$here"
fi
if grep -qF 'ARGS=[one two]' <<<"$out"; then ok "suite arguments pass through"; else ko "args lost -- $out"; fi
worktrees_clean "after a failing base run"
if [ "$(git -C "$R" status --porcelain)" = "$status_before" ]; then
  ok "the checkout's working tree is untouched"
else
  ko "working tree changed: $(git -C "$R" status --porcelain)"
fi

# ---- --base: a fixed base passes; a suite new in the working tree runs ------------------------
run_rab test-toy.sh --base fixed
if [ "$rc" -eq 0 ] && grep -qF 'run-against-base: exit 0 on fixed: 2 passed, 0 failed' <<<"$out"; then
  ok "--base fixed: the suite passes"
else
  ko "--base fixed: rc=$rc -- $out"
fi
worktrees_clean "after a passing base run"
run_rab "$R/scripts/test-new.sh"
if [ "$rc" -eq 0 ] && grep -qF 'exit 0 on origin/main: 1 passed, 0 failed' <<<"$out"; then
  ok "a suite absent from the base (absolute path) runs"
else
  ko "new suite: rc=$rc -- $out"
fi

# ---- refusals exit 125 and leave nothing ------------------------------------------------------
run_rab test-toy.sh --base no-such-ref
if [ "$rc" -eq 125 ] && grep -qF 'no such commit: no-such-ref' <<<"$out"; then
  ok "unknown base refused with 125"
else
  ko "unknown base: rc=$rc -- $out"
fi
printf '#!/usr/bin/env bash\n' >"$TMP/outside.sh"
chmod +x "$TMP/outside.sh"
run_rab "$TMP/outside.sh"
if [ "$rc" -eq 125 ] && grep -qF 'is not inside this checkout' <<<"$out"; then
  ok "a suite outside the checkout refused with 125"
else
  ko "outside suite: rc=$rc -- $out"
fi
run_rab test-missing.sh
if [ "$rc" -eq 125 ]; then ok "a missing suite refused with 125"; else ko "missing suite: rc=$rc -- $out"; fi
worktrees_clean "after refusals"

# ---- a signal mid-run: the worktree still goes, and so does the suite ------------------------
# signal_case SIG WANT_RC [MODE [twice]]: `set -m` gives the helper its own process group with default signal
# dispositions -- a non-interactive shell starts background jobs with INT ignored, and a signal
# ignored on entry cannot be trapped.
signal_case() {
  local sig=$1 want=$2 mode=${3:---slow} pidf="$TMP/suite.pid.$1${3-}${4-}" hpid spid i rc_s
  rm -f "$pidf"
  set -m
  (cd "$R/scripts" && TMPDIR="$HTMP" RUN_AGAINST_BASE_GRACE=1 exec "$RAB" test-toy.sh "$mode" "$pidf") >"$TMP/sig.$sig.out" 2>&1 &
  hpid=$!
  set +m
  for i in $(seq 1 300); do
    [ -s "$pidf" ] && break
    sleep 0.1
  done
  spid=$(cat "$pidf" 2>/dev/null)
  if [ -z "$spid" ]; then
    ko "$sig: the suite never started -- $(cat "$TMP/sig.$sig.out")"
    kill -KILL "$hpid" 2>/dev/null
    return
  fi
  kill -"$sig" "$hpid"
  # A second signal inside the cleanup's grace must not cut the teardown short.
  [ "${4-}" = twice ] && sleep 0.5 && kill -"$sig" "$hpid" 2>/dev/null
  # Bounded: a helper that waits forever on a suite ignoring TERM is the regression this case is
  # for, and it must fail here rather than hang the run. An exited helper is a zombie until
  # waited for, and kill -0 reaches a zombie, so the state is read instead.
  for i in $(seq 1 300); do
    case $(ps -o stat= -p "$hpid" 2>/dev/null) in '' | Z*) break ;; esac
    sleep 0.1
  done
  if case $(ps -o stat= -p "$hpid" 2>/dev/null) in '' | Z*) false ;; *) true ;; esac then
    ko "$sig: the helper was still running 30s after $sig"
    kill -KILL -- "-$hpid" "-$spid" 2>/dev/null
  fi
  wait "$hpid"
  rc_s=$?
  if [ "$rc_s" -eq "$want" ]; then ok "$sig: helper exits $want"; else ko "$sig: helper rc=$rc_s want $want"; fi
  for i in $(seq 1 50); do
    kill -0 "$spid" 2>/dev/null || break
    sleep 0.1
  done
  if kill -0 "$spid" 2>/dev/null; then
    ko "$sig: the suite ($spid) outlived the helper"
    kill -KILL "$spid" 2>/dev/null
  else
    ok "$sig: the suite is gone"
  fi
  worktrees_clean "after $sig mid-run"
}
signal_case TERM 143
signal_case INT 130
# A suite that ignores TERM: the helper's own wait is bounded, and KILL follows the grace.
signal_case TERM 143 --stubborn
signal_case TERM 143 --stubborn twice

# ---- what the suite leaves behind is not the helper's to wait on ------------------------------
# An orphan that inherited the suite's stdout holds the output pipe open after the suite exits;
# the helper must still report and clean up promptly, and the orphan must not outlive it.
SECONDS=0
run_rab test-toy.sh --orphan "$TMP/orphan.pid"
took=$SECONDS
opid=$(cat "$TMP/orphan.pid" 2>/dev/null)
if [ "$rc" -eq 1 ] && [ "$took" -lt 20 ] && grep -qF 'exit 1 on origin/main: 1 passed, 1 failed' <<<"$out"; then
  ok "an orphan holding the output does not hold the helper (${took}s)"
else
  ko "orphan: rc=$rc after ${took}s -- $out"
fi
# A killed orphan can sit as a zombie until init reaps it, and kill -0 reaches a zombie.
if [ -n "$opid" ] && case $(ps -o stat= -p "$opid" 2>/dev/null) in '' | Z*) true ;; *) false ;; esac then
  ok "the orphan is stopped with the suite"
else
  ko "the orphan ($opid) outlived the helper"
  [ -n "$opid" ] && kill -KILL "$opid" 2>/dev/null
fi
worktrees_clean "after an orphaned child"

# A background child with a TERM cleanup of its own gets the grace, not a fixed moment: the group
# is what is waited for, not the leader that has already exited.
rm -f "$TMP/graceful.done" "$TMP/graceful.done.ready"
out=$(cd "$R/scripts" && TMPDIR="$HTMP" RUN_AGAINST_BASE_GRACE=4 "$RAB" test-toy.sh --graceful "$TMP/graceful.done" 2>&1)
rc=$?
if [ "$rc" -eq 1 ] && [ -s "$TMP/graceful.done" ]; then
  ok "a left-behind child's TERM cleanup completes within the grace"
else
  ko "graceful: rc=$rc, marker $( [ -s "$TMP/graceful.done" ] && echo present || echo absent) -- $out"
fi
worktrees_clean "after a graceful child"

# A base whose suite path is a symlink out of the checkout: removed, never written through.
run_rab test-link.sh --base linked
if [ "$rc" -eq 0 ] && [ "$(cat "$TMP/victim.sh")" = VICTIM ]; then
  ok "a symlinked suite path in the base is replaced, not written through"
else
  ko "symlink: rc=$rc, victim now: $(cat "$TMP/victim.sh") -- $out"
fi
worktrees_clean "after a symlinked base path"

# A parent component the base keeps as a symlink is replaced, not followed -- not even by mkdir.
run_rab lnk/deep/test-deep.sh --base linked
if [ "$rc" -eq 0 ] && [ -z "$(ls -A "$TMP/outdir")" ]; then
  ok "a symlinked parent in the base is replaced: nothing created outside the worktree"
else
  ko "parent symlink: rc=$rc, outdir holds [$(ls -A "$TMP/outdir")] -- $out"
fi
# A directory in the base where the working tree has the suite file: a path-type change.
run_rab test-dir --base linked
if [ "$rc" -eq 0 ]; then ok "a base directory at the suite's path is replaced"; else ko "dir at suite path: rc=$rc -- $out"; fi
worktrees_clean "after replacing base paths"

# A suite name that starts with a dash is a file, not an option.
run_rab -check.sh
if [ "$rc" -eq 0 ]; then ok "a suite named -check.sh runs"; else ko "leading dash: rc=$rc -- $out"; fi
# A trailing newline is part of the name: the suite named so runs, not its newline-free twin.
run_rab "test-nl.sh"$'\n'
if [ "$rc" -eq 0 ] && ! grep -qF 'WRONG FILE' <<<"$out"; then
  ok "a suite name ending in a newline runs that file"
else
  ko "trailing newline: rc=$rc -- $out"
fi
# A directory literally named `--` is a path component like any other.
run_rab ./--/test-dash.sh
if [ "$rc" -eq 0 ]; then ok "a \`--\` directory on the suite's path installs"; else ko "-- component: rc=$rc -- $out"; fi
# A suite path that is itself a symlink (here, out of the checkout) is refused, not followed.
run_rab test-symleaf.sh
if [ "$rc" -eq 125 ] && grep -qF 'is a symlink' <<<"$out"; then
  ok "a symlinked suite in the working tree is refused"
else
  ko "symlink leaf: rc=$rc -- $out"
fi
# A caller exporting git's repository-local variables (as a git hook does): the suite's git must
# still see the base worktree, not the caller's checkout.
out=$(cd "$R/scripts" && GIT_DIR="$R/.git" GIT_WORK_TREE="$R" TMPDIR="$HTMP" "$RAB" test-toy.sh 2>&1)
rc=$?
top=$(sed -n 's/^TOPLEVEL=\([^ ]*\) HERE=.*$/\1/p' <<<"$out")
if [ "$rc" -eq 1 ] && case "$top" in "$HTMP"/*) true ;; *) false ;; esac; then
  ok "GIT_DIR/GIT_WORK_TREE from the caller do not reach the suite"
else
  ko "git env: rc=$rc TOPLEVEL=$top -- $out"
fi
worktrees_clean "after a caller with git's local variables"
# A suite in a nested repository (as a submodule's would be) is refused from the outer one: the
# outer base holds none of its neighbours.
g init -q "$R/sub"
cp -p "$R/scripts/test-link.sh" "$R/sub/test-sub.sh"
run_rab ../sub/test-sub.sh
if [ "$rc" -eq 125 ] && grep -qF 'nested repository' <<<"$out"; then
  ok "a suite inside a nested repository is refused from the outer checkout"
else
  ko "nested repo: rc=$rc -- $out"
fi
rm -rf "$R/sub"
# A suite under .git is not a working-tree file.
run_rab "$R/.git/hooks/test-meta"
if [ "$rc" -eq 125 ] && grep -qF 'inside a .git directory' <<<"$out"; then
  ok "a path inside .git is refused"
else
  ko ".git path: rc=$rc -- $out"
fi
# ...and so did one whose `#!/usr/bin/env <prog>` names a program that is not on PATH, which the
# exec cannot see (env itself starts).
run_rab test-envmiss.sh
if [ "$rc" -eq 125 ] && grep -qF 'not on PATH' <<<"$out"; then
  ok "an env shebang naming a missing interpreter exits 125, not env's 127"
else
  ko "env interpreter: rc=$rc -- $out"
fi
# The `-S` form, as common as the plain one: a missing program behind it is caught the same way,
# and a present one runs with the suite's arguments intact.
run_rab test-envS.sh
if [ "$rc" -eq 125 ] && grep -qF 'not on PATH' <<<"$out"; then
  ok "an env -S shebang naming a missing interpreter exits 125"
else
  ko "env -S missing: rc=$rc -- $out"
fi
if [ "$(uname)" = Darwin ] || env -S true 2>/dev/null; then
  run_rab test-envSok.sh -- a
  if [ "$rc" -eq 0 ] && grep -qF 'ARGS=[-- a]' <<<"$out"; then
    ok "an env -S shebang with its program present runs, arguments intact"
  else
    ko "env -S present: rc=$rc -- $out"
  fi
fi
# A PATH= in the shebang is the PATH env searches: bash is on ours and not on that one, and a
# private interpreter is on that one and not on ours.
if [ "$(uname)" = Darwin ] || env -S true 2>/dev/null; then
  run_rab test-envPATHbad.sh
  if [ "$rc" -eq 125 ] && grep -qF 'not on the PATH its shebang sets' <<<"$out"; then
    ok "a program missing from the shebang's own PATH= exits 125"
  else
    ko "env PATH= bad: rc=$rc -- $out"
  fi
  run_rab test-envPATHok.sh
  if [ "$rc" -eq 0 ]; then
    ok "a program found only on the shebang's own PATH= runs"
  else
    ko "env PATH= ok: rc=$rc -- $out"
  fi
fi
# A suite whose interpreter is missing never ran: that is the helper's 125, not a base failure.
run_rab test-noexec.sh
if [ "$rc" -eq 125 ] && grep -qF 'it never ran' <<<"$out"; then
  ok "a suite that cannot be started exits 125, not 126/127"
else
  ko "exec failure: rc=$rc -- $out"
fi
worktrees_clean "after path-shape cases"

# The grace is validated before anything is allocated; a suite's own 125 is not the helper's.
out=$(cd "$R/scripts" && TMPDIR="$HTMP" RUN_AGAINST_BASE_GRACE=0.5 "$RAB" test-toy.sh 2>&1)
rc=$?
if [ "$rc" -eq 125 ] && grep -qF 'must be whole seconds' <<<"$out"; then
  ok "a fractional grace is refused up front"
else
  ko "grace 0.5: rc=$rc -- $out"
fi
out=$(cd "$R/scripts" && TMPDIR="$HTMP" RUN_AGAINST_BASE_GRACE=09 "$RAB" test-toy.sh 2>&1)
rc=$?
if [ "$rc" -eq 1 ]; then ok "a zero-padded grace (09) is read as decimal"; else ko "grace 09: rc=$rc -- $out"; fi
run_rab test-toy.sh --rc125
if [ "$rc" -eq 1 ] && grep -qF 'exit 125 on origin/main' <<<"$out"; then
  ok "a suite's own 125 is reported, and exits 1"
else
  ko "suite 125: rc=$rc -- $out"
fi
worktrees_clean "after grace and 125 cases"

# A suite that leaves an unreadable directory behind: the scratch still goes (as root the
# permissions never bite, so this passes trivially there).
run_rab test-toy.sh --lockout
if [ "$rc" -eq 1 ]; then ok "an unreadable leftover: the suite's status is reported"; else ko "lockout: rc=$rc -- $out"; fi
worktrees_clean "after an unreadable leftover"

# A suite that locks its own worktree: a single --force refuses a locked one.
run_rab test-toy.sh --lock
if [ "$rc" -eq 1 ]; then ok "a locked worktree: the suite's status is still reported"; else ko "lock: rc=$rc -- $out"; fi
worktrees_clean "after the suite locked its worktree"

printf '\n%s\n' "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
exit "$?"
}
