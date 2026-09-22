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
    exit 255 ;; # SSH drops when the machine suspends or shuts down.
esac
case " $* " in
  *' tuf-amd-linux '*) [ "${SSH_UP:-0}" = 1 ] ;;
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
export PATH="$tmp/bin:$PATH" SSH_LOG="$tmp/ssh.log" WAKE_LAB_HOSTS="$tmp/hosts.sh" WAKE_LAB_LOCK_DIR="$tmp/locks"
mkdir -p "$WAKE_LAB_LOCK_DIR"
fail=0
check() { if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; fail=$((fail+1)); fi; }
out=$(SSH_UP=1 "$tmp/wake-lab.sh" status tuf 2>&1); rc=$?
check 'Linux status reports the reached OS without loading the adapter' '[ "$rc" = 0 ] && [[ "$out" == *"os=linux  linux=UP"* ]] && [[ "$out" != *"Windows Update"* ]]'
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
sed 's/echo linux/echo unknown/' "$tmp/hosts.sh" >"$tmp/bad.sh"
out=$(WAKE_LAB_HOSTS="$tmp/bad.sh" "$tmp/wake-lab.sh" tuf 2>&1); rc=$?
check 'invalid kind refuses before WoL' '[ "$rc" = 1 ] && [[ "$out" == *"invalid kind for tuf"* ]]'
[ "$fail" -eq 0 ]
exit "$?"
}
