"""The plumbing that does not need the SDK: prompts, prompt-shapes, failures."""

from __future__ import annotations

import pathlib
import unittest
from types import SimpleNamespace

import support  # noqa: F401 - puts `agents/` on the path
from prose_agent.loop import _appendToPrompt, _explain, _prompt


class Prompts(unittest.TestCase):
    def test_a_users_message_is_passed_through(self) -> None:
        self.assertEqual(_prompt("message", {"text": "hello"}), "hello")

    def test_a_child_asking_is_labelled_as_such(self) -> None:
        said = _prompt("child.ask", {"pane": 3, "prompt": "which reading?"})
        self.assertIn("pane 3", said)
        self.assertIn("prose_answer", said)

    def test_an_unknown_notification_says_nothing(self) -> None:
        self.assertEqual(_prompt("teatime", {}), "")


class TheRuntimeParagraph(unittest.TestCase):
    def test_a_plain_prompt_is_extended(self) -> None:
        options = SimpleNamespace(system_prompt="You are a personal agent.")
        _appendToPrompt(options, " Your pane is 1.")
        self.assertEqual(options.system_prompt, "You are a personal agent. Your pane is 1.")

    def test_a_missing_prompt_becomes_one(self) -> None:
        options = SimpleNamespace(system_prompt=None)
        _appendToPrompt(options, "Your pane is 1.")
        self.assertEqual(options.system_prompt, "Your pane is 1.")

    def test_a_preset_is_appended_to_rather_than_replaced(self) -> None:
        options = SimpleNamespace(
            system_prompt={"type": "preset", "preset": "claude_code", "append": "Be brief."})
        _appendToPrompt(options, " Your pane is 1.")
        self.assertEqual(options.system_prompt["preset"], "claude_code")
        self.assertEqual(options.system_prompt["append"], "Be brief. Your pane is 1.")

    def test_a_file_prompt_is_left_alone(self) -> None:
        """There is nothing to append to from here, and quietly dropping the
        author's file would be worse than not adding the paragraph."""
        options = SimpleNamespace(system_prompt={"type": "file", "path": "/p.txt"})
        _appendToPrompt(options, "Your pane is 1.")
        self.assertEqual(options.system_prompt, {"type": "file", "path": "/p.txt"})


class AnAllowanceThatConfines(unittest.TestCase):
    """`allow:` is a declaration, so it has to be the answer.

    The regression: `serve` appended every non-denied prose tool to
    `allowed_tools` after `permissions.allowance` had composed a precise list,
    so a narrow expert was auto-approved for tools its file never mentioned.
    `archetype-designer` declares seven and ran with fourteen.
    """

    def declared(self) -> list[str]:
        from prose_agent import archetypes
        from prose_agent.permissions import allowance

        return allowance(archetypes.load("archetype-designer"))[0]

    def test_a_general_pane_agent_is_still_widened(self) -> None:
        """It has no declaration to be measured against, and a card for
        `prose_wait` is friction with nothing bought by it."""
        from prose_agent.loop import auto_approved

        widened = auto_approved(["Read"], "prose", (), confine=False)
        self.assertIn("Read", widened)
        self.assertIn("mcp__prose__prose_wait", widened)

    def test_an_archetype_gets_exactly_what_it_named(self) -> None:
        from prose_agent.loop import auto_approved

        declared = self.declared()
        self.assertEqual(auto_approved(declared, "prose", (), confine=True),
                         declared)

    def test_the_tools_it_did_not_name_are_not_auto_approved(self) -> None:
        """Not unreachable — that is `deny`'s job — but a card, which is the
        documented meaning of leaving a tool out."""
        from prose_agent.loop import auto_approved

        confined = auto_approved(self.declared(), "prose", (), confine=True)
        for never_named in ("prose_close", "prose_send", "prose_interrupt",
                            "prose_read", "prose_answer"):
            self.assertNotIn(f"mcp__prose__{never_named}", confined)

    def test_the_archetype_agent_asks_to_be_confined(self) -> None:
        """The fix is worth nothing if the one caller with a declaration does
        not pass it, and nothing else in the tree would catch that."""
        source = (pathlib.Path(__file__).resolve().parents[1]
                  / "archetype_agent.py").read_text()
        self.assertIn("confine=True", source)


class TidyingUp(unittest.TestCase):
    """The parent closes the panes it opened once the job is done.

    The rule is in the prompt, but it is worth pinning that the tool is
    actually *there* without a card — a prompt telling the model to do
    something it would be interrupted for is a prompt it will stop following.
    """

    def test_a_parent_can_close_without_raising_a_card(self) -> None:
        from prose_agent.loop import auto_approved
        from prose_agent.tools import BROWSER

        held = auto_approved(["Read"], "prose", tuple(BROWSER), confine=False)
        self.assertIn("mcp__prose__prose_close", held)

    def test_the_prompt_says_when_not_to_close(self) -> None:
        """The dangerous half. Closing a pane mid-turn throws away the work and
        its answer, so the exceptions have to be as legible as the rule."""
        from prose_agent.prompt import SYSTEM

        self.assertIn("CLOSE WHAT YOU OPENED", SYSTEM)
        self.assertIn("still working", SYSTEM)
        self.assertIn("question outstanding", SYSTEM)

    def test_the_reuse_rule_no_longer_contradicts_it(self) -> None:
        """Both rules are about the same pane: keep it for the length of a job,
        close it when the job is over. The old wording said only the first."""
        from prose_agent.prompt import SYSTEM

        self.assertIn("WHILE THE ERRAND LASTS", SYSTEM)


class Failures(unittest.TestCase):
    def test_an_auth_failure_says_what_to_do(self) -> None:
        said = _explain(RuntimeError("Invalid API key · Please run /login"))
        self.assertIn("ANTHROPIC_API_KEY", said)
        self.assertIn("~/.config/prose/env", said)

    def test_anything_else_is_passed_through(self) -> None:
        self.assertEqual(_explain(ValueError("the socket went away")),
                         "the socket went away")

    def test_a_silent_exception_still_names_itself(self) -> None:
        self.assertEqual(_explain(TimeoutError()), "TimeoutError")


if __name__ == "__main__":
    unittest.main()
