# Within-session native workers

Codex and Claude Code can both run same-provider runtime subagents, one issue per
coordinator-created external worktree. Provider choice does not force native transport:
`fleet-worker.sh launch --kind claude|codex` also supports either provider, including
cross-provider delegation and residence on a task's iteration box. Preserve the user's provider,
model and transport choices. Read the currently callable runtime tool schemas: Codex typically exposes `spawn_agent`, `list_agents`, `send_message`, `followup_task`,
`interrupt_agent` and `wait_agent`; Claude Code uses its available Agent/task tools and
tracked completion mechanism. Do not copy Codex tool names into a Claude brief. Tool names and concurrency limits come from this runtime,
not from a remembered wave. If subagents are unavailable, report the capability gate; do not
silently create app tasks or substitute CLI workers. The user may explicitly choose the complete
[separate-conversation alternative](separate-codex.md).

## Placement and launch

Interpret the plan with separate columns for **agent host** and **execution host**. A local
agent can drive a reserved CUDA leg on ROG or HIP leg on Minix. Required hardware constrains
execution, not necessarily the residence of the agent. Repeated hardware iteration can justify
choosing a CLI worker on that host, or proposing an explicitly selected separate app task
subject to its actual host-aware tools. This default does not preclude checks on other boxes;
reserve each execution separately, including runs local to the agent.
SSH or Control other devices connectivity does not establish remote runtime-subagent support.

1. Claim the fleet lease and read the plan, existing board, halt, PRs, and execution reservations.
   Resolve the project's development remote (including staging versus upstream), fetch it, and
   verify the intended base ref and exact SHA. Never infer it from a stale local default branch.
2. Discover effective agent capacity from the current runtime's stated limit and active agents,
   including the coordinator and other children. Queue dependency-ready issues when slots are
   occupied and launch as capacity frees. If capacity is unknown, establish it from tool evidence;
   do not invent a fixed limit. Dependency readiness and agent capacity are separate gates, as
   is exclusive execution capacity on each machine.
3. Run `fleet-worker.sh preflight <agent-box> --native-codex` for Codex or `--native-claude`
   for Claude. This verifies the provider's deployed skills and
   fleet reach without CLI login or tmux. Confirm actual runtime tools and mutation permissions.
4. Create one external worktree and branch per issue before spawning. For example, with resolved
   absolute paths and a verified base: `git -C <repo> worktree add -b codex/<issue> <external-path>
   <verified-base-sha>`. Record ownership first; do not reuse a checkout with an unresolved writer.
5. Persist the complete brief and pending entry on the anchor. Run `fleet-worker.sh gate --target-repo <owner/repo> [--base-branch <branch>]`
   immediately before spawning. Nonzero blocks dispatch. `gate --target-repo <owner/repo> --force --allow-red-base "<triage reason>"` is only for the named
   regression-triage worker and must be recorded. This check is point-in-time, not atomic with a
   runtime tool call; adoption must reconcile pending dispatches before replacement.
6. Spawn with that brief, recording the returned actual agent identity/canonical task name.
   Do not infer a runtime ID from an app task ID. Validate the worker's startup report before
   considering launch successful: actual absolute worktree, branch, base SHA, agent identity,
   and a harmless successful Git mutation such as `git update-index --refresh` with exit status.

The default self-contained brief includes issue repository/number and comments to read, scope,
absolute assigned worktree and branch, verified base SHA, agent and execution hosts, coordinator
runtime identity, applicable project guidance, test bounds, ship-pr and issue-close responsibilities,
and after-merge hand-back mode. Require **an explicit command working directory for every shell
call and absolute assigned paths for edits**. Runtime children share the environment: cooperative
cross-path reads are allowed, but each checkout has one writer. Never rely on inherited cwd as
isolation. Workers must ask the coordinator for an execution assignment before launching fleet tests or
experiments beyond their standing iteration reservation (below), return the actual runner
handle/log/verdict, and leave worktree cleanup to the coordinator. Brief text is
model-agnostic: the commit trailer says "credit your own model" rather than naming one (an Opus
worker inherited a Fable trailer on 2026-09-15 and rightly corrected it), and tool names come
from what this runtime exposes to the worker, never from a remembered brief for the other
provider.

## Claude Code worker channel

A Claude Code subagent cannot wait mid-turn: nothing lets it block on a coordinator message, and
ending its turn is its only way to yield. So the "message the coordinator and wait for dispatch"
shape above is Codex's; the Claude shape is turn-shaped, and the brief template in SKILL.md
spells it out. It carried four issues and a release through five PRs on 2026-09-15 with no
stranded worker.

1. **Standing iteration reservation, at launch.** The coordinator takes one `kind:
   correctness` reservation per worker on its agent host with `fleet-worker.sh execution run`
   (request id `<wave>-<issue>-<host>-iterate`; see [executions.md](executions.md)) and names
   it in the brief. It pre-authorizes the worker's own targeted test batches there - each
   through the project runner (`tools/test-run.sh run ...`), blocked to completion inside the
   turn, reported by run directory in the worker's messages - with no per-batch request. It is
   concluded at hand-back from the last batch's record. Boxes hold as many of these as their
   correctness slots allow (three on mac-studio); a measurement needs the box to itself.
2. **Request, for everything else.** A measurement, a cross-box leg, a full suite: the worker
   ends its turn with its final message carrying one block and nothing after it:

   ```
   EXECUTION_REQUEST
   {"request_id":"<wave>-<issue>-<host>-<n>","execution_host":"rog-nv-wsl","kind":"measurement",
    "requested_revision":"<pushed sha>","checkout":"<absolute path on the execution host>",
    "command":"<one bounded runner command>","log":"<intended log path, or ->"}
   END_EXECUTION_REQUEST
   ```

   The task notification that follows is this hand-back, not completion.
3. **Assign.** The coordinator completes the reservation (wave, worker, `transport:
   "subagent"`, agent host, repository, issue, purpose - the request supplies the rest), runs
   `execution run <reserve.json>`, and on exit 0 resumes the worker by its agent ID (the
   runtime's continue-an-agent form: SendMessage to the agent's name or ID, never a fresh
   Agent call) with one line, `EXECUTION_ASSIGNED <request_id>`, followed by the exact
   command, revision, checkout and log to use. On a refusal, hold the worker - idle, it keeps
   its context - or answer `EXECUTION_REFUSED <reason>` so it keeps implementing.
4. **Result.** The resumed worker runs only the assigned command, blocks on it to completion
   within the turn (`TaskOutput` on the harness's background task, or `tools/test-run.sh wait
   last`), and ends that turn with one fixed line, so the coordinator concludes without
   grepping run ids out of prose:

   ```
   EXECUTION_RESULT {"request_id":"<id>","run":"<absolute test-run.sh run directory>","exit":0,"observed_sha":"<sha that ran>"}
   ```

   The coordinator runs `fleet-worker.sh execution conclude --from-run <run> --request <id>
   --box <execution host>`, which reads verdict, log, checkout and head off the record and
   refuses an unfinished run or a checkout committed to since (then `--sha` from the result
   line vouches for the revision), and resumes the worker with `EXECUTION_CONCLUDED <id>
   <verdict>` or its next assignment.

The same request/result lines work for a Codex native worker that prefers them; what differs is
only that Codex may keep its turn open and wait.

## Supervision, recovery and evidence

Maintain the board on the anchor under `FLEET_ANCHOR_STATE`, alongside CLI state. Store wave and
coordinator identity, durable brief, runtime identity, transport, agent host, intended execution
hosts, checkout ownership, branch/base, dispatch status, PR/head/merge state, last observation,
remaining gates, hand-back, and execution request IDs. Check the lease before board writes and
interventions. `fleet-worker.sh ls/status/attach` observe CLI workers only.

Use native messages and bounded native waits, retaining real identities. Follow up in the same
agent when work is unfinished; observe the response. A returned agent turn is not a merge or a
remote process verdict. **A Claude Code task notification means the agent's turn ended, and
nothing more**: a worker that started `dune` in the background and yielded produces the same
notification as one that finished (twice on 2026-09-15 a "finished" notification arrived with
the worker's dune still running). Briefs therefore require blocking on every run before
yielding (`TaskOutput` on the background task, or `tools/test-run.sh wait last`), and the
coordinator reads a notification by the worker's final message: an `EXECUTION_REQUEST` or
`EXECUTION_RESULT` block is a hand-off, a ship-pr hand-back report is completion, anything else
is read against the PR feed and the agent listing before it is called a stall. An idle worker
(turn ended, no background task) disappears from the agent listing but keeps its whole context
and resumes by ID; a worker still listed as running is mid-turn or holds a background task and is
not stalled, so spawn no finisher on its worktree. Verify PR, issue, Git and test evidence independently. Keep long tests in
bounded tracked sessions; recover their actual exit code rather than starting a duplicate when
output goes quiet. Re-arm review/check waiters for the current commit after a push. The exact-head
CI and Windows evidence guidance in the separate-conversation reference also applies to runtime
workers; those verification rules do not change transport.

After interruption or adoption, reconcile what the current runtime actually exposes with the
anchor board, Git/PR evidence and project runner records. Restart survival was not established by
the original smoke: do not promise durability and do not assume agents or child processes stopped.
Resolve each pending identity and existing checkout writer before resuming or replacing it. A
missing agent listing is not proof that its processes cannot write. Use the available native
controls and process evidence; leave takeover gated when ownership cannot be established.
Reconcile outstanding [execution assignments](executions.md) separately before reusing boxes.

For regressions, halt fleet dispatch and message each runtime worker. Keep the named triage
exception visible. A message or interruption request alone is not proof the old writer stopped.
Keep administrative identity gaps distinct from dependencies: independently verified prerequisite
merges can unblock dependent issues while the coordinator still pursues the missing hand-back.
Do not release the wave with unaccounted identities or executions. An authorized heartbeat can
resume reconciliation later; it must stay quiet on unchanged non-actionable state and must not
assume runtime subagents survive the gap.

## Close-out and bounded smoke

Verify each completed hand-back, landed changes and clean checkout (including local/ignored data),
then confirm no agent, child process or outstanding execution assignment still uses that checkout.
Only the coordinator removes its externally created worker worktree using the project's cleanup
procedure. Retain any checkout whose ownership or execution is uncertain. App-managed worktrees
follow the separate-conversation cleanup rules instead. Consolidate workers' after-merge proposals,
persist the final board and release the lease last.

For a bounded transport smoke, create two disposable external worktrees with distinct branches at
one verified base. Spawn two workers with explicit cwd/absolute-path briefs. Each reports `pwd`,
branch and base, successfully refreshes its index, and reads one tracked file from the sibling
checkout without editing it. Collect both real agent IDs and exit results, check clean state and
execution assignments, then remove the two checkouts only after both hand-backs. No feature PR or
full issue wave is needed; record observations rather than encoding prose sentences as tests.
