"""The checked root, and the verdict lines every check writes.

``Tree`` is the root and its lookups, by root-relative BYTE-STRING path (see ``bytes_view``).
``Report`` keeps the pass and fail counts and prints each verdict as the shell did: ``ok: <text>``,
``FAIL: <file>: <message>``, and under GitHub Actions the ``::error file=<file>::<message>``
annotation beside it.
"""

import glob
import os
from dataclasses import dataclass

from ludics import cli
from ludics.checkprompts.bytes_view import is_file, lat, read_bytes, read_text, u


@dataclass(frozen=True)
class Tree:
    root: str  # the canonical root, as an ordinary (filesystem) string

    def path(self, rel: str) -> str:
        return os.path.join(self.root, u(rel)) if rel else self.root

    def is_file(self, rel: str) -> bool:
        return is_file(self.path(rel))

    def is_link(self, rel: str) -> bool:
        return os.path.islink(self.path(rel))

    def read(self, rel: str) -> str | None:
        return read_text(self.path(rel))

    def read_bytes(self, rel: str) -> bytes | None:
        return read_bytes(self.path(rel))

    def names(self, rel: str) -> list[str] | None:
        """Every entry of the directory but ``.`` and ``..``, or None when it cannot be listed."""
        try:
            return [lat(n) for n in os.listdir(self.path(rel))]
        except OSError:
            return None

    def glob(self, pattern: str) -> list[str]:
        """A shell glob under the root, sorted as bash sorts it under C (byte order): `*` skips a
        name with a leading dot unless the pattern spells the dot. Like an unquoted shell glob
        followed by `[ -e ]`, a pattern that matches nothing yields nothing."""
        found = glob.glob(pattern, root_dir=self.root)
        return sorted(lat(p) for p in found)

    def files(self, *patterns: str) -> list[str]:
        """``for f in <patterns>; do [ -f "$f" ] && echo "$f"; done``: each pattern's matches in
        its own sorted order, the patterns in the order given, regular files (followed) only."""
        out: list[str] = []
        for pattern in patterns:
            out.extend(rel for rel in self.glob(pattern) if self.is_file(rel))
        return out


@dataclass
class Report:
    actions: bool
    passed: int = 0
    failed: int = 0

    def ok(self, text: str) -> None:
        self.passed += 1
        cli.say("ok: " + u(text))

    def ko(self, file: str, message: str) -> None:
        """A failure on ``file`` (root-relative, for the annotation). Both are byte strings."""
        self.failed += 1
        cli.say(f"FAIL: {u(file)}: {u(message)}")
        if self.actions:
            cli.say(f"::error file={u(file)}::{u(message)}")
