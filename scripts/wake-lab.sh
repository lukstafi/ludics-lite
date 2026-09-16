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
#   wake-lab.sh --wait --restart-wsl rog  ...and start WSL from a FRESH VM (wsl --shutdown first)
#   wake-lab.sh status [box...]           per-box power/reachability table
#   wake-lab.sh sleep|hibernate|down box  suspend / hibernate / full shutdown
#   wake-lab.sh kick-wsl box              start the WSL VM (it never autostarts at boot)
#   wake-lab.sh restart-wsl box           shut the WSL VM down and start it again (see the lore)
#   wake-lab.sh kick-wsl --hold box       ...and leave a Windows-side holder keeping the VM alive
#   wake-lab.sh unhold box                end that holder (a lane ends by unhold, never by expiry)
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
# * `status` -> router-active is the router's NewActive bit for the box's Ethernet MAC, read over
#   TR-064 -- the router's opinion of the lease, not NIC telemetry, and the column is named for
#   what it reads so that it is not mistaken for link state. It is a fast UP signal and a SLOW
#   DOWN signal: for several minutes after a shutdown or hibernate, router-active=1 is a stale
#   DHCP lease aging out, and diagnosing the wake path from it is a misdiagnosis (2026-09-01);
#   wait for it to settle first. Once settled after a full shutdown, router-active=1 means the
#   NIC still holds Ethernet link while powered off: the WoL-armed state that makes the wake
#   possible. A failed wake then means the magic packet was ignored: the WoL option itself (BIOS,
#   or the Windows NIC driver's wake settings) has been lost. With settled router-active=0 after
#   a full shutdown, check the cable, the box's power, and the BIOS setting that keeps the NIC
#   powered in S5.
# * WSL never autostarts at boot, so a box coming up from power-down always needs kick_wsl. A box
#   resuming from sleep/hibernate with the user's GUI WSL shell still open (the usual cycle) keeps
#   its VM across the resume — verified on minix 2026-09-01: same boot id, -wsl answering seconds
#   after the wake with no kick; the kick is then a harmless no-op.
# * The dxg refusal class is decided by CONCURRENCY, not by the VM's age. `misc dxg:
#   dxgvmb_send_sync_msg: vmbus_sendpacket failed: fffffff5` (-EAGAIN) floods whenever more than
#   about two processes hold the GPU, and every standalone probe still passes. ludics-lite#60 read
#   it as a VM kept alive across host resumes and `--restart-wsl` was built on that reading; on
#   2026-09-15 three FRESH VMs overflowed the same way within minutes at dune's default width
#   (160–320 refusals), and the same VMs were clean serially and at `-j 2`. The fix that holds is
#   the job cap — ocannl-staging's `unit_jobs` (`minix:hip -> 2`, since 2026-09-05). `restart-wsl`
#   (and `--wait --restart-wsl`) issues `wsl --shutdown` on the Windows host before the start,
#   which is harmless and costs ~a minute; on a cold-booted box the shutdown is a no-op. Keep it,
#   but do NOT read a fresh VM as protection: a manual run at full width overflows on one too.
#   Nothing inside the VM can issue that restart without killing its own session, which is why it
#   lives here, on the -win side.
# * Under WSL2, /dev/kfd and /dev/dri are never present and `rocm-smi` always says "driver not
#   initialized (amdgpu not found in modules)"; none of that is evidence of a lost passthrough,
#   and a "check the device nodes" step in the WSL path would report the box broken every time.
#   `hipGetDeviceCount` (or `rocminfo` listing the gfx agent) is the evidence. And a stale-but-
#   alive VM is NOT detectable by a single-process probe: hipGetDeviceCount, hiprtc and a kernel
#   launch all pass on it. The only signal is the guest's `dmesg | grep -c 'misc dxg'` growing
#   under a few concurrent GPU processes (the `hv_utils: TimeSync IC version` renegotiation lines,
#   one per host resume, date the VM but do not predict the refusals). That is why a green
#   single-process probe certifies nothing about a run at full width: the job cap does.
# * What keeps a WSL VM alive is a wsl.exe process on the WINDOWS side, never a session inside the
#   guest. The kick's `wsl.exe -d Ubuntu -e true` returns at once, and the VM then shuts down under
#   whatever is running inside it: on 2026-09-01, twice in a row, `--wait --wsl` reported both -wsl
#   UP yet both VMs were gone ~4 minutes later (`status`: win=UP, wsl=--), and on 2026-09-08 three
#   minix launches died mid-fetch/mid-build the same way. The steady state that hides this is the
#   owner's console WSL shell, which is exactly such a Windows-side process — and which a Windows
#   Update restart silently removes (ludics-lite#155). An inbound ssh session inside the guest does
#   NOT hold it: the 2026-09-15 sweep's hip unit died 76 s in on an unheld VM that had powered off
#   18 s after its kick.
# * Hence `--hold`: `kick-wsl --hold` / `restart-wsl --hold` spawns the holder this script owns —
#   `ssh -o ServerAliveInterval=15 <box>-win 'wsl.exe -d Ubuntu -e sleep infinity'`, backgrounded
#   here, its pid under $WAKE_LAB_STATE_DIR — and declares the VM up only once a wsl.exe is
#   OBSERVED on the Windows side (`tasklist`), because a holder that failed to start is exactly the
#   state the flag exists to rule out. `unhold <box>` ends it. Never size the holder with a fixed
#   `sleep N`: a lane is several units with their own caps plus preparation, and a 3-hour holder
#   expires under the last one — `sleep infinity` killed explicitly is the contract, so a lane ends
#   by unhold, not by expiry. A holder inside the guest would die with the VM, which is the failure
#   being fixed. `kick-wsl` re-kicks a box whose Windows side is up, so `kick-wsl --hold` is also
#   how a lane takes a holder over a VM that is already running.
# * Windows Update restarts are the other way an unattended lane loses its box, and they are
#   readable in advance: `ActiveHoursStart`, `ActiveHoursEnd` and `SmartActiveHoursState` under
#   `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` on the -win side. On 2026-09-15 KB5129195
#   restarted minix 21 min into its hip unit, because active hours were 10:00–01:00 and the sweep
#   runs in the morning; both boxes now pin 6→0 (the 18 h maximum) with SmartActiveHoursState=0,
#   but a feature update can reset that. `status`, and `--hold`, read those values and warn when
#   the sweep window ($WAKE_LAB_SWEEP_HOURS, default 7-11 local) is not inside them. After the
#   fact, the signature is System event 1074 from MoUsoCoreWorker.exe / TrustedInstaller.exe on the
#   -win side inside the unit's window: an `error` unit with one of those is an update restart, not
#   a backend failure.
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
# mac_of (every MAC of a box), eth_mac_of (the Ethernet one alone, whose lease is what
# router_active asks the router about) and ip_of are NOT here: they are the fleet's hardware
# addresses, the one part of this script that is site data rather than reviewable logic, and they
# come from HOSTS_FILE.
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

# The table's box list is mac_of's, and every target must be in it BEFORE anything is sent. A table
# that knows rog but not minix would otherwise wake rog, then report minix as a typo halfway
# through the operation -- and the dispatch loop's exit status hides that, so the run reads as a
# success. Refusing the whole run is what "refuse rather than run half-configured" means here.
check_targets() {
  local t bad=""
  for t in "$@"; do mac_of "$t" >/dev/null 2>&1 || bad="$bad $t"; done
  [ -z "$bad" ] && return 0
  echo "wake-lab.sh: not in the host table ($HOSTS_FILE):$bad" >&2
  echo "  the known boxes are the ones mac_of answers for; nothing was sent." >&2
  exit 1
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

router_active() { # router_active <box> — echo 1/0/? for the router's NewActive bit on the Ethernet MAC
  # NewActive is the router's view of the lease, not the NIC's link state; see the lore above.
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
  l=$(router_active "$1")
  printf '%-6s router-active=%-1s' "$1" "$l"
  if [ -n "$lan" ]; then ssh_probe "$lan" && printf '  lan=UP  ' || printf '  lan=--  '; else printf '  lan=n/a '; fi
  if [ -n "$ts" ];  then ssh_probe "$ts"  && printf '  win=UP  ' || printf '  win=--  '; else printf '  win=n/a '; fi
  if [ -n "$wsl" ]; then ssh_probe "$wsl" && printf '  wsl=UP'   || printf '  wsl=--'  ; else printf '  wsl=n/a'; fi
  printf '\n'
}

do_status() {
  local n
  echo "box    router-active   lan(direct IP)  win(tailscale)  wsl(tailscale)"
  for n in "$@"; do status_one "$n"; done
  echo
  # The update window is part of "is this box fit to run an unattended lane tonight", and nothing
  # else in the fleet reports it. A box that is down simply has no reading; that is not a warning
  # about its settings, so say which of the two it is.
  echo "Windows Update window (active hours vs the sweep window $SWEEP_HOURS, local time on the box):"
  for n in "$@"; do check_active_hours "$n" "$(win_dest "$n")"; done
  echo
  echo "router-active is the router's NewActive bit for the Ethernet MAC, not the NIC's link state:"
  echo "minutes after a shutdown or hibernate, 1 is a stale DHCP lease still aging out; once settled,"
  echo "1 on a powered-off box means the NIC holds link and is WoL-armed."
  echo "lan/win/wsl are real ssh probes; wsl=-- right after a wake is usually just tailscaled lag."
}

# ---------------------------------------------------------------- power control
# Poll budgets, in seconds, and they are wall-clock budgets: the loops below run to a deadline
# rather than to an iteration count. Counting iterations quietly lied whenever the boxes stayed
# dark -- each is_up() burns two ssh ConnectTimeouts, so 48 rounds over two unreachable boxes ran
# for about twenty minutes under the name of a four-minute wait, delaying the sweep that is the
# only coverage those backends get. The env overrides exist for the test suite.
WAIT_SECONDS=${WAKE_LAB_WAIT_SECONDS:-240}
WSL_WAIT_SECONDS=${WAKE_LAB_WSL_WAIT_SECONDS:-180}
DOWN_WAIT_SECONDS=${WAKE_LAB_DOWN_WAIT_SECONDS:-120}
# How long to wait for the spawned holder to show up as a wsl.exe on the Windows side, and where
# its pid is recorded so that `unhold` — possibly in a later shell, since a lane is a sequence of
# commands — can end it.
HOLD_WAIT_SECONDS=${WAKE_LAB_HOLD_WAIT_SECONDS:-60}
# How long our holder must have been alive, counted FROM ITS SPAWN, before the VM is called held.
# The bound is not arbitrary: it exceeds the holder's own ConnectTimeout (15s), and ssh exits both
# when it cannot connect and when its remote command ends. A client still alive past that is
# therefore one that connected AND whose `sleep infinity` is running — which a `tasklist` reading
# on its own cannot say, since the wsl.exe it sees may be the owner's console shell.
HOLD_SETTLE_SECONDS=${WAKE_LAB_HOLD_SETTLE_SECONDS:-20}
HOLD_STATE_DIR=${WAKE_LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wake-lab}
# The local-time hours on the Windows box that the unattended sweep occupies: the routine's 07:20
# launch plus its longest lane. Written `<start>-<end>`, end exclusive, and it may wrap midnight.
SWEEP_HOURS=${WAKE_LAB_SWEEP_HOURS:-7-11}

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

kick_wsl() { # kick_wsl <box> [fresh] — WSL never autostarts at boot, and hibernate terminates the VM.
  # The -lan and -win aliases land in the same Windows sshd, and after a cold boot the LAN one
  # answers within seconds while tailscaled takes a minute or more (the same asymmetry is_up() is
  # built on). A kick that knew only the Tailscale alias therefore failed on exactly the wake
  # wait_for had just declared finished, and the WSL poll behind it could only time out. Try the
  # fast path first, fall back to Tailscale, and say which one carried it.
  #
  # With `fresh`, `wsl --shutdown` goes first over the same alias: a VM that survived a host
  # resume can carry a degraded dxg bridge (see the lore), and the only cure is a new VM. The
  # shutdown lands on the Windows host, never inside the VM, so it cannot kill the session issuing
  # it. A start that then fails falls through to the next alias, shutdown included, which is a
  # natural retry of the whole restart rather than a start on a VM only half torn down.
  #
  # On failure KICK_PHASE says which phase failed, because the two mean opposite things to the
  # operator: `shutdown` — no alias carried the shutdown, so a -wsl guest that still answers is
  # the OLD VM; `start` — the shutdown went through and the start then failed everywhere, so
  # there is no VM at all until a kick succeeds; `kick` — the plain kick's start failed.
  local name=$1 fresh=${2:-} dest what=kick shut=0
  [ "$fresh" = fresh ] && what=restart
  for dest in $(lan_of "$name") $(ts_of "$name"); do
    [ -n "$dest" ] || continue
    # An ssh network logon is session enough: this works with nobody logged in at the console.
    if [ "$fresh" = fresh ]; then
      ssh -o BatchMode=yes -o ConnectTimeout=15 "$dest" 'wsl.exe --shutdown' >/dev/null 2>&1 || continue
      echo "  wsl shut down on $name (via $dest)"
      shut=1
    fi
    if ssh -o BatchMode=yes -o ConnectTimeout=15 "$dest" 'wsl.exe -d Ubuntu -e true' >/dev/null 2>&1; then
      echo "  wsl started on $name (via $dest)"
      KICK_DEST=$dest
      return 0
    fi
  done
  if [ "$fresh" = fresh ] && [ "$shut" = 0 ]; then KICK_PHASE=shutdown
  elif [ "$fresh" = fresh ]; then KICK_PHASE=start
  else KICK_PHASE=kick; fi
  echo "  wsl $what FAILED on $name (no Windows endpoint answered the $KICK_PHASE)"
  return 1
}
KICK_PHASE=""
KICK_DEST=""   # the Windows alias that carried the last successful kick; the holder rides the same

# ---------------------------------------------------------------- the Windows-side holder
# A VM is held up by a wsl.exe on the Windows side and by nothing else (see the lore). These three
# own that process: spawn it, observe it, kill it. The holder is `sleep infinity` on purpose — a
# lane is several units with their own caps plus preparation and diagnostics outside them, so a
# holder sized to the expected run expires under the last unit, silently, exactly when nobody is
# watching. It ends by unhold.
# One spelling of the holder, used to spawn it and to recognize it again.
HOLD_CMD='wsl.exe -d Ubuntu -e sleep infinity'

hold_pid_read() { # hold_pid_read <pidfile> — echo "<pid> <dest>", empty if the file is unusable
  local line p d
  [ -r "$1" ] || return 1
  line=$(cat "$1" 2>/dev/null)
  p=${line%% *}; d=${line#* }
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$d" ] && [ "$d" != "$p" ] || return 1
  printf '%s %s\n' "$p" "$d"
}

hold_pid_live() { # hold_pid_live <pidfile> — is the recorded holder still OUR holder, still running
  local rec p d
  rec=$(hold_pid_read "$1") || return 1
  p=${rec%% *}; d=${rec#* }
  kill -0 "$p" 2>/dev/null || return 1
  # Pids are reused, and this file outlives the shell that wrote it — so an `unhold` run tomorrow
  # over a stale file must never kill whatever inherited the number. The signature is the holder's
  # whole command line INCLUDING its destination: every box's holder runs the same payload, so a
  # signature without the alias would let one box's stale file kill another box's live holder and
  # drop that lane.
  # -ww: macOS ps truncates args to the output width otherwise, and this command line is long —
  # a truncated one matches nothing, and every live holder would read as somebody else's process.
  ps -ww -o args= -p "$p" 2>/dev/null | grep -q -- "$d $HOLD_CMD"
}

win_holder_seen() { # win_holder_seen <windows-alias> — true iff a wsl.exe runs on the Windows side
  # `tasklist` answers a filter that matches nothing with "INFO: No tasks are running which match
  # ...", so the image name in the output IS the signal. Any wsl.exe counts: the claim being made
  # is that something on the Windows side holds the VM, and the owner's console shell holds it
  # every bit as well as ours. Local `kill -0` on our own pid is not that claim — an ssh client
  # can outlive the command it ran.
  ssh -o BatchMode=yes -o ConnectTimeout=15 "$1" 'tasklist /FI "IMAGENAME eq wsl.exe" /NH' 2>/dev/null \
    | grep -qi 'wsl[.]exe'
}

hold_wsl() { # hold_wsl <box> <windows-alias> — spawn the holder and wait until Windows shows one
  local name=$1 dest=$2 pid f deadline started_at=""
  f=$HOLD_STATE_DIR/hold-$name.pid
  mkdir -p "$HOLD_STATE_DIR" 2>/dev/null
  if hold_pid_live "$f"; then
    pid=$(hold_pid_read "$f"); pid=${pid%% *}
    echo "  wsl holder already running for $name (pid $pid)"
  else
    # Claim the record BEFORE spawning, with noclobber. Two `--hold` runs for one box would
    # otherwise both spawn a holder and the second write would erase the first pid, leaving a
    # holder nobody can unhold and a VM pinned until the box reboots. A file left by a holder that
    # is no longer ours (checked just above) is stale and goes first.
    rm -f "$f" 2>/dev/null
    if ! ( set -C; : > "$f" ) 2>/dev/null; then
      if [ -e "$f" ]; then
        echo "  wsl holder for $name is already being created by another run ($f is claimed); nothing was started"
      else
        echo "  wsl holder on $name could NOT be recorded at $f; nothing was started"
      fi
      return 1
    fi
    ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        "$dest" "$HOLD_CMD" >/dev/null 2>&1 &
    pid=$!
    started_at=$SECONDS
    # An unrecordable holder is a leaked one: nothing would ever unhold it. Kill it rather than
    # leave it running unowned.
    if ! printf '%s %s\n' "$pid" "$dest" > "$f" 2>/dev/null; then
      kill "$pid" 2>/dev/null
      rm -f "$f" 2>/dev/null
      echo "  wsl holder on $name could NOT be recorded at $f — holder (pid $pid) killed rather than leaked"
      return 1
    fi
    echo "  wsl holder started on $name (via $dest, pid $pid)"
  fi
  # Both halves, in this order. The local pid alone is not the claim: an ssh client can outlive
  # the command it ran, and `tasklist` is what says a wsl.exe is really there. A wsl.exe alone is
  # not it either: the owner's console shell is one, and it would certify a holder of ours that
  # never started — with a log-off or an update restart then taking away the only thing holding
  # the VM. A holder whose ssh has already died cannot start being seen later, so that ends the
  # wait rather than burning the budget.
  deadline=$((SECONDS + HOLD_WAIT_SECONDS))
  while hold_pid_live "$f"; do
    if win_holder_seen "$dest"; then
      # ...and our own holder still connected, at least HOLD_SETTLE_SECONDS after it was spawned —
      # past its ConnectTimeout, so it is not one still negotiating beside somebody else's
      # wsl.exe, and not one whose remote command has already ended (ssh would have exited).
      while [ -n "$started_at" ] && [ $((SECONDS - started_at)) -lt "$HOLD_SETTLE_SECONDS" ]; do
        sleep 1
      done
      if hold_pid_live "$f"; then
        echo "  wsl holder observed on $name (wsl.exe on the Windows side, holder connected past its ${HOLD_SETTLE_SECONDS}s settle)"
        return 0
      fi
      break
    fi
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 5
  done
  release_hold "$name" >/dev/null
  return 1
}

release_hold() { # release_hold <box> — end the recorded holder; always rc 0, always says what it did
  local f=$HOLD_STATE_DIR/hold-$1.pid p
  if [ ! -r "$f" ]; then echo "  no wsl holder recorded for $1"; return 0; fi
  p=$(hold_pid_read "$f" 2>/dev/null); p=${p%% *}
  if hold_pid_live "$f"; then
    # Killing the local client closes the channel and sshd ends the command it was running. If a
    # wsl.exe is ever orphaned on the Windows side despite that, `restart-wsl` clears it: the
    # `wsl --shutdown` it issues takes every holder with the VM.
    kill "$p" 2>/dev/null
    echo "  wsl holder released on $1 (pid $p killed; the VM is unheld from now on)"
  else
    echo "  wsl holder on $1 had already exited (pid ${p:-?}); the VM was unheld"
  fi
  rm -f "$f"
  return 0
}

# ---------------------------------------------------------------- the Windows Update window
# The other way an unattended lane loses its box: an update restart takes the VM and the holder
# with it. Active hours are the only setting that prevents it, they live on the Windows side, and
# a feature update can reset them — so this is a warning, read before the units run, never after.
# It never fails a command: a box whose registry cannot be read is still a box worth sweeping.
ACTIVE_HOURS_KEY='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

reg_dword() { # reg_dword <reg-query output> <value name> — its decimal value, or ?
  local v
  v=$(printf '%s\n' "$1" | awk -v n="$2" '$1 == n && $2 ~ /REG_DWORD/ { print $3; exit }')
  case "$v" in
    0x[0-9a-fA-F]|0x[0-9a-fA-F][0-9a-fA-F]*) printf '%d\n' "$((v))" ;;
    ''|*[!0-9]*) printf '?\n' ;;
    *) printf '%d\n' "$((10#$v))" ;;
  esac
}

hour_active() { # hour_active <hour> <start> <end> — is that local hour inside the active window
  local h=$1 s=$2 e=$3
  [ "$s" = "$e" ] && return 0
  if [ "$s" -lt "$e" ]; then [ "$h" -ge "$s" ] && [ "$h" -lt "$e" ]
  else [ "$h" -ge "$s" ] || [ "$h" -lt "$e" ]; fi          # ...-0 wraps midnight: 6-0 is 06:00-24:00
}

check_active_hours() { # check_active_hours <box> <windows-alias> — one line, warn-only, rc always 0
  local name=$1 dest=$2 out s e m ws we len i h uncovered=""
  if [ -z "$dest" ]; then
    # A box that is down has no reading; that is not a finding about its settings, and a WARNING
    # here would fire on every status of a sleeping fleet until nobody read them at all.
    echo "  active hours on $name: not read (no Windows endpoint answered)"
    return 0
  fi
  # The WHOLE shape, not just the two ends: `7`, `7--11` and `24-25` all survive a check that only
  # looks at the extracted endpoints, and each would then be reported as an ordinary window.
  case "$SWEEP_HOURS" in
    [0-9]-[0-9]|[0-9]-[0-9][0-9]|[0-9][0-9]-[0-9]|[0-9][0-9]-[0-9][0-9]) ;;
    *) echo "  ACTIVE HOURS WARNING on $name: WAKE_LAB_SWEEP_HOURS='$SWEEP_HOURS' is not <start>-<end>"
       return 0 ;;
  esac
  # Base 10 explicitly: `08-11` is the natural way to write a morning window, and bash arithmetic
  # reads a leading zero as octal and dies on the 8 — aborting a check that promises only to warn.
  ws=$((10#${SWEEP_HOURS%%-*})); we=$((10#${SWEEP_HOURS##*-}))
  if [ "$ws" -gt 23 ] || [ "$we" -gt 23 ]; then
    echo "  ACTIVE HOURS WARNING on $name: WAKE_LAB_SWEEP_HOURS='$SWEEP_HOURS' is not a pair of clock hours (0-23)"
    return 0
  fi
  out=$(ssh -o BatchMode=yes -o ConnectTimeout=15 "$dest" "reg query \"$ACTIVE_HOURS_KEY\"" 2>/dev/null) || out=""
  s=$(reg_dword "$out" ActiveHoursStart)
  e=$(reg_dword "$out" ActiveHoursEnd)
  m=$(reg_dword "$out" SmartActiveHoursState)
  if [ "$s" = '?' ] || [ "$e" = '?' ]; then
    echo "  ACTIVE HOURS WARNING on $name: could not read ActiveHoursStart/End under $ACTIVE_HOURS_KEY via $dest"
    return 0
  fi
  len=$(( (we - ws + 24) % 24 )); [ "$len" -eq 0 ] && len=1
  for ((i = 0; i < len; i++)); do
    h=$(( (ws + i) % 24 ))
    hour_active "$h" "$s" "$e" || uncovered="$uncovered $h"
  done
  if [ -n "$uncovered" ]; then
    echo "  ACTIVE HOURS WARNING on $name: sweep window $SWEEP_HOURS falls outside active hours $s-$e (smart=$m); uncovered hours:$uncovered — Windows Update can restart the box mid-unit"
  elif [ "$m" != 0 ]; then
    echo "  ACTIVE HOURS WARNING on $name: active hours $s-$e cover the sweep window $SWEEP_HOURS, but SmartActiveHoursState=$m lets Windows move them"
  else
    echo "  active hours on $name: $s-$e cover the sweep window $SWEEP_HOURS (smart=$m)"
  fi
  return 0
}

win_dest() { # win_dest <box> — the first Windows alias that answers, empty if none does
  local d
  for d in $(lan_of "$1") $(ts_of "$1"); do
    [ -n "$d" ] || continue
    ssh_probe "$d" && { echo "$d"; return 0; }
  done
  echo ""
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

confirm_down() { # confirm_down <box...> — poll until ssh stops answering, to a deadline
  local names=("$@") n any deadline=$((SECONDS + DOWN_WAIT_SECONDS))
  while :; do
    any=0
    for n in "${names[@]}"; do
      if is_up "$n"; then printf '%s=up ' "$n"; any=1; else printf '%s=DOWN ' "$n"; fi
    done
    printf '(%s)\n' "$(date +%H:%M:%S)"
    [ "$any" = 0 ] && return 0
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 5
  done
  echo "still reachable after $((DOWN_WAIT_SECONDS / 60)) min — the suspend may not have taken"
  return 1
}

wait_for() { # wait_for <box...> — poll until every box answers, for up to WAIT_SECONDS
  local names=("$@") n up all deadline=$((SECONDS + WAIT_SECONDS))
  while :; do
    all=1
    for n in "${names[@]}"; do
      if is_up "$n"; then up=UP; else up=down; all=0; fi
      printf '%s=%s ' "$n" "$up"
    done
    printf '(%s)\n' "$(date +%H:%M:%S)"
    [ "$all" = 1 ] && return 0
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 5
  done
}

# start_wsl <box...> — kick (or, with FRESH_WSL, restart) WSL on each box, then poll only the boxes
# whose kick_wsl succeeded. Its status is the whole step's: 0 only when every box's command
# succeeded AND every started guest answered within the poll budget. The restart's success is
# never the guest's liveness: a `wsl --shutdown` that failed on both Windows aliases leaves the
# STALE guest answering, and polling it would print `wsl up` over exactly the degraded VM the
# restart exists to replace — and the sweep reads that line as permission to proceed. Nor is a
# guest that never answered a success: `wsl still down` is a backend the sweep cannot test. So
# `wsl up` is never printed alongside a failure, every failure names its boxes and its phase —
# the poll's aggregate verdict is re-probed per box, so one late guest does not label its
# neighbour untestable, and a refused shutdown (the old VM still answers) is told apart from a
# start that failed after the shutdown went through (no VM at all) — and every one of them
# reaches the wake path's final verdict through WSL_FAILED, so `all up` cannot paper over it.
# With HOLD, a box joins the started set only once its Windows-side holder is OBSERVED: an
# unheld VM is one an update restart or an idle shutdown can take mid-unit, which is the whole
# point of asking for a holder, so it is a failure of the step like the three above and never
# `wsl up`.
WSL_FAILED=""
start_wsl() {
  local n what=kick started=() unshut=() unstarted=() unheld=() up=() down=() rc=0 line
  [ "$FRESH_WSL" = fresh ] && what=restart
  for n in "$@"; do
    if kick_wsl "$n" "$FRESH_WSL"; then
      if [ "$HOLD" = 1 ]; then
        check_active_hours "$n" "$KICK_DEST"
        if hold_wsl "$n" "$KICK_DEST"; then started+=("$n"); else unheld+=("$n"); fi
      else
        started+=("$n")
      fi
    elif [ "$KICK_PHASE" = shutdown ]; then unshut+=("$n")
    else unstarted+=("$n"); fi
  done
  # bash 3.2 under set -u: an empty array cannot be expanded, hence the count guards.
  if [ ${#started[@]} -gt 0 ]; then
    if wait_for_wsl "${started[@]}"; then up=("${started[@]}")
    else for n in "${started[@]}"; do
      if ssh_probe "$(wsl_of "$n")"; then up+=("$n"); else down+=("$n"); fi
    done; fi
  fi
  WSL_FAILED=""
  if [ ${#up[@]} -gt 0 ]; then
    if [ ${#up[@]} -eq $# ]; then echo "wsl up"; else echo "wsl up on: ${up[*]}"; fi
  fi
  if [ ${#down[@]} -gt 0 ]; then
    line="wsl still down after $((WSL_WAIT_SECONDS / 60)) min on: ${down[*]}"
    echo "$line"; WSL_FAILED="$line"; rc=1
  fi
  if [ ${#unshut[@]} -gt 0 ]; then
    line="wsl $what FAILED on: ${unshut[*]} (shutdown refused on every alias: a -wsl guest that still answers there is the old VM)"
    echo "$line"; WSL_FAILED="${WSL_FAILED:+$WSL_FAILED; }$line"; rc=1
  fi
  if [ ${#unstarted[@]} -gt 0 ]; then
    if [ "$what" = restart ]; then line="wsl $what FAILED on: ${unstarted[*]} (shut down, then the start failed on every alias: no VM there until a kick succeeds)"
    else line="wsl $what FAILED on: ${unstarted[*]} (the start failed on every alias)"; fi
    echo "$line"; WSL_FAILED="${WSL_FAILED:+$WSL_FAILED; }$line"; rc=1
  fi
  if [ ${#unheld[@]} -gt 0 ]; then
    line="wsl HOLD FAILED on: ${unheld[*]} (the VM started but no wsl.exe was observed on the Windows side, so nothing holds it)"
    echo "$line"; WSL_FAILED="${WSL_FAILED:+$WSL_FAILED; }$line"; rc=1
  fi
  return $rc
}

wait_for_wsl() { # wait_for_wsl <box...> — tailscaled inside WSL can take >2 min after a resume
  local names=("$@") n w all deadline=$((SECONDS + WSL_WAIT_SECONDS))
  while :; do
    all=1
    for n in "${names[@]}"; do
      w=$(wsl_of "$n")
      if [ -z "$w" ]; then printf '%s=n/a ' "$n"; continue; fi
      if ssh_probe "$w"; then printf '%s-wsl=UP ' "$n"; else printf '%s-wsl=down ' "$n"; all=0; fi
    done
    printf '(%s)\n' "$(date +%H:%M:%S)"
    [ "$all" = 1 ] && return 0
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 5
  done
}

# ---------------------------------------------------------------- dispatch
WAIT=0
WANT_WSL=0
HOLD=0
FRESH_WSL=""   # "fresh" makes kick_wsl shut the VM down first; --wsl alone never kills a live VM
VERB=wake
TARGETS=()

case "${1:-}" in
  status|sleep|hibernate|down|kick-wsl|unhold) VERB=$1; shift ;;
  restart-wsl) VERB=kick-wsl; FRESH_WSL=fresh; shift ;;
esac

for arg in "$@"; do
  case "$arg" in
    --list) list_hosts; exit 0 ;;
    --wait) WAIT=1 ;;
    --wsl)  WANT_WSL=1 ;;
    --hold) HOLD=1 ;;
    --restart-wsl) WANT_WSL=1; FRESH_WSL=fresh ;;
    -h|--help) usage; exit 0 ;;
    all) TARGETS+=(rog minix asus) ;;
    *) TARGETS+=("$arg") ;;
  esac
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(rog minix)

# A --hold that holds nothing is a lane that believes it is held and is not, which is the exact
# failure this flag exists to prevent — so refuse it rather than ignore it. On the wake path that
# means --wait as well as --wsl: without --wait the wake never reaches start_wsl at all, so
# `--wsl --hold` alone would send the packets, hold nothing, and exit 0. Before load_hosts: a
# misspelled command is worth saying so on a box with no host table too.
if [ "$HOLD" = 1 ] && [ "$VERB" != kick-wsl ] &&
   { [ "$VERB" != wake ] || [ "$WANT_WSL" != 1 ] || [ "$WAIT" != 1 ]; }; then
  echo "wake-lab.sh: --hold needs a WSL start to hold" >&2
  echo "  use 'kick-wsl --hold' / 'restart-wsl --hold', or '--wait --wsl --hold' (the wake path" >&2
  echo "  starts WSL only under --wait); end it with 'unhold'." >&2
  exit 1
fi

# unhold before load_hosts, and before check_targets: releasing a local pid needs neither the MAC
# table nor the network, and a site file that went missing or unparseable after a lane started
# would otherwise strand the holder it is the only way to end. The cost is that a misspelled box
# reports no holder instead of a typo, which is the right trade for a cleanup command.
if [ "$VERB" = unhold ]; then
  for t in "${TARGETS[@]}"; do release_hold "$t"; done
  exit 0
fi

# After the argument loop on purpose: --help and --list need no site data, and both are what you
# reach for on a box where the host table has yet to be installed.
load_hosts
check_targets "${TARGETS[@]}"

case "$VERB" in
  status)
    do_status "${TARGETS[@]}"
    ;;
  kick-wsl)
    start_wsl "${TARGETS[@]}"; exit $?
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
      wsl_rc=0
      if [ "$WANT_WSL" = 1 ]; then
        UP=()
        for t in "${TARGETS[@]}"; do is_up "$t" && UP+=("$t"); done
        [ ${#UP[@]} -gt 0 ] && { start_wsl "${UP[@]}" || wsl_rc=1; }
      fi
      # The final verdict is the wake's AND the WSL step's: `all up` over a failed restart would
      # hand the sweep the degraded VM the restart exists to replace, so the WSL failure is
      # restated as the LAST line, where the sweep routine reads its verdict, and the exit
      # status says so too.
      if [ "$rc" = 0 ] && [ "$wsl_rc" = 0 ]; then
        echo "all up"
      else
        if [ "$rc" != 0 ]; then
          for t in "${TARGETS[@]}"; do is_up "$t" || echo "did NOT wake: $t"; done
          echo "Check BIOS Wake-on-LAN / 'Power Up' (minix needed the SECOND setup screen, not"
          echo "Advanced), then run scripts/enable-wol-windows.ps1 from an elevated Windows"
          echo "PowerShell to disable Fast Startup and re-arm the NIC. Check '$0 status' after the"
          echo "router lease settles; asus is Wi-Fi only and cannot be woken."
        fi
        [ "$wsl_rc" != 0 ] && echo "NOT all up: $WSL_FAILED (see above)"
        exit 1
      fi
    fi
    ;;
esac
