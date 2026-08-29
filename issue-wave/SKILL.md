---
name: issue-wave
description: Run a delegation wave over the issue backlog - read the daily sequencing plan, propose a machine-appropriate scope of D1/D2 issues, launch one subagent per issue in its own worktree, each shipping via ship-pr, and supervise the wave to full merge. Use when asked to burn down issues, run a wave, or work the backlog; on ROG/Minix, scope flips to issues that specifically benefit from that box. User decides subagent type (Opus or Codex).
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

One worker per issue, worktrees outside the repo per project convention, parallel groups
launched together in a single message. User decides the workers: either Opus subagents,
or Codex subagents; for Codex, GPT-5.6-Sol or higher, effort high. The brief must be
self-contained (agents do not see this conversation), transfers between worker kinds verbatim,
and includes:

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
  summary comment, then the after-merge brainstorm ship-pr ends with, in **hand-back mode**:
  propose issues and chip candidates in the close-out report, file and spawn nothing — the
  coordinator combines across workers and does the filing. Worktree removal comes LAST, after
  the hand-back is in the close-out — the brainstorm's diff and tracker reads run in that
  worktree — and a worker whose shell sits inside it (Codex, launched `-C <worktree>`) leaves
  removal to the coordinator: removing your own cwd is the "Unable to read current working
  directory" failure ship-pr warns about.
- Process discipline, stated explicitly because agents re-derive it badly under load:
  never end a turn with only a detached process outstanding - attach waits as
  harness-tracked background children; if a review watch goes quiet suspiciously long, read
  the PR feed directly (`gh pr view --comments`) rather than re-arming the watch (reactions
  persist across rounds and strand it).
- **Never re-request review as stall recovery** (2026-08-29): the Codex GitHub reviewer's
  no-findings verdict can arrive as a PR COMMENT ("Didn't find any major issues... Reviewed
  commit: <sha>") rather than only the 👍 reaction, and an `@codex review` re-request CLEARS
  the existing 👍 — a worker that re-requests before reading the feed destroys the approval
  it failed to see. `pr-review.sh status` recognizes the comment-shaped verdict since
  self-improve 0e28fd285; the brief still says: read the full feed first, re-request only
  when it truly holds nothing for the current head.
- Encouragement. It is cheap and the user asked for it: name why the issue matters and
  express confidence. Agents visibly do their best work when the brief treats them as
  trusted colleagues.

### Codex workers

Launch as a harness-tracked background Bash task, one per worktree. Write the brief to a
file first and feed it through stdin - never interpolate it into the command line, where the
backticks, `$()`, and quotes that issue-derived prose routinely contains would be executed
or mangled by the coordinator's own shell:

```
codex exec --json --strict-config -c 'sandbox_mode="workspace-write"' \
  -c 'sandbox_workspace_write.network_access=true' \
  -c 'sandbox_workspace_write.writable_roots=["<main-checkout>/.git","<home>/.local/state","<home>/.ocannl-test-runs"]' \
  -C <worktree> -o <report-file> - < <brief-file>
```

The two state roots come from the first wave's friction reports (2026-08-29): without them
every `pr-review.sh` call warns about its `~/.local/state/ship-pr` cache and
`tools/test-run.sh` cannot write its default runs directory (workers found env-var
workarounds, but granting the roots is smoother). Two sandbox limits to plan around, not
patch: `gh`'s cache under `~/.cache` stays blocked (workers set `XDG_CACHE_HOME=/tmp/...`
when needed — fine), and the sandbox hides GPU devices (a worker probing Metal saw no
device), so GPU-measurement issues need `--yolo`, a Claude worker, or the GPU-box ssh path.

Capture the session UUID from the JSONL stream at launch - it is the address for every later
intervention. Mechanics that differ from Opus workers:

- **Skills**: `ship-pr`, `wait-and-proceed`, and `after-merge` are symlinked into
  `~/.codex/skills` (from this repo's working tree - merged skill edits propagate with no
  deploy step). Codex has no `spawn_task`, which hand-back mode makes moot: wave workers of
  either kind propose rather than file.
- **Network**: the `workspace-write` sandbox blocks network by default; the
  `sandbox_workspace_write.network_access=true` override in the launch line lifts that
  (verified end to end on CLI 0.150.1: an exec-launched agent's `curl` gets HTTP/2 200 with
  it, exit 6 without) so the worker can push, drive `gh`, and own its full lifecycle through
  ship-pr. Keep `--strict-config`: it is what rejects a mistyped or unsupported override -
  0.150.1 rejects `sandbox_permissions` there, a key its own help text still suggests -
  instead of silently launching a network-blocked worker. Deliberate choice: review rounds
  are addressed by the continuous session that wrote the code, never handed to a
  fresh-context finisher - the finisher is the escalation path for stalls (Supervise), not a
  landing path.
- **Linked-worktree git metadata**: a linked worktree's index and refs live under the MAIN
  checkout's `.git/worktrees/<name>`, outside the `-C` workspace, so without the
  `writable_roots` override every `git add`/`commit`/rebase dies on `index.lock: Operation
  not permitted` (verified end to end on 0.150.1: an exec-launched agent's commit in a linked
  worktree fails without it, lands with it). Express it as config, not `--add-dir`: exec has
  the flag but `exec resume` does not, and resume must repeat the sandbox settings.
- **Structured close-out**: `--output-schema` can force the final report shape (PR number,
  test status, residuals, chip candidates) when parsing prose reports gets old.
- **Attribution**: Codex commits carry no Claude trailer; the project's CLAUDE.md
  conventions reach it only through the brief or a mirrored `AGENTS.md`.

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
  arguments — `pgrep -fl '[p]r-review.sh watch <owner>/<repo>#<pr>( |$)'`, the full argument
  ship-pr mandates, anchored (the bracket keeps the pattern from matching the shell that runs
  it; `-l`, not procps-only `-a`, lists the line on both macOS and Linux) — not by cwd, which
  a backgrounded child need not keep. When resuming an
  interrupted agent, lead
  with a disk-first brief: inventory `git status`/log in its worktree, trust the disk over its
  memory, re-run anything whose result is not in a file (observed 3x on 2026-08-23; commits
  proved durable every time, so "commit early" is the cheap insurance to insist on in briefs).
- **Babysit through `pr-review.sh`, not hand-rolled `gh`.** When the coordinator ends up
  shepherding a PR itself — a takeover after failed unsticks, a finisher's branch, a stranded
  PR inherited from a dead session — drive the review loop with the ship-pr skill's
  `~/.claude/skills/ship-pr/scripts/pr-review.sh` (`poll`, `watch`, `status`, `checks`,
  `merge`, `reply`, `resolve`, `comment`, `retry`). It encodes the traps ship-pr documents —
  retry on GitHub's coin-flip 5xxs, the pagination long review rounds walk into, exit codes
  that distinguish "the fact does not hold" (1) from "the API never answered" (3) — that
  hand-rolled `gh` calls rediscover the hard way. The same applies to one-off supervision
  reads: `pr-review.sh retry --read <gh args…>` beats an ad-hoc retry loop.
- **Codex workers have no yield signal.** A `codex exec` run is silent between JSONL events,
  so the "yields twice with no state change" play does not exist for it. The stall test is
  external: the JSONL stream quiet AND `git log`/`git status` in its worktree unmoved over a
  wall-clock window sized to the task. To unstick, write the imperative message to a file
  and `cd <worktree> && codex exec resume <session-id> <sandbox flags> - < <message-file>`.
  That closes the same class as the launch brief: ANY prose substituted into a codex command
  line is shell-expanded before Codex sees it, so every prompt rides stdin (`-`) or a file -
  the post-merge brainstorm prompt below included. The `cd` is mandatory: resume has no `-C`
  and adopts the invoking shell's cwd, so a resume fired from the coordinator's own checkout
  resumes the worker inside the WRONG repo. Full session context is retained (a running
  session takes `codex queue --thread <id> --message` instead - present on CLI 0.150.1,
  absent on 0.144: there, wait out or kill the exec, then resume. `--message` has no stdin
  form, so it carries only literal text you typed yourself, never substituted content). A resume is a fresh CLI
  invocation: it retains the conversation, not the launch flags, so every resume repeats the
  launch line's three `-c` sandbox overrides. `-c` only: `exec resume` has no `-s` flag
  (0.150.1 rejects it, "unexpected argument"), which is why the launch line expresses the
  sandbox mode as config too. A resume without the overrides is back in the network-blocked
  default and the unstick message lands in a worker that cannot push. Escalation is the same as for
  a Claude agent: two failed interventions and the coordinator takes over the mechanical
  remainder or spawns a Claude finisher on the worktree's branch - after confirming the
  stalled exec is DEAD (kill its pid and wait for the exit), because a quiet stream does not
  prove it cannot still act: a queued message processed late would give the branch two
  concurrent writers, one of them a finisher mid-rebase. A finisher landing a stalled
  worker's branch does not inherit its transcript, so the friction that grounds `after-merge`
  is still in the Codex session: after the merge, `codex exec resume <session-id>` it (from
  inside the worktree, which removal-comes-last has kept alive; same sandbox flags -
  hand-back mode still reads the tracker for dedup) for the hand-back
  brainstorm rather than brainstorming its work from the outside; only if the session is
  unresumable does the coordinator brainstorm from the diff and say so.
- **Converge long reviews.** An automated reviewer keeps finding members of any open-ended
  artifact (a scanner, a property table) indefinitely; two agents went 9 and 13 rounds on
  2026-08-22. After ~5 rounds send the policy: fix only findings that show a claim CANNOT fail
  (vacuous guard, untracked config key, host-dependent expectation); reply in-thread and defer
  everything else to ONE follow-up issue; merge on approval. Both converged within two rounds.
  The 2026-08-27 wave (three reviews at 11–18 rounds) refined the policy into the form to send:
  the axis is **silent vs loud** — a silent defect (a claim that cannot fail, a sweep that deletes
  what it shouldn't, an oracle a scheduler accident satisfies) is must-fix at ANY round count,
  while a loud one (a false refusal or error on valid-but-absent shapes) defers; a silent finding
  only reachable by code nobody has written defers too (reachability qualifier); and defects in
  machinery the review itself introduced are the worker's to fix, not to defer ("filing bugs
  against myself"). When a reviewer approves only by finding nothing and the last rounds are
  confined to review-requested machinery, pre-authorize merge-on-substance: CI green on the final
  head, every thread answered with its classification, and a review-record paragraph in the PR
  body. Expect good workers to push back on your framing with verified evidence — the wave's best
  worker corrected the coordinator's premise three times, correctly each time; endorse that, don't
  override it.
  Pair it with **one push per CI cycle** in late rounds — every push supersedes the ubuntu leg
  (~28 min when the runners are free; the 2026-08-23 wave saw 1h20m with six PRs queued), so a fix that only x86 can confirm stays unconfirmed for as long as pushes keep
  coming — and with "rebase before opening and before merging": CI builds the MERGE commit, so a
  repo-wide scan green on the branch can be red against what landed on master meanwhile.
  Where the ci workflow has NO concurrency group, pushes do not supersede — they queue serially
  behind runs for commits nobody will merge (13 queued runs starved one PR's head for an hour on
  2026-08-28). The play: freeze pushes, cancel exactly the runs for superseded intermediate
  commits, let the head's run through, then one batched push carrying the held fixes. A worker
  told to freeze should hold locally-verified commits unpushed with their threads deliberately
  unresolved (resolving would claim work not visible on the PR).
- **Merge gates under a saturated runner queue.** GitHub's macOS runners serialize; a
  20-PR day queues master runs ~2 h deep, which is how a stale test claim reached master unread
  on 2026-08-23 (#452 → red for two hours). `merge --wait` now refuses without a verdict (see
  ship-pr): brief agents to background it and let it hold, raising `SHIP_PR_CHECKS_WAIT` past
  the observed backlog rather than reaching for `--allow-no-verdict` — merging on the one leg
  that ran is that flag too, with the same bar — and whoever does merge unread owns re-checking
  the master run it produces. A red the next agent inherits is diagnosed by
  `git log` on master between the last green and first red run, not by re-bisecting locally;
  one agent owns the fix-forward and every other open PR is told the red is established.
- **When on non-default machine (ROG, Minix), re-check for a rival PR before each queued launch.**
  Waves on ROG and Minix often run in parallel, and a queued issue may have grown a PR from
  another box's wave since scoping — the pre-wave `gh pr list` goes stale within hours.
  Before launching each queued worker, search open PRs for the issue number/topic; on a hit,
  rebrief the worker to *adopt* the existing PR
  (take over the branch, answer its review, coordinate in PR comments if the original session
  resumes — merge ownership goes to whichever session is actively driving, settled explicitly
  in the PR thread, never raced) instead of opening a competitor. A cross-wave adoption also splits
  the hand-back: whichever coordinator files first checks the other wave's filings for overlap,
  and a follow-up the other session claimed ("I will file X") is theirs — record it as a close-out
  gate, don't duplicate it.
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
follow-up issues, and any gates left for the next invocation. Workers ran `after-merge` in
hand-back mode, so each close-out arrives carrying proposed issues, chip candidates, and
reasoned drops; the coordinator's role here is editorial, not generative. Combine overlapping
proposals across workers into single issues — cross-worker recurrence is the strongest
priority signal a wave produces — revise drafts against the tracker's style, then do the
filing, evidence comments, and chip-spawning yourself. Do not re-brainstorm a worker's merge
from the supervision view (its transcript grounds it better); run `after-merge` directly only
for work the coordinator itself shepherded. Notify any sessions the user
asked to be told. If the wave surfaced a new coordination trap, add it to the project's
agent-notes or this skill - whichever the trap belongs to.
