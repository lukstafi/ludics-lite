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

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_eq() {
  [ "$1" = "$2" ] || fail "$3 (got '$1', expected '$2')"
}

assert_contains() {
  case "$1" in *"$2"*) ;; *) fail "$3 (missing '$2' in: $1)" ;; esac
}

# The only gh call gate_checks makes itself is the head-SHA read; the check list comes through
# build_checks, stubbed below.
gh() {
  [ "${1:-}" = api ] || fail "fixture received non-api gh call: $*"
  case "${2:-}" in
  "repos/$REPO/pulls/7") echo head-sha ;;
  *) fail "unexpected fixture endpoint: ${2:-}" ;;
  esac
}

# gate_checks calls this inside a command substitution, so the read count lives in a file, not a
# variable: a subshell's increment would never reach the test.
READS_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-review-checks-reads.XXXXXX") || exit 1
reads() { wc -l <"$READS_FILE" | tr -d ' '; }
PENDING_FOREVER=""
build_checks() {
  echo read >>"$READS_FILE"
  if [ -n "$PENDING_FOREVER" ]; then
    printf 'pending\tci\t\thttps://example/run\n'
  elif [ -n "$GREEN_AFTER" ] && [ "$(reads)" -gt "$GREEN_AFTER" ]; then
    printf 'green\tci\tsuccess\thttps://example/run\n'
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
  [ "$(reads)" -ge 3 ] || fail "should have re-read after absent (reads: $(reads))"
}

test_absent_past_the_grace_is_the_answer() {
  GREEN_AFTER=""
  local before after
  before=$(date +%s)
  run_gate 60
  after=$(date +%s)
  assert_eq "$GATE_RC" 0 "absent past the grace is still exit 0 from the ordinary gate"
  assert_eq "$VERDICT" absent "should settle on absent"
  [ $((after - before)) -lt 30 ] || fail "should give up at the grace, not the full wait"
  [ $((after - before)) -ge 3 ] || fail "should have held through the grace"
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
  [ "$beats" -ge 1 ] || fail "expected at least one heartbeat in a 5 s wait (got $beats)"
  [ "$beats" -le 3 ] || fail "expected at most one heartbeat per 2 s, got $beats in 5 s"
  [ "$(reads)" -ge 4 ] || fail "should have re-read more often than it beat (reads: $(reads))"
}

# The merge is bound to the head the gate read: a push during a long --wait must not land a head
# with neither a read green nor a 👍.
MERGE_ARGS_FILE=$(mktemp "${TMPDIR:-/tmp}/pr-review-merge-args.XXXXXX") || exit 1
trap 'rm -f "$GH_ERR_FILE" "$OUT_FILE" "$READS_FILE" "$MERGE_ARGS_FILE"' EXIT
test_merge_binds_to_the_gated_head() {
  GREEN_AFTER=0
  warn_base_drift() { return 0; }
  gh() {
    case "${1:-} ${2:-}" in
    "api repos/$REPO/pulls/7")
      case "$*" in
      *'.head.sha'*) echo head-sha ;;
      *merged=*) echo "merged=true state=MERGED" ;;
      *) fail "unexpected pulls read: $*" ;;
      esac
      ;;
    "pr merge") printf '%s\n' "$@" >"$MERGE_ARGS_FILE" ;;
    *) fail "unexpected fixture gh call: $*" ;;
    esac
  }
  local rc
  set +e
  cmd_merge "$REPO#7" >"$OUT_FILE" 2>&1
  rc=$?
  set -e
  assert_eq "$rc" 0 "a green head merges ($(cat "$OUT_FILE"))"
  assert_contains "$(tr '\n' ' ' <"$MERGE_ARGS_FILE")" "--match-head-commit head-sha " \
    "merge should be bound to the gated head"
  assert_contains "$(tr '\n' ' ' <"$MERGE_ARGS_FILE")" " --merge" "the repo convention stays"
}

tests=(
  test_no_wait_takes_absent_at_once
  test_wait_holds_for_a_run_to_appear
  test_absent_past_the_grace_is_the_answer
  test_heartbeat_is_once_per_period
  test_merge_binds_to_the_gated_head
)

for test_name in "${tests[@]}"; do
  "$test_name"
  echo "PASS: $test_name"
done
