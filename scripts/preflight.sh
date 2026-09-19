#!/usr/bin/env bash
# CI's lint job, runnable before you push. Every assertion the `lint` job of
# .github/workflows/skill-scripts.yml makes lives here, and the job runs it by calling this script
# rather than by restating it -- so what a push is judged by and what the local loop runs are one
# command, and a change to either is a change to both (ludics-lite#221, #123).
#
# Usage: preflight.sh [--root DIR] [--require-tools] [STEP...]
#        preflight.sh steps | globs | files
#
# With no STEP it runs them all, each one whether or not an earlier one failed -- the workflow's
# `if: !cancelled()` shape -- and prints a summary. Exit 0 when nothing failed, 1 when something
# did, 2 on a usage error or a scope that describes nothing.
#
#   - syntax           bash -n over every tracked script (THE FILE LIST below)
#   - modes            the two-way mode rule: a script is executable, an *.example.sh is not
#   - shellcheck       shellcheck --severity=error --external-sources over the same list
#   - powershell       pwsh parses scripts/*.ps1, and refuses to judge zero of them
#   - parse-guard      the two cleanup scripts still open and close their one brace group
#   - prompts          scripts/check-prompts.sh (the prompt-hygiene job's check, not lint's:
#                      a missing register line for a new suite is the other thing a push goes red
#                      for, and it is free to run here)
#   - jq-shapes        scripts/check-jq-shapes.sh
#   - jq-fixtures      scripts/test-check-jq-shapes.sh
#   - scratch-dirs     scripts/check-scratch-dirs.sh
#   - scratch-fixtures scripts/test-check-scratch-dirs.sh
#
# MISSING TOOLS. Without --require-tools a step whose interpreter is absent is SKIPped by name and
# does not fail the run: pwsh is on neither fleet mac, and a preflight that goes red for a tool
# the reader cannot install is a preflight the reader stops running. CI passes --require-tools, so
# an image that loses pwsh or shellcheck is a red step there rather than a quiet pass. A step named
# on the command line is still only skipped under that rule -- the flag, not the form, decides.
#
# --root DIR judges DIR instead of this script's own checkout. It is how scripts/test-preflight.sh
# puts a defective tree in front of each assertion; nothing else needs it.
#
# `steps` prints "name<TAB>command" per step (`-` for one implemented here), `globs` the file-list
# patterns, `files` the paths they expand to in the judged checkout. They are the read-only half of
# "one place": scripts/test-preflight.sh pins the step table against the lint job's steps, and
# issue-wave/scripts/test-fleet-worker.sh reads `globs` for its lint-coverage guard rather than
# re-deriving the list from the YAML the way it did while the list lived there.

set -uo pipefail

FILES=()

# THE FILE LIST, once. It was spelled three times in the lint job's YAML -- by the syntax step,
# the mode-bit step and the one that runs shellcheck -- and hand-copied a fourth time into a
# scratch buffer by anyone pre-flighting a push (ludics-lite#123). scripts/check-jq-shapes.sh and scripts/check-scratch-dirs.sh still restate it
# for their own default sweeps, which is ludics-lite#246 and not fixed here; they can read `globs`
# the day that is taken. Unquoted below on purpose: these are patterns for the shell to expand,
# with the same rules the workflow's own `for f in */scripts/*.sh ...` had -- a leading `.` is not
# matched, so a script under .github/scripts/ is genuinely outside CI's lint and reported as such
# rather than quietly covered.
GLOBS=('*/scripts/*.sh' 'ship-pr/hooks/*.sh' 'scripts/*.sh')

# THE STEP TABLE: `name:command`, with `-` where the assertion is implemented in this file. The
# commands are the scripts CI's lint job already invokes by path; running them from here too is
# what makes one command cover the whole job. test-preflight.sh reads this table and the workflow
# and refuses a step that is in one and not the other.
STEPS=(
  'syntax:-'
  'modes:-'
  'shellcheck:-'
  'powershell:-'
  'parse-guard:-'
  'prompts:scripts/check-prompts.sh'
  'jq-shapes:scripts/check-jq-shapes.sh'
  'jq-fixtures:scripts/test-check-jq-shapes.sh'
  'scratch-dirs:scripts/check-scratch-dirs.sh'
  'scratch-fixtures:scripts/test-check-scratch-dirs.sh'
)

# The two files the parse guard judges, named rather than globbed: the guard is about these two
# scripts' one brace group (ludics-lite#10), and a third file would be a decision, not a match.
PARSE_GUARD_FILES=(ship-pr/scripts/post-merge-cleanup.sh ship-pr/scripts/test-post-merge-cleanup.sh)

usage() { # the leading comment block, which is this script's manual
  awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "$0"
}

die() { # die <message>: a usage error or a scope that describes nothing
  printf 'preflight.sh: %s\n' "$1" >&2
  exit 2
}

# A refusal about a file in the checkout. Under GitHub Actions it is an annotation on that file's
# line of the diff, which is what the inline steps printed and is worth keeping; anywhere else the
# annotation syntax is noise in front of the sentence, so the sentence is printed on its own.
fail_file() { # fail_file <path> <message>
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    printf '::error file=%s::%s\n' "$1" "$2"
  else
    printf 'preflight: %s: %s\n' "$1" "$2"
  fi
}

step_command() { # step_command <name>: the external command, `-`, or empty when there is no such step
  local entry
  for entry in "${STEPS[@]}"; do
    if [ "${entry%%:*}" = "$1" ]; then
      printf '%s' "${entry#*:}"
      return 0
    fi
  done
  return 1
}

collect_files() { # fills FILES with the paths the globs expand to, relative to the judged checkout
  local pattern path matched
  [ "${#FILES[@]}" -eq 0 ] || return 0
  for pattern in "${GLOBS[@]}"; do
    matched=0
    # Unquoted: this is pathname expansion, the workflow's own. An unmatched pattern arrives as
    # itself, which the existence test drops. A BROKEN SYMLINK is kept, which `-f` would not have
    # been: `-f` follows the link, so a dangling one read as "no such path" and was dropped from
    # every sweep in silence -- while the inline `for f in */scripts/*.sh; do bash -n "$f"; done`
    # this replaced handed it to bash and went red. A path that exists as a link is a path this
    # list owes a verdict on, and bash and shellcheck both refuse it loudly (round 1).
    for path in $pattern; do
      { [ -e "$path" ] || [ -L "$path" ]; } && {
        FILES+=("$path")
        matched=1
      }
    done
    # Fail closed per PATTERN, not merely when the whole sweep is empty: the inline loops this
    # replaced handed an unmatched pattern to bash and shellcheck as the literal it arrives as,
    # and went red. Dropping it silently would let the last ship-pr/hooks script move away while
    # the other two patterns keep FILES nonempty and every step green over a scope that has
    # stopped describing the checkout (round 2). A pattern that should no longer match is an edit
    # to this list, which is the whole point of the list being here.
    [ "$matched" -eq 1 ] ||
      die "no file matched $pattern under $ROOT -- the file list has stopped describing the checkout"
  done
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- the assertions --------------------------------------------------------------------------

step_syntax() {
  local f rc=0
  collect_files
  for f in "${FILES[@]}"; do
    bash -n "$f" || {
      fail_file "$f" "$f does not parse: 'bash -n' refused it"
      rc=1
    }
  done
  return "$rc"
}

# The two-way mode rule. A `> tmp && mv` rewrite of a script drops its mode bit and git tracks the
# mode, so the drop commits; without this the first symptom is an `exit 126` from a suite in some
# other job, which reads as that suite failing rather than as a lost mode bit. The suffix names the
# sourced template: an `*.example.sh` is `.`-ed by the script that reads it
# (scripts/wake-lab-hosts.example.sh, sourced by wake-lab.sh) and is never executed, so it is
# tracked 100644 on purpose. That half is asserted rather than merely exempted, because the pass
# the suffix buys is sound only while the class really is the sourced one: a future `*.example.sh`
# written to be run would otherwise skip the mode check in silence, and a stray `chmod +x` on a
# template would void the convention. The PowerShell scripts are outside the list entirely -- they
# are `.ps1`, and the powershell step parses them rather than running them.
step_modes() {
  local f rc=0
  collect_files
  for f in "${FILES[@]}"; do
    case "$f" in
    *.example.sh)
      if [ -x "$f" ]; then
        fail_file "$f" "$f is an .example.sh: it is sourced, never executed, so it must NOT be executable (the mode check gives the suffix a pass on that assertion, and the pass is only sound if the class is really the sourced one); run 'chmod -x $f' and commit it"
        rc=1
      fi
      ;;
    *)
      if [ ! -x "$f" ]; then
        fail_file "$f" "$f is not executable; restore the mode bit with 'chmod +x $f' and commit it"
        rc=1
      fi
      ;;
    esac
  done
  return "$rc"
}

# Errors only: the warning tier is style and a few false positives on deliberately unquoted globs;
# the error tier is what breaks a script.
step_shellcheck() {
  collect_files
  shellcheck --severity=error --external-sources "${FILES[@]}"
}

# Parse the Windows repair scripts without executing their Windows-only networking and registry
# commands. The glob is what keeps this honest: enable-active-hours-windows.ps1 joined
# enable-wol-windows.ps1 there, and a third repair script must not need an edit here to be judged.
# Only `scripts/*.ps1` -- the PowerShell under a skill directory
# (issue-wave/scripts/test-windows-driver.ps1) is really EXECUTED by the windows-driver job, which
# is a stronger check than parsing it twice. A glob matching nothing is a refusal, not a pass: a
# parse check judging zero files should be red.
step_powershell() {
  pwsh -NoProfile -Command '
    $rc = 0
    $files = @(Get-ChildItem -Path "scripts" -Filter "*.ps1" | Sort-Object Name)
    if ($files.Count -eq 0) {
      Write-Error "no scripts/*.ps1 found: the parse check is judging nothing"
      exit 1
    }
    foreach ($f in $files) {
      $tokens = $null
      $errors = $null
      [System.Management.Automation.Language.Parser]::ParseFile(
        $f.FullName,
        [ref] $tokens,
        [ref] $errors
      ) > $null
      if ($errors.Count -ne 0) {
        $errors | ForEach-Object { Write-Error "$($f.Name): $_" }
        $rc = 1
      } else {
        Write-Host "$($f.Name): parsed"
      }
    }
    exit $rc
  '
}

# post-merge-cleanup.sh and test-post-merge-cleanup.sh are each one brace group ending in
# `exit "$?"` and `}` (ludics-lite#10), so a mid-run rewrite cannot resume the shell at a shifted
# offset. The cost is that a command appended past the closing brace is never read, and that
# failure is silent; this is the guard on the guard. A file that is not there is refused rather
# than skipped -- a rename would otherwise take the guard with it in silence.
step_parse_guard() {
  local f rc=0
  for f in "${PARSE_GUARD_FILES[@]}"; do
    if [ ! -f "$f" ]; then
      fail_file "$f" "$f is missing: the parse guard names it, so a rename is a change to this script too"
      rc=1
      continue
    fi
    if [ "$(tail -n 2 "$f")" != "$(printf 'exit "$?"\n}')" ]; then
      fail_file "$f" "$f must end in 'exit \"\$?\"' and '}' (the parse guard); anything past them is never read"
      rc=1
    fi
    if ! awk '/^set -[a-z]*o pipefail$/ { s = NR; next } s && !/^#/ && !/^$/ { seen = 1; exit ($0 == "{") ? 0 : 1 } END { if (!seen) exit 1 }' "$f"; then
      fail_file "$f" "$f must open its brace group as the first command after 'set -o pipefail', above the first fork"
      rc=1
    fi
  done
  return "$rc"
}

# --- running them ----------------------------------------------------------------------------

# The interpreter each step needs, empty when it needs nothing beyond this shell.
step_tool() { # step_tool <name>
  case "$1" in
  syntax) printf 'bash' ;;
  shellcheck) printf 'shellcheck' ;;
  powershell) printf 'pwsh' ;;
  esac
}

run_step() { # run_step <name>: 0 pass, 1 fail, 3 skipped
  local name="$1" cmd tool
  cmd=$(step_command "$name") || die "no such step: $name (run 'preflight.sh steps')"
  tool=$(step_tool "$name")
  if [ -n "$tool" ] && ! have "$tool"; then
    if [ -n "$REQUIRE_TOOLS" ]; then
      printf 'preflight: %s: FAIL (%s not found, and --require-tools was given)\n' "$name" "$tool"
      return 1
    fi
    printf 'preflight: %s: SKIP (%s not found; CI runs this step with --require-tools)\n' "$name" "$tool"
    return 3
  fi
  if [ "$cmd" != '-' ]; then
    # Fail closed on a step whose script is not there: CI's own step would be a red `No such file`,
    # and a local pass over a check that did not run is the failure this script exists to end.
    if [ ! -x "$cmd" ]; then
      printf 'preflight: %s: FAIL (%s is not there or not executable)\n' "$name" "$cmd"
      return 1
    fi
    "./$cmd"
  else
    case "$name" in
    syntax) step_syntax ;;
    modes) step_modes ;;
    shellcheck) step_shellcheck ;;
    powershell) step_powershell ;;
    parse-guard) step_parse_guard ;;
    esac
  fi
  local rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'preflight: %s: PASS\n' "$name"
    return 0
  fi
  printf 'preflight: %s: FAIL (exit %s)\n' "$name" "$rc"
  return 1
}

# --- arguments -------------------------------------------------------------------------------

ROOT=
REQUIRE_TOOLS=
WANTED=()
while [ "$#" -gt 0 ]; do
  case "$1" in
  -h | --help)
    usage
    exit 0
    ;;
  --root)
    [ "$#" -ge 2 ] || die "--root needs a directory"
    ROOT=$2
    shift 2
    ;;
  --require-tools)
    REQUIRE_TOOLS=1
    shift
    ;;
  -*) die "unknown option: $1" ;;
  *)
    WANTED+=("$1")
    shift
    ;;
  esac
done

if [ -z "$ROOT" ]; then
  ROOT=$(cd "$(dirname "$0")/.." && pwd -P) || die "cannot resolve this script's checkout"
else
  [ -d "$ROOT" ] || die "no such directory: $ROOT"
  ROOT=$(CDPATH= cd "$ROOT" && pwd -P) || die "cannot resolve --root"
fi
# Every glob, every step's script and every annotation path is relative to the checkout, so the
# expansion and the run happen there and nowhere else.
CDPATH= cd "$ROOT" || die "cannot enter $ROOT"

# The read-only queries, before anything is judged.
if [ "${#WANTED[@]}" -eq 1 ]; then
  case "${WANTED[0]}" in
  steps)
    for entry in "${STEPS[@]}"; do printf '%s\t%s\n' "${entry%%:*}" "${entry#*:}"; done
    exit 0
    ;;
  globs)
    printf '%s\n' "${GLOBS[@]}"
    exit 0
    ;;
  files)
    collect_files
    printf '%s\n' "${FILES[@]}"
    exit 0
    ;;
  esac
fi

if [ "${#WANTED[@]}" -eq 0 ]; then
  for entry in "${STEPS[@]}"; do WANTED+=("${entry%%:*}"); done
  printf 'preflight: judging %s\n' "$ROOT"
fi

for name in "${WANTED[@]}"; do
  step_command "$name" >/dev/null || die "no such step: $name (run 'preflight.sh steps')"
done

passed=0
failed=0
skipped=0
skipped_names=
for name in "${WANTED[@]}"; do
  run_step "$name"
  case $? in
  0) passed=$((passed + 1)) ;;
  3)
    skipped=$((skipped + 1))
    skipped_names="$skipped_names $name"
    ;;
  *) failed=$((failed + 1)) ;;
  esac
done

if [ -n "$skipped_names" ]; then
  printf 'preflight: %d passed, %d failed, %d skipped (%s)\n' "$passed" "$failed" "$skipped" "${skipped_names# }"
else
  printf 'preflight: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
fi
[ "$failed" -eq 0 ] || exit 1
exit 0
