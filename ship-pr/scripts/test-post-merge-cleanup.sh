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
  ! git -C "$CASE_MAIN" ls-remote --exit-code --heads origin "refs/heads/$CASE_BRANCH" >/dev/null 2>&1 ||
    fail "expected origin/$CASE_BRANCH to be absent"
}

assert_topic_preserved() {
  git -C "$CASE_MAIN" show-ref --verify --quiet "refs/heads/$CASE_BRANCH" || fail "local topic was deleted"
  git -C "$CASE_MAIN" ls-remote --exit-code --heads origin "refs/heads/$CASE_BRANCH" >/dev/null 2>&1 ||
    fail "remote $CASE_BRANCH was deleted"
  [ -d "$CASE_SESSION" ] || fail "topic worktree was removed"
}

assert_cleaned() {
  local archive archive_count branch_key local_master remote_master
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  remote_master=$(git -C "$CASE_MAIN" rev-parse refs/remotes/origin/master)
  assert_eq "$local_master" "$remote_master" "local master must match origin/master"
  assert_absent "$CASE_SESSION"
  assert_ref_absent "refs/heads/$CASE_BRANCH"
  assert_ref_absent "refs/remotes/origin/$CASE_BRANCH"
  assert_remote_topic_absent
  for branch_key in remote merge pushRemote rebase description; do
    ! git -C "$CASE_MAIN" config --local --no-includes \
      --get "branch.$CASE_BRANCH.$branch_key" >/dev/null 2>&1 ||
      fail "repository-local topic branch configuration remained: $branch_key"
  done
  assert_eq "$(git -C "$CASE_MAIN" rev-parse "refs/ship-pr/recovery/$CASE_BRANCH/$CASE_TOPIC_OID")" \
    "$CASE_TOPIC_OID" "topic recovery ref must retain the cleaned tip"
  archive_count=0
  CASE_ARCHIVE=""
  for archive in "$CASE_ROOT"/.session.ship-pr-recovery.*; do
    [ -d "$archive" ] || continue
    archive_count=$((archive_count + 1))
    CASE_ARCHIVE="$archive"
  done
  assert_eq "$archive_count" 1 "cleanup must retain exactly one session archive"
  [ -f "$CASE_ARCHIVE/worktree/value" ] || fail "session archive did not retain tracked worktree files"
}

git_config() {
  git -C "$1" config user.name "Cleanup Test"
  git -C "$1" config user.email cleanup-test@example.invalid
}

git_log_path() {
  local checkout="$1" ref="$2" path
  path=$(git -C "$checkout" rev-parse --git-path "logs/$ref") || return 1
  case "$path" in
  /*) printf '%s\n' "$path" ;;
  *) printf '%s\n' "$checkout/$path" ;;
  esac
}

keep_last_reflog_entry() {
  local checkout="$1" ref="$2" path snapshot
  path=$(git_log_path "$checkout" "$ref") || fail "could not locate $ref reflog"
  snapshot="$path.ship-pr-test-last"
  tail -n 1 "$path" >"$snapshot"
  mv "$snapshot" "$path"
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
  CASE_BRANCH=topic

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
  CASE_TOPIC_OID=$(git -C "$CASE_SESSION" rev-parse HEAD)

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
    'if [ "$3" = update-ref ] && [ "$5" = refs/heads/master ]; then' \
    '  "$REAL_GIT" -C "$RACE_MAIN" update-ref refs/heads/topic "$RACE_NEW_OID" "$RACE_OLD_OID"' \
    'fi' \
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
  [ -d "$CASE_SESSION" ] || fail "topic worktree was removed after its branch advanced"
  assert_eq "$(git -C "$CASE_SESSION" symbolic-ref --short HEAD)" topic \
    "advanced topic worktree must remain attached"
  assert_eq "$(git -C "$CASE_MAIN" ls-remote origin refs/heads/topic | awk '{print $1}')" "$old_oid" \
    "remote topic must remain at the validated tip when the local branch advances early"
  echo "PASS: topic advancement preserves its branch and worktree"
}

test_already_absent_remote_retry() {
  setup_case already-absent-remote merge main-off
  git -C "$CASE_MAIN" push origin :refs/heads/topic >/dev/null
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  echo "PASS: already-absent remote branch retry"
}

test_absent_remote_recreation_race() {
  local fake_bin local_oid new_oid real_git log tree
  setup_case absent-remote-race merge main-off
  local_oid=$(git -C "$CASE_MAIN" rev-parse refs/heads/topic)
  tree=$(git -C "$CASE_MAIN" rev-parse "refs/heads/topic^{tree}")
  new_oid=$(printf '%s\n' "concurrent remote recreation" | \
    git -C "$CASE_MAIN" commit-tree "$tree" -p "$local_oid")
  git -C "$CASE_MAIN" push origin :refs/heads/topic >/dev/null
  fake_bin="$TEST_ROOT/absent-race-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/absent-race.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'is_topic_query=0' \
    'for arg in "$@"; do' \
    '  [ "$arg" = refs/heads/topic ] && is_topic_query=1' \
    'done' \
    'if [ "$3" = ls-remote ] && [ "$is_topic_query" -eq 1 ]; then' \
    '  output=$("$REAL_GIT" "$@")' \
    '  status=$?' \
    '  "$REAL_GIT" -C "$RACE_MAIN" push "$RACE_REMOTE" "$RACE_OID:refs/heads/topic" >/dev/null' \
    '  printf "%s\\n" "$output"' \
    '  exit "$status"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    RACE_REMOTE="$CASE_REMOTE" RACE_OID="$new_oid" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1
  assert_eq "$(git -C "$CASE_MAIN" ls-remote origin refs/heads/topic | awk '{print $1}')" \
    "$new_oid" "branch created after an absent observation must never be deleted"
  git -C "$CASE_MAIN" push origin :refs/heads/topic >/dev/null
  assert_cleaned
  echo "PASS: branch created after absent advertisement is preserved"
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

test_ignored_session_refusal() {
  setup_case ignored-session merge main-off
  echo local.log >>"$CASE_MAIN/.git/info/exclude"
  echo irreplaceable >"$CASE_SESSION/local.log"
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "session containing ignored data was accepted for destructive cleanup"
  fi
  assert_eq "$(sed -n '1p' "$CASE_SESSION/local.log")" irreplaceable \
    "ignored session data must survive refused cleanup"
  assert_topic_preserved
  echo "PASS: ignored session data is refused before cleanup"
}

test_master_reservation() {
  local fake_bin real_git candidate remote_master checkout_status
  setup_case master-owner-switch merge other
  remote_master=$(git -C "$CASE_INTEGRATOR" rev-parse refs/heads/master)
  candidate="$CASE_ROOT/master-candidate"
  git -C "$CASE_MAIN" worktree add --detach "$candidate" refs/heads/master >/dev/null
  fake_bin="$TEST_ROOT/master-owner-switch-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = update-ref ] && [ "$5" = refs/heads/master ]; then' \
    '  "$REAL_GIT" -C "$MASTER_CANDIDATE" checkout master >/dev/null 2>&1' \
    '  echo "$?" >"$SWITCH_MARKER"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if ! PATH="$fake_bin:$PATH" REAL_GIT="$real_git" MASTER_CANDIDATE="$candidate" \
    SWITCH_MARKER="$TEST_ROOT/master-owner-switch.count" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "continuously owned master update failed"
  fi
  checkout_status=$(cat "$TEST_ROOT/master-owner-switch.count")
  [ "$checkout_status" -ne 0 ] || fail "another worktree acquired master during its named update"
  assert_cleaned
  assert_eq "$(git -C "$CASE_MASTER_OWNER" rev-parse refs/heads/master)" "$remote_master" \
    "named master ref must reach the remote tip"
  assert_eq "$(git -C "$CASE_MASTER_OWNER" symbolic-ref --short HEAD)" master \
    "master must remain continuously owned"
  ! git -C "$candidate" symbolic-ref -q HEAD >/dev/null 2>&1 ||
    fail "candidate worktree stopped being detached"
  echo "PASS: continuous master ownership blocks another checkout"
}

test_unowned_master_reservation() {
  local fake_bin real_git candidate checkout_status
  setup_case unowned-master-reservation merge none
  candidate="$CASE_ROOT/master-candidate"
  git -C "$CASE_MAIN" worktree add --detach "$candidate" refs/heads/master >/dev/null
  fake_bin="$TEST_ROOT/unowned-master-reservation-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = update-ref ] && [ "$5" = refs/heads/master ]; then' \
    '  "$REAL_GIT" -C "$MASTER_CANDIDATE" checkout master >/dev/null 2>&1' \
    '  echo "$?" >"$SWITCH_MARKER"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if ! PATH="$fake_bin:$PATH" REAL_GIT="$real_git" MASTER_CANDIDATE="$candidate" \
    SWITCH_MARKER="$TEST_ROOT/unowned-master-reservation.status" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "temporary reservation of unchecked-out master failed"
  fi
  checkout_status=$(cat "$TEST_ROOT/unowned-master-reservation.status")
  [ "$checkout_status" -ne 0 ] || fail "another worktree acquired initially unowned master"
  assert_cleaned
  ! git -C "$candidate" symbolic-ref -q HEAD >/dev/null 2>&1 ||
    fail "candidate worktree stopped being detached"
  echo "PASS: unchecked-out master is reserved during its update"
}

test_concurrent_master_edit_refusal() {
  local fake_bin real_git log remote_master
  setup_case concurrent-master-edit merge other
  remote_master=$(git -C "$CASE_INTEGRATOR" rev-parse refs/heads/master)
  fake_bin="$TEST_ROOT/concurrent-master-edit-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/concurrent-master-edit.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = switch ] && [ "$4" = --detach ] && [ "$6" = "$RACE_TARGET" ]; then' \
    '  echo concurrent-edit >"$MASTER_OWNER/value"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" MASTER_OWNER="$CASE_MASTER_OWNER" \
    RACE_TARGET="$remote_master" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "master fast-forward discarded a concurrent tracked edit"
  fi
  assert_eq "$(sed -n '1p' "$CASE_MASTER_OWNER/value")" concurrent-edit \
    "concurrent master edit must survive a refused fast-forward"
  assert_topic_preserved
  echo "PASS: concurrent master edit is refused without data loss"
}

test_concurrent_ignored_master_collision() {
  local fake_bin real_git log collision remote_master
  setup_case concurrent-ignored-master-collision merge other
  collision="$CASE_MASTER_OWNER/collision"
  echo remote-data >"$CASE_INTEGRATOR/collision"
  git -C "$CASE_INTEGRATOR" add collision
  git -C "$CASE_INTEGRATOR" commit -m "add incoming master path" >/dev/null
  git -C "$CASE_INTEGRATOR" push origin master >/dev/null
  remote_master=$(git -C "$CASE_INTEGRATOR" rev-parse refs/heads/master)
  echo collision >>"$CASE_MAIN/.git/info/exclude"
  fake_bin="$TEST_ROOT/concurrent-ignored-master-collision-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/concurrent-ignored-master-collision.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = switch ] && [ "$4" = --detach ] && [ "$6" = "$RACE_TARGET" ]; then' \
    '  echo local-data >"$MASTER_COLLISION"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" MASTER_COLLISION="$collision" \
    RACE_TARGET="$remote_master" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "master fast-forward overwrote an ignored file created after collision preflight"
  fi
  assert_eq "$(sed -n '1p' "$collision")" local-data \
    "concurrently created ignored master data must survive"
  assert_topic_preserved
  echo "PASS: concurrent ignored master collision is refused"
}

test_preexisting_ignored_master_data() {
  local local_master
  setup_case preexisting-ignored-master-data merge other
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  echo unrelated.log >>"$CASE_MAIN/.git/info/exclude"
  echo local-data >"$CASE_MASTER_OWNER/unrelated.log"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "master with pre-existing ignored data was advanced into an unretryable state"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "pre-existing ignored master data must be refused before the master ref changes"
  assert_eq "$(sed -n '1p' "$CASE_MASTER_OWNER/unrelated.log")" local-data \
    "pre-existing ignored master data must survive"
  assert_topic_preserved
  echo "PASS: pre-existing ignored master data is refused before mutation"
}

test_master_owner_switch_refusal() {
  local checkout_status fake_bin real_git local_master log remote_master
  setup_case master-owner-branch-switch merge other
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  remote_master=$(git -C "$CASE_INTEGRATOR" rev-parse refs/heads/master)
  git -C "$CASE_MAIN" branch alternate "$local_master"
  fake_bin="$TEST_ROOT/master-owner-branch-switch-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/master-owner-branch-switch.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = update-ref ] && [ "$5" = refs/heads/master ]; then' \
    '  "$REAL_GIT" -C "$MASTER_OWNER" checkout alternate >/dev/null 2>&1' \
    '  echo "$?" >"$SWITCH_MARKER"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" MASTER_OWNER="$CASE_MASTER_OWNER" \
    SWITCH_MARKER="$TEST_ROOT/master-owner-branch-switch.status" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1
  checkout_status=$(cat "$TEST_ROOT/master-owner-branch-switch.status")
  [ "$checkout_status" -eq 0 ] || fail "test did not switch the detached original master owner"
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$remote_master" \
    "master must reach the remote tip while its checkout is locked"
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/alternate)" "$local_master" \
    "unrelated branch must not be advanced by the master update"
  assert_cleaned
  echo "PASS: master ownership handoff prevents update redirection"
}

test_master_update_failure_reattaches_owner() {
  local candidate checkout_status fake_bin local_master real_git remote_master log
  setup_case master-update-failure merge other
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  remote_master=$(git -C "$CASE_INTEGRATOR" rev-parse refs/heads/master)
  candidate="$CASE_ROOT/master-recovery-candidate"
  git -C "$CASE_MAIN" worktree add --detach "$candidate" "$local_master" >/dev/null
  fake_bin="$TEST_ROOT/master-update-failure-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/master-update-failure.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = update-ref ] && [ "$5" = refs/heads/master ]; then' \
    '  "$REAL_GIT" -C "$RACE_MAIN" update-ref refs/heads/master "$RACE_REMOTE" "$RACE_LOCAL"' \
    'fi' \
    'if [ "$3" = worktree ] && [ "$4" = remove ]; then' \
    '  case "$*" in' \
    '  *ship-pr-master-reserve*)' \
    '    "$REAL_GIT" -C "$MASTER_CANDIDATE" checkout master >/dev/null 2>&1' \
    '    echo "$?" >"$CHECKOUT_MARKER"' \
    '    ;;' \
    '  esac' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    RACE_LOCAL="$local_master" RACE_REMOTE="$remote_master" MASTER_CANDIDATE="$candidate" \
    CHECKOUT_MARKER="$TEST_ROOT/master-update-failure-checkout.status" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "conditional master update unexpectedly succeeded after a competing update"
  fi
  assert_eq "$(git -C "$CASE_MASTER_OWNER" symbolic-ref --short HEAD)" master \
    "original master owner must be reattached after update-ref failure"
  assert_eq "$(git -C "$CASE_MASTER_OWNER" rev-parse HEAD)" "$remote_master" \
    "reattached master owner must follow the concurrently updated ref"
  checkout_status=$(cat "$TEST_ROOT/master-update-failure-checkout.status")
  [ "$checkout_status" -ne 0 ] || fail "competitor acquired master during failure recovery"
  assert_topic_preserved
  echo "PASS: master update failure reattaches the original owner"
}

test_master_handoff_stays_reserved() {
  local candidate checkout_status fake_bin real_git
  setup_case master-handoff-reserved merge other
  candidate="$CASE_ROOT/master-handoff-candidate"
  git -C "$CASE_MAIN" worktree add --detach "$candidate" refs/heads/master >/dev/null
  fake_bin="$TEST_ROOT/master-handoff-reserved-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = worktree ] && [ "$4" = remove ]; then' \
    '  case "$*" in' \
    '  *ship-pr-master-reserve*)' \
    '    "$REAL_GIT" -C "$MASTER_CANDIDATE" checkout master >/dev/null 2>&1' \
    '    echo "$?" >"$CHECKOUT_MARKER"' \
    '    ;;' \
    '  esac' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" MASTER_CANDIDATE="$candidate" \
    CHECKOUT_MARKER="$TEST_ROOT/master-handoff-reserved.status" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  checkout_status=$(cat "$TEST_ROOT/master-handoff-reserved.status")
  [ "$checkout_status" -ne 0 ] || fail "competitor acquired master during reservation removal"
  assert_eq "$(git -C "$CASE_MASTER_OWNER" symbolic-ref --short HEAD)" master \
    "original master owner must already be attached before reservation removal"
  assert_cleaned
  echo "PASS: master remains owned across reservation removal"
}

test_master_refresh_preserves_concurrent_ref() {
  local competitor_oid fake_bin real_git remote_master
  setup_case master-refresh-race merge none
  remote_master=$(git -C "$CASE_INTEGRATOR" rev-parse refs/heads/master)
  git -C "$CASE_MAIN" fetch origin refs/heads/master:refs/remotes/origin/master >/dev/null
  competitor_oid=$(printf 'competing master update\n' | git -C "$CASE_MAIN" commit-tree \
    "$(git -C "$CASE_MAIN" rev-parse "$remote_master^{tree}")" -p "$remote_master")
  fake_bin="$TEST_ROOT/master-refresh-race-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = read-tree ] && [ ! -e "$RACE_MARKER" ]; then' \
    '  : >"$RACE_MARKER"' \
    '  "$REAL_GIT" -C "$RACE_MAIN" update-ref refs/heads/master "$RACE_OID" "$REMOTE_MASTER"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    RACE_OID="$competitor_oid" REMOTE_MASTER="$remote_master" \
    RACE_MARKER="$TEST_ROOT/master-refresh-race.injected" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "reservation refresh overwrote a concurrent master ref update"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$competitor_oid" \
    "reservation refresh must not move a concurrently advanced master"
  assert_topic_preserved
  echo "PASS: master reservation refresh never resets the named ref"
}

test_master_reattach_compare_and_swap() {
  local alternate_oid fake_bin local_master real_git log
  setup_case master-reattach-cas merge other
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  git -C "$CASE_MAIN" branch alternate "$local_master"
  alternate_oid=$(git -C "$CASE_MAIN" rev-parse refs/heads/alternate)
  fake_bin="$TEST_ROOT/master-reattach-cas-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/master-reattach-cas.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = update-ref ] && [ "$4" = --stdin ]; then' \
    '  case "$2" in' \
    '  */master-owner) "$REAL_GIT" -C "$MASTER_OWNER" checkout alternate >/dev/null 2>&1 ;;' \
    '  esac' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" MASTER_OWNER="$CASE_MASTER_OWNER" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "master reattachment overwrote a concurrently switched HEAD"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/alternate)" "$alternate_oid" \
    "compare-and-swap refusal must not advance the competing branch"
  assert_eq "$(git -C "$CASE_MASTER_OWNER" symbolic-ref --short HEAD)" master \
    "failure recovery must safely reattach the original owner"
  assert_topic_preserved
  echo "PASS: master reattachment uses a detached-HEAD compare-and-swap"
}

test_master_reattach_verifies_named_branch() {
  local competitor_oid fake_bin real_git remote_master
  setup_case master-reattach-named-ref-cas merge other
  remote_master=$(git -C "$CASE_INTEGRATOR" rev-parse refs/heads/master)
  git -C "$CASE_MAIN" fetch origin refs/heads/master:refs/remotes/origin/master >/dev/null
  competitor_oid=$(printf 'competing master update before reattachment\n' |
    git -C "$CASE_MAIN" commit-tree "$(git -C "$CASE_MAIN" rev-parse "$remote_master^{tree}")" \
      -p "$remote_master")
  fake_bin="$TEST_ROOT/master-reattach-named-ref-cas-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$2" in' \
    '*/master-owner)' \
    '  if [ "$3" = update-ref ] && [ "$4" = --stdin ] && [ ! -e "$RACE_MARKER" ]; then' \
    '    : >"$RACE_MARKER"' \
    '    "$REAL_GIT" -C "$RACE_MAIN" update-ref refs/heads/master "$RACE_OID" "$REMOTE_MASTER"' \
    '  fi' \
    '  ;;' \
    'esac' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" \
    RACE_MAIN="$CASE_MAIN" RACE_OID="$competitor_oid" REMOTE_MASTER="$remote_master" \
    RACE_MARKER="$TEST_ROOT/master-reattach-named-ref-cas.injected" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "master reattachment ignored a concurrent named-branch update"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$competitor_oid" \
    "master reattachment must preserve a concurrently advanced named branch"
  assert_eq "$(git -C "$CASE_MASTER_OWNER" symbolic-ref --short HEAD)" master \
    "failure recovery must reattach the original owner to the current master"
  assert_eq "$(git -C "$CASE_MASTER_OWNER" rev-parse HEAD)" "$competitor_oid" \
    "failure recovery must use the concurrent master tip"
  [ -z "$(git -C "$CASE_MASTER_OWNER" status --porcelain --untracked-files=all)" ] ||
    fail "failure recovery left the original master owner dirty"
  assert_topic_preserved
  echo "PASS: master reattachment verifies the named branch in its HEAD transaction"
}

test_ignored_data_during_master_detach() {
  local fake_bin local_master log real_git
  setup_case ignored-data-during-master-detach merge other
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  git -C "$CASE_MAIN" branch alternate "$local_master"
  git -C "$CASE_MASTER_OWNER" checkout alternate >/dev/null
  git -C "$CASE_MASTER_OWNER" rm value >/dev/null
  git -C "$CASE_MASTER_OWNER" commit -m "alternate omits old-master path" >/dev/null
  git -C "$CASE_MASTER_OWNER" checkout master >/dev/null
  echo value >>"$CASE_MAIN/.git/info/exclude"
  fake_bin="$TEST_ROOT/ignored-data-during-master-detach-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/ignored-data-during-master-detach.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = switch ] && [ "$4" = --detach ] && [ ! -e "$RACE_MARKER" ]; then' \
    '  : >"$RACE_MARKER"' \
    '  "$REAL_GIT" -C "$MASTER_OWNER" checkout alternate >/dev/null 2>&1' \
    '  echo local-data >"$MASTER_OWNER/value"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" MASTER_OWNER="$CASE_MASTER_OWNER" \
    RACE_MARKER="$TEST_ROOT/ignored-data-during-master-detach.injected" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "initial master detach overwrote ignored data"
  fi
  assert_eq "$(sed -n '1p' "$CASE_MASTER_OWNER/value")" local-data \
    "ignored data created during initial master detach must survive"
  assert_topic_preserved
  echo "PASS: initial master detach refuses ignored data"
}

test_ignored_data_during_topic_detach() {
  local fake_bin log new_topic_oid real_git remote_topic_oid
  setup_case ignored-data-during-topic-detach merge main-off
  echo /value >"$CASE_SESSION/.gitignore"
  git -C "$CASE_SESSION" add .gitignore
  git -C "$CASE_SESSION" commit -m "ignore the tracked topic path" >/dev/null
  git -C "$CASE_SESSION" push origin topic >/dev/null
  CASE_TOPIC_OID=$(git -C "$CASE_SESSION" rev-parse HEAD)
  git -C "$CASE_INTEGRATOR" fetch origin topic >/dev/null
  git -C "$CASE_INTEGRATOR" merge --no-ff origin/topic -m "merge topic ignore rule" >/dev/null
  git -C "$CASE_INTEGRATOR" push origin master >/dev/null
  fake_bin="$TEST_ROOT/ignored-data-during-topic-detach-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/ignored-data-during-topic-detach.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = checkout ] && [ "$4" = --detach ] && [ "$5" = --no-overwrite-ignore ] && [ ! -e "$RACE_MARKER" ]; then' \
    '  : >"$RACE_MARKER"' \
    '  "$REAL_GIT" -C "$RACE_SESSION" rm value >/dev/null' \
    '  "$REAL_GIT" -C "$RACE_SESSION" commit -m "remove tracked topic path" >/dev/null' \
    '  echo irreplaceable >"$RACE_SESSION/value"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_SESSION="$CASE_SESSION" \
    RACE_MARKER="$TEST_ROOT/ignored-data-during-topic-detach.injected" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "topic detach overwrote ignored data"
  fi
  [ -e "$TEST_ROOT/ignored-data-during-topic-detach.injected" ] ||
    fail "topic detach race was not injected"
  assert_eq "$(sed -n '1p' "$CASE_SESSION/value")" irreplaceable \
    "ignored data created during topic detach must survive"
  new_topic_oid=$(git -C "$CASE_MAIN" rev-parse refs/heads/topic)
  remote_topic_oid=$(git -C "$CASE_MAIN" ls-remote origin refs/heads/topic | awk '{print $1}')
  assert_eq "$remote_topic_oid" "$new_topic_oid" \
    "topic detach refusal must restore the concurrently advanced tip remotely"
  assert_topic_preserved
  echo "PASS: topic detach refuses ignored data and restores the current remote tip"
}

test_ignored_data_during_topic_reattach() {
  local blob fake_bin index_file log new_topic_oid real_git remote_topic_oid tree
  setup_case ignored-data-during-topic-reattach merge main-off
  echo /ignored-collision >>"$CASE_MAIN/.git/info/exclude"
  blob=$(printf 'branch bytes\n' | git -C "$CASE_MAIN" hash-object -w --stdin)
  index_file=$(mktemp "$TEST_ROOT/topic-reattach-index.XXXXXX")
  GIT_INDEX_FILE="$index_file" git -C "$CASE_MAIN" read-tree "$CASE_TOPIC_OID"
  GIT_INDEX_FILE="$index_file" git -C "$CASE_MAIN" update-index \
    --add --cacheinfo 100644 "$blob" ignored-collision
  tree=$(GIT_INDEX_FILE="$index_file" git -C "$CASE_MAIN" write-tree)
  unlink "$index_file"
  new_topic_oid=$(printf 'advance topic during ownership handoff\n' |
    git -C "$CASE_MAIN" commit-tree "$tree" -p "$CASE_TOPIC_OID")
  fake_bin="$TEST_ROOT/ignored-data-during-topic-reattach-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/ignored-data-during-topic-reattach.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$2" in' \
    '*ship-pr-topic-reserve*)' \
    '  if [ "$3" = switch ] && [ "$5" = topic ] && [ ! -e "$RACE_MARKER" ]; then' \
    '    : >"$RACE_MARKER"' \
    '    "$REAL_GIT" -C "$RACE_MAIN" update-ref refs/heads/topic "$RACE_OID" "$TOPIC_OID"' \
    '    printf "irreplaceable local bytes\n" >"$RACE_SESSION/ignored-collision"' \
    '  fi' \
    '  ;;' \
    'esac' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    RACE_SESSION="$CASE_SESSION" RACE_OID="$new_topic_oid" TOPIC_OID="$CASE_TOPIC_OID" \
    RACE_MARKER="$TEST_ROOT/ignored-data-during-topic-reattach.injected" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "topic ownership race unexpectedly completed cleanup"
  fi
  [ -e "$TEST_ROOT/ignored-data-during-topic-reattach.injected" ] ||
    fail "topic reattachment race was not injected"
  assert_eq "$(sed -n '1p' "$CASE_SESSION/ignored-collision")" "irreplaceable local bytes" \
    "topic reattachment must not overwrite ignored session data"
  remote_topic_oid=$(git -C "$CASE_MAIN" ls-remote origin refs/heads/topic | awk '{print $1}')
  assert_eq "$remote_topic_oid" "$new_topic_oid" \
    "topic reattachment refusal must restore the concurrently advanced tip remotely"
  assert_topic_preserved
  echo "PASS: topic reattachment refuses to overwrite ignored session data"
}

test_initialized_session_submodule_refusal() {
  local local_master sub_remote sub_seed unique_submodule_oid
  setup_case initialized-session-submodule merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  sub_remote="$CASE_ROOT/submodule.git"
  sub_seed="$CASE_ROOT/submodule-seed"
  git init --bare "$sub_remote" >/dev/null
  git -C "$sub_remote" symbolic-ref HEAD refs/heads/main
  git init -b main "$sub_seed" >/dev/null
  git_config "$sub_seed"
  echo submodule-base >"$sub_seed/payload"
  git -C "$sub_seed" add payload
  git -C "$sub_seed" commit -m "submodule base" >/dev/null
  git -C "$sub_seed" remote add origin "$sub_remote"
  git -C "$sub_seed" push -u origin main >/dev/null
  git -c protocol.file.allow=always -C "$CASE_SESSION" submodule add \
    "$sub_remote" nested >/dev/null
  git -C "$CASE_SESSION" commit -m "add initialized submodule" >/dev/null
  git -C "$CASE_SESSION" push origin topic >/dev/null
  CASE_TOPIC_OID=$(git -C "$CASE_SESSION" rev-parse HEAD)
  git -C "$CASE_INTEGRATOR" fetch origin topic >/dev/null
  git -C "$CASE_INTEGRATOR" merge --no-ff origin/topic -m "merge initialized submodule" >/dev/null
  git -C "$CASE_INTEGRATOR" push origin master >/dev/null
  git_config "$CASE_SESSION/nested"
  git -C "$CASE_SESSION" config submodule.nested.ignore all
  echo unique >>"$CASE_SESSION/nested/payload"
  git -C "$CASE_SESSION/nested" add payload
  git -C "$CASE_SESSION/nested" commit -m "unique linked-worktree submodule commit" >/dev/null
  unique_submodule_oid=$(git -C "$CASE_SESSION/nested" rev-parse HEAD)
  [ -z "$(git -C "$CASE_SESSION" status --porcelain --untracked-files=normal --ignored=matching)" ] ||
    fail "submodule ignore=all did not produce the intended clean superproject"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "initialized session submodule was accepted for cleanup"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "initialized submodule refusal must precede master advancement"
  git -C "$CASE_SESSION/nested" cat-file -e "$unique_submodule_oid^{commit}" ||
    fail "unique linked-worktree submodule commit was lost"
  assert_topic_preserved
  echo "PASS: initialized session submodule is refused before mutation"
}

test_deinitialized_session_submodule_refusal() {
  local local_master log session_git_dir status sub_remote sub_seed unique_submodule_oid
  setup_case deinitialized-session-submodule merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  sub_remote="$CASE_ROOT/submodule.git"
  sub_seed="$CASE_ROOT/submodule-seed"
  git init --bare "$sub_remote" >/dev/null
  git -C "$sub_remote" symbolic-ref HEAD refs/heads/main
  git init -b main "$sub_seed" >/dev/null
  git_config "$sub_seed"
  echo submodule-base >"$sub_seed/payload"
  git -C "$sub_seed" add payload
  git -C "$sub_seed" commit -m "submodule base" >/dev/null
  git -C "$sub_seed" remote add origin "$sub_remote"
  git -C "$sub_seed" push -u origin main >/dev/null
  git -c protocol.file.allow=always -C "$CASE_SESSION" submodule add \
    "$sub_remote" nested >/dev/null
  git -C "$CASE_SESSION" commit -m "add deinitialized submodule" >/dev/null
  git -C "$CASE_SESSION" push origin topic >/dev/null
  CASE_TOPIC_OID=$(git -C "$CASE_SESSION" rev-parse HEAD)
  git -C "$CASE_INTEGRATOR" fetch origin topic >/dev/null
  git -C "$CASE_INTEGRATOR" merge --no-ff origin/topic -m "merge deinitialized submodule" >/dev/null
  git -C "$CASE_INTEGRATOR" push origin master >/dev/null
  git_config "$CASE_SESSION/nested"
  echo unique >>"$CASE_SESSION/nested/payload"
  git -C "$CASE_SESSION/nested" add payload
  git -C "$CASE_SESSION/nested" commit -m "unique deinitialized submodule commit" >/dev/null
  unique_submodule_oid=$(git -C "$CASE_SESSION/nested" rev-parse HEAD)
  session_git_dir=$(git -C "$CASE_SESSION" rev-parse --absolute-git-dir)
  git -C "$CASE_SESSION" submodule deinit --force nested >/dev/null
  status=$(git -C "$CASE_SESSION" submodule status nested)
  case "$status" in
  -*) ;;
  *) fail "test did not deinitialize the submodule checkout" ;;
  esac
  [ -z "$(git -C "$CASE_SESSION" status --porcelain --untracked-files=normal --ignored=matching)" ] ||
    fail "deinitialized submodule did not leave the intended clean superproject"
  git --git-dir="$session_git_dir/modules/nested" cat-file -e "$unique_submodule_oid^{commit}" ||
    fail "test residual submodule repository lost its unique commit before cleanup"
  log="$TEST_ROOT/deinitialized-session-submodule.log"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "deinitialized session submodule repository was accepted for cleanup"
  fi
  case "$(cat "$log")" in
  *"session has a residual submodule repository"*) ;;
  *) fail "deinitialized submodule test did not reach the residual-repository refusal" ;;
  esac
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "residual submodule refusal must precede master advancement"
  git --git-dir="$session_git_dir/modules/nested" cat-file -e "$unique_submodule_oid^{commit}" ||
    fail "unique deinitialized submodule commit was lost"
  assert_topic_preserved
  echo "PASS: residual deinitialized submodule repository is refused before mutation"
}

test_initialized_master_submodule_refusal() {
  local local_master next_submodule_oid sub_remote sub_seed
  setup_case initialized-master-submodule merge other
  git -C "$CASE_MASTER_OWNER" fetch origin \
    refs/heads/master:refs/remotes/origin/master >/dev/null
  git -C "$CASE_MASTER_OWNER" merge --ff-only refs/remotes/origin/master >/dev/null
  sub_remote="$CASE_ROOT/master-submodule.git"
  sub_seed="$CASE_ROOT/master-submodule-seed"
  git init --bare "$sub_remote" >/dev/null
  git -C "$sub_remote" symbolic-ref HEAD refs/heads/main
  git init -b main "$sub_seed" >/dev/null
  git_config "$sub_seed"
  echo submodule-base >"$sub_seed/payload"
  git -C "$sub_seed" add payload
  git -C "$sub_seed" commit -m "master submodule base" >/dev/null
  git -C "$sub_seed" remote add origin "$sub_remote"
  git -C "$sub_seed" push -u origin main >/dev/null
  git -c protocol.file.allow=always -C "$CASE_MASTER_OWNER" submodule add \
    "$sub_remote" nested >/dev/null
  git -C "$CASE_MASTER_OWNER" commit -m "add initialized master submodule" >/dev/null
  git -C "$CASE_MASTER_OWNER" push origin master >/dev/null
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  git -C "$CASE_INTEGRATOR" pull --ff-only origin master >/dev/null
  echo next >>"$sub_seed/payload"
  git -C "$sub_seed" add payload
  git -C "$sub_seed" commit -m "advance master submodule" >/dev/null
  git -C "$sub_seed" push origin main >/dev/null
  next_submodule_oid=$(git -C "$sub_seed" rev-parse HEAD)
  git -c protocol.file.allow=always -C "$CASE_INTEGRATOR" submodule update --init nested >/dev/null
  git -C "$CASE_INTEGRATOR/nested" fetch origin >/dev/null
  git -C "$CASE_INTEGRATOR/nested" checkout "$next_submodule_oid" >/dev/null
  git -C "$CASE_INTEGRATOR" add nested
  git -C "$CASE_INTEGRATOR" commit -m "update master submodule gitlink" >/dev/null
  git -C "$CASE_INTEGRATOR" push origin master >/dev/null

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "initialized master-owner submodule was accepted for refresh"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "initialized master-owner submodule refusal must precede master advancement"
  assert_eq "$(git -C "$CASE_MASTER_OWNER/nested" rev-parse HEAD)" \
    "$(git -C "$CASE_MASTER_OWNER" rev-parse HEAD:nested)" \
    "master-owner submodule checkout must remain aligned with its old gitlink"
  assert_topic_preserved
  echo "PASS: initialized master-owner submodule is refused before gitlink advancement"
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

test_private_worktree_ref_refusal() {
  local local_master private_oid
  setup_case private-worktree-ref merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  private_oid=$(printf 'private worktree commit\n' | git -C "$CASE_SESSION" commit-tree \
    "$(git -C "$CASE_SESSION" rev-parse HEAD^{tree})" -p "$CASE_TOPIC_OID")
  git -C "$CASE_SESSION" update-ref refs/worktree/private "$private_oid"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "session-local worktree ref was accepted for cleanup"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "private worktree ref refusal must precede master advancement"
  assert_eq "$(git -C "$CASE_SESSION" rev-parse refs/worktree/private)" "$private_oid" \
    "session-local worktree ref must remain intact"
  git -C "$CASE_SESSION" cat-file -e "$private_oid^{commit}" ||
    fail "commit unique to session-local worktree ref was lost"
  assert_topic_preserved
  echo "PASS: session-local worktree ref is refused before unregistering"
}

test_rewritten_worktree_ref_refusal() {
  local local_master private_oid
  setup_case rewritten-worktree-ref merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  private_oid=$(printf 'rewritten worktree commit\n' | git -C "$CASE_SESSION" commit-tree \
    "$(git -C "$CASE_SESSION" rev-parse HEAD^{tree})" -p "$CASE_TOPIC_OID")
  git -C "$CASE_SESSION" update-ref refs/rewritten/private "$private_oid"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "session-local rewritten ref was accepted for cleanup"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "rewritten worktree ref refusal must precede master advancement"
  assert_eq "$(git -C "$CASE_SESSION" rev-parse refs/rewritten/private)" "$private_oid" \
    "session-local rewritten ref must remain intact"
  assert_topic_preserved
  echo "PASS: session-local rewritten ref is refused before unregistering"
}

test_session_pseudoref_recovery() {
  local unique_oid
  setup_case session-pseudoref-recovery merge main-off
  unique_oid=$(printf 'unique ORIG_HEAD commit\n' | git -C "$CASE_SESSION" commit-tree \
    "$(git -C "$CASE_SESSION" rev-parse HEAD^{tree})" -p "$CASE_TOPIC_OID")
  git -C "$CASE_SESSION" update-ref ORIG_HEAD "$unique_oid"

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" rev-parse \
    "refs/ship-pr/session-recovery/topic/pseudoref-ORIG_HEAD-$unique_oid")" \
    "$unique_oid" "session ORIG_HEAD object must remain directly reachable"
  echo "PASS: session pseudoref objects receive recovery refs before unregistering"
}

test_session_reflog_recovery() {
  local orig_head reflog_path unique_oid
  setup_case session-reflog-recovery merge main-off
  git -C "$CASE_SESSION" checkout --detach >/dev/null
  git -C "$CASE_SESSION" commit --allow-empty -m "unique detached reflog commit" >/dev/null
  unique_oid=$(git -C "$CASE_SESSION" rev-parse HEAD)
  git -C "$CASE_SESSION" reset --hard "$CASE_TOPIC_OID" >/dev/null
  git -C "$CASE_SESSION" reset --hard "$CASE_TOPIC_OID" >/dev/null
  orig_head=$(git -C "$CASE_SESSION" rev-parse ORIG_HEAD)
  [ "$orig_head" != "$unique_oid" ] || fail "test did not evict the unique commit from ORIG_HEAD"
  reflog_path=$(git_log_path "$CASE_SESSION" HEAD)
  printf '%s %s Cleanup\ Test cleanup-test@example.invalid 0 +0000\told-side-only\n' \
    "$unique_oid" "$CASE_TOPIC_OID" >"$reflog_path"

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" rev-parse \
    "refs/ship-pr/session-recovery/topic/reflog-HEAD-$unique_oid")" \
    "$unique_oid" "session HEAD reflog object must remain directly reachable"
  echo "PASS: session HEAD reflog objects receive recovery refs before unregistering"
}

test_session_index_recovery() {
  local blob_oid fake_bin index_ref index_tree real_git retained_blob
  setup_case session-index-recovery merge main-off
  fake_bin="$TEST_ROOT/session-index-recovery-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$2" in' \
    '*.ship-pr-recovery.*/worktree)' \
    '  if [ "$3" = rev-parse ] && [ "$4" = --git-path ] && [ "$5" = ORIG_HEAD ] && [ ! -e "$INDEX_MARKER" ]; then' \
    '    blob=$(printf "staged-only bytes\n" | "$REAL_GIT" -C "$RACE_MAIN" hash-object -w --stdin)' \
    '    "$REAL_GIT" -C "$2" update-index --add --cacheinfo 100644 "$blob" staged-only' \
    '    printf "%s\n" "$blob" >"$INDEX_MARKER"' \
    '  fi' \
    '  ;;' \
    'esac' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    INDEX_MARKER="$TEST_ROOT/session-index-recovery.blob" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  blob_oid=$(cat "$TEST_ROOT/session-index-recovery.blob")
  index_ref=$(git -C "$CASE_MAIN" for-each-ref --format='%(refname)' \
    refs/ship-pr/session-recovery/topic | sed -n '/\/index-tree-/ {p;q;}')
  [ -n "$index_ref" ] || fail "archived session index tree received no recovery ref"
  index_tree=$(git -C "$CASE_MAIN" rev-parse "$index_ref")
  retained_blob=$(git -C "$CASE_MAIN" ls-tree "$index_tree" -- staged-only | awk '{print $3}')
  assert_eq "$retained_blob" "$blob_oid" "staged-only blob must remain reachable from index tree"
  assert_cleaned
  echo "PASS: final session index tree receives a recovery ref before unregistering"
}

test_session_split_index_recovery() {
  local file index_snapshot shared_basename shared_count shared_index
  setup_case session-split-index-recovery merge main-off
  git -C "$CASE_SESSION" update-index --split-index
  shared_index=$(git -C "$CASE_SESSION" rev-parse --shared-index-path)
  [ -n "$shared_index" ] || fail "test did not create a shared index"
  case "$shared_index" in
  /*) ;;
  *) shared_index="$CASE_SESSION/$shared_index" ;;
  esac
  [ -f "$shared_index" ] || fail "test shared index is missing"
  shared_basename=$(basename "$shared_index")

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  [ -f "$CASE_ARCHIVE/$shared_basename" ] ||
    fail "session archive did not retain the split-index base"
  shared_count=0
  for file in "$CASE_ARCHIVE"/sharedindex.*; do
    [ -f "$file" ] || continue
    shared_count=$((shared_count + 1))
  done
  assert_eq "$shared_count" 1 "session archive must retain exactly one split-index base"
  index_snapshot=""
  for file in "$CASE_ARCHIVE"/index.snapshot.*; do
    [ -f "$file" ] || continue
    [ -z "$index_snapshot" ] || fail "session archive retained multiple index snapshots"
    index_snapshot="$file"
  done
  [ -n "$index_snapshot" ] || fail "session archive retained no index snapshot"
  GIT_INDEX_FILE="$index_snapshot" git -C "$CASE_MAIN" ls-files --error-unmatch value >/dev/null ||
    fail "archived split index cannot be read with its retained base"
  echo "PASS: split-index snapshots retain their shared base beside the archived index"
}

test_session_resolve_undo_recovery() {
  local fake_bin first_blob real_git second_blob
  setup_case session-resolve-undo-recovery merge main-off
  fake_bin="$TEST_ROOT/session-resolve-undo-recovery-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$2" in' \
    '*.ship-pr-recovery.*/worktree)' \
    '  if [ "$3" = rev-parse ] && [ "$4" = --git-path ] && [ "$5" = ORIG_HEAD ] && [ ! -e "$REUC_MARKER" ]; then' \
    '    head_blob=$("$REAL_GIT" -C "$2" rev-parse HEAD:value)' \
    '    first=$(printf "resolve-undo first\n" | "$REAL_GIT" -C "$RACE_MAIN" hash-object -w --stdin)' \
    '    second=$(printf "resolve-undo second\n" | "$REAL_GIT" -C "$RACE_MAIN" hash-object -w --stdin)' \
    '    printf "0 0000000000000000000000000000000000000000\tvalue\0" >"$INDEX_INFO"' \
    '    printf "100644 %s 1\tvalue\0" "$head_blob" >>"$INDEX_INFO"' \
    '    printf "100644 %s 2\tvalue\0" "$first" >>"$INDEX_INFO"' \
    '    printf "100644 %s 3\tvalue\0" "$second" >>"$INDEX_INFO"' \
    '    "$REAL_GIT" -C "$2" update-index -z --index-info <"$INDEX_INFO"' \
    '    "$REAL_GIT" -C "$2" update-index --add --cacheinfo 100644 "$head_blob" value' \
    '    printf "%s\n%s\n" "$first" "$second" >"$REUC_MARKER"' \
    '  fi' \
    '  ;;' \
    'esac' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    REUC_MARKER="$TEST_ROOT/session-resolve-undo-recovery.oids" \
    INDEX_INFO="$TEST_ROOT/session-resolve-undo-recovery.index-info" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  first_blob=$(sed -n '1p' "$TEST_ROOT/session-resolve-undo-recovery.oids")
  second_blob=$(sed -n '2p' "$TEST_ROOT/session-resolve-undo-recovery.oids")
  assert_eq "$(git -C "$CASE_MAIN" rev-parse \
    "refs/ship-pr/session-recovery/topic/index-reuc-$first_blob")" "$first_blob" \
    "first resolve-undo blob must remain directly reachable"
  assert_eq "$(git -C "$CASE_MAIN" rev-parse \
    "refs/ship-pr/session-recovery/topic/index-reuc-$second_blob")" "$second_blob" \
    "second resolve-undo blob must remain directly reachable"
  assert_cleaned
  echo "PASS: session resolve-undo blobs receive recovery refs before unregistering"
}

test_worktree_config_archive() {
  local config_count config_snapshot file
  setup_case worktree-config-archive merge main-off
  git -C "$CASE_MAIN" config extensions.worktreeConfig true
  git -C "$CASE_SESSION" config --worktree cleanup.secret retain-me

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  config_count=0
  config_snapshot=""
  for file in "$CASE_ARCHIVE"/config.worktree.*; do
    [ -f "$file" ] || continue
    config_count=$((config_count + 1))
    config_snapshot="$file"
  done
  assert_eq "$config_count" 1 "cleanup must archive exactly one per-worktree config snapshot"
  assert_eq "$(git config --file "$config_snapshot" --get cleanup.secret)" retain-me \
    "per-worktree configuration must survive unregistering"
  echo "PASS: per-worktree configuration is copied into the recovery archive"
}

test_session_metadata_lock_preflight() {
  local local_master lock_path
  setup_case session-metadata-lock-preflight merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  lock_path="$(git -C "$CASE_SESSION" rev-parse --git-path ORIG_HEAD).lock"
  printf 'another Git operation\n' >"$lock_path"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "pre-existing session pseudoref lock was discovered only after mutation"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "session pseudoref lock refusal must precede master advancement"
  assert_eq "$(sed -n '1p' "$lock_path")" "another Git operation" \
    "session pseudoref lock must be preserved"
  assert_topic_preserved
  echo "PASS: session pseudoref locks are preflighted before mutation"
}

test_late_private_worktree_ref_recovery() {
  local fake_bin private_oid real_git
  setup_case late-private-worktree-ref merge main-off
  private_oid=$(printf 'late private worktree commit\n' | git -C "$CASE_MAIN" commit-tree \
    "$(git -C "$CASE_MAIN" rev-parse "$CASE_TOPIC_OID^{tree}")" -p "$CASE_TOPIC_OID")
  fake_bin="$TEST_ROOT/late-private-worktree-ref-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$2" in' \
    '*.ship-pr-recovery.*/worktree)' \
    '  if [ "$3" = for-each-ref ] && [ ! -e "$PRIVATE_MARKER" ]; then' \
    '    : >"$PRIVATE_MARKER"' \
    '    "$REAL_GIT" -C "$2" update-ref refs/worktree/late "$PRIVATE_OID"' \
    '  fi' \
    '  ;;' \
    'esac' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" PRIVATE_OID="$private_oid" \
    PRIVATE_MARKER="$TEST_ROOT/late-private-worktree-ref.injected" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_eq "$(git -C "$CASE_MAIN" rev-parse \
    "refs/ship-pr/session-recovery/topic/private-ref-$private_oid")" "$private_oid" \
    "late session-private ref object must remain directly reachable"
  assert_cleaned
  echo "PASS: late session-private refs receive recovery refs before unregistering"
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

  setup_case symbolic-tracking-master merge main-off
  git -C "$CASE_MAIN" fetch origin refs/heads/master:refs/remotes/origin/master >/dev/null
  tracked_master=$(git -C "$CASE_MAIN" rev-parse refs/remotes/origin/master)
  git -C "$CASE_MAIN" update-ref refs/remotes/origin/master-target "$tracked_master"
  git -C "$CASE_MAIN" update-ref -d refs/remotes/origin/master
  git -C "$CASE_MAIN" symbolic-ref refs/remotes/origin/master refs/remotes/origin/master-target
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "symbolic origin/master was accepted before explicit fetch"
  fi
  assert_eq "$(git -C "$CASE_MAIN" symbolic-ref refs/remotes/origin/master)" \
    refs/remotes/origin/master-target "symbolic origin/master must remain intact"
  assert_topic_preserved
  echo "PASS: symbolic local and tracking refs are refused"
}

test_remote_master_lease() {
  local real_git remote_base hook log
  setup_case remote-master-lease merge main-off
  remote_base=$(git -C "$CASE_INTEGRATOR" rev-list --max-parents=0 HEAD)
  real_git=$(command -v git)
  hook="$CASE_MAIN/.git/hooks/pre-push"
  log="$TEST_ROOT/remote-master-lease.log"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '"$REAL_GIT" -C "$RACE_INTEGRATOR" push --force origin "$RACE_BASE:refs/heads/master" >/dev/null' \
    'exit 0' >"$hook"
  chmod +x "$hook"

  if REAL_GIT="$real_git" RACE_INTEGRATOR="$CASE_INTEGRATOR" \
    RACE_BASE="$remote_base" "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "topic deletion ignored a concurrent remote master rewrite"
  fi
  assert_topic_preserved
  assert_eq "$(git -C "$CASE_MAIN" ls-remote origin refs/heads/master | awk '{print $1}')" \
    "$remote_base" "remote master rewrite must remain visible after atomic refusal"
  echo "PASS: post-advertisement master rewrite restores the topic"
}

test_stale_master_response_retains_recovery() {
  local fake_bin real_git remote_base log
  setup_case stale-master-response merge main-off
  fake_bin="$TEST_ROOT/stale-master-response-bin"
  real_git=$(command -v git)
  remote_base=$(git -C "$CASE_INTEGRATOR" rev-list --max-parents=0 HEAD)
  log="$TEST_ROOT/stale-master-response.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'is_ls_remote=0' \
    'is_master=0' \
    'for arg in "$@"; do' \
    '  [ "$arg" = ls-remote ] && is_ls_remote=1' \
    '  [ "$arg" = refs/heads/master ] && is_master=1' \
    'done' \
    'if [ "$is_ls_remote" -eq 1 ] && [ "$is_master" -eq 1 ]; then' \
    '  output=$("$REAL_GIT" "$@")' \
    '  status=$?' \
    '  "$REAL_GIT" -C "$RACE_INTEGRATOR" push --force origin "$RACE_BASE:refs/heads/master" >/dev/null' \
    '  printf "%s\\n" "$output"' \
    '  exit "$status"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_INTEGRATOR="$CASE_INTEGRATOR" \
    RACE_BASE="$remote_base" "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" ls-remote origin refs/heads/master | awk '{print $1}')" \
    "$remote_base" "test must roll remote master back after returning its stale integrated OID"
  echo "PASS: retained recovery survives stale final master evidence"
}

test_symbolic_recovery_ref_refusal() {
  local recovery_ref
  setup_case symbolic-recovery-ref merge main-off
  recovery_ref="refs/ship-pr/recovery/topic/$CASE_TOPIC_OID"
  git -C "$CASE_MAIN" symbolic-ref "$recovery_ref" refs/heads/topic

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "symbolic recovery ref was accepted as durable topic retention"
  fi
  assert_eq "$(git -C "$CASE_MAIN" symbolic-ref "$recovery_ref")" refs/heads/topic \
    "refused symbolic recovery ref must remain intact"
  assert_topic_preserved
  echo "PASS: symbolic recovery ref is refused before topic deletion"
}

test_topic_reservation() {
  local fake_bin real_git candidate checkout_status
  setup_case topic-reservation merge main-off
  candidate="$CASE_ROOT/topic-candidate"
  git -C "$CASE_MAIN" worktree add --detach "$candidate" refs/heads/topic >/dev/null
  fake_bin="$TEST_ROOT/topic-reservation-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = rev-parse ] && [ "$4" = --git-path ] && [ "$5" = logs/refs/heads/topic ]; then' \
    '  count=0' \
    '  [ ! -f "$COUNT_MARKER" ] || count=$(cat "$COUNT_MARKER")' \
    '  count=$((count + 1))' \
    '  printf "%s\n" "$count" >"$COUNT_MARKER"' \
    '  if [ "$count" -eq 2 ]; then' \
    '    if "$REAL_GIT" -C "$TOPIC_CANDIDATE" checkout topic >/dev/null 2>&1; then status=0; else status=$?; fi' \
    '    printf "%s\n" "$status" >"$CHECKOUT_MARKER"' \
    '  fi' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" TOPIC_CANDIDATE="$candidate" \
    COUNT_MARKER="$TEST_ROOT/topic-reservation.count" \
    CHECKOUT_MARKER="$TEST_ROOT/topic-reservation.status" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  [ -f "$TEST_ROOT/topic-reservation.status" ] ||
    fail "topic reservation injection did not run (reflog reads: $(cat "$TEST_ROOT/topic-reservation.count" 2>/dev/null || echo none))"
  checkout_status=$(cat "$TEST_ROOT/topic-reservation.status")
  [ "$checkout_status" -ne 0 ] || fail "another worktree acquired topic during local deletion"
  assert_cleaned
  ! git -C "$candidate" symbolic-ref -q HEAD >/dev/null 2>&1 ||
    fail "topic candidate worktree stopped being detached"
  echo "PASS: topic reservation blocks checkout through local deletion"
}

test_topic_reservation_failure_restores_remote() {
  local candidate fake_bin real_git log
  setup_case topic-reservation-failure merge main-off
  candidate="$CASE_ROOT/topic-acquisition-candidate"
  git -C "$CASE_MAIN" worktree add --detach "$candidate" refs/heads/topic >/dev/null
  fake_bin="$TEST_ROOT/topic-reservation-failure-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/topic-reservation-failure.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$2" in' \
    '*ship-pr-topic-reserve*)' \
    '  if [ "$3" = switch ] && [ "$5" = topic ]; then' \
    '    "$REAL_GIT" -C "$TOPIC_CANDIDATE" checkout topic >/dev/null 2>&1' \
    '  fi' \
    '  ;;' \
    'esac' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" TOPIC_CANDIDATE="$candidate" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    fail "topic reservation unexpectedly succeeded after competing acquisition"
  fi
  git -C "$CASE_MAIN" show-ref --verify --quiet refs/heads/topic || fail "local topic was lost"
  git -C "$CASE_MAIN" ls-remote --exit-code --heads origin refs/heads/topic >/dev/null 2>&1 ||
    fail "remote topic was not restored after reservation failure"
  [ -d "$CASE_SESSION" ] || fail "original session path was removed after reservation failure"
  echo "PASS: topic reservation failure restores the remote recovery branch"
}

test_ignored_write_at_session_removal() {
  local archive fake_bin late_archive real_git log
  setup_case ignored-write-at-removal merge main-off
  echo local.log >>"$CASE_MAIN/.git/info/exclude"
  fake_bin="$TEST_ROOT/ignored-write-at-removal-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/ignored-write-at-removal.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = worktree ] && [ "$4" = remove ]; then' \
    '  case "$5" in' \
    '  */session)' \
    '    if [ ! -e "$RACE_MARKER" ]; then' \
    '      : >"$RACE_MARKER"' \
    '      mkdir -p "$RACE_SESSION"' \
    '      echo irreplaceable >"$RACE_SESSION/local.log"' \
    '    fi' \
    '    ;;' \
    '  esac' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if ! PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_SESSION="$CASE_SESSION" \
    RACE_MARKER="$TEST_ROOT/ignored-write-at-removal.injected" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1; then
    sed -n '1,120p' "$log" >&2
    fail "cleanup could not archive a late write at the former session path"
  fi
  late_archive=""
  for archive in "$CASE_ROOT"/.session.ship-pr-late-data.*; do
    [ -d "$archive" ] || continue
    [ -z "$late_archive" ] || fail "more than one late-data archive was created"
    late_archive="$archive"
  done
  [ -n "$late_archive" ] || fail "late ignored data did not receive a recovery archive"
  assert_eq "$(sed -n '1p' "$late_archive/data/local.log")" irreplaceable \
    "ignored data created at worktree removal must never be deleted"
  assert_absent "$CASE_SESSION"
  assert_ref_absent refs/heads/topic
  assert_remote_topic_absent
  assert_eq "$(git -C "$CASE_MAIN" rev-parse "refs/ship-pr/recovery/topic/$CASE_TOPIC_OID")" \
    "$CASE_TOPIC_OID" "late ignored write must leave the topic recovery reachable"
  grep -F "data appearing at the former session path was archived" "$log" >/dev/null ||
    fail "late data at the former session path was not reported"
  echo "PASS: atomic session archival cannot erase a late ignored write"
}

test_dangling_link_at_session_removal() {
  local archive fake_bin late_archive real_git log
  setup_case dangling-link-at-removal merge main-off
  fake_bin="$TEST_ROOT/dangling-link-at-removal-bin"
  real_git=$(command -v git)
  log="$TEST_ROOT/dangling-link-at-removal.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = worktree ] && [ "$4" = remove ]; then' \
    '  case "$5" in' \
    '  */session)' \
    '    if [ ! -e "$RACE_MARKER" ]; then' \
    '      : >"$RACE_MARKER"' \
    '      ln -s missing-target "$RACE_SESSION"' \
    '    fi' \
    '    ;;' \
    '  esac' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_SESSION="$CASE_SESSION" \
    RACE_MARKER="$TEST_ROOT/dangling-link-at-removal.injected" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >"$log" 2>&1
  late_archive=""
  for archive in "$CASE_ROOT"/.session.ship-pr-late-data.*; do
    [ -L "$archive/data" ] || continue
    [ -z "$late_archive" ] || fail "more than one dangling-link archive was created"
    late_archive="$archive"
  done
  [ -n "$late_archive" ] || fail "dangling link did not receive a recovery archive"
  assert_eq "$(readlink "$late_archive/data")" missing-target \
    "archived dangling link must retain its target text"
  assert_cleaned
  echo "PASS: dangling link at vacated session path is archived"
}

test_detached_session_head_recovery() {
  local fake_bin final_head real_git
  setup_case detached-session-head-recovery merge main-off
  fake_bin="$TEST_ROOT/detached-session-head-recovery-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$2" in' \
    '*.ship-pr-recovery.*/worktree)' \
    '  if [ "$3" = rev-parse ] && [ "$4" = --git-path ] && [ "$5" = HEAD ] && [ ! -e "$HEAD_MARKER" ]; then' \
    '    "$REAL_GIT" -C "$2" commit --allow-empty -m "late detached session commit" >/dev/null' \
    '    "$REAL_GIT" -C "$2" rev-parse HEAD >"$HEAD_MARKER"' \
    '  fi' \
    '  ;;' \
    'esac' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" \
    HEAD_MARKER="$TEST_ROOT/detached-session-head-recovery.oid" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  final_head=$(cat "$TEST_ROOT/detached-session-head-recovery.oid")
  assert_eq "$(git -C "$CASE_MAIN" rev-parse \
    "refs/ship-pr/session-recovery/topic/$final_head")" "$final_head" \
    "late detached session HEAD must remain reachable after unregistering"
  assert_cleaned
  echo "PASS: final detached session HEAD receives a direct recovery ref"
}

test_session_head_locked_through_unregister() {
  local archive commit_status fake_bin real_git
  setup_case session-head-lock merge main-off
  fake_bin="$TEST_ROOT/session-head-lock-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = worktree ] && [ "$4" = remove ]; then' \
    '  case "$*" in' \
    '  */session*)' \
    '    for archive in "$RACE_ROOT"/.session.ship-pr-recovery.*/worktree; do' \
    '      [ -d "$archive" ] || continue' \
    '      "$REAL_GIT" -C "$archive" commit --allow-empty -m "too-late detached commit" >/dev/null 2>&1' \
    '      echo "$?" >"$COMMIT_MARKER"' \
    '    done' \
    '    ;;' \
    '  esac' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_ROOT="$CASE_ROOT" \
    COMMIT_MARKER="$TEST_ROOT/session-head-lock.status" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  commit_status=$(cat "$TEST_ROOT/session-head-lock.status")
  [ "$commit_status" -ne 0 ] || fail "archived session HEAD advanced after its final recovery read"
  assert_cleaned
  archive="$CASE_ARCHIVE/worktree"
  [ -f "$archive/value" ] || fail "locked session archive lost its worktree files"
  echo "PASS: archived session HEAD is locked through unregistering"
}

test_archive_preflight_refusal() {
  local fake_bin local_master real_mktemp
  setup_case archive-preflight-refusal merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  fake_bin="$TEST_ROOT/archive-preflight-bin"
  real_mktemp=$(command -v mktemp)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'case "$*" in' \
    '*.session.ship-pr-recovery.*) exit 1 ;;' \
    'esac' \
    'exec "$REAL_MKTEMP" "$@"' >"$fake_bin/mktemp"
  chmod +x "$fake_bin/mktemp"

  if PATH="$fake_bin:$PATH" REAL_MKTEMP="$real_mktemp" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "unavailable session archive was discovered only after destructive cleanup"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "archive preflight failure must precede the local master update"
  assert_topic_preserved
  echo "PASS: session archive availability is preflighted before mutation"
}

test_precreated_archive_target_refusal() {
  local attacked_target fake_bin real_perl
  setup_case precreated-archive-target merge main-off
  fake_bin="$TEST_ROOT/precreated-archive-target-bin"
  real_perl=$(command -v perl)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'target=""' \
    'for arg in "$@"; do target=$arg; done' \
    'case "$target" in' \
    '*.session.ship-pr-recovery.*/worktree)' \
    '  if [ ! -e "$TARGET_MARKER" ]; then' \
    '    mkdir -p "$target"' \
    '    echo attacker >"$target/blocker"' \
    '    printf "%s\n" "$target" >"$TARGET_MARKER"' \
    '  fi' \
    '  ;;' \
    'esac' \
    'exec "$REAL_PERL" "$@"' >"$fake_bin/perl"
  chmod +x "$fake_bin/perl"

  if PATH="$fake_bin:$PATH" REAL_PERL="$real_perl" \
    TARGET_MARKER="$TEST_ROOT/precreated-archive-target.path" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "session archive nested into a precreated target"
  fi
  attacked_target=$(cat "$TEST_ROOT/precreated-archive-target.path")
  [ -f "$attacked_target/blocker" ] || fail "precreated archive target was overwritten"
  [ -d "$CASE_SESSION" ] || fail "failed atomic archive moved the original session"
  [ ! -e "$attacked_target/session" ] || fail "session was nested below the precreated target"
  git -C "$CASE_MAIN" show-ref --verify --quiet refs/heads/topic ||
    fail "local topic was lost after atomic archive refusal"

  rm -rf "$attacked_target"
  rmdir "$(dirname "$attacked_target")"
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  echo "PASS: atomic archive refuses a precreated nonempty target without nesting"
}

test_session_head_lock_preflight() {
  local head_path local_master lock_contents
  setup_case session-head-lock-preflight merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  head_path=$(git -C "$CASE_SESSION" rev-parse --git-path HEAD)
  lock_contents="owned by another Git process"
  printf '%s\n' "$lock_contents" >"$head_path.lock"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "pre-existing session HEAD lock was discovered only after mutation"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "session HEAD lock refusal must precede master advancement"
  assert_eq "$(cat "$head_path.lock")" "$lock_contents" \
    "session HEAD lock refusal must preserve the caller's lock"
  assert_topic_preserved
  echo "PASS: session HEAD lock is preflighted before mutation"
}

test_dangling_session_head_lock_preflight() {
  local head_path local_master
  setup_case dangling-session-head-lock-preflight merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  head_path=$(git -C "$CASE_SESSION" rev-parse --git-path HEAD)
  ln -s missing-lock-owner "$head_path.lock"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "dangling session HEAD lock symlink was discovered only after mutation"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "dangling session HEAD lock refusal must precede master advancement"
  [ -L "$head_path.lock" ] || fail "dangling session HEAD lock symlink was removed"
  assert_eq "$(readlink "$head_path.lock")" missing-lock-owner \
    "dangling session HEAD lock target must be preserved"
  assert_topic_preserved
  echo "PASS: dangling session HEAD lock is preflighted before mutation"
}

test_session_recovery_namespace_preflight() {
  local local_master
  setup_case session-recovery-namespace-preflight merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  git -C "$CASE_MAIN" update-ref refs/ship-pr/session-recovery/topic "$CASE_TOPIC_OID"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "conflicting session recovery namespace was discovered only after mutation"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "session recovery namespace refusal must precede master advancement"
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/ship-pr/session-recovery/topic)" \
    "$CASE_TOPIC_OID" "conflicting session recovery prefix ref must be preserved"
  assert_topic_preserved
  echo "PASS: session recovery ref namespace is reserved before mutation"
}

test_dangling_config_lock_preflight() {
  local local_master lock_path
  setup_case dangling-config-lock-preflight merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  lock_path="$CASE_MAIN/.git/config.lock"
  ln -s missing-config-writer "$lock_path"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "dangling config lock symlink was discovered only after mutation"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "dangling config lock refusal must precede master advancement"
  [ -L "$lock_path" ] || fail "dangling config lock symlink was removed"
  assert_eq "$(readlink "$lock_path")" missing-config-writer \
    "dangling config lock target must be preserved"
  assert_topic_preserved
  echo "PASS: dangling repository config lock is preflighted before mutation"
}

test_divergent_tracking_tip_recovery() {
  local tracking_oid
  setup_case divergent-tracking-tip merge main-off
  tracking_oid=$(printf 'tracking-only commit\n' | git -C "$CASE_MAIN" commit-tree \
    "$(git -C "$CASE_MAIN" rev-parse "$CASE_TOPIC_OID^{tree}")" -p "$CASE_TOPIC_OID")
  git -C "$CASE_MAIN" update-ref refs/remotes/origin/topic "$tracking_oid"

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" rev-parse \
    "refs/ship-pr/tracking-recovery/topic/$tracking_oid")" "$tracking_oid" \
    "divergent remote-tracking tip must remain directly reachable"
  echo "PASS: divergent remote-tracking tip receives a recovery ref before pruning"
}

test_tracking_tip_move_refusal() {
  local fake_bin race_oid real_git
  setup_case tracking-tip-move merge main-off
  race_oid=$(printf 'late tracking commit\n' | git -C "$CASE_MAIN" commit-tree \
    "$(git -C "$CASE_MAIN" rev-parse "$CASE_TOPIC_OID^{tree}")" -p "$CASE_TOPIC_OID")
  fake_bin="$TEST_ROOT/tracking-tip-move-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = show-ref ] && [ "$6" = refs/remotes/origin/topic ]; then' \
    '  count=0' \
    '  [ ! -e "$COUNT_MARKER" ] || count=$(cat "$COUNT_MARKER")' \
    '  count=$((count + 1))' \
    '  echo "$count" >"$COUNT_MARKER"' \
    '  if [ "$count" -eq 2 ]; then' \
    '    "$REAL_GIT" -C "$RACE_MAIN" update-ref refs/remotes/origin/topic "$RACE_OID"' \
    '  fi' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    RACE_OID="$race_oid" COUNT_MARKER="$TEST_ROOT/tracking-tip-move.count" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "cleanup deleted a remote-tracking ref that moved after its recovery snapshot"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/remotes/origin/topic)" "$race_oid" \
    "late remote-tracking tip must be preserved"
  git -C "$CASE_MAIN" cat-file -e "$race_oid^{commit}" ||
    fail "commit unique to late remote-tracking tip was lost"
  git -C "$CASE_MAIN" show-ref --verify --quiet refs/heads/topic ||
    fail "local topic was lost after remote-tracking move refusal"
  [ -d "$CASE_SESSION" ] || fail "session was lost after remote-tracking move refusal"
  echo "PASS: remote-tracking ref movement is refused without deleting its new tip"
}

test_tracking_reflog_recovery() {
  local reflog_oid
  setup_case tracking-reflog-recovery merge main-off
  reflog_oid=$(printf 'tracking reflog only\n' | git -C "$CASE_MAIN" commit-tree \
    "$(git -C "$CASE_MAIN" rev-parse "$CASE_TOPIC_OID^{tree}")" -p "$CASE_TOPIC_OID")
  git -C "$CASE_MAIN" update-ref refs/remotes/origin/topic "$reflog_oid"
  git -C "$CASE_MAIN" update-ref refs/remotes/origin/topic "$CASE_TOPIC_OID"
  keep_last_reflog_entry "$CASE_MAIN" refs/remotes/origin/topic

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" rev-parse \
    "refs/ship-pr/recovery/topic/tracking-reflog-$reflog_oid")" "$reflog_oid" \
    "remote-tracking reflog object must remain directly reachable"
  echo "PASS: remote-tracking reflog objects receive recovery refs before pruning"
}

test_tracking_reflog_locked_through_deletion() {
  local attempted_oid fake_bin real_git status
  setup_case tracking-reflog-delete-lock merge main-off
  attempted_oid=$(printf 'competing tracking ABA update\n' | git -C "$CASE_MAIN" commit-tree \
    "$(git -C "$CASE_MAIN" rev-parse "$CASE_TOPIC_OID^{tree}")" -p "$CASE_TOPIC_OID")
  fake_bin="$TEST_ROOT/tracking-reflog-delete-lock-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = rev-parse ] && [ "$4" = --git-path ] && [ "$5" = logs/refs/remotes/origin/topic ]; then' \
    '  count=0' \
    '  [ ! -f "$COUNT_MARKER" ] || count=$(cat "$COUNT_MARKER")' \
    '  count=$((count + 1))' \
    '  printf "%s\n" "$count" >"$COUNT_MARKER"' \
    '  if [ "$count" -eq 2 ]; then' \
    '    if "$REAL_GIT" -C "$RACE_MAIN" update-ref refs/remotes/origin/topic "$RACE_OID" "$TOPIC_OID" >/dev/null 2>&1; then status=0; else status=$?; fi' \
    '    printf "%s\n" "$status" >"$STATUS_MARKER"' \
    '  fi' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    RACE_OID="$attempted_oid" TOPIC_OID="$CASE_TOPIC_OID" \
    COUNT_MARKER="$TEST_ROOT/tracking-reflog-delete-lock.count" \
    STATUS_MARKER="$TEST_ROOT/tracking-reflog-delete-lock.status" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  [ -f "$TEST_ROOT/tracking-reflog-delete-lock.status" ] ||
    fail "test never attempted a tracking update during the locked reflog read"
  status=$(cat "$TEST_ROOT/tracking-reflog-delete-lock.status")
  [ "$status" -ne 0 ] || fail "competing tracking update succeeded during reflog retention"
  assert_cleaned
  echo "PASS: tracking ref and reflog stay locked together through deletion"
}

test_topic_reflog_recovery() {
  local reflog_oid
  setup_case topic-reflog-recovery merge main-off
  reflog_oid=$(printf 'topic reflog only\n' | git -C "$CASE_MAIN" commit-tree \
    "$(git -C "$CASE_MAIN" rev-parse "$CASE_TOPIC_OID^{tree}")" -p "$CASE_TOPIC_OID")
  git -C "$CASE_MAIN" update-ref refs/heads/topic "$reflog_oid" "$CASE_TOPIC_OID"
  git -C "$CASE_MAIN" update-ref refs/heads/topic "$CASE_TOPIC_OID" "$reflog_oid"
  keep_last_reflog_entry "$CASE_MAIN" refs/heads/topic

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" rev-parse \
    "refs/ship-pr/recovery/topic/topic-reflog-$reflog_oid")" "$reflog_oid" \
    "local topic reflog object must remain directly reachable"
  echo "PASS: local topic reflog objects receive recovery refs before branch deletion"
}

test_topic_reflog_locked_through_deletion() {
  local attempted_oid fake_bin real_git status
  setup_case topic-reflog-delete-lock merge main-off
  attempted_oid=$(printf 'competing topic ABA update\n' | git -C "$CASE_MAIN" commit-tree \
    "$(git -C "$CASE_MAIN" rev-parse "$CASE_TOPIC_OID^{tree}")" -p "$CASE_TOPIC_OID")
  fake_bin="$TEST_ROOT/topic-reflog-delete-lock-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = rev-parse ] && [ "$4" = --git-path ] && [ "$5" = logs/refs/heads/topic ]; then' \
    '  count=0' \
    '  [ ! -f "$COUNT_MARKER" ] || count=$(cat "$COUNT_MARKER")' \
    '  count=$((count + 1))' \
    '  printf "%s\n" "$count" >"$COUNT_MARKER"' \
    '  if [ "$count" -eq 2 ]; then' \
    '    if "$REAL_GIT" -C "$RACE_MAIN" update-ref refs/heads/topic "$RACE_OID" "$TOPIC_OID" >/dev/null 2>&1; then status=0; else status=$?; fi' \
    '    printf "%s\n" "$status" >"$STATUS_MARKER"' \
    '  fi' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    RACE_OID="$attempted_oid" TOPIC_OID="$CASE_TOPIC_OID" \
    COUNT_MARKER="$TEST_ROOT/topic-reflog-delete-lock.count" \
    STATUS_MARKER="$TEST_ROOT/topic-reflog-delete-lock.status" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  [ -f "$TEST_ROOT/topic-reflog-delete-lock.status" ] ||
    fail "test never attempted a topic update during the locked reflog read"
  status=$(cat "$TEST_ROOT/topic-reflog-delete-lock.status")
  [ "$status" -ne 0 ] || fail "competing topic update succeeded during the reflog retention window"
  assert_cleaned
  echo "PASS: topic ref and reflog stay locked together through final deletion"
}

test_symref_capability_preflight() {
  local fake_bin local_master real_git
  setup_case symref-capability-preflight merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  fake_bin="$TEST_ROOT/symref-capability-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = update-ref ] && [ "$4" = --stdin ]; then' \
    '  exit 1' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "missing symref transaction capability was discovered only after mutation"
  fi
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "symref capability refusal must precede master advancement"
  [ -z "$(git -C "$CASE_MAIN" for-each-ref --format='%(refname)' \
    refs/ship-pr/capability-probe-)" ] || fail "failed capability probe ref was left behind"
  assert_topic_preserved
  echo "PASS: symref transaction support is preflighted before mutation"
}

test_dangling_capability_ref_refusal() {
  local capability_ref fake_bin local_master real_git
  setup_case dangling-capability-ref merge main-off
  local_master=$(git -C "$CASE_MAIN" rev-parse refs/heads/master)
  fake_bin="$TEST_ROOT/dangling-capability-ref-bin"
  real_git=$(command -v git)
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "$3" = show-ref ] && [ "$4" = --exists ]; then' \
    '  "$REAL_GIT" -C "$RACE_MAIN" symbolic-ref "$5" refs/heads/missing-capability-target' \
    '  printf "%s\n" "$5" >"$CAPABILITY_MARKER"' \
    'fi' \
    'exec "$REAL_GIT" "$@"' >"$fake_bin/git"
  chmod +x "$fake_bin/git"

  if PATH="$fake_bin:$PATH" REAL_GIT="$real_git" RACE_MAIN="$CASE_MAIN" \
    CAPABILITY_MARKER="$TEST_ROOT/dangling-capability-ref.path" \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "pre-existing dangling capability ref was overwritten"
  fi
  capability_ref=$(cat "$TEST_ROOT/dangling-capability-ref.path")
  assert_eq "$(git -C "$CASE_MAIN" symbolic-ref "$capability_ref")" \
    refs/heads/missing-capability-target "dangling capability ref must be preserved"
  assert_eq "$(git -C "$CASE_MAIN" rev-parse refs/heads/master)" "$local_master" \
    "dangling capability ref refusal must precede master advancement"
  assert_topic_preserved
  echo "PASS: dangling capability probe ref is detected without dereferencing"
}

test_option_like_branch_name() {
  setup_case option-like-branch merge main-off
  git -C "$CASE_MAIN" update-ref refs/heads/-topic "$CASE_TOPIC_OID" ""
  git -C "$CASE_SESSION" symbolic-ref HEAD refs/heads/-topic
  git -C "$CASE_MAIN" update-ref -d refs/heads/topic "$CASE_TOPIC_OID"
  git -C "$CASE_MAIN" config --rename-section branch.topic branch.-topic
  git -C "$CASE_SESSION" push origin "$CASE_TOPIC_OID:refs/heads/-topic" >/dev/null
  git -C "$CASE_SESSION" push origin :refs/heads/topic >/dev/null
  CASE_BRANCH=-topic

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" "$CASE_BRANCH" >/dev/null
  assert_cleaned
  echo "PASS: option-like topic branch name is handled safely"
}

test_relative_tmpdir() {
  setup_case relative-tmpdir merge main
  mkdir "$CASE_ROOT/relative-tmp"
  (cd "$CASE_ROOT" && TMPDIR=relative-tmp \
    "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null)
  assert_cleaned
  [ ! -e "$CASE_MAIN/relative-tmp" ] ||
    fail "relative TMPDIR was incorrectly resolved beneath the main checkout"
  echo "PASS: relative TMPDIR is canonicalized before temporary worktree use"
}

test_config_lock_refusal() {
  setup_case config-lock merge main-off
  : >"$CASE_MAIN/.git/config.lock"
  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "repository config lock was accepted"
  fi
  assert_topic_preserved
  echo "PASS: config lock is refused before cleanup"
}

test_ignored_master_collision_refusal() {
  local collision
  setup_case ignored-master-collision merge other
  collision="$CASE_MASTER_OWNER/collision"
  echo collision >>"$CASE_MAIN/.git/info/exclude"
  echo local-data >"$collision"
  echo remote-data >"$CASE_INTEGRATOR/collision"
  git -C "$CASE_INTEGRATOR" add collision
  git -C "$CASE_INTEGRATOR" commit -m "track an ignored master-owner path" >/dev/null
  git -C "$CASE_INTEGRATOR" push origin master >/dev/null

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "master refresh overwrote an ignored path collision"
  fi
  assert_eq "$(sed -n '1p' "$collision")" local-data "ignored master-owner data must survive"
  assert_topic_preserved
  echo "PASS: ignored master-owner collision is refused"
}

test_ignored_master_descendant_refusal() {
  local collision tracked_tip
  setup_case ignored-master-descendant merge other
  collision="$CASE_MASTER_OWNER/collision"
  mkdir "$CASE_INTEGRATOR/collision"
  echo tracked >"$CASE_INTEGRATOR/collision/tracked"
  git -C "$CASE_INTEGRATOR" add collision/tracked
  git -C "$CASE_INTEGRATOR" commit -m "add tracked master directory" >/dev/null
  git -C "$CASE_INTEGRATOR" push origin master >/dev/null
  tracked_tip=$(git -C "$CASE_INTEGRATOR" rev-parse HEAD)
  git -C "$CASE_MAIN" fetch origin refs/heads/master:refs/remotes/origin/master >/dev/null
  git -C "$CASE_MASTER_OWNER" reset --hard "$tracked_tip" >/dev/null

  git -C "$CASE_INTEGRATOR" rm collision/tracked >/dev/null
  echo remote-file >"$CASE_INTEGRATOR/collision"
  git -C "$CASE_INTEGRATOR" add collision
  git -C "$CASE_INTEGRATOR" commit -m "replace tracked directory with a file" >/dev/null
  git -C "$CASE_INTEGRATOR" push origin master >/dev/null
  echo collision/local >>"$CASE_MAIN/.git/info/exclude"
  echo local-data >"$collision/local"

  if "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null 2>&1; then
    fail "master refresh replaced a directory containing ignored local data"
  fi
  assert_eq "$(sed -n '1p' "$collision/local")" local-data \
    "ignored descendant under a replaced directory must survive"
  assert_topic_preserved
  echo "PASS: ignored descendant under replaced master directory is refused"
}

test_missing_branch_config() {
  setup_case missing-branch-config merge main-off
  git -C "$CASE_MAIN" config --remove-section branch.topic
  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  echo "PASS: absent branch configuration is a normal cleanup state"
}

test_inherited_branch_config() {
  local included_config
  setup_case inherited-branch-config merge main-off
  included_config="$CASE_ROOT/included-branch-config"
  git -C "$CASE_MAIN" config --remove-section branch.topic
  printf '%s\n' \
    '[branch "topic"]' \
    '  remote = inherited-origin' \
    '  merge = refs/heads/topic' >"$included_config"
  git -C "$CASE_MAIN" config --local include.path "$included_config"

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" config --get branch.topic.remote)" inherited-origin \
    "inherited branch policy must be ignored rather than treated as editable local residue"
  echo "PASS: inherited branch configuration is deliberately left alone"
}

test_dotted_branch_config() {
  setup_case dotted-branch-config merge main-off
  git -C "$CASE_MAIN" config --remove-section branch.topic
  git -C "$CASE_MAIN" config branch.topic.child.remote child-origin
  git -C "$CASE_MAIN" config branch.topic.child.merge refs/heads/topic.child

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" config --local --no-includes \
    --get branch.topic.child.remote)" child-origin \
    "dotted child branch configuration must not be mistaken for topic configuration"
  echo "PASS: dotted child branch configuration remains distinct"
}

test_custom_branch_config() {
  setup_case custom-branch-config merge main-off
  git -C "$CASE_MAIN" config branch.topic.cleanupNote retain-me

  "$HELPER" "$CASE_MAIN" "$CASE_SESSION" topic >/dev/null
  assert_cleaned
  assert_eq "$(git -C "$CASE_MAIN" config --local --no-includes \
    --get branch.topic.cleanupNote)" retain-me \
    "custom repository-local branch configuration must survive upstream cleanup"
  echo "PASS: custom branch configuration is preserved"
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
test_ignored_session_refusal
test_master_reservation
test_unowned_master_reservation
test_concurrent_master_edit_refusal
test_concurrent_ignored_master_collision
test_preexisting_ignored_master_data
test_master_owner_switch_refusal
test_master_update_failure_reattaches_owner
test_master_handoff_stays_reserved
test_master_refresh_preserves_concurrent_ref
test_master_reattach_compare_and_swap
test_master_reattach_verifies_named_branch
test_ignored_data_during_master_detach
test_ignored_data_during_topic_detach
test_ignored_data_during_topic_reattach
test_initialized_session_submodule_refusal
test_deinitialized_session_submodule_refusal
test_initialized_master_submodule_refusal
test_diverged_master_refusal
test_locked_session_refusal
test_private_worktree_ref_refusal
test_rewritten_worktree_ref_refusal
test_session_pseudoref_recovery
test_session_reflog_recovery
test_session_index_recovery
test_session_split_index_recovery
test_session_resolve_undo_recovery
test_worktree_config_archive
test_session_metadata_lock_preflight
test_late_private_worktree_ref_recovery
test_symbolic_ref_refusal
test_remote_master_lease
test_stale_master_response_retains_recovery
test_symbolic_recovery_ref_refusal
test_topic_reservation
test_topic_reservation_failure_restores_remote
test_ignored_write_at_session_removal
test_dangling_link_at_session_removal
test_detached_session_head_recovery
test_session_head_locked_through_unregister
test_archive_preflight_refusal
test_precreated_archive_target_refusal
test_session_head_lock_preflight
test_dangling_session_head_lock_preflight
test_session_recovery_namespace_preflight
test_dangling_config_lock_preflight
test_divergent_tracking_tip_recovery
test_tracking_tip_move_refusal
test_tracking_reflog_recovery
test_tracking_reflog_locked_through_deletion
test_topic_reflog_recovery
test_topic_reflog_locked_through_deletion
test_symref_capability_preflight
test_dangling_capability_ref_refusal
test_option_like_branch_name
test_relative_tmpdir
test_config_lock_refusal
test_ignored_master_collision_refusal
test_ignored_master_descendant_refusal
test_missing_branch_config
test_inherited_branch_config
test_dotted_branch_config
test_custom_branch_config
echo "PASS: all post-merge cleanup states"
