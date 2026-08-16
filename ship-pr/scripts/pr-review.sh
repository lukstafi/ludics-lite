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
#     ("no review thread starts at comment N") unless the resolve lookup pages to the end.
#
# Usage:
#   pr-review.sh poll <pr> [watermark]    # new comments/reviews above the watermark; prints next
#   pr-review.sh watch <pr> [watermark]   # poll on a timer until a round lands; 0 = act, 1 = quiet
#   pr-review.sh status <pr>              # reaction gate: approved / reviewing / none
#   pr-review.sh reply <pr> <comment-id> <body>
#   pr-review.sh resolve <pr> <comment-id>
#
# Env: REPO=owner/name (default: the repo of the cwd), REVIEWER=login-prefix (default: codex app),
#      WATCH_INTERVAL=seconds between polls (default 90), WATCH_TIMEOUT=seconds to watch (900).

set -uo pipefail

REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)}"
REVIEWER="${REVIEWER:-chatgpt-codex-connector}"

die() {
  echo "pr-review.sh: $*" >&2
  exit 2
}

[ -n "$REPO" ] || die "cannot tell which repo: run inside the checkout or pass REPO=owner/name"

# Paginated GET returning a single flat JSON array (gh emits one array per page). An API error is
# an object, not an array: drop it rather than feeding jq a shape the filters cannot map over.
api_list() {
  gh api --paginate "repos/$REPO/$1" 2>/dev/null |
    jq -s '[.[] | if type == "array" then .[] else empty end]'
}

# One watermark per feed, comma-joined, because the feeds' ids are not comparable to each other.
mark_of() {
  local field
  field=$(echo "${1:-}" | cut -d, -f"$2")
  case "$field" in '' | *[!0-9]*) echo 0 ;; *) echo "$field" ;; esac
}

cmd_poll() {
  local pr="${1:?usage: poll <pr> [watermark]}" mark="${2:-}"
  local m_inline m_issue m_review
  m_inline=$(mark_of "$mark" 1)
  m_issue=$(mark_of "$mark" 2)
  m_review=$(mark_of "$mark" 3)

  local inline issue reviews
  inline=$(api_list "pulls/$pr/comments?per_page=100")
  issue=$(api_list "issues/$pr/comments?per_page=100")
  reviews=$(api_list "pulls/$pr/reviews?per_page=100")

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

status_token() {
  local reactions
  reactions=$(api_list "issues/$1/reactions?per_page=100" |
    jq -r --arg rev "$REVIEWER" '
      map(select((.user.login // "") | startswith($rev)) | .content) | unique | join(",")')
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
  *) echo "no reaction from $REVIEWER yet" ;;
  esac
}

cmd_status() {
  status_line "$(status_token "${1:?usage: status <pr>}")"
}

# Poll on a timer so a round's arrival wakes the caller instead of the caller re-deriving this loop.
# Exits 0 with something to act on (a round's findings, or the reaction reaching/leaving approval),
# 1 having stayed quiet for the whole window — in both cases the last line is a watermark to resume
# from, with poll's semantics. Run it in the Bash tool's background mode: the default window is
# longer than that tool's foreground ceiling.
cmd_watch() {
  local pr="${1:?usage: watch <pr> [watermark]}" mark="${2:-}"
  local interval="${WATCH_INTERVAL:-90}" timeout="${WATCH_TIMEOUT:-900}"
  local start=$SECONDS was now out next quiet=0

  was=$(status_token "$pr")
  echo "watching PR $pr from status '$was', every ${interval}s for up to ${timeout}s" >&2

  while :; do
    out=$(cmd_poll "$pr" "$mark")
    # A failed API round yields no watermark; keeping the old one stops a transient error from
    # resetting to 0 and replaying the whole backlog as if it were a new round.
    next=$(sed -n 's/^watermark: //p' <<<"$out" | tail -1)
    case "$next" in [0-9]*,[0-9]*,[0-9]*) mark="$next" ;; esac

    # A round's stdout is byte-identical to poll's, watermark last, so a caller can consume watch
    # and poll the same way; the reaction is context, not the finding, so it goes to stderr.
    if grep -q '^--- ' <<<"$out"; then
      echo "status: $(status_line "$(status_token "$pr")")" >&2
      echo "$out"
      return 0
    fi

    now=$(status_token "$pr")
    if [ "$now" = approved ]; then
      status_line "$now"
      echo "watermark: $mark"
      return 0
    fi
    # A reaction that vanishes is either a retracted 👀 or a dropped API call; make it prove itself
    # over two rounds before reporting it, since api_list renders an error as an empty list.
    if [ "$was" = reviewing ] && [ "$now" = none ]; then
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

  echo "no new activity in ${timeout}s; status: $(status_line "$(status_token "$pr")")"
  echo "watermark: $mark"
  return 1
}

# Replies carry the automated-work marker so a human scanning the thread knows what wrote them.
cmd_reply() {
  local pr="${1:?usage: reply <pr> <comment-id> <body>}" id="${2:?comment-id}" body="${3:?body}"
  gh api -X POST "repos/$REPO/pulls/$pr/comments/$id/replies" \
    -f body="$body

_🤖 Addressed by [Claude Code](https://claude.com/claude-code)_" --jq .html_url
}

# Threads are addressed by node id, which is only reachable by matching a thread's FIRST comment.
# Prints "<node-id> <isResolved>" for the thread starting at comment $2, or nothing. reviewThreads
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
      --jq .data.repository.pullRequest.reviewThreads) || return 1
    [ -n "$resp" ] || return 1

    hit=$(jq -r --argjson id "$id" '.nodes[]
      | select(.comments.nodes[0].databaseId == $id) | "\(.id) \(.isResolved)"' <<<"$resp")
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
  local pr="${1:?usage: resolve <pr> <comment-id>}" id="${2:?comment-id}" hit
  case "$id" in '' | *[!0-9]*) die "comment-id must be numeric, got '$id'" ;; esac
  hit=$(find_thread "$pr" "$id") ||
    die "no review thread starts at comment $id (searched every page of PR $pr)"
  # Already-resolved is the goal state, not a no-op worth an API write: replying then resolving a
  # thread twice across rounds is normal, and the mutation would just echo it back.
  case "$hit" in
  *" true") echo "true (already resolved)" && return 0 ;;
  esac
  gh api graphql -f query="mutation { resolveReviewThread(input:{threadId:\"${hit%% *}\"}) {
      thread { isResolved } } }" --jq .data.resolveReviewThread.thread.isResolved
}

case "${1:-}" in
poll) shift && cmd_poll "$@" ;;
watch) shift && cmd_watch "$@" ;;
status) shift && cmd_status "$@" ;;
reply) shift && cmd_reply "$@" ;;
resolve) shift && cmd_resolve "$@" ;;
*) die "usage: pr-review.sh {poll|watch|status|reply|resolve} <pr> ..." ;;
esac
