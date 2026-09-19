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

# One brace group, so bash parses this file WHOLE before its first line runs and an edit landing
# while a run is in flight cannot resume the shell at a shifted offset; the `exit` at the foot
# means the shell never comes back to the file for a next command. Two lines here and two at the
# foot, with the body's own indentation untouched (ludics-lite#10, #247); scripts/check-parse-guards.sh
# checks the shape.
{
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
# one thing in. It carries a file under each of the three globs and one PowerShell script. A function rather than a `$(...)` so the heredocs below are
# not read inside a command substitution, where a `$(` in a body loses bash's parser.
T=
tree() {
  T="$TMP/$1"
  mkdir -p "$T/scripts" "$T/ship-pr/hooks" "$T/askill/scripts"
  printf '#!/usr/bin/env bash\ntrue\n' >"$T/scripts/ok.sh"
  printf '#!/usr/bin/env bash\ntrue\n' >"$T/ship-pr/hooks/hook.sh"
  printf '#!/usr/bin/env bash\ntrue\n' >"$T/askill/scripts/s.sh"
  printf 'Write-Host "ok"\n' >"$T/scripts/repair.ps1"
  chmod +x "$T/scripts/ok.sh" "$T/ship-pr/hooks/hook.sh" "$T/askill/scripts/s.sh"
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
# Per pattern, not merely when the whole sweep is empty: two patterns still matching would
# otherwise hide the third going away, and every step would pass over the smaller scope.
tree scope_partial
rm "$T/ship-pr/hooks/hook.sh"
expect "...and so is ONE pattern of the list matching nothing, with the others still full" \
  2 'no file matched ship-pr/hooks/*.sh' -- "$PF" --root "$T" syntax
expect "...which the mode step refuses too, rather than judging the smaller scope" \
  2 'stopped describing the checkout' -- "$PF" --root "$T" modes
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

# A broken symlink is a path the list owes a verdict on: `-f` followed the link and dropped it,
# so the sweep went green over a file bash cannot open (round 1).
tree syntax_dangling
ln -s missing-target.sh "$T/scripts/dangling.sh"
expect "a broken symlink is in the file list, not dropped by it" 0 'scripts/dangling.sh' -- "$PF" --root "$T" files
expect "...and the syntax step refuses it rather than passing over it" 1 'syntax: FAIL' -- "$PF" --root "$T" syntax
expect "...and the mode step too, since a dangling link is not executable" \
  1 'scripts/dangling.sh is not executable' -- "$PF" --root "$T" modes
if command -v shellcheck >/dev/null 2>&1; then
  expect "...and shellcheck is handed it" 1 'shellcheck: FAIL' -- "$PF" --root "$T" shellcheck
fi

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

# --- a step whose script is not there ---------------------------------------------------------

tree external_missing
expect "an external step whose script is absent fails rather than passing over it" \
  1 'prompts: FAIL (scripts/check-prompts.sh is not there' -- "$PF" --root "$T" prompts
printf '#!/usr/bin/env bash\nexit 0\n' >"$T/scripts/check-prompts.sh"
chmod +x "$T/scripts/check-prompts.sh"
expect "...and runs it when it is" 0 'prompts: PASS' -- "$PF" --root "$T" prompts

# --- the scope inside a git work tree -----------------------------------------------------------
#
# CI judges an actions/checkout, which holds no untracked file. A scratch script an agent leaves
# in a worktree must therefore not turn the pre-push command red, and the same file must be judged
# the moment it is staged, which is when a push would carry it (round 5).

tree git_scope
if git -C "$T" init -q >/dev/null 2>&1 && git -C "$T" add -A >/dev/null 2>&1; then
  ok "the git-scope control could be built"
  expect "a tracked tree passes" 0 'syntax: PASS' -- "$PF" --root "$T" syntax
  printf '#!/usr/bin/env bash\nif [ ; then\n' >"$T/scripts/agent-scratch.sh"
  chmod +x "$T/scripts/agent-scratch.sh"
  git_files=$("$PF" --root "$T" files)
  case $git_files in
  *agent-scratch.sh*) ko "an untracked scratch script was in the file list: $git_files" ;;
  *) ok "...an untracked scratch script is not in the file list, as it is not in the push" ;;
  esac
  expect "...so the syntax step does not go red over a file CI will never see" \
    0 'syntax: PASS' -- "$PF" --root "$T" syntax
  git -C "$T" add scripts/agent-scratch.sh >/dev/null 2>&1
  expect "...and the same file staged IS judged, which is when a push would carry it" \
    1 'scripts/agent-scratch.sh does not parse' -- "$PF" --root "$T" syntax
  expect "...while outside a work tree the filesystem is the list, as the trees above rely on" \
    1 'does not parse' -- "$PF" --root "$TMP/syntax_broken" syntax
else
  ko "could not build a scratch git repository: the tracked-scope controls below would prove nothing"
fi

# --- a step in the table with nothing behind it -------------------------------------------------
#
# The negative control needs a table entry that no arm implements, which only a patched copy of
# the script can have. `case` matching nothing exits 0, so without the default arm this prints
# PASS over an assertion that never ran.

mkdir -p "$TMP/handler/scripts"
PATCH_ADD="  'nosuchhandler:-'" awk '
  { print }
  $0 ~ /^  .syntax:-.$/ { print ENVIRON["PATCH_ADD"] }
' "$PF" >"$TMP/handler/scripts/preflight.sh"
chmod +x "$TMP/handler/scripts/preflight.sh"
PATCHED="$TMP/handler/scripts/preflight.sh"
tree handler
if grep -q "nosuchhandler" "$PATCHED"; then
  ok "the unimplemented-step control could be built"
  expect "a step the table names and nothing implements is a failure, not a PASS" \
    1 'no assertion here implements it' -- "$PATCHED" --root "$T" nosuchhandler
  expect "...while the same patched copy still passes a step that has an arm" \
    0 'syntax: PASS' -- "$PATCHED" --root "$T" syntax
else
  ko "could not patch a table entry into a copy of preflight.sh: the control below would prove nothing"
fi

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
expect "a multi-step run reports every step" 0 '2 passed, 0 failed, 0 skipped' \
  -- "$PF" --root "$T" syntax modes
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
# The command word of every `run:` line whose invocation carries NO ARGUMENTS -- nothing between
# the command and the end of the line or the shell operator that follows it (the macOS legs spell
# every suite `<suite> || { echo ...; exit 1; }`, which is a bare invocation of the suite). An
# argument is what turns a run into something other than the check the table names: `--help` exits
# 0 having asserted nothing, and a path narrows a guard's sweep from the checkout to that file,
# either of which would satisfy a pin that read the command word alone (round 4). The prompt
# hygiene job is the case that matters most: it is the only check a prompt-only head gets.
workflow_bare_commands() {
  awk '
    # An operator tail counts only when the line still FAILS if the command does. `|| true`,
    # `; true` and `| cat` each swallow the status, and a pin that took any operator for a bare
    # invocation would pass over a prompt hygiene step that can no longer go red (round 5). The
    # one tail accepted is the `|| { echo ...; exit 1; }` this workflow uses; another spelling that
    # propagates is a line here, deliberately, rather than an attempt to read shell semantics.
    # The tail is matched WHOLE, not searched for a substring: `<cmd> || { ...; exit 1; } || true`
    # contains the accepted handler and still cannot go red, so an unanchored match let the very
    # shape this rule refuses through one operator later (round 6).
    function tail_from(start,   i, t) {
      t = ""
      for (i = start; i <= NF; i++) t = t (t == "" ? "" : " ") $i
      return t
    }
    function bare(cmd, tail) {
      if (tail == "") return cmd
      if (tail ~ /^\|\| \{ .*exit 1 *;? *\}$/) return cmd
      return ""
    }
    $1 == "run:" { c = bare($2, tail_from(3)); if (c != "") print c }
    $1 == "-" && $2 == "run:" { c = bare($3, tail_from(4)); if (c != "") print c }
  ' "$WORKFLOW"
}
# The command word of every lint `run:` whose step carries a condition other than `!cancelled()`.
# GitHub skips a step whose `if:` is false and reports the job green, so a pinned check can be
# turned off without touching its run line at all (round 6). `!cancelled()` is the one condition
# known to preserve execution -- it skips only a cancelled run, which is the macOS legs' spelling
# for "run this step even after an earlier one failed" -- and anything else is a line here.
lint_conditional_runs() {
  awk -v want="  lint:" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job = ($0 == want); next }
    !in_job { next }
    /^      - / { cond = "" }
    $1 == "if:" { cond = $0; sub(/^[[:space:]]*if:[[:space:]]*/, "", cond) }
    $1 == "run:" && cond != "" && cond !~ /^\$\{\{[ ]*![ ]*cancelled\(\)[ ]*\}\}$/ { print $2 }
  ' "$WORKFLOW"
}

# The steps the lint job invokes WITHOUT --require-tools. A step with an interpreter that CI does
# not demand is one a runner losing that interpreter turns into a SKIP and a green job -- the
# fail-closed half of this PR's own promise, dropped by deleting one word from a run line.
lint_preflight_unguarded() {
  awk -v want="  lint:" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job = ($0 == want); next }
    in_job && $1 == "run:" && $2 == "scripts/preflight.sh" {
      for (i = 3; i <= NF; i++) if ($i == "-h" || $i == "--help") next
      for (i = 3; i <= NF; i++) if ($i == "--require-tools") next
      named = 0
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^-/) { if ($i == "--root") i++; continue }
        print $i
        named = 1
      }
      if (!named) print "*"
    }
  ' "$WORKFLOW"
}
# The STEP NAMES the lint job passes to preflight.sh, `*` for an invocation that names none and so
# runs them all. Reading only the command word would exempt every preflight line unconditionally:
# a mode-bit step rewritten to a second `syntax` invocation would leave the mode rule unrun in CI
# while the pin below stayed green, which is the drift this pin exists to catch (round 1).
lint_preflight_steps() {
  awk -v want="  lint:" '
    /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { in_job = ($0 == want); next }
    in_job && $1 == "run:" && $2 == "scripts/preflight.sh" {
      # A help flag is not a run: `preflight.sh --help syntax` prints the manual and exits 0
      # without asserting anything, so the line covers NO step and the pin must say so rather
      # than read `syntax` off it (round 2).
      for (i = 3; i <= NF; i++) if ($i == "-h" || $i == "--help") next
      named = 0
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^-/) { if ($i == "--root") i++; continue }
        print $i
        named = 1
      }
      if (!named) print "*"
    }
  ' "$WORKFLOW"
}

# The one exemption, and it is named rather than glob-shaped: this suite runs preflight, so
# preflight running this suite would recurse. Asserted to exist, since an exemption naming nothing
# is a line that reads as though it still covered something.
SELF=scripts/test-preflight.sh
[ -f "$ROOT/$SELF" ] && ok "the pin's one exemption names a file that is there" \
  || ko "the pin exempts $SELF, which is not in the checkout"

table_commands=$("$PF" steps | awk -F'\t' '$2 != "-" { print $2 }')
# The steps preflight implements itself: these have no script for the reader above to find, so
# they are pinned by the name the lint job passes.
table_internal=$("$PF" steps | awk -F'\t' '$2 == "-" { print $1 }')
table_names=$("$PF" steps | awk -F'\t' '{ print $1 }')
# The steps that need an interpreter, which is what CI must demand with --require-tools.
table_tooled=$("$PF" steps | awk -F'\t' '$3 != "" { print $1 }')
lint_commands=$(job_run_commands lint)
bare_run_commands=$(workflow_bare_commands)

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
  grep -Fqx -- "$cmd" <<<"$bare_run_commands" || unrun="$unrun $cmd"
done <<EOF
$table_commands
EOF
[ -z "$unrun" ] \
  && ok "...and every check preflight.sh runs is one the workflow runs too, with no argument to neuter it" \
  || ko "preflight.sh runs what no workflow step runs bare:$unrun"
[ -n "$bare_run_commands" ] && ok "the workflow's bare invocations can be read" \
  || ko "no bare run: invocation found in the workflow -- the pin above would pass over nothing"

conditional=$(lint_conditional_runs)
[ -z "$conditional" ] \
  && ok "...and no pinned check is behind a condition that could skip it" \
  || ko "a lint step the pin reads is behind a condition:$conditional"

# The same validation on the flag CI's own fail-closed promise rests on.
unguarded=$(lint_preflight_unguarded)
ungated=
while IFS= read -r name; do
  [ -n "$name" ] || continue
  if grep -Fqx -- '*' <<<"$unguarded" || grep -Fqx -- "$name" <<<"$unguarded"; then
    ungated="$ungated $name"
  fi
done <<EOF
$table_tooled
EOF
[ -z "$ungated" ] \
  && ok "...and every step with an interpreter is invoked by CI with --require-tools" \
  || ko "the lint job invokes a tool-dependent step without --require-tools:$ungated"

# unrun_steps LIST: the internal steps no line of LIST names, `*` covering all of them.
unrun_steps() { # unrun_steps <newline-separated step names>
  local invoked="$1" name missing=""
  grep -Fqx -- '*' <<<"$invoked" && return 0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -Fqx -- "$name" <<<"$invoked" || missing="$missing $name"
  done <<EOF
$table_internal
EOF
  printf '%s' "$missing"
}
# unknown_steps LIST: the names LIST passes that are not steps at all.
unknown_steps() { # unknown_steps <newline-separated step names>
  local invoked="$1" name bad=""
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    [ "$name" = '*' ] && continue
    grep -Fqx -- "$name" <<<"$table_names" || bad="$bad $name"
  done <<EOF
$invoked
EOF
  printf '%s' "$bad"
}

invoked_steps=$(lint_preflight_steps)
[ -n "$invoked_steps" ] && ok "the lint job's preflight invocations name their steps" \
  || ko "no preflight step names read from the lint job -- the two pins below would pass over nothing"
missing_steps=$(unrun_steps "$invoked_steps")
[ -z "$missing_steps" ] \
  && ok "...and every assertion preflight implements itself is one the lint job names" \
  || ko "the lint job names no step for:$missing_steps"
bad_steps=$(unknown_steps "$invoked_steps")
[ -z "$bad_steps" ] \
  && ok "...and names no step the table does not hold" \
  || ko "the lint job passes preflight a step that does not exist:$bad_steps"

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
# The other shape of drift: a lint step's run line rewritten rather than added. The swap is
# asserted to have happened, so a change to the workflow's spelling fails here loudly instead of
# leaving a probe that rewrites nothing and passes.
probe_workflow_swap() { # probe_workflow_swap <exact old line> <new line>
  mkdir -p "$TMP/probe/.github/workflows"
  PROBE_OLD="$1" PROBE_NEW="$2" awk '
    $0 == ENVIRON["PROBE_OLD"] { print ENVIRON["PROBE_NEW"]; next }
    { print }
  ' "$ROOT/.github/workflows/skill-scripts.yml" >"$TMP/probe/.github/workflows/skill-scripts.yml"
  WORKFLOW="$TMP/probe/.github/workflows/skill-scripts.yml"
  # The swap is asserted by the file having CHANGED, which covers a probe that puts several lines
  # in place of one and keeps the original line among them (a condition above a run line).
  [ -s "$WORKFLOW" ] && ! cmp -s "$ROOT/.github/workflows/skill-scripts.yml" "$WORKFLOW"
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

# The drift the command word cannot see: a step that still calls preflight, with the wrong
# subcommand. Round 1's finding, and the reason the step names are read at all.
if probe_workflow_swap '        run: scripts/preflight.sh --require-tools modes' \
  '        run: scripts/preflight.sh --require-tools syntax'; then
  probe_steps=$(lint_preflight_steps)
  [ "$(unrun_steps "$probe_steps")" = " modes" ] \
    && ok "...and a lint step rewritten to a duplicate of another trips the step pin" \
    || ko "a lint step that stopped running the mode rule did not trip the step pin (verdict:$(unrun_steps "$probe_steps"))"
  [ -z "$(unknown_steps "$probe_steps")" ] \
    && ok "...without reporting the duplicate as a step that does not exist" \
    || ko "the duplicated step name was reported unknown (verdict:$(unknown_steps "$probe_steps"))"
else
  ko "the swap probe rewrote nothing: the lint job no longer spells the mode step as this file expects"
fi

if probe_workflow_swap '        run: scripts/preflight.sh --require-tools modes' \
  '        run: scripts/preflight.sh --require-tools mode-bits'; then
  [ "$(unknown_steps "$(lint_preflight_steps)")" = " mode-bits" ] \
    && ok "...and a step name the table does not hold is reported as such" \
    || ko "a lint step naming a step that does not exist did not trip the pin"
else
  ko "the swap probe rewrote nothing: the lint job no longer spells the mode step as this file expects"
fi

# A help flag exits 0 having asserted nothing, so the step it names is not run (round 2).
if probe_workflow_swap '        run: scripts/preflight.sh --require-tools syntax' \
  '        run: scripts/preflight.sh --help syntax'; then
  [ "$(unrun_steps "$(lint_preflight_steps)")" = " syntax" ] \
    && ok "...and a step turned into a --help invocation, which asserts nothing, trips it" \
    || ko "a --help invocation was read as running its step (verdict:$(unrun_steps "$(lint_preflight_steps)"))"
else
  ko "the swap probe rewrote nothing: the lint job no longer spells the syntax step as this file expects"
fi

# An argument that neuters an external check is the same drift on the other side of the table.
if probe_workflow_swap '        run: scripts/check-prompts.sh' \
  '        run: scripts/check-prompts.sh --help'; then
  probe_bare=$(workflow_bare_commands)
  grep -Fqx -- scripts/check-prompts.sh <<<"$probe_bare" \
    && ko "a --help argument on the prompt hygiene step still read as a bare invocation" \
    || ok "...and an argument on an external check's own step trips the bare-invocation pin"
else
  ko "the swap probe rewrote nothing: the prompts job no longer spells its step as this file expects"
fi
# ...while the macOS spelling, which is an operator and not an argument, must NOT be refused.
if probe_workflow_swap '        run: scripts/check-prompts.sh' \
  "        run: scripts/check-prompts.sh || { echo 'failed'; exit 1; }"; then
  grep -Fqx -- scripts/check-prompts.sh <<<"$(workflow_bare_commands)" \
    && ok "...while a shell operator after the command is not an argument, and is not refused" \
    || ko "the macOS '<suite> || { ... }' spelling was read as an argument"
else
  ko "the swap probe rewrote nothing: the prompts job no longer spells its step as this file expects"
fi

# ...and a tail that swallows the command's status is not a run of it either.
if probe_workflow_swap '        run: scripts/check-prompts.sh' \
  '        run: scripts/check-prompts.sh || true'; then
  grep -Fqx -- scripts/check-prompts.sh <<<"$(workflow_bare_commands)" \
    && ko "'|| true' after the prompt hygiene step still read as a bare invocation" \
    || ok "...and a '|| true' tail, which cannot go red, does not count as running the check"
else
  ko "the swap probe rewrote nothing: the prompts job no longer spells its step as this file expects"
fi
if probe_workflow_swap '        run: scripts/check-prompts.sh' \
  '        run: scripts/check-prompts.sh | cat'; then
  grep -Fqx -- scripts/check-prompts.sh <<<"$(workflow_bare_commands)" \
    && ko "a pipe after the prompt hygiene step still read as a bare invocation" \
    || ok "...nor does a pipe, whose status is the last command's"
else
  ko "the swap probe rewrote nothing: the prompts job no longer spells its step as this file expects"
fi

# A handler that propagates, followed by one that does not, is not a run either.
if probe_workflow_swap '        run: scripts/check-prompts.sh' \
  "        run: scripts/check-prompts.sh || { echo 'failed'; exit 1; } || true"; then
  grep -Fqx -- scripts/check-prompts.sh <<<"$(workflow_bare_commands)" \
    && ko "an accepted handler followed by '|| true' still read as a bare invocation" \
    || ok "...and the accepted handler must be the WHOLE tail, so a trailing '|| true' still trips it"
else
  ko "the swap probe rewrote nothing: the prompts job no longer spells its step as this file expects"
fi

# A condition is the other way to stop a step running without touching its run line.
if probe_workflow_swap '        run: scripts/preflight.sh --require-tools modes' \
  '        if: ${{ false }}
        run: scripts/preflight.sh --require-tools modes'; then
  [ "$(lint_conditional_runs)" = scripts/preflight.sh ] \
    && ok "...and a pinned step behind a false condition is reported" \
    || ko "a lint step behind 'if: false' was not reported (verdict:$(lint_conditional_runs))"
else
  ko "the swap probe rewrote nothing: the lint job no longer spells the mode step as this file expects"
fi
if probe_workflow_swap '        run: scripts/check-jq-shapes.sh' \
  '        if: ${{ !cancelled() }}
        run: scripts/check-jq-shapes.sh'; then
  [ -z "$(lint_conditional_runs)" ] \
    && ok "...while !cancelled(), which skips only a cancelled run, is not refused" \
    || ko "the !cancelled() condition was read as one that could skip the step"
else
  ko "the swap probe rewrote nothing: the lint job no longer spells the jq guard step as this file expects"
fi

# Dropping --require-tools is one word, and it turns CI's fail-closed step into a SKIP.
if probe_workflow_swap '        run: scripts/preflight.sh --require-tools shellcheck' \
  '        run: scripts/preflight.sh shellcheck'; then
  grep -Fqx -- shellcheck <<<"$(lint_preflight_unguarded)" \
    && ok "...and a tool-dependent step invoked without --require-tools is reported" \
    || ko "dropping --require-tools from the shellcheck step was not reported"
else
  ko "the swap probe rewrote nothing: the lint job no longer spells the shellcheck step as this file expects"
fi

# The shape that must NOT be refused: one invocation with no step names runs them all, which is a
# valid way to spell this job and would otherwise read as five missing assertions.
if probe_workflow_swap '        run: scripts/preflight.sh --require-tools modes' \
  '        run: scripts/preflight.sh --require-tools'; then
  [ -z "$(unrun_steps "$(lint_preflight_steps)")" ] \
    && ok "...while an invocation that names no step covers them all, and is not refused" \
    || ko "a bare preflight invocation was read as running no step"
else
  ko "the swap probe rewrote nothing: the lint job no longer spells the mode step as this file expects"
fi
WORKFLOW="$ROOT/.github/workflows/skill-scripts.yml"

# --- the checkout this suite runs in ------------------------------------------------------------

expect "this checkout's file list holds the script itself" 0 'scripts/preflight.sh' -- "$PF" files

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
exit "$?"
}
