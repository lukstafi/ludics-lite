"""Open review threads, as ``merge`` reads them before every attempt (ludics-lite#289).

Ported from pr-review.sh's ``threads_walk``, ``unresolved_threads``/``unresolved_page``,
``threads_named``, ``threads_advice`` and ``merge_threads_gate`` (they live in the status region of
the shell; ``status``, ``watch`` and ``resolve`` read the same connection). Boundary, as the shell
states it: a thread is closed only when ``isResolved`` is literally true; the first comment's id
(``fullDatabaseId`` before ``databaseId``), author and path NAME a thread and never judge it. The
connection is read whole -- the rows reaching the ``totalCount`` its last page states -- or the
read is refused as unread, never taken for "none are open".
"""

import json
from dataclasses import dataclass
from typing import assert_never

from ludics.prreview.core import GhFailed, GhOk, GhSession, GhUnanswered, Json, fail, shell_quote
from ludics.prreview.shtext import JqError, is_number, jq_alt, jq_get, jq_tostring, tab_fields

# SHARED-CANDIDATE: THREADS_QUERY
THREADS_QUERY = """query($owner:String!, $name:String!, $pr:Int!, $after:String) {
  repository(owner:$owner, name:$name) { pullRequest(number:$pr) {
    reviewThreads(first:100, after:$after) {
      totalCount pageInfo { hasNextPage endCursor }
      nodes { id isResolved path
        comments(first:1) { nodes { fullDatabaseId databaseId author { login } } } } } } } }"""


@dataclass(frozen=True)
class Unread:
    """The connection was not read whole: the one line saying why."""

    reason: str


def _tsv_field(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n").replace("\r", "\\r")


def _page_rows(page: Json) -> list[str] | None:
    """``unresolved_page``: one "<id>\\t<author>\\t<path>" row per open thread of the page, or None
    when the page's nodes do not read (jq would have failed on them)."""
    try:
        nodes = jq_get(page, "nodes")
        if not isinstance(nodes, list):
            return None
        rows: list[str] = []
        for node in nodes:
            if jq_get(node, "isResolved") is True:
                continue
            first = jq_get(node, "comments", "nodes", 0)
            ident = jq_tostring(jq_alt(jq_get(first, "fullDatabaseId"), jq_get(first, "databaseId"), "-"))
            login = jq_tostring(jq_alt(jq_get(node, "comments", "nodes", 0, "author", "login"), "-"))
            path = jq_tostring(jq_alt(jq_get(node, "path"), "-"))
            rows.append("\t".join(_tsv_field(v) for v in (ident, login, path)))
        return rows
    except JqError:
        return None


# SHARED-CANDIDATE: unresolved_threads
def unresolved_threads(session: GhSession, repo: str, pr: str, page_cap: int) -> list[str] | Unread:
    """``threads_walk`` with ``unresolved_page``: the open threads' rows, or why they are unread."""
    owner = repo.split("/", 1)[0]
    name = repo.rsplit("/", 1)[-1]
    cursor = ""
    read_n = 0
    rows: list[str] = []
    for page in range(1, page_cap + 1):
        after = ["-f", f"after={cursor}"] if cursor else []
        result = session.retry(
            "read",
            [
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
                *after,
                "--jq",
                ".data.repository.pullRequest.reviewThreads",
            ],
        )
        match result:
            case GhOk(stdout=resp):
                pass
            case GhFailed():
                return Unread(f"GraphQL REJECTED the review-threads read ({session.err_line()})")
            case GhUnanswered():
                return Unread(
                    f"GraphQL did not answer the review-threads read after {session.config.api_attempts}"
                    f" attempts ({session.err_line()})"
                )
            case _:
                assert_never(result)
        try:
            doc: Json = json.loads(resp)
        except ValueError:
            doc = None
        total = n = None
        has_next = False
        if isinstance(doc, dict):
            nodes = doc.get("nodes")
            count = doc.get("totalCount")
            info = doc.get("pageInfo")
            nxt = info.get("hasNextPage") if isinstance(info, dict) else None
            if isinstance(nodes, list) and is_number(count) and isinstance(nxt, bool):
                assert isinstance(count, (int, float))
                total = count
                n = len(nodes)
                has_next = nxt
                end = info.get("endCursor") if isinstance(info, dict) else None
                cursor = jq_tostring(jq_alt(end, ""))
        if total is None or n is None or not float(total).is_integer() or total < 0:
            return Unread(f"the review-threads read answered page {page} without a thread connection")
        page_rows = _page_rows(doc)
        if page_rows is None:
            return Unread(f"the review-threads read answered page {page} with threads that did not parse")
        rows.extend(page_rows)
        read_n += n
        if not has_next:
            if read_n < int(total):
                return Unread(f"the review-threads read ended at {read_n} thread(s) while the PR states {int(total)}")
            return rows
        if not cursor:
            return Unread(f"the review-threads read said page {page} has a successor and gave no cursor to it")
    return Unread(
        f"the review-threads read was still paging after {page_cap} pages of 100, so it is refused rather"
        f" than judged on its first {read_n} thread(s)"
    )


# SHARED-CANDIDATE: threads_named
def threads_named(rows: list[str]) -> tuple[int, str]:
    """``threads_named``: the count, and the first ten named ("<id> by <author> on <path>")."""
    shown: list[str] = []
    n = 0
    for row in rows:
        ident, login, path = tab_fields(row, 3)
        if not ident:
            continue
        n += 1
        if n <= 10:
            shown.append(f"{ident} by {login} on {shell_quote(path)}")
    text = ", ".join(shown)
    if n > 10:
        text += f", and {n - 10} more"
    return n, text


# SHARED-CANDIDATE: threads_advice
def threads_advice(repo: str, pr: str) -> str:
    """``threads_advice``: what clears an open thread."""
    return (
        "An open thread is a finding nobody closed, whatever head it cites: one written"
        " against an earlier head is live if this head did not change its lines, and `watch` prints"
        " such findings as NOT about head and moves past them (ludics-lite#289). Read each one, answer"
        f" it with a fix or a rebuttal (pr-review.sh reply {repo}#{pr or '<pr>'} <id> '<answer>'), then"
        f" close it (pr-review.sh resolve {repo}#{pr or '<pr>'} <id>); clearing this needs no push"
    )


# SHARED-CANDIDATE: merge_threads_gate
def merge_threads_gate(session: GhSession, repo: str, pr: str, page_cap: int) -> None:
    """``merge_threads_gate``: open threads refuse the merge (1); an unread connection refuses as
    transport (3) -- neither is "none are open"."""
    rows = unresolved_threads(session, repo, pr, page_cap)
    if isinstance(rows, Unread):
        fail(
            3,
            f"NOT merging {repo}#{pr}: {rows.reason} — whether review threads are still open is UNKNOWN, which",
            "is not 'none are'; retry.",
        )
    if not rows:
        return
    count, named = threads_named(rows)
    fail(
        1,
        f"REFUSING to merge {repo}#{pr}: {count} review thread(s) still UNRESOLVED —",
        f"{named}. {threads_advice(repo, pr)}.",
    )
