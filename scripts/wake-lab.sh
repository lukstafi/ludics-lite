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
#   after the wake with no kick; the kick is then a harmless no-op. But a VM kept alive across a
#   host resume can carry a DEGRADED dxg bridge (the WSL2 GPU paravirtualization both CUDA and HIP
#   ride on): on 2026-09-05 minix's VM had survived two resumes, and its bridge then refused under
#   load — `misc dxg: dxgvmb_send_sync_msg: vmbus_sendpacket failed: fffffff5` (-EAGAIN) whenever
#   more than about two processes held the GPU — while every standalone probe passed, so the
#   sweep's hip unit went red twice on a "working" device (ludics-lite#60). `restart-wsl` (and
#   `--wait --restart-wsl`) issues `wsl --shutdown` on the Windows host before the start, which is
#   a fresh VM for ~a minute's cost; on a cold-booted box the shutdown is a no-op. The sweep uses
#   it before its GPU units. Nothing inside the VM can issue that restart without killing its own
#   session, which is why it lives here, on the -win side.
# * Under WSL2, /dev/kfd and /dev/dri are never present and `rocm-smi` always says "driver not
#   initialized (amdgpu not found in modules)"; none of that is evidence of a lost passthrough,
#   and a "check the device nodes" step in the WSL path would report the box broken every time.
#   `hipGetDeviceCount` (or `rocminfo` listing the gfx agent) is the evidence. And a stale-but-
#   alive VM is NOT detectable by a single-process probe: hipGetDeviceCount, hiprtc and a kernel
#   launch all pass on it. The only signals are the guest's `dmesg | grep -c 'misc dxg'` growing
#   under a few concurrent GPU processes, or the `hv_utils: TimeSync IC version` renegotiation
#   lines since boot, one per host resume. That is why the fix is a restart, not a probe.
# * A kicked VM on a cold-booted box does not necessarily STAY up: on 2026-09-01, twice in a row,
#   `--wait --wsl` reported both -wsl UP yet both VMs were gone ~4 minutes later (`status`:
#   win=UP, wsl=--). Use the VM promptly after the kick — and after a restart, whose VM is that
#   same freshly kicked one; once an ssh session is running inside it, it stays up. `kick-wsl`
#   re-kicks a box whose Windows side is up.
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
  echo "box    router-active   lan(direct IP)  win(tailscale)  wsl(tailscale)"
  for n in "$@"; do status_one "$n"; done
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
  local name=$1 fresh=${2:-} dest what=kick shut=0 capped_start=0 guest rc
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
      return 0
    fi
    if [ "$rc" = "$CAP_EXPIRED" ]; then
      # The start was issued and the probe simply never came back. A guest that answers settles it.
      if [ -n "$guest" ] && ssh_probe "$guest"; then
        echo "  wsl start probe timed out after ${WSL_START_CAP}s on $name (via $dest); the guest answers, so the VM is up"
        return 0
      fi
      capped_start=1
      # With the guest silent there is no verdict here, and what to do next differs by path. A
      # RESTART must not fall through: the next alias would issue a second `wsl --shutdown`,
      # tearing down the very VM this start may have just booted, so the box goes to start_wsl's
      # poll, which asks the guest on its own deadline. A plain KICK has no shutdown to repeat and
      # a second start is idempotent, so the other alias is worth trying — a wedged LAN side must
      # not cost a box the start its Tailscale alias would have carried.
      echo "  wsl start probe timed out after ${WSL_START_CAP}s on $name (via $dest); leaving the verdict to the guest poll"
      [ "$fresh" = fresh ] && return 0
    fi
  done
  # Every alias tried and one of them left a start in flight: a cap is not a failure anywhere else
  # in this function and it is not one here either, so the poll gets the box rather than the
  # operator getting a kick that may well have worked.
  if [ "$capped_start" = 1 ]; then
    echo "  wsl $what start probe timed out on every alias on $name; leaving the verdict to the guest poll"
    return 0
  fi
  if [ "$fresh" = fresh ] && [ "$shut" = 0 ]; then KICK_PHASE=shutdown
  elif [ "$fresh" = fresh ]; then KICK_PHASE=start
  else KICK_PHASE=kick; fi
  echo "  wsl $what FAILED on $name (no Windows endpoint answered the $KICK_PHASE)"
  return 1
}
KICK_PHASE=""

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
WSL_FAILED=""
start_wsl() {
  local n i dir krc kphase what=kick started=() unshut=() unstarted=() up=() down=() rc=0 line
  local held=()
  [ "$FRESH_WSL" = fresh ] && what=restart
  # One box at a time meant one wedged box could cost its neighbours their restart entirely: on
  # 2026-09-16 rog's start probe hung and minix, second in the loop, never got a restart at all —
  # its VM sat eleven hours old and the sweep's hip unit went red on exactly the stale-dxg
  # condition restart-wsl exists to clear. The boxes are independent Windows hosts and nothing in
  # the kick is shared, so kick them all at once. Each box's output is buffered and replayed in
  # target order afterwards, so the log still reads box by box rather than interleaved.
  dir=$(mktemp -d "${TMPDIR:-/tmp}/wake-lab-wsl.XXXXXX") || {
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
    # KICK_PHASE is set in the subshell, so it comes back alongside the status rather than as a
    # global; a box whose subshell died outright reads as a plain failed start, never as a success.
    # `locked` is a phase of its own for the same reason the others are: it names a different
    # remedy (wait for the holder) from every other way a box can fail to restart.
    { if [ "$FRESH_WSL" = fresh ] && [ "$FORCE" != 1 ] && ! lab_lock_take "$n" "$what"; then
        echo "  wsl $what REFUSED on $n: $(lab_lock_holder "$n")" >"$dir/$i.out" 2>&1
        printf '1 locked\n' >"$dir/$i.rc"
      else
        kick_wsl "$n" "$FRESH_WSL" >"$dir/$i.out" 2>&1
        printf '%s %s\n' "$?" "$KICK_PHASE" >"$dir/$i.rc"
      fi; } &
  done
  wait
  i=0
  for n in "$@"; do
    i=$((i + 1))
    [ -f "$dir/$i.out" ] && cat "$dir/$i.out"
    krc=1; kphase=start
    [ -s "$dir/$i.rc" ] && read -r krc kphase < "$dir/$i.rc"
    if [ "$krc" = 0 ]; then started+=("$n")
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
  # cure is to wait rather than to go and look at the box.
  if [ ${#held[@]} -gt 0 ]; then
    line="wsl $what REFUSED on: ${held[*]} (the lab lock is held; wait for the holder, or --force to take the box anyway)"
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
FRESH_WSL=""   # "fresh" makes kick_wsl shut the VM down first; --wsl alone never kills a live VM
FORCE=0        # --force: destroy the VM even while the lab lock is held (see the lab lock lore)
VERB=wake
TARGETS=()

case "${1:-}" in
  status|sleep|hibernate|down|kick-wsl) VERB=$1; shift ;;
  restart-wsl) VERB=kick-wsl; FRESH_WSL=fresh; shift ;;
  lock-path) VERB=$1; shift ;;
esac

for arg in "$@"; do
  case "$arg" in
    --list) list_hosts; exit 0 ;;
    --wait) WAIT=1 ;;
    --wsl)  WANT_WSL=1 ;;
    --restart-wsl) WANT_WSL=1; FRESH_WSL=fresh ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    all) TARGETS+=(rog minix asus) ;;
    *) TARGETS+=("$arg") ;;
  esac
done
[ ${#TARGETS[@]} -eq 0 ] && TARGETS=(rog minix)

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
