"""Bash's ``printf '%q'``, for the names a refusal prints.

A pathname is attacker-shaped data: a newline in one would forge a second diagnostic line, and an
escape sequence would reach the operator's terminal. The shell helper printed every such name as
``printf '%q'`` renders it, and the suites compare the refusal against that rendering, so this is
bash 5's algorithm rather than ``shlex.quote``:

- the empty string is ``''``;
- a string holding any character the locale does not print is ANSI-C quoted, ``$'...'``, with
  ``\\a \\b \\E \\f \\n \\r \\t \\v``, ``\\\\`` and ``\\'`` for those characters and a three-digit
  octal escape for every other unprintable byte;
- anything else is backslash-escaped character by character: the shell's metacharacters, blanks
  and quotes, a ``#`` that opens the word, and a ``~`` that opens it or follows ``:`` or ``=``.

"Printable" is the locale's, as bash reads it from LC_ALL, LC_CTYPE and LANG: under a UTF-8 locale
a printable non-ASCII character passes through as itself, while under any other locale every byte
past ASCII is unprintable and is escaped in octal.
"""

import os
import unicodedata
from collections.abc import Mapping

# bash 5's sh_backslash_quote table (lib/sh/shquote.c, bstab): blanks, quotes, and every
# character that is special to the shell's lexer, globbing or expansion.
_BACKSLASHED = frozenset(b" \t\n!\"$&'()*,;<>?[\\]^`{|}")

# ansic_quote's named escapes.
_NAMED = {
    0x1B: b"E",
    0x07: b"a",
    0x0B: b"v",
    0x08: b"b",
    0x0C: b"f",
    0x0A: b"n",
    0x0D: b"r",
    0x09: b"t",
    0x5C: b"\\",
    0x27: b"'",
}


def utf8_locale(env: Mapping[str, str] | None = None) -> bool:
    """Whether the locale bash would run under has a UTF-8 character set."""
    environ: Mapping[str, str] = os.environ if env is None else env
    for name in ("LC_ALL", "LC_CTYPE", "LANG"):
        value = environ.get(name, "")
        if value:
            lowered = value.lower()
            return "utf-8" in lowered or "utf8" in lowered
    return False


def _printable_ascii(byte: int) -> bool:
    return 0x20 <= byte <= 0x7E


def _char_at(data: bytes, i: int) -> tuple[str, int] | None:
    """The UTF-8 character starting at ``data[i]`` and its length, or None when it is invalid."""
    lead = data[i]
    if lead >= 0xF0:
        length = 4
    elif lead >= 0xE0:
        length = 3
    elif lead >= 0xC0:
        length = 2
    else:
        return None
    try:
        return data[i : i + length].decode("utf-8"), length
    except UnicodeDecodeError:
        return None


def _printable_char(ch: str) -> bool:
    return unicodedata.category(ch)[0] != "C" and ch not in (" ", " ")


def _needs_ansi(data: bytes, utf8: bool) -> bool:
    i = 0
    while i < len(data):
        byte = data[i]
        if byte < 0x80:
            if not _printable_ascii(byte):
                return True
            i += 1
            continue
        if not utf8:
            return True
        char = _char_at(data, i)
        if char is None or not _printable_char(char[0]):
            return True
        i += char[1]
    return False


def _ansi(data: bytes, utf8: bool) -> bytes:
    out = bytearray(b"$'")
    i = 0
    while i < len(data):
        byte = data[i]
        if byte in _NAMED:
            out += b"\\" + _NAMED[byte]
            i += 1
            continue
        if byte < 0x80:
            if _printable_ascii(byte):
                out.append(byte)
            else:
                out += b"\\%03o" % byte
            i += 1
            continue
        char = _char_at(data, i) if utf8 else None
        if char is not None and _printable_char(char[0]):
            out += data[i : i + char[1]]
            i += char[1]
            continue
        out += b"\\%03o" % byte
        i += 1
    out += b"'"
    return bytes(out)


def _backslash(data: bytes) -> bytes:
    out = bytearray()
    for i, byte in enumerate(data):
        if byte in _BACKSLASHED:
            out.append(0x5C)
        elif byte == 0x23 and i == 0:  # a comment character opening the word
            out.append(0x5C)
        elif byte == 0x7E and (i == 0 or data[i - 1] in b":="):  # a tilde bash would expand
            out.append(0x5C)
        out.append(byte)
    return bytes(out)


# SHARED-CANDIDATE: printf %q (post-merge-cleanup.sh's refusals; any port that prints a name)
def bash_q(text: str, *, utf8: bool | None = None) -> str:
    """``printf '%q' text`` as bash 5 prints it, under the current (or the given) locale."""
    data = text.encode("utf-8", "surrogateescape")
    if not data:
        return "''"
    in_utf8 = utf8_locale() if utf8 is None else utf8
    quoted = _ansi(data, in_utf8) if _needs_ansi(data, in_utf8) else _backslash(data)
    return quoted.decode("utf-8", "surrogateescape")
