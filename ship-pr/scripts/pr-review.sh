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
#   - a PR number names one PR in EVERY repository, so a repo that was not spelled out in the
#     invocation is a guess about intent that no read can check — the repo travels in the PR
#     argument (owner/name#number), and a bare number with no repo named is refused;
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
#   - the reviewer posts one finding as several inline threads often enough to matter (round 11 of
#     ludics-lite#66: nine threads for four findings), and each duplicate then costs its own
#     composed reply and its own resolve — and it duplicates by RE-WRITING, so the copies share
#     their anchor exactly and share no byte of their text. So threads at the SAME anchor (path,
#     commit, author and every location field the row carries) fold into one entry listing every
#     thread id and printing every distinct body, and `reply`/`resolve` take that list, so a
#     duplicate costs one answer (ludics-lite#76);
#   - the reviewer's own utterances are that clock, NOT the head commit: a 👀 raised just before
#     your next push is a round that is genuinely running (seen live on #358 the same evening — 👀
#     at 20:34:13Z, head committed 20:35:01Z), so "older than the head commit" would declare an
#     in-flight round spent and nudge on top of it;
#   - whether the reviewer has SEEN the head is a SHA equality, not a time comparison: every review
#     records the commit_id it was submitted against, so comparing that to .head.sha answers the
#     question exactly — no guessing at a push time, and immune to a commit whose author date long
#     predates the push that delivered it;
#   - the same equality decides what ENDS a wait, and `watch` used to skip it: a new id above the
#     watermark is not the round you are waiting for unless it is about the head you are watching.
#     A round's watch exits on the inline findings and takes its watermark from that poll; the
#     reviewer's separate summary review lands seconds later with a higher id; and the next
#     window returns 0 on it immediately, with nothing about the new head to act on (ludics-lite
#     #72). So every item poll renders carries the commit it is about (a review's commit_id, an
#     inline comment's original_commit_id — commit_id MIGRATES to the current head as the branch
#     advances — and a comment's "Reviewed commit:" stamp), and one about another commit is
#     printed for the record while the watermark advances past it and the wait goes on;
#   - patience is bounded on BOTH sides, because a stall reads the same from either: a review
#     that never starts and a 👀 that never lands both end with a verdict to nudge rather than with
#     another silent hold. "Wait it out" is only honest while something is actually running — and
#     the verdict that nothing is coming polls ONE more time before it says so, because a nudge
#     recommended over a round that landed while the state was being read re-requests a review
#     and clears the 👍 it was about to get;
#   - how late a due review is cannot be read off the head commit's date alone: that date is
#     commit metadata, and a force-push to an older commit or a first push of a morning's work
#     predates the push it arrived in. The push time is not an API field, so the clock starts at
#     the newest of that date and the PR's created_at — a floor that cannot be wrong, since
#     nothing about a PR is due before the PR exists (ludics-lite#72, where a PR opened seconds
#     earlier reported its review "due for 22m" and recommended a nudge);
#   - the reviewer can fail at INITIALIZATION and say so in a plain summary comment, which is its
#     newest word without being a round at all: "Codex Review: Something went wrong. Try again
#     later by commenting “@codex review”." with "Provided git ref <sha> does not exist" in a
#     code block under it — no review, no findings, and no machine tag to tell it apart from a
#     verdict. On lukstafi/ocannl-staging#677 (2026-09-09) it landed twice, naming two heads that
#     `git ls-remote` and the PR's own head.sha both served: the reviewer's clone was behind, not
#     the push. Counted as the reviewer's last word it spends the 👀, and with no review of the
#     head the state fell to `expected`, so three consecutive windows recommended waiting out a
#     grace for a round that had already ended, while `rounds` counted the failed attempt as a
#     round with findings. Hence the `failed` state below (ludics-lite#78);
#   - and a round is only worth its cost on a head CI can test: GitHub creates no pull_request
#     workflow run for a PR whose merge commit it cannot build (mergeable_state `dirty`), while
#     the reviewer reviews it regardless. On ludics-lite#39 (2026-09-04) a sibling landed on main
#     during round 6 and rounds 6 through 12 each got findings, a "the next move is yours" from
#     `status`, and NO CI, over eight pushes and 80 minutes, until `merge` failed on it — one of
#     those pushes landed a broken test suite CI would have caught (ludics-lite#44). So `status`
#     reads mergeable_state off the same PR read as the head and says CONFLICTS on every state,
#     and `watch` prints the base-drift read the moment a round lands, not only at merge time.
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
# "none". Both compare directions use the head SHA from one PR read and the base branch's tip
# from one read of the branch — NOT the PR's `.base.sha`, which is the base as of the last time
# GitHub could build the merge commit and so stands still on exactly the conflicted PR that is
# furthest behind (#39 read "0 behind" off it, 7 commits and 4 overlapping files behind) — and
# rename entries contribute both their current and previous filenames.
#
# REST vs GraphQL: everything on the polling and merge-gate path is REST, deliberately — GitHub's
# GraphQL endpoint 503s independently of REST, so a GraphQL-borne "no reaction yet" is a lie the
# merge gate would act on. `gh repo view` rides GraphQL, hence the local git-remote fallback.
# Thread resolution has no REST equivalent and stays on GraphQL, but reports transport failure as
# such instead of as "no such thread".
#
# Usage (<pr> is owner/name#number, or a number with the repo named by --repo/REPO=; see the repo
# note below — a bare number with no repo named anywhere is refused, never taken from the cwd):
#   pr-review.sh [--repo owner/name] poll <pr> [watermark]
#                                          # new comments/reviews above the watermark, each stamped
#                                          # with the commit it is about; ends with one machine
#                                          # line naming those items (kind:id:commit:author:state)
#                                          # and the next watermark. Inline threads at the SAME
#                                          # anchor (path, commit, author and every location field
#                                          # the row carries) render as ONE entry whose id field
#                                          # lists them all, anchor first — `id=900+901`, the token
#                                          # `reply` and `resolve` take — with every distinct body
#                                          # under the id of the thread carrying it
#   pr-review.sh watch <pr> [watermark]    # poll on a timer until a round lands ON THE HEAD being
#                                          # watched; 0 = act, 1 = quiet. Reviewer activity about
#                                          # another commit is printed on stderr for the record and
#                                          # the wait continues; every exit names what it ends on
#   pr-review.sh status <pr>               # merge gate + who owes what: approved / reviewing /
#                                          # stalled / failed / expected / idle / unknown — and
#                                          # the round count against the threshold (see `rounds`);
#                                          # says CONFLICTS when GitHub cannot build the merge
#                                          # commit (nothing tests the head merged with the base,
#                                          # and a push gets no run at all, until the base is in)
#   pr-review.sh rounds <pr>               # how many review rounds carried findings, read off the
#                                          # PR (heads the reviewer left comments on), against
#                                          # SHIP_PR_ROUND_THRESHOLD; exit 1 past it
#   pr-review.sh checks <pr> [--wait]      # the BUILD signal on the head commit: green / red /
#                                          # no verdict yet / absent
#   pr-review.sh merge <pr> [--override "<why this red is unrelated>"] [--wait]
#                           [--allow-no-verdict] [--require-green]
#                                          # checks, then merge; refuses on red without --override,
#                                          # on NO verdict without --allow-no-verdict, and — with
#                                          # --require-green (a close-out merge) — on ABSENT, on
#                                          # green-by-skips-only, on --auto, on a base with a
#                                          # merge queue, and on a deferred auto-merge (which it
#                                          # disables again); and WARNS
#                                          # loudly when the branch is far behind its base
#   pr-review.sh base [owner/name] [branch] [--wait[=seconds]]
#                                          # is the branch you are about to work off CI-green?
#                                          # --wait holds until the CURRENT tip has its verdict —
#                                          # the post-merge integration read (see cmd_base).
#                                          # A red names the failing JOB and how far back the red
#                                          # runs go, so the report is an owner's starting point
#                                          # and not just a workflow name (see base_red_detail);
#                                          # `.github/workflows/base-watch.yml` runs it daily on
#                                          # this repository's own main and files what it finds
#   pr-review.sh reply <pr> <comment-id>[+<comment-id>...] <body>
#                                          # the id token poll rendered. A FOLDED entry names
#                                          # several: the body goes to the first thread and each
#                                          # duplicate gets a one-line pointer to that reply, from
#                                          # this one invocation
#   pr-review.sh reply <pr> <comment-id>[+...] --anchor <comment-id>
#                                          # no body: the answer already stands in <comment-id>'s
#                                          # thread, and every id in the token is pointed at it.
#                                          # What a batch that failed part-way is retried with
#   pr-review.sh resolve <pr> <comment-id>[+<comment-id>...]
#                                          # the same token; every thread it names is closed
#   pr-review.sh comment <pr> <body>       # a plain PR comment, for what has no thread to reply in:
#                                          # a review SUMMARY's findings, or a '@codex review' nudge
#   pr-review.sh retry [--read] <gh args...>
#                                          # any other gh call (pr merge, api) with the same retry
#                                          # policy, instead of a hand-rolled loop
#   pr-review.sh retry [--read] run watch owner/name#<run-id>
#                                          # NOT forwarded to gh: executed as a QUIET await of that
#                                          # run — one verdict line instead of a stream of redraws,
#                                          # and a FAILED run is a verdict (exit 1), never retried
#                                          # as transport. The repo travels in the argument, like
#                                          # every other subcommand's (a bare id still works with
#                                          # -R owner/name or REPO=, and is REFUSED without one —
#                                          # never taken from the cwd). For a PR, prefer
#                                          # `checks <pr> --wait`.
#
# Exit codes: 0 the command did what it says (and any fact it printed came from a call that
#             answered); 1 the fact does not hold (the window stayed quiet, no such thread, the API
#             rejected the request, a build check or a checkless workflow run is RED, the merge was
#             refused); 2
#             usage/configuration error; 3 TRANSPORT failure — nothing was learned, so retry rather
#             than concluding anything, which for `watch` includes a verdict WITHHELD because the
#             final poll or the state re-read behind it did not answer. 1 and 3 are kept apart
#             everywhere. `checks`, `base` and
#             `merge` add 4: no verdict yet — the build has not finished, every finished job was
#             cancelled, or a workflow run for the head is queued, running, stopped without a
#             verdict, or still to be created. 4 is not a pass and not a failure, and it is kept
#             apart from 0 for the same reason 3 is: "nothing has failed" and "everything passed"
#             are different facts.
#             From `merge`, 4 means the merge was REFUSED for want of a verdict (see
#             --allow-no-verdict). `checks` and `merge` add 5: SUPERSEDED — the PR head
#             moved from the observed SHA. Re-run to judge the successor; no override bypasses 5.
#
# Env: REPO=owner/name, overridden by a repo spelled out in the <pr> argument or by --repo; those
#      three are the ONLY sources, for every subcommand including `retry run watch` (`base`, which
#      resolves a repo and a branch rather than a bare number, still reads the cwd's checkout),
#      REVIEWER=login-prefix (default: codex app), WATCH_INTERVAL=seconds between polls (default
#      90), WATCH_TIMEOUT=seconds to watch (900),
#      SHIP_PR_API_ATTEMPTS=tries per gh call (4), SHIP_PR_API_BACKOFF=first pause in seconds (5,
#      doubling to a 20s cap: ~35s of retrying before a call is declared dead),
#      SHIP_PR_REVIEW_GRACE=seconds a due-but-unstarted review is waited for before `watch` returns
#      saying so (1200), SHIP_PR_REVIEW_STALL=seconds a live 👀 may run before it gets the same
#      verdict (2×GRACE). Both are measured from the PR's own timestamps, not from when the watch
#      started, so they are reached ACROSS windows — a 900s window cannot outrun a 1200s grace.
#      SHIP_PR_ADVISORY_CHECKS=ERE of check, job and workflow names the build gate ignores
#      (default: the review app's check and the github-pages deploys) — a run whose red is
#      explained entirely by advisory JOBS is not a red build signal either, SHIP_PR_CHECKS_WAIT=seconds `--wait` holds
#      out for a build verdict (7200 — the runner queue alone ran ~2h deep on 2026-08-23),
#      SHIP_PR_CHECKS_INTERVAL=seconds between re-reads (60), SHIP_PR_CHECKS_HEARTBEAT=seconds
#      between the one-line "still waiting" progress notes a `--wait` prints (600),
#      SHIP_PR_BASE_ABSENT_GRACE=seconds a commit with no workflow run yet is allowed before its
#      absence is read as a fact (300; paths-ignore pushes never get one). `base --wait` applies
#      it to the tip — from the first READ of it, not from that round's last answer — and then
#      SETTLES for the older verdict the plain read settles for, once nothing is in flight on the
#      branch and no run for the tip exists to judge it. It settles at once, without the grace,
#      when every commit on the first-parent path from the judged one up to the tip changes only
#      paths within the workflow's own paths-ignore (ludics-lite#156). A `base --wait=N` in the
#      band (grace, grace+SHIP_PR_CHECKS_INTERVAL) is REFUSED: it is sized to outlive the grace
#      and cannot reach the round that settles it (ludics-lite#175). `checks`/`merge` apply the
#      grace to the head before calling a build signal ABSENT rather than not-created-yet
#      (ludics-lite#24), and settle a run-less head at once on the same paths-ignore recognition,
#      walking the PR's own commits from its merge base (ludics-lite#176),
#      SHIP_PR_STALE_BASE=commits behind the base at which `merge` warns loudly (20; `off`
#      silences the commit-count warning). A nonempty file overlap still warns at any count; no
#      base-drift warning blocks the merge. SHIP_PR_ROUND_THRESHOLD=review rounds with findings
#      after which only BLOCKING findings are fixed and the rest go to one follow-up issue (12;
#      ship-pr's "When the loop ends" — `rounds` and `status` report the count against it,
#      nothing here enforces it; `off` reports the count alone; anything else is refused).
#      SHIP_PR_ROUND_GAP=seconds between two of the reviewer's reviews on the same head beyond
#      which they are separate rounds (900; a round's reviews land within seconds).

set -uo pipefail

REPO="${REPO:-}"
REVIEWER="${REVIEWER:-chatgpt-codex-connector}"
ROUND_THRESHOLD="${SHIP_PR_ROUND_THRESHOLD:-12}"
# Reviews of one round land within seconds of each other; a re-requested round on the SAME head
# lands minutes or hours later. This gap is what tells them apart (seconds).
ROUND_GAP="${SHIP_PR_ROUND_GAP:-900}"
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

# A typo in the threshold ("12x") must not read as `off`: that would turn a bounded triage into
# an unbounded one silently, so anything but a number or the literal `off` is a usage error.
case "$ROUND_THRESHOLD" in
off | 0 | [1-9]*) case "$ROUND_THRESHOLD" in *[!0-9]*) [ "$ROUND_THRESHOLD" = off ] ||
  die "SHIP_PR_ROUND_THRESHOLD must be a number of rounds or 'off', got '$ROUND_THRESHOLD'" ;; esac ;;
*) die "SHIP_PR_ROUND_THRESHOLD must be a number of rounds or 'off', got '$ROUND_THRESHOLD'" ;;
esac
# The gap reaches jq as a number (--argjson), where a quoted "900" or a `true` would not be
# rejected but compared cross-type — every same-head re-request collapsing, or every review
# becoming its own round — so only a plain nonnegative integer passes.
case "$ROUND_GAP" in
0 | [1-9]*) case "$ROUND_GAP" in *[!0-9]*)
  die "SHIP_PR_ROUND_GAP must be a nonnegative number of seconds, got '$ROUND_GAP'" ;; esac ;;
*) die "SHIP_PR_ROUND_GAP must be a nonnegative number of seconds, got '$ROUND_GAP'" ;;
esac

warn() { printf 'pr-review.sh: %s\n' "$*" >&2; }

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
# gh_retry's per-attempt stderr capture, tracked here so the EXIT trap removes one a call died
# holding. It is only ever the CURRENT shell's: every feed read happens inside a command
# substitution, and that subshell does not run this trap — which is the same fact gh_err_line
# relies on, since a trap that ran there would blank GH_ERR_FILE before the parent could read it.
# A capture a killed subshell left behind is collected by tmp_sweep_stale instead, which is what
# the pid in its name is for.
GH_TMP_FILE=""
# The round snapshot's files live in the same directory as GH_ERR_FILE, for the same subshell
# reason; see "the round snapshot" below for what is in them. They share ONE directory per process, created on the first
# arm and removed by this trap, rather than a spray of `$$`-keyed files: a watch killed with
# SIGKILL runs no trap, and one leftover directory a later watch can recognize and sweep beats a
# handful of loose files nothing ever collects. The pid is in the directory's NAME, which is what
# makes that sweep possible — see `snapshot_sweep_stale`. SNAP_DIR and SNAP are set in the shell
# that arms, and a command substitution's subshell inherits both, so the two sides address the
# same files.
SNAP_ROOT="${TMPDIR:-/tmp}"
SNAP_ROOT="${SNAP_ROOT%/}"
SNAP_DIR=""
SNAP=""
# The cleanup is a NAMED function rather than a body written into the trap, because two scripts
# source this one and then install an EXIT trap of their own: a trap is REPLACED, never chained,
# so each of them used to hand-copy what this trap does, and nothing checked the copies still
# agreed (ludics-lite#195). The snapshot directory above is the proof: added to this trap alone,
# it leaked from every fixture-suite run into the real TMPDIR until the copy in
# test-pr-review-lib.sh was updated by hand, with every suite and CI green throughout. A sourcing
# script calls this function from its own trap instead, so there is no copy to drift; the suites'
# preamble refuses to run if its trap no longer reaches whatever this one installs.
pr_review_cleanup() {
  rm -f "$GH_ERR_FILE"
  [ -z "$GH_TMP_FILE" ] || rm -f "$GH_TMP_FILE"
  [ -z "$SNAP_DIR" ] || rm -rf "$SNAP_DIR"
}
trap pr_review_cleanup EXIT

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
  # Keyed by the owning pid, like every other temporary path this script makes. The template was
  # `pr-review.XXXXXX`, and mktemp's suffix alone names no owner: a capture a killed call left
  # behind could not be told from a live sibling's by any later run, so nothing could ever collect
  # it, and one sat in this box's TMPDIR from 09-14 until ludics-lite#219 was opened over it.
  tmp=$(mktemp "${TMPDIR:-/tmp}/pr-review-gh.$$.XXXXXX" 2>/dev/null) || tmp=/dev/null
  if [ "$tmp" = /dev/null ]; then GH_TMP_FILE=""; else GH_TMP_FILE="$tmp"; fi
  GH_ERR=""
  while :; do
    out=$(gh "$@" 2>"$tmp")
    rc=$?
    [ "$tmp" = /dev/null ] || GH_ERR=$(cat "$tmp" 2>/dev/null)
    if [ "$rc" -eq 0 ]; then
      [ "$tmp" = /dev/null ] || { rm -f "$tmp"; GH_TMP_FILE=""; }
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
      [ "$tmp" = /dev/null ] || { rm -f "$tmp"; GH_TMP_FILE=""; }
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
# A PR is addressed by a repository and a number, and the number alone names one PR in every
# repository there is. So the repository is either SPELLED OUT in the invocation — an
# owner/name#<n> argument, --repo, REPO= — or the call is refused. Resolution happens after the PR
# argument is parsed, because that argument may carry the repo itself.
#
# Two other sources stood here and both are gone (ludics-lite#92). The cwd was trusted outright,
# and cached: a bare `reply 7` typed from a shell sitting in another project's worktree posted into
# whatever PR 7 is over there. The per-PR cache remembered a repo by NUMBER, across checkouts and
# across sessions, so a `reply 7` meant for repo B resolved to the repo A that some earlier call
# had named for 7.
#
# Both were verified against `repos/<repo>/pulls/<n>` before use, or could have been, and this is
# the half worth writing down because verification is the fix that looks right: that read answers
# "this repository has a seventh PR", not "this is the PR you meant". Every active repository has a
# PR 7. So on exactly the invocations these guesses fail on — a worktree of another project, a
# stale entry from yesterday's PR — the check passes and the write lands on a stranger's review
# thread, now with a verification behind it. A claim that cannot fail, standing in for a
# safeguard, is worse than no safeguard. Nor can any other read stand in: what both sources are
# guesses about is INTENT, and the API has nothing to say about that.
#
# So there is no inference left, as ludics-lite#74 (PR #79) left none for `retry run watch` after a
# background shell in a sibling worktree turned a wrong-target read into a failed-run verdict. The
# cost is one `owner/name#<n>` per call, which is what this skill's instructions have always told
# callers to write and what every documented invocation already spells out. What it buys is an
# invariant with no exception to remember: no command here addresses a repository that this
# invocation did not name.
#
# `repo_from_cwd` survives for `base` alone, which resolves a repo and a BRANCH — a name the API
# can actually be asked about — rather than a bare number every repository answers to.
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

resolve_repo() {
  [ -z "$REPO" ] || return 0
  die "PR $1 was given with no repository, and a PR number alone names one PR in every" \
    "repository there is. Pass it as owner/name#$1 (or --repo owner/name, or REPO=owner/name)." \
    "Nothing was read or written anywhere. It is NOT taken from the working directory and there" \
    "is no per-number memory of an earlier call: either would resolve the wrong checkout, or" \
    "yesterday's PR $1, to a real PR of that number rather than to an error — a write onto a" \
    "stranger's review thread (ludics-lite#92). A BACKGROUND invocation is where that bit" \
    "hardest, since background shells do not start in the checkout, and the skill's documented" \
    "\`watch\` call is a backgrounded one."
}


# Accept both a bare number and owner/name#number (the form PR URLs and cards use); anything else
# dies loudly. Without this, a malformed <pr> lands in the API path, api_list eats the error, and
# every feed reads back empty — the PR looks eternally quiet, which is exactly the false reading
# this script exists to prevent.
#
# Two things are addressed as owner/name#number here: a PR, and the workflow run `retry run watch`
# awaits (ludics-lite#74). They share this parse rather than each hand-rolling it, so that the one
# accepted spelling is the one both commands accept. It sets REF_REPO — EMPTY when the argument did
# not carry one, so a caller can tell "no repo named" from "this repo" — and REF_NUM, and returns 1
# on anything that is not a number, leaving the message to the caller: what the number is called
# ("PR", "run id") is the only part of the refusal that differs.
#
# The WHOLE argument is validated, not the tail after the last `#`. Splitting on the last
# delimiter and checking only what follows it accepts an argument carrying unparsed input in
# front of a valid one: `owner/repo#111#222` would name run 222, and `junk#123` run 123, each
# silently — a verdict about a target the caller did not name, which is the failure this parse
# exists to prevent rather than a shape to be lenient about. So: exactly one `#`, exactly one `/`
# before it with both halves nonempty, and nothing outside the characters GitHub allows in an
# owner or a repository name.
parse_ref() {
  local repo num
  REF_REPO=""
  REF_NUM=""
  case "$1" in
  *"#"*)
    repo="${1%%#*}"
    num="${1#*#}"
    case "$num" in *"#"*) return 1 ;; esac
    case "$repo" in
    */*/* | /* | */) return 1 ;;
    */*) ;;
    *) return 1 ;;
    esac
    case "$repo" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
    ;;
  *)
    repo=""
    num="$1"
    ;;
  esac
  case "$num" in
  '' | *[!0-9]*) return 1 ;;
  esac
  REF_REPO="$repo"
  REF_NUM="$num"
  return 0
}

# Sets PR_NUM, and REPO from the argument or the fallbacks above.
pr_arg() {
  parse_ref "$1" || die "PR must be a number or owner/name#number, got '$1'"
  [ -z "$REF_REPO" ] || REPO="$REF_REPO"
  PR_NUM="$REF_NUM"
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

# --- the round snapshot -------------------------------------------------------------------------
# A watch round used to read the same endpoints twice. `cmd_poll` reads the inline, comments and
# reviews feeds, `watch_round` then reads the PR for the head its items are classified against, and
# `status_state` — called on the same round, a second later — read the comments, the reviews and the
# PR all over again for its own question. Of the eight or so calls a round made, four were the
# second copy of a read already in hand (ludics-lite#95).
#
# The snapshot is that first read, published for the state to take. What it buys is not only the
# calls: two reads a second apart are also what made "the item was classified against a head that
# has since moved" expressible at all, because each answer was about a different instant. With ONE
# observation per round, the round's classification and the state reported beside it are about the
# same instant by construction — the watch's claims about a head are true of the feeds they were
# made from, instead of nearly true of a PR that has moved on since.
#
# The ordering INSIDE a round is unchanged, and it is the whole point: the feeds first, the head
# after (review of ludics-lite#47). Every item in the snapshot's feeds is then about a head no newer
# than the snapshot's head, so "the reviewer's review names the head" means the CURRENT head was
# reviewed; read the other way round, a push landing between the two would match the previous head's
# review to the previous head and report `idle` while the new head sits unreviewed. And because the
# state now TAKES the head rather than reading it again, a push landing after the round can no
# longer re-anchor the state to a head the round never classified against — which is how a round
# just delivered about the head being watched came to be reported beside a state about its
# successor (the P2 rebutted on exactly this ground in the review of ludics-lite#84).
#
# What is NOT in the snapshot: the reactions feed, which `cmd_poll` does not read and which is the
# only place a 👍 lives. Every state read still asks it live, so an approval landing beside a round
# is still reported as the approval it is rather than answered with the nudge that would clear it.
#
# It lives in files rather than variables for the reason GH_ERR_FILE does: `cmd_poll` runs inside a
# command substitution, and an assignment made there dies with the subshell.
#
# Three rules keep a snapshot from ever being read as something it is not:
#   - it is ARMED only inside a watch round (`snapshot_arm`). `poll` and `status` invoked on their
#     own read for themselves, exactly as before, and nothing is written for them;
#   - each part's `.pr` marker names the PR and is written LAST, so a half-written or foreign
#     snapshot is simply absent rather than half-believed; and `snapshot_arm` removes the round
#     before's before any of this round's is written, so a stale answer can never be served as this
#     round's observation;
#   - only a SUCCESSFUL read is published, and a failed round drops the snapshot outright. A state
#     read with no snapshot reads for itself and reports what that read says, so the collapse
#     api_list exists to refuse — a failed read reading as an empty feed — cannot come back in
#     through here.
SNAPSHOT_ARMED=0

# The files of the round in hand, if there are any. Guarded on SNAP rather than assuming it: the
# snapshot directory is made on the first arm, and before that `rm -f "$SNAP".*` would be
# `rm -f .*` in whatever directory the caller happens to be standing in.
snapshot_clear() {
  [ -n "$SNAP" ] || return 0
  rm -f "$SNAP".*
}

# The one directory this process's snapshots live in, made on demand. mktemp picks the suffix, so
# two watches started in the same second cannot collide even if a pid were somehow reused.
snapshot_dir_ensure() {
  [ -z "$SNAP_DIR" ] || return 0
  SNAP_DIR=$(mktemp -d "$SNAP_ROOT/pr-review-snap.$$.XXXXXX" 2>/dev/null) || { SNAP_DIR=""; return 1; }
  # Physically resolved: $SNAP_ROOT is $TMPDIR as the environment spells it, which on macOS is
  # under /var, a symlink to /private/var. Everything else this script computes is `pwd -P`-ed,
  # so an unresolved snapshot path is a second spelling of one directory in the logs and in any
  # comparison a fixture makes against it (ludics-lite#208). A `cd` into a directory mktemp just
  # created fails only if the filesystem went away underneath it, and then there is nothing to
  # remove anyway.
  SNAP_DIR=$(CDPATH= cd "$SNAP_DIR" && pwd -P) || { SNAP_DIR=""; return 1; }
  SNAP="$SNAP_DIR/round"
}

# A process killed with SIGKILL never reaches its EXIT trap, so whatever it had in TMPDIR outlives
# it. The snapshot directory was the first of those to be noticed and for a while the only one
# collected — and the families beside it accumulated in silence, which is what ludics-lite#219 was
# opened over: this box's real TMPDIR held seven of them, dated 09-10 to 09-14, from four
# different families.
#
# THE FAMILIES, every temporary path this script and its fixture suites put in TMPDIR:
#
#   pr-review-snap.<pid>.XXXXXX/  the round snapshot directory (and, from its first cut, loose
#                                 `pr-review-snap.<pid>.<kind>.<pr>` files beside it)
#   pr-review-err.<pid>           GH_ERR_FILE, the last attempt's error for gh_err_line
#   pr-review-gh.<pid>.XXXXXX     gh_retry's per-attempt stderr capture
#   pr-review-probe.<pid>.err     test-pr-review-lib.sh's constants probe, whose own two removals
#                                 cover its documented paths but not a suite killed mid-probe
#   pr-review-test.<pid>.<label>.XXXXXX/  a fixture suite's scratch directory (test_tmpdir)
#
# WHAT MAKES THIS A SWEEP AND NOT A DELETE. The owning pid is in every one of those names, and
# that is the whole safeguard: a dead owner's leftovers are told from a CONCURRENT run's live ones
# by asking the kernel, never by age. Several watches share a TMPDIR routinely, one per PR in
# flight, and ten fixture suites share one on a wave day; sweeping a live one would pull the feeds
# out from under a round, or the fixtures out from under a suite. Nothing here is aged out, and a
# name whose pid field is not a number — which is what the two unkeyed templates used to produce —
# names no owner, so it is left exactly where it is rather than guessed about. That is why the fix
# for those two was to put the pid IN the name rather than to widen this test.
#
# Only paths this user owns are considered, since /tmp is shared where TMPDIR is unset. A pid
# reused by an unrelated live process leaves its path behind for the next sweep to find; that is
# the safe way round.
tmp_sweep_stale() {
  local path pid family
  [ -d "$SNAP_ROOT" ] || return 0
  for family in snap err gh probe test; do
    for path in "$SNAP_ROOT/pr-review-$family".*; do
      # The unmatched glob itself when a family has nothing in it.
      [ -e "$path" ] || continue
      [ -O "$path" ] || continue
      pid=${path##*/pr-review-$family.}
      pid=${pid%%.*}
      case "$pid" in '' | *[!0-9]*) continue ;; esac
      if kill -0 "$pid" 2>/dev/null; then continue; fi
      rm -rf "$path"
    done
  done
}

# A new round: nothing observed before it may be read as part of it. A round whose directory could
# not be made stays DISARMED — every reader is gated on SNAPSHOT_ARMED, so the watch falls back to
# the read-for-yourself behaviour the snapshot replaced rather than writing to a bare `.feeds.pr`.
snapshot_arm() {
  snapshot_clear
  if snapshot_dir_ensure; then
    SNAPSHOT_ARMED=1
  else
    SNAPSHOT_ARMED=0
    warn "could not create a snapshot directory under $SNAP_ROOT; this round's state will read the feeds again"
  fi
}

# The round ended without an observation worth sharing (a feed that did not answer). Callers of
# status_state then read for themselves.
snapshot_drop() {
  snapshot_clear
}

# The watch is over. Disarming is not tidiness: this script's functions outlive a command when it is
# sourced (every fixture suite sources it), and a `status` asked afterwards must read the PR as it
# is NOW, not as the last round saw it. Armed state that survived its watch turned a standalone
# status into a replay of a window that had already ended.
snapshot_off() {
  SNAPSHOT_ARMED=0
  snapshot_clear
}

# Is <kind> (feeds|head) of the current round in hand, and about <pr>?
snapshot_has() { # <kind> <pr>
  [ "$SNAPSHOT_ARMED" = 1 ] || return 1
  [ -f "$SNAP.$1.pr" ] || return 1
  [ "$(cat "$SNAP.$1.pr" 2>/dev/null)" = "$2" ]
}

# The feeds cmd_poll read this round. The marker last, so a write that fails partway leaves no
# snapshot at all rather than one missing a feed.
snapshot_put_feeds() { # <pr> <issue comments json> <reviews json>
  [ "$SNAPSHOT_ARMED" = 1 ] || return 0
  rm -f "$SNAP.feeds.pr"
  printf '%s\n' "$2" >"$SNAP.feeds.comments" 2>/dev/null &&
    printf '%s\n' "$3" >"$SNAP.feeds.reviews" 2>/dev/null &&
    printf '%s\n' "$1" >"$SNAP.feeds.pr" 2>/dev/null
  return 0
}

# The head read watch_round made AFTER those feeds, with the fields pr_head_read sets. head_err is
# a whole error line and may contain anything, so each field gets its own file rather than sharing
# a delimiter with it.
snapshot_put_head() { # <pr>; head_sha, mstate, pr_created and head_err in the caller's scope
  [ "$SNAPSHOT_ARMED" = 1 ] || return 0
  rm -f "$SNAP.head.pr"
  printf '%s' "$head_sha" >"$SNAP.head.sha" 2>/dev/null &&
    printf '%s' "$mstate" >"$SNAP.head.mstate" 2>/dev/null &&
    printf '%s' "$pr_created" >"$SNAP.head.created" 2>/dev/null &&
    printf '%s' "$head_err" >"$SNAP.head.err" 2>/dev/null &&
    printf '%s\n' "$1" >"$SNAP.head.pr" 2>/dev/null
  return 0
}

# The comments and the reviews for a state read: the round's own observation when there is one —
# the SAME bytes cmd_poll classified its items from, so the state and the round cannot disagree
# about what the reviewer has said — and a read of its own otherwise. Failure is api_list's: return
# nonzero having printed nothing, so a caller can still tell a failed read from an empty feed.
state_comments() { # <pr>
  if snapshot_has feeds "$1"; then
    cat "$SNAP.feeds.comments"
    return $?
  fi
  api_list "issues/$1/comments?per_page=100"
}

state_reviews() { # <pr>
  if snapshot_has feeds "$1"; then
    cat "$SNAP.feeds.reviews"
    return $?
  fi
  api_list "pulls/$1/reviews?per_page=100"
}

# The head for a state read. The snapshot's head was read after the snapshot's feeds, which is the
# ordering status_state's own read exists to keep; taking it here keeps that ordering AND stops a
# push that landed since from re-anchoring the state to a head this round never classified against.
# Sets the same four variables pr_head_read sets, in the caller's scope.
state_head_read() { # <pr>
  if snapshot_has head "$1"; then
    head_sha=$(cat "$SNAP.head.sha")
    mstate=$(cat "$SNAP.head.mstate")
    pr_created=$(cat "$SNAP.head.created")
    head_err=$(cat "$SNAP.head.err")
    [ -n "$mstate" ] || mstate="-"
    return 0
  fi
  pr_head_read "$1"
}

# A review's own comments endpoint, read at most once per round for a given review. Two callers ask
# for it on the round that matters: cmd_poll re-reads every NEW review's comments (the flat feed
# lags a fresh review), and substantive_reviews reads the empty-bodied COMMENTED ones to tell an
# envelope from findings — on the round a review lands, that is one read made twice. Only a
# SUCCESSFUL read is cached, so a read that did not answer is never served as a review with no
# findings; the cache is per round, cleared with the rest of the snapshot.
review_comments() { # <pr> <review id>
  local out
  case "$2" in '' | *[!0-9]*) api_list "pulls/$1/reviews/$2/comments?per_page=100" ; return $? ;; esac
  if [ "$SNAPSHOT_ARMED" = 1 ] && [ -f "$SNAP.review.$2" ]; then
    cat "$SNAP.review.$2"
    return $?
  fi
  out=$(api_list "pulls/$1/reviews/$2/comments?per_page=100") || return $?
  [ "$SNAPSHOT_ARMED" != 1 ] || printf '%s\n' "$out" >"$SNAP.review.$2" 2>/dev/null || true
  printf '%s\n' "$out"
}

# The commit each kind of item is ABOUT, as one jq prelude shared by the rendering and the index
# below, so the two can never disagree about an item. Spliced into a jq program, which is why it
# carries no apostrophe.
#
# An inline comment is bound by `original_commit_id`, NOT `commit_id`: GitHub migrates the latter
# forward as the head advances for a comment whose lines still exist, so a previous round finding
# would stamp itself with the CURRENT head and pass any head test put to it. original_commit_id is
# the commit the reviewer wrote it against, and it does not move. Nothing is lost if that ever
# proves too strict: every inline finding belongs to a review, poll re-reads each NEW review own
# comments endpoint (above), and the review row carries the head it was submitted against — so a
# round of the head is caught by its review even if none of its comments were.
#
# A comment has no such field; its only head association is the "**Reviewed commit:** `<sha>`"
# stamp the connector writes on the comments it delivers a round or a verdict in. The LAST match
# is the one taken: the connector writes that stamp as a FOOTER, and a findings body can quote
# another commit above it — a review OF this parsing logic does exactly that — where taking the
# first would stamp the round with a commit it merely mentions and discard it as an old head.
# `[capture(...; "g")] | last` and never `capture(...) // ""`, because a capture that does not
# match produces NO output rather than null, and a zero-output sub-expression inside a string
# interpolation takes the whole string with it: the comment would not be rendered at all, which
# on the initialization failure (the one summary that never carries the stamp) is a round
# silently disappearing from the watch that was waiting for it.
#
# `fold_inline` is the last of these: the reviewer posts one finding as several inline threads
# often enough to matter (round 11 of ludics-lite#66 posted nine threads for four findings,
# ludics-lite#76), and each duplicate then costs its own composed reply and its own resolve. The
# fold groups such threads into one entry whose `thread_ids` lists every one of them, anchor first,
# and the rendering and the index both address it by that list (`id=900+901`) — the token `reply`
# and `resolve` take, so what poll printed is what the caller pastes back.
#
# What folds is a PLACE, not a text. Two threads fold when they are the same anchor — same path,
# same commit, same author, and identical in every location field the row carries — and the BODY
# is deliberately not part of that, which is the whole difference between a fold that fires and
# one that never does. Measured against the round the issue was filed on (#66 head 252e336):
# grouping by body finds ZERO groups among that PR's 51 findings, while grouping by the anchor
# finds exactly four, covering nine threads — the issue's own arithmetic — and not one of them
# mixes unrelated findings. The reviewer duplicates a finding by RE-WRITING it (the three threads
# at :447 carry bodies of 546, 575 and 570 characters saying the same thing), so a key that
# demanded equal text would have been a feature that could not fire.
#
# Nothing is lost by that, because the entry prints every DISTINCT body, each under the id of the
# thread carrying it (`body_block`), and only an exact repeat is printed once. So the caller sees
# every word the reviewer wrote, under one id token, and answers once.
#
# The key is a DENY-LIST — the whole row minus the eleven fields that must differ between two
# posts of one finding (the ids, the urls, the timestamps, the reactions, the links, the review
# id) and the body. Every other field is identifying by default, present or future, so a field
# GitHub adds later can only make the fold fire LESS, never more: unfolded is loud (one extra
# reply) and over-folded is silent (a finding answered by a reply it never got, its id already
# behind the watermark). That is also why the location fields are not enumerated: `line`,
# `original_line`, `side`, `start_line`, `start_side`, `original_start_line`, `position`,
# `original_position` and `subject_type` are all in the key without being named, and so is the
# next one. Two of these were found the expensive way, one per round: the per-review comments
# endpoint (the one poll re-reads when the flat feed lags a new review) serves rows with NO `line`
# and no `original_line` at all, carrying `position`/`original_position` instead — every such row
# renders `:@<position>`, so an enumerating key collapsed two findings in one file (#86 round 1)
# — and `side`/`start_line` do the same for a LEFT-vs-RIGHT or multi-line anchor (#86 round 2).
# The RENDERING names them even so (`item_side`, `item_was` below, #113): the key and the header
# have different jobs, and a key that must separate on a field nobody has heard of leaves the
# header owing the reader every separation it CAN explain.
#
# `pull_request_review_id` is in the deny-list for a measured reason, not a tidy one: the reviewer
# posts a separate COMMENTED review per inline comment (46 comments over 36 reviews on #39), so
# keeping it would have kept every real duplicate apart.
#
# The commit stamp is in the key for a second reason: it is what `watch` classifies an item by, and
# folding across two stamps would force one head verdict onto two different associations.
# Grouping is by the key's `tojson` — a STRING — because jq's `index` on an array argument searches
# for a sub-SEQUENCE rather than an element, so a key kept as an array would match its neighbours
# prefixes. Order is the feed's: `group_by` sorts by key, and `pos` (each group's first member's
# index) puts the entries back in the order they arrived, so folding does not reshuffle a round.
POLL_ITEM_DEFS='
  def short: if (. // "") == "" then "-" else .[0:7] end;
  def item_stamp($re): ([(.body // "") | capture($re; "g").s] | last) | short;
  def inline_commit: (.original_commit_id // .commit_id) | short;
  def review_commit: .commit_id | short;
  def item_path: .path // "?";
  # The line half of an anchor: the range when the row carries a start, the line alone otherwise.
  # A start equal to the end still renders as a range — GitHub refuses `start_line == line`, so
  # the shape does not arise from the API, and collapsing it to a bare line would print a row the
  # key separates on identically to one with no start at all.
  def anchor($s; $l): if $s != null then "\($s)-\($l)" else "\($l)" end;
  # A row from the per-review comments endpoint (what poll reads while the flat feed lags a new
  # review) carries no `line` and no `original_line` at all, only `position`/`original_position`.
  # Rendering that as `0` printed an unknown location in the shape of a known one, and two rows
  # at different places in one file read as the same place — which is what hid the collapse in
  # round 1 of #86 from the eye. An unknown line says so (`?`), and a position says which field it is
  # (`@12`), so nothing downstream reads a location that was never served as a line number.
  def item_line: (.line // .original_line) as $l
    | if $l != null then anchor((.start_line // .original_start_line); $l)
      else ((.position // .original_position) as $p
            | if $p != null then "@\($p)" else "?" end)
      end;
  # The rest of the anchor, in the `k=v` grammar the rest of the header already speaks
  # (ludics-lite#113). The key above separates on `side`, `start_line`, `start_side` and
  # `original_start_line` — #86 round 2 put them there because a LEFT-vs-RIGHT or multi-line
  # anchor was folding two distinct findings into one — while the header named none of them, so a
  # deletion commented on the left and an addition on the right at line 40 of one file printed two
  # rows byte-identical apart from the id and correctly did not fold. That reads as the reviewer
  # posting one finding twice and the fold failing to catch it, which is the mirror of the `:0`
  # defect of #105 and costs the reader the same round: either the anchors are re-derived from the
  # API by hand, or the fold stops being trusted, which is what the fold note exists to prevent.
  #
  # Only what is NOT the default prints. RIGHT is the side of every row that is not about a
  # deleted line, and a `side=RIGHT` on every entry would be noise bought at the price of the one
  # row where the side matters; `start_side` prints when it differs from the side of the end,
  # the only case where naming one side reads a range wrong. A header cannot be a
  # total discriminator for a deny-list key — the next field GitHub invents is in the key and not
  # on this line, which is the direction the key is deliberately wrong in — so what this owes the
  # reader is every anchor field the row actually carries, not a proof of distinctness.
  def item_side:
    (if (.side // "") == "LEFT" then " side=LEFT" else "" end)
    + (if .start_side != null and .start_side != (.side // "RIGHT") then " start_side=\(.start_side)"
       else "" end);
  # Where the finding was WRITTEN, when that is not where it sits now. GitHub migrates `line` and
  # `start_line` forward as the branch advances while the `original_*` pair stays put, and both
  # pairs are in the key, so two findings written at different places can sit at one place today
  # and print one header between them. The same rule as the side fields: it prints only when the
  # row carries an original that differs from what was rendered.
  #
  # In whichever unit the row is anchored by. A row from the per-review endpoint has no line at
  # all and migrates in `position`/`original_position` instead, both of them in the key, so it
  # has the same defect one field over and gets the same token (review of #272, round 1). The two
  # units are never mixed on one line: a position is a second name for a place a row with lines
  # has already named, and the API computes it from the same diff, so a pair of rows agreeing on
  # both line fields cannot disagree on it.
  def item_was: (.line // .original_line) as $l
    | if $l != null then
        (.start_line // .original_start_line) as $s
        | if (.original_line != null and .original_line != $l)
            or (.original_start_line != null and .original_start_line != $s) then
            " was=\(anchor(.original_start_line; (.original_line // $l)))"
          else "" end
      else
        (.position // .original_position) as $p
        | if $p != null and .original_position != null and .original_position != $p then
            " was=@\(.original_position)"
          else "" end
      end;
  def fold_key: del(.id, .node_id, .url, .html_url, .pull_request_url, .pull_request_review_id,
                    .created_at, .updated_at, .reactions, ._links, .body);
  def fold_inline:
    [to_entries[] | {i: .key, k: (.value | fold_key | tojson), v: .value}]
    | group_by(.k)
    | map(sort_by(.i)
          | {pos: .[0].i, ids: [.[].v.id], v: .[0].v,
             bodies: (reduce .[] as $x ([];
                        if (map(.body) | index($x.v.body // "")) then .
                        else . + [{id: $x.v.id, body: ($x.v.body // "")}] end))})
    | sort_by(.pos)
    | map(.v + {thread_ids: .ids, thread_bodies: .bodies});
  def thread_ids: .thread_ids // [.id];
  def thread_list: thread_ids | map(tostring) | join("+");
  def thread_bodies_of: .thread_bodies // [{id: .id, body: (.body // "")}];
  def body_block: thread_bodies_of as $b
    | if ($b | length) <= 1 then ($b[0].body)
      else ([$b[] | "[thread \(.id)]\n\(.body)"] | join("\n")) end;
  def dupe_note: (thread_ids | length) as $n | (thread_bodies_of | length) as $k
    | if $n <= 1 then ""
      elif $k <= 1 then " (\($n) identical threads, one reply answers all)"
      else " (\($n) threads at one location, \($k) findings as written; one reply answers all)"
      end;
'

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
  # The one read of these feeds the round makes. status_state takes its comments and reviews from
  # here instead of reading them again a second later (see "the round snapshot"), so the state a
  # round is reported beside is computed from the very bytes the round was classified from. The
  # UNFILTERED feeds: poll's question is "what is new since the watermark" and the state's is "what
  # has the reviewer ever said", and the second cannot be answered from the first's leftovers.
  # Nothing is published unless all three answered — the return above is what a failed read owes
  # the caller, and a snapshot of two feeds would hand the state an empty third.
  snapshot_put_feeds "$pr" "$issue" "$reviews"

  # A new review's inline comments can lag the flat listing read above (see the header), so every
  # review this round is about to report gets its own comments endpoint read too, merged by
  # comment id — the flat feed's copy wins when both exist, since only it carries current line
  # numbers. A failed per-review read fails the ROUND (unknown, watermark unwritten): the
  # alternative is printing the review while silently dropping its findings.
  # The list of reviews to re-read is itself a read that can fail. Unguarded it failed EMPTY —
  # indistinguishable from "no new reviews this round" — and the round would then render every
  # review without its own comments and still advance the watermark past them (#89).
  local rid extra='[]' more new_review_ids
  new_review_ids=$(jq -r --arg rev "$REVIEWER" --argjson since "$m_review" '
    map(select((.user.login // "") | startswith($rev)) | select(.id > $since))
    | .[].id' <<<"$reviews" 2>/dev/null) || {
    warn "could not read which reviews on PR $pr are new — this round is UNKNOWN, not quiet"
    return 3
  }
  # shellcheck disable=SC2086 # one id per word, and the point is to split them
  for rid in $new_review_ids; do
    more=$(review_comments "$pr" "$rid") || {
      warn "API error reading review $rid's comments on PR $pr after $API_ATTEMPTS attempts" \
        "($(gh_err_line)) — this round is UNKNOWN, not quiet"
      return 3
    }
    extra=$(printf '%s\n%s\n' "$extra" "$more" | jq -s '.[0] + .[1]') || return 4
  done
  inline=$(printf '%s\n%s\n' "$inline" "$extra" | jq -s '
    (.[0] | map(.id)) as $have
    | .[0] + (.[1] | map(select(.id as $i | ($have | index($i)) | not)))') || return 4

  # Every rendered item carries the commit it is ABOUT, short, as `commit=<sha7>` — the field
  # `watch` reads to tell the round it is waiting for from an older one scrolling past
  # (ludics-lite#72). `-` where the feed carries no association at all, and nothing downstream
  # may read that as "another commit": a missing stamp is not evidence.
  #
  # For an inline comment that is `original_commit_id`, NOT `commit_id`: GitHub migrates
  # `commit_id` forward as the head advances for a comment whose lines still exist, so a previous
  # round's finding would stamp itself with the CURRENT head and pass any head test put to it.
  # `original_commit_id` is the commit the comment was written against — the reviewer's own view
  # of the code — and it does not move. Nothing is lost if that ever proves too strict: every
  # inline finding belongs to a review, poll re-reads each NEW review's own comments endpoint
  # (see above), and the review row itself carries the head it was submitted against — so a round
  # of the head is caught by its review even if none of its comments were.
  # Each feed's new items are filtered ONCE, into an array that is then both rendered and indexed
  # (the `items:` line below), so the index cannot drift from what was printed — and so the fold
  # of duplicate threads (`fold_inline`, ludics-lite#76) has ONE place to sit: it happens here,
  # once, and the rendering and the index below read its output. A folded entry is still one
  # finding for `watch` (it counts entries, not threads) and the watermark is untouched — that is
  # computed from the UNFILTERED feed below, so every duplicate's id is still advanced past.
  # `rounds` reads its own feeds and never these, so the round count is untouched too.
  local new_inline new_issue new_reviews
  new_inline=$(jq --arg rev "$REVIEWER" --argjson since "$m_inline" "$POLL_ITEM_DEFS"'
    map(select((.user.login // "") | startswith($rev)) | select(.id > $since)) | fold_inline' \
    <<<"$inline") || return 4
  new_issue=$(jq --arg rev "$REVIEWER" --argjson since "$m_issue" \
    'map(select((.user.login // "") | startswith($rev)) | select(.id > $since)
         | select((.body // "") | test("codex-pull-request-review-summary") | not))' <<<"$issue") ||
    return 4
  new_reviews=$(jq --arg rev "$REVIEWER" --argjson since "$m_review" \
    'map(select((.user.login // "") | startswith($rev)) | select(.id > $since))' <<<"$reviews") ||
    return 4

  jq -r "$POLL_ITEM_DEFS"'
    if length == 0 then "(no new inline comments)"
    else .[] | "--- inline id=\(thread_list) \(item_path):\(item_line)\(item_side)\(item_was) commit=\(inline_commit) by \(.user.login)\(dupe_note)\n\(body_block)"
    end' <<<"$new_inline" || return 4

  # The connector's "Review Summary" placeholder is machine-tagged with an HTML comment and posted
  # the moment a round STARTS ("🔄 Running"); it carries no findings, but its id is above the
  # watermark, so rendering it made `watch` return 0 with nothing to act on — one wasted wake and
  # re-arm per PR (observed landing self-improve#10, 2026-08-29, and again on #13 the day the fix
  # landed). It is dropped from the RENDERING only: the watermark below reads the unfiltered feed,
  # so its id is advanced past and never replayed. Nothing is lost by hiding it — the comment is
  # thereafter EDITED in place (same id, invisible to a watermark feed by construction), findings
  # arrive as reviews and inline comments, and a no-findings verdict arrives as the 👍 or as its
  # own "Didn't find any major issues" comment, both of which status_state reads live.
  #
  # A comment's only head association is the stamp POLL_ITEM_DEFS describes; one carrying none
  # renders `commit=-`, and nothing downstream may read that as "another commit".
  jq -r --arg rc "$REVIEWED_COMMIT_RE" "$POLL_ITEM_DEFS"'
    .[] | "--- summary id=\(.id) commit=\(item_stamp($rc)) by \(.user.login)\n\(.body)"' <<<"$new_issue" ||
    return 4

  jq -r "$POLL_ITEM_DEFS"'
    .[] | "--- review id=\(.id) state=\(.state) commit=\(review_commit) by \(.user.login)\n\(.body // "")"' <<<"$new_reviews" ||
    return 4

  # The items above, as one machine-readable line, for a caller that has to decide something about
  # them — `watch` asks which of them are about the head it is watching. Fields per item:
  # kind:id:commit:author:state (`-` where there is none), and none of the five can contain a
  # space or a colon, so the line is safe to split. The id field of a FOLDED inline entry is the
  # `+`-joined list of its thread ids, anchor first (`inline:900+901:…`) — the same token the
  # rendering shows and `reply`/`resolve` take; a consumer wanting the anchor alone takes the part
  # before the first `+`. It stays one field precisely so that this line's arity never depends on
  # whether the reviewer duplicated a thread. The rendered headers are NOT that line: a
  # BODY may contain a line that looks exactly like one — a review of this script quoting poll
  # output does, and this very PR drew one — and a watch that classified by scanning the rendering
  # would take a quoted header for an item and end the wait on the round it was there to skip.
  # Read it as the watermark is read, the LAST match: it is emitted after every body, so a body
  # that quotes one of these lines cannot displace it.
  #
  # Each field is built into a variable before the line is echoed, rather than inside the `echo`'s
  # command substitutions: a jq that failed there contributed an empty field and the line still
  # printed, so a broken program read downstream as "this round had no items of that kind" — the
  # same silent defect the state line's arms exist to prevent (#89). A failed render exits 4 with
  # the watermark unwritten, so the round is retried rather than advanced past.
  local items_inline items_issue items_review
  items_inline=$(jq -r "$POLL_ITEM_DEFS"'[.[] | "inline:\(thread_list):\(inline_commit):\(.user.login):-"] | join(" ")' \
    <<<"$new_inline") || return 4
  items_issue=$(jq -r --arg rc "$REVIEWED_COMMIT_RE" "$POLL_ITEM_DEFS"'
      [.[] | "summary:\(.id):\(item_stamp($rc)):\(.user.login):-"] | join(" ")' <<<"$new_issue") || return 4
  items_review=$(jq -r "$POLL_ITEM_DEFS"'
      [.[] | "review:\(.id):\(review_commit):\(.user.login):\(.state // "-")"] | join(" ")' \
    <<<"$new_reviews") || return 4
  echo "items: $items_inline $items_issue $items_review"

  # Pass this back verbatim next time: per-feed maxima, so replies you post in this round cannot
  # read back as new findings and a big review id cannot mask a smaller comment id. Same rule as
  # the items line: an empty field here would be read back as the watermark 0 and replay the
  # whole feed, so each maximum is taken before the line exists.
  local mark_inline mark_issue mark_review
  mark_inline=$(jq -s --argjson m "$m_inline" '[.[][].id // 0, $m] | max' <<<"$inline") || return 4
  mark_issue=$(jq -s --argjson m "$m_issue" '[.[][].id // 0, $m] | max' <<<"$issue") || return 4
  mark_review=$(jq -s --argjson m "$m_review" '[.[][].id // 0, $m] | max' <<<"$reviews") || return 4
  echo "watermark: $mark_inline,$mark_issue,$mark_review"
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

# The shape of a reviewer that never started. The connector answers a round it could not
# initialize with a plain summary comment — no review, no findings, and (unlike the round-started
# placeholder) no machine tag: "Codex Review: Something went wrong. Try again later by commenting
# “@codex review”." with "Provided git ref <sha> does not exist" in a fenced block beneath it.
#
# ONE expression, and it is the CANONICAL BODY: anchored to the start of the body (\A), the
# reviewer's own sentence WHOLE — through the command it tells you to comment, not just its first
# words, or a round opening "Codex Review: Something went wrong in the retry path" (round 3) or
# "... Try again later by commenting on the retry logic" (round 7) is read as a failure. The
# quote around that command is matched as "up to a few characters", not as itself: the connector
# renders it curly (“@codex review”), and pinning typography is a matcher a straight-quote
# rendering defeats silently. Both callers use it, so a comment can never be a round for one and
# a failure for the other.
#
# The looser shapes were tried and withdrawn (review of #82, rounds 1 and 2). A ref marker taken
# on any line swallowed a comment-only ROUND whose finding quotes "Provided git ref <sha> does
# not exist" — a round about this very matcher — and anchoring that marker to the opening line
# plus a fence did not save it, since a round's summary opens with "Codex Review:" too. What is
# left is a deliberate, LOUD miss: a failure whose opening sentence is ever worded differently
# reads as `expected` and costs one grace, where the swallowed round would have cost a finding,
# silently. (`^` is no use here in either direction: jq's regexes are Oniguruma in Perl mode,
# where `^` is the start of the STRING and nothing else.)
INIT_FAILURE_RE='\A[ \t]*Codex Review:[ \t]*Something went wrong\.[ \t]*Try again later by commenting[^\n]{0,4}@codex review'
# The ref the failure names — the head the reviewer could not fetch. GitHub serves lowercase hex,
# as does the message. A failure that names none is not attributed to any head: see the branch in
# status_state.
INIT_FAILURE_REF_RE='Provided git ref[^0-9a-f]*(?<s>[0-9a-f]{7,40})'
# The head a comment says it is about. The connector stamps "**Reviewed commit:** `<sha>`" on the
# comments it delivers a round or a verdict in, truncated; it is the only head association a
# comment has, and four readers want it — the verdict check, the round count, the success
# boundary the failure recurrence is measured from, and the `commit=` stamp poll renders (which
# is why cmd_poll, defined above, reads a constant assigned here: every command runs after the
# whole file has been read) — so they share one expression.
REVIEWED_COMMIT_RE='Reviewed commit[^0-9a-fA-F]*(?<s>[0-9a-f]{7,40})'

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

# The freshest of several clocks, as an age in seconds, or "-" when none of them is usable. Each
# candidate is validated on ITS OWN and then the smallest age wins — deliberately not `newest`
# over the raw timestamps, because a timestamp in the FUTURE (clock skew, or an explicit
# GIT_COMMITTER_DATE) is the newest string there is while age_of answers it "-": picking it would
# throw away a perfectly good clock beside it and leave the caller with no age at all, which
# every caller reads as "no grace can expire" (the build gate's round 3, ludics-lite#38, and the
# review clock below, which would then never reach its nudge). Callers that have two independent
# bounds on the same event pass both and get the one that is both usable and tightest.
freshest_age() { # <iso timestamp>...
  local ts t best=""
  for ts in "$@"; do
    t=$(age_of "$ts")
    case "$t" in '' | *[!0-9]*) continue ;; esac
    [ -n "$best" ] && [ "$best" -le "$t" ] || best="$t"
  done
  printf '%s' "${best:--}"
}

# "20m" reads better than "1203s" in a line a human skims; the raw seconds stay in the state line.
fmt_age() {
  case "${1:-}" in
  '' | *[!0-9]*) printf 'an unknown time' ;;
  *) if [ "$1" -ge 60 ]; then printf '%dm' "$(($1 / 60))"; else printf '%ds' "$1"; fi ;;
  esac
}

# Prints ONE line, "<token>|<seconds>|<mergeability>|<detail>", and always exits 0 — the token
# carries the failure:
#   approved  👍 is on the PR: the merge gate is open.
#   reviewing 👀 is newer than the reviewer's last word, so a round really is in flight.
#   stalled   ... and it has been in flight longer than any round takes; nothing is coming.
#   failed    the reviewer's newest word is the INITIALIZATION failure above: the round never ran.
#   expected  no live 👀 and no review of the head SHA: a round is due and has not started.
#   idle      the reviewer has reviewed this exact head and left no 👍, so the next move is yours.
#   nudged    watch-only: a fresh nudge owns one creation-time grace window.
#   unknown   a read failed. NOT a state of the PR — hold the previous one and retry.
# <seconds> is how long the state has held: since the 👀 for reviewing/stalled, since the failure
# comment for failed, and for expected since the LATEST of head commit / PR creation / reviewer's
# last word / spent 👀 — i.e. since the moment a review became due; nudged uses
# the fresh nudge comment creation time. "-" when nothing datable was
# read.
#
# `failed` sits below 👍 and below a live 👀, and above everything else. A 👍 is the merge gate
# and outranks any later trouble; a 👀 newer than the failure is a round that started AFTER it,
# and waiting that out is right. Below them it outranks `idle` and `expected` because it is the
# reviewer's newest word about this head and it says the round did not run: `idle` would say the
# head was reviewed (the findings, if any, are an older round's), and `expected` would send the
# caller to wait out a grace for a round that already ended — the reading ocannl-staging#677 got
# for three windows. `stalled` cannot compete: a failure comment is the reviewer speaking, so the
# 👀 above it is spent by definition. It fires only when the failure comment is the reviewer's
# newest non-placeholder comment, is newer than any review OF THE CURRENT HEAD (a round that
# landed after it is the newer truth), and NAMES the current head as the ref it could not fetch.
# A failure about a head that has since been replaced is `expected`, correctly: the new head's
# round has not started yet and has its grace to run. One that names no ref at all is not
# attributed to a head — the branch says why.
#
# For that token ALONE the detail carries one leading `|`-separated field, the head's short SHA,
# which the rendered line names. status_line splits it off; nothing else parses a detail.
# <mergeability> is the PR's mergeable_state as GitHub reports it (clean, dirty, unstable, blocked,
# behind, draft, unknown while it is recomputing), "unread" when the PR read failed, or "-" when
# no PR read was attempted (a feed failed before it). "unread" is rendered as such: a line that
# cannot say whether the PR conflicts must not look like one that says it does not. It rides
# along with EVERY token, because it is not a state of the review but a fact about what the
# review is worth: `dirty` means the merge commit cannot be built, and GitHub creates no
# pull_request workflow run for a head whose merge commit it cannot build — so a round in flight,
# a round landed and a push awaiting review are all rounds whose fixes no CI tests against the
# base (a run from before the base moved still stands; it tested an older merge). On
# ludics-lite#39 (2026-09-04) main gained a sibling at 10:15 while the loop was on round 6, and
# rounds 6 through 12 each got a reviewer round, a "the next move is yours", and no CI at all,
# over eight pushes and 80 minutes; the first thing that noticed was `merge` (ludics-lite#44).
# The reviewer keeps reviewing a conflicted PR, so the tokens above still apply; the field is
# what turns "the next move is yours" into "merge the base in first". The detail is the LAST
# field, so it may contain anything, `|` included (an error line quotes gh).
# Sets head_sha, mstate, pr_created and head_err in the CALLER's scope (status_state's and
# cmd_watch's locals, by bash's dynamic scoping) from one read of the PR. Best-effort: a failed
# read leaves head_sha empty and mstate "unread", and remembers the error line, because it is the
# caller's state that decides whether the missing head is fatal — an approval is the reactions
# feed's alone to answer, and a failed PR read must not hide a 👍 behind "unknown". Placeholders,
# never empty fields: tab is IFS whitespace, and an empty first column would shift the
# mergeability into the SHA (warn_base_drift's trap).
#
# `created_at` rides along for the review clock below: it is the one timestamp that BOUNDS a
# review's lateness from underneath (nothing about a PR can have been due before the PR existed),
# and it costs nothing here, on a read every state line already makes.
pr_head_read() {
  local hline
  head_sha=""
  mstate=unread
  head_err=""
  pr_created=""
  hline=$(gh_retry read api "repos/$REPO/pulls/$1" \
    --jq '[(.head.sha // "-"), (.mergeable_state // "-"), (.created_at // "-")] | @tsv') || {
    head_err=$(gh_err_line)
    return 0
  }
  IFS=$'\t' read -r head_sha mstate pr_created <<<"$hline"
  [ "$head_sha" = - ] && head_sha=""
  [ "${pr_created:--}" != - ] || pr_created=""
  [ -n "$mstate" ] || mstate="-"
  return 0
}

review_after_nudge() { # <event timestamp> <eligible nudge timestamp, or empty>
  [ -z "$2" ] || [[ "$1" > "$2" ]]
}

# A submitted COMMENTED envelope alone proves no findings (#88). Read its OWN
# comments: the flat PR feed can lag behind that endpoint. A failed read is not
# an empty review. Keep all other review states and nonempty summaries untouched.
substantive_reviews() { # <pr>; reviews JSON on stdin
  local pr="$1" raw ids id inline
  raw=$(cat)
  ids=$(jq -r --arg rev "$REVIEWER" '
    .[] | select((.user.login // "") | startswith($rev))
    | select(.state == "COMMENTED" and .submitted_at != null)
    | select((.body // "") | test("[^[:space:]]") | not) | .id' <<<"$raw") || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case "$id" in null | *[!0-9]*) return 1 ;; esac
    inline=$(review_comments "$pr" "$id") || return 1
    if jq -e 'type == "array" and length == 0' <<<"$inline" >/dev/null; then
      raw=$(jq --argjson id "$id" 'map(select(.id != $id))' <<<"$raw") || return 1
    else
      jq -e 'type == "array"' <<<"$inline" >/dev/null || return 1
    fi
  done <<<"$ids"
  printf '%s\n' "$raw"
}

status_state() {
  local pr="$1" raw line age plus plus_at eyes_at rev_at rev_sha com_at last_spoke head_sha head_at
  local running_at evidence evidence_kind evidence_at running_unread vline verd_at verd_sha mstate="-" head_err="" pr_created=""
  local reviews_raw="[]" comments_raw="[]" fline fail_at fail_ref rev_head_at nudge_at="" nudge_age nudge_id="" nudge_line comments_loaded=false

  raw=$(api_list "issues/$pr/reactions?per_page=100") || {
    echo "unknown|-|-|the reactions API did not answer ($(gh_err_line))"
    return 0
  }
  line=$(jq -r --arg rev "$REVIEWER" '
      [.[] | select((.user.login // "") | startswith($rev))]
      | "\(any(.[]; .content == "+1"))"
        + "|" + ((map(select(.content == "eyes") | .created_at) | max) // "")
        + "|" + ((map(select(.content == "+1") | .created_at) | max) // "")' \
    <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|-|the reactions feed did not parse"
    return 0
  }
  plus="${line%%|*}"
  line="${line#*|}"
  eyes_at="${line%%|*}"
  plus_at="${line#*|}"

  # A watch must identify its pending request before accepting a standing verdict.
  # Reuse this comments read below; standalone status keeps its reactions-only
  # approval fast path because it has no incoming watch watermark to spend.
  if [ -n "${watch_nudge_after:-}" ]; then
    comments_raw=$(state_comments "$pr") || {
      echo "unknown|-|-|the comments API did not answer ($(gh_err_line))"
      return 0
    }
    comments_loaded=true
    nudge_line=$(jq -r --argjson after "$watch_nudge_after" '
      [.[] | select(.id > $after)
       | select((.body // "") | test("^@codex review[ \t\r\n]*(_🤖 Addressed by an automated coding agent_)?[ \t\r\n]*$"))
       | {id, at: .created_at}] | max_by(.at)
       | if . == null then "|" else "\(.id)|\(.at)" end' <<<"$comments_raw" 2>/dev/null) || {
      echo "unknown|-|-|the pending-request comments feed did not parse"
      return 0
    }
    nudge_id="${nudge_line%%|*}"
    nudge_at="${nudge_line#*|}"
    nudge_age=$(age_of "$nudge_at")
    case "$nudge_age" in '' | *[!0-9]*) nudge_at="" ;; esac
  fi

  # Reactions have no commit stamp. Preserve reaction-only approvals, including when
  # supplemental reads fail, but do not accept an older 👍 over a known current-head
  # Code Review Running row (#146). Read comments before the head, as below.
  # Completion removes the contradiction; it is not itself a no-findings verdict.
  [ "$plus" = true ] && review_after_nudge "$plus_at" "$nudge_at" && {
    if [ "$comments_loaded" != true ]; then
      comments_raw=$(state_comments "$pr") || comments_raw='[]'
    fi
    reviews_raw=$(state_reviews "$pr") || reviews_raw='[]'
    reviews_raw=$(substantive_reviews "$pr" <<<"$reviews_raw") || {
      echo "unknown|-|$mstate|the review comments API did not establish substantive reviews"
      return 0
    }
    state_head_read "$pr"
    evidence=$(jq -rs --arg rev "$REVIEWER" --arg head "$head_sha" --arg rc "$REVIEWED_COMMIT_RE" '
      .[0] as $comments | .[1] as $reviews |
      def reviewer: select((.user.login // "") | startswith($rev));
      def current: select(.sha != "" and $head != "")
        | select(.sha as $sha | $head | startswith($sha));
      # One entry per Running row the table test admits, each re-matched by the stamp pattern
      # beside it: `[capture(...)] | first` yields null where they disagree instead of yielding
      # NOTHING, which unbracketed here would delete not just that row but every later row of
      # the same stream. The two patterns have to keep agreeing on every Running row, and the
      # count of nulls is the third field below — how the caller hears that they stopped
      # agreeing, rather than reading a deleted row as "no round is running" (#89, #104).
      [$comments[] | reviewer
         | select((.body // "") | contains("codex-pull-request-review-summary"))
         | (.body // "") | split("\n")[]
         | select(test("^\\|[^|]*Code Review[^|]*\\|[^|]*Running"))
         | ([capture("datetime=\"(?<at>[^\"]+)\"[^|]*\\| *`(?<sha>[0-9a-f]{7,40})` *\\|")] | first)]
        as $running |
      [($running[] | select(. != null) | . + {kind:"running"}),
       ($reviews[] | reviewer | select(.submitted_at != null)
         | {sha:(.commit_id // ""), at:.submitted_at, kind:"findings"}),
       ($comments[] | reviewer
         | {sha: ([(.body // "") | capture($rc; "g").s] | last // ""),
            at:(.updated_at // .created_at),
            kind:(if (.body // "") | test("[Dd]idn.t find any major issues")
                  then "verdict" else "findings" end)})]
      | map(current | .at |= sub("\\.[0-9]+Z$"; "Z"))
      | max_by(.at)
      | (if . == null then "|" else "\(.kind)|\(.at)" end)
        + "|" + (($running | map(select(. == null)) | length) | tostring)' \
      <<<"$comments_raw"$'\n'"$reviews_raw" 2>/dev/null) || {
      echo "unknown|-|$mstate|the current-head review evidence did not parse"
      return 0
    }
    evidence_kind="${evidence%%|*}"
    running_unread="${evidence##*|}"
    evidence_at="${evidence#*|}"
    evidence_at="${evidence_at%|*}"
    # The two Running patterns disagreed on a row. Neither "a round is running" nor "none is"
    # is readable from a table this script can only half parse, so neither is claimed.
    case "$running_unread" in
    0) ;;
    *)
      echo "unknown|-|$mstate|a $REVIEWER Code Review row matched the Running test but not the" \
        "stamp pattern beside it, so the running round could not be read"
      return 0
      ;;
    esac
    if [ -n "$evidence_at" ] && [[ "$evidence_at" > "$plus_at" ]]; then
      case "$evidence_kind" in
      running)
        running_at="$evidence_at"
        age=$(age_of "$running_at")
        case "$age" in
        '' | *[!0-9]*) ;;
        *)
          if [ "$age" -ge "$STALL" ]; then
            echo "stalled|$age|$mstate|$REVIEWER Code Review Running for head ${head_sha:0:7} at $running_at"
            return 0
          fi
          ;;
        esac
        echo "reviewing|$age|$mstate|$REVIEWER Code Review Running for head ${head_sha:0:7} at $running_at"
        return 0
        ;;
      findings)
        echo "idle|$(age_of "$evidence_at")|$mstate|$REVIEWER posted findings for head ${head_sha:0:7} at $evidence_at"
        return 0
        ;;
      esac
    fi
    echo "approved|-|$mstate|👍 from $REVIEWER"
    return 0
  }

  raw=$(state_reviews "$pr") || {
    echo "unknown|-|$mstate|the reviews API did not answer ($(gh_err_line))"
    return 0
  }
  raw=$(substantive_reviews "$pr" <<<"$raw") || {
    echo "unknown|-|$mstate|the review comments API did not establish substantive reviews"
    return 0
  }
  # Kept whole for the `failed` branch, which asks whether any review is of the CURRENT head — a
  # question this point in the function cannot yet ask, the head being read after the feeds.
  reviews_raw="$raw"
  # Your own replies land in this feed as COMMENTED reviews, hence the login filter; PENDING reviews
  # have no submitted_at and are not yet the reviewer speaking.
  line=$(jq -r --arg rev "$REVIEWER" '
      [.[] | select((.user.login // "") | startswith($rev)) | select(.submitted_at != null)]
      | sort_by(.submitted_at) | last
      | if . == null then "|" else "\(.submitted_at)|\(.commit_id // "")" end' \
    <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|$mstate|the reviews feed did not parse"
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
  if [ "$comments_loaded" = true ]; then
    raw="$comments_raw"
  else
    raw=$(state_comments "$pr") || {
      echo "unknown|-|$mstate|the comments API did not answer ($(gh_err_line))"
      return 0
    }
    comments_raw="$raw"
  fi
  com_at=$(jq -r --arg rev "$REVIEWER" '
      [.[] | select((.user.login // "") | startswith($rev))
           | select((.body // "") | test("codex-pull-request-review-summary") | not)
           | .created_at] | max // ""' \
    <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|$mstate|the comments feed did not parse"
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
  #
  # A stampless verdict comment stays a ROW here (`[capture] | first`, the same trap cmd_poll's
  # stamp documents: a `capture` that does not match yields no output, and the enclosing object
  # would vanish with it). It then carries no SHA and approves nothing — where dropping the row
  # would have left an OLDER stamped verdict as "the newest", and approved the head on it.
  vline=$(jq -r --arg rev "$REVIEWER" --arg rc "$REVIEWED_COMMIT_RE" '
      [.[] | select((.user.login // "") | startswith($rev))
           | select((.body // "") | test("[Dd]idn.t find any major issues"))
           | {at: (.updated_at // .created_at),
              sha: ([(.body // "") | capture($rc).s] | first // "")}]
      | sort_by(.at) | last
      | if . == null then "|" else "\(.at)|\(.sha)" end' \
    <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|$mstate|the verdict comments feed did not parse"
    return 0
  }
  verd_at="${vline%%|*}"
  verd_sha="${vline#*|}"
  # The initialization failure (INIT_FAILURE_RE above). Only the NEWEST non-placeholder comment is
  # tested, never all of them: any later word supersedes the failure — a findings summary, a
  # no-findings verdict, a second failure naming a different head — and the state it leaves is
  # that word's, not this one's. `created_at`, not `updated_at`: this comment is posted fresh
  # (the placeholder that gets edited in place is filtered out here as everywhere), and taking
  # the same clock as com_at is what makes "the failure IS the reviewer's last word" exact.
  fline=$(jq -r --arg rev "$REVIEWER" --arg re "$INIT_FAILURE_RE" --arg refre "$INIT_FAILURE_REF_RE" '
      [.[] | select((.user.login // "") | startswith($rev))
           | select((.body // "") | test("codex-pull-request-review-summary") | not)]
      | sort_by(.created_at) | last
      | if . == null or ((.body // "") | test($re) | not) then "|"
        else "\(.created_at)|" + ([(.body // "") | capture($refre).s] | first // "")
        end' <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|$mstate|the initialization-failure comments feed did not parse"
    return 0
  }
  fail_at="${fline%%|*}"
  fail_ref="${fline#*|}"
  # A new explicit request supersedes older evidence uniformly: neither an old
  # success, failure, idle review nor reaction can settle that requested round.
  # Newer events retain the established priority rules below.
  review_after_nudge "$eyes_at" "$nudge_at" || eyes_at=""
  if ! review_after_nudge "$rev_at" "$nudge_at"; then rev_at=""; rev_sha=""; fi
  review_after_nudge "$com_at" "$nudge_at" || com_at=""
  if ! review_after_nudge "$verd_at" "$nudge_at"; then verd_at=""; verd_sha=""; fi
  if ! review_after_nudge "$fail_at" "$nudge_at"; then fail_at=""; fail_ref=""; fi
  last_spoke=$(newest "$rev_at" "$com_at")

  # The head SHA and the mergeability, in ONE read of the PR, made AFTER the feeds: every review
  # in those feeds is then about a head no newer than the one read, so "the review's commit_id
  # equals the head" means the CURRENT head was reviewed. Read before the feeds, a push landing
  # between the two reads would match the previous head's review to the previous head and report
  # `idle` (or a verdict comment as `approved`) while the new head sits unreviewed — the false
  # reading this state machine exists to prevent (review of ludics-lite#47). One read serves the
  # verdict check and the post-round states, which used to read it separately. Inside a watch round
  # it is the round's own head read, taken from the snapshot: that read was made after the feeds
  # this function is holding, so the ordering is the same one — and the state cannot then be
  # anchored on a head the round classified nothing against (ludics-lite#95).
  state_head_read "$pr"

  # A no-findings verdict naming the CURRENT head outranks a live-looking 👀, and must be checked
  # BEFORE the in-flight return below: with the placeholder off the comment clock, a verdict
  # delivered by editing that placeholder in place leaves the 👀 newer than the reviewer's last
  # dated word, and the round would read as `reviewing` forever (the app does not always take the
  # 👀 back). Only a verdict NEWER than the 👀 qualifies — a re-requested review without a push
  # raises a fresh 👀 over a verdict whose SHA still matches, and approving on that would reopen
  # the merge gate under a round that is still running (see the updated_at note above for why an
  # edited placeholder passes this bar and a leftover comment does not). A head the PR read did
  # not deliver falls through to the normal state logic rather than failing the whole status.
  if [ -n "$verd_sha" ] && [ -n "$head_sha" ] &&
    { [ -z "$eyes_at" ] || [[ "$verd_at" > "$eyes_at" ]]; }; then
    case "$head_sha" in
    "$verd_sha"*)
      echo "approved|-|$mstate|$REVIEWER posted a no-findings verdict for head ${head_sha:0:7} at $verd_at"
      return 0
      ;;
    esac
  fi

  # In flight only while the 👀 is newer than everything the reviewer has said. An empty last_spoke
  # (nothing posted yet) makes any 👀 live, which is right: that is a first round running.
  if [ -n "$eyes_at" ] && [[ "$eyes_at" > "$last_spoke" ]]; then
    age=$(age_of "$eyes_at")
    case "$age" in
    '' | *[!0-9]*) ;;
    *) [ "$age" -ge "$STALL" ] && {
      echo "stalled|$age|$mstate|👀 from $REVIEWER at $eyes_at with nothing posted since"
      return 0
    } ;;
    esac
    echo "reviewing|$age|$mstate|👀 from $REVIEWER at $eyes_at, newer than its last" \
      "word${last_spoke:+ ($last_spoke)}"
    return 0
  fi

  [ -n "$head_sha" ] || {
    echo "unknown|-|unread|the pulls API did not answer for the head SHA ($head_err)"
    return 0
  }

  # The round that never started. The 👍 and a live 👀 have already returned above, so what is
  # left to rule out is a round that landed ON THIS HEAD after the failure, and a failure about
  # some other head — which the ref it names answers exactly.
  #
  # A failure that names NO ref is not attributed to any head, and falls through to the ordinary
  # due-round states. Two rounds of review went into trying to attribute one (review of #82): the
  # only clock available is the head commit's committer date, and it is commit metadata, not the
  # time that SHA became the head — a force-push or a reset to an older commit dates the new head
  # BEFORE the failure, so the old failure would be reported against it and `watch` would exit on
  # a round still inside its grace. Every failure the connector has posted names its ref in the
  # fenced block, so what this gives up is a shape nobody has seen, and what it costs when that
  # shape appears is one grace — the state before this existed.
  if [ -n "$fail_at" ] && [ -n "$fail_ref" ]; then
    case "$head_sha" in
    "$fail_ref"*)
      rev_head_at=$(jq -r --arg rev "$REVIEWER" --arg sha "$head_sha" '
          [.[] | select((.user.login // "") | startswith($rev))
               | select(.submitted_at != null) | select((.commit_id // "") == $sha)
               | .submitted_at] | max // ""' <<<"$reviews_raw" 2>/dev/null) || {
        echo "unknown|-|$mstate|the reviews feed did not parse for the failed head"
        return 0
      }
      if [ -z "$rev_head_at" ] || [[ "$fail_at" > "$rev_head_at" ]]; then
        # No recurrence count rides on this line. One was tried and removed (review of #82,
        # rounds 1, 3, 4, 5 and 6): "has this head failed before?" has to be measured from the
        # last time the reviewer GOT THROUGH on it, and that success is not always recorded —
        # a clean round posts no review and only a 👍, and the very re-request that then fails
        # CLEARS that reaction, leaving nothing behind to measure from. Every fix made the
        # boundary wider and the next round found the next hole. So the line states both moves
        # unconditionally, which is what the issue asked for and what a caller can act on
        # without the script deciding which case it is in.
        echo "failed|$(age_of "$fail_at")|$mstate|${head_sha:0:7}|$REVIEWER reported an" \
          "initialization failure at $fail_at for ref ${fail_ref:0:7}"
        return 0
      fi
      ;;
    esac
  fi

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
      echo "approved|-|$mstate|$REVIEWER posted a no-findings verdict for head ${head_sha:0:7} at $verd_at"
      return 0
      ;;
    esac
  fi

  # SHA equality, not a timestamp: the review records the commit it was submitted against, so this
  # is exactly "has the reviewer seen THIS head" with no push time to estimate.
  if [ "$rev_sha" = "$head_sha" ]; then
    echo "idle|$(age_of "$last_spoke")|$mstate|$REVIEWER reviewed head ${head_sha:0:7} at $rev_at"
    return 0
  fi

  # The clock on a review that has not started runs from whichever came last: the push, the
  # reviewer's last word, or the spent 👀 — and how late a review is decides whether `watch`
  # waits or tells the caller to nudge, so what stands in for the push matters (ludics-lite#72).
  #
  # The push time is not an API field (pr-review-api-contract.sh skips that belief; `updated_at`
  # moves on comments, so it dates the PR's last activity and not its last push, and a review
  # clock reset by the caller's own replies would never let the grace expire). What is available
  # are two bounds, and the honest clock is the newest of them:
  #   - the head commit's COMMITTER date, which a rebase, amend or cherry-pick all refresh, so it
  #     tracks most pushes — but it is commit metadata, not the moment that commit became the
  #     head: a force-push to an older commit, or a first push of a series written this morning,
  #     dates the head long BEFORE the push, and then the grace is spent before the reviewer has
  #     had a second (this issue's report: a PR opened seconds earlier read "due for 22m" and
  #     recommended a nudge). It cannot bound the wait from underneath at all;
  #   - the PR's own `created_at`, which does: no review of this PR can have been due before the
  #     PR existed. It is a floor, not the push — on the second and later pushes it is far too
  #     old to be the clock — which is exactly why it is taken TOGETHER with the committer date
  #     rather than instead of it.
  # freshest_age takes the tighter of the two, each validated on its own, so a committer date in
  # the future cannot blind the clock either.
  #
  # A failed commit read costs precision, not the state: the PR's own timestamps remain.
  head_at=$(gh_retry read api "repos/$REPO/commits/$head_sha" --jq .commit.committer.date) ||
    head_at=""
  if [ -n "$nudge_at" ]; then
    # An earlier request must not shorten a newly committed head or newly opened
    # PR's pickup grace. Reuse the same validated clocks as ordinary expected.
    nudge_age=$(freshest_age "$nudge_at" "$head_at" "$pr_created")
    echo "nudged|$nudge_age|$mstate|$nudge_id|fresh review nudge; waiting for pickup"
    return 0
  fi
  echo "expected|$(freshest_age "$head_at" "$pr_created" "$last_spoke" "$eyes_at" "$nudge_at")|$mstate|no 👀" \
    "in flight and no review of head ${head_sha:0:7}${rev_sha:+; $REVIEWER last reviewed ${rev_sha:0:7} at $rev_at}"
}

state_tok() { printf '%s' "${1%%|*}"; }
state_age() {
  local rest="${1#*|}"
  printf '%s' "${rest%%|*}"
}
state_merge() {
  local rest="${1#*|}"
  rest="${rest#*|}"
  printf '%s' "${rest%%|*}"
}
state_detail() {
  local rest="${1#*|}"
  rest="${rest#*|}"
  printf '%s' "${rest#*|}"
}

# The one word of the mergeability that changes what a round is worth. `dirty` is GitHub's term
# for "the merge commit cannot be created", and it is the only value on which no pull_request
# run will test the head merged with the current base (a run that completed before the base
# moved, or a branch-push run, may well exist — they tested the head against an older base, or
# alone, which is why the note says what is NOT tested rather than that nothing ran); `unknown`
# is GitHub still computing (moments after a push) and `behind`/`blocked`/`unstable` are
# branch-protection verdicts the checks gate reads for itself. `unread` is a PR read that failed
# under a state the reactions feed decided on its own, and is said as such: "cannot tell" must
# not render like "does not conflict". Empty when there is nothing to say, so a caller can splice
# it in with ${x:+; $x}.
conflict_note() {
  case "$1" in
  dirty)
    printf '%s' "CONFLICTS with the base (mergeable_state=dirty): GitHub cannot build this head" \
      " merged with the current base, so no pull_request run tests that merge and the rounds'" \
      " fixes go untested against it — merge the base in, resolve, and push before the next round"
    ;;
  unread)
    printf '%s' "mergeability UNREAD (the PR read did not answer): whether this PR conflicts with" \
      " its base is unknown, which is not 'no' — retry status before acting on this line"
    ;;
  # GitHub recomputes the mergeability after every push and reports `unknown` for the seconds it
  # takes, so the first status after the push that CAUSED a conflict reads exactly like a clean
  # one. Not a conflict, and not a clean bill of health either.
  unknown)
    printf '%s' "mergeability NOT YET COMPUTED (mergeable_state=unknown, GitHub recomputes it" \
      " after every push): a conflict this push caused would not show yet — re-read status in a" \
      " minute"
    ;;
  # A draft is not a mergeability in the sense the other arms carry — nothing about the base
  # merge — but GitHub reports it through the same field, and it is the one remaining value that
  # changes the answer (ludics-lite#49): no sequence of reviewer actions lands a draft, so every
  # "next move" the tokens name is wrong over it until someone marks it ready. Read from
  # mergeable_state rather than the PR's own `.draft` boolean because `pr_head_read` already
  # carries this field on every state line and nothing outside status_line parses the format
  # (#47 dropped an extra-field proposal on exactly that ground); should `.draft` ever be needed
  # on its own, the arm stays and the field is what changes.
  # The command names the repository: `status` is invoked as owner/repo#pr from shells whose
  # working directory is unreliable, where a bare `gh pr ready <n>` cannot resolve the repo.
  draft)
    printf '%s' "DRAFT (mergeable_state=draft): a draft cannot be merged and no reviewer action" \
      " lands it — mark it ready (gh pr ready ${PR_NUM:-<pr>} --repo $REPO) when it is; the" \
      " review rounds still count"
    ;;
  esac
  return 0
}

# Takes a whole state line, not a token: the age and the detail are what make the difference between
# "wait it out" and "nothing is coming" legible to whoever reads the log.
status_line() {
  local tok age detail merge conflict fsha frest
  tok=$(state_tok "$1")
  age=$(state_age "$1")
  detail=$(state_detail "$1")
  [ "$tok" != nudged ] || detail="${detail#*|}"
  merge=$(state_merge "$1")
  conflict=$(conflict_note "$merge")
  case "$tok" in
  approved) echo "approved ($detail)${conflict:+; $conflict}" ;;
  reviewing) echo "reviewing — $detail, running $(fmt_age "$age") — wait it out${conflict:+; $conflict}" ;;
  stalled) echo "STALLED — $detail for $(fmt_age "$age"), longer than a round takes. FIRST read" \
    "the PR feed yourself (retry --read pr view <pr> --comments): a verdict may have landed as" \
    "a comment or a 👍 this state machine missed. Only if the feed truly has nothing for the" \
    "current head, nudge with a '@codex review' comment — knowing a re-request CLEARS the" \
    "reviewer's existing 👍${conflict:+; $conflict}" ;;
  # The remedy, not the diagnosis, is what this line is for: the reviewer's clone is behind, and
  # nothing the caller waits for changes that. A nudge re-runs the fetch and usually succeeds
  # (ocannl-staging#677's third head reviewed normally after one); if the same head fails again,
  # only a new head gives the reviewer an object its clone can resolve. Both moves are stated,
  # in order, rather than the script deciding which one the caller is due — see status_state for
  # why counting the failures on a head cannot be done honestly.
  failed)
    fsha="${detail%%|*}"
    frest="${detail#*|}"
    echo "reviewer FAILED at initialization on head $fsha — nudge it once with a '@codex review'" \
      "comment (pr-review.sh comment $REPO#${PR_NUM:-<pr>} '@codex review'); if the SAME head" \
      "fails again, push a new head instead (an amend suffices: git commit --amend --no-edit &&" \
      "git push --force-with-lease), since the reviewer's clone is behind, not your push — the" \
      "ref it could not fetch is one the PR and git ls-remote both serve. This is not a round —" \
      "$frest, standing for $(fmt_age "$age")${conflict:+; $conflict}"
    ;;
  expected | nudged) echo "review EXPECTED but not started — $detail; due for $(fmt_age "$age")${conflict:+; $conflict}" ;;
  # "The next move is yours" is exactly the line that sent #39 into seven untested rounds: on a
  # conflicted PR the move is the base merge, and saying anything else invites another push. A
  # draft takes it away for the same reason (#49): its move is `gh pr ready`, and "yours" would
  # read as "address the round and push" over a PR no push can land. Only a KNOWN conflict or
  # draft takes the move away, though: a mergeability still being computed leaves the move where
  # it was and rides along as a caveat. `unread` needs no arm of its own here: with no
  # head SHA the idle branch of status_state cannot fire at all, so a failed PR read lands in
  # `unknown` — test_failed_pr_read_is_unknown_where_the_head_decides pins that.
  idle)
    case "$merge" in
    dirty | draft) echo "nothing in flight — $detail, and no 👍; $conflict" ;;
    *) echo "nothing in flight — $detail, and no 👍; the next move is yours${conflict:+; $conflict}" ;;
    esac
    ;;
  unknown) echo "UNKNOWN — $detail; this is NOT 'not approved', retry${conflict:+; $conflict}" ;;
  *) echo "unrecognised state '$tok' — treat as unknown and retry" ;;
  esac
}

# How many review rounds have carried findings, read off the PR rather than remembered: a session
# that has been compacted twice cannot say what round it is in, and the convergence policy (the
# skill's "When the loop ends") needs the number. A round with findings is a burst of COMMENTED
# reviews the reviewer submitted against one head — one per inline comment plus a summary, all
# within seconds — so the count is the number of such bursts: in submission order, a review
# starts a new round when it is on a different head than the previous one OR lands more than
# ROUND_GAP after it. The gap is what keeps a re-requested round on the same head (the
# `@codex review` nudge the status verdicts recommend needs no push) from collapsing into the
# round before it, which a distinct-heads count did (review of ludics-lite#39). Your own replies
# land in the same feed as COMMENTED reviews, hence the login filter; PENDING reviews have no
# submitted_at and are not a round. Prints ONE line, "<count>|<detail>", and always exits 0:
# a count of "unknown" carries the failure, and is NOT "no rounds yet".
review_rounds() {
  local pr="$1" raw comments line count heads
  raw=$(api_list "pulls/$pr/reviews?per_page=100") || {
    echo "unknown|the reviews API did not answer ($(gh_err_line))"
    return 0
  }
  raw=$(substantive_reviews "$pr" <<<"$raw") || {
    echo "unknown|the review comments API did not establish substantive reviews"
    return 0
  }
  # A round can also arrive as an issue comment alone — the same shape status_state treats as
  # the reviewer speaking — so those count too, minus the round-started placeholder, the
  # no-findings verdict, and the initialization failure: an attempt that never ran carries no
  # findings, and counting it inflated ocannl-staging#677 to "1 round(s) of findings over 0
  # head(s)" — a threshold reading made of two failed fetches (ludics-lite#78). It is dropped
  # from the COMMENT feed alone, which is the only feed it has ever arrived in: a review carries
  # the commit it was submitted against, and the reviewer submits none when it cannot fetch it.
  #
  # The test is INIT_FAILURE_RE, the canonical body, which is `status_state`'s test too: a
  # comment is a failure for both or a round for both. A comment-only round whose finding quotes
  # "Provided git ref <sha> does not exist" — a round about this very matcher — is a round here
  # and on the state line, and that is what the anchored expression buys (review of #82).
  comments=$(api_list "issues/$pr/comments?per_page=100") || {
    echo "unknown|the comments API did not answer ($(gh_err_line))"
    return 0
  }
  # Both feeds go in on stdin (slurped: reviews first, comments second), never as arguments —
  # a long PR's comment history outgrows the argument list (128 KB per argument on Linux).
  line=$(printf '%s\n%s\n' "$raw" "$comments" | jq -r -s --arg rev "$REVIEWER" \
    --argjson gap "$ROUND_GAP" --arg fail "$INIT_FAILURE_RE" --arg rc "$REVIEWED_COMMIT_RE" '
      .[1] as $comments | .[0]
      | ([.[] | select((.user.login // "") | startswith($rev))
           | select(.submitted_at != null)
           | select(.state == "COMMENTED" or .state == "CHANGES_REQUESTED")
           | {sha: (.commit_id // ""), t: (.submitted_at | fromdateiso8601)}]
       + [$comments[] | select((.user.login // "") | startswith($rev))
           | select((.body // "") | test("codex-pull-request-review-summary") | not)
           | select((.body // "") | test("[Dd]idn.t find any major issues") | not)
           | select((.body // "") | test($fail) | not)
           # `[capture] | first` for the reason the stamp in cmd_poll spells out: an unmatched
           # `capture` yields no output, and the object around it would vanish rather than fall
           # back to "comment" — a findings summary that carried no stamp would not be counted
           # as a round at all, which is the fallback beside it saying the opposite.
           | {sha: (([(.body // "") | capture($rc).s] | first) // "comment"),
              t: (.created_at | fromdateiso8601)}])
      | sort_by(.t)
      # Same head when equal, or when one is a prefix of the other: a comment quotes a
      # truncated sha, a review records the full one.
      | def same($a; $b): $a == $b
          or ($a != null and $b != null and $a != "" and $b != ""
              and (($a | startswith($b)) or ($b | startswith($a))));
        reduce .[] as $r ({n: 0, sha: null, t: 0};
          if (same($r.sha; .sha) | not) or ($r.t - .t) > $gap
          then {n: (.n + 1), sha: $r.sha, t: $r.t}
          else {n: .n, sha: .sha, t: $r.t} end)
      | "\(.n)|" + ([.] | length | tostring)' 2>/dev/null) || {
    echo "unknown|the reviews feed did not parse"
    return 0
  }
  count="${line%%|*}"
  case "$count" in
  '' | *[!0-9]*)
    echo "unknown|the reviews feed did not parse"
    return 0
    ;;
  esac
  heads=$(jq -r --arg rev "$REVIEWER" '
      [.[] | select((.user.login // "") | startswith($rev))
           | select(.submitted_at != null)
           | select(.state == "COMMENTED" or .state == "CHANGES_REQUESTED")
           | (.commit_id // "")] | unique | map(select(. != "")) | length' \
    <<<"$raw" 2>/dev/null) || heads="?"
  echo "$count|$count round(s) of $REVIEWER findings over $heads head(s)"
}

# The count against the threshold, on one line; exit 0 at or under it, 1 past it, 3 unread. The
# threshold is the skill's, not this script's: nothing here refuses a merge over it. It exists so
# the session reads "round 13" off the PR instead of believing it is at round 6. Past it the skill
# fixes only BLOCKING findings — narrowly: what would make the PR wrong, not a bug as such — and
# defers the rest to one follow-up issue, so the loop ends on the first round with nothing to push.
rounds_line() {
  local count detail
  count="${1%%|*}"
  detail="${1#*|}"
  case "$count" in
  unknown)
    echo "review rounds: UNKNOWN — $detail; this is NOT 'no rounds yet', retry"
    return 3
    ;;
  esac
  case "$ROUND_THRESHOLD" in
  '' | off | *[!0-9]*)
    echo "review rounds with findings: $count ($detail); no threshold set"
    return 0
    ;;
  esac
  if [ "$count" -gt "$ROUND_THRESHOLD" ]; then
    echo "review rounds with findings: $count, PAST the $ROUND_THRESHOLD-round threshold —" \
      "blocking-only from here: fix what would make the PR wrong (a bug as such does not" \
      "qualify), defer the rest to ONE follow-up issue, and merge on the first round with" \
      "nothing to push ($detail)"
    return 1
  fi
  if [ "$count" -eq "$ROUND_THRESHOLD" ]; then
    echo "review rounds with findings: $count of $ROUND_THRESHOLD — the last round addressed in" \
      "full; from the next, only blocking findings are fixed ($detail)"
    return 0
  fi
  echo "review rounds with findings: $count of $ROUND_THRESHOLD ($detail)"
  return 0
}

cmd_rounds() {
  pr_arg "${1:?usage: rounds <pr>}"
  rounds_line "$(review_rounds "$PR_NUM")"
}

cmd_status() {
  pr_arg "${1:?usage: status <pr>}"
  local state
  state=$(status_state "$PR_NUM")
  status_line "$state"
  # The round count rides along so the convergence policy is always in view; it never changes
  # this command's exit code — the merge gate is the state, and an unread count is reported as
  # such on its own line rather than turning an approval into an "unknown".
  rounds_line "$(review_rounds "$PR_NUM")" || true
  # Exit 3 on unknown so a caller gating a merge on `status` cannot read a failed read as a quiet
  # "not approved yet" — the same collapse api_list refuses to make. 3 rather than 2, because a
  # usage error (2) is the caller's to fix and this one is the API's to recover from.
  [ "$(state_tok "$state")" = unknown ] && return 3
  return 0
}

# What `merge` reads last — how far behind its base the branch is, whether the base's advance
# touched the PR's files, whether the PR conflicts — read at the moment a round lands instead,
# because that is when it is cheap to act on: the round's fixes are about to be written, and
# "the base touched these files" or "CONFLICTS" is the instruction to merge the base in FIRST,
# so the next push is one CI can test. Read only at merge time, it arrives after every round has
# been paid for (ludics-lite#44: seven rounds on a conflicted #39, 80 minutes, no CI). On stderr
# with the rest of the context, so a round's stdout stays byte-identical to poll's; not on the
# `approved` exit, whose next step is `merge`, which prints the same read on stdout.
watch_drift_note() {
  warn_base_drift "$1" >&2 || true
}

# Is a rendered item about the head being watched? The stamp poll prints is the reviewer's own
# commit association, truncated to seven characters, while the head is a full SHA — so the test is
# a PREFIX test, the shorter side against the longer (the comparison status_state already makes
# against a verdict comment's "Reviewed commit:"), and never equality, which the truncation would
# fail on every item. Two answers are YES without comparing anything, both deliberately: an item
# carrying NO association (`-`), since a missing stamp is not evidence about a head; and any item
# at all when the head could not be read. In both, the expensive mistake would be swallowing a
# finding, not waking on an old one — and the line the caller exits on says which case it was in.
item_about_head() { # <stamp> <head sha>
  case "${1:-}" in '' | -) return 0 ;; esac
  [ -n "${2:-}" ] || return 0
  case "$2" in "$1"*) return 0 ;; esac
  case "$1" in "$2"*) return 0 ;; esac
  return 1
}

# One poll of the three feeds, the head its items have to be ABOUT, and the split of what it
# rendered into the two kinds. The results land in globals rather than on stdout because the
# split is six values wide and a command substitution's assignments would not survive its
# subshell; every one is reset here, so nothing leaks from the round before.
#   POLLED_OUT / POLLED_RC  poll's own stdout and exit code, verbatim
#   POLLED_MARK             the watermark to resume from (the caller's, when the poll failed)
#   POLLED_HEAD             the head the round was judged against ("" when the PR read failed)
#   POLLED_ON  / _ON_N      the items about that head: the first one's descriptor, and how many
#   POLLED_PAST / _PAST_N   the items about some other commit, likewise
#
# The head is read AFTER the poll — status_state's ordering, for status_state's reason: every item
# the poll rendered is then about a head no newer than the one read, so an item can never be
# matched to a head that replaced the one it was written against. The read is skipped when the
# poll failed: there is nothing to classify, and an outage is not the moment to spend a call.
#
# It is the round's ONE head read, and status_state takes it from here rather than making its own
# (ludics-lite#95): the feeds were read first, this head after them, and both halves of the round
# are then about that one pair of instants. Sharing it is what makes the ordering a property of the
# round instead of a coincidence of two functions that each got it right — a push landing between
# this read and the state read used to leave the state anchored on a head this round never
# classified anything against.
watch_round() { # <pr> <watermark>
  local entry rest kind id commit login state desc next head_sha mstate head_err pr_created
  snapshot_arm
  POLLED_OUT=$(cmd_poll "$1" "$2")
  POLLED_RC=$?
  POLLED_MARK="$2"
  POLLED_HEAD=""
  POLLED_ON=""
  POLLED_ON_N=0
  POLLED_PAST=""
  POLLED_PAST_N=0
  # A failed API round yields no watermark; keeping the caller's stops a transient error from
  # resetting to 0 and replaying the whole backlog as if it were a new round.
  #
  # Read ONLY from a round that succeeded, and after the status check, not before it. A round
  # that fails partway has already printed the bodies it got through — a rendering that could
  # not run leaves exactly that (#89) — and a reviewer body can carry a line that looks exactly
  # like this one, the same trap the `items:` line below documents and which a review of this
  # script drew for real. Taken from a failed round, such a line advances the watermark past
  # findings the retry would then never show.
  # A round that did not answer publishes nothing: a caller reading the state next must read the
  # feeds itself and report what ITS read says, rather than take an outage for a quiet feed.
  [ "$POLLED_RC" -eq 0 ] || {
    snapshot_drop
    return 0
  }
  next=$(sed -n 's/^watermark: //p' <<<"$POLLED_OUT" | tail -1)
  case "$next" in [0-9]*,[0-9]*,[0-9]*) POLLED_MARK="$next" ;; esac
  pr_head_read "$1"
  snapshot_put_head "$1"
  POLLED_HEAD="$head_sha"
  # From the `items:` line poll emits, never from the rendered headers: a reviewer BODY can carry
  # a line that looks exactly like a header (see cmd_poll). Splitting on whitespace is the point.
  # An inline entry's id may be a `+`-joined list of duplicated threads (ludics-lite#76); it is
  # one item here, as it is one finding — the act/quiet decision counts entries, not threads, and
  # the exit line names the whole list so the caller can hand it straight back to `reply`.
  # shellcheck disable=SC2013,SC2086
  for entry in $(sed -n 's/^items: //p' <<<"$POLLED_OUT" | tail -1); do
    kind="${entry%%:*}"
    rest="${entry#*:}"
    id="${rest%%:*}"
    rest="${rest#*:}"
    commit="${rest%%:*}"
    rest="${rest#*:}"
    login="${rest%%:*}"
    state="${rest#*:}"
    # What the exit line names: the id, the review state where there is one, the short commit and
    # the author — enough to tell "the reviewer answered this head" from "an old review went by".
    desc="$kind id=$id"
    [ "$state" = - ] || desc="$desc state=$state"
    desc="$desc commit=$commit by $login"
    if item_about_head "$commit" "$POLLED_HEAD"; then
      POLLED_ON_N=$((POLLED_ON_N + 1))
      [ -n "$POLLED_ON" ] || POLLED_ON="$desc"
    else
      POLLED_PAST_N=$((POLLED_PAST_N + 1))
      [ -n "$POLLED_PAST" ] || POLLED_PAST="$desc"
    fi
  done
  return 0
}

# The record of what scrolled past: reviewer activity about some OTHER commit, which the watermark
# has just advanced past and nothing will render again. It goes to stderr, whole — stdout is what
# the caller is to ACT on, and a previous head's round is not it — and it is counted across the
# window, so the exit line can say how much went by. Only ever called on a round that rendered
# nothing about the head; where a round rendered both, the acting exit puts the lot on stdout.
# Updates past_seen and past_last in cmd_watch's scope (bash's dynamic scoping, as pr_head_read
# uses for the head).
watch_note_past() { # <pr>
  [ "$POLLED_PAST_N" -gt 0 ] || return 0
  past_seen=$((past_seen + POLLED_PAST_N))
  past_last="$POLLED_PAST"
  warn "PR $REPO#$1: $POLLED_PAST_N item(s) NOT about head ${POLLED_HEAD:0:7} (first: $POLLED_PAST)" \
    "— printed below for the record; the watermark advances past them and the wait continues"
  sed -e '/^watermark: /d' -e '/^items: /d' <<<"$POLLED_OUT" >&2
}

# What a quiet exit exits ON. The head the wait was bound to, the window it covered when there is
# one, and how much reviewer activity about OTHER commits scrolled past meanwhile — the half no
# log could tell before (ludics-lite#72): without it, "an old review scrolled past three times"
# and "the reviewer never said anything" are the same silent window. No trailing newline, so a
# caller can splice the state onto the same line.
watch_quiet_line() { # <window seconds, or - for a verdict mid-window>
  local h="${POLLED_HEAD:0:7}" about
  # Three different silences, and they must not read alike: a head that was read, a head the PR
  # read did not answer for (the feeds did), and a last look that answered nothing at all.
  about="head ${h:-UNREAD}"
  [ "$POLLED_RC" -eq 0 ] || about="the head (the last poll did not answer)"
  printf 'no reviewer activity about %s' "$about"
  [ "$1" = - ] || printf ' in %ss' "$1"
  [ "$past_seen" -eq 0 ] ||
    printf '; %d item(s) about another commit scrolled past (last: %s)' "$past_seen" "$past_last"
}

# The acting exit: what the wait ended ON, by name, and then the round itself on stdout, byte for
# byte as poll printed it (watermark last), so a caller can consume watch and poll the same way.
# The state and the drift read are context, not the finding, so they go to stderr. Naming the item
# is what makes "the reviewer answered this head" and "an old review scrolled past" read
# differently in a log that used to show the same line for both: the descriptor poll rendered
# carries the id, the review state, the short commit and the author.
watch_act() { # <pr> <state line>
  local extra="" original_mark="$mark"
  [ "$POLLED_ON_N" -le 1 ] || extra=" (+$((POLLED_ON_N - 1)) more about this head)"
  [ "$POLLED_PAST_N" -eq 0 ] || extra="$extra (+$POLLED_PAST_N about another commit, below)"
  [ -n "$POLLED_HEAD" ] ||
    extra="$extra (the head did not read this round, so nothing was held back for being old)"
  # Same-head findings preceding a pending request remain actionable. Surface
  # them, but leave the nudge itself pending so the next observer can await the
  # requested round without replaying these older issue comments.
  if [ "$(state_tok "$2")" = nudged ]; then
    local pending_id
    pending_id=$(state_detail "$2")
    pending_id="${pending_id%%|*}"
    case "$pending_id" in
    '' | *[!0-9]*) ;;
    *)
      if [ "$pending_id" -gt 0 ] && [ "$(mark_of "$mark" 2)" -ge "$pending_id" ]; then
        mark="$(mark_of "$mark" 1),$((pending_id - 1)),$(mark_of "$mark" 3)"
        warn "nudge $pending_id remains pending; keep an observer after handling these review items"
      fi
      ;;
    esac
  elif [ "$(state_tok "$2")" = unknown ]; then
    watch_preserve_unarmed_nudge "$last_healthy_mark" "" "$2"
  fi
  if [ "$mark" != "$original_mark" ]; then
    POLLED_OUT=$(sed '$d' <<<"$POLLED_OUT")
    POLLED_OUT="$POLLED_OUT"$'\n'"watermark: $mark"
  fi
  echo "status: $(status_line "$2")" >&2
  watch_drift_note "$1"
  warn "PR $REPO#$1: ending the wait on ${POLLED_ON:-reviewer activity}$extra"
  echo "$POLLED_OUT"
}

# One last poll before any verdict that says no round came (ludics-lite#72; the race is the one
# ludics-lite#55 hit). Between the poll a round was judged on and the verdict about to be printed
# lie a status read, a drift read and their retries — seconds in which the reviewer can post, and
# a nudge recommended on top of a round that has just landed is the loudest wrong thing this loop
# can say. So the round wins, and the verdict is dropped.
#
# It carries the caller's watermark and blind/saw accounting forward exactly as a loop round does
# (through cmd_watch's locals, by dynamic scoping): a final poll that answers proves the tail of
# the window was observed, and one that does not is reported as such rather than papered over —
# reporting a quiet window whose last read failed is the silent stall this script exists to
# prevent.
# 0 = nothing new; 1 = a round about the head arrived, in the POLLED_* globals; 3 = the poll did
# not answer, so nothing about the gap is known.
watch_settle() { # <pr>
  watch_round "$1" "$mark"
  mark="$POLLED_MARK"
  if [ "$POLLED_RC" -eq 0 ]; then
    saw=1
    blind=0
  else
    blind=$((blind + 1))
    return 3
  fi
  [ "$POLLED_ON_N" -eq 0 ] || return 1
  watch_note_past "$1"
  return 0
}

# The end of the wait, in one place, for every verdict that says nothing is coming. It prints
# whatever the window turned out to be, and RETURNS WHAT cmd_watch RETURNS:
#   0  the verdict still stands, or the round the final poll found instead, or the approval;
#   1  the verdict was dropped because the state moved — a quiet window, re-arm;
#   3  the verdict is WITHHELD: the final poll or the state re-read did not answer, so nothing
#      rules out a round in the gap, and a nudge recommended over one re-requests the review and
#      CLEARS the 👍 it was about to get. An unanswered call is not a fact about the PR.
#
# The state is re-read after that poll, and only the state the verdict was ABOUT is still the
# verdict: cmd_poll reads comments and reviews, and the 👍 is on neither, so an approval landing
# in this same gap would otherwise be answered with a nudge — the one move that destroys it.
# A final poll may see a nudge that no watch status read has armed yet. Keep
# only that feed's old cursor when a fresh nudge (or an unreadable status) is
# discovered at exit; the next watch can then spend it. Other feed cursors stand.
watch_preserve_unarmed_nudge() { # <pre-settle watermark> <previous state> <new state>
  local old_issue next_issue next_tok
  old_issue=$(mark_of "$1" 2)
  next_issue=$(mark_of "$mark" 2)
  [ "$next_issue" -gt "$old_issue" ] || return 0
  next_tok=$(state_tok "$3")
  case "$next_tok" in
  nudged)
    if [ "$(state_tok "$2")" = nudged ] &&
      [ "$(state_detail "$2")" = "$(state_detail "$3")" ]; then return 0; fi
    ;;
  unknown) ;; # An unreadable final status cannot prove a new nudge was consumed safely.
  *) return 0 ;;
  esac
  mark="$(mark_of "$mark" 1),$old_issue,$(mark_of "$mark" 3)"
  warn "keeping the final poll's issue comments pending for the next watch; a new nudge may still need its grace"
}

watch_end() { # <pr> <the state token the verdict is about> <message, empty for none>
  local rc before_settle="$mark" before_state="$state"
  watch_settle "$1"
  rc=$?
  if [ "$rc" -eq 1 ]; then
    # The state beside a round is re-read too: the verdict's own state ("nothing in flight", "no
    # review of the head") is exactly the reading that round has just falsified.
    watch_act "$1" "$(status_state "$1")"
    return 0
  fi
  if [ "$rc" -eq 3 ]; then
    echo "the final poll before the '$2' verdict on PR $REPO#$1 did not answer" \
      "($(gh_err_line)), so nothing rules out a round that landed while the state was being" \
      "read — the verdict is WITHHELD, and this window says nothing about the reviewer; re-arm"
    echo "watermark: $mark"
    return 3
  fi
  state=$(status_state "$1")
  tok=$(state_tok "$state")
  watch_preserve_unarmed_nudge "$before_settle" "$before_state" "$state"
  if [ "$tok" = unknown ]; then
    echo "the state could not be re-read after the final poll on PR $REPO#$1, so the '$2' verdict" \
      "is WITHHELD — $(state_detail "$state"); this is NOT 'the reviewer stayed quiet', re-arm"
    echo "watermark: $mark"
    return 3
  fi
  if [ "$tok" = approved ] && [ "$2" != approved ]; then
    echo "the '$2' verdict on PR $REPO#$1 was dropped: the 👍 landed while it was being read —" \
      "$(status_line "$state")"
    echo "watermark: $mark"
    return 0
  fi
  if [ "$tok" = nudged ] && [ "$(state_tok "$before_state")" = nudged ] &&
    [ "$(state_detail "$before_state")" != "$(state_detail "$state")" ]; then
    echo "the '$2' verdict on PR $REPO#$1 was dropped: a newer nudge still needs its grace; re-arm"
    echo "watermark: $mark"
    return 1
  fi
  if [ "$tok" != "$2" ]; then
    echo "the '$2' verdict on PR $REPO#$1 was dropped: the state moved to '$tok' while it was" \
      "being read — $(status_line "$state"); nothing here says the reviewer is done, re-arm"
    echo "watermark: $mark"
    return 1
  fi
  watch_drift_note "$1"
  [ -z "$3" ] || echo "$3"
  echo "$(watch_quiet_line -); status: $(status_line "$state")"
  echo "watermark: $mark"
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
# What ends the wait is reviewer activity about the head being watched, and nothing else
# (ludics-lite#72). A review, finding or summary about some OTHER commit is a previous round
# scrolling past above the watermark — the shape that fired on this repository: a round's watch
# exited on the inline findings and took its watermark from that poll, the reviewer's separate
# summary review landed seconds later with a higher id, and the NEXT window returned 0 on it
# immediately, with nothing about the new head to act on. It is printed for the record on stderr,
# the watermark advances past it, and the wait continues.
#
# "Keep waiting" is a claim, and this loop is only allowed to make it while something is running.
# Every other state gets a bounded wait and then a verdict, because a window that reports nothing is
# indistinguishable — to the caller and to the user watching the clock — from a window that reported
# a stale 👀 three times in a row.
# A healthy live-round or nudge read provides an absolute grace deadline. An
# unreadable state supplies none; cmd_watch retains its last healthy candidate.
watch_grace_deadline() {
  local tok age
  tok=$(state_tok "$1")
  case "$tok" in reviewing | nudged) ;; *) return 0 ;; esac
  age=$(state_age "$1")
  case "$age" in '' | *[!0-9]*) return 0 ;; esac
  echo $((SECONDS + GRACE - age))
}

# The round snapshot belongs to this command and to nothing after it, hence the wrapper: the loop
# arms a snapshot on every round, and the arming must not outlive the watch. Its locals stay in
# watch_loop, which is the scope watch_note_past and pr_head_read reach into.
#
# The sweep is here for a related reason: a watch is the longest-lived command this script has and
# the one that runs on a box routinely, so the start of one is the natural place to notice what a
# SIGKILLed run — a watch, a gh call, a fixture suite — left in TMPDIR. It sweeps every family,
# not just the snapshot's (ludics-lite#219); see tmp_sweep_stale for why that is safe.
cmd_watch() {
  local rc=0
  tmp_sweep_stale
  watch_loop "$@" || rc=$?
  snapshot_off
  return "$rc"
}

watch_loop() {
  local pr="${1:?usage: watch <pr> [watermark]}" mark="${2:-}"
  pr_arg "$pr"
  pr="$PR_NUM"
  local interval="${WATCH_INTERVAL:-90}" timeout="${WATCH_TIMEOUT:-900}"
  local start=$SECONDS was state tok age quiet=0 saw=0 blind=0 past_seen=0 past_last=""
  local watch_nudge_after extension_end="" candidate_end candidate_kind extension_kind="" extension_mark="" remaining pause elapsed final_state last_healthy_mark="$mark"
  watch_nudge_after=$(mark_of "$mark" 2)

  state=$(status_state "$pr")
  was=$(state_tok "$state")
  candidate_end=$(watch_grace_deadline "$state")
  candidate_kind="$was"
  echo "watching PR $REPO#$pr, every ${interval}s for up to ${timeout}s;" \
    "from: $(status_line "$state")" >&2

  while :; do
    watch_round "$pr" "$mark"
    mark="$POLLED_MARK"
    if [ "$POLLED_RC" -eq 0 ]; then
      saw=1
      blind=0
    else
      blind=$((blind + 1))
    fi

    state=$(status_state "$pr")
    tok=$(state_tok "$state")
    age=$(state_age "$state")
    if [ "$tok" != unknown ]; then
      # The first negative read still holds the live round: only the second
      # confirms it ended. Do not discard its deadline at that first boundary.
      if ! { [ "$was" = reviewing ] && [ "$tok" != reviewing ] &&
        [ "$tok" != nudged ] && [ "$quiet" -eq 0 ]; }; then
        candidate_end=$(watch_grace_deadline "$state")
        candidate_kind="$tok"
      fi
      last_healthy_mark="$mark"
    fi

    # A round's stdout is byte-identical to poll's, watermark last, so a caller can consume watch
    # and poll the same way; the state is context, not the finding, so it goes to stderr.
    if [ "$POLLED_ON_N" -gt 0 ]; then
      watch_act "$pr" "$state"
      return 0
    fi
    watch_note_past "$pr"
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
      # The one exit that does not poll again first: the merge gate is open, and a round arriving
      # beside an approval is not what the caller is waiting for. (Findings do not make an
      # approval — status_state ranks the 👍 above them on purpose.)
      status_line "$state"
      echo "watermark: $mark"
      return 0
      ;;
    stalled)
      # Bounded patience on a LIVE 👀 as well: a round that never lands stalls the loop exactly as a
      # spent 👀 does, and the answer is the same — say so and let the caller nudge.
      watch_end "$pr" "$tok" ""
      return $?
      ;;
    failed)
      # Nothing is running and nothing will start on its own: the reviewer said it could not fetch
      # the head. Exiting here rather than falling into the `expected` arm below is the whole
      # point of the state — that arm would hold the window and then hold the grace out (three
      # times over, on ocannl-staging#677) before recommending the nudge this prints now.
      watch_end "$pr" "$tok" ""
      return $?
      ;;
    *)
      # A 👀 that stops being in flight without a review of the head is a round that ended with
      # nothing. Make it prove itself over two rounds, since one read can be a false negative — and
      # this is the fast path to the same verdict the grace below reaches on the clock alone.
      if [ "$was" = reviewing ] && [ "$tok" != reviewing ] && [ "$tok" != nudged ]; then
        quiet=$((quiet + 1))
        if [ "$quiet" -ge 2 ]; then
          watch_end "$pr" "$tok" "$(echo "the 👀 round on PR $REPO#$pr ended without a review of" \
            "the head commit — consider nudging with a '@codex review' comment")"
          return $?
        fi
      else
        quiet=0
        was="$tok"
      fi
      # The state this loop used to mistake for "reviewing". It is worth a bounded wait — the app
      # takes minutes to pick a push up — and then it is worth SAYING, because there is nothing on
      # the other end to wait for. The grace runs from the PR's clock, not the window's, so it is
      # reached in the second window rather than never.
      if { [ "$tok" = expected ] || [ "$tok" = nudged ]; } &&
        ! { [ "$was" = reviewing ] && [ "$quiet" -eq 1 ]; }; then
        case "$age" in
        '' | *[!0-9]*) ;;
        *)
          if [ "$age" -ge "$GRACE" ]; then
            watch_end "$pr" "$tok" "$(echo "no review materialized on PR $REPO#$pr in the" \
              "$(fmt_age "$age") since it became due — consider nudging with a '@codex review'" \
              "comment")"
            return $?
          fi
          ;;
        esac
      fi
      ;;
    esac

    pause="$interval"
    if [ $((SECONDS - start + interval)) -gt "$timeout" ]; then
      # A live round can outlast the ordinary quiet window. Freeze the extension's
      # deadline on its first use so changing reactions cannot renew it indefinitely.
      # Cache deadlines on healthy reads, including before the ordinary boundary.
      # Unknown reads retain that evidence; none can invent or renew a deadline.
      [ -n "$candidate_end" ] || break
      if [ -z "$extension_end" ]; then
        remaining=$((candidate_end - SECONDS))
        [ "$remaining" -gt 0 ] || break
        extension_end="$candidate_end"
        extension_kind="$candidate_kind"
        extension_mark="$mark"
        warn "extending watch for the live review or fresh nudge, at most ${remaining}s beyond this poll"
      fi
      # Pickup and execution are distinct phases: allow the first live review
      # its own eyes-start grace after a nudge. Once reviewing, never renew again.
      if [ "$extension_kind" = nudged ] && [ "$candidate_kind" = reviewing ]; then
        extension_end="$candidate_end"
        extension_kind=reviewing
        warn "review started after the nudge; handing off to its fixed live-review deadline"
      fi
      remaining=$((extension_end - SECONDS))
      [ "$remaining" -gt 0 ] || break
      [ "$pause" -le "$remaining" ] || pause="$remaining"
    fi
    sleep "$pause"
  done

  # The window is out, and the last thing it does is look once more: the round this watch exists
  # to catch can be seconds old when the loop breaks, and a "quiet window" reported over it costs
  # a whole re-arm (item 3 of ludics-lite#72).
  # A settle that did not answer falls through to the blind branch below, which already says the
  # tail of the window was not observed — the same fact, in the report that window is owed.
  watch_settle "$pr"
  if [ $? -eq 1 ]; then
    watch_act "$pr" "$(status_state "$pr")"
    return 0
  fi

  if [ "$(mark_of "$mark" 2)" -gt "$(mark_of "$last_healthy_mark" 2)" ]; then
    final_state=$(status_state "$pr")
    watch_preserve_unarmed_nudge "$last_healthy_mark" "$state" "$final_state"
  fi

  # A later request cannot renew this frozen window, but it must remain
  # eligible for the next observer. Keep comments after the extension checkpoint
  # pending conservatively; no extra feed read or per-request deadline is needed.
  if [ -n "$extension_mark" ] &&
    [ "$(mark_of "$mark" 2)" -gt "$(mark_of "$extension_mark" 2)" ]; then
    mark="$(mark_of "$mark" 1),$(mark_of "$extension_mark" 2),$(mark_of "$mark" 3)"
    warn "comments after the fixed grace began remain pending; re-arm to observe any newer request"
  fi

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
  elapsed="$timeout"
  [ -z "$extension_end" ] || elapsed=$((SECONDS - start))
  echo "$(watch_quiet_line "$elapsed"); status: $(status_line "$state")"
  echo "watermark: $mark"
  return 1
}

# Replies carry the automated-work marker so a human scanning the thread knows what wrote them.
# The comment-id argument of `reply` and `resolve` is the token poll RENDERS — `900` for an
# ordinary thread, `900+901+902` for a folded entry (see fold_inline) — so the caller pastes back
# what it read instead of re-deriving a list. Splits it into FOLD_IDS, space-joined, anchor first;
# refuses anything else, because the split is new and an id that silently stayed "900+901" would
# address no comment and come back as a 404 the caller would read as a missing thread.
FOLD_IDS=""
split_ids() { # <token> <command name, for the message>
  local id
  FOLD_IDS=""
  # The WHOLE token is matched against the grammar BEFORE anything is split off it, and checking
  # each piece afterwards is not the same thing: the split is an unquoted expansion, so it also
  # word-splits and GLOBS. A token carrying whitespace ("900 901") would arrive as two pieces a
  # per-piece numeric check accepts and be written to twice, and one carrying a glob character
  # ("*") would expand against the caller's working directory, where a numeric filename would
  # become a comment id this script then replies to and resolves (round 1 of #86). Digits and
  # single `+`, nothing else, so nothing that reaches the split can split or expand further.
  case "$1" in
  '' | *[!0-9+]* | *"++"* | "+"* | *"+")
    die "$2: '$1' is not a comment id — a comment id is digits, and several are joined by single" \
      "'+' as poll renders a folded entry (900+901+902)" ;;
  esac
  for id in ${1//+/ }; do
    # Repeats are dropped rather than refused: they cost a duplicate write, and the entry they
    # came from is one finding either way.
    case " $FOLD_IDS " in *" $id "*) continue ;; esac
    FOLD_IDS="$FOLD_IDS $id"
  done
}

# ids_from <space-joined ids> <first id to keep>: the tail of the list starting at that id, for a
# message that has to say which of a batch is still unanswered.
ids_from() {
  local id out="" seen=""
  for id in $1; do
    if [ -z "$seen" ] && [ "$id" != "$2" ]; then continue; fi
    seen=1
    out="$out $id"
  done
  printf '%s' "$out"
}

# ids_token <space-joined ids>: the same list as the TOKEN this command takes. A retry set is
# printed through this and never as the internal space-joined form, which is not something the
# caller can paste back (round 3 of ludics-lite#86).
ids_token() {
  local id out=""
  for id in $1; do
    if [ -z "$out" ]; then out="$id"; else out="$out+$id"; fi
  done
  printf '%s' "$out"
}

# Where a thread lives, from its first comment id alone — the anchor URL a `--anchor` retry points
# at, which no read is spent on because this is the html_url shape GitHub serves for a review
# comment (verified on this repository's own PRs).
thread_url() { # <pr> <comment-id>
  printf 'https://github.com/%s/pull/%s#discussion_r%s' "$REPO" "$1" "$2"
}

# One reply into one thread. Prints the reply's html_url and returns gh_retry's code; the CALLER
# composes the failure, because what a failure means depends on how far the batch got.
post_reply() { # <pr> <comment-id> <body>
  gh_retry write api -X POST "repos/$REPO/pulls/$1/comments/$2/replies" \
    -f body="$3

_🤖 Addressed by an automated coding agent_" --jq .html_url
}

# What a failed reply says, with the batch's progress in it. A reply is the one write here that
# cannot be repeated safely, so a refusal that said "nothing was posted" after the anchor had
# landed would invite a caller to post the same body twice.
#
# The progress turns on the CLASSIFICATION as much as on how far the batch got, and conflating
# the two is how the first cut of this printed a contradiction: an ambiguous first write (a 500,
# a dropped connection — a request that may well have been served) left `answered` empty, so the
# note said "nothing in this invocation was posted, so repeat it whole" directly under a sentence
# saying the reply may have landed (round 2 of #86). The retry set is stated instead of the
# instruction, because only for an ambiguous failure is it a question — and there it is stated as
# the question it is, with both answers.
reply_failed() { # <pr> <comment-id> <rc> <ids answered> <ids not answered, first> <anchor, or empty>
  local pr="$1" id="$2" rc="$3" answered="$4" rest="$5" anchor="$6" landed="" after retry keep
  after="${rest#" $id"}"
  # The retry set as something the caller can paste. Once the ANSWER is standing in a thread, the
  # retry must keep pointing at THAT thread: handing the suffix back plain would promote its first
  # id to anchor, post the composed body there a second time and point the rest at the copy
  # (round 3 of ludics-lite#86). `--anchor` is what says "the answer is already in that thread".
  keep=""
  [ -z "$anchor" ] || keep=" --anchor $anchor"
  retry="$(ids_token "$rest")$keep"
  [ -z "$answered" ] || landed="The replies to$answered DID land, so do not repeat those. "
  case "$rc" in
  # A gateway refusal is a request no backend ran (gh_retry's write policy is narrower than a
  # read's for exactly this reason), so comment $id got nothing and the retry set is exact.
  3) fail 3 "reply to comment $id on PR $REPO#$pr did not go through — the API refused it at the" \
    "gateway on all $API_ATTEMPTS attempts ($(gh_err_line)). ${landed}Nothing was posted for" \
    "comment $id, so retry with: $retry" ;;
  esac
  api_rejection "$(gh_err_line)" &&
    fail 1 "reply to comment $id on PR $REPO#$pr was REJECTED, not dropped: $(gh_err_line)." \
      "Retrying prints the same thing — check the comment id and the PR. ${landed}Comment $id got" \
      "nothing, so once the id is right, retry with: $retry"
  fail 3 "reply to comment $id on PR $REPO#$pr failed AMBIGUOUSLY: $(gh_err_line)." \
    "That is not a gateway refusal, so the reply MAY have landed and this script will not post it" \
    "twice. ${landed}Read comment $id's thread: retry with: $retry if the reply is not there;" \
    "${after:+retry with: $(ids_token "$after") --anchor ${anchor:-$id} if it is}" \
    "${after:-there is nothing else outstanding if it is}"
}

# One invocation answers a whole folded entry: the body goes to the ANCHOR (the first id), and
# each duplicate gets a one-line pointer to the anchor's reply. That is what makes a duplicate
# cheap — one composed answer instead of one per thread (ludics-lite#76).
#
# The duplicates get a pointer REPLY rather than a bare resolve because a thread closed with
# nothing in it reads, to the reviewer and to the next archaeologist, as a finding answered in
# silence — which is what this loop exists to prevent. It is one line, and it says where the
# answer is. `resolve` then closes each of them, taking the same token.
#
# Every reply's html_url is printed, one per line, in the order they were posted, so the caller
# can see which threads it actually reached.
cmd_reply() {
  local anchor="" args=() arg
  while [ $# -gt 0 ]; do
    case "$1" in
    --anchor)
      anchor="${2:-}"
      shift 2 || die "reply: --anchor takes the comment id of the thread the answer is already in"
      ;;
    --anchor=*)
      anchor="${1#--anchor=}"
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
    esac
  done
  set -- ${args[@]+"${args[@]}"}
  # Exactly three, checked rather than left to ${3:?...} — which exits 1, the code that means "the
  # fact does not hold", for what is an invocation error. And a body is a sentence: an unquoted one
  # arrives as several arguments, and the ${3:?} form would post its first word and drop the rest,
  # which reads as a posted reply (cmd_comment's trap, same remedy). With --anchor there is no
  # body at all: the answer is already written, and these threads are being pointed at it.
  local body=""
  if [ -n "$anchor" ]; then
    [ $# -eq 2 ] || die "usage: reply <pr> <comment-id>[+<comment-id>...] --anchor <comment-id> —" \
      "got $# positional argument(s). With --anchor the answer already stands in that thread," \
      "so no body is taken: every id in the token is pointed at it."
    case "$anchor" in '' | *[!0-9]*) die "reply: --anchor takes one comment id, got '$anchor'" ;; esac
  else
    [ $# -eq 3 ] || die "usage: reply <pr> <comment-id>[+<comment-id>...] <body> — got $# argument(s)." \
      "The body is ONE argument: quote it, including a multi-line one."
    body="$3"
    [ -n "${body//[[:space:]]/}" ] || die "reply: the body is empty; there is nothing to post"
  fi
  local pr="$1" ids="$2"
  pr_arg "$pr"
  pr="$PR_NUM"
  split_ids "$ids" reply
  local id anchor_url="" answered="" url rc
  if [ -n "$anchor" ]; then
    case " $FOLD_IDS " in *" $anchor "*)
      die "reply: --anchor $anchor is also in the token '$ids' — a thread cannot be pointed at" \
        "itself; name the threads that still need the pointer" ;;
    esac
    anchor_url=$(thread_url "$pr" "$anchor")
  fi
  for id in $FOLD_IDS; do
    if [ -z "$anchor" ]; then
      url=$(post_reply "$pr" "$id" "$body")
    else
      url=$(post_reply "$pr" "$id" \
        "Duplicate of the thread answered at ${anchor_url:-comment $anchor} — see there.")
    fi
    rc=$?
    [ "$rc" -eq 0 ] ||
      reply_failed "$pr" "$id" "$rc" "$answered" "$(ids_from "$FOLD_IDS" "$id")" "$anchor"
    [ -z "$url" ] || printf '%s\n' "$url"
    if [ -z "$anchor" ]; then
      anchor="$id"
      anchor_url="$url"
    fi
    answered="$answered $id"
  done
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

_🤖 Addressed by an automated coding agent_" --jq .html_url
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

# One thread, closed. <label> is nonempty when the invocation carries several ids, and then each
# answer is prefixed with the id it is about — with one id the output stays what it always was,
# a bare `true`. <done> is the ids already closed by this invocation, named in every refusal so a
# caller knows where it stopped; resolving is idempotent, so the whole token can simply be
# repeated. Refusals exit the process (`fail`), which is why this is called directly and never
# from a command substitution.
resolve_one() { # <pr> <comment-id> <label prefix, empty for none> <ids already resolved>
  local pr="$1" id="$2" label="$3" done_ids="$4" hit rc out progress=""
  [ -z "$done_ids" ] || progress=" Already resolved in this invocation:$done_ids — resolving is
idempotent, so the whole token is safe to repeat."
  hit=$(find_thread "$pr" "$id")
  rc=$?
  case "$rc" in
  0) ;;
  2) fail 3 "GraphQL did not answer for PR $REPO#$pr after $API_ATTEMPTS attempts per page" \
    "($(gh_err_line)) — thread resolution has no REST equivalent, so this is a RETRY, not a" \
    "missing thread: the threads are probably all there, and the reply (REST) may well have gone" \
    "through. Do NOT read this as someone else having resolved it or as a wrong comment id.$progress" ;;
  4) fail 2 "GraphQL REJECTED the thread lookup for PR $REPO#$pr: $(gh_err_line)." \
    "The search never ran, so this says nothing about comment $id — check the repo, the PR" \
    "number and \`gh auth status\` rather than the comment id.$progress" ;;
  *) fail 1 "no review thread starts at comment $id — every page of PR $REPO#$pr was read and" \
    "none of them begins there (this is a real answer, not a dropped request)$progress" ;;
  esac
  # Already-resolved is the goal state, not a no-op worth an API write: replying then resolving a
  # thread twice across rounds is normal, and the mutation would just echo it back.
  case "$hit" in
  *" true")
    printf '%s\n' "${label:+$id }true (already resolved)"
    return 0
    ;;
  esac
  # The mutation is idempotent — resolving a resolved thread just answers true — so it is retried
  # like a read, on anything short of the API rejecting it.
  out=$(gh_retry read api graphql -f query="mutation {
      resolveReviewThread(input:{threadId:\"${hit%% *}\"}) {
      thread { isResolved } } }" --jq .data.resolveReviewThread.thread.isResolved)
  case "$?" in
  0)
    printf '%s\n' "${label:+$id }$out"
    return 0
    ;;
  3) fail 3 "resolveReviewThread did not answer for the thread at comment $id on PR $REPO#$pr" \
    "after $API_ATTEMPTS attempts ($(gh_err_line)); the thread was FOUND, so this is transport" \
    "only — retry when the API recovers, and the mutation is safe to repeat.$progress" ;;
  *) fail 1 "resolveReviewThread was rejected for the thread at comment $id on PR $REPO#$pr:" \
    "$(gh_err_line)$progress" ;;
  esac
}

# `resolve` takes the same token `reply` does, so a folded entry is closed by one invocation too:
# every thread the entry lists, in order, each answered on its own line. Unlike a reply, this is
# safe to repeat whole — the mutation is idempotent and an already-resolved thread costs no write.
cmd_resolve() {
  [ $# -eq 2 ] || die "usage: resolve <pr> <comment-id>[+<comment-id>...] — got $# argument(s)"
  local pr="$1" ids="$2"
  pr_arg "$pr"
  pr="$PR_NUM"
  split_ids "$ids" resolve
  local id resolved="" label=""
  case "$FOLD_IDS" in *" "*" "*) label=1 ;; esac
  for id in $FOLD_IDS; do
    resolve_one "$pr" "$id" "$label" "$resolved"
    resolved="$resolved $id"
  done
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
# The run is addressed the way a PR is — owner/name#<run-id>, through the same parse_ref — and the
# repo is NEVER inferred from the cwd (ludics-lite#74) — nor, since ludics-lite#92, is any
# other subcommand's. It used to be, and the inference is a
# false-verdict generator on exactly the invocation this await exists for: a worker whose
# background shell had started in an ocannl-staging worktree awaited a ludics-lite run id, the
# read 404'd against the repo the cwd named, and the await returned exit 1 over a run that was
# fine — a red gate manufactured out of a wrong-target invocation. A cwd mismatch has to be an
# INVOCATION error, so an unnamed repo is refused (exit 2) rather than guessed, and a named pair
# the API says does not exist is one too (below) rather than a verdict about the run.
#
# Exit codes, matching `checks`: 0 the run succeeded; 1 it concluded failure — a VERDICT, so do
# not retry the watch, read the run; 2 the invocation is wrong (no repo named, a malformed run
# argument, or a run/repo pair the API rejects); 3 the API did not answer, so the run's state is
# UNKNOWN; 4 no verdict — still running at the deadline, or stopped without being judged.
cmd_run_watch() {
  local run_ref="" run_id="" repo="" flag_repo="" interval="$CHECKS_INTERVAL"
  local line rc status concl sleep_for remaining
  while [ $# -gt 0 ]; do
    case "$1" in
    -R | --repo)
      flag_repo="${2:?$1 needs owner/name}"
      shift
      ;;
    -R=* | --repo=*) flag_repo="${1#*=}" ;;
    -i | --interval)
      interval="${2:?$1 needs seconds}"
      shift
      ;;
    -i=* | --interval=*) interval="${1#*=}" ;;
    # The two native flags whose meaning this await subsumes are accepted as no-ops so a pasted
    # `gh run watch` line keeps working; everything ELSE dies loudly. A catch-all that discards
    # an argument turns a mistyped repo flag into a watch against whatever REPO resolves to —
    # the wrong-target failure the strict parse_ref parse exists to prevent.
    --exit-status | --compact) ;;
    -*) die "run watch: unsupported flag '$1' — the quiet await takes owner/name#<run-id>," \
      "-R/--repo, -i/--interval, --exit-status, --compact" ;;
    *)
      [ -z "$run_ref" ] || die "run watch: got two run arguments ('$run_ref' and '$1') —" \
        "name exactly one"
      run_ref="$1"
      ;;
    esac
    shift
  done
  [ -n "$run_ref" ] || die "retry run watch: name the run as owner/name#<run-id> — the quiet" \
    "await polls \`gh run view <id> --repo <owner/name>\`. For a PR's checks, prefer" \
    "\`checks <pr> --wait\`."
  parse_ref "$run_ref" || die "run watch: the run must be owner/name#<run-id> (or a bare run id" \
    "with -R owner/name), got '$run_ref'"
  run_id="$REF_NUM"
  case "$interval" in '' | *[!0-9]*) die "run watch: the interval must be seconds, got '$interval'" ;; esac
  # `gh run watch` documents -i as seconds and defaults to 3; 0 would turn the quiet await into a
  # rate-limit-burning busy loop of API reads for up to the full two-hour ceiling.
  [ "$interval" -gt 0 ] || die "run watch: the interval must be at least 1 second, got '$interval'"
  # Two spellings that BOTH name a target and disagree are an invocation error, not a precedence
  # puzzle: silently preferring either is how a run gets awaited in the repo the caller did not
  # mean, which is the whole failure this argument form removes. REPO= is a session default rather
  # than a second target, so a spelled-out argument overrides it the way it does for a PR.
  repo="$REF_REPO"
  [ -z "$repo" ] || [ -z "$flag_repo" ] || [ "$repo" = "$flag_repo" ] ||
    die "run watch: the run names $repo and -R/--repo names $flag_repo — two explicit targets" \
      "that disagree; name the repo once."
  [ -n "$repo" ] || repo="$flag_repo"
  [ -n "$repo" ] || repo="$REPO"
  [ -n "$repo" ] || die "run watch: name the repo — owner/name#$run_id (preferred), or a bare" \
    "run id with -R owner/name or REPO=owner/name. A bare id alone is refused and NOT resolved" \
    "from the cwd: this await is a background call by construction, a background shell does not" \
    "start in the checkout, and guessing turned a wrong-target read into a FAILED run" \
    "(ludics-lite#74)."
  local started deadline beat now
  started=$(date +%s)
  deadline=$((started + CHECKS_WAIT))
  beat=$started
  while :; do
    line=$(gh_retry read run view "$run_id" --repo "$repo" --json status,conclusion \
      --jq '[.status, (.conclusion // "pending")] | @tsv')
    rc=$?
    if [ "$rc" -ne 0 ]; then
      # A 4xx is the API saying THIS PAIR does not exist (or is not visible), which is a fact
      # about the invocation and not about the run: exit 2, never the 1 that reads as a failed
      # run. That conflation is the second half of ludics-lite#74 — the 404 the cwd inference
      # earned came back as a red gate — and it survives the inference's removal, since a
      # mistyped -R produces the same 404.
      api_rejection "$(gh_err_line)" &&
        die "run watch: $repo has no run $run_id readable here: $(gh_err_line). That is the" \
          "API answering about the id and the repo you named — nothing about the run's outcome," \
          "so it is not a failure. Check both, then re-run the await."
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
# Named for `base --wait`, which asked the question first, but the question is not the base's: how
# long a push may go without a run before absence becomes a fact. The checks gate asks it too
# (see absent_signal), so the shell variable drops the prefix and the ENV name keeps it — nobody's
# scripts should have to be edited for a widened meaning.
ABSENT_GRACE="${SHIP_PR_BASE_ABSENT_GRACE:-300}"
# Whole seconds, validated up front: these feed shell arithmetic (deadlines, heartbeats, and the
# sleep caps against the remaining deadline), where a fractional value does not degrade gracefully
# — `[ 0.5 -le N ]` errors and takes the fallback arm, which for the interval means one read and
# then a sleep to the full ceiling. A zero interval would busy-loop the API instead of pacing it.
case "$ABSENT_GRACE" in
'' | *[!0-9]*) die "SHIP_PR_BASE_ABSENT_GRACE must be a number of seconds, got '$ABSENT_GRACE'" ;;
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

# Orders run rows NEWEST FIRST, on (created_at desc, id desc): rows on stdin, the two columns that
# hold those fields named as arguments, since the two feeds of workflow runs project them at
# different offsets. run_signal has ordered its head's feed this way since ludics-lite#83, cmd_base
# its page per workflow since ludics-lite#90.
#
# The rows are ORDERED HERE, not taken as a feed served them. A feed does come back newest-first by
# `created_at` — a belief the contract still pins, for the reasons each caller notes — but rows
# created in the SAME SECOND have no order the API documents or the fixtures could encode, and
# every reader downstream keeps whichever of them it sees first. Two runs a second apart are a
# re-run or a double dispatch, and which one is "the newest" then decided the verdict by luck.
# (created_at desc, id desc) settles it: the later second still wins, and a tie inside a second
# goes to the higher run id, which is the later allocation. That is a total order over the rows, so
# no reader's answer depends on the order a feed happened to serve. A row whose `created_at` moved
# or vanished sorts LAST ("-" is below every digit under LC_ALL=C, and the key is reversed), so a
# shape drift loses to a well-formed row rather than silently winning its key.
newest_first() { # <created_at column> <id column>; rows on stdin
  LC_ALL=C sort -t$'\t' -k"$1,$1"r -k"$2,$2"nr
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
  local class name concl url red=0 pending=0 nogo=0 green=0 passed=0
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
    *)
      green=$((green + 1))
      # `skipped` and `neutral` are green for the ordinary gate (nothing failed) but they are not
      # a build that RAN; --require-green wants at least one of these.
      [ "$concl" = success ] && passed=$((passed + 1))
      ;;
    esac
  done <<<"$1"
  CHECK_RED="$red"
  CHECK_PASSED="$passed"
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

# The check-run list is not the whole build signal, and after a push it is not even a complete
# view of itself. ABSENT was two facts wearing one word — "no workflow covers this commit" (path
# filters: ocannl's `ci` ignores `docs/**`) and "the checks of the run for this commit DO NOT EXIST
# YET" — and the second one used to leave the gate as exit 0 while `actions/runs` for that same
# head already said `in_progress` (ludics-lite#24). That is the shape a merge is armed on and
# reads nothing: ocannl-staging#491 merged exactly that way.
#
# The same gap has three more mouths, all found reviewing the fix (ludics-lite#38, round 2), and
# they are one defect: the check list can be EMPTY, PARTIAL, or SILENT about a run that never got
# as far as a job.
#   - a workflow that fails before its jobs start (a broken workflow file — `startup_failure` —
#     or a `failure`/`timed_out` at the run level) leaves NO check run to be red;
#   - a run cancelled while still queued reports `completed` with nothing behind it, and stopped
#     is not judged anywhere else in this file (see conclusion_class, cmd_base's nogo_at_tip);
#   - one workflow's green check says nothing about a SIBLING workflow whose run is still queued
#     and has yet to create its own — a green verdict over an unjudged build.
# So the head's RUN list is read whenever the check fold says there is nothing left to wait for
# (green or absent), and it can overrule that reading. `actions/runs?head_sha=` is the right feed
# for it: a run row exists from the moment the run is queued, before any of its check-runs, and it
# carries the run-level conclusion the check list cannot. Paginated, because a head with a long
# re-run history can push a queued run off the first page.
#
# Prints "<red count><TAB><reason>" — a count, because gate_checks reports through CHECK_RED and a
# command substitution cannot hand it back a variable — and returns
#   1  RED at the run level: a non-advisory run for this head concluded red with no check behind
#      it. A red is a verdict, so it ends a --wait like any other.
#   4  no verdict YET — a run is queued or in flight, a run completed stopped-not-judged, or the
#      head has no checks at all and is inside the run-creation grace. Under --wait, keep waiting;
#      without one, 4 is still the honest answer, and it is what makes `merge` refuse.
#   0  the check fold's own reading stands: every run for the head finished and was judged.
#   3  the runs or the clock could not be read — UNKNOWN, which is not "nothing is red".
#
# The run-creation grace applies to every CHECKLESS head, not only to one with no run row at all:
# one finished run is evidence about one workflow, and a repo where A completes with every job
# skipped while B's row has not appeared would otherwise read as settled absence in the middle of
# the creation race. It is deliberately NOT applied when the head has checks: run rows for one
# event are created together, so a head showing any check has had its rows created, and holding
# every fresh green head for five minutes would buy nothing. The alternative — diffing the run
# list against `actions/workflows` — buys precision this gate cannot use, since a dispatch- or
# schedule-only workflow is permanently "missing" and would park every absence on the full grace.
#
# Advisory names are filtered here as everywhere else, and for the same reason in both directions:
# the review app's own check must not hold a wait open, and a repo whose only in-flight run is
# advisory has no build signal coming. A run's `.name` is the workflow's name unless the workflow
# sets `run-name:`, in which case a custom name can miss the advisory ERE — that only costs a hold
# for a run whose verdict would have been ignored, which is the safe direction to be wrong in.
# printf reuses its format string for every argument, so "%s" over a fragmented message is the
# concatenation the reason lines want — but the leading red count must be emitted ONCE, or every
# fragment carries a copy of it (caught by the fixture suite the moment the messages grew a second
# fragment). One printf for the count, one for the message.
run_reason() {
  local n="$1"
  shift
  printf '%s\t' "$n"
  printf '%s' "$@"
}

# A workflow run's aggregate conclusion is not always a build verdict. The advisory list is a
# deny-list of CHECK names (SHIP_PR_ADVISORY_CHECKS), and build_checks applies it per check run —
# so a non-advisory workflow carrying one advisory JOB reports `failure` at the run level when
# only that job failed, and reading the run's red would restore a failure the gate was configured
# to ignore (ludics-lite#38, round 4). The run's own jobs settle it: true when the run has jobs
# and none of the non-advisory ones is red, i.e. its red is entirely explained by jobs the gate
# ignores. A run with NO jobs (the `startup_failure` case this red branch exists for) is not
# explained, and neither is a jobs read that failed — a red this cannot disprove stands.
run_red_is_advisory_only() {
  local id="$1" raw rc jname jconcl jobs=0 hard=0
  raw=$(gh_retry read api --paginate "repos/$REPO/actions/runs/$id/jobs?per_page=100" \
    --jq '.jobs[] | [(.name // "-"), (.conclusion // "pending")] | @tsv')
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  while IFS=$'\t' read -r jname jconcl; do
    [ -n "$jname" ] || continue
    jobs=$((jobs + 1))
    is_advisory "$jname" && continue
    [ "$(conclusion_class "$jconcl")" = red ] && hard=$((hard + 1))
  done <<<"$raw"
  [ "$jobs" -gt 0 ] && [ "$hard" -eq 0 ]
}

run_signal() {
  local sha="$1" pr_at="${2:-}" checks="${3:-0}" base_sha="${4:-}" head_ref="${5:-}"
  local raw rc rid wid event name status concl
  local seen_ids=" " red_rows="" rname rconcl created
  local runs=0 inflight=0 nogo=0 red=0 red_note="" pushed_at age seen
  raw=$(gh_retry read api --paginate \
    "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" \
    --jq '.workflow_runs[] | [(.created_at // "-"), ((.id // 0) | tostring),
          ((.workflow_id // 0) | tostring),
          (.event // "-"), (.name // "-"), (.status // "unknown"), (.conclusion // "pending")]
          | @tsv')
  rc=$?
  [ "$rc" -eq 0 ] || {
    run_reason 0 "the workflow runs for this head could not be read ($(gh_err_line))"
    return 3
  }
  # Ordered before the fold (see newest_first): two runs of one workflow-and-event key created in
  # the same second are a re-run or a double dispatch, and the fold below would otherwise keep
  # whichever of them it saw first. The sort is here rather than inside the `--jq` filter so that
  # it spans the pages — gh applies that filter per page. The feed's own newest-first order is
  # still a belief the contract pins, because this endpoint is read unpaged at `per_page=100` and
  # an order that moved would change WHICH runs a head's page carries; no fold here rests on it.
  raw=$(newest_first 1 2 <<<"$raw")
  # One row per INVOCATION, the newest — the same `filter=latest` semantics build_checks asks the
  # check API for, and for the same reason: a head can carry several runs of one workflow (a
  # queued invocation cancelled, then a fresh one that passed), and the superseded row's
  # conclusion is not the current answer. Without this an old cancelled row parks the gate at 4
  # forever and an old checkless failure holds it RED over a workflow that has since gone green
  # (ludics-lite#38, round 3). After the sort above, the first row seen for a key is the one that
  # counts.
  #
  # The key is workflow id AND event, not the workflow id alone. The id half is there for the
  # reason cmd_base's per-workflow projection sets out: a display name does not identify a
  # workflow FILE. The event half is this feed's own: ONE file triggered on both `push` and
  # `pull_request` produces two INDEPENDENT runs at the same head that share a workflow id —
  # collapsing those hides a queued invocation behind a newer one that finished (round 4).
  # cmd_base keys on the id alone because it queries a single event; this feed is every event at
  # a head.
  #
  # And the fold only ever collapses COMPLETED rows. No key identifies an invocation — two manual
  # dispatches of one workflow at one head share workflow id and event and are independent work
  # (round 5) — but supersession is something that happens to a run that STOPPED: a queued or
  # running row has not been superseded by anything, so it is counted, never folded away. That is
  # what reconciles round 3's ask (a cancelled predecessor must not park the gate) with round 5's
  # (a queued sibling must not hide behind a finished one) without an identity the API does not
  # give: unfinished work is always work, and only finished rows compete to be the answer.
  # `created` is read to consume the sort key's column and nothing else: the ordering above is
  # the only thing this projection needs a timestamp for.
  while IFS=$'\t' read -r created rid wid event name status concl; do
    [ -n "$rid" ] || continue
    is_advisory "$name" && continue
    # A run reported `completed` before its conclusion is populated is not judged either: the
    # projection renders that null as `pending`, which is neither red nor stopped, and counting it
    # as finished-and-judged would let a green check — or, on a checkless head, the eventual
    # ABSENT — carry a workflow that has concluded nothing (round 4).
    if [ "$status" != completed ] || [ "$(conclusion_class "$concl")" = pending ]; then
      runs=$((runs + 1))
      inflight=$((inflight + 1))
      continue
    fi
    case "$seen_ids" in *" $wid/$event "*) continue ;; esac
    seen_ids="$seen_ids$wid/$event "
    runs=$((runs + 1))
    case "$(conclusion_class "$concl")" in
    red) red_rows="${red_rows}${rid}"$'\t'"${name}"$'\t'"${concl}"$'\n' ;;
    nogo) nogo=$((nogo + 1)) ;;
    esac
  done <<<"$raw"
  # Each red run gets the advisory-job read before it counts — one call, only ever for a run that
  # is already red, and only when no check run reported that failure.
  if [ -n "$red_rows" ]; then
    while IFS=$'\t' read -r rid rname rconcl; do
      [ -n "$rid" ] || continue
      run_red_is_advisory_only "$rid" && continue
      red=$((red + 1))
      [ -n "$red_note" ] || red_note="$rname ($rconcl)"
    done <<<"$red_rows"
  fi
  # Red first: it is a verdict, and a verdict ends the wait. Reaching here at all means the check
  # fold found no red, so this run's failure is one no check run reported — the whole reason to
  # look at the run list rather than trusting the check list to carry every failure.
  if [ "$red" -gt 0 ]; then
    run_reason "$red" "$red workflow run(s) for this head concluded red with no build check" \
      " to show for it — $red_note; a run that fails before its jobs start leaves nothing in the" \
      " check list"
    return 1
  fi
  if [ "$inflight" -gt 0 ]; then
    run_reason 0 "$inflight workflow run(s) for this head have no conclusion yet (queued," \
      " running, or completed with none recorded) — their check runs may not exist yet"
    return 4
  fi
  if [ "$nogo" -gt 0 ]; then
    run_reason 0 "$nogo workflow run(s) for this head completed stopped-not-judged (cancelled," \
      " stale or action_required) with no build check behind them — stopped is not absence and" \
      " not a verdict: re-run the workflow"
    return 4
  fi
  # Every run for this head is finished and judged. With checks in hand AND at least one Actions
  # run behind them, the fold above has read the signal and its verdict stands — run rows for one
  # event are created together, so a head showing a run has had its rows created, and holding
  # every fresh green head for the grace would buy nothing. Checks from a NON-Actions provider
  # prove nothing about that (build_checks deliberately accepts every provider's check runs), so
  # an early Codecov green over an empty run list falls through to the grace like any other
  # checkless head (ludics-lite#38, round 3).
  case "$checks" in '' | *[!0-9]*) checks=0 ;; esac
  if [ "$checks" -gt 0 ] && [ "$runs" -gt 0 ]; then
    run_reason 0 "$runs workflow run(s) for this head are finished and judged"
    return 0
  fi
  # Checkless: how long there has been to create a run. Two clocks, and the FRESHER wins, because
  # each covers the other's blind spot. The head's committer date is the push clock the rest of
  # this file uses (pr_state's review clock): a rebase, an amend and a cherry-pick all refresh it,
  # which covers every way a PR head moves — but not a commit that sat locally for hours before
  # its first push, where it is already older than any grace and would settle the absence on the
  # spot. The PR's own `updated_at` covers exactly that: a push to the head branch updates the PR,
  # so it is never OLDER than the push, whatever the commit's date says (measured live on
  # ludics-lite#38: 09:12:31Z before a push of an older commit series, 09:17:29Z five seconds
  # after). It can be fresher than the push — a comment moves it too — and that costs at most one
  # grace of holding after unrelated PR activity, the safe direction for a merge gate.
  pushed_at=$(gh_retry read api "repos/$REPO/commits/$sha" --jq .commit.committer.date) ||
    pushed_at=""
  # Each clock validated on its OWN, then the freshest of what survives — not `newest` over the
  # raw timestamps. A committer date in the FUTURE (clock skew, or an explicit GIT_COMMITTER_DATE)
  # is the newest string there is, and age_of answers a negative age with "-", so picking it would
  # throw away a perfectly good PR clock and leave the gate UNKNOWN until wall time caught up —
  # for hours, on a path-filtered PR that has no other way past this branch (round 3). That is
  # freshest_age, which the review clock in status_state needs for the same reason.
  age=$(freshest_age "$pushed_at" "$pr_at")
  if [ "$age" = - ]; then
    run_reason 0 "no usable clock for this head: neither its commit date nor the PR's updated_at" \
      " could be read ($(gh_err_line)), or both are in the future, so the run-creation window" \
      " is unknown"
    return 3
  fi
  if [ "$runs" -gt 0 ]; then
    seen="$runs workflow run(s) for this head finished and left no build check behind"
  else
    seen="no workflow run exists for this head"
  fi
  # Inside the grace the clock alone cannot tell "never coming" from "not yet" — but for a head
  # with NO run at all the workflows' own filters can, and this is the only window where that
  # answer changes anything: past the grace the absence is already the verdict, and a head that
  # DID get a run is never asked, since a run existed and no filter explains its silence
  # (ludics-lite#176). The refusal costs exactly what it cost before: this grace.
  if [ "$runs" -eq 0 ] && [ "$age" -lt "$ABSENT_GRACE" ] &&
    head_within_paths_ignore "$sha" "$base_sha" "$head_ref"; then
    run_reason 0 "no workflow run exists for this head, and none can be created by" \
      " $PATHS_IGNORE_WHY: every trigger of theirs that this change fires is either filtered" \
      " out by its own paths-ignore — every commit from the merge base up changes only ignored" \
      " paths — or cannot reach this branch at all"
    return 0
  fi
  if [ "$age" -lt "$ABSENT_GRACE" ]; then
    run_reason 0 "$seen, and the head has been in place at most $(fmt_age "$age") — inside the" \
      " $(fmt_age "$ABSENT_GRACE") run-creation grace (SHIP_PR_BASE_ABSENT_GRACE), so a run" \
      " may still appear"
    return 4
  fi
  run_reason 0 "$seen in the $(fmt_age "$age") since it appeared — past the" \
    " $(fmt_age "$ABSENT_GRACE") run-creation grace"
  return 0
}

# Reads the PR's head SHA and judges its build signal, from the check runs AND — whenever those
# leave nothing to wait for — the head's workflow runs. Sets VERDICT and prints the report.
# 0 = green, or an absence run_signal confirmed is the verdict (nothing is red), 1 = RED (a check
# or a checkless run), 3 = the API did not answer, 4 = no verdict yet (still running, stopped
# without a verdict, or a run for this head has yet to produce its checks), 5 = superseded head.
gate_checks() {
  local pr="$1" wait_for="${2:-0}" sha lines rc deadline started beat now sleep_for remaining
  local run_why="" run_info note pr_at="" base_sha="" head_ref="" current_sha
  # One read for both: the head to judge, and the PR's own last-updated stamp, which run_signal
  # uses as the push clock a stale committer date cannot provide. Tab-separated with a placeholder
  # for the same reason build_checks uses one — an empty field would collapse under tab-IFS.
  # Captured first, then split: a process substitution would hand `read` the exit status and lose
  # gh_retry's, and a failed read that reports 0 is the one thing this gate must never do.
  # The PR's base SHA rides along for the same reason `updated_at` does: it costs no extra call,
  # and run_signal needs it to ask whether a run for a run-less head can be created at all — the
  # range it walks starts at this head's merge base with the base branch (ludics-lite#176).
  lines=$(gh_retry read api "repos/$REPO/pulls/$pr" \
    --jq '[.head.sha, (.updated_at // "-"), (.base.sha // "-"), (.head.ref // "-")] | @tsv')
  rc=$?
  IFS=$'\t' read -r sha pr_at base_sha head_ref <<<"$lines"
  [ "${pr_at:--}" != - ] || pr_at=""
  [ "${base_sha:--}" != - ] || base_sha=""
  [ "${head_ref:--}" != - ] || head_ref=""
  if [ "$rc" -ne 0 ] || [ -z "$sha" ]; then
    VERDICT=unknown
    warn "could not read $REPO#$pr's head SHA ($(gh_err_line)); the build signal is UNKNOWN," \
      "which is NOT 'nothing is red'."
    return 3
  fi
  CHECK_SHA="$sha" # what the verdict is ABOUT; merge binds to it
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
    # Every fold but a red one gets the run list's deciding read. Green can be green over a
    # sibling that has not judged the head; an absence can be a run whose checks do not exist yet;
    # and a PENDING or MIXED fold can be sitting on a sibling that already concluded red without
    # producing a check — where reporting 4 lets `--allow-no-verdict` merge a failed head without
    # ever facing the red-build --override, and makes --wait sit out the other check before
    # finding out (ludics-lite#38, round 3). Only a red fold is skipped: it is already the
    # strongest verdict, and a second read cannot add to it. This happens with no --wait too,
    # where the honest answer to "is there a signal here" is 4, not a 0 the merge gate would take
    # for "nothing is red".
    if [ "$VERDICT" != red ]; then
      run_info=$(run_signal "$sha" "$pr_at" "$CHECK_TOTAL" "$base_sha" "$head_ref")
      rc=$?
      run_why="${run_info#*$'\t'}"
      case "$rc" in
      1)
        VERDICT=runred
        CHECK_RED="${run_info%%$'\t'*}"
        ;;
      3)
        # UNKNOWN even over a pending fold, which would otherwise be an honest 4 on its own: an
        # unread run list cannot rule out a red that no check run will ever carry, and this file
        # does not report a signal it failed to read as a milder one.
        VERDICT=unknown
        warn "could not read the workflow runs of $REPO#$pr @${sha:0:8} ($run_why); the checks" \
          "alone are not the build signal, so this is UNKNOWN, which is NOT 'nothing is red'."
        return 3
        ;;
      # Every fold the run list leaves unjudged becomes waitable, MIXED included: a stopped check
      # under a queued run used to break the loop at once, so `--wait` returned without waiting
      # for the run that was still coming (round 4). The stopped checks stay in the report below.
      4) case "$VERDICT" in pending) ;; *) VERDICT=unjudged ;; esac ;;
      esac
    fi
    # Revalidate every observation, including a terminal green or stopped old head. This
    # never follows the successor: the checks and merge binding remain about the original SHA.
    current_sha=$(gh_retry read api "repos/$REPO/pulls/$pr" --jq \
      '.head.sha | select(type == "string" and length > 0)')
    rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$current_sha" ] || [ "$current_sha" = null ]; then
      VERDICT=unknown
      warn "could not re-read $REPO#$pr's head SHA; the build signal is UNKNOWN."
      return 3
    fi
    if [ "$current_sha" != "$sha" ]; then
      VERDICT=superseded
      echo "build signal $REPO#$pr: SUPERSEDED — observed $sha, current $current_sha; re-run for the new head"
      return 5
    fi
    now=$(date +%s)
    case "$VERDICT" in pending | unjudged) ;; *) break ;; esac
    [ "$now" -lt "$deadline" ] || break
    # One line per heartbeat, not per re-read: a two-hour wait is 120 re-reads, and a background
    # child that prints that much is as unreadable as one that prints nothing.
    if [ $((now - beat)) -ge "$CHECKS_HEARTBEAT" ]; then
      case "$VERDICT" in
      unjudged) note="$run_why" ;;
      *) note="$CHECK_PENDING check(s) running" ;;
      esac
      warn "still waiting on $REPO#$pr @${sha:0:8}: no verdict after $(((now - started) / 60)) of" \
        "$((wait_for / 60)) min ($note)"
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
  # A head whose checks were green but whose run list is not done is still reported as no verdict
  # — with what DID pass, so the line is not read as "nothing has run".
  note=""
  [ "${CHECK_GREEN:-0}" -gt 0 ] && note=" ($CHECK_GREEN build check(s) have passed so far)"
  case "$VERDICT" in
  red) echo "build signal $REPO#$pr @${sha:0:8}: RED — $CHECK_RED of $CHECK_TOTAL build checks failed" ;;
  pending) echo "build signal $REPO#$pr @${sha:0:8}: NO VERDICT YET — still running" ;;
  mixed) echo "build signal $REPO#$pr @${sha:0:8}: INCOMPLETE — $CHECK_GREEN passed, the rest were stopped without a verdict" ;;
  runred) echo "build signal $REPO#$pr @${sha:0:8}: RED — $run_why" ;;
  unjudged) echo "build signal $REPO#$pr @${sha:0:8}: NO VERDICT YET — $run_why$note" ;;
  absent) echo "build signal $REPO#$pr @${sha:0:8}: ABSENT — no build check ran on this commit: $run_why" ;;
  green) echo "build signal $REPO#$pr @${sha:0:8}: green — $CHECK_GREEN build checks passed" ;;
  esac
  [ -n "$CHECK_LINES" ] && printf '%s' "$CHECK_LINES"
  case "$VERDICT" in
  red | runred) return 1 ;;
  pending | mixed | unjudged) return 4 ;;
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
# path overlaps in the same region (a path both sides changed in disjoint hunks is listed quietly).
# Returns 0 fresh enough with no such overlap, 1 for either warning, 3 when the count or overlap is
# unknown. For one day (2026-08-29) the merge path treated 1 as a GATE; the
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
# The old-side hunk ranges of each file's patch, keyed by path, from one compare response. Both
# compares below share their merge base, so a forward hunk's `-start,len` and a reverse hunk's
# `-start,len` are ranges of the SAME text (the merge base), and two paths both sides changed can
# be told apart by whether those ranges meet: an appended stanza against an appended stanza forty
# lines up is a different fact from two edits of one paragraph (ludics-lite#54: the wave PRs each
# append a test stanza to `test/operations/dune`, so the path overlapped for nearly every one of
# them while none touched a sibling's lines). A pure insertion (`-N,0`) sits between lines N and
# N+1 and is taken as touching both; adjacent ranges count as meeting, since git merges them
# cleanly and a reader still wants to look. A file without a `patch` (GitHub omits it for binary
# files and past a size cap) yields null, which the caller reads as "hunks unread" — never as
# disjoint.
# A patch is read hunk by hunk against its own headers: every `@@ -s,n +t,m @@` must be followed
# by exactly n old-side and m new-side lines before the next header or the end, and the patch's
# added and removed line totals must equal the entry's own `additions` and `deletions` counts,
# which GitHub computes from the whole diff. The first catches a patch cut inside a hunk; the
# second catches one cut between hunks, where every retained hunk is complete and only the count
# says a later one is missing. Either shortfall yields null like a missing patch — unread, never
# disjoint (Codex P2s on #63).
# The header is matched ONCE — `[capture(...)] | first`, bound and tested for null — and never as
# a `test` guarding a second, near-identical `capture`. A capture that does not match yields NO
# output rather than null, and a zero-output sub-expression inside this reduce takes the whole
# accumulator with it: the fold's result is null, so every hunk of that file, including the ones
# already read, vanishes and the path reads as "hunks unread" — the split above would then report
# what an unread patch reports for a patch it in fact read. Two patterns that must agree on every
# `@@` shape are a standing invitation to that drift; #84 fixed three sibling sites of the same
# trap.
compare_hunks() {
  jq -c '
    def ranges:
      if (.patch | type) != "string" or (.additions | type) != "number"
        or (.deletions | type) != "number" then null
      elif ([.patch | split("\n")[] | select(startswith("+"))] | length) != .additions
        or ([.patch | split("\n")[] | select(startswith("-"))] | length) != .deletions then null
      else
        reduce (.patch | split("\n"))[] as $l ({ranges: [], cur: null, ok: true};
          ([$l | capture("^@@ -(?<s>[0-9]+)(,(?<n>[0-9]+))? \\+[0-9]+(,(?<m>[0-9]+))? @@")]
            | first) as $h
          | if $h != null then
            (if .cur != null and (.cur.o != 0 or .cur.n != 0) then .ok = false else . end)
            | ($h.s | tonumber) as $s
            | (if $h.n == null then 1 else ($h.n | tonumber) end) as $n
            | (if $h.m == null then 1 else ($h.m | tonumber) end) as $m
            | .ranges += [if $n == 0 then {lo: $s, hi: ($s + 1)} else {lo: $s, hi: ($s + $n - 1)} end]
            | .cur = {o: $n, n: $m}
          elif .cur == null then .
          elif ($l | startswith("-")) then .cur.o -= 1
          elif ($l | startswith("+")) then .cur.n -= 1
          elif ($l | startswith(" ")) then .cur.o -= 1 | .cur.n -= 1
          else . end)
        # No recognized header means no evidence of disjointness, even when the totals match.
        | if .ok and (.ranges | length) > 0 and (.cur.o == 0 and .cur.n == 0)
          then .ranges else null end
      end;
    [.files[] | {key: .filename, value: ranges}] | from_entries' <<<"$1" 2>/dev/null
}

compare_file_set() {
  jq -ce '
    def valid_file:
      (.filename | type) == "string" and (.filename | length) > 0
      and ((has("previous_filename") | not) or .previous_filename == null
        or ((.previous_filename | type) == "string" and (.previous_filename | length) > 0));
    if (.files | type) == "array" and all(.files[]; valid_file) then
      {count: (.files | length),
       paths: ([.files[] | .filename, .previous_filename?]
         | map(select(type == "string")) | unique)}
    else error("missing or invalid files") end' <<<"$1" 2>/dev/null
}

warn_base_drift() {
  local pr="$1" fields base base_sha head_sha mstate rc
  local forward reverse behind ahead forward_base reverse_base
  local forward_set reverse_set pr_files base_files pr_file_count base_file_count overlap overlap_count
  local pr_hunks base_hunks split overlap_meet overlap_meet_count overlap_unread overlap_unread_count
  local overlap_disjoint overlap_disjoint_count
  local count_unknown="" overlap_unknown="" overlap_reason="" count_warn="" dirty_warn=""
  # Placeholders, never empty fields: tab is IFS whitespace, so an empty middle column would shift
  # a SHA into the wrong field (the same trap build_checks documents). The head SHA is captured
  # in this one read: labels can move. The base's SHA deliberately is NOT: the PR's `.base.sha`
  # is the base as it stood when GitHub last built the PR's merge commit, and on a PR whose merge
  # commit CANNOT be built (mergeable_state dirty) it stops moving — ludics-lite#39 read "0
  # behind, 15 ahead" off it while main was 7 commits and 4 overlapping files ahead, so the one
  # PR that needed the warning was the one that could not get it (ludics-lite#44). The base's
  # tip is read from the branch itself instead, once, below.
  fields=$(gh_retry read api "repos/$REPO/pulls/$pr" \
    --jq '[(.base.ref // "-"), (.head.sha // "-"), (.mergeable_state // "-")] | @tsv')
  rc=$?
  IFS=$'\t' read -r base head_sha mstate <<<"$fields"
  if [ "$rc" -ne 0 ] || [ -z "$base" ] || [ "$base" = - ] ||
    [ -z "$head_sha" ] || [ "$head_sha" = - ]; then
    warn "how far $REPO#$pr is behind its base: UNKNOWN — the PR could not be read" \
      "($(gh_err_line)). This is not 'not behind': check it by hand before merging" \
      "and do not assume the base-drift file overlap is empty."
    echo "base-drift file overlap $REPO#$pr: UNKNOWN — the PR snapshot could not be read"
    return 3
  fi
  # One read of the tip, and both compares below use that SHA: the base advancing between the
  # two calls then still shows up as disagreeing merge bases (checked below) rather than as two
  # silently different questions. Encoded like `base` encodes it — a `#` or `&` in a branch name
  # would otherwise read some other branch's tip.
  base_sha=$(gh_retry read api "repos/$REPO/commits/$(encode_ref "$base")" --jq .sha)
  rc=$?
  if [ "$rc" -ne 0 ] || [ -z "$base_sha" ]; then
    warn "how far $REPO#$pr is behind $base: UNKNOWN — the tip of $base could not be read" \
      "($(gh_err_line)). This is not 'not behind': check it by hand before merging" \
      "and do not assume the base-drift file overlap is empty."
    echo "base-drift file overlap $REPO#$pr: UNKNOWN — the tip of $base could not be read"
    return 3
  fi

  # Said before the counts, because it is what the counts mean: whatever the checks gate read
  # for this head tested it merged with an OLDER base (a pull_request run from before the base
  # moved) or alone (a branch-push run), never with the base as it stands, and the merge call
  # below this will fail on it anyway.
  if [ "$mstate" = dirty ]; then
    dirty_warn=1
    echo "!!! $REPO#$pr CONFLICTS with $base (mergeable_state=dirty): GitHub cannot build head"
    echo "!!! ${head_sha:0:7} merged with the current $base, so no pull_request run tests that merge"
    echo "!!! and the merge will be refused. Merge $base in, resolve, push, and let the checks run"
    echo "!!! on the resolution."
  fi

  # Compare the tip and the head in both directions. Each direction's files are changes from
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
  forward_set=$(compare_file_set "$forward") || overlap_unknown=1
  pr_files=$(jq -ce '.paths' <<<"$forward_set" 2>/dev/null) || overlap_unknown=1
  pr_file_count=$(jq -er '.count' <<<"$forward_set" 2>/dev/null) || overlap_unknown=1

  reverse=$(gh_retry read api "repos/$REPO/compare/$head_sha...$base_sha?per_page=1")
  rc=$?
  if [ "$rc" -ne 0 ]; then
    overlap_unknown=1
    overlap_reason="the reverse compare call did not answer ($(gh_err_line))"
  else
    reverse_base=$(jq -er '.merge_base_commit.sha | strings | select(length > 0)' \
      <<<"$reverse" 2>/dev/null) || overlap_unknown=1
    reverse_set=$(compare_file_set "$reverse") || overlap_unknown=1
    base_files=$(jq -ce '.paths' <<<"$reverse_set" 2>/dev/null) || overlap_unknown=1
    base_file_count=$(jq -er '.count' <<<"$reverse_set" 2>/dev/null) || overlap_unknown=1
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
  # Split the overlapping paths by whether the two sides' hunks meet. A path whose hunks could
  # not be read on either side stays with the meeting ones: unread is not disjoint.
  if [ -z "$overlap_unknown" ] && [ "$overlap_count" -gt 0 ]; then
    pr_hunks=$(compare_hunks "$forward") || pr_hunks='{}'
    base_hunks=$(compare_hunks "$reverse") || base_hunks='{}'
    split=$(jq -cn --argjson paths "$overlap" --argjson pr "$pr_hunks" --argjson base "$base_hunks" '
      def meets($a; $b):
        any($a[]; . as $x | any($b[]; .lo <= $x.hi + 1 and $x.lo <= .hi + 1));
      reduce $paths[] as $p ({meet: [], disjoint: [], unread: []};
        if ($pr[$p] | type) != "array" or ($base[$p] | type) != "array" then .unread += [$p]
        elif meets($pr[$p]; $base[$p]) then .meet += [$p]
        else .disjoint += [$p] end)') || split=""
    if [ -n "$split" ]; then
      overlap_meet=$(jq -c '.meet + .unread' <<<"$split")
      overlap_meet_count=$(jq -r '(.meet + .unread) | length' <<<"$split")
      overlap_unread=$(jq -c '.unread' <<<"$split")
      overlap_unread_count=$(jq -r '.unread | length' <<<"$split")
      overlap_disjoint=$(jq -c '.disjoint' <<<"$split")
      overlap_disjoint_count=$(jq -r '.disjoint | length' <<<"$split")
    else
      overlap_meet="$overlap"
      overlap_meet_count="$overlap_count"
      overlap_unread="$overlap"
      overlap_unread_count="$overlap_count"
      overlap_disjoint='[]'
      overlap_disjoint_count=0
    fi
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
  elif [ "$overlap_meet_count" -eq 0 ]; then
    # Same paths, different lines: what a sibling's appended stanza looks like. Said without the
    # `!!!`, which is reserved for the two facts that change the next move (a conflict, and a
    # same-region overlap), and with rc 0, since there is nothing to act on (ludics-lite#54).
    echo "base-drift file overlap $REPO#$pr: $overlap_count path(s) changed on both sides, all in" \
      "DISJOINT hunks (the base's lines and this PR's do not meet, which git merges by" \
      "construction): $overlap_disjoint"
  else
    # The wording is the policy: six workers of the 2026-09-04 wave read the old "rebase, push,
    # and let checks re-run" as an instruction they had just failed to follow, then watched the
    # merge proceed anyway (ludics-lite#54). Under roll-forward a clean merge lands on the run
    # that went green; the rebase is an option for a head one wants CI to test against the
    # current base, not a requirement.
    echo "!!! BASE-DRIFT FILE OVERLAP: the base's advance touched the SAME REGIONS of" \
      "$overlap_meet_count path(s) changed by"
    printf '!!! %s#%s: %s\n' "$REPO" "$pr" "$overlap_meet"
    if [ "$overlap_unread_count" -gt 0 ]; then
      echo "!!! (hunks unread for $overlap_unread_count of them — patch missing or unreadable in the compare response," \
        "so counted as meeting: $overlap_unread)"
    fi
    if [ "$overlap_disjoint_count" -gt 0 ]; then
      echo "!!! and $overlap_disjoint_count more path(s) in disjoint hunks only: $overlap_disjoint"
    fi
    echo "!!! Merging under the roll-forward policy (ahrefs/ocannl#861): a clean merge proceeds on"
    echo "!!! the run that went green, and the post-merge integration loop verifies merged $base."
    echo "!!! Read those files for semantic drift; rebase (or merge $base in where the branch is"
    echo "!!! shared) only if you want CI to test this head against the current $base first."
    printf 'pr-review.sh: BASE-DRIFT FILE OVERLAP for %s#%s in the same regions: %s — noted even below %s\n' \
      "$REPO" "$pr" "$overlap_meet" \
      "SHIP_PR_STALE_BASE; it does not block the merge under the roll-forward policy." >&2
  fi

  if [ -n "$count_warn" ]; then
    warn "MERGING A STALE BRANCH: $REPO#$pr is $behind commits behind $base (warns at $STALE_BASE," \
      "SHIP_PR_STALE_BASE) — a clean merge is the policy (roll-forward, ahrefs/ocannl#861)."
  fi
  if [ -n "$dirty_warn" ]; then
    warn "$REPO#$pr CONFLICTS with $base (mergeable_state=dirty): nothing tests this head merged" \
      "with the current $base while GitHub cannot build that merge — merge $base in first."
  fi
  if [ -n "$count_unknown" ] || [ -n "$overlap_unknown" ]; then
    return 3
  fi
  # A shared path whose hunks stay apart is reported, not warned (ludics-lite#54): rc 1 is for
  # the two overlap facts a reader acts on, meeting hunks and hunks that could not be read.
  if [ -n "$count_warn" ] || [ -n "$dirty_warn" ] || [ "${overlap_meet_count:-0}" -gt 0 ]; then
    return 1
  fi
  return 0
}

# merge = read the build signal, then merge. The two are one command on purpose: a gate you have
# to remember to run separately is the gate that was missing for seven merges.
# Refuses (exit 1) when the PR's base has a merge queue, exit 3 when that could not be read —
# the queue is GraphQL-only, and an unread answer is not "no queue". Called by merge under
# --require-green, twice: before the wait and again right before the merge call.
refuse_merge_queue() {
  local pr="$1" base_ref queue
  base_ref=$(gh_retry read api "repos/$REPO/pulls/$pr" --jq .base.ref)
  [ "$?" -eq 0 ] && [ -n "$base_ref" ] || fail 3 "NOT merging $REPO#$pr: the base branch" \
    "could not be read ($(gh_err_line)), so whether it has a merge queue is unknown."
  queue=$(gh_retry read api graphql \
    -f query='query($o:String!,$r:String!,$b:String!){repository(owner:$o,name:$r){mergeQueue(branch:$b){id}}}' \
    -f o="${REPO%%/*}" -f r="${REPO#*/}" -f b="$base_ref" \
    --jq '.data.repository.mergeQueue.id // ""')
  [ "$?" -eq 0 ] || fail 3 "NOT merging $REPO#$pr: could not read whether $base_ref has a" \
    "merge queue ($(gh_err_line)); a close-out merge does not guess. Retry."
  [ -z "$queue" ] || fail 1 "REFUSING to merge $REPO#$pr: $base_ref has a merge queue, so" \
    "\`gh pr merge\` would ENQUEUE the PR to land later on whatever head it has then, and a" \
    "close-out merge lands the gated head now or not at all. Hand the merge to the maintainer" \
    "with the record on the PR."
}

cmd_merge() {
  local pr="${1:?usage: merge <pr> [--override <reason>] [--wait[=seconds]] [--allow-no-verdict] [-- <gh pr merge args...>]}"
  shift
  local override="" wait_for=0 allow_no_verdict="" require_green="" gate out rc attempt=1 mergeable state arg
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
    --require-green)
      require_green=1
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
  # The head binding is the script's, not the caller's: a forwarded --match-head-commit would
  # follow the script's on the command line and could name a head the gate never read.
  for arg in "${gh_args[@]}"; do
    case "$arg" in
    --match-head-commit | --match-head-commit=*) die "merge: --match-head-commit is set by the" \
      "script to the head the build signal was read for, and cannot be forwarded." ;;
    esac
  done
  # A close-out merge is a merge NOW of the head the gate read, or nothing: deferred auto-merge
  # would land whatever head the PR has when the base's checks pass, gate unread.
  if [ -n "$require_green" ]; then
    for arg in "${gh_args[@]}"; do
      case "$arg" in
      --auto | --auto=*) die "merge: --require-green cannot be combined with --auto — a close-out" \
        "merge lands the gated head now or refuses; it is never deferred to auto-merge." ;;
      esac
    done
  fi
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
  # A merge queue turns `gh pr merge` into an ENQUEUE — the PR lands later, on whatever head it
  # has then, and --disable-auto does not take an entry out of a queue. A close-out merge lands
  # the gated head now or refuses, so on a queued base it refuses before calling merge at all:
  # once here, before a wait that can run two hours, and once more right before the call, since
  # the base can be retargeted or a queue enabled during the wait.
  [ -z "$require_green" ] || refuse_merge_queue "$PR_NUM"
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
  5) fail 5 "NOT merging $REPO#$PR_NUM: the observed head was SUPERSEDED; re-run to judge the new head." ;;
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
  # ABSENT passes the ordinary gate (nothing is red, and the run list has confirmed nothing is
  # coming), but a close-out merge — one the reviewer never 👍'd, resting on the record instead
  # — is required to have READ a green. --require-green turns absent into a refusal.
  if [ -n "$require_green" ] && [ "$VERDICT" != green ]; then
    fail 4 "REFUSING to merge $REPO#$PR_NUM: --require-green and the build signal is $VERDICT," \
      "not green. A close-out merge needs a green verdict READ on the final head. If the head" \
      "genuinely runs no build (path filters), get one onto it — dispatch the workflow on the" \
      "branch (gh workflow run) — or hand the merge to the maintainer with the record; a" \
      "close-out merge is never made by dropping --require-green."
  fi
  # Green by skips alone is the path-filter case wearing a verdict: every check concluded, none
  # of them ran a build. The ordinary gate lets that through (nothing failed); a close-out merge
  # needs a build that RAN and passed.
  if [ -n "$require_green" ] && [ "${CHECK_PASSED:-0}" -eq 0 ]; then
    fail 4 "REFUSING to merge $REPO#$PR_NUM: --require-green and every build check on the head" \
      "was skipped or neutral — green, but no build RAN. A close-out merge needs at least one" \
      "check that concluded success. If the head genuinely runs no build (job-level path" \
      "filters), get one onto it (gh workflow run) or hand the merge to the maintainer with" \
      "the record; a close-out merge is never made by dropping --require-green."
  fi
  # Last, so that it is read AFTER a --wait (the base keeps moving during one) and so that its
  # verdict is the final thing on screen before the merge itself. A loud WARNING, not a gate: the
  # roll-forward policy (ahrefs/ocannl#861, see warn_base_drift) lets a clean merge proceed on the
  # head's green run, and hands semantic drift to the post-merge integration loop. A 3 (unread)
  # has already said UNKNOWN loudly; neither outcome blocks the merge.
  warn_base_drift "$PR_NUM" || true
  [ -z "$require_green" ] || refuse_merge_queue "$PR_NUM"
  # The verdict above is about ONE head, the one gate_checks read — and a --wait is minutes to
  # hours long, during which a push can move the PR. `gh pr merge` merges whatever the head is at
  # the moment of the call; --match-head-commit makes it refuse unless that is still the gated
  # SHA, so a close-out merge cannot land a head with neither a read green nor a 👍 (review of
  # ludics-lite#39). The refusal is final, not retried: re-run merge, which re-reads the gate.
  while :; do
    out=$(gh_retry write pr merge "$PR_NUM" --repo "$REPO" --match-head-commit "$CHECK_SHA" \
      "${gh_args[@]}")
    rc=$?
    [ -n "$out" ] && printf '%s\n' "$out"
    [ "$rc" -eq 0 ] && break
    case "$(gh_err_line)" in
    *"was modified"* | *"does not match"* | *"head commit"* | *"expected head"*)
      fail 1 "NOT merged: $REPO#$PR_NUM's head is no longer ${CHECK_SHA:0:8}, the commit the build" \
        "signal was read for ($(gh_err_line)). A push moved it; re-run merge so the gate reads" \
        "the new head."
      ;;
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
  if [ -n "$require_green" ]; then
    # Required checks turned the call into a deferred auto-merge (a merge queue was refused
    # above, before the call), which --match-head-commit guarded only at enable time: a later
    # push would land ungated. Take it back and refuse, loudly; the caller decides what to do
    # about the base's requirements.
    if gh_retry write pr merge "$PR_NUM" --repo "$REPO" --disable-auto >/dev/null; then
      fail 1 "NOT merged, and auto-merge DISABLED again: $REPO#$PR_NUM ($state) — the base defers" \
        "merges to its required checks or a merge queue, and a close-out merge is never" \
        "deferred. Merge it when the base allows a direct merge, or hand it to the maintainer" \
        "with the record on the PR."
    fi
    fail 3 "NOT merged, and auto-merge could NOT be disabled ($(gh_err_line)): $REPO#$PR_NUM" \
      "($state) is armed to land a LATER head ungated. Disable it by hand (gh pr merge" \
      "--disable-auto) before anything else."
  fi
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
# judged run is about the CURRENT tip — or, with nothing in flight and NO run for the tip at all,
# until the workflow's own paths-ignore says outright that none can be created for this tip (a
# docs-only push legitimately never gets one), or failing that until a grace expires
# (SHIP_PR_BASE_ABSENT_GRACE, which is all that separates "never coming" from "not yet"). Then it
# settles for the verdicts in hand, saying which commit each is about, exactly as the plain read
# does. Two absences it will not settle: a run that EXISTS for the tip and has not judged it
# (queued, running, or stopped), which only that run can answer; and a run in flight anywhere on
# the branch, which is judging a tree the tip contains — waiting for it does better than settling,
# since its commit becomes the verdict the tip then trails. A red breaks the wait immediately: it
# is a verdict.
# The red runs whose jobs have already been read, one "<run id><TAB><the line>" record per line.
# `base --wait` re-folds every round, so without this a standing red would spend one jobs call per
# round — per red workflow — to print the line it printed last time. A LIST rather than one slot
# because two red workflows alternate run ids, and a single slot would miss on every read.
BASE_JOBS_CACHE=""

# base_red_detail <workflow-id> <unfolded run rows>: the two facts a CI-red owner asks for first,
# left in BASE_RED_DETAIL as indented notes for the RED line — WHICH job failed, and WHERE the red
# started
# (ludics-lite#73: main was red for a day on a job nobody had named, because what reads a base's
# health reported the workflow and the newest failing run, and an owner still had to open the run
# and walk the branch back by hand to find the commit that broke it).
#
# Both are DECORATION on a verdict already reached, and that governs their failure modes: the
# first red commit is taken from the run rows already in hand, and the jobs read is one extra call
# whose failure prints UNKNOWN and leaves the red standing. Turning a red base into exit 3 because
# a second call fell over would be the worst trade in this file — the caller would retry a fact
# that was already established.
#
# The result comes back in a variable rather than on stdout because the cache above has to
# OUTLIVE the call: `detail=$(base_red_detail …)` would run the whole function in a subshell, and
# every record it added to the cache would die with it — the cache would read empty on every
# round and the call it exists to save would be made anyway (review round 1).
BASE_RED_DETAIL=""
base_red_detail() {
  local wfid="$1" rows="$2" indent='           '
  local cached line
  BASE_RED_DETAIL=""
  local c_wf c_name c_status c_concl c_sha c_when c_url c_id
  local jname jconcl jobs jrc run_id="" first_sha="" first_when="" reds=0 bounded=0 failed=""
  # Newest-first, the order the API returns and the fold relies on. A stopped-not-judged run
  # (cancelled/stale) inside the streak is skipped rather than treated as its end: it judged
  # nothing, so it is no evidence that the branch was well at that commit. A run still running is
  # skipped for the same reason.
  while IFS=$'\t' read -r c_wf c_name c_status c_concl c_sha c_when c_url c_id; do
    [ "$c_wf" = "$wfid" ] || continue
    [ "$c_status" = completed ] || continue
    case "$(conclusion_class "$c_concl")" in
    red)
      reds=$((reds + 1))
      [ -n "$run_id" ] || run_id="$c_id" # the newest red: the run the RED line above reports
      first_sha="$c_sha"
      first_when="$c_when"
      ;;
    green)
      # The newest judged run BELOW the streak is not red, so the streak has a floor and the red
      # started at the run above this one.
      bounded=1
      break
      ;;
    *) continue ;;
    esac
  done <<<"$rows"
  # Called only under a red verdict, so this is a contradiction rather than a quiet nothing: say
  # nothing rather than report a "first red" the rows do not support.
  [ "$reds" -gt 0 ] || return 0
  if [ "$bounded" -eq 1 ]; then
    printf -v BASE_RED_DETAIL \
      '%sred since %s (run created %s), %d run(s) back; the judged run before it was not red\n' \
      "$indent" "${first_sha:0:8}" "$first_when" "$reds"
  else
    # The window is the newest runs of this workflow on this branch, not its whole history: with
    # no green under the streak the first red commit is NOT known, and saying so is the point —
    # an owner told "red since <the oldest run the page happened to hold>" would start bisecting
    # from the wrong end.
    printf -v BASE_RED_DETAIL \
      '%sred for all %d judged run(s) in the window, back to %s (run created %s) — the window holds no\n%sgreen under it, so the red may start further back\n' \
      "$indent" "$reds" "${first_sha:0:8}" "$first_when" "$indent"
  fi
  case "$run_id" in '' | *[!0-9]*) return 0 ;; esac
  cached=$(awk -F'\t' -v r="$run_id" '$1 == r { sub(/^[^\t]*\t/, ""); print; exit }' \
    <<<"$BASE_JOBS_CACHE")
  if [ -n "$cached" ]; then
    BASE_RED_DETAIL="${BASE_RED_DETAIL}${cached}"$'\n'
    return 0
  fi
  jobs=$(gh_retry read api --paginate "repos/$REPO/actions/runs/$run_id/jobs?per_page=100" \
    --jq '.jobs[] | [.name, (.conclusion // "pending")] | @tsv')
  jrc=$?
  # Not cached: the next round may reach the API.
  [ "$jrc" -eq 0 ] || {
    printf -v line '%swhich job failed is UNKNOWN (%s) — the red above stands; open the run' \
      "$indent" "$(gh_err_line)"
    BASE_RED_DETAIL="${BASE_RED_DETAIL}${line}"$'\n'
    return 0
  }
  while IFS=$'\t' read -r jname jconcl; do
    [ -n "$jname" ] || continue
    [ "$(conclusion_class "$jconcl")" = red ] && failed="${failed}${failed:+, }$jname ($jconcl)"
  done <<<"$jobs"
  if [ -n "$failed" ]; then
    line="${indent}failed job(s): $failed"
  else
    # A run can conclude red with no red job: startup_failure, or a failure raised outside the
    # jobs (a matrix that could not expand). Naming that is more use than an empty list.
    line="${indent}no job in that run concluded red — a startup or workflow-level failure"
  fi
  BASE_JOBS_CACHE="${BASE_JOBS_CACHE}${run_id}"$'\t'"${line}"$'\n'
  BASE_RED_DETAIL="${BASE_RED_DETAIL}${line}"$'\n'
}

# --- paths-ignore: the one absence that is not a race ------------------------------------------
# A push whose every changed path sits in the workflow's `paths-ignore` NEVER gets a run: there is
# nothing in flight, nothing late, and no grace that could tell the difference by waiting. `checks`
# and `merge` settle such a head on the clock alone (run_signal's run-creation grace), which is the
# honest answer when nothing else is in hand. `base --wait` is the one caller that has more: the
# tip and the commit the standing verdict is about are both known, so the diff between them is one
# read, and the workflow's own filter says whether that diff can produce a run at all. Recognizing
# it is what keeps a docs-only default-branch tip from parking a whole wave's dispatch at the
# --wait ceiling (ludics-lite#156).
#
# Every step REFUSES rather than guesses: a workflow file that does not parse, a filter pattern
# this translation does not carry, a compare that came back empty or at the endpoint's cap, an
# `on: push:` naming no `paths-ignore`. A refusal costs the grace — the settle that was already
# there, one ABSENT_GRACE later — while a guess would claim "no run is coming" for a run that is
# merely late and settle for an older green over an unbuilt tip. The asymmetry is the whole design:
# the parser below is deliberately narrow, and every branch it cannot read says so.

# WORKFLOW_YAML_FILTER: the items of `on: <want>: <seq>` in a workflow file, one per line, or
# exit 1 when they cannot be established. The event and the sequence key are both PARAMETERS
# (`-v want=push -v seq=paths-ignore`), because a PR head asks this of more than one event and of
# more than one list: `pull_request`'s `paths-ignore` says whether a run would be filtered out,
# and `push`'s `branches` says whether a push to THIS branch reaches the trigger at all
# (ludics-lite#176). Exit 1 covers both "the file does not parse" and "that key is not there";
# every caller treats the two the same, as evidence it does not have.
#
# The YAML is read by a narrow state machine rather than a parser this repository does not have.
# It accepts what a workflow file actually looks like — a top-level `on:` (or `"on":`) mapping, a
# `<want>:` key under it, a `paths-ignore:` block sequence or one flow sequence, single- or
# double-quoted items — and refuses everything else, tabs and aliases included: an alias
# (`paths-ignore: *docs`) reads as a glob to anything that does not track anchors, and "*docs"
# would match half a repository. An INCLUDE filter (`paths:`) is not a paths-ignore and is not
# read as one: the event is then declared with no paths-ignore, which refuses.
WORKFLOW_YAML_FILTER='
function ind_of(s,   n) { n = match(s, /[^ ]/); return n ? n - 1 : -1 }
function unquote(s,   c) {
  sub(/^[ ]+/, "", s); sub(/[ ]+$/, "", s)
  c = substr(s, 1, 1)
  if ((c == q || c == dq) && substr(s, length(s), 1) == c && length(s) >= 2)
    s = substr(s, 2, length(s) - 2)
  return s
}
function emit(s) { s = unquote(s); if (s == "") { bad = 1; exit } n++; pat[n] = s }
function flow(s,   i, m, parts) {
  s = substr(s, 2, length(s) - 2)
  m = split(s, parts, ",")
  for (i = 1; i <= m; i++) emit(parts[i])
  ok = 1
}
/\t/ { bad = 1; exit }
{
  line = $0
  sub(/[ \r]+$/, "", line)
  if (line == "") next
  ind = ind_of(line)
  key = substr(line, ind + 1)
  if (substr(key, 1, 1) == "#") next
  rest = key
  sub(/^[^:]*:/, "", rest)
  sub(/^[ ]+/, "", rest)
  sub(/[ ]+#.*$/, "", rest)
}
state == 0 {
  if (ind == 0 && key ~ /^(on|"on")[ ]*:/) {
    if (rest != "" && substr(rest, 1, 1) != "#") { bad = 1; exit }
    state = 1; on_ind = ind
  }
  next
}
state == 1 {
  if (ind <= on_ind) { bad = 1; exit }
  if (key ~ ("^" want "[ ]*:")) {
    if (rest != "" && substr(rest, 1, 1) != "#") { bad = 1; exit }
    state = 2; push_ind = ind
  }
  next
}
state == 2 {
  if (ind <= push_ind) { bad = 1; exit }
  if (key ~ ("^" seq "[ ]*:")) {
    if (rest == "") { state = 3; seq_ind = ind; next }
    if (rest ~ /^\[.*\]$/) { flow(rest); exit }
    bad = 1; exit
  }
  next
}
state == 3 {
  if (key == "-" || substr(key, 1, 2) == "- ") { emit(substr(key, 2)); next }
  if (ind <= seq_ind) { ok = 1; exit }
  bad = 1; exit
}
END {
  if (state == 3 && !bad) ok = 1
  if (bad || !ok || n == 0) exit 1
  for (i = 1; i <= n; i++) print pat[i]
}'

# WORKFLOW_ON_EVENTS: the trigger events a workflow file DECLARES, one per line, or exit 1 when
# they cannot be established. Reading a filter is not enough on a PR head: what has to be shown is
# that NO trigger of this workflow can produce a run for this head, so the set of triggers has to
# be known before any of their filters is read (ludics-lite#176). Same narrowness as the filter
# above — the mapping form, the one-scalar form (`on: push`) and the flow form (`on: [push,
# pull_request]`), and a refusal for everything else, an event name that is not a plain identifier
# included.
WORKFLOW_ON_EVENTS='
function ind_of(s,   n) { n = match(s, /[^ ]/); return n ? n - 1 : -1 }
function unquote(s,   c) {
  sub(/^[ ]+/, "", s); sub(/[ ]+$/, "", s)
  c = substr(s, 1, 1)
  if ((c == q || c == dq) && substr(s, length(s), 1) == c && length(s) >= 2)
    s = substr(s, 2, length(s) - 2)
  return s
}
function emit(s) {
  s = unquote(s)
  if (s !~ /^[A-Za-z_][A-Za-z0-9_]*$/) { bad = 1; exit }
  n++; ev[n] = s
}
function flow(s,   i, m, parts) {
  s = substr(s, 2, length(s) - 2)
  m = split(s, parts, ",")
  for (i = 1; i <= m; i++) emit(parts[i])
  ok = 1
}
BEGIN { ev_ind = -1 }
/\t/ { bad = 1; exit }
{
  line = $0
  sub(/[ \r]+$/, "", line)
  if (line == "") next
  ind = ind_of(line)
  key = substr(line, ind + 1)
  if (substr(key, 1, 1) == "#") next
  rest = key
  sub(/^[^:]*:/, "", rest)
  sub(/^[ ]+/, "", rest)
  sub(/[ ]+#.*$/, "", rest)
}
state == 0 {
  if (ind == 0 && key ~ /^(on|"on")[ ]*:/) {
    on_ind = ind
    if (rest == "") { state = 1; next }
    if (rest ~ /^\[.*\]$/) { flow(rest); exit }
    emit(rest); ok = 1; exit
  }
  next
}
state == 1 {
  # The on: block ended, and every event key in it has been seen.
  if (ind <= on_ind) { ok = 1; exit }
  # The events are the keys at the FIRST level under `on:`; anything deeper is one event own
  # mapping (`branches:`, `types:`, the filters themselves) and anything shallower than that
  # level but still inside the block is a file this parser will not claim to have read.
  if (ev_ind < 0) ev_ind = ind
  if (ind < ev_ind) { bad = 1; exit }
  if (ind > ev_ind) next
  if (key !~ /^[A-Za-z_][A-Za-z0-9_]*[ ]*:/) { bad = 1; exit }
  k = key
  sub(/[ ]*:.*$/, "", k)
  emit(k)
  next
}
END {
  if (state == 1 && !bad) ok = 1
  if (bad || !ok || n == 0) exit 1
  for (i = 1; i <= n; i++) print ev[i]
}'

# workflow_path <workflow id>: where that workflow's file lives, or nothing (exit 1).
workflow_path() {
  local wpath
  wpath=$(gh_retry read api "repos/$REPO/actions/workflows/$1" --jq '.path // ""') || return 1
  # One path, and one that stays inside the repository: the value is interpolated into a REST
  # path, so a newline or a traversal in it is a different request, not a workflow file.
  case "$wpath" in '' | *$'\n'* | */../* | ../* | /*) return 1 ;; esac
  printf '%s\n' "$wpath"
}

# workflow_body <path> <ref>: the file's own text at that ref, or nothing (exit 1). The ref
# matters: the filter that decides whether a commit gets a run is the one that commit carries.
workflow_body() {
  local body
  # The raw media type, so the file arrives as itself: the JSON form is base64 whose decoder is
  # spelled `-d` on one of this fleet's two platforms and `-D` on the other.
  body=$(gh_retry read api -H "Accept: application/vnd.github.raw" \
    "repos/$REPO/contents/$(encode_ref "$1")?ref=$2") || return 1
  [ -n "$body" ] || return 1
  printf '%s\n' "$body"
}

# workflow_files_at <ref>: every YAML file directly under `.github/workflows/` at that ref, one
# path per line, or nothing (exit 1). What the repository's workflow LIST is not: that list is
# built from the default branch plus whatever has run, so a workflow file living only on a PR's
# base branch, or only on its head, is simply absent from it — and the loop below would then pass
# every workflow it knows about while the one it does not know about creates the run (review
# rounds 3 and 5). Read at both ends of the merge, since a `pull_request` run sees the union.
workflow_files_at() {
  local raw
  raw=$(gh_retry read api "repos/$REPO/contents/.github/workflows?ref=$1" \
    --jq 'if type == "array" then (.[] | select(.type == "file") | .path) else empty end') ||
    return 1
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" | grep -E '\.ya?ml$'
}

# workflow_paths_ignore <workflow id> <ref>: a workflow's `on: push: paths-ignore` patterns, one
# per line, or nothing (exit 1) when they cannot be established. cmd_base's reader: it queries one
# event, `push`, because that is the only event whose runs it folds.
workflow_paths_ignore() {
  local wid="$1" ref="$2" wpath body pats
  wpath=$(workflow_path "$wid") || return 1
  body=$(workflow_body "$wpath" "$ref") || return 1
  pats=$(awk -v q="'" -v dq='"' -v want=push -v seq=paths-ignore \
    "$WORKFLOW_YAML_FILTER" <<<"$body") || return 1
  [ -n "$pats" ] || return 1
  printf '%s\n' "$pats"
}

# glob_ere <pattern>: one GitHub path filter as an ERE anchored at both ends, or nothing (exit 1)
# for a pattern this translation does not carry. `**` is any run of characters, `*` any run within
# one path segment — the two forms every real `paths-ignore` is built from. The cheat sheet's
# other constructs (`?` and `+` over the PRECEDING character, character classes, a leading `!`
# that inverts the whole pattern) are refused rather than approximated: each of them can only
# widen what counts as ignored, and a pattern read too widely settles a tip whose run is coming.
glob_ere() {
  local p="$1" out="" c i=0
  case "$p" in '' | *[!A-Za-z0-9._/*-]*) return 1 ;; esac
  while [ "$i" -lt "${#p}" ]; do
    c=${p:i:1}
    case "$c" in
    '*')
      if [ "${p:i:2}" = '**' ]; then
        out="$out.*"
        i=$((i + 2))
        continue
      fi
      out="${out}[^/]*"
      ;;
    '.') out="$out\\." ;;
    *) out="$out$c" ;;
    esac
    i=$((i + 1))
  done
  printf '^%s$' "$out"
}

# paths_ignore_covers <patterns> <changed paths>: every changed path matches some pattern. A
# pattern that does not translate fails the whole question rather than just itself — "the rest of
# them covered everything" is not an answer about a filter half of which was not read.
paths_ignore_covers() {
  local pats="$1" files="$2" f p ere eres="" hit
  [ -n "$pats" ] && [ -n "$files" ] || return 1
  # EVERY pattern is translated BEFORE anything is matched. Translating lazily would let an early
  # pattern that happens to match end the search before the untranslatable one beside it was ever
  # looked at, and the filter would be declared read when half of it was not.
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    ere=$(glob_ere "$p") || return 1
    eres="${eres}${ere}"$'\n'
  done <<<"$pats"
  [ -n "$eres" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    hit=""
    while IFS= read -r ere; do
      [ -n "$ere" ] || continue
      printf '%s' "$f" | grep -Eq -- "$ere" && {
        hit=1
        break
      }
    done <<<"$eres"
    [ -n "$hit" ] || return 1
  done <<<"$files"
  return 0
}

# How many commits the recognition reads one by one before it gives up and lets the grace answer
# instead. GitHub creates a run for a push of more than 1000 commits WHATEVER the filter says, so
# any cap at or below that is sound; this one is far below, because the recognition exists for a
# docs push of a handful of commits and reading a long range is neither cheap nor what it is for.
IGNORE_MAX_COMMITS=20

# The answer per <workflow>/<judged commit>/<tip>, so a wait that cannot recognize the tip spends
# its reads ONCE rather than once per round for as long as the grace runs. Keyed by all three
# because each of them changing changes the answer.
BASE_IGNORE_CACHE=""
PATHS_IGNORE_WHY=""

# commit_files <sha>: the paths ONE commit changed, one per line, or nothing (exit 1) when the
# answer is not evidence — an empty list (a commit whose files the API omitted, an empty
# first-parent diff) and a list at the endpoint's 300-file cap both say nothing about the whole
# commit. A merge commit answers with its FIRST-PARENT diff, which is the change the merge brought
# to the branch. Renames carry both names, since both are changed paths.
#
# PAGINATED, because a commit's files are: the endpoint serves 30 a page by default and 300 in
# all, so an unpaginated read of a 45-file commit answers with 30 ignored paths and hides the
# source file behind them — a page taken for a diff (ludics-lite#163 review, round 2). One row per
# file, both of a rename's names on it, so the count below counts FILES and not paths.
commit_files() {
  local sha="$1" raw count
  raw=$(gh_retry read api --paginate "repos/$REPO/commits/$sha?per_page=100" \
    --jq '.files[]? | [.filename, (.previous_filename // "")] | @tsv') || return 1
  count=$(printf '%s' "$raw" | grep -c .)
  [ "$count" -gt 0 ] && [ "$count" -lt 300 ] || return 1
  printf '%s' "$raw" | tr '\t' '\n' | grep .
}

# commits_ignored <patterns> <judged sha> <tip>: true when every commit on the
# FIRST-PARENT path from the judged commit up to the tip changed only ignored paths.
#
# Per COMMIT, and not the cumulative diff of the range, because a path filter is evaluated per
# PUSH: GitHub compares the push's before and after SHAs, and a range that nets out to nothing can
# still contain a push that touched source. Push boundaries are not in this feed — but a push's
# own diff is a subset of the union of the diffs along ANY path from its before to its after, so a
# path whose every step is ignored contains no push that is not, whatever the boundaries were. The
# union can only be LARGER than the push diffs (a change and its revert on the path cancel there
# but not here), so the error is always a refusal, which costs the grace and never a green.
#
# The path is the FIRST-PARENT one, and it must really reach the judged commit — two things the
# range alone does not give (ludics-lite#163 review, round 3). A commit's file list is its diff
# against its first parent, so only the first-parent chain is a path those diffs actually describe:
# a merge reached through its second parent hides, behind a docs-only first-parent diff, every
# source change the push carried from the judged tip. And after a force-push the judged commit is
# not an ancestor at all, so the three-dot range walks the tip side of a fork and never sees what
# the push removed — refused here both by `behind_by` and by a chain that cannot reach its base.
#
# The path must also be short and completely known: the commit list is one page, and a range
# longer than the cap goes to the grace rather than to a read per commit (GitHub's own rule is
# 1000 commits, above which a push runs whatever the filter says). A `total_commits` the returned
# list does not match is a truncated answer and settles nothing.
# range_files <judged sha> <tip>: every path changed anywhere on the first-parent path from the
# judged commit up to the tip, one per line, or nothing (exit 1) when the range is not evidence.
#
# The UNION rather than a list per commit, and that is not a weakening: "every commit's files are
# ignored" and "the union of the files is ignored" are the same claim, because a path is covered
# or it is not. Making it the union is what lets a caller with several workflows read the range
# ONCE and then ask each filter about the same lines — at the supported limits that is the
# difference between ~2100 requests and ~21, and the old shape spent them again every polling
# round inside the grace, which could turn the gate UNKNOWN on rate limits for exactly the heads
# the fast path exists to settle (review round 5).
range_files() {
  local vsha="$1" tip="$2" cmp count behind rows sha parent files steps out="" nl=$'\n'
  cmp=$(gh_retry read api "repos/$REPO/compare/$vsha...$tip?per_page=$IGNORE_MAX_COMMITS" \
    --jq '(.total_commits // 0 | tostring), ((.behind_by // -1) | tostring),
          ((.commits // [])[] | [.sha, ((.parents // [])[0].sha // "-")] | @tsv)') || return 1
  count="${cmp%%$nl*}"
  cmp="${cmp#*$nl}"
  behind="${cmp%%$nl*}"
  rows="${cmp#*$nl}"
  case "$count" in '' | *[!0-9]*) return 1 ;; esac
  # Not an ancestor: the judged commit is off to the side of a force-push, and the three-dot range
  # describes a fork rather than what the push did.
  [ "$behind" = 0 ] || return 1
  [ "$count" -gt 0 ] && [ "$count" -le "$IGNORE_MAX_COMMITS" ] || return 1
  [ "$(printf '%s\n' "$rows" | grep -c '^[0-9a-f]\{7,\}	')" -eq "$count" ] || return 1
  sha="$tip"
  steps=0
  while [ "$sha" != "$vsha" ]; do
    steps=$((steps + 1))
    [ "$steps" -le "$count" ] || return 1 # a chain longer than the range it walks: not a chain
    parent=$(awk -F'\t' -v s="$sha" '$1 == s { print $2; exit }' <<<"$rows")
    # A step off the listed range before reaching the judged commit: the path from it to the tip
    # is not the first-parent one (a merge reached through a second parent), so these first-parent
    # diffs do not describe it.
    case "$parent" in '' | -) return 1 ;; esac
    files=$(commit_files "$sha") || return 1
    # ANY file under the workflow directory, not just the one workflow whose filter is being
    # applied (review round 3). A range that edits a workflow is a range across two different
    # filters, and a range that ADDS one adds a workflow the repository's own list does not carry.
    ! grep -q '^\.github/workflows/' <<<"$files" || return 1
    out="${out}${files}"$'\n'
    sha="$parent"
  done
  [ "$steps" -gt 0 ] || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out" | grep .
}

# commits_ignored <patterns> <judged sha> <tip>: the range, read and then covered. cmd_base's
# caller, where each workflow brings its OWN judged commit and so its own range; the PR head's
# caller reads the one range itself and applies each filter to it.
commits_ignored() {
  local files
  files=$(range_files "$2" "$3") || return 1
  paths_ignore_covers "$1" "$files"
}

# tip_within_paths_ignore <rows> <tip>: rows are "<workflow id><TAB><name><TAB><judged sha>", one
# per workflow whose newest judged run trails the tip with no run at the tip at all. True when
# EVERY one of them is explained by its own filter — one workflow's docs-only diff says nothing
# about the workflow beside it — and the reason goes into PATHS_IGNORE_WHY for the settle line.
tip_within_paths_ignore() {
  local rows="$1" tip="$2" wfid name vsha key hit pats why=""
  PATHS_IGNORE_WHY=""
  [ -n "$rows" ] || return 1
  while IFS=$'\t' read -r wfid name vsha; do
    [ -n "$wfid" ] || continue
    # No judged run at all: there is no commit to diff the tip against, so nothing here can
    # explain the absence (and the report says "never judged here" regardless).
    case "$vsha" in '' | -) return 1 ;; esac
    key="$wfid/$vsha/$tip"
    hit=$(awk -F'\t' -v k="$key" '$1 == k { print $2; exit }' <<<"$BASE_IGNORE_CACHE")
    if [ -z "$hit" ]; then
      hit=no
      # The file's path leads the answer; the patterns are the rest of it.
      pats=$(workflow_paths_ignore "$wfid" "$tip") || pats=""
      if [ -n "$pats" ] && commits_ignored "$pats" "$vsha" "$tip"; then
        hit=yes
      fi
      BASE_IGNORE_CACHE="${BASE_IGNORE_CACHE}${key}"$'\t'"${hit}"$'\n'
    fi
    [ "$hit" = yes ] || return 1
    why="${why:+$why, }$name"
  done <<<"$rows"
  PATHS_IGNORE_WHY="$why"
  return 0
}

# --- which trigger can still create a run for THIS head ----------------------------------------
# Only three of a workflow's triggers have anything to do with the change under judgement, and the
# three are answered differently (ludics-lite#176, review round 1).
#
# `pull_request` is the one a filter can EXPLAIN. Its path filter is evaluated against the pull
# request's own two-dot diff, which the first-parent walk from the merge base up is a superset of,
# so a walk whose every step is ignored says the diff is — and it says so however the head got
# there, a force-push included, because the merge base is recomputed against the head in hand.
# The FILE, though, is not the head's: a `pull_request` run uses the workflow from the merge
# context, base merged with head, so a base-side edit that removed a paths-ignore takes effect
# while the head's own copy still carries it — and that edit is outside the walked range, so
# `commits_ignored`'s workflow-file guard never sees it (review round 2). The file is therefore
# read at the head AND at the base tip and the two must be identical: when both sides of a merge
# hold the same content, that content is what the merge produces, so the copy in hand IS the
# merge context's. Any difference, or a copy that cannot be read on either side, refuses.
#
# `push` is the one a filter CANNOT explain, and this is the finding that matters most in the
# round: a push event's changed files are computed between the push's own before and after, and
# after a NON-fast-forward push the before is not on the path walked here at all. Force-pushing a
# `src/` change away leaves a docs-only range whose push diff still carries that file — and
# therefore still creates a run. The pre-push SHA is in no feed this reads, so the push trigger is
# never explained by a filter. What can be established without it is whether the trigger is
# REACHABLE: a `branches:` list the head's own branch matches none of means no push to this branch
# reaches the workflow at all, whatever it changed. Anything else about `push` — no `branches:`, a
# `branches-ignore:`, a pattern that does not translate, a list the branch matches — refuses.
#
# `pull_request_target` refuses outright. GitHub runs it from the workflow file in the PR's BASE
# context, not the head's, so the file read here is not the file that decides; a base-side edit
# removing a paths-ignore is outside the walked range and `commits_ignored`'s workflow-file guard
# would not see it. It is rare enough that reading a second copy of the file is not worth the
# branch.
#
# EVERY OTHER EVENT REFUSES unless it is on the list below, and the list is now down to the two
# entries that can be defended from the shape of the event rather than from what has or has not
# happened yet. Three rounds running produced a member of the same class — round 1 that
# `merge_group` was wrongly counted, round 3 that the review events were wrongly ignored, round 4
# that `workflow_dispatch`, `schedule` and `workflow_run` were — and the third time is the signal
# that the list was the defect, not its contents. So the criterion is stated, and everything that
# does not meet it is gone:
#
#   an event is inert here only when a run of it can NEVER carry this commit as its head.
#
# `merge_group` meets it: its run is created after the PR enters a merge queue, at the queue's own
# temporary ref, and never at the PR head. `workflow_call` meets it: a called workflow produces no
# run of its own at all — its jobs appear inside the caller's run.
#
# `schedule`, `workflow_dispatch`, `repository_dispatch` and `workflow_run` did NOT meet it, and
# round 4 is right about why. Each of them CAN put a run on this head, and "the head's run list is
# empty" does not say one is not on its way — that emptiness is a not-created-yet window, which is
# the whole question. `workflow_dispatch` is the sharpest case: `gh workflow run --ref <branch>` is
# a validation somebody asked for by hand, and merging inside its creation window is exactly the
# thing the grace exists to prevent. `workflow_run` is the subtlest: `run_signal` drops ADVISORY
# runs before it counts, so a head carrying only the review app's run reaches here with runs=0
# while a downstream workflow waits on it. All four now refuse, and cost the grace.
HEAD_INERT_EVENTS='workflow_call merge_group'

# providers_are_actions_only: true when the newest MERGED pull request of this repository carries
# non-advisory check runs and every one of them was created by GitHub Actions. The recognition
# below reads WORKFLOWS, so it can only ever answer for Actions — and `build_checks` deliberately
# accepts every provider's check runs, so a repository with a third-party CI app has a second way
# to grow a check on a fresh head that no workflow filter describes (review round 2). That is the
# mirror of the rule ludics-lite#38 round 3 already holds in the other direction: an early Codecov
# green over an empty run list does not shortcut the grace either, because it proves nothing about
# Actions.
#
# It is a FILTER, not an inventory, and says so here because that is the honest description: no
# endpoint enumerates the check providers configured for a repository, so no read at any cost
# proves the negative. What it does is rule out the case that actually happens — a provider the
# repository is configured with, which therefore leaves check runs on its pull requests.
#
# A MERGED pull request's head is the population the question is about, and round 3 is why: a base
# branch tip, which this sampled first, is exactly where a provider that runs only on pull requests
# does not appear, and where a freshly pushed commit may not have its checks yet either. A merged
# PR's head is settled and is a pull request. No non-advisory row on it is no evidence and refuses,
# as does a read that fails, or a repository with no merged pull request to sample. Advisory names
# are dropped first, for the reason the list exists: the review app posts a check run of its own
# from a non-Actions app, and counting it would refuse on every repository this skill is used in.
#
# The residual is a provider configured but absent from that sample. It is named in ship-pr's
# SKILL.md beside the verdict, and `--require-green` — which refuses ABSENT outright — is the hatch
# for a merge that must have READ a green rather than found nothing.
providers_are_actions_only() {
  local sample raw total name slug seen=0
  sample=$(gh_retry read api \
    "repos/$REPO/pulls?state=closed&sort=updated&direction=desc&per_page=20" \
    --jq '[.[] | select(.merged_at != null) | .head.sha] | (.[0] // "")') || return 1
  case "$sample" in '' | *[!0-9a-f]*) return 1 ;; esac
  # The count leads the rows, and they have to agree, for the reason the workflow list's does
  # (review round 4): a large Actions matrix can fill one page while the third-party provider this
  # is looking for sits on the next, and a page read as the whole sample would report exactly the
  # answer that settles a head wrongly. Refused rather than paginated, so an incomplete sample
  # costs the grace like every other piece of missing evidence here.
  raw=$(gh_retry read api "repos/$REPO/commits/$sample/check-runs?filter=latest&per_page=100" \
    --jq '((.total_count // 0) | tostring),
          (.check_runs[] | [(.name // "-"), (.app.slug // "-")] | @tsv)') || return 1
  total="${raw%%$'\n'*}"
  raw="${raw#*$'\n'}"
  case "$total" in '' | *[!0-9]*) return 1 ;; esac
  [ "$total" -gt 0 ] || return 1
  [ "$(printf '%s\n' "$raw" | grep -c .)" -eq "$total" ] || return 1
  while IFS=$'\t' read -r name slug; do
    [ -n "$name" ] || continue
    is_advisory "$name" && continue
    [ "$slug" = github-actions ] || return 1
    seen=$((seen + 1))
  done <<<"$raw"
  [ "$seen" -gt 0 ]
}

# push_cannot_reach <workflow body> <head ref>: true when a push to this branch does not reach the
# workflow's `push` trigger, because it declares a `branches:` list and the branch matches none of
# its patterns. False for every other shape, including every shape this cannot read.
push_cannot_reach() {
  local body="$1" ref="$2" brs pat ere
  [ -n "$ref" ] || return 1
  # A branches-ignore: is a different filter with the opposite sense, and a workflow carrying one
  # is not described by the list above it. Present at all is a refusal.
  awk -v q="'" -v dq='"' -v want=push -v seq=branches-ignore \
    "$WORKFLOW_YAML_FILTER" <<<"$body" >/dev/null 2>&1 && return 1
  brs=$(awk -v q="'" -v dq='"' -v want=push -v seq=branches \
    "$WORKFLOW_YAML_FILTER" <<<"$body") || return 1
  [ -n "$brs" ] || return 1
  # Branch patterns use the same glob vocabulary the path filters do, so the same translation
  # reads them — and refuses, here as there, any pattern it does not carry: one read too narrowly
  # would report "cannot reach" for a trigger the branch does match.
  while IFS= read -r pat; do
    [ -n "$pat" ] || continue
    ere=$(glob_ere "$pat") || return 1
    printf '%s' "$ref" | grep -Eq -- "$ere" && return 1
  done <<<"$brs"
  return 0
}

# head_within_paths_ignore <head sha> <PR base sha> <PR head ref>: true when NO workflow of this
# repository can produce a run for this PR head — every trigger of every one of them is either one
# this change cannot fire, one this branch cannot reach, or one whose paths-ignore covers every
# commit the head adds over the merge base. The reason goes into PATHS_IGNORE_WHY.
#
# This is `checks`/`merge`'s end of ludics-lite#156's recognition (ludics-lite#176), and it refuses
# on the same evidence cmd_base's does, through the same helpers: the same YAML reader, the same
# glob translation, the same per-commit first-parent walk with the same cap, and the same rule that
# a workflow file changed inside the range is not one filter.
#
# The RANGE is the PR's own: the first-parent path from the MERGE BASE up. The merge base is read
# from the compare endpoint rather than assumed to be the PR's `base.sha`, which is the base
# BRANCH's tip and moves under every sibling merge — on a busy day that is most of the time, and
# taking it for the fork point would put commits of the base branch into the range.
#
# COST. Bounded, and paid only where it can change the answer: run_signal asks this only for a head
# with NO run at all and only while it is still inside the grace, so at most one attempt per round
# for the handful of rounds the grace spans. A refusal short-circuits at the first trigger that
# cannot be explained, which on a repository with no path filters at all is one workflow list and
# one workflow file. Nothing here is memoized, because run_signal is called from inside a command
# substitution where an assignment dies with the subshell (the trap BASE_RED_DETAIL documents).
head_within_paths_ignore() {
  local head="$1" base="$2" ref="$3" mbase wf total rows wid wname wstate wpath body bbody
  local rfiles declared bdeclared listed="" f evs ev pats why=""
  PATHS_IGNORE_WHY=""
  case "$head" in '' | *[!0-9a-f]*) return 1 ;; esac
  case "$base" in '' | *[!0-9a-f]*) return 1 ;; esac
  [ -n "$ref" ] || return 1
  mbase=$(gh_retry read api "repos/$REPO/compare/$base...$head" \
    --jq '.merge_base_commit.sha // ""') || return 1
  case "$mbase" in '' | *[!0-9a-f]*) return 1 ;; esac
  # A head that IS the merge base adds nothing, so there is no range to read and nothing here can
  # say why a run is missing.
  [ "$mbase" != "$head" ] || return 1
  # Everything below reads WORKFLOWS, so it can only answer for Actions. If this repository has a
  # second check provider, no filter here describes what it may still create.
  providers_are_actions_only || return 1
  # The count leads the rows, and they have to agree: this endpoint serves one page, and a
  # repository with more workflows than fit it would have the later ones silently left out — the
  # ones that CAN run for this head, while the ones read say they cannot (review round 1). A
  # truncated list is not a list of this repository's workflows.
  wf=$(gh_retry read api "repos/$REPO/actions/workflows?per_page=100" \
    --jq '((.total_count // 0) | tostring),
          (.workflows[] | [(.id | tostring), (.name // "-"), (.state // "-")] | @tsv)') || return 1
  total="${wf%%$'\n'*}"
  rows="${wf#*$'\n'}"
  case "$total" in '' | *[!0-9]*) return 1 ;; esac
  [ "$total" -gt 0 ] || return 1
  [ "$(printf '%s\n' "$rows" | grep -c '^[0-9][0-9]*	')" -eq "$total" ] || return 1
  # The range, ONCE: every workflow below asks its own filter about the same lines.
  rfiles=$(range_files "$mbase" "$head") || return 1
  # Every workflow FILE that the merge context will hold — the union of the two ends, since a
  # `pull_request` run sees the merge — has to be one the repository's list carries, or it is a
  # workflow nothing below examines while its first run is on its way (review round 5). The
  # head's set and the base's set are read separately because neither contains the other: a
  # workflow the base added after the fork is absent from the head, and one the head adds is
  # absent from the base.
  declared=$(workflow_files_at "$head") || return 1
  bdeclared=$(workflow_files_at "$base") || return 1
  while IFS=$'\t' read -r wid wname wstate; do
    [ -n "$wid" ] || continue
    # The path is read for EVERY listed workflow, advisory and disabled included, because what it
    # is collected for is the completeness check below: a file the list does not carry is the
    # danger, and an advisory workflow's file is carried just as much as any other's.
    wpath=$(workflow_path "$wid") || return 1
    listed="${listed}${wpath}"$'\n'
    is_advisory "$wname" && continue
    # Only an `active` workflow creates runs: one disabled, or listed after its file was deleted,
    # has no filter to read at this head and no run to wait for either.
    [ "$wstate" = active ] || continue
    body=$(workflow_body "$wpath" "$head") || return 1
    bbody=$(workflow_body "$wpath" "$base") || return 1
    [ "$body" = "$bbody" ] || return 1
    evs=$(awk -v q="'" -v dq='"' "$WORKFLOW_ON_EVENTS" <<<"$body") || return 1
    [ -n "$evs" ] || return 1
    while IFS= read -r ev; do
      [ -n "$ev" ] || continue
      case "$ev" in
      pull_request)
        pats=$(awk -v q="'" -v dq='"' -v want=pull_request -v seq=paths-ignore \
          "$WORKFLOW_YAML_FILTER" <<<"$body") || return 1
        [ -n "$pats" ] || return 1
        paths_ignore_covers "$pats" "$rfiles" || return 1
        ;;
      push) push_cannot_reach "$body" "$ref" || return 1 ;;
      *) case " $HEAD_INERT_EVENTS " in *" $ev "*) ;; *) return 1 ;; esac ;;
      esac
    done <<<"$evs"
    why="${why:+$why, }$wname"
  done <<<"$rows"
  # Nothing was examined — every workflow advisory, disabled, or the list a single empty row —
  # so nothing has been explained.
  [ -n "$why" ] || return 1
  # And nothing was MISSED: every workflow file at either end of the merge is one the list carried,
  # so the loop above spoke for all of them.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -qxF -- "$f" <<<"$listed" || return 1
  done <<<"$declared"$'\n'"$bdeclared"
  PATHS_IGNORE_WHY="$why"
  return 0
}

cmd_base() {
  local branch="""" tip raw rc line name status sha concl csha cwhen curl red=0 pend=0 out=""
  local allruns="" wfid
  local vconcl vsha vwhen vurl stopped_note wait_for=0 inflight=0 uncovered=0 red_at_tip=0
  local nogo_at_tip=0 last_tip="" grace_from confirm wf="" wid wname part sleep_for remaining
  local norun=0 tip_seen_at tip_age hold ebranch
  local tip_unjudged=0 unrun_rows="" settle_why
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
  # A --wait sized to outlive the absence grace, but not by a whole round, cannot reach the round
  # that settles (ludics-lite#175). The grace is only ever tested once per round, after that
  # round's own API calls, and rounds are one CHECKS_INTERVAL apart — so between the round before
  # the grace expires and the one after it lies a whole interval, and a ceiling landing inside
  # that interval ends the wait at NO VERDICT for a tip whose absence the next round would have
  # settled. `--wait=301` over a 300s grace was exactly that, and read as a red-adjacent refusal
  # by every caller of the wave gate.
  #
  # A --wait at or BELOW the grace is not that mistake and is not refused: it is a bounded peek —
  # "tell me what you have within N seconds" — which cannot settle an absence and says so, exit 4.
  # Only the band between the grace and one round past it is a number that means to outlive the
  # grace and cannot.
  # A zero grace is outside the band entirely: with nothing to outlive, the absence is eligible
  # to settle on the FIRST round, so every positive ceiling reaches it and `--wait=30` over
  # `SHIP_PR_BASE_ABSENT_GRACE=0` is a perfectly good bounded wait for what is in flight (review
  # round 1). The band is about a grace a ceiling has to outlast, and there is none.
  if [ "$ABSENT_GRACE" -gt 0 ] && [ "$wait_for" -gt "$ABSENT_GRACE" ] &&
    [ "$wait_for" -lt $((ABSENT_GRACE + CHECKS_INTERVAL)) ]; then
    die "base: --wait=$wait_for cannot outlive the ${ABSENT_GRACE}s absence grace it is sized" \
      "against. The absence of a run for the tip is only settled on the round AFTER the grace" \
      "expires, and a round is one ${CHECKS_INTERVAL}s poll interval, so a ceiling in" \
      "($ABSENT_GRACE, $((ABSENT_GRACE + CHECKS_INTERVAL))) always arrives first and reports NO" \
      "VERDICT for a tip that was about to settle (ludics-lite#175). Use --wait of at least" \
      "$((ABSENT_GRACE + CHECKS_INTERVAL)) (SHIP_PR_BASE_ABSENT_GRACE + SHIP_PR_CHECKS_INTERVAL)," \
      "or --wait of at most $ABSENT_GRACE for a bounded peek that does not claim to settle one."
  fi
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
    tip_unjudged=0 unrun_rows=""
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
      # first-listed one's green masking the other still running or red (round 9). This is the
      # whole reason either fold over workflow runs carries an id at all; run_signal's keys on it
      # too, with an event alongside for a feed that spans every event at one head.
      part=$(gh_retry read api \
        "repos/$REPO/actions/workflows/$wid/runs?branch=$ebranch&event=push&per_page=10" \
        --jq '.workflow_runs[] | [(.workflow_id | tostring), .name, .status,
              (.conclusion // "pending"), .head_sha, .created_at, (.html_url // "-"),
              (.id | tostring)] | @tsv')
      rc=$?
      [ "$rc" -eq 0 ] || fail 3 "could not read $REPO's '$wname' runs on $branch" \
        "($(gh_err_line)); the base's health is UNKNOWN, which is NOT 'green'."
      if [ -n "$part" ]; then
        # This workflow's rows are ordered before either reader below sees them (see
        # newest_first): the fold's newest / newest-completed / newest-judged columns, and
        # base_red_detail's walk for where a red streak starts, both keep whichever row of a
        # same-second tie they see first. Two pushes to this branch inside one second is rarer
        # than the two dispatches ludics-lite#83 was about, but the verdict is decided by luck
        # just the same. The page's own newest-first order stays load-bearing ABOVE the sort, and
        # the contract still pins it: WHICH ten rows a `per_page=10` page holds depends on it.
        # Sorting each workflow's page on its own, rather than the assembled rows, leaves the
        # report's per-workflow lines in the order the workflow list gave them.
        part=$(newest_first 6 8 <<<"$part")
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
      # The unfolded rows are kept: the fold answers "is this base broken", and base_red_detail
      # then walks the SAME rows backwards for a red workflow to find where the red started. One
      # read, two questions; re-fetching for the second would ask the API about a branch that may
      # have moved between the two calls.
      allruns="$raw"
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
            # The grouping key rides LAST, so the column numbers every other reader of this fold
            # counts on (the tip_seen_at scan below reads $5 and $6) are where they were.
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", nm[k], lstatus[k], lsha[k],
              (k in done ? c[k] : "pending"), (k in done ? csha[k] : "-"),
              (k in done ? cw[k] : "-"), (k in done ? cu[k] : "-"),
              (k in vdone ? v[k] : "-"), (k in vdone ? vs[k] : "-"),
              (k in vdone ? vw[k] : "-"), (k in vdone ? vu[k] : "-"), k } }
      ' <<<"$raw")
      while IFS=$'\t' read -r name status sha concl csha cwhen curl vconcl vsha vwhen vurl wfid; do
        [ -n "$name" ] || continue
        is_advisory "$name" && continue
        [ "$status" = completed ] || inflight=$((inflight + 1))
        if [ -n "$tip" ] && [ "$vsha" = "$tip" ]; then
          : # this workflow's newest judged run is about the tip: covered
        else
          uncovered=$((uncovered + 1))
          # WHICH absence, per workflow, because only one of the two can ever be explained. A run
          # for the tip EXISTS and has not judged it (queued, running, or stopped) — nothing but
          # that run can answer, so the wait keeps waiting. Or no run for the tip exists at all,
          # which is either the not-created-yet window or a push the workflow's filter skips: the
          # settle below is about exactly those. Read off the unfolded rows, since the fold keeps
          # only the newest of each kind and an older row at the tip counts just as much.
          if awk -F'\t' -v w="$wfid" -v t="$tip" \
            '$1 == w && $5 == t { found = 1 } END { exit !found }' <<<"$allruns"; then
            tip_unjudged=$((tip_unjudged + 1))
          else
            unrun_rows="${unrun_rows}${wfid}"$'\t'"${name}"$'\t'"${vsha}"$'\n'
          fi
        fi
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
          # WHICH job, and SINCE WHEN: what an owner of the red needs before anything else, and
          # what the run-level line above cannot say (ludics-lite#73).
          base_red_detail "$wfid" "$allruns"
          out="${out}${BASE_RED_DETAIL}"
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
      # A MOVE restarts the grace; the FIRST observation does not. `now` here is read after the
      # round's own API calls, so re-stamping it on round one spends that round's latency out of
      # the grace — which is how `--wait=301` over a 300s grace could never reach it: the ceiling
      # arrived a few seconds before the clock it was sized against, every time (ludics-lite#156).
      [ -z "$last_tip" ] || grace_from=$now
      last_tip="$tip"
    fi
    if [ "$inflight" -eq 0 ] && [ "$uncovered" -eq 0 ]; then
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
        *) [ "$tip_age" -ge "$ABSENT_GRACE" ] || hold=1 ;;
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
    # Every workflow still trailing the tip simply has NO run for it: nothing is coming that this
    # wait could receive. That is the shape the header promises a settle for, and it is the shape
    # a docs-only push leaves behind — ludics-lite#156, where a `--wait` sat on one to its ceiling
    # and refused a dispatch the plain read had already settled. Two things end it. The filter
    # says outright that no run can be created for this tip, which needs no clock at all; or the
    # absence outlives the run-creation grace, which is all that separates "never coming" from
    # "not yet". Either way the settle is for the verdicts in hand, and the per-workflow lines
    # name which commit each of them is actually about.
    #
    # Three shapes do NOT settle here, and each is a different thing the wait is still owed.
    # A run that EXISTS for the tip and has not judged it — queued, running, or completed
    # stopped-not-judged — existed, so no filter explains it, and only that run can answer; a
    # stopped one gets the grace for a superseding replacement, and then the verdict is "none".
    # A run in flight ANYWHERE on this branch is judging a tree the tip contains (on a branch
    # this command reads, an older run's commit is an ancestor of the tip): settling for a green
    # under it would hand out an all-clear for a tree whose verdict is minutes away, and waiting
    # for it does better than settle — when it lands, its own commit is what the tip's absence
    # then trails. That is the honest reading of a `--wait`, and it is not what parked the 09-15
    # wave: the tip there was never going to get a run at all.
    # And a listed workflow with NO push run on this branch at all (norun) is not in the fold, so
    # no filter of its was read: it may be dispatch- or schedule-only, or it may be a workflow the
    # tip itself just added whose first run is on its way. The FAST settle cannot speak for it —
    # a docs-only diff under one workflow's filter says nothing about a filter nobody read — so
    # only the grace, which is that newcomer's creation window, may settle a repo carrying one.
    elif [ "$uncovered" -gt 0 ] && [ "$tip_unjudged" -eq 0 ] && [ "$inflight" -eq 0 ]; then
      settle_why=""
      if [ "$norun" -eq 0 ] && tip_within_paths_ignore "$unrun_rows" "$tip"; then
        settle_why="(every commit on the first-parent path from the judged commit up to the tip changes only paths within the paths-ignore of $PATHS_IGNORE_WHY, so no run for it is coming — the verdicts above are about the commit each line names)"
      elif [ $((now - grace_from)) -ge "$ABSENT_GRACE" ]; then
        settle_why="(waited $(((now - started) / 60)) min: no run for the tip appeared and none is in flight for it — the verdicts above may trail it)"
      fi
      # The same TOCTOU the covered break answers, and for the stronger reason: this settle
      # accepts verdicts about an OLDER commit, so a push landing between the tip read and here
      # would settle for a green two commits back. On a moved or unreadable tip, poll again — the
      # tip-change branch above restarts the grace for the successor.
      if [ -n "$settle_why" ]; then
        confirm=$(gh_retry read api "repos/$REPO/commits/$ebranch" --jq .sha) || confirm=""
        if [ "$confirm" = "$tip" ]; then
          waited_note="$settle_why"
          break
        fi
      fi
    elif [ "$inflight" -eq 0 ] && [ "$nogo_at_tip" -gt 0 ] &&
      [ $((now - grace_from)) -ge "$ABSENT_GRACE" ]; then
      waited_note="(the tip's newest run completed stopped-not-judged and no replacement appeared within the grace — NOT absence and NOT a verdict: re-run the workflow)"
      no_tip_verdict=1
      break
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
  rounds) shift && cmd_rounds "$@" ;;
  checks) shift && cmd_checks "$@" ;;
  merge) shift && cmd_merge "$@" ;;
  base) shift && cmd_base "$@" ;;
  reply) shift && cmd_reply "$@" ;;
  resolve) shift && cmd_resolve "$@" ;;
  comment) shift && cmd_comment "$@" ;;
  retry) shift && cmd_retry "$@" ;;
  *) die "usage: pr-review.sh [--repo owner/name] {poll|watch|status|rounds|checks|merge|reply|resolve} <pr> ...
  pr-review.sh comment <pr> <body>           # a plain PR comment (a summary round, a review nudge)
  pr-review.sh base [owner/name] [branch] [--wait]  # is the base branch's CI green? (start of
                                             # work; --wait = post-merge integration read)
  pr-review.sh retry [--read] <gh args...>   # any other gh call, same retry policy
  pr-review.sh retry run watch owner/name#<run-id>  # quiet await of ONE run (never forwarded
                                             # to gh); for a PR prefer: checks <pr> --wait
  <pr> is owner/name#number, or a number with --repo/REPO= naming the repo; a bare number with
  no repo named is REFUSED, never resolved from the cwd (a PR number names one PR in every repo).
  The run argument takes the same form, and a bare run id without -R/REPO is refused." ;;
  esac
}

# Focused tests source the functions and replace gh with a fixture transport; do not expose a
# user-facing testing subcommand or make them pass through the unrelated build and merge gates.
[ "${SHIP_PR_TEST_SOURCE_ONLY:-}" = 1 ] || main "$@"
