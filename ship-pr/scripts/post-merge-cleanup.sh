#!/usr/bin/env bash
# Safely remove a merged topic worktree and branch after ship-pr has confirmed the PR is merged.
#
#   post-merge-cleanup.sh <main-checkout> <session-worktree> <branch> [options]
#
# Run with no arguments for the options. Since the v2 rewrite (ludics-lite#403) the helper is
# lib/ludics/postmergecleanup, run through scripts/py (the first Python >= 3.12 on the box); this
# file is its entry point and forwards the whole command line, so the command, its options, its
# output and its exit statuses are what they were. Every gate, ordering and message, and the
# history behind each, is documented there; test-post-merge-cleanup.sh is the conformance suite.

set -uo pipefail

# Bash reads a script file by offset while it runs, so rewriting this file mid-run resumes the
# shell at a shifted offset (ludics-lite#10). The body is one brace group, parsed whole before its
# first command runs, and the closing exit means nothing past it is ever read. CI checks that the
# file still ends in `exit "$?"` and `}` (scripts/check-parse-guards.sh).
{
# Physically, BEFORE going up: the skills call this file through a symlinked skill directory
# (~/.claude/skills/ship-pr -> <checkout>/ship-pr), and a logical `cd .../../..` would climb out of
# the link into ~/.claude/skills instead of into the checkout.
py="$(CDPATH= cd -P "$(dirname "$0")" && cd -P ../.. && pwd -P)/scripts/py"
if [ ! -x "$py" ]; then
  printf '%s\n' "post-merge-cleanup.sh: the helper is served by Python since ludics-lite#403, and its runner $py is missing or not executable: this copy is not inside a ludics-lite checkout; nothing was read or written" >&2
  exit 1
fi
# Under Git Bash the interpreter is a native Windows program, and an MSYS process that execs one
# stays alive beside it with its working directory. One sitting in the session worktree would
# keep Windows from renaming the session into its archive (ludics-lite#393), so the forwarder
# leaves for the filesystem root and hands the caller's directory over to restore. TMPDIR goes
# over in a variable of its own: MSYS rewrites TMPDIR itself for a native program, which roots a
# relative one.
case "$(uname -s 2>/dev/null)" in
MINGW* | MSYS* | CYGWIN*)
  LUDICS_CALLER_CWD=$(cygpath -m "$PWD") || exit 1
  export LUDICS_CALLER_CWD
  if [ -n "${TMPDIR:-}" ]; then
    LUDICS_CALLER_TMPDIR=$(cygpath -m "$TMPDIR") || exit 1
    export LUDICS_CALLER_TMPDIR
  fi
  cd / || exit 1
  ;;
esac
# Python coerces a C locale (PEP 538) by exporting LC_CTYPE=C.UTF-8, which Git, its hooks and the
# helper's %q rendering would all read; the caller's LC_CTYPE goes over to be restored: empty when
# it was unset, else `=` and its value.
LUDICS_CALLER_LC_CTYPE="${LC_CTYPE+=}${LC_CTYPE-}"
export LUDICS_CALLER_LC_CTYPE
exec "$py" -m ludics.postmergecleanup "$@"
exit "$?"
}
