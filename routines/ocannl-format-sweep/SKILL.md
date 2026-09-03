---
name: ocannl-format-sweep
description: Run OCANNL's quiet-period repo-wide formatting sweep and report the outcome
---

Run OCANNL's automated formatting sweep.

Working directory: /Users/lukstafi/ocannl-staging (the main checkout — not a worktree under .claude/worktrees/).

1. Run `tools/format-sweep.sh` with NO flags — never pass --force on a scheduled run — through the Bash tool in background mode, and act on its completion notification. A sweep that actually proceeds runs the full test suite and can take on the order of 30 minutes; a gated no-op returns in seconds.
2. Interpret the outcome from the script's output:
   - "not a quiet period" (open PRs or active worktrees), "not on master", "working tree not clean", or "local commits not on origin/master": this is the designed no-op. End with a one-line report.
   - "repository already formatted; nothing to do": end with a one-line report.
   - "pushed <sha>": the sweep landed. Report the SHA in one line.
   - "origin/master moved during the sweep; dropped the sweep": a benign race; it retries on the next scheduled run. One-line report.
   - A test-gate failure ("@check failed", "test suite failed...") or "no fixed point after N rounds": the script has already reverted the tree. Do NOT re-run it, do NOT use --force, do NOT hand-edit goldens, do NOT push anything. Read the test-run log the output names (a path under ~/.ocannl-test-runs/) and report a short diagnosis. The most likely cause of non-convergence is an ocamlformat-hostile golden (for example a new test/ppx/*_expected.ml) missing from .ocamlformat-ignore.
   - "gh failed": report that the quiet-period check could not reach GitHub; do not override it.
3. If formatting failed for a formatting-specific, well-scoped, low effort and impact, unambiguous reason, act: attach a floating docu-comment, separate an ambiguously attached docu-comment from the code it doesn't describe, update a broken code link if the intended target can be confidently traced etc. --  fix the problem, commit directly on master, push it (a direct-to-master landing under the ship-pr rules; the entry gate refuses a checkout with local commits not on origin/master, so an unpushed repair only produces that no-op and blocks every later scheduled sweep), and try again from (1). Otherwise report the problem and stop.