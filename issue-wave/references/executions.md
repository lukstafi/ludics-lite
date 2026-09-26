# Coordinator-owned execution reservations

Use `fleet-worker.sh execution` for every worker correctness or measurement run on a fleet box
and every coordinator integration run, with either provider and any transport: a CLI worker
running tests on its own agent host exactly as much as a native worker driving that host over
ssh. Agent residence never grants execution ownership. Python 3 is required on the anchor, and
on every box that runs batches (`execution slot`'s lock is a python3 flock); the per-box
preflight checks it. State lives in `FLEET_ANCHOR_STATE/executions`, under the existing
coordinator lease lock. Use the same fleet environment as `claim`.

The vocabulary is SKILL.md's: a worker *requests*, the coordinator *reserves* (one record in
this registry), and the *assignment* is the message that resumes the worker with the reserved
command.

## Exclusivity and the run-time slots

A `measurement` reservation is for timing-grade claims, and for a run that needs the box to
itself (a [dual-boot reboot](#bounded-native-windows-verification) ends everything there). A
behaviour check that happens to print timings is `correctness`, and its timings are reported as
shared-box (2026-09-25: a warm-cache A/B whose claim was which arms replay asked for an exclusive
mac-studio measurement, impossible while a wave shares the box, and was reclassified). A
measurement is exclusive: it is refused while anything is outstanding on its host, and
everything is refused while it is outstanding. A `correctness` reservation shares its
host with other correctness reservations up to the box's slots - `FLEET_BOX_CORRECTNESS_SLOTS`,
`<box>=<n>` pairs, `mac-studio=6 rog-nv-linux=4 minix-amd-linux=4 tuf-amd-linux=3` with the
default roster and one slot for any box it does not name. The default roster is the default set of boxes, whether
`FLEET_BOXES` is unset or exports those same boxes (ludics-lite#329), and `fleet-worker.sh
preflight` prints the count for every roster box (ludics-lite#157: the exclusivity was written for
measurement noise and for XProtect serializing fresh test binaries, and three workers' targeted
`-j 4` batches ran side by side on the Mac without a stall once the Developer Tools exemption was
in place). Keep one slot for WSL boxes because of the measured dxg bridge limit. The native GPU
boxes' counts were measured with 1-4 concurrent compile-inclusive targeted batches, each box under
an exclusive reservation (ludics-lite#316, #344), at the width each batch runs at: four `-j 4`
batches on minix-amd-linux (16 hip-width at once was green three ways; only dune's default 32 has
drained its device-wide SDMA queue pool), three `-j 8` on tuf-amd-linux, and two `-j 8` cuda
batches on rog-nv-linux, where three or more hit `CUDA_ERROR_OUT_OF_MEMORY` in 2 of 6 rungs while
two ran clean beside two cc batches. OCANNL's `tools/test-run.sh` injects those widths into a
native batch that names none (ahrefs/ocannl#1033; `tools/box-jobs.sh` restates the counts, so the
two change together), so a worker passes no `-j` for them. The kind does not silently change the
configured slot count.

Where the bound is the GPU and not the box, some of the slots are GPU tokens (ludics-lite#391):
`FLEET_BOX_GPU_TOKENS`, the same `<box>=<n>` grammar, `rog-nv-linux=2` with the default roster,
and one per slot on any box it does not name. So rog-nv-linux runs four slots, and at most two
batches hold its 12 GiB GPU. It is fail-closed: every batch is a GPU batch unless it declares
`execution slot --cpu` (a CPU backend such as OCANNL's cc, or a repository with no GPU work;
`--gpu` states the default), so a GPU batch whose caller forgot to say so is still counted, and
a CPU batch that forgot only waits longer. The tokens are the first N slot files, not a second
pool: a batch the script before #391 started holds one of rog's first two slots, so it counts as
a token while a box's checkout moves between the versions. `preflight` shows the tokens beside
the slots wherever they are fewer, as `rog-nv-linux=4(gpu=2)`.

The slot count is a RUN-TIME count, and `execution slot` is the single run-time mechanism
(ludics-lite#160): every correctness run on a box, assigned or standing, is wrapped in
`fleet-worker.sh execution slot [--wait <seconds>] [--cpu|--gpu] -- <command>` on that box, so the box never
carries more than its slots however the runs were authorized. A reservation carrying
`"standing": true` - a correctness record held for a worker's whole life, review waits and idle
included - consumes no slot; it stays outstanding for everything else, so a measurement still
needs the box to itself. The registry's cap stays a bound on how many non-standing reservations
may be outstanding on a box and is deliberately NOT subtracted from the run-time slots: a run
refused because of a record that is not running, its own included, is the defect ludics-lite#160
removed (2026-09-16: a fourth worker was refused a reservation while the three holding
mac-studio's slots were reading their briefs; six slots, not three, for the same reason - the
cap bounds concurrent load, never how many agents may be in flight).

`execution slot` runs on the worker's own box around one suite or batch: it refuses while a
measurement is outstanding on that box, holds one of the box's N slots (a GPU token one, unless
`--cpu`) as a real flock for exactly as long as the command runs (the kernel drops it even when the batch is killed), and
returns the command's own status. It needs no coordinator lease, takes no `--box` (the slot is
the local box's), and refuses with a line beginning `EXECUTION SLOT REFUSED` - exit 1 for no
free slot or token, a measurement, a malformed spec or a local box name outside `FLEET_BOXES` (an alias
would lock and read measurements under a spelling of its own), 4 when the anchor's registry
cannot be read. Its lock files live under `FLEET_SLOT_STATE`
(`~/.local/state/fleet-execution-slots/<box>`), which is box-wide on purpose: `ISSUE_WAVE_STATE`
is each coordinator's own directory, and slots kept there would let two workers under different
coordinators each take slot 1 on one machine. The command after `--` is exec'd, not
interpreted, so a pipeline or a shell builtin goes as `sh -c '...'`.

## The OS-level sleep guard

On native Linux the lab locks are advisory: they bind sessions that go through `wake-lab.sh`,
and nothing at the OS level stopped another session's `wake-lab.sh sleep`, or an idle suspend,
from taking a box out from under a running worker (under WSL the Windows-side holder did that).
So every run on a box carries a logind **block** inhibitor on `sleep:idle` for exactly as long
as it runs (ludics-lite#317): `execution slot` runs its command inside
`fleet-worker.sh execution hold [--why <text>] -- <command>`, and an exclusive measurement,
which cannot take a slot, is invoked as `fleet-worker.sh execution hold -- <runner command>`.
`hold` takes nothing else - no slot, no registry read, no lease - and where there is no
`systemd-inhibit` (macOS, a Linux host without systemd) it runs the command bare and silently.
The inhibitor is held by a helper BESIDE the command, not by systemd-inhibit wrapped around it:
the command is exec'd on the caller's pid with its exit status and the slot flock unchanged,
and the inhibitor lives exactly as long as the flock does - until the last process of the
command's tree exits, however it ends, a `kill -9` of the command alone included.
`FLEET_SYSTEMD_INHIBIT` names the binary; the suites point it at a stub.

The mode is `block`, not `block-weak`: systemd 259's `systemctl --check-inhibitors=yes suspend`,
which is what `wake-lab.sh sleep` runs, refuses on any `block` inhibitor covering sleep, the
caller's own user included, while `block-weak` exempts the same user and so would not stop the
fleet's own `wake-lab.sh sleep` at all. logind itself also refuses a suspend request from anyone
without `suspend-ignore-inhibit` (auth_admin_keep on stock Ubuntu), which covers the GDM
greeter's power plugin on a box woken by WoL with nobody logged in.
`wake-lab.sh status` lists a native box's live sleep blocks (`sleep-blocks=<n>`, then one
`block:` line per holder), and a `sleep` refused by one names the holder and says `REFUSED`.

**Setup per native box.** An ssh session is a REMOTE subject to polkit, so
`org.freedesktop.login1.inhibit-block-sleep` falls under the action's `allow_any`, which stock
Ubuntu sets to `auth_admin_keep` (`allow_active` = yes covers only a local console session):
without a grant the request is denied ("Failed to inhibit: Access denied"), as it was on all
three boxes on 2026-09-23. The grant is `/etc/polkit-1/rules.d/50-fleet-inhibit.rules`, installed
by the Linux bootstrap, [`scripts/install-linux.md`](../../scripts/install-linux.md). Check it from an ssh session:
`pkcheck --action-id org.freedesktop.login1.inhibit-block-sleep --process $$; echo $?` prints 0.
On a box without it `hold` does not refuse the run - that would stop every batch there over a
setup step - but prints `EXECUTION HOLD <box>: WARNING: running WITHOUT a sleep inhibitor` with
the denial, and the run is unguarded.

Verified live on rog-nv-linux on 2026-09-23 (PR #323): with a `hold` running, `wake-lab.sh
status rog` showed `sleep-blocks=1` naming it, `wake-lab.sh sleep rog` printed `Operation
inhibited by "fleet-worker" ...` and `sleep REFUSED on rog by a block inhibitor` with exit 1,
the box stayed up, and `sleep-blocks` returned to 0 when the hold ended.

Idle suspend is off on the fleet's Ubuntu desktops without any site setting: Ubuntu's
`10_ubuntu-settings.gschema.override` sets `sleep-inactive-ac-timeout = 0` in a section with no
desktop qualifier, so it governs the GDM greeter as well as the logged-in session (upstream's
default is 900 seconds); `/etc/gdm3/greeter.dconf-defaults` leaves the power keys commented,
the greeter's dconf database carries none, and logind's `IdleAction` is `ignore`. Checked on
rog-nv-linux and minix-amd-linux on 2026-09-23 (both mini PCs without a battery; tuf, the one
laptop, adds battery and lid residue, in [linux-boxes.md](linux-boxes.md)). Recheck after a
release upgrade with `DCONF_PROFILE=/dev/null gsettings get
org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout` (0 is never); the inhibitor
is the guard either way, since logind refuses the greeter's suspend while it is held.

Use one canonical box name from the site's roster consistently (for example `rog-nv-linux`, not
an alternating ssh alias and app host ID). New reservations and dispatch require exact
`FLEET_BOXES` entries; aliases and case variants are refused. Configure one canonical entry per
physical box: ownership is keyed by the entry, so two aliases of one box would let a measurement
on one sit beside a run on the other. Reserve, run and dispatch refuse such a roster, naming both
entries and the box they share (ludics-lite#395). Which aliases are one box comes from
`wake-lab.sh endpoint-map`, the lab's `ENDPOINT_MAP` read as data, plus entries differing only by
case; ssh config aliases outside that map are not discovered. A checkout with no `wake-lab.sh`
prints an `EXECUTION WARNING` and checks exact entries only; one whose map is inconsistent refuses.
Outstanding records outside a changed roster block dispatch until reconciled; reads and
evidence/conclusion remain available under either refusal. Choose
placement using required hardware, current load, outstanding reservations and available warm
checkouts. Record the checkout actually used; this does not introduce persistent verifier
worktrees, sync, scheduling or remote agent launch.

`load` observes activity; reservations provide cooperative ownership. They do not stop
unrelated users, applications or scheduled sweeps. Before timing experiments inspect external
activity and wait when it compromises the measurement. Existing project runners continue to
own process locks, time limits, cancellation and logs. This interface never starts or stops a
process.

## Reserve, launch, observe, conclude

The coordinator performs mutations; workers request with issue/purpose, requested revision,
execution host and workload kind. Persist JSON payloads on the board as evidence. A reservation
must exist before launch. For example `reserve.json`:

```json
{
  "request_id": "wave-issue123-cuda-1",
  "wave": "wave-20260912",
  "worker": "/root/issue123",
  "transport": "subagent",
  "issue": "owner/repo#123",
  "purpose": "bounded CUDA correctness verification",
  "agent_host": "mac-studio",
  "execution_host": "rog-nv-linux",
  "repository": "owner/repo",
  "requested_revision": "<pushed-ref-or-exact-sha>",
  "kind": "correctness"
}
```

Run `fleet-worker.sh execution reserve <absolute-reserve.json>`, or - the usual shape -
`fleet-worker.sh execution run <absolute-reserve.json>`, which reserves and dispatches under one
lock and leaves the record `launching` (the payload may add `evidence` for the dispatch step).
`run` is not idempotent by design: a second `run` of a dispatched request is refused, because
the connection that dropped after the first may have started the runner; reconcile instead. A
conflicting request reports its current owner and changes nothing. Retrying identical request
identity and fields returns the existing reservation, including terminal state; a changed
request with that ID is refused. IDs that differ only by case collide and are refused,
including on case-sensitive hosts. Use a new ID for a genuinely new execution. `execution list`
prints all records, including history; it requires no coordinator identity. For routine
supervision use `execution list --active --compact`: `--active` excludes concluded records,
and `--compact` omits history and the lease token while retaining current ownership, request
and execution evidence fields. Both options are read-only and validate the entire ledger before
filtering; use the default full listing for history and reconciliation. The creating
coordinator and wave remain recorded after adoption. Transport is `subagent`, `app`, `cli` or
`coordinator`. Transport and `agent_host` are provenance; exclusivity depends on
`execution_host`, whether the agent is local or remote. Provider is not an ownership key. The
same issue may hold separate reservations on different boxes. Planned placement is a default
for iteration; agent capacity and issue dependency readiness remain coordinator decisions
outside this API.

For a reservation created with `reserve`, immediately before invoking the existing bounded
project runner use `execution dispatch` with
`{"request_id":"wave-issue123-cuda-1","evidence":"about to invoke project verifier"}`.
This rechecks the lease and halt under lock and changes `reserved` to `launching`. Nonzero means
no dispatch. This is a point-in-time gate, not atomic with the subsequent ssh or tool call.
Record the pending launch before making the call, and never repeat a launch because the
connection dropped. If adoption or halt occurs in that gap, reconciliation must account for the
possible execution.

`execution run` already performs dispatch; do not dispatch that reservation again. The assignment
must name its workload kind and command: **correctness** wraps the bounded project runner in
`execution slot`; an exclusively reserved **measurement** invokes the runner directly, without
that wrapper (ludics-lite#309), under `fleet-worker.sh execution hold -- <runner command>` alone,
the OS-level sleep guard `slot` also runs inside (ludics-lite#317, [below](#the-os-level-sleep-guard)).
The slot intentionally refuses every outstanding measurement,
including the assigned measurement itself. Keep that refusal: it protects the measurement from
concurrent correctness batches. Direct invocation still uses the project's time limits, logs and
process ownership; it does not skip the reservation, dispatch or external-activity check.

**The execution host's skills checkout** (ludics-lite#362). Only `launch` and `preflight` ever
fast-forwarded a box's `~/ludics-lite`, so a box the fleet only executes on kept a stale one:
tuf-amd-linux sat at `0f7de3d`, without `execution hold`, where a lane wrapped in it would have
exited 2. So every successful `run` or `dispatch` ends with `fleet-worker.sh refresh <execution
host>`, the preflight's own freshness check alone, and prints its one line on stderr: `REFRESH OK
<box> skills=<sha> (already current)` or `(fast-forwarded from <sha>)`; `REFRESH FAILED` with the
reason (a divergent checkout is reported and left as it is, never reset; the fetch, and the wait for
a preflight or another refresh holding the checkout's lock, are each capped by
`FLEET_REFRESH_TIMEOUT`, 30 s); or `REFRESH UNREACHABLE` for a box that did not answer (wake it,
then run `fleet-worker.sh refresh <box>`). It runs after the dispatch, outside the registry lock, so a hanging fetch holds no lock and
a refused reservation never touches a box that is measuring for someone else. The record on stdout
and the exit status are the dispatch's, whatever the refresh reports; read its line before sending
the assignment, since a FAILED or UNREACHABLE host runs whatever skill text it already has.

Use `execution record` with the request ID, `state` (`running` or `uncertain`), and nonempty
`evidence`. This requires a dispatched reservation (`launching`, `running` or `uncertain`); use
explicit reconciliation for recovered prelaunch observations. Add `observed_sha` (exact Git
SHA), `remote_checkout`, `handle`, and `log` as known. ssh failure means uncertain execution,
not a terminal failure. Elapsed time, a returned turn and a worker hand-back do not free a box.
Record the requested revision separately from the observed SHA; the project's verifier
determines whether the source/configuration is acceptable.

Once runner evidence establishes completion and no process remains, `execution conclude` accepts:

```json
{
  "request_id": "wave-issue123-cuda-1",
  "evidence": "runner terminal record retrieved; process stopped",
  "observed_sha": "0123456789012345678901234567890123456789",
  "remote_checkout": "/home/user/project-worktrees/verify",
  "handle": "project-runner-session-123",
  "log": "/home/user/logs/verify-123.log",
  "verdict": "pass"
}
```

When the run went through OCANNL's `tools/test-run.sh` (or any runner leaving `exit`, `log`,
`wt` and `cmd` under a run directory), `fleet-worker.sh execution conclude --from-run <run-dir>
--request <id> --sha <sha> [--box <execution host>] [--evidence <text>]` composes that payload
itself: the verdict from `exit` (0 pass, 142 timeout, a signal code cancelled, anything else
fail), `log` and the checkout from the record, the handle `test-run:<run>`, and `--sha` as the
observed SHA - the record carries none, so the revision that ran is the coordinator's to name
from the worker's result line, and the checkout must at least contain it; a checkout whose head
has moved on is concluded on the named revision with the drift noted in the evidence. It
refuses a record without a verdict and a run the checkout's own `tools/test-run.sh status` does
not call finished. The run directory is read on the reservation's execution host, resolved from
the registry when `--box` is omitted; the conclusion names the box it read, and the registry
refuses evidence read on any box but the reserved one.

The actual verdict must be `pass`, `fail`, `timeout` or `cancelled`. A timeout/cancellation needs
runner evidence that its processes stopped. SHA, checkout and handle may already be in the record;
evidence and log are required in the conclusion. If reconciliation proves nothing launched, use
`not-launched` with evidence and a reconciliation log. Terminal records are immutable; an identical
conclusion retry is harmless. There is no expiry or automatic release. Never remove a checkout
while an outstanding record refers to it, or while a pending reservation could still be using it.

## Standing iteration reservation

A worker's own targeted correctness batches on its agent host do not each need a request. The
coordinator takes one `kind: correctness` reservation per worker at launch (`execution run`,
request id `<wave>-<issue>-<host>-iterate`, `"standing": true`, purpose naming the bounded
aliases and `-j` width) and names it in the brief; the worker then runs those batches through
the project runner without asking, blocks on each inside its turn, and reports every run
directory. The reservation is concluded at hand-back with `conclude --from-run` on the last
batch's record. Measurement, cross-box legs and full suites still go through a request.

`"standing": true` is what exempts the record from the box's slot count, and it is explicit
rather than read off the `-iterate` id convention: a mistyped id must not silently escape the
cap, and `execution list` shows the exemption as a field. Only a correctness reservation may
carry it, and only as `true`. In exchange the worker wraps each batch in the run-time lock:

```
fleet-worker.sh execution slot -- tools/test-run.sh run <alias> -j 4
```

which blocks until one of the box's slots is free (`--wait`, default 600 seconds, then a
refusal), runs the batch under it, and returns the batch's own status. The `-j 4` is mac-studio's
width. On a native GPU box, omit it for a GPU batch: an explicit `-j` wins over the per-slot
width `tools/test-run.sh` injects there (ahrefs/ocannl#1033), so `-j 4` would halve rog's `-j 8`.
A batch that holds no GPU adds `--cpu` before the `--`, which on rog-nv-linux lets it run beside
the two GPU batches instead of waiting for their tokens. The bare suites of a
repository whose runner is a plain script go through it the same way, one batch per call
(2026-09-15: the coordinator ended up granting this by message after sixteen
request/assign/report round-trips parked three workers idle between review rounds).

## Native handoffs

A Claude Code native worker cannot wait for a message mid-turn, so its handoff is turn-shaped:
the `EXECUTION_REQUEST` block ending a turn, `EXECUTION_ASSIGNED <id>` on resume by agent ID,
and one `EXECUTION_RESULT {json}` line ending the result turn, which `conclude --from-run`
consumes; the formats and the coordinator's side are in
[native-claude.md](native-claude.md#worker-channel). A Codex native worker keeps its turn open
and messages instead ([native-codex.md](native-codex.md#worker-channel)).

## CLI reservation handoff

A detached CLI worker has no message channel to the coordinator. Its self-contained brief names
absolute request and result paths under its worker state directory on its agent host. Before
fleet tests or experiments, it writes the requested revision, execution host, workload kind,
exact bounded command/batch, checkout and intended log path to the request file, prints
`EXECUTION_REQUEST <absolute-path>`, and ends its turn without starting that execution.

The coordinator observes the tracked `attach` exit, reads the file (over ssh when needed), and
confirms through `status` and process evidence that the CLI has stopped. Queue the request until
the execution host is available. Reserve it with `transport: "cli"` and the actual `agent_host`,
then call `execution dispatch`. Only after successful dispatch, resume that same session with
`fleet-worker.sh unstick <agent-box> <worker> --message <brief-file>`. The continuation names the
request ID, assigned command/batch, revision, checkout, log and result paths; it instructs the
worker to run only that assignment and return its actual runner handle, observed SHA, log and
terminal outcome in the result file, then exit again before additional fleet work. Start a new
tracked `attach` waiter and record the resume/runner evidence on the board.

Dispatch preceding the resume is a point-in-time gate just as it precedes an ssh runner call.
If resume fails or its outcome is unclear, retain ownership and reconcile whether anything
started; never blindly dispatch or resume twice. When the result turn ends, verify actual runner
termination and conclude with its evidence before resuming ordinary implementation/review. A
`DONE` turn carrying a request or a result is a handoff, not issue completion (SKILL.md,
Supervise: *A returned turn means the turn ended*). A new execution needs a new request and
reservation. CLI workers never mutate the coordinator lease or reservation registry themselves.

## Adoption and halt

Lease adoption fences stale coordinator mutations; outstanding records survive. Read them and
reconcile runtime, Git and runner evidence before reusing their boxes. `execution reconcile`
requires request ID, evidence and state `reserved`, `running` or `uncertain`. Only use `reserved`
when evidence proves no execution began or can still begin; it acknowledges the new lease for a
later dispatch. Otherwise preserve uncertainty or conclude with verified terminal evidence.
Recording and concluding existing executions remain available during a halt for reconciliation.

A halt refuses ordinary reservations and dispatch. The one named regression-triage reservation
may include a nonempty `triage_reason` only while a halt is active; its dispatch is allowed
during the halt. Premarking ordinary reservations as future triage is refused. Each new halt
receives a unique ID. Repeating `halt` to update its reason preserves that ID, including after
coordinator adoption; only resume followed by a new halt changes it. A triage reservation is
bound to that halt and cannot dispatch after it ends or during a later halt; its box stays
reserved until reconciled. Only an outstanding triage reservation for the current halt blocks
its next triage reservation. This exception must correspond to the board's named triage worker,
not a general bypass for ordinary work.

Fixtures: `python3 issue-wave/scripts/test-fleet-execution.py` exercises actual temporary anchor
state and concurrent processes without ssh, accounts or hardware. For live validation reserve
one box, run one existing bounded verification command at a recorded SHA, retain the actual
handle/log/verdict and conclude. Lack of hardware access remains a validation gate, not evidence
of success. The bounded two-worker transport smoke is in [native-workers.md](native-workers.md#close-out-and-bounded-smoke).

## Bounded native Windows verification

Over ssh a `-win` box lands in cmd.exe, where `git --version` prints `.windows.` but a bare `bash`
is WSL's. Invoke Git Bash by path, as the driver below does, and have the script under test print
`uname -s` (`MINGW*`/`MSYS*`) and `git --version` (`.windows.`); for OCANNL keep
`tools/test-run.sh`'s record.

A dual-boot box in Ubuntu can be put into Windows first: `wake-lab.sh boot-windows
--as=<request_id> <box>` (from the anchor, under an exclusive `measurement` reservation on the box,
since the reboot ends everything running there; `--as` names that reservation, and any other
active one on the box refuses the reboot) reboots it into Windows for one boot and exits 0 only once its native Git
Bash answers; `wake-lab.sh boot-linux --as=<request_id> <box>` returns it, and `wake-lab.sh status <box>` then shows
`os=linux`. Exit 3 is `NEEDS A PERSON`: tell the user at once rather than retrying. The README's lab
section has the one-time sudoers grant each box needs. tuf is refused (no wired Wake-on-LAN).

Use `issue-wave/scripts/windows-driver.ps1` for a foreground Git Bash verifier on native
Windows. It extracts the corrected driver from the #671 verification evidence. For example:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:/tools/ludics-lite/issue-wave/scripts/windows-driver.ps1 `
  -ScriptPath C:/work/verify.sh -LogPath C:/evidence/run-123.log `
  -ErrorPath C:/evidence/run-123.err -CapSeconds 120
```

`BashPath` defaults to `C:/Program Files/Git/usr/bin/bash.exe`. Use a fresh pair of log paths
in an existing directory for every invocation. The driver prints its PID and cap, caches the
process handle before waiting, and on timeout calls `taskkill /PID <owned-pid> /T /F`.
The verifier must keep its child work in the foreground (wait for all children) and emit its
verdict as stdout's **last line**, after all output, then exit with that same status:

```bash
bash --noprofile --norc /c/work/check.sh
rc=$?
printf 'exit: %s\n' "$rc"
exit "$rc"
```

Do not let `set -e` skip verdict publication: capture the command's failure explicitly if
using it. The driver accepts only `exit: N` with N in 0..255, requires that record even when
Windows supplies a native exit code, and cross-checks the native code whenever non-null.
A null native code never implies success. It returns the recorded code, 124 for a confirmed
timeout cleanup, or 2 for incomplete/inconsistent evidence or runner errors. Logs remain for
inspection. An unconfirmed cleanup leaves the reservation uncertain; do not conclude it merely
from wrapper termination. This foreground runner does not supervise detached work or replace
the reservation protocol above.

Run `powershell -NoProfile -File issue-wave/scripts/test-windows-driver.ps1` (or `pwsh`) on
Windows. CI runs both engines, including a real inner Bash failure with the native exit accessor
forced to null, absent/trailing/stale verdicts, mismatched codes, and owned-tree timeout.
