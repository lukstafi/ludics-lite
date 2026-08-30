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
  assert_ref_absent refs/remotes/origin/topic
  assert_remote_topic_absent
  ! git -C "$CASE_MAIN" config --get-regexp '^branch\.topic\.' >/dev/null 2>&1 ||
    fail "deleted topic branch configuration remained"
}

git_config() {
  git -C "$1" config user.name "Cleanup Test"
  git -C "$1" config user.email cleanup-test@example.invalid
}

setup_case() {
  local name="$1" merge_mode="$2" owner_mode="$3"
  local root="$TEST_ROOT/$name"
  CASE_ROOT="$root"
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

  setup_case session-subdirectory merge main
  mkdir "$CASE_SESSION/inside"
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION/inside" topic >/dev/null 2>&1; then
    fail "session subdirectory was accepted as the worktree root"
  fi
  assert_topic_preserved
  echo "PASS: invalid checkout path refusal"
}

test_unrelated_upstream_deletion() {
  setup_case unrelated-upstream merge main
  git -C "$CASE_MAIN" branch unrelated refs/heads/master
  git -C "$CASE_SESSION" branch --set-upstream-to=unrelated topic >/dev/null
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  echo "PASS: ancestry-verified deletion ignores unrelated upstream"
}

test_distinct_push_endpoint() {
  local push_remote fetch_tip fetch_after
  setup_case distinct-push-endpoint merge main-off
  push_remote="$CASE_ROOT/push.git"
  git clone --bare "$CASE_REMOTE" "$push_remote" >/dev/null 2>&1
  git -C "$CASE_MAIN" remote set-url --push origin "$push_remote"

  git -C "$CASE_INTEGRATOR" checkout -b topic origin/topic >/dev/null
  echo fetch-only >"$CASE_INTEGRATOR/fetch-only"
  git -C "$CASE_INTEGRATOR" add fetch-only
  git -C "$CASE_INTEGRATOR" commit -m "advance only the fetch endpoint" >/dev/null
  git -C "$CASE_INTEGRATOR" push origin topic >/dev/null
  fetch_tip=$(git -C "$CASE_INTEGRATOR" rev-parse HEAD)

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "cleanup accepted distinct fetch and push repositories"
  fi
  assert_topic_preserved
  git -C "$CASE_MAIN" ls-remote --exit-code --heads "$push_remote" refs/heads/topic >/dev/null 2>&1 ||
    fail "topic disappeared from the refused push endpoint"
  fetch_after=$(git -C "$CASE_MAIN" ls-remote origin refs/heads/topic | awk '{print $1}')
  assert_eq "$fetch_after" "$fetch_tip" "refused cleanup must preserve the fetch endpoint"
  echo "PASS: distinct fetch and push endpoints are refused"
}

test_topic_tag_collision() {
  setup_case topic-tag-collision merge main-off
  git -C "$CASE_MAIN" tag topic refs/heads/master
  git -C "$CASE_MAIN" push origin refs/tags/topic >/dev/null
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  git -C "$CASE_MAIN" ls-remote --exit-code --tags origin refs/tags/topic >/dev/null 2>&1 ||
    fail "same-named topic tag was removed"
  echo "PASS: fully qualified topic branch deletion"
}

test_master_tag_collision() {
  setup_case master-tag-collision merge none
  git -C "$CASE_MAIN" tag master refs/heads/master
  git -C "$CASE_MAIN" push origin refs/tags/master >/dev/null
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  git -C "$CASE_MAIN" ls-remote --exit-code --tags origin refs/tags/master >/dev/null 2>&1 ||
    fail "same-named master tag was removed"
  echo "PASS: fully qualified master branch fetch"
}

test_excluded_master_fetch_refusal() {
  local remote_base tracked_master
  setup_case excluded-master-fetch merge main-off
  git -C "$CASE_MAIN" fetch origin refs/heads/master:refs/remotes/origin/master >/dev/null
  git -C "$CASE_MAIN" config --unset-all remote.origin.fetch
  git -C "$CASE_MAIN" config --add remote.origin.fetch \
    "+refs/heads/topic:refs/remotes/origin/topic"
  remote_base=$(git -C "$CASE_INTEGRATOR" rev-list --max-parents=0 HEAD)
  git -C "$CASE_INTEGRATOR" push --force origin "$remote_base:refs/heads/master" >/dev/null

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "stale origin/master passed ancestry after master was excluded from the fetch map"
  fi
  tracked_master=$(git -C "$CASE_MAIN" rev-parse refs/remotes/origin/master)
  assert_eq "$tracked_master" "$remote_base" "explicit master fetch must replace stale tracking state"
  assert_topic_preserved
  echo "PASS: explicit master fetch defeats an excluding fetch map"
}

test_conditional_local_ref_deletion() {
  local fake_bin real_git old_oid new_oid tree log
  setup_case conditional-local-delete squash main-off
  fake_bin="$TEST_ROOT/update-ref-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/conditional-local-delete.log"
  old_oid=$(git -C "$CASE_MAIN" rev-parse refs/heads/topic)
  tree=$(git -C "$CASE_MAIN" rev-parse "refs/heads/topic^{tree}")
  new_oid=$(printf '%s\n' "concurrent local topic commit" | \
    git -C "$CASE_MAIN" commit-tree "$tree" -p "$old_oid")
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'for arg in "$@"; do' \
    '  if [ "$arg" = update-ref ]; then' \
    '    "$REAL_GIT" -C "$RACE_MAIN" update-ref refs/heads/topic "$RACE_NEW_OID" "$RACE_OLD_OID"' \
    '    break' \
    '  fi' \
    'done' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    RACE_NEW_OID="$new_oid" RACE_OLD_OID="$old_oid" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic \
      --force-integrated "scratch repository confirms the squash merge" >"$log" 2>&1; then
    fail "conditional deletion removed a concurrently advanced local topic"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/topic)" "$new_oid" \
    "concurrently advanced local topic must survive"
  git -C "$CASE_MAIN" cat-file -e "$new_oid^{commit}" || fail "concurrent local commit became unreachable"
  assert_absent "$CASE_SESSION"
  echo "PASS: conditional local ref deletion preserves a concurrent tip"
}

test_already_absent_remote_retry() {
  setup_case already-absent-remote merge main-off
  git -C "$CASE_MAIN" push origin :refs/heads/topic >/dev/null
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  echo "PASS: already-absent remote branch retry"
}

test_absent_remote_recreation_race() {
  local fake_bin real_git local_oid log
  setup_case absent-remote-race merge main-off
  local_oid=$(git -C "$CASE_MAIN" rev-parse refs/heads/topic)
  git -C "$CASE_MAIN" push origin :refs/heads/topic >/dev/null
  fake_bin="$TEST_ROOT/absent-race-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/absent-race.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'for arg in "$@"; do' \
    '  if [ "$arg" = push ]; then' \
    '    "$REAL_GIT" -C "$RACE_MAIN" push "$RACE_REMOTE" "$RACE_OID:refs/heads/topic" >/dev/null' \
    '    break' \
    '  fi' \
    'done' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    RACE_REMOTE="$CASE_REMOTE" RACE_OID="$local_oid" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "remote branch recreation outran the observed-absence cleanup"
  fi
  assert_topic_preserved
  echo "PASS: absent remote branch recreation is lease-refused"
}

test_other_topic_owner_refusal() {
  local other_topic
  setup_case other-topic-owner merge none
  other_topic="$CASE_ROOT/other-topic-worktree"
  git -C "$CASE_SESSION" checkout --detach >/dev/null
  git -C "$CASE_MAIN" worktree add "$other_topic" topic >/dev/null
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "detached session deleted a topic owned by another worktree"
  fi
  assert_topic_preserved
  assert_eq "$(git -C "$other_topic" symbolic-ref --short HEAD)" topic \
    "other topic worktree must remain attached"
  echo "PASS: topic owned by another worktree is refused"
}

test_dirty_session_refusal() {
  setup_case dirty-session merge main-off
  echo dirty >"$CASE_SESSION/untracked"
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "dirty session was accepted for destructive cleanup"
  fi
  assert_topic_preserved
  assert_eq "$(git -C "$CASE_SESSION" symbolic-ref --short HEAD)" topic \
    "dirty session must remain attached"
  echo "PASS: dirty session is refused before cleanup"
}

test_master_owner_switch_refusal() {
  local fake_bin real_git coordinator_before remote_master
  setup_case master-owner-switch merge other
  git -C "$CASE_MASTER_OWNER" branch coordinator
  coordinator_before=$(git -C "$CASE_MASTER_OWNER" rev-parse refs/heads/coordinator)
  remote_master=$(git -C "$CASE_INTEGRATOR" rev-parse refs/heads/master)
  fake_bin="$TEST_ROOT/master-owner-switch-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'joined=" $* "' \
    'case "$joined" in' \
    '  *" checkout --detach "*)' \
    '    if [ ! -e "$SWITCH_MARKER" ]; then' \
    '      : >"$SWITCH_MARKER"' \
    '      "$REAL_GIT" -C "$MASTER_OWNER" checkout coordinator >/dev/null' \
    '    fi' \
    '    ;;' \
    'esac' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if ! PATH="$fake_bin:$PATH" REAL_GIT="$real_git" MASTER_OWNER="$CASE_MASTER_OWNER" \
    SWITCH_MARKER="$TEST_ROOT/master-owner-switch.count" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "named master update failed after an injected owner switch"
  fi
  assert_cleaned
  assert_eq "$(git -C "$CASE_MASTER_OWNER" rev-parse refs/heads/master)" "$remote_master" \
    "named master ref must reach the remote tip"
  assert_eq "$(git -C "$CASE_MASTER_OWNER" rev-parse refs/heads/coordinator)" "$coordinator_before" \
    "coordinator must not receive the master fast-forward"
  assert_eq "$(git -C "$CASE_MASTER_OWNER" symbolic-ref --short HEAD)" master \
    "master owner must be reattached"
  echo "PASS: master owner switch cannot redirect the named ref update"
}

test_diverged_master_refusal() {
  local master_owner="$TEST_ROOT/diverged-master-owner"
  setup_case diverged-master merge none
  git -C "$CASE_MAIN" worktree add "$master_owner" master >/dev/null
  git_config "$master_owner"
  echo divergent >"$master_owner/divergent"
  git -C "$master_owner" add divergent
  git -C "$master_owner" commit -m "diverge local master" >/dev/null
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "non-fast-forward local master was accepted"
  fi
  assert_topic_preserved
  assert_eq "$(git -C "$master_owner" symbolic-ref --short HEAD)" master \
    "diverged master owner must remain attached"
  echo "PASS: divergent local master is refused before remote deletion"
}

test_locked_session_refusal() {
  setup_case locked-session merge main-off
  git -C "$CASE_MAIN" worktree lock --reason "scratch lock" "$CASE_SESSION"
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "locked session was accepted for cleanup"
  fi
  assert_topic_preserved
  echo "PASS: locked session is refused before cleanup"
}

test_symbolic_ref_refusal() {
  local tracked_master
  setup_case symbolic-local-topic merge main-off
  git -C "$CASE_MAIN" branch topic-target refs/heads/topic
  git -C "$CASE_MAIN" symbolic-ref refs/heads/topic refs/heads/topic-target
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "symbolic local topic ref was accepted"
  fi
  assert_eq "$(git -C "$CASE_MAIN" symbolic-ref refs/heads/topic)" refs/heads/topic-target \
    "symbolic local topic must remain intact"
  git -C "$CASE_MAIN" ls-remote --exit-code --heads origin refs/heads/topic >/dev/null 2>&1 ||
    fail "remote topic was deleted after symbolic local ref refusal"

  setup_case symbolic-tracking-topic merge main-off
  git -C "$CASE_MAIN" fetch origin refs/heads/master:refs/remotes/origin/master >/dev/null
  tracked_master=$(git -C "$CASE_MAIN" rev-parse refs/remotes/origin/master)
  git -C "$CASE_MAIN" symbolic-ref refs/remotes/origin/topic refs/remotes/origin/master
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "symbolic remote-tracking topic ref was accepted"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/remotes/origin/master)" "$tracked_master" \
    "symbolic tracking refusal must preserve origin/master"
  assert_topic_preserved
  echo "PASS: symbolic local and tracking refs are refused"
}

test_unchecked_out_master
test_master_owned_by_main
test_master_owned_by_other_worktree
test_safe_topic_deletion
test_squash_rebase_override
test_newer_remote_tip_refusal
test_ls_remote_failure_refusal
test_invalid_path_refusal
test_unrelated_upstream_deletion
test_distinct_push_endpoint
test_topic_tag_collision
test_master_tag_collision
test_excluded_master_fetch_refusal
test_conditional_local_ref_deletion
test_already_absent_remote_retry
test_absent_remote_recreation_race
test_other_topic_owner_refusal
test_dirty_session_refusal
test_master_owner_switch_refusal
test_diverged_master_refusal
test_locked_session_refusal
test_symbolic_ref_refusal
echo "PASS: all post-merge cleanup states"
