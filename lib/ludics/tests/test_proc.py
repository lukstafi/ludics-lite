"""ludics.proc: a tool is the binary on PATH, or a forwarding shell's function through the bridge."""

import os
import shutil
import tempfile
import unittest

from ludics import proc
from ludics.tests.fake import Answer, FakeTool

BASH = shutil.which("bash") or "/bin/bash"


class RunTool(unittest.TestCase):
    def test_the_binary_on_path_is_run_with_the_arguments_verbatim(self) -> None:
        with FakeTool("gh") as gh:
            gh.script(Answer(0, "out\n\n", "warn\n"))
            done = proc.run_tool("gh", ["api", "a b", "", "é"])
            self.assertEqual(done, proc.Completed(0, "out\n\n", "warn\n"))
            self.assertEqual(gh.calls(), [["api", "a b", "", "é"]])

    def test_the_exit_status_is_the_tools(self) -> None:
        with FakeTool("gh") as gh:
            gh.script(Answer(4, "", "gh: Not Found (HTTP 404)\n"))
            self.assertEqual(proc.run_tool("gh", ["api", "x"]).rc, 4)

    def test_a_tool_not_on_path_completes_127_as_the_shell_would(self) -> None:
        done = proc.run_tool("no-such-tool-ludics", [], env={"PATH": tempfile.gettempdir()})
        self.assertEqual(done.rc, 127)
        self.assertIn("command not found", done.stderr)

    def test_substitution_drops_trailing_newlines_only(self) -> None:
        self.assertEqual(proc.substitution("\na\n\nb\n\n"), "\na\n\nb")


class Bridge(unittest.TestCase):
    """The suites define gh as a shell FUNCTION; the forwarder hands its definitions over."""

    def setUp(self) -> None:
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix="ludics-bridge-test."))
        self.state = os.path.join(self.dir, "state")
        with open(self.state, "w", encoding="utf-8") as f:
            f.write(
                "declare -- FIXTURE_WORD=\"from the suite\"\n"
                "gh () {\n"
                "  printf 'bridged %s:' \"$FIXTURE_WORD\"; printf ' [%s]' \"$@\"; echo\n"
                "  echo 'a fixture error' >&2\n"
                "  return 3\n"
                "}\n"
            )

    def tearDown(self) -> None:
        shutil.rmtree(self.dir, ignore_errors=True)

    def bridge_env(self, funcs: str) -> dict[str, str]:
        env = dict(os.environ)
        env.update(
            {proc.BRIDGE_FUNCS: funcs, proc.BRIDGE_STATE: self.state, proc.BRIDGE_SHELL: BASH}
        )
        return env

    def test_a_bridged_tool_is_the_shells_function_with_its_variables(self) -> None:
        done = proc.run_tool("gh", ["a b", "", "c"], env=self.bridge_env("git gh"))
        self.assertEqual(done.rc, 3)
        self.assertEqual(done.stdout, "bridged from the suite: [a b] [] [c]\n")
        self.assertEqual(done.stderr, "a fixture error\n")

    def test_a_tool_not_named_in_the_bridge_is_still_the_binary(self) -> None:
        with FakeTool("gh") as gh:
            gh.script(Answer(0, "binary\n"))
            env = self.bridge_env("git")
            env["PATH"] = os.environ["PATH"]
            self.assertEqual(proc.run_tool("gh", ["x"], env=env).stdout, "binary\n")

    def test_the_states_own_errors_do_not_reach_the_tools_stderr(self) -> None:
        with open(self.state, "a", encoding="utf-8") as f:
            f.write("declare -r BASH_VERSINFO=nope\nreadonly_assignment_fails=1; UID=0\n")
        done = proc.run_tool("gh", [], env=self.bridge_env("gh"))
        self.assertEqual(done.stderr, "a fixture error\n")


if __name__ == "__main__":
    unittest.main()
