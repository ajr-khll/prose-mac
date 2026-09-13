#!/usr/bin/env python3
"""prose, faked, so an agent can be run without a window.

The agent's whole contract is a socket and line-delimited JSON-RPC, so the
useful half of prose for debugging one is about a hundred lines: bind a socket,
answer `hello`, send a message, and print what comes back. What you get is the
**wire** — which is the thing that is either right or wrong — with no Swift, no
window, and no WKWebView in the way.

    agents/.venv/bin/python agents/tests/fake_prose.py --prompt "say hello"
    agents/.venv/bin/python agents/tests/fake_prose.py \\
        --prompt "first errand" --prompt "second errand"
    agents/.venv/bin/python agents/tests/fake_prose.py --ask allow \\
        --prompt "run `date` with Bash and tell me what it said"

`--ask` decides what a question is answered with, so the permission card can be
exercised from here. `--ask interrupt` leaves the question outstanding and
presses Escape instead, which is how to find out whether a card waiting for an
answer stalls the SDK's client. `--raw` prints the lines as they arrive instead of folding
them into something readable.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import secrets
import sys
import tempfile
from pathlib import Path

AGENTS = Path(__file__).resolve().parent.parent
SESSION = 1
PANE = 1


def _what(params: dict) -> str:
    """A one-line description of the pane `pane.create` is asking for.

    `pane.create` carries an argv, not a flavour — the model names a flavour
    and `tools.argv` turns it into a command before this ever reaches the
    wire. So the interesting word is at the end of the command: an archetype's
    name, or the agent script that is going to run.
    """
    if params.get("kind") == "browser":
        return f"browser · {params.get('url')}"
    command = [str(part) for part in (params.get("command") or [])]
    words = []
    for part in command:
        if part.startswith("-") or Path(part).name.startswith("python"):
            continue
        # Only a *path* gets shortened. An archetype's parameters arrive as a
        # JSON argument that often holds a URL, and basenaming that leaves you
        # reading `wiki/"}` and wondering what broke.
        words.append(Path(part).name if part.endswith(".py") else part)
    return f"agent · {' '.join(words) or 'prose'}"


class Fake:
    def __init__(self, answer: str, raw: bool) -> None:
        self.answer = answer
        self.raw = raw
        self.token = secrets.token_hex(16)
        self.done = asyncio.Event()
        self.blocks: dict[str, list[str]] = {}
        self.asked = 0
        #: Panes handed out by `pane.create`, and the sessions notionally in
        #: them. There is no child process behind any of them — see the
        #: dispatch below for what that does and does not let you test.
        self.spawned: dict[int, int] = {}
        #: Prompts still to send. A turn ending pops the next one instead of
        #: ending the run, which is the only way to exercise what an agent
        #: does with a *second* errand — whether it reuses the specialist it
        #: already spawned, or opens another one beside it.
        self.queue: list[str] = []
        #: Set on the serving task, so a turn ending can send without one.
        self.send = None

    # -- what prose would draw --------------------------------------------

    def draw(self, event: dict) -> None:
        kind = event.get("kind")
        if kind == "turn":
            state = event.get("state")
            print(f"\n\033[1m— turn {state}\033[0m"
                  + (f": {event['error']}" if event.get("error") else ""))
            if state != "started":
                if self.queue and self.send is not None:
                    asyncio.ensure_future(self._next())
                else:
                    self.done.set()
        elif kind == "status":
            fields = " · ".join(f"{k} {v}" for k, v in event.get("fields", {}).items())
            print(f"\033[2m[{fields}]\033[0m")
        elif kind == "message.start":
            self.blocks[event["id"]] = []
            role = event.get("role", "agent")
            print(f"\n\033[2m{role}:\033[0m ", end="", flush=True)
        elif kind == "delta":
            self.blocks.setdefault(event["id"], []).append(event.get("text", ""))
            # Printed as it arrives, which is the whole point of streaming —
            # if this comes out in one lump, `include_partial_messages` is not
            # doing what it should.
            print(event.get("text", ""), end="", flush=True)
        elif kind == "message.end":
            print()
        elif kind == "activity":
            mark = {"ok": "●", "error": "✗"}.get(event.get("state"), "◌")
            ring = "○" if event.get("category") == "skill" else mark
            detail = f" — {event['detail']}" if event.get("detail") else ""
            print(f"  {ring} {event.get('label')}{detail}")
        elif kind == "attachment":
            body = event.get("text", "")
            print(f"  \033[2m[{event.get('type')} attachment, {len(body)} chars]\033[0m")

    async def _next(self) -> None:
        """Send the next queued prompt, as the person typing a second time."""
        text = self.queue.pop(0)
        print(f"\n\033[1m> {text}\033[0m")
        await self.send({"jsonrpc": "2.0", "method": "message",
                         "params": {"session": SESSION, "text": text}})

    # -- the socket --------------------------------------------------------

    async def serve(self, reader, writer, prompts: list[str]) -> None:
        async def send(message: dict) -> None:
            writer.write((json.dumps(message) + "\n").encode())
            await writer.drain()

        self.send = send
        self.queue = list(prompts[1:])
        prompt = prompts[0]
        greeted = False
        while True:
            line = await reader.readline()
            if not line:
                break
            try:
                message = json.loads(line)
            except ValueError:
                continue
            if self.raw:
                print(f"\033[2m← {line.decode().rstrip()[:400]}\033[0m")

            method, params = message.get("method"), message.get("params") or {}

            if method == "hello":
                await send({"jsonrpc": "2.0", "id": message["id"],
                            "result": {"ok": True, "pane": PANE, "session": SESSION}})
                print(f"\033[2m[hello from {params.get('name')!r}]\033[0m")
                greeted = True
                await send({"jsonrpc": "2.0", "method": "message",
                            "params": {"session": SESSION, "text": prompt}})

            elif method == "event" and greeted and not self.raw:
                self.draw(params.get("event") or {})

            elif method == "ask":
                self.asked += 1
                choices = params.get("choices") or []
                print(f"\n\033[33m? {params.get('prompt')}\033[0m")
                print(f"\033[2m  choices: {choices}\033[0m")
                if self.answer == "interrupt":
                    # Does a card waiting for an answer stall the SDK's whole
                    # client, `interrupt()` included? Leave the question
                    # outstanding, press Escape, and see whether the turn ends.
                    print("\033[33m  → (not answering; sending interrupt)\033[0m")
                    await send({"jsonrpc": "2.0", "method": "interrupt",
                                "params": {"session": SESSION}})
                    continue
                answer = self._answer(choices)
                print(f"\033[33m  → {answer!r}\033[0m")
                await send({"jsonrpc": "2.0", "id": message["id"],
                            "result": {"answer": answer}})

            elif method == "pane.create":
                # **A spawn has to succeed here**, even though nothing runs in
                # the pane. It is not a detail: an agent whose `prose_spawn`
                # fails does not stop, it improvises — measured, twice, at
                # about thirty cents a go. The first run of this harness after
                # browsing became a delegated job showed the agent reaching
                # for `browser-pilot` first and then falling back to `curl`,
                # and only the fallback was the harness's fault.
                pane = PANE + len(self.spawned) + 1
                session = SESSION + len(self.spawned) + 1
                self.spawned[pane] = session
                print(f"\n\033[36m[pane {pane}: {_what(params)}]\033[0m")
                await send({"jsonrpc": "2.0", "id": message["id"],
                            "result": {"pane": pane, "session": session}})

            elif method == "pane.send" and params.get("pane") in self.spawned:
                # The task is not part of `pane.create` — it is sent to the
                # new pane a moment later, which is why a spawn's own params
                # look empty. Printed here so the errand is visible next to
                # the pane it was given to.
                text = (params.get("text") or "").strip().replace("\n", " ")
                print(f"\033[2m  → pane {params['pane']}: {text[:200]}\033[0m")

            elif method == "pane.read" and params.get("pane") in self.spawned:
                # The child that is not there "exits" at once, so a parent
                # parked on it gets an answer instead of the full timeout.
                # That is honest about what this harness is: it shows you the
                # parent's half of a supervision loop — the spawn, the park,
                # the cursor — and it cannot show you the child's.
                await send({"jsonrpc": "2.0", "id": message["id"],
                            "result": {"reason": "exit", "cursor": 0,
                                       "blocks": [], "note": "fake_prose runs "
                                       "no child process; the pane is empty"}})

            elif "id" in message:
                # Anything else that wants an answer gets an empty one, which
                # is enough to keep the agent moving. A real pane.read would
                # need a transcript; that is what the Swift tests are for.
                await send({"jsonrpc": "2.0", "id": message["id"], "result": {}})

    def _answer(self, choices: list[str]) -> str:
        if self.answer == "allow" and choices:
            return choices[0]
        if self.answer == "deny" and choices:
            return choices[-1]
        return self.answer


async def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--prompt", action="append", default=None,
        help="what the person types. Repeat it to send a second message once "
             "the first turn has ended — which is how to see whether an agent "
             "reuses a pane it already spawned.")
    parser.add_argument("--ask", default="allow",
                        help="allow | deny | interrupt | any literal answer")
    # `nargs` so an archetype can be driven here too: the first is the
    # script, the rest are its arguments —
    #     --agent archetype_agent.py browser-pilot '{"scope": "https://…"}'
    parser.add_argument("--agent", nargs="+", default=["pane_agent.py"])
    parser.add_argument("--raw", action="store_true")
    parser.add_argument("--seconds", type=float, default=180.0)
    arguments = parser.parse_args()

    fake = Fake(arguments.ask, arguments.raw)
    with tempfile.TemporaryDirectory(prefix="fake-prose-") as directory:
        path = str(Path(directory) / "agents.sock")
        server = await asyncio.start_unix_server(
            lambda r, w: asyncio.ensure_future(
                fake.serve(r, w, arguments.prompt
                           or ["Say hello in one short sentence."])), path)

        environment = {
            **os.environ,
            "PROSE_SOCKET": path,
            "PROSE_SESSION": str(SESSION),
            "PROSE_TOKEN": fake.token,
        }
        agent = await asyncio.create_subprocess_exec(
            sys.executable, str(AGENTS / arguments.agent[0]), *arguments.agent[1:],
            env=environment)

        try:
            await asyncio.wait_for(fake.done.wait(), timeout=arguments.seconds)
        except asyncio.TimeoutError:
            print(f"\n\033[31m— nothing ended the turn in {arguments.seconds}s\033[0m")
        finally:
            agent.terminate()
            await agent.wait()
            server.close()

    print(f"\n\033[2m[{fake.asked} question(s) asked]\033[0m")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
