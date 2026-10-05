"""Reading text the way pr-review.sh's shell read it, for the ports of the gate and merge.

The gh calls of the ported subcommands keep their ``--jq`` filters byte for byte (the fixture
suites answer through them), so what comes back is the TSV and the lines the shell read -- and the
shell's reading of them has corners a port must keep: ``IFS=$'\\t' read`` collapses a run of tabs
(the reason every projection carries a ``-`` placeholder), ``${x#*$'\\n'}`` leaves a string with no
newline whole, ``grep -c .`` counts non-empty lines. These helpers are those readings, named.

Also here, ported from the prelude's time helpers: ``newest``, ``age_of``, ``freshest_age``,
``fmt_age``; and jq's compact JSON printing, which the drift and thread lines print.
"""

import datetime
import math
import re
import time
from collections.abc import Callable
from typing import cast

from ludics.prreview.core import Json


def tab_fields(line: str, n: int) -> list[str]:
    """``IFS=$'\\t' read -r f1 .. fn <<<"$line"``: tab is IFS WHITESPACE, so leading and trailing
    tabs are dropped and a run of them is one delimiter; the last field takes the rest of the line
    (its inner tabs kept). Always ``n`` fields, the missing ones empty."""
    rest = line.strip("\t")
    out: list[str] = []
    for _ in range(n - 1):
        if not rest:
            out.append("")
            continue
        idx = rest.find("\t")
        if idx < 0:
            out.append(rest)
            rest = ""
            continue
        out.append(rest[:idx])
        rest = rest[idx:].lstrip("\t")
    out.append(rest)
    return out


def herestring_lines(text: str) -> list[str]:
    """The lines ``while read ...; done <<<"$text"`` sees: ``text`` split at newlines (the
    here-string's own trailing newline adds no line; an empty text is one empty line)."""
    return text.split("\n")


def head_line(text: str) -> str:
    """``${text%%$'\\n'*}``: up to the first newline, or all of it."""
    return text.split("\n", 1)[0]


def after_line(text: str) -> str:
    """``${text#*$'\\n'}``: after the first newline -- or ALL of it when there is none."""
    parts = text.split("\n", 1)
    return parts[1] if len(parts) == 2 else text


def nonempty_lines(text: str) -> list[str]:
    """``printf '%s' "$text" | grep .``: the lines with at least one character."""
    return [line for line in text.split("\n") if line]


def count_nonempty(text: str) -> int:
    """``printf '%s' "$text" | grep -c .``."""
    return len(nonempty_lines(text))


_DIGITS = re.compile(r"[0-9]+")


def is_digits(text: str) -> bool:
    """``case "$x" in '' | *[!0-9]*) no ;; esac``: a nonempty run of ASCII digits."""
    return _DIGITS.fullmatch(text) is not None


def placeholder(field: str) -> str:
    """``[ "${x:--}" != - ] || x=""``: the projection's ``-`` placeholder back to empty."""
    return "" if field in ("", "-") else field


# SHARED-CANDIDATE: encode_ref
def encode_ref(ref: str) -> str:
    """``encode_ref``: a branch name as data in a REST path or query -- every byte outside
    ``[a-zA-Z0-9._~/-]`` percent-encoded, upper-case hex, ``/`` kept literal."""
    out: list[str] = []
    for byte in ref.encode("utf-8", "surrogateescape"):
        ch = chr(byte)
        if byte < 128 and (ch.isalnum() or ch in "._~/-"):
            out.append(ch)
        else:
            out.append(f"%{byte:02X}")
    return "".join(out)


# --- clocks -----------------------------------------------------------------------------------------

_ISO = re.compile(r"([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})Z")


# SHARED-CANDIDATE: newest
def newest(*stamps: str) -> str:
    """``newest``: the greatest of the nonempty ISO stamps as strings (UTC ISO 8601 sorts as text)."""
    best = ""
    for ts in stamps:
        if ts and (not best or ts > best):
            best = ts
    return best


def parse_iso(ts: str) -> float | None:
    """jq's ``fromdateiso8601``: ``YYYY-MM-DDTHH:MM:SSZ`` to epoch seconds, None for anything else."""
    m = _ISO.fullmatch(ts)
    if m is None:
        return None
    y, mo, d, h, mi, sec = (int(g) for g in m.groups())
    try:
        stamp = datetime.datetime(y, mo, d, h, mi, sec, tzinfo=datetime.UTC)
    except ValueError:
        return None
    return stamp.timestamp()


# SHARED-CANDIDATE: age_of
def age_of(ts: str, now: Callable[[], float] = time.time) -> int | None:
    """``age_of``: whole seconds since ``ts``; None ("-") when there is nothing to measure from --
    no stamp, one that does not parse, or one in the FUTURE (a negative age is never 0)."""
    if not ts:
        return None
    then = parse_iso(ts)
    if then is None:
        return None
    age = math.floor(now() - then)
    return age if age >= 0 else None


# SHARED-CANDIDATE: freshest_age
def freshest_age(*stamps: str, now: Callable[[], float] = time.time) -> int | None:
    """``freshest_age``: each clock validated on its own, then the smallest age that survives."""
    best: int | None = None
    for ts in stamps:
        age = age_of(ts, now)
        if age is None:
            continue
        if best is None or age < best:
            best = age
    return best


# SHARED-CANDIDATE: fmt_age
def fmt_age(seconds: int | None) -> str:
    """``fmt_age``: "20m" for a human skimming, "45s" under a minute, "an unknown time" for none."""
    if seconds is None:
        return "an unknown time"
    return f"{seconds // 60}m" if seconds >= 60 else f"{seconds}s"


# --- jq's printing ----------------------------------------------------------------------------------


def _jq_string(s: str) -> str:
    out = ['"']
    for ch in s:
        o = ord(ch)
        if ch == '"':
            out.append('\\"')
        elif ch == "\\":
            out.append("\\\\")
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\t":
            out.append("\\t")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\b":
            out.append("\\b")
        elif ch == "\f":
            out.append("\\f")
        elif o < 0x20 or o == 0x7F:
            out.append(f"\\u{o:04x}")
        else:
            out.append(ch)
    out.append('"')
    return "".join(out)


def jq_compact(value: Json) -> str:
    """``jq -c`` printing of a value: compact separators, non-ASCII as itself, control characters
    escaped the way jq escapes them."""
    if value is None:
        return "null"
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, str):
        return _jq_string(value)
    if isinstance(value, int):
        return str(value)
    if isinstance(value, float):
        return str(int(value)) if value.is_integer() else repr(value)
    if isinstance(value, list):
        return "[" + ",".join(jq_compact(v) for v in value) + "]"
    return "{" + ",".join(_jq_string(k) + ":" + jq_compact(v) for k, v in value.items()) + "}"


def jq_tostring(value: Json) -> str:
    """jq's ``tostring``: a string as itself, anything else as its compact JSON."""
    return value if isinstance(value, str) else jq_compact(value)


class JqError(Exception):
    """A jq path that jq would have refused (``.a`` of a string, ``.[0]`` of an object)."""


def jq_get(value: Json, *path: str | int) -> Json:
    """jq's ``.a.b[0]``: null-safe on null, an error on a value of the wrong type."""
    cur = value
    for step in path:
        if cur is None:
            return None
        if isinstance(step, str):
            if not isinstance(cur, dict):
                raise JqError(step)
            cur = cast(dict[str, Json], cur).get(step)
        else:
            if not isinstance(cur, list):
                raise JqError(str(step))
            items = cast(list[Json], cur)
            cur = items[step] if -len(items) <= step < len(items) else None
    return cur


def jq_alt(*values: Json) -> Json:
    """jq's ``a // b // c``: the first value that is neither null nor false, else the last."""
    for v in values[:-1]:
        if v is not None and v is not False:
            return v
    return values[-1]


def is_number(value: Json) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)
