#!/usr/bin/env bash
# Exercises wake-lab.sh with shim `curl`/`python3`/`ssh` on PATH -- no router, no network, no
# ssh. What it pins is what ludics-lite#31 split the script into: the tracked half (the lore, the
# router endpoints, the aliases, the dispatch) must carry no hardware addresses, and the untracked
# half (~/.config/wake-lab/hosts.sh) must be what every MAC actually comes from. It also pins the
# `--help` range, which used to be the hard-coded `2,20p` that silently truncated a grown header.
#
# Usage: test-wake-lab.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

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
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -q -- "$want"; then ok "$label"
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
printf '%s' "$out" | grep -q 'wake-lab-hosts.example.sh' \
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
printf '%s' "$out" | grep -q 'aa:bb:cc:00:00:01' \
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
printf '%s' "$out" | grep -q "NewActive bit for the Ethernet MAC, not the NIC's link state" \
  && ok "...and says the column is the router's NewActive bit, not link state" \
  || ko "status does not say what router-active reads -- $out"
printf '%s' "$out" | grep -q 'stale DHCP lease' && printf '%s' "$out" | grep -q 'once settled' \
  && ok "...telling a stale lease from the settled powered-off state" \
  || ko "status does not carry the stale-lease-vs-settled caveat -- $out"
printf '%s' "$out" | grep -qE 'eth-link|(^|[^-])link=' \
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
printf '%s' "$out" | grep -q 'wsl started on rog (via rog-lan)' \
  && ok "the WSL kick goes through the LAN alias when Tailscale has not caught up" \
  || ko "the kick did not use the LAN alias -- $out"
grep -q '^rog-lan :: wsl.exe' "$SSH_LOG" \
  && ok "...carrying the wsl.exe start command" || ko "no wsl.exe over rog-lan: $(cat "$SSH_LOG")"
out=$(kick "rog-nv-win rog-nv-wsl" 2>&1)
printf '%s' "$out" | grep -q 'wsl started on rog (via rog-nv-win)' \
  && ok "...and falls back to the Tailscale alias when the LAN one is silent" \
  || ko "no fallback to the Tailscale alias -- $out"
out=$(kick "" 2>&1)
printf '%s' "$out" | grep -q 'wsl kick FAILED on rog' \
  && ok "...and reports a box no endpoint answers for" || ko "a kick with nothing up did not fail -- $out"

# --- restart-wsl shuts the VM down on the Windows host before starting it ---------------------
# A VM kept alive across a host sleep/resume can carry a degraded dxg bridge that fails under the
# sweep's parallel width while every single-process probe passes (ludics-lite#60). The cure is a
# new VM, and `wsl --shutdown` belongs on the Windows side: issued inside the VM it kills the
# session issuing it. So the restart rides the same -lan/-win aliases as the kick, never -wsl.
restart() { env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="$1" "$WL" restart-wsl rog; }
: > "$SSH_LOG"
out=$(restart "rog-lan rog-nv-wsl" 2>&1)
printf '%s' "$out" | grep -q 'wsl shut down on rog (via rog-lan)' \
  && printf '%s' "$out" | grep -q 'wsl started on rog (via rog-lan)' \
  && ok "restart-wsl shuts the VM down and starts it again, over the LAN alias" \
  || ko "restart-wsl did not report a shutdown and a start -- $out"
awk '/^rog-lan :: wsl.exe --shutdown$/ { s = NR } /^rog-lan :: wsl.exe -d Ubuntu/ { t = NR } END { exit !(s && t && s < t) }' "$SSH_LOG" \
  && ok "...issuing wsl.exe --shutdown on the Windows host before the start" \
  || ko "no shutdown ahead of the start over rog-lan: $(cat "$SSH_LOG")"
grep -q '^rog-nv-wsl :: wsl.exe' "$SSH_LOG" \
  && ko "a wsl.exe command reached the -wsl guest, where a shutdown kills its own session: $(cat "$SSH_LOG")" \
  || ok "...and never through the -wsl guest"
out=$(restart "" 2>&1)
printf '%s' "$out" | grep -q 'wsl restart FAILED on rog' \
  && ok "...and reports a box no endpoint answers for as a failed restart" || ko "a restart with nothing up did not fail -- $out"
# A restart's success is the restart's own status, never the guest's liveness: when the shutdown
# fails, the -wsl guest that still answers is the OLD VM, and `wsl up` over it would send the sweep
# onto exactly the degraded bridge the restart exists to replace. Two shapes of that: no Windows
# endpoint answers while the guest does, and the endpoints answer but the shutdown itself fails.
out=$(restart "rog-nv-wsl" 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'wsl restart FAILED on: rog' && ! printf '%s' "$out" | grep -q 'wsl up' \
  && ok "a restart no Windows endpoint carried is not 'wsl up' just because the old guest answers (rc=$rc)" \
  || ko "a failed restart over a live old guest read as success (rc=$rc) -- $out"
: > "$SSH_LOG"
out=$(env SSH_REFUSE=--shutdown WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-win rog-nv-wsl" "$WL" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'wsl restart FAILED on: rog (shutdown refused' && ! printf '%s' "$out" | grep -q 'wsl up' \
  && ok "...nor is one whose wsl.exe --shutdown failed on every alias that answered, and it says which phase (rc=$rc)" \
  || ko "a refused shutdown over a live old guest read as success, or did not name the phase (rc=$rc) -- $out"
grep -q 'wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ko "a start was issued after the shutdown failed, onto the old VM: $(cat "$SSH_LOG")" \
  || ok "...and no start is issued onto the VM the shutdown left standing"
printf '%s\n' "$out" | tail -1 | grep -q 'wsl restart FAILED on: rog' \
  && ok "...with the failure as the last line, where the sweep routine reads its verdict" \
  || ko "the failure is not the last line -- $out"
# The kick keeps its meaning -- start if not running -- so a `--wait --wsl` on a box the user is
# working on never kills a live VM; `--restart-wsl` is the spelling that does.
: > "$SSH_LOG"; kick "rog-lan rog-nv-wsl" >/dev/null 2>&1
grep -q -- '--shutdown' "$SSH_LOG" && ko "kick-wsl issued a shutdown: $(cat "$SSH_LOG")" \
  || ok "kick-wsl never shuts a VM down"
wake_wsl() { env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-wsl" "$WL" --wait "$1" rog; }
: > "$SSH_LOG"; out=$(wake_wsl --wsl 2>&1)
printf '%s' "$out" | grep -q 'wsl up' && ! grep -q -- '--shutdown' "$SSH_LOG" \
  && ok "...and neither does --wait --wsl" || ko "--wait --wsl shut a VM down, or never started one -- $out; $(cat "$SSH_LOG")"
: > "$SSH_LOG"; out=$(wake_wsl --restart-wsl 2>&1); rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'wsl shut down on rog (via rog-lan)' && printf '%s' "$out" | grep -q 'wsl up' \
  && printf '%s\n' "$out" | tail -1 | grep -q '^all up$' && grep -q '^rog-lan :: wsl.exe --shutdown$' "$SSH_LOG" \
  && ok "--wait --restart-wsl shuts the VM down after the wake and starts a fresh one, ending in all up (rc=$rc)" \
  || ko "--wait --restart-wsl did not restart the VM, or did not end in all up (rc=$rc) -- $out; $(cat "$SSH_LOG")"
# The wake path's final verdict is the wake's AND the WSL step's: with the boxes up and the
# restart failed, `all up` with exit 0 would hand the sweep the old VM, so the WSL failure is the
# last line and the exit status is nonzero.
: > "$SSH_LOG"; out=$(env SSH_REFUSE=--shutdown WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-wsl" "$WL" --wait --restart-wsl rog 2>&1); rc=$?
printf '%s' "$out" | grep -q 'wsl restart FAILED on: rog' && ! printf '%s' "$out" | grep -q 'wsl up' \
  && ok "...and in the wake path too, a failed shutdown over a live old guest is never 'wsl up'" \
  || ko "the wake path reported wsl up over a VM it failed to shut down -- $out"
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^all up$' && printf '%s\n' "$out" | tail -1 | grep -q 'wsl restart FAILED on: rog' \
  && ok "...nor 'all up': the restart failure is the wake's last line and its exit status (rc=$rc)" \
  || ko "the wake path said all up, or exited 0, over a failed restart (rc=$rc) -- $out"
# A start that fails AFTER the shutdown went through is the opposite diagnosis: there is no VM at
# all, old or new, and telling the operator the old one still answers would be wrong twice over.
: > "$SSH_LOG"
out=$(env SSH_REFUSE='-d Ubuntu' WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-win rog-nv-wsl" "$WL" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'wsl shut down on rog (via rog-lan)' \
  && printf '%s\n' "$out" | tail -1 | grep -q 'wsl restart FAILED on: rog (shut down, then the start failed' \
  && ! printf '%s' "$out" | grep -q 'old VM' \
  && ok "a start that fails after the shutdown is reported as a start failure, never as the old VM answering (rc=$rc)" \
  || ko "a failed start after a shutdown was misreported (rc=$rc) -- $out"
# The step's third failing shape: every wsl.exe command succeeded, and the fresh guest never
# answered within the poll budget. `wsl still down` is a backend the sweep cannot test, so it is a
# failure of the step, from the verb's exit status and from the wake path's final verdict alike.
: > "$SSH_LOG"; out=$(restart "rog-lan rog-nv-win" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q 'wsl up' && printf '%s\n' "$out" | tail -1 | grep -q 'wsl still down after 0 min on: rog' \
  && ok "a restarted guest that never answers is a failed restart-wsl, its last line saying so (rc=$rc)" \
  || ko "a guest that never answered read as a successful restart (rc=$rc) -- $out"
grep -q '^rog-lan :: wsl.exe -d Ubuntu' "$SSH_LOG" && ok "...after the start really was issued" \
  || ko "the start was never issued, so the case pins nothing: $(cat "$SSH_LOG")"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-win" "$WL" --wait --restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! printf '%s' "$out" | grep -q '^all up$' && printf '%s\n' "$out" | tail -1 | grep -q 'NOT all up: wsl still down after 0 min on: rog' \
  && ok "...and the wake path over it is NOT all up, exit nonzero, with the poll timeout as its last line (rc=$rc)" \
  || ko "the wake path said all up, or exited 0, over a guest that never answered (rc=$rc) -- $out"
# The poll's verdict is aggregate; the report is per box. With two boxes started and one guest
# late, only that one is still down -- the other is up and its backend is testable today.
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan minix-lan rog-nv-wsl" "$WL" restart-wsl rog minix 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q '^wsl up on: rog$' && printf '%s\n' "$out" | tail -1 | grep -q 'wsl still down after 0 min on: minix$' \
  && ok "one late guest is reported alone, and its neighbour as up (rc=$rc)" \
  || ko "the poll's aggregate failure was pinned on every started box (rc=$rc) -- $out"
# The kick path holds the same line: a kick no Windows endpoint carried is a failed kick, whatever
# the guest answers, so `wsl up` there is the kick's own success and not the poll's.
out=$(kick "rog-nv-wsl" 2>&1); rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'wsl kick FAILED on: rog' && ! printf '%s' "$out" | grep -q 'wsl up' \
  && ok "kick-wsl reports its own failure over a live guest as well (rc=$rc)" \
  || ko "a failed kick over a live guest read as success (rc=$rc) -- $out"

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
printf '%s' "$out" | grep -q 'did NOT wake: rog' \
  && ok "...reporting the box that never came up" || ko "no 'did NOT wake' after the budget -- $out"
printf '%s' "$out" | grep -q 'scripts/enable-wol-windows.ps1' \
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
  || ko "--help is not the header block: $(diff <(printf '%s\n' "$head_block") <(printf '%s\n' "$help_out") | head -5)"
printf '%s\n' "$help_out" | grep -q 'set -u' \
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
