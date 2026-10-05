"""A fake command-line tool first on PATH, for the package's unit tests.

``FakeTool("gh")`` writes an executable ``gh`` into a scratch directory. Each run appends its argv
to a log and answers with the next scripted ``Answer`` (the last one repeats), so a test drives
the code under test the way the shell suites' fixtures drive pr-review.sh: through the binary,
never by patching the Python. Use it as a context manager; it puts its directory first on PATH
for the duration and removes it afterwards.
"""

import json
import os
import shutil
import sys
import tempfile
from dataclasses import dataclass
from types import TracebackType
from typing import Self

_PROGRAM = """\
import json, os, sys
here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "calls.jsonl"), "a", encoding="utf-8") as log:
    log.write(json.dumps(sys.argv[1:]) + "\\n")
with open(os.path.join(here, "calls.jsonl"), encoding="utf-8") as log:
    n = sum(1 for _ in log) - 1
with open(os.path.join(here, "script.json"), encoding="utf-8") as f:
    answers = json.load(f)
a = answers[min(n, len(answers) - 1)]
sys.stdout.write(a["stdout"])
sys.stderr.write(a["stderr"])
sys.exit(a["rc"])
"""


@dataclass(frozen=True)
class Answer:
    rc: int = 0
    stdout: str = ""
    stderr: str = ""


class FakeTool:
    def __init__(self, name: str = "gh") -> None:
        self.name = name
        self.dir = os.path.realpath(tempfile.mkdtemp(prefix=f"ludics-fake-{name}."))
        path = os.path.join(self.dir, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(f"#!{sys.executable}\n{_PROGRAM}")
        os.chmod(path, 0o755)
        self._saved_path: str | None = None
        self.script(Answer())

    def script(self, *answers: Answer) -> None:
        """Answer the next calls with ``answers`` in order; the last repeats. Resets the log."""
        with open(os.path.join(self.dir, "script.json"), "w", encoding="utf-8") as f:
            json.dump([{"rc": a.rc, "stdout": a.stdout, "stderr": a.stderr} for a in answers], f)
        log = os.path.join(self.dir, "calls.jsonl")
        if os.path.exists(log):
            os.remove(log)

    def calls(self) -> list[list[str]]:
        log = os.path.join(self.dir, "calls.jsonl")
        if not os.path.exists(log):
            return []
        with open(log, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]

    def __enter__(self) -> Self:
        self._saved_path = os.environ.get("PATH")
        os.environ["PATH"] = self.dir + os.pathsep + (self._saved_path or "")
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc: BaseException | None,
        tb: TracebackType | None,
    ) -> None:
        if self._saved_path is None:
            os.environ.pop("PATH", None)
        else:
            os.environ["PATH"] = self._saved_path
        shutil.rmtree(self.dir, ignore_errors=True)
