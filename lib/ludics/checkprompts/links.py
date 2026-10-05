"""Relative links and anchors in the prompts (ludics-lite#260).

Scope is the prompts, the two READMEs that index them, and the reference files the prompts delegate
to: ``README.md``, ``routines/README.md``, ``*/SKILL.md``, ``routines/*/SKILL.md`` and the
``references/*.md`` (dotted ones included) of a skill or a routine.

The scan is fixed and carries no Markdown block model, for the reason the index lookup carries none
(ludics-lite#75). What it reads is ONE shape -- ``](<target>)`` on one line, opened by a real label,
with no blank inside the target, a path half ending in ``.md`` and spelled in ordinary path
characters -- and what it claims is two lookups: the path exists relative to the LINKING file, and
the anchor is the GitHub slug of one of the target's ATX headings. Everything outside the shape is
not checked rather than guessed at: a URI scheme or a leading ``/``, a titled link, a same-file
anchor, a non-``.md`` target, a percent escape, an angle-bracket destination, a reference-style
link, a link split across lines.

What the scan will not do is answer about the MACHINE instead of the prompts: a path spelling its
way out of the checkout, one walking out through a symbolic link, and one whose spelling the
checkout has only on a case-insensitive filesystem are all refused on the path -- never probed --
on the reading side as on the target side.

There is no BLOCK scope, which is the one gap cutting both ways. A heading-shaped line GFM would not
render (inside a fence, an HTML block, a comment) still contributes a slug: that only makes the
anchor lookup more permissive, and keeping that TRUE constrains everything below -- a heading this
check will not spell refuses nothing after it (round 9 of ludics-lite#268 took out a suppression
that did). A link written inside a fence or between backticks is read like any other.
"""

import re
from dataclasses import dataclass, field

from ludics.checkprompts.bytes_view import WS_CLASS, ascii_lower, is_alnum, records
from ludics.checkprompts.tree import Report, Tree

LINK_FILE_GLOBS = (
    "README.md",
    "routines/README.md",
    "*/SKILL.md",
    "routines/*/SKILL.md",
    "*/references/*.md",
    "*/references/.*.md",
    "routines/*/references/*.md",
    "routines/*/references/.*.md",
)


def link_files(tree: Tree) -> list[str]:
    """The Markdown whose links this check reads, root-relative, byte-sorted and unique."""
    return sorted(set(tree.files(*LINK_FILE_GLOBS)))


@dataclass(frozen=True)
class Link:
    """A link of the read shape: the linking file, the target as WRITTEN, the path it spells
    resolved from the linking file's directory, and the anchor (empty when it carries none)."""

    rel: str
    target: str
    resolved: str
    anchor: str


URI_SCHEME = re.compile(r"[A-Za-z][A-Za-z0-9+.\-]*:")
OUTSIDE_PATH_CHARS = re.compile(r"[^A-Za-z0-9._/()~+#\-]")
BLANK = re.compile(WS_CLASS)


def escaped(text: str, at: int) -> bool:
    """Whether the 1-based character at ``at`` stands behind an odd number of backslashes."""
    b = 0
    while at - b - 1 >= 1 and text[at - b - 2] == "\\":
        b += 1
    return b % 2 == 1


def resolve(directory: str, path: str) -> str:
    """The path as written, read from ``directory``, with its ``.`` and ``..`` segments taken out
    -- lexically, never through the filesystem. A path that climbs past the root keeps its
    leading ``..``."""
    out: list[str] = []
    for part in f"{directory}/{path}".split("/"):
        if part in ("", "."):
            continue
        if part == ".." and out and out[-1] != "..":
            out.pop()
            continue
        out.append(part)
    return "/".join(out)


def md_links(rel: str, directory: str, text: str) -> list[Link]:
    found: list[Link] = []
    for line in records(text):
        while (i := line.find("](") + 1) > 0:
            # A link opens with a LABEL: the bracket THIS `]` closes, walked backwards, counting
            # the pairs that close on the way; a bracket a backslash made literal is text.
            if escaped(line, i):
                line = line[i + 1 :]
                continue
            label = False
            depth = 0
            for k in range(i - 1, 0, -1):
                c = line[k - 1]
                if c not in "[]" or escaped(line, k):
                    continue
                if c == "]":
                    depth += 1
                elif depth == 0:
                    label = True
                    break
                else:
                    depth -= 1
            line = line[i + 1 :]
            if not label:
                continue
            # The target ends at the paren that CLOSES the one the link opened. A candidate that
            # is not accepted leaves the cursor just past its `](`.
            depth = 1
            j = 0
            for k, c in enumerate(line, start=1):
                if c == "(":
                    depth += 1
                elif c == ")":
                    depth -= 1
                    if depth == 0:
                        j = k
                        break
            if j == 0:
                continue
            target = line[: j - 1]
            if BLANK.search(target) or URI_SCHEME.match(target) or target.startswith("/"):
                continue
            path, _, anchor = target.partition("#")
            if not path.endswith(".md") or OUTSIDE_PATH_CHARS.search(target):
                continue
            line = line[j:]  # accepted: the cursor may pass the whole link
            found.append(Link(rel, target, resolve(directory, path), anchor))
    return found


# --- heading slugs -------------------------------------------------------------------------------

ASCII = frozenset(chr(n) for n in range(1, 128))
# U+2000-U+206F, General Punctuation, as its UTF-8 bytes: E2 80 80 .. E2 81 AF.
PUNCTUATION = frozenset(
    ["\xe2\x80" + chr(n) for n in range(128, 192)] + ["\xe2\x81" + chr(n) for n in range(128, 176)]
)
# The ASCII punctuation a backslash may escape, as CommonMark lists it.
ESCAPABLE = frozenset(
    chr(n) for r in ((33, 47), (58, 64), (91, 96), (123, 126)) for n in range(r[0], r[1] + 1)
)
BOM = "\xef\xbb\xbf"
CLOSING_HASHES = re.compile(r"[ \t]+#+[ \t]*\Z")

HTML_TAG = re.compile(r"</?[A-Za-z][A-Za-z0-9-]*(?:" + WS_CLASS + r"[^<>]*)?/?>")
AUTOLINK = re.compile(r"<[A-Za-z][A-Za-z0-9+.\-]*:[^<> \t\n\v\f\r]*>")
COMMENT = re.compile(r"<!--.*-->", re.S)
PROCESSING = re.compile(r"<\?[^<>]*\?>")
DECLARATION = re.compile(r"<![A-Za-z][^<>]*>")
NUMERIC_REF = re.compile(r"&#[0-9]+;|&#[xX][0-9A-Fa-f]+;")
# The named references this prose could plausibly write; anything else reads as the literal text
# it renders as (the permissive direction), and this list is where to add one.
NAMED_REF = re.compile(
    r"&(?:amp|lt|gt|quot|apos|nbsp|copy|reg|trade|hellip|mdash|ndash|laquo|raquo|deg|times"
    r"|divide|plusmn|micro|para|sect|dagger|bull|lsquo|rsquo|ldquo|rdquo);"
)


def render_spans(h: str) -> tuple[str, str]:
    """Two readings of a heading from ONE left-to-right walk: the text with each code span
    replaced by what it renders to (CommonMark's one-space strip when both ends are spaces and the
    content is not all spaces), and the "bare" heading with each span and each escaped character
    replaced by ``.`` for the markup tests. A backslash escapes only when reached as text, outside a
    span; a backtick run with no closing run of the same length is literal."""
    text: list[str] = []
    bare: list[str] = []
    n = len(h)
    i = 0
    while i < n:
        c = h[i]
        if c == "\\" and i < n - 1 and h[i + 1] in ESCAPABLE:
            text.append(h[i + 1])
            bare.append(".")
            i += 2
            continue
        if c != "`":
            text.append(c)
            bare.append(c)
            i += 1
            continue
        run = len(h[i:]) - len(h[i:].lstrip("`"))
        j = i + run
        close = -1
        while j < n:
            if h[j] != "`":
                j += 1
                continue
            m = len(h[j:]) - len(h[j:].lstrip("`"))
            if m == run:
                close = j
                break
            j += m
        if close < 0:  # no closing run: literal backticks
            text.append(h[i : i + run])
            bare.append(h[i : i + run])
            i += run
            continue
        content = h[i + run : close]
        if content.startswith(" ") and content.endswith(" ") and content.strip(" "):
            content = content[1:-1]
        text.append(content)
        bare.append(".")
        i = close + run
    return "".join(text), "".join(bare)


def linked(t: str) -> bool:
    """Whether ``t`` carries a ``](`` whose ``]`` closes a bracket opened earlier."""
    start = 0
    while (i := t.find("](", start)) >= 0:
        depth = 0
        for k in range(i - 1, -1, -1):
            if t[k] == "]":
                depth += 1
            elif t[k] == "[":
                if depth == 0:
                    return True
                depth -= 1
        start = i + 2
    return False


def slug(h: str) -> str | None:
    """The heading's GitHub anchor, or None for one this check will not spell: one whose RENDERED
    text differs from its source (inline link or reference syntax, an HTML tag, autolink, comment
    or other raw-HTML form, a character reference that decodes, underscore emphasis), or one
    carrying a non-ASCII byte outside General Punctuation, which may be a letter GitHub keeps.
    Emphasis with ``*`` and code-span markers need no test: both readings drop them."""
    text, bare = render_spans(h)
    if linked(bare) or "][" in bare:
        return None
    if (
        HTML_TAG.search(bare)
        or AUTOLINK.search(bare)
        or COMMENT.search(bare)
        or PROCESSING.search(bare)
        or DECLARATION.search(bare)
        or "<![CDATA[" in bare
        or NUMERIC_REF.search(bare)
        or NAMED_REF.search(bare)
    ):
        return None
    # CommonMark's flanking rule: an `_` with an alphanumeric on BOTH sides is literal.
    for i, c in enumerate(bare):
        if c == "_" and not (is_alnum(bare[i - 1 : i]) and is_alnum(bare[i + 1 : i + 2])):
            return None
    lower = ascii_lower(text)
    out: list[str] = []
    i = 0
    while i < len(lower):
        c = lower[i]
        # Only a literal SPACE becomes a hyphen; a tab is a control the slugger removes.
        if c == " ":
            out.append("-")
        elif "a" <= c <= "z" or "0" <= c <= "9" or c in "_-":
            out.append(c)
        elif c in ASCII:
            pass  # ASCII punctuation, which GitHub drops
        elif lower[i : i + 3] in PUNCTUATION:
            i += 2
        else:
            return None
        i += 1
    return "".join(out)


@dataclass
class Slugs:
    """A target file's anchors, and whether it carries a heading this check will not spell."""

    anchors: set[str] = field(default_factory=lambda: set())
    unspelled: bool = False


def heading_slugs(text: str) -> Slugs:
    """The GitHub anchor of every ATX heading, numbered as GitHub numbers repeats: a candidate
    already taken takes the next free ``-<n>``, and an empty slug is an occupant too. A heading
    this check will not spell still occupies a slug on GitHub; it contributes none here, which
    can leave a later ``-<n>`` unconfirmed but never accepts an anchor GitHub lacks."""
    slugs = Slugs()
    taken: set[str] = set()
    occurrences: dict[str, int] = {}
    for index, raw in enumerate(records(text)):
        line = raw
        # A byte-order mark opens a file, and GFM removes it before parsing; a CR is the other
        # half of a CRLF line ending.
        if index == 0 and line.startswith(BOM):
            line = line[3:]
        if line.endswith("\r"):
            line = line[:-1]
        # A run of blockquote markers is the container, with GFM's indentation limits: at most
        # three spaces before each, then the one column the marker takes -- of a tab, ONE column of
        # its expansion, the rest kept as the spaces it expands to.
        col = 0
        while True:
            indent = len(line) - len(line.lstrip(" "))
            if indent > 3 or line[indent : indent + 1] != ">":
                break
            col += indent + 1
            line = line[indent + 1 :]
            if line[:1] == " ":
                line = line[1:]
                col += 1
            elif line[:1] == "\t":
                pad = 4 - (col % 4) - 1
                line = " " * pad + line[1:]
                col += 1
        # An ATX heading: up to three spaces, one to six hashes, then a blank or the line end.
        spaces = len(line) - len(line.lstrip(" "))
        if spaces > 3:
            continue
        after = line[spaces:]
        hashes = len(after) - len(after.lstrip("#"))
        if hashes < 1 or hashes > 6:
            continue
        rest = after[hashes:]
        if rest != "" and rest[0] not in " \t":
            continue
        rest = CLOSING_HASHES.sub("", rest, count=1).strip(" \t")
        s = slug(rest)
        if s is None:
            slugs.unspelled = True
            continue
        base = s
        while s in taken:
            occurrences[base] = occurrences.get(base, 0) + 1
            s = f"{base}-{occurrences[base]}"
        taken.add(s)
        if s:
            slugs.anchors.add(s)
    return slugs


# --- the path guards -----------------------------------------------------------------------------


def components(rel: str) -> list[str]:
    return [seg for seg in rel.split("/") if seg]


def symlinked(tree: Tree, rel: str) -> bool:
    """Whether ``rel``, below the root, is a symbolic link or is reached through one."""
    acc = ""
    for seg in components(rel):
        acc = f"{acc}/{seg}" if acc else seg
        if tree.is_link(acc):
            return True
    return False


def cased(tree: Tree, rel: str) -> bool:
    """Whether every component of ``rel`` is spelled exactly as the checkout's directories hold
    it -- on a case-insensitive filesystem the path resolves either way, and GitHub does not."""
    parent = ""
    for seg in components(rel):
        names = tree.names(parent)
        if names is None or seg not in names:
            return False
        parent = f"{parent}/{seg}" if parent else seg
    return True


def outside(resolved: str) -> bool:
    return resolved == ".." or resolved.startswith("../")


def check_links(report: Report, tree: Tree) -> None:
    links: list[Link] = []
    bad = False
    for rel in link_files(tree):
        # The same guard the targets get, on the READING side: a prompt file that is a symlink is
        # a defect in the checkout, reported rather than read or skipped in silence.
        if symlinked(tree, rel):
            report.ko(rel, "is reached through a symbolic link, so its links are not read")
            bad = True
            continue
        directory = rel.rsplit("/", 1)[0] if "/" in rel else "."
        links.extend(md_links(rel, directory, tree.read(rel) or ""))
    # No link is no verdict on the links: the obligation comes from a link.
    if not links:
        return
    table: dict[str, Slugs] = {}
    for link in links:
        rel, target, resolved = link.rel, link.target, link.resolved
        # Refused on the path itself, and never probed on the filesystem, before anything is read.
        if outside(resolved):
            report.ko(rel, f"link to {target} resolves outside the checkout: {resolved}")
            bad = True
            continue
        if symlinked(tree, resolved):
            report.ko(rel, f"link to {target} is reached through a symbolic link: {resolved}")
            bad = True
            continue
        if not tree.is_file(resolved):
            report.ko(rel, f"link to {target} resolves to no file: {resolved}")
            bad = True
            continue
        if not cased(tree, resolved):
            report.ko(
                rel,
                f"link to {target} finds {resolved} only on a case-insensitive filesystem; the"
                " checkout spells that path differently, and GitHub serves the link as written",
            )
            bad = True
            continue
        if not link.anchor:
            continue
        if resolved not in table:
            table[resolved] = heading_slugs(tree.read(resolved) or "")
        slugs = table[resolved]
        if link.anchor not in slugs.anchors:
            hint = (
                " (it also carries a heading this check will not spell an anchor for, which can"
                " leave a numbered repeat unconfirmed: see heading_slugs)"
                if slugs.unspelled
                else ""
            )
            report.ko(
                rel,
                f"link to {target} names no heading: {resolved} has none whose GitHub slug is"
                f" '{link.anchor}'{hint}",
            )
            bad = True
    if not bad:
        report.ok(
            "every relative Markdown link in the prompts resolves, anchors included"
            f" ({len(links)} checked)"
        )
