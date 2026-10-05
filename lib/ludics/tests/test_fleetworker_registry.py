"""ludics.fleetworker.registry: the shipped registry, imported (main does not run on import)."""

import contextlib
import io
import json
import os
import shutil
import tempfile
import unittest
from typing import Any

from ludics.fleetworker import registry


def request(identity: str, **extra: object) -> dict[str, object]:
    base: dict[str, object] = dict(
        request_id=identity, wave="w", worker=identity, transport="subagent", issue="o/r#1",
        purpose="unit", agent_host="mac", execution_host="mac", repository="o/r",
        requested_revision="origin/main", kind="correctness",
    )
    base.update(extra)
    return base


class Registry(unittest.TestCase):
    def setUp(self) -> None:
        self.root = os.path.realpath(tempfile.mkdtemp(prefix="ludics-registry-test."))

    def tearDown(self) -> None:
        shutil.rmtree(self.root)

    def call(self, action: str, payload: object, boxes: str = "mac", slots: str = "") -> tuple[int, Any, str]:
        out, err = io.StringIO(), io.StringIO()
        argv = ["-", self.root, action, "owner", "token", json.dumps(payload), boxes, slots]
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = registry.run(argv)
        return rc, json.loads(out.getvalue()) if out.getvalue() else None, err.getvalue()

    def test_import_runs_nothing(self) -> None:
        self.assertEqual(registry.LANE_LOCKS, [])

    def test_a_correctness_slot_is_capped_and_a_standing_record_takes_none(self) -> None:
        self.assertEqual(self.call("run", request("a"))[0], 0)
        rc, _, err = self.call("run", request("b"))
        self.assertEqual(rc, 1)
        self.assertIn("EXECUTION REFUSED: box owned by a request=a coordinator=owner (correctness slots 1/1 on mac taken)", err)
        self.assertEqual(self.call("run", request("c", standing=True))[0], 0)
        self.assertEqual(self.call("run", request("b"), slots="mac=2")[0], 0)

    def test_a_refusal_is_one_line_on_stderr_and_exit_1(self) -> None:
        rc, out, err = self.call("reserve", request("bad", kind="other"))
        self.assertEqual((rc, out, err), (1, None, "EXECUTION REFUSED: kind must be correctness or measurement\n"))

    def test_list_validates_the_whole_ledger_before_filtering(self) -> None:
        self.call("reserve", request("a"))
        rc, listed, _ = self.call("list", {"active": True, "compact": True})
        self.assertEqual((rc, [r["request_id"] for r in listed]), (0, ["a"]))
        self.assertNotIn("history", listed[0])
        with open(os.path.join(self.root, "executions", "a.json"), "w") as f:
            f.write("{}")
        self.assertEqual(self.call("list", {"active": True, "compact": True})[0], 1)


if __name__ == "__main__":
    unittest.main()
