#!/usr/bin/env python3
"""Exercise hostile-runner verdicts using only synthetic scratch suites.

Promotes the wave-20260913-ludics/120-controls.py probes into regression tests.
Requires the same non-C locale as run-pr-review-hostile.sh; accepts its
PR_REVIEW_HOSTILE_LOCALE override. Run with python3, outside the shell-suite glob.
"""

from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


RUNNER = Path(__file__).resolve().with_name("run-pr-review-hostile.sh")


class HostileControls(unittest.TestCase):
    def test_verdicts(self):
        cases = [
            ("clean", "echo PROBE-PASS", 0o755, 0, None),
            ("stderr", "echo tool-error >&2", 0o755, 1, "tool-error"),
            ("hidden leak", 'touch "$TMPDIR/.leak"', 0o755, 1, ".leak"),
            ("dangling link", 'ln -s missing "$TMPDIR/dangling"',
             0o755, 1, "dangling"),
            ("nonzero exit", "exit 7", 0o755, 1, "exit=7"),
            ("lost executable mode", "echo PROBE-PASS", 0o644, 1, "exit=126"),
        ]
        for label, body, mode, expected, diagnostic in cases:
            with self.subTest(label=label), tempfile.TemporaryDirectory(
                prefix="hostile controls "
            ) as directory:
                root = Path(directory)
                runner = root / RUNNER.name
                # Never copy the real fixture suites or invoke the repository runner.
                shutil.copy2(RUNNER, runner)
                suite = root / "test-pr-review-probe.sh"
                suite.write_text("#!/usr/bin/env bash\n" + body + "\n")
                suite.chmod(mode)
                tmp = root / "outer tmp with spaces"
                tmp.mkdir()
                result = subprocess.run(
                    [str(runner)], cwd=root,
                    env=dict(os.environ, TMPDIR=str(tmp)),
                    capture_output=True, text=True, timeout=30,
                )
                output = f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
                self.assertEqual(result.returncode, expected, output)
                self.assertIn("Hostile pass: test-pr-review-probe.sh", result.stdout, output)
                if diagnostic is None:
                    self.assertIn("PROBE-PASS", result.stdout, output)
                    self.assertEqual(result.stderr, "", output)
                else:
                    self.assertIn("FAIL: test-pr-review-probe.sh", result.stderr, output)
                    self.assertIn(diagnostic, result.stderr, output)
                self.assertEqual(list(tmp.iterdir()), [], output)


if __name__ == "__main__":
    unittest.main()
