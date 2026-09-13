"""What the pane draws, for a turn the model never sees.

Every test here is one of the defects `reference/agent-plan.md` records, and
the first is the one that mattered: the harness as written emitted nothing at
all, because it dispatched on a `type` field the SDK's blocks do not have.
"""

from __future__ import annotations

import unittest

import support
from prose_agent.events import Events
from prose_agent.harness import Harness


class Band(unittest.TestCase):
    def setUp(self) -> None:
        self.wire = support.FakeWire()
        self.harness = Harness(Events(self.wire))


class BlocksWithoutAType(Band):
    """The SDK's block dataclasses carry no discriminator field."""

    def test_text_is_drawn(self) -> None:
        self.harness.observe(support.AssistantMessage([support.TextBlock("hello")]))
        started = self.wire.of("message.start")
        self.assertEqual(len(started), 1, "a text block must open a message")
        self.assertEqual(started[0]["role"], "agent")
        self.assertEqual(self.wire.text(started[0]["id"]), "hello")

    def test_thinking_is_drawn_as_thinking(self) -> None:
        self.harness.observe(
            support.AssistantMessage([support.ThinkingBlock("mulling it over")]))
        self.assertEqual(self.wire.of("message.start")[0]["role"], "thinking")

    def test_a_tool_call_opens_a_row(self) -> None:
        self.harness.observe(support.AssistantMessage(
            [support.ToolUseBlock("t1", "Bash", {"command": "swift test"})]))
        row = self.wire.of("activity")[0]
        self.assertEqual(row["label"], "Bash(swift test)")
        self.assertEqual(row["state"], "running")
        self.assertEqual(row["category"], "tool")


class ActivityRows(Band):
    def test_a_result_keeps_the_rows_label(self) -> None:
        """prose overwrites a label with whatever arrives, and drops an
        activity carrying none — so a resolving update has to resend it."""
        self.harness.observe(support.AssistantMessage(
            [support.ToolUseBlock("t1", "Bash", {"command": "swift test"})]))
        self.harness.observe(support.UserMessage(
            [support.ToolResultBlock("t1", "95 passed")]))

        rows = self.wire.of("activity")
        self.assertEqual(len(rows), 2, "start and resolve, same id")
        self.assertEqual(rows[0]["id"], rows[1]["id"], "or prose draws two rows")
        self.assertEqual(rows[1]["label"], "Bash(swift test)", "the label survives")
        self.assertEqual(rows[1]["detail"], "95 passed")
        self.assertEqual(rows[1]["state"], "ok")

    def test_an_empty_result_leaves_the_detail_alone(self) -> None:
        self.harness.observe(support.AssistantMessage(
            [support.ToolUseBlock("t1", "Bash", {"command": "swift test"})]))
        self.harness.observe(support.UserMessage([support.ToolResultBlock("t1", "")]))
        self.assertIsNone(self.wire.of("activity")[1]["detail"])

    def test_a_failed_tool_resolves_as_an_error(self) -> None:
        self.harness.observe(support.AssistantMessage(
            [support.ToolUseBlock("t1", "Bash", {"command": "false"})]))
        self.harness.observe(support.UserMessage(
            [support.ToolResultBlock("t1", "exit 1", is_error=True)]))
        self.assertEqual(self.wire.of("activity")[1]["state"], "error")

    def test_a_skill_is_a_ring_with_its_name(self) -> None:
        self.harness.observe(support.AssistantMessage(
            [support.ToolUseBlock("s1", "Skill", {"skill": "prose:page-digest"})]))
        row = self.wire.of("activity")[0]
        self.assertEqual(row["category"], "skill", "a disc rather than a ring otherwise")
        self.assertEqual(row["label"], "Skill")
        self.assertEqual(row["detail"], "prose:page-digest")

    def test_a_prose_tool_loses_its_mcp_prefix(self) -> None:
        self.harness.observe(support.AssistantMessage(
            [support.ToolUseBlock("p1", "mcp__prose__prose_wait", {"pane": 2})]))
        self.assertEqual(self.wire.of("activity")[0]["label"], "prose_wait")


class HowTheTurnEnded(Band):
    def test_an_error_is_reported_as_a_string(self) -> None:
        """`turn_ended` puts this in `error`, and `parseEvent` reads it as a
        string — anything else and the notice silently vanishes."""
        self.harness.observe(support.ResultMessage(
            subtype="error", is_error=True, errors=["rate limited"]))
        self.assertEqual(self.harness.error, "rate limited")
        self.assertIsInstance(self.harness.error, str)

    def test_a_successful_turn_reports_nothing(self) -> None:
        self.harness.observe(support.ResultMessage())
        self.assertIsNone(self.harness.error)

    def test_completed_is_not_a_header_field(self) -> None:
        """`completed` is the ordinary ending. Testing against `end_turn`, as
        this used to, stamped `stopped` into the header on every good turn."""
        self.harness.observe(support.ResultMessage(terminal_reason="completed"))
        self.assertEqual(self.wire.of("status"), [])

    def test_a_cap_is_worth_saying(self) -> None:
        self.harness.observe(support.ResultMessage(terminal_reason="max_turns"))
        self.assertEqual(self.wire.of("status")[0]["fields"]["stopped"], "max_turns")

    def test_an_abort_reads_as_an_interruption(self) -> None:
        self.harness.observe(support.ResultMessage(terminal_reason="aborted_streaming"))
        self.assertEqual(self.harness.error, "interrupted")

    def test_cost_and_tokens_reach_the_header(self) -> None:
        self.harness.observe(support.ResultMessage(
            total_cost_usd=0.0123, usage={"input_tokens": 20, "output_tokens": 7}))
        fields = {k: v for e in self.wire.of("status") for k, v in e["fields"].items()}
        self.assertEqual(fields["cost"], "$0.0123")
        self.assertEqual(fields["tokens"], "20→7")

    def test_the_model_reaches_the_header_once(self) -> None:
        for _ in range(3):
            self.harness.observe(support.AssistantMessage([], model="claude-opus-5"))
        models = [e for e in self.wire.of("status") if "model" in e["fields"]]
        self.assertEqual(len(models), 1)


class Streaming(Band):
    """`include_partial_messages` is what gives prose's 16ms coalescing
    something to coalesce."""

    def stream_one_reply(self) -> str:
        self.harness.observe(support.stream(type="message_start", message={}))
        self.harness.observe(support.stream(
            type="content_block_start", index=0,
            content_block={"type": "text", "text": ""}))
        for word in ("The ", "split ", "tree ", "holds"):
            self.harness.observe(support.stream(
                type="content_block_delta", index=0,
                delta={"type": "text_delta", "text": word}))
        return self.wire.of("message.start")[0]["id"]

    def test_deltas_arrive_one_at_a_time(self) -> None:
        block = self.stream_one_reply()
        self.assertEqual(len(self.wire.of("delta")), 4, "not one lump")
        self.assertEqual(self.wire.text(block), "The split tree holds")

    def test_the_whole_message_does_not_draw_it_again(self) -> None:
        """The complete `AssistantMessage` arrives *before* that block's
        `content_block_stop`, so arrival order cannot decide this."""
        self.stream_one_reply()
        self.harness.observe(support.AssistantMessage(
            [support.TextBlock("The split tree holds")]))
        self.assertEqual(len(self.wire.of("message.start")), 1, "drawn twice")
        self.assertEqual(len(self.wire.of("delta")), 4)

    def test_the_block_is_closed_on_stop(self) -> None:
        block = self.stream_one_reply()
        self.harness.observe(support.stream(type="content_block_stop", index=0))
        self.assertEqual(self.wire.of("message.end")[0]["id"], block)

    def test_a_tool_call_is_never_drawn_from_deltas(self) -> None:
        """Its arguments arrive as partial JSON, which cannot make a label."""
        self.harness.observe(support.stream(type="message_start", message={}))
        self.harness.observe(support.stream(
            type="content_block_start", index=0,
            content_block={"type": "tool_use", "id": "t1", "name": "Read", "input": {}}))
        self.harness.observe(support.stream(
            type="content_block_delta", index=0,
            delta={"type": "input_json_delta", "partial_json": '{"path": "/e'}))
        self.assertEqual(self.wire.events, [], "nothing drawable yet")

        self.harness.observe(support.AssistantMessage(
            [support.ToolUseBlock("t1", "Read", {"path": "/etc/hosts"})]))
        self.assertEqual(self.wire.of("activity")[0]["label"], "Read(/etc/hosts)")

    def test_thinking_streams_too(self) -> None:
        self.harness.observe(support.stream(type="message_start", message={}))
        self.harness.observe(support.stream(
            type="content_block_start", index=0,
            content_block={"type": "thinking", "thinking": ""}))
        self.harness.observe(support.stream(
            type="content_block_delta", index=0,
            delta={"type": "thinking_delta", "thinking": "weighing it"}))
        self.assertEqual(self.wire.of("message.start")[0]["role"], "thinking")
        self.assertEqual(len(self.wire.of("delta")), 1)

    def test_a_delta_for_a_block_nobody_opened_is_dropped(self) -> None:
        self.harness.observe(support.stream(
            type="content_block_delta", index=7, delta={"text": "orphan"}))
        self.assertEqual(self.wire.events, [])


class WhatLoadedAtStartup(Band):
    def test_the_skill_count_reaches_the_header(self) -> None:
        """The SDK skips a plugin path that does not exist without saying so,
        so this is the only evidence the skills are really there."""
        self.harness.observe(support.SystemMessage(
            "init", {"skills": ["prose:spawn-coder", "prose:page-digest"],
                     "plugins": [{"name": "prose"}]}))
        self.assertEqual(self.wire.of("status")[0]["fields"]["skills"], "2")

    def test_other_system_subtypes_are_ignored(self) -> None:
        self.harness.observe(support.SystemMessage("status", {"status": "requesting"}))
        self.assertEqual(self.wire.events, [])


class TheUnknown(Band):
    """The SDK emits `HookEventMessage`, `RateLimitEvent` and more besides."""

    def test_an_unknown_message_draws_nothing(self) -> None:
        class RateLimitEvent:
            rate_limit_info = {"status": "allowed"}

        self.harness.observe(RateLimitEvent())
        self.assertEqual(self.wire.events, [])

    def test_a_string_content_is_not_walked_character_by_character(self) -> None:
        """`UserMessage.content` is `str | list`. Iterating the string would
        draw one block per letter."""
        self.harness.observe(support.UserMessage("just text"))
        self.assertEqual(self.wire.events, [])

    def test_a_renamed_block_class_is_still_drawn(self) -> None:
        class TextBlockV2:
            def __init__(self, text: str) -> None:
                self.text = text

        self.harness.observe(support.AssistantMessage([TextBlockV2("still here")]))
        self.assertEqual(len(self.wire.of("message.start")), 1)


if __name__ == "__main__":
    unittest.main()


class Interruptions(Band):
    """Escape during a tool call, which is when it actually gets pressed."""

    def test_an_abort_beats_the_error_flag(self) -> None:
        """Escape mid-tool comes back with `is_error` set *and* a `result`
        holding an internal diagnostic. The person pressed a key; tell them
        that, not `[ede_diagnostic] result_type=user …`."""
        self.harness.observe(support.ResultMessage(
            is_error=True,
            result="[ede_diagnostic] result_type=user last_content_type=n/a",
            terminal_reason="aborted_streaming"))
        self.assertEqual(self.harness.error, "interrupted")

    def test_a_diagnostic_is_not_shown_as_a_reason(self) -> None:
        self.harness.observe(support.ResultMessage(
            is_error=True, result="[ede_diagnostic] stop_reason=tool_use",
            terminal_reason="completed"))
        self.assertEqual(self.harness.error, "the turn failed")

    def test_a_real_reason_still_gets_through(self) -> None:
        self.harness.observe(support.ResultMessage(
            is_error=True, result="Credit balance is too low",
            terminal_reason="completed"))
        self.assertEqual(self.harness.error, "Credit balance is too low")


class LabellingTheUnfamiliar(Band):
    """A row — and the permission card beside it — has to name the call.

    `AskUserQuestion` carries none of the keys `_label` knows, so it drew as a
    bare `AskUserQuestion` and its card read "wants to use something", which is
    a question nobody can answer.
    """

    def test_an_unfamiliar_tool_is_still_named(self) -> None:
        self.harness.observe(support.AssistantMessage([support.ToolUseBlock(
            "a1", "Mystery", {"questions": [{"question": "Which reading of §7.1?",
                                             "header": "Reading"}]})]))
        self.assertEqual(self.wire.of("activity")[0]["label"],
                         "Mystery(Which reading of §7.1?)")

    def test_the_most_informative_string_wins_not_the_first(self) -> None:
        """Sorted by key, `header` would beat `question` and the row would read
        `Reading`."""
        from prose_agent.harness import _anyText

        self.assertEqual(
            _anyText({"header": "Reading", "question": "Which reading of §7.1?"}),
            "Which reading of §7.1?")

    def test_a_known_key_still_wins_over_the_search(self) -> None:
        self.harness.observe(support.AssistantMessage([support.ToolUseBlock(
            "a1", "Bash", {"command": "ls", "description": "a much longer string"})]))
        self.assertEqual(self.wire.of("activity")[0]["label"], "Bash(ls)")

    def test_nothing_to_say_is_still_not_a_crash(self) -> None:
        self.harness.observe(
            support.AssistantMessage([support.ToolUseBlock("a1", "Mystery", {})]))
        self.assertEqual(self.wire.of("activity")[0]["label"], "Mystery")

    def test_it_does_not_wander_into_something_enormous(self) -> None:
        from prose_agent.harness import _anyText

        deep = {"a": {"b": {"c": {"d": "too far down to be worth finding"}}}}
        self.assertIsNone(_anyText(deep))
