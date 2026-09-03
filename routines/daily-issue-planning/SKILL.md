---
name: daily-issue-planning
description: Sequence open issues for execution with focus on what and where to do today.
---

Update ~/self-improve/ClaudeDesktop/sequencing_plan.md with the account of all currently open issues across my active GitHub repositories: ahrefs/ocannl (PRs at lukstafi/ocannl-staging), lukstafi/flotilla, lukstafi/ocaml-cudajit, lukstafi/ocaml-metal, lukstafi/ocaml-hipjit, lukstafi/ocaml-dataprep, lukstafi/lukstafi.github.io, lukstafi/ludics-lite.

Arrange the material without unhelpful redundancy, the following are needs, not steps.

- Briefly describe the issues.
- Group them.
- Show dependencies.
- Categorize into three classes: (D1) straightforward ones; (D2) requiring logical problem solving, but limited code impact (e.g. debugging); (D3) requiring design taste and tricky conceptual thinking.
- Pick the issues that can be implemented or solved first.
  - Among them, show which ones are good to run in parallel to one-another.
  - Among them, show which ones prefer to run on ROG (NVIDIA GPU) and which prefer to run on Minix (AMD GPU).
- End with a "## Design questions" section surfacing the open design decisions you noticed while reading the issues. This section feeds the issue-wave skill's decision gate, so make each entry directly consumable: one line per question with the issue number, the X-vs-Y in a clause, **your own recommendation with a one-clause reason**, and a suggested tier: "veto" (default: the wave posts the recommendation to the issue and proceeds; user silence is consent) or "ask" (reserved for genuinely user-owned calls: lasting API/workflow taste, or impacting longer term design direction). Lean heavily toward "veto" — the point is to spare the user decision fatigue, not to route every judgment through them. Drop entries from previous runs once their issue closes or a decision lands.

Updating the doc means removing issues that are closed and adding issues that are missing. For OCANNL, also assign issues that miss a milestone to the appropriate milestone. Keep the file's "Last updated" header to a few lines — the date, the run number, and one line on what changed — because the issue-wave skill reads the whole file live at every invocation; the narrative of the previous day's activity (what merged, what was filed, what closed) goes into the sync commit message, not into the header. After done, do a sync commit of all changes on ~/self-improve and push.

This routine is started inside the ocannl-staging repository, as this one has the richest related memory and context.