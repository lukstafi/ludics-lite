#!/usr/bin/env bash
# Exercises check-jq-shapes.sh against scratch files: one file per shape the guard exists to
# refuse, each with the passing shape beside it as the control -- a scan that cannot fail would
# prove nothing (ludics-lite#55). It ends by running the guard on this checkout, which is the
# verdict CI's lint job reads, and on pr-review.sh as it stood before ludics-lite#89, where the
# guard must find the site that PR fixed: a rule nobody has ever seen fire is a rule nobody can
# trust. Between the two, scratch CHECKOUTS -- a guard installed in a tree of their own -- pin
# what the argument-less default sweep reads, which the probes above cannot: they are passed by
# path and so say nothing about scope.
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

# Round 3: comment TEXT was read as code, and two comments fabricated the wrapper a bare capture
# was missing. Its control is the same filter with the comments removed by hand, still refused —
# so the case cannot pass merely because the guard refuses everything in sight.
expect "comments cannot fabricate a wrapper" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_comment_wrapper <<'EOF'
jq -r '.[] # [
  | capture("x") # ] | first
  | .s' <<<"$raw"
EOF
)"
expect "the same filter without the comments is refused too" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_comment_wrapper_plain <<'EOF'
jq -r '.[]
  | capture("x")
  | .s' <<<"$raw"
EOF
)"
# ... and a `#` that opens no comment must not truncate the line: the wrapper here is real.
expect "a hash inside a jq string is not a comment" 0 'every capture( is bracketed' -- \
  "$CJ" "$(probe safe_hash_in_string <<'EOF'
jq -r '{tag: "issue #89", sha: ([(.body // "") | capture("(?<s>x)").s] | first // "")}' <<<"$raw"
EOF
)"

# Round 3, the other half: jq accepts a newline between a filter name and its argument list, so
# `capture` on one line and `("x")` on the next read as a clean file. The guard is line-shaped
# and says so rather than following the call across the break.
expect "a capture whose arguments are on the next line is refused" 1 'not on the same logical expression' -- \
  "$CJ" "$(probe bad_split_call <<'EOF'
jq -r '.[] | capture
  ("x") | .s' <<<"$raw"
EOF
)"

# Round 4: inside a jq program a `#` opens a comment at a token boundary too, so the
# whitespace rule from round 3 still let comment text fabricate a wrapper.
expect "a hash right after a token is a comment too" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_tight_comment <<'EOF'
jq -r '"y"#[
  | capture("x")#] | first
  | .s' <<<"$raw"
EOF
)"
# ... while in SHELL code a `#` inside a word opens nothing, or `${var#x}` would truncate the line.
expect "a hash inside a shell word is not a comment" 0 'every capture( is bracketed' -- \
  "$CJ" "$(probe safe_shell_hash <<'EOF'
sha=${ref#refs/heads/}
n=$#
jq -r '{sha: ([(.body // "") | capture("(?<s>x)").s] | first // "")}' <<<"$raw"
EOF
)"
# Round 4: a wrapper that holds something else answers `first` with that instead of the null.
expect "a wrapper holding another element is refused" 1 'not the only thing its `[...]` holds' -- \
  "$CJ" "$(probe bad_extra_element <<'EOF'
jq -r '"y" | [1, capture("x")] | first' <<<"$raw"
EOF
)"
# Round 4: `first(f)` and `last(f)` are different filters — they answer with an output of f.
expect "first with an argument list is not the readback" 1 "$REFUSAL" -- \
  "$CJ" "$(probe bad_first_arg <<'EOF'
jq -r '"y" | [capture("x")] | first(1)' <<<"$raw"
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

# --- the default sweep's scope ------------------------------------------------------------------
# With no arguments the guard reads every `*/scripts/*.sh` and `scripts/*.sh` in its checkout, not
# the one file it was written for. Exercised against scratch checkouts rather than this one: what
# has to be pinned is that a file in a scripts directory the guard was NOT written for is read at
# all, and this repo's own scripts pass (which is the point of the case at the end).

# scratch_tree <name>: a scratch checkout with the guard installed where it lives here, so that
# running it with no arguments exercises the real default sweep over a tree we control. Three
# files come with it.
# Both excluded ones, since the guard refuses a sweep whose exclusion list names a file that is
# not there -- and their probe strings coming along is the point: a tree that passes is a tree in
# which neither was scanned. And a ship-pr/scripts/pr-review.sh holding the safe shape, which is
# what the default used to be, alone. That last one is what makes the cases below fail the right
# way with the widening reverted: not "no such file" on a tree that happens to lack it, but a
# clean verdict printed over a checkout whose bad shape was never opened.
scratch_tree() {
  local d="$TMP/$1"
  mkdir -p "$d/scripts" "$d/ship-pr/scripts"
  cp "$CJ" "$d/scripts/check-jq-shapes.sh"
  cp "$HERE/test-check-jq-shapes.sh" "$d/scripts/test-check-jq-shapes.sh"
  chmod +x "$d/scripts/check-jq-shapes.sh"
  cat >"$d/ship-pr/scripts/pr-review.sh" <<'PRE'
jq -r '{sha: ([(.body // "") | capture($rc).s] | first // "")}' <<<"$raw"
PRE
  printf '%s' "$d/scripts/check-jq-shapes.sh"
}

# in_tree <tree> <path>: a file inside a scratch checkout, written from stdin.
in_tree() {
  mkdir -p "$TMP/$1/$(dirname "$2")"
  cat >"$TMP/$1/$2"
}

# The widening itself: before it, the default read ship-pr/scripts/pr-review.sh and nothing else,
# so this bad shape sat in a sibling skill's scripts directory unread on every head.
T=$(scratch_tree wide_second_dir)
in_tree wide_second_dir other-skill/scripts/stamp.sh <<'EOF'
jq -r '.[] | capture($rc) | {sha: .s}' <<<"$raw"
EOF
expect "a bad shape in a second scripts directory is refused by the default sweep" 1 "$REFUSAL" \
  -- "$T"
# Its control, and with it the proof that the two excluded files above were not scanned: the same
# tree with the shape wrapped passes, probe strings and grammar comments and all.
T=$(scratch_tree wide_second_dir_ok)
in_tree wide_second_dir_ok other-skill/scripts/stamp.sh <<'EOF'
jq -r '.[] | {sha: ([capture($rc).s] | first // "")}' <<<"$raw"
EOF
expect "a second scripts directory with the safe shape passes the default sweep" 0 'every capture( is bracketed' \
  -- "$T"

# The top-level scripts directory is swept too, and the exclusions there are two named paths
# rather than a pattern: a `scripts/check-jq*` or `scripts/test-*.sh` glob would have covered this
# file, which is a script nobody had written when the list was, holding a real bare capture.
T=$(scratch_tree wide_top_level)
in_tree wide_top_level scripts/check-jq-stamps.sh <<'EOF'
jq -r '.[] | capture($rc) | {sha: .s}' <<<"$raw"
EOF
expect "a bad shape in the top-level scripts directory is refused by the default sweep" 1 "$REFUSAL" \
  -- "$T"

# The annotation a refusal prints must be repo-relative. GitHub Actions resolves an `::error
# file=` against the workspace root, so the absolute path the default sweep builds from ROOT
# anchors the comment to no file in the diff and the refusal degrades to a bare log line -- which
# is the guard's primary output now that the sweep reads two dozen files rather than one.
T=$(scratch_tree wide_relative_annotation)
in_tree wide_relative_annotation other-skill/scripts/stamp.sh <<'EOF'
jq -r '.[] | capture($rc) | {sha: .s}' <<<"$raw"
EOF
expect "a default-sweep refusal annotates a repo-relative path" 1 \
  '::error file=other-skill/scripts/stamp.sh,line=' -- "$T"
# ...and no absolute spelling may remain, whether instead of the relative one or beside it: a
# printf carrying both satisfies the substring above and still fails to anchor. Any leading `/`
# is the tell -- the scratch tree lives under a temp directory whose spelling the guard resolves
# with `pwd -P`, so comparing against $TMP itself would miss a /var -> /private/var rewrite.
out=$("$T" 2>&1)
if grep -qE -- '::error file=/' <<<"$out"; then
  ko "a default-sweep refusal must not annotate an absolute path -- $out"
else
  ok "a default-sweep refusal does not annotate an absolute path"
fi

# An explicitly passed file outside the checkout has no relative spelling and keeps the path it
# was given -- there is nothing for a `${f#$ROOT/}` to strip, and a truncated path would name a
# file that is not there.
out=$("$CJ" "$TMP/bad_no_test.sh" 2>&1)
if grep -qF -- "::error file=$TMP/bad_no_test.sh," <<<"$out"; then
  ok "a file passed by a path outside the checkout is annotated as given"
else
  ko "a file passed by a path outside the checkout must be annotated as given -- $out"
fi

# Fail closed on a scope that has stopped describing the checkout. An exclusion entry naming a
# file that is not there is a list nobody updated; an empty sweep is a clean verdict over nothing,
# which every head afterwards would read as a pass.
T=$(scratch_tree wide_stale_exclusion)
in_tree wide_stale_exclusion other-skill/scripts/stamp.sh <<'EOF'
jq -r '.[] | {sha: ([capture($rc).s] | first // "")}' <<<"$raw"
EOF
rm -f "$TMP/wide_stale_exclusion/scripts/test-check-jq-shapes.sh"
expect "an exclusion naming a file that is gone is a usage error" 2 'excluded file not found' \
  -- "$T"
T=$(scratch_tree wide_empty_sweep)
rm -f "$TMP/wide_empty_sweep/ship-pr/scripts/pr-review.sh"
expect "a sweep that matches nothing is a usage error, not a pass" 2 'no scripts matched' -- "$T"

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
