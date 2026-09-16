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
# THE GRAMMAR. Comments are removed first (see `strip` below). What is left is grouped into
# logical expressions: a line that begins with `|` continues the line above it, anything else
# starts a new one. Then EACH `capture` call in an expression is checked on its own, against its
# own brackets:
#   - the nearest `[` before it, with no `]` in between, must exist;
#   - the `]` that closes THAT `[` (by depth) must be read back immediately with `| first` or
#     `| last` — the zero-argument filters, since `first(f)` answers with an output of f and
#     hides the miss exactly as an unwrapped capture would; and
#   - that `[...]` must hold the capture and nothing else: exactly one capture, and no comma at
#     the depth of the wrapper itself, since a second element answers `first` when the capture
#     misses and the null the wrapper exists to produce never appears.
# Per occurrence, never per expression: an existential test over the whole expression certifies
# `([capture("a")] | first), capture("b")` on the strength of the first capture's brackets while
# the second one is bare (review of ludics-lite#162, round 1). And a wrapper is only a wrapper
# for ONE of them: `[ ("a" | capture("a")), ("x" | capture("b")) ] | first` gives both captures
# the same brackets, and `first` then returns the first match while a miss by the second is
# discarded exactly as if it had never been wrapped (round 2).
#
# A call is `capture` followed by optional whitespace and `(` — jq allows `capture ("x")`, which
# a literal search for `capture(` reported as a clean file (round 2) — and preceded by a
# non-word character, so a name that merely ends in `capture` is not one.
#
# The depth count reads `[` and `]` wherever they fall, regex character classes included. Those
# balance in practice (`[^|]*`, `[0-9a-f]`), and a class that did not — `[^][]`, say — would
# unbalance the count and REFUSE, which is the safe direction: the guard would ask for a rewrite
# of a line that is fine, not pass one that is not.
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
    # How many `capture` calls <s> holds. jq allows whitespace between a filter name and its
    # argument list, so `capture ("x")` is the same call; and the leading non-word character
    # keeps a name that merely ENDS in capture (an awk `safe_capture(`, say) out of the count.
    function captures_in(s,   q, c) {
      q = 0; c = 0
      while (match(substr(s, q + 1), /(^|[^A-Za-z0-9_])capture[ \t]*\(/) > 0) {
        c++
        q = q + RSTART + RLENGTH - 1
      }
      return c
    }
    # Is the capture at <pos> in <txt> inside a collection of its OWN, read back with
    # first/last? Returns 1 yes, 0 no wrapper (or no readback), 2 a wrapper it shares with
    # another capture. Its own, in both senses: the brackets are found from this occurrence, so
    # a safe capture elsewhere in the expression vouches for nothing, and a wrapper holding two
    # captures isolates neither — `[ ("a" | capture("a")), ("x" | capture("b")) ] | first`
    # returns the first match and discards the miss of the second capture in silence.
    function safe_capture(txt, pos,   i, ch, open, depth, j, rest, inner) {
      open = 0
      for (i = pos - 1; i >= 1; i--) {
        ch = substr(txt, i, 1)
        if (ch == "]") return 0        # a closed collection, not the one this capture is in
        if (ch == "[") { open = i; break }
      }
      if (open == 0) return 0
      depth = 0
      for (j = open; j <= length(txt); j++) {
        ch = substr(txt, j, 1)
        if (ch == "[") depth++
        else if (ch == "]") { depth--; if (depth == 0) break }
      }
      if (depth != 0) return 0         # unbalanced: refuse rather than guess
      rest = substr(txt, j + 1)
      # `first`/`last` with no argument list. `first(f)` and `last(f)` are different filters —
      # they return an output of f, so `[capture("x")] | first(1)` answers 1 on a miss and hides
      # it exactly as an unwrapped capture would (round 4).
      if (rest !~ /^[ \t]*\|[ \t]*(first|last)([^A-Za-z0-9_(]|$)/) return 0
      inner = substr(txt, open + 1, j - open - 1)
      if (captures_in(inner) != 1) return 2
      # The capture must be what the collection HOLDS, not one of the things it holds: `[1,
      # capture("x")] | first` answers 1 on a miss, so the null the wrapper is there to produce
      # never appears (round 4). Approximated by a comma at the depth of the wrapper itself,
      # which is how a second element is spelled; every safe site here has none.
      depth = 0
      for (j = 1; j <= length(inner); j++) {
        ch = substr(inner, j, 1)
        if (ch == "[" || ch == "(" || ch == "{") depth++
        else if (ch == "]" || ch == ")" || ch == "}") depth--
        else if (ch == "," && depth == 0) return 3
      }
      return 1
    }
    # Comments removed, with enough quote state to know one when it sees it. A `#` opens a
    # comment where a shell or a jq reader would see one: at the start of a word, outside a
    # string. Without this, comment TEXT was read as code, and two of them fabricated the
    # wrapper a bare capture was missing (`.[] # [` … `| capture("x") # ] | first`, round 3).
    #
    # The states are shell code, a shell single-quoted run (which in this file is where a jq
    # program lives), a shell double-quoted string, and a jq string inside that program. A
    # comment ends the line and leaves the state as it was, which is what a comment does.
    # Where the state machine is wrong — a single-quoted shell string that is not a jq program
    # and carries a ` #` of its own — the line is truncated, and a truncation unbalances
    # brackets and REFUSES. That is the direction to be wrong in.
    function strip(s,   out, i, ch) {
      out = ""
      i = 1
      while (i <= length(s)) {
        ch = substr(s, i, 1)
        # Inside a jq program EVERY unquoted `#` opens a comment, token boundary or not
        # (`"y"#[` is a comment, round 4). In shell code a `#` opens one only at the start of a
        # word, which is what keeps `${var#x}` and `$#` whole.
        if (ch == "#" && mode == 1) return out
        if (ch == "#" && mode == 0 &&
            (out == "" || substr(out, length(out), 1) ~ /[ \t]/)) return out
        if (mode == 0) {
          if (ch == "\\") { out = out ch substr(s, i + 1, 1); i += 2; continue }
          if (ch == "'"'"'") mode = 1
          else if (ch == "\"") mode = 2
        } else if (mode == 1) {
          if (ch == "'"'"'") mode = 0
          else if (ch == "\"") mode = 3
        } else {
          if (ch == "\\") { out = out ch substr(s, i + 1, 1); i += 2; continue }
          if (ch == "\"") mode = (mode == 3 ? 1 : 0)
        }
        out = out ch
        i++
      }
      return out
    }
    function flush(   i, txt, p, cpos, verdict, why) {
      if (n == 0) return
      txt = ""
      for (i = 1; i <= n; i++) txt = txt (i > 1 ? " " : "") buf[i]
      # jq accepts a newline between a filter name and its argument list, so a `capture` left
      # dangling at the end of an expression is a call whose arguments this scanner will never
      # see — `capture` on one line and `("x")` on the next read as a clean file (round 3).
      # Refused rather than followed: the grammar below is line-shaped, and a call written
      # across the break is asking the guard for something it does not do.
      if (txt ~ /(^|[^A-Za-z0-9_])capture[ \t]*$/) {
        printf "::error file=%s,line=%d::%s:%d: a `capture` whose argument list is not on the same logical expression: this guard is line-shaped and cannot follow the call across the break, so it cannot certify the wrapper either — put the call and its `[...]` together\n", file, start, file, start
        bad = 1
        n = 0
        return
      }
      p = 0
      while (match(substr(txt, p + 1), /(^|[^A-Za-z0-9_])capture[ \t]*\(/) > 0) {
        # RSTART is the match, which begins one character early unless the capture opens the
        # text; both are recomputed before safe_capture, which uses match() itself.
        cpos = p + RSTART + (substr(txt, p + RSTART, 1) == "c" ? 0 : 1)
        p = p + RSTART + RLENGTH - 1
        verdict = safe_capture(txt, cpos)
        if (verdict == 1) continue
        if (verdict == 2)
          why = "a `capture(` sharing its `[...]` with another one: the collection is read back with `first`, so only the FIRST match survives and a miss by the other capture is discarded in silence — give each capture a wrapper of its own"
        else if (verdict == 3)
          why = "a `capture(` that is not the only thing its `[...]` holds: another element answers `first` when the capture misses, so the null the wrapper exists to produce never appears — wrap the capture alone"
        else {
          why = "a `capture(` that is not `[capture(...)] | first` (or `| last`): an unmatched capture yields NOTHING, which deletes the expression around it instead of defaulting"
          if (txt ~ /test[ \t]*\(/)
            why = why " — and this expression also carries a `test(`, the ludics-lite#104 shape: a guard pattern and a near-identical re-matching pattern that must agree forever, with nothing to notice the day they stop"
        }
        printf "::error file=%s,line=%d::%s:%d: %s\n", file, start, file, start, why
        bad = 1
        break                          # one refusal per expression; the rest read the same
      }
      n = 0
    }
    {
      line = strip($0)
      sub(/^[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      if (line == "") { flush(); next }   # a comment or a blank line ends the expression
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
