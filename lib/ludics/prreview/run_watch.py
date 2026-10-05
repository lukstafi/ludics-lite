"""``pr-review.sh retry run watch owner/name#<run-id>``: the quiet await of ONE workflow run.

Ported from ``cmd_run_watch``; ``retry`` hands its ``run watch`` form here (the shell's
``cmd_run_watch`` stub forwards as the internal subcommand ``run-watch``, which is not a command
line of pr-review.sh's own). The run is addressed the way a PR is, and the repository is never
inferred from the cwd (ludics-lite#74): a cwd mismatch is an INVOCATION error.

Exit codes, matching ``checks``: 0 the run succeeded; 1 it concluded failure (a verdict -- do not
retry the watch, read the run); 2 the invocation is wrong (no repo named, a malformed run argument,
or a run/repo pair the API rejects); 3 the API did not answer; 4 no verdict -- still running at the
deadline, or stopped without being judged.
"""

import os
import re
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from typing import assert_never

from ludics import cli
from ludics.prreview.core import (
    GhFailed,
    GhOk,
    GhSession,
    GhUnanswered,
    api_rejection,
    die,
    fail,
    parse_ref,
    warn,
)
from ludics.prreview.watch_clock import clock_from_env
from ludics.prreview.watch_feeds import ifs_read

_DIGITS = re.compile(r"[0-9]+")


@dataclass(frozen=True)
class ChecksConfig:
    """The ``checks`` constants the await reads: SHIP_PR_CHECKS_INTERVAL (the default interval),
    SHIP_PR_CHECKS_WAIT (the ceiling), SHIP_PR_CHECKS_HEARTBEAT."""

    interval: int
    wait: int
    heartbeat: int


# SHARED-CANDIDATE: (pr-review.sh's source-time CHECKS_INTERVAL, CHECKS_WAIT, CHECKS_HEARTBEAT)
def load_checks_config(env: Mapping[str, str]) -> ChecksConfig:
    def whole(name: str, default: str) -> int:
        text = env.get(name, "") or default
        if not _DIGITS.fullmatch(text):
            die(f"{name} must be whole seconds, got '{text}'")
        return int(text)

    interval = whole("SHIP_PR_CHECKS_INTERVAL", "60")
    if interval <= 0:
        die(f"SHIP_PR_CHECKS_INTERVAL must be at least 1 second, got '{interval}'")
    return ChecksConfig(
        interval=interval,
        wait=whole("SHIP_PR_CHECKS_WAIT", "7200"),
        heartbeat=whole("SHIP_PR_CHECKS_HEARTBEAT", "600"),
    )


# SHARED-CANDIDATE: conclusion_class
def conclusion_class(conclusion: str) -> str:
    match conclusion:
        case "failure" | "timed_out" | "startup_failure":
            return "red"
        case "success" | "skipped" | "neutral":
            return "green"
        case "" | "null" | "pending":
            return "pending"
        case _:
            return "nogo"


def _needs(flag: str, what: str) -> int:
    """The shell's ``${2:?$1 needs ...}``: bash's message and exit status 1."""
    sys.stdout.flush()
    sys.stderr.write(f"pr-review.sh: 2: {flag} needs {what}\n")
    return 1


def run(session: GhSession, args: list[str], env: Mapping[str, str] | None = None) -> int:
    e = dict(os.environ) if env is None else env
    checks = load_checks_config(e)
    clock = clock_from_env(e)
    run_ref = ""
    flag_repo = ""
    interval = str(checks.interval)
    i = 0
    while i < len(args):
        a = args[i]
        if a in ("-R", "--repo"):
            if i + 1 >= len(args) or not args[i + 1]:
                return _needs(a, "owner/name")
            flag_repo = args[i + 1]
            i += 1
        elif a.startswith("-R=") or a.startswith("--repo="):
            flag_repo = a.split("=", 1)[1]
        elif a in ("-i", "--interval"):
            if i + 1 >= len(args) or not args[i + 1]:
                return _needs(a, "seconds")
            interval = args[i + 1]
            i += 1
        elif a.startswith("-i=") or a.startswith("--interval="):
            interval = a.split("=", 1)[1]
        elif a in ("--exit-status", "--compact"):
            pass
        elif a.startswith("-"):
            die(
                f"run watch: unsupported flag '{a}' — the quiet await takes owner/name#<run-id>,",
                "-R/--repo, -i/--interval, --exit-status, --compact",
            )
        else:
            if run_ref:
                die(f"run watch: got two run arguments ('{run_ref}' and '{a}') —", "name exactly one")
            run_ref = a
        i += 1
    if not run_ref:
        die(
            "retry run watch: name the run as owner/name#<run-id> — the quiet",
            "await polls `gh run view <id> --repo <owner/name>`. For a PR's checks, prefer",
            "`checks <pr> --wait`.",
        )
    ref = parse_ref(run_ref)
    if ref is None:
        die(
            "run watch: the run must be owner/name#<run-id> (or a bare run id",
            f"with -R owner/name), got '{run_ref}'",
        )
    run_id = ref.num
    if not _DIGITS.fullmatch(interval):
        die(f"run watch: the interval must be seconds, got '{interval}'")
    if int(interval) <= 0:
        die(f"run watch: the interval must be at least 1 second, got '{interval}'")
    repo = ref.repo
    if repo and flag_repo and repo != flag_repo:
        die(
            f"run watch: the run names {repo} and -R/--repo names {flag_repo} — two explicit targets",
            "that disagree; name the repo once.",
        )
    repo = repo or flag_repo or session.config.repo
    if not repo:
        die(
            f"run watch: name the repo — owner/name#{run_id} (preferred), or a bare",
            "run id with -R owner/name or REPO=owner/name. A bare id alone is refused and NOT resolved",
            "from the cwd: this await is a background call by construction, a background shell does not",
            "start in the checkout, and guessing turned a wrong-target read into a FAILED run",
            "(ludics-lite#74).",
        )

    started = clock.now()
    deadline = started + checks.wait
    beat = started
    while True:
        result = session.retry(
            "read",
            [
                "run", "view", run_id, "--repo", repo, "--json", "status,conclusion", "--jq",
                '[.status, (.conclusion // "pending")] | @tsv',
            ],
        )
        match result:
            case GhOk(stdout=line):
                pass
            case GhFailed() | GhUnanswered():
                err = session.err_line()
                if api_rejection(err):
                    die(
                        f"run watch: {repo} has no run {run_id} readable here: {err}. That is the",
                        "API answering about the id and the repo you named — nothing about the run's outcome,",
                        "so it is not a failure. Check both, then re-run the await.",
                    )
                fail(
                    3,
                    f"could not read run {run_id} in {repo} after {session.config.api_attempts} attempts ({err});",
                    "the run's state is UNKNOWN — not failed, not passed. Retry rather than concluding.",
                )
            case _:
                assert_never(result)
        status, concl = ifs_read(line, 2)
        if status == "completed":
            break
        now = clock.now()
        if now >= deadline:
            fail(
                4,
                f"run {run_id} in {repo} has NO VERDICT after",
                f"{checks.wait // 60} min (status: {status or 'unknown'}) — that is still not a failure;",
                f"re-arm the await, or read it with: gh run view {run_id} --repo {repo}",
            )
        if now - beat >= checks.heartbeat:
            warn(
                f"still waiting on run {run_id} in {repo}: {status or 'unknown'} after",
                f"{(now - started) // 60} min",
            )
            beat = now
        remaining = deadline - now
        clock.sleep(min(int(interval), remaining))
    match conclusion_class(concl):
        case "green":
            cli.say(f"run {run_id} in {repo}: {concl}")
            return 0
        case "red":
            fail(
                1,
                f"run {run_id} in {repo} concluded {concl} — the run FAILED. That is the workflow's",
                "verdict, not transport: do not retry the watch; read the failure with:",
                f"gh run view {run_id} --repo {repo} --log-failed",
            )
        case _:
            fail(
                4,
                f"run {run_id} in {repo} concluded {concl} — stopped, not judged (a superseding push or",
                "a manual cancel); re-run the workflow to turn it into an answer",
            )
