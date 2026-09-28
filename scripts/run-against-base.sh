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
# Exit: the suite's own exit status; 125 when the helper could not run it at all, could not
# start it (exec failed: it never ran), or could not clean up after it (the `git bisect run`
# convention for "cannot test"), so a refusal is never read as the suite's failure -- and a
# suite's own 125 is reported as 1.
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

# A relative path gets a `./`, so a name like `-check.sh` is never read as an option by dirname,
# basename or cd.
case "$suite_arg" in /*) ;; *) suite_arg="./$suite_arg" ;; esac
[ -f "$suite_arg" ] || die "no such file in the working tree: $suite_arg"
# A symlink is refused rather than resolved: what it points at may be outside git, and the negative
# control must be the working tree's committed-or-edited file, not something it reaches.
[ -L "$suite_arg" ] && die "$suite_arg is a symlink; name the file it points at"
TOP=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git checkout: $PWD"
TOP=$(CDPATH= cd "$TOP" && pwd -P) || die "cannot resolve the checkout root: $TOP"
# Split with parameter expansion, and read the resolved directory back through a trailing `x`: a
# command substitution strips trailing newlines, which a git filename may end in, and would then
# name a different file than the one checked above.
suite_dir=$(CDPATH= cd "${suite_arg%/*}/" && pwd -P && printf x) || die "cannot resolve: $suite_arg"
suite_dir=${suite_dir%x}
suite_dir=${suite_dir%$'\n'}
suite_abs="$suite_dir/${suite_arg##*/}"
# A suite inside a nested repository (a submodule, say) belongs to that repository: the base
# worktree of this one would hold an empty directory there, and the suite would fail on the base
# for want of its neighbours -- a negative control that proves nothing. Run it from inside.
suite_top=$(git -C "$suite_dir" rev-parse --show-toplevel 2>/dev/null) \
  && suite_top=$(CDPATH= cd "$suite_top" && pwd -P) || suite_top=
if [ -n "$suite_top" ] && [ "$suite_top" != "$TOP" ]; then
  die "$suite_arg is inside the nested repository $suite_top (a submodule?); run the helper from inside it"
fi
case "$suite_abs" in
"$TOP"/*) rel=${suite_abs#"$TOP"/} ;;
*) die "$suite_arg is not inside this checkout ($TOP)" ;;
esac
# Git's own directory is not the working tree: installing a path through `.git` would replace the
# base worktree's `.git` file and leave a checkout git no longer recognizes.
case "/$rel/" in */.git/*) die "$rel is inside a .git directory, not the working tree" ;; esac
case "$rel" in
*.py) runner=python3 ;;
*)
  [ -x "$suite_abs" ] || die "$rel is not executable (chmod +x it, as the mode rule asks)"
  runner=
  ;;
esac
# An interpreter that is missing means the suite never runs, and its 126/127 must not read as a
# base result. A missing first program is caught at the exec (execfail, below); what the exec
# cannot see is an env shebang whose program is not on PATH, since env itself starts fine -- so
# env's arguments are walked the way env reads them (options, `-u NAME`, `-S`'s split string,
# NAME=value assignments) to the first program word, and that is looked up here.
interp=$runner
if [ -z "$interp" ]; then
  IFS= read -r shebang <"$suite_abs" || true
  case "$shebang" in
  '#!'*)
    # An array, not the positional parameters: those are the suite's arguments.
    set -f
    read -r -a sb <<<"${shebang#??}"
    set +f
    if [ "${#sb[@]}" -gt 0 ] && [ "${sb[0]##*/}" = env ]; then
      i=1
      while [ "$i" -lt "${#sb[@]}" ]; do
        w=${sb[$i]}
        case "$w" in
        -u | --unset) i=$((i + 1)) ;;
        -i | --ignore-environment | -) sb_clear=1 ;;
        -S?*) w=${w#-S}; interp=$w; break ;;
        PATH=*) sb_path=${w#PATH=} ;;
        -* | *=*) ;;
        *) interp=$w; break ;;
        esac
        i=$((i + 1))
      done
    fi
    ;;
  esac
fi
# The lookup uses the PATH env will use: the shebang's own PATH= when it sets one; with the
# environment cleared (-i) and no PATH= the search path is env's built-in default, which is not
# ours to guess, so that one is left to the exec.
if [ -n "$interp" ] && [ -z "${sb_clear-}${sb_path+set}" ]; then
  command -v "$interp" >/dev/null 2>&1 || die "$rel needs $interp, which is not on PATH here; it would never run"
elif [ -n "$interp" ] && [ -n "${sb_path+set}" ]; then
  PATH=$sb_path command -v "$interp" >/dev/null 2>&1 \
    || die "$rel needs $interp, which is not on the PATH its shebang sets ($sb_path); it would never run"
fi
sha=$(git -C "$TOP" rev-parse --verify --quiet "$base^{commit}") || die "no such commit: $base"

# Whole seconds, checked before anything is allocated: the cleanup does integer arithmetic on it,
# and an expansion error inside the EXIT trap would leave the suite and its worktree behind.
GRACE=${RUN_AGAINST_BASE_GRACE:-5}
case "$GRACE" in '' | *[!0-9]*) die "RUN_AGAINST_BASE_GRACE must be whole seconds: $GRACE" ;; esac
GRACE=$((10#$GRACE))

# The cleanup is armed before the scratch directory exists, so no signal can land between the
# allocation and the trap; until SCRATCH is set it has nothing to do.
SCRATCH=
WT=
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
  # A second INT/TERM/HUP while this runs must not cut it short: the trap's `exit` would leave
  # the EXIT trap before the worktree is removed.
  trap '' INT TERM HUP
  [ -n "$SCRATCH" ] || return 0
  [ -n "$child" ] && stop_group
  if [ -n "$teepid" ] && ! gone "$teepid"; then kill "$teepid" 2>/dev/null; fi
  if [ -d "$WT" ]; then
    # --force twice: once for the copied suite (the checkout is dirty), again for a worktree the
    # suite locked, which a single --force refuses.
    git -C "$TOP" worktree remove --force --force "$WT" >/dev/null 2>&1
  fi
  git -C "$TOP" worktree prune >/dev/null 2>&1
  # A suite can leave a directory it made unreadable; give the tree back its owner's permissions
  # and try again rather than leak it.
  rm -rf "$SCRATCH" 2>/dev/null || { chmod -R u+rwx "$SCRATCH" 2>/dev/null; rm -rf "$SCRATCH"; }
  git -C "$TOP" worktree prune >/dev/null 2>&1
  local leaked=
  if git -C "$TOP" worktree list --porcelain 2>/dev/null | grep -qxF "worktree $WT"; then
    printf '%s\n' "run-against-base: the worktree $WT is still registered; remove it by hand" >&2
    leaked=1
  fi
  if [ -e "$SCRATCH" ]; then
    printf '%s\n' "run-against-base: could not remove $SCRATCH; remove it by hand" >&2
    leaked=1
  fi
  [ -z "$leaked" ] || exit 125
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# The root is resolved first and the scratch directory made under it, so SCRATCH is physical
# from its first assignment (a child of a physical path is physical) and no later line can
# overwrite it with an empty value the cleanup would then not know to remove.
TMP_ROOT=$(CDPATH= cd "${TMPDIR:-/tmp}" && pwd -P) || die "cannot resolve ${TMPDIR:-/tmp}"
SCRATCH=$(mktemp -d "$TMP_ROOT/run-against-base.$$.XXXXXX") || die "mktemp failed"
WT="$SCRATCH/base"

git -C "$TOP" worktree add --quiet --detach "$WT" "$sha" >/dev/null 2>&1 \
  || die "git worktree add failed for $base ($sha)"
# The suite's path is installed one component at a time, and at each one whatever the base has
# there -- a symlink, a file, a directory where the suite now is -- is replaced, never followed:
# the working tree's shape wins, so nothing is created or written outside the worktree. (`rel`
# came from a `pwd -P`, so every component above the suite is a real directory in the working
# tree too.)
dest=$WT
rest=$rel
while case "$rest" in */*) true ;; *) false ;; esac do
  dest="$dest/${rest%%/*}"
  rest=${rest#*/}
  if [ -L "$dest" ] || { [ -e "$dest" ] && [ ! -d "$dest" ]; }; then
    rm -f "$dest" || die "cannot replace ${dest#"$WT"/} in the base worktree"
  fi
  [ -d "$dest" ] || mkdir "$dest" || die "cannot create ${dest#"$WT"/} in the base worktree"
done
dest="$dest/$rest"
if [ -L "$dest" ] || [ -e "$dest" ]; then rm -rf "$dest" || die "cannot replace $rel in the base worktree"; fi
cp -p "$suite_abs" "$dest" || die "cannot copy $rel into the base worktree"

git_local_env=$(git rev-parse --local-env-vars | tr '\n' ' ')
say "$rel (working tree) against $base ($(git -C "$TOP" rev-parse --short "$sha"))"
# The suite runs in the background so the INT/TERM traps fire at once rather than after it
# returns; its output goes through a fifo to tee, which both shows it live and keeps it for the
# pass/fail line (a `| tee` would hide the suite's exit status behind tee's under `wait`).
LOG="$SCRATCH/out"
# Signals are deferred from the launches until `teepid` and `child` are recorded: a trap taken in between would
# run the cleanup without knowing what it has to stop, and leave tee or the suite running.
pending=
trap 'pending=130' INT
trap 'pending=143' TERM HUP
mkfifo "$SCRATCH/fifo" || die "mkfifo failed"
tee "$LOG" <"$SCRATCH/fifo" &
teepid=$!
# `set -m` puts the suite in a process group of its own (its pid is the group id), which
# stop_group signals whole; it also keeps INT at its default there rather than ignored, as a
# non-interactive shell would start a background job.
set -m
# execfail: a suite that cannot be started at all (a missing interpreter, no python3) never ran,
# so it must not read as the suite's 126/127 failure on the base; the marker tells the two apart.
# A top-level `bash -c` and not a `( ... )` subshell, because bash 3.2 exits a subshell on a
# failed exec whatever execfail says. Its $0 is the marker path; the exec keeps the pid, so the
# suite is still the group leader.
# Git's repository-local variables (GIT_DIR, GIT_WORK_TREE, ... as `git rev-parse
# --local-env-vars` lists them; a git hook exports them) are unset for the suite, or its git
# commands would inspect the caller's checkout instead of the base worktree.
# shellcheck disable=SC2016 # expanded by the inner bash
RUN_AGAINST_BASE_UNSET=$git_local_env bash -c 'unset $RUN_AGAINST_BASE_UNSET RUN_AGAINST_BASE_UNSET
  cd "$1" && shift && shopt -s execfail && exec "$@"
  : >"$0"
  exit 125' "$SCRATCH/execfail" "$WT" $runner "./$rel" "$@" >"$SCRATCH/fifo" 2>&1 </dev/null &
child=$!
set +m
trap 'exit 130' INT
trap 'exit 143' TERM HUP
[ -z "$pending" ] || exit "$pending"
wait "$child"
rc=$?
if [ -e "$SCRATCH/execfail" ]; then
  stop_group
  child=
  die "could not start $rel on $base (exec failed, see above); it never ran"
fi
# Anything the suite left running still holds the fifo open; stop it so tee sees EOF.
stop_group
child=
# tee is reaped and judged too: a capture that failed, or that something outside the group still
# held open past the grace, would make the result line (and a SIGPIPE'd suite's status) a claim
# about output nobody read.
if gone "$teepid"; then
  wait "$teepid"
  tee_rc=$?
else
  kill "$teepid" 2>/dev/null
  wait "$teepid" 2>/dev/null
  tee_rc=timeout
fi
teepid=
[ "$tee_rc" = 0 ] || die "capturing the suite's output failed (tee: $tee_rc); its exit $rc is not a result"

tally=$(grep -E '[0-9]+ passed, [0-9]+ failed' "$LOG" | tail -n 1)
[ -n "$tally" ] || tally=$(grep -v '^[[:space:]]*$' "$LOG" | tail -n 1)
say "exit $rc on $base: ${tally:-(no output)}"
# 125 is this helper's own "could not run it"; a suite that returns it failed, and says so as 1.
[ "$rc" -eq 125 ] && rc=1
exit "$rc"
exit "$?"
}
