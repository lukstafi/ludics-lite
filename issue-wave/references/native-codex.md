# Native Codex workers

Use this path for Codex workers in an issue wave. Tool names below refer to the Codex app
capabilities (`mcp__codex_app__*` in the current harness); discover them when deferred and read
their current schemas. The app creates ordinary user-level tasks, each with a dedicated Git
worktree and an independent conversation. Do not use `codex exec`, tmux, `fleet-worker.sh
launch --kind codex`, or a shared-directory runtime subagent for these workers.

## Placement and launch

1. Call `list_projects` and match the repository and the plan's box to a saved project and
   its configured host. Check `isGitRepository`; issue workers need a Git project. A machine
   reachable by ssh is not necessarily a connected app host. If the required project/host
   is unavailable, record that placement gate and defer the issue or obtain a revised
   placement. Do not silently dispatch it locally or substitute the CLI.
2. Claim the existing fleet coordinator lease. Before each launch run
   `fleet-worker.sh preflight <box> --native-codex`. This preserves the deployed checkout,
   symlink and cross-box checks without requiring either CLI's login or a headless probe,
   or tmux. Confirm the project setup can supply the task's tools and permissions; a passing
   filesystem preflight alone does not prove native startup will succeed.
3. Write the self-contained brief and a pending entry to the shared wave board. Recheck rival
   PRs and dependencies, then run `fleet-worker.sh gate` immediately before `create_thread`.
   Exit 0 permits dispatch; any other exit blocks it. `gate` checks the anchor lease and halt
   state at that instant; it does not reserve a worker or atomically fence a later app call.
   An adoption must reconcile pending entries before creating anything. Use `gate --force`
   only for the single named regression-triage worker while halted, and record the exception.
4. Call `create_thread` with `target.type: "project"`, the returned `projectId`, and
   `target.environment: {type: "worktree"}`. Put the complete brief in `prompt` and use a
   recognizable issue title. Omit `model` and `thinking` unless the user requested overrides;
   a tool's current model availability governs any requested setting. Do not create a
   projectless or cloud task for repository work on a named fleet box.
5. Let the app create the worktree. Do not pre-create a second worktree with the shell
   launcher. By default omit `startingState` and use the project's default branch. If the
   user explicitly requested a particular starting ref or the current working tree, use
   the corresponding supported `startingState`. Never invent a branch to fill that field.
   Put required base verification in the brief: before edits, fetch and check the planned
   base, record its SHA, and create a `codex/<topic>` branch if needed. If a nondefault base
   cannot be selected through the permitted tool fields, have the worker set it up in its
   fresh worktree before edits; stop if local changes make that unsafe. Existing-PR adoption
   must preserve the existing branch and first establish that its prior writer has stopped.
6. A ready result supplies `threadId` and `hostId`. Record both. A setup-in-progress result
   may supply only `clientThreadId`: record it as pending, do not pass it to tools requiring
   `threadId`, and do not call `create_thread` again just because setup is slow. Reconcile
   with `list_threads` using project, host and the pending task's title/context; obtain the
   real thread ID and confirm startup with `read_thread`. An ambiguous or failed creation
   stays a gate until the app state establishes whether a task exists.

An example of the creation arguments, after substituting a verified project ID and full brief:

```json
{
  "title": "owner/repo #123: implement the scoped issue",
  "prompt": "<complete worker brief, including base verification and hand-back mode>",
  "target": {
    "type": "project",
    "projectId": "<id from list_projects for the planned box>",
    "environment": {"type": "worktree"}
  }
}
```

The first worker update should identify its actual host, worktree path, branch and base SHA.
Check them against the plan before treating the launch as successful. App-managed worktree
paths replace the CLI launcher's `<checkout>-worktrees/<name>` convention for these workers.
The worker owns only its issue; it must not claim the fleet lease or start another wave.

## Shared board and recovery

`fleet-worker.sh ls/status/log/attach` only know CLI workers. Keep a native board alongside
those records on the **anchor**, under `FLEET_ANCHOR_STATE` (default
`~/.local/state/issue-wave`), for example `native-workers.md`. Write it through the anchor's
filesystem/ssh path, not a coordinator-local copy that another host cannot recover. Record:

- Wave/coordinator identity, issue and intended box, project ID, brief location/content.
- Dispatch state, pending client ID if any, resolved thread ID and host ID.
- Actual worktree, branch and base SHA, PR, last observed status, remaining gates and hand-back.

Persist the pending entry before dispatch and update it after every creation, intervention,
merge and hand-back. Store the brief durably on the anchor as well. Recheck lease ownership
before dispatch, intervention and board updates. The board is coordinator-maintained, not a
new script worker record; do not manufacture tmux/session files to make `ls` include it.

After interruption or lease adoption, read the anchor board and halt state, reconcile native
entries with `list_threads`/`read_thread` and CLI entries with `fleet-worker.sh ls`, then
resume supervision of the same identities. Read archived threads if a recorded task was
archived; disappearance from the recent list is not proof of failure. Do not assume a
coordinator interruption stopped a worker, or that a persistent thread is still running.

## Supervision and intervention

Use `wait_threads` to await completion or attention, at most eight thread IDs per call,
with returned cursors to avoid replaying old reports. Use bounded waits and rotate across
batches so one batch does not hide another. `read_thread` supplies progress and recent output;
`list_threads` is discovery and recovery. A completed turn is not a merged issue: verify the
PR state, issue state, commits and tests externally and continue unfinished work in that thread.

Use `send_message_to_thread` with the recorded thread/host IDs to give corrections, request
progress, continue a finished turn or request the final hand-back. Send a clear human-readable
prompt, preserving model settings unless the user directed a change. Do not use CLI resume,
`codex queue`, tmux kills, or `fleet-worker.sh unstick` on an app thread. Observe the response;
a sent message alone does not prove an active task stopped or obeyed it.

For stalls, compare native status/output over a task-appropriate interval with git, process
and PR evidence. Quiet output during a long test is not a failure. Retry a failed capacity
turn in the same thread with a disk-first note after confirming it ended. After two failed
interventions, establish the old worker is stopped and its child processes cannot write
before any takeover. If the available native controls cannot establish that, leave takeover
gated and report the blocker. Never start a second writer or switch runtimes to bypass a
permission or policy block. A finisher's brief names the inherited branch, commits and PR;
request the original worker's brainstorm in the original thread when it remains usable.

For a regression, set the anchor halt and tell native workers through
`send_message_to_thread`; also follow the shared PR/integration protocol in SKILL.md.
Every new native dispatch must pass `gate` even though the app itself does not know the halt.

For a wave that needs supervision beyond the current turn, use the available native heartbeat
/ automation tool when the user's request authorizes ongoing monitoring. Save the board
location, identities and recovery instructions in its prompt; notify only on meaningful
change or required action. A waiter or message does not itself schedule a later wakeup. Do not
apply Claude Desktop's `/loop`, `ScheduleWakeup` or pause timing to the Codex app.

## Close-out

Collect the structured hand-back through `read_thread` (request it in the same thread if
missing), verify merge and issue closure externally, and consolidate proposals as SKILL.md
requires. Confirm no worker or its child processes can still write before cleanup. Keep the
thread and its app-managed worktree through hand-back and any interventions. Do not apply the
CLI worktree-removal recipe to an app-managed worktree; use a documented app cleanup control
when available, otherwise retain it and record that fact. Archiving a thread is not evidence
that its worktree was removed. Release the fleet lease only after both native and CLI boards
are reconciled and the wave report is durable.

The [official worktree documentation](https://learn.chatgpt.com/docs/environments/git-worktrees)
explains app-managed worktree isolation. The available app tool schemas are the authority for
creation, pending IDs, placement and control; do not infer extra parameters from the CLI.
