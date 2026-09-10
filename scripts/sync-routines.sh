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
# Registration is separate: the desktop app's registry (cron, working directory, model) is
# not a file in this repository. Register a task with the `schedule` tool first -- it writes
# a placeholder SKILL.md -- then `sync-routines.sh push` over it.

set -euo pipefail

# The cloud routine (ocannl-ci-red-triage) is not here: it is synced by hand through the
# `schedule` skill, per routines/README.md.
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

drift=0
copied=0

for r in $LOCAL_ROUTINES; do
  src="$src_root/$r"
  dst="$dest_root/$r"

  if [ ! -d "$src" ]; then
    warn "$r: no such routine in $src_root -- skipping"
    drift=1
    continue
  fi

  if [ -L "$dst" ]; then
    warn "$r: installed as a SYMLINK ($(readlink "$dst")) -- the scheduler cannot read it"
    if [ "$mode" = push ]; then
      if $dry_run; then
        say "$r: would replace the symlink with a real directory"
      else
        rm -f "$dst"
        copy_dir "$src" "$dst"
        say "$r: symlink replaced with a real copy"
        copied=$((copied + 1))
      fi
    else
      drift=1
    fi
    continue
  fi

  if [ ! -d "$dst" ]; then
    warn "$r: not installed at $dst -- register the task with the \`schedule\` tool first"
    if [ "$mode" = push ] && ! $dry_run; then
      copy_dir "$src" "$dst"
      say "$r: prompt installed, but the task is still unregistered (no cron will fire it)"
      copied=$((copied + 1))
    fi
    drift=1
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
say "$copied routine(s) updated."
if [ "$mode" = pull ]; then
  say "Nothing is committed: review with git diff, then commit here."
fi
exit 0
