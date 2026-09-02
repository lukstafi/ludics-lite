---
name: ship-pr
description: Land finished work — decide whether it goes straight to master or through a PR, then carry the PR through automated review to merge. Use whenever a coding task is complete and its changes are not yet landed, when asked to monitor or babysit a PR, and for multi-PR arcs where each phase lands separately. Do not use to land work that looks like it went down a wrong path — raise that with the user instead.
---

# Ship a PR through review

Covers: open -> monitor -> address -> merge. The step after merging is the `after-merge`
brainstorm, which turns the experience into the next cycle's issues; hand off to it rather than
ending at the merge.

Scoping (one goal per PR, one design move per commit) is the project's own convention — check
CLAUDE.md/AGENTS.md before splitting work differently.

## Fire when the work is done, not when a PR is asked for

Reaching a finished goal with unlanded changes is itself the trigger; landing does not wait for
the user to ask for a PR. These are single-maintainer projects where churn is cheap and history is
not a museum, so the default at completion is to land and let review catch the rest — fail
forward.

Three things are not "done" in this sense: work that changed nothing (an investigation, a
question answered), a move that is one commit of a goal still in progress, and a goal the user has
already said how to land.

The exception that outranks fail-forward: when the work looks like it went **down a wrong path** —
the approach did not pan out, the fix papers over the design problem rather than solving it, tests
were bent to make it pass, or the goal drifted from what was asked — do not ship it and leave the
reviewer to find that out. Say what went wrong and what you would do differently, and let the user
redirect. Shipping is for work you would defend; a wrong path is a conversation.

## PR or direct commit?

Every PR here draws an automated review, so opening one and then skipping the monitor forfeits a
review rather than saving time — a PR is never the "light" option. The light option is landing on
master directly, and it is the right one when there is nothing to review: a typo, a comment,
re-promoting a golden. It waits for the user no more than a PR does — merging a PR into master is
the larger act of the two, however much the merge commit makes it the more visible one:

```bash
git fetch origin && git rebase origin/master   # a direct push has to fast-forward
git push origin HEAD:master
```

From a linked worktree push `HEAD:master` rather than checking master out — some checkout
holds that branch ("already used by worktree"). That is checked-out-branch protection, not `git
worktree lock`, and it does not reach the remote ref: `push HEAD:master` goes through. It does
leave the local `master` behind, and which command advances it depends on who has it checked out,
so look first (`git -C <main> worktree list --porcelain`, grep `branch refs/heads/master`). If NO
worktree has it out, the primary form is `git -C <main> fetch origin master:master`. If one does,
that fetch is refused, and the exact complement is `git -C <master-owner> merge --ff-only
origin/master` run in whichever worktree owns it — the main checkout only when the main checkout
is the owner. Either update it, or give every later branch an explicit start point (`git checkout
-b next origin/master`, `git worktree add -b next <path> origin/master`) — an omitted start point
takes the current HEAD, which from a stale checkout drops the commits just landed.

The trade is explicit: a direct commit gets no review at all. Anything carrying a design decision
goes through the full loop below.

The `gh` recipes below are packaged as `~/.claude/skills/ship-pr/scripts/pr-review.sh` (`poll`,
`watch`, `status`, `checks`, `merge`, `base`, `reply`, `resolve`, `comment`, `retry`), which
encodes the traps in code — including the pagination that a PR running to many rounds walks into —
so prefer it to hand-rolled API calls. The commands below spell that path out in full because they
are run from a repo checkout, not from the skill directory.

**GitHub fails half the time, not none of the time.** During an incident (2026-08-17: an hour of
roughly every other call returning `503 No server is currently available`) a single attempt is a
coin flip, so the script retries every call — 4 tries, 5s doubling to 20s, on 5xx and that body,
never on a 4xx. Two rules follow, and they are worth holding even when you step outside the script.
Read its **exit codes**: `0` did it, `1` the fact does not hold, `2` your invocation is wrong, `3`
the API never answered. And never restate a `3` as a finding — "no such thread", "no new activity",
"not approved" are claims about the PR, and an unanswered call supports none of them. That
conflation is not hypothetical: the pre-retry script reported `no review thread starts at comment
N` for three threads that existed, because its paginated GraphQL lookup had 503'd.

For the `gh` calls this skill makes outside the script — an ad-hoc `api` read, say — use
`pr-review.sh retry [--read] <gh args…>` rather than hand-rolling a
`for i in 1 2 3; do … && break; sleep; done` loop (which one outage session wrote five times).
Writes are retried only on gateway refusals, so a merge or a comment cannot be sent twice. Do not
route `gh pr comment` through `retry`, though: it is the one call that cannot take the
`owner/name#<pr>` argument this skill standardizes on (it wants a bare number plus `--repo`, or a
full URL), so it fails on the argument and invites hand-building a PR URL. Use `comment` below.

**Always name the repo in the PR argument: `owner/name#<pr>`, not a bare number.** The script can
infer the repo from the cwd, but a *background* shell does not reliably start in the checkout — and
`watch`, the one invocation this skill tells you to background, is exactly where that bites. The
failure is loud (exit 2, nothing watching) but easy to leave un-noticed once the command is
backgrounded and the turn has yielded. It also bites unevenly inside a batch: three `reply` calls
in one message, the first two landing and the third dying, is a partial success that reads as
success. A resolved repo is cached per PR number, so later bare-number calls usually still work —
but that is a safety net, not something to rely on for the first call of a session.

## Read the base before you branch

A branch inherits its base's breakage. When a `master` does not build, every later "is this my
change?" question gets expensive, and the answer is usually no — that is where the cost of a red
base actually lands, not in the ten hours it stays red. So read it before taking a branch off it:

```bash
~/.claude/skills/ship-pr/scripts/pr-review.sh base <owner>/<repo> [branch]   # default branch if omitted
```

Exit **0** green, **1** RED (it says so in three shouted lines and names the run), **3** the API did
not answer — which is not "green" — and **4** no build workflow has ever completed on that branch.

On a **1**, do not start by branching and hoping. Open the run it names and decide which you are in:
the break is someone else's and already known (say so before you start, so the session's first
confusing build failure is not re-diagnosed from scratch), the break is *yours* from a previous
landing (fix that first — it is one commit and it unblocks everyone), or nobody has looked yet (this
is the case that costs the most, and reporting it is worth more than the task you were about to
start). What you must not do is spend the session bisecting a break you inherited.

If this skill fires at the *end* of a task, as it usually does, this section is the one part of it
to have run at the beginning. A session that did not is still better off running `base` before it
branches for the follow-up work.

The verdict is about the last **completed** run, and `base` prints which commit that run tested. On
ocannl-staging `ci` carries `paths-ignore: docs/**`, so a docs-only push produces no run at all and
the newest verdict legitimately trails the tip by a commit or several — that is a gap in coverage,
not a stale reading, and the printed SHA is what lets you tell them apart.

## Open

Look at the working tree first: commit what belongs to this goal, and say explicitly what you did
with anything that doesn't.

Whether to branch is a judgment call — reuse the topic branch you are already on. When you do need
a new one, take it from a *freshly fetched* base:

```bash
git fetch origin && git checkout -b claude/<topic> origin/master
```

In a worktree setup `git checkout master` fails whenever another worktree owns that branch
("already used by worktree"), and a stale local base silently reopens problems the base already
fixed. The `-b … origin/<base>` form
sidesteps both.

If the branch already has a PR, push to it and reuse it — never open a second one for the same
branch.

Write the body as the reviewer's map, not a changelog: what is now true that was not, what the
tests pin, what changes for existing users, and where the risky corner is. Reviewers — human and
automated — spend their attention where the body sends it.

Report the URL on its own line, wrapped so the Desktop client renders a live status card (the tag
is inert everywhere else):

```
<pr-created>https://github.com/owner/repo/pull/123</pr-created>
```

When the tracker lives in a different repo from the PRs (a staging fork carrying PRs, upstream
carrying issues is a common pairing), comment on the tracking issue with what this PR does. On a
multi-PR arc that comment is what makes the phases legible later.

## Monitor

Poll for the review yourself: nothing arms on its own. The `<pr-created>` tag gets the Desktop
client to render a PR card, but the review-event feed behind that card starts only when the user
clicks its "Auto-fix CI & address comments" — verified on a PR opened with the tag and no other
setup, which drew a review nobody was told about. If those events do start mid-loop they carry the
comment bodies and ids inline; take them as they come and stop polling for what they delivered.

Never end a turn with a PR in flight and nothing watching it: arm the watch as a background command
before yielding, so the next round wakes you instead of waiting for the user to notice it. `watch`
*is* the polling loop — don't hand-roll a sleep loop around `poll`, which is what a long review
otherwise turns into. It returns the moment a round lands (printing exactly what `poll` would), the
approval arrives, or it can tell that no review is coming; exits 1 having stayed quiet; and ends on a
watermark either way:

```bash
~/.claude/skills/ship-pr/scripts/pr-review.sh watch <owner>/<repo>#<pr> [watermark]  # background it
~/.claude/skills/ship-pr/scripts/pr-review.sh poll <owner>/<repo>#<pr> [watermark]   # one shot
```

Run `watch` through the Bash tool's **background** mode and act on its completion notification: its
default window (15 min; `WATCH_INTERVAL`/`WATCH_TIMEOUT` retune it) outlasts the foreground timeout
ceiling. Spell the repo out, as above — this is the backgrounded call that cwd inference cannot
serve.

**Never pipe a gate command** — `watch`, `poll`, `checks`, `base`, `merge` — through `tail`, `head`
or anything else: the pipeline reports the LAST command's status, so the script's exit code (2 for
a usage error, 1 for red, 3 transport, 4 no verdict) is replaced by the pager's 0, and the harness
then reports a clean exit for a call that never ran. On 2026-09-01 a `checks 587 --repo …` — wrong
option, `checks` takes the repo through `REPO=` — died on stderr and the run was recorded as
exit 0, which reads exactly like a passing build gate. Let these commands write straight to the
output file, where the message is anyway.

Read its exit code, which is three-valued: **0** = act on what it printed; **1** = the window
passed quietly, so hand the watermark it printed to the next `watch` and keep working meanwhile;
**3** = it did not read the PR (API trouble), which is *not* quiet — nothing was observed, so
re-arm rather than concluding the reviewer is silent. A window whose *last* polls failed exits 3
too, even after healthy rounds earlier: the round you are waiting for could be sitting in the part
of the window that was never read.

**The watch's printout is not the record of the round.** A long round's output is cut by the Bash
tool's display (the head goes, the tail stays), and on 2026-08-22 two agents answered half a round
that way, both times dropping real findings. After any exit 0, enumerate the round's findings
yourself from the feeds, by id above the watermark you PASSED IN — `watch` prints the advanced one
back, and ids above that are the next round's (`status`, or the comment APIs) — and address
THAT list; cross-check the count against what the watch claimed before replying/resolving.

An exit 0 is not always a round: `watch` also returns when it can tell that **nothing is coming** —
the 👀 went spent without a review of the head, or never landed, or a push has been sitting
unreviewed past the grace (20 min, `SHIP_PR_REVIEW_GRACE`). Its line says so and names the remedy:
post a plain `@codex review` comment on the PR — `pr-review.sh comment <owner>/<repo>#<pr>
'@codex review'` — which starts a round within one window. Do that rather than re-arming a fourth
identical wait; see the state table below for why waiting cannot distinguish itself.

Hand-rolling that query has produced seven false readings, all of which the script handles: app
reviewers' logins carry a `[bot]` suffix so an exact-match filter never fires; your own replies
bump both counts — and are themselves recorded as `COMMENTED` reviews — so "new" must mean an id
above a watermark, not a delta; the three feeds number their items in SEPARATE id spaces, so one
shared watermark takes the max from the reviews feed and then hides every inline finding — the
dangerous one, because it looks exactly like the reviewer going quiet; the comment APIs paginate
at 30; `[ "$n" -gt 0 ]` on empty output aborts the watcher mid-run; a failed request renders
as the same empty list as a quiet feed, so an outage reads as "no findings, no approval" unless
the two are kept apart; and a 👀 reaction is a LEVEL that the app does not always take back, so
reading it as "a review is running" waits on a round that already finished.

## Address a round

Read *every* finding before changing anything. Rounds have shape: the early ones tend to hit
analysis and correctness, the later ones robustness and reproducibility, and treating a late
finding as if it were isolated is what makes review loops long.

Judge each finding on the merits. Most are right; some are not, and a wrong one deserves a
reasoned reply rather than a compliance edit — a design boundary you hold deliberately (what a
component is *not* responsible for) is worth defending in the thread, in the terms of the design. A
round you answer entirely with reasoning needs no push: reply, then merge.

**When findings arrive in a family, fix the genre, not the instance.** This is the single biggest
lever on how long the loop runs. If round N says "pin knob X" and round N+1 says "pin knob Y", a
third knob exists; close the whole class instead — sweep the ambient variables categorically,
delete a duplicated command so it cannot drift from its source, derive a value instead of
restating it. Then say in the reply that the class is closed and why, so the reviewer can check the
reasoning rather than re-find members.

Land each round as one commit whose message names the findings it answers and their severity, in
the reviewer's own terms:

```
Review fixes round 3: repro commands pinned, keep-fraction pin, exact provenance

- P1: <the finding, then what changed and why that is the right fix>
- P2: <…>
```

The history then reads as a dialogue, which is what a reviewer (or a future archaeologist) needs.

Push, then close out each thread — silent fixes leave the reviewer re-deriving what you did:

```bash
~/.claude/skills/ship-pr/scripts/pr-review.sh reply <owner>/<repo>#<pr> <comment-id> "Fixed in <sha>: <substance>"
~/.claude/skills/ship-pr/scripts/pr-review.sh resolve <owner>/<repo>#<pr> <comment-id>
```

Check every call in such a batch, not just the last: these are independent invocations, and one
failing while its neighbours succeed leaves a thread silently unanswered. A `reply` that exits 3
posted nothing (the gateway refused it) — repeat it; a `resolve` that exits 3 found the thread and
failed to close it, so repeating that is safe too. Only exit 1 from `resolve` means the thread is
really not there.

**A finding without a comment id has no thread to reply in — answer it with `comment`.** A review's
summary body (the `--- review id=… state=…` block a round prints, and the `--- summary id=…` one)
carries findings that were never attached to a line, so there is nothing to `reply` to and nothing
to `resolve`; the same is true of the `@codex review` nudge the watch verdicts recommend. Both are
plain PR comments:

```bash
~/.claude/skills/ship-pr/scripts/pr-review.sh comment <owner>/<repo>#<pr> "Round 3, on the summary: <substance>"
```

Do not reach for `gh pr comment` here, with or without `retry` — it rejects the `owner/repo#<pr>`
form, and the workaround it invites (hand-building the PR's URL) is how a release-prep session on
`lukstafi/ocannl-staging#475` spent its retries on argument parsing. `comment` takes the same
argument as every other subcommand and posts through the same write policy: exit 0 posted (it
prints the comment's URL), 1 the API rejected it, 2 your invocation is wrong — note the body is
**one** argument, so quote it — and 3 nothing was posted, or nothing is known, so re-read the PR
before repeating it.

If a finding changes what a measurement *means* (not just how it is run), redo the affected
measurement rather than editing the prose around it; and if a result rests on a premise the
review invalidated, say so in the artifact instead of quietly dropping it.

## Converge and merge

Two gates stand between a finished round and `master`: the reviewer's approval and the build
signal. This section is the first; the build gate is below, and neither substitutes for the other.

The review gate is the reviewer's approval — for the Codex integration, a 👍 reaction on the PR,
not a review state. The two channels are disjoint: a round WITH findings posts `COMMENTED` reviews
— one carrying each inline comment, plus one summary — and no reaction, while a clean round posts no
review at all and only the reaction. So a string of `COMMENTED` reviews is neither rejection nor
sign-off, and their absence after a push is the approval, not silence.

```bash
~/.claude/skills/ship-pr/scripts/pr-review.sh status <owner>/<repo>#<pr>
```

The 👀 reaction is the one signal you cannot read on its own. It is a level, not an event, and the
app does not reliably take it back: on #364 a 👀 outlived the review it announced by an hour, and
three consecutive 15-minute windows reported "reviewing — wait it out" over a PR nothing was
reading. So `status` crosses the reactions with what the reviewer has actually posted and with the
head SHA, and answers with one of six:

| state | means | what to do |
| --- | --- | --- |
| `approved` | 👍 is on the PR | merge |
| `reviewing` | the 👀 is newer than the reviewer's last word — a round really is in flight | wait it out |
| `stalled` | that 👀 has been up longer than a round takes and nothing was posted | `@codex review` |
| `expected` | no live 👀, and no review of the head SHA: a round is due and has not started | wait out the grace, then `@codex review` |
| `idle` | the reviewer has reviewed this exact head and left no 👍 | the next move is yours: address the round and push |
| `unknown` (exit 3) | a read failed | retry — this is *not* "not approved yet" |

Two comparisons carry that, and both are easy to get wrong by hand. Whether the reviewer has *seen*
the head is a SHA equality (each review records the `commit_id` it was submitted against), never a
time comparison — a commit's date can long predate the push that delivered it. Whether a 👀 is live
is judged against the reviewer's own last word, never against the head commit: a 👀 raised just
before your next push is a round that is genuinely running, and #358 had exactly that shape (👀 at
20:34:13Z, head committed 20:35:01Z) twenty minutes after #364 had the stale one.

The whole polling and merge-gate path is REST: GitHub's GraphQL endpoint 503s independently of REST,
and a GraphQL-borne silence is indistinguishable from a reviewer's. Thread resolution is the one
GraphQL-only operation left, and it reports a transport failure as a retry rather than as a missing
thread.

### The approval is one gate; the build is the other

Approval says a human-or-bot read the diff. It says nothing about whether the tree compiles, and
those two gates fail independently. On ocannl-staging they failed independently for ten hours: seven
consecutive merges landed on a `master` that did not build on the only compiler CI builds, and every
one of those PRs was carrying its own red `ci` run at the moment it merged — the same error, both
platforms, named file and line. Six of them were reviewed and approved on top of it
(ahrefs/ocannl#694). Nothing was undetected; nothing read the result.

So merge through the script, which reads the head commit's checks and then merges:

```bash
~/.claude/skills/ship-pr/scripts/pr-review.sh merge <owner>/<repo>#<pr>
```

It merges with `--merge`, preserving the commit series (the repo convention for topical commits);
other `gh pr merge` flags go after a `--` — `--auto` included, and the gate still runs ahead of it.
That matters on a base with no required checks, where `--auto` is not a queue at all: it merges on
the spot, which is exactly how six red builds got past a merge step that read nothing.

**It refuses when a build check on the head commit concluded `failure`**, printing which ones with
their run URLs, and exits 1 without calling the merge API at all. That refusal is the whole point:
open the run, fix the build, push, merge.

It refuses on an unreadable signal too (exit 3). An unread check list is not a green one — that
distinction is why these reads are REST while `gh pr checks` is GraphQL, which 503s independently
and answers an outage with an empty list indistinguishable from a PR whose CI never ran.

The other verdicts are not refusals, and none of them is a green light either:

| exit | verdict | what it is |
| --- | --- | --- |
| 0 | green | every build check on the head passed |
| 0 | absent | no build check ran on this commit — path filters (ocannl's `ci` ignores `docs/**`), or CI never started |
| 1 | RED | a build check concluded `failure` — refused |
| 3 | unknown | the checks could not be read — refused |
| 4 | no verdict | still running, or every finished job was `cancelled` — refused without `--allow-no-verdict` |

**Exit 4 refuses too, by default.** Nothing has failed, but nothing has passed, and a merge that
waits for neither read nothing — it was a warning until 2026-08-23, when a day-long runner queue
outran the 30-minute wait and a PR merged unread with a stale test claim (ahrefs/ocannl#745),
leaving `master` red for two hours. So:

```bash
~/.claude/skills/ship-pr/scripts/pr-review.sh merge <owner>/<repo>#<pr> --wait
```

`--wait` holds for the verdict up to 120 min (`SHIP_PR_CHECKS_WAIT` seconds, or `--wait=<seconds>`)
with a one-line heartbeat every 10 min (`SHIP_PR_CHECKS_HEARTBEAT`), so background it and let it
hold. If the ceiling runs out it exits 4 naming `--allow-no-verdict`; for anything a compiler sees,
wait again instead.

Two traps around that hold, both observed 2026-08-28. **`ABSENT` seconds after a force-push is not
a verdict** — a rebase before merging pushes a new head whose checks may not EXIST yet,
and a wait that starts in that window sees nothing to wait for and can pass the gate having read
nothing (ocannl staging#491 merged that way). After any force-push, confirm a run exists on the
new head (`gh pr checks` / the run list) before trusting a quick `ABSENT`-shaped answer, and if
none exists yet, wait for it to appear. And **the harness can kill a backgrounded `merge --wait`
well before its ceiling** (observed twice at ~40 min): the correct response is to re-read merge
state over REST (`gh pr view --json state,mergedAt,headRefOid`) and re-arm the wait — never to
conclude the merge failed, and never to reach for `--allow-no-verdict` because the waiter died.

`--allow-no-verdict` merges unread, loudly on stdout and stderr. It is acceptable only when the
verdict could tell you nothing you have not established yourself: a doc-only diff, or a shell-only
one whose script you ran locally on the **exact rebased tree** you are merging — a rebase is a new
tree, and "I tested it earlier" is the stale test claim of #745. It is not for "CI is slow today";
that is the day it exists to refuse.

`cancelled` is deliberately neither red nor green — a cancel is a job that was stopped, not one
that found something, and ocannl's `ci` sets `fail-fast: false` precisely so a red matrix leg does
not cancel its siblings and destroy the information. A cancel here comes from a superseding push or
a manual stop, and re-running is what turns it into an answer; it is exit 4 like a running job, and
`--allow-no-verdict` is no more acceptable for it.

Run `checks` on its own — same verdicts, same exit codes, no merge — whenever you want the build
signal without acting on it, such as before asking the reviewer for another round.

**Awaiting CI is `checks --wait`'s job, never `gh run watch`'s.** Raw `gh run watch` streamed
~168k tokens of progress redraws into one session, and its nonzero exit on a run that concluded
FAILURE carries no HTTP status, so a retry loop reads a workflow verdict as transport — the
2026-08-29 wave re-watched a completed FAILED run four times and then reported "the API never
answered". Use `checks <pr> --wait` for a PR's build signal (it reads every check on the head,
with a heartbeat instead of redraws). For a single run addressed by id, `retry run watch
<run-id>` is safe: the script does not forward it to gh but executes a quiet await — one verdict
line; run FAILED is exit 1, transport exit 3, no verdict exit 4.

### How stale the base has grown

Both gates above read the *head commit*, and both are satisfied by a branch whose base has moved on
without it. `merge` therefore also prints how many commits behind its base the branch is, and says
so loudly — `!!! … COMMITS BEHIND`, on stdout and stderr — past 20 (`SHIP_PR_STALE_BASE`, or `off`).

It warns and merges anyway. That is the **roll-forward policy** (ahrefs/ocannl#861, decided
2026-08-30 after a wave where every sibling merge invalidated every open PR's verification —
staging#533 ran three clean rebases and three full CI cycles over an unchanged topic diff): a PR
merges on one green full-matrix run for its *last commit*; a clean merge does not restart
verification; only a merge that needed a conflict-RESOLVING commit waits for green CI on that
commit, which the checks gate reads naturally as the new head. What owns semantic drift instead is
the wave coordinator's post-merge **integration loop** (issue-wave skill): the full `@runtest
@train` suites on merged master, on whichever fleet machine has the least work, with
stop-the-world triage on a regression.

**When a wave coordinator is actively running that integration loop**, the division is strict
on the landing side too: after `merge` confirms `merged`, the worker's verification is over.
Do not run the `base --wait` tail below and do not watch master's subsequent workflows — under
concurrent sibling merges "the current tip" is a moving target and the wait never terminates
(on 2026-08-30 seven wave workers each chased it for 100–120 minutes; every one ended unjudged
or had to be killed). If a wave worker checks anything post-merge, it is the single run for its
OWN merge commit, read once — a run superseded or cancelled by a later sibling merge is the
integration loop's business. In standalone use — no coordinator, no loop — trailing CI is
likewise not the merger's to watch: it belongs to the CI-red triage routine (below).

**Still read the line before letting the merge stand.** On staging#488 (2026-08-28) sixteen review
rounds ran against a base that had gone 136 commits stale, `master` had meanwhile edited the very
file the PR changed, and every signal on the merge path was clean: green checks (on the stale
head), an approval (of the stale diff), `mergeable=true` (semantic drift produces no textual
conflict). What caught it was a hand-run `git diff origin/master..HEAD --stat` whose 258 files were
visibly not the two-file branch. That two-dot endpoint diff is an eyeball tool, not a test: it
includes the PR's own edits, so every nonempty PR looks drifted by it. The question — did the
base's advance touch this PR's files — is answered by anchoring at the branch point:

```bash
git diff --name-only --no-renames $(git merge-base origin/master HEAD) origin/master | grep -Fxf <(git diff --name-only --no-renames origin/master...HEAD)
```

It prints exactly the PR's files that the base's advance also touched — nothing means none
(substitute the remote that actually points at the base repo; its name is local). `--no-renames`
lists both names of a file the PR renamed, so an edit the base made to the old name still shows;
`grep -Fx` compares whole lines, so a path with spaces is one path rather than word-split
pathspec fragments.

When the base's advance touches the files this PR changes, rebase (or merge the base in, where the
branch is shared), push, and let the checks re-run first — any commit that moves the head waits
for its own green run, conflicts or not; otherwise a clean merge on a green head is the policy,
not a corner cut. A count the compare API could not answer prints `UNKNOWN`, which is not "not
behind": check it by hand.

**Standalone use does not watch CI at all** (since 2026-08-31): trailing failures on merged
master belong to the **"ocannl-staging CI-red triage" cloud routine** — fired by `ci.yml`'s own
`notify-triage-routine` job through the routine fire API on any non-PR master red, with a daily
backstop sweep behind it. On a master red it checks for an existing claim, claims the failure
with an issue on **ahrefs/ocannl** (`CI red on master@<short-sha>: <workflow>` — issues are
disabled on the staging repo), and either opens a `ci-fix/*` PR on staging (it never merges its
own PRs) or posts its diagnosis to the claiming issue. So after `merge` confirms `merged`, this
session's verification is over: do not run `base --wait`, do not watch master's subsequent
workflows. (Briefly that day the rule was the opposite — every merger blocked on its own
`base --wait` — which stacked N sessions on the same remote CI cycle; the routine is the
single owner that replaced it.)

Two local touchpoints remain. A red you happen to see — in the pre-branch `base` read, or
anywhere else — is presumptively CLAIMED work: find the routine's claiming issue and any
linked PR before touching anything, and take over only when the issue shows triage stopped
short and nobody else picked it up (say so there first). And a `ci-fix/*` PR the routine
opened is finished work like any other: land it through this skill.

### The override

The gate has two escape hatches, for two different facts. `--allow-no-verdict` (above) is for a
verdict that has not arrived; `--override` is for one that has arrived and is red. They do not
substitute for each other: a red is never "no verdict", and a queue is never "an unrelated red".

```bash
~/.claude/skills/ship-pr/scripts/pr-review.sh merge <owner>/<repo>#<pr> \
  --override "the red is the pages Deps step, failing on master since before this branch existed"
```

`--override` takes a reason in **words** — a bare token like `yes` is rejected — because what makes
an override legitimate is being able to say why *this* red is unrelated to *this* PR, and that
sentence is what the next reader finds in the log. It prints on both stdout and stderr, loudly, and
then merges.

It is legitimate when you have **established** that the failure is neither about your change nor
about the tree you are merging into: the identical red is on `master` from before your branch
existed; the failing step is infrastructure no source change can reach (an opam solve, a runner
image, a registry timeout, a rate limit); or you can point at another PR whose build fails the same
way. In each of those you have opened the run and read it.

It is not legitimate for "the error looks unrelated", for a red you have not opened, or for a flake
you are assuming rather than confirming — re-run the job instead. A re-run costs minutes; an
override costs whoever branches next their afternoon. And an override is never the way to handle a
red you caused: an unrelated red is a fact about the world, and a related one is your commit.

Which checks the gate reads is a deny-list, not an allow-list: every check on the commit counts
unless it is named advisory (`SHIP_PR_ADVISORY_CHECKS`), so a renamed job or a new matrix leg keeps
gating instead of silently falling out of it. Advisory by default: the review app's own
permanently-skipped check, and a publishing workflow that compiles none of the tree (ocannl's
`github pages docs` runs slipshow, pandoc and latexmk over `docs/**`, so its red is about a font
package, never about the code).

Exclude by name only what **cannot carry a build verdict** — not merely what is red today. ocannl's
`github pages api` was excluded on the latter reasoning, being red on every master push, and the
exclusion promptly hid a real `dune build @doc` compile break behind the apt failure that was
masking it (ahrefs/ocannl#698). A workflow that is always red wants fixing, not deny-listing; once
it is fixed, take it back off the list.

### What `merge` absorbs, and what a nonzero exit therefore means

`gh pr merge` exits 0 having only *enabled* auto-merge when the base carries required checks or a
merge queue, so the exit code is not the answer; `merge` confirms `merged` over REST and reports
`merged=false` as a failure to land. REST, not `gh pr view --json` — those ride GraphQL, and a
nonzero merge whose state query then 503s is exactly the shape of a merge that DID land.

A merge failing with "Pull request is not mergeable: the merge commit cannot be cleanly created" is
ambiguous, and the two readings demand opposite moves. GitHub recomputes a PR's mergeability
asynchronously after every push; until that finishes the API serves the cached verdict, so for some
seconds after a push — including the very push that just resolved a real conflict — the merge fails
with a message byte-identical to a genuine conflict. Seen back to back on ocannl-staging#373
(2026-08-18): first real base drift, then the stale cache over the freshly pushed
conflict-resolution merge. `merge` re-reads `.mergeable` over REST until it is non-null and retries
on `true`, so a nonzero exit from it already means the recompute settled: `mergeable=false` is base
drift needing a merge or rebase of the base branch, and only a repeated failure after that is a
conflict you must resolve.

### After it lands

Then clean up, but not with `gh pr merge --delete-branch`: from a worktree its cleanup fails *after*
the merge has landed ("fatal: 'master' is already used by worktree"), leaving the branch behind and
the failure looking like a failed merge. Run the executable sequence instead:

```bash
~/.claude/skills/ship-pr/scripts/post-merge-cleanup.sh <main-checkout> <session-worktree> <branch>
```

It fetches and proves the ordinary topic is an ancestor of `origin/master` before deleting
anything, deletes the remote branch, advances local `master` according to which worktree owns it,
detaches and unregisters the session worktree into a sibling recovery archive, rechecks ancestry
against updated local `master`, and
deletes the local branch independently of its configured upstream. Its scratch-repository test
covers unchecked-out `master`, `master` owned by the primary checkout, `master` owned by another
worktree, safe deletion while the primary checkout is off `master`, and refusal of an unmerged
topic:

```bash
~/.claude/skills/ship-pr/scripts/test-post-merge-cleanup.sh
```

Naming one or more cases exactly — as `--list` spells them — runs only those, which is how to
iterate on a single failure; an unrecognized name is refused before any case runs.

```bash
~/.claude/skills/ship-pr/scripts/test-post-merge-cleanup.sh test_safe_topic_deletion
```

The cases are independent, so they run concurrently, one per processor by default (`-j N` or
`SHIP_PR_TEST_JOBS` changes that; `-j 1` is serial): the full suite finishes in about a minute and
a half on a 4-core CI runner, where the serial run took eight, and in well under a minute on a
desktop. Each case's output is buffered and printed whole when it completes, so a failure report
never interleaves with another case; passing cases print only their `PASS:` line unless `-v` asks
for everything. Failures do not stop the other cases — the closing `FAIL:` line names every case
that failed.

A squash or rebase merge does not preserve ancestry. After independently confirming that merge,
make the exception explicit and leave its reason in the transcript:

```bash
~/.claude/skills/ship-pr/scripts/post-merge-cleanup.sh <main-checkout> <session-worktree> <branch> \
  --force-integrated "GitHub reports the PR squash-merged at <sha>"
```

The helper requires Git's transactional `update-ref` symbolic-ref commands, Perl for an atomic
filesystem rename, the exact session-worktree root, a clean and unlocked session with no ignored
local data, and one shared
fetch/push endpoint for `origin`. It treats an already absent topic as a safe retry state and
refuses an unreadable ref, a symbolic local/tracking ref, or a remote tip newer than the local
branch; an absent remote topic sends no deletion, while present remote and local deletions carry
exact-OID leases. It also fetches `master`
explicitly, independent of the remote's configured fetch map, and proves the local ref can
fast-forward before any remote deletion. A clean worktree keeps `master` continuously reserved
while the named ref is conditionally updated and its tree refreshed; when no worktree owns it, the
helper creates a temporary owner for that same critical section. Remote topic deletion is leased
on the observed topic OID and followed by fresh `master` and local-topic reads; if either changed
or `master` became unreadable, the current topic recovery ref is restored before refusal. The
validated tip also remains reachable under a direct `refs/ship-pr/recovery/` ref because no finite
remote read can rule out a later base rollback; a divergent remote-tracking tip is retained
separately under `refs/ship-pr/tracking-recovery/` before pruning. The master-owner refresh uses a non-destructive porcelain
fast-forward through a helper-only reservation and a conditional named-ref update. A checked-out
master owner must contain no local data, including ignored files; after the update it is prepared
at the new tree and reattached with a detached-HEAD compare-and-swap before the reservation is
removed. The helper probes that compare-and-swap capability before any branch mutation and refuses
older Git versions cleanly. The helper also checks ignored descendants when a directory is
replaced, refuses a topic owned by any other worktree, and transfers
topic ownership to a temporary reservation through local ref deletion, and removes matching
remote-tracking and only the standard keys from repository-local upstream configuration. Included, global,
per-worktree, and custom branch configuration is inherited policy and is deliberately not edited.
Rather than recursively deleting a directory that can receive a last-moment ignored write, it
refuses initialized submodules and session-local worktree refs before mutation, preallocates sibling archives before ref mutation,
reserves the session-recovery ref namespace, atomically renames the session into one without
directory-nesting semantics,
retains the archived session's final HEAD under `refs/ship-pr/session-recovery/`, and unregisters
the now-missing worktree while holding the linked-worktree HEAD and pseudoref locks. Objects named
by session pseudorefs or its HEAD reflog, plus the final index tree, are retained beneath the
reserved `refs/ship-pr/session-recovery/` namespace; resolve-undo blobs receive direct recovery
refs, and per-worktree configuration is copied into the archive. Remote-tracking reflog objects are
retained under the topic recovery namespace before pruning, as are local-topic reflog objects before
branch deletion; both sides of every retained reflog entry are covered. Late files or links at the vacated path are moved to the second archive
before unregistering is retried. Do not reconstruct its state
machine in prose or
replace the ancestry guard with `git branch -d`: `-d` may test a configured upstream unrelated to
`master`, making deletion either tautological or a false refusal after the worktree is already gone.

If the harness blocks the merge itself, that is a permission gate, not a failure: explain what you
were doing, give the command, and let the user decide. Never work around it.

After merging: run the `after-merge` brainstorm FIRST, while the session's friction is still in
context. Then refresh the base for the next branch (`git fetch origin`, then branch off
`origin/master` again) and tear down any scratch worktrees the work created on remote machines.
Nothing further is owed: trailing CI on the new tip is the CI-red triage routine's business
(the stale-base section owns the division of responsibilities and the takeover protocol) — and
a plain `base` read seconds after a merge would only report the previous tip's green anyway,
so do not treat one as a post-merge verdict.

## Multi-PR arcs

When several PRs implement one tracked issue, comment on the issue as each phase lands — what the
phase delivered, in the issue's own vocabulary. At the end, close the issue with a waypoint
summary mapping each waypoint to the PR that landed it, and state the honest outcome including
where the work did *not* pay off; file the follow-ups that the arc's own evidence justifies
(that is `after-merge`'s job). An arc that closes with only its wins recorded costs the next
person the same discovery twice.
