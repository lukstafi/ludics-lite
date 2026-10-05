"""What every entry point shares: the streams, and how a command ends.

A command ends by RETURNING its exit status from its ``run``, or by raising ``Exit`` from any
depth -- the Python form of the shell's ``fail <rc> <message>``, which exits from inside whatever
function noticed. ``main_guard`` turns that into the message on stderr, prefixed with the script's
name the way the shell printed it, and the status.
"""

import io
import sys
from collections.abc import Callable
from typing import NoReturn


class Exit(Exception):
    """End the command with ``rc``; ``message`` (one line, may be empty) goes to stderr as
    ``<prog>: <message>``, or as given when ``raw`` (an already-prefixed block)."""

    def __init__(self, rc: int, message: str = "", *, raw: bool = False) -> None:
        super().__init__(message)
        self.rc = rc
        self.message = message
        self.raw = raw


def exit_with(rc: int, *parts: str) -> NoReturn:
    """The shell's ``fail rc a b c``: the parts joined with single spaces, as ``$*`` joins them."""
    raise Exit(rc, " ".join(parts))


def setup_streams() -> None:
    """UTF-8 out and err, LF line ends on every platform, and stdout flushed per line.

    LF: Python on Windows writes CRLF in text mode, which is exactly the bug a native jq.exe put
    into the shell (ludics-lite#335). Line buffering: the shell wrote each line as it went, and a
    caller reading stdout and stderr interleaved, or a run cut off by a timeout, sees the same.
    """
    for stream, buffered in ((sys.stdout, True), (sys.stderr, False)):
        if isinstance(stream, io.TextIOWrapper):
            stream.reconfigure(
                encoding="utf-8", errors="surrogateescape", newline="\n", line_buffering=buffered
            )


def say(text: str) -> None:
    """One line (or several) to stdout, newline-terminated, as ``printf '%s\\n'``."""
    sys.stdout.write(text + "\n")


def emit(text: str) -> None:
    """The shell's ``[ -n "$out" ] && printf '%s\\n' "$out"``: nothing at all for empty output."""
    if text:
        say(text)


def note(prog: str, text: str) -> None:
    """A diagnostic line on stderr, ``<prog>: <text>``, ordered after any stdout already written."""
    sys.stdout.flush()
    sys.stderr.write(f"{prog}: {text}\n")
    sys.stderr.flush()


def main_guard(prog: str, run: Callable[[list[str]], int], argv: list[str]) -> int:
    """Run ``run(argv)``; an ``Exit`` from anywhere inside becomes its message and status."""
    setup_streams()
    try:
        return run(argv)
    except Exit as end:
        if end.message:
            sys.stdout.flush()
            sys.stderr.write(end.message + "\n" if end.raw else f"{prog}: {end.message}\n")
            sys.stderr.flush()
        return end.rc
