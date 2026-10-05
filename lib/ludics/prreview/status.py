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
from collections.abc import Mapping

from ludics import cli
from ludics.prreview import knobs
from ludics.prreview.core import GhSession, die, pr_arg
from ludics.prreview.rounds import review_rounds, rounds_line
from ludics.prreview.state import (
    approval_gate,
    state_tok,
    status_line,
    status_state,
)

def stall_seconds(env: Mapping[str, str]) -> int:
    """STALL as the shell resolves it (knobs.review_clocks)."""
    return knobs.review_clocks(env)[1]


def threads_cap(env: Mapping[str, str]) -> int:
    return knobs.threads_page_cap(env)


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
    if after and not knobs.is_digits(after):
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
