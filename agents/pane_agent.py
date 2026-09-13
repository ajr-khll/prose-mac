#!/usr/bin/env python3
"""The agent that runs in a prose pane, on the Claude Agent SDK.

What `AgentProcess.defaultCommand` names, and what `PROSE_AGENT` overrides.
Everything it does is in `prose_agent/`; this file is the configuration, which
is the point — `reference/agent-guide.md` §12 promises that writing an agent is
a system prompt and a list of tools.

Run it yourself, against a fake prose, with `agents/tests/fake_prose.py`.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

# Beside us, not installed: a bundle's Resources and a source checkout put this
# directory in different places, and neither of them is the working directory.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from claude_agent_sdk import ClaudeAgentOptions  # noqa: E402
from prose_agent import credentials, run, skills
from prose_agent.tools import NEVER_DEFERRED  # noqa: E402
from prose_agent.asking import Asker  # noqa: E402
from prose_agent.permissions import (INVISIBLE, NO_AUTHORING, NO_BROWSER,
                                     UNATTENDED, Permissions)  # noqa: E402
from prose_agent.prompt import SYSTEM  # noqa: E402

def workspace() -> str:
    """Where the agent works.

    A bundle opened from Finder has a working directory of `/`, which is not
    somewhere anybody wants an agent reading and writing. A personal agent's
    home is the person's, not whichever repository prose happened to be built
    in, so `$PROSE_HOME` wins and `~` is the floor.
    """
    if home := os.environ.get("PROSE_HOME"):
        return home
    here = os.getcwd()
    return here if here not in ("/", "") else str(Path.home())


def options(asker: Asker) -> ClaudeAgentOptions:
    return ClaudeAgentOptions(
        system_prompt=SYSTEM,
        # Unset means the SDK's own default, which is one fewer thing to be
        # wrong about and one environment variable to change.
        model=os.environ.get("PROSE_MODEL") or None,
        effort=os.environ.get("PROSE_EFFORT") or None,
        cwd=workspace(),
        # The only mode that reaches `can_use_tool`. Anything looser and the
        # ask card never appears.
        permission_mode="default",
        can_use_tool=Permissions(asker),
        # **Project only, deliberately not `"user"`.** Adding `"user"` pulls
        # in every skill in `~/.claude/skills`, which on a working machine is
        # dozens of them written for a coding terminal — 85 here — and every
        # one costs a description in context on every turn of every pane. A
        # personal agent wants prose's own skills, whatever the workspace
        # defines, and nothing else by default. Put a personal skill in
        # `agents/skills/skills/` or point `$PROSE_PLUGINS` at it.
        setting_sources=["project"],
        plugins=skills.plugins(),
        skills="all",
        # Both lists live in `prose_agent.permissions`, beside the callback
        # that answers for everything absent from the first. `NO_BROWSER` is
        # the third: a pane agent that can spawn hands browsing to the
        # `browser-pilot` archetype rather than doing it badly itself, and the
        # tools are withheld rather than merely discouraged.
        allowed_tools=UNATTENDED,
        disallowed_tools=INVISIBLE + NO_BROWSER + NO_AUTHORING,
        # So prose's 16ms repaint coalescing has something to coalesce. Without
        # it a reply lands in one lump, which draws worse than the echo agent.
        env=NEVER_DEFERRED,
        include_partial_messages=True,
        # prose has a thinking block and folds it to a `Thought` line when the
        # turn ends. `display` defaults to "omitted", which would draw it empty.
        thinking={"type": "adaptive", "display": "summarized"},
        # No cap: supervising another pane is inherently many turns, and a cap
        # here is a hang that looks like a bug. Escape is the control, and it
        # works.
        max_turns=None,
    )


def main() -> None:
    credentials.load()
    # One `Asker` for the whole process, shared by `prose_ask` and by the
    # permission prompts — prose answers the first *unanswered* question it
    # finds, so two outstanding at once is a bug rather than a queue, and that
    # shared instance is the lock that prevents it.
    asker = Asker()
    run(options(asker), name=os.environ.get("PROSE_AGENT_NAME", "claude"), asker=asker)


if __name__ == "__main__":
    main()
