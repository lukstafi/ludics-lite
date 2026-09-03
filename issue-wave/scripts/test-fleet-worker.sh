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

HERE=$(cd "$(dirname "$0")" && pwd)
FW="$HERE/fleet-worker.sh"

# --- section selection ------------------------------------------------------------------------
# The `--- name` headers below, in the order they run. Arguments are matched against these, and a
# selected run still runs the sections in file order: each reads what the ones above it left.
SECTIONS=(
  "the real checkout under the README's install loops"
  "coordinator lease"
  "preflight"
  "launch / attach / status / log with a project repo and --repo/--branch"
  "failure verdicts"
  "unstick"
  "codex workers"
  "halt"
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

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "PASS: $*"; }
ko() { fail=$((fail + 1)); echo "FAIL: $*"; }
# expect <label> <want-rc> <want-substring> -- <cmd...>; captures output for later assertions in $out.
expect() {
  local label="$1" want_rc="$2" want="$3"; shift 3; [ "$1" = -- ] && shift
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -q -- "$want"; then ok "$label"
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
sleep_s=$(printf '%s\n' "$brief" | sed -n 's/^SLEEP \([0-9]*\).*/\1/p' | head -n1)
[ -n "${SHIM_CLAUDE_HANG:-}" ] && sleep 30
if [ "$fmt" = json ]; then
  printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"%s"}\n' "${sid:-none}"; exit 0
fi
if printf '%s' "$brief" | grep -q '^SILENT'; then exit 0; fi
printf '{"type":"system","subtype":"init","session_id":"%s","resumed":%s}\n' "$sid" "$([ -n "$resume" ] && echo true || echo false)"
[ -n "$sleep_s" ] && sleep "$sleep_s"
text="did: $(printf '%s' "$brief" | head -c 40 | tr '\n' ' ')"
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"%s"}]}}\n' "$text"
if printf '%s' "$brief" | grep -q '^FAIL'; then
  printf '{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"result":"boom","session_id":"%s"}\n' "$sid"; exit 1
fi
printf '{"type":"result","subtype":"success","is_error":false,"num_turns":1,"result":"%s","session_id":"%s"}\n' "$text" "$sid"
EOF
# codex: `exec --json ... -o <file> -` and `exec resume <id> --yolo --json -`.
cat > "$TMP/bin/codex" <<'EOF'
#!/usr/bin/env bash
[ "$1" = login ] && exit 0
[ "$1" = exec ] && shift
case " $* " in *" -C / "*) case " $* " in *" --skip-git-repo-check "*) ;; *) echo "Not inside a trusted directory and --skip-git-repo-check was not specified." >&2; exit 1 ;; esac ;; esac
if [ -n "${SHIM_CODEX_DOWN:-}" ]; then printf '{"type":"thread.started","thread_id":"x"}\n{"type":"turn.failed","error":{"message":"401 Unauthorized"}}\n'; exit 1; fi
tid=""; out=""
resumed=""
if [ "${1:-}" = resume ]; then shift; tid="$1"; shift; resumed=1; fi
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
[ -n "$tid" ] || tid="0199-shim-$(date +%s)-$$"
brief=$(cat)
if [ -n "${SHIM_CODEX_SILENT_RESUME:-}" ] && [ "$1" != "" ] 2>/dev/null; then :; fi
if [ -n "${SHIM_CODEX_SILENT_RESUME:-}" ] && [ -n "$resumed" ]; then exit 0; fi
printf '{"type":"thread.started","thread_id":"%s"}\n{"type":"turn.started"}\n' "$tid"
sleep 1
text="codex did: $(printf '%s' "$brief" | head -c 40 | tr '\n' ' ')"
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
exec "$REAL_TMUX" "\$@"
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/codex" "$TMP/bin/tmux"

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
git clone -q -b main "$real_origin" "$real_home/ludics-lite" || ko "could not clone the scratch origin (setup, not the launcher)"
claude_loop=$(readme_block 'ludics-lite/*/' | grep -v '^git clone ')
codex_loop=$(readme_block 'for s in ship-pr wait-and-proceed after-merge' | grep -v '^git clone ')
[ -n "$claude_loop" ] && [ -n "$codex_loop" ] && ok "README.md carries both install loops" || ko "could not find the README's install loops"
( export HOME="$real_home"; eval "$claude_loop" && eval "$codex_loop" ) || ko "the README's install loops failed: $claude_loop $codex_loop"
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
  "$FW" launch testbox "$1" --kind claude --brief "$brief" --repo "$proj" --branch "claude/$1" >/dev/null &&
    "$FW" attach testbox "$1" --interval 1 >/dev/null ||
    ko "could not prepare worker $1 (setup, not the launcher)"
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
expect "...and cannot launch through the holder's token" 1 "coordinator lease held by" -- env FLEET_COORDINATOR=other-session "$FW" launch testbox nope --kind claude --brief /dev/null --cwd "$TMP"
# Two adopters at once: the takeover lock serializes them, exactly one holds afterwards.
env FLEET_COORDINATOR=race-a "$FW" claim --take >"$TMP/race-a.out" 2>&1 & ra=$!
env FLEET_COORDINATOR=race-b "$FW" claim --take >"$TMP/race-b.out" 2>&1 & rb=$!
wait "$ra" "$rb"
holders=0
env FLEET_COORDINATOR=race-a "$FW" coordinator 2>&1 | grep -q "COORDINATOR: you" && holders=$((holders + 1))
env FLEET_COORDINATOR=race-b "$FW" coordinator 2>&1 | grep -q "COORDINATOR: you" && holders=$((holders + 1))
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
[ -d "$ISSUE_WAVE_STATE/preflight.lock" ] && ko "preflight lock left after the bounded fetch" || ok "preflight lock released after the bounded fetch"
expect "a hanging live probe is bounded and refused" 1 "claude headless probe timed out after 2s" -- env SHIM_CLAUDE_HANG=1 FLEET_PROBE_TIMEOUT=2 "$FW" preflight testbox
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
git clone -q -b main "$origin" "$TMP/other" && echo more >> "$TMP/other/ship-pr/SKILL.md" \
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
expect "...and claude preflight still passes" 0 "PREFLIGHT OK" -- "$FW" preflight testbox --no-probe
ln -sfn "$repo/after-merge" "$HOME/.codex/skills/after-merge"
mkdir -p "$TMP/elsewhere"; ln -sfn "$TMP/elsewhere" "$HOME/.claude/skills/ship-pr"
expect "skill link pointing outside the checkout refuses" 1 "skills/ship-pr -> $TMP/elsewhere" -- "$FW" preflight testbox --no-probe
mkdir -p "$TMP/outside-skill"; ln -sfn "$repo/../outside-skill" "$HOME/.claude/skills/ship-pr"
expect "skill link that escapes the checkout through .. refuses" 1 "skills/ship-pr -> $TMP/outside-skill" -- "$FW" preflight testbox --no-probe
rm "$HOME/.claude/skills/ship-pr"; cp -R "$repo/ship-pr" "$HOME/.claude/skills/ship-pr"
expect "a real directory in place of the link refuses" 1 "skills/ship-pr -> missing/not a link" -- "$FW" preflight testbox --no-probe
rm -rf "$HOME/.claude/skills/ship-pr"; ln -sfn "$repo/wait-and-proceed" "$HOME/.claude/skills/ship-pr"
expect "a link swapped to a sibling skill refuses" 1 "skills/ship-pr -> .*/wait-and-proceed (not " -- "$FW" preflight testbox --no-probe
ln -sfn "$repo/ship-pr" "$HOME/.claude/skills/ship-pr"
}

section "launch / attach / status / log with a project repo and --repo/--branch" && {
expect "launch without a lease refuses" 1 "LAUNCH REFUSED testbox/w1: no coordinator lease" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --repo "$proj" --branch claude/w1
"$FW" claim >/dev/null
echo x >> "$repo/ship-pr/SKILL.md"
expect "launch runs the preflight on the box and refuses a dirty served tree" 1 "LAUNCH REFUSED testbox/w1: PREFLIGHT REFUSED testbox: 1 local change(s) in the served tree" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --repo "$proj" --branch claude/w1
git -C "$repo" checkout -q -- .
expect "launch creates the worktree and reports the session" 0 "LAUNCHED testbox/w1 kind=claude session=[0-9a-f-]\{36\} cwd=$proj-worktrees/w1" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --repo "$proj" --branch claude/w1 -- --model opus
[ -d "$proj-worktrees/w1" ] && [ "$(git -C "$proj-worktrees/w1" rev-parse --abbrev-ref HEAD)" = claude/w1 ] && ok "worktree on the requested branch" || ko "worktree missing or wrong branch"
grep -q -- "--model opus" "$ISSUE_WAVE_STATE/workers/w1/run.sh" && ok "extra CLI args reach the command line" || ko "extra args lost"
expect "attach returns the verdict" 0 "DONE testbox/w1 exit=0 success is_error=false" -- "$FW" attach testbox w1 --interval 1
git -C "$proj" branch -q -f alt-base master && echo b > "$proj/b" && git -C "$proj" add b && git -C "$proj" commit -q -m b && git -C "$proj" push -q origin master alt-base
expect "FLEET_BASE_REF sets the worktree's start point when --base is not given" 0 "LAUNCHED testbox/wb " -- \
  env FLEET_BASE_REF=origin/alt-base "$FW" launch testbox wb --kind claude --brief "$brief" --repo "$proj" --branch claude/wb
[ "$(git -C "$proj-worktrees/wb" rev-parse HEAD)" = "$(git -C "$proj" rev-parse origin/alt-base)" ] && ok "worktree started from FLEET_BASE_REF" || ko "worktree did not start from FLEET_BASE_REF"
"$FW" attach testbox wb --interval 1 >/dev/null
[ "$(cat "$ISSUE_WAVE_STATE/workers/w1/brief.md")" = "$(cat "$brief")" ] && ok "brief crossed byte-for-byte" || ko "brief mangled"
expect "status after exit names head and branch" 0 "EXITED(0) testbox/w1 kind=claude .*branch=claude/w1" -- "$FW" status testbox w1
expect "log prints the assistant text" 0 "did: Fix issue #1" -- "$FW" log testbox w1
expect "unknown worker is UNKNOWN, exit 3" 3 "UNKNOWN testbox/nope" -- "$FW" status testbox nope
expect "the literal box name local is the same box, labelled as typed" 0 "EXITED(0) local/w1 kind=claude" -- "$FW" status local w1
printf 'a different brief\n' > "$TMP/brief2.md"
expect "a finished worker's name is not reused silently" 1 "finished worker's record is here" -- \
  "$FW" launch testbox w1 --kind claude --brief "$TMP/brief2.md" --cwd "$proj-worktrees/w1"
[ "$(cat "$ISSUE_WAVE_STATE/workers/w1/brief.md")" = "$(cat "$brief")" ] && ok "a refused launch leaves the recorded brief untouched" || ko "refused launch overwrote brief.md"
ls "$ISSUE_WAVE_STATE/incoming/" 2>/dev/null | grep -q '^w1-' && ko "refused launch left its staged brief behind" || ok "refused launch cleans up its staged brief"
git -C "$proj-worktrees/w1" checkout -q -b other
expect "a reused worktree on another branch refuses" 1 "exists but is on 'other', not claude/w1" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --repo "$proj" --branch claude/w1 --replace
git -C "$proj-worktrees/w1" checkout -q claude/w1 && git -C "$proj-worktrees/w1" branch -q -D other
foreign="$proj-worktrees/wx"; git init -q -b claude/wx "$foreign" && echo z > "$foreign/z" && git -C "$foreign" add z && git -C "$foreign" commit -q -m z
expect "a foreign repository at the derived path is refused even on the right branch" 1 "exists but is not a worktree of" -- \
  "$FW" launch testbox wx --kind claude --brief "$brief" --repo "$proj" --branch claude/wx
rm -rf "$foreign"
expect "a reused worktree on the requested branch is accepted" 0 "reusing existing worktree .* (on claude/w1)" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --repo "$proj" --branch claude/w1 --replace
"$FW" attach testbox w1 --interval 1 >/dev/null
bash -c 'sleep 30; :' claude "$ISSUE_WAVE_STATE/workers/w1/" >/dev/null 2>&1 & orphan=$!
expect "--replace refuses while a process still carries the old worker's path" 1 "a CLI from the previous launch is still running" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --cwd "$proj-worktrees/w1" --replace
kill "$orphan" 2>/dev/null; wait "$orphan" 2>/dev/null
rm -rf "$ISSUE_WAVE_STATE/replaced"; : > "$ISSUE_WAVE_STATE/replaced"
expect "--replace with an unusable archive namespace refuses and changes nothing" 1 "cannot archive the previous record .* nothing was changed" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --cwd "$proj-worktrees/w1" --replace
[ -s "$ISSUE_WAVE_STATE/workers/w1/stream.jsonl" ] && [ -f "$ISSUE_WAVE_STATE/workers/w1/exit" ] && ok "the old record is intact" || ko "old record damaged by a failed archive"
rm -f "$ISSUE_WAVE_STATE/replaced"
oldstream=$(cat "$ISSUE_WAVE_STATE/workers/w1/stream.jsonl")
expect "--replace archives the previous record and starts a fresh one" 0 "LAUNCHED testbox/w1 .* replaced=.*/replaced/w1-" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --cwd "$proj-worktrees/w1" --replace
arch=$(printf '%s' "$out" | sed -n 's/.* replaced=//p')
[ -n "$arch" ] && [ "$(cat "$arch/stream.jsonl")" = "$oldstream" ] && [ -f "$arch/exit" ] && ok "the archived record keeps the old stream and exit" || ko "archive missing or incomplete: $arch"
[ "$(cat "$ISSUE_WAVE_STATE/workers/w1/brief.md")" = "$(cat "$brief")" ] && ok "the fresh record has the new brief" || ko "fresh record brief wrong"
"$FW" attach testbox w1 --interval 1 >/dev/null
expect "ls lists local workers with state" 0 "testbox/w1 EXITED(0) kind=claude" -- "$FW" ls testbox
out=$(FLEET_BOXES="testbox" "$FW" ls 2>&1)
[ "$(printf '%s\n' "$out" | grep -c '/w1 ')" -eq 1 ] && printf '%s' "$out" | grep -q '^local/w1 ' && ok "default ls sweeps the fleet minus the local box, once" || ko "default ls: $out"
}

section "failure verdicts" && {
need_lease   # this section and every one below launch workers; see the shared setup above
printf 'FAIL on purpose\n' > "$TMP/fail.md"
"$FW" launch testbox wf --kind claude --brief "$TMP/fail.md" --cwd "$proj" >/dev/null
expect "an erroring worker attaches as FAILED, exit 1" 1 "FAILED testbox/wf exit=1 error_during_execution is_error=true" -- "$FW" attach testbox wf --interval 1
printf 'SILENT\n' > "$TMP/silent.md"
"$FW" launch testbox wsil --kind claude --brief "$TMP/silent.md" --cwd "$proj" >/dev/null
expect "exit 0 with no terminal event is FAILED, not DONE" 1 "FAILED testbox/wsil exit=0 no terminal event" -- "$FW" attach testbox wsil --interval 1
printf 'SLEEP 30\n' > "$TMP/slow.md"
"$FW" launch testbox wv --kind claude --brief "$TMP/slow.md" --cwd "$proj" >/dev/null
sleep 1; tmux -L "$FLEET_TMUX_SOCKET" kill-session -t iw-wv
expect "a killed session with no exit record is VANISHED, exit 3" 3 "VANISHED testbox/wv" -- "$FW" attach testbox wv --interval 1
expect "relaunching a vanished name refuses without --replace" 1 "left no exit record" -- "$FW" launch testbox wv --kind claude --brief "$brief" --cwd "$proj"
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
"$FW" launch testbox ws --kind claude --brief "$TMP/slow.md" --cwd "$proj" >/dev/null; sleep 1
expect "unstick refuses while the exec is alive" 1 "still running.*pass --kill" -- "$FW" unstick testbox ws --message "$TMP/msg.md"
expect "unstick --kill stops it and resumes the same session" 0 "RESUMED testbox/ws kind=claude session=[0-9a-f-]\{36\} resume=1" -- \
  "$FW" unstick testbox ws --message "$TMP/msg.md" --kill
sid=$(sed -n 's/^session=//p' "$ISSUE_WAVE_STATE/workers/ws/meta")
grep -q -- "--resume $sid" "$ISSUE_WAVE_STATE/workers/ws/run.sh" && ok "resume addresses the recorded session" || ko "resume command wrong: $(cat "$ISSUE_WAVE_STATE/workers/ws/run.sh")"
expect "the resumed turn completes with the message's result" 0 "DONE testbox/ws exit=0 .*did: Stop and answer now" -- "$FW" attach testbox ws --interval 1
grep -q '"resumed":true' "$ISSUE_WAVE_STATE/workers/ws/stream.jsonl" && ok "stream appended, not truncated, across the resume" || ko "stream lost the resume"
grep -q '^resumes=1$' "$ISSUE_WAVE_STATE/workers/ws/meta" && ok "meta counts the resume" || ko "meta resumes not bumped"

printf 'SLEEP 60\n' > "$TMP/slow.md"
"$FW" launch testbox a.b --kind claude --brief "$TMP/slow.md" --cwd "$proj" >/dev/null; sleep 1
expect "a dotted name is killed by a literal match, not a regex" 0 "RESUMED testbox/a.b" -- "$FW" unstick testbox a.b --message "$TMP/msg.md" --kill
"$FW" attach testbox a.b --interval 1 >/dev/null
mkdir -p "$TMP/nouuid"; printf '#!/bin/sh\nexit 1\n' > "$TMP/nouuid/uuidgen"; chmod +x "$TMP/nouuid/uuidgen"
expect "no uuidgen: a fallback still yields a session id" 0 "LAUNCHED testbox/nu kind=claude session=[0-9a-f-]\{36\}" -- \
  env PATH="$TMP/nouuid:$PATH" "$FW" launch testbox nu --kind claude --brief "$brief" --cwd "$proj"
"$FW" attach testbox nu --interval 1 >/dev/null

"$FW" launch testbox wo --kind claude --brief "$brief" --cwd "$proj" >/dev/null; "$FW" attach testbox wo --interval 1 >/dev/null
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
expect "...and the worker still reads as its previous successful turn" 0 "DONE testbox/wo exit=0" -- "$FW" attach testbox wo --interval 1
echo 99 > "$ISSUE_WAVE_STATE/workers/wo/exit.prev"; echo "kind=stale" > "$ISSUE_WAVE_STATE/workers/wo/meta.prev"; cp "$ISSUE_WAVE_STATE/workers/wo/meta" "$TMP/wo.meta"
mv "$proj" "$proj.moved"
expect "unstick refuses when the recorded worktree is gone, before touching the record" 1 "recorded working directory .* is gone" -- "$FW" unstick testbox wo --message "$TMP/msg.md"
[ -f "$ISSUE_WAVE_STATE/workers/wo/exit" ] && [ "$(cat "$ISSUE_WAVE_STATE/workers/wo/exit")" = 0 ] && cmp -s "$ISSUE_WAVE_STATE/workers/wo/meta" "$TMP/wo.meta" && ok "the exit record survived and stale .prev files were not restored over it" || ko "exit/meta changed by the refused unstick: $(cat "$ISSUE_WAVE_STATE/workers/wo/exit")"
rm -f "$ISSUE_WAVE_STATE/workers/wo/exit.prev" "$ISSUE_WAVE_STATE/workers/wo/meta.prev"
mv "$proj.moved" "$proj"
expect "a non-holder cannot unstick" 1 "UNSTICK REFUSED testbox/wo: coordinator lease held by" -- env FLEET_COORDINATOR=other-session "$FW" unstick testbox wo --message "$TMP/msg.md"

printf 'SLEEP 5\n' > "$TMP/slow5.md"
"$FW" launch testbox dup --kind claude --brief "$TMP/slow5.md" --cwd "$proj" >"$TMP/dup-a.out" 2>&1 & da=$!
"$FW" launch testbox dup --kind claude --brief "$TMP/slow5.md" --cwd "$proj" >"$TMP/dup-b.out" 2>&1 & db=$!
wait "$da" "$db"
launched=$(cat "$TMP/dup-a.out" "$TMP/dup-b.out" | grep -c '^LAUNCHED testbox/dup')
[ "$launched" -eq 1 ] && ok "two overlapping launches of one name: exactly one LAUNCHED" || ko "overlapping launches: $launched LAUNCHED -- $(cat "$TMP/dup-a.out" "$TMP/dup-b.out")"
cat "$TMP/dup-a.out" "$TMP/dup-b.out" | grep -q 'another launch of this name is in progress\|already running' && ok "the other was refused by the lock or the liveness guard" || ko "no refusal for the overlapping launch"
[ -d "$ISSUE_WAVE_STATE/locks/dup" ] && ko "launch lock left behind" || ok "launch lock released"
"$FW" attach testbox dup --interval 1 >/dev/null   # dup shares $proj; a live owner would refuse q
mkdir -p "$ISSUE_WAVE_STATE/locks/q"; echo 999999 > "$ISSUE_WAVE_STATE/locks/q/pid"
expect "a lock left by a dead holder is reclaimed" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --kind claude --brief "$brief" --cwd "$proj"
"$FW" attach testbox q --interval 1 >/dev/null
mkdir -p "$ISSUE_WAVE_STATE/locks/q"
expect "a fresh ownerless lock (registration in progress) still refuses" 1 "another launch or unstick of this name is in progress" -- "$FW" launch testbox q --kind claude --brief "$brief" --cwd "$proj" --replace
touch -t 202001010000 "$ISSUE_WAVE_STATE/locks/q"
expect "an old ownerless lock (shell died before the pid write) is reclaimed" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --kind claude --brief "$brief" --cwd "$proj" --replace
"$FW" attach testbox q --interval 1 >/dev/null
mkdir -p "$ISSUE_WAVE_STATE/locks/q"; echo $$ > "$ISSUE_WAVE_STATE/locks/q/pid"; echo "bogus start" > "$ISSUE_WAVE_STATE/locks/q/start"
expect "a lock whose pid is live but whose start time differs (pid reuse) is reclaimed" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --kind claude --brief "$brief" --cwd "$proj" --replace
"$FW" attach testbox q --interval 1 >/dev/null
mkdir -p "$ISSUE_WAVE_STATE/locks/q"; echo $$ > "$ISSUE_WAVE_STATE/locks/q/pid"; ps -o lstart= -p $$ | tr -s ' ' > "$ISSUE_WAVE_STATE/locks/q/start"
expect "a lock held by a live process still refuses" 1 "another launch or unstick of this name is in progress" -- "$FW" launch testbox q --kind claude --brief "$brief" --cwd "$proj" --replace
rm -rf "$ISSUE_WAVE_STATE/locks/q"
"$FW" launch testbox q.mutating --kind claude --brief "$brief" --cwd "$proj" >/dev/null; "$FW" attach testbox q.mutating --interval 1 >/dev/null
expect "a worker named like a lock suffix does not block its sibling" 0 "LAUNCHED testbox/q" -- "$FW" launch testbox q --kind claude --brief "$brief" --cwd "$proj" --replace
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
expect "a brief that cannot be staged is a refusal, not an unreachable box" 1 "LAUNCH REFUSED testbox/blocked: cannot stage the brief" -- "$FW" launch testbox blocked --kind claude --brief "$brief" --cwd "$proj"
rm -f "$ISSUE_WAVE_STATE/incoming"
: > "$ISSUE_WAVE_STATE/workers/blocked"
expect "a record directory that cannot be created is a refusal naming it" 1 "LAUNCH REFUSED testbox/blocked: cannot create the worker record" -- "$FW" launch testbox blocked --kind claude --brief "$brief" --cwd "$proj"
rm -f "$ISSUE_WAVE_STATE/workers/blocked"

printf 'SLEEP 20\n' > "$TMP/slow20.md"
"$FW" launch testbox own-a --kind claude --brief "$TMP/slow20.md" --cwd "$proj" >/dev/null; sleep 1
expect "a second worker on a worktree a live worker owns is refused" 1 "already owned by live worker own-a" -- "$FW" launch testbox own-b --kind claude --brief "$brief" --cwd "$proj/"
"$FW" unstick testbox own-a --message "$TMP/msg.md" --kill >/dev/null; "$FW" attach testbox own-a --interval 1 >/dev/null
expect "...and allowed once that worker has finished" 0 "LAUNCHED testbox/own-b" -- "$FW" launch testbox own-b --kind claude --brief "$brief" --cwd "$proj"
"$FW" attach testbox own-b --interval 1 >/dev/null
"$FW" launch testbox race-x --kind claude --brief "$TMP/slow5.md" --cwd "$proj" >"$TMP/rx.out" 2>&1 & rx=$!
"$FW" launch testbox race-y --kind claude --brief "$TMP/slow5.md" --cwd "$proj" >"$TMP/ry.out" 2>&1 & ry=$!
wait "$rx" "$ry"
n=$(cat "$TMP/rx.out" "$TMP/ry.out" | grep -c '^LAUNCHED ')
[ "$n" -eq 1 ] && ok "two concurrent launches under different names on one worktree: exactly one LAUNCHED" || ko "worktree race: $n LAUNCHED -- $(cat "$TMP/rx.out" "$TMP/ry.out")"
cat "$TMP/rx.out" "$TMP/ry.out" | grep -q 'already owned by live worker' && ok "the other was refused by ownership" || ko "no ownership refusal: $(cat "$TMP/rx.out" "$TMP/ry.out")"
[ -d "$ISSUE_WAVE_STATE/launch.lock" ] && ko "box-wide launch lock left behind" || ok "box-wide launch lock released"
for w in race-x race-y; do "$FW" unstick testbox $w --message "$TMP/msg.md" --kill >/dev/null 2>&1; "$FW" attach testbox $w --interval 1 >/dev/null 2>&1; done
"$FW" launch testbox hold --kind claude --brief "$TMP/slow20.md" --cwd "$proj" >/dev/null; sleep 1
expect "unstick refuses to resume into a worktree another live worker now owns" 1 "UNSTICK REFUSED testbox/own-b: worktree .* is now owned by live worker hold" -- "$FW" unstick testbox own-b --message "$TMP/msg.md"
"$FW" unstick testbox hold --message "$TMP/msg.md" --kill >/dev/null; "$FW" attach testbox hold --interval 1 >/dev/null
"$FW" launch testbox p-1 --kind claude --brief "$brief" --cwd "$proj" >/dev/null; "$FW" attach testbox p-1 --interval 1 >/dev/null
"$FW" launch testbox p-12 --kind claude --brief "$TMP/slow20.md" --cwd "$proj-worktrees/w1" >/dev/null; sleep 1   # its own worktree: ownership is not what this case tests
expect "a finished worker is not read as running through a prefix-matching sibling session" 0 "EXITED(0) testbox/p-1 " -- "$FW" status testbox p-1
expect "unstick --kill of the finished worker leaves the sibling session alone" 0 "RESUMED testbox/p-1" -- "$FW" unstick testbox p-1 --message "$TMP/msg.md" --kill
expect "...the sibling is still running" 0 "RUNNING testbox/p-12" -- "$FW" status testbox p-12
"$FW" attach testbox p-1 --interval 1 >/dev/null
"$FW" unstick testbox p-12 --message "$TMP/msg.md" --kill >/dev/null; "$FW" attach testbox p-12 --interval 1 >/dev/null
expect "a first launch whose tmux fails leaves no record behind" 1 "LAUNCH REFUSED testbox/tf: tmux failed" -- env SHIM_TMUX_FAIL_NEW=1 "$FW" launch testbox tf --kind claude --brief "$brief" --cwd "$proj"
[ -d "$ISSUE_WAVE_STATE/workers/tf" ] && ko "failed first launch left a record" || ok "no record left by the failed first launch"
expect "...so the name launches normally afterwards" 0 "LAUNCHED testbox/tf" -- "$FW" launch testbox tf --kind claude --brief "$brief" --cwd "$proj"
"$FW" attach testbox tf --interval 1 >/dev/null
expect "a --replace whose tmux fails restores the previous record" 1 "tmux failed (previous record restored)" -- env SHIM_TMUX_FAIL_NEW=1 "$FW" launch testbox tf --kind claude --brief "$brief" --cwd "$proj" --replace
expect "...and the previous worker still reads as done" 0 "EXITED(0) testbox/tf" -- "$FW" status testbox tf
expect "a stalling project fetch is bounded and refused before any record is touched" 1 "git fetch in .* timed out after 2s" -- \
  env SHIM_GIT_HANG_FETCH=1 FLEET_FETCH_TIMEOUT=2 "$FW" launch testbox fh --kind claude --brief "$brief" --repo "$proj" --branch claude/fh
[ -d "$ISSUE_WAVE_STATE/workers/fh" ] && ko "a refused fetch left a record" || ok "no record left by the refused fetch"
ls "$ISSUE_WAVE_STATE/incoming/" 2>/dev/null | grep -q '^fh-' && ko "a refused fetch left a staged brief" || ok "no staged brief left by the refused fetch"
}

section "codex workers" && {
need_lease
expect "codex launch captures the thread id from the stream" 0 "LAUNCHED testbox/c1 kind=codex session=0199-shim-" -- \
  "$FW" launch testbox c1 --kind codex --brief "$brief" --cwd "$proj"
grep -qF -- "codex exec --json --yolo -C $(printf '%q' "$proj") -o " "$ISSUE_WAVE_STATE/workers/c1/run.sh" && grep -qF -- "last-message.md - < " "$ISSUE_WAVE_STATE/workers/c1/run.sh" && ok "codex command shape (brief on stdin, -o last message)" || ko "codex command: $(cat "$ISSUE_WAVE_STATE/workers/c1/run.sh")"
expect "codex attach reads turn.completed and the last message" 0 "DONE testbox/c1 exit=0 turn.completed .*codex did: Fix issue" -- "$FW" attach testbox c1 --interval 1
expect "codex log prints agent messages" 0 "codex did: Fix issue" -- "$FW" log testbox c1
printf '{"type":"item.completed","item":{"type":"agent_mes' >> "$ISSUE_WAVE_STATE/workers/c1/stream.jsonl"; printf '\n{"type":"item.completed","item":{"type":"agent_message","text":"after the damage"}}\n' >> "$ISSUE_WAVE_STATE/workers/c1/stream.jsonl"
expect "a truncated JSONL line does not hide the events after it" 0 "after the damage" -- "$FW" log testbox c1
sed -i.bak '/^session=/d' "$ISSUE_WAVE_STATE/workers/c1/meta" && rm -f "$ISSUE_WAVE_STATE/workers/c1/meta.bak"
expect "status recovers the thread id from the stream when meta lacks it" 0 "session=0199-shim-" -- "$FW" status testbox c1
expect "codex unstick resumes by thread id (from the stream) with --yolo" 0 "RESUMED testbox/c1 kind=codex session=0199-shim-" -- "$FW" unstick testbox c1 --message "$TMP/msg.md"
tid=$(sed -n 's/^session=//p' "$ISSUE_WAVE_STATE/workers/c1/meta" | head -n1)
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
expect "halted reports open" 0 "launches open" -- "$FW" halted
expect "halt records the reason" 0 "HALTED: launches refused" -- "$FW" halt "master red at abc123, owner: coordinator"
expect "halted reports the reason, exit 1" 1 "HALTED .*master red at abc123" -- "$FW" halted
expect "launch refuses while halted" 1 "LAUNCH REFUSED testbox/h1: launches halted -- .*master red" -- "$FW" launch testbox h1 --kind claude --brief "$brief" --cwd "$proj"
expect "--force launches anyway (the triage worker)" 0 "LAUNCHED testbox/h1" -- "$FW" launch testbox h1 --kind claude --brief "$brief" --cwd "$proj" --force
"$FW" attach testbox h1 --interval 1 >/dev/null
expect "resume-launches clears it" 0 "RESUMED launches" -- "$FW" resume-launches
expect "launch works again" 0 "LAUNCHED testbox/h2" -- "$FW" launch testbox h2 --kind claude --brief "$brief" --cwd "$proj"
"$FW" attach testbox h2 --interval 1 >/dev/null
"$FW" halt "adopted mid-halt" >/dev/null
"${B[@]}" claim --take >/dev/null
expect "a coordinator adopting the lease inherits the halt" 1 "LAUNCH REFUSED testbox/h3: launches halted -- .*adopted mid-halt" -- \
  "${B[@]}" launch testbox h3 --kind claude --brief "$brief" --cwd "$proj"
expect "...and reads it with halted" 1 "HALTED .*adopted mid-halt" -- "${B[@]}" halted
"$FW" claim --take >/dev/null; "$FW" resume-launches >/dev/null
}

section "usage" && {
need_lease
need_worker w1
expect "no command prints usage, exit 2" 2 "Usage:" -- "$FW"
expect "bad worker name refuses" 2 "name must be" -- "$FW" launch testbox "bad name" --kind claude --brief "$brief" --cwd "$proj"
expect "dot names refuse" 2 "name must be" -- "$FW" launch testbox .. --kind claude --brief "$brief" --cwd "$proj"
expect "a dot-prefixed name refuses (ls could not see it)" 2 "not start with a dot" -- "$FW" launch testbox .triage --kind claude --brief "$brief" --cwd "$proj"
expect "unstick validates the name before writing anything" 2 "unstick: name must be" -- "$FW" unstick testbox ../escape --message "$TMP/msg.md"
expect "status validates the name" 2 "status: name must be" -- "$FW" status testbox "a b"
expect "without FLEET_LOCAL_BOX an unrecognized host is local only to 'local'" 0 "EXITED(0) local/w1" -- env -u FLEET_LOCAL_BOX "$FW" status local w1
out=$(env -u FLEET_LOCAL_BOX "$FW" status testbox w1 2>&1); rc=$?
[ "$rc" -eq 4 ] && printf '%s' "$out" | grep -q "UNREACHABLE testbox" && ok "...and a named box that is not this host goes over ssh (unreachable here)" || ko "named box without local mapping: rc=$rc $out"
me=$(hostname -s | tr 'A-Z' 'a-z')
expect "FLEET_HOSTNAME_MAP maps this host to a fleet name (glob, first match wins)" 0 "EXITED(0) testbox/w1" -- env -u FLEET_LOCAL_BOX FLEET_HOSTNAME_MAP="nomatch*=other ${me%?}*=testbox *=wrong" "$FW" status testbox w1
expect "...and a map that does not match leaves the host unnamed" 4 "UNREACHABLE testbox" -- env -u FLEET_LOCAL_BOX FLEET_HOSTNAME_MAP="nomatch*=testbox" "$FW" status testbox w1
mkdir "$TMP/glob-cwd"; touch "$TMP/glob-cwd/cache=testbox"
expect "hostname-map tokens do not expand as filenames in the launcher's cwd" 0 "EXITED(0) testbox/w1" -- \
  bash -c 'cd "$1" && exec env -u FLEET_LOCAL_BOX FLEET_HOSTNAME_MAP="*=testbox" "$2" status testbox w1' _ "$TMP/glob-cwd" "$FW"
expect "attach rejects a zero interval" 2 "positive number of seconds" -- "$FW" attach testbox w1 --interval 0
expect "attach rejects a non-numeric interval" 2 "positive number of seconds" -- "$FW" attach testbox w1 --interval fast
expect "missing brief refuses" 2 "readable file" -- "$FW" launch testbox nb --kind claude --brief "$TMP/none.md" --cwd "$proj"
( cd "$TMP" && "$FW" launch testbox rel --kind claude --brief "$brief" --cwd "pro j" >/dev/null ) && "$FW" attach testbox rel --interval 1 >/dev/null
grep -q "^cwd=$proj\$" "$ISSUE_WAVE_STATE/workers/rel/meta" && ok "a relative --cwd is recorded as its absolute path" || ko "relative cwd recorded: $(grep '^cwd=' "$ISSUE_WAVE_STATE/workers/rel/meta")"
expect "a path with a newline refuses" 2 "must not contain newlines" -- "$FW" launch testbox nl --kind claude --brief "$brief" --cwd "$(printf '%s\nx' "$proj")"
}

echo
if [ "$NAMED" -eq 1 ]; then
  echo "$pass passed, $fail failed (${#SELECTED[@]} of ${#SECTIONS[@]} sections)"
else
  echo "$pass passed, $fail failed"
fi
[ "$fail" -eq 0 ]
