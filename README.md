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

## Why not copies

Copies drift silently, and did: the `ship-pr` watcher was independently repaired on a second
machine against a base that had already grown a better fix, so the repair both duplicated work and
sat on top of a copy missing later improvements (`resolve` pagination, watermark preservation
across a failed API round). Symlinks make one tree the only tree.
