#!/usr/bin/env python3
"""The default agent: echoes what it is told, in prose's own vocabulary.

spec §11 names `python3 agents/echo_agent.py` as the default command. It is
deliberately not clever — its job is to prove the wire, and to be the thing an
end-to-end test drives. Everything it does, it does through `prose_agent`, so
the transport under it is the one a real agent would use rather than a second
implementation that can drift from it.

Three things it knows how to do:

    <anything>     one turn: an activity, a streamed reply, a code attachment
    spawn <task>   split, hand a subagent the task, and supervise it
    browse <url>   open a browser pane and read the page back
"""

import asyncio
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from prose_agent import Events, ProseError, Wire  # noqa: E402


class Echo:
    def __init__(self, wire: Wire):
        self.wire = wire
        self.out = Events(wire)
        self.turns = 0

    # -- one turn ---------------------------------------------------------

    async def respond(self, text: str) -> None:
        """As much of spec §10's vocabulary as a turn can reasonably use."""
        self.turns += 1
        self.out.turn_started()
        self.out.status(model="echo", turns=self.turns)

        self.out.activity("a1", "Reading", detail="1 message", state="running",
                          category="tool")
        await asyncio.sleep(0.15)
        self.out.activity("a1", "Read", state="ok")

        self.out.thinking("t%d" % self.turns)
        self.out.delta("t%d" % self.turns, "It said %r, so I will say it back." % text)
        self.out.end("t%d" % self.turns)

        block = "m%d" % self.turns
        self.out.message(block)
        # A word at a time, so prose's 16ms coalescing has something to
        # coalesce and the test exercises a real stream rather than one write.
        for word in ("You said: " + text).split(" "):
            self.out.delta(block, word + " ")
            await asyncio.sleep(0.03)
        self.out.end(block)

        self.out.attachment("x%d" % self.turns, 'print("echo: %s")' % text.replace('"', '\\"'),
                            type="code", language="python")
        self.out.turn_ended()

    # -- supervising a subagent -------------------------------------------

    async def supervise(self, task: str) -> None:
        """The whole supervision loop: split, send, *wait*, report.

        One blocking read per turn of the child's — not a poll. `pane.read`
        parks until the child stops and brings back everything new with it.
        """
        self.out.turn_started()
        self.out.activity("s1", "Spawning", state="running", category="tool")

        try:
            child = await self.wire.call("pane.create", {
                "from": self.wire.pane, "axis": "row", "title": "child"})
        except ProseError as refused:
            self.out.activity("s1", "Spawning", detail=str(refused), state="error")
            self.out.turn_ended("could not spawn a subagent")
            return

        pane = child["pane"]
        self.out.activity("s1", "Spawned", detail="pane %d" % pane, state="ok")
        self.wire.notify("pane.send", {"pane": pane, "text": task})

        answer = await self.wire.call(
            "pane.read",
            {"pane": pane, "since": 0, "until": ["turn", "exit"], "timeout": 20000},
            timeout=40,
        )
        self.out.say("sup", "child woke on %r with %d blocks" % (
            answer.get("reason"), len(answer.get("blocks") or [])))
        self.out.turn_ended()

    # -- driving a browser ------------------------------------------------

    async def browse(self, url: str) -> None:
        self.out.turn_started()
        self.out.activity("b1", "Opening", detail=url, state="running", category="tool")

        try:
            opened = await self.wire.call("pane.create", {
                "from": self.wire.pane, "axis": "row", "kind": "browser",
                "url": url, "title": "page"})
        except ProseError as refused:
            self.out.activity("b1", "Opening", detail=str(refused), state="error")
            self.out.turn_ended("could not open a browser pane")
            return

        pane = opened["pane"]
        # Parked, not polled. A browser pane's clock is its load count, so this
        # is the same level-triggered read a parent uses on a child: it returns
        # the instant the page is done, and returns *immediately* if the page
        # beat us here. The forty-iteration poll this replaces was wrong in
        # both directions — it burned calls on a fast page and gave up on a
        # slow one — and it is the reason this path is worth keeping in the
        # echo agent at all: `EndToEndTests` now exercises `WaitReason.loaded`
        # over a real socket with a real WKWebView, for no API tokens.
        waited = await self.wire.call(
            "pane.read",
            {"pane": pane, "since": 0, "until": ["loaded"], "timeout": 20_000},
            timeout=50,
        )
        answer = await self.wire.call("browser.text", {"pane": pane, "limit": 400})
        text = (answer.get("text") or "").strip()
        if not text:
            text = "(nothing: %s)" % waited.get("reason", "no reason given")

        self.out.activity("b1", "Opened", detail=url, state="ok")
        self.out.say("br", "page says: %s" % text)
        self.out.turn_ended()

    # -- the loop ---------------------------------------------------------

    async def run(self) -> None:
        await self.wire.hello("echo")
        turn: asyncio.Task | None = None

        async for method, params in self.wire.notifications():
            if method == "message":
                text = params.get("text", "")
                if text.startswith("spawn "):
                    work = self.supervise(text[len("spawn "):])
                elif text.startswith("browse "):
                    work = self.browse(text[len("browse "):])
                else:
                    work = self.respond(text)
                # On its own task, so an interrupt can still be read while a
                # turn is streaming.
                turn = asyncio.create_task(work)

            elif method == "interrupt":
                if turn and not turn.done():
                    turn.cancel()
                    self.out.turn_ended("interrupted")

            elif method == "child.result":
                self.out.say("child", "subagent returned %r" % params.get("value"))

            elif method == "closed":
                break

        if turn and not turn.done():
            turn.cancel()


async def main() -> int:
    try:
        wire = await Wire.connect()
    except ProseError as why:
        sys.stderr.write("echo_agent: %s\n" % why)
        return 1
    try:
        await Echo(wire).run()
    except ProseError:
        pass
    finally:
        await wire.close()
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
