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
# The fix is one line, `TMP=$(CDPATH= cd "$TMP" && pwd -P)`, and it was independently rediscovered three
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
# Usage: check-scratch-dirs.sh [file...]   (default: every */scripts/*.sh, scripts/*.sh and
# ship-pr/hooks/*.sh in the checkout, less this guard and its fixtures -- see EXCLUDED below)
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
# job's own file list in .github/workflows/skill-scripts.yml, ship-pr/hooks included: the first cut
# left the hooks out because none of them shells out to mktemp today, which is exactly the manual
# scope update this guard exists to make unnecessary -- the first one added there would have been
# read as clean (round 4). Two files are excluded by name because both carry text that
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
  for f in "$ROOT"/*/scripts/*.sh "$ROOT"/scripts/*.sh "$ROOT"/ship-pr/hooks/*.sh; do
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
    echo "check-scratch-dirs.sh: no scripts matched */scripts/*.sh, scripts/*.sh or ship-pr/hooks/*.sh under $ROOT" >&2
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
    # The same for double-quoted runs, used only where a COMMAND is being looked for: `|| bail
    # "mktemp -d failed for $2"` is a message, not a second allocation (round 5). Double quotes
    # are not blanked anywhere else, because every template in this repository is one.
    function blank_dq(s,   out, i, ch, q) {
      out = ""; q = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (q == "") {
          if (ch == "\\") { out = out ch substr(s, i + 1, 1); i++; continue }
          if (ch == "\"") q = ch
          out = out ch
        } else if (ch == q) {
          q = ""
          out = out ch
        } else out = out "x"
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
    # Is the character at <pos> preceded by an odd run of backslashes?
    function escaped(s, pos,   k, c) {
      c = 0
      for (k = pos - 1; k >= 1 && substr(s, k, 1) == "\\"; k--) c++
      return c % 2
    }
    # The contents of every `$( ... )` in <s>, concatenated: what a shell would EXECUTE in a line
    # that is otherwise text.
    function subst_only(s,   out, i, ch, depth, start) {
      out = ""; depth = 0
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        # A backslash-escaped dollar is a literal one: `\\$(mktemp -d ...)` in an unquoted body is
        # emitted as text and runs nothing (round 5) -- but only an ODD run of backslashes escapes
        # it, since each pair is itself an escaped backslash (round 6).
        if (depth == 0 && ch == "$" && substr(s, i + 1, 1) == "(" && !escaped(s, i)) { depth = 1; start = i + 2; i++ }
        else if (depth > 0 && ch == "(") depth++
        else if (depth > 0 && ch == ")") {
          depth--
          if (depth == 0) out = out " " substr(s, start, i - start)
        }
      }
      if (depth > 0) out = out " " substr(s, start)
      return out
    }
    # Does <s> mention $NAME or ${NAME}?
    function mentions(s, name) {
      return (s ~ ("\\$" name "([^A-Za-z0-9_]|$)")) || (s ~ ("\\$\\{" name "[^A-Za-z0-9_]"))
    }
    # The leading `$VAR` / `${VAR}` of a template, or "" when it does not start with one, AND the
    # template names exactly one component below it. A `${TMPDIR:-/tmp}` is deliberately not one:
    # the name carries a default, so the value is whatever the environment said and nothing
    # resolved it. Neither is `$BASE/cache/work.XXXXXX`: the root may be physical while `cache` is
    # a symlink, and then mktemp answers through the link exactly as it does under /var
    # (round 2). The component mktemp itself creates cannot be a link, so one level below a
    # physical root is physical and everything deeper has to be resolved on its own. Every
    # inheriting site in this repository is one level down.
    # The plain variable a string opens with, whatever follows it: `$VAR`, `${VAR}`, or "" when it
    # opens with neither. `${TMPDIR:-/tmp}` is deliberately neither -- the name carries a default,
    # so the value is whatever the environment said and nothing resolved it.
    function var_head(t,   m) {
      if (t ~ /^\$\{[A-Za-z_][A-Za-z0-9_]*\}/) {
        m = substr(t, 3); sub(/\}.*/, "", m); return m
      }
      if (t ~ /^\$[A-Za-z_][A-Za-z0-9_]*/) {
        m = substr(t, 2); sub(/[^A-Za-z0-9_].*/, "", m); return m
      }
      return ""
    }
    # The variable a template may INHERIT its resolution from: var_head, and the template names
    # exactly one component below it. Not `$BASE/cache/work.XXXXXX`: the root may be physical
    # while `cache` is a symlink, and then mktemp answers through the link exactly as it does
    # under /var (round 2). The component mktemp itself creates cannot be a link, so one level
    # below a physical root is physical and everything deeper has to be resolved on its own.
    # Every inheriting site in this repository is one level down.
    function lead_var(t,   m, rest) {
      m = var_head(t)
      if (m == "") return ""
      rest = t
      if (!sub(/^\$\{[A-Za-z_][A-Za-z0-9_]*\}/, "", rest)) sub(/^\$[A-Za-z_][A-Za-z0-9_]*/, "", rest)
      if (rest !~ /^\//) return ""            # `$BASEsomething`, not a path under $BASE
      if (substr(rest, 2) ~ /\//) return ""   # more than one component below the root
      return m
    }
    # A `mktemp` CALL that makes a DIRECTORY, read the way the command documents itself:
    # `mktemp [OPTION]... [TEMPLATE]`, with `-d`/`--directory` anywhere in the option list. The
    # first cut demanded a literal `-d` right after the name, so `mktemp -q -d ...`, `mktemp
    # --directory ...` and a bundled `-qd` were skipped entirely (round 4); and `$(mktemp -d)`
    # takes no template at all, defaulting to tmp.XXXXXXXXXX, which is every bit as unresolved as
    # a spelled-out one (round 1). Sets MT_DIR and MT_TPL; MT_TPL is "" when there is no template.
    function scan_mktemp(s,   rest, w, i, j, c, n, parts, opts, skip) {
      MT_DIR = 0; MT_TPL = ""; skip = 0
      # A leading space, so the "not a word character before it" test has something to match even
      # when the call opens the text: `^` inside an alternation is not anchored by every awk.
      s = " " s
      # `/usr/bin/mktemp` is the same command: the basename is what names it, and a slash before
      # it is a path, not a different word (round 5).
      if (s !~ /(^|[^A-Za-z0-9_.-])mktemp[ \t]/) return 0
      rest = s
      sub(/^.*(^|[^A-Za-z0-9_.-])mktemp[ \t]+/, "", rest)
      # Stop at whatever ends the command; what follows is another command, not an argument.
      sub(/[ \t]*(\)|;|\||&|<|>).*$/, "", rest)
      n = split(rest, parts, /[ \t]+/)
      opts = 1
      for (i = 1; i <= n; i++) {
        w = parts[i]
        if (w == "") continue
        if (opts && w == "--") { opts = 0; continue }
        if (skip) { skip = 0; continue }            # the value of the option before it
        if (opts && w ~ /^--/) {
          if (w ~ /^--directory/) MT_DIR = 1
          # A long option that takes a value and was not given one with `=` takes the next word.
          if (w ~ /^--(suffix|tmpdir|p)$/) skip = 1
          continue
        }
        if (opts && w ~ /^-[A-Za-z]/) {             # short options, bundled or not
          # Letter by letter, because a value can be ATTACHED: `-p/tmp` is -p with its argument,
          # and `-pd` would be -p taking "d" as its value rather than the directory flag
          # (round 6). A flag that takes a value ends the cluster: the rest of the word is its
          # value, or the next word when nothing is left.
          for (j = 2; j <= length(w); j++) {
            c = substr(w, j, 1)
            if (c == "d") { MT_DIR = 1; continue }
            if (c ~ /[pt]/) { if (j == length(w)) skip = 1; j = length(w); break }
          }
          continue
        }
        gsub(/["'"'"']/, "", w)
        MT_TPL = w                                  # the first non-option word is the template
        break
      }
      return MT_DIR
    }
    function has_mktemp_d(s) { return scan_mktemp(s) }
    function template_of(s) { scan_mktemp(s); return MT_TPL }
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
      if (hd != "") {
        # A heredoc body is data -- but only a QUOTED delimiter stops the shell expanding it.
        # With `cat <<EOF`, a `$(mktemp -d ...)` in the body RUNS before cat ever sees the text
        # (round 4), so an unquoted body is reduced to the contents of its command substitutions
        # and those are scanned; everything around them is text and goes.
        if ($0 == hd || (hdtab && $0 ~ ("^[ \t]*" hd "$"))) { hd = ""; code[FNR] = ""; }
        else code[FNR] = hdquoted ? "" : subst_only(blank_sq(decomment($0)))
        funcof[FNR] = infunc
        depth[FNR] = dep
        next
      }
      # A backslash at end of line continues the command, and bash reads the two physical lines as
      # one. Joined here, so the call `TMP=$(mktemp \` / `-d "...")` -- which matches nothing on
      # either line of its own -- is read as what it is (round 2). The continued text is attached
      # to the line the command STARTED on, which is the line a refusal should name, and the lines
      # it came from are left empty so nothing is judged twice.
      if (cont != 0) {
        code[cont] = code[cont] " " blank_sq(decomment($0))
        code[FNR] = ""
        if ($0 !~ /\\$/) cont = 0
        next
      }
      src = decomment($0)                  # comments gone, quotes still readable
      l = blank_sq(src)
      if ($0 ~ /\\$/) { sub(/\\[ \t]*$/, "", l); cont = FNR }
      code[FNR] = l
      # A heredoc opener: `<<WORD`, `<<-WORD`, `<<"WORD"`, `<<'"'"'WORD'"'"'`. The body starts on the
      # next line and belongs to whatever reads it, not to this file.
      if (src ~ /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/) {
        d = src
        sub(/^.*<<-?[ \t]*/, "", d)
        hdtab = (src ~ /<<-/)
        hdquoted = (d ~ /^["'"'"'\\]/)     # only a quoted delimiter disables expansion
        gsub(/^["'"'"'\\]/, "", d)
        sub(/["'"'"'].*$/, "", d)
        sub(/[^A-Za-z0-9_].*$/, "", d)
        if (d != "") hd = d
      }
      if (l ~ /^[ \t]*(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*\(\)/) {
        fname = l
        sub(/^[ \t]*(function[ \t]+)?/, "", fname)
        sub(/[ \t]*\(\).*/, "", fname)
        infunc = fname
      } else if (infunc != "" && l ~ /^\}/) {
        infunc = ""
      } else if (infunc != "") {
        # A resolver is a function whose LAST statement is the idiom, since that is what it
        # returns. Merely CONTAINING a `pwd -P` proves nothing -- `(cd "$1" && pwd -P) >/dev/null`
        # followed by a printf of ${TMPDIR:-/tmp} contains one and answers with the environment
        # spelling (round 4). Every statement resets the verdict; the one standing when the body
        # closes is the one that counts.
        t = l
        gsub(/^[ \t]+|[ \t]+$/, "", t)
        if (t != "") resolver[infunc] = (t ~ /^\((CDPATH=[ \t]+)?cd[ \t].*&&[ \t]*pwd[ \t]+-P[ \t]*\)([ \t]|$)/) ? 1 : 0
      }
      funcof[FNR] = infunc       # which function a line is inside, for the local shadows below
      # Control depth, for the rule that a resolution has to sit where the allocation does.
      # Keywords only: braces would need `${...}` and `$(...)` parsed out of the count, and the
      # `|| { ...; }` tail an allocation is routinely written with is balanced within one
      # statement anyway. A `fi`/`done`/`esac` closing on the same line it opened nets to zero.
      depth[FNR] = dep
      n = split(l, w, /[ \t]+/)
      for (k = 1; k <= n; k++) {
        if (w[k] == "") continue
        # Only a keyword in COMMAND POSITION is one: the first word, or one behind a separator.
        # Splitting on every non-word character instead read the `case` out of
        # `"${TMPDIR:-/tmp}/case.XXXXXX"` and opened a block that never closed.
        if (!(k == 1 || w[k-1] ~ /(;|&&|\|\||\{|^then$|^do$|^else$)$/)) continue
        if (w[k] ~ /^(if|case|for|while|until)$/) dep++
        else if (w[k] ~ /^(fi|esac|done)$/) dep--
      }
      if (dep < 0) dep = 0
      next
    }
    # Does the value of an ordinary assignment yield a physical path? The house idiom and nothing
    # looser: a command substitution that IS `$(cd <where> && pwd -P)`, with whatever error tail
    # follows it. A `pwd -P` anywhere in the value proved nothing -- `BASE=$(pwd -P >/dev/null;
    # printf %s "${TMPDIR:-/tmp}")` leaves the environment spelling and was marked resolved
    # (round 2) -- and a guard that names one idiom in its refusals may as well require it.
    function value_resolves(val,   inner, fn, arg, lv) {
      sub(/^"/, "", val)                       # `VAR="$(...)"` is the same capture as `VAR=$(...)`
      # The substitution has to BE the value, not open it: `$(cd ... && pwd -P)/cache` is a
      # physical root with a component glued on, and that component can be a symlink (round 5).
      if (val ~ /^\$\((CDPATH=[ \t]+)?cd[ \t].*&&[ \t]*pwd[ \t]+-P[ \t]*\)"?[ \t]*($|\|\||&&|;)/) return 1
      # ...and the same anchor for the branch below: `$(canonical_dir "$x")/cache` is a resolver
      # call with a component glued on, which round 5 fixed for the direct idiom only (round 6).
      if (val ~ /^\$\(/ && val ~ /\)"?[ \t]*($|\|\||&&|;)/) {
        inner = substr(val, 3)
        sub(/\).*$/, "", inner)
        gsub(/^[ \t]+/, "", inner)
        fn = inner; sub(/[ \t].*$/, "", fn)
        # `in`, and then the VALUE: an awk assignment of 0 creates the element, so a function
        # whose body reset the verdict to 0 was still "in" the table (round 4, found by its own
        # fixture).
        if ((fn in resolver) && resolver[fn]) return 1
        if (fn == "dirname") {
          # The parent of a physical path is physical -- but only of a path that IS one. A
          # `dirname "$ROOT/cache/file"` answers `$ROOT/cache`, and `cache` can be a symlink
          # (round 4), so the argument must be the resolved variable and nothing more.
          arg = inner; sub(/^dirname[ \t]*/, "", arg); gsub(/["'"'"']/, "", arg)
          gsub(/[ \t]+$/, "", arg)
          lv = var_head(arg)
          if (lv != "" && (lv in resolved) && arg ~ ("^\\$\\{?" lv "\\}?$")) return 1
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
    # ...and its complement: what the assignment'"'"'s own `$( ... )` CAPTURES. An assignment-shaped
    # prefix and a `mktemp -d` somewhere later on the line are two different things --
    # `ROOT=$(pwd -P); mktemp -d /tmp/leaked.XXXXXX` is a resolved ROOT beside a leaked directory,
    # and reading the line as one captured call credited the next line'"'"'s resolution to it
    # (round 5).
    # Does the substitution <h> ANSWER with its mktemp? Containment is not capture: `$(mktemp -d
    # ... >/dev/null; printf %s /tmp)` holds the call and assigns /tmp, leaving the directory
    # unreachable and unresolved (round 6). Same rule as the resolver functions: what a construct
    # returns is its LAST command, and a stdout redirect on that command sends the path elsewhere
    # (`2>/dev/null`, which this repository writes, redirects stderr and is fine).
    function answers_with_mktemp(h,   n, parts, k, tail_cmd) {
      n = split(h, parts, /;/)
      tail_cmd = parts[n]
      if (!has_mktemp_d(blank_dq(tail_cmd))) return 0
      if (tail_cmd ~ /(^|[ \t])1?>[^&]/) return 0
      return 1
    }
    function head_of(l,   i, depth, ch, started, start) {
      depth = 0; started = 0
      for (i = 1; i <= length(l); i++) {
        ch = substr(l, i, 1)
        if (ch == "(") { depth++; if (!started) { started = 1; start = i + 1 } }
        else if (ch == ")") { depth--; if (started && depth <= 0) return substr(l, start, i - start) }
      }
      return started ? substr(l, start) : ""
    }
    # The first line after <from> that USES <name>, or 0. A deferred `trap '"'"'rm -rf "$TMP"'"'"' EXIT` is
    # not a use and needs no rule of its own: its body is single-quoted, so blank_sq already made
    # it data. Skipping the whole trap LINE, as the first cut did, also hid a `trap ... ; consume
    # "$TMP"` beside it -- and hid a DOUBLE-quoted body, whose expansion happens when the trap is
    # registered and is a genuine use of the unresolved spelling (round 2).
    # A bare-name `export TMP` is a use too, and the one that does not look like one: the value
    # goes into the environment of every command after it, so a `consume` two lines down receives
    # the unresolved spelling without any textual expansion for this scanner to see (round 3).
    function exports(s, name) {
      return s ~ ("^(export|readonly|declare|typeset)[ \t]+([^ \t]+[ \t]+)*" name "([ \t=]|$)")
    }
    function first_use(name, from,   i, l) {
      for (i = from + 1; i <= last; i++) {
        l = code[i]
        gsub(/^[ \t]+/, "", l)
        if (l == "") continue
        if (mentions(l, name) || exports(l, name)) return i
      }
      return 0
    }
    # Is the mktemp assignment at line <i> resolved by the line below it -- and not used before
    # that? Text only, so it can be computed before the fixpoint that consults it.
    function resolved_below(i,   nm, l, u) {
      nm = an[i]
      if (mentions(tail_of(code[i]), nm) || exports(tail_of(code[i]), nm)) return 0
      u = first_use(nm, i)
      if (u == 0) return 0
      # ...and it has to RUN where the allocation did. A resolution written inside a function body
      # that nothing has called yet, or inside a branch that may not be taken, is an assignment
      # the commands after the allocation never see (round 4): `TMP=$(mktemp -d ...);
      # normalize() { TMP=$(CDPATH= cd "$TMP" && pwd -P); }; echo "$TMP"` echoes the unresolved spelling.
      if (funcof[u] != funcof[i] || depth[u] != depth[i]) return 0
      l = code[u]
      gsub(/^[ \t]+/, "", l)
      return (l ~ ("^(local[ \t]+|declare[ \t]+|typeset[ \t]+|export[ \t]+)?" nm "=\"?\\$\\((CDPATH=[ \t]+)?cd[ \t].*&&[ \t]*pwd[ \t]+-P[ \t]*\\)\"?[ \t]*($|\\|\\||&&|;)")) ? 1 : 0
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
      # The assignment table is built HERE and not in pass 1, so that it reads the joined
      # continuation lines rather than their halves.
      for (i = 1; i <= last; i++) {
        l = code[i]
        if (l !~ /^[ \t]*(local[ \t]+|declare[ \t]+|typeset[ \t]+|export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/) continue
        nm = l
        sub(/^[ \t]*/, "", nm)
        # A `local`/`declare`/`typeset` assignment belongs to one function'"'"'s scope, and a short name
        # is routinely reused across functions: folding a helper'"'"'s `local BASE=${TMPDIR:-/tmp}` into
        # the global BASE made a correct file fail the mandatory lint job (round 2). It still gets
        # an entry -- the mktemp rules below are about the LINE and apply wherever it is written --
        # but it is left out of the name-global conjunction.
        isloc[i] = (nm ~ /^(local|declare|typeset)[ \t]/) ? 1 : 0
        # A local that SHADOWS a name: inside this function the global'"'"'s resolution says nothing
        # about the value, so nothing there may inherit from it. Leaving locals out of the
        # conjunction (round 2) fixed the false refusal and opened this, its inverse (round 3).
        if (isloc[i]) {
          nmloc = nm
          sub(/^(local|declare|typeset)[ \t]+/, "", nmloc)
          sub(/=.*$/, "", nmloc)
          shadow[funcof[i] SUBSEP nmloc] = 1
        }
        sub(/^(local[ \t]+|declare[ \t]+|typeset[ \t]+|export[ \t]+)/, "", nm)
        val = nm
        sub(/=.*$/, "", nm)
        sub(/^[^=]*=/, "", val)
        an[i] = nm
        av[i] = val
      }
      for (i = 1; i <= last; i++) if (i in an) mkok[i] = resolved_below(i)
      for (round = 0; round < 5; round++) {
        for (n in seen) delete seen[n]
        for (n in bad_assign) delete bad_assign[n]
        for (i = 1; i <= last; i++) {
          if (!(i in an) || isloc[i]) continue
          # An assignment inside a branch may never run, so it cannot CERTIFY a name -- `if false;
          # then BASE=$(cd /tmp && pwd -P); fi` left BASE resolved (round 5). It can still
          # DISQUALIFY one, which is the safe direction: a name assigned the environment spelling
          # anywhere is a name this guard will not certify.
          if (depth[i] == 0) seen[an[i]] = 1
          if (has_mktemp_d(head_of(code[i]))) {
            if (!answers_with_mktemp(head_of(code[i]))) { bad_assign[an[i]] = 1; continue }
            lv = lead_var(template_of(head_of(code[i])))
            if (lv != "" && ((funcof[i] SUBSEP lv) in shadow)) lv = ""
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
      # Captured means captured BY THIS ASSIGNMENT: the call has to sit inside the `$( ... )` the
      # line opens with, and a second one past that substitution is uncaptured whatever the line
      # begins with.
      if (line !~ /^[ \t]*(local[ \t]+|declare[ \t]+|typeset[ \t]+|export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*="?\$\(/ ||
          !has_mktemp_d(head_of(line)) || !answers_with_mktemp(head_of(line))) {
        refuse(FNR, "a `mktemp -d` whose result is not captured in a variable assignment: this guard resolves a scratch directory by following the variable it lands in, and cannot follow this one — write it as `VAR=$(mktemp -d ...)` and resolve VAR with `pwd -P`")
        next
      }
      if (has_mktemp_d(blank_dq(tail_of(line)))) {
        refuse(FNR, "a second `mktemp -d` on this line, outside the substitution the assignment captures: its directory is leaked and never resolved — give it a capture and a resolution of its own")
        next
      }
      nm = an[FNR]
      lv = lead_var(template_of(head_of(line)))
      if (lv != "" && ((funcof[FNR] SUBSEP lv) in shadow)) lv = ""   # a local shadow, not the global
      if (lv != "" && (lv in resolved)) next   # inherited from a resolved root
      if (mkok[FNR]) next
      if (mentions(tail_of(line), nm) || exports(tail_of(line), nm)) {
        refuse(FNR, "a `mktemp -d` into $" nm " that is used later on its OWN line, before anything could resolve it: the resolution below does not reach a command that already ran with the environment'"'"'s spelling — put `" nm "=$(CDPATH= cd \"$" nm "\" && pwd -P)` between them")
        next
      }
      u = first_use(nm, FNR)
      if (u == 0) {
        refuse(FNR, "a `mktemp -d` into $" nm " that is never used and never resolved: if the directory is wanted, resolve it with `" nm "=$(CDPATH= cd \"$" nm "\" && pwd -P)`; if it is not, drop the call")
        next
      }
      refuse(FNR, "a `mktemp -d` into $" nm " whose result is used at line " u " without being resolved physically: mktemp answers with the path as the environment spells it, and on macOS /var and /tmp are symlinks into /private, so this is a second spelling of a directory every `pwd -P` in the repository names differently — an assertion comparing it against a script'"'"'s output stops matching in silence, and a \"must NOT appear\" one then passes over anything. Add `" nm "=$(CDPATH= cd \"$" nm "\" && pwd -P)` directly below, or build the template on a directory this file already resolved")
    }
    END { exit bad ? 1 : 0 }
  ' "$f" "$f" || rc=1
done

if [ "$rc" -ne 0 ]; then
  echo "check-scratch-dirs.sh: refused; see scripts/test-sync-routines.sh for the one-line idiom" >&2
  exit 1
fi
echo "check-scratch-dirs.sh: every mktemp -d is resolved or rooted in a resolved path ($scanned file(s))"
