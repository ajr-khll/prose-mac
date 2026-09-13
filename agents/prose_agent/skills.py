"""Where the agent's skills come from.

Four tiers, and they do not compete:

  * **bundled** — `agents/skills/`, loaded as a local plugin and namespaced
    `prose:<name>`. prose's own capabilities, versioned with prose.
  * **personal** — `~/.claude/skills/`, loaded because `setting_sources`
    includes `"user"`. Shared with the terminal, nothing to configure.
  * **per-workspace** — `<cwd>/.claude/skills/`, from `"project"`.
  * **dropped in** — anything named in `$PROSE_PLUGINS`, colon-separated.

Because the bundled ones carry a prefix and the others do not, a name
collision between tiers is impossible by construction rather than by
convention.
"""

from __future__ import annotations

import os
from pathlib import Path

#: Extra plugin roots, colon-separated, so one can be tried without editing
#: anything. Same separator as `PATH`, for the same reason.
ENVIRONMENT = "PROSE_PLUGINS"


def plugins() -> list[dict[str, str]]:
    """Every plugin root to load, in the shape `ClaudeAgentOptions` wants.

    Two things about the SDK make this more than a path join. It **does not
    expand `~`**, so every path here is absolute. And it **skips a path that
    does not exist without saying so** — which is why `Harness` reads the
    `init` message's plugin list rather than trusting what this returns.
    """
    roots: list[Path] = []

    bundled = resource("skills")
    if bundled is not None:
        roots.append(bundled)

    for extra in os.environ.get(ENVIRONMENT, "").split(":"):
        if not extra.strip():
            continue
        where = Path(extra).expanduser().resolve()
        if where.is_dir() and where not in roots:
            roots.append(where)

    return [{"type": "local", "path": str(root)} for root in roots]


def resource(relative: str) -> Path | None:
    """Where something under `agents/` actually is.

    The twin of `AgentProcess.resolveAgentFile` on the Swift side, and it walks
    the same ladder for the same reason: a bundled app and a source checkout
    put this directory in different places, and neither of them is the working
    directory. Keep the two in step.
    """
    here = Path(__file__).resolve().parent.parent          # …/agents
    candidates = [here / relative]

    binary = Path(__file__).resolve()
    for parent in binary.parents:
        candidates.append(parent / "agents" / relative)
        candidates.append(parent / "Resources" / "agents" / relative)

    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    return None
