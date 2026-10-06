"""Two readings of check runs that ``checks``, ``merge``, ``base`` and ``retry run watch`` share,
ported once from pr-review.sh: ``conclusion_class`` and ``newest_first``."""

import re
from collections.abc import Callable, Sequence
from typing import Literal

type ConclusionClass = Literal["red", "green", "pending", "nogo"]


def conclusion_class(conclusion: str) -> ConclusionClass:
    """``conclusion_class``: failure, timed_out and startup_failure are a verdict and it is no;
    success, skipped and neutral are green (a path-filtered job that did not run has not failed);
    no conclusion yet is pending; anything else (cancelled, stale, action_required) was stopped,
    not judged -- never counted as red and never as a pass."""
    match conclusion:
        case "failure" | "timed_out" | "startup_failure":
            return "red"
        case "success" | "skipped" | "neutral":
            return "green"
        case "" | "null" | "pending":
            return "pending"
        case _:
            return "nogo"


def _sort_number(text: str) -> float:
    """``sort -n``'s reading of a field: its leading number after blanks, 0 when there is none."""
    m = re.match(r"[ \t]*(-?[0-9]*(\.[0-9]*)?)", text)
    try:
        return float(m.group(1)) if m and m.group(1) not in ("", "-", ".", "-.") else 0.0
    except ValueError:
        return 0.0


def _bytes(text: str) -> bytes:
    return text.encode("utf-8", "surrogateescape")


def newest_first[T](rows: Sequence[T], created: Callable[[T], str], rid: Callable[[T], str],
                    line: Callable[[T], str]) -> list[T]:
    """``newest_first``: ``LC_ALL=C sort -t$'\\t' -k<c>,<c>r -k<i>,<i>nr`` -- created_at descending
    as bytes, a same-second tie to the higher id (read as ``sort -n`` reads a number), then sort's
    last resort, the whole line ascending as bytes. Each pass is stable, so the last key sorted is
    the first one compared."""
    out = sorted(rows, key=lambda r: _bytes(line(r)))
    out.sort(key=lambda r: _sort_number(rid(r)), reverse=True)
    out.sort(key=lambda r: _bytes(created(r)), reverse=True)
    return out


def newest_first_lines(text: str, created_col: int, id_col: int) -> str:
    """``newest_first`` over tab-separated lines, as the shell piped them through it."""

    def col(row: str, n: int) -> str:
        cols = row.split("\t")
        return cols[n - 1] if len(cols) >= n else ""

    rows = text.split("\n")
    return "\n".join(
        newest_first(rows, lambda r: col(r, created_col), lambda r: col(r, id_col), lambda r: r)
    )
