"""Find an API key, if one is needed and the environment does not have it.

`AgentProcess` copies prose's own environment into every agent it spawns, so a
key exported in the shell that launched prose reaches every pane for free. But
**Finder does not give you your shell**: `open Prose.app` inherits launchd's
environment, and `export ANTHROPIC_API_KEY` in a shell profile never arrives.
Since a bundled app is how prose is meant to be run, there has to be somewhere
on disk to put it.

Often none of this matters — the SDK bundles a Claude Code binary that will use
an existing `claude login` and report `apiKeySource: "none"`. This is for when
that is not true.
"""

from __future__ import annotations

import os
import stat
import sys
from pathlib import Path

#: Where to look. One file, in the place command-line tools already keep this
#: sort of thing, rather than a search path nobody can predict.
FILE = Path.home() / ".config" / "prose" / "env"

#: What may be carried. A deliberately short list: this file is read by a
#: process that then talks to a model, so it is not a general-purpose way to
#: set environment variables for an agent — `pane.create`'s `env` is that.
CARRIED = (
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
)


def load(path: Path | None = None) -> None:
    """Put anything in `CARRIED` into the environment, without overwriting.

    Never overwrites, so a key exported for one run beats the file, which is
    the order anybody would expect. Refuses a file others can read: this holds
    a credential, and the socket directory next door is 0700 for the same
    reason (spec §11).
    """
    where = path or FILE
    try:
        mode = where.stat().st_mode
    except OSError:
        return

    if mode & (stat.S_IRGRP | stat.S_IROTH):
        print(f"[prose] ignoring {where}: it is readable by others — "
              f"chmod 600 it", file=sys.stderr)
        return

    for name, value in _read(where).items():
        if name in CARRIED and name not in os.environ:
            os.environ[name] = value


def _read(where: Path) -> dict[str, str]:
    """`KEY=value` lines, `#` comments, optional surrounding quotes.

    Deliberately not `dotenv`: this is thirty lines of parsing against a third
    dependency for a file that holds one key, and `prose_agent` is otherwise
    standard library only.
    """
    found: dict[str, str] = {}
    try:
        lines = where.read_text(encoding="utf-8").splitlines()
    except OSError:
        return found

    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, _, value = line.partition("=")
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        found[name.strip()] = value
    return found
