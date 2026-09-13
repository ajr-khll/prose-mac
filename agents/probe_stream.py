#!/usr/bin/env python3
"""Print what the SDK's stream actually looks like, so the harness can be written from it.

`reference/known-issues.md` §1 lists four things about the SDK that were
guessed rather than observed, and `agent-plan.md` §3.3 adds a fifth: the shape
of a `StreamEvent`. Guessing at that produces a pane that draws nothing,
silently, which is the most expensive failure mode available — so this runs one
throwaway query and dumps every message, and the mapping gets written from the
output rather than from the documentation.

    agents/.venv/bin/python agents/probe_stream.py [prompt]

Not shipped behaviour and not imported by anything. It costs one short turn.
"""

from __future__ import annotations

import asyncio
import json
import sys
from dataclasses import asdict, is_dataclass

from claude_agent_sdk import ClaudeAgentOptions, ClaudeSDKClient


def describe(message: object) -> str:
    """Everything about a message, without assuming it is a dataclass."""
    if is_dataclass(message) and not isinstance(message, type):
        body = asdict(message)
    else:
        body = dict(getattr(message, "__dict__", {}) or {})
    return json.dumps(body, default=repr, sort_keys=True)


async def main(prompt: str) -> int:
    options = ClaudeAgentOptions(
        include_partial_messages=True,
        thinking={"type": "adaptive", "display": "summarized"},
        allowed_tools=["Read", "Glob", "Skill"],
        setting_sources=["user", "project"],
        skills="all",
        max_turns=3,
    )

    async with ClaudeSDKClient(options=options) as client:
        await client.query(prompt)
        async for message in client.receive_response():
            print(f"--- {type(message).__name__}")
            print(f"    {describe(message)[:2000]}")
    return 0


if __name__ == "__main__":
    words = " ".join(sys.argv[1:]) or "Read agents/pyproject.toml and name its one dependency."
    sys.exit(asyncio.run(main(words)))
