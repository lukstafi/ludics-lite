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
export PATH="$TMP/bin:$PATH"
# A scratch git identity, so worktree/commit steps work on a bare runner.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

cleanup() { tmux -L "$FLEET_TMUX_SOCKET" kill-server 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

# Copy the dispatcher beside a canned base helper: no live GitHub reads, and no
# production bypass knob. The production helper's own suites pin its red diagnostics.
mkdir -p "$TMP/dispatcher/issue-wave/scripts" "$TMP/dispatcher/ship-pr/scripts"
cp "$FW" "$TMP/dispatcher/issue-wave/scripts/fleet-worker.sh"
cp "$HERE/fleet-execution.py" "$TMP/dispatcher/issue-wave/scripts/fleet-execution.py"
FW="$TMP/dispatcher/issue-wave/scripts/fleet-worker.sh"
export BASE_CALL_LOG="$TMP/base-calls"
cat > "$TMP/dispatcher/ship-pr/scripts/pr-review.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$* grace=${SHIP_PR_BASE_ABSENT_GRACE:-unset} interval=${SHIP_PR_CHECKS_INTERVAL:-unset}" >> "$BASE_CALL_LOG"
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
cat > "$TMP/bin/claude" <<'EOF'
#!/usr/bin/env bash
sid=""; fmt=text; resume=""
while [ $# -gt 0 ]; do
  case "$1" in
    --session-id) sid="$2"; shift ;;
    --resume) resume="$2"; sid="$2"; shift ;;
    --output-format) fmt="$2"; shift ;;
  esac
  shift
done
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
# it would be for real: nothing in these tests reaches a real box.
cat > "$TMP/bin/ssh" <<'SHIMEOF'
#!/usr/bin/env bash
host=""
while [ $# -gt 0 ]; do case "$1" in -o) shift ;; -*) ;; *) host="$1"; break ;; esac; shift; done
shift
[ "$*" = "exit 0" ] || { echo "ssh: Could not resolve hostname $host: nodename nor servname provided" >&2; exit 255; }
[ "$host" = "${SHIM_SSH_HANG:-}" ] && sleep 30
[ "$host" = "${SHIM_SSH_SLURP:-}" ] && cat > /dev/null
[ "$host" = "${SHIM_SSH_DENY:-}" ] && { echo "$host: Permission denied (publickey)." >&2; exit 255; }
[ "$host" = "${SHIM_SSH_DOWN:-}" ] && { echo "ssh: connect to host $host port 22: Connection timed out" >&2; exit 255; }
exit 0
SHIMEOF
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/tmux" "$TMP/bin/ssh"

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
# need_worker <name>: a finished worker and its worktree, as the launch section leaves behind for
# the sections that read one. A no-op once that section has run.
need_worker() {
  [ -d "$ISSUE_WAVE_STATE/workers/$1" ] && return 0
  need_lease
  "$FW" launch testbox "$1" --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch "claude/$1" >/dev/null &&
    "$FW" attach testbox "$1" --interval 1 >/dev/null ||
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
"$FW" attach testbox pinned-base --interval 1 >/dev/null
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
[ -d "$ISSUE_WAVE_STATE/preflight.lock" ] && ko "preflight lock left after the bounded reach probe" || ok "preflight lock released after the bounded reach probe"
# The slot count per roster box is on the preflight's output (ludics-lite#329): it showed nowhere
# but in a batch's own slot line, so a day of one-slot Mac batches passed every preflight. Each
# case sets or unsets both variables itself.
# A one-slot count is matched as `mac-studio[=]1`: check-prompts reads the bare pair anywhere in
# this file as a statement of the site default, and this is a count the fixture configured.
PFROSTER="mac-studio rog-nv-linux minix-amd-linux tuf-amd-linux"
PFM=(env FLEET_LOCAL_BOX=mac-studio "$FW" preflight mac-studio --no-probe --no-cross)
expect "preflight prints the site default's slot counts under an exported default roster" 0 "^PREFLIGHT SLOTS mac-studio=6 rog-nv-linux=1 minix-amd-linux=1 tuf-amd-linux=1 (site default)$" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS FLEET_BOXES="$PFROSTER" "${PFM[@]}"
grep -q "WARNING" <<<"$out" && ko "...and warns about a configuration that is the site default -- $out" || ok "...and warns about nothing"
expect "...the same under an unset roster" 0 "^PREFLIGHT SLOTS mac-studio=6 .*(site default)$" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS -u FLEET_BOXES "${PFM[@]}"
expect "a spec that leaves mac-studio out under the default roster is a loud warning, not a refusal" 0 "PREFLIGHT SLOTS WARNING: the default roster, but FLEET_BOX_CORRECTNESS_SLOTS=\"rog-nv-linux=2\" does not name mac-studio, which falls to one slot" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="rog-nv-linux=2" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
grep -q "^PREFLIGHT OK mac-studio" <<<"$out" && grep -q "^PREFLIGHT SLOTS mac-studio[=]1 rog-nv-linux=2 minix-amd-linux=1 tuf-amd-linux=1 (FLEET_BOX_CORRECTNESS_SLOTS)$" <<<"$out" \
  && ok "...beside the OK line and the counts it names" || ko "the collapse warning lost the OK line or the counts -- $out"
expect "...as is an explicitly empty spec" 0 "PREFLIGHT SLOTS WARNING: .* does not name mac-studio" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
expect "a spec naming mac-studio at one slot is a choice, printed without a warning" 0 "^PREFLIGHT SLOTS mac-studio[=]1 .*(FLEET_BOX_CORRECTNESS_SLOTS)$" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="mac-studio=1" FLEET_BOXES="$PFROSTER" "${PFM[@]}"
grep -q "WARNING" <<<"$out" && ko "a spec naming mac-studio at one slot drew a collapse warning -- $out" || ok "...and no warning"
expect "a custom roster prints one slot each, without a warning" 0 "^PREFLIGHT SLOTS testbox=1 otherbox=1 (custom roster: one slot each)$" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS FLEET_BOXES="testbox otherbox" "$FW" preflight testbox --no-probe --no-cross
grep -q "WARNING" <<<"$out" && ko "a custom roster drew a collapse warning -- $out" || ok "...and no warning"
expect "a malformed spec is a warning on the preflight, which still passes" 0 "PREFLIGHT SLOTS WARNING: FLEET_BOX_CORRECTNESS_SLOTS names stale-box, which is not in FLEET_BOXES" -- \
  env FLEET_BOX_CORRECTNESS_SLOTS="stale-box=2" FLEET_BOXES="testbox otherbox" "$FW" preflight testbox --no-probe --no-cross
# The probe must not read the far-side program off stdin: a sibling that swallows its stdin would
# otherwise end the preflight early with status 0 over an earlier refusal (Codex P1 on #67).
echo x >> "$repo/ship-pr/SKILL.md"
expect "a reachable sibling does not swallow the refusal that follows the probe" 1 "1 local change(s) in the served tree" -- env FLEET_BOXES="testbox otherbox" SHIM_SSH_SLURP=otherbox "$FW" preflight testbox --no-probe
git -C "$repo" checkout -q -- ship-pr/SKILL.md
[ -d "$ISSUE_WAVE_STATE/preflight.lock" ] && ko "preflight lock left after the bounded fetch" || ok "preflight lock released after the bounded fetch"
# `execution slot` runs a python3 flock on the box that runs the batches, so Python is no longer
# an anchor-only requirement and the preflight is where a box missing it must say so.
mkdir -p "$TMP/nopy"; printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/nopy/python3"; chmod +x "$TMP/nopy/python3"
expect "a box whose python3 cannot import fcntl refuses (the run-time slot lock needs it)" 1 "no python3 with fcntl" -- \
  env PATH="$TMP/nopy:$PATH" "$FW" preflight testbox --no-probe
expect "a hanging live probe is bounded and refused" 1 "claude headless probe timed out after 2s" -- env SHIM_CLAUDE_HANG=1 FLEET_PROBE_TIMEOUT=2 "$FW" preflight testbox
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
"$FW" attach testbox w-cross --interval 1 >/dev/null
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
expect "attach returns the verdict" 0 "DONE testbox/w1 exit=0 success is_error=false" -- "$FW" attach testbox w1 --interval 1
git -C "$proj" branch -q -f alt-base master && echo b > "$proj/b" && git -C "$proj" add b && git -C "$proj" commit -q -m b && git -C "$proj" push -q origin master alt-base
expect "FLEET_BASE_REF sets the worktree's start point when --base is not given" 0 "LAUNCHED testbox/wb " -- \
  env FLEET_BASE_REF=origin/alt-base "$FW" launch testbox wb --target-repo example/project --kind claude --brief "$brief" --repo "$proj" --branch claude/wb
[ "$(git -C "$proj-worktrees/wb" rev-parse HEAD)" = "$(git -C "$proj" rev-parse origin/alt-base)" ] && ok "worktree started from FLEET_BASE_REF" || ko "worktree did not start from FLEET_BASE_REF"
"$FW" attach testbox wb --interval 1 >/dev/null
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
"$FW" attach testbox w1 --interval 1 >/dev/null
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
"$FW" attach testbox w1 --interval 1 >/dev/null
expect "ls lists local workers with state" 0 "testbox/w1 EXITED(0) kind=claude" -- "$FW" ls testbox
out=$(FLEET_BOXES="testbox" "$FW" ls 2>&1)
[ "$(printf '%s\n' "$out" | grep -c '/w1 ')" -eq 1 ] && grep -q '^local/w1 ' <<<"$out" && ok "default ls sweeps the fleet minus the local box, once" || ko "default ls: $out"
}

section "failure verdicts" && {
need_lease   # this section and every one below launch workers; see the shared setup above
printf 'FAIL on purpose\n' > "$TMP/fail.md"
"$FW" launch testbox wf --target-repo example/project --kind claude --brief "$TMP/fail.md" --cwd "$proj" >/dev/null
expect "an erroring worker attaches as FAILED, exit 1" 1 "FAILED testbox/wf exit=1 error_during_execution is_error=true" -- "$FW" attach testbox wf --interval 1
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
}

section "unstick" && {
need_lease
need_worker w1   # its own worktree, for the sibling-session case below
printf 'SLEEP 60 then report\n' > "$TMP/slow.md"
"$FW" launch testbox ws --target-repo example/project --kind claude --brief "$TMP/slow.md" --cwd "$proj" >/dev/null; sleep 1
expect "unstick refuses while the exec is alive" 1 "still running.*pass --kill" -- "$FW" unstick testbox ws --message "$TMP/msg.md"
expect "unstick --kill stops it and resumes the same session" 0 "RESUMED testbox/ws kind=claude session=[0-9a-f-]\{36\} resume=1" -- \
  "$FW" unstick testbox ws --message "$TMP/msg.md" --kill
sid=$(sed -n 's/^session=//p' "$ISSUE_WAVE_STATE/workers/ws/meta")
grep -q -- "--resume $sid" "$ISSUE_WAVE_STATE/workers/ws/run.sh" && ok "resume addresses the recorded session" || ko "resume command wrong: $(cat "$ISSUE_WAVE_STATE/workers/ws/run.sh")"
expect "the resumed turn completes with the message's result" 0 "DONE testbox/ws exit=0 .*did: Stop and answer now" -- "$FW" attach testbox ws --interval 1
grep -q '"resumed":true' "$ISSUE_WAVE_STATE/workers/ws/stream.jsonl" && ok "stream appended, not truncated, across the resume" || ko "stream lost the resume"
grep -q '^resumes=1$' "$ISSUE_WAVE_STATE/workers/ws/meta" && ok "meta counts the resume" || ko "meta resumes not bumped"

printf 'SLEEP 60\n' > "$TMP/slow.md"
"$FW" launch testbox a.b --target-repo example/project --kind claude --brief "$TMP/slow.md" --cwd "$proj" >/dev/null; sleep 1
expect "a dotted name is killed by a literal match, not a regex" 0 "RESUMED testbox/a.b" -- "$FW" unstick testbox a.b --message "$TMP/msg.md" --kill
"$FW" attach testbox a.b --interval 1 >/dev/null
mkdir -p "$TMP/nouuid"; printf '#!/bin/sh\nexit 1\n' > "$TMP/nouuid/uuidgen"; chmod +x "$TMP/nouuid/uuidgen"
expect "no uuidgen: a fallback still yields a session id" 0 "LAUNCHED testbox/nu kind=claude session=[0-9a-f-]\{36\}" -- \
  env PATH="$TMP/nouuid:$PATH" "$FW" launch testbox nu --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
"$FW" attach testbox nu --interval 1 >/dev/null

"$FW" launch testbox wo --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" >/dev/null; "$FW" attach testbox wo --interval 1 >/dev/null
bash -c 'sleep 30; :' claude "$ISSUE_WAVE_STATE/workers/wo/" >/dev/null 2>&1 & orphan=$!; disown; sleep 0.5
expect "an orphaned CLI (tmux gone) refuses a plain unstick" 1 "tmux is gone but a CLI still runs" -- "$FW" unstick testbox wo --message "$TMP/msg.md"
kill -0 "$orphan" 2>/dev/null && ok "the orphan was not killed by the refused unstick" || ko "plain unstick killed the orphan"
expect "unstick --kill terminates the orphan and resumes" 0 "RESUMED testbox/wo" -- "$FW" unstick testbox wo --message "$TMP/msg.md" --kill
kill -0 "$orphan" 2>/dev/null && ko "orphan survived --kill" || ok "--kill terminated the orphan"
"$FW" attach testbox wo --interval 1 >/dev/null
mv "$ISSUE_WAVE_STATE/workers/wo/run.sh" "$TMP/run.saved"; mkdir "$ISSUE_WAVE_STATE/workers/wo/run.sh"
expect "unstick refuses when the resume script cannot be written" 1 "UNSTICK REFUSED testbox/wo: cannot write .*run.sh" -- "$FW" unstick testbox wo --message "$TMP/msg.md"
[ -f "$ISSUE_WAVE_STATE/workers/wo/exit" ] && ok "a refused unstick keeps the previous exit record" || ko "refused unstick destroyed the exit record"
rmdir "$ISSUE_WAVE_STATE/workers/wo/run.sh"; mv "$TMP/run.saved" "$ISSUE_WAVE_STATE/workers/wo/run.sh"
bash -c 'sleep 3; :' tail -f "$ISSUE_WAVE_STATE/workers/wo/stream.jsonl" >/dev/null 2>&1 & disown; sleep 0.5
expect "a diagnostic process on the record does not block a plain unstick" 0 "RESUMED testbox/wo" -- "$FW" unstick testbox wo --message "$TMP/msg.md"
"$FW" attach testbox wo --interval 1 >/dev/null
cp "$ISSUE_WAVE_STATE/workers/wo/meta" "$TMP/meta.before"
expect "a tmux failure during unstick restores exit and meta" 1 "tmux failed (previous exit record and meta kept)" -- env SHIM_TMUX_FAIL_NEW=1 "$FW" unstick testbox wo --message "$TMP/msg.md"
cmp -s "$ISSUE_WAVE_STATE/workers/wo/meta" "$TMP/meta.before" && [ -f "$ISSUE_WAVE_STATE/workers/wo/exit" ] && ok "meta and exit are as before the failed resume" || ko "meta or exit changed by a failed resume"
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
"$FW" attach testbox dup --interval 1 >/dev/null   # dup shares $proj; a live owner would refuse q
mkdir -p "$ISSUE_WAVE_STATE/locks/q"; echo 999999 > "$ISSUE_WAVE_STATE/locks/q/pid"
expect "a lock left by a dead holder is reclaimed" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
"$FW" attach testbox q --interval 1 >/dev/null
mkdir -p "$ISSUE_WAVE_STATE/locks/q"
expect "a fresh ownerless lock (registration in progress) still refuses" 1 "another launch or unstick of this name is in progress" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
touch -t 202001010000 "$ISSUE_WAVE_STATE/locks/q"
expect "an old ownerless lock (shell died before the pid write) is reclaimed" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
"$FW" attach testbox q --interval 1 >/dev/null
mkdir -p "$ISSUE_WAVE_STATE/locks/q"; echo $$ > "$ISSUE_WAVE_STATE/locks/q/pid"; echo "bogus start" > "$ISSUE_WAVE_STATE/locks/q/start"
expect "a lock whose pid is live but whose start time differs (pid reuse) is reclaimed" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
"$FW" attach testbox q --interval 1 >/dev/null
mkdir -p "$ISSUE_WAVE_STATE/locks/q"; echo $$ > "$ISSUE_WAVE_STATE/locks/q/pid"; ps -o lstart= -p $$ | tr -s ' ' > "$ISSUE_WAVE_STATE/locks/q/start"
expect "a lock held by a live process still refuses" 1 "another launch or unstick of this name is in progress" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
rm -rf "$ISSUE_WAVE_STATE/locks/q"
"$FW" launch testbox q.mutating --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" >/dev/null; "$FW" attach testbox q.mutating --interval 1 >/dev/null
expect "a worker named like a lock suffix does not block its sibling" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" --replace
"$FW" attach testbox q --interval 1 >/dev/null
"$FW" attach testbox dup --interval 1 >/dev/null
"$FW" unstick testbox dup --message "$TMP/msg.md" >"$TMP/un-a.out" 2>&1 & ua=$!
"$FW" unstick testbox dup --message "$TMP/msg.md" >"$TMP/un-b.out" 2>&1 & ub=$!
wait "$ua" "$ub"
resumed=$(cat "$TMP/un-a.out" "$TMP/un-b.out" | grep -c '^RESUMED testbox/dup')
[ "$resumed" -eq 1 ] && ok "two overlapping unsticks of one worker: exactly one RESUMED" || ko "overlapping unsticks: $resumed RESUMED -- $(cat "$TMP/un-a.out" "$TMP/un-b.out")"
"$FW" attach testbox dup --interval 1 >/dev/null
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
"$FW" unstick testbox own-a --message "$TMP/msg.md" --kill >/dev/null; "$FW" attach testbox own-a --interval 1 >/dev/null
expect "...and allowed once that worker has finished" 0 "LAUNCHED testbox/own-b" -- "$FW" launch testbox own-b --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
"$FW" attach testbox own-b --interval 1 >/dev/null
"$FW" launch testbox race-x --target-repo example/project --kind claude --brief "$TMP/slow5.md" --cwd "$proj" >"$TMP/rx.out" 2>&1 & rx=$!
"$FW" launch testbox race-y --target-repo example/project --kind claude --brief "$TMP/slow5.md" --cwd "$proj" >"$TMP/ry.out" 2>&1 & ry=$!
wait "$rx" "$ry"
n=$(cat "$TMP/rx.out" "$TMP/ry.out" | grep -c '^LAUNCHED ')
[ "$n" -eq 1 ] && ok "two concurrent launches under different names on one worktree: exactly one LAUNCHED" || ko "worktree race: $n LAUNCHED -- $(cat "$TMP/rx.out" "$TMP/ry.out")"
grep -q 'already owned by live worker' "$TMP/rx.out" "$TMP/ry.out" && ok "the other was refused by ownership" || ko "no ownership refusal: $(cat "$TMP/rx.out" "$TMP/ry.out")"
[ -d "$ISSUE_WAVE_STATE/launch.lock" ] && ko "box-wide launch lock left behind" || ok "box-wide launch lock released"
for w in race-x race-y; do "$FW" unstick testbox $w --message "$TMP/msg.md" --kill >/dev/null 2>&1; "$FW" attach testbox $w --interval 1 >/dev/null 2>&1; done
"$FW" launch testbox hold --target-repo example/project --kind claude --brief "$TMP/slow20.md" --cwd "$proj" >/dev/null; sleep 1
expect "unstick refuses to resume into a worktree another live worker now owns" 1 "UNSTICK REFUSED testbox/own-b: worktree .* is now owned by live worker hold" -- "$FW" unstick testbox own-b --message "$TMP/msg.md"
"$FW" unstick testbox hold --message "$TMP/msg.md" --kill >/dev/null; "$FW" attach testbox hold --interval 1 >/dev/null
"$FW" launch testbox p-1 --target-repo example/project --kind claude --brief "$brief" --cwd "$proj" >/dev/null; "$FW" attach testbox p-1 --interval 1 >/dev/null
"$FW" launch testbox p-12 --target-repo example/project --kind claude --brief "$TMP/slow20.md" --cwd "$proj-worktrees/w1" >/dev/null; sleep 1   # its own worktree: ownership is not what this case tests
expect "a finished worker is not read as running through a prefix-matching sibling session" 0 "EXITED(0) testbox/p-1 " -- "$FW" status testbox p-1
expect "unstick --kill of the finished worker leaves the sibling session alone" 0 "RESUMED testbox/p-1" -- "$FW" unstick testbox p-1 --message "$TMP/msg.md" --kill
expect "...the sibling is still running" 0 "RUNNING testbox/p-12" -- "$FW" status testbox p-12
"$FW" attach testbox p-1 --interval 1 >/dev/null
"$FW" unstick testbox p-12 --message "$TMP/msg.md" --kill >/dev/null; "$FW" attach testbox p-12 --interval 1 >/dev/null
expect "a first launch whose tmux fails leaves no record behind" 1 "LAUNCH REFUSED testbox/tf: tmux failed" -- env SHIM_TMUX_FAIL_NEW=1 "$FW" launch testbox tf --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
[ -d "$ISSUE_WAVE_STATE/workers/tf" ] && ko "failed first launch left a record" || ok "no record left by the failed first launch"
expect "...so the name launches normally afterwards" 0 "LAUNCHED testbox/tf" -- "$FW" launch testbox tf --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
"$FW" attach testbox tf --interval 1 >/dev/null
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
"$FW" attach testbox c1 --interval 1 >/dev/null
expect "a resumed turn that emits nothing is FAILED even though the first turn succeeded" 1 "FAILED testbox/c1 exit=0 no terminal event" -- \
  env SHIM_CODEX_SILENT_RESUME=1 bash -c '"$0" unstick testbox c1 --message "$1" && "$0" attach testbox c1 --interval 1' "$FW" "$TMP/msg.md"
"$FW" unstick testbox c1 --message "$TMP/msg.md" >/dev/null
expect "the resumed codex turn's verdict carries the NEW message, from the stream" 0 "DONE testbox/c1 exit=0 turn.completed .*| codex did: Stop and answer now" -- "$FW" attach testbox c1 --interval 1
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
"$FW" attach testbox h1 --interval 1 >/dev/null
expect "resume-launches clears it" 0 "RESUMED launches" -- "$FW" resume-launches
expect "launch works again" 0 "LAUNCHED testbox/h2" -- "$FW" launch testbox h2 --target-repo example/project --kind claude --brief "$brief" --cwd "$proj"
"$FW" attach testbox h2 --interval 1 >/dev/null
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
# The site default, the number the references quote: six on mac-studio (ludics-lite#160), and
# one anywhere the spec does not name -- which is every box under a custom FLEET_BOXES.
# The default applies whenever the roster IS the default one (ludics-lite#329): on 2026-09-22 every
# box's env.sh began exporting FLEET_BOXES with exactly the default boxes, and a test on the
# variable's presence dropped mac-studio to one slot for a day. Each case sets or unsets both
# variables itself.
DEFROSTER="mac-studio rog-nv-linux minix-amd-linux tuf-amd-linux"
FWM=(env FLEET_LOCAL_BOX=mac-studio FLEET_ANCHOR=mac-studio)
expect "the site default gives mac-studio six run-time slots" 0 "slot 1 of 6" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS -u FLEET_BOXES "${FWM[@]}" "$FW" execution slot --wait 0 -- echo default-cap
expect "...and so does an exported roster equal to the default (the 2026-09-22 shape)" 0 "slot 1 of 6" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS "${FWM[@]}" FLEET_BOXES="$DEFROSTER" "$FW" execution slot --wait 0 -- echo exported-default
expect "...or the default boxes in another order and spacing (a word set, not a string)" 0 "slot 1 of 6" -- \
  env -u FLEET_BOX_CORRECTNESS_SLOTS "${FWM[@]}" FLEET_BOXES="  tuf-amd-linux mac-studio   minix-amd-linux rog-nv-linux " "$FW" execution slot --wait 0 -- echo reordered-default
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
expect "execution slot needs a command after --" 2 "a command to hold the slot around is required" -- "${FWS[@]}" execution slot --
expect "execution slot refuses a non-numeric --wait" 2 "whole number of seconds" -- "${FWS[@]}" execution slot --wait soon -- echo x
expect "execution slot takes no --box: the slot is this box's own" 2 "execution slot .--wait <seconds>. -- <command>" -- "${FWS[@]}" execution slot --box other -- echo x
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
( cd "$TMP" && "$FW" launch testbox rel --target-repo example/project --kind claude --brief "$brief" --cwd "pro j" >/dev/null ) && "$FW" attach testbox rel --interval 1 >/dev/null
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
