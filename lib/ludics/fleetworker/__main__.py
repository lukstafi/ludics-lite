"""``scripts/py -m ludics.fleetworker <fleet-worker.sh path> <verb> <args...>``

What fleet-worker.sh's forwarder runs for a verb in its ported set, before the shell reads any of
its own configuration: the script's path as it was invoked (``"$0"``, from which the checkout and
its sibling scripts are found), then the verb and its arguments exactly as given. Every knob is
read from the environment, as the shell read it (``ludics.fleetworker.config``).

Ported: the coordinator lease (claim, release, coordinator), the halt (halt, resume-launches,
halted), the native gate (gate), and every ``execution`` action (the registry, the conclusions read
off a run, and ``execution slot``/``hold``). The rest -- launch, preflight, refresh, attach, status,
log, unstick, close, ls, load, prs -- is still fleet-worker.sh's own.
"""

import os
import signal
import sys
from collections.abc import MutableMapping

from ludics import cli
from ludics.fleetworker import execution, gate, lease
from ludics.fleetworker.config import load_config
from ludics.fleetworker.identity import PROG, die

PORTED = (
    "gate",
    "execution",
    "halt",
    "resume-launches",
    "halted",
    "claim",
    "release",
    "coordinator",
)


# The forwarder's note of the caller's PYTHONPATH: ``=<value>`` when it was set, empty when not.
CALLER_PYTHONPATH = "LUDICS_FW_PYTHONPATH"


def restore_caller_pythonpath(env: MutableMapping[str, str]) -> None:
    """Put back the PYTHONPATH scripts/py replaced with the checkout's lib/ (fleet-worker.sh's
    forwarder notes it), so every child -- a batch under ``execution slot``/``hold`` above all --
    runs in the caller's environment. This process's own path was fixed at startup; a run not
    through the forwarder has no note, and keeps what it has."""
    saved = env.pop(CALLER_PYTHONPATH, None)
    if saved is None:
        return
    if saved.startswith("="):
        env["PYTHONPATH"] = saved[1:]
    else:
        env.pop("PYTHONPATH", None)


def dispatch(argv: list[str]) -> int:
    restore_caller_pythonpath(os.environ)
    if not argv:
        die("usage: python -m ludics.fleetworker <fleet-worker.sh path> <verb> [args...]")
    cfg = load_config(argv[0], os.environ)
    verb = argv[1] if len(argv) > 1 else ""
    rest = argv[2:]
    match verb:
        case "gate":
            return gate.cmd_gate(cfg, rest)
        case "execution":
            return execution.cmd_execution(cfg, rest)
        case "halt":
            return lease.cmd_halt(cfg, rest)
        case "resume-launches":
            return lease.cmd_resume_launches(cfg, rest)
        case "halted":
            return lease.cmd_halted(cfg, rest)
        case "claim":
            return lease.cmd_claim(cfg, rest)
        case "release":
            return lease.cmd_release(cfg, rest)
        case "coordinator":
            return lease.cmd_coordinator(cfg, rest)
        case _:
            die(
                f"'{verb}' is not a verb ported to Python (ported: {' '.join(PORTED)});",
                "run it through fleet-worker.sh, which serves every verb.",
            )


def die_of_sigpipe() -> int:
    """A reader that went away: end as the shell did, killed by SIGPIPE (a caller's pipefail reads
    141), with no traceback. Python ignores SIGPIPE and raises BrokenPipeError instead, and would
    end in a traceback and exit 120 from the flush at shutdown."""
    devnull = os.open(os.devnull, os.O_WRONLY)
    os.dup2(devnull, sys.stdout.fileno())  # the interpreter's final flush must not fail again
    os.close(devnull)
    if hasattr(signal, "SIGPIPE"):
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        os.kill(os.getpid(), signal.SIGPIPE)
    return 128 + 13


def main() -> int:
    try:
        rc = cli.main_guard(PROG, dispatch, sys.argv[1:])
        sys.stdout.flush()
    except BrokenPipeError:
        return die_of_sigpipe()
    return rc


if __name__ == "__main__":
    sys.exit(main())
