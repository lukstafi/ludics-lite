---
name: daily-issue-planning
description: Sequence open issues for execution with focus on what and where to do today.
---

Do not start editing until `git -C ~/self-improve pull --rebase` has actually succeeded — the plan is edited from other boxes too, and every recovery below ends by running it again, since nothing else fetches what they pushed. If it does not succeed, a previous run may have left a conflicted rebase behind: finish it (`git -C ~/self-improve rebase --continue`, or `--abort` for a clean tree), pull again, and if you still cannot get a clean pull, stop and report that the plan was not updated at all and why.

Update ~/self-improve/ClaudeDesktop/sequencing_plan.md with the account of all currently open issues across my active GitHub repositories: ahrefs/ocannl (PRs at lukstafi/ocannl-staging), lukstafi/flotilla, lukstafi/ocaml-cudajit, lukstafi/ocaml-metal, lukstafi/ocaml-hipjit, lukstafi/ocaml-dataprep, lukstafi/lukstafi.github.io, lukstafi/ludics-lite.

Arrange the material without unhelpful redundancy, the following are needs, not steps.

- Briefly describe the issues.
- Group them.
- Show dependencies.
- Categorize into three classes: (D1) straightforward ones; (D2) requiring logical problem solving, but limited code impact (e.g. debugging); (D3) requiring design taste and tricky conceptual thinking.
- Pick the issues that can be implemented or solved first.
  - Present them as the first-wave list, with an explicit home-box field on every item: exactly one of
    `mac-studio`, `rog-nv-wsl`, or `minix-amd-wsl`. This is the issue-wave coordinator's dispatch
    lookup, so never leave it to inference from the machine-placement prose. When an issue has useful
    legs on other boxes, name the box where its primary iteration happens as home and list the other
    boxes separately as legs. If one list item groups issues with different homes, label each issue's
    home rather than giving the group an ambiguous shared field.
  - Among them, show which ones are good to run in parallel to one-another.
  - Among them, show which ones prefer to run on ROG (NVIDIA GPU) and which prefer to run on Minix (AMD GPU).
- End with a "## Design questions" section surfacing the open design decisions you noticed while reading the issues. This section feeds the issue-wave skill's decision gate, so make each entry directly consumable: one line per question with the issue number, the X-vs-Y in a clause, **your own recommendation with a one-clause reason**, and a suggested tier: "veto" (default: the wave posts the recommendation to the issue and proceeds; user silence is consent) or "ask" (reserved for genuinely user-owned calls: lasting API/workflow taste, or impacting longer term design direction). Lean heavily toward "veto" — the point is to spare the user decision fatigue, not to route every judgment through them. Drop entries from previous runs once their issue closes or a decision lands.

Updating the doc means removing issues that are closed and adding issues that are missing. For OCANNL, also assign issues that miss a milestone to the appropriate milestone. Keep the file's "Last updated" header to a few lines — the date, the run number, and one line on what changed — because the issue-wave skill reads the whole file live at every invocation; the narrative of the previous day's activity (what merged, what was filed, what closed) goes into the sync commit message, not into the header. After done, do a sync commit of all changes on ~/self-improve and push. If the push does not succeed — rejected, or failing for any other reason (auth, network, remote down) — run `git -C ~/self-improve pull --rebase` once and push again. If that still fails, do not leave it silent: end your report with an explicit final line saying the plan was updated locally but not pushed, and why (the error, and any rebase conflict you left behind) — other boxes read this file live and would otherwise keep working off a stale plan.

This routine is started inside the ocannl-staging repository, as this one has the richest related memory and context.
