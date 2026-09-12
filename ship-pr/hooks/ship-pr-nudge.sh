#!/bin/bash
# Stop hook: when a session ends with finished-looking work that never landed, block the stop once
# and point at the ship-pr skill.
#
# A Stop hook's stdout does not reach the model -- blocking (exit 2, message on stderr) is the only
# channel. Blocking costs an extra model turn, so this is a STATE GATE, not a reminder: it stays
# silent unless there is genuinely unlanded work, and it speaks at most once per repository state.
#
# Exit 0 = let the session stop. Exit 2 = block, stderr goes to the model.

input=$(cat)

# jq is not everywhere (minix-amd-wsl has none), and a hook that cannot read its input would go
# silently inert -- every field empty, every gate passed, exit 0 forever, with nothing to show that
# it had stopped working. The fields wanted here are flat strings and one boolean, so a sed
# fallback covers them; jq is used when present because it is the one that is actually correct.
have_jq=$(command -v jq 2>/dev/null)
q() {
  local key="$1" out
  if [ -n "$have_jq" ]; then
    printf '%s' "$input" | "$have_jq" -r ".$key // empty" 2>/dev/null
    return
  fi
  out=$(printf '%s' "$input" |
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
  [ -z "$out" ] && out=$(printf '%s' "$input" |
    sed -n 's/.*"'"$key"'"[[:space:]]*:[[:space:]]*\([A-Za-z0-9._-]*\).*/\1/p' | head -1)
  printf '%s' "$out"
}

# 1. Loop guard: we already blocked once and the model is answering us.
[ "$(q stop_hook_active)" = "true" ] && exit 0

cwd=$(q cwd)
[ -d "$cwd" ] && cd "$cwd" || exit 0

# 2. Only inside a git repo (worktrees included).
git rev-parse --git-dir >/dev/null 2>&1 || exit 0

branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
[ -z "$branch" ] || [ "$branch" = "HEAD" ] && exit 0

# 3. The default branch is where work lands, so being on it means nothing is pending review.
default_branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
default_branch=${default_branch#origin/}
[ -z "$default_branch" ] && default_branch=master
[ "$branch" = "$default_branch" ] && exit 0

upstream="origin/$default_branch"
git rev-parse --verify --quiet "$upstream" >/dev/null || exit 0

# 4. What is unlanded: uncommitted changes, and commits this branch has that the default branch
# does not. Both are read locally -- no fetch, so a merged-but-unfetched branch can still look
# ahead; the PR check below is what catches that case.
dirty=$(git status --porcelain 2>/dev/null)
ahead=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
[ -z "$dirty" ] && [ "$ahead" = "0" ] && exit 0

# 5. A Stop does not mean the work settled, only that the turn yielded: backgrounded builds, test
# runs and PR watchers keep running across it, and the session is woken again when they finish.
# Nudging mid-flight asks about work that is still happening, so defer -- silently, and WITHOUT
# stamping, so the question gets asked once the state stops moving.
#
# This harness writes each background task to <session dir>/tasks/<id>.output and appends an exit
# marker when it ends. A task file with no marker is either running or was abandoned, so recency
# decides: an old unmarked file is a corpse, not a running job, and must not mute the hook forever.
sid=$(q session_id)
if [ -n "$sid" ]; then
  for tasks_dir in /private/tmp/claude-*/*/"$sid"/tasks "${TMPDIR:-/tmp}"/claude-*/*/"$sid"/tasks; do
    [ -d "$tasks_dir" ] || continue
    while IFS= read -r out; do
      grep -aq '^\[exited with code' "$out" || exit 0
    done < <(find "$tasks_dir" -name '*.output' -mmin -30 2>/dev/null)
  done
fi

# 6. A turn that ends by asking the user something is already waiting on them; blocking it would
# talk over the question. Heuristic, and deliberately cheap: worst case is one skipped nudge.
transcript=$(q transcript_path)
if [ -f "$transcript" ] && tail -c 20000 "$transcript" | tail -3 | grep -q 'AskUserQuestion'; then
  exit 0
fi

# 7. One nudge per state: the same tree and the same HEAD do not get asked twice, so follow-up
# questions in a dirty worktree stay quiet.
hash_cmd=$(command -v shasum || command -v sha1sum || command -v cksum)
state=$(printf '%s\n%s\n%s' "$branch" "$(git rev-parse HEAD)" "$dirty" | "$hash_cmd" | cut -d' ' -f1)
stamp_dir="${TMPDIR:-/tmp}/claude-ship-pr-nudge"
mkdir -p "$stamp_dir" 2>/dev/null
stamp="$stamp_dir/$(q session_id)-$state"
[ -f "$stamp" ] && exit 0

# 8. A branch that already has a PR has been shipped; monitoring it is the session's own business.
# The only network call, and only once the local checks say something is pending.
if command -v gh >/dev/null 2>&1; then
  pr_state=$(gh pr view "$branch" --json state --jq .state 2>/dev/null)
  if [ -n "$pr_state" ]; then
    touch "$stamp"
    exit 0
  fi
fi

touch "$stamp"
{
  printf 'Unlanded work: branch %s' "$branch"
  [ "$ahead" != "0" ] && printf ', %s commit(s) ahead of %s' "$ahead" "$upstream"
  [ -n "$dirty" ] && printf ', uncommitted changes'
  printf ', no PR.\n'
  printf 'If the goal is finished, invoke the ship-pr skill to land it. If it is not -- work still\n'
  printf 'in progress, an investigation that changed nothing, a path that went wrong, or the user\n'
  printf 'already said how to land it -- say which in one line and stop.\n'
} >&2
exit 2
