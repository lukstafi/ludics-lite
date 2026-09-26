#!/usr/bin/env bash
# Fixture tests for wait-for.sh's branch mode, in scratch git repositories with a stub `gh` on
# PATH -- no network. Every wait runs with --timeout 0, so a case takes one tick: a PR the stub
# reports as merged clears it, and anything else ends in TIMEOUT.
#
# What it pins: which repository the PR is asked for. The branch is watched on origin, so its PR
# is looked up on origin's repository by URL, even when the checkout also has an `upstream` remote
# -- the one gh resolves to by itself without `gh repo set-default`, which would miss a squash
# merge on origin that git cannot see (ludics-lite#404 was the same bug in the ship-pr Stop hook).
# A checkout whose origin has no URL falls back to gh's default.
#
# Usage: test-wait-for.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

# One brace group, so bash parses this file WHOLE before its first line runs and an edit landing
# while a run is in flight cannot resume the shell at a shifted offset; the `exit` at the foot
# means the shell never comes back to the file for a next command (ludics-lite#10, #247);
# scripts/check-parse-guards.sh checks the shape.
{
HERE=$(cd "$(dirname "$0")" && pwd)
WAIT_FOR="$HERE/wait-for.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wait-for-test.XXXXXX") || exit 1
# Physical path, so the origin URL the stub is told to expect is the one git reports; on macOS
# $TMPDIR sits under /var, a link to /private/var.
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
trap 'rm -rf "$TMP"' EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_NOSYSTEM=1

# The stub answers a merged PR only when asked about FAKE_GH_REPO (empty: asked with no --repo),
# and for any other repository behaves as gh does for a branch with no PR there.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GH_LOG"
repo=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) repo="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ "$repo" = "$FAKE_GH_REPO" ] || { echo "no pull requests found" >&2; exit 1; }
echo "MERGED 1234abcd"
EOF
chmod +x "$TMP/bin/gh"
export PATH="$TMP/bin:$PATH"

pass=0
fail=0
check() {
  if [ "$1" = "$2" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$3" "$2" "$1"
  fi
}
check_contains() {
  case "$1" in
    *"$2"*) pass=$((pass + 1)) ;;
    *) fail=$((fail + 1)); printf 'FAIL: %s\n  expected to contain: %s\n  actual: %s\n' "$3" "$2" "$1" ;;
  esac
}

# A work checkout on `topic`, one commit past main; with an origin, topic is pushed there and NOT
# an ancestor of origin/main -- the shape a squash merge leaves, which only the PR can report.
make_checkout() {
  local dir="$1" with_origin="$2"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m base
  if [ "$with_origin" = yes ]; then
    git init -q --bare "$dir.origin.git"
    git -C "$dir" remote add origin "$dir.origin.git"
    git -C "$dir" push -q origin main
  fi
  git -C "$dir" checkout -q -b topic
  git -C "$dir" commit -q --allow-empty -m work
  [ "$with_origin" = yes ] && git -C "$dir" push -q origin topic
  return 0
}

run_wait() {
  local dir="$1"
  GH_LOG="$dir.gh-log"
  : >"$GH_LOG"
  export GH_LOG
  OUT=$("$WAIT_FOR" branch topic --base origin/main --repo "$dir" --timeout 0 --interval 1 2>&1)
  RC=$?
}

# ludics-lite#404's shape: origin is the fork, `upstream` its parent, no `gh repo set-default`.
# The PR merged on origin; asking gh's default would have asked upstream and timed out.
test_fork_checkout_asks_origin() {
  local dir="$TMP/fork"
  make_checkout "$dir" yes
  git -C "$dir" remote add upstream https://github.com/example/parent.git
  FAKE_GH_REPO="$dir.origin.git" run_wait "$dir"
  check "$RC" 0 "fork checkout: a PR merged on origin clears the wait"
  check_contains "$OUT" "CLEAR: topic merged (1234abcd)" "fork checkout: the PR reported the landing"
  check_contains "$(cat "$GH_LOG")" "--repo $dir.origin.git" "fork checkout: gh was asked about origin"
}

# Without an origin URL there is nothing to name, and gh's own resolution is all there is.
test_no_origin_falls_back_to_gh_default() {
  local dir="$TMP/bare"
  make_checkout "$dir" no
  FAKE_GH_REPO="" run_wait "$dir"
  check "$RC" 0 "no origin: gh's default repository is asked"
  check_contains "$OUT" "CLEAR: topic merged (1234abcd)" "no origin: the PR reported the landing"
  case "$(cat "$GH_LOG")" in
    *--repo*) check "has --repo" "no --repo" "no origin: gh was called without --repo" ;;
    *) check ok ok "no origin: gh was called without --repo" ;;
  esac
}

test_fork_checkout_asks_origin
test_no_origin_falls_back_to_gh_default

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
exit "$?"
}
