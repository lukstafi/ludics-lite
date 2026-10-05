"""ludics.fleetworker's worker, preflight and supervision near sides: the readings the shell made of
its own text (``${pf#*skills=* }``, the usage block, jq's @tsv and @uri), the slots report, and the
far side's Python probe in scripts/py's order."""

import calendar
import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

from ludics.fleetworker import farside
from ludics.fleetworker.__main__ import usage_text
from ludics.fleetworker.config import load_config
from ludics.fleetworker.gate import uri
from ludics.fleetworker.preflight import siblings_of, slots_report
from ludics.fleetworker.supervision import each, head_age, length, load_line, pr_rows, wave_issues
from ludics.fleetworker.workers import feeder_wait_ok, preflight_note, valid_name
from ludics.prreview.core import JsonStreamError, json_docs, json_stream
from ludics.prreview.jqsem import JqError, jstr, tojson

SCRIPT = "/repo/issue-wave/scripts/fleet-worker.sh"
ROSTER = "mac-studio rog-nv-linux minix-amd-linux tuf-amd-linux"


class Names(unittest.TestCase):
    def test_a_worker_name_is_the_safe_set_without_a_leading_dot(self) -> None:
        for name in ("w1", "a.b", "claude-issue_7"):
            self.assertTrue(valid_name(name), name)
        for name in ("", ".", "..", ".triage", "a b", "../escape", "a/b", "é"):
            self.assertFalse(valid_name(name), name)

    def test_the_feeder_wait_is_a_positive_whole_number_without_a_leading_zero(self) -> None:
        for value, want in (("10", True), ("1", True), ("0", False), ("01", False), ("1s", False)):
            cfg = load_config(SCRIPT, {"FLEET_FEEDER_WAIT": value}, host="h")
            self.assertEqual(feeder_wait_ok(cfg), want, value)
        # `${FLEET_FEEDER_WAIT:-10}`: empty is the default.
        self.assertTrue(feeder_wait_ok(load_config(SCRIPT, {"FLEET_FEEDER_WAIT": ""}, host="h")))


class Readings(unittest.TestCase):
    def test_the_preflight_note_is_the_ok_line_past_its_skills_field(self) -> None:
        line = "PREFLIGHT OK rog skills=abcdef123 (cross-box unreachable, asleep or off the network: tuf)"
        self.assertEqual(preflight_note(line), "(cross-box unreachable, asleep or off the network: tuf)")
        self.assertEqual(preflight_note("no skills field here"), "no skills field here")
        self.assertEqual(preflight_note("PREFLIGHT OK rog skills=abc"), "PREFLIGHT OK rog skills=abc")

    def test_usage_is_the_header_block_from_usage_through_exit(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".sh", delete=False) as f:
            f.write("#!/usr/bin/env bash\n# intro\n# Usage:\n#   x.sh a\n#bare\n# Exit: 0 ok\n# after\nbody\n")
        try:
            self.assertEqual(usage_text(f.name), "Usage:\n  x.sh a\nbare\nExit: 0 ok\n")
        finally:
            os.unlink(f.name)
        self.assertEqual(usage_text("/nonexistent/fleet-worker.sh"), "")

    def test_uri_is_jqs(self) -> None:
        self.assertEqual(uri("claude/issue-7"), "claude%2Fissue-7")
        self.assertEqual(uri("a b~c_d.e-f"), "a%20b~c_d.e-f")
        self.assertEqual(uri("é"), "%C3%A9")

    def test_siblings_leave_out_the_box_and_every_spelling_of_this_one(self) -> None:
        cfg = load_config(SCRIPT, {"FLEET_BOXES": "mac-studio rog tuf", "FLEET_LOCAL_BOX": "mac-studio"}, host="h")
        self.assertEqual(siblings_of(cfg, "rog"), "mac-studio tuf")
        self.assertEqual(siblings_of(cfg, "local"), "rog tuf")
        self.assertEqual(siblings_of(cfg, "mac-studio"), "rog tuf")


def report(env: dict[str, str]) -> tuple[str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        slots_report(load_config(SCRIPT, env, host="h"))
    return out.getvalue(), err.getvalue()


class SlotsReport(unittest.TestCase):
    def test_the_site_default_is_printed_with_its_tokens_and_no_warning(self) -> None:
        out, err = report({"FLEET_BOXES": ROSTER})
        self.assertEqual(out, "PREFLIGHT SLOTS mac-studio=6 rog-nv-linux=4(gpu=2) minix-amd-linux=4 tuf-amd-linux=3 (site default)\n")
        self.assertEqual(err, "")

    def test_an_empty_spec_under_the_default_roster_warns_box_by_box(self) -> None:
        out, err = report({"FLEET_BOXES": ROSTER, "FLEET_BOX_CORRECTNESS_SLOTS": ""})
        self.assertTrue(out.endswith("(FLEET_BOX_CORRECTNESS_SLOTS)\n"), out)
        warned = [line.split(" does not name ")[1].split(",")[0] for line in err.splitlines()]
        self.assertEqual(warned, ROSTER.split())

    def test_the_spec_spelling_of_a_count_is_kept(self) -> None:
        out, _ = report({"FLEET_BOXES": "a b", "FLEET_BOX_CORRECTNESS_SLOTS": "a=007"})
        self.assertEqual(out, "PREFLIGHT SLOTS a=007 b=1 (FLEET_BOX_CORRECTNESS_SLOTS)\n")

    def test_a_malformed_spec_is_one_warning_and_no_slots_line(self) -> None:
        out, err = report({"FLEET_BOXES": "a b", "FLEET_BOX_GPU_TOKENS": "stale=1"})
        self.assertEqual(out, "")
        self.assertEqual(err, "PREFLIGHT SLOTS WARNING: FLEET_BOX_GPU_TOKENS names stale, which is not in FLEET_BOXES; every `execution slot` refuses\n")


class Prs(unittest.TestCase):
    def test_rows_are_in_number_order_with_placeholders_and_tsv_escapes(self) -> None:
        listing = json.loads(
            '[{"number": 12, "title": "a\\tb", "headRefName": "x", "headRefOid": "c12", "createdAt": "t", "isDraft": true},'
            ' {"number": 7, "title": "", "headRefName": "y", "headRefOid": "c7", "createdAt": "t", "isDraft": false}]'
        )
        self.assertEqual(
            pr_rows(listing, None),
            [["7", "c7", "t", "-", "y", "-"], ["12", "c12", "t", "draft", "x", "a\\tb"]],
        )

    def test_a_wave_keeps_the_prs_closing_one_of_its_issues(self) -> None:
        ref = {"number": 7, "repository": {"name": "r", "owner": {"login": "o"}}}
        listing = json.loads(json.dumps([{"number": 1, "closingIssuesReferences": [ref]}, {"number": 2, "closingIssuesReferences": None}]))
        self.assertEqual([row[0] for row in pr_rows(listing, ["o/r#7"])], ["1"])
        self.assertEqual([row[0] for row in pr_rows(listing, ["o/r#8"])], [])
        records = json.loads('[{"request": {"wave": "w", "issue": "o/r#7"}}, {"request": {"wave": "w", "issue": "o/r#7"}}, {"request": {"wave": "v", "issue": "x"}}]')
        self.assertEqual(wave_issues(records, "w"), ["o/r#7"])

    def test_a_list_that_is_not_an_array_is_jqs_error(self) -> None:
        with self.assertRaises(JqError):
            pr_rows({"number": 1}, None)

    def test_head_age_reads_the_newer_date_and_formats_it_as_the_shell_did(self) -> None:
        epoch = calendar.timegm((2027, 1, 15, 8, 0, 0, 0, 0, 0)) + 0.5  # jq's `now`, a float
        self.assertEqual(head_age("2027-01-15T07:59:00Z", "", epoch), "1m")
        self.assertEqual(head_age("2027-01-15T06:58:00Z", "2027-01-15T05:00:00Z", epoch), "1h2m")
        self.assertEqual(head_age("not a date", "2027-01-12T05:00:00Z", epoch), "3d3h")
        self.assertEqual(head_age("", "", epoch), "?")
        # A date jq cannot read fails the whole program, and one in the future is no age.
        self.assertEqual(head_age("2027-13-01T00:00:00Z", "2027-01-15T07:59:00Z", epoch), "?")
        self.assertEqual(head_age("2028-01-01T00:00:00Z", "", epoch), "?")


class Load(unittest.TestCase):
    def test_a_line_prints_jqs_interpolations_and_defaults(self) -> None:
        endpoint = json.loads('{"kind": "unix", "ok": true, "avg": {"m5": {"cpu_pct": 12.5}}, "data": {"sessions": {"claude": [1, 2]}}}')
        self.assertEqual(
            load_line({"name": "mac"}, "studio", endpoint),
            "mac\tstudio\tok=true\tcpu5=12.5%\tgpu5=-%\tdune=?\tclaude=2\tcodex=0\tgpu=-",
        )

    def test_numbers_print_as_the_payload_spelled_them(self) -> None:
        # jq 1.8 prints a number it did not compute with as its literal, in decNumber's spelling.
        (doc,) = json_docs('[1E+2, 1e2, 3.50, -0, 1.5e3, 0.0000001, 1E1000, 12.0, 7, -0.0]', literals=True)
        self.assertEqual([jstr(n) for n in each(doc)], ["1E+2", "1E+2", "3.50", "-0", "1.5E+3", "1E-7", "1E+1000", "12.0", "7", "-0.0"])
        self.assertEqual(tojson(doc), "[1E+2,1E+2,3.50,-0,1.5E+3,1E-7,1E+1000,12.0,7,-0.0]")
        # length keeps a literal, its sign dropped, as jq 1.8's does; the default reading (every
        # other port's) is unchanged.
        (signed,) = json_docs("[-3.50, -0, -0.0, 1.10, -100000000000000000000001]", literals=True)
        self.assertEqual([jstr(length(n)) for n in each(signed)], ["3.50", "0", "0.0", "1.10", "100000000000000000000001"])
        self.assertEqual(jstr(next(json_docs("1E+2"))), "100.0")
        (nested,) = json_docs('{"a": [3.50, {"b": -0}], "c": "\u00e9"}', literals=True)
        self.assertEqual(tojson(nested), '{"a":[3.50,{"b":-0}],"c":"\u00e9"}')

    def test_documents_before_a_cut_are_read_before_it_refuses(self) -> None:
        docs = json_docs('{"a": 1} [2] {"b":', literals=True)
        self.assertEqual(next(docs), {"a": 1})
        self.assertEqual(next(docs), [2])
        with self.assertRaises(JsonStreamError):
            next(docs)
        self.assertIsNone(json_stream('{"a": 1} {"b":'))


@unittest.skipIf(shutil.which("bash") is None, "no bash")
class FleetPython(unittest.TestCase):
    """farside.FLEET_PYTHON: the box's first Python >= 3.12 in scripts/py's order, or what each
    candidate was."""

    def probe(self, candidates: list[str]) -> tuple[int, str]:
        env = {**os.environ, "LUDICS_PY_CANDIDATES": "\n".join(candidates)}
        done = subprocess.run(
            ["bash", "-c", farside.FLEET_PYTHON + "fleet_python"], env=env, capture_output=True, text=True, check=False
        )
        return done.returncode, done.stdout

    def test_the_first_qualifying_candidate_wins_and_the_rest_is_named(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            old = os.path.join(d, "old")
            with open(old, "w") as f:
                f.write("#!/bin/sh\necho 3.9.6; exit 1\n")
            junk = os.path.join(d, "junk")
            with open(junk, "w") as f:
                f.write("#!/bin/sh\nexit 3\n")
            os.chmod(old, 0o755)
            os.chmod(junk, 0o755)
            missing = os.path.join(d, "missing")
            rc, out = self.probe([missing, old, junk])
            self.assertEqual(rc, 1)
            self.assertEqual(out, f"tried {missing}: absent, {old}: Python 3.9.6, {junk}: not Python (exit 3)")
            rc, out = self.probe([old, sys.executable])
            self.assertEqual((rc, out), (0, sys.executable))


if __name__ == "__main__":
    unittest.main()
