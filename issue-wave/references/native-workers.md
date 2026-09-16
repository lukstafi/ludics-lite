# Within-session native workers

The provider-agnostic body of a native wave: Codex and Claude Code both run same-provider
runtime subagents, one issue per coordinator-created external worktree, and everything below
holds for either. What differs by coordinator is the worker channel and the tool names, and
those live in the per-coordinator files - [native-claude.md](native-claude.md) for a Claude
Code coordinator, [native-codex.md](native-codex.md) for a Codex one; read yours alongside
this. Provider choice does not force native transport: `fleet-worker.sh launch --kind
claude|codex` also supports either provider, including cross-provider delegation and residence
on a task's iteration box ([cli-claude.md](cli-claude.md)). Preserve the user's provider, model
and transport choices. Tool names and concurrency limits come from this runtime, not from a
remembered wave. If subagents are unavailable, report the capability gate; do not silently
create app tasks or substitute CLI workers. The user may explicitly choose the complete
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
isolation. The same holds for scratch space: every native worker of a wave shares the
COORDINATOR's scratchpad directory (it is keyed on the coordinator's session, not the worker's),
so the brief requires every scratch file there to carry the issue number as a prefix (or to
live in a per-issue subdirectory of that scratchpad) - never inside the worker's worktree, which
must be clean of local and ignored data at close-out - and a body file re-read immediately
before the `gh` command that consumes it - on
2026-09-16 two workers overwrote each other's `pr-body.md` there minutes apart, and only timing
kept the wrong body off a PR. Workers must ask the coordinator for an execution assignment before launching fleet tests or
experiments beyond their standing iteration reservation ([executions.md](executions.md#standing-iteration-reservation)), return the actual runner
handle/log/verdict, and leave worktree cleanup to the coordinator. Brief text is
model-agnostic: the commit trailer says "credit your own model" rather than naming one (an Opus
worker inherited a Fable trailer on 2026-09-15 and rightly corrected it), and tool names come
from what this runtime exposes to the worker, never from a remembered brief for the other
provider.

## Supervision, recovery and evidence

Maintain the board on the anchor under `FLEET_ANCHOR_STATE`, alongside CLI state. Store wave and
coordinator identity, durable brief, runtime identity, transport, agent host, intended execution
hosts, checkout ownership, branch/base, dispatch status, PR/head/merge state, last observation,
remaining gates, hand-back, and execution request IDs. Check the lease before board writes and
interventions. `fleet-worker.sh ls/status/attach` observe CLI workers only.

Use native messages and bounded native waits, retaining real identities. Follow up in the same
agent when work is unfinished; observe the response. A returned agent turn is not a merge or a
remote process verdict - and what a returned turn does mean differs by runtime: see your
coordinator file's *What a returned turn means*. Verify PR, issue, Git and test evidence independently. Keep long tests in
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
