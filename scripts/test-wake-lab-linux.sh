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
  *) for a in "$@"; do [ "$a" = "${SSH_UP:-}" ] && exit 0; done; exit 1 ;;
esac
SSH
# The router and the magic packet log to the same file as ssh, so an empty log is "nothing sent".
cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >>"$SSH_LOG"
printf '<NewActive>1</NewActive>\n'
CURL
cat >"$tmp/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
printf 'python3 %s\n' "$*" >>"$SSH_LOG"
exit 0
PYTHON
chmod +x "$tmp/bin"/*
export PATH="$tmp/bin:$PATH" SSH_LOG="$tmp/ssh.log" WAKE_LAB_HOSTS="$tmp/hosts.sh" WAKE_LAB_LOCK_DIR="$tmp/locks"
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
# ludics-lite#314: every alias comes from ONE endpoint map, and an incomplete row is refused before
# anything is sent -- whatever the box's kind, since a Linux-configured dual-boot box still probes
# its Windows endpoints in status. tuf's row without its guest alias is the first review finding on
# the asus -> tuf rename (PR #313): its Windows endpoint then passed WSL validation with no guest.
mkdir "$tmp/no-guest"
cp "$tmp/wake-lab-wsl.sh" "$tmp/no-guest/wake-lab-wsl.sh"
sed 's/ wsl=tuf-amd-wsl//' "$tmp/wake-lab.sh" >"$tmp/no-guest/wake-lab.sh"; chmod +x "$tmp/no-guest/wake-lab.sh"
check 'the fixture really took the guest alias out of the map' '! cmp -s "$tmp/wake-lab.sh" "$tmp/no-guest/wake-lab.sh"'
out=$(WAKE_LAB_HOSTS="$tmp/tuf-wsl.sh" SSH_UP=tuf-amd-win "$tmp/no-guest/wake-lab.sh" status tuf 2>&1); rc=$?
check 'WSL kind refuses a map row without a guest endpoint' '[ "$rc" = 1 ] && [[ "$out" == *"a Windows endpoint (tuf-amd-win) with no WSL guest alias"* ]]'
: >"$SSH_LOG"; rm -f "$WAKE_LAB_LOCK_DIR/tuf.lock" "$WAKE_LAB_LOCK_DIR/tuf.hold.lock"
out=$(SSH_UP=1 WAKE_LAB_DOWN_WAIT_SECONDS=0 "$tmp/no-guest/wake-lab.sh" sleep tuf 2>&1); rc=$?
check '...and so does Linux kind, before any power operation or lock' '[ "$rc" = 1 ] && [[ "$out" == *"no WSL guest alias"*"nothing was sent"* ]] && [ ! -s "$SSH_LOG" ] && [ ! -e "$WAKE_LAB_LOCK_DIR/tuf.lock" ]'
# A NEWLY ADDED dual-boot box, `nova`, is one row in the map plus its site entries. With a complete
# row, status finds its alternate boots from that row alone -- the second #313 finding was a status
# whose Windows probe listed the box names by hand, and so skipped the renamed box.
cat >"$tmp/nova-hosts.sh" <<'HOSTS'
mac_of() { [ "$1" = nova ] && echo aa:bb:cc:00:00:07; }
eth_mac_of() { mac_of "$1"; }
ip_of() { [ "$1" = nova ] && echo 192.0.2.33; }
kind_of() { [ "$1" = nova ] && echo linux; }
HOSTS
nova_map() { # nova_map <dir> <row> -- a copy of the scripts whose endpoint map also lists nova
  mkdir -p "$tmp/$1"
  cp "$tmp/wake-lab-wsl.sh" "$tmp/$1/wake-lab-wsl.sh"
  awk -v row="  nova) echo $2 ;;" '{ print } /^  tuf\) +echo linux=/ { print row }' \
    "$tmp/wake-lab.sh" >"$tmp/$1/wake-lab.sh"
  chmod +x "$tmp/$1/wake-lab.sh"
  grep -qF "  nova) echo $2 ;;" "$tmp/$1/wake-lab.sh"
}
check 'the added-box fixture inserts its row into the map' 'nova_map nova "linux=nova-x-linux win=nova-x-win wsl=nova-x-wsl lan=nova-lan"'
out=$(WAKE_LAB_HOSTS="$tmp/nova-hosts.sh" SSH_UP=nova-x-linux "$tmp/nova/wake-lab.sh" status nova 2>&1); rc=$?
check 'an added box answers on the Linux endpoint of its row' '[ "$rc" = 0 ] && [[ "$out" == *"nova "*"os=linux  linux=UP"* ]]'
out=$(WAKE_LAB_HOSTS="$tmp/nova-hosts.sh" SSH_UP=nova-x-win "$tmp/nova/wake-lab.sh" status nova 2>&1); rc=$?
check '...and status probes its alternate Windows boot from the row' '[ "$rc" = 0 ] && [[ "$out" == *"os=windows  linux=--  win=UP"* ]]'
out=$(WAKE_LAB_HOSTS="$tmp/nova-hosts.sh" SSH_UP=nova-x-wsl "$tmp/nova/wake-lab.sh" status nova 2>&1); rc=$?
check '...and its alternate WSL guest' '[ "$rc" = 0 ] && [[ "$out" == *"os=wsl  linux=--  wsl=UP"* ]]'
sed 's/echo linux/echo wsl/' "$tmp/nova-hosts.sh" >"$tmp/nova-wsl.sh"
out=$(WAKE_LAB_HOSTS="$tmp/nova-wsl.sh" SSH_UP=nova-lan "$tmp/nova/wake-lab.sh" status nova 2>&1); rc=$?
check '...and, set to WSL, its LAN route' '[ "$rc" = 0 ] && [[ "$out" == *"lan=UP  win=--  wsl=--"*"os=windows"* ]]'
# Each way the row can be incomplete, as an addition or a half-done rename leaves it. Every one is
# refused, says what is wrong, and sends nothing: no router query, no packet, no ssh, no lock.
n=0
while IFS='|' read -r row want; do
  n=$((n + 1))
  if ! nova_map "nova-bad-$n" "$row"; then check "incomplete-row fixture $n was inserted" false; continue; fi
  for verb in '' sleep; do   # '' is the bare wake, which has no verb word
    : >"$SSH_LOG"; rm -f "$WAKE_LAB_LOCK_DIR/nova.lock" "$WAKE_LAB_LOCK_DIR/nova.hold.lock"
    out=$(WAKE_LAB_HOSTS="$tmp/nova-hosts.sh" SSH_UP=nova-x-linux WAKE_LAB_DOWN_WAIT_SECONDS=0 \
      "$tmp/nova-bad-$n/wake-lab.sh" ${verb:+"$verb"} nova 2>&1); rc=$?
    check "an added box whose row has $want is refused before ${verb:-wake} sends anything" \
      '[ "$rc" = 1 ] && [[ "$out" == *"incomplete ssh endpoints for nova"*"$want"*"nothing was sent"* ]] && [ ! -s "$SSH_LOG" ] && [ ! -e "$WAKE_LAB_LOCK_DIR/nova.lock" ]'
  done
done <<'ROWS'
linux=nova-x-linux win=nova-x-win|a Windows endpoint (nova-x-win) with no WSL guest alias
linux=nova-x-linux wsl=nova-x-wsl|a WSL guest (nova-x-wsl) with no Windows host
linux=nova-x-linux lan=nova-lan|a LAN route (nova-lan) with no Windows endpoint
linux=nova-x-linux win=nova-x-win wsl=nova-x-wsl lan=tuf-lan|the LAN route tuf-lan is not nova-lan
linux=nova-x-linux win=tuf-amd-win wsl=nova-x-wsl|tuf-amd-win does not share the stem nova-x
linux=nova-x-linux win=nova-x-win wsl=nova-x-guest|nova-x-guest does not end in -wsl
linux=nova-x-linux wn=nova-x-win|unknown endpoint wn
linux=nova-x-linux linux=nova-y-linux|linux is listed twice
win=nova-x-win wsl=nova-x-wsl|no linux ssh endpoint for a linux box
ROWS
check 'every incomplete-row fixture ran' '[ "$n" = 9 ]'
cat >"$tmp/other-linux.sh" <<'HOSTS'
mac_of() { [ "$1" = other ] && echo aa:bb:cc:00:00:05; }
eth_mac_of() { return 1; }
ip_of() { [ "$1" = other ] && echo 192.0.2.29; }
kind_of() { [ "$1" = other ] && echo linux; }
HOSTS
out=$(WAKE_LAB_HOSTS="$tmp/other-linux.sh" "$tmp/wake-lab.sh" status other 2>&1); rc=$?
check 'a box the site table knows and the endpoint map does not is refused' '[ "$rc" = 1 ] && [[ "$out" == *"no ssh endpoints for other"* ]]'
sed 's/echo linux/echo wsl/' "$tmp/other-linux.sh" >"$tmp/other-wsl.sh"
out=$(WAKE_LAB_HOSTS="$tmp/other-wsl.sh" "$tmp/wake-lab.sh" status other 2>&1); rc=$?
check '...whatever its kind' '[ "$rc" = 1 ] && [[ "$out" == *"no ssh endpoints for other"* ]]'
sed 's/echo linux/echo unknown/' "$tmp/hosts.sh" >"$tmp/bad.sh"
out=$(WAKE_LAB_HOSTS="$tmp/bad.sh" "$tmp/wake-lab.sh" tuf 2>&1); rc=$?
check 'invalid kind refuses before WoL' '[ "$rc" = 1 ] && [[ "$out" == *"invalid kind for tuf"* ]]'
[ "$fail" -eq 0 ]
exit "$?"
}
