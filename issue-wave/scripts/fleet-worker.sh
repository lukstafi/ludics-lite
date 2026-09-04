#!/usr/bin/env bash
# The fleet half of the issue-wave skill: one coordinator launches workers onto any box in the
# fleet and supervises them there, with the same commands whether the box is the coordinator's
# own machine or a remote one reached over ssh (ludics-lite#4).
#
# A worker is a detached tmux session on its box running one headless CLI turn --
# `claude -p --output-format stream-json` or `codex exec --json` -- with its brief on stdin and
# its event stream on disk under the box's ~/.local/state/issue-wave/workers/<name>/. Everything
# the coordinator needs later is a file there: the JSONL stream, stderr, the exit code, and a
# meta file naming the kind, the cwd and the session id that addresses every intervention.
#
# Why the shape is what it is, kept in code rather than skill prose:
#   - the worker's process tree hangs off tmux on ITS box, never off the coordinator's ssh or
#     the coordinator's session, so a coordinator pause, restart or dropped connection strands
#     nothing -- `attach` re-arms against the still-running session;
#   - every prompt (brief, unstick message) travels as a FILE, never as command-line text: issue
#     prose is full of backticks and $() that a shell would expand before the model saw them;
#   - supervision reads are the same commands on every box, so "the JSONL stream is quiet AND the
#     worktree is unmoved" (the stall test for workers with no yield signal) does not assume the
#     coordinator can read the worker's disk directly;
#   - the skill-freshness preflight (ludics-lite#3) runs on the box that will run the worker,
#     because that box's ~/.claude/skills symlinks serve whatever its checkout holds;
#   - `unstick` refuses to resume a session whose exec is still alive: a resume beside a live exec
#     gives the branch two writers, and the quiet stream that prompted the unstick does not prove
#     the exec cannot still act;
#   - fleet-wide state -- the coordinator LEASE and the stop-the-world HALT -- lives on one anchor
#     box (mac-studio, the always-on controller), never on whichever box the coordinator happens
#     to run on: `claim` takes the lease atomically, every `launch` proves it holds it, and `halt`
#     is a file on the anchor the launcher checks, so "one coordinator" and "launch nothing new
#     after an integration regression" are enforced rather than remembered.
#
# Usage:
#   fleet-worker.sh claim [--take]         # take the fleet's coordinator lease (--take adopts)
#   fleet-worker.sh coordinator | release  # who holds it (exit 0 me, 1 other, 3 nobody) / give it up
#   fleet-worker.sh preflight <box> [--codex] [--no-probe]   # launch runs this itself, too
#   fleet-worker.sh launch <box> <name> --kind claude|codex --brief <file>
#                          (--cwd <dir> | --repo <dir> --branch <branch> [--base <ref>])
#                          [--force] [--replace] [-- <extra CLI args>]
#   fleet-worker.sh attach <box> <name> [--interval <sec>]
#   fleet-worker.sh status <box> <name>
#   fleet-worker.sh log <box> <name> [-n <lines>]
#   fleet-worker.sh unstick <box> <name> --message <file> [--kill] [-- <extra CLI args>]
#   fleet-worker.sh ls [<box> ...]
#   fleet-worker.sh load
#   fleet-worker.sh halt <reason> | resume-launches | halted
#
# `launch`, `unstick`, `halt` and `resume-launches` require the lease; `launch` also refuses
# while halted (`--force` admits the one triage worker) and runs the preflight on the box first.
# Lease and halt live on FLEET_ANCHOR.
#
# <box> is an ssh destination (rog-nv-wsl, minix-amd-wsl), or `local` / this machine's own fleet
# name (detected from the hostname through FLEET_HOSTNAME_MAP; FLEET_LOCAL_BOX overrides) for the
# coordinator's own machine.
#
# Exit: 0 ok | 1 the fact does not hold (refused, worker failed, stale) | 2 usage |
#       3 worker vanished without an exit record | 4 the box never answered.
#
# Env:
#   FLEET_COORDINATOR: lease identity; defaults to inherited CLAUDE_CODE_SESSION_ID or
#     CODEX_THREAD_ID. Required when the harness supplies neither, because nothing is guessed from
#     the process tree.
#   FLEET_LOCAL_BOX: this box's fleet name; otherwise detected from the hostname.
#   FLEET_HOSTNAME_MAP: space-separated `<glob>=<box>` hostname mappings, first match wins; the
#     default is the author's fleet.
#   FLEET_BASE_REF: ref from which `launch` starts a worktree when --base is absent; origin/master.
#   FLEET_ANCHOR: box where lease and halt live; mac-studio.
#   FLEET_ANCHOR_STATE: anchor state dir; defaults to ISSUE_WAVE_STATE.
#   FLEET_BOXES: whole fleet; "mac-studio rog-nv-wsl minix-amd-wsl". `ls` sweeps it minus local.
#   FLEET_SKILLS_REPO: skills checkout on each box; ~/ludics-lite.
#   ISSUE_WAVE_STATE: local worker-state directory; ~/.local/state/issue-wave.
#   FLEET_TMUX_SOCKET: tmux -L name; tests isolate with it.
#   FLEET_FLOTILLA: status service; http://mac-studio:7799.
#   FLEET_LOCK_WAIT: seconds a lease mutation waits for a concurrent one; 10.
#   FLEET_PROBE_TIMEOUT: wall-clock bound on the live headless preflight turn; 120.
#   FLEET_FETCH_TIMEOUT: wall-clock bound on skills-checkout and project fetches; 300.

set -uo pipefail

# Which fleet box this is, from the hostname unless FLEET_LOCAL_BOX says so; an unrecognized
# host is local to nothing but the literal `local`, so every named box is reached over ssh.
# FLEET_HOSTNAME_MAP is the lookup: `<glob>=<box>` pairs, first match wins, patterns are shell
# globs against the lowercased short hostname (so `*mac-studio*` and `rog-nv*` read as expected).
# The Mac Studio's short hostname is `LukaszsacStudio` (Apple names the host after the owner and
# model, not after the ssh alias), so it is listed beside the alias-shaped spelling: without it
# the coordinator on the anchor box itself ssh'd to `mac-studio` and read its own lease and
# halt files as unreachable (2026-09-04, the first fleet-wide wave).
HOSTNAME_MAP="${FLEET_HOSTNAME_MAP:-*mac-studio*=mac-studio lukaszsacstudio*=mac-studio rog-nv*=rog-nv-wsl rog=rog-nv-wsl minix*=minix-amd-wsl}"
detect_local_box() {
  local host pair
  local -a hostname_pairs=()
  host=$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z')
  read -r -a hostname_pairs <<< "$HOSTNAME_MAP"
  for pair in "${hostname_pairs[@]}"; do
    case "$pair" in *=*) ;; *) continue ;; esac
    # shellcheck disable=SC2254  # the glob is the point
    case "$host" in ${pair%%=*}) echo "${pair#*=}"; return ;; esac
  done
  echo ""
}
LOCAL_BOX="${FLEET_LOCAL_BOX-$(detect_local_box)}"
BASE_REF="${FLEET_BASE_REF:-origin/master}"
ANCHOR="${FLEET_ANCHOR:-mac-studio}"
BOXES="${FLEET_BOXES:-mac-studio rog-nv-wsl minix-amd-wsl}"
SKILLS_REPO="${FLEET_SKILLS_REPO:-\$HOME/ludics-lite}"
STATE="${ISSUE_WAVE_STATE:-\$HOME/.local/state/issue-wave}"
ANCHOR_STATE="${FLEET_ANCHOR_STATE:-$STATE}"
TMUX_SOCKET="${FLEET_TMUX_SOCKET:-}"
FLOTILLA="${FLEET_FLOTILLA:-http://mac-studio:7799}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"

die() { echo "fleet-worker.sh: $*" >&2; exit 2; }

is_local() { [ "$1" = local ] || { [ -n "$LOCAL_BOX" ] && [ "$1" = "$LOCAL_BOX" ]; }; }

# A configured path, expanded on THIS box (a default keeps a literal $HOME so the same value can
# also be shipped to another box and expanded there).
local_path() { case "$1" in '$HOME'/*) printf '%s' "$HOME/${1#\$HOME/}" ;; *) printf '%s' "$1" ;; esac; }
# The same value as a far-side assignment: $HOME stays expandable, the rest is shell-quoted, so
# a checkout under "/Volumes/Work Trees" is an assignment and not a command.
emit_var() {
  case "$2" in
    '$HOME'/*) printf '%s="$HOME"/%q\n' "$1" "${2#\$HOME/}" ;;
    *) printf '%s=%q\n' "$1" "$2" ;;
  esac
}

# Every far-side script starts with this: the same paths, the same tmux invocation, the same
# portable helpers, on macOS and Linux alike, and BOX = the name the coordinator addressed the
# box by, so every line it prints is greppable by that name rather than by a hostname the
# coordinator never typed. Single-quoted heredoc: nothing expands locally.
prelude() {
  emit_var STATE "$STATE"; emit_var SKILLS_REPO "$SKILLS_REPO"; emit_var ANCHOR_STATE "$ANCHOR_STATE"
  printf 'TMUX_SOCKET=%q\nBOX=%q\n' "$TMUX_SOCKET" "$1"
  cat <<'EOF'
set -uo pipefail
expand_tilde() { case "$1" in '~/'*) printf '%s' "$HOME/${1#\~/}" ;; '~') printf '%s' "$HOME" ;; *) printf '%s' "$1" ;; esac; }
tm() { if [ -n "$TMUX_SOCKET" ]; then tmux -L "$TMUX_SOCKET" "$@"; else tmux "$@"; fi; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
now() { date +%s; }
meta_get() { sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | head -n1; }
# The session id addresses every intervention: from meta when the launch recorded it, else from
# the stream itself (a Codex thread id lands there first; a launch connection can drop between).
session_of() {
  local s; s=$(meta_get "$1" session)
  [ -n "$s" ] || s=$(jq -Rr 'fromjson? | select(.type=="thread.started") | .thread_id' "$1/stream.jsonl" 2>/dev/null | head -n1)
  [ -n "$s" ] || s=$(jq -Rr 'fromjson? | select(.type=="system" and .subtype=="init") | .session_id' "$1/stream.jsonl" 2>/dev/null | head -n1)
  printf '%s' "$s"
}
# A literal string as an ERE, for pgrep/pkill -f.
re_lit() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
# `=` forces an exact session name: without it tmux falls back to prefix matching, and with
# iw-repo-1 gone, -t iw-repo-1 would resolve to iw-repo-12 - reading, or killing, a sibling.
alive() { tm has-session -t "=iw-$1" 2>/dev/null; }
WORKERS="$STATE/workers"
# take_lock <dir> <wait-seconds> <label>: a mkdir lock that records its holder's pid, so a lock
# left by a killed shell or a rebooted box is reclaimed instead of wedging the name forever.
# Prints nothing on success; on failure prints one line and returns 1. Release with rmdir.
# The holder is identified by pid AND process start time: after a reboot (or plain pid reuse)
# the recorded pid may belong to an unrelated live process, which a bare kill -0 would treat
# as the holder forever.
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }
take_lock() {
  local lock="$1" wait="$2" label="$3" waited=0 holder hstart
  until mkdir "$lock" 2>/dev/null; do
    [ -d "$lock" ] || { echo "$label: cannot create lock $lock (unwritable?)"; return 1; }
    holder=$(cat "$lock/pid" 2>/dev/null); hstart=$(cat "$lock/start" 2>/dev/null)
    if [ -n "$holder" ] && { ! kill -0 "$holder" 2>/dev/null || [ "$(proc_start "$holder")" != "$hstart" ]; }; then
      rm -f "$lock/pid" "$lock/start"; rmdir "$lock" 2>/dev/null; continue   # dead or reused pid: reclaim
    fi
    # No owner recorded: registration takes milliseconds, so an ownerless lock older than 30 s
    # was left by a shell that died between mkdir and the pid write. Reclaim it.
    if [ -z "$holder" ] && [ $(( $(now) - $(mtime "$lock") )) -gt 30 ]; then
      rm -f "$lock/pid" "$lock/start"; rmdir "$lock" 2>/dev/null; continue
    fi
    [ "$waited" -lt "$wait" ] || { echo "$label: lock $lock held ${holder:+by pid $holder }for ${wait}s -- another operation in progress"; return 1; }
    sleep 1; waited=$((waited + 1))
  done
  # start before pid: a contender that sees a pid without its start time would otherwise read
  # the mismatch as a reused pid and reclaim a lock that is being taken right now.
  proc_start $$ > "$lock/start"; echo $$ > "$lock/pid"
}
release_lock() { rm -f "$1/pid" "$1/start"; rmdir "$1" 2>/dev/null; }
# bounded [--stdin <file>] <secs> <cmd...>: run detached from the caller's stdin, kill the whole
# group at the deadline (no `timeout` on stock macOS). Output on stdout; exit 124 on expiry.
# The child's stdin is /dev/null unless --stdin names a file. A pipe into `bounded` is NOT
# forwarded: a `&` command with job control off gets /dev/null for stdin, and macOS's bash 3.2
# (what the local run_on's `bash -s` is) applies that even inside a pipeline, while bash 5 on the
# Linux boxes kept the pipe -- so the live probe's prompt reached codex on rog and minix and
# vanished on mac-studio ("No prompt provided via stdin.", reported as an empty refusal). And the
# far-side scripts run under `bash -s`, whose stdin IS the script: a child inheriting it would
# eat the rest of the preflight. Hence a file, never the inherited descriptor.
bounded() {
  local stdin=/dev/null
  if [ "$1" = --stdin ]; then stdin="$2"; shift 2; fi
  local secs="$1"; shift
  local out rcf pid waited=0 rc c
  out=$(mktemp "${TMPDIR:-/tmp}/fw-probe.XXXXXX"); rcf=$(mktemp "${TMPDIR:-/tmp}/fw-probe-rc.XXXXXX")
  # Everything under the probe writes to files or /dev/null: nothing it spawns may inherit the
  # caller's stdout, or a lingering child would hold a command substitution open.
  ( "$@" < "$stdin" > "$out" 2>&1; echo $? > "$rcf" ) >/dev/null 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt "$secs" ]; do sleep 1; waited=$((waited + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    for c in $(pgrep -P "$pid" 2>/dev/null); do pkill -P "$c" 2>/dev/null; kill "$c" 2>/dev/null; done
    kill "$pid" 2>/dev/null; rc=124
  else
    rc=$(cat "$rcf" 2>/dev/null); rc=${rc:-1}
  fi
  wait "$pid" 2>/dev/null
  cat "$out"; rm -f "$out" "$rcf"; return "$rc"
}
# The pattern that finds a worker's CLI by its own command line: a claude or codex command
# word, then the session id (claude, and codex after a resume) or this worker's state dir
# (codex's -o). The command-word anchor keeps a `tail -f .../stream.jsonl` or an editor on a
# record file from reading as the worker - or from being killed as one. Same pattern everywhere.
live_pat() {
  local d="$WORKERS/$1" p sid; p=$(re_lit "$WORKERS/$1/"); sid=$(session_of "$d"); [ -n "$sid" ] && p="$(re_lit "$sid")|$p"
  printf '(^|/| )(claude|codex)( |$).*(%s)' "$p"
}
# tmux gone but the CLI reparented and still running: a live writer, not a finished worker.
orphaned() { ! alive "$1" && pgrep -f -- "$(live_pat "$1")" >/dev/null 2>&1; }
running() { alive "$1" || orphaned "$1"; }
state_of() { if alive "$1"; then echo RUNNING; elif orphaned "$1"; then echo ORPHANED; elif [ -f "$WORKERS/$1/exit" ]; then echo "EXITED($(cat "$WORKERS/$1/exit"))"; else echo VANISHED; fi; }
EOF
}

# Run a script (on stdin) on the box; positional args arrive as $1.. on the far side. Locally
# the script runs in a child bash; remotely `bash -s` reads it over ssh. Args are %q-quoted for
# the remote login shell, which must be bash-compatible (it is on every WSL box).
run_on() {
  local box="$1"; shift
  if is_local "$box"; then
    bash -s -- "$@"
  else
    local quoted="" a
    for a in "$@"; do quoted="$quoted $(printf '%q' "$a")"; done
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$box" "bash -s --$quoted"
  fi
}

# Copy a local file to a path on the box (parent created). The file's bytes cross as stdin, so
# nothing in it is ever a shell word anywhere.
put_file() {
  local box="$1" src="$2" dst="$3" q
  if is_local "$box"; then
    bash -c 'mkdir -p "$(dirname "$1")" && cat > "$1"' -- "$(local_path "$dst")" < "$src"
  else
    # The destination travels as ONE quoted word ($HOME kept expandable, the rest %q), never
    # interpolated into the command text where a quote or $() in a configured path would run.
    case "$dst" in '$HOME'/*) q="\"\$HOME\"/$(printf '%q' "${dst#\$HOME/}")" ;; *) q=$(printf '%q' "$dst") ;; esac
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$box" "bash -c 'mkdir -p \"\$(dirname \"\$1\")\" && cat > \"\$1\"' -- $q" < "$src"
  fi
}

# A session id for a Claude worker, from whatever the coordinator's box has; empty means none of
# the sources worked and the launch must refuse rather than start an unaddressable session.
gen_uuid() {
  local u
  u=$(uuidgen 2>/dev/null) || u=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) ||
    u=$(python3 -c 'import uuid; print(uuid.uuid4())' 2>/dev/null) ||
    u=$(od -An -N16 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n' | sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\)$/\1-\2-\3-\4-\5/')
  u=$(printf '%s' "$u" | tr 'A-Z' 'a-z')
  case "$u" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*-*-*-[0-9a-f]*) printf '%s' "$u" ;;
    *) return 1 ;;
  esac
}

# ssh's own transport failure is 255; a local child cannot produce it, so 255 always means the
# box never answered and the caller may retry rather than conclude anything.
unreachable() { [ "$1" -eq 255 ]; }

# No leading dot: a `*` glob (fleet inventory) would not see such a record.
valid_name() { case "$1" in ''|.*|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

# The coordinator's identity is per SESSION, not per box: FLEET_COORDINATOR if set, else the
# harness identity inherited as CLAUDE_CODE_SESSION_ID or CODEX_THREAD_ID. Nothing is guessed from
# the process tree - a parent pid is shared by sibling tabs and changes under command substitution,
# so a guessed identity is either not unique or not stable. Its token lives under that identity, so
# a second coordinator session on the same box has no token and cannot pass the gate, and a
# restarted coordinator (new session id) must adopt explicitly with claim --take.
coordinator_id() {
  if [ -n "${FLEET_COORDINATOR:-}" ]; then printf '%s' "$FLEET_COORDINATOR"
  elif [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then printf 'session-%s' "$CLAUDE_CODE_SESSION_ID"
  elif [ -n "${CODEX_THREAD_ID:-}" ]; then printf 'codex-%s' "$CODEX_THREAD_ID"
  fi
}
# Validated at top level (a die inside $(...) would only end the substitution): the identity
# is used verbatim as the token file name, so it must be injective - no folding of characters.
check_identity() {
  local id; id=$(coordinator_id)
  [ -n "$id" ] || die "no coordinator identity: harness supplied neither CLAUDE_CODE_SESSION_ID" \
    "nor CODEX_THREAD_ID -- set FLEET_COORDINATOR=<name> for this coordinator session"
  case "$id" in .|..|*[!A-Za-z0-9._-]*) die "coordinator identity '$id' must be [A-Za-z0-9._-]+ (set FLEET_COORDINATOR)" ;; esac
}
token_file() { printf '%s/tokens/%s' "$(local_path "$STATE")" "$(coordinator_id)"; }
my_token() { cat "$(token_file)" 2>/dev/null; }

# Far-side script for the anchor: lease + halt checks. Args: verb label force token.
# Prints nothing when the coordinator may proceed; otherwise one refusal line, exit 1.
anchor_gate_script() {
  cat <<'EOF'
verb="$1" label="$2" force="$3" token="$4"
lease="$ANCHOR_STATE/COORDINATOR"
if [ ! -f "$lease" ]; then echo "$verb REFUSED $label: no coordinator lease on the anchor -- run \`fleet-worker.sh claim\` first"; exit 1; fi
held=$(sed -n 's/^token=//p' "$lease"); host=$(sed -n 's/^host=//p' "$lease"); since=$(sed -n 's/^since=//p' "$lease")
if [ -z "$token" ] || [ "$held" != "$token" ]; then
  echo "$verb REFUSED $label: coordinator lease held by $host since $since -- adopt it with \`fleet-worker.sh claim --take\` only if that coordinator is gone"; exit 1
fi
if [ "$force" != 1 ] && [ -f "$ANCHOR_STATE/HALT" ]; then
  echo "$verb REFUSED $label: launches halted -- $(cat "$ANCHOR_STATE/HALT")"; exit 1
fi
EOF
}
# anchor_gate <verb> <label> <force>: exit 0 proceed, 1 refused (line printed), 4 anchor unreachable.
anchor_gate() {
  check_identity
  { prelude "$ANCHOR"; anchor_gate_script; } | run_on "$ANCHOR" "$1" "$2" "$3" "$(my_token)"
  local rc=$?
  if unreachable "$rc"; then echo "$1 REFUSED $2: anchor $ANCHOR unreachable (lease and halt live there)"; return 4; fi
  return "$rc"
}

# ---------------------------------------------------------------------------------------------
# Far-side skill-freshness preflight (ludics-lite#3). Args: codex probe. Exit 0 with a
# PREFLIGHT OK line, 1 with the refusal. `launch` runs it on the box before every worker, so
# the per-launch refusal the skill promises is enforced here rather than remembered.
preflight_script() {
  cat <<'EOF'
codex="$1" probe="$2" probe_timeout="$3" fetch_timeout="$4"
refuse=""
note() { refuse="$refuse; $*"; }
# One preflight per box at a time: a parallel group launched together would otherwise race
# `git fetch`/`merge` in the same checkout and refuse on git's own lock files. Idempotent, so
# waiting for the other preflight is the right thing; the bound covers a hung live probe.
mkdir -p "$STATE" 2>/dev/null; plock="$STATE/preflight.lock"
msg=$(take_lock "$plock" $((fetch_timeout + probe_timeout + 60)) "PREFLIGHT REFUSED $BOX") || { echo "$msg"; exit 1; }
trap 'release_lock "$plock"' EXIT
repo=$(expand_tilde "$SKILLS_REPO")
if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  echo "PREFLIGHT REFUSED $BOX: no skills checkout at $repo"; exit 1
fi
bounded "$fetch_timeout" git -C "$repo" fetch -q origin >/dev/null; frc=$?
if [ "$frc" -eq 124 ]; then note "git fetch in $repo timed out after ${fetch_timeout}s"; elif [ "$frc" -ne 0 ]; then note "fetch failed (offline?)"; fi
# The whole checkout is the served tree: every skill directory sits at its root, so any local
# change - tracked, untracked, even ignored - is divergence to surface, since the deployed
# symlinks would serve it. The one exception is a stray .claude/ (settings.local.json appears
# wherever claude was run inside the checkout): not skill text, so reported rather than refused.
# The fast-forward below still fails, and refuses, if such a change collides with what upstream brings.
# NUL-delimited, so a path git would otherwise quote (a space, a quote, a non-ASCII byte) is
# still classified by its directory rather than falling through as "outside the served tree".
served=0; other=""
statusz=$(mktemp "${TMPDIR:-/tmp}/fw-status.XXXXXX")
if ! git -C "$repo" status --porcelain -z --untracked-files=all --ignored=matching > "$statusz" 2>/dev/null; then
  rm -f "$statusz"; note "git status failed in $repo (cannot scan the served tree)"; statusz=/dev/null
fi
# Index-hidden entries (skip-worktree / assume-unchanged) never show in status: refuse them
# under the served tree outright, since the symlinks serve the working-tree bytes.
hidden=$(git -C "$repo" ls-files -v 2>/dev/null | grep -c '^[Sh]' || true)
[ "${hidden:-0}" -eq 0 ] || note "$hidden index-hidden (skip-worktree/assume-unchanged) file(s) in the served tree"
while IFS= read -r -d '' entry; do
  st=${entry:0:2}; path=${entry:3}; from=""
  case "$st" in R*|C*) IFS= read -r -d '' from ;; esac   # a rename's second record is the source
  # Both sides of a rename count: a file moved OUT of the served tree is a served file gone.
  case "$path" in .claude/*) case "$from" in ""|.claude/*) other="$other$path " ;; *) served=$((served + 1)) ;; esac ;; *) served=$((served + 1)) ;; esac
done < "$statusz"
[ "$statusz" = /dev/null ] || rm -f "$statusz"
[ "$served" -eq 0 ] || note "$served local change(s) in the served tree"
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
[ "$branch" = main ] || note "checked out $branch, not main"
if [ -z "$refuse" ]; then
  git -C "$repo" merge --ff-only -q origin/main >/dev/null 2>&1 || note "main does not fast-forward to origin/main"
fi
head=$(git -C "$repo" rev-parse HEAD 2>/dev/null); up=$(git -C "$repo" rev-parse origin/main 2>/dev/null)
[ "$head" = "$up" ] || note "HEAD $(echo "$head" | cut -c1-9) != origin/main $(echo "$up" | cut -c1-9) (ahead, or offline)"
# Every skill the checkout declares must be one of the symlinks the README installs, into ITS OWN
# directory of THIS checkout - compared as resolved paths, so neither a link through `..` nor two
# links swapped within the checkout can pass. Deriving this set from SKILL.md keeps a new skill
# from falling outside preflight while the README's top-level install glob starts serving it.
canon=$(cd "$repo" && pwd -P)
resolved() { [ -L "$1" ] && (cd -P "$1" 2>/dev/null && pwd -P); }
for skill_dir in "$repo"/*; do
  [ -f "$skill_dir/SKILL.md" ] || continue
  s=${skill_dir##*/}
  t=$(resolved "$HOME/.claude/skills/$s")
  [ "$t" = "$canon/$s" ] || note "~/.claude/skills/$s -> ${t:-missing/not a link} (not $repo/$s)"
done
if [ "$codex" = 1 ]; then
  for s in ship-pr wait-and-proceed after-merge; do
    t=$(resolved "$HOME/.codex/skills/$s")
    [ "$t" = "$canon/$s" ] || note "~/.codex/skills/$s -> ${t:-missing/not a link} (README's Codex loop not run)"
  done
  command -v codex >/dev/null 2>&1 || note "no codex on PATH"
  codex login status >/dev/null 2>&1 || note "codex not logged in"
  # A status read is not a proof either way; only a live headless turn is.
  if [ "$probe" = 1 ] && command -v codex >/dev/null 2>&1; then
    prompt=$(mktemp "${TMPDIR:-/tmp}/fw-prompt.XXXXXX"); printf 'Reply with the single word ok.' > "$prompt"
    out=$(cd / && bounded --stdin "$prompt" "$probe_timeout" codex exec --json --ephemeral --skip-git-repo-check -C / -); prc=$?
    rm -f "$prompt"
    if [ "$prc" -eq 124 ]; then note "codex headless probe timed out after ${probe_timeout}s"
    elif ! printf '%s' "$out" | grep -q '"type":"turn.completed"'; then
      note "codex cannot run headless: $(printf '%s' "$out" | grep -o '"message":"[^"]*"' | head -n1 | cut -c1-120)"
    fi
  fi
else
  command -v claude >/dev/null 2>&1 || note "no claude on PATH"
  # `claude auth status` reports loggedIn:true over an expired, unrefreshable OAuth session
  # (observed 2026-09-02 on minix); only a live turn proves the CLI can run headless here.
  if [ "$probe" = 1 ] && command -v claude >/dev/null 2>&1; then
    prompt=$(mktemp "${TMPDIR:-/tmp}/fw-prompt.XXXXXX"); printf 'Reply with the single word ok.' > "$prompt"
    out=$(cd / && bounded --stdin "$prompt" "$probe_timeout" claude -p --model haiku --output-format json --no-session-persistence); prc=$?
    rm -f "$prompt"
    if [ "$prc" -eq 124 ]; then note "claude headless probe timed out after ${probe_timeout}s"
    elif ! printf '%s' "$out" | grep -q '"is_error":false'; then
      note "claude cannot run headless: $(printf '%s' "$out" | grep -o '"result":"[^"]*"' | head -n1 | cut -c1-120)"
    fi
  fi
fi
command -v tmux >/dev/null 2>&1 || note "no tmux"
command -v jq >/dev/null 2>&1 || note "no jq"
if [ -n "$refuse" ]; then
  echo "PREFLIGHT REFUSED $BOX: ${refuse#; }${other:+ (changes outside the served tree, ignored: $other)}"
  exit 1
fi
echo "PREFLIGHT OK $BOX skills=$(echo "$head" | cut -c1-9)${other:+ (changes outside the served tree, ignored: $other)}"
EOF
}

cmd_preflight() {
  local box="${1:-}"; [ -n "$box" ] || die "preflight: which box?"; shift
  local codex=0 probe=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --codex) codex=1 ;;
      --no-probe) probe=0 ;;
      *) die "preflight: unknown option $1" ;;
    esac
    shift
  done
  { prelude "$box"; preflight_script; } | run_on "$box" "$codex" "$probe" "${FLEET_PROBE_TIMEOUT:-120}" "${FLEET_FETCH_TIMEOUT:-300}"
  local rc=$?
  if unreachable "$rc"; then echo "PREFLIGHT UNREACHABLE $box"; exit 4; fi
  exit "$rc"
}

# ---------------------------------------------------------------------------------------------
cmd_launch() {
  local box="${1:-}" name="${2:-}"
  [ -n "$box" ] && [ -n "$name" ] || die "launch: <box> <name> required"
  valid_name "$name" || die "launch: name must be [A-Za-z0-9._-]+ and not start with a dot"
  shift 2
  local kind="" brief="" cwd="" repo="" branch="" base="$BASE_REF" force=0 replace=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --kind) kind="${2:-}"; shift ;;
      --brief) brief="${2:-}"; shift ;;
      --cwd) cwd="${2:-}"; shift ;;
      --repo) repo="${2:-}"; shift ;;
      --branch) branch="${2:-}"; shift ;;
      --base) base="${2:-}"; shift ;;
      --force) force=1 ;;
      --replace) replace=1 ;;
      --) shift; break ;;
      *) die "launch: unknown option $1" ;;
    esac
    shift
  done
  case "$kind" in claude|codex) ;; *) die "launch: --kind claude|codex" ;; esac
  case "$cwd$repo$branch$base" in *$'\n'*) die "launch: paths and refs must not contain newlines (the record is line-oriented)" ;; esac
  [ -n "$brief" ] && [ -r "$brief" ] || die "launch: --brief <readable file>"
  if [ -z "$cwd" ]; then
    [ -n "$repo" ] && [ -n "$branch" ] || die "launch: --cwd <dir>, or --repo <dir> --branch <branch>"
  fi
  anchor_gate LAUNCH "$box/$name" "$force" || exit $?
  local codex=0 pf; [ "$kind" = codex ] && codex=1
  pf=$( { prelude "$box"; preflight_script; } | run_on "$box" "$codex" 1 "${FLEET_PROBE_TIMEOUT:-120}" "${FLEET_FETCH_TIMEOUT:-300}" )
  local prc=$?
  if unreachable "$prc"; then echo "LAUNCH UNREACHABLE $box"; exit 4; fi
  [ "$prc" -eq 0 ] || { echo "LAUNCH REFUSED $box/$name: $pf"; exit 1; }
  # The preflight fetches and runs a live probe; a halt or an adoption during that window
  # must still fence this launch, so the gate is read again right before anything is written.
  anchor_gate LAUNCH "$box/$name" "$force" || exit $?
  local sid=""
  if [ "$kind" = claude ]; then
    sid=$(gen_uuid) || { echo "LAUNCH REFUSED $box/$name: cannot generate a session id here (no uuidgen, /proc uuid, or python3)"; exit 1; }
  fi
  # The brief lands beside the record, not on it: the far side moves it into place only after
  # the guards pass, so a refused launch leaves a finished worker's brief untouched.
  local stamp; stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  put_file "$box" "$brief" "$STATE/incoming/$name-$stamp.md"
  local prc2=$?
  if unreachable "$prc2"; then echo "LAUNCH UNREACHABLE $box"; exit 4; fi
  [ "$prc2" -eq 0 ] || { echo "LAUNCH REFUSED $box/$name: cannot stage the brief under the worker state dir on $box (unwritable, or a file in the way)"; exit 1; }
  { prelude "$box"; cat <<'EOF'
name="$1" kind="$2" cwd="$3" repo="$4" branch="$5" base="$6" sid="$7" coord="$8" replace="$9" stamp="${10}" fetch_timeout="${11}"; shift 11
d="$WORKERS/$name"; incoming="$STATE/incoming/$name-$stamp.md"
# Until the lock is held nothing here is ours but the staged brief; `fresh` (this launch
# creates the record, so a refusal removes it whole) is decided under the lock.
fresh=0
refuse() { rm -f "$incoming"; if [ "$fresh" = 1 ]; then rm -rf "$d"; fi; echo "LAUNCH REFUSED $BOX/$name: $*"; exit 1; }
# One launch of a name at a time: the guards below and the record writes after them are one
# critical section, held until the tmux session exists (or this launch has refused).
mkdir -p "$STATE/locks"; wlock="$STATE/locks/$name"
msg=$(take_lock "$wlock" 0 "lock") || refuse "another launch or unstick of this name is in progress ($msg)"
archive=""; started=0
on_exit() {
  # Killed anywhere after archiving the old record and before tmux started: put it back; a
  # fresh record that never reached a session is removed, so the name stays launchable. The
  # session itself is the truth: if it exists, nothing is rolled back whatever the flag says.
  if [ "$started" != 1 ] && ! alive "$name"; then
    if [ -n "$archive" ] && [ -d "$archive" ]; then rm -rf "$d"; mv "$archive" "$d" 2>/dev/null
    elif [ "$fresh" = 1 ]; then rm -rf "$d"; fi
  fi
  release_lock "$wlock"; [ -n "${blaunch:-}" ] && release_lock "$blaunch"
}
trap on_exit EXIT; trap 'exit 143' TERM HUP INT
blaunch=""
[ -f "$d/meta" ] || fresh=1
if alive "$name"; then refuse "already running"; fi
if [ -f "$d/meta" ]; then
  # tmux gone is not the CLI gone: a reparented orphan can still write and commit, and
  # --replace must not put a second CLI beside it.
  opat=$(live_pat "$name")
  if pgrep -f -- "$opat" >/dev/null 2>&1; then
    refuse "a CLI from the previous launch is still running ($(pgrep -fl -- "$opat" | head -n 2 | tr '\n' ';')); unstick --kill it, or wait"
  fi
fi
if [ -f "$d/meta" ] && [ "$replace" != 1 ]; then
  if [ -f "$d/exit" ]; then
    refuse "a finished worker's record is here (its stream is close-out evidence); pick a new name, or --replace to archive it"
  fi
  refuse "a previous launch left no exit record (killed?); unstick it, or --replace"
fi
if [ -z "$cwd" ]; then
  repo=$(expand_tilde "$repo")
  cwd="$repo-worktrees/$name"
  if [ ! -d "$cwd" ]; then
    # Bounded: a stalling origin must not hold the worker lock (or, below, an archived record)
    # indefinitely.
    bounded "$fetch_timeout" git -C "$repo" fetch -q origin >/dev/null; frc=$?
    [ "$frc" -ne 124 ] || refuse "git fetch in $repo timed out after ${fetch_timeout}s"
    [ "$frc" -eq 0 ] || refuse "fetch failed in $repo"
    git -C "$repo" worktree add -q "$cwd" -b "$branch" "$base" 2>&1 || refuse "worktree add failed"
  else
    # An existing directory is reused only when it is the worktree the caller described.
    have=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ "$have" = "$branch" ] || refuse "$cwd exists but is on '${have:-no branch}', not $branch; remove it, or pass it explicitly with --cwd"
    common=$(cd "$cwd" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
    want=$(cd "$repo" 2>/dev/null && cd "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null && pwd -P)
    [ -n "$common" ] && [ "$common" = "$want" ] || refuse "$cwd exists but is not a worktree of $repo (common dir ${common:-unknown}); remove it, or pass it explicitly with --cwd"
    echo "notice: reusing existing worktree $cwd (on $branch)"
  fi
else
  cwd=$(expand_tilde "$cwd")
fi
[ -d "$cwd" ] || refuse "no such directory $cwd"
# One live worker per worktree on this box: two CLIs in one checkout are the two-writer
# condition unstick refuses, under different names. Compared by resolved path, and under a
# box-wide launch lock held from this scan until this record's meta (its ownership claim)
# is written, so two launches under different names cannot both pass the scan.
msg=$(take_lock "$STATE/launch.lock" 120 "launch lock") || refuse "another launch on this box is publishing its record ($msg)"
blaunch="$STATE/launch.lock"   # set only once acquired: on_exit must never release another holder's lock
canon_cwd=$(cd "$cwd" 2>/dev/null && pwd -P); cwd="$canon_cwd"   # the record holds the resolved absolute path
for om in "$WORKERS"/*/meta; do
  [ -f "$om" ] || continue
  oname=$(basename "$(dirname "$om")"); [ "$oname" = "$name" ] && continue
  ocwd=$(sed -n 's/^cwd=//p' "$om" | head -n1); [ -n "$ocwd" ] || continue
  [ "$(cd "$ocwd" 2>/dev/null && pwd -P)" = "$canon_cwd" ] || continue
  running "$oname" && refuse "worktree $cwd is already owned by live worker $oname on this box; wait for it, unstick --kill it, or use another worktree"
done
mkdir -p "$d" 2>/dev/null || refuse "cannot create the worker record at $d (a file in the way, or unwritable)"
if [ -f "$d/meta" ]; then
  # --replace keeps the previous record whole under $STATE/replaced/ (evidence), and a refusal
  # below puts it back; nothing of it is truncated in place.
  mkdir -p "$STATE/replaced" 2>/dev/null; archive="$STATE/replaced/$name-$stamp"
  if ! mv "$d" "$archive" 2>/dev/null || [ ! -d "$archive" ]; then
    archive=""; refuse "cannot archive the previous record to $STATE/replaced/ (unwritable, or a file in the way); nothing was changed"
  fi
  # From here the old record lives in $archive; any refusal puts it back whole.
  refuse() { rm -f "$incoming"; rm -rf "$d"; mv "$archive" "$d" 2>/dev/null; echo "LAUNCH REFUSED $BOX/$name: $* (previous record restored)"; exit 1; }
  mkdir -p "$d" || refuse "cannot start a fresh record at $d"
fi
# Every record mutation is checked, and the brief is in place before any evidence is truncated.
[ ! -d "$d/brief.md" ] || refuse "cannot install the brief: $d/brief.md is a directory"
mv -f "$incoming" "$d/brief.md" 2>/dev/null && [ -f "$d/brief.md" ] || refuse "cannot install the brief at $d/brief.md"
{ : > "$d/stream.jsonl" && : > "$d/stderr.log" && rm -f "$d/exit" && [ ! -e "$d/exit" ]; } 2>/dev/null ||
  refuse "cannot initialize the worker record under $d"
# The CLI line itself, written to a file tmux runs: nothing from the brief is ever a shell word.
{
  printf 'cd %q || { echo 97 > %q; exit 97; }\n' "$cwd" "$d/exit"
  case "$kind" in
    claude) printf 'claude -p --output-format stream-json --verbose --dangerously-skip-permissions --session-id %q' "$sid" ;;
    codex)  printf 'codex exec --json --yolo -C %q -o %q' "$cwd" "$d/last-message.md" ;;
  esac
  for a in "$@"; do printf ' %q' "$a"; done
  [ "$kind" = codex ] && printf ' -'
  printf ' < %q >> %q 2>> %q\n' "$d/brief.md" "$d/stream.jsonl" "$d/stderr.log"
  printf 'echo $? > %q\n' "$d/exit"
} > "$d/run.sh" || refuse "cannot write $d/run.sh"
{
  echo "kind=$kind"; echo "cwd=$cwd"; echo "box=$(hostname -s)"; echo "coordinator=$coord"
  echo "launched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "resumes=0"; echo "turn_offset=0"
  if [ -n "$sid" ]; then echo "session=$sid"; fi
} > "$d/meta" || refuse "cannot write $d/meta"
tm new-session -d -s "iw-$name" "bash $(printf '%q' "$d/run.sh")" || refuse "tmux failed"
started=1
# Ownership is now visible as a live session; the box-wide lock can go.
release_lock "$blaunch"; blaunch=""
if [ "$kind" = codex ]; then
  # The thread id is the resume address; it is the first event, but the exec takes a moment. If
  # this connection drops before it is recorded, session_of recovers it from the stream later.
  for i in $(seq 1 60); do
    sid=$(jq -Rr 'fromjson? | select(.type=="thread.started") | .thread_id' "$d/stream.jsonl" 2>/dev/null | head -n1)
    [ -n "$sid" ] && break
    [ -f "$d/exit" ] && break
    sleep 1
  done
  [ -n "$sid" ] && echo "session=$sid" >> "$d/meta"
fi
echo "LAUNCHED $BOX/$name kind=$kind session=${sid:-unknown} cwd=$cwd stream=$d/stream.jsonl${archive:+ replaced=$archive}"
EOF
  } | run_on "$box" "$name" "$kind" "$cwd" "$repo" "$branch" "$base" "$sid" "$(hostname -s)" "$replace" "$stamp" "${FLEET_FETCH_TIMEOUT:-300}" "$@"
  local rc=$?
  if unreachable "$rc"; then echo "LAUNCH UNREACHABLE $box"; exit 4; fi
  exit "$rc"
}

# ---------------------------------------------------------------------------------------------
# The verdict of a finished worker, from its files. Prints one line; exit 0 clean, 1 failed,
# 3 no exit record (the session is gone but nothing wrote the code: killed, or never started).
verdict_script() {
  cat <<'EOF'
verdict() {
  local name="$1" d="$WORKERS/$1" kind rc summary
  kind=$(meta_get "$d" kind)
  if [ ! -f "$d/exit" ]; then
    echo "VANISHED $BOX/$name: no exit record (killed, or the CLI never started; an orphaned CLI ran on past tmux if the stream moved -- see $d/stderr.log)"; return 3
  fi
  rc=$(cat "$d/exit")
  # Only THIS turn's events count: the stream is append-only across resumes, so the verdict
  # reads past the turn_offset the launch/unstick recorded; a turn with no terminal event of
  # its own is not a success whatever the exit code said.
  local off; off=$(meta_get "$d" turn_offset); off=${off:-0}
  turn() { tail -n +"$((off + 1))" "$d/stream.jsonl" 2>/dev/null; }
  case "$kind" in
    claude) summary=$(turn | jq -Rr 'fromjson? | select(.type=="result") | "\(.subtype) is_error=\(.is_error) turns=\(.num_turns) " + ((.result // "")|tostring|.[0:200]|gsub("\n";" "))' 2>/dev/null | tail -n1)
            ok_event=$(printf '%s' "$summary" | grep -c 'is_error=false') ;;
    codex)  summary=$(turn | jq -Rr 'fromjson? | select(.type=="turn.completed" or .type=="turn.failed") | .type + " " + ((.error.message // "")|tostring|.[0:200])' 2>/dev/null | tail -n1)
            ok_event=$(printf '%s' "$summary" | grep -c '^turn.completed')
            last=$(turn | jq -Rr 'fromjson? | select(.type=="item.completed" and .item.type=="agent_message") | .item.text' 2>/dev/null | tail -n1 | cut -c1-200)
            [ -n "$last" ] && summary="$summary | $last" ;;
  esac
  [ -n "$summary" ] || summary="no terminal event in the stream"
  if [ "$rc" = 0 ] && [ "${ok_event:-0}" -gt 0 ]; then
    echo "DONE $BOX/$name exit=0 $summary"; return 0
  fi
  echo "FAILED $BOX/$name exit=$rc $summary $(tail -n 2 "$d/stderr.log" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"; return 1
}
EOF
}

cmd_attach() {
  local box="${1:-}" name="${2:-}"; [ -n "$box" ] && [ -n "$name" ] || die "attach: <box> <name> required"
  valid_name "$name" || die "attach: name must be [A-Za-z0-9._-]+"
  shift 2
  local interval=30
  while [ $# -gt 0 ]; do
    case "$1" in --interval) interval="${2:-30}"; shift ;; *) die "attach: unknown option $1" ;; esac; shift
  done
  case "$interval" in ''|*[!0-9]*|0) die "attach: --interval must be a positive number of seconds" ;; esac
  # The far side waits; a dropped connection (box asleep, tailnet blip) is retried here, from the
  # coordinator, because the worker is still running on its box regardless.
  local tries=0 rc
  while :; do
    { prelude "$box"; verdict_script; cat <<'EOF'
name="$1" interval="$2"; d="$WORKERS/$name"
[ -f "$d/meta" ] || { echo "UNKNOWN $BOX/$name: never launched here"; exit 3; }
started=$(now); last=$started
while running "$name"; do
  sleep "$interval"
  t=$(now)
  if [ $((t - last)) -ge 900 ]; then
    echo "still running: $BOX/$name, $(( (t - started) / 60 )) min attached, stream $(( t - $(mtime "$d/stream.jsonl") ))s quiet"
    last=$t
  fi
done
verdict "$name"
EOF
    } | run_on "$box" "$name" "$interval"
    rc=$?
    if unreachable "$rc"; then
      tries=$((tries + 1))
      if [ "$tries" -ge 40 ]; then echo "ATTACH UNREACHABLE $box/$name: gave up after $tries attempts"; exit 4; fi
      echo "attach: $box unreachable (attempt $tries), retrying in 60s"
      sleep 60
      continue
    fi
    exit "$rc"
  done
}

# ---------------------------------------------------------------------------------------------
cmd_status() {
  local box="${1:-}" name="${2:-}"; [ -n "$box" ] && [ -n "$name" ] || die "status: <box> <name> required"
  valid_name "$name" || die "status: name must be [A-Za-z0-9._-]+"
  { prelude "$box"; cat <<'EOF'
name="$1"; d="$WORKERS/$name"
[ -f "$d/meta" ] || { echo "UNKNOWN $BOX/$name: never launched here"; exit 3; }
kind=$(meta_get "$d" kind); cwd=$(meta_get "$d" cwd)
state=$(state_of "$name")
quiet=$(( $(now) - $(mtime "$d/stream.jsonl") ))
case "$kind" in
  claude) last=$(tail -n 1 "$d/stream.jsonl" 2>/dev/null | jq -Rr 'fromjson? | .type + (if .type=="assistant" then ":" + ([.message.content[]? | .type] | join(",")) else "" end)' 2>/dev/null) ;;
  codex)  last=$(tail -n 1 "$d/stream.jsonl" 2>/dev/null | jq -Rr 'fromjson? | .type + (if .item then ":" + .item.type else "" end)' 2>/dev/null) ;;
esac
events=$(grep -c . "$d/stream.jsonl" 2>/dev/null); events=${events:-0}
if git -C "$cwd" rev-parse --git-dir >/dev/null 2>&1; then
  wt="head=$(git -C "$cwd" log -1 --format='%h %cr' 2>/dev/null) dirty=$(git -C "$cwd" status --porcelain 2>/dev/null | grep -c .) branch=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)"
else
  wt="cwd not a git repo (or gone)"
fi
echo "$state $BOX/$name kind=$kind session=$(session_of "$d") stream: ${events} events, ${quiet}s quiet, last=${last:-none} | $wt | resumes=$(meta_get "$d" resumes) stderr=$(wc -c < "$d/stderr.log" 2>/dev/null | tr -d ' ')B"
EOF
  } | run_on "$box" "$name"
  local rc=$?
  if unreachable "$rc"; then echo "STATUS UNREACHABLE $box/$name"; exit 4; fi
  exit "$rc"
}

# ---------------------------------------------------------------------------------------------
cmd_log() {
  local box="${1:-}" name="${2:-}"; [ -n "$box" ] && [ -n "$name" ] || die "log: <box> <name> required"
  valid_name "$name" || die "log: name must be [A-Za-z0-9._-]+"
  shift 2
  local n=40
  while [ $# -gt 0 ]; do case "$1" in -n) n="${2:-40}"; shift ;; *) die "log: unknown option $1" ;; esac; shift; done
  { prelude "$box"; cat <<'EOF'
name="$1" n="$2"; d="$WORKERS/$name"
[ -f "$d/meta" ] || { echo "UNKNOWN $BOX/$name: never launched here"; exit 3; }
case "$(meta_get "$d" kind)" in
  claude) jq -Rr 'fromjson? | select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$d/stream.jsonl" 2>/dev/null | tail -n "$n" ;;
  codex)  jq -Rr 'fromjson? | select(.type=="item.completed" and .item.type=="agent_message") | .item.text' "$d/stream.jsonl" 2>/dev/null | tail -n "$n" ;;
esac
if [ -s "$d/stderr.log" ]; then echo "--- stderr (tail):"; tail -n 5 "$d/stderr.log"; fi
EOF
  } | run_on "$box" "$name" "$n"
  local rc=$?
  if unreachable "$rc"; then echo "LOG UNREACHABLE $box/$name"; exit 4; fi
  exit "$rc"
}

# ---------------------------------------------------------------------------------------------
cmd_unstick() {
  local box="${1:-}" name="${2:-}"; [ -n "$box" ] && [ -n "$name" ] || die "unstick: <box> <name> required"
  valid_name "$name" || die "unstick: name must be [A-Za-z0-9._-]+"
  shift 2
  local msg="" kill=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --message) msg="${2:-}"; shift ;;
      --kill) kill=1 ;;
      --) shift; break ;;
      *) die "unstick: unknown option $1" ;;
    esac
    shift
  done
  [ -n "$msg" ] && [ -r "$msg" ] || die "unstick: --message <readable file>"
  anchor_gate UNSTICK "$box/$name" 1 || exit $?
  local stamp; stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  put_file "$box" "$msg" "$STATE/incoming/$name-$stamp.md"
  local prc2=$?
  if unreachable "$prc2"; then echo "UNSTICK UNREACHABLE $box"; exit 4; fi
  [ "$prc2" -eq 0 ] || { echo "UNSTICK REFUSED $box/$name: cannot stage the message under the worker state dir on $box (unwritable, or a file in the way)"; exit 1; }
  # Re-read the lease after the upload, right before the worker is touched: an adoption that
  # completed meanwhile fences this intervention (residual window: one ssh round trip).
  anchor_gate UNSTICK "$box/$name" 1 || exit $?
  { prelude "$box"; cat <<'EOF'
name="$1" kill="$2" stamp="$3"; shift 3
d="$WORKERS/$name"; staged="$STATE/incoming/$name-$stamp.md"
[ -f "$d/meta" ] || { rm -f "$staged"; echo "UNSTICK REFUSED $BOX/$name: never launched here"; exit 1; }
# Same critical section as launch: liveness checks through tmux creation, one at a time.
mkdir -p "$STATE/locks"; wlock="$STATE/locks/$name"
msg=$(take_lock "$wlock" 0 "lock") || { rm -f "$staged"; echo "UNSTICK REFUSED $BOX/$name: another launch or unstick of this name is in progress ($msg)"; exit 1; }
started=0; blaunch=""; backed=0
on_exit() {
  # Only backups THIS invocation made are ever restored, and only when the session does not
  # exist (the session is the truth); when it does, the backups are stale and are removed
  # so no later refusal can restore them over a completed turn.
  if [ "$backed" = 1 ]; then
    if [ "$started" != 1 ] && ! alive "$name"; then
      [ -e "$d/exit.prev" ] && mv -f "$d/exit.prev" "$d/exit" 2>/dev/null
      [ -e "$d/meta.prev" ] && mv -f "$d/meta.prev" "$d/meta" 2>/dev/null
      rm -f "$staged"
    else
      rm -f "$d/exit.prev" "$d/meta.prev"
    fi
  fi
  release_lock "$wlock"; [ -n "$blaunch" ] && release_lock "$blaunch"
}
trap on_exit EXIT; trap 'exit 143' TERM HUP INT
# The message moves into the record only now, under the lock: a --replace that archived the
# record before we held it cannot have taken it along.
mkdir -p "$d/messages" && mv -f "$staged" "$d/messages/$stamp.md" 2>/dev/null && [ -f "$d/messages/$stamp.md" ] ||
  { echo "UNSTICK REFUSED $BOX/$name: cannot place the message under $d/messages"; exit 1; }
kind=$(meta_get "$d" kind); cwd=$(meta_get "$d" cwd); sid=$(session_of "$d")
[ -n "$sid" ] || { echo "UNSTICK REFUSED $BOX/$name: no session id in meta or stream"; exit 1; }
[ -d "$cwd" ] || { echo "UNSTICK REFUSED $BOX/$name: recorded working directory $cwd is gone (worktree removed or renamed); nothing was changed"; exit 1; }
# The same one-live-worker-per-worktree rule as launch, under the same box-wide lock: a
# resume must not start beside another worker that took this worktree meanwhile.
msg=$(take_lock "$STATE/launch.lock" 120 "launch lock") || { echo "UNSTICK REFUSED $BOX/$name: another launch on this box is publishing its record ($msg)"; exit 1; }
blaunch="$STATE/launch.lock"
canon_cwd=$(cd "$cwd" 2>/dev/null && pwd -P)
for om in "$WORKERS"/*/meta; do
  [ -f "$om" ] || continue
  oname=$(basename "$(dirname "$om")"); [ "$oname" = "$name" ] && continue
  ocwd=$(sed -n 's/^cwd=//p' "$om" | head -n1); [ -n "$ocwd" ] || continue
  [ "$(cd "$ocwd" 2>/dev/null && pwd -P)" = "$canon_cwd" ] || continue
  running "$oname" && { echo "UNSTICK REFUSED $BOX/$name: worktree $cwd is now owned by live worker $oname on this box"; exit 1; }
done
grep -q '^session=' "$d/meta" || echo "session=$sid" >> "$d/meta"
if alive "$name"; then
  if [ "$kill" != 1 ]; then
    echo "UNSTICK REFUSED $BOX/$name: still running -- a resume beside a live exec gives the branch two writers; pass --kill to stop it first"; exit 1
  fi
  tm kill-session -t "=iw-$name"
  for i in $(seq 1 30); do alive "$name" || break; sleep 1; done
fi
# The tmux session is gone; make sure the CLI it ran is too (it could have been reparented).
# A claude worker carries its session id on its command line; a codex worker's first exec
# carries only this worker's state dir (-o), so match either. An orphan is still a live
# writer: it is refused without --kill exactly like a live tmux session.
pat=$(live_pat "$name")
if [ "$kill" != 1 ] && pgrep -f -- "$pat" >/dev/null 2>&1; then
  echo "UNSTICK REFUSED $BOX/$name: tmux is gone but a CLI still runs ($(pgrep -fl -- "$pat" | head -n 2 | tr '\n' ';')); pass --kill to stop it first"; exit 1
fi
for i in $(seq 1 30); do
  pgrep -f -- "$pat" >/dev/null 2>&1 || break
  [ "$i" -eq 1 ] && pkill -TERM -f -- "$pat" 2>/dev/null
  sleep 1
done
if pgrep -f -- "$pat" >/dev/null 2>&1; then
  echo "UNSTICK REFUSED $BOX/$name: a process still carries session $sid after TERM: $(pgrep -fl -- "$pat" | head -n 3 | tr '\n' ';')"; exit 1
fi
{
  printf 'cd %q || { echo 97 > %q; exit 97; }\n' "$cwd" "$d/exit"
  case "$kind" in
    claude) printf 'claude -p --output-format stream-json --verbose --dangerously-skip-permissions --resume %q' "$sid" ;;
    codex)  printf 'codex exec resume %q --yolo --json' "$sid" ;;
  esac
  for a in "$@"; do printf ' %q' "$a"; done
  [ "$kind" = codex ] && printf ' -'
  printf ' < %q >> %q 2>> %q\n' "$d/messages/$stamp.md" "$d/stream.jsonl" "$d/stderr.log"
  printf 'echo $? > %q\n' "$d/exit"
} > "$d/run.sh" 2>/dev/null && [ -s "$d/run.sh" ] || { echo "UNSTICK REFUSED $BOX/$name: cannot write $d/run.sh (a directory in its place, or unwritable)"; exit 1; }
n=$(meta_get "$d" resumes); n=$(( ${n:-0} + 1 ))
# meta is set aside with exit below and restored together with it if tmux refuses.
rm -f "$d/exit.prev" "$d/meta.prev"   # leftovers from an interrupted earlier run are not ours to restore
cp -p "$d/meta" "$d/meta.prev" 2>/dev/null || { echo "UNSTICK REFUSED $BOX/$name: cannot back up $d/meta"; exit 1; }
backed=1
# The verdict of THIS turn must come from events appended after this point, never from the
# previous turn's terminal event: record where the new turn's output starts.
off=$(grep -c '' "$d/stream.jsonl" 2>/dev/null); off=${off:-0}
grep -q '^turn_offset=' "$d/meta" || echo "turn_offset=0" >> "$d/meta"
sed -i.bak "s/^resumes=.*/resumes=$n/; s/^turn_offset=.*/turn_offset=$off/" "$d/meta" 2>/dev/null && rm -f "$d/meta.bak" && grep -q "^resumes=$n\$" "$d/meta" && grep -q "^turn_offset=$off\$" "$d/meta" ||
  { mv -f "$d/meta.prev" "$d/meta"; echo "UNSTICK REFUSED $BOX/$name: cannot update $d/meta"; exit 1; }
# The previous terminal state is evidence until the resume has really started: set it aside,
# and put it back (with the previous meta) if tmux refuses.
if [ -e "$d/exit" ]; then mv -f "$d/exit" "$d/exit.prev" 2>/dev/null && [ ! -e "$d/exit" ] || { mv -f "$d/meta.prev" "$d/meta"; echo "UNSTICK REFUSED $BOX/$name: cannot set aside $d/exit"; exit 1; }; fi
if ! tm new-session -d -s "iw-$name" "bash $(printf '%q' "$d/run.sh")"; then
  [ -e "$d/exit.prev" ] && mv -f "$d/exit.prev" "$d/exit"
  mv -f "$d/meta.prev" "$d/meta"
  echo "UNSTICK REFUSED $BOX/$name: tmux failed (previous exit record and meta kept)"; exit 1
fi
started=1
release_lock "$blaunch"; blaunch=""
rm -f "$d/exit.prev" "$d/meta.prev"
echo "RESUMED $BOX/$name kind=$kind session=$sid resume=$n message=$d/messages/$stamp.md"
EOF
  } | run_on "$box" "$name" "$kill" "$stamp" "$@"
  local rc=$?
  if unreachable "$rc"; then echo "UNSTICK UNREACHABLE $box/$name"; exit 4; fi
  exit "$rc"
}

# ---------------------------------------------------------------------------------------------
cmd_ls() {
  local boxes="$*" box rc worst=0 b
  if [ -z "$boxes" ]; then
    boxes=local
    for b in $BOXES; do is_local "$b" || boxes="$boxes $b"; done
  fi
  for box in $boxes; do
    { prelude "$box"; cat <<'EOF'
[ -d "$WORKERS" ] || { echo "$BOX: no workers"; exit 0; }
found=0
for d in "$WORKERS"/*/; do
  [ -f "$d/meta" ] || continue
  found=1
  name=$(basename "$d")
  state=$(state_of "$name")
  echo "$BOX/$name $state kind=$(meta_get "$d" kind) launched=$(meta_get "$d" launched_at) by=$(meta_get "$d" coordinator) quiet=$(( $(now) - $(mtime "$d/stream.jsonl") ))s cwd=$(meta_get "$d" cwd)"
done
[ "$found" = 1 ] || echo "$BOX: no workers"
EOF
    } | run_on "$box"
    rc=$?
    if unreachable "$rc"; then echo "$box: unreachable"; worst=4
    elif [ "$rc" -ne 0 ]; then echo "$box: inventory failed (exit $rc)"; [ "$worst" -eq 4 ] || worst=1; fi
  done
  exit "$worst"
}

# ---------------------------------------------------------------------------------------------
# Placement input: what each fleet machine is doing right now, from the flotilla dashboard.
cmd_load() {
  local json
  json=$(curl -s -m 10 "$FLOTILLA/api/fleet") || { echo "LOAD UNREACHABLE $FLOTILLA"; exit 4; }
  printf '%s' "$json" | jq -r '
    .machines[] | .name as $m | .endpoints | to_entries[]
    | select(.value.kind == "unix")
    | "\($m)\t\(.value.host // .key)\tok=\(.value.ok)\tcpu5=\(.value.avg.m5.cpu_pct // "?")%\tgpu5=\(.value.avg.m5.gpu_util_pct // "-")%\tdune=\(.value.data.counts.dune // "?")\tclaude=\(.value.data.sessions.claude // [] | length)\tcodex=\(.value.data.sessions.codex // [] | length)\tgpu=\(.value.data.gpu.name // "-")"' 2>/dev/null ||
    { echo "LOAD: unexpected payload from $FLOTILLA/api/fleet"; exit 1; }
}

# ---------------------------------------------------------------------------------------------
# Far-side: take the lease lock (shared with claim --take and release), verify the caller
# still holds the lease, then run the mutation. Args: verb token lockwait, then the action's.
lease_mutation_prelude() {
  cat <<'EOF'
verb="$1" token="$2" lockwait="$3"; shift 3
mkdir -p "$ANCHOR_STATE" 2>/dev/null; lease="$ANCHOR_STATE/COORDINATOR"; lock="$lease.lock"
msg=$(take_lock "$lock" "$lockwait" "$verb FAILED: lease lock on $BOX") || { echo "$msg"; exit 1; }
trap 'release_lock "$lock"' EXIT
held=$(sed -n 's/^token=//p' "$lease" 2>/dev/null); hhost=$(sed -n 's/^host=//p' "$lease" 2>/dev/null)
[ -n "$token" ] && [ "$held" = "$token" ] || { echo "$verb REFUSED fleet: coordinator lease held by ${hhost:-nobody} -- not you (adopted since your gate?)"; exit 1; }
EOF
}

cmd_halt() {
  local reason="$*"; [ -n "$reason" ] || die "halt: give the reason (what regressed, who owns the fix)"
  check_identity
  { prelude "$ANCHOR"; lease_mutation_prelude; cat <<'EOF'
if ! printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" > "$ANCHOR_STATE/HALT" 2>/dev/null || [ ! -f "$ANCHOR_STATE/HALT" ]; then
  echo "HALT FAILED: cannot write $ANCHOR_STATE/HALT on $BOX -- the fleet is NOT halted"; exit 1
fi
echo "HALTED: launches refused until resume-launches -- $1"
EOF
  } | run_on "$ANCHOR" HALT "$(my_token)" "${FLEET_LOCK_WAIT:-10}" "$reason"
  local rc=$?; if unreachable "$rc"; then echo "HALT UNREACHABLE $ANCHOR"; exit 4; fi; exit "$rc"
}

cmd_resume_launches() {
  check_identity
  { prelude "$ANCHOR"; lease_mutation_prelude; cat <<'EOF'
f="$ANCHOR_STATE/HALT"
if [ -f "$f" ]; then
  was=$(cat "$f"); rm -f "$f" 2>/dev/null
  [ ! -e "$f" ] || { echo "RESUME-LAUNCHES FAILED: cannot remove $f on $BOX -- still halted"; exit 1; }
  echo "RESUMED launches (was: $was)"
else echo "launches were not halted"; fi
EOF
  } | run_on "$ANCHOR" RESUME-LAUNCHES "$(my_token)" "${FLEET_LOCK_WAIT:-10}"
  local rc=$?; if unreachable "$rc"; then echo "RESUME-LAUNCHES UNREACHABLE $ANCHOR"; exit 4; fi; exit "$rc"
}

cmd_halted() {
  { prelude "$ANCHOR"; cat <<'EOF'
f="$ANCHOR_STATE/HALT"
if [ -f "$f" ]; then echo "HALTED $(cat "$f")"; exit 1; else echo "launches open"; exit 0; fi
EOF
  } | run_on "$ANCHOR"
  local rc=$?; if unreachable "$rc"; then echo "HALTED? UNREACHABLE $ANCHOR"; exit 4; fi; exit "$rc"
}

# ---------------------------------------------------------------------------------------------
# The coordinator lease: one file on the anchor, created with O_EXCL (noclobber) so two
# coordinators starting at once cannot both win, naming the holder's host and token.
cmd_claim() {
  check_identity
  local take=0
  while [ $# -gt 0 ]; do case "$1" in --take) take=1 ;; *) die "claim: unknown option $1" ;; esac; shift; done
  local tf; tf=$(token_file)
  if [ ! -s "$tf" ]; then
    mkdir -p "$(dirname "$tf")" 2>/dev/null
    # noclobber: two first claims of one identity race to create it; the loser reads the winner's.
    local tok; tok=$(gen_uuid) || tok="$(hostname -s)-$(date +%s)-$$"
    ( set -o noclobber; printf '%s\n' "$tok" > "$tf" ) 2>/dev/null || true
  fi
  [ -s "$tf" ] || { echo "CLAIM REFUSED: cannot persist this coordinator's token at $tf"; exit 1; }
  { prelude "$ANCHOR"; cat <<'EOF'
host="$1" token="$2" take="$3" lockwait="$4"
mkdir -p "$ANCHOR_STATE"; lease="$ANCHOR_STATE/COORDINATOR"
record() { printf 'host=%s\ntoken=%s\nsince=%s\n' "$host" "$token" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"; }
# Every lease mutation - first claim, idempotent re-claim, takeover - runs under one lock, so
# a claim cannot slip between a release and a queued takeover and leave two believers.
lock="$lease.lock"
msg=$(take_lock "$lock" "$lockwait" "CLAIM FAILED: lease lock on $BOX") || { echo "$msg"; exit 1; }
trap 'release_lock "$lock"' EXIT
verified() { [ "$(sed -n 's/^token=//p' "$lease" 2>/dev/null)" = "$token" ]; }
# The record is written and verified in a temp file first, then published atomically (link for
# a first claim, rename for a takeover), so a failed write never truncates a valid lease.
tmp="$lease.tmp.$$"; trap 'rm -f "$tmp"; release_lock "$lock"' EXIT
# ln/mv onto a DIRECTORY would publish the record inside it; refuse that shape outright.
[ ! -d "$lease" ] || { echo "CLAIM FAILED: could not write the lease at $lease on $BOX (a directory in its place)"; exit 1; }
staged() { record > "$tmp" 2>/dev/null && [ "$(sed -n 's/^token=//p' "$tmp" 2>/dev/null)" = "$token" ]; }
if [ ! -f "$lease" ]; then
  if staged && ln "$tmp" "$lease" 2>/dev/null && verified; then echo "CLAIMED coordinator lease on $BOX for $host"; exit 0; fi
  echo "CLAIM FAILED: could not write the lease at $lease on $BOX (a directory in its place, or unwritable)"; exit 1
fi
held=$(sed -n 's/^token=//p' "$lease"); hhost=$(sed -n 's/^host=//p' "$lease"); since=$(sed -n 's/^since=//p' "$lease")
if [ "$held" = "$token" ]; then echo "CLAIMED already held by $host since $since"; exit 0; fi
if [ "$take" = 1 ]; then
  if staged && mv -f "$tmp" "$lease" 2>/dev/null && verified; then
    echo "CLAIMED (adopted) coordinator lease on $BOX for $host -- was ${hhost:-nobody} since ${since:-never}"; exit 0
  fi
  echo "CLAIM FAILED: could not write the lease at $lease on $BOX (a directory in its place, or unwritable) -- not adopted; the previous lease is intact"; exit 1
fi
echo "CLAIM REFUSED: coordinator lease held by $hhost since $since -- a wave is in flight; adopt with --take only if that coordinator is gone"
exit 1
EOF
  } | run_on "$ANCHOR" "$(hostname -s)/$(coordinator_id)" "$(cat "$tf")" "$take" "${FLEET_LOCK_WAIT:-10}"
  local rc=$?; if unreachable "$rc"; then echo "CLAIM UNREACHABLE $ANCHOR"; exit 4; fi; exit "$rc"
}

cmd_release() {
  check_identity
  { prelude "$ANCHOR"; cat <<'EOF'
token="$1" lockwait="$2"; lease="$ANCHOR_STATE/COORDINATOR"
# The token check and the removal happen under the same lock takeovers use, so a release
# racing an adoption cannot delete the successor's freshly written lease.
lock="$lease.lock"
msg=$(take_lock "$lock" "$lockwait" "RELEASE FAILED: lease lock on $BOX") || { echo "$msg -- the lease is still held"; exit 1; }
trap 'release_lock "$lock"' EXIT
[ -f "$lease" ] || { echo "RELEASE: no lease held"; exit 0; }
held=$(sed -n 's/^token=//p' "$lease"); hhost=$(sed -n 's/^host=//p' "$lease")
[ "$held" = "$token" ] || { echo "RELEASE REFUSED: lease held by $hhost, not you"; exit 1; }
if rm -f "$lease" 2>/dev/null && [ ! -e "$lease" ]; then echo "RELEASED coordinator lease on $BOX"; else echo "RELEASE FAILED: could not remove $lease on $BOX -- the lease is still held"; exit 1; fi
EOF
  } | run_on "$ANCHOR" "$(my_token)" "${FLEET_LOCK_WAIT:-10}"
  local rc=$?; if unreachable "$rc"; then echo "RELEASE UNREACHABLE $ANCHOR"; exit 4; fi; exit "$rc"
}

cmd_coordinator() {
  check_identity
  { prelude "$ANCHOR"; cat <<'EOF'
token="$1"; lease="$ANCHOR_STATE/COORDINATOR"
[ -f "$lease" ] || { echo "COORDINATOR: nobody holds the lease on $BOX"; exit 3; }
held=$(sed -n 's/^token=//p' "$lease"); hhost=$(sed -n 's/^host=//p' "$lease"); since=$(sed -n 's/^since=//p' "$lease")
if [ -n "$token" ] && [ "$held" = "$token" ]; then echo "COORDINATOR: you ($hhost) since $since"; exit 0; fi
echo "COORDINATOR: $hhost since $since (not you)"; exit 1
EOF
  } | run_on "$ANCHOR" "$(my_token)"
  local rc=$?; if unreachable "$rc"; then echo "COORDINATOR UNREACHABLE $ANCHOR"; exit 4; fi; exit "$rc"
}

# ---------------------------------------------------------------------------------------------
cmd="${1:-}"; [ -n "$cmd" ] && shift
case "$cmd" in
  preflight) cmd_preflight "$@" ;;
  launch) cmd_launch "$@" ;;
  attach) cmd_attach "$@" ;;
  status) cmd_status "$@" ;;
  log) cmd_log "$@" ;;
  unstick) cmd_unstick "$@" ;;
  ls) cmd_ls "$@" ;;
  load) cmd_load "$@" ;;
  halt) cmd_halt "$@" ;;
  resume-launches) cmd_resume_launches "$@" ;;
  halted) cmd_halted "$@" ;;
  claim) cmd_claim "$@" ;;
  release) cmd_release "$@" ;;
  coordinator) cmd_coordinator "$@" ;;
  *) sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
