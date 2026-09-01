#!/usr/bin/env bash
# Safely remove a merged topic worktree and branch after ship-pr has confirmed the PR is merged.

set -uo pipefail

# Repository-local environment overrides take precedence over -C and can redirect both reads and
# mutations away from the explicit checkout arguments. Ask Git for its complete local set, then
# clear it before interpreting either path.
GIT_LOCAL_ENV_VARS=$(git rev-parse --local-env-vars 2>/dev/null) || {
  echo "post-merge-cleanup.sh: could not enumerate Git repository-selection environment" >&2
  exit 1
}
for GIT_LOCAL_ENV_VAR in $GIT_LOCAL_ENV_VARS; do
  unset "$GIT_LOCAL_ENV_VAR"
done
unset GIT_LOCAL_ENV_VAR GIT_LOCAL_ENV_VARS
export GIT_NO_REPLACE_OBJECTS=1

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

refuse_session_module_gitdirs() {
  local worktree="$1" git_dir modules first
  git_dir=$(git -C "$worktree" rev-parse --absolute-git-dir) ||
    fail "could not locate session worktree metadata: $worktree"
  modules="$git_dir/modules"
  { [ ! -e "$modules" ] && [ ! -L "$modules" ]; } && return 0
  [ ! -L "$modules" ] || fail "session submodule repository root is symbolic: $modules"
  [ -d "$modules" ] || fail "session submodule repository root is not a directory: $modules"
  first=$(find "$modules" -mindepth 1 -print -quit) ||
    fail "could not inspect residual session submodule repositories: $modules"
  [ -z "$first" ] ||
    fail "session has a residual submodule repository; retain or remove it before cleanup: $first"
}

refuse_private_worktree_refs() {
  local worktree="$1" private_ref
  private_ref=$(git -C "$worktree" for-each-ref --format='%(refname)' \
    refs/worktree refs/bisect refs/rewritten | sed -n '1p') ||
    fail "could not inspect session-local refs: $worktree"
  [ -z "$private_ref" ] ||
    fail "session worktree has a private ref; remove or retain it before cleanup: $private_ref"
}

preflight_session_metadata_locks() {
  local name path path_dir lock symbolic_status
  for name in ORIG_HEAD MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD \
    BISECT_HEAD AUTO_MERGE FETCH_HEAD COMMIT_EDITMSG SQUASH_MSG TAG_EDITMSG NOTES_EDITMSG \
    index config.worktree; do
    path=$(git -C "$SESSION" rev-parse --git-path "$name") ||
      fail "could not locate session metadata: $name"
    case "$path" in
    /*) ;;
    *) path="$SESSION/$path" ;;
    esac
    path_dir=$(canonical_dir "$(dirname "$path")") || exit $?
    path="$path_dir/$(basename "$path")"
    [ ! -L "$path" ] || fail "session metadata is symbolic; replace it before cleanup: $name"
    case "$name" in
    COMMIT_EDITMSG | SQUASH_MSG | TAG_EDITMSG | NOTES_EDITMSG | index | config.worktree) ;;
    *)
      git -C "$SESSION" symbolic-ref -q "$name" >/dev/null 2>&1
      symbolic_status=$?
      case "$symbolic_status" in
      0) fail "session pseudoref is symbolic; replace it before cleanup: $name" ;;
      1) ;;
      *) fail "could not inspect whether the session pseudoref is symbolic: $name" ;;
      esac
      ;;
    esac
    lock="$path_dir/$(basename "$path").lock"
    { [ ! -e "$lock" ] && [ ! -L "$lock" ]; } ||
      fail "session metadata is locked; retry after its Git operation finishes: $name"
  done
}

preflight_sparse_checkout_metadata() {
  local path path_dir lock
  path=$(git -C "$SESSION" rev-parse --git-path info/sparse-checkout) ||
    fail "could not locate session sparse-checkout metadata"
  case "$path" in
  /*) ;;
  *) path="$SESSION/$path" ;;
  esac
  path_dir=$(dirname "$path")
  if [ ! -d "$path_dir" ]; then
    { [ ! -e "$path" ] && [ ! -L "$path" ]; } ||
      fail "session sparse-checkout metadata has an invalid parent"
    return 0
  fi
  path_dir=$(canonical_dir "$path_dir") || exit $?
  path="$path_dir/$(basename "$path")"
  [ ! -L "$path" ] || fail "session sparse-checkout metadata is symbolic"
  lock="$path.lock"
  { [ ! -e "$lock" ] && [ ! -L "$lock" ]; } ||
    fail "session sparse-checkout metadata is locked; retry after its Git operation finishes"
}

refuse_active_session_operations() {
  local worktree="${1:-$SESSION}" description="${2:-session}" name path path_dir
  for name in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD \
    BISECT_START BISECT_LOG BISECT_NAMES BISECT_TERMS BISECT_RUN \
    BISECT_ANCESTORS_OK BISECT_EXPECTED_REV sequencer rebase-merge rebase-apply; do
    path=$(git -C "$worktree" rev-parse --git-path "$name") ||
      fail "could not locate session operation state: $name"
    case "$path" in
    /*) ;;
    *) path="$worktree/$path" ;;
    esac
    path_dir=$(canonical_dir "$(dirname "$path")") || exit $?
    path="$path_dir/$(basename "$path")"
    { [ ! -e "$path" ] && [ ! -L "$path" ]; } ||
      fail "$description has an active or retained Git operation; finish or abort it before cleanup: $name"
  done
}

refuse_index_resolve_undo() {
  local worktree="$1" description="$2" first
  first=$(git -C "$worktree" ls-files --resolve-undo | sed -n '1p') ||
    fail "could not inspect $description resolve-undo state: $worktree"
  [ -z "$first" ] ||
    fail "$description index has resolve-undo data; resolve or remove it before cleanup: $worktree"
}

refuse_hidden_index_changes() {
  local worktree="$1" description="$2" index_path index_dir entry path
  index_path=$(git -C "$worktree" rev-parse --git-path index) ||
    fail "could not locate $description index: $worktree"
  case "$index_path" in
  /*) ;;
  *) index_path="$worktree/$index_path" ;;
  esac
  index_dir=$(canonical_dir "$(dirname "$index_path")") || exit $?
  index_path="$index_dir/$(basename "$index_path")"
  [ ! -L "$index_path" ] || fail "$description index is symbolic: $worktree"
  [ -f "$index_path" ] || fail "$description index is missing: $worktree"
  { [ ! -e "$index_path.lock" ] && [ ! -L "$index_path.lock" ]; } ||
    fail "$description index is locked; retry after its Git operation finishes: $worktree"
  MASTER_INDEX_PROBE=$(mktemp "$index_dir/.ship-pr-index-probe.XXXXXX") ||
    fail "could not allocate the $description index probe"
  cp -p "$index_path" "$MASTER_INDEX_PROBE" || fail "could not snapshot the $description index"
  MASTER_SKIP_PATHS_FILE=$(mktemp "$index_dir/.ship-pr-skip-paths.XXXXXX") ||
    fail "could not allocate the $description skip-worktree snapshot"
  GIT_INDEX_FILE="$MASTER_INDEX_PROBE" git -C "$worktree" ls-files -t -z \
    >"$MASTER_SKIP_PATHS_FILE" || fail "could not enumerate $description index flags"
  # Clear the copied flag only for materialized paths: a skip-worktree entry with no file on disk
  # is a sparse checkout's intentional absence, and clearing it would make the probe read a clean
  # sparse owner as "tracked file deleted". A materialized skip-worktree file still has its flag
  # cleared, so an edit hidden behind the flag is still detected.
  while IFS= read -r -d '' entry; do
    case "$entry" in
    S\ *)
      path=${entry#S }
      { [ -e "$worktree/$path" ] || [ -L "$worktree/$path" ]; } || continue
      GIT_INDEX_FILE="$MASTER_INDEX_PROBE" git -C "$worktree" update-index \
        --no-skip-worktree -- "$path" || fail "could not clear a copied skip-worktree flag"
      ;;
    esac
  done <"$MASTER_SKIP_PATHS_FILE"
  unlink "$MASTER_SKIP_PATHS_FILE" || fail "could not remove the skip-worktree snapshot"
  MASTER_SKIP_PATHS_FILE=""
  GIT_INDEX_FILE="$MASTER_INDEX_PROBE" git -C "$worktree" update-index -q --really-refresh ||
    fail "could not refresh the $description index snapshot"
  GIT_INDEX_FILE="$MASTER_INDEX_PROBE" git -C "$worktree" diff-files \
    --quiet --ignore-submodules=none -- ||
    fail "$description has a tracked change hidden by index flags; clean it before cleanup: $worktree"
  unlink "$MASTER_INDEX_PROBE" || fail "could not remove the $description index probe"
  MASTER_INDEX_PROBE=""
}

reserve_master_owner_handoff() {
  local head_path head_dir index_path index_dir raw
  head_path=$(git -C "$ORIGINAL_MASTER_OWNER" rev-parse --git-path HEAD) ||
    fail "could not locate the master owner's HEAD"
  case "$head_path" in
  /*) ;;
  *) head_path="$ORIGINAL_MASTER_OWNER/$head_path" ;;
  esac
  head_dir=$(canonical_dir "$(dirname "$head_path")") || exit $?
  head_path="$head_dir/$(basename "$head_path")"
  [ ! -L "$head_path" ] || fail "master owner's HEAD is symbolic on disk"
  MASTER_HEAD_LOCK="$head_path.lock"
  (set -o noclobber; printf '%s\n' "$$" >"$MASTER_HEAD_LOCK") 2>/dev/null || return 1
  MASTER_HEAD_LOCK_OWNED=1
  raw=$(sed -n '1p' "$head_path") || return 1
  [ "$raw" = "ref: refs/heads/master" ] || return 1

  index_path=$(git -C "$ORIGINAL_MASTER_OWNER" rev-parse --git-path index) || return 1
  case "$index_path" in
  /*) ;;
  *) index_path="$ORIGINAL_MASTER_OWNER/$index_path" ;;
  esac
  index_dir=$(canonical_dir "$(dirname "$index_path")") || exit $?
  MASTER_OWNER_INDEX_PATH="$index_dir/$(basename "$index_path")"
  [ ! -L "$MASTER_OWNER_INDEX_PATH" ] || return 1
  [ -f "$MASTER_OWNER_INDEX_PATH" ] || return 1
  MASTER_OWNER_INDEX_LOCK="$MASTER_OWNER_INDEX_PATH.lock"
  (set -o noclobber; : >"$MASTER_OWNER_INDEX_LOCK") 2>/dev/null || return 1
  MASTER_OWNER_INDEX_LOCK_OWNED=1
  cp -p "$MASTER_OWNER_INDEX_PATH" "$MASTER_OWNER_INDEX_LOCK" || return 1
  unlink "$MASTER_HEAD_LOCK" || return 1
  MASTER_HEAD_LOCK_OWNED=0
}

prepare_master_owner_refresh() {
  MASTER_REFRESH_GIT_DIR=$(mktemp -d "$TEMP_ROOT/ship-pr-master-refresh.XXXXXX") || return 1
  printf '%s\n' "$LOCAL_MASTER" >"$MASTER_REFRESH_GIT_DIR/HEAD" || return 1
}

refresh_master_owner_to() {
  local target=$1
  GIT_DIR="$MASTER_REFRESH_GIT_DIR" GIT_COMMON_DIR="$MAIN_COMMON" \
    GIT_WORK_TREE="$ORIGINAL_MASTER_OWNER" GIT_INDEX_FILE="$MASTER_OWNER_INDEX_LOCK" \
    git -C "$ORIGINAL_MASTER_OWNER" checkout --detach --no-overwrite-ignore "$target" >/dev/null
}

discard_master_refresh_admin() {
  [ ! -f "$MASTER_REFRESH_GIT_DIR/logs/HEAD" ] ||
    unlink "$MASTER_REFRESH_GIT_DIR/logs/HEAD" >/dev/null 2>&1 || true
  [ ! -d "$MASTER_REFRESH_GIT_DIR/logs" ] ||
    rmdir "$MASTER_REFRESH_GIT_DIR/logs" >/dev/null 2>&1 || true
  [ ! -f "$MASTER_REFRESH_GIT_DIR/HEAD" ] ||
    unlink "$MASTER_REFRESH_GIT_DIR/HEAD" >/dev/null 2>&1 || true
  if rmdir "$MASTER_REFRESH_GIT_DIR" >/dev/null 2>&1; then
    MASTER_REFRESH_GIT_DIR=""
  else
    echo "post-merge-cleanup.sh: retained temporary master refresh metadata at $MASTER_REFRESH_GIT_DIR" >&2
  fi
}

install_master_owner_refresh() {
  atomic_rename "$MASTER_OWNER_INDEX_LOCK" "$MASTER_OWNER_INDEX_PATH" ||
    fail "could not install the refreshed master-owner index"
  MASTER_OWNER_INDEX_LOCK_OWNED=0
  unlink "$MASTER_HEAD_LOCK" || fail "could not release the master-owner HEAD lock"
  MASTER_HEAD_LOCK_OWNED=0
  discard_master_refresh_admin
}

relock_master_owner_head() {
  local raw
  (set -o noclobber; printf '%s\n' "$$" >"$MASTER_HEAD_LOCK") 2>/dev/null || return 1
  MASTER_HEAD_LOCK_OWNED=1
  raw=$(sed -n '1p' "${MASTER_HEAD_LOCK%.lock}") || return 1
  [ "$raw" = "ref: refs/heads/master" ]
}

lock_session_head_for_archive() {
  local raw
  (set -o noclobber; printf '%s\n' "$$" >"$SESSION_HEAD_LOCK") 2>/dev/null || return 1
  SESSION_HEAD_LOCK_OWNED=1
  raw=$(sed -n '1p' "$SESSION_HEAD_PATH") || return 1
  if [ -n "$SESSION_REF" ]; then
    [ "$raw" = "ref: refs/heads/$BRANCH" ] || return 1
    printf '%s\n' "$SESSION_HEAD" >"$SESSION_HEAD_LOCK" || return 1
    atomic_rename "$SESSION_HEAD_LOCK" "$SESSION_HEAD_PATH" || return 1
    SESSION_HEAD_LOCK_OWNED=0
    (set -o noclobber; printf '%s\n' "$$" >"$SESSION_HEAD_LOCK") 2>/dev/null || return 1
    SESSION_HEAD_LOCK_OWNED=1
    raw=$(sed -n '1p' "$SESSION_HEAD_PATH") || return 1
  fi
  [ "$raw" = "$SESSION_HEAD" ]
}

retain_session_object() {
  local kind="$1" oid="$2" recovery_ref recovery_oid
  git -C "$MAIN" cat-file -e "$oid^{object}" 2>/dev/null ||
    fail "archived session metadata contains an unreadable object: $kind"
  recovery_ref="refs/ship-pr/session-recovery/$BRANCH/$kind-$oid"
  if git -C "$MAIN" symbolic-ref -q "$recovery_ref" >/dev/null 2>&1; then
    fail "session metadata recovery ref is symbolic rather than direct: $recovery_ref"
  fi
  if git -C "$MAIN" show-ref --verify --quiet "$recovery_ref"; then
    recovery_oid=$(git -C "$MAIN" rev-parse "$recovery_ref") || fail "cannot read $recovery_ref"
    [ "$recovery_oid" = "$oid" ] ||
      fail "session metadata recovery points at an unexpected object: $recovery_ref"
  else
    git -C "$MAIN" update-ref --no-deref "$recovery_ref" "$oid" "" ||
      fail "could not retain archived session metadata object: $recovery_ref"
  fi
}

retain_topic_recovery_object() {
  local kind="$1" oid="$2" recovery_ref recovery_oid
  git -C "$MAIN" cat-file -e "$oid^{object}" 2>/dev/null ||
    fail "topic recovery metadata contains an unreadable object: $kind"
  recovery_ref="refs/ship-pr/recovery/$BRANCH/$kind-$oid"
  if git -C "$MAIN" symbolic-ref -q "$recovery_ref" >/dev/null 2>&1; then
    fail "topic metadata recovery ref is symbolic rather than direct: $recovery_ref"
  fi
  if git -C "$MAIN" show-ref --verify --quiet "$recovery_ref"; then
    recovery_oid=$(git -C "$MAIN" rev-parse "$recovery_ref") || fail "cannot read $recovery_ref"
    [ "$recovery_oid" = "$oid" ] ||
      fail "topic metadata recovery points at an unexpected object: $recovery_ref"
  else
    git -C "$MAIN" update-ref --no-deref "$recovery_ref" "$oid" "" ||
      fail "could not retain topic metadata object: $recovery_ref"
  fi
}

retain_topic_reflog_sides() {
  local ref="$1" kind="$2" path path_dir line old_oid new_oid rest oid
  path=$(git -C "$MAIN" rev-parse --git-path "logs/$ref") ||
    fail "could not locate $ref reflog"
  case "$path" in
  /*) ;;
  *) path="$MAIN/$path" ;;
  esac
  path_dir=$(dirname "$path")
  if [ ! -d "$path_dir" ]; then
    { [ ! -e "$path" ] && [ ! -L "$path" ]; } || fail "$ref reflog has an invalid parent"
    return 0
  fi
  path_dir=$(canonical_dir "$path_dir") || exit $?
  path="$path_dir/$(basename "$path")"
  [ ! -L "$path" ] || fail "$ref reflog is symbolic"
  [ -f "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    read -r old_oid new_oid rest <<<"$line"
    for oid in "$old_oid" "$new_oid"; do
      case "$oid" in
      *[!0]*) retain_topic_recovery_object "$kind" "$oid" ;;
      esac
    done
  done <"$path"
}

retain_session_reflog_sides() {
  local ref="$1" kind="${2:-private-reflog}" path="${3:-}" path_dir line old_oid new_oid rest oid
  if [ -z "$path" ]; then
    path=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path "logs/$ref") ||
      fail "could not locate session-private reflog: $ref"
    case "$path" in
    /*) ;;
    *) path="$SESSION_ARCHIVED_WORKTREE/$path" ;;
    esac
  fi
  path_dir=$(dirname "$path")
  if [ ! -d "$path_dir" ]; then
    { [ ! -e "$path" ] && [ ! -L "$path" ]; } || fail "session-private reflog has an invalid parent: $ref"
    return 0
  fi
  path_dir=$(canonical_dir "$path_dir") || exit $?
  path="$path_dir/$(basename "$path")"
  [ ! -L "$path" ] || fail "session-private reflog is symbolic: $ref"
  [ -f "$path" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    read -r old_oid new_oid rest <<<"$line"
    for oid in "$old_oid" "$new_oid"; do
      case "$oid" in
      *[!0]*) retain_session_object "$kind" "$oid" ;;
      esac
    done
  done <"$path"
}

retain_private_session_refs() {
  local private_refs line ref oid response namespace probe blocker blocker_parent blocker_temp
  private_refs=$(git -C "$SESSION_ARCHIVED_WORKTREE" for-each-ref \
    --format='%(refname) %(objectname)' refs/worktree refs/bisect refs/rewritten) ||
    fail "could not recheck session-private refs before unregistering"
  REF_TRANSACTION_DIR=$(mktemp -d "$TEMP_ROOT/ship-pr-ref-transaction.XXXXXX") ||
    fail "could not allocate the session-private namespace transaction"
  REF_TRANSACTION_IN="$REF_TRANSACTION_DIR/input"
  REF_TRANSACTION_OUT="$REF_TRANSACTION_DIR/output"
  mkfifo "$REF_TRANSACTION_IN" "$REF_TRANSACTION_OUT" ||
    fail "could not create the session-private namespace transaction channels"
  git -C "$SESSION_ARCHIVED_WORKTREE" update-ref --stdin \
    <"$REF_TRANSACTION_IN" >"$REF_TRANSACTION_OUT" &
  REF_TRANSACTION_PID=$!
  exec 7>"$REF_TRANSACTION_IN" || fail "could not open the private namespace transaction input"
  exec 8<"$REF_TRANSACTION_OUT" || fail "could not open the private namespace transaction output"
  printf 'start\noption no-deref\n' >&7 || fail "could not start the private namespace transaction"
  while IFS= read -r line; do
    ref=${line%% *}
    oid=${line#* }
    [ -n "$ref" ] || continue
    case "$ref" in
    refs/worktree | refs/bisect | refs/rewritten) continue ;;
    esac
    [ -n "$oid" ] || fail "session-private ref has no object: $ref"
    printf 'delete %s %s\n' "$ref" "$oid" >&7 ||
      fail "could not queue session-private ref retention: $ref"
  done <<<"$private_refs"
  printf 'prepare\n' >&7 || fail "could not prepare session-private namespace retention"
  IFS= read -r response <&8 || fail "session-private namespace transaction stopped before start"
  [ "$response" = "start: ok" ] || fail "session-private namespace transaction did not start"
  IFS= read -r response <&8 || fail "session-private namespace transaction stopped before preparation"
  [ "$response" = "prepare: ok" ] || fail "session-private refs changed before retention"
  while IFS= read -r line; do
    ref=${line%% *}
    oid=${line#* }
    [ -n "$ref" ] || continue
    case "$ref" in
    refs/worktree | refs/bisect | refs/rewritten) continue ;;
    esac
    retain_session_object private-ref "$oid"
    retain_session_reflog_sides "$ref"
  done <<<"$private_refs"
  printf 'commit\n' >&7 || fail "could not commit session-private namespace retention"
  IFS= read -r response <&8 || fail "session-private namespace transaction stopped before commit"
  [ "$response" = "commit: ok" ] || fail "session-private namespace transaction did not commit"
  exec 7>&- 8<&-
  wait "$REF_TRANSACTION_PID" || fail "session-private namespace transaction failed"
  REF_TRANSACTION_PID=""
  unlink "$REF_TRANSACTION_IN" || fail "could not remove the private namespace transaction input"
  unlink "$REF_TRANSACTION_OUT" || fail "could not remove the private namespace transaction output"
  REF_TRANSACTION_IN=""
  REF_TRANSACTION_OUT=""
  rmdir "$REF_TRANSACTION_DIR" || fail "could not remove the private namespace transaction directory"
  REF_TRANSACTION_DIR=""

  # These namespace roots are special: the root ref itself is shared, while every child is private
  # to the worktree. Reserve the actual per-worktree filesystem directory with a regular blocker
  # after atomically emptying it. If a writer recreates a child in the handoff, rmdir refuses and
  # preserves that new state; once installed, the blocker makes every Git child creation fail.
  for namespace in refs/worktree refs/bisect refs/rewritten; do
    probe=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path "$namespace/ship-pr-probe") ||
      fail "could not locate private namespace: $namespace"
    case "$probe" in
    /*) ;;
    *) probe="$SESSION_ARCHIVED_WORKTREE/$probe" ;;
    esac
    blocker=$(dirname "$probe")
    blocker_parent=$(dirname "$blocker")
    if [ ! -d "$blocker_parent" ]; then
      { [ ! -e "$blocker_parent" ] && [ ! -L "$blocker_parent" ]; } ||
        fail "private namespace parent is invalid: $namespace"
      mkdir "$blocker_parent" || fail "could not create private namespace parent: $namespace"
    fi
    blocker_parent=$(canonical_dir "$blocker_parent") || exit $?
    blocker="$blocker_parent/$(basename "$blocker")"
    blocker_temp=$(mktemp "$blocker_parent/.ship-pr-namespace-blocker.XXXXXX") ||
      fail "could not allocate private namespace blocker: $namespace"
    printf '%s\n' "$LOCAL_BRANCH_OID" >"$blocker_temp" ||
      fail "could not write private namespace blocker: $namespace"
    if [ -d "$blocker" ]; then
      rmdir "$blocker" || fail "private namespace gained a ref during retention: $namespace"
    else
      { [ ! -e "$blocker" ] && [ ! -L "$blocker" ]; } ||
        fail "private namespace gained an unexpected entry during retention: $namespace"
    fi
    atomic_rename "$blocker_temp" "$blocker" ||
      fail "could not install private namespace blocker: $namespace"
    PRIVATE_NAMESPACE_BLOCKERS+=("$blocker")
  done
}

release_private_namespace_locks() {
  PRIVATE_NAMESPACE_BLOCKERS=()
}

discard_ref_transaction() {
  exec 7>&- 8<&-
  if [ -n "${REF_TRANSACTION_PID:-}" ]; then
    wait "$REF_TRANSACTION_PID" >/dev/null 2>&1 || true
  fi
  REF_TRANSACTION_PID=""
  [ -z "${REF_TRANSACTION_IN:-}" ] || unlink "$REF_TRANSACTION_IN" >/dev/null 2>&1 || true
  [ -z "${REF_TRANSACTION_OUT:-}" ] || unlink "$REF_TRANSACTION_OUT" >/dev/null 2>&1 || true
  REF_TRANSACTION_IN=""
  REF_TRANSACTION_OUT=""
  [ -z "${REF_TRANSACTION_DIR:-}" ] || rmdir "$REF_TRANSACTION_DIR" >/dev/null 2>&1 || true
  REF_TRANSACTION_DIR=""
}

delete_ref_with_locked_reflog() {
  local ref="$1" expected_oid="$2" kind="$3" response=""
  REF_TRANSACTION_DIR=$(mktemp -d "$TEMP_ROOT/ship-pr-ref-transaction.XXXXXX") ||
    fail "could not allocate the ref deletion transaction: $ref"
  REF_TRANSACTION_IN="$REF_TRANSACTION_DIR/input"
  REF_TRANSACTION_OUT="$REF_TRANSACTION_DIR/output"
  mkfifo "$REF_TRANSACTION_IN" "$REF_TRANSACTION_OUT" ||
    fail "could not create the ref deletion transaction channels: $ref"
  git -C "$MAIN" update-ref --stdin <"$REF_TRANSACTION_IN" >"$REF_TRANSACTION_OUT" &
  REF_TRANSACTION_PID=$!
  exec 7>"$REF_TRANSACTION_IN" || fail "could not open the ref transaction input: $ref"
  exec 8<"$REF_TRANSACTION_OUT" || fail "could not open the ref transaction output: $ref"

  printf 'start\noption no-deref\ndelete %s %s\nprepare\n' "$ref" "$expected_oid" >&7 ||
    fail "could not prepare the ref deletion: $ref"
  if ! IFS= read -r response <&8 || [ "$response" != "start: ok" ]; then
    echo "post-merge-cleanup.sh: ref deletion transaction did not start: $ref: $response" >&2
    discard_ref_transaction
    return 1
  fi
  if ! IFS= read -r response <&8 || [ "$response" != "prepare: ok" ]; then
    echo "post-merge-cleanup.sh: ref deletion transaction was not prepared: $ref: $response" >&2
    discard_ref_transaction
    return 1
  fi

  # prepare holds the ref and reflog locks. Retain every reflog endpoint while neither can
  # change, then commit the already-validated deletion without an ABA window between those steps.
  retain_topic_reflog_sides "$ref" "$kind"
  printf 'commit\n' >&7 || fail "could not commit the ref deletion: $ref"
  IFS= read -r response <&8 || fail "ref deletion transaction stopped before commit: $ref"
  [ "$response" = "commit: ok" ] || fail "ref deletion transaction did not commit: $ref: $response"
  exec 7>&- 8<&-
  wait "$REF_TRANSACTION_PID" || fail "ref deletion transaction failed: $ref"
  REF_TRANSACTION_PID=""
  unlink "$REF_TRANSACTION_IN" || fail "could not remove the ref transaction input: $ref"
  unlink "$REF_TRANSACTION_OUT" || fail "could not remove the ref transaction output: $ref"
  REF_TRANSACTION_IN=""
  REF_TRANSACTION_OUT=""
  rmdir "$REF_TRANSACTION_DIR" || fail "could not remove the ref transaction directory: $ref"
  REF_TRANSACTION_DIR=""
}

lock_and_retain_session_metadata() {
  local name path path_dir lock line metadata oid config_snapshot message_snapshot squash_snapshot index_snapshot index_tree
  local edit_snapshot shared_index shared_snapshot shared_temp sparse_snapshot worktree_git_dir
  local reuc_snapshot mode stage old_oid new_oid rest
  for name in ORIG_HEAD MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD REBASE_HEAD \
    BISECT_HEAD AUTO_MERGE FETCH_HEAD; do
    path=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path "$name") ||
      fail "could not locate archived session pseudoref: $name"
    case "$path" in
    /*) ;;
    *) path="$SESSION_ARCHIVED_WORKTREE/$path" ;;
    esac
    path_dir=$(canonical_dir "$(dirname "$path")") || exit $?
    path="$path_dir/$(basename "$path")"
    lock="$path.lock"
    (set -o noclobber; printf '%s\n' "$$" >"$lock") 2>/dev/null ||
      fail "archived session pseudoref is busy: $name"
    SESSION_PSEUDOREF_LOCKS+=("$lock")
    [ ! -L "$path" ] || fail "archived session pseudoref is symbolic: $name"
    if [ -f "$path" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        oid=${line%%[[:space:]]*}
        [ -n "$oid" ] || continue
        retain_session_object "pseudoref-$name" "$oid"
      done <"$path"
    fi
    worktree_git_dir=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --absolute-git-dir) ||
      fail "could not locate archived session Git metadata"
    worktree_git_dir=$(canonical_dir "$worktree_git_dir") || exit $?
    retain_session_reflog_sides "$name" "pseudoref-reflog-$name" \
      "$worktree_git_dir/logs/$name"
  done

  path=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path COMMIT_EDITMSG) ||
    fail "could not locate archived commit message"
  case "$path" in
  /*) ;;
  *) path="$SESSION_ARCHIVED_WORKTREE/$path" ;;
  esac
  path_dir=$(canonical_dir "$(dirname "$path")") || exit $?
  path="$path_dir/$(basename "$path")"
  lock="$path.lock"
  (set -o noclobber; printf '%s\n' "$$" >"$lock") 2>/dev/null ||
    fail "archived commit message is busy"
  SESSION_PSEUDOREF_LOCKS+=("$lock")
  [ ! -L "$path" ] || fail "archived commit message is symbolic"
  if [ ! -f "$path" ]; then
    : >"$path" || fail "could not reserve the archived commit-message path"
  fi
  message_snapshot=$(mktemp "$SESSION_ARCHIVE/COMMIT_EDITMSG.XXXXXX") ||
    fail "could not allocate a commit-message snapshot"
  unlink "$message_snapshot" || fail "could not prepare the commit-message snapshot"
  ln "$path" "$message_snapshot" || fail "could not link the archived commit message"

  path=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path SQUASH_MSG) ||
    fail "could not locate archived squash message"
  case "$path" in
  /*) ;;
  *) path="$SESSION_ARCHIVED_WORKTREE/$path" ;;
  esac
  path_dir=$(canonical_dir "$(dirname "$path")") || exit $?
  path="$path_dir/$(basename "$path")"
  lock="$path.lock"
  (set -o noclobber; printf '%s\n' "$$" >"$lock") 2>/dev/null ||
    fail "archived squash message is busy"
  SESSION_PSEUDOREF_LOCKS+=("$lock")
  [ ! -L "$path" ] || fail "archived squash message is symbolic"
  if [ -f "$path" ]; then
    squash_snapshot=$(mktemp "$SESSION_ARCHIVE/SQUASH_MSG.XXXXXX") ||
      fail "could not allocate a squash-message snapshot"
    unlink "$squash_snapshot" || fail "could not prepare the squash-message snapshot"
    ln "$path" "$squash_snapshot" || fail "could not link the archived squash message"
  fi

  for name in TAG_EDITMSG NOTES_EDITMSG; do
    path=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path "$name") ||
      fail "could not locate archived edit message: $name"
    case "$path" in
    /*) ;;
    *) path="$SESSION_ARCHIVED_WORKTREE/$path" ;;
    esac
    path_dir=$(canonical_dir "$(dirname "$path")") || exit $?
    path="$path_dir/$(basename "$path")"
    lock="$path.lock"
    (set -o noclobber; printf '%s\n' "$$" >"$lock") 2>/dev/null ||
      fail "archived edit message is busy: $name"
    SESSION_PSEUDOREF_LOCKS+=("$lock")
    [ ! -L "$path" ] || fail "archived edit message is symbolic: $name"
    if [ -f "$path" ]; then
      edit_snapshot=$(mktemp "$SESSION_ARCHIVE/$name.XXXXXX") ||
        fail "could not allocate an edit-message snapshot: $name"
      unlink "$edit_snapshot" || fail "could not prepare the edit-message snapshot: $name"
      ln "$path" "$edit_snapshot" || fail "could not link the archived edit message: $name"
    fi
  done


  path=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path config.worktree) ||
    fail "could not locate archived per-worktree configuration"
  case "$path" in
  /*) ;;
  *) path="$SESSION_ARCHIVED_WORKTREE/$path" ;;
  esac
  path_dir=$(dirname "$path")
  if [ -d "$path_dir" ]; then
    path_dir=$(canonical_dir "$path_dir") || exit $?
    path="$path_dir/$(basename "$path")"
    lock="$path.lock"
    (set -o noclobber; printf '%s\n' "$$" >"$lock") 2>/dev/null ||
      fail "archived per-worktree configuration is busy"
    SESSION_PSEUDOREF_LOCKS+=("$lock")
    [ ! -L "$path" ] || fail "archived per-worktree configuration is symbolic"
    if [ -f "$path" ]; then
      config_snapshot=$(mktemp "$SESSION_ARCHIVE/config.worktree.XXXXXX") ||
        fail "could not allocate a per-worktree configuration snapshot"
      cp "$path" "$config_snapshot" || fail "could not archive per-worktree configuration"
    fi
  else
    { [ ! -e "$path" ] && [ ! -L "$path" ]; } ||
      fail "archived per-worktree configuration has an invalid parent"
  fi

  path=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path info/sparse-checkout) ||
    fail "could not locate archived sparse-checkout metadata"
  case "$path" in
  /*) ;;
  *) path="$SESSION_ARCHIVED_WORKTREE/$path" ;;
  esac
  path_dir=$(dirname "$path")
  if [ -d "$path_dir" ]; then
    path_dir=$(canonical_dir "$path_dir") || exit $?
    path="$path_dir/$(basename "$path")"
    lock="$path.lock"
    (set -o noclobber; printf '%s\n' "$$" >"$lock") 2>/dev/null ||
      fail "archived sparse-checkout metadata is busy"
    SESSION_PSEUDOREF_LOCKS+=("$lock")
    [ ! -L "$path" ] || fail "archived sparse-checkout metadata is symbolic"
    if [ -f "$path" ]; then
      sparse_snapshot=$(mktemp "$SESSION_ARCHIVE/sparse-checkout.XXXXXX") ||
        fail "could not allocate a sparse-checkout snapshot"
      cp "$path" "$sparse_snapshot" || fail "could not archive sparse-checkout metadata"
    fi
  else
    { [ ! -e "$path" ] && [ ! -L "$path" ]; } ||
      fail "archived sparse-checkout metadata has an invalid parent"
  fi

  path=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path index) ||
    fail "could not locate archived session index"
  case "$path" in
  /*) ;;
  *) path="$SESSION_ARCHIVED_WORKTREE/$path" ;;
  esac
  path_dir=$(canonical_dir "$(dirname "$path")") || exit $?
  lock="$path_dir/$(basename "$path").lock"
  (set -o noclobber; printf '%s\n' "$$" >"$lock") 2>/dev/null ||
    fail "archived session index is busy"
  SESSION_PSEUDOREF_LOCKS+=("$lock")
  index_snapshot=$(mktemp "$SESSION_ARCHIVE/index.snapshot.XXXXXX") ||
    fail "could not allocate an archived session index snapshot"
  cp "$path" "$index_snapshot" || fail "could not copy the locked archived session index"
  shared_index=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --shared-index-path) ||
    fail "could not locate the archived session shared index"
  if [ -n "$shared_index" ]; then
    case "$shared_index" in
    /*) ;;
    *) shared_index="$SESSION_ARCHIVED_WORKTREE/$shared_index" ;;
    esac
    path_dir=$(canonical_dir "$(dirname "$shared_index")") || exit $?
    shared_index="$path_dir/$(basename "$shared_index")"
    [ ! -L "$shared_index" ] || fail "archived session shared index is symbolic"
    [ -f "$shared_index" ] || fail "archived session shared index is missing"
    shared_temp=$(mktemp "$SESSION_ARCHIVE/sharedindex.snapshot.XXXXXX") ||
      fail "could not allocate an archived shared-index snapshot"
    cp "$shared_index" "$shared_temp" || fail "could not copy the archived session shared index"
    shared_snapshot="$SESSION_ARCHIVE/$(basename "$shared_index")"
    ln "$shared_temp" "$shared_snapshot" ||
      fail "could not reserve the archived session shared-index name"
    unlink "$shared_temp" || fail "could not finalize the archived session shared-index snapshot"
  fi
  index_tree=$(GIT_INDEX_FILE="$index_snapshot" git -C "$SESSION_ARCHIVED_WORKTREE" write-tree) ||
    fail "could not retain the archived session index"
  retain_session_object index-tree "$index_tree"
  reuc_snapshot=$(mktemp "$SESSION_ARCHIVE/index.resolve-undo.XXXXXX") ||
    fail "could not allocate a resolve-undo snapshot"
  GIT_INDEX_FILE="$index_snapshot" git -C "$SESSION_ARCHIVED_WORKTREE" \
    ls-files --resolve-undo -z >"$reuc_snapshot" ||
    fail "could not inspect archived session resolve-undo data"
  while IFS= read -r -d '' line; do
    metadata=${line%%$'\t'*}
    read -r mode oid stage <<<"$metadata"
    [ -n "$oid" ] || continue
    retain_session_object index-reuc "$oid"
  done <"$reuc_snapshot"

  path=$(git -C "$SESSION_ARCHIVED_WORKTREE" rev-parse --git-path logs/HEAD) ||
    fail "could not locate the archived session HEAD reflog"
  case "$path" in
  /*) ;;
  *) path="$SESSION_ARCHIVED_WORKTREE/$path" ;;
  esac
  path_dir=$(dirname "$path")
  if [ -d "$path_dir" ]; then
    path_dir=$(canonical_dir "$path_dir") || exit $?
    path="$path_dir/$(basename "$path")"
    [ ! -L "$path" ] || fail "archived session HEAD reflog is symbolic"
    if [ -f "$path" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        read -r old_oid new_oid rest <<<"$line"
        for oid in "$old_oid" "$new_oid"; do
          case "$oid" in
          *[!0]*) retain_session_object reflog-HEAD "$oid" ;;
          esac
        done
      done <"$path"
    fi
  else
    { [ ! -e "$path" ] && [ ! -L "$path" ]; } ||
      fail "archived session HEAD reflog has an invalid parent"
  fi
}

scan_branch_owner() {
  # NUL-delimited fields: a valid worktree path (or lock reason) can contain a newline, and the
  # line-based porcelain would truncate it — misreading which worktree owns the branch. Command
  # substitution strips NUL bytes, so the listing goes through a snapshot file instead.
  local target_ref="$1" field current_worktree=""
  BRANCH_OWNER=""
  BRANCH_OWNER_COUNT=0
  SESSION_LOCKED=0
  WORKTREE_LIST_FILE=$(mktemp "$TEMP_ROOT/ship-pr-worktree-list.XXXXXX") ||
    fail "could not allocate the worktree list snapshot"
  git -C "$MAIN" worktree list --porcelain -z >"$WORKTREE_LIST_FILE" ||
    fail "could not inspect registered worktrees"
  while IFS= read -r -d '' field; do
    case "$field" in
    worktree\ *) current_worktree=${field#worktree } ;;
    locked*) [ "$current_worktree" != "$SESSION" ] || SESSION_LOCKED=1 ;;
    esac
    if [ "$field" = "branch $target_ref" ]; then
      BRANCH_OWNER="$current_worktree"
      BRANCH_OWNER_COUNT=$((BRANCH_OWNER_COUNT + 1))
    fi
  done <"$WORKTREE_LIST_FILE"
  unlink "$WORKTREE_LIST_FILE" || fail "could not remove the worktree list snapshot"
  WORKTREE_LIST_FILE=""
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
  local lock
  if [ -n "${REF_TRANSACTION_PID:-}" ]; then
    kill "$REF_TRANSACTION_PID" >/dev/null 2>&1 || true
    exec 7>&- 8<&-
    wait "$REF_TRANSACTION_PID" >/dev/null 2>&1 || true
    REF_TRANSACTION_PID=""
  fi
  [ -z "${REF_TRANSACTION_IN:-}" ] || unlink "$REF_TRANSACTION_IN" >/dev/null 2>&1 || true
  [ -z "${REF_TRANSACTION_OUT:-}" ] || unlink "$REF_TRANSACTION_OUT" >/dev/null 2>&1 || true
  [ -z "${REF_TRANSACTION_DIR:-}" ] || rmdir "$REF_TRANSACTION_DIR" >/dev/null 2>&1 || true
  if [ "${#PRIVATE_NAMESPACE_BLOCKERS[@]}" -gt 0 ]; then
    for lock in "${PRIVATE_NAMESPACE_BLOCKERS[@]}"; do
      [ ! -f "$lock" ] || unlink "$lock" >/dev/null 2>&1 || true
    done
  fi
  if [ "${CONFIG_LOCK_OWNED:-0}" -eq 1 ] && [ -n "${CONFIG_LOCK:-}" ] && [ -f "$CONFIG_LOCK" ]; then
    unlink "$CONFIG_LOCK" >/dev/null 2>&1 || true
  fi
  if [ -n "${CHANGED_PATHS_FILE:-}" ] && [ -f "$CHANGED_PATHS_FILE" ]; then
    unlink "$CHANGED_PATHS_FILE" >/dev/null 2>&1 || true
  fi
  if [ -n "${WORKTREE_LIST_FILE:-}" ] && [ -f "$WORKTREE_LIST_FILE" ]; then
    unlink "$WORKTREE_LIST_FILE" >/dev/null 2>&1 || true
  fi
  if [ -n "${MASTER_INDEX_PROBE:-}" ]; then
    unlink "$MASTER_INDEX_PROBE.lock" >/dev/null 2>&1 || true
    unlink "$MASTER_INDEX_PROBE" >/dev/null 2>&1 || true
  fi
  if [ -n "${MASTER_SKIP_PATHS_FILE:-}" ]; then
    unlink "$MASTER_SKIP_PATHS_FILE" >/dev/null 2>&1 || true
  fi
  if [ "${#SESSION_PSEUDOREF_LOCKS[@]}" -gt 0 ]; then
    for lock in "${SESSION_PSEUDOREF_LOCKS[@]}"; do
      [ ! -f "$lock" ] || unlink "$lock" >/dev/null 2>&1 || true
    done
  fi
  if [ "${SESSION_HEAD_LOCK_OWNED:-0}" -eq 1 ] && [ -n "${SESSION_HEAD_LOCK:-}" ] &&
    [ -f "$SESSION_HEAD_LOCK" ]; then
    unlink "$SESSION_HEAD_LOCK" >/dev/null 2>&1 || true
  fi
  if [ "${CAPABILITY_REF_OWNED:-0}" -eq 1 ] && [ -n "${CAPABILITY_REF:-}" ]; then
    git -C "$MAIN" symbolic-ref --delete "$CAPABILITY_REF" >/dev/null 2>&1 || true
  fi
  if [ "${SESSION_NAMESPACE_RESERVATION_OWNED:-0}" -eq 1 ] &&
    [ -n "${SESSION_NAMESPACE_RESERVATION:-}" ]; then
    git -C "$MAIN" update-ref --no-deref -d "$SESSION_NAMESPACE_RESERVATION" \
      "$LOCAL_BRANCH_OID" >/dev/null 2>&1 || true
  fi
  if [ -n "${TOPIC_RESERVATION:-}" ] && [ -d "$TOPIC_RESERVATION" ]; then
    git -C "$MAIN" worktree remove --force "$TOPIC_RESERVATION" >/dev/null 2>&1 || true
  fi
  if [ "${SESSION_WORKTREE_LOCK_OWNED:-0}" -eq 1 ] && [ -n "${SESSION:-}" ]; then
    git -C "$MAIN" worktree unlock "$SESSION" >/dev/null 2>&1 || true
  fi
  if [ "${MASTER_OWNER_INDEX_LOCK_OWNED:-0}" -eq 1 ] &&
    [ -n "${MASTER_OWNER_INDEX_LOCK:-}" ] && [ -f "$MASTER_OWNER_INDEX_LOCK" ]; then
    unlink "$MASTER_OWNER_INDEX_LOCK" >/dev/null 2>&1 || true
  fi
  if [ "${MASTER_HEAD_LOCK_OWNED:-0}" -eq 1 ] && [ -n "${MASTER_HEAD_LOCK:-}" ] &&
    [ -f "$MASTER_HEAD_LOCK" ]; then
    unlink "$MASTER_HEAD_LOCK" >/dev/null 2>&1 || true
  fi
  if [ -n "${MASTER_REFRESH_GIT_DIR:-}" ]; then
    unlink "$MASTER_REFRESH_GIT_DIR/HEAD.lock" >/dev/null 2>&1 || true
    unlink "$MASTER_REFRESH_GIT_DIR/logs/HEAD" >/dev/null 2>&1 || true
    rmdir "$MASTER_REFRESH_GIT_DIR/logs" >/dev/null 2>&1 || true
    unlink "$MASTER_REFRESH_GIT_DIR/HEAD" >/dev/null 2>&1 || true
    rmdir "$MASTER_REFRESH_GIT_DIR" >/dev/null 2>&1 || true
  fi
  if [ -n "${MASTER_RESERVATION:-}" ] && [ -d "$MASTER_RESERVATION" ]; then
    git -C "$MAIN" worktree remove --force "$MASTER_RESERVATION" >/dev/null 2>&1 || true
  fi
  [ -z "${SESSION_ARCHIVE:-}" ] || rmdir "$SESSION_ARCHIVE" >/dev/null 2>&1 || true
  [ -z "${LATE_SESSION_ARCHIVE:-}" ] || rmdir "$LATE_SESSION_ARCHIVE" >/dev/null 2>&1 || true
}

MASTER_RESERVATION=""
MASTER_HEAD_LOCK=""
MASTER_HEAD_LOCK_OWNED=0
MASTER_OWNER_INDEX_PATH=""
MASTER_OWNER_INDEX_LOCK=""
MASTER_OWNER_INDEX_LOCK_OWNED=0
MASTER_REFRESH_GIT_DIR=""
SESSION_HEAD_LOCK=""
SESSION_HEAD_LOCK_OWNED=0
CAPABILITY_REF=""
CAPABILITY_REF_OWNED=0
SESSION_NAMESPACE_RESERVATION=""
SESSION_NAMESPACE_RESERVATION_OWNED=0
SESSION_PSEUDOREF_LOCKS=()
SESSION_WORKTREE_LOCK_OWNED=0
TOPIC_RESERVATION=""
REF_TRANSACTION_DIR=""
REF_TRANSACTION_IN=""
REF_TRANSACTION_OUT=""
REF_TRANSACTION_PID=""
PRIVATE_NAMESPACE_BLOCKERS=()
CONFIG_LOCK=""
CONFIG_LOCK_OWNED=0
CHANGED_PATHS_FILE=""
WORKTREE_LIST_FILE=""
MASTER_INDEX_PROBE=""
MASTER_SKIP_PATHS_FILE=""
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
case "$TEMP_ROOT" in
"$SESSION" | "$SESSION"/*) fail "temporary root must be outside the session worktree: $TEMP_ROOT" ;;
esac

MAIN_COMMON=$(git_path "$MAIN" "$(git -C "$MAIN" rev-parse --git-common-dir)") || exit $?
MAIN_GIT=$(git_path "$MAIN" "$(git -C "$MAIN" rev-parse --git-dir)") || exit $?
SESSION_COMMON=$(git_path "$SESSION" "$(git -C "$SESSION" rev-parse --git-common-dir)") || exit $?
[ "$MAIN_GIT" = "$MAIN_COMMON" ] || fail "main-checkout is a linked worktree, not the primary checkout: $MAIN"
[ "$MAIN" != "$SESSION" ] || fail "main checkout and session worktree must be different paths"
[ "$SESSION_COMMON" = "$MAIN_COMMON" ] || fail "main checkout and session worktree belong to different repositories"
REF_FORMAT=$(git -C "$MAIN" rev-parse --show-ref-format) || fail "could not determine repository ref storage"
[ "$REF_FORMAT" = files ] || fail "cleanup currently requires files ref storage, found: $REF_FORMAT"
[ ! -L "$MAIN_COMMON/config" ] || fail "repository config is symbolic; replace it before cleanup"
[ -f "$MAIN_COMMON/config" ] || fail "repository config is missing or not a regular file"
{ [ ! -e "$MAIN_COMMON/config.lock" ] && [ ! -L "$MAIN_COMMON/config.lock" ]; } ||
  fail "repository config is locked; retry after the lock clears"
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
  SESSION_HEAD="$LOCAL_BRANCH_OID"
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
refuse_session_module_gitdirs "$SESSION"
refuse_private_worktree_refs "$SESSION"
refuse_active_session_operations
preflight_session_metadata_locks
preflight_sparse_checkout_metadata

SESSION_HEAD_PATH=$(git -C "$SESSION" rev-parse --git-path HEAD) || fail "cannot locate session HEAD"
case "$SESSION_HEAD_PATH" in
/*) ;;
*) SESSION_HEAD_PATH="$SESSION/$SESSION_HEAD_PATH" ;;
esac
SESSION_HEAD_DIR=$(canonical_dir "$(dirname "$SESSION_HEAD_PATH")") || exit $?
SESSION_HEAD_LOCK="$SESSION_HEAD_DIR/$(basename "$SESSION_HEAD_PATH").lock"
{ [ ! -e "$SESSION_HEAD_LOCK" ] && [ ! -L "$SESSION_HEAD_LOCK" ]; } ||
  fail "session HEAD is locked; retry after its Git operation finishes"

# Keep a child ref present until the final session recovery ref exists. With the files ref backend,
# this reserves every prefix directory against a conflicting direct ref; an existing conflict makes
# this expected-absent update fail before master or topic mutation.
SESSION_NAMESPACE_RESERVATION="refs/ship-pr/session-recovery/$BRANCH/reservation-$$"
git -C "$MAIN" update-ref --no-deref "$SESSION_NAMESPACE_RESERVATION" \
  "$LOCAL_BRANCH_OID" "" || fail "session recovery ref namespace is unavailable"
SESSION_NAMESPACE_RESERVATION_OWNED=1

# Allocate both sibling archives before any ref mutation. Keeping the empty directories reserved
# proves the parent is writable and prevents a later name race; teardown moves data beneath them.
SESSION_PARENT=$(dirname "$SESSION")
SESSION_BASENAME=$(basename "$SESSION")
SESSION_ARCHIVE=$(mktemp -d "$SESSION_PARENT/.${SESSION_BASENAME}.ship-pr-recovery.XXXXXX") ||
  fail "could not allocate a session recovery archive beside $SESSION"
LATE_SESSION_ARCHIVE=$(mktemp -d "$SESSION_PARENT/.${SESSION_BASENAME}.ship-pr-late-data.XXXXXX") ||
  fail "could not allocate a late-data recovery archive beside $SESSION"
COMMIT_LINK_PROBE="$SESSION_ARCHIVE/.commit-message-link-probe"
ln "$MAIN_COMMON/config" "$COMMIT_LINK_PROBE" ||
  fail "session recovery archive cannot hard-link repository metadata"
unlink "$COMMIT_LINK_PROBE" || fail "could not remove the commit-message link probe"
git -C "$MAIN" worktree lock --reason "ship-pr cleanup in progress" "$SESSION" ||
  fail "could not lock the session worktree registration against pruning"
SESSION_WORKTREE_LOCK_OWNED=1

# symref-update provides the compare-and-swap used by the master ownership handoff. Probe it before
# master or topic mutation so older Git versions refuse cleanly rather than failing mid-cleanup.
CAPABILITY_REF="refs/ship-pr/capability-probe-$$"
git -C "$MAIN" show-ref --exists "$CAPABILITY_REF" >/dev/null 2>&1
CAPABILITY_REF_STATUS=$?
case "$CAPABILITY_REF_STATUS" in
0) fail "temporary capability ref already exists: $CAPABILITY_REF" ;;
2) ;;
*) fail "could not inspect the temporary capability ref: $CAPABILITY_REF" ;;
esac
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
# Ignored files are deliberately NOT part of this cleanliness gate: on the standard layout the
# primary checkout owns master and always carries build caches and ignored config, so requiring
# "no ignored data anywhere" makes the helper unusable there. Ignored data is only at risk on
# paths the fast-forward actually touches, and those are refused by the changed-path collision
# scan below; the locked refresh itself runs checkout --no-overwrite-ignore, which refuses loudly
# if ignored data appears on a touched path after that scan.
MASTER_OWNER_STATUS=$(git -C "$MASTER_OWNER" status \
  --porcelain --untracked-files=normal) ||
  fail "could not inspect master owner cleanliness"
[ -z "$MASTER_OWNER_STATUS" ] || fail "master owner is dirty; clean it before cleanup: $MASTER_OWNER"
refuse_hidden_index_changes "$MASTER_OWNER" "master owner"
refuse_initialized_submodules "$MASTER_OWNER" "master owner"
refuse_index_resolve_undo "$MASTER_OWNER" "master owner"
refuse_active_session_operations "$MASTER_OWNER" "master owner"
IGNORED_COLLISION=""
CHANGED_PATHS_FILE=$(mktemp "$TEMP_ROOT/ship-pr-master-paths.XXXXXX") ||
  fail "could not allocate the master changed-path snapshot"
git -C "$MAIN" diff --name-only -z "$LOCAL_MASTER" "$REMOTE_MASTER" >"$CHANGED_PATHS_FILE" ||
  fail "could not enumerate paths changed by the master fast-forward"
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
done <"$CHANGED_PATHS_FILE"
unlink "$CHANGED_PATHS_FILE" || fail "could not remove the master changed-path snapshot"
CHANGED_PATHS_FILE=""
[ -z "$IGNORED_COLLISION" ] ||
  fail "master fast-forward would overwrite ignored local data: $MASTER_OWNER/$IGNORED_COLLISION"

# Keep an existing owner's symbolic HEAD and real index locked across the complete named-ref and
# worktree refresh. An initially unowned master instead remains reserved by its helper worktree.
if [ -n "$ORIGINAL_MASTER_OWNER" ]; then
  reserve_master_owner_handoff ||
    fail "master owner HEAD or index changed before its locked refresh: $ORIGINAL_MASTER_OWNER"
  prepare_master_owner_refresh || fail "could not prepare the locked master-owner refresh"
fi
if ! git -C "$MAIN" update-ref --no-deref refs/heads/master "$REMOTE_MASTER" "$LOCAL_MASTER"; then
  if [ -n "$ORIGINAL_MASTER_OWNER" ]; then
    relock_master_owner_head ||
      fail "local master and its owner's HEAD both moved after preflight"
    MASTER_DURING_REFRESH=$(git -C "$MAIN" rev-parse refs/heads/master) ||
      fail "could not read master after its conditional update failed"
    refresh_master_owner_to "$MASTER_DURING_REFRESH" ||
      fail "local master moved and its locked owner could not follow the concurrent tip"
    MASTER_OWNER_STATUS=$(GIT_INDEX_FILE="$MASTER_OWNER_INDEX_LOCK" \
      git -C "$ORIGINAL_MASTER_OWNER" status \
        --porcelain --untracked-files=normal) ||
      fail "could not recheck the master owner after its ref moved"
    install_master_owner_refresh
    [ -z "$MASTER_OWNER_STATUS" ] ||
      fail "local master moved and its owner gained data; the data was preserved"
  fi
  fail "local master moved after its owner preflight"
fi
if [ -n "$ORIGINAL_MASTER_OWNER" ]; then
  if ! relock_master_owner_head; then
    git -C "$MAIN" update-ref --no-deref refs/heads/master "$LOCAL_MASTER" "$REMOTE_MASTER" || true
    fail "master owner changed HEAD during its locked ownership handoff"
  fi
  if ! refresh_master_owner_to "$REMOTE_MASTER"; then
    git -C "$MAIN" update-ref --no-deref refs/heads/master "$LOCAL_MASTER" "$REMOTE_MASTER" || true
    fail "master owner could not be refreshed while its HEAD and index were locked"
  fi
  MASTER_DURING_REFRESH=$(git -C "$MAIN" rev-parse refs/heads/master) ||
    fail "could not recheck master during its locked refresh"
  if [ "$MASTER_DURING_REFRESH" != "$REMOTE_MASTER" ]; then
    refresh_master_owner_to "$MASTER_DURING_REFRESH" ||
      fail "master moved during refresh and its owner could not follow the concurrent tip"
  fi
  # Ignored files pass here for the same reason as the preflight gate: pre-existing ignored data
  # on untouched paths is expected on the standard layout, and touched paths were either refused
  # by the collision scan or protected by the refresh's --no-overwrite-ignore.
  MASTER_OWNER_STATUS=$(GIT_INDEX_FILE="$MASTER_OWNER_INDEX_LOCK" git -C "$ORIGINAL_MASTER_OWNER" status \
    --porcelain --untracked-files=normal) ||
    fail "could not recheck the locked master owner"
  install_master_owner_refresh
  [ -z "$MASTER_OWNER_STATUS" ] ||
    fail "master owner gained local data during its locked update; the data was preserved"
  [ "$MASTER_DURING_REFRESH" = "$REMOTE_MASTER" ] ||
    fail "master moved during its locked refresh; its owner followed the concurrent tip"
else
  git -C "$MASTER_RESERVATION" read-tree --reset -u "$REMOTE_MASTER" >/dev/null ||
    fail "master advanced but its helper-only reservation could not be refreshed"
  git -C "$MAIN" worktree remove --force "$MASTER_RESERVATION" ||
    fail "master advanced but its temporary reservation could not be removed"
  MASTER_RESERVATION=""
fi

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
retain_topic_reflog_sides "refs/heads/$BRANCH" topic-reflog

# A stale tracking ref can retain commits absent from both the local topic and the live remote.
# Preserve any differing tip before its conditional pruning so cleanup cannot erase its last ref.
TRACKING_RECOVERY_REF=""
TRACKING_BRANCH_PRESENT=0
if git -C "$MAIN" show-ref --verify --quiet "refs/remotes/origin/$BRANCH"; then
  TRACKING_BRANCH_PRESENT=1
  TRACKING_BRANCH_OID=$(git -C "$MAIN" rev-parse "refs/remotes/origin/$BRANCH") ||
    fail "cannot read origin/$BRANCH tracking ref"
  if [ "$TRACKING_BRANCH_OID" != "$LOCAL_BRANCH_OID" ]; then
    TRACKING_RECOVERY_REF="refs/ship-pr/tracking-recovery/$BRANCH/$TRACKING_BRANCH_OID"
    if git -C "$MAIN" symbolic-ref -q "$TRACKING_RECOVERY_REF" >/dev/null 2>&1; then
      fail "tracking recovery ref is symbolic rather than direct: $TRACKING_RECOVERY_REF"
    fi
    if git -C "$MAIN" show-ref --verify --quiet "$TRACKING_RECOVERY_REF"; then
      TRACKING_RECOVERY_OID=$(git -C "$MAIN" rev-parse "$TRACKING_RECOVERY_REF") ||
        fail "cannot read $TRACKING_RECOVERY_REF"
      [ "$TRACKING_RECOVERY_OID" = "$TRACKING_BRANCH_OID" ] ||
        fail "tracking recovery ref points at an unexpected object: $TRACKING_RECOVERY_REF"
    else
      git -C "$MAIN" update-ref --no-deref "$TRACKING_RECOVERY_REF" \
        "$TRACKING_BRANCH_OID" "" || fail "could not retain $TRACKING_RECOVERY_REF"
    fi
  fi
  retain_topic_reflog_sides "refs/remotes/origin/$BRANCH" tracking-reflog
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
  CURRENT_TRACKING_BRANCH_OID=$(git -C "$MAIN" rev-parse "refs/remotes/origin/$BRANCH") ||
    fail "cannot read origin/$BRANCH tracking ref"
  [ "$TRACKING_BRANCH_PRESENT" -eq 1 ] ||
    fail "origin/$BRANCH tracking ref appeared during cleanup; its new tip was preserved"
  [ "$CURRENT_TRACKING_BRANCH_OID" = "$TRACKING_BRANCH_OID" ] ||
    fail "origin/$BRANCH tracking ref moved during cleanup; its new tip was preserved"
  delete_ref_with_locked_reflog "refs/remotes/origin/$BRANCH" \
    "$TRACKING_BRANCH_OID" tracking-reflog ||
    fail "origin/$BRANCH tracking ref changed before its leased deletion"
fi

# Inspect only the repository-local file that removal edits. Git flattens dotted subsection names,
# so test the standard branch keys exactly instead of treating branch.topic.* as unambiguous when
# topic.child is also a valid branch. Included, global, per-worktree, and custom keys are inherited
# policy rather than branch-owned upstream residue and are deliberately left alone.
CONFIG_LOCK="$MAIN_COMMON/config.lock"
(set -o noclobber; : >"$CONFIG_LOCK") 2>/dev/null ||
  fail "repository config became locked during cleanup; local $BRANCH was preserved"
CONFIG_LOCK_OWNED=1
cp -p "$MAIN_COMMON/config" "$CONFIG_LOCK" || fail "could not snapshot repository configuration"
for BRANCH_CONFIG_KEY in remote merge mergeOptions pushRemote rebase description; do
  git config --file "$CONFIG_LOCK" --no-includes --get \
    "branch.$BRANCH.$BRANCH_CONFIG_KEY" >/dev/null 2>&1
  CONFIG_GET_STATUS=$?
  case "$CONFIG_GET_STATUS" in
  0)
    git config --file "$CONFIG_LOCK" --no-includes --unset-all \
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
if ! lock_session_head_for_archive; then
  CURRENT_TOPIC_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH" 2>/dev/null || true)
  [ -n "$CURRENT_TOPIC_OID" ] && restore_remote_topic "$CURRENT_TOPIC_OID" ||
    fail "session HEAD changed, and its current topic tip could not be restored remotely"
  fail "session HEAD changed after preflight; its remote ref was restored"
fi
if ! git -C "$TOPIC_RESERVATION" switch -- "$BRANCH" >/dev/null 2>&1; then
  git -C "$MAIN" worktree remove --force "$TOPIC_RESERVATION" >/dev/null 2>&1 || true
  TOPIC_RESERVATION=""
  CURRENT_TOPIC_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH" 2>/dev/null || true)
  [ -n "$CURRENT_TOPIC_OID" ] && restore_remote_topic "$CURRENT_TOPIC_OID" ||
    fail "topic reservation failed, and its remote recovery ref could not be restored"
  fail "could not reserve local $BRANCH for deletion; its remote ref was restored"
fi
CURRENT_TOPIC_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH") || fail "cannot reread local $BRANCH"
if [ "$CURRENT_TOPIC_OID" != "$LOCAL_BRANCH_OID" ]; then
  git -C "$TOPIC_RESERVATION" checkout --detach "$LOCAL_BRANCH_OID" >/dev/null 2>&1 || true
  git -C "$MAIN" worktree remove --force "$TOPIC_RESERVATION" >/dev/null 2>&1 || true
  TOPIC_RESERVATION=""
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
# The session HEAD lock acquired during the ownership handoff stays held across this rename and
# unregister, so neither an attached nor an initially detached session can change after validation.
lock_and_retain_session_metadata
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
retain_private_session_refs
refuse_session_module_gitdirs "$SESSION_ARCHIVED_WORKTREE"
refuse_active_session_operations "$SESSION_ARCHIVED_WORKTREE"
git -C "$MAIN" update-ref --no-deref -d "$SESSION_NAMESPACE_RESERVATION" \
  "$LOCAL_BRANCH_OID" || fail "could not release the session recovery namespace reservation"
SESSION_NAMESPACE_RESERVATION_OWNED=0
if [ -e "$SESSION" ] || [ -L "$SESSION" ]; then
  atomic_rename "$SESSION" "$LATE_SESSION_ARCHIVE/data" ||
    fail "late data appeared at $SESSION and could not be moved aside safely"
fi
if ! git -C "$MAIN" worktree remove --force --force "$SESSION"; then
  { [ -e "$SESSION" ] || [ -L "$SESSION" ]; } ||
    fail "session data was archived, but its locked worktree registration could not be removed"
  atomic_rename "$SESSION" "$LATE_SESSION_ARCHIVE/data" ||
    fail "late data appeared during unregistering and could not be moved aside safely"
  git -C "$MAIN" worktree remove --force --force "$SESSION" ||
    fail "session and late data were archived, but the locked registration could not be removed"
fi
SESSION_WORKTREE_LOCK_OWNED=0
if [ ! -e "$LATE_SESSION_ARCHIVE/data" ] && [ ! -L "$LATE_SESSION_ARCHIVE/data" ]; then
  rmdir "$LATE_SESSION_ARCHIVE" || fail "unused late-data archive could not be removed"
  LATE_SESSION_ARCHIVE=""
fi
release_private_namespace_locks
SESSION_HEAD_LOCK_OWNED=0
SESSION_HEAD_LOCK=""
SESSION_PSEUDOREF_LOCKS=()
[ -d "$SESSION_ARCHIVED_WORKTREE" ] || fail "session recovery archive disappeared: $SESSION_ARCHIVED_WORKTREE"

if ! delete_ref_with_locked_reflog "refs/heads/$BRANCH" "$LOCAL_BRANCH_OID" topic-reflog; then
  CURRENT_TOPIC_OID=$(git -C "$MAIN" rev-parse "refs/heads/$BRANCH" 2>/dev/null || true)
  [ -n "$CURRENT_TOPIC_OID" ] || CURRENT_TOPIC_OID="$LOCAL_BRANCH_OID"
  restore_remote_topic "$CURRENT_TOPIC_OID" ||
    fail "local $BRANCH changed before final deletion, and its current tip could not be restored remotely"
  fail "local $BRANCH changed before final deletion; its current tip was restored remotely"
fi
atomic_rename "$CONFIG_LOCK" "$MAIN_COMMON/config" ||
  fail "local $BRANCH was deleted but its cleaned repository configuration could not be installed"
CONFIG_LOCK_OWNED=0
CONFIG_LOCK=""
git -C "$MAIN" worktree remove --force "$TOPIC_RESERVATION" ||
  fail "local $BRANCH was deleted but its temporary reservation could not be removed"
TOPIC_RESERVATION=""

if [ -n "$LATE_SESSION_ARCHIVE" ]; then
  echo "post-merge-cleanup.sh: data appearing at the former session path was archived at $LATE_SESSION_ARCHIVE" >&2
fi
echo "post-merge-cleanup.sh: cleaned $BRANCH and unregistered $SESSION_ORIGINAL; session archived at $SESSION_ARCHIVED_WORKTREE; recovery retained at $RECOVERY_REF and $SESSION_RECOVERY_REF"
