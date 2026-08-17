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

From a linked worktree push `HEAD:master` rather than checking master out — the main checkout
holds that branch ("already used by worktree"). That is checked-out-branch protection, not `git
worktree lock`, and it does not reach the remote ref: `push HEAD:master` goes through. It does
leave the local `master` behind, and only the main checkout can advance it (`git -C <main> merge
--ff-only origin/master`; `fetch origin master:master` and `branch -f master` are refused from the
worktree). Either do that, or give every later branch an explicit start point (`git checkout -b
next origin/master`, `git worktree add -b next <path> origin/master`) — an omitted start point
takes the current HEAD, which from a stale main checkout drops the commits just landed.

The trade is explicit: a direct commit gets no review at all. Anything carrying a design decision
goes through the full loop below.

The `gh` recipes below are packaged as `~/.claude/skills/ship-pr/scripts/pr-review.sh` (`poll`,
`watch`, `status`, `reply`, `resolve`), which encodes the traps in code — including the pagination
that a PR running to many rounds walks into — so prefer it to hand-rolled API calls.
The commands below spell that path out in full because they are run from a repo checkout, not from
the skill directory.

**Always name the repo in the PR argument: `owner/name#<pr>`, not a bare number.** The script can
infer the repo from the cwd, but a *background* shell does not reliably start in the checkout — and
`watch`, the one invocation this skill tells you to background, is exactly where that bites. The
failure is loud (exit 2, nothing watching) but easy to leave un-noticed once the command is
backgrounded and the turn has yielded. It also bites unevenly inside a batch: three `reply` calls
in one message, the first two landing and the third dying, is a partial success that reads as
success. A resolved repo is cached per PR number, so later bare-number calls usually still work —
but that is a safety net, not something to rely on for the first call of a session.

## Open

Look at the working tree first: commit what belongs to this goal, and say explicitly what you did
with anything that doesn't.

Whether to branch is a judgment call — reuse the topic branch you are already on. When you do need
a new one, take it from a *freshly fetched* base:

```bash
git fetch origin && git checkout -b claude/<topic> origin/master
```

In a worktree setup `git checkout master` fails outright ("already used by worktree"), and a stale
local base silently reopens problems the base already fixed. The `-b … origin/<base>` form
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
otherwise turns into. It returns the moment a round lands (printing exactly what `poll` would) or
the reaction reaches approval, exits 1 having stayed quiet, and ends on a watermark either way:

```bash
~/.claude/skills/ship-pr/scripts/pr-review.sh watch <owner>/<repo>#<pr> [watermark]  # background it
~/.claude/skills/ship-pr/scripts/pr-review.sh poll <owner>/<repo>#<pr> [watermark]   # one shot
```

Run `watch` through the Bash tool's **background** mode and act on its completion notification: its
default window (15 min; `WATCH_INTERVAL`/`WATCH_TIMEOUT` retune it) outlasts the foreground timeout
ceiling. Spell the repo out, as above — this is the backgrounded call that cwd inference cannot
serve.

Read its exit code, which is three-valued: **0** = act on what it printed; **1** = the window
passed quietly, so hand the watermark it printed to the next `watch` and keep working meanwhile;
**3** = it never managed to read the PR (API trouble), which is *not* quiet — nothing was observed,
so re-arm rather than concluding the reviewer is silent.

Hand-rolling that query has produced six false readings, all of which the script handles: app
reviewers' logins carry a `[bot]` suffix so an exact-match filter never fires; your own replies
bump both counts — and are themselves recorded as `COMMENTED` reviews — so "new" must mean an id
above a watermark, not a delta; the three feeds number their items in SEPARATE id spaces, so one
shared watermark takes the max from the reviews feed and then hides every inline finding — the
dangerous one, because it looks exactly like the reviewer going quiet; the comment APIs paginate
at 30; `[ "$n" -gt 0 ]` on empty output aborts the watcher mid-run; and a failed request renders
as the same empty list as a quiet feed, so an outage reads as "no findings, no approval" unless
the two are kept apart.

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
failing while its neighbours succeed leaves a thread silently unanswered.

If a finding changes what a measurement *means* (not just how it is run), redo the affected
measurement rather than editing the prose around it; and if a result rests on a premise the
review invalidated, say so in the artifact instead of quietly dropping it.

## Converge and merge

The merge gate is the reviewer's approval — for the Codex integration, a 👍 reaction on the PR,
not a review state. An 👀 reaction means a review is running; wait it out. The two channels are
disjoint: a round WITH findings posts `COMMENTED` reviews — one
carrying each inline comment, plus one summary — and no reaction, while a clean round posts no
review at all and only the reaction. So a string of `COMMENTED` reviews is neither rejection nor
sign-off, and their absence after a push is the approval, not silence.

```bash
~/.claude/skills/ship-pr/scripts/pr-review.sh status <owner>/<repo>#<pr>
```

It answers with a fourth state besides approved/reviewing/none: **UNKNOWN** (exit 2) means the
reactions API did not answer, and it is not a synonym for "not approved yet" — retry it. The whole
polling and merge-gate path is REST for this reason: GitHub's GraphQL endpoint 503s independently
of REST, and a GraphQL-borne silence is indistinguishable from a reviewer's. Thread resolution is
the one GraphQL-only operation left, and it reports a transport failure as a retry rather than as a
missing thread.

Merge preserving the commit series (the repo convention for topical commits), and confirm the state
rather than the exit code — `gh pr merge` returns having only enabled auto-merge when the base has
required checks or a merge queue:

```bash
gh pr merge <n> --repo <owner>/<repo> --merge
gh api repos/<owner>/<repo>/pulls/<n> --jq '"merged=\(.merged) state=\(.state)"'   # before cleanup
```

Confirm over REST, not `gh pr view --json` / `gh pr checks`: those ride GraphQL, which degrades
independently of REST, and a nonzero `gh pr merge` whose state query then 503s is exactly the shape
of a merge that DID land.

Then clean up, but not with `gh pr merge --delete-branch`: from a worktree its cleanup fails *after*
the merge has landed ("fatal: 'master' is already used by worktree"), leaving the branch behind and
the failure looking like a failed merge. Two rules carry the rest — anchor every command with `git
-C <main>`, since `worktree remove` deletes the current directory when run from inside it and
everything after it dies with "Unable to read current working directory"; and fast-forward `master`
before `git branch -d`, which tests the branch's upstream first and falls back to the stale local
`master` once the remote branch is gone. `docs/agent-notes.md` (Conventions) carries the full
ordered sequence, verified end to end — follow it there rather than reconstructing it.

If the harness blocks the merge itself, that is a permission gate, not a failure: explain what you
were doing, give the command, and let the user decide. Never work around it.

After merging: refresh the base for the next branch (`git fetch origin`, then branch off
`origin/master` again), tear down any scratch worktrees the work created on remote machines, and
run the `after-merge` brainstorm while the session's friction is still in context.

## Multi-PR arcs

When several PRs implement one tracked issue, comment on the issue as each phase lands — what the
phase delivered, in the issue's own vocabulary. At the end, close the issue with a waypoint
summary mapping each waypoint to the PR that landed it, and state the honest outcome including
where the work did *not* pay off; file the follow-ups that the arc's own evidence justifies
(that is `after-merge`'s job). An arc that closes with only its wins recorded costs the next
person the same discovery twice.
