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
#     through a symlink, quietly);
#   - that --dry-run copies nothing, in every mode, and still says what it would do;
#   - the usage exits: an unknown argument is 2, --help prints the header;
#   - that LOCAL_ROUTINES lists exactly the routines/README.md rows whose Kind is
#     `local scheduled task` (ludics-lite#77), with negative controls that show the comparison
#     can fail -- a claim that cannot fail would be worse than no claim;
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
