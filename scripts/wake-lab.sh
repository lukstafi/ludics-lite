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
#   wake-lab.sh lock-path box             where that box's LANE lock lives, for a harness taking one
#   wake-lab.sh --list                    dump the router's host table
#
# Every path that takes a box away from whatever is running on it -- `restart-wsl` and
# `--restart-wsl`, which shut the VM down host-globally, and `sleep`/`hibernate`/`down`, which take
# the whole host -- RESERVES the box first and refuses one another tool is using. The reservation is
# held across the destructive command rather than checked before it, because a check and an act
# with a gap between them is the race this exists to close. It spans BOTH of that box's lab locks
# -- the lane lock and the hold lock, which say two different things and are held by two different
# kinds of user -- and `--force` overrides both. The lab lock lore below says which is which, why
# there are two, when `--force` is the right call, and what each cost the day it was not there.
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
#   `ssh -o ServerAliveInterval=15 <box>-win 'wsl.exe -d Ubuntu -e sh -s <token>'`, backgrounded
#   here with a fifo for its stdin, its record under $WAKE_LAB_STATE_DIR — and declares the VM up
#   only once that holder has SAID ITS TOKEN BACK from inside the guest, because a holder that
#   failed to start is exactly the state the flag exists to rule out, and because a wsl.exe in
#   `tasklist` (what this observed until 2026-09-19) is true of the owner's console shell as well
#   as of ours. `unhold <box>` ends it, and says what it observed rather than what it intended:
#   the local client is killed, then the VM is asked whether that guest shell is gone, and if it
#   is not, it is ended by pid (ludics-lite#192, #184).
#   The holder is a SHELL READING ITS CHANNEL, which is what makes it end when the channel does:
#   Windows sshd does not reap the command tree when the client dies, so a holder that never reads
#   its stdin is orphaned on the Windows side by every single unhold. Never size it with a fixed
#   `sleep N` either: a lane is several units with their own caps plus preparation, and a 3-hour
#   holder expires under the last one — a shell waiting for input cannot expire, so a lane ends by
#   unhold, not by expiry. A holder inside the guest would die with the VM, which is the failure
#   being fixed. `kick-wsl` re-kicks a box whose Windows side is up, so `kick-wsl --hold` is also
#   how a lane takes a holder over a VM that is already running. The holder also carries that box's
#   HOLD LOCK: it inherits the descriptor the lock is held on, so the flock lives exactly as long
#   as the holder and `unhold`'s kill releases it. That is what makes a held box visible to the
#   interlock — another session's `restart-wsl` is refused, naming this holder, instead of
#   destroying the VM with a host-global `wsl.exe --shutdown` (the other half of 2026-09-16). The
#   hold lock is deliberately NOT the LANE lock a sweep takes: a hold says "do not destroy this
#   VM", never "nobody else may work here", and while one file said both, a lane could not sweep
#   the box its own holder was keeping alive (ludics-lite#224). The lab lock lore below has both.
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
# How long to wait for the spawned holder to answer its token from inside the VM, and where its
# record is kept so that `unhold` — possibly in a later shell, since a lane is a sequence of
# commands — can end it. It used to be how long to wait for a wsl.exe to appear in `tasklist`,
# which is not the same question and was answered `true` by processes that were never ours.
HOLD_WAIT_SECONDS=${WAKE_LAB_HOLD_WAIT_SECONDS:-60}
# How long, after the local client has been killed, the guest shell is given to notice its channel
# closed and exit, before `unhold` calls the holder a leak and ends it by pid. EOF crosses a dead
# TCP connection, a Windows sshd, cmd.exe and wsl.exe before the guest reads it, so this is a grace
# period and not a probe interval; it bounds only the failing case, since a holder that went at
# once is observed gone on the first ask.
HOLD_TEARDOWN_SECONDS=${WAKE_LAB_HOLD_TEARDOWN_SECONDS:-20}
HOLD_STATE_DIR=${WAKE_LAB_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/wake-lab}
# Set when a holder was found already dead at unhold: a lane that lost its box without anyone
# noticing. It is a FAULT and not a cleanup detail, so it leaves the command non-zero -- see
# release_hold for why a holder can only be gone by having died under the lane.
HOLD_ANOMALY=0
# Set when a release could NOT leave the box demonstrably free: either a holder of ours was still
# running in the VM after its channel died and after unhold ended it by pid, or the box never
# answered and nothing here knows either way. A different fault from the one above and reported as
# a different exit status, because it says the opposite thing about the lane -- the results are
# fine, the BOX is not. The two share a status deliberately: what a caller does about them is the
# same, which is to look at that box.
HOLD_LEAK=0
# What the last confirmation established: gone, pinned, or unverified. It is what decides whether
# a release may remove the record -- an unverified teardown keeps the guest pid and token, which
# are the only things a later unhold could finish the job with.
HOLD_CONFIRM=""
# The local-time hours on the Windows box that the unattended sweep occupies: the routine's 07:20
# launch plus its longest lane. Written `<start>-<end>`, end exclusive, and it may wrap midnight.
SWEEP_HOURS=${WAKE_LAB_SWEEP_HOURS:-7-11}
# Caps for the two remote commands of the kick/restart path, which are the ones observed to wedge.
# Sized to be generous against how long each really takes — a `wsl --shutdown` is seconds and a
# cold VM start is well under a minute — because the cap is here to end a command that will never
# return, not to give up on a slow one.
WSL_SHUTDOWN_CAP=${WAKE_LAB_WSL_SHUTDOWN_CAP:-60}
WSL_START_CAP=${WAKE_LAB_WSL_START_CAP:-120}

# ---------------------------------------------------------------- the lab locks
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
# So the boxes are a SHARED resource and destroying one needs an interlock. But "this box is in
# use" turned out to be TWO claims, and one exclusive file could not carry both of them:
#
#   "do not destroy this VM"        -- what `--hold` says, on behalf of whatever will run there
#   "no other lane runs here"       -- what a sweep lane says, so two lanes cannot fight over a box
#
# While both lived in one flock, a lane could not sweep the box its own holder was keeping alive.
# The cross-machine sweep routine holds rog and minix in step 1 and runs the sweep in step 2 of the
# same session, and on 2026-09-18 every remote lane waited out its 300 s LAB_LOCK_WAIT against that
# routine's own holder and then skipped: three of the five backends that routine is the only gate
# for got zero coverage, and the documented recovery (`kick-wsl --hold` then rerun) reproduced the
# skip exactly, because it took the same lock again (ludics-lite#224). The two halves had been
# designed as mutual exclusion between DIFFERENT sessions; one session doing both is not a
# contradiction to resolve but the intended shape, so the file is split rather than shared.
#
# Two files per box, each an ordinary EXCLUSIVE flock, in a directory this script and the sweep
# agree on. The contract is still deliberately nothing more than a directory, a filename and a
# one-line holder description: the sweep takes its own flock and does not need this script
# installed, which keeps a harness on another machine from depending on a symlink in ~/bin.
#
#   <dir>/<box>.lock        the LANE lock -- "no other lane runs on this box"
#   <dir>/<box>.hold.lock   the HOLD lock -- "this box's VM must not be destroyed"
#   first line of each      "<what> (pid <pid>, since <utc>)" -- advisory, for the refusal message
#
# Who takes which, and it is the whole design:
#
#   a sweep lane   the LANE lock, for the length of the lane
#   `--hold`       the HOLD lock, carried by the holder for exactly as long as the holder lives
#   a DESTROYER    (`restart-wsl`, `--restart-wsl`, `sleep`, `hibernate`, `down`) takes BOTH and is
#                  refused if EITHER is held -- each one alone means somebody loses work
#
# That keeps the 2026-09-16 property whole: another session's `restart-wsl` is refused while a lane
# is using the box, and refused just the same in the gap between a hold and the lane it was taken
# for, where there is no lane yet to refuse on its own behalf. What it drops is the one exclusion
# nobody ever wanted -- a hold and a lane no longer refuse each other.
#
# The LANE lock keeps the old name, the old format and the old semantics, so a sweep checkout that
# has not been updated still interlocks exactly as before. Worst case across a version skew is a
# spurious skip (an old sweep waiting out a new hold that no longer needs to block it), never a
# destroyed VM: neither side can be made to believe a box is free while the other is using it.
#
# flock and not a pidfile for the reasons sweep.sh gives about its own run lock: there is nothing
# to reclaim after a crash, no window between creating the lock and publishing ownership, and the
# kernel releases it when the holder dies however it dies. The holder line is advisory only -- it
# names who to go and look at, and a stale or missing one never decides anything.
LOCK_DIR=${WAKE_LAB_LOCK_DIR:-$HOME/.local/state/wake-lab}

lab_lock_path() { # lab_lock_path <box> — where that box's LANE lock lives
  printf '%s/%s.lock' "$LOCK_DIR" "$1"
}

hold_lock_path() { # hold_lock_path <box> — where that box's HOLD lock lives
  printf '%s/%s.hold.lock' "$LOCK_DIR" "$1"
}

# Take a lock and HOLD it, on a descriptor the calling shell keeps open until it exits.
#
# Asking whether a lock is free and then acting on the answer is the very race this interlock
# exists to close: a probe that takes the lock and releases it leaves a window between the check
# and the `wsl.exe --shutdown`, and a sweep that reserves the box inside that window is destroyed
# by a restart that had already decided it was allowed to proceed. So the restarter becomes a
# holder rather than an observer — there is no window because there is no interval in which
# nothing holds the lock.
#
# Every caller runs this inside a per-box SUBSHELL, so the descriptor is that subshell's own and
# concurrent boxes cannot collide on it; the lock lives exactly as long as the work it guards. A
# lock file that cannot be created or opened at all is treated as free, deliberately: that is a
# fault in this machine's state directory, and it must not lock the operator out of their own lab
# (a real holder had to create the file to hold it).
# The descriptor is a parameter so that ONE process can hold several locks at once, each on its
# own: a destroyer holds two per box, and `power_phase` reserves every box it is about to act on
# and must keep all of them for as long as it acts. bash 3.2 has no `exec {fd}>`, hence the eval
# over an explicitly chosen number.
lock_take_fd_strict() { # lock_take_fd_strict <path> <what> <fd>
                        # 0 taken and held, 1 someone else holds it, 2 could not even be attempted
  local path=$1
  mkdir -p "$LOCK_DIR" 2>/dev/null || return 2
  eval "exec $3>>\"\$path\"" 2>/dev/null || return 2
  perl -e 'use Fcntl ":flock"; exit(flock(STDIN, LOCK_EX | LOCK_NB) ? 0 : 1)' <&"$3" || return 1
  lock_label "$path" "$2" "$$"
  return 0
}

# The fail-OPEN wrapper, and the contract every caller but the release wants: a lab whose lock
# directory cannot be created or written must not stop the boxes being used, so "could not be
# attempted" reads as "proceed". That is exactly the wrong answer for a caller asking whether it
# is SERIALIZED, though -- proceeding and being serialized are different facts, and reading the
# first as the second is how an unlocked cleanup came to believe it held the box. Callers that
# need the difference use the strict form.
lock_take_fd() { # lock_take_fd <path> <what> <fd> — 0 taken or unavailable, 1 someone else holds it
  lock_take_fd_strict "$@"
  case $? in 1) return 1 ;; *) return 0 ;; esac
}

# The advisory line, written by whoever holds the lock. Separate from the take because the hold
# path REWRITES it: on the restart path the holder inherits the descriptor the restart's own take
# opened, and a line left saying `wake-lab restart (pid ...)` then outlives the restart and names a
# pid that has already exited — which is what every later refusal message, on this side and in the
# sweep's skip lines, would go on quoting. So the holder relabels the lock it has taken over.
lock_label() { # lock_label <path> <what> <pid>
  printf 'wake-lab %s (pid %s, since %s)\n' "$2" "$3" "$(date -u +%Y%m%dT%H%M%SZ)" \
    >"$1" 2>/dev/null
}

# A lock's own description of itself, for the refusal message. Never trusted for the decision
# -- taking the lock makes that -- so an empty or truncated line degrades to a bare "held".
lock_holder() { # lock_holder <path>
  local line
  line=$(head -1 "$1" 2>/dev/null | tr -d '\000-\037')
  printf '%s' "${line:-held by an unnamed holder}"
}

# Every lock descriptor in this script stays BELOW 10, and that is not a style choice. bash 3.2
# parks the descriptor a redirection displaces on the first free fd at or above 10, for the length
# of the command carrying the redirection — so `eval "exec 10>>\"$path\"" 2>/dev/null` opens the
# lock onto the very slot holding this shell's stderr, and bash closes it again when the eval
# returns. `exec` reports success, `flock` then fails on a descriptor that is no longer there, and
# the box reads as reserved by somebody else. It cost a run of the suite to find; the cases pin it.
# The cost is a ceiling on how many locks one process can hold at once, and `power_phase` is the
# only caller that holds more than one box's worth — hence the refusal there rather than a silent
# reservation this shell cannot actually make.
LOCK_FD_BASE=4         # the lowest descriptor a multi-box reservation may use
LOCK_FD_LIMIT=9        # ...and the highest, one below bash 3.2's save slot

# RESERVE a box: both of its locks, taken in one fixed order and released together if either is
# refused. Half a reservation is worse than none — a destroyer that kept the lane lock it had just
# taken while refusing on the hold lock would block the very sweep the holder was taken for — so
# the lane fd is closed again on the way out. Every take here is non-blocking, and this script
# never waits on a lock, so two destroyers racing for the same pair cannot deadlock: one of them
# is refused at once.
RESERVE_REFUSED_BY=""  # the holder line of whichever lock refused us, for the caller's message
lab_reserve() { # lab_reserve <box> <what> <fd> — the lane lock on <fd>, the hold lock on <fd>+1
  local box=$1 what=$2 fd=$3 hfd=$(($3 + 1))
  RESERVE_REFUSED_BY=""
  if ! lock_take_fd "$(lab_lock_path "$box")" "$what" "$fd"; then
    RESERVE_REFUSED_BY=$(lock_holder "$(lab_lock_path "$box")")
    return 1
  fi
  if ! lock_take_fd "$(hold_lock_path "$box")" "$what" "$hfd"; then
    RESERVE_REFUSED_BY=$(lock_holder "$(hold_lock_path "$box")")
    eval "exec $fd>&-"
    return 1
  fi
  return 0
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
# THIS process holds every reservation, two descriptors each — the lane lock and the hold lock, as
# every destructive path takes both — and it is also the process that acts.
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
  local box fd=$LOCK_FD_BASE rc=0 acted=() refused=()
  for box in "$@"; do
    if [ "$FORCE" = 1 ]; then acted+=("$box"); continue; fi
    # Out of descriptors below bash 3.2's save slot: refuse rather than act on a box this shell
    # cannot hold. A reservation it cannot make is exactly the state the interlock exists to rule
    # out, and the ceiling is well clear of the three boxes the host table names.
    if [ $((fd + 1)) -gt "$LOCK_FD_LIMIT" ]; then
      echo "  $verb REFUSED on $box: no descriptor left to reserve it with (at most $(( (LOCK_FD_LIMIT - LOCK_FD_BASE + 1) / 2 )) boxes per command)"
      refused+=("$box"); continue
    fi
    if lab_reserve "$box" "$verb" "$fd"; then
      acted+=("$box"); fd=$((fd + 2))
    else
      echo "  $verb REFUSED on $box: $RESERVE_REFUSED_BY"
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
    echo "$verb REFUSED on: ${refused[*]} (a lab lock is held; wait for the holder, or --force to take the box anyway)"
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
# A VM is held up by a wsl.exe on the Windows side and by nothing else (see the lore). These own
# that process: spawn it, prove it is ours, kill it, and prove it is gone.
#
# The holder is a SHELL READING ITS COMMANDS FROM THE CHANNEL, and each half of that sentence is
# there for a measured reason.
#
# It READS, so it ends when the channel does. `release_hold` used to reason that "killing the local
# client closes the channel and sshd ends the command it was running". On Windows OpenSSH that is
# false: sshd runs the remote command under `cmd.exe` and its session process exits WITHOUT taking
# its children, so every hold/unhold cycle left an orphaned `cmd.exe` + two `wsl.exe` + a guest
# `sleep infinity` behind, reparented and unreachable from this side -- measured on both lab boxes
# on 2026-09-17 (ludics-lite#192). Nothing in the guest noticed either, because `sleep infinity`
# never touches its stdio and a dead channel produces no EPIPE for a process that never reads. A
# holder that READS is the portable version of the guarantee the old comment assumed: when the
# client dies the channel closes, the remote end of that pipe goes to EOF, `sh` runs out of input
# and exits, and the tree unwinds from the inside, on the far side of the boundary this script
# cannot reach across. That is why the payload is a shell and not a `sleep`: the holder has to be a
# process with a reason to notice.
#
# It is still UNSIZED -- `sh` waits for input, it does not expire. A lane is several units with
# their own caps plus preparation and diagnostics outside them, so a holder sized to the expected
# run expires under the last unit, silently, exactly when nobody is watching. It ends by `unhold`,
# or with its channel, and by nothing else.
#
# And it IDENTIFIES itself, which is what lets everything below claim something about OUR holder
# rather than about the box. `sh -s <token>` puts a token this run generated into `$1` in the guest
# and into the command line on all three sides (the local ssh client, the Windows-side wsl.exe, the
# guest shell), and the handshake asks the holder to say it back down its own stdout along with its
# guest pid. Before this there was no identity at all: the observation read `tasklist` and counted
# ANY wsl.exe, which on both lab boxes was already true with nothing of ours running -- the Codex
# app-server's own console wsl.exe -- so that half of the handshake certified nothing and the whole
# claim rested on the local ssh client still being connected (ludics-lite#184 (a), measured in
# #155's acceptance run). A token that came back through the VM is the opposite kind of evidence:
# it cannot be true unless our command is running in that guest.
#
# Nothing in the payload quotes, and that is the other half of the design. It reaches the guest
# through `cmd.exe /c` and then through `wsl.exe`, both of which parse Windows-style: cmd.exe's /c
# strips the outer quotes only under a rule that counts quote characters, and wsl.exe's own argv
# splitting has never heard of single quotes. `sh -c "echo <token>; exec sleep infinity"` -- the
# shape ludics-lite#184 (a) proposed -- has to survive both hops with its quoting intact, and #155
# confirmed the hops are real by reading the holder's Windows command line. Reading the script off
# stdin instead makes the payload `wsl.exe -d Ubuntu -e sh -s <token>`: one space-separated list of
# bare words, the same quoting profile as the `sleep infinity` it replaces, with the interesting
# part travelling as DATA inside the channel, where no Windows parser looks at it.
HOLD_PAYLOAD='wsl.exe -d Ubuntu -e sh -s'
# What that payload runs INSIDE the guest, which is what the guest's own process list shows. The
# two must agree: this is the shape the cleanup probe looks for, and a token found anywhere else on
# a line is not a holder. An operator debugging a stuck lane with `watch ... grep <token>` has that
# token in their argv, and matching it would end their command instead of the holder.
HOLD_GUEST_ARGV='sh -s'
# The holder every version before this one spawned. A hold outlives the shell that took it -- a
# lane is a sequence of commands and this script is updated between them -- so an `unhold` from the
# new script can meet a record the old one wrote. That holder has no token, cannot be handshaken
# and does not read its stdin; it is recognized, ended and reported as what it is, rather than read
# as a stale record naming somebody else's process.
HOLD_CMD_LEGACY='wsl.exe -d Ubuntu -e sleep infinity'

# The channel the holder reads and the file its stdout lands in. Both live beside the record, are
# named after the box, and are removed by the release that ends the holder.
# The fifo is mode 600 on purpose: anything that can write to it runs shell commands inside that
# VM, which is a narrower door than the state directory's own, and worth keeping shut.
hold_fifo_path() { printf '%s\n' "$HOLD_STATE_DIR/hold-$1.in"; }
hold_out_path()  { printf '%s\n' "$HOLD_STATE_DIR/hold-$1.out"; }

# The record is "<pid> <dest> <epoch> <sidecar> <token> <guest pid> <protected>". The destination is
# part of the holder's identity and is the alias every later observation of THIS holder goes out
# on; the epoch is when it was spawned; the sidecar is the process that keeps the box's HOLD lock
# open for as long as the holder lives (see hold_wsl); the token is this lane's identity, the thing
# that makes "our holder" a decidable question on both sides of the channel; the guest pid is the
# shell the handshake found in the VM, which is what `unhold` looks for afterwards; and the last
# field says whether this holder ever carried the hold lock -- a `--force` holder did not, so the
# box was never protected from another session's `restart-wsl` while it ran, and a release that
# stayed silent about that would let a lane believe in an interlock it never had (#184 (b)).
# A record written before those three fields existed is a legacy record: it reads with token "-",
# guest pid 0 and protection "unknown", which every caller here handles as the holder it is.
# Write a record, or leave the existing one alone. `>` truncates the moment the redirection opens,
# so a short write -- a state filesystem that filled between one field and the next -- destroys the
# only usable record of a holder that is still running, and the reuse path deliberately leaves that
# holder alive. The next `unhold` would then have no local pid, no sidecar, no token and no guest
# pid: a stranded lock and a stranded tree. A rename is atomic within the directory, so the record
# is either the old one or the new one and never half of either.
hold_record_write() { # hold_record_write <pidfile> <pid> <dest> <epoch> <sidecar> <token> <gp> <prot>
  local f=$1 tmp
  shift
  tmp=$f.$$.new
  if ! printf '%s %s %s %s %s %s %s\n' "$@" > "$tmp" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  mv -f "$tmp" "$f" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }
  return 0
}

hold_pid_read() { # hold_pid_read <pidfile> — echo the seven fields, fail if unusable
  local line p d t sc tok gp prot
  [ -r "$1" ] || return 1
  line=$(cat "$1" 2>/dev/null)
  read -r p d t sc tok gp prot <<<"$line"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$d" ] && [ "$d" != "$p" ] || return 1
  case "$t" in ''|*[!0-9]*) t=0 ;; esac
  case "$sc" in ''|*[!0-9]*) sc=0 ;; esac
  # A token is bare word characters by construction (it is spelled into a Windows command line and
  # then into a grep pattern); anything else in that field is a record this script did not write,
  # and it is read as the legacy shape rather than trusted into either use.
  case "$tok" in ''|*[!A-Za-z0-9-]*) tok='-' ;; esac
  case "$gp" in ''|*[!0-9]*) gp=0 ;; esac
  case "$prot" in protected|unprotected) ;; *) prot=unknown ;; esac
  printf '%s %s %s %s %s %s %s\n' "$p" "$d" "$t" "$sc" "$tok" "$gp" "$prot"
}

hold_pid_live() { # hold_pid_live <pidfile> — is the recorded holder still OUR holder, still running
  local rec p d t sc tok gp prot
  rec=$(hold_pid_read "$1") || return 1
  read -r p d t sc tok gp prot <<<"$rec"; : "$t" "$sc" "$gp" "$prot"
  kill -0 "$p" 2>/dev/null || return 1
  # A zombie answers `kill -0` and, on Linux, still prints its old command line — so an exited
  # holder whose parent has not reaped it would read as live.
  case "$(ps -o state= -p "$p" 2>/dev/null)" in *Z*) return 1 ;; esac
  # Pids are reused, and this file outlives the shell that wrote it — so an `unhold` run tomorrow
  # over a stale file must never kill whatever inherited the number. The signature is the holder's
  # whole command line INCLUDING its destination and its token: a signature without the alias would
  # let one box's stale file kill another box's live holder, and one without the token would let a
  # stale file kill the holder of another LANE on the same box, which is the same accident one
  # level down (#184 (b)). A legacy holder has no token to match, so it is matched on the payload
  # every version before this one used — the most that record supports.
  # -ww: macOS ps truncates args to the output width otherwise, and this command line is long —
  # a truncated one matches nothing, and every live holder would read as somebody else's process.
  if [ "$tok" = '-' ]; then
    ps -ww -o args= -p "$p" 2>/dev/null | grep -q -- "$d $HOLD_CMD_LEGACY"
  else
    ps -ww -o args= -p "$p" 2>/dev/null | grep -q -- "$d $HOLD_PAYLOAD $tok"
  fi
}

# The handshake: ask the holder, down its own channel, to say who it is. It answers with its token
# and its guest pid, so a round trip proves three things at once that no local check can — the
# channel is open, OUR command is the one running on the far side of it, and it is running IN that
# VM. The nonce is what makes it a fresh answer rather than a line the holder printed an hour ago:
# the reply has to carry the nonce THIS call just sent.
hold_handshake() { # hold_handshake <box> <token> <seconds> — echo the holder's guest pid
  local name=$1 tok=$2 secs=$3 fifo out nonce gp deadline
  fifo=$(hold_fifo_path "$name"); out=$(hold_out_path "$name")
  [ -p "$fifo" ] && [ -r "$out" ] || return 1
  nonce=n$$x${RANDOM:-0}x$(date +%s)
  # `<>` and not `>`: opening a fifo for writing ALONE blocks until a reader turns up, and a holder
  # that has died is precisely the case this has to answer rather than hang in. Read-write never
  # blocks, reader or no reader, so a dead holder produces silence and a timeout — a negative
  # answer, reached in bounded time. Descriptor 3 is below LOCK_FD_BASE, so it can never be a lock's.
  exec 3<>"$fifo" || return 1
  # Single-quoted: `$1` and `$$` are for the guest shell to expand, not this one.
  printf 'echo $1 $$ %s\n' "$nonce" >&3 2>/dev/null
  exec 3>&-
  deadline=$((SECONDS + secs))
  while :; do
    # Fields, not a substring: a reply is our token in the FIRST field and this call's nonce in the
    # third, so neither a token that appears inside some other text nor an earlier handshake's line
    # can be read as this one's answer.
    gp=$(awk -v t="$tok" -v n="$nonce" '$1 == t && $3 == n { print $2; exit }' "$out" 2>/dev/null)
    case "$gp" in ''|*[!0-9]*) ;; *) printf '%s\n' "$gp"; return 0 ;; esac
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 1
  done
}

# Is the holder's guest shell gone from the VM? Asked over the holder's OWN recorded alias, after
# the local client has been killed, because #192 is exactly the case where the local half of the
# teardown is complete and the remote half is not. rc 0 gone, 1 still there, 2 could not tell.
#
# Neither probe can START anything. `wsl.exe -e <cmd>` BOOTS a stopped distro, so asking the guest
# first would let an `unhold` bring up the VM it just released; the running-distro question is
# asked first and answers the whole thing when the distro is down — a guest shell cannot outlive
# the guest. Both read their answer out of the OUTPUT and not out of the exit status, because ssh
# hands back the remote command's status and `wsl --list --running` with nothing running, `ps` with
# no such pid, and an ssh that never connected are all "non-zero" — only the output tells them
# apart. Silence is therefore never read as good news: it is rc 2, and the caller says so.
# Is a holder of ours still running in that VM? Asked over the holder's OWN recorded alias, after
# the local client has been killed, because #192 is exactly the case where the local half of the
# teardown is complete and the remote half is not. rc 0 gone, 1 still there (with its guest pid in
# HOLD_REMOTE_PID), 2 could not tell.
#
# It asks by TOKEN and not by recorded pid, which is what lets every caller use it. A hold whose
# handshake never answered has a token in its payload and no guest pid to have recorded, and that
# holder is the most dangerous one there is: it may be running in the VM with nothing naming it.
# The token is in the guest process's argv by construction, so the process list answers for it.
#
# Neither probe can START anything. `wsl.exe -e <cmd>` BOOTS a stopped distro, so asking the guest
# first would let an `unhold` bring up the VM it just released; the running-distro question is
# asked first and answers the whole thing when the distro is down -- a guest shell cannot outlive
# the guest. Every reading is gated on `capped`'s status first: a wedged command's partial output
# is kept by the command substitution, and a `wsl --list` cut off before "Ubuntu" or a process list
# cut off before our line both look exactly like the good news this exists to be careful about.
# The header is what proves the probe RAN, so it is required by name rather than inferred from any
# non-empty reply; silence is never read as good news.
HOLD_REMOTE_PID=""     # the guest pid the last probe found, which is what a kill by pid needs
hold_remote_gone() { # hold_remote_gone <windows-alias> <token>
  local out rc
  HOLD_REMOTE_PID=""
  # No token is no question. `index($0, "")` is true of every line, so an empty one would match the
  # first process in the guest's list and report it as ours -- a finding invented out of a record
  # that names nothing. Callers guard this too; it is cheap to be certain here.
  [ -n "${2:-}" ] && [ "$2" != '-' ] || return 2
  out=$(capped "$PROBE_CAP" ssh -o BatchMode=yes -o ConnectTimeout=15 "$1" \
        'wsl.exe --list --running' 2>/dev/null); rc=$?
  # 124 is `capped` cutting a wedge short; 255 is ssh's own "something went wrong", which it
  # returns for a connection that dropped -- possibly after the far side had already sent a header.
  # Neither is a reading of the VM, and the bytes that arrived before them are not one either.
  case "$rc" in "$CAP_EXPIRED"|255) return 2 ;; esac
  # wsl.exe writes UTF-16LE, which arrives here as NUL-interleaved bytes.
  out=$(printf '%s' "$out" | tr -d '\000\r')
  [ -n "$out" ] || return 2
  # "Gone" has to be something wsl SAID, not something it failed to say. `wsl --list --running`
  # exits 1 with "There are no running distributions." when nothing runs, and every other failure
  # -- a wsl.exe that errored, a distro in a bad state -- also prints something without our distro
  # in it, so inferring absence from a missing line reported those as a verified teardown and let
  # the release delete the record.
  if printf '%s\n' "$out" | grep -qi 'no running distributions'; then return 0; fi
  # ...and "running" has to name OUR distro EXACTLY. A prefix test matches `Ubuntu-22.04` beside a
  # stopped `Ubuntu`, and the guest probe below would then BOOT the stopped one -- an unhold
  # starting the VM it exists only to inspect. Trailing blanks only, plus wsl's `(Default)` mark.
  printf '%s\n' "$out" |
    awk '{ sub(/[ \t]+$/, "") } $0 == "Ubuntu" || $0 == "Ubuntu (Default)" { f = 1 }
         END { exit !f }' || return 2
  # `-eo pid -o args` rather than `-o pid,args`: cmd.exe treats a comma as an argument delimiter,
  # and nothing in this command may depend on surviving that. The PID header is the marker.
  out=$(capped "$PROBE_CAP" ssh -o BatchMode=yes -o ConnectTimeout=15 "$1" \
        'wsl.exe -d Ubuntu -e ps -eo pid -o args' 2>/dev/null); rc=$?
  case "$rc" in "$CAP_EXPIRED"|255) return 2 ;; esac
  out=$(printf '%s' "$out" | tr -d '\r')
  printf '%s\n' "$out" | grep -q 'PID' || return 2
  HOLD_REMOTE_PID=$(printf '%s\n' "$out" |
    awk -v t="$2" -v g="$HOLD_GUEST_ARGV" \
      '$1 ~ /^[0-9]+$/ && ($2 " " $3) == g && $4 == t { print $1; exit }')
  [ -n "$HOLD_REMOTE_PID" ] && return 1
  return 0
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

# The two descriptors start_wsl's per-box subshell reserves on, named rather than spelled out at
# each use: `lab_reserve` takes the lane lock on the fd it is given and the hold lock on the one
# after it, so these two must stay adjacent, and the hold's own number is the one `hold_wsl`
# reuses. Each box has its own subshell, so one pair serves them all; `power_phase`, which holds
# every box in ONE process, counts up from LOCK_FD_BASE instead. Both stay under bash 3.2's save
# slot, for the reason spelled out beside LOCK_FD_BASE.
LANE_FD=8
HOLD_FD=9      # the descriptor the box's HOLD lock lives on; the holder inherits exactly this one
hold_wsl() { # hold_wsl <box> <windows-alias> — spawn the holder and prove it is ours, in that VM
  local name=$1 dest=$2 pid f fifo out token spawn_epoch spawned=0 sidecar=0 gp prot=protected
  local rec rec_seen rec_existed now_existed rp rd rt rsc rtok rgp rprot own theirs
  local hold_locked=${HOLD_LOCKED:-0}
  # The box's HOLD lock — "do not destroy this VM" — and the holder is what carries it. A restart
  # path already holds it on HOLD_FD (its reservation took both of that box's locks before the
  # kick, and set HOLD_LOCKED to say so); a plain `kick-wsl --hold` does not, so it takes it here,
  # on the same descriptor. Either way the holder we spawn INHERITS that descriptor, so the flock
  # lives exactly as long as the holder does — an inheriting child keeping an flock alive is the
  # semantics ludics-lite#168 documents — and `unhold`'s kill releases it with no separate release
  # path to get wrong. The consequence that matters: while a box is held, another session's
  # `restart-wsl` is REFUSED instead of destroying its VM with a host-global `wsl.exe --shutdown`.
  # What it deliberately does NOT take is the LANE lock: a sweep lane on this very box — the one
  # the holder exists to serve — must be able to reserve it (ludics-lite#224).
  f=$HOLD_STATE_DIR/hold-$name.pid
  fifo=$(hold_fifo_path "$name"); out=$(hold_out_path "$name")
  mkdir -p "$HOLD_STATE_DIR" 2>/dev/null
  if hold_pid_live "$f"; then
    # Reuse: the live holder already carries this box's lock, and taking it again from here would
    # fail against our own holder. Everything this branch says about it is said over the alias the
    # RECORD names, never the one this invocation happens to be kicking on: the holder's channel
    # is the holder's channel, and an observation sent down some other alias would be evidence
    # about a different connection to the same box (#184 (b)).
    rec=$(hold_pid_read "$f"); read -r rp rd rt rsc rtok rgp rprot <<<"$rec"; : "$rt"; : "$rsc"
    echo "  wsl holder already running for $name (pid $rp, via $rd)"
    if [ "$rprot" = unprotected ]; then
      # A --force holder carries no flock: its sidecar inherited a descriptor that was never
      # locked, and it will never acquire one. Reusing it and returning success would have
      # start_wsl report the VM as held when another session's restart-wsl can still take it
      # mid-lane -- which is the one claim this whole flag exists to make truthfully.
      # So try to make it true instead of warning about it. The lock the earlier run could not get
      # may well be free by now, and a holder can be given a NEW sidecar over its existing pid: the
      # sidecar is only a process that holds the descriptor and outlives this shell.
      if lock_take_fd_strict "$(hold_lock_path "$name")" "--hold" "$HOLD_FD"; then
        perl -e 'my $tag = "wake-lab-hold-lock"; my $p = shift; while (kill 0, $p) { sleep 1 }' \
          "$rp" >/dev/null 2>&1 </dev/null 8>&- &
        # Recorded so the release ends this sidecar rather than the dead one, and so the box stops
        # reading as unprotected. Safe to rewrite here for once: we hold the box's lock, so no
        # other hold can be writing this record.
        if hold_record_write "$f" "$rp" "$rd" "$rt" "$!" "$rtok" "$rgp" protected; then
          echo "    ...was taken with --force and held no lock; this run has now taken $name's hold lock for it"
        else
          echo "    ...was taken with --force; this run took $name's hold lock for it, but could not record that"
        fi
      elif [ "$FORCE" = 1 ]; then
        echo "    ...taken with --force: it never held $name's hold lock, and this run cannot take it either,"
        echo "    so $name's VM is NOT protected from another session's restart-wsl for the rest of this lane"
      else
        # An ordinary --hold asks for a held VM, and `wsl up` is read as one. This holder carries
        # no flock and this run could not take one for it, so returning success here would report a
        # box as held that another session's restart-wsl can still destroy mid-lane -- the one
        # claim this flag exists to make truthfully. Refusing says the same thing honestly, and
        # --force is how a caller says it accepts an unprotected box.
        echo "  wsl holder NOT started on $name: the live holder was taken with --force and carries no"
        echo "    hold lock, and $(lock_holder "$(hold_lock_path "$name")") holds it now, so this run"
        echo "    cannot take one for it. That VM is not protected from another session's restart-wsl."
        echo "    Wait for that lock, or pass --force to accept an unprotected box."
        return 1
      fi
    fi
    if [ "$rtok" = '-' ]; then
      # A holder from before the handshake. It is running and it is recognizably the old payload,
      # but it does not read its stdin and carries no token, so there is no way to ask it anything
      # and no way to end its Windows-side tree cleanly (ludics-lite#192). Saying "held" here
      # would be the unobserved claim this whole change is about, so it says what it has instead.
      echo "  wsl holder for $name predates the token handshake: it cannot be asked to prove it is"
      echo "    still holding that VM, and its tree will outlive its channel. End it with"
      echo "    'wake-lab.sh unhold $name' and take the hold again."
      return 1
    fi
    if gp=$(hold_handshake "$name" "$rtok" "$HOLD_WAIT_SECONDS"); then
      if [ "$rgp" != 0 ] && [ "$gp" != "$rgp" ]; then
        # Only the holder recorded here knows this token, so a DIFFERENT guest pid answering with
        # it is a record that no longer describes what is running. Refuse rather than adopt it.
        echo "  ANOMALY: the holder for $name answers its token from guest pid $gp, not the recorded $rgp; the record does not describe what is running"
        return 1
      fi
      # This deliberately does NOT write the recovered guest pid back into the record, though an
      # earlier round of this change did. Writing here cannot be made safe: this path holds no lock
      # (the holder it is reusing owns the box's), so an overlapping `unhold` can clear the record
      # between the handshake and the rewrite, and the rewrite would then resurrect a released
      # holder's record -- or land on the record of whichever run took the freed lock next, leaving
      # THAT holder alive and unrecorded. The reason to write it has gone anyway: the cleanup probe
      # asks the VM by TOKEN and not by recorded pid, so a record with guest pid 0 is as usable for
      # ending a survivor as one without. The pid is reported here, where it is evidence, and not
      # stored, where it would be a race.
      echo "  wsl holder observed on $name (guest shell $gp answered its token over $rd)"
      return 0
    fi
    echo "  wsl holder for $name (pid $rp) did not answer its token within ${HOLD_WAIT_SECONDS}s over $rd"
    echo "    The client is alive, so this is not a holder that exited -- but nothing proves it is"
    echo "    still holding that VM. It belongs to an earlier run: left running and recorded, because"
    echo "    killing it over a failed probe of OURS would unhold that lane's VM, which is the exact"
    echo "    failure this flag exists to prevent. End it with 'wake-lab.sh unhold $name' if this"
    echo "    lane needs the box."
    return 1
  fi
  if [ "${HOLD_LOCKED:-0}" != 1 ] &&
     ! lock_take_fd_strict "$(hold_lock_path "$name")" "--hold" "$HOLD_FD"; then
    if [ "$FORCE" = 1 ]; then
      # Recorded, not just printed: the line below scrolls past, while the record is what `unhold`
      # reads at the end of the lane -- and "this box was never protected" is exactly what a lane
      # whose results depend on the VM surviving needs told, however long afterwards (#184 (b)).
      prot=unprotected; hold_locked=0
      echo "  wsl holder on $name proceeds WITHOUT the hold lock (--force): $(lock_holder "$(hold_lock_path "$name")")"
    else
      echo "  wsl holder NOT started on $name: $(lock_holder "$(hold_lock_path "$name")") — that box's VM is already spoken for; wait for the holder, or --force"
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
  # ...but a marker with a usable record behind it is not stale state, it is an UNFINISHED
  # RELEASE. Since #192 an unhold that could not reach the box keeps both deliberately, so that a
  # later one can re-probe off the recorded guest pid and token -- and those two are the only way
  # that tree can ever be ended short of a host-global restart-wsl. Deleting them here and starting
  # a second holder would make the first one permanently untracked, still pinning the VM, and
  # outliving the release of the holder about to be spawned. So this run finishes that job first,
  # and only takes the box if the VM says the old guest shell is gone.
  # The gate is the RECORD, not the marker. A marker says an unhold ended the client deliberately,
  # which is what release_hold needs to tell a release from a loss -- but the question here is
  # different and simpler: could a holder of ours still be running in that VM? Any record carrying
  # a token could mean yes, however its client died, so the marker is not required to ask. Two
  # things follow. A marker that could not be written (a state filesystem briefly full) no longer
  # loses the pending cleanup it was the only sign of, and a holder that died WITHOUT an unhold --
  # the ludics-lite#237 shape, whose orphan the lore says nothing can name -- is confirmed here
  # too, where before this it was simply deleted.
  # The record exactly as this call saw it, which is what the unlink below is allowed to remove --
  # including whether it was THERE. Content alone cannot tell "no record" from "another run's
  # zero-length claim", since `cat` answers the empty string for both, and reading the second as
  # the first would let an unserialized racer delete a claim created a moment ago.
  rec_seen=$(cat "$f" 2>/dev/null); rec_existed=0; [ -e "$f" ] && rec_existed=1
  rec=$(hold_pid_read "$f" 2>/dev/null) || rec=""
  if [ -n "$rec" ]; then
    read -r rp rd rt rsc rtok rgp rprot <<<"$rec"; : "$rp" "$rt" "$rsc" "$rprot"
    if [ -n "$rtok" ] && [ "$rtok" != '-' ]; then
      { echo "  $name has a holder on record whose client is gone (token $rtok);"
        echo "  confirming the VM is free of it before taking the box:"; }
      HOLD_CONFIRM=""
      hold_confirm_gone "$name" "$rd" "$rgp" "$rtok" "its client ended"
      if [ "$HOLD_CONFIRM" != gone ]; then
        echo "  wsl holder NOT started on $name: that earlier holder may still be running in the VM,"
        echo "    and starting a second one would leave it untracked and pinning the box for good."
        echo "    Its record is kept; run 'wake-lab.sh unhold $name' again when the box answers."
        return 1
      fi
    fi
  fi
  # ...and a marker from some earlier release goes with it: left in place it would mask the loss
  # of the holder about to be spawned, which is the one thing this reporting exists to catch.
  #
  # Conditionally, though: this unlink used to take whatever occupied the path. Two --force holds
  # racing -- or two holds where the lock could not be attempted at all -- are neither of them
  # serialized, so both can pass the checks above, and the second would then remove the FIRST's
  # freshly created noclobber claim and let both spawn a holder over one record. The claim exists
  # precisely to make that impossible, so what is removed here is the record this call INSPECTED
  # and nothing else; a record that changed underneath is another run's, and its claim stands.
  now_existed=0; [ -e "$f" ] && now_existed=1
  if [ "$now_existed" = "$rec_existed" ] && [ "$(cat "$f" 2>/dev/null)" = "${rec_seen:-}" ]; then
    rm -f "$f" "${f%.pid}.releasing" 2>/dev/null
  else
    echo "  wsl holder for $name is being created by another run ($f changed underneath); nothing was started"
    return 1
  fi
  if ! ( set -C; : > "$f" ) 2>/dev/null; then
    if [ -e "$f" ]; then
      echo "  wsl holder for $name is already being created by another run ($f is claimed); nothing was started"
    else
      echo "  wsl holder on $name could NOT be recorded at $f; nothing was started"
    fi
    return 1
  fi
  # This lane's identity, and the only thing about the holder that is not the same on every box and
  # in every run. Bare word characters: it is spelled into a Windows command line, into the guest's
  # argv, and into a grep pattern over `ps` output, and it must mean the same thing in all three.
  [ "$prot" = protected ] && hold_locked=1
  token=wlh-$$-$(date +%s)-${RANDOM:-0}
  # The channel. It is a fifo and not a pipe because a pipe cannot be reopened, and the handshake
  # -- including a LATER invocation's handshake against this same holder -- has to be able to write
  # to the holder's stdin again long after this shell is gone.
  rm -f "$fifo" "$out" 2>/dev/null
  if ! mkfifo -m 600 "$fifo" 2>/dev/null || ! : > "$out" 2>/dev/null; then
    echo "  wsl holder on $name could NOT be given a channel at $fifo; nothing was started"
    # The claim goes LAST. It is what keeps another run out, so unlinking it first opens a window
    # in which a second hold can claim the box and create its channel -- and the operands still to
    # come would then delete that new channel out from under it.
    rm -f "$fifo" "$out" "$f" 2>/dev/null
    return 1
  fi
  # READ-WRITE, and that is the whole teardown contract on this side. The holder must not see EOF
  # while its client lives -- an ssh whose stdin is already at EOF (`-n`, or `</dev/null`, which is
  # what this used to pass) makes the remote shell exit the moment it starts. Opening the fifo
  # `<>` gives the descriptor a writer of its own, so it never reaches EOF while it is open, and
  # the holder inherits THAT descriptor as its stdin: the only thing that can end it is the channel
  # closing, which is what happens when the client dies, by `unhold` or otherwise. Descriptor 3 is
  # below LOCK_FD_BASE and cannot collide with a lock's.
  # `-n` is gone with it. It was there so that a backgrounded ssh reading the caller's terminal
  # could not be stopped by SIGTTIN -- and a STOPPED holder answers `kill -0` exactly like a live
  # one. A fifo is not a terminal, so there is no SIGTTIN to take; what replaces `-n` is that this
  # holder's stdin is never the caller's.
  if ! exec 3<>"$fifo"; then
    echo "  wsl holder on $name could NOT open its channel at $fifo; nothing was started"
    rm -f "$f" "$fifo" "$out" 2>/dev/null
    return 1
  fi
  # NOT capped, and that is deliberate: every other remote command here is a finite probe, and
  # this one is meant to run until `unhold` kills it. A cap on the holder would be a timer on
  # the lane — the sized `sleep N` this design exists to avoid, wearing a different hat.
  #
  # `8>&-` — LANE_FD, spelled as the literal bash 3.2 requires in a redirection — is the whole
  # reason a held box can still be swept. This runs inside start_wsl's per-box subshell on the
  # restart path, and that subshell holds the box's LANE lock for the length of the restart; a
  # holder that inherited it would carry it for the life of the lane instead, and the sweep that
  # holder exists to serve would then wait out its LAB_LOCK_WAIT against it and skip every unit
  # on that box (ludics-lite#224). Only the HOLD lock may travel to the holder. The rule for
  # anything added here later: a LONG-LIVED child of this function closes fd 8 and keeps fd 9.
  # `3<&-` after the dup: the holder needs the channel as its stdin, not as a second descriptor it
  # could never reach anyway.
  ssh -o BatchMode=yes -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
      "$dest" "$HOLD_PAYLOAD $token" >"$out" 2>/dev/null 0<&3 3<&- 8>&- &
  pid=$!
  # This shell's own handle on the channel goes now: the holder has its copy, and a descriptor left
  # open here would be inherited by everything spawned after it -- including the sidecar, which
  # outlives this function and would then be a second writer keeping a dead holder's channel from
  # ever reaching EOF.
  exec 3>&-
  # The lock must not depend on what the ssh client does with descriptors it inherited: OpenSSH
  # may close everything above stderr at startup, and then nothing would hold the flock once
  # this subshell exits. So a sidecar process holds the hold lock instead — it inherits the very
  # descriptor the flock lives on, so there is no window in which the VM is unprotected — and it
  # exits as soon as the holder does, by `unhold` or otherwise, taking the lock with it.
  #
  # It is an EXEC'd process, not a brace group: a forked bash keeps every descriptor bash holds
  # internally, including its copy of a caller's pipe, and a background child holding that pipe
  # hangs `wake-lab.sh kick-wsl --hold rog | tee log` — or any caller reading the command's
  # output — for the whole life of the lane. Those descriptors are close-on-exec, so exec'ing
  # anything sheds them; HOLD_FD — opened by the take above, or by the reservation this subshell
  # inherited it from — is not, so the lock survives. perl is already the lab lock's own
  # dependency.
  # `8>&-` for the same reason as the holder above, and it matters more here: this process
  # exists to keep a descriptor alive, so an inherited lane lock would be kept alive exactly as
  # deliberately as the hold lock it is for.
  # The holder's pid is its LAST argument, which is what ties this sidecar to this holder: the tag
  # alone names every sidecar on this machine, and `release_hold` must be able to tell its own from
  # the one belonging to another box's lane before it signals anything (#184 (b)).
  perl -e 'my $tag = "wake-lab-hold-lock"; my $p = shift; while (kill 0, $p) { sleep 1 }' \
    "$pid" >/dev/null 2>&1 </dev/null 8>&- &
  sidecar=$!
  spawn_epoch=$(date +%s); spawned=1
  # An unrecordable holder is a leaked one: nothing would ever unhold it. Kill it rather than
  # leave it running unowned. The guest pid is 0 until the handshake answers with it.
  if ! hold_record_write "$f" "$pid" "$dest" "$spawn_epoch" "$sidecar" "$token" 0 "$prot"; then
    kill "$pid" "$sidecar" 2>/dev/null
    echo "  wsl holder on $name could NOT be recorded at $f — holder (pid $pid) killed rather than leaked"
    # ...but killing the client is not the end of it, and here the token cannot be written down at
    # all: this is the one path where the identity exists only in this shell. The guest shell may
    # already be running, a plain `kick-wsl --hold` leaves the VM up, and the tree can outlive its
    # channel -- so the VM is asked now, while the token is still known, rather than after it is
    # lost with the record that could not be written.
    HOLD_CONFIRM=""
    hold_confirm_gone "$name" "$dest" 0 "$token" "its unrecordable hold killed the client"
    [ "$HOLD_CONFIRM" = gone ] ||
      echo "    That holder cannot be recorded, so nothing will name it later: its token is $token."
    # Not through hold_state_clear: `$f` is still this invocation's zero-length claim -- the write
    # that would have filled it is what just failed -- and that function categorically reads an
    # empty record as another run's claim in progress, which is what it must do for records it did
    # not create. These three paths were created by THIS call, seconds ago and under that claim, so
    # they are removable here and nowhere else. Leaving them would refuse the next hold until the
    # claim went stale and make every unhold until then report a lost holder that never existed.
    rm -f "$f" "$fifo" "$out" 2>/dev/null
    return 1
  fi
  # The lock this holder now carries says whatever the take that opened the descriptor said, and
  # on the restart path that is `wake-lab restart` with the restarter's pid — a line that outlives
  # the restart by the whole length of the lane and names a process that has already exited, in
  # every refusal message here and in every `skip (box ... reserved by ...)` the sweep publishes.
  # So relabel it for the holder that is actually there.
  lock_label "$(hold_lock_path "$name")" "--hold" "$pid"
  echo "  wsl holder started on $name (via $dest, pid $pid, token $token)"
  # The observation, and the only one made: the token comes back THROUGH the VM or the hold failed.
  # There is no local half to combine it with any more. `kill -0` on our own pid was never the
  # claim (an ssh client can outlive the command it ran), a wsl.exe in `tasklist` was not either
  # (the owner's console shell is one, and on both lab boxes it certified a holder of ours that did
  # not exist), and the 20-second settle those two needed between them was a proxy for exactly what
  # the handshake now measures directly -- so it is gone, along with the wait it cost every hold.
  if gp=$(hold_handshake "$name" "$token" "$HOLD_WAIT_SECONDS"); then
    # Checked, like the first write: a state directory that filled up between the two leaves a
    # record with guest pid 0 or a truncated one, and reporting the hold established over that
    # hands the lane a holder `unhold` cannot check the VM for or end by pid. An unusable record
    # is the unrecordable holder one step later, and it gets the same treatment.
    if hold_record_write "$f" "$pid" "$dest" "$spawn_epoch" "$sidecar" "$token" "$gp" "$prot"; then
      echo "  wsl holder observed on $name (guest shell $gp in the VM answered its token over $dest)"
      return 0
    fi
    echo "  wsl holder on $name answered its token, but its record could NOT be completed at $f"
    echo "    — the hold fails rather than reporting one the release cannot work with."
    # ...and it falls through to the teardown below rather than deleting anything: the FIRST write
    # landed, so the record on disk still carries this lane's token, which is the whole of what the
    # cleanup probe needs. Deleting it here would do exactly what the failed-handshake path was
    # fixed not to do -- kill the client and leave a confirmed guest shell with nothing naming it.
  fi
  # Only a holder THIS call spawned is cleaned up, and by construction that is the only kind that
  # reaches here: a holder we merely reused belongs to an earlier invocation that may still be
  # protecting a running lane, and the reuse branch above returns without touching it.
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
      echo "  wsl holder on $name stopped (pid $pid)"
    else
      echo "  wsl holder on $name is gone (pid $pid no longer names it)"
    fi
    # Killing the client is not the claim here either, and this is the WORST place to assume it.
    # A handshake that did not answer in time does not mean the guest shell never started: it may
    # be running in that VM right now, and if it survives its channel -- the #192 shape -- killing
    # the client and deleting the record would leave it pinning the box with nothing naming it,
    # while every later `unhold` reports no holder recorded. The token is in its argv, so the VM
    # can still be asked, and the record is kept unless the answer is that it is gone.
    HOLD_CONFIRM=""
    hold_confirm_gone "$name" "$dest" 0 "$token" "its failed hold killed the client"
    if [ "$HOLD_CONFIRM" = gone ]; then
      echo "    nothing of ours holds that VM"
      # Compare-and-delete, as the release does, and only while this shell really holds the box's
      # hold lock -- which it normally does, since lock_take_fd_strict opened fd 9 HERE and the
      # holder only inherited a copy, so a competing --hold is refused throughout. When it does
      # not (a --force hold, or a lock directory that could not be opened at all) the probe above
      # has just spent seconds unlocked, and compare-and-delete is two operations: a replacement
      # landing between them would have this call remove a LIVE holder's state. Unserialized, the
      # state stays; the next --hold confirms and clears it, which it now does for any record.
      if [ "$hold_locked" = 1 ]; then
        hold_state_clear "$name" "$pid" "$token" >/dev/null
      else
        echo "    Its record is left in place: without $name's hold lock this cannot remove state"
        echo "    without racing whoever holds it. The next --hold clears it after confirming."
      fi
    else
      # The marker says the client was ended deliberately, which is what stops the next reader
      # calling this a holder the lane lost.
      : > "${f%.pid}.releasing" 2>/dev/null ||
        echo "    (its release marker could not be written; the record below is what matters)"
      echo "    Its record is KEPT (token $token): that is the only way anything can name what may"
      echo "    still be running in $name's VM. 'wake-lab.sh unhold $name' finishes it."
    fi
  else
    # We spawned a holder, but the record no longer names it: a concurrent run replaced it after
    # ours exited. Killing what the file names now would unhold THAT run's lane.
    echo "  wsl holder for $name was not observed; the record now names another run's holder, left alone"
  fi
  return 1
}

# The other end of the teardown, and the one #192 is about: the local kill is not the claim. This
# asks the VM whether the guest shell is still there, and if it is, ends it BY PID -- which is a
# thing this script can only do at all because the holder carries a token: without one, every
# `wsl.exe` on that Windows side looks alike and the only cure documented for an orphan was a
# host-global `restart-wsl`, which destroys every other session's work on the box.
# Poll the VM until it stops saying "still there". Only that answer is worth asking again: EOF has
# to cross a dead channel, a Windows sshd and wsl.exe before the guest shell reads it, and a kill
# by pid has to reach a process that may be mid-syscall -- neither is instant, and a single
# immediate look would report every slow teardown as a leak. "Gone" and "no answer" are both final.
hold_watch_gone() { # hold_watch_gone <windows-alias> <token>
  local deadline=$((SECONDS + HOLD_TEARDOWN_SECONDS)) obs
  while :; do
    hold_remote_gone "$1" "$2"; obs=$?
    [ "$obs" = 1 ] || return "$obs"
    [ "$SECONDS" -ge "$deadline" ] && return 1
    sleep 2
  done
}

hold_confirm_gone() { # hold_confirm_gone <box> <alias> <guest pid> <token> <what ended it>
  local name=$1 dest=$2 gp=$3 tok=$4 what=$5 obs
  hold_watch_gone "$dest" "$tok"; obs=$?
  # The pid to speak about, and to kill by: whatever the VM just showed us, falling back to what
  # the record knew. A hold whose handshake never answered has only the former.
  [ -n "$HOLD_REMOTE_PID" ] && gp=$HOLD_REMOTE_PID
  [ -n "$gp" ] && [ "$gp" != 0 ] || gp='?'
  case "$obs" in
    0) HOLD_CONFIRM=gone
       echo "    ...and its guest shell (pid $gp) is gone from the VM, observed over $dest" ;;
    2) HOLD_CONFIRM=unverified; HOLD_LEAK=1
       echo "    ...but $dest did not answer, so this does NOT claim the VM is unheld: the holder's"
       echo "    tree may still be running there. The record is KEPT -- its guest pid ($gp) and"
       echo "    token are the only things that could ever end that tree without a restart-wsl --"
       echo "    so run 'wake-lab.sh unhold $name' again when the box answers, and it will finish." ;;
    1) echo "    ...but its guest shell (pid $gp) is STILL RUNNING in the VM ${HOLD_TEARDOWN_SECONDS}s after $what:"
       echo "    the holder outlived its channel, which is ludics-lite#192 happening on this box."
       echo "    Ending it by pid over $dest, which is what the token makes possible:"
       # `pkill -x -f <shape>` and not `kill <pid>`: the match and the signal happen in the same
       # guest-side operation, so a holder that exits between them cannot have its number reused by
       # something else that then gets killed instead. `-x` anchors the pattern to the WHOLE
       # command line and the dots stand in for its spaces, which keeps the argument free of
       # anything cmd.exe would take apart on the way.
       capped "$PROBE_CAP" ssh -o BatchMode=yes -o ConnectTimeout=15 "$dest" \
         "wsl.exe -d Ubuntu -e pkill -x -f $(printf '%s' "$HOLD_GUEST_ARGV" | tr ' ' '.').$tok" \
         >/dev/null 2>&1
       hold_watch_gone "$dest" "$tok"; obs=$?
       case "$obs" in
         0) HOLD_CONFIRM=gone
            echo "    ...ended: the guest shell is gone and nothing of ours is left on $name. Note that"
            echo "    the CHANNEL did not end it -- that is the contract this holder is built on, so a"
            echo "    box reaching this line is worth reporting rather than just cleaning up." ;;
         2) HOLD_CONFIRM=unverified; HOLD_LEAK=1
            echo "    ...and then $dest stopped answering, so whether that kill landed is unknown."
            echo "    The record is KEPT: run 'wake-lab.sh unhold $name' again when the box answers." ;;
         *) HOLD_LEAK=1; HOLD_CONFIRM=pinned
            echo "    ...and it SURVIVED that too. $name is still pinned by a holder of ours: guest"
            echo "    pid $gp, token $tok. Nothing short of ending that process or a restart-wsl"
            echo "    (which destroys every other session on the box) will free it." ;;
       esac ;;
  esac
}

# Give the box's hold lock back at the end of a release. Closing the descriptor is what releases
# the flock, and it is spelled with the literal bash 3.2 needs in a redirection.
hold_cleanup_unlock() { # hold_cleanup_unlock <took-it?>
  [ "$1" = 1 ] || return 0
  eval "exec $HOLD_FD>&-" 2>/dev/null
  return 0
}

# Remove a holder's record and channel, and ONLY that holder's.
#
# `unhold` now spends up to HOLD_TEARDOWN_SECONDS between the kill and here, asking the VM whether
# the guest shell is gone -- and the hold lock went with the sidecar at the top of the release, so
# that window is long enough for another session's `kick-wsl --hold` to take the lock and write ITS
# record, fifo and stdout file at these very paths. Unlinking those would leave that holder running,
# locked, and unrecorded: a VM pinned until the box reboots, caused by a cleanup. It would not even
# notice, because an open fifo survives its own unlink. So the removal is conditional on the state
# still naming the holder this call ended.
hold_state_clear() { # hold_state_clear <box> <pid> <token> — rc 1 if the state is somebody else's
  local f=$HOLD_STATE_DIR/hold-$1.pid rec p2 tok2
  rec=$(hold_pid_read "$f" 2>/dev/null) || rec=""
  if [ -n "$rec" ]; then
    read -r p2 _ _ _ tok2 _ _ <<<"$rec"
    if [ "$p2" != "$2" ] || [ "$tok2" != "$3" ]; then
      echo "    ...and $1's record now names another run's holder (pid $p2): its state is left alone"
      return 1
    fi
  elif [ -e "$f" ] && [ ! -s "$f" ]; then
    # EMPTY, which is specifically another run's claim, taken between its noclobber create and its
    # pid write. A record that is merely unparseable is NOT that: a claim is filled in with one
    # write, so nothing else ever leaves a non-empty record this cannot read, and the entry above
    # has already judged it as naming no holder. Reading the two as one would let a corrupt record
    # outlive every unhold, which is a box nothing can ever be recorded against again.
    echo "    ...and another run has claimed $1's record: its state is left alone"
    return 1
  elif [ ! -e "$f" ]; then
    # No record at all: nothing here is demonstrably ours, and the fifo and stdout file at these
    # paths may already belong to a hold being taken right now. Only the marker goes.
    rm -f "${f%.pid}.releasing"
    return 0
  fi
  # Channel first, claim last, for the reason the spawn path gives: the record is what keeps
  # another run out, so it is the last thing to go.
  rm -f "$(hold_fifo_path "$1")" "$(hold_out_path "$1")" "${f%.pid}.releasing" "$f"
  return 0
}

release_hold() { # release_hold <box> — end the recorded holder; always rc 0 (an already-dead
                 # holder is reported by setting HOLD_ANOMALY, which the caller turns into rc 2,
                 # and a holder that outlived its channel by setting HOLD_LEAK, which becomes
                 # rc 3), always says what it did and never claims more than it observed
  local f=$HOLD_STATE_DIR/hold-$1.pid rec p d t sc tok gp prot rel fifo out sargs i cleanup_locked=0 was_live=0
  # Per box: `unhold rog minix` releases them in one process, and a verdict carried over from the
  # first box would decide what is kept or removed for the second.
  HOLD_CONFIRM=""
  # An unhold is not atomic: it kills the holder and then removes the record, and between those
  # two it can be interrupted (or a second unhold can overlap it -- which the routine now invites,
  # since it tells a run whose unhold has not come back to chase it). The record left behind then
  # names a pid that IS dead, and without this marker the retry would read a deliberate release as
  # a holder the lane lost and call valid results suspect. So intent is written down BEFORE the
  # kill: whoever finds the record next can tell "an unhold ended this" from "this died".
  rel=${f%.pid}.releasing
  fifo=$(hold_fifo_path "$1"); out=$(hold_out_path "$1")
  # Only the marker: the fifo and stdout file at these paths may belong to a hold being taken right
  # now, and a record is what says otherwise.
  if [ ! -r "$f" ]; then rm -f "$rel"; echo "  no wsl holder recorded for $1"; return 0; fi
  # From here the release can hold the box's lock, and every return below goes through the unlock.
  rec=$(hold_pid_read "$f" 2>/dev/null) || rec=""
  read -r p d t sc tok gp prot <<<"${rec:-}"; : "$t"
  # The hold-lock sidecar goes with the holder: it exits on its own once the holder is gone, and
  # killing it here is what makes the box destroyable again immediately rather than a poll later.
  # Its pid is checked the way the holder's is — a record outlives both processes, and by the time
  # anyone runs `unhold` the number may belong to something else entirely — and the check is for
  # THIS holder's sidecar, not for any sidecar: the tag is the same in every lane on this machine,
  # so a stale record whose number has been recycled onto a sibling box's sidecar would otherwise
  # release that box's hold lock and leave its VM unprotected (#184 (b)).
  if [ -n "${sc:-}" ] && [ "${sc:-0}" != 0 ]; then
    sargs=$(ps -ww -o args= -p "$sc" 2>/dev/null)
    case "$sargs" in
      *wake-lab-hold-lock*" $p") kill "$sc" 2>/dev/null ;;
    esac
  fi
  if hold_pid_live "$f"; then
    was_live=1
    : > "$rel" 2>/dev/null
    kill "$p" 2>/dev/null
    # The kill is where this used to stop, on the reasoning that "killing the local client closes
    # the channel and sshd ends the command it was running". It does not on Windows (#192), so the
    # client is first waited out -- a signalled process is not a dead one, and the EOF the holder
    # ends on cannot cross a channel that is still open -- and then the VM itself is asked.
    for i in 1 2 3 4 5; do kill -0 "$p" 2>/dev/null || break; sleep 1; done
  fi
  # ...and only NOW can the release take the box's hold lock, which is why this sits below the kill
  # rather than beside the sidecar's. The lock lives on a descriptor the HOLDER inherits -- that is
  # the whole mechanism, the flock lasting exactly as long as the holder -- so while that client is
  # alive the lock is not free to take, and a take attempted before the kill simply fails.
  #
  # Taking it matters because comparing the record's identity and then unlinking it are two
  # operations, and between them -- as between any two steps from here on, and this release now
  # spends seconds asking the VM a question -- another session's `kick-wsl --hold` can take the box
  # the sidecar has stopped protecting and write its own record, fifo and stdout file at these
  # paths. The identity check narrows that window; holding the box is what closes it. A `--hold`
  # arriving now is refused by the same interlock that refuses a restart, and one that got in FIRST
  # refuses us instead -- the honest outcome, with the identity check keeping this release off its
  # state.
  for i in 1 2 3 4 5; do
    lock_take_fd_strict "$(hold_lock_path "$1")" "unhold" "$HOLD_FD"
    case $? in
      0) cleanup_locked=1; break ;;
      2) break ;;   # no lock to be had here at all: waiting cannot change that
    esac
    sleep 1
  done
  [ "$cleanup_locked" = 1 ] ||
    echo "  note: $1's hold lock is held by something else, so this release is not serialized against it; nothing of another run's will be removed"
  if [ "$was_live" = 1 ]; then
    echo "  wsl holder released on $1 (pid $p killed)"
    [ "$prot" = unprotected ] &&
      echo "    It was taken with --force and never held $1's hold lock, so the box was NOT protected from another session's restart-wsl while it ran"
    if [ -z "${tok:-}" ] || [ "$tok" = '-' ]; then
      # A legacy record, or one whose handshake never answered: there is no pid in that VM to ask
      # about, so the one thing this must not do is repeat the old sentence and call it unheld.
      HOLD_CONFIRM=unverified; HOLD_LEAK=1
      echo "    Its holder carries no token (a record from before the handshake), so nothing here"
      echo "    can say whether its Windows-side tree ended with it -- on Windows it usually does"
      echo "    NOT (ludics-lite#192). Treat $1 as possibly still pinned: this release exits 3 and"
      echo "    keeps what it knows, because saying 0 here is the sentence #192 was filed about,"
      echo "    and the runbook now reads a clean exit as a box that needs nothing."
    else
      hold_confirm_gone "$1" "$d" "$gp" "$tok" "its client was killed"
    fi
  elif [ -e "$rel" ]; then
    # The holder is gone and an unhold is on record as having ended it. That is a completed
    # release whose record outlived it, not a loss: say so, clear up, and leave rc 0.
    echo "  wsl holder on $1 was already ended by an earlier unhold (pid ${p:-?})"
    # ...except that "ended" is only half of it since #192. An earlier unhold may have killed the
    # client and then not reached the box to see whether the tree went with it; it keeps its record
    # precisely so that this run can finish the job, and clearing that record would throw away the
    # guest pid and token that are the only way to end that tree short of a restart-wsl.
    if [ -n "${tok:-}" ] && [ "$tok" != '-' ]; then
      hold_confirm_gone "$1" "$d" "$gp" "$tok" "an earlier unhold ended its client"
    else
      echo "    ...and it carries no guest pid to check the VM against; its record is cleared"
    fi
  elif [ ! -e "$f" ]; then
    # The record VANISHED between this run's entry and here, which is the one interleaving the
    # marker cannot cover on its own: a concurrent unhold got through its whole release -- marker,
    # kill, `rm -f` of both files -- inside that window, leaving nothing behind to read. The fix is
    # not to serialize, but to stop treating an absent record as evidence: a record is removed by
    # exactly one thing, a release that completed, so a record that is GONE never witnesses a loss.
    # Only a record that is STILL THERE naming a holder that is not does that, which is the branch
    # below. Locking this instead would put an acquire in front of the one command that has to work
    # when everything else is wedged -- unhold is how a lane ends -- and a marker that outlived its
    # release, the other suggestion, would mask the next holder's loss.
    echo "  wsl holder on $1 was released by a concurrent unhold; nothing to do"
  else
    # NOT a routine outcome, though this reported it as one until 2026-09-18. A lane ends by
    # unhold and nothing else ENDS the holder deliberately, so a holder already gone is one the
    # lane LOST -- the box slept or rebooted under it, the network dropped, something killed it.
    # What that costs is the LAB LOCK, not usually the VM: the lock lives on the
    # holder's descriptor, so it was released the moment the holder died and the box stopped being
    # reserved -- another session's `restart-wsl` was then free to take it with a host-global
    # `wsl --shutdown`, which is the 2026-09-16 failure the interlock exists to prevent. Note that
    # the interlock only covers THIS script's `sleep`/`down` verbs, which reserve the box and are
    # refused while it is held: a box slept by hand or from Windows bypasses it entirely and takes
    # the holder with it. That is 2026-09-18 -- both boxes slept at 11:33 with a hold outstanding,
    # four hours into the lane, and the only thing that ever said so was this line, which called it
    # a release and was believed. The VM
    # itself commonly survives, because a dying holder ORPHANS its wsl.exe on the Windows side
    # rather than taking it down (measured 2026-09-18: a holder killed at 12:47:37 left its two
    # wsl.exe running, and four from 07:08 were still up six hours later). That is not a
    # consolation -- an orphan is unowned, invisible to this script, and ends only at the next
    # restart-wsl or reboot. Either way the lane no longer holds what it believes it holds, so
    # this says it in the words of a fault and the caller exits non-zero.
    HOLD_ANOMALY=1
    case ${t:-} in
      ''|*[!0-9]*) echo "  ANOMALY: wsl holder on $1 had already exited (pid ${p:-?})" ;;
      *) echo "  ANOMALY: wsl holder on $1 had already exited (pid ${p:-?}, spawned $(date -r "$t" '+%H:%M:%S' 2>/dev/null || echo '?'), so it lived at most $(( ($(date +%s) - t) / 60 )) min)" ;;
    esac
    echo "    This unhold did not end it. The lab lock died with it, so $1 stopped being RESERVED"
    echo "    at that moment and another session's restart-wsl was free to shut the VM down under"
    echo "    the lane. Treat this lane's results on $1 as suspect."
    # The orphan this used to be able to say nothing about. A holder that died without being
    # unheld leaves its Windows-side tree running -- that is measured, not feared -- and until the
    # holder carried a token there was no way to name that tree, so the only documented cure was a
    # restart-wsl that destroys every other session on the box. With a token there is: the guest
    # shell has a pid, the pid can be checked, and if it is still there it can be ended alone.
    if [ -n "${tok:-}" ] && [ "$tok" != '-' ]; then
      hold_confirm_gone "$1" "$d" "$gp" "$tok" "the holder died"
    fi
  fi
  # What the release leaves behind, and the rule is one line: the state goes only when the box has
  # been OBSERVED free. An unverified teardown keeps it because the record is the only place the
  # guest pid and token live and a later unhold re-probes off exactly those two (the marker branch
  # above); a PINNED one keeps it for the same reason and a better one, since something of ours is
  # demonstrably still running there. Anything that reaches here having confirmed nothing at all --
  # a legacy record, which has no identity to confirm with -- is cleared as before.
  case "$HOLD_CONFIRM" in
    pinned|unverified) hold_cleanup_unlock "$cleanup_locked"; return 0 ;;
  esac
  # ...and only under the lock. Without it the compare-and-delete is two operations with nothing
  # holding the box between them: a competitor that took the lock first can be paused between its
  # take and its record write, long enough for the check below to read OUR identity and the unlink
  # to land on THEIRS. Keeping a stale record costs the next `--hold` a confirmation it will do
  # anyway; deleting a live one costs a VM until the box reboots.
  if [ "$cleanup_locked" != 1 ]; then
    echo "    ...and its record is left in place: without $1's hold lock this release cannot remove"
    echo "    state without racing whoever holds it. The next --hold clears it after confirming."
    hold_cleanup_unlock "$cleanup_locked"
    return 0
  fi
  hold_state_clear "$1" "${p:-0}" "${tok:--}"
  hold_cleanup_unlock "$cleanup_locked"
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
  # Both failures say the same thing, so it is written once rather than in two copies that can
  # drift; and each tail stays on ONE line, which is what keeps the resolution the very next
  # command after the allocation (ludics-lite#208).
  local nowork="wsl $what FAILED: no work directory"
  dir=$(mktemp -d "${TMPDIR:-/tmp}/wake-lab-wsl.XXXXXX") || { echo "$nowork" >&2; WSL_FAILED="$nowork"; return 1; }
  # Physical path, the house idiom: $TMPDIR on macOS is under /var, a symlink to /private/var
  # (ludics-lite#208).
  dir=$(CDPATH= cd "$dir" && pwd -P) || { echo "$nowork" >&2; WSL_FAILED="$nowork"; return 1; }
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
    # hold lock this subshell already holds is the one the holder must inherit.
    { if [ "$FRESH_WSL" = fresh ] && [ "$FORCE" != 1 ] && ! lab_reserve "$n" "$what" "$LANE_FD"; then
        echo "  wsl $what REFUSED on $n: $RESERVE_REFUSED_BY" >"$dir/$i.out" 2>&1
        printf '1 locked na\n' >"$dir/$i.rc"
      else
        [ "$FRESH_WSL" = fresh ] && [ "$FORCE" != 1 ] && HOLD_LOCKED=1
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
  # cure is to wait rather than to go and look at the box. A sweep lane on the box is one such
  # holder and a `--hold` holder is the other, so a second restart is refused here rather than
  # destroying the lane's units or unholding the VM under them.
  if [ ${#held[@]} -gt 0 ]; then
    line="wsl $what REFUSED on: ${held[*]} (a lab lock is held; wait for the holder, or --force to take the box anyway)"
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
FORCE=0        # --force: destroy the VM even while a lab lock is held (see the lab lock lore)
HOLD_LOCKED=0  # set in a box's subshell once its reservation holds that box's HOLD lock on HOLD_FD
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
  # rc 2, not 1: a lane's cleanup must be able to tell "the holder died under me" (the lane's
  # results are suspect) from an ordinary failure of the unhold command itself. The record is gone
  # either way, so a caller that only cares about cleanup can ignore it, while the sweep can fail
  # the lane on it.
  #
  # rc 3 is the opposite fault and is deliberately not folded into it: the holder did its job and
  # the lane's results are fine, but this release could not leave the box demonstrably free -- a
  # process of ours survived both its channel dying and being ended by pid, or the box never
  # answered and nothing here knows either way. That needs a human on that box, and it needs them
  # for a reason that has nothing to do with the lane's results -- reporting both as rc 2
  # would make the sweep discard good work over a box it should instead be complaining about.
  # An unverified release KEEPS its record, so running `unhold` again once the box answers picks
  # the job up where this one left it rather than starting from no identity at all.
  # The anomaly is checked first: of the two, it is the one that says the results cannot be
  # trusted, and a caller reacting to only one status should react to that one.
  [ "$HOLD_ANOMALY" = 1 ] && exit 2
  [ "$HOLD_LEAK" = 1 ] && exit 3
  exit 0
fi

# Before load_hosts, like --help and --list: a lock path is a function of the lock directory and a
# box NAME alone, and the harness that asks where to put its flock -- the sweep, from a checkout
# that has no business holding this lab's MAC addresses -- must not need the site table to find
# out. It answers the LANE lock, because that is the one a harness takes; the hold lock beside it
# is wake-lab's own, taken by `--hold` alone and never by a lane.
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
