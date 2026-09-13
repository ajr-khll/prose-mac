"""The Agent SDK's stream, translated into prose's vocabulary.

This is all of Band A, and the agent author writes none of it. Thinking, tool
calls, skill loads, turn boundaries and status all come off a stream the
harness is reading anyway, so drawing them costs no model tokens and cannot
disagree with what actually happened.

Everything here is duck-typed rather than matched against the SDK's classes, on
purpose: the mapping stays readable, this module stays importable without the
SDK, and a message or block type the SDK adds later is ignored rather than
crashing the turn. The SDK emits `HookEventMessage`, `RateLimitEvent`,
`TaskStartedMessage` and several `SystemMessage` subtypes that mean nothing
here, so ignoring the unknown is the common path rather than the edge case.

The discriminator is the **class name**, not a `type` field. See `_kind`.
"""

from __future__ import annotations

import sys
from typing import Any

from .events import Events

#: Server-side tools whose rows read better as a search than as a tool call.
#: `spec §10` lists `search` as a category, and this is the only thing that
#: produces one.
_SEARCHES = {"web_search", "web_fetch"}

#: Terminal reasons that are not worth a header field. Everything else —
#: `max_turns`, `aborted_streaming`, `aborted_tools` — is something the person
#: reading the pane wants to know.
_UNREMARKABLE = {"completed", "end_turn"}

#: Terminal reasons that mean somebody stopped the turn on purpose.
_ABORTED = {"aborted_streaming", "aborted_tools"}


class Harness:
    """Folds one turn's worth of SDK messages into prose events."""

    def __init__(self, events: Events):
        self.events = events
        #: Set if the turn ended badly, so the loop can close it honestly.
        self.error: str | None = None

        #: `tool_use` id -> the label its row was created with.
        #:
        #: prose keeps an activity's *detail* and *category* when an update
        #: omits them, but not its label: `Transcript.upsertActivity` writes
        #: the label through unconditionally, and `parseEvent` drops an
        #: activity that carries none at all. So a resolving update has to
        #: resend the label, which means remembering it.
        self._labels: dict[str, str] = {}

        #: SSE content-block index -> the prose block id it was opened as.
        self._open: dict[int, str] = {}
        #: SSE indices already drawn delta by delta, so the whole
        #: `AssistantMessage` that follows does not draw them a second time.
        self._streamed: set[int] = set()

        self._message = 0
        self._blocks = 0
        self._said_model = False

    def _next(self, prefix: str) -> str:
        self._blocks += 1
        return f"{prefix}{self._blocks}"

    # -- one message off `receive_response()` -----------------------------

    def observe(self, message: Any) -> None:
        """One message off `receive_response()`, of whatever sort."""
        name = type(message).__name__

        if name == "StreamEvent":
            self._observe_stream(getattr(message, "event", None) or {})
            return

        if name == "SystemMessage":
            self._observe_system(message)
            return

        if name == "ResultMessage":
            self._observe_result(message)
            return

        # `AssistantMessage` and `UserMessage` both carry content blocks, and
        # both may carry none. `UserMessage.content` is `str | list`, so the
        # list check is load-bearing: iterating a string would walk it a
        # character at a time and draw nothing recognisable.
        if name == "AssistantMessage" and not self._said_model:
            model = getattr(message, "model", None)
            if model:
                self.events.status(model=str(model))
                self._said_model = True

        content = getattr(message, "content", None)
        if isinstance(content, list):
            for index, block in enumerate(content):
                # Drawn already, delta by delta. The whole message arrives
                # *before* that block's `content_block_stop`, so this cannot
                # be decided by arrival order.
                if index in self._streamed and _kind(block) in ("text", "thinking"):
                    continue
                self._observe_block(block)

    # -- the streaming path -----------------------------------------------

    def _observe_stream(self, event: dict) -> None:
        """A raw Anthropic stream event, as `StreamEvent.event` carries it.

        Streaming exists so prose's 16ms repaint coalescing has something to
        coalesce. Without it a reply lands in one lump, which draws worse than
        the echo agent this replaces.
        """
        kind = event.get("type")

        if kind == "message_start":
            self._message += 1
            self._open.clear()
            self._streamed.clear()
            return

        if kind == "content_block_start":
            index = event.get("index")
            block = event.get("content_block") or {}
            opening = block.get("type")
            if not isinstance(index, int):
                return
            # A tool call's arguments arrive as partial JSON, which cannot
            # produce a label — so its row is drawn from the whole block when
            # the message lands, and the index is left out of `_streamed`.
            if opening == "text":
                self._open[index] = self._blockID(index)
                self._streamed.add(index)
                self.events.message(self._open[index])
            elif opening == "thinking":
                self._open[index] = self._blockID(index)
                self._streamed.add(index)
                self.events.thinking(self._open[index])
            return

        if kind == "content_block_delta":
            index = event.get("index")
            delta = event.get("delta") or {}
            block = self._open.get(index) if isinstance(index, int) else None
            if block is None:
                return
            text = delta.get("text") or delta.get("thinking") or ""
            if text:
                self.events.delta(block, text)
            return

        if kind == "content_block_stop":
            index = event.get("index")
            block = self._open.pop(index, None) if isinstance(index, int) else None
            if block is not None:
                self.events.end(block)
            return

    def _blockID(self, index: int) -> str:
        """An id for a streamed block.

        Prefixed apart from `_next`'s, so a turn that streams some blocks and
        draws others whole cannot collide the two.
        """
        return f"s{self._message}-{index}"

    # -- whole blocks -----------------------------------------------------

    def _observe_block(self, block: Any) -> None:
        kind = _kind(block)

        if kind == "thinking":
            text = getattr(block, "thinking", "") or ""
            if text:
                self.events.say(self._next("t"), text, role="thinking")

        elif kind == "text":
            text = getattr(block, "text", "") or ""
            if text:
                self.events.say(self._next("m"), text)

        elif kind == "tool_use":
            # **The id is the tool call's own**, so the result below updates
            # this row rather than adding a second one that never resolves.
            name = getattr(block, "name", "tool")
            row = f"tool-{getattr(block, 'id', self._next('u'))}"
            arguments = getattr(block, "input", None) or {}
            if _isSkill(name):
                label, detail = "Skill", _skillName(arguments)
                category = "skill"
            else:
                label, detail = _label(name, arguments), None
                category = "search" if name in _SEARCHES else "tool"
            self._labels[row] = label
            self.events.activity(
                row, label=label, detail=detail, state="running", category=category)

        elif kind == "tool_result":
            row = f"tool-{getattr(block, 'tool_use_id', '')}"
            failed = bool(getattr(block, "is_error", False))
            self.events.activity(
                row,
                # Resent rather than omitted: prose overwrites a label with
                # whatever arrives and drops an activity that has none.
                label=self._labels.pop(row, "tool"),
                # Omitted when there is nothing to say, which *does* keep the
                # detail the row already had.
                detail=_summarise(getattr(block, "content", None)),
                state="error" if failed else "ok",
            )

    # -- the two whole-message cases --------------------------------------

    def _observe_system(self, message: Any) -> None:
        """The `init` message, which is the only evidence that skills loaded.

        The SDK **skips a plugin path that does not exist without saying so**,
        so a typo in `skills.plugins()` means the skills quietly are not there.
        This is what notices. Every other system subtype is runtime chatter.
        """
        if getattr(message, "subtype", None) != "init":
            return
        data = getattr(message, "data", None) or {}

        skills = data.get("skills") or []
        if skills:
            self.events.status(skills=str(len(skills)))
        # To stderr rather than the transcript: the names are for whoever is
        # debugging why a skill did not fire, not for whoever is reading the
        # pane. `PROSE_LOG_DIR` and `PROSE_FRAME=1` both capture this.
        print(f"[prose] skills: {', '.join(map(str, skills)) or 'none'}", file=sys.stderr)
        plugins = [p.get("name") for p in (data.get("plugins") or []) if isinstance(p, dict)]
        print(f"[prose] plugins: {', '.join(map(str, plugins)) or 'none'}", file=sys.stderr)

    def _observe_result(self, message: Any) -> None:
        """How the turn went.

        `is_error` is the reliable signal — `subtype` is an untyped string, and
        the value this code used to test for (`"failure"`) is not one the SDK
        emits at all, so every failed turn reported success.
        """
        reason = getattr(message, "terminal_reason", None)

        # **An abort is checked first, and it beats `is_error`.** Escape
        # during a tool call comes back with `is_error` set *and* a `result`
        # holding an internal diagnostic — `[ede_diagnostic] result_type=user
        # …` — which is not something to put in front of a person who just
        # pressed a key and knows perfectly well what happened.
        if reason in _ABORTED:
            self.error = "interrupted"
        elif getattr(message, "is_error", False):
            errors = getattr(message, "errors", None) or []
            self.error = str(
                (errors[0] if errors else None)
                or _plain(getattr(message, "result", None))
                or "the turn failed")

        if reason and reason not in _UNREMARKABLE:
            self.events.status(stopped=str(reason))

        cost = getattr(message, "total_cost_usd", None)
        if isinstance(cost, (int, float)):
            self.events.status(cost=f"${cost:.4f}")

        usage = getattr(message, "usage", None)
        if isinstance(usage, dict):
            spent = usage.get("input_tokens"), usage.get("output_tokens")
            if all(isinstance(n, int) for n in spent):
                self.events.status(tokens=f"{spent[0]}→{spent[1]}")


def _plain(said: Any) -> str | None:
    """A failure string, unless it is the CLI talking to itself.

    `ResultMessage.result` sometimes carries an internal diagnostic rather
    than a reason — a bracketed tag and a run of `key=value` pairs. Drawing
    that in a pane tells the reader nothing and looks like a crash, so it is
    dropped in favour of the generic wording the caller falls back to.
    """
    if not isinstance(said, str) or not said.strip():
        return None
    if said.startswith("[") and "=" in said:
        return None
    return said


def _kind(block: Any) -> str | None:
    """Which sort of block this is.

    **The SDK's block dataclasses carry no `type` field** — `TextBlock` has
    only `text`, `ToolUseBlock` only `id`/`name`/`input` — so the discriminator
    has to be the class name. Reading the name rather than importing the
    classes is what keeps this module importable, and its tests runnable, with
    no SDK installed.

    The attribute sniff behind it is for a rename: a class we have never heard
    of that has a `.thinking` is still thinking, and drawing it beats dropping
    it.
    """
    byName = {
        "TextBlock": "text",
        "ThinkingBlock": "thinking",
        "ToolUseBlock": "tool_use",
        "ToolResultBlock": "tool_result",
        "ServerToolUseBlock": "tool_use",
        "ServerToolResultBlock": "tool_result",
    }.get(type(block).__name__)
    if byName:
        return byName

    if hasattr(block, "thinking"):
        return "thinking"
    if hasattr(block, "tool_use_id"):
        return "tool_result"
    if hasattr(block, "name") and hasattr(block, "input"):
        return "tool_use"
    if hasattr(block, "text"):
        return "text"
    return None


def _isSkill(name: str) -> bool:
    """Whether a tool call is really a skill loading.

    The SDK surfaces a skill as an ordinary tool call named `Skill` — which is
    also why `"Skill"` has to be in `allowed_tools` for skills to exist at all.
    This is the one place that has to know it, and it decides a ring rather
    than a disc.
    """
    return name == "Skill" or name.startswith("Skill(")


def _skillName(arguments: dict) -> str | None:
    """Which skill is loading, for the row's detail.

    The input key is not documented, so every plausible spelling is tried and
    the row falls back to a bare `Skill` rather than raising.
    """
    for key in ("skill", "name", "command", "skill_name"):
        value = arguments.get(key)
        if isinstance(value, str) and value:
            return value
    return None


def _label(name: str, arguments: dict) -> str:
    """`Bash(swift test)` rather than `Bash` — the row reads as the step it is.

    An MCP tool arrives namespaced as `mcp__server__tool`; the server prefix is
    prose's own plumbing and says nothing to whoever is reading the pane.
    """
    if name.startswith("mcp__"):
        name = name.rsplit("__", 1)[-1]

    for key in ("command", "pattern", "file_path", "path", "url", "query", "prompt"):
        value = arguments.get(key)
        if isinstance(value, str) and value:
            return f"{name}({_short(value)})"

    # Nothing named. Rather than draw a bare `Tool`, go looking: a tool this
    # code has never heard of still put *something* readable in its arguments,
    # and a row — or a permission card — that names it is worth much more than
    # one that does not. The card is the case that matters: "wants to use
    # something" is a question nobody can answer.
    found = _anyText(arguments)
    return f"{name}({_short(found)})" if found else name


def _short(value: str) -> str:
    return value if len(value) <= 60 else value[:57] + "…"


def _anyText(arguments: Any, depth: int = 0) -> str | None:
    """The most informative string in a tool's arguments, wherever it is.

    **The longest one**, not the first. A tool this code has never heard of
    still put something readable in its arguments, but the readable part is
    rarely the first key alphabetically — `{"questions": [{"header": "Reading",
    "question": "Which reading of §7.1?"}]}` would otherwise draw as `Reading`.
    Length is a crude proxy for which of two strings tells you more, and it is
    right far more often than key order is.

    Shallow on purpose: three levels reaches the shape above without wandering
    into something enormous, and only the first few items of a list are looked
    at. The caller truncates, so a long winner costs nothing.
    """
    if isinstance(arguments, str):
        return arguments.strip() or None
    if depth >= 3:
        return None

    found: list[str] = []
    if isinstance(arguments, dict):
        found = [text for value in arguments.values()
                 if (text := _anyText(value, depth + 1))]
    elif isinstance(arguments, list):
        found = [text for item in arguments[:3]
                 if (text := _anyText(item, depth + 1))]
    return max(found, key=len) if found else None


def _summarise(content: Any) -> str | None:
    """One line of a tool's output, for the row's detail."""
    if isinstance(content, str):
        text = content
    elif isinstance(content, list):
        text = " ".join(
            part.get("text", "") for part in content if isinstance(part, dict))
    elif isinstance(content, dict):
        # A server tool's result is a raw dict, opaque to this layer.
        text = str(content.get("type", ""))
    else:
        return None

    text = " ".join(text.split())
    if not text:
        return None
    return text if len(text) <= 80 else text[:77] + "…"
