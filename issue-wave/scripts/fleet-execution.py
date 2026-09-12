"""Anchor-side execution records. Invoked by fleet-worker under its coordinator lock.

This records cooperative ownership; it neither launches nor supervises processes.
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


def main():
    root, action, coordinator, token, raw = sys.argv[1:]
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
    now = datetime.now(timezone.utc).isoformat()
    halt_path = Path(root) / "HALT"
    halt_identity = halt_path.read_text() if halt_path.exists() else None
    if halt_identity is not None and not halt_identity.strip():
        refuse("invalid empty halt record")
    record = records.get(identity)
    if action == "reserve":
        validate_request(data)
        if record:
            if record["request"] != data:
                refuse("request_id already names a different assignment")
            sync_directory(directory.parent)
            sync_directory(directory)
            print(json.dumps(record, indent=2))
            return
        halted = halt_identity is not None
        if "triage_reason" in data and not halted:
            refuse("triage reservations require an active halt")
        for existing in records.values():
            if existing["state"] != "concluded" and existing["request"]["execution_host"] == data["execution_host"]:
                refuse(f"box owned by {existing['request']['worker']} request={existing['request_id']} coordinator={existing['coordinator']}")
        if halted:
            nonempty(data, ["triage_reason"])
            # One explicitly named exception, not an unrestricted force flag.
            if any(r["state"] != "concluded" and r.get("halt_identity") == halt_identity for r in records.values()):
                refuse("an outstanding triage assignment already exists")
        record = {"request_id": identity, "request": data, "coordinator": coordinator,
                  "lease_token": token, "state": "reserved", "created_at": now, "history": []}
        if "triage_reason" in data:
            record["halt_identity"] = halt_identity
    else:
        if record is None:
            refuse("unknown request_id")
        if set(data) - {"request_id", "state", "evidence", "observed_sha", "remote_checkout", "handle", "log", "verdict"}:
            refuse("unknown evidence fields")
        nonempty(data, ["evidence"])
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
            if triage and (halt_identity is None or record.get("halt_identity") != halt_identity):
                refuse("triage assignment belongs to a different or ended halt")
            if halt_identity is not None and not triage:
                refuse("fleet halted; ordinary dispatch refused")
            state = "launching"
        elif action == "record":
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
    record["updated_at"] = now
    record["history"].append({"at": now, "coordinator": coordinator, "action": action, "data": data})
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
