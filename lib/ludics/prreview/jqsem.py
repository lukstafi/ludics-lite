"""jq's semantics, as plain Python, for every read ported from one of pr-review.sh's jq programs.

pr-review.sh asked every question of a feed in a jq program, and its answers -- which items are
new, which row is the newest, what an interpolated field prints as -- are jq's: its ordering of
mixed types, ``max_by`` keeping the LAST of equal maxima, ``//`` taking only null and false as
missing, ``.a`` on a string being an ERROR rather than null, and a regex dialect (Oniguruma in
Perl mode) whose ``\\z``, ``(?<name>...)`` and ``[[:space:]]`` are spelled differently here. The
port keeps those answers, including the failures: a shape a jq program would have errored on raises
``JqError``, and each caller turns that into the refusal the shell printed when its ``jq`` failed
("... did not parse"), never into an empty answer.

One module for every subcommand (ludics-lite#403's integration): the reads of ``poll``,
``status``, ``rounds`` and ``watch``, and the clocks' ``fromdateiso8601``.
"""

import calendar
import json
import re
import time
from collections.abc import Callable, Iterable, Sequence

from ludics.prreview.core import Json


class JqError(Exception):
    """A jq program would have failed here (a type error, an unparseable date)."""


# --- values ---------------------------------------------------------------------------------------


def idx(value: Json, key: str) -> Json:
    """jq's ``.key``: null on null, the member (or null) on an object, an error on anything else."""
    if value is None:
        return None
    if isinstance(value, dict):
        return value.get(key)
    raise JqError(f"cannot index {type_name(value)} with {key!r}")


def path(value: Json, *keys: str | int) -> Json:
    """``.a.b[0]...``: ``idx`` for a name, jq's ``.[n]`` for an integer (null past the end)."""
    out = value
    for key in keys:
        if isinstance(key, str):
            out = idx(out, key)
        elif out is None:
            return None
        elif isinstance(out, list):
            out = out[key] if -len(out) <= key < len(out) else None
        else:
            raise JqError(f"cannot index {type_name(out)} with a number")
    return out


def alt(value: Json, default: Json) -> Json:
    """``value // default``: null and false are missing."""
    return default if value is None or value is False else value


def truthy(value: Json) -> bool:
    return value is not None and value is not False


def type_name(value: Json) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    return "object"


def as_list(value: Json) -> list[Json]:
    """``.[]`` over an array, or ``$x[]``; an error on anything that is not one (objects are not
    iterated by any program this port replaces)."""
    if isinstance(value, list):
        return value
    raise JqError(f"cannot iterate over {type_name(value)}")


def string(value: Json) -> str:
    """A value a program required to be a string (``startswith``, ``test``, ``split``)."""
    if isinstance(value, str):
        return value
    raise JqError(f"{type_name(value)} is not a string")


def startswith(value: Json, prefix: Json) -> bool:
    if not isinstance(value, str) or not isinstance(prefix, str):
        raise JqError("startswith() requires string inputs")
    return value.startswith(prefix)


def login_is(item: Json, reviewer: str) -> bool:
    """``select((.user.login // "") | startswith($rev))``, the reviewer filter every feed uses."""
    return startswith(alt(path(item, "user", "login"), ""), reviewer)


def body_of(item: Json) -> str:
    """``(.body // "")``, required to be a string by whatever reads it next."""
    return string(alt(idx(item, "body"), ""))


# --- printing -------------------------------------------------------------------------------------


def number_text(value: int | float) -> str:
    if isinstance(value, int):
        return str(value)
    if value != value or value in (float("inf"), float("-inf")):
        return "null" if value != value else ("1.7976931348623157e+308" if value > 0 else "-1.7976931348623157e+308")
    return json.dumps(value)


def tojson(value: Json) -> str:
    """jq's ``tojson``/``-c``: compact, keys in their order, non-ASCII as itself."""
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def jstr(value: Json) -> str:
    """What ``"\\(x)"`` and ``-r`` print for a value: a string as itself, anything else as JSON."""
    if isinstance(value, str):
        return value
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return number_text(value)
    return tojson(value)


# --- ordering ---------------------------------------------------------------------------------------

_RANK = {"null": 0, "boolean": 1, "number": 3, "string": 4, "array": 5, "object": 6}


def _rank(value: Json) -> int:
    if value is True:
        return 2
    return _RANK[type_name(value)]


def cmp(a: Json, b: Json) -> int:
    """jq's total order: null < false < true < numbers < strings < arrays < objects."""
    ra, rb = _rank(a), _rank(b)
    if ra != rb:
        return -1 if ra < rb else 1
    if isinstance(a, (int, float)) and isinstance(b, (int, float)) and not isinstance(a, bool):
        return (a > b) - (a < b)
    if isinstance(a, str) and isinstance(b, str):
        return (a > b) - (a < b)
    if isinstance(a, list) and isinstance(b, list):
        for x, y in zip(a, b):
            c = cmp(x, y)
            if c:
                return c
        return (len(a) > len(b)) - (len(a) < len(b))
    if isinstance(a, dict) and isinstance(b, dict):
        ka, kb = sorted(a), sorted(b)
        c = cmp(list[Json](ka), list[Json](kb))
        if c:
            return c
        for k in ka:
            c = cmp(a[k], b[k])
            if c:
                return c
        return 0
    return 0


def gt(a: Json, b: Json) -> bool:
    return cmp(a, b) > 0


def ge(a: Json, b: Json) -> bool:
    return cmp(a, b) >= 0


def lt(a: Json, b: Json) -> bool:
    return cmp(a, b) < 0


def sort_by[T](items: Iterable[T], key: Callable[[T], Json]) -> list[T]:
    """``sort_by(f)``: stable, in jq's order."""
    import functools

    keyed = [(key(x), x) for x in items]
    keyed.sort(key=functools.cmp_to_key(lambda p, q: cmp(p[0], q[0])))
    return [x for _, x in keyed]


def max_by[T](items: Sequence[T], key: Callable[[T], Json]) -> T | None:
    """``max_by(f)``: the LAST of the greatest, None for an empty array."""
    best: T | None = None
    best_key: Json = None
    first = True
    for item in items:
        k = key(item)
        if first or cmp(k, best_key) >= 0:
            best, best_key, first = item, k, False
    return best


def jmax(values: Sequence[Json]) -> Json:
    """``max``: null for an empty array."""
    return max_by(values, lambda v: v)


def unique(values: Iterable[Json]) -> list[Json]:
    out: list[Json] = []
    for v in sort_by(values, lambda v: v):
        if not out or cmp(out[-1], v) != 0:
            out.append(v)
    return out


def member(values: Sequence[Json], value: Json) -> bool:
    """``$array | index($x)`` used as a test: is an element equal to it."""
    return any(cmp(v, value) == 0 and type_name(v) == type_name(value) for v in values)


# --- regular expressions ----------------------------------------------------------------------------

# Oniguruma's [[:space:]] under UTF-8: the White_Space property, not Python's isspace (which also
# takes the four information separators U+001C-U+001F).
SPACE = "\t\n\x0b\x0c\r \x85\xa0  -     　"


def onig(pattern: str, flags: int = 0) -> re.Pattern[str]:
    """Compile a pattern written in jq's dialect: ``(?<name>`` is ``(?P<name>``, ``\\z`` is
    ``\\Z``, and ``[:space:]`` inside a bracket is the White_Space set. ``^``, ``$`` and ``.``
    already mean what they mean there (string start; end or before a final newline; no newline)."""
    p = pattern.replace("(?<", "(?P<").replace("\\z", "\\Z").replace("[:space:]", SPACE)
    return re.compile(p, flags)


def test(text: Json, rx: re.Pattern[str]) -> bool:
    return rx.search(string(text)) is not None


def capture_first(text: Json, rx: re.Pattern[str]) -> dict[str, str | None] | None:
    """``[capture(re)] | first``: the first match's named groups, or None."""
    m = rx.search(string(text))
    return None if m is None else m.groupdict()


def capture_all(text: Json, rx: re.Pattern[str]) -> list[dict[str, str | None]]:
    """``[capture(re; "g")]``."""
    return [m.groupdict() for m in rx.finditer(string(text))]


def sub_once(text: Json, rx: re.Pattern[str], repl: str) -> str:
    """``sub(re; s)`` with a literal replacement."""
    return rx.sub(lambda _m: repl, string(text), count=1)


# --- dates ------------------------------------------------------------------------------------------

_ISO = re.compile(r"([0-9]{1,4})-([0-9]{1,2})-([0-9]{1,2})T([0-9]{1,2}):([0-9]{1,2}):([0-9]{1,2})Z")


def fromdateiso8601(text: Json) -> int:
    """jq's ``fromdateiso8601``: strptime ``%Y-%m-%dT%H:%M:%SZ`` and timegm, whole string, UTC.

    Like the C strptime under it, a field may be written without its leading zero, a value out of
    its field's range (a 13th month, a 25th hour) does not parse, and neither does a fraction of a
    second; timegm normalizes an out-of-range day. Seconds go to 60, as macOS's strptime reads
    them (glibc's also takes 61; GitHub never sends either)."""
    s = string(text)
    m = _ISO.fullmatch(s)
    if m is None:
        raise JqError(f'date "{s}" does not match format "%Y-%m-%dT%H:%M:%SZ"')
    y, mo, d, h, mi, se = (int(g) for g in m.groups())
    if not (1 <= mo <= 12 and 1 <= d <= 31 and h <= 23 and mi <= 59 and se <= 60):
        raise JqError(f'date "{s}" does not match format "%Y-%m-%dT%H:%M:%SZ"')
    return calendar.timegm((y, mo, d, h, mi, se, 0, 0, 0))


def todate(epoch: int) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))
