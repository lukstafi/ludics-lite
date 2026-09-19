#!/usr/bin/env bash
# Exercises scripts/preflight.sh against scratch checkouts: one defective tree per assertion the
# script carries, each with the tree that must PASS beside it. Until ludics-lite#123 these
# assertions were inline `run:` shell in the lint job, so nothing could put a defective tree in
# front of them -- the mode rule's two directions were pinned once, by hand, in a session
# transcript (ludics-lite#121), and the parse guard ran only against two files that already
# satisfied it, which is a guard that could stop guarding in silence.
#
# It ends on the pin that keeps the job and the script one set of checks: every `run:` in the lint
# job is preflight.sh or a command in its step table, and every command in that table is run
# somewhere in the workflow. A step added to one side and not the other fails here, and so does a
# lint step rewritten back into inline shell -- its `run: |` is a command word the table cannot
# hold.
#
# Usage: test-preflight.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
PF="$HERE/preflight.sh"
WORKFLOW="$ROOT/.github/workflows/skill-scripts.yml"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/preflight-test.XXXXXX") || exit 1
# Resolved physically: preflight computes its own root with `pwd -P`, so an unresolved $TMP and
# its idea of the same tree would be spelled differently and every path assertion below would stop
# matching -- on macOS, where /var and /tmp are symlinks into /private, silently.
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
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

# expect LABEL WANT_RC WANT_SUBSTRING -- COMMAND...
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

# tree NAME: sets T to a fresh scratch checkout that passes every assertion, for a case to break
# one thing in. It carries a file under each of the three globs, the two files the parse guard
# names, and one PowerShell script. A function rather than a `$(...)` so the heredocs below are
# not read inside a command substitution, where a `$(` in a body loses bash's parser.
T=
tree() {
  T="$TMP/$1"
  mkdir -p "$T/scripts" "$T/ship-pr/hooks" "$T/ship-pr/scripts" "$T/askill/scripts"
  printf '#!/usr/bin/env bash\ntrue\n' >"$T/scripts/ok.sh"
  printf '#!/usr/bin/env bash\ntrue\n' >"$T/ship-pr/hooks/hook.sh"
  printf '#!/usr/bin/env bash\ntrue\n' >"$T/askill/scripts/s.sh"
  printf 'Write-Host "ok"\n' >"$T/scripts/repair.ps1"
  cleanup_script "$T/ship-pr/scripts/post-merge-cleanup.sh"
  cleanup_script "$T/ship-pr/scripts/test-post-merge-cleanup.sh"
  chmod +x "$T/scripts/ok.sh" "$T/ship-pr/hooks/hook.sh" "$T/askill/scripts/s.sh" \
    "$T/ship-pr/scripts/post-merge-cleanup.sh" "$T/ship-pr/scripts/test-post-merge-cleanup.sh"
}

# The shape the parse guard demands: one brace group opened as the first command after
# `set -o pipefail` and closed by `exit "$?"` and `}` on the last two lines, at column zero.
cleanup_script() {
  cat >"$1" <<'CLEANUP'
#!/usr/bin/env bash
set -uo pipefail

# A comment and a blank line may stand between the set and the brace group.
{
  true
exit "$?"
}
CLEANUP
}

# --- the file list is the scope, and an empty one is a refusal --------------------------------

tree scope
expect "globs prints the file list" 0 '*/scripts/*.sh' -- "$PF" globs
expect "...and ship-pr/hooks is in it" 0 'ship-pr/hooks/*.sh' -- "$PF" globs
expect "files expands them in the judged checkout" 0 'askill/scripts/s.sh' -- "$PF" --root "$T" files
# Repo-relative, because every refusal spells its file the same way and GitHub Actions resolves
# an annotation's `file=` against the workspace root.
files_out=$("$PF" --root "$T" files)
case $files_out in
*"$TMP"*) ko "the file list printed absolute paths: $files_out" ;;
*) ok "...and the paths are repo-relative, as an annotation's file= must be" ;;
esac
expect "steps prints the table" 0 'prompts	scripts/check-prompts.sh' -- "$PF" steps

mkdir -p "$TMP/empty/docs"
expect "a checkout the file list does not describe is a usage error, not a pass" \
  2 'stopped describing the checkout' -- "$PF" --root "$TMP/empty" syntax
expect "...and so is a missing --root" 2 'no such directory' -- "$PF" --root "$TMP/nowhere" syntax
expect "an unknown step is a usage error" 2 'no such step' -- "$PF" --root "$T" lint
expect "an unknown option is a usage error" 2 'unknown option' -- "$PF" --root "$T" --lint
expect "--help prints the header" 0 'CI'"'"'s lint job, runnable before you push' -- "$PF" --help

# --- syntax -----------------------------------------------------------------------------------

tree syntax_clean
expect "a tree that parses passes the syntax step" 0 'syntax: PASS' -- "$PF" --root "$T" syntax
tree syntax_broken
printf '#!/usr/bin/env bash\nif [ ; then\n' >"$T/scripts/broken.sh"
chmod +x "$T/scripts/broken.sh"
expect "...and a file bash cannot parse fails it" 1 'syntax: FAIL' -- "$PF" --root "$T" syntax
expect "...naming the file" 1 'scripts/broken.sh does not parse' -- "$PF" --root "$T" syntax

# A script under a skill directory and one under ship-pr/hooks are in scope too: the three globs
# are one list, and a case per glob is what keeps a narrowing of it visible here.
tree syntax_skill
printf '#!/usr/bin/env bash\nif [ ; then\n' >"$T/askill/scripts/broken.sh"
chmod +x "$T/askill/scripts/broken.sh"
expect "a broken script under a skill directory fails it" 1 'askill/scripts/broken.sh does not parse' -- "$PF" --root "$T" syntax
tree syntax_hook
printf '#!/usr/bin/env bash\nif [ ; then\n' >"$T/ship-pr/hooks/broken.sh"
chmod +x "$T/ship-pr/hooks/broken.sh"
expect "a broken hook fails it" 1 'ship-pr/hooks/broken.sh does not parse' -- "$PF" --root "$T" syntax

# --- the two-way mode rule --------------------------------------------------------------------

tree modes_clean
expect "an executable tree passes the mode step" 0 'modes: PASS' -- "$PF" --root "$T" modes
tree modes_dropped
chmod -x "$T/scripts/ok.sh"
expect "...a script that lost its mode bit fails it" 1 'scripts/ok.sh is not executable' -- "$PF" --root "$T" modes
tree modes_template
printf '# sourced, never executed\nHOSTS=x\n' >"$T/scripts/hosts.example.sh"
expect "a non-executable .example.sh passes, which is the exemption" 0 'modes: PASS' -- "$PF" --root "$T" modes
chmod +x "$T/scripts/hosts.example.sh"
expect "...and an executable one fails, which is the half that makes the exemption sound" \
  1 'must NOT be executable' -- "$PF" --root "$T" modes

# --- shellcheck ---------------------------------------------------------------------------------

if command -v shellcheck >/dev/null 2>&1; then
  tree sc_clean
  expect "a clean tree passes the shellcheck step" 0 'shellcheck: PASS' -- "$PF" --root "$T" shellcheck
  # SC1087, error severity: the finding that cost PR #211 a post-approval push and filed #221.
  tree sc_broken
  printf '#!/usr/bin/env bash\nfoo=bar\necho "$foo[1]"\n' >"$T/scripts/regex.sh"
  chmod +x "$T/scripts/regex.sh"
  expect "...and an error-severity finding fails it" 1 'shellcheck: FAIL' -- "$PF" --root "$T" shellcheck
  expect "...naming the file shellcheck refused" 1 'scripts/regex.sh' -- "$PF" --root "$T" shellcheck
  # SC2034, warning severity: the tier the step deliberately does not judge, because it is style
  # and a few false positives on deliberately unquoted globs.
  tree sc_warning
  printf '#!/usr/bin/env bash\nunused_here=1\ntrue\n' >"$T/scripts/style.sh"
  chmod +x "$T/scripts/style.sh"
  expect "...while a warning-severity one does not, since the step is --severity=error" \
    0 'shellcheck: PASS' -- "$PF" --root "$T" shellcheck
else
  ok "SKIP: shellcheck is not installed, so its controls do not run here (CI runs them)"
fi

# --- the parse guard ------------------------------------------------------------------------

tree pg_clean
expect "the house brace group passes the parse guard" 0 'parse-guard: PASS' -- "$PF" --root "$T" parse-guard
tree pg_tail
printf 'echo "past the brace"\n' >>"$T/ship-pr/scripts/post-merge-cleanup.sh"
expect "...a command appended past the closing brace fails it" 1 "must end in 'exit" -- "$PF" --root "$T" parse-guard
tree pg_open
cat >"$T/ship-pr/scripts/test-post-merge-cleanup.sh" <<'LATE'
#!/usr/bin/env bash
set -uo pipefail
echo "a fork above the brace group"
{
  true
exit "$?"
}
LATE
chmod +x "$T/ship-pr/scripts/test-post-merge-cleanup.sh"
expect "...and a brace group that is not the first command after the set fails it" \
  1 'must open its brace group' -- "$PF" --root "$T" parse-guard
tree pg_missing
rm "$T/ship-pr/scripts/post-merge-cleanup.sh"
expect "...and a file the guard names but the checkout does not hold is a failure, not a skip" \
  1 'is missing: the parse guard names it' -- "$PF" --root "$T" parse-guard

# --- a step whose script is not there ---------------------------------------------------------

tree external_missing
expect "an external step whose script is absent fails rather than passing over it" \
  1 'prompts: FAIL (scripts/check-prompts.sh is not there' -- "$PF" --root "$T" prompts
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/scripts/check-prompts.sh"
chmod +x "$T/scripts/check-prompts.sh"
expect "...and runs it when it is" 0 'prompts: PASS' -- "$PF" --root "$T" prompts

# --- the missing-tool rule --------------------------------------------------------------------
#
# PATH is emptied rather than shellcheck hidden: with --root given, the step needs no external
# command at all before it looks for its tool, so an empty PATH is exactly "the tool is absent".
# The script is handed to $BASH by path for the same reason -- `#!/usr/bin/env bash` would itself
# need a PATH to find bash.

tree tools
expect "a missing tool is a named SKIP, not a failure" \
  0 'shellcheck: SKIP (shellcheck not found' -- env PATH="$TMP/nobin" "${BASH:-/bin/bash}" "$PF" --root "$T" shellcheck
expect "...and the run's exit status is still clean" \
  0 '0 failed, 1 skipped (shellcheck)' -- env PATH="$TMP/nobin" "${BASH:-/bin/bash}" "$PF" --root "$T" shellcheck
expect "...while --require-tools, which CI passes, makes it a failure" \
  1 'shellcheck: FAIL (shellcheck not found' -- env PATH="$TMP/nobin" "${BASH:-/bin/bash}" "$PF" --root "$T" --require-tools shellcheck

# --- powershell ---------------------------------------------------------------------------------
#
# A shim first, so the step's invocation and its exit status are judged on a box with no pwsh --
# every fleet mac. The real parse, including the empty-glob refusal, runs under the `command -v`
# below, which is true on both CI images.
mkdir -p "$TMP/shim"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/shim/pwsh"
chmod +x "$TMP/shim/pwsh"
tree ps_shim
expect "the powershell step passes when the parser does" 0 'powershell: PASS' \
  -- env PATH="$TMP/shim:$PATH" "$PF" --root "$T" powershell
printf '#!/usr/bin/env bash\nexit 1\n' >"$TMP/shim/pwsh"
expect "...and fails when it does not, rather than swallowing its status" 1 'powershell: FAIL' \
  -- env PATH="$TMP/shim:$PATH" "$PF" --root "$T" powershell

if command -v pwsh >/dev/null 2>&1; then
  tree ps_clean
  expect "a .ps1 that parses passes the powershell step" 0 'powershell: PASS' -- "$PF" --root "$T" powershell
  tree ps_broken
  printf 'if ($true {\n' >"$T/scripts/repair.ps1"
  expect "...a .ps1 that does not parse fails it" 1 'powershell: FAIL' -- "$PF" --root "$T" powershell
  tree ps_none
  rm "$T/scripts/repair.ps1"
  expect "...and a glob matching no .ps1 at all is a failure, not a green parse of nothing" \
    1 'judging nothing' -- "$PF" --root "$T" powershell
else
  ok "SKIP: pwsh is not installed, so the real parse controls do not run here (CI runs them)"
fi

# --- the run: every step runs, and the summary counts them ------------------------------------

tree summary_clean
expect "a multi-step run reports every step" 0 '3 passed, 0 failed, 0 skipped' \
  -- "$PF" --root "$T" syntax modes parse-guard
tree summary_two_bad
printf '#!/usr/bin/env bash\nif [ ; then\n' >"$T/scripts/broken.sh"
chmod +x "$T/scripts/broken.sh"
chmod -x "$T/scripts/ok.sh"
expect "...and a failing step does not stop the ones after it, as CI's if:!cancelled() does not" \
  1 '0 passed, 2 failed' -- "$PF" --root "$T" syntax modes

# --- the refusal's two spellings ---------------------------------------------------------------

tree annotation
chmod -x "$T/scripts/ok.sh"
expect "a refusal reads as a sentence outside CI" 1 'preflight: scripts/ok.sh: scripts/ok.sh is not executable' \
  -- "$PF" --root "$T" modes
expect "...and as an annotation on the file's line under GitHub Actions" \
  1 '::error file=scripts/ok.sh::' -- env GITHUB_ACTIONS=true "$PF" --root "$T" modes

# --- the pin: the lint job and the step table are one set of checks ---------------------------

# Every `run:` command word in the lint job, and every one in the whole workflow.
job_run_commands() { # job_run_commands <job>
  awk -v want="  $1:" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job = ($0 == want); next }
    in_job && $1 == "run:" { print $2 }
  ' "$WORKFLOW"
}
workflow_run_commands() {
  awk '$1 == "run:" { print $2 } $1 == "-" && $2 == "run:" { print $3 }' "$WORKFLOW"
}

# The one exemption, and it is named rather than glob-shaped: this suite runs preflight, so
# preflight running this suite would recurse. Asserted to exist, since an exemption naming nothing
# is a line that reads as though it still covered something.
SELF=scripts/test-preflight.sh
[ -f "$ROOT/$SELF" ] && ok "the pin's one exemption names a file that is there" \
  || ko "the pin exempts $SELF, which is not in the checkout"

table_commands=$("$PF" steps | awk -F'\t' '$2 != "-" { print $2 }')
lint_commands=$(job_run_commands lint)
all_run_commands=$(workflow_run_commands)

[ -n "$lint_commands" ] && ok "the lint job's run: lines can be read" \
  || ko "no run: lines found in the lint job -- the pin below would pass over nothing"
[ -n "$table_commands" ] && ok "the step table names external commands" \
  || ko "preflight.sh steps named no external command -- the pin below would pass over nothing"

unpinned=
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  [ "$cmd" = scripts/preflight.sh ] && continue
  [ "$cmd" = "$SELF" ] && continue
  grep -Fqx -- "$cmd" <<<"$table_commands" || unpinned="$unpinned $cmd"
done <<EOF
$lint_commands
EOF
[ -z "$unpinned" ] \
  && ok "every check the lint job runs is one preflight.sh runs too" \
  || ko "the lint job runs what preflight.sh does not:$unpinned"

unrun=
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  grep -Fqx -- "$cmd" <<<"$all_run_commands" || unrun="$unrun $cmd"
done <<EOF
$table_commands
EOF
[ -z "$unrun" ] \
  && ok "...and every check preflight.sh runs is one the workflow runs too" \
  || ko "preflight.sh runs what no workflow step does:$unrun"

# Both halves of that reading, on a scratch copy of the workflow: a lint step the table cannot
# hold must trip the pin, or the two assertions above are claims nothing could falsify. Inline
# shell is the shape that matters -- it is what the lint job carried until ludics-lite#123.
probe_workflow() { # probe_workflow <text to insert into the lint job>
  mkdir -p "$TMP/probe/.github/workflows"
  # Through the environment rather than -v: an awk assignment processes escapes and cannot carry
  # a literal newline, and every probe here is a step of two or more lines.
  PROBE_ADD="$1" awk '
    { print }
    $0 == "      - uses: actions/checkout@v4" && !inserted && in_lint {
      print ENVIRON["PROBE_ADD"]
      inserted = 1
    }
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_lint = ($0 == "  lint:") }
  ' "$ROOT/.github/workflows/skill-scripts.yml" >"$TMP/probe/.github/workflows/skill-scripts.yml"
  # The readers below take the workflow from here, and the source is the real file however often
  # this runs: reading $WORKFLOW after it has been pointed at the probe would have awk read the
  # file the redirection has just truncated, and an empty workflow is a pin that passes over
  # nothing -- which is how this probe first "passed".
  WORKFLOW="$TMP/probe/.github/workflows/skill-scripts.yml"
}
probe_workflow '      - name: A new check
        run: scripts/check-something-new.sh'
probe_unpinned=
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  [ "$cmd" = scripts/preflight.sh ] && continue
  [ "$cmd" = "$SELF" ] && continue
  grep -Fqx -- "$cmd" <<<"$table_commands" || probe_unpinned="$probe_unpinned $cmd"
done <<EOF
$(job_run_commands lint)
EOF
[ "$probe_unpinned" = " scripts/check-something-new.sh" ] \
  && ok "...and a lint step the table does not hold trips that pin" \
  || ko "a lint step outside the step table did not trip the pin (verdict:$probe_unpinned)"

probe_workflow '      - name: An inline assertion
        run: |
          set -e
          for f in scripts/*.sh; do bash -n "$f"; done'
probe_inline=
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  [ "$cmd" = scripts/preflight.sh ] && continue
  [ "$cmd" = "$SELF" ] && continue
  grep -Fqx -- "$cmd" <<<"$table_commands" || probe_inline="$probe_inline $cmd"
done <<EOF
$(job_run_commands lint)
EOF
[ "$probe_inline" = " |" ] \
  && ok "...as does a lint step written back as inline shell, which is what #123 filed" \
  || ko "inline shell in the lint job did not trip the pin (verdict:$probe_inline)"
WORKFLOW="$ROOT/.github/workflows/skill-scripts.yml"

# --- the checkout this suite runs in ------------------------------------------------------------

expect "this checkout's file list holds the script itself" 0 'scripts/preflight.sh' -- "$PF" files

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
