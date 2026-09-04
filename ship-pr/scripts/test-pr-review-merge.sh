#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's `merge`: the binding of the merge to the head the build
# signal was read for, and the refusals of a --require-green (close-out) merge (ludics-lite#39).
# The build signal itself is stubbed; the gate's own behaviour is test-pr-review-checks-absent.sh's.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
HELPER="$SCRIPT_DIR/pr-review.sh"

export SHIP_PR_TEST_SOURCE_ONLY=1
export SHIP_PR_STATE_DIR=off
export SHIP_PR_API_ATTEMPTS=1
export SHIP_PR_API_BACKOFF=0
# shellcheck source=pr-review.sh
source "$HELPER"

REPO=example/repo

# Not `fail`: pr-review.sh is sourced above and its refusals call ITS fail, whose exit code the
# merge tests read; a same-named helper here would turn every refusal into this reporter's 1.
bail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || bail "$3 (got '$1', expected '$2')"
}

assert_contains() {
  case "$1" in *"$2"*) ;; *) bail "$3 (missing '$2' in: $1)" ;; esac
}

OUT_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-review-merge-out.XXXXXX") || exit 1
CALLS_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-review-merge-calls.XXXXXX") || exit 1
# pr-review.sh installed its own EXIT trap when sourced; keep its cleanup and add these files'.
trap 'rm -f "$GH_ERR_FILE" "$OUT_FILE" "$CALLS_FILE"' EXIT

SKIPS_ONLY=""                          # the head's checks all skipped/neutral
MERGE_STATE="merged=true state=MERGED" # what REST says after the merge call
MERGE_QUEUE=""                         # nonempty = the base has a merge queue

# gate_checks calls these inside command substitutions; they print, they do not set variables.
build_checks() {
  if [ -n "$SKIPS_ONLY" ]; then
    printf 'green\tci\tskipped\thttps://example/run\ngreen\tdocs\tneutral\thttps://example/run2\n'
  else
    printf 'green\tci\tsuccess\thttps://example/run\n'
  fi
  return 0
}
run_signal() { printf '0\tevery run for the head finished and was judged\n'; return 0; }
warn_base_drift() { return 0; }

gh() {
  case "${1:-} ${2:-}" in
  "api repos/$REPO/pulls/7")
    case "$*" in
    *'.head.sha'*) printf 'head-sha\t2026-09-01T00:00:00Z\n' ;;
    *'.base.ref'*) echo main ;;
    *merged=*) echo "$MERGE_STATE" ;;
    *) bail "unexpected pulls read: $*" ;;
    esac
    ;;
  "api graphql")
    case "$*" in
    *mergeQueue*) printf 'CALL %s\n' "$*" >>"$CALLS_FILE"; echo "$MERGE_QUEUE" ;;
    *) bail "unexpected graphql call: $*" ;;
    esac
    ;;
  "pr merge") printf 'CALL %s\n' "$*" >>"$CALLS_FILE" ;;
  *) bail "unexpected fixture gh call: $*" ;;
  esac
}

# In a subshell: cmd_merge's refusals are `fail`, which exits the shell it runs in. The calls
# and output travel through files, so the subshell costs nothing the assertions need.
run_merge() {
  local rc
  : >"$CALLS_FILE"
  set +e
  (cmd_merge "$REPO#7" "$@") >"$OUT_FILE" 2>&1
  rc=$?
  set -e
  MERGE_OUTPUT=$(cat "$OUT_FILE")
  MERGE_RC="$rc"
  MERGE_CALLS=$(cat "$CALLS_FILE")
}

assert_no_merge_call() {
  case "$MERGE_CALLS" in *"pr merge"*) bail "no merge call should have been made ($MERGE_CALLS)" ;; esac
}

reset() {
  SKIPS_ONLY=""
  MERGE_STATE="merged=true state=MERGED"
  MERGE_QUEUE=""
}

# The merge is bound to the head the gate read: a push during a long --wait must not land a head
# with neither a read green nor a 👍.
test_merge_binds_to_the_gated_head() {
  reset
  run_merge
  assert_eq "$MERGE_RC" 0 "a green head merges ($MERGE_OUTPUT)"
  assert_contains "$MERGE_CALLS" "--match-head-commit head-sha " "merge is bound to the gated head"
  assert_contains "$MERGE_CALLS" " --merge" "the repo convention stays"
}

test_forwarded_head_binding_is_refused() {
  reset
  run_merge -- --match-head-commit other --merge
  assert_eq "$MERGE_RC" 2 "a forwarded --match-head-commit is a usage error"
  assert_contains "$MERGE_OUTPUT" "cannot be forwarded" "should say the flag is the script's"
  assert_no_merge_call
  run_merge -- --match-head-commit=other --merge
  assert_eq "$MERGE_RC" 2 "the = form is refused too"
}

# Skipped and neutral are green for the ordinary gate; a close-out merge needs a build that RAN.
test_require_green_refuses_green_by_skips_only() {
  reset
  SKIPS_ONLY=1
  run_merge
  assert_eq "$MERGE_RC" 0 "the ordinary gate lets skips-only through"
  run_merge --require-green
  assert_eq "$MERGE_RC" 4 "--require-green refuses skips-only"
  assert_contains "$MERGE_OUTPUT" "skipped or neutral — green, but no build RAN" "should say why"
  assert_no_merge_call
}

test_require_green_refuses_auto() {
  reset
  run_merge --require-green -- --auto --merge
  assert_eq "$MERGE_RC" 2 "--auto with --require-green is a usage error"
  assert_contains "$MERGE_OUTPUT" "cannot be combined with --auto" "should name the conflict"
  assert_no_merge_call
}

# On a base that defers merges, gh returns 0 having only ENABLED auto-merge; a close-out merge
# takes that back rather than leaving a later head armed to land ungated.
test_require_green_disables_a_deferred_auto_merge() {
  reset
  MERGE_STATE="merged=false state=OPEN"
  run_merge
  assert_eq "$MERGE_RC" 1 "an ordinary deferred merge is exit 1"
  case "$MERGE_CALLS" in *--disable-auto*) bail "the ordinary path must not disable auto-merge" ;; esac
  run_merge --require-green
  assert_eq "$MERGE_RC" 1 "a deferred close-out merge is exit 1"
  assert_contains "$MERGE_CALLS" "--disable-auto" "auto-merge should be disabled again"
  assert_contains "$MERGE_OUTPUT" "auto-merge DISABLED again" "should say it took it back"
}

# A merge queue makes `gh pr merge` an enqueue, which --disable-auto cannot undo: a close-out
# merge refuses before calling merge, and reads the queue again right before the call. The
# ordinary gate never asks.
test_require_green_refuses_a_merge_queue() {
  reset
  MERGE_QUEUE=MQ_1
  run_merge
  assert_eq "$MERGE_RC" 0 "the ordinary gate merges on a queued base as before"
  case "$MERGE_CALLS" in *mergeQueue*) bail "the ordinary path must not read the queue" ;; esac
  run_merge --require-green
  assert_eq "$MERGE_RC" 1 "--require-green refuses a base with a merge queue"
  assert_contains "$MERGE_OUTPUT" "has a merge queue" "should say why"
  assert_contains "$MERGE_CALLS" "mergeQueue(branch:" "should have read the queue"
  assert_no_merge_call
  MERGE_QUEUE=""
  run_merge --require-green
  assert_eq "$MERGE_RC" 0 "no queue: --require-green merges ($MERGE_OUTPUT)"
  assert_eq "$(grep -c 'mergeQueue(branch:' "$CALLS_FILE")" 2 "the queue is read before and after the gate"
  local calls
  calls=$(grep -n 'mergeQueue\|pr merge' "$CALLS_FILE" | cut -d: -f2- | cut -c1-14 | tr '\n' ',')
  assert_eq "$calls" "CALL api graph,CALL api graph,CALL pr merge ," "both reads precede the merge call"
}

tests=(
  test_merge_binds_to_the_gated_head
  test_forwarded_head_binding_is_refused
  test_require_green_refuses_green_by_skips_only
  test_require_green_refuses_auto
  test_require_green_disables_a_deferred_auto_merge
  test_require_green_refuses_a_merge_queue
)

for test_name in "${tests[@]}"; do
  "$test_name"
  echo "PASS: $test_name"
done
