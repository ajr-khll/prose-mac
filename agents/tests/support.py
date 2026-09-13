"""Stand-ins for the SDK, so the band-A mapping can be tested with nothing installed.

The block classes are named exactly as the SDK names them, and carry exactly
the fields it gives them — **no `type` field**, which is the whole reason
`harness._kind` dispatches on the class name. If these ever drift from
`claude_agent_sdk.types`, the tests here stop meaning anything, so the field
lists are copied rather than abbreviated.
"""

from __future__ import annotations

import os
import sys
from contextlib import contextmanager
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))


@dataclass
class TextBlock:
    text: str


@dataclass
class ThinkingBlock:
    thinking: str
    signature: str = ""


@dataclass
class ToolUseBlock:
    id: str
    name: str
    input: dict[str, Any] = field(default_factory=dict)


@dataclass
class ToolResultBlock:
    tool_use_id: str
    content: Any = None
    is_error: bool | None = None


@dataclass
class AssistantMessage:
    content: list[Any]
    model: str = "claude-opus-5"


@dataclass
class UserMessage:
    content: Any


@dataclass
class SystemMessage:
    subtype: str
    data: dict[str, Any]


@dataclass
class ResultMessage:
    subtype: str = "success"
    is_error: bool = False
    result: str | None = None
    errors: list[str] | None = None
    terminal_reason: str | None = "completed"
    total_cost_usd: float | None = None
    usage: dict[str, Any] | None = None


@dataclass
class StreamEvent:
    event: dict[str, Any]


class FakeWire:
    """A wire that records instead of writing, so events can be asserted on."""

    session = 1
    pane = 1

    def __init__(self, answer: dict | None = None) -> None:
        self.events: list[dict] = []
        self.calls: list[tuple[str, dict]] = []
        self.notices: list[tuple[str, dict]] = []
        #: What the next `call` comes back with.
        self.answer: dict = answer or {}

    def event(self, **fields: Any) -> None:
        self.events.append(fields)

    def notify(self, method: str, params: dict) -> None:
        self.notices.append((method, params))

    async def call(self, method: str, params: dict, timeout: float = 60.0) -> dict:
        self.calls.append((method, params))
        return self.answer

    # -- reading what was drawn -------------------------------------------

    def of(self, kind: str) -> list[dict]:
        return [e for e in self.events if e.get("kind") == kind]

    def text(self, block: str) -> str:
        return "".join(
            e.get("text", "") for e in self.of("delta") if e.get("id") == block)


def stream(**event: Any) -> StreamEvent:
    """One raw Anthropic stream event, as `StreamEvent.event` carries it."""
    return StreamEvent(event=event)


@contextmanager
def environment(**values: str):
    """Set environment variables for the length of a `with`, and put back
    exactly what was there — including absence, which `os.environ[k] = old`
    would turn into an empty string."""
    previous = {key: os.environ.get(key) for key in values}
    os.environ.update(values)
    try:
        yield
    finally:
        for key, old in previous.items():
            if old is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = old
