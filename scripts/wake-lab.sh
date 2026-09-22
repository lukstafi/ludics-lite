#!/bin/bash
# Drive the home-lab machines' power state remotely: wake, sleep, hibernate, shut down, inspect.
#
# Waking uses two independent paths, both attempted:
#   1. FRITZ!Box TR-064 `X_AVM-DE_WakeOnLANByMACAddress` — the router emits the magic
#      packet on the wired LAN segment. No credentials needed from the LAN side.
#   2. A magic packet sent directly from this Mac (broadcast, UDP ports 7 and 9).
#
# Usage:
#   wake-lab.sh [rog|minix|tuf|asus|all]  wake (default: rog minix; all: rog minix asus)
#   wake-lab.sh --wait [--wsl] rog        wake, then poll until configured OS answers
#   wake-lab.sh --wait --restart-wsl rog  ...and start WSL from a FRESH VM (wsl --shutdown first)
#   wake-lab.sh status [box...]           per-box reachability and reached OS
#   wake-lab.sh sleep|hibernate|down box  suspend / hibernate / full shutdown
#   wake-lab.sh kick-wsl box              start the WSL VM (it never autostarts at boot)
#   wake-lab.sh restart-wsl box           shut the WSL VM down and start it again
#   wake-lab.sh kick-wsl --hold box       ...and leave a Windows-side holder keeping the VM alive
#   wake-lab.sh unhold box                end that holder (a lane ends by unhold, never by expiry)
#   wake-lab.sh lock-path box             where that box's LANE lock lives, for a harness taking one
#   wake-lab.sh --list                    dump the router's host table
# WSL and Windows hardware notes live with the adapter in scripts/wake-lab-wsl.sh.
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
# defines mac_of, eth_mac_of, ip_of and kind_of, and the script refuses to run without it;
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
#   cannot be woken at all. The new tuf box is Wi-Fi-only too (flotilla PR #3): it needs manual
#   wake, though its native Linux ssh can be checked after it resumes.
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
  for f in mac_of eth_mac_of ip_of kind_of; do
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
  local t bad="" kind
  for t in "$@"; do
    mac_of "$t" >/dev/null 2>&1 || { bad="$bad $t"; continue; }
    kind=$(kind_of "$t") || kind=""
    case "$kind" in wsl|linux) ;; *) echo "wake-lab.sh: invalid kind for $t: ${kind:-(none)} (expected wsl or linux)" >&2; exit 1 ;; esac
  done
  [ -z "$bad" ] && return 0
  echo "wake-lab.sh: not in the host table ($HOSTS_FILE):$bad" >&2
  echo "  the known boxes are the ones mac_of answers for; nothing was sent." >&2
  exit 1
}

# Native Ubuntu ssh aliases. The short box names are the WoL/lock identities; the ssh names
# identify the OS reached after the boot selection. More site facts remain in hosts.sh.
linux_of() { case "$1" in
  rog) echo rog-nv-linux ;;
  minix) echo minix-amd-linux ;;
  tuf) echo tuf-amd-linux ;;
  *) return 1 ;; esac; }

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

# "Up" means the configured OS answers ssh. A dual-boot box can answer through the other OS;
# status reports both probes so a wake never claims to know what GRUB selected.
is_up() { # is_up <box>
  case "$(kind_of "$1")" in
    wsl) wsl_box_live "$1" ;;
    linux) ssh_probe "$(linux_of "$1")" ;;
  esac
}

status_one() { # status_one <box>
  local l host win guest
  l=$(router_active "$1")
  printf '%-6s router-active=%-1s' "$1" "$l"
  if [ "$(kind_of "$1")" = wsl ]; then
    wsl_status_fields "$1"
  else
    host=$(linux_of "$1") || return 1
    if ssh_probe "$host"; then
      printf '  os=linux  linux=UP'
    else
      # A dual-boot box may have booted Windows despite its configured Linux kind. The
      # suffixes are only liveness probes for status; the Windows commands remain in the WSL
      # adapter and are never read on this path.
      case "$1" in
        rog|minix)
          win=${host%-linux}-win; guest=${host%-linux}-wsl
          if ssh_probe "$guest"; then printf '  os=wsl  linux=--  wsl=UP'
          elif ssh_probe "$win"; then printf '  os=windows  linux=--  win=UP'
          else printf '  os=--  linux=--'; fi ;;
        *) printf '  os=--  linux=--' ;;
      esac
    fi
  fi
  printf '\n'
}

do_status() {
  local n wsl_boxes=()
  echo "box    router-active   reached OS and ssh endpoint"
  for n in "$@"; do status_one "$n"; done
  echo
  for n in "$@"; do [ "$(kind_of "$n")" = wsl ] && wsl_boxes+=("$n"); done
  [ ${#wsl_boxes[@]} -gt 0 ] && wsl_status_extra "${wsl_boxes[@]}"
  echo "router-active is the router's NewActive bit for the Ethernet MAC, not the NIC's link state:"
  echo "minutes after a shutdown or hibernate, 1 is a stale DHCP lease still aging out; once settled,"
  echo "1 on a powered-off box means the NIC holds link and is WoL-armed."
}

# ---------------------------------------------------------------- power control
# Poll budgets, in seconds, and they are wall-clock budgets: the loops below run to a deadline
# rather than to an iteration count. Counting iterations quietly lied whenever the boxes stayed
# dark -- each is_up() burns two ssh ConnectTimeouts, so 48 rounds over two unreachable boxes ran
# for about twenty minutes under the name of a four-minute wait, delaying the sweep that is the
# only coverage those backends get. The env overrides exist for the test suite.
WAIT_SECONDS=${WAKE_LAB_WAIT_SECONDS:-240}
DOWN_WAIT_SECONDS=${WAKE_LAB_DOWN_WAIT_SECONDS:-120}

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
  local box fd=$LOCK_FD_BASE rc=0 acted=() confirming=() refused=()
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
    for box in "${acted[@]}"; do
      if power_action "$verb" "$box"; then confirming+=("$box"); else rc=1; fi
    done
    # Its status is the phase's: a box that never went down is a failure of this command, and
    # letting a trailing conditional swallow it would report success over the very line that says
    # the suspend may not have taken.
    if [ ${#confirming[@]} -gt 0 ]; then
      echo "confirming..."
      confirm_down "${confirming[@]}" || rc=1
    fi
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
  if ! eth_mac_of "$name" >/dev/null 2>&1; then
    echo "  $name has no wired NIC in the site file; wake it manually (Wi-Fi cannot receive WoL)"
    return 1
  fi
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

power_action() {
  if [ "$(kind_of "$2")" = wsl ]; then
    wsl_power_action "$@"
    return
  fi
  local cmd host output action_rc
  host=$(linux_of "$2") || return 1
  case "$1" in
    sleep) cmd="systemctl --no-ask-password --check-inhibitors=yes suspend" ;;
    hibernate) cmd="systemctl --no-ask-password hibernate" ;;
    down) cmd="systemctl --no-ask-password poweroff" ;;
    *) return 1 ;;
  esac
  # Flotilla PR #3 verified this native-OS guard and the inhibitor-aware suspend path on
  # ROG and MINIX. A stale ssh alias must never suspend a WSL guest as if it were the host.
  cmd='[ "$(uname -s)" = Linux ] || { echo "OS changed; refresh before requesting power action" >&2; exit 2; }; if grep -qi microsoft /proc/sys/kernel/osrelease; then echo "Refusing to power off WSL; use its Windows host" >&2; exit 2; fi; echo WAKE_LAB_POWER_STARTED; exec '"$cmd"
  echo "$2: $1"
  output=$(capped 30 ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=2 "$host" "$cmd" 2>&1); action_rc=$?
  [ -z "$output" ] || printf '  %s\n' "$(printf '%s\n' "$output" | tail -1)"
  case "$action_rc" in
    0) return 0 ;;
    255|124) echo "  $1 on $2 unconfirmed (connection dropped or timed out); checking reachability"; return 0 ;;
    *) echo "  $1 FAILED on $2 (command exited $action_rc)"; return 1 ;;
  esac
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

# ---------------------------------------------------------------- dispatch
load_wsl_adapter() {
  [ "${WSL_ADAPTER_LOADED:-0}" = 1 ] && return 0
  local path=$0 link
  while [ -L "$path" ]; do
    link=$(readlink "$path") || return 1
    case "$link" in /*) path=$link ;; *) path=$(dirname "$path")/$link ;; esac
  done
  # shellcheck source=scripts/wake-lab-wsl.sh
  . "$(dirname "$path")/wake-lab-wsl.sh" || return 1
  WSL_ADAPTER_LOADED=1
}

prepare_boxes() { # WSL gets its existing concurrent kick; Linux needs nothing after sshd boots.
  local n wsl_boxes=()
  for n in "$@"; do
    if [ "$(kind_of "$n")" = wsl ]; then wsl_boxes+=("$n");
    else echo "linux ready on $n (sshd starts at boot; no holder needed)"; fi
  done
  if [ ${#wsl_boxes[@]} -gt 0 ]; then start_wsl "${wsl_boxes[@]}"; fi
}

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
# a WSL box that has no start to hold is refused after kind validation.
# unhold before load_hosts, and before check_targets: releasing a local pid needs neither the MAC
# table nor the network, and a site file that went missing or unparseable after a lane started
# would otherwise strand the holder it is the only way to end. The cost is that a misspelled box
# reports no holder instead of a typo, which is the right trade for a cleanup command.
if [ "$VERB" = unhold ]; then
  # A missing site file must not strand an existing holder. When it is available, Linux is a
  # no-op and need not even read the WSL adapter.
  [ ! -r "$HOSTS_FILE" ] || . "$HOSTS_FILE"
  for t in "${TARGETS[@]}"; do
    if declare -F kind_of >/dev/null && [ "$(kind_of "$t")" = linux ]; then
      echo "no holder needed for linux box $t"
    else
      load_wsl_adapter || exit 1
      release_hold "$t"
    fi
  done
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
  [ "${HOLD_ANOMALY:-0}" = 1 ] && exit 2
  [ "${HOLD_LEAK:-0}" = 1 ] && exit 3
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
any_wsl=0
for t in "${TARGETS[@]}"; do
  if [ "$(kind_of "$t")" = wsl ]; then any_wsl=1; load_wsl_adapter || exit 1; break; fi
done
if [ "$HOLD" = 1 ] && [ "$any_wsl" = 1 ] && [ "$VERB" != kick-wsl ] &&
   { [ "$VERB" != wake ] || [ "$WANT_WSL" != 1 ] || [ "$WAIT" != 1 ]; }; then
  echo "wake-lab.sh: --hold needs a WSL start to hold" >&2
  echo "  use 'kick-wsl --hold' / 'restart-wsl --hold', or '--wait --wsl --hold' (the wake path" >&2
  echo "  starts WSL only under --wait); end it with 'unhold'." >&2
  exit 1
fi

case "$VERB" in
  status)
    do_status "${TARGETS[@]}"
    ;;
  kick-wsl)
    prepare_boxes "${TARGETS[@]}"; exit $?
    ;;
  sleep|hibernate|down)
    # Only the boxes actually acted on are confirmed: polling a refused box for the DOWN signal
    # would report the holder's live machine as a failure to go down.
    power_phase "$VERB" "${TARGETS[@]}" || exit 1
    ;;
  wake)
    wake_rc=0
    for t in "${TARGETS[@]}"; do echo "$t:"; wake "$t" || wake_rc=1; done
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
        [ ${#UP[@]} -gt 0 ] && { prepare_boxes "${UP[@]}" || wsl_rc=1; }
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
          echo "router lease settles; Wi-Fi-only asus and tuf need manual wake."
        fi
        [ "$wsl_rc" != 0 ] && echo "NOT all up: $WSL_FAILED (see above)"
        exit 1
      fi
    else
      exit "$wake_rc"
    fi
    ;;
esac
