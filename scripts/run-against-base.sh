#!/usr/bin/env bash
# Runs the working tree's version of ONE suite against the base code: the negative control every
# issue-wave brief asks for ("show the new fixtures FAIL on the base"). A detached worktree of
# origin/main (or --base <ref>) is made under $TMPDIR, the current working tree's copy of
# <suite-path> -- that file and nothing else -- is copied over the base's, and the suite runs from
# the base worktree, so everything it reaches through its own directory is the base's. The
# worktree is a real checkout, not a `git archive` export, so a suite that asks git about its
# checkout gets an answer. It is removed on every exit path, INT and TERM included.
#
# Before 2026-09-28 each worker did this by hand, each differently: a detached worktree with the
# test copied in, a `git archive` of the base (which broke a case, since an export is not a git
# checkout), the edited script stashed back to base, temporary worktrees.
#
# It is a suite run like any other, so callers take the box's correctness slot around it:
#   ~/.claude/skills/issue-wave/scripts/fleet-worker.sh execution slot -- \
#     scripts/run-against-base.sh <suite-path> [--base <ref>] [suite args...]
# (`execution slot --cpu -- ...` for a suite that holds no GPU).
#
# The base ref is used as it stands locally: fetch first if origin/main may be stale.
#
# Usage: run-against-base.sh <suite-path> [--base <ref>] [suite args...]
#   <suite-path>  a file in the current checkout's working tree (relative to the cwd, or absolute)
#   --base <ref>  the base to run against (default origin/main); it must come right after the
#                 suite path, and every argument after it goes to the suite
# Exit: the suite's own exit status; 125 when the helper could not run it at all (the
# `git bisect run` convention for "cannot test"), so a refusal is never read as the suite's
# failure.

set -uo pipefail

# One brace group, so bash parses this file WHOLE before its first line runs and an edit landing
# while a (minutes-long) suite run is in flight cannot resume the shell at a shifted offset
# (ludics-lite#10, #247).
{
say() { printf '%s\n' "run-against-base: $*"; }
die() {
  printf '%s\n' "run-against-base: $*" >&2
  exit 125
}

[ $# -ge 1 ] || die "usage: run-against-base.sh <suite-path> [--base <ref>] [suite args...]"
case "$1" in -h | --help)
  sed -n '2,/^$/s/^# \{0,1\}//p' "$0"
  exit 0
  ;;
esac
suite_arg=$1
shift
base=origin/main
if [ "${1-}" = --base ]; then
  [ $# -ge 2 ] || die "--base needs a ref"
  base=$2
  shift 2
fi

[ -f "$suite_arg" ] || die "no such file in the working tree: $suite_arg"
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout: $PWD"
TOP=$(CDPATH= cd "$TOP" && pwd -P) || die "cannot resolve the checkout root: $TOP"
suite_dir=$(CDPATH= cd "$(dirname "$suite_arg")" && pwd -P) || die "cannot resolve: $suite_arg"
suite_abs="$suite_dir/$(basename "$suite_arg")"
case "$suite_abs" in
"$TOP"/*) rel=${suite_abs#"$TOP"/} ;;
*) die "$suite_arg is not inside this checkout ($TOP)" ;;
esac
case "$rel" in
*.py) runner=python3 ;;
*)
  [ -x "$suite_abs" ] || die "$rel is not executable (chmod +x it, as the mode rule asks)"
  runner=
  ;;
esac
sha=$(git -C "$TOP" rev-parse --verify --quiet "$base^{commit}") || die "no such commit: $base"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/run-against-base.$$.XXXXXX") || die "mktemp failed"
SCRATCH=$(CDPATH= cd "$SCRATCH" && pwd -P) || die "cannot resolve $SCRATCH"
WT="$SCRATCH/base"
child=
teepid=
cleanup() {
  [ -n "$child" ] && kill -TERM "$child" 2>/dev/null && wait "$child" 2>/dev/null
  [ -n "$teepid" ] && kill "$teepid" 2>/dev/null
  if [ -d "$WT" ]; then
    git -C "$TOP" worktree remove --force "$WT" >/dev/null 2>&1 \
      || printf '%s\n' "run-against-base: could not remove the worktree $WT" >&2
  fi
  git -C "$TOP" worktree prune >/dev/null 2>&1
  rm -rf "$SCRATCH"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

git -C "$TOP" worktree add --quiet --detach "$WT" "$sha" >/dev/null 2>&1 \
  || die "git worktree add failed for $base ($sha)"
mkdir -p "$(dirname "$WT/$rel")" || die "cannot create $(dirname "$WT/$rel")"
cp -p "$suite_abs" "$WT/$rel" || die "cannot copy $rel into the base worktree"

say "$rel (working tree) against $base ($(git -C "$TOP" rev-parse --short "$sha"))"
# The suite runs in the background so the INT/TERM traps fire at once rather than after it
# returns; its output goes through a fifo to tee, which both shows it live and keeps it for the
# pass/fail line (a `| tee` would hide the suite's exit status behind tee's under `wait`).
LOG="$SCRATCH/out"
mkfifo "$SCRATCH/fifo" || die "mkfifo failed"
tee "$LOG" <"$SCRATCH/fifo" &
teepid=$!
(cd "$WT" && exec $runner "./$rel" "$@") >"$SCRATCH/fifo" 2>&1 </dev/null &
child=$!
wait "$child"
rc=$?
child=
wait "$teepid"
teepid=

tally=$(grep -E '[0-9]+ passed, [0-9]+ failed' "$LOG" | tail -n 1)
[ -n "$tally" ] || tally=$(grep -v '^[[:space:]]*$' "$LOG" | tail -n 1)
say "exit $rc on $base: ${tally:-(no output)}"
exit "$rc"
exit "$?"
}
