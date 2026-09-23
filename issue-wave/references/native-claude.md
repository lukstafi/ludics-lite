# Claude Code coordinator, native workers

The Claude-specific half of a native wave; the shared body - placement, launch, board,
supervision, recovery, close-out, the two-worker smoke - is [native-workers.md](native-workers.md).
The tools are what this runtime exposes: `Agent` spawns a worker (it returns the agent's name
or ID, which is the address for everything after), `SendMessage` continues a spawned agent
with its context intact, `ListAgents` lists the ones currently running, `TaskOutput` blocks on
a background task, `TaskStop` ends one. Read their current schemas; a deferred tool is loaded
with `ToolSearch` first.

## Worker channel

A Claude Code native worker cannot wait mid-turn: nothing lets it block on a coordinator
message, and ending its turn is its only way to yield. So the "message the coordinator and
wait for dispatch" shape of [native-codex.md](native-codex.md#worker-channel) is Codex's; the
Claude shape is turn-shaped, and SKILL.md's brief template names it. It carried four issues
and a release through five PRs on 2026-09-15 with no stranded worker.

1. **Standing reservation, at launch.** The coordinator takes one `kind: correctness`,
   `"standing": true` reservation per worker on its agent host with `fleet-worker.sh execution
   run` (request id `<wave>-<issue>-<host>-iterate`; see [executions.md](executions.md)) and
   names it in the brief. It pre-authorizes the worker's own targeted test batches there -
   each through the project runner (`tools/test-run.sh run ...`), blocked to completion inside
   the turn, reported by run directory in the worker's messages - with no per-batch request. It
   is concluded at hand-back from the last batch's record. Being standing, it consumes no
   correctness slot, so a box holds as many as it has workers and a worker never waits on a
   sibling's brief-reading to start. The brief tells the worker to wrap each batch in the
   run-time lock instead - `fleet-worker.sh execution slot -- <batch>`, which takes one of the
   box's slots for exactly as long as the batch runs (six on mac-studio, one on a box the spec
   does not name) and refuses while a measurement is outstanding there; a measurement still
   needs the box to itself through the registry.
2. **Request, for everything else.** A measurement, a cross-box leg, a full suite: the worker
   ends its turn with its final message carrying one block and nothing after it:

   ```
   EXECUTION_REQUEST
   {"request_id":"<wave>-<issue>-<host>-<n>","execution_host":"rog-nv-linux","kind":"measurement",
    "requested_revision":"<pushed sha>","checkout":"<absolute path on the execution host>",
    "command":"<one bounded runner command>","log":"<intended log path, or ->"}
   END_EXECUTION_REQUEST
   ```

   The task notification that follows is this handoff, not completion.
3. **Assign.** The coordinator completes the reservation (wave, worker, `transport:
   "subagent"`, agent host, repository, issue, purpose - the request supplies the rest), runs
   `execution run <reserve.json>`, and on exit 0 resumes the worker by its agent ID (the
   runtime's continue-an-agent form: SendMessage to the agent's name or ID, never a fresh
   Agent call) with one line, `EXECUTION_ASSIGNED <request_id>`, followed by the exact
   command, revision, checkout and log to use. On a refusal, hold the worker - idle, it keeps
   its context - or answer `EXECUTION_REFUSED <reason>` so it keeps implementing.
4. **Result.** The resumed worker runs only the assigned command. Correctness uses
   `fleet-worker.sh execution slot -- <command>`, which is what bounds the box's
   concurrent load. An exclusively reserved measurement runs the bounded project runner directly,
   without `execution slot`, as [executions.md](executions.md#reserve-launch-observe-conclude)
   specifies: under `fleet-worker.sh execution hold -- <command>`, the OS-level sleep guard
   alone. The worker blocks on either kind to completion within the turn (`TaskOutput` on the harness's
   background task, or `tools/test-run.sh wait last`), and ends that turn with one fixed line,
   so the coordinator concludes without grepping run ids out of prose:

   ```
   EXECUTION_RESULT {"request_id":"<id>","run":"<absolute test-run.sh run directory>","exit":0,"observed_sha":"<sha that ran>"}
   ```

   The coordinator runs `fleet-worker.sh execution conclude --from-run <run> --request <id>
   --sha <observed_sha>`, which reads verdict, log and checkout off the record on the reserved
   box (the record carries no SHA, so the result line's is the revision of record; a checkout
   that has moved on since is noted in the evidence) and refuses an unfinished run, and then
   resumes the worker with `EXECUTION_CONCLUDED <id> <verdict>` or its next assignment.

The same request and result lines work for a Codex native worker that prefers them; what
differs is only that Codex may keep its turn open and wait.

## What a returned turn means

The rule is SKILL.md's (Supervise: *A returned turn means the turn ended*); on this runtime the
signal is the task notification, and a worker that started `dune` in the background and
yielded produces the same notification as one that finished. Two Claude-specific readings: an
idle worker (turn ended, no background task) disappears from `ListAgents` but keeps its whole
context and resumes by ID with `SendMessage`; a worker still listed as running is mid-turn or
holds a background task and is not stalled, so spawn no finisher on its worktree.

**Stay alive.** The Claude Desktop pause and the coordinator-side heartbeat are SKILL.md's
(Supervise: *Stay alive, but design for dying*). After any interruption reconcile from
`ListAgents`, the board and the PRs rather than from memory; an idle worker is still there to
resume.
