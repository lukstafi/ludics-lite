#!/usr/bin/env bash
# End-to-end tests for post-merge-cleanup.sh. Every repository lives under one disposable /tmp tree.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
HELPER="$SCRIPT_DIR/post-merge-cleanup.sh"
TEST_ROOT=$(mktemp -d "/tmp/post-merge-cleanup-test.XXXXXX") || exit 1

cleanup() {
  case "$TEST_ROOT" in
  /tmp/post-merge-cleanup-test.*) rm -rf "$TEST_ROOT" ;;
  *) echo "refusing to remove unexpected test root: $TEST_ROOT" >&2 ;;
  esac
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (got $1, expected $2)"
}

assert_absent() {
  [ ! -e "$1" ] || fail "expected path to be absent: $1"
}

assert_ref_absent() {
  ! git -C "$CASE_MAIN" show-ref --verify --quiet "$1" || fail "expected ref to be absent: $1"
}

assert_remote_topic_absent() {
  ! git -C "$CASE_MAIN" ls-remote --exit-code --heads origin refs/heads/topic >/dev/null 2>&1 ||
    fail "expected origin/topic to be absent"
}

assert_topic_preserved() {
  git -C "$CASE_MAIN" show-ref --verify --quiet refs/heads/topic || fail "local topic was deleted"
  git -C "$CASE_MAIN" ls-remote --exit-code --heads origin refs/heads/topic >/dev/null 2>&1 ||
    fail "remote topic was deleted"
  [ -d "$CASE_SESSION" ] || fail "topic worktree was removed"
}

assert_cleaned() {
  local local_master remote_master
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  remote_master=$(git -C "$CASE_MAIN" rev-parse refs/remotes/origin/master)
  assert_eq "$local_master" "$remote_master" "local master must match origin/master"
  assert_absent "$CASE_SESSION"
  assert_ref_absent refs/heads/topic
  assert_remote_topic_absent
}

git_config() {
  git -C "$1" config user.name "Cleanup Test"
  git -C "$1" config user.email cleanup-test@example.invalid
}

setup_case() {
  local name="$1" merge_mode="$2" owner_mode="$3"
  local root="$TEST_ROOT/$name"
  CASE_REMOTE="$root/remote.git"
  CASE_MAIN="$root/main"
  CASE_SESSION="$root/session"
  CASE_INTEGRATOR="$root/integrator"
  CASE_MASTER_OWNER="$root/master-owner"

  mkdir -p "$root"
  git init --bare "$CASE_REMOTE" >/dev/null
  git init -b master "$CASE_MAIN" >/dev/null
  git_config "$CASE_MAIN"
  echo base >"$CASE_MAIN/value"
  git -C "$CASE_MAIN" add value
  git -C "$CASE_MAIN" commit -m base >/dev/null
  git -C "$CASE_MAIN" remote add origin "$CASE_REMOTE"
  git -C "$CASE_MAIN" push -u origin master >/dev/null

  git -C "$CASE_MAIN" branch topic
  git -C "$CASE_MAIN" worktree add "$CASE_SESSION" topic >/dev/null
  git_config "$CASE_SESSION"
  echo topic >>"$CASE_SESSION/value"
  git -C "$CASE_SESSION" add value
  git -C "$CASE_SESSION" commit -m topic >/dev/null
  git -C "$CASE_SESSION" push -u origin topic >/dev/null

  git clone --branch master "$CASE_REMOTE" "$CASE_INTEGRATOR" >/dev/null 2>&1
  git_config "$CASE_INTEGRATOR"
  case "$merge_mode" in
  merge)
    git -C "$CASE_INTEGRATOR" merge --no-ff origin/topic -m "merge topic" >/dev/null
    git -C "$CASE_INTEGRATOR" push origin master >/dev/null
    ;;
  squash)
    git -C "$CASE_INTEGRATOR" merge --squash origin/topic >/dev/null
    git -C "$CASE_INTEGRATOR" commit -m "squash topic" >/dev/null
    git -C "$CASE_INTEGRATOR" push origin master >/dev/null
    ;;
  unmerged) ;;
  *) fail "unknown merge mode: $merge_mode" ;;
  esac

  case "$owner_mode" in
  none) git -C "$CASE_MAIN" checkout --detach >/dev/null ;;
  main) ;;
  other)
    git -C "$CASE_MAIN" checkout --detach >/dev/null
    git -C "$CASE_MAIN" worktree add "$CASE_MASTER_OWNER" master >/dev/null
    ;;
  main-off)
    git -C "$CASE_MAIN" checkout -b coordinator >/dev/null
    ;;
  *) fail "unknown owner mode: $owner_mode" ;;
  esac
}

test_unchecked_out_master() {
  setup_case unchecked-out-master merge none
  (cd "$CASE_SESSION" && "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null)
  assert_cleaned
  echo "PASS: unchecked-out master"
}

test_master_owned_by_main() {
  setup_case master-owned-by-main merge main
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" symbolic-ref --short HEAD)" master "main checkout must still own master"
  echo "PASS: master owned by main checkout"
}

test_master_owned_by_other_worktree() {
  setup_case master-owned-by-other merge other
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MASTER_OWNER" symbolic-ref --short HEAD)" master "other worktree must own master"
  assert_eq "$(git -C "$CASE_MASTER_OWNER" rev-parse HEAD)" "$(git -C "$CASE_MAIN" rev-parse refs/remotes/origin/master)" \
    "other worktree must be fast-forwarded"
  echo "PASS: master owned by another worktree"
}

test_safe_topic_deletion() {
  setup_case safe-topic-deletion merge main-off
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" symbolic-ref --short HEAD)" coordinator \
    "main checkout must remain on its unrelated branch"

  setup_case unmerged-topic-refusal unmerged main-off
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "unmerged topic cleanup unexpectedly succeeded"
  fi
  assert_topic_preserved
  echo "PASS: safe topic deletion and unmerged refusal"
}

test_squash_rebase_override() {
  setup_case squash-override squash main-off
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "squash-merged topic cleanup succeeded without an override"
  fi
  git -C "$CASE_MAIN" show-ref --verify --quiet refs/heads/topic || fail "topic disappeared before override"
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic \
    --force-integrated "scratch repository confirms the squash merge" >/dev/null
  assert_cleaned
  echo "PASS: explicit squash/rebase override"
}

test_newer_remote_tip_refusal() {
  local remote_tip after_tip
  setup_case newer-remote-tip merge main-off
  git -C "$CASE_INTEGRATOR" checkout -b topic origin/topic >/dev/null
  echo newer >"$CASE_INTEGRATOR/newer"
  git -C "$CASE_INTEGRATOR" add newer
  git -C "$CASE_INTEGRATOR" commit -m "newer remote topic work" >/dev/null
  git -C "$CASE_INTEGRATOR" push origin topic >/dev/null
  remote_tip=$(git -C "$CASE_INTEGRATOR" rev-parse HEAD)

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "cleanup deleted a newer remote topic tip"
  fi
  after_tip=$(git -C "$CASE_MAIN" ls-remote origin refs/heads/topic | awk '{print $1}')
  assert_eq "$after_tip" "$remote_tip" "newer remote topic tip must be preserved"
  assert_topic_preserved
  echo "PASS: newer remote topic tip refusal"
}

test_ls_remote_failure_refusal() {
  local fake_bin real_git log
  setup_case ls-remote-failure merge main-off
  fake_bin="$TEST_ROOT/fake-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/ls-remote-failure.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'for arg in "$@"; do' \
    '  [ "$arg" = ls-remote ] && exit 1' \
    'done' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "ls-remote transport failure was treated as branch absence"
  fi
  grep -F "could not determine whether origin/topic exists (ls-remote exit 1)" "$log" >/dev/null ||
    fail "ls-remote failure was not diagnosed distinctly"
  assert_topic_preserved
  echo "PASS: ls-remote failure refusal"
}

test_invalid_path_refusal() {
  setup_case missing-main-path merge main
  if (cd "$CASE_SESSION" && "$HELPER" "$TEST_ROOT/missing-main" "$CASE_SESSION" topic >/dev/null 2>&1); then
    fail "missing main path did not stop cleanup"
  fi
  assert_topic_preserved

  setup_case missing-session-path merge main
  if "$HELPER" "$CASE_MAIN" "$TEST_ROOT/missing-session" topic >/dev/null 2>&1; then
    fail "missing session path did not stop cleanup"
  fi
  assert_topic_preserved
  echo "PASS: invalid checkout path refusal"
}

test_unchecked_out_master
test_master_owned_by_main
test_master_owned_by_other_worktree
test_safe_topic_deletion
test_squash_rebase_override
test_newer_remote_tip_refusal
test_ls_remote_failure_refusal
test_invalid_path_refusal
echo "PASS: all post-merge cleanup states"
