"""Archetypes, kept honest without running a model.

The failures worth catching here are the quiet ones: a tool name that is a
typo and is therefore ignored rather than refused, a parameter the body never
uses, a header that drifted from its filename. None of them raise anything at
runtime — they just produce an expert that is subtly not the one that was
written down.
"""

from __future__ import annotations

import json
import re
import tempfile
import unittest
from pathlib import Path

import support  # noqa: F401 - puts `agents/` on the path
from prose_agent import archetypes, tools
from prose_agent.permissions import INVISIBLE, UNATTENDED, allowance
from prose_agent.archetypes import Archetype, ArchetypeError

BUNDLED = Path(__file__).resolve().parent.parent / "archetypes"

#: A `{name}` in a body, but not the `{"key": …}` of a JSON example.
PLACEHOLDER = re.compile(r"\{([a-z_][a-z0-9_]*)\}")

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

    def test_the_description_says_when_to_reach_for_it(self) -> None:
        for archetype in self.loaded():
            self.assertIn("use when", archetype.description.lower(),
                          f"{archetype.name}: say when, not what")
            self.assertLess(len(archetype.description), 1024, archetype.name)

    def test_there_are_real_instructions(self) -> None:
        """The whole argument for an archetype is that it holds the detail the
        parent does not. One that says little is a skill written in the wrong
        place."""
        for archetype in self.loaded():
            self.assertGreater(len(archetype.body.strip()), 600, archetype.name)

    def test_every_prose_tool_named_exists(self) -> None:
        """`qualify` passes an unrecognised name through untouched and the SDK
        then ignores it, so `browser_txt` in an `allow` list is an allowance
        that silently is not there."""
        real = {name.rsplit("__", 1)[-1] for name in tools.tool_names()}
        for archetype in self.loaded():
            for name in archetype.allow + archetype.deny:
                if name.startswith(("prose_", "browser_")):
                    self.assertIn(name, real, f"{archetype.name}: no such tool {name}")

    def test_every_placeholder_is_declared(self) -> None:
        for archetype in self.loaded():
            for used in set(PLACEHOLDER.findall(archetype.body)):
                self.assertIn(used, archetype.parameters,
                              f"{archetype.name}: {{{used}}} is never bound")

    def test_every_parameter_is_used(self) -> None:
        """A declared parameter the body never mentions reaches the model only
        as a name in a schema, which is a knob wired to nothing."""
        for archetype in self.loaded():
            used = set(PLACEHOLDER.findall(archetype.body))
            for declared in archetype.parameters:
                self.assertIn(declared, used,
                              f"{archetype.name}: {declared} is declared but unused")

    def test_every_parameter_is_required_or_defaulted(self) -> None:
        for archetype in self.loaded():
            for name, spec in archetype.parameters.items():
                self.assertTrue(spec.get("required") or "default" in spec,
                                f"{archetype.name}: {name} is neither")
                self.assertTrue(spec.get("description"), f"{archetype.name}: {name}")

    def test_a_return_schema_can_say_it_failed(self) -> None:
        """Without somewhere to put it, a child that cannot do the job
        improvises prose and the parent's parse breaks."""
        for archetype in self.loaded():
            if not archetype.returns:
                continue
            self.assertEqual(archetype.returns.get("type"), "object", archetype.name)
            self.assertIn("failed", archetype.returns.get("properties", {}),
                          f"{archetype.name}: no shape for failure")


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
