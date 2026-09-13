"""Archetypes, kept honest without running a model.

The failures worth catching here are the quiet ones: a tool name that is a
typo and is therefore ignored rather than refused, a parameter the body never
uses, a header that drifted from its filename. None of them raise anything at
runtime — they just produce an expert that is subtly not the one that was
written down.
"""

from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import support  # noqa: F401 - puts `agents/` on the path
from prose_agent import archetypes, tools
from prose_agent.tools import BROWSER
from prose_agent.permissions import INVISIBLE, UNATTENDED, allowance
from prose_agent.archetypes import Archetype, ArchetypeError

BUNDLED = Path(__file__).resolve().parent.parent / "archetypes"

MINIMAL = '''---
name: tester
description: Use when testing.
---

A body long enough to be worth loading.
'''


class TheFormat(unittest.TestCase):
    def parse(self, text: str, name: str = "tester") -> Archetype:
        return archetypes.parse(text, name)

    def test_a_minimal_archetype_parses(self) -> None:
        archetype = self.parse(MINIMAL)
        self.assertEqual(archetype.name, "tester")
        self.assertFalse(archetype.spawns, "spawning is off unless asked for")
        self.assertEqual(archetype.skills, (), "a narrow expert carries no catalogue")

    def test_the_header_must_agree_with_the_filename(self) -> None:
        """Otherwise one of the two is a typo and the spawn that fails is a
        long way from the file that caused it."""
        with self.assertRaises(ArchetypeError):
            self.parse(MINIMAL, name="something-else")

    def test_what_is_refused(self) -> None:
        for broken, why in [
            ("no frontmatter at all", "no header"),
            ("---\nname: tester\n", "header never closes"),
            ("---\nname: tester\n---\n\nbody", "no description"),
            ("---\nname: tester\ndescription: d\n---\n\n   ", "no body"),
            ('---\nname: tester\ndescription: d\nreturns: {not json\n---\n\nbody', "bad JSON"),
        ]:
            with self.assertRaises(ArchetypeError, msg=why):
                self.parse(broken)

    def test_lists_and_json_are_read_as_themselves(self) -> None:
        archetype = self.parse(
            '---\nname: tester\ndescription: Use when testing.\n'
            'allow: browser_text, prose_result\n'
            'returns: {"type": "object"}\n'
            'spawns: true\n---\n\nbody here')
        self.assertEqual(archetype.allow, ("browser_text", "prose_result"))
        self.assertEqual(archetype.returns, {"type": "object"})
        self.assertTrue(archetype.spawns)


class Binding(unittest.TestCase):
    def archetype(self, parameters: dict) -> Archetype:
        return archetypes.parse(
            f'---\nname: tester\ndescription: Use when testing.\n'
            f'parameters: {json.dumps(parameters)}\n---\n\nbody with {{one}}', "tester")

    def test_a_missing_required_parameter_is_an_error(self) -> None:
        with self.assertRaises(ArchetypeError):
            self.archetype({"one": {"required": True}}).bind({})

    def test_an_undeclared_parameter_is_an_error(self) -> None:
        """As an unknown flavour is. Silently dropping it would start an expert
        that quietly ignores half of what it was told."""
        with self.assertRaises(ArchetypeError):
            self.archetype({"one": {"default": "x"}}).bind({"two": 1})

    def test_defaults_fill_in_and_values_win(self) -> None:
        archetype = self.archetype({"one": {"default": "fallback"}})
        self.assertEqual(archetype.bind(None), {"one": "fallback"})
        self.assertEqual(archetype.bind({"one": "given"}), {"one": "given"})


class ThePrompt(unittest.TestCase):
    def test_parameters_are_substituted(self) -> None:
        archetype = archetypes.parse(
            '---\nname: tester\ndescription: Use when testing.\n'
            'parameters: {"scope": {"required": true}}\n---\n\nStay in {scope}.', "tester")
        self.assertIn("Stay in https://x.dev.", archetype.prompt({"scope": "https://x.dev"}))

    def test_braces_that_are_not_parameters_survive(self) -> None:
        """A body is prose written for a model and will contain JSON examples.
        `str.format` would raise on them; a literal replace per declared name
        does not."""
        archetype = archetypes.parse(
            '---\nname: tester\ndescription: Use when testing.\n---\n\n'
            'Return {"answer": 1} and {unknown}.', "tester")
        self.assertIn('{"answer": 1}', archetype.prompt())
        self.assertIn("{unknown}", archetype.prompt())

    def test_the_return_schema_is_appended_as_a_contract(self) -> None:
        archetype = archetypes.parse(
            '---\nname: tester\ndescription: Use when testing.\n'
            'returns: {"type": "object"}\n---\n\nbody', "tester")
        self.assertIn("prose_result", archetype.prompt())
        self.assertIn('"type": "object"', archetype.prompt())

    def test_a_preset_archetype_appends_rather_than_replaces(self) -> None:
        archetype = archetypes.parse(
            '---\nname: tester\ndescription: Use when testing.\n'
            'preset: claude_code\n---\n\nthe extra rules', "tester")
        prompt = archetype.system_prompt()
        self.assertEqual(prompt["preset"], "claude_code")
        self.assertIn("the extra rules", prompt["append"])


class EveryBundledArchetype(unittest.TestCase):
    def files(self) -> list[Path]:
        found = sorted(BUNDLED.glob("*.md"))
        self.assertTrue(found, "no archetypes at all")
        return found

    def loaded(self) -> list[Archetype]:
        return [archetypes.parse(path.read_text(encoding="utf-8"), path.stem)
                for path in self.files()]

    def test_they_all_parse(self) -> None:
        """`catalogue()` skips a broken file so one cannot stop every pane
        opening. That tolerance is exactly why the bundled ones need checking
        somewhere that does not forgive."""
        self.assertEqual(len(self.loaded()), len(self.files()))

    def test_they_all_lint_clean(self) -> None:
        """Every rule lives in `archetypes.lint`, so that the suite and
        `prose_archetype_check` cannot disagree about what deployable means —
        and so an author gets these findings before the file is written rather
        than from a failing test afterwards."""
        for path in self.files():
            self.assertEqual(
                archetypes.lint(path.read_text(encoding="utf-8"), path.stem), [],
                path.stem)


class Linting(unittest.TestCase):
    """What `lint` catches that nothing else does.

    Every one of these produces an archetype that *loads* — or silently does
    not — rather than raising anywhere, which is why they are worth a test each.
    """

    def problems(self, header: str = "", body: str = "x" * 700) -> str:
        text = (f"---\nname: tester\ndescription: Use when testing.\n{header}"
                f"---\n\n{body}")
        return " | ".join(archetypes.lint(text, "tester"))

    def test_a_file_that_would_not_parse_says_only_that(self) -> None:
        """Every other rule reads a field that failure means we do not have."""
        found = archetypes.lint("---\nname: tester\n", "tester")
        self.assertEqual(len(found), 1)

    def test_a_key_the_parser_does_not_know(self) -> None:
        """Dropped in silence, so a draft can declare `tools:` and read as
        working while the child gets the default allowance."""
        self.assertIn("'tools'", self.problems("tools: Read, Bash\n"))

    def test_a_description_that_does_not_route(self) -> None:
        text = ("---\nname: tester\ndescription: Reads files and reports.\n"
                "---\n\n" + "x" * 700)
        self.assertIn("use when", " | ".join(archetypes.lint(text, "tester")))

    def test_a_body_with_nothing_in_it(self) -> None:
        self.assertIn("body", self.problems(body="too short"))

    def test_a_tool_name_that_does_not_exist(self) -> None:
        """`qualify` passes an unrecognised name through untouched and the SDK
        ignores it, so `browser_txt` is an allowance that is simply not there."""
        self.assertIn("browser_txt", self.problems("allow: browser_txt\n"))

    def test_a_placeholder_nobody_declared(self) -> None:
        self.assertIn("{scope}", self.problems(body="Stay inside {scope}. " * 40))

    def test_a_parameter_wired_to_nothing(self) -> None:
        self.assertIn("'scope'", self.problems(
            'parameters: {"scope": {"description": "d", "required": true}}\n'))

    def test_a_parameter_that_is_neither_required_nor_defaulted(self) -> None:
        self.assertIn("neither", self.problems(
            'parameters: {"scope": {"description": "d"}}\n',
            body="Stay inside {scope}. " * 40))

    def test_a_return_schema_with_nowhere_to_put_a_failure(self) -> None:
        self.assertIn("failure", self.problems(
            'returns: {"type": "object", "properties": {"answer": {"type": "string"}}}\n'))


class Resolution(unittest.TestCase):
    def test_both_kinds_of_flavour_are_offered(self) -> None:
        offered = tools.flavours()
        self.assertIn("prose", offered)
        self.assertIn("browser-pilot", offered)

    def test_an_archetype_becomes_an_argv_carrying_its_values(self) -> None:
        argv = tools.argv("browser-pilot", {"scope": "https://x.dev"})
        self.assertTrue(argv[1].endswith("archetype_agent.py"))
        self.assertEqual(argv[2], "browser-pilot")
        self.assertEqual(json.loads(argv[3]), {"scope": "https://x.dev"})

    def test_the_default_flavour_uses_proses_own_command(self) -> None:
        self.assertEqual(tools.argv("prose", None), [])

    def test_what_is_refused_before_a_pane_exists(self) -> None:
        for flavour, params in [("nope", None), ("browser-pilot", None), ("code", {"a": 1})]:
            with self.assertRaises(Exception):
                tools.argv(flavour, params)

    def test_an_unknown_flavour_names_every_flavour(self) -> None:
        try:
            tools.argv("nope", None)
        except Exception as refused:
            self.assertIn("code", str(refused))
            self.assertIn("browser-pilot", str(refused))


class TheAllowance(unittest.TestCase):
    """`allow` and `deny` are not symmetrical, and getting that backwards
    produces an expert that looks constrained and is not."""

    def archetype(self, header: str) -> Archetype:
        return archetypes.parse(
            f"---\nname: tester\ndescription: Use when testing.\n{header}---\n\nbody", "tester")

    def test_an_allowance_replaces_the_default_rather_than_adding_to_it(self) -> None:
        """Otherwise a narrow expert still reads the filesystem unattended and
        cannot be narrower than any other pane."""
        allowed, _ = allowance(self.archetype("allow: browser_text\n"))
        self.assertEqual(allowed, ["mcp__prose__browser_text"])
        self.assertNotIn("Read", allowed)

    def test_declaring_nothing_keeps_the_ordinary_set(self) -> None:
        allowed, _ = allowance(self.archetype(""))
        self.assertEqual(allowed, list(UNATTENDED))

    def test_leaving_a_tool_out_makes_it_ask_rather_than_blocking_it(self) -> None:
        """`allowed_tools` auto-approves; it does not restrict. Only
        `disallowed_tools` makes a tool unreachable."""
        allowed, denied = allowance(self.archetype("allow: browser_text\n"))
        self.assertNotIn("Write", allowed)
        self.assertNotIn("Write", denied)

    def test_spawning_is_shut_unless_asked_for_in_writing(self) -> None:
        """A narrow expert that can spawn a wide one has everything it was
        denied, one pane away — and containment does not catch it, because the
        child is a perfectly legitimate descendant."""
        _, denied = allowance(self.archetype(""))
        self.assertIn("mcp__prose__prose_spawn", denied)
        _, permitted = allowance(self.archetype("spawns: true\n"))
        self.assertNotIn("mcp__prose__prose_spawn", permitted)

    def test_the_browser_is_shut_unless_the_file_asked_for_it(self) -> None:
        """`loop.serve` registers every prose tool the deny list does not shut,
        so leaving the browser out of an `allow:` line did not withhold it —
        `skill-designer`, which writes Markdown, held all sixteen."""
        _, denied = allowance(self.archetype(""))
        for tool in BROWSER:
            self.assertIn(f"mcp__prose__{tool}", denied)

    def test_an_archetype_that_asked_for_the_browser_keeps_it(self) -> None:
        """Which is the test of the rule: `browser-pilot` names them itself."""
        allowed, denied = allowance(archetypes.load("browser-pilot"))
        self.assertIn("mcp__prose__browser_text", allowed)
        self.assertNotIn("mcp__prose__browser_text", denied)

    def test_authoring_is_shut_the_same_way(self) -> None:
        _, denied = allowance(self.archetype(""))
        self.assertIn("mcp__prose__prose_archetype_check", denied)
        allowed, permitted = allowance(self.archetype("allow: prose_archetype_check\n"))
        self.assertIn("mcp__prose__prose_archetype_check", allowed)
        self.assertNotIn("mcp__prose__prose_archetype_check", permitted)

    def test_what_prose_shuts_is_shut_whatever_the_archetype_says(self) -> None:
        _, denied = allowance(self.archetype("allow: Task\n"))
        for door in INVISIBLE:
            self.assertIn(door, denied)

    def test_restating_a_door_prose_already_shuts_is_harmless(self) -> None:
        _, denied = allowance(self.archetype(f"deny: {INVISIBLE[0]}\n"))
        self.assertEqual(len(denied), len(set(denied)), "repeats only confuse a log")


class TheCatalogue(unittest.TestCase):
    def test_a_malformed_file_is_skipped_rather_than_fatal(self) -> None:
        """One bad file in a dropped-in directory must not stop every pane in
        the window from opening."""
        with tempfile.TemporaryDirectory() as directory:
            (Path(directory) / "broken.md").write_text("not an archetype")
            with support.environment(PROSE_ARCHETYPES=directory):
                archetypes.catalogue.cache_clear()
                found = archetypes.catalogue()
            archetypes.catalogue.cache_clear()
        self.assertNotIn("broken", found)
        self.assertIn("browser-pilot", found, "the good ones still loaded")


if __name__ == "__main__":
    unittest.main()
