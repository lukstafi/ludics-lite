#!/usr/bin/env bash
# Refuse the one jq shape that fails by producing NOTHING: a `capture(` that is not wrapped in a
# collection constructor read back with `first` or `last`.
#
# jq's `capture` yields ZERO outputs when the pattern does not match — not null. A zero-output
# sub-expression does not fall back to a default and does not error; it deletes the expression
# that contains it. Inside a string interpolation that loses the string; inside an object that
# loses the object; inside the update expression of a `reduce` it takes the whole accumulator,
# so a fold over ten hunks returns null and the path reads as "hunks unread" on a patch that
# parsed fine (ludics-lite#104). `[capture(...)] | first` is the shape that cannot do that: an
# array of the zero-or-one matches, read back as a value that is null when there was no match,
# which `//` can then default and a caller can test.
#
# Five such sites have been fixed across three PRs (ludics-lite#84 fixed three, #104 a fourth,
# #89 a fifth), and until this check the safe shape was documented only in prose beside one of
# them. The trap is invisible in review precisely because nothing errors, so what catches it has
# to be mechanical and run on every head. That is all this is: a grep-shaped rule, deliberately
# not a jq parser.
#
# The issue's second proposed rule — refuse a `test(` and a `capture(` on the same logical
# expression, the #104 shape of a guard pattern followed by a near-identical re-matching pattern
# — collapses into this one. What makes that pair dangerous is not the pairing, it is the
# unbracketed `capture`: bracketed, a row the second pattern misses is a null the caller sees
# rather than a row that vanishes. So a `test(`/`capture(` pair that satisfies the rule below is
# not refused, and one that does not is refused anyway, with #104 named in the message.
#
# THE GRAMMAR. Comment lines are dropped (shell and jq comments alike open with `#`). What is
# left is grouped into logical expressions: a line that begins with `|` continues the line above
# it, anything else starts a new one. Every expression containing `capture(` must carry both
#   - a `[` with no `]` between it and the `capture(`, and
#   - a `]` followed by `| first` or `| last`.
# That is an approximation of "the capture is immediately inside a collection constructor whose
# result is read back as a value", and it is the approximation on purpose: a rule a reader can
# check by eye is a rule that gets kept.
#
# Usage: check-jq-shapes.sh [file...]   (default: ship-pr/scripts/pr-review.sh)
# Exit 0 when every capture is in the safe shape, 1 when one is not, 2 on a usage error.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

case "${1:-}" in
-h | --help)
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
  ;;
esac

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=("$ROOT/ship-pr/scripts/pr-review.sh")
fi

rc=0
for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "check-jq-shapes.sh: no such file: $f" >&2
    exit 2
  fi
  awk -v file="$f" '
    function flush(   i, txt) {
      if (n == 0) return
      txt = ""
      for (i = 1; i <= n; i++) txt = txt (i > 1 ? " " : "") buf[i]
      if (txt ~ /capture\(/) {
        if (txt !~ /\[[^]]*capture\(/ || txt !~ /\][ \t]*\|[ \t]*(first|last)/) {
          why = "a `capture(` that is not `[capture(...)] | first` (or `| last`): an unmatched capture yields NOTHING, which deletes the expression around it instead of defaulting"
          if (txt ~ /test\(/)
            why = why " — and this expression also carries a `test(`, the ludics-lite#104 shape: a guard pattern and a near-identical re-matching pattern that must agree forever, with nothing to notice the day they stop"
          printf "::error file=%s,line=%d::%s:%d: %s\n", file, start, file, start, why
          bad = 1
        }
      }
      n = 0
    }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line ~ /^#/) next          # a comment continues neither expression nor evidence
      if (line !~ /^\|/) flush()
      if (n == 0) start = NR
      buf[++n] = line
    }
    END { flush(); exit bad ? 1 : 0 }
  ' "$f" || rc=1
done

if [ "$rc" -ne 0 ]; then
  echo "check-jq-shapes.sh: refused; see ship-pr/scripts/pr-review.sh's \`item_stamp\` for the safe shape" >&2
  exit 1
fi
echo "check-jq-shapes.sh: every capture( is bracketed and read back (${#files[@]} file(s))"
