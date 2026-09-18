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
REFUSAL='is not its resolution'

# --- the shapes that must pass ------------------------------------------------------------------

probe safe_idiom <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
mkdir -p "$TMP/bin"
EOF
expect "the house idiom passes" 0 "$CLEAN" -- "$CS" "$TMP/safe_idiom.sh"

# The resolution is the NEXT command, so the cleanup trap goes under it -- which is also the only
# order in which the trap's own body is the resolved path, should anyone ever write it unquoted.
probe safe_trap_after <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
trap 'rm -rf "$TMP"' EXIT
echo "$TMP"
EOF
expect "the cleanup trap goes under the resolution" 0 "$CLEAN" -- "$CS" "$TMP/safe_trap_after.sh"

# A comment is not a command, so the explanation still fits between the two lines.
probe safe_comment <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
# An unresolved $TMP here and the script's idea of the same directory are spelled differently.
TMP=$(cd "$TMP" && pwd -P) || exit 1
echo "$TMP"
EOF
expect "a comment between the two lines is not a command" 0 "$CLEAN" -- "$CS" "$TMP/safe_comment.sh"

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
# one down. Each link costs a round of the guard's fixpoint, so the chain below and the deeper one
# after it are the same shape at two lengths.
probe safe_chain <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
TMP=$(cd "$TMP" && pwd -P) || exit 1
inner=$(mktemp -d "$TMP/inner.XXXXXX") || exit 1
deeper=$(mktemp -d "$inner/deeper.XXXXXX") || exit 1
echo "$deeper"
EOF
expect "a scratch directory under a resolved scratch directory passes" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_chain.sh"

# ...and the chain has no maximum length. The fixpoint used to run a fixed five rounds, one link
# per round, so a sixth level was refused as unresolved with every link satisfying the inheritance
# rule -- and the refusal named the deepest line rather than the bound it had hit, which is the
# worst way for a limit to be spelled. Six levels is one past the old constant, so this case fails
# the moment a fixed count comes back. No file in the checkout is this deep today; that is why the
# limit could sit here unnoticed, and why the fixture rather than a scanned file has to hold it.
probe safe_chain_deep <<'EOF'
D0=$(CDPATH= cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
D1=$(mktemp -d "$D0/l1.XXXXXX") || exit 1
D2=$(mktemp -d "$D1/l2.XXXXXX") || exit 1
D3=$(mktemp -d "$D2/l3.XXXXXX") || exit 1
D4=$(mktemp -d "$D3/l4.XXXXXX") || exit 1
D5=$(mktemp -d "$D4/l5.XXXXXX") || exit 1
D6=$(mktemp -d "$D5/l6.XXXXXX") || exit 1
echo "$D6"
EOF
expect "a chain deeper than five links passes" 0 "$CLEAN" -- "$CS" "$TMP/safe_chain_deep.sh"

# The other side of the same case: depth is not what certifies a chain, its ROOT is. With the root
# left as the environment's own spelling, no length of chain may pass -- a fixpoint that ran until
# nothing moved would be free to keep looking for a certification that is not there.
probe bad_chain_deep_unrooted <<'EOF'
D0=${TMPDIR:-/tmp}
D1=$(mktemp -d "$D0/l1.XXXXXX") || exit 1
D2=$(mktemp -d "$D1/l2.XXXXXX") || exit 1
D3=$(mktemp -d "$D2/l3.XXXXXX") || exit 1
D4=$(mktemp -d "$D3/l4.XXXXXX") || exit 1
D5=$(mktemp -d "$D4/l5.XXXXXX") || exit 1
D6=$(mktemp -d "$D5/l6.XXXXXX") || exit 1
echo "$D6"
EOF
expect "a deep chain on an unresolved root is still refused" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_chain_deep_unrooted.sh"

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

# Round 4 of #252: `readonly` is read for what it takes AWAY and never for what it could grant, so
# a `readonly` RESOLUTION is not a resolution -- refused here exactly as it is on main. Accepting it
# certified a plain allocation whose assignments bash then refuses outright: under an earlier
# `readonly TMP=old` this file runs mktemp, rejects both assignments, keeps `old`, leaks the
# directory and can still exit 0. The resolver pattern does not check WHICH directory is
# canonicalized either, so `readonly TMP=$(CDPATH= cd / && pwd -P)` read as a resolution too. Both
# are the certifying direction, and the keyword does not get to work in it.
probe bad_readonly_resolution <<'EOF'
readonly TMP=old
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX")
readonly TMP=$(CDPATH= cd "$TMP" && pwd -P)
mkdir -p "$TMP/bin"
EOF
expect "a readonly resolution does not certify the allocation above it" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_readonly_resolution.sh"

# ...and a root that is only ever assigned with `readonly` certifies nothing, which is main's
# verdict too: a declaration inside `( ... )` is gone when the subshell exits, and parens move
# neither `depth` nor `funcof`, so certifying from one would hand an outer allocation a root it
# never got.
probe bad_readonly_root_in_subshell <<'EOF'
(
  readonly BASE=$(CDPATH= cd /tmp && pwd -P)
  echo "$BASE"
)
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a readonly root does not certify, in a subshell or out of one" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_readonly_root_in_subshell.sh"

# Round 5 of #252, and the direction the guard is deliberately conservative in. A reassignment
# inside `( ... )` is discarded when the subshell exits, so disqualifying the outer root over it
# refuses a script that is in fact safe. The guard does it anyway, and has always done it: parens
# move neither `depth` nor `funcof`, so every spelling it can READ disqualifies from inside a
# subshell -- the plain assignment, `export`, `local`, `declare`, `typeset`. `readonly` passed on
# main only because main could not see it at all, and making it behave like its four siblings is
# this change. Exempting it instead would need to know the line is inside a subshell, which is the
# paren tracking this file does not do (`${...}` and `$(...)` would have to be parsed out of the
# count) -- and would have to loosen the other four to stay coherent, turning current refusals into
# passes in the dangerous direction. The cost is one refusal of a safe shape whose remedy is the
# line the guard wants anyway: resolve the allocation underneath it. This case pins the uniformity
# so the asymmetry cannot come back by accident.
probe bad_subshell_reassignment_uniform <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
(
  readonly BASE=${TMPDIR:-/tmp}
  echo "$BASE"
)
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a readonly reassignment in a subshell disqualifies, as every other spelling does" 1 \
  "$REFUSAL" -- "$CS" "$TMP/bad_subshell_reassignment_uniform.sh"

probe bad_subshell_reassignment_plain <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
(
  export BASE=${TMPDIR:-/tmp}
  echo "$BASE"
)
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "...which is what export already did, here as the control for that claim" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_subshell_reassignment_plain.sh"

# Round 6 of #252: `readonly NAME=v` takes a LIST, and reading only the first operand left the
# second invisible -- this change's own defect, one operand along. `readonly AUX=x
# BASE=${TMPDIR:-/tmp}` really does overwrite and freeze BASE, and the file below passed with a
# certified BASE while printing a `/var/...` path at runtime. Every declaration keyword takes the
# list, so all of them are read rather than `readonly` singled out; the `export` spelling is here
# as the control for that, and it is a shape main passes too.
probe bad_multi_operand_readonly <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
readonly AUX=x BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a later operand of a readonly list disqualifies its own name" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_multi_operand_readonly.sh"

probe bad_multi_operand_export <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
export AUX=x BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "...and so does one of an export list, which is the same rule not singling readonly out" 1 \
  "$REFUSAL" -- "$CS" "$TMP/bad_multi_operand_export.sh"

# ...while an operand list that touches no root is ordinary code and stays passing. The repository
# writes `local a="$1" b="$2"` some forty times, and a rule that disqualified on sight of a list
# rather than on the NAMES in it would have refused a great deal of correct shell.
probe safe_multi_operand_unrelated <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
helper() {
  local checkout="$1" value="$2" rest
  rest="$checkout$value"
  echo "$rest"
}
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "an operand list that names no root is left alone" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_multi_operand_unrelated.sh"

# Round 7 of #252: the keyword's own OPTIONS and the `--` terminator sit between it and the first
# operand. `readonly -- BASE=...` and `declare -r BASE=...` are ordinary declarations that really do
# overwrite BASE, and a pattern demanding the name immediately after the keyword skipped the whole
# line. Read on the disqualifying side only: the capture and resolver patterns keep main's shape, so
# an option cannot turn a `mktemp -d` line into a capture or a `pwd -P` line into a resolution.
probe bad_option_terminator <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
readonly -- BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a -- terminator does not hide the assignment behind it" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_option_terminator.sh"

probe bad_declare_r <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
declare -r BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "an attribute flag does not hide the assignment behind it" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_declare_r.sh"

# ...and the operand list is disqualified BEFORE the branches that `continue`. A first operand that
# captures a `mktemp -d` under a resolved root is one of them, and the later operand was left
# certified because the scan sat after that `continue`.
probe bad_list_after_capture <<'EOF'
OTHER=$(CDPATH= cd /tmp && pwd -P) || exit 1
ROOT=$(CDPATH= cd /tmp && pwd -P) || exit 1
export AUX=$(mktemp -d "$OTHER/a.XXXXXX") ROOT=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$ROOT/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a later operand is disqualified even when the first one captured cleanly" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_list_after_capture.sh"

# ...while an option list with no assignment on it is not an assignment. `declare -p` and
# `readonly -f name` name no variable value, and reading them as one would refuse working code.
probe safe_option_without_assignment <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
helper() { :; }
readonly -f helper
declare -p BASE >/dev/null
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "an option list with no assignment on it is not an assignment" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_option_without_assignment.sh"

# Round 8 of #252: reading options (round 7) let an OPTION-BEARING declaration into the table, and
# certifying from one assumes the option mode assigns. `declare -p` does not: it DISPLAYS each
# name, so bash reports the expanded `BASE=/private/tmp` as a name it cannot find, BASE keeps
# whatever it inherited, and the guard certified it anyway -- which main refuses, since main never
# saw the line at all. Which modes assign is a table of every option of five builtins, and the
# wrong entry certifies a root that was never set; so an option on the line means the line can take
# a name away and never hand one over. Round 4's asymmetry, one axis over.
probe bad_option_mode_certifies <<'EOF'
declare -p BASE=$(cd /tmp && pwd -P)
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "an option-bearing declaration does not certify a root" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_option_mode_certifies.sh"

# ...the same line without the flag does certify, which is what keeps the rule about OPTIONS rather
# than about the keyword: a plain `declare BASE=$(... pwd -P)` assigns, and is the control for the
# refusal above.
probe safe_declare_root_no_option <<'EOF'
declare BASE=$(CDPATH= cd /tmp && pwd -P)
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a plain declare root still certifies" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_declare_root_no_option.sh"

# ...and an option-bearing declaration still DISQUALIFIES, which is the half round 7 added: the two
# directions are read differently on purpose.
probe bad_option_mode_disqualifies <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
declare -r BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "...while it still disqualifies, which is the asymmetry" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_option_mode_disqualifies.sh"

# Round 9 of #252: `NAME+=v` appends and is an assignment like any other. `readonly BASE+=/../var`
# turns a certified root into `/tmp/../var`, which no `pwd -P` in this repository spells that way.
# The later-operand scan read `+=` from the start; the first operand did not, so whether the line
# counted as an assignment depended on WHICH operand carried the append.
probe bad_append_first_operand <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
readonly BASE+=/../var
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "an append in the first operand disqualifies the root it rewrites" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_append_first_operand.sh"

# ...and a later operand is an assignment IN ITS SCOPE, not merely a bad one. `assigns` is what
# `scope_resolved` reads to decide whether a function has its own binding for a name; a later
# operand that was only ever marked bad left the function without one, so a lookup inside it fell
# back to the resolved GLOBAL and the allocation under the shadowing local passed. The
# single-operand spelling below was refused all along, and is the control for that.
probe bad_local_list_shadow <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
helper() {
  local AUX=x BASE=${TMPDIR:-/tmp}
  TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
  echo "$AUX $TMP"
}
helper
EOF
expect "a later operand shadows in its own scope, as the single-operand form already did" 1 \
  "$REFUSAL" -- "$CS" "$TMP/bad_local_list_shadow.sh"

probe bad_local_single_shadow <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
helper() {
  local BASE=${TMPDIR:-/tmp}
  TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
  echo "$TMP"
}
helper
EOF
expect "...the single-operand spelling, which is the control for that claim" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_local_single_shadow.sh"

# Round 10 of #252: an option-bearing assignment is purely DISQUALIFYING, which is round 8's rule
# finished. Round 8 stopped such a line certifying, because an option decides whether the mode
# assigns at all; the same ignorance says it cannot be trusted to leave a resolved root alone,
# because an option also decides what the stored value IS. `declare -l` lowercases it (bash 4+, so
# the Ubuntu leg of CI is where this bites and not the 3.2 one), `-u` uppercases, `-i` makes it
# arithmetic -- and a lowercased path on a case-insensitive or symlinked tree is exactly the alias
# this guard refuses. The value resolves on its face, so `bad_assign` stayed clear and the root
# above survived.
probe bad_option_transforms_value <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
declare -l BASE=$(CDPATH= cd /tmp && pwd -P)
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "an option-bearing assignment disqualifies even when its value looks resolved" 1 \
  "$REFUSAL" -- "$CS" "$TMP/bad_option_transforms_value.sh"

# ...and a DOUBLE-quoted operand is the same assignment, since quote removal happens before the
# builtin sees it. Read here, where it only ever adds a name to disqualify. (The single-quoted
# spelling is NOT read -- `blank_sq` has replaced its contents with `x` by then, which is what keeps
# a `mktemp -d` inside a usage string from being a call; see the PR body.)
probe bad_quoted_operand <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
readonly "BASE=/var"
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a double-quoted operand is the same assignment" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_quoted_operand.sh"

# Round 11 of #252: ...in every operand position, not only the first. Round 10 taught the first
# operand to read a double quote and left the list scan behind it, so whether the quote hid the
# assignment depended on WHICH operand carried it -- the same split round 9 found for `+=`.
probe bad_quoted_list_operand <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
readonly AUX=x "BASE=/var"
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a double-quoted operand is read in the list too, not only first" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_quoted_list_operand.sh"

# ...while the quoted text the blanking exists to protect is still data: a usage string naming the
# idiom is not an allocation, whatever keyword precedes it.
probe safe_quoted_usage_after_readonly <<'EOF'
readonly USAGE='write it as TMP=$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX")'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$USAGE $TMP"
EOF
expect "a usage string in a readonly constant is still data" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_quoted_usage_after_readonly.sh"

# Round 3 of #252: and the guard does NOT try to work out whether an earlier `readonly` is in
# force, which is why these two pass. `readonly -f TMP` freezes a FUNCTION named TMP and leaves the
# variable alone, and a freeze inside `( ... )` is gone when the subshell exits; both files run
# correctly, and a scanner that read either as a freeze would refuse working code.
probe safe_readonly_f <<'EOF'
BASE=$(CDPATH= cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
TMP() { :; }
readonly -f TMP
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "readonly -f freezes a function, not the variable" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_readonly_f.sh"

probe safe_readonly_in_subshell <<'EOF'
BASE=$(CDPATH= cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
(
  readonly TMP=old
  echo "$TMP"
)
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a freeze inside a subshell does not outlive it" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_readonly_in_subshell.sh"

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

# Round 7, the false-refusal half: five ordinary spellings the line-shaped reader got wrong.
probe safe_multiline_forms <<'EOF'
printf '%s\n' 'usage:
  TMP=$(mktemp -d /tmp/example.XXXXXX)   # not code: the quote is still open'
TMP=$(
  mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX"
) || exit 1
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
echo "a directory is made with mktemp -d, then resolved" <<<"$TMP"
echo "$TMP"
EOF
expect "an open quote, a multiline substitution and a here-string are read as bash reads them" 0 \
  "$CLEAN" -- "$CS" "$TMP/safe_multiline_forms.sh"

# A `mktemp -d` that is an ARGUMENT to another command is a diagnostic, not an allocation.
probe safe_not_command_position <<'EOF'
echo To create a directory, run mktemp -d /tmp/example.XXXXXX
EOF
expect "a mktemp -d that is not the command word is not a call" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_not_command_position.sh"

# `-p DIR` puts the result one component below DIR, so a resolved DIR certifies it by the guard's
# own inheritance rule.
probe safe_p_root_inherits <<'EOF'
BASE=$(CDPATH= cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
TMP=$(mktemp -p "$BASE" -d probe.XXXXXX) || exit 1
echo "$TMP"
EOF
expect "a -p DIR under a resolved root inherits it" 0 "$CLEAN" -- "$CS" "$TMP/safe_p_root_inherits.sh"

# A redirection between the command name and its options does not hide them.
probe safe_redirect_before_options <<'EOF'
TMP=$(mktemp 2>/dev/null -d "${TMPDIR:-/tmp}/probe.XXXXXX") || exit 1
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
echo "$TMP"
EOF
expect "a redirection before the options does not hide them" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_redirect_before_options.sh"

# An ESCAPED substitution opens no command here: `control "SNAP_DIR=\$(mktemp -d ...)"` is shell
# source this file hands to another shell to run later, which is a file this guard has not been
# asked about. (ludics-lite#195's new case in test-pr-review-lib.sh is exactly this shape.)
probe safe_escaped_probe_source <<'EOF'
control "SNAP_DIR=\$(mktemp -d \"$root/snap.XXXXXX\")" \
  'printf "snap=%s\n" "$SNAP_DIR"'
EOF
expect "an escaped substitution in probe source is not a call here" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_escaped_probe_source.sh"

# Round 8, the false-refusal half: a multiline subshell, a `||` failure handler inside the
# capture, and a `#` comment opened right after a separator.
probe safe_subshell_and_handler <<'EOF'
(
  TMP=$(mktemp -d /tmp/probe.XXXXXX || exit 1) || exit 1
  TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
  echo "$TMP"
)
echo done;# an example, not a call: mktemp -d /tmp/probe.XXXXXX
EOF
expect "a subshell, a || handler inside the capture, and a comment after a separator" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_subshell_and_handler.sh"

# A resolved local root certifies its child inside the same function.
probe safe_local_root <<'EOF'
work() {
  local BASE TMP
  BASE=$(CDPATH= cd /tmp && pwd -P) || return 1
  TMP=$(mktemp -d "$BASE/probe.XXXXXX") || return 1
  echo "$TMP"
}
EOF
expect "a resolved local root certifies its child in the same function" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_local_root.sh"

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
expect "...and the refusal names the line that should have resolved it" 1 "at line 2, is not its resolution" -- \
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
expect "a mktemp -d with nothing after it is refused" 1 'with nothing after it' -- \
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

# ...and the reassignment that un-resolves it can carry a declaration keyword. `readonly` was
# missing from the alternation the assignment table and `resolved_below` spell, so this line was
# not an assignment to the guard at all: it read the certified BASE above, never saw the spelling
# that replaces it, and passed a root holding the environment's own /var path by the time mktemp
# ran. The file is legal bash and it runs -- a plain assignment followed by a `readonly` one is
# fine, and only a THIRD assignment would error -- so nothing else was going to catch it.
probe bad_readonly_reassignment <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
readonly BASE=${TMPDIR:-/tmp}
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "a readonly reassignment un-resolves the root it overwrites" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_readonly_reassignment.sh"

# ...and the same file without that line is the control: the root above certifies its child, so
# the refusal above is the `readonly` line and nothing else about the shape.
probe safe_readonly_control <<'EOF'
BASE=$(CDPATH= cd /tmp && pwd -P) || exit 1
TMP=$(mktemp -d "$BASE/x.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "the same file without the readonly line passes" 0 "$CLEAN" -- \
  "$CS" "$TMP/safe_readonly_control.sh"

# Rounds 1-3 of #252: `readonly` on the ALLOCATION, which is the half of the keyword that reading
# it opened. The house shape is two adjacent lines, and `readonly` on the first makes the second
# impossible -- the name is immutable from the moment the directory is made, so bash refuses the
# resolution with `TMP: readonly variable` and, with no `set -e`, every command below runs on the
# environment's spelling while the script exits 0. Verified: before this rule the first file passed
# the guard and printed a `/var/...` path.
probe bad_readonly_allocation <<'EOF'
readonly TMP=$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX")
TMP=$(CDPATH= cd "$TMP" && pwd -P)
echo "$TMP"
EOF
expect "a readonly allocation cannot be resolved by the line below it" 1 'freezes the name' -- \
  "$CS" "$TMP/bad_readonly_allocation.sh"

# ...and a resolved template does not save it: under an earlier freeze of the same name the call
# still runs, its capture is still refused, and the directory is still leaked (`TMP is: old`). The
# guard refuses on the keyword alone rather than working out whether that earlier freeze is in
# force -- which is not a question a scanner can answer, since bash's `readonly` inside a helper is
# global unless the name was localized, a definition above a call is not execution order,
# `readonly -f` freezes a function and not the variable, `TMP+=` freezes too, and a freeze inside
# `( ... )` is gone when the subshell exits. One textual rule settles every one of those.
probe bad_readonly_allocation_rooted <<'EOF'
BASE=$(CDPATH= cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
readonly TMP=old
readonly TMP=$(mktemp -d "$BASE/x.XXXXXX")
echo "$TMP"
EOF
expect "a readonly allocation is refused even over a resolved root" 1 'freezes the name' -- \
  "$CS" "$TMP/bad_readonly_allocation_rooted.sh"

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

# Round 7, the missed-detection half.
probe bad_redirect_before_options <<'EOF'
TMP=$(mktemp 2>/dev/null -d "${TMPDIR:-/tmp}/probe.XXXXXX")
echo "$TMP"
EOF
expect "an unresolved call with a redirection before its options is still refused" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_redirect_before_options.sh"

# A later plain `mktemp` must not hide an earlier `mktemp -d`.
probe bad_two_calls <<'EOF'
mktemp -d /tmp/leak.XXXXXX; mktemp /tmp/file.XXXXXX
EOF
expect "a plain mktemp behind a mktemp -d does not hide it" 1 'not captured in a variable assignment' -- \
  "$CS" "$TMP/bad_two_calls.sh"

# An assignment inside a function body runs only when something calls the function.
probe bad_resolver_in_uncalled_function <<'EOF'
BASE=${BASE:-/tmp}
normalize() {
  BASE=$(CDPATH= cd /tmp && pwd -P)
}
TMP=$(mktemp -d "$BASE/probe.XXXXXX") || exit 1
echo "$TMP"
EOF
expect "an assignment in an uncalled function does not certify the global" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_resolver_in_uncalled_function.sh"

# `unset` makes the directory unreachable before the resolution can run.
probe bad_unset_before_resolution <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX") || exit 1
unset TMP
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
EOF
expect "an unset before the resolution is a use" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_unset_before_resolution.sh"

# Round 8: what adjacency buys. A resolution in the sibling `else` arm has the same function and
# the same numeric depth as the allocation, so depth alone could not tell them apart -- and it
# cannot run on the path that made the directory.
probe bad_else_arm_resolution <<'EOF'
if [ -n "${WANT:-}" ]; then
  TMP=$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX") || exit 1
else
  TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
fi
echo "$TMP"
EOF
expect "a resolution in the sibling else arm is not the next command" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_else_arm_resolution.sh"

# ...and a plain reassignment between them, which mentions nothing and so was invisible to a
# use-scan, is simply not the resolution.
probe bad_reassignment_between <<'EOF'
TMP=$(mktemp -d "${TMPDIR:-/tmp}/probe.XXXXXX") || exit 1
TMP=/tmp
TMP=$(CDPATH= cd "$TMP" && pwd -P) || exit 1
EOF
expect "a reassignment between the two lines is not the resolution" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_reassignment_between.sh"

# Round 8: a delimiter is a whole word. Truncating it left a terminator that could never match,
# and everything after it read as heredoc data -- a clean verdict over an unscanned file.
probe bad_after_hyphenated_heredoc <<'OUTER'
usage() {
  cat <<'USAGE-TEXT'
usage: thing [--list]
USAGE-TEXT
}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/suite.XXXXXX") || exit 1
mkdir -p "$TMP/bin"
OUTER
expect "a hyphenated heredoc delimiter does not swallow the rest of the file" 1 "$REFUSAL" -- \
  "$CS" "$TMP/bad_after_hyphenated_heredoc.sh"

# Round 8: `command mktemp` runs mktemp.
probe bad_command_wrapper <<'EOF'
TMP=$(command mktemp -d /tmp/probe.XXXXXX)
echo "$TMP"
EOF
expect "a command-wrapped call is the same call" 1 "$REFUSAL" -- "$CS" "$TMP/bad_command_wrapper.sh"

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

# The control for that non-match, and the reason it needs one. A "must NOT appear" check passes
# both when the guard is right and when the check was written so that it could never match, and
# the two are indistinguishable from a green run -- which is how an earlier draft of this one's
# twin over in the jq guard (ludics-lite#197) got away with grepping for a $TMP path the
# /var -> /private/var symlink kept it from ever seeing: it PASSED against a guard whose fix had
# been torn out. The repo-wide resolution sweep that followed was ludics-lite#208. So tear the fix
# out here, in a scratch checkout's COPY of the guard, and prove the grep above can fire: with
# `display` gone the relative spelling is gone with it, and the absolute path is what gets
# annotated. The real scripts/check-scratch-dirs.sh is never touched -- scratch_tree cp'd it into
# the tree, and the rewrite lands on that copy.
scratch_tree annotation_mutant
in_tree annotation_mutant other-skill/scripts/stage.sh <<'EOF'
work=$(mktemp -d "${TMPDIR:-/tmp}/stage.XXXXXX") || exit 1
echo "$work"
EOF
mutant="$TMP/annotation_mutant/scripts/check-scratch-dirs.sh"
# `-i.bak` and a removal, not a bare `-i`: the in-place-without-suffix spelling is GNU-only.
sed -i.bak 's/awk -v file="$display"/awk -v file="$f"/' "$mutant" && rm -f "$mutant.bak"
# A sed that matched nothing would leave the guard whole and hand back a case passing for exactly
# the vacuity it exists to rule out, so the mutation is asserted on the file's text before it runs.
if grep -qF -- 'awk -v file="$f"' "$mutant" && ! grep -qF -- 'awk -v file="$display"' "$mutant"; then
  ok "the annotation guard can be reverted in a scratch copy"
else
  ko "reverting the annotation guard in a scratch copy did not take -- $(grep -n 'awk -v file=' "$mutant")"
fi
out=$("$mutant" 2>&1)
if grep -qF -- "::error file=$TMP/annotation_mutant/other-skill/scripts/stage.sh,line=" <<<"$out" &&
  ! grep -qF -- '::error file=other-skill/scripts/stage.sh,line=' <<<"$out"; then
  ok "a guard without the fix annotates the absolute path, which is what the two cases above catch"
else
  ko "a guard without the fix must annotate the absolute path and not the relative one -- $out"
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
  grep -vE '^[A-Za-z_][A-Za-z0-9_]*=\$\((CDPATH= )?cd "\$[A-Za-z_][A-Za-z0-9_]*" && pwd -P\)' "$ROOT/$rel" >"$src"
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
