"""ludics.prreview's readers: poll, rounds, status, and the jq semantics they read feeds with.

The shell suites (test-pr-review-status.sh, -rounds.sh, -watch.sh) are the conformance suite;
these pin the logic underneath them directly, with gh replaced by a table of answers.
"""

import contextlib
import io
import json
import time
import unittest
from collections.abc import Callable, Sequence

from ludics import proc
from ludics.prreview import jqsem as jq
from ludics.prreview import poll, reads, rounds, state
from ludics.prreview.core import GhSession, Json, load_config

REV = "chatgpt-codex-connector"
BOT = REV + "[bot]"
HEAD = "a" * 40


def iso(seconds_ago: float) -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - seconds_ago))


class FakeGh:
    """gh as a table: endpoint -> JSON (or a callable of the args), applying the few --jq filters
    the readers send the way gh would."""

    def __init__(self, answers: dict[str, Json | Callable[[Sequence[str]], Json]]) -> None:
        self.answers = answers
        self.calls: list[str] = []
        self.down: set[str] = set()

    def __call__(self, name: str, args: Sequence[str]) -> proc.Completed:
        assert name == "gh" and args[0] == "api"
        endpoint = next(a for a in args[1:] if not a.startswith("-") and "/" in a or a == "graphql")
        self.calls.append(endpoint)
        if endpoint in self.down:
            return proc.Completed(1, "", "gh: HTTP 503: No server is currently available\n")
        answer = self.answers.get(endpoint)
        if answer is None:
            return proc.Completed(1, "", "gh: Not Found (HTTP 404)\n")
        value = answer(args) if callable(answer) else answer
        if "--jq" in args:
            return proc.Completed(0, self._filter(args[args.index("--jq") + 1], value), "")
        return proc.Completed(0, json.dumps(value) + "\n", "")

    @staticmethod
    def _filter(expr: str, value: Json) -> str:
        if expr == reads.HEAD_JQ:
            fields = [jq.text(jq.alt(jq.path(value, *p), "-")) for p in (("head", "sha"),
                      ("mergeable_state",), ("created_at",))]
            return jq.tsv(fields) + "\n"
        if expr == ".commit.committer.date":
            return jq.text(jq.path(value, "commit", "committer", "date")) + "\n"
        if expr == ".data.repository.pullRequest.reviewThreads":
            return json.dumps(jq.path(value, "data", "repository", "pullRequest", "reviewThreads")) + "\n"
        raise AssertionError(f"unexpected --jq {expr}")


def session(gh: FakeGh, **env: str) -> GhSession:
    base = {"REPO": "o/r", "SHIP_PR_API_ATTEMPTS": "1", "SHIP_PR_API_BACKOFF": "0"}
    base.update(env)
    return GhSession(load_config(base), run=gh, sleep=lambda _s: None)


def feeds(
    *,
    reactions: Sequence[Json] | None = None,
    comments: Sequence[Json] | None = None,
    reviews: Sequence[Json] | None = None,
    inline: Sequence[Json] | None = None,
    review_comments: Sequence[Json] | None = None,
    head: str = HEAD,
    mstate: str = "clean",
    created: str = "2026-09-01T00:00:00Z",
    head_at: str = "2026-09-01T00:00:00Z",
    threads: Sequence[Json] | None = None,
) -> FakeGh:
    answers: dict[str, Json | Callable[[Sequence[str]], Json]] = {
        "repos/o/r/issues/7/reactions?per_page=100": list(reactions or []),
        "repos/o/r/issues/7/comments?per_page=100": list(comments or []),
        "repos/o/r/pulls/7/reviews?per_page=100": list(reviews or []),
        "repos/o/r/pulls/7/comments?per_page=100": list(inline or []),
        "repos/o/r/pulls/7": {"head": {"sha": head}, "mergeable_state": mstate, "created_at": created},
        f"repos/o/r/commits/{head}": {"commit": {"committer": {"date": head_at}}},
        "graphql": {"data": {"repository": {"pullRequest": {"reviewThreads": {
            "totalCount": len(threads or []), "pageInfo": {"hasNextPage": False, "endCursor": "c"},
            "nodes": list(threads or [])}}}}},
    }
    gh = FakeGh(answers)
    for rid in range(1, 1000):
        gh.answers[f"repos/o/r/pulls/7/reviews/{rid}/comments?per_page=100"] = list(review_comments or [])
    return gh


def reaction(content: str, at: str) -> Json:
    return {"user": {"login": BOT}, "content": content, "created_at": at}


def review(
    rid: int, sha: str, at: str, body: str = "findings", st: str = "COMMENTED"
) -> dict[str, Json]:
    return {"id": rid, "user": {"login": BOT}, "state": st, "commit_id": sha,
            "submitted_at": at, "body": body}


def comment(cid: int, at: str, body: str, login: str = BOT) -> dict[str, Json]:
    return {"id": cid, "user": {"login": login}, "created_at": at, "updated_at": at, "body": body}


def run_state(gh: FakeGh, nudge_after: int | None = None) -> str:
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        return state.status_state(session(gh), "o/r", "7", 2400, nudge_after)


# --- jq semantics ---------------------------------------------------------------------------------


class JqSemantics(unittest.TestCase):
    def test_order_is_jqs(self) -> None:
        values: list[Json] = [{"a": 1}, [1], "a", 2, True, False, None]
        self.assertEqual(jq.sort_by(values, lambda v: v), [None, False, True, 2, "a", [1], {"a": 1}])
        self.assertFalse(jq.eq(1, True))
        self.assertTrue(jq.eq(1, 1.0))
        self.assertTrue(jq.gt("1", 5))

    def test_max_by_keeps_the_last_of_equals_and_none_of_nothing(self) -> None:
        items = [{"k": 1, "n": "first"}, {"k": 1, "n": "second"}]
        best = jq.max_by(items, lambda i: i["k"])
        self.assertEqual(best, {"k": 1, "n": "second"})
        nothing: list[Json] = []
        self.assertIsNone(jq.max_by(nothing, lambda i: i))

    def test_indexing_refuses_what_jq_refuses(self) -> None:
        self.assertIsNone(jq.idx(None, "a"))
        with self.assertRaises(jq.JqError):
            jq.idx("s", "a")
        with self.assertRaises(jq.JqError):
            jq.startswith(5, "x")
        with self.assertRaises(jq.JqError):
            jq.test(7, jq.NONSPACE)
        with self.assertRaises(jq.JqError):
            jq.head_slice(7, 7)
        self.assertEqual(jq.head_slice("héllo wörld", 3), "hél")

    def test_fromdateiso8601_is_strptimes(self) -> None:
        self.assertEqual(jq.fromdateiso8601("2026-09-01T00:00:00Z"), 1788220800)
        self.assertEqual(jq.fromdateiso8601("2026-9-1T0:0:0Z"), 1788220800)
        for bad in ("2026-09-01T00:00:00.5Z", " 2026-09-01T00:00:00Z", "2026-09-01T00:00:00Zx",
                    "2026-13-01T00:00:00Z", "garbage"):
            with self.assertRaises(jq.JqError, msg=bad):
                jq.fromdateiso8601(bad)

    def test_bash_read(self) -> None:
        self.assertEqual(jq.bash_read("a\t\tb\tc d\t", 3), ["a", "b", "c d"])
        self.assertEqual(jq.bash_read("", 3), ["", "", ""])
        self.assertEqual(jq.bash_read_delim("||0|", 4, "|"), ["", "", "0", ""])
        self.assertEqual(jq.bash_read_delim("x|y|", 2, "|"), ["x", "y"])
        self.assertEqual(jq.bash_read_delim("x|y|z|", 2, "|"), ["x", "y|z|"])

    def test_split_of_empty_is_no_parts(self) -> None:
        self.assertEqual(jq.split("", ","), [])
        self.assertEqual(jq.split("a,b", ","), ["a", "b"])

    def test_space_is_unicode_white_space_not_pythons(self) -> None:
        self.assertTrue(jq.test("\x1c", jq.NONSPACE))
        self.assertFalse(jq.test("\xa0  \t", jq.NONSPACE))


# --- poll -----------------------------------------------------------------------------------------


class PollItems(unittest.TestCase):
    def test_threads_at_one_anchor_fold_with_every_distinct_body(self) -> None:
        a: dict[str, Json] = {"id": 900, "path": "a.sh", "line": 3, "body": "one",
                              "user": {"login": BOT}, "original_commit_id": HEAD}
        b: Json = {**a, "id": 901, "body": "two"}
        c: Json = {**a, "id": 902, "body": "one"}
        d: Json = {**a, "id": 903, "line": 4}
        folded = poll.fold_inline([a, d, b, c])
        self.assertEqual([poll.thread_list(f) for f in folded], ["900+901+902", "903"])
        self.assertEqual(poll.body_block(folded[0]), "[thread 900]\none\n[thread 901]\ntwo")
        self.assertEqual(poll.dupe_note(folded[0]),
                         " (3 threads at one location, 2 findings as written; one reply answers all)")
        self.assertEqual(poll.dupe_note(folded[1]), "")

    def test_the_anchor_line(self) -> None:
        self.assertEqual(poll.item_line({"line": 5, "start_line": 3}), "3-5")
        self.assertEqual(poll.item_line({"position": 12}), "@12")
        self.assertEqual(poll.item_line({}), "?")
        self.assertEqual(poll.item_side({"side": "LEFT", "start_side": "RIGHT"}),
                         " side=LEFT start_side=RIGHT")
        self.assertEqual(poll.item_was({"line": 7, "original_line": 3}), " was=3")
        self.assertEqual(poll.item_was({"position": 9, "original_position": 5}), " was=@5")
        self.assertEqual(poll.item_was({"position": 5, "original_position": 5}), "")

    def test_short_and_stamps(self) -> None:
        self.assertEqual(poll.short(None), "-")
        self.assertEqual(poll.short(""), "-")
        self.assertEqual(poll.short(HEAD), "aaaaaaa")
        body = "quotes `bbbbbbb`\n**Reviewed commit:** `ccccccc`\n**Reviewed commit:** `ddddddd`"
        self.assertEqual(poll.item_stamp({"body": body}, reads.REVIEWED_COMMIT), "ddddddd")

    def test_the_about_codex_block_folds_only_as_the_body_s_end(self) -> None:
        block = poll.CODEX_ABOUT_OPEN + "\ninterior\n</details>\n  "
        self.assertEqual(poll.fold_codex_about("findings\n" + block),
                         "findings\n" + poll.CODEX_ABOUT_FOLDED)
        self.assertEqual(poll.fold_codex_about("x" + block + "more"), "x" + block + "more")
        self.assertEqual(poll.fold_codex_about(None), "")


class PollRound(unittest.TestCase):
    def run_poll(self, gh: FakeGh, mark: str = "") -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = poll.poll_round(session(gh), "o/r", "7", mark)
        return rc, out.getvalue(), err.getvalue()

    def test_a_round(self) -> None:
        gh = feeds(
            inline=[{"id": 900, "path": "a.sh", "line": 3, "body": "a finding",
                     "user": {"login": BOT}, "original_commit_id": HEAD}],
            comments=[comment(700, "2026-09-01T00:00:00Z", "summary\n**Reviewed commit:** `aaaaaaa`"),
                      comment(701, "2026-09-01T00:00:00Z", "<!-- codex-pull-request-review-summary -->")],
            reviews=[review(800, HEAD, "2026-09-01T00:00:00Z")],
        )
        rc, out, _ = self.run_poll(gh)
        self.assertEqual(rc, 0)
        self.assertIn(f"--- inline id=900 a.sh:3 commit=aaaaaaa by {BOT}\na finding", out)
        self.assertIn(f"--- summary id=700 commit=aaaaaaa by {BOT}", out)
        self.assertNotIn("id=701", out)
        self.assertIn(f"items: inline:900:aaaaaaa:{BOT}:- summary:700:aaaaaaa:{BOT}:- "
                      f"review:800:aaaaaaa:{BOT}:COMMENTED", out)
        self.assertTrue(out.endswith("watermark: 900,701,800\n"))

    def test_a_shape_the_rendering_cannot_take_fails_after_what_was_printed(self) -> None:
        gh = feeds(
            inline=[{"id": 900, "body": "printed first", "user": {"login": BOT},
                     "original_commit_id": HEAD}],
            reviews=[{**review(800, HEAD, "2026-09-01T00:00:00Z"), "commit_id": 7}],
        )
        rc, out, _ = self.run_poll(gh)
        self.assertEqual(rc, 4)
        self.assertIn("printed first", out)
        self.assertNotIn("watermark:", out)

    def test_a_feed_that_did_not_answer_is_exit_3(self) -> None:
        gh = feeds()
        gh.down.add("repos/o/r/issues/7/comments?per_page=100")
        rc, out, err = self.run_poll(gh)
        self.assertEqual((rc, out), (3, ""))
        self.assertIn("feed(s): summary after 1 attempts each", err)


# --- rounds ---------------------------------------------------------------------------------------


class Rounds(unittest.TestCase):
    def count(self, reviews: Sequence[Json], comments: Sequence[Json] | None = None, gap: int = 900,
              icap: int | None = None, rcap: int | None = None) -> str:
        gh = feeds(reviews=reviews, comments=comments)
        return rounds.review_rounds(session(gh, SHIP_PR_ROUND_GAP=str(gap)), "o/r", "7", icap, rcap)

    def test_bursts_by_head_and_gap(self) -> None:
        r = self.count([
            review(1, "aaaa", "2026-09-01T10:00:00Z"),
            review(2, "aaaa", "2026-09-01T10:00:03Z"),
            review(3, "aaaa", "2026-09-01T10:40:00Z"),
            review(4, "bbbb", "2026-09-01T11:00:00Z", st="CHANGES_REQUESTED"),
            review(5, "cccc", "2026-09-01T12:00:00Z", st="APPROVED"),
        ])
        self.assertEqual(r, f"3|3 round(s) of {REV} findings over 2 head(s)")

    def test_a_comment_quoting_a_truncated_sha_joins_its_burst(self) -> None:
        r = self.count([review(1, "aaaa1111", "2026-09-01T10:00:00Z")],
                       [comment(9, "2026-09-01T10:00:05Z", "**Reviewed commit:** `aaaa111`")])
        self.assertTrue(r.startswith("1|"))

    def test_caps_count_as_of_a_watermark(self) -> None:
        reviews = [review(1, "aaaa", "2026-09-01T10:00:00Z"), review(2, "bbbb", "2026-09-01T11:00:00Z")]
        self.assertTrue(self.count(reviews, rcap=1).startswith("1|"))
        self.assertTrue(self.count(reviews).startswith("2|"))

    def test_a_date_that_does_not_parse_is_unknown(self) -> None:
        self.assertEqual(self.count([review(1, "aaaa", "yesterday")]),
                         "unknown|the reviews feed did not parse")

    def test_rounds_line(self) -> None:
        self.assertEqual(rounds.rounds_line("2|d", 12), ("review rounds with findings: 2 of 12 (d)", 0))
        self.assertEqual(rounds.rounds_line("2|d", None)[1], 0)
        self.assertEqual(rounds.rounds_line("13|d", 12)[1], 1)
        self.assertEqual(rounds.rounds_line("unknown|why", 12)[1], 3)
        self.assertEqual(rounds.count_token("unknown|why"), "unknown")
        self.assertEqual(rounds.count_token("4|x"), "4")


# --- status ---------------------------------------------------------------------------------------


class StatusState(unittest.TestCase):
    def test_idle_on_a_review_of_the_head(self) -> None:
        line = run_state(feeds(reviews=[review(5, HEAD, "2026-09-01T00:00:00Z")]))
        self.assertTrue(line.startswith("idle|"), line)
        self.assertEqual(state.state_merge(line), "clean")

    def test_a_thumbs_up_is_an_approval_and_the_gate_reads_the_threads(self) -> None:
        gh = feeds(reactions=[reaction("+1", iso(30))], head_at=iso(3600),
                   threads=[{"isResolved": False, "path": "a b.sh",
                             "comments": {"nodes": [{"fullDatabaseId": "4095735704",
                                                     "author": {"login": "codex"}}]}}])
        line = run_state(gh)
        self.assertEqual(line, f"approved|-|clean|👍 from {REV}")
        gated = state.approval_gate(session(gh), "o/r", "7", line, 50)
        self.assertEqual(gated, f"unresolved|-|clean|1|👍 from {REV}|4095735704 by codex on a\\ b.sh")

    def test_a_live_eyes_is_reviewing_and_an_old_one_stalled(self) -> None:
        self.assertTrue(run_state(feeds(reactions=[reaction("eyes", iso(60))])).startswith("reviewing|"))
        self.assertTrue(run_state(feeds(reactions=[reaction("eyes", iso(9999))])).startswith("stalled|"))

    def test_a_feed_that_did_not_answer_is_unknown(self) -> None:
        gh = feeds()
        gh.down.add("repos/o/r/issues/7/reactions?per_page=100")
        self.assertTrue(run_state(gh).startswith("unknown|-|-|the reactions API did not answer (gh: HTTP 503"))

    def test_a_shape_a_read_cannot_take_is_unknown(self) -> None:
        line = run_state(feeds(comments=[{**comment(1, "2026-09-01T00:00:00Z", "x"), "body": 7}]))
        # The head is read after the feeds, so no mergeability rides on this line yet.
        self.assertEqual(line, "unknown|-|-|the comments feed did not parse")

    def test_a_pending_request_is_nudged(self) -> None:
        line = run_state(feeds(comments=[comment(9, iso(30), "@codex review", login="me")]), 1)
        self.assertTrue(line.startswith("nudged|"), line)
        self.assertEqual(state.status_line(line, "o/r", "7").split(" — ")[0], "review EXPECTED but not started")

    def test_the_initialization_failure_names_its_head(self) -> None:
        body = ("Codex Review: Something went wrong. Try again later by commenting “@codex review”.\n\n"
                f"```\nProvided git ref {HEAD} does not exist\n```")
        line = run_state(feeds(comments=[comment(1, "2026-09-01T01:00:00Z", body)]))
        self.assertTrue(line.startswith("failed|"), line)
        self.assertEqual(state.state_detail(line).split("|")[:2], ["aaaaaaa", "git"])


class StatusLine(unittest.TestCase):
    def test_tokens(self) -> None:
        self.assertEqual(state.status_line("approved|-|dirty|x", "o/r", "7"),
                         "approved (x); " + state.conflict_note("dirty", "o/r", "7"))
        self.assertIn("the next move is yours", state.status_line("idle|5|clean|d", "o/r", "7"))
        self.assertNotIn("the next move is yours", state.status_line("idle|5|draft|d", "o/r", "7"))
        self.assertIn("gh pr ready <pr> --repo o/r", state.status_line("idle|5|draft|d", "o/r", ""))
        self.assertEqual(state.status_line("weird|-|-|", "o/r", "7"),
                         "unrecognised state 'weird' — treat as unknown and retry")
        self.assertIn("running 2m", state.status_line("reviewing|125|clean|d", "o/r", "7"))

    def test_parsers_keep_pipes_in_the_detail(self) -> None:
        line = "unknown|-|-|gh: 502 | Bad Gateway"
        self.assertEqual((state.state_tok(line), state.state_age(line), state.state_merge(line),
                          state.state_detail(line)), ("unknown", "-", "-", "gh: 502 | Bad Gateway"))

    def test_threads_named_names_ten(self) -> None:
        rows = [jq.tsv([str(i), "u", "p"]) for i in range(12)]
        n, shown = state.threads_named(rows)
        self.assertEqual(n, 12)
        self.assertTrue(shown.endswith("9 by u on p, and 2 more"))


if __name__ == "__main__":
    unittest.main()
