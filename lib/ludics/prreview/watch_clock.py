"""The clock a watch and its state read: the epoch second, and a sleep.

SHIP_PR_TEST_CLOCK naming a file makes that file the clock (one epoch second in it), and a sleep
advances it instead of waiting -- pr-review.sh's ``clock_now``/``clock_sleep``, and the reason the
interface is the environment: a fixture suite drives a watch's window, its graces and every age it
reads without the implementation being a shell it can stub a ``sleep`` into. Unset, which is every
real run, it is the system clock and ``time.sleep``.
"""

import math
import os
import time
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Protocol

from ludics.prreview.core import die
from ludics.prreview.watch_jq import JqError, fromdateiso8601

TEST_CLOCK = "SHIP_PR_TEST_CLOCK"


class Clock(Protocol):
    def now(self) -> int: ...

    def sleep(self, seconds: int) -> None: ...


class SystemClock:
    def now(self) -> int:
        return math.floor(time.time())

    def sleep(self, seconds: int) -> None:
        if seconds > 0:
            time.sleep(seconds)


@dataclass(frozen=True)
class FileClock:
    path: str

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

    def sleep(self, seconds: int) -> None:
        t = self.now() + seconds
        with open(self.path, "w", encoding="utf-8") as f:
            f.write(f"{t}\n")


def clock_from_env(env: Mapping[str, str] | None = None) -> Clock:
    e = os.environ if env is None else env
    path = e.get(TEST_CLOCK, "")
    return FileClock(path) if path else SystemClock()


def age_of(timestamp: str, clock: Clock) -> int | None:
    """``age_of``: whole seconds since an ISO timestamp, or None ("-") when there is nothing to
    measure from -- empty, unparseable, or in the future. None is deliberately not 0."""
    if not timestamp:
        return None
    try:
        t = fromdateiso8601(timestamp)
    except JqError:
        return None
    age = clock.now() - t
    return age if age >= 0 else None


def age_text(age: int | None) -> str:
    """An age as the state line carries it: the number, or ``-``."""
    return "-" if age is None else str(age)


def freshest_age(clock: Clock, *timestamps: str) -> int | None:
    """``freshest_age``: each clock validated on its own, then the smallest age."""
    best: int | None = None
    for ts in timestamps:
        a = age_of(ts, clock)
        if a is None:
            continue
        if best is None or a < best:
            best = a
    return best


def fmt_age(age: int | None) -> str:
    """``fmt_age``: "20m" for 1203 seconds, "45s" under a minute."""
    if age is None:
        return "an unknown time"
    return f"{age // 60}m" if age >= 60 else f"{age}s"


def newest(*timestamps: str) -> str:
    """``newest``: the greatest non-empty string (ISO UTC timestamps sort as strings)."""
    best = ""
    for ts in timestamps:
        if ts and (not best or ts > best):
            best = ts
    return best
