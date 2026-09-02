# Claude Code skills

The authoritative copy of my personal (user-level) Claude Code skills. Each machine symlinks
`~/.claude/skills/<name>` here, so a skill edited mid-session lands in this working tree and shows
up as a normal `git status` — there is no separate sync step to forget.

Only the skills live here. The rest of `~/.claude` (sessions, cache, credentials, `settings.json`)
stays out of version control: it is machine-local and partly sensitive.

## Setting up a machine

```sh
git clone git@github.com:lukstafi/self-improve.git ~/self-improve   # if not already cloned
for s in "$HOME"/self-improve/ClaudeDesktop/skills/*/; do
  ln -sfn "${s%/}" "$HOME/.claude/skills/$(basename "$s")"
done
```

Rerun the loop after adding a skill. Replace any pre-existing real directory in
`~/.claude/skills/` by hand first — diff it against this copy, since a divergent local edit may be
a fix worth keeping.

On a machine that runs Codex workers (see issue-wave's Codex workers section), also link the
skills Codex uses into `~/.codex/skills` — same tree, same no-sync-step property. The issue-wave
coordinator's per-launch preflight (`issue-wave/scripts/fleet-worker.sh preflight <box> --codex`)
refuses to launch a Codex worker on a box where these links are missing, so run the loop once per
box before its first Codex wave:

```sh
mkdir -p "$HOME/.codex/skills"
for s in ship-pr wait-and-proceed after-merge; do
  ln -sfn "$HOME/self-improve/ClaudeDesktop/skills/$s" "$HOME/.codex/skills/$s"
done
```

## Fleet boxes

Waves run with one coordinator for the whole fleet (issue-wave skill, self-improve#12): workers
are launched onto rog-nv-wsl / minix-amd-wsl over ssh by `issue-wave/scripts/fleet-worker.sh`,
whose `preflight` fast-forwards that box's `~/self-improve` to upstream main before every launch
and refuses on a dirty or diverged checkout. That pull-side step is what propagates merged skill
edits to boxes that slept through the merge; the push-side fast-forward after a merge is
best-effort tidying. A headless worker also needs the box's CLI logged in — `claude auth login`
there for Claude workers (an expired OAuth session cannot refresh headless, and `claude auth
status` does not notice), `codex login` for Codex ones; the preflight proves both with a live
call, not a status read.

## Why not copies

Copies drift silently, and did: the `ship-pr` watcher was independently repaired on a second
machine against a base that had already grown a better fix, so the repair both duplicated work and
sat on top of a copy missing later improvements (`resolve` pagination, watermark preservation
across a failed API round). Symlinks make one tree the only tree.
