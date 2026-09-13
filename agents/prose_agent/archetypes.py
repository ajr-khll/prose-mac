"""Subagent archetypes: an expert per pane, declared as a file.

An archetype is what `prose_spawn(flavour=...)` opens. It is one Markdown file
whose body is a system prompt and whose header is an allowance — the tools that
agent may use, the skills it carries, the model it runs on, the parameters it
takes and the shape it returns.

**Why this is not a skill.** A skill loads instructions into *this* agent's
context, in this pane, mid-turn. An archetype is a different agent in a
different pane, with its own context window, its own tool allowance and its own
transcript. So the test for which one to write is not how specialised the
instructions are, it is: does this need a context window you do not want to
spend, or a permission set you do not want to hold? Either one means an
archetype. Neither means a skill.

**Why the parent names one rather than writing one.** `tools.FLAVOURS` already
refuses to let a model choose an argv, because a model that can choose an argv
has a shell. A model that can write its child's system prompt and pick its
tools has the same thing by a longer route: it would author itself an agent
without the constraints it is under. So the parent supplies a *name* from this
catalogue and *values* for declared parameters, and never prose that lands in a
system prompt.

**Where the words sit**, which is the whole economic argument. The parent holds
one line per archetype — a name and a description — in `prose_spawn`'s schema.
The child holds the body: as much precise instruction as the job deserves, in
its own window, which the parent never reads. If the parent could author that
prompt, the instructions would have to be in the parent's context in order to
be written, and the saving would be gone.

The format is `skills/*/SKILL.md`'s, deliberately: `key: value` frontmatter,
parsed shallowly, no YAML library — `prose_agent` imports nothing outside the
standard library. The two keys that are genuinely nested, `parameters` and
`returns`, carry JSON on one line, which a shallow parser can hand to
`json.loads` and a person can still read.
"""

from __future__ import annotations

import json
import os
import re
import sys
from dataclasses import dataclass, field
from functools import lru_cache
from pathlib import Path
from typing import Any

from . import skills

#: Extra archetype directories, colon-separated. As `PROSE_PLUGINS`, and for
#: the same reason: trying one should not mean editing anything.
ENVIRONMENT = "PROSE_ARCHETYPES"

#: Frontmatter keys that are read as JSON rather than as a bare string, because
#: they are the two that are genuinely structured.
STRUCTURED = ("parameters", "returns")

#: Frontmatter keys read as a comma-separated list of names.
LISTS = ("allow", "deny", "skills", "integrations")

#: Every key the header understands. The parser ignores the rest in silence, so
#: this is what `lint` measures a draft against — inventing `tools:` or
#: `permissions:` is a mistake that otherwise reads as working.
KEYS = ("name", "description", "preset", "model", "effort", "spawns",
        *LISTS, *STRUCTURED)


#: A `{name}` in a body, and not the `{"key": …}` of a JSON example.
PLACEHOLDER = re.compile(r"\{([a-z_][a-z0-9_]*)\}")


class ArchetypeError(Exception):
    """A malformed archetype, or a spawn that does not match one.

    Raised where it can still be fixed — when the catalogue is read, or in the
    parent that is about to spawn — rather than surfacing as a child that
    quietly came up with the wrong instructions.
    """


@dataclass(frozen=True)
class Archetype:
    """One expert, as loaded from one file."""

    name: str
    description: str
    body: str
    #: `claude_code` to build on the SDK's coding preset, with the body
    #: appended; empty to make the body the whole system prompt.
    preset: str = ""
    model: str = ""
    effort: str = ""
    #: Tools this archetype may call without raising a card. Empty means
    #: `permissions.UNATTENDED`, the same reading-is-free set every pane gets.
    allow: tuple[str, ...] = ()
    #: Tools it must not reach at all, on top of `permissions.INVISIBLE`.
    deny: tuple[str, ...] = ()
    #: `("all",)` for every discovered skill, or names. Empty carries no skill
    #: listing at all, which is the right default for a narrow expert: the
    #: catalogue costs a description per skill on every turn.
    skills: tuple[str, ...] = ()
    #: Third-party providers this archetype brokers — `apps.PROVIDERS`. Empty
    #: means the `apps_*` server is not registered in its pane at all, which is
    #: every archetype but the two integration ones. It is declared in the file
    #: and never in `params`, because a parent that could choose its child's
    #: providers would hold the union of all of them.
    integrations: tuple[str, ...] = ()
    #: Whether this archetype may spawn panes of its own. Off by default —
    #: otherwise a narrow expert spawns a wide one and has everything it was
    #: denied, which descendant containment does not catch because the child
    #: is a perfectly legitimate descendant.
    spawns: bool = False
    parameters: dict[str, Any] = field(default_factory=dict)
    returns: dict[str, Any] = field(default_factory=dict)

    def bind(self, values: dict[str, Any] | None) -> dict[str, str]:
        """The parameter values this archetype will actually be started with.

        Missing required ones and names it does not declare are both errors, in
        the parent, before a pane exists — `tools.FLAVOURS` makes an unknown
        flavour an error rather than a fallback, and an unknown parameter is
        the same mistake one level down.
        """
        given = dict(values or {})
        unknown = sorted(set(given) - set(self.parameters))
        if unknown:
            raise ArchetypeError(
                f"{self.name} takes no parameter {unknown[0]!r}"
                f" — it takes {', '.join(sorted(self.parameters)) or 'none'}")

        bound: dict[str, str] = {}
        for key, spec in self.parameters.items():
            if key in given:
                bound[key] = str(given[key])
            elif "default" in spec:
                bound[key] = str(spec["default"])
            elif spec.get("required"):
                raise ArchetypeError(
                    f"{self.name} needs {key!r}: {spec.get('description', '')}".strip())
        return bound

    def prompt(self, values: dict[str, Any] | None = None) -> str:
        """The body with its parameters filled in, and its contract appended.

        Substitution is a literal replace per declared name rather than
        `str.format`, because the body is prose written for a model and will
        contain braces of its own — a JSON example in a browser prompt should
        not be a formatting error.
        """
        text = self.body.strip()
        for key, value in self.bind(values).items():
            text = text.replace("{" + key + "}", value)

        if self.returns:
            # Stated as the shape it owes rather than as an instruction it
            # might paraphrase. `prose_result` is how it reaches the parent;
            # `pane_agent`'s prompt says that, and a spawned expert reads this
            # one instead, so it has to be said here too.
            text += (
                "\n\nWhen you are done, call `prose_result` with a value "
                "matching exactly this JSON schema, and nothing else:\n\n"
                + json.dumps(self.returns, indent=2)
                + "\n\nIf you cannot finish the job, say so in that same shape "
                  "rather than in prose — the parent is parsing it, not reading it."
            )
        return text

    def system_prompt(self, values: dict[str, Any] | None = None) -> Any:
        """What `ClaudeAgentOptions.system_prompt` is given.

        A preset plus an append where the archetype asked for one — a coding
        expert wants the SDK's file and shell conventions and they are not
        worth re-deriving — and otherwise the body alone, because for most
        experts the preset is thousands of tokens of an identity we would then
        spend our own tokens contradicting.
        """
        if self.preset:
            return {"type": "preset", "preset": self.preset, "append": "\n\n" + self.prompt(values)}
        return self.prompt(values)


def parse(text: str, name: str) -> Archetype:
    """One archetype file. `name` is the filename stem, which the header must
    agree with — a header that has drifted from its filename means one of the
    two is a typo, and the spawn that fails is far away from here."""
    if not text.startswith("---\n"):
        raise ArchetypeError(f"{name}: no frontmatter")
    header, marker, body = text[4:].partition("\n---\n")
    if not marker:
        raise ArchetypeError(f"{name}: frontmatter is not closed")

    fields: dict[str, Any] = {}
    for line in header.splitlines():
        # Continuation lines are indented, as in a SKILL.md header. There are
        # none today; ignoring them beats parsing half of YAML.
        if ":" not in line or line.startswith((" ", "\t", "#")):
            continue
        key, _, raw = line.partition(":")
        key, raw = key.strip(), raw.strip()
        if key in STRUCTURED:
            try:
                fields[key] = json.loads(raw)
            except json.JSONDecodeError as bad:
                raise ArchetypeError(f"{name}: {key} is not valid JSON — {bad}") from bad
        elif key in LISTS:
            fields[key] = tuple(part.strip() for part in raw.split(",") if part.strip())
        else:
            fields[key] = raw

    declared = fields.get("name", "")
    if declared != name:
        raise ArchetypeError(f"{name}: header says name {declared!r}")
    if not fields.get("description"):
        raise ArchetypeError(f"{name}: no description — it is the only part the "
                             f"parent reads before choosing")
    if not body.strip():
        raise ArchetypeError(f"{name}: no body, so it has no instructions to give")

    return Archetype(
        name=name,
        description=fields["description"],
        body=body,
        preset=fields.get("preset", ""),
        model=fields.get("model", ""),
        effort=fields.get("effort", ""),
        allow=fields.get("allow", ()),
        deny=fields.get("deny", ()),
        skills=fields.get("skills", ()),
        integrations=fields.get("integrations", ()),
        spawns=str(fields.get("spawns", "")).lower() in ("true", "yes", "1"),
        parameters=fields.get("parameters", {}),
        returns=fields.get("returns", {}),
    )


def lint(text: str, name: str) -> list[str]:
    """Everything wrong with one archetype file, in the order it is worth
    fixing. Empty means it is deployable.

    This is the one definition of valid: `tests/test_archetypes.py` measures the
    bundled files with it, and `prose_archetype_check` hands it to the agent
    that is writing one. Two copies of these rules would drift, and the drift
    would show up as a specialist that passes review and never loads.

    The failures it is really for are the silent ones. `catalogue` **skips** a
    file it cannot parse — one line on stderr and the archetype is simply
    absent, with nothing raised anywhere — and the header drops keys it does not
    know without comment. Neither is discoverable by reading the file back.
    """
    from .tools import tool_names

    try:
        archetype = parse(text, name)
    except ArchetypeError as bad:
        # Nothing further is worth saying: every other rule reads a field that
        # this failure means we do not have.
        return [str(bad)]

    problems: list[str] = []

    header = text[4:].partition("\n---\n")[0]
    for line in header.splitlines():
        if ":" not in line or line.startswith((" ", "\t", "#")):
            continue
        key = line.partition(":")[0].strip()
        if key not in KEYS:
            problems.append(
                f"{key!r} is not a header key — it is dropped in silence, so "
                f"whatever you meant by it is not happening. One of {', '.join(KEYS)}")

    if "use when" not in archetype.description.lower():
        problems.append("description: say when to reach for this, in the words a "
                        "request would use — it is a routing rule, not a summary, "
                        "and it must contain 'use when'")
    if len(archetype.description) >= 1024:
        problems.append(f"description: {len(archetype.description)} characters, and it "
                        f"sits in every parent's context — keep it under 1024")
    if len(archetype.body.strip()) <= 600:
        problems.append("body: too short to be worth a pane. The argument for an "
                        "archetype is that it holds detail the parent does not; one "
                        "that says little is a skill written in the wrong place")

    real = {name.rsplit("__", 1)[-1] for name in tool_names()}
    # `apps_*` exist only in a pane whose archetype declared a provider set, so
    # they are measured against that declaration rather than the global
    # catalogue — naming one without `integrations:` is an allowance for a
    # server that will not be registered.
    from . import apps

    if archetype.integrations:
        try:
            apps.providers(archetype.integrations)
        except Exception as bad:  # noqa: BLE001 - reported, not raised
            problems.append(str(bad))
        else:
            real |= {name.rsplit("__", 1)[-1]
                     for name in apps.tool_names(archetype.integrations)}

    for named in archetype.allow + archetype.deny:
        if named.startswith(("prose_", "browser_", "apps_")) and named not in real:
            hint = ""
            if named.startswith("apps_") and not archetype.integrations:
                hint = (" — and this file declares no `integrations:`, so the "
                        "apps server is never registered in its pane")
            problems.append(f"no such tool {named!r} — an unrecognised name is ignored "
                            f"rather than refused, so this line does nothing{hint}")

    if archetype.integrations and archetype.spawns:
        # A pane holding a workspace credential that can also open panes hands
        # that credential's reach to something with no declaration at all.
        problems.append("integrations with spawns: true — a pane holding a "
                        "provider credential must not open panes, because the "
                        "child is not measured against this file's allowance")

    used = set(PLACEHOLDER.findall(archetype.body))
    for placeholder in sorted(used - set(archetype.parameters)):
        problems.append(f"{{{placeholder}}} is never bound — declare it in "
                        f"`parameters` or it reaches the model as literal braces")
    for declared, spec in archetype.parameters.items():
        if declared not in used:
            problems.append(f"parameter {declared!r} is declared and never used — a "
                            f"knob wired to nothing")
        if not spec.get("description"):
            problems.append(f"parameter {declared!r}: no description, and the parent "
                            f"chooses its value from that alone")
        if not (spec.get("required") or "default" in spec):
            problems.append(f"parameter {declared!r}: neither required nor defaulted, "
                            f"so it is silently absent when nobody passes it")

    if archetype.returns:
        if archetype.returns.get("type") != "object":
            problems.append("returns: use a JSON object schema, so the parent can read "
                            "fields rather than parse prose")
        if "failed" not in archetype.returns.get("properties", {}):
            problems.append("returns: no shape for failure. Without somewhere to put it "
                            "a child that cannot do the job improvises prose, and the "
                            "parent's parse breaks on the one case that matters")

    return problems


def roots() -> list[Path]:
    """Where archetypes are read from: the bundled directory, then anything in
    `$PROSE_ARCHETYPES`. Found by `skills.resource`, which walks the ladder a
    bundle and a source checkout need."""
    found: list[Path] = []
    if (bundled := skills.resource("archetypes")) is not None:
        found.append(bundled)
    for extra in os.environ.get(ENVIRONMENT, "").split(":"):
        if extra.strip():
            where = Path(extra).expanduser().resolve()
            if where.is_dir() and where not in found:
                found.append(where)
    return found


@lru_cache(maxsize=1)
def catalogue() -> dict[str, Archetype]:
    """Every archetype, by name. Later roots win, so `$PROSE_ARCHETYPES` can
    override a bundled one — which is how you try a change to `browser-pilot`
    without editing the checkout.

    Cached because this is read on every `prose_spawn` and once per process is
    enough; `catalogue.cache_clear()` is what a reload calls.
    """
    found: dict[str, Archetype] = {}
    for root in roots():
        for path in sorted(root.glob("*.md")):
            try:
                found[path.stem] = parse(path.read_text(encoding="utf-8"), path.stem)
            except (ArchetypeError, OSError) as bad:
                # Skipped, not raised. One malformed file in a dropped-in
                # directory must not stop every pane in the window from
                # opening — but it says so on stderr, which `PROSE_LOG_DIR`
                # and `PROSE_FRAME=1` both capture, and the archetype is then
                # simply absent from the list an unknown name is measured
                # against. The bundled ones are parsed strictly by the tests,
                # so a broken one there fails before it ships.
                print(f"archetype skipped: {bad}", file=sys.stderr)
    return found


def load(name: str) -> Archetype:
    """One archetype by name, or an error naming the ones that exist."""
    available = catalogue()
    if name not in available:
        raise ArchetypeError(
            f"no such archetype {name!r} — one of {', '.join(sorted(available)) or 'none'}")
    return available[name]
