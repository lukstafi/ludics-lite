#!/usr/bin/env bash
# The fleet half of the issue-wave skill: one coordinator launches workers onto any box in the
# fleet and supervises them there, with the same commands whether the box is the coordinator's
# own machine or a remote one reached over ssh (ludics-lite#4).
#
# Native workers use runtime subagents (or explicitly chosen app tasks); this script supplies their provider-specific native
# freshness preflight and point-in-time gate. Their board is coordinator-maintained (see
# references/native-workers.md); ls/status/attach/unstick below only handle CLI workers.
#
# A CLI worker is a detached tmux session on its box running one headless CLI turn --
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
#   fleet-worker.sh preflight <box> [--codex|--native-codex|--native-claude] [--no-probe] [--no-cross]   # launch runs this itself, too
#   fleet-worker.sh refresh <box> [<box> ...]   # fast-forward each box's skills checkout alone, or
#                          # report why not (never resets); `execution run`/`dispatch` run it
#                          # on the execution host
#   fleet-worker.sh gate --target-repo <owner/repo> [--base-branch <branch>] [--force --allow-red-base <reason>] # lease + halt read before native dispatch (not a reservation)
#   fleet-worker.sh launch <box> <name> --target-repo <owner/repo> --kind claude|codex --brief <file>
#                          (--cwd <dir> | --repo <dir> --branch <branch> [--base <ref>])
#                          [--base-branch <branch>] [--force --allow-red-base <reason>]
#                          [--replace] [-- <extra CLI args>]
#   fleet-worker.sh attach <box> <name> [--interval <sec>]
#   fleet-worker.sh status <box> <name>
#   fleet-worker.sh log <box> <name> [-n <lines>]
#   fleet-worker.sh unstick <box> <name> --message <file> [--kill] [-- <extra CLI args>]
#   fleet-worker.sh ls [<box> ...]
#   fleet-worker.sh load
#   fleet-worker.sh execution list [--active] [--compact]
#   fleet-worker.sh execution slot [--wait <seconds>] [--cpu|--gpu] -- <command...>   # hold one
#                          # of THIS box's run-time correctness slots around a suite or batch
#                          # (no lease needed), plus a GPU token unless it declares --cpu
#   fleet-worker.sh execution hold [--why <text>] -- <command...>   # run under THIS box's OS-level
#                          # sleep guard alone (a systemd-inhibit block lock; bare where none):
#                          # the wrapper for an exclusive measurement, and what `slot` runs inside
#   fleet-worker.sh execution reserve|dispatch|record|reconcile|conclude <json-file>
#   fleet-worker.sh execution run <json-file>          # reserve + dispatch in one step
#   fleet-worker.sh execution conclude --from-run <run-dir> --request <id> --sha <sha>
#                          [--box <box>] [--evidence <text>]   # verdict, log and checkout read from a
#                                                     # test-run.sh record on the reserved box
#   fleet-worker.sh execution conclude --from-bg-run <run-dir> --request <id> --sha <sha>
#                          [--box <box>] [--checkout <text>] [--evidence <text>]   # verdict and log
#                          # read from a bg-run.sh directory (see conclude_from_bg_run for the mapping)
#   fleet-worker.sh prs <owner/repo> [--wave <id>] [--flag-at <n>]   # open PRs with review rounds,
#                          # CI state and head age; flags <n> (5) or more rounds (read-only)
#   fleet-worker.sh halt <reason> | resume-launches | halted
#
# `launch`, `unstick`, `halt` and `resume-launches` require the lease; `launch` also refuses
# while halted (`--force` admits the one triage worker) and runs the preflight on the box first.
# Lease and halt live on FLEET_ANCHOR.
#
# <box> is an ssh destination (rog-nv-linux, minix-amd-linux, tuf-amd-linux), or `local` / this machine's own fleet
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
#   FLEET_BOXES: whole fleet; "mac-studio rog-nv-linux minix-amd-linux tuf-amd-linux". `ls` sweeps it minus local.
#     One entry per physical box: the registry refuses a reservation under a roster naming two
#     aliases of one box, read from wake-lab.sh's endpoint map (ludics-lite#395; endpoint_map).
#   FLEET_BOX_CORRECTNESS_SLOTS: `<box>=<n>` pairs, how many correctness executions may share a
#     box (ludics-lite#157); an unnamed box has one. "mac-studio=6" whenever the roster is the
#     default one, beside "rog-nv-linux=4 minix-amd-linux=4 tuf-amd-linux=3" in the same
#     value, whether FLEET_BOXES is unset or exports those same boxes (compared as a word set,
#     ludics-lite#329); empty (one slot everywhere) with a custom FLEET_BOXES. Set, even to
#     empty, it overrides the default either way. `preflight` prints the count per roster box.
#     Measurement stays exclusive.
#     Six, not three (ludics-lite#160): three `-j 4` batches ran side by side on the Mac without
#     a stall on 2026-09-15 and the Developer Tools exemption removed the XProtect tax, and the
#     cap exists to bound concurrent load, never to bound how many agents may be in flight.
#     The native GPU boxes' counts were measured with 1-4 concurrent targeted batches, each box
#     under an exclusive reservation (ludics-lite#316 on 2026-09-23, #344 on 2026-09-24), and
#     every batch compiled the tree (dune's cache restored nothing). OCANNL's tools/box-jobs.sh
#     restates each count and injects the width it was measured at (ahrefs/ocannl#1033), so
#     a change here goes there too. minix-amd-linux four, at `-j 4`: 16 hip-width at once was
#     green three ways (four `-j 4` batches, two `-j 8`, a full unit at `-j 16`) and 12 twice,
#     and only dune's default 32 has drained its device-wide SDMA pool. tuf-amd-linux three, at
#     `-j 8`: three `-j 8` hip batches were green on its discrete gfx1102. rog-nv-linux four, of
#     which two may hold its GPU (FLEET_BOX_GPU_TOKENS below): rungs of three or more concurrent
#     `-j 8` cuda batches hit CUDA_ERROR_OUT_OF_MEMORY in 2 of 6 (10 of its 12 GiB in use),
#     while two cuda batches beside one or two cc batches were green, so the bound there is
#     GPU memory and not the box (ludics-lite#391).
#   FLEET_BOX_GPU_TOKENS: `<box>=<n>` pairs, how many of a box's correctness slots may run a
#     batch that holds its GPU at once (ludics-lite#391); an unnamed box has as many as it has
#     slots, so the pool binds nowhere else. "rog-nv-linux=2" whenever the roster is the default
#     one; set, even to empty, it overrides that. Fail-closed: every batch takes a token except
#     one that declares `execution slot --cpu`, so a GPU batch whose caller forgot to say so is
#     still counted. `preflight` prints the tokens beside the slots wherever they are fewer.
#   FLEET_SKILLS_REPO: skills checkout on each box; ~/ludics-lite.
#   ISSUE_WAVE_STATE: local worker-state directory; ~/.local/state/issue-wave.
#   FLEET_SLOT_STATE: where `execution slot` keeps a box's run-time slot locks;
#     ~/.local/state/fleet-execution-slots. Deliberately NOT under ISSUE_WAVE_STATE, which is
#     per-coordinator: the cap is the box's, so every agent on the box must resolve this to the
#     same directory (as every coordinator must resolve FLEET_ANCHOR_STATE to the same one).
#   FLEET_SYSTEMD_INHIBIT: the systemd-inhibit that `execution hold` (and so `execution slot`)
#     wraps a run in; systemd-inhibit on PATH. A name that resolves to no executable runs the
#     command bare, as on macOS; the suites pin it to a stub or to nothing, never to the runner's.
#   FLEET_TMUX_SOCKET: tmux -L name; tests isolate with it.
#   FLEET_FLOTILLA: status service; http://mac-studio:7799.
#   FLEET_PRS_LIMIT: how many open PRs `prs` fetches; 1000. A list that reaches it says so.
#   FLEET_LOCK_WAIT: seconds a lease mutation waits for a concurrent one; 10.
#   FLEET_PROBE_TIMEOUT: wall-clock bound on the live headless preflight turn; 120.
#   FLEET_CROSS_TIMEOUT: wall-clock bound on each cross-box ssh reach probe of the preflight; 20.
#   FLEET_FETCH_TIMEOUT: wall-clock bound on skills-checkout and project fetches; 300.
#   FLEET_GH_TIMEOUT: wall-clock bound on the preflight's `gh api user` credential call; 30.
#   FLEET_REFRESH_TIMEOUT: wall-clock bound on `refresh`'s skills fetch (and so on the refresh
#     after a cross-box `execution run`/`dispatch`); 30.

set -uo pipefail

# Which fleet box this is, from the hostname unless FLEET_LOCAL_BOX says so; an unrecognized
# host is local to nothing but the literal `local`, so every named box is reached over ssh.
# FLEET_HOSTNAME_MAP is the lookup: `<glob>=<box>` pairs, first match wins, patterns are shell
# globs against the lowercased short hostname (so `*mac-studio*` and `rog-nv*` read as expected).
# The Mac Studio's short hostname is `LukaszsacStudio` (Apple names the host after the owner and
# model, not after the ssh alias), so it is listed beside the alias-shaped spelling: without it
# the coordinator on the anchor box itself ssh'd to `mac-studio` and read its own lease and
# halt files as unreachable (2026-09-04, the first fleet-wide wave).
HOSTNAME_MAP="${FLEET_HOSTNAME_MAP:-*mac-studio*=mac-studio lukaszsacstudio*=mac-studio rog-nv*=rog-nv-linux rog=rog-nv-linux minix*=minix-amd-linux tuf*=tuf-amd-linux}"
detect_local_box() {
  local host pair
  local -a hostname_pairs=()
  host=$(hostname -s 2>/dev/null | tr 'A-Z' 'a-z')
  read -r -d "" -a hostname_pairs <<< "$HOSTNAME_MAP" || :
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
DEFAULT_BOXES="mac-studio rog-nv-linux minix-amd-linux tuf-amd-linux"
BOXES="${FLEET_BOXES:-$DEFAULT_BOXES}"
# A roster as a normalised word list: whitespace-separated, order and repeats ignored, so an
# exported roster naming the default boxes reads as the default roster (ludics-lite#329).
# Every configured word list here (roster, slot spec, hostname map) is read with `read -d ""`,
# i.e. across ALL its lines: a plain `read -a` stops at the first newline, and a roster written
# over two lines would read as a custom one and drop the Mac back to one slot (PR #333 review).
roster_words() {
  local -a words=()
  read -r -d "" -a words <<< "$1" || :
  [ "${#words[@]}" -gt 0 ] || return 0
  printf '%s\n' "${words[@]}" | LC_ALL=C sort -u | tr '\n' ' '
}
# Correctness slots per box: the site default only fits the site's roster, so it applies whenever
# the effective roster IS the default one -- not only when FLEET_BOXES is absent. From 2026-09-22
# every box's ~/.config/fleet/env.sh exported the default roster verbatim, and a test on the
# variable's presence silently dropped mac-studio to one slot for a day (ludics-lite#329).
if [ "$(roster_words "$BOXES")" = "$(roster_words "$DEFAULT_BOXES")" ]; then DEFAULT_ROSTER=1; else DEFAULT_ROSTER=0; fi
SLOTS="${FLEET_BOX_CORRECTNESS_SLOTS-$([ "$DEFAULT_ROSTER" = 0 ] || echo mac-studio=6 rog-nv-linux=4 minix-amd-linux=4 tuf-amd-linux=3)}"
# GPU tokens per box (ludics-lite#391), the same roster rule: rog-nv-linux's four slots admit only
# two batches holding its 12 GiB GPU at once, the count its cuda batches were measured green at.
GPU_TOKENS_DEFAULT="rog-nv-linux=2"
GPU_TOKENS="${FLEET_BOX_GPU_TOKENS-$([ "$DEFAULT_ROSTER" = 0 ] || echo "$GPU_TOKENS_DEFAULT")}"
SKILLS_REPO="${FLEET_SKILLS_REPO:-\$HOME/ludics-lite}"
STATE="${ISSUE_WAVE_STATE:-\$HOME/.local/state/issue-wave}"
# Run-time correctness slots (`execution slot`) are a property of the BOX, so their lock files
# must not hang off ISSUE_WAVE_STATE: that is each coordinator's own directory, and two workers
# on one host under different coordinators would then lock different files and each take slot 1,
# leaving the cap bounding nothing. Every agent on a box must resolve this to one directory.
SLOT_STATE="${FLEET_SLOT_STATE:-\$HOME/.local/state/fleet-execution-slots}"
INHIBIT="${FLEET_SYSTEMD_INHIBIT:-systemd-inhibit}"
ANCHOR_STATE="${FLEET_ANCHOR_STATE:-$STATE}"
TMUX_SOCKET="${FLEET_TMUX_SOCKET:-}"
FLOTILLA="${FLEET_FLOTILLA:-http://mac-studio:7799}"
PRS_LIMIT="${FLEET_PRS_LIMIT:-1000}"
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
  # Whether run_on runs this as a local child: `local` and the anchor's own name alike (is_local).
  if is_local "$1"; then printf 'BOX_IS_LOCAL=1\n'; else printf 'BOX_IS_LOCAL=0\n'; fi
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
  # Tenth-second polls: a probe that returns at once (a reachable ssh sibling, a fast CLI) must
  # not cost a whole second each, since the preflight runs them serially under the per-box lock
  # and every launch pays it; [waited] counts tenths against [secs].
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt $((secs * 10)) ]; do sleep 0.1; waited=$((waited + 1)); done
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
# A stale tmux server environment (ludics-lite#327). A CLI worker's `bash run.sh` reads no startup
# file, and a new tmux session takes the SERVER's environment, not the asking shell's, so an
# env.sh or gpu.sh edit reaches no CLI worker on a box whose server predates it -- silently: a
# server started before gpu.sh dropped ROCM_PATH=/usr (2026-09-22) would have gone on handing
# workers the value that broke hipcc's bitcode discovery. The reference is what a server started
# NOW would get, which is this script's own environment: on a remote box it runs under
# `ssh <box> "bash -s"`, the fresh non-login ssh shell whose ~/.bashrc sources env.sh (the
# launch that starts a server runs under the same one), and on the local box under a `bash -s`
# that reads no startup file, as that launch does. The coordinator's own environment never
# enters a remote comparison. No server running passes: the next launch starts a fresh one.
# Prints the refusal and returns 1 on a stale server. The preflight reports it early, and every
# far-side script that creates a worker session (launch, unstick) repeats it just before
# `new-session`: the launch's fetch and base gate can take minutes, and a resume creates a
# session with no preflight at all.
TMUX_ENV_VARS="PATH ROCM_PATH HIP_PATH OPAM_SWITCH_PREFIX"
tmux_env_check() {
  local sessions genv refreshed v line skip sset sval fset fval diff="" workers="" others="" tmx
  genv=$(tm show-environment -g 2>/dev/null) || return 0   # no server running
  # `exit-empty off` keeps a server alive with no session at all, so the server is found by its
  # environment, never by its session list; an unreadable list is an empty one.
  sessions=$(tm list-sessions -F '#{session_name}' 2>/dev/null) || sessions=""
  # A variable named in `update-environment` is copied from the launching client into every new
  # session (removed there when the client lacks it), so the worker gets the fresh shell's value
  # whatever the global one says: comparing it would refuse a safe launch.
  refreshed=$(tm show-options -gv update-environment 2>/dev/null)
  for v in $TMUX_ENV_VARS; do
    skip=0
    while IFS= read -r line; do [ "$line" = "$v" ] && skip=1; done <<< "$refreshed"
    [ "$skip" = 0 ] || continue
    # `VAR=value` is set, `-VAR` is removed from the global environment, no line is never set.
    sset=0; sval=""
    while IFS= read -r line; do
      case "$line" in "$v="*) sset=1; sval=${line#"$v="} ;; "-$v") sset=0; sval="" ;; esac
    done <<< "$genv"
    fset=0; fval=""; if [ -n "${!v+x}" ]; then fset=1; fval=${!v}; fi
    [ "$sset" = "$fset" ] && [ "$sval" = "$fval" ] && continue
    [ "$sset" = 1 ] || sval="unset"; [ "$fset" = 1 ] || fval="unset"
    diff="$diff, $v is $sval in the server but $fval in a fresh shell"
  done
  [ -n "$diff" ] || return 0
  # Every live worker is an iw-<name> session on this socket (`ls` reads RUNNING from the same
  # sessions), and kill-server ends every session the server holds.
  while IFS= read -r line; do
    case "$line" in iw-*) workers="$workers $line" ;; ?*) others="$others $line" ;; esac
  done <<< "$sessions"
  if [ -n "$TMUX_SOCKET" ]; then tmx="tmux -L $(printf '%q' "$TMUX_SOCKET")"; else tmx=tmux; fi
  # Whichever branch names kill-server also names what else it would end: on the default socket
  # those are the user's own sessions.
  others=${others:+ (kill-server also ends its non-worker session(s):$others)}
  if [ -n "$workers" ]; then
    echo "stale tmux server environment (${diff#, }): a CLI worker started now would inherit the server's values; wait for its live worker session(s) (${workers# }; \`fleet-worker.sh ls $BOX\`) to finish, then \`$tmx kill-server\` if it outlives them$others"
  else
    echo "stale tmux server environment (${diff#, }): a CLI worker started now would inherit the server's values; no worker session is live on it, so restart it with \`$tmx kill-server\`$others and try again"
  fi
  return 1
}
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
# The skills checkout's freshness, shared by the preflight and `refresh` (ludics-lite#362) so the
# two can never disagree about what "current" means. Far side, after the prelude; the caller
# defines note() (it appends to $refuse) and runs this before any note of its own, since the
# fast-forward is attempted only when this function has noted nothing. Brings a clean main to
# origin/main and never resets anything: a divergent checkout is noted, not repaired. Arg: the
# fetch's wall-clock bound. Sets repo, before (HEAD on entry), head, up (origin/main) and other
# (changes outside the served tree). Returns 2 when there is no checkout at all, else 0.
# checkout_lock <wait> <label> goes first: the lock that serializes everything that fetches or
# fast-forwards the checkout. It lives in the checkout's own git directory, so every caller on the
# box meets the same lock whatever its ISSUE_WAVE_STATE (per coordinator; the daily sweep may run
# under another), which a lock under that state directory did not give (PR #379 review). Sets repo
# and plock and arms the release; prints the refusal and returns 1 on timeout, 2 with no checkout.
freshness_fn() {
  cat <<'EOF'
checkout_lock() {
  local gitdir
  repo=$(expand_tilde "$SKILLS_REPO")
  gitdir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null) || return 2
  plock="$gitdir/fleet-checkout.lock"
  take_lock "$plock" "$1" "$2" || return 1
  trap 'release_lock "$plock"' EXIT
}
skills_freshness() {
  local prior="$refuse" frc served statusz hidden entry st path from branch
  repo=$(expand_tilde "$SKILLS_REPO")
  git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || return 2
  before=$(git -C "$repo" rev-parse HEAD 2>/dev/null)
  bounded "$1" git -C "$repo" fetch -q origin >/dev/null; frc=$?
  if [ "$frc" -eq 124 ]; then note "git fetch in $repo timed out after ${1}s"; elif [ "$frc" -ne 0 ]; then note "fetch failed (offline?)"; fi
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
  if [ "$refuse" = "$prior" ]; then
    git -C "$repo" merge --ff-only -q origin/main >/dev/null 2>&1 || note "main does not fast-forward to origin/main"
  fi
  head=$(git -C "$repo" rev-parse HEAD 2>/dev/null); up=$(git -C "$repo" rev-parse origin/main 2>/dev/null)
  # Only after a fast-forward that went through: one that was never tried leaves a stale HEAD by
  # design, and the note that stopped it already says why.
  [ "$refuse" != "$prior" ] || [ "$head" = "$up" ] || note "HEAD $(echo "$head" | cut -c1-9) != origin/main $(echo "$up" | cut -c1-9) (ahead, or offline)"
}
EOF
}

# Far-side skill-freshness preflight (ludics-lite#3). Args: codex probe. Exit 0 with a
# PREFLIGHT OK line, 1 with the refusal. `launch` runs it on the box before every worker, so
# the per-launch refusal the skill promises is enforced here rather than remembered.
preflight_script() {
  freshness_fn
  cat <<'EOF'
codex="$1" probe="$2" probe_timeout="$3" fetch_timeout="$4" cross="$5" cross_timeout="$6" gh_timeout="$7"
refuse=""
note() { refuse="$refuse; $*"; }
# One preflight per box at a time: a parallel group launched together would otherwise race
# `git fetch`/`merge` in the same checkout and refuse on git's own lock files. Idempotent, so
# waiting for the other preflight is the right thing; the bound covers a hung live probe.
# The wait covers everything a holder may legitimately spend: the fetch, the live probe, and one
# cross-box timeout per sibling, since the reach probes run serially under this lock.
nsib=0; for _s in $cross; do nsib=$((nsib + 1)); done
checkout_lock $((fetch_timeout + probe_timeout + gh_timeout + 60 + cross_timeout * nsib)) "PREFLIGHT REFUSED $BOX"; lrc=$?
if [ "$lrc" -eq 2 ]; then echo "PREFLIGHT REFUSED $BOX: no skills checkout at $repo"; exit 1; fi
[ "$lrc" -eq 0 ] || exit 1
skills_freshness "$fetch_timeout"
if [ $? -eq 2 ]; then echo "PREFLIGHT REFUSED $BOX: no skills checkout at $repo"; exit 1; fi
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
if [ "$codex" = 1 ] || [ "$codex" = native ]; then
  for s in ship-pr wait-and-proceed after-merge; do
    t=$(resolved "$HOME/.codex/skills/$s")
    [ "$t" = "$canon/$s" ] || note "~/.codex/skills/$s -> ${t:-missing/not a link} (README's Codex loop not run)"
  done
  if [ "$codex" = 1 ]; then
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
  fi
elif [ "$codex" = 0 ]; then
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
case "$codex" in
  native|native-claude) ;;
  *) if command -v tmux >/dev/null 2>&1; then msg=$(tmux_env_check) || note "$msg"; else note "no tmux"; fi ;;
esac
command -v jq >/dev/null 2>&1 || note "no jq"
# Every correctness batch on this box now runs under `execution slot`, whose N-holder lock is a
# real flock taken by python3 (ludics-lite#160), so Python is no longer an anchor-only need.
python3 -c 'import fcntl' >/dev/null 2>&1 || note "no python3 with fcntl (execution slot's run-time lock)"
sleep_guard=""
if command -v "${FLEET_SYSTEMD_INHIBIT:-systemd-inhibit}" >/dev/null 2>&1 \
  && ! pkcheck --action-id org.freedesktop.login1.inhibit-block-sleep --process $$ >/dev/null 2>&1; then
  sleep_guard="no polkit grant for the sleep guard (runs unguarded; see issue-wave/references/executions.md#the-os-level-sleep-guard)"
fi
# Cross-box reach (ludics-lite#57): a worker's brief may drive a fleet sibling over ssh for a
# one-off leg, and on 2026-09-04 the first such leg found no credential mid-task. A refused
# credential (permission denied, an unverifiable host key) refuses here; a sibling that does not
# answer at all is asleep or off the network, which the wake path owns, so it is noted on the OK
# line rather than refused - a worker whose task has no leg there must still launch.
cross_down=""
if [ -n "$cross" ] && ! command -v ssh >/dev/null 2>&1; then
  note "no ssh client on $BOX for the cross-box legs (ludics-lite#57)"; cross=""
fi
for sibling in $cross; do
  # Under `bounded`, which gives the probe /dev/null as stdin (the far-side program arrives on
  # stdin through `bash -s`, and an ssh that inherited it would read the rest of this script as
  # its own input, ending it early with status 0 - Codex P1 on #67; `-n` says the same thing to
  # ssh itself) and a whole-process deadline: ConnectTimeout bounds the handshake only, not a
  # login shell that never returns, and this loop holds the preflight lock.
  err=$(bounded "$cross_timeout" ssh -n -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new "$sibling" exit 0); crc=$?
  [ "$crc" -eq 0 ] && continue
  if [ "$crc" -eq 124 ]; then cross_down="$cross_down $sibling(no answer in ${cross_timeout}s)"; continue; fi
  case "$err" in
    *"Permission denied"*|*"Host key verification failed"*)
      note "no non-interactive ssh to $sibling from $BOX: $(printf '%s' "$err" | tail -n1 | cut -c1-100) (provision the key, ludics-lite#57)" ;;
    *) cross_down="$cross_down $sibling" ;;
  esac
done
# GitHub credential (ludics-lite#360): a worker on this box pushes and opens its PR with this
# box's `gh` (git's credential helper here too), and on 2026-09-23 a dead keyring token surfaced
# an hour into a worker's task, and another worker routed around it with a copied token. Since
# 2026-09-24 every box instead exports one PAT as GH_TOKEN from ~/.config/fleet/gh-token.sh, which
# env.sh sources (per-box keyring logins revoked each other: GitHub keeps 10 OAuth tokens per
# user and app). So the
# preflight makes the call a worker makes, `gh api user`, from the same kind of session: this
# script runs as a non-interactive `ssh <box> bash -s` (or a local child on the anchor), which is
# NOT the box's desktop console. On 2026-09-24 minix's `gh auth status` was reported green at the
# desktop while its token answered HTTP 401 over non-interactive ssh, and rog's gh 2.46 exited 0
# from `auth status` over "The token in keyring is invalid", so neither a console nor a status
# read is the proof. Classification is a fail-closed allowlist: a login on stdout with exit 0 passes; a
# call with no answer in time, gh's "error connecting to" (DNS, TCP, TLS) or an HTTP 5xx means
# GitHub did not answer, which is noted on the OK line like a sleeping sibling (git fetch above
# already refuses a box that cannot reach GitHub at all); everything else - a 401, gh's "gh auth
# login" hint, any output this list does not name - refuses with the user-side repair.
# Boundary: it proves what `gh api --hostname github.com user` answers in this session - the
# session a native worker, a leg and a NEW tmux server get. It does not read a running tmux
# server's environment (a CLI worker inherits that; tmux_env_check compares its build variables
# only), the git credential helper a push uses, or a token /user does not accept (an app
# installation token): those are ludics-lite#374, not this check.
gh_down=""
# The fleet's PAT file (2026-09-24), checked whatever `gh api user` answers, since a live token
# that is not the file's is a per-box credential again: it must be a regular file this user owns,
# mode 0600/0400 (`ls -lnd` reads that alike on GNU and BSD), and the session's GH_TOKEN must be
# the one it exports (sourced in a subshell only once it passed; no value is printed). Each
# repair replaces the file with a fresh regular one or names the startup line to fix.
tokf="$HOME/.config/fleet/gh-token.sh"; tokbad=""; qbox=$(printf '%q' "$BOX")
case "$BOX_IS_LOCAL" in 1) tokcopy="replace it here with a regular 0600 file holding the fleet PAT (export GH_TOKEN=ghp_...)" ;;
  *) tokcopy="replace it from the anchor: ssh $qbox 'f=~/.config/fleet/gh-token.sh; umask 077; cat > \"\$f.new\" && chmod 600 \"\$f.new\" && mv \"\$f.new\" \"\$f\"' < ~/.config/fleet/gh-token.sh" ;; esac
if [ -e "$tokf" ] || [ -L "$tokf" ]; then
  tokbad=1; tls=$(ls -lnd "$tokf" 2>/dev/null)
  case "$tls" in "-rw------- "*|"-r-------- "*) [ "$(printf '%s' "$tls" | awk '{print $3}')" != "$(id -u)" ] || tokbad="" ;; esac
  if [ -n "$tokbad" ]; then
    # mv replaces only a regular file: onto a directory, or a symlink to one, it moves the new
    # file INTO it. So any path that is not a plain regular file is moved aside first (never
    # deleted: nothing here says its contents are disposable).
    # The operator reads this on the anchor, so a remote box's move runs over ssh as its copy does.
    tokmv="mv ~/.config/fleet/gh-token.sh ~/.config/fleet/gh-token.sh.aside"; [ "$BOX_IS_LOCAL" = 1 ] || tokmv="ssh $qbox '$tokmv'"
    tokfix=$tokcopy; [ -f "$tokf" ] && [ ! -L "$tokf" ] || tokfix="move the path aside first ($tokmv; a symlink moves as the link), then $tokcopy"
    note "~/.config/fleet/gh-token.sh on $BOX is not a regular mode-0600 file this user owns ($(printf '%s' "$tls" | awk '{print $1, "uid", $3}')): the PAT in it may be readable by others -- repair: $tokfix"
  else
    # An empty GH_TOKEN is no token to gh: it falls back to GITHUB_TOKEN or a stored login. And
    # an assignment without `export` never reaches gh, so the file's token is read through the
    # environment (printenv), not as a shell variable.
    ftok=$(unset GH_TOKEN; . "$tokf" >/dev/null 2>&1; printenv GH_TOKEN)
    if [ -z "$ftok" ]; then
      tokbad=1; note "~/.config/fleet/gh-token.sh on $BOX exports no GH_TOKEN -- repair: $tokcopy"
    elif [ -z "${GH_TOKEN-}" ]; then
      tokbad=1; note "this session does not export the token in ~/.config/fleet/gh-token.sh on $BOX -- repair: end its ~/.config/fleet/env.sh with [ ! -r \"\$HOME/.config/fleet/gh-token.sh\" ] || . \"\$HOME/.config/fleet/gh-token.sh\" (scripts/install-linux.sh adds it)"
    elif [ "$GH_TOKEN" != "$ftok" ]; then
      tokbad=1
      # The anchor's preflight is a child of the invoking shell, which rereads no startup file:
      # there a mismatch is as likely a shell that predates the file's rotation.
      case "$BOX_IS_LOCAL" in
        1) note "this shell's GH_TOKEN is not the one ~/.config/fleet/gh-token.sh exports -- repair: run . ~/.config/fleet/gh-token.sh (or open a new shell) and rerun; if a new shell still differs, a later startup line overrides it (grep -Hnos GH_TOKEN ~/.zshrc ~/.zprofile ~/.bashrc ~/.profile ~/.bash_profile ~/.config/fleet/env.sh lists the lines without their values)" ;;
        *) note "this session's GH_TOKEN is not the one ~/.config/fleet/gh-token.sh exports on $BOX: a later line of its shell startup overrides it -- repair: remove that line (ssh $qbox 'grep -Hnos GH_TOKEN ~/.bashrc ~/.profile ~/.bash_profile ~/.config/fleet/env.sh' lists the lines without their values), then restart any tmux server that inherited it" ;;
      esac
    fi
  fi
fi
if ! command -v gh >/dev/null 2>&1; then
  note "no gh on PATH in a non-interactive session on $BOX (a worker here cannot open its PR)"
else
  ghout=$(GH_PROMPT_DISABLED=1 bounded "$gh_timeout" gh api --hostname github.com user -q .login); ghrc=$?
  ghlast=$(printf '%s\n' "$ghout" | sed '/^[[:space:]]*$/d' | tail -n1 | sed 's/^.*}gh: /gh: /' | cut -c1-120)
  if [ "$ghrc" -eq 0 ] && [ -n "$ghlast" ]; then :
  elif [ "$ghrc" -eq 124 ]; then gh_down="no answer from gh api user in ${gh_timeout}s"
  else
    case "$ghout" in
      *"error connecting to "*|*"(HTTP 5"[0-9][0-9]")"*) gh_down="gh api user: $ghlast" ;;
      *)
        # An exported token outranks the stored login, and `gh auth login` refuses while one is
        # set, so the stored-login repair applies only to a box without the fleet's token file.
        envtok=""; for v in GH_TOKEN GITHUB_TOKEN; do [ -z "${!v+x}" ] || envtok="${envtok:+$envtok and }$v"; done
        if [ -n "$tokbad" ]; then repair="fix the token file first (above), then rerun the preflight"
        elif [ -e "$tokf" ]; then repair="the PAT in ~/.config/fleet/gh-token.sh is dead: $tokcopy; then restart any tmux server that inherited the old value"
        else
          case "$BOX_IS_LOCAL" in 1) repair="in a terminal on this box: gh auth login -h github.com -p https -w && gh auth setup-git" ;;
            *) repair="ssh -t $qbox 'gh auth login -h github.com -p https -w && gh auth setup-git'" ;; esac
          [ -z "$envtok" ] || repair="remove the $envtok this session exports (it outranks gh's stored login and blocks gh auth login) from $BOX's shell startup, then restart any tmux server that inherited it; for the stored login: $repair"
        fi
        note "GitHub credential refused in a non-interactive session on $BOX (gh api user: ${ghlast:-exit $ghrc, no output}); a green \`gh auth status\` at the box's desktop console does not prove the token a worker's ssh session reads -- repair: $repair" ;;
    esac
  fi
fi
if [ -n "$refuse" ]; then
  echo "PREFLIGHT REFUSED $BOX: ${refuse#; }${other:+ (changes outside the served tree, ignored: $other)}"
  exit 1
fi
echo "PREFLIGHT OK $BOX skills=$(echo "$head" | cut -c1-9)${other:+ (changes outside the served tree, ignored: $other)}${cross_down:+ (cross-box unreachable, asleep or off the network:$cross_down)}${gh_down:+ (GitHub unreachable from $BOX: $gh_down)}${sleep_guard:+ ($sleep_guard)}"
EOF
}

# Far-side refresh of a box's skills checkout alone (ludics-lite#362): the freshness half of the
# preflight, for a box the fleet reaches for work without launching a worker there. Only `launch`
# and `preflight` ever fast-forwarded a checkout, so a box that only EXECUTES kept a stale one
# indefinitely (tuf-amd-linux sat at 0f7de3d, without `execution hold`, until a hand-run
# preflight). Arg: the fetch bound, which also bounds the wait for the checkout's lock: a holder
# (a preflight, another refresh) may still fail, so a busy lock is waited out and the checkout then
# checked here, never read as refreshed by someone else (PR #379 review).
# Exit 0 current or fast-forwarded, 1 not refreshed (divergent, fetch failed, lock never free): the
# checkout is reported and left exactly as it is, never reset.
refresh_script() {
  freshness_fn
  cat <<'EOF'
fetch_timeout="$1"
refuse=""
note() { refuse="$refuse; $*"; }
checkout_lock "$fetch_timeout" "REFRESH FAILED $BOX"; lrc=$?
if [ "$lrc" -eq 2 ]; then echo "REFRESH FAILED $BOX: no skills checkout at $repo"; exit 1; fi
[ "$lrc" -eq 0 ] || exit 1
skills_freshness "$fetch_timeout"
if [ $? -eq 2 ]; then echo "REFRESH FAILED $BOX: no skills checkout at $repo"; exit 1; fi
if [ -n "$refuse" ]; then
  echo "REFRESH FAILED $BOX: ${refuse#; } -- left as it is, never reset; repair it by hand, then run fleet-worker.sh preflight $BOX"
  exit 1
fi
if [ "$before" = "$head" ]; then echo "REFRESH OK $BOX skills=$(echo "$head" | cut -c1-9) (already current)"
else echo "REFRESH OK $BOX skills=$(echo "$head" | cut -c1-9) (fast-forwarded from $(echo "$before" | cut -c1-9))"; fi
EOF
}

# The fleet minus one box: what that box's preflight probes ssh to. `local` and the coordinator's
# own name both stand for the box running this script, so neither is a sibling of itself.
siblings_of() {
  local box="$1" b out=""
  for b in $BOXES; do
    [ "$b" = "$box" ] && continue
    is_local "$box" && is_local "$b" && continue
    out="$out $b"
  done
  printf '%s' "${out# }"
}

cmd_preflight() {
  local box="${1:-}"; [ -n "$box" ] || die "preflight: which box?"; shift
  local codex=0 probe=1 cross=""
  cross=$(siblings_of "$box")
  while [ $# -gt 0 ]; do
    case "$1" in
      --codex) codex=1 ;;
      --native-codex) codex=native ;;
      --native-claude) codex=native-claude ;;
      --no-probe) probe=0 ;;
      --no-cross) cross="" ;;
      *) die "preflight: unknown option $1" ;;
    esac
    shift
  done
  { prelude "$box"; preflight_script; } | run_on "$box" "$codex" "$probe" "${FLEET_PROBE_TIMEOUT:-120}" "${FLEET_FETCH_TIMEOUT:-300}" "$cross" "${FLEET_CROSS_TIMEOUT:-20}" "${FLEET_GH_TIMEOUT:-30}"
  local rc=$?
  if unreachable "$rc"; then echo "PREFLIGHT UNREACHABLE $box"; slots_report; exit 4; fi
  slots_report
  exit "$rc"
}

# refresh_box <box>: the far-side refresh on one box; its line on stdout, exit 0/1, or 4 with a
# REFRESH UNREACHABLE line when the box did not answer (asleep, off the network: not checked).
# The fetch has its own bound, FLEET_REFRESH_TIMEOUT, shorter than the preflight's: this runs on
# every `execution run`, where a coordinator is waiting on it.
refresh_box() {
  { prelude "$1"; refresh_script; } | run_on "$1" "${FLEET_REFRESH_TIMEOUT:-30}"
  local rc=$?
  if unreachable "$rc"; then echo "REFRESH UNREACHABLE $1: its skills checkout was not checked"; return 4; fi
  return "$rc"
}

# `refresh <box>...`: bring each box's skills checkout to origin/main, or report why not.
# Exit 1 when any box was not refreshed, else 4 when any did not answer, else 0.
cmd_refresh() {
  [ "$#" -ge 1 ] || die "refresh: which box(es)?"
  local box rc worst=0
  for box in "$@"; do case "$box" in -*) die "refresh: unknown option $box" ;; esac; done
  for box in "$@"; do
    refresh_box "$box"; rc=$?
    if [ "$rc" -eq 1 ] || { [ "$rc" -ne 0 ] && [ "$worst" -eq 0 ]; }; then worst="$rc"; fi
  done
  exit "$worst"
}

# slots_report: one PREFLIGHT SLOTS line with the correctness slot count this shell's configuration
# gives every roster box -- what the registry admits (every reservation carries this spec) and what
# `execution slot` takes on this machine; a remote box's own batches read that box's environment. The
# count showed nowhere but in a batch's own slot line, so when an exported default roster dropped
# mac-studio to one slot, nine workers serialized on one flock with every preflight passing
# (ludics-lite#329). Under the default roster, a spec that does not name a box the SLOTS default
# above widens -- mac-studio, where the Mac batches run, and the native GPU boxes rog-nv-linux and
# minix-amd-linux (ludics-lite#316) -- is that collapse for that box, and is one warning on stderr
# per box; a spec naming the box explicitly, even at one slot, is someone's choice and is not. The
# boxes are spelled here as well as in the default, and the preflight fixture checks both
# directions: the site default draws no warning, and an empty spec warns about exactly the boxes
# the site default gives more than one slot. A box whose GPU tokens are fewer than its slots
# shows them as `<box>=<slots>(gpu=<tokens>)` (ludics-lite#391), and a token spec that leaves out a
# box the site's token default narrows is the same kind of warning. Never changes the preflight's
# verdict.
slots_report() {
  local b n t named out="" src
  local -a roster=() spec=() widened=(mac-studio rog-nv-linux minix-amd-linux tuf-amd-linux) tokened=()
  read -r -d "" -a roster <<< "$BOXES" || :
  read -r -d "" -a spec <<< "$SLOTS" || :
  for b in ${roster[@]+"${roster[@]}"}; do
    n=$(box_correctness_slots "$b") || { echo "PREFLIGHT SLOTS WARNING: $n; every \`execution slot\` and reservation under it refuses" >&2; return 0; }
    t=$(box_gpu_tokens "$b") || { echo "PREFLIGHT SLOTS WARNING: $t; every \`execution slot\` refuses" >&2; return 0; }
    # The GPU tokens only where they bind (ludics-lite#391): fewer than the slots.
    if [ "$t" -lt "$n" ]; then out="$out $b=$n(gpu=$t)"; else out="$out $b=$n"; fi
  done
  if [ -n "${FLEET_BOX_CORRECTNESS_SLOTS+x}" ]; then src="FLEET_BOX_CORRECTNESS_SLOTS"
  elif [ "$DEFAULT_ROSTER" = 1 ]; then src="site default"
  else src="custom roster: one slot each"; fi
  [ -z "${FLEET_BOX_GPU_TOKENS+x}" ] || src="$src; FLEET_BOX_GPU_TOKENS"
  echo "PREFLIGHT SLOTS${out} ($src)"
  [ "$DEFAULT_ROSTER" = 1 ] || return 0
  for b in "${widened[@]}"; do
    named=0
    for n in ${spec[@]+"${spec[@]}"}; do [ "${n%%=*}" = "$b" ] && named=1; done
    [ "$named" = 1 ] || echo "PREFLIGHT SLOTS WARNING: the default roster, but FLEET_BOX_CORRECTNESS_SLOTS=\"$SLOTS\" does not name $b, which falls to one slot (the site default gives it more); every correctness batch there serializes" >&2
  done
  # The mirror image for the token pool: a GPU-token spec that leaves out a box the site default
  # holds to fewer GPU batches than slots lets every slot there hold the GPU -- rog-nv-linux's
  # measured CUDA_ERROR_OUT_OF_MEMORY shape. Only when the box has more slots than that default.
  read -r -d "" -a spec <<< "$GPU_TOKENS" || :
  read -r -d "" -a tokened <<< "$GPU_TOKENS_DEFAULT" || :
  for b in "${tokened[@]}"; do
    t="${b#*=}" b="${b%%=*}" named=0
    for n in ${spec[@]+"${spec[@]}"}; do [ "${n%%=*}" = "$b" ] && named=1; done
    n=$(box_correctness_slots "$b")
    [ "$named" = 1 ] || [ "$n" -le "$t" ] || echo "PREFLIGHT SLOTS WARNING: the default roster, but FLEET_BOX_GPU_TOKENS=\"$GPU_TOKENS\" does not name $b, so all $n of its slots may hold its GPU at once (the site default allows $t); GPU batches there can run out of device memory" >&2
  done
}

# ---------------------------------------------------------------------------------------------
# Read on the coordinator, where gh is authenticated, never on the worker box.
# Keep complete helper diagnostics; CI refusals use fleet exit 1, never transport 4.
# A named triage may override RED, never unknown.
#
# The gate's two clocks, pinned here so the ceiling below cannot drift away from them. The grace
# is how long a tip with no run of its own is given before its absence is read as a fact; the
# interval is how long a round of the checker's wait takes, and the grace is only ever tested
# once per round. The CEILING is DERIVED from both rather than spelled as a number beside them
# (ludics-lite#175): `--wait=301` over a 300s grace left a one-second margin that one round's API
# latency swallowed, so the wave gate reached its ceiling and refused dispatch for a docs-only
# default-branch tip that the very next round would have settled. One round of margin is the
# smallest that always reaches the round after the grace, and the checker refuses anything in
# between, so these three numbers cannot disagree silently again.
BASE_ABSENT_GRACE=300
BASE_POLL_INTERVAL=60
BASE_WAIT=$((BASE_ABSENT_GRACE + BASE_POLL_INTERVAL))
base_checker() (
  # Gate policy and bounds are not inherited from an unrelated ship-pr operation.
  # Keep connection/auth, state paths and review-only settings; they do not decide base CI.
  # The interval is PINNED rather than unset, for the same reason the grace is: the ceiling above
  # is arithmetic over both, and a default that moved would move the margin without moving it.
  unset SHIP_PR_ADVISORY_CHECKS SHIP_PR_TEST_SOURCE_ONLY
  unset SHIP_PR_CHECKS_WAIT SHIP_PR_CHECKS_HEARTBEAT SHIP_PR_API_ATTEMPTS SHIP_PR_API_BACKOFF
  SHIP_PR_BASE_ABSENT_GRACE="$BASE_ABSENT_GRACE" SHIP_PR_CHECKS_INTERVAL="$BASE_POLL_INTERVAL" "$@"
)

base_gate() {
  local target="$1" branch="$2" force="$3" reason="$4" expected="${5:-}" helper rc tip encoded
  [[ "$target" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "base gate: --target-repo <owner/repo> required"
  [ -z "$reason" ] || [ "$force" -eq 1 ] || die "base gate: --allow-red-base requires --force for a triage worker"
  case "$branch" in -*|*$'\n'*) die "base gate: invalid --base-branch" ;; esac
  helper="$(cd "$(dirname "$0")/../../ship-pr/scripts" 2>/dev/null && pwd)/pr-review.sh"
  [ -x "$helper" ] || { echo "BASE REFUSED: coordinator base checker missing: $helper" >&2; return 1; }
  # The ordinary base read may carry an older green while the tip is running.
  # Reuse its bounded integration mode; preserve the established absence grace
  # for path-filtered tips, independent of the coordinator's ambient settings.
  # The ceiling is BASE_WAIT, derived from the grace and the poll interval pinned above.
  if [ -n "$branch" ]; then
    base_checker "$helper" --repo "$target" base "$branch" "--wait=$BASE_WAIT" >&2
  else
    base_checker "$helper" --repo "$target" base "--wait=$BASE_WAIT" >&2
  fi
  rc=$?
  if [ "$rc" -eq 1 ] && [ "$force" -eq 1 ] && [ -n "$reason" ]; then
    echo "BASE TRIAGE OVERRIDE: $target ${branch:-default branch}: $reason" >&2
    rc=0
  fi
  [ "$rc" -eq 0 ] || echo "BASE REFUSED: $target ${branch:-default branch} (base checker exit $rc); dispatch blocked" >&2
  [ "$rc" -eq 0 ] || return 1
  if [ -n "$expected" ]; then
    encoded=$(jq -rn --arg ref "$branch" '$ref | @uri') || return 1
    tip=$(base_checker "$helper" --repo "$target" retry --read api "repos/$target/commits/$encoded" --jq .sha) || {
      echo "BASE REFUSED: cannot confirm $target $branch after verdict" >&2; return 1;
    }
    [[ "$tip" =~ ^[0-9a-f]{40}$ ]] || { echo "BASE REFUSED: invalid target tip" >&2; return 1; }
    [ "$tip" = "$expected" ] || {
      echo "BASE REFUSED: $target $branch moved or differs from fetched base $expected (now $tip); dispatch blocked" >&2
      return 1
    }
  fi
  return 0
}

cmd_gate() {
  local force=0 target="" branch="" reason=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --allow-red-base)
        [ "$#" -ge 2 ] && [[ "$2" =~ [^[:space:]] ]] || die "base gate: --allow-red-base requires a triage reason"
        reason="$2"; shift ;;
      --force) force=1 ;;
      --target-repo|--base-branch)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "gate: expected value for $1"
        if [ "$1" = --target-repo ]; then target="$2"; else branch="$2"; fi
        shift ;;
      *) die "gate: expected --target-repo <owner/repo> [--base-branch <branch>] [--force]" ;;
    esac
    shift
  done
  anchor_gate GATE native-worker "$force" || return $?
  base_gate "$target" "$branch" "$force" "$reason" || return $?
  anchor_gate GATE native-worker "$force"
}

cmd_launch() {
  local box="${1:-}" name="${2:-}"
  [ -n "$box" ] && [ -n "$name" ] || die "launch: <box> <name> required"
  valid_name "$name" || die "launch: name must be [A-Za-z0-9._-]+ and not start with a dot"
  shift 2
  local kind="" brief="" cwd="" repo="" branch="" base="$BASE_REF" force=0 replace=0 target="" base_branch="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --target-repo|--base-branch)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "launch: expected value for $1"
        if [ "$1" = --target-repo ]; then target="$2"; else base_branch="$2"; fi
        shift ;;
      --kind) kind="${2:-}"; shift ;;
      --brief) brief="${2:-}"; shift ;;
      --cwd) cwd="${2:-}"; shift ;;
      --repo) repo="${2:-}"; shift ;;
      --branch) branch="${2:-}"; shift ;;
      --base) base="${2:-}"; shift ;;
      --allow-red-base)
        [ "$#" -ge 2 ] && [[ "$2" =~ [^[:space:]] ]] || die "base gate: --allow-red-base requires a triage reason"
        reason="$2"; shift ;;
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
  # Worktree creation names its base already. An explicit CI branch is needed for
  # non-origin refs (tags, SHAs, or another remote); existing cwd uses repo default.
  if [ -z "$cwd" ] && [ -z "$base_branch" ]; then
    case "$base" in origin/*) base_branch="${base#origin/}" ;;
      *) die "launch: --base-branch required for a non-origin --base" ;; esac
  fi
  local codex=0 pf; [ "$kind" = codex ] && codex=1
  pf=$( { prelude "$box"; preflight_script; } | run_on "$box" "$codex" 1 "${FLEET_PROBE_TIMEOUT:-120}" "${FLEET_FETCH_TIMEOUT:-300}" "$(siblings_of "$box")" "${FLEET_CROSS_TIMEOUT:-20}" "${FLEET_GH_TIMEOUT:-30}" )
  local prc=$?
  if unreachable "$prc"; then echo "LAUNCH UNREACHABLE $box"; exit 4; fi
  [ "$prc" -eq 0 ] || { echo "LAUNCH REFUSED $box/$name: $pf"; exit 1; }
  # A passing preflight can still carry a note the coordinator must see before briefing a
  # cross-box leg: a sibling that did not answer. Said on stderr, so the LAUNCHED line stays
  # the one thing on stdout.
  case "$pf" in *"cross-box unreachable"*|*"GitHub unreachable"*) echo "preflight note for $box/$name: ${pf#*skills=* }" >&2 ;; esac
  local pinned=""
  if [ -z "$cwd" ]; then
    # Fetch before reading CI and carry an immutable object into worktree add.
    pinned=$( { prelude "$box"; cat <<'EOF'
repo=$(expand_tilde "$1"); base="$2"; fetch_timeout="$3"
bounded "$fetch_timeout" git -C "$repo" fetch -q origin >/dev/null; frc=$?
[ "$frc" -ne 124 ] || { echo "LAUNCH REFUSED: git fetch in $repo timed out after ${fetch_timeout}s" >&2; exit 1; }
[ "$frc" -eq 0 ] || { echo "LAUNCH REFUSED: fetch failed in $repo" >&2; exit 1; }
git -C "$repo" rev-parse --verify "$base^{commit}"
EOF
    } | run_on "$box" "$repo" "$base" "${FLEET_FETCH_TIMEOUT:-300}" )
    prc=$?
    if unreachable "$prc"; then echo "LAUNCH UNREACHABLE $box"; exit 4; fi
    [ "$prc" -eq 0 ] || exit "$prc"
    [[ "$pinned" =~ ^[0-9a-f]{40}$ ]] || die "launch: could not resolve base commit"
  fi
  base_gate "$target" "$base_branch" "$force" "$reason" "$pinned" || exit $?
  [ -z "$pinned" ] || base="$pinned"
  # The preflight and base read may take minutes; a halt or adoption during that window
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
    # base is the immutable SHA fetched and confirmed before admission.
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
msg=$(tmux_env_check) || refuse "$msg"   # the preflight's read may be minutes old
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
#
# A DONE line gains `| PROBABLE STRAND: ...` when the turn's final message announces a wait still
# pending. A headless turn's end kills the background tasks it started, so a worker that ended
# on "the watch will wake me" will never be woken (ludics-lite#361). This is a free-text reader,
# and its boundary is a fail-closed allowlist: it reads ONLY the turn's final message (a Claude
# turn's `result`, a Codex turn's last agent message), whole, case-insensitively, for the fixed
# substrings strand_mark lists, and flags on the first one present. It does not read
# earlier messages, the tool calls, or the processes the turn left, so a paraphrase outside the
# list is not flagged, and a phrase quoted or negated ("no watch will wake me") is flagged anyway.
# The mark is a prompt to read the final message, never a verdict: it changes neither the DONE
# nor the exit code.
verdict_script() {
  cat <<'EOF'
strand_mark() {
  local text p
  text=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  for p in 'will wake me' 'wakes me' 'wake me up' 'wake me when' 'watch is armed' 'watch armed' \
           'armed the watch' 'armed a watch' 'while the watch runs' 'waiting in the background' \
           'running in the background'; do
    case "$text" in *"$p"*)
      printf ' | PROBABLE STRAND: the final message says "%s"; a CLI turn'"'"'s background tasks end with it' "$p"
      return 0 ;;
    esac
  done
}
verdict() {
  local name="$1" d="$WORKERS/$1" kind rc summary final
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
    case "$kind" in
      claude) final=$(turn | jq -Rrn '[inputs | fromjson? | select(.type=="result") | (.result // "" | tostring)] | last // ""' 2>/dev/null) ;;
      codex)  final=$(turn | jq -Rrn '[inputs | fromjson? | select(.type=="item.completed" and .item.type=="agent_message") | (.item.text // "" | tostring)] | last // ""' 2>/dev/null) ;;
    esac
    echo "DONE $BOX/$name exit=0 $summary$(strand_mark "${final:-}")"; return 0
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
# A resume creates a session too, with no preflight in front of it.
msg=$(tmux_env_check) || { echo "UNSTICK REFUSED $BOX/$name: $msg"; exit 1; }
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
# `prs <owner/repo> [--wave <id>] [--flag-at <n>]`: the coordinator's supervision read of open PRs
# (ludics-lite#405). The skill sends the convergence policy "after ~5 rounds", but no view showed
# the count: staging#783 reached round 10 before the coordinator noticed, and ended at 14. One line
# per open PR -- `pr-review.sh rounds` (review rounds with findings), `pr-review.sh checks` (the
# build signal on the head, never waited for) and the head's age -- and a CONVERGE note on a PR at
# --flag-at rounds or more. Every read goes through ship-pr's pr-review.sh, for its retry and its
# exit codes; its text is read only as far as the count on the `rounds` line and the ABSENT word
# on the `checks` line. Read-only: no lease, nothing posted.
# The head's age runs from the newer of the head commit's committer date and the PR's creation,
# the floor pr-review.sh itself uses, since the push time is not an API field.
# --wave keeps the PRs that close an issue some execution record of that wave names (every worker
# takes a standing reservation at launch, so the registry lists the wave's issues); a PR whose
# closing references name none of them -- no `Closes` line -- is not shown under --wave.
# Exit: 0 read | 1 a PR is at the flag, or refused | 4 some read did not answer (a flag wins).
cmd_prs() {
  local repo="" wave="" flag=5 helper list rc issues=null rows n sha created draft branch title
  local rounds_out rounds checks_out ci date age worst=0 shown=0 note
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wave|--flag-at)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "prs: expected value for $1"
        if [ "$1" = --wave ]; then wave="$2"; else flag="$2"; fi
        shift ;;
      -*) die "prs <owner/repo> [--wave <id>] [--flag-at <n>]" ;;
      *) [ -z "$repo" ] || die "prs: one <owner/repo>"; repo="$1" ;;
    esac
    shift
  done
  [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "prs: <owner/repo> required"
  [[ "$flag" =~ ^[1-9][0-9]*$ ]] || die "prs: --flag-at takes a positive number of rounds"
  [[ "$PRS_LIMIT" =~ ^[1-9][0-9]*$ ]] || die "prs: FLEET_PRS_LIMIT must be a positive number of PRs"
  helper="$(cd "$(dirname "$0")/../../ship-pr/scripts" 2>/dev/null && pwd)/pr-review.sh"
  [ -x "$helper" ] || { echo "PRS REFUSED: ship-pr's pr-review.sh missing: $helper"; exit 1; }
  if [ -n "$wave" ]; then
    list=$(execution_listing "$(cd "$(dirname "$0")" && pwd)/fleet-execution.py"); rc=$?
    if unreachable "$rc"; then echo "PRS UNREACHABLE $ANCHOR: the registry naming wave $wave's issues did not answer"; exit 4; fi
    [ "$rc" -eq 0 ] || { printf '%s\n' "$list"; echo "PRS REFUSED: the anchor's registry could not be read"; exit 1; }
    issues=$(jq -c --arg w "$wave" '[.[] | select(.request.wave == $w) | .request.issue] | unique' <<<"$list") ||
      { echo "PRS REFUSED: the anchor's registry did not parse"; exit 1; }
    [ "$issues" != "[]" ] || { echo "PRS REFUSED: no execution record names wave $wave, so its issues are unknown"; exit 1; }
  fi
  # `--limit` is a cap on what gh fetches, not a page size (it pages internally up to it), so a
  # list that reaches it may have lost PRs past it: said on its own line and read as exit 4.
  list=$("$helper" retry --read pr list --repo "$repo" --state open --limit "$PRS_LIMIT" \
    --json number,title,headRefName,headRefOid,createdAt,isDraft,closingIssuesReferences); rc=$?
  if [ "$rc" -eq 3 ]; then echo "PRS UNREACHABLE: the open PRs of $repo did not answer"; exit 4; fi
  [ "$rc" -eq 0 ] || { echo "PRS REFUSED: the open-PR list of $repo was refused (pr-review.sh exit $rc)"; exit 1; }
  n=$(jq 'length' <<<"$list") || { echo "PRS REFUSED: the open-PR list of $repo did not parse"; exit 1; }
  if [ "$n" -ge "$PRS_LIMIT" ]; then
    printf '%s\n' "PRS INCOMPLETE $repo: the list reached its cap of $PRS_LIMIT open PRs (FLEET_PRS_LIMIT), so PRs past it are not shown"
    worst=4
  fi
  # Tab-separated with every field a nonempty placeholder, so no empty field collapses under the
  # tab IFS below and shifts the rest; the title goes last, where a stray character harms nothing.
  rows=$(jq -r --argjson issues "$issues" '
      sort_by(.number)[]
      | [.closingIssuesReferences[]? | "\(.repository.owner.login)/\(.repository.name)#\(.number)"] as $refs
      | select($issues == null or ([$refs[] | select(. as $i | $issues | any(. == $i))] | length > 0))
      | [.number, .headRefOid, .createdAt, (if .isDraft then "draft" else "-" end), .headRefName, .title]
      | map(tostring | if length > 0 then . else "-" end) | @tsv' <<<"$list") ||
    { echo "PRS REFUSED: the open-PR list of $repo did not parse"; exit 1; }
  while IFS=$'\t' read -r n sha created draft branch title; do
    [ -n "$n" ] || continue
    shown=$((shown + 1))
    rounds_out=$(SHIP_PR_ROUND_THRESHOLD=off "$helper" rounds "$repo#$n" 2>/dev/null)
    rounds=$(sed -n 's/^review rounds with findings: \([0-9][0-9]*\) .*/\1/p' <<<"$rounds_out" | head -n 1)
    [ -n "$rounds" ] || { rounds="?"; [ "$worst" -eq 1 ] || worst=4; }
    checks_out=$("$helper" checks "$repo#$n" 2>/dev/null)
    case "$?" in
      0) case "$(head -n 1 <<<"$checks_out")" in *": ABSENT"*) ci=absent ;; *) ci=green ;; esac ;;
      1) ci=red ;;
      4) ci=pending ;;
      5) ci=moved ;;
      *) ci=unknown; [ "$worst" -eq 1 ] || worst=4 ;;
    esac
    date=$("$helper" retry --read api "repos/$repo/commits/$sha" --jq .commit.committer.date 2>/dev/null) || date=""
    age=$(jq -rn --arg a "$date" --arg b "$created" \
      '[$a, $b] | map(select(test("^[0-9]{4}-")) | fromdateiso8601) | if length == 0 then "?" else (now - max) | floor end' 2>/dev/null) || age="?"
    case "$age" in
      ''|*[!0-9]*) age="?" ;;
      *) if [ "$age" -lt 3600 ]; then age="$((age / 60))m"
         elif [ "$age" -lt 172800 ]; then age="$((age / 3600))h$((age % 3600 / 60))m"
         else age="$((age / 86400))d$((age % 86400 / 3600))h"; fi ;;
    esac
    note=""
    if [ "$rounds" != "?" ] && [ "$rounds" -ge "$flag" ]; then
      note=" -- CONVERGE: $rounds review rounds with findings (flag at $flag): send the convergence policy"
      worst=1
    fi
    [ "$draft" = draft ] || draft=""
    printf '%s\n' "$repo#$n rounds=$rounds ci=$ci head=$age ${draft:+draft }$branch: $title$note"
  done <<<"$rows"
  [ "$shown" -gt 0 ] || printf '%s\n' "PRS $repo: no open PRs${wave:+ closing an issue of wave $wave}"
  exit "$worst"
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

# JSON payloads travel as quoted positional arguments. The helper executes on the anchor
# while the existing lease lock fences both adoption and concurrent reservations.
# Far side of `conclude --from-run`, on the execution box: read a finished test-run.sh record
# (OCANNL's `tools/test-run.sh`: `exit`, `log`, `wt` and `cmd` under the run directory) and
# the checkout's head, and refuse anything short of a published verdict with no process left.
# Args: run-dir, reported sha. Prints `exit=`, `wt=`, `head=` lines, or one FROM-RUN REFUSED line.
from_run_script() {
  cat <<'EOF'
dir="$1" sha="$2"
refuse() { echo "FROM-RUN REFUSED: $*"; exit 1; }
[ -d "$dir" ] || refuse "no run directory $dir on $BOX"
for f in exit log wt cmd; do
  [ -f "$dir/$f" ] || refuse "$dir has no $f (the run is unfinished, died without a verdict, or is not a test-run.sh record)"
done
code=$(head -n1 "$dir/exit"); case "$code" in ''|*[!0-9]*) refuse "$dir/exit holds '$code', not a status" ;; esac
wt=$(head -n1 "$dir/wt"); [ -d "$wt" ] || refuse "recorded worktree $wt is gone"
# The project's runner is the authority on "published and no process remains" (exit 0; 3 still
# running, 1 died); without it, the supervisor pid must be gone.
if [ -x "$wt/tools/test-run.sh" ]; then
  (cd "$wt" && tools/test-run.sh status "$dir" >/dev/null 2>&1); st=$?
  [ "$st" -eq 0 ] || refuse "tools/test-run.sh status $dir exit $st: not a finished run"
elif [ -s "$dir/pid" ] && kill -0 "$(head -n1 "$dir/pid")" 2>/dev/null; then
  refuse "supervisor pid $(head -n1 "$dir/pid") of $dir is still alive"
fi
head=$(git -C "$wt" rev-parse --verify HEAD^{commit} 2>/dev/null) || refuse "cannot read HEAD of $wt"
# The record carries no SHA, so the revision that ran is the coordinator's to name (--sha, from
# the worker's result line); the checkout only has to KNOW that commit, and its head is reported
# so a conclusion over a moved checkout says so in its evidence.
git -C "$wt" cat-file -e "$sha^{commit}" 2>/dev/null || refuse "$wt does not contain the reported revision $sha"
printf 'exit=%s\nwt=%s\nhead=%s\n' "$code" "$wt" "$head"
EOF
}

# execution_listing <helper>: the anchor's whole registry as JSON on stdout. `list` takes no
# lease and mutates nothing, so a worker with no coordinator identity may read it.
execution_listing() {
  { prelude "$ANCHOR"; printf 'shift 3\n'
    cat <<'EXECUTION_COMMAND'
python3 - "$ANCHOR_STATE" "$@" <<'FLEET_EXECUTION_PY'
EXECUTION_COMMAND
    cat "$1"; printf '\nFLEET_EXECUTION_PY\n'
  } | run_on "$ANCHOR" EXECUTION x x list x x '{}' "$BOXES" "$SLOTS"
}

# execution_host_of <helper> <request-id>: the reserved execution host of an outstanding record,
# from the anchor's registry (empty when unknown; the conclusion then fails on the request id).
execution_host_of() {
  local listing
  listing=$(execution_listing "$1") || return 1
  jq -r --arg id "$2" '.[] | select(.request_id == $id) | .request.execution_host' <<<"$listing"
}

# conclude_from_run <run-dir> <request-id> <box> <sha> <evidence>: the conclude payload (JSON on
# stdout) read off a finished run record on the box, or a refusal line on stdout and exit 1/4.
# The box is the reservation's execution host: the payload names it and the registry checks it,
# so a record read on the wrong machine cannot conclude another box's assignment.
conclude_from_run() {
  local dir="$1" request="$2" box="$3" sha="$4" evidence="$5" facts rc code wt head verdict
  facts=$({ prelude "$box"; from_run_script; } | run_on "$box" "$dir" "$sha"); rc=$?
  if unreachable "$rc"; then echo "FROM-RUN UNREACHABLE $box: nothing concluded"; return 4; fi
  [ "$rc" -eq 0 ] || { printf '%s\n' "$facts"; return 1; }
  code=$(sed -n 's/^exit=//p' <<<"$facts"); wt=$(sed -n 's/^wt=//p' <<<"$facts"); head=$(sed -n 's/^head=//p' <<<"$facts")
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] && [ -n "$code" ] && [ -n "$wt" ] || { echo "FROM-RUN REFUSED: unreadable record facts from $box: $facts"; return 1; }
  # test-run.sh's exit vocabulary: 142 the cap, 129/130/137/143 a signal; every other nonzero
  # (dune's own 1, a refused invocation, 126/127 toolchain) is a failed run.
  case "$code" in 0) verdict=pass ;; 142) verdict=timeout ;; 129|130|137|143) verdict=cancelled ;; *) verdict=fail ;; esac
  [ -n "$evidence" ] || evidence="test-run.sh record $dir on $box: exit $code published, no process remains"
  [ "$head" = "$sha" ] || evidence="$evidence; checkout head is now $head, revision $sha as reported by the worker"
  jq -cn --arg id "$request" --arg ev "$evidence" --arg sha "$sha" --arg wt "$wt" --arg host "$box" \
    --arg handle "test-run:$(basename "$dir")" --arg log "$dir/log" --arg verdict "$verdict" \
    '{request_id: $id, evidence: $ev, observed_sha: $sha, remote_checkout: $wt, handle: $handle, log: $log, verdict: $verdict, execution_host: $host}'
}

# Far side of `conclude --from-bg-run`, on the box that holds the directory: bg-run.sh's own `wait
# <dir> --within 0` gives the verdict, so the directory contract (bg-run.sh's header: `refused`
# before `rc`, liveness from `pid`/`cpid`) keeps one reader. The coordinator's copy of bg-run.sh
# travels in this script (arg 1 is its path here), so the far box's skills checkout, which only
# `launch`/`preflight`/`execution run` refresh, cannot read the directory with another version.
# The one thing read past `wait` is the runner's own exit sentinel in `log`. Its grammar is a
# fail-closed allowlist: a whole line `exit: <status>` or `<name>: exit: <status>`, the name
# [A-Za-z0-9._-]+ and the status 0-255 without leading zeros -- what OCANNL's tools/test-run.sh
# (`exit: N`), machine-verify-far.sh (`machine-verify: exit: N`) and ci-compiler-test.sh print. The
# LAST such line wins. Deliberately not read: a transport line with a second word
# (`machine-verify: ssh exit: N`, which restates rc), a line with trailing text or a CR, and
# anything else in the log. Prints `status=rc`, `rc=`, `sentinel=` lines, `status=DIED`, or one
# FROM-BG-RUN REFUSED line.
from_bg_run_script() {
  cat <<'EOF'
dir="$1"
refuse() { echo "FROM-BG-RUN REFUSED: $*"; exit 1; }
[ -d "$dir" ] || refuse "no run directory $dir on $BOX"
tmp=$(mktemp "${TMPDIR:-/tmp}/fw-bg-run.XXXXXX") || refuse "cannot create a scratch file on $BOX"
bg_wait() {
  bash -s -- wait "$dir" --within 0 > "$tmp" 2>&1 <<'FLEET_BG_RUN_SH'
EOF
  cat "$1"
  cat <<'EOF'
FLEET_BG_RUN_SH
}
bg_wait; wrc=$?
# DIED is read twice, 5 s apart. bg-run.sh's header names the one window where DIED is wrong: a
# wrapper killed alone between forking the command and the command publishing `cpid`, which a
# wait in that instant reads as DIED while the command goes on to run. The command publishes its
# cpid before it execs anything, so a second read after the pause sees it RUNNING; only a DIED
# that holds across the pause becomes a conclusion.
if [ "$wrc" -eq 5 ]; then sleep 5; bg_wait; wrc=$?; fi
said=$(head -n1 "$tmp"); rm -f "$tmp"
case "$wrc" in
  0) ;;
  3) refuse "bg-run.sh wait: RUNNING -- $dir has no rc and its task or command is alive; conclude once it finishes" ;;
  4) refuse "bg-run.sh wait: STARTING -- no task has published a pid in $dir (never started, or not yet)" ;;
  5) printf 'status=DIED\n'; exit 0 ;;
  6) refuse "bg-run.sh wait: $said -- start refused this directory, so an rc there may be an earlier run's" ;;
  *) refuse "bg-run.sh wait exit $wrc: $said" ;;
esac
code=${said#rc=}
case "$said" in rc=*) ;; *) refuse "bg-run.sh wait printed '$said', not rc=<status>" ;; esac
case "$code" in ''|*[!0-9]*) refuse "$dir/rc holds '$code', not a status" ;; esac
[ -f "$dir/log" ] || refuse "$dir has an rc but no log"
sentinel=$(LC_ALL=C grep -a -E '^([A-Za-z0-9._-]+: )?exit: (0|[1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])$' "$dir/log" | tail -n 1)
printf 'status=rc\nrc=%s\nsentinel=%s\n' "$code" "$sentinel"
EOF
}

# conclude_from_bg_run <run-dir> <request-id> <read-box> <execution-host> <sha> <checkout> <evidence>
# <bg-run.sh path>: the conclude payload (JSON on stdout) read off a bg-run.sh directory, or a
# refusal line on stdout and exit 1/4. The verdict mapping, stated once here and in the help text:
#   - the code is the runner's own sentinel when the log carries one and it is nonzero, else rc --
#     so a pass needs BOTH rc 0 and no nonzero sentinel, and a wrapper that swallowed a failure
#     (or a runner whose status a pipe or tee replaced) cannot conclude as pass;
#   - 0 pass; 124 (timeout(1), fleet-worker's `bounded`) and 142 (test-run.sh's cap) timeout;
#     129/130/137/143 (a signal) cancelled; anything else fail;
#   - bg-run's DIED (a published pid, it and the command both gone, no rc: the harness killed the
#     task), read twice 5 s apart (from_bg_run_script says why), is cancelled, since nothing of the
#     command is left running and it never returned.
# The read box need not be the execution host: a trip driven over ssh (machine-verify from the
# agent host) leaves its directory on the box that drove it, and 5 of the 09-25 wave's 8
# bg-run conclusions were of that shape. So the payload carries no `execution_host` binding (the
# registry would refuse the driving box), and the log and handle name the box read instead,
# `<box>:<path>`. bg-run keeps no checkout: `--checkout` names one, and as the caller's explicit
# statement it replaces any the record carries; without it a checkout already on the record is
# kept, and otherwise the field says it was not recorded.
conclude_from_bg_run() {
  local dir="$1" request="$2" box="$3" host="$4" sha="$5" checkout="$6" evidence="$7" bgrun="$8"
  local facts rc status code sentinel scode verdict note=""
  facts=$({ prelude "$box"; from_bg_run_script "$bgrun"; } | run_on "$box" "$dir"); rc=$?
  if unreachable "$rc"; then echo "FROM-BG-RUN UNREACHABLE $box: nothing concluded"; return 4; fi
  [ "$rc" -eq 0 ] || { printf '%s\n' "$facts"; return 1; }
  status=$(sed -n 's/^status=//p' <<<"$facts")
  case "$status" in
    DIED)
      verdict=cancelled
      note="bg-run $dir on $box: DIED -- the task was killed before the command returned (no rc), and neither it nor the command is alive" ;;
    rc)
      code=$(sed -n 's/^rc=//p' <<<"$facts"); sentinel=$(sed -n 's/^sentinel=//p' <<<"$facts")
      [[ "$code" =~ ^[0-9]+$ ]] || { echo "FROM-BG-RUN REFUSED: unreadable run facts from $box: $facts"; return 1; }
      note="bg-run $dir on $box: rc=$code"
      if [ -n "$sentinel" ]; then
        scode=${sentinel##*exit: }
        note="$note, runner sentinel '$sentinel'"
        [ "$scode" = 0 ] || code="$scode"
      fi
      case "$code" in 0) verdict=pass ;; 124|142) verdict=timeout ;; 129|130|137|143) verdict=cancelled ;; *) verdict=fail ;; esac
      note="$note; the command returned" ;;
    *) echo "FROM-BG-RUN REFUSED: unreadable run facts from $box: $facts"; return 1 ;;
  esac
  [ -n "$evidence" ] || evidence="$note; revision $sha as reported by the worker"
  [ "$box" = "$host" ] || evidence="$evidence; directory read on $box, which drove the run on $host"
  jq -cn --arg id "$request" --arg ev "$evidence" --arg sha "$sha" --arg co "$checkout" \
    --arg handle "bg-run:$box:$dir" --arg log "$box:$dir/log" --arg verdict "$verdict" \
    '{request_id: $id, evidence: $ev, observed_sha: $sha, remote_checkout: $co, handle: $handle, log: $log, verdict: $verdict}'
}

# in_roster <name>: is that an exact FLEET_BOXES entry? The registry refuses an execution host
# and a slots-spec box that is not one, and the run-time lock must read the same configuration.
in_roster() {
  local name="$1" entry
  local -a roster=()
  read -r -d "" -a roster <<< "$BOXES" || :
  for entry in ${roster[@]+"${roster[@]}"}; do [ "$entry" = "$name" ] && return 0; done
  return 1
}

# box_correctness_slots <box>: that box's correctness slot count from $SLOTS on stdout (a box
# the spec does not name has one), or a refusal line on stdout and return 1 for a malformed spec.
# The same grammar the registry enforces, read here so the run-time lock and the registry agree --
# including on a spec that names a box twice, where the registry's dict keeps the LAST value: a
# first-match read here would have let six batches run against a registry admitting one.
box_correctness_slots() { box_spec_count FLEET_BOX_CORRECTNESS_SLOTS "$SLOTS" "$1" 1; }

# box_gpu_tokens <box>: how many of that box's slots may hold its GPU at once, from $GPU_TOKENS
# (ludics-lite#391) in the same grammar; a box the spec does not name has one per slot. Needs the
# slot count to be valid, so a malformed slots spec refuses here too.
box_gpu_tokens() {
  local slots
  slots=$(box_correctness_slots "$1") || { echo "$slots"; return 1; }
  box_spec_count FLEET_BOX_GPU_TOKENS "$GPU_TOKENS" "$1" "$slots"
}

# box_spec_count <variable> <spec> <box> <default>: the shared reader of the two `<box>=<n>` specs.
box_spec_count() {
  local name="$1" spec="$2" box="$3" found="$4" pair count
  local -a pairs=()
  read -r -d "" -a pairs <<< "$spec" || :
  for pair in ${pairs[@]+"${pairs[@]}"}; do
    count="${pair#*=}"
    case "$pair" in *=*) ;; *) count="" ;; esac
    case "$count" in ''|*[!0-9]*) echo "$name entry must be <box>=<positive n>: $pair"; return 1 ;; esac
    [ "$count" -ge 1 ] || { echo "$name entry must be <box>=<positive n>: $pair"; return 1; }
    in_roster "${pair%%=*}" || { echo "$name names ${pair%%=*}, which is not in FLEET_BOXES"; return 1; }
    [ "${pair%%=*}" = "$box" ] && found="$count"
  done
  echo "$found"
}

# `execution slot [--wait <seconds>] -- <command...>`: the RUN-TIME half of the correctness cap
# (ludics-lite#160). The registry reservation is ownership and evidence, held for a worker's whole
# life including its review waits, so counting it against the box's slots capped agents in flight
# rather than concurrent load -- on 2026-09-16 a fourth worker was refused a standing reservation
# while the three holding the slots were reading their briefs and nothing was running at all. So a
# standing record consumes no slot (`"standing": true` in the reservation), and the slots are taken
# HERE instead, by the worker itself, around one suite or batch.
#
# The lock is a real flock, N holders: one file per slot under the box's own state directory, and
# the holder is the open descriptor, inherited across the exec of the wrapped command. That is why
# there is no stale-lock reclaim to get wrong -- the kernel drops the lock when the process dies,
# however it dies, including a kill -9 of a whole batch. The repository's own mkdir `take_lock`
# could not serve: it is defined in the far-side prelude, for scripts shipped to a box, and this
# lock has to outlive the acquiring process's exec on THIS box. There is no --box for the same
# reason: a slot on another machine would be a lock on the wrong disk.
#
# THE GPU TOKENS (ludics-lite#391). On rog-nv-linux the bound is the GPU's 12 GiB, not the box:
# three concurrent cuda batches ran out of device memory, while two ran clean beside two cc
# batches. So where FLEET_BOX_GPU_TOKENS gives a box T tokens, fewer than its slots, the first T
# slot files are its GPU tokens: a GPU batch may take only slot.1..slot.T, and a batch declared
# `--cpu` takes the highest free slot, reaching the GPU ones last. Two properties follow, and both
# are why this is not a second lock pool beside the slots:
#   - fail-closed: a batch is a GPU batch unless it declares `--cpu` (`--gpu` says the default),
#     so one whose caller forgot to declare it is still held to T, and a CPU batch that forgot
#     only waits longer;
#   - safe across the switch: the script before #391 gave rog-nv-linux two slots and took the
#     first free one, so a batch it started holds slot.1 or slot.2 -- which this version counts as
#     a token. A separate token pool would have seen two free tokens beside two such batches and
#     let four cuda batches onto the GPU while the box's checkout moved from one version to the
#     other.
# The cost is fragmentation: a CPU batch that fell back into a GPU slot keeps it until it ends,
# even after a higher slot frees. A GPU batch waiting on a token holds no slot meanwhile. Where a
# box has as many tokens as slots nothing binds, and every batch takes the first free slot as
# before, so every box but the one the token spec narrows is unchanged.
#
# The measurement check is a point-in-time gate read from the anchor's registry, exactly as
# `execution dispatch` is: it refuses to start a batch beside an outstanding measurement, and
# a measurement reserved afterwards is the registry's exclusivity to enforce, not this lock's.
#
# EVERY correctness run on the box goes through this lock, an assigned one (a full suite, a
# cross-box leg) exactly as much as a standing worker's batch: it is the single run-time
# mechanism, and the registry's reservation cap stays a bound on how many non-standing
# assignments may be QUEUED there. Subtracting outstanding assignments from the cap here would
# re-introduce the very thing #160 removes - a run refused because of a record that is not
# running, its own included.
#
# Inside the slot the command runs under the OS-level sleep guard `execution hold` takes
# (ludics-lite#317, below), so a correctness batch on a native Linux box carries the guard a
# measurement does, for exactly as long as the batch runs. One Python program serves both
# subcommands; `slot` is `hold` plus the flock.
# Exit: the wrapped command's own status; 1 with a line beginning `EXECUTION SLOT REFUSED` (no
# free slot or GPU token before the deadline, an outstanding measurement, a malformed spec); 4 when the
# anchor's registry could not be read; 127 when the command itself could not be run. The command
# is exec'd and not interpreted, so a pipeline or a builtin goes as `sh -c '...'`.
#
# THE GUARD (ludics-lite#317). Under WSL the Windows-side holder kept a lane's box alive; on
# native Ubuntu nothing at the OS level stopped another session's `wake-lab.sh sleep`, or an idle
# suspend, from taking a box out from under a running worker, because the lab locks are advisory
# and bind only sessions that go through wake-lab.sh. A logind BLOCK inhibitor on sleep:idle is
# the OS-side answer: systemd 259's `systemctl --check-inhibitors=yes suspend` (wake-lab.sh's
# path) refuses on any `block` inhibitor covering sleep, the caller's own uid included -- only
# `block-weak` exempts the same user, which is why the mode here is `block` -- and logind itself
# refuses a suspend request from anyone without `suspend-ignore-inhibit`, a GDM greeter's
# included.
#
# The inhibitor is held by a HELPER beside the command, never by a wrapper around it, and that
# shape is forced by what systemd-inhibit does to the process it runs (measured on rog-nv-linux,
# systemd 259): it closes every descriptor above 2 in its child, so a batch run UNDER it would
# no longer inherit the slot's flock; it SIGTERMs that child when it dies itself; and it turns a
# command killed by a signal into exit 1 and adds a "<cmd> failed with exit status <n>." line --
# a wrapper that changes verdicts, and a PID that is not the workload's, so killing `$!` would
# kill systemd-inhibit and not the batch (PR #323 review, round 1). So the helper is
# `systemd-inhibit ... -- sh -c 'echo HELD; exec cat'`, reading a LIFETIME PIPE whose write end
# the command inherits, and the command is exec'd exactly as before, on this PID, with the flock:
# the inhibitor then lives as long as anything in the command's process tree holds that pipe --
# the same lifetime as the flock, ended by the kernel however the tree ends, including a kill -9
# of the command alone. The helper is double-forked so it is never the command's child: a
# workload that waits for all of its children would otherwise wait on it forever. It reports
# through a readiness pipe -- HELD once the inhibitor is taken, or systemd-inhibit's own refusal
# and EOF -- and the command starts only after that answer, so there is no window in which the
# run has started and the box is not yet held.
#
# Fail-open, and loudly. An unprivileged ssh session is a REMOTE subject to polkit, so
# `org.freedesktop.login1.inhibit-block-sleep` falls under its `allow_any`, which stock Ubuntu
# sets to auth_admin_keep: until the box's one-time polkit grant is installed (executions.md,
# "The OS-level sleep guard") the request is denied. A run refused for that would stop every
# batch on the box over a setup step, so a denial prints a WARNING naming it and runs the command
# bare -- exactly as it runs on macOS, or on a Linux host with no systemd-inhibit at all.
# No `--no-ask-password`: systemd-inhibit gained it in v257, so 255 (Ubuntu 24.04) and 256 reject
# it as an unknown option, which would turn every hold there into the unguarded path (PR #323
# review, round 1). It is not needed either: the helper's stdio are pipes, so systemd-inhibit has
# no terminal to start a polkit agent on, and a denial comes back at once.
run_py() {
  cat <<'RUN_PY'
import fcntl, os, select, shutil, signal, sys, time
mode, box = sys.argv[1], sys.argv[2]
if mode == "slot":
    directory, cap, tokens, cpu = sys.argv[3], int(sys.argv[4]), int(sys.argv[5]), sys.argv[6] == "cpu"
    wait, inhibitor = int(sys.argv[7]), sys.argv[8]
    why, command = "", sys.argv[9:]
    prefix = "EXECUTION SLOT"
else:
    inhibitor, why, command = sys.argv[3], sys.argv[4], sys.argv[5:]
    prefix = "EXECUTION HOLD"
HOLD_WAIT = 30  # seconds for systemd-inhibit to answer HELD or refuse; it answers at once

def refuse_unrunnable(exc):
    print("%s REFUSED %s: cannot run %s: %s" % (prefix, box, command[0], exc))
    sys.exit(127)

def start_guard(why):
    """Take the sleep:idle block inhibitor in a helper; return the lifetime pipe's write end, or None."""
    sys.stdout.flush(); sys.stderr.flush()  # nothing buffered may be written twice by a fork
    if len(why) > 160:  # one line of `systemd-inhibit --list` and of `wake-lab.sh status`
        why = why[:157] + "..."
    life_r, life_w = os.pipe()
    ready_r, ready_w = os.pipe()
    middle = os.fork()
    if middle == 0:
        helper = os.fork()
        if helper == 0:
            try:
                os.dup2(life_r, 0); os.dup2(ready_w, 1); os.dup2(ready_w, 2)
                os.closerange(3, 65536)  # the slot flock, the lifetime pipe's write end, all of it
                signal.signal(signal.SIGPIPE, signal.SIG_DFL)
                os.execv(inhibitor, [inhibitor, "--what=sleep:idle", "--mode=block", "--who=fleet-worker",
                                     "--why=" + why, "--", "sh", "-c", "echo HELD; exec cat >/dev/null"])
            finally:
                os._exit(127)
        os.write(ready_w, ("PID %d\n" % helper).encode())
        os._exit(0)
    os.waitpid(middle, 0)
    os.close(life_r); os.close(ready_w)
    text, helper, held = b"", None, False
    deadline = time.monotonic() + HOLD_WAIT
    while not held:
        left = deadline - time.monotonic()
        if left <= 0 or not select.select([ready_r], [], [], left)[0]:
            text += b"no answer from systemd-inhibit after %ds" % HOLD_WAIT
            break
        chunk = os.read(ready_r, 4096)
        if not chunk:
            break
        text += chunk
        lines = text.split(b"\n")
        held = b"HELD" in lines
        for line in lines:
            if line.startswith(b"PID "):
                helper = int(line[4:])
    os.close(ready_r)
    if held:
        sys.stderr.write("EXECUTION HOLD %s: sleep:idle block inhibitor held for: %s\n" % (box, why))
        os.set_inheritable(life_w, True)
        return life_w
    if helper is not None:
        try:
            os.kill(helper, signal.SIGTERM)
        except OSError:
            pass
    os.close(life_w)
    detail = b" ".join(l for l in text.split(b"\n") if l and not l.startswith(b"PID ")).decode("utf-8", "replace")
    sys.stderr.write("EXECUTION HOLD %s: WARNING: running WITHOUT a sleep inhibitor, so nothing at the OS level"
                     " stops a suspend under it -- %s refused: %s (the one-time polkit grant:"
                     " issue-wave/references/executions.md, \"The OS-level sleep guard\")\n"
                     % (box, inhibitor, detail[:200]))
    return None

def run(why):
    # Resolved before the guard: a command that cannot be found takes no inhibitor.
    if shutil.which(command[0]) is None:
        refuse_unrunnable("no such executable")
    if inhibitor:
        start_guard(why)
    sys.stderr.flush()
    try:
        # Python ignores SIGPIPE, and an IGNORED disposition survives exec: without this the
        # wrapped batch would see `yes | head -n1` exit 1 with a "Broken pipe" diagnostic
        # where the same script run directly exits 141. A wrapper must not change verdicts.
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        os.execvp(command[0], command)
    except OSError as exc:
        # A script whose interpreter is missing passes the lookup above and fails here.
        refuse_unrunnable(exc)

if mode == "hold":
    run(why)

# The candidate slots, in the order this batch tries them. Where the box has fewer GPU tokens
# than slots, the tokens ARE the first <tokens> slot files: a GPU batch may take only those, and a
# CPU batch takes the highest free slot, so it leaves the GPU ones for last (THE GPU TOKENS, above).
if not tokens:
    order = range(1, cap + 1)
elif cpu:
    order = range(cap, 0, -1)
else:
    order = range(1, tokens + 1)
deadline = time.monotonic() + wait
while True:
    for index in order:
        descriptor = os.open(os.path.join(directory, "slot.%d" % index), os.O_CREAT | os.O_RDWR, 0o644)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(descriptor)
            continue
        # The lock lives on this descriptor: it must survive the exec below, so it must not be
        # closed on it. Nothing releases it afterwards -- the kernel does, when the process ends.
        os.set_inheritable(descriptor, True)
        held = "slot %d of %d" % (index, cap)
        if tokens and index <= tokens:
            held += ", GPU token %d of %d" % (index, tokens)
        sys.stderr.write("EXECUTION SLOT %s: %s held for: %s\n" % (box, held, " ".join(command)))
        run("%s %s: %s" % (box, held, " ".join(command)))
    if time.monotonic() >= deadline:
        if tokens and not cpu:
            print("EXECUTION SLOT REFUSED %s: all %d GPU tokens (slots 1-%d of %d) busy after %ds; a batch"
                  " that holds no GPU declares --cpu" % (box, tokens, tokens, cap, wait))
        else:
            print("EXECUTION SLOT REFUSED %s: all %d run-time correctness slots busy after %ds"
                  % (box, cap, wait))
        sys.exit(1)
    time.sleep(1)
RUN_PY
}

# inhibitor_path: the systemd-inhibit this box would take the guard with, or empty for none.
inhibitor_path() { type -P -- "$INHIBIT" 2>/dev/null || true; }

cmd_execution_slot() {
  local wait=600 kind="" box cap tokens listing rc measuring dir helper
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --wait)
        [ "$#" -ge 2 ] || die "execution slot: expected value for --wait"
        case "$2" in ''|*[!0-9]*) die "execution slot: --wait takes a whole number of seconds" ;; esac
        wait="$2"; shift ;;
      --cpu|--gpu)
        [ -z "$kind" ] || [ "$kind" = "$1" ] || die "execution slot: --cpu and --gpu are exclusive"
        kind="$1" ;;
      --) shift; break ;;
      *) die "execution slot [--wait <seconds>] [--cpu|--gpu] -- <command> [args...]" ;;
    esac
    shift
  done
  [ "$#" -ge 1 ] || die "execution slot: a command to hold the slot around is required, after --"
  box="$LOCAL_BOX"
  [ -n "$box" ] || die "execution slot: this host has no fleet name; set FLEET_LOCAL_BOX (the slot is this box's own)"
  # An alias or a typo would lock under a name of its own and read measurements under another,
  # so a batch could run beside a measurement reserved on the canonical spelling of this very box.
  # The registry refuses a noncanonical execution_host for the same reason; this is that check.
  in_roster "$box" || { echo "EXECUTION SLOT REFUSED $box: not a canonical FLEET_BOXES entry ($BOXES)"; exit 1; }
  cap=$(box_correctness_slots "$box") || { echo "EXECUTION SLOT REFUSED $box: $cap"; exit 1; }
  tokens=$(box_gpu_tokens "$box") || { echo "EXECUTION SLOT REFUSED $box: $tokens"; exit 1; }
  # Where there are as many tokens as slots the tokens cannot bind, and every batch takes any slot.
  [ "$tokens" -lt "$cap" ] || tokens=0
  helper="$(cd "$(dirname "$0")" && pwd)/fleet-execution.py"
  [ -s "$helper" ] && [ -r "$helper" ] || die "execution: missing helper $helper"
  listing=$(execution_listing "$helper"); rc=$?
  if unreachable "$rc"; then echo "EXECUTION SLOT UNREACHABLE $ANCHOR: registry unread, no slot taken"; exit 4; fi
  [ "$rc" -eq 0 ] || { printf '%s\n' "$listing"; echo "EXECUTION SLOT REFUSED $box: the anchor's registry could not be read"; exit 1; }
  measuring=$(jq -r --arg box "$box" \
    '[.[] | select(.state != "concluded" and .request.execution_host == $box and .request.kind == "measurement")
       | .request_id] | join(", ")' <<<"$listing") ||
    { echo "EXECUTION SLOT REFUSED $box: the anchor's registry did not parse"; exit 1; }
  [ -z "$measuring" ] || { echo "EXECUTION SLOT REFUSED $box: a measurement holds the box exclusively ($measuring)"; exit 1; }
  dir="$(local_path "$SLOT_STATE")/$box"
  mkdir -p "$dir" || die "execution slot: cannot create the slot directory $dir"
  exec python3 -c "$(run_py)" slot "$box" "$dir" "$cap" "$tokens" "${kind#--}" "$wait" "$(inhibitor_path)" "$@"
}

# `execution hold [--why <text>] -- <command...>`: run the command under THIS box's OS-level
# guard against sleep and nothing else -- no slot, no registry read, no lease (ludics-lite#317;
# the guard itself is described above `run_py`). It is the wrapper for an exclusive measurement,
# which runs the runner directly because `execution slot` refuses while a measurement is
# outstanding, and `slot` takes the same guard inside the flock, so both kinds of run carry it
# through one implementation. Where no systemd-inhibit resolves it runs the command bare and
# says nothing. Needs python3, as `slot` does (the per-box preflight checks it).
# Exit: the command's own status; 127 with `EXECUTION HOLD REFUSED` when it cannot be run; 2 usage.
cmd_execution_hold() {
  local why="" box
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --why)
        [ "$#" -ge 2 ] && [ -n "$2" ] || die "execution hold: expected text for --why"
        why="$2"; shift ;;
      --) shift; break ;;
      *) die "execution hold [--why <text>] -- <command> [args...]" ;;
    esac
    shift
  done
  [ "$#" -ge 1 ] || die "execution hold: a command to hold the box around is required, after --"
  box="${LOCAL_BOX:-$(hostname -s 2>/dev/null)}"
  [ -n "$why" ] || why="$box hold: $*"
  exec python3 -c "$(run_py)" hold "$box" "$(inhibitor_path)" "$why" "$@"
}

cmd_execution() {
  local action="${1:-}" payload='{}'
  case "$action" in
    list)
      shift
      local active=false compact=false
      while [ "$#" -gt 0 ]; do
        case "$1" in
          --active) active=true ;;
          --compact) compact=true ;;
          *) die "execution list: expected --active or --compact" ;;
        esac
        shift
      done
      payload="{\"active\":$active,\"compact\":$compact}" ;;
    # The run-time slot lock: no registry mutation, no lease, and the command runs from here.
    slot) shift; cmd_execution_slot "$@" ;;
    # The OS-level sleep guard alone: no slot, no registry, no lease.
    hold) shift; cmd_execution_hold "$@" ;;
    conclude)
      if [ "${2:-}" = --from-run ]; then
        local dir="${3:-}" request="" box="" sha="" evidence="" rc
        [ -n "$dir" ] || die "execution conclude --from-run: <run-dir> required"
        case "$dir" in /*) ;; *) die "execution conclude --from-run: the run directory must be absolute (it is read on the execution box)" ;; esac
        shift 3
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --request|--box|--sha|--evidence)
              [ "$#" -ge 2 ] && [ -n "$2" ] || die "execution conclude: expected value for $1"
              case "$1" in --request) request="$2" ;; --box) box="$2" ;; --sha) sha="$2" ;; --evidence) evidence="$2" ;; esac
              shift ;;
            *) die "execution conclude --from-run <run-dir> --request <id> [--box <box>] [--sha <sha>] [--evidence <text>]" ;;
          esac
          shift
        done
        [ -n "$request" ] || die "execution conclude --from-run: --request <id> required"
        [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "execution conclude --from-run: --sha <full commit SHA> required (the record carries none; the worker's result line names it)"
        check_identity
        if [ -z "$box" ]; then
          box=$(execution_host_of "$(cd "$(dirname "$0")" && pwd)/fleet-execution.py" "$request") || { echo "EXECUTION UNREACHABLE $ANCHOR: cannot resolve the request's execution host"; exit 4; }
          [ -n "$box" ] || { echo "EXECUTION REFUSED: unknown request_id $request (no execution host to read the run on)"; exit 1; }
        fi
        payload=$(conclude_from_run "$dir" "$request" "$box" "$sha" "$evidence"); rc=$?
        [ "$rc" -eq 0 ] || { printf '%s\n' "$payload"; exit "$rc"; }
      elif [ "${2:-}" = --from-bg-run ]; then
        local dir="${3:-}" request="" box="" sha="" evidence="" checkout="" rc listing host bgrun
        local usage="execution conclude --from-bg-run <run-dir> --request <id> --sha <sha> [--box <box>] [--checkout <text>] [--evidence <text>]"
        [ -n "$dir" ] || die "execution conclude --from-bg-run: <run-dir> required"
        case "$dir" in /*) ;; *) die "execution conclude --from-bg-run: the run directory must be absolute (it is read on the box that holds it)" ;; esac
        shift 3
        while [ "$#" -gt 0 ]; do
          case "$1" in
            --request|--box|--sha|--evidence|--checkout)
              [ "$#" -ge 2 ] && [ -n "$2" ] || die "execution conclude: expected value for $1"
              case "$1" in --request) request="$2" ;; --box) box="$2" ;; --sha) sha="$2" ;; --evidence) evidence="$2" ;; --checkout) checkout="$2" ;; esac
              shift ;;
            *) die "$usage" ;;
          esac
          shift
        done
        [ -n "$request" ] || die "execution conclude --from-bg-run: --request <id> required"
        [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || die "execution conclude --from-bg-run: --sha <full commit SHA> required (a bg-run directory records none; the worker's result line names it)"
        bgrun="$(cd "$(dirname "$0")" && pwd)/bg-run.sh"
        [ -s "$bgrun" ] && [ -r "$bgrun" ] || die "execution conclude --from-bg-run: missing $bgrun"
        check_identity
        listing=$(execution_listing "$(cd "$(dirname "$0")" && pwd)/fleet-execution.py"); rc=$?
        if unreachable "$rc"; then echo "EXECUTION UNREACHABLE $ANCHOR: cannot resolve the request's execution host"; exit 4; fi
        [ "$rc" -eq 0 ] || { printf '%s\n' "$listing"; echo "EXECUTION REFUSED: the anchor's registry could not be read"; exit 1; }
        host=$(jq -r --arg id "$request" '.[] | select(.request_id == $id) | .request.execution_host' <<<"$listing")
        [ -n "$host" ] || { echo "EXECUTION REFUSED: unknown request_id $request (no execution host to read the run for)"; exit 1; }
        # Without --checkout the record's own checkout is restated, or the placeholder when it has
        # none -- always spelled out in the payload, so a retry of a conclusion whose answer was
        # lost composes the same payload and meets the registry's identical-retry rule.
        [ -n "$checkout" ] || checkout=$(jq -r --arg id "$request" '.[] | select(.request_id == $id) | .remote_checkout // empty' <<<"$listing")
        [ -n "$checkout" ] || checkout="not recorded (bg-run keeps no checkout; the log names what ran)"
        payload=$(conclude_from_bg_run "$dir" "$request" "${box:-$host}" "$host" "$sha" "$checkout" "$evidence" "$bgrun"); rc=$?
        [ "$rc" -eq 0 ] || { printf '%s\n' "$payload"; exit "$rc"; }
      else
        [ "$#" -eq 2 ] && [ -r "$2" ] || die "execution $action: readable JSON file required"
        payload=$(cat "$2") || die "execution: cannot read payload"
        check_identity
      fi ;;
    reserve|run|dispatch|record|reconcile)
      [ "$#" -eq 2 ] && [ -r "$2" ] || die "execution $action: readable JSON file required"
      payload=$(cat "$2") || die "execution: cannot read payload"
      check_identity ;;
    *) die "execution: list, slot -- <command>, hold -- <command>, run|reserve|dispatch|record|reconcile|conclude <json-file>, or conclude --from-run|--from-bg-run <run-dir> --request <id>" ;;
  esac
  local helper out rc map=""; helper="$(cd "$(dirname "$0")" && pwd)/fleet-execution.py"
  [ -s "$helper" ] && [ -r "$helper" ] || die "execution: missing helper $helper"
  case "$action" in reserve|run|dispatch) map=$(endpoint_map) || exit 1 ;; esac
  out=$({
    prelude "$ANCHOR"
    if [ "$action" != list ]; then lease_mutation_prelude; else printf 'shift 3\n'; fi
    cat <<'EXECUTION_COMMAND'
python3 - "$ANCHOR_STATE" "$@" <<'FLEET_EXECUTION_PY'
EXECUTION_COMMAND
    cat "$helper"
    printf '\nFLEET_EXECUTION_PY\n'
  } | run_on "$ANCHOR" EXECUTION "$(my_token)" "${FLEET_LOCK_WAIT:-10}" "$action" "$(coordinator_id)" "$(my_token)" "$payload" "$BOXES" "$SLOTS" "$map"); rc=$?
  [ -z "$out" ] || printf '%s\n' "$out"
  if unreachable "$rc"; then echo "EXECUTION UNREACHABLE $ANCHOR: outcome unknown; reconcile before retrying dispatch"; exit 4; fi
  if [ "$rc" -eq 0 ]; then case "$action" in run|dispatch) execution_refresh "$out" >&2 ;; esac; fi
  exit "$rc"
}

# endpoint_map: the lab's endpoint map as `wake-lab.sh endpoint-map` prints it, one `<box> <alias>...`
# line per box, for the registry's one-entry-per-box roster check (ludics-lite#395; the grammar and
# its boundary are fleet-execution.py's header). Read from THIS checkout's wake-lab.sh, found by the
# physical path (the skill is reached through a ~/.claude/skills symlink), so the map is never
# restated here. No wake-lab.sh in the checkout degrades loudly: one EXECUTION WARNING on stderr and
# an empty map, which keeps the roster check to exact entries up to case, as before. A wake-lab.sh
# that refuses its own map refuses the reservation: a map that is there and wrong is a defect to fix.
endpoint_map() {
  local wake out
  # cd -P: `..` must leave the skill symlink's TARGET, not collapse the symlink's own path.
  wake="$(cd -P "$(dirname "$0")/../.." && pwd -P)/scripts/wake-lab.sh"
  if [ ! -f "$wake" ]; then
    printf '%s\n' "EXECUTION WARNING: no endpoint map ($wake is missing): FLEET_BOXES is not checked for two aliases of one box" >&2
    return 0
  fi
  out=$(bash "$wake" endpoint-map) || {
    printf '%s\n' "EXECUTION REFUSED: $wake endpoint-map failed (above), so FLEET_BOXES cannot be checked for two aliases of one box" >&2
    return 1
  }
  printf '%s\n' "$out"
}

# execution_refresh <record-json>: after a dispatch, refresh the execution host's skills checkout
# (ludics-lite#362), since that box's own `execution slot`/`hold` and skill text are what the
# assigned command runs next. AFTER the dispatch, never before it: the registry lock is released by
# then, so a fetch that hangs cannot hold it, and a refused reservation - the box measuring for
# someone else - never has its checkout touched. Every host, this box and the anchor included: no
# launch preflight need have run on the box the coordinator itself runs from (PR #379 review). On
# stderr, so stdout stays the record; the dispatch's exit status stands whatever the refresh
# reports, and a record it cannot read is said so rather than skipped silently.
execution_refresh() {
  local host
  host=$(jq -r '.request.execution_host // empty' <<<"$1" 2>&1) && [ -n "$host" ] || {
    printf '%s\n' "REFRESH FAILED: cannot read the execution host from the dispatched record (${host:-empty}); run fleet-worker.sh refresh <host> by hand"
    return 1
  }
  refresh_box "$host"
}

cmd_halt() {
  local reason="$*"; [ -n "$reason" ] || die "halt: give the reason (what regressed, who owns the fix)"
  local halt_id; halt_id=$(gen_uuid) || die "halt: cannot generate a halt identity"
  check_identity
  { prelude "$ANCHOR"; lease_mutation_prelude; cat <<'EOF'
halt="$ANCHOR_STATE/HALT"; halt_id="$2"
if [ -f "$halt" ]; then
  existing_id=$(sed -n '1s/^[^ ]* id=\([^ ]*\) .*/\1/p' "$halt")
  if [ -z "$existing_id" ]; then
    # Legacy markers have no ID: retain their first line as the generation, append the update.
    if printf 'update %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$halt"; then
      echo "HALTED: launches refused until resume-launches -- $1"; exit 0
    fi
    echo "HALT FAILED: cannot update $halt on $BOX"; exit 1
  fi
  halt_id="$existing_id"
fi
if ! printf '%s id=%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$halt_id" "$1" > "$ANCHOR_STATE/HALT" 2>/dev/null || [ ! -f "$ANCHOR_STATE/HALT" ]; then
  echo "HALT FAILED: cannot write $ANCHOR_STATE/HALT on $BOX -- the fleet is NOT halted"; exit 1
fi
echo "HALTED: launches refused until resume-launches -- $1"
EOF
  } | run_on "$ANCHOR" HALT "$(my_token)" "${FLEET_LOCK_WAIT:-10}" "$reason" "$halt_id"
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
  gate) cmd_gate "$@" ;;
  preflight) cmd_preflight "$@" ;;
  refresh) cmd_refresh "$@" ;;
  launch) cmd_launch "$@" ;;
  attach) cmd_attach "$@" ;;
  status) cmd_status "$@" ;;
  log) cmd_log "$@" ;;
  unstick) cmd_unstick "$@" ;;
  ls) cmd_ls "$@" ;;
  load) cmd_load "$@" ;;
  prs) cmd_prs "$@" ;;
  execution) cmd_execution "$@" ;;
  halt) cmd_halt "$@" ;;
  resume-launches) cmd_resume_launches "$@" ;;
  halted) cmd_halted "$@" ;;
  claim) cmd_claim "$@" ;;
  release) cmd_release "$@" ;;
  coordinator) cmd_coordinator "$@" ;;
  *) sed -n '/^# Usage:/,/^# Exit:/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
esac
