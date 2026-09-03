---
name: ocannl-cross-machine-sweep
description: Daily OCANNL test sweep across cc/multidev_cc/metal locally and cuda/hip on the GPU boxes
---

Run the OCANNL cross-machine test sweep and report failures, especially what changed since the previous sweep.

GitHub CI covers exactly one backend — `test/config/ocannl_config` pins `backend=cc` and the runners have no GPU. Metal, CUDA,
HIP — and multidev_cc, which needs no hardware but is deliberately kept off CI to keep the per-PR
matrix fast (gh-ocannl-756; the decision is recorded at the runtest step in `.github/workflows/ci.yml`) —
have no automated coverage except this sweep, so this routine is the ONLY gate for all five of
those backends. The CUDA box (rog-nv-wsl) and HIP box
(minix-amd-wsl) are often hibernated, and sometimes powered off; step 1 tries to wake them, but if that fails,
"skip (unreachable)" is a normal outcome, not an error. CI's Windows OS target is likewise off the per-PR path: it runs only on the
twice-weekly scheduled CI sweep, and on demand via `workflow_dispatch`, because at 62-74min it
set the latency of the whole per-PR matrix.

## 1. Wake the GPU boxes

The sweep talks to the WSL sides (`rog-nv-wsl`, `minix-amd-wsl`); waking and liveness go through
the Windows sides. A box can be fully awake on `-win` while `-wsl` is still absent, so "the machine
is up" and "the backend is testable" are different claims.

One command does the whole thing, and is safe to run unconditionally — packets to an
already-running box are a no-op, and so is the WSL kick:

    ~/bin/wake-lab.sh --wait --wsl rog minix

It sends the wake-on-LAN packets (router-side and direct), polls for up to 4 minutes, then starts
WSL on whichever boxes came up — WSL never autostarts at boot, so `--wsl` is not optional — and
waits up to 3 minutes for `tailscaled` inside the VM to register. Do not hand-roll the
probe-then-branch logic it replaces; a partial wake (one box up, one dead) is handled — the live
box still gets its WSL kick.

Read its last lines:

- `did NOT wake: <box>` is **not** an error: that backend simply goes uncovered today, surfacing
  through the staleness thresholds in step 4. Do not send the wake command again.
- `wsl still down after 3 min` on a box that woke means the machine is up but the backend is
  untestable — say so explicitly in the report, since it is a different finding from a box that
  never woke.
- `no host table at ~/.config/wake-lab/hosts.sh`: nothing was woken and nothing will be. That
  file is this box's untracked site configuration for the script (the top-level README of
  ludics-lite says how to install it); report the missing setup as the finding rather than the
  boxes as unreachable.
- `all up` and `wsl up`: start the sweep promptly. A VM kicked on a cold-booted box does not
  always stay up on its own; once a unit's ssh session is running inside it, it does.

`~/bin/wake-lab.sh status` prints the per-box picture (link, `-lan`, `-win`, `-wsl`) if you need to
say precisely what happened.

The retry budget is exactly one re-kick and one rerun. If the sweep records cuda or hip as
`skip (unreachable)` while `status` shows that box `win=UP`, the VM was up and vanished: run
`~/bin/wake-lab.sh kick-wsl rog minix` once, then rerun the sweep once — reruns are incremental
and cheap. If the unit still skips, report it as "woken but `-wsl` gone" (step 4 names this
outcome) and do not kick or rerun again.

Everything else about these boxes — WoL over Ethernet only, waking from a full shutdown, what
`link=1` means, the cold-boot kicked-VM trap, Tailscale unattended mode, the `exit 0` vs `true`
probe trap — is verified and recorded in the header comment of `scripts/wake-lab.sh` in
ludics-lite, which is what `~/bin/wake-lab.sh` links to and what `~/bin/wake-lab.sh --help`
prints; do not spend the run rediscovering it.

Do not power the boxes back down afterwards — the user may want them for the day's work, and the
next sweep can always wake them again.

## 2. Run the sweep

Always use origin/master's copy of the script, the checkout is sometimes on a WIP branch:

    mkdir -p ~/.ocannl-sweep
    git -C ~/ocannl-staging fetch -q origin master
    git -C ~/ocannl-staging show origin/master:tools/sweep.sh > ~/.ocannl-sweep/sweep.sh
    chmod +x ~/.ocannl-sweep/sweep.sh

Then, if today is Sunday, run the weekly full check
`OCANNL_TOOL_SWEEP_CAP=10800 ~/.ocannl-sweep/sweep.sh --slow --force`; otherwise
`~/.ocannl-sweep/sweep.sh`. `--force` is what makes a unit record `pass` with `execution=forced`
(a `dune clean` plus alias `--force`, so every test action genuinely re-executes); a weekday run
is incremental and records `incremental-pass`, which is evidence about the changed cone but does
not refresh execution coverage. The raised cap is for the forced runs only: a cold rebuild plus
`@slow` legitimately exceeds the default 90-minute unit cap, and cutting it short would file lost
coverage as `timeout`.
Run it in the background and wait for it to finish — a cold unit can take tens of minutes.
The script deliberately exits 0 even when tests
fail; its exit code tells you nothing about test results, so do not read anything into it. Read
the results from the history file instead.

## 3. Diff against the previous sweep

Read `~/.ocannl-sweep/history.tsv` (columns: when, machine, backend, ref, outcome, seconds,
target, slow, log, execution). Passing outcomes are `pass` (forced execution), `incremental-pass`
(a weekday run; cache hits possible) and `legacy-pass` (rows migrated from before the execution
column existed).
For every unit in today's run whose outcome is not one of those, compare
`~/.ocannl-sweep/logs/<stamp>-<machine>-<backend>.fingerprint` against the fingerprint of that
same unit's most recent PREVIOUS non-pass run. Only a DIFFERENCE is news.

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

Two distinct ages per backend, because a green incremental run and a genuinely re-executed suite
are different claims:
- **Liveness**: the most recent full-scope passing row of ANY passing outcome (`pass`,
  `incremental-pass`, or `legacy-pass` while those age out). This is the "is the sweep working
  and is the backend green" age, thresholded below.
- **Execution coverage**: the most recent full-scope `pass` row with `execution=forced`. Flag any
  backend whose last forced pass is more than 14 days old (the Sunday `--force` cadence plus one
  missed week) — incremental greens in between may be cache hits and cannot stand in for it.

For each of the FIVE backends (cc, multidev_cc, metal, cuda, hip) find the most recent qualifying
liveness row. Flag backends with no pass in more than 2 days. For cuda or hip, say which of the three step-1 outcomes applied: woken
  and swept; woken but `-wsl` never appeared or was gone again by the time the unit probed it
  (machine up, backend untestable — the cold-boot kicked-VM trap in step 1; a re-kick plus an
  incremental rerun usually recovers it); or the wake itself failed. A failed wake with `link=1` means the NIC was
  powered and listening, so the magic packet was ignored: the WoL option itself (BIOS, or the
  Windows NIC driver's wake settings) has been lost. With `link=0` the NIC is not powered while the
  box is off: the cable, the box's power, or the BIOS setting that keeps the NIC powered in S5.

## 5. Report

Print a short summary: one line per unit (machine/backend, outcome, duration), preceded by a line
on what step 1 did if any box needed waking. Then either "no change since the last sweep" or the
specific new failures with the relevant log excerpt (the full log path is in the history row —
quote a few lines, do not paste the whole thing). On a forced run, also include the skip-coverage
`result:` line and every `FAIL:`/`POTENTIAL:` claim from today's report, plus the report path —
these are the zero-coverage findings this routine is the only channel for.

Outcomes are `pass`, `incremental-pass`, `legacy-pass`, `fail`, `skip`, `timeout` and `error`.
`error` means the harness could not
put that machine's worktree on the commit under test, so NOTHING was tested there — report it as
non-coverage rather than as a test failure, and treat it as notify-worthy. If the script itself
exits 2, no sweep happened at all: report that as the finding and do not read the history file as
though the run had completed.

## 6. Notify

Send a PushNotification ONLY if there is (a) a new failure or timeout, (b) a staleness flag,
(c) a skip-coverage `FAIL`, or a FAIL/POTENTIAL claim set that differs from the previous report's,
or (d) an `error` outcome or a script exit of 2: nothing was tested there, which step 5 already
calls notify-worthy, and it must not go silent for being neither a failure nor yet stale.
A `FAIL` notifies even when unchanged — it fires at most weekly (forced runs only) and means some
claim has zero execution coverage on every backend, which must keep reaching a human until fixed;
an unchanged POTENTIAL set stays silent like an unchanged fingerprint.
A green sweep, or a red-but-unchanged sweep, must stay silent — a notification that fires every
day is one that gets ignored, which would defeat the point. A box that failed to wake is not by
itself notify-worthy; it becomes so only through the staleness thresholds above.

Do NOT fix anything, do NOT commit, do NOT run `dune promote`. However, create a task chip for each failure/finding that has a diagnostic. The task is to fix the regression if the fix is localized, file an ahrefs/ocannl issue if the fix would involve design work.
If the sweep script itself errors out (missing repo, cannot resolve the ref), report that as the
finding and stop.