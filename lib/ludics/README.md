# lib/ludics: the v2 rewrite's Python package

The core scripts are being ported to type-checked, standard-library-only Python 3.12, one script
(and for `pr-review.sh`, one subcommand) at a time, behind the command lines the skills already
call ([ludics-lite#403](https://github.com/lukstafi/ludics-lite/issues/403)). This file is for
porters: where code goes, how a subcommand is forwarded, and how to check it.

## The rules that do not bend

- **Standard library only.** No third-party imports, no `requirements.txt`, no build step.
- **Python 3.12 is the floor.** Nothing from 3.13 or later. `pyrightconfig.json` pins
  `pythonVersion` to 3.12, so pyright refuses a newer API even when the local interpreter has it
  (this Mac's is 3.14).
- **Strict pyright**, `reportMatchNotExhaustive` on. A sum type is a union of frozen dataclasses,
  matched with `match`, and every match over a union ends in `case _: assert_never(x)`. See
  `GhResult` in `prreview/core.py` and the match in `prreview/body.py`.
- **The command line is fixed.** Subcommands, flags, stdout lines, stderr wording that a suite
  or a skill reads, and exit codes stay exactly what the script did. The shell suites are the
  conformance suite: a port lands only when the script's existing suites pass unchanged against
  it, under `bash` 5 and `/bin/bash` 3.2.
- **External tools are binaries.** `gh` and `git` run through `ludics.proc.run_tool`, resolved
  on PATH, never replaced by an HTTP client, so the suites' fixtures drive the Python as they
  drove the shell.

## Layout

```
scripts/py                       the interpreter wrapper: the first Python >= 3.12, run as
                                 `-X utf8 -P` with PYTHONPATH=lib (scripts/test-py.sh)
lib/ludics/cli.py                shared by every entry point: Exit, main_guard, say/emit/note
lib/ludics/proc.py               run_tool and the shell bridge
lib/ludics/prreview/core.py      pr-review.sh's prelude: fail/die/warn, Config, GhSession
                                 (gh_retry and its classification), parse_ref/pr_arg,
                                 repo_from_cwd, api_list, mark_of
lib/ludics/prreview/<name>.py    one module per ported subcommand: run(session, args) -> int
lib/ludics/prreview/__main__.py  the dispatcher: `scripts/py -m ludics.prreview <name> ...`
lib/ludics/<script>/             the next script's package (e.g. checkprompts/, fleetworker/),
                                 with its own __main__.py
lib/ludics/tests/test_*.py       unittest suites (fake.py: a fake tool first on PATH)
```

A script other than `pr-review.sh` gets a sibling package, `lib/ludics/<script>/`, run as
`scripts/py -m ludics.<script>`; its shell file becomes the one-line forward (`exec "$(dirname
"$0")/../../scripts/py" -m ludics.<script> "$@"`, with the right number of `..`).

## Forwarding a pr-review.sh subcommand

`pr-review.sh` keeps every subcommand it has not ported. To port `<name>`:

1. Write `lib/ludics/prreview/<name>.py` with `run(session: GhSession, args: list[str]) -> int`,
   using the core (`session.retry`, `pr_arg`, `fail`/`die`, `cli.emit`). Return the exit status,
   or raise through `fail(rc, ...)`, which ends the command from any depth with
   `pr-review.sh: <message>` on stderr.
2. Add `case "<name>":` to `lib/ludics/prreview/__main__.py` (and the name to `PORTED` there).
3. In `ship-pr/scripts/pr-review.sh`: add the name to `PY_PORTED`, and reduce `cmd_<name>` to
   `cmd_<name>() { py_forward call <name> "$@"; }`. `main` then execs the Python for it; the stub
   serves callers that source the script (every fixture suite, and any shell function that still
   calls `cmd_<name>`).
4. Every source-time constant the Python reads goes into `PY_FORWARD_VARS` as
   `SHELLVAR=ENVNAME` (with `Config` reading `ENVNAME`), because a suite's `retune` and `main`'s
   `--repo` change the shell variable, not the environment. A constant whose being SET is itself
   meaningful (`SHIP_PR_ADVISORY_CHECKS`) needs a private environment name for the forward.
5. Run the subcommand's suites unchanged, under `bash` and `/bin/bash`, and the hostile pass
   (`ship-pr/scripts/run-pr-review-hostile.sh`, which needs `en_US.UTF-8`).

### The shell bridge, and what it does not cover

The pr-review suites source the script and define `gh` as a shell **function**. When the
forwarder sees that `gh` or `git` is a function, it writes the shell's functions, variables and
`-u`/`pipefail` options to a file (`pr-review-bridge.<pid>.*` under TMPDIR, removed on return),
and the Python runs each such call as `<the same bash> -c '. <file>; gh "$@"'`. That is what the
shell's own `$(gh ...)` subshell saw, so a fixture that keeps its counters in files (they all do,
for that reason) behaves the same. In production nothing is a function and `gh` is the binary.

Not bridged: a suite's stub of a **time** command (`sleep() { SECONDS=...; }` in
test-pr-review-watch.sh) or of `date`. The `watch`/`base` porters need a clock the suite can
drive; design it in that port (an injectable clock in the session, set from the environment the
forwarder passes) rather than bridging `sleep`.

## Helpers shared across subcommands

Port what your subcommand needs into **your own module**, even when another subcommand will need
it too, and mark it on the line above the definition:

```python
# SHARED-CANDIDATE: status_state
def status_state(...) -> ...:
```

naming the shell function it ports. Do not edit another porter's module or move code into
`core.py` yourself: the integrator consolidates the candidates into core once the parallel ports
land, which keeps concurrent ports from conflicting.

## Checking

```sh
npx --yes pyright@1.1.414                                         # from the repo root
scripts/py -m unittest discover -s lib -t lib -p 'test_*.py'     # the package's unit tests
scripts/test-py.sh                                                # the wrapper
ship-pr/scripts/test-pr-review-<suite>.sh                         # the conformance suites
```

CI runs pyright and the unit tests in the `python` job of `.github/workflows/skill-scripts.yml`,
and the shell suites where they always ran. `scripts/fleet-peers.py` is not behind `scripts/py`
yet: its callers and its tests run it with `python3` and by path.

The execution registry (formerly `issue-wave/scripts/fleet-execution.py`) is
`lib/ludics/fleetworker/registry.py`, and it is the one module here that is SHIPPED: `fleet-worker.sh
execution` sends its source to the anchor box, where a Python >= 3.12 found by the far side's own
probe runs it from stdin. So it imports nothing from `ludics` (the anchor's checkout may hold
another version) and its positional argv is a contract; `issue-wave/scripts/test-fleet-execution.py`
loads it with `runpy` and patches `os.replace` between records.
