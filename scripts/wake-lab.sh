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
#   wake-lab.sh lock-path box             where that box's lab lock lives, for a harness taking one
#   wake-lab.sh --list                    dump the router's host table
#
# Every path that takes a box away from whatever is running on it -- `restart-wsl` and
# `--restart-wsl`, which shut the VM down host-globally, and `sleep`/`hibernate`/`down`, which take
# the whole host -- RESERVES the box first and refuses one another tool is using. The reservation is
# held across the destructive command rather than checked before it, because a check and an act
# with a gap between them is the race this exists to close. `--force` overrides, and the lab lock
# lore below says when that is the right call and what it cost the day it was not there.
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
#   how a lane takes a holder over a VM that is already running. The holder also carries that box's
#   LAB LOCK: it inherits the descriptor the lock is held on, so the flock lives exactly as long as
#   the holder and `unhold`'s kill releases it. That is what makes a held lane visible to the
#   interlock — another session's `restart-wsl` is refused, naming this holder, instead of
#   destroying the lane's VM with a host-global `wsl.exe --shutdown` (the other half of
#   2026-09-16).
# * Windows Update restarts are the other way an unattended lane loses its box, and they are
#   readable in advance: `ActiveHoursStart`, `ActiveHoursEnd` and `SmartActiveHoursState` under
#   `HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings` on the -win side. On 2026-09-15 KB5129195
#   restarted minix 21 min into its hip unit, because active hours were 10:00–01:00 and the sweep
#   runs in the morning; both boxes now pin 6→0 (the 18 h maximum) with SmartActiveHoursState=0,
#   but a feature update can reset that and nothing re-applies it. `status`, and `--hold`, read
#   those values and warn when the sweep window ($WAKE_LAB_SWEEP_HOURS, default 7-11 local) is not
#   inside them; `scripts/enable-active-hours-windows.ps1`, run from an elevated PowerShell on the
#   box the warning named, writes the three values back and is the whole repair. After the
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
# * `wsl.exe` on the Windows side can wedge and never return, and ssh will wait for it forever:
#   ConnectTimeout bounds the TCP connect ALONE, never the remote command. On 2026-09-16 a
#   `--wait --restart-wsl rog minix` sat 2h40m in `wsl.exe -d Ubuntu -e true` on rog, hanging the
#   scheduled sweep that called it — and because the loop over boxes was serialized, minix never
#   got its restart at all, so the sweep's hip unit went red on the stale-dxg condition the
#   restart exists to clear (ludics-lite#60). Two things follow, and both are load-bearing. Every
#   remote command runs under a wall-clock cap (capped(); macOS ships no timeout(1)), and the
#   boxes are kicked concurrently, so a wedge is bounded and is one box's problem alone. And a cap
#   that fires is NOT a failure: the VM had in fact started that day, `uptime -p` inside the guest
#   matching the restart to the minute while the Windows-side probe was still stuck. So on expiry
#   the guest is asked directly over its -wsl alias — which answered instantly throughout — and
#   that answer, not the wedged probe, is the evidence. But only in ONE direction: a guest that
#   answers is proof a VM is up, while a guest that does not answer proves nothing at all, because
#   the -wsl alias rides tailscaled inside the guest and that lags minutes behind a running VM
#   (the bullet above says so about every fresh kick). So a capped START with a silent guest is
#   left to the poll, and a capped SHUTDOWN with a silent guest is UNCONFIRMED — never permission
#   to start, which would attach to the old VM and then report it as the fresh one. That keeps the
#   restart's invariant: a start is issued only after a shutdown that actually returned, so a
#   guest answering after one is always the fresh VM.
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

# ssh's ConnectTimeout bounds the TCP connect ALONE and never the remote command, so every ssh
# here is unbounded the moment the far side accepts the connection and then wedges. On 2026-09-16
# that cost 2h40m: `wsl.exe -d Ubuntu -e true` on rog never returned, the caller (the scheduled
# cross-machine sweep) hung behind it, and the VM had in fact started — only the probe was stuck.
# Every remote command below therefore runs under a wall-clock cap. macOS ships no timeout(1), so
# the watchdog is a background subshell: SIGALRM at the deadline, SIGKILL a grace period later for
# anything that ignores it, and the 142/137 `wait` then reports is mapped to CAP_EXPIRED so a
# command the cap cut short is never read as one that ran and failed — the two mean opposite
# things, and the callers below act on the difference.
CAP_EXPIRED=124        # what `capped` returns for a cut-short command, as timeout(1) does
CAP_GRACE=5            # seconds between the SIGALRM and the SIGKILL behind it
capped() { # capped <seconds> <cmd...> — run cmd under a hard wall-clock cap
  local secs=$1 pid dog rc; shift
  # Redirections belong on the CALL, not in here: they then cover the watchdog too, which has
  # nothing to say, and the command keeps whatever the caller wanted to do with its output.
  "$@" & pid=$!
  # The watchdog has to be killable TOGETHER WITH its nap, and that is the whole reason for the
  # shape below. A `sleep` run in the watchdog's foreground is a separate process, so a signal to
  # the watchdog leaves it orphaned for the rest of its interval — up to WSL_START_CAP, two
  # minutes — still holding every descriptor the watchdog inherited. That is not only litter: an
  # orphan holding an inherited copy of the lab lock's descriptor keeps the lock alive after the
  # caller believes it has dropped it, which is how this was found. So the watchdog naps in a
  # background child and waits for it, which leaves it free to run a TERM trap that takes the nap
  # with it. `jobs -p` rather than a remembered `$!`, because a TERM arriving between the fork and
  # the assignment would find that variable unset, and that is the one window a remembered pid
  # cannot cover; `jobs -p` is whatever is actually running, whenever the trap happens to run.
  { trap 'kill -KILL $(jobs -p) 2>/dev/null; exit 0' TERM
    sleep "$secs" & wait $!
    kill -ALRM "$pid" 2>/dev/null
    sleep "$CAP_GRACE" & wait $!
    kill -KILL "$pid" 2>/dev/null; } >/dev/null 2>&1 &
  dog=$!
  # TERM, not KILL: the trap above is what reaps the nap, and an untrappable signal would put the
  # orphan straight back. A watchdog that somehow missed the trap still dies on TERM's default
  # action, so there is no path on which this wait outlives the watchdog.
  wait "$pid"; rc=$?
  kill -TERM "$dog" >/dev/null 2>&1; wait "$dog" >/dev/null 2>&1
  case "$rc" in 142|137) return "$CAP_EXPIRED" ;; esac
  return "$rc"
}

# The probes are capped as well, and not only for tidiness: a single wedged probe inside one of the
# polling loops below hangs it forever, because those loops check their deadline BETWEEN
# iterations. The cap is deliberately loose against the ConnectTimeout it wraps — it exists to
# bound a remote command that never returns, not to second-guess a slow connect.
PROBE_CAP=${WAKE_LAB_PROBE_CAP:-20}
ssh_probe() { # ssh_probe <alias> [timeout] — true iff sshd answers and authentication succeeds
  [ -n "$1" ] || return 1
  # `exit 0`, NOT `true`: the -win/-lan aliases land in cmd.exe, which has no `true` and would
  # report every Windows box as down. `exit 0` is valid in cmd.exe and in POSIX shells alike.
  capped "$PROBE_CAP" \
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
# Caps for the two remote commands of the kick/restart path, which are the ones observed to wedge.
# Sized to be generous against how long each really takes — a `wsl --shutdown` is seconds and a
# cold VM start is well under a minute — because the cap is here to end a command that will never
# return, not to give up on a slow one.
WSL_SHUTDOWN_CAP=${WAKE_LAB_WSL_SHUTDOWN_CAP:-60}
WSL_START_CAP=${WAKE_LAB_WSL_START_CAP:-120}

# ---------------------------------------------------------------- the lab lock
# `wsl.exe --shutdown` is HOST-GLOBAL: it destroys the whole WSL2 VM, so every session on that box
# dies with it -- an in-flight sweep unit, and whatever terminals the operator had open. kick_wsl's
# own note ("the shutdown lands on the Windows host, never inside the VM, so it cannot kill the
# session issuing it") is true and was exactly the blind spot: it reasons about the session ISSUING
# the shutdown and says nothing about every other session on the VM.
#
# On 2026-09-16 that cost the cross-machine sweep both GPU units. Sweep 20260916T074913Z was
# 13 minutes into rog-nv/cuda and minix/hip when a second session, verifying a fix to THIS script
# against the real lab, ran `wake-lab.sh --wait --restart-wsl rog minix` at 08:02:30Z. Both guests
# rebooted (08:02:37Z, 08:02:40Z -- three seconds apart because the restart above is concurrent)
# and both units died on a reset connection seconds later. The sweep logged it as `error`, which
# reads as a box fault, and the failure was misattributed to the GPU autotune tests for two days:
# they are the longest-running tests in the suite, so a randomly-timed external kill lands in them
# far more often than anywhere else.
#
# So the boxes are a SHARED resource and destroying one needs an interlock. The lock is a file per
# box under a directory both this script and the sweep agree on, and the contract is deliberately
# nothing more than that directory, a filename and a one-line holder description: the sweep takes
# its own flock and does not need this script installed, which keeps a harness on another machine
# from depending on a symlink in ~/bin.
#
#   <dir>/<box>.lock   flock held EXCLUSIVE for as long as the holder is using the box
#   first line         "<what> (pid <pid>, since <utc>)" -- advisory, for the refusal message
#
# flock and not a pidfile for the reasons sweep.sh gives about its own run lock: there is nothing
# to reclaim after a crash, no window between creating the lock and publishing ownership, and the
# kernel releases it when the holder dies however it dies. The holder line is advisory only -- it
# names who to go and look at, and a stale or missing one never decides anything.
LOCK_DIR=${WAKE_LAB_LOCK_DIR:-$HOME/.local/state/wake-lab}

lab_lock_path() { # lab_lock_path <box> — where that box's lock lives
  printf '%s/%s.lock' "$LOCK_DIR" "$1"
}

# Take the box's lock and HOLD it, on a descriptor the calling shell keeps open until it exits.
#
# Asking whether the lock is free and then acting on the answer is the very race this interlock
# exists to close: a probe that takes the lock and releases it leaves a window between the check
# and the `wsl.exe --shutdown`, and a sweep that reserves the box inside that window is destroyed
# by a restart that had already decided it was allowed to proceed. So the restarter becomes a
# holder rather than an observer — there is no window because there is no interval in which
# nothing holds the lock.
#
# Every caller runs this inside a per-box SUBSHELL, so fd 8 is that subshell's own and concurrent
# boxes cannot collide on it; the lock lives exactly as long as the work it guards. A lock file
# that cannot be created or opened at all is treated as free, deliberately: that is a fault in
# this machine's state directory, and it must not lock the operator out of their own lab (a real
# holder had to create the file to hold it).
# The descriptor is a parameter so that ONE process can hold several boxes at once, each on its
# own: `power_phase` reserves every box it is about to act on and must keep all of them for as long
# as it acts. bash 3.2 has no `exec {fd}>`, hence the eval over an explicitly chosen number.
lab_lock_take_fd() { # lab_lock_take_fd <box> <what> <fd> — 0 taken and held, 1 someone else holds it
  local path; path=$(lab_lock_path "$1")
  mkdir -p "$LOCK_DIR" 2>/dev/null || return 0
  eval "exec $3>>\"\$path\"" 2>/dev/null || return 0
  perl -e 'use Fcntl ":flock"; exit(flock(STDIN, LOCK_EX | LOCK_NB) ? 0 : 1)' <&"$3" || return 1
  printf 'wake-lab %s (pid %s, since %s)\n' "$2" "$$" "$(date -u +%Y%m%dT%H%M%SZ)" \
    >"$path" 2>/dev/null
  return 0
}

lab_lock_take() { # lab_lock_take <box> <what> — the single-box form, on fd 8
  lab_lock_take_fd "$1" "$2" 8
}

# The holder's own description of itself, for the refusal message. Never trusted for the decision
# -- taking the lock makes that -- so an empty or truncated line degrades to a bare "held".
lab_lock_holder() { # lab_lock_holder <box>
  local path line; path=$(lab_lock_path "$1")
  line=$(head -1 "$path" 2>/dev/null | tr -d '\000-\037')
  printf '%s' "${line:-held by an unnamed holder}"
}

# The whole power phase, with every box it acts on RESERVED from before its command is sent until
# that box is confirmed down.
#
# `hibernate` terminates the WSL VM outright (kick_wsl's note says so), `down` is a full host
# shutdown, and `sleep` suspends the host under whatever is running on it — all three destroy a
# reserved workload exactly as `wsl.exe --shutdown` does, so the interlock that covers the restart
# has to cover them too.
#
# And it has to cover the EFFECT, not the command. A dropped ssh means the suspend was INITIATED,
# not that the host is gone: for the seconds or minutes until it actually goes down the box still
# answers, so a reservation released when `power_action` returns lets another harness take the lock
# and start work that the pending transition then destroys. That is the restart's mistake one layer
# out — there the reservation did not cover the shutdown, here it did not cover what the shutdown
# does — so the rule this file holds is that a reservation spans the effect, never the command.
#
# THIS process holds every reservation, one descriptor each, and it is also the process that acts.
# An earlier version reserved box N at recursion level N, each level a subshell, so the descriptors
# lived in a chain of waiting ancestors — and killing the top-level command then released the first
# box's lock while the surviving descendant went on issuing and confirming its suspend, freeing a
# box whose power transition was still pending. Descriptors held by the actor cannot outlive it or
# be released ahead of it: kill the command and every reservation goes at once, which is the only
# arrangement where "reserved" and "still acting" cannot come apart. It is also the simpler one —
# a flat loop rather than a recursion — and it keeps the confirmation concurrent, against one
# deadline, where confirming box by box would multiply the worst-case wait by the number of boxes.
power_phase() { # power_phase <verb> <box...> — nonzero if any box was refused or never went down
  local verb=$1; shift
  local box fd=8 rc=0 acted=() refused=()
  for box in "$@"; do
    if [ "$FORCE" = 1 ]; then acted+=("$box"); continue; fi
    if lab_lock_take_fd "$box" "$verb" "$fd"; then
      acted+=("$box"); fd=$((fd + 1))
    else
      echo "  $verb REFUSED on $box: $(lab_lock_holder "$box")"
      refused+=("$box")
    fi
  done
  # Only the boxes actually acted on are confirmed: polling a refused box for the DOWN signal
  # would report the holder's live machine as a failure to go down.
  if [ ${#acted[@]} -gt 0 ]; then
    for box in "${acted[@]}"; do power_action "$verb" "$box"; done
    echo "confirming..."
    # Its status is the phase's: a box that never went down is a failure of this command, and
    # letting a trailing conditional swallow it would report success over the very line that says
    # the suspend may not have taken.
    confirm_down "${acted[@]}" || rc=1
  fi
  if [ ${#refused[@]} -gt 0 ]; then
    echo "$verb REFUSED on: ${refused[*]} (the lab lock is held; wait for the holder, or --force to take the box anyway)"
    rc=1
  fi
  return $rc
}

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
  # Both commands run under `capped`, and a cap that fires is NOT a failure: it is a command with
  # no verdict, and the guest itself is then asked instead (see the CAP_EXPIRED branches). That
  # distinction is the whole point — on 2026-09-16 the start probe wedged on rog for 2h40m over a
  # VM that had started perfectly, and reading the wedge as a failure would have been as wrong as
  # the old unbounded wait was.
  #
  # On failure KICK_PHASE says which phase failed, because the two mean opposite things to the
  # operator: `shutdown` — no alias carried the shutdown, so a -wsl guest that still answers is
  # the OLD VM; `start` — the shutdown went through and the start then failed everywhere, so
  # there is no VM at all until a kick succeeds; `kick` — the plain kick's start failed.
  local name=$1 fresh=${2:-} dest what=kick shut=0 capped_start=0 capped_dest="" guest rc
  [ "$fresh" = fresh ] && what=restart
  guest=$(wsl_of "$name")
  for dest in $(lan_of "$name") $(ts_of "$name"); do
    [ -n "$dest" ] || continue
    # An ssh network logon is session enough: this works with nobody logged in at the console.
    if [ "$fresh" = fresh ]; then
      capped "$WSL_SHUTDOWN_CAP" \
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$dest" 'wsl.exe --shutdown' >/dev/null 2>&1
      rc=$?
      if [ "$rc" = "$CAP_EXPIRED" ]; then
        # The command never returned, so its status says nothing about the teardown — and NOTHING
        # here can supply that. A silent guest does not mean a stopped VM: the -wsl alias rides
        # tailscaled inside the guest, which this file's own lore says lags minutes behind a
        # running VM, so "no guest answers" is the everyday reading of a VM that is perfectly
        # alive. Starting on that evidence would attach to the old VM and then report the fresh
        # restart the sweep is waiting for, which is precisely the stale bridge restart-wsl exists
        # to replace. So a capped shutdown is UNCONFIRMED, whatever the guest says, and this alias
        # has not carried the restart: retry the whole thing on the next one, and if none carries
        # it the step fails as a shutdown failure. The guest is still probed, because "the old VM
        # demonstrably still answers" and "nothing is known" read differently to an operator, but
        # neither of them is permission to start.
        if [ -n "$guest" ] && ssh_probe "$guest"; then
          echo "  wsl shutdown TIMED OUT after ${WSL_SHUTDOWN_CAP}s on $name (via $dest); the guest still answers, so the old VM stands"
        else
          echo "  wsl shutdown TIMED OUT after ${WSL_SHUTDOWN_CAP}s on $name (via $dest); no guest answers, but a silent guest is not a stopped VM — the teardown is unconfirmed"
        fi
        continue
      elif [ "$rc" != 0 ]; then
        continue
      else
        echo "  wsl shut down on $name (via $dest)"
      fi
      shut=1
    fi
    capped "$WSL_START_CAP" \
      ssh -o BatchMode=yes -o ConnectTimeout=15 "$dest" 'wsl.exe -d Ubuntu -e true' >/dev/null 2>&1
    rc=$?
    if [ "$rc" = 0 ]; then
      echo "  wsl started on $name (via $dest)"
      KICK_DEST=$dest
      return 0
    fi
    if [ "$rc" = "$CAP_EXPIRED" ]; then
      # The start was issued and the probe simply never came back. A guest that answers settles it.
      if [ -n "$guest" ] && ssh_probe "$guest"; then
        echo "  wsl start probe timed out after ${WSL_START_CAP}s on $name (via $dest); the guest answers, so the VM is up"
        KICK_DEST=$dest
        return 0
      fi
      capped_start=1
      # The alias whose start went out, kept for the hold: on the kick path the loop goes on to
      # try the other alias, and a later alias that FAILS must not leave the holder pointed at an
      # endpoint that answers nothing. Only a start that succeeds later replaces it.
      [ -n "$capped_dest" ] || capped_dest=$dest
      # With the guest silent there is no verdict here, and what to do next differs by path. A
      # RESTART must not fall through: the next alias would issue a second `wsl --shutdown`,
      # tearing down the very VM this start may have just booted, so the box goes to start_wsl's
      # poll, which asks the guest on its own deadline. A plain KICK has no shutdown to repeat and
      # a second start is idempotent, so the other alias is worth trying — a wedged LAN side must
      # not cost a box the start its Tailscale alias would have carried.
      echo "  wsl start probe timed out after ${WSL_START_CAP}s on $name (via $dest); leaving the verdict to the guest poll"
      if [ "$fresh" = fresh ]; then KICK_DEST=$dest; return 0; fi
    fi
  done
  # Every alias tried and one of them left a start in flight: a cap is not a failure anywhere else
  # in this function and it is not one here either, so the poll gets the box rather than the
  # operator getting a kick that may well have worked.
  if [ "$capped_start" = 1 ]; then
    echo "  wsl $what start probe timed out on every alias on $name; leaving the verdict to the guest poll"
    KICK_DEST=$capped_dest
    return 0
  fi
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

# The record is "<pid> <destination> <spawn epoch> <lock sidecar pid>". The destination is part of
# the holder's identity (every box's holder runs the same payload), the epoch is how a LATER
# invocation that reuses this holder knows whether it is past its settle, and the sidecar is the
# process that keeps the box's lab lock open for as long as the holder lives (see hold_wsl).
hold_pid_read() { # hold_pid_read <pidfile> — echo "<pid> <dest> <epoch> <sidecar>", fail if unusable
  local line p d t sc
  [ -r "$1" ] || return 1
  line=$(cat "$1" 2>/dev/null)
  read -r p d t sc <<<"$line"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$d" ] && [ "$d" != "$p" ] || return 1
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  case "$sc" in ''|*[!0-9]*) sc=0 ;; esac
  printf '%s %s %s %s\n' "$p" "$d" "$t" "$sc"
}

hold_pid_live() { # hold_pid_live <pidfile> — is the recorded holder still OUR holder, still running
  local rec p d t sc
  rec=$(hold_pid_read "$1") || return 1
  read -r p d t sc <<<"$rec"; : "$t" "$sc"
  kill -0 "$p" 2>/dev/null || return 1
  # A zombie answers `kill -0` and, on Linux, still prints its old command line — so an exited
  # holder whose parent has not reaped it would read as live.
  case "$(ps -o state= -p "$p" 2>/dev/null)" in *Z*) return 1 ;; esac
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
  # Capped like every other remote command here: ConnectTimeout bounds the connect, not the
  # remote command, and an accepted session whose `tasklist` never returns would stop the hold's
  # own deadline from advancing — the 2026-09-16 wedge, reintroduced behind a new probe. A cap
  # that fires is simply "not observed this round"; the loop asks again until HOLD_WAIT_SECONDS.
  local out
  out=$(capped "$PROBE_CAP" ssh -o BatchMode=yes -o ConnectTimeout=15 "$1" \
        'tasklist /FI "IMAGENAME eq wsl.exe" /NH' 2>/dev/null) || return 1
  printf '%s' "$out" | tr -d '\r' | grep -qi 'wsl[.]exe'
}

# A VM this run started fresh and then could not hold is worse than no VM: the sweep's lanes probe
# the -wsl guest themselves, so a reachable-but-unheld guest runs a GPU unit that then dies
# mid-run, which is the whole failure being fixed. Shut it down instead and let the unit record an
# honest `skip (unreachable)`. Only for a VM this run created (`restart-wsl`): on a plain kick the
# guest may be the owner's, and taking it away over a failed hold would be a nasty surprise.
shutdown_unheld_vm() { # shutdown_unheld_vm <box> <windows-alias> — rc 0 only if the VM really went
  # Every alias, starting with the one that carried the start: the reason we are here is that
  # something went wrong on that side during the hold, and the alias may be exactly what went
  # wrong. The kick tries both for the same reason; leaving a reachable unheld VM up because one
  # endpoint stopped answering is the outcome this whole function exists to avoid.
  local d tried=""
  for d in "$2" $(lan_of "$1") $(ts_of "$1"); do
    [ -n "$d" ] || continue
    case " $tried " in *" $d "*) continue ;; esac
    tried="$tried $d"
    if capped "$WSL_SHUTDOWN_CAP" \
        ssh -o BatchMode=yes -o ConnectTimeout=15 "$d" 'wsl.exe --shutdown' >/dev/null 2>&1; then
      echo "  wsl shut down on $1 (via $d): a fresh VM that cannot be held would die mid-unit, so the lane records no coverage instead"
      return 0
    fi
  done
  echo "  wsl on $1 is up and UNHELD and the shutdown failed on every alias: do not sweep that box"
  return 1
}

hold_wsl() { # hold_wsl <box> <windows-alias> — spawn the holder and wait until Windows shows one
  local name=$1 dest=$2 pid f deadline rec spawn_epoch spawned=0 sidecar=0 now own theirs _
  # The lane's reservation, and the holder is what carries it. A restart path already holds this
  # box's lab lock on fd 8 (start_wsl takes it before the kick); a plain `kick-wsl --hold` does
  # not, so it takes it here, on the same descriptor. Either way the holder we spawn INHERITS that
  # descriptor, so the flock lives exactly as long as the holder does — an inheriting child keeping
  # an flock alive is the semantics ludics-lite#168 documents — and `unhold`'s kill releases it
  # with no separate release path to get wrong. The consequence that matters: while a lane holds a
  # box, another session's `restart-wsl` is REFUSED instead of destroying that lane's VM with a
  # host-global `wsl.exe --shutdown`.
  f=$HOLD_STATE_DIR/hold-$name.pid
  mkdir -p "$HOLD_STATE_DIR" 2>/dev/null
  if hold_pid_live "$f"; then
    # Reuse: the live holder already carries this box's lock, and taking it again from here would
    # fail against our own holder.
    rec=$(hold_pid_read "$f"); read -r pid _ spawn_epoch _ <<<"$rec"
    # A clock corrected backwards would leave an epoch in the future and park the settle loop
    # there for as long as the correction; a holder cannot have been spawned after now.
    now=$(date +%s); [ "$spawn_epoch" -gt "$now" ] && spawn_epoch=$now
    echo "  wsl holder already running for $name (pid $pid)"
  else
    if [ "${LANE_LOCKED:-0}" != 1 ] && ! lab_lock_take "$name" "--hold"; then
      if [ "$FORCE" = 1 ]; then
        echo "  wsl holder on $name proceeds WITHOUT the lab lock (--force): $(lab_lock_holder "$name")"
      else
        echo "  wsl holder NOT started on $name: $(lab_lock_holder "$name") — that box is reserved; wait for the holder, or --force"
        return 1
      fi
    fi
    # An EMPTY record is another run's claim, between its noclobber create and its pid write —
    # removing it as stale would let both runs spawn a holder with only one pid recorded, which is
    # the race this claim exists to prevent. Only an empty claim old enough to be abandoned (its
    # creator died in that one fork) is cleared; a record with a pid in it has already been judged
    # by hold_pid_live above.
    if [ -e "$f" ] && [ ! -s "$f" ] && [ -z "$(find "$f" -mmin +1 2>/dev/null)" ]; then
      echo "  wsl holder for $name is being created by another run ($f is claimed); nothing was started"
      return 1
    fi
    # Claim the record BEFORE spawning, with noclobber. Two `--hold` runs for one box would
    # otherwise both spawn a holder and the second write would erase the first pid, leaving a
    # holder nobody can unhold and a VM pinned until the box reboots.
    rm -f "$f" 2>/dev/null
    if ! ( set -C; : > "$f" ) 2>/dev/null; then
      if [ -e "$f" ]; then
        echo "  wsl holder for $name is already being created by another run ($f is claimed); nothing was started"
      else
        echo "  wsl holder on $name could NOT be recorded at $f; nothing was started"
      fi
      return 1
    fi
    # NOT capped, and that is deliberate: every other remote command here is a finite probe, and
    # this one is meant to run until `unhold` kills it. A cap on the holder would be a timer on
    # the lane — the sized `sleep N` this design exists to avoid, wearing a different hat.
    # `-n` and </dev/null: an ssh backgrounded from a terminal otherwise reads the caller's stdin
    # and can be stopped by SIGTTIN — and a STOPPED holder answers `kill -0` exactly like a live
    # one, so the lane would believe in a holder that is not running.
    ssh -n -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
        "$dest" "$HOLD_CMD" >/dev/null 2>&1 </dev/null &
    pid=$!
    # The lock must not depend on what the ssh client does with descriptors it inherited: OpenSSH
    # may close everything above stderr at startup, and then nothing would hold the flock once
    # this subshell exits. So a sidecar process holds fd 8 instead — it inherits the very
    # descriptor the flock lives on, so there is no window in which the box is unreserved — and it
    # exits as soon as the holder does, by `unhold` or otherwise, taking the lock with it.
    #
    # It is an EXEC'd process, not a brace group: a forked bash keeps every descriptor bash holds
    # internally, including its copy of a caller's pipe, and a background child holding that pipe
    # hangs `wake-lab.sh kick-wsl --hold rog | tee log` — or any caller reading the command's
    # output — for the whole life of the lane. Those descriptors are close-on-exec, so exec'ing
    # anything sheds them; fd 8, opened here, is not, so the lock survives. perl is already the
    # lab lock's own dependency.
    perl -e 'my $tag = "wake-lab-hold-lock"; my $p = shift; while (kill 0, $p) { sleep 1 }' \
      "$pid" >/dev/null 2>&1 </dev/null &
    sidecar=$!
    spawn_epoch=$(date +%s); spawned=1
    # An unrecordable holder is a leaked one: nothing would ever unhold it. Kill it rather than
    # leave it running unowned.
    if ! printf '%s %s %s %s\n' "$pid" "$dest" "$spawn_epoch" "$sidecar" > "$f" 2>/dev/null; then
      kill "$pid" "$sidecar" 2>/dev/null
      rm -f "$f" 2>/dev/null
      echo "  wsl holder on $name could NOT be recorded at $f — holder (pid $pid) killed rather than leaked"
      return 1
    fi
    echo "  wsl holder started on $name (via $dest, pid $pid)"
    # Between `&` and the exec, the child is still a copy of THIS shell and its command line does
    # not carry the holder's signature yet — so a signature check run straight away can read a
    # perfectly good holder as dead, tear the record down, and leave the child to exec into an
    # infinite holder nobody records. Give the fork a bounded moment to become the ssh.
    for _ in 1 2 3 4 5; do
      hold_pid_live "$f" && break
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
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
      # ...and our own holder still connected, at least HOLD_SETTLE_SECONDS after it was SPAWNED —
      # past its ConnectTimeout, so it is not one still negotiating beside somebody else's
      # wsl.exe, and not one whose remote command has already ended (ssh would have exited). The
      # bound is on the holder's age, not on this invocation's, so a run that REUSES a holder
      # another run started a second ago waits out the rest of that holder's settle too.
      while [ $(( $(date +%s) - spawn_epoch )) -lt "$HOLD_SETTLE_SECONDS" ]; do
        # The settle waits on the holder, so it ends when the holder does — and never outlives the
        # step's own deadline, whatever the recorded epoch says.
        hold_pid_live "$f" || break
        [ "$SECONDS" -ge "$deadline" ] && break
        sleep 1
      done
      # The settle must have been SERVED, not merely attempted: the loop above also ends on the
      # step's deadline, and a settle cut short by it is a holder that has not shown it outlived
      # its own ConnectTimeout. Reporting that as observed would be the claim this whole check
      # exists to make, made without the evidence.
      if [ $(( $(date +%s) - spawn_epoch )) -ge "$HOLD_SETTLE_SECONDS" ] && hold_pid_live "$f"; then
        echo "  wsl holder observed on $name (wsl.exe on the Windows side, holder connected past its ${HOLD_SETTLE_SECONDS}s settle)"
        return 0
      fi
      break
    fi
    [ "$SECONDS" -ge "$deadline" ] && break
    sleep 5
  done
  # Only a holder THIS call spawned is cleaned up. One we merely reused belongs to an earlier
  # invocation that may still be protecting a running lane, and killing it over a failed probe of
  # ours would unhold that lane's VM — the failure this whole flag exists to prevent, caused by a
  # retry.
  if [ "$spawned" = 1 ] && [ "$(hold_pid_read "$f" 2>/dev/null | cut -d' ' -f1)" = "$pid" ]; then
    # Our own record, so kill the pid we spawned WITHOUT asking for the signature again: a child
    # still between fork and exec carries none, and release_hold would then drop the record and
    # leave it to become an unrecorded holder. There is no pid-reuse hazard here — this pid is our
    # own child, alive or not, for as long as this shell has not reaped it.
    # ...but prove the pid is still ours before signalling it. Two shapes count: it carries the
    # holder's signature, or its command line is still a copy of OURS, which is what a child
    # between fork and exec looks like. Anything else is a number that has been recycled onto an
    # unrelated process, and killing that would be far worse than leaving a holder to be reaped.
    if hold_pid_live "$f" ||
       { own=$(ps -ww -o args= -p $$ 2>/dev/null); theirs=$(ps -ww -o args= -p "$pid" 2>/dev/null)
         [ -n "$theirs" ] && [ "$theirs" = "$own" ]; }; then
      kill "$pid" "$sidecar" 2>/dev/null
      echo "  wsl holder on $name stopped (pid $pid): nothing holds that VM"
    else
      echo "  wsl holder on $name is gone (pid $pid no longer names it): nothing holds that VM"
    fi
    rm -f "$f" 2>/dev/null
  elif [ "$spawned" = 1 ]; then
    # We spawned a holder, but the record no longer names it: a concurrent run replaced it after
    # ours exited. Killing what the file names now would unhold THAT run's lane.
    echo "  wsl holder for $name was not observed; the record now names another run's holder, left alone"
  else
    echo "  wsl holder for $name was not observed, but it belongs to an earlier run: left running and recorded"
  fi
  return 1
}

release_hold() { # release_hold <box> — end the recorded holder; always rc 0, always says what it did
  local f=$HOLD_STATE_DIR/hold-$1.pid rec p d t sc
  if [ ! -r "$f" ]; then echo "  no wsl holder recorded for $1"; return 0; fi
  rec=$(hold_pid_read "$f" 2>/dev/null) || rec=""
  read -r p d t sc <<<"${rec:-}"; : "$d" "$t"
  # The lock sidecar goes with the holder: it exits on its own once the holder is gone, and
  # killing it here is what makes the box free again immediately rather than a poll later. Its pid
  # is checked the way the holder's is — a record outlives both processes, and by the time anyone
  # runs `unhold` the number may belong to something else entirely.
  if [ -n "${sc:-}" ] && [ "${sc:-0}" != 0 ] &&
     ps -ww -o args= -p "$sc" 2>/dev/null | grep -q 'wake-lab-hold-lock'; then
    kill "$sc" 2>/dev/null
  fi
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
# Every warning about the BOX's own values names scripts/enable-active-hours-windows.ps1, which
# writes the three of them back: a warning whose repair has to be reconstructed from the registry
# path is one that gets read and left. The WAKE_LAB_SWEEP_HOURS warnings do not name it — those
# are a misconfiguration on this side, and nothing on the box would change — and neither does the
# unreadable-registry one, which knows of no setting to repair.
ACTIVE_HOURS_KEY='HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
# The repair advice itself, once: four warnings carried four verbatim copies, and only one of them
# was pinned by a test. It has no leading punctuation, so each site spells its own joiner — the
# "falls outside" line already carries an em-dash and takes a semicolon instead.
ACTIVE_HOURS_REPAIR='repair with scripts/enable-active-hours-windows.ps1 on the box (elevated PowerShell)'

reg_dword() { # reg_dword <reg-query output> <value name> — its decimal value, or ?
  local v
  # The CR is not cosmetic: reg.exe writes CRLF, and a value carrying a trailing \r matches
  # neither the hex nor the decimal branch below, so every real reading would come back `?` and
  # the check would report an unreadable registry on every box, forever.
  v=$(printf '%s\n' "$1" | awk -v n="$2" '{ sub(/\r$/, "") } $1 == n && $2 ~ /REG_DWORD/ { print $3; exit }')
  case "$v" in
    0x[0-9a-fA-F]|0x[0-9a-fA-F][0-9a-fA-F]*) printf '%d\n' "$((v))" ;;
    ''|*[!0-9]*) printf '?\n' ;;
    *) printf '%d\n' "$((10#$v))" ;;
  esac
}

hour_active() { # hour_active <hour> <start> <end> — is that local hour inside the active window
  # Equal endpoints never reach here: check_active_hours refuses them as a malformed setting
  # rather than reading them as a 24-hour window.
  local h=$1 s=$2 e=$3
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
  out=$(capped "$PROBE_CAP" ssh -o BatchMode=yes -o ConnectTimeout=15 "$dest" \
        "reg query \"$ACTIVE_HOURS_KEY\"" 2>/dev/null) || out=""
  s=$(reg_dword "$out" ActiveHoursStart)
  e=$(reg_dword "$out" ActiveHoursEnd)
  m=$(reg_dword "$out" SmartActiveHoursState)
  if [ "$s" = '?' ] || [ "$e" = '?' ]; then
    echo "  ACTIVE HOURS WARNING on $name: could not read ActiveHoursStart/End under $ACTIVE_HOURS_KEY via $dest"
    return 0
  fi
  # Numeric is not the same as valid. `24-24` reaches hour_active's equal-endpoint branch, which
  # calls every hour covered — so a box whose update protection is set to nonsense would report
  # the quiet line instead of the warning that is the only notice anyone gets.
  if [ "$s" -gt 23 ] || [ "$e" -gt 23 ]; then
    echo "  ACTIVE HOURS WARNING on $name: active hours read as $s-$e, which are not clock hours (0-23): the update protection on that box is not valid — $ACTIVE_HOURS_REPAIR"
    return 0
  fi
  # Equal endpoints are not a 24-hour window. Windows allows at most 18 hours (this file's own
  # lore: the boxes pin 6→0 as the maximum), so `6-6` is a reset or a malformed setting — and
  # reading it as "every hour protected" would print the quiet line over a box with no protection.
  # ...and the same bound from the other side: Windows allows at most 18 hours, so `1-23` is as
  # impossible as `6-6`, and reading a 22-hour span as coverage hides the risk this line exists to
  # show. Equal endpoints are the zero/24 case of the same check.
  len=$(( (e - s + 24) % 24 ))
  if [ "$len" -eq 0 ] || [ "$len" -gt 18 ]; then
    echo "  ACTIVE HOURS WARNING on $name: active hours read as $s-$e, a span Windows cannot mean (its maximum is 18 h), so the setting is reset or malformed — $ACTIVE_HOURS_REPAIR"
    return 0
  fi
  # End-exclusive, so equal endpoints are an empty range, not a one-hour one: forcing len=1 would
  # judge a single hour and print the quiet line over a window nobody meant.
  if [ "$ws" -eq "$we" ]; then
    echo "  ACTIVE HOURS WARNING on $name: WAKE_LAB_SWEEP_HOURS='$SWEEP_HOURS' is an empty range (the end is exclusive)"
    return 0
  fi
  len=$(( (we - ws + 24) % 24 ))
  for ((i = 0; i < len; i++)); do
    h=$(( (ws + i) % 24 ))
    hour_active "$h" "$s" "$e" || uncovered="$uncovered $h"
  done
  if [ -n "$uncovered" ]; then
    echo "  ACTIVE HOURS WARNING on $name: sweep window $SWEEP_HOURS falls outside active hours $s-$e (smart=$m); uncovered hours:$uncovered — Windows Update can restart the box mid-unit; $ACTIVE_HOURS_REPAIR"
  elif [ "$m" != 0 ]; then
    echo "  ACTIVE HOURS WARNING on $name: active hours $s-$e cover the sweep window $SWEEP_HOURS, but SmartActiveHoursState=$m lets Windows move them — $ACTIVE_HOURS_REPAIR"
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
  local n i dir krc kphase kheld what=kick started=() unshut=() unstarted=() up=() down=() rc=0 line
  local unheld_down=() unheld_up=() held=()
  [ "$FRESH_WSL" = fresh ] && what=restart
  # One box at a time meant one wedged box could cost its neighbours their restart entirely: on
  # 2026-09-16 rog's start probe hung and minix, second in the loop, never got a restart at all —
  # its VM sat eleven hours old and the sweep's hip unit went red on exactly the stale-dxg
  # condition restart-wsl exists to clear. The boxes are independent Windows hosts and nothing in
  # the kick is shared, so kick them all at once. Each box's output is buffered and replayed in
  # target order afterwards, so the log still reads box by box rather than interleaved.
  dir=$(mktemp -d "${TMPDIR:-/tmp}/wake-lab-wsl.XXXXXX") || {
    echo "wsl $what FAILED: no work directory" >&2; WSL_FAILED="wsl $what FAILED: no work directory"; return 1; }
  # Physical path, the house idiom: $TMPDIR on macOS is under /var, a symlink to /private/var
  # (ludics-lite#208).
  dir=$(cd "$dir" && pwd -P) || {
    echo "wsl $what FAILED: no work directory" >&2; WSL_FAILED="wsl $what FAILED: no work directory"; return 1; }
  i=0
  for n in "$@"; do
    i=$((i + 1))
    # The reservation is taken INSIDE this subshell and held until it exits, so the lock covers the
    # `wsl.exe --shutdown` itself rather than a moment before it. The lock is consulted ONLY on the
    # destructive path: a plain kick starts an already-running VM as a no-op and cannot cost a
    # holder anything, so gating it would buy nothing and would make `kick-wsl` -- the recovery
    # command for a box with no VM at all -- refusable at exactly the moment it is needed.
    #
    # KICK_PHASE and KICK_DEST are set in the subshell, so they come back alongside the status
    # rather than as globals; a box whose subshell died outright reads as a plain failed start,
    # never as a success. `locked` is a phase of its own for the same reason the others are: it
    # names a different remedy (wait for the holder) from every other way a box can fail to
    # restart. The HOLD step runs in this same subshell, for the same reason the kick does: a box
    # whose holder cannot be established must not cost its neighbour the settle — and because the
    # lock this subshell already holds is the one the holder must inherit.
    { if [ "$FRESH_WSL" = fresh ] && [ "$FORCE" != 1 ] && ! lab_lock_take "$n" "$what"; then
        echo "  wsl $what REFUSED on $n: $(lab_lock_holder "$n")" >"$dir/$i.out" 2>&1
        printf '1 locked na\n' >"$dir/$i.rc"
      else
        [ "$FRESH_WSL" = fresh ] && [ "$FORCE" != 1 ] && LANE_LOCKED=1
        kick_wsl "$n" "$FRESH_WSL" >"$dir/$i.out" 2>&1
        krc=$?; kheld=na
        if [ "$krc" = 0 ] && [ "$HOLD" = 1 ]; then
          { check_active_hours "$n" "$KICK_DEST"
            if [ -z "$KICK_DEST" ]; then
              echo "  wsl holder NOT started on $n: no Windows alias carried the start"
              kheld=failup
            elif hold_wsl "$n" "$KICK_DEST"; then kheld=ok
            else
              # `failup` unless the VM was really taken down: on the kick path there is no shutdown
              # to attempt (the guest may be the owner's), and a fresh-VM shutdown can itself fail.
              # The verdict must say which, because a guest that is still up and unheld gets swept
              # by the lanes and dies mid-unit, and one that is gone simply records no coverage.
              kheld=failup
              if [ "$FRESH_WSL" = fresh ] && shutdown_unheld_vm "$n" "$KICK_DEST"; then kheld=faildown; fi
            fi; } >>"$dir/$i.out" 2>&1
        fi
        printf '%s %s %s\n' "$krc" "${KICK_PHASE:-none}" "$kheld" >"$dir/$i.rc"
      fi; } &
  done
  wait
  i=0
  for n in "$@"; do
    i=$((i + 1))
    [ -f "$dir/$i.out" ] && cat "$dir/$i.out"
    krc=1; kphase=start; kheld=na
    [ -s "$dir/$i.rc" ] && read -r krc kphase kheld < "$dir/$i.rc"
    if [ "$krc" = 0 ]; then
      # A VM nothing holds is not a started box: it is the one shape --hold exists to refuse.
      case "$kheld" in
        faildown) unheld_down+=("$n") ;;
        failup)   unheld_up+=("$n") ;;
        *)        started+=("$n") ;;
      esac
    elif [ "$kphase" = locked ]; then held+=("$n")
    elif [ "$kphase" = shutdown ]; then unshut+=("$n")
    else unstarted+=("$n"); fi
  done
  rm -rf "$dir"
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
  # A refused box is a failure of the step like any other, and for the same reason the rest of this
  # function is built that way: the caller asked for a FRESH VM there and did not get one, so the
  # sweep must not read the verdict as permission to test that backend. It is the one failure whose
  # cure is to wait rather than to go and look at the box. A lane holding a box with `--hold` is
  # one of those holders, so a second restart is refused here rather than destroying that lane.
  if [ ${#held[@]} -gt 0 ]; then
    line="wsl $what REFUSED on: ${held[*]} (the lab lock is held; wait for the holder, or --force to take the box anyway)"
    echo "$line"; WSL_FAILED="${WSL_FAILED:+$WSL_FAILED; }$line"; rc=1
  fi
  # Two shapes, and they are different findings: a VM that is gone costs the lane its coverage,
  # while one still running unheld gets swept by the lanes (they probe the guest themselves) and
  # dies mid-unit. Never claim a shutdown that did not happen.
  if [ ${#unheld_down[@]} -gt 0 ]; then
    line="wsl HOLD FAILED on: ${unheld_down[*]} (nothing on the Windows side holds the VM, so it was shut down again: those units record no coverage)"
    echo "$line"; WSL_FAILED="${WSL_FAILED:+$WSL_FAILED; }$line"; rc=1
  fi
  if [ ${#unheld_up[@]} -gt 0 ]; then
    line="wsl HOLD FAILED on: ${unheld_up[*]} (the VM is up and UNHELD and was not shut down: do not sweep that box, its units can die mid-unit)"
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
FORCE=0        # --force: destroy the VM even while the lab lock is held (see the lab lock lore)
LANE_LOCKED=0  # set in a box's subshell once start_wsl holds that box's lab lock on fd 8
VERB=wake
TARGETS=()

case "${1:-}" in
  status|sleep|hibernate|down|kick-wsl|unhold) VERB=$1; shift ;;
  restart-wsl) VERB=kick-wsl; FRESH_WSL=fresh; shift ;;
  lock-path) VERB=$1; shift ;;
esac

for arg in "$@"; do
  case "$arg" in
    --list) list_hosts; exit 0 ;;
    --wait) WAIT=1 ;;
    --wsl)  WANT_WSL=1 ;;
    --hold) HOLD=1 ;;
    --restart-wsl) WANT_WSL=1; FRESH_WSL=fresh ;;
    --force) FORCE=1 ;;
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

# Before load_hosts, like --help and --list: a lock path is a function of the lock directory and a
# box NAME alone, and the harness that asks where to put its flock -- the sweep, from a checkout
# that has no business holding this lab's MAC addresses -- must not need the site table to find out.
if [ "$VERB" = lock-path ]; then
  for t in "${TARGETS[@]}"; do lab_lock_path "$t"; echo; done
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
    # Only the boxes actually acted on are confirmed: polling a refused box for the DOWN signal
    # would report the holder's live machine as a failure to go down.
    power_phase "$VERB" "${TARGETS[@]}" || exit 1
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
