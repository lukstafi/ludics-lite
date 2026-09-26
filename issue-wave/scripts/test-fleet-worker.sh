#!/usr/bin/env bash
# Exercises fleet-worker.sh against the local box with shim `claude`/`codex` CLIs on PATH -- no
# model calls, no network, no ssh. Every case runs in a scratch HOME with its own tmux socket and
# state dir, so it is safe beside real workers. The far-side script is the same for local and
# remote boxes, so what passes here is what runs over ssh; only the transport is untested.
#
# Usage: test-fleet-worker.sh [section ...] (exit 0 all pass, 1 otherwise; skips with a notice
#                                          when tmux is not installed, which is the CI runner's
#                                          state unless the workflow installs it)
#        test-fleet-worker.sh --list       (the section names)
#
# With no arguments every section runs; each argument selects every section whose name contains
# it, so a prefix or any distinctive substring will do. An argument matching no section is refused
# before anything runs. The setup the sections share -- the shim CLIs, the scratch skills checkout,
# the scratch project repo -- runs whatever is selected, and a section that needs more than that
# (the coordinator lease, a finished worker) takes it explicitly, so any section runs on its own.

set -uo pipefail
# No `... | grep -q` under that pipefail: grep exits on its first match and the writer takes
# SIGPIPE, so the pipeline reads 141 -- a refusal message long enough for two writes turned the
# ownership-race assertion into a flake (the gh-ocannl-949 mechanism). Matches read from files or
# here-strings, which bash backs with a file.

# One brace group, so bash parses this file WHOLE before its first line runs and an edit landing
# while a run is in flight cannot resume the shell at a shifted offset; the `exit` at the foot
# means the shell never comes back to the file for a next command. Two lines here and two at the
# foot, with the body's own indentation untouched (ludics-lite#10, #247); scripts/check-parse-guards.sh
# checks the shape.
{
HERE=$(cd "$(dirname "$0")" && pwd)
FW="$HERE/fleet-worker.sh"

# --- section selection ------------------------------------------------------------------------
# The `--- name` headers below, in the order they run. Arguments are matched against these, and a
# selected run still runs the sections in file order: each reads what the ones above it left.
SECTIONS=(
  "the real checkout under the README's install loops"
  "coordinator lease"
  "base gate"
  "preflight"
  "load"
  "launch / attach / status / log with a project repo and --repo/--branch"
  "failure verdicts"
  "unstick"
  "codex workers"
  "halt"
  "execution run and conclude --from-run"
  "execution conclude --from-bg-run"
  "prs (the supervision read)"
  "refresh (execution-only boxes)"
  "execution slot"
  "usage"
)

usage() {
  cat <<'USAGE'
usage: test-fleet-worker.sh [--list] [section ...]

With no arguments every section runs. Each argument selects every section whose
name contains it, so a prefix or any distinctive substring ("coord", "unstick",
"status") will do; --list prints the names. An argument matching no section is
refused before anything runs.

Selected sections run in file order, after the setup they all share: the shim
CLIs, the scratch skills checkout and the scratch project repo. A section that
needs more than that -- the coordinator lease, a finished worker to read -- takes
it itself, so any section stands on its own.
USAGE
}

NAMED=0
SELECTED=()
# select_section <name>: add it once. Two arguments can match the same section (`coord lease` both
# name the lease section), and a section running twice would assert against its own leftovers.
select_section() {
  local s
  for s in ${SELECTED[@]+"${SELECTED[@]}"}; do [ "$s" = "$1" ] && return 0; done
  SELECTED+=("$1")
}
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0 ;;
    --list) printf '%s\n' "${SECTIONS[@]}"; exit 0 ;;
    -*) echo "FAIL: unknown option: $1" >&2; usage >&2; exit 1 ;;
    *)
      matched=0
      for s in "${SECTIONS[@]}"; do
        case "$s" in *"$1"*) select_section "$s"; matched=1 ;; esac
      done
      [ "$matched" -eq 1 ] || {
        echo "FAIL: no section matches: $1" >&2
        echo "run with --list to see the ${#SECTIONS[@]} section names" >&2
        exit 1
      }
      NAMED=1
      ;;
  esac
  shift
done

# section <name>: print the header, and say whether this run includes the section. Every section
# below is `section "..." && { ... }`, so an unselected one is skipped whole.
section() {
  local s found=0
  [ "$NAMED" -eq 1 ] || found=1
  for s in ${SELECTED[@]+"${SELECTED[@]}"}; do [ "$s" = "$1" ] && found=1; done
  [ "$found" -eq 1 ] || return 1
  echo "--- $1"
}

command -v tmux >/dev/null 2>&1 || { echo "SKIP: tmux not installed"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fleet-worker-test.XXXXXX")
TMP=$(cd "$TMP" && pwd -P)   # canonical: macOS mktemp answers under /var, which resolves to /private/var
export HOME="$TMP/home"
mkdir -p "$HOME/.claude/skills" "$HOME/.codex/skills" "$TMP/bin"
# Hermetic: every ambient FLEET_* and ISSUE_WAVE_* knob is cleared before the suite sets its own. A
# fleet box's ~/.config/fleet/env.sh exports the roster and, on the hub, a slot spec: an inherited
# `mac-studio=6` beside a `testbox other` roster refused every execution case as naming a box
# outside it (ludics-lite#329), and an inherited FLEET_SLOT_STATE would point the slot cases at the
# box's real locks. By prefix, so a knob added later cannot leak either. Every case that depends on
# the roster or the slot spec sets or unsets it itself.
while IFS= read -r v; do
  case "$v" in FLEET_*|ISSUE_WAVE_*) unset "$v" ;; esac
done < <(compgen -e)
# Paths with spaces on purpose: every far-side line that forgets to quote shows up here.
export ISSUE_WAVE_STATE="$TMP/st ate"
export FLEET_TMUX_SOCKET="fwtest-$$"
export FLEET_LOCAL_BOX="testbox"
export FLEET_ANCHOR="testbox"
# The coordinator identity, pinned: without either harness session variable the script refuses to
# guess (tested below), so a test must name it, as would any coordinator whose harness supplies no
# session identity.
export FLEET_COORDINATOR="test-coordinator"
unset CLAUDE_CODE_SESSION_ID CODEX_THREAD_ID
# An exported GitHub token changes the preflight's credential repair text (ludics-lite#360), so the
# runner's own must not reach it.
unset GH_TOKEN GITHUB_TOKEN
export PATH="$TMP/bin:$PATH"
# `execution slot` runs its command under `execution hold`, which wraps it in systemd-inhibit when
# one resolves (ludics-lite#317). The CI runner is Ubuntu, whose real systemd-inhibit would make
# every slot case below a probe of that runner's polkit, so the suite pins it to a name that
# resolves to nothing -- the bare arm, as on macOS -- and the cases that exercise the inhibitor
# point it at a stub instead.
export FLEET_SYSTEMD_INHIBIT="fleet-test-no-systemd-inhibit"
# A scratch git identity, so worktree/commit steps work on a bare runner.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

cleanup() { tmux -L "$FLEET_TMUX_SOCKET" kill-server 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Copy the dispatcher beside a canned base helper: no live GitHub reads, and no
# production bypass knob. The production helper's own suites pin its red diagnostics.
mkdir -p "$TMP/dispatcher/issue-wave/scripts" "$TMP/dispatcher/ship-pr/scripts"
cp "$FW" "$TMP/dispatcher/issue-wave/scripts/fleet-worker.sh"
cp "$HERE/fleet-execution.py" "$TMP/dispatcher/issue-wave/scripts/fleet-execution.py"
cp "$HERE/bg-run.sh" "$TMP/dispatcher/issue-wave/scripts/bg-run.sh"
FW="$TMP/dispatcher/issue-wave/scripts/fleet-worker.sh"
export BASE_CALL_LOG="$TMP/base-calls"
cat > "$TMP/dispatcher/ship-pr/scripts/pr-review.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$* grace=${SHIP_PR_BASE_ABSENT_GRACE:-unset} interval=${SHIP_PR_CHECKS_INTERVAL:-unset}" >> "$BASE_CALL_LOG"
# `prs` reads (SHIM_PRS names a fixture directory): the open-PR list, `rounds`, `checks` and the
# head commit's date, each answered from a file there, or 3 (the API never answered) without one.
if [ -n "${SHIM_PRS:-}" ]; then
  printf '%s\n' "$* threshold=${SHIP_PR_ROUND_THRESHOLD:-unset}" >> "$SHIM_PRS/calls"
  case "$1 $3" in
    "retry pr") [ -f "$SHIM_PRS/list.json" ] || exit 3; cat "$SHIM_PRS/list.json"; exit 0 ;;
    "retry api") [ -f "$SHIM_PRS/date-${4##*/}" ] || exit 3; cat "$SHIM_PRS/date-${4##*/}"; exit 0 ;;
  esac
  case "$1" in
    rounds)
      [ "${SHIP_PR_ROUND_THRESHOLD:-}" = off ] || exit 2
      [ -f "$SHIM_PRS/rounds-${2##*#}" ] || { echo "review rounds: UNKNOWN — fixture; this is NOT 'no rounds yet', retry"; exit 3; }
      echo "review rounds with findings: $(cat "$SHIM_PRS/rounds-${2##*#}") (fixture); no threshold set"; exit 0 ;;
    checks)
      [ -f "$SHIM_PRS/checks-${2##*#}" ] || exit 3
      { read -r crc; read -r line; } < "$SHIM_PRS/checks-${2##*#}"
      printf 'build signal %s @abcdef12: %s\n  a check line\n' "$2" "$line"; exit "$crc" ;;
  esac
  exit 2
fi
if [ "$3" = retry ]; then
  [ -z "${SHIM_BASE_TIP_FAIL:-}" ] || exit 3
  ref="${6##*/}"
  tip=$(git -C "$BASE_PROJECT" rev-parse "origin/$ref") || exit 3
  if [ -n "${SHIM_MOVE_REF_AFTER_CONFIRM:-}" ]; then
    git -C "$BASE_PROJECT" update-ref "refs/remotes/origin/$ref" "$SHIM_MOVE_REF_AFTER_CONFIRM" || exit 3
  fi
  echo "${SHIM_BASE_TIP:-$tip}"
  exit 0
fi
# Fail if the dispatch contract drifts; ambient REPO must not select this read.
[ "$1" = --repo ] && [ "$2" = example/project ] && [ "$3" = base ] || exit 2
[ "${SHIP_PR_BASE_ABSENT_GRACE:-}" = 300 ] || exit 3
# Pinned, not cleared: the ceiling below is arithmetic over the grace AND this interval, so the
# gate has to put both in force rather than leave one to the checker's default (ludics-lite#175).
[ "${SHIP_PR_CHECKS_INTERVAL:-}" = 60 ] || exit 3
for knob in SHIP_PR_ADVISORY_CHECKS SHIP_PR_TEST_SOURCE_ONLY SHIP_PR_CHECKS_WAIT SHIP_PR_CHECKS_HEARTBEAT SHIP_PR_API_ATTEMPTS SHIP_PR_API_BACKOFF; do
  [ -z "${!knob}" ] || exit 3
done
# The gate's one base read is the bounded --wait one: `base --wait` settles a path-filtered tip
# for the older verdict itself (ludics-lite#156), so the gate has no second, plain read to make.
# Its ceiling is DERIVED from the two knobs above — the grace plus one round of the checker's
# wait — and is checked here as that arithmetic rather than against a literal, so a gate that
# moved either knob and left the ceiling behind fails here (ludics-lite#175).
case " $* " in *" --wait=$((SHIP_PR_BASE_ABSENT_GRACE + SHIP_PR_CHECKS_INTERVAL)) "*) ;; *) exit 4 ;; esac
# SHIM_BASE_TOUCH: a marker this read leaves behind, so a test can change the world between the
# preflight and the launch's far side (the tmux shim's SHIM_TMUX_GENV_WHEN reads it).
[ -z "${SHIM_BASE_TOUCH:-}" ] || touch "$SHIM_BASE_TOUCH"
if [ -n "${SHIM_BASE_REQUIRE_PREFLIGHT:-}" ] && [ ! -e "$SHIM_BASE_REQUIRE_PREFLIGHT" ]; then
  echo 'base read occurred before preflight'; exit 3
fi
echo "${SHIM_BASE_MESSAGE:-BASE GREEN example/project tested abc1234}"
exit "${SHIM_BASE_RC:-0}"
EOF
chmod +x "$TMP/dispatcher/ship-pr/scripts/pr-review.sh"

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "PASS: $*"; }
ko() { fail=$((fail + 1)); echo "FAIL: $*"; }
# expect <label> <want-rc> <want-substring> -- <cmd...>; captures output for later assertions in $out.
expect() {
  local label="$1" want_rc="$2" want="$3"; shift 3; [ "$1" = -- ] && shift
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -q -- "$want" <<<"$out"; then ok "$label"
  else ko "$label (rc=$rc want $want_rc; want /$want/) -- $out"; fi
}

# --- shim CLIs ------------------------------------------------------------------------------
# claude: honours -p/--output-format/--session-id/--resume; the brief on stdin drives it: a line
# `SLEEP <n>` sleeps (a live worker to unstick), `FAIL` makes the result an error.
# With --input-format stream-json (a worker's channel, ludics-lite#259) it is the long-lived
# process the real CLI is: one turn per input line, alive until stdin closes, each message echoed
# under its uuid with --replay-user-messages. A line arriving during a SLEEP is taken mid-turn,
# as Claude Code 2.1.282 takes one at its next tool boundary, and its text joins the reply; `BG
# <n>` ends the turn with a background task listed that finishes <n> s later and starts a turn
# of its own; `SILENT` exits 0 with no events; `FAIL` answers with an error result and stays up.
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
sid=""; fmt=text; resume=""; infmt=text; replay=0; probe=0
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) sid="$2"; shift ;;
    --resume) resume="$2"; sid="$2"; shift ;;
    --output-format) fmt="$2"; shift ;;
    --input-format) infmt="$2"; shift ;;
    --replay-user-messages) replay=1 ;;
    --no-session-persistence) probe=1 ;;   # the preflight's live probe
  esac
  shift
done
if [ "$infmt" = stream-json ]; then
  # SHIM_CLAUDE_OLD: a CLI that predates the stream-json channel, as commander reports it.
  [ -z "${SHIM_CLAUDE_OLD:-}" ] || { echo "error: unknown option '--input-format'" >&2; exit 1; }
  if [ "$probe" = 1 ]; then
    [ -z "${SHIM_BASE_REQUIRE_PREFLIGHT:-}" ] || touch "$SHIM_BASE_REQUIRE_PREFLIGHT"
    [ -n "${SHIM_CLAUDE_HANG:-}" ] && sleep 30
  fi
  echo_line() { [ "$replay" = 0 ] || jq -c '. + {isReplay: true}' <<<"$1"; }
  say() { jq -cn --arg t "$1" '{type: "assistant", message: {content: [{type: "text", text: $t}]}}'; }
  result() { jq -cn --arg t "$1" --arg s "$sid" --argjson e "${2:-false}" '{type: "result", subtype: (if $e then "error_during_execution" else "success" end), is_error: $e, num_turns: 1, result: $t, session_id: $s}'; }
  init() { printf '{"type":"system","subtype":"init","session_id":"%s","resumed":%s}\n' "$sid" "$([ -n "$resume" ] && echo true || echo false)"; }
  while IFS= read -r line; do
    msg=$(jq -r '.message.content // empty' <<<"$line" 2>/dev/null)
    init; echo_line "$line"
    grep -q '^SILENT' <<<"$msg" && exit 0
    extra=""
    n=$(sed -n '/^SLEEP [0-9]/ { s/^SLEEP \([0-9]*\).*/\1/; p; q; }' <<<"$msg")
    i=0
    while [ -n "$n" ] && [ "$i" -lt "$n" ]; do
      if IFS= read -r -t 1 more; then
        echo_line "$more"; extra="$extra +msg: $(jq -r '.message.content // empty' <<<"$more" | tr '\n' ' ' | cut -c1-30)"
      else
        rs=$?; [ "$rs" -gt 128 ] || sleep 1   # >128 is the timeout, which already waited
      fi
      i=$((i + 1))
    done
    text="did: $(printf '%s' "$msg" | tr '\n' ' ' | cut -c1-40)$extra"
    say "$text"
    if grep -q '^FAIL' <<<"$msg"; then result "boom: $text" true; continue; fi
    bg=$(sed -n '/^BG [0-9]/ { s/^BG \([0-9]*\).*/\1/; p; q; }' <<<"$msg")
    if [ -n "$bg" ]; then
      echo '{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1","task_type":"local_bash"}]}'
      result "$text"; sleep "$bg"
      # As the real CLI: the task list clears, then the notification lands, then the new turn's
      # init, in separate writes (gaps widened so a reader can land between them).
      echo '{"type":"system","subtype":"background_tasks_changed","tasks":[]}'
      sleep 2; echo '{"type":"system","subtype":"task_notification","task_id":"b1","status":"completed"}'
      sleep 2; init; text="background task done"; say "$text"
    fi
    result "$text"
  done
  exit 0
fi
brief=$(cat)
# The real CLI refuses an empty stdin prompt; the shim must too, or a probe whose prompt was lost
# on the way (bash 3.2 backgrounding, the mac-studio preflight failure) passes here and fails live.
[ -n "$brief" ] || { echo "Error: Input must be provided either through stdin or as a prompt argument when using --print" >&2; exit 1; }
sleep_s=$(sed -n '/^SLEEP [0-9]/ { s/^SLEEP \([0-9]*\).*/\1/; p; q; }' <<<"$brief")
[ -n "${SHIM_CLAUDE_HANG:-}" ] && sleep 30
if [ "$fmt" = json ]; then
  [ -z "${SHIM_BASE_REQUIRE_PREFLIGHT:-}" ] || touch "$SHIM_BASE_REQUIRE_PREFLIGHT"
  printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"%s"}\n' "${sid:-none}"; exit 0
fi
if grep -q '^SILENT' <<<"$brief"; then exit 0; fi
printf '{"type":"system","subtype":"init","session_id":"%s","resumed":%s}\n' "$sid" "$([ -n "$resume" ] && echo true || echo false)"
[ -n "$sleep_s" ] && sleep "$sleep_s"
text="did: $(LC_ALL=C; printf '%s' "${brief:0:40}" | tr '\n' ' ')"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$text"
if grep -q '^FAIL' <<<"$brief"; then
  printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"result":"boom","session_id":"%s"}\n' "$sid"; exit 1
fi
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"%s","session_id":"%s"}\n' "$text" "$sid"
EOF
# codex: `exec --json ... -o <file> -` and `exec resume <id> --yolo --json -`.
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
[ "$1" = login ] && { [ -z "${SHIM_CODEX_LOGIN_DOWN:-}" ]; exit $?; }
[ "$1" = exec ] && shift
case " $* " in *" -C / "*) case " $* " in *" --skip-git-repo-check "*) ;; *) echo "Not inside a trusted directory and --skip-git-repo-check was not specified." >&2; exit 1 ;; esac ;; esac
if [ -n "${SHIM_CODEX_DOWN:-}" ]; then printf '{"type":"thread.started","thread_id":"x"}\n{"type":"turn.failed","error":{"message":"401 Unauthorized"}}\n'; exit 1; fi
tid=""; out=""
resumed=""
if [ "${1:-}" = resume ]; then shift; tid="$1"; shift; resumed=1; fi
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
[ -n "$tid" ] || tid="0199-shim-$(date +%s)-$$"
brief=$(cat)
[ -n "$brief" ] || { echo "No prompt provided via stdin." >&2; exit 1; }
if [ -n "${SHIM_CODEX_SILENT_RESUME:-}" ] && [ "$1" != "" ] 2>/dev/null; then :; fi
if [ -n "${SHIM_CODEX_SILENT_RESUME:-}" ] && [ -n "$resumed" ]; then exit 0; fi
printf '{"type":"thread.started","thread_id":"%s"}\n{"type":"turn.started"}\n' "$tid"
sleep 1
text="codex did: $(LC_ALL=C; printf '%s' "${brief:0:40}" | tr '\n' ' ')"
printf '{"type":"item.completed","item":{"type":"agent_message","text":"%s"}}\n{"type":"turn.completed"}\n' "$text"
[ -n "$out" ] && printf '%s\n' "$text" > "$out"
exit 0
EOF
REAL_GIT=$(command -v git)
cat > "$TMP/bin/git" <<EOF
#!/usr/bin/env bash
if [ -n "\${SHIM_GIT_HANG_FETCH:-}" ]; then for a in "\$@"; do [ "\$a" = fetch ] && sleep 60; done; fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$TMP/bin/git"
REAL_TMUX=$(command -v tmux)
cat > "$TMP/bin/tmux" <<EOF
#!/usr/bin/env bash
if [ -n "\${SHIM_TMUX_FAIL_NEW:-}" ]; then case " \$* " in *" new-session "*) echo "shim: tmux refuses new-session" >&2; exit 1 ;; esac; fi
# The server the preflight's environment check reads (ludics-lite#327): SHIM_TMUX_GENV names a
# file holding \`show-environment -g\` output, or \`none\` for no server running; SHIM_TMUX_SESSIONS
# lists its session names and SHIM_TMUX_UPDATE_ENV its update-environment option; with
# SHIM_TMUX_GENV_WHEN it plays that server only once the named file exists. Unset, the real
# server on the test socket answers.
if [ -n "\${SHIM_TMUX_GENV:-}" ] && { [ -z "\${SHIM_TMUX_GENV_WHEN:-}" ] || [ -e "\$SHIM_TMUX_GENV_WHEN" ]; }; then
  case " \$* " in
    *" list-sessions "*|*" show-environment "*|*" show-options "*)
      [ "\$SHIM_TMUX_GENV" != none ] || { echo "no server running on /tmp/shim/\${FLEET_TMUX_SOCKET:-default}" >&2; exit 1; }
      case " \$* " in
        *" list-sessions "*) for s in \${SHIM_TMUX_SESSIONS:-}; do echo "\$s"; done ;;
        *" show-options "*) for s in DISPLAY SSH_AUTH_SOCK \${SHIM_TMUX_UPDATE_ENV:-}; do echo "\$s"; done ;;
        *) cat "\$SHIM_TMUX_GENV" ;;
      esac
      exit 0 ;;
  esac
fi
exec "$REAL_TMUX" "\$@"
EOF
# ssh: the preflight's cross-box reach probe (ludics-lite#57) -- the one ssh shape these tests
# answer, `ssh <opts> <host> exit 0`. `SHIM_SSH_DENY=<host>` answers a missing credential,
# `SHIM_SSH_DOWN=<host>` a box that does not answer; every other probed host is reachable. Any
# other invocation (run_on's `bash -s` to a box the tests never map as local) is unresolvable, as
# it would be for real: nothing in these tests reaches a real box. The one exception is
# `SHIM_SSH_LOCAL=<host>`, which runs whatever reaches that host here, as its remote shell would:
# the stand-in for a second box, so a cross-box path is exercised through run_on's real quoting.
cat > "$TMP/bin/ssh" <<'SHIMEOF'
#!/usr/bin/env bash
host=""
while [ $# -gt 0 ]; do case "$1" in -o) shift ;; -*) ;; *) host="$1"; break ;; esac; shift; done
shift
[ -n "${SHIM_SSH_LOCAL:-}" ] && [ "$host" = "$SHIM_SSH_LOCAL" ] && exec bash -c "$*"
[ "$*" = "exit 0" ] || { echo "ssh: Could not resolve hostname $host: nodename nor servname provided" >&2; exit 255; }
[ "$host" = "${SHIM_SSH_HANG:-}" ] && sleep 30
[ "$host" = "${SHIM_SSH_SLURP:-}" ] && cat > /dev/null
[ "$host" = "${SHIM_SSH_DENY:-}" ] && { echo "$host: Permission denied (publickey)." >&2; exit 255; }
[ "$host" = "${SHIM_SSH_DOWN:-}" ] && { echo "ssh: connect to host $host port 22: Connection timed out" >&2; exit 255; }
exit 0
SHIMEOF
# gh: the preflight's GitHub credential call (ludics-lite#360), `gh api user -q .login`, in the
# shapes a real gh answers with: SHIM_GH=401 is gh 2.46 over a dead keyring token (the JSON body
# on stdout with no newline, then the error on stderr, exit 1; rog-nv-linux, 2026-09-24),
# `noauth` a box never logged in (exit 4), `down` a network that cannot reach api.github.com,
# `5xx` a GitHub outage, `hang` a call that never returns. Unset, it answers a login.
cat > "$TMP/bin/gh" <<'SHIMEOF'
#!/usr/bin/env bash
[ "$*" = "api --hostname github.com user -q .login" ] || { echo "gh shim: unexpected call: $*" >&2; exit 2; }
case "${SHIM_GH:-}" in
  401) printf '{\n  "message": "Bad credentials",\n  "status": "401"\n}'; echo "gh: Bad credentials (HTTP 401)" >&2; exit 1 ;;
  noauth) printf 'To get started with GitHub CLI, please run:  gh auth login\n' >&2; exit 4 ;;
  down) printf 'error connecting to api.github.com\ncheck your internet connection or https://githubstatus.com\n' >&2; exit 1 ;;
  5xx) echo "gh: Server Error (HTTP 502)" >&2; exit 1 ;;
  hang) sleep 30 ;;
esac
echo shim-user
SHIMEOF
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/tmux" "$TMP/bin/ssh" "$TMP/bin/gh"

# --- the real checkout, installed by the README's own loops, must pass the preflight ---------
# The scratch checkout further down is built to the layout the preflight expects, so the two
# can agree with each other while both disagree with the repository: after the extraction into
# this repo the preflight went on scanning a ClaudeDesktop/ tree that no longer existed, and the
# suite passed (ludics-lite#16). This pins the served-tree assumption to the actual tree. The
# commit this test lives in is pushed to a scratch origin, cloned to ~/ludics-lite under a
# scratch HOME, installed with the install loops extracted from README.md (minus their git
# clone), and preflighted for both worker kinds, so the README's loop and the preflight's
# expected link target are read from where they live rather than restated here.
section "the real checkout under the README's install loops" && {
real_top=$(git -C "$HERE" rev-parse --show-toplevel)
readme_block() { # <text>: the first fenced code block of README.md containing the text
  awk -v want="$1" '
    /^```/ { if (inblock) { if (index(block, want)) { printf "%s", block; exit } block = "" }; inblock = !inblock; next }
    inblock { block = block $0 "\n" }
  ' "$real_top/README.md"
}
real_home="$TMP/real-home"; real_origin="$TMP/real-origin.git"
mkdir -p "$real_home"
git init -q --bare "$real_origin"
git -C "$real_top" push -q "$real_origin" HEAD:refs/heads/main || ko "could not push the real checkout's HEAD to the scratch origin (setup, not the launcher)"
# Use the transport even for a local path: push can leave background object maintenance
# running, and a local clone's hardlink walk races with repacking (seen in PR #149).
git clone --no-local -q -b main "$real_origin" "$real_home/ludics-lite" || ko "could not clone the scratch origin (setup, not the launcher)"
claude_loop=$(readme_block 'ludics-lite/*/' | grep -v '^git clone ')
codex_loop=$(readme_block 'for s in ship-pr wait-and-proceed after-merge' | grep -v '^git clone ')
[ -n "$claude_loop" ] && [ -n "$codex_loop" ] && ok "README.md carries both install loops" || ko "could not find the README's install loops"
( export HOME="$real_home"; eval "$claude_loop" && eval "$codex_loop" ) || ko "the README's install loops failed: $claude_loop $codex_loop"

# Read the layout rather than naming today's skills. A new top-level directory has to declare
# itself as infrastructure here, or carry SKILL.md and therefore become part of the install set.
# What the repository tracks, not what the working tree holds: the agent harness writes an
# untracked `.claude/` into every checkout it opens, so reading the working tree failed this guard
# on every local run while CI, whose actions/checkout leaves no such scratch, stayed green -- a
# suite whose one local failure is always the same false positive is a suite people stop reading.
# Tracked paths close the class rather than one name (post-merge-cleanup.sh, which has to judge a
# real checkout rather than a declaration, exempts `.claude/` by name instead). `.git` is never
# tracked, so unlike under `find` it no longer has to be declared.
non_skill_dirs=".github routines scripts"
top_dirs() { # <checkout>: the top-level directories the repository declares, one per line
  git -C "$1" ls-files -z | while IFS= read -r -d '' path; do
    case $path in */*) printf '%s\n' "${path%%/*}" ;; esac
  done | sort -u
}
is_tracked_skill() { # <checkout> <name>: does that top-level directory declare a SKILL.md?
  git -C "$1" ls-files --error-unmatch -- "$2/SKILL.md" >/dev/null 2>&1
}
undeclared_dirs() { # <checkout>: declared directories that are neither a skill nor infrastructure
  top_dirs "$1" | while IFS= read -r name; do
    is_tracked_skill "$1" "$name" && continue
    declared=0
    for non_skill in $non_skill_dirs; do [ "$name" = "$non_skill" ] && declared=1; done
    [ "$declared" -eq 1 ] || printf ' %s' "$name"
  done
}
tree_skills=$(top_dirs "$real_top" | while IFS= read -r name; do
  is_tracked_skill "$real_top" "$name" && printf '%s\n' "$name"
done)
unknown_dirs=$(undeclared_dirs "$real_top")
[ -n "$tree_skills" ] && [ -z "$unknown_dirs" ] \
  && ok "every top-level directory is a skill or a declared non-skill ($non_skill_dirs)" \
  || ko "top-level directories without SKILL.md outside the declared non-skill set:$unknown_dirs"

# Both halves of that reading, on a clone of the real tree: the untracked scratch the harness
# leaves behind stays invisible, and a directory the tree actually gains -- declaring neither
# SKILL.md nor infrastructure -- still trips the guard, which is the whole point of having it.
guard_clone="$TMP/guard-clone"
git clone --no-local -q -b main "$real_origin" "$guard_clone" || ko "could not clone the scratch origin for the layout guard (setup, not the launcher)"
mkdir -p "$guard_clone/.claude/skills" && : > "$guard_clone/.claude/settings.json"
untracked_verdict=$(undeclared_dirs "$guard_clone")
[ -z "$untracked_verdict" ] \
  && ok "an untracked top-level directory does not reach the layout guard" \
  || ko "an untracked top-level directory tripped the layout guard:$untracked_verdict"
mkdir -p "$guard_clone/newthing" && : > "$guard_clone/newthing/notes.md"
git -C "$guard_clone" add newthing/notes.md || ko "could not track the guard clone's new directory (setup, not the launcher)"
tracked_verdict=$(undeclared_dirs "$guard_clone")
[ "$tracked_verdict" = " newthing" ] \
  && ok "...while a tracked directory that is neither a skill nor declared infrastructure trips it" \
  || ko "the layout guard missed a tracked undeclared top-level directory (verdict:$tracked_verdict)"

linked_skills=$(find "$real_home/.claude/skills" -mindepth 1 -maxdepth 1 -type l -exec basename {} \; | sort)
[ "$linked_skills" = "$tree_skills" ] \
  && ok "the README's Claude loop links exactly the skills the tree declares" \
  || ko "the README's Claude loop and tree disagree (tree: $tree_skills; links: $linked_skills)"

# Read the lint steps' patterns from the checkout rather than restating them: restating them here
# would let the test and workflow drift together. Until ludics-lite#221 that meant slicing them out
# of the workflow's own `run:` blocks; the list now lives once in scripts/preflight.sh, which the
# lint job calls, and `preflight.sh globs` is the reading of it. What this guard no longer sees on
# its own is a lint step rewritten to sweep something ELSE inline -- the globs would still be read
# from the script while CI ran the inline copy. That is scripts/test-preflight.sh's pin (every
# lint `run:` is preflight.sh or a command in its step table), and the two are the whole claim.
# Every shell file must be covered by BOTH the syntax and shellcheck step, which is one list today.
lint_globs() { # lint_globs <checkout>
  "$1/scripts/preflight.sh" globs
}
workflow_matches() { # workflow_matches <checkout> <newline-separated patterns>: the paths they cover
  # Expand the patterns the way the workflow's own shell does, over a tree holding exactly what the
  # repository TRACKS -- mirrored here as empty files, since only the paths decide the match.
  # Tracked paths on this side too, for the reason the other side reads them: expanding into the
  # checkout answers what the worktree HOLDS, so a tracked script the worktree is missing (an
  # unstaged deletion, a sparse checkout) would be matched by no pattern and reported uncovered,
  # which is the very false positive this guard was fixed for. Re-implementing the expansion over
  # a list of paths instead is the trap: `case` lets `*` cross a slash, and git's `:(glob)`
  # pathspec stops that but still matches a leading `.`, which bash does only under `dotglob` --
  # so a tracked `.github/scripts/check.sh` would read as covered while the workflow's glob never
  # expands to it. Mirroring keeps every rule of the expansion with the shell that has them.
  local checkout="$1" patterns="$2" mirror path matched
  mirror=$(mktemp -d "$TMP/glob-mirror.XXXXXX") || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    case $path in */*) mkdir -p "$mirror/${path%/*}" || return 1 ;; esac
    : > "$mirror/$path" || return 1
  done <<EOF
$(tracked_shell_files "$checkout")
EOF
  (
    cd "$mirror" || exit 1
    while IFS= read -r pattern; do
      [ -n "$pattern" ] || continue
      # Unquoted on purpose: this is the workflow's own pathname expansion, run by the same shell
      # over the same names. Only `*.sh` is mirrored, and every pattern ends in `.sh`.
      # shellcheck disable=SC2086
      for matched in $pattern; do [ -f "$matched" ] && printf '%s\n' "$matched"; done
    done <<EOF
$patterns
EOF
  ) | sort -u
  rm -rf "$mirror"
}
tracked_shell_files() { # <checkout>: the shell scripts the repository tracks, one per line
  # Tracked paths, for the reason the layout guard above reads them: CI's lint steps run over an
  # actions/checkout, which holds no untracked file, so a scratch `*.sh` an agent leaves in a local
  # worktree is not something these globs were ever meant to cover -- and under `find` it failed
  # this guard with a message about the workflow. `*.sh` here is a git pathspec, not a pathname
  # glob: its `*` crosses `/`, so it matches at every depth, which is what this guard wants, since
  # the workflow's globs cover nested paths too.
  git -C "$1" ls-files -z -- '*.sh' | while IFS= read -r -d '' path; do printf '%s\n' "$path"; done | sort
}
uncovered_shell_files() { # <checkout>: "<step>:<path>" for every tracked script a lint step misses
  local syntax_files shellcheck_files uncovered="" f
  # Both steps sweep the one list, so these two are the same set today; they stay separate
  # because the claim the verdict makes is per step, and a step given a narrower list of its own
  # would be read here without another edit.
  syntax_files=$(workflow_matches "$1" "$(lint_globs "$1")")
  shellcheck_files=$(workflow_matches "$1" "$(lint_globs "$1")")
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    grep -Fqx -- "$f" <<<"$syntax_files" || uncovered="$uncovered bash-n:$f"
    grep -Fqx -- "$f" <<<"$shellcheck_files" || uncovered="$uncovered shellcheck:$f"
  done <<EOF
$(tracked_shell_files "$1")
EOF
  printf '%s' "$uncovered"
}
syntax_globs=$(lint_globs "$real_top")
shellcheck_globs=$syntax_globs
uncovered=$(uncovered_shell_files "$real_top")
[ -n "$syntax_globs" ] && [ -n "$shellcheck_globs" ] && [ -z "$uncovered" ] \
  && ok "the lint job's own syntax and shellcheck globs cover every shell script in the tree" \
  || ko "lint shell globs are missing or leave files uncovered:$uncovered (bash -n: $syntax_globs; shellcheck: $shellcheck_globs)"

# Both halves of that reading, on the layout guard's clone: the scratch script an agent drops in a
# worktree stays invisible, and the same path once the tree TRACKS it -- at the root, where none of
# the workflow's globs reach -- is still reported against both lint steps.
printf '#!/usr/bin/env bash\ntrue\n' > "$guard_clone/scratch-probe.sh"
untracked_sh_verdict=$(uncovered_shell_files "$guard_clone")
[ -z "$untracked_sh_verdict" ] \
  && ok "an untracked shell script does not reach the lint-coverage guard" \
  || ko "an untracked shell script tripped the lint-coverage guard:$untracked_sh_verdict"
git -C "$guard_clone" add scratch-probe.sh || ko "could not track the guard clone's scratch script (setup, not the launcher)"
tracked_sh_verdict=$(uncovered_shell_files "$guard_clone")
[ "$tracked_sh_verdict" = " bash-n:scratch-probe.sh shellcheck:scratch-probe.sh" ] \
  && ok "...while a tracked shell script no lint glob covers trips it" \
  || ko "the lint-coverage guard missed a tracked uncovered shell script (verdict:$tracked_sh_verdict)"
rm "$guard_clone/scratch-probe.sh" "$guard_clone/scripts/sync-routines.sh" \
  || ko "could not remove the guard clone's shell scripts (setup, not the launcher)"
missing_sh_verdict=$(uncovered_shell_files "$guard_clone")
[ "$missing_sh_verdict" = " bash-n:scratch-probe.sh shellcheck:scratch-probe.sh" ] \
  && ok "...and both sides read the declaration: a covered script the worktree is missing stays covered" \
  || ko "a tracked script absent from the worktree changed the lint-coverage verdict (verdict:$missing_sh_verdict)"
# A hidden directory is the one place the expansion's rules decide the verdict rather than merely
# where it reads from: `*/scripts/*.sh` does not reach `.github/scripts/`, because bash matches a
# leading `.` only when the pattern spells it, so a script there is genuinely unlinted in CI.
mkdir -p "$guard_clone/.github/scripts" && : > "$guard_clone/.github/scripts/check.sh"
git -C "$guard_clone" add .github/scripts/check.sh || ko "could not track the guard clone's hidden-directory script (setup, not the launcher)"
hidden_sh_verdict=$(uncovered_shell_files "$guard_clone")
[ "$hidden_sh_verdict" = " bash-n:.github/scripts/check.sh shellcheck:.github/scripts/check.sh bash-n:scratch-probe.sh shellcheck:scratch-probe.sh" ] \
  && ok "...and a tracked script under a hidden directory, which the workflow's glob never expands to, trips it" \
  || ko "the lint-coverage guard read a hidden-directory script as covered (verdict:$hidden_sh_verdict)"

[ -L "$real_home/.claude/skills/ship-pr" ] && ok "the README's loop links ship-pr" || ko "the README's loop did not link ship-pr into ~/.claude/skills"
[ ! -e "$real_home/.claude/skills/routines" ] && ok "the README's loop keeps routines/ out of ~/.claude/skills" || ko "the README's loop linked routines/ into ~/.claude/skills"
[ ! -e "$real_home/.claude/skills/scripts" ] && ok "...and scripts/ too" || ko "the README's loop linked scripts/ into ~/.claude/skills"
# FLEET_SKILLS_REPO is at its default here on purpose: ~/ludics-lite is where the README clones
# to, and the default must agree with it. Unset explicitly, since a configured fleet environment
# exports it, and an absolute value would send this preflight to the box's real checkout.
expect "the real checkout, installed the README's way, passes the claude preflight" 0 "PREFLIGHT OK" -- \
  env -u FLEET_SKILLS_REPO HOME="$real_home" "$FW" preflight testbox --no-probe
expect "...and the codex preflight" 0 "PREFLIGHT OK" -- \
  env -u FLEET_SKILLS_REPO HOME="$real_home" "$FW" preflight testbox --codex --no-probe
unverified_skills=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  rm "$real_home/.claude/skills/$s"
  missing_out=$(env -u FLEET_SKILLS_REPO HOME="$real_home" "$FW" preflight testbox --no-probe 2>&1); missing_rc=$?
  if [ "$missing_rc" -ne 1 ] || ! grep -Fq ".claude/skills/$s -> missing" <<<"$missing_out"; then
    unverified_skills="$unverified_skills $s"
  fi
  ln -sfn "$real_home/ludics-lite/$s" "$real_home/.claude/skills/$s"
done <<EOF
$tree_skills
EOF
[ -z "$unverified_skills" ] \
  && ok "production preflight refuses every skill link derived from the tree when it is missing" \
  || ko "production preflight did not refuse these missing derived skill links:$unverified_skills"
}

# --- a scratch skills checkout with an origin, deployed the way the README deploys it --------
origin="$TMP/origin.git"; repo="$TMP/ludics lite"
git init -q --bare "$origin"
git init -q -b main "$repo"
for s in issue-wave ship-pr wait-and-proceed after-merge; do
  mkdir -p "$repo/$s"; echo "# $s" > "$repo/$s/SKILL.md"
  ln -sfn "$repo/$s" "$HOME/.claude/skills/$s"
done
for s in ship-pr wait-and-proceed after-merge; do ln -sfn "$repo/$s" "$HOME/.codex/skills/$s"; done
git -C "$repo" add -A && git -C "$repo" commit -q -m init
git -C "$repo" remote add origin "$origin" && git -C "$repo" push -q -u origin main
export FLEET_SKILLS_REPO="$repo"

# --- setup every section shares ---------------------------------------------------------------
# The project repo and the brief live here, not in the launch section, so a later section selected
# on its own still finds them; the two helpers below take what only some sections need.
proj="$TMP/pro j"; git init -q -b master "$proj" && echo a > "$proj/a" && git -C "$proj" add a && git -C "$proj" commit -q -m a
git init -q --bare "$TMP/proj.git" && git -C "$proj" remote add origin "$TMP/proj.git" && git -C "$proj" push -q -u origin master
export BASE_PROJECT="$proj"
brief="$TMP/brief.md"; printf 'Fix issue #1: handle `$(rm -rf /)` and `backticks` in prose\n' > "$brief"
# The unstick message: the unstick, codex and usage sections all pass it to `unstick --message`.
printf 'Stop and answer now.\n' > "$TMP/msg.md"
# A second coordinator: its own state dir (own token), the same anchor state.
B=(env ISSUE_WAVE_STATE="$TMP/state-b" FLEET_ANCHOR_STATE="$ISSUE_WAVE_STATE" "$FW")
# need_lease: the coordinator lease, held by us -- what every section from the launches on assumes.
# The lease section leaves it unheld and the launch section claims it, and a claim by the holder is
# idempotent, so this is a no-op in a full run.
need_lease() { "$FW" claim >/dev/null || ko "could not claim the coordinator lease (setup, not the launcher)"; }
# settle <name>: wait for the worker's turn to end, then end the worker. A claude worker's process
# outlives its turns (ludics-lite#259) and an IDLE one still owns its worktree, so a case that
# needs it finished closes it; for a worker that already ended, close prints its verdict.
settle() { "$FW" attach testbox "$1" --interval 1 >/dev/null 2>&1; "$FW" close testbox "$1" >/dev/null 2>&1; }
# need_worker <name>: a finished worker and its worktree, as the launch section leaves behind for
# the sections that read one. A no-op once that section has run.
need_worker() {
  [ -d "$ISSUE_WAVE_STATE/workers/$1" ] && return 0
  need_lease
  "$FW" launch testbox "$1" --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch "claude/$1" >/dev/null &&
    settle "$1" && [ -f "$ISSUE_WAVE_STATE/workers/$1/exit" ] ||
    ko "could not prepare worker $1 (setup, not the launcher)"
}

section "base gate" && {
need_lease
for verdict in 1 3 4; do
  expect "native gate blocks base exit $verdict with diagnostics" 1 "job broken; first red commit deadbee" -- \
    env SHIM_BASE_RC="$verdict" SHIM_BASE_MESSAGE="job broken; first red commit deadbee" "$FW" gate --target-repo example/project --base-branch topic
  expect "CLI blocks base exit $verdict before creating worker" 1 "dispatch blocked" -- \
    env SHIM_BASE_RC="$verdict" "$FW" launch testbox base-red --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/base-red
  [ ! -e "$ISSUE_WAVE_STATE/workers/base-red" ] && [ ! -e "$proj-worktrees/base-red" ] && ok "refusal left no worker or checkout" || ko "base refusal wrote worker state"
done
expect "native green pins target and wait despite ambient settings" 0 "BASE GREEN" -- env REPO=wrong/repo SHIP_PR_BASE_ABSENT_GRACE=0 SHIP_PR_ADVISORY_CHECKS=.* SHIP_PR_TEST_SOURCE_ONLY=1 SHIP_PR_CHECKS_INTERVAL=0 SHIP_PR_CHECKS_WAIT=0 SHIP_PR_CHECKS_HEARTBEAT=0 SHIP_PR_API_ATTEMPTS=0 SHIP_PR_API_BACKOFF=0 "$FW" gate --target-repo example/project --base-branch topic
expect "missing repository refuses" 2 "--target-repo" -- "$FW" gate
expect "triage force cannot bypass red base" 1 "dispatch blocked" -- env SHIM_BASE_RC=1 "$FW" gate --target-repo example/project --force
expect "explicit red triage override passes with reason" 0 "BASE TRIAGE OVERRIDE: example/project default branch: fix broken job" -- env SHIM_BASE_RC=1 "$FW" gate --target-repo example/project --force --allow-red-base 'fix broken job'
expect "override needs force" 2 "requires --force" -- "$FW" gate --target-repo example/project --allow-red-base fix
for verdict in 3 4; do
  expect "triage cannot override unknown $verdict" 1 "dispatch blocked" -- env SHIM_BASE_RC="$verdict" "$FW" gate --target-repo example/project --force --allow-red-base fix
done
expect "missing helper refuses with unknown diagnostic" 1 "checker missing" -- env SHIM_BASE_RC=0 bash -c 'mv "$1" "$1.saved"; "$2" gate --target-repo example/project; rc=$?; mv "$1.saved" "$1"; exit "$rc"' _ "$TMP/dispatcher/ship-pr/scripts/pr-review.sh" "$FW"
grep -Fxq -- '--repo example/project base topic --wait=360 grace=300 interval=60' "$BASE_CALL_LOG" && ok "explicit native branch passed to coordinator helper" || ko "native branch lost"
grep -Fxq -- '--repo example/project base master --wait=360 grace=300 interval=60' "$BASE_CALL_LOG" && ok "worktree base branch passed to coordinator helper" || ko "worktree base lost"
# The value itself, and the relation behind it: 360 is 300 + 60, a whole round of margin over the
# grace. `--wait=301` left a one-second margin that one round's API latency swallowed, so the gate
# reached its ceiling and refused dispatch for a docs-only tip the next round would have settled
# (ludics-lite#175); the checker now warns loudly about that band, and nothing here may spell it.
grep -q -- '--wait=301 ' "$BASE_CALL_LOG" && ko "the hand-spelled 301 ceiling is back" || ok "no base read carries a ceiling inside the grace's own round"
original_base=$(git -C "$proj" rev-parse origin/master)
later_base=$(git -C "$proj" commit-tree 'HEAD^{tree}' -p HEAD -m later)
expect "new worktree uses confirmed SHA despite later ref movement" 0 "LAUNCHED testbox/pinned-base" -- env SHIM_MOVE_REF_AFTER_CONFIRM="$later_base" "$FW" launch testbox pinned-base --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/pinned-base
settle pinned-base
[ "$(git -C "$proj-worktrees/pinned-base" rev-parse HEAD)" = "$original_base" ] && ok "worktree starts from pinned SHA" || ko "worktree followed moving ref"
git -C "$proj" update-ref refs/remotes/origin/master "$original_base"
expect "target movement refuses new worktree" 1 "differs from fetched base" -- env SHIM_BASE_TIP=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$FW" launch testbox moved-base --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/moved-base
[ ! -e "$proj-worktrees/moved-base" ] && ok "moved base created no worktree" || ko "moved base created worktree"
expect "unreadable target confirmation blocks" 1 "cannot confirm" -- env SHIM_BASE_TIP_FAIL=1 "$FW" launch testbox unread-base --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/unread-base
expect "base read follows freshness preflight" 1 "dispatch blocked" -- env SHIM_BASE_REQUIRE_PREFLIGHT="$TMP/preflight-ran" SHIM_BASE_RC=1 "$FW" launch testbox base-order --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
"$FW" release >/dev/null
}

section "coordinator lease" && {
expect "no identity at all is refused, not guessed" 2 "no coordinator identity" -- env -u FLEET_COORDINATOR "$FW" claim
expect "a Codex thread id supplies the coordinator identity" 3 "nobody holds the lease" -- \
  env -u FLEET_COORDINATOR CODEX_THREAD_ID=test-thread "$FW" coordinator
mkdir "$ISSUE_WAVE_STATE/COORDINATOR.lock" 2>/dev/null || { mkdir -p "$ISSUE_WAVE_STATE"; mkdir "$ISSUE_WAVE_STATE/COORDINATOR.lock"; }
expect "a first claim also waits on the lease lock and fails after the bound" 1 "CLAIM FAILED: lease lock" -- env FLEET_LOCK_WAIT=1 "$FW" claim
rmdir "$ISSUE_WAVE_STATE/COORDINATOR.lock"
expect "coordinator: nobody yet, exit 3" 3 "nobody holds the lease" -- "$FW" coordinator
expect "claim takes the lease" 0 "CLAIMED coordinator lease on testbox" -- "$FW" claim
expect "claim again is idempotent for the holder" 0 "CLAIMED already held" -- "$FW" claim
expect "coordinator: me" 0 "COORDINATOR: you" -- "$FW" coordinator
expect "a second coordinator's claim is refused while held" 1 "CLAIM REFUSED: coordinator lease held by" -- "${B[@]}" claim
expect "a second coordinator cannot halt" 1 "HALT REFUSED fleet: coordinator lease held by" -- "${B[@]}" halt "not mine"
mkdir "$ISSUE_WAVE_STATE/COORDINATOR.lock"
expect "resume-launches waits for the lease lock and fails after the bound" 1 "RESUME-LAUNCHES FAILED: lease lock" -- env FLEET_LOCK_WAIT=1 "$FW" resume-launches
rmdir "$ISSUE_WAVE_STATE/COORDINATOR.lock"
expect "release by a non-holder is refused" 1 "RELEASE REFUSED" -- "${B[@]}" release
expect "--take adopts the lease" 0 "CLAIMED (adopted) coordinator lease" -- "${B[@]}" claim --take
expect "the previous holder now sees the lease as not theirs" 1 "(not you)" -- "$FW" coordinator
expect "...and takes it back with --take" 0 "CLAIMED (adopted)" -- "$FW" claim --take
expect "another session on the same box (same state dir) is not the holder" 1 "CLAIM REFUSED" -- env FLEET_COORDINATOR=other-session "$FW" claim
expect "...and cannot launch through the holder's token" 1 "coordinator lease held by" -- env FLEET_COORDINATOR=other-session "$FW" launch testbox nope --target-repo example/project --kind claude --brief /dev/null --cwd "$TMP"
# Two adopters at once: the takeover lock serializes them, exactly one holds afterwards.
env FLEET_COORDINATOR=race-a "$FW" claim --take >"$TMP/race-a.out" 2>&1 & ra=$!
env FLEET_COORDINATOR=race-b "$FW" claim --take >"$TMP/race-b.out" 2>&1 & rb=$!
wait "$ra" "$rb"
holders=0
ra=$(env FLEET_COORDINATOR=race-a "$FW" coordinator 2>&1); grep -q "COORDINATOR: you" <<<"$ra" && holders=$((holders + 1))
rb=$(env FLEET_COORDINATOR=race-b "$FW" coordinator 2>&1); grep -q "COORDINATOR: you" <<<"$rb" && holders=$((holders + 1))
[ "$holders" -eq 1 ] && ok "concurrent takeovers leave exactly one holder" || ko "concurrent takeovers: $holders holders -- $(cat "$TMP/race-a.out" "$TMP/race-b.out")"
[ -d "$ISSUE_WAVE_STATE/COORDINATOR.lock" ] && ko "takeover lock left behind" || ok "takeover lock released"
mkdir "$ISSUE_WAVE_STATE/COORDINATOR.lock"
expect "a held lease lock makes --take fail after the bounded wait" 1 "CLAIM FAILED: lease lock" -- env FLEET_LOCK_WAIT=1 "$FW" claim --take
expect "release under a held lease lock fails after the bounded wait, not silently" 1 "RELEASE FAILED: lease lock" -- env FLEET_LOCK_WAIT=1 "$FW" release
rmdir "$ISSUE_WAVE_STATE/COORDINATOR.lock"
"$FW" claim --take >/dev/null
mkdir -p "$TMP/state-c"; : > "$TMP/state-c/tokens"
expect "a token that cannot be persisted refuses the claim" 1 "CLAIM REFUSED: cannot persist" -- env ISSUE_WAVE_STATE="$TMP/state-c" FLEET_ANCHOR_STATE="$ISSUE_WAVE_STATE" FLEET_COORDINATOR=c "$FW" claim --take
grep -q '^token=$' "$ISSUE_WAVE_STATE/COORDINATOR" && ko "an empty token reached the lease" || ok "no empty-token lease was written"
"$FW" release >/dev/null 2>&1
env FLEET_COORDINATOR=fresh "$FW" claim >"$TMP/fresh-a.out" 2>&1 & fa=$!
env FLEET_COORDINATOR=fresh "$FW" claim >"$TMP/fresh-b.out" 2>&1 & fb=$!
wait "$fa" "$fb"
expect "two first claims of one new identity leave that identity holding" 0 "COORDINATOR: you" -- env FLEET_COORDINATOR=fresh "$FW" coordinator
env FLEET_COORDINATOR=fresh "$FW" release >/dev/null; "$FW" claim >/dev/null
expect "an identity outside the safe set is refused, not folded" 2 "coordinator identity 'team/a' must be" -- env FLEET_COORDINATOR=team/a "$FW" claim
chmod 555 "$ISSUE_WAVE_STATE"
expect "release on an unwritable anchor fails at once, not after the lock wait" 1 "RELEASE FAILED: lease lock on testbox: cannot create lock" -- "$FW" release
chmod 755 "$ISSUE_WAVE_STATE"
expect "release drops it" 0 "RELEASED coordinator lease" -- "$FW" release
expect "coordinator after release: nobody" 3 "nobody holds" -- "$FW" coordinator
mkdir -p "$ISSUE_WAVE_STATE/COORDINATOR"
expect "claim --take that cannot write the lease fails, not CLAIMED" 1 "CLAIM FAILED: could not write" -- "$FW" claim --take
expect "a plain claim over an unwritable lease path fails too" 1 "CLAIM FAILED: could not write" -- "$FW" claim
rmdir "$ISSUE_WAVE_STATE/COORDINATOR"
}

section "preflight" && {
expect "clean main on origin passes (claude, live probe via shim)" 0 "PREFLIGHT OK" -- "$FW" preflight testbox
expect "clean main passes for codex (live probe via shim)" 0 "PREFLIGHT OK" -- "$FW" preflight testbox --codex
expect "a stalling skills fetch is bounded and refused" 1 "git fetch in .* timed out after 2s" -- env SHIM_GIT_HANG_FETCH=1 FLEET_FETCH_TIMEOUT=2 "$FW" preflight testbox --no-probe
# Cross-box reach (ludics-lite#57): a missing credential refuses, a box that is down is noted.
expect "a sibling refusing the key refuses the preflight" 1 "no non-interactive ssh to otherbox from testbox: .*Permission denied" -- env FLEET_BOXES="testbox otherbox" SHIM_SSH_DENY=otherbox "$FW" preflight testbox --no-probe
expect "a sibling that does not answer is noted on the OK line" 0 "PREFLIGHT OK.*cross-box unreachable, asleep or off the network: otherbox" -- env FLEET_BOXES="testbox otherbox" SHIM_SSH_DOWN=otherbox "$FW" preflight testbox --no-probe
expect "a reachable sibling adds nothing to the OK line" 0 "PREFLIGHT OK testbox skills=[0-9a-f]*$" -- env FLEET_BOXES="testbox otherbox" "$FW" preflight testbox --no-probe
expect "--no-cross skips the reach probe" 0 "PREFLIGHT OK" -- env FLEET_BOXES="testbox otherbox" SHIM_SSH_DENY=otherbox "$FW" preflight testbox --no-probe --no-cross
expect "a sibling whose login never returns is bounded and noted, not hung" 0 "PREFLIGHT OK.*otherbox(no answer in 2s)" -- env FLEET_BOXES="testbox otherbox" SHIM_SSH_HANG=otherbox FLEET_CROSS_TIMEOUT=2 "$FW" preflight testbox --no-probe
# The same through the DEFAULT roster (ludics-lite#320): tuf-amd-linux is Wi-Fi only and woken by
# hand, so from mac-studio it is often the one sibling asleep. Its silence is a note naming it
# alone, never a refusal, and rog and minix answering add nothing (the `$` anchor says so).
expect "mac-studio with the default roster notes a sleeping TUF and still passes" 0 "PREFLIGHT OK mac-studio skills=[0-9a-f]* (cross-box unreachable, asleep or off the network: tuf-amd-linux)$" -- \
  env -u FLEET_BOXES FLEET_LOCAL_BOX=mac-studio SHIM_SSH_DOWN=tuf-amd-linux "$FW" preflight mac-studio --no-probe
[ -d "$repo/.git/fleet-checkout.lock" ] && ko "preflight lock left after the bounded reach probe" || ok "preflight lock released after the bounded reach probe"
# The slot count per roster box is on the preflight's output (ludics-lite#329): it showed nowhere
# but in a batch's own slot line, so a day of one-slot Mac batches passed every preflight. Each
# case sets or unsets both variables itself.
# A one-slot count is matched as `mac-studio[=]1`: check-prompts reads the bare pair anywhere in
# this file as a statement of the site default, and this is a count the fixture configured.
PFROSTER="mac-studio rog-nv-linux minix-amd-linux tuf-amd-linux"
PFM=(env FLEET_LOCAL_BOX=mac-studio "$FW" preflight mac-studio --no-probe --no-cross)
expect "preflight prints the site default's slot counts under an exported default roster" 0 "^PREFLIGHT SLOTS mac-studio=6 rog-nv-linux=4(gpu=2) minix-amd-linux=4 tuf-amd-linux=3 (site default)$" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS FLEET_BOXES="$PFROSTER" "${PFM[@]}"
grep -q "WARNING" <<<"$out" && ko "...and warns about a configuration that is the site default -- $out" || ok "...and warns about nothing"
# The other direction of that pairing: the boxes the site default widens, read off its own line,
# are exactly the boxes an empty spec warns about -- so a box added to the default and not to the
# warning's list (or the reverse) fails here.
pf_widened=$(sed -n 's/^PREFLIGHT SLOTS \(.*\) (site default)$/\1/p' <<<"$out" | tr ' ' '\n' | sed 's/(gpu=[0-9]*)$//' | awk -F= '$2 + 0 > 1 {print $1}' | sort | tr '\n' ' ')
expect "an empty spec under the default roster warns, box by box" 0 "does not name" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
pf_warned=$(sed -n 's/^PREFLIGHT SLOTS WARNING: .* does not name \([^,]*\), which falls.*/\1/p' <<<"$out" | sort | tr '\n' ' ')
[ -n "$pf_widened" ] && [ "$pf_widened" = "$pf_warned" ] && ok "...about exactly the boxes the site default widens: $pf_warned" \
  || ko "the collapse warning names '$pf_warned', the site default widens '$pf_widened'"
expect "...the same under an unset roster" 0 "^PREFLIGHT SLOTS mac-studio=6 .*(site default)$" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS -u FLEET_BOXES "${PFM[@]}"
expect "a spec that leaves mac-studio out under the default roster is a loud warning, not a refusal" 0 "PREFLIGHT SLOTS WARNING: the default roster, but FLEET_BOX_CORRECTNESS_SLOTS=\"rog-nv-linux=2\" does not name mac-studio, which falls to one slot" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="rog-nv-linux=2" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
grep -q "^PREFLIGHT OK mac-studio" <<<"$out" && grep -q "^PREFLIGHT SLOTS mac-studio[=]1 rog-nv-linux=2 minix-amd-linux=1 tuf-amd-linux=1 (FLEET_BOX_CORRECTNESS_SLOTS)$" <<<"$out" \
  && ok "...beside the OK line and the counts it names" || ko "the collapse warning lost the OK line or the counts -- $out"
expect "...as is an explicitly empty spec" 0 "PREFLIGHT SLOTS WARNING: .* does not name mac-studio" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
expect "a spec naming every widened box at one slot is a choice, printed without a warning" 0 "^PREFLIGHT SLOTS mac-studio[=]1 rog-nv-linux[=]1 minix-amd-linux[=]1 tuf-amd-linux[=]1 (FLEET_BOX_CORRECTNESS_SLOTS)$" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="mac-studio=1 rog-nv-linux=1 minix-amd-linux=1 tuf-amd-linux=1" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
grep -q "WARNING" <<<"$out" && ko "a spec naming every widened box at one slot drew a collapse warning -- $out" || ok "...and no warning"
# The hub's 2026-09-23 mitigation shape: a spec naming only the Mac collapses the native GPU boxes
# (ludics-lite#316), so it warns about each of them and not about mac-studio.
expect "a spec naming only mac-studio warns about each native GPU box it leaves at one slot" 0 "does not name rog-nv-linux, which falls to one slot" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="mac-studio=4" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
grep -q "does not name minix-amd-linux, which falls" <<<"$out" && grep -q "does not name tuf-amd-linux, which falls" <<<"$out" \
  && ! grep -q "does not name mac-studio" <<<"$out" \
  && ok "...minix-amd-linux and tuf-amd-linux too, and not the Mac it names" || ko "the per-box collapse warnings are wrong -- $out"
expect "a roster over several lines prints every box" 0 "^PREFLIGHT SLOTS mac-studio=6 rog-nv-linux=4(gpu=2) minix-amd-linux=4 tuf-amd-linux=3 (site default)$" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS FLEET_BOXES="mac-studio rog-nv-linux
minix-amd-linux tuf-amd-linux" "${PFM[@]}"
expect "a custom roster prints one slot each, without a warning" 0 "^PREFLIGHT SLOTS testbox=1 otherbox=1 (custom roster: one slot each)$" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS FLEET_BOXES="testbox otherbox" "$FW" preflight testbox --no-probe --no-cross
grep -q "WARNING" <<<"$out" && ko "a custom roster drew a collapse warning -- $out" || ok "...and no warning"
expect "a malformed spec is a warning on the preflight, which still passes" 0 "PREFLIGHT SLOTS WARNING: FLEET_BOX_CORRECTNESS_SLOTS names stale-box, which is not in FLEET_BOXES" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="stale-box=2" FLEET_BOXES="testbox otherbox" "$FW" preflight testbox --no-probe --no-cross
# The GPU tokens (ludics-lite#391) show beside a box's slots where they are fewer, and a token
# spec that leaves out a box the site default narrows is the same loud warning, paired the same
# way: the boxes the default shows with `(gpu=` are exactly the ones an empty token spec names.
env -u FLEET_BOX_CORRECTNESS_SLOTS FLEET_BOXES="$PFROSTER" "${PFM[@]}" > "$TMP/pf-tokens.out" 2>&1
pf_tokened=$(sed -n 's/^PREFLIGHT SLOTS \(.*\) (site default)$/\1/p' "$TMP/pf-tokens.out" | tr ' ' '\n' | sed -n 's/=.*(gpu=.*//p' | sort | tr '\n' ' ')
expect "an empty GPU-token spec under the default roster warns about the box it un-narrows" 0 "PREFLIGHT SLOTS WARNING: the default roster, but FLEET_BOX_GPU_TOKENS=\"\" does not name rog-nv-linux, so all 4 of its slots may hold its GPU at once (the site default allows 2)" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS FLEET_BOX_GPU_TOKENS="" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
pf_twarned=$(sed -n 's/^PREFLIGHT SLOTS WARNING: .*FLEET_BOX_GPU_TOKENS=.* does not name \([^,]*\), so all.*/\1/p' <<<"$out" | sort | tr '\n' ' ')
[ -n "$pf_tokened" ] && [ "$pf_tokened" = "$pf_twarned" ] && ok "...about exactly the boxes the site default narrows: $pf_twarned" \
  || ko "the token warning names '$pf_twarned', the site default narrows '$pf_tokened'"
grep -q "^PREFLIGHT SLOTS mac-studio=6 rog-nv-linux=4 minix-amd-linux=4 tuf-amd-linux=3 (site default; FLEET_BOX_GPU_TOKENS)$" <<<"$out" \
  && ok "...beside a slots line with no tokens and the override named" || ko "the un-narrowed slots line is wrong -- $out"
expect "a token spec naming rog-nv-linux at every slot is a choice, printed without a warning" 0 "^PREFLIGHT SLOTS mac-studio=6 rog-nv-linux=4 minix" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS FLEET_BOX_GPU_TOKENS="rog-nv-linux=4" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
grep -q "WARNING" <<<"$out" && ko "a token spec naming rog-nv-linux drew a warning -- $out" || ok "...and no warning"
expect "...and so is a slot spec that leaves rog-nv-linux no more slots than the token default" 0 "rog-nv-linux=2 minix" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="mac-studio=6 rog-nv-linux=2 minix-amd-linux=4 tuf-amd-linux=3" FLEET_BOX_GPU_TOKENS="" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
grep -q "WARNING" <<<"$out" && ko "a two-slot rog-nv-linux drew a token warning -- $out" || ok "...with no warning"
expect "a malformed token spec is a warning on the preflight, which still passes" 0 "PREFLIGHT SLOTS WARNING: FLEET_BOX_GPU_TOKENS names stale-box, which is not in FLEET_BOXES" -- \
  env FLEET_BOX_GPU_TOKENS="stale-box=1" FLEET_BOXES="testbox otherbox" "$FW" preflight testbox --no-probe --no-cross
# The probe must not read the far-side program off stdin: a sibling that swallows its stdin would
# otherwise end the preflight early with status 0 over an earlier refusal (Codex P1 on #67).
echo x >> "$repo/ship-pr/SKILL.md"
expect "a reachable sibling does not swallow the refusal that follows the probe" 1 "1 local change(s) in the served tree" -- env FLEET_BOXES="testbox otherbox" SHIM_SSH_SLURP=otherbox "$FW" preflight testbox --no-probe
git -C "$repo" checkout -q -- ship-pr/SKILL.md
[ -d "$repo/.git/fleet-checkout.lock" ] && ko "preflight lock left after the bounded fetch" || ok "preflight lock released after the bounded fetch"
# `execution slot` runs a python3 flock on the box that runs the batches, so Python is no longer
# an anchor-only requirement and the preflight is where a box missing it must say so.
mkdir -p "$TMP/nopy"; printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/nopy/python3"; chmod +x "$TMP/nopy/python3"
expect "a box whose python3 cannot import fcntl refuses (the run-time slot lock needs it)" 1 "no python3 with fcntl" -- \
  env PATH="$TMP/nopy:$PATH" "$FW" preflight testbox --no-probe
mkdir -p "$TMP/pk-yes" "$TMP/pk-no"; printf '#!/bin/sh\nexit 0\n' > "$TMP/pk-yes/pkcheck"; printf '#!/bin/sh\nexit 1\n' > "$TMP/pk-no/pkcheck"
chmod +x "$TMP/pk-yes/pkcheck" "$TMP/pk-no/pkcheck"; printf '#!/bin/sh\n' > "$TMP/pk-yes/fleet-test-inhibit"; chmod +x "$TMP/pk-yes/fleet-test-inhibit"
expect "a box with systemd-inhibit and the polkit grant adds nothing to the OK line" 0 "PREFLIGHT OK testbox skills=[0-9a-f]*$" -- \
  env PATH="$TMP/pk-yes:$PATH" FLEET_SYSTEMD_INHIBIT=fleet-test-inhibit "$FW" preflight testbox --no-probe --no-cross
expect "...and without the grant notes the unguarded sleep guard on the OK line" 0 "PREFLIGHT OK testbox skills=[0-9a-f]* (no polkit grant for the sleep guard (runs unguarded; see issue-wave/references/executions.md#the-os-level-sleep-guard))$" -- \
  env PATH="$TMP/pk-no:$TMP/pk-yes:$PATH" FLEET_SYSTEMD_INHIBIT=fleet-test-inhibit "$FW" preflight testbox --no-probe --no-cross
# The repairs that differ by box are read from `other`, a second box the ssh shim maps here, so
# they go through run_on's real ssh path; `testbox` is this suite's LOCAL box.
FWO=(env FLEET_BOXES="testbox other" SHIM_SSH_LOCAL=other "$FW")
# The GitHub credential call (ludics-lite#360): a refused token refuses in every mode with the
# user-side repair, a GitHub that does not answer is a note, as a sleeping sibling is.
expect "a live GitHub credential passes and adds nothing to the OK line" 0 "PREFLIGHT OK testbox skills=[0-9a-f]*$" -- "$FW" preflight testbox --no-probe --no-cross
expect "a gh token answering HTTP 401 refuses with the repair" 1 "PREFLIGHT REFUSED other: GitHub credential refused in a non-interactive session on other (gh api user: gh: Bad credentials (HTTP 401)).*desktop console.*repair: ssh -t other 'gh auth login -h github.com -p https -w && gh auth setup-git'" -- \
  env SHIM_GH=401 "${FWO[@]}" preflight other --no-probe --no-cross
expect "...and refuses the native Claude preflight too" 1 "GitHub credential refused in a non-interactive session on testbox" -- env SHIM_GH=401 "$FW" preflight testbox --native-claude --no-cross
expect "...and the native Codex preflight" 1 "GitHub credential refused in a non-interactive session on testbox" -- env SHIM_GH=401 "$FW" preflight testbox --native-codex --no-cross
expect "...and the Codex CLI preflight" 1 "GitHub credential refused" -- env SHIM_GH=401 "$FW" preflight testbox --codex --no-probe --no-cross
expect "a rejected token exported in the session names it in the repair" 1 "repair: remove the GH_TOKEN this session exports (it outranks gh's stored login and blocks gh auth login) from other's shell startup, then restart any tmux server that inherited it; for the stored login: ssh -t other" -- \
  env SHIM_GH=401 GH_TOKEN=gho_dead "${FWO[@]}" preflight other --native-claude --no-cross
# The fleet's PAT file (2026-09-24): its contract is checked whatever gh answers, and a dead PAT
# is replaced in the file, never by gh auth login.
mkdir -p "$HOME/.config/fleet"; printf 'export GH_TOKEN=ghp_dead\n' > "$HOME/.config/fleet/gh-token.sh"; chmod 600 "$HOME/.config/fleet/gh-token.sh"
expect "the file's own PAT, live, passes" 0 "PREFLIGHT OK testbox skills=[0-9a-f]*$" -- env GH_TOKEN=ghp_dead "$FW" preflight testbox --native-claude --no-cross
expect "a dead PAT from gh-token.sh is replaced from the anchor's file" 1 "repair: the PAT in ~/.config/fleet/gh-token.sh is dead: replace it from the anchor: ssh other 'f=~/.config/fleet/gh-token.sh; umask 077; cat > .*f.new.* && chmod 600 .*f.new.* && mv .*f.new.*' < ~/.config/fleet/gh-token.sh; then restart any tmux server that inherited the old value$" -- \
  env SHIM_GH=401 GH_TOKEN=ghp_dead "${FWO[@]}" preflight other --native-claude --no-cross
expect "a LIVE token a later startup line exports is refused as the override" 1 "PREFLIGHT REFUSED other: this session's GH_TOKEN is not the one ~/.config/fleet/gh-token.sh exports on other: a later line of its shell startup overrides it.*grep -Hnos GH_TOKEN" -- \
  env GH_TOKEN=ghp_other "${FWO[@]}" preflight other --native-claude --no-cross
expect "...and a dead one points at that, not at the file" 1 "repair: fix the token file first (above)" -- \
  env SHIM_GH=401 GH_TOKEN=ghp_other "$FW" preflight testbox --native-claude --no-cross
expect "a gh-token.sh the session does not source names the env.sh line" 1 "this session does not export the token in ~/.config/fleet/gh-token.sh on testbox -- repair: end its ~/.config/fleet/env.sh with .*gh-token.sh.*install-linux.sh adds it)" -- \
  env -u GH_TOKEN -u GITHUB_TOKEN "$FW" preflight testbox --native-claude --no-cross
expect "an empty GH_TOKEN is not an export of the file's" 1 "this session does not export the token in ~/.config/fleet/gh-token.sh on testbox" -- \
  env GH_TOKEN= "$FW" preflight testbox --native-claude --no-cross
expect "on the anchor, a mismatch says to re-source the file or open a new shell, with no ssh" 1 "this shell's GH_TOKEN is not the one ~/.config/fleet/gh-token.sh exports -- repair: run \\. ~/.config/fleet/gh-token.sh (or open a new shell)" -- \
  env GH_TOKEN=ghp_other "$FW" preflight local --native-claude --no-cross
expect "...and so does the anchor addressed by its own name" 1 "this shell's GH_TOKEN is not the one ~/.config/fleet/gh-token.sh exports -- repair: run \\. ~/.config/fleet/gh-token.sh" -- \
  env GH_TOKEN=ghp_other FLEET_LOCAL_BOX=anchorbox "$FW" preflight anchorbox --native-claude --no-cross
printf 'export GH_TOKEN=\n' > "$HOME/.config/fleet/gh-token.sh"
expect "a gh-token.sh exporting an empty GH_TOKEN is replaced" 1 "gh-token.sh on other exports no GH_TOKEN -- repair: replace it from the anchor" -- \
  env GH_TOKEN= "${FWO[@]}" preflight other --native-claude --no-cross
printf 'GH_TOKEN=ghp_dead\n' > "$HOME/.config/fleet/gh-token.sh"
expect "...and so is one that assigns GH_TOKEN without exporting it" 1 "gh-token.sh on testbox exports no GH_TOKEN" -- \
  env GH_TOKEN=ghp_dead "$FW" preflight testbox --native-claude --no-cross
printf 'export GH_TOKEN=ghp_dead\n' > "$HOME/.config/fleet/gh-token.sh"
chmod 644 "$HOME/.config/fleet/gh-token.sh"
expect "a group-readable gh-token.sh refuses even with a live token, with the replace-the-file repair" 1 "gh-token.sh on other is not a regular mode-0600 file this user owns (-rw-r--r-- uid [0-9]*).*repair: replace it from the anchor" -- \
  env GH_TOKEN=ghp_dead "${FWO[@]}" preflight other --native-claude --no-cross
rm "$HOME/.config/fleet/gh-token.sh"; mkdir "$HOME/.config/fleet/gh-token.sh"
expect "...and a directory, whose repair removes it before the copy" 1 "gh-token.sh on other is not a regular mode-0600 file this user owns (d.*repair: move the path aside first (ssh other 'mv ~/.config/fleet/gh-token.sh ~/.config/fleet/gh-token.sh.aside'" -- \
  env GH_TOKEN=ghp_dead "${FWO[@]}" preflight other --native-claude --no-cross
rmdir "$HOME/.config/fleet/gh-token.sh"; ln -s "$TMP" "$HOME/.config/fleet/gh-token.sh"
expect "...and a symlink to a directory, the same" 1 "gh-token.sh on other is not a regular mode-0600 file this user owns (l.*repair: move the path aside first (ssh other 'mv ~/.config/fleet/gh-token.sh ~/.config/fleet/gh-token.sh.aside'" -- \
  env GH_TOKEN=ghp_dead "${FWO[@]}" preflight other --native-claude --no-cross
rm "$HOME/.config/fleet/gh-token.sh"; ln -s /dev/null "$HOME/.config/fleet/gh-token.sh"
expect "...and so does a symlink" 1 "gh-token.sh on testbox is not a regular mode-0600 file this user owns (l" -- \
  env GH_TOKEN=ghp_dead "$FW" preflight testbox --native-claude --no-cross
rm "$HOME/.config/fleet/gh-token.sh"
expect "a box never logged in to gh refuses (an unnamed failure fails closed)" 1 "GitHub credential refused.*gh auth login" -- env SHIM_GH=noauth "$FW" preflight testbox --no-probe --no-cross
expect "a GitHub that cannot be reached is noted on the OK line" 0 "PREFLIGHT OK testbox .*(GitHub unreachable from testbox: gh api user: check your internet connection" -- env SHIM_GH=down "$FW" preflight testbox --no-probe --no-cross
expect "a GitHub outage (HTTP 5xx) is noted, not refused" 0 "PREFLIGHT OK.*GitHub unreachable from testbox: gh api user: gh: Server Error (HTTP 502)" -- env SHIM_GH=5xx "$FW" preflight testbox --no-probe --no-cross
expect "a gh call that never returns is bounded and noted" 0 "PREFLIGHT OK.*GitHub unreachable from testbox: no answer from gh api user in 2s" -- env SHIM_GH=hang FLEET_GH_TIMEOUT=2 "$FW" preflight testbox --no-probe --no-cross
expect "a hanging live probe is bounded and refused" 1 "claude headless probe timed out after 2s" -- env SHIM_CLAUDE_HANG=1 FLEET_PROBE_TIMEOUT=2 "$FW" preflight testbox
expect "the live probe runs the worker's own stream-json mode: a CLI without it is refused" 1 "claude cannot run headless: error: unknown option '--input-format'" -- env SHIM_CLAUDE_OLD=1 "$FW" preflight testbox
expect "native preflight needs neither CLI login nor a model probe" 0 "PREFLIGHT OK" -- env SHIM_CODEX_LOGIN_DOWN=1 SHIM_CODEX_DOWN=1 SHIM_CLAUDE_DOWN=1 "$FW" preflight testbox --native-codex
expect "native Claude needs no CLI model probe" 0 "PREFLIGHT OK" -- env SHIM_CLAUDE_DOWN=1 SHIM_CODEX_LOGIN_DOWN=1 "$FW" preflight testbox --native-claude
expect "legacy preflight still requires CLI login" 1 "codex not logged in" -- env SHIM_CODEX_LOGIN_DOWN=1 "$FW" preflight testbox --codex --no-probe
expect "codex that cannot run headless refuses despite login status" 1 "codex cannot run headless: \"message\":\"401 Unauthorized\"" -- env SHIM_CODEX_DOWN=1 "$FW" preflight testbox --codex
echo x >> "$repo/ship-pr/SKILL.md"
expect "a tracked change under the served tree refuses" 1 "1 local change(s) in the served tree" -- "$FW" preflight testbox --no-probe
git -C "$repo" checkout -q -- .
touch "$repo/ship-pr/scripts.sh"
expect "untracked file under the served tree refuses" 1 "1 local change(s) in the served tree" -- "$FW" preflight testbox --no-probe
git -C "$repo" config status.showUntrackedFiles no
expect "...even when the box's git config hides untracked files" 1 "1 local change(s) in the served tree" -- "$FW" preflight testbox --no-probe
git -C "$repo" config --unset status.showUntrackedFiles
git -C "$repo" update-index --skip-worktree ship-pr/SKILL.md; echo hidden >> "$repo/ship-pr/SKILL.md"
expect "a skip-worktree edit under the served tree refuses" 1 "index-hidden (skip-worktree/assume-unchanged) file(s) in the served tree" -- "$FW" preflight testbox --no-probe
git -C "$repo" update-index --no-skip-worktree ship-pr/SKILL.md; git -C "$repo" checkout -q -- .
git -C "$repo" config status.relativePaths bogus
expect "a git status that cannot run refuses instead of passing an empty scan" 1 "git status failed in" -- "$FW" preflight testbox --no-probe
git -C "$repo" config --unset status.relativePaths
printf '*.tmp\n' > "$TMP/excludes"; git -C "$repo" config core.excludesFile "$TMP/excludes"; touch "$repo/ship-pr/x.tmp"
expect "an ignored file under the served tree still refuses" 1 "local change(s) in the served tree" -- "$FW" preflight testbox --no-probe
rm "$repo/ship-pr/x.tmp"; git -C "$repo" config --unset core.excludesFile
rm "$repo/ship-pr/scripts.sh"
touch "$repo/ship-pr/a b.sh"
expect "an untracked served file whose path git would quote still refuses" 1 "1 local change(s) in the served tree" -- "$FW" preflight testbox --no-probe
rm "$repo/ship-pr/a b.sh"
mkdir -p "$repo/outside"; git -C "$repo" mv after-merge/SKILL.md outside/gone.md
expect "a file renamed out of the served tree refuses (the source side counts)" 1 "1 local change(s) in the served tree" -- "$FW" preflight testbox --no-probe
git -C "$repo" mv outside/gone.md after-merge/SKILL.md; rmdir "$repo/outside"
mkdir -p "$repo/.claude"; echo '{}' > "$repo/.claude/settings.local.json"
expect "a stray .claude/ (the one path outside the served tree) passes with a notice" 0 "PREFLIGHT OK.*ignored: .claude/" -- "$FW" preflight testbox --no-probe
git -C "$repo" mv ship-pr/SKILL.md .claude/moved.md
expect "a served file renamed into .claude/ refuses (the source side counts)" 1 "1 local change(s) in the served tree" -- "$FW" preflight testbox --no-probe
git -C "$repo" mv .claude/moved.md ship-pr/SKILL.md
rm -rf "$repo/.claude"
# Behind origin: a second clone pushes; the preflight must fast-forward and pass. The bare origin
# has no HEAD for `main` (the runner's git may default to master), so name the branch to clone.
git clone --no-local -q -b main "$origin" "$TMP/other" && echo more >> "$TMP/other/ship-pr/SKILL.md" \
  && git -C "$TMP/other" commit -q -am upstream && git -C "$TMP/other" push -q origin main \
  || ko "could not advance the scratch origin (setup, not the launcher)"
expect "behind origin fast-forwards and passes" 0 "PREFLIGHT OK" -- "$FW" preflight testbox --no-probe
[ "$(git -C "$repo" rev-parse HEAD)" = "$(git -C "$TMP/other" rev-parse HEAD)" ] && ok "checkout was fast-forwarded" || ko "checkout not fast-forwarded"
echo local >> "$repo/after-merge/SKILL.md" && git -C "$repo" commit -q -am "unpushed"
expect "ahead of origin (unpushed local commit) refuses" 1 "!= origin/main" -- "$FW" preflight testbox --no-probe
git -C "$repo" reset -q --hard origin/main
git -C "$repo" checkout -q -b topic
expect "wrong branch refuses" 1 "checked out topic, not main" -- "$FW" preflight testbox --no-probe
git -C "$repo" checkout -q main && git -C "$repo" branch -q -D topic
rm "$HOME/.codex/skills/after-merge"
expect "missing codex skill link refuses only for codex" 1 "codex/skills/after-merge -> missing" -- "$FW" preflight testbox --codex --no-probe
expect "native preflight still requires Codex skill links" 1 "codex/skills/after-merge -> missing" -- "$FW" preflight testbox --native-codex
expect "...and claude preflight still passes" 0 "PREFLIGHT OK" -- "$FW" preflight testbox --no-probe
expect "native Claude does not require Codex skill links" 0 "PREFLIGHT OK" -- "$FW" preflight testbox --native-claude
ln -sfn "$repo/after-merge" "$HOME/.codex/skills/after-merge"
mkdir -p "$TMP/elsewhere"; ln -sfn "$TMP/elsewhere" "$HOME/.claude/skills/ship-pr"
expect "skill link pointing outside the checkout refuses" 1 "skills/ship-pr -> $TMP/elsewhere" -- "$FW" preflight testbox --no-probe
expect "native Claude still requires deployed Claude skill links" 1 "skills/ship-pr -> $TMP/elsewhere" -- "$FW" preflight testbox --native-claude
mkdir -p "$TMP/outside-skill"; ln -sfn "$repo/../outside-skill" "$HOME/.claude/skills/ship-pr"
expect "skill link that escapes the checkout through .. refuses" 1 "skills/ship-pr -> $TMP/outside-skill" -- "$FW" preflight testbox --no-probe
rm "$HOME/.claude/skills/ship-pr"; cp -R "$repo/ship-pr" "$HOME/.claude/skills/ship-pr"
expect "a real directory in place of the link refuses" 1 "skills/ship-pr -> missing/not a link" -- "$FW" preflight testbox --no-probe
rm -rf "$HOME/.claude/skills/ship-pr"; ln -sfn "$repo/wait-and-proceed" "$HOME/.claude/skills/ship-pr"
expect "a link swapped to a sibling skill refuses" 1 "skills/ship-pr -> .*/wait-and-proceed (not " -- "$FW" preflight testbox --no-probe
ln -sfn "$repo/ship-pr" "$HOME/.claude/skills/ship-pr"
# A stale tmux server environment (ludics-lite#327): a new session takes the server's
# environment, so a server started before an env.sh/gpu.sh edit hands CLI workers the old values.
# The shim plays the server; `fresh` pins the three GPU/OCaml variables of the far-side shell, the
# reference a server started now would inherit.
fresh=(env -u ROCM_PATH -u HIP_PATH -u OPAM_SWITCH_PREFIX)
printf 'PATH=%s\n-ROCM_PATH\nTERM=screen\n' "$PATH" > "$TMP/genv-match"
printf 'PATH=%s\nROCM_PATH=/usr\n' "$PATH" > "$TMP/genv-rocm"
printf 'PATH=/old/bin:%s\n' "$PATH" > "$TMP/genv-path"
expect "a tmux server whose environment matches a fresh shell passes" 0 "PREFLIGHT OK" -- \
  "${fresh[@]}" SHIM_TMUX_GENV="$TMP/genv-match" SHIM_TMUX_SESSIONS="iw-live" "$FW" preflight testbox --no-probe
expect "no tmux server running passes (the next launch starts a fresh one)" 0 "PREFLIGHT OK" -- \
  "${fresh[@]}" HIP_PATH=/usr SHIM_TMUX_GENV=none "$FW" preflight testbox --no-probe
expect "a server still exporting a dropped ROCM_PATH refuses, naming it, and says to wait for its live worker" 1 \
  "stale tmux server environment (ROCM_PATH is /usr in the server but unset in a fresh shell): .*wait for its live worker session(s) (iw-w7 iw-w8; \`fleet-worker.sh ls testbox\`) to finish" -- \
  "${fresh[@]}" SHIM_TMUX_GENV="$TMP/genv-rocm" SHIM_TMUX_SESSIONS="iw-w7 iw-w8" "$FW" preflight testbox --no-probe
grep -q 'restart it with' <<<"$out" && ko "kill-server offered as the fix while a worker session is live -- $out" \
  || ok "no restart is offered while a worker session is live"
expect "with no live worker session, the refusal names the socket's kill-server" 1 \
  "ROCM_PATH is /usr in the server .*no worker session is live on it, so restart it with \`tmux -L $FLEET_TMUX_SOCKET kill-server\` and try again" -- \
  "${fresh[@]}" SHIM_TMUX_GENV="$TMP/genv-rocm" "$FW" preflight testbox --no-probe
expect "...and warns which non-worker sessions a kill-server would end" 1 "kill-server also ends its non-worker session(s): notes)" -- \
  "${fresh[@]}" SHIM_TMUX_GENV="$TMP/genv-rocm" SHIM_TMUX_SESSIONS="notes" "$FW" preflight testbox --no-probe
expect "...and warns of them too when the advice is to wait for live workers first" 1 "to finish, then .*kill-server.* if it outlives them (kill-server also ends its non-worker session(s): notes)" -- \
  "${fresh[@]}" SHIM_TMUX_GENV="$TMP/genv-rocm" SHIM_TMUX_SESSIONS="iw-w7 notes" "$FW" preflight testbox --no-probe
expect "a variable tmux refreshes from the client (update-environment) is not compared" 0 "PREFLIGHT OK" -- \
  "${fresh[@]}" SHIM_TMUX_GENV="$TMP/genv-rocm" SHIM_TMUX_UPDATE_ENV="ROCM_PATH" "$FW" preflight testbox --no-probe
expect "...while the variables it does not refresh still are" 1 "PATH is /old/bin:.* in the server" -- \
  "${fresh[@]}" SHIM_TMUX_GENV="$TMP/genv-path" SHIM_TMUX_UPDATE_ENV="ROCM_PATH" "$FW" preflight testbox --no-probe
expect "a variable the fresh shell gained since the server started refuses too" 1 "HIP_PATH is unset in the server but /usr in a fresh shell" -- \
  "${fresh[@]}" HIP_PATH=/usr SHIM_TMUX_GENV="$TMP/genv-match" "$FW" preflight testbox --no-probe
expect "a PATH that moved since the server started refuses" 1 "PATH is /old/bin:.* in the server but .* in a fresh shell" -- \
  "${fresh[@]}" SHIM_TMUX_GENV="$TMP/genv-path" "$FW" preflight testbox --no-probe
expect "every stale variable is named in one refusal" 1 "(ROCM_PATH is /usr in the server but unset in a fresh shell, OPAM_SWITCH_PREFIX is unset in the server but /o in a fresh shell)" -- \
  "${fresh[@]}" OPAM_SWITCH_PREFIX=/o SHIM_TMUX_GENV="$TMP/genv-rocm" "$FW" preflight testbox --no-probe
expect "native workers never run under tmux, so a stale server does not refuse them" 0 "PREFLIGHT OK" -- \
  "${fresh[@]}" SHIM_TMUX_GENV="$TMP/genv-rocm" "$FW" preflight testbox --native-claude
# The same fact against a real tmux server, on a socket of its own: the shim above must not be the
# only thing that knows the output shape of show-environment.
envsock="fwtest-env-$$"
"${fresh[@]}" ROCM_PATH=/usr "$REAL_TMUX" -L "$envsock" new-session -d -s iw-real 'sleep 60'
expect "a real server started with ROCM_PATH=/usr refuses a fresh shell without it" 1 \
  "ROCM_PATH is /usr in the server but unset in a fresh shell): .*wait for its live worker session(s) (iw-real;" -- \
  "${fresh[@]}" FLEET_TMUX_SOCKET="$envsock" "$FW" preflight testbox --no-probe
# update-environment, on the real server: tmux copies ROCM_PATH from the launching client into
# each new session, so the stale global value reaches no worker and the launch is safe.
"$REAL_TMUX" -L "$envsock" set-option -ga update-environment ROCM_PATH
expect "a real server that refreshes ROCM_PATH from the client passes despite its stale global value" 0 "PREFLIGHT OK" -- \
  "${fresh[@]}" FLEET_TMUX_SOCKET="$envsock" "$FW" preflight testbox --no-probe
"$REAL_TMUX" -L "$envsock" set-option -gu update-environment
# exit-empty off: the server outlives its last session and a new one would still inherit from it.
"$REAL_TMUX" -L "$envsock" set-option -g exit-empty off
"$REAL_TMUX" -L "$envsock" kill-session -t iw-real
expect "a real server left with no session (exit-empty off) is still checked" 1 "ROCM_PATH is /usr in the server .*no worker session is live on it, so restart it with \`tmux -L $envsock kill-server\`" -- \
  "${fresh[@]}" FLEET_TMUX_SOCKET="$envsock" "$FW" preflight testbox --no-probe
"$REAL_TMUX" -L "$envsock" kill-server 2>/dev/null
"${fresh[@]}" "$REAL_TMUX" -L "$envsock" new-session -d -s iw-real 'sleep 60'
expect "...and a real server started from the same environment passes" 0 "PREFLIGHT OK" -- \
  "${fresh[@]}" FLEET_TMUX_SOCKET="$envsock" "$FW" preflight testbox --no-probe
"$REAL_TMUX" -L "$envsock" kill-server 2>/dev/null
}

# --- load: an asleep box is a row, not a failure ------------------------------------------------
# `load` is placement input, and the box it most often reports asleep is tuf-amd-linux (Wi-Fi only,
# manual wake; ludics-lite#320). The payload below is flotilla's own shape for an endpoint that did
# not answer, copied from http://mac-studio:7799/api/fleet on 2026-09-23 (`data` null, null
# averages, an ssh error). curl is shimmed on this case's PATH only.
section "load" && {
mkdir -p "$TMP/loadbin"
printf '#!/usr/bin/env bash\ncat "$SHIM_FLEET_JSON"\n' > "$TMP/loadbin/curl"; chmod +x "$TMP/loadbin/curl"
cat > "$TMP/fleet-asleep.json" <<'JSON'
{"machines":[
 {"name":"mac-studio","endpoints":{"local":{"kind":"unix","host":"local","ok":true,"data":{"counts":{"dune":0},"sessions":{"claude":[1],"codex":[]},"gpu":{"name":"Apple M4 Max"}},"avg":{"m5":{"cpu_pct":12.7,"gpu_util_pct":0}}}}},
 {"name":"tuf","sleep_status":null,"wol":false,"endpoints":{"linux":{"kind":"unix","host":"tuf-amd-linux","ok":false,"data":null,"error":"exit 255: ssh: connect to host tuf-amd-linux port 22: Operation timed out","fetched_at":null,"avg":{"m1":{"cpu_pct":null,"gpu_util_pct":null,"samples":0},"m5":{"cpu_pct":null,"gpu_util_pct":null,"samples":0},"m15":{"cpu_pct":null,"gpu_util_pct":null,"samples":0}}},"win":{"kind":"windows","host":"tuf-amd-win","ok":false,"data":null}}}
]}
JSON
tab=$'\t'
out=$(env PATH="$TMP/loadbin:$PATH" SHIM_FLEET_JSON="$TMP/fleet-asleep.json" "$FW" load 2>&1); rc=$?
if [ "$rc" -eq 0 ] && grep -q "^tuf${tab}tuf-amd-linux${tab}ok=false${tab}cpu5=?%" <<<"$out" &&
   grep -q "^mac-studio${tab}local${tab}ok=true" <<<"$out"; then
  ok "load reports a sleeping TUF as an ok=false row beside the live boxes, exit 0"
else ko "load over a sleeping TUF (rc=$rc) -- $out"; fi
}

section "launch / attach / status / log with a project repo and --repo/--branch" && {
expect "launch without a lease refuses" 1 "LAUNCH REFUSED testbox/w1: no coordinator lease" -- \
  "$FW" launch testbox w1 --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/w1
"$FW" claim >/dev/null
expect "launch says on stderr which sibling did not answer, and still launches" 0 "preflight note for testbox/w-cross: (cross-box unreachable, asleep or off the network: otherbox)" -- \
  env FLEET_BOXES="testbox otherbox" SHIM_SSH_DOWN=otherbox "$FW" launch testbox w-cross --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
settle w-cross
echo x >> "$repo/ship-pr/SKILL.md"
expect "launch runs the preflight on the box and refuses a dirty served tree" 1 "LAUNCH REFUSED testbox/w1: PREFLIGHT REFUSED testbox: 1 local change(s) in the served tree" -- \
  "$FW" launch testbox w1 --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/w1
git -C "$repo" checkout -q -- .
# The launch's far side re-reads the tmux server just before new-session (ludics-lite#327): the
# base gate between it and the preflight can take minutes. Here the server turns stale during it.
printf 'PATH=%s\nROCM_PATH=/usr\n' "$PATH" > "$TMP/genv-late"; rm -f "$TMP/stale-now"
expect "a tmux server that turns stale after the preflight still refuses the launch" 1 "LAUNCH REFUSED testbox/wz: stale tmux server environment (ROCM_PATH is /usr in the server" -- \
  env -u ROCM_PATH -u HIP_PATH -u OPAM_SWITCH_PREFIX SHIM_TMUX_GENV="$TMP/genv-late" SHIM_TMUX_GENV_WHEN="$TMP/stale-now" SHIM_BASE_TOUCH="$TMP/stale-now" \
  "$FW" launch testbox wz --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
grep -q 'PREFLIGHT REFUSED' <<<"$out" && ko "the stale server was caught by the preflight, not the late re-read -- $out" || ok "the late re-read, not the preflight, caught it"
[ -e "$ISSUE_WAVE_STATE/workers/wz" ] && ko "a stale-server refusal left a record behind" || ok "a stale-server refusal leaves no record"
rm -f "$TMP/stale-now"
expect "launch creates the worktree and reports the session" 0 "LAUNCHED testbox/w1 kind=claude session=[0-9a-f-]\{36\} cwd=$proj-worktrees/w1" -- \
  "$FW" launch testbox w1 --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/w1 -- --model opus
[ -d "$proj-worktrees/w1" ] && [ "$(git -C "$proj-worktrees/w1" rev-parse --abbrev-ref HEAD)" = claude/w1 ] && ok "worktree on the requested branch" || ko "worktree missing or wrong branch"
grep -q -- "--model opus" "$ISSUE_WAVE_STATE/workers/w1/run.sh" && ok "extra CLI args reach the command line" || ko "extra args lost"
# ludics-lite#259: a claude worker is one stream-json process fed from input.jsonl, the brief first.
grep -q -- "{ tail -n +1 -f .*input.jsonl .* | {" "$ISSUE_WAVE_STATE/workers/w1/run.sh" && grep -q -- "claude -p --input-format stream-json --output-format stream-json --verbose --replay-user-messages " "$ISSUE_WAVE_STATE/workers/w1/run.sh" &&
  ok "a claude worker runs one stream-json process fed from its input channel" || ko "claude command: $(cat "$ISSUE_WAVE_STATE/workers/w1/run.sh")"
[ "$(jq -j '.message.content' "$ISSUE_WAVE_STATE/workers/w1/input.jsonl")" = "$(cat "$brief")" ] && [ "$(grep -c '' "$ISSUE_WAVE_STATE/workers/w1/input.jsonl")" -eq 1 ] &&
  ok "the brief is the channel's first line, byte for byte" || ko "input.jsonl: $(cat "$ISSUE_WAVE_STATE/workers/w1/input.jsonl")"
expect "attach returns IDLE when the turn ends: the process stays up for the next message" 0 "IDLE testbox/w1 success is_error=false .* | awaiting input" -- "$FW" attach testbox w1 --interval 1
expect "...ls reads it as IDLE" 0 "testbox/w1 IDLE kind=claude" -- "$FW" ls testbox
expect "...status names the turn state and no unread input" 0 "IDLE testbox/w1 kind=claude .* | turn=ended background_tasks=0 unread=0 | " -- "$FW" status testbox w1
expect "...and attach re-armed on an IDLE worker answers at once" 0 "IDLE testbox/w1 " -- "$FW" attach testbox w1 --interval 30
expect "close ends an IDLE worker and prints the final verdict" 0 "DONE testbox/w1 exit=0 success is_error=false" -- "$FW" close testbox w1
[ ! -e "$ISSUE_WAVE_STATE/workers/w1/feeder.pid" ] && ok "the process's end removes its feeder pid" || ko "feeder pid left behind"
expect "close of an ended worker prints its verdict as it stands" 0 "DONE testbox/w1 exit=0" -- "$FW" close testbox w1
git -C "$proj" branch -q -f alt-base master && echo b > "$proj/b" && git -C "$proj" add b && git -C "$proj" commit -q -m b && git -C "$proj" push -q origin master alt-base
expect "FLEET_BASE_REF sets the worktree's start point when --base is not given" 0 "LAUNCHED testbox/wb " -- \
  env FLEET_BASE_REF=origin/alt-base "$FW" launch testbox wb --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/wb
[ "$(git -C "$proj-worktrees/wb" rev-parse HEAD)" = "$(git -C "$proj" rev-parse origin/alt-base)" ] && ok "worktree started from FLEET_BASE_REF" || ko "worktree did not start from FLEET_BASE_REF"
settle wb
[ "$(cat "$ISSUE_WAVE_STATE/workers/w1/brief.md")" = "$(cat "$brief")" ] && ok "brief crossed byte-for-byte" || ko "brief mangled"
expect "status after exit names head and branch" 0 "EXITED(0) testbox/w1 kind=claude .*branch=claude/w1" -- "$FW" status testbox w1
expect "log prints the assistant text" 0 "did: Fix issue #1" -- "$FW" log testbox w1
expect "unknown worker is UNKNOWN, exit 3" 3 "UNKNOWN testbox/nope" -- "$FW" status testbox nope
expect "the literal box name local is the same box, labelled as typed" 0 "EXITED(0) local/w1 kind=claude" -- "$FW" status local w1
printf 'a different brief\n' > "$TMP/brief2.md"
expect "a finished worker's name is not reused silently" 1 "finished worker's record is here" -- \
  "$FW" launch testbox w1 --target-repo example/project --kind claude --brief "$TMP/brief2.md" --cwd "$proj-worktrees/w1"
[ "$(cat "$ISSUE_WAVE_STATE/workers/w1/brief.md")" = "$(cat "$brief")" ] && ok "a refused launch leaves the recorded brief untouched" || ko "refused launch overwrote brief.md"
grep -q '^w1-' <<<"$(ls "$ISSUE_WAVE_STATE/incoming/" 2>/dev/null)" && ko "refused launch left its staged brief behind" || ok "refused launch cleans up its staged brief"
git -C "$proj-worktrees/w1" checkout -q -b other
expect "a reused worktree on another branch refuses" 1 "exists but is on 'other', not claude/w1" -- \
  "$FW" launch testbox w1 --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/w1 --replace
git -C "$proj-worktrees/w1" checkout -q claude/w1 && git -C "$proj-worktrees/w1" branch -q -D other
foreign="$proj-worktrees/wx"; git init -q -b claude/wx "$foreign" && echo z > "$foreign/z" && git -C "$foreign" add z && git -C "$foreign" commit -q -m z
expect "a foreign repository at the derived path is refused even on the right branch" 1 "exists but is not a worktree of" -- \
  "$FW" launch testbox wx --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/wx
rm -rf "$foreign"
expect "a reused worktree on the requested branch is accepted" 0 "reusing existing worktree .* (on claude/w1)" -- \
  "$FW" launch testbox w1 --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/w1 --replace
settle w1
bash -c 'sleep 30; :' claude "$ISSUE_WAVE_STATE/workers/w1/" >/dev/null 2>&1 & orphan=$!
expect "--replace refuses while a process still carries the old worker's path" 1 "a CLI from the previous launch is still running" -- \
  "$FW" launch testbox w1 --target-repo example/project --kind claude --brief "$brief" --cwd "$proj-worktrees/w1" --replace
kill "$orphan" 2>/dev/null; wait "$orphan" 2>/dev/null
rm -rf "$ISSUE_WAVE_STATE/replaced"; : > "$ISSUE_WAVE_STATE/replaced"
expect "--replace with an unusable archive namespace refuses and changes nothing" 1 "cannot archive the previous record .* nothing was changed" -- \
  "$FW" launch testbox w1 --target-repo example/project --kind claude --brief "$brief" --cwd "$proj-worktrees/w1" --replace
[ -s "$ISSUE_WAVE_STATE/workers/w1/stream.jsonl" ] && [ -f "$ISSUE_WAVE_STATE/workers/w1/exit" ] && ok "the old record is intact" || ko "old record damaged by a failed archive"
rm -f "$ISSUE_WAVE_STATE/replaced"
oldstream=$(cat "$ISSUE_WAVE_STATE/workers/w1/stream.jsonl")
expect "--replace archives the previous record and starts a fresh one" 0 "LAUNCHED testbox/w1 .* replaced=.*/replaced/w1-" -- \
  "$FW" launch testbox w1 --target-repo example/project --kind claude --brief "$brief" --cwd "$proj-worktrees/w1" --replace
arch=$(printf '%s' "$out" | sed -n 's/.* replaced=//p')
[ -n "$arch" ] && [ "$(cat "$arch/stream.jsonl")" = "$oldstream" ] && [ -f "$arch/exit" ] && ok "the archived record keeps the old stream and exit" || ko "archive missing or incomplete: $arch"
[ "$(cat "$ISSUE_WAVE_STATE/workers/w1/brief.md")" = "$(cat "$brief")" ] && ok "the fresh record has the new brief" || ko "fresh record brief wrong"
settle w1
expect "ls lists local workers with state" 0 "testbox/w1 EXITED(0) kind=claude" -- "$FW" ls testbox
out=$(FLEET_BOXES="testbox" "$FW" ls 2>&1)
[ "$(printf '%s\n' "$out" | grep -c '/w1 ')" -eq 1 ] && grep -q '^local/w1 ' <<<"$out" && ok "default ls sweeps the fleet minus the local box, once" || ko "default ls: $out"
}

section "failure verdicts" && {
need_lease   # this section and every one below launch workers; see the shared setup above
# Its result text says `is_error=false`: the verdict reads the field, never the text.
printf 'FAIL on purpose; is_error=false\n' > "$TMP/fail.md"
"$FW" launch testbox wf --target-repo example/project --kind claude --brief "$TMP/fail.md" --cwd "$proj" >/dev/null
expect "an erroring turn attaches as FAILED idle, exit 1: the process awaits input" 1 "FAILED testbox/wf idle error_during_execution is_error=true .* | awaiting input" -- "$FW" attach testbox wf --interval 1
expect "...and its close reports the failed last turn" 1 "FAILED testbox/wf exit=0 error_during_execution is_error=true" -- "$FW" close testbox wf
printf 'SILENT\n' > "$TMP/silent.md"
"$FW" launch testbox wsil --target-repo example/project --kind claude --brief "$TMP/silent.md" --cwd "$proj" >/dev/null
expect "exit 0 with no terminal event is FAILED, not DONE" 1 "FAILED testbox/wsil exit=0 no terminal event" -- "$FW" attach testbox wsil --interval 1
printf 'SLEEP 30\n' > "$TMP/slow.md"
"$FW" launch testbox wv --target-repo example/project --kind claude --brief "$TMP/slow.md" --cwd "$proj" >/dev/null
sleep 1; tmux -L "$FLEET_TMUX_SOCKET" kill-session -t iw-wv
expect "a killed session with no exit record is VANISHED, exit 3" 3 "VANISHED testbox/wv" -- "$FW" attach testbox wv --interval 1
expect "relaunching a vanished name refuses without --replace" 1 "left no exit record" -- "$FW" launch testbox wv --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
# An orphan: tmux gone, a process still carrying the worker's state dir. Supervision must see it.
bash -c 'sleep 4; :' claude "$ISSUE_WAVE_STATE/workers/wv/" >/dev/null 2>&1 & disown; sleep 0.5
expect "status reports an orphaned CLI as ORPHANED" 0 "ORPHANED testbox/wv" -- "$FW" status testbox wv
expect "ls reports it as ORPHANED too" 0 "testbox/wv ORPHANED" -- "$FW" ls testbox
t0=$(date +%s)
expect "attach waits for the orphan to exit and then reports VANISHED" 3 "VANISHED testbox/wv" -- "$FW" attach testbox wv --interval 1
[ $(( $(date +%s) - t0 )) -ge 2 ] && ok "attach held while the orphan lived" || ko "attach returned before the orphan exited"
# ludics-lite#361: a DONE turn that ended announcing a pending wait is marked, not failed.
printf 'The watch is ARMED; it will wake me\n' > "$TMP/strand.md"
"$FW" launch testbox wst --target-repo example/project --kind claude --brief "$TMP/strand.md" --cwd "$proj" >/dev/null
expect "a final message announcing a pending wait marks IDLE as a PROBABLE STRAND when no background task is listed, exit still 0" 0 \
  'IDLE testbox/wst .* | PROBABLE STRAND: the final message says "will wake me"; no background task of the worker is pending' -- "$FW" attach testbox wst --interval 1
expect "...and so does the DONE its close prints" 0 \
  'DONE testbox/wst exit=0 .* | PROBABLE STRAND: the final message says "will wake me"' -- "$FW" close testbox wst
printf 'The watch returned rc=0 and it merged\n' > "$TMP/nostrand.md"
"$FW" launch testbox wns --target-repo example/project --kind claude --brief "$TMP/nostrand.md" --cwd "$proj" >/dev/null
out=$("$FW" attach testbox wns --interval 1 2>&1)
grep -q '^IDLE testbox/wns ' <<<"$out" && ! grep -q 'PROBABLE STRAND' <<<"$out" && ok "a final message with no listed phrase is a plain IDLE" || ko "unlisted final message: $out"
settle wns
# A turn that ends with a background task listed is not the worker idle: the task's completion
# starts a turn of its own (Claude Code 2.1.282), so attach waits it out.
printf 'BG 5 then report\n' > "$TMP/bg.md"
"$FW" launch testbox wbg --target-repo example/project --kind claude --brief "$TMP/bg.md" --cwd "$proj" >/dev/null
for i in $(seq 1 20); do grep -q '"background_tasks_changed","tasks":\[{' "$ISSUE_WAVE_STATE/workers/wbg/stream.jsonl" 2>/dev/null && break; sleep 0.25; done
expect "a turn ended with a background task listed reads as RUNNING, not IDLE" 0 "RUNNING testbox/wbg .* turn=ended background_tasks=1 " -- "$FW" status testbox wbg
for i in $(seq 1 40); do grep -q '"tasks":\[\]' "$ISSUE_WAVE_STATE/workers/wbg/stream.jsonl" 2>/dev/null && break; sleep 0.25; done
expect "...and the task list clearing starts the task's turn before its notification or init: RUNNING, turn=working" 0 "RUNNING testbox/wbg .* turn=working background_tasks=0 " -- "$FW" status testbox wbg
for i in $(seq 1 40); do grep -q '"task_notification"' "$ISSUE_WAVE_STATE/workers/wbg/stream.jsonl" 2>/dev/null && break; sleep 0.25; done
expect "...as does the notification before the init" 0 "RUNNING testbox/wbg .* turn=working background_tasks=0 " -- "$FW" status testbox wbg
expect "...attach waits for the turn the task's completion starts" 0 "IDLE testbox/wbg .*background task done" -- "$FW" attach testbox wbg --interval 1
settle wbg
# A feeder that outlived its CLI must not follow the archived record forever after a --replace.
tail -n +1 -f "$ISSUE_WAVE_STATE/workers/wbg/input.jsonl" >/dev/null 2>&1 & stale=$!; echo "$stale" > "$ISSUE_WAVE_STATE/workers/wbg/feeder.pid"
"$FW" launch testbox wbg --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace >/dev/null
sleep 0.5; kill -0 "$stale" 2>/dev/null && { ko "--replace left the old record's feeder running"; kill "$stale"; } || ok "--replace ends a feeder the old record left behind"
wait "$stale" 2>/dev/null; settle wbg
# The verdict of an ended process reads only what follows the echo of the latest message: a
# message echoed and never answered is no DONE, even with an earlier turn's result after the append.
printf 'BG 4\n' > "$TMP/bg4b.md"; printf 'SILENT\n' > "$TMP/silent-msg.md"
"$FW" launch testbox wqs --target-repo example/project --kind claude --brief "$TMP/bg4b.md" --cwd "$proj" >/dev/null
for i in $(seq 1 20); do grep -q '"background_tasks_changed","tasks":\[{' "$ISSUE_WAVE_STATE/workers/wqs/stream.jsonl" 2>/dev/null && break; sleep 0.25; done
FLEET_DELIVERY_WAIT=0 "$FW" unstick testbox wqs --message "$TMP/silent-msg.md" >/dev/null
expect "a message echoed but never answered before the CLI exited is FAILED, not the earlier turn's DONE" 1 "FAILED testbox/wqs exit=0 no terminal event" -- "$FW" attach testbox wqs --interval 1
}

section "unstick" && {
need_lease
need_worker w1   # its own worktree, for the sibling-session case below
# ludics-lite#259: a live claude worker takes the message by append -- mid-turn it reaches the
# model at the next tool boundary, idle it starts the next turn -- with no kill and no resume.
wsd="$ISSUE_WAVE_STATE/workers/ws"
printf 'SLEEP 6 then report\n' > "$TMP/slow.md"
"$FW" launch testbox ws --target-repo example/project --kind claude --brief "$TMP/slow.md" --cwd "$proj" >/dev/null; sleep 1
pid_before=$(cat "$wsd/feeder.pid")
expect "unstick of a live worker mid-turn appends the message and proves delivery from its echo" 0 \
  "APPENDED testbox/ws kind=claude session=[0-9a-f-]\{36\} to=RUNNING .* delivered (echoed by the CLI)" -- "$FW" unstick testbox ws --message "$TMP/msg.md"
expect "...the turn in flight answers it: attach waits for that reply" 0 "IDLE testbox/ws success .*did: SLEEP 6 then report +msg: Stop and answer now" -- "$FW" attach testbox ws --interval 1
[ "$(cat "$wsd/feeder.pid")" = "$pid_before" ] && ! grep -q '"resumed":true' "$wsd/stream.jsonl" && grep -q '^resumes=0$' "$wsd/meta" &&
  ok "...the same process took it: no restart, no resume" || ko "the append restarted the worker: $(cat "$wsd/meta")"
[ "$(grep -c '' "$wsd/input.jsonl")" -eq 2 ] && [ "$(sed -n 2p "$wsd/input.jsonl" | jq -j '.message.content')" = "$(cat "$TMP/msg.md")" ] &&
  ok "...and input.jsonl logs the message after the brief" || ko "input.jsonl: $(cat "$wsd/input.jsonl")"
printf 'Now the next step.\n' > "$TMP/msg2.md"
expect "an append to an IDLE worker starts its next turn" 0 "APPENDED testbox/ws .* to=IDLE .* delivered" -- "$FW" unstick testbox ws --message "$TMP/msg2.md"
expect "...whose reply attach returns" 0 "IDLE testbox/ws success .*did: Now the next step" -- "$FW" attach testbox ws --interval 1
expect "a live worker refuses extra CLI args on the append path: they need a new process" 1 "UNSTICK REFUSED testbox/ws: extra CLI arguments (--model opus) cannot reach a live process" -- "$FW" unstick testbox ws --message "$TMP/msg.md" -- --model opus
mv "$proj" "$proj.moved"
expect "a live worker whose worktree is gone refuses the append too" 1 "UNSTICK REFUSED testbox/ws: recorded working directory .* is gone" -- "$FW" unstick testbox ws --message "$TMP/msg.md"
mv "$proj.moved" "$proj"
[ "$(grep -c '' "$wsd/input.jsonl")" -eq 3 ] && ok "...neither refusal touched the input channel" || ko "a refused append wrote input: $(cat "$wsd/input.jsonl")"
# An appended line the CLI has not answered: close would drop it by closing the input under it.
cp "$wsd/meta" "$TMP/ws.meta"; sed -i.bak 's/^awaiting=.*/awaiting=never-sent/' "$wsd/meta" && rm -f "$wsd/meta.bak"
expect "close refuses an IDLE worker whose latest message has no reply yet" 1 "CLOSE REFUSED testbox/ws: idle, but the latest message sent has no reply yet" -- "$FW" close testbox ws
cp "$TMP/ws.meta" "$wsd/meta"
cp "$wsd/feeder.pid" "$TMP/feeder.saved"; echo $$ > "$wsd/feeder.pid"
expect "a live session whose input feeder is gone refuses the append and names --kill" 1 "UNSTICK REFUSED testbox/ws: the CLI's session is up but its input channel is not" -- "$FW" unstick testbox ws --message "$TMP/msg.md"
cp "$TMP/feeder.saved" "$wsd/feeder.pid"
jq -cn '{type: "user", uuid: "x-1", message: {role: "user", content: "SLEEP 4"}}' >> "$wsd/input.jsonl"; sleep 2
expect "close refuses a worker whose turn is in progress" 1 "CLOSE REFUSED testbox/ws: not idle (turn=working" -- "$FW" close testbox ws
# A record from before the channel, still running its one-shot turn: no input to append to.
sleep 3; sed -i.bak '/^channel=/d' "$wsd/meta" && rm -f "$wsd/meta.bak"
expect "a live one-shot claude worker still refuses without --kill" 1 "still running.*pass --kill" -- "$FW" unstick testbox ws --message "$TMP/msg.md"
echo "channel=stream-json" >> "$wsd/meta"
expect "unstick --kill stops a live worker and resumes the same session" 0 "RESUMED testbox/ws kind=claude session=[0-9a-f-]\{36\} resume=1 .*(kill-and-resume: --kill stopped the live CLI)" -- \
  "$FW" unstick testbox ws --message "$TMP/msg.md" --kill
sid=$(sed -n 's/^session=//p' "$wsd/meta")
grep -q -- "--resume $sid" "$wsd/run.sh" && grep -q -- "tail -n +5 -f " "$wsd/run.sh" && ok "the resume addresses the recorded session and feeds from the message's own line" || ko "resume command wrong: $(cat "$wsd/run.sh")"
expect "the resumed process answers the message and idles" 0 "IDLE testbox/ws .*did: Stop and answer now" -- "$FW" attach testbox ws --interval 1
grep -q '"resumed":true' "$wsd/stream.jsonl" && ok "stream appended, not truncated, across the resume" || ko "stream lost the resume"
[ "$(tail -n +"$(( $(sed -n 's/^proc_offset=//p' "$wsd/meta") + 1 ))" "$wsd/stream.jsonl" | grep -c '"isReplay":true')" -eq 1 ] && ok "the resumed process read no line an earlier one had" || ko "the resume replayed old input"
grep -q '^resumes=1$' "$wsd/meta" && ok "meta counts the resume" || ko "meta resumes not bumped"
# A CLI that outlives its session (an orphan carrying this record's path) still holds close open.
bash -c 'sleep 4; :' claude "$wsd/" >/dev/null 2>&1 & orphan=$!; t0=$(date +%s)
expect "close ends it with the resumed turn's verdict" 0 "DONE testbox/ws exit=0 .*did: Stop and answer now" -- "$FW" close testbox ws
[ $(( $(date +%s) - t0 )) -ge 3 ] && ! kill -0 "$orphan" 2>/dev/null && ok "...and waits out a CLI still running past its session" || ko "close returned while an orphaned CLI still ran"
wait "$orphan" 2>/dev/null
# Delivery is proven by the echo, not assumed: a CLI that has not read the line yet (here inside a
# turn that reads nothing) leaves it queued and unread, and attach waits for its reply.
printf 'BG 6\n' > "$TMP/bg4.md"
"$FW" launch testbox wq --target-repo example/project --kind claude --brief "$TMP/bg4.md" --cwd "$proj" >/dev/null
for i in $(seq 1 20); do grep -q '"background_tasks_changed","tasks":\[{' "$ISSUE_WAVE_STATE/workers/wq/stream.jsonl" 2>/dev/null && break; sleep 0.25; done
expect "a message the CLI has not read is reported queued, not delivered" 0 "APPENDED testbox/wq .* queued: not echoed within 1s" -- env FLEET_DELIVERY_WAIT=1 "$FW" unstick testbox wq --message "$TMP/msg.md"
expect "...status counts it unread" 0 "turn=.* unread=1 " -- "$FW" status testbox wq
expect "...and attach returns the reply to it, not the turn that ended before it was read" 0 "IDLE testbox/wq .*did: Stop and answer now" -- "$FW" attach testbox wq --interval 1
expect "...after which it is read" 0 "unread=0 " -- "$FW" status testbox wq
settle wq
# A message still queued when the process is killed is fed to the resumed one, before the new one.
"$FW" launch testbox wr --target-repo example/project --kind claude --brief "$TMP/bg4.md" --cwd "$proj" >/dev/null
for i in $(seq 1 20); do grep -q '"background_tasks_changed","tasks":\[{' "$ISSUE_WAVE_STATE/workers/wr/stream.jsonl" 2>/dev/null && break; sleep 0.25; done
FLEET_DELIVERY_WAIT=0 "$FW" unstick testbox wr --message "$TMP/msg.md" >/dev/null
expect "a kill-and-resume over a queued message" 0 "RESUMED testbox/wr " -- "$FW" unstick testbox wr --message "$TMP/msg2.md" --kill
grep -q -- "tail -n +2 -f " "$ISSUE_WAVE_STATE/workers/wr/run.sh" && ok "...resumes from the first line the dead process never echoed" || ko "resume skipped the queued message: $(cat "$ISSUE_WAVE_STATE/workers/wr/run.sh")"
expect "...and the resumed process answers both, the new one last" 0 "IDLE testbox/wr .*did: Now the next step" -- "$FW" attach testbox wr --interval 1
grep -q '"text":"did: Stop and answer now' "$ISSUE_WAVE_STATE/workers/wr/stream.jsonl" && ok "...the queued message had its own turn" || ko "queued message lost across the resume"
settle wr
# A feeder whose pid cannot be recorded could never be closed: the worker stops before its CLI.
mkdir "$ISSUE_WAVE_STATE/workers/wr/feeder.pid"
"$FW" unstick testbox wr --message "$TMP/msg.md" >/dev/null
expect "an unwritable feeder pid file stops the worker before the CLI starts" 1 "FAILED testbox/wr exit=95" -- "$FW" attach testbox wr --interval 1
rmdir "$ISSUE_WAVE_STATE/workers/wr/feeder.pid"

printf 'SLEEP 60\n' > "$TMP/slow.md"
"$FW" launch testbox a.b --target-repo example/project --kind claude --brief "$TMP/slow.md" --cwd "$proj" >/dev/null; sleep 1
expect "a dotted name is killed by a literal match, not a regex" 0 "RESUMED testbox/a.b" -- "$FW" unstick testbox a.b --message "$TMP/msg.md" --kill
# tmux turns a `.` in a session name into `_`: the session must still be found by the worker's name.
expect "...and its session is found by its own name, not read as an orphan" 0 "^\(RUNNING\|IDLE\) testbox/a.b " -- "$FW" status testbox a.b
settle a.b
mkdir -p "$TMP/nouuid"; printf '#!/bin/sh\nexit 1\n' > "$TMP/nouuid/uuidgen"; chmod +x "$TMP/nouuid/uuidgen"
expect "no uuidgen: a fallback still yields a session id" 0 "LAUNCHED testbox/nu kind=claude session=[0-9a-f-]\{36\}" -- \
  env PATH="$TMP/nouuid:$PATH" "$FW" launch testbox nu --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
settle nu

"$FW" launch testbox wo --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" >/dev/null; settle wo
bash -c 'sleep 30; :' claude "$ISSUE_WAVE_STATE/workers/wo/" >/dev/null 2>&1 & orphan=$!; disown; sleep 0.5
expect "an orphaned CLI (tmux gone) refuses a plain unstick" 1 "tmux is gone but a CLI still runs" -- "$FW" unstick testbox wo --message "$TMP/msg.md"
kill -0 "$orphan" 2>/dev/null && ok "the orphan was not killed by the refused unstick" || ko "plain unstick killed the orphan"
expect "unstick --kill terminates the orphan and resumes" 0 "RESUMED testbox/wo" -- "$FW" unstick testbox wo --message "$TMP/msg.md" --kill
kill -0 "$orphan" 2>/dev/null && ko "orphan survived --kill" || ok "--kill terminated the orphan"
settle wo
mv "$ISSUE_WAVE_STATE/workers/wo/run.sh" "$TMP/run.saved"; mkdir "$ISSUE_WAVE_STATE/workers/wo/run.sh"
expect "unstick refuses when the resume script cannot be written" 1 "UNSTICK REFUSED testbox/wo: cannot write .*run.sh" -- "$FW" unstick testbox wo --message "$TMP/msg.md"
[ -f "$ISSUE_WAVE_STATE/workers/wo/exit" ] && ok "a refused unstick keeps the previous exit record" || ko "refused unstick destroyed the exit record"
rmdir "$ISSUE_WAVE_STATE/workers/wo/run.sh"; mv "$TMP/run.saved" "$ISSUE_WAVE_STATE/workers/wo/run.sh"
bash -c 'sleep 3; :' tail -f "$ISSUE_WAVE_STATE/workers/wo/stream.jsonl" >/dev/null 2>&1 & disown; sleep 0.5
expect "a diagnostic process on the record does not block a plain unstick" 0 "RESUMED testbox/wo" -- "$FW" unstick testbox wo --message "$TMP/msg.md"
settle wo
cp "$ISSUE_WAVE_STATE/workers/wo/meta" "$TMP/meta.before"; cp "$ISSUE_WAVE_STATE/workers/wo/input.jsonl" "$TMP/input.before"
expect "a tmux failure during unstick restores exit and meta" 1 "tmux failed (previous exit record and meta kept)" -- env SHIM_TMUX_FAIL_NEW=1 "$FW" unstick testbox wo --message "$TMP/msg.md"
cmp -s "$ISSUE_WAVE_STATE/workers/wo/meta" "$TMP/meta.before" && [ -f "$ISSUE_WAVE_STATE/workers/wo/exit" ] && ok "meta and exit are as before the failed resume" || ko "meta or exit changed by a failed resume"
cmp -s "$ISSUE_WAVE_STATE/workers/wo/input.jsonl" "$TMP/input.before" && ok "...and the input channel takes the undelivered message back" || ko "input.jsonl changed by a failed resume: $(cat "$ISSUE_WAVE_STATE/workers/wo/input.jsonl")"
# A resume creates a tmux session with no preflight in front of it, so it runs the stale-server
# check itself (ludics-lite#327), before it touches the record.
printf 'PATH=%s\nROCM_PATH=/usr\n' "$PATH" > "$TMP/genv-stale"
expect "a resume refuses against a stale tmux server" 1 "UNSTICK REFUSED testbox/wo: stale tmux server environment (ROCM_PATH is /usr in the server but unset in a fresh shell)" -- \
  env -u ROCM_PATH -u HIP_PATH -u OPAM_SWITCH_PREFIX SHIM_TMUX_GENV="$TMP/genv-stale" "$FW" unstick testbox wo --message "$TMP/msg.md"
cmp -s "$ISSUE_WAVE_STATE/workers/wo/meta" "$TMP/meta.before" && [ -f "$ISSUE_WAVE_STATE/workers/wo/exit" ] && ok "a resume refused over a stale server leaves meta and exit as they were" || ko "meta or exit changed by a stale-server refusal"
expect "...and the worker still reads as its previous successful turn" 0 "DONE testbox/wo exit=0" -- "$FW" attach testbox wo --interval 1
echo 99 > "$ISSUE_WAVE_STATE/workers/wo/exit.prev"; echo "kind=stale" > "$ISSUE_WAVE_STATE/workers/wo/meta.prev"; cp "$ISSUE_WAVE_STATE/workers/wo/meta" "$TMP/wo.meta"
mv "$proj" "$proj.moved"
expect "unstick refuses when the recorded worktree is gone, before touching the record" 1 "recorded working directory .* is gone" -- "$FW" unstick testbox wo --message "$TMP/msg.md"
[ -f "$ISSUE_WAVE_STATE/workers/wo/exit" ] && [ "$(cat "$ISSUE_WAVE_STATE/workers/wo/exit")" = 0 ] && cmp -s "$ISSUE_WAVE_STATE/workers/wo/meta" "$TMP/wo.meta" && ok "the exit record survived and stale .prev files were not restored over it" || ko "exit/meta changed by the refused unstick: $(cat "$ISSUE_WAVE_STATE/workers/wo/exit")"
rm -f "$ISSUE_WAVE_STATE/workers/wo/exit.prev" "$ISSUE_WAVE_STATE/workers/wo/meta.prev"
mv "$proj.moved" "$proj"
expect "a non-holder cannot unstick" 1 "UNSTICK REFUSED testbox/wo: coordinator lease held by" -- env FLEET_COORDINATOR=other-session "$FW" unstick testbox wo --message "$TMP/msg.md"

printf 'SLEEP 5\n' > "$TMP/slow5.md"
"$FW" launch testbox dup --target-repo example/project --kind claude --brief "$TMP/slow5.md" --cwd "$proj" >"$TMP/dup-a.out" 2>&1 & da=$!
"$FW" launch testbox dup --target-repo example/project --kind claude --brief "$TMP/slow5.md" --cwd "$proj" >"$TMP/dup-b.out" 2>&1 & db=$!
wait "$da" "$db"
launched=$(cat "$TMP/dup-a.out" "$TMP/dup-b.out" | grep -c '^LAUNCHED testbox/dup')
[ "$launched" -eq 1 ] && ok "two overlapping launches of one name: exactly one LAUNCHED" || ko "overlapping launches: $launched LAUNCHED -- $(cat "$TMP/dup-a.out" "$TMP/dup-b.out")"
# Three guards can refuse the loser, depending on where the winner is when the loser arrives: the
# name lock, the liveness guard, or -- once the winner has published its record and its CLI is up --
# the worktree ownership check. Each is a refusal; which one fires is timing.
grep -q 'another launch of this name is in progress\|already running\|already owned by live worker' "$TMP/dup-a.out" "$TMP/dup-b.out" && ok "the other was refused by the lock, the liveness guard or ownership" || ko "no refusal for the overlapping launch -- $(cat "$TMP/dup-a.out" "$TMP/dup-b.out")"
[ -d "$ISSUE_WAVE_STATE/locks/dup" ] && ko "launch lock left behind" || ok "launch lock released"
settle dup   # dup shares $proj; a live owner would refuse q
mkdir -p "$ISSUE_WAVE_STATE/locks/q"; echo 999999 > "$ISSUE_WAVE_STATE/locks/q/pid"
expect "a lock left by a dead holder is reclaimed" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
settle q
mkdir -p "$ISSUE_WAVE_STATE/locks/q"
expect "a fresh ownerless lock (registration in progress) still refuses" 1 "another launch or unstick of this name is in progress" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
touch -t 202001010000 "$ISSUE_WAVE_STATE/locks/q"
expect "an old ownerless lock (shell died before the pid write) is reclaimed" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
settle q
mkdir -p "$ISSUE_WAVE_STATE/locks/q"; echo $$ > "$ISSUE_WAVE_STATE/locks/q/pid"; echo "bogus start" > "$ISSUE_WAVE_STATE/locks/q/start"
expect "a lock whose pid is live but whose start time differs (pid reuse) is reclaimed" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
settle q
mkdir -p "$ISSUE_WAVE_STATE/locks/q"; echo $$ > "$ISSUE_WAVE_STATE/locks/q/pid"; ps -o lstart= -p $$ | tr -s ' ' > "$ISSUE_WAVE_STATE/locks/q/start"
expect "a lock held by a live process still refuses" 1 "another launch or unstick of this name is in progress" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
rm -rf "$ISSUE_WAVE_STATE/locks/q"
"$FW" launch testbox q.mutating --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" >/dev/null; settle q.mutating
expect "a worker named like a lock suffix does not block its sibling" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
settle q
settle dup
"$FW" unstick testbox dup --message "$TMP/msg.md" >"$TMP/un-a.out" 2>&1 & ua=$!
"$FW" unstick testbox dup --message "$TMP/msg.md" >"$TMP/un-b.out" 2>&1 & ub=$!
wait "$ua" "$ub"
resumed=$(cat "$TMP/un-a.out" "$TMP/un-b.out" | grep -c '^RESUMED testbox/dup')
# The other one either met the name lock, or came after the resume and appended to its process.
other=$(cat "$TMP/un-a.out" "$TMP/un-b.out" | grep -c '^APPENDED testbox/dup\|another launch or unstick of this name is in progress')
[ "$resumed" -eq 1 ] && [ "$other" -eq 1 ] && ok "two overlapping unsticks of one ended worker: exactly one RESUMED, the other locked out or appended" || ko "overlapping unsticks: $resumed RESUMED -- $(cat "$TMP/un-a.out" "$TMP/un-b.out")"
settle dup
bash -c 'sleep 3; :' tail -f "$ISSUE_WAVE_STATE/workers/dup/stream.jsonl" >/dev/null 2>&1 & disown; sleep 0.5
expect "a diagnostic process on a record file is not the worker" 0 "EXITED(0) testbox/dup" -- "$FW" status testbox dup
rm -rf "$ISSUE_WAVE_STATE/incoming"; : > "$ISSUE_WAVE_STATE/incoming"
expect "a brief that cannot be staged is a refusal, not an unreachable box" 1 "LAUNCH REFUSED testbox/blocked: cannot stage the brief" -- "$FW" launch testbox blocked --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
rm -f "$ISSUE_WAVE_STATE/incoming"
: > "$ISSUE_WAVE_STATE/workers/blocked"
expect "a record directory that cannot be created is a refusal naming it" 1 "LAUNCH REFUSED testbox/blocked: cannot create the worker record" -- "$FW" launch testbox blocked --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
rm -f "$ISSUE_WAVE_STATE/workers/blocked"

printf 'SLEEP 20\n' > "$TMP/slow20.md"
"$FW" launch testbox own-a --target-repo example/project --kind claude --brief "$TMP/slow20.md" --cwd "$proj" >/dev/null; sleep 1
expect "a second worker on a worktree a live worker owns is refused" 1 "already owned by live worker own-a" -- "$FW" launch testbox own-b --target-repo example/project --kind claude --brief "$brief" --cwd "$proj/"
"$FW" unstick testbox own-a --message "$TMP/msg.md" --kill >/dev/null; settle own-a
expect "...and allowed once that worker has finished" 0 "LAUNCHED testbox/own-b" -- "$FW" launch testbox own-b --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
settle own-b
"$FW" launch testbox race-x --target-repo example/project --kind claude --brief "$TMP/slow5.md" --cwd "$proj" >"$TMP/rx.out" 2>&1 & rx=$!
"$FW" launch testbox race-y --target-repo example/project --kind claude --brief "$TMP/slow5.md" --cwd "$proj" >"$TMP/ry.out" 2>&1 & ry=$!
wait "$rx" "$ry"
n=$(cat "$TMP/rx.out" "$TMP/ry.out" | grep -c '^LAUNCHED ')
[ "$n" -eq 1 ] && ok "two concurrent launches under different names on one worktree: exactly one LAUNCHED" || ko "worktree race: $n LAUNCHED -- $(cat "$TMP/rx.out" "$TMP/ry.out")"
grep -q 'already owned by live worker' "$TMP/rx.out" "$TMP/ry.out" && ok "the other was refused by ownership" || ko "no ownership refusal: $(cat "$TMP/rx.out" "$TMP/ry.out")"
[ -d "$ISSUE_WAVE_STATE/launch.lock" ] && ko "box-wide launch lock left behind" || ok "box-wide launch lock released"
for w in race-x race-y; do "$FW" unstick testbox $w --message "$TMP/msg.md" --kill >/dev/null 2>&1; settle $w; done
"$FW" launch testbox hold --target-repo example/project --kind claude --brief "$TMP/slow20.md" --cwd "$proj" >/dev/null; sleep 1
expect "unstick refuses to resume into a worktree another live worker now owns" 1 "UNSTICK REFUSED testbox/own-b: worktree .* is now owned by live worker hold" -- "$FW" unstick testbox own-b --message "$TMP/msg.md"
"$FW" unstick testbox hold --message "$TMP/msg.md" --kill >/dev/null; settle hold
"$FW" launch testbox p-1 --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" >/dev/null; settle p-1
"$FW" launch testbox p-12 --target-repo example/project --kind claude --brief "$TMP/slow20.md" --cwd "$proj-worktrees/w1" >/dev/null; sleep 1   # its own worktree: ownership is not what this case tests
expect "a finished worker is not read as running through a prefix-matching sibling session" 0 "EXITED(0) testbox/p-1 " -- "$FW" status testbox p-1
expect "unstick --kill of the finished worker leaves the sibling session alone" 0 "RESUMED testbox/p-1" -- "$FW" unstick testbox p-1 --message "$TMP/msg.md" --kill
expect "...the sibling is still running" 0 "RUNNING testbox/p-12" -- "$FW" status testbox p-12
settle p-1
"$FW" unstick testbox p-12 --message "$TMP/msg.md" --kill >/dev/null; settle p-12
expect "a first launch whose tmux fails leaves no record behind" 1 "LAUNCH REFUSED testbox/tf: tmux failed" -- env SHIM_TMUX_FAIL_NEW=1 "$FW" launch testbox tf --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
[ -d "$ISSUE_WAVE_STATE/workers/tf" ] && ko "failed first launch left a record" || ok "no record left by the failed first launch"
expect "...so the name launches normally afterwards" 0 "LAUNCHED testbox/tf" -- "$FW" launch testbox tf --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
settle tf
expect "a --replace whose tmux fails restores the previous record" 1 "tmux failed (previous record restored)" -- env SHIM_TMUX_FAIL_NEW=1 "$FW" launch testbox tf --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
expect "...and the previous worker still reads as done" 0 "EXITED(0) testbox/tf" -- "$FW" status testbox tf
expect "a stalling project fetch is bounded and refused before any record is touched" 1 "git fetch in .* timed out after 2s" -- \
  env SHIM_GIT_HANG_FETCH=1 FLEET_FETCH_TIMEOUT=2 "$FW" launch testbox fh --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/fh
[ -d "$ISSUE_WAVE_STATE/workers/fh" ] && ko "a refused fetch left a record" || ok "no record left by the refused fetch"
grep -q '^fh-' <<<"$(ls "$ISSUE_WAVE_STATE/incoming/" 2>/dev/null)" && ko "a refused fetch left a staged brief" || ok "no staged brief left by the refused fetch"
}

section "codex workers" && {
need_lease
expect "codex launch captures the thread id from the stream" 0 "LAUNCHED testbox/c1 kind=codex session=0199-shim-" -- \
  "$FW" launch testbox c1 --target-repo example/project --kind codex --brief "$brief" --cwd "$proj"
grep -qF -- "codex exec --json --yolo -C $(printf '%q' "$proj") -o " "$ISSUE_WAVE_STATE/workers/c1/run.sh" && grep -qF -- "last-message.md - < " "$ISSUE_WAVE_STATE/workers/c1/run.sh" && ok "codex command shape (brief on stdin, -o last message)" || ko "codex command: $(cat "$ISSUE_WAVE_STATE/workers/c1/run.sh")"
expect "codex attach reads turn.completed and the last message" 0 "DONE testbox/c1 exit=0 turn.completed .*codex did: Fix issue" -- "$FW" attach testbox c1 --interval 1
expect "codex log prints agent messages" 0 "codex did: Fix issue" -- "$FW" log testbox c1
printf '{"type":"item.completed","item":{"type":"agent_mes' >> "$ISSUE_WAVE_STATE/workers/c1/stream.jsonl"; printf '\n{"type":"item.completed","item":{"type":"agent_message","text":"after the damage"}}\n' >> "$ISSUE_WAVE_STATE/workers/c1/stream.jsonl"
expect "a truncated JSONL line does not hide the events after it" 0 "after the damage" -- "$FW" log testbox c1
sed -i.bak '/^session=/d' "$ISSUE_WAVE_STATE/workers/c1/meta" && rm -f "$ISSUE_WAVE_STATE/workers/c1/meta.bak"
expect "status recovers the thread id from the stream when meta lacks it" 0 "session=0199-shim-" -- "$FW" status testbox c1
expect "codex unstick resumes by thread id (from the stream) with --yolo" 0 "RESUMED testbox/c1 kind=codex session=0199-shim-" -- "$FW" unstick testbox c1 --message "$TMP/msg.md"
tid=$(sed -n '/^session=/ { s/^session=//; p; q; }' "$ISSUE_WAVE_STATE/workers/c1/meta")
grep -q -- "codex exec resume $tid --yolo --json -" "$ISSUE_WAVE_STATE/workers/c1/run.sh" && ok "codex resume command shape" || ko "codex resume: $(cat "$ISSUE_WAVE_STATE/workers/c1/run.sh")"
settle c1
expect "a resumed turn that emits nothing is FAILED even though the first turn succeeded" 1 "FAILED testbox/c1 exit=0 no terminal event" -- \
  env SHIM_CODEX_SILENT_RESUME=1 bash -c '"$0" unstick testbox c1 --message "$1" && "$0" attach testbox c1 --interval 1' "$FW" "$TMP/msg.md"
"$FW" unstick testbox c1 --message "$TMP/msg.md" >/dev/null
expect "the resumed codex turn's verdict carries the NEW message, from the stream" 0 "DONE testbox/c1 exit=0 turn.completed .*| codex did: Stop and answer now" -- "$FW" attach testbox c1 --interval 1
printf 'Watch armed; it wakes me later\n' > "$TMP/cstrand.md"
"$FW" launch testbox cst --target-repo example/project --kind codex --brief "$TMP/cstrand.md" --cwd "$proj" >/dev/null
expect "a codex turn's last agent message is read for the strand mark too" 0 \
  'DONE testbox/cst exit=0 turn.completed .* | PROBABLE STRAND: the final message says "wakes me"' -- "$FW" attach testbox cst --interval 1
}

section "halt" && {
need_lease
mkdir -p "$ISSUE_WAVE_STATE/HALT"
expect "halt that cannot write its marker fails loudly" 1 "HALT FAILED: cannot write" -- "$FW" halt "unwritable"
rmdir "$ISSUE_WAVE_STATE/HALT"
expect "native gate accepts the lease holder" 0 "" -- "$FW" gate --target-repo example/project
expect "native gate refuses another coordinator" 1 "coordinator lease held" -- "${B[@]}" gate --target-repo example/project
expect "native gate rejects unknown flags" 2 "gate: expected" -- "$FW" gate --target-repo example/project --oops
expect "halted reports open" 0 "launches open" -- "$FW" halted
expect "halt records the reason" 0 "HALTED: launches refused" -- "$FW" halt "master red at abc123, owner: coordinator"
expect "halted reports the reason, exit 1" 1 "HALTED .*master red at abc123" -- "$FW" halted
expect "native gate refuses while halted" 1 "launches halted" -- "$FW" gate --target-repo example/project
expect "native triage gate allows the holder during halt" 0 "" -- "$FW" gate --target-repo example/project --force
expect "native triage gate still refuses a non-holder" 1 "coordinator lease held" -- "${B[@]}" gate --target-repo example/project --force
expect "launch refuses while halted" 1 "LAUNCH REFUSED testbox/h1: launches halted -- .*master red" -- "$FW" launch testbox h1 --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
expect "--force launches anyway (the triage worker)" 0 "LAUNCHED testbox/h1" -- "$FW" launch testbox h1 --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --force
settle h1
expect "resume-launches clears it" 0 "RESUMED launches" -- "$FW" resume-launches
expect "launch works again" 0 "LAUNCHED testbox/h2" -- "$FW" launch testbox h2 --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
settle h2
"$FW" halt "adopted mid-halt" >/dev/null
"${B[@]}" claim --take >/dev/null
expect "a coordinator adopting the lease inherits the halt" 1 "LAUNCH REFUSED testbox/h3: launches halted -- .*adopted mid-halt" -- \
  "${B[@]}" launch testbox h3 --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
expect "...and reads it with halted" 1 "HALTED .*adopted mid-halt" -- "${B[@]}" halted
"$FW" claim --take >/dev/null; "$FW" resume-launches >/dev/null
}

section "execution run and conclude --from-run" && {
need_lease
# A finished test-run.sh record on the local box: `exit`, `log`, `wt`, `cmd` under a
# timestamped directory, with the checkout it ran in and that checkout's own runner shim
# (`tools/test-run.sh status <run>` is the authority on "published, nothing left running").
runs="$TMP/test-runs"; wt="$TMP/run-wt"
git clone -q "$TMP/proj.git" "$wt" && mkdir -p "$wt/tools"
cat > "$wt/tools/test-run.sh" <<'EOF'
#!/usr/bin/env bash
[ "$1" = status ] || exit 2
exit "${SHIM_RUN_STATUS:-0}"
EOF
chmod +x "$wt/tools/test-run.sh"
ran=$(git -C "$wt" rev-parse HEAD)
mkrun() { # <name> <exit or ->
  local d="$runs/$1"; mkdir -p "$d"; printf 'build @scans\n' > "$d/cmd"; printf '%s\n' "$wt" > "$d/wt"
  printf 'exit: %s\n' "$2" > "$d/log"; [ "$2" = - ] || printf '%s\n' "$2" > "$d/exit"
}
mkrun 20260915T201414Z-1 0; mkrun 20260915T201414Z-2 -; mkrun 20260915T201414Z-3 142; mkrun 20260915T201414Z-4 1; mkrun 20260915T201414Z-5 0
reqjson() { # <id> [host] -> a reservation payload file
  jq -n --arg id "$1" --arg host "${2:-testbox}" '{request_id:$id, wave:"w", worker:$id, transport:"subagent", issue:"o/r#1", purpose:"fixture",
    agent_host:"testbox", execution_host:$host, repository:"o/r", requested_revision:"origin/master", kind:"correctness"}' > "$TMP/$1.json"
  printf '%s' "$TMP/$1.json"
}
FWX=(env FLEET_BOXES="testbox other" "$FW")
run1="$runs/20260915T201414Z-1"
expect "execution run reserves and dispatches in one call" 0 '"state": "launching"' -- "${FWX[@]}" execution run "$(reqjson run-a)"
expect "a second run of the same request is refused, never re-launched" 1 "already dispatched" -- "${FWX[@]}" execution run "$(reqjson run-a)"
expect "conclude --from-run needs an absolute run directory" 2 "must be absolute" -- "${FWX[@]}" execution conclude --from-run runs/x --request run-a --sha "$ran"
expect "conclude --from-run needs the request id" 2 "--request <id> required" -- "${FWX[@]}" execution conclude --from-run "$run1" --sha "$ran"
expect "conclude --from-run needs the revision that ran (the record has none)" 2 "--sha <full commit SHA> required" -- "${FWX[@]}" execution conclude --from-run "$run1" --request run-a
expect "conclude --from-run refuses a stray flag" 2 "conclude --from-run <run-dir>" -- "${FWX[@]}" execution conclude --from-run "$run1" --request run-a --sha "$ran" --oops
expect "conclude --from-run refuses a short --sha" 2 "full commit SHA" -- "${FWX[@]}" execution conclude --from-run "$run1" --request run-a --sha abc
expect "a record without a verdict file is refused" 1 "FROM-RUN REFUSED: .*has no exit" -- "${FWX[@]}" execution conclude --from-run "$runs/20260915T201414Z-2" --request run-a --sha "$ran"
expect "a missing run directory is refused" 1 "FROM-RUN REFUSED: no run directory" -- "${FWX[@]}" execution conclude --from-run "$runs/nope" --request run-a --sha "$ran"
expect "the checkout's runner saying 'still running' refuses" 1 "not a finished run" -- env SHIM_RUN_STATUS=3 "${FWX[@]}" execution conclude --from-run "$run1" --request run-a --sha "$ran"
expect "a revision the checkout does not contain is refused" 1 "does not contain the reported revision" -- "${FWX[@]}" execution conclude --from-run "$run1" --request run-a --sha "$(printf 'a%.0s' $(seq 40))"
"${FWX[@]}" execution run "$(reqjson run-other other)" >/dev/null
expect "evidence read on a box other than the reserved one is refused by the registry" 1 "evidence from testbox cannot conclude an assignment reserved on other" -- \
  "${FWX[@]}" execution conclude --from-run "$run1" --request run-other --sha "$ran" --box testbox
"$FW" execution list | grep -c '"state": "launching"' | grep -qx 2 && ok "every refusal left the assignments dispatched, not concluded" || ko "a refusal changed a record"
expect "a passed run concludes with its verdict, log, checkout, handle and revision, on the reserved box by default" 0 '"verdict": "pass"' -- "${FWX[@]}" execution conclude --from-run "$run1" --request run-a --sha "$ran"
for want in "\"observed_sha\": \"$ran\"" "\"remote_checkout\": \"$wt\"" "\"handle\": \"test-run:20260915T201414Z-1\"" "\"log\": \"$run1/log\"" "exit 0 published"; do
  grep -Fq -- "$want" <<<"$out" && ok "...recorded $want" || ko "missing $want in $out"
done
jq -e '.history[-1].data | has("execution_host") | not' <<<"$out" >/dev/null && ok "...and the box check left no field behind" || ko "the box bound to the evidence leaked into the record: $out"
run_conclude() { local id="$1" dir="$2"; shift 2; "${FWX[@]}" execution run "$(reqjson "$id")" >/dev/null && "${FWX[@]}" execution conclude --from-run "$dir" --request "$id" --sha "$ran" "$@"; }
expect "a capped run concludes as timeout" 0 '"verdict": "timeout"' -- run_conclude run-b "$runs/20260915T201414Z-3"
expect "a red run concludes as fail, with the given evidence" 0 '"evidence": "sweep red on scans"' -- run_conclude run-c "$runs/20260915T201414Z-4" --evidence "sweep red on scans"
grep -q '"verdict": "fail"' <<<"$out" && ok "...as fail" || ko "exit 1 did not read as fail: $out"
expect "conclude --from-run on an unknown request is refused before any box is read" 1 "unknown request_id run-zz" -- "${FWX[@]}" execution conclude --from-run "$run1" --request run-zz --sha "$ran"
# A checkout that moved on after the run still concludes on the reported revision, and says so.
git -C "$wt" commit -q --allow-empty -m moved   # a guaranteed new head, whatever the clone holds
expect "a moved checkout concludes on the reported revision and records the drift" 0 "checkout head is now $(git -C "$wt" rev-parse HEAD), revision $ran as reported" -- run_conclude run-d "$runs/20260915T201414Z-5"
grep -Fq "\"observed_sha\": \"$ran\"" <<<"$out" && ok "...with the reported revision as observed_sha" || ko "wrong observed_sha: $out"
jq -n '{request_id:"run-other", verdict:"not-launched", log:"/dev/null", evidence:"fixture never invoked a runner on other"}' > "$TMP/run-other-done.json"
"${FWX[@]}" execution conclude "$TMP/run-other-done.json" >/dev/null || ko "could not conclude the off-box fixture (setup)"
expect "a run of a request outside the roster is refused" 1 "canonical FLEET_BOXES" -- "$FW" execution run "$(reqjson run-e)"
}

section "execution conclude --from-bg-run" && {
need_lease
# ludics-lite#405: runs that are not test-run.sh records -- a machine-verify trip, a measurement
# script -- block under bg-run.sh, whose directory (`rc`, `log`, `refused`, `pid`/`cpid`) is read
# here through bg-run.sh's own `wait --within 0`. Each directory below is a real bg-run.sh run
# (`start` returns when the command does), except the ones whose state has to be staged: a live
# task, a killed one, one never started.
BG="$TMP/dispatcher/issue-wave/scripts/bg-run.sh"
bgdir() { # <name> <command...>: a finished bg-run.sh directory, its path on stdout
  local d="$TMP/bg runs/$1"; shift
  bash "$BG" start "$d" -- "$@" >/dev/null 2>&1
  printf '%s' "$d"
}
bgreq() { # <id> -> a dispatched reservation on testbox
  jq -n --arg id "$1" '{request_id:$id, wave:"w", worker:$id, transport:"subagent", issue:"o/r#405", purpose:"bg-run fixture",
    agent_host:"testbox", execution_host:"testbox", repository:"o/r", requested_revision:"origin/main", kind:"correctness"}' > "$TMP/$1.json"
  "${FWB[@]}" execution run "$TMP/$1.json" >/dev/null 2>&1 || ko "could not dispatch $1 (setup)"
}
FWB=(env FLEET_BOXES="testbox other" SHIM_SSH_LOCAL=other "$FW")
sha=$(printf 'b%.0s' $(seq 40))
bgdone() { # <id>: conclude it, so testbox's one slot is free for the next case
  jq -n --arg id "$1" '{request_id:$id, verdict:"not-launched", log:"/dev/null", evidence:"bg-run fixture: nothing ran"}' > "$TMP/$1-done.json"
  "${FWB[@]}" execution conclude "$TMP/$1-done.json" >/dev/null || ko "could not conclude $1 (setup)"
}
bgc() { # <id> <dir> [flags...]: dispatch <id>, then conclude it from <dir>
  local id="$1" dir="$2"; shift 2
  bgreq "$id" && "${FWB[@]}" execution conclude --from-bg-run "$dir" --request "$id" --sha "$sha" "$@"
}
ok_dir=$(bgdir pass sh -c 'echo building; echo "exit: 1 (a test named exit)"; echo "x: ssh exit: 5"')
expect "a bg-run that returned 0 concludes as pass" 0 '"verdict": "pass"' -- bgc bg-pass "$ok_dir"
for want in "\"observed_sha\": \"$sha\"" "\"handle\": \"bg-run:testbox:$ok_dir\"" "\"log\": \"testbox:$ok_dir/log\"" \
  "rc=0; the command returned; revision $sha as reported by the worker" "\"remote_checkout\": \"not recorded (bg-run keeps no checkout"; do
  grep -Fq -- "$want" <<<"$out" && ok "...recorded $want" || ko "missing $want in $out"
done
grep -q "runner sentinel" <<<"$out" && ko "a line outside the sentinel grammar was read as one: $out" || ok "...reading neither a sentinel with trailing text nor a transport line as the runner's"
expect "a retry of that conclusion (its answer lost) composes the same payload, which the registry takes as a harmless retry" 0 '"state": "concluded"' -- \
  "${FWB[@]}" execution conclude --from-bg-run "$ok_dir" --request bg-pass --sha "$sha"
expect "the runner's nonzero sentinel wins over a 0 rc: fail" 0 "runner sentinel 'runner: exit: 1'" -- bgc bg-sent1 "$(bgdir sent1 sh -c 'echo "runner: exit: 1"; echo tail output')"
grep -q '"verdict": "fail"' <<<"$out" && ok "...as fail" || ko "a failing sentinel under rc 0 did not read as fail: $out"
expect "a zero sentinel does not rescue a nonzero rc: fail" 0 '"verdict": "fail"' -- bgc bg-sent0 "$(bgdir sent0 sh -c 'echo "exit: 0"; exit 1')"
expect "the LAST sentinel is the runner's: a cap is timeout" 0 '"verdict": "timeout"' -- bgc bg-cap "$(bgdir cap sh -c 'echo "exit: 1"; echo "machine-verify: exit: 142"; echo "machine-verify: ssh exit: 142"; exit 142')"
expect "rc 124 (timeout(1)) concludes as timeout" 0 '"verdict": "timeout"' -- bgc bg-124 "$(bgdir t124 sh -c 'exit 124')"
expect "a signal death concludes as cancelled" 0 '"verdict": "cancelled"' -- bgc bg-term "$(bgdir term sh -c 'kill -TERM $$')"
expect "any other status concludes as fail, with the given evidence and checkout" 0 '"evidence": "sweep red"' -- \
  bgc bg-fail "$(bgdir fail sh -c 'exit 3')" --evidence "sweep red" --checkout "testbox:/w/verify (removed)"
grep -q '"verdict": "fail"' <<<"$out" && grep -Fq '"remote_checkout": "testbox:/w/verify (removed)"' <<<"$out" && ok "...as fail, naming the checkout given" || ko "exit 3 or --checkout misread: $out"
# The box that drove the run over ssh holds the directory; the conclusion names it.
expect "a directory read on the box that drove the run concludes, naming that box" 0 "read on other, which drove the run on testbox" -- bgc bg-drove "$ok_dir" --box other
grep -Fq "\"log\": \"other:$ok_dir/log\"" <<<"$out" && ok "...in the log it cites" || ko "the driving box is missing from the log: $out"
# A checkout already on the record is kept when --checkout is absent, and replaced when it is given.
bgreq bg-rec && jq -n '{request_id:"bg-rec", state:"running", evidence:"fixture", remote_checkout:"/rec/wt"}' > "$TMP/bg-rec-rec.json" &&
  "${FWB[@]}" execution record "$TMP/bg-rec-rec.json" >/dev/null || ko "could not record bg-rec's checkout (setup)"
expect "a checkout the record already carries is kept" 0 '"remote_checkout": "/rec/wt"' -- "${FWB[@]}" execution conclude --from-bg-run "$ok_dir" --request bg-rec --sha "$sha"
bgreq bg-rec2 && jq -n '{request_id:"bg-rec2", state:"running", evidence:"fixture", remote_checkout:"/rec/wt"}' > "$TMP/bg-rec2-rec.json" &&
  "${FWB[@]}" execution record "$TMP/bg-rec2-rec.json" >/dev/null || ko "could not record bg-rec2's checkout (setup)"
expect "...and an explicit --checkout replaces it" 0 '"remote_checkout": "/named/wt"' -- "${FWB[@]}" execution conclude --from-bg-run "$ok_dir" --request bg-rec2 --sha "$sha" --checkout /named/wt
# Staged states: bg-run.sh's own verdicts, never re-derived here.
d="$TMP/bg runs/died"; mkdir -p "$d"; sh -c 'exit 0' & gone=$!; wait "$gone"; printf '%s\n\n' "$gone" > "$d/pid"; : > "$d/log"
expect "a task killed before the command returned (DIED) is refused, never concluded" 1 "FROM-BG-RUN REFUSED: bg-run.sh wait: DIED" -- bgc bg-died "$d"
bgdone bg-died
d="$TMP/bg runs/live"; mkdir -p "$d"; printf '%s\n\n' "$$" > "$d/pid"
expect "a live task (RUNNING) is refused" 1 "FROM-BG-RUN REFUSED: bg-run.sh wait: RUNNING" -- bgc bg-live "$d"
d="$TMP/bg runs/never"; mkdir -p "$d"
expect "a directory no task claimed (STARTING) is refused" 1 "FROM-BG-RUN REFUSED: bg-run.sh wait: STARTING" -- "${FWB[@]}" execution conclude --from-bg-run "$d" --request bg-live --sha "$sha"
d=$(bgdir reused true); bash "$BG" start "$d" -- false >/dev/null 2>&1
expect "a directory a second start refused is refused, its rc unread" 1 "an rc there may be an earlier run's" -- "${FWB[@]}" execution conclude --from-bg-run "$d" --request bg-live --sha "$sha"
expect "a missing directory is refused" 1 "FROM-BG-RUN REFUSED: no run directory" -- "${FWB[@]}" execution conclude --from-bg-run "$TMP/bg runs/nope" --request bg-live --sha "$sha"
expect "an unknown request is refused before any box is read" 1 "unknown request_id bg-zz" -- "${FWB[@]}" execution conclude --from-bg-run "$ok_dir" --request bg-zz --sha "$sha"
expect "--from-bg-run needs an absolute directory" 2 "must be absolute" -- "${FWB[@]}" execution conclude --from-bg-run bg/x --request bg-live --sha "$sha"
expect "--from-bg-run needs the request id" 2 "--request <id> required" -- "${FWB[@]}" execution conclude --from-bg-run "$ok_dir" --sha "$sha"
expect "--from-bg-run needs the revision that ran" 2 "--sha <full commit SHA> required" -- "${FWB[@]}" execution conclude --from-bg-run "$ok_dir" --request bg-live
expect "--from-bg-run refuses a stray flag" 2 "conclude --from-bg-run <run-dir>" -- "${FWB[@]}" execution conclude --from-bg-run "$ok_dir" --request bg-live --sha "$sha" --oops
"$FW" execution list | jq -e '[.[] | select(.request_id == "bg-live") | .state] == ["launching"]' >/dev/null && ok "every refusal left the assignment dispatched" || ko "a refusal changed bg-live"
bgdone bg-live
}

section "prs (the supervision read)" && {
# ludics-lite#405: one line per open PR, from ship-pr's pr-review.sh (stubbed: SHIM_PRS).
P="$TMP/prs"; mkdir -p "$P"; export SHIM_PRS="$P"
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n --arg now "$now" '[
  {number: 12, title: "second\tPR", headRefName: "claude/issue-12", headRefOid: "c12", createdAt: "2026-09-01T00:00:00Z", isDraft: true,
   closingIssuesReferences: [{number: 12, repository: {name: "r", owner: {login: "o"}}}]},
  {number: 7, title: "first PR", headRefName: "claude/issue-7", headRefOid: "c7", createdAt: $now, isDraft: false,
   closingIssuesReferences: [{number: 7, repository: {name: "other", owner: {login: "o"}}}]},
  {number: 9, title: "", headRefName: "claude/issue-9", headRefOid: "c9", createdAt: $now, isDraft: false, closingIssuesReferences: []}]' > "$P/list.json"
echo 6 > "$P/rounds-12"; echo 2 > "$P/rounds-7"
printf '0\ngreen — 3 build checks passed\n' > "$P/checks-12"; printf '4\nNO VERDICT YET — still running\n' > "$P/checks-7"
printf '0\nABSENT — no build check ran on this commit: x\n' > "$P/checks-9"
echo "2026-09-02T00:00:00Z" > "$P/date-c12"; echo "$now" > "$P/date-c7"
expect "prs flags a PR at five or more rounds, exit 1" 1 "o/r#12 rounds=6 ci=green head=[0-9]*d[0-9]*h draft claude/issue-12: second.tPR -- CONVERGE: 6 review rounds with findings (flag at 5)" -- "$FW" prs o/r
grep -q "^o/r#7 rounds=2 ci=pending head=[01]m claude/issue-7: first PR$" <<<"$out" && ok "...a PR under the flag gets its line, no note, age from the newer of commit and creation" || ko "PR 7's line: $out"
grep -q "^o/r#9 rounds=? ci=absent head=[01]m claude/issue-9: -$" <<<"$out" && ok "...an unread count reads as ?, never as 0, and an unread commit date leaves the age to the creation time" || ko "PR 9's line: $out"
[ "$(grep -o '^o/r#[0-9]*' <<<"$out" | tr '\n' ' ')" = "o/r#7 o/r#9 o/r#12 " ] && ok "...in PR order" || ko "order: $out"
grep -q "rounds o/r#12 threshold=off" "$P/calls" && grep -q "^retry --read pr list --repo o/r --state open" "$P/calls" && ok "...through pr-review.sh, the repo spelled out in every read" || ko "calls: $(cat "$P/calls")"
expect "--flag-at raises the flag; an unread count alone exits 4" 4 "o/r#9 rounds=?" -- "$FW" prs o/r --flag-at 7
grep -q CONVERGE <<<"$out" && ko "a PR under --flag-at was flagged: $out" || ok "...and nothing is flagged under it"
expect "a list that reaches its cap says PRs past it are not shown, exit 4" 4 "PRS INCOMPLETE o/r: the list reached its cap of 3 open PRs" -- env FLEET_PRS_LIMIT=3 "$FW" prs o/r --flag-at 7
grep -q "^o/r#12 rounds=6" <<<"$out" && ok "...and still lists what it read" || ko "a capped list dropped its rows: $out"
rm "$P/list.json"
expect "an open-PR list that never answered is UNREACHABLE, exit 4" 4 "PRS UNREACHABLE: the open PRs of o/r did not answer" -- "$FW" prs o/r
expect "prs needs an owner/repo" 2 "prs: <owner/repo> required" -- "$FW" prs
expect "prs refuses a zero --flag-at" 2 "positive number of rounds" -- "$FW" prs o/r --flag-at 0
# --wave: the wave's issues are the ones its execution records name.
need_lease
jq -n --arg now "$now" '[{number: 7, title: "first PR", headRefName: "claude/issue-7", headRefOid: "c7", createdAt: $now, isDraft: false,
  closingIssuesReferences: [{number: 7, repository: {name: "other", owner: {login: "o"}}}]},
  {number: 12, title: "second", headRefName: "claude/issue-12", headRefOid: "c12", createdAt: $now, isDraft: false,
  closingIssuesReferences: [{number: 12, repository: {name: "r", owner: {login: "o"}}}]}]' > "$P/list.json"
jq -n '{request_id:"prs-7", wave:"wv", worker:"prs-7", transport:"subagent", issue:"o/other#7", purpose:"prs fixture",
  agent_host:"testbox", execution_host:"testbox", repository:"o/r", requested_revision:"origin/main", kind:"correctness", standing:true}' > "$TMP/prs-7.json"
env FLEET_BOXES="testbox other" "$FW" execution reserve "$TMP/prs-7.json" >/dev/null 2>&1 || ko "could not reserve prs-7 (setup)"
expect "--wave keeps the PRs closing an issue its records name" 0 "^o/r#7 rounds=2" -- "$FW" prs o/r --wave wv
grep -q "o/r#12" <<<"$out" && ko "a PR of no wave issue was listed: $out" || ok "...and drops the rest"
expect "--wave with no records is refused, not read as an empty wave" 1 "no execution record names wave nowave" -- "$FW" prs o/r --wave nowave
jq -n '{request_id:"prs-7", verdict:"not-launched", log:"/dev/null", evidence:"prs fixture: nothing ran"}' > "$TMP/prs-7-done.json"
"$FW" execution conclude "$TMP/prs-7-done.json" >/dev/null || ko "could not conclude prs-7 (setup)"
unset SHIM_PRS
}

section "refresh (execution-only boxes)" && {
need_lease
# ludics-lite#362: only launch and preflight fast-forwarded a box's skills checkout, so a box the
# fleet only EXECUTES on kept a stale one (tuf lacked `execution hold`). `refresh` is the
# preflight's own freshness function alone, and a cross-box `execution run`/`dispatch` runs it on
# the execution host after the dispatch. `other` is the second box: SHIM_SSH_LOCAL runs its far
# side here, against the same scratch checkout.
git -C "$repo" fetch -q origin && git -C "$repo" merge --ff-only -q origin/main || ko "could not bring the scratch checkout current (setup)"
upstream() { # <line>: advance the scratch origin by one commit, from a clone of its own
  [ -d "$TMP/refresh-up" ] || git clone --no-local -q -b main "$origin" "$TMP/refresh-up"
  git -C "$TMP/refresh-up" pull -q --ff-only origin main && echo "$1" >> "$TMP/refresh-up/ship-pr/SKILL.md" \
    && git -C "$TMP/refresh-up" commit -q -am "$1" && git -C "$TMP/refresh-up" push -q origin main \
    || ko "could not advance the scratch origin (setup)"
}
rreq() { # <id> [execution host] -> a reservation payload, on `other` unless named
  jq -n --arg id "$1" --arg host "${2:-other}" '{request_id:$id, wave:"w", worker:$id, transport:"subagent", issue:"o/r#362", purpose:"refresh fixture",
    agent_host:"testbox", execution_host:$host, repository:"o/r", requested_revision:"origin/main", kind:"correctness"}' > "$TMP/refresh-$1.json"
  printf '%s' "$TMP/refresh-$1.json"
}
rdone() { # <id>: conclude it, so its box is free for the next case
  jq -n --arg id "$1" '{request_id:$id, verdict:"not-launched", log:"/dev/null", evidence:"refresh fixture never ran a runner"}' > "$TMP/refresh-$1-done.json"
  "${FWR[@]}" execution conclude "$TMP/refresh-$1-done.json" >/dev/null || ko "could not conclude $1 (setup)"
}
FWR=(env FLEET_BOXES="testbox other" SHIM_SSH_LOCAL=other "$FW")
cur=$(git -C "$repo" rev-parse HEAD)
expect "a current checkout reports already current" 0 "^REFRESH OK testbox skills=${cur:0:9} (already current)$" -- "$FW" refresh testbox
upstream stale-1
expect "a stale checkout is fast-forwarded, and says from where" 0 "^REFRESH OK testbox skills=[0-9a-f]* (fast-forwarded from ${cur:0:9})$" -- "$FW" refresh testbox
[ "$(git -C "$repo" rev-parse HEAD)" = "$(git -C "$TMP/refresh-up" rev-parse HEAD)" ] && ok "...to origin/main" || ko "refresh did not bring the checkout to origin/main"
upstream stale-2; cur=$(git -C "$repo" rev-parse HEAD)
echo local-fix >> "$repo/issue-wave/SKILL.md"
expect "a divergent checkout is reported, not refreshed" 1 "^REFRESH FAILED testbox: 1 local change(s) in the served tree -- left as it is, never reset" -- "$FW" refresh testbox
[ "$(git -C "$repo" rev-parse HEAD)" = "$cur" ] && grep -q local-fix "$repo/issue-wave/SKILL.md" && ok "...and left exactly as it was: HEAD and the local edit" || ko "a divergent checkout was moved or reset"
git -C "$repo" checkout -q -- issue-wave/SKILL.md
expect "a stalling fetch is bounded by FLEET_REFRESH_TIMEOUT and reported" 1 "REFRESH FAILED testbox: git fetch in .* timed out after 2s" -- env SHIM_GIT_HANG_FETCH=1 FLEET_REFRESH_TIMEOUT=2 "$FW" refresh testbox
[ -d "$repo/.git/fleet-checkout.lock" ] && ko "refresh left the checkout's lock behind" || ok "...and releases the lock it shares with the preflight"
# The lock is the checkout's own, in its git directory, so a caller under another ISSUE_WAVE_STATE
# (the sweep beside a wave) meets it too. A holder may yet fail, so a busy lock is waited out and
# the checkout then checked here; one never freed in time is a failure, not a pass.
hold_checkout_lock() { # <seconds>: a live holder of the checkout's lock, as take_lock records one
  sleep "$1" & lockholder=$!
  mkdir "$repo/.git/fleet-checkout.lock" && ps -o lstart= -p "$lockholder" | tr -s ' ' > "$repo/.git/fleet-checkout.lock/start" \
    && echo "$lockholder" > "$repo/.git/fleet-checkout.lock/pid" || ko "could not plant the lock holder (setup)"
}
upstream stale-lock; cur=$(git -C "$repo" rev-parse HEAD)
hold_checkout_lock 3
expect "a refresh waits out a holder that finishes, then checks the checkout itself" 0 "^REFRESH OK testbox skills=[0-9a-f]* (fast-forwarded from ${cur:0:9})$" -- \
  env ISSUE_WAVE_STATE="$TMP/sweep-state" FLEET_REFRESH_TIMEOUT=15 "$FW" refresh testbox
wait "$lockholder" 2>/dev/null
hold_checkout_lock 60
expect "a holder that outlasts the bound fails the refresh, whatever the caller's state directory" 1 "^REFRESH FAILED testbox: lock .*fleet-checkout.lock held by pid $lockholder for 2s" -- \
  env ISSUE_WAVE_STATE="$TMP/sweep-state" FLEET_REFRESH_TIMEOUT=2 "$FW" refresh testbox
kill "$lockholder" 2>/dev/null; wait "$lockholder" 2>/dev/null; rm -rf "$repo/.git/fleet-checkout.lock"
expect "a box that does not answer is unreachable (exit 4), not failed" 4 "^REFRESH UNREACHABLE other: its skills checkout was not checked" -- env FLEET_BOXES="testbox other" "$FW" refresh other
expect "several boxes: one line each, and a failure outranks an unreachable box" 1 "REFRESH UNREACHABLE other" -- env FLEET_BOXES="testbox other" SHIM_GIT_HANG_FETCH=1 FLEET_REFRESH_TIMEOUT=1 "$FW" refresh other testbox
grep -q "^REFRESH FAILED testbox" <<<"$out" && ok "...with the failed box's own line" || ko "multi-box refresh lost a line: $out"
expect "refresh needs a box" 2 "refresh: which box" -- "$FW" refresh
# The execution path. The checkout is stale again; a dispatch to `other` refreshes it, on stderr,
# with the record alone on stdout and the dispatch's own status.
upstream stale-3; cur=$(git -C "$repo" rev-parse HEAD)
"${FWR[@]}" execution run "$(rreq rf-a)" > "$TMP/rf-a.out" 2> "$TMP/rf-a.err"; rc=$?
[ "$rc" -eq 0 ] && jq -e '.state == "launching"' "$TMP/rf-a.out" >/dev/null && ok "a cross-box execution run dispatches, with only the record on stdout" || ko "cross-box run: rc=$rc $(cat "$TMP/rf-a.out" "$TMP/rf-a.err")"
grep -q "^REFRESH OK other skills=[0-9a-f]* (fast-forwarded from ${cur:0:9})$" "$TMP/rf-a.err" && ok "...and fast-forwards the execution host's skills checkout, reported on stderr" || ko "cross-box run did not refresh: $(cat "$TMP/rf-a.err")"
rdone rf-a
expect "a refused dispatch never touches the execution host" 1 "already dispatched" -- "${FWR[@]}" execution run "$(rreq rf-a)"
grep -q REFRESH <<<"$out" && ko "a refused run refreshed the box: $out" || ok "...(no refresh line)"
upstream stale-4; cur=$(git -C "$repo" rev-parse HEAD)
expect "a run on the anchor and local box refreshes it too (no launch need have preflighted it)" 0 "REFRESH OK testbox skills=[0-9a-f]* (fast-forwarded from ${cur:0:9})" -- "${FWR[@]}" execution run "$(rreq rf-b testbox)"
upstream stale-4b; cur=$(git -C "$repo" rev-parse HEAD)
rdone rf-b
echo local-fix >> "$repo/issue-wave/SKILL.md"
expect "a divergent execution host is reported and the dispatch still stands" 0 "REFRESH FAILED other: 1 local change(s) in the served tree -- left as it is, never reset" -- "${FWR[@]}" execution run "$(rreq rf-c)"
[ "$(git -C "$repo" rev-parse HEAD)" = "$cur" ] && grep -q local-fix "$repo/issue-wave/SKILL.md" && ok "...with the checkout left as it was" || ko "a divergent execution host was moved or reset"
git -C "$repo" checkout -q -- issue-wave/SKILL.md; rdone rf-c
# A dispatch whose record cannot be read says so, rather than skipping the refresh silently.
mkdir -p "$TMP/nojq"; printf '#!/bin/sh\necho "jq: not here" >&2; exit 127\n' > "$TMP/nojq/jq"; chmod +x "$TMP/nojq/jq"
expect "an unreadable dispatched record is a loud refresh failure, the dispatch standing" 0 "REFRESH FAILED: cannot read the execution host from the dispatched record (jq: not here)" -- \
  env PATH="$TMP/nojq:$PATH" "${FWR[@]}" execution run "$(rreq rf-g)"
rdone rf-g
# The reserve + dispatch pair refreshes at the dispatch, which is where the box is about to be used.
"${FWR[@]}" execution reserve "$(rreq rf-d)" 2>&1 | grep -q REFRESH && ko "a bare reserve refreshed the box" || ok "a bare reserve does not refresh"
jq -n '{request_id:"rf-d", evidence:"fixture dispatch"}' > "$TMP/refresh-rf-d-dispatch.json"
expect "...its dispatch does" 0 "REFRESH OK other skills=[0-9a-f]* (fast-forwarded from ${cur:0:9})" -- "${FWR[@]}" execution dispatch "$TMP/refresh-rf-d-dispatch.json"
rdone rf-d
# The refresh runs after the registry's lock is released: a fetch that hangs on the execution host
# must not keep other coordinator mutations out. While it hangs, a mutation with no lock wait at
# all goes through (a record on the same request, so no slot is in question).
upstream stale-5
env SHIM_GIT_HANG_FETCH=1 FLEET_REFRESH_TIMEOUT=6 "${FWR[@]}" execution run "$(rreq rf-e)" > "$TMP/rf-e.out" 2> "$TMP/rf-e.err" &
hung=$!
for _ in $(seq 40); do grep -q '"state": "launching"' "$TMP/rf-e.out" 2>/dev/null && break; sleep 0.25; done
jq -n '{request_id:"rf-e", state:"running", evidence:"fixture: recorded while the refresh hangs"}' > "$TMP/refresh-rf-e-record.json"
expect "while the refresh's fetch hangs, the registry lock is free" 0 '"state": "running"' -- env FLEET_LOCK_WAIT=0 "${FWR[@]}" execution record "$TMP/refresh-rf-e-record.json"
kill -0 "$hung" 2>/dev/null && ok "...(the refresh was still running)" || ko "the hanging refresh had already ended; the lock check proved nothing"
wait "$hung"; rc=$?
[ "$rc" -eq 0 ] && grep -q "REFRESH FAILED other: git fetch in .* timed out after 6s" "$TMP/rf-e.err" && ok "...and the bounded fetch is reported, the dispatch standing" || ko "hung refresh: rc=$rc $(cat "$TMP/rf-e.err")"
rdone rf-e
git -C "$repo" fetch -q origin && git -C "$repo" merge --ff-only -q origin/main || ko "could not leave the scratch checkout current (teardown)"
}

section "execution slot" && {
need_lease
# The run-time half of the correctness cap (ludics-lite#160): the registry record is ownership,
# the flock here is what actually bounds concurrent load on the box. testbox has one slot unless
# the spec says otherwise, and every holder below is killed before the section ends.
FWS=(env FLEET_BOXES="testbox other" "$FW")
FWS2=(env FLEET_BOXES="testbox other" FLEET_BOX_CORRECTNESS_SLOTS="testbox=2" "$FW")
# held <log> <pattern>: wait until a background holder has announced the slot it took. The line
# is written after the flock succeeded, so seeing it proves the lock is held, not merely asked for.
held() {
  local i
  for i in $(seq 40); do grep -q "$2" "$1" 2>/dev/null && return 0; sleep 1; done
  ko "no holder announced $2 in $1: $(cat "$1" 2>/dev/null)"; return 1
}
slotreq() { # <id> <kind> [standing] -> a reservation payload file on testbox
  jq -n --arg id "$1" --arg kind "$2" --argjson standing "${3:-false}" \
    '{request_id:$id, wave:"w", worker:$id, transport:"subagent", issue:"o/r#1", purpose:"slot fixture",
      agent_host:"testbox", execution_host:"testbox", repository:"o/r", requested_revision:"origin/master",
      kind:$kind} + (if $standing then {standing:true} else {} end)' > "$TMP/slot-$1.json"
  printf '%s' "$TMP/slot-$1.json"
}
slotdone() { # <id>: free the box again for the cases below
  jq -n --arg id "$1" '{request_id:$id, verdict:"not-launched", log:"/dev/null", evidence:"slot fixture never ran a runner"}' > "$TMP/slot-$1-done.json"
  "${FWS[@]}" execution conclude "$TMP/slot-$1-done.json" >/dev/null || ko "could not conclude $1 (setup)"
}
expect "a batch runs under one of the box's run-time slots" 0 "EXECUTION SLOT testbox: slot 1 of 1 held for: echo batch-ran" -- "${FWS[@]}" execution slot -- echo batch-ran
grep -q batch-ran <<<"$out" && ok "...and the command's own output came through" || ko "the wrapped command's output was lost: $out"
expect "...and the wrapped command's own status is what the slot call returns" 3 "slot 1 of 1" -- "${FWS[@]}" execution slot -- sh -c 'exit 3'
expect "a command that cannot be run is a refusal, not a held slot" 127 "cannot run /nonexistent/runner" -- "${FWS[@]}" execution slot -- /nonexistent/runner
expect "...and the slot it never took is still free" 0 "slot 1 of 1" -- "${FWS[@]}" execution slot --wait 0 -- echo still-free
"${FWS[@]}" execution slot -- sleep 30 > "$TMP/slot-h0.log" 2>&1 &
h0=$!
held "$TMP/slot-h0.log" "slot 1 of 1 held" &&
  expect "a second batch is refused while the box's only run-time slot is held" 1 "all 1 run-time correctness slots busy after 0s" -- "${FWS[@]}" execution slot --wait 0 -- echo second
# The lock is the kernel's, held on an open descriptor through the exec, so there is no lock file
# to strand: killing the batch outright -- what a cancelled or stuck suite gets -- frees the slot.
kill -9 "$h0" 2>/dev/null; wait "$h0" 2>/dev/null
expect "a killed batch frees its slot at once (the kernel holds the lock, not a file)" 0 "slot 1 of 1" -- "${FWS[@]}" execution slot --wait 0 -- echo after-kill
"${FWS2[@]}" execution slot -- sleep 30 > "$TMP/slot-h1.log" 2>&1 &
h1=$!
"${FWS2[@]}" execution slot -- sleep 30 > "$TMP/slot-h2.log" 2>&1 &
h2=$!
if held "$TMP/slot-h1.log" "held" && held "$TMP/slot-h2.log" "held"; then
  grep -q "slot 2 of 2 held" "$TMP/slot-h1.log" "$TMP/slot-h2.log" && ok "two batches run side by side on a two-slot box" || ko "the second batch did not take the second slot"
  expect "...and a third waits for the deadline, then is refused" 1 "all 2 run-time correctness slots busy after 1s" -- "${FWS2[@]}" execution slot --wait 1 -- echo third
fi
kill -9 "$h1" "$h2" 2>/dev/null; wait "$h1" 2>/dev/null; wait "$h2" 2>/dev/null
expect "the widened cap is read from FLEET_BOX_CORRECTNESS_SLOTS, not baked in" 0 "slot 1 of 2" -- "${FWS2[@]}" execution slot --wait 0 -- echo widened
# A measurement owns the box through the registry, and the run-time lock reads that before locking.
"${FWS[@]}" execution run "$(slotreq slot-measure measurement)" >/dev/null || ko "could not reserve the measurement (setup)"
expect "a batch is refused while a measurement is outstanding on the box" 1 "a measurement holds the box exclusively (slot-measure)" -- "${FWS[@]}" execution slot -- echo during-measurement
slotdone slot-measure
expect "...and admitted once the measurement is concluded" 0 "slot 1 of 1" -- "${FWS[@]}" execution slot --wait 0 -- echo after-measurement
# The standing iteration record is ownership and evidence for the worker's whole life, so it
# does not consume the box's one correctness slot -- an agent start is never gated on it.
expect "a standing iteration reservation is admitted" 0 '"standing": true' -- "${FWS[@]}" execution run "$(slotreq slot-iterate correctness true)"
expect "...and leaves the box's correctness slot free for an ordinary reservation" 0 '"state": "launching"' -- "${FWS[@]}" execution run "$(slotreq slot-ordinary correctness)"
expect "...which does fill it: the next ordinary reservation is refused" 1 "correctness slots 1/1 on testbox" -- "${FWS[@]}" execution run "$(slotreq slot-ordinary-2 correctness)"
expect "...while another standing record is still admitted" 0 '"standing": true' -- "${FWS[@]}" execution run "$(slotreq slot-iterate-2 correctness true)"
expect "a batch still takes a run-time slot beside them" 0 "slot 1 of 1" -- "${FWS[@]}" execution slot --wait 0 -- echo beside-standing
slotdone slot-iterate; slotdone slot-iterate-2; slotdone slot-ordinary
# The cap is the BOX's, so the slot files must not hang off ISSUE_WAVE_STATE, which is each
# coordinator's own directory: two workers on one host under different coordinators would each
# take slot 1 and the cap would bound nothing (PR #166 review, round 1).
env ISSUE_WAVE_STATE="$TMP/other-coordinator-state" FLEET_BOXES="testbox other" "$FW" execution slot -- sleep 30 > "$TMP/slot-h3.log" 2>&1 &
h3=$!
held "$TMP/slot-h3.log" "slot 1 of 1 held" &&
  expect "a batch under another coordinator's state contends for the same box slot" 1 "all 1 run-time correctness slots busy after 0s" -- "${FWS[@]}" execution slot --wait 0 -- echo other-state
kill -9 "$h3" 2>/dev/null; wait "$h3" 2>/dev/null
[ -e "$HOME/.local/state/fleet-execution-slots/testbox/slot.1" ] && ok "...because the locks live in the box-wide slot directory, not the coordinator's" || ko "the slot lock is not in the box-wide directory"
expect "FLEET_SLOT_STATE relocates that directory" 0 "slot 1 of 1" -- \
  env FLEET_SLOT_STATE="$TMP/slot state" FLEET_BOXES="testbox other" "$FW" execution slot --wait 0 -- echo relocated
[ -e "$TMP/slot state/testbox/slot.1" ] && ok "...to where it says" || ko "FLEET_SLOT_STATE did not move the lock files"
# A local name outside the roster would lock under a spelling of its own while reading the
# registry for that spelling too, so a batch could run beside a measurement on the canonical one.
expect "a local box outside FLEET_BOXES is refused, as the registry refuses a noncanonical host" 1 "not a canonical FLEET_BOXES entry" -- \
  env FLEET_LOCAL_BOX=testbox-alias FLEET_BOXES="testbox other" "$FW" execution slot -- echo alias
# The registry parses the spec into a dict, so a repeated box keeps its LAST value; a first-match
# read here would run six batches against a registry that admits one.
expect "a repeated box in the spec reads as its last value, as the registry reads it" 0 "slot 1 of 1" -- \
  env FLEET_BOXES="testbox other" FLEET_BOX_CORRECTNESS_SLOTS="testbox=6 testbox=1" "$FW" execution slot --wait 0 -- echo last-wins
expect "...and a malformed later entry is still refused" 1 "<box>=<positive n>" -- \
  env FLEET_BOXES="testbox other" FLEET_BOX_CORRECTNESS_SLOTS="testbox=2 other=0" "$FW" execution slot -- echo bad-tail
expect "...and a spec naming a box outside the roster, as the registry refuses it" 1 "names stale-box, which is not in FLEET_BOXES" -- \
  env FLEET_BOXES="testbox other" FLEET_BOX_CORRECTNESS_SLOTS="testbox=2 stale-box=1" "$FW" execution slot -- echo stale-spec
# A wrapper must not change a batch's verdict: Python ignores SIGPIPE and an ignored disposition
# survives exec, so without the reset the pipeline below exits 1 with a "Broken pipe" line.
expect "a pipeline under the slot dies of SIGPIPE exactly as it does unwrapped" 141 "slot 1 of 1" -- \
  "${FWS[@]}" execution slot -- bash -c 'set -o pipefail; yes | head -n1 >/dev/null'
grep -q "Broken pipe" <<<"$out" && ko "the wrapped pipeline reported a broken pipe the bare one does not" || ok "...and without the diagnostic the bare pipeline never prints"
# The site default, the number the references quote: six on mac-studio (ludics-lite#160), the
# measured counts on the native GPU boxes (ludics-lite#316, #344), and one anywhere the spec does not name -- which is every box under a custom FLEET_BOXES.
# The default applies whenever the roster IS the default one (ludics-lite#329): on 2026-09-22 every
# box's env.sh began exporting FLEET_BOXES with exactly the default boxes, and a test on the
# variable's presence dropped mac-studio to one slot for a day. Each case sets or unsets both
# variables itself.
DEFROSTER="mac-studio rog-nv-linux minix-amd-linux tuf-amd-linux"
FWM=(env FLEET_LOCAL_BOX=mac-studio FLEET_ANCHOR=mac-studio)
expect "the site default gives mac-studio six run-time slots" 0 "slot 1 of 6" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS -u FLEET_BOXES "${FWM[@]}" "$FW" execution slot --wait 0 -- echo default-cap
# The native GPU boxes' measured counts (ludics-lite#316, #344, #391): four on rog-nv-linux, of
# which two hold a GPU token, four on minix-amd-linux, three on tuf-amd-linux. Each box is its own
# anchor here, so the registry read stays local.
for pair in rog-nv-linux:4 minix-amd-linux:4 tuf-amd-linux:3; do
  box=${pair%%:*} n=${pair#*:}
  expect "...and $box $n" 0 "slot 1 of $n" -- \
    env -u FLEET_BOX_CORRECTNESS_SLOTS -u FLEET_BOXES FLEET_LOCAL_BOX=$box FLEET_ANCHOR=$box "$FW" execution slot --wait 0 -- echo default-cap
done
expect "...and so does an exported roster equal to the default (the 2026-09-22 shape)" 0 "slot 1 of 6" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS "${FWM[@]}" FLEET_BOXES="$DEFROSTER" "$FW" execution slot --wait 0 -- echo exported-default
expect "...or the default boxes in another order and spacing (a word set, not a string)" 0 "slot 1 of 6" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS "${FWM[@]}" FLEET_BOXES="  tuf-amd-linux mac-studio   minix-amd-linux rog-nv-linux " "$FW" execution slot --wait 0 -- echo reordered-default
expect "...or the default boxes over several lines (every line is read, not the first)" 0 "slot 1 of 6" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS "${FWM[@]}" FLEET_BOXES="mac-studio rog-nv-linux
minix-amd-linux
tuf-amd-linux" "$FW" execution slot --wait 0 -- echo multiline-default
expect "a box on a later line of the roster is in it, and a spec may name it" 0 "slot 1 of 2" -- \
  env FLEET_LOCAL_BOX=testbox FLEET_BOXES="other
testbox" FLEET_BOX_CORRECTNESS_SLOTS="other=1
testbox=2" "$FW" execution slot --wait 0 -- echo multiline-roster
expect "a custom roster still gives mac-studio one slot" 0 "slot 1 of 1" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS "${FWM[@]}" FLEET_BOXES="mac-studio rog-nv-linux" "$FW" execution slot --wait 0 -- echo custom-roster
expect "an explicit spec overrides the default under an unset roster" 0 "slot 1 of 2" -- \
  env -u FLEET_BOXES "${FWM[@]}" FLEET_BOX_CORRECTNESS_SLOTS="mac-studio=2" "$FW" execution slot --wait 0 -- echo explicit-unset-roster
expect "...and under an exported default roster" 0 "slot 1 of 3" -- \
  "${FWM[@]}" FLEET_BOXES="$DEFROSTER" FLEET_BOX_CORRECTNESS_SLOTS="mac-studio=3" "$FW" execution slot --wait 0 -- echo explicit-default-roster
expect "...where an explicitly empty spec is one slot everywhere" 0 "slot 1 of 1" -- \
  "${FWM[@]}" FLEET_BOXES="$DEFROSTER" FLEET_BOX_CORRECTNESS_SLOTS="" "$FW" execution slot --wait 0 -- echo explicit-empty
expect "...and under a custom roster" 0 "slot 1 of 4" -- \
  "${FWM[@]}" FLEET_BOXES="mac-studio rog-nv-linux" FLEET_BOX_CORRECTNESS_SLOTS="mac-studio=4" "$FW" execution slot --wait 0 -- echo explicit-custom
expect "...and a box the spec does not name has one" 0 "slot 1 of 1" -- "${FWS[@]}" execution slot --wait 0 -- echo unnamed-box
# The GPU tokens (ludics-lite#391): where a box has fewer than its slots, the first N slot files
# are the tokens. Fail-closed: every batch is a GPU batch unless it declares --cpu.
expect "the site default gives rog-nv-linux two GPU tokens among its four slots" 0 "slot 1 of 4, GPU token 1 of 2 held" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS -u FLEET_BOXES FLEET_LOCAL_BOX=rog-nv-linux FLEET_ANCHOR=rog-nv-linux "$FW" execution slot --wait 0 -- echo default-tokens
expect "...and a batch declared --cpu takes the highest free slot there, not a token" 0 "slot 4 of 4 held" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS -u FLEET_BOXES FLEET_LOCAL_BOX=rog-nv-linux FLEET_ANCHOR=rog-nv-linux "$FW" execution slot --wait 0 --cpu -- echo default-cpu
expect "a box with as many tokens as slots is unchanged (the tokens cannot bind there)" 0 "slot 1 of 6 held" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS -u FLEET_BOXES "${FWM[@]}" "$FW" execution slot --wait 0 --cpu -- echo mac-no-token
grep -q "GPU token" <<<"$out" && ko "mac-studio named a GPU token -- $out" || ok "...(no token named)"
FWT=(env FLEET_BOXES="testbox other" FLEET_BOX_CORRECTNESS_SLOTS="testbox=3" FLEET_BOX_GPU_TOKENS="testbox=1" "$FW")
"${FWT[@]}" execution slot -- sleep 30 > "$TMP/slot-g1.log" 2>&1 &
g1=$!
if held "$TMP/slot-g1.log" "slot 1 of 3, GPU token 1 of 1 held"; then
  expect "an undeclared batch waits for the token though slots are free (fail-closed)" 1 "all 1 GPU tokens (slots 1-1 of 3) busy after 1s" -- "${FWT[@]}" execution slot --wait 1 -- echo undeclared
  expect "...and so does one declared --gpu" 1 "all 1 GPU tokens" -- "${FWT[@]}" execution slot --wait 0 --gpu -- echo declared
  # A GPU batch queued behind the token must not sit on a slot meanwhile: start one waiting, and
  # the CPU batches still find both slots left beside the holder. It polls once a second, so two
  # seconds put it well inside its loop first.
  "${FWT[@]}" execution slot --wait 20 -- echo queued-gpu > "$TMP/slot-g2.log" 2>&1 &
  g2=$!
  sleep 2
  "${FWT[@]}" execution slot --cpu -- sleep 30 > "$TMP/slot-c1.log" 2>&1 &
  c1=$!
  if held "$TMP/slot-c1.log" "slot 3 of 3 held"; then
    expect "CPU batches run beside the token holder, and a queued GPU batch holds no slot" 0 "slot 2 of 3 held for: echo cpu-beside" -- "${FWT[@]}" execution slot --wait 0 --cpu -- echo cpu-beside
  fi
  kill -9 "$g1" 2>/dev/null; wait "$g1" 2>/dev/null
  wait "$g2"; rc=$?
  [ "$rc" -eq 0 ] && grep -q "GPU token 1 of 1 held for: echo queued-gpu" "$TMP/slot-g2.log" \
    && ok "...and the queued GPU batch takes the token once it is released" || ko "the queued GPU batch did not run: rc=$rc $(cat "$TMP/slot-g2.log")"
  kill -9 "$c1" 2>/dev/null; wait "$c1" 2>/dev/null
fi
kill -9 "$g1" 2>/dev/null; wait "$g1" 2>/dev/null
# Safe across the switch: a batch started by the version before the tokens took the first free of
# the box's slots, which is a token slot now, so it is counted without knowing it. Here the old
# script's shape is a one-slot spec on the same directory.
env FLEET_BOXES="testbox other" FLEET_BOX_CORRECTNESS_SLOTS="testbox=1" "$FW" execution slot -- sleep 30 > "$TMP/slot-old.log" 2>&1 &
o1=$!
held "$TMP/slot-old.log" "slot 1 of 1 held" &&
  expect "a batch holding slot 1 under the old count is a GPU token to the new one" 1 "all 1 GPU tokens" -- "${FWT[@]}" execution slot --wait 0 -- echo after-switch
kill -9 "$o1" 2>/dev/null; wait "$o1" 2>/dev/null
expect "--cpu and --gpu together are a usage error" 2 "exclusive" -- "${FWT[@]}" execution slot --cpu --gpu -- true
expect "a token count below one is refused, as a slot count is" 1 "FLEET_BOX_GPU_TOKENS entry must be <box>=<positive n>: testbox=0" -- \
  env FLEET_BOXES="testbox other" FLEET_BOX_GPU_TOKENS="testbox=0" "$FW" execution slot -- true
expect "...and one naming a box outside the roster" 1 "FLEET_BOX_GPU_TOKENS names stale-box, which is not in FLEET_BOXES" -- \
  env FLEET_BOXES="testbox other" FLEET_BOX_GPU_TOKENS="stale-box=1" "$FW" execution slot -- true
# The OS-level sleep guard (ludics-lite#317). The stub logs its arguments and its pid and, like
# the real systemd-inhibit, runs the command after its options -- the helper that holds the
# inhibitor for as long as the batch's lifetime pipe is open; INHIBIT_DENY is polkit refusing
# the block, which the real one reports as "Failed to inhibit: Access denied" and exit 1.
mkdir -p "$TMP/inhibit"
cat > "$TMP/inhibit/systemd-inhibit" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$INHIBIT_LOG"
printf '%s\n' "$$" > "$INHIBIT_PID"
[ -z "${INHIBIT_DENY:-}" ] || { echo "Failed to inhibit: Access denied (stub)" >&2; exit 1; }
while [ "$#" -gt 0 ]; do case "$1" in --) shift; break ;; --*) shift ;; *) break ;; esac; done
exec "$@"
EOF
chmod +x "$TMP/inhibit/systemd-inhibit"
export INHIBIT_LOG="$TMP/inhibit.log" INHIBIT_PID="$TMP/inhibit.pid"
HELPER_ARGV="-- sh -c echo HELD; exec cat >/dev/null"
# gone <pidfile>: the helper recorded there has exited (the inhibitor is released), within 10s.
gone() {
  local i pid; pid=$(cat "$1" 2>/dev/null) || return 1
  for i in $(seq 20); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.5; done
  return 1
}
FWI=(env FLEET_SYSTEMD_INHIBIT="$TMP/inhibit/systemd-inhibit" FLEET_BOXES="testbox other" "$FW")
: > "$INHIBIT_LOG"
expect "on a host with systemd-inhibit a slot's batch runs under a sleep:idle block inhibitor" 3 "EXECUTION HOLD testbox: sleep:idle block inhibitor held for: testbox slot 1 of 1: sh -c exit 3" -- \
  "${FWI[@]}" execution slot -- sh -c 'exit 3'
grep -Fxq -- "--what=sleep:idle --mode=block --who=fleet-worker --why=testbox slot 1 of 1: sh -c exit 3 $HELPER_ARGV" "$INHIBIT_LOG" &&
  ok "...as systemd-inhibit --mode=block, never block-weak, which the caller's own uid would ignore" || ko "the batch did not run under the block inhibitor: $(cat "$INHIBIT_LOG")"
grep -q "slot 1 of 1 held for: sh -c exit 3" <<<"$out" && ok "...inside the slot, which it still holds" || ko "the inhibited batch lost its slot line: $out"
gone "$INHIBIT_PID" && ok "...and the inhibitor is released when the batch ends" || ko "the inhibitor helper outlived the batch"
# The inhibitor is held BESIDE the batch, so the pid a caller holds is the batch's own: killing it
# ends the batch, frees the slot and releases the inhibitor, with no process group to find (PR
# #323 review, round 1: under a systemd-inhibit wrapper that pid was systemd-inhibit's).
"${FWI[@]}" execution slot -- sleep 30 > "$TMP/slot-i0.log" 2>&1 &
ipid=$!
if held "$TMP/slot-i0.log" "block inhibitor held"; then
  kill -0 "$(cat "$INHIBIT_PID")" 2>/dev/null && ok "an inhibited batch's helper is alive while the batch runs" || ko "the helper was not running under a live batch"
  [ "$(ps -o comm= -p "$ipid" | sed 's|.*/||')" = sleep ] && ok "...and the pid the caller holds is the batch itself" || ko "the caller's pid is $(ps -o comm= -p "$ipid"), not the batch"
  kill -KILL "$ipid"; wait "$ipid" 2>/dev/null
  gone "$INHIBIT_PID" && ok "...killing that pid releases the inhibitor" || ko "the inhibitor outlived its killed batch"
  expect "...and frees the slot" 0 "slot 1 of 1" -- "${FWS[@]}" execution slot --wait 0 -- echo after-inhibited-kill
fi
# The batch still inherits the slot flock, as it did unwrapped: a descendant that outlives the
# batch's top process keeps both the slot and the inhibitor, since it is still using the box.
: > "$INHIBIT_LOG"
"${FWI[@]}" execution slot -- sh -c 'sleep 30 & echo "child $!"' > "$TMP/slot-i1.log" 2>&1
child=$(sed -n 's/^child //p' "$TMP/slot-i1.log")
if [ -n "$child" ] && kill -0 "$child" 2>/dev/null; then
  expect "a descendant outliving its batch still holds the slot" 1 "slots busy" -- "${FWS[@]}" execution slot --wait 0 -- echo while-child
  kill -0 "$(cat "$INHIBIT_PID")" 2>/dev/null && ok "...and the inhibitor" || ko "the inhibitor was released under a still-running descendant"
  kill "$child"
  gone "$INHIBIT_PID" && ok "...until it exits" || ko "the inhibitor outlived the last descendant"
else ko "no surviving descendant to test with: $(cat "$TMP/slot-i1.log")"; fi
: > "$INHIBIT_LOG"
expect "without systemd-inhibit (macOS) the batch runs bare, and says nothing about it" 0 "slot 1 of 1 held for: echo bare" -- "${FWS[@]}" execution slot -- echo bare
grep -q "EXECUTION HOLD" <<<"$out" && ko "the bare arm announced an inhibitor: $out" || ok "...with no hold line"
[ -s "$INHIBIT_LOG" ] && ko "the bare arm called systemd-inhibit: $(cat "$INHIBIT_LOG")" || ok "...and no systemd-inhibit call"
expect "a polkit refusal of the block runs the batch anyway, under a WARNING" 0 "WARNING: running WITHOUT a sleep inhibitor" -- \
  env INHIBIT_DENY=1 "${FWI[@]}" execution slot -- echo denied-but-ran
grep -q "^denied-but-ran$" <<<"$out" && grep -q "Access denied (stub)" <<<"$out" && ok "...naming the refusal, and the batch ran" || ko "a refused inhibitor stopped the batch or hid why: $out"
: > "$INHIBIT_LOG"
expect "a command that cannot be run is still the slot's own refusal under the inhibitor" 127 "EXECUTION SLOT REFUSED testbox: cannot run /nonexistent/runner" -- \
  "${FWI[@]}" execution slot -- /nonexistent/runner
[ -s "$INHIBIT_LOG" ] && ko "an unrunnable command took an inhibitor: $(cat "$INHIBIT_LOG")" || ok "...refused before any inhibitor is taken"
# `hold` is the measurement's wrapper: the slot refuses while a measurement is outstanding, the
# measurement's own included, so the guard has to come without the slot.
"${FWS[@]}" execution run "$(slotreq hold-measure measurement)" >/dev/null || ko "could not reserve the measurement (setup)"
: > "$INHIBIT_LOG"
expect "execution hold runs a measurement's runner under the inhibitor while the slot refuses it" 0 "sleep:idle block inhibitor held for: testbox hold: echo measured" -- \
  "${FWI[@]}" execution hold -- echo measured
grep -Fxq -- "--what=sleep:idle --mode=block --who=fleet-worker --why=testbox hold: echo measured $HELPER_ARGV" "$INHIBIT_LOG" && ok "...the same block inhibitor the slot takes" || ko "hold did not take the block inhibitor: $(cat "$INHIBIT_LOG")"
expect "...beside a slot that is refused for that very measurement" 1 "a measurement holds the box exclusively (hold-measure)" -- "${FWI[@]}" execution slot -- echo during
slotdone hold-measure
expect "execution hold --why names the holder in the inhibitor" 0 "held for: rog run 7" -- "${FWI[@]}" execution hold --why "rog run 7" -- true
expect "execution hold passes the command's own status through" 5 "held for" -- "${FWI[@]}" execution hold -- sh -c 'exit 5'
expect "...a signal death's too, which a systemd-inhibit wrapper would have turned into 1" 143 "held for" -- "${FWI[@]}" execution hold -- sh -c 'kill -TERM $$'
printf '#!/nonexistent/interpreter\n' > "$TMP/no-interp.sh"; chmod +x "$TMP/no-interp.sh"
expect "execution hold refuses a script whose interpreter is missing with 127, not the run's 1" 127 "EXECUTION HOLD REFUSED testbox: cannot run $TMP/no-interp.sh" -- "${FWI[@]}" execution hold -- "$TMP/no-interp.sh"
expect "...and so does the slot" 127 "EXECUTION SLOT REFUSED testbox: cannot run $TMP/no-interp.sh" -- "${FWI[@]}" execution slot -- "$TMP/no-interp.sh"
expect "execution hold runs bare where there is no systemd-inhibit" 0 "^bare-hold$" -- "${FWS[@]}" execution hold -- echo bare-hold
expect "execution hold refuses a command that cannot be run" 127 "EXECUTION HOLD REFUSED testbox: cannot run /nonexistent/runner" -- "${FWS[@]}" execution hold -- /nonexistent/runner
expect "execution hold needs a command after --" 2 "a command to hold the box around is required" -- "${FWS[@]}" execution hold --
expect "execution hold takes no slot options" 2 "execution hold .--why <text>. -- <command>" -- "${FWS[@]}" execution hold --wait 5 -- true
expect "execution slot needs a command after --" 2 "a command to hold the slot around is required" -- "${FWS[@]}" execution slot --
expect "execution slot refuses a non-numeric --wait" 2 "whole number of seconds" -- "${FWS[@]}" execution slot --wait soon -- echo x
expect "execution slot takes no --box: the slot is this box's own" 2 "execution slot .--wait <seconds>. .--cpu|--gpu. -- <command>" -- "${FWS[@]}" execution slot --box other -- echo x
expect "a malformed slots spec refuses before anything is locked" 1 "<box>=<positive n>" -- \
  env FLEET_BOXES="testbox other" FLEET_BOX_CORRECTNESS_SLOTS="testbox=x" "$FW" execution slot -- echo x
expect "a host with no fleet name has no slot to take" 2 "no fleet name" -- \
  env -u FLEET_LOCAL_BOX FLEET_HOSTNAME_MAP="nomatch*=testbox" "$FW" execution slot -- echo x
}

section "usage" && {
need_lease
need_worker w1
expect "no command prints usage, exit 2" 2 "Usage:" -- "$FW"
expect "bad worker name refuses" 2 "name must be" -- "$FW" launch testbox "bad name" --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
expect "dot names refuse" 2 "name must be" -- "$FW" launch testbox .. --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
expect "a dot-prefixed name refuses (ls could not see it)" 2 "not start with a dot" -- "$FW" launch testbox .triage --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
expect "unstick validates the name before writing anything" 2 "unstick: name must be" -- "$FW" unstick testbox ../escape --message "$TMP/msg.md"
expect "status validates the name" 2 "status: name must be" -- "$FW" status testbox "a b"
expect "close validates the name" 2 "close: name must be" -- "$FW" close testbox ../escape
expect "close takes no options" 2 "close: unknown option" -- "$FW" close testbox w1 --kill
expect "close is fenced by the lease" 1 "CLOSE REFUSED testbox/w1: coordinator lease held by" -- env FLEET_COORDINATOR=other-session "$FW" close testbox w1
expect "without FLEET_LOCAL_BOX an unrecognized host is local only to 'local'" 0 "EXITED(0) local/w1" -- env -u FLEET_LOCAL_BOX "$FW" status local w1
out=$(env -u FLEET_LOCAL_BOX "$FW" status testbox w1 2>&1); rc=$?
[ "$rc" -eq 4 ] && grep -q "UNREACHABLE testbox" <<<"$out" && ok "...and a named box that is not this host goes over ssh (unreachable here)" || ko "named box without local mapping: rc=$rc $out"
me=$(hostname -s | tr 'A-Z' 'a-z')
expect "FLEET_HOSTNAME_MAP maps this host to a fleet name (glob, first match wins)" 0 "EXITED(0) testbox/w1" -- env -u FLEET_LOCAL_BOX FLEET_HOSTNAME_MAP="nomatch*=other ${me%?}*=testbox *=wrong" "$FW" status testbox w1
expect "...and a map that does not match leaves the host unnamed" 4 "UNREACHABLE testbox" -- env -u FLEET_LOCAL_BOX FLEET_HOSTNAME_MAP="nomatch*=testbox" "$FW" status testbox w1
mkdir "$TMP/glob-cwd"; touch "$TMP/glob-cwd/cache=testbox"
expect "hostname-map tokens do not expand as filenames in the launcher's cwd" 0 "EXITED(0) testbox/w1" -- \
  bash -c 'cd "$1" && exec env -u FLEET_LOCAL_BOX FLEET_HOSTNAME_MAP="*=testbox" "$2" status testbox w1' _ "$TMP/glob-cwd" "$FW"
expect "attach rejects a zero interval" 2 "positive number of seconds" -- "$FW" attach testbox w1 --interval 0
expect "attach rejects a non-numeric interval" 2 "positive number of seconds" -- "$FW" attach testbox w1 --interval fast
expect "missing brief refuses" 2 "readable file" -- "$FW" launch testbox nb --target-repo example/project --kind claude --brief "$TMP/none.md" --cwd "$proj"
( cd "$TMP" && "$FW" launch testbox rel --target-repo example/project --kind claude --brief "$brief" --cwd "pro j" >/dev/null ) && settle rel
grep -q "^cwd=$proj\$" "$ISSUE_WAVE_STATE/workers/rel/meta" && ok "a relative --cwd is recorded as its absolute path" || ko "relative cwd recorded: $(grep '^cwd=' "$ISSUE_WAVE_STATE/workers/rel/meta")"
expect "a path with a newline refuses" 2 "must not contain newlines" -- "$FW" launch testbox nl --target-repo example/project --kind claude --brief "$brief" --cwd "$(printf '%s\nx' "$proj")"
}

echo
if [ "$NAMED" -eq 1 ]; then
  echo "$pass passed, $fail failed (${#SELECTED[@]} of ${#SECTIONS[@]} sections)"
else
  echo "$pass passed, $fail failed"
fi
[ "$fail" -eq 0 ]
exit "$?"
}
