"""The reviewer state `status` reports, ported from pr-review.sh's ``status_state`` and the
functions around it (ludics-lite#403).

  status_state      one line, ``<token>|<seconds>|<mergeability>|<detail>``: approved, reviewing,
                    stalled, failed, expected, idle, nudged (a watch's pending request), unknown
  status_line       that line rendered for a reader
  approval_gate     an ``approved`` line checked for open review threads (#289): unresolved, or
                    unknown when the thread read did not answer
  threads_walk ...  the reviewThreads connection, paged to the end or refused

The shell comments above each of these carry the incident behind every comparison; the order of
the reads and of the arms below is theirs, and so is every message. Each feed is read through
``jqsem``, so a shape the shell's jq refused is refused here at the same arm (``... did not
parse``). The state line is a string because `watch` (still shell) and the suites read it as one.
"""

from collections.abc import Callable
from dataclasses import dataclass
from typing import assert_never

from ludics.prreview import jqsem as jq
from ludics.prreview.core import (
    GhFailed,
    GhOk,
    GhSession,
    GhUnanswered,
    Json,
    ListOk,
    ListResult,
    ListUnparsed,
    api_list,
    json_stream,
    shell_quote,
)
from ludics.prreview.reads import (
    CODE_REVIEW_ROW,
    FRACTION_Z,
    INIT_FAILURE,
    INIT_FAILURE_ENV_ONLY,
    INIT_FAILURE_REF,
    NUDGE_BODY,
    PLACEHOLDER,
    PLACEHOLDER_TAG,
    REQUEST,
    REVIEWED_COMMIT,
    RUNNING_ROW,
    SUMMARY_COMPLETED_ROW,
    SUMMARY_FAILED_ROW,
    SUMMARY_ROW_STAMP,
    VERDICT,
    Head,
    age_of,
    by_reviewer,
    commit_date,
    fmt_age,
    freshest_age,
    instant,
    is_digits,
    newest,
    pr_head_read,
    substantive_reviews,
)


def _before(s: str) -> str:
    """``${s%%|*}``."""
    return s.split("|", 1)[0]


def _after(s: str) -> str:
    """``${s#*|}``: the whole string when it holds no ``|``."""
    return s.split("|", 1)[1] if "|" in s else s


# SHARED-CANDIDATE: state_tok
def state_tok(line: str) -> str:
    return _before(line)


# SHARED-CANDIDATE: state_age
def state_age(line: str) -> str:
    return _before(_after(line))


# SHARED-CANDIDATE: state_merge
def state_merge(line: str) -> str:
    return _before(_after(_after(line)))


# SHARED-CANDIDATE: state_detail
def state_detail(line: str) -> str:
    return _after(_after(_after(line)))


def _after_nudge(event: str, nudge_at: str) -> bool:
    """``review_after_nudge``."""
    return not nudge_at or event > nudge_at


@dataclass(frozen=True)
class StateConfig:
    reviewer: str
    stall: int


class _Reads:
    """status_state's reads of one PR, each made at most once and in the shell's order."""

    def __init__(self, session: GhSession, repo: str, pr: str) -> None:
        self.session = session
        self.repo = repo
        self.pr = pr

    def comments(self) -> ListResult:
        return api_list(self.session, f"issues/{self.pr}/comments?per_page=100", self.repo)

    def reviews(self) -> ListResult:
        return api_list(self.session, f"pulls/{self.pr}/reviews?per_page=100", self.repo)

    def head(self) -> Head:
        return pr_head_read(self.session, self.repo, self.pr)

    def commit_date(self, sha: str) -> str:
        return commit_date(self.session, self.repo, sha)


def _items(result: ListResult) -> list[Json] | None:
    match result:
        case ListOk(items=items):
            return items
        case GhFailed() | GhUnanswered() | ListUnparsed():
            return None
        case _:
            assert_never(result)


def _summaries(comments: list[Json], reviewer: str) -> list[Json]:
    """``[.[] | reviewer | select((.body // "") | contains(<the summary tag>))]``."""
    return [
        c
        for c in comments
        if by_reviewer(c, reviewer) and jq.contains(jq.alt(jq.idx(c, "body"), ""), PLACEHOLDER_TAG)
    ]


def _newest_summary(summaries: list[Json]) -> Json:
    return jq.max_by(summaries, lambda c: jq.alt(jq.idx(c, "updated_at"), jq.idx(c, "created_at")))


def _lines(body: Json) -> list[str]:
    return jq.split(jq.alt(body, ""), "\n")


def _strip_fraction(at: Json) -> str:
    return jq.sub(at, FRACTION_Z, "Z")


def _evidence(comments: list[Json], reviews: list[Json], reviewer: str, head: str) -> str:
    """The 👍 path's current-head evidence: ``<kind>|<at>|<unread Running rows>|<row sha>``."""
    running: list[dict[str, Json] | None] = []
    for c in _summaries(comments, reviewer):
        for row in _lines(jq.idx(c, "body")):
            if jq.test(row, RUNNING_ROW):
                running.append(jq.capture(row, SUMMARY_ROW_STAMP))
    newest_summary = _newest_summary(_summaries(comments, reviewer))
    rows: list[dict[str, Json] | None] = []
    if newest_summary is not None:
        rows = [
            jq.capture(row, SUMMARY_ROW_STAMP)
            for row in _lines(jq.idx(newest_summary, "body"))
            if jq.test(row, CODE_REVIEW_ROW)
        ]
    row_sha = ""
    if rows and all(r is not None for r in rows):
        known = [r for r in rows if r is not None]
        best = jq.max_by(known, lambda r: instant(r.get("at")))
        row_sha = jq.add_str("", None if best is None else best.get("sha"))
    entries: list[dict[str, Json]] = []
    for r in running:
        if r is not None:
            entries.append({**r, "kind": "running"})
    for review in reviews:
        if by_reviewer(review, reviewer) and not jq.eq(jq.idx(review, "submitted_at"), None):
            entries.append(
                {
                    "sha": jq.alt(jq.idx(review, "commit_id"), ""),
                    "at": jq.idx(review, "submitted_at"),
                    "kind": "findings",
                }
            )
    for c in comments:
        if not by_reviewer(c, reviewer):
            continue
        stamps = jq.capture_all(jq.alt(jq.idx(c, "body"), ""), REVIEWED_COMMIT)
        entries.append(
            {
                "sha": jq.alt(stamps[-1].get("s") if stamps else None, ""),
                "at": jq.alt(jq.idx(c, "updated_at"), jq.idx(c, "created_at")),
                "kind": "verdict" if jq.test(jq.alt(jq.idx(c, "body"), ""), VERDICT) else "findings",
            }
        )
    current: list[dict[str, Json]] = []
    for e in entries:
        sha = e.get("sha")
        if jq.eq(sha, "") or head == "":
            continue
        if not jq.startswith(head, sha):
            continue
        current.append({**e, "at": _strip_fraction(e.get("at"))})
    best_entry = jq.max_by(current, lambda e: e.get("at"))
    out = "|" if best_entry is None else f"{jq.text(best_entry.get('kind'))}|{jq.text(best_entry.get('at'))}"
    unread = sum(1 for r in running if r is None)
    return jq.add_str(f"{out}|{unread}|", row_sha)


def _summary_verdict(comments: list[Json], reviewer: str) -> str:
    """The newest summary's newest Code Review row as a Completed or Failed verdict:
    ``completed|<at>|<sha>``, ``failed|<at>|<sha>``, or ``||``."""
    newest_summary = _newest_summary(_summaries(comments, reviewer))
    if newest_summary is None:
        return "||"
    rows: list[dict[str, Json] | None] = []
    for row in _lines(jq.idx(newest_summary, "body")):
        if not jq.test(row, CODE_REVIEW_ROW):
            continue
        stamp = jq.capture(row, SUMMARY_ROW_STAMP)
        rows.append(None if stamp is None else {"at": stamp.get("at"), "row": row})
    if not rows or any(r is None for r in rows):
        return "||"
    known = [r for r in rows if r is not None]
    best = jq.max_by(known, lambda r: instant(r.get("at")))
    assert best is not None
    done = jq.capture(best.get("row"), SUMMARY_COMPLETED_ROW)
    failed = jq.capture(best.get("row"), SUMMARY_FAILED_ROW)
    if done is not None:
        return f"completed|{_strip_fraction(done.get('at'))}|{jq.text(done.get('sha'))}"
    if failed is not None:
        return f"failed|{_strip_fraction(failed.get('at'))}|{jq.text(failed.get('sha'))}"
    return "||"


def _last_word_of_reviews(reviews: list[Json], reviewer: str) -> str:
    """``<submitted_at>|<commit_id>`` of the reviewer's newest submitted review, or ``|``."""
    spoken = [
        r
        for r in reviews
        if by_reviewer(r, reviewer) and not jq.eq(jq.idx(r, "submitted_at"), None)
    ]
    ordered = jq.sort_by(spoken, lambda r: jq.idx(r, "submitted_at"))
    if not ordered:
        return "|"
    last = ordered[-1]
    return f"{jq.text(jq.idx(last, 'submitted_at'))}|{jq.text(jq.alt(jq.idx(last, 'commit_id'), ''))}"


def _reviews_of_head(reviews: list[Json], reviewer: str, sha: str) -> str:
    """The newest submission time of a reviewer review of exactly this head, or empty."""
    times = [
        jq.idx(r, "submitted_at")
        for r in reviews
        if by_reviewer(r, reviewer)
        and not jq.eq(jq.idx(r, "submitted_at"), None)
        and jq.eq(jq.alt(jq.idx(r, "commit_id"), ""), sha)
    ]
    return jq.captured([jq.text(jq.alt(jq.jmax(times), ""))])


# SHARED-CANDIDATE: status_state
def status_state(
    session: GhSession,
    repo: str,
    pr: str,
    stall: int,
    nudge_after: int | None = None,
    reads: Callable[[GhSession, str, str], _Reads] = _Reads,
) -> str:
    """``status_state``: one state line, always (a read that failed is the ``unknown`` token).
    ``nudge_after`` is a watch's issue-comment watermark (``watch_nudge_after``): with it, a
    pending ``@codex review`` above it is identified and supersedes older evidence."""
    rev = session.config.reviewer
    io = reads(session, repo, pr)
    mstate = "-"
    reactions = _items(api_list(session, f"issues/{pr}/reactions?per_page=100", repo))
    if reactions is None:
        return f"unknown|-|-|the reactions API did not answer ({session.err_line()})"
    try:
        mine = [r for r in reactions if by_reviewer(r, rev)]
        any_plus = any(jq.eq(jq.idx(r, "content"), "+1") for r in mine)
        eyes = jq.jmax([jq.idx(r, "created_at") for r in mine if jq.eq(jq.idx(r, "content"), "eyes")])
        plus = jq.jmax([jq.idx(r, "created_at") for r in mine if jq.eq(jq.idx(r, "content"), "+1")])
        line = jq.add_str(jq.add_str(jq.text(any_plus) + "|", jq.alt(eyes, "")) + "|", jq.alt(plus, ""))
    except jq.JqError:
        return "unknown|-|-|the reactions feed did not parse"
    line = line.rstrip("\n")
    plus_flag = _before(line)
    line = _after(line)
    eyes_at = _before(line)
    plus_at = _after(line)

    comments: list[Json] = []
    comments_loaded = False
    reviews: list[Json] = []
    reviews_loaded = False
    head = Head("", "-", "", "")
    head_loaded = False
    head_at = ""
    head_at_read = False
    nudge_at = ""
    nudge_id = ""
    stale_plus_at = ""
    stale_note = ""

    if nudge_after is not None:
        got = _items(io.comments())
        if got is None:
            return f"unknown|-|-|the comments API did not answer ({session.err_line()})"
        comments = got
        comments_loaded = True
        try:
            pending = [
                {"id": jq.idx(c, "id"), "at": jq.idx(c, "created_at")}
                for c in comments
                if jq.gt(jq.idx(c, "id"), nudge_after)
                and jq.test(jq.alt(jq.idx(c, "body"), ""), NUDGE_BODY)
            ]
            last = jq.max_by(pending, lambda p: p["at"])
            nudge_line = jq.captured(
                ["|" if last is None else f"{jq.text(last['id'])}|{jq.text(last['at'])}"]
            )
        except jq.JqError:
            return "unknown|-|-|the pending-request comments feed did not parse"
        nudge_id = _before(nudge_line)
        nudge_at = _after(nudge_line)
        if not is_digits(age_of(nudge_at)):
            nudge_at = ""

    # The 👍 path (#146, #418): a reaction carries no commit, so it is checked against the
    # current head's Running row and against the head's arrival.
    if plus_flag == "true" and _after_nudge(plus_at, nudge_at):
        if not comments_loaded:
            got = _items(io.comments())
            if got is not None:
                comments = got
                comments_loaded = True
            else:
                comments = []
        got = _items(io.reviews())
        if got is not None:
            reviews = got
            reviews_loaded = True
        else:
            reviews = []
        substantive = substantive_reviews(session, repo, pr, reviews)
        if substantive is None:
            return f"unknown|-|{mstate}|the review comments API did not establish substantive reviews"
        reviews = substantive
        head = io.head()
        mstate = head.mstate
        head_loaded = True
        try:
            evidence = _evidence(comments, reviews, rev, head.sha)
        except jq.JqError:
            return f"unknown|-|{mstate}|the current-head review evidence did not parse"
        evidence_kind, evidence_at, running_unread, row_sha = jq.bash_read_delim(evidence, 4, "|")
        if running_unread != "0":
            return (
                f"unknown|-|{mstate}|a {rev} Code Review row matched the Running test but not the"
                " SUMMARY_ROW_STAMP_RE, so the running round could not be read"
            )
        if evidence_at and evidence_at > plus_at:
            if evidence_kind == "running":
                age = age_of(evidence_at)
                if is_digits(age) and int(age) >= stall:
                    return (
                        f"stalled|{age}|{mstate}|{rev} Code Review Running for head {head.sha[:7]}"
                        f" at {evidence_at}"
                    )
                return (
                    f"reviewing|{age}|{mstate}|{rev} Code Review Running for head {head.sha[:7]}"
                    f" at {evidence_at}"
                )
            if evidence_kind == "findings":
                return (
                    f"idle|{age_of(evidence_at)}|{mstate}|{rev} posted findings for head"
                    f" {head.sha[:7]} at {evidence_at}"
                )
        if head.sha:
            if row_sha:
                if not head.sha.startswith(row_sha):
                    stale_note = f"the 👍 at {plus_at} is for {row_sha[:7]}, per {rev}'s summary"
            else:
                head_at = io.commit_date(head.sha)
                head_at_read = True
                if age_of(head_at) != "-" and plus_at < head_at:
                    stale_note = (
                        f"the 👍 at {plus_at} predates head {head.sha[:7]}'s commit date {head_at}"
                    )
        if not stale_note:
            return f"approved|-|{mstate}|👍 from {rev}"
        stale_plus_at = plus_at

    # The comments BEFORE the reviews (#439's read order).
    if not comments_loaded:
        got = _items(io.comments())
        if got is None:
            return f"unknown|-|{mstate}|the comments API did not answer ({session.err_line()})"
        comments = got
        comments_loaded = True
        reviews_loaded = False

    if not reviews_loaded:
        got = _items(io.reviews())
        if got is None:
            return f"unknown|-|{mstate}|the reviews API did not answer ({session.err_line()})"
        substantive = substantive_reviews(session, repo, pr, got)
        if substantive is None:
            return f"unknown|-|{mstate}|the review comments API did not establish substantive reviews"
        reviews = substantive

    try:
        rev_line = jq.captured([_last_word_of_reviews(reviews, rev)])
    except jq.JqError:
        return f"unknown|-|{mstate}|the reviews feed did not parse"
    rev_at = _before(rev_line)
    rev_sha = _after(rev_line)

    try:
        spoken = [
            jq.idx(c, "created_at")
            for c in comments
            if by_reviewer(c, rev) and not jq.test(jq.alt(jq.idx(c, "body"), ""), PLACEHOLDER)
        ]
        com_at = jq.captured([jq.text(jq.alt(jq.jmax(spoken), ""))])
    except jq.JqError:
        return f"unknown|-|{mstate}|the comments feed did not parse"

    try:
        verdicts: list[dict[str, Json]] = []
        for c in comments:
            if not by_reviewer(c, rev) or not jq.test(jq.alt(jq.idx(c, "body"), ""), VERDICT):
                continue
            stamp = jq.capture(jq.alt(jq.idx(c, "body"), ""), REVIEWED_COMMIT)
            verdicts.append(
                {
                    "at": jq.alt(jq.idx(c, "updated_at"), jq.idx(c, "created_at")),
                    "sha": jq.alt(None if stamp is None else stamp.get("s"), ""),
                }
            )
        ordered = jq.sort_by(verdicts, lambda v: v["at"])
        vline = jq.captured(
            ["|" if not ordered else f"{jq.text(ordered[-1]['at'])}|{jq.text(ordered[-1]['sha'])}"]
        )
    except jq.JqError:
        return f"unknown|-|{mstate}|the verdict comments feed did not parse"
    verd_at = _before(vline)
    verd_sha = _after(vline)

    try:
        done_line = jq.captured([_summary_verdict(comments, rev)])
    except jq.JqError:
        return f"unknown|-|{mstate}|the summary comments feed did not parse"
    done_kind = _before(done_line)
    done_line = _after(done_line)
    done_at = _before(done_line)
    done_sha = _after(done_line)

    try:
        words = [
            c
            for c in comments
            if by_reviewer(c, rev) and not jq.test(jq.alt(jq.idx(c, "body"), ""), PLACEHOLDER)
        ]
        ordered_words = jq.sort_by(words, lambda c: jq.idx(c, "created_at"))
        last_word = ordered_words[-1] if ordered_words else None
        if last_word is None or not jq.test(jq.alt(jq.idx(last_word, "body"), ""), INIT_FAILURE):
            fline = "||"
        else:
            body = jq.alt(jq.idx(last_word, "body"), "")
            ref = jq.capture(body, INIT_FAILURE_REF)
            fline = jq.add_str(
                f"{jq.text(jq.idx(last_word, 'created_at'))}|",
                jq.alt(None if ref is None else ref.get("s"), ""),
            ) + ("|env" if jq.test(body, INIT_FAILURE_ENV_ONLY) else "|git")
        fline = jq.captured([fline])
    except jq.JqError:
        return f"unknown|-|{mstate}|the initialization-failure comments feed did not parse"
    fail_at = _before(fline)
    fline = _after(fline)
    fail_ref = _before(fline)
    fail_kind = _after(fline)

    # A new explicit request supersedes older evidence uniformly.
    if not _after_nudge(eyes_at, nudge_at):
        eyes_at = ""
    if not _after_nudge(rev_at, nudge_at):
        rev_at, rev_sha = "", ""
    if not _after_nudge(com_at, nudge_at):
        com_at = ""
    if not _after_nudge(verd_at, nudge_at):
        verd_at, verd_sha = "", ""
    if not _after_nudge(fail_at, nudge_at):
        fail_at, fail_ref, fail_kind = "", "", ""
    last_spoke = newest(rev_at, com_at, stale_plus_at)

    if not head_loaded:
        head = io.head()
        mstate = head.mstate
    head_sha = head.sha

    # A no-findings verdict naming the current head outranks a live-looking 👀.
    if verd_sha and head_sha and (not eyes_at or verd_at > eyes_at):
        if head_sha.startswith(verd_sha):
            return (
                f"approved|-|{mstate}|{rev} posted a no-findings verdict for head {head_sha[:7]}"
                f" at {verd_at}"
            )

    # A round the summary marks Completed on the current head, silent since its 👀 (#439).
    if (
        done_kind == "completed"
        and done_sha
        and head_sha
        and eyes_at
        and done_at > eyes_at
        and (not last_spoke or last_spoke < eyes_at)
    ):
        if head_sha.startswith(done_sha):
            return (
                f"approved|-|{mstate}|{rev}'s summary marks head {head_sha[:7]}'s Code Review"
                f" Completed at {done_at}, with nothing posted since its 👀 at {eyes_at} (no 👍"
                " was given)"
            )

    # A reviewer RUN the summary marks Failed on the current head (#453).
    if (
        done_kind == "failed"
        and done_sha
        and head_sha
        and plus_flag != "true"
        and age_of(done_at) != "-"
        and _after_nudge(done_at, nudge_at)
        and (not eyes_at or eyes_at < done_at)
    ):
        if head_sha.startswith(done_sha):
            if eyes_at:
                if not (not last_spoke or last_spoke < eyes_at):
                    done_kind = ""
            else:
                if not (not last_spoke or last_spoke < done_at):
                    done_kind = ""
                try:
                    rev_head_at = _reviews_of_head(reviews, rev, head_sha)
                except jq.JqError:
                    return f"unknown|-|{mstate}|the reviews feed did not parse for the failed run's head"
                if rev_head_at:
                    done_kind = ""
        else:
            done_kind = ""
    else:
        done_kind = ""
    if done_kind == "failed":
        if not head_at_read:
            head_at = io.commit_date(head_sha)
            head_at_read = True
        floor = ""
        if age_of(head_at) != "-":
            floor = head_at
        if head.created and age_of(head.created) != "-":
            floor = newest(floor, head.created)
        try:
            requested: list[Json] = []
            for c in comments:
                if by_reviewer(c, rev):
                    continue
                if not jq.test(jq.alt(jq.idx(c, "body"), ""), REQUEST):
                    continue
                requested.append(jq.alt(jq.idx(c, "created_at"), ""))
            after_row = any(jq.cmp(t, done_at) >= 0 for t in requested)
            before_row = jq.jmax(
                [t for t in requested if jq.cmp(t, floor) >= 0 and jq.cmp(t, done_at) < 0]
            )
            req_line = jq.captured([f"{jq.text(after_row)}|{jq.text(jq.alt(before_row, ''))}"])
        except jq.JqError:
            return f"unknown|-|{mstate}|the review-request comments feed did not parse"
        req_after = _before(req_line)
        req_before = _after(req_line)
        if req_after != "true":
            if req_before:
                return (
                    f"failed|{age_of(done_at)}|{mstate}|{head_sha[:7]}|run-again|{rev}'s summary"
                    f" marks head {head_sha[:7]}'s Code Review Failed at {done_at}, after the"
                    f" '@codex review' request at {req_before} on this head, with no review of it"
                    " and no 👍"
                )
            return (
                f"failed|{age_of(done_at)}|{mstate}|{head_sha[:7]}|run|{rev}'s summary marks head"
                f" {head_sha[:7]}'s Code Review Failed at {done_at}, with no review of it, no 👍,"
                " and no '@codex review' on it since it arrived"
            )

    # In flight only while the 👀 is newer than everything the reviewer has said.
    if eyes_at and eyes_at > last_spoke:
        age = age_of(eyes_at)
        if is_digits(age) and int(age) >= stall:
            return f"stalled|{age}|{mstate}|👀 from {rev} at {eyes_at} with nothing posted since"
        spoke = f" ({last_spoke})" if last_spoke else ""
        return f"reviewing|{age}|{mstate}|👀 from {rev} at {eyes_at}, newer than its last word{spoke}"

    if not head_sha:
        return f"unknown|-|unread|the pulls API did not answer for the head SHA ({head.err})"

    # The round that never started (#78, #421).
    fail_head = ""
    if fail_at and fail_ref:
        if head_sha.startswith(fail_ref):
            fail_head = f"for ref {fail_ref[:7]}"
    elif fail_at and fail_kind == "env":
        if not head_at_read:
            head_at = io.commit_date(head_sha)
            head_at_read = True
        if (
            age_of(head_at) != "-"
            and fail_at > head_at
            and (not head.created or (age_of(head.created) != "-" and fail_at > head.created))
        ):
            fail_head = f"after head {head_sha[:7]}'s commit date {head_at}"
    if fail_head:
        try:
            rev_head_at = _reviews_of_head(reviews, rev, head_sha)
        except jq.JqError:
            return f"unknown|-|{mstate}|the reviews feed did not parse for the failed head"
        if not rev_head_at or fail_at > rev_head_at:
            return (
                f"failed|{age_of(fail_at)}|{mstate}|{head_sha[:7]}|{fail_kind}|{rev} reported an"
                f" initialization failure at {fail_at} {fail_head}"
            )

    # A verdict naming the current head, no older than the reviewer's last word.
    if verd_sha and not verd_at < last_spoke:
        if head_sha.startswith(verd_sha):
            return (
                f"approved|-|{mstate}|{rev} posted a no-findings verdict for head {head_sha[:7]}"
                f" at {verd_at}"
            )

    if rev_sha == head_sha:
        return f"idle|{age_of(last_spoke)}|{mstate}|{rev} reviewed head {head_sha[:7]} at {rev_at}"

    if not head_at_read:
        head_at = io.commit_date(head_sha)
    if nudge_at:
        return (
            f"nudged|{freshest_age(nudge_at, head_at, head.created)}|{mstate}|{nudge_id}|fresh"
            " review nudge; waiting for pickup"
        )
    last = f"; {rev} last reviewed {rev_sha[:7]} at {rev_at}" if rev_sha else ""
    stale = f"; {stale_note}" if stale_note else ""
    return (
        f"expected|{freshest_age(head_at, head.created, last_spoke, eyes_at, nudge_at)}|{mstate}|no"
        f" 👀 in flight and no review of head {head_sha[:7]}{last}{stale}"
    )


# --- open review threads under an approval (ludics-lite#289) --------------------------------------

THREADS_PAGE_CAP = 50
THREADS_QUERY = (
    "query($owner:String!, $name:String!, $pr:Int!, $after:String) {\n"
    "  repository(owner:$owner, name:$name) { pullRequest(number:$pr) {\n"
    "    reviewThreads(first:100, after:$after) {\n"
    "      totalCount pageInfo { hasNextPage endCursor }\n"
    "      nodes { id isResolved path\n"
    "        comments(first:1) { nodes { fullDatabaseId databaseId author { login } } } } } } } }"
)


@dataclass(frozen=True)
class ThreadsRead:
    """The whole connection was read (or the walk was stopped by the page reader)."""


@dataclass(frozen=True)
class ThreadsUnread:
    """Why the connection was not read whole; ``rc`` 4 when GraphQL rejected the query, else 3."""

    why: str
    rc: int


type ThreadsWalk = ThreadsRead | ThreadsUnread


def _meta(resp: str) -> str:
    """threads_walk's ``meta``: ``<total>\\t<rows>\\t<has next>\\t<cursor>`` of a connection, or
    empty for anything that is not one."""
    docs = json_stream(resp)
    if docs is None:
        return ""
    out: list[str] = []
    try:
        for doc in docs:
            if not (
                isinstance(doc, dict)
                and jq.kind(jq.idx(doc, "nodes")) == "array"
                and jq.kind(jq.idx(doc, "totalCount")) == "number"
                and jq.kind(jq.path(doc, "pageInfo", "hasNextPage")) == "boolean"
            ):
                continue
            nodes = doc["nodes"]
            assert isinstance(nodes, list)
            out.append(
                f"{jq.text(doc['totalCount'])}\t{len(nodes)}\t"
                f"{jq.text(jq.path(doc, 'pageInfo', 'hasNextPage'))}\t"
                f"{jq.text(jq.alt(jq.path(doc, 'pageInfo', 'endCursor'), ''))}"
            )
    except jq.JqError:
        return ""
    return jq.captured(out)


# SHARED-CANDIDATE: threads_walk
def threads_walk(
    session: GhSession, repo: str, pr: str, page_fn: Callable[[str], int], cap: int
) -> ThreadsWalk:
    """``threads_walk``: page the PR's reviewThreads, handing each page's answer to ``page_fn``
    (0 read on, 1 stop here, 2 the page did not parse)."""
    owner = repo.split("/", 1)[0]
    name = repo.rsplit("/", 1)[-1]
    cursor = ""
    read_n = 0
    for page in range(1, cap + 1):
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
                return ThreadsUnread(
                    f"GraphQL REJECTED the review-threads read ({session.err_line()})", 4
                )
            case GhUnanswered():
                return ThreadsUnread(
                    "GraphQL did not answer the review-threads read after"
                    f" {session.config.api_attempts} attempts ({session.err_line()})",
                    3,
                )
            case _:
                assert_never(result)
        total, n, has_next, cursor = jq.bash_read(_meta(resp), 4)
        if not is_digits((total or "x") + (n or "x")):
            return ThreadsUnread(
                f"the review-threads read answered page {page} without a thread connection", 3
            )
        status = page_fn(resp)
        if status == 1:
            return ThreadsRead()
        if status != 0:
            return ThreadsUnread(
                f"the review-threads read answered page {page} with threads that did not parse", 3
            )
        read_n += int(n)
        if has_next != "true":
            if read_n < int(total):
                return ThreadsUnread(
                    f"the review-threads read ended at {read_n} thread(s) while the PR states {total}",
                    3,
                )
            return ThreadsRead()
        if not cursor:
            return ThreadsUnread(
                f"the review-threads read said page {page} has a successor and gave no cursor to it",
                3,
            )
    return ThreadsUnread(
        f"the review-threads read was still paging after {cap} pages of 100, so it is refused"
        f" rather than judged on its first {read_n} thread(s)",
        3,
    )


def _open_rows(resp: str) -> list[str]:
    """unresolved_page's rows: ``<first comment id>\\t<author>\\t<path>`` per thread whose
    isResolved is not literally true."""
    docs = json_stream(resp)
    if docs is None:
        raise jq.JqError("the page did not parse")
    rows: list[str] = []
    for doc in docs:
        nodes = jq.idx(doc, "nodes")
        if nodes is None:
            raise jq.JqError("Cannot iterate over null")
        if not isinstance(nodes, (list, dict)):
            raise jq.JqError(f"Cannot iterate over {jq.kind(nodes)}")
        for node in nodes if isinstance(nodes, list) else list(nodes.values()):
            if jq.eq(jq.idx(node, "isResolved"), True):
                continue
            first = jq.nth(jq.path(node, "comments", "nodes"), 0)
            ident = jq.alt(jq.alt(jq.idx(first, "fullDatabaseId"), jq.idx(first, "databaseId")), "-")
            author = jq.alt(jq.path(first, "author", "login"), "-")
            path = jq.alt(jq.idx(node, "path"), "-")
            rows.append(jq.tsv([jq.text(ident), jq.text(author), jq.text(path)]))
    return rows


@dataclass(frozen=True)
class OpenThreads:
    rows: list[str]


type UnresolvedResult = OpenThreads | ThreadsUnread


# SHARED-CANDIDATE: unresolved_threads
def unresolved_threads(session: GhSession, repo: str, pr: str, cap: int) -> UnresolvedResult:
    rows: list[str] = []

    def page(resp: str) -> int:
        try:
            rows.extend(_open_rows(resp))
        except jq.JqError:
            return 2
        return 0

    walked = threads_walk(session, repo, pr, page, cap)
    match walked:
        case ThreadsRead():
            return OpenThreads(rows)
        case ThreadsUnread():
            return walked
        case _:
            assert_never(walked)


# SHARED-CANDIDATE: threads_named
def threads_named(rows: list[str]) -> tuple[int, str]:
    """``<count>`` and the first ten named, the path shell-quoted."""
    n = 0
    shown = ""
    for row in rows:
        ident, login, path = jq.bash_read(row, 3)
        if not ident:
            continue
        n += 1
        if n > 10:
            continue
        shown += (", " if shown else "") + f"{ident} by {login} on {shell_quote(path)}"
    if n > 10:
        shown += f", and {n - 10} more"
    return n, shown


# SHARED-CANDIDATE: threads_advice
def threads_advice(repo: str, num: str) -> str:
    pr = num or "<pr>"
    return (
        "An open thread is a finding nobody closed, whatever head it cites: one written against an"
        " earlier head is live if this head did not change its lines, and `watch` prints such"
        " findings as NOT about head and moves past them (ludics-lite#289). Read each one, answer"
        f" it with a fix or a rebuttal (pr-review.sh reply {repo}#{pr} <id> '<answer>'), then close"
        f" it (pr-review.sh resolve {repo}#{pr} <id>); clearing this needs no push"
    )


# SHARED-CANDIDATE: approval_gate
def approval_gate(session: GhSession, repo: str, pr: str, line: str, cap: int) -> str:
    if state_tok(line) != "approved":
        return line
    found = unresolved_threads(session, repo, pr, cap)
    match found:
        case ThreadsUnread(why=why):
            return (
                f"unknown|-|{state_merge(line)}|{why}, so whether open review threads stand under"
                f" this approval ({state_detail(line)}) is unknown"
            )
        case OpenThreads(rows=rows):
            if not rows:
                return line
            n, shown = threads_named(rows)
            return f"unresolved|-|{state_merge(line)}|{n}|{state_detail(line)}|{shown}"
        case _:
            assert_never(found)


# --- rendering ------------------------------------------------------------------------------------


# SHARED-CANDIDATE: conflict_note
def conflict_note(merge: str, repo: str, num: str) -> str:
    match merge:
        case "dirty":
            return (
                "CONFLICTS with the base (mergeable_state=dirty): GitHub cannot build this head"
                " merged with the current base, so no pull_request run tests that merge and the"
                " rounds' fixes go untested against it — merge the base in, resolve, and push"
                " before the next round"
            )
        case "unread":
            return (
                "mergeability UNREAD (the PR read did not answer): whether this PR conflicts with"
                " its base is unknown, which is not 'no' — retry status before acting on this line"
            )
        case "unknown":
            return (
                "mergeability NOT YET COMPUTED (mergeable_state=unknown, GitHub recomputes it after"
                " every push): a conflict this push caused would not show yet — re-read status in"
                " a minute"
            )
        case "draft":
            return (
                "DRAFT (mergeable_state=draft): a draft cannot be merged and no reviewer action"
                f" lands it — mark it ready (gh pr ready {num or '<pr>'} --repo {repo}) when it is;"
                " the review rounds still count"
            )
        case _:
            return ""


# SHARED-CANDIDATE: status_line
def status_line(line: str, repo: str, num: str) -> str:
    """``status_line``: the state line rendered. ``num`` is PR_NUM, empty when unknown."""
    tok = state_tok(line)
    age = state_age(line)
    detail = state_detail(line)
    if tok == "nudged":
        detail = _after(detail)
    merge = state_merge(line)
    conflict = conflict_note(merge, repo, num)
    c = f"; {conflict}" if conflict else ""
    pr = num or "<pr>"
    match tok:
        case "approved":
            return f"approved ({detail}){c}"
        case "unresolved":
            rest = _after(detail)
            return (
                f"approved ({_before(rest)}) BUT {_before(detail)} review thread(s) still UNRESOLVED"
                f" — NOT a clean approval, and `merge` refuses it: {_after(rest)}."
                f" {threads_advice(repo, num)}{c}"
            )
        case "reviewing":
            return f"reviewing — {detail}, running {fmt_age(age)} — wait it out{c}"
        case "stalled":
            return (
                f"STALLED — {detail} for {fmt_age(age)}, longer than a round takes. FIRST read the"
                " PR feed yourself (retry --read pr view <pr> --comments): a verdict may have landed"
                " as a comment or a 👍 this state machine missed. Only if the feed truly has nothing"
                " for the current head, nudge with a '@codex review' comment — knowing a re-request"
                f" CLEARS the reviewer's existing 👍{c}"
            )
        case "failed":
            fsha = _before(detail)
            frest = _after(detail)
            fkind = _before(frest)
            frest = _after(frest)
            standing = f"This is not a round — {frest}, standing for {fmt_age(age)}{c}"
            match fkind:
                case "run":
                    return (
                        f"reviewer's run FAILED on head {fsha} — no review and no 👍, so a"
                        " '@codex review' re-request clears nothing: `watch` posts it itself, once"
                        " per head, and keeps watching; outside a watch, post it (pr-review.sh"
                        f" comment {repo}#{pr} '@codex review'). {standing}"
                    )
                case "run-again":
                    return (
                        f"reviewer's run FAILED AGAIN on head {fsha} after a '@codex review' request"
                        " on it — not re-requested a second time: read the PR feed (retry --read pr"
                        " view <pr> --comments) for anything the reviewer said, then push a new head"
                        " (an amend suffices: git commit --amend --no-edit && git push"
                        f" --force-with-lease) or hand it to the maintainer. {standing}"
                    )
                case "env":
                    return (
                        f"reviewer FAILED at initialization on head {fsha} — nudge it once with a"
                        f" '@codex review' comment (pr-review.sh comment {repo}#{pr} '@codex"
                        ' review\'); the connector answered "To use Codex here, create an'
                        ' environment for this repo", which has cleared on one nudge before. If the'
                        " nudge draws the same answer, the environment is the maintainer's to set"
                        " up (https://chatgpt.com/codex/cloud/settings/environments) — no push of"
                        f" yours fixes it. {standing}"
                    )
                case _:
                    return (
                        f"reviewer FAILED at initialization on head {fsha} — nudge it once with a"
                        f" '@codex review' comment (pr-review.sh comment {repo}#{pr} '@codex"
                        " review'); if the SAME head fails again, push a new head instead (an amend"
                        " suffices: git commit --amend --no-edit && git push --force-with-lease),"
                        " since the reviewer's clone is behind, not your push — the ref it could not"
                        f" fetch is one the PR and git ls-remote both serve. {standing}"
                    )
        case "expected" | "nudged":
            return f"review EXPECTED but not started — {detail}; due for {fmt_age(age)}{c}"
        case "idle":
            if merge in ("dirty", "draft"):
                return f"nothing in flight — {detail}, and no 👍; {conflict}"
            return f"nothing in flight — {detail}, and no 👍; the next move is yours{c}"
        case "unknown":
            return f"UNKNOWN — {detail}; this is NOT 'not approved', retry{c}"
        case _:
            return f"unrecognised state '{tok}' — treat as unknown and retry"

