"""The socket, and the one rule about reading it.

prose hands every process it spawns an open, authenticated place to talk:
`PROSE_SOCKET`, `PROSE_SESSION` and `PROSE_TOKEN` in the environment. This
module is that connection and nothing else — framing, the handshake, and the
demultiplexer. It imports nothing that is not in the standard library, so the
transport can be used, read and tested without an agent framework anywhere near
it.

# Only one thing may read the socket

Both the agent's own loop and every tool handler need traffic off this
connection. If two of them read it, they steal each other's lines: whichever
was owed the line that went the other way waits forever, and nothing raises.

So exactly one task reads, and it sorts what it finds. A JSON-RPC *response*
resolves the future belonging to the id it answers. A *notification* goes on a
queue for whoever is driving the agent. Everything else is dropped, which is
spec §10's rule read from this side — prose may grow vocabulary faster than any
one client does, and a line this build does not understand is not an error.
"""

from __future__ import annotations

import asyncio
import json
import os
from typing import Any


class ProseError(Exception):
    """prose refused something. Carries the reason it gave."""


class Wire:
    """One connection to prose."""

    def __init__(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter,
                 session: int, token: str):
        self._reader = reader
        self._writer = writer
        self.session = session
        self._token = token

        #: This agent's own pane, learned from the handshake. Everything an
        #: agent addresses is addressed by pane, and nothing else tells it.
        self.pane: int | None = None

        self._next_id = 1
        self._pending: dict[int, asyncio.Future] = {}
        self._notifications: asyncio.Queue = asyncio.Queue()
        self._reader_task: asyncio.Task | None = None

    # -- opening ----------------------------------------------------------

    @classmethod
    async def connect(cls, path: str | None = None, session: int | None = None,
                      token: str | None = None) -> "Wire":
        path = path or os.environ.get("PROSE_SOCKET")
        session = session if session is not None else os.environ.get("PROSE_SESSION")
        token = token or os.environ.get("PROSE_TOKEN")
        if not (path and session and token):
            raise ProseError(
                "PROSE_SOCKET, PROSE_SESSION and PROSE_TOKEN are required — "
                "this process is meant to be started by prose"
            )
        reader, writer = await asyncio.open_unix_connection(path)
        return cls(reader, writer, int(session), token)

    async def hello(self, name: str | None = None) -> dict:
        """Says hello and reads the answer back.

        Must be the first line: anything sent before it is dropped rather than
        refused, because a connection that has not identified itself is owed
        nothing. Starts the reader, since there is nothing to demultiplex until
        this connection is bound to a session.
        """
        self._reader_task = asyncio.create_task(self._read_forever())
        params: dict[str, Any] = {"session": self.session, "token": self._token}
        if name:
            params["name"] = name
        result = await self.call("hello", params)
        self.pane = result.get("pane")
        return result

    # -- speaking ---------------------------------------------------------

    def notify(self, method: str, params: dict) -> None:
        """Says something that owes no answer."""
        self._send({"jsonrpc": "2.0", "method": method, "params": params})

    async def call(self, method: str, params: dict, timeout: float = 60.0) -> dict:
        """Asks something and waits for the answer.

        **Never call this from the task that reads the socket.** It is waiting
        for a line that only the reader can deliver.
        """
        identifier = self._next_id
        self._next_id += 1

        waiting: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[identifier] = waiting
        self._send({"jsonrpc": "2.0", "id": identifier, "method": method, "params": params})

        try:
            return await asyncio.wait_for(waiting, timeout)
        except asyncio.TimeoutError as expired:
            raise ProseError(f"{method} was not answered in {timeout}s") from expired
        finally:
            self._pending.pop(identifier, None)

    def event(self, **fields: Any) -> None:
        """One thing to draw. The bulk of what any agent sends."""
        self.notify("event", {"session": self.session, "event": fields})

    # -- listening --------------------------------------------------------

    async def notifications(self):
        """Everything prose says that was not an answer: `message`, `interrupt`,
        `closed`, `child.result`, `child.ask`. Ends when the pane does.
        """
        while True:
            item = await self._notifications.get()
            if item is None:
                return
            yield item

    # -- the one reader ---------------------------------------------------

    async def _read_forever(self) -> None:
        try:
            while True:
                raw = await self._reader.readline()
                if not raw:
                    break
                try:
                    message = json.loads(raw.decode("utf-8"))
                except ValueError:
                    # A malformed line is ignored, never an error — the same
                    # forgiveness prose extends in the other direction.
                    continue
                self._dispatch(message)
        except (ConnectionResetError, BrokenPipeError):
            pass
        finally:
            self._shut_down()

    def _dispatch(self, message: dict) -> None:
        if "id" in message and ("result" in message or "error" in message):
            waiting = self._pending.pop(message["id"], None)
            if waiting is None or waiting.done():
                # An answer to something nobody is waiting for any more.
                return
            if "error" in message:
                waiting.set_exception(
                    ProseError((message.get("error") or {}).get("message", "refused")))
            else:
                waiting.set_result(message.get("result") or {})
            return

        method = message.get("method")
        if method:
            self._notifications.put_nowait((method, message.get("params") or {}))

    def _shut_down(self) -> None:
        """The socket went. Nobody is left to answer, so say so once rather
        than leaving every waiter hanging on its timeout."""
        for waiting in self._pending.values():
            if not waiting.done():
                waiting.set_exception(ProseError("the connection to prose closed"))
        self._pending.clear()
        self._notifications.put_nowait(None)

    # -- closing ----------------------------------------------------------

    def _send(self, payload: dict) -> None:
        try:
            self._writer.write((json.dumps(payload) + "\n").encode("utf-8"))
        except (ConnectionResetError, BrokenPipeError):
            pass

    async def close(self) -> None:
        if self._reader_task:
            self._reader_task.cancel()
        try:
            self._writer.close()
            await self._writer.wait_closed()
        except (ConnectionResetError, BrokenPipeError):
            pass
