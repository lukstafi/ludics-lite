#!/usr/bin/env bash
# Review-loop helpers for the ship-pr skill: poll a PR for NEW reviewer activity, reply to an
# inline comment, resolve its thread, and check the approval reaction.
#
# The point of the script is that the polling traps live in code instead of in prose:
#   - app reviewers appear as "<name>[bot]", so the login is matched by PREFIX, never equality;
#   - your own replies bump review and comment counts, so "new" means id > watermark, not a delta;
#   - the comment APIs paginate at 30, so every list call paginates with per_page=100;
#   - a just-submitted review shows up in pulls/<n>/reviews BEFORE its inline comments reach the
#     flat pulls/<n>/comments listing (2026-08-20, #396 review 4985620117: three findings readable
#     under the review's own comments endpoint while the flat list still omitted them, and the
#     round printed "(no new inline comments)" beside the review it had just detected) — so a
#     round that sees a new review re-reads pulls/<n>/reviews/<id>/comments and merges by comment
#     id, and a failure of THAT read fails the whole round rather than dropping the findings;
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
#     printed ONLY on a call that succeeded; otherwise the message and the exit code say transport;
#   - a reaction is a LEVEL, not an event, and the app does not always take its 👀 back: on
#     2026-08-17 (#364) a 👀 added at 18:13:51Z outlived the review it announced (18:26:06Z), and
#     three consecutive 15-minute `watch` windows then reported "reviewing — wait it out" over a PR
#     nothing was reading. 45 minutes went to a signal carrying no information, and the loop only
#     moved after a hand-posted "@codex review". So a 👀 counts as in flight only while it is NEWER
#     than the reviewer's last word (a review OR its summary comment); once the reviewer has spoken,
#     the 👀 describes a round that has already landed and is spent;
#   - the reviewer's own utterances are that clock, NOT the head commit: a 👀 raised just before
#     your next push is a round that is genuinely running (seen live on #358 the same evening — 👀
#     at 20:34:13Z, head committed 20:35:01Z), so "older than the head commit" would declare an
#     in-flight round spent and nudge on top of it;
#   - whether the reviewer has SEEN the head is a SHA equality, not a time comparison: every review
#     records the commit_id it was submitted against, so comparing that to .head.sha answers the
#     question exactly — no guessing at a push time, and immune to a commit whose author date long
#     predates the push that delivered it;
#   - and patience is bounded on BOTH sides, because a stall reads the same from either: a review
#     that never starts and a 👀 that never lands both end with a verdict to nudge rather than with
#     another silent hold. "Wait it out" is only honest while something is actually running.
#
# The `merge` command exists for the same reason as the rest of this file: what the merge step has
# to READ before it acts does not survive as prose. It reads the head commit's check-runs and
# REFUSES on a build check that concluded failure (ahrefs/ocannl#694 — seven merges onto a master
# that did not compile, each PR carrying its own red run), and it absorbs the merge traps: GitHub
# recomputes a PR's mergeability asynchronously after every push, and until that finishes `gh pr
# merge` fails with "Pull request is not mergeable: the merge commit cannot be cleanly created" —
# byte-identical to a genuine conflict. On ocannl-staging#373 (2026-08-18) that fired seconds after
# pushing the conflict-RESOLUTION merge commit; re-reading .mergeable moments later gave true and
# the retried merge landed. So it polls .mergeable over REST until it is non-null before calling
# that failure base drift (null = still computing; only a persisting false is a conflict), and it
# confirms `merged` over REST afterwards, because `gh pr merge` exits 0 having merely ENABLED
# auto-merge when the base carries required checks.
#
# The last thing `merge` reads before acting is how far the branch has fallen BEHIND its base,
# because a review is only ever about the code it was run against. On 2026-08-28
# (ocannl-staging#488) a merge was one keystroke away over a base 136 commits stale after SIXTEEN
# review rounds; master had meanwhile edited the very file the PR changed, and what caught it was a
# hand-run `git diff origin/master..HEAD --stat` whose 258 files and 14k deletions were visibly not
# the two-file branch. Nothing on the merge path had a reason to notice: the checks were green (on
# the stale head), the reviewer had approved (the stale diff), and `mergeable` was true (no textual
# conflict — semantic drift does not produce one). So the count is read from the compare API and
# WARNED about. It does not refuse: rebasing before merging is already the repo convention, so this
# is the backstop for the pass where that was forgotten, and refusing on a number GitHub computes
# would strand merges whose drift is genuinely irrelevant.
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
#   pr-review.sh status <pr>               # merge gate + who owes what: approved / reviewing /
#                                          # stalled / expected / idle / unknown
#   pr-review.sh checks <pr> [--wait]      # the BUILD signal on the head commit: green / red /
#                                          # no verdict yet / absent
#   pr-review.sh merge <pr> [--override "<why this red is unrelated>"] [--wait]
#                           [--allow-no-verdict]
#                                          # checks, then merge; refuses on red without --override,
#                                          # on NO verdict without --allow-no-verdict, and WARNS
#                                          # loudly when the branch is far behind its base
#   pr-review.sh base [owner/name] [branch]
#                                          # is the branch you are about to work off CI-green?
#   pr-review.sh reply <pr> <comment-id> <body>
#   pr-review.sh resolve <pr> <comment-id>
#   pr-review.sh comment <pr> <body>       # a plain PR comment, for what has no thread to reply in:
#                                          # a review SUMMARY's findings, or a '@codex review' nudge
#   pr-review.sh retry [--read] <gh args...>
#                                          # any other gh call (pr merge, api) with the same retry
#                                          # policy, instead of a hand-rolled loop
#
# Exit codes: 0 the command did what it says (and any fact it printed came from a call that
#             answered); 1 the fact does not hold (the window stayed quiet, no such thread, the API
#             rejected the request, a build check is RED, the merge was refused); 2
#             usage/configuration error; 3 TRANSPORT failure — nothing was learned, so retry rather
#             than concluding anything. 1 and 3 are kept apart everywhere. `checks`, `base` and
#             `merge` add 4: no verdict yet — the build has not finished, or every finished job was
#             cancelled. 4 is not a pass and not a failure, and it is kept apart from 0 for the
#             same reason 3 is: "nothing has failed" and "everything passed" are different facts.
#             From `merge`, 4 means the merge was REFUSED for want of a verdict (see
#             --allow-no-verdict).
#
# Env: REPO=owner/name (else the <pr> argument, else the cwd's checkout, else the per-PR cache),
#      REVIEWER=login-prefix (default: codex app), WATCH_INTERVAL=seconds between polls (default
#      90), WATCH_TIMEOUT=seconds to watch (900), SHIP_PR_STATE_DIR=where the cache lives,
#      SHIP_PR_API_ATTEMPTS=tries per gh call (4), SHIP_PR_API_BACKOFF=first pause in seconds (5,
#      doubling to a 20s cap: ~35s of retrying before a call is declared dead),
#      SHIP_PR_REVIEW_GRACE=seconds a due-but-unstarted review is waited for before `watch` returns
#      saying so (1200), SHIP_PR_REVIEW_STALL=seconds a live 👀 may run before it gets the same
#      verdict (2×GRACE). Both are measured from the PR's own timestamps, not from when the watch
#      started, so they are reached ACROSS windows — a 900s window cannot outrun a 1200s grace.
#      SHIP_PR_ADVISORY_CHECKS=ERE of check/workflow names the build gate ignores (default: the
#      review app's check and the github-pages deploys), SHIP_PR_CHECKS_WAIT=seconds `--wait` holds
#      out for a build verdict (7200 — the runner queue alone ran ~2h deep on 2026-08-23),
#      SHIP_PR_CHECKS_INTERVAL=seconds between re-reads (60), SHIP_PR_CHECKS_HEARTBEAT=seconds
#      between the one-line "still waiting" progress notes a `--wait` prints (600),
#      SHIP_PR_STALE_BASE=commits behind the base at which `merge` warns loudly (20; `off`
#      silences it — the warning never blocks the merge either way).

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

  # A new review's inline comments can lag the flat listing read above (see the header), so every
  # review this round is about to report gets its own comments endpoint read too, merged by
  # comment id — the flat feed's copy wins when both exist, since only it carries current line
  # numbers. A failed per-review read fails the ROUND (unknown, watermark unwritten): the
  # alternative is printing the review while silently dropping its findings.
  local rid extra='[]' more
  for rid in $(jq -r --arg rev "$REVIEWER" --argjson since "$m_review" '
    map(select((.user.login // "") | startswith($rev)) | select(.id > $since))
    | .[].id' <<<"$reviews"); do
    more=$(api_list "pulls/$pr/reviews/$rid/comments?per_page=100") || {
      warn "API error reading review $rid's comments on PR $pr after $API_ATTEMPTS attempts" \
        "($(gh_err_line)) — this round is UNKNOWN, not quiet"
      return 3
    }
    extra=$(printf '%s\n%s\n' "$extra" "$more" | jq -s '.[0] + .[1]') || return 4
  done
  inline=$(printf '%s\n%s\n' "$inline" "$extra" | jq -s '
    (.[0] | map(.id)) as $have
    | .[0] + (.[1] | map(select(.id as $i | ($have | index($i)) | not)))') || return 4

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

# --- reviewer state ---------------------------------------------------------------------------
# The 👀/👍 reactions alone cannot say whether a round is RUNNING, only that one was announced at
# some point, so the state is derived from the reactions crossed with what the reviewer has actually
# posted and with the head SHA. See the 👀 notes in the header for why each comparison is the one it
# is; the short version is that a spent 👀 is indistinguishable from a live one until you look at
# what the reviewer said after it.

GRACE="${SHIP_PR_REVIEW_GRACE:-1200}"
case "$GRACE" in
'' | *[!0-9]*) die "SHIP_PR_REVIEW_GRACE must be a number of seconds, got '$GRACE'" ;;
esac
STALL="${SHIP_PR_REVIEW_STALL:-$((GRACE * 2))}"
case "$STALL" in
'' | *[!0-9]*) die "SHIP_PR_REVIEW_STALL must be a number of seconds, got '$STALL'" ;;
esac

# ISO 8601 UTC timestamps sort correctly as plain strings, which is why every comparison below is a
# string comparison: no date(1) is involved, whose parsing flags differ between BSD and GNU.
newest() {
  local ts best=""
  for ts in "$@"; do
    [ -n "$ts" ] || continue
    [ -z "$best" ] || [[ "$ts" > "$best" ]] || continue
    best="$ts"
  done
  printf '%s' "$best"
}

# Seconds since an ISO timestamp, or "-" when there is nothing to measure from. jq does the
# arithmetic for the same portability reason, and "-" is deliberately not 0: a missing age must not
# read as "just happened" and must never reach an integer comparison.
age_of() {
  local out
  [ -n "${1:-}" ] || {
    echo -
    return 0
  }
  out=$(jq -rn --arg t "$1" \
    'try ((now - ($t | fromdateiso8601)) | floor | tostring) catch "-"' 2>/dev/null)
  case "$out" in '' | *[!0-9]*) echo - ;; *) echo "$out" ;; esac
}

# "20m" reads better than "1203s" in a line a human skims; the raw seconds stay in the state line.
fmt_age() {
  case "${1:-}" in
  '' | *[!0-9]*) printf 'an unknown time' ;;
  *) if [ "$1" -ge 60 ]; then printf '%dm' "$(($1 / 60))"; else printf '%ds' "$1"; fi ;;
  esac
}

# Prints ONE line, "<token>|<seconds>|<detail>", and always exits 0 — the token carries the failure:
#   approved  👍 is on the PR: the merge gate is open.
#   reviewing 👀 is newer than the reviewer's last word, so a round really is in flight.
#   stalled   ... and it has been in flight longer than any round takes; nothing is coming.
#   expected  no live 👀 and no review of the head SHA: a round is due and has not started.
#   idle      the reviewer has reviewed this exact head and left no 👍, so the next move is yours.
#   unknown   a read failed. NOT a state of the PR — hold the previous one and retry.
# <seconds> is how long the state has held: since the 👀 for reviewing/stalled, and for expected
# since the LATEST of head commit / reviewer's last word / spent 👀 — i.e. since the moment a review
# became due. "-" when nothing datable was read.
status_state() {
  local pr="$1" raw line age plus eyes_at rev_at rev_sha com_at last_spoke head_sha head_at

  raw=$(api_list "issues/$pr/reactions?per_page=100") || {
    echo "unknown|-|the reactions API did not answer ($(gh_err_line))"
    return 0
  }
  line=$(jq -r --arg rev "$REVIEWER" '
      [.[] | select((.user.login // "") | startswith($rev))]
      | "\(any(.[]; .content == "+1"))"
        + "|" + ((map(select(.content == "eyes") | .created_at) | max) // "")' \
    <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|the reactions feed did not parse"
    return 0
  }
  plus="${line%%|*}"
  eyes_at="${line#*|}"

  # 👍 is the merge gate and the reactions feed alone answers it, so it is answered before any feed
  # that could fail: an outage on the reviews feed must not hide an approval behind "unknown".
  [ "$plus" = true ] && {
    echo "approved|-|👍 from $REVIEWER"
    return 0
  }

  raw=$(api_list "pulls/$pr/reviews?per_page=100") || {
    echo "unknown|-|the reviews API did not answer ($(gh_err_line))"
    return 0
  }
  # Your own replies land in this feed as COMMENTED reviews, hence the login filter; PENDING reviews
  # have no submitted_at and are not yet the reviewer speaking.
  line=$(jq -r --arg rev "$REVIEWER" '
      [.[] | select((.user.login // "") | startswith($rev)) | select(.submitted_at != null)]
      | sort_by(.submitted_at) | last
      | if . == null then "|" else "\(.submitted_at)|\(.commit_id // "")" end' \
    <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|the reviews feed did not parse"
    return 0
  }
  rev_at="${line%%|*}"
  rev_sha="${line#*|}"

  # The summary comment counts as the reviewer speaking too: a round delivered only as an issue
  # comment would otherwise leave its 👀 looking live forever, which is this same bug in a hat.
  raw=$(api_list "issues/$pr/comments?per_page=100") || {
    echo "unknown|-|the comments API did not answer ($(gh_err_line))"
    return 0
  }
  com_at=$(jq -r --arg rev "$REVIEWER" '
      [.[] | select((.user.login // "") | startswith($rev)) | .created_at] | max // ""' \
    <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|the comments feed did not parse"
    return 0
  }
  last_spoke=$(newest "$rev_at" "$com_at")

  # In flight only while the 👀 is newer than everything the reviewer has said. An empty last_spoke
  # (nothing posted yet) makes any 👀 live, which is right: that is a first round running.
  if [ -n "$eyes_at" ] && [[ "$eyes_at" > "$last_spoke" ]]; then
    age=$(age_of "$eyes_at")
    case "$age" in
    '' | *[!0-9]*) ;;
    *) [ "$age" -ge "$STALL" ] && {
      echo "stalled|$age|👀 from $REVIEWER at $eyes_at with nothing posted since"
      return 0
    } ;;
    esac
    echo "reviewing|$age|👀 from $REVIEWER at $eyes_at, newer than its last" \
      "word${last_spoke:+ ($last_spoke)}"
    return 0
  fi

  head_sha=$(gh_retry read api "repos/$REPO/pulls/$pr" --jq .head.sha)
  [ "$?" -eq 0 ] && [ -n "$head_sha" ] || {
    echo "unknown|-|the pulls API did not answer for the head SHA ($(gh_err_line))"
    return 0
  }

  # SHA equality, not a timestamp: the review records the commit it was submitted against, so this
  # is exactly "has the reviewer seen THIS head" with no push time to estimate.
  if [ "$rev_sha" = "$head_sha" ]; then
    echo "idle|$(age_of "$last_spoke")|$REVIEWER reviewed head ${head_sha:0:7} at $rev_at"
    return 0
  fi

  # The clock on a review that has not started runs from whichever came last: the push (approximated
  # by the head commit's committer date, which a rebase, amend or cherry-pick all refresh), the
  # reviewer's last word, or the spent 👀. A failed commit read costs precision, not the state.
  head_at=$(gh_retry read api "repos/$REPO/commits/$head_sha" --jq .commit.committer.date) ||
    head_at=""
  echo "expected|$(age_of "$(newest "$head_at" "$last_spoke" "$eyes_at")")|no 👀 in flight and no" \
    "review of head ${head_sha:0:7}${rev_sha:+; $REVIEWER last reviewed ${rev_sha:0:7} at $rev_at}"
}

state_tok() { printf '%s' "${1%%|*}"; }
state_age() {
  local rest="${1#*|}"
  printf '%s' "${rest%%|*}"
}
state_detail() {
  local rest="${1#*|}"
  printf '%s' "${rest#*|}"
}

# Takes a whole state line, not a token: the age and the detail are what make the difference between
# "wait it out" and "nothing is coming" legible to whoever reads the log.
status_line() {
  local tok age detail
  tok=$(state_tok "$1")
  age=$(state_age "$1")
  detail=$(state_detail "$1")
  case "$tok" in
  approved) echo "approved ($detail)" ;;
  reviewing) echo "reviewing — $detail, running $(fmt_age "$age") — wait it out" ;;
  stalled) echo "STALLED — $detail for $(fmt_age "$age"), longer than a round takes; nothing is" \
    "coming, so nudge with a '@codex review' comment rather than waiting further" ;;
  expected) echo "review EXPECTED but not started — $detail; due for $(fmt_age "$age")" ;;
  idle) echo "nothing in flight — $detail, and no 👍; the next move is yours" ;;
  unknown) echo "UNKNOWN — $detail; this is NOT 'not approved', retry" ;;
  *) echo "unrecognised state '$tok' — treat as unknown and retry" ;;
  esac
}

cmd_status() {
  pr_arg "${1:?usage: status <pr>}"
  local state
  state=$(status_state "$PR_NUM")
  status_line "$state"
  # Exit 3 on unknown so a caller gating a merge on `status` cannot read a failed read as a quiet
  # "not approved yet" — the same collapse api_list refuses to make. 3 rather than 2, because a
  # usage error (2) is the caller's to fix and this one is the API's to recover from.
  [ "$(state_tok "$state")" = unknown ] && return 3
  return 0
}

# Poll on a timer so a round's arrival wakes the caller instead of the caller re-deriving this loop.
# Exits 0 with something to act on — a round's findings, the approval landing, or the verdict that no
# review is coming (a spent or stalled 👀, or one that never started within the grace) — and 1 having
# stayed quiet for the whole window; in both cases the last line is a watermark to resume from, with
# poll's semantics. It exits 3 instead when it never managed to read the PR at all, so that "the
# reviewer stayed quiet" and "I was blind for the whole window" stay distinguishable — only the first
# is a reason to stop watching. Run it in the Bash tool's background mode: the default window is
# longer than that tool's foreground ceiling. Background shells do not start in the checkout, so give
# this the repo: `watch owner/name#<pr>`.
#
# "Keep waiting" is a claim, and this loop is only allowed to make it while something is running.
# Every other state gets a bounded wait and then a verdict, because a window that reports nothing is
# indistinguishable — to the caller and to the user watching the clock — from a window that reported
# a stale 👀 three times in a row.
cmd_watch() {
  local pr="${1:?usage: watch <pr> [watermark]}" mark="${2:-}"
  pr_arg "$pr"
  pr="$PR_NUM"
  local interval="${WATCH_INTERVAL:-90}" timeout="${WATCH_TIMEOUT:-900}"
  local start=$SECONDS was state tok age out rc next quiet=0 saw=0 blind=0

  state=$(status_state "$pr")
  was=$(state_tok "$state")
  echo "watching PR $REPO#$pr, every ${interval}s for up to ${timeout}s;" \
    "from: $(status_line "$state")" >&2

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

    state=$(status_state "$pr")
    tok=$(state_tok "$state")
    age=$(state_age "$state")

    # A round's stdout is byte-identical to poll's, watermark last, so a caller can consume watch
    # and poll the same way; the state is context, not the finding, so it goes to stderr.
    if [ "$rc" -eq 0 ] && grep -q '^--- ' <<<"$out"; then
      echo "status: $(status_line "$state")" >&2
      echo "$out"
      return 0
    fi
    # One line per round, so a backgrounded watch leaves a log that says WHICH kind of quiet this
    # was — the stall this loop used to hide was a status line repeating itself unremarked.
    warn "PR $REPO#$pr: $(status_line "$state")"

    case "$tok" in
    unknown)
      # Neither approval nor its absence can be concluded from a read that did not happen; hold the
      # previous state and keep polling.
      warn "state unreadable this round on PR $REPO#$pr; holding '$was'"
      ;;
    approved)
      status_line "$state"
      echo "watermark: $mark"
      return 0
      ;;
    stalled)
      # Bounded patience on a LIVE 👀 as well: a round that never lands stalls the loop exactly as a
      # spent 👀 does, and the answer is the same — say so and let the caller nudge.
      status_line "$state"
      echo "watermark: $mark"
      return 0
      ;;
    *)
      # A 👀 that stops being in flight without a review of the head is a round that ended with
      # nothing. Make it prove itself over two rounds, since one read can be a false negative — and
      # this is the fast path to the same verdict the grace below reaches on the clock alone.
      if [ "$was" = reviewing ] && [ "$tok" != reviewing ]; then
        quiet=$((quiet + 1))
        if [ "$quiet" -ge 2 ]; then
          echo "the 👀 round on PR $REPO#$pr ended without a review of the head commit — consider" \
            "nudging with a '@codex review' comment"
          status_line "$state"
          echo "watermark: $mark"
          return 0
        fi
      else
        quiet=0
        was="$tok"
      fi
      # The state this loop used to mistake for "reviewing". It is worth a bounded wait — the app
      # takes minutes to pick a push up — and then it is worth SAYING, because there is nothing on
      # the other end to wait for. The grace runs from the PR's clock, not the window's, so it is
      # reached in the second window rather than never.
      if [ "$tok" = expected ]; then
        case "$age" in
        '' | *[!0-9]*) ;;
        *)
          if [ "$age" -ge "$GRACE" ]; then
            echo "no review materialized on PR $REPO#$pr in the $(fmt_age "$age") since it became" \
              "due — consider nudging with a '@codex review' comment"
            status_line "$state"
            echo "watermark: $mark"
            return 0
          fi
          ;;
        esac
      fi
      ;;
    esac

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
  # The state is the last round's, not a fresh read: it is what the window actually observed, and a
  # re-read here would report a change this window never saw and never acted on.
  echo "no new activity in ${timeout}s; status: $(status_line "$state")"
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

# Not every finding has a thread to answer in. A review's SUMMARY body carries no comment ids, so
# the only surface for answering it is a plain PR comment — and so is the '@codex review' nudge the
# watch verdicts recommend. `gh pr comment` is the obvious tool and it does NOT take the
# owner/name#number form the rest of this script standardizes on (it wants a bare number plus
# --repo, or a full URL), so `retry gh pr comment lukstafi/ocannl-staging#475 --body ...` fails on
# the argument, not on the network: during the 1.0.1 release prep on that PR (2026-08-25) the
# workaround was hand-building the PR's URL. The REST issues endpoint takes the same pieces this
# script already resolved, so the argument shape, the retry policy and the write semantics all stay
# what every other command here has. Same marker as `reply`, for the same reason.
cmd_comment() {
  # Exactly two, and checked rather than left to ${1:?...} — which exits 1, the code that means "the
  # fact does not hold". A body is a sentence, so an unquoted one arrives as several arguments and
  # would otherwise post its first word and drop the rest; that reads as a posted comment.
  [ $# -eq 2 ] || die "usage: comment <pr> <body> — got $# argument(s)." \
    "The body is ONE argument: quote it, including a multi-line one."
  local pr="$1" body="$2"
  [ -n "${body//[[:space:]]/}" ] || die "comment: the body is empty; there is nothing to post"
  pr_arg "$pr"
  pr="$PR_NUM"
  # issues/<n>/comments, not pulls/<n>/comments: on GitHub a PR *is* an issue, and the pulls
  # endpoint posts INLINE review comments, which need a commit and a path.
  gh_retry write api -X POST "repos/$REPO/issues/$pr/comments" \
    -f body="$body

_🤖 Addressed by [Claude Code](https://claude.com/claude-code)_" --jq .html_url
  case "$?" in
  0) return 0 ;;
  3) fail 3 "comment on PR $REPO#$pr did not go through — the API refused it at the gateway on" \
    "all $API_ATTEMPTS attempts ($(gh_err_line)). Nothing was posted, so retry." ;;
  *)
    api_rejection "$(gh_err_line)" &&
      fail 1 "comment on PR $REPO#$pr was REJECTED, not dropped: $(gh_err_line)." \
        "Retrying prints the same thing — check the PR number and the repo."
    fail 3 "comment on PR $REPO#$pr failed AMBIGUOUSLY: $(gh_err_line)." \
      "That is not a gateway refusal, so the comment may or may not have landed and this script" \
      "will not post it twice — read the PR, then retry only if it is not there."
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

# --- the build signal -------------------------------------------------------------------------
# ahrefs/ocannl#694: a master that did not compile on OCaml 5.5 survived seven consecutive merges.
# Detection was never missing — every one of those PRs had its own red `ci` run, byte-identical
# error, both platforms, before it merged. The signal was produced six times and consumed zero
# times, because no step between "run finished red" and "merge" read the result. So the read lives
# here, in the merge command itself, rather than as a line of prose asking the next session to
# remember it.
#
# The reads are REST, like the rest of the merge path: `gh pr checks` rides GraphQL, which 503s
# independently of REST, and a GraphQL-borne empty check list is indistinguishable from a PR whose
# CI genuinely never ran. On a merge gate that difference is the whole point — a failed read
# reports UNKNOWN (exit 3) and never "nothing is red".
#
# Which checks count is a DENY-list, not an allow-list. Everything a commit's check-runs report is
# build-relevant unless it is named advisory. An allow-list keyed on today's job names ("Build
# (ubuntu-latest, 5.5.x)") stops gating silently the day a job is renamed or a matrix entry is
# added — it fails OPEN, which is the exact failure this exists to prevent. What is advisory by
# default: the review app's check (permanently SKIPPED on the PR path), and a publishing workflow
# that builds none of the tree — ocannl's `github pages docs` runs slipshow, pandoc and latexmk over
# `docs/**` and compiles no OCaml, so its red is about a font package, never about the code.
#
# `github pages api` is NOT on that list, and the distinction is the point. It runs `dune build
# @doc` over the whole tree, so its red can be the tree's. It was excluded for a while, on the
# argument that a chronically red signal is one everyone stops reading (the pathology #694 is
# about) — and that exclusion promptly hid a genuine `@doc` compile break behind the infrastructure
# failure that was masking it (ahrefs/ocannl#698). The lesson is the opposite of the exclusion: a
# workflow whose red can mean "the tree does not build" belongs in the gate, and a workflow that is
# always red belongs fixed. Exclude by name only what CANNOT carry a build verdict.
#
# Which CONCLUSIONS count as red is deliberately narrow, because the merge path must not cry wolf:
#   failure, timed_out, startup_failure   a verdict, and the verdict is no
#   success, skipped, neutral             green; a path-filtered job that did not run has not failed
#   cancelled, stale, action_required     NO VERDICT — reported, never counted as red and never
#                                         counted as a pass
# `cancelled` is the one worth spelling out: a cancel means the job was stopped, not that it found
# anything. ocannl's ci sets `fail-fast: false` precisely so a red matrix leg does not cancel its
# siblings, but that has not always been true and is not true of every workflow, and a superseding
# push cancels too. Treating a cancel as red would make every force-push a refusal; treating it as
# green would let a matrix leg that never finished pass for one that passed. It is neither.
BUILD_ADVISORY="${SHIP_PR_ADVISORY_CHECKS:-^(claude|Claude Code|github pages docs)$}"
CHECKS_INTERVAL="${SHIP_PR_CHECKS_INTERVAL:-60}"
CHECKS_WAIT="${SHIP_PR_CHECKS_WAIT:-7200}"
CHECKS_HEARTBEAT="${SHIP_PR_CHECKS_HEARTBEAT:-600}"

is_advisory() { printf '%s' "$1" | grep -Eq "$BUILD_ADVISORY"; }

conclusion_class() {
  case "$1" in
  failure | timed_out | startup_failure) echo red ;;
  success | skipped | neutral) echo green ;;
  '' | null | pending) echo pending ;;
  *) echo nogo ;; # cancelled, stale, action_required: stopped, not judged
  esac
}

# Prints "class<TAB>name<TAB>conclusion<TAB>url" per non-advisory check-run of <sha>. Returns 3
# printing NOTHING when the read failed, so the caller can tell an outage from a commit with no
# checks — collapsing those two is how a merge gate says "nothing is red" about a PR it never read.
# filter=latest is explicit: a re-run adds a second check-run under the same name, and the older
# one's conclusion is not the current answer.
#
# No field is ever emitted EMPTY, and that is not cosmetic: tab is an IFS *whitespace* character,
# so `IFS=$'\t' read` collapses a run of tabs into one delimiter. An unfinished check-run has a
# null conclusion, so an empty middle field would silently shift its URL into the conclusion
# column and every pending job would be classified by the text of its own link. The placeholder
# keeps the columns aligned.
build_checks() {
  local sha="$1" raw rc name concl url
  raw=$(gh_retry read api --paginate \
    "repos/$REPO/commits/$sha/check-runs?filter=latest&per_page=100" \
    --jq '.check_runs[] | [.name, (.conclusion // "pending"), (.html_url // "-")] | @tsv')
  rc=$?
  [ "$rc" -eq 0 ] || return 3
  while IFS=$'\t' read -r name concl url; do
    [ -n "$name" ] || continue
    is_advisory "$name" && continue
    printf '%s\t%s\t%s\t%s\n' "$(conclusion_class "$concl")" "$name" "$concl" "$url"
  done <<<"$raw"
}

# Folds the per-check classes into VERDICT (red|pending|mixed|absent|green) and the report lines.
# Runs in the current shell — a pipeline would put the loop in a subshell and lose both.
summarize_checks() {
  local class name concl url red=0 pending=0 nogo=0 green=0
  VERDICT=""
  CHECK_LINES=""
  CHECK_RED=0
  while IFS=$'\t' read -r class name concl url; do
    [ -n "$class" ] || continue
    case "$class" in
    red)
      red=$((red + 1))
      CHECK_LINES="${CHECK_LINES}  RED      $name ($concl)  $url"$'\n'
      ;;
    pending)
      pending=$((pending + 1))
      CHECK_LINES="${CHECK_LINES}  running  $name (no verdict yet)  $url"$'\n'
      ;;
    nogo)
      nogo=$((nogo + 1))
      CHECK_LINES="${CHECK_LINES}  no verdict  $name ($concl — stopped, not judged)  $url"$'\n'
      ;;
    *) green=$((green + 1)) ;;
    esac
  done <<<"$1"
  CHECK_RED="$red"
  CHECK_PENDING="$pending"
  CHECK_TOTAL=$((red + pending + nogo + green))
  if [ "$red" -gt 0 ]; then
    VERDICT=red
  elif [ "$pending" -gt 0 ]; then
    VERDICT=pending
  elif [ "$nogo" -gt 0 ]; then
    VERDICT=mixed
  elif [ "$green" -eq 0 ]; then
    VERDICT=absent
  else
    VERDICT=green
  fi
  CHECK_GREEN="$green"
}

# Reads the PR's head SHA and judges its build signal. Sets VERDICT and prints the report.
# 0 = green or absent (nothing is red), 1 = RED, 3 = the API did not answer, 4 = no verdict yet
# (still running, or every finished job was cancelled).
gate_checks() {
  local pr="$1" wait_for="${2:-0}" sha lines rc deadline started beat now
  sha=$(gh_retry read api "repos/$REPO/pulls/$pr" --jq .head.sha)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$sha" ]; then
    VERDICT=unknown
    warn "could not read $REPO#$pr's head SHA ($(gh_err_line)); the build signal is UNKNOWN," \
      "which is NOT 'nothing is red'."
    return 3
  fi
  started=$(date +%s)
  deadline=$((started + wait_for))
  beat=$started
  while :; do
    lines=$(build_checks "$sha")
    rc=$?
    if [ "$rc" -ne 0 ]; then
      VERDICT=unknown
      warn "could not read the checks of $REPO#$pr @${sha:0:8} ($(gh_err_line));" \
        "the build signal is UNKNOWN, which is NOT 'nothing is red'."
      return 3
    fi
    summarize_checks "$lines"
    now=$(date +%s)
    [ "$VERDICT" = pending ] && [ "$now" -lt "$deadline" ] || break
    # One line per heartbeat, not per re-read: a two-hour wait is 120 re-reads, and a background
    # child that prints that much is as unreadable as one that prints nothing.
    if [ $((now - beat)) -ge "$CHECKS_HEARTBEAT" ]; then
      warn "still waiting on $REPO#$pr @${sha:0:8}: no verdict after $(((now - started) / 60)) of" \
        "$((wait_for / 60)) min ($CHECK_PENDING check(s) running)"
      beat=$now
    fi
    sleep "$CHECKS_INTERVAL"
  done
  case "$VERDICT" in
  red) echo "build signal $REPO#$pr @${sha:0:8}: RED — $CHECK_RED of $CHECK_TOTAL build checks failed" ;;
  pending) echo "build signal $REPO#$pr @${sha:0:8}: NO VERDICT YET — still running" ;;
  mixed) echo "build signal $REPO#$pr @${sha:0:8}: INCOMPLETE — $CHECK_GREEN passed, the rest were stopped without a verdict" ;;
  absent) echo "build signal $REPO#$pr @${sha:0:8}: ABSENT — no build check ran on this commit (path filters, or CI never started)" ;;
  green) echo "build signal $REPO#$pr @${sha:0:8}: green — $CHECK_GREEN build checks passed" ;;
  esac
  [ -n "$CHECK_LINES" ] && printf '%s' "$CHECK_LINES"
  case "$VERDICT" in
  red) return 1 ;;
  pending | mixed) return 4 ;;
  *) return 0 ;;
  esac
}

cmd_checks() {
  local pr="${1:?usage: checks <pr> [--wait[=seconds]]}" wait_for=0
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
    --wait) wait_for="$CHECKS_WAIT" ;;
    --wait=*) wait_for="${1#--wait=}" ;;
    *) die "checks: unknown option '$1'" ;;
    esac
    shift
  done
  pr_arg "$pr"
  gate_checks "$PR_NUM" "$wait_for"
}

# GitHub recomputes a PR's mergeability asynchronously after every push, and until that finishes
# `gh pr merge` fails with a message byte-identical to a genuine conflict. Seen back to back on
# ocannl-staging#373: real base drift, then the stale cache over the freshly pushed
# conflict-RESOLUTION merge. null = still computing, so it is not an answer to anything.
await_mergeable() {
  local i m rc
  for i in 1 2 3 4 5 6 7 8; do
    m=$(gh_retry read api "repos/$REPO/pulls/$PR_NUM" --jq '.mergeable | tostring')
    rc=$?
    [ "$rc" -eq 0 ] || {
      echo unknown
      return 3
    }
    case "$m" in
    true | false)
      echo "$m"
      return 0
      ;;
    esac
    sleep 5
  done
  echo null
  return 4
}

# --- staleness of the base --------------------------------------------------------------------
# How far behind its base the branch is, i.e. how much of the base the review and the checks never
# saw. Nothing else on the merge path can answer this: green checks are green on the STALE head, an
# approval approves the STALE diff, and `mergeable` is true whenever the drift produced no textual
# conflict — which is exactly the case where the damage is silent. See the header for #488.
STALE_BASE="${SHIP_PR_STALE_BASE:-20}"
case "$STALE_BASE" in
off) ;;
'' | *[!0-9]*) die "SHIP_PR_STALE_BASE must be a number of commits or 'off', got '$STALE_BASE'" ;;
esac

# Prints the count, loudly when it is at or over the threshold. Returns 0 fresh enough, 1 warned,
# 3 unread. The caller merges regardless — this is a warning, not a gate — but the DIFFERENCE
# between "not behind" and "could not be read" is preserved here like everywhere else in this file:
# a compare call that never answered must not print a reassuring number it does not have.
warn_base_drift() {
  local pr="$1" fields cmp base head sha behind ahead rc
  [ "$STALE_BASE" = off ] && return 0
  # Placeholders, never empty fields: tab is IFS whitespace, so an empty middle column would shift
  # the sha into $head (the same trap build_checks documents).
  fields=$(gh_retry read api "repos/$REPO/pulls/$pr" \
    --jq '[(.base.ref // "-"), (.head.label // "-"), (.head.sha // "-")] | @tsv')
  rc=$?
  IFS=$'\t' read -r base head sha <<<"$fields"
  if [ "$rc" -ne 0 ] || [ -z "$base" ] || [ "$base" = - ]; then
    warn "how far $REPO#$pr is behind its base: UNKNOWN — the PR could not be read" \
      "($(gh_err_line)). This is not 'not behind': check it by hand before merging" \
      "(git fetch, then git diff <remote>/<base>..HEAD --stat)."
    return 3
  fi
  # owner:branch, so a fork PR compares against the branch it actually has; the head SHA is the
  # fallback for a head whose repo is gone or whose label the API left unset.
  case "$head" in *:*) ;; *) head="$sha" ;; esac
  # per_page=1 trims the commit list the compare would otherwise carry — 136 commits and 258 files
  # of payload to read two integers. behind_by/ahead_by are totals and are unaffected by it.
  cmp=$(gh_retry read api "repos/$REPO/compare/$base...$head?per_page=1" \
    --jq '[(.behind_by // "-"), (.ahead_by // "-")] | @tsv')
  rc=$?
  if [ "$rc" -ne 0 ] && [ "$head" != "$sha" ] && [ "$sha" != - ]; then
    cmp=$(gh_retry read api "repos/$REPO/compare/$base...$sha?per_page=1" \
      --jq '[(.behind_by // "-"), (.ahead_by // "-")] | @tsv')
    rc=$?
  fi
  IFS=$'\t' read -r behind ahead <<<"$cmp"
  [ "$rc" -eq 0 ] || behind=-
  case "$behind" in
  '' | *[!0-9]*)
    warn "how far $REPO#$pr is behind $base: UNKNOWN — the compare call did not answer" \
      "($(gh_err_line)). This is not 'not behind': check it by hand before merging" \
      "(git fetch, then git diff <remote>/$base..HEAD --stat)."
    return 3
    ;;
  esac
  case "$ahead" in '' | *[!0-9]*) ahead="?" ;; esac
  if [ "$behind" -lt "$STALE_BASE" ]; then
    echo "base freshness $REPO#$pr: $behind commit(s) behind $base, $ahead ahead" \
      "(warns at $STALE_BASE)"
    return 0
  fi
  echo "!!! $REPO#$pr is $behind COMMITS BEHIND its base ($base)."
  echo "!!! The review that approved this branch, and the checks that went green on it, both judged"
  echo "!!! it against a base that has since moved $behind commits. $base may have edited the very"
  echo "!!! files this PR changes: merging now lands a combination nobody reviewed and no CI run"
  echo "!!! built. A clean 'mergeable' says only that the two texts do not collide."
  echo "!!! Rebase onto the base (or merge it in, where the branch is shared and rewriting is not"
  echo "!!! yours to do), push, and let the checks re-run before merging:"
  echo "!!!   git fetch <the remote pointing at $REPO> && git rebase <that remote>/$base"
  echo "!!!   git diff <that remote>/$base..HEAD --stat   # two dots: on a stale branch this shows"
  echo "!!!                                               # the BASE's files too, not just yours"
  warn "MERGING A STALE BRANCH: $REPO#$pr is $behind commits behind $base (warns at $STALE_BASE," \
    "SHIP_PR_STALE_BASE) — rebase and re-check unless you know the drift is irrelevant."
  return 1
}

# merge = read the build signal, then merge. The two are one command on purpose: a gate you have
# to remember to run separately is the gate that was missing for seven merges.
cmd_merge() {
  local pr="${1:?usage: merge <pr> [--override <reason>] [--wait[=seconds]] [--allow-no-verdict] [-- <gh pr merge args...>]}"
  shift
  local override="" wait_for=0 allow_no_verdict="" gate out rc attempt=1 mergeable state
  local -a gh_args=()
  while [ $# -gt 0 ]; do
    case "$1" in
    --override)
      override="${2:?--override needs a reason}"
      shift 2
      ;;
    --override=*)
      override="${1#--override=}"
      shift
      ;;
    --wait)
      wait_for="$CHECKS_WAIT"
      shift
      ;;
    --wait=*)
      wait_for="${1#--wait=}"
      shift
      ;;
    --allow-no-verdict)
      allow_no_verdict=1
      shift
      ;;
    --)
      shift
      gh_args=("$@")
      break
      ;;
    *) die "merge: unknown option '$1' (extra \`gh pr merge\` flags go after --)" ;;
    esac
  done
  [ ${#gh_args[@]} -gt 0 ] || gh_args=(--merge) # the repo convention: preserve the commit series
  # A reason, not a token. "--override yes" would make the gate a formality one keystroke wide;
  # what makes an override legitimate is being able to say why THIS red is unrelated to THIS PR,
  # and that sentence is what lands in the log the next reader sees.
  if [ -n "$override" ] &&
    ! printf '%s' "$override" | grep -Eq '[^[:space:]]+[[:space:]]+[^[:space:]]+'; then
    die "merge: --override takes a REASON in words, not '$override'. Say why this red is" \
      "known-unrelated to this PR — e.g. --override 'ci Deps step fails on an opam solve," \
      "same red on master before this branch existed'."
  fi
  pr_arg "$pr"
  gate_checks "$PR_NUM" "$wait_for"
  gate=$?
  case "$gate" in
  1)
    if [ -n "$override" ]; then
      echo "OVERRIDE: merging $REPO#$PR_NUM over a RED build signal — $override"
      warn "OVERRIDE: merging $REPO#$PR_NUM over $CHECK_RED red build check(s) — $override"
    else
      fail 1 "REFUSING to merge $REPO#$PR_NUM: $CHECK_RED build check(s) concluded failure on the" \
        "head commit (listed above). Fix it, or — only if that red is genuinely not about this" \
        "change — re-run with --override '<why this red is unrelated>'."
    fi
    ;;
  3) fail 3 "NOT merging $REPO#$PR_NUM: the build signal could not be READ. Nothing is known," \
    "so this is not 'nothing is red' — retry rather than merging past it." ;;
  4)
    # No verdict is not "nothing is red" either. On 2026-08-23 a day-long ~2h runner queue outran
    # the 30-minute wait, two PRs merged unread on the warning below, and master was red for two
    # hours (ahrefs/ocannl#745, fixed forward in lukstafi/ocannl-staging#456) — so the default
    # is now to refuse, and merging unread takes a flag, like merging over red takes a reason.
    if [ -n "$allow_no_verdict" ]; then
      echo "ALLOW-NO-VERDICT: merging $REPO#$PR_NUM with NO build verdict on the head commit"
      warn "ALLOW-NO-VERDICT: merging $REPO#$PR_NUM unread — nothing has failed, nothing has" \
        "passed either (see above)."
    else
      fail 4 "REFUSING to merge $REPO#$PR_NUM: no verdict after $((wait_for / 60)) min —" \
        "re-run with --allow-no-verdict to merge unread, or wait (--wait holds up to" \
        "$((CHECKS_WAIT / 60)) min, SHIP_PR_CHECKS_WAIT)."
    fi
    ;;
  esac
  # Last, so that it is read AFTER a --wait (the base keeps moving during one) and so that the
  # warning is the final thing on screen before the merge itself. It never stops the merge.
  warn_base_drift "$PR_NUM" || :
  while :; do
    out=$(gh_retry write pr merge "$PR_NUM" --repo "$REPO" "${gh_args[@]}")
    rc=$?
    [ -n "$out" ] && printf '%s\n' "$out"
    [ "$rc" -eq 0 ] && break
    case "$(gh_err_line)" in
    *"not mergeable"* | *"cannot be cleanly created"*)
      [ "$attempt" -ge 3 ] && fail 1 "merge of $REPO#$PR_NUM keeps failing as not mergeable" \
        "after $attempt attempts: this is base drift, merge or rebase origin/<base> in."
      mergeable=$(await_mergeable)
      case "$mergeable" in
      true)
        warn "'not mergeable' was the stale pre-recompute verdict (mergeable=true now); retrying"
        attempt=$((attempt + 1))
        continue
        ;;
      false) fail 1 "$REPO#$PR_NUM really does not merge cleanly (mergeable=false after the" \
        "recompute): merge or rebase the base branch in, push, then merge again." ;;
      *) fail 3 "$REPO#$PR_NUM failed to merge as 'not mergeable' and its mergeable field is" \
        "$mergeable — GitHub is still computing, or did not answer. Re-read before concluding." ;;
      esac
      ;;
    esac
    api_rejection "$(gh_err_line)" && fail 1 "gh pr merge was rejected: $(gh_err_line)"
    fail 3 "gh pr merge failed AMBIGUOUSLY: $(gh_err_line). It may have LANDED — confirm over" \
      "REST (api repos/$REPO/pulls/$PR_NUM --jq .merged) before retrying."
  done
  # `gh pr merge` returns 0 having only ENABLED auto-merge when the base carries required checks or
  # a merge queue, so the exit code is not the answer. REST is, and it is REST because a GraphQL
  # 503 on the confirmation looks exactly like a merge that did not land.
  state=$(gh_retry read api "repos/$REPO/pulls/$PR_NUM" --jq '"merged=\(.merged) state=\(.state)"')
  rc=$?
  [ "$rc" -eq 0 ] || fail 3 "merge command returned but the state could not be confirmed" \
    "($(gh_err_line)) — do NOT re-merge; re-read repos/$REPO/pulls/$PR_NUM first."
  echo "$REPO#$PR_NUM $state"
  case "$state" in
  *"merged=true"*) return 0 ;;
  esac
  fail 1 "$REPO#$PR_NUM is not merged ($state) — \`gh pr merge\` returned having only enabled" \
    "auto-merge. It will land when the base's required checks pass; do not treat it as landed."
}

# The other half of #694: the confusion actually lands on whoever branches off a broken master.
# Read the base's own CI before starting work, not only before merging.
cmd_base() {
  local branch="" tip raw rc line name status sha concl csha cwhen curl red=0 pend=0 out=""
  local vconcl vsha vwhen vurl stopped_note
  while [ $# -gt 0 ]; do
    case "$1" in
    # First slashed arg is the repo UNLESS one is already named (--repo, REPO=, or an earlier
    # positional): branches carry slashes too (claude/...), and reading one as the repo turns
    # `base --repo owner/name claude/topic` into a 404 on repo "claude/topic".
    */*) if [ -z "$REPO" ]; then REPO="$1"; else branch="$1"; fi ;;
    -*) die "base: unknown option '$1'" ;;
    *) branch="$1" ;;
    esac
    shift
  done
  [ -n "$REPO" ] || REPO=$(repo_from_cwd) || true
  [ -n "$REPO" ] || die "base: name the repo — \`base owner/name [branch]\`, --repo, or REPO=." \
    "cwd inference only works from a checkout, and not from a background shell."
  if [ -z "$branch" ]; then
    branch=$(gh_retry read api "repos/$REPO" --jq .default_branch)
    [ $? -eq 0 ] && [ -n "$branch" ] || fail 3 "could not read $REPO's default branch" \
      "($(gh_err_line)) — the base's health is UNKNOWN, which is not 'fine'."
  fi
  tip=$(gh_retry read api "repos/$REPO/commits/$branch" --jq .sha) || tip=""
  raw=$(gh_retry read api \
    "repos/$REPO/actions/runs?branch=$branch&event=push&per_page=50" \
    --jq '.workflow_runs[] | [.name, .status, (.conclusion // "pending"), .head_sha, .created_at,
          (.html_url // "-")] | @tsv')
  rc=$?
  [ "$rc" -eq 0 ] || fail 3 "could not read $REPO's runs on $branch ($(gh_err_line));" \
    "the base's health is UNKNOWN, which is NOT 'green'."
  # Empty result must short-circuit: one empty line through tab-IFS `read` collapses into
  # shifted fields (tab is IFS whitespace), which used to render as a phantom workflow — and
  # a branch with no push-event runs would headline green with exit 0.
  if [ -z "$raw" ]; then
    echo "$REPO $branch: no build workflow has run on it (nothing to read, not a green light)"
    return 4
  fi
  # Newest first, so per workflow: the newest run at all (is one in flight?), the newest
  # COMPLETED one, and the newest run with an actual VERDICT (red/green). The last one is what
  # answers "is this base broken": under cancel-in-progress concurrency the newest completed run
  # on a busy default branch is routinely `cancelled` — stopped, not judged — and reading that as
  # either green or "no verdict" would be wrong (an older run usually did judge an earlier tip).
  # Same empty-field rule as build_checks: a workflow with no completed run yet leaves these
  # columns unset, and unset prints as empty, which `IFS=$'\t' read` would collapse.
  raw=$(awk -F'\t' '
    { nm=$1
      if (!(nm in seen)) { seen[nm]=1; order[++n]=nm; lstatus[nm]=$2; lsha[nm]=$4 }
      if ($2 == "completed" && !(nm in done)) { done[nm]=1; c[nm]=$3; csha[nm]=$4; cw[nm]=$5; cu[nm]=$6 }
      if ($2 == "completed" && !(nm in vdone) && \
          ($3 == "failure" || $3 == "timed_out" || $3 == "startup_failure" || \
           $3 == "success" || $3 == "skipped" || $3 == "neutral")) {
        vdone[nm]=1; v[nm]=$3; vs[nm]=$4; vw[nm]=$5; vu[nm]=$6 }
    }
    END { for (i=1;i<=n;i++) { nm=order[i]
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", nm, lstatus[nm], lsha[nm],
          (nm in done ? c[nm] : "pending"), (nm in done ? csha[nm] : "-"),
          (nm in done ? cw[nm] : "-"), (nm in done ? cu[nm] : "-"),
          (nm in vdone ? v[nm] : "-"), (nm in vdone ? vs[nm] : "-"),
          (nm in vdone ? vw[nm] : "-"), (nm in vdone ? vu[nm] : "-") } }
  ' <<<"$raw")
  while IFS=$'\t' read -r name status sha concl csha cwhen curl vconcl vsha vwhen vurl; do
    [ -n "$name" ] || continue
    is_advisory "$name" && continue
    # Newest completed run stopped-not-judged (cancelled/stale/action_required): the newest
    # JUDGED run carries the verdict — a red under a cancelled run is not an all-clear — and the
    # stopped run becomes context. Only when NO run ever judged this branch is there no verdict.
    stopped_note=""
    if [ "$(conclusion_class "$concl")" = nogo ] && [ "$vsha" != "-" ]; then
      stopped_note="           (newest completed run: $concl at ${csha:0:8}, stopped not judged — verdict above is the newest judged run)"$'\n'
      concl=$vconcl csha=$vsha cwhen=$vwhen curl=$vurl
    fi
    case "$(conclusion_class "$concl")" in
    red)
      red=$((red + 1))
      out="${out}  RED      $name — $concl at ${csha:0:8} ($cwhen)  $curl"$'\n'
      ;;
    green) out="${out}  green    $name — $concl at ${csha:0:8}"$'\n' ;;
    pending)
      pend=$((pend + 1))
      out="${out}  no verdict  $name — has never completed on $branch"$'\n'
      ;;
    *)
      pend=$((pend + 1))
      out="${out}  no verdict  $name — $concl at ${csha:0:8} (stopped, not judged; no earlier judged run in the window)  $curl"$'\n'
      ;;
    esac
    out="${out}${stopped_note}"
    # A run whose head is behind the tip is normal here (ci carries paths-ignore: docs/**), but it
    # means the verdict is about an older tree than the one you are about to branch from.
    [ "$csha" = "-" ] && csha=""
    if [ "$status" != completed ]; then
      out="${out}           ($name is running now at ${sha:0:8})"$'\n'
    elif [ -n "$tip" ] && [ -n "$csha" ] && [ "$csha" != "$tip" ]; then
      out="${out}           (that verdict is about ${csha:0:8}, not the tip ${tip:0:8})"$'\n'
    fi
  done <<<"$raw"
  if [ "$red" -gt 0 ]; then
    echo "!!! $REPO $branch is RED — $red workflow(s) failed on the tip you are about to branch from"
    printf '%s' "$out"
    echo "!!! Branching off a red base makes every later 'is this my change?' question expensive."
    echo "!!! Read the run above first: if it is already broken, say so before starting, and do not"
    echo "!!! spend the session bisecting someone else's break."
    return 1
  fi
  if [ -z "$out" ]; then
    echo "$REPO $branch: no build workflow has run on it (nothing to read, not a green light)"
    return 4
  fi
  if [ "$pend" -gt 0 ]; then
    echo "$REPO $branch: NO VERDICT${tip:+ (tip ${tip:0:8})} — some workflow was never judged here; not green, not red"
    printf '%s' "$out"
    return 4
  fi
  echo "$REPO $branch: green${tip:+ (tip ${tip:0:8})}"
  printf '%s' "$out"
  return 0
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
checks) shift && cmd_checks "$@" ;;
merge) shift && cmd_merge "$@" ;;
base) shift && cmd_base "$@" ;;
reply) shift && cmd_reply "$@" ;;
resolve) shift && cmd_resolve "$@" ;;
comment) shift && cmd_comment "$@" ;;
retry) shift && cmd_retry "$@" ;;
*) die "usage: pr-review.sh [--repo owner/name] {poll|watch|status|checks|merge|reply|resolve} <pr> ...
  pr-review.sh comment <pr> <body>           # a plain PR comment (a summary round, a review nudge)
  pr-review.sh base [owner/name] [branch]    # is the base branch's CI green? (start of work)
  pr-review.sh retry [--read] <gh args...>   # any other gh call, same retry policy
  <pr> is a number or owner/name#number; prefer owner/name#number for background invocations." ;;
esac
