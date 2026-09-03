#!/bin/bash
# Drive the home-lab machines' power state remotely: wake, sleep, hibernate, shut down, inspect.
#
# Waking uses two independent paths, both attempted:
#   1. FRITZ!Box TR-064 `X_AVM-DE_WakeOnLANByMACAddress` — the router emits the magic
#      packet on the wired LAN segment. No credentials needed from the LAN side.
#   2. A magic packet sent directly from this Mac (broadcast, UDP ports 7 and 9).
#
# Usage:
#   wake-lab.sh [rog|minix|asus|all]      wake (default targets: rog minix)
#   wake-lab.sh --wait [--wsl] rog        wake, then poll until ssh answers (--wsl: also start WSL)
#   wake-lab.sh status [box...]           per-box power/reachability table
#   wake-lab.sh sleep|hibernate|down box  suspend / hibernate / full shutdown
#   wake-lab.sh kick-wsl box              start the WSL VM (it never autostarts at boot)
#   wake-lab.sh --list                    dump the router's host table
#
# Tracked in the ludics-lite repository as scripts/wake-lab.sh and meant to be reached through a
# ~/bin/wake-lab.sh symlink, so an edit made mid-run lands as a normal `git status`. One part is
# deliberately NOT tracked: the fleet's MAC and LAN IP addresses, which live in a site file this
# script sources at startup — ~/.config/wake-lab/hosts.sh, or wherever WAKE_LAB_HOSTS points. It
# defines mac_of, eth_mac_of and ip_of, and the script refuses to run without it;
# scripts/wake-lab-hosts.example.sh in the checkout is the template. Everything else — the lab
# lore below, the router endpoints, the ssh aliases, all of the logic — is tracked and reviewable.
#
# -h/--help prints this block, which ends at the first non-comment line, so it can grow freely.
# Requires bash 3.2 (stock macOS): no associative arrays, no ${var,,}.
set -u

ROUTER=192.168.178.1
BCAST=192.168.178.255
HOSTS_CTL=/upnp/control/hosts
HOSTS_SVC=urn:dslforum-org:service:Hosts:1

# ---------------------------------------------------------------- machine table
# Verified lab constraints. Do not spend a session rediscovering them; the dates say when each
# was last checked.
#
# * WoL works over Ethernet only, never over Wi-Fi: a magic packet cannot reach the Wi-Fi NIC of
#   a powered-off machine. Both MACs are in the host table and packets go to both, but the
#   Ethernet one does the waking. rog and minix are both CABLED (rog Ethernet .30, minix
#   Ethernet .31; minix's old .27 Wi-Fi lease is inactive). asus is Wi-Fi only and therefore
#   cannot be woken at all.
# * Both boxes wake from a full shutdown (S5), not just from sleep — verified 2026-08-15 on both,
#   after enabling the `Wake Up` item on minix's BIOS SECOND setup screen (not under Advanced).
#   "Powered off" is a normal starting state for a wake, not a reason to expect failure.
# * A box holding Ethernet link while powered off (`status` -> link=1) is the WoL-armed state and
#   is what makes the wake possible. A failed wake with link=1 means the NIC was powered and
#   listening, so the magic packet was ignored: the WoL option itself (BIOS, or the Windows NIC
#   driver's wake settings) has been lost. With link=0 the NIC is not powered while the box is
#   off: the cable, the box's power, or the BIOS setting that keeps the NIC powered in S5.
# * WSL never autostarts at boot, so a box coming up from power-down always needs kick_wsl. A box
#   resuming from sleep/hibernate with the user's GUI WSL shell still open (the usual cycle) keeps
#   its VM across the resume — verified on minix 2026-09-01: same boot id, -wsl answering seconds
#   after the wake with no kick; the kick is then a harmless no-op.
# * A kicked VM on a cold-booted box does not necessarily STAY up: on 2026-09-01, twice in a row,
#   `--wait --wsl` reported both -wsl UP yet both VMs were gone ~4 minutes later (`status`:
#   win=UP, wsl=--). Use the VM promptly after the kick; once an ssh session is running inside it,
#   it stays up. `kick-wsl` re-kicks a box whose Windows side is up.
# * WSL needs no interactive Windows login: the ssh network logon is session enough (verified
#   with the console logged off). A `console` entry in `query session` after a cold boot comes
#   from Windows' Automatic Restart Sign-On, not from a human having logged in.
# * Both boxes run Tailscale in unattended mode (ForceDaemon), so they authenticate after a cold
#   wake with nobody logged in. If a box comes up without its Tailscale node appearing, the LAN
#   aliases rog-lan / minix-lan depend on nothing but the box being booted and answer within
#   seconds of a wake, while Tailscale lags a minute or more. They need the box's Windows
#   Firewall profile to be Private, currently true of both.
# * Probing the -win / -lan aliases by hand: the command must be `exit 0`, NOT `true` — they land
#   in cmd.exe, which has no `true`; see ssh_probe().
#
# mac_of (every MAC of a box), eth_mac_of (the Ethernet one alone, whose link state is what
# link_active reads) and ip_of are NOT here: they are the fleet's hardware addresses, the one part
# of this script that is site data rather than reviewable logic, and they come from HOSTS_FILE.
HOSTS_FILE=${WAKE_LAB_HOSTS:-$HOME/.config/wake-lab/hosts.sh}

# Refuse rather than run half-configured: without the table every box is "unknown machine", which
# reads like a typo in the command rather than a missing install step.
load_hosts() {
  local f
  if [ ! -r "$HOSTS_FILE" ]; then
    echo "wake-lab.sh: no host table at $HOSTS_FILE" >&2
    echo "  copy scripts/wake-lab-hosts.example.sh from the ludics-lite checkout there and fill" >&2
    echo "  in this fleet's MACs and IPs, or point WAKE_LAB_HOSTS at your own copy." >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  . "$HOSTS_FILE" || { echo "wake-lab.sh: $HOSTS_FILE failed to load" >&2; exit 1; }
  for f in mac_of eth_mac_of ip_of; do
    declare -F "$f" >/dev/null && continue
    echo "wake-lab.sh: $HOSTS_FILE defines no $f() — see scripts/wake-lab-hosts.example.sh" >&2
    exit 1
  done
}

# Direct-to-LAN-IP ssh aliases. These depend on nothing but the box being booted, which makes them
# the FASTEST and most trustworthy liveness signal — see is_up(). asus has none.
lan_of() { case "$1" in
  rog)   echo rog-lan ;;
  minix) echo minix-lan ;;
  *) echo "" ;; esac; }
# Tailscale (MagicDNS) aliases: native Windows, and the WSL guest.
ts_of() { case "$1" in
  rog)   echo rog-nv-win ;;
  minix) echo minix-amd-win ;;
  asus)  echo asus-amd-win ;;
  *) return 1 ;; esac; }
wsl_of() { case "$1" in
  rog)   echo rog-nv-wsl ;;
  minix) echo minix-amd-wsl ;;
  *) echo "" ;; esac; }

# ---------------------------------------------------------------- plumbing
# The header block, line 2 through the last line before the first non-comment line. The range was
# once hard-coded as 2,20p, which silently truncated the help whenever the header grew.
usage() { sed -n '2,${/^#/!q;p;}' "$0"; }

soap() { # soap <control-url> <serviceType> <action> <inner-xml>
  local body="<?xml version=\"1.0\"?><s:Envelope xmlns:s=\"http://schemas.xmlsoap.org/soap/envelope/\" s:encodingStyle=\"http://schemas.xmlsoap.org/soap/encoding/\"><s:Body><u:$3 xmlns:u=\"$2\">${4:-}</u:$3></s:Body></s:Envelope>"
  curl -s -m 10 -H 'Content-Type: text/xml; charset="utf-8"' -H "SoapAction: $2#$3" \
       -d "$body" "http://$ROUTER:49000$1"
}

# The router answers a refused action with an HTTP body containing <s:Fault>, and curl still exits
# 0 — so a bare `soap ... && echo sent` reports success for a MAC the router has never seen. Always
# route SOAP calls that matter through this.
soap_checked() { # soap_checked <control-url> <serviceType> <action> <inner-xml>; prints body, fails on fault
  local resp desc
  resp=$(soap "$@") || { echo "no response from router ($ROUTER)" >&2; return 1; }
  if [ -z "$resp" ]; then echo "empty response from router ($ROUTER)" >&2; return 1; fi
  if printf '%s' "$resp" | grep -q '<s:Fault>'; then
    desc=$(printf '%s' "$resp" | sed -n 's/.*<errorDescription>\([^<]*\)<.*/\1/p')
    echo "${desc:-SOAP fault}" >&2
    return 1
  fi
  printf '%s' "$resp"
}

ssh_probe() { # ssh_probe <alias> [timeout] — true iff sshd answers and authentication succeeds
  [ -n "$1" ] || return 1
  # `exit 0`, NOT `true`: the -win/-lan aliases land in cmd.exe, which has no `true` and would
  # report every Windows box as down. `exit 0` is valid in cmd.exe and in POSIX shells alike.
  ssh -o BatchMode=yes -o ConnectTimeout="${2:-5}" -o StrictHostKeyChecking=accept-new \
      "$1" 'exit 0' >/dev/null 2>&1
}

magic_packet() { # magic_packet <MAC>
  python3 - "$1" "$BCAST" <<'PY'
import socket, sys
mac, bcast = sys.argv[1], sys.argv[2]
pkt = b'\xff' * 6 + bytes.fromhex(mac.replace(':', '').replace('-', '')) * 16
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
for host in ('255.255.255.255', bcast):
    for port in (7, 9):
        s.sendto(pkt, (host, port))
s.close()
PY
}

# ---------------------------------------------------------------- inspection
list_hosts() {
  local n i
  n=$(soap $HOSTS_CTL $HOSTS_SVC GetHostNumberOfEntries \
      | sed -n 's/.*<NewHostNumberOfEntries>\([0-9]*\)<.*/\1/p')
  for ((i = 0; i < n; i++)); do
    soap $HOSTS_CTL $HOSTS_SVC GetGenericHostEntry "<NewIndex>$i</NewIndex>" \
      | sed -n 's/.*<NewHostName>\([^<]*\)<.*/\1/p;s/.*<NewMACAddress>\([^<]*\)<.*/\1/p;s/.*<NewIPAddress>\([^<]*\)<.*/\1/p;s/.*<NewActive>\([01]\)<.*/active=\1/p' \
      | paste -s -d' ' -
  done
  echo
  echo "NOTE: 'active' is a fast UP signal but a SLOW DOWN signal — a just-shut-down box reads"
  echo "active=1 for several minutes while its DHCP lease ages out, and a WoL-armed box holds the"
  echo "link (active=1) indefinitely while powered off. Use 'status' to ask what is really running."
}

link_active() { # link_active <box> — echo 1/0/? for the Ethernet MAC's router-side link state
  local mac out
  mac=$(eth_mac_of "$1") || { echo '?'; return; }
  out=$(soap_checked $HOSTS_CTL $HOSTS_SVC GetSpecificHostEntry "<NewMACAddress>$mac</NewMACAddress>" 2>/dev/null) \
    || { echo '?'; return; }
  printf '%s' "$out" | sed -n 's/.*<NewActive>\([01]\)<.*/\1/p' | head -1
}

# "Up" means ssh answers, NOT that Tailscale thinks the node is online: after a wake the LAN path
# answers within seconds while tailscaled takes a minute or more to register with the control
# plane, and after a hibernate resume the WSL node has taken over two minutes. ICMP is firewalled
# on both boxes, so pinging is useless as a fallback.
is_up() { # is_up <box>
  ssh_probe "$(lan_of "$1")" && return 0
  ssh_probe "$(ts_of "$1")" && return 0
  return 1
}

status_one() { # status_one <box>
  local lan ts wsl l
  lan=$(lan_of "$1"); ts=$(ts_of "$1"); wsl=$(wsl_of "$1")
  l=$(link_active "$1")
  printf '%-6s eth-link=%-1s' "$1" "$l"
  if [ -n "$lan" ]; then ssh_probe "$lan" && printf '  lan=UP  ' || printf '  lan=--  '; else printf '  lan=n/a '; fi
  if [ -n "$ts" ];  then ssh_probe "$ts"  && printf '  win=UP  ' || printf '  win=--  '; else printf '  win=n/a '; fi
  if [ -n "$wsl" ]; then ssh_probe "$wsl" && printf '  wsl=UP'   || printf '  wsl=--'  ; else printf '  wsl=n/a'; fi
  printf '\n'
}

do_status() {
  echo "box    link  lan(direct IP)  win(tailscale)  wsl(tailscale)"
  for n in "$@"; do status_one "$n"; done
  echo
  echo "link=1 only means the NIC holds link — a WoL-armed box reads 1 while powered OFF."
  echo "lan/win/wsl are real ssh probes; wsl=-- right after a wake is usually just tailscaled lag."
}

# ---------------------------------------------------------------- power control
wake() { # wake <box>
  local name=$1 macs mac err ok=1
  macs=$(mac_of "$name") || { echo "unknown machine: $name" >&2; return 1; }
  for mac in $macs; do
    if err=$(soap_checked $HOSTS_CTL $HOSTS_SVC X_AVM-DE_WakeOnLANByMACAddress \
                          "<NewMACAddress>$mac</NewMACAddress>" 2>&1 >/dev/null); then
      echo "  fritzbox WoL sent      -> $name ($mac)"
    else
      # NoSuchEntryInArray just means this MAC never held a DHCP lease; the direct packet below
      # is the path that matters for a freshly cabled NIC.
      echo "  fritzbox WoL REFUSED   -> $name ($mac): $err"
      ok=0
    fi
    if magic_packet "$mac"; then
      echo "  direct magic packet    -> $name ($mac)"
    else
      echo "  direct magic packet FAILED -> $name ($mac)"
      ok=0
    fi
  done
  [ "$ok" = 1 ]
}

kick_wsl() { # kick_wsl <box> — WSL never autostarts at boot, and hibernate terminates the VM.
  local ts; ts=$(ts_of "$1") || return 1
  # An ssh network logon is session enough: this works with nobody logged in at the console.
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$ts" 'wsl.exe -d Ubuntu -e true' >/dev/null 2>&1 \
    && echo "  wsl started on $1" || echo "  wsl kick FAILED on $1 (is $ts up?)"
}

# `SetSuspendState` drops the connection mid-command; without ServerAlive* the ssh client can hang
# for minutes instead of returning. The drop IS the success signature — do not treat it as an error,
# and do not wrap the command as `start /b ... & exit` (the detached child dies with the session).
power_action() { # power_action <verb> <box>
  local verb=$1 name=$2 ts cmd
  ts=$(ts_of "$name") || { echo "unknown machine: $name" >&2; return 1; }
  case "$verb" in
    sleep)     cmd='rundll32.exe powrprof.dll,SetSuspendState 0,1,0' ;;
    hibernate) cmd='shutdown /h' ;;
    down)      cmd='shutdown /s /f /t 0' ;;
    *) echo "unknown power verb: $verb" >&2; return 1 ;;
  esac
  echo "$name: $verb"
  ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 \
      "$ts" "$cmd" 2>&1 | tail -1
  echo "  (a dropped/timed-out connection here is the expected success signature)"
}

confirm_down() { # confirm_down <box...> — poll until ssh stops answering
  local names=("$@") i n any
  for ((i = 0; i < 24; i++)); do
    any=0
    for n in "${names[@]}"; do
      if is_up "$n"; then printf '%s=up ' "$n"; any=1; else printf '%s=DOWN ' "$n"; fi
    done
    printf '(%s)\n' "$(date +%H:%M:%S)"
    [ "$any" = 0 ] && return 0
    sleep 5
  done
  echo "still reachable after 2 min — the suspend may not have taken"
  return 1
}

wait_for() { # wait_for <box...> — poll for up to 4 minutes
  local names=("$@") i n up all
  for ((i = 0; i < 48; i++)); do
    all=1
    for n in "${names[@]}"; do
      if is_up "$n"; then up=UP; else up=down; all=0; fi
      printf '%s=%s ' "$n" "$up"
    done
    printf '(%s)\n' "$(date +%H:%M:%S)"
    [ "$all" = 1 ] && return 0
    sleep 5
  done
  return 1
}

wait_for_wsl() { # wait_for_wsl <box...> — tailscaled inside WSL can take >2 min after a resume
  local names=("$@") i n w all
  for ((i = 0; i < 36; i++)); do
    all=1
    for n in "${names[@]}"; do
      w=$(wsl_of "$n")
      if [ -z "$w" ]; then printf '%s=n/a ' "$n"; continue; fi
      if ssh_probe "$w"; then printf '%s-wsl=UP ' "$n"; else printf '%s-wsl=down ' "$n"; all=0; fi
    done
    printf '(%s)\n' "$(date +%H:%M:%S)"
    [ "$all" = 1 ] && return 0
    sleep 5
  done
  return 1
}

# ---------------------------------------------------------------- dispatch
WAIT=0
WANT_WSL=0
VERB=wake
TARGETS=()

case "${1:-}" in
  status|sleep|hibernate|down|kick-wsl) VERB=$1; shift ;;
esac

for arg in "$@"; do
  case "$arg" in
    --list) list_hosts; exit 0 ;;
    --wait) WAIT=1 ;;
    --wsl)  WANT_WSL=1 ;;
    -h|--help) usage; exit 0 ;;
    all) TARGETS+=(rog minix asus) ;;
    *) TARGETS+=("$arg") ;;
  esac
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(rog minix)

# After the argument loop on purpose: --help and --list need no site data, and both are what you
# reach for on a box where the host table has yet to be installed.
load_hosts

case "$VERB" in
  status)
    do_status "${TARGETS[@]}"
    ;;
  kick-wsl)
    for t in "${TARGETS[@]}"; do kick_wsl "$t"; done
    wait_for_wsl "${TARGETS[@]}" && echo "wsl up" || echo "wsl still down after 3 min"
    ;;
  sleep|hibernate|down)
    for t in "${TARGETS[@]}"; do power_action "$VERB" "$t"; done
    echo "confirming..."
    confirm_down "${TARGETS[@]}"
    ;;
  wake)
    for t in "${TARGETS[@]}"; do echo "$t:"; wake "$t"; done
    if [ "$WAIT" = 1 ]; then
      echo "waiting for boot..."
      wait_for "${TARGETS[@]}"; rc=$?
      # Partial success still deserves the WSL kick: one box failing to wake must not suppress
      # starting WSL on the box that did come up, or an unrelated dead machine silently costs a
      # backend's coverage.
      if [ "$WANT_WSL" = 1 ]; then
        UP=()
        for t in "${TARGETS[@]}"; do is_up "$t" && UP+=("$t"); done
        if [ ${#UP[@]} -gt 0 ]; then
          for t in "${UP[@]}"; do kick_wsl "$t"; done
          wait_for_wsl "${UP[@]}" && echo "wsl up" || echo "wsl still down after 3 min"
        fi
      fi
      if [ "$rc" = 0 ]; then
        echo "all up"
      else
        for t in "${TARGETS[@]}"; do is_up "$t" || echo "did NOT wake: $t"; done
        echo "Check, in order: BIOS Wake-on-LAN / 'Power Up' (minix needed this, and it is on the"
        echo "SECOND setup screen, not under Advanced); Fast Startup off; the NIC holding link"
        echo "while powered off ('$0 status' -> link=1). asus is Wi-Fi only and cannot be woken."
      fi
    fi
    ;;
esac
