"""``scripts/py -m ludics.postmergecleanup <main-checkout> <session-worktree> <branch> [options]``

What ``ship-pr/scripts/post-merge-cleanup.sh`` runs, with its whole command line. Before anything
else, as the shell did, the environment is cleared of every repository-selection variable Git
names (``git rev-parse --local-env-vars``): they take precedence over ``-C`` and could redirect both
reads and mutations away from the checkouts named on the command line. Replacement objects are
disabled for every proof. The reservations a run takes are released on every way out -- a
refusal, an error, SIGINT, SIGTERM or SIGHUP -- as the shell's EXIT trap released them.
"""

import os
import signal
import sys
from types import FrameType

from ludics import cli
from ludics.postmergecleanup import system
from ludics.postmergecleanup.cleanup import Cleanup
from ludics.postmergecleanup.options import PROG

# The caller's working directory, handed over by the shell forwarder under Git Bash, which runs
# this native interpreter from a neutral directory: an MSYS process that execs a native program
# stays alive beside it, and one whose working directory is the session would keep Windows from
# renaming the session into its archive (ludics-lite#393).
CALLER_CWD = "LUDICS_CALLER_CWD"


class Signalled(BaseException):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def on_signal(signum: int, _frame: FrameType | None) -> None:
    raise Signalled(signum)


def scrub_git_environment() -> bool:
    done = system.git("rev-parse", "--local-env-vars", out="capture", err="devnull")
    if done.rc != 0:
        return False
    for name in done.out.split():
        os.environ.pop(name, None)
    os.environ["GIT_NO_REPLACE_OBJECTS"] = "1"
    if os.name == "nt":
        # ludics-lite#393: recovery ref names and their locks run past MAX_PATH in a deep
        # checkout; Git for Windows handles them only with core.longpaths.
        os.environ["GIT_CONFIG_COUNT"] = "1"
        os.environ["GIT_CONFIG_KEY_0"] = "core.longpaths"
        os.environ["GIT_CONFIG_VALUE_0"] = "true"
    return True


def run(argv: list[str]) -> int:
    caller_cwd = os.environ.pop(CALLER_CWD, "")
    if caller_cwd and not system.chdir(caller_cwd):
        raise cli.Exit(1, f"could not return to the caller's working directory: {caller_cwd}")
    if not scrub_git_environment():
        raise cli.Exit(1, "could not enumerate Git repository-selection environment")
    cleanup = Cleanup()
    try:
        return cleanup.run(argv)
    finally:
        cleanup.release()


def main() -> int:
    for signum in (signal.SIGTERM, getattr(signal, "SIGHUP", None)):
        if signum is not None:
            signal.signal(signum, on_signal)
    try:
        return cli.main_guard(PROG, run, sys.argv[1:])
    except (Signalled, KeyboardInterrupt) as stop:
        signum = stop.signum if isinstance(stop, Signalled) else int(signal.SIGINT)
        if os.name != "nt":
            # Die of the signal, as the shell did once its trap had run.
            signal.signal(signum, signal.SIG_DFL)
            os.kill(os.getpid(), signum)
        return 128 + signum


if __name__ == "__main__":
    sys.exit(main())
