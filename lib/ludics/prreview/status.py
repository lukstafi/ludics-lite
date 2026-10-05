"""``pr-review.sh status <pr>``: the merge gate and who owes what, then the round count.

Ported from the shell's ``cmd_status`` (ludics-lite#403): the reviewer state (``state.status_state``)
checked for open review threads under an approval (``state.approval_gate``), rendered, and the
round count against the threshold on the line after it. Exit: 0 whatever state the reads answered
(``unresolved`` included: `merge` is the gate that refuses it), 3 on ``unknown`` — a failed read
is not "not approved yet". The count never changes the exit.

Two more entry points serve the suites, which judge the state line itself rather than its
rendering; pr-review.sh's command line routes to neither:

  status-state <pr> [<watch's issue-comment watermark>]   the bare state line (no thread gate)
  status-line <state line> [<pr number>]                 that line rendered
"""

import os
import re
from collections.abc import Mapping

from ludics import cli
from ludics.prreview.core import GhSession, die, pr_arg
from ludics.prreview.rounds import review_rounds, rounds_line
from ludics.prreview.state import (
    THREADS_PAGE_CAP,
    approval_gate,
    state_tok,
    status_line,
    status_state,
)

# THREADS_PAGE_CAP as the shell holds it, which a suite's `retune` moves; private to the forward.
THREADS_PAGE_CAP_ENV = "LUDICS_PR_REVIEW_THREADS_PAGE_CAP"

_DIGITS = re.compile(r"[0-9]+")


def stall_seconds(env: Mapping[str, str]) -> int:
    """GRACE and STALL as the shell resolves them: ``SHIP_PR_REVIEW_GRACE`` (1200) and
    ``SHIP_PR_REVIEW_STALL`` (twice the grace), each a whole number of seconds."""
    grace = env.get("SHIP_PR_REVIEW_GRACE", "") or "1200"
    if not _DIGITS.fullmatch(grace):
        die(f"SHIP_PR_REVIEW_GRACE must be a number of seconds, got '{grace}'")
    stall = env.get("SHIP_PR_REVIEW_STALL", "") or str(int(grace) * 2)
    if not _DIGITS.fullmatch(stall):
        die(f"SHIP_PR_REVIEW_STALL must be a number of seconds, got '{stall}'")
    return int(stall)


def threads_cap(env: Mapping[str, str]) -> int:
    cap = env.get(THREADS_PAGE_CAP_ENV, "")
    return int(cap) if _DIGITS.fullmatch(cap) else THREADS_PAGE_CAP


def run(session: GhSession, args: list[str]) -> int:
    if not args or not args[0]:
        cli.exit_with(1, "1: usage: status <pr>")
    target = pr_arg(args[0], session.config.repo)
    env = os.environ
    state = approval_gate(
        session,
        target.repo,
        target.num,
        status_state(session, target.repo, target.num, stall_seconds(env)),
        threads_cap(env),
    )
    cli.say(status_line(state, target.repo, target.num))
    line, _rc = rounds_line(
        review_rounds(session, target.repo, target.num), session.config.round_threshold
    )
    cli.say(line)
    return 3 if state_tok(state) == "unknown" else 0


def run_state(session: GhSession, args: list[str]) -> int:
    """``status-state <pr> [<nudge watermark>]``."""
    if not args or not args[0]:
        die("usage: status-state <pr> [<issue-comment watermark>]")
    target = pr_arg(args[0], session.config.repo)
    after = args[1] if len(args) > 1 else ""
    if after and not _DIGITS.fullmatch(after):
        die(f"status-state: the watermark must be a whole number, got '{after}'")
    cli.say(
        status_state(
            session,
            target.repo,
            target.num,
            stall_seconds(os.environ),
            int(after) if after else None,
        )
    )
    return 0


def run_line(session: GhSession, args: list[str]) -> int:
    """``status-line <state line> [<pr number>]``."""
    if not args:
        die("usage: status-line <state line> [<pr number>]")
    cli.say(status_line(args[0], session.config.repo, args[1] if len(args) > 1 else ""))
    return 0
