"""``pr-review.sh rounds <pr>``: how many review rounds carried findings, against the threshold.

Ported from the shell's ``review_rounds``, ``rounds_line``, ``count_token`` and ``cmd_rounds``
(ludics-lite#403); their comments carry the rules' history. A round is a burst of the reviewer's
COMMENTED (or CHANGES_REQUESTED) reviews on one head, or a comment-only round, in submission
order: a new round starts on a different head (a prefix of the other counts as the same) or more
than SHIP_PR_ROUND_GAP seconds after the previous item. Not rounds: pending reviews, the author's
own replies, the round-started placeholder, a no-findings verdict, an initialization failure
(either shape), and an empty envelope holding nothing but the connector's fixed reply.

Stdout: the count line, then the trailer ``rounds: n=<count|unknown> threshold=<n|off>``.
Exit: 0 at or under the threshold (or none set), 1 past it, 3 the count could not be read.
"""

from dataclasses import dataclass
from typing import assert_never

from ludics import cli
from ludics.prreview import jqsem as jq
from ludics.prreview.core import (
    GhFailed,
    GhSession,
    GhUnanswered,
    Json,
    ListOk,
    ListUnparsed,
    api_list,
    pr_arg,
)
from ludics.prreview.reads import (
    INIT_FAILURE,
    PLACEHOLDER,
    REVIEWED_COMMIT,
    VERDICT,
    Snapshot,
    by_reviewer,
    is_digits,
    substantive_reviews,
)


@dataclass(frozen=True)
class _Item:
    sha: Json
    t: int


def _same(a: Json, b: Json) -> bool:
    """``same($a; $b)``: equal, or one a prefix of the other (a comment quotes a truncated sha)."""
    if jq.eq(a, b):
        return True
    if a is None or b is None or jq.eq(a, "") or jq.eq(b, ""):
        return False
    return jq.startswith(a, b) or jq.startswith(b, a)


def _count(
    reviews: list[Json],
    comments: list[Json],
    reviewer: str,
    gap: int,
    icap: int | None,
    rcap: int | None,
) -> int:
    """review_rounds' count program. Raises JqError where it errored."""
    items: list[_Item] = []
    for r in reviews:
        if not by_reviewer(r, reviewer):
            continue
        if rcap is not None and jq.gt(jq.alt(jq.idx(r, "id"), 0), rcap):
            continue
        if jq.eq(jq.idx(r, "submitted_at"), None):
            continue
        state = jq.idx(r, "state")
        if not (jq.eq(state, "COMMENTED") or jq.eq(state, "CHANGES_REQUESTED")):
            continue
        items.append(
            _Item(jq.alt(jq.idx(r, "commit_id"), ""), jq.fromdateiso8601(jq.idx(r, "submitted_at")))
        )
    for c in comments:
        if not by_reviewer(c, reviewer):
            continue
        if icap is not None and jq.gt(jq.alt(jq.idx(c, "id"), 0), icap):
            continue
        body = jq.alt(jq.idx(c, "body"), "")
        if jq.test(body, PLACEHOLDER) or jq.test(body, VERDICT) or jq.test(body, INIT_FAILURE):
            continue
        stamp = jq.capture(body, REVIEWED_COMMIT)
        sha = jq.alt(None if stamp is None else stamp.get("s"), "comment")
        items.append(_Item(sha, jq.fromdateiso8601(jq.idx(c, "created_at"))))
    n, sha, t = 0, None, 0
    for item in sorted(items, key=lambda i: i.t):
        if not _same(item.sha, sha) or item.t - t > gap:
            n, sha, t = n + 1, item.sha, item.t
        else:
            t = item.t
    return n


def _heads(reviews: list[Json], reviewer: str) -> int:
    shas = [
        jq.alt(jq.idx(r, "commit_id"), "")
        for r in reviews
        if by_reviewer(r, reviewer)
        and not jq.eq(jq.idx(r, "submitted_at"), None)
        and (jq.eq(jq.idx(r, "state"), "COMMENTED") or jq.eq(jq.idx(r, "state"), "CHANGES_REQUESTED"))
    ]
    return len([s for s in jq.unique(shas) if not jq.eq(s, "")])


# SHARED-CANDIDATE: review_rounds
def review_rounds(
    session: GhSession,
    repo: str,
    pr: str,
    icap: int | None = None,
    rcap: int | None = None,
    snapshot: Snapshot | None = None,
) -> str:
    """``review_rounds``: ``<count>|<detail>``, the count ``unknown`` when a read failed. The caps
    count only the comments and reviews at or below those ids (the count as of a watermark)."""
    reviewer = session.config.reviewer
    listed = api_list(session, f"pulls/{pr}/reviews?per_page=100", repo)
    match listed:
        case ListOk(items=reviews):
            pass
        case GhFailed() | GhUnanswered() | ListUnparsed():
            return f"unknown|the reviews API did not answer ({session.err_line()})"
        case _:
            assert_never(listed)
    raw = substantive_reviews(session, repo, pr, reviews, snapshot)
    if raw is None:
        return "unknown|the review comments API did not establish substantive reviews"
    listed = api_list(session, f"issues/{pr}/comments?per_page=100", repo)
    match listed:
        case ListOk(items=comments):
            pass
        case GhFailed() | GhUnanswered() | ListUnparsed():
            return f"unknown|the comments API did not answer ({session.err_line()})"
        case _:
            assert_never(listed)
    try:
        count = _count(raw, comments, reviewer, session.config.round_gap, icap, rcap)
    except jq.JqError:
        return "unknown|the reviews feed did not parse"
    try:
        heads = str(_heads(raw, reviewer))
    except jq.JqError:
        heads = "?"
    return f"{count}|{count} round(s) of {reviewer} findings over {heads} head(s)"


def threshold_text(threshold: int | None) -> str:
    return "off" if threshold is None else str(threshold)


# SHARED-CANDIDATE: rounds_line
def rounds_line(result: str, threshold: int | None) -> tuple[str, int]:
    """``rounds_line``: the line, and 0 at or under the threshold, 1 past it, 3 unread."""
    count, _, detail = result.partition("|")
    if "|" not in result:
        detail = result
    if count == "unknown":
        return f"review rounds: UNKNOWN — {detail}; this is NOT 'no rounds yet', retry", 3
    if threshold is None:
        return f"review rounds with findings: {count} ({detail}); no threshold set", 0
    n = int(count)
    if n > threshold:
        return (
            f"review rounds with findings: {count}, PAST the {threshold}-round threshold —"
            " blocking-only from here: use ship-pr's narrow criteria — consequential defects"
            " introduced or materially worsened by the PR, invalidated central claims or evidence,"
            " or failed build-relevant checks (all non-advisory checks). Merely exposing a severe"
            " pre-existing defect does not block. Defer the rest to ONE follow-up issue, and merge"
            f" on the first round with nothing to push ({detail})",
            1,
        )
    if n == threshold:
        return (
            f"review rounds with findings: {count} of {threshold} — the last round addressed in"
            f" full; from the next, only blocking findings are fixed ({detail})",
            0,
        )
    return f"review rounds with findings: {count} of {threshold} ({detail})", 0


# SHARED-CANDIDATE: count_token
def count_token(result: str) -> str:
    count = result.split("|", 1)[0]
    return count if is_digits(count) else "unknown"


def run(session: GhSession, args: list[str]) -> int:
    if not args or not args[0]:
        cli.exit_with(1, "1: usage: rounds <pr>")
    target = pr_arg(args[0], session.config.repo)
    result = review_rounds(session, target.repo, target.num)
    line, rc = rounds_line(result, session.config.round_threshold)
    cli.say(line)
    cli.say(
        f"rounds: n={count_token(result)} threshold={threshold_text(session.config.round_threshold)}"
    )
    return rc
