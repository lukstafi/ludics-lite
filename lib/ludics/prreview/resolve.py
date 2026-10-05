"""``pr-review.sh resolve <pr> <comment-id>[+<comment-id>...]``: close every review thread the token
names, each answered on its own line.

Ported from the shell's ``cmd_resolve``, ``resolve_one``, ``find_thread``, ``thread_page`` and the
walk they read through, ``threads_walk`` (ludics-lite#403). The token is ``reply``'s, so a folded
entry is closed by one invocation too. Unlike a reply, this is safe to repeat whole: the mutation is
idempotent and an already-resolved thread costs no write.

Threads are addressed by node id, which is only reachable by matching a thread's FIRST comment, by
the id the open-thread gate names it by (``fullDatabaseId``, the BigInt string, ahead of
``databaseId``, a 32-bit Int while review comment ids already run past 2^31; review of #370). The
lookup reads the same connection as the gate, through the same walk, to the same page cap, so
every thread the gate can name is one ``resolve`` can reach (round 1 of #370's review: the two once
paged to different caps). "Not found" is concluded only when EVERY page came back and the rows add
up to the PR's totalCount: a short read is a hole the id could be hiding in (9197c23: a 503'd page
announced "no review thread starts at comment N" for three threads that all existed).

Stdout: ``true`` for one id; ``<id> true`` per id for several; ``true (already resolved)`` for a
thread already closed. Exit: 0 every thread is closed; 1 no thread starts at that comment, or the
API rejected the mutation; 2 usage, or GraphQL rejected the lookup (about the query, not the id);
3 the lookup or the mutation did not complete. Every refusal past the first id names the ids
already closed by this invocation.
"""

import json
import os
import re
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Literal, assert_never

from ludics import cli
from ludics.prreview.core import (
    GhFailed,
    GhOk,
    GhSession,
    GhUnanswered,
    Json,
    die,
    fail,
    json_stream,
    pr_arg,
)
from ludics.prreview.reply import split_ids

# --- the review-threads walk (shared with the open-thread gate) -------------------------------------

THREADS_QUERY = """query($owner:String!, $name:String!, $pr:Int!, $after:String) {
  repository(owner:$owner, name:$name) { pullRequest(number:$pr) {
    reviewThreads(first:100, after:$after) {
      totalCount pageInfo { hasNextPage endCursor }
      nodes { id isResolved path
        comments(first:1) { nodes { fullDatabaseId databaseId author { login } } } } } } } }"""

# The shell's THREADS_PAGE_CAP is a constant no caller's environment sets; the forwarder hands the
# shell's value over under this private name, so a suite that retunes it reaches the Python too.
PAGE_CAP_ENV = "LUDICS_THREADS_PAGE_CAP"
PAGE_CAP_DEFAULT = 50


# SHARED-CANDIDATE: THREADS_PAGE_CAP
def page_cap(env: Mapping[str, str]) -> int:
    text = env.get(PAGE_CAP_ENV, "")
    return int(text) if re.fullmatch(r"[0-9]+", text) else PAGE_CAP_DEFAULT


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


# SHARED-CANDIDATE: THREAD_ID_JQ
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


# SHARED-CANDIDATE: threads_walk
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


# --- resolve ----------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Found:
    """``find_thread``'s 0: the thread starting at the comment, as ``<node id> <isResolved>``."""

    node: str
    resolved: str


@dataclass(frozen=True)
class Missing:
    """``find_thread``'s 1: every page was read and no thread begins at the comment."""


type Lookup = Found | Missing | WalkRejected | WalkUnread


def find_thread(session: GhSession, repo: str, pr: str, comment_id: str, *, cap: int) -> Lookup:
    """``find_thread`` and its page reader ``thread_page``: the thread whose first comment is
    ``comment_id``, matched as the string GitHub serves (the token admits leading zeros)."""
    wanted = re.sub(r"^0+(?=.)", "", comment_id)
    hit: list[Found] = []

    def page(conn: dict[str, Json]) -> PageVerdict:
        nodes = conn.get("nodes")
        assert isinstance(nodes, list)
        # jq reads every node before the walk sees its output, so a node that does not parse
        # spoils the page even after a hit.
        try:
            names = [(node, thread_id(node)) for node in nodes]
            hits = [
                Found(jq_text(jq_field(node, "id")), jq_text(jq_field(node, "isResolved")))
                for node, name in names
                if name == wanted
            ]
        except JqError:
            return "unparsed"
        if hits:
            hit.append(hits[0])
            return "stop"
        return "more"

    walked = threads_walk(session, repo, pr, page, cap=cap)
    match walked:
        case WalkDone():
            return hit[0] if hit else Missing()
        case WalkRejected() | WalkUnread():
            return walked
        case _:
            assert_never(walked)


_MUTATION = (
    "mutation {{\n      resolveReviewThread(input:{{threadId:\"{node}\"}}) {{\n"
    "      thread {{ isResolved }} }} }}"
)


def resolve_one(
    session: GhSession,
    repo: str,
    pr: str,
    comment_id: str,
    *,
    label: bool,
    done_ids: list[str],
    cap: int,
) -> None:
    """``resolve_one``: one thread, closed. With ``label`` (several ids in the token) each answer is
    prefixed with the id it is about; ``done_ids`` are named in every refusal, so a caller knows
    where it stopped."""
    progress = ""
    if done_ids:
        progress = (
            f" Already resolved in this invocation: {' '.join(done_ids)} — resolving is\n"
            "idempotent, so the whole token is safe to repeat."
        )
    on = f"PR {repo}#{pr}"
    lookup = find_thread(session, repo, pr, comment_id, cap=cap)
    match lookup:
        case Found():
            pass
        case WalkUnread(line=why):
            fail(
                3,
                f"the thread lookup on {on} did not complete: {why} — thread resolution has no",
                "REST equivalent, so this is a RETRY, not a missing thread: the threads are probably all",
                "there, and the reply (REST) may well have gone through. Do NOT read this as someone else",
                f"having resolved it or as a wrong comment id.{progress}",
            )
        case WalkRejected():
            fail(
                2,
                f"GraphQL REJECTED the thread lookup for {on}: {session.err_line()}.",
                f"The search never ran, so this says nothing about comment {comment_id} — check the repo, the PR",
                f"number and `gh auth status` rather than the comment id.{progress}",
            )
        case Missing():
            fail(
                1,
                f"no review thread starts at comment {comment_id} — every page of {on} was read and",
                f"none of them begins there (this is a real answer, not a dropped request){progress}",
            )
        case _:
            assert_never(lookup)
    prefix = f"{comment_id} " if label else ""
    # Already-resolved is the goal state, not a no-op worth an API write.
    if lookup.resolved == "true":
        cli.say(f"{prefix}true (already resolved)")
        return
    # The mutation is idempotent -- resolving a resolved thread just answers true -- so it is
    # retried like a read, on anything short of the API rejecting it.
    result = session.retry(
        "read",
        [
            "api",
            "graphql",
            "-f",
            "query=" + _MUTATION.format(node=lookup.node.split(" ", 1)[0]),
            "--jq",
            ".data.resolveReviewThread.thread.isResolved",
        ],
    )
    match result:
        case GhOk(stdout=out):
            cli.say(f"{prefix}{out}")
        case GhUnanswered():
            fail(
                3,
                f"resolveReviewThread did not answer for the thread at comment {comment_id} on {on}",
                f"after {session.config.api_attempts} attempts ({session.err_line()}); the thread was FOUND, so this is transport",
                f"only — retry when the API recovers, and the mutation is safe to repeat.{progress}",
            )
        case GhFailed():
            fail(
                1,
                f"resolveReviewThread was rejected for the thread at comment {comment_id} on {on}:",
                f"{session.err_line()}{progress}",
            )
        case _:
            assert_never(result)


def run(session: GhSession, args: list[str], *, env: Mapping[str, str] | None = None) -> int:
    if len(args) != 2:
        die(f"usage: resolve <pr> <comment-id>[+<comment-id>...] — got {len(args)} argument(s)")
    target = pr_arg(args[0], session.config.repo)
    ids = split_ids(args[1], "resolve")
    cap = page_cap(os.environ if env is None else env)
    label = len(ids) > 1
    resolved: list[str] = []
    for comment_id in ids:
        resolve_one(
            session, target.repo, target.num, comment_id, label=label, done_ids=resolved, cap=cap
        )
        resolved.append(comment_id)
    return 0
