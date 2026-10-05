"""The build gate that ``checks`` and ``merge`` share: is the PR head's build signal green?

Ported from pr-review.sh's ``gate_checks`` and everything it reads through (ludics-lite#403):
the advisory list and the repository's own advisory file (``advisory_policy``, #530), the
override's waiver (``apply_waiver``/``is_waived``, #392), the check fold (``build_checks``,
``summarize_checks``), and the run list that overrules it (``run_signal`` with its job reads,
#24/#38/#500) -- whose run-less head, inside the grace, asks the paths-ignore recognition
(``workflows.head_within_paths_ignore``, #176).

The shell's comments above each of those functions carry the incident history and every review
round's reason; read them there before changing a rule here. What changed in the port is the
mechanism only: the globals the shell threaded through command substitutions (VERDICT, CHECK_*,
GATE_WAIVE, WAIVED, GATE_BASE) are the attributes of one ``Gate``. The advisory EREs are still
grep's to read (``ere``: grep is asked, as the shell asked it). Every gh call is the shell's, argument for argument,
and its TSV is read the way the shell's ``IFS=$'\\t' read`` read it (``shtext.tab_fields``), since
the column-shifting that read does on an empty field is part of what the placeholders guard.
"""

import functools
import re
import sys
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from typing import Literal, assert_never

from ludics import cli
from ludics.prreview import ere
from ludics.prreview.core import GhFailed, GhOk, GhSession, GhUnanswered, die, warn
from ludics.prreview.shtext import (
    age_of,
    fmt_age,
    freshest_age,
    herestring_lines,
    is_digits,
    newest,
    placeholder,
    tab_fields,
)
from ludics.prreview.workflows import RecognitionLimits, Reads, head_within_paths_ignore

DEFAULT_ADVISORY = "^(claude|Claude Code|github pages docs)$"
ADVISORY_FILE = ".github/ship-pr-advisory-checks"

# The forward's private names (pr-review.sh's PY_FORWARD_VARS): a constant whose being SET is read
# (SHIP_PR_ADVISORY_CHECKS) travels under a name of its own, so a default is never read as a
# caller's choice; and the constants no environment variable configures, which a suite's `retune`
# can still move.
ENV_BUILD_ADVISORY = "LUDICS_PR_BUILD_ADVISORY"
ENV_ADVISORY_FROM_ENV = "LUDICS_PR_ADVISORY_FROM_ENV"
ENV_ADVISORY_SETTLE = "LUDICS_PR_ADVISORY_SETTLE"
ENV_CONTENTS_DIR_CAP = "LUDICS_PR_CONTENTS_DIR_CAP"
ENV_IGNORE_MAX_COMMITS = "LUDICS_PR_IGNORE_MAX_COMMITS"
ENV_THREADS_PAGE_CAP = "LUDICS_PR_THREADS_PAGE_CAP"


def _env(env: Mapping[str, str], name: str, default: str) -> str:
    value = env.get(name, "")
    return value if value else default


def _private_int(env: Mapping[str, str], name: str, default: int) -> int:
    value = env.get(name, "")
    return int(value) if is_digits(value) else default


@dataclass(frozen=True)
class GateConfig:
    """The gate's and merge's source-time constants, validated as the shell validated them."""

    checks_interval: int
    checks_wait: int
    checks_heartbeat: int
    absent_grace: int
    advisory: str
    advisory_from_env: bool
    advisory_settle: int
    stale_base: int | None  # None: `off`
    threads_page_cap: int
    limits: RecognitionLimits


def load_gate_config(env: Mapping[str, str]) -> GateConfig:
    grace = _env(env, "SHIP_PR_BASE_ABSENT_GRACE", "300")
    if not is_digits(grace):
        die(f"SHIP_PR_BASE_ABSENT_GRACE must be a number of seconds, got '{grace}'")
    interval = _env(env, "SHIP_PR_CHECKS_INTERVAL", "60")
    if not is_digits(interval):
        die(f"SHIP_PR_CHECKS_INTERVAL must be whole seconds, got '{interval}'")
    if int(interval) <= 0:
        die(f"SHIP_PR_CHECKS_INTERVAL must be at least 1 second, got '{interval}'")
    wait = _env(env, "SHIP_PR_CHECKS_WAIT", "7200")
    if not is_digits(wait):
        die(f"SHIP_PR_CHECKS_WAIT must be whole seconds, got '{wait}'")
    heartbeat = _env(env, "SHIP_PR_CHECKS_HEARTBEAT", "600")
    if not is_digits(heartbeat):
        die(f"SHIP_PR_CHECKS_HEARTBEAT must be whole seconds, got '{heartbeat}'")
    stale = _env(env, "SHIP_PR_STALE_BASE", "20")
    if stale != "off" and not is_digits(stale):
        die(f"SHIP_PR_STALE_BASE must be a number of commits or 'off', got '{stale}'")
    from_var = env.get("SHIP_PR_ADVISORY_CHECKS", "")
    advisory = env[ENV_BUILD_ADVISORY] if ENV_BUILD_ADVISORY in env else (from_var or DEFAULT_ADVISORY)
    from_env = bool(env[ENV_ADVISORY_FROM_ENV]) if ENV_ADVISORY_FROM_ENV in env else bool(from_var)
    return GateConfig(
        checks_interval=int(interval),
        checks_wait=int(wait),
        checks_heartbeat=int(heartbeat),
        absent_grace=int(grace),
        advisory=advisory,
        advisory_from_env=from_env,
        advisory_settle=_private_int(env, ENV_ADVISORY_SETTLE, 60),
        stale_base=None if stale == "off" else int(stale),
        threads_page_cap=_private_int(env, ENV_THREADS_PAGE_CAP, 50),
        limits=RecognitionLimits(
            contents_dir_cap=_private_int(env, ENV_CONTENTS_DIR_CAP, 1000),
            ignore_max_commits=_private_int(env, ENV_IGNORE_MAX_COMMITS, 20),
        ),
    )


# --- small readings ---------------------------------------------------------------------------------

type ConclusionClass = Literal["red", "green", "pending", "nogo"]


# SHARED-CANDIDATE: conclusion_class
def conclusion_class(conclusion: str) -> ConclusionClass:
    """``conclusion_class``: a verdict (red, green), no verdict yet (pending), or stopped (nogo)."""
    if conclusion in ("failure", "timed_out", "startup_failure"):
        return "red"
    if conclusion in ("success", "skipped", "neutral"):
        return "green"
    if conclusion in ("", "null", "pending"):
        return "pending"
    return "nogo"


def _sort_number(text: str) -> float:
    m = re.match(r"[ \t]*(-?[0-9]*(\.[0-9]*)?)", text)
    try:
        return float(m.group(1)) if m and m.group(1) not in ("", "-", ".", "-.") else 0.0
    except ValueError:
        return 0.0


# SHARED-CANDIDATE: newest_first
def newest_first(text: str, created_col: int, id_col: int) -> str:
    """``newest_first``: ``LC_ALL=C sort -t$'\\t' -k<c>,<c>r -k<i>,<i>nr`` over the lines -- newest
    created_at first, a same-second tie to the higher id, the whole line (bytes, ascending) as
    sort's last resort."""

    def col(line: str, n: int) -> str:
        cols = line.split("\t")
        return cols[n - 1] if len(cols) >= n else ""

    def cmp(a: str, b: str) -> int:
        ka = col(a, created_col).encode("utf-8", "surrogateescape")
        kb = col(b, created_col).encode("utf-8", "surrogateescape")
        if ka != kb:
            return -1 if ka > kb else 1
        na, nb = _sort_number(col(a, id_col)), _sort_number(col(b, id_col))
        if na != nb:
            return -1 if na > nb else 1
        ba, bb = a.encode("utf-8", "surrogateescape"), b.encode("utf-8", "surrogateescape")
        return (ba > bb) - (ba < bb)

    lines = text.split("\n")
    return "\n".join(sorted(lines, key=functools.cmp_to_key(cmp)))


def _before_space(text: str) -> str:
    return text.split(" ", 1)[0]


def _after_space(text: str) -> str:
    parts = text.split(" ", 1)
    return parts[1] if len(parts) == 2 else text


# --- the build signal -------------------------------------------------------------------------------

type Verdict = Literal[
    "", "green", "absent", "red", "runred", "waived", "pending", "mixed", "unjudged",
    "superseded", "unknown",
]


@dataclass
class RunSignal:
    """``run_signal``'s answer: its status (0 the fold stands, 1 red at the run level, 3 unread,
    4 no verdict yet), the run-level red count, the runs the waiver took out of it (one
    "<run id> <run|job> <name>" per line), and the reason line."""

    rc: int
    red: int
    waived_runs: str
    reason: str


@dataclass
class Clock:
    """The gate's clock and sleep, injectable: whole seconds, as ``date +%s`` gave them."""

    now: Callable[[], float] = time.time
    sleep: Callable[[float], None] = time.sleep

    def seconds(self) -> int:
        return int(self.now())


# SHARED-CANDIDATE: gate_checks (with build_checks, summarize_checks, run_signal, apply_waiver):
# `base`'s tip_pr_head_verdict judges a merged PR's head through the same gate.
@dataclass
class Gate:
    """One command's build gate. The attributes are the shell's globals of the same name, which
    ``merge`` reads after a gate: ``verdict`` (VERDICT), ``check_sha`` (CHECK_SHA, what the verdict
    is ABOUT), ``gate_base`` (GATE_BASE, the base the round's run read was about), and the counts."""

    session: GhSession
    repo: str
    config: GateConfig
    clock: Clock = field(default_factory=Clock)
    advisory: str = ""
    verdict: Verdict = ""
    check_sha: str = ""
    gate_base: str = ""
    check_red: int = 0
    check_waived: int = 0
    run_waived: int = 0
    check_passed: int = 0
    check_pending: int = 0
    check_total: int = 0
    check_green: int = 0
    check_lines: str = ""
    waive_mode: Literal["", "record", "apply"] = ""
    waived: set[str] = field(default_factory=lambda: set[str]())
    _advisory_seen: dict[tuple[str, str], bool] = field(default_factory=lambda: dict[tuple[str, str], bool]())

    def __post_init__(self) -> None:
        if not self.advisory:
            self.advisory = self.config.advisory

    # --- the advisory list ---------------------------------------------------------------------------

    # SHARED-CANDIDATE: is_advisory
    def is_advisory(self, name: str) -> bool:
        """``is_advisory``: grep matches the name against the advisory ERE (a pattern grep refuses
        matches nothing, as in the shell). One process's answers are kept: a wait loop asks the same
        names every round, and grep's answer for a pattern, a name and an environment is fixed."""
        key = (self.advisory, name)
        if key not in self._advisory_seen:
            self._advisory_seen[key] = ere.matches(self.advisory, name)
        return self._advisory_seen[key]

    def advisory_policy(self) -> int:
        """``advisory_policy``: the advisory list from the repository's ADVISORY_FILE on its default
        branch, when there is one and the variable is unset. 0 read (or not needed); 2 or 3, said
        on stderr, when the policy is refused or unknown -- returned, not raised, so ``checks`` can
        still end with its trailer."""
        if self.config.advisory_from_env:
            return 0
        repo = self.repo
        result = self.session.retry(
            "read", ["api", "-H", "Accept: application/vnd.github.raw", f"repos/{repo}/contents/{ADVISORY_FILE}"]
        )
        match result:
            case GhOk(stdout=body):
                parsed = advisory_parse(body, f"{repo}'s {ADVISORY_FILE}")
                if parsed is None:
                    return 2
                self.advisory = parsed
                warn(f"advisory checks, from {repo}'s {ADVISORY_FILE}: {self.advisory}")
                return 0
            case GhFailed():
                if "HTTP 404" in self.session.err_line():
                    absent = self.advisory_absent()
                    if absent == 0:
                        return 0
                    if absent == 3:
                        warn(
                            f"{repo}'s advisory list, {ADVISORY_FILE}, read as 404, and the listing that would",
                            f"establish its absence did not answer ({self.session.err_line()}). The gate's policy is",
                            "UNKNOWN; nothing was judged. Retry.",
                        )
                        return 3
                    warn(
                        f"{repo}'s advisory list, {ADVISORY_FILE}, read as 404, and its absence could not be",
                        "established from the directory listing: a 404 is also how GitHub answers a token",
                        "without Contents access to a private repository, so the default list is not a safe",
                        "stand-in. Give the token Contents read access.",
                    )
                    return 2
                warn(
                    f"could not read {repo}'s advisory list, {ADVISORY_FILE} on its default branch",
                    f"({self.session.err_line()}). The API refused the read, so the gate's policy is unknown, and the",
                    "default list is not a safe stand-in for it.",
                )
                return 2
            case GhUnanswered():
                warn(
                    f"could not read {repo}'s advisory list, {ADVISORY_FILE} on its default branch",
                    f"({self.session.err_line()}). The gate's policy is UNKNOWN; nothing was judged. Retry.",
                )
                return 3
            case _:
                assert_never(result)

    def advisory_absent(self) -> int:
        """``advisory_absent``: 0 when a directory listing that answered leaves the file out; 2 when
        that is not established; 3 when a listing did not answer."""
        for directory in (".github", ""):
            leaf = "ship-pr-advisory-checks" if directory else ".github"
            path = f"repos/{self.repo}/contents" + (f"/{directory}" if directory else "")
            result = self.session.retry(
                "read",
                ["api", path, "--jq", 'if type == "array" then ((length | tostring), (.[].name)) else empty end'],
            )
            match result:
                case GhUnanswered():
                    return 3
                case GhFailed():
                    if not directory:
                        return 2
                    if "HTTP 404" in self.session.err_line():
                        continue
                    return 2
                case GhOk(stdout=raw):
                    count = raw.split("\n", 1)[0]
                    if not is_digits(count):
                        return 2
                    if int(count) >= self.config.limits.contents_dir_cap:
                        return 2
                    if leaf in raw.split("\n"):
                        return 2
                    return 0
                case _:
                    assert_never(result)
        return 2

    # --- the check fold -------------------------------------------------------------------------------

    def build_checks(self, sha: str) -> list[str] | None:
        """``build_checks``: one "class\\tname\\tconclusion\\turl\\tsuite" line per non-advisory check
        run of ``sha``; None when the read failed (an outage is not a commit with no checks)."""
        result = self.session.retry(
            "read",
            [
                "api",
                "--paginate",
                f"repos/{self.repo}/commits/{sha}/check-runs?filter=latest&per_page=100",
                "--jq",
                '.check_runs[] | [.name, (.conclusion // "pending"), (.html_url // "-"),\n'
                '          ((.check_suite.id // "-") | tostring)] | @tsv',
            ],
        )
        if not isinstance(result, GhOk):
            return None
        rows: list[str] = []
        for line in herestring_lines(result.stdout):
            name, concl, url, suite = tab_fields(line, 4)
            if not name or self.is_advisory(name):
                continue
            rows.append(f"{conclusion_class(concl)}\t{name}\t{concl}\t{url}\t{suite or '-'}")
        return rows

    def apply_waiver(self, rows: list[str]) -> list[str]:
        """``apply_waiver``: the red rows the waiver covers marked ``waived`` -- recorded first on the
        recording read -- and only while their key names exactly ONE row."""
        keys: list[str] = []
        for row in rows:
            cls, name, _concl, _url, suite = tab_fields(row, 5)
            if cls:
                keys.append(f"check:{suite}/{name}")
        out: list[str] = []
        for row in rows:
            cls, name, concl, url, suite = tab_fields(row, 5)
            if not cls:
                continue
            key = f"check:{suite}/{name}"
            if cls == "red" and keys.count(key) == 1:
                if self.waive_mode == "record":
                    self.waived.add(key)
                if key in self.waived:
                    cls = "waived"
            out.append(f"{cls}\t{name}\t{concl}\t{url}\t{suite}")
        return out

    def summarize(self, rows: list[str]) -> None:
        """``summarize_checks``: the per-check classes folded into ``verdict`` and the report lines."""
        red = waived = pending = nogo = green = passed = 0
        lines: list[str] = []
        for row in rows:
            cls, name, concl, url, _suite = tab_fields(row, 5)
            if not cls:
                continue
            match cls:
                case "red":
                    red += 1
                    lines.append(f"  RED      {name} ({concl})  {url}\n")
                case "waived":
                    waived += 1
                    lines.append(f"  RED      {name} ({concl} — WAIVED: red when --override was given)  {url}\n")
                case "pending":
                    pending += 1
                    lines.append(f"  running  {name} (no verdict yet)  {url}\n")
                case "nogo":
                    nogo += 1
                    lines.append(f"  no verdict  {name} ({concl} — stopped, not judged)  {url}\n")
                case _:
                    green += 1
                    if concl == "success":
                        passed += 1
        self.check_lines = "".join(lines)
        self.check_red = red
        self.check_waived = waived
        self.check_passed = passed
        self.check_pending = pending
        self.check_total = red + waived + pending + nogo + green
        if red:
            self.verdict = "red"
        elif pending:
            self.verdict = "pending"
        elif nogo:
            self.verdict = "mixed"
        elif waived:
            self.verdict = "waived"
        elif not green:
            self.verdict = "absent"
        else:
            self.verdict = "green"
        self.check_green = green

    # --- the run list ---------------------------------------------------------------------------------

    def run_jobs(self, run_id: str) -> str | None:
        """``run_jobs``: "name\\tconclusion\\tcreated_at\\tcompleted_at" per job of the run."""
        result = self.session.retry(
            "read",
            [
                "api",
                "--paginate",
                f"repos/{self.repo}/actions/runs/{run_id}/jobs?per_page=100",
                "--jq",
                '.jobs[] | [(.name // "-"), (.conclusion // "pending"), (.created_at // "-"),\n'
                '          (.completed_at // "-")]\n'
                '          | map(if type == "string" and length > 0 then . else "-" end) | @tsv',
            ],
        )
        return result.stdout if isinstance(result, GhOk) else None

    def run_red_is_advisory_only(self, run_id: str, suite: str) -> int:
        """``run_red_is_advisory_only``: 0 advisory jobs alone explain the run's red; 2 explained,
        but a job the override waived is part of it; 1 not explained (or the jobs are unread)."""
        raw = self.run_jobs(run_id)
        if raw is None:
            return 1
        names = [tab_fields(line, 3)[0] for line in herestring_lines(raw)]
        names = [n for n in names if n]
        jobs = hard = waived = 0
        for line in herestring_lines(raw):
            jname, jconcl, _times = tab_fields(line, 3)
            if not jname:
                continue
            jobs += 1
            if self.is_advisory(jname):
                continue
            if conclusion_class(jconcl) != "red":
                continue
            if names.count(jname) == 1 and f"check:{suite or '-'}/{jname}" in self.waived:
                waived += 1
                continue
            hard += 1
        if not (jobs > 0 and hard == 0):
            return 1
        return 2 if waived else 0

    def run_inflight_is_advisory_only(self, run_id: str) -> bool:
        """``run_inflight_is_advisory_only``: every unfinished job advisory, every finished
        non-advisory job green, and the job list still for ADVISORY_SETTLE seconds."""
        raw = self.run_jobs(run_id)
        if raw is None:
            return False
        unfinished = 0
        last = ""
        for line in herestring_lines(raw):
            jname, jconcl, jcreated, jdone = tab_fields(line, 4)
            if not jname:
                continue
            if (jcreated or "-") == "-":
                return False
            last = newest(last, jcreated)
            if conclusion_class(jconcl) == "pending":
                if not self.is_advisory(jname):
                    return False
                unfinished += 1
                continue
            if (jdone or "-") == "-":
                return False
            last = newest(last, jdone)
            if self.is_advisory(jname):
                continue
            if conclusion_class(jconcl) != "green":
                return False
        if unfinished == 0:
            return False
        age = age_of(last, self.clock.now)
        return age is not None and age >= self.config.advisory_settle

    def run_signal(self, sha: str, pr_at: str, checks: int, base_sha: str, head_ref: str, pr: str) -> RunSignal:
        """``run_signal``: the head's workflow runs, read whenever the check fold leaves nothing to
        wait for, and able to overrule it (see the shell's comment for every round)."""
        repo = self.repo
        waived_runs = ""
        result = self.session.retry(
            "read",
            [
                "api",
                "--paginate",
                f"repos/{repo}/actions/runs?head_sha={sha}&per_page=100",
                "--jq",
                '.workflow_runs[] | [(.created_at // "-"), ((.id // 0) | tostring),\n'
                "          ((.workflow_id // 0) | tostring),\n"
                '          (.event // "-"), (.name // "-"), (.status // "unknown"), (.conclusion // "pending"),\n'
                '          ((.check_suite_id // "-") | tostring)]\n'
                "          | @tsv",
            ],
        )
        if not isinstance(result, GhOk):
            return RunSignal(
                3, 0, waived_runs, f"the workflow runs for this head could not be read ({self.session.err_line()})"
            )
        raw = newest_first(result.stdout, 1, 2)
        seen: set[str] = set()
        red_rows: list[str] = []
        inflight_ids: list[str] = []
        runs = nogo = 0
        for line in herestring_lines(raw):
            _created, rid, wid, event, name, status, concl, suite = tab_fields(line, 8)
            if not rid:
                continue
            if self.is_advisory(name):
                continue
            if status != "completed" or conclusion_class(concl) == "pending":
                runs += 1
                inflight_ids.append(rid)
                continue
            key = f"{wid}/{event}"
            if key in seen:
                continue
            seen.add(key)
            runs += 1
            cls = conclusion_class(concl)
            match cls:
                case "red":
                    red_rows.append(f"{rid}\t{name}\t{concl}\t{suite or '-'}")
                case "nogo":
                    nogo += 1
                case "green" | "pending":
                    pass
                case _:
                    assert_never(cls)
        red = 0
        red_note = ""
        for row in red_rows:
            rid, rname, rconcl, rsuite = tab_fields(row, 4)
            if not rid:
                continue
            explained = self.run_red_is_advisory_only(rid, rsuite)
            if explained == 0:
                continue
            if explained == 2:
                waived_runs += f"{rid} job {rname}\n"
                continue
            if self.waive_mode == "record" or (self.waive_mode == "apply" and f"run:{rid}" in self.waived):
                waived_runs += f"{rid} run {rname}\n"
                continue
            red += 1
            red_note = red_note or f"{rname} ({rconcl})"
        if red > 0:
            return RunSignal(
                1,
                red,
                waived_runs,
                f"{red} workflow run(s) for this head concluded red with no build check"
                f" to show for it — {red_note}; a run that fails before its jobs start leaves nothing in the"
                " check list",
            )
        inflight = released = 0
        for rid in inflight_ids:
            if self.run_inflight_is_advisory_only(rid):
                released += 1
            else:
                inflight += 1
        if inflight > 0:
            return RunSignal(
                4,
                0,
                waived_runs,
                f"{inflight} workflow run(s) for this head have no conclusion yet (queued,"
                " running, or completed with none recorded) — their check runs may not exist yet",
            )
        if nogo > 0:
            return RunSignal(
                4,
                0,
                waived_runs,
                f"{nogo} workflow run(s) for this head completed stopped-not-judged (cancelled,"
                " stale or action_required) with no build check behind them — stopped is not absence and"
                " not a verdict: re-run the workflow",
            )
        if checks > 0 and runs > 0:
            if released > 0:
                reason = (
                    f"{runs} workflow run(s) for this head are judged — {released} of them"
                    " still running, but only advisory jobs (SHIP_PR_ADVISORY_CHECKS)"
                )
            else:
                reason = f"{runs} workflow run(s) for this head are finished and judged"
            return RunSignal(0, 0, waived_runs, reason)
        pushed = self.session.retry("read", ["api", f"repos/{repo}/commits/{sha}", "--jq", ".commit.committer.date"])
        pushed_at = pushed.stdout if isinstance(pushed, GhOk) else ""
        age = freshest_age(pushed_at, pr_at, now=self.clock.now)
        if age is None:
            return RunSignal(
                3,
                0,
                waived_runs,
                "no usable clock for this head: neither its commit date nor the PR's updated_at"
                f" could be read ({self.session.err_line()}), or both are in the future, so the run-creation window"
                " is unknown",
            )
        if runs > 0:
            seen_text = f"{runs} workflow run(s) for this head finished and left no build check behind"
        else:
            seen_text = "no workflow run exists for this head"
        grace = self.config.absent_grace
        if runs == 0 and age < grace:
            reads = Reads(self.session, repo, self.config.limits, self.is_advisory)
            why = head_within_paths_ignore(reads, pr, sha, base_sha, head_ref)
            if why is not None:
                return RunSignal(
                    0,
                    0,
                    waived_runs,
                    "no workflow run exists for this head, and none can be created by"
                    f" {why}: every trigger of theirs that this change fires is either filtered"
                    " out by its own paths-ignore — every commit from the merge base up changes only ignored"
                    " paths — or cannot reach this branch at all",
                )
        if age < grace:
            return RunSignal(
                4,
                0,
                waived_runs,
                f"{seen_text}, and the head has been in place at most {fmt_age(age)} — inside the"
                f" {fmt_age(grace)} run-creation grace (SHIP_PR_BASE_ABSENT_GRACE), so a run"
                " may still appear",
            )
        return RunSignal(
            0,
            0,
            waived_runs,
            f"{seen_text} in the {fmt_age(age)} since it appeared — past the {fmt_age(grace)} run-creation grace",
        )

    # --- the gate -------------------------------------------------------------------------------------

    def _pr_fields(self, pr: str, with_updated: bool) -> tuple[bool, list[str]]:
        if with_updated:
            jq = (
                '[(.head.sha // "-"), (.updated_at // "-"), (.base.sha // "-"), (.head.ref // "-")]\n'
                '          | map(if type == "string" and length > 0 then . else "-" end) | @tsv'
            )
        else:
            jq = (
                '[(.head.sha // "-"), (.base.sha // "-"), (.head.ref // "-")]\n'
                '            | map(if type == "string" and length > 0 then . else "-" end) | @tsv'
            )
        result = self.session.retry("read", ["api", f"repos/{self.repo}/pulls/{pr}", "--jq", jq])
        text = result.stdout if isinstance(result, GhOk) else ""
        fields = [placeholder(f) for f in tab_fields(text, 4 if with_updated else 3)]
        return isinstance(result, GhOk), fields

    def check(self, pr: str, wait_for: int, waive: bool = False) -> int:
        """``gate_checks <pr> <wait> [waive]``: read the head and judge its build signal, printing the
        report. 0 green or a confirmed absence; 1 red (a check, a checkless run, or every red
        waived); 3 unread; 4 no verdict yet; 5 the head was superseded."""
        repo = self.repo
        self.gate_base = ""
        self.waived = set()
        self.run_waived = 0
        self.check_waived = 0
        self.waive_mode = "record" if waive else ""
        ok, (sha, pr_at, base_sha, head_ref) = self._pr_fields(pr, with_updated=True)
        if not ok or not sha:
            self.verdict = "unknown"
            warn(
                f"could not read {repo}#{pr}'s head SHA ({self.session.err_line()}); the build signal is UNKNOWN,",
                "which is NOT 'nothing is red'.",
            )
            return 3
        self.check_sha = sha
        started = self.clock.seconds()
        deadline = started + wait_for
        beat = started
        run_why = ""
        while True:
            rows = self.build_checks(sha)
            if rows is None:
                self.verdict = "unknown"
                warn(
                    f"could not read the checks of {repo}#{pr} @{sha[:8]} ({self.session.err_line()});",
                    "the build signal is UNKNOWN, which is NOT 'nothing is red'.",
                )
                return 3
            if self.waive_mode:
                rows = self.apply_waiver(rows)
            self.summarize(rows)
            self.run_waived = 0
            self.gate_base = base_sha
            if self.verdict != "red":
                sig = self.run_signal(sha, pr_at, self.check_total, base_sha, head_ref, pr)
                run_why = sig.reason
                for entry in herestring_lines(sig.waived_runs):
                    if not entry:
                        continue
                    self.run_waived += 1
                    rid = _before_space(entry)
                    rest = _after_space(entry)
                    if _before_space(rest) == "job":
                        self.check_lines += (
                            f"  RED      workflow run {_after_space(rest)} (red through a check above that is WAIVED)\n"
                        )
                    else:
                        if self.waive_mode == "record":
                            self.waived.add(f"run:{rid}")
                        self.check_lines += (
                            f"  RED      workflow run {_after_space(rest)} (no build check behind it — WAIVED:"
                            " red when --override was given)\n"
                        )
                match sig.rc:
                    case 1:
                        self.verdict = "runred"
                        self.check_red = sig.red
                    case 3:
                        self.verdict = "unknown"
                        warn(
                            f"could not read the workflow runs of {repo}#{pr} @{sha[:8]} ({run_why}); the checks",
                            "alone are not the build signal, so this is UNKNOWN, which is NOT 'nothing is red'.",
                        )
                        return 3
                    case 4:
                        if self.verdict != "pending":
                            self.verdict = "unjudged"
                    case _:
                        if self.run_waived and self.verdict in ("green", "absent"):
                            self.verdict = "waived"
                        if "only advisory jobs" in run_why:
                            self.check_lines += f"  running  {run_why} — not waited for\n"
            if self.waive_mode == "record":
                self.waive_mode = "apply"
            ok, (current, base_sha, head_ref) = self._pr_fields(pr, with_updated=False)
            if not ok or not current or current == "null":
                self.verdict = "unknown"
                warn(f"could not re-read {repo}#{pr}'s head SHA; the build signal is UNKNOWN.")
                return 3
            if current != sha:
                self.verdict = "superseded"
                cli.say(
                    f"build signal {repo}#{pr}: SUPERSEDED — observed {sha}, current {current};"
                    " re-run for the new head"
                )
                return 5
            now = self.clock.seconds()
            if self.verdict not in ("pending", "unjudged"):
                break
            if now >= deadline:
                break
            if now - beat >= self.config.checks_heartbeat:
                note = run_why if self.verdict == "unjudged" else f"{self.check_pending} check(s) running"
                warn(
                    f"still waiting on {repo}#{pr} @{sha[:8]}: no verdict after {(now - started) // 60} of",
                    f"{wait_for // 60} min ({note})",
                )
                beat = now
            self.clock.sleep(min(self.config.checks_interval, deadline - now))
        note = f" ({self.check_green} build check(s) have passed so far)" if self.check_green > 0 else ""
        head = f"build signal {repo}#{pr} @{sha[:8]}"
        match self.verdict:
            case "red":
                cli.say(f"{head}: RED — {self.check_red} of {self.check_total} build checks failed")
            case "waived":
                cli.say(
                    f"{head}: RED, WAIVED — every red ({self.check_waived + self.run_waived}) was red when"
                    " --override was given; everything else has a verdict and none is red"
                )
            case "pending":
                cli.say(f"{head}: NO VERDICT YET — still running")
            case "mixed":
                cli.say(f"{head}: INCOMPLETE — {self.check_green} passed, the rest were stopped without a verdict")
            case "runred":
                cli.say(f"{head}: RED — {run_why}")
            case "unjudged":
                cli.say(f"{head}: NO VERDICT YET — {run_why}{note}")
            case "absent":
                cli.say(f"{head}: ABSENT — no build check ran on this commit: {run_why}")
            case "green":
                cli.say(f"{head}: green — {self.check_green} build checks passed")
            case "" | "superseded" | "unknown":
                pass
            case _:
                assert_never(self.verdict)
        if self.check_lines:
            sys.stdout.write(self.check_lines)
        match self.verdict:
            case "red" | "runred" | "waived":
                return 1
            case "pending" | "mixed" | "unjudged":
                return 4
            case _:
                return 0


# SHARED-CANDIDATE: advisory_parse
def advisory_parse(text: str, where: str) -> str | None:
    """``advisory_parse``: the file's ERE lines joined by ``|`` (blank lines, ``#`` comments and a
    trailing CR aside), or None -- having said why -- for a file that is not such a list: no ERE
    line, a backreference (or an escaped backslash before a digit), a line or a join grep
    refuses (``ere.valid``)."""
    joined = ""
    n = 0
    for raw in text.split("\n"):
        line = raw[:-1] if raw.endswith("\r") else raw
        if not re.search(r"[^ \t\n\r\f\v]", line):
            continue
        if line.lstrip(" \t\n\r\f\v").startswith("#"):
            continue
        if re.search(r"\\[1-9]", line):
            warn(f"{where} holds a line with a backreference, which a list cannot keep: {line}")
            return None
        if not ere.valid(line):
            warn(f"{where} holds a line that is not an ERE grep accepts: {line}")
            return None
        n += 1
        joined = f"{joined}|{line}" if joined else line
    if n == 0:
        warn(
            f"{where} holds no ERE line (blank lines and # comments aside). An empty list would match",
            "every name; fix the file.",
        )
        return None
    if not ere.valid(joined):
        warn(f"{where}'s lines do not join into an ERE grep accepts: {joined}")
        return None
    return joined
