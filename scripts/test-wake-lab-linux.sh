#!/usr/bin/env bash
# Native Linux path: run the core from a directory with no WSL adapter.
set -u
{
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/wake-lab-linux.XXXXXX") || exit 1
tmp=$(CDPATH= cd "$tmp" && pwd -P) || exit 1
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cp "$here/wake-lab.sh" "$tmp/wake-lab.sh"
cat >"$tmp/hosts.sh" <<'HOSTS'
mac_of() { [ "$1" = tuf ] && echo aa:bb:cc:00:00:06; }
eth_mac_of() { return 1; } # TUF is Wi-Fi only, as verified in flotilla PR #3.
ip_of() { [ "$1" = tuf ] && echo 192.0.2.32; }
kind_of() { [ "$1" = tuf ] && echo linux; }
HOSTS
cat >"$tmp/bin/ssh" <<'SSH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SSH_LOG"
case "$*" in
  *systemctl*)
    [ "${SSH_POWER_FAIL:-0}" = 1 ] && { echo 'Access denied' >&2; exit 2; }
    # systemd 259's refusal under --check-inhibitors=yes: the holder is NOT on the last line.
    if [ "${SSH_INHIBITED:-0}" = 1 ]; then
      echo WAKE_LAB_POWER_STARTED
      echo 'Operation inhibited by "fleet-worker" (PID 4242 "systemd-inhibit", user lukstafi), reason is "tuf-amd-linux slot 1 of 1: run".' >&2
      echo 'Please retry operation after closing inhibitors and logging out other users.' >&2
      echo "Alternatively, ignore inhibitors and users with 'systemctl suspend -i'." >&2
      exit 1
    fi
    [ "${SSH_NO_MARKER:-0}" = 1 ] || echo WAKE_LAB_POWER_STARTED
    exit 255 ;; # SSH drops when the machine suspends or shuts down.
  *systemd-inhibit*)
    [ "${SSH_INHIBIT_FAIL:-0}" = 1 ] && exit 1
    printf '%s' "${SSH_INHIBITORS:-}"; exit 0 ;;
esac
case " $* " in
  *' tuf-amd-linux '*) [ "${SSH_UP:-0}" = 1 ] ;;
  *' tuf-amd-win '*) [ "${SSH_UP:-0}" = tuf-amd-win ] ;;
  *' tuf-amd-wsl '*) [ "${SSH_UP:-0}" = tuf-amd-wsl ] ;;
  *' rog-nv-linux '*) [ "${SSH_UP:-0}" = rog-nv-linux ] ;;
  *' rog-nv-win '*) [ "${SSH_UP:-0}" = rog-nv-win ] ;;
  *' rog-nv-wsl '*) [ "${SSH_UP:-0}" = rog-nv-wsl ] ;;
  *) exit 1 ;;
esac
SSH
cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf '<NewActive>1</NewActive>\n'
CURL
cat >"$tmp/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
exit 0
PYTHON
chmod +x "$tmp/bin"/*
# WAKE_LAB_FLEET_WORKER: status reads the execution registry, and this suite must not read the real one.
export PATH="$tmp/bin:$PATH" SSH_LOG="$tmp/ssh.log" WAKE_LAB_HOSTS="$tmp/hosts.sh" WAKE_LAB_LOCK_DIR="$tmp/locks" \
  WAKE_LAB_FLEET_WORKER="$tmp/absent-fleet-worker.sh"
mkdir -p "$WAKE_LAB_LOCK_DIR"
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=$((fail+1)); fi; }
out=$(SSH_UP=1 "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'Linux status reports the reached OS without loading the adapter' '[ "$rc" = 0 ] && [[ "$out" == *"os=linux  linux=UP"* ]] && [[ "$out" != *"Windows Update"* ]]'
check 'Linux status counts no sleep blocks on a box with none' '[[ "$out" == *"sleep-blocks=0"* ]] && [[ "$out" != *"block: "* ]]'
# The real listing's shape (systemd 259, rog-nv-linux): GNOME's handle-* blocks are on every
# logged-in desktop and refuse no power verb, so only the sleep holder may be counted.
listing='fleet-worker 1000 lukstafi 86901 systemd-inhibit sleep:idle                                               tuf-amd-linux slot 1 of 1: bash -c x                        block
lukstafi     1000 lukstafi 6032  gsd-power       handle-lid-switch                                        External monitor attached or configuration changed recently block
lukstafi     1000 lukstafi 6030  gsd-media-keys  handle-power-key:handle-suspend-key:handle-hibernate-key GNOME handling keypresses                                   block
'
out=$(SSH_UP=1 SSH_INHIBITORS="$listing" "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'Linux status shows the live sleep block inhibitor and who holds it' '[ "$rc" = 0 ] && [[ "$out" == *"sleep-blocks=1"* ]] && [[ "$out" == *"block: fleet-worker 1000 lukstafi 86901 systemd-inhibit sleep:idle tuf-amd-linux slot 1 of 1"* ]]'
check '...and leaves out the desktop key and lid blocks that refuse no verb' '[[ "$out" != *"gsd-media-keys"* ]] && [[ "$out" != *"gsd-power"* ]]'
out=$(SSH_UP=1 SSH_INHIBIT_FAIL=1 "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'an unreadable inhibitor listing is unknown, not none' '[ "$rc" = 0 ] && [[ "$out" == *"sleep-blocks=?"* ]]'
# ludics-lite#359: status asks each lab lock's flock, because the text outlives the holder. The
# lane lock is held the way the sweep holds it (a descriptor kept open, flock taken by a perl that
# exits), and `7>&-` keeps status from inheriting it. The hold lock's line names a dead holder.
sl="$tmp/status-locks"; mkdir -p "$sl"
printf 'ocannl sweep 20260924T051741Z (pid 76065, since 20260924T051742Z)\n' >"$sl/tuf.lock"
printf 'wake-lab sleep (pid 63477, since 20260923T220025Z)\n' >"$sl/tuf.hold.lock"
perl -e 'utime time - 93784, time - 93784, $ARGV[0]' "$sl/tuf.hold.lock"
lock_sums=$(cksum "$sl/tuf.lock" "$sl/tuf.hold.lock")
lock_free() { perl -e 'use Fcntl ":flock"; exit(flock(STDIN, LOCK_EX | LOCK_NB) ? 0 : 1)' <"$1"; }
exec 7>>"$sl/tuf.lock"
perl -e 'use Fcntl ":flock"; exit(flock(STDIN, LOCK_EX | LOCK_NB) ? 0 : 1)' <&7; took=$?
check 'control: the suite holds the lane lock' '[ "$took" = 0 ] && ! lock_free "$sl/tuf.lock"'
out=$(WAKE_LAB_LOCK_DIR="$sl" SSH_UP=1 "$tmp/wake-lab.sh" status tuf 7>&- 2>&1); rc=$?
check 'a held lane lock reads held, with its holder line and the age of that line' '[ "$rc" = 0 ] && [[ "$out" == *"lane-lock=held"* ]] && [[ "$out" == *"lane lock: held by ocannl sweep 20260924T051741Z (pid 76065, since 20260924T051742Z) (line written "[0-9]*"s ago)"* ]]'
check 'a free lock with a leftover line reads free, showing the line as stale text with its age' '[[ "$out" == *"hold-lock=free"* ]] && [[ "$out" == *"hold lock: free, stale text (written 1d02h ago): wake-lab sleep (pid 63477, since 20260923T220025Z)"* ]]'
check '...and status left both files as it found them' '[ "$(cksum "$sl/tuf.lock" "$sl/tuf.hold.lock")" = "$lock_sums" ]'
check '...and the lane lock still held by its holder' '! lock_free "$sl/tuf.lock"'
exec 7>&-
out=$(WAKE_LAB_LOCK_DIR="$sl" SSH_UP=1 "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'once its holder lets go, the same lane lock reads free with its line as stale text' '[ "$rc" = 0 ] && [[ "$out" == *"lane-lock=free"* ]] && [[ "$out" == *"lane lock: free, stale text (written "*"ocannl sweep 20260924T051741Z"* ]]'
rm -f "$sl/tuf.lock" "$sl/tuf.hold.lock"
out=$(WAKE_LAB_LOCK_DIR="$sl" SSH_UP=1 "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'with no lock files both locks read free, with no detail line' '[ "$rc" = 0 ] && [[ "$out" == *"lane-lock=free  hold-lock=free"* ]] && [[ "$out" != *" lock: "* ]]'
check '...and status created no lock file' '[ -z "$(ls -A "$sl")" ]'
# The reservations column, from a stub registry reader; `?` whenever the registry was not read.
cat >"$tmp/fleet-worker.sh" <<'FW'
#!/usr/bin/env bash
[ "$*" = "execution list --active --compact" ] || exit 9
printf '%s' "${FW_LISTING-}"; exit "${FW_RC:-0}"
FW
chmod +x "$tmp/fleet-worker.sh"
listing='[{"request_id":"w-359-tuf-1","request":{"execution_host":"tuf-amd-linux"},"state":"launching"},
{"request_id":"w-359-mac","request":{"execution_host":"mac-studio"},"state":"running"},
{"request_id":"w-360-tuf-2","request":{"execution_host":"tuf-amd-linux"},"state":"dispatched"}]'
out=$(WAKE_LAB_FLEET_WORKER="$tmp/fleet-worker.sh" FW_LISTING="$listing" SSH_UP=1 "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'status counts the active reservations naming the box, and lists them' '[ "$rc" = 0 ] && [[ "$out" == *"reservations=2"* ]] && [[ "$out" == *"reservation: w-359-tuf-1 (launching)"* ]] && [[ "$out" == *"reservation: w-360-tuf-2 (dispatched)"* ]] && [[ "$out" != *"w-359-mac"* ]]'
out=$(WAKE_LAB_FLEET_WORKER="$tmp/fleet-worker.sh" FW_LISTING='[]' SSH_UP=1 "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'an empty registry is zero reservations' '[ "$rc" = 0 ] && [[ "$out" == *"reservations=0"* ]] && [[ "$out" != *"reservation: "* ]]'
out=$(WAKE_LAB_FLEET_WORKER="$tmp/fleet-worker.sh" FW_LISTING='[]' FW_RC=4 SSH_UP=1 "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'an unreachable registry is unknown, not zero' '[ "$rc" = 0 ] && [[ "$out" == *"reservations=?"* ]]'
out=$(WAKE_LAB_FLEET_WORKER="$tmp/fleet-worker.sh" FW_LISTING='EXECUTION REFUSED' SSH_UP=1 "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'a registry listing that is not a JSON list is unknown, not zero' '[ "$rc" = 0 ] && [[ "$out" == *"reservations=?"* ]]'
out=$(SSH_UP=1 "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'a missing registry reader is unknown, not zero' '[ "$rc" = 0 ] && [[ "$out" == *"reservations=?"* ]]'
out=$(SSH_UP=tuf-amd-win "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'Linux-configured TUF reports an alternate Windows boot' '[ "$rc" = 0 ] && [[ "$out" == *"os=windows"* ]]'
out=$(SSH_UP=tuf-amd-wsl "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'Linux-configured TUF reports an alternate WSL guest' '[ "$rc" = 0 ] && [[ "$out" == *"os=wsl"* ]]'
cat >"$tmp/rog-hosts.sh" <<'HOSTS'
mac_of() { [ "$1" = rog ] && echo aa:bb:cc:00:00:02; }
eth_mac_of() { mac_of "$1"; }
ip_of() { [ "$1" = rog ] && echo 192.0.2.30; }
kind_of() { [ "$1" = rog ] && echo linux; }
HOSTS
out=$(WAKE_LAB_HOSTS="$tmp/rog-hosts.sh" SSH_UP=rog-nv-win "$tmp/wake-lab.sh" status rog 2>&1); rc=$?
check 'Linux-configured dual boot reports Windows when Windows answered' '[ "$rc" = 0 ] && [[ "$out" == *"os=windows"* ]]'
out=$(WAKE_LAB_HOSTS="$tmp/rog-hosts.sh" SSH_UP=rog-nv-wsl "$tmp/wake-lab.sh" status rog 2>&1); rc=$?
check 'Linux-configured dual boot reports WSL when its guest answered' '[ "$rc" = 0 ] && [[ "$out" == *"os=wsl"* ]]'
# ludics-lite#320: a bare `status` is a read of the whole lab, so it shows tuf -- Wi-Fi only and
# woken by hand, often the one box awake -- beside rog and minix. The bare WAKE keeps `rog minix`:
# tuf cannot be woken over Wi-Fi, so defaulting a wake to it would only print manual-wake guidance.
cat >"$tmp/lab-hosts.sh" <<'HOSTS'
mac_of() { case "$1" in rog) echo aa:bb:cc:00:00:02 ;; minix) echo aa:bb:cc:00:00:03 ;; tuf) echo aa:bb:cc:00:00:06 ;; *) return 1 ;; esac; }
eth_mac_of() { case "$1" in rog|minix) mac_of "$1" ;; *) return 1 ;; esac; }
ip_of() { case "$1" in rog) echo 192.0.2.30 ;; minix) echo 192.0.2.31 ;; tuf) echo 192.0.2.32 ;; *) return 1 ;; esac; }
kind_of() { case "$1" in rog|minix|tuf) echo linux ;; *) return 1 ;; esac; }
HOSTS
out=$(WAKE_LAB_HOSTS="$tmp/lab-hosts.sh" SSH_UP=1 "$tmp/wake-lab.sh" status 2>&1); rc=$?
check 'bare status reads all three boxes, tuf included' '[ "$rc" = 0 ] && [[ "$out" == *"
rog "*"os=--"* ]] && [[ "$out" == *"
minix "*"os=--"* ]] && [[ "$out" == *"
tuf "*"os=linux  linux=UP"* ]]'
: >"$SSH_LOG"
out=$(WAKE_LAB_HOSTS="$tmp/lab-hosts.sh" "$tmp/wake-lab.sh" 2>&1); rc=$?
check 'bare wake still defaults to rog minix, never the manual-wake tuf' '[ "$rc" = 0 ] && [[ "$out" == *"rog:"* ]] && [[ "$out" == *"minix:"* ]] && [[ "$out" != *"tuf:"* ]] && [[ "$out" != *"wake it manually"* ]]'
out=$("$tmp/wake-lab.sh" status 2>&1); rc=$?
check 'bare status over a table that does not know rog and minix refuses rather than shrinking' '[ "$rc" = 1 ] && [[ "$out" == *"not in the host table"*"rog minix"* ]]'
out=$("$tmp/wake-lab.sh" unhold tuf 2>&1); rc=$?
check 'Linux unhold is a no-op without the adapter' '[ "$rc" = 0 ] && [[ "$out" == *"no holder needed"* ]]'
out=$("$tmp/wake-lab.sh" tuf 2>&1); rc=$?
check 'Wi-Fi-only TUF refuses WoL with manual-wake guidance' '[ "$rc" = 1 ] && [[ "$out" == *"wake it manually"* ]]'
: >"$SSH_LOG"
out=$(SSH_UP=1 WAKE_LAB_WAIT_SECONDS=1 "$tmp/wake-lab.sh" --wait --wsl --hold tuf 2>&1); rc=$?
check 'Linux wait needs no WSL kick or holder and explains manual wake' '[ "$rc" = 0 ] && [[ "$out" == *"all up"* ]] && [[ "$out" == *"no holder needed"* ]] && [[ "$out" == *"wake it manually"* ]] && ! grep -q wsl.exe "$SSH_LOG"'
: >"$SSH_LOG"
out=$(SSH_UP=0 WAKE_LAB_DOWN_WAIT_SECONDS=0 "$tmp/wake-lab.sh" sleep tuf 2>&1); rc=$?
check 'Linux sleep uses inhibitor-aware systemctl under both lab locks' '[ "$rc" = 0 ] && grep -q -- "--check-inhibitors=yes suspend" "$SSH_LOG" && [ -e "$WAKE_LAB_LOCK_DIR/tuf.lock" ] && [ -e "$WAKE_LAB_LOCK_DIR/tuf.hold.lock" ]'
out=$(SSH_UP=0 WAKE_LAB_DOWN_WAIT_SECONDS=0 "$tmp/wake-lab.sh" hibernate tuf 2>&1); rc=$?
check 'Linux hibernate uses systemctl' '[ "$rc" = 0 ] && grep -q "systemctl --no-ask-password hibernate" "$SSH_LOG"'
out=$(SSH_UP=0 WAKE_LAB_DOWN_WAIT_SECONDS=0 "$tmp/wake-lab.sh" down tuf 2>&1); rc=$?
check 'Linux shutdown uses systemctl' '[ "$rc" = 0 ] && grep -q "systemctl --no-ask-password poweroff" "$SSH_LOG"'
out=$(SSH_POWER_FAIL=1 SSH_UP=1 WAKE_LAB_DOWN_WAIT_SECONDS=0 "$tmp/wake-lab.sh" sleep tuf 2>&1); rc=$?
check 'definite Linux power refusal is visible and fails immediately' '[ "$rc" = 1 ] && [[ "$out" == *"sleep FAILED on tuf"* ]] && [[ "$out" != *"confirming..."* ]]'
out=$(SSH_INHIBITED=1 SSH_UP=1 WAKE_LAB_DOWN_WAIT_SECONDS=0 "$tmp/wake-lab.sh" sleep tuf 2>&1); rc=$?
check 'a sleep refused by a block inhibitor names the holder and is a refusal' '[ "$rc" = 1 ] && [[ "$out" == *"Operation inhibited by \"fleet-worker\""* ]] && [[ "$out" == *"sleep REFUSED on tuf by a block inhibitor"* ]] && [[ "$out" != *"confirming..."* ]]'
out=$(SSH_NO_MARKER=1 SSH_UP=1 WAKE_LAB_DOWN_WAIT_SECONDS=0 "$tmp/wake-lab.sh" sleep tuf 2>&1); rc=$?
check 'SSH disconnect before the command marker is a failure' '[ "$rc" = 1 ] && [[ "$out" == *"before the remote power command started"* ]] && [[ "$out" != *"confirming..."* ]]'
out=$(WAKE_LAB_HOSTS="$tmp/rog-hosts.sh" SSH_NO_MARKER=1 SSH_UP=rog-nv-win WAKE_LAB_DOWN_WAIT_SECONDS=0 "$tmp/wake-lab.sh" sleep rog 2>&1); rc=$?
check 'a Linux-configured box booted into Windows cannot report successful sleep' '[ "$rc" = 1 ] && [[ "$out" == *"before the remote power command started"* ]]'
cp "$here/wake-lab-wsl.sh" "$tmp/wake-lab-wsl.sh"
sed 's/echo linux/echo wsl/' "$tmp/hosts.sh" >"$tmp/tuf-wsl.sh"
out=$(WAKE_LAB_HOSTS="$tmp/tuf-wsl.sh" SSH_UP=tuf-amd-win "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'the renamed TUF keeps its Windows endpoint when configured for WSL' '[ "$rc" = 0 ] && [[ "$out" == *"win=UP"* ]] && [[ "$out" == *"wsl=--"* ]] && [[ "$out" == *"os=windows"* ]]'
out=$(WAKE_LAB_HOSTS="$tmp/tuf-wsl.sh" SSH_UP=tuf-amd-wsl "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'TUF WSL status requires a responding guest' '[ "$rc" = 0 ] && [[ "$out" == *"wsl=UP"* ]] && [[ "$out" == *"os=wsl"* ]]'
out=$(WAKE_LAB_HOSTS="$tmp/tuf-wsl.sh" SSH_UP=tuf-amd-win WAKE_LAB_WSL_WAIT_SECONDS=0 "$tmp/wake-lab.sh" kick-wsl tuf 2>&1); rc=$?
check 'TUF kick cannot report WSL up without its guest endpoint answering' '[ "$rc" != 0 ] && [[ "$out" == *"wsl still down"* ]] && [[ "$out" != *"wsl up"* ]]'
mkdir "$tmp/no-guest"
cp "$tmp/wake-lab.sh" "$tmp/no-guest/wake-lab.sh"
sed '/tuf) echo tuf-amd-wsl ;;/d' "$tmp/wake-lab-wsl.sh" >"$tmp/no-guest/wake-lab-wsl.sh"
out=$(WAKE_LAB_HOSTS="$tmp/tuf-wsl.sh" SSH_UP=tuf-amd-win "$tmp/no-guest/wake-lab.sh" status tuf 2>&1); rc=$?
check 'WSL kind refuses an adapter without a guest endpoint' '[ "$rc" = 1 ] && [[ "$out" == *"no WSL guest ssh endpoint for tuf"* ]]'
cat >"$tmp/other-linux.sh" <<'HOSTS'
mac_of() { [ "$1" = other ] && echo aa:bb:cc:00:00:05; }
eth_mac_of() { return 1; }
ip_of() { [ "$1" = other ] && echo 192.0.2.29; }
kind_of() { [ "$1" = other ] && echo linux; }
HOSTS
out=$(WAKE_LAB_HOSTS="$tmp/other-linux.sh" "$tmp/wake-lab.sh" status other 2>&1); rc=$?
check 'Linux kind without a native ssh endpoint is refused' '[ "$rc" = 1 ] && [[ "$out" == *"no linux ssh endpoint for other"* ]]'
sed 's/echo linux/echo wsl/' "$tmp/other-linux.sh" >"$tmp/other-wsl.sh"
out=$(WAKE_LAB_HOSTS="$tmp/other-wsl.sh" "$tmp/wake-lab.sh" status other 2>&1); rc=$?
check 'WSL kind without a Windows ssh endpoint is refused' '[ "$rc" = 1 ] && [[ "$out" == *"no Windows ssh endpoint for other"* ]]'
sed 's/echo linux/echo unknown/' "$tmp/hosts.sh" >"$tmp/bad.sh"
out=$(WAKE_LAB_HOSTS="$tmp/bad.sh" "$tmp/wake-lab.sh" tuf 2>&1); rc=$?
check 'invalid kind refuses before WoL' '[ "$rc" = 1 ] && [[ "$out" == *"invalid kind for tuf"* ]]'
[ "$fail" -eq 0 ]
exit "$?"
}
