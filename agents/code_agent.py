#!/usr/bin/env python3
"""A pane that is a coding agent, for when one is actually wanted.

Reached through `prose_spawn(task=..., flavour="code")`, which is what the
bundled `prose:spawn-coder` skill calls. It exists as a separate file precisely
so the coding identity is *not* in every pane: `pane_agent.py` is a personal
agent, and this is the thing it opens when the errand is a repository.

This one does use the SDK's `claude_code` preset, because here the preset is
right — its file and shell conventions are what a coding agent needs, and they
are not worth re-deriving. The prose-specific rules are appended.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from claude_agent_sdk import ClaudeAgentOptions  # noqa: E402
from prose_agent import credentials, run, skills
from prose_agent.tools import NEVER_DEFERRED  # noqa: E402
from prose_agent.asking import Asker  # noqa: E402
from prose_agent.permissions import (INVISIBLE, NO_AUTHORING, NO_BROWSER,
                                     UNATTENDED, Permissions)  # noqa: E402

#: The preset assumes a terminal that renders all of markdown. prose renders
#: only inline emphasis, so this has to be said again even though
#: `pane_agent.py` says it too — an agent started here never reads that prompt.
APPEND = """

You are running inside a prose pane, not a terminal. prose renders no markdown \
structure: headings, bullets, tables and fenced code blocks appear as the \
literal characters you typed. Write plain paragraphs, and send code as an \
attachment rather than in a fence. **Bold**, *italics* and `backtick spans` do \
render, inside a paragraph; underscores do not, so that __init__.py survives.

Do not narrate your work. Your reasoning, your tool calls and your skill loads \
are already drawn in the pane as they happen.

You were spawned by another agent. Call `prose_result` with what you concluded \
before you finish — that is how your answer reaches whoever asked for it.\
"""


def main() -> None:
    credentials.load()
    asker = Asker()
    run(ClaudeAgentOptions(
        system_prompt={"type": "preset", "preset": "claude_code", "append": APPEND},
        model=os.environ.get("PROSE_MODEL") or None,
        effort=os.environ.get("PROSE_EFFORT") or None,
        cwd=os.getcwd(),
        permission_mode="default",
        can_use_tool=Permissions(asker),
        # As `pane_agent.py`: project only, so a pane does not silently carry
        # every skill on the machine. This is the one flavour where adding
        # `"user"` would be defensible — a terminal's coding skills are for
        # exactly this — so it is a one-word change when that is wanted.
        setting_sources=["project"],
        plugins=skills.plugins(),
        skills="all",
        # The same two lists the personal agent uses: reading is unattended,
        # changing anything raises a card in this pane that the parent agent —
        # or the person — has to answer.
        allowed_tools=UNATTENDED,
        # A coding agent delegates browsing exactly as a personal one does —
        # the same fumbling with guessed selectors, in a pane where there is
        # also a repository to damage. See `permissions.NO_BROWSER`.
        disallowed_tools=INVISIBLE + NO_BROWSER + NO_AUTHORING,
        env=NEVER_DEFERRED,
        include_partial_messages=True,
        thinking={"type": "adaptive", "display": "summarized"},
    ), name=os.environ.get("PROSE_AGENT_NAME", "code"), asker=asker)


if __name__ == "__main__":
    main()
