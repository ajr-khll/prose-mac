"""The plumbing that does not need the SDK: prompts, prompt-shapes, failures."""

from __future__ import annotations

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
