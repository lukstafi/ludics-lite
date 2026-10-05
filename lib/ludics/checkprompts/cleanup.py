"""The post-merge-cleanup option register: ship-pr/SKILL.md against the helper's usage text.

ship-pr/SKILL.md is where an operator learns what post-merge-cleanup.sh takes, and the two were
edited apart (ludics-lite#276). This pins the one fact a lookup can see, in both directions: every
option the helper's usage text LISTS is named, verbatim, somewhere in the prompt, and every
``--option`` the prompt PASSES to the helper is one the text lists.

The listing is read where the helper's option table is rendered -- its printed usage text, which it
prints from the same table its parser reads (ludics-lite#332) -- by RUNNING it with no arguments,
its usage error. A listing line opens with two blanks and a ``--name``; its arity is 1 when a
``<value>`` placeholder follows the name.

What is an option OF the helper, on the prompt's side, is a line shape: a line inside a backtick
fence (three or more backticks up to three blanks in, closed only by a run at least as long with
nothing after it), lexed as the shell lexes a simple command, on which some word's last path
component is ``post-merge-cleanup.sh`` -- from that word to the first shell separator outside
quotes, plus each line a trailing backslash continues it onto; what follows a separator is lexed
again for a second invocation. The word after an arity-1 option is its value whatever it looks
like. That grammar is the reader's boundary (README, Tests; ludics-lite#75): encodings outside it
-- a quoted argument spanning lines, a ``$(…)`` argument, a redirection glued to the command word,
a word split by a continuation, options in a ``$var``, a ``~~~`` fence -- are unread, not misread,
and the prompt writes none of them.
"""

import os
import re
from dataclasses import dataclass

from ludics.checkprompts.bytes_view import WS, WS_CLASS, lat, one_of, records, substitution
from ludics.checkprompts.tree import Report, Tree
from ludics.proc import run_tool

CLEANUP_HELPER = "ship-pr/scripts/post-merge-cleanup.sh"
CLEANUP_PROMPT = "ship-pr/SKILL.md"

LISTING = re.compile(r"  --[A-Za-z0-9][A-Za-z0-9-]*(?:" + WS_CLASS + r"|\Z)")
PLACEHOLDER = re.compile(WS_CLASS + "*<")
FENCE = re.compile(r" {0,3}`{3,}")
BLANK_LINE = re.compile(WS_CLASS + "*")
HELPER_WORD = re.compile(r"(?:^|[^A-Za-z0-9_.\-])post-merge-cleanup\.sh\Z")
OPTION_WORD = re.compile(r"--.", re.S)


def usage_options(tree: Tree) -> list[tuple[str, int]] | None:
    """The options the helper's usage text lists, with their arity, or None when the run printed
    no usage text: an exit other than 2, or a stderr not opening with ``usage: ``."""
    env = dict(os.environ)
    env["LC_ALL"] = "C"  # the locale the shell checker exported to it
    done = run_tool("bash", [tree.path(CLEANUP_HELPER)], env=env)
    if done.rc != 2:
        return None
    text = lat(substitution(done.stderr))
    if not text.startswith("usage: "):
        return None
    listed: list[tuple[str, int]] = []
    for line in text.split("\n"):
        m = LISTING.match(line)
        if m is None:
            continue
        name = re.sub(WS_CLASS + r"\Z", "", line[2 : m.end()])
        listed.append((name, 1 if PLACEHOLDER.match(line[m.end() :]) else 0))
    return listed


@dataclass(frozen=True)
class Lexed:
    """One simple command's words; ``rest`` after the separator that ended it (``term``), and
    ``cont`` when an unquoted backslash ends the line."""

    words: list[str]
    term: bool
    rest: str
    cont: bool


def lex(line: str) -> Lexed:
    """Words split on unquoted blanks; single quotes literal; double quotes with the four escapes;
    a backslash escaping the next character; an unquoted ``#`` opening a word starts a comment;
    a redirection (``2>&1``, ``>&2``, ``<&0``, ``&>log``) carries no separator."""
    words: list[str] = []
    q = ""
    word = ""
    have = False
    n = len(line)
    i = 0
    while i < n:
        c = line[i]
        nxt = line[i + 1 : i + 2]
        if q == "":
            if c in WS:
                if have:
                    words.append(word)
                    word = ""
                    have = False
                i += 1
                continue
            if c == "\\":
                if i == n - 1:
                    return Lexed(words + [word] if have else words, False, "", True)
                word += nxt
                have = True
                i += 2
                continue
            if c in "\"'":
                q = c
                have = True
                i += 1
                continue
            if c == "#" and not have:
                break
            if c in ";|)" or (c == "&" and nxt != ">"):
                return Lexed(words + [word] if have else words, True, line[i + 1 :], False)
            if c == "&":  # `&>` and `&>>`
                i += 2
                if line[i : i + 1] == ">":
                    i += 1
                continue
            if c in "><" and nxt == "&":
                i += 1
                while one_of(line[i + 1 : i + 2], "0123456789-"):
                    i += 1
                i += 1
                continue
            word += c
            have = True
            i += 1
            continue
        if c == q:
            q = ""
        elif q == '"' and c == "\\" and one_of(nxt, '"\\$`'):
            word += nxt
            i += 1
        else:
            word += c
        i += 1
    return Lexed(words + [word] if have else words, False, "", False)


def invocation_options(text: str, valued: str) -> list[str]:
    """Every ``--option`` the prompt's helper command lines pass, in order. ``valued`` is the
    arity-1 names, each followed by a blank, as the shell checker built it."""
    padded = f" {valued} "
    out: list[str] = []
    fence = False
    flen = 0
    cont = False
    skip = False
    for rec in records(text):
        m = FENCE.match(rec)
        if m is not None:
            run = m.end() - rec.index("`")
            if not fence:
                fence, flen, cont, skip = True, run, False, False
                continue
            if run >= flen and BLANK_LINE.fullmatch(rec[m.end() :]):
                fence, cont = False, False
                continue
        if not fence:
            cont = False
            continue
        line = rec
        while True:
            lexed = lex(line)
            start = 0
            if not cont:
                # The helper is a WORD whose last path component is its name, once unquoted.
                hit = next(
                    (i for i, w in enumerate(lexed.words) if HELPER_WORD.search(w)), None
                )
                if hit is None:
                    if not lexed.term:
                        break
                    line = lexed.rest
                    continue
                start = hit + 1
                skip = False
            for w in lexed.words[start:]:
                if skip:
                    skip = False
                    continue
                if not OPTION_WORD.match(w):
                    continue
                out.append(w)
                if f" {w} " in padded:
                    skip = True
            cont = lexed.cont
            if not lexed.term:
                break
            line = lexed.rest
            cont = False
    return out


def check_cleanup_options(report: Report, tree: Tree) -> None:
    # A root without the helper documents no helper, so it carries no obligation.
    if not tree.is_file(CLEANUP_HELPER):
        return
    if not tree.is_file(CLEANUP_PROMPT):
        report.ko(CLEANUP_HELPER, f"has no {CLEANUP_PROMPT} to document its options in")
        return
    listing = usage_options(tree)
    if listing is None:
        report.ko(
            CLEANUP_HELPER,
            "run with no arguments, it printed no usage text: it must exit 2 with a stderr opening"
            " 'usage: ' (see usage_options)",
        )
        return
    if not listing:
        # Not a pass: an empty register would hold the prompt to nothing, in silence.
        report.ko(
            CLEANUP_HELPER,
            "usage() lists no options this reader can see: a usage line opening with two blanks"
            " and a --name",
        )
        return
    listed = [name for name, _ in listing]
    valued = "".join(f"{name} " for name, arity in listing if arity == 1)
    prompt = tree.read(CLEANUP_PROMPT) or ""
    passed = sorted(set(invocation_options(prompt, valued)))
    # The shell read the prompt through `$(cat …)`, which drops a NUL.
    prompt_lines = records(prompt.replace("\0", ""))
    bad = False
    for o in listed:
        # The token whole, and in the token grammar the invocation side uses.
        named = re.compile(r"(?:^|[^A-Za-z0-9_.\-])" + re.escape(o) + r"(?:[^A-Za-z0-9_.\-]|\Z)")
        if not any(named.search(line) for line in prompt_lines):
            report.ko(
                CLEANUP_PROMPT,
                f"names no '{o}', which {CLEANUP_HELPER}'s usage() lists: the prompt is where the"
                " option is learned of (ludics-lite#276)",
            )
            bad = True
    for o in passed:
        if o not in listed:
            report.ko(
                CLEANUP_PROMPT, f"passes '{o}' to {CLEANUP_HELPER}, whose usage() lists no such option"
            )
            bad = True
    if not bad:
        report.ok(
            f"{CLEANUP_PROMPT} and {CLEANUP_HELPER}'s usage() agree on the helper's options"
            f" ({len(listed)} listed)"
        )
