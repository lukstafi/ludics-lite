# Claude Code coordinator, native subagents

The Claude-specific half of a native wave; the shared body - placement, launch, board,
supervision, recovery, close-out, the two-worker smoke - is [native-workers.md](native-workers.md).
The tools are what this runtime exposes: `Agent` spawns a worker (it returns the agent's name
or ID, which is the address for everything after), `SendMessage` continues a spawned agent
with its context intact, `ListAgents` lists the ones currently running, `TaskOutput` blocks on
a background task, `TaskStop` ends one. Read their current schemas; a deferred tool is loaded
with `ToolSearch` first. Do not copy Codex tool names into a brief, and do not remember these
from a previous wave - they change between builds (on 2026-09-10 `SendMessage` was not loadable
at all; on 2026-09-15 it was the whole channel).

## Worker channel

A Claude Code subagent cannot wait mid-turn: nothing lets it block on a coordinator message, and
ending its turn is its only way to yield. So the "message the coordinator and wait for dispatch"
shape of [native-codex.md](native-codex.md#worker-channel) is Codex's; the Claude shape is turn-shaped, and the brief template in SKILL.md
spells it out. It carried four issues and a release through five PRs on 2026-09-15 with no
stranded worker.

1. **Standing iteration reservation, at launch.** The coordinator takes one `kind:
   correctness`, `"standing": true` reservation per worker on its agent host with
   `fleet-worker.sh execution run` (request id `<wave>-<issue>-<host>-iterate`; see
   [executions.md](executions.md)) and names it in the brief. It pre-authorizes the worker's own
   targeted test batches there - each through the project runner (`tools/test-run.sh run ...`),
   blocked to completion inside the turn, reported by run directory in the worker's messages -
   with no per-batch request. It is concluded at hand-back from the last batch's record. Being
   standing, it consumes no correctness slot, so a box holds as many as it has workers and a
   worker never waits on a sibling's brief-reading to start. The brief tells the worker to wrap
   each batch in the run-time lock instead - `fleet-worker.sh execution slot -- <batch>`, which
   takes one of the box's slots for exactly as long as the batch runs (six on mac-studio, one
   on a box the spec does not name) and refuses while a measurement is outstanding there; a
   measurement still needs the box to itself through the registry.
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
4. **Result.** The resumed worker runs only the assigned command - wrapped, like its own
   batches, in `fleet-worker.sh execution slot -- <command>`, which is what bounds the box's
   concurrent load - blocks on it to completion within the turn (`TaskOutput` on the harness's background task, or `tools/test-run.sh wait
   last`), and ends that turn with one fixed line, so the coordinator concludes without
   grepping run ids out of prose:

   ```
   EXECUTION_RESULT {"request_id":"<id>","run":"<absolute test-run.sh run directory>","exit":0,"observed_sha":"<sha that ran>"}
   ```

   The coordinator runs `fleet-worker.sh execution conclude --from-run <run> --request <id>
   --sha <observed_sha>`, which reads verdict, log and checkout off the record on the reserved
   box (the record carries no SHA, so the result line's is the revision of record; a checkout
   that has moved on since is noted in the evidence) and refuses an unfinished run, and then
   resumes the worker with `EXECUTION_CONCLUDED <id> <verdict>` or its next assignment.

The same request/result lines work for a Codex native worker that prefers them; what differs is
only that Codex may keep its turn open and wait.

## What a returned turn means

**A Claude Code task notification means the agent's turn ended, and
nothing more**: a worker that started `dune` in the background and yielded produces the same
notification as one that finished (twice on 2026-09-15 a "finished" notification arrived with
the worker's dune still running). Briefs therefore require blocking on every run before
yielding (`TaskOutput` on the background task, or `tools/test-run.sh wait last`), and the
coordinator reads a notification by the worker's final message: an `EXECUTION_REQUEST` or
`EXECUTION_RESULT` block is a hand-off, a ship-pr hand-back report is completion, anything else
is read against the PR feed and the agent listing before it is called a stall. An idle worker
(turn ended, no background task) disappears from the agent listing but keeps its whole context
and resumes by ID; a worker still listed as running is mid-turn or holds a background task and is
not stalled, so spawn no finisher on its worktree.

**Stay alive.** The desktop app pauses a warm coordinator session about fifteen minutes after
its last main-conversation activity, and a background waiter held inside a subagent does not
hold the pause. While workers are working and the user may be away, keep a coordinator-side
heartbeat under that threshold (SKILL.md's *Supervise*), and after any interruption reconcile
from the agent listing, the board and the PRs rather than from memory - an idle worker is
still there to resume.
