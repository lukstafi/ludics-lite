"""The workflow-file readers `base` settles a tip's absence with, ported from pr-review.sh.

Two narrow state machines over a workflow file's text, and the path-filter translation:

  workflow_filter  ``WORKFLOW_YAML_FILTER``: the items of ``on: <want>: <seq>``
  workflow_keys    ``WORKFLOW_KEYS``: the keys at one level of the ``on:`` block
  glob_ere         ``glob_ere``: one GitHub path filter as an anchored regular expression
  paths_ignore_covers ``paths_ignore_covers``: every changed path matches some pattern

Every one of them REFUSES (returns None or False) rather than guesses, for the reason the shell's
comments give at length: a refusal costs the absence grace, a guess settles for an older green
over an unbuilt tip. The shell ran the two readers as awk programs; these are line-for-line ports
of those programs, including where awk's semantics are unusual (``split`` of an empty string
yields nothing; ``exit`` inside a rule still runs the END block). ``head_within_paths_ignore``
(``checks``/``merge``, ludics-lite#176) reads files with the same two programs, so all four are
shared candidates.
"""

import re
from dataclasses import dataclass

_IDENT = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*")
_IDENT_KEY = re.compile(r"[A-Za-z_][A-Za-z0-9_-]*[ ]*:")
_ON_KEY = re.compile(r'(on|"on")[ ]*:')
_FLOW = re.compile(r"\[.*\]")


def _ind_of(s: str) -> int:
    """awk ``ind_of``: the index of the first non-space, or -1."""
    for i, c in enumerate(s):
        if c != " ":
            return i
    return -1


def _unquote(s: str) -> str:
    """awk ``unquote``: trim spaces, then drop ONE matching pair of quotes around the whole."""
    s = s.strip(" ")
    if len(s) >= 2 and s[0] in ("'", '"') and s[-1] == s[0]:
        s = s[1:-1]
    return s


def _awk_split(s: str) -> list[str]:
    """awk ``split(s, parts, ",")``: an EMPTY string has no fields at all."""
    return [] if s == "" else s.split(",")


@dataclass(frozen=True)
class _Line:
    ind: int
    key: str
    rest: str


def _lines(text: str) -> list[_Line] | None:
    """The records both programs read, preprocessed as their shared main rule does: trailing
    spaces and CRs dropped, empty lines and comment lines skipped. None for a file holding a TAB
    anywhere (the programs' first rule refuses it before anything else is read)."""
    out: list[_Line] = []
    for raw in text.split("\n"):
        if "\t" in raw:
            return None
        line = re.sub(r"[ \r]+$", "", raw)
        if line == "":
            continue
        ind = _ind_of(line)
        key = line[ind:]
        if key.startswith("#"):
            continue
        rest = re.sub(r"^[^:]*:", "", key, count=1)
        rest = re.sub(r"^[ ]+", "", rest, count=1)
        rest = re.sub(r"[ ]+#.*$", "", rest, count=1)
        out.append(_Line(ind, key, rest))
    return out


def _no_value(rest: str) -> bool:
    """A key with nothing after its colon but (perhaps) a comment."""
    return rest == "" or rest.startswith("#")


# SHARED-CANDIDATE: WORKFLOW_YAML_FILTER
def workflow_filter(text: str, want: str, seq: str) -> list[str] | None:
    """The items of ``on: <want>: <seq>`` in a workflow file, or None when they cannot be
    established (the file does not parse this narrowly, or the key is not there). ``want`` and
    ``seq`` are matched as the awk program matched them: as regular expressions anchored at the
    key's start."""
    lines = _lines(text)
    if lines is None:
        return None
    want_re = re.compile("^" + want + "[ ]*:")
    seq_re = re.compile("^" + seq + "[ ]*:")
    pats: list[str] = []
    state = 0
    on_ind = push_ind = seq_ind = 0
    ok = False
    bad = False

    def emit(item: str) -> bool:
        item = _unquote(item)
        if item == "":
            return False
        pats.append(item)
        return True

    for ln in lines:
        if state == 0:
            if ln.ind == 0 and _ON_KEY.match(ln.key):
                if not _no_value(ln.rest):
                    bad = True
                    break
                state, on_ind = 1, ln.ind
            continue
        if state == 1:
            if ln.ind <= on_ind:
                bad = True
                break
            if want_re.search(ln.key):
                if not _no_value(ln.rest):
                    bad = True
                    break
                state, push_ind = 2, ln.ind
            continue
        if state == 2:
            if ln.ind <= push_ind:
                bad = True
                break
            if seq_re.search(ln.key):
                if ln.rest == "":
                    state, seq_ind = 3, ln.ind
                    continue
                if _FLOW.fullmatch(ln.rest):
                    for part in _awk_split(ln.rest[1:-1]):
                        if not emit(part):
                            bad = True
                            break
                    else:
                        ok = True
                    break
                bad = True
                break
            continue
        # state 3: the block sequence's items
        if ln.key == "-" or ln.key.startswith("- "):
            if not emit(ln.key[1:]):
                bad = True
                break
            continue
        if ln.ind <= seq_ind:
            ok = True
            break
        bad = True
        break
    if state == 3 and not bad:
        ok = True
    if bad or not ok or not pats:
        return None
    return pats


# SHARED-CANDIDATE: WORKFLOW_KEYS
def workflow_keys(text: str, want: str = "") -> list[str] | None:
    """The keys a workflow file declares at one level of its ``on:`` block: the trigger events
    (``want`` empty), or the keys under the event ``want``. None when they cannot be established.
    Under a named event no keys at all is an answer (an empty list); at the ``on:`` level it is
    not, since a workflow with no trigger is a file this has misread."""
    lines = _lines(text)
    if lines is None:
        return None
    keys: list[str] = []
    state = 0
    on_ind = want_ind = 0
    ev_ind = kw_ind = -1
    ok = False
    bad = False

    def emit(item: str) -> bool:
        item = _unquote(item)
        if not _IDENT.fullmatch(item):
            return False
        keys.append(item)
        return True

    def key_name(key: str) -> str:
        return re.sub(r"[ ]*:.*$", "", key, count=1)

    for ln in lines:
        if state == 0:
            if ln.ind == 0 and _ON_KEY.match(ln.key):
                on_ind = ln.ind
                if ln.rest == "":
                    state = 1
                    continue
                # `on: push` and `on: [push, ...]` declare events and NOTHING under them.
                if _FLOW.fullmatch(ln.rest):
                    if want == "":
                        for part in _awk_split(ln.rest[1:-1]):
                            if not emit(part):
                                bad = True
                                break
                        else:
                            ok = True
                    else:
                        ok = True
                    break
                if want == "":
                    if not emit(ln.rest):
                        bad = True
                        break
                ok = True
                break
            continue
        if state == 1:
            if ln.ind <= on_ind:
                ok = True
                break
            if ev_ind < 0:
                ev_ind = ln.ind
            if ln.ind < ev_ind:
                bad = True
                break
            if ln.ind > ev_ind:
                continue
            if not _IDENT_KEY.match(ln.key):
                bad = True
                break
            k = key_name(ln.key)
            if want == "":
                if not emit(k):
                    bad = True
                    break
                continue
            if k == want:
                state, want_ind = 2, ln.ind
            continue
        # state 2: the keys under the named event
        if ln.ind <= want_ind:
            ok = True
            break
        if kw_ind < 0:
            kw_ind = ln.ind
        if ln.ind < kw_ind:
            bad = True
            break
        if ln.ind > kw_ind:
            continue
        if not _IDENT_KEY.match(ln.key):
            bad = True
            break
        if not emit(key_name(ln.key)):
            bad = True
            break
    if not bad and state in (1, 2):
        ok = True
    if bad or not ok:
        return None
    # An `on:` MAPPING that never reached the named event did not declare it.
    if want != "" and state == 1:
        return None
    if want == "" and not keys:
        return None
    return keys


_GLOB_CHARS = re.compile(r"[A-Za-z0-9._/*-]+")


# SHARED-CANDIDATE: glob_ere
def glob_ere(pattern: str) -> str | None:
    """One GitHub path filter as a regular expression anchored at both ends, or None for a
    pattern this translation does not carry: ``**`` is any run of characters, ``*`` any run within
    one path segment, and every other construct of the cheat sheet is refused, since each can only
    widen what counts as ignored."""
    if not _GLOB_CHARS.fullmatch(pattern):
        return None
    out: list[str] = []
    i = 0
    while i < len(pattern):
        c = pattern[i]
        if c == "*":
            if pattern[i : i + 2] == "**":
                out.append(".*")
                i += 2
                continue
            out.append("[^/]*")
        elif c == ".":
            out.append("\\.")
        else:
            out.append(c)
        i += 1
    return "^" + "".join(out) + "$"


# SHARED-CANDIDATE: paths_ignore_covers
def paths_ignore_covers(patterns: list[str], files: list[str]) -> bool:
    """Every changed path matches some pattern. EVERY pattern is translated before anything is
    matched, so one that does not translate fails the whole question rather than just itself."""
    pats = [p for p in patterns if p]
    paths = [f for f in files if f]
    if not pats or not paths:
        return False
    eres: list[re.Pattern[str]] = []
    for p in pats:
        ere = glob_ere(p)
        if ere is None:
            return False
        eres.append(re.compile(ere))
    return all(any(e.search(f) for e in eres) for f in paths)
