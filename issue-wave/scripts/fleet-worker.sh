#!/usr/bin/env bash
# The fleet half of the issue-wave skill: one coordinator launches workers onto any box in the
# fleet and supervises them there, with the same commands whether the box is the coordinator's
# own machine or a remote one reached over ssh (self-improve#12).
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
#   - the skill-freshness preflight (self-improve#11) runs on the box that will run the worker,
#     because that box's ~/.claude/skills symlinks serve whatever its checkout holds;
#   - `unstick` refuses to resume a session whose exec is still alive: a resume beside a live exec
#     gives the branch two writers, and the quiet stream that prompted the unstick does not prove
#     the exec cannot still act;
#   - `halt` is the stop-the-world mechanism: a file the launcher checks, so "launch nothing new"
#     after an integration regression is enforced rather than remembered.
#
# Usage:
#   fleet-worker.sh preflight <box> [--codex] [--no-probe]
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
# <box> is an ssh destination (rog-nv-wsl, minix-amd-wsl), or `local` / the value of
# FLEET_LOCAL_BOX (default mac-studio) for the coordinator's own machine.
#
# Exit: 0 ok | 1 the fact does not hold (refused, worker failed, stale) | 2 usage |
#       3 worker vanished without an exit record | 4 the box never answered.
#
# Env: FLEET_LOCAL_BOX (mac-studio), FLEET_BOXES (the whole fleet, "mac-studio rog-nv-wsl
# minix-amd-wsl"; `ls` sweeps it minus the local box), FLEET_SKILLS_REPO (~/self-improve), ISSUE_WAVE_STATE (~/.local/state/issue-wave),
# FLEET_TMUX_SOCKET (tmux -L name; tests isolate with it), FLEET_FLOTILLA (http://mac-studio:7799).

set -uo pipefail

LOCAL_BOX="${FLEET_LOCAL_BOX:-mac-studio}"
BOXES="${FLEET_BOXES:-mac-studio rog-nv-wsl minix-amd-wsl}"
SKILLS_REPO="${FLEET_SKILLS_REPO:-\$HOME/self-improve}"
STATE="${ISSUE_WAVE_STATE:-\$HOME/.local/state/issue-wave}"
TMUX_SOCKET="${FLEET_TMUX_SOCKET:-}"
FLOTILLA="${FLEET_FLOTILLA:-http://mac-studio:7799}"
SSH_OPTS="-o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=30 -o ServerAliveCountMax=4"

die() { echo "fleet-worker.sh: $*" >&2; exit 2; }

is_local() { [ "$1" = local ] || [ "$1" = "$LOCAL_BOX" ]; }

# Every far-side script starts with this: the same paths, the same tmux invocation, the same
# portable helpers, on macOS and Linux alike, and BOX = the name the coordinator addressed the
# box by, so every line it prints is greppable by that name rather than by a hostname the
# coordinator never typed. Single-quoted heredoc: nothing expands locally.
prelude() {
  printf 'STATE=%s\nSKILLS_REPO=%s\nTMUX_SOCKET=%q\nBOX=%q\n' "$STATE" "$SKILLS_REPO" "$TMUX_SOCKET" "$1"
  cat <<'EOF'
set -uo pipefail
tm() { if [ -n "$TMUX_SOCKET" ]; then tmux -L "$TMUX_SOCKET" "$@"; else tmux "$@"; fi; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
now() { date +%s; }
meta_get() { sed -n "s/^$2=//p" "$1/meta" 2>/dev/null | head -n1; }
# The session id addresses every intervention: from meta when the launch recorded it, else from
# the stream itself (a Codex thread id lands there first; a launch connection can drop between).
session_of() {
  local s; s=$(meta_get "$1" session)
  [ -n "$s" ] || s=$(jq -r 'select(.type=="thread.started") | .thread_id' "$1/stream.jsonl" 2>/dev/null | head -n1)
  [ -n "$s" ] || s=$(jq -r 'select(.type=="system" and .subtype=="init") | .session_id' "$1/stream.jsonl" 2>/dev/null | head -n1)
  printf '%s' "$s"
}
# A literal string as an ERE, for pgrep/pkill -f.
re_lit() { printf '%s' "$1" | sed 's/[][\.*^$+?(){}|/]/\\&/g'; }
alive() { tm has-session -t "iw-$1" 2>/dev/null; }
WORKERS="$STATE/workers"
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
  local box="$1" src="$2" dst="$3"
  if is_local "$box"; then
    bash -c 'mkdir -p "$(dirname "$1")" && cat > "$1"' -- "$(eval echo "$dst")" < "$src"
  else
    # shellcheck disable=SC2086
    ssh $SSH_OPTS "$box" "mkdir -p \"\$(dirname \"$dst\")\" && cat > \"$dst\"" < "$src"
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

valid_name() { case "$1" in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; *) return 0 ;; esac; }

halt_file() { eval echo "$STATE/HALT"; }

# ---------------------------------------------------------------------------------------------
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
  { prelude "$box"; cat <<'EOF'
codex="$1" probe="$2"
refuse=""
note() { refuse="$refuse; $*"; }
repo=$(eval echo "$SKILLS_REPO")
if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
  echo "PREFLIGHT REFUSED $BOX: no skills checkout at $repo"; exit 1
fi
git -C "$repo" fetch -q origin 2>/dev/null || note "fetch failed (offline?)"
# Tracked modifications, and untracked files under the served tree, are divergence to surface.
# Untracked files elsewhere (a stray .claude/ from running claude inside the checkout) are not
# skill text and are only reported.
dirty=$(git -C "$repo" status --porcelain 2>/dev/null)
tracked=$(printf '%s\n' "$dirty" | grep -v '^??' | grep -c . || true)
served=$(printf '%s\n' "$dirty" | grep '^?? ClaudeDesktop/' | grep -c . || true)
other=$(printf '%s\n' "$dirty" | grep '^??' | grep -v '^?? ClaudeDesktop/' | sed 's/^?? //' | tr '\n' ' ')
[ "$tracked" -eq 0 ] || note "$tracked tracked change(s) in $repo"
[ "$served" -eq 0 ] || note "$served untracked file(s) under ClaudeDesktop/"
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null)
[ "$branch" = main ] || note "checked out $branch, not main"
if [ -z "$refuse" ]; then
  git -C "$repo" merge --ff-only -q origin/main >/dev/null 2>&1 || note "main does not fast-forward to origin/main"
fi
head=$(git -C "$repo" rev-parse HEAD 2>/dev/null); up=$(git -C "$repo" rev-parse origin/main 2>/dev/null)
[ "$head" = "$up" ] || note "HEAD $(echo "$head" | cut -c1-9) != origin/main $(echo "$up" | cut -c1-9) (ahead, or offline)"
# The deployed skills must be the symlinks the README installs, into THIS checkout - compared
# as resolved paths, so a link through `..` cannot pass a lexical prefix test.
canon=$(cd "$repo" && pwd -P)
resolved() { [ -L "$1" ] && (cd -P "$1" 2>/dev/null && pwd -P); }
for s in issue-wave ship-pr wait-and-proceed after-merge; do
  t=$(resolved "$HOME/.claude/skills/$s")
  case "$t" in "$canon"/ClaudeDesktop/skills/*) ;; *) note "~/.claude/skills/$s -> ${t:-missing/not a link} (not into $repo)" ;; esac
done
if [ "$codex" = 1 ]; then
  for s in ship-pr wait-and-proceed after-merge; do
    t=$(resolved "$HOME/.codex/skills/$s")
    case "$t" in "$canon"/ClaudeDesktop/skills/*) ;; *) note "~/.codex/skills/$s -> ${t:-missing/not a link} (README's Codex loop not run)" ;; esac
  done
  command -v codex >/dev/null 2>&1 || note "no codex on PATH"
  codex login status >/dev/null 2>&1 || note "codex not logged in"
else
  command -v claude >/dev/null 2>&1 || note "no claude on PATH"
  # `claude auth status` reports loggedIn:true over an expired, unrefreshable OAuth session
  # (observed 2026-09-02 on minix); only a live turn proves the CLI can run headless here.
  if [ "$probe" = 1 ] && command -v claude >/dev/null 2>&1; then
    out=$(cd / && printf 'Reply with the single word ok.' | claude -p --model haiku --output-format json --no-session-persistence 2>&1)
    if ! printf '%s' "$out" | grep -q '"is_error":false'; then
      note "claude cannot run headless: $(printf '%s' "$out" | grep -o '"result":"[^"]*"' | head -n1 | cut -c1-120)"
    fi
  fi
fi
command -v tmux >/dev/null 2>&1 || note "no tmux"
command -v jq >/dev/null 2>&1 || note "no jq"
if [ -n "$refuse" ]; then
  echo "PREFLIGHT REFUSED $BOX: ${refuse#; }${other:+ (untracked outside the served tree, ignored: $other)}"
  exit 1
fi
echo "PREFLIGHT OK $BOX skills=$(echo "$head" | cut -c1-9)${other:+ (untracked outside the served tree, ignored: $other)}"
EOF
  } | run_on "$box" "$codex" "$probe"
  local rc=$?
  if unreachable "$rc"; then echo "PREFLIGHT UNREACHABLE $box"; exit 4; fi
  exit "$rc"
}

# ---------------------------------------------------------------------------------------------
cmd_launch() {
  local box="${1:-}" name="${2:-}"
  [ -n "$box" ] && [ -n "$name" ] || die "launch: <box> <name> required"
  valid_name "$name" || die "launch: name must be [A-Za-z0-9._-]+"
  shift 2
  local kind="" brief="" cwd="" repo="" branch="" base="origin/master" force=0 replace=0
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
  [ -n "$brief" ] && [ -r "$brief" ] || die "launch: --brief <readable file>"
  if [ -z "$cwd" ]; then
    [ -n "$repo" ] && [ -n "$branch" ] || die "launch: --cwd <dir>, or --repo <dir> --branch <branch>"
  fi
  if [ "$force" = 0 ] && [ -f "$(halt_file)" ]; then
    echo "LAUNCH REFUSED $box/$name: launches halted -- $(cat "$(halt_file)")"
    exit 1
  fi
  local sid=""
  if [ "$kind" = claude ]; then
    sid=$(gen_uuid) || { echo "LAUNCH REFUSED $box/$name: cannot generate a session id here (no uuidgen, /proc uuid, or python3)"; exit 1; }
  fi
  # The brief lands beside the record, not on it: the far side moves it into place only after
  # the guards pass, so a refused launch leaves a finished worker's brief untouched.
  local stamp; stamp=$(date -u +%Y%m%dT%H%M%SZ)
  put_file "$box" "$brief" "$STATE/workers/$name/incoming-$stamp.md" || { echo "LAUNCH UNREACHABLE $box"; exit 4; }
  { prelude "$box"; cat <<'EOF'
name="$1" kind="$2" cwd="$3" repo="$4" branch="$5" base="$6" sid="$7" coord="$8" replace="$9" stamp="${10}"; shift 10
d="$WORKERS/$name"; incoming="$d/incoming-$stamp.md"
refuse() { rm -f "$incoming"; echo "LAUNCH REFUSED $BOX/$name: $*"; exit 1; }
if alive "$name"; then refuse "already running"; fi
if [ -f "$d/meta" ] && [ "$replace" != 1 ]; then
  if [ -f "$d/exit" ]; then
    refuse "a finished worker's record is here (its stream is close-out evidence); pick a new name, or --replace to overwrite"
  fi
  refuse "a previous launch left no exit record (killed?); unstick it, or --replace"
fi
if [ -z "$cwd" ]; then
  repo=$(eval echo "$repo")
  cwd="$repo-worktrees/$name"
  if [ ! -d "$cwd" ]; then
    git -C "$repo" fetch -q origin || refuse "fetch failed in $repo"
    git -C "$repo" worktree add -q "$cwd" -b "$branch" "$base" 2>&1 || refuse "worktree add failed"
  else
    # An existing directory is reused only when it is the worktree the caller described.
    have=$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null)
    [ "$have" = "$branch" ] || refuse "$cwd exists but is on '${have:-no branch}', not $branch; remove it, or pass it explicitly with --cwd"
    echo "notice: reusing existing worktree $cwd (on $branch)"
  fi
else
  cwd=$(eval echo "$cwd")
fi
[ -d "$cwd" ] || refuse "no such directory $cwd"
mv -f "$incoming" "$d/brief.md"
: > "$d/stream.jsonl"; : > "$d/stderr.log"; rm -f "$d/exit"
# The CLI line itself, written to a file tmux runs: nothing from the brief is ever a shell word.
{
  printf 'cd %q || exit 97\n' "$cwd"
  case "$kind" in
    claude) printf 'claude -p --output-format stream-json --verbose --dangerously-skip-permissions --session-id %q' "$sid" ;;
    codex)  printf 'codex exec --json --yolo -C %q -o %q' "$cwd" "$d/last-message.md" ;;
  esac
  for a in "$@"; do printf ' %q' "$a"; done
  [ "$kind" = codex ] && printf ' -'
  printf ' < %q >> %q 2>> %q\n' "$d/brief.md" "$d/stream.jsonl" "$d/stderr.log"
  printf 'echo $? > %q\n' "$d/exit"
} > "$d/run.sh"
{
  echo "kind=$kind"; echo "cwd=$cwd"; echo "box=$(hostname -s)"; echo "coordinator=$coord"
  echo "launched_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; echo "resumes=0"; [ -n "$sid" ] && echo "session=$sid"
} > "$d/meta"
tm new-session -d -s "iw-$name" "bash $d/run.sh" || { echo "LAUNCH REFUSED $BOX/$name: tmux failed"; exit 1; }
if [ "$kind" = codex ]; then
  # The thread id is the resume address; it is the first event, but the exec takes a moment. If
  # this connection drops before it is recorded, session_of recovers it from the stream later.
  for i in $(seq 1 60); do
    sid=$(jq -r 'select(.type=="thread.started") | .thread_id' "$d/stream.jsonl" 2>/dev/null | head -n1)
    [ -n "$sid" ] && break
    [ -f "$d/exit" ] && break
    sleep 1
  done
  [ -n "$sid" ] && echo "session=$sid" >> "$d/meta"
fi
echo "LAUNCHED $BOX/$name kind=$kind session=${sid:-unknown} cwd=$cwd stream=$d/stream.jsonl"
EOF
  } | run_on "$box" "$name" "$kind" "$cwd" "$repo" "$branch" "$base" "$sid" "$(hostname -s)" "$replace" "$stamp" "$@"
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
    echo "VANISHED $BOX/$name: no exit record (killed, or the CLI never started -- see $d/stderr.log)"; return 3
  fi
  rc=$(cat "$d/exit")
  case "$kind" in
    claude) summary=$(jq -r 'select(.type=="result") | "\(.subtype) is_error=\(.is_error) turns=\(.num_turns) " + ((.result // "")|tostring|.[0:200]|gsub("\n";" "))' "$d/stream.jsonl" 2>/dev/null | tail -n1) ;;
    codex)  summary=$(jq -r 'select(.type=="turn.completed" or .type=="turn.failed") | .type + " " + ((.error.message // "")|tostring|.[0:200])' "$d/stream.jsonl" 2>/dev/null | tail -n1)
            [ -s "$d/last-message.md" ] && summary="$summary | $(head -c 200 "$d/last-message.md" | tr '\n' ' ')" ;;
  esac
  if [ "$rc" = 0 ] && ! printf '%s' "$summary" | grep -q 'is_error=true\|turn.failed'; then
    echo "DONE $BOX/$name exit=0 $summary"; return 0
  fi
  echo "FAILED $BOX/$name exit=$rc $summary $(tail -n 2 "$d/stderr.log" 2>/dev/null | tr '\n' ' ' | cut -c1-200)"; return 1
}
EOF
}

cmd_attach() {
  local box="${1:-}" name="${2:-}"; [ -n "$box" ] && [ -n "$name" ] || die "attach: <box> <name> required"
  shift 2
  local interval=30
  while [ $# -gt 0 ]; do
    case "$1" in --interval) interval="${2:-30}"; shift ;; *) die "attach: unknown option $1" ;; esac; shift
  done
  # The far side waits; a dropped connection (box asleep, tailnet blip) is retried here, from the
  # coordinator, because the worker is still running on its box regardless.
  local tries=0 rc
  while :; do
    { prelude "$box"; verdict_script; cat <<'EOF'
name="$1" interval="$2"; d="$WORKERS/$name"
[ -f "$d/meta" ] || { echo "UNKNOWN $BOX/$name: never launched here"; exit 3; }
started=$(now); last=$started
while alive "$name"; do
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
  { prelude "$box"; cat <<'EOF'
name="$1"; d="$WORKERS/$name"
[ -f "$d/meta" ] || { echo "UNKNOWN $BOX/$name: never launched here"; exit 3; }
kind=$(meta_get "$d" kind); cwd=$(meta_get "$d" cwd)
if alive "$name"; then state=RUNNING; elif [ -f "$d/exit" ]; then state="EXITED($(cat "$d/exit"))"; else state=VANISHED; fi
quiet=$(( $(now) - $(mtime "$d/stream.jsonl") ))
case "$kind" in
  claude) last=$(tail -n 1 "$d/stream.jsonl" 2>/dev/null | jq -r '.type + (if .type=="assistant" then ":" + ([.message.content[]? | .type] | join(",")) else "" end)' 2>/dev/null) ;;
  codex)  last=$(tail -n 1 "$d/stream.jsonl" 2>/dev/null | jq -r '.type + (if .item then ":" + .item.type else "" end)' 2>/dev/null) ;;
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
  shift 2
  local n=40
  while [ $# -gt 0 ]; do case "$1" in -n) n="${2:-40}"; shift ;; *) die "log: unknown option $1" ;; esac; shift; done
  { prelude "$box"; cat <<'EOF'
name="$1" n="$2"; d="$WORKERS/$name"
[ -f "$d/meta" ] || { echo "UNKNOWN $BOX/$name: never launched here"; exit 3; }
case "$(meta_get "$d" kind)" in
  claude) jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="text") | .text' "$d/stream.jsonl" 2>/dev/null | tail -n "$n" ;;
  codex)  jq -r 'select(.type=="item.completed" and .item.type=="agent_message") | .item.text' "$d/stream.jsonl" 2>/dev/null | tail -n "$n" ;;
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
  local stamp; stamp=$(date -u +%Y%m%dT%H%M%SZ)
  put_file "$box" "$msg" "$STATE/workers/$name/messages/$stamp.md" || { echo "UNSTICK UNREACHABLE $box"; exit 4; }
  { prelude "$box"; cat <<'EOF'
name="$1" kill="$2" stamp="$3"; shift 3
d="$WORKERS/$name"
[ -f "$d/meta" ] || { echo "UNSTICK REFUSED $BOX/$name: never launched here"; exit 1; }
kind=$(meta_get "$d" kind); cwd=$(meta_get "$d" cwd); sid=$(session_of "$d")
[ -n "$sid" ] || { echo "UNSTICK REFUSED $BOX/$name: no session id in meta or stream"; exit 1; }
grep -q '^session=' "$d/meta" || echo "session=$sid" >> "$d/meta"
if alive "$name"; then
  if [ "$kill" != 1 ]; then
    echo "UNSTICK REFUSED $BOX/$name: still running -- a resume beside a live exec gives the branch two writers; pass --kill to stop it first"; exit 1
  fi
  tm kill-session -t "iw-$name"
  for i in $(seq 1 30); do alive "$name" || break; sleep 1; done
fi
# The tmux session is gone; make sure the CLI it ran is too (it could have been reparented).
# A claude worker carries its session id on its command line; a codex worker's first exec
# carries only this worker's state dir (-o), so match either.
pat="$(re_lit "$sid")|$(re_lit "$d/")"
for i in $(seq 1 30); do
  pgrep -f -- "$pat" >/dev/null 2>&1 || break
  [ "$i" -eq 1 ] && pkill -TERM -f -- "$pat" 2>/dev/null
  sleep 1
done
if pgrep -f -- "$pat" >/dev/null 2>&1; then
  echo "UNSTICK REFUSED $BOX/$name: a process still carries session $sid after TERM: $(pgrep -fl -- "$pat" | head -n 3 | tr '\n' ';')"; exit 1
fi
rm -f "$d/exit"
{
  printf 'cd %q || exit 97\n' "$cwd"
  case "$kind" in
    claude) printf 'claude -p --output-format stream-json --verbose --dangerously-skip-permissions --resume %q' "$sid" ;;
    codex)  printf 'codex exec resume %q --yolo --json' "$sid" ;;
  esac
  for a in "$@"; do printf ' %q' "$a"; done
  [ "$kind" = codex ] && printf ' -'
  printf ' < %q >> %q 2>> %q\n' "$d/messages/$stamp.md" "$d/stream.jsonl" "$d/stderr.log"
  printf 'echo $? > %q\n' "$d/exit"
} > "$d/run.sh"
n=$(meta_get "$d" resumes); n=$(( ${n:-0} + 1 ))
sed -i.bak "s/^resumes=.*/resumes=$n/" "$d/meta" && rm -f "$d/meta.bak"
tm new-session -d -s "iw-$name" "bash $d/run.sh" || { echo "UNSTICK REFUSED $BOX/$name: tmux failed"; exit 1; }
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
  if alive "$name"; then state=RUNNING; elif [ -f "$d/exit" ]; then state="EXITED($(cat "$d/exit"))"; else state=VANISHED; fi
  echo "$BOX/$name $state kind=$(meta_get "$d" kind) launched=$(meta_get "$d" launched_at) by=$(meta_get "$d" coordinator) quiet=$(( $(now) - $(mtime "$d/stream.jsonl") ))s cwd=$(meta_get "$d" cwd)"
done
[ "$found" = 1 ] || echo "$BOX: no workers"
EOF
    } | run_on "$box"
    rc=$?
    if unreachable "$rc"; then echo "$box: unreachable"; worst=4; fi
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
cmd_halt() {
  local reason="$*"; [ -n "$reason" ] || die "halt: give the reason (what regressed, who owns the fix)"
  local f; f=$(halt_file)
  mkdir -p "$(dirname "$f")"
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" > "$f"
  echo "HALTED: launches refused until resume-launches -- $reason"
}

cmd_resume_launches() {
  local f; f=$(halt_file)
  if [ -f "$f" ]; then echo "RESUMED launches (was: $(cat "$f"))"; rm -f "$f"; else echo "launches were not halted"; fi
}

cmd_halted() {
  local f; f=$(halt_file)
  if [ -f "$f" ]; then echo "HALTED $(cat "$f")"; exit 1; else echo "launches open"; exit 0; fi
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
  *) sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
