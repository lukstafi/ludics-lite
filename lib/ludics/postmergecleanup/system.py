"""What the helper asks of the system: Git as a binary, and the shell's file primitives.

Git is the binary on PATH, looked up at each call, so a suite's fake ``git`` first on PATH answers
exactly as it did for the shell; and every call keeps the argument list the shell sent, because
those fakes match on it. A call says where each stream goes, as the shell's redirections did:
``inherit`` (the helper's own stream, for Git's messages the operator reads), ``devnull`` or
``capture``. The environment is the process's own, which ``scrub_git_environment`` has already
cleared of every repository-selection variable, so hooks and every other child see what the shell
helper's children saw.

The file primitives are the shell's, one for one: ``noclobber_create`` is ``set -o noclobber;
printf … >file`` (an exclusive create), ``atomic_rename`` is the ``rename(2)`` the shell reached
through Perl (it replaces an empty directory or a file, and refuses a nonempty directory), and
``posix_dirname``/``posix_basename`` are dirname(1) and basename(1).
"""

import os
import secrets
import shutil
import stat
import string
import subprocess
import sys
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Literal

from ludics import cli
from ludics.proc import decode, substitution

PROG = "post-merge-cleanup.sh"

type Stream = Literal["inherit", "devnull", "capture"]


@dataclass(frozen=True)
class Done:
    """A finished Git call: its status, and its stdout when captured (else empty)."""

    rc: int
    out: str


def encode(text: str) -> bytes:
    return text.encode("utf-8", "surrogateescape")


def status_of(returncode: int) -> int:
    """A child's status as the shell's ``$?`` reports it: 128 + N for a death by signal N."""
    return 128 - returncode if returncode < 0 else returncode


def _redirect(stream: Stream) -> int | None:
    match stream:
        case "inherit":
            return None
        case "devnull":
            return subprocess.DEVNULL
        case "capture":
            return subprocess.PIPE


def git_executable() -> str | None:
    return shutil.which("git")


# SHARED-CANDIDATE: run_tool with stream redirections, stdin and env overrides (ludics.proc)
def git(
    *args: str,
    out: Stream = "inherit",
    err: Stream = "inherit",
    env: Mapping[str, str] | None = None,
    stdin: bytes | None = None,
) -> Done:
    """Run ``git args``; ``env`` adds to (does not replace) the process environment."""
    exe = git_executable()
    if exe is None:
        if err == "inherit":
            cli.note(PROG, "git: command not found")
        return Done(127, "")
    environ = None if env is None else {**os.environ, **env}
    sys.stdout.flush()
    sys.stderr.flush()
    try:
        proc = subprocess.run(
            [exe, *args],
            input=stdin,
            stdout=_redirect(out),
            stderr=_redirect(err),
            env=environ,
            check=False,
        )
    except OSError as error:
        if err == "inherit":
            cli.note(PROG, f"git: {error.strerror}")
        return Done(126, "")
    captured = decode(proc.stdout) if out == "capture" else ""
    return Done(status_of(proc.returncode), captured)


def nul_records(text: str) -> list[str]:
    """The records of a ``-z`` listing, as ``while IFS= read -r -d '' x`` reads them: each one
    NUL-terminated, and an unterminated tail is not a record."""
    return text.split("\0")[:-1]


def first_nul_record(text: str) -> str:
    """``IFS= read -r -d '' x``, once: the first record, or all of it when no NUL ends one."""
    return text.split("\0", 1)[0]


def first_token(text: str) -> str:
    """``${text%%[[:space:]]*}``: everything before the first whitespace character."""
    for i, char in enumerate(text):
        if char in " \t\n\v\f\r":
            return text[:i]
    return text


def read_fields(line: str, count: int) -> list[str]:
    """``read -r a b … rest <<<"$line"`` with the default IFS: ``count`` fields, the last one the
    remainder, missing ones empty."""
    fields: list[str] = []
    rest = line.strip(" \t\n")
    while len(fields) < count - 1 and rest:
        cut = next((i for i, c in enumerate(rest) if c in " \t\n"), len(rest))
        fields.append(rest[:cut])
        rest = rest[cut:].lstrip(" \t\n")
    fields.append(rest)
    while len(fields) < count:
        fields.append("")
    return fields


def has_nonzero(oid: str) -> bool:
    """``case "$oid" in *[!0]*)``: some character other than ``0`` -- not the null object id."""
    return any(c != "0" for c in oid)


def git_path_is_absolute(path: str) -> bool:
    """A path Git reported that is already rooted, so joining it to the checkout it was read from
    would name something else entirely. A leading slash is the POSIX root (and a ``//server``
    UNC spelling); a drive letter and a slash or backslash is Git for Windows, which reports a
    path read from a ``.git`` file, core.worktree or ``--git-common-dir`` in native form
    (``C:/Users/...``) even under Git Bash (ludics-lite#147). The drive letter is one ASCII
    letter, so ``AB:/x`` stays relative."""
    if path.startswith("/"):
        return True
    return (
        len(path) >= 3
        and path[0] in string.ascii_letters
        and path[1] == ":"
        and path[2] in "/\\"
    )


def posix_dirname(path: str) -> str:
    stripped = path.rstrip("/")
    if not stripped:
        return "/" if path else "."
    cut = stripped.rfind("/")
    if cut < 0:
        return "."
    parent = stripped[:cut].rstrip("/")
    return parent or "/"


def posix_basename(path: str) -> str:
    stripped = path.rstrip("/")
    if not stripped:
        return "/" if path else ""
    return stripped[stripped.rfind("/") + 1 :]


def native_slashes(path: str) -> str:
    """Windows paths as Git spells them, with forward slashes; elsewhere the path itself."""
    return path.replace("\\", "/") if os.name == "nt" else path


def physical_directory(path: str) -> str | None:
    """``cd "$path" && pwd -P``: the directory's physical path, or None when it cannot be entered.
    The ``$(...)`` around it in the shell drops trailing newlines, and so does this."""
    try:
        resolved = os.path.realpath(path, strict=True)
    except (OSError, ValueError):
        return None
    if not os.path.isdir(resolved) or not os.access(resolved, os.X_OK):
        return None
    return substitution(native_slashes(resolved))


def lexists(path: str) -> bool:
    """``[ -e path ] || [ -L path ]``."""
    return os.path.lexists(path)


def is_link(path: str) -> bool:
    return os.path.islink(path)


def is_dir(path: str) -> bool:
    """``[ -d path ]``, which follows a symbolic link."""
    return os.path.isdir(path)


def is_file(path: str) -> bool:
    """``[ -f path ]``, which follows a symbolic link."""
    return os.path.isfile(path)


_TEMPLATE_ALPHABET = string.ascii_letters + string.digits


def _fill_template(template: str) -> str:
    if not template.endswith("XXXXXX"):
        raise ValueError(f"not a mktemp template: {template}")
    return template[:-6] + "".join(secrets.choice(_TEMPLATE_ALPHABET) for _ in range(6))


def mktemp_file(template: str) -> str | None:
    """``mktemp <template>``: a new empty file, mode 0600, at the template with its ``XXXXXX``
    filled; None when none could be created."""
    for _ in range(100):
        candidate = _fill_template(template)
        try:
            fd = os.open(candidate, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        except FileExistsError:
            continue
        except OSError:
            return None
        os.close(fd)
        return candidate
    return None


def mktemp_dir(template: str) -> str | None:
    """``mktemp -d <template>``: a new directory, mode 0700; None when none could be created."""
    for _ in range(100):
        candidate = _fill_template(template)
        try:
            os.mkdir(candidate, 0o700)
        except FileExistsError:
            continue
        except OSError:
            return None
        return candidate
    return None


def noclobber_create(path: str, content: str) -> bool:
    """``(set -o noclobber; printf '%s' content >path)``: create the file only if nothing is at the
    path -- not a file, not a dangling link -- and write ``content`` into it."""
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    except OSError:
        return False
    try:
        os.write(fd, encode(content))
    except OSError:
        return False
    finally:
        os.close(fd)
    return True


def write_file(path: str, content: str) -> bool:
    """``printf '%s' content >path``: create or truncate, then write."""
    try:
        with open(path, "wb") as handle:
            handle.write(encode(content))
    except OSError:
        return False
    return True


def first_line(path: str) -> str | None:
    """``$(sed -n '1p' path)``: the file's first line, or None when it cannot be read."""
    try:
        with open(path, "rb") as handle:
            line = handle.readline()
    except OSError:
        return None
    return substitution(decode(line))


def read_lines(path: str) -> list[str] | None:
    """``while IFS= read -r line || [ -n "$line" ]; do … done <path``: every line, the last one
    whether or not a newline ends it; None when the file cannot be read."""
    try:
        with open(path, "rb") as handle:
            data = decode(handle.read())
    except OSError as error:
        cli.note(PROG, f"{path}: {error.strerror}")
        return None
    lines = data.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def same_contents(a: str, b: str) -> bool:
    """``cmp -s a b``: both readable and byte-identical."""
    try:
        with open(a, "rb") as left, open(b, "rb") as right:
            while True:
                chunk_a = left.read(1 << 16)
                chunk_b = right.read(1 << 16)
                if chunk_a != chunk_b:
                    return False
                if not chunk_a:
                    return True
    except OSError:
        return False


def copy_preserving(source: str, target: str) -> bool:
    """``cp -p source target``: contents, mode and times."""
    try:
        shutil.copy2(source, target)
    except OSError:
        return False
    return True


def copy_contents(source: str, target: str) -> bool:
    """``cp source target`` onto a file that exists: the contents, the target keeping its mode."""
    try:
        shutil.copyfile(source, target)
    except OSError:
        return False
    return True


def copy_new(source: str, target: str) -> bool:
    """``cp source target`` to a new path: the contents and the source's mode."""
    try:
        shutil.copy(source, target)
    except OSError:
        return False
    return True


def unlink(path: str) -> bool:
    try:
        os.unlink(path)
    except OSError:
        return False
    return True


def rmdir(path: str) -> bool:
    try:
        os.rmdir(path)
    except OSError:
        return False
    return True


def mkdir(path: str) -> bool:
    try:
        os.mkdir(path)
    except OSError:
        return False
    return True


def hard_link(source: str, target: str) -> bool:
    try:
        os.link(source, target)
    except OSError as error:
        cli.note(PROG, f"{target}: {error.strerror}")
        return False
    return True


def remove_tree(path: str) -> bool:
    """``rm -rf -- path``, which never follows a link inside the tree and, under Git Bash, removes
    a read-only file as well."""

    def make_writable_and_retry(
        function: Callable[[str], object], target: str, error: BaseException
    ) -> None:
        if not isinstance(error, PermissionError) or os.name != "nt":
            raise error
        os.chmod(target, stat.S_IWRITE)
        function(target)

    try:
        shutil.rmtree(path, onexc=make_writable_and_retry)
    except OSError as error:
        cli.note(PROG, f"{path}: {error.strerror}")
        return False
    return True


def atomic_rename(source: str, target: str) -> OSError | None:
    """rename(2), as the shell reached it through Perl: an existing directory is not taken as a
    container -- an empty one is replaced and a nonempty one refuses -- so a same-user race on the
    target cannot nest the source below an attacker-created path while reporting success. A
    failure prints Perl's line (``<source> -> <target>: <error>``) and is returned."""
    try:
        os.replace(source, target)
    except OSError as error:
        sys.stdout.flush()
        sys.stderr.write(f"{source} -> {target}: {error.strerror}\n")
        sys.stderr.flush()
        return error
    return None


def list_entries(directory: str) -> list[str] | None:
    """The names in a directory, in the order the filesystem returns them; None on any error."""
    try:
        with os.scandir(directory) as entries:
            return [entry.name for entry in entries]
    except OSError:
        return None


def walk_non_directories(root: str) -> list[str] | None:
    """``find root ! -type d``: every entry under ``root`` that is not a directory -- a symbolic
    link to one included, since find does not follow links -- as a path under ``root``; None
    when any part of the tree could not be read, since a partial walk must clear nothing."""
    found: list[str] = []
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            with os.scandir(directory) as entries:
                for entry in entries:
                    path = f"{directory}/{entry.name}"
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(path)
                    else:
                        found.append(path)
        except OSError:
            return None
    return found


def chdir(path: str) -> bool:
    try:
        os.chdir(path)
    except OSError:
        return False
    return True
