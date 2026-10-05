"""An interactive ``git update-ref --stdin`` transaction.

``prepare`` takes the ref and reflog locks, the helper retains what the reflog reaches while they
are held, and only then sends ``commit`` -- so there is no window between the retention and the
deletion for the reflog to change in. The commands go down a pipe; the responses land in a
REGULAR FILE that is polled, never a pipe or a FIFO: a native Git for Windows opened an MSYS2 FIFO,
read nothing from it and exited 0 having done nothing (ludics-lite#287), and the suite holds every
transaction to a response channel that is neither (test_ref_transactions_answer_into_a_regular_file).

Closing the input ends the transaction: after ``commit`` Git exits, and before it Git reads EOF
and aborts, releasing every lock ``prepare`` took. Either way the helper waits for it, so no lock
outlives the call. A transaction is aborted by closing its input, never by a signal.
"""

import os
import subprocess
import sys
import time

from ludics.postmergecleanup import system

POLL_SECONDS = 0.02


class RefTransaction:
    """One transaction. ``open`` starts it; the owner keeps the object from before ``open`` so
    that a refusal at any later point still discards whatever ``open`` created."""

    def __init__(self, checkout: str, what: str) -> None:
        self.checkout = checkout
        self.what = what
        self.directory = ""
        self.output = ""
        self.proc: subprocess.Popen[bytes] | None = None
        self.reader: int | None = None
        self.pending = b""

    def open(self, temp_root: str) -> str | None:
        """Start Git; the refusal when it could not be started, else None."""
        what = self.what
        directory = system.mktemp_dir(f"{temp_root}/ship-pr-ref-transaction.XXXXXX")
        if directory is None:
            return f"could not allocate the {what} transaction"
        self.directory = directory
        self.output = f"{directory}/output"
        if not system.write_file(self.output, ""):
            return f"could not create the {what} transaction output"
        try:
            self.reader = os.open(self.output, os.O_RDONLY)
        except OSError:
            return f"could not open the {what} transaction output"
        exe = system.git_executable()
        if exe is None:
            return f"could not start the {what} transaction"
        sys.stdout.flush()
        sys.stderr.flush()
        try:
            # Appending: the reader polls the same file, and an append never truncates under it.
            with open(self.output, "ab") as answers:
                self.proc = subprocess.Popen(
                    [*exe, "-C", self.checkout, "update-ref", "--stdin"],
                    stdin=subprocess.PIPE,
                    stdout=answers,
                )
        except OSError:
            return f"could not start the {what} transaction"
        return None

    def send(self, text: str) -> bool:
        """Write commands down the transaction's input; False when Git no longer reads it."""
        if self.proc is None or self.proc.stdin is None:
            return False
        try:
            self.proc.stdin.write(system.encode(text))
            self.proc.stdin.flush()
        except OSError:
            return False
        return True

    def exited(self) -> bool:
        return self.proc is None or self.proc.poll() is not None

    def _take_line(self) -> str | None:
        cut = self.pending.find(b"\n")
        if cut < 0:
            return None
        line, self.pending = self.pending[:cut], self.pending[cut + 1 :]
        return system.decode(line)

    def _drain(self) -> None:
        if self.reader is None:
            return
        while True:
            chunk = os.read(self.reader, 1 << 16)
            if not chunk:
                return
            self.pending += chunk

    def response(self) -> tuple[bool, str]:
        """Git's next complete response line, as (True, line); (False, what partial line there
        was) once Git has exited without one. A partial line is kept across polls, since Git may
        be caught mid-write."""
        while True:
            self._drain()
            line = self._take_line()
            if line is not None:
                return True, line
            if self.exited():
                self._drain()
                line = self._take_line()
                if line is not None:
                    return True, line
                partial = system.decode(self.pending)
                self.pending = b""
                return False, partial
            time.sleep(POLL_SECONDS)

    def end(self) -> None:
        """Close the input and wait for Git to exit."""
        if self.proc is not None:
            if self.proc.stdin is not None and not self.proc.stdin.closed:
                try:
                    self.proc.stdin.close()
                except OSError:
                    pass
            self.proc.wait()
        if self.reader is not None:
            os.close(self.reader)
            self.reader = None

    def status(self) -> int:
        if self.proc is None or self.proc.returncode is None:
            return 1
        return system.status_of(self.proc.returncode)

    def discard(self) -> None:
        """End the transaction and remove its files, quietly: the abort path."""
        self.end()
        if self.output:
            system.unlink(self.output)
        if self.directory:
            system.rmdir(self.directory)

    def finish(self) -> str | None:
        """End a committed transaction; the refusal when it did not succeed or its files could not
        be removed, else None."""
        self.end()
        status = self.status()
        if status != 0:
            return f"the {self.what} transaction failed (git exit {status})"
        if not system.unlink(self.output):
            return f"could not remove the {self.what} transaction output"
        if not system.rmdir(self.directory):
            return f"could not remove the {self.what} transaction directory"
        return None

