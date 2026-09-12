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

# Both Claude Code and Codex send JSON on stdin and accept exit 2 + stderr at Stop.
# Never approximate JSON with sed: escaped paths and multiline records are valid input.
# Python is a fallback for fleet boxes without jq; without either parser, stay quiet.
have_jq=$(command -v jq 2>/dev/null)
have_python=$(command -v python3 2>/dev/null)
[ -n "$have_jq$have_python" ] || exit 0
q() {
  if [ -n "$have_jq" ]; then
    printf '%s' "$input" | "$have_jq" -r --arg key "$1" '.[$key] // empty' 2>/dev/null
  else
    printf '%s' "$input" | "$have_python" -c '
import json, sys
try:
    value = json.load(sys.stdin).get(sys.argv[1])
    if isinstance(value, bool):
        print(str(value).lower())
    elif isinstance(value, str):
        print(value)
except (ValueError, AttributeError):
    pass
' "$1" 2>/dev/null
  fi
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
dirty=$(git status --porcelain 2>/dev/null) || exit 0
ahead=$(git rev-list --count "$upstream..HEAD" 2>/dev/null) || exit 0
[ -z "$dirty" ] && [ "$ahead" = "0" ] && exit 0

# 5. A Stop does not mean the work settled, only that the turn yielded: backgrounded builds, test
# runs and PR watchers keep running across it, and the session is woken again when they finish.
# Nudging mid-flight asks about work that is still happening, so defer -- silently, and WITHOUT
# stamping, so the question gets asked once the state stops moving.
#
# Claude Code writes each background task to <session dir>/tasks/<id>.output and appends an exit
# marker when it ends. A task file with no marker is either running or was abandoned, so recency
# decides: an old unmarked file is a corpse, not a running job, and must not mute the hook forever.
# Codex does not use Claude's task files. Do not infer its background state from them.
# Its Stop payload adds turn_id; the shared loop guard and coarse stamp still apply.
sid=$(q session_id)
[ -n "$sid" ] || exit 0
if [ -z "$(q turn_id)" ]; then
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
if [ -f "$transcript" ] && tail -c 20000 "$transcript" | tail -3 | grep -Eq 'AskUserQuestion|request_user_input(_async)?'; then
  exit 0
fi

# 7. Deliberately coarse: more edits to the same dirty files do NOT reset the nudge.
# Include the worktree and session in the hash, both to isolate repos and to avoid using
# an input session id as a path. Atomic mkdir lets concurrent Stops share one claim.
hash_cmd=$(command -v shasum || command -v sha1sum || command -v cksum)
state=$(printf '%s\n' "$(pwd -P)" "$sid" "$branch" "$(git rev-parse HEAD)" "$dirty" | "$hash_cmd" | cut -d' ' -f1)
stamp_dir="${TMPDIR:-/tmp}/ship-pr-nudge"
mkdir -p "$stamp_dir" 2>/dev/null || exit 0
stamp="$stamp_dir/$state"
[ -e "$stamp" ] && exit 0

# 8. A branch that already has a PR has been shipped; monitoring it is the session's own business.
# The only network call, and only once the local checks say something is pending.
# Keep ALL PR states exempt: closed PRs may be deliberately abandoned experiments.
# A successful empty list proves absence; auth/network errors and missing gh do not.
command -v gh >/dev/null 2>&1 || exit 0
pr_count=$(gh pr list --head "$branch" --state all --limit 1 --json number --jq length 2>/dev/null) || exit 0
case "$pr_count" in
  0) ;;
  1) mkdir "$stamp" 2>/dev/null; exit 0 ;;
  *) exit 0 ;;
esac

mkdir "$stamp" 2>/dev/null || exit 0
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
