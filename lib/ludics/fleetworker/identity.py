"""The coordinator's identity and lease token (fleet-worker.sh's ``coordinator_id``, ``check_identity``,
``token_file``, ``my_token``, ``gen_uuid``).

The identity is per SESSION, not per box: FLEET_COORDINATOR if set, else the harness identity
inherited as CLAUDE_CODE_SESSION_ID or CODEX_THREAD_ID. Nothing is guessed from the process tree --
a parent pid is shared by sibling tabs and changes under command substitution. Its token lives
under that identity, so a second coordinator session on the same box has no token and cannot pass
the gate, and a restarted coordinator (new session id) must adopt explicitly with ``claim --take``.
"""

import re
import uuid
from typing import NoReturn

from ludics import cli
from ludics.fleetworker.config import Config

PROG = "fleet-worker.sh"


# SHARED-CANDIDATE: die
def die(*parts: str) -> NoReturn:
    """``die``: ``fleet-worker.sh: <message>`` on stderr, exit 2."""
    cli.exit_with(2, *parts)


# SHARED-CANDIDATE: coordinator_id
def coordinator_id(cfg: Config) -> str:
    env = cfg.env
    if env.get("FLEET_COORDINATOR"):
        return env["FLEET_COORDINATOR"]
    if env.get("CLAUDE_CODE_SESSION_ID"):
        return "session-" + env["CLAUDE_CODE_SESSION_ID"]
    if env.get("CODEX_THREAD_ID"):
        return "codex-" + env["CODEX_THREAD_ID"]
    return ""


# SHARED-CANDIDATE: check_identity
def check_identity(cfg: Config) -> str:
    """The identity, which is used verbatim as the token file's name, so it must be injective: no
    folding of characters. Refuses (exit 2) when there is none or it is unsafe."""
    ident = coordinator_id(cfg)
    if not ident:
        die(
            "no coordinator identity: harness supplied neither CLAUDE_CODE_SESSION_ID",
            "nor CODEX_THREAD_ID -- set FLEET_COORDINATOR=<name> for this coordinator session",
        )
    if ident in (".", "..") or not re.fullmatch(r"[A-Za-z0-9._-]+", ident):
        die(f"coordinator identity '{ident}' must be [A-Za-z0-9._-]+ (set FLEET_COORDINATOR)")
    return ident


# SHARED-CANDIDATE: token_file
def token_file(cfg: Config) -> str:
    return f"{cfg.path(cfg.state)}/tokens/{coordinator_id(cfg)}"


# SHARED-CANDIDATE: my_token
def my_token(cfg: Config) -> str:
    """``cat "$(token_file)"``: the token, trailing newlines dropped; empty when unreadable."""
    try:
        with open(token_file(cfg), encoding="utf-8", errors="surrogateescape") as f:
            return f.read().rstrip("\n")
    except OSError:
        return ""


# SHARED-CANDIDATE: gen_uuid
def gen_uuid() -> str:
    """A fresh lowercase UUID: a halt's identity, a lease token."""
    return str(uuid.uuid4())
