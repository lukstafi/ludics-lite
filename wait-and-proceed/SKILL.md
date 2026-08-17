---
name: wait-and-proceed
description: Wait for work in another session to land before starting yours, then proceed. Use when told this task is sequenced behind something, when asked to start after a branch or PR merges, or when beginning work that builds on a change still in flight.
---

# Wait, then proceed

Sequenced work is run one piece at a time on purpose. Concurrency here would buy wall-clock and
spend it on merge conflicts, cold prompt caches, and corrupted timings — all of
which are scarcer than the machine. So: wait, and wait cheaply.

**Before you read anything, arm the waiter.** Then hold a one-paragraph brief and do nothing else.

The instinct is to get oriented first and wait afterwards. That is backwards, and it is the whole
reason sequencing is cheap when done right and expensive when done wrong:

- Context read now is a snapshot of the codebase *before* your dependency lands. You would wake up
  holding a confident, stale picture and plan against a base that no longer exists.
- Context held across a multi-hour wait ages out of the prompt cache anyway, so you pay to read it
  and then pay again to re-read it.

Hold nothing, and the wait costs approximately nothing. Read everything on wake, when the tree is
already current.

Some non-contending work is legitimate while parked — thinking through an approach, asking the
user clarifying questions. Nothing that touches the repository, and nothing whose conclusions
depend on code your dependency is about to change.

## Arm the waiter

```bash
~/.claude/skills/wait-and-proceed/scripts/wait-for.sh branch <branch> --label "<what this unblocks>"
```

**Run it with Bash `run_in_background: true`.** Its completion notification is your wake signal —
one notification, no polling, no turns burned while it waits. Run in the foreground and it will
hit the 600s tool cap long before the merge happens.

A branch is the right thing to name whether or not a PR exists yet: the script watches the PR when
there is one and git when there is not, so you can arm it before the other session has opened
anything.

For anything that is not a branch, use a predicate command — an issue closing, a file appearing, a
check passing:

```bash
~/.claude/skills/wait-and-proceed/scripts/wait-for.sh cmd 'gh issue view 601 --json state --jq .state | grep -q CLOSED'
```

Options: `--base` (default `origin/master`), `--timeout` (default 4h), `--interval` (default 60s),
`--repo`, `--label`.

## Read the outcome, do not assume it

Every exit prints one line. Four of the five are not "go":

| Exit | Line | What to do |
|---|---|---|
| 0 | `CLEAR:` | Proceed — step 5. |
| 3 | `TIMEOUT:` | Nothing landed in the window. Report to the user; do not start on a guess. |
| 4 | `ERROR:` | Predicate unevaluable (wrong repo path). Fix and re-arm. |
| 5 | `ABANDONED:` | The PR was closed unmerged — this will never clear. Tell the user; the plan needs rethinking, not a longer wait. |
| 2 | usage | Fix the invocation. |

A `CLEAR` line naming a merge commit means the PR is what reported the landing, which is the usual
case — merging generally deletes the head branch, so the branch itself is often gone by the time
you wake. Rebase onto the base branch, never onto that branch's tip.

## On wake

1. `git fetch` and rebase or branch off the *current* base — not the state you last saw.
2. *Now* read the code. Read the merged diff rather than trusting the brief you were parked with;
   the landed shape often differs from the planned one after review.
3. Do the work. Land it with the `ship-pr` skill.
