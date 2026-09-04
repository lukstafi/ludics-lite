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
# is, which is what the polling deadlines have to survive.
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
  *) return 1 ;; esac; }
eth_mac_of() { case "$1" in
  rog)   echo aa:bb:cc:00:00:02 ;;
  *) return 1 ;; esac; }
ip_of() { case "$1" in
  rog)   echo 10.0.0.1 ;;
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
expect "status asks the router about the site file's Ethernet MAC alone" 0 "rog    eth-link=1" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" status rog
grep -q 'aa:bb:cc:00:00:02' "$CURL_LOG" && ! grep -q 'aa:bb:cc:00:00:01' "$CURL_LOG" \
  && ok "...not about the Wi-Fi one" || ko "link_active used the wrong MAC: $(cat "$CURL_LOG")"
printf '%s' "$out" | grep -q 'stale router lease, not physical link state' \
  && ok "...and warns that a recent shutdown can leave a stale lease reading" \
  || ko "status does not carry the stale-lease caveat -- $out"

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
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 SSH_DELAY=3 "$WL" --wait rog 2>&1)
elapsed=$((SECONDS - started))
[ "$elapsed" -lt 30 ] && ok "...and so does the wake wait (${elapsed}s)" \
  || ko "the wake wait ran ${elapsed}s against a 1s budget: it is still counting iterations"
printf '%s' "$out" | grep -q 'did NOT wake: rog' \
  && ok "...reporting the box that never came up" || ko "no 'did NOT wake' after the budget -- $out"
printf '%s' "$out" | grep -q 'scripts/enable-wol-windows.ps1' \
  && ok "...and points failure advice at the tracked Windows repair script" \
  || ko "wake failure advice does not name scripts/enable-wol-windows.ps1 -- $out"

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
expect "the example host table satisfies the contract" 0 "eth-link=1" -- \
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
