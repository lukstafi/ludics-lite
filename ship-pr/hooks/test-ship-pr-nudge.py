"""Offline contract tests: real Git, mocked GitHub, isolated hook stamps/task files."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

HOOK = Path(__file__).with_name("ship-pr-nudge.sh").resolve()


class NudgeTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="ship-nudge-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.repo = self.root / 'repo "quoted"'
        self.repo.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # A controlled PATH also exercises the Python fallback without uninstalling jq.
        for name in ("git", "python3", "cat", "shasum", "cut", "mkdir", "pwd",
                     "grep", "tail", "find"):
            path = shutil.which(name)
            if path:
                (self.bin / name).symlink_to(path)
        gh = self.bin / "gh"
        gh.write_text('#!/bin/bash\n'
                      'echo called >> "$TMPDIR/gh-calls"\n'
                      '[ "$1 $2" = "pr list" ] || exit 9\n'
                      '[ "$N_PR" = error ] && exit 1\n'
                      'printf "%s\\n" "$N_PR"\n')
        gh.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin), TMPDIR=str(self.root), N_PR="0",
                        GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.org",
                        GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.org")
        self.git("init", "-q", "-b", "main")
        self.file = self.repo / "example.txt"
        self.file.write_text("base\n")
        self.git("add", ".")
        self.git("commit", "-qm", "base")
        self.git("update-ref", "refs/remotes/origin/main", "HEAD")
        self.git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
        self.git("switch", "-qc", "topic")
        self.file.write_text("exploring\n")
        self.payload = dict(cwd=str(self.repo), session_id="session", stop_hook_active=False)

    def git(self, *args):
        return subprocess.run(["git", *args], cwd=self.repo, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def run_hook(self, expected, payload=None):
        result = subprocess.run(["/bin/bash", str(HOOK)], env=self.env,
                                input=json.dumps(self.payload if payload is None else payload),
                                capture_output=True, text=True)
        self.assertEqual(result.returncode, expected, result.stderr)
        self.assertEqual(result.stdout, "")
        if expected == 2:
            self.assertIn("If the goal is finished", result.stderr)
        else:
            self.assertEqual(result.stderr, "")
        return result

    def test_coarse_stamp_preserves_incremental_exploration(self):
        self.run_hook(2)
        self.file.write_text("more exploration, same dirty path\n")
        self.run_hook(0)
        self.git("add", ".")
        self.git("commit", "-qm", "checkpoint")
        self.run_hook(2)

    def test_codex_payload_and_loop_guard(self):
        self.payload["turn_id"] = "turn-1"
        self.payload["stop_hook_active"] = True
        self.run_hook(0)
        self.payload["stop_hook_active"] = False
        self.run_hook(2)
        self.payload["turn_id"] = "turn-2"
        self.run_hook(0)

    def test_any_pr_stays_exempt(self):
        # --state all makes OPEN, CLOSED, and MERGED equivalent by design.
        self.env["N_PR"] = "1"
        self.run_hook(0)
        self.env["N_PR"] = "0"
        self.run_hook(0)  # The same repository state remains stamped.

    def test_lookup_failure_does_not_claim_absence_or_stamp(self):
        self.env["N_PR"] = "error"
        self.run_hook(0)
        self.env["N_PR"] = "0"
        self.run_hook(2)

    def test_missing_gh_does_not_stamp(self):
        gh = self.bin / "gh"
        gh.rename(self.bin / "gh.saved")
        self.run_hook(0)
        (self.bin / "gh.saved").rename(gh)
        self.run_hook(2)

    def test_default_branch_and_clean_topic_stay_quiet(self):
        self.git("switch", "-q", "main")
        self.run_hook(0)
        self.git("switch", "-q", "topic")
        self.git("restore", "example.txt")
        self.run_hook(0)
        self.assertFalse((self.root / "gh-calls").exists())

    def test_claude_running_task_defers_without_stamp(self):
        tasks = self.root / "claude-test" / "project" / "session" / "tasks"
        tasks.mkdir(parents=True)
        output = tasks / "build.output"
        output.write_text("building\n")
        self.run_hook(0)
        output.write_text("[exited with code 0]\n")
        self.run_hook(2)

    def test_codex_ignores_claude_task_files(self):
        tasks = self.root / "claude-test" / "project" / "session" / "tasks"
        tasks.mkdir(parents=True)
        (tasks / "build.output").write_text("building\n")
        self.payload["turn_id"] = "turn-1"
        self.run_hook(2)

    def test_question_tools_defer_without_stamp(self):
        transcript = self.root / "transcript.jsonl"
        self.payload["transcript_path"] = str(transcript)
        for name in ("AskUserQuestion", "request_user_input", "request_user_input_async"):
            transcript.write_text(json.dumps(dict(name=name)) + "\n")
            self.run_hook(0)
        transcript.write_text("{}\n")
        self.run_hook(2)

    def test_invalid_input_and_missing_session_stay_quiet(self):
        self.run_hook(0, [])
        self.payload.pop("session_id")
        self.run_hook(0)

    def test_jq_parser_also_handles_escaped_paths(self):
        jq = shutil.which("jq")
        if not jq:
            self.skipTest("jq not installed; Python fallback covered by other tests")
        (self.bin / "jq").symlink_to(jq)
        self.run_hook(2)

    def test_sessions_are_separate_and_ids_are_not_paths(self):
        self.payload["session_id"] = "../../outside"
        self.run_hook(2)
        self.run_hook(0)
        self.payload["session_id"] = "other-session"
        self.run_hook(2)
        self.assertEqual(len(list((self.root / "ship-pr-nudge").iterdir())), 2)


if __name__ == "__main__":
    unittest.main()
