"""``pr-review.sh poll <pr> [watermark]``: the reviewer's activity above a per-feed watermark.

Ported from the shell's ``cmd_poll`` and ``POLL_ITEM_DEFS`` (ludics-lite#403). The shell comments
there carry every rule's incident; the short form:

  - three feeds (inline comments, issue comments, reviews), each with its own watermark field,
    because their ids are not comparable;
  - every NEW review's own comments endpoint is read too and merged by id, the flat feed's copy
    winning, because the flat listing lags a fresh review; that read failing fails the round;
  - every rendered item carries the commit it is ABOUT (an inline comment's original_commit_id,
    a review's commit_id, a comment's LAST "Reviewed commit:" stamp), ``-`` when there is none;
  - inline threads at one ANCHOR (the row minus its ids, urls, times, reactions, links, review id
    and body) fold into one entry addressed by every id, ``900+901``, each distinct body shown;
  - the connector's round-started placeholder is not rendered, but the watermark passes it;
  - its "About Codex in GitHub" block folds to one line in summary and review bodies;
  - an ``items:`` line indexes what was rendered (kind:id:commit:author:state), then the
    ``watermark:`` line, last.

Exit: 0 a round that answered; 3 a feed (or a new review's comments) did not answer — no
watermark, so the caller keeps its own; 4 a feed answered a shape its read could not take — no
watermark either. Every read goes through ``jqsem`` so the shapes that failed the shell's jq fail
here, at the same point and after the same output.
"""

import re
from collections.abc import Callable
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
    mark_of,
    pr_arg,
    warn,
)
from ludics.prreview.reads import (
    PLACEHOLDER,
    REVIEWED_COMMIT,
    CacheUnparsed,
    Snapshot,
    by_reviewer,
    hand_back_err_line,
    review_comments,
    snapshot_from_env,
)


class _Refused(Exception):
    """The round ends with ``rc`` and no watermark."""

    def __init__(self, rc: int) -> None:
        super().__init__(rc)
        self.rc = rc


# --- POLL_ITEM_DEFS -------------------------------------------------------------------------------


def short(v: Json) -> str:
    """``short``: the first seven characters, or ``-`` for none."""
    a = jq.alt(v, "")
    if jq.eq(a, ""):
        return "-"
    return jq.text(jq.head_slice(a, 7))


def item_stamp(item: Json, pattern: re.Pattern[str]) -> str:
    """``item_stamp``: the LAST stamp in the body (the connector writes it as a footer)."""
    found = [m.get("s") for m in jq.capture_all(jq.alt(jq.idx(item, "body"), ""), pattern)]
    return short(found[-1] if found else None)


def inline_commit(item: Json) -> str:
    return short(jq.alt(jq.idx(item, "original_commit_id"), jq.idx(item, "commit_id")))


def review_commit(item: Json) -> str:
    return short(jq.idx(item, "commit_id"))


def item_path(item: Json) -> str:
    return jq.text(jq.alt(jq.idx(item, "path"), "?"))


def anchor(start: Json, line: Json) -> str:
    return f"{jq.text(start)}-{jq.text(line)}" if start is not None else jq.text(line)


def item_line(item: Json) -> str:
    line = jq.alt(jq.idx(item, "line"), jq.idx(item, "original_line"))
    if line is not None:
        return anchor(jq.alt(jq.idx(item, "start_line"), jq.idx(item, "original_start_line")), line)
    pos = jq.alt(jq.idx(item, "position"), jq.idx(item, "original_position"))
    return f"@{jq.text(pos)}" if pos is not None else "?"


def item_side(item: Json) -> str:
    out = " side=LEFT" if jq.eq(jq.alt(jq.idx(item, "side"), ""), "LEFT") else ""
    start_side = jq.idx(item, "start_side")
    if start_side is not None and not jq.eq(start_side, jq.alt(jq.idx(item, "side"), "RIGHT")):
        out += f" start_side={jq.text(start_side)}"
    return out


def item_was(item: Json) -> str:
    line = jq.alt(jq.idx(item, "line"), jq.idx(item, "original_line"))
    if line is not None:
        start = jq.alt(jq.idx(item, "start_line"), jq.idx(item, "original_start_line"))
        oline = jq.idx(item, "original_line")
        ostart = jq.idx(item, "original_start_line")
        if (oline is not None and not jq.eq(oline, line)) or (
            ostart is not None and not jq.eq(ostart, start)
        ):
            return f" was={anchor(ostart, jq.alt(oline, line))}"
        return ""
    pos = jq.alt(jq.idx(item, "position"), jq.idx(item, "original_position"))
    opos = jq.idx(item, "original_position")
    if pos is not None and opos is not None and not jq.eq(opos, pos):
        return f" was=@{jq.text(opos)}"
    return ""


_FOLD_DROPPED = frozenset(
    "id node_id url html_url pull_request_url pull_request_review_id created_at updated_at"
    " reactions _links body".split()
)


def fold_key(item: Json) -> str:
    """``fold_key | tojson``: the row minus the fields two posts of one finding differ in."""
    if not isinstance(item, dict):
        if item is None:
            return "null"
        raise jq.JqError(f"Cannot delete field at object index of {jq.kind(item)}")
    return jq.tojson({k: v for k, v in item.items() if k not in _FOLD_DROPPED})


def _index_of(haystack: list[Json], needle: Json) -> bool:
    """``haystack | index(needle)`` used as a condition: found (a position, even 0) or null."""
    if isinstance(needle, list):
        n = len(needle)
        if n == 0:
            return False
        return any(
            all(jq.eq(haystack[i + j], needle[j]) for j in range(n))
            for i in range(len(haystack) - n + 1)
        )
    return any(jq.eq(h, needle) for h in haystack)


def fold_inline(items: list[Json]) -> list[Json]:
    """``fold_inline``: threads at one anchor become one entry, in the order they arrived."""
    groups: dict[str, list[Json]] = {}
    for item in items:
        groups.setdefault(fold_key(item), []).append(item)
    out: list[Json] = []
    for members in groups.values():
        bodies: list[Json] = []
        for member in members:
            body = jq.alt(jq.idx(member, "body"), "")
            if _index_of([jq.idx(b, "body") for b in bodies], body):
                continue
            bodies.append({"id": jq.idx(member, "id"), "body": body})
        first = members[0]
        if not isinstance(first, dict):
            raise jq.JqError(f"{jq.kind(first)} and object cannot be added")
        entry: dict[str, Json] = dict(first)
        entry["thread_ids"] = [jq.idx(m, "id") for m in members]
        entry["thread_bodies"] = bodies
        out.append(entry)
    return out


def _thread_ids(item: Json) -> Json:
    return jq.alt(jq.idx(item, "thread_ids"), [jq.idx(item, "id")])


def _length(v: Json) -> int:
    if isinstance(v, (list, str, dict)):
        return len(v)
    if v is None:
        return 0
    raise jq.JqError(f"{jq.kind(v)} has no length")


def thread_list(item: Json) -> str:
    ids = _thread_ids(item)
    if not isinstance(ids, list):
        raise jq.JqError(f"Cannot iterate over {jq.kind(ids)}")
    return "+".join(jq.text(i) for i in ids)


def _thread_bodies(item: Json) -> Json:
    return jq.alt(
        jq.idx(item, "thread_bodies"),
        [{"id": jq.idx(item, "id"), "body": jq.alt(jq.idx(item, "body"), "")}],
    )


def body_block(item: Json) -> str:
    bodies = _thread_bodies(item)
    if _length(bodies) <= 1:
        return jq.text(jq.idx(jq.nth(bodies, 0), "body"))
    if not isinstance(bodies, list):
        raise jq.JqError(f"Cannot iterate over {jq.kind(bodies)}")
    return "\n".join(
        f"[thread {jq.text(jq.idx(b, 'id'))}]\n{jq.text(jq.idx(b, 'body'))}" for b in bodies
    )


def dupe_note(item: Json) -> str:
    n = _length(_thread_ids(item))
    k = _length(_thread_bodies(item))
    if n <= 1:
        return ""
    if k <= 1:
        return f" ({n} identical threads, one reply answers all)"
    return f" ({n} threads at one location, {k} findings as written; one reply answers all)"


CODEX_ABOUT_OPEN = "<details> <summary>ℹ️ About Codex in GitHub</summary>"
CODEX_ABOUT_FOLDED = '[Codex "About Codex in GitHub" boilerplate folded]'


def fold_codex_about(body: Json) -> str:
    """``fold_codex_about``: the connector's trailing "About Codex in GitHub" block, exactly as it
    writes it and ending the body, as one line; anything else as it is (ludics-lite#358)."""
    text = jq.alt(body, "")
    parts = jq.split(text, CODEX_ABOUT_OPEN)
    if len(parts) < 2:
        return jq.text(text)
    tail = jq.split(parts[-1], "</details>")
    if len(tail) == 2 and not jq.test(tail[1], jq.NONSPACE):
        return CODEX_ABOUT_OPEN.join(parts[:-1]) + CODEX_ABOUT_FOLDED
    return jq.text(text)


# --- the round ------------------------------------------------------------------------------------


def _new_items(
    feed: list[Json], reviewer: str, since: int, keep: Callable[[Json], bool] = lambda _i: True
) -> list[Json]:
    """``map(select(login) | select(.id > $since) | <keep>)``."""
    return [
        item
        for item in feed
        if by_reviewer(item, reviewer) and jq.gt(jq.idx(item, "id"), since) and keep(item)
    ]


def _watermark(feed: list[Json], mark: int) -> str:
    """``[.[][].id // 0, $m] | max``, printed as jq prints it."""
    ids = [i for i in (jq.idx(item, "id") for item in feed) if jq.truthy(i)]
    return jq.tojson(jq.jmax([*(ids or [0]), mark]))


def _print_each[T](items: list[T], render: Callable[[T], str]) -> None:
    """One jq rendering: each item printed as it is made, and an item that cannot be rendered
    ending the round (4) after whatever was printed before it."""
    for item in items:
        try:
            text = render(item)
        except jq.JqError:
            raise _Refused(4) from None
        cli.say(text)


def _login(item: Json) -> str:
    return jq.text(jq.path(item, "user", "login"))


def _render_inline(i: Json) -> str:
    return (
        f"--- inline id={thread_list(i)} {item_path(i)}:{item_line(i)}{item_side(i)}{item_was(i)}"
        f" commit={inline_commit(i)} by {_login(i)}{dupe_note(i)}\n{body_block(i)}"
    )


def _render_summary(i: Json) -> str:
    return (
        f"--- summary id={jq.text(jq.idx(i, 'id'))} commit={item_stamp(i, REVIEWED_COMMIT)}"
        f" by {_login(i)}\n{fold_codex_about(jq.idx(i, 'body'))}"
    )


def _render_review(i: Json) -> str:
    return (
        f"--- review id={jq.text(jq.idx(i, 'id'))} state={jq.text(jq.idx(i, 'state'))}"
        f" commit={review_commit(i)} by {_login(i)}\n{fold_codex_about(jq.idx(i, 'body'))}"
    )


def poll_round(
    session: GhSession, repo: str, pr: str, mark: str, snapshot: Snapshot | None = None
) -> int:
    reviewer = session.config.reviewer
    m_inline, m_issue, m_review = mark_of(mark, 1), mark_of(mark, 2), mark_of(mark, 3)
    feeds: dict[str, list[Json]] = {}
    bad = ""
    for name, endpoint in (
        ("inline", f"pulls/{pr}/comments?per_page=100"),
        ("summary", f"issues/{pr}/comments?per_page=100"),
        ("reviews", f"pulls/{pr}/reviews?per_page=100"),
    ):
        result = api_list(session, endpoint, repo)
        match result:
            case ListOk(items=items):
                feeds[name] = items
            case GhFailed() | GhUnanswered() | ListUnparsed():
                bad += f" {name}"
            case _:
                assert_never(result)
    if bad:
        warn(
            f"API error reading PR {pr} feed(s):{bad} after {session.config.api_attempts} attempts each",
            f"({session.err_line()}) — this round is UNKNOWN, not quiet",
        )
        return 3
    inline, issue, reviews = feeds["inline"], feeds["summary"], feeds["reviews"]
    if snapshot is not None:
        snapshot.put_feeds(pr, issue, reviews)

    try:
        new_review_ids = [
            jq.text(jq.idx(r, "id")) for r in _new_items(reviews, reviewer, m_review)
        ]
    except jq.JqError:
        warn(f"could not read which reviews on PR {pr} are new — this round is UNKNOWN, not quiet")
        return 3
    extra: list[Json] = []
    # The shell split the ids on whitespace, unquoted.
    for rid in " ".join(new_review_ids).split():
        more = review_comments(session, repo, pr, rid, snapshot)
        match more:
            case ListOk(items=items):
                extra = extra + items
            case CacheUnparsed():
                return 4
            case GhFailed() | GhUnanswered() | ListUnparsed():
                warn(
                    f"API error reading review {rid}'s comments on PR {pr} after"
                    f" {session.config.api_attempts} attempts",
                    f"({session.err_line()}) — this round is UNKNOWN, not quiet",
                )
                return 3
            case _:
                assert_never(more)

    try:
        have = [jq.idx(i, "id") for i in inline]
        inline = inline + [e for e in extra if not _index_of(have, jq.idx(e, "id"))]
        new_inline = fold_inline(_new_items(inline, reviewer, m_inline))
        new_issue = _new_items(
            issue,
            reviewer,
            m_issue,
            lambda i: not jq.test(jq.alt(jq.idx(i, "body"), ""), PLACEHOLDER),
        )
        new_reviews = _new_items(reviews, reviewer, m_review)
    except jq.JqError:
        return 4

    try:
        if new_inline:
            _print_each(new_inline, _render_inline)
        else:
            cli.say("(no new inline comments)")
        _print_each(new_issue, _render_summary)
        _print_each(new_reviews, _render_review)
    except _Refused as refused:
        return refused.rc
    # The index of what was rendered, each field built before the line exists (#89).
    try:
        items_inline = " ".join(
            f"inline:{thread_list(i)}:{inline_commit(i)}:{_login(i)}:-" for i in new_inline
        )
        items_issue = " ".join(
            f"summary:{jq.text(jq.idx(i, 'id'))}:{item_stamp(i, REVIEWED_COMMIT)}:{_login(i)}:-"
            for i in new_issue
        )
        items_review = " ".join(
            f"review:{jq.text(jq.idx(i, 'id'))}:{review_commit(i)}:{_login(i)}:"
            f"{jq.text(jq.alt(jq.idx(i, 'state'), '-'))}"
            for i in new_reviews
        )
    except jq.JqError:
        return 4
    cli.say(f"items: {items_inline} {items_issue} {items_review}")
    try:
        marks = (
            _watermark(inline, m_inline),
            _watermark(issue, m_issue),
            _watermark(reviews, m_review),
        )
    except jq.JqError:
        return 4
    cli.say(f"watermark: {','.join(marks)}")
    return 0


def run(session: GhSession, args: list[str]) -> int:
    if not args or not args[0]:
        cli.exit_with(1, "1: usage: poll <pr> [watermark]")
    target = pr_arg(args[0], session.config.repo)
    mark = args[1] if len(args) > 1 else ""
    try:
        return poll_round(session, target.repo, target.num, mark, snapshot_from_env())
    finally:
        hand_back_err_line(session)


# --- the history, moved from pr-review.sh with the code it explained (ludics-lite#403) ------------
# What follows is the shell's own commentary on POLL_ITEM_DEFS and cmd_poll, verbatim: the
# incident behind every rule above. Where it names a jq construct, the function above with the
# same name is its port.
#
# The commit each kind of item is ABOUT, as one jq prelude shared by the rendering and the index
# below, so the two can never disagree about an item. Spliced into a jq program, which is why it
# carries no apostrophe.
#
# An inline comment is bound by `original_commit_id`, NOT `commit_id`: GitHub migrates the latter
# forward as the head advances for a comment whose lines still exist, so a previous round finding
# would stamp itself with the CURRENT head and pass any head test put to it. original_commit_id is
# the commit the reviewer wrote it against, and it does not move. Nothing is lost if that ever
# proves too strict: every inline finding belongs to a review, poll re-reads each NEW review own
# comments endpoint (above), and the review row carries the head it was submitted against — so a
# round of the head is caught by its review even if none of its comments were.
#
# A comment has no such field; its only head association is the "**Reviewed commit:** `<sha>`"
# stamp the connector writes on the comments it delivers a round or a verdict in. The LAST match
# is the one taken: the connector writes that stamp as a FOOTER, and a findings body can quote
# another commit above it — a review OF this parsing logic does exactly that — where taking the
# first would stamp the round with a commit it merely mentions and discard it as an old head.
# `[capture(...; "g")] | last` and never `capture(...) // ""`, because a capture that does not
# match produces NO output rather than null, and a zero-output sub-expression inside a string
# interpolation takes the whole string with it: the comment would not be rendered at all, which
# on the initialization failure (the one summary that never carries the stamp) is a round
# silently disappearing from the watch that was waiting for it.
#
# `fold_inline` is the last of these: the reviewer posts one finding as several inline threads
# often enough to matter (round 11 of ludics-lite#66 posted nine threads for four findings,
# ludics-lite#76), and each duplicate then costs its own composed reply and its own resolve. The
# fold groups such threads into one entry whose `thread_ids` lists every one of them, anchor first,
# and the rendering and the index both address it by that list (`id=900+901`) — the token `reply`
# and `resolve` take, so what poll printed is what the caller pastes back.
#
# What folds is a PLACE, not a text. Two threads fold when they are the same anchor — same path,
# same commit, same author, and identical in every location field the row carries — and the BODY
# is deliberately not part of that, which is the whole difference between a fold that fires and
# one that never does. Measured against the round the issue was filed on (#66 head 252e336):
# grouping by body finds ZERO groups among that PR's 51 findings, while grouping by the anchor
# finds exactly four, covering nine threads — the issue's own arithmetic — and not one of them
# mixes unrelated findings. The reviewer duplicates a finding by RE-WRITING it (the three threads
# at :447 carry bodies of 546, 575 and 570 characters saying the same thing), so a key that
# demanded equal text would have been a feature that could not fire.
#
# Nothing is lost by that, because the entry prints every DISTINCT body, each under the id of the
# thread carrying it (`body_block`), and only an exact repeat is printed once. So the caller sees
# every word the reviewer wrote, under one id token, and answers once.
#
# The key is a DENY-LIST — the whole row minus the eleven fields that must differ between two
# posts of one finding (the ids, the urls, the timestamps, the reactions, the links, the review
# id) and the body. Every other field is identifying by default, present or future, so a field
# GitHub adds later can only make the fold fire LESS, never more: unfolded is loud (one extra
# reply) and over-folded is silent (a finding answered by a reply it never got, its id already
# behind the watermark). That is also why the location fields are not enumerated: `line`,
# `original_line`, `side`, `start_line`, `start_side`, `original_start_line`, `position`,
# `original_position` and `subject_type` are all in the key without being named, and so is the
# next one. Two of these were found the expensive way, one per round: the per-review comments
# endpoint (the one poll re-reads when the flat feed lags a new review) serves rows with NO `line`
# and no `original_line` at all, carrying `position`/`original_position` instead — every such row
# renders `:@<position>`, so an enumerating key collapsed two findings in one file (#86 round 1)
# — and `side`/`start_line` do the same for a LEFT-vs-RIGHT or multi-line anchor (#86 round 2).
# The RENDERING names them even so (`item_side`, `item_was` below, #113): the key and the header
# have different jobs, and a key that must separate on a field nobody has heard of leaves the
# header owing the reader every separation it CAN explain.
#
# `pull_request_review_id` is in the deny-list for a measured reason, not a tidy one: the reviewer
# posts a separate COMMENTED review per inline comment (46 comments over 36 reviews on #39), so
# keeping it would have kept every real duplicate apart.
#
# The commit stamp is in the key for a second reason: it is what `watch` classifies an item by, and
# folding across two stamps would force one head verdict onto two different associations.
# Grouping is by the key's `tojson` — a STRING — because jq's `index` on an array argument searches
# for a sub-SEQUENCE rather than an element, so a key kept as an array would match its neighbours
# prefixes. Order is the feed's: `group_by` sorts by key, and `pos` (each group's first member's
# index) puts the entries back in the order they arrived, so folding does not reshuffle a round.
# The line half of an anchor: the range when the row carries a start, the line alone otherwise.
# A start equal to the end still renders as a range — GitHub refuses `start_line == line`, so
# the shape does not arise from the API, and collapsing it to a bare line would print a row the
# key separates on identically to one with no start at all.
# A row from the per-review comments endpoint (what poll reads while the flat feed lags a new
# review) carries no `line` and no `original_line` at all, only `position`/`original_position`.
# Rendering that as `0` printed an unknown location in the shape of a known one, and two rows
# at different places in one file read as the same place — which is what hid the collapse in
# round 1 of #86 from the eye. An unknown line says so (`?`), and a position says which field it is
# (`@12`), so nothing downstream reads a location that was never served as a line number.
# The rest of the anchor, in the `k=v` grammar the rest of the header already speaks
# (ludics-lite#113). The key above separates on `side`, `start_line`, `start_side` and
# `original_start_line` — #86 round 2 put them there because a LEFT-vs-RIGHT or multi-line
# anchor was folding two distinct findings into one — while the header named none of them, so a
# deletion commented on the left and an addition on the right at line 40 of one file printed two
# rows byte-identical apart from the id and correctly did not fold. That reads as the reviewer
# posting one finding twice and the fold failing to catch it, which is the mirror of the `:0`
# defect of #105 and costs the reader the same round: either the anchors are re-derived from the
# API by hand, or the fold stops being trusted, which is what the fold note exists to prevent.
#
# Only what is NOT the default prints. RIGHT is the side of every row that is not about a
# deleted line, and a `side=RIGHT` on every entry would be noise bought at the price of the one
# row where the side matters; `start_side` prints when it differs from the side of the end,
# the only case where naming one side reads a range wrong. A header cannot be a
# total discriminator for a deny-list key — the next field GitHub invents is in the key and not
# on this line, which is the direction the key is deliberately wrong in — so what this owes the
# reader is every anchor field the row actually carries, not a proof of distinctness.
# Where the finding was WRITTEN, when that is not where it sits now. GitHub migrates `line` and
# `start_line` forward as the branch advances while the `original_*` pair stays put, and both
# pairs are in the key, so two findings written at different places can sit at one place today
# and print one header between them. The same rule as the side fields: it prints only when the
# row carries an original that differs from what was rendered.
#
# In whichever unit the row is anchored by. A row from the per-review endpoint has no line at
# all and migrates in `position`/`original_position` instead, both of them in the key, so it
# has the same defect one field over and gets the same token (review of #272, round 1). The two
# units are never mixed on one line: a position is a second name for a place a row with lines
# has already named, and the API computes it from the same diff, so a pair of rows agreeing on
# both line fields cannot disagree on it.
# The connector ends every review body it writes with a fixed "About Codex in GitHub" block
# (ludics-lite#358): some fifteen lines of trigger instructions, 18 of the 44 lines one round of
# #354 printed. It sits at the TAIL, the part of a long round the Bash display keeps, so it
# pushes the findings above it toward the part the display cuts. The rendering folds it into one
# line. The boundary is a fail-closed ALLOWLIST of one exact shape, and anything outside it
# renders as-is:
#   - the opener is the literal bytes `<details> <summary>` U+2139 U+FE0F ` About Codex in
#     GitHub</summary>` (the text the connector writes, as served in the reviews of #354), so
#     another summary, a missing variation selector or a different spacing is not the block;
#   - the block is the text after the LAST such opener, and it must hold exactly one
#     `</details>` with nothing but whitespace after it: the block ends the body. An unterminated
#     block, a block followed by more text, or a second `</details>` renders as-is, and an
#     earlier opener (a finding QUOTING the line) can never swallow the findings after it;
#   - the interior is not read, since its wording differs between the variants the connector
#     writes.
# It is applied to the summary and review bodies only, where the connector writes the block;
# an inline finding is never folded. It is RENDERING only: the stamp `item_stamp` reads, the
# `items:` line and the watermark all read the raw body or the ids, never this output.
#
# Exits 3, and prints no watermark, when any feed failed to read: an unwritten watermark keeps the
# caller's old one, so a transient error cannot advance past findings it never saw.
#
# The one read of these feeds the round makes. status_state takes its comments and reviews from
# here instead of reading them again a second later (see "the round snapshot"), so the state a
# round is reported beside is computed from the very bytes the round was classified from. The
# UNFILTERED feeds: poll's question is "what is new since the watermark" and the state's is "what
# has the reviewer ever said", and the second cannot be answered from the first's leftovers.
# Nothing is published unless all three answered — the return above is what a failed read owes
# the caller, and a snapshot of two feeds would hand the state an empty third.
#
# A new review's inline comments can lag the flat listing read above (see the header), so every
# review this round is about to report gets its own comments endpoint read too, merged by
# comment id — the flat feed's copy wins when both exist, since only it carries current line
# numbers. A failed per-review read fails the ROUND (unknown, watermark unwritten): the
# alternative is printing the review while silently dropping its findings.
# The list of reviews to re-read is itself a read that can fail. Unguarded it failed EMPTY —
# indistinguishable from "no new reviews this round" — and the round would then render every
# review without its own comments and still advance the watermark past them (#89).
#
# Every rendered item carries the commit it is ABOUT, short, as `commit=<sha7>` — the field
# `watch` reads to tell the round it is waiting for from an older one scrolling past
# (ludics-lite#72). `-` where the feed carries no association at all, and nothing downstream
# may read that as "another commit": a missing stamp is not evidence.
#
# For an inline comment that is `original_commit_id`, NOT `commit_id`: GitHub migrates
# `commit_id` forward as the head advances for a comment whose lines still exist, so a previous
# round's finding would stamp itself with the CURRENT head and pass any head test put to it.
# `original_commit_id` is the commit the comment was written against — the reviewer's own view
# of the code — and it does not move. Nothing is lost if that ever proves too strict: every
# inline finding belongs to a review, poll re-reads each NEW review's own comments endpoint
# (see above), and the review row itself carries the head it was submitted against — so a round
# of the head is caught by its review even if none of its comments were.
# Each feed's new items are filtered ONCE, into an array that is then both rendered and indexed
# (the `items:` line below), so the index cannot drift from what was printed — and so the fold
# of duplicate threads (`fold_inline`, ludics-lite#76) has ONE place to sit: it happens here,
# once, and the rendering and the index below read its output. A folded entry is still one
# finding for `watch` (it counts entries, not threads) and the watermark is untouched — that is
# computed from the UNFILTERED feed below, so every duplicate's id is still advanced past.
# `rounds` reads its own feeds and never these, so the round count is untouched too.
#
# The connector's "Review Summary" placeholder is machine-tagged with an HTML comment and posted
# the moment a round STARTS ("🔄 Running"); it carries no findings, but its id is above the
# watermark, so rendering it made `watch` return 0 with nothing to act on — one wasted wake and
# re-arm per PR (observed landing self-improve#10, 2026-08-29, and again on #13 the day the fix
# landed). It is dropped from the RENDERING only: the watermark below reads the unfiltered feed,
# so its id is advanced past and never replayed. Nothing is lost by hiding it — the comment is
# thereafter EDITED in place (same id, invisible to a watermark feed by construction), findings
# arrive as reviews and inline comments, and a no-findings verdict arrives as the 👍 or as its
# own "Didn't find any major issues" comment, both of which status_state reads live.
#
# A comment's only head association is the stamp POLL_ITEM_DEFS describes; one carrying none
# renders `commit=-`, and nothing downstream may read that as "another commit".
#
# The items above, as one machine-readable line, for a caller that has to decide something about
# them — `watch` asks which of them are about the head it is watching. Fields per item:
# kind:id:commit:author:state (`-` where there is none), and none of the five can contain a
# space or a colon, so the line is safe to split. The id field of a FOLDED inline entry is the
# `+`-joined list of its thread ids, anchor first (`inline:900+901:…`) — the same token the
# rendering shows and `reply`/`resolve` take; a consumer wanting the anchor alone takes the part
# before the first `+`. It stays one field precisely so that this line's arity never depends on
# whether the reviewer duplicated a thread. The rendered headers are NOT that line: a
# BODY may contain a line that looks exactly like one — a review of this script quoting poll
# output does, and this very PR drew one — and a watch that classified by scanning the rendering
# would take a quoted header for an item and end the wait on the round it was there to skip.
# Read it as the watermark is read, the LAST match: it is emitted after every body, so a body
# that quotes one of these lines cannot displace it.
#
# Each field is built into a variable before the line is echoed, rather than inside the `echo`'s
# command substitutions: a jq that failed there contributed an empty field and the line still
# printed, so a broken program read downstream as "this round had no items of that kind" — the
# same silent defect the state line's arms exist to prevent (#89). A failed render exits 4 with
# the watermark unwritten, so the round is retried rather than advanced past.
#
# Pass this back verbatim next time: per-feed maxima, so replies you post in this round cannot
# read back as new findings and a big review id cannot mask a smaller comment id. Same rule as
# the items line: an empty field here would be read back as the watermark 0 and replay the
# whole feed, so each maximum is taken before the line exists.
