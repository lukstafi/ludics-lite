#!/usr/bin/env bash
# Safely remove a merged topic worktree and branch after ship-pr has confirmed the PR is merged.

set -uo pipefail

fail() {
  echo "post-merge-cleanup.sh: $*" >&2
  exit 1
}

usage() {
  cat >&2 <<'EOF'
usage: post-merge-cleanup.sh <main-checkout> <session-worktree> <branch>
       post-merge-cleanup.sh <main-checkout> <session-worktree> <branch> \
         --force-integrated "why this squash/rebase merge is confirmed"

The ordinary path requires the topic branch to be an ancestor of origin/master. Use
--force-integrated only after independently confirming a squash or rebase merge; its non-empty
reason is printed in the cleanup record.
EOF
  exit 2
}

canonical_dir() {
  [ -d "$1" ] || fail "directory does not exist: $1"
  (cd "$1" && pwd -P) || fail "cannot resolve directory: $1"
}

git_path() {
  local checkout="$1" value="$2"
  case "$value" in
  /*) canonical_dir "$value" ;;
  *) canonical_dir "$checkout/$value" ;;
  esac
}

[ "$#" -ge 3 ] || usage

MAIN=$(canonical_dir "$1") || exit $?
SESSION=$(canonical_dir "$2") || exit $?
BRANCH="$3"
shift 3

FORCE_REASON=""
case "$#" in
0) ;;
2)
  [ "$1" = "--force-integrated" ] || usage
  FORCE_REASON="$2"
  [ -n "$FORCE_REASON" ] || usage
  ;;
*) usage ;;
esac

[ "$BRANCH" != master ] || fail "refusing to clean up the base branch master"
git check-ref-format "refs/heads/$BRANCH" >/dev/null 2>&1 || fail "invalid branch name: $BRANCH"

git -C "$MAIN" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "main checkout is not a git worktree: $MAIN"
git -C "$SESSION" rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
  fail "session path is not a git worktree: $SESSION"
SESSION_TOPLEVEL=$(canonical_dir "$(git -C "$SESSION" rev-parse --show-toplevel)") || exit $?
[ "$SESSION" = "$SESSION_TOPLEVEL" ] ||
  fail "session-worktree must be the worktree root ($SESSION_TOPLEVEL), not a directory inside it"

MAIN_COMMON=$(git_path "$MAIN" "$(git -C "$MAIN" rev-parse --git-common-dir)") || exit $?
MAIN_GIT=$(git_path "$MAIN" "$(git -C "$MAIN" rev-parse --git-dir)") || exit $?
SESSION_COMMON=$(git_path "$SESSION" "$(git -C "$SESSION" rev-parse --git-common-dir)") || exit $?
[ "$MAIN_GIT" = "$MAIN_COMMON" ] || fail "main-checkout is a linked worktree, not the primary checkout: $MAIN"
[ "$MAIN" != "$SESSION" ] || fail "main checkout and session worktree must be different paths"
[ "$SESSION_COMMON" = "$MAIN_COMMON" ] || fail "main checkout and session worktree belong to different repositories"

git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BRANCH" ||
  fail "local branch does not exist: $BRANCH"

SESSION_REF=$(git -C "$SESSION" symbolic-ref -q HEAD 2>/dev/null || true)
if [ -n "$SESSION_REF" ]; then
  [ "$SESSION_REF" = "refs/heads/$BRANCH" ] ||
    fail "session worktree owns ${SESSION_REF#refs/heads/}, not $BRANCH"
else
  SESSION_HEAD=$(git -C "$SESSION" rev-parse HEAD) || fail "cannot read detached session HEAD"
  BRANCH_HEAD=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH") || fail "cannot read $BRANCH"
  [ "$SESSION_HEAD" = "$BRANCH_HEAD" ] ||
    fail "detached session HEAD is not the tip of $BRANCH"
fi

# Fetch before the safety decision: local master may be stale, while origin/master is the state
# whose PR merge was independently confirmed. This also makes the later owner-specific update a
# local fast-forward rather than a second network-dependent decision point.
git -C "$MAIN" fetch --prune origin || fail "could not fetch origin"
git -C "$MAIN" show-ref --verify --quiet refs/remotes/origin/master ||
  fail "origin/master does not exist"

if [ -z "$FORCE_REASON" ]; then
  git -C "$MAIN" merge-base --is-ancestor "refs/heads/$BRANCH" refs/remotes/origin/master ||
    fail "$BRANCH is not an ancestor of origin/master; independently confirm a squash/rebase merge and use --force-integrated with a reason"
else
  echo "post-merge-cleanup.sh: FORCE-INTEGRATED override: $FORCE_REASON" >&2
fi

# Read and delete the branch through the same push endpoint, leasing the mutation against the OID
# just observed. A missing remote branch is a safe retry state after an interrupted cleanup.
ORIGIN_PUSH_URLS=$(git -C "$MAIN" remote get-url --push --all origin) ||
  fail "could not resolve origin's push endpoint"
[ -n "$ORIGIN_PUSH_URLS" ] || fail "origin has no push endpoint"
case "$ORIGIN_PUSH_URLS" in
*$'\n'*) fail "origin has multiple push endpoints; refusing ambiguous branch deletion" ;;
esac
ORIGIN_PUSH_URL="$ORIGIN_PUSH_URLS"

REMOTE_BRANCH_LINE=$(git -C "$MAIN" ls-remote --exit-code --heads "$ORIGIN_PUSH_URL" "refs/heads/$BRANCH")
REMOTE_BRANCH_STATUS=$?
case "$REMOTE_BRANCH_STATUS" in
0)
  REMOTE_BRANCH_OID=${REMOTE_BRANCH_LINE%%[[:space:]]*}
  LOCAL_BRANCH_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH") || fail "cannot read local $BRANCH"
  [ "$REMOTE_BRANCH_OID" = "$LOCAL_BRANCH_OID" ] ||
    fail "origin/$BRANCH moved from local $LOCAL_BRANCH_OID to $REMOTE_BRANCH_OID; refusing to delete its newer tip"
  git -C "$MAIN" push --force-with-lease="refs/heads/$BRANCH:$REMOTE_BRANCH_OID" \
    "$ORIGIN_PUSH_URL" ":refs/heads/$BRANCH" ||
    fail "could not lease-delete origin/$BRANCH at $REMOTE_BRANCH_OID"
  ;;
2)
  echo "post-merge-cleanup.sh: origin/$BRANCH is already absent" >&2
  ;;
*) fail "could not determine whether origin/$BRANCH exists (ls-remote exit $REMOTE_BRANCH_STATUS)" ;;
esac
git -C "$MAIN" fetch --prune origin || fail "could not refresh origin after branch deletion"

# Git permits at most one worktree to own master, but the three possible states need different
# commands: update the branch ref directly when nobody owns it, or fast-forward the owning
# worktree (which may or may not be the primary checkout).
MASTER_OWNER=""
MASTER_OWNER_COUNT=0
CURRENT_WORKTREE=""
while IFS= read -r -d '' FIELD; do
  case "$FIELD" in
  worktree\ *) CURRENT_WORKTREE=${FIELD#worktree } ;;
  "branch refs/heads/master")
    MASTER_OWNER="$CURRENT_WORKTREE"
    MASTER_OWNER_COUNT=$((MASTER_OWNER_COUNT + 1))
    ;;
  esac
done < <(git -C "$MAIN" worktree list --porcelain -z)

[ "$MASTER_OWNER_COUNT" -le 1 ] || fail "more than one worktree reports owning master"
if [ "$MASTER_OWNER_COUNT" -eq 0 ]; then
  git -C "$MAIN" fetch origin refs/heads/master:refs/heads/master ||
    fail "could not fast-forward unchecked-out master"
else
  git -C "$MASTER_OWNER" merge --ff-only refs/remotes/origin/master ||
    fail "could not fast-forward master in its owning worktree: $MASTER_OWNER"
fi

LOCAL_MASTER=$(git -C "$MAIN" rev-parse refs/heads/master) || fail "cannot read local master"
REMOTE_MASTER=$(git -C "$MAIN" rev-parse refs/remotes/origin/master) || fail "cannot read origin/master"
[ "$LOCAL_MASTER" = "$REMOTE_MASTER" ] || fail "local master did not reach origin/master"

if [ -n "$SESSION_REF" ]; then
  git -C "$SESSION" checkout --detach >/dev/null || fail "could not detach the session worktree"
fi

# Do not inherit a cwd that the next command removes. This also lets the helper finish when invoked
# from inside the session worktree itself.
cd "${TMPDIR:-/tmp}" || fail "cannot move out of the session worktree before removing it"
git -C "$MAIN" worktree remove "$SESSION" || fail "could not remove session worktree: $SESSION"

if [ -n "$FORCE_REASON" ]; then
  git -C "$MAIN" branch -D "$BRANCH" || fail "could not delete integrated branch: $BRANCH"
else
  git -C "$MAIN" merge-base --is-ancestor "refs/heads/$BRANCH" refs/heads/master ||
    fail "$BRANCH is not an ancestor of the updated local master"
  git -C "$MAIN" branch -D "$BRANCH" || fail "could not delete ancestry-verified branch: $BRANCH"
fi

echo "post-merge-cleanup.sh: cleaned $BRANCH and removed $SESSION"
