"""Band A: what the harness knows, drawn without the model spending a token.

Thinking, skill loads, tool calls, turn boundaries and status are facts about
the agent's own runtime. The harness is already reading the stream they come
from, so they cost nothing to emit and cannot be wrong about themselves.

**None of this belongs in a tool.** A model asked to announce its own thinking
pays an inference round-trip per indicator and is free to announce thinking it
did not do. See `reference/agent-guide.md` §2.
"""

from __future__ import annotations

from .wire import Wire


class Events:
    """The drawing vocabulary, as methods rather than dictionaries."""

    def __init__(self, wire: Wire):
        self._wire = wire

    # -- a turn -----------------------------------------------------------

    def turn_started(self) -> None:
        self._wire.event(kind="turn", state="started")

    def turn_ended(self, error: str | None = None) -> None:
        self._wire.event(
            kind="turn", state="failed" if error else "ended", error=error)

    def status(self, **fields: str) -> None:
        """Free-form key/values for the pane header — model, cost, whatever is
        worth showing. Merged, not replaced, and drawn in a stable order."""
        self._wire.event(kind="status", fields={k: str(v) for k, v in fields.items()})

    # -- prose ------------------------------------------------------------

    def message(self, block: str, role: str = "agent") -> None:
        self._wire.event(kind="message.start", id=block, role=role)

    def thinking(self, block: str) -> None:
        """Opens a reasoning block. It streams through the same deltas prose
        does, and prose folds it away as the turn ends."""
        self._wire.event(kind="message.start", id=block, role="thinking")

    def delta(self, block: str, text: str) -> None:
        self._wire.event(kind="delta", id=block, text=text)

    def end(self, block: str) -> None:
        self._wire.event(kind="message.end", id=block)

    def say(self, block: str, text: str, role: str = "agent") -> None:
        """A whole block at once, for a stream that arrives in one piece."""
        self.message(block, role=role)
        self.delta(block, text)
        self.end(block)

    # -- steps ------------------------------------------------------------

    def activity(self, block: str, label: str, detail: str | None = None,
                 state: str | None = None, category: str | None = None) -> None:
        """A labelled step: a tool call, a retrieval, a wait.

        **Reuse `block` when the step resolves.** prose updates a row in place
        by id; a fresh id on the result appends a second row that never
        resolves, which is the most common mistake on this side of the wire.
        A resolving update that omits `detail` or `category` keeps the ones it
        had, so "Searching / 40 sources" does not lose its subtitle.
        """
        self._wire.event(
            kind="activity", id=block, label=label, detail=detail, state=state,
            category=category)

    def skill(self, block: str, name: str, state: str | None = None) -> None:
        """A skill loading. Drawn as a ring rather than a disc."""
        self.activity(block, "Skill", detail=name, state=state, category="skill")

    def attachment(self, block: str, text: str, type: str = "text",
                   language: str | None = None) -> None:
        """A block that is not prose. **Code goes here**, not in a fenced block
        inside a message — prose parses no markdown structure, so a fence in
        prose renders as literal backticks (and suppresses inline emphasis for
        the whole message)."""
        self._wire.event(
            kind="attachment", id=block, type=type, language=language, text=text)
