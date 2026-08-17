#!/usr/bin/env bash
# Review-loop helpers for the ship-pr skill: poll a PR for NEW reviewer activity, reply to an
# inline comment, resolve its thread, and check the approval reaction.
#
# The point of the script is that the polling traps live in code instead of in prose:
#   - app reviewers appear as "<name>[bot]", so the login is matched by PREFIX, never equality;
#   - your own replies bump review and comment counts, so "new" means id > watermark, not a delta;
#   - the comment APIs paginate at 30, so every list call paginates with per_page=100;
#   - empty/non-numeric API output makes [ "$n" -gt 0 ] abort, so no count is compared as an int;
#   - the three feeds number their items in SEPARATE id spaces (a review id is ~4.9e9 while an
#     inline-comment id is ~3.8e9), so one shared watermark takes the max from reviews and then
#     hides every inline finding — the watermark is per feed, an opaque comma-joined triple;
#   - reviewThreads paginates at 100 too, so a long-running PR's later threads are unaddressable
#     ("no review thread starts at comment N") unless the resolve lookup pages to the end;
#   - the repo cannot be inferred from the cwd in a BACKGROUND shell, and the skill's documented
#     `watch` invocation is a backgrounded one — so the repo travels in the PR argument
#     (owner/name#number) and is cached per PR number for the calls that follow;
#   - an API failure and a genuinely empty feed both render as `[]`, so a read that failed must
#     report UNKNOWN and never "no approval yet" — that is a silent false negative on the merge
#     gate, and it fired for real during the 2026-08-17 GitHub outage on an approved PR.
#
# REST vs GraphQL: everything on the polling and merge-gate path is REST, deliberately — GitHub's
# GraphQL endpoint 503s independently of REST, so a GraphQL-borne "no reaction yet" is a lie the
# merge gate would act on. `gh repo view` rides GraphQL, hence the local git-remote fallback.
# Thread resolution has no REST equivalent and stays on GraphQL, but reports transport failure as
# such instead of as "no such thread".
#
# Usage (<pr> is a number, or owner/name#number — prefer the latter, see the repo note below):
#   pr-review.sh [--repo owner/name] poll <pr> [watermark]
#                                          # new comments/reviews above the watermark; prints next
#   pr-review.sh watch <pr> [watermark]    # poll on a timer until a round lands; 0 = act, 1 = quiet
#   pr-review.sh status <pr>               # reaction gate: approved / reviewing / none / unknown
#   pr-review.sh reply <pr> <comment-id> <body>
#   pr-review.sh resolve <pr> <comment-id>
#
# Env: REPO=owner/name (else the <pr> argument, else the cwd's checkout, else the per-PR cache),
#      REVIEWER=login-prefix (default: codex app), WATCH_INTERVAL=seconds between polls (default
#      90), WATCH_TIMEOUT=seconds to watch (900), SHIP_PR_STATE_DIR=where the cache lives.

set -uo pipefail

REPO="${REPO:-}"
REVIEWER="${REVIEWER:-chatgpt-codex-connector}"
STATE_DIR="${SHIP_PR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ship-pr}"
CACHE="$STATE_DIR/repo-by-pr"

die() {
  echo "pr-review.sh: $*" >&2
  exit 2
}

warn() { echo "pr-review.sh: $*" >&2; }

# --- repo resolution ------------------------------------------------------------------------
# A background shell does not reliably start in the checkout, so cwd inference is the LAST resort
# among the sources the caller controls, not the first. Resolution happens after the PR argument
# is parsed, because that argument may carry the repo itself.

# Remembering the repo per PR number is what keeps a follow-up call (a reply, a resolve) working
# when only the first call spelled the repo out. A bare PR number is not unique across repos, so
# a cache hit is VERIFIED against the API before it is trusted — a wrong repo would post a reply
# onto an unrelated PR, which is worse than the error it is standing in for.
cache_get() {
  [ -f "$CACHE" ] || return 1
  local hit
  hit=$(awk -v n="$1" '$1 == n { r = $2 } END { if (r != "") print r }' "$CACHE" 2>/dev/null)
  [ -n "$hit" ] || return 1
  echo "$hit"
}

# Last write wins, and a concurrent watch on another PR can drop an entry by rewriting the file
# from a stale read. That costs a later cache MISS, never a wrong repo — the verify above is what
# makes losing an entry harmless. Skipping the no-op rewrite keeps most of that window shut, since
# a running `watch` re-resolves every round.
cache_put() {
  [ "$(cache_get "$1" 2>/dev/null)" = "$2" ] && return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || return 0
  local tmp="$CACHE.$$"
  {
    [ -f "$CACHE" ] && awk -v n="$1" '$1 != n' "$CACHE"
    echo "$1 $2"
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$CACHE" 2>/dev/null
  rm -f "$tmp" 2>/dev/null
  return 0
}

repo_from_cwd() {
  local url
  # `gh repo view` first: it honours remote.origin.gh-resolved, so a fork checkout keeps naming
  # whichever repo gh already decided the PRs live in.
  gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null | grep . && return 0
  # ... but it rides GraphQL, so fall back to the origin remote, which answers the same question
  # locally and stays up when GraphQL does not.
  url=$(git remote get-url origin 2>/dev/null) || return 1
  url="${url%.git}"
  case "$url" in *github.com[:/]*) ;; *) return 1 ;; esac
  url=$(echo "${url#*github.com}" | sed 's,^[:/],,')
  case "$url" in */*) echo "$url" ;; *) return 1 ;; esac
}

verify_repo() { [ "$(gh api "repos/$1/pulls/$2" --jq .number 2>/dev/null)" = "$2" ]; }

resolve_repo() {
  local pr="$1" cached
  if [ -n "$REPO" ]; then
    cache_put "$pr" "$REPO"
    return 0
  fi
  REPO=$(repo_from_cwd) && [ -n "$REPO" ] && {
    cache_put "$pr" "$REPO"
    return 0
  }
  REPO=""
  cached=$(cache_get "$pr") && verify_repo "$cached" "$pr" && {
    REPO="$cached"
    return 0
  }
  die "cannot tell which repo PR $pr belongs to." \
    "Pass it as owner/name#$pr (or --repo owner/name, or REPO=owner/name)." \
    "This usually means a BACKGROUND invocation: background shells do not start in the checkout," \
    "so cwd inference only works in the foreground. The skill's documented \`watch\` call is a" \
    "backgrounded one, which is why it always names the repo."
}

# Accept both a bare number and owner/name#number (the form PR URLs and cards use); anything else
# dies loudly. Without this, a malformed <pr> lands in the API path, api_list eats the error, and
# every feed reads back empty — the PR looks eternally quiet, which is exactly the false reading
# this script exists to prevent. Sets PR_NUM, and REPO from the argument or the fallbacks above.
pr_arg() {
  case "$1" in
  */*"#"*) REPO="${1%%#*}" ;;
  esac
  PR_NUM="${1##*#}"
  case "$PR_NUM" in
  '' | *[!0-9]*) die "PR must be a number or owner/name#number, got '$1'" ;;
  esac
  resolve_repo "$PR_NUM"
}

# --- feeds ------------------------------------------------------------------------------------

# Paginated GET returning a single flat JSON array (gh emits one array per page). An API error is
# an object, not an array: drop it rather than feeding jq a shape the filters cannot map over.
# Returns 1 printing NOTHING when the request or the parse fails, so that a caller can tell a
# failed read from an empty feed — collapsing the two is how an outage reads as "reviewer quiet"
# and, worse, as "not approved yet".
api_list() {
  local raw
  raw=$(gh api --paginate "repos/$REPO/$1" 2>/dev/null) || return 1
  jq -s '[.[] | if type == "array" then .[] else empty end]' <<<"$raw" 2>/dev/null || return 1
}

# One watermark per feed, comma-joined, because the feeds' ids are not comparable to each other.
mark_of() {
  local field
  field=$(echo "${1:-}" | cut -d, -f"$2")
  case "$field" in '' | *[!0-9]*) echo 0 ;; *) echo "$field" ;; esac
}

# Exits 3, and prints no watermark, when any feed failed to read: an unwritten watermark keeps the
# caller's old one, so a transient error cannot advance past findings it never saw.
cmd_poll() {
  local pr="${1:?usage: poll <pr> [watermark]}" mark="${2:-}"
  pr_arg "$pr"
  pr="$PR_NUM"
  local m_inline m_issue m_review
  m_inline=$(mark_of "$mark" 1)
  m_issue=$(mark_of "$mark" 2)
  m_review=$(mark_of "$mark" 3)

  local inline issue reviews bad=""
  inline=$(api_list "pulls/$pr/comments?per_page=100") || bad="$bad inline"
  issue=$(api_list "issues/$pr/comments?per_page=100") || bad="$bad summary"
  reviews=$(api_list "pulls/$pr/reviews?per_page=100") || bad="$bad reviews"
  if [ -n "$bad" ]; then
    warn "API error reading PR $pr feed(s):$bad — this round is UNKNOWN, not quiet"
    return 3
  fi

  jq -r --arg rev "$REVIEWER" --argjson since "$m_inline" '
    map(select((.user.login // "") | startswith($rev)) | select(.id > $since))
    | if length == 0 then "(no new inline comments)"
      else .[] | "--- inline id=\(.id) \(.path // "?"):\(.line // .original_line // 0) by \(.user.login)\n\(.body)"
      end' <<<"$inline"

  jq -r --arg rev "$REVIEWER" --argjson since "$m_issue" '
    map(select((.user.login // "") | startswith($rev)) | select(.id > $since))
    | .[] | "--- summary id=\(.id) by \(.user.login)\n\(.body)"' <<<"$issue"

  jq -r --arg rev "$REVIEWER" --argjson since "$m_review" '
    map(select((.user.login // "") | startswith($rev)) | select(.id > $since))
    | .[] | "--- review id=\(.id) state=\(.state) by \(.user.login)\n\(.body // "")"' <<<"$reviews"

  # Pass this back verbatim next time: per-feed maxima, so replies you post in this round cannot
  # read back as new findings and a big review id cannot mask a smaller comment id.
  echo "watermark: $(jq -s --argjson m "$m_inline" '[.[][].id // 0, $m] | max' <<<"$inline"),$(
    jq -s --argjson m "$m_issue" '[.[][].id // 0, $m] | max' <<<"$issue"),$(
    jq -s --argjson m "$m_review" '[.[][].id // 0, $m] | max' <<<"$reviews")"
}

# "unknown" is a fourth state, not a flavour of "none": the merge gate reads this, and a dropped
# request must never present as the reviewer withholding approval.
status_token() {
  local raw reactions
  raw=$(api_list "issues/$1/reactions?per_page=100") || {
    echo unknown
    return 0
  }
  reactions=$(jq -r --arg rev "$REVIEWER" '
      map(select((.user.login // "") | startswith($rev)) | .content) | unique | join(",")' \
    <<<"$raw" 2>/dev/null) || {
    echo unknown
    return 0
  }
  case "$reactions" in
  *"+1"*) echo approved ;;
  *eyes*) echo reviewing ;;
  *) echo none ;;
  esac
}

status_line() {
  case "$1" in
  approved) echo "approved (👍 from $REVIEWER)" ;;
  reviewing) echo "reviewing (👀 from $REVIEWER) — wait it out" ;;
  unknown) echo "UNKNOWN — the reactions API did not answer; this is NOT 'not approved', retry" ;;
  *) echo "no reaction from $REVIEWER yet" ;;
  esac
}

cmd_status() {
  pr_arg "${1:?usage: status <pr>}"
  local tok
  tok=$(status_token "$PR_NUM")
  status_line "$tok"
  # Exit nonzero on unknown so a caller gating a merge on `status` cannot read a failed read as a
  # quiet "not approved yet" — the same collapse api_list refuses to make.
  [ "$tok" = unknown ] && return 2
  return 0
}

# Poll on a timer so a round's arrival wakes the caller instead of the caller re-deriving this loop.
# Exits 0 with something to act on (a round's findings, or the reaction reaching/leaving approval),
# 1 having stayed quiet for the whole window — in both cases the last line is a watermark to resume
# from, with poll's semantics. It exits 3 instead when it never managed to read the PR at all, so
# that "the reviewer stayed quiet" and "I was blind for the whole window" stay distinguishable —
# only the first is a reason to stop watching. Run it in the Bash tool's background mode: the
# default window is longer than that tool's foreground ceiling. Background shells do not start in
# the checkout, so give this the repo: `watch owner/name#<pr>`.
cmd_watch() {
  local pr="${1:?usage: watch <pr> [watermark]}" mark="${2:-}"
  pr_arg "$pr"
  pr="$PR_NUM"
  local interval="${WATCH_INTERVAL:-90}" timeout="${WATCH_TIMEOUT:-900}"
  local start=$SECONDS was now out rc next quiet=0 saw=0

  was=$(status_token "$pr")
  echo "watching PR $REPO#$pr from status '$was', every ${interval}s for up to ${timeout}s" >&2

  while :; do
    out=$(cmd_poll "$pr" "$mark")
    rc=$?
    # A failed API round yields no watermark; keeping the old one stops a transient error from
    # resetting to 0 and replaying the whole backlog as if it were a new round.
    next=$(sed -n 's/^watermark: //p' <<<"$out" | tail -1)
    case "$next" in [0-9]*,[0-9]*,[0-9]*) mark="$next" ;; esac
    [ "$rc" -eq 0 ] && saw=1

    # A round's stdout is byte-identical to poll's, watermark last, so a caller can consume watch
    # and poll the same way; the reaction is context, not the finding, so it goes to stderr.
    if [ "$rc" -eq 0 ] && grep -q '^--- ' <<<"$out"; then
      echo "status: $(status_line "$(status_token "$pr")")" >&2
      echo "$out"
      return 0
    fi

    now=$(status_token "$pr")
    if [ "$now" = unknown ]; then
      # Neither approval nor retraction can be concluded from a read that did not happen; hold the
      # previous status and keep polling.
      warn "reactions unreadable this round on PR $REPO#$pr; holding status '$was'"
    elif [ "$now" = approved ]; then
      status_line "$now"
      echo "watermark: $mark"
      return 0
    # A reaction that vanishes is either a retracted 👀 or a dropped API call; make it prove itself
    # over two rounds before reporting it, since a single round's read can be a false negative.
    elif [ "$was" = reviewing ] && [ "$now" = none ]; then
      quiet=$((quiet + 1))
      if [ "$quiet" -ge 2 ]; then
        echo "reaction from $REVIEWER was retracted (was 👀, now none)"
        echo "watermark: $mark"
        return 0
      fi
    else
      quiet=0
      was="$now"
    fi

    [ $((SECONDS - start + interval)) -le "$timeout" ] || break
    sleep "$interval"
  done

  if [ "$saw" -eq 0 ]; then
    echo "could not read PR $REPO#$pr for the whole ${timeout}s window — NOT the same as quiet;" \
      "nothing was observed, so re-arm the watch rather than concluding the reviewer is silent"
    echo "watermark: $mark"
    return 3
  fi
  echo "no new activity in ${timeout}s; status: $(status_line "$(status_token "$pr")")"
  echo "watermark: $mark"
  return 1
}

# Replies carry the automated-work marker so a human scanning the thread knows what wrote them.
cmd_reply() {
  local pr="${1:?usage: reply <pr> <comment-id> <body>}" id="${2:?comment-id}" body="${3:?body}"
  pr_arg "$pr"
  pr="$PR_NUM"
  gh api -X POST "repos/$REPO/pulls/$pr/comments/$id/replies" \
    -f body="$body

_🤖 Addressed by [Claude Code](https://claude.com/claude-code)_" --jq .html_url
}

# Threads are addressed by node id, which is only reachable by matching a thread's FIRST comment.
# Prints "<node-id> <isResolved>" for the thread starting at comment $2. Exits 1 when the PR
# genuinely has no such thread and 2 when GraphQL did not answer — the caller must not report an
# outage as a missing thread and send the user hunting for a comment id that is fine. reviewThreads
# is itself a 100-item page: a PR that ran to many rounds keeps its LATEST threads — the ones
# actually being addressed — past the first page, so page until the id is found or the pages run
# out. The page cap only bounds a cursor that stops advancing; it is far above any real PR.
find_thread() {
  local pr="$1" id="$2" cursor="" after page resp hit
  for page in $(seq 1 20); do
    [ -z "$cursor" ] && after="" || after=", after:\"$cursor\""
    resp=$(gh api graphql -f query="
      query(\$owner:String!, \$name:String!, \$pr:Int!) {
        repository(owner:\$owner, name:\$name) { pullRequest(number:\$pr) {
          reviewThreads(first:100$after) {
            pageInfo { hasNextPage endCursor }
            nodes { id isResolved comments(first:1) { nodes { databaseId } } } } } } }" \
      -F owner="${REPO%%/*}" -F name="${REPO##*/}" -F pr="$pr" \
      --jq .data.repository.pullRequest.reviewThreads) || return 2
    [ -n "$resp" ] || return 2

    hit=$(jq -r --argjson id "$id" '.nodes[]
      | select(.comments.nodes[0].databaseId == $id) | "\(.id) \(.isResolved)"' <<<"$resp") || return 2
    if [ -n "$hit" ]; then
      echo "$hit"
      return 0
    fi

    [ "$(jq -r '.pageInfo.hasNextPage' <<<"$resp")" = true ] || return 1
    cursor=$(jq -r '.pageInfo.endCursor // ""' <<<"$resp")
    [ -n "$cursor" ] || return 1
  done
  return 1
}

cmd_resolve() {
  local pr="${1:?usage: resolve <pr> <comment-id>}" id="${2:?comment-id}" hit rc
  pr_arg "$pr"
  pr="$PR_NUM"
  case "$id" in '' | *[!0-9]*) die "comment-id must be numeric, got '$id'" ;; esac
  hit=$(find_thread "$pr" "$id")
  rc=$?
  case "$rc" in
  0) ;;
  2) die "GraphQL did not answer for PR $REPO#$pr — thread resolution has no REST equivalent," \
    "so this is a RETRY, not a missing thread. The reply (REST) may well have gone through." ;;
  *) die "no review thread starts at comment $id (searched every page of PR $REPO#$pr)" ;;
  esac
  # Already-resolved is the goal state, not a no-op worth an API write: replying then resolving a
  # thread twice across rounds is normal, and the mutation would just echo it back.
  case "$hit" in
  *" true") echo "true (already resolved)" && return 0 ;;
  esac
  gh api graphql -f query="mutation { resolveReviewThread(input:{threadId:\"${hit%% *}\"}) {
      thread { isResolved } } }" --jq .data.resolveReviewThread.thread.isResolved ||
    die "resolveReviewThread mutation failed (GraphQL); retry when the API recovers"
}

# --repo mirrors gh's own flag, so reaching for it out of gh habit works instead of hitting usage.
case "${1:-}" in
--repo) REPO="${2:?--repo owner/name}" && shift 2 ;;
--repo=*) REPO="${1#--repo=}" && shift ;;
esac

case "${1:-}" in
poll) shift && cmd_poll "$@" ;;
watch) shift && cmd_watch "$@" ;;
status) shift && cmd_status "$@" ;;
reply) shift && cmd_reply "$@" ;;
resolve) shift && cmd_resolve "$@" ;;
*) die "usage: pr-review.sh [--repo owner/name] {poll|watch|status|reply|resolve} <pr> ...
  <pr> is a number or owner/name#number; prefer owner/name#number for background invocations." ;;
esac
