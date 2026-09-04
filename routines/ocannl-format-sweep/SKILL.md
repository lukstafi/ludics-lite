---
name: ocannl-format-sweep
description: Run OCANNL's quiet-period repo-wide formatting sweep and report the outcome
---

Run OCANNL's automated formatting sweep.

Working directory: /Users/lukstafi/ocannl-staging (the main checkout — not a worktree under .claude/worktrees/).

Use `~/.ocannl-test-runs/format-sweep-scheduled.tsv` as the scheduled run's cross-run ledger. Before
invoking the sweep, create its parent directory and an empty ledger file if either is absent, then read
the ledger's last line (an empty file means there is no previous run). After the run's final outcome is known — including after any repair and retry
in step 3 — append exactly one tab-separated line before reporting:
`<UTC timestamp>\t<outcome key>\t<one-line report>`. Keep the fields themselves on one line and free of
tabs. The outcome key is the stable quoted outcome category from step 2; for "not a quiet period", add
the specific gate reason so two different holders do not count as a repeat. Do not compare volatile
details such as timestamps, SHAs, paths, or the body of a git error.

1. Run `tools/format-sweep.sh` with NO flags — never pass --force on a scheduled run — through the Bash tool in background mode, and act on its completion notification. A sweep that actually proceeds runs the full test suite and can take on the order of 30 minutes; a gated no-op returns in seconds.
2. Interpret the outcome from the script's output:
   - A gate stopped the sweep before it touched anything, and the next scheduled run can simply try again: "not a quiet
     period" (open PRs or active worktrees), "not on master", "working tree not clean", "local commits not on origin/master",
     "a tools/test-run.sh run is active in this checkout", "a tools/test-run.sh run held its lock past the bound", or "another
     format-sweep is running". This is the designed no-op. End with a one-line report. But a no-op only stays benign while it
     CLEARS: each of these describes someone else holding the checkout, and if the previous scheduled run reported the same
     message, nobody is letting go and the sweep is silently disabled rather than politely waiting. Say so in the report when
     that happens — a repeat is worth a person's attention even though a single occurrence is not. Compare the current
     outcome key with the previous ledger line's key. On an exact consecutive repeat, search open issues on
     `ahrefs/ocannl` for one claiming that same recurring condition; add this run's evidence there if one exists, otherwise
     file an issue whose title names the repeatedly blocked formatting sweep and whose body includes both ledger lines, the
     current output, and the remedy. A first occurrence remains the designed daily no-op and does not get an issue.
     Two of these have a specific remedy to name on a repeat. "another format-sweep is running" also covers a stale lock left
     by a hard kill; the $LOCKDIR path in the output is what a person clears, but only after confirming no live sweep still
     owns it (a hung sweep and a stale lock produce the same message, and removing the directory under a live one lets a
     second invocation rewrite the same checkout underneath it — so the check is for the process first, the directory second).
     "a tools/test-run.sh run is active" / "held its lock past the bound" is an flock the kernel drops when its holder dies, so
     a repeat means a genuinely long-running or hung test run to look at, never a lock file to delete.
   - "repository already formatted; nothing to do": end with a one-line report.
   - "pushed <sha>": the sweep landed. Report the SHA in one line.
   - "origin/master moved during the sweep; dropped the sweep" or "quiet period ended during the sweep; dropped the sweep": a
     benign race against the post-commit gate recheck; it retries on the next scheduled run. One-line report.
   - "git fetch failed" (the entry gate, before the sweep starts), "git fetch failed; dropped the sweep" or "push failed;
     dropped the sweep": nothing was left behind — the entry-gate one never touched the tree and the other two revert it — so
     the checkout is safe and the next run is unblocked, but unlike the races above these are NOT self-healing if the cause is
     credentials, branch protection or remote config, which would drop every future sweep the same way. Report in one line
     WITH the git error the output carries, and say whether the previous scheduled run reported the same step failing; a
     repeat is an operational break to raise, not a race to wait out. Detect and raise it through the same ledger comparison
     and `ahrefs/ocannl` issue-or-update flow as a repeated designed no-op above.
   - "master diverged from origin/master; resolve that first", "working tree changed during the entry gates; resolve that
     first", "working tree changed while waiting for the test-run lock; resolve that first", "not the main checkout (master is
     checked out in a linked worktree)", "ocamlformat is not installed" or "ocamlformat <version> does not match the
     .ocamlformat pin": these need a person, and until someone acts every future sweep dies at the same gate — not even on the
     first occurrence is waiting the right move. "not the main checkout" is the least obvious of them: the gate compares the
     checkout's git-dir against its git-common-dir, so it fires on the directory the task is REGISTERED to run in, which is
     fixed configuration the next run reuses unchanged; report it as the task pointing at a linked worktree instead of
     /Users/lukstafi/ocannl-staging. Do NOT clear them yourself — do not reset, clean or stash the main checkout (the
     changed-tree messages exist precisely to preserve someone's unrelated in-progress work), do not resolve the divergence,
     and do not run the opam install the ocamlformat messages name. Report in one line which gate stopped it and what the fix
     is, and raise it as an operational break rather than waiting for it to clear on its own.
   - A test-gate failure ("@check failed", "test suite failed...") or "no fixed point after N rounds": the script has already reverted the tree. Do NOT re-run it, do NOT use --force, do NOT hand-edit goldens, do NOT push anything. Read the test-run log the output names (a path under ~/.ocannl-test-runs/) and report a short diagnosis. The most likely cause of non-convergence is an ocamlformat-hostile golden (for example a new test/ppx/*_expected.ml) missing from .ocamlformat-ignore.
   - "gh failed": report that the quiet-period check could not reach GitHub; do not override it.
3. If formatting failed for a formatting-specific, well-scoped, low effort and impact, unambiguous reason, act: attach a floating docu-comment, separate an ambiguously attached docu-comment from the code it doesn't describe, update a broken code link if the intended target can be confidently traced etc. --  fix the problem, commit directly on master, push it (a direct-to-master landing under the ship-pr rules; the entry gate refuses a checkout with local commits not on origin/master, so an unpushed repair only produces that no-op and blocks every later scheduled sweep), and try again from (1). Otherwise report the problem and stop. If the ledger cannot be read or appended, do not claim a previous-run comparison succeeded: report the ledger failure as the operational break, including the path and error, because recurrence detection is disabled until it is fixed.
