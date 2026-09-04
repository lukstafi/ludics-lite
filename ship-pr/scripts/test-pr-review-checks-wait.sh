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
build_checks() {
  echo read >>"$READS_FILE"
  if [ -n "$GREEN_AFTER" ] && [ "$(reads)" -gt "$GREEN_AFTER" ]; then
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

tests=(
  test_no_wait_takes_absent_at_once
  test_wait_holds_for_a_run_to_appear
  test_absent_past_the_grace_is_the_answer
)

for test_name in "${tests[@]}"; do
  "$test_name"
  echo "PASS: $test_name"
done
