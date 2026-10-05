"""The paths-ignore recognition: can any workflow of this repository still create a run for a PR head?

Ported from pr-review.sh's ``head_within_paths_ignore`` (ludics-lite#176) and the helpers it shares
with ``base``: the narrow workflow-YAML readers (``WORKFLOW_YAML_FILTER``, ``WORKFLOW_KEYS``, awk
state machines in the shell), the glob translation, the per-commit first-parent walk, the
workflow-directory inventory and the provider sample. The shell's comments above each of those
carry the review history (eleven rounds); every refusal there is a refusal here, in the same order,
because a refusal costs the run-creation grace and a guess settles an absence a run is about to
contradict.

Every gh call is the shell's, argument for argument (``--jq`` filters included), and its output is
read the way the shell read it (see ``shtext``). The two YAML readers were checked against the
shell's awk programs on 6,000 generated workflow texts, each read four ways: identical answers.
"""

import re
from collections.abc import Callable
from dataclasses import dataclass

from ludics.prreview.core import GhOk, GhSession
from ludics.prreview.workflow_yaml import paths_ignore_covers, workflow_filter, workflow_keys
from ludics.prreview.shtext import (
    after_line,
    count_nonempty,
    encode_ref,
    head_line,
    is_digits,
    nonempty_lines,
    tab_fields,
)

CONTENTS_DIR_CAP_DEFAULT = 1000
IGNORE_MAX_COMMITS_DEFAULT = 20
HEAD_INERT_EVENTS = ("workflow_call", "merge_group")

@dataclass(frozen=True)
class RecognitionLimits:
    contents_dir_cap: int = CONTENTS_DIR_CAP_DEFAULT
    ignore_max_commits: int = IGNORE_MAX_COMMITS_DEFAULT


# --- the reads ----------------------------------------------------------------------------------


class Reads:
    """The recognition's gh reads for one repository."""

    def __init__(
        self,
        session: GhSession,
        repo: str,
        limits: RecognitionLimits,
        is_advisory: Callable[[str], bool],
    ) -> None:
        self.session = session
        self.repo = repo
        self.limits = limits
        self.is_advisory = is_advisory

    def read(self, args: list[str]) -> str | None:
        result = self.session.retry("read", args)
        return result.stdout if isinstance(result, GhOk) else None

    def workflow_path(self, wid: str) -> str | None:
        wpath = self.read(["api", f"repos/{self.repo}/actions/workflows/{wid}", "--jq", '.path // ""'])
        if wpath is None:
            return None
        if wpath == "" or "\n" in wpath or "/../" in wpath or wpath.startswith(("../", "/")):
            return None
        return wpath

    def workflow_body(self, path: str, ref: str) -> str | None:
        body = self.read(
            [
                "api",
                "-H",
                "Accept: application/vnd.github.raw",
                f"repos/{self.repo}/contents/{encode_ref(path)}?ref={ref}",
            ]
        )
        return body if body else None

    def workflow_files_at(self, ref: str) -> list[str] | None:
        raw = self.read(
            [
                "api",
                f"repos/{self.repo}/contents/.github/workflows?ref={ref}",
                "--jq",
                'if type == "array" then (((. | length) | tostring),\n'
                '                                   (.[] | select(.type == "file") | .path))\n'
                "          else empty end",
            ]
        )
        if not raw:
            return None
        count = head_line(raw)
        raw = after_line(raw)
        if not is_digits(count) or int(count) <= 0 or int(count) >= self.limits.contents_dir_cap:
            return None
        files = [line for line in raw.split("\n") if re.search(r"\.ya?ml$", line)]
        return files or None

    def commit_files(self, sha: str) -> list[str] | None:
        raw = self.read(
            [
                "api",
                "--paginate",
                f"repos/{self.repo}/commits/{sha}?per_page=100",
                "--jq",
                '.files[]? | [.filename, (.previous_filename // "")] | @tsv',
            ]
        )
        if raw is None:
            return None
        count = count_nonempty(raw)
        if not 0 < count < 300:
            return None
        return nonempty_lines(raw.replace("\t", "\n"))

    def range_files(self, vsha: str, tip: str) -> list[str] | None:
        cap = self.limits.ignore_max_commits
        cmp = self.read(
            [
                "api",
                f"repos/{self.repo}/compare/{vsha}...{tip}?per_page={cap}",
                "--jq",
                "(.total_commits // 0 | tostring), ((.behind_by // -1) | tostring),\n"
                '          ((.commits // [])[] | [.sha, ((.parents // [])[0].sha // "-")] | @tsv)',
            ]
        )
        if cmp is None:
            return None
        count = head_line(cmp)
        cmp = after_line(cmp)
        behind = head_line(cmp)
        rows = after_line(cmp)
        if not is_digits(count):
            return None
        if behind != "0":
            return None
        n = int(count)
        if not 0 < n <= cap:
            return None
        if sum(1 for line in rows.split("\n") if re.match(r"[0-9a-f]{7,}\t", line)) != n:
            return None
        sha = tip
        steps = 0
        out: list[str] = []
        while sha != vsha:
            steps += 1
            if steps > n:
                return None
            parent = ""
            for row in rows.split("\n"):
                cols = row.split("\t")
                if cols[0] == sha:
                    parent = cols[1] if len(cols) > 1 else ""
                    break
            if parent in ("", "-"):
                return None
            files = self.commit_files(sha)
            if files is None:
                return None
            if any(f.startswith(".github/workflows/") for f in files):
                return None
            out.extend(files)
            sha = parent
        if steps == 0 or not out:
            return None
        return [f for f in out if f]

    def providers_are_actions_only(self) -> bool:
        sample = self.read(
            [
                "api",
                f"repos/{self.repo}/pulls?state=closed&sort=updated&direction=desc&per_page=20",
                "--jq",
                '[.[] | select(.merged_at != null) | .head.sha] | (.[0] // "")',
            ]
        )
        if not sample or re.search(r"[^0-9a-f]", sample):
            return False
        raw = self.read(
            [
                "api",
                f"repos/{self.repo}/commits/{sample}/check-runs?filter=latest&per_page=100",
                "--jq",
                "((.total_count // 0) | tostring),\n"
                '          (.check_runs[] | [(.name // "-"), (.app.slug // "-")] | @tsv)',
            ]
        )
        if raw is None:
            return False
        total = head_line(raw)
        raw = after_line(raw)
        if not is_digits(total) or int(total) <= 0:
            return False
        if count_nonempty(raw) != int(total):
            return False
        seen = 0
        for line in raw.split("\n"):
            name, slug = tab_fields(line, 2)
            if not name:
                continue
            if self.is_advisory(name):
                continue
            if slug != "github-actions":
                return False
            seen += 1
        return seen > 0


def head_within_paths_ignore(reads: Reads, pr: str, head: str, base: str, ref: str) -> str | None:
    """``head_within_paths_ignore``: the names of the workflows that explain why NO run can be
    created for this PR head (the settle line's PATHS_IGNORE_WHY), or None when that is not
    established -- every trigger of every workflow is inert here, unreachable, or a
    ``pull_request`` whose paths-ignore covers every commit from the merge base up, and the head,
    the base and the head ref were the same at the end of the read as at its start."""
    repo = reads.repo
    if not head or re.search(r"[^0-9a-f]", head):
        return None
    if not base or re.search(r"[^0-9a-f]", base):
        return None
    if not ref:
        return None
    mbase = reads.read(["api", f"repos/{repo}/compare/{base}...{head}", "--jq", '.merge_base_commit.sha // ""'])
    if not mbase or re.search(r"[^0-9a-f]", mbase):
        return None
    if mbase == head:
        return None
    if not reads.providers_are_actions_only():
        return None
    wf = reads.read(
        [
            "api",
            f"repos/{repo}/actions/workflows?per_page=100",
            "--jq",
            "((.total_count // 0) | tostring),\n"
            '          (.workflows[] | [(.id | tostring), (.name // "-"), (.state // "-")] | @tsv)',
        ]
    )
    if wf is None:
        return None
    total = head_line(wf)
    rows = after_line(wf)
    if not is_digits(total) or int(total) <= 0:
        return None
    if sum(1 for line in rows.split("\n") if re.match(r"[0-9][0-9]*\t", line)) != int(total):
        return None
    rfiles = reads.range_files(mbase, head)
    if rfiles is None:
        return None
    declared = reads.workflow_files_at(head)
    if declared is None:
        return None
    bdeclared = reads.workflow_files_at(base)
    if bdeclared is None:
        return None
    ends = set(declared) | set(bdeclared)
    listed: list[str] = []
    why = ""
    for row in rows.split("\n"):
        wid, wname, wstate = tab_fields(row, 3)
        if not wid:
            continue
        wpath = reads.workflow_path(wid)
        if wpath is None:
            return None
        listed.append(wpath)
        if wstate != "active" and wpath not in ends:
            continue
        body = reads.workflow_body(wpath, head)
        if body is None:
            return None
        bbody = reads.workflow_body(wpath, base)
        if bbody is None:
            return None
        if body != bbody:
            return None
        evs = workflow_keys(body, "")
        if not evs:
            return None
        for ev in evs:
            if ev == "pull_request":
                pats = workflow_filter(body, "pull_request", "paths-ignore")
                if not pats:
                    return None
                if not paths_ignore_covers(pats, rfiles):
                    return None
            elif ev not in HEAD_INERT_EVENTS:
                return None
        why = f"{why}, {wname}" if why else wname
    if not why:
        return None
    if any(f and f not in listed for f in [*declared, *bdeclared]):
        return None
    confirm = reads.read(
        [
            "api",
            f"repos/{repo}/pulls/{pr}",
            "--jq",
            '[(.head.sha // "-"), (.base.sha // "-"), (.head.ref // "-")]\n'
            '          | map(if type == "string" and length > 0 then . else "-" end) | @tsv',
        ]
    )
    if confirm != f"{head}\t{base}\t{ref}":
        return None
    return why
