#!/usr/bin/env bash
# Exercises scripts/py, the interpreter wrapper every Python entry point of the v2 rewrite runs
# through (ludics-lite#403): the probe that picks the first Python >= 3.12, the refusal that names
# every candidate when none qualifies, and how the chosen one is run -- the arguments, stdin, the
# exit status, the package on PYTHONPATH and nothing from the caller's cwd on sys.path.
#
# The probe list is replaced through LUDICS_PY_CANDIDATES with fake interpreters in a scratch
# directory, so the refusal and the ordering are exercised on a box that HAS a good Python (the
# built-in list starts at /opt/homebrew/bin/python3, which no PATH edit can hide). The cases that
# run real Python use the built-in list, so they also prove this box (or CI runner) qualifies.
#
# Usage: test-py.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

# One brace group, so bash parses this file WHOLE before its first line runs and an edit landing
# while a run is in flight cannot resume the shell at a shifted offset; the `exit` at the foot
# means the shell never comes back to the file for a next command. Two lines here and two at the
# foot, with the body's own indentation untouched (ludics-lite#10, #247); scripts/check-parse-guards.sh
# checks the shape.
{
HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
PY="$HERE/py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-py.XXXXXX") || exit 1
# Resolved physically, like every root here: the wrapper computes its lib/ with `pwd -P`, and the
# fake interpreters below log paths this suite compares against (ludics-lite#208).
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "PASS: $*"
}
ko() {
  fail=$((fail + 1))
  echo "FAIL: $*"
}

# fake <path> <version> <probe exit>: an "interpreter" that answers the probe with <version> and
# <probe exit>, and otherwise logs its arguments (one per line) and PYTHONPATH to <path>.log.
fake() {
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<EOF
#!/bin/sh
if [ "\$1" = -c ]; then
  printf '%s\n' '$2'
  exit $3
fi
{ for a in "\$@"; do printf 'arg:%s\n' "\$a"; done; printf 'PYTHONPATH:%s\n' "\$PYTHONPATH"; } >"$1.log"
exit 0
EOF
  chmod +x "$1"
}

# The refusal: every candidate named with what was found there, exit 2, nothing run.
mkdir -p "$TMP/bin"
fake "$TMP/bin/old" 3.9.6 1
fake "$TMP/bin/py2" 2.7.18 1
cat >"$TMP/bin/broken" <<'EOF'
#!/bin/sh
exit 3
EOF
chmod +x "$TMP/bin/broken"
candidates="$TMP/bin/absent
$TMP/bin/old
$TMP/bin/py2
$TMP/bin/broken
no-such-python-on-path"
out=$(LUDICS_PY_CANDIDATES="$candidates" "$PY" -c 'print(1)' 2>&1)
rc=$?
[ "$rc" -eq 2 ] && ok "no qualifying interpreter exits 2" || ko "no qualifying interpreter: rc=$rc, want 2 -- $out"
for want in "no Python >= 3.12 found, so nothing was run" \
  "$TMP/bin/absent: absent" \
  "$TMP/bin/old ($TMP/bin/old): Python 3.9.6, older than 3.12" \
  "$TMP/bin/py2 ($TMP/bin/py2): Python 2.7.18, older than 3.12" \
  "$TMP/bin/broken ($TMP/bin/broken): did not run as Python (exit 3)" \
  "no-such-python-on-path: not on PATH" \
  "LUDICS_PY_CANDIDATES"; do
  case "$out" in
  *"$want"*) ok "the refusal says: $want" ;;
  *) ko "the refusal does not say '$want' -- $out" ;;
  esac
done
[ ! -e "$TMP/bin/old.log" ] && [ ! -e "$TMP/bin/py2.log" ] &&
  ok "an old interpreter is probed, never run" || ko "an old interpreter was run past its probe"

# The first qualifying candidate wins, and nothing after it is probed or run. Paths with spaces are
# kept whole (one candidate per line).
fake "$TMP/dir with spaces/new" 3.12.4 0
fake "$TMP/bin/newer" 3.14.0 0
out=$(LUDICS_PY_CANDIDATES="$TMP/bin/old
$TMP/dir with spaces/new
$TMP/bin/newer" "$PY" -m ludics.prreview 'two words' '' 2>&1)
rc=$?
[ "$rc" -eq 0 ] && ok "a qualifying interpreter after an old one runs" || ko "rc=$rc -- $out"
log=$(cat "$TMP/dir with spaces/new.log" 2>/dev/null)
want="arg:-X
arg:utf8
arg:-P
arg:-m
arg:ludics.prreview
arg:two words
arg:
PYTHONPATH:$ROOT/lib"
[ "$log" = "$want" ] && ok "it gets -X utf8 -P, then the arguments verbatim, with lib/ as PYTHONPATH" ||
  ko "the chosen interpreter was run as: $log -- want: $want"
[ ! -e "$TMP/bin/newer.log" ] && ok "a later candidate is not run" || ko "a later candidate ran too"

# An inherited PYTHONPATH is replaced, not extended: the rewrite is standard-library only.
LUDICS_PY_CANDIDATES="$TMP/bin/newer" PYTHONPATH="$TMP/elsewhere" "$PY" -c x >/dev/null 2>&1
case "$(cat "$TMP/bin/newer.log" 2>/dev/null)" in
*"PYTHONPATH:$ROOT/lib") ok "an inherited PYTHONPATH is replaced by lib/" ;;
*) ko "PYTHONPATH was not exactly lib/: $(cat "$TMP/bin/newer.log" 2>/dev/null)" ;;
esac

# The built-in list on this box: a real interpreter >= 3.12 is found.
out=$("$PY" -c 'import sys; print(sys.version_info >= (3, 12))' 2>&1)
[ "$out" = True ] && ok "the built-in list finds a Python >= 3.12 here" ||
  ko "the built-in list did not run a Python >= 3.12: $out"

# Exit status and stdin pass through: the wrapper execs, it does not interpret.
out=$(printf 'abc' | "$PY" -c 'import sys; sys.exit(40 + len(sys.stdin.read()))' 2>&1)
rc=$?
[ "$rc" -eq 43 ] && ok "stdin reaches the program and its exit status is the wrapper's" ||
  ko "rc=$rc, want 43 -- $out"

# Nothing from the caller's cwd shadows a module: pr-review.sh runs from inside arbitrary project
# checkouts. Without -P, a `json.py` in the cwd is what `import json` loads.
mkdir -p "$TMP/project"
printf 'raise SystemExit("the cwd json.py was imported")\n' >"$TMP/project/json.py"
out=$(cd "$TMP/project" && "$PY" -c 'import json; print(json.dumps([1]))' 2>&1)
[ "$out" = "[1]" ] && ok "a module in the cwd does not shadow the standard library" ||
  ko "the cwd shadowed a module: $out"

# UTF-8 on the streams whatever the locale.
out=$(LC_ALL=C LANG=C "$PY" -c 'print("—")' 2>&1)
[ "$out" = "—" ] && ok "stdout is UTF-8 under LC_ALL=C" || ko "stdout under LC_ALL=C: $out"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
exit "$?"
}
