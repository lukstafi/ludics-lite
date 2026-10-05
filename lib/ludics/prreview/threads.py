"""The PR's review threads: the walk every reader of the connection pages through, and the
open-thread gate (ludics-lite#289) ``status``, ``watch`` and ``merge`` apply under an approval.

Ported once from pr-review.sh's ``THREADS_QUERY``, ``THREAD_ID_JQ``, ``threads_walk``,
``unresolved_threads``/``unresolved_page``, ``threads_named``, ``threads_advice`` and
``merge_threads_gate``; ``resolve``'s lookup (``find_thread``) reads the same connection through the
same walk, to the same page cap, so every thread the gate can name is one ``resolve`` can reach.
Boundary, as the shell states it: a thread is closed only when ``isResolved`` is literally true; the
first comment's id (``fullDatabaseId`` before ``databaseId``), author and path NAME a thread and
never judge it. The connection is read whole -- the rows reaching the ``totalCount`` its last page
states -- or the read is refused as unread, never taken for "none are open".
"""

import json
from collections.abc import Callable
from dataclasses import dataclass
from typing import Literal, assert_never

from ludics.prreview.core import (
    GhFailed,
    GhOk,
    GhSession,
    GhUnanswered,
    Json,
    fail,
    json_stream,
    shell_quote,
)
from ludics.prreview.shtext import tab_fields

THREADS_QUERY = """query($owner:String!, $name:String!, $pr:Int!, $after:String) {
  repository(owner:$owner, name:$name) { pullRequest(number:$pr) {
    reviewThreads(first:100, after:$after) {
      totalCount pageInfo { hasNextPage endCursor }
      nodes { id isResolved path
        comments(first:1) { nodes { fullDatabaseId databaseId author { login } } } } } } } }"""

@dataclass(frozen=True)
class WalkDone:
    """The page reader stopped the walk (it has what it wanted), or the whole connection was read:
    the rows reached the totalCount the last page states."""


@dataclass(frozen=True)
class WalkRejected:
    """GraphQL rejected the query (threads_walk's 4): nothing about any thread is known."""

    line: str


@dataclass(frozen=True)
class WalkUnread:
    """The read did not complete (threads_walk's 3): no answer, a malformed or short answer, or the
    page cap. None of it is evidence about any thread."""

    line: str


type WalkResult = WalkDone | WalkRejected | WalkUnread
type PageVerdict = Literal["more", "stop", "unparsed"]


class JqError(Exception):
    """What jq would have failed on: a field read off a value that is not an object, an index off
    one that is not an array."""


def jq_field(value: Json, key: str) -> Json:
    """jq's ``.key``: null passes through as null, an object answers, anything else is an error."""
    if value is None:
        return None
    if isinstance(value, dict):
        return value.get(key)
    raise JqError(key)


def jq_first(value: Json) -> Json:
    """jq's ``.[0]``: null for null or an empty array."""
    if value is None:
        return None
    if isinstance(value, list):
        return value[0] if value else None
    raise JqError("0")


def jq_alt(left: Json, right: Json) -> Json:
    """jq's ``//``: the right side for null and false."""
    return right if left is None or left is False else left


def jq_text(value: Json) -> str:
    """jq's ``tostring``, which string interpolation also applies: a string as itself, anything
    else as its compact JSON."""
    if isinstance(value, str):
        return value
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def thread_id(node: Json) -> str:
    """THREAD_ID_JQ, ``((.comments.nodes[0] | .fullDatabaseId // .databaseId // "-") | tostring)``:
    a thread's name, its first comment's id, full width first. Raises ``JqError`` where jq erred."""
    first = jq_first(jq_field(jq_field(node, "comments"), "nodes"))
    return jq_text(jq_alt(jq_alt(jq_field(first, "fullDatabaseId"), jq_field(first, "databaseId")), "-"))


@dataclass(frozen=True)
class _Meta:
    total: int
    n: int
    has_next: bool
    cursor: str


def _connection(resp: str) -> tuple[dict[str, Json], _Meta] | None:
    """The page's connection and what the walk reads off it, or None when the answer is not a
    connection: an object with a nodes array, a numeric totalCount and a boolean hasNextPage (a
    ``pullRequest`` of null, GraphQL's way of erroring inside a 200, is refused with the rest)."""
    docs = json_stream(resp)
    if not docs:
        return None
    conn = docs[0]
    if not isinstance(conn, dict):
        return None
    nodes = conn.get("nodes")
    total = conn.get("totalCount")
    try:
        has_next = jq_field(conn.get("pageInfo"), "hasNextPage")
        cursor = jq_alt(jq_field(conn.get("pageInfo"), "endCursor"), "")
    except JqError:
        return None
    if not isinstance(nodes, list) or not isinstance(has_next, bool):
        return None
    # "\(.totalCount)" must be digits alone: a bool is no number, and a float prints with a point.
    if not isinstance(total, int) or isinstance(total, bool) or total < 0:
        return None
    return conn, _Meta(total, len(nodes), has_next, jq_text(cursor))


def threads_walk(
    session: GhSession,
    repo: str,
    pr: str,
    on_page: Callable[[dict[str, Json]], PageVerdict],
    *,
    cap: int,
) -> WalkResult:
    """``threads_walk``: page PR ``pr``'s reviewThreads with THREADS_QUERY, the cursor passed as a
    variable, handing each page's connection to ``on_page`` -- ``more`` to read on, ``stop`` when
    it has what it wanted, ``unparsed`` when the page's threads did not parse. The read is whole
    only when the rows read reach the totalCount the last page states; one still paging at ``cap``
    pages is refused as unread rather than judged on its prefix."""
    owner = repo.split("/", 1)[0]
    name = repo.rsplit("/", 1)[-1]
    cursor = ""
    read_n = 0
    for page in range(1, cap + 1):
        args = [
            "api",
            "graphql",
            "-f",
            f"query={THREADS_QUERY}",
            "-F",
            f"owner={owner}",
            "-F",
            f"name={name}",
            "-F",
            f"pr={pr}",
        ]
        if cursor:
            args += ["-f", f"after={cursor}"]
        args += ["--jq", ".data.repository.pullRequest.reviewThreads"]
        result = session.retry("read", args)
        match result:
            case GhOk(stdout=resp):
                pass
            case GhFailed():
                return WalkRejected(f"GraphQL REJECTED the review-threads read ({session.err_line()})")
            case GhUnanswered():
                return WalkUnread(
                    "GraphQL did not answer the review-threads read after"
                    f" {session.config.api_attempts} attempts ({session.err_line()})"
                )
            case _:
                assert_never(result)
        parsed = _connection(resp)
        if parsed is None:
            return WalkUnread(f"the review-threads read answered page {page} without a thread connection")
        conn, meta = parsed
        verdict = on_page(conn)
        match verdict:
            case "more":
                pass
            case "stop":
                return WalkDone()
            case "unparsed":
                return WalkUnread(
                    f"the review-threads read answered page {page} with threads that did not parse"
                )
            case _:
                assert_never(verdict)
        read_n += meta.n
        if not meta.has_next:
            if read_n < meta.total:
                return WalkUnread(
                    f"the review-threads read ended at {read_n} thread(s) while the PR states {meta.total}"
                )
            return WalkDone()
        cursor = meta.cursor
        if not cursor:
            return WalkUnread(
                f"the review-threads read said page {page} has a successor and gave no cursor to it"
            )
    return WalkUnread(
        f"the review-threads read was still paging after {cap} pages of 100, so it is refused"
        f" rather than judged on its first {read_n} thread(s)"
    )


# --- the open-thread gate ---------------------------------------------------------------------------


def _tsv_field(value: str) -> str:
    """One field of jq's ``@tsv``."""
    return value.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


def open_rows(conn: dict[str, Json]) -> list[str]:
    """``unresolved_page``: ``<first comment id>\\t<author>\\t<path>`` per thread of the page
    whose isResolved is not literally true. Raises ``JqError`` where jq erred on a node."""
    nodes = conn.get("nodes")
    assert isinstance(nodes, list)
    rows: list[str] = []
    for node in nodes:
        if jq_field(node, "isResolved") is True:
            continue
        first = jq_first(jq_field(jq_field(node, "comments"), "nodes"))
        author = jq_text(jq_alt(jq_field(jq_field(first, "author"), "login"), "-"))
        path = jq_text(jq_alt(jq_field(node, "path"), "-"))
        rows.append("\t".join(_tsv_field(v) for v in (thread_id(node), author, path)))
    return rows


@dataclass(frozen=True)
class OpenThreads:
    """The connection was read whole: the open threads' rows (none is an answer)."""

    rows: list[str]


type Unresolved = OpenThreads | WalkRejected | WalkUnread


def unresolved_threads(session: GhSession, repo: str, pr: str, cap: int) -> Unresolved:
    """``unresolved_threads``: ``threads_walk`` with ``unresolved_page`` -- every open thread, or
    why the connection is unread."""
    rows: list[str] = []

    def page(conn: dict[str, Json]) -> PageVerdict:
        try:
            rows.extend(open_rows(conn))
        except JqError:
            return "unparsed"
        return "more"

    walked = threads_walk(session, repo, pr, page, cap=cap)
    match walked:
        case WalkDone():
            return OpenThreads(rows)
        case WalkRejected() | WalkUnread():
            return walked
        case _:
            assert_never(walked)


def threads_named(rows: list[str]) -> tuple[int, str]:
    """``threads_named``: the count, and the first ten named ("<id> by <author> on <path>", the
    path shell-quoted)."""
    n = 0
    shown = ""
    for row in rows:
        ident, login, path = tab_fields(row, 3)
        if not ident:
            continue
        n += 1
        if n > 10:
            continue
        shown += (", " if shown else "") + f"{ident} by {login} on {shell_quote(path)}"
    if n > 10:
        shown += f", and {n - 10} more"
    return n, shown


def threads_advice(repo: str, num: str) -> str:
    """``threads_advice``: what clears an open thread."""
    pr = num or "<pr>"
    return (
        "An open thread is a finding nobody closed, whatever head it cites: one written against an"
        " earlier head is live if this head did not change its lines, and `watch` prints such"
        " findings as NOT about head and moves past them (ludics-lite#289). Read each one, answer"
        f" it with a fix or a rebuttal (pr-review.sh reply {repo}#{pr} <id> '<answer>'), then close"
        f" it (pr-review.sh resolve {repo}#{pr} <id>); clearing this needs no push"
    )


def merge_threads_gate(session: GhSession, repo: str, pr: str, page_cap: int) -> None:
    """``merge_threads_gate``: open threads refuse the merge (1); an unread connection refuses as
    transport (3) -- neither is "none are open"."""
    found = unresolved_threads(session, repo, pr, page_cap)
    match found:
        case WalkRejected(line=why) | WalkUnread(line=why):
            fail(
                3,
                f"NOT merging {repo}#{pr}: {why} — whether review threads are still open is UNKNOWN, which",
                "is not 'none are'; retry.",
            )
        case OpenThreads(rows=rows):
            if not rows:
                return
            count, named = threads_named(rows)
            fail(
                1,
                f"REFUSING to merge {repo}#{pr}: {count} review thread(s) still UNRESOLVED —",
                f"{named}. {threads_advice(repo, pr)}.",
            )
        case _:
            assert_never(found)
