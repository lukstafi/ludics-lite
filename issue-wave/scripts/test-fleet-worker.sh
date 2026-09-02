#!/usr/bin/env bash
# Exercises fleet-worker.sh against the local box with shim `claude`/`codex` CLIs on PATH -- no
# model calls, no network, no ssh. Every case runs in a scratch HOME with its own tmux socket and
# state dir, so it is safe beside real workers. The far-side script is the same for local and
# remote boxes, so what passes here is what runs over ssh; only the transport is untested.
#
# Usage: test-fleet-worker.sh            (exit 0 all pass, 1 otherwise; skips with a notice when
#                                          tmux is not installed, which is the CI runner's state
#                                          unless the workflow installs it)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
FW="$HERE/fleet-worker.sh"

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
tid=""; out=""
if [ "${1:-}" = resume ]; then shift; tid="$1"; shift; fi
while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done
[ -n "$tid" ] || tid="0199-shim-$(date +%s)-$$"
brief=$(cat)
printf '{"type":"thread.started","thread_id":"%s"}\n{"type":"turn.started"}\n' "$tid"
sleep 1
text="codex did: $(printf '%s' "$brief" | head -c 40 | tr '\n' ' ')"
printf '{"type":"item.completed","item":{"type":"agent_message","text":"%s"}}\n{"type":"turn.completed"}\n' "$text"
[ -n "$out" ] && printf '%s\n' "$text" > "$out"
exit 0
EOF
chmod +x "$TMP/bin/claude" "$TMP/bin/codex"

# --- a scratch skills checkout with an origin, deployed the way the README deploys it --------
origin="$TMP/origin.git"; repo="$TMP/self improve"
git init -q --bare "$origin"
git init -q -b main "$repo"
mkdir -p "$repo/ClaudeDesktop/skills"
for s in issue-wave ship-pr wait-and-proceed after-merge; do
  mkdir -p "$repo/ClaudeDesktop/skills/$s"; echo "# $s" > "$repo/ClaudeDesktop/skills/$s/SKILL.md"
  ln -sfn "$repo/ClaudeDesktop/skills/$s" "$HOME/.claude/skills/$s"
done
for s in ship-pr wait-and-proceed after-merge; do ln -sfn "$repo/ClaudeDesktop/skills/$s" "$HOME/.codex/skills/$s"; done
git -C "$repo" add -A && git -C "$repo" commit -q -m init
git -C "$repo" remote add origin "$origin" && git -C "$repo" push -q -u origin main
export FLEET_SKILLS_REPO="$repo"

echo "--- coordinator lease"
expect "coordinator: nobody yet, exit 3" 3 "nobody holds the lease" -- "$FW" coordinator
expect "claim takes the lease" 0 "CLAIMED coordinator lease on testbox" -- "$FW" claim
expect "claim again is idempotent for the holder" 0 "CLAIMED already held" -- "$FW" claim
expect "coordinator: me" 0 "COORDINATOR: you" -- "$FW" coordinator
# A second coordinator: its own state dir (own token), the same anchor state.
B=(env ISSUE_WAVE_STATE="$TMP/state-b" FLEET_ANCHOR_STATE="$ISSUE_WAVE_STATE" "$FW")
expect "a second coordinator's claim is refused while held" 1 "CLAIM REFUSED: coordinator lease held by" -- "${B[@]}" claim
expect "a second coordinator cannot halt" 1 "HALT REFUSED fleet: coordinator lease held by" -- "${B[@]}" halt "not mine"
expect "release by a non-holder is refused" 1 "RELEASE REFUSED" -- "${B[@]}" release
expect "--take adopts the lease" 0 "CLAIMED (adopted) coordinator lease" -- "${B[@]}" claim --take
expect "the previous holder now sees the lease as not theirs" 1 "(not you)" -- "$FW" coordinator
expect "...and takes it back with --take" 0 "CLAIMED (adopted)" -- "$FW" claim --take
expect "another session on the same box (same state dir) is not the holder" 1 "CLAIM REFUSED" -- env FLEET_COORDINATOR=other-session "$FW" claim
expect "...and cannot launch through the holder's token" 1 "coordinator lease held by" -- env FLEET_COORDINATOR=other-session "$FW" launch testbox nope --kind claude --brief /dev/null --cwd "$TMP"
expect "release drops it" 0 "RELEASED coordinator lease" -- "$FW" release
expect "coordinator after release: nobody" 3 "nobody holds" -- "$FW" coordinator

echo "--- preflight"
expect "clean main on origin passes (claude, live probe via shim)" 0 "PREFLIGHT OK" -- "$FW" preflight testbox
expect "clean main passes for codex" 0 "PREFLIGHT OK" -- "$FW" preflight testbox --codex
echo x >> "$repo/ClaudeDesktop/skills/ship-pr/SKILL.md"
expect "tracked change refuses" 1 "tracked change" -- "$FW" preflight testbox --no-probe
git -C "$repo" checkout -q -- .
touch "$repo/ClaudeDesktop/skills/ship-pr/scripts.sh"
expect "untracked file under the served tree refuses" 1 "untracked file(s) under ClaudeDesktop" -- "$FW" preflight testbox --no-probe
rm "$repo/ClaudeDesktop/skills/ship-pr/scripts.sh"
touch "$repo/ClaudeDesktop/skills/ship-pr/a b.sh"
expect "an untracked served file whose path git would quote still refuses" 1 "1 untracked file(s) under ClaudeDesktop" -- "$FW" preflight testbox --no-probe
rm "$repo/ClaudeDesktop/skills/ship-pr/a b.sh"
mkdir -p "$repo/.claude"; echo '{}' > "$repo/.claude/settings.local.json"
expect "untracked file outside the served tree passes with a notice" 0 "PREFLIGHT OK.*ignored: .claude/" -- "$FW" preflight testbox --no-probe
rm -rf "$repo/.claude"
# Behind origin: a second clone pushes; the preflight must fast-forward and pass. The bare origin
# has no HEAD for `main` (the runner's git may default to master), so name the branch to clone.
git clone -q -b main "$origin" "$TMP/other" && echo more >> "$TMP/other/ClaudeDesktop/skills/ship-pr/SKILL.md" \
  && git -C "$TMP/other" commit -q -am upstream && git -C "$TMP/other" push -q origin main \
  || ko "could not advance the scratch origin (setup, not the launcher)"
expect "behind origin fast-forwards and passes" 0 "PREFLIGHT OK" -- "$FW" preflight testbox --no-probe
[ "$(git -C "$repo" rev-parse HEAD)" = "$(git -C "$TMP/other" rev-parse HEAD)" ] && ok "checkout was fast-forwarded" || ko "checkout not fast-forwarded"
echo local >> "$repo/ClaudeDesktop/skills/after-merge/SKILL.md" && git -C "$repo" commit -q -am "unpushed"
expect "ahead of origin (unpushed local commit) refuses" 1 "!= origin/main" -- "$FW" preflight testbox --no-probe
git -C "$repo" reset -q --hard origin/main
git -C "$repo" checkout -q -b topic
expect "wrong branch refuses" 1 "checked out topic, not main" -- "$FW" preflight testbox --no-probe
git -C "$repo" checkout -q main && git -C "$repo" branch -q -D topic
rm "$HOME/.codex/skills/after-merge"
expect "missing codex skill link refuses only for codex" 1 "codex/skills/after-merge -> missing" -- "$FW" preflight testbox --codex --no-probe
expect "...and claude preflight still passes" 0 "PREFLIGHT OK" -- "$FW" preflight testbox --no-probe
ln -sfn "$repo/ClaudeDesktop/skills/after-merge" "$HOME/.codex/skills/after-merge"
mkdir -p "$TMP/elsewhere"; ln -sfn "$TMP/elsewhere" "$HOME/.claude/skills/ship-pr"
expect "skill link pointing outside the checkout refuses" 1 "skills/ship-pr -> $TMP/elsewhere" -- "$FW" preflight testbox --no-probe
mkdir -p "$TMP/outside-skill"; ln -sfn "$repo/ClaudeDesktop/../../outside-skill" "$HOME/.claude/skills/ship-pr"
expect "skill link that escapes the checkout through .. refuses" 1 "skills/ship-pr -> $TMP/outside-skill" -- "$FW" preflight testbox --no-probe
rm "$HOME/.claude/skills/ship-pr"; cp -R "$repo/ClaudeDesktop/skills/ship-pr" "$HOME/.claude/skills/ship-pr"
expect "a real directory in place of the link refuses" 1 "skills/ship-pr -> missing/not a link" -- "$FW" preflight testbox --no-probe
rm -rf "$HOME/.claude/skills/ship-pr"; ln -sfn "$repo/ClaudeDesktop/skills/wait-and-proceed" "$HOME/.claude/skills/ship-pr"
expect "a link swapped to a sibling skill refuses" 1 "skills/ship-pr -> .*/skills/wait-and-proceed (not " -- "$FW" preflight testbox --no-probe
ln -sfn "$repo/ClaudeDesktop/skills/ship-pr" "$HOME/.claude/skills/ship-pr"

echo "--- launch / attach / status / log with a project repo and --repo/--branch"
proj="$TMP/pro j"; git init -q -b master "$proj" && echo a > "$proj/a" && git -C "$proj" add a && git -C "$proj" commit -q -m a
git init -q --bare "$TMP/proj.git" && git -C "$proj" remote add origin "$TMP/proj.git" && git -C "$proj" push -q -u origin master
brief="$TMP/brief.md"; printf 'Fix issue #1: handle `$(rm -rf /)` and `backticks` in prose\n' > "$brief"
expect "launch without a lease refuses" 1 "LAUNCH REFUSED testbox/w1: no coordinator lease" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --repo "$proj" --branch claude/w1
"$FW" claim >/dev/null
echo x >> "$repo/ClaudeDesktop/skills/ship-pr/SKILL.md"
expect "launch runs the preflight on the box and refuses a dirty checkout" 1 "LAUNCH REFUSED testbox/w1: PREFLIGHT REFUSED testbox: 1 tracked change" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --repo "$proj" --branch claude/w1
git -C "$repo" checkout -q -- .
expect "launch creates the worktree and reports the session" 0 "LAUNCHED testbox/w1 kind=claude session=[0-9a-f-]\{36\} cwd=$proj-worktrees/w1" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --repo "$proj" --branch claude/w1 -- --model opus
[ -d "$proj-worktrees/w1" ] && [ "$(git -C "$proj-worktrees/w1" rev-parse --abbrev-ref HEAD)" = claude/w1 ] && ok "worktree on the requested branch" || ko "worktree missing or wrong branch"
grep -q -- "--model opus" "$ISSUE_WAVE_STATE/workers/w1/run.sh" && ok "extra CLI args reach the command line" || ko "extra args lost"
expect "attach returns the verdict" 0 "DONE testbox/w1 exit=0 success is_error=false" -- "$FW" attach testbox w1 --interval 1
[ "$(cat "$ISSUE_WAVE_STATE/workers/w1/brief.md")" = "$(cat "$brief")" ] && ok "brief crossed byte-for-byte" || ko "brief mangled"
expect "status after exit names head and branch" 0 "EXITED(0) testbox/w1 kind=claude .*branch=claude/w1" -- "$FW" status testbox w1
expect "log prints the assistant text" 0 "did: Fix issue #1" -- "$FW" log testbox w1
expect "unknown worker is UNKNOWN, exit 3" 3 "UNKNOWN testbox/nope" -- "$FW" status testbox nope
expect "the literal box name local is the same box, labelled as typed" 0 "EXITED(0) local/w1 kind=claude" -- "$FW" status local w1
printf 'a different brief\n' > "$TMP/brief2.md"
expect "a finished worker's name is not reused silently" 1 "finished worker's record is here" -- \
  "$FW" launch testbox w1 --kind claude --brief "$TMP/brief2.md" --cwd "$proj-worktrees/w1"
[ "$(cat "$ISSUE_WAVE_STATE/workers/w1/brief.md")" = "$(cat "$brief")" ] && ok "a refused launch leaves the recorded brief untouched" || ko "refused launch overwrote brief.md"
ls "$ISSUE_WAVE_STATE/workers/w1/" | grep -q '^incoming-' && ko "refused launch left its incoming brief behind" || ok "refused launch cleans up its incoming brief"
git -C "$proj-worktrees/w1" checkout -q -b other
expect "a reused worktree on another branch refuses" 1 "exists but is on 'other', not claude/w1" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --repo "$proj" --branch claude/w1 --replace
git -C "$proj-worktrees/w1" checkout -q claude/w1 && git -C "$proj-worktrees/w1" branch -q -D other
expect "a reused worktree on the requested branch is accepted" 0 "reusing existing worktree .* (on claude/w1)" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --repo "$proj" --branch claude/w1 --replace
"$FW" attach testbox w1 --interval 1 >/dev/null
bash -c 'sleep 30; :' orphan-shim "$ISSUE_WAVE_STATE/workers/w1/" >/dev/null 2>&1 & orphan=$!
expect "--replace refuses while a process still carries the old worker's path" 1 "a CLI from the previous launch is still running" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --cwd "$proj-worktrees/w1" --replace
kill "$orphan" 2>/dev/null; wait "$orphan" 2>/dev/null
expect "--replace overwrites deliberately" 0 "LAUNCHED testbox/w1" -- \
  "$FW" launch testbox w1 --kind claude --brief "$brief" --cwd "$proj-worktrees/w1" --replace
"$FW" attach testbox w1 --interval 1 >/dev/null
expect "ls lists local workers with state" 0 "testbox/w1 EXITED(0) kind=claude" -- "$FW" ls testbox
out=$(FLEET_BOXES="testbox" "$FW" ls 2>&1)
[ "$(printf '%s\n' "$out" | grep -c '/w1 ')" -eq 1 ] && printf '%s' "$out" | grep -q '^local/w1 ' && ok "default ls sweeps the fleet minus the local box, once" || ko "default ls: $out"

echo "--- failure verdicts"
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

echo "--- unstick"
printf 'SLEEP 60 then report\n' > "$TMP/slow.md"; printf 'Stop and answer now.\n' > "$TMP/msg.md"
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
bash -c 'sleep 30; :' orphan-shim "$ISSUE_WAVE_STATE/workers/wo/" >/dev/null 2>&1 & orphan=$!; disown; sleep 0.5
expect "an orphaned CLI (tmux gone) refuses a plain unstick" 1 "tmux is gone but a CLI still runs" -- "$FW" unstick testbox wo --message "$TMP/msg.md"
kill -0 "$orphan" 2>/dev/null && ok "the orphan was not killed by the refused unstick" || ko "plain unstick killed the orphan"
expect "unstick --kill terminates the orphan and resumes" 0 "RESUMED testbox/wo" -- "$FW" unstick testbox wo --message "$TMP/msg.md" --kill
kill -0 "$orphan" 2>/dev/null && ko "orphan survived --kill" || ok "--kill terminated the orphan"
"$FW" attach testbox wo --interval 1 >/dev/null
expect "a non-holder cannot unstick" 1 "UNSTICK REFUSED testbox/wo: coordinator lease held by" -- env FLEET_COORDINATOR=other-session "$FW" unstick testbox wo --message "$TMP/msg.md"

echo "--- codex workers"
expect "codex launch captures the thread id from the stream" 0 "LAUNCHED testbox/c1 kind=codex session=0199-shim-" -- \
  "$FW" launch testbox c1 --kind codex --brief "$brief" --cwd "$proj"
grep -qF -- "codex exec --json --yolo -C $(printf '%q' "$proj") -o " "$ISSUE_WAVE_STATE/workers/c1/run.sh" && grep -qF -- "last-message.md - < " "$ISSUE_WAVE_STATE/workers/c1/run.sh" && ok "codex command shape (brief on stdin, -o last message)" || ko "codex command: $(cat "$ISSUE_WAVE_STATE/workers/c1/run.sh")"
expect "codex attach reads turn.completed and the last message" 0 "DONE testbox/c1 exit=0 turn.completed .*codex did: Fix issue" -- "$FW" attach testbox c1 --interval 1
expect "codex log prints agent messages" 0 "codex did: Fix issue" -- "$FW" log testbox c1
sed -i.bak '/^session=/d' "$ISSUE_WAVE_STATE/workers/c1/meta" && rm -f "$ISSUE_WAVE_STATE/workers/c1/meta.bak"
expect "status recovers the thread id from the stream when meta lacks it" 0 "session=0199-shim-" -- "$FW" status testbox c1
expect "codex unstick resumes by thread id (from the stream) with --yolo" 0 "RESUMED testbox/c1 kind=codex session=0199-shim-" -- "$FW" unstick testbox c1 --message "$TMP/msg.md"
tid=$(sed -n 's/^session=//p' "$ISSUE_WAVE_STATE/workers/c1/meta" | head -n1)
grep -q -- "codex exec resume $tid --yolo --json -" "$ISSUE_WAVE_STATE/workers/c1/run.sh" && ok "codex resume command shape" || ko "codex resume: $(cat "$ISSUE_WAVE_STATE/workers/c1/run.sh")"
expect "the resumed codex turn's verdict carries the NEW message, from the stream" 0 "DONE testbox/c1 exit=0 turn.completed .*| codex did: Stop and answer now" -- "$FW" attach testbox c1 --interval 1

echo "--- halt"
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

echo "--- usage"
expect "no command prints usage, exit 2" 2 "Usage:" -- "$FW"
expect "bad worker name refuses" 2 "name must be" -- "$FW" launch testbox "bad name" --kind claude --brief "$brief" --cwd "$proj"
expect "dot names refuse" 2 "name must be" -- "$FW" launch testbox .. --kind claude --brief "$brief" --cwd "$proj"
expect "missing brief refuses" 2 "readable file" -- "$FW" launch testbox nb --kind claude --brief "$TMP/none.md" --cwd "$proj"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
