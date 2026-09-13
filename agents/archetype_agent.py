#!/usr/bin/env python3
"""A pane running one archetype, named on the command line.

`prose_spawn(flavour=...)` resolves an archetype to
`[python, archetype_agent.py, <name>, <params as JSON>]` and `pane.create`
execs it. There is one of these rather than one file per expert precisely so
that adding an expert is adding a Markdown file — see
`prose_agent/archetypes.py` for why the parent names one instead of writing
one.

To try an archetype without prose:

    agents/.venv/bin/python agents/tests/fake_prose.py \
        --agent archetype_agent.py browser-pilot '{"scope": "https://example.com"}' \
        --prompt "what does the front page say?"
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from claude_agent_sdk import ClaudeAgentOptions  # noqa: E402
from prose_agent import archetypes, credentials, run  # noqa: E402
from prose_agent import skills as skill_roots  # noqa: E402
from prose_agent.archetypes import Archetype, ArchetypeError  # noqa: E402
from prose_agent.asking import Asker  # noqa: E402
from prose_agent.permissions import Permissions, allowance  # noqa: E402
from prose_agent.tools import NEVER_DEFERRED  # noqa: E402


def options(archetype: Archetype, values: dict, asker: Asker) -> ClaudeAgentOptions:
    """One expert's options, assembled from its header.

    The two tool lists come from `permissions.allowance`, which is where the
    reasoning about them lives — they are a decision, and this file is only
    the plumbing that hands it to the SDK.
    """
    allowed, denied = allowance(archetype)
    return ClaudeAgentOptions(
        system_prompt=archetype.system_prompt(values),
        # The archetype's choice wins, then the environment, then the SDK's own
        # default: a cheap model is often right for a mechanical expert, and
        # that is a property of the expert rather than of the machine.
        model=archetype.model or os.environ.get("PROSE_MODEL") or None,
        effort=archetype.effort or os.environ.get("PROSE_EFFORT") or None,
        cwd=os.getcwd(),
        permission_mode="default",
        can_use_tool=Permissions(asker),
        setting_sources=["project"],
        plugins=skill_roots.plugins(),
        # An empty `skills` is `[]`, not `None`: `None` leaves the CLI's own
        # default on, and the point of a narrow expert is that it does not
        # carry a catalogue it will never use.
        skills="all" if archetype.skills == ("all",) else list(archetype.skills),
        allowed_tools=allowed,
        disallowed_tools=denied,
        env=NEVER_DEFERRED,
        include_partial_messages=True,
        thinking={"type": "adaptive", "display": "summarized"},
    )


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit("usage: archetype_agent.py <archetype> [params-json]")
    try:
        archetype = archetypes.load(sys.argv[1])
        values = json.loads(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2] else {}
        # Bound here as well as in the spawning parent, because `$PROSE_AGENT`
        # and `fake_prose.py` both reach this without going through one.
        archetype.bind(values)
    except (ArchetypeError, json.JSONDecodeError) as bad:
        # Loudly, and on stderr: a pane whose agent exits silently shows an
        # empty transcript and a status code, which says nothing about why.
        sys.exit(f"archetype_agent: {bad}")

    credentials.load()
    asker = Asker()
    run(options(archetype, values, asker),
        name=os.environ.get("PROSE_AGENT_NAME", archetype.name), asker=asker)


if __name__ == "__main__":
    main()
