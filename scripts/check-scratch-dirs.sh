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
    # THE TEXT THIS SCANNER READS is the file with three things taken out, because none of them is
    # shell this file executes: a comment (it is where the resolution gets explained, and naming
    # the variable there is not a use), the CONTENTS of a single-quoted run, and a heredoc body.
    # The last two are round 1: a usage string `echo '"'"'TMP=$(mktemp -d /tmp/x.XXXXXX)'"'"'`, or the
    # same text in a documentation heredoc, was read as a real allocation and refused — and since
    # this guard judges every head, adding ordinary help text to any scanned script would have
    # turned CI red. Single-quoted contents are blanked rather than deleted, so the STRUCTURE of
    # the line (an assignment outside the quotes, the `trap` in front of them) survives. The cost
    # is that a `mktemp -d` inside `bash -c '"'"'...'"'"'` is out of scope; that is a script being
    # generated or handed to another shell, and this guard reads the file in front of it.
    #
    # Two steps, because the heredoc OPENER has to be read before the blanking: `cat <<'"'"'USAGE'"'"'`
    # names its delimiter inside single quotes, and blanking it first left the scanner waiting for
    # a terminator that never came -- which swallowed the rest of the file, and with it the very
    # mktemp the fixtures were watching for.
    function decomment(s,   out, i, ch, q) {
      out = ""; q = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (q == "") {
          if (ch == "#" && (out == "" || substr(out, length(out), 1) ~ /[ \t]/)) return out
          if (ch == "\\") { out = out ch substr(s, i + 1, 1); i++; continue }
          if (ch == "\"" || ch == "'"'"'") q = ch
        } else if (ch == q) {
          q = ""
        }
        out = out ch
      }
      return out
    }
    # Inside a single-quoted run the character is data: keep the width, lose the meaning. A
    # double-quoted run is kept as it is -- every template in this repository is one.
    function blank_sq(s,   out, i, ch, q) {
      out = ""; q = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (q == "") {
          if (ch == "\\") { out = out ch substr(s, i + 1, 1); i++; continue }
          if (ch == "\"" || ch == "'"'"'") q = ch
          out = out ch
        } else if (ch == q) {
          q = ""
          out = out ch
        } else {
          out = out (q == "'"'"'" ? "x" : ch)
        }
      }
      return out
    }
    # Does <s> mention $NAME or ${NAME}?
    function mentions(s, name) {
      return (s ~ ("\\$" name "([^A-Za-z0-9_]|$)")) || (s ~ ("\\$\\{" name "[^A-Za-z0-9_]"))
    }
    # The leading `$VAR` / `${VAR}` of a template, or "" when it does not start with one. A
    # `${TMPDIR:-/tmp}` is deliberately NOT one: the name carries a default, which means the value
    # is whatever the environment said and nothing resolved it.
    function lead_var(t,   m) {
      if (t ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}/) {
        m = substr(t, 3); sub(/\}.*/, "", m); return m
      }
      if (t ~ /^\$[A-Za-z_][A-Za-z0-9_]*/) {
        m = substr(t, 2); sub(/[^A-Za-z0-9_].*/, "", m); return m
      }
      return ""
    }
    # A `mktemp -d` CALL: the option, then whitespace, end of text, or any character that can end a
    # word in shell. `$(mktemp -d)` takes no template at all and defaults to tmp.XXXXXXXXXX, which
    # is every bit as unresolved as a spelled-out one, and a rule that demanded whitespace after
    # the `-d` reported that file clean (round 1).
    function has_mktemp_d(s) { return s ~ /mktemp[ \t]+-d([ \t)|&;<>"'"'"']|$)/ }
    # Its template: the first word after `-d`, unquoted; "" when there is none.
    function template_of(s,   t) {
      t = s
      if (t !~ /mktemp[ \t]+-d[ \t]+[^ \t)|&;<>]/) return ""
      sub(/^.*mktemp[ \t]+-d[ \t]+/, "", t)
      sub(/[ \t].*$/, "", t)
      gsub(/["'"'"']/, "", t)
      return t
    }
    function refuse(line, why) {
      printf "::error file=%s,line=%d::%s:%d: %s\n", file, line, file, line, why
      bad = 1
    }
    # Pass 1 collects the code text of every line, the functions whose body carries `pwd -P`
    # (canonical_dir and its kin), and every assignment. Pass 2 does the scanning. Reading the
    # file twice is what lets a resolver, or a resolved root, defined BELOW its first use still
    # count -- post-merge-cleanup.sh sets TEMP_ROOT at the bottom and builds scratch directories
    # on it from functions at the top, and a one-pass scanner reported all three as unresolved.
    FNR == NR {
      last = FNR
      raw[FNR] = $0
      if (hd != "") {                      # inside a heredoc body: data, not code
        if ($0 == hd || (hdtab && $0 ~ ("^[ \t]*" hd "$"))) hd = ""
        code[FNR] = ""
        next
      }
      src = decomment($0)                  # comments gone, quotes still readable
      l = blank_sq(src)
      code[FNR] = l
      # A heredoc opener: `<<WORD`, `<<-WORD`, `<<"WORD"`, `<<'"'"'WORD'"'"'`. The body starts on the
      # next line and belongs to whatever reads it, not to this file.
      if (src ~ /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/) {
        d = src
        sub(/^.*<<-?[ \t]*/, "", d)
        hdtab = (src ~ /<<-/)
        gsub(/^["'"'"']/, "", d)
        sub(/["'"'"'].*$/, "", d)
        sub(/[^A-Za-z0-9_].*$/, "", d)
        if (d != "") hd = d
      }
      if (l ~ /^[ \t]*(local[ \t]+|export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/) {
        nm = l
        sub(/^[ \t]*(local[ \t]+|export[ \t]+)?/, "", nm)
        val = nm
        sub(/=.*$/, "", nm)
        sub(/^[^=]*=/, "", val)
        an[FNR] = nm
        av[FNR] = val
        count[nm]++
      }
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
      next
    }
    # Does the value of an ordinary assignment yield a physical path?
    function value_resolves(val,   inner, fn, arg, lv) {
      if (val ~ /pwd[ \t]+-P/) return 1
      if (val ~ /^\$\(/) {
        inner = substr(val, 3)
        sub(/\).*$/, "", inner)
        gsub(/^[ \t]+/, "", inner)
        fn = inner; sub(/[ \t].*$/, "", fn)
        if (fn in resolver) return 1
        if (fn == "dirname") {             # the parent of a physical path is physical
          arg = inner; sub(/^dirname[ \t]*/, "", arg); gsub(/["'"'"']/, "", arg)
          lv = lead_var(arg)
          if (lv != "" && (lv in resolved)) return 1
        }
        return 0
      }
      inner = val; gsub(/^["'"'"']|["'"'"']$/, "", inner)
      lv = lead_var(inner)
      return (lv != "" && (lv in resolved)) ? 1 : 0
    }
    # The rest of the assignment line, past the `$(...)` the value opens with. A use HERE is a use
    # before the resolution on the next line: `TMP=$(mktemp -d ...); consume "$TMP"` handed the
    # unresolved spelling to consume, and the line-granular first-use scan read it as clean
    # (round 1).
    function tail_of(l,   i, depth, ch, started) {
      depth = 0; started = 0
      for (i = 1; i <= length(l); i++) {
        ch = substr(l, i, 1)
        if (ch == "(") { depth++; started = 1 }
        else if (ch == ")") { depth--; if (started && depth <= 0) return substr(l, i + 1) }
      }
      return ""
    }
    # The first line after <from> that USES <name>, or 0. A `trap` line is not one: its body runs
    # at exit, after every resolution in the file, and two of the three suites that already do
    # this right register their cleanup between the mktemp and the resolution.
    function first_use(name, from,   i, l) {
      for (i = from + 1; i <= last; i++) {
        l = code[i]
        gsub(/^[ \t]+/, "", l)
        if (l == "") continue
        if (l ~ /^trap[ \t]/) continue
        if (mentions(l, name)) return i
      }
      return 0
    }
    # Is the mktemp assignment at line <i> resolved by the line below it -- and not used before
    # that? Text only, so it can be computed before the fixpoint that consults it.
    function resolved_below(i,   nm, l, u) {
      nm = an[i]
      if (mentions(tail_of(code[i]), nm)) return 0
      u = first_use(nm, i)
      if (u == 0) return 0
      l = code[u]
      gsub(/^[ \t]+/, "", l)
      return (l ~ ("^(local[ \t]+|export[ \t]+)?" nm "=") && l ~ /pwd[ \t]+-P/) ? 1 : 0
    }
    # The fixpoint, once, before the first line of pass 2 is judged. A name is resolved only when
    # EVERY assignment to it leaves a physical path: `BASE=$(cd /tmp && pwd -P)` followed by
    # `BASE=${TMPDIR:-/tmp}` is not a resolved BASE, and a name-global set that never looked at the
    # second assignment let a plain reassignment walk a scratch directory past the guard (round 1).
    # A `mktemp -d` assignment counts as leaving one when it inherits a resolved root or is
    # resolved on the line below, which is what lets a CHAIN of scratch directories certify its
    # tail. Order does not enter into it, and five rounds is more than any chain here; a longer one
    # simply does not certify its tail, which refuses rather than passes.
    FNR == 1 {
      for (i = 1; i <= last; i++) if (i in an) mkok[i] = resolved_below(i)
      for (round = 0; round < 5; round++) {
        for (n in seen) delete seen[n]
        for (n in bad_assign) delete bad_assign[n]
        for (i = 1; i <= last; i++) {
          if (!(i in an)) continue
          seen[an[i]] = 1
          if (has_mktemp_d(av[i])) {
            lv = lead_var(template_of(av[i]))
            if ((lv != "" && (lv in resolved)) || mkok[i]) continue
            bad_assign[an[i]] = 1
          } else if (!value_resolves(av[i])) {
            bad_assign[an[i]] = 1
          }
        }
        for (n in seen) if (!(n in bad_assign)) resolved[n] = 1; else delete resolved[n]
      }
    }
    {
      line = code[FNR]
      if (!has_mktemp_d(line)) next
      if (line !~ /^[ \t]*(local[ \t]+|export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=\$\(/) {
        refuse(FNR, "a `mktemp -d` whose result is not captured in a variable assignment: this guard resolves a scratch directory by following the variable it lands in, and cannot follow this one — write it as `VAR=$(mktemp -d ...)` and resolve VAR with `pwd -P`")
        next
      }
      nm = an[FNR]
      lv = lead_var(template_of(line))
      if (lv != "" && (lv in resolved)) next   # inherited from a resolved root
      if (mkok[FNR]) next
      if (mentions(tail_of(line), nm)) {
        refuse(FNR, "a `mktemp -d` into $" nm " that is used later on its OWN line, before anything could resolve it: the resolution below does not reach a command that already ran with the environment'"'"'s spelling — put `" nm "=$(cd \"$" nm "\" && pwd -P)` between them")
        next
      }
      u = first_use(nm, FNR)
      if (u == 0) {
        refuse(FNR, "a `mktemp -d` into $" nm " that is never used and never resolved: if the directory is wanted, resolve it with `" nm "=$(cd \"$" nm "\" && pwd -P)`; if it is not, drop the call")
        next
      }
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
