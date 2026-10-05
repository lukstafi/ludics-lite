"""``[[:space:]]`` as the shell's body checks read it: the C library's own class under the caller's
LC_CTYPE, not a fixed list (ludics-lite#403).

The shell's ``${body//[[:space:]]/}`` and ``${body%"${body##*[![:space:]]}"}`` matched through
bash, which asks the C library: ``iswspace`` per character in a UTF-8 locale, ``isspace`` per byte
in a single-byte one, and ``isspace`` on the byte for a byte that is not valid UTF-8 (bash 3.2 trims
a lone 0xA0 under en_US.UTF-8 on macOS). So under en_US.UTF-8 a body of only U+00A0, U+2003 or
U+3000 was empty, and '@codex review' followed by U+00A0 was the bare nudge; under the C locale
neither was. The C locale's six are whitespace everywhere.

The locale this reads is the C library's LC_CTYPE, which Python sets from the environment at
startup. scripts/py turns off Python's C-locale coercion (PYTHONCOERCECLOCALE=0) so that a caller
running in the C locale is read as the C locale, and not as the C.UTF-8 Python would coerce it to.

Boundary: one character (or, in a single-byte locale, one byte) at a time. Not reproduced: bash
3.2's matching of a string that MIXES invalid bytes with multibyte whitespace, which bash itself
answers inconsistently between its two expansions. Where the C library cannot be reached (a native
Windows interpreter), only the C locale's six count.
"""

import ctypes
import locale
import sys
from collections.abc import Callable
from dataclasses import dataclass
from functools import cache

C_SPACE = " \t\n\r\f\v"


@dataclass(frozen=True)
class _Classes:
    """The C library's two tests, and whether the locale's codeset is UTF-8."""

    wide: Callable[[int], bool]
    byte: Callable[[int], bool]
    utf8: bool


def _c_locale_only() -> _Classes:
    return _Classes(lambda code: chr(code) in C_SPACE, lambda b: chr(b) in C_SPACE, True)


@cache
def _classes() -> _Classes:
    if sys.platform == "win32":
        return _c_locale_only()
    try:
        libc = ctypes.CDLL(None)
        iswspace = libc.iswspace
        isspace = libc.isspace
        codeset = locale.nl_langinfo(locale.CODESET)
    except (OSError, AttributeError, ValueError):
        return _c_locale_only()
    iswspace.argtypes = [ctypes.c_uint32]
    iswspace.restype = ctypes.c_int
    isspace.argtypes = [ctypes.c_int]
    isspace.restype = ctypes.c_int
    utf8 = codeset.replace("-", "").replace("_", "").upper() == "UTF8"
    return _Classes(lambda code: iswspace(code) != 0, lambda b: isspace(b) != 0, utf8)


def _char_space(classes: _Classes, ch: str) -> bool:
    if ch in C_SPACE:
        return True
    code = ord(ch)
    # A byte that was not valid UTF-8 arrives as a lone surrogate (surrogateescape).
    if 0xDC80 <= code <= 0xDCFF:
        return classes.byte(code - 0xDC00)
    if code < 0x80:
        return classes.byte(code)
    return classes.wide(code)


def blank(text: str) -> bool:
    """``[ -z "${text//[[:space:]]/}" ]``: nothing in the text but whitespace."""
    classes = _classes()
    if classes.utf8:
        return all(_char_space(classes, ch) for ch in text)
    return all(classes.byte(b) for b in text.encode("utf-8", "surrogateescape"))


def rstrip(text: str) -> str:
    """``${text%"${text##*[![:space:]]}"}``: the text without its trailing whitespace."""
    classes = _classes()
    if classes.utf8:
        end = len(text)
        while end and _char_space(classes, text[end - 1]):
            end -= 1
        return text[:end]
    data = text.encode("utf-8", "surrogateescape")
    stop = len(data)
    while stop and classes.byte(data[stop - 1]):
        stop -= 1
    return data[:stop].decode("utf-8", "surrogateescape")
