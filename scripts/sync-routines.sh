#!/usr/bin/env bash
# Sync the local scheduled-task prompts between this checkout and the desktop app's
# ~/.claude/scheduled-tasks/<id>/.
#
# Those directories must hold REAL files. The symlink trick the skills still use stopped
# working for scheduled tasks in desktop app 1.46388.4 (2026-09-06): the scheduler now
# refuses a task file whose path traverses a symlink ("symlink detected before open;
# refusing to open"), and a task whose prompt it cannot read is dispatched, never started,
# and cleared ten minutes later as a stale dispatch -- with lastRunAt stamped by the clear,
# so the registry still looks like it ran. Hence copies, and hence this script.
#
# Usage:
#   sync-routines.sh              status only: report drift, exit 1 if any
#   sync-routines.sh push         this checkout -> ~/.claude/scheduled-tasks (after editing here)
#   sync-routines.sh pull         ~/.claude/scheduled-tasks -> this checkout (after an edit
#                                 made in place, e.g. by the routine's own run)
#
# Options:
#   -n, --dry-run                 say what would be copied, copy nothing
#   -h, --help                    this text
#
# Exit codes:
#   0  status: everything in sync. push/pull: every routine handled.
#   1  status: drift (or a routine not installed, or installed as a symlink, or a destination
#      reached through one). push: the destination is behind a symlink, so nothing was copied,
#      or a routine could not be synced. pull: a routine could not be read -- a source directory
#      missing, or an installed path that is a symlink and so holds nothing real. A push that
#      installs a prompt over a placeholder is not a failure.
#   2  usage: an argument this script does not know.
#
# The destination is $CLAUDE_SCHEDULED_TASKS_DIR when set, which is what the fixture suite
# scripts/test-sync-routines.sh points at scratch trees; otherwise ~/.claude/scheduled-tasks.
#
# Registration is separate: the desktop app's registry (cron, working directory, model) is
# not a file in this repository. Register a task with the `schedule` tool first -- it writes
# a placeholder SKILL.md -- then `sync-routines.sh push` over it.

set -euo pipefail

# The routines this script syncs: exactly the rows of routines/README.md's table whose Kind is
# `local scheduled task`. The cloud routine (ocannl-ci-red-triage) is not here -- it is synced
# by hand through the `schedule` skill, per that README.
#
# The list is written out rather than read off the table on purpose. Parsing the README at
# runtime would put a Markdown table model in the path of every sync, and ludics-lite#75 is
# thirteen review rounds of what that costs; the drift it would guard against instead has a
# test: scripts/test-sync-routines.sh reads this line and the table and refuses them if they
# disagree, with negative controls that show the comparison can fail (ludics-lite#77). Keep
# the assignment on one line, `LOCAL_ROUTINES="..."`, which is the shape the suite reads.
LOCAL_ROUTINES="daily-issue-planning ocannl-cross-machine-sweep"

repo_root=$(cd "$(dirname "$0")/.." && pwd)
src_root="$repo_root/routines"
dest_root="${CLAUDE_SCHEDULED_TASKS_DIR:-$HOME/.claude/scheduled-tasks}"

mode=status
dry_run=false

while [ $# -gt 0 ]; do
  case "$1" in
    push|pull|status) mode=$1 ;;
    -n|--dry-run) dry_run=true ;;
    -h|--help) awk 'NR>1 && /^#/ {sub(/^# ?/, ""); print; next} NR>1 {exit}' "$0"; exit 0 ;;
    *) echo "sync-routines: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

say() { printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# first_symlinked_ancestor <dir>: the first component of <dir>'s path that is a symlink, or
# nothing. The per-routine `[ -L "$dst" ]` check below only sees the routine's own directory, but
# the scheduler refuses a task file whose path traverses a symlink at ANY component: a symlinked
# ~/.claude, or a scheduled-tasks directory moved aside and linked back, hides behind a $dst that
# is a real directory and would otherwise be reported in sync while nothing could read it.
#
# The walk is over the LITERAL components, which is what the registry stores and what the reader
# traverses -- so a component above the destination counts too, even one nobody here chose (on
# macOS /var is a link to /private/var, so a destination under /var/... genuinely is behind one).
# `pwd -P` at the caller's end is how a path is made clean; realpath is not on stock macOS.
first_symlinked_ancestor() {
  local path=$1 prefix="" comp oldifs
  case "$path" in /*) ;; *) path="$PWD/$path" ;; esac
  oldifs=$IFS
  IFS=/
  for comp in $path; do
    [ -n "$comp" ] || continue
    prefix="$prefix/$comp"
    if [ -L "$prefix" ]; then IFS=$oldifs; printf '%s\n' "$prefix"; return 0; fi
  done
  IFS=$oldifs
  return 1
}

# Replace dst with a copy of src, atomically enough that a dispatch mid-copy sees either the
# old directory or the new one.
copy_dir() {
  local src=$1 dst=$2 tmp
  tmp="$dst.sync-$$"
  rm -rf "$tmp"
  cp -R "$src" "$tmp"
  rm -rf "$dst"
  mv "$tmp" "$dst"
}

drift=0      # status only: the checkout and the installed copies disagree
problems=0   # push/pull only: a routine this run could not sync
copied=0

# Whatever the mode, a destination reached through a symlink is a destination the scheduler will
# not read. Checked once, above the loop, because it is a fact about the root and not about any
# one routine.
if link=$(first_symlinked_ancestor "$dest_root"); then
  warn "$dest_root is reached through a SYMLINK ($link -> $(readlink "$link")) -- the scheduler"
  warn "refuses a task file whose path traverses one, at any component. Make the destination a"
  warn "real directory (or point CLAUDE_SCHEDULED_TASKS_DIR at the resolved path) before syncing."
  case "$mode" in
    push)
      # Copying would succeed and install a prompt nothing can read: the exact quiet failure
      # this script exists to prevent.
      warn "sync-routines: refusing to push behind a symlink"
      exit 1
      ;;
    pull)
      # Reading is unaffected -- the files behind the link are real -- so this is a warning.
      warn "sync-routines: pulling anyway; the content behind the link is real"
      ;;
    *) drift=1 ;;
  esac
fi

# A push onto a box whose scheduled-tasks directory does not exist yet has to create it, or
# copy_dir's `mv` lands nowhere. Status and pull read, so they leave the filesystem alone.
if [ "$mode" = push ] && ! $dry_run; then
  mkdir -p "$dest_root"
fi

for r in $LOCAL_ROUTINES; do
  src="$src_root/$r"
  dst="$dest_root/$r"

  if [ ! -d "$src" ]; then
    warn "$r: no such routine in $src_root -- skipping"
    if [ "$mode" = status ]; then drift=1; else problems=1; fi
    continue
  fi

  if [ -L "$dst" ]; then
    warn "$r: installed as a SYMLINK ($(readlink "$dst")) -- the scheduler cannot read it"
    case "$mode" in
      push)
        if $dry_run; then
          say "$r: would replace the symlink with a real directory"
        else
          rm -f "$dst"
          copy_dir "$src" "$dst"
          say "$r: symlink replaced with a real copy"
          copied=$((copied + 1))
        fi
        ;;
      pull)
        # Reading through the link would "pull" the checkout onto itself and call the drift
        # resolved. There is nothing installed to take.
        warn "$r: nothing to pull -- the installed path is a link, not a copy; \`push\` first"
        problems=1
        ;;
      *) drift=1 ;;
    esac
    continue
  fi

  if [ ! -d "$dst" ]; then
    warn "$r: not installed at $dst -- register the task with the \`schedule\` tool first"
    case "$mode" in
      push)
        if $dry_run; then
          say "$r: would install $src -> $dst"
        else
          copy_dir "$src" "$dst"
          say "$r: prompt installed, but the task is still unregistered (no cron will fire it)"
          copied=$((copied + 1))
        fi
        ;;
      pull) problems=1 ;;
      *) drift=1 ;;
    esac
    continue
  fi

  if diff -r -q "$src" "$dst" >/dev/null 2>&1; then
    if [ "$mode" = status ]; then say "$r: in sync"; fi
    continue
  fi

  case "$mode" in
    status)
      say "$r: DRIFT"
      diff -r -u "$src" "$dst" | sed 's/^/    /' || true
      drift=1
      ;;
    push)
      if $dry_run; then
        say "$r: would push $src -> $dst"
      else
        copy_dir "$src" "$dst"
        say "$r: pushed to $dst"
        copied=$((copied + 1))
      fi
      ;;
    pull)
      if $dry_run; then
        say "$r: would pull $dst -> $src"
      else
        copy_dir "$dst" "$src"
        say "$r: pulled into $src -- review it with git diff"
        copied=$((copied + 1))
      fi
      ;;
  esac
done

if [ "$mode" = status ]; then
  if [ "$drift" -eq 0 ]; then
    say "all local routines in sync with $dest_root"
  else
    say ""
    say "run \`$0 push\` to install this checkout's prompts, or \`pull\` to take the installed ones."
  fi
  exit "$drift"
fi

say ""
if $dry_run; then
  say "dry run: nothing was copied."
else
  say "$copied routine(s) updated."
fi
if [ "$mode" = pull ] && [ "$copied" -gt 0 ]; then
  say "Nothing is committed: review with git diff, then commit here."
fi
if [ "$problems" -ne 0 ]; then
  warn "sync-routines: some routines were not synced (see the lines above)"
fi
exit "$problems"
