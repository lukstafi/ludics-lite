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
#     gate, and it fired for real during the 2026-08-17 GitHub outage on an approved PR;
#   - during an incident GitHub does not fail cleanly, it fails HALF the time: on 2026-08-17 about
#     one call in two came back "503 No server is currently available to service your request" for
#     an hour, so a single attempt is a coin flip and every call goes through gh_retry — which
#     retries 5xx and that body text, and never a 4xx (a 4xx is the API answering);
#   - a call that exhausted its retries is a TRANSPORT failure, and reporting it as a fact about
#     the PR is the worst thing this script can do: "no review thread starts at comment N" was
#     printed during that outage for three threads that all existed, because the paginated GraphQL
#     lookup 503'd — it reads as a finding ("someone resolved it", "the id is wrong") and sends the
#     caller hunting. So every claim (no new activity, no such thread, not approved, wrong repo) is
#     printed ONLY on a call that succeeded; otherwise the message and the exit code say transport.
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
#   pr-review.sh retry [--read] <gh args...>
#                                          # any other gh call (pr comment, pr merge, api) with the
#                                          # same retry policy, instead of a hand-rolled loop
#
# Exit codes: 0 the command did what it says (and any fact it printed came from a call that
#             answered); 1 the fact does not hold (the window stayed quiet, no such thread, the API
#             rejected the request); 2 usage/configuration error; 3 TRANSPORT failure — nothing was
#             learned, so retry rather than concluding anything. 1 and 3 are kept apart everywhere.
#
# Env: REPO=owner/name (else the <pr> argument, else the cwd's checkout, else the per-PR cache),
#      REVIEWER=login-prefix (default: codex app), WATCH_INTERVAL=seconds between polls (default
#      90), WATCH_TIMEOUT=seconds to watch (900), SHIP_PR_STATE_DIR=where the cache lives,
#      SHIP_PR_API_ATTEMPTS=tries per gh call (4), SHIP_PR_API_BACKOFF=first pause in seconds (5,
#      doubling to a 20s cap: ~35s of retrying before a call is declared dead).

set -uo pipefail

REPO="${REPO:-}"
REVIEWER="${REVIEWER:-chatgpt-codex-connector}"
STATE_DIR="${SHIP_PR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ship-pr}"
CACHE="$STATE_DIR/repo-by-pr"

API_ATTEMPTS="${SHIP_PR_API_ATTEMPTS:-4}"
API_BACKOFF="${SHIP_PR_API_BACKOFF:-5}"

# The exit code carries the difference the messages carry: 1 = the fact does not hold, 2 = the
# caller or the environment is wrong, 3 = the API never answered so nothing is known.
fail() {
  local rc="$1"
  shift
  echo "pr-review.sh: $*" >&2
  exit "$rc"
}

die() { fail 2 "$@"; }

warn() { echo "pr-review.sh: $*" >&2; }

# --- transport retries ----------------------------------------------------------------------
# Only TRANSPORT failures are retried. A 4xx is the API ANSWERING — no such comment, no such PR,
# no permission — and retrying it spends the backoff to print the same thing.
#
# Writes are retried on a narrower set than reads: a gateway status (502/503/504, and the
# "No server is currently available" body GitHub's front door emits) means the request was refused
# before a backend ran it, so a second attempt cannot duplicate a reply that landed. An ambiguous
# failure — a 500, a dropped connection, an unparseable body — might be a write that DID land, so
# a write stops there and says so instead of posting twice.
#
# GH_ERR is the stderr of the last gh_retry attempt, for callers that report the reason. It lives
# in a file as well as in a variable: every feed read here happens inside a command substitution,
# i.e. a subshell, so a variable set by the failing call is gone by the time the caller composes
# its message — which is how the first cut of this printed "the API did not answer ()", reason
# blank.
GH_ERR=""
GH_ERR_FILE="${TMPDIR:-/tmp}/pr-review-err.$$"
trap 'rm -f "$GH_ERR_FILE"' EXIT

gateway_failure() {
  case "$1" in
  *"No server is currently available"* | *"HTTP 502"* | *"HTTP 503"* | *"HTTP 504"*) return 0 ;;
  *"Bad gateway"* | *"Service Unavailable"* | *"Gateway Timeout"*) return 0 ;;
  esac
  return 1
}

# Did the API answer the request (4xx), or just fail? A write that stopped on a non-gateway error
# is in the second case and must be reported as ambiguous — "rejected, check the comment id" would
# be a claim about the request that a 500 does not support.
api_rejection() {
  # Only an explicit 4xx counts: gh spells one out ("gh: Not Found (HTTP 404)"), and anything
  # without a status is a failure whose effect is unknown.
  case "$1" in *"HTTP 4"[0-9][0-9]*) return 0 ;; esac
  return 1
}

transient_failure() {
  gateway_failure "$1" && return 0
  case "$1" in
  *"HTTP 4"[0-9][0-9]*) return 1 ;; # the API answered; a retry answers the same, slower
  esac
  # Everything else — a 500, a GraphQL "Something went wrong while executing your query", a reset
  # connection, an HTML error page jq could not parse — is retried, because a read has nothing to
  # duplicate and the alternative is presenting the failure as an empty feed.
  return 0
}

# gh_retry <read|write> <gh args...>: runs gh, prints its stdout, and returns 0 on success,
# 3 when a retryable failure outlived the attempts, 1 when the failure was the API's answer.
gh_retry() {
  local mode="$1"
  shift
  local attempt=1 rc out tmp retryable delay="$API_BACKOFF"
  tmp=$(mktemp "${TMPDIR:-/tmp}/pr-review.XXXXXX" 2>/dev/null) || tmp=/dev/null
  GH_ERR=""
  while :; do
    out=$(gh "$@" 2>"$tmp")
    rc=$?
    [ "$tmp" = /dev/null ] || GH_ERR=$(cat "$tmp" 2>/dev/null)
    if [ "$rc" -eq 0 ]; then
      [ "$tmp" = /dev/null ] || rm -f "$tmp"
      : >"$GH_ERR_FILE" 2>/dev/null # a later message must not quote an error this call outlived
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    fi
    printf '%s' "${GH_ERR%%$'\n'*}" >"$GH_ERR_FILE" 2>/dev/null
    if [ "$mode" = write ]; then
      gateway_failure "$GH_ERR $out"
    else
      transient_failure "$GH_ERR $out"
    fi
    retryable=$?
    if [ "$retryable" -ne 0 ] || [ "$attempt" -ge "$API_ATTEMPTS" ]; then
      [ "$tmp" = /dev/null ] || rm -f "$tmp"
      [ "$retryable" -eq 0 ] && return 3
      return 1
    fi
    warn "gh ${1:-api} failed (attempt $attempt/$API_ATTEMPTS), retrying in ${delay}s: $(gh_err_line)"
    sleep "$delay"
    [ "$delay" -ge 20 ] || delay=$((delay * 2))
    attempt=$((attempt + 1))
  done
}

# One line of the last error, for messages that must stay one line. Reads the file, so it works in
# the parent shell as well as inside the subshell that made the call.
gh_err_line() {
  local line
  line=$(cat "$GH_ERR_FILE" 2>/dev/null)
  printf '%s' "${line:-${GH_ERR%%$'\n'*}}"
}

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

# 0 = that repo really has that PR, 1 = it does not, 3 = the API did not answer, so neither is
# known — the caller must not turn an outage into "wrong repo".
verify_repo() {
  local n rc
  n=$(gh_retry read api "repos/$1/pulls/$2" --jq .number)
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  [ "$n" = "$2" ]
}

resolve_repo() {
  local pr="$1" cached rc
  if [ -n "$REPO" ]; then
    cache_put "$pr" "$REPO"
    return 0
  fi
  REPO=$(repo_from_cwd) && [ -n "$REPO" ] && {
    cache_put "$pr" "$REPO"
    return 0
  }
  REPO=""
  if cached=$(cache_get "$pr"); then
    verify_repo "$cached" "$pr"
    rc=$?
    case "$rc" in
    0)
      REPO="$cached"
      return 0
      ;;
    3) fail 3 "cannot verify PR $pr against the cached repo $cached — the API did not answer" \
      "after $API_ATTEMPTS attempts ($(gh_err_line)). This is TRANSPORT, not a wrong repo:" \
      "retry, or name the repo as owner/name#$pr to skip the verification entirely." ;;
    esac
  fi
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
# Returns nonzero printing NOTHING when the request or the parse fails, so that a caller can tell a
# failed read from an empty feed — collapsing the two is how an outage reads as "reviewer quiet"
# and, worse, as "not approved yet". A 5xx mid-pagination discards the pages already fetched and
# starts over, which costs a repeat of a few GETs and buys a feed that is whole or absent, never
# truncated at the page the outage hit.
api_list() {
  local raw rc
  raw=$(gh_retry read api --paginate "repos/$REPO/$1")
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  jq -s '[.[] | if type == "array" then .[] else empty end]' <<<"$raw" 2>/dev/null || return 4
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
    warn "API error reading PR $pr feed(s):$bad after $API_ATTEMPTS attempts each" \
      "($(gh_err_line)) — this round is UNKNOWN, not quiet"
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
  # Exit 3 on unknown so a caller gating a merge on `status` cannot read a failed read as a quiet
  # "not approved yet" — the same collapse api_list refuses to make. 3 rather than 2, because a
  # usage error (2) is the caller's to fix and this one is the API's to recover from.
  [ "$tok" = unknown ] && return 3
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
  local start=$SECONDS was now out rc next quiet=0 saw=0 blind=0

  was=$(status_token "$pr")
  echo "watching PR $REPO#$pr from status '$was', every ${interval}s for up to ${timeout}s" >&2

  while :; do
    out=$(cmd_poll "$pr" "$mark")
    rc=$?
    # A failed API round yields no watermark; keeping the old one stops a transient error from
    # resetting to 0 and replaying the whole backlog as if it were a new round.
    next=$(sed -n 's/^watermark: //p' <<<"$out" | tail -1)
    case "$next" in [0-9]*,[0-9]*,[0-9]*) mark="$next" ;; esac
    if [ "$rc" -eq 0 ]; then
      saw=1
      blind=0
    else
      blind=$((blind + 1))
    fi

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
  # The window ending blind is not the window being quiet either: a round posted during those last
  # unreadable polls is exactly what a watcher is here to catch, so the ONLY honest report is that
  # the tail was not observed. Reporting "no new activity" from a window whose last reads failed is
  # how a review loop stalls silently — the thing this script exists to prevent, in slow motion.
  if [ "$blind" -gt 0 ]; then
    echo "the last $blind poll(s) of the ${timeout}s window on PR $REPO#$pr did not answer, so the" \
      "tail of this window was NOT observed — nothing here says the reviewer stayed quiet; re-arm"
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
  gh_retry write api -X POST "repos/$REPO/pulls/$pr/comments/$id/replies" \
    -f body="$body

_🤖 Addressed by [Claude Code](https://claude.com/claude-code)_" --jq .html_url
  case "$?" in
  0) return 0 ;;
  3) fail 3 "reply to comment $id on PR $REPO#$pr did not go through — the API refused it at the" \
    "gateway on all $API_ATTEMPTS attempts ($(gh_err_line)). Nothing was posted, so retry;" \
    "a batch of replies fails one at a time, so check each one, not just the last." ;;
  *)
    api_rejection "$(gh_err_line)" &&
      fail 1 "reply to comment $id on PR $REPO#$pr was REJECTED, not dropped: $(gh_err_line)." \
        "Retrying prints the same thing — check the comment id and the PR."
    fail 3 "reply to comment $id on PR $REPO#$pr failed AMBIGUOUSLY: $(gh_err_line)." \
      "That is not a gateway refusal, so the reply may or may not have landed and this script" \
      "will not post it twice — read the thread, then retry only if it is not there."
    ;;
  esac
}

# Threads are addressed by node id, which is only reachable by matching a thread's FIRST comment.
# Prints "<node-id> <isResolved>" for the thread starting at comment $2. Exits 1 when the PR
# genuinely has no such thread, 2 when GraphQL never answered, and 4 when GraphQL rejected the
# query (a 4xx: bad repo, bad auth) — the caller must not report either of the last two as a
# missing thread and send the user hunting for a comment id that is fine. reviewThreads
# is itself a 100-item page: a PR that ran to many rounds keeps its LATEST threads — the ones
# actually being addressed — past the first page, so page until the id is found or the pages run
# out. The page cap only bounds a cursor that stops advancing; it is far above any real PR.
#
# "Not found" is only concluded when EVERY page came back: one 503'd page is a hole the id could be
# hiding in, and reporting that as a missing thread is the false finding this whole file guards
# against. Each page therefore retries, and an unanswered page aborts the search as transport.
find_thread() {
  local pr="$1" id="$2" cursor="" after page resp hit rc
  for page in $(seq 1 20); do
    [ -z "$cursor" ] && after="" || after=", after:\"$cursor\""
    resp=$(gh_retry read api graphql -f query="
      query(\$owner:String!, \$name:String!, \$pr:Int!) {
        repository(owner:\$owner, name:\$name) { pullRequest(number:\$pr) {
          reviewThreads(first:100$after) {
            pageInfo { hasNextPage endCursor }
            nodes { id isResolved comments(first:1) { nodes { databaseId } } } } } } }" \
      -F owner="${REPO%%/*}" -F name="${REPO##*/}" -F pr="$pr" \
      --jq .data.repository.pullRequest.reviewThreads)
    rc=$?
    [ "$rc" -eq 1 ] && return 4
    [ "$rc" -eq 0 ] || return 2
    # A `data.repository.pullRequest` of null (GraphQL's way of erroring inside a 200) prints
    # nothing: the query did not run, so it is not evidence about the thread either.
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
  2) fail 3 "GraphQL did not answer for PR $REPO#$pr after $API_ATTEMPTS attempts per page" \
    "($(gh_err_line)) — thread resolution has no REST equivalent, so this is a RETRY, not a" \
    "missing thread: the threads are probably all there, and the reply (REST) may well have gone" \
    "through. Do NOT read this as someone else having resolved it or as a wrong comment id." ;;
  4) fail 2 "GraphQL REJECTED the thread lookup for PR $REPO#$pr: $(gh_err_line)." \
    "The search never ran, so this says nothing about comment $id — check the repo, the PR" \
    "number and \`gh auth status\` rather than the comment id." ;;
  *) fail 1 "no review thread starts at comment $id — every page of PR $REPO#$pr was read and" \
    "none of them begins there (this is a real answer, not a dropped request)" ;;
  esac
  # Already-resolved is the goal state, not a no-op worth an API write: replying then resolving a
  # thread twice across rounds is normal, and the mutation would just echo it back.
  case "$hit" in
  *" true") echo "true (already resolved)" && return 0 ;;
  esac
  # The mutation is idempotent — resolving a resolved thread just answers true — so it is retried
  # like a read, on anything short of the API rejecting it.
  gh_retry read api graphql -f query="mutation {
      resolveReviewThread(input:{threadId:\"${hit%% *}\"}) {
      thread { isResolved } } }" --jq .data.resolveReviewThread.thread.isResolved
  case "$?" in
  0) return 0 ;;
  3) fail 3 "resolveReviewThread did not answer for the thread at comment $id on PR $REPO#$pr" \
    "after $API_ATTEMPTS attempts ($(gh_err_line)); the thread was FOUND, so this is transport" \
    "only — retry when the API recovers, and the mutation is safe to repeat." ;;
  *) fail 1 "resolveReviewThread was rejected for the thread at comment $id on PR $REPO#$pr:" \
    "$(gh_err_line)" ;;
  esac
}

# Every gh call this skill makes wants the same policy, not just the ones wrapped above: the
# 2026-08-17 outage had a session hand-rolling `for i in 1 2 3; do … && break; sleep; done` around
# `gh pr comment` and `gh pr merge` five separate times. Run them through here instead. Default is
# the write policy (gateway failures only, so a merge or a comment cannot be sent twice from an
# ambiguous error); --read opts into the broader one for a plain GET.
cmd_retry() {
  local mode=write
  case "${1:-}" in
  --read) mode=read && shift ;;
  --write) shift ;;
  esac
  [ "${1:-}" = gh ] && shift # tolerate the leading `gh` a caller pastes in
  [ $# -gt 0 ] || die "usage: retry [--read] <gh args...>"
  gh_retry "$mode" "$@"
  case "$?" in
  0) return 0 ;;
  3) fail 3 "gh $1 did not go through after $API_ATTEMPTS attempts ($(gh_err_line));" \
    "the API never answered, so the outcome is UNKNOWN — confirm the state before retrying a" \
    "write, and never report the command as having failed to do its job." ;;
  *)
    api_rejection "$(gh_err_line)" && fail 1 "gh $1 was rejected: $(gh_err_line)"
    fail 3 "gh $1 failed AMBIGUOUSLY: $(gh_err_line). Not a gateway refusal, so a write may have" \
      "landed and this did not repeat it — confirm the state (over REST) before retrying."
    ;;
  esac
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
retry) shift && cmd_retry "$@" ;;
*) die "usage: pr-review.sh [--repo owner/name] {poll|watch|status|reply|resolve} <pr> ...
  pr-review.sh retry [--read] <gh args...>   # any other gh call, same retry policy
  <pr> is a number or owner/name#number; prefer owner/name#number for background invocations." ;;
esac
