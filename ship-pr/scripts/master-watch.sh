#!/bin/bash
# master-watch.sh — at most ONE master-CI watcher per machine per repo.
#
# The standalone complement of the roll-forward policy (ahrefs/ocannl#861) briefly read "every
# merging session runs `base --wait` after its own merge"; with several standalone sessions
# active that meant N agents blocked on the same moving tip, and potentially N parallel fixes
# for one red (observed 2026-08-31). This wrapper makes the duty singular: the first session
# to call it becomes the machine's watcher for the repo and runs the wait; every later call
# while that watcher lives prints who holds it and exits 0 immediately — the caller owes
# nothing further, because the running wait re-reads the tip each round and so already covers
# the later merge too.
#
# Usage: master-watch.sh <owner>/<repo> [branch] [--wait=seconds]
#   Trailing args pass through to `pr-review.sh base`; the wait itself is always on (that is
#   the point) — `--wait=N` shortens/lengthens the ceiling (default SHIP_PR_CHECKS_WAIT).
#
# Exit codes: 0 = tip judged green/settled, OR another watcher already holds the repo here
# (the message says which — it is not a verdict, but either way this session owes nothing);
# otherwise pr-review.sh base's own codes: 1 red — the WATCHER claims and fixes it forward
# (see SKILL.md's claim step before touching anything), 3 transport, 4 tip unjudged at the
# ceiling.
#
# The lock is an mkdir-atomic directory holding the watcher's pid; a lock whose holder is dead
# (crashed or killed session — an untrapped kill skips the EXIT cleanup) is reclaimed on the
# next call. It is machine-LOCAL by design: cross-machine duplication is prevented by the
# claim-on-GitHub step in SKILL.md, not by this lock.
set -u

REPO="${1:?usage: master-watch.sh <owner>/<repo> [branch] [--wait=seconds]}"
shift

LOCKROOT="${SHIP_PR_WATCH_LOCK_DIR:-${TMPDIR:-/tmp}}"
KEY=$(printf '%s' "$REPO" | tr '/:' '__')
LOCKDIR="$LOCKROOT/ship-pr-master-watch-$KEY"

HOLDER=""
acquire() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCKDIR/pid"
    return 0
  fi
  local pid
  pid=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    HOLDER="$pid"
    return 1
  fi
  # Holder gone: reclaim. Two sessions can race the reclaim; mkdir's atomicity picks one.
  rm -rf "$LOCKDIR" 2>/dev/null
  if mkdir "$LOCKDIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCKDIR/pid"
    return 0
  fi
  HOLDER=$(cat "$LOCKDIR/pid" 2>/dev/null || echo unknown)
  return 1
}

if ! acquire; then
  echo "master-watch: SKIPPED — pid ${HOLDER:-unknown} already watches $REPO on this machine." \
    "Its wait follows the moving tip, so it covers this merge too; trailing CI is that" \
    "session's business and this one is done."
  exit 0
fi
trap 'rm -rf "$LOCKDIR"' EXIT

echo "master-watch: this session is now the $REPO watcher on this machine — a red this wait" \
  "turns up is yours to claim and fix forward."
"$(dirname "$0")/pr-review.sh" base "$REPO" --wait "$@"
