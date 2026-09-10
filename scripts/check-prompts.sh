#!/usr/bin/env bash
# Prompt hygiene: the small, deterministic checks on the prompts themselves -- every skill and
# routine `SKILL.md`, and the two READMEs that index them. It is the one CI job that runs on
# every head regardless of what changed (ludics-lite#55): the script suites are conditioned on
# script-related paths, so a prompt-only PR would otherwise reach the merge gate with no verdict at
# all, which `pr-review.sh merge` refuses as ABSENT. This is what keeps such a head judged.
#
# What it pins, per <root>/*/SKILL.md and <root>/routines/*/SKILL.md:
#   - YAML frontmatter: line 1 is `---`, closed by a later `---`, and every line between them
#     is a top-level `key: value` (or blank, or a comment) -- a flat map of one-line scalars,
#     which is the only shape the loaders read; a continued, nested, listed or block-scalar
#     value is refused rather than half-read;
#   - exactly one `name:` and one `description:` declaration, each a value inside the grammar
#     YAML reads unambiguously as a non-empty string -- a fully quoted string, or a plain
#     scalar free of indicators, of `: `, and of the number/boolean/null spellings; anything
#     else is refused, whether or not a loader would accept it, so the checker never has to
#     guess what a loader would make of it;
#   - `name` equals the directory's name, which is what the install loops link by and what the
#     scheduler registers.
# And per README -- README.md for the skills, routines/README.md for the routines -- that every
# directory carrying a SKILL.md is named, in backticks, in the first cell of a row there, so a new
# prompt cannot land unindexed. That is a lookup, not a rendering claim: see `indexed` below for
# what it stopped asserting when the table scanner went (ludics-lite#75).
#
# Usage: check-prompts.sh [root]   (root defaults to the checkout this script lives in;
#                                   exit 0 all pass, 1 otherwise)
# Under GitHub Actions each failure is also an `::error` annotation on the file it names.

set -uo pipefail

# Every character class below is ASCII, by locale: under C, `[[:space:]]` is the blanks YAML
# calls whitespace, `[[:cntrl:]]` the ASCII controls, `[A-Za-z]` the letters, and any other
# byte is content -- a Unicode space in a name stays in the name and is compared with the
# directory, never trimmed away as a UTF-8 locale's `[[:space:]]` would. The same reading on
# every box, whatever its locale.
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${1:-$(cd "$HERE/.." && pwd)}
[ -d "$ROOT" ] || { echo "check-prompts: no such directory: $ROOT" >&2; exit 2; }

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok: $*"; }

# matches <ERE> <text>: whether a line of the text matches the expression. Judged on grep's
# OUTPUT, never on a `grep -q` pipeline's status: -q stops at the first match, the producer
# then dies of SIGPIPE, and under pipefail a match early in text longer than the pipe buffer
# would read as no match. Every regex test in this file goes through here for that reason.
matches() { [ -n "$(printf '%s\n' "$2" | grep -E "$1")" ]; }
# ko <file> <message>: <file> is relative to the root, for the annotation.
ko() {
  fail=$((fail + 1))
  echo "FAIL: $1: $2"
  [ "${GITHUB_ACTIONS:-}" = true ] && echo "::error file=$1::$2"
  return 0
}

# --- frontmatter ------------------------------------------------------------------------------
# frontmatter <file>: prints the lines between the opening and closing fences, or fails.
frontmatter() {
  local f="$1" first
  IFS= read -r first < "$f" || return 1
  [ "$first" = '---' ] || return 1
  # Lines 2.. up to the closing fence, exclusive; no closing fence is a failure.
  awk 'NR == 1 { next } /^---$/ { found = 1; exit } { print } END { exit found ? 0 : 1 }' "$f"
}

# The frontmatter is read as what the loaders need it to be: a FLAT map of one-line scalars. That
# is what makes the reading exact rather than an approximation of YAML -- every line is blank, a
# comment, or a top-level `key: value`, so a value cannot continue on a next line, a block scalar
# has no body to hold, and a list or nested map is refused outright. Within that shape, a value is
# accepted only inside a grammar YAML reads unambiguously as a string (`value_of` below), so
# `description: ""`, `description: ~` and `description: # note` are the empty they are to a
# loader, `description: []` and `description: Runs: checks` are refused rather than half-read,
# and the checker owes no opinion on anything it does not accept.
KEY_LINE='^[A-Za-z_][A-Za-z0-9_-]*:([[:space:]]|$)'
BLANK_OR_COMMENT='^[[:space:]]*(#|$)'

# field <key> <frontmatter>: the raw right-hand side of EVERY `key:` line, one per output line,
# an empty value included -- the count of declarations is a fact about the keys, not the values.
field() { printf '%s\n' "$2" | sed -n "s/^$1:[[:space:]]*//p"; }

# value_of <raw>: the text a value resolves to, on stdout with exit 0, when the value lies inside
# the grammar this checker accepts; otherwise exit 1 with the REASON on stdout. The grammar is a
# deliberate SUBSET of YAML -- the values a loader reads unambiguously as a string -- and
# everything outside it is refused whether YAML would accept it or not. That is what closes, for
# good, the class of "the checker reads this value differently from a YAML loader": the checker
# never models what a loader does with a value it does not accept, it refuses it.
#   - a double-quoted string, `"..."` with backslash escapes, closed on the same line and
#     followed by nothing but an optional comment;
#   - a single-quoted string, `'...'` with `''` for a quote, closed the same way;
#   - a plain scalar: starts with an ASCII letter (no implicitly typed YAML scalar -- number,
#     date, time, sexagesimal, binary, merge key -- does, so none needs modelling), is not a
#     boolean or null keyword, carries no leading YAML indicator (`[]{}&*!|>%@,` and the
#     backtick; `-`, `?` and `:` before a space or at the end), no `: ` and no trailing `:`
#     (a mapping to YAML); an unquoted trailing ` #comment` is dropped first.
# The empty string, from any of these, is "no value" (`null`, `~` and a bare comment included).
value_of() {
  local v inner first
  v=$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$v" in
  \"*)
    # Only the two escapes whose reading is one character and one line, `\"` and `\\`; every
    # other backslash (`\n`, `\t`, `\q`) is refused rather than decoded, so a value never
    # resolves past one line, and never to something a loader would reject.
    if ! matches '^"([^"\\]|\\["\\])*"([[:space:]]+#.*)?$' "$v"; then
      echo "a double-quoted value must close on the same line with nothing but a comment after it, and may escape only \\\" and \\\\ (single-quote the value, or drop the backslash)"; return 1
    fi
    inner=$(printf '%s\n' "$v" | sed -E 's/^"(([^"\\]|\\["\\])*)".*$/\1/' | sed -E 's/\\(["\\])/\1/g')
    ;;
  \'*)
    if ! matches "^'([^']|'')*'([[:space:]]+#.*)?\$" "$v"; then
      echo "a single-quoted value must close on the same line, with nothing but a comment after the closing quote"; return 1
    fi
    inner=$(printf '%s\n' "$v" | sed -E "s/^'(([^']|'')*)'.*\$/\1/" | sed "s/''/'/g")
    ;;
  *)
    v=$(printf '%s' "$v" | sed -e 's/[[:space:]]#.*$//' -e 's/[[:space:]]*$//')
    first=${v%"${v#?}"}
    case "$v" in
    '' | \#*) inner="" ;;
    [\[\]{}\&\*\!\|\>%@\`,]*)
      echo "starts with the YAML indicator '$first', which a loader reads as a collection, anchor, tag or block scalar, not text; quote the value"; return 1 ;;
    -\ * | - | \?\ * | \? | :\ * | :)
      echo "starts with '$first ', which YAML reads as a list item or mapping key, not text; quote the value"; return 1 ;;
    *:\ * | *:)
      echo "contains ': ' or ends with ':', which YAML reads as a nested mapping, not text; quote the value or rephrase"; return 1 ;;
    *) inner="$v" ;;
    esac
    case "$inner" in null | Null | NULL | '~') inner="" ;; esac
    # Implicit typing is closed by shape, not by enumerating the loaders' type grammars: no
    # number, float, date, time, sexagesimal, binary, merge key or other implicitly typed
    # scalar begins with an ASCII letter, so a plain value must, and the keyword spellings
    # of booleans and null are the one lettered exception, refused by name.
    case "$inner" in
    '' | [A-Za-z]*) ;;
    *) echo "'$inner' does not start with a letter, so a loader may read it as a number, date, time or other typed value, not text; quote the value"; return 1 ;;
    esac
    if matches '^(true|false|yes|no|on|off|y|n|null)$' "$(printf '%s' "$inner" | tr '[:upper:]' '[:lower:]')"; then
      echo "'$inner' is a boolean or null to YAML, not text; quote the value"; return 1
    fi
    ;;
  esac
  printf '%s' "$inner"
}

# The bytes a shell variable cannot hold, or a loader will not, are checked on the raw file
# before anything is read into a variable: bash drops a NUL from a command substitution (with a
# warning on stderr that no verdict reads); invalid UTF-8 is a loader error; and so is any
# character outside YAML's `c-printable` production -- of which, in valid UTF-8 with the ASCII
# controls refused on the frontmatter below, the C1 controls U+0080-U+009F (`\xC2\x80`-
# `\xC2\x9F`) and the non-characters U+FFFE, U+FFFF (`\xEF\xBF\xBE`, `\xEF\xBF\xBF`) are what
# remains -- and the line breaks YAML 1.1 (libyaml, Psych) knows beyond LF, CR and NEL, the
# separators U+2028 and U+2029 (`\xE2\x80\xA8`, `\xE2\x80\xA9`), which would split a value the
# frontmatter reads as one line. Refusing by the spec's own definitions is what closes the class.
# The NUL and UTF-8 checks are the whole file's (every reader takes it as UTF-8 text); the
# YAML character rules are the frontmatter's alone, read as raw bytes off the file, since the
# Markdown body after the closing fence is never YAML and may carry a line separator.
well_formed_bytes() {
  local f="$1"
  [ "$(tr -d '\000' < "$f" | wc -c)" -eq "$(wc -c < "$f")" ] || return 1
  iconv -f UTF-8 -t UTF-8 < "$f" > /dev/null 2>&1 || return 1
  # Judged on grep's OUTPUT, not the pipeline's status: `grep -q` stops at the first match,
  # awk then dies of SIGPIPE, and under pipefail the negated pipeline would read a large
  # frontmatter with an early forbidden character as well formed. Without -q, grep reads it all.
  [ -z "$(awk 'NR > 1 && /^---$/ { exit } NR > 1 { print }' "$f" \
    | grep -E "$(printf '\302[\200-\237]|\357\277[\276\277]|\342\200[\250\251]')")" ]
}

check_skill_file() {
  local rel="$1" dir fm bad key count raw name="" value
  dir=$(basename "$(dirname "$ROOT/$rel")")
  if ! well_formed_bytes "$ROOT/$rel"; then
    ko "$rel" "carries a byte sequence no loader accepts: a NUL or invalid UTF-8 anywhere, or in the frontmatter a character outside YAML's printable set (a C1 control, U+FFFE, U+FFFF) or a line separator (U+2028, U+2029)"
    return
  fi
  if ! fm=$(frontmatter "$ROOT/$rel"); then
    ko "$rel" "no YAML frontmatter: line 1 must be '---' and a closing '---' must follow"
    return
  fi
  # A control character anywhere in the frontmatter -- a tab YAML reads as a separator, a
  # carriage return a loader folds into the value -- is refused whole, rather than modelled
  # wherever it could change a reading.
  if matches '[[:cntrl:]]' "$fm"; then
    ko "$rel" "frontmatter carries a control character (a tab or a carriage return, say); use plain spaces and LF line ends"
    return
  fi
  bad=$(printf '%s\n' "$fm" | grep -v -E "$BLANK_OR_COMMENT" | grep -v -E "$KEY_LINE" | head -n 1)
  if [ -n "$bad" ]; then
    ko "$rel" "frontmatter line is not a top-level 'key: value' (a continued, nested or listed value cannot be read as one line): '$bad'"
    return
  fi
  # Every declared key, the optional ones included, is declared once and carries a value inside
  # the grammar: a loader rejects the whole file on a malformed `allowed-tools:` just as on a
  # malformed `name:`, so the verdict cannot be limited to the two required keys.
  for key in $(printf '%s\n' "$fm" | grep -E "$KEY_LINE" | sed 's/:.*$//' | sort -u); do
    count=$(field "$key" "$fm" | wc -l | tr -d ' ')
    if [ "$count" -ne 1 ]; then
      ko "$rel" "frontmatter has $count '$key:' lines, expected one"; continue
    fi
    raw=$(field "$key" "$fm")
    case "$raw" in
    '|'* | '>'*)
      ko "$rel" "$key is a block scalar ('$raw'); the loaders read it as one line"; continue ;;
    esac
    if ! value=$(value_of "$raw"); then
      ko "$rel" "frontmatter '$key:' value is outside the grammar this check accepts: '$raw' ($value)"; continue
    fi
    if [ -z "$value" ]; then
      ko "$rel" "frontmatter '$key:' has no value ('$raw' resolves to empty)"; continue
    fi
    [ "$key" = name ] && name="$value"
  done
  for key in name description; do
    matches "^$key:" "$fm" || ko "$rel" "frontmatter has no '$key:' line"
  done
  if [ -n "$name" ] && [ "$name" != "$dir" ]; then
    ko "$rel" "frontmatter name '$name' does not match its directory '$dir'"
  fi
  [ "$fail" -eq 0 ] || return 0
  ok "$rel: frontmatter names '$name' with a one-line description"
}

# --- index lookup -----------------------------------------------------------------------------
# indexed <readme> <name>: whether <readme> carries a row whose FIRST cell is `<name>` -- the
# whole claim, and a lookup rather than a parse. One fixed scan per directory: a line is a row
# here when, after an optional leading pipe, it opens with the backticked name and the next
# non-blank character is a pipe (GFM renders a body row without its leading pipe, so both
# spellings count). The name is matched as text, not as a pattern, so a `.` or a `-` in a
# directory name is that character and `beta` is not found in `` `betas` ``.
#
# What this deliberately does NOT claim, after ludics-lite#75: that the row renders. There is no
# table model here -- no header, no delimiter row, no fenced-code or HTML-comment scope, no
# end-of-table condition -- so a row-shaped line inside a code fence or a comment satisfies the
# lookup, and a table whose header or delimiter row was mangled still passes. Each of those was
# a rule the scanner got to be wrong about, and thirteen review rounds of PR #64 went on their
# edge cases while the drift anyone actually commits -- a new prompt directory nobody added to
# the README -- needs none of them. The check that is left is the one worth having, and it is
# small enough to be obviously right.
indexed() {
  awk -v want="\`$2\`" '
    {
      line = $0
      sub(/^[[:space:]]*\|?[[:space:]]*/, "", line)
      if (index(line, want) == 1) {
        rest = substr(line, length(want) + 1)
        sub(/^[[:space:]]*/, "", rest)
        if (substr(rest, 1, 1) == "|") { found = 1; exit }
      }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

# check_index <readme> <dir prefix> <what>: every directory carrying a SKILL.md under the prefix
# is named in a backticked row of the readme, so a new prompt cannot land unindexed. The other
# direction -- a row that outlives its directory -- is not checked: reading it needs the table
# model this file no longer has, and a stale row misleads a reader where an unindexed prompt
# hides from one.
check_index() {
  local readme="$1" prefix="$2" what="$3" dirs dir found=0 bad=0
  [ -f "$ROOT/$readme" ] || { ko "$readme" "missing: it indexes the $what directories"; return; }
  dirs=$(cd "$ROOT" && for f in ${prefix}*/SKILL.md; do [ -f "$f" ] && dirname "$f"; done \
    | sed "s|^$prefix||" | sort)
  while IFS= read -r dir; do
    [ -n "$dir" ] || continue
    found=$((found + 1))
    indexed "$ROOT/$readme" "$dir" \
      || { ko "$readme" "$what '$dir' is not indexed: no row whose first cell is the backticked name '\`$dir\`'"; bad=1; }
  done <<<"$dirs"
  if [ "$found" -eq 0 ]; then
    # Nothing to look up is not a verdict on the index: say that, rather than passing as if the
    # readme had been checked against something.
    ok "$readme: no ${prefix:-top-level} SKILL.md directory to index"
  elif [ "$bad" -eq 0 ]; then
    ok "$readme: all $found $what directories are named in backticked rows"
  fi
}

# --- run --------------------------------------------------------------------------------------
files=$(cd "$ROOT" && for f in */SKILL.md routines/*/SKILL.md; do [ -f "$f" ] && echo "$f"; done)
[ -n "$files" ] || ko . "no */SKILL.md or routines/*/SKILL.md under $ROOT"
for f in $files; do
  before=$fail
  fail=0
  check_skill_file "$f"
  fail=$((before + fail))
done

check_index README.md "" skill
check_index routines/README.md routines/ routine

echo
echo "check-prompts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
