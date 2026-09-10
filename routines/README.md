# Routines

The prompts behind the scheduled runs that feed the skills: the daily plan `issue-wave` reads,
the sweep that keeps OCANNL's non-CI backends honest, and the CI-red triage that
`ship-pr` hands master's trailing failures to. Each directory holds one `SKILL.md` in the shape
Claude Code's scheduled tasks use: a `name` and `description` in the frontmatter, then the prompt.
CI's prompt hygiene job (`scripts/check-prompts.sh`) checks that shape, that `name` matches the
directory, and that each of these directories is named, in backticks, in the first cell of a row
of the table below.

Two kinds live here, and they are kept in sync differently.

| Routine | Kind | Fires | Runs in | Model | Feeds |
| --- | --- | --- | --- | --- | --- |
| `ocannl-cross-machine-sweep` | local scheduled task | daily 07:20 local (`20 7 * * *`) | `~/ocannl-staging` | Opus | `tools/sweep.sh` in OCANNL, `scripts/wake-lab.sh` |
| `daily-issue-planning` | local scheduled task | daily 07:05 local (`5 7 * * *`) | `~/ocannl-staging` | Fable | the sequencing plan `issue-wave` reads |
| `ocannl-ci-red-triage` | cloud routine | on any non-PR master red, fired by `ci.yml`; backstop daily 05:17 UTC (`17 5 * * *`) | Anthropic cloud, sources `lukstafi/ocannl-staging` and `ahrefs/ocannl` | Sonnet | the claiming issues `ship-pr` defers to |

The local scheduler adds a per-task jitter of a few minutes to the times above. Cron in the
local registry is the box's local time; the cloud routine's cron is UTC.

The cross-machine sweep starts after the planning run, which is light, so the two never contend
for `~/ocannl-staging`. (A daily formatting sweep used to run first; OCANNL formats per PR now,
through a CI gate, and the routine is retired.)

## Local scheduled tasks: copies, kept in sync by a script

A local scheduled task is two things: the prompt, at `~/.claude/scheduled-tasks/<id>/SKILL.md`,
and a registry entry in the desktop app (cron expression, working directory, model, enabled) that
names that file by path. The registry is not a file to edit by hand and is not in this repository;
the table above records its values so a task can be re-registered elsewhere.

The prompt directories must hold REAL files. Symlinking them, the way `~/.claude/skills/*` still
is, worked until desktop app 1.46388.4 (2026-09-06), which hardened the task-file reader to refuse
any path traversing a symlink. The failure is quiet: the task fires on time and is dispatched, the
prompt cannot be read, no session starts, and ten minutes later the dispatch is cleared as stale --
stamping `lastRunAt`, so the registry and the task list still look like it ran. Two symptoms give it
away: `Failed to read task file for <id>: symlink detected before open` followed by
`Cleared stale pending dispatch` in `~/Library/Logs/Claude/main.log` (a healthy run logs
`Confirmed task run for: <id>` instead), and an empty `description` for every task in the list,
because that too is read from the frontmatter of the file it will not open.

So this checkout stays canonical and `scripts/sync-routines.sh` copies between the two:

```sh
scripts/sync-routines.sh        # status: report drift, exit 1 if any
scripts/sync-routines.sh push   # this checkout -> ~/.claude/scheduled-tasks
scripts/sync-routines.sh pull   # ~/.claude/scheduled-tasks -> this checkout, then commit
```

`push` also converts a directory left over from the symlink era. Edit a prompt here and `push`; if
an edit lands in the installed copy instead -- a routine's own run editing its prompt in place --
`pull` it back and commit, rather than letting the two drift. `status` exits 1 on any drift, which
is what makes it worth running after a merge that touched a prompt.

The script is unforgiving about symlinks in three places, because the scheduler is. When either
end is reached through a link at an ancestor, the directories under it are each real while the
link is doing the damage. The rule is the filesystem's: publishing through a symlinked ancestor is
refused, since it writes into the link's target and leaves the link standing, while reading
through one is only warned about. So a symlinked `~/.claude/scheduled-tasks` refuses a `push` and
lets a `pull` through (the files behind it are real, and taking them is the recovery); a
symlinked `routines/` in this checkout refuses a `pull` and lets a `push` through. `status`
reports the destination one, because the scheduler will not open a task file whose path traverses
a link however the sync went. It refuses an
installed directory holding a link anywhere inside it, a linked `SKILL.md` included, which a plain
`diff -r` would follow and call in sync. And `push` replaces a link rather than writing through
it. It also refuses to `pull` from an installed directory with no `SKILL.md` —
that is a leftover, not a routine, and taking it would delete the tracked prompt here. In the
other direction `pull` is the repair, and reads on past a checkout prompt that is broken in any of
those ways, a deleted routine directory and one linked out of the tree included: it restores them
from a usable installed copy. `push`
publishes file by file, staging each inside the destination and renaming it onto its final name,
so a dispatch that lands mid-push always finds a whole prompt: never a missing one, never a
half-written one. It replaces whatever stands in a file's way rather than following or entering it,
checks every step, and reads the result before reporting a routine published — not that a
`SKILL.md` is there, which a failed copy leaves standing, but that the destination now holds what
the source holds.

The script only touches the rows above whose Kind is `local scheduled task`, never the cloud
routine below, and its `LOCAL_ROUTINES` list is exactly those rows -- pinned by
`scripts/test-sync-routines.sh`, so adding a local scheduled task means editing both the table and
that list, and CI says so if only one of them changes.

On a fresh box, register the task first (the `schedule` tool in the desktop app, with the cron,
working directory and model from the table; it writes a placeholder `SKILL.md`), then `push` over
it. Registration and prompt are independent in both directions, and the script can see only one of
them: the registry is the desktop app's, so a missing prompt directory is no evidence the task is
unregistered (a prompt directory deleted under a live registry entry looks exactly the same), and
`push` says to check the app's task list rather than telling you what it found there.

Only the box running the desktop app's scheduler fires these. On the author's fleet that is
`mac-studio`, which is why both run in that box's `~/ocannl-staging`.

Retiring a routine is three steps, and the registry is the one the repository cannot do: delete
its directory here and its row above, then deregister the task in the desktop app, then remove
`~/.claude/scheduled-tasks/<id>`. The first step alone retires nothing on a box that already has
the task — the installed prompt stays, and so does the registry entry naming it by path, which
keeps firing. Because the script iterates the list above rather than the destination, a leftover
like that would be invisible, so a retired name goes into `RETIRED_ROUTINES` in
`scripts/sync-routines.sh` as a tombstone: the script then looks for it by name and says, in every
mode, that it is still installed and what the two remaining steps are. It removes nothing itself —
a prompt deleted while its registry entry stands makes the task fire and fail rather than stop.
The check is for a name that is present OR is a dangling link: a box installed by the old loop has
the task directory symlinked into this checkout, and deleting the target here leaves exactly that,
which a plain existence test calls absent. Drop the tombstone once the fleet is known to be clean.
`ocannl-format-sweep` is the one carried today.

## The cloud routine: synced by hand

`ocannl-ci-red-triage/SKILL.md` is a copy of the prompt of the "ocannl-staging CI-red triage"
routine at claude.ai/code/routines; the cloud holds the live copy and nothing links them. Its
body is the prompt verbatim, so it can be diffed against the cloud copy. To change it, edit here,
land the change, then push the new body to the routine through the `schedule` skill's update
action, diffing the live prompt against the previous version of this file first in case someone
edited it in the web UI.

Its non-prompt configuration, for re-creating it:

| Setting | Value |
| --- | --- |
| Environment | "Full access" (`anthropic_cloud`) |
| Sources | `https://github.com/lukstafi/ocannl-staging`, `https://github.com/ahrefs/ocannl` |
| Allowed tools | `Bash`, `Read`, `Write`, `Edit`, `Glob`, `Grep` (the GitHub MCP tools load through `ToolSearch` regardless) |
| MCP | `Claude_Code_Remote` (`https://api.anthropic.com/v1/code/mcp/meta`) |
| Fire API | `ci.yml`'s `notify-triage-routine` job, with the `ROUTINE_FIRE_URL` and `ROUTINE_FIRE_TOKEN` repository secrets |
| Notifications | none; findings reach people as issues on `ahrefs/ocannl` |

## Site configuration

Like the skills, these prompts name the author's setup in prose and are edited in place:
`~/self-improve/ClaudeDesktop/sequencing_plan.md` and the repository list in
`daily-issue-planning`; `~/ocannl-staging`, `~/.ocannl-sweep`, `~/bin/wake-lab.sh` and the box
names `rog`/`minix` (`rog-nv-wsl`, `minix-amd-wsl`) in the cross-machine sweep; the two OCANNL
repositories in the triage routine. `~/bin/wake-lab.sh` is a symlink to `scripts/wake-lab.sh` in
this checkout, so the cross-machine sweep's lab lore is reviewable here rather than living only on
`mac-studio` (ludics-lite#31); the fleet's MAC and IP addresses are the one part that stays out of
the repository, in the untracked `~/.config/wake-lab/hosts.sh` the script refuses to run without.
Both are installed by the "The lab script" section of the top-level README.

The OCANNL scripts they drive (`tools/sweep.sh`, `tools/aggregate-skips.sh`) live in that repository, and the outcome strings
the prompts teach the agent to read are those scripts' messages, so a change to a script's
wording is a change to its routine.
