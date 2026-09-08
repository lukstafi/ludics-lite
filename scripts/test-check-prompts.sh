#!/usr/bin/env bash
# Exercises check-prompts.sh against a scratch tree: a well-formed layout passes, and each defect
# the checker exists for is refused with the message that names it -- with the passing tree as
# the control, since a scan that cannot fail would prove nothing (ludics-lite#55). It ends by
# running the checker on this checkout, which is the same verdict CI's prompt hygiene job reads.
#
# Usage: test-check-prompts.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
CP="$HERE/check-prompts.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-prompts-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS: $*"; }
ko() { fail=$((fail + 1)); echo "FAIL: $*"; }
# expect <label> <want-rc> <want-substring> -- <cmd...>; leaves the output in $out.
expect() {
  local label="$1" want_rc="$2" want="$3"; shift 3; [ "$1" = -- ] && shift
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF -- "$want"; then ok "$label"
  else ko "$label (rc=$rc want $want_rc; want /$want/) -- $out"; fi
}

# row_after_beta <row>: inserts a row into the scratch README's skill table, after `beta`.
row_after_beta() { sed -i.bak "/^| \`beta\` |/a\\
$1" "$R/README.md"; }

# --- the scratch tree: two skills, two routines, both index tables ---------------------------
skill() {  # skill <root> <name> [frontmatter lines...]: writes <root>/<name>/SKILL.md
  local root="$1" name="$2"; shift 2
  mkdir -p "$root/$name"
  { echo '---'; printf '%s\n' "$@"; echo '---'; echo; echo "# $name"; } > "$root/$name/SKILL.md"
}
fresh() {  # fresh <root>: a passing layout from scratch
  local root="$1"
  rm -rf "$root"; mkdir -p "$root/routines" "$root/scripts"
  skill "$root" alpha 'name: alpha' 'description: The first skill.'
  skill "$root" beta 'name: beta' 'description: The second skill.' 'allowed-tools: Bash'
  skill "$root/routines" nightly 'name: nightly' 'description: A nightly routine.'
  skill "$root/routines" weekly 'name: weekly' 'description: A weekly routine.'
  cat > "$root/README.md" <<'EOF'
# scratch

| Skill | What it does |
| --- | --- |
| `alpha` | The first. |
| `beta` | The second. |

| Variable | Meaning |
| --- | --- |
| `NOT_A_SKILL` | A table with backticks that is not the skill table. |
EOF
  cat > "$root/routines/README.md" <<'EOF'
# Routines

| Routine | Kind | Fires |
| --- | --- | --- |
| `nightly` | local | daily |
| `weekly` | local | weekly |
EOF
}
R="$TMP/tree"

fresh "$R"
expect "a well-formed tree passes" 0 '6 passed, 0 failed' -- "$CP" "$R"
expect "a missing root is refused, not passed" 2 'no such directory' -- "$CP" "$TMP/nowhere"

# --- frontmatter defects ---------------------------------------------------------------------
fresh "$R"; sed -i.bak '1d' "$R/alpha/SKILL.md"
expect "no opening fence" 1 'alpha/SKILL.md: no YAML frontmatter' -- "$CP" "$R"

fresh "$R"; printf -- '---\nname: beta\ndescription: unclosed\n\n# beta\n' > "$R/beta/SKILL.md"
expect "no closing fence" 1 'beta/SKILL.md: no YAML frontmatter' -- "$CP" "$R"

fresh "$R"; skill "$R" alpha 'description: nameless'
expect "missing name" 1 "alpha/SKILL.md: frontmatter has no 'name:' line" -- "$CP" "$R"

fresh "$R"; skill "$R/routines" weekly 'name: weekly' 'description:'
expect "empty description" 1 "weekly/SKILL.md: frontmatter 'description:' has no value" -- "$CP" "$R"

fresh "$R"; skill "$R" beta 'name: beta' 'name: beta' 'description: twice named'
expect "duplicate name" 1 "beta/SKILL.md: frontmatter has 2 'name:' lines" -- "$CP" "$R"

# Declarations are counted as keys, not as non-empty values: a blank `name:` beside a populated
# one is two declarations, and neither the blank one nor the mismatch it could hide gets through.
fresh "$R"; skill "$R" beta 'name:' 'name: alpha' 'description: blank beside populated'
expect "a blank duplicate key still counts" 1 "beta/SKILL.md: frontmatter has 2 'name:' lines" -- "$CP" "$R"

# Values resolve the way YAML resolves a one-line scalar: the quoted, null and comment-only
# spellings of empty are empty, and quotes and a trailing comment around real text are not text.
for empty in 'description: ""' "description: ''" 'description: null' 'description: ~' 'description: # only a comment' 'description:    '; do
  fresh "$R"; skill "$R" alpha 'name: alpha' "$empty"
  expect "'$empty' is empty" 1 "alpha/SKILL.md: frontmatter 'description:' has no value" -- "$CP" "$R"
done
fresh "$R"; skill "$R" alpha "name: 'alpha'" 'description: "Quoted, with a # inside." # and a trailing note'
expect "quoted and commented values resolve to their text" 0 '6 passed, 0 failed' -- "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: "beta"' 'description: quoted mismatch'
expect "...so a quoted name is still compared to the directory" 1 "name 'beta' does not match its directory 'alpha'" -- "$CP" "$R"

# The value grammar is a subset of YAML: whatever it accepts a loader reads as the same string,
# and whatever a loader might read otherwise -- or reject -- is refused, with the reason. One
# probe per refusal reason, then the plain-text shapes that must stay accepted.
while IFS='|' read -r value reason; do
  fresh "$R"; skill "$R" alpha 'name: alpha' "description: $value"
  expect "'description: $value' is refused ($reason)" 1 "outside the grammar this check accepts: '$value' ($reason" -- "$CP" "$R"
done <<'CASES'
"unterminated|a double-quoted value must close
"closed" then more|a double-quoted value must close
'unterminated|a single-quoted value must close
'closed' then more|a single-quoted value must close
[]|starts with the YAML indicator '['
{}|starts with the YAML indicator '{'
[a, b]|starts with the YAML indicator '['
&anchor text|starts with the YAML indicator '&'
*alias|starts with the YAML indicator '*'
!!str text|starts with the YAML indicator '!'
`backticked`|starts with the YAML indicator '`'
- a list item|starts with '- '
? a key|starts with '? '
: a value|starts with ': '
Runs checks: quickly|contains ': ' or ends with ':'
Ends with a colon:|contains ': ' or ends with ':'
42|'42' does not start with a letter
1e3|'1e3' does not start with a letter
.inf|'.inf' does not start with a letter
2001-12-15|'2001-12-15' does not start with a letter
0b1010|'0b1010' does not start with a letter
12:34|'12:34' does not start with a letter
+1_000|'+1_000' does not start with a letter
<< merge|'<< merge' does not start with a letter
-x is plain to YAML but outside the grammar|'-x is plain to YAML but outside the grammar' does not start with a letter
true|'true' is a boolean or null
Yes|'Yes' is a boolean or null
n|'n' is a boolean or null
CASES
for value in 'Runs checks:quickly, no space after the colon' 'v1.2 of 3 things, 100% plain' \
  'Text - with - dashes and a trailing note # here' 'Nothing is 2001-12-15 once a letter leads' \
  '"Runs checks: quickly, quoted"' "'It''s quoted, with: a colon'" 'Yes it is text, not a boolean' \
  '"2001-12-15, quoted, is text"'; do
  fresh "$R"; skill "$R" alpha 'name: alpha' "description: $value"
  expect "'description: $value' is accepted" 0 '6 passed, 0 failed' -- "$CP" "$R"
done

fresh "$R"; skill "$R" alpha 'name: alpah' 'description: misspelt'
expect "name must match the directory" 1 "name 'alpah' does not match its directory 'alpha'" -- "$CP" "$R"

# A block scalar is refused by its header, whatever indicators or comment follow the `|`/`>`;
# and its body, like any continued, nested or listed value, is refused as a non-key line, so a
# value cannot span lines whichever way it is spelled.
for header in 'description: |' 'description: |2-' 'description: >+' 'description: > # folded'; do
  fresh "$R"; skill "$R" alpha 'name: alpha' "$header"
  expect "block scalar header '$header'" 1 'description is a block scalar' -- "$CP" "$R"
done
fresh "$R"; skill "$R" alpha 'name: alpha' 'description: |' '  A block scalar body.'
expect "a block scalar body is a non-key line" 1 "not a top-level 'key: value'" -- "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: alpha' 'description: The first line' '  continued on a second.'
expect "a plain scalar continued on the next line" 1 "not a top-level 'key: value'" -- "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: alpha' 'description: listed' 'allowed-tools:' '  - Bash'
expect "a nested list" 1 "not a top-level 'key: value'" -- "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: alpha' 'description: commented' '# a comment line' '' 'model: sonnet'
expect "blank and comment lines between keys are fine" 0 '6 passed, 0 failed' -- "$CP" "$R"

# Double-quoted values admit only `\"` and `\\`: a backslash a loader would reject (`\q`) and one
# it would turn into a second line (`\n`) are refused alike, and the two admitted ones decode.
fresh "$R"; skill "$R" alpha 'name: alpha' 'description: "bad \q escape"'
expect "an escape YAML rejects" 1 'may escape only \" and \\' -- "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: alpha' 'description: "first\nsecond"'
expect "an escape that would make a second line" 1 'may escape only \" and \\' -- "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: "al\"pha"' 'description: "a \"quoted\" word and a \\ backslash"'
expect "the admitted escapes decode before the directory comparison" 1 "name 'al\"pha' does not match its directory 'alpha'" -- "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: alpha' 'description: "a \"quoted\" word and a \\ backslash"'
expect "...and pass where the text is fine" 0 '6 passed, 0 failed' -- "$CP" "$R"

# A control character anywhere in the frontmatter is refused whole: the tab YAML reads as a
# separator after `:`, and the carriage return a loader would fold into the value.
fresh "$R"; skill "$R" alpha 'name: alpha' "description: Runs:$(printf '\t')quickly"
expect "a tab in a value" 1 'frontmatter carries a control character' -- "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: alpha' "description: CRLF line$(printf '\r')"
expect "a carriage return" 1 'frontmatter carries a control character' -- "$CP" "$R"

# A NUL byte never reaches a shell variable (bash drops it, warning on stderr where no verdict
# reads), and invalid UTF-8 is a loader error: both are refused on the raw file, first.
fresh "$R"; printf -- '---\nname: alpha\ndescription: a NUL \000 inside\n---\n' > "$R/alpha/SKILL.md"
expect "a NUL byte" 1 'a byte sequence no loader accepts' -- "$CP" "$R"
fresh "$R"; printf -- '---\nname: alpha\ndescription: bad \377 byte\n---\n' > "$R/alpha/SKILL.md"
expect "invalid UTF-8" 1 'a byte sequence no loader accepts' -- "$CP" "$R"
# ...and the characters YAML's printable set excludes, by the spec's definition: the C1
# controls and the two non-characters. Everything else valid UTF-8 encodes is content.
fresh "$R"; printf -- '---\nname: alpha\ndescription: a C1 control \302\205 inside\n---\n' > "$R/alpha/SKILL.md"
expect "a C1 control (U+0085)" 1 'a byte sequence no loader accepts' -- "$CP" "$R"
fresh "$R"; printf -- '---\nname: alpha\ndescription: a\357\277\276 non-character\n---\n' > "$R/alpha/SKILL.md"
expect "U+FFFE" 1 'a byte sequence no loader accepts' -- "$CP" "$R"
fresh "$R"; printf -- '---\nname: alpha\ndescription: a\342\200\250b, split by a line separator\n---\n' > "$R/alpha/SKILL.md"
expect "U+2028, a line break to YAML 1.1" 1 'a byte sequence no loader accepts' -- "$CP" "$R"
fresh "$R"; printf -- '---\nname: alpha\ndescription: fine\n---\n\nA body line\342\200\250split by a separator, which is not YAML.\n' > "$R/alpha/SKILL.md"
expect "...but only in the frontmatter: the Markdown body is not YAML" 0 '6 passed, 0 failed' -- "$CP" "$R"
fresh "$R"; printf -- '---\nname: alpha\ndescription: fine \303\274ber text \342\200\224 with a dash\n---\n' > "$R/alpha/SKILL.md"
expect "...while valid UTF-8 content passes" 0 '6 passed, 0 failed' -- "$CP" "$R"
# A Unicode space is content, not whitespace, to YAML and to this check (LC_ALL=C): appended
# to a name it stays in the name, which then does not match its directory.
fresh "$R"; printf -- '---\nname: alpha\342\200\202\ndescription: en space after the name\n---\n' > "$R/alpha/SKILL.md"
expect "a Unicode space is kept in the name" 1 "does not match its directory 'alpha'" -- "$CP" "$R"

# Optional keys are held to the same grammar: a loader rejects the whole file on any of them.
fresh "$R"; skill "$R" alpha 'name: alpha' 'description: fine' 'allowed-tools: ['
expect "a malformed optional key" 1 "frontmatter 'allowed-tools:' value is outside the grammar" -- "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: alpha' 'description: fine' 'model:'
expect "an empty optional key" 1 "frontmatter 'model:' has no value" -- "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: alpha' 'description: fine' 'model: sonnet' 'model: opus'
expect "a duplicated optional key" 1 "frontmatter has 2 'model:' lines" -- "$CP" "$R"

# --- index table defects ---------------------------------------------------------------------
fresh "$R"; skill "$R" gamma 'name: gamma' 'description: Unindexed.'
expect "a skill missing from the README table" 1 'skill directories missing from its table: gamma' -- "$CP" "$R"

fresh "$R"; rm -r "$R/beta"
expect "a README row without a directory" 1 "table row 'beta' has no beta/SKILL.md" -- "$CP" "$R"

fresh "$R"; skill "$R/routines" monthly 'name: monthly' 'description: Unindexed.'
expect "a routine missing from routines/README.md" 1 'routine directories missing from its table: monthly' -- "$CP" "$R"

fresh "$R"; rm -r "$R/routines/nightly"
expect "a routines row without a directory" 1 "table row 'nightly' has no routines/nightly/SKILL.md" -- "$CP" "$R"

# A table ends at its first non-row line, blank or not: rows of a later table that follows a
# heading with no blank line between are not the index, in either direction.
fresh "$R"; cat > "$R/README.md" <<'EOF'
# scratch

| Skill | What it does |
| --- | --- |
| `alpha` | The first. |
## A heading with no blank line before it
| Variable | Meaning |
| --- | --- |
| `beta` | Indexed in the wrong table. |
| `NOT_A_SKILL` | Not a skill either. |
EOF
expect "a heading ends the table: a skill listed only in a later table is missing" 1 'skill directories missing from its table: beta' -- "$CP" "$R"
printf '%s' "$out" | grep -q "table row 'NOT_A_SKILL'" && ko "the later table's rows were read as the index" \
  || ok "...and the later table's rows are not read as index rows"

# A table inside a fenced code block or an HTML comment is not rendered, and is not read; one
# outside them is, whatever fenced or commented look-alikes precede it.
fresh "$R"; { echo '```'; cat "$R/README.md"; echo '```'; } > "$R/README.fenced" && mv "$R/README.fenced" "$R/README.md"
expect "a table inside a code fence is not a table" 1 "no '| Skill |' table" -- "$CP" "$R"
fresh "$R"; { echo '<!--'; cat "$R/README.md"; echo '-->'; } > "$R/README.commented" && mv "$R/README.commented" "$R/README.md"
expect "a table inside an HTML comment is not a table" 1 "no '| Skill |' table" -- "$CP" "$R"
fresh "$R"; { printf '%s\n' '```' '| Skill | What it does |' '| --- | --- |' '| `NOT_A_SKILL` | fenced |' '```' \
  '<!-- | Skill | What it does |' '| --- | --- |' '| `NOT_A_SKILL` | commented | -->'; cat "$R/README.md"; } > "$R/README.pre" \
  && mv "$R/README.pre" "$R/README.md"
expect "...and look-alikes inside them do not hide the real table after them" 0 '6 passed, 0 failed' -- "$CP" "$R"
# A comment that closes on its own line is cut out and the rest of the line still read: a
# row with an inline note is a row (and a stale one is caught); a header with one is a header.
fresh "$R"; row_after_beta '| `stale` | Visible text <!-- note --> |'
expect "a row with an inline comment is still judged" 1 "table row 'stale' has no stale/SKILL.md" -- "$CP" "$R"
fresh "$R"; sed -i.bak 's/^| Skill | What it does |$/| Skill | What it does | <!-- two cells, one note -->/' "$R/README.md"
expect "a header with a trailing inline comment is still the header" 0 '6 passed, 0 failed' -- "$CP" "$R"

# A fence closes only on its own marker, at least as long as the opener: a `~~~` inside a
# backtick fence, or a shorter fence, leaves the block open, as it does for the renderer.
fresh "$R"; { echo '```'; echo '~~~'; cat "$R/README.md"; echo '```'; } > "$R/README.f" && mv "$R/README.f" "$R/README.md"
expect "a ~~~ inside a backtick fence does not close it" 1 "no '| Skill |' table" -- "$CP" "$R"
fresh "$R"; { echo '````'; echo '```'; cat "$R/README.md"; echo '````'; } > "$R/README.f" && mv "$R/README.f" "$R/README.md"
expect "a shorter fence does not close a longer one" 1 "no '| Skill |' table" -- "$CP" "$R"
fresh "$R"; { echo '```'; echo 'code'; echo '`````'; cat "$R/README.md"; } > "$R/README.f" && mv "$R/README.f" "$R/README.md"
expect "...and a longer fence of the same marker does" 0 '6 passed, 0 failed' -- "$CP" "$R"
fresh "$R"; { echo '```text'; echo '```not-a-close'; cat "$R/README.md"; echo '```'; } > "$R/README.f" && mv "$R/README.f" "$R/README.md"
expect "a fence line with text after the marker does not close" 1 "no '| Skill |' table" -- "$CP" "$R"
fresh "$R"; { echo '```text'; echo 'code'; echo '```   '; cat "$R/README.md"; } > "$R/README.f" && mv "$R/README.f" "$R/README.md"
expect "...and one with only whitespace after it does" 0 '6 passed, 0 failed' -- "$CP" "$R"
# A fence line may be indented at most three spaces; four make it code inside the open block.
fresh "$R"; { echo '```'; echo '    ```'; cat "$R/README.md"; echo '```'; } > "$R/README.f" && mv "$R/README.f" "$R/README.md"
expect "a fence indented four spaces does not close" 1 "no '| Skill |' table" -- "$CP" "$R"
fresh "$R"; { echo '```'; echo 'code'; echo '   ```'; cat "$R/README.md"; } > "$R/README.f" && mv "$R/README.f" "$R/README.md"
expect "...and one indented three does" 0 '6 passed, 0 failed' -- "$CP" "$R"
# GFM's delimiter row: cells "whose only content are hyphens", no minimum count -- `| - | - |`
# renders as a table on GitHub, and so it is one here.
fresh "$R"; sed -i.bak 's/^| --- | --- |$/| - | - |/' "$R/README.md"
expect "a single-hyphen delimiter row is a table, as on GitHub" 0 '6 passed, 0 failed' -- "$CP" "$R"
# ...but only with as many cells as the header: GFM recognises no table otherwise.
fresh "$R"; sed -i.bak 's/^| --- | --- |$/| - |/' "$R/README.md"
expect "a delimiter row with fewer cells than the header is not a table" 1 "no '| Skill |' table" -- "$CP" "$R"
fresh "$R"; sed -i.bak 's/^| --- | --- |$/| --- | --- | --- |/' "$R/README.md"
expect "...nor one with more" 1 "no '| Skill |' table" -- "$CP" "$R"

# Every data row is judged: a row the reader sees with a first cell that is not one backticked
# name fails, instead of being skipped as not-a-row.
fresh "$R"; row_after_beta '| stale-skill | Stale rendered row. |'
expect "an unbackticked first cell is a failing row" 1 "skill table row's first cell is not a backticked name: 'stale-skill'" -- "$CP" "$R"
fresh "$R"; row_after_beta '| `two` `names` | Two names. |'
expect "two backticked names in one cell is a failing row" 1 "is not one backticked name" -- "$CP" "$R"
fresh "$R"; row_after_beta '|   | Empty first cell. |'
expect "an empty first cell is a failing row" 1 "first cell is not a backticked name: ''" -- "$CP" "$R"

# Without its delimiter row a header and its rows are prose to Markdown, and to this.
fresh "$R"; sed -i.bak '/^| Skill |/{n;d;}' "$R/README.md"
expect "a table without its delimiter row is not a table" 1 "no '| Skill |' table" -- "$CP" "$R"

fresh "$R"; sed -i.bak 's/^| Routine |/| Routines |/' "$R/routines/README.md"
expect "a renamed table header is a failure, not an empty pass" 1 "no '| Routine |' table" -- "$CP" "$R"

fresh "$R"; rm "$R/routines/README.md"
expect "a missing index file" 1 'routines/README.md: missing' -- "$CP" "$R"

# Two defects in one run are both reported: the per-file loop does not stop at the first.
fresh "$R"; skill "$R" alpha 'description: nameless'; skill "$R/routines" weekly 'name: weekly'
out=$("$CP" "$R" 2>&1)
if printf '%s' "$out" | grep -q "alpha/SKILL.md: frontmatter has no 'name:' line" \
  && printf '%s' "$out" | grep -q "weekly/SKILL.md: frontmatter has no 'description:' line"; then
  ok "every defective file is reported, not only the first"
else ko "a second defective file went unreported -- $out"; fi

# Under Actions each failure is also an annotation on the file.
fresh "$R"; skill "$R" alpha 'name: alpah' 'description: x'
expect "GitHub annotations name the file" 1 '::error file=alpha/SKILL.md::' -- env GITHUB_ACTIONS=true "$CP" "$R"
fresh "$R"; skill "$R" alpha 'name: alpah' 'description: x'
out=$(env -u GITHUB_ACTIONS "$CP" "$R" 2>&1)
printf '%s' "$out" | grep -q '::error' && ko "annotations leak outside Actions" \
  || ok "...and only under Actions"

# --- this checkout ---------------------------------------------------------------------------
expect "this checkout's prompts pass" 0 '0 failed' -- "$CP"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
