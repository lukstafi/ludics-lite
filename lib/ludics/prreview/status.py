"""``pr-review.sh status <pr>``: the merge gate and who owes what, then the round count.

Ported from the shell's ``cmd_status`` (ludics-lite#403): the reviewer state (``state.status_state``,
the one port ``watch`` reads too) checked for open review threads under an approval
(``state.approval_gate``), rendered, and the
round count against the threshold on the line after it. Exit: 0 whatever state the reads answered
(``unresolved`` included: `merge` is the gate that refuses it), 3 on ``unknown`` — a failed read
is not "not approved yet". The count never changes the exit.

Two more entry points serve the suites, which judge the state line itself rather than its
rendering; pr-review.sh's command line routes to neither:

  status-state <pr> [<watch's issue-comment watermark>]   the bare state line (no thread gate)
  status-line <state line> [<pr number>]                 that line rendered
"""

from typing import cast, get_args

from ludics import cli
from ludics.prreview import knobs
from ludics.prreview.core import GhSession, die, pr_arg
from ludics.prreview.rounds import rounds_line, rounds_result
from ludics.prreview.feeds import outside_watch
from ludics.prreview.state import State, Token, approval_gate, status_line, status_state


def run(session: GhSession, args: list[str]) -> int:
    if not args or not args[0]:
        cli.exit_with(1, "1: usage: status <pr>")
    target = pr_arg(args[0], session.config.repo)
    ctx = outside_watch(session, target.repo)
    state = approval_gate(ctx, target.num, status_state(ctx, target.num))
    cli.say(status_line(state, target.repo, target.num))
    line, _rc = rounds_line(rounds_result(ctx, target.num), session.config.round_threshold)
    cli.say(line)
    return 3 if state.tok == "unknown" else 0


def run_state(session: GhSession, args: list[str]) -> int:
    """``status-state <pr> [<nudge watermark>]``."""
    if not args or not args[0]:
        die("usage: status-state <pr> [<issue-comment watermark>]")
    target = pr_arg(args[0], session.config.repo)
    after = args[1] if len(args) > 1 else ""
    if after and not knobs.is_digits(after):
        die(f"status-state: the watermark must be a whole number, got '{after}'")
    ctx = outside_watch(session, target.repo, int(after) if after else None)
    cli.say(status_state(ctx, target.num).line())
    return 0


_TOKENS: frozenset[str] = frozenset(get_args(Token.__value__))


def run_line(session: GhSession, args: list[str]) -> int:
    """``status-line <state line> [<pr number>]``."""
    if not args:
        die("usage: status-line <state line> [<pr number>]")
    tok, age, merge, detail = (args[0].split("|", 3) + ["", "", ""])[:4]
    if tok not in _TOKENS:
        cli.say(f"unrecognised state '{tok}' — treat as unknown and retry")
        return 0
    state = State(cast(Token, tok), int(age) if knobs.is_digits(age) else None, merge, detail)
    cli.say(status_line(state, session.config.repo, args[1] if len(args) > 1 else ""))
    return 0
