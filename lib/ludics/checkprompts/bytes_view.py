"""The C-locale view of text that every reader in this package works on.

The shell checker ran under ``LC_ALL=C``: awk, sed and grep saw BYTES, so a length was a byte
count, ``[[:space:]]`` was the six ASCII blanks, ``tolower`` folded ASCII alone, and a byte past
0x7F was content, never a letter or a space. That reading is part of the contract (a Unicode space
in a name stays in the name; the slug reader recognises General Punctuation by its three UTF-8
bytes), so the port keeps it exactly: file contents are decoded as LATIN-1, one character per byte,
and every scan runs over that string. Nothing here ever treats such a string as Unicode text.

Paths are held the same way, so a path read off a link and a path read off the filesystem compare
as the bytes they are. ``u`` turns a byte string back into the ordinary string the streams and the
filesystem take (UTF-8, with surrogateescape for bytes that are not), and ``lat`` goes the other
way.
"""

import os
import re

# `[[:space:]]` in the C locale.
WS = " \t\n\v\f\r"
WS_CLASS = "[ \\t\\n\\v\\f\\r]"
WS_RUN = re.compile(WS_CLASS + "+")

_UPPER = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
_LOWER_TABLE = str.maketrans(_UPPER, _UPPER.lower())


def lat(s: str) -> str:
    """An ordinary (filesystem or argv) string as its byte string."""
    return s.encode("utf-8", "surrogateescape").decode("latin-1")


def u(s: str) -> str:
    """A byte string as the ordinary string that writes or names the same bytes."""
    return s.encode("latin-1").decode("utf-8", "surrogateescape")


def ascii_lower(s: str) -> str:
    """``tolower`` and ``tr '[:upper:]' '[:lower:]'`` under C: ASCII letters only."""
    return s.translate(_LOWER_TABLE)


def is_alnum(c: str) -> bool:
    """``c ~ /^[A-Za-z0-9]$/``: one ASCII letter or digit (the empty string is not one)."""
    return len(c) == 1 and ("a" <= c <= "z" or "A" <= c <= "Z" or "0" <= c <= "9")


def one_of(c: str, chars: str) -> bool:
    """Whether ``c`` is ONE character from ``chars`` -- ``"" in chars`` is true in Python, and an
    awk ``substr`` past the end is the empty string, which belongs to no bracket expression."""
    return len(c) == 1 and c in chars


def records(text: str) -> list[str]:
    """The lines awk (and sed, and grep) read: split on LF, with no empty record for the LF that
    ends the last line, and none at all for an empty file."""
    if not text:
        return []
    lines = text.split("\n")
    if lines[-1] == "":
        lines.pop()
    return lines


def ws_split(s: str) -> list[str]:
    """awk's ``split(s, a, /[[:space:]]+/)``: a leading or trailing blank run yields an empty field,
    and an empty string yields none."""
    return [] if s == "" else WS_RUN.split(s)


def read_bytes(path: str) -> bytes | None:
    try:
        with open(path, "rb") as f:
            return f.read()
    except OSError:
        return None


def read_text(path: str) -> str | None:
    """The file as a byte string, or None when it cannot be read."""
    data = read_bytes(path)
    return None if data is None else data.decode("latin-1")


def substitution(s: str) -> str:
    """What ``$(...)`` keeps of an output: every trailing newline dropped."""
    return s.rstrip("\n")


def is_file(path: str) -> bool:
    """``[ -f path ]``: a regular file, following symbolic links."""
    return os.path.isfile(path)
