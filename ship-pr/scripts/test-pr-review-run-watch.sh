#!/usr/bin/env bash
# Focused fixture tests for pr-review.sh's `retry run watch`: how the run is addressed, and the
# line between an invocation error and a verdict about the run (ludics-lite#74).
#
# The await used to resolve the repository from the cwd when no -R/REPO named one. A worker whose
# background shell had started in another project's worktree awaited a run id from this one: the
# read 404'd against the repo the cwd named, and the await exited 1 — a red gate manufactured out
# of a wrong-target invocation. So the run now travels as owner/name#<run-id>, like every other
# subcommand's argument, and the cases below pin BOTH halves: the refusals that replaced the
# guess, and the exits 0/1/3/4 that must survive them (a refusal policy that swallowed the real
# verdicts would be worse than the inference it replaced).

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
# shellcheck source=test-pr-review-lib.sh
source "$SCRIPT_DIR/test-pr-review-lib.sh"
test_tmpdir TEST_ROOT run-watch-test

CALL_LOG="$TEST_ROOT/gh-calls"
: >"$CALL_LOG"

RUN_STATUS=completed
RUN_CONCLUSION=success
RUN_ERROR="" # gh's stderr when the read must fail, e.g. "gh: Not Found (HTTP 404)"
# What `repo_from_cwd` would answer if anything asked it. The point of every refusal case below is
# that nothing does: this value must never reach a run read.
CWD_REPO=cwd-inferred/repo

# The fixture gh. Not gh_fixture_parse: that one refuses everything but `gh api`, and this await
# reads `gh run view`. `repo view` is answered rather than refused ON PURPOSE — it is the first
# thing the removed cwd inference asked, so a regression that brings the guess back shows up as a
# `run view` in the call log instead of as a fixture error nobody can attribute.
gh() {
  local filter="" repo="" run_id="" json=""
  printf '%s\n' "$*" >>"$CALL_LOG"
  case "$1 ${2:-}" in
  "repo view")
    printf '%s\n' "$CWD_REPO"
    return 0
    ;;
  "run view") ;;
  *)
    echo "gh: unsupported fixture call: $*" >&2
    return 1
    ;;
  esac
  shift 2
  run_id="${1:-}"
  shift || true
  while [ $# -gt 0 ]; do
    case "$1" in
    --repo)
      repo="${2:-}"
      shift
      ;;
    --jq)
      filter="${2:-}"
      shift
      ;;
    --json) shift ;;
    esac
    shift
  done
  [ -n "$run_id" ] || bail "fixture run view got no run id: $*"
  [ -n "$repo" ] || bail "fixture run view got no --repo: $*"
  if [ -n "$RUN_ERROR" ]; then
    echo "$RUN_ERROR" >&2
    return 1
  fi
  json=$(jq -cn --arg s "$RUN_STATUS" --arg c "$RUN_CONCLUSION" \
    '{status:$s, conclusion:(if $c == "" then null else $c end)}')
  if [ -n "$filter" ]; then jq -r "$filter" <<<"$json"; else printf '%s\n' "$json"; fi
}

reset_fixture() {
  RUN_STATUS=completed
  RUN_CONCLUSION=success
  RUN_ERROR=""
  REPO=""
  AWAIT_WAIT=""
  : >"$CALL_LOG"
}

# cmd_run_watch in a command substitution: its refusals call `exit`, and a subshell is what keeps
# them from ending this reporter. The subshell is also where AWAIT_WAIT is applied, so a case that
# shortens the deadline cannot leak that to the next one.
AWAIT_WAIT=""
run_await() {
  local rc
  : >"$CALL_LOG"
  set +e
  AWAIT_OUT=$(CHECKS_WAIT="${AWAIT_WAIT:-$CHECKS_WAIT}" cmd_run_watch "$@" 2>&1)
  rc=$?
  set -e
  AWAIT_RC="$rc"
}

gh_calls() { cat "$CALL_LOG"; }

# A scratch checkout whose origin is a third repository, so the git half of the removed inference
# is armed too: `repo_from_cwd` falls back to `git remote get-url origin` when gh does not answer.
# It sets CWD_CHECKOUT rather than printing the path: test_tmpdir registers the directory for
# removal in the shell it runs in, and a $(...) would register it in a subshell that then exits.
CWD_CHECKOUT=""
scratch_checkout() {
  test_tmpdir CWD_CHECKOUT cwd-checkout
  git -C "$CWD_CHECKOUT" init -q >/dev/null 2>&1 || bail "git init failed in $CWD_CHECKOUT"
  git -C "$CWD_CHECKOUT" remote add origin https://github.com/cwd-git/repo.git ||
    bail "git remote add failed in $CWD_CHECKOUT"
}

# --- the refusals that replaced the guess -----------------------------------------------------

# The regression control. Both inference paths are armed — the fixture answers `repo view`, and
# the cwd is a checkout whose origin names yet another repo — and the await must still refuse
# without reading anything. On the old code this case reports exit 1 over `cwd-inferred/repo`.
test_bare_run_id_without_a_repo_is_refused() {
  local rc
  reset_fixture
  scratch_checkout
  : >"$CALL_LOG"
  set +e
  AWAIT_OUT=$(cd "$CWD_CHECKOUT" && cmd_run_watch 12345 2>&1)
  rc=$?
  set -e
  assert_eq "$rc" 2 "a bare run id with no repo is an invocation error ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "name the repo" "the refusal should say what is missing"
  assert_contains "$AWAIT_OUT" "owner/name#12345" "the refusal should spell the accepted form"
  assert_contains "$AWAIT_OUT" "ludics-lite#74" "the refusal should cite the failure it prevents"
  assert_not_contains "$AWAIT_OUT" "cwd-inferred/repo" "the cwd's repo must not be named as a target"
  assert_not_contains "$AWAIT_OUT" "cwd-git/repo" "the origin remote must not be named as a target"
  assert_eq "$(gh_calls)" "" "nothing may be read before the repo is known"
}

# The positive control on that refusal: the same bare id passes the moment a repo is named, so the
# refusal is about the missing repo and not about the bare form.
test_bare_run_id_with_a_named_repo_is_accepted() {
  reset_fixture
  run_await -R example/repo 12345
  assert_eq "$AWAIT_RC" 0 "a bare id with -R should run ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "run 12345 in example/repo: success" "the verdict line"
  assert_contains "$(gh_calls)" "--repo example/repo" "the read should name the repo given"
  reset_fixture
  REPO=env/repo
  run_await 12345
  assert_eq "$AWAIT_RC" 0 "a bare id with REPO= should run ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "run 12345 in env/repo: success" "REPO= names the target too"
}

# The form the skill now documents.
test_owner_name_hash_run_is_accepted() {
  reset_fixture
  REPO=env/repo
  run_await example/repo#4242
  assert_eq "$AWAIT_RC" 0 "owner/name#<run-id> should run ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "run 4242 in example/repo: success" "the verdict names the argument's repo"
  assert_contains "$(gh_calls)" "run view 4242 --repo example/repo" "the read should use the argument"
  assert_not_contains "$(gh_calls)" "env/repo" "the argument overrides the REPO= default"
}

# Two spellings that both name a target and disagree: refused, not silently resolved either way.
test_conflicting_repos_are_refused() {
  reset_fixture
  run_await -R other/repo example/repo#4242
  assert_eq "$AWAIT_RC" 2 "two disagreeing targets are an invocation error ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "example/repo" "the refusal should name the argument's repo"
  assert_contains "$AWAIT_OUT" "other/repo" "the refusal should name the flag's repo"
  assert_eq "$(gh_calls)" "" "nothing may be read while the target is ambiguous"
  # The negative control: the same two spellings AGREEING are not a conflict.
  reset_fixture
  run_await -R example/repo example/repo#4242
  assert_eq "$AWAIT_RC" 0 "two spellings that agree should run ($AWAIT_OUT)"
}

test_malformed_run_argument_is_refused() {
  reset_fixture
  run_await example/repo#abc
  assert_eq "$AWAIT_RC" 2 "a non-numeric run id is refused ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "owner/name#<run-id>" "the refusal should spell the form"
  reset_fixture
  run_await example/repo
  assert_eq "$AWAIT_RC" 2 "a repo with no run id is refused ($AWAIT_OUT)"
  reset_fixture
  run_await
  assert_eq "$AWAIT_RC" 2 "no run argument at all is refused ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "name the run" "the refusal should say what is missing"
  reset_fixture
  run_await example/repo#1 example/repo#2
  assert_eq "$AWAIT_RC" 2 "two run arguments are refused ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "name exactly one" "the refusal should say so"
  assert_eq "$(gh_calls)" "" "a malformed invocation reads nothing"
}

# An argument that carries unparsed input in FRONT of a valid one is the same wrong-target
# failure, arriving through the parse instead of through the cwd: taking the tail after the last
# `#` would name run 222 and run 123 here, and answer about them.
test_unparsed_prefixes_are_refused() {
  reset_fixture
  run_await example/repo#111#222
  assert_eq "$AWAIT_RC" 2 "a second '#' is refused ($AWAIT_OUT)"
  assert_eq "$(gh_calls)" "" "run 222 must not be read"
  reset_fixture
  run_await -R example/repo junk#123
  assert_eq "$AWAIT_RC" 2 "a junk prefix before '#' is refused ($AWAIT_OUT)"
  assert_eq "$(gh_calls)" "" "run 123 must not be read"
  reset_fixture
  run_await -R example/repo '#123'
  assert_eq "$AWAIT_RC" 2 "a bare '#123' is refused ($AWAIT_OUT)"
  reset_fixture
  run_await example/repo/extra#4242
  assert_eq "$AWAIT_RC" 2 "a third path segment is refused ($AWAIT_OUT)"
  reset_fixture
  run_await "example repo#4242"
  assert_eq "$AWAIT_RC" 2 "a repo outside GitHub's name characters is refused ($AWAIT_OUT)"
  assert_eq "$(gh_calls)" "" "nothing may be read on any of these"
}

# --- the verdicts the refusals must not swallow -----------------------------------------------

# A 4xx is the API answering about the pair you named, so it is an invocation error too — but it
# must not borrow exit 1 from the run's own failure, which is what read as a red gate.
test_a_rejected_pair_is_not_a_failed_run() {
  reset_fixture
  RUN_ERROR="gh: Not Found (HTTP 404)"
  run_await example/repo#4242
  assert_eq "$AWAIT_RC" 2 "a 404 on the pair is an invocation error ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "no run 4242 readable here" "the refusal should name the pair"
  assert_contains "$AWAIT_OUT" "not a failure" "it must say what it is not"
  assert_not_contains "$AWAIT_OUT" "FAILED" "a 404 is not a verdict about the run"
}

# The negative control for the case above: exit 1 is still reachable, and only a real conclusion
# reaches it. Without this, "a 404 is not exit 1" would be a claim that cannot fail.
test_a_failed_run_is_still_exit_1() {
  reset_fixture
  RUN_CONCLUSION=failure
  run_await example/repo#4242
  assert_eq "$AWAIT_RC" 1 "a failed run is the verdict ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "the run FAILED" "the verdict should say so"
  assert_contains "$AWAIT_OUT" "--log-failed" "and point at the failure"
}

# Transport stays apart from both: nothing was learned, so nothing is claimed.
test_transport_failure_is_unknown() {
  reset_fixture
  RUN_ERROR="gh: Something went wrong (HTTP 503)"
  run_await example/repo#4242
  assert_eq "$AWAIT_RC" 3 "an unanswered read is transport ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "UNKNOWN" "it should say the state is unknown"
  assert_not_contains "$AWAIT_OUT" "not a failure, so it is" "no verdict is implied"
}

# And a run still going at the deadline is exit 4, stopped-not-judged like everywhere else.
test_no_verdict_is_exit_4() {
  reset_fixture
  RUN_STATUS=in_progress
  RUN_CONCLUSION=""
  AWAIT_WAIT=0
  run_await example/repo#4242
  assert_eq "$AWAIT_RC" 4 "a run still going at the deadline has no verdict ($AWAIT_OUT)"
  assert_contains "$AWAIT_OUT" "NO VERDICT" "it should say so"
  assert_contains "$AWAIT_OUT" "in_progress" "and report the status it read"
}

# --- the shared parse -------------------------------------------------------------------------

# parse_ref is what both this command and pr_arg read their argument with; pinning it directly
# keeps the two spellings from drifting apart behind their different refusal messages.
test_parse_ref() {
  parse_ref example/repo#12 || bail "owner/name#number should parse"
  assert_eq "$REF_REPO" example/repo "the repo comes off the argument"
  assert_eq "$REF_NUM" 12 "the number comes off the argument"
  parse_ref 34 || bail "a bare number should parse"
  assert_eq "$REF_REPO" "" "a bare number carries no repo, and says so as empty"
  assert_eq "$REF_NUM" 34 "the bare number is the number"
  # The names GitHub actually allows on both halves, so the tightening below refuses only what
  # cannot be a repository.
  parse_ref my-org_1.x/repo.name-2#7 || bail "dots, dashes and underscores should parse"
  assert_eq "$REF_REPO" my-org_1.x/repo.name-2 "the repo comes through intact"
  assert_eq "$REF_NUM" 7 "and the number with it"
  local rc bad
  for bad in example/repo#x "" "#123" "junk#123" "example/repo#111#222" "example/repo/extra#1" \
    "example repo#1" "/repo#1" "example/#1" "example/repo#" "example/repo"; do
    set +e
    parse_ref "$bad"
    rc=$?
    set -e
    assert_eq "$rc" 1 "'$bad' must not parse"
    assert_eq "$REF_REPO" "" "'$bad' must leave no repo behind"
    assert_eq "$REF_NUM" "" "'$bad' must leave no number behind"
  done
}

tests=(
  test_bare_run_id_without_a_repo_is_refused
  test_bare_run_id_with_a_named_repo_is_accepted
  test_owner_name_hash_run_is_accepted
  test_conflicting_repos_are_refused
  test_malformed_run_argument_is_refused
  test_unparsed_prefixes_are_refused
  test_a_rejected_pair_is_not_a_failed_run
  test_a_failed_run_is_still_exit_1
  test_transport_failure_is_unknown
  test_no_verdict_is_exit_4
  test_parse_ref
)

run_tests "${tests[@]}"
