"""The permission card's decision table, without the SDK or a socket."""

from __future__ import annotations

import asyncio
import unittest

import support  # noqa: F401 - puts `agents/` on the path
from prose_agent.permissions import Permissions, describe, grant
from prose_agent.wire import ProseError


class FakeAsker:
    """Answers whatever it was told to, and records what it was asked."""

    def __init__(self, *answers: str, broken: bool = False):
        self.answers = list(answers)
        self.broken = broken
        self.asked: list[dict] = []

    async def ask(self, prompt, choices=None, placeholder=None, timeout=0.0) -> str:
        if self.broken:
            raise ProseError("the connection to prose closed")
        self.asked.append(
            {"prompt": prompt, "choices": choices, "placeholder": placeholder})
        return self.answers.pop(0) if self.answers else "Deny"


def decide(permissions, tool, arguments):
    return asyncio.run(permissions.decide(tool, arguments))


class OneAtATime(unittest.TestCase):
    def test_allow_once_does_not_stick(self) -> None:
        asker = FakeAsker("Allow once", "Allow once")
        permissions = Permissions(asker)
        self.assertTrue(decide(permissions, "Bash", {"command": "git status"}).allowed)
        self.assertTrue(decide(permissions, "Bash", {"command": "git status"}).allowed)
        self.assertEqual(len(asker.asked), 2, "asked both times")

    def test_from_now_on_sticks(self) -> None:
        asker = FakeAsker("Allow Bash(swift) from now on")
        permissions = Permissions(asker)
        self.assertTrue(decide(permissions, "Bash", {"command": "swift test"}).allowed)
        self.assertTrue(decide(permissions, "Bash", {"command": "swift build"}).allowed)
        self.assertEqual(len(asker.asked), 1, "the second one did not ask")

    def test_a_grant_is_the_executable_not_the_tool(self) -> None:
        """"Allow Bash from now on" is bypassPermissions reached by one click,
        and nobody clicking yes three times means to grant that."""
        asker = FakeAsker("Allow Bash(swift) from now on")
        permissions = Permissions(asker)
        decide(permissions, "Bash", {"command": "swift test"})
        refused = decide(permissions, "Bash", {"command": "rm -rf /"})
        self.assertFalse(refused.allowed, "a different executable still asks")

    def test_a_grant_on_anything_else_is_the_tool(self) -> None:
        self.assertEqual(grant("Edit", {"file_path": "/a"}), "Edit")
        self.assertEqual(grant("Bash", {"command": "git log"}), "Bash(git)")
        self.assertEqual(grant("Bash", {}), "Bash", "nothing to key on")


class Refusals(unittest.TestCase):
    def test_deny_is_a_refusal(self) -> None:
        answer = decide(Permissions(FakeAsker("Deny")), "Write", {"file_path": "/a"})
        self.assertFalse(answer.allowed)
        self.assertEqual(answer.message, "The user declined.")

    def test_typed_text_becomes_the_reason(self) -> None:
        """The card's choices and placeholder are orthogonal, and this is what
        that is for: a redirect costs one sentence instead of an interrupt."""
        answer = decide(
            Permissions(FakeAsker("use the test fixture, not the live database")),
            "Bash", {"command": "psql production"})
        self.assertFalse(answer.allowed)
        self.assertEqual(answer.message, "use the test fixture, not the live database")

    def test_an_unanswerable_question_denies(self) -> None:
        """prose has gone, or the pane has. Never fall open when the person
        cannot be reached."""
        answer = decide(Permissions(FakeAsker(broken=True)), "Bash", {"command": "x"})
        self.assertFalse(answer.allowed)
        self.assertIn("declined", answer.message)


class TheCard(unittest.TestCase):
    def test_it_names_the_tool_and_what_it_wants(self) -> None:
        self.assertEqual(describe("Bash", {"command": "swift test --filter Split"}),
                         "Bash wants to run: swift test --filter Split")
        self.assertEqual(describe("Edit", {"file_path": "/Sources/Host.swift"}),
                         "Edit wants to edit: /Sources/Host.swift")

    def test_an_unreadable_call_still_says_something(self) -> None:
        self.assertEqual(describe("Write", {}), "Write wants to write something.")

    def test_the_buttons_say_what_is_being_granted(self) -> None:
        asker = FakeAsker("Deny")
        decide(Permissions(asker), "Bash", {"command": "npm install left-pad"})
        self.assertEqual(asker.asked[0]["choices"],
                         ["Allow once", "Allow Bash(npm) from now on", "Deny"])
        self.assertTrue(asker.asked[0]["placeholder"], "and a text field")


if __name__ == "__main__":
    unittest.main()


class Withdrawing(unittest.TestCase):
    """Escape, while a card is waiting for an answer."""

    def test_an_abandoned_question_is_a_refusal_not_an_exception(self) -> None:
        """It has to come back as a decision. A `CancelledError` escaping the
        callback goes into the SDK's control protocol, which is not a place to
        throw from."""
        from prose_agent.asking import Asker

        class Silent:
            session = 1

            async def call(self, method, params, timeout=0.0):
                await asyncio.sleep(3600)

        async def interrupted() -> object:
            asker = Asker(Silent())
            permissions = Permissions(asker)
            deciding = asyncio.ensure_future(
                permissions.decide("Bash", {"command": "rm -rf /"}))
            await asyncio.sleep(0)
            await asyncio.sleep(0)
            asker.abandon()
            return await deciding

        answer = asyncio.run(interrupted())
        self.assertFalse(answer.allowed)

    def test_a_real_cancellation_still_unwinds(self) -> None:
        """Shutdown must not be mistaken for a withdrawn question, or the
        agent never stops."""
        from prose_agent.asking import Asker

        class Silent:
            session = 1

            async def call(self, method, params, timeout=0.0):
                await asyncio.sleep(3600)

        async def cancelled() -> bool:
            asking = asyncio.ensure_future(Asker(Silent()).ask("still there?"))
            await asyncio.sleep(0)
            await asyncio.sleep(0)
            asking.cancel()
            try:
                await asking
            except asyncio.CancelledError:
                return True
            return False

        self.assertTrue(asyncio.run(cancelled()))
