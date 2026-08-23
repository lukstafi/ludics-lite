---
name: issue-wave
description: Run a delegation wave over the issue backlog - read the daily sequencing plan, propose a machine-appropriate scope of D1/D2 issues, launch one encouraged Opus subagent per issue in its own worktree, each shipping via ship-pr, and supervise the wave to full merge. Use when asked to burn down issues, run a wave, or work the backlog; on ROG/Minix, scope flips to issues that specifically benefit from that box.
---

# Issue wave

Runs: plan -> scope -> decision gate -> launch -> supervise -> close out. Each agent's own
lifecycle is implement -> ship-pr -> issue close; the wave coordinator never implements, only
sequences, briefs, unsticks, and reports.

## Inputs

- **The plan**: `~/self-improve/ClaudeDesktop/sequencing_plan.md`, maintained daily by the
  Daily Issue Planning task. Read it live at every invocation - never rely on a remembered
  copy; it turns over fast. It supplies difficulty classes (D1/D2/D3), a dependency graph,
  a parallelism analysis, machine placement, and a ready-now first wave. If it has a design
  questions section (see Decision gate), that too.
- **The machine**: detect which box this is (hostname / platform). Default scope on the Mac:
  most or all D1 plus most D2 issues that do not benefit from ROG or Minix. On ROG or Minix:
  the issues the plan's Machine-placement section assigns to that box. The plan's placement
  section makes this a lookup - do not re-derive hardware needs from issue bodies.
- **Project conventions**: the repo's CLAUDE.md and agent-notes govern how agents work
  (worktree location, test discipline, commit style). The plan governs what and in which order.

## Scope and sequencing

Propose a wave to the user in one exchange: the issues, the parallel groups, and what is
deferred to a later wave and why. Take the plan's Parallelism and Dependencies sections as the
starting truth, then adjust for churn surfaces the plan does not model: two issues editing the
same file or golden serialize even if logically independent, and an issue that adds test
stanzas sequences after one that reshapes the affected goldens or scanners.

**Dependency gating, including out-of-scope dependencies.** For each candidate, walk the
plan's dependency arrows. A prerequisite that is itself in the wave makes the dependent a
later-wave member (launch on the prerequisite's merge). A prerequisite that is NOT in scope -
another machine's item, another session's work, an external blocker - does not silently drop
the dependent: gate it. Record the gate in the wave summary, poll the blocking issue's state
during supervision (`gh issue view N --json state`), and launch the gated task when it closes.
For a gate expected to clear mid-session, the `wait-and-proceed` skill is the per-task shape;
for one that may outlast the session, note it in the wave's close-out so the next invocation
picks it up. Never launch a dependent early on the theory that rebasing will sort it out.

## Decision gate (before launch, batched, fatigue-aware)

Scan the scoped issues for open design decisions: plan entries or issue bodies that say
"decide X vs Y", plus the plan's design-questions section when present. Then triage into
three tiers - the point is to ask the user as little as possible while never burying a
decision they own:

1. **Agent-decidable** (technical calls with a clear best answer discoverable in the code):
   do not ask. Note in the agent's brief that the call is theirs and must be documented in
   the PR and the issue-closing comment.
2. **Recommendation-with-veto** (a judgment call where you have a confident recommendation):
   do not ask either. Post the recommendation as a comment on the issue before launch - that
   comment survives interruptions and briefs the agent - and list these in the wave summary
   so the user can veto in passing. Silence is consent for this tier.
3. **Genuinely user-owned** (scope, taste with lasting API/workflow impact, anything
   irreversible or milestone-shaping): ask, in ONE batched AskUserQuestion for the whole
   wave, recommendation-first ("(Recommended)" option leading each question). Accept "do
   what you recommend" as a global answer. Whatever is decided gets posted to the issue
   before the affected agent launches.

Most waves should have an empty tier 3. If every question keeps landing in tier 3, the
triage is wrong, not the backlog.

## Launch

One Opus subagent per issue, worktrees outside the repo per project convention, parallel
groups launched together in a single message. The brief must be self-contained (agents do
not see this conversation) and include:

- Setup: worktree creation off current origin/master, environment script, which docs to read.
- The task: issue number and repo, a summary, and the instruction to read the issue and its
  comments first - including any decision comment the gate just posted.
- Verification expectations: scoped test runs, negative controls where the work is a checker,
  the project's known environmental traps (on this Mac: Gatekeeper/XProtect stalls fresh
  executables for minutes - sample the pid before assuming a hang; never start a second dune
  against a running _build). **On the Mac, the brief must say: targeted test aliases only
  (`dune build @<dir>/runtest-<name>` for the tests the change reaches, plus the scanners),
  never a full directory suite, and leave full suites to CI** - the XProtect scanner is one
  single-threaded service for the machine and each worktree links its own copies of every
  test exe, so N parallel full suites queue N x ~200 fresh binaries behind it and every
  agent's run freezes (observed 2026-08-22: 34 exes parked in dlopen, logs frozen, load 2.5).
  Also ask for `dune -j 4` when more than ~4 agents share the box.
- Landing: the ship-pr skill through review to merge, then close the upstream issue with a
  summary comment, then remove the worktree.
- Process discipline, stated explicitly because agents re-derive it badly under load:
  never end a turn with only a detached process outstanding - attach waits as
  harness-tracked background children; if a review watch goes quiet suspiciously long, read
  the PR feed directly (`gh pr view --comments`) rather than re-arming the watch (reactions
  persist across rounds and strand it).
- Encouragement. It is cheap and the user asked for it: name why the issue matters and
  express confidence. Agents visibly do their best work when the brief treats them as
  trusted colleagues.

## Supervise

The coordinator's job between launch and last merge:

- **Stay alive.** The Desktop app pauses a warm session ~15 minutes after its last
  main-conversation activity, and a background waiter held inside a subagent does NOT hold
  the pause - the pause killed a wave agent overnight once. During any stretch where agents
  are working and the user may be away, keep a coordinator-side heartbeat: a dynamic /loop
  or ScheduleWakeup firing under the 15-minute threshold, doing a cheap external check each
  tick. Durable worktree commits plus cheap agent re-launch remain the backstop when the
  session dies anyway: after an interruption, inventory worktrees and PRs externally, then
  launch a fresh finisher agent per stranded branch - it re-verifies from scratch and signs
  for the inherited commits.
- **Verify externally, not by agent self-report.** `gh pr list/view`, issue states, worktree
  list. Include the machine: `uptime` low while many `dune` processes sit at 0% CPU means
  the test exes are parked in XProtect's dlopen queue, not working -
  `ps -o pid,etime,pcpu,comm -p $(pgrep -P <dune pid>)` then `sample <exe pid> 1`. An agent saying "waiting on the watch" while the PR feed already has the next review
  round is the known strand - point it at the feed. An agent that yields twice in a row with
  no state change gets a concrete, imperative unstick message (do X now, in this turn, do
  not yield); if that fails too, take over the mechanical remainder or spawn a finisher.
  After a harness restart (power loss, dropped remote-control connection), a resumed agent's
  belief about its own background children is UNRELIABLE in both directions: it claims a
  watch or suite "armed and alive" that no longer exists, and once reported a child as
  launched that never started. Before trusting an "armed" claim, find the process by its own
  arguments — `pgrep -fl '[p]r-review.sh watch .*#<pr>'` (the bracket keeps the pattern from
  matching the shell that runs it; `-l`, not procps-only `-a`, lists the line on both macOS
  and Linux) — not by cwd, which a backgrounded child need not keep. When resuming an
  interrupted agent, lead
  with a disk-first brief: inventory `git status`/log in its worktree, trust the disk over its
  memory, re-run anything whose result is not in a file (observed 3x on 2026-08-23; commits
  proved durable every time, so "commit early" is the cheap insurance to insist on in briefs).
- **Converge long reviews.** An automated reviewer keeps finding members of any open-ended
  artifact (a scanner, a property table) indefinitely; two agents went 9 and 13 rounds on
  2026-08-22. After ~5 rounds send the policy: fix only findings that show a claim CANNOT fail
  (vacuous guard, untracked config key, host-dependent expectation); reply in-thread and defer
  everything else to ONE follow-up issue; merge on approval. Both converged within two rounds.
  Pair it with **one push per CI cycle** in late rounds — every push supersedes the ubuntu leg
  (~28 min when the runners are free; the 2026-08-23 wave saw 1h20m with six PRs queued), so a fix that only x86 can confirm stays unconfirmed for as long as pushes keep
  coming — and with "rebase before opening and before merging": CI builds the MERGE commit, so a
  repo-wide scan green on the branch can be red against what landed on master meanwhile.
- **Merge gates under a saturated runner queue.** GitHub's macOS runners serialize; a
  20-PR day queues master runs ~2 h deep, which is how a stale test claim reached master unread
  on 2026-08-23 (#452 → red for two hours). `merge --wait` now refuses without a verdict (see
  ship-pr): brief agents to background it and let it hold, raising `SHIP_PR_CHECKS_WAIT` past
  the observed backlog rather than reaching for `--allow-no-verdict` — merging on the one leg
  that ran is that flag too, with the same bar. A red the next agent inherits is diagnosed by
  `git log` on master between the last green and first red run, not by re-bisecting locally;
  one agent owns the fix-forward and every other open PR is told the red is established.
- **Stacked launches.** When a gated item depends on a sibling PR that is approved but waiting
  on CI, launch it off the sibling's branch (`git worktree add ... origin/claude/<sibling>`),
  have it implement there, and open its PR only after the sibling merges and it has rebased —
  the implementation overlaps the CI wait instead of idling behind it (#708 on #457).
- **GPU boxes from the Mac.** Agents drive rog/minix over ssh for executed legs (worktree
  off their pushed branch, `opam exec --`, unpiped ssh with an exit sentinel) — this wave ran
  CUDA+HIP parity for #730/#710/#709 and the whole #728 experiment that way. Two rules: an
  agent never WoL/power-cycles a box (the user's own sessions may be on it), and a timing
  harness flushes stdout per line and uses a wall bound — a 0%-CPU process in
  `IOSurfaceSharedEvent waitUntilSignaledValue` was a legitimate 2 s unscheduled kernel behind
  dune's buffered stdout, not a hang.
- **Experiment-only items** (the user says "measurement only, don't recommend"): the brief
  forbids implementing or recommending a fix direction, the deliverable is an issue comment
  that a later session can act on, and the issue stays open. Expect the review of the
  harness PR to find real instrument defects (#444: a device readback inside the timed region,
  worth up to 1.7x) — that review is worth its rounds; cap it with the convergence policy
  after, not before.
- **Gate later waves** on the merges and out-of-scope closures they wait for, and rebrief
  each next-wave agent with what its predecessors landed (new helpers, reshaped goldens,
  fresh conventions) so it builds on them instead of colliding.
- **Relay milestones** to the user as they land - merged PRs with one-line substance, not
  agent-status noise.

## Close out

When the last gate clears: a final board (issue -> PR -> merge state), residuals and
follow-up issues the agents filed, and any gates left for the next invocation. Hand notable
merges to the `after-merge` skill while the context is fresh. Notify any sessions the user
asked to be told. If the wave surfaced a new coordination trap, add it to the project's
agent-notes or this skill - whichever the trap belongs to.
