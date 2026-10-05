"""What `poll`, `status` and `rounds` read in common, ported from pr-review.sh's middle section.

The shell functions each piece ports (their comments carry the incident history behind every
rule; read them there before changing one here):

  REVIEWED_COMMIT, INIT_FAILURE*, SUMMARY_*      the expressions of the same names (``_RE``)
  newest / age_of / freshest_age / fmt_age       the clocks
  review_comments                                one review's own comments endpoint
  substantive_reviews                            empty COMMENTED envelopes and the connector's
                                                 fixed thread reply are not reviews (#88, #472)
  pr_head_read                                   the head, mergeability and creation, one read

The round snapshot. `watch` is still shell (ludics-lite#403), and a watch round shares its one
observation of the feeds with the state read beside it through files (pr-review.sh's "the round
snapshot", ludics-lite#95). `poll` is Python and runs inside that round, so it writes the round's
feeds and reads/writes its per-review cache in the shell's own format when the forwarder hands it
the snapshot's path (``ROUND_SNAPSHOT``). The watch porter replaces this with an object. For the
same reason a poll hands its last gh error back through the shell's GH_ERR_FILE (``GH_ERR_FILE``).
"""

import math
import os
import re
import time
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
    ListUnparsed,
    api_list,
    json_stream,
)

# The snapshot path a watch round armed (pr-review.sh's $SNAP), private to the forward.
ROUND_SNAPSHOT = "LUDICS_PR_REVIEW_ROUND_SNAPSHOT"

_WS = jq.WS

# SHARED-CANDIDATE: REVIEWED_COMMIT_RE
REVIEWED_COMMIT = re.compile(r"Reviewed commit[^0-9a-fA-F]*(?P<s>[0-9a-f]{7,40})")
# SHARED-CANDIDATE: INIT_FAILURE_GIT_RE
INIT_FAILURE_GIT = (
    r"\A[ \t]*Codex Review:[ \t]*Something went wrong\.[ \t]*Try again later by commenting"
    r"[^\n]{0,4}@codex review"
)
# SHARED-CANDIDATE: INIT_FAILURE_ENV_RE
INIT_FAILURE_ENV = (
    rf"\A[ \t]*To use Codex here,[ \t]*\[?create an environment for this repo"
    rf"(?:\]\([^){_WS}]*\))?\.?[{_WS}]*\Z"
)
INIT_FAILURE = re.compile(f"(?:{INIT_FAILURE_GIT})|(?:{INIT_FAILURE_ENV})")
INIT_FAILURE_ENV_ONLY = re.compile(INIT_FAILURE_ENV)
INIT_FAILURE_REF = re.compile(r"Provided git ref[^0-9a-f]*(?P<s>[0-9a-f]{7,40})")
SUMMARY_COMPLETED_ROW = re.compile(
    r'^\|[^|]*Code Review[^|]*\| *✅ \*\*Completed\*\* <relative-time datetime="(?P<at>[^"]+)">'
    r"[^<|]*</relative-time> *\| *`(?P<sha>[0-9a-f]{7,40})` *\|"
)
SUMMARY_FAILED_ROW = re.compile(
    r'^\|[^|]*Code Review[^|]*\| *⚠️ \*\*Failed\*\* <relative-time datetime="(?P<at>[^"]+)">'
    r"[^<|]*</relative-time> *\| *`(?P<sha>[0-9a-f]{7,40})` *\|"
)
SUMMARY_ROW_STAMP = re.compile(r'datetime="(?P<at>[^"]+)"[^|]*\| *`(?P<sha>[0-9a-f]{7,40})` *\|')
CODE_REVIEW_ROW = re.compile(r"^\|[^|]*Code Review[^|]*\|")
RUNNING_ROW = re.compile(r"^\|[^|]*Code Review[^|]*\|[^|]*Running")
PLACEHOLDER_TAG = "codex-pull-request-review-summary"
PLACEHOLDER = re.compile(PLACEHOLDER_TAG)
VERDICT = re.compile(r"[Dd]idn.t find any major issues")
NUDGE_BODY = re.compile(
    "^@codex review[ \t\r\n]*(_\U0001f916 Addressed by an automated coding agent_)?[ \t\r\n]*$"
)
REQUEST = re.compile(f"@codex[{_WS}]+review", re.IGNORECASE)
FRACTION_Z = re.compile(r"\.[0-9]+Z$")
_TRAILING_Z = re.compile(r"Z$")
_DOT = re.compile(r"\.")

# substantive_reviews' allowlist of the connector's fixed thread replies (CONNECTOR_FIXED_REPLIES).
CONNECTOR_FIXED_REPLIES = (
    "To use Codex here, [create an environment for this repo]"
    "(https://chatgpt.com/codex/cloud/settings/environments).",
)


def instant(at: Json) -> Json:
    """SUMMARY_ROW_INSTANT_DEF's ``instant``: a stamp padded to nine fractional digits, so the
    string order is the time order."""
    s = jq.sub(at, _TRAILING_Z, "")
    s = s if jq.test(s, _DOT) else s + "."
    return jq.head_slice(s + "000000000", 29)


def by_reviewer(item: Json, reviewer: str) -> bool:
    """``select((.user.login // "") | startswith($rev))``."""
    return jq.startswith(jq.alt(jq.path(item, "user", "login"), ""), reviewer)


# --- clocks --------------------------------------------------------------------------------------


# SHARED-CANDIDATE: newest
def newest(*stamps: str) -> str:
    """``newest``: the greatest nonempty ISO stamp, compared as a string."""
    best = ""
    for ts in stamps:
        if ts and (not best or ts > best):
            best = ts
    return best


def _digits(s: str) -> bool:
    return s != "" and all("0" <= c <= "9" for c in s)


# SHARED-CANDIDATE: age_of
def age_of(stamp: str, now: float | None = None) -> str:
    """``age_of``: whole seconds since the stamp, or ``-`` when there is none, it does not parse,
    or it lies in the future."""
    if not stamp:
        return "-"
    try:
        then = jq.fromdateiso8601(stamp)
    except jq.JqError:
        return "-"
    age = str(math.floor((time.time() if now is None else now) - then))
    return age if _digits(age) else "-"


# SHARED-CANDIDATE: freshest_age
def freshest_age(*stamps: str) -> str:
    """``freshest_age``: the smallest usable age among the stamps, each validated on its own."""
    best = ""
    for ts in stamps:
        age = age_of(ts)
        if not _digits(age):
            continue
        if not best or int(best) > int(age):
            best = age
    return best or "-"


# SHARED-CANDIDATE: fmt_age
def fmt_age(age: str) -> str:
    if not _digits(age):
        return "an unknown time"
    n = int(age)
    return f"{n // 60}m" if n >= 60 else f"{n}s"


def is_digits(s: str) -> bool:
    return _digits(s)


# --- the round snapshot (shell interop until `watch` is ported) ----------------------------------


@dataclass(frozen=True)
class Snapshot:
    """A watch round's snapshot files, ``<prefix>.feeds.*`` and ``<prefix>.review.<id>``."""

    prefix: str

    def put_feeds(self, pr: str, comments: list[Json], reviews: list[Json]) -> None:
        """``snapshot_put_feeds``: the marker last, so a partial write is no snapshot at all."""
        try:
            os.remove(self.prefix + ".feeds.pr")
        except OSError:
            pass
        try:
            for name, text in (
                (".feeds.comments", jq.tojson(comments)),
                (".feeds.reviews", jq.tojson(reviews)),
                (".feeds.pr", pr),
            ):
                with open(self.prefix + name, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(text + "\n")
        except OSError:
            pass

    def review_path(self, rid: str) -> str:
        return f"{self.prefix}.review.{rid}"


def snapshot_from_env(env: dict[str, str] | None = None) -> Snapshot | None:
    prefix = (os.environ if env is None else env).get(ROUND_SNAPSHOT, "")
    return Snapshot(prefix) if prefix else None


# The shell's GH_ERR_FILE, handed over by a watch round's cmd_poll, private to the forward.
GH_ERR_FILE = "LUDICS_PR_REVIEW_GH_ERR_FILE"


def hand_back_err_line(session: GhSession, env: dict[str, str] | None = None) -> None:
    """Leave this command's last gh error where the shell's gh_err_line reads it. Watch quotes
    $(gh_err_line) after a poll that did not answer ("the final poll ... did not answer (<error>)"),
    and the shell's gh_retry kept that file current after every call: the last FAILED attempt's
    first stderr line, emptied by a call that succeeded. The session holds the same line, so it is
    written once, as the poll ends; a write that fails leaves the message without its quote, as the
    shell's own did."""
    path = (os.environ if env is None else env).get(GH_ERR_FILE, "")
    if not path:
        return
    try:
        with open(path, "w", encoding="utf-8", errors="surrogateescape") as handle:
            handle.write(session.err_line())
    except OSError:
        pass


@dataclass(frozen=True)
class CacheUnparsed:
    """A cached review read that is not JSON: what the shell's next jq would have refused."""


type ReviewComments = ListOk | GhFailed | GhUnanswered | ListUnparsed | CacheUnparsed


# SHARED-CANDIDATE: review_comments
def review_comments(
    session: GhSession, repo: str, pr: str, rid: str, snapshot: Snapshot | None = None
) -> ReviewComments:
    """``review_comments``: a review's own comments endpoint, through the round's cache when a
    watch round armed one. Only a successful read is cached."""
    endpoint = f"pulls/{pr}/reviews/{rid}/comments?per_page=100"
    if not _digits(rid) or snapshot is None:
        return api_list(session, endpoint, repo)
    cache = snapshot.review_path(rid)
    if os.path.isfile(cache):
        try:
            with open(cache, encoding="utf-8", errors="surrogateescape") as handle:
                docs = json_stream(handle.read())
        except OSError:
            docs = None
        if docs is None or len(docs) != 1 or not isinstance(docs[0], list):
            return CacheUnparsed()
        return ListOk(docs[0])
    result = api_list(session, endpoint, repo)
    match result:
        case ListOk(items=items):
            try:
                with open(cache, "w", encoding="utf-8", newline="\n") as handle:
                    handle.write(jq.tojson(items) + "\n")
            except OSError:
                pass
        case GhFailed() | GhUnanswered() | ListUnparsed():
            pass
        case _:
            assert_never(result)
    return result


def _fixed_reply(comment: Json) -> bool:
    """CONNECTOR_FIXED_REPLIES' test: a thread reply whose body, trailing whitespace aside, is one
    of them."""
    if jq.kind(jq.idx(comment, "in_reply_to_id")) != "number":
        return False
    body = jq.idx(comment, "body")
    if not isinstance(body, str):
        return False
    return jq.sub(body, jq.TRAILING_SPACE, "") in CONNECTOR_FIXED_REPLIES


# SHARED-CANDIDATE: substantive_reviews
def substantive_reviews(
    session: GhSession,
    repo: str,
    pr: str,
    reviews: list[Json],
    snapshot: Snapshot | None = None,
) -> list[Json] | None:
    """``substantive_reviews``: the reviews minus every empty-bodied COMMENTED envelope whose own
    comments are all the connector's fixed replies (or none at all). None where the shell returned
    1: a read that did not answer, or a shape it could not take."""
    reviewer = session.config.reviewer
    try:
        ids: list[str] = []
        for review in reviews:
            if not by_reviewer(review, reviewer):
                continue
            if not (
                jq.eq(jq.idx(review, "state"), "COMMENTED")
                and not jq.eq(jq.idx(review, "submitted_at"), None)
            ):
                continue
            if jq.test(jq.alt(jq.idx(review, "body"), ""), jq.NONSPACE):
                continue
            ids.append(jq.text(jq.idx(review, "id")))
    except jq.JqError:
        return None
    raw = reviews
    for rid in "\n".join(ids).split("\n"):
        if not rid:
            continue
        if not _digits(rid):
            return None
        inline = review_comments(session, repo, pr, rid, snapshot)
        match inline:
            case ListOk(items=items):
                try:
                    fixed = all(_fixed_reply(c) for c in items)
                except jq.JqError:
                    fixed = False
                if fixed:
                    try:
                        raw = [r for r in raw if not jq.eq(jq.idx(r, "id"), int(rid))]
                    except jq.JqError:
                        return None
            case GhFailed() | GhUnanswered() | ListUnparsed() | CacheUnparsed():
                return None
            case _:
                assert_never(inline)
    return raw


# --- the head ------------------------------------------------------------------------------------

HEAD_JQ = '[(.head.sha // "-"), (.mergeable_state // "-"), (.created_at // "-")] | @tsv'


@dataclass(frozen=True)
class Head:
    """``pr_head_read``'s four variables: an empty ``sha`` and mergeability ``unread`` when the
    read failed, with its error line kept in ``err``."""

    sha: str
    mstate: str
    created: str
    err: str


# SHARED-CANDIDATE: pr_head_read
def pr_head_read(session: GhSession, repo: str, pr: str) -> Head:
    result = session.retry("read", ["api", f"repos/{repo}/pulls/{pr}", "--jq", HEAD_JQ])
    match result:
        case GhOk(stdout=out):
            sha, mstate, created = jq.bash_read(out, 3)
            return Head(
                sha="" if sha == "-" else sha,
                mstate=mstate or "-",
                created="" if (created or "-") == "-" else created,
                err="",
            )
        case GhFailed() | GhUnanswered():
            return Head(sha="", mstate="unread", created="", err=session.err_line())
        case _:
            assert_never(result)


def commit_date(session: GhSession, repo: str, sha: str) -> str:
    """The head commit's committer date, or empty when the read failed."""
    result = session.retry(
        "read", ["api", f"repos/{repo}/commits/{sha}", "--jq", ".commit.committer.date"]
    )
    match result:
        case GhOk(stdout=out):
            return out
        case GhFailed() | GhUnanswered():
            return ""
        case _:
            assert_never(result)
