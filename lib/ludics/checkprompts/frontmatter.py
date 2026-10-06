"""The frontmatter of a SKILL.md: a flat map of one-line scalars, each inside a YAML subset.

What it pins, per file:
  - YAML frontmatter: line 1 is ``---``, closed by a later ``---``, and every line between them is
    a top-level ``key: value`` (or blank, or a comment) -- a flat map of one-line scalars, which is
    the only shape the loaders read; a continued, nested, listed or block-scalar value is refused
    rather than half-read;
  - every declared key is declared once and carries a value inside the grammar YAML reads
    unambiguously as a non-empty string (``value_of``); anything else is refused, whether or not a
    loader would accept it, so the checker never has to guess what a loader would make of it;
  - ``name:`` and ``description:`` are both there, and (outside ``--one``) ``name`` equals the
    directory's name, which is what the install loops link by and the scheduler registers.

Bytes no loader accepts are refused on the raw file before anything is read: a NUL or invalid UTF-8
anywhere, and in the frontmatter the characters outside YAML's ``c-printable`` production that
valid UTF-8 can still carry once the ASCII controls are refused -- the C1 controls U+0080-U+009F and
the non-characters U+FFFE and U+FFFF -- plus the line breaks YAML 1.1 knows beyond LF, CR and NEL,
U+2028 and U+2029, which would split a value the frontmatter reads as one line. The Markdown body
after the closing fence is never YAML and may carry a line separator.
"""

import re
from dataclasses import dataclass
from typing import assert_never

from ludics.checkprompts.bytes_view import WS, WS_CLASS, ascii_lower, records
from ludics.checkprompts.tree import Report, Tree

KEY_LINE = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*:(?:" + WS_CLASS + r"|\Z)")
BLANK_OR_COMMENT = re.compile(WS_CLASS + r"*(?:#|\Z)")
# In the frontmatter, as bytes: a C1 control, U+FFFE/U+FFFF, U+2028/U+2029.
YAML_UNPRINTABLE = re.compile("\xc2[\x80-\x9f]|\xef\xbf[\xbe\xbf]|\xe2\x80[\xa8\xa9]")

DOUBLE_QUOTED = re.compile(r'"((?:[^"\\]|\\["\\])*)"(?:' + WS_CLASS + r"+#.*)?", re.S)
SINGLE_QUOTED = re.compile(r"'((?:[^']|'')*)'(?:" + WS_CLASS + r"+#.*)?", re.S)
PLAIN_COMMENT = re.compile(WS_CLASS + "#.*", re.S)
YAML_KEYWORDS = frozenset(("true", "false", "yes", "no", "on", "off", "y", "n", "null"))
INDICATORS = "[]{}&*!|>%@`,"
LETTERS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


@dataclass(frozen=True)
class Resolved:
    """A value inside the grammar, and the text it resolves to (empty is "no value")."""

    text: str


@dataclass(frozen=True)
class Refused:
    """A value outside the grammar, and why."""

    reason: str


type Value = Resolved | Refused


def value_of(raw: str) -> Value:
    """The text a value resolves to, when it lies inside the grammar this checker accepts.

    The grammar is a deliberate SUBSET of YAML -- the values a loader reads unambiguously as a
    string -- and everything outside it is refused whether YAML would accept it or not:
      - a double-quoted string, ``"..."``, closed on the same line and followed by nothing but an
        optional comment, escaping only ``\\"`` and ``\\\\`` (every other backslash is refused
        rather than decoded, so a value never resolves past one line);
      - a single-quoted string, ``'...'`` with ``''`` for a quote, closed the same way;
      - a plain scalar: starts with an ASCII letter (no implicitly typed YAML scalar does), is not
        a boolean or null keyword, carries no leading indicator, no ``: `` and no trailing ``:``;
        an unquoted trailing `` #comment`` is dropped first.
    The empty string, from any of these, is "no value" (``null``, ``~`` and a bare comment too).
    """
    v = raw.strip(WS)
    if v.startswith('"'):
        m = DOUBLE_QUOTED.fullmatch(v)
        if m is None:
            return Refused(
                "a double-quoted value must close on the same line with nothing but a comment"
                ' after it, and may escape only \\" and \\\\ (single-quote the value, or drop the'
                " backslash)"
            )
        return Resolved(re.sub(r'\\(["\\])', r"\1", m.group(1)))
    if v.startswith("'"):
        m = SINGLE_QUOTED.fullmatch(v)
        if m is None:
            return Refused(
                "a single-quoted value must close on the same line, with nothing but a comment"
                " after the closing quote"
            )
        return Resolved(m.group(1).replace("''", "'"))
    v = PLAIN_COMMENT.sub("", v, count=1).rstrip(WS)
    first = v[:1]
    if v == "" or v.startswith("#"):
        inner = ""
    elif first in INDICATORS:
        return Refused(
            f"starts with the YAML indicator '{first}', which a loader reads as a collection,"
            " anchor, tag or block scalar, not text; quote the value"
        )
    elif v in ("-", "?", ":") or v.startswith(("- ", "? ", ": ")):
        return Refused(
            f"starts with '{first} ', which YAML reads as a list item or mapping key, not text;"
            " quote the value"
        )
    elif ": " in v or v.endswith(":"):
        return Refused(
            "contains ': ' or ends with ':', which YAML reads as a nested mapping, not text;"
            " quote the value or rephrase"
        )
    else:
        inner = v
    if inner in ("null", "Null", "NULL", "~"):
        inner = ""
    # Implicit typing is closed by shape: no number, date, time or other implicitly typed scalar
    # begins with an ASCII letter, so a plain value must, and the keyword spellings of booleans
    # and null are the one lettered exception, refused by name.
    if inner and inner[0] not in LETTERS:
        return Refused(
            f"'{inner}' does not start with a letter, so a loader may read it as a number, date,"
            " time or other typed value, not text; quote the value"
        )
    if ascii_lower(inner) in YAML_KEYWORDS:
        return Refused(f"'{inner}' is a boolean or null to YAML, not text; quote the value")
    return Resolved(inner)


def well_formed_bytes(data: bytes) -> bool:
    """No NUL, valid UTF-8, and no YAML-unprintable character or line separator in the
    frontmatter -- read as the lines after the first, up to the first ``---`` line."""
    if b"\0" in data:
        return False
    try:
        data.decode("utf-8")
    except UnicodeDecodeError:
        return False
    for line in records(data.decode("latin-1"))[1:]:
        if line == "---":
            break
        if YAML_UNPRINTABLE.search(line):
            return False
    return True


def frontmatter(text: str) -> list[str] | None:
    """The lines between the opening and the closing fence, or None when there is no frontmatter.
    Trailing blank lines are dropped, as the shell's ``$(...)`` dropped them; an empty frontmatter
    is one empty line."""
    # The opening fence is a whole first LINE: `read` fails on a first line with no newline.
    if not text.startswith("---\n"):
        return None
    body: list[str] = []
    for line in records(text)[1:]:
        if line == "---":
            return "\n".join(body).rstrip("\n").split("\n")
        body.append(line)
    return None


def has_control(lines: list[str]) -> bool:
    """``[[:cntrl:]]`` under C: an ASCII control (0x00-0x1F) or DEL."""
    return any(c < " " or c == "\x7f" for line in lines for c in line)


def check_skill_file(report: Report, tree: Tree, rel: str, *, one: bool) -> None:
    """The frontmatter verdict on ``rel``: every defect reported, then ``ok`` when it had none."""
    before = report.failed
    data = tree.read_bytes(rel)
    if data is None or not well_formed_bytes(data):
        report.ko(
            rel,
            "carries a byte sequence no loader accepts: a NUL or invalid UTF-8 anywhere, or in the"
            " frontmatter a character outside YAML's printable set (a C1 control, U+FFFE, U+FFFF)"
            " or a line separator (U+2028, U+2029)",
        )
        return
    fm = frontmatter(data.decode("latin-1"))
    if fm is None:
        report.ko(rel, "no YAML frontmatter: line 1 must be '---' and a closing '---' must follow")
        return
    # A control character anywhere in the frontmatter -- a tab YAML reads as a separator, a
    # carriage return a loader folds into the value -- is refused whole.
    if has_control(fm):
        report.ko(
            rel,
            "frontmatter carries a control character (a tab or a carriage return, say); use plain"
            " spaces and LF line ends",
        )
        return
    for line in fm:
        if not BLANK_OR_COMMENT.match(line) and not KEY_LINE.match(line):
            report.ko(
                rel,
                "frontmatter line is not a top-level 'key: value' (a continued, nested or listed"
                f" value cannot be read as one line): '{line}'",
            )
            return
    # Every declared key, the optional ones included, is declared once and carries a value inside
    # the grammar: a loader rejects the whole file on a malformed `allowed-tools:` just as on a
    # malformed `name:`.
    name = ""
    keys = sorted({line.split(":", 1)[0] for line in fm if KEY_LINE.match(line)})
    for key in keys:
        declared = [line for line in fm if line.startswith(key + ":")]
        if len(declared) != 1:
            report.ko(rel, f"frontmatter has {len(declared)} '{key}:' lines, expected one")
            continue
        raw = declared[0][len(key) + 1 :].lstrip(WS)
        if raw.startswith(("|", ">")):
            report.ko(rel, f"{key} is a block scalar ('{raw}'); the loaders read it as one line")
            continue
        match value_of(raw):
            case Refused(reason):
                report.ko(
                    rel,
                    f"frontmatter '{key}:' value is outside the grammar this check accepts:"
                    f" '{raw}' ({reason})",
                )
                continue
            case Resolved(value):
                pass
            case _ as unreachable:
                assert_never(unreachable)
        if value == "":
            report.ko(rel, f"frontmatter '{key}:' has no value ('{raw}' resolves to empty)")
            continue
        if key == "name":
            name = value
    for key in ("name", "description"):
        if not any(line.startswith(key + ":") for line in fm):
            report.ko(rel, f"frontmatter has no '{key}:' line")
    directory = rel.split("/")[-2] if "/" in rel else ""
    if not one and name and name != directory:
        report.ko(rel, f"frontmatter name '{name}' does not match its directory '{directory}'")
    if report.failed == before:
        report.ok(f"{rel}: frontmatter names '{name}' with a one-line description")
