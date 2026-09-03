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
#   - the reviewer ANNOUNCES a round by posting a placeholder comment the moment it starts (the
#     machine-tagged codex-pull-request-review-summary table, "🔄 Running"), so a new id above the
#     watermark is not yet something to act on — it is dropped from the rendering while the
#     watermark still advances past it, or every PR's watch wakes once for a round that has not
#     finished (one wasted wake + re-arm per PR, observed landing self-improve#10 and #13);
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
# The last thing `merge` reads before acting is how far the branch has fallen BEHIND its base and
# whether the base's advance touched any path changed by the PR, because a review is only ever
# about the code it was run against. On 2026-08-28
# (ocannl-staging#488) a merge was one keystroke away over a base 136 commits stale after SIXTEEN
# review rounds; master had meanwhile edited the very file the PR changed, and what caught it was a
# hand-run `git diff origin/master..HEAD --stat` whose 258 files and 14k deletions were visibly not
# the two-file branch. Nothing on the merge path had a reason to notice: the checks were green (on
# the stale head), the reviewer had approved (the stale diff), and `mergeable` was true (no textual
# conflict — semantic drift does not produce one). So the count is read from the compare API and
# WARNED about. It does not refuse — for one day (2026-08-29) it did, and the ahrefs/ocannl#861
# decision (2026-08-30) reverted that to the roll-forward policy: a clean merge proceeds on the
# head's green run, verification does not restart per sibling merge (the gate's cost was
# structural — #533 ran three full CI cycles over an unchanged diff), and what owns semantic
# drift after the fact is the wave coordinator's integration loop (issue-wave skill), which runs
# the full suites on merged master and stops the world on a regression. The overlap is exact or
# UNKNOWN: compare responses cap their file list at 300, so a capped list is never reported as
# "none". Both compare directions use the base and head SHAs from one PR read, and rename entries
# contribute both their current and previous filenames.
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
#   pr-review.sh base [owner/name] [branch] [--wait[=seconds]]
#                                          # is the branch you are about to work off CI-green?
#                                          # --wait holds until the CURRENT tip has its verdict —
#                                          # the post-merge integration read (see cmd_base)
#   pr-review.sh reply <pr> <comment-id> <body>
#   pr-review.sh resolve <pr> <comment-id>
#   pr-review.sh comment <pr> <body>       # a plain PR comment, for what has no thread to reply in:
#                                          # a review SUMMARY's findings, or a '@codex review' nudge
#   pr-review.sh retry [--read] <gh args...>
#                                          # any other gh call (pr merge, api) with the same retry
#                                          # policy, instead of a hand-rolled loop
#   pr-review.sh retry [--read] run watch <run-id> [-R owner/name]
#                                          # NOT forwarded to gh: executed as a QUIET await of that
#                                          # run — one verdict line instead of a stream of redraws,
#                                          # and a FAILED run is a verdict (exit 1), never retried
#                                          # as transport. For a PR, prefer `checks <pr> --wait`.
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
#      90), WATCH_TIMEOUT=seconds to watch (900), SHIP_PR_STATE_DIR=where the cache lives
#      (`off` disables the cache entirely — for sandboxes where even the attempted write warns),
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
#      SHIP_PR_BASE_ABSENT_GRACE=seconds `base --wait` allows for a run on the tip to APPEAR
#      before settling for an older verdict (300; paths-ignore pushes never get one),
#      SHIP_PR_STALE_BASE=commits behind the base at which `merge` warns loudly (20; `off`
#      silences the commit-count warning). A nonempty file overlap still warns at any count; no
#      base-drift warning blocks the merge.

set -uo pipefail

REPO="${REPO:-}"
REVIEWER="${REVIEWER:-chatgpt-codex-connector}"
STATE_DIR="${SHIP_PR_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/ship-pr}"
CACHE="$STATE_DIR/repo-by-pr"

# The cache is a convenience, never a requirement, and in a sandboxed worker the write ATTEMPT is
# what draws the harness's warning — on every call, when the state dir is unwritable and unreadable
# (ludics-lite#2: workers given explicit owner/name#number arguments, which never need the cache,
# still warned on each invocation). So it can be switched off outright (SHIP_PR_STATE_DIR=off),
# and a failed write latches WRITES off. The latch is a file, not a variable, because cache_put
# runs inside command substitutions (every `watch` round's poll is one), where a variable set
# there would not survive to the next round — and it must outlive the PROCESS too, since every
# documented pr-review.sh command is its own invocation and a per-process latch would re-attempt
# the prohibited write once per command (review of self-improve#13). Hence: keyed by the state
# dir (overriding SHIP_PR_STATE_DIR to a writable place re-enables caching instead of inheriting
# a stale latch), and deliberately NOT removed by the exit trap. Reads are gated only by the
# explicit off switch: a readable-but-unwritable cache keeps serving the mappings it already
# holds — reading costs no prohibited write, and disabling it would turn every later bare-number
# call into a usage failure over one unrelated write refusal (same review, round 4).
CACHE_OFF_FILE="${TMPDIR:-/tmp}/pr-review-nocache.$(printf '%s' "$STATE_DIR" | cksum | cut -d' ' -f1)"
case "$STATE_DIR" in off | none) CACHE_OFF=1 ;; *) CACHE_OFF="" ;; esac
cache_disabled() { [ -n "$CACHE_OFF" ]; }
cache_write_off() { cache_disabled || [ -e "$CACHE_OFF_FILE" ]; }

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
trap 'rm -f "$GH_ERR_FILE"' EXIT # NOT the cache latch — it must persist across invocations

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
  cache_disabled && return 1
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
  cache_write_off && return 0
  [ "$(cache_get "$1" 2>/dev/null)" = "$2" ] && return 0
  mkdir -p "$STATE_DIR" 2>/dev/null || {
    : >"$CACHE_OFF_FILE" 2>/dev/null
    return 0
  }
  local tmp="$CACHE.$$"
  {
    [ -f "$CACHE" ] && awk -v n="$1" '$1 != n' "$CACHE"
    echo "$1 $2"
  } >"$tmp" 2>/dev/null && mv -f "$tmp" "$CACHE" 2>/dev/null || : >"$CACHE_OFF_FILE" 2>/dev/null
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

  # The connector's "Review Summary" placeholder is machine-tagged with an HTML comment and posted
  # the moment a round STARTS ("🔄 Running"); it carries no findings, but its id is above the
  # watermark, so rendering it made `watch` return 0 with nothing to act on — one wasted wake and
  # re-arm per PR (observed landing self-improve#10, 2026-08-29, and again on #13 the day the fix
  # landed). It is dropped from the RENDERING only: the watermark below reads the unfiltered feed,
  # so its id is advanced past and never replayed. Nothing is lost by hiding it — the comment is
  # thereafter EDITED in place (same id, invisible to a watermark feed by construction), findings
  # arrive as reviews and inline comments, and a no-findings verdict arrives as the 👍 or as its
  # own "Didn't find any major issues" comment, both of which status_state reads live.
  jq -r --arg rev "$REVIEWER" --argjson since "$m_issue" '
    map(select((.user.login // "") | startswith($rev)) | select(.id > $since)
        | select((.body // "") | test("codex-pull-request-review-summary") | not))
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
  local vline verd_at verd_sha

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
  # EXCEPT the machine-tagged round-started placeholder (codex-pull-request-review-summary,
  # "🔄 Running"), which lands moments after the 👀 goes up: counting it as the last word makes a
  # LIVE 👀 look spent — a watch that saw `reviewing` then returns "ended without a review" after
  # two polls, and one that never did times out at the shorter grace while the round is still
  # running (review of self-improve#13). It is an announcement, not the reviewer speaking; the
  # verdict scan below still reads it, in case a verdict is ever delivered by editing it in place.
  raw=$(api_list "issues/$pr/comments?per_page=100") || {
    echo "unknown|-|the comments API did not answer ($(gh_err_line))"
    return 0
  }
  com_at=$(jq -r --arg rev "$REVIEWER" '
      [.[] | select((.user.login // "") | startswith($rev))
           | select((.body // "") | test("codex-pull-request-review-summary") | not)
           | .created_at] | max // ""' \
    <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|the comments feed did not parse"
    return 0
  }
  # The connector can deliver its no-findings verdict as an issue comment ("Codex Review:
  # Didn't find any major issues. ... **Reviewed commit:** `<sha>`") instead of — or as well
  # as — the 👍 reaction, and a re-requested review CLEARS the reaction while the comment
  # persists (ocannl-staging#531, 2026-08-29). Capture the newest such verdict and the commit
  # it names; whether it approves the CURRENT head is decided below, once the head is known.
  # The timestamp is updated_at, not created_at, and that carries a distinction: a verdict
  # delivered by EDITING the running placeholder in place bears the edit time (newer than the
  # round's 👀, as it must be to count), while a verdict comment left over from an earlier
  # round keeps its old time and loses to a fresh 👀 — the re-request-without-a-push case,
  # where the SHA still matches but a new round is running that may yet find something.
  vline=$(jq -r --arg rev "$REVIEWER" '
      [.[] | select((.user.login // "") | startswith($rev))
           | select((.body // "") | test("[Dd]idn.t find any major issues"))
           | {at: (.updated_at // .created_at),
              sha: (try ((.body // "")
                    | capture("Reviewed commit[^0-9a-fA-F]*(?<s>[0-9a-f]{7,40})").s)
                    catch "")}]
      | sort_by(.at) | last
      | if . == null then "|" else "\(.at)|\(.sha)" end' \
    <<<"$raw" 2>/dev/null) || vline="|"
  verd_at="${vline%%|*}"
  verd_sha="${vline#*|}"
  last_spoke=$(newest "$rev_at" "$com_at")

  # A no-findings verdict naming the CURRENT head outranks a live-looking 👀, and must be checked
  # BEFORE the in-flight return below: with the placeholder off the comment clock, a verdict
  # delivered by editing that placeholder in place leaves the 👀 newer than the reviewer's last
  # dated word, and the round would read as `reviewing` forever (the app does not always take the
  # 👀 back). Only a verdict NEWER than the 👀 qualifies — a re-requested review without a push
  # raises a fresh 👀 over a verdict whose SHA still matches, and approving on that would reopen
  # the merge gate under a round that is still running (see the updated_at note above for why an
  # edited placeholder passes this bar and a leftover comment does not). The head is read here
  # only when a qualifying verdict exists at all, so the common reviewing path stays one call
  # cheaper; a failed read falls through to the normal state logic rather than failing the
  # whole status.
  if [ -n "$verd_sha" ] && { [ -z "$eyes_at" ] || [[ "$verd_at" > "$eyes_at" ]]; }; then
    head_sha=$(gh_retry read api "repos/$REPO/pulls/$pr" --jq .head.sha) || head_sha=""
    if [ -n "$head_sha" ]; then
      case "$head_sha" in
      "$verd_sha"*)
        echo "approved|-|$REVIEWER posted a no-findings verdict for head ${head_sha:0:7} at $verd_at"
        return 0
        ;;
      esac
    fi
  fi

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

  # A verdict comment naming the current head is an approval — without this arm it reads as
  # "no review of this head", which is what invited the '@codex review' re-request that
  # destroyed the 👍 on #531. Prefix match: the comment quotes a truncated sha. The verdict must
  # also be no OLDER than the reviewer's last word: a re-requested round on the same head that
  # ended WITH findings spends the 👀 through its own review, and a SHA-only check here would
  # then approve on the previous round's verdict over those findings. Not-older (rather than
  # strictly newer) because the legitimate verdict usually IS the last word — the same comment
  # timestamps both sides of the comparison.
  if [ -n "$verd_sha" ] && ! [[ "$verd_at" < "$last_spoke" ]]; then
    case "$head_sha" in
    "$verd_sha"*)
      echo "approved|-|$REVIEWER posted a no-findings verdict for head ${head_sha:0:7} at $verd_at"
      return 0
      ;;
    esac
  fi

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
  stalled) echo "STALLED — $detail for $(fmt_age "$age"), longer than a round takes. FIRST read" \
    "the PR feed yourself (retry --read pr view <pr> --comments): a verdict may have landed as" \
    "a comment or a 👍 this state machine missed. Only if the feed truly has nothing for the" \
    "current head, nudge with a '@codex review' comment — knowing a re-request CLEARS the" \
    "reviewer's existing 👍" ;;
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

# `gh run watch` is the wrong tool on both of its ends, and workers keep reaching for it (the
# 2026-08-29 wave, ludics-lite#2). Its nonzero exit on a run that concluded FAILURE is a workflow
# VERDICT, but it arrives with no HTTP status on stderr, so the retry policy read it as transport:
# four attempts re-watching a run that had already completed, then "the API never answered" — a
# lie, it answered every time. And in a non-TTY shell its progress redraws accumulate; one session
# captured ~168k tokens of them. So `retry` does not forward `run watch` to gh at all: the await
# below polls `gh run view` on the checks cadence, prints a heartbeat line instead of redraws, and
# ends with ONE verdict line. Each poll keeps the usual transport retries. For a PR's build
# signal, prefer `checks <pr> --wait`, which reads EVERY check on the head commit, not one run.
#
# Exit codes, matching `checks`: 0 the run succeeded; 1 it concluded failure — a VERDICT, so do
# not retry the watch, read the run; 3 the API did not answer, so the run's state is UNKNOWN;
# 4 no verdict — still running at the deadline, or stopped without being judged (cancelled).
cmd_run_watch() {
  local run_id="" repo="" interval="$CHECKS_INTERVAL" line rc status concl sleep_for remaining
  while [ $# -gt 0 ]; do
    case "$1" in
    -R | --repo)
      repo="${2:?$1 needs owner/name}"
      shift
      ;;
    -R=* | --repo=*) repo="${1#*=}" ;;
    -i | --interval)
      interval="${2:?$1 needs seconds}"
      shift
      ;;
    -i=* | --interval=*) interval="${1#*=}" ;;
    [0-9]*)
      [ -z "$run_id" ] || die "run watch: got two run ids ('$run_id' and '$1') — name exactly one"
      run_id="$1"
      ;;
    # The two native flags whose meaning this await subsumes are accepted as no-ops so a pasted
    # `gh run watch` line keeps working; everything ELSE dies loudly. A catch-all that discards
    # an argument turns a mistyped repo flag into a watch against whatever REPO or the cwd
    # resolves to — the wrong-target failure the strict pr_arg parse exists to prevent.
    --exit-status | --compact) ;;
    -*) die "run watch: unsupported flag '$1' — the quiet await takes <run-id>, -R/--repo," \
      "-i/--interval, --exit-status, --compact" ;;
    *) die "run watch: unexpected argument '$1' — the run id is a bare number" ;;
    esac
    shift
  done
  case "$run_id" in
  '' | *[!0-9]*) die "retry run watch: name the run id (a number) — the quiet await polls" \
    "\`gh run view <id>\`. For a PR's checks, prefer \`checks <pr> --wait\`." ;;
  esac
  case "$interval" in '' | *[!0-9]*) die "run watch: the interval must be seconds, got '$interval'" ;; esac
  # `gh run watch` documents -i as seconds and defaults to 3; 0 would turn the quiet await into a
  # rate-limit-burning busy loop of API reads for up to the full two-hour ceiling.
  [ "$interval" -gt 0 ] || die "run watch: the interval must be at least 1 second, got '$interval'"
  [ -n "$repo" ] || repo="$REPO"
  [ -n "$repo" ] || repo=$(repo_from_cwd) || true
  [ -n "$repo" ] || die "run watch: name the repo (-R owner/name, --repo, or REPO=) —" \
    "cwd inference only works from a checkout, and not from a background shell."
  local started deadline beat now
  started=$(date +%s)
  deadline=$((started + CHECKS_WAIT))
  beat=$started
  while :; do
    line=$(gh_retry read run view "$run_id" --repo "$repo" --json status,conclusion \
      --jq '[.status, (.conclusion // "pending")] | @tsv')
    rc=$?
    if [ "$rc" -ne 0 ]; then
      api_rejection "$(gh_err_line)" &&
        fail 1 "run $run_id was not readable in $repo: $(gh_err_line) — check the id and the repo"
      fail 3 "could not read run $run_id in $repo after $API_ATTEMPTS attempts ($(gh_err_line));" \
        "the run's state is UNKNOWN — not failed, not passed. Retry rather than concluding."
    fi
    IFS=$'\t' read -r status concl <<<"$line"
    [ "$status" = completed ] && break
    now=$(date +%s)
    [ "$now" -lt "$deadline" ] || fail 4 "run $run_id in $repo has NO VERDICT after" \
      "$((CHECKS_WAIT / 60)) min (status: ${status:-unknown}) — that is still not a failure;" \
      "re-arm the await, or read it with: gh run view $run_id --repo $repo"
    if [ $((now - beat)) -ge "$CHECKS_HEARTBEAT" ]; then
      warn "still waiting on run $run_id in $repo: ${status:-unknown} after" \
        "$(((now - started) / 60)) min"
      beat=$now
    fi
    # Capped at the remaining deadline: -i is a documented pass-through, and an interval longer
    # than what is left would sleep the process hours past the advertised ceiling before the
    # clock is checked again.
    remaining=$((deadline - now))
    sleep_for="$interval"
    [ "$sleep_for" -le "$remaining" ] || sleep_for="$remaining"
    sleep "$sleep_for"
  done
  case "$(conclusion_class "$concl")" in
  green)
    echo "run $run_id in $repo: $concl"
    return 0
    ;;
  red) fail 1 "run $run_id in $repo concluded $concl — the run FAILED. That is the workflow's" \
    "verdict, not transport: do not retry the watch; read the failure with:" \
    "gh run view $run_id --repo $repo --log-failed" ;;
  *) fail 4 "run $run_id in $repo concluded $concl — stopped, not judged (a superseding push or" \
    "a manual cancel); re-run the workflow to turn it into an answer" ;;
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
  if [ "${1:-}" = run ] && [ "${2:-}" = watch ]; then
    shift 2
    cmd_run_watch "$@"
    return
  fi
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
BASE_ABSENT_GRACE="${SHIP_PR_BASE_ABSENT_GRACE:-300}"
# Whole seconds, validated up front: these feed shell arithmetic (deadlines, heartbeats, and the
# sleep caps against the remaining deadline), where a fractional value does not degrade gracefully
# — `[ 0.5 -le N ]` errors and takes the fallback arm, which for the interval means one read and
# then a sleep to the full ceiling. A zero interval would busy-loop the API instead of pacing it.
case "$BASE_ABSENT_GRACE" in
'' | *[!0-9]*) die "SHIP_PR_BASE_ABSENT_GRACE must be a number of seconds, got '$BASE_ABSENT_GRACE'" ;;
esac
case "$CHECKS_INTERVAL" in
'' | *[!0-9]*) die "SHIP_PR_CHECKS_INTERVAL must be whole seconds, got '$CHECKS_INTERVAL'" ;;
esac
[ "$CHECKS_INTERVAL" -gt 0 ] || die "SHIP_PR_CHECKS_INTERVAL must be at least 1 second, got '$CHECKS_INTERVAL'"
case "$CHECKS_WAIT" in
'' | *[!0-9]*) die "SHIP_PR_CHECKS_WAIT must be whole seconds, got '$CHECKS_WAIT'" ;;
esac
case "$CHECKS_HEARTBEAT" in
'' | *[!0-9]*) die "SHIP_PR_CHECKS_HEARTBEAT must be whole seconds, got '$CHECKS_HEARTBEAT'" ;;
esac

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
  local pr="$1" wait_for="${2:-0}" sha lines rc deadline started beat now sleep_for remaining
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
    # Capped at the remaining deadline, same as cmd_base and cmd_run_watch: an interval longer
    # than what is left would sleep the process past the advertised ceiling before the clock is
    # checked again.
    remaining=$((deadline - now))
    sleep_for="$CHECKS_INTERVAL"
    [ "$sleep_for" -le "$remaining" ] || sleep_for="$remaining"
    sleep "$sleep_for"
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

# Prints the count and exact path overlap, loudly when the count is at or over the threshold or any
# path overlaps. Returns 0 fresh enough with no overlap, 1 for either warning, 3 when the count or
# overlap is unknown. For one day (2026-08-29) the merge path treated 1 as a GATE; the
# ahrefs/ocannl#861 decision (2026-08-30) reverted it to a WARNING under the roll-forward policy:
# a PR merges on one green full-matrix run for its LAST commit, a clean merge does not restart
# verification, and only a conflict-RESOLVING commit needs green CI after it — which the checks
# gate reads naturally, that commit being the new head. The gate's cost was structural (every
# sibling merge invalidated every open PR's verification; #533 ran three complete rebase+CI
# cycles over an unchanged topic diff), and #488's semantic-drift risk is owned after the fact by
# the wave's integration loop (issue-wave skill: full suites on merged master, stop-the-world on
# regression). The DIFFERENCE between "not behind" and "could not be read" is preserved here like
# everywhere else in this file: a compare call that never answered must not print a reassuring
# number.
warn_base_drift() {
  local pr="$1" fields base base_sha head_sha rc
  local forward reverse behind ahead forward_base reverse_base
  local pr_files base_files pr_file_count base_file_count overlap overlap_count
  local count_unknown="" overlap_unknown="" overlap_reason="" count_warn=""
  # Placeholders, never empty fields: tab is IFS whitespace, so an empty middle column would shift
  # a SHA into the wrong field (the same trap build_checks documents). Capture both endpoint SHAs
  # in this one read: labels can move, and the base can advance between the two compare calls.
  fields=$(gh_retry read api "repos/$REPO/pulls/$pr" \
    --jq '[(.base.ref // "-"), (.base.sha // "-"), (.head.sha // "-")] | @tsv')
  rc=$?
  IFS=$'\t' read -r base base_sha head_sha <<<"$fields"
  if [ "$rc" -ne 0 ] || [ -z "$base" ] || [ "$base" = - ] ||
    [ -z "$base_sha" ] || [ "$base_sha" = - ] || [ -z "$head_sha" ] || [ "$head_sha" = - ]; then
    warn "how far $REPO#$pr is behind its base: UNKNOWN — the PR could not be read" \
      "($(gh_err_line)). This is not 'not behind': check it by hand before merging" \
      "and do not assume the base-drift file overlap is empty."
    echo "base-drift file overlap $REPO#$pr: UNKNOWN — the PR snapshot could not be read"
    return 3
  fi

  # Compare the captured endpoints in both directions. Each direction's files are changes from
  # their common merge base to that direction's head: base...head is the PR, head...base is the
  # base advance. Exact SHAs also make fork labels irrelevant once GitHub has admitted the PR.
  # per_page=1 trims only the commit list. GitHub still returns the first (and only) file list, but
  # caps it at 300 entries for the whole comparison; length 300 is therefore potentially truncated.
  forward=$(gh_retry read api "repos/$REPO/compare/$base_sha...$head_sha?per_page=1")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "how far $REPO#$pr is behind $base: UNKNOWN — the compare call did not answer" \
      "($(gh_err_line)). The base-drift file overlap is UNKNOWN too, not none; retry before" \
      "merging."
    echo "base-drift file overlap $REPO#$pr: UNKNOWN — the forward compare call did not answer"
    return 3
  fi

  behind=$(jq -er '.behind_by | numbers | select(. >= 0 and floor == .) | tostring' \
    <<<"$forward" 2>/dev/null) || count_unknown=1
  ahead=$(jq -er '.ahead_by | numbers | select(. >= 0 and floor == .) | tostring' \
    <<<"$forward" 2>/dev/null) || ahead="?"
  forward_base=$(jq -er '.merge_base_commit.sha | strings | select(length > 0)' \
    <<<"$forward" 2>/dev/null) || overlap_unknown=1
  pr_files=$(jq -ce '
    if (.files | type) == "array" then
      [.files[] | .filename, .previous_filename?]
      | map(select(type == "string")) | unique
    else error("missing files") end' <<<"$forward" 2>/dev/null) || overlap_unknown=1
  pr_file_count=$(jq -er 'if (.files | type) == "array" then .files | length
    else error("missing files") end' <<<"$forward" 2>/dev/null) || overlap_unknown=1

  reverse=$(gh_retry read api "repos/$REPO/compare/$head_sha...$base_sha?per_page=1")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    overlap_unknown=1
    overlap_reason="the reverse compare call did not answer ($(gh_err_line))"
  else
    reverse_base=$(jq -er '.merge_base_commit.sha | strings | select(length > 0)' \
      <<<"$reverse" 2>/dev/null) || overlap_unknown=1
    base_files=$(jq -ce '
      if (.files | type) == "array" then
        [.files[] | .filename, .previous_filename?]
        | map(select(type == "string")) | unique
      else error("missing files") end' <<<"$reverse" 2>/dev/null) || overlap_unknown=1
    base_file_count=$(jq -er 'if (.files | type) == "array" then .files | length
      else error("missing files") end' <<<"$reverse" 2>/dev/null) || overlap_unknown=1
  fi

  if [ -z "$overlap_unknown" ] && [ "$forward_base" != "$reverse_base" ]; then
    overlap_unknown=1
    overlap_reason="the two compare calls reported different merge bases"
  fi
  if [ -z "$overlap_unknown" ] &&
    { [ "$pr_file_count" -ge 300 ] || [ "$base_file_count" -ge 300 ]; }; then
    overlap_unknown=1
    overlap_reason="a compare file list reached GitHub's 300-file cap and may be truncated"
  fi
  if [ -z "$overlap_unknown" ]; then
    overlap=$(jq -cn --argjson pr "$pr_files" --argjson base "$base_files" '
      [$pr[] | select(. as $path | $base | index($path))] | unique') || overlap_unknown=1
    overlap_count=$(jq -er 'length' <<<"$overlap" 2>/dev/null) || overlap_unknown=1
  fi

  if [ -n "$count_unknown" ]; then
    warn "how far $REPO#$pr is behind $base: UNKNOWN — the compare response did not contain a" \
      "valid behind_by count. This is not 'not behind'."
  elif [ "$STALE_BASE" = off ]; then
    : # only the count warning is disabled; the path-overlap warning below remains active
  elif [ "$behind" -lt "$STALE_BASE" ]; then
    echo "base freshness $REPO#$pr: $behind commit(s) behind $base, $ahead ahead" \
      "(warns at $STALE_BASE)"
  else
    count_warn=1
    echo "!!! $REPO#$pr is $behind COMMITS BEHIND its base ($base)."
    echo "!!! The review that approved this branch, and the checks that went green on it, both judged"
    echo "!!! it against a base that has since moved $behind commits. Under the roll-forward policy"
    echo "!!! (ahrefs/ocannl#861) this does NOT block a clean merge — the post-merge integration loop"
    echo "!!! re-runs the full suites on merged master — but a clean 'mergeable' says only that the"
    echo "!!! two texts do not collide. Read the base-drift file intersection printed below."
  fi

  if [ -n "$overlap_unknown" ]; then
    [ -n "$overlap_reason" ] || overlap_reason="a compare response was incomplete or invalid"
    echo "base-drift file overlap $REPO#$pr: UNKNOWN — $overlap_reason"
    warn "BASE-DRIFT FILE OVERLAP UNKNOWN for $REPO#$pr — this is not 'none'; retry the merge" \
      "read before deciding whether the branch needs a rebase."
  elif [ "$overlap_count" -eq 0 ]; then
    echo "base-drift file overlap $REPO#$pr: none"
  else
    echo "!!! BASE-DRIFT FILE OVERLAP: the base's advance touched $overlap_count path(s) changed by"
    echo "!!! $REPO#$pr: $overlap"
    echo "!!! Rebase (or merge $base in where the branch is shared), push, and let checks re-run."
    warn "BASE-DRIFT FILE OVERLAP for $REPO#$pr: $overlap — this warning applies even below" \
      "SHIP_PR_STALE_BASE, but does not block the merge under the roll-forward policy."
  fi

  if [ -n "$count_warn" ]; then
    warn "MERGING A STALE BRANCH: $REPO#$pr is $behind commits behind $base (warns at $STALE_BASE," \
      "SHIP_PR_STALE_BASE) — a clean merge is the policy (roll-forward, ahrefs/ocannl#861)."
  fi
  if [ -n "$count_unknown" ] || [ -n "$overlap_unknown" ]; then
    return 3
  fi
  if [ -n "$count_warn" ] || [ "${overlap_count:-0}" -gt 0 ]; then
    return 1
  fi
  return 0
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
  # Last, so that it is read AFTER a --wait (the base keeps moving during one) and so that its
  # verdict is the final thing on screen before the merge itself. A loud WARNING, not a gate: the
  # roll-forward policy (ahrefs/ocannl#861, see warn_base_drift) lets a clean merge proceed on the
  # head's green run, and hands semantic drift to the post-merge integration loop. A 3 (unread)
  # has already said UNKNOWN loudly; neither outcome blocks the merge.
  warn_base_drift "$PR_NUM" || true
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

# A branch name is data, not URL structure: `release#1` and `release&one` are valid refs, but
# interpolated raw into a REST path or query the `#` truncates the request at the fragment and the
# `&` splits it into another parameter — so `base` would read some OTHER branch's tip and runs.
# Percent-encode every byte outside the unreserved set, keeping `/` literal (slashed branch names
# are the common case, and a literal `/` is valid in both a path segment sequence and a query
# value, while `+` is not — in a query it decodes as a space).
encode_ref() {
  # LC_ALL=C so the loop walks BYTES; the ordinal of a high byte sign-extends on some shells, so
  # mask it back to one byte before formatting (UTF-8 branch names encode per byte).
  local LC_ALL=C s="$1" out="" c i o
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case "$c" in
    [a-zA-Z0-9._~/-]) out+="$c" ;;
    *)
      printf -v o '%d' "'$c"
      printf -v c '%%%02X' "$((o & 255))"
      out+="$c"
      ;;
    esac
  done
  printf '%s' "$out"
}

# The other half of #694: the confusion actually lands on whoever branches off a broken master.
# Read the base's own CI before starting work, not only before merging.
#
# --wait exists for the OTHER end of a branch's life: the roll-forward policy's standalone
# complement (ahrefs/ocannl#861, review of self-improve#13) is "after a stale-warned merge, read
# the base's CI on what you just landed" — and a plain `base` seconds after a merge answers with
# the PREVIOUS tip's green, because the merge's own run is still queued or does not exist yet
# (the same not-created-yet window as the force-push ABSENT trap on the merge path). Declaring
# integration green off that is the stale reading this command exists to prevent. So --wait
# re-reads until nothing non-advisory is mid-flight AND every non-advisory workflow's newest
# judged run is about the CURRENT tip — or, when no run for the tip has appeared and none is
# running, until a grace expires (SHIP_PR_BASE_ABSENT_GRACE; paths-ignore means a docs-only push
# legitimately never gets one, and only the grace separates "never coming" from "not yet"). A
# red breaks the wait immediately: it is a verdict.
cmd_base() {
  local branch="" tip raw rc line name status sha concl csha cwhen curl red=0 pend=0 out=""
  local vconcl vsha vwhen vurl stopped_note wait_for=0 inflight=0 uncovered=0 red_at_tip=0
  local nogo_at_tip=0 last_tip="" grace_from confirm wf="" wid wname part sleep_for remaining
  local norun=0 tip_seen_at tip_age hold ebranch
  local started now beat waited_note="" no_tip_verdict=""
  while [ $# -gt 0 ]; do
    case "$1" in
    # First slashed arg is the repo UNLESS one is already named (--repo, REPO=, or an earlier
    # positional): branches carry slashes too (claude/...), and reading one as the repo turns
    # `base --repo owner/name claude/topic` into a 404 on repo "claude/topic".
    */*) if [ -z "$REPO" ]; then REPO="$1"; else branch="$1"; fi ;;
    --wait) wait_for="$CHECKS_WAIT" ;;
    --wait=*) wait_for="${1#--wait=}" ;;
    -*) die "base: unknown option '$1'" ;;
    *) branch="$1" ;;
    esac
    shift
  done
  case "$wait_for" in '' | *[!0-9]*) die "base: --wait takes seconds, got '$wait_for'" ;; esac
  [ -n "$REPO" ] || REPO=$(repo_from_cwd) || true
  [ -n "$REPO" ] || die "base: name the repo — \`base owner/name [branch]\`, --repo, or REPO=." \
    "cwd inference only works from a checkout, and not from a background shell."
  if [ -z "$branch" ]; then
    branch=$(gh_retry read api "repos/$REPO" --jq .default_branch)
    [ $? -eq 0 ] && [ -n "$branch" ] || fail 3 "could not read $REPO's default branch" \
      "($(gh_err_line)) — the base's health is UNKNOWN, which is not 'fine'."
  fi
  ebranch=$(encode_ref "$branch")
  started=$(date +%s)
  beat=$started
  grace_from=$started
  while :; do
    red=0 pend=0 out="" inflight=0 uncovered=0 red_at_tip=0 nogo_at_tip=0 norun=0
    # Tip re-read every round: the wait's covered-ness is against wherever the branch is NOW, so
    # a further push during the wait moves the goal with it (its run includes the older merges).
    tip=$(gh_retry read api "repos/$REPO/commits/$ebranch" --jq .sha) || tip=""
    # Without --wait the tip only decorates the report, so a failed read costs the "not the tip"
    # notes. Under --wait it is the QUESTION — which commit needs the verdict — and an unknown
    # tip would idle to the absent-run grace and then settle for an older green, exit 0, having
    # never known what it was waiting for. UNKNOWN is the only honest answer there.
    [ -n "$tip" ] || [ "$wait_for" -eq 0 ] ||
      fail 3 "could not read $REPO $branch's tip ($(gh_err_line)) — base --wait cannot know" \
        "which commit needs the verdict. This is UNKNOWN, not green: retry."
    # The workflow list is (re-)read whenever the observed tip moves — a sibling merge landing
    # mid-wait can ADD a workflow, and a stale snapshot would never query it: the old set going
    # fully covered would then read as green over a new workflow still pending or red. Runs are
    # then fetched PER WORKFLOW, not as one flat page: on an active branch, a page of mixed runs
    # can entirely postdate an infrequent workflow's newest run, and a workflow the fold never
    # sees is neither uncovered nor red — its standing verdict simply vanishes from the report
    # (review of self-improve#13, rounds 5-6). The list itself is one page of 100: a repo with
    # more real workflows than that has bigger problems than this report.
    if [ "$tip" != "$last_tip" ] || [ -z "$wf" ]; then
      wf=$(gh_retry read api "repos/$REPO/actions/workflows?per_page=100" \
        --jq '.workflows[] | [(.id | tostring), .name] | @tsv')
      rc=$?
      [ "$rc" -eq 0 ] || fail 3 "could not read $REPO's workflow list ($(gh_err_line));" \
        "the base's health is UNKNOWN, which is NOT 'green'."
    fi
    raw=""
    while IFS=$'\t' read -r wid wname; do
      [ -n "$wid" ] || continue
      is_advisory "$wname" && continue
      # The workflow ID leads each row so the fold can group by it: two workflow FILES can share
      # one display name, and a name-keyed fold would collapse them into a single row — the
      # first-listed one's green masking the other still running or red (round 9).
      part=$(gh_retry read api \
        "repos/$REPO/actions/workflows/$wid/runs?branch=$ebranch&event=push&per_page=10" \
        --jq '.workflow_runs[] | [(.workflow_id | tostring), .name, .status,
              (.conclusion // "pending"), .head_sha, .created_at, (.html_url // "-")] | @tsv')
      rc=$?
      [ "$rc" -eq 0 ] || fail 3 "could not read $REPO's '$wname' runs on $branch" \
        "($(gh_err_line)); the base's health is UNKNOWN, which is NOT 'green'."
      if [ -n "$part" ]; then
        raw="${raw}${part}"$'\n'
      else
        # A listed non-advisory workflow with NO push runs on this branch yet — just added, or
        # its first run not created — is still unjudged at the tip. Dropping it here let the
        # OTHER workflows' coverage read as immediately green, with no creation grace for the
        # newcomer that may then fail (round 7).
        norun=$((norun + 1))
      fi
    done <<<"$wf"
    # Empty result must short-circuit the fold: one empty line through tab-IFS `read` collapses
    # into shifted fields (tab is IFS whitespace), which used to render as a phantom workflow —
    # and a branch with no push-event runs would headline green with exit 0. Under --wait it is
    # the not-created-yet window instead, until the grace says otherwise.
    if [ -z "$raw" ]; then
      uncovered=1
    else
      # Newest first, so per workflow: the newest run at all (is one in flight?), the newest
      # COMPLETED one, and the newest run with an actual VERDICT (red/green). The last one is what
      # answers "is this base broken": under cancel-in-progress concurrency the newest completed
      # run on a busy default branch is routinely `cancelled` — stopped, not judged — and reading
      # that as either green or "no verdict" would be wrong (an older run usually did judge an
      # earlier tip). Same empty-field rule as build_checks: a workflow with no completed run yet
      # leaves these columns unset, and unset prints as empty, which `IFS=$'\t' read` would
      # collapse.
      # Grouped by the leading workflow ID — the name is display only (two files can share it).
      raw=$(awk -F'\t' '
        $1 == "" { next } # the per-workflow assembly ends with a newline, and an empty record
                          # here becomes a phantom workflow whose empty id shifts every later
                          # field left through tab-IFS (seen live: a workflow named "pending")
        { k=$1
          if (!(k in seen)) { seen[k]=1; order[++n]=k; nm[k]=$2; lstatus[k]=$3; lsha[k]=$5 }
          if ($3 == "completed" && !(k in done)) { done[k]=1; c[k]=$4; csha[k]=$5; cw[k]=$6; cu[k]=$7 }
          if ($3 == "completed" && !(k in vdone) && \
              ($4 == "failure" || $4 == "timed_out" || $4 == "startup_failure" || \
               $4 == "success" || $4 == "skipped" || $4 == "neutral")) {
            vdone[k]=1; v[k]=$4; vs[k]=$5; vw[k]=$6; vu[k]=$7 }
        }
        END { for (i=1;i<=n;i++) { k=order[i]
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", nm[k], lstatus[k], lsha[k],
              (k in done ? c[k] : "pending"), (k in done ? csha[k] : "-"),
              (k in done ? cw[k] : "-"), (k in done ? cu[k] : "-"),
              (k in vdone ? v[k] : "-"), (k in vdone ? vs[k] : "-"),
              (k in vdone ? vw[k] : "-"), (k in vdone ? vu[k] : "-") } }
      ' <<<"$raw")
      while IFS=$'\t' read -r name status sha concl csha cwhen curl vconcl vsha vwhen vurl; do
        [ -n "$name" ] || continue
        is_advisory "$name" && continue
        [ "$status" = completed ] || inflight=$((inflight + 1))
        [ -n "$tip" ] && [ "$vsha" = "$tip" ] || uncovered=$((uncovered + 1))
        # A tip run that completed stopped-not-judged (cancelled/stale/action_required) is NOT
        # the same absence as a run that never existed: one wants a re-run, the other may be
        # paths-ignore. Recorded here, before the nogo-swap below overwrites concl/csha.
        [ "$(conclusion_class "$concl")" = nogo ] && [ -n "$tip" ] && [ "$csha" = "$tip" ] &&
          nogo_at_tip=$((nogo_at_tip + 1))
        # Newest completed run stopped-not-judged (cancelled/stale/action_required): the newest
        # JUDGED run carries the verdict — a red under a cancelled run is not an all-clear — and
        # the stopped run becomes context. Only when NO run ever judged this branch is there no
        # verdict.
        stopped_note=""
        if [ "$(conclusion_class "$concl")" = nogo ] && [ "$vsha" != "-" ]; then
          stopped_note="           (newest completed run: $concl at ${csha:0:8}, stopped not judged — verdict above is the newest judged run)"$'\n'
          concl=$vconcl csha=$vsha cwhen=$vwhen curl=$vurl
        fi
        case "$(conclusion_class "$concl")" in
        red)
          red=$((red + 1))
          [ -n "$tip" ] && [ "$csha" = "$tip" ] && red_at_tip=$((red_at_tip + 1))
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
        # A run whose head is behind the tip is normal here (ci carries paths-ignore: docs/**),
        # but it means the verdict is about an older tree than the one you are about to branch
        # from.
        [ "$csha" = "-" ] && csha=""
        if [ "$status" != completed ]; then
          out="${out}           ($name is running now at ${sha:0:8})"$'\n'
        elif [ -n "$tip" ] && [ -n "$csha" ] && [ "$csha" != "$tip" ]; then
          out="${out}           (that verdict is about ${csha:0:8}, not the tip ${tip:0:8})"$'\n'
        fi
      done <<<"$raw"
    fi
    [ "$wait_for" -gt 0 ] || break
    # Only a red AT THE TIP ends the wait early — it is the tip's own verdict. An older tip's red
    # while the current tip's run is still in flight is precisely the fix-in-progress shape:
    # breaking on it would report RED for a commit that has no verdict yet and trigger the
    # fix-forward response against a fix already running. The older red keeps the wait; when the
    # tip's run completes, the newest-judged fold replaces it either way. The break reconfirms
    # the tip first, the same TOCTOU as the green break: a fix-forward push landing between the
    # tip read and this check turns this red into an older tip's red — exactly the shape this
    # gate exists to keep waiting on — so on a moved (or unconfirmable) tip, poll again instead.
    if [ "$red_at_tip" -gt 0 ]; then
      confirm=$(gh_retry read api "repos/$REPO/commits/$ebranch" --jq .sha) || confirm=""
      [ "$confirm" = "$tip" ] && break
    fi
    now=$(date +%s)
    # The absence grace runs from the last time the TIP MOVED, not from when the wait started: a
    # further merge landing after the grace had already elapsed would otherwise be declared
    # integration-green on the spot, its run not yet created and the timer long spent.
    if [ "$tip" != "$last_tip" ]; then
      last_tip="$tip"
      grace_from=$now
    fi
    if [ "$inflight" -eq 0 ]; then
      if [ "$uncovered" -eq 0 ]; then
        # A listed workflow with NO push runs on the branch (norun) is ambiguous: dispatch- or
        # schedule-only (never coming — staging carries two such smoke workflows, and counting
        # them as uncovered would park EVERY wait on the full grace), or a push workflow the tip
        # itself just added, whose first run is not created yet. What separates them is whether
        # the newcomer has had its creation window SINCE THE PUSH — and the push time is the
        # sibling runs' own creation time at this tip (every workflow here is judged at the tip,
        # so sibling rows exist to read: folded col 5 is the newest completed run's sha, col 6
        # its created_at). Not the commit's committer date (an hours-old commit pushed directly
        # would erase the window) and not the wait's observation clock (which would hold every
        # late-started wait on a repo carrying dispatch-only workflows for the full grace).
        hold=""
        if [ "$norun" -gt 0 ]; then
          tip_seen_at=$(awk -F'\t' -v t="$tip" \
            '$5 == t && $6 > best { best=$6 } END { print best }' <<<"$raw")
          tip_age=$(age_of "$tip_seen_at")
          case "$tip_age" in
          '' | *[!0-9]*) ;; # unreadable age is not evidence to hold on
          *) [ "$tip_age" -ge "$BASE_ABSENT_GRACE" ] || hold=1 ;;
          esac
        fi
        # Covered — against the tip read BEFORE the runs. A sibling merge landing between those
        # two reads is the integration loop's normal traffic, and would make this a false green
        # for a branch already pointing elsewhere: accept coverage only when the tip has not
        # moved meanwhile; otherwise fall through to the sleep and let the next round re-read
        # everything (the tip-change branch above restarts the grace).
        if [ -z "$hold" ]; then
          confirm=$(gh_retry read api "repos/$REPO/commits/$ebranch" --jq .sha) || confirm=""
          [ "$confirm" = "$tip" ] && break
        fi
      # Nothing running and the tip unjudged. A tip run that completed STOPPED (cancelled/stale)
      # is not absence — it existed and was not judged, so no amount of paths-ignore explains it;
      # the grace only allows for a superseding replacement to be created, and then the verdict
      # is "none". A tip with NO run is either the not-created-yet window or paths-ignore, and
      # only time tells those apart: after the grace, settle for what is there — the
      # per-workflow lines name which commit each verdict is actually about.
      elif [ $((now - grace_from)) -ge "$BASE_ABSENT_GRACE" ]; then
        if [ "$nogo_at_tip" -gt 0 ]; then
          waited_note="(the tip's newest run completed stopped-not-judged and no replacement appeared within the grace — NOT absence and NOT a verdict: re-run the workflow)"
          no_tip_verdict=1
        else
          waited_note="(waited $(((now - started) / 60)) min: no run for the tip appeared and none is in flight — the verdicts above may trail it)"
        fi
        break
      fi
    fi
    [ $((now - started)) -lt "$wait_for" ] || {
      waited_note="(--wait ceiling of $((wait_for / 60)) min reached with a run still unfinished or the tip unjudged — NOT a verdict for the tip)"
      no_tip_verdict=1
      break
    }
    if [ $((now - beat)) -ge "$CHECKS_HEARTBEAT" ]; then
      warn "still waiting on $REPO $branch: $inflight run(s) in flight, $uncovered workflow(s)" \
        "not yet judged at the tip, after $(((now - started) / 60)) min"
      beat=$now
    fi
    # Capped at the remaining ceiling: an interval longer than what is left would carry the
    # process past the advertised deadline before the clock is checked again.
    remaining=$((started + wait_for - now))
    sleep_for="$CHECKS_INTERVAL"
    [ "$sleep_for" -le "$remaining" ] || sleep_for="$remaining"
    sleep "$sleep_for"
  done
  [ -n "$waited_note" ] && echo "$waited_note"
  # A wait that ended WITHOUT the tip's verdict says exactly that, BEFORE the red branch below: at
  # the ceiling with an older tip's red standing, that branch would headline "failed on the tip
  # you are about to branch from" with exit 1 — a claim about a commit that has no verdict yet. A
  # red AT the tip broke the wait before this flag could be set, so it still reports as red; the
  # older red stays visible in the per-workflow lines under the honest headline.
  if [ -n "$no_tip_verdict" ]; then
    echo "$REPO $branch: NO VERDICT for the tip${tip:+ ${tip:0:8}} — not green, not red (see above)"
    printf '%s' "$out"
    return 4
  fi
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
main() {
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
  pr-review.sh base [owner/name] [branch] [--wait]  # is the base branch's CI green? (start of
                                             # work; --wait = post-merge integration read)
  pr-review.sh retry [--read] <gh args...>   # any other gh call, same retry policy
  pr-review.sh retry run watch <run-id> [-R owner/name]  # quiet await of ONE run (never forwarded
                                             # to gh); for a PR prefer: checks <pr> --wait
  <pr> is a number or owner/name#number; prefer owner/name#number for background invocations." ;;
  esac
}

# Focused tests source the functions and replace gh with a fixture transport; do not expose a
# user-facing testing subcommand or make them pass through the unrelated build and merge gates.
[ "${SHIP_PR_TEST_SOURCE_ONLY:-}" = 1 ] || main "$@"
