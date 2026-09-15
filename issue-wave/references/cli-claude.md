# Claude Code coordinator, CLI workers

A CLI worker is a headless `claude -p` or `codex exec` turn in a detached tmux session on a
fleet box, launched and supervised through `fleet-worker.sh` by a coordinator that can be
either provider - this file is written for a Claude Code coordinator, and its workers can be
Claude or Codex invocations (`--kind claude` / `--kind codex`); the shared issue requirements
of the brief, the base gate and the preflight are in SKILL.md, and the reservation handoff for a
worker that cannot message the coordinator is [executions.md](executions.md#cli-reservation-handoff).

## Launch

CLI workers use `~/.claude/skills/issue-wave/scripts/fleet-worker.sh`. Each is a detached
tmux session on its agent box running the selected `claude` or `codex` CLI, with the brief on stdin
and events, stderr, exit code and session id under `~/.local/state/issue-wave/workers/<name>/`.
Detached CLI workers run without permission prompts: retain the triage screen of the full
issue body and comments before launch. Issues with untrusted outside participation are
deferred or handled under ordinary permission controls, not dispatched unscreened.

Write the brief to a file and launch with the selected kind
(`--kind claude` with `-- --model opus --effort high` for requested Opus, or `--kind codex`
with the user's supported Codex model flags):

```bash
fleet-worker.sh launch <box> <repo>-<issue> --target-repo <owner/repo> --kind claude --brief <brief-file> \
  --repo '~/<project checkout>' --branch claude/<topic> [-- <model flags>]
fleet-worker.sh attach <box> <repo>-<issue>     # Bash run_in_background: the wake signal
```

`launch` creates `<checkout>-worktrees/<name>` off `origin/master` on the box (`FLEET_BASE_REF`
for another default, `--base` for one launch, `--cwd` for a worktree that already exists) and
prints the session id that addresses every later intervention. `attach` blocks until the worker's session exits and prints
one verdict line (`DONE` / `FAILED` / `VANISHED`), riding out ssh drops and box naps by
retrying from the coordinator's side; run it as a harness-tracked background task, one per
worker, and its completion notification is the wake signal - exactly the wait-and-proceed
shape. Native subagents use their runtime wait mechanism instead; do not assume they or their
child processes survive a coordinator interruption. Detached CLI workers continue independently.

## Intervening

- **CLI workers: unstick through the script, and only a dead exec.** Write the imperative
  message to a file (do X now, in this turn, do not yield; never as command-line text - issue prose is
  full of backticks and `$()`) and run `fleet-worker.sh unstick <box> <name> --message
  <file>`. It resumes the recorded session in a fresh detached turn - full context retained,
  same worktree (resume has no `-C`; the script `cd`s first) - and REFUSES while the exec is
  alive, because a resume beside a live exec gives the branch two writers, one of them
  possibly a finisher mid-rebase, and a quiet stream does not prove the exec cannot still act.
  For a live-but-stuck worker pass `--kill`: the script stops the tmux session, waits for the
  CLI process to be gone, then resumes. Do NOT reach for `codex queue --thread <id>
  --message` for an exec worker: an entire `codex exec` run is ONE turn and queued messages
  deliver only at a turn boundary - the message sits undelivered while the worker keeps doing
  the thing you queued it to stop (2026-08-30: a tip-chasing worker ran 50 more minutes past
  its queued stop). Escalation is two failed interventions, then the coordinator takes over
  the mechanical remainder or spawns a Claude finisher on the worktree's branch - after
  `status` shows the stalled session gone. A finisher landing a stalled worker's branch does
  not inherit its transcript, so after the merge `unstick` the ORIGINAL session (post-exit, no
  `--kill` needed) with the hand-back brainstorm prompt - the friction that grounds
  `after-merge` is in that session, on that box, and removal-comes-last has kept its worktree
  alive; only if the session is unresumable does the coordinator brainstorm from the diff and
  say so.
- **CLI model-capacity errors end execs; resume the recorded session.** A CLI worker whose
  `attach` line reads `FAILED ... turn.failed ... "Selected model is at capacity"` (or a Claude worker's
  `is_error=true` on a provider error) is terminal for that turn, not for the session. The
  work is durable (briefs mandate early commits): `unstick` with a disk-first note (trust
  `git log`/`git status` and the PR state over the session's memory; re-run anything whose
  result is not in a file) recovered 2/2 cleanly on 2026-08-30. Expect kills to cluster
  (capacity is global); resume victims as their `attach` notifications arrive.
