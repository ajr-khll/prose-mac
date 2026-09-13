"""Connect, say hello, and drive the Agent SDK from what prose sends.

The whole of an agent's plumbing, so that writing one is a system prompt and a
list of tools. See `reference/agent-guide.md` §12 for what these five lines
silently set up.
"""

from __future__ import annotations

import asyncio
from typing import Any

from .asking import Asker
from .events import Events
from .harness import Harness
from .tools import mcp_server, tool_names
from .wire import ProseError, Wire

#: What to say when the SDK cannot authenticate. A pane that sits empty and
#: never explains itself is the worst outcome available, and it is one `except`
#: away from being a sentence instead.
_NO_CREDENTIALS = (
    "no credentials — run `claude login`, or set ANTHROPIC_API_KEY, or put it "
    "in ~/.config/prose/env, then reopen this pane"
)


def auto_approved(declared: list[str] | None, server: str,
                  omit: tuple[str, ...] | list[str], confine: bool) -> list[str]:
    """The final `allowed_tools`: what runs without raising a card.

    `allowed_tools` auto-approves; it does not restrict. A prose tool missing
    from it falls through to permission evaluation — which with a `can_use_tool`
    installed is an ask card for `prose_wait`, and without one is a hang. For a
    general pane agent that is pure friction, so every registered tool goes on.

    For an archetype it is the whole point, and this is where `allow:` stopped
    meaning anything: the widening used to happen unconditionally, *after*
    `permissions.allowance` had composed a careful list, so `archetype-designer`
    — which names seven tools — ran auto-approved for `prose_close`,
    `prose_send` and `prose_interrupt` too. `deny` was the only real boundary,
    and every capability added to `tools.py` was reachable by every archetype
    until somebody remembered to deny it. Under `confine` the declaration is
    the answer, which is what an allowance has to mean before one of these
    holds a credential that can write to Slack.
    """
    already = list(declared or [])
    if confine:
        return already
    return already + tool_names(server, omit=omit)


async def serve(options: Any, name: str = "agent", server: str = "prose",
                asker: Asker | None = None, confine: bool = False,
                integrations: tuple[str, ...] | list[str] = ()) -> None:
    """Runs one pane's agent until prose closes it.

    `asker` is the one the caller already handed to its permission callback,
    if it has one. The same instance has to reach the tools, because it is the
    lock that keeps two questions from being outstanding at once (§8).

    `confine` says the caller's `allowed_tools` is the whole answer for prose's
    own tools and must not be widened here. An archetype sets it, because its
    `allow:` line is a declaration; a general pane agent does not, because it
    has no declaration to be measured against and every registered tool is
    legitimately its own.

    `integrations` is the provider set from an archetype's header, and the only
    thing that puts the `apps_*` server in a pane. It is empty everywhere else
    — `pane_agent` and `code_agent` pass nothing — so a general agent has no
    connector tools to reach for and no schema cost for them.
    """
    from claude_agent_sdk import ClaudeSDKClient

    _quiet()

    wire = await Wire.connect()
    events = Events(wire)
    await wire.hello(name)

    asker = asker or Asker()
    asker.bind(wire)

    # What this pane will not be given. Read once, here, because it decides
    # both which tools are registered below and what the prompt may point at.
    omit = _plainly(getattr(options, "disallowed_tools", None) or [])

    # Only this side knows the answer, because the environment hands the agent
    # a session and no call turns one into the other. Without it the model
    # either guesses its own pane id or spends a tool call discovering it.
    handed = "`prose_spawn` or `browser_open`" if "browser_open" not in omit \
        else "`prose_spawn`"
    _appendToPrompt(options, (
        f"\n\nYour own pane is {wire.pane} and your session is {wire.session}. "
        f"Any tool that takes a `pane` takes that number, or one that "
        f"{handed} handed you."))

    # prose's own tools, in-process: one line out and one line back on the
    # socket this process already holds. Added to whatever the author asked
    # for rather than replacing it, and named the way the SDK will namespace
    # them.
    #
    # A prose tool the caller has already denied is **not registered at all**,
    # rather than registered and then refused. A registered-but-denied tool
    # costs its schema in context on every turn and gives the model something
    # to try and be told off for; the pane agent's `NO_BROWSER` is nine of them
    # (`permissions.NO_BROWSER` says why browsing is delegated), and an
    # archetype that may not spawn drops `prose_spawn` the same way.
    options.mcp_servers = {**(getattr(options, "mcp_servers", None) or {}),
                           server: mcp_server(wire, name=server, asker=asker,
                                              omit=omit)}
    if integrations:
        # Built here rather than by the caller because it needs `wire`, which
        # does not exist until this function has connected. The provider set
        # is closed over, so a provider outside it is refused in-process
        # before anything reaches the broker.
        from .apps import mcp_server as apps_server

        options.mcp_servers["apps"] = apps_server(wire, integrations,
                                                  asker=asker)
    options.allowed_tools = auto_approved(
        getattr(options, "allowed_tools", None), server, omit, confine)

    try:
        await _converse(ClaudeSDKClient(options=options), wire, events, asker)
    except ProseError:
        raise
    except Exception as failure:  # noqa: BLE001 - reported into the pane, not swallowed
        events.turn_started()
        events.turn_ended(_explain(failure))

    await wire.close()


async def _converse(client: Any, wire: Wire, events: Events, asker: Asker) -> None:
    """The notification pump, and the one turn at a time it allows."""
    async with client:
        #: Prompts waiting for the current turn to finish. **A message queues;
        #: Escape interrupts.** prose already gives the user a dedicated
        #: interrupt, so treating a second message as an implicit one would
        #: mean a supervisor could not be told two things without losing the
        #: first.
        pending: list[str] = []
        turn: asyncio.Task | None = None

        async def run(text: str) -> None:
            """One turn. Band A comes out of it; the model spends nothing."""
            harness = Harness(events)
            events.turn_started()
            try:
                await client.query(text)
                async for message in client.receive_response():
                    harness.observe(message)
            except asyncio.CancelledError:
                # Shutdown, not an interrupt — an interrupt lets this loop run
                # on to the result that reports it. prose has to be told either
                # way, or the pane keeps saying `thinking…` forever.
                events.turn_ended("interrupted")
                raise
            except Exception as failure:  # noqa: BLE001 - reported, not swallowed
                events.turn_ended(_explain(failure))
            else:
                events.turn_ended(harness.error)

        async def pump() -> None:
            """Everything queued, one turn at a time, until nothing is left."""
            while pending:
                text = "\n\n".join(pending)
                pending.clear()
                await run(text)

        async for method, params in wire.notifications():
            if method in ("message", "child.result", "child.ask"):
                text = _prompt(method, params)
                if not text:
                    continue
                pending.append(text)
                # **On its own task**, so `interrupt` and `closed` are still
                # read while a turn is in flight. A serial loop here would make
                # Escape do nothing until the turn it was meant to stop ended.
                if turn is None or turn.done():
                    turn = asyncio.create_task(pump())

            elif method == "interrupt":
                # A card waiting on an answer would otherwise hold its turn for
                # the full day `asking.PATIENCE` allows.
                asker.abandon()
                if turn and not turn.done():
                    # Not `turn.cancel()`. `interrupt()` does not drain the
                    # buffer, and the `receive_response()` loop inside `run` is
                    # the drain — it iterates to the result that says
                    # `aborted_streaming`, which is what ends the turn
                    # honestly. Cancelling would abandon the drain and leave
                    # the next query reading the last turn's tail.
                    await client.interrupt()

            elif method == "closed":
                break

        if turn and not turn.done():
            turn.cancel()


def _quiet() -> None:
    """Stop the SDK warning about a thing we are doing on purpose.

    `CanUseToolShadowedWarning` says that a tool named in `allowed_tools` is
    auto-approved before `can_use_tool` is consulted. That is the design, not
    an accident: `allowed_tools` is exactly the list of calls that should not
    raise a card, and everything absent from it — `Bash`, `Write`, `Edit` —
    is absent so that it does. Left alone the warning names twenty tools on
    stderr every time a pane opens, which trains whoever is reading a log to
    ignore stderr.
    """
    import warnings

    from claude_agent_sdk import types

    shadowed = getattr(types, "CanUseToolShadowedWarning", None)
    if shadowed is not None:
        warnings.filterwarnings("ignore", category=shadowed)


def _appendToPrompt(options: Any, text: str) -> None:
    """Add to whatever shape of system prompt the author chose.

    `system_prompt` is a string, a `{"type": "preset", …}` dict or a
    `{"type": "file", …}` one. The file form has nothing to append to from
    here, so it is left alone rather than silently ignored — an agent that
    loads its prompt from a file can put the pane paragraph in the file.
    """
    prompt = getattr(options, "system_prompt", None)

    if prompt is None or isinstance(prompt, str):
        options.system_prompt = (prompt or "") + text
    elif isinstance(prompt, dict) and prompt.get("type") == "preset":
        options.system_prompt = {**prompt, "append": (prompt.get("append") or "") + text}


def _explain(failure: Exception) -> str:
    """A failure, said in a way the person reading the pane can act on."""
    said = str(failure) or type(failure).__name__
    lowered = said.lower()
    if any(word in lowered for word in
           ("authentication", "api key", "unauthorized", "not logged in", "credential")):
        return _NO_CREDENTIALS
    return said


def _prompt(method: str, params: dict) -> str:
    """What prose said, as something to say to the model.

    A parent talking, a child returning, and a child asking all arrive as
    separate methods but are all just the next thing this agent has to react
    to — labelled, so the model can tell them apart.
    """
    if method == "message":
        return params.get("text", "")
    if method == "child.result":
        return (f"The subagent in session {params.get('from')} finished and "
                f"returned: {params.get('value')!r}")
    if method == "child.ask":
        choices = params.get("choices") or []
        return (f"The subagent in pane {params.get('pane')} is asking: "
                f"{params.get('prompt')!r}"
                + (f" Choices: {choices}." if choices else "")
                + " Answer it with prose_answer, or escalate it to the user.")
    return ""


def _plainly(names: list[str]) -> list[str]:
    """Tool names as `definitions` spells them, whichever way they arrived.

    A deny list carries both spellings: `permissions.INVISIBLE` names built-ins
    plainly (`Task`), while `allowance` namespaces prose's own
    (`mcp__prose__prose_spawn`). Taking the last segment reads both, and a
    built-in name simply matches nothing in the catalogue.
    """
    return [name.rsplit("__", 1)[-1] for name in names]


def run(options: Any, name: str = "agent", asker: Asker | None = None,
        confine: bool = False,
        integrations: tuple[str, ...] | list[str] = ()) -> None:
    """`serve`, for a script that just wants to start."""
    try:
        asyncio.run(serve(options, name=name, asker=asker, confine=confine,
                          integrations=integrations))
    except (KeyboardInterrupt, ProseError):
        pass
