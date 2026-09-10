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

`routines/` carries the scheduled-task prompts, but not the way the skill directories carry
skills: since desktop app 1.46388.4 the scheduler refuses a task file reached through a symlink,
so the two local ones install as copies under `~/.claude/scheduled-tasks`, pushed and pulled by
`scripts/sync-routines.sh` (`status` after a merge that touched a prompt, `push` to install it).
The desktop app's registry (cron, working directory, model) is not in the repository and is
recorded in [routines/README.md](routines/README.md), which also carries the install order and the
symptoms of an unreadable prompt. The third, the CI-red triage routine `ship-pr` defers master's
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

`WAKE_LAB_HOSTS` overrides that path. Everything else stays here and reviewable: the verified lab
lore in the header comment (wake-on-LAN over Ethernet only, waking from a full shutdown, what
`router-active=1` means, the cold-boot kicked-VM trap, the `exit 0` vs `true` probe trap), the router
endpoints, the ssh aliases and all of the logic. `wake-lab.sh --help` prints that header, and
`--help` and `--list` are the two commands that work before the host table exists. The box names
(`rog`, `minix`, `asus`) and the ssh aliases are the author's and are edited in place.

To repair the Windows-side NIC settings, copy `scripts/enable-wol-windows.ps1` to the Windows box
and run it from an elevated PowerShell (`powershell -ExecutionPolicy Bypass -File
.\enable-wol-windows.ps1`); BIOS/UEFI Wake-on-LAN still has to be enabled separately.

## Tests

The shell scripts carry their own test suites:

```sh
issue-wave/scripts/test-fleet-worker.sh
ship-pr/scripts/test-post-merge-cleanup.sh
ship-pr/scripts/test-pr-review-lib.sh
ship-pr/scripts/test-pr-review-base-drift.sh
ship-pr/scripts/test-pr-review-base-red.sh
ship-pr/scripts/test-pr-review-checks-absent.sh
ship-pr/scripts/test-pr-review-rounds.sh
ship-pr/scripts/test-pr-review-merge.sh
ship-pr/scripts/test-pr-review-status.sh
ship-pr/scripts/test-pr-review-watch.sh
ship-pr/scripts/test-pr-review-reply.sh
ship-pr/scripts/test-pr-review-run-watch.sh
scripts/test-wake-lab.sh
scripts/test-check-prompts.sh
scripts/test-sync-routines.sh
```

The GitHub Actions workflow in `.github/workflows/skill-scripts.yml` runs all fourteen on Ubuntu, one
job per suite, and on macOS (the fleet's bash is 3.2) as one job with a step per suite: the hosted
macOS runners are scarce enough that four separate macOS jobs queued a green PR for one to two
hours behind nine minutes of work (ludics-lite#55). Alongside them run `bash -n`, shellcheck at
error severity, and a check that the two cleanup scripts still carry their parse guard. The suites
run on every push to main and on a pull request that touches anything but Markdown (the top-level
README counts as script input, since the fleet suite executes its install loops); three jobs run on
every head regardless, the prompt hygiene check (`scripts/check-prompts.sh`), the lint, and the
sync-routines suite, so every PR's merge gate reads a verdict rather than `ABSENT`, a prompt-only
PR included. The third is unconditional for a reason of its own: the routines-table pin it carries
is broken by exactly the all-Markdown PR the classification calls prompt-only.

`check-prompts.sh` is the prompt hygiene check itself: every skill and routine `SKILL.md` opens
with YAML frontmatter carrying one `name`, equal to its directory, and one single-line
`description`, and every directory carrying a `SKILL.md` is named, in backticks, in the first cell
of a row of the README that indexes it — the skill table above, the routine table in
`routines/README.md`. That second half is a lookup, one fixed scan per directory, not a table
parser: it claims only that the name is written down as a row, not that the row renders, and it no
longer reads the other direction, a row that outlived its directory. The scanner it replaced drew
thirteen rounds of table-syntax edge cases in one review and reopened on every new rule
(ludics-lite#75). `test-check-prompts.sh` runs it against scratch trees, one per defect, with the
well-formed tree as the control, and ends by running it on this checkout.

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
`WAKE_LAB_DOWN_WAIT_SECONDS` are what let the suite ask for a one-second one).

`test-sync-routines.sh` runs `scripts/sync-routines.sh` against scratch trees, with
`CLAUDE_SCHEDULED_TASKS_DIR` pointed at them and over a byte-identical copy of the script inside a
scratch checkout, so a `pull` case can never reach the real `routines/`. It pins the four states
`status` reports and the exit code of each (in sync, drift, installed as a symlink, not
installed), that `push` replaces a symlinked installation with a real directory instead of writing
through it, that a destination reached through a link at any component *above* the routine
directory is refused as well — a symlinked `~/.claude` leaves every task directory real and the
whole tree unreadable — that `--dry-run` copies nothing in any mode, and the usage exits. It also pins what
ludics-lite#77 found unpinned: that the script's `LOCAL_ROUTINES` lists exactly the rows of
`routines/README.md` whose Kind is `local scheduled task`. That comparison reads the table
narrowly and refuses an empty read, so a mangled table cannot pass it vacuously, and four negative
controls show it can fail; `check-prompts.sh` keeps its per-directory lookup and gains no table
model. Two more cases pin what the comparison is worth: that the workflow job running this suite
carries no `if:`/`needs:`, since an all-Markdown PR is both what the classification calls
prompt-only and the one shape that can break the pin, and that the tracked mode of
`sync-routines.sh` is 755, which a `> tmp && mv` rewrite drops silently.

`test-pr-review-checks-absent.sh` drives the build gate against a canned Actions API, one answer
per polling round, and pins everything the check list alone cannot say about a head. Exit 4 (no
verdict): a queued or running workflow — including under a green check from a sibling workflow — a
run that completed stopped-not-judged with nothing behind it, a green check with no Actions run
behind it at all, and a checkless head still inside `SHIP_PR_BASE_ABSENT_GRACE`, measured from the
fresher of the commit date and the PR's `updated_at` (each validated on its own, so a long-local
commit pushed a moment ago counts as fresh and a future commit date does not blind the gate).
Exit 1: a run that concluded red without producing a check to be red, over a green, pending or
stopped check alike. Exit 0: green over a finished, judged run list, and the absence itself once
the grace is spent. A read that fails is exit 3, never a reassuring 0. Only finished runs are
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
tip, leaving stdout byte-identical to `poll`'s. `test-pr-review-base-drift.sh` pins the other
half: the drift count is anchored on the base's tip and never on the PR's `base.sha` snapshot,
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
findings at one line. Every verdict that
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
exits stay apart inside a batch — a 4xx rejected (1), anything else ambiguous (3).

`test-pr-review-base-red.sh` covers the other `base` — the one that answers "is the branch I am
about to work off green", and what it says once the answer is no (ludics-lite#73). A red names the
failing JOB and the commit the red starts at, and the cases pin the claims that could be quietly
wrong: a first red commit is named only when a judged run under the streak was not red (a window
red to its end says the red may start further back instead), a run that was cancelled or is still
going ends no streak because it judged nothing, two workflow files sharing a display name keep
their histories apart, a jobs read that fails prints UNKNOWN and leaves the red standing rather
than reporting no failing job, and a green base spends no call on any of it.

The nine `test-pr-review-*` suites share a preamble, `test-pr-review-lib.sh`, which sources
`pr-review.sh` for them and carries the reporter, the assertions, the scratch-directory cleanup and
the fixture `gh`'s argument parsing. It also closes the trap that bit twice (ludics-lite#39, #45,
#46): `pr-review.sh` puts some sixty unqualified functions in scope, and a suite helper sharing a
name — a reporter called `fail` — silently replaces the library's, turning every refusal's exit
code into the reporter's. So the preamble snapshots the function table when it is sourced, and
`run_tests` refuses, naming the function and where the suite redefined it, any library function
redefined without a `stub <fn>` declaration (the merge suite declares `build_checks`, `run_signal`
and `warn_base_drift`), and any declaration the suite never honoured. Run directly,
`test-pr-review-lib.sh` is its own suite: throwaway suites that source it prove the guard refuses
what it must and passes what it must.

The fixture suites pin the gate's logic against canned answers, so the shapes those answers imitate
are a belief the suites cannot check — a renamed field, a changed default ordering or a new
conclusion string leaves every fixture green and the gate reading a head wrong (ludics-lite#41).
`ship-pr/scripts/pr-review-api-contract.sh` asks this repository's own live API the same questions,
one jq read per belief, and reports each on its own line (`ok`, `MOVED` with the filter and the
read, or `skip` with the reason it cannot be checked here), so a failure localizes to the field
that moved; its exit code separates a moved belief (1), an addressed endpoint answering 4xx (4) and
a read the token was refused (5) from the API not answering or throttling (3), and the reporter
files everything but the last, naming which: the fields `run_signal`, `build_checks`, `run_red_is_advisory_only`, `pr_head_read`,
`warn_base_drift` and `status_state` index; the newest-first order of `actions/runs`; the status,
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
session start, `pr-review.sh base lukstafi/ludics-lite main`, runs daily (06:47 UTC, away from the
contract's slot) and on demand, and a scheduled run that finds a red — or a tip with no verdict at
all, or a check that broke — opens one issue naming the workflow, the failing job and where the red
starts, from a second job that checks nothing out and holds the only writing token. One issue per
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
