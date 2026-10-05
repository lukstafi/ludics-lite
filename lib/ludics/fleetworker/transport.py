"""Reaching a box: the far-side shell scripts, and how they travel (fleet-worker.sh's ``run_on``).

The coordination verbs keep fleet-worker.sh's FAR SIDE as it was: a bash script, composed here and
read by ``bash -s`` on the box -- a local child for this box (``is_local``), ``ssh <box> bash -s``
for any other -- with its arguments as positional parameters. Only the near side moved to Python
(ludics-lite#403). That keeps one implementation of the anchor's lease lock (``take_lock``, a mkdir
lock recording its holder's pid and start time), which the verbs still in shell -- launch, unstick,
close -- take on the same anchor, and it keeps every far-side line the boxes run exactly what they
ran: what is ported is what the coordinator decides around them.

``prelude`` is the part of the shell's ``prelude`` these scripts read: the paths, BOX, and the lock
helpers (``now``, ``mtime``, ``proc_start``, ``take_lock``, ``release_lock``), byte for byte the
shell's. ``run`` starts a process with a script on its stdin and the far side's stderr passed
through, which ``ludics.proc.run_tool`` (captured streams, inherited stdin) does not offer.
"""

import shlex
import shutil
import subprocess
import sys
from collections.abc import Mapping, Sequence
from dataclasses import dataclass

from ludics.fleetworker.config import Config

SSH_OPTS = [
    "-o", "BatchMode=yes",
    "-o", "ConnectTimeout=15",
    "-o", "ServerAliveInterval=30",
    "-o", "ServerAliveCountMax=4",
]  # fmt: skip

# ssh's own transport failure; a local child cannot produce it, so it always means the box never
# answered and the caller may retry rather than conclude anything.
UNREACHABLE = 255


@dataclass(frozen=True)
class Done:
    """A finished far-side run: its status, and its stdout when it was captured (else empty)."""

    rc: int
    out: str

    @property
    def unreachable(self) -> bool:
        return self.rc == UNREACHABLE


# SHARED-CANDIDATE: is_local
def is_local(cfg: Config, box: str) -> bool:
    return box == "local" or (cfg.local_box != "" and box == cfg.local_box)


# SHARED-CANDIDATE: fleet_name
def fleet_name(cfg: Config, box: str) -> str:
    """A configured box as a fleet name: ``local`` is this box's own name, when it has one."""
    return cfg.local_box if box == "local" and cfg.local_box else box


# SHARED-CANDIDATE: emit_var
def emit_var(name: str, value: str) -> str:
    """A far-side assignment: a leading literal ``$HOME/`` stays expandable there, the rest quoted."""
    if value.startswith("$HOME/"):
        return f'{name}="$HOME"/{shlex.quote(value[len("$HOME/") :])}\n'
    return f"{name}={shlex.quote(value)}\n"


_HELPERS = r"""set -uo pipefail
expand_tilde() { case "$1" in '~/'*) printf '%s' "$HOME/${1#\~/}" ;; '~') printf '%s' "$HOME" ;; *) printf '%s' "$1" ;; esac; }
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
now() { date +%s; }
# take_lock <dir> <wait-seconds> <label>: a mkdir lock that records its holder's pid, so a lock
# left by a killed shell or a rebooted box is reclaimed instead of wedging the name forever.
# Prints nothing on success; on failure prints one line and returns 1. Release with rmdir.
# The holder is identified by pid AND process start time: after a reboot (or plain pid reuse)
# the recorded pid may belong to an unrelated live process, which a bare kill -0 would treat
# as the holder forever.
proc_start() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }
take_lock() {
  local lock="$1" wait="$2" label="$3" waited=0 holder hstart
  until mkdir "$lock" 2>/dev/null; do
    [ -d "$lock" ] || { echo "$label: cannot create lock $lock (unwritable?)"; return 1; }
    holder=$(cat "$lock/pid" 2>/dev/null); hstart=$(cat "$lock/start" 2>/dev/null)
    if [ -n "$holder" ] && { ! kill -0 "$holder" 2>/dev/null || [ "$(proc_start "$holder")" != "$hstart" ]; }; then
      rm -f "$lock/pid" "$lock/start"; rmdir "$lock" 2>/dev/null; continue   # dead or reused pid: reclaim
    fi
    # No owner recorded: registration takes milliseconds, so an ownerless lock older than 30 s
    # was left by a shell that died between mkdir and the pid write. Reclaim it.
    if [ -z "$holder" ] && [ $(( $(now) - $(mtime "$lock") )) -gt 30 ]; then
      rm -f "$lock/pid" "$lock/start"; rmdir "$lock" 2>/dev/null; continue
    fi
    [ "$waited" -lt "$wait" ] || { echo "$label: lock $lock held ${holder:+by pid $holder }for ${wait}s -- another operation in progress"; return 1; }
    sleep 1; waited=$((waited + 1))
  done
  # start before pid: a contender that sees a pid without its start time would otherwise read
  # the mismatch as a reused pid and reclaim a lock that is being taken right now.
  proc_start $$ > "$lock/start"; echo $$ > "$lock/pid"
}
release_lock() { rm -f "$1/pid" "$1/start"; rmdir "$1" 2>/dev/null; }
"""


# SHARED-CANDIDATE: prelude
def prelude(cfg: Config, box: str) -> str:
    """What every far-side script here starts with: BOX is the name the coordinator addressed the
    box by, so every line it prints is greppable by that name."""
    return (
        emit_var("STATE", cfg.state)
        + emit_var("SKILLS_REPO", cfg.skills_repo)
        + emit_var("ANCHOR_STATE", cfg.anchor_state)
        + f"TMUX_SOCKET={shlex.quote(cfg.tmux_socket)}\n"
        + f"BOX={shlex.quote(box)}\n"
        + f"FEEDER_WAIT={shlex.quote(cfg.feeder_wait)}\n"
        + f"BOX_IS_LOCAL={1 if is_local(cfg, box) else 0}\n"
        + _HELPERS
    )


def run(
    argv: Sequence[str],
    *,
    stdin: bytes | None = None,
    capture: bool = False,
    stdout_to_stderr: bool = False,
    env: Mapping[str, str] | None = None,
) -> Done:
    """Start ``argv``; stderr is the caller's. stdin is ``stdin`` when given (else inherited), stdout
    captured, sent to our stderr (the shell's ``>&2``), or the caller's. A program that cannot be
    started completes 127, as the shell's would."""
    sys.stdout.flush()
    sys.stderr.flush()
    out = subprocess.PIPE if capture else (sys.stderr.fileno() if stdout_to_stderr else None)
    try:
        proc = subprocess.run(
            list(argv),
            input=stdin,
            stdout=out,
            env=None if env is None else dict(env),
            check=False,
        )
    except OSError as exc:
        sys.stderr.write(f"{argv[0]}: {exc.strerror}\n")
        return Done(127, "")
    text = proc.stdout.decode("utf-8", "surrogateescape") if capture else ""
    return Done(proc.returncode, text)


# SHARED-CANDIDATE: run_on
def run_on(cfg: Config, box: str, script: str, args: Sequence[str], *, capture: bool = False) -> Done:
    """Run ``script`` (on stdin) on the box, ``args`` as its $1..: a local ``bash -s`` here, ``bash -s``
    over ssh for any other box, its arguments quoted for the remote login shell (bash on every box)."""
    if is_local(cfg, box):
        argv = [shutil.which("bash") or "/bin/bash", "-s", "--", *args]
    else:
        quoted = "".join(" " + shlex.quote(a) for a in args)
        argv = [shutil.which("ssh") or "ssh", *SSH_OPTS, box, "bash -s --" + quoted]
    return run(argv, stdin=script.encode("utf-8", "surrogateescape"), capture=capture)


def err(text: str) -> None:
    """A line on stderr as the shell's ``echo ... >&2`` wrote it: no prefix, after any stdout."""
    sys.stdout.flush()
    sys.stderr.write(text + "\n")
    sys.stderr.flush()


def substitution(text: str) -> str:
    """What the shell's ``$(...)`` keeps of a command's output: every trailing newline dropped."""
    return text.rstrip("\n")

