#!/usr/bin/env bash
# Exercises check-jq-shapes.sh against scratch files: one file per shape the guard exists to
# refuse, each with the passing shape beside it as the control -- a scan that cannot fail would
# prove nothing (ludics-lite#55). It ends by running the guard on this checkout, which is the
# verdict CI's lint job reads, and on pr-review.sh as it stood before ludics-lite#89, where the
# guard must find the site that PR fixed: a rule nobody has ever seen fire is a rule nobody can
# trust.
#
# Usage: test-check-jq-shapes.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
CJ="$HERE/check-jq-shapes.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-jq-shapes-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() {
  pass=$((pass + 1))
  echo "PASS: $*"
}
ko() {
  fail=$((fail + 1))
  echo "FAIL: $*"
}

# expect <label> <want-rc> <want-substring> -- <cmd...>
expect() {
  local label="$1" want_rc="$2" want="$3" out rc
  shift 3
  [ "$1" = -- ] && shift
  out=$("$@" 2>&1)
  rc=$?
  if [ "$rc" -eq "$want_rc" ] && grep -qF -- "$want" <<<"$out"; then
    ok "$label"
  else
    ko "$label (rc=$rc want $want_rc; want /$want/) -- $out"
  fi
}

# probe <name>: the scratch file the next expect reads, written from stdin.
probe() {
  cat >"$TMP/$1.sh"
  printf '%s' "$TMP/$1.sh"
}

REFUSAL='a `capture(` that is not `[capture(...)] | first`'

# --- the shapes that must pass ----------------------------------------------------------------

expect "the safe shape on one line passes" 0 'every capture( is bracketed' -- \
  "$CJ" "$(probe safe_one_line <<'EOF'
line=$(jq -r '
  {sha: ([(.body // "") | capture($rc).s] | first // "")}' <<<"$raw")
EOF
)"

expect "the safe shape read back on a continuation line passes" 0 'every capture( is bracketed' -- \
  "$CJ" "$(probe safe_two_lines <<'EOF'
jq -c '
  reduce (.patch | split("\n"))[] as $l ({ranges: []};
    ([$l | capture("^@@ -(?<s>[0-9]+)")]
      | first) as $h
    | .ranges += [$h])' <<<"$1"
EOF
)"

# The pairing is not what the rule refuses, the unbracketed capture is: a `test(` beside a
# BRACKETED capture leaves a null the caller can see, and is let through.
expect "a test( beside a bracketed capture passes" 0 'every capture( is bracketed' -- \
  "$CJ" "$(probe safe_with_test <<'EOF'
jq -r '
  [.[] | select((.body // "") | test("didn.t find any"))
       | {sha: ([(.body // "") | capture($rc).s] | last // "")}]' <<<"$raw"
EOF
)"

expect "a capture named only in a comment is not code" 0 'every capture( is bracketed' -- \
  "$CJ" "$(probe safe_comment_only <<'EOF'
# Always `[capture(...)] | first`, never a bare capture(...) // "": a capture that does not
# match yields nothing at all, and the enclosing value goes with it.
jq -r '.body' <<<"$raw"
EOF
)"

# --- the shapes that must be refused ------------------------------------------------------------

expect "an unbracketed capture in an object is refused" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_object <<'EOF'
jq -r '
  .[] | capture($rc) | {sha: .s, at: .created_at}' <<<"$raw"
EOF
)"

expect "an unbracketed capture inside a reduce is refused" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_reduce <<'EOF'
jq -c '
  reduce (.patch | split("\n"))[] as $l ({ranges: []};
    ($l | capture("^@@ -(?<s>[0-9]+)")) as $h
    | .ranges += [$h])' <<<"$1"
EOF
)"

# `[capture(...)]` alone is an array of zero or one matches, and nothing downstream distinguishes
# the empty one from a match: the bracket is only half the shape.
expect "a bracketed capture that is never read back is refused" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_unread <<'EOF'
jq -r '
  {shas: [(.body // "") | capture($rc).s]}' <<<"$raw"
EOF
)"

# Round 1 of the review of ludics-lite#162: the rule is per OCCURRENCE, not per expression. An
# existential test over the whole expression certifies this line on the strength of the first
# capture's brackets while the second one is bare. Its control is the same line with both
# captures bracketed, which must pass.
expect "a bare capture beside a bracketed one is refused" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_second_capture <<'EOF'
jq -r '([capture("a")] | first), capture("b")' <<<"$raw"
EOF
)"
expect "two bracketed captures on one expression pass" 0 'every capture( is bracketed' -- \
  "$CJ" "$(probe safe_two_captures <<'EOF'
jq -r '([capture("a")] | first), ([capture("b")] | first)' <<<"$raw"
EOF
)"
# The mirror: the bare capture FIRST, so a scan that stopped at the first safe one would miss it.
expect "a bare capture before a bracketed one is refused" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_first_capture <<'EOF'
jq -r 'capture("a"), ([capture("b")] | first)' <<<"$raw"
EOF
)"
# The brackets must be the capture's OWN: a closed `[...]` between them is a different collection.
expect "a capture after a closed collection is refused" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_foreign_brackets <<'EOF'
jq -r '[.ids[]] | capture($rc).s | first' <<<"$raw"
EOF
)"

# Round 2: jq allows whitespace between a filter name and its argument list, so a literal search
# for `capture(` reported this file clean. Its control is the same call with no space, refused.
expect "a capture called with a space before its argument is refused" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_spaced_call <<'EOF'
jq -r '.[] | capture ("x") | .s' <<<"$raw"
EOF
)"
# ... and a name that merely ENDS in capture is not a capture call.
expect "a name ending in capture is not a capture call" 0 'every capture( is bracketed' -- \
  "$CJ" "$(probe safe_suffix_name <<'EOF'
jq -r 'def safe_capture($re): .s; .[] | safe_capture("x")' <<<"$raw"
EOF
)"
# Round 2, the other half: one wrapper cannot isolate two captures. `first` returns the first
# match, so a miss by the second is discarded exactly as if it had never been wrapped.
expect "two captures sharing one wrapper are refused" 1 'sharing its `[...]` with another one' -- \
  "$CJ" "$(probe bad_shared_wrapper <<'EOF'
jq -r '[ ("a" | capture("a")), ("x" | capture("b")) ] | first' <<<"$raw"
EOF
)"

expect "the refusal names the line" 1 ":3:" -- \
  "$CJ" "$(probe bad_line_number <<'EOF'
# a comment, which is not a line of the expression below

jq -r '.[] | capture($rc) | .s' <<<"$raw"
EOF
)"

# The ludics-lite#104 shape: a guard pattern admits a row and a second, near-identical pattern
# re-matches it. Refused for the unbracketed capture, and told apart in the message.
expect "a test( and an unbracketed capture( name #104" 1 'ludics-lite#104 shape' -- \
  "$CJ" "$(probe bad_test_and_capture <<'EOF'
jq -rs '
  [.[] | select((.body // "") | split("\n")[]
     | select(test("^\\|[^|]*Code Review[^|]*Running"))
     | capture("datetime=\"(?<at>[^\"]+)\"")
     | . + {kind:"running"})]' <<<"$raw"
EOF
)"

expect "a plain unbracketed capture does not claim the #104 shape" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_no_test <<'EOF'
jq -r '.[] | capture($rc) | .s' <<<"$raw"
EOF
)"
out=$("$CJ" "$TMP/bad_no_test.sh" 2>&1)
if grep -qF 'ludics-lite#104 shape' <<<"$out"; then
  ko "an expression with no test( must not be reported as the #104 shape -- $out"
else
  ok "an expression with no test( is not reported as the #104 shape"
fi

# --- usage ------------------------------------------------------------------------------------

expect "a missing file is a usage error, not a pass" 2 'no such file' -- \
  "$CJ" "$TMP/there-is-no-such-file.sh"
expect "--help prints the header" 0 'yields ZERO outputs' -- "$CJ" --help

# --- this checkout, and the head this guard was written for -------------------------------------

expect "this checkout passes the guard" 0 'every capture( is bracketed' -- "$CJ"

# pr-review.sh as it stood before ludics-lite#89: the Running-row stamp was an unbracketed
# `capture` on the same expression as the `test(` that admitted the row. If this ever stops
# failing, the guard has stopped guarding.
BEFORE=3a23e4f9b57df5080f5b7fabbfc097e7860ca8f8
if git -C "$ROOT" show "$BEFORE:ship-pr/scripts/pr-review.sh" >"$TMP/pr-review-before.sh" 2>/dev/null &&
  [ -s "$TMP/pr-review-before.sh" ]; then
  expect "the head this guard was written for is refused" 1 'ludics-lite#104 shape' -- \
    "$CJ" "$TMP/pr-review-before.sh"
else
  # CI checks out at depth 1, so the pre-#89 blob is usually absent there. The scratch probes
  # above are what hold the guard honest on every head; this one is the historical witness.
  ok "the pre-#89 pr-review.sh is not in this checkout (shallow clone); skipped"
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
