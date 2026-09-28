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
#     an orphan that inherited its output is stopped with it, and a worktree it locked still goes.
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
# signal_case SIG WANT_RC [MODE]: `set -m` gives the helper its own process group with default signal
# dispositions -- a non-interactive shell starts background jobs with INT ignored, and a signal
# ignored on entry cannot be trapped.
signal_case() {
  local sig=$1 want=$2 mode=${3:---slow} pidf="$TMP/suite.pid.$1${3-}" hpid spid i rc_s
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
if [ -n "$opid" ] && ! kill -0 "$opid" 2>/dev/null; then
  ok "the orphan is stopped with the suite"
else
  ko "the orphan ($opid) outlived the helper"
  [ -n "$opid" ] && kill -KILL "$opid" 2>/dev/null
fi
worktrees_clean "after an orphaned child"

# A suite that locks its own worktree: a single --force refuses a locked one.
run_rab test-toy.sh --lock
if [ "$rc" -eq 1 ]; then ok "a locked worktree: the suite's status is still reported"; else ko "lock: rc=$rc -- $out"; fi
worktrees_clean "after the suite locked its worktree"

printf '\n%s\n' "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
exit "$?"
}
