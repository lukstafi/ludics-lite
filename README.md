# ludics-lite

A small collection of agent skills for landing work through review and running
delegation waves over an issue backlog across a fleet of machines. They are the lightweight,
skill-only companion to [ludics](https://github.com/lukstafi/ludics): no binary, no daemon,
just Markdown and shell loaded by compatible agent harnesses from their skill directories.

| Skill | What it does |
| --- | --- |
| `ship-pr` | Land finished work: decide between a direct push and a PR, then carry the PR through automated review to merge, with a watcher that survives reviewer delays. |
| `wait-and-proceed` | Block a task behind another branch or PR until it lands, then continue. |
| `after-merge` | Right after a merge, brainstorm what the experience suggests about the codebase and route each idea to an issue, a task chip, or the bin. |
| `issue-wave` | Run one coordinator over the whole fleet: pick issues from a sequencing plan, launch one worker per issue in its own worktree on a chosen box, and supervise the wave to full merge. |

The `routines/` directory holds the prompts of the scheduled runs that feed these skills: the
daily sequencing plan `issue-wave` reads, the OCANNL test and formatting sweeps, and the CI-red
triage cloud routine. See [routines/README.md](routines/README.md).

The skills were extracted from a private repository with their full history. Its issues were
cloned here and the references in the skills renumbered to `ludics-lite#N`; the few remaining
`self-improve#N` references, and the ones in older commit messages, are that repository's pull
requests, which were not cloned. They are kept as provenance.

## Installing

Clone the repository and symlink each skill into `~/.claude/skills`. Symlinks rather than copies
mean a skill edited mid-session lands in this working tree and shows up as a normal `git status`,
so there is no separate sync step to forget.

```sh
git clone https://github.com/lukstafi/ludics-lite.git ~/ludics-lite
mkdir -p "$HOME/.claude/skills"
for s in "$HOME"/ludics-lite/*/; do
  case "$s" in */.git/|*/routines/|*/scripts/) continue ;; esac
  ln -sfn "${s%/}" "$HOME/.claude/skills/$(basename "$s")"
done
```

The loop skips `routines/`, whose contents are scheduled-task prompts rather than skills, and
`scripts/`, which holds the lab script; both are linked separately, see the Routines and Lab
script sections. Rerun the loop after adding a skill. Replace any pre-existing real directory in
`~/.claude/skills/` by hand first, and diff it against this copy, since a divergent local edit
may be a fix worth keeping.

These loops are executed, not just quoted: the fleet launcher's test suite extracts them from
this README, runs them against a scratch clone of the checkout, and preflights the result, so a
loop that stops matching the layout the preflight expects fails the suite.

Keep these `~/.claude/skills` links even on a Codex-only box: command examples use them as the
canonical script paths. The `~/.codex/skills` links below are additionally required for Codex to
discover the skills.

On a machine that runs Codex workers (see the Codex workers section of `issue-wave/SKILL.md`),
also link the skills Codex uses into `~/.codex/skills`. The issue-wave coordinator's per-launch
preflight (`issue-wave/scripts/fleet-worker.sh preflight <box> --codex`) refuses to launch a
Codex worker on a box where these links are missing:

```sh
mkdir -p "$HOME/.codex/skills"
for s in ship-pr wait-and-proceed after-merge; do
  ln -sfn "$HOME/ludics-lite/$s" "$HOME/.codex/skills/$s"
done
```

A box that runs the `issue-wave` coordinator itself under Codex needs that skill discoverable too:

```sh
mkdir -p "$HOME/.codex/skills"
ln -sfn "$HOME/ludics-lite/issue-wave" "$HOME/.codex/skills/issue-wave"
```

## Fleet configuration

`issue-wave` assumes a fleet of boxes reachable over ssh, with one anchor box that holds the
lease and halt files. Every site-specific value is an environment variable read by
`issue-wave/scripts/fleet-worker.sh`; the header comment of that script is the authoritative
list. The ones you will need to set for your own fleet:

| Variable | Meaning |
| --- | --- |
| `FLEET_BOXES` | Space-separated fleet box names. |
| `FLEET_ANCHOR` | The box where the lease and halt files live. |
| `FLEET_LOCAL_BOX` | This box's fleet name, if hostname detection does not recognise it. |
| `FLEET_HOSTNAME_MAP` | How hostname detection reads: space-separated `<glob>=<box>` pairs, first match wins. |
| `FLEET_BASE_REF` | The ref a worker's worktree starts from when a launch names no `--base` (`origin/master` by default). |
| `FLEET_SKILLS_REPO` | Path of this checkout on each box, `~/ludics-lite` by default (the preflight fast-forwards it). |
| `FLEET_FLOTILLA` | URL of the flotilla status service, if you run one. |
| `ISSUE_WAVE_STATE` | Local state directory for each coordinator. |
| `FLEET_ANCHOR_STATE` | State directory on the anchor for the lease and fleet-wide halt; every coordinator must resolve it to the same directory there. |

The defaults encode the author's fleet and will not work anywhere else. The prose of
`issue-wave/SKILL.md` names that fleet too, along with a daily sequencing plan file and the
project the waves run over; its opening "Site configuration" section lists what to edit.

`ship-pr` assumes the [Codex](https://github.com/openai/codex) GitHub app reviews every PR: its
watch waits for that reviewer's rounds and its 👍 reaction is the approval gate. Without it, the
watch reports that no review is coming and the merge gate has only the build signal to read.

Before every launch the preflight fast-forwards the target box's checkout of this repository to
upstream main and refuses on a dirty or diverged checkout. That pull-side step is what
propagates merged skill edits to boxes that slept through the merge. A headless worker also
needs the box's CLI logged in: `claude auth login` for Claude workers (an expired OAuth session
cannot refresh headless, and `claude auth status` does not notice) and `codex login` for Codex
ones. The preflight proves both with a live call, not a status read.

## Routines

`routines/` carries the scheduled-task prompts the same way the skill directories carry skills,
and three of the four install the same way: each task directory under `~/.claude/scheduled-tasks`
replaced by a symlink into this checkout, so an edit made during a run lands here. The desktop
app's registry (cron, working directory, model) is not in the repository and is recorded in
[routines/README.md](routines/README.md), which also carries the install loop with its guard
against linking into a real directory. The fourth, the CI-red triage routine `ship-pr` defers
master's trailing failures to, runs in the cloud and is synced by hand.

## The lab script

`scripts/wake-lab.sh` drives the home-lab boxes' power state: wake-on-LAN over the router's TR-064
interface and as a direct magic packet, sleep/hibernate/shutdown, a WSL kick, and a per-box
reachability table. The cross-machine sweep routine calls it to wake the GPU boxes before testing
them. It installs the way the skills do, as a symlink, so an edit made mid-run lands in this
checkout as a normal `git status` (ludics-lite#31):

```sh
mkdir -p "$HOME/bin"
ln -sfn "$HOME/ludics-lite/scripts/wake-lab.sh" "$HOME/bin/wake-lab.sh"
```

The fleet's MAC and LAN IP addresses are the one part that is not tracked. They live in a file the
script sources at startup and refuses to run without, so a box that has not been configured says
so instead of reporting every machine as unknown:

```sh
mkdir -p "$HOME/.config/wake-lab"
cp "$HOME/ludics-lite/scripts/wake-lab-hosts.example.sh" "$HOME/.config/wake-lab/hosts.sh"
chmod 600 "$HOME/.config/wake-lab/hosts.sh"   # then fill in mac_of, eth_mac_of and ip_of
```

`WAKE_LAB_HOSTS` overrides that path. Everything else stays here and reviewable: the verified lab
lore in the header comment (wake-on-LAN over Ethernet only, waking from a full shutdown, what
`link=1` means, the cold-boot kicked-VM trap, the `exit 0` vs `true` probe trap), the router
endpoints, the ssh aliases and all of the logic. `wake-lab.sh --help` prints that header, and
`--help` and `--list` are the two commands that work before the host table exists. The box names
(`rog`, `minix`, `asus`) and the ssh aliases are the author's and are edited in place.

## Tests

The shell scripts carry their own test suites:

```sh
issue-wave/scripts/test-fleet-worker.sh
ship-pr/scripts/test-post-merge-cleanup.sh
ship-pr/scripts/test-pr-review-base-drift.sh
scripts/test-wake-lab.sh
```

The GitHub Actions workflow in `.github/workflows/skill-scripts.yml` runs all four on Ubuntu and
macOS (the fleet's bash is 3.2) for every push and pull request, along with `bash -n`, shellcheck
at error severity, and a check that the two cleanup scripts still carry their parse guard. It runs
without path filters, so every PR's merge gate reads a verdict rather than `ABSENT`.

`test-fleet-worker.sh` runs its ~180 assertions top to bottom in one shell, which takes about three
and a half minutes. Arguments narrow that: each one selects every section whose name contains it
(`test-fleet-worker.sh unstick`, `test-fleet-worker.sh 'real checkout'`), `--list` prints the
section names, and an argument matching none of them is refused before anything runs. The setup the
sections share (the shim CLIs, the scratch skills checkout, the scratch project repo) runs whatever
is selected, and a section that needs more than that, such as the coordinator lease or a finished
worker to read, takes it itself, so every section also passes when it is the only one selected.

`test-wake-lab.sh` runs the lab script against shim `curl`, `python3` and `ssh` on PATH, so it
touches neither the router nor the network. It pins the split above from both sides: that every
MAC the script sends comes from the sourced host table and that a missing or incomplete one is
refused before any router traffic, and that no MAC-shaped literal is tracked anywhere in the
repository (with a negative control, since a scan that cannot fail would prove nothing). It also
pins `--help` to the whole header comment, which was a hard-coded line range that truncated
silently whenever the header grew.

`test-post-merge-cleanup.sh` runs its cases concurrently, each in its own process group with a
deadline (`SHIP_PR_TEST_CASE_TIMEOUT`, five minutes by default): a stalled case is killed and
reported instead of holding the job until CI's own timeout. `SHIP_PR_TEST_LOG_DIR` keeps the
per-case logs where CI can collect them. The runner also tests itself, from patched scratch copies:
refused arguments, `--help` with an inherited pid list, the deadline, and an in-place rewrite of
both scripts mid-run (with a negative control that strips the parse guard).

## Why symlinks, not copies

Copies drift silently, and did: the `ship-pr` watcher was independently repaired on a second
machine against a base that had already grown a better fix, so the repair both duplicated work
and sat on top of a copy missing later improvements. Symlinks make one tree the only tree.

## License

MIT, see [LICENSE](LICENSE).
