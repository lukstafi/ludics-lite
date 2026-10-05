"""How far a PR is behind its base, and whether the base's advance touched the PR's lines.

Ported from pr-review.sh's ``warn_base_drift`` with ``compare_hunks``, ``compare_file_set`` and
``encode_ref``: what ``merge`` reads last, and what a ``watch`` reads when a round lands (on
stderr there, with the rest of the context, so the round's stdout stays poll's). The shell's
comments carry the policy (a warning, never a gate, under the roll-forward policy of
ahrefs/ocannl#861) and the incidents behind each refusal to read "unknown" as "none".

``say`` receives what the shell printed on stdout and ``warn`` what it printed on stderr; the
watch passes one stderr writer for both.
"""

import json
import re
import urllib.parse
from collections.abc import Callable
from dataclasses import dataclass
from typing import assert_never

from ludics.prreview.core import GhFailed, GhOk, GhUnanswered, Json
from ludics.prreview.watch_feeds import Ctx, ifs_read
from ludics.prreview.watch_jq import JqError, as_list, idx, member, tojson, type_name, unique

_HUNK = re.compile(r"^@@ -(?P<s>[0-9]+)(,(?P<n>[0-9]+))? \+[0-9]+(,(?P<m>[0-9]+))? @@")


def encode_ref(ref: str) -> str:
    """``encode_ref``: every byte outside ``[a-zA-Z0-9._~/-]`` as ``%XX``."""
    return urllib.parse.quote(ref.encode("utf-8", "surrogateescape"), safe="._~/-")


@dataclass(frozen=True)
class Range:
    lo: int
    hi: int


def _ranges(entry: Json) -> list[Range] | None:
    patch = idx(entry, "patch")
    additions = idx(entry, "additions")
    deletions = idx(entry, "deletions")
    if not isinstance(patch, str) or type_name(additions) != "number" or type_name(deletions) != "number":
        return None
    lines = patch.split("\n")
    if sum(1 for l in lines if l.startswith("+")) != additions or sum(
        1 for l in lines if l.startswith("-")
    ) != deletions:
        return None
    ranges: list[Range] = []
    cur: list[int] | None = None  # [old lines left, new lines left]
    ok = True
    for line in lines:
        h = _HUNK.search(line)
        if h is not None:
            if cur is not None and (cur[0] != 0 or cur[1] != 0):
                ok = False
            s = int(h.group("s"))
            n = 1 if h.group("n") is None else int(h.group("n"))
            m = 1 if h.group("m") is None else int(h.group("m"))
            ranges.append(Range(s, s + 1) if n == 0 else Range(s, s + n - 1))
            cur = [n, m]
        elif cur is None:
            continue
        elif line.startswith("-"):
            cur[0] -= 1
        elif line.startswith("+"):
            cur[1] -= 1
        elif line.startswith(" "):
            cur[0] -= 1
            cur[1] -= 1
    if ok and ranges and cur is not None and cur[0] == 0 and cur[1] == 0:
        return ranges
    return None


def compare_hunks(doc: Json) -> dict[str, list[Range] | None]:
    """``compare_hunks``: each file's old-side hunk ranges, None where they cannot be read."""
    out: dict[str, list[Range] | None] = {}
    for f in as_list(idx(doc, "files")):
        name = idx(f, "filename")
        out[name if isinstance(name, str) else tojson(name)] = _ranges(f)
    return out


@dataclass(frozen=True)
class FileSet:
    count: int
    paths: list[Json]


def compare_file_set(doc: Json) -> FileSet | None:
    """``compare_file_set``: the count and the paths (old names included), or None when the files
    list is missing or holds an entry without a usable name."""
    try:
        files = idx(doc, "files")
        if not isinstance(files, list):
            return None
        for f in files:
            name = idx(f, "filename")
            if not (isinstance(name, str) and name):
                return None
            if not isinstance(f, dict):
                return None
            if "previous_filename" in f:
                prev = f["previous_filename"]
                if not (prev is None or (isinstance(prev, str) and prev)):
                    return None
        paths: list[Json] = []
        for f in files:
            paths.append(idx(f, "filename"))
            if isinstance(f, dict):
                paths.append(f.get("previous_filename"))
        return FileSet(len(files), unique([p for p in paths if isinstance(p, str)]))
    except JqError:
        return None


def _meets(a: list[Range], b: list[Range]) -> bool:
    return any(y.lo <= x.hi + 1 and x.lo <= y.hi + 1 for x in a for y in b)


def _count(value: Json) -> str | None:
    """``.behind_by | numbers | select(. >= 0 and floor == .) | tostring``."""
    if type_name(value) != "number" or isinstance(value, bool):
        return None
    assert isinstance(value, (int, float))
    if value < 0 or value != int(value):
        return None
    return str(value) if isinstance(value, int) else json.dumps(value)


def _sha(value: Json) -> str | None:
    return value if isinstance(value, str) and value else None


# SHARED-CANDIDATE: warn_base_drift
def warn_base_drift(
    ctx: Ctx, pr: str, stale_base: int | None, say: Callable[[str], None], warn: Callable[[str], None]
) -> int:
    """Returns 0 fresh enough with no same-region overlap, 1 for either warning, 3 unknown."""
    repo = ctx.repo
    session = ctx.session

    def p(text: str) -> None:
        warn(f"pr-review.sh: {text}")

    result = session.retry(
        "read",
        ["api", f"repos/{repo}/pulls/{pr}", "--jq",
         '[(.base.ref // "-"), (.head.sha // "-"), (.mergeable_state // "-")] | @tsv'],
    )
    fields = result.stdout if isinstance(result, GhOk) else ""
    base, head_sha, mstate = ifs_read(fields, 3)
    if not isinstance(result, GhOk) or base in ("", "-") or head_sha in ("", "-"):
        p(
            f"how far {repo}#{pr} is behind its base: UNKNOWN — the PR could not be read"
            f" ({session.err_line()}). This is not 'not behind': check it by hand before merging"
            " and do not assume the base-drift file overlap is empty."
        )
        say(f"base-drift file overlap {repo}#{pr}: UNKNOWN — the PR snapshot could not be read")
        return 3
    result = session.retry("read", ["api", f"repos/{repo}/commits/{encode_ref(base)}", "--jq", ".sha"])
    base_sha = result.stdout if isinstance(result, GhOk) else ""
    if not isinstance(result, GhOk) or not base_sha:
        p(
            f"how far {repo}#{pr} is behind {base}: UNKNOWN — the tip of {base} could not be read"
            f" ({session.err_line()}). This is not 'not behind': check it by hand before merging"
            " and do not assume the base-drift file overlap is empty."
        )
        say(f"base-drift file overlap {repo}#{pr}: UNKNOWN — the tip of {base} could not be read")
        return 3

    dirty_warn = mstate == "dirty"
    if dirty_warn:
        say(f"!!! {repo}#{pr} CONFLICTS with {base} (mergeable_state=dirty): GitHub cannot build head")
        say(f"!!! {head_sha[:7]} merged with the current {base}, so no pull_request run tests that merge")
        say(f"!!! and the merge will be refused. Merge {base} in, resolve, push, and let the checks run")
        say("!!! on the resolution.")

    fwd = session.retry("read", ["api", f"repos/{repo}/compare/{base_sha}...{head_sha}?per_page=1"])
    match fwd:
        case GhOk(stdout=forward_text):
            pass
        case GhFailed() | GhUnanswered():
            p(
                f"how far {repo}#{pr} is behind {base}: UNKNOWN — the compare call did not answer"
                f" ({session.err_line()}). The base-drift file overlap is UNKNOWN too, not none;"
                " retry before merging."
            )
            say(f"base-drift file overlap {repo}#{pr}: UNKNOWN — the forward compare call did not answer")
            return 3
        case _:
            assert_never(fwd)
    forward = _parse(forward_text)
    count_unknown = False
    overlap_unknown = False
    overlap_reason = ""
    behind = _count(_get(forward, "behind_by"))
    if behind is None:
        count_unknown = True
    ahead = _count(_get(forward, "ahead_by")) or "?"
    forward_base = _sha(_get(_get(forward, "merge_base_commit"), "sha"))
    forward_set = compare_file_set(forward)
    if forward_base is None or forward_set is None:
        overlap_unknown = True

    reverse: Json = None
    reverse_set: FileSet | None = None
    reverse_base: str | None = None
    rev = session.retry("read", ["api", f"repos/{repo}/compare/{head_sha}...{base_sha}?per_page=1"])
    match rev:
        case GhOk(stdout=reverse_text):
            reverse = _parse(reverse_text)
            reverse_base = _sha(_get(_get(reverse, "merge_base_commit"), "sha"))
            reverse_set = compare_file_set(reverse)
            if reverse_base is None or reverse_set is None:
                overlap_unknown = True
        case GhFailed() | GhUnanswered():
            overlap_unknown = True
            overlap_reason = f"the reverse compare call did not answer ({session.err_line()})"
        case _:
            assert_never(rev)

    if not overlap_unknown and forward_base != reverse_base:
        overlap_unknown = True
        overlap_reason = "the two compare calls reported different merge bases"
    if (
        not overlap_unknown
        and forward_set is not None
        and reverse_set is not None
        and (forward_set.count >= 300 or reverse_set.count >= 300)
    ):
        overlap_unknown = True
        overlap_reason = "a compare file list reached GitHub's 300-file cap and may be truncated"
    overlap: list[Json] = []
    if not overlap_unknown and forward_set is not None and reverse_set is not None:
        base_paths = reverse_set.paths
        overlap = unique([q for q in forward_set.paths if member(base_paths, q)])
    meet: list[Json] = []
    unread: list[Json] = []
    disjoint: list[Json] = []
    if not overlap_unknown and overlap:
        try:
            pr_hunks = compare_hunks(forward)
        except JqError:
            pr_hunks = {}
        try:
            base_hunks = compare_hunks(reverse)
        except JqError:
            base_hunks = {}
        for q in overlap:
            key = q if isinstance(q, str) else tojson(q)
            a = pr_hunks.get(key)
            b = base_hunks.get(key)
            if a is None or b is None:
                unread.append(q)
            elif _meets(a, b):
                meet.append(q)
            else:
                disjoint.append(q)
    meet_all = meet + unread

    count_warn = False
    if count_unknown:
        p(
            f"how far {repo}#{pr} is behind {base}: UNKNOWN — the compare response did not contain"
            " a valid behind_by count. This is not 'not behind'."
        )
    elif stale_base is None:
        pass
    elif behind is not None and _int(behind) < stale_base:
        say(f"base freshness {repo}#{pr}: {behind} commit(s) behind {base}, {ahead} ahead (warns at {stale_base})")
    else:
        count_warn = True
        say(f"!!! {repo}#{pr} is {behind} COMMITS BEHIND its base ({base}).")
        say("!!! The review that approved this branch, and the checks that went green on it, both judged")
        say(f"!!! it against a base that has since moved {behind} commits. Under the roll-forward policy")
        say("!!! (ahrefs/ocannl#861) this does NOT block a clean merge — the post-merge integration loop")
        say("!!! re-runs the full suites on merged master — but a clean 'mergeable' says only that the")
        say("!!! two texts do not collide. Read the base-drift file intersection printed below.")

    if overlap_unknown:
        reason = overlap_reason or "a compare response was incomplete or invalid"
        say(f"base-drift file overlap {repo}#{pr}: UNKNOWN — {reason}")
        p(f"BASE-DRIFT FILE OVERLAP UNKNOWN for {repo}#{pr} — this is not 'none'; retry the merge read.")
    elif not overlap:
        say(f"base-drift file overlap {repo}#{pr}: none")
    elif not meet_all:
        say(
            f"base-drift file overlap {repo}#{pr}: {len(overlap)} path(s) changed on both sides, all"
            " in DISJOINT hunks (the base's lines and this PR's do not meet, which git merges by"
            f" construction): {tojson(disjoint)}"
        )
    else:
        say(
            "!!! BASE-DRIFT FILE OVERLAP: the base's advance touched the SAME REGIONS of"
            f" {len(meet_all)} path(s) changed by"
        )
        say(f"!!! {repo}#{pr}: {tojson(meet_all)}")
        if unread:
            say(
                f"!!! (hunks unread for {len(unread)} of them — patch missing or unreadable in the"
                f" compare response, so counted as meeting: {tojson(unread)})"
            )
        if disjoint:
            say(f"!!! and {len(disjoint)} more path(s) in disjoint hunks only: {tojson(disjoint)}")
        say("!!! Merging under the roll-forward policy (ahrefs/ocannl#861): a clean merge proceeds on")
        say(f"!!! the run that went green, and the post-merge integration loop verifies merged {base}.")
        say("!!! Read those files for semantic drift. The overlap is not a reason to rebase: rebase")
        say(f"!!! (or merge {base} in) only to resolve a conflict.")
        warn(
            f"pr-review.sh: BASE-DRIFT FILE OVERLAP for {repo}#{pr} in the same regions:"
            f" {tojson(meet_all)} — noted even below SHIP_PR_STALE_BASE; it does not block the"
            " merge under the roll-forward policy."
        )

    if count_warn:
        p(
            f"MERGING A STALE BRANCH: {repo}#{pr} is {behind} commits behind {base} (warns at"
            f" {stale_base}, SHIP_PR_STALE_BASE) — a clean merge is the policy (roll-forward,"
            " ahrefs/ocannl#861)."
        )
    if dirty_warn:
        p(
            f"{repo}#{pr} CONFLICTS with {base} (mergeable_state=dirty): nothing tests this head"
            f" merged with the current {base} while GitHub cannot build that merge — merge {base}"
            " in first."
        )
    if count_unknown or overlap_unknown:
        return 3
    if count_warn or dirty_warn or meet_all:
        return 1
    return 0


def _int(text: str) -> int:
    return int(float(text)) if "." in text else int(text)


def _parse(text: str) -> Json:
    try:
        doc: Json = json.loads(text)
    except ValueError:
        return None
    return doc


def _get(doc: Json, key: str) -> Json:
    return doc.get(key) if isinstance(doc, dict) else None
