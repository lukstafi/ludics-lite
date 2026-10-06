"""The helper's command line: one option table drives the usage text and the parser.

That is ludics-lite#332's rule, carried over from the shell: ``usage_text`` prints its option rows
from ``OPTIONS`` and ``parse_options`` looks each argument up in it, so the listing and the parser
cannot disagree on an option's name or on whether it takes a value (#302 was a second hand-written
copy that did). ``scripts/check-prompts.sh`` holds ship-pr/SKILL.md to the PRINTED listing.

A row's placeholder is ``<word>`` for an option that takes a value (the next argument, which may
be anything but missing or empty) and empty for a flag, which consumes nothing. A repeatable
option appends; any other takes its last occurrence.
"""

from dataclasses import dataclass

PROG = "post-merge-cleanup.sh"


@dataclass(frozen=True)
class Option:
    name: str
    placeholder: str
    key: str
    repeatable: bool
    help: tuple[str, ...]


OPTIONS: tuple[Option, ...] = (
    Option(
        "--base", "<branch>", "base", False, ("Base branch to refresh and verify (default: master)",)
    ),
    Option(
        "--force-integrated",
        "<reason>",
        "force_reason",
        False,
        ("Why this squash/rebase merge is confirmed",),
    ),
    Option(
        "--regenerable",
        "<name>",
        "regenerable",
        True,
        (
            "A top-level directory of the session worktree that cleanup may",
            "REMOVE rather than refuse over or archive, such as a build tree.",
            "Repeatable, no default; the name must be one untracked directory",
            "of the worktree root and is never followed through a symlink.",
        ),
    ),
)

_EPILOGUE = (
    "The ordinary path requires the topic branch to be an ancestor of origin/<base>. Use\n"
    "--force-integrated only after independently confirming a squash or rebase merge; its\n"
    "non-empty reason is printed in the cleanup record."
)

# An option's name and placeholder fill a 21-column field ahead of its help; a longer pair takes a
# line of its own, and its help starts on the next, at the same column.
_FIELD = 21


def usage_text() -> str:
    lines = [
        f"usage: {PROG} <main-checkout> <session-worktree> <branch> [options]",
        "",
        "Options:",
    ]
    for option in OPTIONS:
        head = option.name + (f" {option.placeholder}" if option.placeholder else "")
        if len(head) > _FIELD:
            lines.append(f"  {head}")
            head = ""
        for text in option.help:
            lines.append(f"  {head:<{_FIELD}} {text}")
            head = ""
    lines.append("")
    lines.append(_EPILOGUE)
    return "\n".join(lines)


@dataclass(frozen=True)
class Options:
    base: str = "master"
    force_reason: str = ""
    regenerable: tuple[str, ...] = ()


@dataclass(frozen=True)
class Parsed:
    options: Options


@dataclass(frozen=True)
class UsageError:
    """An argument the table does not name in exactly that spelling, or a missing or empty value."""


type ParseResult = Parsed | UsageError


def parse_options(args: list[str]) -> ParseResult:
    values: dict[str, str] = {}
    lists: dict[str, list[str]] = {}
    i = 0
    while i < len(args):
        option = next((o for o in OPTIONS if o.name == args[i]), None)
        if option is None:
            return UsageError()
        if not option.placeholder:
            values[option.key] = "1"
            i += 1
            continue
        if i + 1 >= len(args) or not args[i + 1]:
            return UsageError()
        if option.repeatable:
            lists.setdefault(option.key, []).append(args[i + 1])
        else:
            values[option.key] = args[i + 1]
        i += 2
    return Parsed(
        Options(
            base=values.get("base", "master"),
            force_reason=values.get("force_reason", ""),
            regenerable=tuple(lists.get("regenerable", [])),
        )
    )

