#!/usr/bin/env bash
# Prompt hygiene: the small, deterministic checks on the prompts themselves -- every skill and
# routine `SKILL.md`, the two READMEs that index them, and the cross-file agreements that ride
# along (the fixture register, the mac-studio slot count, the routines' drift step, the cleanup
# helper's options, relative links and anchors). The one CI job that runs on every head (#55).
#
# Usage: check-prompts.sh [root]   (root defaults to this checkout; exit 0 all pass, 1 otherwise)
#        check-prompts.sh --one <dir>   (frontmatter only, for an installed task's directory)
#
# Ported to Python (ludics-lite#403): the checks live in lib/ludics/checkprompts/, whose modules
# each state what they read and where their reading stops. This file is the entry point the skills,
# CI and preflight call, and forwards to it unchanged; scripts/test-check-prompts.sh is its suite.
exec "$(dirname "$0")/py" -m ludics.checkprompts "$@"
