"""ludics.fleetworker.execution and gate: the near side's reading of the registry and of a run."""

import contextlib
import io
import json
import unittest
from typing import Any

from ludics.fleetworker import execution
from ludics.fleetworker.config import load_config
from ludics.fleetworker.execution import (
    Payload,
    Refusal,
    Unreadable,
    basename,
    facts_of,
    records_of,
    refresh_host,
    run_verdict,
)
from ludics.fleetworker.gate import integration_rows

SHA = "a" * 40


def record(request_id: str, request: dict[str, object] | None = None, **fields: object) -> dict[str, Any]:
    req: dict[str, object] = {"request_id": request_id, "repository": "example/project", "transport": "coordinator",
                              "kind": "correctness", "integration": True, "execution_host": "testbox"}
    req.update(request or {})
    base: dict[str, Any] = {"request_id": request_id, "state": "concluded", "verdict": "pass",
                            "observed_sha": SHA, "updated_at": "2026-10-05T00:00:00+00:00", "request": req}
    base.update(fields)
    return base


class DispatchedRecord(unittest.TestCase):
    """The refresh after a dispatch reads the execution host off the dispatched record; a record
    it cannot read is a loud REFRESH FAILED line, the dispatch standing (moved here from the shell
    suite, whose case broke the reader by putting a failing jq first on PATH)."""

    def test_an_unreadable_record_is_a_loud_refresh_failure_not_a_silent_skip(self) -> None:
        for text in ("not json", "", '{"request": {}}', '{"request": {"execution_host": ""}}'):
            host = refresh_host(text)
            self.assertIsInstance(host, Unreadable, text)
            assert isinstance(host, Unreadable)
            self.assertTrue(host.line.startswith("REFRESH FAILED: cannot read the execution host from the dispatched record ("))
            self.assertTrue(host.line.endswith("); run fleet-worker.sh refresh <host> by hand"))

    def test_execution_refresh_prints_the_failure_on_stderr_and_runs_nothing(self) -> None:
        cfg = load_config("/nonexistent/issue-wave/scripts/fleet-worker.sh", {}, host="h")
        err, out = io.StringIO(), io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(out):
            execution.execution_refresh(cfg, "not json")
        self.assertIn("REFRESH FAILED: cannot read the execution host", err.getvalue())
        self.assertEqual(out.getvalue(), "")

    def test_a_record_queued_behind_a_window_defers_the_refresh(self) -> None:
        cfg = load_config("/nonexistent/issue-wave/scripts/fleet-worker.sh", {}, host="h")
        text = json.dumps({"state": "suspended", "suspended_by": "win-1", "request": {"execution_host": "rog"}})
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            execution.execution_refresh(cfg, text)
        self.assertEqual(
            err.getvalue(),
            "REFRESH DEFERRED rog: measurement window win-1 is measuring there; run fleet-worker.sh refresh rog once it concludes\n",
        )


class Conclusions(unittest.TestCase):
    def test_test_run_exit_vocabulary(self) -> None:
        for code, want in (("0", "pass"), ("142", "timeout"), ("124", "fail"), ("130", "cancelled"), ("143", "cancelled"), ("1", "fail"), ("00", "fail")):
            self.assertEqual(run_verdict(code, timeout_codes=("142",)), want, code)
        self.assertEqual(run_verdict("124", timeout_codes=("124", "142")), "timeout")

    def test_facts_are_read_by_key_as_sed_reads_them(self) -> None:
        facts = "exit=0\nwt=/w t\nhead=" + SHA + "\nrecord=none"
        self.assertEqual((facts_of(facts, "exit"), facts_of(facts, "wt"), facts_of(facts, "record")), ("0", "/w t", "none"))
        self.assertEqual(facts_of(facts, "nope"), "")

    def test_the_handle_names_the_run_directory_trailing_slash_or_not(self) -> None:
        self.assertEqual(basename("/runs/20260915T201414Z-1"), "20260915T201414Z-1")
        self.assertEqual(basename("/runs/x/"), "x")

    def test_a_refusal_prints_its_text_and_exits_with_its_status(self) -> None:
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(execution.cli.Exit) as caught:
            execution.concluded(Refusal("FROM-RUN UNREACHABLE far: nothing concluded", 4))
        self.assertEqual((caught.exception.rc, out.getvalue()), (4, "FROM-RUN UNREACHABLE far: nothing concluded\n"))
        self.assertEqual(execution.concluded(Payload('{"a":1}')), '{"a":1}')

    def test_a_listing_must_be_an_array_of_objects(self) -> None:
        self.assertEqual(records_of("[]"), [])
        for text in ("{}", "[1]", "nope", ""):
            self.assertIsNone(records_of(text), text)


class IntegrationRecords(unittest.TestCase):
    """ludics-lite#401: only a coordinator's concluded, marked, non-standing correctness run at an
    exact SHA, for the repository compared without case, is a verdict source for the gate."""

    def test_only_marked_integration_runs_of_the_target_are_sources(self) -> None:
        records = [
            record("int-a", request={"repository": "Example/Project"}),
            record("int-b", request={"integration": False}),
            record("int-c", request={"repository": "o/r"}),
            record("int-d", verdict="timeout"),
            record("int-e", state="launching"),
            record("int-f", request={"transport": "subagent"}),
            record("int-g", request={"standing": True}),
            record("int-h", observed_sha="b" * 64),
            record("int-i", verdict="fail"),
        ]
        rows = integration_rows(records, "example/project")
        self.assertEqual(
            rows.split("\n"),
            [f"{SHA}\tpass\tint-a\t2026-10-05T00:00:00+00:00", f"{SHA}\tfail\tint-i\t2026-10-05T00:00:00+00:00"],
        )
        self.assertEqual(integration_rows([], "example/project"), "")


if __name__ == "__main__":
    unittest.main()
