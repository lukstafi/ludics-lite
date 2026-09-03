# Routines

The prompts behind the scheduled runs that feed the skills: the daily plan `issue-wave` reads,
the sweeps that keep OCANNL's non-CI backends and formatting honest, and the CI-red triage that
`ship-pr` hands master's trailing failures to. Each directory holds one `SKILL.md` in the shape
Claude Code's scheduled tasks use: a `name` and `description` in the frontmatter, then the prompt.

Two kinds live here, and they are kept in sync differently.

| Routine | Kind | Fires | Runs in | Model | Feeds |
| --- | --- | --- | --- | --- | --- |
| `ocannl-format-sweep` | local scheduled task | daily 06:43 local (`43 6 * * *`) | `~/ocannl-staging` | Opus | `tools/format-sweep.sh` in OCANNL |
| `ocannl-cross-machine-sweep` | local scheduled task | daily 07:20 local (`20 7 * * *`) | `~/ocannl-staging` | Opus | `tools/sweep.sh` in OCANNL, `~/bin/wake-lab.sh` |
| `daily-issue-planning` | local scheduled task | daily 07:05 local (`5 7 * * *`) | `~/ocannl-staging` | Fable | the sequencing plan `issue-wave` reads |
| `ocannl-ci-red-triage` | cloud routine | on any non-PR master red, fired by `ci.yml`; backstop daily 05:17 UTC (`17 5 * * *`) | Anthropic cloud, sources `lukstafi/ocannl-staging` and `ahrefs/ocannl` | Sonnet | the claiming issues `ship-pr` defers to |

The local scheduler adds a per-task jitter of a few minutes to the times above. Cron in the
local registry is the box's local time; the cloud routine's cron is UTC.

The two sweeps share `~/ocannl-staging`, which is fine because the cross-machine sweep never
modifies the tree, but the format sweep runs the full test suite for about 30 minutes when it
proceeds, and the cross-machine sweep's local units would contend with it. Hence the gap:
the cross-machine sweep starts last, after the planning run, which is light.

## Local scheduled tasks: symlinks, like the skills

A local scheduled task is two things: the prompt, at `~/.claude/scheduled-tasks/<id>/SKILL.md`,
and a registry entry in the desktop app (cron expression, working directory, model, enabled) that
names that file by path. The registry is not a file to edit by hand and is not in this repository;
the table above records its values so a task can be re-registered elsewhere.

The scheduler does not list the `scheduled-tasks` directory, it reads each registered task's file
by its path (verified 2026-09-03: an unregistered directory symlinked in is not listed). That is
exactly what makes the skills' symlink trick work here too. Symlink each task's directory, never
the `scheduled-tasks` directory itself: the registry path is unchanged, resolves through the link,
and an edit made mid-run lands in this checkout as a normal `git status`.

On a fresh box, register the task first (the `schedule` tool in the desktop app, with the cron,
working directory and model from the table; it writes a placeholder `SKILL.md`), then replace the
directory it created with the link:

```sh
mkdir -p "$HOME/.claude/scheduled-tasks"
for r in daily-issue-planning ocannl-cross-machine-sweep ocannl-format-sweep; do
  d="$HOME/.claude/scheduled-tasks/$r"
  if [ -d "$d" ] && [ ! -L "$d" ]; then
    echo "$d is a real directory: diff it against routines/$r, move it aside, rerun" >&2
    continue
  fi
  ln -sfn "$HOME/ludics-lite/routines/$r" "$d"
done
```

The guard matters: `ln -sfn` onto a real directory creates the link inside it instead of replacing
it. A pre-existing directory may also carry a local edit worth keeping, hence the diff first.

Only the box running the desktop app's scheduler fires these. On the author's fleet that is
`mac-studio`, which is why all three run in that box's `~/ocannl-staging`.

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
names `rog`/`minix` (`rog-nv-wsl`, `minix-amd-wsl`) in the two sweeps; the two OCANNL
repositories in the triage routine. The OCANNL scripts they drive (`tools/format-sweep.sh`,
`tools/sweep.sh`, `tools/aggregate-skips.sh`) live in that repository, and the outcome strings
the prompts teach the agent to read are those scripts' messages, so a change to a script's
wording is a change to its routine.
