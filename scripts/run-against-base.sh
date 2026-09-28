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
# Exit: the suite's own exit status; 125 when the helper could not run it at all, or could not
# unregister the worktree afterwards (the `git bisect run` convention for "cannot test"), so a
# refusal is never read as the suite's failure -- and a suite's own 125 is reported as 1.
# Whatever the suite left running is stopped with it: its process group gets TERM, then KILL
# after RUN_AGAINST_BASE_GRACE whole seconds (default 5).

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

# Whole seconds, checked before anything is allocated: the cleanup does integer arithmetic on it,
# and an expansion error inside the EXIT trap would leave the suite and its worktree behind.
GRACE=${RUN_AGAINST_BASE_GRACE:-5}
case "$GRACE" in '' | *[!0-9]*) die "RUN_AGAINST_BASE_GRACE must be whole seconds: $GRACE" ;; esac
GRACE=$((10#$GRACE))

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/run-against-base.$$.XXXXXX") || die "mktemp failed"
SCRATCH=$(CDPATH= cd "$SCRATCH" && pwd -P) || die "cannot resolve $SCRATCH"
WT="$SCRATCH/base"
child=
teepid=
# live PID | live -PGID: whether that process, or any member of that process group, is still
# running. An exited child of this shell stays a zombie until it is waited for, and kill -0
# still reaches a zombie, so the state is read instead.
live() {
  case "$1" in
  -*) ps -eo pgid=,stat= 2>/dev/null | awk -v g="${1#-}" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit !f }' ;;
  *) case $(ps -o stat= -p "$1" 2>/dev/null) in '' | Z*) return 1 ;; esac ;;
  esac
}
# gone PID|-PGID: true once it is no longer live, polling for at most $GRACE seconds -- no wait
# here is unbounded, since a process that ignores TERM or an orphan holding the fifo would
# otherwise hold the helper, and the worktree, forever.
gone() {
  local i=0
  while live "$1"; do
    [ "$i" -ge $((GRACE * 10)) ] && return 1
    sleep 0.1
    i=$((i + 1))
  done
}
# stop_group: the suite runs as the leader of its own process group, so this reaches whatever it
# left behind in that group as well -- a background child that outlived it, one that ignores
# TERM -- and none of it keeps running in (or writing to) a worktree about to be removed. The
# grace is the GROUP's, not the leader's: a leader that has already exited must not cut short a
# background child's own TERM cleanup. A descendant that leaves the group (`setsid`, its own
# `set -m` job) has left what this helper owns; the suite that starts one stops it.
stop_group() {
  kill -TERM -- "-$child" 2>/dev/null
  gone "-$child" || kill -KILL -- "-$child" 2>/dev/null
  wait "$child" 2>/dev/null
  return 0
}
cleanup() {
  [ -n "$child" ] && stop_group
  if [ -n "$teepid" ] && ! gone "$teepid"; then kill "$teepid" 2>/dev/null; fi
  if [ -d "$WT" ]; then
    # --force twice: once for the copied suite (the checkout is dirty), again for a worktree the
    # suite locked, which a single --force refuses.
    git -C "$TOP" worktree remove --force --force "$WT" >/dev/null 2>&1
  fi
  git -C "$TOP" worktree prune >/dev/null 2>&1
  rm -rf "$SCRATCH"
  git -C "$TOP" worktree prune >/dev/null 2>&1
  if git -C "$TOP" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $WT"; then
    printf '%s\n' "run-against-base: the worktree $WT is still registered; remove it by hand" >&2
    exit 125
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

git -C "$TOP" worktree add --quiet --detach "$WT" "$sha" >/dev/null 2>&1 \
  || die "git worktree add failed for $base ($sha)"
# The suite's path is installed one component at a time, and at each one whatever the base has
# there -- a symlink, a file, a directory where the suite now is -- is replaced, never followed:
# the working tree's shape wins, so nothing is created or written outside the worktree. (`rel`
# came from a `pwd -P`, so every component above the suite is a real directory in the working
# tree too.)
dest=$WT
old_ifs=$IFS
IFS=/
set -f
# shellcheck disable=SC2086 # the split on / is the point
set -- $rel -- "$@"
set +f
IFS=$old_ifs
while [ "$2" != -- ]; do
  dest="$dest/$1"
  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -d "$dest" ]; }; then
    rm -f "$dest" || die "cannot replace ${dest#"$WT"/} in the base worktree"
  fi
  [ -d "$dest" ] || mkdir "$dest" || die "cannot create ${dest#"$WT"/} in the base worktree"
  shift
done
dest="$dest/$1"
shift 2
if [ -L "$dest" ] || [ -e "$dest" ]; then rm -rf "$dest" || die "cannot replace $rel in the base worktree"; fi
cp -p "$suite_abs" "$dest" || die "cannot copy $rel into the base worktree"

say "$rel (working tree) against $base ($(git -C "$TOP" rev-parse --short "$sha"))"
# The suite runs in the background so the INT/TERM traps fire at once rather than after it
# returns; its output goes through a fifo to tee, which both shows it live and keeps it for the
# pass/fail line (a `| tee` would hide the suite's exit status behind tee's under `wait`).
LOG="$SCRATCH/out"
mkfifo "$SCRATCH/fifo" || die "mkfifo failed"
tee "$LOG" <"$SCRATCH/fifo" &
teepid=$!
# `set -m` puts the suite in a process group of its own (its pid is the group id), which
# stop_group signals whole; it also keeps INT at its default there rather than ignored, as a
# non-interactive shell would start a background job.
set -m
(cd "$WT" && exec $runner "./$rel" "$@") >"$SCRATCH/fifo" 2>&1 </dev/null &
child=$!
set +m
wait "$child"
rc=$?
# Anything the suite left running still holds the fifo open; stop it so tee sees EOF.
stop_group
child=
if ! gone "$teepid"; then kill "$teepid" 2>/dev/null; fi
teepid=

tally=$(grep -E '[0-9]+ passed, [0-9]+ failed' "$LOG" | tail -n 1)
[ -n "$tally" ] || tally=$(grep -v '^[[:space:]]*$' "$LOG" | tail -n 1)
say "exit $rc on $base: ${tally:-(no output)}"
# 125 is this helper's own "could not run it"; a suite that returns it failed, and says so as 1.
[ "$rc" -eq 125 ] && rc=1
exit "$rc"
exit "$?"
}
