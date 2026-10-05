"""jq's value semantics, for the reads ported from pr-review.sh's jq programs.

The shell read every feed with a jq program, and what a program did with a shape it could not take
was part of the command's behaviour: it ERRORED, the caller saw the failure, and the read reported
itself unread (``unknown``, exit 3 or 4) instead of rendering a value (ludics-lite#89). A Python
port that read feeds with ``dict.get`` would answer those shapes instead. So the reads ported from
those programs go through the helpers here, which do what jq 1.8 does (the fleet's jq, pinned in
CI, ludics-lite#508):

  - indexing ``.key`` of null is null, of an object its value, of anything else an error;
  - ``a // b`` takes ``b`` when ``a`` is null or false, and does NOT swallow an error in ``a``;
  - ``==``, ``<`` and the sorts use jq's total order: null < false < true < numbers < strings <
    arrays < objects;
  - the string builtins (``test``, ``startswith``, ``split``, ``sub``, ``capture``, ``contains``,
    ``fromdateiso8601``) refuse a non-string input;
  - ``max_by`` keeps the LAST of equal maxima, ``sort_by`` is stable, ``max`` of nothing is null;
  - string interpolation and ``jq -r`` print a string as itself and anything else as JSON.

Every failure is a ``JqError``; a caller catches it exactly where the shell's ``|| {...}`` stood.
"""

import calendar
import json
import re
from collections.abc import Callable, Iterable, Sequence
from functools import cmp_to_key

from ludics.prreview.core import Json


class JqError(Exception):
    """What jq would have exited 5 on."""


def kind(v: Json) -> str:
    """jq's ``type``."""
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "boolean"
    if isinstance(v, (int, float)):
        return "number"
    if isinstance(v, str):
        return "string"
    if isinstance(v, list):
        return "array"
    return "object"


def idx(v: Json, key: str) -> Json:
    """``.key``."""
    if v is None:
        return None
    if isinstance(v, dict):
        return v.get(key)
    raise JqError(f'Cannot index {kind(v)} with "{key}"')


def nth(v: Json, i: int) -> Json:
    """``.[i]`` for a number ``i``."""
    if v is None:
        return None
    if isinstance(v, list):
        return v[i] if -len(v) <= i < len(v) else None
    raise JqError(f"Cannot index {kind(v)} with number")


def truthy(v: Json) -> bool:
    return v is not None and v is not False


def alt(v: Json, default: Json) -> Json:
    """``v // default`` for a single-valued ``v``."""
    return v if truthy(v) else default


def path(v: Json, *keys: str) -> Json:
    """``.a.b.c``."""
    for key in keys:
        v = idx(v, key)
    return v


# --- order -----------------------------------------------------------------------------------------

_RANK = {"null": 0, "boolean": 1, "number": 3, "string": 4, "array": 5, "object": 6}


def _rank(v: Json) -> int:
    if v is True:
        return 2
    return _RANK[kind(v)]


def cmp(a: Json, b: Json) -> int:
    """jq's ``jv_cmp``: a total order over every JSON value."""
    ra, rb = _rank(a), _rank(b)
    if ra != rb:
        return -1 if ra < rb else 1
    if isinstance(a, (int, float)) and isinstance(b, (int, float)):
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
        ka: list[Json] = list(sorted(a))
        kb: list[Json] = list(sorted(b))
        c = cmp(ka, kb)
        if c:
            return c
        for key in sorted(a):
            c = cmp(a[key], b[key])
            if c:
                return c
        return 0
    return 0  # null, false, true: one value each


def eq(a: Json, b: Json) -> bool:
    return cmp(a, b) == 0


def gt(a: Json, b: Json) -> bool:
    return cmp(a, b) > 0


def sort_by[T](items: Iterable[T], key: Callable[[T], Json]) -> list[T]:
    keyed = [(key(item), item) for item in items]
    keyed.sort(key=cmp_to_key(lambda x, y: cmp(x[0], y[0])))
    return [item for _, item in keyed]


def max_by[T](items: Sequence[T], key: Callable[[T], Json]) -> T | None:
    """``max_by(f)``: the LAST of equal maxima; None (jq's null) for no items."""
    best: T | None = None
    best_key: Json = None
    first = True
    for item in items:
        k = key(item)
        if first or cmp(k, best_key) >= 0:
            best, best_key, first = item, k, False
    return best


def jmax(items: Sequence[Json]) -> Json:
    """``max``."""
    return max_by(items, lambda v: v)


def unique(items: Sequence[Json]) -> list[Json]:
    out: list[Json] = []
    for v in sort_by(items, lambda v: v):
        if not out or not eq(out[-1], v):
            out.append(v)
    return out


# --- printing --------------------------------------------------------------------------------------


def tojson(v: Json) -> str:
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def text(v: Json) -> str:
    """String interpolation ``\\(v)`` and ``tostring``: a string as itself, the rest as JSON."""
    return v if isinstance(v, str) else tojson(v)


def add_str(a: str, b: Json) -> str:
    """``"..." + b``: a string, or null (which adds nothing); anything else is an error."""
    if b is None:
        return a
    if isinstance(b, str):
        return a + b
    raise JqError(f"string and {kind(b)} cannot be added")


def captured(outputs: Iterable[str]) -> str:
    """What ``x=$(jq -r ...)`` holds: each output on its own line, trailing newlines dropped."""
    return "".join(o + "\n" for o in outputs).rstrip("\n")


# --- strings ---------------------------------------------------------------------------------------


def _string(v: Json, what: str) -> str:
    if isinstance(v, str):
        return v
    raise JqError(f"{kind(v)} ({tojson(v)}) {what}")


def test(v: Json, pattern: re.Pattern[str]) -> bool:
    return pattern.search(_string(v, "cannot be matched, as it is not a string")) is not None


def startswith(v: Json, prefix: Json) -> bool:
    if isinstance(v, str) and isinstance(prefix, str):
        return v.startswith(prefix)
    raise JqError("startswith() requires string inputs")


def contains(v: Json, needle: str) -> bool:
    if isinstance(v, str):
        return needle in v
    raise JqError(f"{kind(v)} ({tojson(v)}) and string cannot have their containment checked")


def split(v: Json, sep: str) -> list[str]:
    """``split("sep")``: jq splits an empty string into NO parts."""
    s = _string(v, "cannot be split")
    return [] if s == "" else s.split(sep)


def sub(v: Json, pattern: re.Pattern[str], repl: str) -> str:
    """``sub(re; "literal")``: the first match only."""
    s = _string(v, "cannot be matched, as it is not a string")
    return pattern.sub(lambda _m: repl, s, count=1)


def capture(v: Json, pattern: re.Pattern[str]) -> dict[str, Json] | None:
    """``[capture(re)] | first``: the named groups of the first match, or None (no output)."""
    match = pattern.search(_string(v, "cannot be matched, as it is not a string"))
    return None if match is None else dict(match.groupdict())


def capture_all(v: Json, pattern: re.Pattern[str]) -> list[dict[str, Json]]:
    """``[capture(re; "g")]``."""
    s = _string(v, "cannot be matched, as it is not a string")
    return [dict(m.groupdict()) for m in pattern.finditer(s)]


def head_slice(v: Json, n: int) -> Json:
    """``.[0:n]``: a string by code points, an array by elements, null as null."""
    if v is None:
        return None
    if isinstance(v, (str, list)):
        return v[0:n]
    raise JqError(f"Cannot index {kind(v)} with object")


_ISO = re.compile(r"([0-9]{1,4})-([0-9]{1,2})-([0-9]{1,2})T([0-9]{1,2}):([0-9]{1,2}):([0-9]{1,2})Z")


def fromdateiso8601(v: Json) -> int:
    """``fromdateiso8601``: jq's strptime of ``%Y-%m-%dT%H:%M:%SZ``, whole string, UTC.

    Like the C strptime under it, a field may be written without its leading zero, and a value
    out of its field's range (a 13th month, a 25th hour) does not parse; a fraction of a second
    does not either."""
    s = _string(v, "cannot be parsed as a date")
    m = _ISO.fullmatch(s)
    if m is None:
        raise JqError(f'date "{s}" does not match format "%Y-%m-%dT%H:%M:%SZ"')
    year, month, day, hour, minute, second = (int(g) for g in m.groups())
    if not (1 <= month <= 12 and 1 <= day <= 31 and hour <= 23 and minute <= 59 and second <= 60):
        raise JqError(f'date "{s}" does not match format "%Y-%m-%dT%H:%M:%SZ"')
    return calendar.timegm((year, month, day, hour, minute, second, 0, 0, 0))


# [[:space:]] as jq's Oniguruma reads it in a UTF-8 string: Unicode White_Space, which is NOT
# Python's \s (that adds \x1c-\x1f).
WS = "\t\n\x0b\x0c\r \x85\xa0\u1680\u2000-\u200a\u2028\u2029\u202f\u205f\u3000"
NONSPACE = re.compile(f"[^{WS}]")
TRAILING_SPACE = re.compile(f"[{WS}]+\\Z")


def bash_read(line: str, count: int, ws: str = "\t") -> list[str]:
    """``IFS=<ws> read -r a b c <<<"$line"``, for an IFS of whitespace characters only: the first
    line, leading and trailing IFS stripped, fields split on RUNS of IFS, the last variable taking
    the rest."""
    s = line.split("\n", 1)[0].strip(ws)
    out: list[str] = []
    for _ in range(count - 1):
        cut = next((i for i, c in enumerate(s) if c in ws), len(s))
        out.append(s[:cut])
        s = s[cut:].lstrip(ws)
    out.append(s)
    return out


def bash_read_delim(line: str, count: int, delim: str) -> list[str]:
    """``IFS=<delim> read -r a b c <<<"$line"`` for ONE non-whitespace delimiter: every delimiter
    separates (empty fields kept), the last variable takes the rest, and a rest that is one field
    and a trailing delimiter loses the delimiter, as bash's read does."""
    parts = line.split("\n", 1)[0].split(delim, count - 1)
    parts += [""] * (count - len(parts))
    rest = parts[-1]
    if rest.endswith(delim) and delim not in rest[:-1]:
        parts[-1] = rest[:-1]
    return parts


def tsv(fields: Sequence[str]) -> str:
    """``@tsv`` over strings."""
    return "\t".join(
        f.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")
        for f in fields
    )
