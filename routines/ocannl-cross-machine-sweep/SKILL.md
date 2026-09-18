---
name: ocannl-cross-machine-sweep
description: Daily OCANNL test sweep, one concurrent lane per box - cc/metal locally, cuda on rog-nv, hip/multidev_cc on minix
---

Run the OCANNL cross-machine test sweep and report failures, especially what changed since the previous sweep.

GitHub CI covers exactly one backend — `test/config/ocannl_config` pins `backend=cc` and the runners have no GPU. Metal, CUDA,
HIP — and multidev_cc, which needs no hardware but is deliberately kept off CI to keep the per-PR
matrix fast (gh-ocannl-756; the decision is recorded at the runtest step in `.github/workflows/ci.yml`) —
have no automated coverage except this sweep, so this routine is the ONLY gate for all five of
those backends. The sweep places them on three boxes: cc and metal on this Mac (`m4-max`), cuda on
`rog-nv-wsl`, and hip then multidev_cc on `minix-amd-wsl` — the CPU pair is split across macOS and
Linux on purpose (load balance, and cross-OS coverage of the CPU backends). So minix carries TWO
backends: a minix that stays down leaves both hip and multidev_cc uncovered. Throughout this
routine, "the box's backends" means all of them — rog: cuda; minix: hip AND multidev_cc — and every
outcome step 1 reports BEFORE the sweep (no wake, no WSL, a failed restart) is reported for each
backend on that box. What happens DURING the sweep is per unit instead: minix runs hip and then
multidev_cc, so a VM can vanish after hip recorded a real result; judge each backend by its own row,
and only a unit that recorded `skip (unreachable)` is uncovered. The CUDA box (rog-nv-wsl) and HIP box
(minix-amd-wsl) are often hibernated, and sometimes powered off; step 1 tries to wake them, but if that fails,
"skip (unreachable)" is a normal outcome, not an error. CI's Windows OS target is likewise off the per-PR path: it runs only on the
twice-weekly scheduled CI sweep, and on demand via `workflow_dispatch`, because at 62-74min it
set the latency of the whole per-PR matrix.

## 0. Check you are running the current prompt

Before waking anything, run the drift check in the ludics-lite checkout, which is where this prompt is canonical:

    git -C ~/ludics-lite fetch --quiet origin \
      && git -C ~/ludics-lite rev-parse --abbrev-ref HEAD \
      && git -C ~/ludics-lite rev-list --left-right --count HEAD...origin/main \
      && git -C ~/ludics-lite status --porcelain -- routines scripts/sync-routines.sh
    ~/ludics-lite/scripts/sync-routines.sh

`scripts/sync-routines.sh` with no argument is status mode: one line per local scheduled task, and exit 1 on any drift. Read your own line. `ocannl-cross-machine-sweep: DRIFT` means the prompt the scheduler dispatched — the one you are reading now — is not the one the checkout holds, so the steps below may be a superseded revision; the diff it prints says in what, though not which side is the newer one — its orientation is argument order, and step 6 says how to read that from provenance instead. It is not hypothetical: on 2026-09-17 the installed copy was found nineteen lines of superseded prose behind, still telling the run to wake the lab without `--hold`, and it had been that way for about a week (ludics-lite#199).

Status mode compares the installed copies with THIS checkout, not with `origin/main`, so a checkout behind the remote reports `in sync` while the installed prompt is older than what merged. `rev-list --left-right --count HEAD...origin/main` prints `<ahead> <behind>`. **Canonical**, once, since everything below turns on it: the checkout is canonical when the branch is `main`, the counts are `0 0`, and the `status --porcelain` line printed NOTHING. Only then does it hold exactly what merged, and only then may anyone install from it. A nonzero BEHIND means it is missing prompts that merged. A nonzero AHEAD, any other branch, or a dirty `routines/` or `scripts/sync-routines.sh` means it carries text that has not been through review — the script is in the pathspec because the next command RUNS it, and a local edit to its routine list, its destination or its publishing logic installs a state nobody reviewed — and `sync-routines.sh` compares the working tree, so uncommitted text reads as the checkout being newer and would be published as-is. Installing from a non-canonical checkout is a worse failure than the drift it would be fixing: the scheduler would then be running something nobody reviewed. Against `origin/main` by name, not `git status -sb`: the checkout may be on a topic branch or one with no upstream, whose tracking state says nothing about `main`. The `&&` is deliberate too — a failed fetch (auth, DNS, network) prints no counts at all, and that absence is the answer: the remote comparison is UNKNOWN, not clean, because stale remote-tracking refs would show a checkout matching the installed copies as up to date. Report the fetch failure in its place.

Carry on with the sweep either way — a drifted prompt still runs a useful sweep, and the coverage window is the thing that must not be missed — but report the finding in step 5 and notify on it in step 6. Do NOT run `sync-routines.sh push` and do not edit the installed copy: those are live scheduler state, and re-installing a prompt is a person's call made after reading the diff. Where the two disagree about a step below, this prompt is what the scheduler gave you; say so and follow it.

## 1. Wake the GPU boxes

The sweep talks to the WSL sides (`rog-nv-wsl`, `minix-amd-wsl`); waking and liveness go through
the Windows sides. A box can be fully awake on `-win` while `-wsl` is still absent, so "the machine
is up" and "the backend is testable" are different claims.

One command does the whole thing, and is safe to run unconditionally — packets to an
already-running box are a no-op, and the WSL restart is wanted either way (below):

    ~/bin/wake-lab.sh --wait --restart-wsl --hold rog minix

It sends the wake-on-LAN packets (router-side and direct), polls for up to 4 minutes, then restarts
WSL on whichever boxes came up — WSL never autostarts at boot, so starting it is not optional — and
waits up to 3 minutes for `tailscaled` inside the VM to register. Do not hand-roll the
probe-then-branch logic it replaces; a partial wake (one box up, one dead) is handled — the live
box still gets its WSL kick.

`--hold` also takes that box's **hold lock** (one of the two interlocks `--restart-wsl` consults)
and leaves it with the holder, so while a box is held another session's `restart-wsl` is REFUSED —
naming this holder — instead of destroying the VM under it with a host-global `wsl.exe --shutdown`.
`unhold` releases the lock along with the holder. That is the other half of the 2026-09-16 story:
one loss was the update restart, the other was a second session restarting WSL under a running
unit.

There are two locks per box and this run takes one of each, at different times, which is what lets
step 1 and step 2 belong to the same session:

- `<box>.hold.lock`, the **hold lock** — "this box's VM must not be destroyed". Step 1's `--hold`
  takes it, the Windows-side holder carries it, and `unhold` in step 2 releases it.
- `<box>.lock`, the **lane lock** — "no other lane runs on this box". The sweep takes it in step 2,
  per box, for the length of that box's lane, and the hold deliberately does not touch it.

`restart-wsl` and the power verbs take both and refuse the box if either is held. Do not expect
step 1's hold to keep the sweep out of its own boxes: before 2026-09-18 it did exactly that — one
file said both things, so every remote lane waited out its five-minute lock budget against this
routine's own holder and skipped, and three of the five backends this routine gates got no
coverage at all that day (ludics-lite#224). If you ever see `skip (box <box> reserved by wake-lab
--hold ...)`, that regression is back: report it as the finding, because it means the run held the
boxes against itself.

`--hold` is what keeps each GPU lane's VM alive for the whole lane. A WSL VM is held up by a
`wsl.exe` process on the WINDOWS side and by nothing else; the sweep's ssh sessions inside the
guest do not hold it, and the owner's console shell — the process that usually does — is removed by
a Windows Update restart. `--hold` spawns `wsl.exe -d Ubuntu -e sleep infinity` on each box's
Windows side, reports it, and declares the VM up only once that process is observed there. It is
never sized with a fixed `sleep N`: a lane is hip then multidev_cc, each with its own cap, plus
preparation outside them, so a sized holder expires under the last unit. **You must end it
explicitly** once the sweep has finished (step 2), for every box you held:

    ~/bin/wake-lab.sh unhold rog minix

Name only the boxes THIS run held — the ones whose `wsl holder observed on <box>` line you read in
step 1. The record is per box and global to the machine, so `unhold` on a box you did not hold
would release whatever holder is there, and if another run put it there you would unhold its lane.
Run that even when the sweep failed or a box never woke — `unhold` over a box with no holder says
so and exits 0. `wsl HOLD FAILED on: <box>` in the last lines means the VM started but nothing on
the Windows side holds it, and the line says which of two situations that is:

- `...so it was shut down again: those units record no coverage` — the VM this command created is
  gone, you need do nothing by hand, and that box's units will record `skip (unreachable)`. Report
  its backends as untestable today, the same as `wsl still down` below.
- `...the VM is up and UNHELD and was not shut down: do not sweep that box` — the guest is still
  reachable, so the lanes WILL run its units and those units can die mid-run. This is the shape the
  recovery rerun below can produce. Do not launch the sweep for that box: report its backends as
  untestable, and say in the report that an unheld guest was left running.

It always terminates. Every remote command it issues runs under a wall-clock cap, and the boxes
are restarted concurrently, so it cannot sit on a wedged `wsl.exe` the way it did on 2026-09-16 —
2h40m in one start probe, which hung this sweep behind it and cost the second box its restart
entirely. If it has not returned in about a quarter of an hour, that is a bug in the script and
not a slow box.

Read its last lines:

- `did NOT wake: <box>` is **not** an error: that box's backends (rog: cuda; minix: hip and
  multidev_cc) simply go uncovered today, surfacing through the staleness thresholds in step 4. Do not send the wake command again.
- `wsl still down after 3 min` on a box that woke means the machine is up but that box's backends (minix: both) are
  untestable — say so explicitly in the report, since it is a different finding from a box that
  never woke.
- `no host table at ~/.config/wake-lab/hosts.sh`: nothing was woken and nothing will be. That
  file is this box's untracked site configuration for the script (the top-level README of
  ludics-lite says how to install it); report the missing setup as the finding rather than the
  boxes as unreachable.
- `all up`, `wsl up` and `wsl holder observed on <box>`: start the sweep promptly. A VM kicked on a
  cold-booted box does not stay up on its own, and a session inside it does not hold it — the
  holder `--hold` spawned does, until you `unhold`.
- `ACTIVE HOURS WARNING on <box>`: the box's Windows Update active hours do not cover the sweep
  window, so an update restart can take the VM, its holder and the unit with it mid-run (that is
  how the 2026-09-15 sweep lost hip twice). Both boxes pin `ActiveHoursStart=6`, `ActiveHoursEnd=0`
  with `SmartActiveHoursState=0` under `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings`; a
  feature update can reset that, and the warning is the only notice. Sweep anyway — it is a
  warning, not a refusal — and report it in step 5 as a risk to tomorrow's run, with a task chip to
  re-pin the values on that box.
- `--restart-wsl` rather than `--wsl`: it is harmless (on a cold-booted box the shutdown is a
  no-op) and it keeps the daily GPU units on a VM of known age. Do NOT read it as protection
  against the dxg `vmbus_sendpacket failed: fffffff5` refusals: ludics-lite#60 read those as a VM
  kept alive across host resumes, and on 2026-09-15 three FRESH VMs overflowed the same way at
  dune's default width while the same VMs were clean at `-j 2`. Concurrency decides that class,
  and OCANNL's `unit_jobs` cap (`minix:hip -> 2`) is the fix that holds.
  `wsl restart FAILED on: <box>` in the last lines means no fresh VM there — the line says
  whether the shutdown was refused (a `-wsl` that still answers is the old VM) or the start
  failed after it (no VM at all) — so that box's backends (minix: hip and multidev_cc both) are untestable today: report it as such rather
  than sweeping it. Each such line names only the boxes it applies to.
- `wsl restart REFUSED on: <box>` is a different line and a different situation: **another tool is
  using that box right now**, and the refusal names it. `wsl.exe --shutdown` is host-global, so
  restarting a box mid-sweep destroys the VM under whatever is running there — on 2026-09-16 that
  cost this sweep both GPU units, and the failure was read as a GPU fault for two days. Almost
  always the holder is another sweep that has not finished, or a `--hold` holder another session
  left behind. Wait for it and run the wake command again; do **not** reach for `--force`, which
  takes the box anyway and is there for a holder that has demonstrably gone (a crashed run whose
  ssh is still orphaned), not for one you are impatient with. If you wait, say in the report that
  the run started late and why. One holder it can never name is this run's own: the command that
  prints this line is the one that would have taken the locks, and it took none.

`~/bin/wake-lab.sh status` prints the per-box picture (router-active, `-lan`, `-win`, `-wsl`) if you need to
say precisely what happened.

The sweep takes each WSL box's lane lock for the length of that box's lane, and `wake-lab.sh`
refuses to destroy a box either of whose locks is held, so the 2026-09-16 collision cannot repeat
silently. Two consequences to know. A unit recorded as `skip (box <box> reserved by ...)` is a box
ANOTHER run's lane held for longer than the sweep was willing to wait: nothing was tested and
nothing failed, so report it the way `skip (unreachable)` is reported, naming the holder. (A
holder line reading `wake-lab --hold` there is the regression above, not another run.) And a dxg
window whose verdict is
`vm-replaced` means the guest was destroyed and recreated while that unit ran — the unit's result
says nothing about the code, it gets the serial rerun automatically, and the thing to investigate
is who restarted the box, not the backend.

The retry budget is exactly one re-kick and one rerun. If the sweep records cuda, hip or multidev_cc as
`skip (unreachable)` while `status` shows that box `win=UP`, the VM was up and vanished: run
`~/bin/wake-lab.sh kick-wsl --hold <box>` once — **with `--hold`**, or the rerun runs an unheld VM
the way the 2026-09-15 recovery rerun did, and it died 76 s in — then rerun the sweep once (reruns
are incremental and cheap) and `~/bin/wake-lab.sh unhold <box>` when it finishes. The re-kick takes
only that box's hold lock, so the rerun's own lane still reserves the box normally; before
ludics-lite#224 this recovery reproduced the skip exactly, taking the same lock the lane then
waited on, which is why a rerun that skips for `reserved by wake-lab --hold` means the fix has
regressed rather than that the box is busy. If the unit still skips, report it as "woken but
`-wsl` gone" (step 4 names this outcome) and do not kick or rerun again.

Everything else about these boxes — WoL over Ethernet only, waking from a full shutdown, what
`router-active=1` means, what actually holds a kicked VM up (a Windows-side `wsl.exe`, which is
what `--hold` supplies), Tailscale unattended mode, the `exit 0` vs `true`
probe trap — is verified and recorded in the header comment of `scripts/wake-lab.sh` in
ludics-lite, which is what `~/bin/wake-lab.sh` links to and what `~/bin/wake-lab.sh --help`
prints; do not spend the run rediscovering it.

Do not power the boxes back down afterwards — the user may want them for the day's work, and the
next sweep can always wake them again.

## 2. Run the sweep

Always use origin/master's copy of the script, the checkout is sometimes on a WIP branch. The
script is NOT standalone: it resolves siblings relative to its own directory
(`tools/aggregate-skips.sh`, and `benchmarks/fixture_digest.py` for the measurement-box matrix),
so a lone copy of `tools/sweep.sh` dies with exit 2 before testing anything. Extract the two
directories together from master instead of copying one file:

    mkdir -p ~/.ocannl-sweep
    git -C ~/ocannl-staging fetch -q origin master
    rm -rf ~/.ocannl-sweep/tools ~/.ocannl-sweep/benchmarks
    git -C ~/ocannl-staging archive origin/master tools benchmarks | tar -x -C ~/.ocannl-sweep

The `mkdir` is not redundant on a box where the sweep has run before: `tar -C` requires the
directory to exist, and `~/.ocannl-sweep` is also the script's state directory
(`OCANNL_TOOL_SWEEP_STATE`), so a fresh host, or one where it was cleared, has none.

If a future master grows a dependency outside those two directories, the failure is an exit 2
during startup: today the missing sibling is reported by the interpreter's own error above the
`sweep:` line (`cannot parse measurement boxes at <sha>` is what the script itself says when
`benchmarks/fixture_digest.py` is not there), so read both lines, not just the `sweep:` one.
Widen the pathspec in the `git archive` line above (that is the whole fix), then relaunch once.

The script refuses to run without `OCANNL_TOOL_SWEEP_LOCAL_BOX`, the portable measurement-box ID
of THIS host — one of the names on the `# measurement-boxes:` line of
`benchmarks/fixtures/DIGESTS.txt` (currently `m4-max minix rog-nv`). It deliberately will not
infer that identity from the hostname or CPU model (either can name a different machine the same
way), so the binding is per-host site configuration, one line in
`~/.config/ocannl-sweep/local-box` (on this Mac, the Apple M4 Max, it says `m4-max`). Do not
hardcode a box name in this routine: read the file, and treat its absence exactly like the missing
`~/.config/wake-lab/hosts.sh` in step 1 — the setup is the finding, nothing was swept, and it is
notify-worthy (step 6):

    box=$(cat ~/.config/ocannl-sweep/local-box 2>/dev/null)
    [ -n "$box" ] || { echo "no box ID at ~/.config/ocannl-sweep/local-box; nothing swept" >&2; exit 1; }

If that fires, DO NOT launch the sweep. An empty `OCANNL_TOOL_SWEEP_LOCAL_BOX` is not "let the
script decide": it dies with the same exit 2 as any other unusable environment, which reads like
something the corrected relaunch below could fix and is not. Release step 1's holders first
(`~/bin/wake-lab.sh unhold rog minix`) — they are already running by then, nothing else ends them,
and this path never reaches the cleanup below — then go straight to step 5 and report the missing
site configuration as the finding, and notify in step 6. The same goes for any other exit from
this step that never launches the sweep: unhold before you leave it.

A typo in the file is caught by the script itself: it checks that every declared box has a sweep
unit, so a misspelled local ID dies with `declared measurement box 'm4-max' has no sweep unit`.

Then, if today is Sunday, run the weekly full check
`OCANNL_TOOL_SWEEP_LOCAL_BOX=$box OCANNL_TOOL_SWEEP_CAP=10800 ~/.ocannl-sweep/tools/sweep.sh --slow --force`;
otherwise `OCANNL_TOOL_SWEEP_LOCAL_BOX=$box ~/.ocannl-sweep/tools/sweep.sh`. `--force` is what makes a unit record `pass` with `execution=forced`
(a `dune clean` plus alias `--force`, so every test action genuinely re-executes); a weekday run
is incremental and records `incremental-pass`, which is evidence about the changed cone but does
not refresh execution coverage. The raised cap is for the forced runs only: a cold rebuild plus
`@slow` legitimately exceeds the default 90-minute unit cap, and cutting it short would file lost
coverage as `timeout`.
Run it in the background and wait for it to finish — a cold unit can take tens of minutes.
Each box's units run as one lane, and the three lanes run concurrently (gh-ocannl-976): the remote
units start within seconds of launch, and the run lasts as long as its longest lane — normally this Mac's, which carries metal's suite. The stdout header's `lanes:` line names each
box's units. Units on different boxes finish in any order, so their summary blocks and their
history rows appear in completion order, not in the order this routine lists them.
The script deliberately exits 0 even when tests
fail; its exit code tells you nothing about test results, so do not read anything into it. Read
the results from the history file instead.

The ONE exit code that does carry meaning is 2, and it comes in two kinds; tell them apart by the
`sweep:` line before doing anything else. The startup kind: the script found its launch environment
unusable (a `sweep: ...` line on stderr says why) and stopped BEFORE testing anything, on any
machine. A startup exit 2 is therefore a whole day of non-coverage for all five backends, not a test result:
read the `sweep:` line first, and relaunch only if it names something this routine can correct
from the instructions above (a missing box ID, a stale or incomplete extraction, "another sweep is
running"). Do not retry the same command hoping for a different answer — the 2026-09-05 run burned
a second attempt on that before recognizing the failure. Whatever the outcome of the single
corrected relaunch, a startup exit 2 is reported in step 5 as non-coverage and notified in step 6.

The lane-stopped kind comes AFTER testing: `sweep: lane(s) stopped before finishing: <box> (exit
N)` means a lane could not write a history row or unit state (the lane's own `sweep:` line above
says which) and stopped, while the other lanes ran to completion. This is a PARTIAL sweep, not an
absent one: the rows the run did write, today's `when` stamp in the history file, are real
results, and steps 3–5 process them exactly as for a completed run — a failure in a lane that
finished is news like any other. Units without a row, which only the stopped lane can have, are non-coverage; any row
the stopped lane did write is a result like the rest, and no
skip-coverage report was written. Do not relaunch for it: an unwritable state directory is the
finding, and it is notify-worthy.

When you leave this step — however that happens: the run finished, it died at startup, or one of
the refusals above sent you to step 5 without launching anything — release the holders step 1
took:

    ~/bin/wake-lab.sh unhold rog minix

Nothing else ends them: the holder is `sleep infinity` precisely so that it cannot expire under the
last unit, so a lane that is never unheld leaves a `wsl.exe` pinning the VM (and an ssh connection
from this Mac) until the box reboots. Do it before the retry budget's rerun too, or take the rerun's
own `kick-wsl --hold` over the still-held box — `kick-wsl --hold` reuses a live holder rather than
stacking a second one.

## 3. Diff against the previous sweep

Read `~/.ocannl-sweep/history.tsv` (columns: when, machine, backend, ref, outcome, seconds,
target, slow, log, execution). Passing outcomes are `pass` (forced execution), `incremental-pass`
(a weekday run; cache hits possible) and `legacy-pass` (rows migrated from before the execution
column existed).
For every unit in today's run whose outcome is not one of those, compare
`~/.ocannl-sweep/logs/<stamp>-<machine>-<backend>.fingerprint` against the fingerprint of that
same unit's most recent PREVIOUS non-pass run. Only a DIFFERENCE is news.

The `machine` column holds the measurement-box ID, so rows and filenames from before 2026-09-05
spell the same units `local` (now `m4-max`) and `rog` (now `rog-nv`); `minix` is unchanged. When
looking for a unit's previous non-pass run, match on `backend` and accept the old machine spelling
of its fingerprint filename.

multidev_cc also MOVED, from this Mac to minix (gh-ocannl-976): its older rows and fingerprints say
`m4-max`/`local`, its newer ones `minix`. Match it on `backend` across both, but read the first
minix failures with that in mind: a multidev_cc unit that is red on minix while its last `m4-max`
rows were green may be a Linux-only finding the move newly exposed rather than a regression of
master — still news, and worth a task chip, but say which it looks like (does cc on this Mac pass
the same tests? is the failing golden platform-sensitive?). The sweep's own per-unit cursor is
keyed by machine, so its `REGRESSION OR FIX DID NOT TAKE` and `fingerprint moved` lines start
fresh for minix/multidev_cc and cannot flag that first transition; this diff is what catches it.

A unit going from `pass` to `fail`, or a new entry appearing in a fingerprint, IS news.

A forced full-suite run (Sunday) also writes `~/.ocannl-sweep/logs/<stamp>-skip-coverage.txt` —
the intersection of backend-scoped `Verdict.skipped` claims across every unit that recorded
`pass` (gh-ocannl-792). Read it: its `result:` line is the verdict (`PASS`/`CLEAR` are green;
`POTENTIAL` means some claim was skipped on every backend that completed, with backends absent;
`FAIL` means a claim was skipped on all five backends — that claim has ZERO execution coverage
anywhere; `NOT AGGREGATED` means fewer than two backends completed, so the question could not be
asked — report that as non-coverage of the coverage question itself, not as green). The sweep's
stdout also quotes the `result:` line and each `FAIL:`/`POTENTIAL:` finding, indented under its
`skip coverage:` line. Compare the FAIL/POTENTIAL claim set against the most recent previous
`*-skip-coverage.txt`, the same way fingerprints are diffed: a claim appearing or escalating
(POTENTIAL → FAIL) is news. A weekday incremental run writes no report and says
`skip coverage: not aggregated` — that is normal, not a finding.

## 4. Staleness

Age only FULL-SCOPE passes: a row counts toward coverage only if its `target` column is `<all>`.
A row with a narrower target came from a manual smoke run that executed a fraction of the suite,
and treating it as coverage would certify tests that never ran. Likewise, when judging whether
slow coverage is current, count only rows with `slow` = 1.

And age a backend only by rows from the box that runs it NOW — the one today's `lanes:` header line
puts it on — normalizing only the historical renames of the same box (`local` → `m4-max`, `rog` →
`rog-nv`). A backend that moved boxes has not been covered on its new box until a row there says
so: multidev_cc's `m4-max`/`local` passes do not count toward its liveness or its 14-day forced
check once the sweep runs it on minix, so the move shows as stale until minix records its own pass
and forced pass — which is the point, since the move exists to add coverage that had never run.
Failure comparison in step 3 still matches across the move; only aging is per box.

Two distinct ages per backend, because a green incremental run and a genuinely re-executed suite
are different claims:
- **Liveness**: the most recent full-scope passing row of ANY passing outcome (`pass`,
  `incremental-pass`, or `legacy-pass` while those age out). This is the "is the sweep working
  and is the backend green" age, thresholded below.
- **Execution coverage**: the most recent full-scope `pass` row with `execution=forced`. Flag any
  backend whose last forced pass is more than 14 days old (the Sunday `--force` cadence plus one
  missed week) — incremental greens in between may be cache hits and cannot stand in for it.

For each of the FIVE backends (cc, multidev_cc, metal, cuda, hip) find the most recent qualifying
liveness row. Flag backends with no pass in more than 2 days. For cuda, hip or multidev_cc (the
backends on the WSL boxes), say which of the three step-1 outcomes applied: woken
  and swept; woken but `-wsl` never appeared or was gone again by the time the unit probed it
  (machine up, that unit untestable — only the units whose row says `skip (unreachable)`, while a
  unit that ran before the VM vanished keeps its result — step 1's holder is what prevents this,
  so a vanished VM also means either the hold failed or it was never asked for; a re-kick with
  `--hold` plus an incremental rerun usually recovers it); or the wake itself failed. A failed wake with settled `router-active=1` means the NIC was
  powered and listening, so the magic packet was ignored: the WoL option itself (BIOS, or the
  Windows NIC driver's wake settings) has been lost. With settled `router-active=0` the NIC is not powered while the
  box is off: the cable, the box's power, or the BIOS setting that keeps the NIC powered in S5.

## 5. Report

Print a short summary: one line per unit (machine/backend, outcome, duration), preceded by a line
on what step 1 did if any box needed waking. Open with step 0's drift verdict, in one line when
everything is in sync and with the diff when it is not (plus the branch, the `rev-list` counts and every path the
`status --porcelain` line printed when the checkout is not canonical — the sync script's own path
included, which no sync diff would show — or the fetch's error if that comparison could not be made,
and any `RETIRED, but still installed` warning with the two steps the script names for it) — a check whose silence and whose absence look alike is not a check. Then either "no change since the last sweep" or the
specific new failures with the relevant log excerpt (the full log path is in the history row —
quote a few lines, do not paste the whole thing). On a forced run, also include the skip-coverage
`result:` line and every `FAIL:`/`POTENTIAL:` claim from today's report, plus the report path —
these are the zero-coverage findings this routine is the only channel for.

Outcomes are `pass`, `incremental-pass`, `legacy-pass`, `fail`, `skip`, `timeout` and `error`.
`error` means the harness could not
put that machine's worktree on the commit under test, so NOTHING was tested there — report it as
non-coverage rather than as a test failure, and treat it as notify-worthy. For an `error` (or a
`skip (unreachable)`) on a GPU box, check whether the box restarted under it before diagnosing the
harness: System event 1074 on the `-win` side inside the unit's window, from `MoUsoCoreWorker.exe`
or `TrustedInstaller.exe`, is a Windows Update restart, which takes the VM and its holder with it.

    ssh rog-nv-win "powershell -NoProfile -Command \"Get-WinEvent -FilterHashtable @{LogName='System';Id=1074;StartTime=(Get-Date).AddHours(-12)} | Format-List TimeCreated,Message\""

(`minix-amd-win` for minix — those two, and the `-lan` aliases, are the Windows destinations;
`wake-lab.sh` names the one that answered when it kicked the box.)

Report that as an update restart, name the active-hours values step 1 read, and file the fix as
re-pinning active hours on that box — not as a backend regression. If the script itself
exits 2 at startup, no sweep happened at all: report that as the finding and do not read the history
file as though the run had completed. A lane-stopped exit 2 (step 2) is the exception: report every row the run
recorded — the stopped lane's own included, since it may have finished a unit (minix's hip) before
stopping — including any new failures among them, as this step describes, and report only the
units with no row as non-coverage. The same applies when this routine never got as far as launching
it because `~/.config/ocannl-sweep/local-box` is missing: report the missing site configuration,
not the backends.

## 6. Notify

Send a PushNotification ONLY if there is (a) a new failure or timeout, (b) a staleness flag,
(c) a skip-coverage `FAIL`, or a FAIL/POTENTIAL claim set that differs from the previous report's,
(d) step 0 reporting DRIFT on this routine's own prompt, a checkout that is not canonical as
step 0 defines it, or a remote comparison it could not make at all — each says this run may have executed
instructions that have been superseded, and nothing else on this box notices; an installed prompt that
matches an equally stale checkout reads `in sync` and is exactly as wrong,
or (e) an `error` outcome, a script exit of 2, or a launch refused for a missing
`~/.config/ocannl-sweep/local-box`: nothing was tested there, which step 5 already
calls notify-worthy, and it must not go silent for being neither a failure nor yet stale.
A `FAIL` notifies even when unchanged — it fires at most weekly (forced runs only) and means some
claim has zero execution coverage on every backend, which must keep reaching a human until fixed;
an unchanged POTENTIAL set stays silent like an unchanged fingerprint.
Drift — and a checkout that is not canonical, and a fetch that failed — notifies every day it lasts, for
the same reason: each says this run may have followed superseded instructions, only a person can end it,
and it is silent everywhere else — the 2026-09-17 instance went a
week unseen. Name the direction from PROVENANCE, never from the diff's orientation (`sync-routines.sh` always diffs
the checkout first, so the `-` side is the checkout whether it is the stale one or not; the checkout's
`git log` for that prompt is what says which text landed and when). Put THAT in the notification, never a
fixed command, and never a `push` out of a
checkout step 0 did not find canonical — that installs unreviewed text, and the notification is read by
someone who will run what it says. So: `pull` whenever the INSTALLED copy holds the newer text (a run
that edited its own prompt in place — a push would destroy the only copy of that edit), canonical or
not, since a pull writes into the checkout where `git diff` shows it and review still stands between it
and the scheduler; `push` when the checkout holds the newer text AND step 0 found it canonical; and no
command at all — just what is wrong — when the checkout holds the newer text but is not canonical, or
when both sides have moved — or when another local routine's drift points the OTHER way, since
`push` and `pull` take no routine argument and apply to every local routine at once, so one of the two
would be destroyed.
A green sweep, or a red-but-unchanged sweep, must stay silent — a notification that fires every
day is one that gets ignored, which would defeat the point. A box that failed to wake is not by
itself notify-worthy; it becomes so only through the staleness thresholds above.

Do NOT fix anything, do NOT commit, do NOT run `dune promote`. However, create a task chip for each failure/finding that has a diagnostic. The task is to fix the regression if the fix is localized, file an ahrefs/ocannl issue if the fix would involve design work.
If the sweep script itself errors out (missing repo, cannot resolve the ref), report that as the
finding and stop.