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
daily sequencing plan `issue-wave` reads, the OCANNL test sweep, and the CI-red
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
`scripts/`, which holds the lab script; both are installed separately, see the Routines and Lab
script sections. Rerun the loop after adding a skill. Replace any pre-existing real directory in
`~/.claude/skills/` by hand first, and diff it against this copy, since a divergent local edit
may be a fix worth keeping.

These loops are executed, not just quoted: the fleet launcher's test suite extracts them from
this README, runs them against a scratch clone of the checkout, and preflights the result, so a
loop that stops matching the layout the preflight expects fails the suite.

Keep these `~/.claude/skills` links even on a Codex-only box: command examples use them as the
canonical script paths. The `~/.codex/skills` links below are additionally required for Codex to
discover the skills.

On a machine that runs Codex workers (see the Native workers section of `issue-wave/SKILL.md`),
also link the skills Codex uses into `~/.codex/skills`. The issue-wave coordinator's per-launch
preflight (`issue-wave/scripts/fleet-worker.sh preflight <box> --native-codex`) refuses to launch a
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

An optional [stop nudge](ship-pr/hooks/README.md) works with Claude Code and Codex to
remind a session to consider landing finished work. It requires a separate hook
registration and deliberately stays quiet during common exploratory workflows.

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
CLI ones. The CLI preflight proves both with a live call, not a status read.
Provider/model, launch transport and execution placement are separate choices. Both Codex and
Claude Code support their own native subagents in coordinator-created external worktrees, or
CLI workers launched with `--kind codex` or `--kind claude`. Only the CLI route provides
cross-provider delegation, and it can place the agent directly on the best iteration box.
Native workers use their runtime tools and a shared anchor board; CLI workers use the launcher's
tracked process lifecycle. See [Native workers](issue-wave/references/native-workers.md) for placement and
recovery, [native-claude.md](issue-wave/references/native-claude.md) / [native-codex.md](issue-wave/references/native-codex.md)
for each coordinator's worker channel and tool discovery, [cli-claude.md](issue-wave/references/cli-claude.md)
for the CLI worker lifecycle, and the explicit separate-conversation alternative.
[Execution reservations](issue-wave/references/executions.md) apply to fleet test/experiment runs
for either transport, including host-local CLI work, and coordinator integration. Agent residence
does not confer ownership, and an issue may reserve checks on several boxes. Measurement is
exclusive per box; correctness runs share a box up to its `FLEET_BOX_CORRECTNESS_SLOTS` (six on
mac-studio), a run-time count a worker takes around each batch with `execution slot -- <batch>`,
so a standing iteration record gates no agent's start (ludics-lite#160). The
usual coordinator shape is two calls per execution: `execution run <reserve.json>` (reserve and
dispatch) and `execution conclude --from-run <run-dir> --request <id> --sha <sha>` (verdict, log and
checkout read off a `test-run.sh` record on the reserved box). The reservation helper requires Python 3 on the anchor, and `execution slot` requires it on every
box that runs batches (the per-box preflight checks it).

## Routines

`routines/` carries the scheduled-task prompts, but not the way the skill directories carry
skills: since desktop app 1.46388.4 the scheduler refuses a task file reached through a symlink,
so the two local ones install as copies under `~/.claude/scheduled-tasks`, pushed and pulled by
`scripts/sync-routines.sh` (`status` after a merge that touched a prompt, `push` to install it).
The desktop app's registry (cron, working directory, model) is not in the repository and is
recorded in [routines/README.md](routines/README.md), which also carries the install order and the
symptoms of an unreadable prompt. That push is manual and is part of landing any PR that
touches a prompt — merging moves this checkout, never the scheduler's copy — so after such a merge,
on `mac-studio`, through the chained recipe in [routines/README.md](routines/README.md): put the
checkout on `main`, prove it is level with `origin/main` and clean where it matters — only such a
checkout may be installed from, since `push` installs whatever it holds — then
`scripts/sync-routines.sh` to read the direction, and `push`, or `pull` on the rarer drift whose
newer text is the installed copy. Forgetting it is silent (the routine keeps firing the old prompt and its
record looks normal), so both live prompts open by running `scripts/sync-routines.sh` and reporting
their own drift, and `daily-issue-planning` reports every routine's verdict once a day
(ludics-lite#199). The third, the CI-red triage routine `ship-pr` defers master's
trailing failures to, runs in the cloud and is synced by hand.

## The lab script

`scripts/wake-lab.sh` drives the home-lab boxes' power state: wake-on-LAN over the router's TR-064
interface and as a direct magic packet, sleep/hibernate/shutdown, a WSL kick or restart, and a per-box
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

The WSL boxes are shared, and `wsl.exe --shutdown` is host-global — it destroys the whole VM, so
every session on that box dies with it. Anything that uses a box for a while therefore reserves it,
with an `flock` under `~/.local/state/wake-lab/` (`WAKE_LAB_LOCK_DIR` overrides the directory).
There are two locks per box, because "in use" is two different claims:

- `<box>.lock`, the **lane** lock — "no other lane runs on this box". A harness that is about to
  work on a box takes this one, for as long as it is working; `wake-lab.sh lock-path <box>`
  answers its path. The contract is only the path and a one-line holder description, so the
  reserving tool needs nothing installed from here.
- `<box>.hold.lock`, the **hold** lock — "this box's VM must not be destroyed". `--hold` takes it
  and the Windows-side holder carries it until `unhold`.

The holder itself is `wsl.exe -d Ubuntu -e sh -s <token>`: a shell reading its commands off the ssh
channel. It ends when that channel does, which is not something sshd can be relied on to arrange —
on Windows it exits without reaping the command tree, so a holder that never read its stdin was
orphaned by every `unhold`, one `cmd.exe` and two `wsl.exe` per lane (ludics-lite#192). The token
is this lane's identity: `--hold` declares the VM up only once the holder has said that token back
from inside the guest, which no `tasklist` reading can substitute for (both lab boxes already show
a `wsl.exe` with nothing of ours running), and `unhold` uses it to ask the VM whether that exact
guest shell is gone before it claims anything. `unhold` exits 2 when the holder had already died
under the lane — its results are suspect — and 3 when it could not leave the box demonstrably
free: a holder of ours survived both its channel and a kill by pid, or the box never answered. An
unverified release keeps its record, because the guest pid and token in it are the only things a
later `unhold` could finish the job with; run it again when the box answers.

`restart-wsl` and the power verbs take **both** and refuse the box if either is held, until the
holder lets go or `--force` takes it anyway. The OCANNL cross-machine sweep reserves each box's
lane lock for the length of its lane — on 2026-09-16, before any of this existed, a restart issued
mid-sweep destroyed both GPU boxes' VMs and cost that run both GPU units. The split into two locks
came later, on 2026-09-18: while one lock said both things, the sweep routine's own `--hold` in
step 1 reserved the boxes against its own sweep in step 2, and three backends went uncovered.

That interlock spans two repositories with nothing enforcing it: the sweep takes the lane lock
itself and neither side reads anything from the other, so four facts stay equal by hand — the
directory, the `<box>.lock` name, the box name the sweep derives from an ssh alias, and a negative
one, that the sweep must never take or honour the **hold** lock. The first three fail open (the two
sides quietly stop meeting and the interlock is gone) and the fourth fails closed (a held box can
no longer sweep itself). `test-wake-lab.sh` compares all four against the sweep's own code. It
reads the revision the sweep routine actually runs — `origin/master` of
`${OCANNL_STAGING:-$HOME/ocannl-staging}`, since that checkout is often on a WIP branch — and it
runs the sweep's own `take_lab_lock` under a HOME of its own rather than rebuilding the path,
so the comparison is against the lock file that really appears. It then holds each side's real
lock and checks the other side's real behaviour, since a lock file without a live `flock` stops
nothing: a restart is refused while the sweep's own `take_lab_lock` holds the box, and the sweep
still takes its lane lock while that box's hold lock is held. The checkout is read strictly
read-only. Where it is absent, as in CI, the case prints a named `SKIP:` line that the summary
counts, so a green run says what it did not check. The staging side has no matching check.

`WAKE_LAB_HOSTS` overrides that path. Everything else stays here and reviewable: the verified lab
lore in the header comment (wake-on-LAN over Ethernet only, waking from a full shutdown, what
`router-active=1` means, the cold-boot kicked-VM trap, the `exit 0` vs `true` probe trap), the router
endpoints, the ssh aliases and all of the logic. `wake-lab.sh --help` prints that header, and
`--help` and `--list` are the two commands that work before the host table exists. The box names
(`rog`, `minix`, `asus`) and the ssh aliases are the author's and are edited in place.

To repair the Windows-side NIC settings, copy `scripts/enable-wol-windows.ps1` to the Windows box
and run it from an elevated PowerShell (`powershell -ExecutionPolicy Bypass -File
.\enable-wol-windows.ps1`); BIOS/UEFI Wake-on-LAN still has to be enabled separately.
`scripts/enable-active-hours-windows.ps1` is its counterpart for the other way an unattended lane
loses a box: it writes back the Windows Update active hours (`ActiveHoursStart=6`,
`ActiveHoursEnd=0` — the 18-hour maximum — and `SmartActiveHoursState=0`, or a `-Start` / `-End`
pair of your own, refusing a span Windows cannot mean rather than writing it), printing the values
before and after. Nothing re-applies those, and a feature update can reset them, which is what
`wake-lab.sh status` warns about; this is the one-step repair for that warning.

## Tests

**Before every push, run `scripts/preflight.sh` from the checkout.** It is CI's `lint` job — the
same command the workflow runs, not a reconstruction of it: shell syntax, the two-way mode rule,
shellcheck at error severity, the PowerShell parse, and the parse, prompt, jq-shape and
scratch-directory guards with their fixtures, about 25 seconds for the lot. A
step whose interpreter this box lacks (`pwsh` on the macs) is a named SKIP rather than a failure;
CI passes `--require-tools`, where the same absence is red. `preflight.sh steps` lists what it
runs, `preflight.sh globs` the file list every sweep here is spelled from, and a single step runs
alone (`preflight.sh shellcheck`) while you iterate. `--as-ci` exports `GITHUB_ACTIONS=true` for
the run, so a refusal prints the `::error file=` annotation the lint job prints and every step
script sees the variable CI sets: a control that reads it by accident goes red at your prompt
instead of on the push (PR #275). The workflow calls this script for those steps, so the two
cannot drift, and `scripts/test-preflight.sh` pins that they have not.

The scripts carry their own test suites (Python fixtures use `python3`; PowerShell fixtures run on Windows):

```sh
issue-wave/scripts/test-fleet-worker.sh
python3 issue-wave/scripts/test-fleet-execution.py
./issue-wave/scripts/test-windows-driver.ps1
python3 ship-pr/hooks/test-ship-pr-nudge.py
python3 ship-pr/scripts/test-pr-review-hostile.py
python3 scripts/test-workflow-reporters.py
ship-pr/scripts/test-post-merge-cleanup.sh
ship-pr/scripts/test-pr-review-lib.sh
ship-pr/scripts/test-pr-review-base-lib.sh
ship-pr/scripts/test-pr-review-base-drift.sh
ship-pr/scripts/test-pr-review-base-red.sh
ship-pr/scripts/test-pr-review-base-settle.sh
ship-pr/scripts/test-pr-review-base-verdict.sh
ship-pr/scripts/test-pr-review-checks-absent.sh
ship-pr/scripts/test-pr-review-rounds.sh
ship-pr/scripts/test-pr-review-merge.sh
ship-pr/scripts/test-pr-review-status.sh
ship-pr/scripts/test-pr-review-watch.sh
ship-pr/scripts/test-pr-review-reply.sh
ship-pr/scripts/test-pr-review-run-watch.sh
scripts/test-wake-lab.sh
scripts/test-check-prompts.sh
scripts/test-check-jq-shapes.sh
scripts/test-check-scratch-dirs.sh
scripts/test-check-parse-guards.sh
scripts/test-preflight.sh
scripts/test-sync-routines.sh
```

Four conventions travel with that list. Each is held by a scanner that reads line shapes — a
register lookup, a line regex — and not by a parser, so a green check says a line of the required
shape is present and never that the thing it stands for is true: text crafted to carry the shape
without the substance passes every one of them. That is the design (ludics-lite#75, where a table
parser drew thirteen rounds of edge cases and was replaced by a scan), so the conventions below
state what each check establishes rather than enumerate the shapes that would fool it.

**A `test-*` name is a promise to run.** `check-prompts.sh`'s fixture check walks `scripts/test-*`,
`*/scripts/test-*` and `*/hooks/test-*`, and of every `.sh`, `.py` or `.ps1` it finds there it
requires a line in this Tests section that is that path once an optional `python3` or `./` prefix is
stripped — the two forms the register itself uses — and an inline `run:` line in
`.github/workflows/skill-scripts.yml` on each platform that file needs — both Ubuntu and macOS for a
shell suite, while a `.ps1` goes to Windows on its extension and the two Ubuntu-only Python fixtures
are the ones named by path in the checker. The lookup is the section and not the block — any such
line anywhere under `## Tests` satisfies it, so the register above is where those lines are kept by
convention rather than by enforcement. The glob asks the filename, not the file, so it cannot tell a
suite from a helper that is only ever sourced: such a helper either earns the name by carrying its
own controls and being run, as `ship-pr/scripts/test-pr-review-base-lib.sh` has since
ludics-lite#212 (executed rather than sourced, it proves the round counter, the grace and the tip
move straight off the fixture rather than through a `base` run, and the refusals it owes its three
callers), or it must not be named `test-*`. The third option, a register line and two CI steps for a
file nothing executes, is a green step that tests nothing.

**Every `test-*.sh` suite is one brace group.** Bash reads a script by OFFSET while it runs: it
parses one command, runs it, and comes back to the file for the next one — so a file rewritten
while a run of it is in flight resumes the shell in the middle of whatever text now sits at the
offset it left off at. The suites here take minutes and an agent iterating on one edits it during
exactly that window; it has cost two runs of `test-post-merge-cleanup.sh`, which removed the
scratch root under live cases (ludics-lite#10), and four minutes on `test-fleet-worker.sh`, which
died at a line whose text was fine (ludics-lite#247). So every suite's body is wrapped in one brace
group — two lines at the top, `exit "$?"` and `}` at the foot, the body's own indentation
untouched — and `scripts/check-parse-guards.sh` refuses one that is not, over the same
`scripts/`, `*/scripts/` and `*/hooks/` globs the fixture check above walks, plus the non-test
scripts named in its `ALSO_GUARDED` list. The group is parsed whole before its first line runs, and
the `exit` means the shell never returns to the file for a next command; both halves are needed,
and the shape was chosen over a `main() { … }` with `main "$@"` at the foot precisely because that
one hands the shell back to the file after the minutes the run took. A suite that is also SOURCED
by a sibling takes the same shape: the `[ "${BASH_SOURCE[0]}" = "$0" ] || return 0` dispatch in
`test-pr-review-lib.sh` and `test-pr-review-base-lib.sh` ends the sourcing inside the group, before
the foot is reached, so the caller survives with the definitions it came for.

A suite that SOURCES a sibling library does it in a preamble ABOVE the `{`, and that is the one
thing about the shape that is not free. Bash binds the location `declare -F` reports for a function
when it PARSES the definition, so with the sources inside the group every definition in the suite is
parsed before the libraries are read, the libraries' bindings land last, and the ludics-lite#46
shadow guard — which compares each protected function against the file and line its owner recorded
— reads every suite function as still the library's: it refuses a declared `stub`, and it accepts an
undeclared shadow in silence, which is the case that guard exists for. Above the group the
definitions are back where they were. What may stand up there is what forks nothing (`set` lines, an
`export NAME=value` with no substitution) plus what the sources need — one
`DIR=$(cd "$(dirname "$0")" && pwd -P)` and the `source "$DIR/…"` lines — with a source last; the
window it costs is those few commands, and the file is whole before the first case runs. What the
check establishes is those line shapes plus one thing a line shape cannot say: with the wrapper
lines deleted the body still parses, so a `{` that some `}` midway already closed is refused rather
than certified by a second group carrying the required foot. It is still a scan — another
arrangement of braces contrived to satisfy all of it says nothing, and a `source "$DIR/test-x.sh"`
quoted inside a heredoc is refused though it runs nothing — and the `.py` and `.ps1` suites are
outside it, since python and pwsh read a script whole before running any of it.

**Scratch directories have one house shape:** `VAR=$(mktemp -d …)`, then directly under it
`VAR=$(CDPATH= cd "$VAR" && pwd -P)`, and the cleanup `trap` under that. What
`scripts/check-scratch-dirs.sh` has enforced since ludics-lite#214 is the adjacency of the first
two: the next code line after the allocation must be the resolution — in the same function, at the
same block depth, whatever that line would otherwise be — because a line that already ran with the
environment's spelling does not get the physical one retroactively. Only comments and blank lines
may stand between them, which is where the `/var`-to-`/private/var` explanation goes, and that is
what places the `trap` the guard never reads: above the allocation or below the resolution, never
between, with the house order below, where the reading order matches the running order. The rest is
convention. `CDPATH=` is optional to the guard — a bare `cd "$VAR" && pwd -P` passes, as two suites
here still spell it — and is there against a nonempty `CDPATH`, under which a `cd` to a relative
target prints the directory it found and puts a second line inside the substitution. The resolution
itself is matched by shape, the same name on the left and a `cd … && pwd -P` on the right with the
`cd`'s own target unchecked, so resolving the wrong directory into the right variable passes. The
alternative to resolving is inheritance: `mktemp -d "$TEMP_ROOT/x.XXXXXX"` under a resolved
`TEMP_ROOT` needs no line of its own, which is what lets post-merge-cleanup.sh's scratch directories
pass, while `"$TEMP_ROOT/cache/x.XXXXXX"` is refused — the component `mktemp` creates cannot be a
symlink, an intermediate one can. That is one component per assignment and not one per chain:
`A="$ROOT/cache"` is resolved by the same rule, so `B="$A/work"` and a `mktemp -d "$B/x.XXXXXX"`
under it walk as far as they like. A root counts as resolved for a scope when every assignment to it
there matches one of the shapes the scanner reads as physical — its `cd … && pwd -P` idiom, a
resolver function defined in the same file, a `dirname` of a resolved variable, or inheritance from
one — and at least one of them stands at control depth zero. Depth there is keyword depth, so a
`then` arm cannot certify while a line inside `( … )` still does, and a non-resolving assignment
disqualifies from any depth, though only one that opens its own line is in the table to do it. A
shape it does not read is no resolution to it, however physical the path: a bare `ROOT=$(pwd -P)`
after a `cd` is refused. Line ORDER is not compared, so a root resolved below the allocation
satisfies the guard while the allocation itself ran unresolved: resolving it first is convention the
guard cannot verify.

**`routines/*/SKILL.md` are Markdown prompts read by an agent, not shell scripts.** Nothing execs
the file and no shell parses it: `bash -n`, shellcheck, `check-jq-shapes.sh` and
`check-scratch-dirs.sh` all sweep `*.sh`, and `check-prompts.sh` reads a routine prompt as text —
its frontmatter, its row in `routines/README.md`, the indented line that is this checkout's
`sync-routines.sh` invocation and nothing else, and the correctness-slot count where a file states
it. So a finding whose consequence comes from parsing the whole document as a program describes
something nothing does: a `: <<'X'` … `X` pair around a line does not swallow it, and a trailing
backslash on the line above does not join it to the next. Both were rebutted in ludics-lite#211, two
rounds apart. The boundary is the file and not the commands in it — the agent is told to RUN the
commands in those indented blocks, one at a time, so a command malformed in itself is a real defect;
what does not apply is the reproduction that needs bash to read the prose around it.

The GitHub Actions workflow in `.github/workflows/skill-scripts.yml` runs the shell suites and
shared Python fixtures on Ubuntu and on macOS (the fleet's bash is 3.2), with macOS spread over two
jobs and a step per suite. The count of macOS jobs is itself the thing being tuned: the hosted
runners are scarce enough that four separate macOS jobs queued a green PR for one to two hours
behind nine minutes of work (ludics-lite#55). Two rather than four, because that exposure grows
with the runner assignments and not with the work — the second job re-pays only a checkout and a
`brew install tmux`. Two rather than one, because the suites now take about eighteen minutes
together and all of it sits on the merge gate's critical path; the halves are cut along what they
exercise, ship-pr's own suites in one and the repo and fleet guards in the other, and come out at
roughly nine minutes each. The workflow carries the measured queue waits that trade rests on, and
the standing answer if the macOS pool starts starving these jobs: not a third assignment, but
moving suites off the per-push path onto periodic CI. Alongside them runs the `lint` job, which is
`scripts/preflight.sh` step by step: `bash -n`, shellcheck at error severity, the mode bits, the
PowerShell parse, the parse guard (`scripts/check-parse-guards.sh`, with
`scripts/test-check-parse-guards.sh` beside it), and the jq
shape guard (`scripts/check-jq-shapes.sh`, with `scripts/test-check-jq-shapes.sh` beside it) and the
scratch directory guard (`scripts/check-scratch-dirs.sh`, with `scripts/test-check-scratch-dirs.sh`
beside it). The first four were inline `run:` shell in that job until ludics-lite#123 (the parse guard became
a script of its own in ludics-lite#247, and preflight runs it as one more step): nothing
but a push ran them, nothing probed them, and the file list they sweep was spelled three times in
the YAML and a fourth time by hand in whatever buffer the next worker pre-flighted a push in. The suites
run on every push to main and on a pull request that touches anything but Markdown (the top-level
README counts as script input, since the fleet suite executes its install loops); three jobs run on
every head regardless, the prompt hygiene check (`scripts/check-prompts.sh`), the lint, and the
sync-routines suite, so every PR's merge gate reads a verdict rather than `ABSENT`, a prompt-only
PR included. The third is unconditional for a reason of its own: the routines-table pin it carries
is broken by exactly the all-Markdown PR the classification calls prompt-only.

The reporter and hostile-runner Python controls run on Ubuntu; the driver fixture runs on Windows.
`check-prompts.sh` checks each fixture file against this command register and the inline CI run
commands on its required platforms, so a new shell or Python suite cannot silently miss either
Unix platform. Platform-specific fixtures have explicit exceptions in the checker.

`check-prompts.sh` is the prompt hygiene check itself: every skill and routine `SKILL.md` opens
with YAML frontmatter carrying one `name`, equal to its directory, and one single-line
`description`, and every directory carrying a `SKILL.md` is named, in backticks, in the first cell
of a row of the README that indexes it — the skill table above, the routine table in
`routines/README.md`. That second half is a lookup, one fixed scan per directory, not a table
parser: it claims only that the name is written down as a row, not that the row renders, and it no
longer reads the other direction, a row that outlived its directory. The scanner it replaced drew
thirteen rounds of table-syntax edge cases in one review and reopened on every new rule
(ludics-lite#75). It also reads the relative Markdown links in those prompts, in the reference
files they delegate to — a routine's as well as a skill's — and in both READMEs: the path half of
a `.md` link has to exist relative to the linking file, and an anchor on it has to be the GitHub
slug of a heading in the target.
ludics-lite#260 cut the wave prompt into sections addressed by anchor — `cli-claude.md#close-out`,
`native-workers.md#placement-and-launch` and six more — and verified them by hand, once; a renamed
file or a retitled heading leaves such a link rendering as a link and landing nowhere, which is a
defect a reader finds and a test never did. This is the same kind of lookup as the index one, over
one fixed shape, spelled out in the checker's own header: a parenthesized target directly after a
bracketed label, on one line, with no blank in it, a path half ending in `.md`, and the whole
target spelled in ordinary path characters. Anything else — a URL, a title after the target, a
site-absolute path, a bare anchor, a percent escape or other spelling it would have to decode, a
reference-style link, a target that wrapped onto the next line — is not checked rather than
guessed at. What it will not do is answer about the machine instead of the prompts: a path that
spells its way out of the checkout, and one that walks out through a symbolic link, are both
refused on the path rather than probed, so no file beside the checkout can make an outside link
read as resolving; and a path is checked against the spelling the checkout actually has, since a
case-insensitive filesystem — the macOS default, and these suites run on macOS and Ubuntu both —
resolves a link GitHub serves as a 404. There is no
block scope either — no fences, no HTML blocks, no comments — deliberately, and at a cost paid in
this very paragraph: prose that spells a whole link in backticks is read as that link, so
documentation of the syntax has to describe it rather than write one. The other direction of that
gap is the mild one: a heading-shaped line GFM would not render, inside a fence or a comment,
still contributes an anchor, which can accept a link GitHub would not resolve but refuses none. On the other side, a heading whose rendered text differs
from its source — inline link syntax, an HTML tag, a character entity — or which carries a letter
past ASCII, is one whose anchor it will not spell: it reports no slug and says so, rather than
answering with the source reading, which would refuse the right anchor and accept one GitHub never
creates. It also holds `ship-pr/SKILL.md` to `post-merge-cleanup.sh`'s own option register: every
option the helper's `usage()` heredoc lists is named, verbatim, somewhere in the prompt, and every
`--option` the prompt's fenced command lines pass to the helper is one the heredoc lists. Which
`--flag` in the prompt is the helper's is a line shape — a fenced line naming
`post-merge-cleanup.sh`, plus the lines a trailing backslash continues it onto — so a flag of `gh`
or of the test runner is attributed to nothing, and an option the prompt only discusses is held
from the listing side alone. ludics-lite#276 added `--regenerable` to the helper and to the prompt
by hand, in the PR that found the prompt's prose about the base-owner gate had been false through
two earlier PRs; the name being present is what this pins, and whether the prose around it is true
stays the review question it was. `test-check-prompts.sh` runs it against scratch trees,
one per defect, with the well-formed tree as the control, and ends by running it on this checkout.

`check-jq-shapes.sh` is the jq shape guard, run in the lint job on every head over every
`*/scripts/*.sh` and `scripts/*.sh` in the checkout — the lint job's own file list, less
`ship-pr/hooks`, whose shell shells out to no jq yet. The trap is a property of jq and not of any
one script, so the one-file default it opened with printed "every capture( is bracketed" over two
dozen files it had never read. Two are excluded, named one path at a time rather than matched by a
glob that would also cover a file nobody has written yet: the guard itself and its fixtures, which
quote and write the refused shapes on purpose and would otherwise have their documentation of the
rule reported as a breach of it. An explicit argument is read whatever its name. jq's `capture`
yields ZERO outputs when its pattern does not match — not null — and a zero-output sub-expression
deletes the value that contains it rather than falling back to a default: a string interpolation
loses the string, an object loses the object, and inside the update expression of a `reduce` the
whole accumulator goes, so a fold over ten hunks returns null and the path reads as "unread" on a
patch that parsed fine. Nothing errors, so nothing catches it. Five such sites have been fixed
across three PRs (ludics-lite#84 three, #104 a fourth, #89 a fifth) while `[capture(…)] | first`
was documented only in prose beside one of them. The guard is deliberately grep-shaped rather
than a jq parser: comments are removed first, with enough shell/jq quote state to know a `#`
that opens one from a `#` inside a string (without that, comment text read as code, and two
comments could fabricate the wrapper a bare capture was missing); a line beginning with `|`
continues the line above it; a `capture` left dangling at the end of an expression — its argument
list on the next line, which jq accepts — is refused rather than followed, since a line-shaped
scanner cannot certify a wrapper it cannot see; and then EACH `capture` call in the resulting expression is checked against its own brackets
— the nearest `[` before it with no `]` in between, the `]` that closes that `[` by depth read
back immediately with the zero-argument `| first` or `| last` (`first(f)` answers with an output
of `f`, hiding the miss), and the capture alone inside those brackets — one capture, and no comma
at the wrapper's own depth, since a second element answers `first` when the capture misses. Per
occurrence rather than per expression, because an existential test certifies
`([capture("a")] | first), capture("b")` on the first capture's brackets while the second is
bare; and one wrapper per capture, because `[ ("a" | capture("a")), ("x" | capture("b")) ] |
first` returns the first match and discards a miss by the second exactly as if it had never been
wrapped. A call is `capture` with optional whitespace before its argument list, since jq allows
`capture ("x")`, and a bracket count that a regex character class unbalanced refuses, which is
the direction that asks for a rewrite rather than passing a bare capture. The issue's second proposed rule — refuse a
`test(` and a `capture(` on one expression, the #104 shape — collapses into that one, since what
makes the pair dangerous is the unbracketed capture and not the pairing; a pair that satisfies
the rule passes, and one that does not is refused with #104 named in the message.
`test-check-jq-shapes.sh` runs the guard against a scratch file per shape, with the passing shape
beside each as the control; against scratch checkouts that pin the default sweep's scope, where a
bad shape in a second scripts directory and in the top-level one must each be refused and the two
excluded files must not be read; and then against pr-review.sh as it stood before ludics-lite#89,
where it must still find the site that PR fixed (skipped on the depth-1 Ubuntu checkout, run on
the macOS one, which fetches the full history).

`check-scratch-dirs.sh` is the scratch directory guard, run in the lint job over that job's own
file list, `ship-pr/hooks` included. `mktemp -d` answers with the path as the environment spells it, and on macOS both `/var` and
`/tmp` are symlinks into `/private`, while every script here computes its own root with `pwd -P`.
Unresolved, one directory has two spellings, so an assertion comparing a script's output against a
scratch path stops matching in silence and the ones phrased as "this must NOT appear" pass over
anything at all. The one-line fix, `TMP=$(cd "$TMP" && pwd -P)`, was independently rediscovered
three times, because the absence of the line is not visible in the file that lacks it: a suite with
it and a suite without it read identically at the `mktemp` call (ludics-lite#208). The guard
refuses a `mktemp -d` whose result is neither resolved before its first use nor rooted in a path
the file already resolved — a child of a physical path is physical, which is what lets
post-merge-cleanup.sh's two dozen scratch paths under its canonicalized `TEMP_ROOT` pass without a
line each. A comment and a `trap` body are not uses: the first is where the resolution gets
explained, the second runs at exit. `test-check-scratch-dirs.sh` runs it against a scratch file per
shape with the passing shape beside each, against scratch checkouts that pin the default sweep's
scope, and finally against the three suites that rediscovered the fix, each with its resolution
line removed, where the guard must find what their authors found by accident.

`test-fleet-worker.sh` runs its ~180 assertions top to bottom in one shell, which takes about three
and a half minutes. Arguments narrow that: each one selects every section whose name contains it
(`test-fleet-worker.sh unstick`, `test-fleet-worker.sh 'real checkout'`), `--list` prints the
section names, and an argument matching none of them is refused before anything runs. The setup the
sections share (the shim CLIs, the scratch skills checkout, the scratch project repo) runs whatever
is selected, and a section that needs more than that, such as the coordinator lease or a finished
worker to read, takes it itself, so every section also passes when it is the only one selected.

`test-wake-lab.sh` runs the lab script against shim `curl`, `python3` and `ssh` on PATH, so it
touches neither the router nor the network. It pins the split above from both sides: that every
MAC the script sends comes from the sourced host table and that a missing, incomplete or
short-a-target one is refused before any router traffic, and that no MAC-shaped literal is tracked
anywhere in the repository, in either separator the script accepts (with a negative control, since
a scan that cannot fail would prove nothing). It also pins `--help` to the whole header comment,
which was a hard-coded line range that truncated silently whenever the header grew; that the WSL
kick reaches the Windows side through whichever of the two aliases answers, since after a cold boot
that is the LAN one; and that the polling loops honour a wall-clock deadline against slow probes,
which an iteration budget did not (`WAKE_LAB_WAIT_SECONDS`, `WAKE_LAB_WSL_WAIT_SECONDS` and
`WAKE_LAB_DOWN_WAIT_SECONDS` are what let the suite ask for a one-second one). It also pins what
holds a kicked WSL VM up, which is a `wsl.exe` on the Windows side and nothing else: `--hold`
spawns that holder as an unsized shell reading the ssh channel, never inside the guest, and the VM
counts as up only once that holder has said its token back from inside the guest. Its shim models
the holder as TWO processes — a client and a remote with a channel between them, and no reach from
one to the other — because the teardown defect it now pins (ludics-lite#192) is precisely a remote
tree outliving its channel, which a one-process shim ends by killing and therefore cannot express;
so the cases cover the guest shell ending on EOF, `unhold` observing that before it claims a
release, a leaked holder being ended by its recorded guest pid, and one that survives even that
leaving rc 3 rather than the sentence the issue was filed about;
and it pins the Windows Update active-hours warning together with its quiet path, since a check
that warned under the 6-to-0 window the boxes pin is one nobody would read. Finally it compares
the lab lock contract against the ocannl sweep's code where that checkout is present, as described
under [The lab script](#the-lab-script), and prints a counted `SKIP:` line where it is not.

`test-sync-routines.sh` runs `scripts/sync-routines.sh` against scratch trees, with
`CLAUDE_SCHEDULED_TASKS_DIR` pointed at them and over a byte-identical copy of the script inside a
scratch checkout, so a `pull` case can never reach the real `routines/`. It pins the four states
`status` reports and the exit code of each — in sync, drift, installed as a symlink, no prompt
directory — that `push` replaces a symlinked installation with a real directory instead of writing
through it, and that a destination reached through a link at any component *above* the routine
directory is refused too: a symlinked `~/.claude` leaves every task directory real and the whole
tree unreadable. It pins that a directory which exists and is
still not a usable prompt — a link anywhere inside it, no `SKILL.md`, or a `SKILL.md` that is
empty or carries no readable frontmatter — is refused rather than certified in sync or pulled over
the checkout, in both directions and before any branch that would publish it, with legal but unusual prompts
as passing controls. Frontmatter validation delegates to `check-prompts.sh --one <dir>`, including
optional fields and the checker's LF-only grammar: CRLF prompts are now refused consistently
with repository validation. Single-directory mode skips README indexing and name/directory
equality, so installed task IDs may differ from prompt names; repository mode keeps both checks.
Sync separately requires a nonempty Markdown body. The suite also checks missing-validator
refusal, a description quoting the former parser's markers, and this repository's own prompts; that the two
roots must be disjoint however the overlap is spelled, since a destination under `routines/` has
the publisher walk the tree it is writing; that publishing replaces what stands in its way rather than following or
entering it (a linked directory at either end, a directory or a link to one where `SKILL.md`
belongs, a file where a directory belongs), checks every step, and reads its own
result afterwards — that the destination now HOLDS the source, not merely that a `SKILL.md` is
there, which a failed copy leaves standing. Two copies of the script, each with one guard deleted
between markers in the source, are what keep that post-condition honest: without the file-kind
guard it must catch an unusable destination, without the pruning pass it must catch a destination
that is not the source, and each has the control that the same copy publishes cleanly when
nothing is in its way. It pins that `pull` is the repair in the other direction, restoring a
checkout routine that was deleted or linked away, and that it does not take the empty-diff
shortcut over a linked `SKILL.md` whose bytes already match; that a RETIRED routine still
installed on a box is reported in every mode and removed by nobody, since deleting a prompt
directory here retires nothing where the registry entry still names it and the install loop reads
this repository's list rather than the destination; including the dangling link an
upgraded box is left with, which a plain existence test calls absent; that publishing through a
symlinked ancestor is refused at either root while reading through one is only warned about, so a
linked destination root refuses a `push` and a linked `routines/` refuses a `pull`, each letting
the other direction through; and that `--help` states both halves of that, since it is the
contract a caller reads exit codes out of; that a push never
leaves the installed prompt absent or half-written, sampled by a reader running flat out across
twelve of them, with a control that the reader can report an absence; and that two modes in one
invocation are a usage error, since `push` and `pull` write in opposite directions and the last
token used to win. It pins that
`--dry-run` copies nothing in any mode, the usage exits, and that nothing infers a registration
state from a missing prompt directory — the registry is the desktop
app's and unreadable here, so `push` says to check the task list rather than reporting what is in
it. It also pins what ludics-lite#77 found unpinned: that the script's `LOCAL_ROUTINES` lists
exactly the rows of `routines/README.md` whose Kind is `local scheduled task`. That comparison
reads the table narrowly and refuses an empty read, so a mangled table cannot pass it vacuously,
and four negative controls show it can fail; `check-prompts.sh` keeps its per-directory lookup and
gains no table model. Two last cases pin what the comparison is worth: that the workflow job
running this suite carries no `if:`/`needs:`, since an all-Markdown PR is both what the diff
classification calls prompt-only and the one shape that can break the pin, and that the tracked
mode of `sync-routines.sh` is 755, which a `> tmp && mv` rewrite drops silently. Its assertions read
strings rather than piping them into `grep -q`, which exits at the first match and can SIGPIPE the
writer under `pipefail`: a pin that fails one run in many is worse than no pin, and the one it
carries decides whether an unconditional CI job is worth having.

`test-pr-review-checks-absent.sh` drives the build gate against a canned Actions API, one answer
per polling round, and pins everything the check list alone cannot say about a head. Exit 4 (no
verdict): a queued or running workflow — including under a green check from a sibling workflow — a
run that completed stopped-not-judged with nothing behind it, a green check with no Actions run
behind it at all, and a checkless head still inside `SHIP_PR_BASE_ABSENT_GRACE`, measured from the
fresher of the commit date and the PR's `updated_at` (each validated on its own, so a long-local
commit pushed a moment ago counts as fresh and a future commit date does not blind the gate).
Exit 1: a run that concluded red without producing a check to be red, over a green, pending or
stopped check alike. Exit 0: green over a finished, judged run list, and the absence itself once
the grace is spent — or, for a head with no run at all, as soon as no workflow of
the repository can create one for it (ludics-lite#176): every `pull_request` trigger's
`paths-ignore` covers every commit from the PR's merge base up, every declared `push` trigger refuses outright — nothing about a
push event is establishable from these feeds, which is most of the recognition's reach given away
deliberately — and every other trigger is one whose run can never carry this commit as its head
(`merge_group` and `workflow_call`, and nothing else). The cases pin the
refusals as much as the recognition — a trigger with no filter, a source path in the range, a path
under `.github/workflows/` anywhere in it (a filter that moved mid-range), a workflow file at
either end of the merge that the repository's list does not carry (that list is built from the
default branch plus whatever has run, so it is no inventory of the merge context's files), a
workflow-directory response at the Contents API's cap, a listed workflow the advisory NAME would
once have skipped (those names have no ref, so they describe the default branch's copy and not the
one that runs here), an unparseable workflow, an unreadable or truncated workflow list,
a PR whose base SHA or branch did not come back, a declared `push` trigger in any form, a base
that moved under the recognition (a retarget moves the evidence without moving the head), an event outside the inert list
(`pull_request_target`, the review events, `schedule` and `workflow_dispatch` among them), a base-side edit to the workflow (a
`pull_request` run uses the merge context's copy, so the two sides must be identical), and a
sampled merged PR whose check runs show a provider other than Actions, none at all, or more than
its page holds — each of
which leaves the grace to answer as it did before, while the named inert events do not block the
recognition, because none of their runs is created at this head; and that the question costs no read at all where it cannot change the answer
(a head that already has a run, or one already past the grace). A read that fails is exit 3, never a reassuring 0. Only finished runs are
folded away as superseded, per workflow and event, so a re-triggered invocation does not park the
gate on its cancelled predecessor while one file's `push` and `pull_request` runs still count
separately and a queued invocation is never hidden behind a finished twin; and a run whose red is
explained entirely by advisory jobs is not a red build signal, since those checks were dropped on
purpose.

`test-pr-review-run-watch.sh` drives `retry run watch`, which addresses its run as
`owner/name#<run-id>` like every other subcommand and no longer resolves the repository from the
cwd (ludics-lite#74): a background shell that had started in another project's worktree awaited a
run id from this one, the read 404'd against the repo the cwd named, and the await answered about
the run. So a bare run id with no `-R`/`REPO=` is refused, and its control runs from a scratch
checkout whose `origin` names a third repository with the fixture answering `gh repo view` too —
both halves of the removed inference armed, and nothing read. The suite pins the other exits
against that refusal: a 4xx on the pair is an invocation error (exit 2) and a run that concluded
`failure` is still the verdict (exit 1), with an unanswered read exit 3 and a run still going at
the deadline exit 4.

`test-pr-review-status.sh` drives `status` and `watch` against canned reactions, reviews,
comments and PR reads, and pins the mergeability that rides on every state line: a PR whose merge
commit GitHub cannot build says `CONFLICTS` on every state and never "the next move is yours",
GitHub still computing is not a conflict, a failed PR read cannot hide a 👍 and is `unknown`
(exit 3) only where the head SHA decides the state, one PR read serves a whole `status`, and a
`watch` that returns on a round prints the base-drift read on stderr, against the base branch's
tip, leaving stdout byte-identical to `poll`'s. It also pins the round's ONE observation
(ludics-lite#95): a watch round reads the comments, the reviews and the PR once each, publishes
them, and the state reported beside that round is computed from those same bytes instead of a
second read a second later — the comments and reviews feeds, the PR, and a new review's own
comments endpoint each drop from three reads a window to two, one for the state the watch opens
with and one for the round (the third PR read on a landing round is the base-drift read, a
different question). Three things the second read was carrying are pinned with it: the round
reads its head AFTER its feeds, so a push landing on the round's feed read leaves the item
classified against the new head rather than matched to the one it named (the ludics-lite#47
ordering, now a property of the round); a push landing AFTER the round's head read cannot
re-anchor the state to a head the round classified nothing against (the P2 rebutted in the review
of ludics-lite#84); and a round that did not answer publishes nothing, so the state read after it
reads the feeds itself, as does a `status` asked after the watch has ended.
`test-pr-review-base-drift.sh` pins the other half: the drift count is anchored on the base's tip and never on the PR's `base.sha` snapshot,
which stands still on a conflicted PR.

`test-pr-review-watch.sh` drives what ends a `watch` (ludics-lite#72), against a fixture that
answers the feeds in sequence across polls — the round a final poll catches has to be absent from
the round before it. The wait ends only on reviewer activity about the head being watched: a
review, an inline finding or a summary about another commit is printed on stderr for the record
while the watermark advances past it and the window goes on, with the same item about the head as
each case's control. An inline finding is bound by the commit it was WRITTEN against, since
GitHub migrates `commit_id` forward to the current head; an item with no commit association at
all, and every item when the head could not be read, is acted on rather than swallowed. Each exit
names what it ends on, from the machine-readable `items:` line `poll` ends with rather than from
the rendered headers — a reviewer body that quotes one of those headers is not an item, and a
summary is stamped by its footer rather than by a commit it mentions above it. Inline threads at one anchor — same path, commit, author and every location
field the row carries — render as ONE entry naming every thread id and printing every distinct
body under its own thread id, with one item on that index; the body is deliberately not part of
the key, because the reviewer duplicates a finding by re-writing it (on the round the issue was
filed on, grouping by body finds zero duplicates among 51 findings while grouping by the anchor
finds the four the issue counted). A different place — line, path, commit, position, a `side` or
`start_line` nobody enumerated, or a field this script has never heard of — stays a separate
entry, each difference with its own case, because a fold that collapsed unrelated findings would
pass every other case here. The anchor is rendered as the field the feed actually served — a line
number, else the diff `position` as `@12`, else `?` — so a row from the per-review endpoint, which
carries no line at all, no longer prints the unknown place as `:0` and no longer reads like two
findings at one line. The rest of that anchor is on the line too (ludics-lite#113), since the key
separates on fields the header used to omit: the range of a multi-line comment (`a.sh:36-40`),
`side=LEFT` on the deletion side, `start_side=` when a range ends on the other side, and `was=`
when GitHub has migrated the anchor forward since it was written — the sibling case asserts that
two entries the fold kept apart render as two distinct headers, the id aside, and that rows
agreeing on every anchor field still fold and print that anchor once. Every verdict that
says nothing came polls once more first, and re-reads the state behind that poll: a 👍 landing in
the same gap is reported as the approval it is rather than answered with the nudge that would
clear it, a state that moved otherwise makes the window quiet, and a read that did not answer
withholds the verdict for a transport exit instead of claiming the reviewer said nothing — including
when that changes nothing, so the extra poll is not proved by the hit alone — and the round it
finds beats the nudge it would have recommended. The `expected` clock is here too: it starts no
earlier than the PR's own creation, still runs from the head's committer date on an older PR, and
survives a committer date in the future.

`test-pr-review-reply.sh` covers the two WRITING commands, which had no fixture coverage at all
until it (ludics-lite#76): every other suite drives a read path, and a double-posted reply is not
something a test may risk against the live API. One invocation answers a whole folded entry — the
composed body to the anchor thread, a one-line pointer to that reply into each duplicate — and
`resolve` closes every thread the same token names, an already-resolved one costing no write. A
token that is not a comment id or several joined by single `+` is refused before anything is
posted, and so is an unquoted body (the arity, not `${3:?}`, which would post its first word). A
failure MID-batch never says "nothing was posted" once the anchor has landed: it names what landed
and which ids to retry with, with the same failure at the anchor as the control, and the write
exits stay apart inside a batch — a 4xx rejected (1), anything else ambiguous (3). The suite also
pins where a write is ALLOWED to land (ludics-lite#92): `resolve_repo` verified a cached repo
against `repos/<repo>/pulls/<n>` and trusted the cwd-inferred one above it outright, and cached it,
so a bare `reply 7` from a shell in another project's worktree posted into that project's PR 7 and
remembered the wrong repo for every later call. The repo is now NAMED or refused — neither the cwd nor
the per-PR cache is a source any longer, and verifying either would not have made it one, since
`repos/<repo>/pulls/7` answers "this repository has a seventh PR" and every active repository does.
The cases run the writing commands from a scratch checkout naming a third repository with
`gh repo view` answering a fourth, as in `run-watch`'s control, and nothing is read before the
refusal; a checkout that really *has* PR 7 gets its own case, since that is the invocation a
verification could not fail on, and so does a bare number following a call that named a repo, which
is the ambiguity the cache carried across checkouts and sessions. The control is a named repo
writing from that same wrong cwd.

Three suites cover the other `base` — the one that answers "is the branch I am about to work off
green" — over one shared fixture transport, `test-pr-review-base-lib.sh`. They were one 900-line,
33-case file until ludics-lite#179, where "which suite failed" said only "base".

`test-pr-review-base-red.sh` is the red REPORT: what the command says once the answer is no
(ludics-lite#73). A red names the
failing JOB and the commit the red starts at, and the cases pin the claims that could be quietly
wrong: a first red commit is named only when a judged run under the streak was not red (a window
red to its end says the red may start further back instead), a run that was cancelled or is still
going ends no streak because it judged nothing, two workflow files sharing a display name keep
their histories apart, a jobs read that fails prints UNKNOWN and leaves the red standing rather
than reporting no failing job, and a green base spends no call on any of it.

`test-pr-review-base-settle.sh` covers what `base --wait` does when the tip has no verdict of its
own (ludics-lite#156, where a docs-only default-branch tip parked a wave's dispatch at the ceiling
while the plain read settled for the older green on it). The grace that separates "never coming"
from "not yet" runs from the first READ of the tip rather than from the end of the round that read
it — re-stamping it there spent a round of API latency out of the grace, which is how a
`--wait=301` over a 300s grace reached its ceiling seconds before the clock it was sized against,
every time. The ceiling's own arithmetic is pinned here too (ludics-lite#175): the grace is tested
once per round and rounds are one poll interval apart, so a `--wait` in the band between the grace
and one interval past it draws a loud line — the ceiling cap does schedule it one settling round,
which a tip that moves takes away — while one at or below the grace is a bounded peek that reports
no verdict, and a zero grace is outside the question entirely. The absence is then read per workflow: a run that EXISTS for the tip and has not
judged it — queued, running, or stopped — keeps the refusal because only that run can answer, and
so does a run in flight anywhere on the branch, which is judging a tree the tip contains (waiting
for it does better than settling: its commit becomes the verdict the tip then trails). What ends
the wait with no clock at all is the workflow's own `paths-ignore`: when every commit the tip adds
over the judged one changes only ignored paths, no run can be created for that tip. Per commit,
because a filter is evaluated per PUSH and a range that nets out to docs can still contain a push
that touched source; a push's diff is a subset of the union of its commits', so a range whose
every commit is ignored contains no push that is not. The path walked is the FIRST-PARENT one from the tip
down to the judged commit, and it has to really reach it: a commit's file list is its diff against
its first parent, so a merge reached through its second parent would hide, behind a docs-only
first-parent diff, everything the push carried — and after a force-push the judged commit is not an
ancestor at all, which `behind_by` says. The one filter read has to be the one that applied, too —
so no commit on the path may touch the workflow file, and each commit's files are read across every
page, since that endpoint serves thirty at a time. The cases pin both directions
— a source file in the range, a source change reverted inside it, a workflow file changed inside
it, a judged commit that is not an ancestor, a merge reached through its second parent, a range
past the commit cap or only partly in hand, a file list at the endpoint's own cap, a
filter pattern the translation does not carry, a workflow file naming no filter, a workflow with
no run history whose filter nobody read — each costing the grace rather than a settle, and the tip
re-confirm, since a settle for an older verdict must not be handed to a tip that moved under the
round.

Five cases across those suites are on the CLOCK — a retuned grace, a `--wait` ceiling, a delay
inside the fixture — and they went red on a loaded machine twice before settling into one shape,
which the shared transport now writes down and provides: the grace is spent by an explicit delay
inside the first round's own reads (`spend_grace`), the fixture's event lands on round one
(`at_round`, counted on the runs-feed read, which is one per round by construction), and the
ceiling is kept clear of both. Counting ROUNDS against a clock was the trap: a round launches a
fixture and several jq subprocesses, so under load four happened where five were counted on and a
tip move landed on the wrong side of the grace (ludics-lite#169). A case that wants to know how
far a wait got reads `rounds_polled` rather than elapsed time. Executed rather than sourced, the
transport runs its own controls over those three devices — read a `gh` call at a time, with no
`base` run around them, since a control driven through the wait loop would be on the clock itself.

`test-pr-review-base-verdict.sh` pins what the wait loop DECIDES (ludics-lite#93). A red at the tip is the
tip's own verdict and ends the wait on the round that saw it; a red behind an unjudged tip is the
fix-in-progress shape and keeps it, so both breaks — the red one and the covered-green one —
re-confirm the tip before they trust the read that reached them, and at the ceiling `NO VERDICT`
headlines instead of an older tip's red. The absence grace restarts whenever the tip MOVES, so a
merge landing after it has already elapsed is not declared green on the spot. A listed workflow
with no push run at all is ambiguous — dispatch-only, or a newcomer the tip just added — and what
separates them is the tip's own age, read off the sibling runs at the tip rather than off the
wait's observation clock (an unreadable timestamp holds nothing). A run that completed
stopped-not-judged does not speak for the run under it: the newest JUDGED run carries the verdict,
so a red beneath a cancelled one still stands and a green beneath one still covers the tip. And
under `--wait` the tip is the question, so a tip read that failed is UNKNOWN rather than something
to wait through; without `--wait` the same failure costs only the "not the tip" notes.

Each workflow's page of runs is sorted on `(created_at desc, id desc)` before the fold
(ludics-lite#90), as `run_signal`'s feed has been since #83: two pushes to the branch inside one
second give their runs the same `created_at`, GitHub documents no order between them, and the fold
and the streak walk both keep whichever row they see first — so the verdict was decided by luck. A
tie now goes to the higher run id, the later allocation. Sorting each page rather than the
assembled rows leaves the report's per-workflow lines in the order the workflow list gave them.

The `test-pr-review-*.sh` suites share a preamble, `test-pr-review-lib.sh`, which sources
`pr-review.sh` for them and carries the reporter, the assertions, the scratch-directory cleanup,
the fixture `gh`'s argument parsing, and the `jq` shim that makes ONE named jq program fail so a
case can prove a read that did not parse refuses instead of rendering a plausible value
(ludics-lite#89). Three suites carried that shim byte-identically, each re-proving with a control
of its own that it breaks only what it is pointed at; that claim is about the shim, so the
preamble's own controls pin it once and a suite keeps only the baseline its broken runs are
measured against (ludics-lite#179). The guard reaches one library further out too: the base
suites' shared fixture transport is sourced after the preamble, so its own helpers were outside
the snapshot and a suite colliding with one of them — `reset_fixture`, say, which every case
opens with — was accepted in silence. `protect_library <file>`, called by such a library from
inside itself, extends the snapshot over what it defines, and a call that would add nothing is
refused rather than protecting nothing. It also closes the trap that bit twice (ludics-lite#39, #45,
#46): `pr-review.sh` puts some sixty unqualified functions in scope, and a suite helper sharing a
name — a reporter called `fail` — silently replaces the library's, turning every refusal's exit
code into the reporter's. So the preamble snapshots the function table when it is sourced, and
`run_tests` refuses, naming the function and where the suite redefined it, any library function
redefined without a `stub <fn>` declaration (the merge suite declares `build_checks`, `run_signal`
and `warn_base_drift`), and any declaration the suite never honoured. It also carries `retune`, for
the constants `pr-review.sh` reads from the environment exactly once, when it is sourced (`GRACE`,
`STALL`, `ROUND_GAP`, `ABSENT_GRACE`, `CHECKS_INTERVAL`, …): a case that needs a different clock
cannot pass `SHIP_PR_REVIEW_GRACE` to it and has to assign the constant, and the restore is the
part that gets forgotten — a constant left retuned leaks into every case after it, which is a wrong
result rather than a failure. `retune GRACE=1` remembers the value as sourced, refuses a name the
script does not set, and `run_tests` puts every one of them back when the case ends. Run directly,
`test-pr-review-lib.sh` is its own suite: throwaway suites that source it prove the guard refuses
what it must and passes what it must, and a pair of cases proves a retuned constant is restored for
the case after it. A control there has to be *shown* to fail, and the way to show it is to copy the
file and `pr-review.sh` into a scratch directory, revert the fix in the copy, and run the copy —
the tracked file is never touched, so an interrupted session leaves the repo clean. The copy may be
named anything (the file derives its own name rather than spelling it) and needs only `pr-review.sh`
beside it; the last case runs a renamed copy for real, so a name spelled instead of derived breaks
the suite rather than the next person's mutation (ludics-lite#101).

The fixture suites pin the gate's logic against canned answers, so the shapes those answers imitate
are a belief the suites cannot check — a renamed field, a changed default ordering or a new
conclusion string leaves every fixture green and the gate reading a head wrong (ludics-lite#41).
`ship-pr/scripts/pr-review-api-contract.sh` asks this repository's own live API the same questions,
one jq read per belief, and reports each on its own line (`ok`, `MOVED` with the filter and the
read, or `skip` with the reason it cannot be checked here), so a failure localizes to the field
that moved; its exit code separates a moved belief (1), an addressed endpoint answering 4xx (4) and
a read the token was refused (5) from the API not answering or throttling (3), and the reporter
files everything but the last, naming which: the fields `run_signal`, `build_checks`, `run_red_is_advisory_only`, `pr_head_read`,
`warn_base_drift` and `status_state` index; the workflow file `workflow_paths_ignore` reads under
the raw media type (the base64 envelope arriving instead would cost every paths-ignore recognition
silently); the newest-first order of `actions/runs`; the two feeds `cmd_base` reads and nothing checked until
ludics-lite#90 — the workflow list (`actions/workflows?per_page=100`: the id and name the fold
groups on, the path the filter read asks for, and that this repository fits the single page) and
the per-workflow, branch-and-event runs page (`actions/workflows/<id>/runs?branch=&event=push`: the
eight fields the fold projects, `.id` among them since #81, that the `branch=` and `event=` filters
really filter, and the newest-first order that makes `per_page=10` the newest TEN runs and not ten
arbitrary ones); the status,
conclusion, mergeable-state and review-state vocabularies; that a merged PR's `.base.sha` is a
snapshot standing behind the merge's first parent (anchored on #53); and the reviewer feeds' shapes
(the `[bot]` suffix, the `+1` approval, `COMMENTED` rounds, the summary tag, 30-per-page
pagination) anchored on #39. `.github/workflows/api-contract.yml` runs it daily, on demand, and on a pull request that
changes the contract itself; a scheduled failure opens (or comments on) one issue rather than
failing silently, from a second job that checks nothing out, so the job that runs a pull request's
version of the script holds a read-only token. A belief that needs a state this repository does not
have, or a fact the API does not carry — a dirty PR pushed to under observation, a 300-file
compare, the push time behind `updated_at` — prints as `skip`, so the unpinned set is visible in
every run. Run it locally with `gh` auth: `ship-pr/scripts/pr-review-api-contract.sh lukstafi/ludics-lite`.

`.github/workflows/base-watch.yml` gives main's own CI verdict an owner (ludics-lite#73). Every
worker's session starts by branching off main, and nothing read main's verdict between waves: main
was once red for a day, unnamed, until a pull request tripped over it. So the read a worker does at
session start, `pr-review.sh base lukstafi/ludics-lite main`, runs after `skill scripts` completes a
push run on main, daily (06:47 UTC, away from the contract's slot), and on demand. An unattended
run that finds a red — or a tip with no verdict at all, or a check that broke — opens one issue
naming the workflow, the failing job and where the red starts, from a second job that checks nothing out and holds the only writing token. One issue per
red EPISODE, not per day: while it is open the next run comments on it, so closing it once main is
green is what lets the next red open a fresh one. On a pull request it reads and reports without
filing, and a red main does not redden the pull request: that verdict is about main, and a PR
carrying it as a failed check could not merge the fix.

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
