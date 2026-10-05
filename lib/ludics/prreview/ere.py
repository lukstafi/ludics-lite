"""POSIX extended regular expressions, as ``grep -E`` reads the advisory list, translated to ``re``.

The shell asked grep itself (``is_advisory``, ``ere_valid``); the port reads the same patterns with
Python's ``re``, so it needs a translation, and a translation is only honest about the patterns it
understands. BOUNDARY, as a fail-closed allowlist: what translates is the ERE that GNU grep (Linux)
and BSD grep 2.6 (macOS) both accept AND read the same way --

  literals; ``.``; ``^`` and ``$`` (anchors wherever they stand); ``(...)`` groups, ``()`` included;
  ``|`` between non-empty branches; ``*``, ``+``, ``?`` and ``{m}``, ``{m,}``, ``{m,n}`` (n <= 255)
  after an atom; a ``{`` not followed by a digit as a literal; bracket expressions with ranges,
  a leading ``^``, a leading or trailing ``-``, a leading ``]``, the twelve ``[:class:]`` names and
  single-character ``[=x=]`` / ``[.x.]``; ``\\1``..``\\9`` naming a group already closed; the
  GNU-and-BSD escapes ``\\w \\W \\s \\S \\< \\>``; and a backslash before punctuation, which is
  that character.

Everything else is REFUSED (``translate`` returns None), even where one of the two greps accepts it:
a repetition with nothing before it (``*a``, ``(+a)``), two repetitions in a row (``a**``, ``a+?``),
an empty branch beside a ``|``, an unmatched ``)``, a trailing backslash, and a backslash before a
letter or digit outside the list above (``\\d`` is a digit to BSD grep and a ``d`` to GNU grep;
BSD grep's ``\\b`` matches inside ``-``, GNU grep's does not).
Character classes and the word escapes are ASCII, as grep reads them in the C locale; ``.`` is
one character, as grep reads it in a UTF-8 locale.

For the repository's advisory file a refusal is a configuration error (exit 2), and for the
variable a pattern that matches nothing -- in both cases the stricter gate, never a guess.
"""

import re

_RE_DUP_MAX = 255

_CLASSES = {
    "alpha": "a-zA-Z",
    "digit": "0-9",
    "alnum": "a-zA-Z0-9",
    "upper": "A-Z",
    "lower": "a-z",
    "space": " \\t\\n\\r\\f\\v",
    "blank": " \\t",
    "punct": re.escape("!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~"),
    "print": " -~",
    "graph": "!-~",
    "cntrl": "\\x00-\\x1f\\x7f",
    "xdigit": "0-9A-Fa-f",
}

_ESCAPES = {
    "w": r"\w",
    "W": r"\W",
    "s": r"\s",
    "S": r"\S",
    "<": r"\b(?=\w)",
    ">": r"\b(?<=\w)",
}


class _Refused(Exception):
    pass


class _Parser:
    def __init__(self, pattern: str) -> None:
        self.p = pattern
        self.i = 0
        self.groups_open = 0
        self.groups_closed = 0

    def peek(self) -> str:
        return self.p[self.i] if self.i < len(self.p) else ""

    def ere(self, depth: int) -> str:
        branches = [self.branch(depth)]
        while self.peek() == "|":
            self.i += 1
            branches.append(self.branch(depth))
        if len(branches) > 1 and any(b == "" for b in branches):
            raise _Refused
        return "|".join(branches)

    def branch(self, depth: int) -> str:
        out: list[str] = []
        repeatable = False
        while self.i < len(self.p):
            c = self.peek()
            if c == "|":
                break
            if c == ")":
                if depth == 0:
                    raise _Refused  # GNU refuses an unmatched ), BSD reads it as a literal
                break
            if c in "*+?" or (c == "{" and self._interval_ahead()):
                if not repeatable:
                    raise _Refused
                out.append(self.repetition())
                repeatable = False
                continue
            atom, repeatable = self.atom(depth)
            out.append(atom)
        return "".join(out)

    def _interval_ahead(self) -> bool:
        return self.i + 1 < len(self.p) and self.p[self.i + 1].isdigit()

    def repetition(self) -> str:
        c = self.peek()
        if c in "*+?":
            self.i += 1
            return c
        m = re.compile(r"\{([0-9]+)(,([0-9]*))?\}").match(self.p, self.i)
        if m is None:
            raise _Refused
        low = int(m.group(1))
        if m.group(2) is None:
            text = f"{{{low}}}"
            high = low
        elif m.group(3) == "":
            text = f"{{{low},}}"
            high = low
        else:
            high = int(m.group(3))
            text = f"{{{low},{high}}}"
        if low > _RE_DUP_MAX or high > _RE_DUP_MAX or high < low:
            raise _Refused
        self.i = m.end()
        return text

    def atom(self, depth: int) -> tuple[str, bool]:
        """One atom, and whether a repetition may follow it."""
        c = self.peek()
        self.i += 1
        if c == "(":
            self.groups_open += 1
            inner = self.ere(depth + 1)
            if self.peek() != ")":
                raise _Refused
            self.i += 1
            self.groups_closed += 1
            return f"({inner})", True
        if c == "^":
            return "^", False
        if c == "$":
            return r"\Z", False
        if c == ".":
            return ".", True
        if c == "[":
            return self.bracket(), True
        if c == "\\":
            if self.i >= len(self.p):
                raise _Refused
            e = self.p[self.i]
            self.i += 1
            if e in "123456789":
                if int(e) > self.groups_closed:
                    raise _Refused
                return f"(?:\\{e})", True
            if e in _ESCAPES:
                return _ESCAPES[e], e not in "<>"
            if e.isalnum() or e == "_":
                raise _Refused
            return re.escape(e), True
        return re.escape(c), True

    def bracket(self) -> str:
        negate = False
        if self.peek() == "^":
            negate = True
            self.i += 1
        items: list[str] = []
        first = True
        while True:
            if self.i >= len(self.p):
                raise _Refused
            c = self.p[self.i]
            if c == "]" and not first:
                self.i += 1
                break
            first = False
            start, start_is_char = self.bracket_term()
            if (
                self.peek() == "-"
                and self.i + 1 < len(self.p)
                and self.p[self.i + 1] != "]"
            ):
                self.i += 1
                end, end_is_char = self.bracket_term()
                if not (start_is_char and end_is_char) or ord(start) > ord(end):
                    raise _Refused
                items.append(_class_char(start) + "-" + _class_char(end))
            elif start_is_char:
                items.append(_class_char(start))
            else:
                items.append(start)
        if not items:
            raise _Refused
        return "[" + ("^" if negate else "") + "".join(items) + "]"

    def bracket_term(self) -> tuple[str, bool]:
        """One bracket term: (a character, True) or (a class's members, False)."""
        if self.p.startswith("[:", self.i):
            end = self.p.find(":]", self.i + 2)
            if end < 0:
                raise _Refused
            name = self.p[self.i + 2 : end]
            if name not in _CLASSES:
                raise _Refused
            self.i = end + 2
            return _CLASSES[name], False
        for opener, closer in (("[=", "=]"), ("[.", ".]")):
            if self.p.startswith(opener, self.i):
                end = self.p.find(closer, self.i + 2)
                if end < 0 or end != self.i + 3:
                    raise _Refused  # multi-character collating elements are not read
                ch = self.p[self.i + 2]
                self.i = end + 2
                return ch, True
        ch = self.p[self.i]
        self.i += 1
        return ch, True


def _class_char(c: str) -> str:
    return "\\" + c if c in "\\]^-[" else c


def translate(pattern: str) -> str | None:
    """The ``re`` source for an ERE inside the boundary above, or None for one outside it."""
    parser = _Parser(pattern)
    try:
        out = parser.ere(0)
    except _Refused:
        return None
    if parser.i != len(pattern):
        return None
    try:
        re.compile(out, re.ASCII)
    except re.error:
        return None
    return out


def compile_ere(pattern: str) -> re.Pattern[str] | None:
    """``translate``, compiled; None for a pattern outside the boundary."""
    src = translate(pattern)
    return None if src is None else re.compile(src, re.ASCII)
