#!/usr/bin/env bash
# Exercises wake-lab.sh with shim `curl`/`python3`/`ssh` on PATH -- no router, no network, no
# ssh. What it pins is what ludics-lite#31 split the script into: the tracked half (the lore, the
# router endpoints, the aliases, the dispatch) must carry no hardware addresses, and the untracked
# half (~/.config/wake-lab/hosts.sh) must be what every MAC actually comes from. It also pins the
# `--help` range, which used to be the hard-coded `2,20p` that silently truncated a grown header.
#
# Usage: test-wake-lab.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail
# Feed captured assertions with here-strings: early-exiting grep must not SIGPIPE a writer.

HERE=$(cd "$(dirname "$0")" && pwd)
WL="$HERE/wake-lab.sh"
EXAMPLE="$HERE/wake-lab-hosts.example.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wake-lab-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS: $*"; }
ko() { fail=$((fail + 1)); echo "FAIL: $*"; }
# expect <label> <want-rc> <want-substring> -- <cmd...>; leaves the output in $out.
expect() {
  local label="$1" want_rc="$2" want="$3"; shift 3; [ "$1" = -- ] && shift
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -q -- "$want" <<<"$out"; then ok "$label"
  else ko "$label (rc=$rc want $want_rc; want /$want/) -- $out"; fi
}

# --- shims ------------------------------------------------------------------------------------
# curl: logs the SOAP action and the MACs it was asked about to $CURL_LOG, and answers with
# whatever $CURL_REPLY names -- `fault`, a link state, or an empty host table.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
body=""; prev=""
for a in "$@"; do case "$prev" in -d) body="$a" ;; esac; prev="$a"; done
printf '%s\n' "$body" >> "$CURL_LOG"
case "${CURL_REPLY:-active}" in
  fault) echo '<s:Envelope><s:Body><s:Fault><detail><errorDescription>NoSuchEntryInArray</errorDescription></detail></s:Fault></s:Body></s:Envelope>' ;;
  hosts) echo '<NewHostNumberOfEntries>0</NewHostNumberOfEntries>' ;;
  *)     echo '<NewActive>1</NewActive>' ;;
esac
EOF
# python3: the magic-packet sender. Logs the MAC it was handed instead of opening a socket.
cat > "$TMP/bin/python3" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null            # the inline program, read from stdin as `python3 - <mac> <bcast>`
printf 'magic %s\n' "${2:-}" >> "$CURL_LOG"
EOF
# ssh: logs `<destination> :: <command>` and answers according to $SSH_UP, a space-separated list
# of destinations that are reachable -- unset, every box is down, which is what most of the cases
# below want. $SSH_DELAY makes each probe slow, the way a real ConnectTimeout against a dark box
# is, which is what the polling deadlines have to survive. $SSH_REFUSE names a command substring
# that fails even on a reachable destination: a Windows host that answers ssh but whose
# `wsl.exe --shutdown` fails, say.
# Three commands also have OUTPUT the script reads, and only a reachable destination produces it:
# $SSH_TASKLIST is what `tasklist` prints (empty -- the default -- is a Windows side holding no
# wsl.exe at all), $SSH_REG is what `reg query` prints, and $SSH_HOLD_LIFE is how many seconds the
# `sleep infinity` holder stays alive here, so that `unhold` can be shown killing a LIVE process
# rather than reaping one the shim had already let exit. That sleep runs as a background job with
# a TERM trap, because a non-interactive bash defers a signal until its FOREGROUND child returns
# -- which would make every holder here outlive the kill a real ssh client obeys at once.
cat > "$TMP/bin/ssh" <<'EOF'
#!/usr/bin/env bash
dest=""; cmd=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) shift ;;
    -*) ;;
    *) if [ -z "$dest" ]; then dest="$1"; else cmd="$cmd $1"; fi ;;
  esac
  shift
done
printf '%s ::%s\n' "$dest" "$cmd" >> "$SSH_LOG"
[ -n "${SSH_DELAY:-}" ] && sleep "$SSH_DELAY"
case "$cmd" in *"${SSH_REFUSE:-}"*) [ -n "${SSH_REFUSE:-}" ] && exit 1 ;; esac
up=1
for u in ${SSH_UP:-}; do [ "$u" = "$dest" ] && up=0; done
if [ "$up" = 0 ]; then
  case "$cmd" in
    *tasklist*)          printf '%s\n' "${SSH_TASKLIST:-}" ;;
    *"reg query"*)       printf '%s\n' "${SSH_REG:-}" ;;
    *"sleep infinity"*)  trap 'exit 143' TERM; sleep "${SSH_HOLD_LIFE:-0}" & wait ;;
  esac
fi
exit "$up"
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/python3" "$TMP/bin/ssh"
PATH="$TMP/bin:$PATH"; export PATH
CURL_LOG="$TMP/curl.log"; export CURL_LOG
SSH_LOG="$TMP/ssh.log"; export SSH_LOG
: > "$CURL_LOG"; : > "$SSH_LOG"

# A host table with obviously fake addresses, in the shape the example file documents.
cat > "$TMP/hosts.sh" <<'EOF'
mac_of() { case "$1" in
  rog)   echo aa:bb:cc:00:00:01 aa:bb:cc:00:00:02 ;;
  minix) echo aa:bb:cc:00:00:03 aa:bb:cc:00:00:04 ;;
  *) return 1 ;; esac; }
eth_mac_of() { case "$1" in
  rog)   echo aa:bb:cc:00:00:02 ;;
  minix) echo aa:bb:cc:00:00:04 ;;
  *) return 1 ;; esac; }
ip_of() { case "$1" in
  rog)   echo 10.0.0.1 ;;
  minix) echo 10.0.0.2 ;;
  *) return 1 ;; esac; }
EOF

# --- the site file is required, and is the only source of hardware addresses -------------------
: > "$CURL_LOG"
expect "a missing host table refuses, naming the path it looked at" 1 "no host table at $TMP/absent.sh" -- \
  env WAKE_LAB_HOSTS="$TMP/absent.sh" "$WL" status rog
grep -q 'wake-lab-hosts.example.sh' <<<"$out" \
  && ok "...and points at the template" || ko "the refusal does not name the template -- $out"
[ ! -s "$CURL_LOG" ] && ok "...before it talks to the router" || ko "it reached the router without a host table: $(cat "$CURL_LOG")"

printf 'mac_of() { echo aa:bb:cc:00:00:01; }\n' > "$TMP/partial.sh"
expect "a host table missing eth_mac_of refuses, naming the function" 1 "defines no eth_mac_of" -- \
  env WAKE_LAB_HOSTS="$TMP/partial.sh" "$WL" status rog
printf 'mac_of() { echo x; }\neth_mac_of() { echo x; }\n' > "$TMP/no-ip.sh"
expect "...and so does one missing ip_of" 1 "defines no ip_of" -- \
  env WAKE_LAB_HOSTS="$TMP/no-ip.sh" "$WL" status rog
printf 'mac_of() { case in esac; }\n' > "$TMP/broken.sh"
expect "a host table that will not parse refuses too" 1 "wake-lab.sh:" -- \
  env WAKE_LAB_HOSTS="$TMP/broken.sh" "$WL" status rog

: > "$CURL_LOG"
expect "the wake path sends both of the site file's MACs" 0 "aa:bb:cc:00:00:02" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" rog
grep -q 'aa:bb:cc:00:00:01' <<<"$out" \
  && ok "...including the Wi-Fi one" || ko "the first MAC never reached the router -- $out"
grep -q 'WakeOnLANByMACAddress' "$CURL_LOG" \
  && ok "...through the router's WoL action" || ko "no WoL SOAP call: $(cat "$CURL_LOG")"
grep -q '^magic aa:bb:cc:00:00:02$' "$CURL_LOG" \
  && ok "...and as a direct magic packet" || ko "no direct packet for the Ethernet MAC: $(cat "$CURL_LOG")"

: > "$CURL_LOG"
expect "status asks the router about the site file's Ethernet MAC alone" 0 "rog    router-active=1" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" status rog
grep -q 'aa:bb:cc:00:00:02' "$CURL_LOG" && ! grep -q 'aa:bb:cc:00:00:01' "$CURL_LOG" \
  && ok "...not about the Wi-Fi one" || ko "router_active used the wrong MAC: $(cat "$CURL_LOG")"
# The column is named for what it reads, the router's NewActive bit, and never for the NIC's link
# state: `eth-link=1` minutes after a shutdown was read as physical link when it was a stale DHCP
# lease (ludics-lite#56). The footer is where a reader of the table learns the difference between
# that stale reading and the settled, powered-off, WoL-armed one.
grep -q "NewActive bit for the Ethernet MAC, not the NIC's link state" <<<"$out" \
  && ok "...and says the column is the router's NewActive bit, not link state" \
  || ko "status does not say what router-active reads -- $out"
grep -q 'stale DHCP lease' <<<"$out" && grep -q 'once settled' <<<"$out" \
  && ok "...telling a stale lease from the settled powered-off state" \
  || ko "status does not carry the stale-lease-vs-settled caveat -- $out"
grep -qE 'eth-link|(^|[^-])link=' <<<"$out" \
  && ko "the old link column name resurfaced in status -- $out" \
  || ok "...and nothing in the table is still called link"

# A target the table does not answer for refuses the whole run, before any packet: the boxes it
# DOES know must not be woken while a later target turns out to be missing, and the dispatch loop's
# exit status would have reported that partial operation as a success.
: > "$CURL_LOG"
expect "a box the site file does not know refuses the run" 1 "not in the host table" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" nosuch
expect "...naming every missing target, with a known one alongside" 1 "nosuch alsomissing" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" rog nosuch alsomissing
[ ! -s "$CURL_LOG" ] && ok "...before waking the box it does know" \
  || ko "a partial wake went out before the refusal: $(cat "$CURL_LOG")"

# --- the WSL kick reaches the Windows side by whichever alias answers ---------------------------
# After a cold boot the LAN alias answers within seconds and tailscaled lags a minute or more, so a
# kick that knew only the Tailscale alias failed on exactly the wake wait_for had just declared
# finished -- and the WSL poll behind it could then only time out, losing the box's backend for the
# day. `kick-wsl` also polls, so the budget is cut to a second here.
kick() { env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="$1" "$WL" kick-wsl rog; }
: > "$SSH_LOG"
out=$(kick "rog-lan rog-nv-wsl" 2>&1)
grep -q 'wsl started on rog (via rog-lan)' <<<"$out" \
  && ok "the WSL kick goes through the LAN alias when Tailscale has not caught up" \
  || ko "the kick did not use the LAN alias -- $out"
grep -q '^rog-lan :: wsl.exe' "$SSH_LOG" \
  && ok "...carrying the wsl.exe start command" || ko "no wsl.exe over rog-lan: $(cat "$SSH_LOG")"
out=$(kick "rog-nv-win rog-nv-wsl" 2>&1)
grep -q 'wsl started on rog (via rog-nv-win)' <<<"$out" \
  && ok "...and falls back to the Tailscale alias when the LAN one is silent" \
  || ko "no fallback to the Tailscale alias -- $out"
out=$(kick "" 2>&1)
grep -q 'wsl kick FAILED on rog' <<<"$out" \
  && ok "...and reports a box no endpoint answers for" || ko "a kick with nothing up did not fail -- $out"

# --- restart-wsl shuts the VM down on the Windows host before starting it ---------------------
# A VM kept alive across a host sleep/resume can carry a degraded dxg bridge that fails under the
# sweep's parallel width while every single-process probe passes (ludics-lite#60). The cure is a
# new VM, and `wsl --shutdown` belongs on the Windows side: issued inside the VM it kills the
# session issuing it. So the restart rides the same -lan/-win aliases as the kick, never -wsl.
restart() { env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="$1" "$WL" restart-wsl rog; }
: > "$SSH_LOG"
out=$(restart "rog-lan rog-nv-wsl" 2>&1)
grep -q 'wsl shut down on rog (via rog-lan)' <<<"$out" \
  && grep -q 'wsl started on rog (via rog-lan)' <<<"$out" \
  && ok "restart-wsl shuts the VM down and starts it again, over the LAN alias" \
  || ko "restart-wsl did not report a shutdown and a start -- $out"
awk '/^rog-lan :: wsl.exe --shutdown$/ { s = NR } /^rog-lan :: wsl.exe -d Ubuntu/ { t = NR } END { exit !(s && t && s < t) }' "$SSH_LOG" \
  && ok "...issuing wsl.exe --shutdown on the Windows host before the start" \
  || ko "no shutdown ahead of the start over rog-lan: $(cat "$SSH_LOG")"
grep -q '^rog-nv-wsl :: wsl.exe' "$SSH_LOG" \
  && ko "a wsl.exe command reached the -wsl guest, where a shutdown kills its own session: $(cat "$SSH_LOG")" \
  || ok "...and never through the -wsl guest"
out=$(restart "" 2>&1)
grep -q 'wsl restart FAILED on rog' <<<"$out" \
  && ok "...and reports a box no endpoint answers for as a failed restart" || ko "a restart with nothing up did not fail -- $out"
# A restart's success is the restart's own status, never the guest's liveness: when the shutdown
# fails, the -wsl guest that still answers is the OLD VM, and `wsl up` over it would send the sweep
# onto exactly the degraded bridge the restart exists to replace. Two shapes of that: no Windows
# endpoint answers while the guest does, and the endpoints answer but the shutdown itself fails.
out=$(restart "rog-nv-wsl" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl restart FAILED on: rog' <<<"$out" && ! grep -q 'wsl up' <<<"$out" \
  && ok "a restart no Windows endpoint carried is not 'wsl up' just because the old guest answers (rc=$rc)" \
  || ko "a failed restart over a live old guest read as success (rc=$rc) -- $out"
: > "$SSH_LOG"
out=$(env SSH_REFUSE=--shutdown WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-win rog-nv-wsl" "$WL" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl restart FAILED on: rog (shutdown refused' <<<"$out" && ! grep -q 'wsl up' <<<"$out" \
  && ok "...nor is one whose wsl.exe --shutdown failed on every alias that answered, and it says which phase (rc=$rc)" \
  || ko "a refused shutdown over a live old guest read as success, or did not name the phase (rc=$rc) -- $out"
grep -q 'wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ko "a start was issued after the shutdown failed, onto the old VM: $(cat "$SSH_LOG")" \
  || ok "...and no start is issued onto the VM the shutdown left standing"
grep -q 'wsl restart FAILED on: rog' <<<"${out##*$'\n'}" \
  && ok "...with the failure as the last line, where the sweep routine reads its verdict" \
  || ko "the failure is not the last line -- $out"
# The kick keeps its meaning -- start if not running -- so a `--wait --wsl` on a box the user is
# working on never kills a live VM; `--restart-wsl` is the spelling that does.
: > "$SSH_LOG"; kick "rog-lan rog-nv-wsl" >/dev/null 2>&1
grep -q -- '--shutdown' "$SSH_LOG" && ko "kick-wsl issued a shutdown: $(cat "$SSH_LOG")" \
  || ok "kick-wsl never shuts a VM down"
wake_wsl() { env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-wsl" "$WL" --wait "$1" rog; }
: > "$SSH_LOG"; out=$(wake_wsl --wsl 2>&1)
grep -q 'wsl up' <<<"$out" && ! grep -q -- '--shutdown' "$SSH_LOG" \
  && ok "...and neither does --wait --wsl" || ko "--wait --wsl shut a VM down, or never started one -- $out; $(cat "$SSH_LOG")"
: > "$SSH_LOG"; out=$(wake_wsl --restart-wsl 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl shut down on rog (via rog-lan)' <<<"$out" && grep -q 'wsl up' <<<"$out" \
  && grep -q '^all up$' <<<"${out##*$'\n'}" && grep -q '^rog-lan :: wsl.exe --shutdown$' "$SSH_LOG" \
  && ok "--wait --restart-wsl shuts the VM down after the wake and starts a fresh one, ending in all up (rc=$rc)" \
  || ko "--wait --restart-wsl did not restart the VM, or did not end in all up (rc=$rc) -- $out; $(cat "$SSH_LOG")"
# The wake path's final verdict is the wake's AND the WSL step's: with the boxes up and the
# restart failed, `all up` with exit 0 would hand the sweep the old VM, so the WSL failure is the
# last line and the exit status is nonzero.
: > "$SSH_LOG"; out=$(env SSH_REFUSE=--shutdown WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-wsl" "$WL" --wait --restart-wsl rog 2>&1); rc=$?
grep -q 'wsl restart FAILED on: rog' <<<"$out" && ! grep -q 'wsl up' <<<"$out" \
  && ok "...and in the wake path too, a failed shutdown over a live old guest is never 'wsl up'" \
  || ko "the wake path reported wsl up over a VM it failed to shut down -- $out"
[ "$rc" -ne 0 ] && ! grep -q '^all up$' <<<"$out" && grep -q 'wsl restart FAILED on: rog' <<<"${out##*$'\n'}" \
  && ok "...nor 'all up': the restart failure is the wake's last line and its exit status (rc=$rc)" \
  || ko "the wake path said all up, or exited 0, over a failed restart (rc=$rc) -- $out"
# A start that fails AFTER the shutdown went through is the opposite diagnosis: there is no VM at
# all, old or new, and telling the operator the old one still answers would be wrong twice over.
: > "$SSH_LOG"
out=$(env SSH_REFUSE='-d Ubuntu' WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-win rog-nv-wsl" "$WL" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl shut down on rog (via rog-lan)' <<<"$out" \
  && grep -q 'wsl restart FAILED on: rog (shut down, then the start failed' <<<"${out##*$'\n'}" \
  && ! grep -q 'old VM' <<<"$out" \
  && ok "a start that fails after the shutdown is reported as a start failure, never as the old VM answering (rc=$rc)" \
  || ko "a failed start after a shutdown was misreported (rc=$rc) -- $out"
# The step's third failing shape: every wsl.exe command succeeded, and the fresh guest never
# answered within the poll budget. `wsl still down` is a backend the sweep cannot test, so it is a
# failure of the step, from the verb's exit status and from the wake path's final verdict alike.
: > "$SSH_LOG"; out=$(restart "rog-lan rog-nv-win" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'wsl up' <<<"$out" && grep -q 'wsl still down after 0 min on: rog' <<<"${out##*$'\n'}" \
  && ok "a restarted guest that never answers is a failed restart-wsl, its last line saying so (rc=$rc)" \
  || ko "a guest that never answered read as a successful restart (rc=$rc) -- $out"
grep -q '^rog-lan :: wsl.exe -d Ubuntu' "$SSH_LOG" && ok "...after the start really was issued" \
  || ko "the start was never issued, so the case pins nothing: $(cat "$SSH_LOG")"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-win" "$WL" --wait --restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q '^all up$' <<<"$out" && grep -q 'NOT all up: wsl still down after 0 min on: rog' <<<"${out##*$'\n'}" \
  && ok "...and the wake path over it is NOT all up, exit nonzero, with the poll timeout as its last line (rc=$rc)" \
  || ko "the wake path said all up, or exited 0, over a guest that never answered (rc=$rc) -- $out"
# The poll's verdict is aggregate; the report is per box. With two boxes started and one guest
# late, only that one is still down -- the other is up and its backend is testable today.
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan minix-lan rog-nv-wsl" "$WL" restart-wsl rog minix 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q '^wsl up on: rog$' <<<"$out" && grep -q 'wsl still down after 0 min on: minix$' <<<"${out##*$'\n'}" \
  && ok "one late guest is reported alone, and its neighbour as up (rc=$rc)" \
  || ko "the poll's aggregate failure was pinned on every started box (rc=$rc) -- $out"
# The kick path holds the same line: a kick no Windows endpoint carried is a failed kick, whatever
# the guest answers, so `wsl up` there is the kick's own success and not the poll's.
out=$(kick "rog-nv-wsl" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl kick FAILED on: rog' <<<"$out" && ! grep -q 'wsl up' <<<"$out" \
  && ok "kick-wsl reports its own failure over a live guest as well (rc=$rc)" \
  || ko "a failed kick over a live guest read as success (rc=$rc) -- $out"

# --- --hold: the VM is kept alive by a wsl.exe on the WINDOWS side, by nothing else --------------
# A kick returns at once and the VM then shuts down under whatever runs inside it: the 2026-09-15
# sweep's hip unit died 76 s into an unheld VM that had powered off 18 s after its kick
# (ludics-lite#155). An ssh session INSIDE the guest does not hold it, so the holder is a
# Windows-side `wsl.exe -d Ubuntu -e sleep infinity`, and the VM counts as up only once such a
# process is OBSERVED there -- a holder that failed to start is the exact state the flag exists to
# rule out.
held_kick() { # held_kick <ssh-up> <tasklist output> [reg output] [holder lifetime] -- kick-wsl --hold rog
  # The default lifetime is not 0: the script requires its own holder to still be running when it
  # sees a wsl.exe on the Windows side, so a shim holder that exits instantly is an already-dead
  # one, not a held VM.
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="$1" \
      SSH_TASKLIST="$2" SSH_REG="${3:-}" SSH_HOLD_LIFE="${4:-20}" "$WL" kick-wsl --hold rog
}
unhold() { env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog; }
# `tasklist /FI "IMAGENAME eq wsl.exe" /NH` prints one row per match and an INFO line when nothing
# matches, so the image name in the output is the whole signal.
TASKLIST_HELD='wsl.exe                       6412 Services                   0     12,345 K'
TASKLIST_EMPTY='INFO: No tasks are running which match the specified criteria.'

rm -rf "$TMP/state"; : > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl holder started on rog (via rog-lan' <<<"$out" \
  && grep -q 'wsl holder observed on rog' <<<"$out" && grep -q 'wsl up' <<<"$out" \
  && ok "kick-wsl --hold spawns a Windows-side holder, observes it, and only then is the VM up (rc=$rc)" \
  || ko "kick-wsl --hold did not spawn and observe a holder (rc=$rc) -- $out"
grep -q '^rog-lan :: wsl.exe -d Ubuntu -e sleep infinity$' "$SSH_LOG" \
  && ok "...as sleep infinity over the alias that carried the kick" \
  || ko "the holder command is not a sleep infinity over rog-lan: $(cat "$SSH_LOG")"
# Never a sized sleep: a lane is several units with their own caps plus preparation outside them,
# so a holder sized to the expected run expires under the last unit, silently (issue comment of
# 2026-09-15). A lane ends by unhold.
grep -qE 'sleep [0-9]' "$SSH_LOG" \
  && ko "the holder was sized with a fixed sleep, which expires under the last unit: $(cat "$SSH_LOG")" \
  || ok "...never a fixed sleep N"
grep -qE '^rog-nv-wsl :: .*(sleep infinity|tasklist)' "$SSH_LOG" \
  && ko "a holder command reached the -wsl guest, where it would die with the VM it holds: $(cat "$SSH_LOG")" \
  || ok "...and never inside the guest, which would die with the VM it is meant to hold"
grep -q '^rog-lan :: tasklist' "$SSH_LOG" \
  && ok "...with the observation read from the Windows side" \
  || ko "no tasklist query went to the Windows side: $(cat "$SSH_LOG")"
[ -s "$TMP/state/hold-rog.pid" ] \
  && ok "...and the holder's pid is recorded, so a later shell can end it" \
  || ko "no pid recorded under $TMP/state"
# The control that makes the case above mean something: a plain kick holds nothing.
: > "$SSH_LOG"; kick "rog-lan rog-nv-wsl" >/dev/null 2>&1
grep -q 'sleep infinity' "$SSH_LOG" && ko "a kick without --hold spawned a holder: $(cat "$SSH_LOG")" \
  || ok "a kick without --hold spawns no holder"

# The whole point of observing: with the guest answering but NO wsl.exe on the Windows side, the
# old code's `wsl up` would hand the sweep a VM nothing holds.
rm -rf "$TMP/state"; : > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_EMPTY" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'wsl up' <<<"$out" \
  && grep -q 'wsl HOLD FAILED on: rog' <<<"${out##*$'\n'}" \
  && ok "a VM whose holder is not observed on the Windows side is never 'wsl up', and says so last (rc=$rc)" \
  || ko "an unheld VM read as up (rc=$rc) -- $out"
[ ! -f "$TMP/state/hold-rog.pid" ] \
  && ok "...and the failed holder is not left recorded for a later unhold to believe in" \
  || ko "a failed hold left a pid file behind: $(cat "$TMP/state/hold-rog.pid")"

# unhold ends the holder explicitly, which is the only way a lane ends.
rm -rf "$TMP/state"; : > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 2>&1)
hold_pid=$(cut -d' ' -f1 "$TMP/state/hold-rog.pid" 2>/dev/null)
if [ -n "$hold_pid" ] && kill -0 "$hold_pid" 2>/dev/null; then
  ok "the holder is a live process while the lane runs (pid $hold_pid)"
else
  ko "the holder was not running after a successful hold (pid ${hold_pid:-none}) -- $out"
fi
out=$(unhold 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q "wsl holder released on rog (pid $hold_pid killed" <<<"$out" \
  && ok "...and unhold kills it, naming the pid (rc=$rc)" || ko "unhold did not release the holder (rc=$rc) -- $out"
for _ in 1 2 3 4 5; do kill -0 "$hold_pid" 2>/dev/null || break; sleep 1; done
kill -0 "$hold_pid" 2>/dev/null \
  && ko "unhold reported a kill the holder survived (pid $hold_pid)" \
  || ok "...and the holder really is gone"
[ ! -f "$TMP/state/hold-rog.pid" ] && ok "...leaving no pid file behind" \
  || ko "unhold left the pid file in place"
# A lane's cleanup runs on the way out of a FAILED lane too, so unhold over nothing is not an error.
expect "unhold with no holder recorded says so and still succeeds" 0 "no wsl holder recorded for rog" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog
# Cleanup must not be blocked by configuration: the holder is a local pid, and a site file that
# went missing after the lane started would otherwise strand the one process that pins the VM.
rm -rf "$TMP/state"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 2>&1)
stranded=$(cut -d' ' -f1 "$TMP/state/hold-rog.pid" 2>/dev/null)
out=$(env WAKE_LAB_HOSTS="$TMP/absent.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl holder released on rog' <<<"$out" \
  && ok "unhold releases the holder even with no host table, which it needs nothing from (rc=$rc)" \
  || ko "a missing site file stranded the holder (rc=$rc) -- $out"
for _ in 1 2 3 4 5; do kill -0 "$stranded" 2>/dev/null || break; sleep 1; done
kill -0 "$stranded" 2>/dev/null && ko "...but the holder survived" || ok "...and the holder is gone"
mkdir -p "$TMP/state"; printf '999999\n' > "$TMP/state/hold-rog.pid"
expect "...and a holder that had already died is reported as such, not as a release" 0 "had already exited" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog
[ ! -f "$TMP/state/hold-rog.pid" ] && ok "...and its stale pid file is cleared" \
  || ko "a dead holder's pid file survived unhold"
# Every box's holder runs the same payload, so a signature that did not include the destination
# would let one box's stale file kill another box's LIVE holder -- dropping that lane silently.
rm -rf "$TMP/state"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 2>&1)
rog_pid=$(cut -d' ' -f1 "$TMP/state/hold-rog.pid" 2>/dev/null)
printf '%s minix-lan\n' "$rog_pid" > "$TMP/state/hold-minix.pid"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold minix 2>&1)
grep -q 'had already exited' <<<"$out" && kill -0 "$rog_pid" 2>/dev/null \
  && ok "a stale file for one box does not kill another box's live holder" \
  || ko "unhold minix killed rog's holder, or claimed it as its own -- $out"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1
# The pid file outlives the shell that wrote it, and pids are reused: a stale one whose number has
# been taken over by something else must not get that process killed.
sleep 30 & innocent=$!
printf '%s\n' "$innocent" > "$TMP/state/hold-rog.pid"
expect "a stale pid reused by an unrelated process is not killed as a holder" 0 "had already exited" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog
kill -0 "$innocent" 2>/dev/null && ok "...and that process is still running" \
  || ko "unhold killed a process that merely inherited the holder's pid"
kill "$innocent" 2>/dev/null; wait "$innocent" 2>/dev/null
# A --hold that holds nothing is a lane that believes it is held and is not.
: > "$CURL_LOG"
expect "--hold without a WSL start is refused rather than ignored" 1 "hold needs a WSL start" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" --hold rog
[ ! -s "$CURL_LOG" ] && ok "...before anything is sent" || ko "the refused run still woke the box: $(cat "$CURL_LOG")"
# The wake path starts WSL only under --wait, so `--wsl --hold` without it holds nothing either --
# and it is the shape an operator is most likely to type.
: > "$CURL_LOG"
expect "...and so is --wsl --hold without --wait, which never reaches the WSL start" 1 "hold needs a WSL start" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" --wsl --hold rog
expect "...and --restart-wsl --hold without --wait" 1 "hold needs a WSL start" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" --restart-wsl --hold rog
[ ! -s "$CURL_LOG" ] && ok "...both before any packet goes out" || ko "a refused held wake still woke the box: $(cat "$CURL_LOG")"

# An unrecordable holder is a leaked one: nothing would ever unhold it, and the VM would stay
# pinned until the box reboots.
rm -rf "$TMP/state"; : > "$TMP/state"      # a FILE where the state directory should be
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'could NOT be recorded' <<<"$out" && grep -q 'wsl HOLD FAILED on: rog' <<<"$out" \
  && ok "a holder whose pid cannot be recorded is killed, not leaked, and the hold fails (rc=$rc)" \
  || ko "an unrecordable holder did not fail the hold (rc=$rc) -- $out"
leaked=$(sed -n 's/.*holder (pid \([0-9]*\)) killed.*/\1/p' <<<"$out" | head -1)
for _ in 1 2 3 4 5; do [ -n "$leaked" ] && kill -0 "$leaked" 2>/dev/null || break; sleep 1; done
if [ -n "$leaked" ] && ! kill -0 "$leaked" 2>/dev/null; then
  ok "...with that holder process (pid $leaked) really gone, not left pinning the VM"
else
  ko "the unrecorded holder is still running (pid ${leaked:-unnamed in the message})"
fi
rm -f "$TMP/state"

# The wake path carries the hold too, and its final verdict is the hold's as well.
wake_hold() { # wake_hold <tasklist output>
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_WAIT_SECONDS=1 WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/state" \
      SSH_UP="rog-lan rog-nv-wsl" SSH_TASKLIST="$1" SSH_HOLD_LIFE=20 \
      "$WL" --wait --restart-wsl --hold rog
}
rm -rf "$TMP/state"
out=$(wake_hold "$TASKLIST_HELD" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl holder observed on rog' <<<"$out" && grep -q '^all up$' <<<"${out##*$'\n'}" \
  && ok "--wait --restart-wsl --hold ends in all up with the holder observed (rc=$rc)" \
  || ko "the wake path did not hold the fresh VM (rc=$rc) -- $out"
rm -rf "$TMP/state"
out=$(wake_hold "$TASKLIST_EMPTY" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q '^all up$' <<<"$out" && grep -q 'NOT all up: wsl HOLD FAILED on: rog' <<<"${out##*$'\n'}" \
  && ok "...and is NOT all up when nothing holds the VM it just started (rc=$rc)" \
  || ko "the wake path said all up over an unheld VM (rc=$rc) -- $out"

# --- the Windows Update window ------------------------------------------------------------------
# KB5129195 restarted minix 21 min into its hip unit on 2026-09-15: active hours were 10:00-01:00
# and the sweep runs in the morning. The registry values are readable in advance from the -win
# side, so a feature update that resets them is a warning before the sweep, not a lost unit after.
reg_out() { # reg_out <start> <end> <smart> -- as `reg query` prints the key
  printf 'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\WindowsUpdate\\UX\\Settings\n'
  printf '    ActiveHoursStart    REG_DWORD    %s\n' "$1"
  printf '    ActiveHoursEnd    REG_DWORD    %s\n' "$2"
  printf '    SmartActiveHoursState    REG_DWORD    %s\n' "$3"
}
rm -rf "$TMP/state"; : > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out 0xa 0x1 0x0)" 2>&1)
grep -q 'ACTIVE HOURS WARNING on rog: sweep window 7-11 falls outside active hours 10-1' <<<"$out" \
  && grep -q 'uncovered hours: 7 8 9' <<<"$out" \
  && ok "the preflight warns when the sweep window falls outside active hours, naming the hours" \
  || ko "no active-hours warning for a 10-1 window against a 7-11 sweep -- $out"
grep -q 'reg query "HKLM\\SOFTWARE\\Microsoft\\WindowsUpdate\\UX\\Settings"' "$SSH_LOG" \
  && ok "...read from the UX\\Settings key on the Windows side" \
  || ko "the active-hours check did not query the registry key: $(cat "$SSH_LOG")"
# The quiet path: the 6-to-0 maximum the boxes now pin covers a morning sweep, and a check that
# warned there too would be one nobody reads.
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out 0x6 0x0 0x0)" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'active hours on rog: 6-0 cover the sweep window 7-11 (smart=0)' <<<"$out" \
  && ! grep -q 'ACTIVE HOURS WARNING' <<<"$out" \
  && ok "...and is quiet under the 6-to-0 maximum the boxes pin, reporting what it read (rc=$rc)" \
  || ko "the covered case warned, or said nothing about what it read (rc=$rc) -- $out"
# Smart active hours means Windows moves the window itself, so the pinned values are not in force.
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out 0x6 0x0 0x1)" 2>&1)
grep -q 'SmartActiveHoursState=1 lets Windows move them' <<<"$out" \
  && ok "...but warns when SmartActiveHoursState is on, whatever the values say" \
  || ko "a covered window with smart active hours on went unremarked -- $out"
# A window that wraps midnight is read on both sides of it.
out=$(env WAKE_LAB_SWEEP_HOURS=23-2 WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_WAIT_SECONDS=1 WAKE_LAB_HOLD_SETTLE_SECONDS=0 \
      WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="rog-lan rog-nv-wsl" \
      SSH_TASKLIST="$TASKLIST_HELD" SSH_REG="$(reg_out 0x6 0x0 0x0)" SSH_HOLD_LIFE=20 \
      "$WL" kick-wsl --hold rog 2>&1)
grep -q 'uncovered hours: 0 1' <<<"$out" && ! grep -q 'uncovered hours:.*23' <<<"$out" \
  && ok "...and a sweep window that wraps midnight is judged hour by hour across it" \
  || ko "a wrapping sweep window was misjudged -- $out"
# `08-11` is the natural way to write a morning window, and bash reads a leading zero as octal:
# the arithmetic would die on the 8 and abort a check that promises only to warn.
out=$(env WAKE_LAB_SWEEP_HOURS=08-11 WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_WAIT_SECONDS=1 WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/state" \
      SSH_UP="rog-lan rog-nv-wsl" SSH_TASKLIST="$TASKLIST_HELD" SSH_REG="$(reg_out 0xa 0x1 0x0)" \
      SSH_HOLD_LIFE=20 "$WL" kick-wsl --hold rog 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'uncovered hours: 8 9' <<<"$out" && ! grep -qi 'value too great\|base' <<<"$out" \
  && ok "...and a zero-padded sweep window is read as decimal, not as octal (rc=$rc)" \
  || ko "a zero-padded window aborted the warn-only check (rc=$rc) -- $out"
# Unreadable is its own answer: the box may still be swept, but nothing is known about its updates.
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'ACTIVE HOURS WARNING on rog: could not read ActiveHoursStart/End' <<<"$out" \
  && ok "an unreadable registry warns without failing the hold (rc=$rc)" \
  || ko "an unreadable registry was silent, or failed the hold (rc=$rc) -- $out"

# status reports the same window, which is where a human asks whether the fleet is fit for tonight.
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" SSH_UP="rog-lan" SSH_REG="$(reg_out 0xa 0x1 0x0)" "$WL" status rog 2>&1)
grep -q 'Windows Update window' <<<"$out" \
  && grep -q 'ACTIVE HOURS WARNING on rog: sweep window 7-11 falls outside active hours 10-1' <<<"$out" \
  && ok "status carries the active-hours reading for each box" \
  || ko "status does not report the update window -- $out"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" status rog 2>&1)
grep -q 'active hours on rog: not read (no Windows endpoint answered)' <<<"$out" \
  && ! grep -q 'ACTIVE HOURS WARNING' <<<"$out" \
  && ok "...and a box that is down has no reading rather than a warning about its settings" \
  || ko "status warned about the settings of a box it could not reach -- $out"

# --- the polling loops are bounded by elapsed time, not by iteration count -----------------------
# Every probe of a dark box burns its ConnectTimeout, so an iteration budget was a wall-clock lie:
# 36 rounds of a "3 minute" WSL wait ran for nine when the probes were slow. Three-second probes
# against a one-second budget: a loop counting iterations would run for minutes here.
started=$SECONDS
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_DELAY=3 "$WL" kick-wsl rog >/dev/null 2>&1
elapsed=$((SECONDS - started))
[ "$elapsed" -lt 30 ] && ok "a WSL wait with slow probes honours its deadline (${elapsed}s)" \
  || ko "the WSL wait ran ${elapsed}s against a 1s budget: it is still counting iterations"
started=$SECONDS
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 SSH_DELAY=3 "$WL" --wait rog 2>&1); wake_rc=$?
elapsed=$((SECONDS - started))
[ "$elapsed" -lt 30 ] && ok "...and so does the wake wait (${elapsed}s)" \
  || ko "the wake wait ran ${elapsed}s against a 1s budget: it is still counting iterations"
grep -q 'did NOT wake: rog' <<<"$out" \
  && ok "...reporting the box that never came up" || ko "no 'did NOT wake' after the budget -- $out"
grep -q 'scripts/enable-wol-windows.ps1' <<<"$out" \
  && ok "...and points failure advice at the tracked Windows repair script" \
  || ko "wake failure advice does not name scripts/enable-wol-windows.ps1 -- $out"
[ "$wake_rc" -ne 0 ] && ok "...and exits nonzero (rc=$wake_rc)" || ko "a wake that timed out exited 0"

# --- the two commands that need no site data --------------------------------------------------
# --help and --list are what you reach for on a box where the table has yet to be installed, so
# they must work before it exists.
expect "--help works with no host table" 0 "Drive the home-lab machines" -- \
  env WAKE_LAB_HOSTS="$TMP/absent.sh" "$WL" --help
expect "--list works with no host table" 0 "active" -- \
  env CURL_REPLY=hosts WAKE_LAB_HOSTS="$TMP/absent.sh" "$WL" --list

# --- the --help range ---------------------------------------------------------------------------
# Computed here in awk against the script itself: the whole leading comment block, ending at the
# first non-comment line. A range that stops earlier -- the `2,20p` this replaced -- drops the
# lines a header grew, and does it silently.
head_block=$(awk 'NR == 1 { next } !/^#/ { exit } { print }' "$WL")
help_out=$(env WAKE_LAB_HOSTS="$TMP/absent.sh" "$WL" --help)
[ "$help_out" = "$head_block" ] && ok "--help prints the header block entire, to its last line" \
  || ko "--help is not the header block: $(diff <(printf '%s\n' "$head_block") <(printf '%s\n' "$help_out") | sed -n '1,5p')"
grep -q 'set -u' <<<"$help_out" \
  && ko "--help ran past the header into the script" || ok "...and stops at the first non-comment line"
[ "$(printf '%s\n' "$head_block" | wc -l)" -gt 19 ] \
  && ok "...on a header already longer than the old 2,20p range" \
  || ko "the header is short enough that the old truncating range would still pass; the guard above proves nothing"

# --- the example table is a working one ---------------------------------------------------------
expect "the example host table satisfies the contract" 0 "router-active=1" -- \
  env WAKE_LAB_HOSTS="$EXAMPLE" "$WL" status rog

# --- no hardware addresses in the repository ----------------------------------------------------
# The point of the split. Anything MAC-shaped in a tracked file is a leak, except the example
# file's 00:00:00 placeholders (and this script's own aa:bb:cc fixtures, which name no hardware).
# Both separators, because magic_packet() strips `:` and `-` alike: a MAC pasted in with hyphens,
# the spelling Windows prints, is every bit as much a leak as the colon-separated one, and a guard
# that reads only half of what the script accepts promises more than it checks. Each hit is printed as `file:line:<address>`,
# so the placeholder filter can anchor on the address itself: a line carrying both a placeholder
# and a real MAC still reports the real one.
mac_hits() { # mac_hits <file...> -- the MAC-shaped literals in those files, placeholders aside
  grep -oHInEi -- '([0-9a-f]{2}[:-]){5}[0-9a-f]{2}' "$@" 2>/dev/null \
    | grep -vEi '(00[:-]00[:-]00|aa[:-]bb[:-]cc)([:-][0-9a-f]{2}){3}$'
}
# The negative control: a scan that cannot fail proves nothing, and this one is two greps deep.
# Assembled at runtime, because a real-shaped address written out here would be a hit itself.
for sep in : -; do
  leak_mac=$(printf 'de%sad%sbe%sef%s12%s34' "$sep" "$sep" "$sep" "$sep" "$sep")
  printf 'eth_mac_of() { echo %s; }\n' "$leak_mac" > "$TMP/leaky.sh"
  [ -n "$(mac_hits "$TMP/leaky.sh")" ] && ok "the MAC scan catches a real-shaped address ($sep)" \
    || ko "the MAC scan does not catch $leak_mac, so its verdict below means nothing"
done
[ -z "$(mac_hits "$EXAMPLE")" ] && ok "...and passes the example file's placeholders" \
  || ko "the example file carries a non-placeholder MAC: $(mac_hits "$EXAMPLE")"
# The template's IPs are site data too if they are the author's leases. RFC 5737's 192.0.2.0/24 is
# the documentation range; anything in a private range here is a real address someone copied in.
ex_ips=$(grep -oE '\b(10|127|192\.168|172\.(1[6-9]|2[0-9]|3[01]))\.[0-9]+\.[0-9]+\b' "$EXAMPLE")
[ -z "$ex_ips" ] && ok "...and the example's IPs are documentation addresses, not a real LAN" \
  || ko "the example file carries private-range addresses: $ex_ips"

# Tracked files, so a leak is judged by what the repository would publish. Before the first
# commit of a new script `git ls-files` does not list it yet; scan scripts/ as well, always.
tracked=$(cd "$HERE/.." && git ls-files 2>/dev/null | sed "s|^|$(cd "$HERE/.." && pwd)/|")
[ -n "$tracked" ] && ok "the repository's tracked files are readable to scan" \
  || ko "git ls-files came back empty -- the scan below covers only scripts/"
leaks=$(printf '%s\n%s\n' "$tracked" "$(ls -d "$HERE"/*.sh)" | sort -u | grep -v '^$' | while read -r f; do
  [ -f "$f" ] && mac_hits "$f"
done)
if [ -z "$leaks" ]; then ok "no MAC address is tracked in the repository"
else ko "MAC-shaped literals in tracked files:"; printf '%s\n' "$leaks"; fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
