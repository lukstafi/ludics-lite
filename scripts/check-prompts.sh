#!/usr/bin/env bash
# Prompt hygiene: the small, deterministic checks on the prompts themselves -- every skill and
# routine `SKILL.md`, and the two README tables that index them. It is the one CI job that runs on
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
# And per index table -- `| Skill |` in README.md, `| Routine |` in routines/README.md -- that
# the table's first column and the directories carrying a SKILL.md are the same set, in both
# directions, so a new prompt cannot land unindexed and a row cannot outlive its directory.
#
# Usage: check-prompts.sh [root]   (root defaults to the checkout this script lives in;
#                                   exit 0 all pass, 1 otherwise)
# Under GitHub Actions each failure is also an `::error` annotation on the file it names.

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=${1:-$(cd "$HERE/.." && pwd)}
[ -d "$ROOT" ] || { echo "check-prompts: no such directory: $ROOT" >&2; exit 2; }

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok: $*"; }
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
#   - a plain scalar: no leading YAML indicator (`[]{}&*!|>%@,` and the backtick; `-`, `?`
#     and `:` only where YAML gives them meaning, before a space or at the end), no `: ` and no
#     trailing `:` (a mapping to YAML), and not a spelling YAML resolves to a number, boolean or
#     null; an unquoted trailing ` #comment` is dropped first.
# The empty string, from any of these, is "no value" (`null`, `~` and a bare comment included).
value_of() {
  local v inner first
  v=$(printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
  case "$v" in
  \"*)
    # Only the two escapes whose reading is one character and one line, `\"` and `\\`; every
    # other backslash (`\n`, `\t`, `\q`) is refused rather than decoded, so a value never
    # resolves past one line, and never to something a loader would reject.
    if ! printf '%s\n' "$v" | grep -qE '^"([^"\\]|\\["\\])*"([[:space:]]+#.*)?$'; then
      echo "a double-quoted value must close on the same line with nothing but a comment after it, and may escape only \\\" and \\\\ (single-quote the value, or drop the backslash)"; return 1
    fi
    inner=$(printf '%s\n' "$v" | sed -E 's/^"(([^"\\]|\\["\\])*)".*$/\1/' | sed -E 's/\\(["\\])/\1/g')
    ;;
  \'*)
    if ! printf '%s\n' "$v" | grep -qE "^'([^']|'')*'([[:space:]]+#.*)?\$"; then
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
    if printf '%s\n' "$inner" | grep -qiE '^(true|false|yes|no|on|off|y|n|[-+]?(\.[0-9]+|[0-9][0-9_]*(\.[0-9_]*)?)([eE][-+]?[0-9]+)?|0x[0-9a-fA-F_]+|0o?[0-7_]+|[-+]?\.(inf|nan))$'; then
      echo "'$inner' is a number, boolean or null to YAML, not text; quote the value"; return 1
    fi
    ;;
  esac
  printf '%s' "$inner"
}

check_skill_file() {
  local rel="$1" dir fm bad key count raw name="" value
  dir=$(basename "$(dirname "$ROOT/$rel")")
  if ! fm=$(frontmatter "$ROOT/$rel"); then
    ko "$rel" "no YAML frontmatter: line 1 must be '---' and a closing '---' must follow"
    return
  fi
  # A control character anywhere in the frontmatter -- a tab YAML reads as a separator, a
  # carriage return a loader folds into the value -- is refused whole, rather than modelled
  # wherever it could change a reading.
  if printf '%s\n' "$fm" | grep -q '[[:cntrl:]]'; then
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
    printf '%s\n' "$fm" | grep -qE "^$key:" || ko "$rel" "frontmatter has no '$key:' line"
  done
  if [ -n "$name" ] && [ "$name" != "$dir" ]; then
    ko "$rel" "frontmatter name '$name' does not match its directory '$dir'"
  fi
  [ "$fail" -eq 0 ] || return 0
  ok "$rel: frontmatter names '$name' with a one-line description"
}

# --- index tables -----------------------------------------------------------------------------
# table_names <readme> <first-column-header>: the backticked first column of the table whose
# header row starts `| <header> |`. It is a table only with its delimiter row (`| --- | ... |`)
# right under the header -- without one Markdown renders the rows as prose, and so does this.
# A table ends at the first line that is not a row, blank or not: a heading or paragraph ends
# it just the same, and the rows of a later table are that table's, whatever its header.
table_names() {
  awk -v hdr="| $2 |" '
    index($0, hdr) == 1 { want_delim = 1; next }
    want_delim { want_delim = 0; if ($0 ~ /^\|([[:space:]]*:?-+:?[[:space:]]*\|)+[[:space:]]*$/) in_table = 1; else exit; next }
    in_table && !/^\|/ { exit }
    in_table && /^\| `[^`]*` \|/ { sub(/^\| `/, ""); sub(/`.*$/, ""); print }
  ' "$ROOT/$1"
}

# check_index <readme> <header> <dir prefix> <what>: the table's names and the directories
# carrying a SKILL.md under the prefix must be the same set.
check_index() {
  local readme="$1" header="$2" prefix="$3" what="$4" dirs rows missing extra
  [ -f "$ROOT/$readme" ] || { ko "$readme" "missing: it carries the $what table"; return; }
  dirs=$(cd "$ROOT" && for f in ${prefix}*/SKILL.md; do [ -f "$f" ] && dirname "$f"; done \
    | sed "s|^$prefix||" | sort)
  rows=$(table_names "$readme" "$header" | sort)
  if [ -z "$rows" ]; then
    ko "$readme" "no '| $header |' table (a header row, its '| --- |' delimiter row, then rows with backticked names in the first column)"
    return
  fi
  missing=$(comm -23 <(printf '%s\n' "$dirs") <(printf '%s\n' "$rows") | tr '\n' ' ')
  extra=$(comm -13 <(printf '%s\n' "$dirs") <(printf '%s\n' "$rows") | tr '\n' ' ')
  [ -z "$missing" ] || ko "$readme" "$what directories missing from its table: ${missing% }"
  for name in $extra; do
    ko "$readme" "table row '$name' has no ${prefix}$name/SKILL.md behind it"
  done
  [ -n "$missing$extra" ] || ok "$readme: the $what table indexes exactly the ${prefix:-top-level} SKILL.md directories"
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

check_index README.md Skill "" skill
check_index routines/README.md Routine routines/ routine

echo
echo "check-prompts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
