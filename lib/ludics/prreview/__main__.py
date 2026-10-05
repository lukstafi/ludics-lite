"""``scripts/py -m ludics.prreview [--repo owner/name] <subcommand> <args...>``

What pr-review.sh's forwarder runs for a subcommand in its ``PY_PORTED`` set, with the same
arguments and the shell's resolved constants in the environment (``PY_FORWARD_VARS``). The shell
has already taken its own ``--repo`` off; it is accepted here too so the module can be run
directly.

Adding a subcommand: a module ``ludics/prreview/<name>.py`` with ``run(session, args) -> int``,
a ``case "<name>":`` below, and the name in the shell's ``PY_PORTED``.
"""

import os
import sys

from ludics import cli
from ludics.prreview.core import PROG, GhSession, die, load_config

PORTED = ("body",)


def dispatch(argv: list[str]) -> int:
    env = dict(os.environ)
    args = list(argv)
    if args and args[0] == "--repo":
        if len(args) < 2 or not args[1]:
            die("--repo owner/name")
        env["REPO"] = args[1]
        args = args[2:]
    elif args and args[0].startswith("--repo="):
        env["REPO"] = args[0][len("--repo=") :]
        args = args[1:]
    session = GhSession(load_config(env))
    sub = args[0] if args else ""
    rest = args[1:]
    match sub:
        case "body":
            from ludics.prreview import body

            return body.run(session, rest)
        case _:
            die(
                f"'{sub}' is not a subcommand ported to Python (ported: {' '.join(PORTED)});",
                "run it through pr-review.sh, which serves every subcommand.",
            )


def main() -> int:
    return cli.main_guard(PROG, dispatch, sys.argv[1:])


if __name__ == "__main__":
    sys.exit(main())
