# Coordinator-owned execution reservations

Use `fleet-worker.sh execution` for remote worker legs and coordinator integration with any
transport. Python 3 is required on the anchor. State lives in `FLEET_ANCHOR_STATE/executions`,
under the existing coordinator lease lock. Use the same fleet environment as `claim`.

There is one exclusive active assignment per execution host, for correctness and measurement
alike. Use one canonical box name from the site's roster consistently (for example `rog-nv-wsl`,
not an alternating SSH alias and app host ID). Choose placement using required hardware, current
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

Run `fleet-worker.sh execution reserve <absolute-reserve.json>`. A conflicting request reports
its current owner and changes nothing. Retrying identical request identity and fields returns
the existing assignment, including terminal state; a changed request with that ID is refused.
IDs that differ only by case collide and are refused, including on case-sensitive hosts.
Use a new ID for a genuinely new execution. `execution list` prints all records, including
history; it requires no coordinator identity. The creating coordinator and wave remain recorded
after adoption. Transport is `subagent`, `app`, `cli` or `coordinator`.

Immediately before invoking the existing bounded project runner, use `execution dispatch` with
`{"request_id":"wave-issue123-cuda-1","evidence":"about to invoke project verifier"}`.
This rechecks the lease and halt under lock and changes `reserved` to `launching`. Nonzero means
no dispatch. This is a point-in-time gate, not atomic with the subsequent SSH/tool call. Record
pending launch before making the call, and never repeat a launch because the connection dropped.
If adoption or halt occurs in that gap, reconciliation must account for the possible execution.

Use `execution record` with the request ID, `state` (`running` or `uncertain`), and nonempty
`evidence`. Add `observed_sha` (exact Git SHA), `remote_checkout`, `handle`, and `log` as known.
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

The actual verdict must be `pass`, `fail`, `timeout` or `cancelled`. A timeout/cancellation needs
runner evidence that its processes stopped. SHA, checkout and handle may already be in the record;
evidence and log are required in the conclusion. If reconciliation proves nothing launched, use
`not-launched` with evidence and a reconciliation log. Terminal records are immutable; an identical
conclusion retry is harmless. There is no expiry or automatic release. Never remove a checkout
while an outstanding record refers to it, or while a pending assignment could still be using it.

## Adoption and halt

Lease adoption fences stale coordinator mutations; outstanding records survive. Read them and
reconcile runtime, Git and runner evidence before reusing their boxes. `execution reconcile`
requires request ID, evidence and state `reserved`, `running` or `uncertain`. Only use `reserved`
when evidence proves no execution began or can still begin; it acknowledges the new lease for a
later dispatch. Otherwise preserve uncertainty or conclude with verified terminal evidence.
Recording and concluding existing executions remain available during a halt for reconciliation.

A halt refuses ordinary reservations and dispatch. The one named regression-triage reservation
may include a nonempty `triage_reason` only while a halt is active; its dispatch is allowed
during the halt. Premarking ordinary reservations as future triage is refused. Each halt receives a unique ID. A triage assignment is bound to that halt and cannot
dispatch after it ends or during a later halt; its box stays reserved until reconciled. Only an
outstanding triage assignment for the current halt blocks its next triage reservation. This exception must correspond
to the board's named triage worker, not a general bypass for ordinary work.

Fixtures: `python3 issue-wave/scripts/test-fleet-execution.py` exercises actual temporary anchor
state and concurrent processes without SSH, accounts or hardware. For live validation reserve
one box, run one existing bounded verification command at a recorded SHA, retain the actual
handle/log/verdict and conclude. Lack of hardware access remains a validation gate, not evidence
of success. The bounded two-worker transport smoke is in [native-codex.md](native-codex.md).
