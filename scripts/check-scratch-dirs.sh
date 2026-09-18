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
# explained; and a `trap` line, whose body runs at exit rather than where it is written, so it
# cannot read the unresolved value. Everything else is a use.
#
# Exempt from the use rule is not exempt from the adjacency one. Only comments and blank lines may
# stand BETWEEN the allocation and its resolution: the resolution has to BE the next code line, and
# a `trap` written there is a code line, so it is what gets picked and the allocation is refused.
# The trap therefore goes above the allocation or below the resolution -- below is the house order,
# where reading order matches running order, and is where all four suites here that resolve a
# scratch directory install it. See README.md's Tests section, "Scratch directories have one house
# shape" (ludics-lite#228, review round 2).
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
    # Q is the open quote, carried ACROSS physical lines: a single-quoted string that runs over a
    # line break makes every line under it literal, and starting each line unquoted read the
    # continuation of a usage string as real code (round 7). SUBDEPTH does the same for an open
    # `$(`, so a call written across lines is still one command.
    function decomment(s,   out, i, ch) {
      out = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        if (Q == "") {
          # A `#` opens a comment at the start of a WORD, and a separator ends a word too
          # (`echo hi;# an example, not a call`, round 8).
          if (ch == "#" && (out == "" || substr(out, length(out), 1) ~ /[ \t;&|(]/)) return out
          if (ch == "\\") { out = out ch substr(s, i + 1, 1); i++; continue }
          if (ch == "\"" || ch == "'"'"'") Q = ch
          # Only a COMMAND SUBSTITUTION continues a line. Counting every `(` collapsed a
          # multiline subshell onto its opening paren, and the logical line then did not begin
          # with the assignment inside it (round 8).
          else if (ch == "$" && substr(s, i + 1, 1) == "(") { SUBDEPTH++; out = out ch; i++; ch = "(" }
          else if (ch == ")" && SUBDEPTH > 0) SUBDEPTH--
        } else if (ch == Q) {
          Q = ""
        } else if (Q == "\"" && ch == "\\") { out = out ch substr(s, i + 1, 1); i++; continue }
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
    function blank_sq(s, q0,   out, i, ch, q) {
      out = ""; q = q0
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
    # Is <v> resolved as seen from line <i>? The enclosing function'"'"'s verdict when that function
    # assigns the name at all, the top level'"'"'s otherwise.
    function scope_resolved(i, v,   sc) {
      if (v == "") return 0
      sc = ((funcof[i] SUBSEP v) in assigns) ? funcof[i] : ""
      return ((sc SUBSEP v) in resolved)
    }
    # The same question for a name read inside a value, where the scope is passed directly.
    function name_resolved(v, sc) {
      if (v == "") return 0
      if (!((sc SUBSEP v) in assigns)) sc = ""
      return ((sc SUBSEP v) in resolved)
    }
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
    # Every COMMAND in <s>, in order: the text is split on the operators that end one, and the
    # first word of each piece (past any variable-assignment prefixes) is its command name. That
    # is what makes `echo run mktemp -d /tmp/x.XXXXXX` a diagnostic rather than an allocation, and
    # what finds BOTH calls in `mktemp -d /tmp/a.XXXXXX; mktemp /tmp/b.XXXXXX` -- a scan that
    # looked for the last textual occurrence saw only the second and let the first leak (round 7).
    # Fills CMD[1..NCMD].
    function commands(s,   i, ch, cur, q, sp, stack, sep) {
      NCMD = 0; cur = ""; q = ""; sp = 0; sep = ""
      for (i = 1; i <= length(s); i++) {
        ch = substr(s, i, 1)
        # A `$(` opens a command even inside a double-quoted string -- `cd "$(mktemp -d ...)"`
        # runs the call, and a splitter that stopped at the quote saw only the `cd`. An ESCAPED
        # one does not: `control "SNAP_DIR=\$(mktemp -d ...)"` hands that text to another shell
        # to run later, and this guard reads the file in front of it.
        if (ch == "$" && substr(s, i + 1, 1) == "(" && !escaped(s, i)) {
          stack[++sp] = q; q = ""
          if (cur != "") { CMD[++NCMD] = cur; SEP[NCMD] = sep }
          cur = ""; sep = "$("; i++
          continue
        }
        if (ch == ")" && sp > 0 && q == "") {
          if (cur != "") { CMD[++NCMD] = cur; SEP[NCMD] = sep }
          cur = ""; sep = ")"; q = stack[sp--]
          continue
        }
        if (q != "") { cur = cur ch; if (ch == q) q = ""; continue }
        if (ch == "\"" || ch == "'"'"'") { q = ch; cur = cur ch; continue }
        if (ch == ";" || ch == "|" || ch == "&" || ch == "(" || ch == ")" || ch == "{" || ch == "}") {
          if (cur != "") { CMD[++NCMD] = cur; SEP[NCMD] = sep }
          # `||` and `&&` remember themselves, so a failure handler can be told from an ordinary
          # next command: `$(mktemp -d ... || exit 1)` is answered by the mktemp on every path
          # that produces a value at all (round 8).
          if ((ch == "|" || ch == "&") && substr(s, i + 1, 1) == ch) { sep = ch ch; i++ }
          else sep = ch
          cur = ""
          continue
        }
        cur = cur ch
      }
      if (cur != "") { CMD[++NCMD] = cur; SEP[NCMD] = sep }
      return NCMD
    }
    # Is <c>'"'"'s command word mktemp (by basename, so /usr/bin/mktemp counts), and if so does the
    # call make a DIRECTORY? `mktemp [OPTION]... [TEMPLATE]`, with `-d`/`--directory` anywhere in
    # the option list, values attached or separate, and redirections skipped wherever they fall --
    # `mktemp 2>/dev/null -d ...` is valid and put the whole option list out of reach (round 7).
    # Sets MT_DIR, MT_TPL and MT_ROOT (the `-p DIR` the template is taken relative to).
    function scan_cmd(c,   w, i, j, ch, n, parts, opts, skip, root_next, name) {
      MT_DIR = 0; MT_TPL = ""; MT_ROOT = ""
      n = split(c, parts, /[ \t]+/)
      i = 1
      while (i <= n && (parts[i] == "" || parts[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) i++  # assignment prefix
      # `command mktemp -d ...` runs mktemp, and so do the `builtin` and `exec` wrappers
      # (round 8); their own options go with them.
      while (i <= n && (parts[i] ~ /^(command|builtin|exec)$/ ||
                        (i > 1 && parts[i-1] ~ /^(command|builtin|exec)$/ && parts[i] ~ /^-/))) i++
      if (i > n) return 0
      name = parts[i]
      sub(/^.*\//, "", name)                    # the basename names the command
      if (name != "mktemp") return 0
      opts = 1
      for (i = i + 1; i <= n; i++) {
        w = parts[i]
        if (w == "") continue
        if (w ~ /^[0-9]*(>>|>|<)/) {            # a redirection and, if it stands alone, its target
          if (w ~ /^[0-9]*(>>|>|<)$/) i++
          continue
        }
        if (skip) { skip = 0; MT_ROOT = root_next ? w : MT_ROOT; root_next = 0; continue }
        if (opts && w == "--") { opts = 0; continue }
        if (opts && w ~ /^--/) {
          if (w ~ /^--directory/) MT_DIR = 1
          if (w ~ /^--tmpdir=/) { MT_ROOT = w; sub(/^--tmpdir=/, "", MT_ROOT) }
          if (w ~ /^--(suffix|tmpdir|p)$/) { skip = 1; root_next = (w == "--tmpdir") }
          continue
        }
        if (opts && w ~ /^-[A-Za-z]/) {
          for (j = 2; j <= length(w); j++) {
            ch = substr(w, j, 1)
            if (ch == "d") { MT_DIR = 1; continue }
            if (ch ~ /[pt]/) {
              if (j == length(w)) { skip = 1; root_next = (ch == "p") }
              else if (ch == "p") MT_ROOT = substr(w, j + 1)
              j = length(w)
              break
            }
          }
          continue
        }
        gsub(/["'"'"']/, "", w)
        MT_TPL = w                              # the first non-option word is the template
        break
      }
      gsub(/["'"'"']/, "", MT_ROOT)
      # `-p DIR` means the template is taken relative to DIR, so THAT is the path the result sits
      # under and the template is one component of it (round 7).
      if (MT_ROOT != "") MT_TPL = MT_ROOT "/" MT_TPL
      return MT_DIR
    }
    # How many command-position `mktemp` calls in <s> make a directory; MT_* describe the last one.
    function dir_calls(s,   i, c, hits) {
      hits = 0
      commands(s)
      for (i = 1; i <= NCMD; i++) { c = CMD[i]; if (scan_cmd(c)) { hits++; DIR_CMD = c } }
      return hits
    }
    function has_mktemp_d(s) { return dir_calls(s) > 0 }
    function template_of(s) { if (!dir_calls(s)) return ""; scan_cmd(DIR_CMD); return MT_TPL }
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
      # A LOGICAL line: physical lines joined while a backslash continues the command, while a
      # quote is still open, or while a `$(` is still unclosed -- bash reads all three as one
      # command, and reading their halves in isolation both missed calls and refused correct ones
      # (rounds 2 and 7). The joined text is attached to the line the command STARTED on, which is
      # the line a refusal should name, and the lines it came from are left empty so nothing is
      # judged twice.
      if (cont != 0) {
        q0 = Q
        code[cont] = code[cont] " " blank_sq(decomment($0), q0)
        code[FNR] = ""
        if ($0 !~ /\\$/ && Q == "" && SUBDEPTH == 0) cont = 0
        next
      }
      q0 = Q
      src = decomment($0)                  # comments gone, quotes still readable
      l = blank_sq(src, q0)
      if ($0 ~ /\\$/) sub(/\\[ \t]*$/, "", l)
      if ($0 ~ /\\$/ || Q != "" || SUBDEPTH != 0) cont = FNR
      code[FNR] = l
      # A heredoc opener: `<<WORD`, `<<-WORD`, `<<"WORD"`, `<<'"'"'WORD'"'"'`. The body starts on the
      # next line and belongs to whatever reads it, not to this file.
      # `<<<word` is a here-string, not a heredoc opener: taking its word for a delimiter swallowed
      # every line after it until a line happened to equal that word (round 7).
      if (src ~ /<<[^<]/ && src ~ /<<-?[ \t]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/) {
        d = src
        sub(/^.*<<(<+[^<]*<<)?-?[ \t]*/, "", d)
        hdtab = (src ~ /<<-/)
        hdquoted = (d ~ /^["'"'"'\\]/)     # only a quoted delimiter disables expansion
        gsub(/^["'"'"'\\]/, "", d)
        sub(/["'"'"'].*$/, "", d)
        # The WHOLE word: a delimiter may carry any character a word may, and truncating
        # `USAGE-TEXT` to `USAGE` left a terminator that could never match -- which swallowed the
        # rest of the file and read as a clean verdict (round 8).
        sub(/[ \t;&|<>()].*$/, "", d)
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
      funcof[FNR] = infunc       # which function a line is inside: the scope its names live in
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
    function value_resolves(val, sc,   inner, fn, arg, lv) {
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
          if (name_resolved(lv, sc) && arg ~ ("^\\$\\{?" lv "\\}?$")) return 1
        }
        return 0
      }
      inner = val; gsub(/^["'"'"']|["'"'"']$/, "", inner)
      return name_resolved(lead_var(inner), sc)
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
    function answers_with_mktemp(h,   tail_cmd, k) {
      if (commands(h) == 0) return 0
      k = NCMD
      while (k > 1 && SEP[k] == "||") k--   # a failure handler supplies nothing on the live path
      tail_cmd = CMD[k]
      if (!scan_cmd(tail_cmd)) return 0
      if (tail_cmd ~ /(^|[ \t])1?>[^&]/) return 0   # the path goes to the redirect, not to the caller
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
    # ...and so is `unset TMP`, which makes the directory unreachable before anything could
    # resolve it: with `set -u` the next line exits and leaks it, without one it canonicalizes
    # whatever `cd ""` lands on (round 7).
    function exports(s, name) {
      return s ~ ("^(export|readonly|declare|typeset|unset)[ \t]+([^ \t]+[ \t]+)*" name "([ \t=]|$)")
    }
    # THE NEXT CODE LINE, and nothing looser. Eight rounds of review found the same defect in a
    # new place each time -- a resolution in the sibling `else` arm, a reassignment or an `unset`
    # in between, an `export` handing the old spelling to a child -- because "somewhere below,
    # before the first use" invites a search, and a search over shell text is a bash interpreter
    # nobody asked for. The house shape is two adjacent lines; every site in this repository is
    # written that way; and a scanner that asks for exactly that has nothing left to approximate,
    # because anything between them, whatever it is, refuses.
    function next_code_line(from,   i, l) {
      for (i = from + 1; i <= last; i++) {
        l = code[i]
        gsub(/^[ \t]+|[ \t]+$/, "", l)
        if (l != "") return i
      }
      return 0
    }
    # Is the mktemp assignment at line <i> resolved by the line below it -- and not used before
    # that? Text only, so it can be computed before the fixpoint that consults it.
    function resolved_below(i,   nm, l, u) {
      nm = an[i]
      if (mentions(tail_of(code[i]), nm) || exports(tail_of(code[i]), nm)) return 0
      u = next_code_line(i)
      if (u == 0) return 0
      # ...and it has to RUN where the allocation did, which adjacency nearly gives on its own:
      # a resolution inside an uncalled function body or a `then` arm is separated from the
      # allocation by the line that opens the block, so it is not the next code line at all. The
      # scope test stays as the belt to that brace.
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
    # tail. Order does not enter into it: the rounds run until the verdicts stop moving, so a chain
    # is certified to whatever depth it has rather than to a depth this file picked in advance.
    FNR == 1 {
      # The assignment table is built HERE and not in pass 1, so that it reads the joined
      # continuation lines rather than their halves.
      for (i = 1; i <= last; i++) {
        l = code[i]
        # The keyword'"'"'s own OPTIONS and the `--` terminator sit between it and the first operand:
        # `readonly -- BASE=${TMPDIR:-/tmp}` and `declare -r BASE=${TMPDIR:-/tmp}` are ordinary
        # declarations that really do overwrite BASE, and a pattern demanding the name immediately
        # after the keyword skipped the whole line (ludics-lite#252 review round 7). This is read on
        # the DISQUALIFYING side only, like the keyword itself: the capture and resolver patterns
        # keep main'"'"'s shape, so an option cannot make a `mktemp -d` line into a capture or a
        # `pwd -P` line into a resolution -- both of which would loosen the guard.
        if (l !~ /^[ \t]*((local|declare|typeset|export|readonly)([ \t]+[-+][A-Za-z-]*)*[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=/) continue
        nm = l
        sub(/^[ \t]*/, "", nm)
        sub(/^((local|declare|typeset|export|readonly)([ \t]+[-+][A-Za-z-]*)*[ \t]+)/, "", nm)
        val = nm
        sub(/=.*$/, "", nm)
        sub(/^[^=]*=/, "", val)
        an[i] = nm
        av[i] = val
        # `readonly NAME=v` takes a LIST: `readonly AUX=x BASE=${TMPDIR:-/tmp}` assigns and freezes
        # both, and reading only the first left the second invisible -- the very defect this change
        # is for, one operand along (ludics-lite#252 review round 6). Every declaration keyword
        # takes the list, so this reads them all rather than singling `readonly` out. Conservative
        # by construction: an operand past the first can DISQUALIFY its name and never certify it,
        # so nothing here has to work out what the value is worth, and the worst a
        # mis-tokenized operand can do is refuse. The line has already had its single-quoted runs
        # blanked, so a `=` inside `'"'"'...'"'"'` is gone; a double-quoted one still reads as an operand,
        # which is the conservative direction.
        rest = val
        while (match(rest, /[ \t]+[A-Za-z_][A-Za-z0-9_]*\+?=/)) {
          ex = substr(rest, RSTART, RLENGTH)
          gsub(/^[ \t]+/, "", ex)
          sub(/\+?=$/, "", ex)
          more[i] = more[i] " " ex
          rest = substr(rest, RSTART + RLENGTH)
        }
      }
      for (i = 1; i <= last; i++) if (i in an) mkok[i] = resolved_below(i)
      # WHICH SCOPE a name is resolved in, rather than one name-global verdict. A short name is
      # reused across functions, so a helper'"'"'s `local BASE=${TMPDIR:-/tmp}` must not un-resolve the
      # global BASE (round 2), an allocation inside that helper must not inherit the global'"'"'s
      # resolution either (round 3), a function-body assignment cannot certify the global, which
      # runs only when something calls it (round 8) -- and a local root that IS resolved must
      # still certify its own child in its own function (round 8 again). All four are the same
      # statement once the verdict is keyed by scope: a name is resolved IN A SCOPE, the scope
      # being the function that assigns it or the top level; a lookup inside a function that
      # assigns the name at all reads that function'"'"'s verdict and never the global one. The
      # two-sided rules stay: only an assignment at control depth 0 can certify, and any assignment
      # can disqualify.
      #
      # THE ROUNDS RUN TO A FIXPOINT, not a fixed count. Each link of a chain of scratch
      # directories is certified by the round that certified the link above it, so a fixed five
      # rounds was a fixed maximum depth: a sixth level was refused as unresolved although every
      # link satisfied the inheritance rule, and the refusal named the deepest line rather than the
      # bound it had hit (ludics-lite#228 review round 4). A pass either adds or removes a
      # `resolved` entry or is the last, and there are only as many entries as assignments, so
      # `nassign` passes cannot be exceeded -- the bound is the file'"'"'s own size, and nothing here
      # has to be more than any chain.
      nassign = 0
      for (i = 1; i <= last; i++) if (i in an) { assigns[funcof[i] SUBSEP an[i]] = 1; nassign++ }
      # This block is entered exactly once: awk reads the file twice, but the pass-1 rule ends in
      # `next`, so `FNR == 1` is reached only on pass 2, with a complete `last`. The clear is not
      # there to undo a previous entry -- there is none -- it keeps the precondition of the loop
      # local, so the empty `resolved` a round starts from is stated here rather than inferred
      # from that `next` far above.
      for (n in resolved) delete resolved[n]
      changed = 1
      for (round = 0; changed && round <= nassign; round++) {
        changed = 0
        for (n in seen) delete seen[n]
        for (n in bad_assign) delete bad_assign[n]
        for (i = 1; i <= last; i++) {
          if (!(i in an)) continue
          key = funcof[i] SUBSEP an[i]
          # `readonly` is read here for what it can take AWAY and never for what it could grant.
          # Reading the keyword at all is what this change is for -- a `readonly` reassignment of a
          # resolved root has to un-resolve it, which is the defect that went unseen -- and
          # `bad_assign` below does that whatever the line'"'"'s shape. Certifying is the other
          # direction, and every attempt to let the keyword do it walked into something this
          # scanner cannot see: the same declaration inside `( ... )` disappears when the subshell
          # exits, and parens move neither `depth` nor `funcof`, so it would certify an outer root
          # that never got one (ludics-lite#252 review round 4). The house rule was already
          # two-sided -- only an assignment at control depth 0 can certify, any assignment can
          # disqualify -- and this is the same asymmetry one keyword further: a file whose root is
          # only ever assigned with `readonly` is refused exactly as it is on main, and a file that
          # merely FREEZES an already-resolved root is refused too, which is the conservative
          # direction. The effect is that reading the keyword can only turn a pass into a refusal.
          if (depth[i] == 0 && code[i] !~ /^[ \t]*readonly[ \t]+/) seen[key] = 1
          # The operand list is disqualified FIRST, ahead of every branch below -- two of which
          # `continue` out of the iteration. A first operand that captures a `mktemp -d` under a
          # resolved root is one of them, and `export AUX=$(mktemp -d "$OTHER/a.XXXXXX")
          # ROOT=${TMPDIR:-/tmp}` then left ROOT certified, because the scan that should have
          # disqualified it sat after the `continue` this line takes (ludics-lite#252 review round
          # 7). What the first operand is worth has nothing to do with what the later ones assign.
          if (i in more) {
            nex = split(more[i], exn, / /)
            for (xi = 1; xi <= nex; xi++)
              if (exn[xi] != "") bad_assign[funcof[i] SUBSEP exn[xi]] = 1
          }
          if (has_mktemp_d(head_of(code[i]))) {
            if (!answers_with_mktemp(head_of(code[i]))) { bad_assign[key] = 1; continue }
            if (scope_resolved(i, lead_var(template_of(head_of(code[i])))) || mkok[i]) continue
            bad_assign[key] = 1
          } else if (!value_resolves(av[i], funcof[i])) {
            bad_assign[key] = 1
          }
        }
        for (n in seen) {
          if (!(n in bad_assign)) { if (!(n in resolved)) { resolved[n] = 1; changed = 1 } }
          else if (n in resolved) { delete resolved[n]; changed = 1 }
        }
      }
    }
    {
      line = code[FNR]
      if (!has_mktemp_d(line)) next
      # `readonly` on the ALLOCATION, refused ahead of the capture check so it gets a message about
      # the freeze rather than the generic one about an uncaptured call. The house shape is two
      # adjacent lines, and `readonly` on the first makes the second impossible: the name is
      # immutable from the moment the directory is made, so bash refuses the resolution with `TMP:
      # readonly variable` and, with no `set -e`, every command below runs on the environment'"'"'s own
      # spelling while the script still exits 0. A template that is already resolved does not save
      # it either -- the same allocation under an earlier freeze of the same name runs mktemp, has
      # its capture refused, and leaks the directory. Whether THAT earlier freeze is in force is not
      # a question a scanner can answer: bash'"'"'s `readonly` inside a helper is global unless the name
      # was localized, a definition above a call is not execution order, `readonly -f` freezes a
      # function and not the variable, `TMP+=` freezes too, and a freeze inside `( ... )` is gone
      # when the subshell exits. So the guard does not ask. It asks for the house shape instead,
      # which is decidable from this line alone: capture plainly, resolve on the line below, and
      # freeze afterwards with a bare `readonly` if the name should be immutable.
      if (line ~ /^[ \t]*readonly[ \t]+/) {
        refuse(FNR, "a `readonly` `mktemp -d`: the allocation freezes the name where the directory is made, so the resolution this guard asks for on the next line cannot run — bash refuses it with a `readonly variable` message and a nonzero status that no `set -e` here is catching, and every command below then uses the environment'"'"'s own spelling. Capture it plainly, resolve it with `VAR=$(CDPATH= cd \"$VAR\" && pwd -P)` on the line below, and freeze it after that with a bare `readonly VAR` if it should be immutable")
        next
      }
      # Captured means captured BY THIS ASSIGNMENT: the call has to sit inside the `$( ... )` the
      # line opens with, and a second one past that substitution is uncaptured whatever the line
      # begins with.
      if (line !~ /^[ \t]*(local[ \t]+|declare[ \t]+|typeset[ \t]+|export[ \t]+)?[A-Za-z_][A-Za-z0-9_]*="?\$\(/ ||
          !has_mktemp_d(head_of(line)) || !answers_with_mktemp(head_of(line))) {
        refuse(FNR, "a `mktemp -d` whose result is not captured in a variable assignment: this guard resolves a scratch directory by following the variable it lands in, and cannot follow this one — write it as `VAR=$(mktemp -d ...)` and resolve VAR with `pwd -P`")
        next
      }
      if (has_mktemp_d(tail_of(line))) {
        refuse(FNR, "a second `mktemp -d` on this line, outside the substitution the assignment captures: its directory is leaked and never resolved — give it a capture and a resolution of its own")
        next
      }
      nm = an[FNR]
      if (scope_resolved(FNR, lead_var(template_of(head_of(line))))) next   # inherited root
      if (mkok[FNR]) next
      if (mentions(tail_of(line), nm) || exports(tail_of(line), nm)) {
        refuse(FNR, "a `mktemp -d` into $" nm " that is used later on its OWN line, before anything could resolve it: the resolution below does not reach a command that already ran with the environment'"'"'s spelling — put `" nm "=$(CDPATH= cd \"$" nm "\" && pwd -P)` between them")
        next
      }
      u = next_code_line(FNR)
      if (u == 0) {
        refuse(FNR, "a `mktemp -d` into $" nm " with nothing after it: if the directory is wanted, resolve it on the next line with `" nm "=$(CDPATH= cd \"$" nm "\" && pwd -P)`; if it is not, drop the call")
        next
      }
      refuse(FNR, "a `mktemp -d` into $" nm " whose next command, at line " u ", is not its resolution: mktemp answers with the path as the environment spells it, and on macOS /var and /tmp are symlinks into /private, so this is a second spelling of a directory every `pwd -P` in the repository names differently — an assertion comparing it against a script'"'"'s output stops matching in silence, and a \"must NOT appear\" one then passes over anything. The guard asks for the two lines adjacent rather than searching for a resolution below: put `" nm "=$(CDPATH= cd \"$" nm "\" && pwd -P)` directly under it, or build the template on a directory this file already resolved")
    }
    END { exit bad ? 1 : 0 }
  ' "$f" "$f" || rc=1
done

if [ "$rc" -ne 0 ]; then
  echo "check-scratch-dirs.sh: refused; see scripts/test-sync-routines.sh for the one-line idiom" >&2
  exit 1
fi
echo "check-scratch-dirs.sh: every mktemp -d is resolved or rooted in a resolved path ($scanned file(s))"
