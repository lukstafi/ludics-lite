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
# `wsl.exe --shutdown` fails, say. $SSH_HANG is an extended regex over the whole `<dest> :: <cmd>`
# line, and a match WEDGES instead of answering -- the 2026-09-16 shape, where the far side
# accepts the connection and the remote command never returns, which ConnectTimeout does not bound
# and only the script's own cap can end. A regex rather than a substring because the cases below
# need to wedge one box's Windows aliases while leaving its guest and its neighbour answering. It
# is an `exec sleep`, not a `sleep`, so that the cap's SIGALRM lands on the sleeping process itself
# rather than on a shell waiting for a foreground child.
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
line=$(printf '%s ::%s' "$dest" "$cmd")
printf '%s\n' "$line" >> "$SSH_LOG"
# $LOCK_PROBE names a lock file to test AT THE MOMENT a shutdown is issued, which is the only way
# to observe the check/act race from outside: a restarter that merely probed the lock leaves it
# free by the time the shutdown lands, and one that holds it does not.
if [ -n "${LOCK_PROBE:-}" ]; then
  case "$cmd" in
    *--shutdown*)
      if perl -e 'use Fcntl ":flock"; exit(flock(STDIN, LOCK_EX | LOCK_NB) ? 0 : 1)' \
           <"$LOCK_PROBE" 2>/dev/null
      then printf 'lock FREE during shutdown\n' >> "$SSH_LOG"
      else printf 'lock HELD during shutdown\n' >> "$SSH_LOG"; fi ;;
  esac
fi
[ -n "${SSH_DELAY:-}" ] && sleep "$SSH_DELAY"
[ -n "${SSH_HANG:-}" ] && grep -qE "$SSH_HANG" <<<"$line" && exec sleep 900
case "$cmd" in *"${SSH_REFUSE:-}"*) [ -n "${SSH_REFUSE:-}" ] && exit 1 ;; esac
for u in ${SSH_UP:-}; do [ "$u" = "$dest" ] && exit 0; done
exit 1
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

# --- a wedged wsl.exe is bounded, and the guest is what settles it ------------------------------
# 2026-09-16: `--wait --restart-wsl rog minix` ran 2h40m without exiting. ssh's ConnectTimeout
# bounds the TCP connect alone, so once the Windows side accepted the connection and `wsl.exe -d
# Ubuntu -e true` wedged, the ssh had no upper bound at all -- and the scheduled sweep that called
# it hung behind it. Each remote command now runs under a wall-clock cap. The caps are cut to a
# few seconds here; the shim wedges with `exec sleep 900`, so a run that still finishes proves the
# cap fired and nothing else.
hang() { # hang <regex> <up-list> <verb...> -- a restart with some remote commands wedged
  local re=$1 up=$2; shift 2
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 \
      WAKE_LAB_WSL_SHUTDOWN_CAP=3 WAKE_LAB_WSL_START_CAP=3 WAKE_LAB_PROBE_CAP=3 \
      SSH_HANG="$re" SSH_UP="$up" "$WL" "$@"
}
# The incident's own shape, and its own resolution: the start probe never returns, and the VM has
# in fact started -- `uptime -p` inside rog's guest matched the restart to the minute while the
# Windows-side probe was still stuck. So the cap is not a failure. The guest is asked directly over
# the -wsl alias, which answered instantly throughout that morning, and its answer is the verdict.
: > "$SSH_LOG"; started=$SECONDS
out=$(hang '^rog-lan :: wsl\.exe -d Ubuntu' "rog-lan rog-nv-win rog-nv-wsl" restart-wsl rog 2>&1); rc=$?
elapsed=$((SECONDS - started))
[ "$elapsed" -lt 30 ] && ok "a wedged start probe is cut short by its cap instead of hanging (${elapsed}s)" \
  || ko "the run took ${elapsed}s against a 3s cap: the remote command is still unbounded"
[ "$rc" -eq 0 ] && grep -q 'wsl start probe timed out after 3s on rog (via rog-lan); the guest answers, so the VM is up' <<<"$out" \
  && grep -q 'wsl up' <<<"$out" \
  && ok "...and a guest that answers over its own alias settles it as up, not as a failed restart (rc=$rc)" \
  || ko "a capped start probe over a live guest did not read as up (rc=$rc) -- $out"
grep -q '^rog-nv-wsl :: exit 0$' "$SSH_LOG" \
  && ok "...having really asked the guest, over the -wsl alias the wedged Windows side is not on" \
  || ko "the guest was never probed after the cap fired: $(cat "$SSH_LOG")"
# With no guest answering there is no verdict yet, and the poll already has one: it asks the guest,
# on its own deadline. What must NOT happen is a fall through to the next alias -- in the restart
# path that is a second `wsl --shutdown`, tearing down the VM the wedged start may just have booted.
: > "$SSH_LOG"
out=$(hang 'wsl\.exe -d Ubuntu' "rog-lan rog-nv-win" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'leaving the verdict to the guest poll' <<<"$out" \
  && grep -q 'wsl still down after 0 min on: rog' <<<"${out##*$'\n'}" && ! grep -q 'wsl up' <<<"$out" \
  && ok "...while a capped start with a silent guest is left to the poll, which fails it (rc=$rc)" \
  || ko "a capped start with no guest answering was not left to the poll (rc=$rc) -- $out"
[ "$(grep -c -- 'wsl.exe --shutdown' "$SSH_LOG")" -eq 1 ] \
  && ok "...and no second shutdown is issued onto the VM that start may have booted" \
  || ko "the capped start retried the whole restart on the next alias: $(cat "$SSH_LOG")"
# A wedged `wsl --shutdown` is the dangerous one: its status says nothing, and the restart's whole
# invariant is that no live old VM survives it. So the guest decides again -- and here it decides
# against. A guest still answering means the teardown has not taken, this alias has not carried the
# restart, and no start may be issued onto the VM left standing.
: > "$SSH_LOG"
out=$(hang 'wsl\.exe --shutdown' "rog-lan rog-nv-win rog-nv-wsl" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl shutdown TIMED OUT after 3s on rog (via rog-lan); the guest still answers, so the old VM stands' <<<"$out" \
  && grep -q 'wsl restart FAILED on: rog (shutdown refused' <<<"${out##*$'\n'}" && ! grep -q 'wsl up' <<<"$out" \
  && ok "a wedged shutdown over a guest that still answers is a failed restart, never 'wsl up' (rc=$rc)" \
  || ko "a capped shutdown over a live old guest read as success (rc=$rc) -- $out"
grep -q 'wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ko "a start was issued onto the VM the capped shutdown left standing: $(cat "$SSH_LOG")" \
  || ok "...and no start is issued onto it"
# A SILENT guest is not the opposite evidence, and reading it that way was a real defect (PR #165
# round 1, P1). The -wsl alias rides tailscaled inside the guest, which this suite's own subject
# documents as lagging minutes behind a running VM, so "no guest answers" is the everyday reading
# of a VM that is perfectly alive. Starting on it attaches to the old VM and then reports the
# fresh restart the sweep waits for -- the stale bridge restart-wsl exists to replace. So a capped
# shutdown is unconfirmed whichever way the guest goes, and NO start may follow it on that alias.
: > "$SSH_LOG"
out=$(hang 'wsl\.exe --shutdown' "rog-lan rog-nv-win" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'no guest answers, but a silent guest is not a stopped VM — the teardown is unconfirmed' <<<"$out" \
  && ! grep -q 'wsl up' <<<"$out" && grep -q 'wsl restart FAILED on: rog (shutdown refused' <<<"${out##*$'\n'}" \
  && ok "a capped shutdown is unconfirmed even with a silent guest, and fails the restart (rc=$rc)" \
  || ko "a capped shutdown with a silent guest was treated as a teardown (rc=$rc) -- $out"
grep -q 'wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ko "a start was issued after a shutdown that was never confirmed: $(cat "$SSH_LOG")" \
  || ok "...issuing no start on evidence that cannot tell a stopped VM from a lagging tailscaled"
grep -c -- 'wsl.exe --shutdown' "$SSH_LOG" | grep -qx 2 \
  && ok "...and retrying the whole restart on the other alias first" \
  || ko "the capped shutdown did not fall through to the second alias: $(cat "$SSH_LOG")"

# A plain kick has no shutdown to repeat and a second start is idempotent, so a wedged LAN side
# must not cost the box the start its Tailscale alias would have carried (PR #165 round 1, P2).
# The restart path keeps the opposite rule, pinned above: it must NOT fall through.
# The guest must be SILENT here: a guest that answers settles the cap on the spot, and the
# fallback this pins exists only for the case where nothing has answered yet. The poll then fails
# the step (no guest ever answers in this fixture), so the evidence is the start on the second
# alias, not the exit status.
: > "$SSH_LOG"
out=$(hang '^rog-lan :: wsl\.exe -d Ubuntu' "rog-lan rog-nv-win" kick-wsl rog 2>&1)
grep -q 'wsl started on rog (via rog-nv-win)' <<<"$out" \
  && grep -q '^rog-nv-win :: wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ok "a plain kick whose start wedges on one alias is carried by the other" \
  || ko "a wedged plain kick never tried the second alias -- $out; $(cat "$SSH_LOG")"
# And when every alias wedges, the cap is still not a failure: the poll gets the box.
: > "$SSH_LOG"
out=$(hang 'wsl\.exe -d Ubuntu' "rog-lan rog-nv-win" kick-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'start probe timed out on every alias on rog' <<<"$out" \
  && grep -q 'wsl still down after 0 min on: rog' <<<"${out##*$'\n'}" \
  && ok "...and a kick that wedges on every alias is left to the poll, not called a failed kick (rc=$rc)" \
  || ko "a kick wedged on every alias was not handed to the poll (rc=$rc) -- $out"

# --- one wedged box must not cost its neighbours their restart ----------------------------------
# The second half of the 2026-09-16 damage. The loop over boxes was serialized, so while rog's
# probe hung minix never got a restart at all: its VM sat eleven hours old and the sweep's hip unit
# went red on exactly the stale-dxg condition restart-wsl exists to clear (ludics-lite#60).
: > "$SSH_LOG"
out=$(hang '^rog-(lan|nv-win) :: wsl\.exe' "rog-lan rog-nv-win minix-lan minix-amd-wsl" restart-wsl rog minix 2>&1); rc=$?
grep -q '^minix-lan :: wsl.exe --shutdown$' "$SSH_LOG" && grep -q '^minix-lan :: wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ok "a box whose Windows side wedges does not stop its neighbour getting its restart" \
  || ko "minix never got its restart while rog was wedged: $(cat "$SSH_LOG")"
# rog's own outcome is a shutdown failure -- its capped shutdown is unconfirmed on both aliases,
# which is the P1 rule above -- while minix's is a clean restart. Each box is named for what
# happened to IT; the wedge is not charged to the neighbour.
[ "$rc" -ne 0 ] && grep -q '^wsl up on: minix$' <<<"$out" && grep -q 'wsl restart FAILED on: rog' <<<"$out" \
  && ok "...and the report still names each box's own outcome (rc=$rc)" \
  || ko "the wedged box's outcome was pinned on its neighbour (rc=$rc) -- $out"
# ...and they really are kicked at once, not merely bounded one after another: two boxes wedged
# against a 12s cap cost one cap between them concurrently and two serialized. The numbers have to
# respect the poll's 5s granularity, because a guest probe that misses its first round adds
# exactly one of those to either arm: concurrent is 12s or 17s, serialized 24s or 29s, so 20s is
# the only threshold with a clear margin on both sides. And PROBE_CAP is left at its default --
# shrinking it to a couple of seconds, as the wedge cases above can afford to, is what makes that
# missed round likely in the first place: on a loaded machine the shim's own fork can outlast a 3s
# cap, and the probe then fails for reasons that have nothing to do with what is being measured.
started=$SECONDS
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_WSL_START_CAP=12 \
    SSH_HANG='wsl\.exe -d Ubuntu' SSH_UP="rog-lan minix-lan rog-nv-wsl minix-amd-wsl" \
    "$WL" kick-wsl rog minix 2>&1); rc=$?
elapsed=$((SECONDS - started))
[ "$rc" -eq 0 ] && grep -q '^wsl up$' <<<"$out" \
  && ok "two wedged start probes both fall back to their own guest (rc=$rc)" \
  || ko "the two-box fallback did not end in wsl up (rc=$rc) -- $out"
[ "$elapsed" -lt 20 ] && ok "...costing one cap between them, not one each (${elapsed}s)" \
  || ko "the kick still runs box by box: ${elapsed}s for two boxes against a 12s cap"

# --- a capped call leaves nothing of itself behind ----------------------------------------------
# capped()'s watchdog naps in a child. Killing the watchdog alone left that nap orphaned for the
# rest of its interval -- two minutes, at the default start cap -- holding an inherited copy of
# every descriptor the run had open. Stray processes were the visible half; the half that bites is
# that an inherited descriptor keeps its resource alive after the caller has dropped it, which is
# how this surfaced against the lab lock. The caps here are absurd values (3117/3118/3119) so a
# survivor is unmistakably one of ours and no real sleep can be mistaken for it.
naps() { ps -eo pid,command 2>/dev/null | awk '/sleep 311[789]$/ { print $1 }'; }
reap_naps() { local p; for p in $(naps); do kill -KILL "$p" 2>/dev/null; done; }
# The negative control first: a scan that cannot fail proves nothing. This is exactly the old
# shape -- a watchdog whose sleep runs in its foreground, killed outright -- and it must leave a
# survivor, or the assertion below is vacuous.
reap_naps
( cmd_pid=""; sleep 1 & cmd_pid=$!
  { sleep 3117; } >/dev/null 2>&1 & dog=$!
  wait "$cmd_pid"; kill -KILL "$dog" 2>/dev/null; wait "$dog" 2>/dev/null ) >/dev/null 2>&1
[ "$(naps | wc -l | tr -d ' ')" -ge 1 ] \
  && ok "the stray-nap scan catches a watchdog killed without its sleep" \
  || ko "the stray-nap scan sees nothing even for the leaking shape, so its verdict below is vacuous"
reap_naps
# A restart makes several capped calls -- a shutdown, a start, and the probes around them -- and
# every one of them must come back with its watchdog fully reaped.
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 \
    WAKE_LAB_WSL_SHUTDOWN_CAP=3118 WAKE_LAB_WSL_START_CAP=3117 WAKE_LAB_PROBE_CAP=3119 \
    SSH_UP="rog-lan rog-nv-wsl" "$WL" restart-wsl rog >/dev/null 2>&1
[ "$(naps | wc -l | tr -d ' ')" -eq 0 ] \
  && ok "...and a restart's capped calls leave no nap of their own behind" \
  || ko "a capped call orphaned its watchdog's sleep: $(ps -eo pid,command | awk '/sleep 311[789]$/')"
reap_naps
# The same when the cap actually FIRES: the watchdog is then mid-grace, napping again, and the old
# shape leaked that second sleep just as readily as the first.
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_WSL_START_CAP=2 \
    WAKE_LAB_WSL_SHUTDOWN_CAP=3118 WAKE_LAB_PROBE_CAP=3119 \
    SSH_HANG='wsl\.exe -d Ubuntu' SSH_UP="rog-lan rog-nv-win" "$WL" restart-wsl rog >/dev/null 2>&1
[ "$(naps | wc -l | tr -d ' ')" -eq 0 ] \
  && ok "...nor does one whose cap fired and whose watchdog was mid-grace" \
  || ko "a fired cap orphaned its grace sleep: $(ps -eo pid,command | awk '/sleep 311[789]$/')"
reap_naps

# --- the lab lock stops a restart destroying someone else's VM ----------------------------------
# 2026-09-16, the third and most expensive shape of the same day: `wsl.exe --shutdown` is
# host-global, so a restart issued while the cross-machine sweep was 13 minutes into rog-nv/cuda
# and minix/hip destroyed both VMs and both units. The sweep recorded `error`, which reads as a box
# fault, and it was misattributed to the GPU autotune tests for two days. The lock is the interlock
# that was missing; these cases pin that it actually refuses, and that it refuses ONLY the
# destructive path.
LOCKS="$TMP/locks"; mkdir -p "$LOCKS"
# Held the way the sweep holds it: a descriptor kept open, flock taken by a perl that exits. The
# lock belongs to the open file description, so it outlives that perl and dies with this shell --
# which is the property the whole contract rests on, so take it here exactly as the real holder does
# rather than simulating a held lock with a flag file.
hold_lock() { # hold_lock <box> <description>
  printf '%s\n' "$2" > "$LOCKS/$1.lock"
  eval "exec $3>>\"$LOCKS/$1.lock\""
  perl -e 'use Fcntl ":flock"; exit(flock(STDIN, LOCK_EX | LOCK_NB) ? 0 : 1)' <&"$3"
}
wl_locked() { # wl_locked <args...> -- a run with both boxes' guests answering and the lock dir live
  # `8>&-`: the checker must not inherit the HOLDER's descriptor. An flock lives until every
  # descriptor onto that open file description is closed, so a child that inherited one keeps the
  # lock alive after the holder let go -- and wake-lab's own `capped` leaves its watchdog `sleep`
  # orphaned for the length of the cap, which would hold this test's lock for two minutes after
  # `exec 8>&-`. In production the checker is a separate process that never had the descriptor at
  # all, so closing it here is what models the real thing; the case below pins the property itself.
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_WSL_WAIT_SECONDS=1 \
      SSH_UP="rog-lan minix-lan rog-nv-wsl minix-amd-wsl" "$WL" "$@" 2>&1 8>&-
}
if hold_lock minix 'sweep 20260916T074913Z (pid 999, since 20260916T074913Z)' 8; then
  ok "the lab lock can be taken the way a harness takes it"
else
  ko "could not take a test lab lock -- the cases below prove nothing"
fi

: > "$SSH_LOG"
out=$(wl_locked restart-wsl rog minix); rc=$?
grep -q '^minix-lan :: wsl.exe --shutdown$' "$SSH_LOG" \
  && ko "a held box was shut down anyway -- the interlock does not hold: $(cat "$SSH_LOG")" \
  || ok "a restart does not shut down a box whose lab lock is held"
[ "$rc" -ne 0 ] && grep -q 'REFUSED on: minix' <<<"$out" \
  && ok "...and the step FAILS rather than reporting a fresh VM it did not make (rc=$rc)" \
  || ko "a refused box did not fail the step (rc=$rc) -- $out"
grep -q 'sweep 20260916T074913Z' <<<"$out" \
  && ok "...and the refusal names the holder, so the operator knows what to wait for" \
  || ko "the refusal does not say who holds the box -- $out"
# The neighbour rule of the wedge cases above, applied to the lock: one held box must not cost the
# others their restart, and `wsl up` must never appear unqualified over a box that was refused.
grep -q '^rog-lan :: wsl.exe --shutdown$' "$SSH_LOG" \
  && ok "...and its neighbour still gets its restart" \
  || ko "a held box cost its neighbour the restart: $(cat "$SSH_LOG")"
grep -q '^wsl up$' <<<"$out" \
  && ko "the run claimed a blanket 'wsl up' over a refused box -- $out" \
  || ok "...and the verdict is never a blanket 'wsl up' while a box was refused"

# --force is the override, and it is the ONLY thing that takes a held box.
: > "$SSH_LOG"
out=$(wl_locked restart-wsl --force minix); rc=$?
[ "$rc" -eq 0 ] && grep -q '^minix-lan :: wsl.exe --shutdown$' "$SSH_LOG" \
  && ok "--force takes a held box anyway (rc=$rc)" \
  || ko "--force did not override the lock (rc=$rc) -- $out"

# A plain kick starts a VM that is already running as a no-op: it cannot cost a holder anything,
# and gating it would make `kick-wsl` -- the recovery command for a box with no VM at all --
# refusable at exactly the moment it is needed.
: > "$SSH_LOG"
out=$(wl_locked kick-wsl minix); rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'shutdown' "$SSH_LOG" \
  && ok "a plain kick is not gated by the lock, and still shuts nothing down (rc=$rc)" \
  || ko "the lock gated a non-destructive kick (rc=$rc) -- $out $(cat "$SSH_LOG")"

# A free box is the ordinary case and must be untouched by any of this.
: > "$SSH_LOG"
out=$(wl_locked restart-wsl rog); rc=$?
[ "$rc" -eq 0 ] && grep -q '^wsl up$' <<<"$out" \
  && ok "a box whose lock is free restarts exactly as before (rc=$rc)" \
  || ko "the lock broke the ordinary restart (rc=$rc) -- $out"

# An INHERITED descriptor holds the lock too, and that is the semantics to want rather than a
# wart: a child still talking to the box means the box is still in use, so it stays reserved. It is
# also the sweep's own run lock's behaviour, where an orphaned dune keeping the worktree locked is
# documented as correct. The consequence to know is that a holder's lock outlives it for as long as
# any inheriting child runs, and `--force` is the way past one that has outstayed its welcome.
sleep 30 8>&8 &
inheritor=$!
exec 8>&-
out=$(wl_locked restart-wsl minix); rc=$?
[ "$rc" -ne 0 ] && grep -q 'REFUSED on: minix' <<<"$out" \
  && ok "a child that inherited the descriptor keeps the box reserved (rc=$rc)" \
  || ko "the lock died while an inheriting child was still running (rc=$rc) -- $out"
expect "...and --force is the way past it" 0 "wsl up" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_WSL_WAIT_SECONDS=1 \
      SSH_UP="rog-lan minix-lan rog-nv-wsl minix-amd-wsl" "$WL" restart-wsl --force minix

# Released with the holder: the sweep's lock dies with the sweep however it dies, which is why
# there is nothing to reclaim after a crash.
kill -KILL "$inheritor" 2>/dev/null; wait "$inheritor" 2>/dev/null
out=$(wl_locked restart-wsl minix); rc=$?
[ "$rc" -eq 0 ] \
  && ok "...and a lock whose holders are all gone stops refusing, with nothing to reclaim (rc=$rc)" \
  || ko "a released lock still refuses (rc=$rc) -- $out"

# The reservation is HELD ACROSS the shutdown, not checked before it. A restarter that only probes
# the lock leaves a window between its check and its `wsl.exe --shutdown` — and a holder that
# reserves the box inside that window is destroyed by a restart that had already decided it was
# allowed to proceed, which is the exact race the interlock exists to close. Observed from the far
# side: the ssh shim tests the lock at the instant the shutdown is issued.
: > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_WSL_WAIT_SECONDS=1 \
    SSH_UP="rog-lan minix-lan rog-nv-wsl minix-amd-wsl" LOCK_PROBE="$LOCKS/rog.lock" \
    "$WL" restart-wsl rog 2>&1 8>&-); rc=$?
grep -q '^lock HELD during shutdown$' "$SSH_LOG" \
  && ok "the box stays reserved for the length of its own restart (rc=$rc)" \
  || ko "the lock was free when the shutdown landed — the check/act race is open: $(cat "$SSH_LOG")"

# Power actions take the box away just as surely: hibernate terminates the VM outright, `down` is a
# full host shutdown, and `sleep` suspends the host under whatever is running on it.
if hold_lock minix 'sweep 20260916T074913Z (pid 999, since 20260916T074913Z)' 8; then
  ok "the lab lock can be retaken for the power-action cases"
else
  ko "could not retake a test lab lock -- the power cases below prove nothing"
fi
for verb in hibernate down sleep; do
  : > "$SSH_LOG"
  out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" \
      SSH_UP="minix-lan minix-amd-win" "$WL" "$verb" minix 2>&1 8>&-); rc=$?
  if [ "$rc" -ne 0 ] && grep -q "$verb REFUSED on: minix" <<<"$out" && ! grep -q 'shutdown /\|SetSuspendState' "$SSH_LOG"; then
    ok "$verb refuses a reserved box, and sends nothing (rc=$rc)"
  else
    ko "$verb went through on a reserved box (rc=$rc) -- $out $(cat "$SSH_LOG")"
  fi
done
# ...and a refused box is not then polled for the DOWN signal, which would report the holder's
# live machine as a failure to go down.
grep -q 'confirming' <<<"$out" \
  && ko "a refused box was polled for the down signal -- $out" \
  || ok "...and a refused box is not confirmed down"
# --force is the same override here as everywhere else.
: > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" \
    SSH_UP="minix-lan minix-amd-win" "$WL" hibernate --force minix 2>&1 8>&-); rc=$?
grep -q 'shutdown /h' "$SSH_LOG" \
  && ok "--force hibernates a reserved box anyway (rc=$rc)" \
  || ko "--force did not override the lock for a power action (rc=$rc) -- $out $(cat "$SSH_LOG")"
# A free box is unaffected.
: > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" \
    SSH_UP="rog-lan rog-nv-win" "$WL" hibernate rog 2>&1 8>&-); rc=$?
grep -q 'shutdown /h' "$SSH_LOG" && grep -q 'confirming' <<<"$out" \
  && ok "a box whose lock is free hibernates exactly as before (rc=$rc)" \
  || ko "the lock broke the ordinary power action (rc=$rc) -- $out $(cat "$SSH_LOG")"
exec 8>&-

# The path is the whole contract with the sweep, so it must not need the site table: the harness
# asking where to put its flock runs from a checkout with no business holding this lab's MACs.
out=$(env WAKE_LAB_HOSTS="$TMP/absent.sh" WAKE_LAB_LOCK_DIR="$LOCKS" "$WL" lock-path minix 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "$LOCKS/minix.lock" ] \
  && ok "lock-path answers without the site file, at the path the holder must take (rc=$rc)" \
  || ko "lock-path did not answer the contract path without hosts.sh (rc=$rc) -- $out"

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
