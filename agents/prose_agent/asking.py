"""Every question prose is asked, through one door.

`reference/agent-guide.md` §8 is explicit: prose answers the first *unanswered*
ask it finds, so two outstanding at once is a bug rather than a queue. That
used to be easy to honour, because only the model could ask — its own turn is
sequential. It stopped being easy when permission prompts became asks too: the
SDK emits parallel tool calls, and each one that needs permission wants a card.

So both paths go through a single `Asker`, and it holds a lock. `pane_agent.py`
builds one and hands the same instance to the MCP server and to
`Permissions` — that shared instance *is* the mechanism.
"""

from __future__ import annotations

import asyncio
from typing import Any

from .wire import ProseError

#: A day. An ask has no deadline of its own — the person may be at lunch — and
#: prose keeps the card until it is answered. The number exists only so a
#: wedged socket eventually gives up rather than holding a turn forever.
PATIENCE = 86_400.0


class Asker:
    """One outstanding question at a time, whoever is asking."""

    def __init__(self, wire: Any = None):
        self._wire = wire
        # Safe to build before there is a running loop: since 3.10 a Lock
        # takes the running loop when it is first awaited, not when it is made.
        self._lock = asyncio.Lock()
        self._live: asyncio.Future | None = None
        self._withdrawn = False

    def bind(self, wire: Any) -> None:
        """Give it the socket, once `serve` has one.

        `pane_agent.py` has to build the `Asker` before the wire exists,
        because `ClaudeAgentOptions` wants the permission callback at
        construction and the wire is not open until `serve` runs.
        """
        self._wire = wire

    async def ask(self, prompt: str, choices: list[str] | None = None,
                  placeholder: str | None = None, timeout: float = PATIENCE,
                  secret: bool = False) -> str:
        """Put a question in the pane and wait for whoever answers it.

        Serialised rather than refused when a second one arrives: the second
        is usually the SDK's, not the model's, so raising would surface as a
        tool that was mysteriously denied.
        """
        async with self._lock:
            if self._wire is None:
                raise ProseError("not connected to prose")

            params: dict[str, Any] = {"session": self._wire.session, "prompt": prompt}
            if choices:
                params["choices"] = choices
            if placeholder:
                params["placeholder"] = placeholder
            if secret:
                # The composer masks what is typed and the transcript records
                # dots instead of the answer. The answer still comes back here
                # in full — this is about what is left behind, because a
                # transcript gets scrolled through, screenshotted and pasted
                # into conversations, and a credential in one is a credential
                # to revoke.
                params["secret"] = True

            # Held as a future so `abandon` can reach it. Awaiting directly
            # would leave nothing to cancel when the person presses Escape.
            self._live = asyncio.ensure_future(
                self._wire.call("ask", params, timeout=timeout))
            self._withdrawn = False
            try:
                answered = await self._live
            except asyncio.CancelledError:
                # **Only `abandon` may turn this into an answer.** When the
                # whole task is being cancelled — shutdown — the exception has
                # to keep going, or the loop never unwinds. Telling the two
                # apart is what the flag is for, and getting it wrong here
                # means an Escape either hangs or kills the agent.
                if not self._withdrawn:
                    raise
                raise ProseError("the question was withdrawn") from None
            finally:
                self._withdrawn = False
                self._live = None
            return str(answered.get("answer", ""))

    def abandon(self) -> None:
        """Give up on the outstanding question, if there is one.

        For Escape. The card itself stays in the transcript unanswered —
        nothing on the wire withdraws an ask — but that is cosmetic: if the
        person answers it later, `Wire._dispatch` drops a reply nobody is
        waiting for. Without this, an interrupted permission prompt would hold
        its turn for the full day above.

        The waiting `ask` comes out as a `ProseError` rather than a
        `CancelledError`, so a permission prompt becomes an ordinary refusal
        instead of an exception thrown back into the SDK's control protocol.
        """
        if self._live is not None and not self._live.done():
            self._withdrawn = True
            self._live.cancel()
