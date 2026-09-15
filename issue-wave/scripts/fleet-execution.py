"""Anchor-side execution records. Invoked by fleet-worker under its coordinator lock.

This records cooperative ownership; it neither launches nor supervises processes.

Argv: <state root> <action> <coordinator> <lease token> <json payload> <FLEET_BOXES>
      [<FLEET_BOX_CORRECTNESS_SLOTS>]

Ownership per execution host (ludics-lite#157): a `measurement` assignment is exclusive -- it
refuses while anything else is outstanding on the box, and everything refuses while it is. A
`correctness` assignment shares the box with other correctness assignments up to that box's
slot count (`<box>=<n>` pairs in the slots spec; one slot for any box the spec does not name).
"""
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from datetime import datetime, timezone


def refuse(message):
    raise ValueError(message)


def nonempty(obj, keys):
    for key in keys:
        if not isinstance(obj.get(key), str) or not obj[key].strip():
            refuse(f"{key} must be a nonempty string")


REQUEST_FIELDS = {"request_id", "wave", "worker", "transport", "issue", "purpose",
                  "agent_host", "execution_host", "repository", "requested_revision", "kind"}
STATES = {"reserved", "launching", "running", "uncertain", "concluded"}


def validate_request(data):
    if not isinstance(data, dict) or set(data) - REQUEST_FIELDS - {"triage_reason"}:
        refuse("unknown reservation fields or invalid request")
    nonempty(data, REQUEST_FIELDS)
    if "triage_reason" in data:
        nonempty(data, ["triage_reason"])
    if data["kind"] not in {"correctness", "measurement"}:
        refuse("kind must be correctness or measurement")
    if data["transport"] not in {"subagent", "app", "cli", "coordinator"}:
        refuse("invalid transport")


def validate_record(record, path):
    if not isinstance(record, dict):
        refuse(f"invalid execution record: {path}")
    nonempty(record, ["request_id", "coordinator", "lease_token", "state", "created_at", "updated_at"])
    if record["request_id"] != path.stem or record["state"] not in STATES:
        refuse(f"invalid execution record: {path}")
    validate_request(record.get("request"))
    if record["request"]["request_id"] != record["request_id"]:
        refuse(f"mismatched request identity: {path}")
    history = record.get("history")
    if not isinstance(history, list) or not history:
        refuse(f"missing execution history: {path}")
    for event in history:
        if not isinstance(event, dict) or not isinstance(event.get("data"), dict):
            refuse(f"invalid execution history: {path}")
        nonempty(event, ["at", "coordinator", "action"])
    for key in ("remote_checkout", "handle", "log", "observed_sha", "verdict", "halt_identity"):
        if key in record:
            nonempty(record, [key])
    if "observed_sha" in record and not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", record["observed_sha"]):
        refuse(f"invalid observed SHA: {path}")
    if record["state"] == "concluded":
        nonempty(record, ["verdict", "log"])
        if record["verdict"] not in {"pass", "fail", "timeout", "cancelled", "not-launched"}:
            refuse(f"invalid terminal verdict: {path}")
        if record["verdict"] != "not-launched":
            nonempty(record, ["observed_sha", "remote_checkout", "handle"])


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def halt_generation(marker):
    if marker is None:
        return None
    first_line = marker.splitlines()[0] if marker.splitlines() else ""
    match = re.match(r"^\S+ id=(\S+) ", first_line)
    # Also recognizes records saved by the earlier full-marker representation.
    return match.group(1) if match else first_line


def correctness_slots(spec, canonical_hosts):
    """`<box>=<n>` pairs; a box the spec does not name has one slot."""
    slots = {}
    for pair in spec.split():
        box, _, count = pair.partition("=")
        if not box or not count.isdigit() or int(count) < 1:
            refuse(f"FLEET_BOX_CORRECTNESS_SLOTS entry must be <box>=<positive n>: {pair}")
        if box not in canonical_hosts:
            refuse(f"FLEET_BOX_CORRECTNESS_SLOTS names {box}, which is not in FLEET_BOXES")
        slots[box] = int(count)
    return slots


def check_capacity(data, records, canonical_hosts, slots_spec):
    """Refuse when the requested host cannot take this assignment beside the outstanding ones."""
    host, kind = data["execution_host"], data["kind"]
    slots = correctness_slots(slots_spec, canonical_hosts)
    outstanding = [r for r in records.values()
                   if r["state"] != "concluded" and r["request"]["execution_host"] == host]
    if not outstanding:
        return
    owners = ", ".join(f"{r['request']['worker']} request={r['request_id']} coordinator={r['coordinator']}"
                       for r in outstanding)
    measuring = [r for r in outstanding if r["request"]["kind"] == "measurement"]
    if kind == "measurement":
        refuse(f"box owned by {owners} (measurement needs {host} to itself)")
    if measuring:
        refuse(f"box owned by {owners} (a measurement holds {host} exclusively)")
    cap = slots.get(host, 1)
    if len(outstanding) >= cap:
        refuse(f"box owned by {owners} (correctness slots {len(outstanding)}/{cap} on {host} taken)")


def main():
    root, action, coordinator, token, raw, boxes = sys.argv[1:7]
    slots_spec = sys.argv[7] if len(sys.argv) > 7 else ""
    directory = Path(root) / "executions"
    # A corrupt record blocks dispatch instead of silently making its box available.
    records = {}
    if directory.exists():
        for path in sorted(directory.glob("*.json")):
            record = json.loads(path.read_text())
            validate_record(record, path)
            records[path.stem] = record
    if action == "list":
        print(json.dumps(list(records.values()), indent=2))
        return
    data = json.loads(raw)
    if not isinstance(data, dict):
        refuse("request must be a JSON object")
    nonempty(data, ["request_id"])
    identity = data["request_id"]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", identity):
        refuse("invalid request_id")
    # APFS commonly preserves case but aliases filenames differing only by case.
    # Preserve existing mixed-case identities; never publish another spelling over them.
    if any(name.casefold() == identity.casefold() and name != identity for name in records):
        refuse("request_id collides with an existing identity by case")
    now = datetime.now(timezone.utc).isoformat()
    halt_path = Path(root) / "HALT"
    halt_identity = halt_generation(halt_path.read_text()) if halt_path.exists() else None
    if halt_identity is not None and not halt_identity.strip():
        refuse("invalid empty halt record")
    record = records.get(identity)
    events = []   # (action, data) pairs appended to the history, in order
    if action in {"reserve", "run", "dispatch"}:
        canonical_hosts = set(boxes.split())
        if not canonical_hosts:
            refuse("FLEET_BOXES must name the canonical fleet hosts")
        # A changed roster cannot silently erase ownership recorded under an old alias.
        # Keep reads and evidence/conclusion available to reconcile those records.
        for existing in records.values():
            if existing["state"] != "concluded" and existing["request"]["execution_host"] not in canonical_hosts:
                refuse(f"reconcile noncanonical execution host on request {existing['request_id']} before dispatch")
    if action in {"reserve", "run"}:
        # `run` is reserve + dispatch under one lock: the payload is the reservation, plus an
        # optional `evidence` for the dispatch step (ludics-lite: four calls per execution
        # were a third of a coordinator's tool calls on 2026-09-15).
        request = data
        dispatch_evidence = "reserved and dispatched in one step (execution run)"
        if action == "run":
            request = {k: v for k, v in data.items() if k != "evidence"}
            if "evidence" in data:
                nonempty(data, ["evidence"])
                dispatch_evidence = data["evidence"]
        validate_request(request)
        if request["execution_host"] not in canonical_hosts:
            refuse("execution_host must exactly match a canonical FLEET_BOXES entry")
        if record:
            if record["request"] != request:
                refuse("request_id already names a different assignment")
            if action == "reserve":
                sync_directory(directory.parent)
                sync_directory(directory)
                print(json.dumps(record, indent=2))
                return
            # A repeated `run` never repeats a launch: the connection that dropped after the
            # first one may have started the runner. Only a still-reserved own record proceeds.
            if record["state"] != "reserved":
                refuse(f"assignment already dispatched (state {record['state']}); reconcile, never run twice")
            if record["lease_token"] != token:
                refuse("adopted assignment must be reconciled before dispatch")
        else:
            halted = halt_identity is not None
            if "triage_reason" in request and not halted:
                refuse("triage reservations require an active halt")
            check_capacity(request, records, canonical_hosts, slots_spec)
            if halted:
                if "triage_reason" not in request:
                    refuse("fleet halted; ordinary reservations refused (only the named triage_reason reservation is admitted)")
                nonempty(request, ["triage_reason"])
                # One explicitly named exception, not an unrestricted force flag.
                if any(r["state"] != "concluded" and halt_generation(r.get("halt_identity")) == halt_identity for r in records.values()):
                    refuse("an outstanding triage assignment already exists")
            record = {"request_id": identity, "request": request, "coordinator": coordinator,
                      "lease_token": token, "state": "reserved", "created_at": now, "history": []}
            if "triage_reason" in request:
                record["halt_identity"] = halt_identity
            events.append(("reserve", request))
        if action == "run":
            triage = record["request"].get("triage_reason")
            if triage and (halt_identity is None or halt_generation(record.get("halt_identity")) != halt_identity):
                refuse("triage assignment belongs to a different or ended halt")
            if halt_identity is not None and not triage:
                refuse("fleet halted; ordinary dispatch refused")
            record["state"] = "launching"
            events.append(("dispatch", {"request_id": identity, "evidence": dispatch_evidence}))
    else:
        if record is None:
            refuse("unknown request_id")
        if set(data) - {"request_id", "state", "evidence", "observed_sha", "remote_checkout", "handle", "log", "verdict", "execution_host"}:
            refuse("unknown evidence fields")
        nonempty(data, ["evidence"])
        # Evidence read on a named box binds to the box that was reserved: a run record at the
        # same path on another machine cannot conclude this assignment.
        if "execution_host" in data:
            nonempty(data, ["execution_host"])
            if data["execution_host"] != record["request"]["execution_host"]:
                refuse(f"evidence from {data['execution_host']} cannot conclude an assignment reserved on {record['request']['execution_host']}")
            data = {k: v for k, v in data.items() if k != "execution_host"}
        if "verdict" in data and action != "conclude":
            refuse("verdict is only valid for conclude")
        if "state" in data and action not in {"record", "reconcile"}:
            refuse("state is only valid for record or reconcile")
        if record["state"] == "concluded":
            # Terminal records are immutable; retries of the final payload are harmless.
            if action == "conclude" and record["history"][-1]["data"] == data:
                sync_directory(directory.parent)
                sync_directory(directory)
                print(json.dumps(record, indent=2))
                return
            refuse("assignment already concluded")
        if action == "dispatch":
            if record["state"] != "reserved":
                refuse("dispatch requires reserved state; reconcile an uncertain launch")
            if record["lease_token"] != token:
                refuse("adopted assignment must be reconciled before dispatch")
            triage = record["request"].get("triage_reason")
            if triage and (halt_identity is None or halt_generation(record.get("halt_identity")) != halt_identity):
                refuse("triage assignment belongs to a different or ended halt")
            if halt_identity is not None and not triage:
                refuse("fleet halted; ordinary dispatch refused")
            state = "launching"
        elif action == "record":
            if record["state"] not in {"launching", "running", "uncertain"}:
                refuse("record requires dispatch; use reconcile for recovered execution evidence")
            state = data.get("state")
            if state not in {"running", "uncertain"}:
                refuse("record state must be running or uncertain")
        elif action == "reconcile":
            state = data.get("state")
            if state not in {"reserved", "running", "uncertain"}:
                refuse("reconcile state must be reserved, running or uncertain")
            # reserved means evidence establishes no launch occurred and no process can run.
            record["lease_token"] = token
        elif action == "conclude":
            nonempty(data, ["verdict", "log"])
            if data["verdict"] not in {"pass", "fail", "timeout", "cancelled", "not-launched"}:
                refuse("invalid terminal verdict")
            if data["verdict"] != "not-launched":
                nonempty({**record, **data}, ["observed_sha", "remote_checkout", "handle"])
            state = "concluded"
        else:
            refuse("unknown operation")
        if "observed_sha" in data and not re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", data["observed_sha"]):
            refuse("observed_sha must be an exact Git object ID")
        for key in ("observed_sha", "remote_checkout", "handle", "log", "verdict"):
            if key in data:
                nonempty(data, [key])
                record[key] = data[key]
        record["state"] = state
        events.append((action, data))
    record["updated_at"] = now
    for event_action, event_data in events:
        record["history"].append({"at": now, "coordinator": coordinator, "action": event_action, "data": event_data})
    directory.mkdir(exist_ok=True)
    # Sync even on retry: an earlier failed sync may have left the new directory visible.
    sync_directory(directory.parent)
    fd, temporary = tempfile.mkstemp(prefix=".execution-", dir=directory)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(record, stream, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, directory / (identity + ".json"))
        sync_directory(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    print(json.dumps(record, indent=2))


try:
    main()
except (ValueError, OSError, KeyError, TypeError) as exc:
    print(f"EXECUTION REFUSED: {exc}", file=sys.stderr)
    sys.exit(1)
