#!/usr/bin/env bash
# Exercises bg-run.sh with real background processes in a scratch directory -- no network, no
# harness. The command under test is always a small `sh -c` fixture, and every wait runs with a
# 1 s poll (BG_RUN_POLL=1) so the suite takes seconds rather than the production cadence.
#
# What it pins:
#   - a finished run reads rc=<its exit status> with exit 0, whatever that status is, and the
#     background `start` itself exits with it too;
#   - race 1: a task killed before its command returned (so no rc is ever written) reads DIED,
#     promptly, rather than RUNNING until the window is spent -- with RUNNING as the control
#     while it was alive;
#   - race 2: output that quotes `rc=`, DIED or REFUSED cannot settle a wait, because the status is
#     a file the command's output does not reach: the wait reads RUNNING while that output sits
#     in the log, and then the real status;
#   - race 3: a wait that runs before the pid is published reads STARTING, never DIED -- on an
#     absent directory and on an empty one -- gives up on it after the start grace rather than
#     the whole window, and a wait already polling when `start` runs picks the run up;
#   - a stale directory: `start` refuses one that already holds a run, finished or live, runs
#     nothing, leaves the earlier status untouched, and a wait on it reads REFUSED, not the
#     earlier run's rc;
#   - two starts racing on one fresh directory: exactly one runs its command, the other is refused;
#   - the finish-between-reads order: a dead pid beside an rc reads rc, not DIED;
#   - the usage errors (relative directory, missing `--`, a --within that is not a number);
#   - when zsh is installed, a start issued through `zsh -c` the way the Bash tool issues it,
#     with its arguments passed through intact.
#
# Usage: test-bg-run.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

# One brace group, so bash parses this file WHOLE before its first line runs and an edit landing
# while a run is in flight cannot resume the shell at a shifted offset; the `exit` at the foot
# means the shell never comes back to the file for a next command. Two lines here and two at the
# foot, with the body's own indentation untouched (ludics-lite#10, #247); scripts/check-parse-guards.sh
# checks the shape.
{
HERE=$(cd "$(dirname "$0")" && pwd)
BG="$HERE/bg-run.sh"
export BG_RUN_POLL=1
TMP=$(mktemp -d "${TMPDIR:-/tmp}/bg-run-test.XXXXXX") || exit 1
# Physical path, so the directories the cases name are the ones bg-run.sh sees; on macOS $TMPDIR
# sits under /var, a link to /private/var.
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
# Every background process a case starts is recorded here and killed on the way out, so a failed
# case cannot leave a sleeper behind.
BGPIDS=
trap 'for p in $BGPIDS; do kill -9 "$p" 2>/dev/null; done; rm -rf "$TMP"' EXIT
# From inside it, so the relative-directory cases below cannot touch the caller's tree.
cd "$TMP" || exit 1

pass=0; fail=0
# Both report and then RETURN 0 explicitly, for the `<test> && ok ... || ko ...` house style.
ok() { pass=$((pass + 1)); echo "PASS: $*"; return 0; }
ko() { fail=$((fail + 1)); echo "FAIL: $*"; return 0; }
contains() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# expect <label> <want-rc> <want-substring> -- <cmd...>; leaves the output in $out, rc in $rc.
expect() {
  local label="$1" want_rc="$2" want="$3"; shift 3; [ "$1" = -- ] && shift
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && contains "$out" "$want"; then ok "$label"
  else ko "$label (rc=$rc want $want_rc; want /$want/) -- $out"; fi
}
# until_file <path> <seconds>: poll for a nonempty file; 0 once it is there.
until_file() {
  local i=0
  while [ "$i" -lt $(($2 * 5)) ]; do [ -s "$1" ] && return 0; sleep 0.2; i=$((i + 1)); done
  return 1
}
# bg_start <dir> <cmd...>: `start` in the background, the way the Bash tool runs it; its pid in S.
bg_start() {
  local d=$1; shift
  "$BG" start "$d" -- "$@" > /dev/null 2>&1 &
  S=$!; BGPIDS="$BGPIDS $S"
}

# --- a finished run ------------------------------------------------------------------------------
d="$TMP/finished"
bg_start "$d" sh -c 'echo hello; exit 7'
expect "a finished run reads rc=7, exit 0" 0 'rc=7' -- "$BG" wait "$d" --within 20
wait "$S"; src=$?
[ "$src" -eq 7 ] && ok "...and the background start exits with the command's status" \
  || ko "the background start exited $src, want 7"
[ "$(cat "$d/log")" = hello ] && ok "...and the command's output is in log" \
  || ko "log holds: $(cat "$d/log")"
[ "$(ls -A "$d" | tr '\n' ' ')" = "log pid rc " ] && ok "...and the directory holds log, pid, rc and nothing else" \
  || ko "the directory holds: $(ls -A "$d" | tr '\n' ' ')"
d="$TMP/finished0"
bg_start "$d" true
expect "a run exiting 0 reads rc=0" 0 'rc=0' -- "$BG" wait "$d" --within 20

# --- race 1: the task is killed before the command returns ---------------------------------------
d="$TMP/killed"
bg_start "$d" sh -c 'echo "$$" > "$0"; exec sleep 60' "$TMP/killed.child"
if until_file "$d/pid" 10 && until_file "$TMP/killed.child" 10; then
  child=$(cat "$TMP/killed.child"); BGPIDS="$BGPIDS $child"
  expect "control: while the task lives, a wait reads RUNNING (exit 3)" 3 RUNNING -- "$BG" wait "$d" --within 0
  kill -9 "$S" "$child" 2>/dev/null
  { wait "$S"; } 2>/dev/null
  t0=$SECONDS
  expect "race 1: a killed task that wrote no rc reads DIED (exit 5)" 5 DIED -- "$BG" wait "$d" --within 30
  [ $((SECONDS - t0)) -le 3 ] && ok "...at once, not at the end of the window" \
    || ko "DIED took $((SECONDS - t0)) s of a 30 s window"
  [ ! -e "$d/rc" ] && ok "...and no rc was invented for it" || ko "an rc appeared: $(cat "$d/rc")"
else
  ko "race 1: the fixture task never published its pid"
fi

# --- race 2: the command's output quotes the verdicts --------------------------------------------
d="$TMP/quoting"
bg_start "$d" sh -c 'printf "rc=0\nDIED\nREFUSED: no\n"; sleep 3; exit 7'
if until_file "$d/log" 10; then
  expect "race 2: output quoting rc=0 does not settle the wait (RUNNING)" 3 RUNNING -- "$BG" wait "$d" --within 0
  expect "...and the wait then reads the command's real status" 0 'rc=7' -- "$BG" wait "$d" --within 20
  contains "$(cat "$d/log")" 'rc=0' && ok "...while the log still quotes rc=0" \
    || ko "the log lost its rc=0 line: $(cat "$d/log")"
else
  ko "race 2: the fixture command wrote no log"
fi

# --- race 3: the wait runs before the pid is published -------------------------------------------
d="$TMP/absent"
expect "race 3: no directory yet reads STARTING (exit 4), not DIED" 4 STARTING -- \
  env BG_RUN_START_GRACE=60 "$BG" wait "$d" --within 1
[ ! -e "$d" ] && ok "...and the wait created nothing" || ko "the wait created $d"
d="$TMP/empty"; mkdir -p "$d"
expect "race 3: an empty directory reads STARTING, not DIED" 4 STARTING -- \
  env BG_RUN_START_GRACE=60 "$BG" wait "$d" --within 1
t0=$SECONDS
expect "race 3: no pid within the start grace reads STARTING" 4 STARTING -- \
  env BG_RUN_START_GRACE=2 "$BG" wait "$TMP/never" --within 540
[ $((SECONDS - t0)) -le 6 ] && ok "...after the grace, not the 540 s window" \
  || ko "STARTING took $((SECONDS - t0)) s with a 2 s grace"
d="$TMP/late"
"$BG" wait "$d" --within 30 > "$TMP/late.out" 2>&1 &
W=$!; BGPIDS="$BGPIDS $W"
sleep 2
bg_start "$d" sh -c 'exit 0'
wait "$W"; wrc=$?
[ "$wrc" -eq 0 ] && contains "$(cat "$TMP/late.out")" 'rc=0' \
  && ok "race 3: a wait already polling when start runs picks the run up (rc=0)" \
  || ko "the early wait exited $wrc -- $(cat "$TMP/late.out")"
[ -e "$d/refused" ] && ko "the early wait's directory was refused: $(cat "$d/refused")" \
  || ok "...and the early wait did not make the directory look stale"

# --- a stale directory -----------------------------------------------------------------------------
d="$TMP/stale"; mkdir -p "$d"
printf '99999999\n' > "$d/pid"; printf 'old log\n' > "$d/log"; printf '0\n' > "$d/rc"
expect "stale: start refuses a directory that holds a finished run (exit 2)" 2 'already holds a run' -- \
  "$BG" start "$d" -- sh -c 'touch "$0"; exit 9' "$TMP/stale.ran"
[ ! -e "$TMP/stale.ran" ] && ok "...and runs nothing" || ko "the refused start ran its command"
[ "$(cat "$d/rc")" = 0 ] && [ "$(cat "$d/log")" = 'old log' ] \
  && ok "...and leaves the earlier run's rc and log untouched" || ko "the earlier run's files changed"
expect "stale: a wait on it reads REFUSED (exit 6), not the earlier rc=0" 6 'REFUSED:' -- "$BG" wait "$d" --within 0
d="$TMP/stale-live"
bg_start "$d" sleep 30
live=$S
if until_file "$d/pid" 10; then
  expect "stale: start refuses a directory whose run is still live" 2 'already holds a run' -- \
    "$BG" start "$d" -- true
  expect "...and a wait on it reads REFUSED" 6 'REFUSED:' -- "$BG" wait "$d" --within 0
else
  ko "stale: the live fixture never published its pid"
fi
kill -9 "$live" 2>/dev/null; { wait "$live"; } 2>/dev/null

# Two starts racing on one fresh directory (a duplicated tool call, a retry): exactly one may run
# its command. BG_RUN_CLAIM_PAUSE holds both past the emptiness check, so the claim is what decides
# and the race is lost every time rather than by luck; the control is a copy whose exclusive link
# is patched into an overwriting rename, which must then run the command twice.
# twin_starts <script> <dir>: launch two starts at once; sets TWIN_RAN (times the command ran) and
# TWIN_RCS (the two start exits).
twin_starts() {
  local ran="$2.ran" a b ra rb
  BG_RUN_CLAIM_PAUSE=1 "$1" start "$2" -- sh -c 'echo x >> "$0"; sleep 1' "$ran" > /dev/null 2>&1 &
  a=$!
  BG_RUN_CLAIM_PAUSE=1 "$1" start "$2" -- sh -c 'echo x >> "$0"; sleep 1' "$ran" > /dev/null 2>&1 &
  b=$!
  BGPIDS="$BGPIDS $a $b"
  wait "$a"; ra=$?; wait "$b"; rb=$?
  TWIN_RAN=$(grep -c x "$ran" 2>/dev/null); TWIN_RAN=${TWIN_RAN:-0}
  TWIN_RCS=$(printf '%s\n' "$ra" "$rb" | sort | tr '\n' ' ')
}
twin_starts "$BG" "$TMP/twin"
[ "$TWIN_RAN" -eq 1 ] && [ "$TWIN_RCS" = "0 2 " ] \
  && ok "twin starts on one directory: the command ran once and the other start was refused" \
  || ko "twin starts: the command ran $TWIN_RAN time(s); the starts exited $TWIN_RCS"
sed 's|ln -- "$dir/.pid.$$" "$dir/pid"|mv -f -- "$dir/.pid.$$" "$dir/pid"|' "$BG" > "$TMP/unclaimed.sh"
chmod +x "$TMP/unclaimed.sh"
if cmp -s "$BG" "$TMP/unclaimed.sh"; then
  ko "control: the patch found no exclusive link to replace in $BG"
else
  twin_starts "$TMP/unclaimed.sh" "$TMP/twin-control"
  [ "$TWIN_RAN" -eq 2 ] && ok "control: with an overwriting rename for the claim, both starts run the command" \
    || ko "control: the unclaimed copy ran the command $TWIN_RAN time(s), so the case above proves nothing"
fi

# --- the finish-between-reads order ------------------------------------------------------------------
d="$TMP/dead-with-rc"; mkdir -p "$d"
printf '99999999\n' > "$d/pid"; printf '3\n' > "$d/rc"
expect "a dead pid beside an rc reads rc=3, not DIED" 0 'rc=3' -- "$BG" wait "$d" --within 0
d="$TMP/dead-no-rc"; mkdir -p "$d"
printf '99999999\n' > "$d/pid"
expect "control: a dead pid with no rc reads DIED" 5 DIED -- "$BG" wait "$d" --within 0

# --- usage -------------------------------------------------------------------------------------------
expect "usage: start refuses a relative directory" 2 'absolute' -- "$BG" start rel/dir -- true
[ ! -e rel ] && ok "...and creates nothing" || ko "a relative start created ./rel"
expect "usage: wait refuses a relative directory" 2 'absolute' -- "$BG" wait rel/dir --within 0
expect "usage: start without -- is refused" 2 'usage:' -- "$BG" start "$TMP/u1" true
[ ! -e "$TMP/u1" ] && ok "...and creates nothing" || ko "a start without -- created its directory"
expect "usage: start with no command is refused" 2 'usage:' -- "$BG" start "$TMP/u2" --
expect "usage: a --within that is not a number is refused" 2 'whole number' -- "$BG" wait "$TMP/u3" --within soon
expect "usage: no subcommand is refused" 2 'usage:' -- "$BG"
expect "usage: --help prints the synopsis" 0 'bg-run.sh start <dir> --' -- "$BG" --help

# --- through zsh, the way the Bash tool issues it ------------------------------------------------------
if command -v zsh > /dev/null 2>&1; then
  d="$TMP/zsh"
  # shellcheck disable=SC2016 # the single quotes are zsh's to expand
  zsh -fc '"$0" start "$1" -- printf "%s\n" "owner/repo#12" "a b" "\$HOME"' "$BG" "$d" > /dev/null 2>&1 &
  BGPIDS="$BGPIDS $!"
  expect "zsh: a start issued through zsh -c finishes (rc=0)" 0 'rc=0' -- "$BG" wait "$d" --within 20
  [ "$(cat "$d/log")" = "$(printf '%s\n' 'owner/repo#12' 'a b' '$HOME')" ] \
    && ok "...with its arguments passed through intact" || ko "zsh start logged: $(cat "$d/log")"
else
  echo "SKIP: zsh is not installed; the zsh -c start is not exercised here"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
exit "$?"
}
