"""``pr-review.sh checks <pr> [--wait[=seconds]]``: the PR head's build signal, and its trailer.

Ported from the shell's ``cmd_checks`` (ludics-lite#403). The repository's advisory list is read
first (``Gate.advisory_policy``); a policy that could not be read is the command's status, with
nothing judged. The last stdout line is always ``checks: verdict=<v>`` from a closed vocabulary
(ludics-lite#423): ``fleet-worker.sh prs`` reads the verdict from it, never from the prose.

Exit: the gate's (0 green or a confirmed absence, 1 red, 3 unread, 4 no verdict yet, 5 superseded),
or the policy's refusal (2, 3). ``--wait=`` takes whole seconds; the shell fed anything else to its
arithmetic, which failed obscurely, so here it is a usage error (2).
"""

import os

from ludics import cli
from ludics.prreview.core import GhSession, die, fail, pr_arg
from ludics.prreview.gate import Gate, load_gate_config
from ludics.prreview.shtext import is_digits

VERDICTS = (
    "green", "absent", "red", "runred", "waived", "pending", "mixed", "unjudged", "superseded", "unknown",
)


def parse_wait(value: str, command: str) -> int:
    """A ``--wait=<seconds>`` value: whole seconds, or a usage error."""
    if not is_digits(value):
        die(f"{command}: --wait takes whole seconds, got '{value}'")
    return int(value)


def run(session: GhSession, args: list[str]) -> int:
    config = load_gate_config(os.environ)
    if not args or not args[0]:
        fail(1, "usage: checks <pr> [--wait[=seconds]]")
    pr = args[0]
    wait_for = 0
    for arg in args[1:]:
        if arg == "--wait":
            wait_for = config.checks_wait
        elif arg.startswith("--wait="):
            wait_for = parse_wait(arg[len("--wait=") :], "checks")
        else:
            die(f"checks: unknown option '{arg}'")
    target = pr_arg(pr, session.config.repo)
    gate = Gate(session, target.repo, config)
    policy = gate.advisory_policy()
    if policy == 0:
        rc = gate.check(target.num, wait_for)
        verdict: str = gate.verdict
    else:
        rc = policy
        verdict = "unknown"
    if verdict not in VERDICTS:
        verdict = "unknown"
    cli.say(f"checks: verdict={verdict}")
    return rc
