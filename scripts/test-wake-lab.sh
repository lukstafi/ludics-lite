#!/usr/bin/env bash
# Exercises wake-lab.sh with shim `curl`/`python3`/`ssh` on PATH -- no router, no network, no
# ssh. What it pins is what ludics-lite#31 split the script into: the tracked half (the lore, the
# router endpoints, the aliases, the dispatch) must carry no hardware addresses, and the untracked
# half (~/.config/wake-lab/hosts.sh) must be what every MAC actually comes from. It also pins the
# `--help` range, which used to be the hard-coded `2,20p` that silently truncated a grown header.
#
# Usage: test-wake-lab.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail
# Feed captured assertions with here-strings: early-exiting grep must not SIGPIPE a writer.

HERE=$(cd "$(dirname "$0")" && pwd)
WL="$HERE/wake-lab.sh"
EXAMPLE="$HERE/wake-lab-hosts.example.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wake-lab-test.XXXXXX") || exit 1
# Physical path, for the same reason the other suites resolve theirs: on macOS $TMPDIR is under
# /var, a symlink to /private/var, so an unresolved $TMP and the path wake-lab.sh prints for the
# same directory are spelled differently and a comparison quietly stops matching
# (ludics-lite#208).
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
trap 'rm -rf "$TMP"' EXIT

# The lab lock directory, for the WHOLE suite and not merely the cases that are about locking.
# Every `restart-wsl` here reserves its box for real, so without this the suite takes flocks under
# the developer's own ~/.local/state/wake-lab -- writing lock files into $HOME, blocking a genuine
# sweep or wake-lab run for as long as a case holds one, and (since a wedged case's orphaned `ssh`
# inherits the descriptor) leaving one held for minutes after the suite exits. Two suite runs
# overlapping then fight over the real lab's locks and fail each other's restart cases, which is
# how this was found. Exported, so every invocation below inherits it whether or not it passes
# `env`.
LOCKS="$TMP/locks"; mkdir -p "$LOCKS"
WAKE_LAB_LOCK_DIR="$LOCKS"; export WAKE_LAB_LOCK_DIR

# ...and the control that the export above is really doing it. The redirection is one variable
# deep: a case that builds its own environment with `env -i`, or an explicit `env` list that drops
# this name, falls back to the real lab's directory and reserves the real lab, with nothing going
# red. So fingerprint that directory before any case runs and compare it afterwards. Contents and
# not merely names, because the hazard includes a lock file that is ALREADY there: taking a lock
# rewrites its holder line, which a listing of names would not show.
REAL_LOCK_DIR="$HOME/.local/state/wake-lab"
lock_dir_state() { # lock_dir_state <dir> -- a printable fingerprint of what that directory holds
  [ -d "$1" ] || { printf '(absent)\n'; return 0; }
  ( cd "$1" && ls -A 2>/dev/null | sort | while IFS= read -r f; do
      if [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum <"$f" 2>/dev/null)"
      else printf '%s (not a regular file)\n' "$f"; fi
    done )
}
REAL_LOCK_BEFORE=$(lock_dir_state "$REAL_LOCK_DIR")

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS: $*"; }
ko() { fail=$((fail + 1)); echo "FAIL: $*"; }
# expect <label> <want-rc> <want-substring> -- <cmd...>; leaves the output in $out.
expect() {
  local label="$1" want_rc="$2" want="$3"; shift 3; [ "$1" = -- ] && shift
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -q -- "$want" <<<"$out"; then ok "$label"
  else ko "$label (rc=$rc want $want_rc; want /$want/) -- $out"; fi
}

# lock_holders <diff> -- the holder line of each lock file the diff names, one per line.
# The diff says a file is new or changed but not by whom, and the two readings of that call for
# opposite responses: a case that escaped WAKE_LAB_LOCK_DIR is a bug in this suite to fix, while
# a genuine cross-machine sweep that reserved a box mid-run is the lab working correctly and the
# suite merely watching. wake-lab's `lab_lock_take_fd` already writes WHO took the lock on its
# first line -- `wake-lab <what> (pid <n>, since <utc>)` -- so print that beside the diff and
# reading it stops being a manual `cat` after the fact. The suite's own pid goes in the message
# for the comparison: its cases run as its children, so a holder pid near it and gone is this
# suite escaping, while a stranger's is the sweep. Only the files the diff names, so a busy lab
# does not bury the diff. Control characters go, and a missing or empty line degrades rather than
# failing, both as `lab_lock_holder` does -- this text goes to a terminal, and a lock a sweep is
# mid-write on has no first line yet.
lock_holders() {
  sed -n 's/^> \([^ ][^ ]*\).*/\1/p' <<<"$1" | sort -u | while IFS= read -r f; do
    local line; line=$(head -1 "$REAL_LOCK_DIR/$f" 2>/dev/null | tr -d '\000-\037')
    printf '\n  %s: %s' "$f" "${line:-(no holder line)}"
  done
}

# lab_untouched <region> -- the real lab's lock directory is exactly as the suite found it.
# Called after the cases that reserve and again at the end, so a failure names a region rather
# than the whole file.
lab_untouched() {
  local now; now=$(lock_dir_state "$REAL_LOCK_DIR")
  if [ "$now" = "$REAL_LOCK_BEFORE" ]; then
    ok "the real lab's lock directory is untouched ($1)"
  else
    local d; d=$(diff <(printf '%s\n' "$REAL_LOCK_BEFORE") <(printf '%s\n' "$now") | sed -n '1,10p')
    ko "$1 reached $REAL_LOCK_DIR: a case escaped WAKE_LAB_LOCK_DIR and reserved the real lab \
(this suite is pid $$) -- $d$(lock_holders "$d")"
  fi
}

# --- the hermeticity control is itself controlled -----------------------------------------------
# A fingerprint that cannot notice anything would pass with the export deleted, and then the two
# `lab_untouched` calls below would be decoration. Prove it notices both shapes of the hazard --
# a lock file that was not there before, and a lock file that was there and has been taken since
# (same name, rewritten holder line) -- and that it tells a missing directory from an empty one,
# which is the shape of a suite that creates the directory on a machine that had none.
probe="$TMP/lockprobe"; mkdir -p "$probe"; printf 'wake-lab restart (pid 1)\n' > "$probe/rog.lock"
probe_before=$(lock_dir_state "$probe")
printf 'wake-lab restart (pid 2)\n' > "$probe/rog.lock"
[ "$(lock_dir_state "$probe")" != "$probe_before" ] \
  && ok "the lock-directory fingerprint notices a lock that has been retaken" \
  || ko "the fingerprint cannot see a rewritten holder line, so lab_untouched proves nothing"
printf 'wake-lab restart (pid 1)\n' > "$probe/rog.lock"      # back to the fingerprinted content
[ "$(lock_dir_state "$probe")" = "$probe_before" ] \
  && ok "...and is stable when nothing has changed" \
  || ko "the fingerprint differs from itself over an unchanged directory: it would cry wolf"
: > "$probe/minix.lock"
[ "$(lock_dir_state "$probe")" != "$probe_before" ] \
  && ok "...and notices a lock file that was not there before" \
  || ko "the fingerprint cannot see a new lock file, so lab_untouched proves nothing"
[ "$(lock_dir_state "$TMP/never-created")" = "(absent)" ] && [ "$(lock_dir_state "$probe")" != "(absent)" ] \
  && ok "...and tells a directory that does not exist from one that does" \
  || ko "the fingerprint cannot tell a missing lock directory from a present one"

# And that the directory it watches is the one wake-lab.sh would fall back to: a guard aimed at
# some other path is vacuous however sharp its fingerprint. `lock-path` only prints, so asking
# with the variable unset creates nothing.
out=$(env -u WAKE_LAB_LOCK_DIR WAKE_LAB_HOSTS="$TMP/absent.sh" "$WL" lock-path minix 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "$REAL_LOCK_DIR/minix.lock" ] \
  && ok "the guarded directory is the one wake-lab falls back to with no WAKE_LAB_LOCK_DIR" \
  || ko "wake-lab's default lock path is not under $REAL_LOCK_DIR (rc=$rc) -- $out; the guard watches the wrong directory"

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
# is, which is what the polling deadlines have to survive. $SSH_DOWN_AFTER (with $SSH_DOWN_LIST
# naming a scratch file) makes a destination go unreachable partway through a run. $SSH_REFUSE
# names a command substring
# that fails even on a reachable destination: a Windows host that answers ssh but whose
# `wsl.exe --shutdown` fails, say. $SSH_HANG is an extended regex over the whole `<dest> :: <cmd>`
# line, and a match WEDGES instead of answering -- the 2026-09-16 shape, where the far side
# accepts the connection and the remote command never returns, which ConnectTimeout does not bound
# and only the script's own cap can end. A regex rather than a substring because the cases below
# need to wedge one box's Windows aliases while leaving its guest and its neighbour answering. It
# is an `exec sleep`, not a `sleep`, so that the cap's SIGALRM lands on the sleeping process itself
# rather than on a shell waiting for a foreground child.
# Three commands also have OUTPUT the script reads, and only a reachable destination produces it:
# $SSH_TASKLIST is what `tasklist` prints (empty -- the default -- is a Windows side holding no
# wsl.exe at all), $SSH_REG is what `reg query` prints, and $SSH_HOLD_LIFE is how many seconds the
# `sleep infinity` holder stays alive here, so that `unhold` can be shown killing a LIVE process
# rather than reaping one the shim had already let exit. That sleep runs as a background job with
# a TERM trap, because a non-interactive bash defers a signal until its FOREGROUND child returns
# -- which would make every holder here outlive the kill a real ssh client obeys at once.
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
line=$(printf '%s ::%s' "$dest" "$cmd")
printf '%s\n' "$line" >> "$SSH_LOG"
# $LOCK_PROBE names a lock file to test AT THE MOMENT each remote command is issued, which is the
# only way to observe from outside whether a reservation really spans what it claims to. A
# restarter that merely probed the lock leaves it free by the time the shutdown lands; a power
# phase that releases at `power_action` leaves it free by the time the confirmation polls. Both
# read as HELD if the reservation is right and FREE if it is not, and neither is visible from
# inside the script.
if [ -n "${LOCK_PROBE:-}" ]; then
  if perl -e 'use Fcntl ":flock"; exit(flock(STDIN, LOCK_EX | LOCK_NB) ? 0 : 1)' \
       <"$LOCK_PROBE" 2>/dev/null
  then printf 'lock FREE during%s\n' "$cmd" >> "$SSH_LOG"
  else printf 'lock HELD during%s\n' "$cmd" >> "$SSH_LOG"; fi
fi
[ -n "${SSH_DELAY:-}" ] && sleep "$SSH_DELAY"
[ -n "${SSH_HANG:-}" ] && grep -qE "$SSH_HANG" <<<"$line" && exec sleep 900
# $SSH_DOWN_AFTER is "<regex>|<dest>": once a line matching the regex has been handled, that
# destination is unreachable for every later command -- an alias that dies mid-run, which is how a
# cleanup ends up on an endpoint the start went out on and nothing answers any more.
down_list=${SSH_DOWN_LIST:-/dev/null}
[ -s "$down_list" ] && grep -qx "$dest" "$down_list" && exit 1
if [ -n "${SSH_DOWN_AFTER:-}" ]; then
  case "$SSH_DOWN_AFTER" in *"|"*)
    grep -qE "${SSH_DOWN_AFTER%%|*}" <<<"$line" && printf '%s\n' "${SSH_DOWN_AFTER##*|}" >> "$down_list" ;;
  esac
fi
case "$cmd" in *"${SSH_REFUSE:-}"*) [ -n "${SSH_REFUSE:-}" ] && exit 1 ;; esac
up=1
for u in ${SSH_UP:-}; do [ "$u" = "$dest" ] && up=0; done
if [ "$up" = 0 ]; then
  case "$cmd" in
    *tasklist*)          printf '%s\n' "${SSH_TASKLIST:-}" ;;
    *"reg query"*)       printf '%s\n' "${SSH_REG:-}" ;;
    # The trap takes the NAP with it, the way wake-lab's own `capped` watchdog does: a shim holder
    # that exits leaving its sleep behind leaves a child holding every descriptor it inherited --
    # including the box's lab lock, which would then outlive the `unhold` that killed the holder.
    *"sleep infinity"*)  trap 'printf "HOLDER-TERMED %s\n" "$$" >> "$SSH_LOG"; kill -KILL $(jobs -p) 2>/dev/null; exit 143' TERM
                         sleep "${SSH_HOLD_LIFE:-0}" & wait ;;
  esac
fi
exit "$up"
EOF
chmod +x "$TMP/bin/curl" "$TMP/bin/python3" "$TMP/bin/ssh"
PATH="$TMP/bin:$PATH"; export PATH
CURL_LOG="$TMP/curl.log"; export CURL_LOG
SSH_LOG="$TMP/ssh.log"; export SSH_LOG
SSH_DOWN_LIST="$TMP/ssh-down.list"; export SSH_DOWN_LIST
# Every run in this suite gets a scratch lab-lock directory, exported once here rather than passed
# case by case. A case that forgot it would take the REAL lock under ~/.local/state/wake-lab --
# and a `--hold` case leaves a holder carrying that lock, which would then refuse every later
# restart in the suite and, worse, on the machine running it. Cases that need their own lock
# directory (the lab-lock block below) override it.
WAKE_LAB_LOCK_DIR="$TMP/labtest-locks"; export WAKE_LAB_LOCK_DIR
mkdir -p "$WAKE_LAB_LOCK_DIR"
: > "$CURL_LOG"; : > "$SSH_LOG"

# A host table with obviously fake addresses, in the shape the example file documents.
cat > "$TMP/hosts.sh" <<'EOF'
mac_of() { case "$1" in
  rog)   echo aa:bb:cc:00:00:01 aa:bb:cc:00:00:02 ;;
  minix) echo aa:bb:cc:00:00:03 aa:bb:cc:00:00:04 ;;
  *) return 1 ;; esac; }
eth_mac_of() { case "$1" in
  rog)   echo aa:bb:cc:00:00:02 ;;
  minix) echo aa:bb:cc:00:00:04 ;;
  *) return 1 ;; esac; }
ip_of() { case "$1" in
  rog)   echo 10.0.0.1 ;;
  minix) echo 10.0.0.2 ;;
  *) return 1 ;; esac; }
EOF

# --- the site file is required, and is the only source of hardware addresses -------------------
: > "$CURL_LOG"
expect "a missing host table refuses, naming the path it looked at" 1 "no host table at $TMP/absent.sh" -- \
  env WAKE_LAB_HOSTS="$TMP/absent.sh" "$WL" status rog
grep -q 'wake-lab-hosts.example.sh' <<<"$out" \
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
grep -q 'aa:bb:cc:00:00:01' <<<"$out" \
  && ok "...including the Wi-Fi one" || ko "the first MAC never reached the router -- $out"
grep -q 'WakeOnLANByMACAddress' "$CURL_LOG" \
  && ok "...through the router's WoL action" || ko "no WoL SOAP call: $(cat "$CURL_LOG")"
grep -q '^magic aa:bb:cc:00:00:02$' "$CURL_LOG" \
  && ok "...and as a direct magic packet" || ko "no direct packet for the Ethernet MAC: $(cat "$CURL_LOG")"

: > "$CURL_LOG"
expect "status asks the router about the site file's Ethernet MAC alone" 0 "rog    router-active=1" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" status rog
grep -q 'aa:bb:cc:00:00:02' "$CURL_LOG" && ! grep -q 'aa:bb:cc:00:00:01' "$CURL_LOG" \
  && ok "...not about the Wi-Fi one" || ko "router_active used the wrong MAC: $(cat "$CURL_LOG")"
# The column is named for what it reads, the router's NewActive bit, and never for the NIC's link
# state: `eth-link=1` minutes after a shutdown was read as physical link when it was a stale DHCP
# lease (ludics-lite#56). The footer is where a reader of the table learns the difference between
# that stale reading and the settled, powered-off, WoL-armed one.
grep -q "NewActive bit for the Ethernet MAC, not the NIC's link state" <<<"$out" \
  && ok "...and says the column is the router's NewActive bit, not link state" \
  || ko "status does not say what router-active reads -- $out"
grep -q 'stale DHCP lease' <<<"$out" && grep -q 'once settled' <<<"$out" \
  && ok "...telling a stale lease from the settled powered-off state" \
  || ko "status does not carry the stale-lease-vs-settled caveat -- $out"
grep -qE 'eth-link|(^|[^-])link=' <<<"$out" \
  && ko "the old link column name resurfaced in status -- $out" \
  || ok "...and nothing in the table is still called link"

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
grep -q 'wsl started on rog (via rog-lan)' <<<"$out" \
  && ok "the WSL kick goes through the LAN alias when Tailscale has not caught up" \
  || ko "the kick did not use the LAN alias -- $out"
grep -q '^rog-lan :: wsl.exe' "$SSH_LOG" \
  && ok "...carrying the wsl.exe start command" || ko "no wsl.exe over rog-lan: $(cat "$SSH_LOG")"
out=$(kick "rog-nv-win rog-nv-wsl" 2>&1)
grep -q 'wsl started on rog (via rog-nv-win)' <<<"$out" \
  && ok "...and falls back to the Tailscale alias when the LAN one is silent" \
  || ko "no fallback to the Tailscale alias -- $out"
out=$(kick "" 2>&1)
grep -q 'wsl kick FAILED on rog' <<<"$out" \
  && ok "...and reports a box no endpoint answers for" || ko "a kick with nothing up did not fail -- $out"

# --- restart-wsl shuts the VM down on the Windows host before starting it ---------------------
# A VM kept alive across a host sleep/resume can carry a degraded dxg bridge that fails under the
# sweep's parallel width while every single-process probe passes (ludics-lite#60). The cure is a
# new VM, and `wsl --shutdown` belongs on the Windows side: issued inside the VM it kills the
# session issuing it. So the restart rides the same -lan/-win aliases as the kick, never -wsl.
restart() { env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="$1" "$WL" restart-wsl rog; }
: > "$SSH_LOG"
out=$(restart "rog-lan rog-nv-wsl" 2>&1)
grep -q 'wsl shut down on rog (via rog-lan)' <<<"$out" \
  && grep -q 'wsl started on rog (via rog-lan)' <<<"$out" \
  && ok "restart-wsl shuts the VM down and starts it again, over the LAN alias" \
  || ko "restart-wsl did not report a shutdown and a start -- $out"
awk '/^rog-lan :: wsl.exe --shutdown$/ { s = NR } /^rog-lan :: wsl.exe -d Ubuntu/ { t = NR } END { exit !(s && t && s < t) }' "$SSH_LOG" \
  && ok "...issuing wsl.exe --shutdown on the Windows host before the start" \
  || ko "no shutdown ahead of the start over rog-lan: $(cat "$SSH_LOG")"
grep -q '^rog-nv-wsl :: wsl.exe' "$SSH_LOG" \
  && ko "a wsl.exe command reached the -wsl guest, where a shutdown kills its own session: $(cat "$SSH_LOG")" \
  || ok "...and never through the -wsl guest"
out=$(restart "" 2>&1)
grep -q 'wsl restart FAILED on rog' <<<"$out" \
  && ok "...and reports a box no endpoint answers for as a failed restart" || ko "a restart with nothing up did not fail -- $out"
# A restart's success is the restart's own status, never the guest's liveness: when the shutdown
# fails, the -wsl guest that still answers is the OLD VM, and `wsl up` over it would send the sweep
# onto exactly the degraded bridge the restart exists to replace. Two shapes of that: no Windows
# endpoint answers while the guest does, and the endpoints answer but the shutdown itself fails.
out=$(restart "rog-nv-wsl" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl restart FAILED on: rog' <<<"$out" && ! grep -q 'wsl up' <<<"$out" \
  && ok "a restart no Windows endpoint carried is not 'wsl up' just because the old guest answers (rc=$rc)" \
  || ko "a failed restart over a live old guest read as success (rc=$rc) -- $out"
: > "$SSH_LOG"
out=$(env SSH_REFUSE=--shutdown WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-win rog-nv-wsl" "$WL" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl restart FAILED on: rog (shutdown refused' <<<"$out" && ! grep -q 'wsl up' <<<"$out" \
  && ok "...nor is one whose wsl.exe --shutdown failed on every alias that answered, and it says which phase (rc=$rc)" \
  || ko "a refused shutdown over a live old guest read as success, or did not name the phase (rc=$rc) -- $out"
grep -q 'wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ko "a start was issued after the shutdown failed, onto the old VM: $(cat "$SSH_LOG")" \
  || ok "...and no start is issued onto the VM the shutdown left standing"
grep -q 'wsl restart FAILED on: rog' <<<"${out##*$'\n'}" \
  && ok "...with the failure as the last line, where the sweep routine reads its verdict" \
  || ko "the failure is not the last line -- $out"
# The kick keeps its meaning -- start if not running -- so a `--wait --wsl` on a box the user is
# working on never kills a live VM; `--restart-wsl` is the spelling that does.
: > "$SSH_LOG"; kick "rog-lan rog-nv-wsl" >/dev/null 2>&1
grep -q -- '--shutdown' "$SSH_LOG" && ko "kick-wsl issued a shutdown: $(cat "$SSH_LOG")" \
  || ok "kick-wsl never shuts a VM down"
wake_wsl() { env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-wsl" "$WL" --wait "$1" rog; }
: > "$SSH_LOG"; out=$(wake_wsl --wsl 2>&1)
grep -q 'wsl up' <<<"$out" && ! grep -q -- '--shutdown' "$SSH_LOG" \
  && ok "...and neither does --wait --wsl" || ko "--wait --wsl shut a VM down, or never started one -- $out; $(cat "$SSH_LOG")"
: > "$SSH_LOG"; out=$(wake_wsl --restart-wsl 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl shut down on rog (via rog-lan)' <<<"$out" && grep -q 'wsl up' <<<"$out" \
  && grep -q '^all up$' <<<"${out##*$'\n'}" && grep -q '^rog-lan :: wsl.exe --shutdown$' "$SSH_LOG" \
  && ok "--wait --restart-wsl shuts the VM down after the wake and starts a fresh one, ending in all up (rc=$rc)" \
  || ko "--wait --restart-wsl did not restart the VM, or did not end in all up (rc=$rc) -- $out; $(cat "$SSH_LOG")"
# The wake path's final verdict is the wake's AND the WSL step's: with the boxes up and the
# restart failed, `all up` with exit 0 would hand the sweep the old VM, so the WSL failure is the
# last line and the exit status is nonzero.
: > "$SSH_LOG"; out=$(env SSH_REFUSE=--shutdown WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-wsl" "$WL" --wait --restart-wsl rog 2>&1); rc=$?
grep -q 'wsl restart FAILED on: rog' <<<"$out" && ! grep -q 'wsl up' <<<"$out" \
  && ok "...and in the wake path too, a failed shutdown over a live old guest is never 'wsl up'" \
  || ko "the wake path reported wsl up over a VM it failed to shut down -- $out"
[ "$rc" -ne 0 ] && ! grep -q '^all up$' <<<"$out" && grep -q 'wsl restart FAILED on: rog' <<<"${out##*$'\n'}" \
  && ok "...nor 'all up': the restart failure is the wake's last line and its exit status (rc=$rc)" \
  || ko "the wake path said all up, or exited 0, over a failed restart (rc=$rc) -- $out"
# A start that fails AFTER the shutdown went through is the opposite diagnosis: there is no VM at
# all, old or new, and telling the operator the old one still answers would be wrong twice over.
: > "$SSH_LOG"
out=$(env SSH_REFUSE='-d Ubuntu' WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-win rog-nv-wsl" "$WL" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl shut down on rog (via rog-lan)' <<<"$out" \
  && grep -q 'wsl restart FAILED on: rog (shut down, then the start failed' <<<"${out##*$'\n'}" \
  && ! grep -q 'old VM' <<<"$out" \
  && ok "a start that fails after the shutdown is reported as a start failure, never as the old VM answering (rc=$rc)" \
  || ko "a failed start after a shutdown was misreported (rc=$rc) -- $out"
# The step's third failing shape: every wsl.exe command succeeded, and the fresh guest never
# answered within the poll budget. `wsl still down` is a backend the sweep cannot test, so it is a
# failure of the step, from the verb's exit status and from the wake path's final verdict alike.
: > "$SSH_LOG"; out=$(restart "rog-lan rog-nv-win" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'wsl up' <<<"$out" && grep -q 'wsl still down after 0 min on: rog' <<<"${out##*$'\n'}" \
  && ok "a restarted guest that never answers is a failed restart-wsl, its last line saying so (rc=$rc)" \
  || ko "a guest that never answered read as a successful restart (rc=$rc) -- $out"
grep -q '^rog-lan :: wsl.exe -d Ubuntu' "$SSH_LOG" && ok "...after the start really was issued" \
  || ko "the start was never issued, so the case pins nothing: $(cat "$SSH_LOG")"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan rog-nv-win" "$WL" --wait --restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q '^all up$' <<<"$out" && grep -q 'NOT all up: wsl still down after 0 min on: rog' <<<"${out##*$'\n'}" \
  && ok "...and the wake path over it is NOT all up, exit nonzero, with the poll timeout as its last line (rc=$rc)" \
  || ko "the wake path said all up, or exited 0, over a guest that never answered (rc=$rc) -- $out"
# The poll's verdict is aggregate; the report is per box. With two boxes started and one guest
# late, only that one is still down -- the other is up and its backend is testable today.
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 SSH_UP="rog-lan minix-lan rog-nv-wsl" "$WL" restart-wsl rog minix 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q '^wsl up on: rog$' <<<"$out" && grep -q 'wsl still down after 0 min on: minix$' <<<"${out##*$'\n'}" \
  && ok "one late guest is reported alone, and its neighbour as up (rc=$rc)" \
  || ko "the poll's aggregate failure was pinned on every started box (rc=$rc) -- $out"
# The kick path holds the same line: a kick no Windows endpoint carried is a failed kick, whatever
# the guest answers, so `wsl up` there is the kick's own success and not the poll's.
out=$(kick "rog-nv-wsl" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl kick FAILED on: rog' <<<"$out" && ! grep -q 'wsl up' <<<"$out" \
  && ok "kick-wsl reports its own failure over a live guest as well (rc=$rc)" \
  || ko "a failed kick over a live guest read as success (rc=$rc) -- $out"

# --- --hold: the VM is kept alive by a wsl.exe on the WINDOWS side, by nothing else --------------
# A kick returns at once and the VM then shuts down under whatever runs inside it: the 2026-09-15
# sweep's hip unit died 76 s into an unheld VM that had powered off 18 s after its kick
# (ludics-lite#155). An ssh session INSIDE the guest does not hold it, so the holder is a
# Windows-side `wsl.exe -d Ubuntu -e sleep infinity`, and the VM counts as up only once such a
# process is OBSERVED there -- a holder that failed to start is the exact state the flag exists to
# rule out.
# A holder carries its box's lab lock for as long as it lives (that is the point: another
# session's restart is then refused rather than destroying the lane). In this suite that means a
# case which leaves a holder running would refuse every later case on that box, so each case that
# does not continue from a previous holder starts from a clean state AND a free lock. Unlinking
# the lock file is enough: the flock belongs to the inode, so the next take creates a new one.
reset_hold_state() {
  rm -rf "$TMP/state"
  rm -f "$WAKE_LAB_LOCK_DIR"/*.lock
}

held_kick() { # held_kick <ssh-up> <tasklist output> [reg output] [holder lifetime] -- kick-wsl --hold rog
  # The default lifetime is not 0: the script requires its own holder to still be running when it
  # sees a wsl.exe on the Windows side, so a shim holder that exits instantly is an already-dead
  # one, not a held VM.
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="$1" \
      SSH_TASKLIST="$2" SSH_REG="${3:-}" SSH_HOLD_LIFE="${4:-20}" "$WL" kick-wsl --hold rog
}
unhold() { env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog; }
# `tasklist /FI "IMAGENAME eq wsl.exe" /NH` prints one row per match and an INFO line when nothing
# matches, so the image name in the output is the whole signal.
# `kill -0` alone is not a liveness test: a killed orphan whose init does not reap it promptly --
# a container's PID 1, typically -- stays a zombie and answers it, which would read as "unhold did
# not kill the holder" when it did.
alive() { # alive <pid>
  local st
  [ -n "$1" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  st=$(ps -o state= -p "$1" 2>/dev/null)
  case "$st" in ''|*Z*) return 1 ;; esac
  return 0
}
TASKLIST_HELD='wsl.exe                       6412 Services                   0     12,345 K'
TASKLIST_EMPTY='INFO: No tasks are running which match the specified criteria.'

reset_hold_state; : > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl holder started on rog (via rog-lan' <<<"$out" \
  && grep -q 'wsl holder observed on rog' <<<"$out" && grep -q 'wsl up' <<<"$out" \
  && ok "kick-wsl --hold spawns a Windows-side holder, observes it, and only then is the VM up (rc=$rc)" \
  || ko "kick-wsl --hold did not spawn and observe a holder (rc=$rc) -- $out"
grep -q '^rog-lan :: wsl.exe -d Ubuntu -e sleep infinity$' "$SSH_LOG" \
  && ok "...as sleep infinity over the alias that carried the kick" \
  || ko "the holder command is not a sleep infinity over rog-lan: $(cat "$SSH_LOG")"
# Never a sized sleep: a lane is several units with their own caps plus preparation outside them,
# so a holder sized to the expected run expires under the last unit, silently (issue comment of
# 2026-09-15). A lane ends by unhold.
grep -qE 'sleep [0-9]' "$SSH_LOG" \
  && ko "the holder was sized with a fixed sleep, which expires under the last unit: $(cat "$SSH_LOG")" \
  || ok "...never a fixed sleep N"
grep -qE '^rog-nv-wsl :: .*(sleep infinity|tasklist)' "$SSH_LOG" \
  && ko "a holder command reached the -wsl guest, where it would die with the VM it holds: $(cat "$SSH_LOG")" \
  || ok "...and never inside the guest, which would die with the VM it is meant to hold"
grep -q '^rog-lan :: tasklist' "$SSH_LOG" \
  && ok "...with the observation read from the Windows side" \
  || ko "no tasklist query went to the Windows side: $(cat "$SSH_LOG")"
[ -s "$TMP/state/hold-rog.pid" ] \
  && ok "...and the holder's pid is recorded, so a later shell can end it" \
  || ko "no pid recorded under $TMP/state"
# The control that makes the case above mean something: a plain kick holds nothing.
: > "$SSH_LOG"; kick "rog-lan rog-nv-wsl" >/dev/null 2>&1
grep -q 'sleep infinity' "$SSH_LOG" && ko "a kick without --hold spawned a holder: $(cat "$SSH_LOG")" \
  || ok "a kick without --hold spawns no holder"

# The whole point of observing: with the guest answering but NO wsl.exe on the Windows side, the
# old code's `wsl up` would hand the sweep a VM nothing holds.
reset_hold_state; : > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_EMPTY" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'wsl up' <<<"$out" \
  && grep -q 'wsl HOLD FAILED on: rog' <<<"${out##*$'\n'}" \
  && ok "a VM whose holder is not observed on the Windows side is never 'wsl up', and says so last (rc=$rc)" \
  || ko "an unheld VM read as up (rc=$rc) -- $out"
[ ! -f "$TMP/state/hold-rog.pid" ] \
  && ok "...and the failed holder is not left recorded for a later unhold to believe in" \
  || ko "a failed hold left a pid file behind: $(cat "$TMP/state/hold-rog.pid")"
# ...and the VM does not stay up unheld. The sweep's lanes probe the -wsl guest themselves, so a
# reachable-but-unheld guest runs a GPU unit that then dies mid-run -- the exact failure being
# fixed. A VM THIS run created is shut down again, so the unit records honest non-coverage.
reset_hold_state; : > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="rog-lan rog-nv-wsl" \
      SSH_TASKLIST="$TASKLIST_EMPTY" "$WL" restart-wsl --hold rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl shut down on rog (via rog-lan): a fresh VM that cannot be held' <<<"$out" \
  && awk '/^rog-lan :: wsl.exe -d Ubuntu -e true$/ { t = NR } /^rog-lan :: wsl.exe --shutdown$/ { s = NR } END { exit !(t && s && t < s) }' "$SSH_LOG" \
  && ok "a fresh VM whose hold failed is shut down again rather than left for the sweep (rc=$rc)" \
  || ko "an unheld fresh VM was left running (rc=$rc) -- $out; $(cat "$SSH_LOG")"
grep -q 'so it was shut down again: those units record no coverage' <<<"${out##*$'\n'}" \
  && ok "...and the verdict line says the VM is gone, which is what the routine reads" \
  || ko "the verdict did not report the shutdown -- $out"
# The cleanup tries every alias, not just the one the start went out on: that alias is often
# exactly what went wrong during the hold, and one endpoint going quiet must not leave a reachable
# unheld VM up. Here the LAN side dies the moment the observation runs.
reset_hold_state; : > "$SSH_LOG"; : > "$SSH_DOWN_LIST"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="rog-lan rog-nv-win" \
      SSH_TASKLIST="$TASKLIST_EMPTY" SSH_DOWN_AFTER='tasklist|rog-lan' SSH_HOLD_LIFE=20 \
      "$WL" restart-wsl --hold rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl shut down on rog (via rog-nv-win)' <<<"$out" \
  && grep -q 'so it was shut down again' <<<"${out##*$'\n'}" \
  && ok "an unheld VM is shut down over the other alias when the first one has gone quiet (rc=$rc)" \
  || ko "the cleanup gave up on one alias and left the VM up (rc=$rc) -- $out"
: > "$SSH_DOWN_LIST"

# But never a VM that was already there: on a plain kick the guest may be the owner's, and taking
# it away over a failed hold of ours would be a nasty surprise.
reset_hold_state; : > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_EMPTY" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q -- '--shutdown' "$SSH_LOG" \
  && ok "...while a plain kick-wsl --hold never shuts down a VM it did not create (rc=$rc)" \
  || ko "a failed hold shut down a VM this run did not create (rc=$rc) -- $(cat "$SSH_LOG")"
# ...and then the verdict must NOT claim a shutdown that did not happen. This is the sweep
# routine's own retry command: an operator told the VM is gone leaves a reachable unheld guest for
# the lanes to find, and its unit dies mid-run.
grep -q 'the VM is up and UNHELD and was not shut down: do not sweep that box' <<<"${out##*$'\n'}" \
  && ! grep -q 'shut down again' <<<"$out" \
  && ok "...and the verdict says the guest is still up and unheld, never that it was shut down" \
  || ko "the verdict claimed a shutdown that never happened -- $out"

# unhold ends the holder explicitly, which is the only way a lane ends.
reset_hold_state; : > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 2>&1)
hold_pid=$(cut -d' ' -f1 "$TMP/state/hold-rog.pid" 2>/dev/null)
echo "DBG procs=[$(pgrep -fl 'sleep infinity' | head -3)] sidecar=[$(ps -o pid,args -p "$(cut -d' ' -f4 "$TMP/state/hold-rog.pid")" 2>&1|tail -1)]"
if [ -n "$hold_pid" ] && alive "$hold_pid"; then
  ok "the holder is a live process while the lane runs (pid $hold_pid)"
else
  ko "the holder was not running after a successful hold (pid ${hold_pid:-none}) -- $out"
fi
out=$(unhold 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q "wsl holder released on rog (pid $hold_pid killed" <<<"$out" \
  && ok "...and unhold kills it, naming the pid (rc=$rc)" || ko "unhold did not release the holder (rc=$rc) -- $out"
for _ in 1 2 3 4 5; do alive "$hold_pid" || break; sleep 1; done
alive "$hold_pid" \
  && ko "unhold reported a kill the holder survived (pid $hold_pid)" \
  || ok "...and the holder really is gone"
[ ! -f "$TMP/state/hold-rog.pid" ] && ok "...leaving no pid file behind" \
  || ko "unhold left the pid file in place"
# A lane's cleanup runs on the way out of a FAILED lane too, so unhold over nothing is not an error.
expect "unhold with no holder recorded says so and still succeeds" 0 "no wsl holder recorded for rog" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog
# Cleanup must not be blocked by configuration: the holder is a local pid, and a site file that
# went missing after the lane started would otherwise strand the one process that pins the VM.
reset_hold_state
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 2>&1)
stranded=$(cut -d' ' -f1 "$TMP/state/hold-rog.pid" 2>/dev/null)
out=$(env WAKE_LAB_HOSTS="$TMP/absent.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl holder released on rog' <<<"$out" \
  && ok "unhold releases the holder even with no host table, which it needs nothing from (rc=$rc)" \
  || ko "a missing site file stranded the holder (rc=$rc) -- $out"
for _ in 1 2 3 4 5; do alive "$stranded" || break; sleep 1; done
alive "$stranded" && ko "...but the holder survived" || ok "...and the holder is gone"
mkdir -p "$TMP/state"; printf '999999\n' > "$TMP/state/hold-rog.pid"
# A holder found already dead is a lane that lost its box with nobody noticing -- the very failure
# --hold exists to prevent -- so it is reported as a FAULT and leaves rc 2, never as a release. On
# 2026-09-18 both holders died ~30-38 min into a lane, unhold called it a release, and the run read
# as clean; the boxes stayed up by luck. rc 2 and not 1 so a cleanup can tell this from an ordinary
# failure of the unhold command.
expect "...and a holder that had already died is reported as an ANOMALY, not as a release" 2 "ANOMALY: wsl holder on rog had already exited" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog
grep -q 'stopped being RESERVED' <<<"$out" \
  && ok "...and says what it cost the lane -- the lab lock -- not merely that a pid was gone" \
  || ko "the anomaly does not say the box stopped being reserved when the holder died -- $out"
[ ! -f "$TMP/state/hold-rog.pid" ] && ok "...and its stale pid file is cleared" \
  || ko "a dead holder's pid file survived unhold"
# An unhold is not atomic -- it kills the holder, then removes the record -- so an interruption
# between the two (or a second unhold overlapping the first, which the routine now invites by
# telling a run whose unhold has not come back to chase it) leaves a record naming a pid that
# unhold itself deliberately ended. Reporting that as a lost holder would mark valid lane results
# suspect, so the release writes its intent down BEFORE the kill and a retry reads it.
mkdir -p "$TMP/state"; printf '999999 rog-lan 1 0\n' > "$TMP/state/hold-rog.pid"
: > "$TMP/state/hold-rog.releasing"
expect "an interrupted unhold's leftover record is a completed release, not a lost holder" 0 "was already ended by an earlier unhold" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog
grep -q 'ANOMALY' <<<"$out" \
  && ko "a deliberate release was reported as a lost holder -- $out" \
  || ok "...and raises no anomaly, so the lane's results are not called suspect"
[ ! -f "$TMP/state/hold-rog.releasing" ] && ok "...and the release marker is cleared with the record" \
  || ko "the release marker survived unhold"
# ...and that marker must not outlive its lane: left in place it would mask the loss of the NEXT
# holder, which is the one thing this reporting exists to catch.
reset_hold_state
mkdir -p "$TMP/state"; : > "$TMP/state/hold-rog.releasing"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 2>&1)
[ ! -f "$TMP/state/hold-rog.releasing" ] \
  && ok "a fresh hold clears a stale release marker, so the next lost holder is still reported" \
  || ko "a stale release marker survived a fresh hold -- it would mask the next loss -- $out"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1
# Two unholds racing over one box must never report an intentional release as a loss. The marker
# alone does not close this: the record can vanish between one run's entry and its own checks,
# which is why an absent record is read as "a release completed" rather than as evidence. Note what
# this case can and cannot do -- it runs the pair concurrently and cannot prove it ever hit the
# window, so the guarantee rests on that argument and this is the regression net under it. It also
# cannot fail spuriously in the other direction: the only things that fail it, an ANOMALY line and
# an rc 2, are both the bug itself.
race_bad=0
for i in 1 2 3; do
  reset_hold_state
  held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 >/dev/null 2>&1
  ( env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog \
      > "$TMP/race-a" 2>&1; echo $? > "$TMP/race-a.rc" ) &
  ( env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog \
      > "$TMP/race-b" 2>&1; echo $? > "$TMP/race-b.rc" ) &
  wait
  if grep -q 'ANOMALY' "$TMP/race-a" "$TMP/race-b" 2>/dev/null; then
    race_bad=$((race_bad + 1)); echo "  race $i raised an anomaly: $(cat "$TMP/race-a" "$TMP/race-b")"
  fi
  for half in a b; do
    [ "$(cat "$TMP/race-$half.rc" 2>/dev/null)" = 2 ] && race_bad=$((race_bad + 1))
  done
done
[ "$race_bad" -eq 0 ] \
  && ok "overlapping unholds never report a deliberate release as a lost holder" \
  || ko "overlapping unholds reported an intentional release as a loss ($race_bad of 6 halves)"
# ...and the pair really did release something, so the case above is not passing on two no-ops.
if grep -q 'wsl holder released on rog' "$TMP/race-a" "$TMP/race-b" 2>/dev/null; then
  ok "...and the racing pair between them released the holder"
else
  ko "neither half of the race released anything -- $(cat "$TMP/race-a" "$TMP/race-b" 2>/dev/null)"
fi
[ ! -f "$TMP/state/hold-rog.pid" ] && [ ! -f "$TMP/state/hold-rog.releasing" ] \
  && ok "...and leaves neither the record nor the marker behind" \
  || ko "a raced unhold left state behind for the next lane to trip on"
# Every box's holder runs the same payload, so a signature that did not include the destination
# would let one box's stale file kill another box's LIVE holder -- dropping that lane silently.
reset_hold_state
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 2>&1)
rog_pid=$(cut -d' ' -f1 "$TMP/state/hold-rog.pid" 2>/dev/null)
printf '%s minix-lan\n' "$rog_pid" > "$TMP/state/hold-minix.pid"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold minix 2>&1)
grep -q 'had already exited' <<<"$out" && alive "$rog_pid" \
  && ok "a stale file for one box does not kill another box's live holder" \
  || ko "unhold minix killed rog's holder, or claimed it as its own -- $out"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1
# The pid file outlives the shell that wrote it, and pids are reused: a stale one whose number has
# been taken over by something else must not get that process killed.
sleep 30 & innocent=$!
printf '%s\n' "$innocent" > "$TMP/state/hold-rog.pid"
expect "a stale pid reused by an unrelated process is not killed as a holder" 2 "had already exited" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog
alive "$innocent" && ok "...and that process is still running" \
  || ko "unhold killed a process that merely inherited the holder's pid"
kill "$innocent" 2>/dev/null; wait "$innocent" 2>/dev/null
# A --hold that holds nothing is a lane that believes it is held and is not.
: > "$CURL_LOG"
expect "--hold without a WSL start is refused rather than ignored" 1 "hold needs a WSL start" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" --hold rog
[ ! -s "$CURL_LOG" ] && ok "...before anything is sent" || ko "the refused run still woke the box: $(cat "$CURL_LOG")"
# The wake path starts WSL only under --wait, so `--wsl --hold` without it holds nothing either --
# and it is the shape an operator is most likely to type.
: > "$CURL_LOG"
expect "...and so is --wsl --hold without --wait, which never reaches the WSL start" 1 "hold needs a WSL start" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" --wsl --hold rog
expect "...and --restart-wsl --hold without --wait" 1 "hold needs a WSL start" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" --restart-wsl --hold rog
[ ! -s "$CURL_LOG" ] && ok "...both before any packet goes out" || ko "a refused held wake still woke the box: $(cat "$CURL_LOG")"

# An unrecordable holder is a leaked one: nothing would ever unhold it, and the VM would stay
# pinned until the box reboots.
# A state path UNDER a regular file, not a mode-555 directory: root ignores the mode bits, and
# this suite runs as root in a container often enough that the case would fail there for the
# runner's uid rather than for the defect it pins.
reset_hold_state; : > "$TMP/notadir"
: > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/notadir/state" \
      SSH_UP="rog-lan rog-nv-wsl" SSH_TASKLIST="$TASKLIST_HELD" SSH_HOLD_LIFE=20 \
      "$WL" kick-wsl --hold rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl HOLD FAILED on: rog' <<<"$out" \
  && grep -q 'could NOT be recorded at .*; nothing was started' <<<"$out" \
  && ok "a holder that cannot be recorded fails the hold, and is never spawned to begin with (rc=$rc)" \
  || ko "an unrecordable holder did not fail the hold, or was spawned before its record (rc=$rc) -- $out"
# The wording is the evidence for the ordering: the record is claimed (noclobber) BEFORE the ssh
# exists, so there is no window in which a holder runs that nothing can unhold. Spawning first and
# killing on a failed write leaves that window, and says "killed rather than leaked" instead.
grep -q 'sleep infinity' "$SSH_LOG" \
  && ko "a holder was spawned before its record was claimed: $(cat "$SSH_LOG")" \
  || ok "...with no holder command issued at all"
rm -f "$TMP/notadir"
# The same claim serializes two --hold runs for one box: the second reuses the live holder rather
# than spawning a second one whose pid the first would never see.
reset_hold_state
held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 >/dev/null 2>&1
: > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl holder already running for rog' <<<"$out" \
  && ! grep -q 'sleep infinity' "$SSH_LOG" \
  && ok "a second --hold over a live holder reuses it and spawns no second one (rc=$rc)" \
  || ko "a second --hold spawned another holder (rc=$rc) -- $out; $(cat "$SSH_LOG")"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1

# `wsl --shutdown` is HOST-GLOBAL, so a restart on a box a lane is holding destroys that lane's VM
# and its holder -- the 2026-09-16 loss, from inside the flag meant to prevent it. The holder
# carries that box's LAB LOCK (ludics-lite#168): it inherits the descriptor, so the flock lives as
# long as the holder and the next restart is refused by the same interlock that protects every
# other tool. A plain kick stays available because it has no shutdown to refuse and is the recovery
# command for a box with no VM.
reset_hold_state
held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 >/dev/null 2>&1
lane_pid=$(cut -d' ' -f1 "$TMP/state/hold-rog.pid" 2>/dev/null)
: > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="rog-lan rog-nv-wsl" \
      SSH_TASKLIST="$TASKLIST_HELD" SSH_HOLD_LIFE=30 "$WL" restart-wsl --hold rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q -- '--shutdown' "$SSH_LOG" \
  && grep -q "wsl restart REFUSED on: rog (the lab lock is held" <<<"${out##*$'\n'}" \
  && grep -q 'wake-lab --hold' <<<"$out" && alive "$lane_pid" \
  && ok "a restart is refused on a box a lane is holding, before any host-global shutdown (rc=$rc)" \
  || ko "a restart tore down a held lane's VM (rc=$rc) -- $out; $(cat "$SSH_LOG")"
[ -n "$(env WAKE_LAB_HOSTS="$TMP/absent.sh" "$WL" lock-path rog)" ] \
  && ok "...and the refusal names the holder as the hold itself, at the lock path lock-path reports" \
  || ko "lock-path does not answer for the box the holder locked"
: > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl holder already running for rog' <<<"$out" && ! grep -q -- '--shutdown' "$SSH_LOG" \
  && ok "...while a plain kick-wsl --hold on the same box is still allowed and reuses the holder (rc=$rc)" \
  || ko "the refusal also blocked the recovery kick (rc=$rc) -- $out"
# ...and unhold gives the box back: the kill releases the flock with it, so the restart that was
# refused a moment ago goes through with nothing to reclaim.
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1
: > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_STATE_DIR="$TMP/state" \
      SSH_UP="rog-lan rog-nv-wsl" "$WL" restart-wsl rog 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q '^rog-lan :: wsl.exe --shutdown$' "$SSH_LOG" \
  && ! grep -q 'REFUSED' <<<"$out" \
  && ok "...and unhold gives the box back: the lock dies with the holder it was taken by (rc=$rc)" \
  || ko "the lock outlived the holder unhold killed (rc=$rc) -- $out"

# A holder that another run is in the middle of creating is an EMPTY record, between its claim and
# its pid write. Clearing that as stale would let both runs spawn a holder with one pid recorded --
# the race the claim exists to prevent -- so a fresh empty claim is refused, and only an abandoned
# one (older than a minute: its creator died inside a single fork) is cleared.
reset_hold_state; mkdir -p "$TMP/state"; : > "$TMP/state/hold-rog.pid"
: > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'is being created by another run' <<<"$out" && ! grep -q 'sleep infinity' "$SSH_LOG" \
  && ok "a claim another run is still filling in is not cleared, and no second holder is spawned (rc=$rc)" \
  || ko "an in-progress claim was taken over (rc=$rc) -- $out; $(cat "$SSH_LOG")"
touch -t 202001010000 "$TMP/state/hold-rog.pid"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl holder started on rog' <<<"$out" \
  && ok "...while an abandoned claim is taken over rather than blocking the hold forever (rc=$rc)" \
  || ko "an abandoned claim blocked the hold (rc=$rc) -- $out"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1

# A holder this call merely REUSED belongs to an earlier invocation that may still be protecting a
# running lane. A failed probe here must not kill it: that would unhold that lane's VM, which is
# the failure the flag exists to prevent, caused by a retry.
reset_hold_state
held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 >/dev/null 2>&1
other_pid=$(cut -d' ' -f1 "$TMP/state/hold-rog.pid" 2>/dev/null)
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_EMPTY" 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'belongs to an earlier run: left running and recorded' <<<"$out" \
  && alive "$other_pid" && [ -s "$TMP/state/hold-rog.pid" ] \
  && ok "a failed hold does not kill a holder it reused from an earlier run (rc=$rc)" \
  || ko "a failed retry unheld the earlier run's VM (rc=$rc) -- $out"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1

# The settle belongs to the HOLDER, not to the invocation: a run that reuses a holder another run
# started a moment ago has to wait out the rest of that holder's settle, or it certifies an ssh
# that may still be inside its ConnectTimeout.
reset_hold_state
held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 30 >/dev/null 2>&1
started=$SECONDS
# The step's own deadline bounds the settle too (a settle that outlived HOLD_WAIT_SECONDS would
# be a hold with no bound at all), so this case gives the step room and lets the settle bind.
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=30 \
      WAKE_LAB_HOLD_SETTLE_SECONDS=6 WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="rog-lan rog-nv-wsl" \
      SSH_TASKLIST="$TASKLIST_HELD" SSH_HOLD_LIFE=30 "$WL" kick-wsl --hold rog 2>&1); rc=$?
elapsed=$((SECONDS - started))
[ "$rc" -eq 0 ] && grep -q 'wsl holder already running for rog' <<<"$out" && [ "$elapsed" -ge 4 ] \
  && ok "a reused holder still has to clear its own settle (${elapsed}s against a 6s settle)" \
  || ko "reusing a holder skipped the settle (rc=$rc, ${elapsed}s) -- $out"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1

# The wake path carries the hold too, and its final verdict is the hold's as well.
wake_hold() { # wake_hold <tasklist output>
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 WAKE_LAB_WSL_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_WAIT_SECONDS=1 WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/state" \
      SSH_UP="rog-lan rog-nv-wsl" SSH_TASKLIST="$1" SSH_HOLD_LIFE=20 \
      "$WL" --wait --restart-wsl --hold rog
}
reset_hold_state
out=$(wake_hold "$TASKLIST_HELD" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'wsl holder observed on rog' <<<"$out" && grep -q '^all up$' <<<"${out##*$'\n'}" \
  && ok "--wait --restart-wsl --hold ends in all up with the holder observed (rc=$rc)" \
  || ko "the wake path did not hold the fresh VM (rc=$rc) -- $out"
reset_hold_state
out=$(wake_hold "$TASKLIST_EMPTY" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q '^all up$' <<<"$out" && grep -q 'NOT all up: wsl HOLD FAILED on: rog' <<<"${out##*$'\n'}" \
  && ok "...and is NOT all up when nothing holds the VM it just started (rc=$rc)" \
  || ko "the wake path said all up over an unheld VM (rc=$rc) -- $out"

# --- the Windows Update window ------------------------------------------------------------------
# KB5129195 restarted minix 21 min into its hip unit on 2026-09-15: active hours were 10:00-01:00
# and the sweep runs in the morning. The registry values are readable in advance from the -win
# side, so a feature update that resets them is a warning before the sweep, not a lost unit after.
# reg.exe writes CRLF, and Windows OpenSSH passes it through: a parser that leaves the \r on the
# value matches neither the hex nor the decimal shape, and every real box would read as an
# unreadable registry. So the fixture is CRLF, like the real thing.
reg_out() { # reg_out <start> <end> <smart> -- as `reg query` prints the key, CRLF included
  printf 'HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\WindowsUpdate\\UX\\Settings\r\n'
  printf '    ActiveHoursStart    REG_DWORD    %s\r\n' "$1"
  printf '    ActiveHoursEnd    REG_DWORD    %s\r\n' "$2"
  printf '    SmartActiveHoursState    REG_DWORD    %s\r\n' "$3"
}
reset_hold_state; : > "$SSH_LOG"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out 0xa 0x1 0x0)" 2>&1)
grep -q 'ACTIVE HOURS WARNING on rog: sweep window 7-11 falls outside active hours 10-1' <<<"$out" \
  && grep -q 'uncovered hours: 7 8 9' <<<"$out" \
  && ok "the preflight warns when the sweep window falls outside active hours, naming the hours" \
  || ko "no active-hours warning for a 10-1 window against a 7-11 sweep -- $out"
grep -q 'reg query "HKLM\\SOFTWARE\\Microsoft\\WindowsUpdate\\UX\\Settings"' "$SSH_LOG" \
  && ok "...read from the UX\\Settings key on the Windows side" \
  || ko "the active-hours check did not query the registry key: $(cat "$SSH_LOG")"
# A warning whose repair has to be reconstructed from a registry path is one that gets read and
# left: nothing re-applies the values, so the line names the tracked script that writes them back.
grep -q 'repair with scripts/enable-active-hours-windows.ps1 on the box (elevated PowerShell)' <<<"$out" \
  && ok "...and points the repair at the tracked active-hours script" \
  || ko "the active-hours warning does not name scripts/enable-active-hours-windows.ps1 -- $out"
[ -f "$HERE/enable-active-hours-windows.ps1" ] \
  && ok "...which is tracked where the warning says it is" \
  || ko "the warning names scripts/enable-active-hours-windows.ps1, which is not in the checkout"
# The advice is one constant now, and pinning one use of it would leave the other three free to
# drift. Every warning about the BOX's own values carries it, whichever branch printed it.
for fixture in '0x18 0x18 0x0' '0x6 0x6 0x0' '0x6 0x0 0x1'; do
  # shellcheck disable=SC2086 # the fixture is three fields, deliberately split
  branch=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out $fixture)" 2>&1)
  grep -q 'ACTIVE HOURS WARNING' <<<"$branch" \
    && grep -q 'repair with scripts/enable-active-hours-windows.ps1 on the box (elevated PowerShell)' <<<"$branch" \
    && ok "...on every branch that warns about the box's values ($fixture)" \
    || ko "the active-hours warning for $fixture carries no repair advice -- $branch"
done
# ...and the two that deliberately do not: a malformed WAKE_LAB_SWEEP_HOURS is a misconfiguration
# on THIS side, where the Windows script would change nothing, and an unreadable registry knows of
# no setting to repair. Pinning the constant's reach means pinning where it stops, too.
out=$(env WAKE_LAB_SWEEP_HOURS=morning WAKE_LAB_HOSTS="$TMP/hosts.sh" SSH_UP="rog-lan" \
      SSH_REG="$(reg_out 0x6 0x0 0x0)" "$WL" status rog 2>&1)
grep -q "WAKE_LAB_SWEEP_HOURS='morning' is not" <<<"$out" \
  && ! grep -q 'enable-active-hours-windows.ps1' <<<"$out" \
  && ok "...but a sweep-window misconfiguration on this side does not point at the box's script" \
  || ko "the WAKE_LAB_SWEEP_HOURS warning names a repair on the box -- $out"
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 2>&1)
grep -q 'could not read ActiveHoursStart/End' <<<"$out" \
  && ! grep -q 'enable-active-hours-windows.ps1' <<<"$out" \
  && ok "...and an unreadable registry names no repair, knowing of no setting to fix" \
  || ko "the unreadable-registry warning claimed a repair -- $out"
# The quiet path: the 6-to-0 maximum the boxes now pin covers a morning sweep, and a check that
# warned there too would be one nobody reads.
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out 0x6 0x0 0x0)" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'active hours on rog: 6-0 cover the sweep window 7-11 (smart=0)' <<<"$out" \
  && ! grep -q 'ACTIVE HOURS WARNING' <<<"$out" \
  && ok "...and is quiet under the 6-to-0 maximum the boxes pin, reporting what it read (rc=$rc)" \
  || ko "the covered case warned, or said nothing about what it read (rc=$rc) -- $out"
# Smart active hours means Windows moves the window itself, so the pinned values are not in force.
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out 0x6 0x0 0x1)" 2>&1)
grep -q 'SmartActiveHoursState=1 lets Windows move them' <<<"$out" \
  && ok "...but warns when SmartActiveHoursState is on, whatever the values say" \
  || ko "a covered window with smart active hours on went unremarked -- $out"
# A window that wraps midnight is read on both sides of it.
out=$(env WAKE_LAB_SWEEP_HOURS=23-2 WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_WAIT_SECONDS=1 WAKE_LAB_HOLD_SETTLE_SECONDS=0 \
      WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="rog-lan rog-nv-wsl" \
      SSH_TASKLIST="$TASKLIST_HELD" SSH_REG="$(reg_out 0x6 0x0 0x0)" SSH_HOLD_LIFE=20 \
      "$WL" kick-wsl --hold rog 2>&1)
grep -q 'uncovered hours: 0 1' <<<"$out" && ! grep -q 'uncovered hours:.*23' <<<"$out" \
  && ok "...and a sweep window that wraps midnight is judged hour by hour across it" \
  || ko "a wrapping sweep window was misjudged -- $out"
# `08-11` is the natural way to write a morning window, and bash reads a leading zero as octal:
# the arithmetic would die on the 8 and abort a check that promises only to warn.
out=$(env WAKE_LAB_SWEEP_HOURS=08-11 WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_WAIT_SECONDS=1 WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/state" \
      SSH_UP="rog-lan rog-nv-wsl" SSH_TASKLIST="$TASKLIST_HELD" SSH_REG="$(reg_out 0xa 0x1 0x0)" \
      SSH_HOLD_LIFE=20 "$WL" kick-wsl --hold rog 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'uncovered hours: 8 9' <<<"$out" && ! grep -qi 'value too great\|base' <<<"$out" \
  && ok "...and a zero-padded sweep window is read as decimal, not as octal (rc=$rc)" \
  || ko "a zero-padded window aborted the warn-only check (rc=$rc) -- $out"
# A window that is not a pair of clock hours is a configuration finding, not an hour to judge:
# `7`, `7--11` and `24-25` all survived a check that read only the two extracted endpoints.
# Equal endpoints are an EMPTY range, the end being exclusive -- not a one-hour window.
out=$(env WAKE_LAB_SWEEP_HOURS=7-7 WAKE_LAB_HOSTS="$TMP/hosts.sh" SSH_UP="rog-lan" \
      SSH_REG="$(reg_out 0x6 0x0 0x0)" "$WL" status rog 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q "WAKE_LAB_SWEEP_HOURS='7-7' is an empty range" <<<"$out" \
  && ! grep -q 'cover the sweep window' <<<"$out" \
  && ok "an empty sweep window is reported as empty, not judged as one hour (rc=$rc)" \
  || ko "7-7 was silently read as a one-hour window (rc=$rc) -- $out"
for bad in 7 7--11 24-25 morning; do
  out=$(env WAKE_LAB_SWEEP_HOURS="$bad" WAKE_LAB_HOSTS="$TMP/hosts.sh" SSH_UP="rog-lan" \
        SSH_REG="$(reg_out 0x6 0x0 0x0)" "$WL" status rog 2>&1); rc=$?
  [ "$rc" -eq 0 ] && grep -q "WAKE_LAB_SWEEP_HOURS='$bad' is not" <<<"$out" \
    && ! grep -q 'uncovered hours' <<<"$out" \
    && ok "a malformed sweep window ($bad) is reported as malformed, not judged (rc=$rc)" \
    || ko "the sweep window '$bad' was accepted (rc=$rc) -- $out"
done
# Equal endpoints are not a 24-hour window: Windows allows at most 18 hours, so 6-6 is a reset or
# malformed setting, and reading it as "every hour protected" would print the quiet line over a box
# with no protection at all.
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out 0x6 0x6 0x0)" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'a span Windows cannot mean' <<<"$out" && ! grep -q 'cover the sweep window' <<<"$out" \
  && ok "equal active-hours endpoints are a warning, not a day-long window (rc=$rc)" \
  || ko "6-6 was read as full coverage (rc=$rc) -- $out"
# The same bound from the other side: Windows allows at most 18 hours, so 1-23 is as impossible as
# 6-6, and it covers the sweep window on paper -- which is how an invalid setting would stay quiet.
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out 0x1 0x17 0x0)" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'active hours read as 1-23, a span Windows cannot mean' <<<"$out" \
  && ! grep -q 'cover the sweep window' <<<"$out" \
  && ok "...and so is a span longer than the 18 h Windows maximum (rc=$rc)" \
  || ko "a 22-hour active window was read as coverage (rc=$rc) -- $out"
# The pinned maximum itself must stay quiet: 6-0 is exactly 18 h.
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out 0x6 0x0 0x0)" 2>&1)
grep -q 'active hours on rog: 6-0 cover the sweep window' <<<"$out" && ! grep -q 'cannot mean' <<<"$out" \
  && ok "...while the 18 h maximum the boxes pin is still the quiet path" \
  || ko "the 6-to-0 window the boxes pin was rejected -- $out"
# Numeric is not valid: 24-24 reaches the equal-endpoint branch, which would call every hour
# covered and print the quiet line over a box whose update protection is nonsense.
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "$(reg_out 0x18 0x18 0x0)" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'active hours read as 24-24, which are not clock hours' <<<"$out" \
  && ! grep -q 'cover the sweep window' <<<"$out" \
  && ok "...and registry values that are not clock hours are a warning, not a covered window (rc=$rc)" \
  || ko "24-24 was read as a covered window (rc=$rc) -- $out"
# Unreadable is its own answer: the box may still be swept, but nothing is known about its updates.
out=$(held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 2>&1); rc=$?
[ "$rc" -eq 0 ] && grep -q 'ACTIVE HOURS WARNING on rog: could not read ActiveHoursStart/End' <<<"$out" \
  && ok "an unreadable registry warns without failing the hold (rc=$rc)" \
  || ko "an unreadable registry was silent, or failed the hold (rc=$rc) -- $out"

# status reports the same window, which is where a human asks whether the fleet is fit for tonight.
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" SSH_UP="rog-lan" SSH_REG="$(reg_out 0xa 0x1 0x0)" "$WL" status rog 2>&1)
grep -q 'Windows Update window' <<<"$out" \
  && grep -q 'ACTIVE HOURS WARNING on rog: sweep window 7-11 falls outside active hours 10-1' <<<"$out" \
  && ok "status carries the active-hours reading for each box" \
  || ko "status does not report the update window -- $out"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" "$WL" status rog 2>&1)
grep -q 'active hours on rog: not read (no Windows endpoint answered)' <<<"$out" \
  && ! grep -q 'ACTIVE HOURS WARNING' <<<"$out" \
  && ok "...and a box that is down has no reading rather than a warning about its settings" \
  || ko "status warned about the settings of a box it could not reach -- $out"

# A start probe that wedges on one alias must not leave the holder pointed at the OTHER one: on
# the kick path the loop tries the Tailscale alias next, and when that start fails the box is
# still reported up (the wedged start may well have worked), so the holder has to ride the alias
# whose start actually went out.
reset_hold_state; : > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_WSL_START_CAP=2 WAKE_LAB_PROBE_CAP=3 \
      WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="rog-lan" SSH_HANG='rog-lan :: wsl\.exe -d Ubuntu -e true' \
      SSH_TASKLIST="$TASKLIST_HELD" SSH_HOLD_LIFE=30 "$WL" kick-wsl --hold rog 2>&1); rc=$?
grep -q '^rog-lan :: wsl.exe -d Ubuntu -e sleep infinity$' "$SSH_LOG" \
  && ok "the holder rides the alias whose start went out, not the one that answered nothing" \
  || ko "the holder was put on the wrong alias after a capped start (rc=$rc) -- $out; $(cat "$SSH_LOG")"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1

# Every remote command the hold adds is capped, for the reason the kick's are: ConnectTimeout
# bounds the connect, not the remote command, so an accepted session whose `tasklist` never
# returns would stop the hold's own deadline from advancing and hang the sweep behind it. The shim
# wedges with `exec sleep 900`, so a run that FINISHES at all proves the cap fired.
reset_hold_state
started=$SECONDS
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_PROBE_CAP=2 WAKE_LAB_STATE_DIR="$TMP/state" \
      SSH_UP="rog-lan rog-nv-wsl" SSH_HANG='tasklist' SSH_TASKLIST="$TASKLIST_HELD" \
      SSH_HOLD_LIFE=30 "$WL" kick-wsl --hold rog 2>&1); rc=$?
elapsed=$((SECONDS - started))
[ "$rc" -ne 0 ] && [ "$elapsed" -lt 90 ] && grep -q 'wsl HOLD FAILED on: rog' <<<"$out" \
  && ok "a wedged tasklist is cut short rather than hanging the hold (${elapsed}s)" \
  || ko "the holder observation was not capped (rc=$rc, ${elapsed}s) -- $out"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1

# A caller that READS the command's output must not wait for the lane. The holder and the process
# that keeps its lab lock both outlive the command by design, so anything of theirs still holding
# the caller's pipe hangs `kick-wsl --hold | tee log` — or any `$( )` around it, which is how this
# suite calls it — for the whole life of the lane. The lock process is exec'd for exactly that
# reason: a forked shell keeps bash's own descriptors, a caller's pipe among them, while an exec
# sheds them (they are close-on-exec) and keeps only the lock's own fd.
reset_hold_state
started=$SECONDS
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=1 \
    WAKE_LAB_HOLD_SETTLE_SECONDS=0 WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="rog-lan rog-nv-wsl" \
    SSH_TASKLIST="$TASKLIST_HELD" SSH_HOLD_LIFE=45 "$WL" kick-wsl --hold rog 2>&1 | cat >/dev/null
elapsed=$((SECONDS - started))
[ "$elapsed" -lt 20 ] \
  && ok "a held lane does not hold its caller's pipe open behind it (${elapsed}s against a 45s holder)" \
  || ko "reading the command's output waited for the holder (${elapsed}s): something of the lane's holds the pipe"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1

# A settle cut short by the step's own deadline is not a settle served: the holder has not shown
# it outlived its own ConnectTimeout, so the hold must fail rather than report it observed.
reset_hold_state
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_HOLD_WAIT_SECONDS=1 \
      WAKE_LAB_HOLD_SETTLE_SECONDS=30 WAKE_LAB_STATE_DIR="$TMP/state" SSH_UP="rog-lan rog-nv-wsl" \
      SSH_TASKLIST="$TASKLIST_HELD" SSH_HOLD_LIFE=45 "$WL" kick-wsl --hold rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && ! grep -q 'holder observed on rog' <<<"$out" \
  && grep -q 'wsl HOLD FAILED on: rog' <<<"$out" \
  && ok "a settle the step's deadline cut short is not reported as a holder observed (rc=$rc)" \
  || ko "an unserved settle read as success (rc=$rc) -- $out"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1
# ...and the lock process is identified before it is signalled, exactly as the holder is: a record
# outlives both, and by the time anyone runs `unhold` the number may belong to something else.
reset_hold_state
held_kick "rog-lan rog-nv-wsl" "$TASKLIST_HELD" "" 45 >/dev/null 2>&1
sc_pid=$(cut -d' ' -f4 "$TMP/state/hold-rog.pid" 2>/dev/null)
sleep 30 & bystander=$!
printf '%s rog-lan %s %s\n' "$(cut -d' ' -f1 "$TMP/state/hold-rog.pid")" "$(date +%s)" "$bystander" \
  > "$TMP/state/hold-rog.pid"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold rog >/dev/null 2>&1
alive "$bystander" \
  && ok "a recorded lock pid that is not the lock process is left alone by unhold" \
  || ko "unhold killed an unrelated process recorded as the lock"
kill "$bystander" 2>/dev/null; kill "$sc_pid" 2>/dev/null; reset_hold_state

# The holder's signature is read from `ps`, and macOS `ps` truncates the argument list to the
# output width unless it is asked not to. This command line runs well past 79 columns, so a
# truncated reading matches nothing and every live holder would look like somebody else's process
# -- a false negative that fails the hold and deletes the record without killing the holder. The
# fixture cannot make a pipe narrow, so the guard is on the invocation itself.
grep -q 'ps -ww -o args=' "$WL" \
  && ok "the holder signature is read with ps -ww, which macOS does not truncate" \
  || ko "ps is called without -ww: on macOS the signature is cut off and no holder is ever recognized"
# Leave no holder running into the cases below: a live holder carries its box's lab lock, which is
# the point of the design, and the restart cases that follow would be refused by it.
for b in rog minix; do
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_STATE_DIR="$TMP/state" "$WL" unhold "$b" >/dev/null 2>&1
done
reset_hold_state

# --- a wedged wsl.exe is bounded, and the guest is what settles it ------------------------------
# 2026-09-16: `--wait --restart-wsl rog minix` ran 2h40m without exiting. ssh's ConnectTimeout
# bounds the TCP connect alone, so once the Windows side accepted the connection and `wsl.exe -d
# Ubuntu -e true` wedged, the ssh had no upper bound at all -- and the scheduled sweep that called
# it hung behind it. Each remote command now runs under a wall-clock cap. The caps are cut to a
# few seconds here; the shim wedges with `exec sleep 900`, so a run that still finishes proves the
# cap fired and nothing else.
hang() { # hang <regex> <up-list> <verb...> -- a restart with some remote commands wedged
  local re=$1 up=$2; shift 2
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 \
      WAKE_LAB_WSL_SHUTDOWN_CAP=3 WAKE_LAB_WSL_START_CAP=3 WAKE_LAB_PROBE_CAP=3 \
      SSH_HANG="$re" SSH_UP="$up" "$WL" "$@"
}
# The incident's own shape, and its own resolution: the start probe never returns, and the VM has
# in fact started -- `uptime -p` inside rog's guest matched the restart to the minute while the
# Windows-side probe was still stuck. So the cap is not a failure. The guest is asked directly over
# the -wsl alias, which answered instantly throughout that morning, and its answer is the verdict.
: > "$SSH_LOG"; started=$SECONDS
out=$(hang '^rog-lan :: wsl\.exe -d Ubuntu' "rog-lan rog-nv-win rog-nv-wsl" restart-wsl rog 2>&1); rc=$?
elapsed=$((SECONDS - started))
[ "$elapsed" -lt 30 ] && ok "a wedged start probe is cut short by its cap instead of hanging (${elapsed}s)" \
  || ko "the run took ${elapsed}s against a 3s cap: the remote command is still unbounded"
[ "$rc" -eq 0 ] && grep -q 'wsl start probe timed out after 3s on rog (via rog-lan); the guest answers, so the VM is up' <<<"$out" \
  && grep -q 'wsl up' <<<"$out" \
  && ok "...and a guest that answers over its own alias settles it as up, not as a failed restart (rc=$rc)" \
  || ko "a capped start probe over a live guest did not read as up (rc=$rc) -- $out"
grep -q '^rog-nv-wsl :: exit 0$' "$SSH_LOG" \
  && ok "...having really asked the guest, over the -wsl alias the wedged Windows side is not on" \
  || ko "the guest was never probed after the cap fired: $(cat "$SSH_LOG")"
# With no guest answering there is no verdict yet, and the poll already has one: it asks the guest,
# on its own deadline. What must NOT happen is a fall through to the next alias -- in the restart
# path that is a second `wsl --shutdown`, tearing down the VM the wedged start may just have booted.
: > "$SSH_LOG"
out=$(hang 'wsl\.exe -d Ubuntu' "rog-lan rog-nv-win" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'leaving the verdict to the guest poll' <<<"$out" \
  && grep -q 'wsl still down after 0 min on: rog' <<<"${out##*$'\n'}" && ! grep -q 'wsl up' <<<"$out" \
  && ok "...while a capped start with a silent guest is left to the poll, which fails it (rc=$rc)" \
  || ko "a capped start with no guest answering was not left to the poll (rc=$rc) -- $out"
[ "$(grep -c -- 'wsl.exe --shutdown' "$SSH_LOG")" -eq 1 ] \
  && ok "...and no second shutdown is issued onto the VM that start may have booted" \
  || ko "the capped start retried the whole restart on the next alias: $(cat "$SSH_LOG")"
# A wedged `wsl --shutdown` is the dangerous one: its status says nothing, and the restart's whole
# invariant is that no live old VM survives it. So the guest decides again -- and here it decides
# against. A guest still answering means the teardown has not taken, this alias has not carried the
# restart, and no start may be issued onto the VM left standing.
: > "$SSH_LOG"
out=$(hang 'wsl\.exe --shutdown' "rog-lan rog-nv-win rog-nv-wsl" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'wsl shutdown TIMED OUT after 3s on rog (via rog-lan); the guest still answers, so the old VM stands' <<<"$out" \
  && grep -q 'wsl restart FAILED on: rog (shutdown refused' <<<"${out##*$'\n'}" && ! grep -q 'wsl up' <<<"$out" \
  && ok "a wedged shutdown over a guest that still answers is a failed restart, never 'wsl up' (rc=$rc)" \
  || ko "a capped shutdown over a live old guest read as success (rc=$rc) -- $out"
grep -q 'wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ko "a start was issued onto the VM the capped shutdown left standing: $(cat "$SSH_LOG")" \
  || ok "...and no start is issued onto it"
# A SILENT guest is not the opposite evidence, and reading it that way was a real defect (PR #165
# round 1, P1). The -wsl alias rides tailscaled inside the guest, which this suite's own subject
# documents as lagging minutes behind a running VM, so "no guest answers" is the everyday reading
# of a VM that is perfectly alive. Starting on it attaches to the old VM and then reports the
# fresh restart the sweep waits for -- the stale bridge restart-wsl exists to replace. So a capped
# shutdown is unconfirmed whichever way the guest goes, and NO start may follow it on that alias.
: > "$SSH_LOG"
out=$(hang 'wsl\.exe --shutdown' "rog-lan rog-nv-win" restart-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'no guest answers, but a silent guest is not a stopped VM — the teardown is unconfirmed' <<<"$out" \
  && ! grep -q 'wsl up' <<<"$out" && grep -q 'wsl restart FAILED on: rog (shutdown refused' <<<"${out##*$'\n'}" \
  && ok "a capped shutdown is unconfirmed even with a silent guest, and fails the restart (rc=$rc)" \
  || ko "a capped shutdown with a silent guest was treated as a teardown (rc=$rc) -- $out"
grep -q 'wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ko "a start was issued after a shutdown that was never confirmed: $(cat "$SSH_LOG")" \
  || ok "...issuing no start on evidence that cannot tell a stopped VM from a lagging tailscaled"
grep -c -- 'wsl.exe --shutdown' "$SSH_LOG" | grep -qx 2 \
  && ok "...and retrying the whole restart on the other alias first" \
  || ko "the capped shutdown did not fall through to the second alias: $(cat "$SSH_LOG")"

# A plain kick has no shutdown to repeat and a second start is idempotent, so a wedged LAN side
# must not cost the box the start its Tailscale alias would have carried (PR #165 round 1, P2).
# The restart path keeps the opposite rule, pinned above: it must NOT fall through.
# The guest must be SILENT here: a guest that answers settles the cap on the spot, and the
# fallback this pins exists only for the case where nothing has answered yet. The poll then fails
# the step (no guest ever answers in this fixture), so the evidence is the start on the second
# alias, not the exit status.
: > "$SSH_LOG"
out=$(hang '^rog-lan :: wsl\.exe -d Ubuntu' "rog-lan rog-nv-win" kick-wsl rog 2>&1)
grep -q 'wsl started on rog (via rog-nv-win)' <<<"$out" \
  && grep -q '^rog-nv-win :: wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ok "a plain kick whose start wedges on one alias is carried by the other" \
  || ko "a wedged plain kick never tried the second alias -- $out; $(cat "$SSH_LOG")"
# And when every alias wedges, the cap is still not a failure: the poll gets the box.
: > "$SSH_LOG"
out=$(hang 'wsl\.exe -d Ubuntu' "rog-lan rog-nv-win" kick-wsl rog 2>&1); rc=$?
[ "$rc" -ne 0 ] && grep -q 'start probe timed out on every alias on rog' <<<"$out" \
  && grep -q 'wsl still down after 0 min on: rog' <<<"${out##*$'\n'}" \
  && ok "...and a kick that wedges on every alias is left to the poll, not called a failed kick (rc=$rc)" \
  || ko "a kick wedged on every alias was not handed to the poll (rc=$rc) -- $out"

# --- one wedged box must not cost its neighbours their restart ----------------------------------
# The second half of the 2026-09-16 damage. The loop over boxes was serialized, so while rog's
# probe hung minix never got a restart at all: its VM sat eleven hours old and the sweep's hip unit
# went red on exactly the stale-dxg condition restart-wsl exists to clear (ludics-lite#60).
: > "$SSH_LOG"
out=$(hang '^rog-(lan|nv-win) :: wsl\.exe' "rog-lan rog-nv-win minix-lan minix-amd-wsl" restart-wsl rog minix 2>&1); rc=$?
grep -q '^minix-lan :: wsl.exe --shutdown$' "$SSH_LOG" && grep -q '^minix-lan :: wsl.exe -d Ubuntu' "$SSH_LOG" \
  && ok "a box whose Windows side wedges does not stop its neighbour getting its restart" \
  || ko "minix never got its restart while rog was wedged: $(cat "$SSH_LOG")"
# rog's own outcome is a shutdown failure -- its capped shutdown is unconfirmed on both aliases,
# which is the P1 rule above -- while minix's is a clean restart. Each box is named for what
# happened to IT; the wedge is not charged to the neighbour.
[ "$rc" -ne 0 ] && grep -q '^wsl up on: minix$' <<<"$out" && grep -q 'wsl restart FAILED on: rog' <<<"$out" \
  && ok "...and the report still names each box's own outcome (rc=$rc)" \
  || ko "the wedged box's outcome was pinned on its neighbour (rc=$rc) -- $out"
# ...and they really are kicked at once, not merely bounded one after another: two boxes wedged
# against a 12s cap cost one cap between them concurrently and two serialized. The numbers have to
# respect the poll's 5s granularity, because a guest probe that misses its first round adds
# exactly one of those to either arm: concurrent is 12s or 17s, serialized 24s or 29s, so 20s is
# the only threshold with a clear margin on both sides. And PROBE_CAP is left at its default --
# shrinking it to a couple of seconds, as the wedge cases above can afford to, is what makes that
# missed round likely in the first place: on a loaded machine the shim's own fork can outlast a 3s
# cap, and the probe then fails for reasons that have nothing to do with what is being measured.
started=$SECONDS
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_WSL_START_CAP=12 \
    SSH_HANG='wsl\.exe -d Ubuntu' SSH_UP="rog-lan minix-lan rog-nv-wsl minix-amd-wsl" \
    "$WL" kick-wsl rog minix 2>&1); rc=$?
elapsed=$((SECONDS - started))
[ "$rc" -eq 0 ] && grep -q '^wsl up$' <<<"$out" \
  && ok "two wedged start probes both fall back to their own guest (rc=$rc)" \
  || ko "the two-box fallback did not end in wsl up (rc=$rc) -- $out"
[ "$elapsed" -lt 20 ] && ok "...costing one cap between them, not one each (${elapsed}s)" \
  || ko "the kick still runs box by box: ${elapsed}s for two boxes against a 12s cap"

# --- a capped call leaves nothing of itself behind ----------------------------------------------
# capped()'s watchdog naps in a child. Killing the watchdog alone left that nap orphaned for the
# rest of its interval -- two minutes, at the default start cap -- holding an inherited copy of
# every descriptor the run had open. Stray processes were the visible half; the half that bites is
# that an inherited descriptor keeps its resource alive after the caller has dropped it, which is
# how this surfaced against the lab lock. The caps here are absurd values (3117/3118/3119) so a
# survivor is unmistakably one of ours and no real sleep can be mistaken for it.
naps() { ps -eo pid,command 2>/dev/null | awk '/sleep 311[789]$/ { print $1 }'; }
reap_naps() { local p; for p in $(naps); do kill -KILL "$p" 2>/dev/null; done; }
# The negative control first: a scan that cannot fail proves nothing. This is exactly the old
# shape -- a watchdog whose sleep runs in its foreground, killed outright -- and it must leave a
# survivor, or the assertion below is vacuous.
reap_naps
( cmd_pid=""; sleep 1 & cmd_pid=$!
  { sleep 3117; } >/dev/null 2>&1 & dog=$!
  wait "$cmd_pid"; kill -KILL "$dog" 2>/dev/null; wait "$dog" 2>/dev/null ) >/dev/null 2>&1
[ "$(naps | wc -l | tr -d ' ')" -ge 1 ] \
  && ok "the stray-nap scan catches a watchdog killed without its sleep" \
  || ko "the stray-nap scan sees nothing even for the leaking shape, so its verdict below is vacuous"
reap_naps
# A restart makes several capped calls -- a shutdown, a start, and the probes around them -- and
# every one of them must come back with its watchdog fully reaped.
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 \
    WAKE_LAB_WSL_SHUTDOWN_CAP=3118 WAKE_LAB_WSL_START_CAP=3117 WAKE_LAB_PROBE_CAP=3119 \
    SSH_UP="rog-lan rog-nv-wsl" "$WL" restart-wsl rog >/dev/null 2>&1
[ "$(naps | wc -l | tr -d ' ')" -eq 0 ] \
  && ok "...and a restart's capped calls leave no nap of their own behind" \
  || ko "a capped call orphaned its watchdog's sleep: $(ps -eo pid,command | awk '/sleep 311[789]$/')"
reap_naps
# The same when the cap actually FIRES: the watchdog is then mid-grace, napping again, and the old
# shape leaked that second sleep just as readily as the first.
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WSL_WAIT_SECONDS=1 WAKE_LAB_WSL_START_CAP=2 \
    WAKE_LAB_WSL_SHUTDOWN_CAP=3118 WAKE_LAB_PROBE_CAP=3119 \
    SSH_HANG='wsl\.exe -d Ubuntu' SSH_UP="rog-lan rog-nv-win" "$WL" restart-wsl rog >/dev/null 2>&1
[ "$(naps | wc -l | tr -d ' ')" -eq 0 ] \
  && ok "...nor does one whose cap fired and whose watchdog was mid-grace" \
  || ko "a fired cap orphaned its grace sleep: $(ps -eo pid,command | awk '/sleep 311[789]$/')"
reap_naps

# --- the lab lock stops a restart destroying someone else's VM ----------------------------------
# 2026-09-16, the third and most expensive shape of the same day: `wsl.exe --shutdown` is
# host-global, so a restart issued while the cross-machine sweep was 13 minutes into rog-nv/cuda
# and minix/hip destroyed both VMs and both units. The sweep recorded `error`, which reads as a box
# fault, and it was misattributed to the GPU autotune tests for two days. The lock is the interlock
# that was missing; these cases pin that it actually refuses, and that it refuses ONLY the
# destructive path.
# Held the way the sweep holds it: a descriptor kept open, flock taken by a perl that exits. The
# lock belongs to the open file description, so it outlives that perl and dies with this shell --
# which is the property the whole contract rests on, so take it here exactly as the real holder does
# rather than simulating a held lock with a flag file.
hold_lock() { # hold_lock <box> <description>
  printf '%s\n' "$2" > "$LOCKS/$1.lock"
  eval "exec $3>>\"$LOCKS/$1.lock\""
  perl -e 'use Fcntl ":flock"; exit(flock(STDIN, LOCK_EX | LOCK_NB) ? 0 : 1)' <&"$3"
}
wl_locked() { # wl_locked <args...> -- a run with both boxes' guests answering and the lock dir live
  # `8>&-`: the checker must not inherit the HOLDER's descriptor. An flock lives until every
  # descriptor onto that open file description is closed, so a child that inherited one keeps the
  # lock alive after the holder let go -- and wake-lab's own `capped` leaves its watchdog `sleep`
  # orphaned for the length of the cap, which would hold this test's lock for two minutes after
  # `exec 8>&-`. In production the checker is a separate process that never had the descriptor at
  # all, so closing it here is what models the real thing; the case below pins the property itself.
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_WSL_WAIT_SECONDS=1 \
      SSH_UP="rog-lan minix-lan rog-nv-wsl minix-amd-wsl" "$WL" "$@" 2>&1 8>&-
}
if hold_lock minix 'sweep 20260916T074913Z (pid 999, since 20260916T074913Z)' 8; then
  ok "the lab lock can be taken the way a harness takes it"
else
  ko "could not take a test lab lock -- the cases below prove nothing"
fi

: > "$SSH_LOG"
out=$(wl_locked restart-wsl rog minix); rc=$?
grep -q '^minix-lan :: wsl.exe --shutdown$' "$SSH_LOG" \
  && ko "a held box was shut down anyway -- the interlock does not hold: $(cat "$SSH_LOG")" \
  || ok "a restart does not shut down a box whose lab lock is held"
[ "$rc" -ne 0 ] && grep -q 'REFUSED on: minix' <<<"$out" \
  && ok "...and the step FAILS rather than reporting a fresh VM it did not make (rc=$rc)" \
  || ko "a refused box did not fail the step (rc=$rc) -- $out"
grep -q 'sweep 20260916T074913Z' <<<"$out" \
  && ok "...and the refusal names the holder, so the operator knows what to wait for" \
  || ko "the refusal does not say who holds the box -- $out"
# The neighbour rule of the wedge cases above, applied to the lock: one held box must not cost the
# others their restart, and `wsl up` must never appear unqualified over a box that was refused.
grep -q '^rog-lan :: wsl.exe --shutdown$' "$SSH_LOG" \
  && ok "...and its neighbour still gets its restart" \
  || ko "a held box cost its neighbour the restart: $(cat "$SSH_LOG")"
grep -q '^wsl up$' <<<"$out" \
  && ko "the run claimed a blanket 'wsl up' over a refused box -- $out" \
  || ok "...and the verdict is never a blanket 'wsl up' while a box was refused"

# --force is the override, and it is the ONLY thing that takes a held box.
: > "$SSH_LOG"
out=$(wl_locked restart-wsl --force minix); rc=$?
[ "$rc" -eq 0 ] && grep -q '^minix-lan :: wsl.exe --shutdown$' "$SSH_LOG" \
  && ok "--force takes a held box anyway (rc=$rc)" \
  || ko "--force did not override the lock (rc=$rc) -- $out"

# A plain kick starts a VM that is already running as a no-op: it cannot cost a holder anything,
# and gating it would make `kick-wsl` -- the recovery command for a box with no VM at all --
# refusable at exactly the moment it is needed.
: > "$SSH_LOG"
out=$(wl_locked kick-wsl minix); rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'shutdown' "$SSH_LOG" \
  && ok "a plain kick is not gated by the lock, and still shuts nothing down (rc=$rc)" \
  || ko "the lock gated a non-destructive kick (rc=$rc) -- $out $(cat "$SSH_LOG")"

# A free box is the ordinary case and must be untouched by any of this.
: > "$SSH_LOG"
out=$(wl_locked restart-wsl rog); rc=$?
[ "$rc" -eq 0 ] && grep -q '^wsl up$' <<<"$out" \
  && ok "a box whose lock is free restarts exactly as before (rc=$rc)" \
  || ko "the lock broke the ordinary restart (rc=$rc) -- $out"

# An INHERITED descriptor holds the lock too, and that is the semantics to want rather than a
# wart: a child still talking to the box means the box is still in use, so it stays reserved. It is
# also the sweep's own run lock's behaviour, where an orphaned dune keeping the worktree locked is
# documented as correct. The consequence to know is that a holder's lock outlives it for as long as
# any inheriting child runs, and `--force` is the way past one that has outstayed its welcome.
sleep 30 8>&8 &
inheritor=$!
exec 8>&-
out=$(wl_locked restart-wsl minix); rc=$?
[ "$rc" -ne 0 ] && grep -q 'REFUSED on: minix' <<<"$out" \
  && ok "a child that inherited the descriptor keeps the box reserved (rc=$rc)" \
  || ko "the lock died while an inheriting child was still running (rc=$rc) -- $out"
expect "...and --force is the way past it" 0 "wsl up" -- \
  env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_WSL_WAIT_SECONDS=1 \
      SSH_UP="rog-lan minix-lan rog-nv-wsl minix-amd-wsl" "$WL" restart-wsl --force minix

# Released with the holder: the sweep's lock dies with the sweep however it dies, which is why
# there is nothing to reclaim after a crash.
kill -KILL "$inheritor" 2>/dev/null; wait "$inheritor" 2>/dev/null
out=$(wl_locked restart-wsl minix); rc=$?
[ "$rc" -eq 0 ] \
  && ok "...and a lock whose holders are all gone stops refusing, with nothing to reclaim (rc=$rc)" \
  || ko "a released lock still refuses (rc=$rc) -- $out"

# The reservation is HELD ACROSS the shutdown, not checked before it. A restarter that only probes
# the lock leaves a window between its check and its `wsl.exe --shutdown` — and a holder that
# reserves the box inside that window is destroyed by a restart that had already decided it was
# allowed to proceed, which is the exact race the interlock exists to close. Observed from the far
# side: the ssh shim tests the lock at the instant the shutdown is issued.
: > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_WSL_WAIT_SECONDS=1 \
    SSH_UP="rog-lan minix-lan rog-nv-wsl minix-amd-wsl" LOCK_PROBE="$LOCKS/rog.lock" \
    "$WL" restart-wsl rog 2>&1 8>&-); rc=$?
grep -q '^lock HELD during .*--shutdown$' "$SSH_LOG" \
  && ok "the box stays reserved for the length of its own restart (rc=$rc)" \
  || ko "the lock was free when the shutdown landed — the check/act race is open: $(cat "$SSH_LOG")"

# Power actions take the box away just as surely: hibernate terminates the VM outright, `down` is a
# full host shutdown, and `sleep` suspends the host under whatever is running on it.
if hold_lock minix 'sweep 20260916T074913Z (pid 999, since 20260916T074913Z)' 8; then
  ok "the lab lock can be retaken for the power-action cases"
else
  ko "could not retake a test lab lock -- the power cases below prove nothing"
fi
for verb in hibernate down sleep; do
  : > "$SSH_LOG"
  out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_DOWN_WAIT_SECONDS=0 \
      SSH_UP="minix-lan minix-amd-win" "$WL" "$verb" minix 2>&1 8>&-); rc=$?
  if [ "$rc" -ne 0 ] && grep -q "$verb REFUSED on: minix" <<<"$out" && ! grep -q 'shutdown /\|SetSuspendState' "$SSH_LOG"; then
    ok "$verb refuses a reserved box, and sends nothing (rc=$rc)"
  else
    ko "$verb went through on a reserved box (rc=$rc) -- $out $(cat "$SSH_LOG")"
  fi
done
# ...and a refused box is not then polled for the DOWN signal, which would report the holder's
# live machine as a failure to go down.
grep -q 'confirming' <<<"$out" \
  && ko "a refused box was polled for the down signal -- $out" \
  || ok "...and a refused box is not confirmed down"
# --force is the same override here as everywhere else.
: > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_DOWN_WAIT_SECONDS=0 \
    SSH_UP="minix-lan minix-amd-win" "$WL" hibernate --force minix 2>&1 8>&-); rc=$?
grep -q 'shutdown /h' "$SSH_LOG" \
  && ok "--force hibernates a reserved box anyway (rc=$rc)" \
  || ko "--force did not override the lock for a power action (rc=$rc) -- $out $(cat "$SSH_LOG")"
# A free box is unaffected.
: > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_DOWN_WAIT_SECONDS=0 \
    SSH_UP="rog-lan rog-nv-win" "$WL" hibernate rog 2>&1 8>&-); rc=$?
grep -q 'shutdown /h' "$SSH_LOG" && grep -q 'confirming' <<<"$out" \
  && ok "a box whose lock is free hibernates exactly as before (rc=$rc)" \
  || ko "the lock broke the ordinary power action (rc=$rc) -- $out $(cat "$SSH_LOG")"
exec 8>&-

# The reservation spans the EFFECT, not the command. A dropped ssh means the suspend was
# INITIATED; until the box actually goes down it still answers, so a reservation released when
# `power_action` returns lets another harness take the lock and start work the pending transition
# destroys. Observed the same way as the restart race: the shim tests the lock as each command is
# issued, and the CONFIRMATION probes come after the power command — so the last reading is the one
# that says whether the box was still reserved while it was going down.
: > "$SSH_LOG"
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_DOWN_WAIT_SECONDS=0 \
    SSH_UP="rog-lan rog-nv-win" LOCK_PROBE="$LOCKS/rog.lock" \
    "$WL" hibernate rog 2>&1 8>&-); rc=$?
grep -q 'shutdown /h' "$SSH_LOG" \
  && ok "a free box is hibernated (rc=$rc)" \
  || ko "the power action never went out (rc=$rc) -- $out $(cat "$SSH_LOG")"
# More than one reading (so the confirmation really did probe after the power command), and not
# one of them free.
[ "$(grep -c '^lock ' "$SSH_LOG")" -gt 1 ] && ! grep -q '^lock FREE' "$SSH_LOG" \
  && ok "...and stays reserved through the confirmation, not just the command" \
  || ko "the reservation was released before the box was down: $(grep '^lock ' "$SSH_LOG")"

# Every reservation belongs to the process that ACTS, not to a chain of ancestors. An earlier
# version reserved box N at recursion level N, each level a subshell, so killing the top-level
# command released the FIRST box's lock while the surviving descendant went on issuing and
# confirming its suspend — freeing a box whose power transition was still pending, which is the
# whole hazard the reservation exists to prevent. Killing the command must free every box or none.
lock_free() { # lock_free <box> — true iff nothing holds that box's lock
  [ -e "$LOCKS/$1.lock" ] || return 0
  perl -e 'use Fcntl ":flock"; exit(flock(STDIN, LOCK_EX | LOCK_NB) ? 0 : 1)' <"$LOCKS/$1.lock" 2>/dev/null
}
: > "$SSH_LOG"
env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_LOCK_DIR="$LOCKS" WAKE_LAB_DOWN_WAIT_SECONDS=60 \
    SSH_UP="rog-lan rog-nv-win minix-lan minix-amd-win" \
    "$WL" hibernate rog minix >"$TMP/phase.out" 2>&1 8>&- &
phase_pid=$!
# Wait for the phase to have reserved both boxes and reached its confirmation loop.
phase_deadline=$((SECONDS + 20))
while lock_free rog || lock_free minix; do
  [ "$SECONDS" -ge "$phase_deadline" ] && break
  sleep 1
done
if ! lock_free rog && ! lock_free minix; then
  ok "a multi-box power command reserves every box it acts on"
else
  ko "the phase did not hold both boxes (rog free=$(lock_free rog && echo yes || echo no), minix free=$(lock_free minix && echo yes || echo no))"
fi
kill "$phase_pid" 2>/dev/null
wait "$phase_pid" 2>/dev/null
# A moment for any child that inherited the descriptors to go with it -- confirm_down's `sleep` is
# one, and the inherited-descriptor rule above is why it counts.
kill_deadline=$((SECONDS + 20))
while ! lock_free rog || ! lock_free minix; do
  [ "$SECONDS" -ge "$kill_deadline" ] && break
  sleep 1
done
if lock_free rog && lock_free minix; then
  ok "...and killing it frees every one of them, not just the outermost"
else
  ko "a box stayed reserved after the command was killed (rog free=$(lock_free rog && echo yes || echo no), minix free=$(lock_free minix && echo yes || echo no))"
fi

# The path is the whole contract with the sweep, so it must not need the site table: the harness
# asking where to put its flock runs from a checkout with no business holding this lab's MACs.
out=$(env WAKE_LAB_HOSTS="$TMP/absent.sh" WAKE_LAB_LOCK_DIR="$LOCKS" "$WL" lock-path minix 2>&1); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "$LOCKS/minix.lock" ] \
  && ok "lock-path answers without the site file, at the path the holder must take (rc=$rc)" \
  || ko "lock-path did not answer the contract path without hosts.sh (rc=$rc) -- $out"

# Everything above this line is what reserves: every `restart-wsl`, every power command, every
# lock case. Check here as well as at the end, so an escape is attributed to that region.
lab_untouched "the restart, power and lock cases"

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
out=$(env WAKE_LAB_HOSTS="$TMP/hosts.sh" WAKE_LAB_WAIT_SECONDS=1 SSH_DELAY=3 "$WL" --wait rog 2>&1); wake_rc=$?
elapsed=$((SECONDS - started))
[ "$elapsed" -lt 30 ] && ok "...and so does the wake wait (${elapsed}s)" \
  || ko "the wake wait ran ${elapsed}s against a 1s budget: it is still counting iterations"
grep -q 'did NOT wake: rog' <<<"$out" \
  && ok "...reporting the box that never came up" || ko "no 'did NOT wake' after the budget -- $out"
grep -q 'scripts/enable-wol-windows.ps1' <<<"$out" \
  && ok "...and points failure advice at the tracked Windows repair script" \
  || ko "wake failure advice does not name scripts/enable-wol-windows.ps1 -- $out"
[ "$wake_rc" -ne 0 ] && ok "...and exits nonzero (rc=$wake_rc)" || ko "a wake that timed out exited 0"

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
  || ko "--help is not the header block: $(diff <(printf '%s\n' "$head_block") <(printf '%s\n' "$help_out") | sed -n '1,5p')"
grep -q 'set -u' <<<"$help_out" \
  && ko "--help ran past the header into the script" || ok "...and stops at the first non-comment line"
[ "$(printf '%s\n' "$head_block" | wc -l)" -gt 19 ] \
  && ok "...on a header already longer than the old 2,20p range" \
  || ko "the header is short enough that the old truncating range would still pass; the guard above proves nothing"

# --- the example table is a working one ---------------------------------------------------------
expect "the example host table satisfies the contract" 0 "router-active=1" -- \
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

lab_untouched "the suite as a whole"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
