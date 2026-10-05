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
#     round with findings. Hence the `failed` state below (ludics-lite#78), which also covers
#     the connector's "To use Codex here, create an environment for this repo" (ludics-lite#421);
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
#                                          # the wait continues; every exit names what it ends on,
#                                          # and one on reviewer activity carries a `watch-rounds:`
#                                          # line above the watermark (see count_token)
#   pr-review.sh status <pr>               # merge gate + who owes what: approved / unresolved
#                                          # (approved over open review threads) / reviewing /
#                                          # stalled / failed / expected / idle / unknown — and
#                                          # the round count against the threshold (see `rounds`);
#                                          # says CONFLICTS when GitHub cannot build the merge
#                                          # commit (nothing tests the head merged with the base,
#                                          # and a push gets no run at all, until the base is in)
#   pr-review.sh rounds <pr>               # how many review rounds carried findings, read off the
#                                          # PR (heads the reviewer left comments on), against
#                                          # SHIP_PR_ROUND_THRESHOLD; exit 1 past it; ends with a
#                                          # `rounds: n=… threshold=…` trailer (see count_token)
#   pr-review.sh checks <pr> [--wait]      # the BUILD signal on the head commit: green / red /
#                                          # no verdict yet / absent; ends with a
#                                          # `checks: verdict=…` trailer (see count_token)
#   pr-review.sh merge <pr> [--override "<why this red is unrelated>"] [--wait]
#                           [--allow-no-verdict] [--require-green]
#                                          # checks, then merge; refuses on an open review thread
#                                          # (no flag bypasses that), on red without --override,
#                                          # on NO verdict without --allow-no-verdict, and — with
#                                          # --require-green (a close-out merge) — on ABSENT, on
#                                          # green-by-skips-only, on --auto, on a base with a
#                                          # merge queue, and on a deferred auto-merge (which it
#                                          # disables again); and WARNS
#                                          # loudly when the branch is far behind its base.
#                                          # --override waives exactly the reds of the gate's
#                                          # FIRST read (by check suite and name), never a check
#                                          # with no verdict yet: that one is waited for under
#                                          # --wait and refused with 4 without it, and a check
#                                          # that turns red during the wait was never waived, so
#                                          # it refuses with 1 (ludics-lite#392)
#   pr-review.sh base [owner/name] [branch] [--wait[=seconds]] [--interim]
#                                          # is the branch you are about to work off CI-green?
#                                          # --wait holds until the CURRENT tip has its verdict —
#                                          # the post-merge integration read (see cmd_base).
#                                          # A red names the failing JOB and how far back the red
#                                          # runs go, so the report is an owner's starting point
#                                          # and not just a workflow name (see base_red_detail);
#                                          # `.github/workflows/base-watch.yml` runs it daily on
#                                          # this repository's own main and files what it finds.
#                                          # A workflow that no longer runs on push is judged at
#                                          # the tip by a NAMED source or not at all (ludics-lite
#                                          # #401): the merged PR's head run, or a coordinator's
#                                          # [--integration-records <file>] (fleet-worker gate)
#                                          # --interim: a tip whose own push run is in flight is
#                                          # green by a NAMED source meanwhile (the merged PR's
#                                          # head run), never the tip's own verdict; opt-in, for
#                                          # the gate and the base watch (ludics-lite#308)
#   pr-review.sh reply <pr> <comment-id>[+<comment-id>...] <body> [--allow-mention]
#                                          # the id token poll rendered. A FOLDED entry names
#                                          # several: the body goes to the first thread and each
#                                          # duplicate gets a one-line pointer to that reply, from
#                                          # this one invocation. A body mentioning '@codex' is
#                                          # refused unless --allow-mention (see prreview/reply.py)
#   pr-review.sh reply <pr> <comment-id>[+...] --anchor <comment-id>
#                                          # no body: the answer already stands in <comment-id>'s
#                                          # thread, and every id in the token is pointed at it.
#                                          # What a batch that failed part-way is retried with
#   pr-review.sh resolve <pr> <comment-id>[+<comment-id>...]
#                                          # the same token; every thread it names is closed
#   pr-review.sh comment <pr> <body> [--allow-mention]
#                                          # a plain PR comment, for what has no thread to reply in:
#                                          # a review SUMMARY's findings, or a '@codex review' nudge
#                                          # (the one body that may mention '@codex' without the
#                                          # flag; see prreview/reply.py)
#   pr-review.sh body <pr> <file>          # replace the PR's description with the file's content,
#                                          # over REST: `gh pr edit --body-file` rides GraphQL and
#                                          # fails on a repo whose PRs trip the classic-Projects
#                                          # deprecation (see cmd_body). Prints the PR's URL
#   pr-review.sh retry [--read] <gh args...>
#                                          # any other gh call (pr merge, api) with the same retry
#                                          # policy, instead of a hand-rolled loop. gh refusing
#                                          # the arguments itself (an unknown flag or --json
#                                          # field) sent nothing: exit 2, never retried
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
#      90), WATCH_TIMEOUT=seconds to watch (900), SHIP_PR_REVIEW_POLL_CAP and
#      SHIP_PR_BUILD_POLL_CAP=seconds the pause between unchanged polls doubles up to (300 for
#      `watch`, 600 for a `--wait`), SHIP_PR_STATE_DIR=where the quota hold and the observer locks
#      live (default ${XDG_STATE_HOME:-~/.local/state}/ship-pr; see "the polling budget"),
#      SHIP_PR_API_ATTEMPTS=tries per gh call (4), SHIP_PR_API_BACKOFF=first pause in seconds (5,
#      doubling to a 20s cap: ~35s of retrying before a call is declared dead),
#      SHIP_PR_REVIEW_GRACE=seconds a due-but-unstarted review is waited for before `watch` returns
#      saying so (1200), SHIP_PR_REVIEW_STALL=seconds a live 👀 may run before it gets the same
#      verdict (2×GRACE). Both are measured from the PR's own timestamps, not from when the watch
#      started, so they are reached ACROSS windows — a 900s window cannot outrun a 1200s grace.
#      SHIP_PR_ADVISORY_CHECKS=ERE of check, job and workflow names the build gate ignores
#      (default: the review app's check and the github-pages deploys) — a run whose red is
#      explained entirely by advisory JOBS is not a red build signal either, and a run still in
#      flight whose every unfinished job is advisory does not hold a `--wait` once its finished
#      non-advisory jobs are all green and its job list has been still for a minute
#      (ludics-lite#500; run_inflight_is_advisory_only). BOUNDARY: GitHub creates a
#      `needs:`-blocked job only once its dependencies finish, so a required job that `needs:` an
#      advisory one is not visible while that advisory job runs — such a workflow is released
#      early. A required job must not `needs:` an advisory one. A value REPLACES the default list,
#      so a caller that adds names spells the default's in too. A repository can set its own list
#      for `checks` and `merge` instead: one ERE per line in .github/ship-pr-advisory-checks on
#      its default branch, read before the gate (ludics-lite#530; advisory_policy). That keeps the
#      merge command bare. The variable, when set, still wins over the file, and `base` reads
#      only the variable and the default.
#      SHIP_PR_CHECKS_WAIT=seconds `--wait` holds
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
#      band (grace, grace+SHIP_PR_CHECKS_INTERVAL) is WARNED about: it reaches the settle only on
#      the single round the ceiling cap schedules, and only if the tip has not moved
#      (ludics-lite#175). `checks`/`merge` apply the
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
  # After gh refused one of this script's own calls, that refusal is the command's one outcome
  # (gh_refused_own): a verdict composed from the call it stopped would be about nothing.
  [ ! -s "${GH_REFUSED_FILE:-}" ] || exit 2
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

# --- jq's line ending (ludics-lite#335) -------------------------------------------------------
# A native jq.exe on Windows (winget, Chocolatey, Scoop; Git for Windows ships no jq) writes its
# stdout in text mode and ends every line CRLF. Every line but a `$(...)`'s last keeps its \r, so
# a conclusion read off a list is `failure\r`, not red, and a decision takes the wrong branch, at
# any of this script's ~100 jq calls. So every call goes through `jq` below, and the line
# ending is decided ONCE, here, by asking the jq on PATH:
#   lf      it writes LF already (every Unix jq, an MSYS2 jq): called as is, no cost;
#   binary  it writes CRLF and `-b` (jq 1.7+ on Windows) turns that off: called with `-b`, which
#           costs no process, where a filter would cost a fork per call on the slowest-forking
#           platform there is;
#   strip   it writes CRLF and refuses `-b` (jq 1.6): its output goes through `tr -d '\r'`. That
#           takes a CRLF inside a raw string (a comment body's line ends) to LF as well, which
#           nothing here reads as data. It is not `sed 's/\r$//'`, which keeps that CRLF on Unix
#           but lost it on the Git Bash leg all the same, where MSYS sed read the \r away: the
#           one platform that takes this path gets the same answer either way, and tr says so.
# `jq_lf` is the call and `jq` names it, so the fixtures' jq shim (test-pr-review-lib.sh), which
# replaces `jq`, forwards to `jq_lf` and keeps the line ending. A jq that is missing or broken
# probes as `lf`, and the first real call then fails as it did before this.
JQ_EOL=lf
# The probe counts the bytes of `"x"` through a pipe (3 is x\r\n) rather than comparing a
# `$(...)`: Git Bash's command substitution drops a trailing \r with the \n, so `$(jq -rn '"x"')`
# reads `x` from the very jq.exe that writes x\r\n. There a single value read back clean all
# along; a multi-line read, a `while read` and a pipe did not.
jq_eol_probe() {
  local n
  JQ_EOL=lf
  n=$(command jq -rn '"x"' 2>/dev/null | wc -c) || return 0
  [ "$((n))" -eq 3 ] || return 0
  n=$(command jq -b -rn '"x"' 2>/dev/null | wc -c) || n=0
  if [ "$((n))" -eq 2 ]; then JQ_EOL=binary; else JQ_EOL=strip; fi
}
jq_lf() {
  case "$JQ_EOL" in
  lf) command jq "$@" ;;
  binary) command jq -b "$@" ;;
  *) jq_lf_strip "$@" ;;
  esac
}
# A subshell with its own `pipefail`, so jq's failure is the call's status whatever options the
# caller runs under. Not PIPESTATUS: a PIPESTATUS the environment exports shadows bash's own, and
# it then never moves (run-pr-review-hostile.sh exports one, and every read here saw `hostile`).
jq_lf_strip() (
  set -o pipefail
  command jq "$@" | tr -d '\r'
)
jq() { jq_lf "$@"; }
jq_eol_probe

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
# gh_refused_own's message, when gh refused one of this script's own calls (see there).
GH_REFUSED_FILE="${TMPDIR:-/tmp}/pr-review-refused.$$"
rm -f "$GH_REFUSED_FILE"
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
  rm -f "$GH_ERR_FILE" "$GH_REFUSED_FILE"
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

# Did GraphQL answer with an error whose answer is FIXED, one that re-sending the same query can
# never change (ludics-lite#422)? GraphQL validates a query before it runs any of it, so such a
# query did nothing. Retried as transport, a query-cost rejection spent four attempts and ~35s and
# then reported "the API never answered" — which it had.
#
# The boundary. This reads ONE line, the first line of gh's stderr, where gh prints a GraphQL
# error's message after `gh: ` (`gh api graphql`) or `GraphQL: ` (every other gh command). It is a
# fail-closed ALLOWLIST of whole-line shapes, each copied from a real failing call:
#   the node limit    By the time this query traverses to the <c> connection, it is requesting up
#                     to <n> possible nodes which exceeds the maximum limit of <n>.
#   the page limit    Requesting <n> records on the `<c>` connection exceeds the `first|last`
#                     limit of <n> records.
#   an unknown field  Field '<f>' doesn't exist on type '<T>'
#   a parse error     Expected <tokens>, actual: <TOKEN> ("<text>") at [<line>, <column>]
# It deliberately does not read stdout (a read's data can quote any of these sentences), the lines
# after the first, a message carrying gh's ` (<path>)` suffix, several errors gh joined onto one
# line, gh's own client-side refusals (`Unknown JSON field`), or any other GraphQL message. Those
# keep the classification they had, and that direction is the point: a fixed shape this misses
# costs only the retries it always cost, while a transient failure read as fixed would turn an
# unanswered read into a false fact (exit 1).
graphql_fixed_answer() {
  local msg re
  case "$1" in
  "gh: "*) msg="${1#gh: }" ;;
  "GraphQL: "*) msg="${1#GraphQL: }" ;;
  *) return 1 ;;
  esac
  for re in \
    '^By the time this query traverses to the [A-Za-z0-9_]+ connection, it is requesting up to [0-9,]+ possible nodes which exceeds the maximum limit of [0-9,]+\.$' \
    '^Requesting [0-9,]+ records on the `[A-Za-z0-9_]+` connection exceeds the `(first|last)` limit of [0-9,]+ records\.$' \
    "^Field '[A-Za-z0-9_]+' doesn't exist on type '[A-Za-z0-9_]+'$" \
    '^Expected [A-Za-z_ ,]+, actual: ([A-Z_]+|\(none\)) \(".*"\) at \[[0-9]+, [0-9]+\]$'; do
    [[ "$msg" =~ $re ]] && return 0
  done
  return 1
}

# Did gh refuse the ARGUMENTS itself, before it sent anything (ludics-lite#452)? gh validates its
# flags, its argument count and its `--json` field names before it makes a request, so such a
# refusal is a caller error: re-sending prints it again, and the API never saw the call. Retried as
# transport, `gh pr view 1 --json nosuchfield` spent four attempts and then reported "the API never
# answered", which tells an obedient caller to re-arm forever.
#
# The boundary. This reads ONE line, the first line of gh's stderr, where gh prints the refusal
# with no prefix, and only for a call gh_api_only_command (below) lets it read. It is a
# fail-closed ALLOWLIST of whole-line shapes, each copied from a real call to gh 2.101.0 that sent
# no request:
#   Unknown JSON field: "<field>"                              --json with a field gh lacks
#   Specify one or more comma-separated fields for `--json`:   --json with no value
#   unknown flag: --<name>                                     a long flag the command lacks
#   unknown shorthand flag: '<c>' in -<cs>                     a short one
#   flag needs an argument: --<name>  /  '<c>' in -<c>         a flag missing its value
#   invalid argument "<v>" for "[-<c>, ]--<name>" flag: <why>  a value the flag cannot take
#   accepts [at most ]<n> arg(s), received <m>                 the wrong number of arguments
#   requires at least <n> arg(s), only received <m>            too few, on a minimum-count command
#   bad flag syntax: --=<x>  /  ---<x>                         a long flag with no name
#   unknown command "<x>" for "gh <cmd>..."                    a subcommand gh does not have
# A mistyped flag's name is whatever the caller typed up to an `=`, punctuation included
# (`--foo_bar`, `--foo.bar`, `-_`); one holding whitespace is not read. The line deliberately does
# not read stdout, the lines after the first, a line behind a prefix (`gh: `, `GraphQL: `: those
# are the API's words, which can quote any of these), or any other client-side message. A jq
# expression gh could not parse can be reported AFTER the request was sent (`gh pr view 1 --jq
# '.['` answers with the API's own error first), a write's included, and the rest (`flags required
# when not running interactively`, `cannot use --web with --json`, ...) are not on the list. Those
# keep the classification they had. Cobra's other count refusals (`accepts between <n> and <m>
# arg(s)`, ...) are not on the list until a real call shows one verbatim.
#
# Two kinds of argument are read this way. A caller's, through cmd_retry, where the refusal is the
# caller's usage error (exit 2, said by cmd_retry). And this script's own (ludics-lite#471), where
# it means the installed gh no longer takes an argument the script sends, a field or a flag a gh
# upgrade renamed: retried as transport, `watch`, `merge` and the run await each reported "the API
# never answered", and a caller obeying exit 3 re-armed forever. That refusal stops the whole
# command at once with exit 2 (gh_refused_own, below).
gh_client_refusal() {
  local re
  for re in \
    '^Unknown JSON field: "[^"]+"$' \
    '^Specify one or more comma-separated fields for `--json`:$' \
    '^unknown flag: --[^[:space:]=]+$' \
    "^unknown shorthand flag: '[^'[:space:]]' in -[^[:space:]]+\$" \
    "^flag needs an argument: (--[A-Za-z0-9][A-Za-z0-9-]*|'[A-Za-z0-9]' in -[A-Za-z0-9])\$" \
    '^invalid argument ".*" for "(-[A-Za-z0-9], )?--[A-Za-z0-9][A-Za-z0-9-]*" flag: .+$' \
    '^accepts (at most )?[0-9]+ arg\(s\), received [0-9]+$' \
    '^requires at least [0-9]+ arg\(s\), only received [0-9]+$' \
    '^bad flag syntax: --[-=][^[:space:]]*$' \
    '^unknown command "[^"]+" for "gh( [a-z][a-z-]*)+"$'; do
    [[ "$1" =~ $re ]] && return 0
  done
  return 1
}

# Is the call's command one whose whole run is gh's own parse and API calls, so that its stderr
# is gh's own? A command gh does not have is an alias or an extension, which gh hands every
# argument: its stderr is arbitrary code's, which can write to GitHub and then print a gh-shaped
# `unknown flag:` line. And some built-ins run another program after a write (`repo fork --clone`
# runs git once the fork exists, `pr merge --delete-branch` once the merge landed). So this is a
# fail-closed ALLOWLIST of command paths, read off gh 2.101.0's own command lists: whole commands
# with no subcommand that runs another program, and, of the rest, the subcommands that run none.
# Left off, and so keeping today's classification: `pr checkout|create|merge|close|diff|revert`,
# `issue develop`, `run download` (`run watch` is the await above), `repo clone|create|fork|
# rename|set-default|sync`, `release create|download`, `gist clone|edit|rename`, and `extension`,
# `alias`, `copilot`, `codespace`, `preview`, `browse` and every other command not named. A
# built-in cannot be taken over: gh 2.101.0 refuses the alias (`Could not create alias pr: already
# a gh command or extension`), and `gh help extension` states that an extension cannot override a
# core command (one that clashes runs only through `gh extension exec`). What this does not read:
# a flag that starts a program inside a listed subcommand (`--editor`, `--web`), which runs it
# before the call writes anything, in a mode a scripted retry does not use; and a subcommand named
# after a flag the parent takes (`gh pr -R o/r view`), which reads as unlisted. `discussion` stays
# off although gh 2.101.0's preview command runs no other program (ludics-lite#468): it is new
# enough that an older gh hands `gh discussion` to an installed `gh-discussion` extension, and
# arbitrary code there can write and then print an allowlisted line (review of #490).
# This list gates a CALLER's arguments only. The script's own calls are not read through it: they
# are written in this file, as `api`, `run view` and `pr merge` with no `--delete-branch`, none of
# which runs another program. A `merge` that forwards the caller's own `gh pr merge` flags (after
# `--`) makes that call a caller's, and it is read as unlisted (review of #490).
gh_api_only_command() {
  case "${1:-}" in
  api | status | search | org | project | label | cache | ruleset | secret | variable | ssh-key | \
    gpg-key) return 0 ;;
  esac
  case "${1:-} ${2:-}" in
  "pr list" | "pr status" | "pr checks" | "pr comment" | "pr edit" | "pr lock" | "pr ready" | \
    "pr reopen" | "pr review" | "pr unlock" | "pr update-branch" | "pr view") return 0 ;;
  "issue create" | "issue list" | "issue status" | "issue close" | "issue comment" | \
    "issue delete" | "issue edit" | "issue lock" | "issue pin" | "issue reopen" | \
    "issue transfer" | "issue unlock" | "issue unpin" | "issue view") return 0 ;;
  "run cancel" | "run delete" | "run list" | "run rerun" | "run view") return 0 ;;
  "workflow disable" | "workflow enable" | "workflow list" | "workflow run" | \
    "workflow view") return 0 ;;
  "repo list" | "repo archive" | "repo autolink" | "repo delete" | "repo deploy-key" | \
    "repo edit" | "repo gitignore" | "repo license" | "repo read-dir" | "repo read-file" | \
    "repo unarchive" | "repo view") return 0 ;;
  "release list" | "release delete" | "release delete-asset" | "release edit" | "release upload" | \
    "release verify" | "release verify-asset" | "release view") return 0 ;;
  "gist create" | "gist delete" | "gist list" | "gist view") return 0 ;;
  esac
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

# gh's refusal of an argument THIS SCRIPT sends (ludics-lite#471). It is not the caller's error,
# not transport and not GitHub's answer: the installed gh no longer takes something this file
# wrote, and every later run hits the same refusal. So it ends the whole command, exit 2, rather
# than the call: most calls run inside a command substitution, whose caller would read a failed
# call as an unanswered one, and a `watch` would hold its window blind and report exit 3, the code
# that says re-arm. The pieces:
#   GH_REFUSED_FILE  holds the message, so a subshell's refusal is visible to its parents (the
#                    same subshell reason as GH_ERR_FILE). Cleared at source time, since a pid a
#                    killed run left one under would otherwise stop a later run before its first
#                    call; removed by the EXIT trap.
#   GH_REFUSAL_PID   main's pid, set by main with the USR2 trap that prints the message and exits
#                    2. A refusal in any subshell signals it, so main stops when the substitution it
#                    is waiting on returns, without running its next command.
#   gh_retry         makes no call once the file holds a refusal, so a subshell that outlives one
#                    sends nothing more; and `fail` exits 2 in silence then, so no verdict about
#                    the PR (exit 1, 3 or 4) is printed over it.
# Sourced without main (the suites, pr-review-api-contract.sh), there is no pid to signal: the
# refusal prints its message itself, and the caller's `fail` turns into the exit 2.
GH_REFUSAL_PID=""
gh_refused_own() { # <gh args...>, of the refused call
  local call="" arg prev=""
  # A field's VALUE is payload, not the call's shape: a reply's or a comment's text, a body file's
  # path, a GraphQL query. Logged, it would copy text that was never posted into a worker's or CI's
  # log (review of #490), and the field's name is enough to find the call in this file. This file
  # passes every field as a separate `-f`/`-F` argument, which is the one form read here.
  for arg in "$@"; do
    case "$prev" in
    -f | -F | --field | --raw-field) call+=" $(printf '%q' "${arg%%=*}")=..." ;;
    *) call+=" $(printf '%q' "$arg")" ;;
    esac
    prev="$arg"
  done
  # A long --jq filter: enough of the call to find it, not the whole filter.
  [ "${#call}" -le 240 ] || call="${call:0:240}..."
  printf '%s\n' "pr-review.sh: the installed gh refused this script's own call, which sent \
nothing: gh${call} -> $(gh_err_line). That is a version mismatch between pr-review.sh and the \
installed gh (\`gh --version\`), not transport and not GitHub's answer: re-running prints the same \
refusal, so do not re-arm or retry; update gh or this script. The command stopped at this call, \
and anything it did before the call stands." >"$GH_REFUSED_FILE"
  if [ -n "$GH_REFUSAL_PID" ]; then
    kill -USR2 "$GH_REFUSAL_PID" 2>/dev/null
  else
    cat "$GH_REFUSED_FILE" >&2
  fi
  exit 2
}
gh_refused_exit() {
  cat "$GH_REFUSED_FILE" >&2 2>/dev/null
  exit 2
}

# gh_retry <read|write> <gh args...>: runs gh, prints its stdout, and returns 0 on success,
# 3 when a retryable failure outlived the attempts, 1 when the failure was the API's answer.
# GH_RETRY_CALLER_ARGS says whose arguments these are. Empty (every call but cmd_retry's) is this
# script's own, and gh refusing one ends the command (gh_refused_own). `listed` is a caller's, on a
# path gh_api_only_command reads: gh refusing it returns 2 on the first attempt, sent nothing.
# `unlisted` is a caller's on any other path, whose stderr is not read as gh's.
GH_RETRY_CALLER_ARGS=""
gh_retry() {
  local mode="$1"
  shift
  local attempt=1 rc out tmp retryable delay="$API_BACKOFF"
  [ ! -s "$GH_REFUSED_FILE" ] || exit 2
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
    # A refusal of the arguments sent nothing, so under either policy there is nothing to retry
    # and, for a write, nothing that could have landed.
    if [ "$GH_RETRY_CALLER_ARGS" != unlisted ] && gh_client_refusal "${GH_ERR%%$'\n'*}"; then
      [ "$tmp" = /dev/null ] || { rm -f "$tmp"; GH_TMP_FILE=""; }
      [ "$GH_RETRY_CALLER_ARGS" = listed ] && return 2
      gh_refused_own "$@"
    fi
    # A fixed GraphQL answer is read FIRST, under both policies: its whole first line is GraphQL's
    # own message, which no gateway prints, while the substring scans below would match a marker the
    # message only quotes (`Expected NAME, actual: STRING ("Bad gateway")`) and retry a query that
    # cannot change. A query GraphQL refused to validate ran nothing, so a write has nothing to land.
    if graphql_fixed_answer "${GH_ERR%%$'\n'*}"; then
      retryable=1
    elif [ "$mode" = write ]; then
      gateway_failure "$GH_ERR $out"
      retryable=$?
    else
      transient_failure "$GH_ERR $out"
      retryable=$?
    fi
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

# --- the polling budget (ludics-lite#543, #551) ----------------------------------------------
# One mechanism every observer shares (`watch`, `checks --wait`, `merge --wait`, `base --wait`,
# `retry run watch`): THE PAUSE (an unchanged poll doubles the pause from the command's interval up
# to its kind's cap), THE HOLD (a call GitHub refuses on quota stops every pr-review.sh sharing this
# state directory until a probe of the FAILING endpoint answers, its end read from that endpoint's
# own headers), and THE OBSERVER (one per PR and kind; a second is refused with exit 2 before it
# reads). A quota failure is never the API's answer about the PR: it is exit 3, and never permits a
# merge. Served by Python with every subcommand: lib/ludics/prreview/budget.py holds the mechanism,
# its BOUNDARY and the on-disk format of the state directory, which every version on a host shares.
# Only the knobs are resolved here, so a sourcing suite's assignment reaches the forward
# (PY_FORWARD_VARS).
REVIEW_POLL_CAP="${SHIP_PR_REVIEW_POLL_CAP:-300}"
BUILD_POLL_CAP="${SHIP_PR_BUILD_POLL_CAP:-600}"
for budget_knob in "SHIP_PR_REVIEW_POLL_CAP=$REVIEW_POLL_CAP" "SHIP_PR_BUILD_POLL_CAP=$BUILD_POLL_CAP"; do
  case "${budget_knob#*=}" in
  '' | *[!0-9]*) die "${budget_knob%%=*} must be whole seconds, got '${budget_knob#*=}'" ;;
  esac
done
unset budget_knob
# The state the hold and the observer locks live in. A fixture suite (source-only mode) gets none
# unless it names one, so no suite reads or writes this host's real hold.
if [ -n "${SHIP_PR_STATE_DIR:-}" ]; then
  BUDGET_DIR="$SHIP_PR_STATE_DIR"
elif [ "${SHIP_PR_TEST_SOURCE_ONLY:-}" = 1 ]; then
  BUDGET_DIR=""
else
  BUDGET_DIR="${XDG_STATE_HOME:-${HOME:-/tmp}/.local/state}/ship-pr"
fi

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
# The sweep runs at the start of every `watch`, which is Python since ludics-lite#403:
# tmp_sweep_stale in lib/ludics/prreview/watch.py, over the families above, in the TMPDIR of the
# call.

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

# The feeds poll read this round were written here, in this format: the comments and the reviews
# as JSON arrays, then the `.feeds.pr` marker LAST, so a write that fails partway leaves no
# snapshot at all rather than one missing a feed. The Python watch keeps its round snapshot in
# memory (lib/ludics/prreview/feeds.py), so these files serve only the shell round, which no
# subcommand runs any more (ludics-lite#403).

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

# --- poll ---------------------------------------------------------------------------------------
# Served by Python since ludics-lite#403: lib/ludics/prreview/poll.py, whose module keeps the
# comments that stood here (the commit each item is about, the fold of threads at one anchor, the
# About-Codex fold, the items line, the per-feed watermark). `watch` is Python as well and polls in
# process, so the snapshot and GH_ERR_FILE hand-over below served only the shell watch round this
# file no longer runs; they are inert until the shell half of this file is retired.
cmd_poll() {
  local err_file
  err_file=$(py_native_path "$GH_ERR_FILE")
  if [ "$SNAPSHOT_ARMED" = 1 ] && [ -n "$SNAP" ]; then
    LUDICS_PR_REVIEW_GH_ERR_FILE="$err_file" \
      LUDICS_PR_REVIEW_ROUND_SNAPSHOT="$(py_native_path "$SNAP")" py_forward call poll "$@"
  else
    LUDICS_PR_REVIEW_GH_ERR_FILE="$err_file" py_forward call poll "$@"
  fi
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
#
# The connector has a second way of not starting, and it is the same shape: "To use Codex here,
# [create an environment for this repo](https://chatgpt.com/codex/cloud/settings/environments)."
# as its first word on a round (ludics-lite#421: PR #420, 2026-09-26, while a sibling PR was
# reviewed normally; one '@codex review' got a round). It names no ref, which is why status_state
# attributes it by the clock rather than by the ref (see the `failed` branch there). Anchored and
# anchored at BOTH ends: the sentence is the connector's whole comment, so the match is the whole
# body — the link if there is one, an optional full stop, trailing whitespace, and nothing else.
# Three review rounds of #434 (1, 4, 5) each found a way a finding could open with the words and
# go on — "this repository …", text after the link, text on the next line — and each was a
# suffix the matcher accepted; with the body's end required there is no suffix left to accept.
# The trade is the canonical body's: should the connector ever append to this comment, it reads
# `expected` and costs one grace, loudly. The link is optional, since only its text is the
# reviewer's sentence. INIT_FAILURE_RE is the
# union, so `rounds` drops both shapes.
INIT_FAILURE_GIT_RE='\A[ \t]*Codex Review:[ \t]*Something went wrong\.[ \t]*Try again later by commenting[^\n]{0,4}@codex review'
INIT_FAILURE_ENV_RE='\A[ \t]*To use Codex here,[ \t]*\[?create an environment for this repo(?:\]\([^)[:space:]]*\))?\.?[[:space:]]*\z'
INIT_FAILURE_RE="(?:$INIT_FAILURE_GIT_RE)|(?:$INIT_FAILURE_ENV_RE)"
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
# The summary comment's Code Review row once a round is DONE (#439), the one row shape status_state
# reads as a verdict when no 👍 came. A fail-closed allowlist, cell by cell, of the row the app
# writes (ocannl-staging#828, ludics-lite#427 and #444, 2026-09-27):
#   | <a cell naming Code Review> | ✅ **Completed** <relative-time datetime="<ISO>"><text></relative-time> | `<7-40 hex>` | ...
# The status cell must be exactly that: U+2705 with no variation selector, the bold word, one
# relative-time element and nothing else; the commit cell a backquoted lowercase hex SHA. Any other
# status (Running, a failure or cancellation word, a new emoji, a reworded or re-marked Completed)
# is not a verdict, and what it leaves is the reading status gave before this row was read.
SUMMARY_COMPLETED_ROW_RE='^\|[^|]*Code Review[^|]*\| *✅ \*\*Completed\*\* <relative-time datetime="(?<at>[^"]+)">[^<|]*</relative-time> *\| *`(?<sha>[0-9a-f]{7,40})` *\|'
# The same row when the reviewer's RUN failed (#453), the one failure status the app has been seen
# to write — once in the 621 Code Review rows of every summary comment on both repositories since
# the table appeared (2026-08-29 to 2026-09-29), on lukstafi/ocannl-staging#633
# (issuecomment-5541857882); then twice on 2026-09-29: ludics-lite#462's opening round (read back
# from the comment's GraphQL userContentEdits, since the app rewrites the row in place — the row's
# datetime 17:40:02Z, the edit 17:40:56Z, and one '@codex review' got the round), and ludics-lite#465,
# the PR that added this reading, with a "Manual request" trigger one second after a "Something
# went wrong" comment:
#   | 📝 **Code Review** | ⚠️ **Failed** <relative-time datetime="2026-09-04T22:47:25.387018Z">...</relative-time> | `1e14b13` | New commits |
# A fail-closed allowlist of that row, cell by cell as the Completed one is: U+26A0 WITH its
# variation selector U+FE0F (the bytes that row carries), the bold word, one relative-time element,
# a backquoted lowercase hex SHA. Any other failure word, emoji or spelling is not this row, and
# keeps the reading status gave before #453 (a spent 👀's `expected`, a live one's `stalled`).
SUMMARY_FAILED_ROW_RE='^\|[^|]*Code Review[^|]*\| *⚠️ \*\*Failed\*\* <relative-time datetime="(?<at>[^"]+)">[^<|]*</relative-time> *\| *`(?<sha>[0-9a-f]{7,40})` *\|'
# The stamp of any summary-table row, whatever its status: the relative-time's datetime and the
# commit cell after it. status_state reads it three times — the Running rows, the newest summary's
# Code Review rows for the 👍 path's fourth field, and the same rows again to find the one
# SUMMARY_COMPLETED_ROW_RE is tried on — and the three must date a row identically, or the newest
# row one reader finds is not the one another does.
SUMMARY_ROW_STAMP_RE='datetime="(?<at>[^"]+)"[^|]*\| *`(?<sha>[0-9a-f]{7,40})` *\|'
# How the two readers that pick the NEWEST row (the 👍 path's fourth field and the Completed/Failed
# read) order the stamps: as instants, not as the strings the app writes. The app writes six
# fractional digits, but a whole-second "...:25Z" sorts AFTER "...:25.123Z" as a string, so a row
# written without a fraction would be taken for newer than one written later in the same second
# (review of #465, round 3). Padded to nine fractional digits, the string order is the time order;
# both readers use this one definition, so they cannot disagree about which row is the newest.
SUMMARY_ROW_INSTANT_DEF='def instant: sub("Z$"; "") | (if test("\\.") then . else . + "." end) + "000000000" | .[0:29];'

# The clock every age is read from: the epoch second. With SHIP_PR_TEST_CLOCK naming a file, that
# file IS the clock (one epoch second in it), which the Python watch's sleeps advance instead of
# waiting (lib/ludics/prreview/clock.py), so a fixture suite drives a watch's window, its
# graces and the ages it reads through the environment (ludics-lite#403). Unset, which is every
# real run, it is the system clock.
clock_now() {
  if [ -n "${SHIP_PR_TEST_CLOCK:-}" ]; then
    cat "$SHIP_PR_TEST_CLOCK"
  else
    date +%s
  fi
}

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
  out=$(jq -rn --arg t "$1" --argjson clock "$(clock_now)" \
    'try (($clock - ($t | fromdateiso8601)) | floor | tostring) catch "-"' 2>/dev/null)
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
#   approved  👍 is on the PR and is not older than the head (#418, below): the merge gate is open.
#   reviewing 👀 is newer than the reviewer's last word, so a round really is in flight.
#   stalled   ... and it has been in flight longer than any round takes; nothing is coming.
#   failed    the reviewer's newest word is the INITIALIZATION failure above: the round never ran —
#             or its summary marks the head's run Failed with no review and no 👍 (#453, below).
#   expected  no live 👀 and no review of the head SHA: a round is due and has not started. A 👍
#             left from before the head arrived is such a head's state too, not an approval.
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
#
# Nor does an envelope whose comments are all the connector's FIXED replies (ludics-lite#472). A
# mention of '@codex' in a review thread draws the connector's answer INTO that thread, and GitHub
# files a thread reply as an empty-bodied COMMENTED review on the head, so the envelope test above
# passed it as findings: on PR #465 one quoted '@codex review' drew inline comment 4138519259, and
# `watch` reported "opened round 5 of 12" over a round that never ran. Both the count and the
# state read through here, so for both it is not a review of that head.
#
# Boundary, as a fail-closed allowlist: CONNECTOR_FIXED_REPLIES holds the verbatim bodies of the
# replies seen, and a comment matches only when it IS a thread reply (a numeric `in_reply_to_id`,
# which the review's own comments endpoint serves) and its body, trailing whitespace aside, EQUALS
# one of them. A top-level comment carrying that text is a finding, not this reply (review of #488,
# round 1). One body today, taken from comment 4138519259 and the same answer the connector gave six
# times in threads of PR #82 (every connector thread reply on this repository and
# ocannl-staging, read 2026-10-01). Not read: the comment's author (a review's comments are its
# author's), any other wording, a body that quotes or extends one of these, and an envelope
# mixing one with anything else, all of which stay findings. A new fixed reply counts as a round
# until its body is added here, loudly; a finding swallowed by a looser match would not be seen.
CONNECTOR_FIXED_REPLIES='["To use Codex here, [create an environment for this repo](https://chatgpt.com/codex/cloud/settings/environments)."]'
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
    if jq -e --argjson fixed "$CONNECTOR_FIXED_REPLIES" '
        def fixed_reply: (.in_reply_to_id | type) == "number" and (.body | type) == "string"
          and (.body | sub("[[:space:]]+\\z"; "") | IN($fixed[]));
        type == "array" and all(.[]; fixed_reply)' \
      <<<"$inline" >/dev/null; then
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
  local reviews_raw="[]" comments_raw="[]" fline fail_at fail_ref fail_kind fail_head rev_head_at nudge_at="" nudge_age nudge_id="" nudge_line comments_loaded=false
  local reviews_loaded=false head_loaded=false head_at_read=false row_sha stale_plus_at="" stale_note=""
  local done_line done_kind done_at done_sha req_line req_after req_before floor

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
  # Nor a 👍 left from before the head arrived (#418, below), which falls through to the
  # ordinary states — so the reads made here are kept, and the path below does not repeat them.
  if [ "$plus" = true ] && review_after_nudge "$plus_at" "$nudge_at"; then
    if [ "$comments_loaded" != true ]; then
      if comments_raw=$(state_comments "$pr"); then comments_loaded=true; else comments_raw='[]'; fi
    fi
    if reviews_raw=$(state_reviews "$pr"); then reviews_loaded=true; else reviews_raw='[]'; fi
    reviews_raw=$(substantive_reviews "$pr" <<<"$reviews_raw") || {
      echo "unknown|-|$mstate|the review comments API did not establish substantive reviews"
      return 0
    }
    state_head_read "$pr"
    head_loaded=true
    evidence=$(jq -rs --arg rev "$REVIEWER" --arg head "$head_sha" --arg rc "$REVIEWED_COMMIT_RE" \
      --arg stamp "$SUMMARY_ROW_STAMP_RE" "$SUMMARY_ROW_INSTANT_DEF"'
      .[0] as $comments | .[1] as $reviews |
      def reviewer: select((.user.login // "") | startswith($rev));
      def current: select(.sha != "" and $head != "")
        | select(.sha as $sha | $head | startswith($sha));
      # One entry per Running row the table test admits, each re-matched by the stamp pattern
      # (SUMMARY_ROW_STAMP_RE): `[capture(...)] | first` yields null where they disagree instead of yielding
      # NOTHING, which unbracketed here would delete not just that row but every later row of
      # the same stream. The two patterns have to keep agreeing on every Running row, and the
      # count of nulls is the third field below — how the caller hears that they stopped
      # agreeing, rather than reading a deleted row as "no round is running" (#89, #104).
      [$comments[] | reviewer
         | select((.body // "") | contains("codex-pull-request-review-summary"))
         | (.body // "") | split("\n")[]
         | select(test("^\\|[^|]*Code Review[^|]*\\|[^|]*Running"))
         | ([capture($stamp)] | first)]
        as $running |
      # The Code Review rows of the NEWEST summary comment (the app edits one in place, so that
      # is its latest activity), whatever their status: the newest row names the commit the
      # reviewer last took up, which is the fourth field (#418, below). Empty — and the clock
      # below answers instead — when there is no such row, or when ANY of them is one the stamp
      # pattern cannot read: its time is then unknown, so no readable row can be called the
      # newest, and an older summary is never consulted in its place.
      ([$comments[] | reviewer
         | select((.body // "") | contains("codex-pull-request-review-summary"))]
       | max_by(.updated_at // .created_at)
       | if . == null then []
         else [(.body // "") | split("\n")[]
               | select(test("^\\|[^|]*Code Review[^|]*\\|"))
               | [capture($stamp)] | first]
         end) as $rows |
      (if ($rows | length) == 0 or any($rows[]; . == null) then ""
       else $rows | max_by(.at | instant) | .sha end) as $row_sha |
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
        + "|" + (($running | map(select(. == null)) | length) | tostring)
        + "|" + $row_sha' \
      <<<"$comments_raw"$'\n'"$reviews_raw" 2>/dev/null) || {
      echo "unknown|-|$mstate|the current-head review evidence did not parse"
      return 0
    }
    IFS='|' read -r evidence_kind evidence_at running_unread row_sha <<<"$evidence"
    # The two Running patterns disagreed on a row. Neither "a round is running" nor "none is"
    # is readable from a table this script can only half parse, so neither is claimed.
    case "$running_unread" in
    0) ;;
    *)
      echo "unknown|-|$mstate|a $REVIEWER Code Review row matched the Running test but not the" \
        "SUMMARY_ROW_STAMP_RE, so the running round could not be read"
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
    # A 👍 is about the head the reviewer last took up, and a push moves the head without taking
    # the 👍 back: the app removes it only when it puts up the 👀 for the new head, minutes later.
    # In that window an unreviewed head read as approved (#418: on #411 for four minutes, on #415
    # for a push 67 minutes after the 👍). The rule: a 👍 older than the head's arrival is not an
    # approval of that head. The arrival is no API field, so two pieces of evidence stand in:
    #   - the newest Code Review row of the reviewer's summary comment (the fourth field above).
    #     The app rewrites that row when it takes a head up and again when the round completes,
    #     each time naming the commit — so while a 👍 stands, the row names the head it was
    #     given for (#411: "Completed ... `7e2aca6`" three seconds before its 👍). A row naming
    #     any other commit is a head nobody has reviewed, and this is exact, with no clock;
    #   - with no such row read, the head commit's committer date, the review clock's own lower
    #     bound on the push (below): a 👍 older than the commit cannot be about it. It misses a
    #     commit made BEFORE the 👍 and pushed after (#415's head sat nine minutes between commit
    #     and push); that miss is the one the row closes, and the only one left without it. A
    #     date in the FUTURE (clock skew, an explicit GIT_COMMITTER_DATE) proves nothing and is
    #     not used — age_of refuses it, as it does for the review clock — or every 👍 before
    #     that date would be demoted and a nudge recommended over it.
    # Not the PR's `updated_at`, which the checks grace pairs with the commit date: it moves on
    # every comment and thread reply, and the `unresolved` flow (reply to and resolve threads
    # under a standing 👍) would then demote a real approval to `expected` and invite the
    # `@codex review` that clears it. The commit read is the one the `expected` clock below makes,
    # taken earlier and only when the row is missing; neither test runs without a head, where the
    # 👍 stands as before (a failed PR read must not hide it). A stale 👍 falls through to the
    # ordinary states as the reviewer's last word, which also spends any 👀 older than it.
    if [ -n "$head_sha" ]; then
      if [ -n "$row_sha" ]; then
        case "$head_sha" in
        "$row_sha"*) ;;
        *) stale_note="the 👍 at $plus_at is for ${row_sha:0:7}, per $REVIEWER's summary" ;;
        esac
      else
        head_at=$(gh_retry read api "repos/$REPO/commits/$head_sha" --jq .commit.committer.date) ||
          head_at=""
        head_at_read=true
        age=$(age_of "$head_at")
        if [ "$age" != - ] && [[ "$plus_at" < "$head_at" ]]; then
          stale_note="the 👍 at $plus_at predates head ${head_sha:0:7}'s commit date $head_at"
        fi
      fi
    fi
    if [ -z "$stale_note" ]; then
      echo "approved|-|$mstate|👍 from $REVIEWER"
      return 0
    fi
    stale_plus_at="$plus_at"
  fi

  # The comments BEFORE the reviews, as the 👍 path above and cmd_poll read them: the summary's
  # Completed row is read below as a verdict when nothing was posted since the 👀 (#439), and the
  # app submits a round's findings review 2-4 s BEFORE it flips that row to Completed (nine of nine
  # findings rounds sampled on 2026-09-28, e.g. ludics-lite#427's review at 20:04:21Z under the row's
  # 20:04:24Z). Read in that order, a Completed row in the comments read means its review, if the
  # round had one, is already in the reviews read after it; read the other way round, the few
  # seconds between the reads would be a window in which a findings round reads as clean. So a
  # comments read that the 👍 path could not make, and makes here after that path's reviews
  # read, costs the reviews a second read rather than the order.
  if [ "$comments_loaded" != true ]; then
    comments_raw=$(state_comments "$pr") || {
      echo "unknown|-|$mstate|the comments API did not answer ($(gh_err_line))"
      return 0
    }
    comments_loaded=true
    reviews_loaded=false
  fi

  if [ "$reviews_loaded" = true ]; then
    # The stale-👍 path's read, already through substantive_reviews.
    raw="$reviews_raw"
  else
    raw=$(state_reviews "$pr") || {
      echo "unknown|-|$mstate|the reviews API did not answer ($(gh_err_line))"
      return 0
    }
    raw=$(substantive_reviews "$pr" <<<"$raw") || {
      echo "unknown|-|$mstate|the review comments API did not establish substantive reviews"
      return 0
    }
  fi
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
  raw="$comments_raw"
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
  # The round the summary table says is done (#439): its newest Code Review row, when that row is
  # the Completed shape SUMMARY_COMPLETED_ROW_RE allows — or the run it says FAILED (#453), when it
  # is the SUMMARY_FAILED_ROW_RE shape instead; the first field says which. Read like the 👍
  # path's fourth field: the rows of the NEWEST summary comment only, and none at all when any
  # Code Review row there is one
  # the stamp pattern cannot date — no row can then be called the newest, and an older summary is
  # never consulted in its place. The newest row is found by the same stamp the 👍 path reads, and
  # must then ALSO match the allowlist, the two patterns applied to the same line: one that dates a
  # row the allowlist refuses is not a verdict, so the patterns disagreeing costs the verdict and
  # nothing else (the Running rows' disagreement is `unknown` instead, because there it would
  # otherwise leave a 👍 standing; here the fallback approves nothing). Whether it is a verdict for
  # the head, and for this round, is decided below, once the head is known.
  done_line=$(jq -r --arg rev "$REVIEWER" --arg done "$SUMMARY_COMPLETED_ROW_RE" \
      --arg failed "$SUMMARY_FAILED_ROW_RE" --arg stamp "$SUMMARY_ROW_STAMP_RE" "$SUMMARY_ROW_INSTANT_DEF"'
      [.[] | select((.user.login // "") | startswith($rev))
           | select((.body // "") | contains("codex-pull-request-review-summary"))]
      | max_by(.updated_at // .created_at)
      | if . == null then "||"
        else [(.body // "") | split("\n")[]
              | select(test("^\\|[^|]*Code Review[^|]*\\|"))
              | . as $row
              | [capture($stamp)] | first
              | if . == null then null else {at, row: $row} end]
          | if length == 0 or any(.[]; . == null) then "||"
            else max_by(.at | instant) | ([.row | capture($done)] | first) as $c
              | ([.row | capture($failed)] | first) as $f
              | if $c != null then "completed|\($c.at | sub("\\.[0-9]+Z$"; "Z"))|\($c.sha)"
                elif $f != null then "failed|\($f.at | sub("\\.[0-9]+Z$"; "Z"))|\($f.sha)"
                else "||" end
            end
        end' <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|$mstate|the summary comments feed did not parse"
    return 0
  }
  done_kind="${done_line%%|*}"
  done_line="${done_line#*|}"
  done_at="${done_line%%|*}"
  done_sha="${done_line#*|}"
  # The initialization failure (INIT_FAILURE_RE above). Only the NEWEST non-placeholder comment is
  # tested, never all of them: any later word supersedes the failure — a findings summary, a
  # no-findings verdict, a second failure naming a different head — and the state it leaves is
  # that word's, not this one's. `created_at`, not `updated_at`: this comment is posted fresh
  # (the placeholder that gets edited in place is filtered out here as everywhere), and taking
  # the same clock as com_at is what makes "the failure IS the reviewer's last word" exact.
  # The third field is which of the two shapes it is: `env` (the missing-environment sentence,
  # which names no ref) or `git` (the "Something went wrong" one).
  fline=$(jq -r --arg rev "$REVIEWER" --arg re "$INIT_FAILURE_RE" --arg refre "$INIT_FAILURE_REF_RE" \
    --arg envre "$INIT_FAILURE_ENV_RE" '
      [.[] | select((.user.login // "") | startswith($rev))
           | select((.body // "") | test("codex-pull-request-review-summary") | not)]
      | sort_by(.created_at) | last
      | if . == null or ((.body // "") | test($re) | not) then "||"
        else "\(.created_at)|" + ([(.body // "") | capture($refre).s] | first // "")
          + "|" + (if (.body // "") | test($envre) then "env" else "git" end)
        end' <<<"$raw" 2>/dev/null) || {
    echo "unknown|-|$mstate|the initialization-failure comments feed did not parse"
    return 0
  }
  fail_at="${fline%%|*}"
  fline="${fline#*|}"
  fail_ref="${fline%%|*}"
  fail_kind="${fline#*|}"
  # A new explicit request supersedes older evidence uniformly: neither an old
  # success, failure, idle review nor reaction can settle that requested round.
  # Newer events retain the established priority rules below.
  review_after_nudge "$eyes_at" "$nudge_at" || eyes_at=""
  if ! review_after_nudge "$rev_at" "$nudge_at"; then rev_at=""; rev_sha=""; fi
  review_after_nudge "$com_at" "$nudge_at" || com_at=""
  if ! review_after_nudge "$verd_at" "$nudge_at"; then verd_at=""; verd_sha=""; fi
  if ! review_after_nudge "$fail_at" "$nudge_at"; then fail_at=""; fail_ref=""; fail_kind=""; fi
  # A stale 👍 (above) is the reviewer's last word about the head it was given for.
  last_spoke=$(newest "$rev_at" "$com_at" "$stale_plus_at")

  # The head SHA and the mergeability, in ONE read of the PR, made AFTER the feeds: every review
  # in those feeds is then about a head no newer than the one read, so "the review's commit_id
  # equals the head" means the CURRENT head was reviewed. Read before the feeds, a push landing
  # between the two reads would match the previous head's review to the previous head and report
  # `idle` (or a verdict comment as `approved`) while the new head sits unreviewed — the false
  # reading this state machine exists to prevent (review of ludics-lite#47). One read serves the
  # verdict check and the post-round states, which used to read it separately. Inside a watch round
  # it is the round's own head read, taken from the snapshot: that read was made after the feeds
  # this function is holding, so the ordering is the same one — and the state cannot then be
  # anchored on a head the round classified nothing against (ludics-lite#95). The stale-👍 path
  # made this read already, after the same feeds.
  [ "$head_loaded" = true ] || state_head_read "$pr"

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

  # A round the summary table marks Completed on the CURRENT head, with nothing posted since its 👀,
  # is a clean round the app forgot to 👍 (#439: ocannl-staging#828, the row "✅ Completed" on
  # fc6ff6a at 01:10:51Z under a 👀 of 01:06:53Z, no review and no 👍 after it, and `status` read
  # STALLED 56 minutes on and recommended the nudge that clears approvals). The app's own contract,
  # in every summary it posts, is "comments if it has suggestions, and reacts with 👍 once all
  # reviews finish with no findings", so a finished round that said nothing is the no-findings one.
  # This is an approval, and passes through the open-thread gate like any other; `merge` reads the
  # build and the threads and never the 👍, so it gains nothing to skip. What makes it safe to call
  # one is what it requires, each fail-closed:
  #   - the row is the allowlisted Completed shape, newest in the newest summary, naming the head;
  #   - a 👀 bounds the round: the row is newer than it, and so is not a previous round's (a
  #     re-request raises a fresh 👀 over a row whose SHA still matches). No 👀 — taken down, or
  #     older than a pending request — leaves no round to bound, and the reading stays as it was;
  #   - the reviewer's last word (a substantive review, a comment other than the summary, a stale 👍)
  #     is OLDER than that 👀. "Nothing after the row" would be the wrong test: a findings round
  #     submits its review 2-4 s BEFORE the row flips (see the read order above), so it would call
  #     every findings round clean. Anything the reviewer said inside the round disqualifies it,
  #     which leaves such a round to the arms below (`idle` on a review of this head).
  if [ "$done_kind" = completed ] && [ -n "$done_sha" ] && [ -n "$head_sha" ] && [ -n "$eyes_at" ] && [[ "$done_at" > "$eyes_at" ]] &&
    { [ -z "$last_spoke" ] || [[ "$last_spoke" < "$eyes_at" ]]; }; then
    case "$head_sha" in
    "$done_sha"*)
      echo "approved|-|$mstate|$REVIEWER's summary marks head ${head_sha:0:7}'s Code Review Completed at" \
        "$done_at, with nothing posted since its 👀 at $eyes_at (no 👍 was given)"
      return 0
      ;;
    esac
  fi

  # A reviewer RUN the summary table marks Failed on the CURRENT head (#453): the app took the
  # head up and its run ended without a round — no review, no 👍 — so nothing is coming, and a
  # '@codex review' re-request is the move. That request is safe to make exactly when there is no
  # approval for it to clear (the danger the never-re-request-as-stall-recovery rule is about), so
  # the reading requires that, each fail-closed; anything else keeps the reading status gave
  # before this row was read (the observed case, ocannl-staging#633, read `expected` there):
  #   - the row is the allowlisted Failed shape, newest in the newest summary, naming the head,
  #     and its datetime is one age_of reads, not in the future: the comparisons below are string
  #     orderings, and a malformed or future stamp would order an old failure above a newer 👀;
  #   - no 👍 on the PR at all, standing or stale;
  #   - the row is newer than a pending request (a watch's nudge) and than any 👀 — a 👀 above it
  #     is a round started after the failure, which the in-flight arm below waits out — and no
  #     '@codex review' has been posted since the row: a request after it has answered it. The
  #     row's stamp is cut to whole seconds, as the comments' are served, so a request in the
  #     row's own second counts as after it — pending, never a second failure's cause;
  #   - the reviewer said nothing inside the run: with a 👀 up, nothing since that 👀 (a findings
  #     round submits its review seconds BEFORE its row flips, see the read order above, so
  #     "nothing after the row" would be the wrong test); with the 👀 taken down — the app takes
  #     it down when a run ends, and #633 had none — no review of this head at all, and nothing
  #     newer than the row. An initialization-failure comment posted with the row (#465: one second
  #     BEFORE it) is the same failed run, not a word against it: the row, being newer, is read,
  #     and the init-failure arm below keeps the failures that come with no row.
  # The kind says whether this head has had a request before: `run` when no '@codex review' was
  # posted between the head's arrival and the row, `run-again` when one was, so the failure is
  # the answer to a request already made. `watch` re-requests on `run` and surfaces `run-again`,
  # which is what makes its re-request once per head across watches, not per process. The
  # arrival is the newest of the head commit's date and the PR's creation (the review clock's
  # bounds), inclusive, since a request in the arrival's own second is on this head as likely as
  # not; with neither readable every request on the PR counts, so an unreadable clock can only
  # suppress a re-request, never add one. The committer date is commit metadata, not the push
  # (which is no API field, #72), and its two misses are priced, not closed (review of #465, round
  # 4): a reset to an OLDER commit dates the head before requests made for its predecessor, so a
  # first failure reads `run-again` and is surfaced to the caller, loudly; a commit dated AFTER a
  # request it was pushed before (an explicit GIT_COMMITTER_DATE) can cost one duplicate request
  # on a run with no approval, never a cleared 👍. Requests are matched loosely, any non-reviewer
  # comment carrying "@codex review", for the same reason: a looser match only surfaces sooner.
  if [ "$done_kind" = failed ] && [ -n "$done_sha" ] && [ -n "$head_sha" ] && [ "$plus" != true ] &&
    [ "$(age_of "$done_at")" != - ] &&
    review_after_nudge "$done_at" "$nudge_at" && { [ -z "$eyes_at" ] || [[ "$eyes_at" < "$done_at" ]]; }; then
    case "$head_sha" in
    "$done_sha"*)
      if [ -n "$eyes_at" ]; then
        { [ -z "$last_spoke" ] || [[ "$last_spoke" < "$eyes_at" ]]; } || done_kind=""
      else
        { [ -z "$last_spoke" ] || [[ "$last_spoke" < "$done_at" ]]; } || done_kind=""
        rev_head_at=$(jq -r --arg rev "$REVIEWER" --arg sha "$head_sha" '
            [.[] | select((.user.login // "") | startswith($rev))
                 | select(.submitted_at != null) | select((.commit_id // "") == $sha)
                 | .submitted_at] | max // ""' <<<"$reviews_raw" 2>/dev/null) || {
          echo "unknown|-|$mstate|the reviews feed did not parse for the failed run's head"
          return 0
        }
        [ -z "$rev_head_at" ] || done_kind=""
      fi
      ;;
    *) done_kind="" ;;
    esac
  else
    done_kind=""
  fi
  if [ "$done_kind" = failed ]; then
    if [ "$head_at_read" != true ]; then
      head_at=$(gh_retry read api "repos/$REPO/commits/$head_sha" --jq .commit.committer.date) ||
        head_at=""
      head_at_read=true
    fi
    floor=""
    [ "$(age_of "$head_at")" = - ] || floor="$head_at"
    [ -z "$pr_created" ] || [ "$(age_of "$pr_created")" = - ] || floor=$(newest "$floor" "$pr_created")
    req_line=$(jq -r --arg rev "$REVIEWER" --arg row "$done_at" --arg floor "$floor" '
        [.[] | select((.user.login // "") | startswith($rev) | not)
             | select((.body // "") | test("@codex[[:space:]]+review"; "i"))
             | .created_at // ""]
        | "\(any(.[]; . >= $row))|\([.[] | select(. >= $floor and . < $row)] | max // "")"' \
      <<<"$comments_raw" 2>/dev/null) || {
      echo "unknown|-|$mstate|the review-request comments feed did not parse"
      return 0
    }
    req_after="${req_line%%|*}"
    req_before="${req_line#*|}"
    if [ "$req_after" != true ]; then
      if [ -n "$req_before" ]; then
        echo "failed|$(age_of "$done_at")|$mstate|${head_sha:0:7}|run-again|$REVIEWER's summary marks" \
          "head ${head_sha:0:7}'s Code Review Failed at $done_at, after the '@codex review' request" \
          "at $req_before on this head, with no review of it and no 👍"
      else
        echo "failed|$(age_of "$done_at")|$mstate|${head_sha:0:7}|run|$REVIEWER's summary marks" \
          "head ${head_sha:0:7}'s Code Review Failed at $done_at, with no review of it, no 👍, and" \
          "no '@codex review' on it since it arrived"
      fi
      return 0
    fi
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
  #
  # The missing-environment shape (ludics-lite#421) is the exception, because it NEVER names a ref:
  # left unattributed it could never be `failed`, and #420 read `expected` until a hand nudge
  # while `watch` had already exited on it as a round. So it is attributed by that same clock,
  # with the objection above priced differently: its miss — a head pushed after the failure whose
  # commit date predates it — reports `failed` and recommends a nudge that requests exactly the
  # round that head is due, a redundant request at worst; unattributed, it is the stall #421
  # reported. Newer than the head's committer date AND the PR's creation, both read and neither in
  # the future; an unread or future date attributes nothing and costs the grace, as before.
  fail_head=""
  if [ -n "$fail_at" ] && [ -n "$fail_ref" ]; then
    case "$head_sha" in "$fail_ref"*) fail_head="for ref ${fail_ref:0:7}" ;; esac
  elif [ -n "$fail_at" ] && [ "$fail_kind" = env ]; then
    if [ "$head_at_read" != true ]; then
      head_at=$(gh_retry read api "repos/$REPO/commits/$head_sha" --jq .commit.committer.date) ||
        head_at=""
      head_at_read=true
    fi
    if [ "$(age_of "$head_at")" != - ] && [[ "$fail_at" > "$head_at" ]] &&
      { [ -z "$pr_created" ] || { [ "$(age_of "$pr_created")" != - ] && [[ "$fail_at" > "$pr_created" ]]; }; }; then
      fail_head="after head ${head_sha:0:7}'s commit date $head_at"
    fi
  fi
  if [ -n "$fail_head" ]; then
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
      echo "failed|$(age_of "$fail_at")|$mstate|${head_sha:0:7}|$fail_kind|$REVIEWER reported an" \
        "initialization failure at $fail_at $fail_head"
      return 0
    fi
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
  if [ "$head_at_read" != true ]; then
    head_at=$(gh_retry read api "repos/$REPO/commits/$head_sha" --jq .commit.committer.date) ||
      head_at=""
  fi
  if [ -n "$nudge_at" ]; then
    # An earlier request must not shorten a newly committed head or newly opened
    # PR's pickup grace. Reuse the same validated clocks as ordinary expected.
    nudge_age=$(freshest_age "$nudge_at" "$head_at" "$pr_created")
    echo "nudged|$nudge_age|$mstate|$nudge_id|fresh review nudge; waiting for pickup"
    return 0
  fi
  echo "expected|$(freshest_age "$head_at" "$pr_created" "$last_spoke" "$eyes_at" "$nudge_at")|$mstate|no 👀" \
    "in flight and no review of head ${head_sha:0:7}${rev_sha:+; $REVIEWER last reviewed ${rev_sha:0:7} at $rev_at}${stale_note:+; $stale_note}"
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
  local tok age detail merge conflict fsha frest fkind
  tok=$(state_tok "$1")
  age=$(state_age "$1")
  detail=$(state_detail "$1")
  [ "$tok" != nudged ] || detail="${detail#*|}"
  merge=$(state_merge "$1")
  conflict=$(conflict_note "$merge")
  case "$tok" in
  approved) echo "approved ($detail)${conflict:+; $conflict}" ;;
  # An approval with open threads under it (approval_gate). "approved" leads the line on purpose —
  # the 👍 is real — and what follows it is what makes it not a merge.
  unresolved)
    frest="${detail#*|}"
    echo "approved (${frest%%|*}) BUT ${detail%%|*} review thread(s) still UNRESOLVED — NOT a" \
      "clean approval, and \`merge\` refuses it: ${frest#*|}. $(threads_advice)${conflict:+; $conflict}"
    ;;
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
  #
  # The missing-environment shape (ludics-lite#421) gets the same first move and a different
  # second one: on #420 one nudge got a round, and if it does not, no push reaches a setting
  # that lives on the connector's side.
  failed)
    fsha="${detail%%|*}"
    frest="${detail#*|}"
    fkind="${frest%%|*}"
    frest="${frest#*|}"
    case "$fkind" in
    # A run the summary marks Failed (#453). The re-request is the move, and it is safe here as it
    # is nowhere else: the state requires no 👍 on the PR and nothing from the reviewer about the
    # run, so the request has no approval to clear. `watch` makes it itself, once per head;
    # `run-again` is that request answered by a second failure, and is the caller's.
    run)
      echo "reviewer's run FAILED on head $fsha — no review and no 👍, so a '@codex review'" \
        "re-request clears nothing: \`watch\` posts it itself, once per head, and keeps" \
        "watching; outside a watch, post it (pr-review.sh comment $REPO#${PR_NUM:-<pr>}" \
        "'@codex review'). This is not a round — $frest, standing for" \
        "$(fmt_age "$age")${conflict:+; $conflict}"
      ;;
    run-again)
      echo "reviewer's run FAILED AGAIN on head $fsha after a '@codex review' request on it — not" \
        "re-requested a second time: read the PR feed (retry --read pr view <pr> --comments) for" \
        "anything the reviewer said, then push a new head (an amend suffices: git commit --amend" \
        "--no-edit && git push --force-with-lease) or hand it to the maintainer. This is not a" \
        "round — $frest, standing for $(fmt_age "$age")${conflict:+; $conflict}"
      ;;
    env)
      echo "reviewer FAILED at initialization on head $fsha — nudge it once with a '@codex review'" \
        "comment (pr-review.sh comment $REPO#${PR_NUM:-<pr>} '@codex review'); the connector" \
        "answered \"To use Codex here, create an environment for this repo\", which has cleared" \
        "on one nudge before. If the nudge draws the same answer, the environment is the" \
        "maintainer's to set up (https://chatgpt.com/codex/cloud/settings/environments) — no push" \
        "of yours fixes it. This is not a round — $frest, standing for" \
        "$(fmt_age "$age")${conflict:+; $conflict}"
      ;;
    *)
      echo "reviewer FAILED at initialization on head $fsha — nudge it once with a '@codex review'" \
        "comment (pr-review.sh comment $REPO#${PR_NUM:-<pr>} '@codex review'); if the SAME head" \
        "fails again, push a new head instead (an amend suffices: git commit --amend --no-edit &&" \
        "git push --force-with-lease), since the reviewer's clone is behind, not your push — the" \
        "ref it could not fetch is one the PR and git ls-remote both serve. This is not a round —" \
        "$frest, standing for $(fmt_age "$age")${conflict:+; $conflict}"
      ;;
    esac
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
#
# The optional caps count only the comments and reviews at or below those ids — the count as it
# stood at a watermark, which is how `watch` tells which rounds a window's items opened.
review_rounds() { # <pr> [<issue comment id cap> <review id cap>]
  local pr="$1" icap="${2:-null}" rcap="${3:-null}" raw comments line count heads
  # Through the round snapshot when a watch round holds one (the same feeds the round was judged
  # on, and no second read), and a read of its own otherwise — as status_state reads them.
  raw=$(state_reviews "$pr") || {
    echo "unknown|the reviews API did not answer ($(gh_err_line))"
    return 0
  }
  raw=$(substantive_reviews "$pr" <<<"$raw") || {
    echo "unknown|the review comments API did not establish substantive reviews"
    return 0
  }
  # A round can also arrive as an issue comment alone — the same shape status_state treats as
  # the reviewer speaking — so those count too, minus the round-started placeholder, the
  # no-findings verdict, and the initialization failure (either shape INIT_FAILURE_RE names, the
  # missing environment of ludics-lite#421 included): an attempt that never ran carries no
  # findings, and counting it inflated ocannl-staging#677 to "1 round(s) of findings over 0
  # head(s)" — a threshold reading made of two failed fetches (ludics-lite#78). It is dropped
  # from the COMMENT feed alone, which is the only feed it has ever arrived in: a review carries
  # the commit it was submitted against, and the reviewer submits none when it cannot fetch it.
  #
  # The test is INIT_FAILURE_RE, the canonical body, which is `status_state`'s test too: a
  # comment is a failure for both or a round for both. A comment-only round whose finding quotes
  # "Provided git ref <sha> does not exist" — a round about this very matcher — is a round here
  # and on the state line, and that is what the anchored expression buys (review of #82).
  comments=$(state_comments "$pr") || {
    echo "unknown|the comments API did not answer ($(gh_err_line))"
    return 0
  }
  # Both feeds go in on stdin (slurped: reviews first, comments second), never as arguments —
  # a long PR's comment history outgrows the argument list (128 KB per argument on Linux).
  line=$(printf '%s\n%s\n' "$raw" "$comments" | jq -r -s --arg rev "$REVIEWER" \
    --argjson gap "$ROUND_GAP" --arg fail "$INIT_FAILURE_RE" --arg rc "$REVIEWED_COMMIT_RE" \
    --argjson icap "$icap" --argjson rcap "$rcap" '
      .[1] as $comments | .[0]
      | ([.[] | select((.user.login // "") | startswith($rev))
           | select($rcap == null or (.id // 0) <= $rcap)
           | select(.submitted_at != null)
           | select(.state == "COMMENTED" or .state == "CHANGES_REQUESTED")
           | {sha: (.commit_id // ""), t: (.submitted_at | fromdateiso8601)}]
       + [$comments[] | select((.user.login // "") | startswith($rev))
           | select($icap == null or (.id // 0) <= $icap)
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
      "blocking-only from here: use ship-pr's narrow criteria — consequential defects" \
      "introduced or materially worsened by the PR, invalidated central claims or evidence," \
      "or failed build-relevant checks (all non-advisory checks). Merely exposing a severe" \
      "pre-existing defect does not block. Defer the rest to ONE follow-up issue, and merge on the first round with" \
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

# The machine-readable trailers (ludics-lite#423, part 1). The prose above them is for a reader and
# has been reworded often (#434 changed `watch`'s round clause four times in one PR); a program
# reads these instead, the way `watch` reads poll's `items:` line. Each is the LAST line of its
# command's stdout — `watch`'s goes just above its watermark, which stays last — and each field is
# a token from a closed set: a count or `unknown`, a threshold number or `off`, and for `checks`
# the VERDICT vocabulary gate_checks sets (anything else prints as `unknown`). A consumer takes
# the fields from the trailer alone and reads a missing or malformed one as unknown.
count_token() { # <review_rounds result>
  case "${1%%|*}" in
  '' | *[!0-9]*) printf 'unknown' ;;
  *) printf '%s' "${1%%|*}" ;;
  esac
}

# Served by Python since ludics-lite#403 (lib/ludics/prreview/rounds.py, counting through
# state.py's review_rounds, which `watch` and `status` count with too).
cmd_rounds() { py_forward call rounds "$@"; }

# --- open review threads under an approval (ludics-lite#289) ----------------------------------
# An approval is about the head it landed on; an open thread is a finding nobody has closed, and
# the two are different facts. On PR #277's round 6 the reviewer left two findings on the previous
# head and its 👍 landed on the base-merge commit above it: `watch` classified the findings NOT
# about head, advanced its watermark past them and reported `approved`. The merge had touched
# neither line, so both were live in the head about to be merged, and only the worker's own read
# of the feed caught it. Whether a finding written against another head still holds is a question
# about LINES (did this head change them?) that nothing here tries to answer; whether the thread is
# still OPEN is answered exactly. So an approval with any unresolved review thread is not a clean
# approval: `status` and `watch` report it as `unresolved`, and `merge` refuses. Clearing it is
# what the loop already does with every thread — answer it (`reply`, a fix or a rebuttal), then
# close it (`resolve`) — and needs no push, which is why no flag bypasses it.
#
# Boundary, as an allowlist: the ONE field read is each thread's `isResolved`, and a thread counts
# as closed only when that field is literally true — absent or null is open. The first comment's
# id, author and path are read to NAME a thread, never to judge it; the id is `fullDatabaseId`
# (a BigInt string) ahead of `databaseId`, which the schema types as a 32-bit Int while review
# comment ids already run past 2^31 — GitHub serves them whole today (4095735684 on #370), and the
# BigInt field is the one that is typed to keep doing so. Not read: whether a thread is
# outdated, which head its comments cite, who wrote it, or what its last reply says — an open
# outdated thread, or one a human opened, refuses like any other (fail closed), and a resolved one
# passes whatever its replies say.
#
# GraphQL, because resolution has no REST field — the one read on the gate path that rides it (see
# "REST vs GraphQL" above), and a failed read is UNKNOWN, never "no open threads". The connection
# pages at 100; the read follows it to the end, and is taken as whole only when the rows read
# reach the totalCount its last page states (a count that leads the rows is a partial read, not a
# smaller PR). One still paging at THREADS_PAGE_CAP pages is refused as unread rather than judged
# on its prefix. Reads: one call per 100 threads, made only where an approval is about to be
# reported or acted on — never on a watch round that is not ending on one.
#
# `resolve`'s lookup (find_thread, ported to lib/ludics/prreview/resolve.py with a port of
# `threads_walk` beside it, ludics-lite#403) reads the same connection: one query, one paging loop,
# one cap -- the cap reaches it through PY_FORWARD_VARS, so the two cannot drift apart. Every thread
# this read can name is then one the advertised `resolve` can reach, by the same id — the two once
# paged to different caps (review of #370, round 1), and a lookup matching only `databaseId` would
# miss a thread the gate named by its `fullDatabaseId`. THREADS_QUERY and THREAD_ID_JQ have their
# copies there too, until the gate's port leaves one home for all three.
THREADS_PAGE_CAP=50
THREADS_QUERY='query($owner:String!, $name:String!, $pr:Int!, $after:String) {
  repository(owner:$owner, name:$name) { pullRequest(number:$pr) {
    reviewThreads(first:100, after:$after) {
      totalCount pageInfo { hasNextPage endCursor }
      nodes { id isResolved path
        comments(first:1) { nodes { fullDatabaseId databaseId author { login } } } } } } } }'
# A thread's name: its first comment's id, full width first (the jq filter both readers apply).
THREAD_ID_JQ='((.comments.nodes[0] | .fullDatabaseId // .databaseId // "-") | tostring)'

# Pages PR <pr>'s reviewThreads with THREADS_QUERY and hands each page's connection to
# `<fn> <page json>`, which returns 0 to read on, 1 to stop here (it has what it wanted), or 2 when
# the page did not parse. <fn> runs in THIS shell, so what it collects lands in its caller's locals.
# Exit 0 when <fn> stopped the walk or the whole connection was read — the rows read reaching the
# totalCount the last page states; otherwise ONE line on stdout saying why not, and exit 4 when
# GraphQL rejected the query, 3 for everything else (no answer, a malformed or short answer, the
# cap), none of which is evidence about any thread.
threads_walk() { # <pr> <fn>
  local pr="$1" fn="$2" page cursor="" resp meta total n next read_n=0 rc
  local -a after=()
  for ((page = 1; page <= THREADS_PAGE_CAP; page++)); do
    after=()
    [ -z "$cursor" ] || after=(-f "after=$cursor")
    resp=$(gh_retry read api graphql -f query="$THREADS_QUERY" -F owner="${REPO%%/*}" \
      -F name="${REPO##*/}" -F pr="$pr" ${after[@]+"${after[@]}"} \
      --jq .data.repository.pullRequest.reviewThreads)
    rc=$?
    case "$rc" in
    0) ;;
    1)
      printf '%s\n' "GraphQL REJECTED the review-threads read ($(gh_err_line))"
      return 4
      ;;
    *)
      printf '%s\n' "GraphQL did not answer the review-threads read after $API_ATTEMPTS attempts ($(gh_err_line))"
      return 3
      ;;
    esac
    # A `data.repository.pullRequest` of null (GraphQL's way of erroring inside a 200) prints
    # nothing, and is refused here with every other answer that is not a connection.
    meta=$(jq -r 'select(type == "object" and (.nodes | type == "array")
        and (.totalCount | type == "number") and (.pageInfo.hasNextPage | type == "boolean"))
      | "\(.totalCount)\t\(.nodes | length)\t\(.pageInfo.hasNextPage)\t\(.pageInfo.endCursor // "")"' \
      <<<"$resp" 2>/dev/null) || meta=""
    IFS=$'\t' read -r total n next cursor <<<"$meta"
    case "${total:-x}${n:-x}" in *[!0-9]*)
      printf '%s\n' "the review-threads read answered page $page without a thread connection"
      return 3
      ;;
    esac
    "$fn" "$resp"
    case "$?" in
    0) ;;
    1) return 0 ;;
    *)
      printf '%s\n' "the review-threads read answered page $page with threads that did not parse"
      return 3
      ;;
    esac
    read_n=$((read_n + n))
    if [ "$next" != true ]; then
      if [ "$read_n" -lt "$total" ]; then
        printf '%s\n' "the review-threads read ended at $read_n thread(s) while the PR states $total"
        return 3
      fi
      return 0
    fi
    [ -n "$cursor" ] || {
      printf '%s\n' "the review-threads read said page $page has a successor and gave no cursor to it"
      return 3
    }
  done
  printf '%s\n' "the review-threads read was still paging after $THREADS_PAGE_CAP pages of 100, so it is refused rather than judged on its first $read_n thread(s)"
  return 3
}

# One "<first comment id>\t<author>\t<path>" row per open thread, exit 0, when the whole connection
# was read; otherwise ONE line saying why it was not, exit 3.
unresolved_threads() { # <pr>
  local rows=""
  threads_walk "$1" unresolved_page || return 3
  printf '%s' "$rows"
}

unresolved_page() { # <page json>: appends the page's open threads to unresolved_threads' rows
  local page_rows
  page_rows=$(jq -r ".nodes[] | select(.isResolved != true)
      | [$THREAD_ID_JQ, ((.comments.nodes[0].author.login // \"-\") | tostring),
         ((.path // \"-\") | tostring)] | @tsv" <<<"$1" 2>/dev/null) || return 2
  [ -z "$page_rows" ] || rows="$rows$page_rows"$'\n'
}

# "<count>|<the first ten, named>" of unresolved_threads' rows. The path is repository-controlled,
# so it is shell-quoted; the id is what `reply` and `resolve` take.
threads_named() { # <rows>
  local id login path n=0 shown=""
  while IFS=$'\t' read -r id login path; do
    [ -n "$id" ] || continue
    n=$((n + 1))
    [ "$n" -le 10 ] || continue
    shown="$shown${shown:+, }$id by $login on $(printf '%q' "$path")"
  done <<<"$1"
  [ "$n" -le 10 ] || shown="$shown, and $((n - 10)) more"
  printf '%s|%s' "$n" "$shown"
}

# The clearing instruction, shared by the `unresolved` state line and `merge`'s refusal.
threads_advice() {
  printf '%s' "An open thread is a finding nobody closed, whatever head it cites: one written" \
    " against an earlier head is live if this head did not change its lines, and \`watch\` prints" \
    " such findings as NOT about head and moves past them (ludics-lite#289). Read each one, answer" \
    " it with a fix or a rebuttal (pr-review.sh reply $REPO#${PR_NUM:-<pr>} <id> '<answer>'), then" \
    " close it (pr-review.sh resolve $REPO#${PR_NUM:-<pr>} <id>); clearing this needs no push"
}

# An `approved` state line, checked for open threads: unchanged when there are none, `unresolved`
# when there are, `unknown` when the read did not answer. Any other state passes through unread.
# Line: unresolved|-|<merge>|<count>|<the approval's own detail>|<the threads, named>.
approval_gate() { # <pr> <state line>
  local rows named
  [ "$(state_tok "$2")" = approved ] || {
    printf '%s\n' "$2"
    return 0
  }
  rows=$(unresolved_threads "$1") || {
    printf '%s\n' "unknown|-|$(state_merge "$2")|$rows, so whether open review threads stand under this approval ($(state_detail "$2")) is unknown"
    return 0
  }
  [ -n "$rows" ] || {
    printf '%s\n' "$2"
    return 0
  }
  named=$(threads_named "$rows")
  printf '%s\n' "unresolved|-|$(state_merge "$2")|${named%%|*}|$(state_detail "$2")|${named#*|}"
}

# The state as `status` and every `watch` exit report it: status_state, then the open-thread check
# on an approval. The watch's opening line and its nudge bookkeeping take status_state bare — they
# report nothing a caller acts on as an approval.
gated_state() { # <pr>
  approval_gate "$1" "$(status_state "$1")"
}

# `merge`'s read of the same question: open threads refuse (1), an unread connection refuses as
# transport (3) — neither is "none are open".
merge_threads_gate() { # <pr>
  local rows named
  rows=$(unresolved_threads "$1") ||
    fail 3 "NOT merging $REPO#$1: $rows — whether review threads are still open is UNKNOWN, which" \
      "is not 'none are'; retry."
  [ -n "$rows" ] || return 0
  named=$(threads_named "$rows")
  fail 1 "REFUSING to merge $REPO#$1: ${named%%|*} review thread(s) still UNRESOLVED —" \
    "${named#*|}. $(threads_advice)."
}

# Served by Python since ludics-lite#403 (lib/ludics/prreview/status.py). `watch` and `merge` are
# Python too, so status_state, status_line, gated_state and the thread reads above no longer serve
# any subcommand: they are the shell implementation the ports were made from, until the shell half
# of this file is retired.
cmd_status() { py_forward call status "$@"; }

# `watch` — poll on a timer so a round's arrival wakes the caller instead of the caller re-deriving
# this loop — is served by Python since ludics-lite#403: lib/ludics/prreview/watch.py (the loop,
# the final poll before every verdict, the grace extensions, the once-per-head re-request of a
# failed run), with the round's poll, state, open-thread check, round count and base-drift read
# beside it in poll.py, state.py and drift.py. The shell implementation and its
# comments, which carry the incident behind every rule there, are this file as of the port's
# parent commit (`git show 14f2ca7:ship-pr/scripts/pr-review.sh`). Exit 0 something to act on,
# 1 a quiet window, 3 not observed; the last stdout line is a watermark with poll's semantics. Run
# it in the Bash tool's background mode, and give it the repo: `watch owner/name#<pr>`.
#
# In a subshell, unlike the other stubs: cmd_watch RETURNED its status (1 is a quiet window, not a
# failure), and `py_forward call` exits on any nonzero one, which would end a sourcing caller.
cmd_watch() { (py_forward call watch "$@"); }

# --- the writers and `retry`: PORTED to Python (ludics-lite#403) --------------------------------
# reply, resolve, comment, body and retry (with `retry run watch`, the quiet run await) are served
# by lib/ludics/prreview/{reply,resolve,comment,body,retry,runwatch}.py, which carry these
# functions' rationale, the incident history behind each rule, and their exits; resolve's lookup
# reads the same connection as the open-thread gate, through a port of threads_walk there.
# main() forwards them before reaching its case below. These stubs are for a caller that sources
# the script and calls the function, as the fixture suites do.
cmd_reply() { py_forward call reply "$@"; }
cmd_resolve() { py_forward call resolve "$@"; }
cmd_comment() { py_forward call comment "$@"; }
cmd_body() { py_forward call body "$@"; }
cmd_retry() { py_forward call retry "$@"; }

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

# `--`, because the list is configuration (a variable, or a repository's file): a pattern that
# starts with `-` would otherwise be read as an option, and GNU grep's `--help` exits 0 for every
# name, which makes every check advisory (review of #531).
is_advisory() { printf '%s' "$1" | grep -Eq -- "$BUILD_ADVISORY"; }

# --- the repository's own advisory list (ludics-lite#530) --------------------------------------
# `checks` and `merge` read a repository's advisory list from .github/ship-pr-advisory-checks on its
# DEFAULT branch, and a non-empty SHIP_PR_ADVISORY_CHECKS still wins and skips the read. That read
# is Python's now (lib/ludics/prreview/gate.py, advisory_policy, with the format and the fail-closed
# rules); this variable says whether the caller SET the list, and travels to the Python under its
# own name (PY_FORWARD_VARS), so a default is never read as a caller's choice. `base` does not read
# the file: the integration loop reads the advisory jobs on the merged tip with the default list.
ADVISORY_FROM_ENV=""
[ -z "${SHIP_PR_ADVISORY_CHECKS:-}" ] || ADVISORY_FROM_ENV=1

# --- what `merge --override` waives (ludics-lite#392) ------------------------------------------
# An override is a sentence about a red the operator has READ, so it waives exactly the reds the
# gate saw when it was given, and nothing else. It used to waive the whole verdict: a red fold
# ended the read at once, so lukstafi/ocannl-staging#776 merged over an unrelated ubuntu red while
# its macOS leg was still RUNNING, and nothing had read that leg at all. A check with no verdict is
# not a red, and the override is not the flag for it (SKILL.md *The override*).
#
# THE WAIVED SET is the reds of the gate's FIRST read, the read made when the override was given —
# not the set re-read after a --wait. The operator can only have meant what was red then; a check
# that turns red DURING the wait is one nobody read, so it is a plain red and the merge refuses on
# it (re-run merge to read it, and override it too if it is just as unrelated). Membership is by
# IDENTITY, and the identity outlives a re-run: a waived check that is re-run is waited for while it
# runs (it has no verdict) and stays waived if it concludes red again. Two kinds are recorded, and
# they are all the gate reads:
#   check:<suite>/<name>  a non-advisory check run (build_checks) that was red at the first read,
#                 by its check_suite.id AND its name. The name alone is not an identity: two
#                 workflows can each run a job named `build`, and keying on the name let one
#                 workflow's red waive the other's later failure (review round 1). A re-run stays
#                 in its suite with the same name (pr-review-api-contract.sh pins filter=latest's
#                 superseded attempt as a newer row of the same suite and name); were that ever
#                 to move, the re-run would be refused, the loud direction. Nor is suite-and-name
#                 always unique — two jobs of one workflow may legally share a name (the contract
#                 says so) — and no field tells which of two same-named rows a re-run replaced, so
#                 no bookkeeping over such a pair can say which red is the one that was read
#                 (review rounds 3 and 4: a count was defeated by a re-run swapping the twins). A
#                 key is therefore waived only while it names exactly ONE row: at the first read
#                 (a same-named pair there is not recorded, so its red refuses at once) and at
#                 every read after it (a second row appearing under a waived key un-waives it).
#                 Both are refusals, the loud direction, for a shape this repo's own CI does not
#                 have.
#   run:<run id>  a non-advisory workflow run that was red at the first read with no check to show
#                 for it (run_signal's run-level red), by the INVOCATION: a re-run keeps its run
#                 id (run_attempt bumps), while another dispatch of the same workflow and event is
#                 a new run nobody read. The fold's workflow-and-event key would have handed the
#                 waiver on to that one when it finished red (review round 2).
# A job of a completed red run is the check of the same name in that run's suite (the contract pins
# that join too), so run_red_is_advisory_only reads a job whose `check:<suite>/<name>` is waived as
# explained, exactly as it reads an advisory job (and only while the run has one job of that
# name): otherwise the waived leg's run concludes `failure` once its siblings finish and comes
# back as a red run.
#
# GATE_WAIVE is "" outside an override, `record` for the first read, `apply` after it. It and
# WAIVED are globals because run_signal reads them from inside a command substitution; gate_checks
# resets both on entry, so a `checks` call never inherits a waiver. WAIVED is newline-framed
# (`\n` + one key per line), which is safe because every name reaches here through `@tsv`, which
# escapes a newline inside a name.
GATE_WAIVE=""
WAIVED=$'\n'
is_waived() {
  case "$WAIVED" in *$'\n'"$1"$'\n'*) return 0 ;; esac
  return 1
}

# True when exactly one line of the newline-separated list <list> is <line>.
one_line_is() { # <list> <line>
  local l n=0
  while IFS= read -r l; do
    [ "$l" != "$2" ] || n=$((n + 1))
  done <<<"$1"
  [ "$n" -eq 1 ]
}

# Marks the waived red rows of a build_checks listing as class `waived`, recording every red one
# first when this is the recording read. Sets WAIVER_ROWS rather than printing, because the record
# has to land in THIS shell. Rows keep build_checks' shape and placeholders. Two passes, because a
# key is waived only while it names ONE row (see is_waived), which takes every key read first.
apply_waiver() {
  local class name concl url suite keys=""
  WAIVER_ROWS=""
  while IFS=$'\t' read -r class name concl url suite; do
    [ -n "$class" ] && keys="${keys}check:${suite}/${name}"$'\n'
  done <<<"$1"
  while IFS=$'\t' read -r class name concl url suite; do
    [ -n "$class" ] || continue
    if [ "$class" = red ] && one_line_is "$keys" "check:$suite/$name"; then
      [ "$GATE_WAIVE" != record ] || WAIVED="${WAIVED}check:${suite}/${name}"$'\n'
      is_waived "check:$suite/$name" && class=waived
    fi
    WAIVER_ROWS="${WAIVER_ROWS}${class}"$'\t'"${name}"$'\t'"${concl}"$'\t'"${url}"$'\t'"${suite}"$'\n'
  done <<<"$1"
}

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

# Prints "class<TAB>name<TAB>conclusion<TAB>url<TAB>suite" per non-advisory check-run of <sha>, the
# suite being its check_suite.id: the identity an override's waiver keys on beside the name. Returns 3
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
  local sha="$1" raw rc name concl url suite
  raw=$(gh_retry read api --paginate \
    "repos/$REPO/commits/$sha/check-runs?filter=latest&per_page=100" \
    --jq '.check_runs[] | [.name, (.conclusion // "pending"), (.html_url // "-"),
          ((.check_suite.id // "-") | tostring)] | @tsv')
  rc=$?
  [ "$rc" -eq 0 ] || return 3
  while IFS=$'\t' read -r name concl url suite; do
    [ -n "$name" ] || continue
    is_advisory "$name" && continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$(conclusion_class "$concl")" "$name" "$concl" "$url" "${suite:--}"
  done <<<"$raw"
}

# Folds the per-check classes into VERDICT (red|pending|mixed|absent|green) and the report lines.
# Runs in the current shell — a pipeline would put the loop in a subshell and lose both.
summarize_checks() {
  local class name concl url suite red=0 waived=0 pending=0 nogo=0 green=0 passed=0
  VERDICT=""
  CHECK_LINES=""
  CHECK_RED=0
  # `suite` is read so that `url` stays its own column; only the waiver keys on it.
  while IFS=$'\t' read -r class name concl url suite; do
    [ -n "$class" ] || continue
    case "$class" in
    red)
      red=$((red + 1))
      CHECK_LINES="${CHECK_LINES}  RED      $name ($concl)  $url"$'\n'
      ;;
    waived)
      waived=$((waived + 1))
      CHECK_LINES="${CHECK_LINES}  RED      $name ($concl — WAIVED: red when --override was given)  $url"$'\n'
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
  CHECK_WAIVED="$waived"
  CHECK_PASSED="$passed"
  CHECK_PENDING="$pending"
  CHECK_TOTAL=$((red + waived + pending + nogo + green))
  # A waived red ranks BELOW every fact still owed: it settles nothing about a check that is
  # running or stopped, which keep their own verdicts (ludics-lite#392).
  if [ "$red" -gt 0 ]; then
    VERDICT=red
  elif [ "$pending" -gt 0 ]; then
    VERDICT=pending
  elif [ "$nogo" -gt 0 ]; then
    VERDICT=mixed
  elif [ "$waived" -gt 0 ]; then
    VERDICT=waived
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
# Prints "<red count><TAB><waived runs><TAB><reason>" — a count, because gate_checks reports through
# CHECK_RED and a command substitution cannot hand it back a variable; and the red runs an
# override's waiver took out of that count (see is_waived), one "<run id> <run|job> <name>" per
# line (`job`: red through a waived check; `run`: a checkless red waived as itself), empty outside
# an override, because the recording read has to add them to WAIVED in gate_checks' own shell — and
# returns
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
# fragment). One printf for the count and the waived names, one for the message.
run_reason() {
  local n="$1" waived="$2"
  shift 2
  printf '%s\t%s\t' "$n" "$waived"
  printf '%s' "$@"
}

# Prints "name<TAB>conclusion<TAB>created_at<TAB>completed_at" per job of run <id> — the one
# projection both job reads below share, so a red run and an in-flight one are read the same way.
# Every field gets the "-" placeholder, empty strings included, for the reason gate_checks' PR read
# gives: one empty field collapses under tab-IFS `read` and shifts every later column into the
# slot before it. An unfinished job's null conclusion renders `pending`, as it always has.
run_jobs() {
  gh_retry read api --paginate "repos/$REPO/actions/runs/$1/jobs?per_page=100" \
    --jq '.jobs[] | [(.name // "-"), (.conclusion // "pending"), (.created_at // "-"),
          (.completed_at // "-")]
          | map(if type == "string" and length > 0 then . else "-" end) | @tsv'
}

# A workflow run's aggregate conclusion is not always a build verdict. The advisory list is a
# deny-list of CHECK names (SHIP_PR_ADVISORY_CHECKS), and build_checks applies it per check run —
# so a non-advisory workflow carrying one advisory JOB reports `failure` at the run level when
# only that job failed, and reading the run's red would restore a failure the gate was configured
# to ignore (ludics-lite#38, round 4). The run's own jobs settle it: true when the run has jobs
# and none of the non-advisory ones is red, i.e. its red is entirely explained by jobs the gate
# ignores. A run with NO jobs (the `startup_failure` case this red branch exists for) is not
# explained, and neither is a jobs read that failed — a red this cannot disprove stands.
# Returns 0 when advisory jobs alone explain the red, 2 when it is explained but a job an override
# waived is part of the explanation, 1 when it is not explained. 2 is not 0 because a red waived is
# still a red: dropping it like an advisory one let a poll whose check list momentarily lacked the
# waived row read the head as GREEN, with no OVERRIDE record, and past --require-green (review
# round 5). The caller reports it as a waived red instead.
run_red_is_advisory_only() {
  local id="$1" suite="${2:--}" raw rc jname jconcl jtimes jobs=0 hard=0 waived=0 names=""
  raw=$(run_jobs "$id")
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  # The run's job names, read first: a job is waived only while it is the one job of its name
  # (see is_waived). `jtimes` takes the columns only the in-flight read needs.
  while IFS=$'\t' read -r jname jconcl jtimes; do
    [ -n "$jname" ] && names="${names}${jname}"$'\n'
  done <<<"$raw"
  while IFS=$'\t' read -r jname jconcl jtimes; do
    [ -n "$jname" ] || continue
    jobs=$((jobs + 1))
    is_advisory "$jname" && continue
    [ "$(conclusion_class "$jconcl")" = red ] || continue
    # A job an override waived as its check explains its run's red the same way (ludics-lite#392,
    # see is_waived). Outside an override WAIVED is empty and this never holds.
    if one_line_is "$names" "$jname" && is_waived "check:$suite/$jname"; then
      waived=$((waived + 1))
      continue
    fi
    hard=$((hard + 1))
  done <<<"$raw"
  [ "$jobs" -gt 0 ] && [ "$hard" -eq 0 ] || return 1
  [ "$waived" -eq 0 ] || return 2
  return 0
}

# The in-flight half of the same question (ludics-lite#500). An unfinished run used to hold the
# gate on its row alone, so a run whose only unfinished jobs were advisory held `merge --wait` for
# the whole of them: on 2026-10-01 two PRs merged under an advisory macOS setting and both still
# waited out the ~55 min macOS runner queue (#489 sat 21 minutes after its last required job). The
# advisory list is about JOBS as much as runs, so a run whose every unfinished job is advisory has
# no build verdict on the way and does not hold. True (0) only when ALL of these hold, and every
# doubt holds the run (1), because releasing a run too early merges over a verdict nobody read:
#   - the jobs read answered (a failed read proves nothing);
#   - the run lists at least one unfinished job, and every unfinished job is advisory. No jobs at
#     all is a run that has not created them yet; no unfinished job in a run that is still in
#     flight is a run between jobs (below), or finishing — its row's own conclusion settles it;
#   - every finished non-advisory job is green. A red or stopped one is the check fold's to
#     report, and the run's row says the rest once it concludes — this read only ever RELEASES,
#     it never decides a red;
#   - the run's job list has been still for ADVISORY_SETTLE seconds: no job of it was created or
#     finished more recently than that.
# That last clause is the `needs:` boundary, and the reason this is not a plain name check. GitHub
# creates a job only once its `needs:` are met, and the jobs feed does not list it before then.
# Read live on 2026-10-02: skill-scripts.yml run 36988361670 listed 3 jobs (total_count=3) while
# `changes` was queued, and all 11 once it had finished; base-watch run 36988361969 listed `read`
# alone while `report` (needs: read) waited. On every earlier run of skill-scripts.yml read the
# same day, each `needs: changes` job's created_at equals `changes`' completed_at to the second. So a
# required job waiting on a finished job can be missing from a read taken in the instant between
# the one finishing and the other being created, while an advisory job still runs; the settle
# outlasts that instant, and costs at most one more poll after the last required job. What no read
# can see is a required job that `needs:` an ADVISORY job still running: it does not exist yet,
# so the run is released before it ever runs. That is a boundary of this read, stated where the
# advisory list is configured (the usage text above): a required job must not `needs:` an
# advisory one.
ADVISORY_SETTLE=60
run_inflight_is_advisory_only() {
  local raw rc jname jconcl jcreated jdone unfinished=0 last="" age
  raw=$(run_jobs "$1")
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  while IFS=$'\t' read -r jname jconcl jcreated jdone; do
    [ -n "$jname" ] || continue
    # A job with no creation time cannot be placed against the settle, so it proves nothing.
    [ "${jcreated:--}" != - ] || return 1
    last=$(newest "$last" "$jcreated")
    if [ "$(conclusion_class "$jconcl")" = pending ]; then
      is_advisory "$jname" || return 1
      unfinished=$((unfinished + 1))
      continue
    fi
    [ "${jdone:--}" != - ] || return 1
    last=$(newest "$last" "$jdone")
    is_advisory "$jname" && continue
    [ "$(conclusion_class "$jconcl")" = green ] || return 1
  done <<<"$raw"
  [ "$unfinished" -gt 0 ] || return 1
  # age_of answers "-" for a missing or FUTURE timestamp, and either is no settle.
  age=$(age_of "$last")
  case "$age" in '' | *[!0-9]*) return 1 ;; esac
  [ "$age" -ge "$ADVISORY_SETTLE" ]
}

run_signal() {
  local sha="$1" pr_at="${2:-}" checks="${3:-0}" base_sha="${4:-}" head_ref="${5:-}" pr="${6:-}"
  local raw rc rid wid event name status concl suite
  local seen_ids=" " red_rows="" rname rconcl rsuite created
  local runs=0 inflight=0 nogo=0 red=0 red_note="" pushed_at age seen waived_runs=""
  local inflight_ids="" released=0
  raw=$(gh_retry read api --paginate \
    "repos/$REPO/actions/runs?head_sha=$sha&per_page=100" \
    --jq '.workflow_runs[] | [(.created_at // "-"), ((.id // 0) | tostring),
          ((.workflow_id // 0) | tostring),
          (.event // "-"), (.name // "-"), (.status // "unknown"), (.conclusion // "pending"),
          ((.check_suite_id // "-") | tostring)]
          | @tsv')
  rc=$?
  [ "$rc" -eq 0 ] || {
    run_reason 0 "$waived_runs" "the workflow runs for this head could not be read ($(gh_err_line))"
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
  while IFS=$'\t' read -r created rid wid event name status concl suite; do
    [ -n "$rid" ] || continue
    is_advisory "$name" && continue
    # A run reported `completed` before its conclusion is populated is not judged either: the
    # projection renders that null as `pending`, which is neither red nor stopped, and counting it
    # as finished-and-judged would let a green check — or, on a checkless head, the eventual
    # ABSENT — carry a workflow that has concluded nothing (round 4).
    # Counted as in flight only after its jobs are read, below.
    if [ "$status" != completed ] || [ "$(conclusion_class "$concl")" = pending ]; then
      runs=$((runs + 1))
      inflight_ids="${inflight_ids}${rid}"$'\n'
      continue
    fi
    case "$seen_ids" in *" $wid/$event "*) continue ;; esac
    seen_ids="$seen_ids$wid/$event "
    runs=$((runs + 1))
    case "$(conclusion_class "$concl")" in
    red) red_rows="${red_rows}${rid}"$'\t'"${name}"$'\t'"${concl}"$'\t'"${suite:--}"$'\n' ;;
    nogo) nogo=$((nogo + 1)) ;;
    esac
  done <<<"$raw"
  # Each red run gets the advisory-job read before it counts — one call, only ever for a run that
  # is already red, and only when no check run reported that failure.
  if [ -n "$red_rows" ]; then
    while IFS=$'\t' read -r rid rname rconcl rsuite; do
      [ -n "$rid" ] || continue
      run_red_is_advisory_only "$rid" "$rsuite"
      case "$?" in
      0) continue ;;
      # Red through a check the override waived: a waived red, handed back as one (kind `job`).
      2)
        waived_runs="${waived_runs}${rid} job ${rname}"$'\n'
        continue
        ;;
      esac
      # Under an override, a run-level red it waives (or, on the recording read, every one there
      # is) is handed back to gate_checks as "<run id> run <name>" and not counted
      # (ludics-lite#392).
      if [ "$GATE_WAIVE" = record ] || { [ "$GATE_WAIVE" = apply ] && is_waived "run:$rid"; }; then
        waived_runs="${waived_runs}${rid} run ${rname}"$'\n'
        continue
      fi
      red=$((red + 1))
      [ -n "$red_note" ] || red_note="$rname ($rconcl)"
    done <<<"$red_rows"
  fi
  # Red first: it is a verdict, and a verdict ends the wait. Reaching here at all means the check
  # fold found no red, so this run's failure is one no check run reported — the whole reason to
  # look at the run list rather than trusting the check list to carry every failure.
  if [ "$red" -gt 0 ]; then
    run_reason "$red" "$waived_runs" "$red workflow run(s) for this head concluded red with no build check" \
      " to show for it — $red_note; a run that fails before its jobs start leaves nothing in the" \
      " check list"
    return 1
  fi
  # Each in-flight run gets its jobs read before it holds — one call per in-flight run, made only
  # once no red has already decided the answer, and a run whose every unfinished job is advisory
  # is released (see run_inflight_is_advisory_only). It still counts among `runs`: it is an Actions
  # run behind the head's checks, and its finished jobs are among them.
  while IFS= read -r rid; do
    [ -n "$rid" ] || continue
    if run_inflight_is_advisory_only "$rid"; then
      released=$((released + 1))
    else
      inflight=$((inflight + 1))
    fi
  done <<<"$inflight_ids"
  if [ "$inflight" -gt 0 ]; then
    run_reason 0 "$waived_runs" "$inflight workflow run(s) for this head have no conclusion yet (queued," \
      " running, or completed with none recorded) — their check runs may not exist yet"
    return 4
  fi
  if [ "$nogo" -gt 0 ]; then
    run_reason 0 "$waived_runs" "$nogo workflow run(s) for this head completed stopped-not-judged (cancelled," \
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
    if [ "$released" -gt 0 ]; then
      run_reason 0 "$waived_runs" "$runs workflow run(s) for this head are judged — $released of them" \
        " still running, but only advisory jobs (SHIP_PR_ADVISORY_CHECKS)"
    else
      run_reason 0 "$waived_runs" "$runs workflow run(s) for this head are finished and judged"
    fi
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
    run_reason 0 "$waived_runs" "no usable clock for this head: neither its commit date nor the PR's updated_at" \
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
    head_within_paths_ignore "$pr" "$sha" "$base_sha" "$head_ref"; then
    run_reason 0 "$waived_runs" "no workflow run exists for this head, and none can be created by" \
      " $PATHS_IGNORE_WHY: every trigger of theirs that this change fires is either filtered" \
      " out by its own paths-ignore — every commit from the merge base up changes only ignored" \
      " paths — or cannot reach this branch at all"
    return 0
  fi
  if [ "$age" -lt "$ABSENT_GRACE" ]; then
    run_reason 0 "$waived_runs" "$seen, and the head has been in place at most $(fmt_age "$age") — inside the" \
      " $(fmt_age "$ABSENT_GRACE") run-creation grace (SHIP_PR_BASE_ABSENT_GRACE), so a run" \
      " may still appear"
    return 4
  fi
  run_reason 0 "$waived_runs" "$seen in the $(fmt_age "$age") since it appeared — past the" \
    " $(fmt_age "$ABSENT_GRACE") run-creation grace"
  return 0
}

# Reads the PR's head SHA and judges its build signal, from the check runs AND — whenever those
# leave nothing to wait for — the head's workflow runs. Sets VERDICT and prints the report.
# 0 = green, or an absence run_signal confirmed is the verdict (nothing is red), 1 = RED (a check
# or a checkless run), 3 = the API did not answer, 4 = no verdict yet (still running, stopped
# without a verdict, or a run for this head has yet to produce its checks), 5 = superseded head.
# A third argument `waive` is merge --override's: the first read's reds are recorded as waived
# (see is_waived), and a head whose every red is one of them, with every other check and run
# judged, is VERDICT=waived — still exit 1, since it IS red, but the only red cmd_merge's
# override takes. Anything still running under a waived red is 4 and held by --wait like any
# other; a red that is not in the set is VERDICT red or runred, as it would be without one.
gate_checks() {
  local pr="$1" wait_for="${2:-0}" sha lines rc deadline started beat now sleep_for remaining
  local run_why="" run_info note pr_at="" base_sha="" head_ref="" current_sha waived_runs rname rid
  GATE_BASE=""
  WAIVED=$'\n'
  RUN_WAIVED=0
  CHECK_WAIVED=0
  case "${3:-}" in
  waive) GATE_WAIVE=record ;;
  *) GATE_WAIVE="" ;;
  esac
  # One read for both: the head to judge, and the PR's own last-updated stamp, which run_signal
  # uses as the push clock a stale committer date cannot provide. Tab-separated with a placeholder
  # for the same reason build_checks uses one — an empty field would collapse under tab-IFS.
  # Captured first, then split: a process substitution would hand `read` the exit status and lose
  # gh_retry's, and a failed read that reports 0 is the one thing this gate must never do.
  # The PR's base SHA rides along for the same reason `updated_at` does: it costs no extra call,
  # and run_signal needs it to ask whether a run for a run-less head can be created at all — the
  # range it walks starts at this head's merge base with the base branch (ludics-lite#176).
  # EVERY field gets the placeholder, not just the ones that can be null. An empty string is not
  # null, so `// "-"` alone leaves it empty — and one empty field COLLAPSES under tab-IFS `read`,
  # shifting every later field into the slot before it. With `.head.sha` leading, a PR read
  # answering with an empty head would put `updated_at` into `sha` and sail past the emptiness
  # check below. That is the same trap build_checks' own placeholder documents; it just had one
  # field to lose before and has four now.
  lines=$(gh_retry read api "repos/$REPO/pulls/$pr" \
    --jq '[(.head.sha // "-"), (.updated_at // "-"), (.base.sha // "-"), (.head.ref // "-")]
          | map(if type == "string" and length > 0 then . else "-" end) | @tsv')
  rc=$?
  IFS=$'\t' read -r sha pr_at base_sha head_ref <<<"$lines"
  [ "${sha:--}" != - ] || sha=""
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
    if [ -n "$GATE_WAIVE" ]; then
      apply_waiver "$lines"
      lines="$WAIVER_ROWS"
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
    RUN_WAIVED=0
    # The base THIS round's run read is about, for cmd_merge: an ABSENT verdict can rest on it (the
    # paths-ignore recognition reads the base's workflows), and the merge call binds only the head,
    # so merge re-reads the base before each attempt and re-gates when it moved (ludics-lite#523).
    GATE_BASE="$base_sha"
    if [ "$VERDICT" != red ]; then
      run_info=$(run_signal "$sha" "$pr_at" "$CHECK_TOTAL" "$base_sha" "$head_ref" "$pr")
      rc=$?
      run_why="${run_info#*$'\t'}"
      waived_runs="${run_why%%$'\t'*}"
      run_why="${run_why#*$'\t'}"
      # The run-level reds the waiver took out of run_signal's count: recorded when this is the
      # recording read, and reported either way, since they are reds the merge goes over.
      while IFS= read -r rname; do
        [ -n "$rname" ] || continue
        RUN_WAIVED=$((RUN_WAIVED + 1))
        rid="${rname%% *}"
        rname="${rname#* }"
        case "${rname%% *}" in
        job) CHECK_LINES="${CHECK_LINES}  RED      workflow run ${rname#* } (red through a check above that is WAIVED)"$'\n' ;;
        *)
          # Only a checkless red is waived by its run id; one red through a waived check is
          # covered by that check's key, and recording its id would waive the run's later reds.
          [ "$GATE_WAIVE" != record ] || WAIVED="${WAIVED}run:${rid}"$'\n'
          CHECK_LINES="${CHECK_LINES}  RED      workflow run ${rname#* } (no build check behind it — WAIVED: red when --override was given)"$'\n'
          ;;
        esac
      done <<<"$waived_runs"
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
      # Everything judged, and the only red a run-level one the override waived.
      # A run released while still running (only advisory jobs left in it) is named in the
      # report: the verdict stands over work that has not finished, and the reader should see
      # that it was the advisory list that let it (ludics-lite#500).
      0)
        [ "$RUN_WAIVED" -eq 0 ] || case "$VERDICT" in green | absent) VERDICT=waived ;; esac
        case "$run_why" in
        *"only advisory jobs"*) CHECK_LINES="${CHECK_LINES}  running  $run_why — not waited for"$'\n' ;;
        esac
        ;;
      esac
    fi
    # The first read is the one the override was given against; every later one applies it.
    [ "$GATE_WAIVE" != record ] || GATE_WAIVE=apply
    # Revalidate every observation, including a terminal green or stopped old head. This
    # never follows the successor: the checks and merge binding remain about the original SHA.
    # The base and the head ref ride along, refreshed for the NEXT round: a retarget or a base
    # advance moves the evidence the paths-ignore recognition rests on without moving the head
    # (review round 9). The recognition re-confirms them itself before it settles anything, so a
    # move mid-round costs a round rather than a wrong absence.
    lines=$(gh_retry read api "repos/$REPO/pulls/$pr" \
      --jq '[(.head.sha // "-"), (.base.sha // "-"), (.head.ref // "-")]
            | map(if type == "string" and length > 0 then . else "-" end) | @tsv')
    rc=$?
    IFS=$'\t' read -r current_sha base_sha head_ref <<<"$lines"
    [ "${current_sha:--}" != - ] || current_sha=""
    [ "${base_sha:--}" != - ] || base_sha=""
    [ "${head_ref:--}" != - ] || head_ref=""
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
    # Capped at the remaining deadline, same as cmd_base and `retry run watch`: an interval longer
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
  waived) echo "build signal $REPO#$pr @${sha:0:8}: RED, WAIVED — every red ($((CHECK_WAIVED + RUN_WAIVED))) was red when --override was given; everything else has a verdict and none is red" ;;
  pending) echo "build signal $REPO#$pr @${sha:0:8}: NO VERDICT YET — still running" ;;
  mixed) echo "build signal $REPO#$pr @${sha:0:8}: INCOMPLETE — $CHECK_GREEN passed, the rest were stopped without a verdict" ;;
  runred) echo "build signal $REPO#$pr @${sha:0:8}: RED — $run_why" ;;
  unjudged) echo "build signal $REPO#$pr @${sha:0:8}: NO VERDICT YET — $run_why$note" ;;
  absent) echo "build signal $REPO#$pr @${sha:0:8}: ABSENT — no build check ran on this commit: $run_why" ;;
  green) echo "build signal $REPO#$pr @${sha:0:8}: green — $CHECK_GREEN build checks passed" ;;
  esac
  [ -n "$CHECK_LINES" ] && printf '%s' "$CHECK_LINES"
  case "$VERDICT" in
  red | runred | waived) return 1 ;;
  pending | mixed | unjudged) return 4 ;;
  *) return 0 ;;
  esac
}

# `checks <pr> [--wait[=seconds]]`: the head's build signal, ending with its `checks: verdict=`
# trailer. PORTED to Python (ludics-lite#403): lib/ludics/prreview/checks.py, which reads the
# repository's advisory list (gate.py's advisory_policy) and then the gate. main() forwards it before
# reaching the case below; this stub is for a caller that sources the script and calls the
# function, as the fixture suites do.
cmd_checks() { py_forward call checks "$@"; }

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
# a PR merges on one build verdict for its own head, never on the base's tip (ship-pr SKILL.md,
# *How stale the base has grown*, states the gate). The gate's cost was structural (every
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
      "read."
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
    # The wording is the policy (ship-pr SKILL.md, *How stale the base has grown*): a clean merge
    # lands on the run that went green, and only a conflict moves the head. Six workers of the
    # 2026-09-04 wave read an older "rebase, push, and let checks re-run" as an instruction they
    # had just failed to follow, then watched the merge proceed anyway (ludics-lite#54).
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
    echo "!!! Read those files for semantic drift. The overlap is not a reason to rebase: rebase"
    echo "!!! (or merge $base in) only to resolve a conflict."
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

# `merge <pr> [--override <reason>] [--wait[=s]] [--allow-no-verdict] [--require-green] [-- <gh pr
# merge args...>]`: the build gate, then the merge of the head it was read for. PORTED to Python
# (ludics-lite#403): lib/ludics/prreview/merge.py, with the closing-keyword scans of the body and
# the commit series (closekw.py), the base-drift read (drift.py), the open-thread gate (threads.py)
# and the gate itself (gate.py). Those modules carry the rationale and the review history the
# shell's comments here carried; `git show e86cba3:ship-pr/scripts/pr-review.sh` has the shell as
# it was. main() forwards it before reaching the case below; this stub is for a caller that sources
# the script, as the fixture suites do. `base` and `watch` read the same gate.py and drift.py, so
# gate_checks and warn_base_drift here no longer serve any subcommand.
cmd_merge() { py_forward call merge "$@"; }

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

# WORKFLOW_KEYS: the keys a workflow file DECLARES at one level of its `on:` block — the trigger
# events themselves with `-v want=`, or the keys under one named event with `-v want=push` — one
# per line, or exit 1 when they cannot be established.
#
# PRESENCE, separately from parsing, and round 10 is why that distinction has to exist. The probes
# that ask "does this trigger carry a tag filter" used to be the pattern reader run for its exit
# status, which is 1 both when the key is absent and when it is present in a form this narrow
# parser cannot read — so an unparseable `tags:` read as no tags at all, and a push that a tag
# could reach was declared unreachable. A key is now found by name, and only the keys whose VALUES
# are needed are parsed.
#
# Same narrowness as the pattern reader: the mapping form, the one-scalar form (`on: push`) and the
# flow form (`on: [push, pull_request]`), and a refusal for everything else, a key that is not a
# plain identifier included. Under a named event, no keys at all is an answer (exit 0, nothing
# printed); at the `on:` level it is not, since a workflow with no trigger is a file this has
# misread.
WORKFLOW_KEYS='
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
  if (s !~ /^[A-Za-z_][A-Za-z0-9_-]*$/) { bad = 1; exit }
  n++; key_of[n] = s
}
function flow(s,   i, m, parts) {
  s = substr(s, 2, length(s) - 2)
  m = split(s, parts, ",")
  for (i = 1; i <= m; i++) emit(parts[i])
  ok = 1
}
BEGIN { ev_ind = -1; kw_ind = -1 }
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
    # `on: push` and `on: [push, ...]` declare events and NOTHING under them, so a caller asking
    # for one event finds no keys — which is not the same as finding the file unreadable, and the
    # END below tells them apart by the state.
    if (rest ~ /^\[.*\]$/) { if (want == "") flow(rest); else ok = 1; exit }
    if (want == "") { emit(rest); ok = 1; exit }
    ok = 1; exit
  }
  next
}
state == 1 {
  if (ind <= on_ind) { ok = 1; exit }
  # The events are the keys at the FIRST level under `on:`; anything deeper is one event own
  # mapping, and anything shallower than that level but still inside the block is a file this
  # parser will not claim to have read.
  if (ev_ind < 0) ev_ind = ind
  if (ind < ev_ind) { bad = 1; exit }
  if (ind > ev_ind) next
  if (key !~ /^[A-Za-z_][A-Za-z0-9_-]*[ ]*:/) { bad = 1; exit }
  k = key
  sub(/[ ]*:.*$/, "", k)
  if (want == "") { emit(k); next }
  if (k == want) { state = 2; want_ind = ind }
  next
}
state == 2 {
  if (ind <= want_ind) { ok = 1; exit }
  if (kw_ind < 0) kw_ind = ind
  if (ind < kw_ind) { bad = 1; exit }
  if (ind > kw_ind) next
  if (key !~ /^[A-Za-z_][A-Za-z0-9_-]*[ ]*:/) { bad = 1; exit }
  k = key
  sub(/[ ]*:.*$/, "", k)
  emit(k)
  next
}
END {
  if (!bad && (state == 1 || state == 2)) ok = 1
  if (bad || !ok) exit 1
  # An `on:` MAPPING that never reached the named event did not declare it, and that is not an
  # answer about its keys. (State 0 here is the scalar or flow form, where the event is declared
  # with no keys at all, which IS an answer.)
  if (want != "" && state == 1) exit 1
  # At the on: level, a file declaring no trigger at all is one this has misread.
  if (want == "" && n == 0) exit 1
  for (i = 1; i <= n; i++) print key_of[i]
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
# How many entries the Contents API serves for a directory before it truncates. It offers no
# pagination past this, so a directory at the cap is a directory this cannot read, and the answer
# is a refusal rather than a shorter inventory (review round 6) — the same shape commit_files uses
# for its own 300-file cap.
CONTENTS_DIR_CAP=1000


workflow_files_at() {
  local raw count
  # The count is of the WHOLE array and leads the rows, as it does on the workflow list and on the
  # provider sample. Counting what survived `select(.type == "file")` would be the cap read one
  # projection too late (review round 7): the limit is on entries, so a response holding
  # directories can carry fewer than the cap in files and still have left a later workflow out.
  raw=$(gh_retry read api "repos/$REPO/contents/.github/workflows?ref=$1" \
    --jq 'if type == "array" then (((. | length) | tostring),
                                   (.[] | select(.type == "file") | .path))
          else empty end') || return 1
  [ -n "$raw" ] || return 1
  count="${raw%%$'\n'*}"
  raw="${raw#*$'\n'}"
  case "$count" in '' | *[!0-9]*) return 1 ;; esac
  [ "$count" -gt 0 ] || return 1
  [ "$count" -lt "$CONTENTS_DIR_CAP" ] || return 1
  printf '%s\n' "$raw" | grep -E '\.ya?ml$'
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

PATHS_IGNORE_WHY=""

# commit_files <sha>: the paths ONE commit changed, one per line, or nothing (exit 1) when the
# answer is not evidence — an empty list (a commit whose files the API omitted, an empty
# first-parent diff) and a list of 300 or more both say nothing about the whole commit. A merge
# commit answers with its FIRST-PARENT diff, which is the change the merge brought to the branch.
# Renames carry both names, since both are changed paths.
#
# PAGINATED, because a commit's files are: an unpaginated read answers one default page of 300
# files with a rel=next link past it, so a wide commit's single read hides every file after the
# first page — a page taken for a diff (ludics-lite#163 review, round 2). The paginated read is
# whole well past 300 (GitHub documents 3000 as the most it serves; pr-review-api-contract.sh pins
# the default page, per_page, and a 353-file read joining whole — ludics-lite#177, which found the
# "30 a page, 300 in all" this comment once said to be wrong on both counts). So the refusal at 300
# is conservative, not a cap the endpoint imposes: it costs a docs push that wide the grace, and it
# is the backstop that refuses an unpaginated read, whose wide answer is exactly 300. One row per
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
# `push` REFUSES, always, and four rounds of review are the argument. Nothing about a push event
# can be established from the feeds this reads. Its changed files are computed between the push's
# own before and after, and after a non-fast-forward push the before is not on the path walked here
# (round 1), so no path filter describes it. Whether its `branches:` list can be reached is not
# answerable either: a tag push carries the same SHA (round 9), so does a push to another branch,
# and `branches-where-head` — the one lookup that could name those branches — describes where the
# SHA is head NOW rather than where it was pushed, so a matching branch that has since advanced or
# been deleted is invisible while its run is still being created (round 11). Each fix closed its
# case and the next round found another, which is the signal to stop: the pre-push context is not
# in any feed here, and a rule that cannot see it cannot be completed.
#
# What that costs is stated plainly, because it is most of this recognition's reach: a repository
# whose CI workflow declares `on: push` at all — which is most of them — gets no fast path, and its
# docs-only PR heads wait the absence grace out exactly as they did before ludics-lite#176. What
# remains is the workflow triggered on `pull_request` alone, where the question is answerable, and
# the grace carries every other head as it always has.
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

# head_within_paths_ignore <pr> <head sha> <PR base sha> <PR head ref>: true when NO workflow of this
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
# substitution where an assignment dies with the subshell.
head_within_paths_ignore() {
  local pr="$1" head="$2" base="$3" ref="$4" mbase wf total rows wid wname wstate wpath body bbody
  local rfiles declared bdeclared listed="" f evs ev pats confirm why=""
  # The head ref is not read for a filter any more — `push` refuses outright — but it is still
  # evidence about WHICH pull request this is, and it is re-confirmed with the two SHAs below: a
  # retarget that moved it would mean the round's reads were about another target.
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
  # EVERY listed workflow is explained, the advisory ones included. The shortcut that skipped them
  # was mine and it rested on the wrong reading of the wrong file: the name in this list has no
  # ref, so it describes the DEFAULT branch's copy, while what runs for this PR is the copy at the
  # head and the base. A file whose default-branch copy is named `github pages docs` and whose
  # target-context copy is an ordinary `ci` would have been skipped while its run was being
  # created (review round 6). Reading the name out of the body instead would mean one more YAML
  # reader and one more thing to get wrong, for a saving of a few reads — so the shortcut is gone
  # instead. What it costs is a repository carrying an advisory workflow whose own filter cannot
  # explain it: that head now waits the grace out, which is the safe direction and where it was
  # before any of this. `wname` survives only to name the workflows in the settle line.
  while IFS=$'\t' read -r wid wname wstate; do
    [ -n "$wid" ] || continue
    # The path is read for EVERY listed workflow, disabled ones included, because what it is
    # collected for is the completeness check below: what matters there is only whether the list
    # carries the file at all.
    wpath=$(workflow_path "$wid") || return 1
    listed="${listed}${wpath}"$'\n'
    # A non-`active` row — disabled, or listed after the file was deleted — describes the DEFAULT
    # branch, like every other field of this list. If the file is nonetheless present at either end
    # of THIS merge, the merge context can still run it (a PR against a branch that kept a workflow
    # the default branch dropped is the shape), so it is examined like any other. Only a row whose
    # file is in neither end is skipped: there is nothing there to read and nothing to wait for
    # (review round 8).
    if [ "$wstate" != active ]; then
      grep -qxF -- "$wpath" <<<"$declared"$'\n'"$bdeclared" || continue
    fi
    body=$(workflow_body "$wpath" "$head") || return 1
    bbody=$(workflow_body "$wpath" "$base") || return 1
    [ "$body" = "$bbody" ] || return 1
    evs=$(awk -v q="'" -v dq='"' -v want= "$WORKFLOW_KEYS" <<<"$body") || return 1
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
  # The BASE is evidence here, not just the head — the workflow bodies, the file inventory and the
  # merge base all came from it — and a PR can be RETARGETED, or its base advance, with the head
  # untouched, which the caller's head-only revalidation would not notice and which
  # `--match-head-commit` does not bind either (review round 9). So all three are re-read at the
  # end and must be what they were: anything else, and this round's evidence is about a target the
  # PR no longer has. The caller refreshes them for the next round, which then judges the new one.
  confirm=$(gh_retry read api "repos/$REPO/pulls/$pr" \
    --jq '[(.head.sha // "-"), (.base.sha // "-"), (.head.ref // "-")]
          | map(if type == "string" and length > 0 then . else "-" end) | @tsv') || return 1
  [ "$confirm" = "$head"$'\t'"$base"$'\t'"$ref" ] || return 1
  PATHS_IGNORE_WHY="$why"
  return 0
}

# `base` is served by lib/ludics/prreview/base.py (ludics-lite#403): the fold, the RED report, the
# --wait loop, the pushless named sources and the interim. It reads the workflow files and the
# paths-ignore walk through workflows.py and judges a merged PR head's signal through gate.py, the
# same ports `checks` and `merge` use; the shell helpers above no longer serve any subcommand.
cmd_base() { py_forward call base "$@"; }

# --- the Python half (ludics-lite#403) -------------------------------------------------------------
# The v2 rewrite moves this script to type-checked Python one subcommand at a time, behind the same
# command line: the subcommands named in PY_PORTED are served by lib/ludics/prreview/<name>.py, run
# through scripts/py (which picks a Python >= 3.12), with the same arguments; every other
# subcommand is the shell below. main() EXECs a ported one, so the Python's exit status, stdout and
# stderr are the command's own. A ported cmd_<name> is a one-line `py_forward call <name> "$@"`
# stub for callers that source this file (the fixture suites): it returns 0 when the Python did
# and exits with its status otherwise, which is what the shell function did on its `fail` paths.
#
# Porting a subcommand: its module in lib/ludics/prreview/, its `case` in that package's
# __main__.py, its name here, its cmd_<name> reduced to the stub, and every constant it reads in
# PY_FORWARD_VARS. lib/ludics/README.md says the rest.
PY_PORTED=" body reply resolve comment retry poll status rounds checks merge base watch "
# The source-time constants the Python side reads, as <shell variable>=<environment name>. The
# VALUE handed over is the shell's own, not the caller's environment: a suite that `retune`s
# API_ATTEMPTS, or main's --repo, has changed the variable and not the environment. Name a constant
# here only when its environment name means "the caller set this" in the Python as well -- a
# constant whose being SET is itself read (SHIP_PR_ADVISORY_CHECKS, ADVISORY_FROM_ENV) needs its own
# name for the forward, or the Python would read every default as a caller's choice. So does one no
# caller's environment sets at all (THREADS_PAGE_CAP): its LUDICS_ name is the forward's alone.
PY_FORWARD_VARS=(REPO=REPO REVIEWER=REVIEWER ROUND_THRESHOLD=SHIP_PR_ROUND_THRESHOLD
  ROUND_GAP=SHIP_PR_ROUND_GAP API_ATTEMPTS=SHIP_PR_API_ATTEMPTS API_BACKOFF=SHIP_PR_API_BACKOFF
  GRACE=SHIP_PR_REVIEW_GRACE STALL=SHIP_PR_REVIEW_STALL STALE_BASE=SHIP_PR_STALE_BASE
  CHECKS_INTERVAL=SHIP_PR_CHECKS_INTERVAL CHECKS_WAIT=SHIP_PR_CHECKS_WAIT
  CHECKS_HEARTBEAT=SHIP_PR_CHECKS_HEARTBEAT ABSENT_GRACE=SHIP_PR_BASE_ABSENT_GRACE
  BUILD_ADVISORY=LUDICS_BUILD_ADVISORY ADVISORY_FROM_ENV=LUDICS_PR_ADVISORY_FROM_ENV
  ADVISORY_SETTLE=LUDICS_PR_ADVISORY_SETTLE CONTENTS_DIR_CAP=LUDICS_PR_CONTENTS_DIR_CAP
  IGNORE_MAX_COMMITS=LUDICS_PR_IGNORE_MAX_COMMITS THREADS_PAGE_CAP=LUDICS_THREADS_PAGE_CAP
  REVIEW_POLL_CAP=SHIP_PR_REVIEW_POLL_CAP BUILD_POLL_CAP=SHIP_PR_BUILD_POLL_CAP
  BUDGET_DIR=LUDICS_PR_BUDGET_DIR)
# The commands the Python runs that a sourcing suite may have replaced with a shell FUNCTION (its
# fixture `gh`). The Python cannot call a function of this shell, so when one of these is a function
# here the forward hands its definitions over through the shell bridge (lib/ludics/proc.py): a file
# of this shell's functions and variables that each bridged call sources in a fresh bash, which is
# what the shell's own `$(gh ...)` subshell saw. In a plain run none is a function, and nothing is
# written. `sleep` is one of them because a suite's `sleep` OBSERVES the wait (the pauses it logs,
# what it lets happen meanwhile), which only a call can carry; a suite that defines one under
# SHIP_PR_TEST_CLOCK advances that clock in it. The clock itself is never bridged: the Python reads
# SHIP_PR_TEST_CLOCK (lib/ludics/README.md, "the shell bridge").
PY_BRIDGE_COMMANDS=(gh git sleep)

py_ported() { case "$PY_PORTED" in *" ${1:-} "*) return 0 ;; esac; return 1; }

# The usage refusal of a ported reader with no PR, made HERE: bash's own `${1:?}` message names this
# script, the line and the parameter ("<script>: line N: 1: usage: status <pr>"), which the Python
# cannot spell. Exit 1, as before the port; any other argument goes to the Python.
py_usage() { # <subcommand> <its args...>
  local sub="${1:-}"
  shift
  case "$sub" in
  poll) : "${1:?usage: poll <pr> [watermark]}" ;;
  status) : "${1:?usage: status <pr>}" ;;
  rounds) : "${1:?usage: rounds <pr>}" ;;
  esac
}

# This shell's state for the bridge: every function, every variable bash lets a script assign
# (its own read-only and dynamic ones are left out; a declaration the source refuses anyway is
# silenced there), and the two options a command substitution inherits, -u and pipefail. errexit is
# not one of them: bash clears it inside `$(...)`, where every gh call here ran.
py_bridge_state() {
  local __name
  declare -f
  for __name in $(compgen -v); do
    case "$__name" in
    BASH* | FUNCNAME | GROUPS | DIRSTACK | PIPESTATUS | RANDOM | SRANDOM | SECONDS | LINENO | \
      HISTCMD | EPOCHREALTIME | EPOCHSECONDS | PPID | UID | EUID | SHELLOPTS | PWD | OLDPWD | \
      COMP_WORDBREAKS | _ | __name) continue ;;
    esac
    declare -p "$__name" 2>/dev/null
  done
  case "$-" in *u*) echo 'set -u' ;; esac
  case ":${SHELLOPTS:-}:" in *:pipefail:*) echo 'set -o pipefail' ;; esac
}

# A path as the interpreter scripts/py runs will read it: on Git Bash that is a native Windows
# Python, which knows nothing of /usr/bin or /tmp.
py_native_path() {
  case "$(uname -s 2>/dev/null)" in
  MINGW* | MSYS* | CYGWIN*) command -v cygpath >/dev/null 2>&1 && { cygpath -m "$1"; return; } ;;
  esac
  printf '%s\n' "$1"
}

py_forward() { # <exec|call> <subcommand> <args...>
  local how="$1" py pair name state rc fn bridged=""
  local -a env_args=()
  shift
  # Physically, BEFORE going up: the skills call this file through a symlinked skill directory
  # (~/.claude/skills/ship-pr -> <checkout>/ship-pr), and a logical `cd .../../..` would climb out
  # of the link into ~/.claude/skills instead of into the checkout.
  py="$(CDPATH= cd -P "$(dirname "${BASH_SOURCE[0]}")" && cd -P ../.. && pwd -P)/scripts/py"
  [ -x "$py" ] || die "$1 is served by Python since ludics-lite#403, and its runner $py is missing" \
    "or not executable: this copy of pr-review.sh is not inside a ludics-lite checkout. Run the" \
    "checkout's ship-pr/scripts/pr-review.sh. Nothing was read or written."
  for pair in "${PY_FORWARD_VARS[@]}"; do
    name=${pair%%=*}
    env_args+=("${pair#*=}=${!name-}")
  done
  for fn in "${PY_BRIDGE_COMMANDS[@]}"; do
    if declare -F "$fn" >/dev/null; then bridged="$bridged $fn"; fi
  done
  if [ -z "$bridged" ]; then
    [ "$how" != exec ] || exec env "${env_args[@]}" "$py" -m ludics.prreview "$@"
    env "${env_args[@]}" "$py" -m ludics.prreview "$@"
    rc=$?
  else
    # Keyed by the owning pid like every temporary path here (see tmp_sweep_stale), and gone before
    # this returns.
    state=$(mktemp "${TMPDIR:-/tmp}/pr-review-bridge.$$.XXXXXX") ||
      die "could not create the shell bridge's file under ${TMPDIR:-/tmp}; nothing was run"
    py_bridge_state >"$state"
    env "${env_args[@]}" LUDICS_BRIDGE_FUNCS="${bridged# }" \
      LUDICS_BRIDGE_STATE="$(py_native_path "$state")" \
      LUDICS_BRIDGE_SHELL="$(py_native_path "$BASH")" "$py" -m ludics.prreview "$@"
    rc=$?
    rm -f "$state"
  fi
  [ "$rc" -eq 0 ] || exit "$rc"
  return 0
}

# --repo mirrors gh's own flag, so reaching for it out of gh habit works instead of hitting usage.
main() {
  GH_REFUSAL_PID=$$
  trap gh_refused_exit USR2
  case "${1:-}" in
  --repo) REPO="${2:?--repo owner/name}" && shift 2 ;;
  --repo=*) REPO="${1#--repo=}" && shift ;;
  esac
  # A subcommand ported to Python is exec'd there; see "the Python half" above.
  if py_ported "${1:-}"; then
    py_usage "$@"
    py_forward exec "$@"
  fi

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
  body) shift && cmd_body "$@" ;;
  retry) shift && cmd_retry "$@" ;;
  *) die "usage: pr-review.sh [--repo owner/name] {poll|watch|status|rounds|checks|merge|reply|resolve} <pr> ...
  pr-review.sh comment <pr> <body>           # a plain PR comment (a summary round, a review nudge)
  pr-review.sh body <pr> <file>              # replace the PR's description from a file, over REST
  pr-review.sh base [owner/name] [branch] [--wait]  # is the base branch's CI green? (start of
                                             # work; --wait = post-merge integration read;
                                             # --integration-records <file>: fleet-worker gate's;
                                             # --interim: a named green while the tip's run is in
                                             # flight — the gate's and the base watch's, never
                                             # the integration loop's)
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
