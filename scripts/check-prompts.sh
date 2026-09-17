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
# Two cross-file agreements ride along, each pinning a fact the prompts only restate: every test
# fixture has a command in the README's register and a run line on each CI platform it needs, and
# every file that quotes the mac-studio correctness-slot count quotes the one fleet-worker.sh
# actually defaults to (ludics-lite#160) -- which files those are is discovered, not listed.
#
# Usage: check-prompts.sh [root]   (root defaults to the checkout this script lives in;
#                                   exit 0 all pass, 1 otherwise)
# Single directory: check-prompts.sh --one <dir> (frontmatter only; no index or directory-name
# equality requirement, since installed scheduler IDs may differ from prompt names).
# Under GitHub Actions each failure is also an `::error` annotation on the file it names.

set -uo pipefail

# Every character class below is ASCII, by locale: under C, `[[:space:]]` is the blanks YAML
# calls whitespace, `[[:cntrl:]]` the ASCII controls, `[A-Za-z]` the letters, and any other
# byte is content -- a Unicode space in a name stays in the name and is compared with the
# directory, never trimmed away as a UTF-8 locale's `[[:space:]]` would. The same reading on
# every box, whatever its locale.
export LC_ALL=C

HERE=$(cd "$(dirname "$0")" && pwd)
ONE=false
case "${1:-}" in
  --one) [ "$#" -eq 2 ] || { echo 'usage: check-prompts.sh --one <dir>' >&2; exit 2; }
    ONE=true; ROOT=$2 ;;
  -h|--help) echo 'usage: check-prompts.sh [root] | --one <dir>'; exit 0 ;;
  -*) echo "check-prompts: unknown option: $1" >&2; exit 2 ;;
  *) [ "$#" -le 1 ] || { echo 'usage: check-prompts.sh [root] | --one <dir>' >&2; exit 2; }
    ROOT=${1:-$(cd "$HERE/.." && pwd)} ;;
esac
[ -d "$ROOT" ] || { echo "check-prompts: no such directory: $ROOT" >&2; exit 2; }
# Canonical and without a trailing slash, so every `$ROOT/`-relative path built below reads
# the same whether the caller wrote `<dir>` or `<dir>/` -- a `<dir>//` prefix matched none of
# find's output, which silently emptied the slot scan and then reported the prompts as silent.
ROOT=$(cd "$ROOT" && pwd) || { echo "check-prompts: cannot enter: $ROOT" >&2; exit 2; }

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
  if ! $ONE && [ -n "$name" ] && [ "$name" != "$dir" ]; then
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
# directory name is that character and `beta` is not found in `` `betas` ``. The name reaches awk
# through the ENVIRONMENT, never through `-v`: an assignment made with `-v` is escape-processed, so
# a directory named `a\n` -- a name this checker accepts, spelled `name: "a\\n"` -- would be
# looked up as `a<LF>` and reported unindexed however exactly the README names it, while the
# decoded spelling of some OTHER name would answer for it.
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
  CP_WANT="\`$2\`" awk '
    BEGIN { want = ENVIRON["CP_WANT"] }
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

# --- fixture membership -----------------------------------------------------------------------
# A register lookup, like the prompt index: every test file has a command line in README and
# an inline run command on each required platform. This deliberately checks the workflow's
# current simple shape (literal runs-on and run), not arbitrary YAML or shell execution.
# Comments, names, echo arguments and longer filenames cannot stand in for a command.
fixture_command() {
  CP_SUITE="$2" CP_PLATFORM="${3:-}" awk '
    BEGIN { want = ENVIRON["CP_SUITE"]; required = ENVIRON["CP_PLATFORM"] }
    /^## / { tests = ($0 == "## Tests") }
    /^  [A-Za-z0-9_-]+:/ { platform = "" }
    /^[[:space:]]*runs-on: / {
      platform = $2; sub(/-latest$/, "", platform)
    }
    {
      if (required == "" && !tests) next
      line = $0
      sub(/^[[:space:]]*/, "", line)
      if (required != "") {
        if (platform != required || line !~ /^(- )?run: /) next
        sub(/^(- )?run: /, "", line)
      }
      sub(/^python3[[:space:]]+/, "", line)
      sub(/^\.\//, "", line)
      split(line, words, /[[:space:]]+/)
      if (words[1] == want) { found = 1; exit }
    }
    END { exit found ? 0 : 1 }
  ' "$1"
}

check_fixtures() {
  local suite platforms platform bad=0 count=0
  local workflow=.github/workflows/skill-scripts.yml
  # Include root scripts, skill scripts and hook fixtures; PowerShell belongs to Windows.
  for suite in "$ROOT"/scripts/test-* "$ROOT"/*/scripts/test-* "$ROOT"/*/hooks/test-*; do
    [ -f "$suite" ] || continue
    case "$suite" in *.sh|*.py|*.ps1) ;; *) continue ;; esac
    suite=${suite#"$ROOT"/}
    count=$((count + 1))
    case "$suite" in
      *.ps1) platforms=windows ;;
      # These probe Ubuntu production reporters and the Ubuntu-only hostile runner.
      scripts/test-workflow-reporters.py|ship-pr/scripts/test-pr-review-hostile.py) platforms=ubuntu ;;
      *) platforms="ubuntu macos" ;;
    esac
    if [ ! -f "$ROOT/README.md" ] || ! fixture_command "$ROOT/README.md" "$suite"; then
      ko README.md "fixture '$suite' has no command line in the test register"; bad=1
    fi
    for platform in $platforms; do
      if [ ! -f "$ROOT/$workflow" ] || ! fixture_command "$ROOT/$workflow" "$suite" "$platform"; then
        ko "$workflow" "fixture '$suite' has no inline run command on $platform"; bad=1
      fi
    done
  done
  # Scratch prompt-only roots need no workflow; a fixture creates the membership obligation.
  [ "$count" -eq 0 ] || [ "$bad" -ne 0 ] || ok "fixture command register and required CI platforms agree"
}

# --- the mac-studio correctness-slot count ----------------------------------------------------
# ludics-lite#160 raised `FLEET_BOX_CORRECTNESS_SLOTS`' mac-studio default from three to six, and
# the number is restated as prose all over the prompts. The default is one line of fleet-worker.sh;
# every other statement of it is English, and English does not fail a test when it goes stale -- so
# read the number off the script and require every statement to say the same thing.
#
# WHICH files are held is discovered, not listed: every `*.md` and `*.sh` under the root is scanned,
# and one is held exactly when it states the count. A list would need a member added each time a
# prompt starts quoting the number, which is the mistake this check exists to stop -- the first
# revision listed three files while `references/native-claude.md` and `scripts/test-fleet-worker.sh`
# quoted the count too. The checker and its own suite are the two exclusions: their `mac-studio=`
# text is patterns and messages, not a statement about the fleet. The three prompts PR #166 quoted
# it in are also REQUIRED to keep stating it, so the agreement cannot go vacuous by the prose
# quietly going away.
#
# WHAT counts as a statement is three shapes, which are the three the prose uses -- `mac-studio=<n>`
# (the whole token, so a malformed `mac-studio=6oops` is refused rather than accepted on its
# prefix), the number word in `<n> on mac-studio`, and the word opening the `<N>, not <m>`
# justification. The word form finds the PHRASE -- `on mac-studio` at a token boundary -- and reads
# the count as the run of numeral words standing before it: `twenty-six`, `twenty six` and
# `thirteen` are each the whole count they state and are refused, while `done on mac-studio` and
# `six on mac-studio-pro` state none. Matching a number word instead reads the first as `six`, the
# third as nothing at all, and `done` as a count.
#
# A third form was read and is deliberately no longer: the `<N>, not <m>` opening the justification
# sentence ("Six, not three, since ludics-lite#160"). Nothing in that shape says it is about slots
# -- the real ones carry `slot` only in the PREVIOUS sentence -- so reading it meant a proximity
# window, and a window wide enough to catch them is wide enough to read "Choose one, not two modes"
# beside the slot paragraph as a slot count. Every file still states its count in a form above, so
# the agreement is pinned; what is no longer pinned is that one sentence's number, which is a
# smaller loss than prose that cannot be written near a slot paragraph (ludics-lite#202). The word
# form is read WITHOUT such context for the same reason: `on mac-studio` is what makes a numeral a
# statement about this box, and the only stronger test available is the same proximity window that
# form was removed for. The cost is stated in #202 -- an unrelated `version six on mac-studio`
# would satisfy a required prompt's obligation to state the count.
# A numeral is a word, or hyphenated words, from $NUMERALS. Text INSIDE an assignment of the
# variable is skipped: a fixture configuring a two-slot box states its own input and claims nothing
# about the default. Which text that is, is answered structurally rather than by looking back a
# fixed distance -- the assignment word is walked from `…SLOTS=` to its first unquoted blank, so
# `export FLEET_BOX_CORRECTNESS_SLOTS="testbox=2 mac-studio=2"` is inside it however many pairs
# stand first. That last one is scoped to slot prose: both sides must be number words AND `slot`
# must stand within $SLOT_CONTEXT characters, so an ordinary "one, not both" sentence elsewhere in
# these long documents is not read as a slot declaration. Mentions are matched against the file
# joined into one line, so a sentence that wraps reads like one that does not. A root without
# fleet-worker.sh -- a scratch tree, a prompt-only checkout -- carries no obligation, as with the
# fixture register.
SLOT_SCRIPT=issue-wave/scripts/fleet-worker.sh
SLOT_PROMPTS='README.md issue-wave/SKILL.md issue-wave/references/executions.md'
SLOT_MECHANISM='scripts/check-prompts.sh scripts/test-check-prompts.sh'
NUMBER_WORDS='zero one two three four five six seven eight nine ten eleven twelve'
# The vocabulary a word-shaped count is recognized by -- wider than the spellings a default can
# take, because its job is to tell a stated count apart from an ordinary word, not to name one.
NUMERALS="$NUMBER_WORDS thirteen fourteen fifteen sixteen seventeen eighteen nineteen twenty
  thirty forty fifty sixty seventy eighty ninety hundred thousand million billion"

# number_word <n>: the English spelling of a small number; empty past the list above.
number_word() {
  local i=0 w
  for w in $NUMBER_WORDS; do
    [ "$i" = "$1" ] && { printf '%s\n' "$w"; return 0; }
    i=$((i + 1))
  done
}

# slot_files: every file the scan considers, root-relative and sorted, minus the mechanism's own.
slot_files() {
  find "$ROOT" -name .git -prune -o -type f \( -name '*.md' -o -name '*.sh' \) -print \
    | awk -v root="$ROOT/" -v skip=" $SLOT_MECHANISM " '
        index($0, root) == 1 {
          f = substr($0, length(root) + 1)
          if (index(skip, " " f " ") == 0) print f
        }' \
    | sort
}

# slot_mentions <file>: every statement of the mac-studio slot count in <file>, one per line, as
# `<kind> TAB <number> TAB <as written>` -- kind `digit` carrying the token past `mac-studio=`
# (which is the number only when the mention is well formed) and `word`/`not` the number word.
# Boundaries are spelled `[^a-z]` rather than `\b`, which BSD and GNU EREs do not read alike; the
# text is joined and space-prefixed so that stand-in always has a character to match.
slot_mentions() {
  local q="'"
  RE_DIGIT="[^a-z0-9_.-]mac-studio=[^[:space:]\`\"$q),;]*" \
  RE_WORD="[[:space:]]on[[:space:]]+mac-studio([^a-z0-9_.-]|$)" \
  NUMERALS="$(printf '%s' " $NUMERALS " | tr -s '[:space:]' ' ')" \
  awk "$SLOT_AWK_LIB"'
    # Each line is joined into one text, and masked alongside it: `a` marks a character inside an
    # assignment of the variable, `.` one in prose. Position for position, so a mention is judged
    # by where it stands rather than by what the 32 characters before it happen to spell.
    { text = text " " $0 }
    END {
      lower = tolower(text); find_assignments()
      scan(ENVIRON["RE_DIGIT"], "digit")
      scan(ENVIRON["RE_WORD"], "word")
    }
    # Walk every match of <re>, reporting each by its position in the joined text.
    # RSTART/RLENGTH are read ONCE per iteration and carried in locals: emit() matches too, and
    # advancing `rest` by a clobbered RSTART walks the cursor into the middle of the text.
    function scan(re, kind,   rest, base, st, len, at) {
      rest = lower; base = 0
      while (match(rest, re)) {
        st = RSTART; len = RLENGTH; at = base + st
        emit(kind, substr(text, at, len), at, len)
        base = at + len - 1
        rest = substr(rest, st + len)
      }
    }
    function emit(kind, frag, at, len,   n, box) {
      if (kind == "digit") {
        # The box name starts where the match says it does, past the boundary character: the
        # position of the name, not of the match, is what the value and the mask hang off.
        box = at + index(frag, "mac-studio=") - 1
        # The variable being SET, not a statement of its default.
        if (assignment_at(box)) return
        n = substr(frag, index(frag, "mac-studio=") + 11)
        # Punctuation that closes the mention is punctuation, wherever Markdown puts it -- `6]`,
        # `6.`, `6:` state six. A suffix that is not punctuation still makes the value malformed.
        sub(/[^A-Za-z0-9]+$/, "", n)
      } else {
        # The count is the RUN of numeral words standing before the phrase, read backwards: not a
        # number word found inside the text before it. `twenty-six`, `twenty six` and `six` are
        # each the whole count they state; `done on mac-studio` and `boxes. Six` state none here.
        n = numerals_before(at)
        if (n == "") return
        frag = n " " frag           # report the count with the phrase that carried it
      }
      sub(/^[^A-Za-z0-9]+/, "", frag); sub(/[^A-Za-z0-9]+$/, "", frag)
      print kind "\t" n "\t" frag
    }
    # find_assignments: the span of every assignment of the variable, over the JOINED text -- from
    # `…SLOTS=` through the end of the assignment word. Spans rather than a mask string, and over
    # the joined text rather than line by line: a word continued onto the next line (a trailing
    # backslash, or a quote still open) is one word to the shell, and it reads as one here because
    # the line break arrives as the blank that the escape or the quote covers.
    function find_assignments(   rest, base, st, at) {
      rest = lower; base = 0; spans = 0
      while (match(rest, /(^|[^a-z0-9_])[a-z0-9_]*slots=/)) {
        st = RSTART; at = base + st
        spans++
        span_from[spans] = at
        span_to[spans] = word_end(text, at + RLENGTH - 1)
        base = at + RLENGTH - 1
        rest = substr(rest, st + RLENGTH)
      }
    }
    # assignment_at <pos>: whether the character at <pos> stands inside one of those spans.
    function assignment_at(pos,   i) {
      for (i = 1; i <= spans; i++) if (pos >= span_from[i] && pos <= span_to[i]) return 1
      return 0
    }
    # numeral <word>: whether <word> is a count -- a word from the vocabulary, or hyphenated words
    # all of which are ("twenty-six"). An empty word is not one.
    function numeral(w,   parts, i, k) {
      if (w == "") return 0
      k = split(w, parts, "-")
      for (i = 1; i <= k; i++)
        if (index(ENVIRON["NUMERALS"], " " parts[i] " ") == 0) return 0
      return 1
    }
    # numerals_before <at>: the maximal run of numeral words ending just before <at>, in order and
    # separated by single blanks, or empty when the word there is not a numeral. A word carrying
    # trailing punctuation ENDS the run without joining it, so the `one.` closing a sentence does
    # not join the `Six` opening the next.
    function numerals_before(at,   from, w, k, i, word, run, joined) {
      from = at - 90; if (from < 1) from = 1
      k = split(substr(lower, from, at - from), w, /[[:space:]]+/)
      run = ""; joined = ""
      for (i = k; i >= 1; i--) {
        word = w[i]; sub(/^[^a-z]+/, "", word)
        if (word !~ /^[a-z][a-z-]*$/) break
        if (numeral(word)) {
          run = (joined != "") ? word " " joined " " run : (run == "" ? word : word " " run)
          joined = ""
        }
        # `one hundred and six` is one numeral; `and` joins only between two of them, so a bare
        # `and` before the phrase (`… and six on mac-studio`) leaves the run at six.
        else if (word == "and" && run != "" && joined == "") joined = "and"
        else break
      }
      return run
    }
  ' "$1"
}

# Shared by both readers below, so "where does the assigned value end" has one answer. A shell
# word ends at the first UNQUOTED, UNESCAPED blank, which is why `SLOTS="testbox=2 mac-studio=6"`
# and `SLOTS=testbox=2\ mac-studio=6` are each one word and not two.
SLOT_AWK_LIB='
  # word_end <line> <from>: index of the last character of the word that starts after <from>.
  function word_end(line, from,   i, c, q, plain) {
    q = ""; sq = sprintf("%c", 39); plain = 0
    for (i = from + 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (q == "") {
        if (c == "\\") { i++; continue }            # an escaped blank is part of the word
        if (c == "\"" || c == sq) { q = c; continue }
        if (c == " " || c == "\t") break
      } else if (c == q) q = ""
      else if ((c == " " || c == "\t") && plain == 0) plain = i - 1
    }
    # A quote that never closes was not quoting: prose carries apostrophes, and a word must not
    # run to the end of the text because one of them opened. Fall back to the unquoted reading.
    if (q != "" && plain > 0) return plain
    return i - 1
  }
  # uncommented <line>: <line> up to its comment, if it carries one -- a `#` outside quotes, at the
  # start or after a blank. A heredoc named in a comment opens no body, and queueing one would skip
  # the rest of the file as if it were data.
  function uncommented(line,   i, c, q, sq) {
    q = ""; sq = sprintf("%c", 39)
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (q == "") {
        if (c == "\\") { i++; continue }
        if (c == "\"" || c == sq) { q = c; continue }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:]]/)) return substr(line, 1, i - 1)
      } else if (c == q) q = ""
    }
    return line
  }
  # unquote <s>: <s> with the quote characters that grouped it removed.
  function unquote(s,   out, i, c, q) {
    out = ""; q = ""; sq = sprintf("%c", 39)
    for (i = 1; i <= length(s); i++) {
      c = substr(s, i, 1)
      if (q == "") {
        if (c == "\\") { out = out substr(s, ++i, 1); continue }   # the character, not the escape
        if (c == "\"" || c == sq) { q = c; continue }
      } else if (c == q) { q = ""; continue }
      out = out c
    }
    return out
  }
'

# as_number <token>: <token> as a decimal number, leading zeros dropped; a token that is not all
# digits is echoed back unchanged, so it is reported as written and agrees with nothing.
as_number() {
  case "$1" in '' | *[!0-9]*) printf '%s\n' "$1" ;; *) printf '%d\n' "$((10#$1))" ;; esac
}

# slot_default <file>: the `mac-studio=<n>` default inside the value assigned to SLOTS, or empty.
slot_default() {
  awk "$SLOT_AWK_LIB"'
    # A heredoc body is data the script WRITES, not code it runs: this one hands workers their
    # briefs, and a column-zero `SLOTS=` inside one assigns nothing. Bodies are skipped whole.
    # A delimiter is any word (`<<123` is valid), quoted however; the leading `[^<]` keeps a
    # here-STRING (`read -r -a pairs <<< "$SLOTS"`) from reading as a heredoc opened by its
    # second `<`.
    BEGIN { hd = "(^|[^<])<<-?[[:space:]]*[\"\\\\" sprintf("%c", 39) "]?[^[:space:];&|<>()]+" }
    queued > 0 {
      line = $0; if (dash[1]) sub(/^\t+/, "", line)
      if (line == delims[1]) {                 # this body ends; the next one on that line begins
        for (i = 1; i < queued; i++) { delims[i] = delims[i + 1]; dash[i] = dash[i + 1] }
        queued--
      }
      next
    }
    {
      # Every heredoc the line opens, in the order the shell consumes their bodies: one command
      # may declare several.
      rest = uncommented($0)
      while (match(rest, hd)) {
        tag = substr(rest, RSTART, RLENGTH)
        sub(/^[^<]/, "", tag)                  # the guard character, when the match took one
        queued++
        dash[queued] = (substr(tag, 3, 1) == "-")
        sub(/^<<-?[[:space:]]*/, "", tag); gsub(/["'"'"'\\]/, "", tag)   # bare, quoted or backslashed
        delims[queued] = tag
        rest = substr(rest, RSTART + RLENGTH)
      }
    }
    # A function body is defined, not run: an assignment inside one sets nothing until something
    # calls it, and nothing here does. Conventional shell layout is what this reads -- a definition
    # opening at column zero, its body closed by a `}` at column zero -- which is also what the
    # column-zero anchor below already assumes about the top level.
    /^[A-Za-z_][A-Za-z0-9_]*(\(\))?[[:space:]]*\{/ || /^function[[:space:]]/ { in_func = 1; next }
    in_func { if ($0 ~ /^\}/) in_func = 0; next }
    # The LAST top-level assignment, which is the one the shell is left holding -- reading the
    # first would report a default a later line has replaced (and `slot_mentions` skips that line
    # as an assignment, so nothing else would catch it either).
    /^SLOTS=/ {
      eq = index($0, "=")
      stop = word_end($0, eq)
      # `SLOTS=… some-command` scopes the assignment to that command and leaves the shell variable
      # alone, so only an assignment standing as the whole command sets the default. Nothing but a
      # comment may follow it.
      tail = substr($0, stop + 1); sub(/^[[:space:]]+/, "", tail)
      if (tail != "" && substr(tail, 1, 1) != "#") next
      # The value as the shell would take it: the assignment word with its quoting removed.
      val = unquote(substr($0, eq + 1, stop - eq))
      # EVERY mac-studio pair in the value, since `box_correctness_slots` validates the pairs in
      # order and refuses the whole spec on the first malformed one -- a good pair standing after
      # a bad one is never reached. The last VALID one is the default, since the registry dict
      # keeps the last value for a box named twice (a note in fleet-worker.sh). The value is an
      # expression here rather than a literal pair list (the roster default reaches it through
      # `… || echo mac-studio=6`), so a count ends at a blank or at the `)` and `}` closing that
      # expression; anything else in it means the pair was never `<box>=<n>`.
      last = ""; bad = ""; rest = val
      # A literal pair list -- no expansion, no substitution -- is exactly what the worker splits
      # and validates in order, so a malformed pair ANYWHERE in one refuses the whole spec and the
      # mac-studio entry behind it is never usable. An expression cannot be read this way: its
      # blank-separated tokens are shell syntax, not pairs, so only the mac-studio ones below are.
      if (val !~ /[$`(]/) {
        k = split(val, pairs, /[[:space:]]+/)
        for (i = 1; i <= k && bad == ""; i++)
          if (pairs[i] != "" && pairs[i] !~ /^[^=[:space:]]+=0*[1-9][0-9]*$/) bad = pairs[i]
      }
      while (match(rest, /(^|[^a-z0-9_.-])mac-studio=[^[:space:])}]*/)) {
        m = substr(rest, RSTART, RLENGTH)
        sub(/^[^m]/, "", m)                      # the boundary character, if the match took one
        count = substr(m, 12)
        if (count ~ /^[0-9]+$/) last = count; else if (bad == "") bad = m
        rest = substr(rest, RSTART + RLENGTH)
      }
      if (bad != "") last = "!" bad
    }
    END { print last }
  ' "$1"
}

check_slots() {
  local default word f kind n shown mentions stated=' ' bad=0
  [ -f "$ROOT/$SLOT_SCRIPT" ] || return 0
  # The default as the shell takes it: the `mac-studio=<n>` inside the SLOTS assignment's VALUE.
  # Read to the first UNQUOTED blank rather than to the end of the line, so a trailing comment --
  # `SLOTS="${FLEET_BOX_CORRECTNESS_SLOTS-}" # old mac-studio=6` -- cannot stand in for a default
  # the script no longer has; from the LAST such assignment, which is the one the shell keeps.
  default=$(slot_default "$ROOT/$SLOT_SCRIPT")
  case "$default" in
    # A pair the worker refuses outright, so nothing downstream of it is reached -- including a
    # well-formed duplicate later in the same spec.
    '!'*) ko "$SLOT_SCRIPT" "SLOTS assignment states '${default#\!}', which is not <box>=<positive n>"; return 0 ;;
    *[!0-9]* | '') ko "$SLOT_SCRIPT" "SLOTS assignment states no 'mac-studio=<n>' default"; return 0 ;;
  esac
  # As a NUMBER before anything is decided about it, not as the digits that spell it: the worker
  # reads `mac-studio=06` as six and `mac-studio=00` as zero (`test` and Python both take the
  # leading zero as decimal), so both the positivity rule and the spelling below judge the value.
  default=$(as_number "$default")
  # The worker's own grammar: `box_correctness_slots` refuses a pair whose count is below one, so
  # a zero default is a roster every mac-studio slot call dies on, not a count to agree with.
  [ "$default" -ge 1 ] || { ko "$SLOT_SCRIPT" "SLOTS assignment states mac-studio=$default; the worker requires <box>=<positive n>"; return 0; }
  # An unspellable default (past the vocabulary) leaves the word forms unmatchable rather than
  # unchecked: any numeral then mismatches and says what the script actually pins.
  word=$(number_word "$default")
  # Line by line: a path with a space in it would otherwise split into words, and the resulting
  # reads of nonexistent paths increment nothing -- the file would be skipped under a clean pass.
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    mentions=$(slot_mentions "$ROOT/$f")
    [ -n "$mentions" ] || continue
    stated="$stated$f "
    while IFS="$(printf '\t')" read -r kind n shown; do
      [ -n "$kind" ] || continue
      case "$kind" in
        digit) [ "$(as_number "$n")" = "$default" ] \
          || { ko "$f" "states '$shown'; $SLOT_SCRIPT defaults to mac-studio=$default"; bad=1; } ;;
        *) [ "$n" = "$word" ] \
          || { ko "$f" "spells the mac-studio slot count '$n'; $SLOT_SCRIPT defaults to mac-studio=$default"; bad=1; } ;;
      esac
    done <<<"$mentions"
  done <<<"$(slot_files)"
  # A prompt that stops stating the count is how the agreement would quietly stop being checked.
  for f in $SLOT_PROMPTS; do
    case "$stated" in
      *" $f "*) ;;
      *) ko "$f" "states no mac-studio slot count in a form this check reads ('mac-studio=$default', '$word on mac-studio')"; bad=1 ;;
    esac
  done
  [ "$bad" -ne 0 ] || ok "mac-studio correctness slots agree: $SLOT_SCRIPT and every file that states the count say $default"
}

# --- run --------------------------------------------------------------------------------------
if $ONE; then
  if [ -f "$ROOT/SKILL.md" ]; then check_skill_file SKILL.md
  else ko SKILL.md "missing regular SKILL.md in $ROOT"; fi
  echo "check-prompts: $pass passed, $fail failed"
  [ "$fail" -eq 0 ]
  exit $?
fi

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
check_fixtures
check_slots

echo
echo "check-prompts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
