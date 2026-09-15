# Codex coordinator, native subagents

The Codex-specific half of a native wave; the shared body - placement, launch, board,
supervision, recovery, close-out, the two-worker smoke - is [native-workers.md](native-workers.md).
Read the currently callable runtime tool schemas: Codex typically exposes `spawn_agent`,
`list_agents`, `send_message`, `followup_task`, `interrupt_agent` and `wait_agent`. Tool names
and concurrency limits come from this runtime, not from a remembered wave, and a Codex tool
name never goes into a brief for a Claude worker.

## Worker channel

A Codex subagent can keep its turn open, so the handoff is message-shaped: before any fleet
correctness/test or measurement run beyond its
[standing iteration reservation](executions.md#standing-iteration-reservation), the worker
messages the coordinator with revision, execution host, workload kind, the bounded command,
checkout and intended log path, then waits for dispatch. The coordinator completes the
reservation, runs `fleet-worker.sh execution run <reserve.json>`, and answers the same agent
with the assignment; the worker runs only that, blocks on it to completion, and reports the run
directory, observed SHA and exit in its reply, which `execution conclude --from-run <run> --request
<id> --sha <sha>` consumes. A Codex worker may also use the fixed `EXECUTION_REQUEST` /
`EXECUTION_RESULT` blocks of [native-claude.md](native-claude.md#worker-channel); what differs
is only that it may wait instead of yielding.

## What a returned turn means

A Codex `wait_agent` return is the agent's turn ending; a background process it started is not
finished by it. Briefs require blocking on every run inside the turn (the project runner's own
`wait`, or keeping the turn open), and a returned turn is read by its final message, never as a
verdict on a run or a merge. An authorized quiet heartbeat may resume reconciliation later; it
must stay quiet on unchanged, non-actionable state and must not assume runtime subagents
survive the gap.

Codex still needs the deployed `ship-pr`, `wait-and-proceed`, and `after-merge` skills, a
self-contained brief, and the full implement-through-merge lifecycle. Ask for the PR,
verification results, residuals and chip candidates in its final report. Codex commits carry no
Claude trailer; include relevant project conventions in the brief or `AGENTS.md`.
