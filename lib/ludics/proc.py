"""Starting external programs: the one place in the package that does.

Every external tool -- ``gh``, ``git`` -- is run as a BINARY resolved on PATH, never replaced by an
HTTP client or a library, so the fixtures that drive the shell scripts drive the Python too: a
fake ``gh`` first on PATH answers both.

The shell bridge. The pr-review suites do not put a fake ``gh`` on PATH: they SOURCE the script
and define ``gh`` as a shell FUNCTION, whose answers read the suite's own variables. A Python
process cannot call a function of the shell that started it, so the shell's forwarder (``py_forward``
in pr-review.sh) hands it the next best thing when, and only when, one of the commands it would
run is a shell function there:

  LUDICS_BRIDGE_FUNCS  the names that are functions in the forwarding shell (``gh git``);
  LUDICS_BRIDGE_STATE  a file holding that shell's functions and variables (``declare -f``,
                       ``declare -p``) and its ``-u``/``pipefail`` options;
  LUDICS_BRIDGE_SHELL  that shell's own bash (``$BASH``), so the file is read by the bash that
                       wrote it -- bash 3.2's output in bash 3.2.

A bridged call runs ``<bash> -c '. <state>; <name> "$@"'``: a fresh shell holding the same
definitions and values the forwarder's shell had, which is what the shell implementation's
``$(gh ...)`` saw -- it, too, ran every gh call in a subshell, so a fixture already keeps
anything that must outlive one call in a FILE. With none of the three set, which is every
production run, a tool is the binary on PATH and nothing else.
"""

import os
import shutil
import subprocess
from collections.abc import Mapping, Sequence
from dataclasses import dataclass

BRIDGE_FUNCS = "LUDICS_BRIDGE_FUNCS"
BRIDGE_STATE = "LUDICS_BRIDGE_STATE"
BRIDGE_SHELL = "LUDICS_BRIDGE_SHELL"


@dataclass(frozen=True)
class Completed:
    """A finished process: its status and both streams, decoded as UTF-8 with surrogateescape so
    any bytes round-trip back out unchanged."""

    rc: int
    stdout: str
    stderr: str


def decode(data: bytes) -> str:
    return data.decode("utf-8", "surrogateescape")


def bridge_argv(name: str, args: Sequence[str], env: Mapping[str, str]) -> list[str] | None:
    """The argv that runs ``name`` through the shell bridge, or None when it is not bridged."""
    funcs = env.get(BRIDGE_FUNCS, "").split()
    state = env.get(BRIDGE_STATE, "")
    shell = env.get(BRIDGE_SHELL, "")
    if name not in funcs or not state or not shell:
        return None
    # The state's own errors (a readonly variable it cannot reassign) are the bridge's, not the
    # tool's: they must not reach the stderr the caller classifies.
    script = '. "$1" 2>/dev/null; shift; ' + name + ' "$@"'
    return [shell, "-c", script, name, state, *args]


def run_tool(
    name: str,
    args: Sequence[str],
    *,
    env: Mapping[str, str] | None = None,
    cwd: str | None = None,
    stdin: bytes | None = None,
) -> Completed:
    """Run the tool ``name`` with ``args``, capturing both streams; stdin is inherited, or is
    ``stdin`` when one is given (a shell ``printf '%s' "$x" | tool``).

    A tool that is not on PATH completes with 127 and the shell's message, as ``gh`` would have
    in the shell implementation, so callers classify it the same way.
    """
    environ = dict(os.environ if env is None else env)
    argv = bridge_argv(name, args, environ)
    if argv is None:
        exe = shutil.which(name, path=environ.get("PATH"))
        if exe is None:
            return Completed(127, "", f"{name}: command not found\n")
        argv = [exe, *args]
    proc = subprocess.run(argv, capture_output=True, env=environ, cwd=cwd, check=False, input=stdin)
    return Completed(proc.returncode, decode(proc.stdout), decode(proc.stderr))


def substitution(text: str) -> str:
    """What the shell's ``$(...)`` keeps of a command's output: every trailing newline dropped."""
    return text.rstrip("\n")
