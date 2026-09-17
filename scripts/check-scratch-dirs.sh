#!/usr/bin/env bash
# Refuse a `mktemp -d` whose result is never resolved physically: the scratch directory a script
# then builds its paths on is spelled the way the environment spells it, and not the way the same
# script spells every other path it computes.
#
# `mktemp -d` answers with the template it was given, expanded. On macOS that template is
# `${TMPDIR:-/tmp}/...` or a literal `/tmp/...`, and both /var and /tmp are symlinks into
# /private — so the answer is `/var/folders/.../x` while `pwd -P` inside that very directory says
# `/private/var/folders/.../x`. Every script in this repository computes its own root with
# `pwd -P` (`ROOT=$(cd "$(dirname "$0")/.." && pwd -P)`, post-merge-cleanup.sh's `canonical_dir`),
# so an unresolved scratch path is a SECOND SPELLING of one directory. An assertion comparing a
# script's output against a path built on it stops matching, and the ones phrased as "this string
# must NOT appear" then pass over anything at all.
#
# The fix is one line, `TMP=$(cd "$TMP" && pwd -P)`, and it was independently rediscovered three
# times — scripts/test-sync-routines.sh, issue-wave/scripts/test-fleet-worker.sh, and
# scripts/test-check-jq-shapes.sh (ludics-lite#206) — each time with its own comment explaining
# the same /var rewrite, because THE ABSENCE OF THE LINE IS NOT VISIBLE IN THE FILE THAT LACKS IT.
# A suite with the resolution and a suite without it read identically at the `mktemp` call; the
# difference shows up only in whether a negative assertion can fail, which is exactly the thing
# nobody checks. That is what makes it a scanner's job rather than a comment's (ludics-lite#208).
#
# THE RULE. For each `mktemp -d` in the file:
#
#   1. Its result must be captured in a variable assignment, `VAR=$(mktemp -d ...)`. A `mktemp -d`
#      whose answer goes somewhere this scanner cannot follow is refused rather than guessed at.
#   2. The variable is then satisfied EITHER by inheritance OR by resolution:
#      - INHERITED: the template's leading component is `$OTHER`/`${OTHER}` for a variable this
#        file already resolved. `TEMP_ROOT=$(canonical_dir "${TMPDIR:-/tmp}")` is resolved, so
#        `mktemp -d "$TEMP_ROOT/..."` needs nothing further: a child of a physical path is
#        physical. `${TMPDIR:-/tmp}` is not a resolved variable, it is the environment's own
#        spelling, and a bare `/tmp` or `/var` prefix is not either.
#      - RESOLVED: the first line after the assignment that mentions the variable is an
#        assignment to it whose value carries `pwd -P` — the house idiom
#        `VAR=$(cd "$VAR" && pwd -P)`. Before FIRST USE, not merely somewhere in the file: a
#        resolution after the directory has already been compared or handed to something is a
#        resolution the earlier line did not get.
#
# A variable counts as resolved when it is assigned from a command substitution carrying `pwd -P`;
# from a function defined in the same file whose body carries `pwd -P` (`canonical_dir`); from a
# `dirname` of a resolved variable (the parent of a physical path is physical); or from a string
# whose leading component is a resolved variable. An inherited `mktemp -d` result is itself
# resolved, so a chain of scratch directories is certified from its root.
#
# WHAT IS NOT A USE. Comments, which discuss the variable precisely where the resolution is being
# explained; and a `trap` line, whose body runs at exit and is written before the resolution in
# two of the three files that already do this right. Everything else is a use.
#
# Files, not just directories: a plain `mktemp` (no -d) is out of scope. Its result is a path
# under the same unresolved root, but nothing here compares one, and widening the rule to cover
# the dozens of snapshot files in post-merge-cleanup.sh would refuse a great deal to catch
# nothing. The day a file path is compared, this is where the rule grows.
#
# Usage: check-scratch-dirs.sh [file...]   (default: every */scripts/*.sh and scripts/*.sh in the
# checkout, less this guard and its fixtures -- see EXCLUDED below)
# Exit 0 when every `mktemp -d` is resolved or inherits one, 1 when one is not, 2 on a usage error.

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd -P)

case "${1:-}" in
-h | --help)
  sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
  ;;
esac

# THE SCOPE, and the exclusions, both as check-jq-shapes.sh has them: the two globs are the lint
# job's own file list in .github/workflows/skill-scripts.yml, less ship-pr/hooks (no mktemp there
# today; add it the day there is one). Two files are excluded by name because both carry text that
# READS as an unresolved `mktemp -d` and is not: this guard's own comments quote the shape it
# refuses, and its fixtures write a scratch probe per shape.
EXCLUDED=(
  scripts/check-scratch-dirs.sh
  scripts/test-check-scratch-dirs.sh
)

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  for f in "$ROOT"/*/scripts/*.sh "$ROOT"/scripts/*.sh; do
    [ -f "$f" ] || continue # an unmatched glob arrives as the pattern itself
    rel=${f#"$ROOT"/}
    excluded=
    for x in "${EXCLUDED[@]}"; do
      if [ "$rel" = "$x" ]; then
        excluded=1
        break
      fi
    done
    [ -n "$excluded" ] || files+=("$f")
  done
  # An exclusion that names nothing is a stale line reading as though it still covered a file.
  for x in "${EXCLUDED[@]}"; do
    if [ ! -f "$ROOT/$x" ]; then
      echo "check-scratch-dirs.sh: excluded file not found: $x -- the list in $0 is stale" >&2
      exit 2
    fi
  done
  # Fail closed rather than print a clean verdict over nothing.
  if [ "${#files[@]}" -eq 0 ]; then
    echo "check-scratch-dirs.sh: no scripts matched */scripts/*.sh or scripts/*.sh under $ROOT" >&2
    exit 2
  fi
fi

rc=0
scanned=0
for f in "${files[@]}"; do
  if [ ! -f "$f" ]; then
    echo "check-scratch-dirs.sh: no such file: $f" >&2
    exit 2
  fi
  scanned=$((scanned + 1))
  # `file=` is resolved by GitHub Actions against the workspace root, so what is PRINTED is made
  # repo-relative while the path is still read absolute.
  display=$f
  case "$f" in "$ROOT"/*) display=${f#"$ROOT"/} ;; esac
  awk -v file="$display" '
    # A `#` that opens a comment: at the start of a word and outside quotes. Without the quote
    # state, the `#` in ${var#x} and in a quoted "#" would truncate the line, and a truncation
    # here can only HIDE a use, never invent one -- so the state machine is kept simple and the
    # error is in the direction of scanning more of the line than less.
    function strip(s,   out, i, ch, q) {
      out = ""; q = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (q == "") {
          if (ch == "#" && (out == "" || substr(out, length(out), 1) ~ /[ \t]/)) return out
          if (ch == "\\") { out = out ch substr(s, i + 1, 1); i++; continue }
          if (ch == "\"" || ch == "'"'"'") q = ch
        } else if (ch == q) q = ""
        out = out ch
      }
      return out
    }
    # Does <s> mention $NAME or ${NAME}?
    function mentions(s, name) {
      return (s ~ ("\\$" name "([^A-Za-z0-9_]|$)")) || (s ~ ("\\$\\{" name "[^A-Za-z0-9_]"))
    }
    # The leading `$VAR` / `${VAR}` of a template, or "" when it does not start with one. A
    # `${TMPDIR:-/tmp}` is deliberately NOT one: the name carries a default, which means the
    # value is whatever the environment said and nothing resolved it.
    function lead_var(t,   m) {
      if (t ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}/) {
        m = substr(t, 3); sub(/\}.*/, "", m); return m
      }
      if (t ~ /^\$[A-Za-z_][A-Za-z0-9_]*/) {
        m = substr(t, 2); sub(/[^A-Za-z0-9_].*/, "", m); return m
      }
      return ""
    }
    function refuse(line, why) {
      printf "::error file=%s,line=%d::%s:%d: %s\n", file, line, file, line, why
      bad = 1
    }
    # Pass 1 collects the functions whose body carries `pwd -P` (canonical_dir and its kin) and
    # every assignment in the file; pass 2 does the scanning. Reading the file twice is what lets
    # a resolver, or a resolved root, defined BELOW its first use still count — post-merge-cleanup.sh
    # sets TEMP_ROOT at the bottom and builds scratch directories on it from functions at the top,
    # and a one-pass scanner reported all three of those as unresolved.
    FNR == NR {
      raw[FNR] = $0
      l = strip($0)
      if (l ~ /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/) {
        fname = l
        sub(/^[ \t]*(function[ \t]+)?/, "", fname)
        sub(/[ \t]*\(\).*/, "", fname)
        infunc = fname
      } else if (infunc != "" && l ~ /^\}/) {
        infunc = ""
      } else if (infunc != "" && l ~ /pwd[ \t]+-P/) {
        resolver[infunc] = 1
      }
      if (l ~ /^[ \t]*(local[ \t]+|export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/) {
        nm = l
        sub(/^[ \t]*(local[ \t]+|export[ \t]+)?/, "", nm)
        val = nm
        sub(/=.*$/, "", nm)
        sub(/^[^=]*=/, "", val)
        an[FNR] = nm
        av[FNR] = val
      }
      last = FNR
      next
    }
    # The fixpoint, once, before the first line of pass 2 is judged: a resolved variable can be
    # named by an assignment anywhere in the file, and a chain (TEMP_ROOT -> a mktemp under it ->
    # a path under that) takes one round per link. Five rounds is more than any chain here; a
    # longer one simply does not certify its tail, which refuses rather than passes.
    FNR == 1 {
      for (round = 0; round < 5; round++)
        for (i = 1; i <= last; i++) {
          if (!(i in an) || (an[i] in resolved)) continue
          if (av[i] ~ /mktemp[ \t]+-d/) {
            tpl = av[i]
            sub(/^.*mktemp[ \t]+-d[ \t]+/, "", tpl)
            sub(/[ \t].*$/, "", tpl)
            gsub(/["'"'"']/, "", tpl)
            lv = lead_var(tpl)
            if (lv != "" && (lv in resolved)) resolved[an[i]] = 1
            continue
          }
          if (value_resolves(av[i])) resolved[an[i]] = 1
        }
    }
    # Is the value of an assignment one that yields a physical path?
    function value_resolves(val,   inner, fn, arg, lv) {
      if (val ~ /pwd[ \t]+-P/) return 1
      if (val ~ /^\$\(/) {
        inner = substr(val, 3)
        sub(/\).*$/, "", inner)
        gsub(/^[ \t]+/, "", inner)
        fn = inner; sub(/[ \t].*$/, "", fn)
        if (fn in resolver) return 1
        if (fn == "dirname") {
          arg = inner; sub(/^dirname[ \t]*/, "", arg); gsub(/["'"'"']/, "", arg)
          lv = lead_var(arg)
          if (lv != "" && (lv in resolved)) return 1
        }
        return 0
      }
      # A plain string whose leading component is a resolved variable.
      inner = val; gsub(/^["'"'"']|["'"'"']$/, "", inner)
      lv = lead_var(inner)
      return (lv != "" && (lv in resolved)) ? 1 : 0
    }
    # The first line after <from> that USES <name>, or 0. Comments and `trap` lines are not uses:
    # a comment is where the resolution gets explained, and a trap body runs at exit, after every
    # resolution in the file.
    function first_use(name, from,   i, l) {
      for (i = from + 1; i <= last; i++) {
        l = strip(raw[i])
        gsub(/^[ \t]+/, "", l)
        if (l == "" || l ~ /^#/) continue
        if (l ~ /^trap[ \t]/) continue
        if (mentions(l, name)) return i
      }
      return 0
    }
    {
      line = strip(raw[FNR])
      if (line !~ /mktemp[ \t]+-d([ \t]|$)/) next
      if (line !~ /^[ \t]*(local[ \t]+|export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=\$\(/) {
        refuse(FNR, "a `mktemp -d` whose result is not captured in a variable assignment: this guard resolves a scratch directory by following the variable it lands in, and cannot follow this one — write it as `VAR=$(mktemp -d ...)` and resolve VAR with `pwd -P`")
        next
      }
      nm = line
      sub(/^[ \t]*(local[ \t]+|export[ \t]+)?/, "", nm)
      sub(/=.*$/, "", nm)
      # The template: the first word after `-d`, unquoted.
      tpl = line
      sub(/^.*mktemp[ \t]+-d[ \t]+/, "", tpl)
      sub(/[ \t].*$/, "", tpl)
      gsub(/["'"'"']/, "", tpl)
      lv = lead_var(tpl)
      if (lv != "" && (lv in resolved)) next   # inherited from a resolved root
      u = first_use(nm, FNR)
      if (u == 0) {
        refuse(FNR, "a `mktemp -d` into $" nm " that is never used and never resolved: if the directory is wanted, resolve it with `" nm "=$(cd \"$" nm "\" && pwd -P)`; if it is not, drop the call")
        next
      }
      l = strip(raw[u])
      gsub(/^[ \t]+/, "", l)
      if (l ~ ("^(local[ \t]+|export[ \t]+)?" nm "=") && l ~ /pwd[ \t]+-P/) next
      refuse(FNR, "a `mktemp -d` into $" nm " whose result is used at line " u " without being resolved physically: mktemp answers with the path as the environment spells it, and on macOS /var and /tmp are symlinks into /private, so this is a second spelling of a directory every `pwd -P` in the repository names differently — an assertion comparing it against a script'"'"'s output stops matching in silence, and a \"must NOT appear\" one then passes over anything. Add `" nm "=$(cd \"$" nm "\" && pwd -P)` directly below, or build the template on a directory this file already resolved")
    }
    END { exit bad ? 1 : 0 }
  ' "$f" "$f" || rc=1
done

if [ "$rc" -ne 0 ]; then
  echo "check-scratch-dirs.sh: refused; see scripts/test-sync-routines.sh for the one-line idiom" >&2
  exit 1
fi
echo "check-scratch-dirs.sh: every mktemp -d is resolved or rooted in a resolved path ($scanned file(s))"
