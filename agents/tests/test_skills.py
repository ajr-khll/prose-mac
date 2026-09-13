"""The bundled plugin, kept honest without running a model.

The failures these catch all present the same way — a skill that silently never
fires — which is the most expensive kind to chase.
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

import support  # noqa: F401 - puts `agents/` on the path
from prose_agent import skills

BUNDLED = Path(__file__).resolve().parent.parent / "skills"


def frontmatter(path: Path) -> tuple[dict[str, str], str]:
    """The YAML header and the body, parsed shallowly.

    Deliberately not a YAML library: `prose_agent` is standard library only,
    and a skill header is `key: value` lines. If one ever needs more than that,
    it has stopped being a header.
    """
    text = path.read_text(encoding="utf-8")
    assert text.startswith("---\n"), f"{path} has no frontmatter"
    header, _, body = text[4:].partition("\n---\n")
    fields = {}
    for line in header.splitlines():
        if ":" in line and not line.startswith((" ", "\t")):
            key, _, value = line.partition(":")
            fields[key.strip()] = value.strip()
    return fields, body


class ThePlugin(unittest.TestCase):
    def test_the_manifest_is_valid_and_named(self) -> None:
        manifest = json.loads((BUNDLED / ".claude-plugin" / "plugin.json").read_text())
        self.assertEqual(manifest["name"], "prose",
                         "the namespace every bundled skill is invoked under")

    def test_plugins_returns_absolute_paths_that_exist(self) -> None:
        """The SDK does not expand `~`, and it skips a path that does not exist
        **without saying so** — so a wrong path here is invisible until nothing
        works."""
        roots = skills.plugins()
        self.assertTrue(roots, "the bundled plugin was not found at all")
        for root in roots:
            self.assertEqual(root["type"], "local")
            self.assertTrue(Path(root["path"]).is_absolute())
            self.assertNotIn("~", root["path"])
            self.assertTrue(Path(root["path"]).is_dir())

    def test_the_bundled_root_is_the_one_beside_us(self) -> None:
        self.assertEqual(skills.plugins()[0]["path"], str(BUNDLED))


class EverySkill(unittest.TestCase):
    def skills(self):
        found = sorted((BUNDLED / "skills").glob("*/SKILL.md"))
        self.assertTrue(found, "no skills at all")
        return found

    def test_the_name_matches_its_directory(self) -> None:
        for path in self.skills():
            fields, _ = frontmatter(path)
            self.assertEqual(fields.get("name"), path.parent.name, path)

    def test_the_description_says_when_to_reach_for_it(self) -> None:
        """It is the only part the model reads before deciding, and it is read
        against a request rather than against the file."""
        for path in self.skills():
            fields, _ = frontmatter(path)
            description = fields.get("description", "")
            self.assertTrue(description, f"{path} has no description")
            self.assertLess(len(description), 1024, path)
            self.assertIn("use when", description.lower(), f"{path}: say when")

    def test_there_is_a_body(self) -> None:
        for path in self.skills():
            _, body = frontmatter(path)
            self.assertGreater(len(body.strip()), 200, f"{path} is barely there")


if __name__ == "__main__":
    unittest.main()
