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

atomic_rename() {
  # Shell mv treats an existing directory as a container. The rename(2) syscall instead replaces
  # an empty target directory or refuses a nonempty one, so a same-user target race cannot nest the
  # worktree below an attacker-created path while reporting success.
  perl -e 'rename $ARGV[0], $ARGV[1] or die "$ARGV[0] -> $ARGV[1]: $!\n"' -- "$1" "$2"
}

refuse_initialized_submodules() {
  local worktree="$1" description="$2" line status
  status=$(git -C "$worktree" submodule status --recursive) ||
    fail "could not inspect $description submodules: $worktree"
  while IFS= read -r line; do
    case "$line" in
    "" | -*) ;;
    *) fail "$description has an initialized submodule; deinitialize it before cleanup: ${line#?}" ;;
    esac
  done <<<"$status"
}

scan_branch_owner() {
  local target_ref="$1" worktree_list field current_worktree=""
  BRANCH_OWNER=""
  BRANCH_OWNER_COUNT=0
  SESSION_LOCKED=0
  worktree_list=$(git -C "$MAIN" worktree list --porcelain) || fail "could not inspect registered worktrees"
  while IFS= read -r field; do
    case "$field" in
    worktree\ *) current_worktree=${field#worktree } ;;
    locked*) [ "$current_worktree" != "$SESSION" ] || SESSION_LOCKED=1 ;;
    esac
    if [ "$field" = "branch $target_ref" ]; then
      BRANCH_OWNER="$current_worktree"
      BRANCH_OWNER_COUNT=$((BRANCH_OWNER_COUNT + 1))
    fi
  done <<<"$worktree_list"
}

restore_remote_topic() {
  local recovery_oid="$1"
  if git -C "$MAIN" push --force-with-lease="refs/heads/$BRANCH:" \
    "$ORIGIN_PUSH_URL" "$recovery_oid:refs/heads/$BRANCH"; then
    return 0
  fi
  # A competing writer may have restored another recovery tip first. That is still safer than an
  # absent ref; distinguish it from a transport failure that left no recovery branch at all.
  git -C "$MAIN" ls-remote --exit-code --heads "$ORIGIN_PUSH_URL" \
    "refs/heads/$BRANCH" >/dev/null 2>&1
}

cleanup_reservations() {
  if [ "${SESSION_HEAD_LOCK_OWNED:-0}" -eq 1 ] && [ -n "${SESSION_HEAD_LOCK:-}" ] &&
    [ -f "$SESSION_HEAD_LOCK" ]; then
    unlink "$SESSION_HEAD_LOCK" >/dev/null 2>&1 || true
  fi
  if [ "${CAPABILITY_REF_OWNED:-0}" -eq 1 ] && [ -n "${CAPABILITY_REF:-}" ]; then
    git -C "$MAIN" symbolic-ref --delete "$CAPABILITY_REF" >/dev/null 2>&1 || true
  fi
  if [ -n "${TOPIC_RESERVATION:-}" ] && [ -d "$TOPIC_RESERVATION" ]; then
    git -C "$MAIN" worktree remove --force "$TOPIC_RESERVATION" >/dev/null 2>&1 || true
  fi
  if [ "${ORIGINAL_MASTER_DETACHED:-0}" -eq 1 ] &&
    [ -n "${ORIGINAL_MASTER_OWNER:-}" ] && [ -d "$ORIGINAL_MASTER_OWNER" ]; then
    RECOVERY_MASTER=$(git -C "$MAIN" rev-parse refs/heads/master 2>/dev/null || true)
    if [ -n "$RECOVERY_MASTER" ] &&
      git -C "$ORIGINAL_MASTER_OWNER" switch --detach --no-overwrite-ignore \
        "$RECOVERY_MASTER" >/dev/null 2>&1 &&
      printf 'option no-deref\nsymref-update HEAD refs/heads/master oid %s\n' "$RECOVERY_MASTER" |
        git -C "$ORIGINAL_MASTER_OWNER" update-ref --stdin >/dev/null 2>&1; then
      ORIGINAL_MASTER_DETACHED=0
    fi
  fi
  if [ -n "${MASTER_RESERVATION:-}" ] && [ -d "$MASTER_RESERVATION" ]; then
    git -C "$MAIN" worktree remove --force "$MASTER_RESERVATION" >/dev/null 2>&1 || true
  fi
  if [ "${ORIGINAL_MASTER_DETACHED:-0}" -eq 1 ] &&
    [ -n "${ORIGINAL_MASTER_OWNER:-}" ] && [ -d "$ORIGINAL_MASTER_OWNER" ]; then
    git -C "$ORIGINAL_MASTER_OWNER" switch --no-overwrite-ignore -- master >/dev/null 2>&1 || true
  fi
  [ -z "${SESSION_ARCHIVE:-}" ] || rmdir "$SESSION_ARCHIVE" >/dev/null 2>&1 || true
  [ -z "${LATE_SESSION_ARCHIVE:-}" ] || rmdir "$LATE_SESSION_ARCHIVE" >/dev/null 2>&1 || true
}

MASTER_RESERVATION=""
ORIGINAL_MASTER_DETACHED=0
SESSION_HEAD_LOCK=""
SESSION_HEAD_LOCK_OWNED=0
CAPABILITY_REF=""
CAPABILITY_REF_OWNED=0
TOPIC_RESERVATION=""
trap cleanup_reservations EXIT

[ "$#" -ge 3 ] || usage

MAIN=$(canonical_dir "$1") || exit $?
SESSION=$(canonical_dir "$2") || exit $?
SESSION_ORIGINAL="$SESSION"
TEMP_ROOT=$(canonical_dir "${TMPDIR:-/tmp}") || exit $?
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
[ ! -e "$MAIN_COMMON/config.lock" ] || fail "repository config is locked; retry after the lock clears"
command -v perl >/dev/null 2>&1 || fail "Perl is required for atomic session archiving"

git -C "$MAIN" show-ref --verify --quiet "refs/heads/$BRANCH" ||
  fail "local branch does not exist: $BRANCH"
if git -C "$MAIN" symbolic-ref -q "refs/heads/$BRANCH" >/dev/null 2>&1; then
  fail "local branch ref is symbolic rather than direct: refs/heads/$BRANCH"
fi
LOCAL_BRANCH_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH") || fail "cannot read local $BRANCH"

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

scan_branch_owner "refs/heads/$BRANCH"
[ "$SESSION_LOCKED" -eq 0 ] || fail "session worktree is locked; unlock it before cleanup"
if [ -n "$SESSION_REF" ]; then
  [ "$BRANCH_OWNER_COUNT" -eq 1 ] ||
    fail "$BRANCH must be owned only by the attached session worktree"
  BRANCH_OWNER=$(canonical_dir "$BRANCH_OWNER") || exit $?
  [ "$BRANCH_OWNER" = "$SESSION" ] || fail "$BRANCH is owned by another worktree: $BRANCH_OWNER"
else
  [ "$BRANCH_OWNER_COUNT" -eq 0 ] || fail "detached session cannot clean $BRANCH while another worktree owns it: $BRANCH_OWNER"
fi
SESSION_STATUS=$(git -C "$SESSION" status --porcelain --untracked-files=normal --ignored=matching) ||
  fail "could not inspect session worktree cleanliness"
[ -z "$SESSION_STATUS" ] || fail "session worktree is dirty; commit, stash, or remove its changes before cleanup"
refuse_initialized_submodules "$SESSION" "session worktree"

SESSION_HEAD_PATH=$(git -C "$SESSION" rev-parse --git-path HEAD) || fail "cannot locate session HEAD"
case "$SESSION_HEAD_PATH" in
/*) ;;
*) SESSION_HEAD_PATH="$SESSION/$SESSION_HEAD_PATH" ;;
esac
SESSION_HEAD_DIR=$(canonical_dir "$(dirname "$SESSION_HEAD_PATH")") || exit $?
SESSION_HEAD_LOCK="$SESSION_HEAD_DIR/$(basename "$SESSION_HEAD_PATH").lock"
[ ! -e "$SESSION_HEAD_LOCK" ] || fail "session HEAD is locked; retry after its Git operation finishes"

# Allocate both sibling archives before any ref mutation. Keeping the empty directories reserved
# proves the parent is writable and prevents a later name race; teardown moves data beneath them.
SESSION_PARENT=$(dirname "$SESSION")
SESSION_BASENAME=$(basename "$SESSION")
SESSION_ARCHIVE=$(mktemp -d "$SESSION_PARENT/.${SESSION_BASENAME}.ship-pr-recovery.XXXXXX") ||
  fail "could not allocate a session recovery archive beside $SESSION"
LATE_SESSION_ARCHIVE=$(mktemp -d "$SESSION_PARENT/.${SESSION_BASENAME}.ship-pr-late-data.XXXXXX") ||
  fail "could not allocate a late-data recovery archive beside $SESSION"

# symref-update provides the compare-and-swap used by the master ownership handoff. Probe it before
# master or topic mutation so older Git versions refuse cleanly rather than failing mid-cleanup.
CAPABILITY_REF="refs/ship-pr/capability-probe-$$"
git -C "$MAIN" show-ref --verify --quiet "$CAPABILITY_REF" &&
  fail "temporary capability ref already exists: $CAPABILITY_REF"
git -C "$MAIN" symbolic-ref "$CAPABILITY_REF" refs/heads/master ||
  fail "could not create the symref capability probe"
CAPABILITY_REF_OWNED=1
if ! printf 'option no-deref\nsymref-update %s refs/heads/master ref refs/heads/master\n' "$CAPABILITY_REF" |
  git -C "$MAIN" update-ref --stdin >/dev/null 2>&1; then
  if git -C "$MAIN" symbolic-ref --delete "$CAPABILITY_REF" >/dev/null 2>&1; then
    CAPABILITY_REF_OWNED=0
  fi
  fail "Git lacks update-ref symref transactions required for safe cleanup"
fi
git -C "$MAIN" symbolic-ref --delete "$CAPABILITY_REF" ||
  fail "could not remove the symref capability probe"
CAPABILITY_REF_OWNED=0

# Fetch before the safety decision: local master may be stale, while origin/master is the state
# whose PR merge was independently confirmed. This also makes the later owner-specific update a
# local fast-forward rather than a second network-dependent decision point.
if git -C "$MAIN" symbolic-ref -q refs/remotes/origin/master >/dev/null 2>&1; then
  fail "origin/master is symbolic rather than a direct remote-tracking ref"
fi
git -C "$MAIN" fetch --no-tags origin \
  "+refs/heads/master:refs/remotes/origin/master" || fail "could not fetch origin/master explicitly"
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
ORIGIN_FETCH_URL=$(git -C "$MAIN" remote get-url origin) || fail "could not resolve origin's fetch endpoint"
[ "$ORIGIN_FETCH_URL" = "$ORIGIN_PUSH_URL" ] ||
  fail "origin has distinct fetch and push endpoints; cleanup requires one repository for master and topic"
if git -C "$MAIN" symbolic-ref -q "refs/remotes/origin/$BRANCH" >/dev/null 2>&1; then
  fail "remote-tracking branch is symbolic rather than direct: refs/remotes/origin/$BRANCH"
fi

# Prove and perform the local master fast-forward before deleting the remote recovery ref. Keep a
# checked-out master continuously owned so Git refuses another worktree's checkout, conditionally
# update the named ref, then refresh that same clean owner from the new tip.
if git -C "$MAIN" symbolic-ref -q refs/heads/master >/dev/null 2>&1; then
  fail "local master ref is symbolic rather than direct"
fi
LOCAL_MASTER=$(git -C "$MAIN" rev-parse refs/heads/master) || fail "cannot read local master"
REMOTE_MASTER=$(git -C "$MAIN" rev-parse refs/remotes/origin/master) || fail "cannot read origin/master"
git -C "$MAIN" merge-base --is-ancestor "$LOCAL_MASTER" "$REMOTE_MASTER" ||
  fail "local master cannot fast-forward to origin/master"

scan_branch_owner refs/heads/master
[ "$BRANCH_OWNER_COUNT" -le 1 ] || fail "more than one worktree reports owning master"
if [ "$BRANCH_OWNER_COUNT" -eq 0 ]; then
  MASTER_RESERVATION=$(mktemp -d "$TEMP_ROOT/ship-pr-master-reserve.XXXXXX") ||
    fail "could not allocate a temporary master reservation"
  rmdir "$MASTER_RESERVATION" || fail "could not prepare the temporary master reservation path"
  git -C "$MAIN" worktree add "$MASTER_RESERVATION" master >/dev/null ||
    fail "could not reserve unchecked-out master in a temporary worktree"
  MASTER_OWNER="$MASTER_RESERVATION"
  ORIGINAL_MASTER_OWNER=""
else
  MASTER_OWNER="$BRANCH_OWNER"
  ORIGINAL_MASTER_OWNER="$BRANCH_OWNER"
fi

MASTER_OWNER_REF=$(git -C "$MASTER_OWNER" symbolic-ref -q HEAD 2>/dev/null || true)
[ "$MASTER_OWNER_REF" = refs/heads/master ] ||
  fail "master owner changed branches before its fast-forward: $MASTER_OWNER"
MASTER_OWNER_HEAD=$(git -C "$MASTER_OWNER" rev-parse HEAD) || fail "cannot read master owner HEAD"
[ "$MASTER_OWNER_HEAD" = "$LOCAL_MASTER" ] || fail "master owner's HEAD disagrees with local master"
MASTER_OWNER_STATUS=$(git -C "$MASTER_OWNER" status \
  --porcelain --untracked-files=normal --ignored=matching) ||
  fail "could not inspect master owner cleanliness"
[ -z "$MASTER_OWNER_STATUS" ] || fail "master owner is dirty; clean it before cleanup: $MASTER_OWNER"
refuse_initialized_submodules "$MASTER_OWNER" "master owner"
IGNORED_COLLISION=""
while IFS= read -r -d '' CHANGED_PATH; do
  if { [ -e "$MASTER_OWNER/$CHANGED_PATH" ] || [ -L "$MASTER_OWNER/$CHANGED_PATH" ]; } &&
    git -C "$MASTER_OWNER" check-ignore -q -- "$CHANGED_PATH"; then
    IGNORED_COLLISION="$CHANGED_PATH"
    break
  fi
  if [ -d "$MASTER_OWNER/$CHANGED_PATH" ]; then
    REMOTE_PATH_TYPE=$(git -C "$MAIN" cat-file -t "$REMOTE_MASTER:$CHANGED_PATH" 2>/dev/null || true)
    if [ "$REMOTE_PATH_TYPE" != tree ]; then
      IGNORED_DESCENDANT=$(git -C "$MASTER_OWNER" ls-files --others --ignored \
        --exclude-standard -- "$CHANGED_PATH" | sed -n '1p')
      if [ -n "$IGNORED_DESCENDANT" ]; then
        IGNORED_COLLISION="$IGNORED_DESCENDANT"
        break
      fi
    fi
  fi
done < <(git -C "$MAIN" diff --name-only -z "$LOCAL_MASTER" "$REMOTE_MASTER")
[ -z "$IGNORED_COLLISION" ] ||
  fail "master fast-forward would overwrite ignored local data: $MASTER_OWNER/$IGNORED_COLLISION"

# Move branch ownership to a helper-only worktree before the named ref update. The original owner
# is never reset: after the reservation is refreshed, an option-safe switch back to master refuses
# any tracked or ignored data that appeared concurrently.
if [ -n "$ORIGINAL_MASTER_OWNER" ]; then
  MASTER_RESERVATION=$(mktemp -d "$TEMP_ROOT/ship-pr-master-reserve.XXXXXX") ||
    fail "could not allocate a temporary master reservation"
  rmdir "$MASTER_RESERVATION" || fail "could not prepare the temporary master reservation path"
  git -C "$MAIN" worktree add --detach "$MASTER_RESERVATION" "$LOCAL_MASTER" >/dev/null ||
    fail "could not prepare a temporary master reservation"
  MASTER_RESERVATION=$(canonical_dir "$MASTER_RESERVATION") || exit $?
  git -C "$ORIGINAL_MASTER_OWNER" switch --detach --no-overwrite-ignore "$LOCAL_MASTER" >/dev/null ||
    fail "could not detach the clean master owner for its named update: $ORIGINAL_MASTER_OWNER"
  ORIGINAL_MASTER_DETACHED=1
  git -C "$MASTER_RESERVATION" switch -- master >/dev/null ||
    fail "could not transfer master ownership to its temporary reservation"
fi
git -C "$MAIN" update-ref --no-deref refs/heads/master "$REMOTE_MASTER" "$LOCAL_MASTER" ||
  fail "local master moved after its owner preflight"
git -C "$MASTER_RESERVATION" reset --hard "$REMOTE_MASTER" >/dev/null ||
  fail "master advanced but its helper-only reservation could not be refreshed"
if [ -n "$ORIGINAL_MASTER_OWNER" ]; then
  git -C "$ORIGINAL_MASTER_OWNER" switch --detach --no-overwrite-ignore "$REMOTE_MASTER" >/dev/null ||
    fail "master advanced, but its original owner gained local data: $ORIGINAL_MASTER_OWNER"
  MASTER_OWNER_STATUS=$(git -C "$ORIGINAL_MASTER_OWNER" status \
    --porcelain --untracked-files=normal --ignored=matching) ||
    fail "could not recheck the detached original master owner"
  [ -z "$MASTER_OWNER_STATUS" ] ||
    fail "master owner gained local data during its update; the data was preserved: $ORIGINAL_MASTER_OWNER"
  printf 'option no-deref\nsymref-update HEAD refs/heads/master oid %s\n' "$REMOTE_MASTER" |
    git -C "$ORIGINAL_MASTER_OWNER" update-ref --stdin ||
    fail "original master owner changed after preparation; its HEAD was not rewritten"
  ORIGINAL_MASTER_DETACHED=0
fi
git -C "$MAIN" worktree remove --force "$MASTER_RESERVATION" ||
  fail "master advanced but its temporary reservation could not be removed"
MASTER_RESERVATION=""

LOCAL_MASTER=$(git -C "$MAIN" rev-parse refs/heads/master) || fail "cannot reread local master"
[ "$LOCAL_MASTER" = "$REMOTE_MASTER" ] || fail "local master did not reach origin/master"
CURRENT_TOPIC_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH") || fail "cannot reread local $BRANCH"
[ "$CURRENT_TOPIC_OID" = "$LOCAL_BRANCH_OID" ] ||
  fail "local $BRANCH moved before remote deletion; all topic artifacts were preserved"

# A remote master can change immediately after any finite observation. Keep the validated topic
# reachable locally even after its public branch is deleted, so a later rollback can always be
# recovered rather than turning this cleanup into data loss.
RECOVERY_REF="refs/ship-pr/recovery/$BRANCH/$LOCAL_BRANCH_OID"
if git -C "$MAIN" symbolic-ref -q "$RECOVERY_REF" >/dev/null 2>&1; then
  fail "recovery ref is symbolic rather than a direct ref: $RECOVERY_REF"
fi
if git -C "$MAIN" show-ref --verify --quiet "$RECOVERY_REF"; then
  RECOVERY_OID=$(git -C "$MAIN" rev-parse "$RECOVERY_REF") || fail "cannot read $RECOVERY_REF"
  [ "$RECOVERY_OID" = "$LOCAL_BRANCH_OID" ] || fail "recovery ref points at an unexpected object: $RECOVERY_REF"
else
  git -C "$MAIN" update-ref --no-deref "$RECOVERY_REF" "$LOCAL_BRANCH_OID" "" ||
    fail "could not retain the topic recovery ref: $RECOVERY_REF"
fi

REMOTE_BRANCH_LINE=$(git -C "$MAIN" ls-remote --exit-code --heads "$ORIGIN_PUSH_URL" "refs/heads/$BRANCH")
REMOTE_BRANCH_STATUS=$?
case "$REMOTE_BRANCH_STATUS" in
0)
  REMOTE_BRANCH_OID=${REMOTE_BRANCH_LINE%%[[:space:]]*}
  [ "$REMOTE_BRANCH_OID" = "$LOCAL_BRANCH_OID" ] ||
    fail "origin/$BRANCH moved from local $LOCAL_BRANCH_OID to $REMOTE_BRANCH_OID; refusing to delete its newer tip"
  git -C "$MAIN" push --force-with-lease="refs/heads/$BRANCH:$REMOTE_BRANCH_OID" \
    "$ORIGIN_PUSH_URL" ":refs/heads/$BRANCH" ||
    fail "could not lease-delete origin/$BRANCH at $REMOTE_BRANCH_OID"
  ;;
2)
  # An empty force-with-lease can still delete a ref created after push advertisement. Absence is
  # already the desired state, so do not send a deletion at all; a concurrent creation survives.
  echo "post-merge-cleanup.sh: origin/$BRANCH was already absent (no deletion sent)" >&2
  ;;
*) fail "could not determine whether origin/$BRANCH exists (ls-remote exit $REMOTE_BRANCH_STATUS)" ;;
esac

MASTER_AFTER_LINE=$(git -C "$MAIN" ls-remote --exit-code --heads \
  "$ORIGIN_PUSH_URL" refs/heads/master)
MASTER_AFTER_STATUS=$?
if [ "$MASTER_AFTER_STATUS" -ne 0 ]; then
  restore_remote_topic "$LOCAL_BRANCH_OID" ||
    fail "remote master became unreadable after topic deletion, and the topic could not be restored"
  fail "remote master became unreadable after topic deletion; origin/$BRANCH was restored"
fi
MASTER_AFTER_OID=${MASTER_AFTER_LINE%%[[:space:]]*}
if [ "$MASTER_AFTER_OID" != "$REMOTE_MASTER" ]; then
  restore_remote_topic "$LOCAL_BRANCH_OID" ||
    fail "remote master changed to $MASTER_AFTER_OID, and the topic could not be restored"
  fail "remote master changed from $REMOTE_MASTER to $MASTER_AFTER_OID; origin/$BRANCH was restored"
fi

CURRENT_TOPIC_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH") || fail "cannot reread local $BRANCH"
if [ "$CURRENT_TOPIC_OID" != "$LOCAL_BRANCH_OID" ]; then
  restore_remote_topic "$CURRENT_TOPIC_OID" ||
    fail "local $BRANCH moved after remote deletion, and its new tip could not be restored remotely"
  fail "local $BRANCH moved after remote deletion; its new tip was restored remotely"
fi

if git -C "$MAIN" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  TRACKING_BRANCH_OID=$(git -C "$MAIN" rev-parse "refs/remotes/origin/$BRANCH") ||
    fail "cannot read origin/$BRANCH tracking ref"
  git -C "$MAIN" update-ref --no-deref -d "refs/remotes/origin/$BRANCH" "$TRACKING_BRANCH_OID" ||
    fail "origin/$BRANCH tracking ref changed while pruning it"
fi

# Inspect only the repository-local file that removal edits. Git flattens dotted subsection names,
# so test the standard branch keys exactly instead of treating branch.topic.* as unambiguous when
# topic.child is also a valid branch. Included, global, per-worktree, and custom keys are inherited
# policy rather than branch-owned upstream residue and are deliberately left alone.
for BRANCH_CONFIG_KEY in remote merge pushRemote rebase description; do
  git -C "$MAIN" config --local --no-includes --get \
    "branch.$BRANCH.$BRANCH_CONFIG_KEY" >/dev/null 2>&1
  CONFIG_GET_STATUS=$?
  case "$CONFIG_GET_STATUS" in
  0)
    git -C "$MAIN" config --local --no-includes --unset-all \
      "branch.$BRANCH.$BRANCH_CONFIG_KEY" 2>/dev/null ||
      fail "branch configuration could not be removed; local $BRANCH and its session were preserved"
    ;;
  1) ;;
  *) fail "branch configuration could not be inspected; local $BRANCH and its session were preserved" ;;
  esac
done

# Transfer topic ownership from the session to a temporary worktree, revalidating across the
# handoff. Keeping that reservation attached through update-ref prevents another worktree from
# acquiring the branch between the final owner scan and local deletion.
TOPIC_RESERVATION=$(mktemp -d "$TEMP_ROOT/ship-pr-topic-reserve.XXXXXX") ||
  fail "could not allocate a temporary topic reservation"
rmdir "$TOPIC_RESERVATION" || fail "could not prepare the temporary topic reservation path"
git -C "$MAIN" worktree add --detach "$TOPIC_RESERVATION" "$LOCAL_BRANCH_OID" >/dev/null ||
  fail "could not prepare a temporary topic reservation"
TOPIC_RESERVATION=$(canonical_dir "$TOPIC_RESERVATION") || exit $?
if [ -n "$SESSION_REF" ]; then
  if ! git -C "$SESSION" checkout --detach --no-overwrite-ignore "$LOCAL_BRANCH_OID" >/dev/null; then
    CURRENT_TOPIC_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH" 2>/dev/null || true)
    [ -n "$CURRENT_TOPIC_OID" ] && restore_remote_topic "$CURRENT_TOPIC_OID" ||
      fail "session detach failed, and its current topic tip could not be restored remotely"
    fail "could not detach the session worktree without overwriting local data; its remote ref was restored"
  fi
fi
if ! git -C "$TOPIC_RESERVATION" switch -- "$BRANCH" >/dev/null 2>&1; then
  git -C "$MAIN" worktree remove --force "$TOPIC_RESERVATION" >/dev/null 2>&1 || true
  TOPIC_RESERVATION=""
  CURRENT_TOPIC_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH" 2>/dev/null || true)
  [ -n "$CURRENT_TOPIC_OID" ] && restore_remote_topic "$CURRENT_TOPIC_OID" ||
    fail "topic reservation failed, and its remote recovery ref could not be restored"
  [ -z "$SESSION_REF" ] || git -C "$SESSION" switch -- "$BRANCH" >/dev/null 2>&1 || true
  fail "could not reserve local $BRANCH for deletion; its remote ref was restored"
fi
CURRENT_TOPIC_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH") || fail "cannot reread local $BRANCH"
if [ "$CURRENT_TOPIC_OID" != "$LOCAL_BRANCH_OID" ]; then
  git -C "$TOPIC_RESERVATION" checkout --detach "$LOCAL_BRANCH_OID" >/dev/null 2>&1 || true
  git -C "$MAIN" worktree remove --force "$TOPIC_RESERVATION" >/dev/null 2>&1 || true
  TOPIC_RESERVATION=""
  [ -z "$SESSION_REF" ] || git -C "$SESSION" switch -- "$BRANCH" >/dev/null 2>&1 || true
  restore_remote_topic "$CURRENT_TOPIC_OID" ||
    fail "local $BRANCH moved during ownership handoff, and its new tip could not be restored remotely"
  fail "local $BRANCH moved during ownership handoff; its session and remote tip were preserved"
fi

scan_branch_owner "refs/heads/$BRANCH"
[ "$BRANCH_OWNER_COUNT" -eq 1 ] || fail "$BRANCH reservation was lost before deletion"
BRANCH_OWNER=$(canonical_dir "$BRANCH_OWNER") || exit $?
[ "$BRANCH_OWNER" = "$TOPIC_RESERVATION" ] || fail "$BRANCH was acquired by another worktree: $BRANCH_OWNER"
if [ -z "$FORCE_REASON" ]; then
  git -C "$MAIN" merge-base --is-ancestor "refs/heads/$BRANCH" refs/heads/master ||
    fail "$BRANCH is not an ancestor of the updated local master"
fi

# Atomically move the session aside before unregistering it. `git worktree remove` recursively
# deletes ignored files, so ordinary removal cannot close the final write race. Removing the now-
# missing registered path drops only Git metadata; every former worktree file remains recoverable.
cd "$TEMP_ROOT" || fail "cannot move out of the session worktree before archiving it"
SESSION_ARCHIVED_WORKTREE="$SESSION_ARCHIVE/worktree"
atomic_rename "$SESSION" "$SESSION_ARCHIVED_WORKTREE" ||
  fail "could not archive session worktree atomically: $SESSION"
# Prevent a detached commit from advancing the archived session after the final read. Removing a
# missing worktree unregisters its metadata without consulting this ref lock, so the exact HEAD can
# be retained before that metadata (including the lock) disappears.
SESSION_HEAD_PATH=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path HEAD) ||
  fail "could not locate the archived session HEAD"
case "$SESSION_HEAD_PATH" in
/*) ;;
*) SESSION_HEAD_PATH="$SESSION_ARCHIVED_WORKTREE/$SESSION_HEAD_PATH" ;;
esac
SESSION_HEAD_DIR=$(canonical_dir "$(dirname "$SESSION_HEAD_PATH")") || exit $?
SESSION_HEAD_LOCK="$SESSION_HEAD_DIR/$(basename "$SESSION_HEAD_PATH").lock"
(set -o noclobber; printf '%s\n' "$$" >"$SESSION_HEAD_LOCK") 2>/dev/null ||
  fail "archived session HEAD is busy; its worktree metadata was preserved"
SESSION_HEAD_LOCK_OWNED=1
SESSION_FINAL_HEAD=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse HEAD) ||
  fail "could not read the archived session's final HEAD"
SESSION_RECOVERY_REF="refs/ship-pr/session-recovery/$BRANCH/$SESSION_FINAL_HEAD"
if git -C "$MAIN" symbolic-ref -q "$SESSION_RECOVERY_REF" >/dev/null 2>&1; then
  fail "session recovery ref is symbolic rather than direct: $SESSION_RECOVERY_REF"
fi
if git -C "$MAIN" show-ref --verify --quiet "$SESSION_RECOVERY_REF"; then
  SESSION_RECOVERY_OID=$(git -C "$MAIN" rev-parse "$SESSION_RECOVERY_REF") ||
    fail "cannot read $SESSION_RECOVERY_REF"
  [ "$SESSION_RECOVERY_OID" = "$SESSION_FINAL_HEAD" ] ||
    fail "session recovery ref points at an unexpected object: $SESSION_RECOVERY_REF"
else
  git -C "$MAIN" update-ref --no-deref "$SESSION_RECOVERY_REF" "$SESSION_FINAL_HEAD" "" ||
    fail "could not retain the archived session HEAD: $SESSION_RECOVERY_REF"
fi
if ! git -C "$MAIN" worktree remove "$SESSION"; then
  { [ -e "$SESSION" ] || [ -L "$SESSION" ]; } ||
    fail "session was archived at $SESSION_ARCHIVE but its worktree registration could not be removed"
  atomic_rename "$SESSION" "$LATE_SESSION_ARCHIVE/data" ||
    fail "late data appeared at $SESSION and could not be moved aside safely"
  git -C "$MAIN" worktree remove "$SESSION" ||
    fail "session and late data were archived, but the worktree registration could not be removed"
else
  rmdir "$LATE_SESSION_ARCHIVE" || fail "unused late-data archive could not be removed"
  LATE_SESSION_ARCHIVE=""
fi
SESSION_HEAD_LOCK_OWNED=0
SESSION_HEAD_LOCK=""
[ -d "$SESSION_ARCHIVED_WORKTREE" ] || fail "session recovery archive disappeared: $SESSION_ARCHIVED_WORKTREE"

git -C "$MAIN" update-ref --no-deref -d "refs/heads/$BRANCH" "$LOCAL_BRANCH_OID" ||
  fail "local $BRANCH moved from validated tip $LOCAL_BRANCH_OID; its newer ref was preserved"
git -C "$MAIN" worktree remove --force "$TOPIC_RESERVATION" ||
  fail "local $BRANCH was deleted but its temporary reservation could not be removed"
TOPIC_RESERVATION=""

if [ -n "$LATE_SESSION_ARCHIVE" ]; then
  echo "post-merge-cleanup.sh: data appearing at the former session path was archived at $LATE_SESSION_ARCHIVE" >&2
fi
echo "post-merge-cleanup.sh: cleaned $BRANCH and unregistered $SESSION_ORIGINAL; session archived at $SESSION_ARCHIVED_WORKTREE; recovery retained at $RECOVERY_REF and $SESSION_RECOVERY_REF"
