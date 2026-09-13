#!/usr/bin/env python3
"""Pin the two unattended reporters without merging their distinct vocabulary.

This deliberately accepts only their current, simple YAML layout. A layout change
must update this probe; it is not a general YAML or GitHub expression evaluator.
The shell is executed from the actual run blocks, with gh replaced by a recorder.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
GUARDS = {
    "api-contract": "${{ !cancelled() && github.event_name == 'schedule' && needs.contract.outputs.rc != '0' && needs.contract.outputs.rc != '3' }}",
    "base-watch": "${{ !cancelled() && needs.read.result != 'skipped' && (github.event_name == 'schedule' || github.event_name == 'workflow_run') && needs.read.outputs.rc != '0' && needs.read.outputs.rc != '3' }}",
}
VOCABULARY = {
    "api-contract": {"1": "found a belief", "4": "got a 4xx", "5": "was refused a read"},
    "base-watch": {"1": "found main RED", "4": "reached no verdict for main"},
}


def reporter(text, name):
    """Fail closed if the report job/guard/single literal run block moves."""
    jobs = re.findall(r"^  report:\n(.*?)(?=^  [A-Za-z_-]+:|\Z)", text, re.M | re.S)
    assert len(jobs) == 1, "expected exactly one report job"
    job = jobs[0]
    guards = re.findall(r"^    if: (.*)$", job, re.M)
    assert guards == [GUARDS[name]], f"{name}: reporter guard drifted: {guards}"
    runs = re.findall(r"^        run: \|\n((?:          .*\n|\n)+)", job, re.M)
    assert len(runs) == 1, "expected exactly one literal reporter run block"
    return "\n".join(line[10:] for line in runs[0].splitlines()) + "\n"


def run_reporter(shell, rc, existing):
    with tempfile.TemporaryDirectory(prefix="reporter-probe-") as tmp:
        root = Path(tmp)
        gh = root / "gh"
        gh.write_text(f"#!{sys.executable}\n" + '''import json, os, sys
with open(os.environ["CALL_LOG"], "a") as out:
    out.write(json.dumps(sys.argv[1:]) + "\\n")
if sys.argv[1:3] == ["issue", "list"]:
    print(os.environ["EXISTING"])
''')
        gh.chmod(0o755)
        env = dict(os.environ, PATH=tmp + os.pathsep + os.environ["PATH"],
                   CALL_LOG=str(root / "calls"), EXISTING=existing, RC=rc,
                   REPORT="fixture report: workflow X failed", GH_TOKEN="fixture-only",
                   GITHUB_SERVER_URL="https://example.invalid",
                   GITHUB_REPOSITORY="fixture/repository", GITHUB_RUN_ID="42")
        subprocess.run(["bash", "-eu", "-o", "pipefail", "-c", shell], env=env,
                       cwd=tmp, capture_output=True, text=True, check=True, timeout=10)
        return [json.loads(line) for line in (root / "calls").read_text().splitlines()]


def assert_report(test, name, shell, rc, existing):
    calls = run_reporter(shell, rc, existing)
    test.assertEqual(len(calls), 2)
    test.assertEqual(calls[0][:2], ["issue", "list"])
    test.assertEqual(calls[1][:2], ["issue", "comment" if existing else "create"])
    if existing:
        test.assertEqual(calls[1][2], existing)
    body = calls[1][calls[1].index("--body") + 1]
    test.assertIn("https://example.invalid/fixture/repository/actions/runs/42", body)
    if existing or rc not in VOCABULARY[name]:
        test.assertIn(f"exit {rc or 'none'}", body)
    if not existing:
        test.assertIn(VOCABULARY[name].get(rc, "did not run to a verdict"), body)
    if name == "base-watch":
        test.assertIn("fixture report: workflow X failed", body)


class Reporters(unittest.TestCase):
    def test_guards_and_rendered_reports(self):
        for name in GUARDS:
            text = (ROOT / f".github/workflows/{name}.yml").read_text()
            shell = reporter(text, name)
            # 0 and 3 never reach shell: the exact guard pin above owns that.
            for rc in ("1", "2", "4", "5", "99", ""):
                for existing in ("", "123"):
                    with self.subTest(name=name, rc=rc, existing=existing):
                        assert_report(self, name, shell, rc, existing)

    def test_guard_negative_controls(self):
        for name in GUARDS:
            text = (ROOT / f".github/workflows/{name}.yml").read_text()
            for old, new in (("!cancelled()", "failure()"),
                             (" != '0'", " != '9'"),
                             (" != '3'", " != '9'"),
                             ("== 'schedule'", "== 'workflow_dispatch'")):
                with self.subTest(name=name, mutation=old):
                    changed = text.replace(old, new)
                    self.assertNotEqual(changed, text)
                    with self.assertRaises(AssertionError):
                        reporter(changed, name)

    def test_fallback_negative_controls(self):
        for name in GUARDS:
            shell = reporter((ROOT / f".github/workflows/{name}.yml").read_text(), name)
            # Change each occurrence separately: both creation and recurrence must
            # name an absent output, including when the other route remains right.
            matches = list(re.finditer(re.escape("${RC:-none}"), shell))
            self.assertEqual(len(matches), 2)
            for match in matches:
                changed = shell[:match.start()] + "$RC" + shell[match.end():]
                rejected = False
                for existing in ("", "123"):
                    try:
                        assert_report(self, name, changed, "", existing)
                    except AssertionError:
                        rejected = True
                self.assertTrue(rejected, f"{name}: empty-exit mutation escaped")


if __name__ == "__main__":
    unittest.main()
