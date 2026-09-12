# Within-session Codex workers (default)

An ordinary supervised Codex wave uses runtime subagents, one issue per coordinator-created
external worktree. Preserve the user's Codex versus Claude choice. Read the currently callable
runtime tool schemas: typically `spawn_agent`, `list_agents`, `send_message`, `followup_task`,
`interrupt_agent` and `wait_agent`. Tool names and concurrency limits come from this runtime,
not from a remembered wave. If subagents are unavailable, report the capability gate; do not
silently create app tasks or substitute CLI workers. The user may explicitly choose the complete
[separate-conversation alternative](separate-codex.md).

## Placement and launch

Interpret the plan with separate columns for **agent host** and **execution host**. A local
agent can drive a reserved CUDA leg on ROG or HIP leg on Minix. Required hardware constrains
execution, not necessarily the residence of the agent. Repeated hardware iteration can justify
proposing a separate task on that host, subject to user choice and its actual host-aware tools.
SSH or Control other devices connectivity does not establish remote runtime-subagent support.

1. Claim the fleet lease and read the plan, existing board, halt, PRs, and execution reservations.
   Resolve the project's development remote (including staging versus upstream), fetch it, and
   verify the intended base ref and exact SHA. Never infer it from a stale local default branch.
2. Discover effective agent capacity from the current runtime's stated limit and active agents,
   including the coordinator and other children. Queue dependency-ready issues when slots are
   occupied and launch as capacity frees. If capacity is unknown, establish it from tool evidence;
   do not invent a fixed limit. Dependency readiness and agent capacity are separate gates, as
   is exclusive execution capacity on each machine.
3. Run `fleet-worker.sh preflight <agent-box> --native-codex`. This verifies deployed skills and
   fleet reach without CLI login or tmux. Confirm actual runtime tools and mutation permissions.
4. Create one external worktree and branch per issue before spawning. For example, with resolved
   absolute paths and a verified base: `git -C <repo> worktree add -b codex/<issue> <external-path>
   <verified-base-sha>`. Record ownership first; do not reuse a checkout with an unresolved writer.
5. Persist the complete brief and pending entry on the anchor. Run `fleet-worker.sh gate`
   immediately before spawning. Nonzero blocks dispatch. `gate --force` is only for the named
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
isolation. Workers must ask the coordinator for a remote execution assignment before launching,
return the actual runner handle/log/verdict, and leave worktree cleanup to the coordinator.

## Supervision, recovery and evidence

Maintain the board on the anchor under `FLEET_ANCHOR_STATE`, alongside CLI state. Store wave and
coordinator identity, durable brief, runtime identity, transport, agent host, intended execution
hosts, checkout ownership, branch/base, dispatch status, PR/head/merge state, last observation,
remaining gates, hand-back, and execution request IDs. Check the lease before board writes and
interventions. `fleet-worker.sh ls/status/attach` observe CLI workers only.

Use native messages and bounded native waits, retaining real identities. Follow up in the same
agent when work is unfinished; observe the response. A returned agent turn is not a merge or a
remote process verdict. Verify PR, issue, Git and test evidence independently. Keep long tests in
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
