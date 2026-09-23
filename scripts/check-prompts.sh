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
# Five cross-file agreements ride along, each pinning a fact the prompts only restate: every test
# fixture has a command in the README's register and a run line on each CI platform it needs, and
# every file that quotes the mac-studio correctness-slot count quotes the one fleet-worker.sh
# actually defaults to (ludics-lite#160) -- which files those are is discovered, not listed.
# A third reads the routines sync-routines.sh installs off its own LOCAL_ROUTINES line and
# requires each of their prompts to RUN that script -- the command line, not a mention of the
# name -- so the step 0 that makes an installed copy's drift visible cannot be edited away in
# silence (ludics-lite#199).
#
# A fifth compares ship-pr/SKILL.md with post-merge-cleanup.sh's usage(): every option the
# heredoc lists is named in the prompt, and every `--option` the prompt's fenced command lines
# pass to the helper is one usage() lists -- the two files ludics-lite#276 found edited apart
# (see `check_cleanup_options` for what "of the helper" means on the prompt's side) -- and
# usage()'s <value> placeholders agree with the `shift` of each option's arm in the helper's own
# parser, since that arity is what the prompt's values are skipped by (ludics-lite#302).
#
# A fourth reads the relative Markdown links in those prompts, their reference files and the two
# READMEs: the path a `](….md)` link spells exists relative to the linking file, and an anchor on
# it is the GitHub slug of a heading in the target -- so the section links ludics-lite#260 created
# and verified by hand cannot rot in silence (see `check_links` for the one shape it reads).
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
    { text = text " " $0; code = code " " uncommented($0) }
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
    function emit(kind, frag, at, len,   n, box, name) {
      if (kind == "digit") {
        # The match was found in the lowercased text, so the box name is located there: `frag`
        # keeps the original case (`MAC-STUDIO=6` is the same statement) and an index into it
        # would miss.
        name = index(tolower(frag), "mac-studio=")
        # The box name starts where the match says it does, past the boundary character: the
        # position of the name, not of the match, is what the value and the mask hang off.
        box = at + name - 1
        # The variable being SET, not a statement of its default.
        if (assignment_at(box)) return
        n = substr(frag, name + 11)
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
      # Past the comments, not over the raw text: `# … SLOTS=mac-studio=6 with the default roster`
      # is one of the prose declarations this check exists to hold, and masking it would excuse it
      # from the agreement it is supposed to keep. Same positions either way -- the line keeps its
      # length -- and quoted values are kept, since a quoted value is part of its assignment.
      rest = tolower(code); base = 0; spans = 0
      while (match(rest, /(^|[^a-z0-9_])[a-z0-9_]*slots=/)) {
        st = RSTART; at = base + st
        spans++
        span_from[spans] = at
        span_to[spans] = word_end(code, at + RLENGTH - 1)
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
  # uncommented <line>: <line> with its comment dropped -- a `#` outside quotes, at the start or
  # after a blank -- and padded back to its original length so positions do not shift. Quoted text
  # is KEPT: the value of an assignment is usually quoted, and belongs to it.
  function uncommented(line,   i, c, q, sq, out) {
    q = ""; sq = sprintf("%c", 39)
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (q == "") {
        if (c == "\\") { i++; continue }
        if (c == "\"" || c == sq) { q = c; continue }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:]]/)) {
          out = substr(line, 1, i - 1)
          while (length(out) < length(line)) out = out " "
          return out
        }
      } else if (c == q) q = ""
    }
    return line
  }
  # code_of <line>: the part of <line> the shell would EXECUTE -- its comment dropped (a `#`
  # outside quotes, at the start or after a blank) and its quoted text blanked out. Both are places
  # a `<<word` can stand without opening anything, and queueing a heredoc that never arrives skips
  # the rest of the file as if it were data, which hides every assignment after it.
  function code_of(line,   i, j, c, q, sq, dq, out) {
    q = ""; sq = sprintf("%c", 39); out = ""
    for (i = 1; i <= length(line); i++) {
      c = substr(line, i, 1)
      if (q == "") {
        if (c == "\\") { out = out "  "; i++; continue }
        # A redirection operator and the word after it are copied whole, quotes and all: the
        # quotes in `<<'"'"'EOF'"'"'` belong to the operator, and blanking them would lose the heredoc
        # this function exists to find.
        if (c == "<" && substr(line, i + 1, 1) == "<") {
          j = i
          while (substr(line, j, 1) == "<") { out = out "<"; j++ }
          if (substr(line, j, 1) == "-") { out = out "-"; j++ }
          while (j <= length(line) && substr(line, j, 1) ~ /[[:space:]]/) { out = out substr(line, j, 1); j++ }
          dq = substr(line, j, 1)
          if (dq == "\"" || dq == sq) {
            out = out dq; j++
            while (j <= length(line) && substr(line, j, 1) != dq) { out = out substr(line, j, 1); j++ }
            if (j <= length(line)) { out = out dq; j++ }
          } else
            while (j <= length(line) && substr(line, j, 1) !~ /[[:space:];&|<>()]/) { out = out substr(line, j, 1); j++ }
          i = j - 1
          continue
        }
        if (c == "\"" || c == sq) { q = c; out = out " "; continue }
        if (c == "#" && (i == 1 || substr(line, i - 1, 1) ~ /[[:space:]]/)) {
          while (length(out) < length(line)) out = out " "      # the length stands; the code stops
          return out
        }
        out = out c
      } else {
        if (c == q) q = ""
        out = out " "          # same length, so nothing shifts under the caller
      }
    }
    return out
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
      rest = code_of($0)
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
      # alone, so a WORD after the assignment means it sets nothing. A separator or a redirection
      # does not: `SLOTS=…; export SLOTS` is an assignment-only command, and it persists.
      tail = substr($0, stop + 1); sub(/^[[:space:]]+/, "", tail)
      if (tail != "" && tail !~ /^[#;&|<>)]/) next
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
    # A file that cannot state the count is skipped before the heavy scan, rather than joined and
    # walked to be found silent. The filter is exactly equivalent: BOTH mention shapes
    # `slot_mentions` reads -- the `mac-studio=<n>` digit form and the `<numerals> on mac-studio`
    # word form -- contain the literal string `mac-studio`, so a file without it anywhere states
    # no count in either. The word form may WRAP across a line, and the scan joins the lines to
    # read it; `mac-studio` itself is never what the wrap splits (it is one word, and the blank
    # the scan restores stands between words), so a line-based grep still finds it. Judged on
    # grep's OUTPUT, never on a `grep -q` pipeline's status, for the reason `matches` gives: -q
    # stops at the first match, the producer then dies of SIGPIPE, and under pipefail the result
    # would invert on a large file. -m1 is grep's own early exit reading the file directly, with
    # no producer to kill.
    #
    # -a and -o are what keep that equivalence true of the OUTPUT rather than only of the match.
    # A NUL anywhere in the file makes grep call it binary, and the three greps this script runs
    # under then disagree in a way that would decide the check: BSD grep prints `Binary file …
    # matches` on STDOUT (non-empty, so the file is scanned), GNU grep 3.5+ prints that same line
    # on STDERR and leaves stdout empty, and ugrep reports no match at all -- so the same tree
    # would be held on macOS and let through on the Linux CI. -a reads the file as the text every
    # other reader here takes it for, and -o then prints the MATCH rather than its line, so a NUL
    # on the matching line cannot ride into the command substitution (where bash drops it with a
    # warning on stderr) and the capture stays one word however long the line is.
    [ -n "$(grep -aiFom1 -e mac-studio -- "$ROOT/$f")" ] || continue
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

# --- the installed-routine drift guard ---------------------------------------------------------
# A local scheduled task runs from a COPY under ~/.claude/scheduled-tasks, necessarily (the
# scheduler refuses a task file reached through a symlink), and a copy drifts from this checkout
# in silence: the task fires on time, the run looks normal, and the only thing wrong is that the
# prompt is old. ludics-lite#199 is a week of that. The guard against it lives inside the prompts
# -- each installed routine opens by running scripts/sync-routines.sh and reading its own verdict
# -- and prose does not fail a test when somebody edits it away. So this pins that it is there.
#
# WHICH prompts are held is read off the script that installs them: the one-line LOCAL_ROUTINES
# assignment, the same line scripts/test-sync-routines.sh reads, so a routine added to the sync
# arrives here already obliged and a retired one stops being.
#
# WHAT is required is the COMMAND, not a mention of it. Both prompts name sync-routines.sh in
# their explanatory and reporting prose several times over, so a check that matched the filename
# would go on passing over a prompt whose indented command line had been deleted -- the guard
# gone, the prose about it left standing, and the checker reporting the step present. So the
# match is the shape a prompt runs a command in: a Markdown indented-code line (four spaces or
# more, which is what both prompts use) whose whole content is THE path to this checkout's copy
# of the script -- the invocation, in STATUS mode, and nothing else. That path is not restated
# here either: its `~/ludics-lite` half is read off the README's own clone command. Every weaker
# reading was tried and is refused for a reason somebody would otherwise reach for: a
# `push`/`pull` argument writes where the obligation is to read; `echo`/`cat` and friends put the
# path in some other command's argument; `DRIFT_COMMAND=<path>` assigns it and runs nothing; a
# leading `#` is how a guard is usually disabled rather than deleted; a backtick makes the line
# prose quoting a command; and a same-basename path elsewhere is another file entirely. Whether the prompt then READS the verdict is a review
# question no lookup settles; this pins the one thing a lookup can see, which is that the command
# is still there. Same shape as the fixture register and the slot count.
SYNC_SCRIPT=scripts/sync-routines.sh

# checkout_path: where the README's install section clones this repository to (`~/ludics-lite`),
# read off that clone command rather than restated here -- the prompts invoke the script through
# that path, and it is the README's fact. Empty when there is no such line to read.
checkout_path() {
  [ -f "$ROOT/README.md" ] || return 0
  # The first match, taken by expansion rather than by `| head -1`: an early-exiting reader would
  # SIGPIPE the producer, which under pipefail is the failure this file's `matches` avoids too.
  local all
  all=$(sed -n 's|^git clone [^ ]*ludics-lite\.git \(~/[A-Za-z0-9_.-][A-Za-z0-9_.-]*\)[[:space:]]*$|\1|p' \
    "$ROOT/README.md")
  printf '%s\n' "${all%%$'\n'*}"
}

check_drift_guard() {
  local names r f home want bad=0
  # A root without the sync script installs nothing, so it carries no obligation -- as with the
  # fixture register, whose obligation comes from a fixture, and the slot count's from the worker.
  [ -f "$ROOT/$SYNC_SCRIPT" ] || return 0
  # The path the prompts must invoke, spelled from the README's clone destination and this
  # script's own repo-relative location -- so neither is restated here, and a `/tmp/…` or any
  # other same-basename path is not this checkout's script.
  home=$(checkout_path)
  if [ -z "$home" ]; then
    ko README.md "no 'git clone … ~/<dir>' line to read the checkout path from; the routines' drift step cannot be checked"
    return 0
  fi
  # As an ERE: `~` and `.` are literals, and `$HOME` is accepted for the same path.
  want="(~|[$]HOME)/$(printf '%s' "${home#\~/}" | sed 's/[.]/[.]/g')/$(printf '%s' "$SYNC_SCRIPT" | sed 's/[.]/[.]/g')"
  names=$(sed -n 's/^LOCAL_ROUTINES="\([^"]*\)"[[:space:]]*$/\1/p' "$ROOT/$SYNC_SCRIPT")
  if [ -z "$names" ]; then
    # Not a pass: the obligation exists and this reader cannot see who carries it.
    ko "$SYNC_SCRIPT" "has no one-line LOCAL_ROUTINES=\"...\" naming the routines it installs"
    return 0
  fi
  # A name a word at a time, through `tr`: an unquoted expansion would also GLOB, and a routine
  # name holding a `*` would be replaced by whatever it matched in the caller's directory.
  while IFS= read -r r; do
    [ -n "$r" ] || continue
    f="routines/$r/SKILL.md"
    if [ ! -f "$ROOT/$f" ]; then
      ko "$SYNC_SCRIPT" "installs '$r', but this checkout has no $f to install from"; bad=1; continue
    fi
    # An indented-code line that IS the invocation: the line's whole content, after the indent,
    # is THE path to this checkout's script and nothing else. Spelling the whole path is what
    # makes the match a claim about this script rather than about a basename -- a /tmp one is
    # some other file, possibly none -- and it rules out, in one shape, every way of holding the
    # path without running it: a blank (so `echo …` and `cat …` put it in another command's
    # arguments), an `=` (an assignment executes nothing), a `#` (how a guard gets disabled,
    # rather than by deleting it), a backtick (prose quoting a command), and anything following
    # the path (a `push`/`pull` argument writes, where the obligation is the status read).
    # `${want}` braced: `$want[` reads as an array expansion to shellcheck (SC1087), and the
    # `[` here opens the bracket expression, not a subscript.
    matches "^ {4,}${want}[[:space:]]*\$" "$(cat "$ROOT/$f")" \
      || { ko "$f" "runs no $home/$SYNC_SCRIPT: an installed routine reads its own drift with an indented command line invoking THAT path in status mode (ludics-lite#199)"; bad=1; }
  done <<<"$(tr -s '[:space:]' '\n' <<<"$names")"
  [ "$bad" -ne 0 ] || ok "every routine $SYNC_SCRIPT installs runs it to read its own drift"
}

# --- the post-merge-cleanup option register ----------------------------------------------------
# ship-pr/SKILL.md is where an operator learns what post-merge-cleanup.sh takes, and the two are
# edited apart: ludics-lite#276 added `--regenerable` to the helper's usage() and documented it in
# the prompt by hand, in the same PR that found the prompt's prose about the base-owner gate had
# been false through at least two earlier PRs. Nothing but a reader compares the two files, so
# this pins the one fact a lookup can see, in both directions: every option usage()'s heredoc
# LISTS is named, verbatim, somewhere in the prompt, and every `--option` the prompt PASSES to the
# helper is one usage() lists. What is an option OF the helper, on the prompt's side, is a line
# shape and not a judgement: the helper's command lines -- a line inside a backtick fence naming
# `post-merge-cleanup.sh`, from that name to the first shell separator, and every line a trailing
# backslash continues it onto, lexed as the shell lexes a simple command. The shell's grammar is
# modelled only as far as `invocation_options` states, which also says how each residue errs. A
# `--flag` in
# prose, or on some other command's line (`gh pr merge --delete-branch`, the test runner's
# `--list`), is attributed to nothing, so an option the prompt explains but never passes is not
# held to the register from that side. And a name present is a name present: whether the prose
# around it is still true is the review question ludics-lite#276 was, which no scan settles.
# The arity usage() gives each option -- whether a `<value>` placeholder follows it -- is what the
# prompt's side skips a value by, so it is held to the helper's own parser too: each listed option
# has a `--name)` arm whose `shift` consumes what the listing says, and each arm is listed
# (ludics-lite#302 found `--force-integrated` listed bare over a `shift 2`; `parser_options` says
# what of the parser is read).
CLEANUP_HELPER=ship-pr/scripts/post-merge-cleanup.sh
CLEANUP_PROMPT=ship-pr/SKILL.md

# usage_options <script>: the options usage()'s heredoc lists, one per line as `--name<TAB>arity`
# -- each line of the body, between the `usage() {` line and its closing `}`, that opens with two
# blanks and a `--name`, which is the listing's own shape (`  --base <branch>  Base branch …`), and
# the arity is 1 when a `<value>` placeholder follows the name, else 0. The delimiter is whatever
# word the `<<` names, quoted or not, with or without a blank after the operator and whatever
# else the line carries after it (a `>&2`, a comment), and under `<<-`
# the body's leading tabs are stripped as the shell strips them; a `}` inside the heredoc is text
# and does not close the function; the prose below the listing, which mentions an option
# mid-sentence, is at no such indent and is not read.
usage_options() {
  awk '
    !infn && /^usage\(\) \{/ { infn = 1; next }
    # The closing brace ends the function only OUTSIDE the heredoc: a `}` in the usage text is
    # data, and exiting on it would drop every option listed below it while the register stayed
    # nonempty -- an agreement over half the list.
    infn && !inhd && /^\}/ { exit }
    infn && !inhd && match($0, /<<-?[[:space:]]*("[^"]+"|'"'"'[^'"'"']+'"'"'|[^[:space:]"'"'"'<>|&;()]+)/) {
      d = substr($0, RSTART, RLENGTH); dash = (d ~ /^<<-/)
      sub(/^<<-?[[:space:]]*/, "", d); gsub(/["'"'"']/, "", d)
      inhd = 1; next
    }
    inhd {
      l = $0
      if (dash) sub("^\t+", "", l)
      if (l == d) { inhd = 0; next }
      if (match(l, /^  --[A-Za-z0-9][A-Za-z0-9-]*([[:space:]]|$)/)) {
        o = substr(l, 3, RLENGTH - 2); sub(/[[:space:]]$/, "", o)
        print o "\t" (substr(l, RLENGTH + 1) ~ /^[[:space:]]*</ ? 1 : 0)
      }
    }
  ' "$1"
}

# invocation_options <prompt> <valued>: every `--option` the prompt's helper command lines pass,
# one per line. A command line is a line inside a backtick fence lexed as the shell lexes a simple
# command, on which some word's last path component is `post-merge-cleanup.sh` -- a quoted path,
# a `(` or an `out=$(` prefix all carry it, and `test-post-merge-cleanup.sh` is another file --
# from that word to the first shell separator (`;`, `&&`, `||`, `|`, `&`, or the `)` that closes a
# subshell or substitution) outside quotes, plus each line a trailing backslash continues it onto;
# what follows a separator is lexed again for a second invocation. The lexing: words split on unquoted blanks,
# single quotes literal, double quotes with the four escapes, a backslash escaping the next
# character, an unquoted `#` opening a word starting a comment, and a redirection (`2>&1`, `>&2`,
# `<&0`, `&>log`) carrying no separator. A word opening with `--` is an option, and the word after
# an option in <valued> (the register's arity-1 names, blank-separated) is that option's value
# whatever it looks like, since the helper takes it so. A fence is a run of three or more
# backticks up to three blanks in, closed only by a run at least as long with nothing after it, as
# CommonMark reads them.
# That grammar is the reader's boundary, and it is the boundary every scanner in this file has
# (README, Tests: a scanner reads line shapes, and text crafted to carry the shape without the
# substance, or the substance in another shape, is outside it -- ludics-lite#75). What this
# establishes is that the options the prompt's commands SPELL agree with usage(); it does not
# establish that every shell-valid encoding of an invocation is read. Encodings outside the
# grammar are unread, not misread, and the prompt writes none of them: a quoted argument spanning
# lines, a `$(…)` substitution standing as an argument, a redirection glued to the command word, a
# word split by a backslash continuation, options held in a `$var`, a `~~~` fence. Each could be
# added as a shape; none is, because the check reads the prompt's commands and not the shell's
# language, and the list of encodings a shell accepts has no end that a scan would reach.
invocation_options() {
  awk -v valued=" $2 " '
    # lex <line>: the words of one simple command into W[1..NW]; TERM and REST when a separator
    # ended it, CONT when an unquoted backslash ends the line.
    function lex(line,   i, n, c, q, word, have) {
      NW = 0; REST = ""; TERM = 0; CONT = 0; q = ""; word = ""; have = 0
      n = length(line)
      for (i = 1; i <= n; i++) {
        c = substr(line, i, 1)
        if (q == "") {
          if (c ~ /[[:space:]]/) { if (have) { W[++NW] = word; word = ""; have = 0 }; continue }
          if (c == "\\") {
            if (i == n) { CONT = 1; break }
            word = word substr(line, ++i, 1); have = 1; continue
          }
          if (c == "\"" || c == "\047") { q = c; have = 1; continue }
          if (c == "#" && !have) break
          if (c == ";" || c == "|" || c == ")" || (c == "&" && substr(line, i + 1, 1) != ">")) {
            TERM = 1; REST = substr(line, i + 1); break
          }
          if (c == "&") { i++; if (substr(line, i + 1, 1) == ">") i++; continue }
          if ((c == ">" || c == "<") && substr(line, i + 1, 1) == "&") {
            i++; while (substr(line, i + 1, 1) ~ /[0-9-]/) i++; continue
          }
          word = word c; have = 1; continue
        }
        if (c == q) { q = ""; continue }
        if (q == "\"" && c == "\\" && substr(line, i + 1, 1) ~ /["\\$`]/) { word = word substr(line, ++i, 1); continue }
        word = word c
      }
      if (have) W[++NW] = word
    }
    match($0, /^ {0,3}`{3,}/) {
      run = RLENGTH - index($0, "`") + 1
      if (!fence) { fence = 1; flen = run; cont = 0; skip = 0; next }
      if (run >= flen && substr($0, RLENGTH + 1) ~ /^[[:space:]]*$/) { fence = 0; cont = 0; next }
    }
    !fence { cont = 0; next }
    {
      line = $0
      while (1) {
        lex(line)
        start = 1
        if (!cont) {
          # The helper is a WORD whose last path component is its name, once the lexer has
          # unquoted it -- so a quoted path, a `(` or an `out=$(` prefix all carry it, and
          # `test-post-merge-cleanup.sh` does not.
          start = 0
          for (i = 1; i <= NW; i++)
            if (W[i] ~ /(^|[^A-Za-z0-9_.-])post-merge-cleanup\.sh$/) { start = i + 1; skip = 0; break }
          if (!start) { if (!TERM) break; line = REST; continue }
        }
        for (i = start; i <= NW; i++) {
          if (skip) { skip = 0; continue }
          if (W[i] !~ /^--./) continue
          print W[i]
          if (index(valued, " " W[i] " ") > 0) skip = 1
        }
        cont = CONT
        if (!TERM) break
        line = REST; cont = 0
      }
    }
  ' "$1"
}

# parser_options <script>: the options the helper's own parser takes, one per line as
# `--name<TAB>arity`, so usage()'s arity -- which is what `invocation_options` skips a value on --
# is pinned to what the parser consumes rather than to a placeholder typed by hand (ludics-lite#302
# found `--force-integrated` listed bare while its arm did `shift 2`). A parser outside the grammar
# below prints one `!<TAB><why>` line instead, and the caller refuses it whole.
#
# The parser is READ only in the shape the helper writes, and every level of it is an allowlist:
# review rounds kept finding shapes in which text the reader took for the parser does not run as
# one -- a repeated shift, a shift in a comment, quote, argument, conditional, subshell, heredoc or
# nested case, behind a `continue`, split by an escape, an arm shadowed by an earlier pattern or
# sharing a line with another, a shift after the `esac` -- and a denylist of such shapes has no end
# (rounds 1-6). What is read:
#  - the block: a `while [ "$#" -gt 0 ]; do` line, `case "$1" in` on the next, the arms, `esac` at
#    the `case` line's indent, then `done`, with only blank and comment lines between the two --
#    so nothing else in the loop consumes an argument;
#  - a pattern: one bare `--name)` opening a line, or one `*)` that is the LAST arm and whose body
#    is `usage` alone -- so no pattern can match a long option ahead of its own arm;
#  - an arm: its pattern line through the line ENDING in `;;`, with no other `;;` in it -- so one
#    line is never two clauses;
#  - a statement, once each quoted span is a plain word and `#` comments are dropped: `shift` or
#    `shift N`, a single assignment word (`NAME=word`, `NAME+=(word)`, no operator or blank outside
#    quotes), or a `[ … ] || usage` guard, whose `usage` exits; with no quote left open and no
#    backslash, since the split is per line and per `;` and models neither.
#  - a byte: printable ASCII or a tab, in every line from the `case` line to `done` -- a CR that a
#    trim would drop is part of the word to the shell.
# A `--name)` arm is read when all its statements are in that grammar and exactly one is a shift,
# whose arity is N-1 (`shift 2` is 1, a bare `shift` is 0); otherwise it prints `?`, which the
# caller refuses as unread. Any other departure is the whole parser's. The cost is stated: a
# harmless statement outside the grammar (an `echo`) is refused until the grammar grows with it,
# which is a false refusal on a line the operator can see and not a false agreement nobody reads.
# That is the reader's boundary, the same line-shape boundary as the rest of this file (README,
# Tests; ludics-lite#75): it establishes that each arm's shift agrees with its listing, not that the
# arm reads `$2` or that the parser is the one the script runs, and it takes `usage` to exit and `[`
# to be the test builtin.
parser_options() {
  LC_ALL=C awk '
    function bad(why) { print "!\t" why; over = 1; exit }
    function trim(t) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); return t }
    !inp && /^[[:space:]]*while \[ "\$#" -gt 0 \]; do[[:space:]]*$/ { want = 1; next }
    want && !inp && match($0, /^[[:space:]]*case "\$1" in[[:space:]]*$/) {
      ind = substr($0, 1, index($0, "c") - 1); inp = 1; want = 0; next
    }
    !inp { want = 0; next }
    # A carriage return, or any other byte that is neither printable nor a tab, is a character the
    # trim below would drop and the shell keeps: `shift 2` before a CR is `shift` refusing "2\r"
    # (round 7, P2). The block is read in the C locale, so a non-ASCII byte is refused too.
    /[^[:print:]\t]/ { bad("a byte that is neither printable ASCII nor a tab, such as a CRLF line end") }
    # Between `esac` and `done` the loop runs every iteration: a statement there consumes
    # arguments no arm accounts for (round 6, P2).
    post {
      if ($0 ~ /^[[:space:]]*(#.*)?$/) next
      if ($0 ~ /^[[:space:]]*done[[:space:]]*(#.*)?$/) { closed = 1; exit }
      bad("a statement between esac and done: " trim($0))
    }
    !arm && $0 ~ ("^" ind "esac[[:space:]]*(#.*)?$") { post = 1; next }
    !arm && $0 ~ /^[[:space:]]*(#.*)?$/ { next }
    # case runs the FIRST arm that matches, so a pattern that can match a long option ahead of its
    # own arm -- a glob, an alternation, an escaped or quoted spelling -- decides the arity the arm
    # below it only claims (rounds 4-6, P2).
    !arm {
      if (star) bad("a line after the catch-all *) arm, which matches first: " trim($0))
      if (match($0, /^[[:space:]]*--[A-Za-z0-9][A-Za-z0-9-]*\)/)) {
        name = trim(substr($0, RSTART, RLENGTH - 1))
      } else if (match($0, /^[[:space:]]*\*\)/)) {
        name = ""; star = 1
      } else bad("a case pattern other than one bare --name) or a final *): " trim($0))
      arm = 1; ar = ""; ns = 0; amb = 0; $0 = substr($0, RSTART + RLENGTH)
    }
    arm {
      # Quoted spans are text, each standing as one plain word Q, and a `#` opening a word -- after
      # a blank, a `;` or an operator, `;;# shift 2` included -- starts a comment (round 1, P2).
      l = $0
      gsub(/\047[^\047]*\047/, "Q", l); gsub(/"([^"\\]|\\.)*"/, "Q", l)
      if (match(l, /(^|[[:space:];&|()])#/)) l = substr(l, 1, RSTART + RLENGTH - 2)
      # A quote left open runs onto the next line and a backslash escapes what follows it, a `;`
      # included: the per-line, per-`;` split models neither (round 5, P2).
      if (l ~ /["\047\\`]/) amb = 1
      closes = sub(/;;[[:space:]]*$/, "", l)
      if (index(l, ";;")) bad("a ;; that does not end its line, which makes it two clauses: " trim($0))
      nseg = split(l, seg, ";")
      for (k = 1; k <= nseg; k++) {
        g = trim(seg[k])
        if (g == "") continue
        if (star) { if (g != "usage") amb = 1; continue }
        if (g ~ /^shift([[:space:]]+[0-9]+)?$/) {
          ar = (match(g, /[0-9]+/) ? substr(g, RSTART, RLENGTH) : 1) - 1; ns++
        } else if (g ~ /^[A-Za-z_][A-Za-z0-9_]*\+?=([^[:space:]&|<>()`]*|\([^[:space:]&|<>()`]*\))$/) {
        } else if (g ~ /^\[ [^][&|<>()`]* \] \|\| usage$/) {
        } else amb = 1
      }
      if (!closes) next
      # Every shift in the arm runs in sequence, so a second one -- equal or not -- consumes more
      # than either says: the arity of an arm is read off exactly one.
      if (star && amb) bad("a catch-all *) arm doing more than usage")
      if (!star) print name "\t" (ns == 1 && !amb ? ar : "?")
      arm = 0
    }
    END { if (inp && !over && !closed) print "!\tno esac at the case line indent followed by done" }
  ' "$1"
}

check_cleanup_options() {
  local listed parsed valued passed o a p sh n nl bad=0
  nl=$'\n'
  # A root without the helper documents no helper, so it carries no obligation -- the same rule as
  # the drift guard's sync script and the slot count's worker.
  [ -f "$ROOT/$CLEANUP_HELPER" ] || return 0
  if [ ! -f "$ROOT/$CLEANUP_PROMPT" ]; then
    ko "$CLEANUP_HELPER" "has no $CLEANUP_PROMPT to document its options in"
    return 0
  fi
  listed=$(usage_options "$ROOT/$CLEANUP_HELPER")
  if [ -z "$listed" ]; then
    # Not a pass: an empty register would hold the prompt to nothing, in silence.
    ko "$CLEANUP_HELPER" "usage() lists no options this reader can see: a heredoc line opening with two blanks and a --name"
    return 0
  fi
  # usage()'s arity against the parser's, both ways by name: the arity is what the prompt's
  # values are skipped by, so a placeholder the parser does not back is a register that lies.
  parsed=$(parser_options "$ROOT/$CLEANUP_HELPER")
  case "$parsed" in *'!'$'\t'*)
    # A parser outside the grammar is not compared arm by arm: which arm runs is what is unread.
    ko "$CLEANUP_HELPER" "the option parser is not one this reader can read: ${parsed##*!$'\t'} (see parser_options)"
    bad=1; parsed="" ;;
  "")
    ko "$CLEANUP_HELPER" "has no option parser this reader can see: a 'while [ \"\$#\" -gt 0 ]; do' line, then 'case \"\$1\" in' and '--name)' arms"
    bad=1 ;;
  esac
  while IFS=$'\t' read -r o a; do
    [ -n "$o" ] || continue
    [ -n "$parsed" ] || break
    p=$(printf '%s\n' "$parsed" | awk -F'\t' -v o="$o" '$1 == o { print $2; exit }')
    if [ -z "$p" ]; then
      ko "$CLEANUP_HELPER" "usage() lists '$o', for which the option parser has no '$o)' arm"; bad=1
    elif [ "$p" = "?" ]; then
      ko "$CLEANUP_HELPER" "the parser's '$o)' arm is not one this reader can read: it needs exactly one 'shift' or 'shift N' among straight-line statements -- single assignment words and '[ … ] || usage' guards (see parser_options)"; bad=1
    elif [ "$p" != "$a" ]; then
      sh=shift; [ "$p" -eq 0 ] || sh="shift $((p + 1))"
      if [ "$a" = 1 ]; then
        ko "$CLEANUP_HELPER" "usage() lists '$o' with a <value> placeholder, but its parser arm does '$sh' and takes none: the placeholder is what the prompt's values are skipped by (ludics-lite#302)"
      else
        ko "$CLEANUP_HELPER" "usage() lists '$o' with no <value> placeholder, but its parser arm does '$sh' and takes a value (ludics-lite#302)"
      fi
      bad=1
    fi
  done <<<"$listed"
  while IFS=$'\t' read -r o a; do
    [ -n "$o" ] || continue
    printf '%s\n' "$listed" | awk -F'\t' -v o="$o" '$1 == o { f = 1 } END { exit !f }' \
      || { ko "$CLEANUP_HELPER" "the option parser takes '$o', which usage() does not list"; bad=1; }
  done <<<"$parsed"
  valued=$(printf '%s\n' "$listed" | awk -F'\t' '$2 == 1 { printf "%s ", $1 }')
  listed=$(printf '%s\n' "$listed" | cut -f1)
  n=$(printf '%s\n' "$listed" | grep -c .)
  passed=$(invocation_options "$ROOT/$CLEANUP_PROMPT" "$valued" | sort -u)
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    # The token whole, and in the token grammar the invocation side uses: `--base` is not found
    # inside `--base-branch` or `--base_branch`, and `.` is a literal.
    matches "(^|[^A-Za-z0-9_.-])$(printf '%s' "$o" | sed 's/[.]/[.]/g')([^A-Za-z0-9_.-]|\$)" "$(cat "$ROOT/$CLEANUP_PROMPT")" \
      || { ko "$CLEANUP_PROMPT" "names no '$o', which $CLEANUP_HELPER's usage() lists: the prompt is where the option is learned of (ludics-lite#276)"; bad=1; }
  done <<<"$listed"
  while IFS= read -r o; do
    [ -n "$o" ] || continue
    case "$nl$listed$nl" in *"$nl$o$nl"*) ;; *)
      ko "$CLEANUP_PROMPT" "passes '$o' to $CLEANUP_HELPER, whose usage() lists no such option"; bad=1 ;;
    esac
  done <<<"$passed"
  [ "$bad" -ne 0 ] \
    || ok "$CLEANUP_PROMPT and $CLEANUP_HELPER's usage() agree on the helper's options ($n listed), and usage() agrees with its parser on each one's arity"
}

# --- relative links and anchors ----------------------------------------------------------------
# A prompt that points at another prompt points at a PATH, and since ludics-lite#260 often at a
# HEADING inside it: that PR cut `issue-wave/SKILL.md` and its references into sections addressed
# by anchor -- `cli-claude.md#supervising`, `native-workers.md#placement-and-launch`,
# `separate-codex.md#ci-and-review-evidence` and five more -- and every one of them was verified by
# hand, once. Nothing re-verifies them: a renamed file, a moved section and a retitled heading all
# leave the link rendering as a link and landing nowhere, which is a defect a reader finds and a
# test never does. This makes that one-time verification permanent.
#
# Scope is the prompts and the two READMEs that index them, plus the reference files the prompts
# delegate to: `*/SKILL.md`, `*/references/*.md`, `routines/*/SKILL.md`, `README.md` and
# `routines/README.md`.
#
# The scan is fixed and deterministic, and carries no Markdown model, for the reason `indexed`
# above carries none (ludics-lite#75): what it reads is ONE shape, `](<target>)` on one line with
# no blank inside the target and a path half ending in `.md`, and what it then claims is two
# lookups -- the path exists relative to the LINKING file, and the anchor is the GitHub slug of one
# of the target's ATX headings. Everything outside that shape is not checked rather than guessed
# at, and each of those gaps reports nothing rather than reporting wrongly: a target carrying a URI
# scheme or a leading `/` (`https://…`, `mailto:…`, `/x.md`) is not a file in this checkout; a
# target with a blank in it -- a `](path.md "Title")` link -- is outside the form; a `](#anchor)`
# names no file and a non-`.md` target has no headings to name; a target spelled in anything but
# ordinary path characters (a `%` escape, a backslash, an angle-bracket destination) is one this
# scan does not decode; a reference-style `[text][ref]` is a different syntax; and a link whose
# `](` and `)` fall on different lines is not one line.
#
# What the scan will not do is answer about the MACHINE instead of the prompts. A path spelling its
# way out of the checkout, and one walking out through a symbolic link, are both refused on the
# path -- never probed, so no file beside the checkout can make an outside link read as resolving.
#
# There is no BLOCK scope, and that is the one gap cutting both ways. Every line is read on its
# own, so a heading-shaped line GFM would not render as a heading -- inside a fenced block, an
# HTML block, an HTML comment -- contributes a slug here anyway. That direction only makes the
# ANCHOR lookup more permissive: it can accept a link GitHub would not resolve, and it refuses
# none. Keeping that second half TRUE is a constraint on everything else in this section, and it
# has been broken once already: the slug suppression round 3 added let a phantom heading refuse
# real anchors, which is what took it out again in round 9. The other direction is the costly one: a link written inside a fence or between backticks
# is read like any other, so prose ILLUSTRATING the syntax is read as the link it spells. That
# cost is real and was paid the first time this check was documented -- the README's own sentence
# about it had to describe the shape rather than write one.
#
# It is still the cheaper side, and the alternative was weighed rather than assumed. A block model
# -- fences with their info strings, tildes, nesting and indentation, HTML blocks with their seven
# start conditions, comments -- is the same table model whose edge cases took thirteen review
# rounds of ludics-lite#75. Refusing anchors in any file that CONTAINS such a block is worse than
# the gap it closes: with no fence scope, an HTML comment quoted inside a fenced example would
# take every anchored link into that file down with it, and these prompts quote a great deal of
# markup. A permissive lookup accepts a link nobody wrote; that refusal would reject links people
# did write. Both directions are pinned by probes, so the shape of the gap is on record.

# link_files: the Markdown whose links this check reads, root-relative. A routine's reference
# files are in it for the same reason a skill's are: the prompt delegating to one is checked, and
# the second hop out of it would otherwise be the one place a missing target passed. No routine
# keeps a references/ directory today, so the glob is there ahead of the first one.
link_files() {
  (cd "$ROOT" && for f in README.md routines/README.md */SKILL.md routines/*/SKILL.md \
    */references/*.md */references/.*.md routines/*/references/*.md \
    routines/*/references/.*.md; do [ -f "$f" ] && echo "$f"; done) | sort -u
}

# md_links <rel> <dir>: every link of the read shape in the root-relative file <rel>, one per line,
# as `<rel> TAB <target> TAB <resolved> TAB <anchor>` -- the file, for the message; the target as
# WRITTEN, which is what the message names; the path it spells, resolved; and the anchor, empty
# when the link carries none. Resolution happens inside this scan, rather than in a reader of its
# own, because this is the one thing in the file that runs once per LINK and not once per file: a
# reader per link is six dozen processes per run of the checker, over a string operation awk is
# already standing in front of.
#
# resolve: the path as written, read from <rel>'s directory, with its `.` and `..` segments taken
# out. Lexically, and never through the filesystem: what a link means is the path it spells, and
# `readlink -f` would answer for wherever a symlink under it points -- and would answer nothing at
# all for the missing file this is about to report. A path that climbs past the root keeps its
# leading `..`, so it is reported as the nonexistent file it is.
md_links() {
  CP_REL="$1" CP_DIR="$2" awk '
    BEGIN { rel = ENVIRON["CP_REL"]; dir = ENVIRON["CP_DIR"] }
    {
      line = $0
      while ((i = index(line, "](")) > 0) {
        # A link opens with a LABEL, and the label is the bracket THIS `]` closes -- not any `[`
        # standing earlier. `[note] then ](x.md)` has a bracket before it and opens no link, so
        # looking for any at all still failed prose that is perfectly fine, which is the one way
        # this scan can fail a file with nothing wrong with it. Walked backwards from the `]`,
        # counting the pairs that close on the way, so a `[` already closed answers for nothing.
        # A bracket a backslash made literal is text, and closes or opens nothing -- `\[note](x.md)`
        # renders as prose. Parity, not presence: `\\[note]` is an escaped BACKSLASH followed by a
        # real opener. The `]` of this candidate is read the same way, since an escaped one closes
        # no label either.
        label = 0; depth = 0
        if (escaped(line, i)) { line = substr(line, i + 2); continue }
        for (k = i - 1; k >= 1; k--) {
          c = substr(line, k, 1)
          if (c != "[" && c != "]") continue
          if (escaped(line, k)) continue
          if (c == "]") depth++
          else if (depth == 0) { label = 1; break }
          else depth--
        }
        line = substr(line, i + 2)
        if (label == 0) continue
        # The target ends at the paren that CLOSES the one the link opened, not at the first `)`:
        # a Markdown destination may carry balanced parentheses, and `a_(b).md` cut at the first
        # one is `a_(b`, which then fails the `.md` test and takes a real link out of the scan in
        # silence. A destination whose parens do not balance on the line -- an escaped one
        # included, since this reads no escapes -- leaves the line with no close, and is outside
        # the shape like every other link this cannot see the end of.
        depth = 1; j = 0
        for (k = 1; k <= length(line); k++) {
          c = substr(line, k, 1)
          if (c == "(") depth++
          else if (c == ")" && --depth == 0) { j = k; break }
        }
        # The cursor now stands just past this `](`, and it STAYS there for every candidate this
        # pass does not accept -- whether the parens never close or the target is refused below.
        # A false `](` is a false candidate, and everything after it on the line is still text to
        # read: `Token ]( prose [guide](missing.md).)` balances its parens around the real link,
        # so advancing past the closing one swallowed that link and the run came out green.
        # Only an ACCEPTED link advances the cursor past itself. Progress holds either way,
        # because each pass has already shortened the line by the `](` it stepped over.
        if (j == 0) continue
        target = substr(line, 1, j - 1)
        if (target ~ /[[:space:]]/) continue       # a titled link, say: outside the form
        if (target ~ /^[A-Za-z][A-Za-z0-9+.-]*:/) continue    # a URI scheme: not a path here
        if (substr(target, 1, 1) == "/") continue             # nor is an absolute path
        hash = index(target, "#")
        path = (hash > 0) ? substr(target, 1, hash - 1) : target
        anchor = (hash > 0) ? substr(target, hash + 1) : ""
        if (path !~ /\.md$/) continue              # `](#anchor)` and `](LICENSE)` alike
        # And SPELLED as a path in this checkout: ASCII letters and digits with `. _ - / ( ) ~ +`,
        # and `#` for the anchor. A percent escape (`my%20notes.md`), a backslash, an angle-bracket
        # destination or an entity is a spelling this scan does not decode -- and a decoded reading
        # is one it would have to guess at, then guess at again for the next encoding somebody
        # reaches for. One rule instead: a target written in anything else is outside the shape,
        # like a titled one. The cost is that a file whose name needs escaping goes unchecked; the
        # names in this checkout are dashed and lowercase, and that is the convention to keep.
        if (target ~ /[^A-Za-z0-9._\/()~+#-]/) continue
        line = substr(line, j + 1)                 # accepted: the cursor may pass the whole link
        print rel "\t" target "\t" resolve(dir, path) "\t" anchor
      }
    }
    # escaped <text> <at>: whether the character at <at> stands behind an odd number of
    # backslashes, which is what makes it literal rather than a delimiter.
    function escaped(text, at,   b) {
      b = 0
      while (at - b - 1 >= 1 && substr(text, at - b - 1, 1) == "\\") b++
      return b % 2
    }
    function resolve(dir, path,   parts, k, i, out, n, s) {
      k = split(dir "/" path, parts, "/")
      n = 0
      for (i = 1; i <= k; i++) {
        if (parts[i] == "" || parts[i] == ".") continue
        if (parts[i] == ".." && n > 0 && out[n] != "..") { n--; continue }
        out[++n] = parts[i]
      }
      s = ""
      for (i = 1; i <= n; i++) s = (s == "") ? out[i] : s "/" out[i]
      return s
    }' "$ROOT/$1"
}

# heading_slugs <file> [prefix]: the GitHub anchor of every ATX heading in <file>, one per line and
# in file order, each behind the optional <prefix> -- which is how the whole lookup table below is
# built with one reader per target file rather than one per anchor.
# The slug is GitHub's own reading: lowercased, each blank turned into a hyphen, the ASCII
# word characters and the hyphen kept and everything else dropped -- and a slug already seen in the
# file takes the `-1`, `-2` suffix GitHub gives a repeated heading, so the second `## Close-out` is
# reachable as `#close-out-1` rather than unreachable.
# A heading whose anchor this check will not spell -- one carrying a non-ASCII byte that is not
# General Punctuation, so possibly a letter GitHub keeps -- contributes no slug, and is reported as
# `!<heading>` instead, so a link that misses in that file can say why it could not be answered.
heading_slugs() {
  CP_PREFIX="${2:-}" awk '
    BEGIN {
      prefix = ENVIRON["CP_PREFIX"]
      # The byte sets `slug` reads, built rather than spelled: an octal byte range inside a
      # bracket expression is not something every awk on the fleet reads alike, and sprintf is.
      for (n = 1; n <= 127; n++) ascii[sprintf("%c", n)] = 1
      # U+2000-U+206F, General Punctuation, in UTF-8: E2 80 80 .. E2 81 AF.
      for (n = 128; n <= 191; n++) punctuation[sprintf("%c%c%c", 226, 128, n)] = 1
      for (n = 128; n <= 175; n++) punctuation[sprintf("%c%c%c", 226, 129, n)] = 1
      # The ASCII punctuation a backslash may escape, which is the list CommonMark gives: the
      # four ranges standing either side of the letters and digits.
      for (n = 33; n <= 47; n++) escapable[sprintf("%c", n)] = 1
      for (n = 58; n <= 64; n++) escapable[sprintf("%c", n)] = 1
      for (n = 91; n <= 96; n++) escapable[sprintf("%c", n)] = 1
      for (n = 123; n <= 126; n++) escapable[sprintf("%c", n)] = 1
      bom = sprintf("%c%c%c", 239, 187, 191)
      cr = sprintf("%c", 13)
    }
    {
      line = $0
      # A byte-order mark opens a file rather than a line, and GFM removes it before it parses
      # anything -- so the first heading of a file that carries one is a heading, and leaving the
      # bytes in front of its hashes refused a link that works.
      if (FNR == 1 && index(line, bom) == 1) line = substr(line, 4)
      # A carriage return is the other half of a CRLF line ending, not content: awk splits on the
      # LF and leaves it standing. It defeated the closing-hash rule outright -- `## Foo ##<CR>`
      # kept the blank before the hashes and slugged to `foo-`, refusing `#foo` and accepting a
      # `#foo-` that is not there -- and it turned every trailing blank into a hyphen besides.
      if (substr(line, length(line), 1) == cr) line = substr(line, 1, length(line) - 1)
      # A blockquote marker before the heading is the container, not the heading: GFM renders
      # `> ## Foo` as a heading with the anchor `foo`, and skipping it refused a link that works.
      # A run of them is stripped, which is the whole of the block model this reads -- and with
      # the indentation limits GFM puts on it, since four spaces opens an indented code block
      # instead: `    > ## Foo` is code, and stripping its marker recorded an anchor that does not
      # exist. At most three spaces before each marker, then the one space the marker itself
      # takes; what is left goes to the same limit again in the ATX test below, so `>     ## Foo`
      # is code inside the quote and stays unread.
      # A heading inside a LIST item is deliberately not read -- whether `- ## Foo` opens one
      # depends on the list indentation and continuation rules around it, which is the block
      # parser this file does not have -- and such a link is refused, loudly and naming the
      # anchor, never accepted for a heading that is not there.
      col = 0
      while (1) {
        indent = 0; while (substr(line, indent + 1, 1) == " ") indent++
        if (indent > 3 || substr(line, indent + 1, 1) != ">") break
        col += indent + 1                          # past the indent and the marker itself
        line = substr(line, indent + 2)
        # The one space the marker takes may be written as a tab, which GFM expands to the next
        # tab stop -- and the marker takes ONE column of that expansion, not the whole of it. The
        # columns left over are indentation, and dropping them changed the block: `><TAB>  ##`
        # is four columns in and so an indented code block, where discarding the tab left two and
        # recorded a heading GFM does not render. Kept as the spaces they expand to, so the ATX
        # test below reads the same indentation GFM does.
        if (substr(line, 1, 1) == " ") { line = substr(line, 2); col++ }
        else if (substr(line, 1, 1) == "\t") {
          pad = 4 - (col % 4) - 1                  # the tab stop, less the column the marker takes
          line = substr(line, 2)
          while (pad-- > 0) line = " " line
          col++
        }
      }
      # An ATX heading, by GFM: up to three leading spaces, one to six hashes, then a blank. The
      # counts are walked rather than matched, since an ERE interval is not something every awk on
      # the fleet reads alike.
      spaces = 0; while (substr(line, spaces + 1, 1) == " ") spaces++
      if (spaces > 3) next
      hashes = 0; while (substr(line, spaces + hashes + 1, 1) == "#") hashes++
      if (hashes < 1 || hashes > 6) next
      rest = substr(line, spaces + hashes + 1)
      # A heading may END at its hash run -- `#` alone is an empty heading to GFM, and skipping it
      # cost its successors their numbering as well as itself: with `#` before `## !!!`, the
      # second is `-1` on GitHub and was being read as the first empty slug.
      if (rest != "" && rest !~ /^[ \t]/) next     # `#tag` is text to GFM, not a heading
      sub(/[ \t]+#+[ \t]*$/, "", rest)             # the optional closing run of hashes
      # The content of a heading is trimmed HERE, as GFM trims it -- before the inline reading,
      # not after. Trimming the rendered text instead threw away a space a code span had
      # preserved: `## ` foo`` renders ` foo` (one-sided padding is kept, where two-sided is
      # stripped) and is `-foo` on GitHub, which a later trim turned into `foo`.
      sub(/^[ \t]+/, "", rest); sub(/[ \t]+$/, "", rest)
      s = slug(rest)
      # A heading this check will not spell still OCCUPIES a slug on GitHub, and the numbering is
      # occupancy-based: `## [Foo](…)` then `## Foo` are `foo` and `foo-1` there, while this reads
      # the second as `foo`. What that costs is bounded, and the bound is what makes it the right
      # trade: every slug this reading emits for a heading is a slug GitHub HAS -- for that
      # heading, or for the earlier one it collided with -- so an anchor accepted here always
      # resolves there. What is lost is the other direction: a `-<n>` anchor standing after such a
      # heading is refused, and the `!` line below tells the reader why.
      #
      # Suppressing every later slug instead was tried and is deliberately gone (ludics-lite#268,
      # round 9). It refused anchors rather than merely failing to confirm them, and with no block
      # scope above, a heading-shaped line inside a FENCE could be the unspellable one -- so a
      # fenced `## [Example](…)` took every real anchor after it in the file down with it. That
      # also cost the block-scope gap the property the whole of it rests on, which is that a
      # phantom heading can only make the lookup more permissive and can refuse nothing.
      if (s == "!") { if (refused == 0) print prefix "!" rest; refused = 1; next }
      # The numbering GitHub does is a LOOP over free names, not a counter per base: a candidate
      # already taken takes the next `-<n>` that is not, so `# Foo`, `# Foo-1`, `# Foo` give `foo`,
      # `foo-1`, `foo-2`. A counter gives `foo-1` twice -- which both rejects a good link to
      # `#foo-2` and lets `#foo-1` answer for either heading.
      # An empty slug is still an OCCUPANT: a heading of pure punctuation slugs to nothing, and
      # `## !!!` written twice is "" and "-1" on GitHub, so a link to `#-1` works there. Skipping
      # both left `-1` out of the table and refused it. The empty name itself is never printed --
      # no anchor can spell it, and a `file.md#` carries no anchor to this scan -- but it takes
      # its place in the numbering, so its repeats take theirs.
      base = s
      while (taken[s]) { occurrences[base]++; s = base "-" occurrences[base] }
      taken[s] = 1
      if (s != "") print prefix s
    }
    # slug <heading>: its GitHub anchor, or `!` for a heading whose anchor this check will not
    # spell. The ASCII half is exact. Beyond it, only the General Punctuation block is known --
    # the dashes, curly quotes and ellipsis this prose is written with, every one of which GitHub
    # drops -- and any OTHER non-ASCII byte is a character that may be a letter GitHub keeps
    # (`# Cafe\u0301` slugs to `cafe\u0301`, not to `caf`). Dropping it silently would not only refuse the
    # right anchor, it would ACCEPT the wrong one: `#caf` would answer for that heading. So such a
    # heading contributes no slug at all, and a link that means it is refused, with the reason.
    # render_spans <h>: the one construct whose CONTENT is literal text, resolved rather than
    # refused, because these headings are full of it. It sets two readings of the heading, from
    # one walk -- the same text-and-mask shape `slot_mentions` uses further up this file.
    #   SPAN_TEXT: each code span replaced by what it RENDERS to. A span opens at a backtick run
    #     and closes at the next run of the SAME length; where its content both begins and ends
    #     with a space and is not all spaces, CommonMark strips one from each end, which is the
    #     divergence that brought this here -- `## ` foo ` ` is `foo` on GitHub, and reading the
    #     source gave `-foo-`. A run with no closing match is literal backticks, left as it is.
    #   SPAN_BARE: the same heading with each span, and each backslash-escaped character, replaced
    #     by a single `.`, for the markup tests below to read. The content of a span is literal text, so `## `_foo_`` is `_foo_` on
    #     GitHub and must not be refused as emphasis; `.` rather than a letter, because it is
    #     punctuation to the flanking rule, which is the conservative side of that test.
    function render_spans(h,   i, c, n, j, k, m, content, text, bare) {
      # ONE walk, left to right, which is the order the inline reading actually happens in. Two
      # global passes -- escapes resolved everywhere, then spans paired -- were wrong about their
      # interaction, and in the direction that matters: a backslash does not escape INSIDE a code
      # span, so `## `\`_foo_`` opens a span at the first backtick, closes it at the one after the
      # backslash, and leaves `_foo_` outside it as emphasis. Marking that closing backtick
      # escaped paired the first with the LAST instead and recorded `_foo_`.
      # Walking once gets both rules from their position in the walk rather than from a rule about
      # which pass wins: a backslash is an escape only when it is REACHED as text, which is to say
      # outside a span, and the search for a closing run reads the raw backticks it passes.
      text = ""; bare = ""; i = 1
      while (i <= length(h)) {
        c = substr(h, i, 1)
        if (c == "\\" && i < length(h) && (substr(h, i + 1, 1) in escapable)) {
          # An escaped character is literal, and so is a delimiter of nothing: it stands in the
          # rendered text as itself and reads as `.` to the markup tests.
          text = text substr(h, i + 1, 1); bare = bare "."
          i += 2
          continue
        }
        if (c != "`") { text = text c; bare = bare c; i++; continue }
        n = 0; while (substr(h, i + n, 1) == "`") n++
        j = i + n; k = 0
        while (j <= length(h)) {
          if (substr(h, j, 1) != "`") { j++; continue }
          m = 0; while (substr(h, j + m, 1) == "`") m++
          if (m == n) { k = j; break }
          j += m
        }
        if (k == 0) {                              # no closing run: literal backticks
          text = text substr(h, i, n); bare = bare substr(h, i, n); i += n; continue
        }
        content = substr(h, i + n, k - i - n)
        if (content ~ /^ / && content ~ / $/ && content ~ /[^ ]/)
          content = substr(content, 2, length(content) - 2)
        text = text content; bare = bare "."
        i = k + n
      }
      SPAN_TEXT = text; SPAN_BARE = bare
    }
    # linked <text>: whether <text> carries a `](` whose `]` closes a bracket opened earlier -- the
    # same label test `md_links` applies, and for the same reason: `## Token ](literal)` renders no
    # link, and GitHub gives it the ordinary `token-literal`. No escape parity is needed here, as
    # `render_spans` has already replaced every escaped character, and every span, with a `.`.
    function linked(t,   i, k, c, depth, from) {
      from = 1
      while ((i = index(substr(t, from), "](")) > 0) {
        i = from + i - 1
        depth = 0
        for (k = i - 1; k >= 1; k--) {
          c = substr(t, k, 1)
          if (c == "]") depth++
          else if (c == "[") { if (depth == 0) return 1; else depth-- }
        }
        from = i + 2
      }
      return 0
    }
    function slug(h,   i, c, out) {
      # A heading whose RENDERED text differs from its SOURCE is one this check will not spell:
      # GitHub slugs what it renders, and rendering means a Markdown parser. Three shapes do that,
      # and they are tested narrowly so the far commoner literal readings keep working --
      #   - inline link, image or reference syntax (`## [Foo](https://example.com)` is `foo`
      #     there and `foohttpsexamplecom` here), while a literal `## Notes [draft]` renders as
      #     its source and slugs to `notes-draft` on both sides;
      #   - an HTML tag or an autolink, `<` before a letter or a `/!?` (`## <em>Foo</em>` is
      #     `foo` there and `emfooem` here), while a literal `## A < B` renders as its source and
      #     gives `a--b` on both sides;
      #   - a character entity, `&<name>;` (`## A &amp; B` renders `A & B` and gives `a--b`,
      #     where the source reading gives `a-amp-b`), while a bare `## Launch & supervise` is
      #     text on both sides.
      # Emphasis, strong and code spans need no test: their markers are punctuation that both
      # readings drop, so `## **Bold** text` and `## `code` here` already agree.
      render_spans(h)
      if (linked(SPAN_BARE) || index(SPAN_BARE, "][") > 0) return "!"
      # A `<` is only markup once the construct CLOSES: `## Use <Type` parses no tag, and GitHub
      # gives it the ordinary `use-type`, so refusing on the opening character alone refused a
      # heading that is plain text. A tag, an autolink or a comment, each spelled whole.
      if (SPAN_BARE ~ /<\/?[A-Za-z][A-Za-z0-9-]*([[:space:]][^<>]*)?\/?>/) return "!"
      if (SPAN_BARE ~ /<[A-Za-z][A-Za-z0-9+.-]*:[^<>[:space:]]*>/) return "!"
      if (SPAN_BARE ~ /<!--.*-->/) return "!"
      # The rest of the raw-HTML forms, which render as markup and contribute no heading text:
      # a processing instruction, a declaration, a CDATA section. `## <?target?>` is nothing at
      # all to GitHub, where the source reading gave it `target`.
      if (SPAN_BARE ~ /<\?[^<>]*\?>/) return "!"
      if (SPAN_BARE ~ /<![A-Za-z][^<>]*>/) return "!"
      if (index(SPAN_BARE, "<![CDATA[") > 0) return "!"
      # A character reference renders as markup only when it DECODES. A numeric one always does;
      # a named one does only if HTML defines it, and that table is two thousand entries this
      # check will not carry -- so the named ones held are the ones this prose could plausibly
      # write, and anything else is read as the literal text it renders as. `## Rock &bogus; Roll`
      # keeps its anchor, where the shape test alone refused it. The residue is stated rather than
      # hidden: a VALID named reference outside this list reads as literal text here, which is the
      # permissive direction, and the list is the place to add one if a heading ever needs it.
      if (SPAN_BARE ~ /&#[0-9]+;/ || SPAN_BARE ~ /&#[xX][0-9A-Fa-f]+;/) return "!"
      if (SPAN_BARE ~ /&(amp|lt|gt|quot|apos|nbsp|copy|reg|trade|hellip|mdash|ndash|laquo|raquo|deg|times|divide|plusmn|micro|para|sect|dagger|bull|lsquo|rsquo|ldquo|rdquo);/) return "!"
      # Underscore emphasis is the one emphasis marker the two readings do NOT agree on, because
      # the slugger keeps `_` as a word character: `## _Foo_` renders as `Foo` and is `foo` there,
      # while the source reading gives `_foo_`. `*` needs no such test -- it is punctuation both
      # readings drop. CommonMark makes `_` emphasis only where it is not intraword, and that
      # flanking rule is the whole test here: an `_` with an alphanumeric on BOTH sides is
      # literal, so `## snake_case` and `## FLEET_BOX_CORRECTNESS_SLOTS` are text on both sides
      # and keep their anchors; any other `_` may open or close emphasis, and its heading is not
      # spelled. A `substr` before the first character is the empty string, which flanks nothing.
      for (i = 1; i <= length(SPAN_BARE); i++)
        if (substr(SPAN_BARE, i, 1) == "_" && !(substr(SPAN_BARE, i - 1, 1) ~ /^[A-Za-z0-9]$/ \
            && substr(SPAN_BARE, i + 1, 1) ~ /^[A-Za-z0-9]$/)) return "!"
      h = tolower(SPAN_TEXT)                       # ASCII only, by locale, as GitHub folds ASCII
      out = ""
      for (i = 1; i <= length(h); i++) {
        c = substr(h, i, 1)
        # Only a literal SPACE becomes a hyphen. A tab is a control character, which the slugger
        # removes before it replaces spaces, so `## Foo<TAB>Bar` is `foobar` there -- hyphenating
        # it approved a `#foo-bar` that does not exist and refused the `#foobar` that does. It
        # falls through to the ASCII drop below.
        if (c == " ") { out = out "-"; continue }
        if (c ~ /^[a-z0-9_-]$/) { out = out c; continue }
        if (c in ascii) continue                   # ASCII punctuation, which GitHub drops
        if (substr(h, i, 3) in punctuation) { i += 2; continue }
        return "!"
      }
      return out
    }' "$1"
}

# symlinked <relpath>: whether <relpath>, under the root, is a symbolic link or is reached through
# one. The lexical `..` guard keeps a path from SPELLING its way out of the checkout; a symlink
# walks out without spelling anything, and `-f` follows it, so a `references/x.md` pointing at the
# runner's filesystem would have its existence -- and its headings -- read off the host. Same class
# as the `..` guard, and the same answer: refused on the path, before anything is read.
# Every component is tested, since it is as easily a parent directory that leaves. Only components
# BELOW the root are, so a checkout reached through a symlink (macOS `/tmp`, this suite's own
# scratch tree) is not itself the finding. A symlink that stays inside the checkout is refused
# too: nothing here uses one, and "no symlink on the path" is a rule with no host in it, where
# "no symlink that escapes" needs the canonical resolution this deliberately does not do.
symlinked() {
  local rest="$1" acc="" seg
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    if [ "$seg" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
    [ -n "$seg" ] || continue
    acc="${acc:+$acc/}$seg"
    [ -L "$ROOT/$acc" ] && return 0
  done
  return 1
}

# cased <relpath>: whether every component of <relpath> is spelled as the checkout spells it. On
# a case-insensitive filesystem -- the macOS default, and this suite runs on macOS and on Ubuntu
# both -- `-f` answers yes for a link to `References/Notes.md` over a `references/notes.md`, while
# GitHub serves that link as a 404. Unchecked, the same head passes on one runner and fails on the
# other, and the verdict is about the box rather than about the prompts: the same class as the
# `..` and symlink guards above.
# Read with a GLOB rather than with `ls`, so a path still costs no process: the kernel matches a
# name case-insensitively, but the shell compares the names a directory actually holds, and it
# compares them exactly.
cased() {
  local rest="$1" parent="" seg entry found
  while [ -n "$rest" ]; do
    seg=${rest%%/*}
    if [ "$seg" = "$rest" ]; then rest=""; else rest=${rest#*/}; fi
    [ -n "$seg" ] || continue
    found=0
    # Three globs, because `*` alone skips every name beginning with a dot -- so a component like
    # `.refs` was never enumerated and a correctly spelled path read as mis-cased. The other two
    # take the dotted names while leaving `.` and `..` out, which is the whole of what they add.
    for entry in "$ROOT${parent:+/$parent}"/* "$ROOT${parent:+/$parent}"/.[!.]* \
      "$ROOT${parent:+/$parent}"/..?*; do
      [ "${entry##*/}" = "$seg" ] && { found=1; break; }
    done
    [ "$found" -eq 1 ] || return 1
    parent="${parent:+$parent/}$seg"
  done
  return 0
}

check_links() {
  local rel dir links all="" wanted t target resolved anchor slugs="" hint nl tab count=0 bad=0
  nl=$'\n'; tab=$(printf '\t')
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    # The same guard the targets get, on the READING side: `link_files` globs, and `-f` follows a
    # symbolic link, so a `references/x.md` pointing out of the checkout would have its links --
    # and its size -- taken from the host. Reported rather than skipped: a prompt file that is a
    # symlink is a defect in the checkout, and skipping it would leave its links unread in silence.
    if symlinked "$rel"; then
      ko "$rel" "is reached through a symbolic link, so its links are not read"; bad=1; continue
    fi
    dir=${rel%/*}; [ "$dir" = "$rel" ] && dir=.
    links=$(md_links "$rel" "$dir")
    [ -n "$links" ] || continue
    all="$all$links$nl"
  done <<<"$(link_files)"
  # No link is no verdict on the links, as no fixture is no verdict on the register: the obligation
  # comes from a link, and a prompt-only scratch root may carry none.
  [ -n "$all" ] || return 0
  # The slug table: every heading of every target an ANCHORED link names, read ONCE per target file.
  # A prompt that points eight times into one reference would otherwise re-read it eight times.
  wanted=$(printf '%s' "$all" | awk -F"$tab" '$4 != "" { print $3 }' | sort -u)
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    # The same two guards the report loop applies, applied HERE as well, because this is where the
    # target is first touched: a prepass that probed and then read a target the loop below was
    # about to refuse would have opened the host file the guards exist to keep out, and the
    # refusal afterwards would come too late to matter.
    case "$t" in .. | ../*) continue ;; esac
    symlinked "$t" && continue
    [ -f "$ROOT/$t" ] || continue
    cased "$t" || continue
    slugs="$slugs$(heading_slugs "$ROOT/$t" "$t$tab")$nl"
  done <<<"$wanted"
  # A tab at a time, and line by line: a path may hold a blank, and splitting on one would read a
  # link nobody wrote and then report the file it did not find.
  while IFS="$tab" read -r rel target resolved anchor; do
    [ -n "$rel" ] || continue
    count=$((count + 1))
    # A path that climbed past the root is refused on the path itself, and never probed on the
    # filesystem: `$ROOT/../outside.md` is a real path on the host, so a file of that name beside
    # the checkout would make an out-of-repository link read as resolving -- a verdict about the
    # machine the check ran on rather than about the prompts.
    case "$resolved" in
      .. | ../*) ko "$rel" "link to $target resolves outside the checkout: $resolved"; bad=1; continue ;;
    esac
    if symlinked "$resolved"; then
      ko "$rel" "link to $target is reached through a symbolic link: $resolved"; bad=1; continue
    fi
    if [ ! -f "$ROOT/$resolved" ]; then
      ko "$rel" "link to $target resolves to no file: $resolved"; bad=1; continue
    fi
    if ! cased "$resolved"; then
      ko "$rel" "link to $target finds $resolved only on a case-insensitive filesystem; the checkout spells that path differently, and GitHub serves the link as written"
      bad=1; continue
    fi
    [ -n "$anchor" ] || continue
    # The anchor is compared as TEXT and in full, the way `indexed` compares a name: a `.` in an
    # anchor is that character and `#close` does not find `close-out`, because the pattern is a
    # whole `<target> TAB <slug>` line of the table with a newline on either side of it.
    case "$nl$slugs" in
      *"$nl$resolved$tab$anchor$nl"*) ;;
      *)
        # A file carrying a heading the slug reader would not spell says so, rather than leaving a
        # maintainer to compare an anchor against a heading that is visibly right -- and it is
        # also the one thing that can make a `-<n>` anchor miss when GitHub has it.
        hint=""
        case "$nl$slugs" in
          *"$nl$resolved$tab!"*) hint=" (it also carries a heading this check will not spell an anchor for, which can leave a numbered repeat unconfirmed: see heading_slugs)" ;;
        esac
        ko "$rel" "link to $target names no heading: $resolved has none whose GitHub slug is '$anchor'$hint"
        bad=1 ;;
    esac
  done <<<"$all"
  [ "$bad" -ne 0 ] \
    || ok "every relative Markdown link in the prompts resolves, anchors included ($count checked)"
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
check_drift_guard
check_cleanup_options
check_links

echo
echo "check-prompts: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
