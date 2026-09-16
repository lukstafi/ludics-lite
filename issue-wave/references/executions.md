# Coordinator-owned execution reservations

Use `fleet-worker.sh execution` for every worker correctness/test or measurement/experiment
execution on a fleet box and every coordinator integration run, with either provider and any
transport. This includes a CLI worker running tests on its own host, just as it includes a
native subagent driving that host over SSH. Agent residence never grants execution ownership. Python 3 is required on the anchor. State lives in `FLEET_ANCHOR_STATE/executions`,
under the existing coordinator lease lock. Use the same fleet environment as `claim`.

A `measurement` assignment is exclusive: it is refused while anything is outstanding on its
host, and everything is refused while it is outstanding. A `correctness` assignment shares its
host with other correctness assignments up to the box's slots - `FLEET_BOX_CORRECTNESS_SLOTS`,
`<box>=<n>` pairs, `mac-studio=6` with the default roster and one slot for any box it does not
name (ludics-lite#157: the exclusivity was written for measurement noise and for XProtect
serializing fresh test binaries, and three workers' targeted `-j 4` batches ran side by side on
the Mac without a stall once the Developer Tools exemption was in place; the WSL boxes keep one
slot because the dxg bridge is the limit there. Six, not three, since ludics-lite#160: the cap
bounds concurrent load on the box and must never bound how many agents may be in flight).

The count is a RUN-TIME count (ludics-lite#160). A reservation carrying `"standing": true` - a
correctness record held for a worker's whole life, review waits and idle included - consumes no
slot; it stays outstanding for everything else, so a measurement still needs the box to itself.
The slots are taken instead by `fleet-worker.sh execution slot [--wait <seconds>] -- <command>`,
which the worker runs on its own box around one suite or batch: it refuses while a measurement
is outstanding on that box, holds one of the box's N slots as a real flock for exactly as long
as the command runs (the kernel drops it even when the batch is killed), and returns the
command's own status. It needs no coordinator lease, takes no `--box` (the slot is the local
box's), and refuses with a line beginning `EXECUTION SLOT REFUSED` - exit 1 for no free slot,
a measurement or a malformed spec, 4 when the anchor's registry cannot be read. The command
after `--` is exec'd, not interpreted, so a pipeline or a shell builtin goes as `sh -c '...'`. Counting the
standing record instead had capped agents: on 2026-09-16 a fourth worker was refused a
reservation while the three holding mac-studio's slots were reading their briefs. Use one canonical box name from the site's roster consistently (for example `rog-nv-wsl`,
not an alternating SSH alias and app host ID). New reservations and dispatch require exact
`FLEET_BOXES` entries; aliases and case variants are refused. Configure one canonical entry per
physical box. Outstanding records outside a changed roster block dispatch until reconciled;
reads and evidence/conclusion remain available. No SSH alias discovery is performed. Choose placement using required hardware, current
load, outstanding assignments and available warm checkouts. Record the checkout actually used;
this does not introduce persistent verifier worktrees, sync, scheduling or remote agent launch.

`load` observes activity; reservations provide cooperative ownership. They do not stop unrelated
users, applications or scheduled sweeps. Before timing experiments inspect external activity and
wait when it compromises the measurement. Existing project runners continue to own process
locks, time limits, cancellation and logs. This interface never starts or stops a process.

## Reserve, launch, observe, conclude

The coordinator performs mutations; workers request assignments with issue/purpose, requested
revision, execution host and workload kind. Persist JSON payloads on the anchor board as evidence.
A reservation must exist before launch. For example `reserve.json`:

```json
{
  "request_id": "wave-issue123-cuda-1",
  "wave": "wave-20260912",
  "worker": "/root/issue123",
  "transport": "subagent",
  "issue": "owner/repo#123",
  "purpose": "bounded CUDA correctness verification",
  "agent_host": "mac-studio",
  "execution_host": "rog-nv-wsl",
  "repository": "owner/repo",
  "requested_revision": "<pushed-ref-or-exact-sha>",
  "kind": "correctness"
}
```

Run `fleet-worker.sh execution reserve <absolute-reserve.json>`, or - the usual shape -
`fleet-worker.sh execution run <absolute-reserve.json>`, which reserves and dispatches under one
lock and leaves the record `launching` (the payload may add `evidence` for the dispatch step).
`run` is not idempotent by design: a second `run` of a dispatched request is refused, because the
connection that dropped after the first may have started the runner; reconcile instead. A
conflicting request reports its current owner and changes nothing. Retrying identical request identity and fields returns
the existing assignment, including terminal state; a changed request with that ID is refused.
IDs that differ only by case collide and are refused, including on case-sensitive hosts.
Use a new ID for a genuinely new execution. `execution list` prints all records, including
history; it requires no coordinator identity. The creating coordinator and wave remain recorded
after adoption. Transport is `subagent`, `app`, `cli` or `coordinator`. Transport and `agent_host`
are provenance; exclusivity depends on `execution_host`, whether the agent is local or remote.
Provider is not an ownership key. The same issue may hold separate reservations on different
boxes. Planned placement is a default for iteration; agent capacity and issue dependency readiness
remain coordinator decisions outside this API.

Immediately before invoking the existing bounded project runner, use `execution dispatch` with
`{"request_id":"wave-issue123-cuda-1","evidence":"about to invoke project verifier"}`.
This rechecks the lease and halt under lock and changes `reserved` to `launching`. Nonzero means
no dispatch. This is a point-in-time gate, not atomic with the subsequent SSH/tool call. Record
pending launch before making the call, and never repeat a launch because the connection dropped.
If adoption or halt occurs in that gap, reconciliation must account for the possible execution.

Use `execution record` with the request ID, `state` (`running` or `uncertain`), and nonempty
`evidence`. This requires a dispatched assignment (`launching`, `running` or `uncertain`);
use explicit reconciliation for recovered prelaunch observations. Add `observed_sha` (exact Git SHA), `remote_checkout`, `handle`, and `log` as known.
SSH failure means uncertain execution, not a terminal failure. Elapsed time, agent completion
and worker hand-back do not free a box. Record the requested revision separately from the
observed SHA; the project's verifier determines whether the source/configuration is acceptable.

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
while an outstanding record refers to it, or while a pending assignment could still be using it.

## Standing iteration reservation

A worker's own targeted correctness batches on its agent host do not each need an assignment.
The coordinator takes one `kind: correctness` reservation per worker at launch (`execution run`,
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
refusal), runs the batch under it, and returns the batch's own status. The bare suites of a
repository whose runner is a plain script go through it the same way, one batch per call. This is what the
2026-09-15 coordinator ended up granting by message after sixteen request/assign/report
round-trips parked three workers idle between review rounds.

## Native Claude Code handoff

A Claude Code subagent cannot wait for a message mid-turn, so its handoff is turn-shaped: the
`EXECUTION_REQUEST` block ending a turn, `EXECUTION_ASSIGNED <id>` on resume by agent ID, and one
`EXECUTION_RESULT {json}` line ending the result turn, which `conclude --from-run` consumes. The
formats and the coordinator's side are in [native-claude.md](native-claude.md#worker-channel).

## CLI reservation handoff

A detached CLI worker cannot rely on a native message channel. Its self-contained brief names
absolute request and result paths under its worker state directory on its agent host. Before
fleet tests or experiments, it writes the requested revision, execution host, workload kind,
exact bounded command/batch, checkout and intended log path to the request file, prints
`EXECUTION_REQUEST <absolute-path>`, and ends its turn without starting that execution.

The coordinator observes the tracked `attach` exit, reads the file (over SSH when needed), and
confirms through `status` and process evidence that the CLI has stopped. Queue the request until
the execution host is available. Reserve it with `transport: "cli"` and the actual `agent_host`,
then call `execution dispatch`. Only after successful dispatch, resume that same session with
`fleet-worker.sh unstick <agent-box> <worker> --message <brief-file>`. The continuation names the
request ID, assigned command/batch, revision, checkout, log and result paths; it instructs the
worker to run only that assignment and return its actual runner handle, observed SHA, log and
terminal outcome in the result file, then exit again before additional fleet work. Start a new
tracked `attach` waiter and record the resume/runner evidence on the board.

Dispatch preceding the resume is a point-in-time gate just as it precedes an SSH runner call.
If resume fails or its outcome is unclear, retain ownership and reconcile whether anything
started; never blindly dispatch or resume twice. When the result turn ends, verify actual runner
termination and conclude with its evidence before resuming ordinary implementation/review.
A `DONE` turn with a request or result is an intermediate handoff, not issue completion. A new
execution needs a new request and reservation. CLI workers never mutate the coordinator lease
or reservation registry themselves. Native workers use their live coordinator message channel
for the same reserve/dispatch/evidence lifecycle.

## Adoption and halt

Lease adoption fences stale coordinator mutations; outstanding records survive. Read them and
reconcile runtime, Git and runner evidence before reusing their boxes. `execution reconcile`
requires request ID, evidence and state `reserved`, `running` or `uncertain`. Only use `reserved`
when evidence proves no execution began or can still begin; it acknowledges the new lease for a
later dispatch. Otherwise preserve uncertainty or conclude with verified terminal evidence.
Recording and concluding existing executions remain available during a halt for reconciliation.

A halt refuses ordinary reservations and dispatch. The one named regression-triage reservation
may include a nonempty `triage_reason` only while a halt is active; its dispatch is allowed
during the halt. Premarking ordinary reservations as future triage is refused. Each new halt receives a unique ID. Repeating `halt` to update its reason preserves that ID,
including after coordinator adoption; only resume followed by a new halt changes it. A triage assignment is bound to that halt and cannot
dispatch after it ends or during a later halt; its box stays reserved until reconciled. Only an
outstanding triage assignment for the current halt blocks its next triage reservation. This exception must correspond
to the board's named triage worker, not a general bypass for ordinary work.

Fixtures: `python3 issue-wave/scripts/test-fleet-execution.py` exercises actual temporary anchor
state and concurrent processes without SSH, accounts or hardware. For live validation reserve
one box, run one existing bounded verification command at a recorded SHA, retain the actual
handle/log/verdict and conclude. Lack of hardware access remains a validation gate, not evidence
of success. The bounded two-worker transport smoke is in [native-workers.md](native-workers.md).

## Bounded native Windows verification

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
inspection. An unconfirmed cleanup leaves the execution reservation uncertain; do not conclude
it merely from wrapper termination. This foreground runner does not supervise detached work
or replace the reservation protocol above.

Run `powershell -NoProfile -File issue-wave/scripts/test-windows-driver.ps1` (or `pwsh`) on
Windows. CI runs both engines, including a real inner Bash failure with the native exit accessor
forced to null, absent/trailing/stale verdicts, mismatched codes, and owned-tree timeout.
