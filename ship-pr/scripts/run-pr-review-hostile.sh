#!/usr/bin/env bash
# Re-run every pr-review fixture suite under the environment axes that broke #106.
# Local use: ship-pr/scripts/run-pr-review-hostile.sh
# Requires an installed non-C locale (default en_US.UTF-8; override PR_REVIEW_HOSTILE_LOCALE).
# Suite stderr must be empty: an exit-zero sed locale error is still a broken assertion.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
hostile_locale=${PR_REVIEW_HOSTILE_LOCALE:-en_US.UTF-8}
# Validate in a separate process, without changing the runner's own parsing locale.
python3 - "$hostile_locale" <<'PY'
import locale
import sys
name = sys.argv[1]
if name.lower() in ('c', 'posix', 'c.utf8', 'c.utf-8'):
    sys.exit('hostile pass requires a non-C locale')
locale.setlocale(locale.LC_ALL, name)
PY

scratch=$(mktemp -d "${TMPDIR:-/tmp}/pr-review hostile.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/scripts with spaces" "$scratch/tmp with spaces"
cp -p "$script_dir/"*.sh "$scratch/scripts with spaces/"
result=0
for suite in "$scratch/scripts with spaces"/test-pr-review-*.sh; do
  name=$(basename "$suite")
  printf '\nHostile pass: %s (locale=%s)\n' "$name" "$hostile_locale"
  rc=0
  # Execute the file itself, preserving the mode-bit check. Bash imports the exported
  # functions; IFS and PIPESTATUS are intentionally supplied too, though Bash resets
  # them on startup. The lib suite pins their rejection as retune constants.
  env GRACE=777 ABSENT_GRACE=5 CHECKS_INTERVAL=9 STALL=3 ROUND_GAP=1 \
    IFS=hostile PIPESTATUS=hostile LC_ALL="$hostile_locale" \
    TMPDIR="$scratch/tmp with spaces" \
    bash -c 'gh(){ :; }; fail(){ :; }; export -f gh fail; exec "$1"' _ "$suite" \
    >"$scratch/stdout" 2>"$scratch/stderr" || rc=$?
  cat "$scratch/stdout"
  cat "$scratch/stderr" >&2
  if [ "$rc" -ne 0 ] || [ -s "$scratch/stderr" ]; then
    printf 'FAIL: %s: exit=%s; stderr must be empty\n' "$name" "$rc" >&2
    result=1
  fi
  # Check before deleting anything, including hidden entries and dangling symlinks.
  leftovers=$(find "$scratch/tmp with spaces" -mindepth 1 -print)
  if [ -n "$leftovers" ]; then
    printf 'FAIL: %s left temporary files:\n%s\n' "$name" "$leftovers" >&2
    result=1
  fi
  # Give the next suite a clean TMPDIR even if this one failed its cleanup check.
  rm -rf "$scratch/tmp with spaces"
  mkdir "$scratch/tmp with spaces"
done
exit "$result"
