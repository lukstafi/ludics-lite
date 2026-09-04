#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's build-signal wait: an ABSENT signal in the first
# seconds of a wait is a run that does not exist yet, and the wait holds through a creation grace
# for it (ludics-lite#39 review, round 4).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
HELPER="$SCRIPT_DIR/pr-review.sh"

export SHIP_PR_TEST_SOURCE_ONLY=1
export SHIP_PR_STATE_DIR=off
export SHIP_PR_API_ATTEMPTS=1
export SHIP_PR_API_BACKOFF=0
export SHIP_PR_CHECKS_INTERVAL=1
export SHIP_PR_CHECKS_ABSENT_GRACE=3
# shellcheck source=pr-review.sh
source "$HELPER"

REPO=example/repo
GREEN_AFTER=""   # number of absent reads before a green one; empty = absent forever

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

# The only gh call gate_checks makes itself is the head-SHA read; the check list comes through
# build_checks, stubbed below.
gh() {
  [ "${1:-}" = api ] || bail "fixture received non-api gh call: $*"
  case "${2:-}" in
  "repos/$REPO/pulls/7") echo head-sha ;;
  *) bail "unexpected fixture endpoint: ${2:-}" ;;
  esac
}

# gate_checks calls this inside a command substitution, so the read count lives in a file, not a
# variable: a subshell's increment would never reach the test.
READS_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-review-checks-reads.XXXXXX") || exit 1
reads() { wc -l <"$READS_FILE" | tr -d ' '; }
PENDING_FOREVER=""
SKIPS_ONLY=""
STARTED_AT=""   # epoch the green check-run was created; empty = undated
build_checks() {
  echo read >>"$READS_FILE"
  if [ -n "$PENDING_FOREVER" ]; then
    printf 'pending\tci\t\thttps://example/run\n'
  elif [ -n "$SKIPS_ONLY" ]; then
    printf 'green\tci\tskipped\thttps://example/run\ngreen\tdocs\tneutral\thttps://example/run2\n'
  elif [ -n "$GREEN_AFTER" ] && [ "$(reads)" -gt "$GREEN_AFTER" ]; then
    printf 'green\tci\tsuccess\thttps://example/run\t%s\n' "${STARTED_AT:-0}"
  fi
  return 0
}

OUT_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-review-checks-wait.XXXXXX") || exit 1
# pr-review.sh installed its own EXIT trap when sourced; keep its cleanup and add this file's.
trap 'rm -f "$GH_ERR_FILE" "$OUT_FILE" "$READS_FILE"' EXIT

# Not a command substitution: the stub's read counter and gate_checks' VERDICT must land in
# THIS shell, and a $(...) would keep both in a subshell.
run_gate() {
  local rc
  : >"$READS_FILE"
  set +e
  gate_checks 7 "$1" >"$OUT_FILE" 2>&1
  rc=$?
  set -e
  GATE_OUTPUT=$(cat "$OUT_FILE")
  GATE_RC="$rc"
}

test_no_wait_takes_absent_at_once() {
  GREEN_AFTER=1
  run_gate 0
  assert_eq "$GATE_RC" 0 "absent without --wait is exit 0"
  assert_eq "$(reads)" 1 "no wait means one read"
  assert_contains "$GATE_OUTPUT" "ABSENT" "should report absent"
}

test_wait_holds_for_a_run_to_appear() {
  GREEN_AFTER=2
  run_gate 30
  assert_eq "$GATE_RC" 0 "a green that appears inside the grace is exit 0"
  assert_eq "$VERDICT" green "should have read the green"
  assert_contains "$GATE_OUTPUT" "holding up to 3 s for one to appear" "should say it is holding"
  assert_contains "$GATE_OUTPUT" ": green" "should report green"
  [ "$(reads)" -ge 3 ] || bail "should have re-read after absent (reads: $(reads))"
}

test_absent_past_the_grace_is_the_answer() {
  GREEN_AFTER=""
  local before after
  before=$(date +%s)
  run_gate 60
  after=$(date +%s)
  assert_eq "$GATE_RC" 0 "absent past the grace is still exit 0 from the ordinary gate"
  assert_eq "$VERDICT" absent "should settle on absent"
  [ $((after - before)) -lt 30 ] || bail "should give up at the grace, not the full wait"
  [ $((after - before)) -ge 3 ] || bail "should have held through the grace"
}

# The heartbeat is one line per SHIP_PR_CHECKS_HEARTBEAT, not one per re-read: round 4's edit
# dropped the clock advance and a two-hour wait would have printed every minute.
test_heartbeat_is_once_per_period() {
  PENDING_FOREVER=1
  CHECKS_HEARTBEAT=2
  run_gate 5
  PENDING_FOREVER=""
  assert_eq "$GATE_RC" 4 "pending to the deadline is exit 4"
  local beats
  beats=$(grep -c 'still waiting' "$OUT_FILE" || true)
  [ "$beats" -ge 1 ] || bail "expected at least one heartbeat in a 5 s wait (got $beats)"
  [ "$beats" -le 3 ] || bail "expected at most one heartbeat per 2 s, got $beats in 5 s"
  [ "$(reads)" -ge 4 ] || bail "should have re-read more often than it beat (reads: $(reads))"
}

# The merge fixture: the head read, the merge call (recorded), and the post-merge state read.
MERGE_ARGS_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-review-merge-args.XXXXXX") || exit 1
trap 'rm -f "$GH_ERR_FILE" "$OUT_FILE" "$READS_FILE" "$MERGE_ARGS_FILE"' EXIT
MERGE_STATE="merged=true state=MERGED"
MERGE_QUEUE=""   # nonempty = the base has a merge queue
use_merge_fixture() {
  : >"$MERGE_ARGS_FILE"
  GREEN_AFTER=0
  SKIPS_ONLY=""
  STARTED_AT=""
  MERGE_QUEUE=""
  warn_base_drift() { return 0; }
  gh() {
    case "${1:-} ${2:-}" in
    "api repos/$REPO/pulls/7")
      case "$*" in
      *'.head.sha'*) echo head-sha ;;
      *'.base.ref'*) echo main ;;
      *merged=*) echo "$MERGE_STATE" ;;
      *) bail "unexpected pulls read: $*" ;;
      esac
      ;;
    "api graphql")
      case "$*" in
      *mergeQueue*) printf 'CALL %s\n' "$*" >>"$MERGE_ARGS_FILE"; echo "$MERGE_QUEUE" ;;
      *) bail "unexpected graphql call: $*" ;;
      esac
      ;;
    "pr merge") printf 'CALL %s\n' "$*" >>"$MERGE_ARGS_FILE" ;;
    *) bail "unexpected fixture gh call: $*" ;;
    esac
  }
}
# In a subshell: cmd_merge's refusals are `fail`, which exits the shell it runs in. The calls
# and output travel through files, so the subshell costs nothing the assertions need.
assert_no_merge_call() {
  case "$MERGE_CALLS" in *"pr merge"*) bail "no merge call should have been made ($MERGE_CALLS)" ;; esac
}
run_merge() {
  local rc
  : >"$MERGE_ARGS_FILE"
  set +e
  (cmd_merge "$REPO#7" "$@") >"$OUT_FILE" 2>&1
  rc=$?
  set -e
  MERGE_OUTPUT=$(cat "$OUT_FILE")
  MERGE_RC="$rc"
  MERGE_CALLS=$(cat "$MERGE_ARGS_FILE")
}

# The merge is bound to the head the gate read: a push during a long --wait must not land a head
# with neither a read green nor a 👍.
test_merge_binds_to_the_gated_head() {
  use_merge_fixture
  run_merge
  assert_eq "$MERGE_RC" 0 "a green head merges ($MERGE_OUTPUT)"
  assert_contains "$MERGE_CALLS" "--match-head-commit head-sha " "merge is bound to the gated head"
  assert_contains "$MERGE_CALLS" " --merge" "the repo convention stays"
}

# Skipped and neutral are green for the ordinary gate; a close-out merge needs a build that RAN.
test_require_green_refuses_green_by_skips_only() {
  use_merge_fixture
  SKIPS_ONLY=1
  run_merge
  assert_eq "$MERGE_RC" 0 "the ordinary gate lets skips-only through"
  run_merge --require-green
  assert_eq "$MERGE_RC" 4 "--require-green refuses skips-only"
  assert_contains "$MERGE_OUTPUT" "skipped or neutral — green, but no build RAN" "should say why"
  assert_no_merge_call
}

test_forwarded_head_binding_is_refused() {
  use_merge_fixture
  run_merge -- --match-head-commit other --merge
  assert_eq "$MERGE_RC" 2 "a forwarded --match-head-commit is a usage error"
  assert_contains "$MERGE_OUTPUT" "cannot be forwarded" "should say the flag is the script's"
  assert_no_merge_call
  run_merge -- --match-head-commit=other --merge
  assert_eq "$MERGE_RC" 2 "the = form is refused too"
}

test_require_green_refuses_auto() {
  use_merge_fixture
  run_merge --require-green -- --auto --merge
  assert_eq "$MERGE_RC" 2 "--auto with --require-green is a usage error"
  assert_contains "$MERGE_OUTPUT" "cannot be combined with --auto" "should name the conflict"
  assert_no_merge_call
}

# On a base that defers merges, gh returns 0 having only ENABLED auto-merge; a close-out merge
# takes that back rather than leaving a later head armed to land ungated.
test_require_green_disables_a_deferred_auto_merge() {
  use_merge_fixture
  MERGE_STATE="merged=false state=OPEN"
  run_merge
  assert_eq "$MERGE_RC" 1 "an ordinary deferred merge is exit 1"
  case "$MERGE_CALLS" in *--disable-auto*) bail "the ordinary path must not disable auto-merge" ;; esac
  run_merge --require-green
  MERGE_STATE="merged=true state=MERGED"
  assert_eq "$MERGE_RC" 1 "a deferred close-out merge is exit 1"
  assert_contains "$MERGE_CALLS" "--disable-auto" "auto-merge should be disabled again"
  assert_contains "$MERGE_OUTPUT" "auto-merge DISABLED again" "should say it took it back"
}

# A green whose newest check-run is seconds old may be a partial set — a sibling workflow not
# yet registered. The ordinary gate takes it; --require-green refuses without --wait and holds
# with it until the set has aged past the grace.
test_require_green_waits_for_a_young_green_to_settle() {
  use_merge_fixture
  STARTED_AT=$(date +%s)
  run_merge
  assert_eq "$MERGE_RC" 0 "the ordinary gate takes a young green"
  STARTED_AT=$(date +%s)
  run_merge --require-green
  assert_eq "$MERGE_RC" 4 "--require-green refuses a young green without --wait"
  assert_contains "$MERGE_OUTPUT" "younger than 3 s" "should say the set is young"
  assert_no_merge_call
  STARTED_AT=$(date +%s)
  local before after
  before=$(date +%s)
  run_merge --require-green --wait=20
  after=$(date +%s)
  assert_eq "$MERGE_RC" 0 "--require-green --wait merges once the set has settled ($MERGE_OUTPUT)"
  assert_contains "$MERGE_OUTPUT" "holding until the set is 3 s old" "should say it is holding"
  [ $((after - before)) -ge 3 ] || bail "should have held through the grace"
  [ $((after - before)) -lt 15 ] || bail "should not have waited to the deadline"
  STARTED_AT=$(( $(date +%s) - 60 ))
  run_merge --require-green
  assert_eq "$MERGE_RC" 0 "an old green needs no settling ($MERGE_OUTPUT)"
}

# A merge queue makes `gh pr merge` an enqueue, which --disable-auto cannot undo: a close-out
# merge refuses before calling merge. The ordinary gate never asks.
test_require_green_refuses_a_merge_queue() {
  use_merge_fixture
  MERGE_QUEUE=MQ_1
  run_merge
  assert_eq "$MERGE_RC" 0 "the ordinary gate merges on a queued base as before"
  case "$MERGE_CALLS" in *mergeQueue*) bail "the ordinary path must not read the queue" ;; esac
  run_merge --require-green
  MERGE_QUEUE=""
  assert_eq "$MERGE_RC" 1 "--require-green refuses a base with a merge queue"
  assert_contains "$MERGE_OUTPUT" "has a merge queue" "should say why"
  assert_contains "$MERGE_CALLS" "mergeQueue(branch:" "should have read the queue"
  assert_no_merge_call
  run_merge --require-green
  assert_eq "$MERGE_RC" 0 "no queue: --require-green merges ($MERGE_OUTPUT)"
  # Read twice: before the wait, and again right before the merge call — a queue can be
  # enabled or the PR retargeted during a two-hour wait.
  assert_eq "$(grep -c 'mergeQueue(branch:' "$MERGE_ARGS_FILE")" 2 "the queue is read before and after the gate"
  local calls
  calls=$(grep -n 'mergeQueue\|pr merge' "$MERGE_ARGS_FILE" | cut -d: -f2- | cut -c1-14 | tr '\n' ',')
  assert_eq "$calls" "CALL api graph,CALL api graph,CALL pr merge ," "both reads precede the merge call"
}

test_malformed_absent_grace_is_refused() {
  local out rc v
  for v in 08 09 x -1 5s; do
    set +e
    out=$(SHIP_PR_CHECKS_ABSENT_GRACE="$v" bash "$HELPER" checks "$REPO#7" 2>&1)
    rc=$?
    set -e
    assert_eq "$rc" 2 "an absent grace of '$v' is a usage error"
    assert_contains "$out" "SHIP_PR_CHECKS_ABSENT_GRACE must be a number of seconds" \
      "should name the setting for '$v'"
  done
  set +e
  out=$(SHIP_PR_CHECKS_ABSENT_GRACE=0 SHIP_PR_TEST_SOURCE_ONLY=1 bash "$HELPER" 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" 0 "a zero grace is accepted"
}

tests=(
  test_no_wait_takes_absent_at_once
  test_wait_holds_for_a_run_to_appear
  test_absent_past_the_grace_is_the_answer
  test_heartbeat_is_once_per_period
  test_merge_binds_to_the_gated_head
  test_require_green_refuses_green_by_skips_only
  test_forwarded_head_binding_is_refused
  test_require_green_refuses_auto
  test_require_green_disables_a_deferred_auto_merge
  test_require_green_refuses_a_merge_queue
  test_malformed_absent_grace_is_refused
  test_require_green_waits_for_a_young_green_to_settle
)

for test_name in "${tests[@]}"; do
  "$test_name"
  echo "PASS: $test_name"
done
