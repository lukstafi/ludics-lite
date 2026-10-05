"""The reads a watch round shares with the state beside it: the round snapshot, the head read, a
review's own comments, and the substantive-review filter.

Ported from pr-review.sh's "round snapshot" section (``snapshot_*``, ``state_comments``,
``state_reviews``, ``state_head_read``, ``review_comments``), ``pr_head_read`` and
``substantive_reviews``. The shell kept the snapshot in FILES because every reader ran inside a
command substitution; here it is the ``Snapshot`` object the watch holds, with the same three
rules: it is armed only inside a watch round; a part is served only when it is about the PR asked
for; and only a read that answered is published, a failed round dropping what it had.

One shell detail is kept on purpose: dropping a round (``snapshot_drop``) empties it but leaves it
ARMED, so a review's comments read after the drop are still cached for the rest of that round.
"""

from dataclasses import dataclass, field
from typing import assert_never

from ludics.prreview.core import (
    GhFailed,
    GhOk,
    GhSession,
    GhUnanswered,
    Json,
    ListOk,
    ListUnparsed,
    api_list,
)
from ludics.prreview.clock import Clock
from ludics.prreview.watch_jq import (
    JqError,
    as_list,
    body_of,
    idx,
    jstr,
    login_is,
    onig,
    sub_once,
    test,
    type_name,
)


@dataclass(frozen=True)
class Head:
    """``pr_head_read``'s four variables: the head SHA ("" when the read failed), the
    mergeability ("unread" when it failed, "-" when the PR carried none), the PR's creation ("" when
    absent), and the error line of a failed read."""

    sha: str
    mstate: str
    created: str
    err: str


@dataclass
# SHARED-CANDIDATE: snapshot_arm snapshot_drop snapshot_off snapshot_put_feeds snapshot_put_head snapshot_has
class Snapshot:
    armed: bool = False
    feeds_pr: str = ""
    comments: list[Json] = field(default_factory=lambda: list[Json]())
    reviews: list[Json] = field(default_factory=lambda: list[Json]())
    head_pr: str = ""
    head: Head | None = None
    review_cache: dict[str, list[Json]] = field(default_factory=lambda: dict[str, list[Json]]())

    def clear(self) -> None:
        self.feeds_pr = ""
        self.comments = []
        self.reviews = []
        self.head_pr = ""
        self.head = None
        self.review_cache = {}

    def arm(self) -> None:
        """``snapshot_arm``: a new round, nothing observed before it readable as part of it."""
        self.clear()
        self.armed = True

    def drop(self) -> None:
        """``snapshot_drop``: the round ended without an observation worth sharing."""
        self.clear()

    def off(self) -> None:
        """``snapshot_off``: the watch is over."""
        self.armed = False
        self.clear()

    def put_feeds(self, pr: str, comments: list[Json], reviews: list[Json]) -> None:
        if not self.armed:
            return
        self.comments = comments
        self.reviews = reviews
        self.feeds_pr = pr

    def put_head(self, pr: str, head: Head) -> None:
        if not self.armed:
            return
        self.head = head
        self.head_pr = pr

    def has_feeds(self, pr: str) -> bool:
        return self.armed and self.feeds_pr == pr

    def has_head(self, pr: str) -> bool:
        return self.armed and self.head is not None and self.head_pr == pr


@dataclass
class Ctx:
    """What every read of one watch shares: the gh session, the repository and the reviewer, the
    clock, how long a live 👀 may run before it is stalled (STALL), the round snapshot, and -- inside a watch only -- the issue-comment watermark the watch
    started from, which the state reads its pending request against (``watch_nudge_after``, a
    watch_loop local the shell's status_state reached by dynamic scoping)."""

    session: GhSession
    repo: str
    reviewer: str
    clock: Clock
    stall: int
    snap: Snapshot = field(default_factory=Snapshot)
    nudge_after: int | None = None


class ReadFailed(Exception):
    """A feed read failed: ``api_list``'s nonzero status. The caller words what it means."""


def feed(ctx: Ctx, path: str) -> list[Json]:
    """``api_list``: the whole feed, or ``ReadFailed``."""
    result = api_list(ctx.session, path, ctx.repo)
    match result:
        case ListOk(items=items):
            return items
        case GhFailed() | GhUnanswered() | ListUnparsed():
            raise ReadFailed()
        case _:
            assert_never(result)


# SHARED-CANDIDATE: state_comments
def state_comments(ctx: Ctx, pr: str) -> list[Json]:
    if ctx.snap.has_feeds(pr):
        return ctx.snap.comments
    return feed(ctx, f"issues/{pr}/comments?per_page=100")


# SHARED-CANDIDATE: state_reviews
def state_reviews(ctx: Ctx, pr: str) -> list[Json]:
    if ctx.snap.has_feeds(pr):
        return ctx.snap.reviews
    return feed(ctx, f"pulls/{pr}/reviews?per_page=100")


def ifs_read(line: str, count: int, ifs: str = "\t") -> list[str]:
    """``IFS=<whitespace> read -r a b c``: leading and trailing separators dropped, a run of them
    one separator, the last variable taking the rest of the line."""
    rest = line.split("\n", 1)[0].strip(ifs)
    out: list[str] = []
    for _ in range(count - 1):
        if not rest:
            out.append("")
            continue
        i = 0
        while i < len(rest) and rest[i] not in ifs:
            i += 1
        out.append(rest[:i])
        rest = rest[i:].lstrip(ifs)
    out.append(rest)
    return out


# SHARED-CANDIDATE: pr_head_read
def pr_head_read(ctx: Ctx, pr: str) -> Head:
    result = ctx.session.retry(
        "read",
        [
            "api",
            f"repos/{ctx.repo}/pulls/{pr}",
            "--jq",
            '[(.head.sha // "-"), (.mergeable_state // "-"), (.created_at // "-")] | @tsv',
        ],
    )
    match result:
        case GhOk(stdout=line):
            sha, mstate, created = ifs_read(line, 3)
            return Head(
                sha="" if sha == "-" else sha,
                mstate=mstate or "-",
                created="" if (created or "-") == "-" else created,
                err="",
            )
        case GhFailed() | GhUnanswered():
            return Head(sha="", mstate="unread", created="", err=ctx.session.err_line())
        case _:
            assert_never(result)


# SHARED-CANDIDATE: state_head_read
def state_head_read(ctx: Ctx, pr: str) -> Head:
    if ctx.snap.has_head(pr) and ctx.snap.head is not None:
        h = ctx.snap.head
        return Head(h.sha, h.mstate or "-", h.created, h.err)
    return pr_head_read(ctx, pr)


# SHARED-CANDIDATE: review_comments
def review_comments(ctx: Ctx, pr: str, review_id: str) -> list[Json]:
    """A review's own comments endpoint, read at most once per round for a given review: only a
    read that answered is cached, so a failure is never served as a review with no findings."""
    path = f"pulls/{pr}/reviews/{review_id}/comments?per_page=100"
    if not review_id.isdigit() or not review_id.isascii():
        return feed(ctx, path)
    if ctx.snap.armed and review_id in ctx.snap.review_cache:
        return ctx.snap.review_cache[review_id]
    out = feed(ctx, path)
    if ctx.snap.armed:
        ctx.snap.review_cache[review_id] = out
    return out


# The connector's fixed replies (ludics-lite#472): see CONNECTOR_FIXED_REPLIES in pr-review.sh.
CONNECTOR_FIXED_REPLIES = (
    "To use Codex here, [create an environment for this repo]"
    "(https://chatgpt.com/codex/cloud/settings/environments).",
)
_NON_SPACE = onig("[^[:space:]]")
_TRAILING_SPACE = onig("[[:space:]]+\\z")


class NotSubstantive(Exception):
    """``substantive_reviews`` returned 1: the review comments could not establish which reviews
    carry findings."""


def _fixed_reply(comment: Json) -> bool:
    in_reply = idx(comment, "in_reply_to_id")
    if not isinstance(in_reply, (int, float)) or isinstance(in_reply, bool):
        return False
    body = idx(comment, "body")
    if not isinstance(body, str):
        return False
    return sub_once(body, _TRAILING_SPACE, "") in CONNECTOR_FIXED_REPLIES


# SHARED-CANDIDATE: substantive_reviews
def substantive_reviews(ctx: Ctx, pr: str, raw: list[Json]) -> list[Json]:
    """The reviews feed minus the empty-bodied COMMENTED envelopes whose own comments carry no
    finding: none at all (#88), or only the connector's fixed thread replies (#472)."""
    try:
        ids: list[str] = []
        for r in raw:
            if not login_is(r, ctx.reviewer):
                continue
            if not (idx(r, "state") == "COMMENTED" and idx(r, "submitted_at") is not None):
                continue
            if test(body_of(r), _NON_SPACE):
                continue
            ids.append(jstr(idx(r, "id")))
    except JqError:
        raise NotSubstantive() from None
    for line in "\n".join(ids).split("\n"):
        rid = line
        if not rid:
            continue
        if not (rid.isdigit() and rid.isascii()):
            raise NotSubstantive()
        try:
            inline = review_comments(ctx, pr, rid)
        except ReadFailed:
            raise NotSubstantive() from None
        try:
            fixed = all(_fixed_reply(c) for c in as_list(inline))
        except JqError:
            fixed = False
        if fixed:
            num = int(rid)
            kept: list[Json] = []
            for r in raw:
                try:
                    rid_value = idx(r, "id")
                except JqError:
                    raise NotSubstantive() from None
                if not (type_name(rid_value) == "number" and rid_value == num):
                    kept.append(r)
            raw = kept
    return raw

