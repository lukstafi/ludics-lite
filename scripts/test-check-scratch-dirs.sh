#!/usr/bin/env bash
# Exercises check-scratch-dirs.sh against scratch files: one file per shape the guard exists to
# refuse, each with the shape that must PASS beside it -- a scan that cannot fail would prove
# nothing, and a scan that refuses everything is worse than none (ludics-lite#55). Scratch
# CHECKOUTS then pin what the argument-less default sweep reads, which the probes cannot: they
# are passed by path and so say nothing about scope. It ends on the three suites that
# independently rediscovered this fix -- test-sync-routines.sh, test-fleet-worker.sh,
# test-check-jq-shapes.sh -- each with its one resolution line removed, where the guard must find
# what its author found by accident. A rule nobody has ever seen fire is a rule nobody can trust.
#
# Usage: test-check-scratch-dirs.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd -P)
ROOT=$(cd "$HERE/.." && pwd -P)
CS="$HERE/check-scratch-dirs.sh"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/check-scratch-dirs-test.XXXXXX") || exit 1
# The suite's own scratch root, resolved physically -- the very rule under test, and here for the
# reason the guard gives: the scratch checkouts below install the guard, which computes its ROOT
# with `pwd -P`, so an unresolved $TMP and the guard's idea of the same directory would be spelled
# differently and every assertion comparing its output against a $TMP path would stop matching.
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

# probe NAME: writes the scratch file $TMP/NAME.sh from stdin. It does not PRINT the path the way
# the jq guard's fixtures do: a heredoc body carrying a `$(` inside a `$(probe ...)` loses bash's
# parser in the command substitution, and every probe here is shell source full of them. Each
# case names its file on the expect line instead.
probe() {
  cat >"$TMP/$1.sh"
}

CLEAN='every mktemp -d is resolved or rooted in a resolved path'
REFUSAL='without being resolved physically'

# --- the shapes that must pass ------------------------------------------------------------------

probe safe_idiom <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
mkdir -p "$TMP/bin"
EOF
expect "the house idiom passes" 0 "$CLEAN" -- "$CS" "$TMP/safe_idiom.sh"

# A trap body runs at exit, after every resolution in the file, so it is not a use: two of the
# three suites that already do this right register their cleanup between the mktemp and the
# resolution.
probe safe_trap_first <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
TMP=$(cd "$TMP" && pwd -P) || exit 1
echo "$TMP"
EOF
expect "a trap between the mktemp and the resolution is not a use" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_trap_first.sh"

# The comment explaining the resolution names the variable, directly above the resolution.
probe safe_comment <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
# An unresolved $TMP here and the script's idea of the same directory are spelled differently.
TMP=$(cd "$TMP" && pwd -P) || exit 1
echo "$TMP"
EOF
expect "a comment naming the variable is not a use" 0 "$CLEAN" -- "$CS" "$TMP/safe_comment.sh"

# A child of a physical path is physical, so a template rooted in an already-resolved variable
# needs nothing further. This is post-merge-cleanup.sh's shape.
probe safe_inherited <<'EOF'
canonical_dir() {
  (cd "$1" && pwd -P) || fail "cannot resolve: $1"
}
TEMP_ROOT=$(canonical_dir "${TMPDIR:-/tmp}") || exit 1
work=$(mktemp -d "$TEMP_ROOT/ship-pr-work.XXXXXX") || exit 1
git init "$work"
EOF
expect "a template rooted in a variable resolved by a function passes" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_inherited.sh"

# ...including when the root is assigned BELOW the function that builds on it, which is exactly
# how post-merge-cleanup.sh reads: TEMP_ROOT is set near the bottom, its scratch directories are
# made in functions near the top. A one-pass scanner called all three of those unresolved.
probe safe_root_below <<'EOF'
canonical_dir() {
  (cd "$1" && pwd -P)
}
make_work() {
  WORK=$(mktemp -d "$TEMP_ROOT/work.XXXXXX") || return 1
  git init "$WORK"
}
TEMP_ROOT=$(canonical_dir "${TMPDIR:-/tmp}") || exit 1
make_work
EOF
expect "a root assigned below its use still counts" 0 "$CLEAN" -- "$CS" "$TMP/safe_root_below.sh"

probe safe_inherited_inline <<'EOF'
BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
d=$(mktemp -d "$BASE/thing.XXXXXX") || exit 1
echo "$d"
EOF
expect "a template rooted in a pwd -P substitution passes" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_inherited_inline.sh"

# The parent of a physical path is physical: post-merge-cleanup.sh allocates its session archives
# beside a session worktree it has already canonicalized.
probe safe_dirname <<'EOF'
canonical_dir() {
  (cd "$1" && pwd -P)
}
SESSION=$(canonical_dir "$2") || exit 1
SESSION_PARENT=$(dirname "$SESSION")
ARCHIVE=$(mktemp -d "$SESSION_PARENT/.recovery.XXXXXX") || exit 1
echo "$ARCHIVE"
EOF
expect "a template rooted in the dirname of a resolved path passes" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_dirname.sh"

# A chain: a scratch directory under a resolved root is itself resolved, and certifies the next
# one down. Each link costs a round of the guard's fixpoint.
probe safe_chain <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
inner=$(mktemp -d "$TMP/inner.XXXXXX") || exit 1
deeper=$(mktemp -d "$inner/deeper.XXXXXX") || exit 1
echo "$deeper"
EOF
expect "a scratch directory under a resolved scratch directory passes" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_chain.sh"

probe safe_local <<'EOF'
case_root() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/case.XXXXXX") || return 1
  d=$(cd "$d" && pwd -P) || return 1
  printf '%s' "$d"
}
EOF
expect "a local variable inside a function passes" 0 "$CLEAN" -- "$CS" "$TMP/safe_local.sh"

# A file with no mktemp -d at all is out of the rule's way, and says so in the same summary line.
probe safe_no_mktemp <<'EOF'
ROOT=$(cd "$(dirname "$0")/.." && pwd -P)
echo "$ROOT"
EOF
expect "a file with no mktemp -d passes" 0 "$CLEAN" -- "$CS" "$TMP/safe_no_mktemp.sh"

# Round 1: a usage string is data. `echo 'TMP=$(mktemp -d ...)'` in a --help body is not an
# allocation, and refusing it would turn CI red the day any scanned script grows help text.
probe safe_quoted_usage <<'EOF'
usage() {
  echo 'Every suite opens with TMP=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX") and resolves it.'
}
EOF
expect "a mktemp -d inside a single-quoted string is data, not code" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_quoted_usage.sh"

# ...and so is a heredoc body: it belongs to whatever reads it.
probe safe_heredoc <<'OUTER'
cat <<'DOC'
The idiom is TMP=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX"), resolved on the line below.
DOC
cat <<-'TABBED'
	and an indented one: work=$(mktemp -d /tmp/work.XXXXXX)
	TABBED
OUTER
expect "a mktemp -d inside a heredoc body is data, not code" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_heredoc.sh"

# A template-less `mktemp -d` defaults to tmp.XXXXXXXXXX under $TMPDIR -- as unresolved as a
# spelled-out template, and resolved the same way.
probe safe_no_template <<'EOF'
d=$(mktemp -d) || exit 1
d=$(cd "$d" && pwd -P) || exit 1
echo "$d"
EOF
expect "a template-less mktemp -d that is resolved passes" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_no_template.sh"

# Round 2: bash joins a backslash-continued command, so the guard does too -- and the joined text
# is judged at the line the command started on.
probe safe_continuation <<'EOF'
TMP=$(mktemp \
  -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
echo "$TMP"
EOF
expect "a line-continued mktemp -d that is resolved passes" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_continuation.sh"

# Round 2: a `local` assignment belongs to one function's scope, and short names are reused across
# functions. Folding a helper's local into the global of the same name made a correct file fail.
probe safe_local_shadow <<'EOF'
BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
helper() {
  local BASE=${TMPDIR:-/tmp}
  echo "$BASE"
}
work=$(mktemp -d "$BASE/work.XXXXXX") || exit 1
echo "$work"
EOF
expect "a function-local of the same name does not un-resolve the global" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_local_shadow.sh"

# Round 3: a quoted command substitution is the same capture. Refusing it would have failed an
# ordinary spelling in the mandatory lint job.
probe safe_quoted_capture <<'EOF'
TMP="$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX")" || exit 1
TMP="$(cd "$TMP" && pwd -P)" || exit 1
mkdir -p "$TMP/bin"
EOF
expect "a quoted command substitution is still a capture" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_quoted_capture.sh"

# Round 4: `declare`/`typeset` are ordinary declaration syntax, and the assignment table already
# read them; only the capture check did not.
probe safe_declare <<'EOF'
declare TMP="$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX")" || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
mkdir -p "$TMP/bin"
EOF
expect "a declare/typeset capture is a capture" 0 "$CLEAN" -- "$CS" "$TMP/safe_declare.sh"

# Round 4: `mktemp [OPTION]... [TEMPLATE]` -- the directory flag can sit anywhere in the option
# list, bundled or spelled long, and a resolved one of any of those spellings passes.
probe safe_option_spellings <<'EOF'
a=$(mktemp -q -d "${TMPDIR:-/tmp}/a.XXXXXX") || exit 1
a=$(cd "$a" && pwd -P) || exit 1
b=$(mktemp --directory "${TMPDIR:-/tmp}/b.XXXXXX") || exit 1
b=$(cd "$b" && pwd -P) || exit 1
c=$(mktemp -qd "${TMPDIR:-/tmp}/c.XXXXXX") || exit 1
c=$(cd "$c" && pwd -P) || exit 1
echo "$a $b $c"
EOF
expect "every spelling of the directory option is read, and passes when resolved" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_option_spellings.sh"

# A plain `mktemp` (a FILE) is out of the rule's way whatever else is on its option list.
probe safe_file_mktemp <<'EOF'
f=$(mktemp -q "${TMPDIR:-/tmp}/f.XXXXXX") || exit 1
printf 'x' > "$f"
EOF
expect "a file mktemp is not a directory mktemp" 0 "$CLEAN" -- "$CS" "$TMP/safe_file_mktemp.sh"

# Round 5: the call is the same command however it is spelled on disk, and its value-taking
# options take their values.
probe safe_path_and_valued_options <<'EOF'
a=$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/a.XXXXXX") || exit 1
a=$(cd "$a" && pwd -P) || exit 1
b=$(mktemp -p "${TMPDIR:-/tmp}" -d b.XXXXXX) || exit 1
b=$(cd "$b" && pwd -P) || exit 1
echo "$a $b"
EOF
expect "a path-qualified call and a -p DIR -d call pass when resolved" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_path_and_valued_options.sh"

# Round 5: an escaped dollar in an unquoted heredoc is emitted as text and runs nothing.
probe safe_escaped_substitution <<'OUTER'
cat <<EOF
the idiom is \$(mktemp -d "\${TMPDIR:-/tmp}/x.XXXXXX"), resolved on the line below
EOF
OUTER
expect "an escaped substitution in an unquoted heredoc is text" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_escaped_substitution.sh"

# Round 5: a `mktemp -d` named inside a double-quoted MESSAGE is not a second allocation.
probe safe_quoted_message <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || bail "mktemp -d failed for the suite"
TMP=$(cd "$TMP" && pwd -P) || exit 1
echo "$TMP"
EOF
expect "a mktemp -d named in an error message is not a second call" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_quoted_message.sh"

# Round 6: the CDPATH-proof spelling every refusal now recommends, and a stderr redirect on the
# capturing call, which this repository writes and which sends nothing but diagnostics away.
probe safe_cdpath_form <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX" 2>/dev/null) || exit 1
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
echo "$TMP"
EOF
expect "the CDPATH-proof resolution and a 2>/dev/null capture pass" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_cdpath_form.sh"

# Round 6: an attached short-option value, resolved.
probe safe_attached_option <<'EOF'
d=$(mktemp -p/tmp -d probe.XXXXXX) || exit 1
d=$(CDPATH= cd "$d" && pwd -P) || exit 1
echo "$d"
EOF
expect "an attached -p/tmp value does not hide the directory flag" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_attached_option.sh"

# --- the shapes that must be refused --------------------------------------------------------

probe bad_tmpdir <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
mkdir -p "$TMP/bin"
EOF
expect "an unresolved TMPDIR scratch directory is refused" 1 "$REFUSAL" -- "$CS" "$TMP/bad_tmpdir.sh"

# The literal /tmp is the same defect wearing a different template: /tmp is a symlink to
# /private/tmp on macOS just as /var is to /private/var.
probe bad_literal_tmp <<'EOF'
TEST_ROOT=$(mktemp -d "/tmp/suite-test.XXXXXX") || exit 1
mkdir -p "$TEST_ROOT/case"
EOF
expect "an unresolved literal /tmp scratch directory is refused" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_literal_tmp.sh"

# Before FIRST USE, not merely somewhere in the file: the line that used the unresolved spelling
# does not get the resolution that follows it, and this is how the defect survives a reader who
# greps for `pwd -P` and finds one.
probe bad_late_resolution <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
mkdir -p "$TMP/bin"
out=$(run_it "$TMP/bin")
TMP=$(cd "$TMP" && pwd -P) || exit 1
EOF
expect "a resolution after the first use is refused" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_late_resolution.sh"
expect "...and the refusal names the line that used it" 1 "used at line 2" -- \
  "$CS" "$TMP/bad_late_resolution.sh"

# `pwd` alone answers with the logical path, $PWD, which on macOS is the very /var spelling the
# resolution exists to leave behind.
probe bad_logical_pwd <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd) || exit 1
mkdir -p "$TMP/bin"
EOF
expect "a resolution with pwd but not pwd -P is refused" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_logical_pwd.sh"

# The resolution has to land back in the SAME variable. Resolving into a second name leaves every
# later reader of the first one holding the environment's spelling.
probe bad_other_name <<'EOF'
SNAP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/snap.XXXXXX") || exit 1
real=$(cd "$SNAP_DIR" && pwd -P) || exit 1
echo "$SNAP_DIR"
EOF
expect "a resolution into a different variable is refused" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_other_name.sh"

probe bad_uncaptured <<'EOF'
cd "$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX")" || exit 1
EOF
expect "a mktemp -d whose result is not captured is refused" 1 'not captured in a variable assignment' -- \
  "$CS" "$TMP/bad_uncaptured.sh"

probe bad_unused <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
EOF
expect "a mktemp -d that is never used and never resolved is refused" 1 'never used and never resolved' -- \
  "$CS" "$TMP/bad_unused.sh"

# Round 1: the common `$(mktemp -d)` takes no template at all. A rule that demanded whitespace
# after the `-d` never saw it, and reported the file clean.
probe bad_no_template <<'EOF'
d=$(mktemp -d) || exit 1
echo "$d"
EOF
expect "a template-less mktemp -d that is not resolved is refused" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_no_template.sh"

# ...and the body must END where its terminator says. A delimiter named inside single quotes --
# `cat <<'USAGE'`, the shape every usage() in this repository uses -- was read after the quotes had
# been blanked, so the scanner waited for a terminator that could never arrive and swallowed the
# rest of the file. Everything below such a heredoc must still be judged:
probe bad_after_heredoc <<'OUTER'
usage() {
  cat <<'USAGE'
usage: thing [--list]
USAGE
}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
mkdir -p "$TMP/bin"
OUTER
expect "an unresolved scratch dir below a quoted-delimiter heredoc is still refused" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_after_heredoc.sh"

# Round 1: resolved-ness is a property of the name across the WHOLE file, so an ordinary
# reassignment un-resolves it. Without this, a resolved root could be overwritten with the
# environment's own spelling and every scratch directory under it would still read as clean.
probe bad_reassigned_root <<'EOF'
BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
BASE=${TMPDIR:-/tmp}
work=$(mktemp -d "$BASE/work.XXXXXX") || exit 1
echo "$work"
EOF
expect "a resolved root that is reassigned no longer certifies what is under it" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_reassigned_root.sh"

# Round 1: the use can share the assignment's own line, and the resolution below does not reach a
# command that already ran.
probe bad_same_line_use <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX"); consume "$TMP"
TMP=$(cd "$TMP" && pwd -P) || exit 1
EOF
expect "a use on the assignment line itself is refused" 1 'used later on its OWN line' -- \
  "$CS" "$TMP/bad_same_line_use.sh"

# Round 2: ordinary command wrapping must not walk past the guard. Neither physical line carries
# a `mktemp -d` on its own.
probe bad_continuation <<'EOF'
TMP=$(mktemp \
  -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
mkdir -p "$TMP/bin"
EOF
expect "a line-continued mktemp -d that is not resolved is refused" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_continuation.sh"

# Round 2: a `pwd -P` present in the value proves nothing about the value. The resolution has to
# BE the assignment, which is the one idiom every refusal names.
probe bad_decorative_pwd <<'EOF'
BASE=$(pwd -P >/dev/null; printf '%s\n' "${TMPDIR:-/tmp}")
work=$(mktemp -d "$BASE/work.XXXXXX") || exit 1
echo "$work"
EOF
expect "a side-effect-only pwd -P does not resolve the variable it decorates" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_decorative_pwd.sh"

# Round 2: inheritance reaches exactly one component below a physical root. A deeper template
# passes through a component that can itself be a symlink -- the same aliasing, one directory in.
probe bad_deep_template <<'EOF'
BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
work=$(mktemp -d "$BASE/cache/work.XXXXXX") || exit 1
echo "$work"
EOF
expect "a template that traverses a component below the resolved root is refused" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_deep_template.sh"

# Round 2: the deferred trap is data because its body is single-quoted -- not because it is on a
# line beginning with `trap`. A command beside it on the same line runs now.
probe bad_trap_then_use <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT; consume "$TMP"
TMP=$(cd "$TMP" && pwd -P) || exit 1
EOF
expect "a command beside a trap on the same line is still a use" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_trap_then_use.sh"

# ...and a DOUBLE-quoted trap body expands when the trap is registered, so it is itself a use of
# the unresolved spelling.
probe bad_trap_double_quoted <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
trap "rm -rf $TMP" EXIT
TMP=$(cd "$TMP" && pwd -P) || exit 1
EOF
expect "a double-quoted trap body is a use, since it expands at registration" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_trap_double_quoted.sh"

# Round 3, the inverse of round 2's scope fix: inside a function that SHADOWS a resolved global,
# the global's resolution says nothing about the value, so nothing there may inherit from it.
probe bad_local_shadow_inherits <<'EOF'
BASE=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
helper() {
  local BASE=${TMPDIR:-/tmp}
  work=$(mktemp -d "$BASE/work.XXXXXX") || return 1
  echo "$work"
}
helper
EOF
expect "a mktemp under a locally shadowed root does not inherit the global's resolution" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_local_shadow_inherits.sh"

# Round 3: `export TMP` hands the unresolved value to every command after it, with no textual
# expansion for a scanner to see. It is a use.
probe bad_bare_export <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
export TMP
consume
TMP=$(cd "$TMP" && pwd -P) || exit 1
EOF
expect "a bare-name export before the resolution is a use" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_bare_export.sh"

# Round 4: the option list is a list. A literal `-d` right after the name was the only spelling
# the first cut saw, so `-q -d`, `--directory` and a bundled `-qd` were skipped entirely.
probe bad_option_spellings <<'EOF'
a=$(mktemp -q -d "${TMPDIR:-/tmp}/a.XXXXXX") || exit 1
mkdir -p "$a/bin"
EOF
expect "an unresolved mktemp -q -d is refused" 1 "$REFUSAL" -- "$CS" "$TMP/bad_option_spellings.sh"
probe bad_long_option <<'EOF'
a=$(mktemp --directory "${TMPDIR:-/tmp}/a.XXXXXX") || exit 1
mkdir -p "$a/bin"
EOF
expect "an unresolved mktemp --directory is refused" 1 "$REFUSAL" -- "$CS" "$TMP/bad_long_option.sh"
probe bad_bundled_option <<'EOF'
a=$(mktemp -qd "${TMPDIR:-/tmp}/a.XXXXXX") || exit 1
mkdir -p "$a/bin"
EOF
expect "an unresolved bundled -qd is refused" 1 "$REFUSAL" -- "$CS" "$TMP/bad_bundled_option.sh"

# Round 4: a resolution has to RUN where the allocation did. Defining a function does not execute
# its body, so the commands after the allocation still see the environment's spelling.
probe bad_resolution_in_function <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
normalize() {
  TMP=$(cd "$TMP" && pwd -P)
}
echo "$TMP"
EOF
expect "a resolution inside an uncalled function is not a resolution" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_resolution_in_function.sh"

# ...and neither is one inside a branch that may not be taken.
probe bad_resolution_in_branch <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
if [ -n "${CANONICAL:-}" ]; then
  TMP=$(cd "$TMP" && pwd -P)
fi
echo "$TMP"
EOF
expect "a resolution inside a conditional branch is not a resolution" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_resolution_in_branch.sh"

# Round 4: a resolver is recognized by what its body RETURNS. A `pwd -P` whose output goes to
# /dev/null, with the environment spelling printed after it, is not one.
probe bad_fake_resolver <<'EOF'
looks_canonical() {
  (cd "$1" && pwd -P) >/dev/null
  printf '%s\n' "${TMPDIR:-/tmp}"
}
BASE=$(looks_canonical "${TMPDIR:-/tmp}")
work=$(mktemp -d "$BASE/work.XXXXXX") || exit 1
echo "$work"
EOF
expect "a function that discards its pwd -P is not a resolver" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_fake_resolver.sh"

# Round 4: dirname removes the last component only, so its argument has to be the resolved
# variable itself -- `dirname "$ROOT/cache/file"` answers $ROOT/cache, and cache can be a link.
probe bad_dirname_deep <<'EOF'
ROOT=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
BASE=$(dirname "$ROOT/cache/file")
work=$(mktemp -d "$BASE/work.XXXXXX") || exit 1
echo "$work"
EOF
expect "a dirname of a deeper path does not inherit the root's resolution" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_dirname_deep.sh"

# Round 4: only a QUOTED heredoc delimiter stops the shell expanding the body. With `cat <<EOF`
# the command substitution runs before cat sees a byte of it.
probe bad_unquoted_heredoc <<'OUTER'
cat <<EOF
the directory is $(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")
EOF
OUTER
expect "a mktemp -d in an UNQUOTED heredoc body is code, and is refused" 1 'not captured in a variable assignment' -- \
  "$CS" "$TMP/bad_unquoted_heredoc.sh"

# Round 5: `/usr/bin/mktemp` is the same command. The basename names it; the slash is a path.
probe bad_path_qualified <<'EOF'
TMP=$(/usr/bin/mktemp -d "/tmp/probe.XXXXXX")
consume "$TMP"
EOF
expect "a path-qualified mktemp -d is the same call" 1 "$REFUSAL" -- "$CS" "$TMP/bad_path_qualified.sh"

# Round 5: `-p DIR` takes its value, so the word after it is not the template and the `-d` behind
# it still has to be seen.
probe bad_valued_option <<'EOF'
TMP=$(mktemp -p "${TMPDIR:-/tmp}" -d probe.XXXXXX)
consume "$TMP"
EOF
expect "a value-taking option does not hide the directory flag" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_valued_option.sh"

# Round 5: the resolving substitution has to BE the value. A component glued on afterwards can be
# a symlink, which is the guard's own failure mode one directory further along.
probe bad_suffixed_resolution <<'EOF'
ROOT=$(cd "${TMPDIR:-/tmp}" && pwd -P)/cache
TMP=$(mktemp -d "$ROOT/probe.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a resolved substitution with a component appended does not certify what is under it" 1 \
  "$REFUSAL" -- "$CS" "$TMP/bad_suffixed_resolution.sh"

# Round 5: an assignment in a branch that may never run cannot certify a name.
probe bad_conditional_resolution <<'EOF'
BASE=${BASE:-/tmp}
if false; then
  BASE=$(cd /tmp && pwd -P)
fi
TMP=$(mktemp -d "$BASE/probe.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "an assignment inside a branch does not certify the name" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_conditional_resolution.sh"

# Round 5: an assignment-shaped prefix and a call later on the line are two different commands.
probe bad_uncaptured_second_call <<'EOF'
ROOT=$(pwd -P); mktemp -d /tmp/leaked.XXXXXX
ROOT=$(cd "$ROOT" && pwd -P)
echo "$ROOT"
EOF
expect "a call outside the captured substitution is uncaptured" 1 'not captured in a variable assignment' -- \
  "$CS" "$TMP/bad_uncaptured_second_call.sh"

# ...and so is a second one trailing a capture that is otherwise correct: the first directory is
# resolved, the second is leaked.
probe bad_trailing_second_call <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/a.XXXXXX"); mktemp -d /tmp/leaked.XXXXXX
TMP=$(cd "$TMP" && pwd -P) || exit 1
echo "$TMP"
EOF
expect "a second call trailing a good capture is refused on its own" 1 \
  'outside the substitution the assignment captures' -- "$CS" "$TMP/bad_trailing_second_call.sh"

# Round 6: the whole-value rule reaches the resolver-function branch too.
probe bad_resolver_suffix <<'EOF'
canonical_dir() {
  (CDPATH= cd "$1" && pwd -P)
}
ROOT=$(canonical_dir "${TMPDIR:-/tmp}")/cache
TMP=$(mktemp -d "$ROOT/probe.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a resolver call with a component appended does not certify what is under it" 1 \
  "$REFUSAL" -- "$CS" "$TMP/bad_resolver_suffix.sh"

# Round 6: `-p/tmp` is the option with its value attached, not the template.
probe bad_attached_option <<'EOF'
d=$(mktemp -p/tmp -d probe.XXXXXX) || exit 1
echo "$d"
EOF
expect "an unresolved mktemp -p/tmp -d is refused" 1 "$REFUSAL" -- "$CS" "$TMP/bad_attached_option.sh"

# Round 6: only an ODD run of backslashes escapes the dollar; `\\$(` is an escaped backslash
# followed by a live substitution.
probe bad_even_backslashes <<'OUTER'
cat <<EOF
two backslashes and a live call: \\$(mktemp -d /tmp/x.XXXXXX)
EOF
OUTER
expect "an even run of backslashes does not escape the substitution" 1 'not captured in a variable assignment' -- \
  "$CS" "$TMP/bad_even_backslashes.sh"

# Round 6: containment is not capture. The substitution has to ANSWER with the call.
probe bad_not_answered <<'EOF'
TMP=$(mktemp -d /tmp/leak.XXXXXX >/dev/null; printf '%s\n' /tmp)
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
echo "$TMP"
EOF
expect "a substitution that holds the call but answers with something else is refused" 1 \
  'not captured in a variable assignment' -- "$CS" "$TMP/bad_not_answered.sh"

# --- the default sweep's scope --------------------------------------------------------------
# With no arguments the guard reads every `*/scripts/*.sh` and `scripts/*.sh` in its checkout.
# Exercised against scratch checkouts: what has to be pinned is that a file in a scripts
# directory nobody has written yet is read at all.

# scratch_tree NAME: a scratch checkout with the guard installed where it lives here, plus both
# files its exclusion list names (the guard refuses a sweep whose list names a file that is not
# there) and one clean script elsewhere, so a tree that passes is a tree in which the two
# excluded files -- which carry the refused shapes in their own text -- were really not scanned.
scratch_tree() {
  local d="$TMP/$1"
  mkdir -p "$d/scripts" "$d/ship-pr/scripts"
  cp "$CS" "$d/scripts/check-scratch-dirs.sh"
  cp "$HERE/test-check-scratch-dirs.sh" "$d/scripts/test-check-scratch-dirs.sh"
  chmod +x "$d/scripts/check-scratch-dirs.sh"
  cat >"$d/ship-pr/scripts/pr-review.sh" <<'PRE'
SNAP=$(mktemp -d "${TMPDIR:-/tmp}/pr-review.XXXXXX") || exit 1
SNAP=$(cd "$SNAP" && pwd -P) || exit 1
echo "$SNAP"
PRE
}

# in_tree TREE PATH: a file inside a scratch checkout, written from stdin.
in_tree() {
  mkdir -p "$TMP/$1/$(dirname "$2")"
  cat >"$TMP/$1/$2"
}

scratch_tree sweep_second_dir
in_tree sweep_second_dir other-skill/scripts/stage.sh <<'EOF'
work=$(mktemp -d "${TMPDIR:-/tmp}/stage.XXXXXX") || exit 1
echo "$work"
EOF
expect "an unresolved scratch dir in a second scripts directory is refused by the default sweep" 1 \
  "$REFUSAL" -- "$TMP/sweep_second_dir/scripts/check-scratch-dirs.sh"

scratch_tree sweep_second_dir_ok
in_tree sweep_second_dir_ok other-skill/scripts/stage.sh <<'EOF'
work=$(mktemp -d "${TMPDIR:-/tmp}/stage.XXXXXX") || exit 1
work=$(cd "$work" && pwd -P) || exit 1
echo "$work"
EOF
expect "a second scripts directory that resolves its scratch dir passes the default sweep" 0 \
  "$CLEAN" -- "$TMP/sweep_second_dir_ok/scripts/check-scratch-dirs.sh"

# Round 4: the hooks are in the lint job's file list, so they are in this sweep's. The first
# `mktemp -d` added to one of them must not need a line here to be judged.
scratch_tree sweep_hooks
in_tree sweep_hooks ship-pr/hooks/ship-pr-nudge.sh <<'EOF'
state=$(mktemp -d "${TMPDIR:-/tmp}/nudge.XXXXXX") || exit 1
echo "$state"
EOF
expect "an unresolved scratch dir in ship-pr/hooks is refused by the default sweep" 1 \
  "$REFUSAL" -- "$TMP/sweep_hooks/scripts/check-scratch-dirs.sh"

scratch_tree sweep_top_level
in_tree sweep_top_level scripts/check-scratch-stamps.sh <<'EOF'
d=$(mktemp -d "/tmp/stamps.XXXXXX") || exit 1
echo "$d"
EOF
expect "an unresolved scratch dir in the top-level scripts directory is refused by the default sweep" 1 \
  "$REFUSAL" -- "$TMP/sweep_top_level/scripts/check-scratch-dirs.sh"

# GitHub Actions resolves an `::error file=` against the workspace root, so the absolute path the
# default sweep builds from ROOT would anchor the refusal to no file in the diff.
scratch_tree sweep_annotation
in_tree sweep_annotation other-skill/scripts/stage.sh <<'EOF'
work=$(mktemp -d "${TMPDIR:-/tmp}/stage.XXXXXX") || exit 1
echo "$work"
EOF
expect "a default-sweep refusal annotates a repo-relative path" 1 \
  '::error file=other-skill/scripts/stage.sh,line=' -- \
  "$TMP/sweep_annotation/scripts/check-scratch-dirs.sh"
# ...and no absolute spelling may remain, whether instead of the relative one or beside it. Any
# leading `/` is the tell, deliberately broader than a comparison against $TMP: it refuses an
# absolute path from anywhere.
out=$("$TMP/sweep_annotation/scripts/check-scratch-dirs.sh" 2>&1)
if grep -qE -- '::error file=/' <<<"$out"; then
  ko "a default-sweep refusal must not annotate an absolute path -- $out"
else
  ok "a default-sweep refusal does not annotate an absolute path"
fi

# An explicitly passed file outside the checkout has no relative spelling and keeps the path it
# was given. The needle is a $TMP path compared against the guard's own output, which is vacuous
# unless $TMP is the physical spelling the guard prints -- this suite's own stake in its rule.
out=$("$CS" "$TMP/bad_tmpdir.sh" 2>&1)
if grep -qF -- "::error file=$TMP/bad_tmpdir.sh," <<<"$out"; then
  ok "a file passed by a path outside the checkout is annotated as given"
else
  ko "a file passed by a path outside the checkout must be annotated as given -- $out"
fi

# Fail closed on a scope that has stopped describing the checkout.
scratch_tree sweep_stale_exclusion
rm -f "$TMP/sweep_stale_exclusion/scripts/test-check-scratch-dirs.sh"
expect "an exclusion naming a file that is gone is a usage error" 2 'excluded file not found' -- \
  "$TMP/sweep_stale_exclusion/scripts/check-scratch-dirs.sh"
scratch_tree sweep_empty
rm -f "$TMP/sweep_empty/ship-pr/scripts/pr-review.sh"
expect "a sweep that matches nothing is a usage error, not a pass" 2 'no scripts matched' -- \
  "$TMP/sweep_empty/scripts/check-scratch-dirs.sh"

# --- usage ------------------------------------------------------------------------------------

expect "a missing file is a usage error, not a pass" 2 'no such file' -- \
  "$CS" "$TMP/there-is-no-such-file.sh"
expect "--help prints the header" 0 'symlinks into' -- "$CS" --help

# --- this checkout, and the three heads that rediscovered the fix -----------------------------

expect "this checkout passes the guard" 0 "$CLEAN" -- "$CS"

# The three independent rediscoveries, each with its one resolution line removed: the guard must
# find what each of those authors found by accident, after an assertion had been vacuous for some
# number of heads. If any of these stops failing, the guard has stopped guarding.
witness() {
  local rel="$1" name="$2" src="$TMP/witness-$2"
  if [ ! -f "$ROOT/$rel" ]; then
    ko "the witness $rel is not in this checkout"
    return
  fi
  # The resolution line and nothing else. A removal that matched nothing would leave a probe
  # asserting a refusal the file earns on its own, which proves nothing about the line.
  grep -vE '^[A-Za-z_][A-Za-z0-9_]*=\$\(cd "\$[A-Za-z_][A-Za-z0-9_]*" && pwd -P\)' "$ROOT/$rel" >"$src"
  if [ "$(wc -l <"$src")" -eq "$(wc -l <"$ROOT/$rel")" ]; then
    ko "$name: no resolution line was removed, so this witness proves nothing"
    return
  fi
  expect "$name is refused with its resolution line removed" 1 "$REFUSAL" -- "$CS" "$src"
  expect "...and passes with it" 0 "$CLEAN" -- "$CS" "$ROOT/$rel"
}
witness scripts/test-sync-routines.sh test-sync-routines.sh
witness issue-wave/scripts/test-fleet-worker.sh test-fleet-worker.sh
witness scripts/test-check-jq-shapes.sh test-check-jq-shapes.sh

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
