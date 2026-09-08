#!/usr/bin/env bash
# Prompt hygiene: the small, deterministic checks on the prompts themselves -- every skill and
# routine `SKILL.md`, and the two README tables that index them. It is the one CI job that runs on
# every head regardless of what changed (ludics-lite#55): the script suites are conditioned on
# script-related paths, so a prompt-only PR would otherwise reach the merge gate with no verdict at
# all, which `pr-review.sh merge` refuses as ABSENT. This is what keeps such a head judged.
#
# What it pins, per <root>/*/SKILL.md and <root>/routines/*/SKILL.md:
#   - YAML frontmatter: line 1 is `---`, closed by a later `---`, and nothing but frontmatter
#     before the closing fence;
#   - exactly one `name:` and one `description:`, each with a non-empty single-line value
#     (a block scalar, `|` or `>`, is refused: the loaders read the description as one line);
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

# field <key> <frontmatter>: the values of `key: value` lines, one per line.
field() { printf '%s\n' "$2" | sed -n "s/^$1:[[:space:]]*//p"; }

check_skill_file() {
  local rel="$1" dir fm name desc count
  dir=$(basename "$(dirname "$ROOT/$rel")")
  if ! fm=$(frontmatter "$ROOT/$rel"); then
    ko "$rel" "no YAML frontmatter: line 1 must be '---' and a closing '---' must follow"
    return
  fi
  for key in name description; do
    count=$(field "$key" "$fm" | grep -c .)
    case "$count" in
    0) ko "$rel" "frontmatter has no '$key:' with a value" ;;
    1) ;;
    *) ko "$rel" "frontmatter has $count '$key:' lines, expected one" ;;
    esac
  done
  name=$(field name "$fm" | head -n 1)
  desc=$(field description "$fm" | head -n 1)
  case "$desc" in
  '|' | '>' | '|-' | '>-' | '|+' | '>+')
    ko "$rel" "description is a block scalar ('$desc'); the loaders read it as one line" ;;
  esac
  if [ -n "$name" ] && [ "$name" != "$dir" ]; then
    ko "$rel" "frontmatter name '$name' does not match its directory '$dir'"
  fi
  [ "$fail" -eq 0 ] || return 0
  ok "$rel: frontmatter names '$name' with a one-line description"
}

# --- index tables -----------------------------------------------------------------------------
# table_names <readme> <first-column-header>: the backticked first column of the table whose
# header row starts `| <header> |`, up to the first blank line after it.
table_names() {
  awk -v hdr="| $2 |" '
    index($0, hdr) == 1 { in_table = 1; next }
    in_table && /^$/ { exit }
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
    ko "$readme" "no '| $header |' table with backticked names in its first column"
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
