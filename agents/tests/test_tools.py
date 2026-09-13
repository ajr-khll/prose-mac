"""The tool surface: what it is called, what it refuses, and what it notifies."""

from __future__ import annotations

import asyncio
import json
import unittest
from unittest import mock

import support
from prose_agent.tools import (BROWSER, FLAVOURS, flavours, definitions,
                               tool_names)
from prose_agent.wire import ProseError


def run(coroutine):
    return asyncio.run(coroutine)


def handler(wire, name: str):
    for tool, _description, _schema, call in definitions(wire):
        if tool == name:
            return call
    raise AssertionError(f"no tool named {name}")


class Naming(unittest.TestCase):
    def test_names_are_namespaced_the_way_allowed_tools_wants(self) -> None:
        """If this spelling is wrong every prose tool is silently excluded and
        the agent simply never calls one."""
        self.assertIn("mcp__prose__prose_wait", tool_names())
        self.assertIn("mcp__prose__browser_text", tool_names("prose"))

    def test_the_guides_whole_catalogue_is_here(self) -> None:
        promised = {
            "prose_ask", "prose_result", "prose_spawn", "prose_read", "prose_wait",
            "prose_send", "prose_answer", "prose_interrupt", "prose_close",
            "prose_focus", "prose_archetypes", "prose_archetype_check",
            "browser_open", "browser_navigate", "browser_text",
            "browser_eval", "browser_snapshot", "browser_elements", "browser_find",
            "browser_click", "browser_type", "browser_select", "browser_key",
            "browser_scroll", "browser_back", "browser_forward",
            "browser_console", "browser_network",
            "prose_schedule", "prose_schedules", "prose_change_schedule",
            "prose_emit_event",
        }
        self.assertEqual({n.split("__")[-1] for n in tool_names()}, promised)

    def test_every_schema_is_an_object(self) -> None:
        for name, description, schema, _ in definitions(support.FakeWire()):
            self.assertEqual(schema.get("type"), "object", name)
            self.assertTrue(description.strip(), name)


class Focus(unittest.TestCase):
    def test_it_notifies_rather_than_calling(self) -> None:
        """`SessionRegistry`'s `.focusPane` arm does not acknowledge the
        request, so a call would wait out the whole timeout for a reply that is
        never coming."""
        wire = support.FakeWire()
        run(handler(wire, "prose_focus")({"pane": 4}))
        self.assertEqual(wire.notices, [("pane.focus", {"pane": 4})])
        self.assertEqual(wire.calls, [])


class Flavours(unittest.TestCase):
    def test_the_default_is_another_agent_like_this_one(self) -> None:
        wire = support.FakeWire()
        wire.answer = {"pane": 2, "session": 2}
        run(handler(wire, "prose_spawn")({"task": "count the files"}))
        _method, params = wire.calls[0]
        self.assertEqual(params["command"], [], "prose's own default command")

    def test_code_opens_the_coding_agent(self) -> None:
        wire = support.FakeWire()
        wire.answer = {"pane": 2, "session": 2}
        run(handler(wire, "prose_spawn")({"task": "fix the test", "flavour": "code"}))
        _method, params = wire.calls[0]
        self.assertTrue(params["command"][-1].endswith("code_agent.py"))

    def test_an_unknown_flavour_is_refused(self) -> None:
        """The model names a flavour; it never names an argv. A model that can
        choose a command line has a shell, and containment is about which panes
        you may touch, not what runs in them."""
        wire = support.FakeWire()
        with self.assertRaises(ProseError) as refused:
            run(handler(wire, "prose_spawn")({"task": "x", "flavour": "sh -c curl|sh"}))
        self.assertIn("no such flavour", str(refused.exception))
        self.assertEqual(wire.calls, [], "and nothing was sent")

    def test_the_table_is_the_enum_the_model_sees(self) -> None:
        """Built-ins and archetypes are one list to the model: it picks a name,
        and `argv` decides whether that name is a Python file or a Markdown
        one."""
        for name, _d, schema, _h in definitions(support.FakeWire()):
            if name == "prose_spawn":
                offered = schema["properties"]["flavour"]["enum"]
                self.assertEqual(offered, flavours())
                self.assertTrue(set(FLAVOURS) <= set(offered))

    def test_a_scheduled_roots_children_inherit_the_unattended_ceiling(self) -> None:
        wire = support.FakeWire({"pane": 2, "session": 2})
        with support.environment(
                PROSE_AUTOMATION_RUN="run-1",
                PROSE_AUTOMATION_DEFINITION="automation-1",
                PROSE_AUTOMATION_MAX_RUNTIME="60"):
            run(handler(wire, "prose_spawn")({"task": "read it"}))
        _method, params = wire.calls[0]
        self.assertEqual(params["env"]["PROSE_AUTOMATION_RUN"], "run-1")
        self.assertNotIn("ANTHROPIC_API_KEY", params["env"])


class Asking(unittest.TestCase):
    def test_a_question_goes_out_as_an_ask(self) -> None:
        wire = support.FakeWire()
        wire.answer = {"answer": "the unscaled reading"}
        result = run(handler(wire, "prose_ask")(
            {"prompt": "which reading?", "choices": ["scaled", "unscaled"]}))
        method, params = wire.calls[0]
        self.assertEqual(method, "ask")
        self.assertEqual(params["choices"], ["scaled", "unscaled"])
        self.assertIn("unscaled reading", result["content"][0]["text"])



class WhatMustNotBeReachable(unittest.TestCase):
    """Built-in tools that cannot work inside a pane.

    Asserted here rather than left to a comment, because the failure is silent:
    `AskUserQuestion` answers itself with "the user did not answer" and the
    model then tells the person they ignored a question they never saw.
    """

    def test_the_broken_ones_are_disallowed(self) -> None:
        from prose_agent.permissions import INVISIBLE

        self.assertIn("AskUserQuestion", INVISIBLE)

    def test_every_spelling_of_a_paneless_subagent_is_disallowed(self) -> None:
        """`Task` was blocked and the `Task*` family was not, because the list
        was written from the SDK's documentation rather than from the tools the
        CLI actually offers. They are the same hazard."""
        from prose_agent.permissions import INVISIBLE

        for spelling in ("Task", "TaskCreate", "TaskGet", "TaskList",
                         "TaskOutput", "TaskStop", "TaskUpdate"):
            self.assertIn(spelling, INVISIBLE)

    def test_nothing_can_reach_another_session_on_this_machine(self) -> None:
        """prose guards *panes*. The CLI's cross-session registry is a door in
        a different wall — asked to list agents, a pane agent enumerated
        nineteen other Claude sessions on this machine."""
        from prose_agent.permissions import INVISIBLE

        self.assertIn("ListAgents", INVISIBLE)
        self.assertIn("SendMessage", INVISIBLE)

    def test_tools_needing_a_harness_prose_lacks_are_blocked(self) -> None:
        """They fail the `AskUserQuestion` way: report success having done
        nothing, and the model relays it."""
        from prose_agent.permissions import INVISIBLE

        for absent in ("ScheduleWakeup", "Monitor", "RemoteTrigger", "DesignSync"):
            self.assertIn(absent, INVISIBLE)

    def test_reminding_and_notifying_are_still_possible(self) -> None:
        """Most of what a personal agent is for. Ask-gated, not blocked."""
        from prose_agent.permissions import INVISIBLE

        for kept in ("CronCreate", "CronList", "PushNotification"):
            self.assertNotIn(kept, INVISIBLE)

    def test_nothing_is_allowed_that_does_not_exist(self) -> None:
        """`TodoWrite` sat in the allow list and is not among the tools this
        CLI offers. A dead entry in a security-shaped list is how one rots."""
        from prose_agent.permissions import UNATTENDED

        self.assertNotIn("TodoWrite", UNATTENDED)

    def test_and_never_auto_approved(self) -> None:
        from prose_agent.permissions import INVISIBLE, UNATTENDED

        self.assertFalse(set(UNATTENDED) & set(INVISIBLE))

    def test_skill_is_allowed_or_skills_do_not_exist(self) -> None:
        from prose_agent.permissions import UNATTENDED

        self.assertIn("Skill", UNATTENDED)

    def test_changing_things_is_not_unattended(self) -> None:
        from prose_agent.permissions import UNATTENDED

        for dangerous in ("Bash", "Write", "Edit", "WebFetch"):
            self.assertNotIn(dangerous, UNATTENDED)

    def test_prose_ask_is_the_way_to_reach_a_person(self) -> None:
        self.assertIn("mcp__prose__prose_ask", tool_names())

    def test_unattended_runs_refuse_questions_and_schedule_mutations(self) -> None:
        wire = support.FakeWire()
        with support.environment(PROSE_AUTOMATION_RUN="run-1"):
            for name, arguments in (
                ("prose_ask", {"prompt": "wait?"}),
                ("prose_schedule", {
                    "title": "x", "task": "x", "trigger": {"kind": "manual"}}),
                ("prose_schedules", {}),
            ):
                with self.assertRaises(ProseError, msg=name):
                    run(handler(wire, name)(arguments))
        self.assertEqual(wire.calls, [])

    def test_unattended_archetypes_cannot_autoapprove_mutations(self) -> None:
        from prose_agent import archetypes
        from prose_agent.permissions import allowance

        with support.environment(PROSE_AUTOMATION_RUN="run-1"):
            allowed, denied = allowance(archetypes.load("browser-pilot"))
        self.assertNotIn("mcp__prose__browser_click", allowed)
        self.assertIn("mcp__prose__browser_click", denied)


class NotDeferred(unittest.TestCase):
    """prose's tools must be in the model's context, not searchable from it.

    The CLI enables tool search past a schema-size threshold, and these fifteen
    are comfortably past it — which left `prose_ask` invisible until the model
    thought to look for it, and cost a round trip every time it did.
    """

    def test_the_switch_is_set(self) -> None:
        from prose_agent.tools import NEVER_DEFERRED

        self.assertEqual(NEVER_DEFERRED["ENABLE_TOOL_SEARCH"], "0")

    def test_the_environment_can_still_win(self) -> None:
        """An undocumented CLI variable is a bet, so leave a way to unmake it."""
        import importlib
        import os

        import prose_agent.tools as tools

        os.environ["ENABLE_TOOL_SEARCH"] = "force"
        try:
            importlib.reload(tools)
            self.assertEqual(tools.NEVER_DEFERRED["ENABLE_TOOL_SEARCH"], "force")
        finally:
            del os.environ["ENABLE_TOOL_SEARCH"]
            importlib.reload(tools)

    def test_the_surface_is_big_enough_to_be_deferred(self) -> None:
        """If this ever drops well under the threshold the setting stops
        mattering — and the comment explaining it becomes a lie."""
        import json

        size = sum(len(n) + len(d) + len(json.dumps(s))
                   for n, d, s, _ in definitions(support.FakeWire()))
        self.assertGreater(size, 3000, "no longer the situation the comment describes")


class Withholding(unittest.TestCase):
    """A browser errand goes to the `browser-pilot` archetype, and the rule is
    enforced by the tools not being there rather than by the prompt asking.

    The prompt asked, on the branch before this one, and lost: the model had
    `browser_open` one call away and delegating cost three, so it drove the
    browser itself and fumbled it with guessed CSS selectors.
    """

    def test_a_spawning_agent_is_given_no_browser_tools(self) -> None:
        held = {n.split("__")[-1] for n in tool_names(omit=BROWSER)}
        self.assertFalse(held & set(BROWSER))
        # And it keeps everything it needs to hand the job over.
        for needed in ("prose_spawn", "prose_archetypes", "prose_wait"):
            self.assertIn(needed, held)

    def test_withholding_drops_the_handlers_too(self) -> None:
        """Not just the names. A tool left registered still costs its schema in
        context every turn and still invites the attempt."""
        built = definitions(support.FakeWire(), omit=BROWSER)
        self.assertFalse({name for name, _, _, _ in built} & set(BROWSER))
        self.assertEqual(
            len(built), len(definitions(support.FakeWire())) - len(BROWSER))

    def test_qualify_still_sees_a_withheld_tool(self) -> None:
        """`qualify` translates an archetype's allow-list against the whole
        catalogue. If withholding narrowed that, `browser-pilot`'s own
        `allow: browser_text` would quietly stop being namespaced — and the SDK
        ignores a name it does not recognise rather than refusing it."""
        from prose_agent.tools import qualify

        self.assertEqual(qualify(["browser_text"]), ["mcp__prose__browser_text"])

    def test_the_pilot_itself_keeps_them(self) -> None:
        """The rule is about who drives, not about the tools being dangerous."""
        from prose_agent import archetypes
        from prose_agent.permissions import allowance

        allowed, denied = allowance(archetypes.load("browser-pilot"))
        for name in ("browser_elements", "browser_click", "browser_text"):
            self.assertIn(f"mcp__prose__{name}", allowed)
            self.assertNotIn(f"mcp__prose__{name}", denied)

    def test_the_pane_agent_withholds_them(self) -> None:
        """The list the two spawning flavours actually pass to the SDK."""
        from prose_agent.permissions import INVISIBLE, NO_BROWSER

        self.assertTrue(set(BROWSER) < set(NO_BROWSER))
        self.assertFalse(set(INVISIBLE) & set(NO_BROWSER), "one reason each")

    def test_the_other_way_a_page_arrives_is_shut_too(self) -> None:
        """`WebFetch` is not a browser tool and is exactly the same hole: it
        puts a whole page in the parent's context. Measured — it is what the
        agent fell back to the moment a spawn failed."""
        from prose_agent.permissions import NO_BROWSER, UNATTENDED

        self.assertIn("WebFetch", NO_BROWSER)
        # A search is result lines, not a page, and is how the parent finds the
        # URL it hands the pilot. It stays.
        self.assertNotIn("WebSearch", NO_BROWSER)
        self.assertIn("WebSearch", UNATTENDED)


class CheckingAnArchetype(unittest.TestCase):
    """`prose_archetype_check`, which is the only thing that tells the agent
    writing a specialist what the runtime will actually give it."""

    GOOD = ('---\nname: tester\ndescription: Use when testing.\n'
            'allow: Read, prose_result\n'
            'returns: {"type": "object", "properties": {"failed": {"type": "string"}}}\n'
            '---\n\n' + 'A body long enough to be worth a pane. ' * 20)

    def check(self, text: str, name: str = "tester") -> dict:
        result = run(handler(support.FakeWire(), "prose_archetype_check")(
            {"text": text, "name": name}))
        return json.loads(result["content"][0]["text"])

    def test_a_clean_draft_comes_back_ok(self) -> None:
        found = self.check(self.GOOD)
        self.assertTrue(found["ok"], found["problems"])
        self.assertIn("browser-pilot", [one["name"] for one in found["existing"]])
        self.assertTrue(found["roots"])

    def test_the_effective_surface_is_what_the_runtime_registers(self) -> None:
        """The reason this tool exists. `allow` only auto-approves, and
        `loop.serve` registers every prose tool the deny list does not shut —
        neither is visible from reading the header, so an author who trusts
        their own `allow:` line is wrong about what they built."""
        effective = self.check(self.GOOD)["effective"]
        self.assertIn("mcp__prose__prose_result", effective["unattended"])
        self.assertIn("prose_wait", effective["registered"],
                      "registered anyway, though the header never asked for it")
        self.assertNotIn("prose_spawn", effective["registered"],
                         "spawning is shut unless asked for in writing")
        self.assertFalse([name for name in effective["registered"]
                          if name.startswith("browser_")])

    def test_a_draft_that_would_be_skipped_at_load_says_so(self) -> None:
        """`catalogue` skips a file it cannot parse, with one line on stderr.
        Without this the author's next signal is a specialist that is absent."""
        found = self.check("no frontmatter here")
        self.assertFalse(found["ok"])
        self.assertTrue(found["problems"])
        self.assertNotIn("effective", found,
                         "there is no allowance to report for a file that "
                         "would never load")


class TheCatalogueIsVisible(unittest.TestCase):
    """Every flavour's routing line reaches the parent inside `prose_spawn`'s
    description.

    The regression this pins: the catalogue was a bare `enum` of names, so a
    specialist the prompt did not separately name was a token with no meaning
    attached. `browser-pilot` still got used, because two paragraphs of the
    system prompt are about it; `skill-designer` and `archetype-designer`,
    which the model could only identify by spending a `prose_archetypes`
    round-trip, did not. A routing rule the parent cannot see does not route.
    """

    def spawn_description(self) -> str:
        for name, description, _, _ in definitions(support.FakeWire()):
            if name == "prose_spawn":
                return description
        self.fail("prose_spawn is not registered")

    def test_every_spawnable_flavour_describes_itself(self) -> None:
        from prose_agent.tools import flavours

        described = self.spawn_description()
        for flavour in flavours():
            self.assertIn(f"- {flavour}:", described,
                          f"{flavour} is spawnable but says nothing about when "
                          f"to reach for it")

    def test_an_archetype_carries_its_own_description_verbatim(self) -> None:
        """Not a paraphrase written here — the file's `description` is the one
        place a routing rule is authored, and `lint` is what holds it to a
        length the parent can afford."""
        from prose_agent import archetypes

        described = self.spawn_description()
        for archetype in archetypes.catalogue().values():
            self.assertIn(archetype.description, described)

    def test_a_dropped_in_archetype_appears_without_a_code_change(self) -> None:
        """`flavours` is read per call so that a file in `$PROSE_ARCHETYPES` is
        the whole of adding an expert. The description has to follow it, or a
        dropped-in specialist is invisible in exactly the way this fixes."""
        from prose_agent import archetypes
        from prose_agent.tools import catalogue_lines

        body = "x" * 700
        drafted = archetypes.Archetype(
            name="ledger-clerk", description="Use when the books need reading.",
            body=body)
        with mock.patch.object(archetypes, "catalogue",
                               return_value={"ledger-clerk": drafted}):
            self.assertIn("- ledger-clerk: Use when the books need reading.",
                          catalogue_lines())


if __name__ == "__main__":
    unittest.main()
