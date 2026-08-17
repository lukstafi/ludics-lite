#!/usr/bin/env bash
# Block until a sequencing precondition clears, then exit -- the waiter half of the
# wait-and-proceed skill. Background it (Bash run_in_background) and the completion notification
# IS the wake signal; run it in the foreground and it hits the 600s tool cap instead.
#
# Why the branch is watched through TWO independent signals, PR state first and git second:
# merging deletes the head branch far more often than not (16 of the last 20 merged PRs in the
# repo this was written against), and a deleted branch that the local clone never fetched leaves
# git with no evidence the work ever existed, let alone landed. So git alone silently waits
# forever on the ordinary case. The PR is therefore the primary witness; git is what covers the
# case the PR cannot -- work that has no PR yet, or that lands by a direct push.
#
# The rest of the traps, likewise kept in code rather than in the skill's prose:
#   - merge-base --is-ancestor reads LOCAL refs, so every git tick fetches first; without that a
#     branch merged an hour ago still reads as unlanded, forever;
#   - the tracking ref origin/<branch> is watched rather than a sha pinned at launch, so commits
#     pushed during review rounds count as part of the work being waited for;
#   - fetch does NOT prune, deliberately: pruning drops the tracking ref of a merged-and-deleted
#     branch and converts a clear signal into an eternal "never appeared";
#   - squash and rebase merges land the work without making the branch an ancestor of the base,
#     which the PR state catches and git cannot;
#   - a PR closed unmerged means the awaited thing will never happen -- terminal, exit at once
#     rather than burning the timeout;
#   - a branch absent from origin with no PR is reported on the FIRST tick, because otherwise a
#     mistyped branch name is indistinguishable from patience for the full four hours;
#   - concurrent fetches from other sessions contend on git's ref lock, so a failed fetch retries
#     next tick instead of killing the wait;
#   - EVERY exit path prints one line naming the outcome, because a waiter that ends silently
#     cannot be told from one that is still waiting.
#
# Usage:
#   wait-for.sh branch <branch> [--base <ref>] [--repo <dir>]
#   wait-for.sh cmd '<shell command>'        # any predicate; its exit 0 means clear
#   both accept: [--timeout <sec>] [--interval <sec>] [--label <text>]
#
# Exit: 0 clear, proceed | 3 timed out | 4 cannot evaluate | 5 will never clear | 2 usage.
#
# Env: none. Defaults: --base origin/master, --timeout 14400 (4h), --interval 60, --repo $PWD.

set -uo pipefail

BASE="origin/master"
REPO_DIR="$PWD"
TIMEOUT=14400
INTERVAL=60
LABEL=""

die() {
  echo "wait-for.sh: $*" >&2
  exit 2
}

# One line, always, on every terminal path.
finish() {
  local code="$1" verdict="$2" detail="$3"
  printf '%s: %s%s\n' "$verdict" "$detail" "${LABEL:+ [$LABEL]}"
  exit "$code"
}

MODE="${1:-}"
TARGET="${2:-}"
[ -n "$MODE" ] && [ -n "$TARGET" ] || die "usage: wait-for.sh branch <branch> | cmd '<shell>'"
shift 2

while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE="${2:-}"; shift 2 ;;
    --repo) REPO_DIR="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --interval) INTERVAL="${2:-}"; shift 2 ;;
    --label) LABEL="${2:-}"; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

case "$TIMEOUT$INTERVAL" in
  *[!0-9]*) die "--timeout and --interval take seconds" ;;
esac

# A caller who says origin/foo means the branch foo; the ref is rebuilt below either way.
TARGET="${TARGET#origin/}"

# Set by check_git: 1 when origin/<branch> has no local tracking ref.
unpushed=0

# MERGED <sha> / CLOSED / OPEN, or empty when there is no PR, no gh, or no network. Empty is not
# evidence of anything -- it just hands the decision to git.
check_pr_state() {
  command -v gh >/dev/null 2>&1 || return 0
  (cd "$REPO_DIR" 2>/dev/null &&
    gh pr view "$TARGET" --json state,mergeCommit \
      --jq '.state + (if .mergeCommit then " " + .mergeCommit.oid[0:8] else "" end)' 2>/dev/null)
}

check_git() {
  # A fetch that loses the ref-lock race just means this tick has stale refs; try again next one.
  git -C "$REPO_DIR" fetch --quiet origin 2>/dev/null || return 1

  local ref="refs/remotes/origin/$TARGET"
  if ! git -C "$REPO_DIR" rev-parse --verify --quiet "$ref" >/dev/null; then
    unpushed=1
    return 1
  fi
  unpushed=0

  git -C "$REPO_DIR" merge-base --is-ancestor "$ref" "$BASE" 2>/dev/null
}

# Distinguishes "not pushed yet" from a typo, once, early -- both look identical to check_git.
branch_on_origin() {
  git -C "$REPO_DIR" ls-remote --exit-code --heads origin "refs/heads/$TARGET" >/dev/null 2>&1
}

started=$(date +%s)
deadline=$((started + TIMEOUT))

case "$MODE" in
  branch)
    git -C "$REPO_DIR" rev-parse --git-dir >/dev/null 2>&1 ||
      finish 4 "ERROR" "not a git repository: $REPO_DIR"
    printf 'waiting: %s into %s (timeout %ss, polling %ss)%s\n' \
      "$TARGET" "$BASE" "$TIMEOUT" "$INTERVAL" "${LABEL:+ [$LABEL]}"
    ;;
  cmd)
    printf 'waiting: `%s` to exit 0 (timeout %ss, polling %ss)%s\n' \
      "$TARGET" "$TIMEOUT" "$INTERVAL" "${LABEL:+ [$LABEL]}"
    ;;
  *) die "unknown mode: $MODE (expected 'branch' or 'cmd')" ;;
esac

tick=0
while :; do
  tick=$((tick + 1))

  if [ "$MODE" = "cmd" ]; then
    if eval "$TARGET" >/dev/null 2>&1; then
      finish 0 "CLEAR" "predicate succeeded after $(( $(date +%s) - started ))s"
    fi
  else
    state=$(check_pr_state)
    case "$state" in
      MERGED*)
        finish 0 "CLEAR" \
          "$TARGET merged (${state#MERGED }) after $(( $(date +%s) - started ))s -- rebase onto $BASE"
        ;;
      CLOSED)
        finish 5 "ABANDONED" "the PR for $TARGET was closed unmerged; this will never clear"
        ;;
    esac

    # Also consult git: it covers a direct push to the base, and everything before a PR exists.
    if check_git; then
      sha=$(git -C "$REPO_DIR" rev-parse --short "refs/remotes/origin/$TARGET" 2>/dev/null)
      finish 0 "CLEAR" "$TARGET ($sha) is in $BASE after $(( $(date +%s) - started ))s"
    fi

    # First tick only: no PR and nothing on origin means either "not pushed yet" or a bad name.
    if [ "$tick" -eq 1 ] && [ -z "$state" ] && [ "$unpushed" = "1" ] && ! branch_on_origin; then
      printf 'notice: no PR, and origin/%s does not exist -- waiting for it to be pushed. If that name is wrong, this waits out the full %ss.\n' \
        "$TARGET" "$TIMEOUT"
    fi
  fi

  now=$(date +%s)
  if [ "$now" -ge "$deadline" ]; then
    if [ "$MODE" = "branch" ] && [ "$unpushed" = "1" ]; then
      finish 3 "TIMEOUT" "origin/$TARGET never appeared in ${TIMEOUT}s -- was it pushed?"
    fi
    finish 3 "TIMEOUT" "still not clear after ${TIMEOUT}s"
  fi

  # Quarter-hourly proof of life, so a long wait's output is not one line for hours.
  if [ $((tick * INTERVAL % 900)) -lt "$INTERVAL" ] && [ "$tick" -gt 1 ]; then
    printf 'still waiting: %ss elapsed, %ss left\n' "$((now - started))" "$((deadline - now))"
  fi

  sleep "$INTERVAL"
done
