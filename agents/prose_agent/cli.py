"""prose-ctl — one call to prose, from a shell.

    PROSE_SOCKET=… PROSE_SESSION=… PROSE_TOKEN=… python3 -m prose_agent.cli \\
        pane.read '{"pane": 4, "fidelity": "summary"}'

**Not for the model.** Every invocation spawns a process, opens a second
socket and re-runs the handshake, for a connection the agent already holds —
which is the whole reason prose's tools are an in-process MCP server rather
than a command line (`reference/agent-guide.md` §2). This exists for the three
things a CLI is actually better at: looking at what a pane holds while
debugging, driving prose from a shell script, and being the one place a
question about the wire can be answered without writing an agent.

It is a thin wrapper over `wire.py`, so there is still exactly one
implementation of the protocol.

**It cannot attach to a session that already has a live agent.** prose refuses
a second `hello` for a bound session, because silently replacing the first
connection would leave that agent unable to receive `message`, `interrupt` or
`closed` with nothing anywhere to say why. So this is useful against a pane
whose agent has exited, or a session a script reserved for itself — not as a
way to look over a running agent's shoulder. Making that work needs replies
routed per connection rather than per session, which is the piece to build when
a second front door earns its place.
"""

from __future__ import annotations

import asyncio
import json
import sys

from .wire import ProseError, Wire

USAGE = """usage: prose-ctl <method> [params-json]

  prose-ctl hello
  prose-ctl pane.read '{"pane": 4}'
  prose-ctl pane.send '{"pane": 4, "text": "hello"}'
  prose-ctl event '{"kind": "activity", "id": "a1", "label": "poked"}'

Reads PROSE_SOCKET, PROSE_SESSION and PROSE_TOKEN from the environment.
A method that owes no answer is sent and not waited on."""

#: Methods prose answers. Everything else is a notification, and waiting on one
#: would hang until the timeout for a reply that was never coming.
ANSWERED = {"hello", "ask", "pane.create", "pane.read", "pane.send", "pane.answer",
            "pane.interrupt", "browser.navigate", "browser.text", "browser.eval",
            "browser.snapshot"}


async def main(argv: list[str]) -> int:
    if not argv or argv[0] in ("-h", "--help"):
        print(USAGE)
        return 0

    method, raw = argv[0], argv[1] if len(argv) > 1 else "{}"
    try:
        params = json.loads(raw)
    except ValueError as bad:
        sys.stderr.write("prose-ctl: %s is not JSON (%s)\n" % (raw, bad))
        return 2

    try:
        wire = await Wire.connect()
    except ProseError as why:
        sys.stderr.write("prose-ctl: %s\n" % why)
        return 1

    try:
        handshake = await wire.hello("prose-ctl")
        if method == "hello":
            print(json.dumps(handshake, indent=2, sort_keys=True))
            return 0

        # `event` names the session for you, since the point of a shell call is
        # not to have to look one up.
        if method == "event":
            wire.event(**params)
        elif method in ANSWERED:
            print(json.dumps(await wire.call(method, params), indent=2, sort_keys=True))
        else:
            wire.notify(method, params)
        # A notification is only in the socket's buffer at this point.
        await asyncio.sleep(0.1)
        return 0
    except ProseError as refused:
        sys.stderr.write("prose-ctl: %s\n" % refused)
        return 1
    finally:
        await wire.close()


if __name__ == "__main__":
    sys.exit(asyncio.run(main(sys.argv[1:])))
