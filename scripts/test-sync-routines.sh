#!/usr/bin/env bash
# Exercises sync-routines.sh against scratch trees -- no ~/.claude, no desktop app. The script
# resolves both ends from its own location (routines/ beside its scripts/ directory) and from
# $CLAUDE_SCHEDULED_TASKS_DIR, so every case here runs a byte-identical COPY of the script
# inside a scratch checkout: a `pull` case must never be able to write into the real routines/.
#
# What it pins:
#   - the four states status reports (in sync, drift, installed as a symlink, not installed)
#     and the exit code of each;
#   - that push replaces a symlink with a real directory instead of writing THROUGH it, which
#     is the whole reason the script exists (desktop app 1.46388.4 refuses a task file reached
#     through a symlink, quietly), and that a destination reached through a link at any component
#     ABOVE the routine directory is refused too, with the same trees under their real path as
#     the control;
#   - that --dry-run copies nothing, in every mode, and still says what it would do;
#   - the usage exits: an unknown argument is 2, --help prints the header;
#   - that LOCAL_ROUTINES lists exactly the routines/README.md rows whose Kind is
#     `local scheduled task` (ludics-lite#77), with negative controls that show the comparison
#     can fail -- a claim that cannot fail would be worse than no claim;
#   - that the workflow job running this suite carries no `if:`/`needs:`, since the diff
#     classification calls an all-Markdown PR prompt-only and that is the one shape the pin
#     above exists to catch;
#   - that the tracked mode of sync-routines.sh is 755, which a `> tmp && mv` rewrite drops.
#
# Usage: test-sync-routines.sh   (exit 0 all pass, 1 otherwise)

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
SYNC="$HERE/sync-routines.sh"
ROUTINES_README="$ROOT/routines/README.md"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/sync-routines-test.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
# Physical path: the script refuses a destination reached through a symlink at ANY component,
# and on macOS $TMPDIR sits under /var, which is a link to /private/var. Every case below wants
# a clean root, so the symlink cases can put the link where they mean it.
TMP=$(cd "$TMP" && pwd -P) || exit 1

pass=0; fail=0
ok() { pass=$((pass + 1)); echo "PASS: $*"; }
ko() { fail=$((fail + 1)); echo "FAIL: $*"; }
# expect <label> <want-rc> <want-substring> -- <cmd...>; leaves the output in $out, rc in $rc.
expect() {
  local label="$1" want_rc="$2" want="$3"; shift 3; [ "$1" = -- ] && shift
  out=$("$@" 2>&1); rc=$?
  if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -q -- "$want"; then ok "$label"
  else ko "$label (rc=$rc want $want_rc; want /$want/) -- $out"; fi
}

# --- the routines this script claims to sync ---------------------------------------------------
# Read off the assignment rather than by sourcing: the script exits on `-h` and does work at
# top level, so it is not sourceable, and the shape the comment promises is a one-line
# LOCAL_ROUTINES="...".
routines_list_of() { sed -n 's/^LOCAL_ROUTINES="\([^"]*\)"[[:space:]]*$/\1/p' "$1"; }
LOCAL_ROUTINES=$(routines_list_of "$SYNC")
if [ -n "$LOCAL_ROUTINES" ]; then
  ok "sync-routines.sh declares LOCAL_ROUTINES ($LOCAL_ROUTINES)"
else
  ko "no one-line LOCAL_ROUTINES=\"...\" in $SYNC -- every case below would test nothing"
  echo; echo "$pass passed, $fail failed"; exit 1
fi

# --- a scratch checkout, so `pull` cannot reach the real routines/ ------------------------------
# The routine names come from the script's own list: adding a routine must not mean editing a
# scratch tree here. The prompts are stand-ins -- this suite is about the copying, and
# check-prompts.sh is what judges the real prompts.
REPO="$TMP/repo"
mkdir -p "$REPO/scripts"
cp "$SYNC" "$REPO/scripts/sync-routines.sh"
chmod +x "$REPO/scripts/sync-routines.sh"
SR="$REPO/scripts/sync-routines.sh"
cmp -s "$SYNC" "$SR" && ok "the scratch copy of the script is byte-identical to the tracked one" \
  || ko "the scratch copy differs from $SYNC -- the cases below judge the wrong bytes"

# reset_trees: a fresh source checkout and an empty install root before each case.
reset_trees() {
  rm -rf "$REPO/routines" "$TMP/installed"
  mkdir -p "$REPO/routines" "$TMP/installed"
  for r in $LOCAL_ROUTINES; do
    mkdir -p "$REPO/routines/$r"
    printf -- '---\nname: %s\ndescription: scratch prompt for %s\n---\n\nbody v1\n' "$r" "$r" \
      > "$REPO/routines/$r/SKILL.md"
  done
}
install_all() {  # a real, in-sync installation, the way a push leaves one
  for r in $LOCAL_ROUTINES; do
    rm -rf "${TMP:?}/installed/$r"
    cp -R "$REPO/routines/$r" "$TMP/installed/$r"
  done
}
first_routine() { set -- $LOCAL_ROUTINES; echo "$1"; }
R1=$(first_routine)
run_sync() { env CLAUDE_SCHEDULED_TASKS_DIR="$TMP/installed" "$SR" "$@"; }

# --- usage --------------------------------------------------------------------------------------
reset_trees; install_all
expect "an unknown argument is refused with exit 2" 2 "unknown argument: --frobnicate" -- \
  run_sync --frobnicate
printf '%s' "$out" | grep -q -- '--help' \
  && ok "...and points at --help" || ko "the refusal does not mention --help -- $out"

expect "--help prints the header's usage" 0 "sync-routines.sh push" -- run_sync --help
printf '%s' "$out" | grep -q 'symlink' \
  && ok "...including why copies rather than symlinks" || ko "--help drops the symlink lore -- $out"
printf '%s' "$out" | grep -q '^#' \
  && ko "--help leaks the comment markers -- $out" || ok "...with the comment markers stripped"
expect "-h is the same" 0 "Exit codes:" -- run_sync -h

# --- status: the four states --------------------------------------------------------------------
reset_trees; install_all
expect "status on a matching pair exits 0" 0 "all local routines in sync" -- run_sync
printf '%s' "$out" | grep -q "$R1: in sync" \
  && ok "...naming each routine" || ko "status does not name $R1 -- $out"
expect "status is also the default with no argument at all" 0 "in sync" -- run_sync status

reset_trees; install_all
printf 'body v2 -- edited in the installed copy\n' >> "$TMP/installed/$R1/SKILL.md"
expect "status reports drift with exit 1" 1 "$R1: DRIFT" -- run_sync
printf '%s' "$out" | grep -q 'body v2' \
  && ok "...and shows the differing lines" || ko "the drift report carries no diff -- $out"
printf '%s' "$out" | grep -q 'push' \
  && ok "...and names the way out" || ko "the drift report suggests nothing -- $out"

reset_trees
rm -rf "$TMP/installed/$R1"
ln -s "$REPO/routines/$R1" "$TMP/installed/$R1"
install_all_rest() { for r in $LOCAL_ROUTINES; do [ "$r" = "$R1" ] && continue
  rm -rf "${TMP:?}/installed/$r"; cp -R "$REPO/routines/$r" "$TMP/installed/$r"; done; }
install_all_rest
expect "status calls out a symlinked installation with exit 1" 1 "installed as a SYMLINK" -- run_sync
printf '%s' "$out" | grep -q 'the scheduler cannot read it' \
  && ok "...and says the scheduler cannot read it" || ko "no consequence given -- $out"

reset_trees
expect "status reports an uninstalled routine with exit 1" 1 "not installed at" -- run_sync
printf '%s' "$out" | grep -q 'schedule' \
  && ok "...pointing at the \`schedule\` tool, since registration is separate" \
  || ko "the not-installed line does not mention registration -- $out"

# --- push ---------------------------------------------------------------------------------------
reset_trees; install_all
printf 'body v2\n' >> "$REPO/routines/$R1/SKILL.md"
expect "push copies the checkout's prompt over the installed one" 0 "$R1: pushed to" -- run_sync push
grep -q 'body v2' "$TMP/installed/$R1/SKILL.md" \
  && ok "...and the installed copy now carries the edit" \
  || ko "the installed copy was not updated: $(cat "$TMP/installed/$R1/SKILL.md")"
expect "...leaving status clean" 0 "all local routines in sync" -- run_sync

# The case the change exists for: a directory left over from the symlink era.
reset_trees; install_all
rm -rf "$TMP/installed/$R1"
ln -s "$REPO/routines/$R1" "$TMP/installed/$R1"
printf 'body v2\n' >> "$REPO/routines/$R1/SKILL.md"
expect "push replaces a symlinked installation" 0 "symlink replaced with a real copy" -- run_sync push
[ -d "$TMP/installed/$R1" ] && [ ! -L "$TMP/installed/$R1" ] \
  && ok "...with a real directory the scheduler can open" \
  || ko "$TMP/installed/$R1 is still a symlink after push"
# The negative control on the replacement: `ln -sfn` onto a live link is how the old install loop
# wrote INTO the target instead of over the link. Nothing may have appeared inside the source.
[ ! -e "$REPO/routines/$R1/$R1" ] \
  && ok "...and nothing was written through the link into the checkout" \
  || ko "push wrote into the link target: $REPO/routines/$R1/$R1 exists"
grep -q 'body v2' "$TMP/installed/$R1/SKILL.md" \
  && ok "...carrying the checkout's current prompt" || ko "the replacement copy is stale"

reset_trees
expect "push installs a routine that is not there at all" 0 "still unregistered" -- run_sync push
[ -f "$TMP/installed/$R1/SKILL.md" ] \
  && ok "...writing a real file" || ko "nothing was installed at $TMP/installed/$R1"
printf '%s' "$out" | grep -q 'no cron will fire it' \
  && ok "...while warning that a prompt without a registry entry never fires" \
  || ko "push installed silently over a missing registration -- $out"

reset_trees
rm -rf "$TMP/installed"
expect "push creates the scheduled-tasks directory on a box that has none" 0 "still unregistered" -- \
  run_sync push
[ -f "$TMP/installed/$R1/SKILL.md" ] \
  && ok "...and installs into it" || ko "push did not create $TMP/installed"

reset_trees; install_all
rm -rf "$REPO/routines/$R1"
expect "push over a missing source routine exits 1 rather than reporting success" 1 \
  "no such routine" -- run_sync push
printf '%s' "$out" | grep -q 'were not synced' \
  && ok "...and says so in the summary" || ko "the summary claims a clean push -- $out"

# --- pull ---------------------------------------------------------------------------------------
reset_trees; install_all
printf 'body v2 -- written by the routine mid-run\n' >> "$TMP/installed/$R1/SKILL.md"
expect "pull takes an edit made in the installed copy" 0 "$R1: pulled into" -- run_sync pull
grep -q 'mid-run' "$REPO/routines/$R1/SKILL.md" \
  && ok "...into the checkout" || ko "the checkout was not updated: $(cat "$REPO/routines/$R1/SKILL.md")"
printf '%s' "$out" | grep -q 'Nothing is committed' \
  && ok "...and says the commit is still the caller's" || ko "pull does not mention committing -- $out"

reset_trees; install_all
rm -rf "$TMP/installed/$R1"
ln -s "$REPO/routines/$R1" "$TMP/installed/$R1"
expect "pull refuses to read back through a symlink" 1 "nothing to pull" -- run_sync pull
grep -q 'body v1' "$REPO/routines/$R1/SKILL.md" \
  && ok "...leaving the checkout's prompt alone" || ko "pull mangled the source through the link"

reset_trees
expect "pull with nothing installed exits 1" 1 "not installed at" -- run_sync pull

# --- --dry-run copies nothing -------------------------------------------------------------------
reset_trees; install_all
printf 'body v2\n' >> "$REPO/routines/$R1/SKILL.md"
before=$(cat "$TMP/installed/$R1/SKILL.md")
expect "push --dry-run says what it would do" 0 "would push" -- run_sync push --dry-run
[ "$(cat "$TMP/installed/$R1/SKILL.md")" = "$before" ] \
  && ok "...and copies nothing" || ko "push --dry-run wrote to the installed copy"
printf '%s' "$out" | grep -q 'dry run: nothing was copied' \
  && ok "...and does not report routines updated" || ko "the dry run's summary claims work -- $out"
expect "-n is the same flag" 0 "would push" -- run_sync push -n
[ "$(cat "$TMP/installed/$R1/SKILL.md")" = "$before" ] \
  && ok "...and copies nothing either" || ko "push -n wrote to the installed copy"

reset_trees; install_all
printf 'body v2\n' >> "$TMP/installed/$R1/SKILL.md"
src_before=$(cat "$REPO/routines/$R1/SKILL.md")
expect "pull --dry-run copies nothing" 0 "would pull" -- run_sync pull --dry-run
[ "$(cat "$REPO/routines/$R1/SKILL.md")" = "$src_before" ] \
  && ok "...leaving the checkout untouched" || ko "pull --dry-run wrote into the checkout"

reset_trees; install_all
rm -rf "$TMP/installed/$R1"
ln -s "$REPO/routines/$R1" "$TMP/installed/$R1"
expect "push --dry-run over a symlink only says it would replace it" 0 "would replace the symlink" -- \
  run_sync push --dry-run
[ -L "$TMP/installed/$R1" ] \
  && ok "...leaving the symlink in place" || ko "push --dry-run replaced the symlink"

reset_trees
expect "push --dry-run over a missing installation says it would install" 0 "would install" -- \
  run_sync push --dry-run
[ ! -e "$TMP/installed/$R1" ] \
  && ok "...installing nothing" || ko "push --dry-run installed $R1"

# --- a destination reached through a symlink ----------------------------------------------------
# The per-routine check only sees the routine's own directory; the scheduler refuses a task file
# whose path traverses a link at any component, so a symlinked ~/.claude or scheduled-tasks makes
# every $dst a real directory behind a link. Reported "in sync" before this was checked.
reset_trees; install_all
LINKED="$TMP/linked-root"
rm -f "$LINKED"
ln -s "$TMP/installed" "$LINKED"
linked_sync() { env CLAUDE_SCHEDULED_TASKS_DIR="$LINKED" "$SR" "$@"; }

expect "status refuses a destination root that is itself a symlink" 1 "reached through a SYMLINK" -- \
  linked_sync
printf '%s' "$out" | grep -q 'at any component' \
  && ok "...saying the scheduler refuses any component" || ko "no reason given -- $out"
# The negative control on that verdict: the SAME trees reached by their real path are in sync, so
# the exit 1 above is about the link and not about the fixture.
expect "...while the same trees under their real path are in sync" 0 "all local routines in sync" -- \
  run_sync

expect "push refuses to install behind a symlinked root" 1 "refusing to push behind a symlink" -- \
  linked_sync push
# And it refuses before writing: a push that copied first would leave the prompt behind the link.
printf 'body v2\n' >> "$REPO/routines/$R1/SKILL.md"
linked_sync push >/dev/null 2>&1
grep -q 'body v2' "$TMP/installed/$R1/SKILL.md" \
  && ko "the refused push copied anyway" || ok "...copying nothing"
expect "push --dry-run refuses the same way" 1 "refusing to push behind a symlink" -- \
  linked_sync push --dry-run

# A deeper link: the root exists as a real directory, but a component above it is a link.
reset_trees; install_all
mkdir -p "$TMP/deep/real"
rm -f "$TMP/deep/link"
ln -s "$TMP/deep/real" "$TMP/deep/link"
mkdir -p "$TMP/deep/real/tasks"
for r in $LOCAL_ROUTINES; do cp -R "$REPO/routines/$r" "$TMP/deep/real/tasks/$r"; done
expect "status refuses when a component ABOVE the destination is the link" 1 \
  "reached through a SYMLINK" -- env CLAUDE_SCHEDULED_TASKS_DIR="$TMP/deep/link/tasks" "$SR"
printf '%s' "$out" | grep -q "$TMP/deep/link" \
  && ok "...naming the component that is the link" || ko "the refusal does not name the link -- $out"
# The control: the same tree by its real path is in sync, so the refusal is the link's doing.
expect "...while the real path of that same tree is in sync" 0 "all local routines in sync" -- \
  env CLAUDE_SCHEDULED_TASKS_DIR="$TMP/deep/real/tasks" "$SR"

# pull is a read: the files behind the link are real, so it warns and proceeds rather than refusing.
reset_trees; install_all
printf 'body v2 -- written by the routine mid-run\n' >> "$TMP/installed/$R1/SKILL.md"
expect "pull behind a symlinked root warns but proceeds" 0 "pulling anyway" -- linked_sync pull
grep -q 'mid-run' "$REPO/routines/$R1/SKILL.md" \
  && ok "...taking the edit, since the content behind the link is real" \
  || ko "pull behind the link took nothing"

# --- the pin: LOCAL_ROUTINES vs the routines table ----------------------------------------------
# ludics-lite#77: nothing said that the install loop lists exactly the rows whose Kind is `local
# scheduled task`. It is a script list now, so the pin is here. This reads the table narrowly --
# a row is a line whose first cell is a backticked name and whose second is the kind -- and the
# emptiness guard below is what stops a mangled table from passing vacuously. check-prompts.sh
# deliberately has no table model (ludics-lite#75) and this does not give it one.
local_rows_of() {
  awk -F'|' '
    /^[[:space:]]*\|/ {
      name = $2; kind = $3
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", name)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", kind)
      if (kind != "local scheduled task") next
      if (substr(name, 1, 1) != "`" || substr(name, length(name), 1) != "`") next
      print substr(name, 2, length(name) - 2)
    }
  ' "$1" | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}
sorted_words() { printf '%s\n' $1 | sort | tr '\n' ' ' | sed 's/[[:space:]]*$//'; }

table_rows=$(local_rows_of "$ROUTINES_README")
if [ -n "$table_rows" ]; then
  ok "routines/README.md declares local scheduled tasks ($table_rows)"
else
  ko "no \`local scheduled task\` row found in $ROUTINES_README -- the comparison below would be vacuous"
fi
declared=$(sorted_words "$LOCAL_ROUTINES")
if [ -n "$table_rows" ] && [ "$declared" = "$table_rows" ]; then
  ok "LOCAL_ROUTINES lists exactly the table's local scheduled tasks"
else
  ko "LOCAL_ROUTINES ($declared) is not the table's local rows ($table_rows) -- ludics-lite#77"
fi

# The negative controls. Without these the comparison above is a claim that cannot fail: the
# same reader, over tables with a known defect, must disagree with the script's list.
cat > "$TMP/table-extra.md" <<'EOF'
| Routine | Kind | Fires |
| --- | --- | --- |
| `daily-issue-planning` | local scheduled task | daily |
| `ocannl-cross-machine-sweep` | local scheduled task | daily |
| `a-routine-nobody-syncs` | local scheduled task | daily |
| `ocannl-ci-red-triage` | cloud routine | on red |
EOF
[ "$(local_rows_of "$TMP/table-extra.md")" != "$declared" ] \
  && ok "the table reader catches a local row the script does not sync" \
  || ko "an unsynced local row reads as agreement -- the pin above proves nothing"

cat > "$TMP/table-missing.md" <<'EOF'
| Routine | Kind | Fires |
| --- | --- | --- |
| `daily-issue-planning` | local scheduled task | daily |
| `ocannl-ci-red-triage` | cloud routine | on red |
EOF
[ "$(local_rows_of "$TMP/table-missing.md")" != "$declared" ] \
  && ok "...and a synced routine that has no row" \
  || ko "a missing row reads as agreement"

cat > "$TMP/table-kind.md" <<'EOF'
| Routine | Kind | Fires |
| --- | --- | --- |
| `daily-issue-planning` | local scheduled task | daily |
| `ocannl-cross-machine-sweep` | local scheduled task | daily |
| `ocannl-ci-red-triage` | local scheduled task | on red |
EOF
[ "$(local_rows_of "$TMP/table-kind.md")" != "$declared" ] \
  && ok "...and the cloud routine relabelled as a local task" \
  || ko "the Kind cell is not read: a relabelled cloud row reads as agreement"

cat > "$TMP/table-none.md" <<'EOF'
| Routine | Kind | Fires |
| --- | --- | --- |
| `ocannl-ci-red-triage` | cloud routine | on red |
EOF
[ -z "$(local_rows_of "$TMP/table-none.md")" ] \
  && ok "...and a table with no local rows reads as empty, which the guard above refuses" \
  || ko "a table with no local rows produced rows anyway"

# The reader must not be fooled by the kind appearing somewhere other than the Kind cell.
cat > "$TMP/table-prose.md" <<'EOF'
Every local scheduled task is listed below.

| Routine | Kind | Fires |
| --- | --- | --- |
| `daily-issue-planning` | local scheduled task | a local scheduled task, daily |
| `ocannl-cross-machine-sweep` | local scheduled task | daily |
EOF
[ "$(local_rows_of "$TMP/table-prose.md")" = "$declared" ] \
  && ok "...while prose and later cells saying \"local scheduled task\" add no rows" \
  || ko "the reader picked up rows outside the Kind cell: $(local_rows_of "$TMP/table-prose.md")"

# --- the pin has to actually run ----------------------------------------------------------------
# The comparison above is only worth what CI runs. The diff classification in the workflow calls a
# PR prompt-only when every file it touches is Markdown other than the top-level README -- and a PR
# that adds or relabels a local routine can be exactly that (routines/README.md plus a prompt). So
# this suite's job must carry no `if:` and no `needs:`, or the one check that compares the table
# with LOCAL_ROUTINES is skipped on precisely the PRs that can break it.
WORKFLOW="$ROOT/.github/workflows/skill-scripts.yml"
# The block of one job: from `  <name>:` to the next line at that indent. A narrow read, like the
# table read above, and the emptiness guard is the same idea.
job_block() {
  JB_NAME="$1" awk '
    BEGIN { want = "  " ENVIRON["JB_NAME"] ":" }
    $0 == want { inside = 1; next }
    inside && /^  [^ #]/ { exit }
    inside { print }
  ' "$2"
}
if [ -f "$WORKFLOW" ]; then
  block=$(job_block sync-routines "$WORKFLOW")
  if [ -n "$block" ]; then
    ok "the workflow declares a sync-routines job"
    printf '%s\n' "$block" | grep -q 'test-sync-routines.sh' \
      && ok "...that runs this suite" || ko "the sync-routines job does not run this suite"
    printf '%s\n' "$block" | grep -qE '^    (if|needs):' \
      && ko "the sync-routines job is conditioned on the diff classification, so the routines-table pin is skipped on an all-Markdown PR -- the one shape that breaks it" \
      || ok "...unconditionally, so an all-Markdown PR is judged by it too"
  else
    ko "no sync-routines job in $WORKFLOW -- nothing runs this suite"
  fi
else
  ko "no $WORKFLOW to read"
fi
# The negative controls: the same reader over a scratch workflow, conditioned and unconditioned.
cat > "$TMP/wf-conditioned.yml" <<'EOF'
jobs:
  prompts:
    runs-on: ubuntu-latest
  sync-routines:
    name: sync-routines (ubuntu)
    needs: changes
    if: ${{ needs.changes.outputs.scripts == 'true' }}
    steps:
      - run: scripts/test-sync-routines.sh
  macos:
    runs-on: macos-latest
EOF
printf '%s\n' "$(job_block sync-routines "$TMP/wf-conditioned.yml")" | grep -qE '^    (if|needs):' \
  && ok "the job reader sees an if:/needs: line when one is there, so the verdict above can fail" \
  || ko "the job reader misses a conditioned job -- the verdict above means nothing"
cat > "$TMP/wf-plain.yml" <<'EOF'
jobs:
  sync-routines:
    name: sync-routines (ubuntu)
    steps:
      - run: scripts/test-sync-routines.sh
  macos:
    needs: changes
    if: ${{ always() }}
EOF
printf '%s\n' "$(job_block sync-routines "$TMP/wf-plain.yml")" | grep -qE '^    (if|needs):' \
  && ko "the job reader read past the end of the job into the next one" \
  || ok "...and stops at the next job, so a neighbour's condition is not read as this job's"

# --- the executable bit -------------------------------------------------------------------------
# A `> tmp && mv` rewrite of a script drops mode 755, and the failure is a CI run away: the
# workflow calls the script by path.
mode_of_tracked() { (cd "$ROOT" && git ls-files -s -- "$1" 2>/dev/null | awk '{print $1}'); }
sync_mode=$(mode_of_tracked scripts/sync-routines.sh)
case "$sync_mode" in
  100755) ok "scripts/sync-routines.sh is tracked executable (100755)" ;;
  "")     ko "scripts/sync-routines.sh is not tracked yet -- git add it, mode 755" ;;
  *)      ko "scripts/sync-routines.sh is tracked as $sync_mode, not 100755: chmod +x and re-add" ;;
esac
[ -x "$SYNC" ] && ok "...and executable in the working tree" || ko "$SYNC is not executable"
# The negative control for the mode read: the same helper over a scratch repo with a 644 script.
GITREPO="$TMP/moderepo"
mkdir -p "$GITREPO"
( cd "$GITREPO" \
  && git init -q . \
  && printf '#!/usr/bin/env bash\ntrue\n' > s.sh && chmod 644 s.sh \
  && git add s.sh ) >/dev/null 2>&1
scratch_mode=$( cd "$GITREPO" && git ls-files -s -- s.sh 2>/dev/null | awk '{print $1}' )
[ "$scratch_mode" = "100644" ] \
  && ok "the mode read reports 100644 for a non-executable script, so the check above can fail" \
  || ko "the mode read said '$scratch_mode' for a 644 file -- the verdict above means nothing"

# --- the real checkout, as the last word --------------------------------------------------------
# status against a destination that exists but holds nothing: the script must report, not crash,
# and must not touch the real ~/.claude/scheduled-tasks.
mkdir -p "$TMP/empty-dest"
out=$(env CLAUDE_SCHEDULED_TASKS_DIR="$TMP/empty-dest" "$SYNC" 2>&1); rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'not installed at' \
  && ok "the tracked script itself reports an empty destination with exit 1" \
  || ko "the tracked script on an empty destination: rc=$rc -- $out"
[ -z "$(ls -A "$TMP/empty-dest")" ] \
  && ok "...and a status read wrote nothing" || ko "status created files in the destination"

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
