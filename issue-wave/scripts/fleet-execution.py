"""Anchor-side execution records. Invoked by fleet-worker under its coordinator lock.

This records cooperative ownership; it neither launches nor supervises processes.

Argv: <state root> <action> <coordinator> <lease token> <json payload> <FLEET_BOXES>
      [<FLEET_BOX_CORRECTNESS_SLOTS> [<endpoint map> [<anchor> <lab host>]]]

Ownership per execution host (ludics-lite#157): a `measurement` assignment is exclusive -- it
refuses while anything else is outstanding on the box, and everything refuses while it is. A
`correctness` assignment shares the box with other correctness assignments up to that box's
slot count (`<box>=<n>` pairs in the slots spec; one slot for any box the spec does not name).

A correctness request may carry `"standing": true` (ludics-lite#160): a standing iteration
record is the ownership/evidence record of a worker's whole life, taken at launch and concluded
at hand-back, so it consumes no slot -- the slots are taken at run time by
`fleet-worker.sh execution slot`, around each batch. It is still outstanding for every other
purpose, so a measurement keeps the box to itself.

One roster entry per physical box (ludics-lite#395). Ownership is keyed by the exact
FLEET_BOXES entry, so a roster naming two aliases of one box (`rog-nv-linux` and `rog-nv-wsl`)
would admit a measurement on one beside a run on the other, and the exclusivity above -- which
`wake-lab.sh boot-windows --as=<request_id>` relies on -- would split silently. So reserve, run and
dispatch refuse such a roster, naming both entries and the box they share; reads and
evidence/conclusion stay available, as for a noncanonical outstanding host. What is one box is read
from the endpoint map argument, `wake-lab.sh endpoint-map` as fleet-worker passes it: one line per
box, the box name and then its ssh aliases. The boundary, fail-closed within it: two roster
entries are one box when the map puts both on one row (the box name counts as one of its row's
aliases), or when they differ only by case, as ssh lowercases a host name before matching its
config; a map naming one alias on two rows is refused whole. It deliberately does not read
~/.ssh/config: two `Host` stanzas pointing at one HostName outside the map are not detected. An
empty or absent map argument keeps today's behaviour (each entry is its own box, up to case);
fleet-worker passes one only when its checkout has no wake-lab.sh, and says so on stderr.

A coordinator's correctness request may carry `"integration": true` (ludics-lite#401): the run is
the repository's full integration suite at a merged tip, and once concluded pass or fail at an
exact `observed_sha` it is the verdict source `fleet-worker.sh gate` offers `pr-review.sh base`
for a default branch without push CI. The field is what tells it from a targeted batch, which is
a correctness run too; the gate reads no record without it.

A measurement refuses a box a sweep lane holds (ludics-lite#445). OCANNL's daily sweep owns no
record here; what says a lane is running on a lab box is that box's LANE lock, the flock
`<lock dir>/<box>.lock` it takes for the length of the lane (`wake-lab.sh`'s lab lock lore). So a
`measurement` reserve, run or dispatch takes that lock SHARED and non-blocking, refuses naming the
holder's first line (e.g. `ocannl sweep <stamp> (pid ..., since ...)`) when it is held, and keeps
it until this process exits, after the record is written. The lane takes it EXCLUSIVE and reads
this registry before each unit only once it holds it, and every destroyer in wake-lab.sh takes it
EXCLUSIVE before it reads this registry too, so neither can slip between this check and the record
it guards. What it reads, and nothing else: the box is the endpoint map row naming the execution
host (the map argument above; a host on no row, or no map at all, is not a lab box and has no lane
lock), and the lock directory is THIS process's -- WAKE_LAB_LOCK_DIR, else
~/.local/state/wake-lab, the default wake-lab.sh and the sweep share. That directory is the lab's
only on the machine that runs wake-lab.sh and the sweep; anywhere else it holds no lane's lock and
every measurement would pass. So before reading it, a measurement on a lab box verifies that this
anchor is that machine, and refuses naming both when it is not (ludics-lite#454). Two facts, and
nothing else: the anchor's fleet name and the lab host's (the last two arguments, FLEET_ANCHOR and
FLEET_LAB_HOST as fleet-worker resolves them) are one name up to case, which catches an anchor
moved without the lab or a lab moved and declared; and the wake-lab site file -- WAKE_LAB_HOSTS,
else ~/.config/wake-lab/hosts.sh, what wake-lab.sh refuses to drive the lab without -- is a
readable file here, which catches a declaration naming a machine that cannot drive the lab. It
resolves no alias, reads none of the file's contents, and cannot see a sweep moved to another
box that has a site file of its own but was never declared: the declaration is that fact's only
source. Absent identity arguments refuse. WAKE_LAB_LOCK_DIR and WAKE_LAB_HOSTS are read from THIS
process's environment -- the anchor's, as its own wake-lab.sh and sweep would see them -- and never
forwarded from the coordinator's: a coordinator's path names a file on the coordinator's machine. A
custom path is set where the anchor's non-interactive ssh shell reads it. The box's HOLD
lock is not read: a hold keeps a VM alive and says nothing about who works there. A lock file that
cannot be created or opened is free, as wake-lab.sh treats it (no lane can hold what it cannot open:
the sweep fails such a lane rather than running it); one that opens but cannot be probed refuses.
Correctness reservations never read the lock.

The measurement window (ludics-lite#481). Every native worker holds a standing correctness record on
its agent host for its whole life, and a measurement is refused while anything is outstanding on its
box, so a measurement on a wave's agent host was never admitted until the coordinator concluded every
standing record there `cancelled` (a conclusion describing no run), measured, and took fresh ones
under invented ids. `window` (payload `{"box": <box>, "request": <measurement reserve.json>}`) does
it under this one lock: it refuses unless everything outstanding on the box is standing, writes the
measurement as `run` does (reserved and dispatched, `"window": true` on the record), then moves each
standing record there to state `suspended`, naming the measurement in `suspended_by` and its former
state in `suspended_from`. Concluding that measurement, whatever the verdict, first restores every
record it suspended to its former state and then writes the conclusion, so no record is ever left
suspended by a concluded measurement. A standing reservation taken while a window is open is admitted
straight into `suspended` by it (queued, not refused: the worker's launch does not wait for the
window). A suspended record takes no dispatch, record or reconcile -- the window owns its state --
but may be concluded, which is how a worker handing back mid-window ends it. A retried `window` with
the same request never dispatches twice: it suspends any standing record not yet suspended and prints
the record. There is one measurement per window, so the registry still never holds two outstanding
measurements on a box (`execution slot`'s in-hold admission, ludics-lite#480, relies on that).
"""
import fcntl
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
STATES = {"reserved", "launching", "running", "uncertain", "suspended", "concluded"}
SUSPENDABLE = STATES - {"suspended", "concluded"}   # what `suspended_from` may name


def validate_request(data):
    if not isinstance(data, dict) or set(data) - REQUEST_FIELDS - {"triage_reason", "standing", "integration"}:
        refuse("unknown reservation fields or invalid request")
    nonempty(data, REQUEST_FIELDS)
    if "triage_reason" in data:
        nonempty(data, ["triage_reason"])
    if data["kind"] not in {"correctness", "measurement"}:
        refuse("kind must be correctness or measurement")
    if "standing" in data:
        # Loud and explicit rather than read off the `-iterate` id convention: a mistyped id
        # must not silently escape the cap, and `execution list` shows the exemption as a field.
        if data["standing"] is not True:
            refuse("standing must be true when present")
        if data["kind"] != "correctness":
            refuse("only a correctness reservation can be standing")
    if data["transport"] not in {"subagent", "app", "cli", "coordinator"}:
        refuse("invalid transport")
    if "integration" in data:
        # A claim the base gate acts on, so only the shape an integration run has may make it.
        if data["integration"] is not True:
            refuse("integration must be true when present")
        if data["kind"] != "correctness" or data["transport"] != "coordinator" or data.get("standing"):
            refuse("only a coordinator's non-standing correctness reservation can be an integration run")


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
    # A suspension is exactly the state and its two fields, on a standing record (see the header).
    if record["state"] == "suspended":
        nonempty(record, ["suspended_by", "suspended_from"])
        if record["suspended_from"] not in SUSPENDABLE or not record["request"].get("standing"):
            refuse(f"invalid suspension: {path}")
    elif {"suspended_by", "suspended_from"} & set(record):
        refuse(f"suspension fields on a record that is not suspended: {path}")
    if "window" in record and (record["window"] is not True or record["request"]["kind"] != "measurement"):
        refuse(f"invalid measurement window: {path}")
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


def endpoint_boxes(spec):
    """The endpoint map as {casefolded alias: box}; each row is `<box> <alias>...`."""
    boxes = {}
    for row in spec.splitlines():
        words = row.split()
        for alias in words:
            owner = boxes.setdefault(alias.casefold(), words[0])
            if owner != words[0]:
                refuse(f"the endpoint map puts {alias} on both {owner} and {words[0]}; fix ENDPOINT_MAP in wake-lab.sh")
    return boxes


def check_one_entry_per_box(roster, map_spec):
    """Refuse a roster naming two aliases of one physical box (see the header)."""
    boxes = endpoint_boxes(map_spec)
    seen = {}
    for entry in roster:
        box = boxes.get(entry.casefold(), entry.casefold())
        other = seen.setdefault(box, entry)
        if other != entry:
            refuse(f"FLEET_BOXES lists {other} and {entry}, two aliases of the one box {box}: a measurement "
                   f"on one would not exclude a run on the other; keep one entry per physical box")


LANE_LOCKS = []   # lane-lock descriptors held SHARED until this process exits (see the header)


def check_lab_host(host, box, anchor, lab):
    """Refuse unless this anchor is the machine whose lock directory holds the lab's lane locks."""
    if not anchor or not lab:
        refuse(f"{host} is lab box {box}, and the anchor's and lab host's names were not passed, so this "
               f"anchor cannot be shown to hold the lab's lane locks")
    if anchor.casefold() != lab.casefold():
        refuse(f"{host} is lab box {box}, whose lane lock is a flock on the lab host {lab} (FLEET_LAB_HOST), "
               f"but this registry, on the anchor {anchor} (FLEET_ANCHOR), reads {anchor}'s lock directory, "
               f"so a running lane could not be seen: the anchor must be the machine that runs "
               f"wake-lab.sh and the sweep, and FLEET_LAB_HOST names that machine")
    site = Path(os.environ.get("WAKE_LAB_HOSTS") or Path.home() / ".config/wake-lab/hosts.sh")
    if not (site.is_file() and os.access(site, os.R_OK)):
        refuse(f"{host} is lab box {box}, and the anchor {anchor}, declared the lab host, has no readable "
               f"wake-lab site file ({site}), so it cannot be the machine whose wake-lab.sh drives the "
               f"lab and holds its lane locks: a running lane could not be seen")


def check_lane_lock(host, map_spec, anchor, lab):
    """Refuse a measurement on a box whose lab LANE lock is held; hold it shared if free."""
    box = endpoint_boxes(map_spec).get(host.casefold())
    if box is None:
        return
    check_lab_host(host, box, anchor, lab)
    directory = Path(os.environ.get("WAKE_LAB_LOCK_DIR") or Path.home() / ".local/state/wake-lab")
    path = directory / (box + ".lock")
    try:
        directory.mkdir(parents=True, exist_ok=True)
        descriptor = os.open(path, os.O_RDONLY | os.O_CREAT, 0o644)
    except OSError:
        return
    try:
        fcntl.flock(descriptor, fcntl.LOCK_SH | fcntl.LOCK_NB)
    except BlockingIOError:
        try:
            with open(descriptor, errors="replace", closefd=False) as stream:
                line = stream.readline()
        except OSError:
            line = ""
        os.close(descriptor)
        holder = re.sub(r"[\x00-\x1f\x7f]", "", line)[:200] or "an unnamed holder"
        refuse(f"{host} is lab box {box}, whose lane lock is held by {holder} ({path}): a measurement "
               f"needs the box to itself; wait for that lane to end (`wake-lab.sh status {box}`)")
    except OSError as exc:
        os.close(descriptor)
        refuse(f"{host} is lab box {box}, whose lane lock {path} could not be probed ({exc}), so a sweep "
               f"lane there cannot be ruled out")
    LANE_LOCKS.append(descriptor)


def check_capacity(data, records, canonical_hosts, slots_spec, window=False):
    """Refuse when the requested host cannot take this assignment beside the outstanding ones.

    Returns the open measurement window a standing request is queued behind, if any."""
    host, kind = data["execution_host"], data["kind"]
    slots = correctness_slots(slots_spec, canonical_hosts)
    outstanding = [r for r in records.values()
                   if r["state"] != "concluded" and r["request"]["execution_host"] == host]
    if window:
        # A window suspends the standing records and nothing else (see the header).
        outstanding = [r for r in outstanding if not r["request"].get("standing")]
    if not outstanding:
        return None
    owners = ", ".join(f"{r['request']['worker']} request={r['request_id']} coordinator={r['coordinator']}"
                       for r in outstanding)
    measuring = [r for r in outstanding if r["request"]["kind"] == "measurement"]
    if window:
        opened = [r["request_id"] for r in measuring if r.get("window")]
        if opened:
            refuse(f"measurement window {opened[0]} is already open on {host}; open the next one when it concludes")
        refuse(f"box owned by {owners} (a measurement window suspends only standing reservations, "
               f"and needs {host} otherwise to itself)")
    if kind == "measurement":
        hint = ("; every one is standing, which `fleet-worker.sh execution window` suspends for the measurement"
                if all(r["request"].get("standing") for r in outstanding) else "")
        refuse(f"box owned by {owners} (measurement needs {host} to itself{hint})")
    if measuring:
        windows = [r["request_id"] for r in measuring if r.get("window")]
        if windows and data.get("standing"):
            return windows[0]
        refuse(f"box owned by {owners} (a measurement holds {host} exclusively)")
    # Standing iteration records hold nothing at run time, so they neither fill a slot nor can
    # be refused for want of one; they remain outstanding for measurement exclusivity above.
    if data.get("standing"):
        return None
    counted = [r for r in outstanding if not r["request"].get("standing")]
    cap = slots.get(host, 1)
    if len(counted) >= cap:
        refuse(f"box owned by {owners} (correctness slots {len(counted)}/{cap} on {host} taken)")
    return None


def suspend(record, window, now, coordinator):
    """Move a standing record into the window's suspension (see the header)."""
    if record["state"] != "suspended":
        record["suspended_from"] = record["state"]
    record["state"] = "suspended"
    record["suspended_by"] = window
    record["updated_at"] = now
    record["history"].append({"at": now, "coordinator": coordinator, "action": "suspend", "data": {
        "request_id": record["request_id"], "evidence": f"suspended by measurement window {window}"}})


def publish(directory, record):
    """Write one record atomically and durably."""
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
        os.replace(temporary, directory / (record["request_id"] + ".json"))
        sync_directory(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main():
    root, action, coordinator, token, raw, boxes = sys.argv[1:7]
    slots_spec = sys.argv[7] if len(sys.argv) > 7 else ""
    map_spec = sys.argv[8] if len(sys.argv) > 8 else ""
    anchor, lab = (sys.argv[9:11] + ["", ""])[:2]
    directory = Path(root) / "executions"
    # A corrupt record blocks dispatch instead of silently making its box available.
    records = {}
    if directory.exists():
        for path in sorted(directory.glob("*.json")):
            record = json.loads(path.read_text())
            validate_record(record, path)
            records[path.stem] = record
    if action == "list":
        options = json.loads(raw)
        if (not isinstance(options, dict) or set(options) - {"active", "compact"}
                or any(type(value) is not bool for value in options.values())):
            refuse("list options must be active/compact booleans")
        # Validate the entire ledger above before filtering: a compact view must not hide
        # corrupt ownership evidence, including a malformed terminal record.
        selected = [record for record in records.values()
                    if not options.get("active") or record["state"] != "concluded"]
        if options.get("compact"):
            selected = [{key: value for key, value in record.items()
                         if key not in {"history", "lease_token"}} for record in selected]
        print(json.dumps(selected, indent=None if options.get("compact") else 2))
        return
    data = json.loads(raw)
    window_box = None
    if action == "window":
        if not isinstance(data, dict) or set(data) != {"box", "request"}:
            refuse("window payload must be {box, request}")
        nonempty(data, ["box"])
        window_box, data = data["box"], data["request"]
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
    before = []   # other records to publish BEFORE this one (a window's restorations)
    after = []    # other records to publish AFTER this one (a window's suspensions)
    if action in {"reserve", "run", "dispatch", "window"}:
        roster = list(dict.fromkeys(boxes.split()))   # a repeated entry is the same entry
        canonical_hosts = set(roster)
        if not canonical_hosts:
            refuse("FLEET_BOXES must name the canonical fleet hosts")
        check_one_entry_per_box(roster, map_spec)
        # A changed roster cannot silently erase ownership recorded under an old alias.
        # Keep reads and evidence/conclusion available to reconcile those records.
        for existing in records.values():
            if existing["state"] != "concluded" and existing["request"]["execution_host"] not in canonical_hosts:
                refuse(f"reconcile noncanonical execution host on request {existing['request_id']} before dispatch")
    if action in {"reserve", "run", "window"}:
        # `run` is reserve + dispatch under one lock: the payload is the reservation, plus an
        # optional `evidence` for the dispatch step (ludics-lite: four calls per execution
        # were a third of a coordinator's tool calls on 2026-09-15). `window` is `run` for a
        # measurement that suspends its box's standing records (see the header).
        request = data
        dispatch_evidence = ("measurement window opened: reserved and dispatched in one step (execution window)"
                             if action == "window" else "reserved and dispatched in one step (execution run)")
        if action in {"run", "window"}:
            request = {k: v for k, v in data.items() if k != "evidence"}
            if "evidence" in data:
                nonempty(data, ["evidence"])
                dispatch_evidence = data["evidence"]
        validate_request(request)
        if request["execution_host"] not in canonical_hosts:
            refuse("execution_host must exactly match a canonical FLEET_BOXES entry")
        if action == "window":
            if request["kind"] != "measurement":
                refuse("a window opens for a measurement: kind must be measurement")
            if request["execution_host"] != window_box:
                refuse(f"the window is for {window_box}, but the measurement names {request['execution_host']}")
        queued = None      # the open window a standing request is admitted suspended by
        dispatch = action in {"run", "window"}
        if record:
            if record["request"] != request:
                refuse("request_id already names a different assignment")
            if action == "reserve":
                sync_directory(directory.parent)
                sync_directory(directory)
                print(json.dumps(record, indent=2))
                return
            if action == "window":
                # A retried window never dispatches again: it finishes the suspensions below.
                if not record.get("window"):
                    refuse("request_id already names a measurement that opened no window")
                if record["state"] == "concluded":
                    sync_directory(directory.parent)
                    sync_directory(directory)
                    print(json.dumps(record, indent=2))
                    return
                dispatch = False
            else:
                # A repeated `run` never repeats a launch: the connection that dropped after the
                # first one may have started the runner. Only a still-reserved own record proceeds.
                if record["state"] != "reserved":
                    refuse(f"assignment already dispatched (state {record['state']}); reconcile, never run twice")
                if record["lease_token"] != token:
                    refuse("adopted assignment must be reconciled before dispatch")
                # The dispatch step, rechecked: a reservation can wait hours for its launch.
                if record["request"]["kind"] == "measurement":
                    check_lane_lock(record["request"]["execution_host"], map_spec, anchor, lab)
        else:
            halted = halt_identity is not None
            if "triage_reason" in request and not halted:
                refuse("triage reservations require an active halt")
            queued = check_capacity(request, records, canonical_hosts, slots_spec, window=action == "window")
            if request["kind"] == "measurement":
                check_lane_lock(request["execution_host"], map_spec, anchor, lab)
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
            if action == "window":
                record["window"] = True
            events.append(("reserve", request))
        if dispatch:
            triage = record["request"].get("triage_reason")
            if triage and (halt_identity is None or halt_generation(record.get("halt_identity")) != halt_identity):
                refuse("triage assignment belongs to a different or ended halt")
            if halt_identity is not None and not triage:
                refuse("fleet halted; ordinary dispatch refused")
            record["state"] = "launching"
            events.append(("dispatch", {"request_id": identity, "evidence": dispatch_evidence}))
        if queued:
            # Queued behind the open window rather than refused: restored when it concludes.
            record["suspended_from"] = record["state"]
            record["state"] = "suspended"
            record["suspended_by"] = queued
            events.append(("suspend", {"request_id": identity, "evidence": f"queued behind measurement window {queued}"}))
        if action == "window":
            # The measurement is published first: a crash before the suspensions leaves standing
            # records outstanding beside it (refused at run time all the same), which a retried
            # window finishes, never a record suspended by a measurement that does not exist.
            host = request["execution_host"]
            for other in records.values():
                if (other["request_id"] != identity and other["state"] not in {"concluded", "suspended"}
                        and other["request"]["execution_host"] == host and other["request"].get("standing")):
                    suspend(other, identity, now, coordinator)
                    after.append(other)
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
        if record["state"] == "suspended" and action != "conclude":
            refuse(f"{identity} is suspended by measurement window {record['suspended_by']}, which restores it "
                   f"when it concludes; conclude it only once its worker has handed back")
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
            # Rechecked at dispatch, the moment the timed work starts: a reservation can wait hours
            # for its launch, and a lane harness that reads no registry can take the box meanwhile.
            if record["request"]["kind"] == "measurement":
                check_lane_lock(record["request"]["execution_host"], map_spec, anchor, lab)
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
            record.pop("suspended_by", None)
            record.pop("suspended_from", None)
            # A window's conclusion, whatever its verdict, restores what it suspended, and those
            # records are published first: a crash between leaves the window open with some
            # records restored early (refused at run time all the same), never a record suspended
            # by a concluded measurement.
            for other in records.values():
                if other["state"] == "suspended" and other.get("suspended_by") == identity:
                    other["state"] = other.pop("suspended_from")
                    del other["suspended_by"]
                    other["updated_at"] = now
                    other["history"].append({"at": now, "coordinator": coordinator, "action": "restore", "data": {
                        "request_id": other["request_id"],
                        "evidence": f"measurement window {identity} concluded {data['verdict']}"}})
                    before.append(other)
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
    for other in before:
        publish(directory, other)
    if events:
        record["updated_at"] = now
        for event_action, event_data in events:
            record["history"].append({"at": now, "coordinator": coordinator, "action": event_action, "data": event_data})
        publish(directory, record)
    else:
        # A retried window: its record stands as it was written.
        sync_directory(directory.parent)
        sync_directory(directory)
    for other in after:
        publish(directory, other)
    host = record["request"]["execution_host"]
    if before:
        print(f"EXECUTION WINDOW {host}: {identity} concluded; restored "
              + ", ".join(f"{r['request_id']} ({r['state']})" for r in before), file=sys.stderr)
    if action == "window":
        suspended = sorted(r["request_id"] for r in records.values()
                           if r.get("suspended_by") == identity and r["state"] == "suspended")
        print(f"EXECUTION WINDOW {host}: {identity} open; suspended "
              + (", ".join(suspended) or "nothing (no standing reservation on the box)"), file=sys.stderr)
    print(json.dumps(record, indent=2))


try:
    main()
except (ValueError, OSError, KeyError, TypeError) as exc:
    print(f"EXECUTION REFUSED: {exc}", file=sys.stderr)
    sys.exit(1)
