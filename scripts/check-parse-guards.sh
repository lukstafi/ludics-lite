#!/usr/bin/env bash
# Refuse a test suite that bash would read past while it runs: a `test-*.sh` that is not one brace
# group ending in `exit "$?"` and `}`.
#
# Bash reads a script file by OFFSET while it runs. It parses one complete command, runs it, then
# comes back to the file for the next one — so a file rewritten mid-run resumes the shell at the
# offset it left off at, in the middle of whatever text now sits there. Editing a suite while a run
# of it is in flight is not exotic: the suites here take minutes, and an agent iterating on one is
# doing exactly that. It has cost this repo twice. `test-post-merge-cleanup.sh` lost two runs to it,
# which removed the scratch root under cases still running (ludics-lite#10); `test-fleet-worker.sh`
# died mid-run with a syntax error at a line whose text was fine, and four minutes went to proving
# the error was the edit landing mid-parse and not a defect in the change (ludics-lite#247).
#
# One brace group around the whole body answers it. The group is a single command, so the file is
# parsed WHOLE before its first line runs; the `exit` on the way out means the shell never returns
# to the file for a next command, so there is no offset to resume at. Both halves are load-bearing:
# the group alone still leaves the shell reading past the closing `}` at EOF, and an `exit` without
# the group only protects the tail of the file.
#
# THE HOUSE SHAPE, and why this one. The alternative — `main() { … }` with `main "$@"` at the foot —
# parses the body whole too, and then hands the shell back to the file for the `main "$@"` line and
# for anything after it, AFTER the minutes that the run takes. That is the same window, at the worst
# possible moment: the file has been open for editing for the whole of the run. The brace group's
# `exit` closes it. The group is also what the two files armored in ludics-lite#10 already carry, so
# adopting it here means one shape and one guard rather than two of each, and no suite had to be
# re-indented to take it (the body keeps its original indentation; the wrapper is two lines at the
# top and two at the foot).
#
# A suite that is also SOURCED by a sibling takes the same shape. `test-pr-review-lib.sh` and
# `test-pr-review-base-lib.sh` dispatch on `[ "${BASH_SOURCE[0]}" = "$0" ] || return 0` partway
# down: inside the group, that `return` ends the sourcing before the trailing `exit` is ever
# reached, so the caller survives (checked on bash 3.2, and by the suites themselves) while the
# sourcing shell has still parsed the file whole.
#
# THE PREAMBLE, and why the group is allowed to open below one. A suite that sources a sibling
# library must do it ABOVE the group, not inside it. Bash binds the location `declare -F` reports
# for a function when it PARSES the definition, so in a group that also holds the sources every
# definition in the suite is parsed before the libraries are read, the libraries' bindings land
# last, and the ludics-lite#46 shadow guard — which compares each protected function against the
# file and line its owner recorded — reads every suite function as still the library's. It then
# refuses a declared `stub` (test-pr-review-merge.sh and test-pr-review-watch.sh both went red
# that way while this guard was being written) and, the half that says nothing, ACCEPTS an
# undeclared shadow: the case ludics-lite#46 exists for. Sourcing above the group puts the
# definitions back after the libraries, which is where they were before any of this.
#
# What a preamble costs is the window between the first line and the `{`: those commands run
# before the rest of the file is parsed. It is a `cd` and a `source` or two, and it is bounded —
# the file is whole before the first CASE runs, which is where the minutes are.
#
# THE RULES, per file. Line shapes where a line shape says it, bash's own parser where it does not:
#   1. the last two lines are exactly `exit "$?"` and `}`;
#   2. the first COMMAND in the file is `{` on a line of its own, or the first below a preamble.
#      What may stand above it is what forks nothing — the shebang, comments, blank lines, `set`
#      lines and an `export NAME=<value>` with no substitution in it, all builtins the shell
#      cannot be interrupted in — plus what the sources need: a
#      `DIR=$(cd "$(dirname "$0")" && pwd -P)` resolution and the `source "$DIR/<file>"` lines,
#      the last preamble line being one of those sources;
#   3. no `source "$DIR/test-*.sh"` at top level BELOW the `{` — the shape the paragraph above is
#      about, and the one that fails in silence;
#   4. the file parses, and the body parses on its own with those two wrapper lines deleted.
# Rule 4 is what makes rules 1 and 2 mean something together. A `{` at the top that some `}`
# midway already closed, with a second group carrying the required foot, satisfies both line
# shapes; with the wrapper lines removed the orphaned `}` is then a syntax error, and the file is
# refused. What it does not establish is that no OTHER pair of braces could be arranged to satisfy
# it — this is a scan, not a proof (README's Tests section, ludics-lite#75). Rule 3 reads lines and
# not shell, so a `source "$DIR/test-x.sh"` quoted inside a heredoc counts: a refusal of a file
# that is fine, which is the direction for a scan to be wrong in.
#
# Scope: every `test-*.sh` under `scripts/`, `*/scripts/` and `*/hooks/` — the globs
# `check-prompts.sh` walks for the register, so a suite added to any skill is judged without a line
# here — plus the files in ALSO_GUARDED below, which is where a non-test script that carries the
# shape is named. The `.py` and `.ps1` suites are out of scope: this is a property of how bash
# reads a script, and python and pwsh read theirs whole.
#
# Usage: check-parse-guards.sh [file...]   (default: the sweep above)
# Exit 0 when every file is one brace group, 1 when one is not, 2 on a usage error.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

case "${1:-}" in
-h | --help)
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
  ;;
esac

# A non-test script required to carry the shape, named one path at a time. post-merge-cleanup.sh is
# here because ludics-lite#10 armored it: the suite runs it once per case while a review round can
# be editing it. The list is explicit rather than a glob because the shape is not free — a script
# that runs and exits in a second has no window to be edited in — so each entry is a decision.
ALSO_GUARDED=(
  ship-pr/scripts/post-merge-cleanup.sh
)

# The wrapper-removal probe of rule 3 needs somewhere to write the body it parses.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-parse-guards.XXXXXX") || exit 2
# `mktemp -d` answers with the template as the environment spells it; every path here is computed
# physically, and on macOS /tmp and /var are symlinks into /private (README's Tests section).
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 2
trap 'rm -rf "$TMP"' EXIT

swept=0
if [ "$#" -gt 0 ]; then
  # An explicit argument is checked whatever its name: the fixtures pass scratch probes by path.
  files=("$@")
else
  files=()
  for f in "$ROOT"/scripts/test-*.sh "$ROOT"/*/scripts/test-*.sh "$ROOT"/*/hooks/test-*.sh; do
    [ -f "$f" ] || continue # an unmatched glob arrives as the pattern itself
    files+=("$f")
    swept=$((swept + 1))
  done
  # Fail closed rather than print a clean verdict over nothing. Counted over the test globs alone:
  # ALSO_GUARDED is a fixed list, and it would otherwise keep the sweep non-empty on a checkout
  # where the globs have stopped describing where the suites live, which every head afterwards
  # would read as a pass.
  if [ "$swept" -eq 0 ]; then
    printf '%s\n' "check-parse-guards.sh: no suites matched scripts/test-*.sh, */scripts/test-*.sh or */hooks/test-*.sh under $ROOT" >&2
    exit 2
  fi
  for x in "${ALSO_GUARDED[@]}"; do
    # An entry naming a file that is not there is a list nobody updated: it reads as though it
    # still covered something, and the next reader would trust it.
    if [ ! -f "$ROOT/$x" ]; then
      printf '%s\n' "check-parse-guards.sh: file named in ALSO_GUARDED not found: $x -- the list in $0 is stale" >&2
      exit 2
    fi
    files+=("$ROOT/$x")
  done
fi

# The annotation's `file=` is resolved by GitHub Actions against the workspace root, so an absolute
# path anchors the refusal to nothing and it degrades to a bare log line. The path is still READ
# absolute -- the guard runs from any cwd -- and only what is printed is made repo-relative. A file
# passed by a path outside the checkout has no relative spelling and keeps the one it was given.
rc=0
for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then
    printf '%s\n' "check-parse-guards.sh: no such file: $f" >&2
    exit 2
  fi
  display=$f
  case "$f" in "$ROOT"/*) display=${f#"$ROOT"/} ;; esac

  # Rule 1: the foot. Both lines, in this order, and last.
  if [ "$(tail -n 2 "$f")" != "$(printf 'exit "$?"\n}')" ]; then
    printf '::error file=%s::%s must end in `exit "$?"` and `}`, the two lines that close the brace group: without them bash comes back to this file for a next command after the run, at whatever offset an edit has left there (ludics-lite#10, #247)\n' "$display" "$display"
    rc=1
    continue
  fi

  # Rule 2: the head. The `{` is the first command, or the first below a preamble that loads
  # libraries. The character classes stand in for backslash escapes so that every awk that reads
  # this -- BSD awk on macOS, mawk or gawk on the runners -- reads the same regex.
  head_line=$(awk '
    NR == 1 && /^#!/ { next }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*$/ { next }
    /^set [-+][A-Za-z]/ { next }
    /^export [A-Za-z_][A-Za-z0-9_]*=[^$()`]*$/ { next }
    $0 == "{" { printf "%d\t%s\t%s", NR, last, $0; exit }
    /^[A-Za-z_][A-Za-z0-9_]*=[$][(]cd "[$][(]dirname "[$]0"[)]" && pwd( -P)?[)]$/ { last = "dir"; next }
    /^(source|[.]) "[$][A-Za-z_][A-Za-z0-9_]*\/[^"]*"$/ { last = "source"; next }
    { printf "%d\t%s\t%s", NR, last, $0; exit }
  ' "$f")
  # Never empty: rule 1 has already found `exit "$?"` on the second-to-last line, and awk skips
  # only the shebang, comments, blanks, `set` lines and preamble lines, so a command is always
  # reached below.
  head_no=${head_line%%	*}
  head_rest=${head_line#*	}
  head_last=${head_rest%%	*}
  head_txt=${head_rest#*	}
  if [ "$head_txt" != "{" ]; then
    printf '::error file=%s,line=%d::%s:%d: the brace group must open as this file'\''s first command, or as the first below a preamble -- found `%s` instead. Above the `{` may stand what forks nothing -- the shebang, comments, blank lines, `set` lines, an `export NAME=value` with no substitution -- and what the sources need: one `DIR=$(cd "$(dirname "$0")" && pwd -P)` and the `source "$DIR/..."` lines (ludics-lite#10, #247)\n' "$display" "$head_no" "$display" "$head_no" "$head_txt"
    rc=1
    continue
  fi
  if [ -n "$head_last" ] && [ "$head_last" != source ]; then
    printf '::error file=%s,line=%d::%s:%d: the preamble above the brace group does not end in a `source`: a preamble is there to load a library the suite cannot source from inside the group, and a directory resolution with nothing sourced under it is one more command the file is read after (ludics-lite#247)\n' "$display" "$head_no" "$display" "$head_no"
    rc=1
    continue
  fi

  # Rule 3: no sibling test library sourced from INSIDE the group. This is the shape that made two
  # suites refuse their own declared stubs, and that would have let an undeclared shadow through in
  # silence; the header says why.
  inside=$(awk -v open="$head_no" '
    NR > open && /^(source|[.]) "[$][A-Za-z_][A-Za-z0-9_]*\/test-[^"]*"$/ { printf "%d\t%s", NR, $0; exit }
  ' "$f")
  if [ -n "$inside" ]; then
    inside_no=${inside%%	*}
    printf '::error file=%s,line=%d::%s:%d: `%s` sources a sibling test library from INSIDE the brace group: bash binds the location `declare -F` reports when it PARSES a definition, so every function below is parsed before the library is read, and the ludics-lite#46 shadow guard then reads each of them as still the library'\''s -- it refuses a declared `stub`, and accepts an undeclared shadow in silence. Move the source into the preamble, above the `{` (ludics-lite#247)\n' "$display" "$inside_no" "$display" "$inside_no" "${inside#*	}"
    rc=1
    continue
  fi

  # Rule 4: the file parses, and the two wrapper lines are only a wrapper. A `{` closed by some `}`
  # midway leaves that `}` orphaned once the wrapper is deleted, and bash says so.
  if ! parse_err=$(bash -n "$f" 2>&1); then
    printf '::error file=%s::%s does not parse: %s\n' "$display" "$display" "$(printf '%s' "$parse_err" | tr '\n' ' ')"
    rc=1
    continue
  fi
  sed -e "${head_no}d" -e '$d' "$f" >"$TMP/body.sh"
  if parse_err=$(bash -n "$TMP/body.sh" 2>&1); then
    :
  else
    printf '::error file=%s,line=%d::%s: the `{` on line %d is not the brace that the final `}` closes -- with the two wrapper lines removed the body no longer parses (%s), so part of this file sits outside the group and bash reads it after the run\n' "$display" "$head_no" "$display" "$head_no" "$(printf '%s' "$parse_err" | sed "s|$TMP/body.sh|<body>|g" | tr '\n' ' ')"
    rc=1
    continue
  fi
done

if [ "$rc" -ne 0 ]; then
  printf '%s\n' "check-parse-guards.sh: refused; see ship-pr/scripts/test-post-merge-cleanup.sh for the shape, and README's Tests section for why" >&2
  exit 1
fi
printf '%s\n' "check-parse-guards.sh: every suite is one brace group (${#files[@]} file(s))"
