"""pr-review.sh, ported one subcommand at a time (ludics-lite#403).

``core`` is the shared prelude; each ported subcommand is a module named after it, exposing
``run(session, args) -> int``, and ``__main__`` dispatches to it. The shell script stays the
entry point: it validates the source-time knobs and forwards every subcommand here.
"""
