"""The clock every ported subcommand reads, and pr-review.sh's prelude time helpers.

A clock answers three questions: jq's ``now`` (``time``, a float, which an age is measured against),
``date +%s`` (``now``, whole seconds, which a wait's deadline is kept in), and ``sleep``.

SHIP_PR_TEST_CLOCK naming a file makes that file the clock (one epoch second in it), and a sleep
advances it instead of waiting -- pr-review.sh's ``clock_now``/``clock_sleep``, and the reason the
interface is the environment: a fixture suite drives a watch's window, its graces and every age it
reads without the implementation being a shell it can stub a ``sleep`` into. Unset, which is every
real run, it is the system clock and ``time.sleep``.

A sleep, though, is a CALL, and a suite that defines ``sleep`` as a function observes the wait
through it (the pauses it logs, what it lets happen meanwhile): pr-review.sh's forward bridges
``sleep`` like ``gh`` (``ludics.proc``), and then that function is every sleep here -- the clock's
and the retry backoff's (``plain_sleep``) alike. A suite that defines one under a test clock
advances the clock in it.

The helpers (``newest``, ``age_of``, ``freshest_age``, ``fmt_age``) are the prelude's, ported once:
an age is whole seconds, or None where the shell printed ``-`` (no stamp, one jq's
``fromdateiso8601`` refuses, or one in the future -- a negative age is never 0).
"""

import math
import os
import time as _time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Protocol

from ludics import proc
from ludics.prreview import jqsem
from ludics.prreview.core import die

TEST_CLOCK = "SHIP_PR_TEST_CLOCK"


class Clock(Protocol):
    def time(self) -> float: ...

    def now(self) -> int: ...

    def sleep(self, seconds: float, /) -> None: ...


def _system_sleep(seconds: float) -> None:
    if seconds > 0:
        _time.sleep(seconds)


def bridged_sleep(env: Mapping[str, str] | None = None) -> Callable[[float], None] | None:
    """The forwarding shell's ``sleep`` FUNCTION, when the bridge hands one over; None otherwise
    (every production run)."""
    e = os.environ if env is None else env
    if proc.bridge_argv("sleep", [], e) is None:
        return None
    environ = dict(e)

    def run(seconds: float) -> None:
        text = str(int(seconds)) if float(seconds).is_integer() else str(seconds)
        proc.run_tool("sleep", [text], env=environ)

    return run


def plain_sleep(env: Mapping[str, str] | None = None) -> Callable[[float], None]:
    """The shell's plain ``sleep``: the bridged function when there is one, else a real wait. What
    the retry backoff sleeps on, which no test clock ever advanced."""
    return bridged_sleep(env) or _system_sleep


@dataclass
class FuncClock:
    """The wall clock, or any pair of functions a unit test injects: ``time`` is jq's ``now``,
    ``now()`` is ``date +%s`` (whole seconds), ``sleep`` waits (a non-positive wait is none)."""

    time: Callable[[], float] = _time.time
    sleep: Callable[[float], None] = _system_sleep

    def now(self) -> int:
        return math.floor(self.time())


@dataclass(frozen=True)
class FileClock:
    """SHIP_PR_TEST_CLOCK's file: one epoch second, which a sleep advances -- or, when the suite
    bridged a ``sleep`` of its own, which that function advances."""

    path: str
    sleeper: Callable[[float], None] | None = None

    def now(self) -> int:
        try:
            with open(self.path, encoding="utf-8") as f:
                text = f.read().strip()
        except OSError as e:
            die(f"{TEST_CLOCK} names '{self.path}', which cannot be read: {e.strerror}")
        try:
            return int(text)
        except ValueError:
            die(f"{TEST_CLOCK}'s file '{self.path}' holds '{text}', not an epoch second")

    def time(self) -> float:
        return float(self.now())

    def sleep(self, seconds: float) -> None:
        if self.sleeper is not None:
            self.sleeper(seconds)
            return
        t = self.now() + math.floor(seconds)
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(f"{t}\n")


def clock_from_env(env: Mapping[str, str] | None = None) -> Clock:
    e = os.environ if env is None else env
    path = e.get(TEST_CLOCK, "")
    bridged = bridged_sleep(e)
    if path:
        return FileClock(path, bridged)
    return FuncClock(sleep=bridged) if bridged is not None else FuncClock()


def newest(*stamps: str) -> str:
    """``newest``: the greatest nonempty ISO stamp, compared as a string (UTC ISO 8601 sorts as
    text)."""
    best = ""
    for ts in stamps:
        if ts and (not best or ts > best):
            best = ts
    return best


def age_of(stamp: str, now: float) -> int | None:
    """``age_of``: whole seconds from ``stamp`` to ``now``; None ("-") when there is nothing to
    measure from -- no stamp, one jq's ``fromdateiso8601`` refuses, or one in the FUTURE."""
    if not stamp:
        return None
    try:
        then = jqsem.fromdateiso8601(stamp)
    except jqsem.JqError:
        return None
    age = math.floor(now - then)
    return age if age >= 0 else None


def age_text(age: int | None) -> str:
    """An age as a state line carries it: the number, or ``-``."""
    return "-" if age is None else str(age)


def freshest_age(*stamps: str, now: float) -> int | None:
    """``freshest_age``: each clock validated on its own, then the smallest age that survives."""
    best: int | None = None
    for ts in stamps:
        age = age_of(ts, now)
        if age is None:
            continue
        if best is None or age < best:
            best = age
    return best


def fmt_age(age: int | None) -> str:
    """``fmt_age``: "20m" for a human skimming, "45s" under a minute, "an unknown time" for none."""
    if age is None:
        return "an unknown time"
    return f"{age // 60}m" if age >= 60 else f"{age}s"
