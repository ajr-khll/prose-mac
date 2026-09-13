"""Band B: the decisions, as tools the model can call.

Every one of these is one line out and one line back on the socket the process
is already holding. There is no subprocess, no second handshake and no HTTP —
which is the whole argument for an in-process MCP server over a CLI: a CLI
would spawn and re-authenticate per call, for a connection already open.

The schemas and handlers live here as plain data and plain functions, so they
can be read and tested without the Agent SDK installed. `mcp_server()` is the
only thing that imports it.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Callable

from . import archetypes
from .asking import Asker
from .wire import ProseError, Wire

#: prose's own tools are the agent's job, so they must not be deferred.
#:
#: The CLI turns on **tool search** once the tool schemas pass a character
#: threshold, and the fifteen below come to about five thousand characters — so
#: by default none of them are in the model's context at all. They exist only
#: as something it might think to go looking for, which makes `prose_ask`
#: indistinguishable from any third-party MCP tool and costs a whole round trip
#: to rediscover each one. Measured: with this set, the `ToolSearch` call that
#: preceded every first use of a prose tool disappears.
#:
#: This is an undocumented CLI variable, found by reading the bundled binary,
#: so treat it as a bet rather than an interface. It is a safe one: if the name
#: ever stops being read the behaviour falls back to what it does today, which
#: works — it just costs the extra call again. `ENABLE_TOOL_SEARCH=force` in
#: the environment puts deferral back, which is worth doing if you attach
#: enough other MCP servers for the context cost to bite.
NEVER_DEFERRED = {"ENABLE_TOOL_SEARCH": os.environ.get("ENABLE_TOOL_SEARCH", "0")}


#: What `prose_spawn(flavour=...)` may open, and nothing else.
#:
#: `pane.create` takes a whole `command[]` on the wire, and exposing that to
#: the model would hand it a shell — which descendant containment does not
#: cover, because containment is about *which panes* you may touch, not what
#: runs in them. So the model names a flavour and this table turns it into an
#: argv. An unknown name is an error rather than a fallback.
#:
#: `None` means prose's own default: another copy of whatever agent the pane
#: was opened with.
#: Every flavour is one of these two or an archetype — see `archetypes.py`.
#: These are the ones that are a whole Python file rather than a Markdown one.
AGENTS = Path(__file__).resolve().parent.parent

FLAVOURS: dict[str, list[str] | None] = {
    "prose": None,
    "code": [sys.executable, str(AGENTS / "code_agent.py")],
}


#: The browser half of the catalogue, named so it can be withheld.
#:
#: A pane agent that can spawn does not drive browsers itself — it hands the
#: errand to the `browser-pilot` archetype, whose pane pays for the pages. That
#: is a rule about *capability*, so it is enforced by not registering these at
#: all rather than by a paragraph of prompt asking the model not to (see
#: `permissions.NO_BROWSER`). Withholding is what `definitions(omit=…)` does;
#: `browser-pilot` itself gets the full set.
BROWSER = (
    "browser_open", "browser_navigate", "browser_elements", "browser_find",
    "browser_click", "browser_type", "browser_select", "browser_key",
    "browser_scroll", "browser_back", "browser_forward", "browser_text",
    "browser_eval", "browser_snapshot", "browser_console", "browser_network",
)

#: Durable automation is available to the general personal and coding agents,
#: but not to narrow archetypes. `permissions.allowance` adds these names to an
#: archetype's deny list, which also makes `loop.serve` omit their schemas.
AUTOMATION = (
    "prose_schedule", "prose_schedules", "prose_change_schedule",
    "prose_emit_event",
)

#: Checking an archetype, which only the archetype that writes them needs.
#:
#: Withheld the way `BROWSER` is, and for the same reason rather than a
#: security one: a tool nobody in this pane will call still costs its schema on
#: every turn, and it invites a general agent to start authoring specialists
#: instead of spawning one. `permissions.allowance` shuts it for any archetype
#: that has not asked for it in writing.
AUTHORING = ("prose_archetype_check",)


def flavours() -> list[str]:
    """What `prose_spawn` will accept, built-ins and archetypes together.

    Read on every call rather than captured once, so that dropping a file into
    `$PROSE_ARCHETYPES` and reopening a pane is the whole of adding an expert.
    """
    return sorted(set(FLAVOURS) | set(archetypes.catalogue()))


#: What the two built-in flavours are, in the same one-line shape an archetype
#: describes itself in, so `catalogue_lines` can render one list rather than a
#: list and an exception.
BUILT_IN_DESCRIPTIONS = {
    "prose": "Another personal agent like you, with the same broad remit. Use "
             "when the job is a whole errand rather than one speciality.",
    "code": "A coding agent with the file and shell conventions for a "
            "repository. Use when the job is reading or changing code — pass "
            "`cwd`.",
}


def catalogue_lines() -> str:
    """One line per flavour — a name and its description — for `prose_spawn`'s
    own tool description.

    This is the half of the archetype economy that has to sit in the parent's
    context. The body of an archetype never does: it loads into the child's
    pane and the parent never reads it. But the *description* is a routing
    rule, and a routing rule the parent cannot see does not route. Left as a
    bare `enum` of names, a specialist is a token the model has no reason to
    reach for, because finding out what it does costs a `prose_archetypes`
    round-trip it only makes when it already suspects the answer — which is
    why `browser-pilot` gets used (two paragraphs of prompt name it) and
    `skill-designer`, named nowhere, never did.

    The cost is roughly fifty tokens per archetype per turn. That is the price
    of the catalogue being usable at all, and it is what `archetypes.py`'s
    header has always claimed is paid.
    """
    described = dict(BUILT_IN_DESCRIPTIONS)
    for name, archetype in archetypes.catalogue().items():
        described[name] = archetype.description
    return "\n".join(f"- {name}: {described[name]}"
                      for name in flavours() if name in described)


def argv(flavour: str, params: dict | None) -> list[str]:
    """The command a flavour opens, with its parameters bound.

    Binding happens **here**, in the parent, before `pane.create` is called:
    a missing or misspelled parameter should be a tool error the model can fix
    in its next sentence, not a pane that opens and immediately exits with a
    message only stderr sees.

    Parameter values travel in argv, which is safe because `AgentProcess` execs
    `/usr/bin/env` with an argument array and no shell — there is nothing for a
    quote in a value to break out of.
    """
    if flavour in FLAVOURS:
        if params:
            raise ProseError(f"the {flavour!r} flavour takes no parameters")
        return FLAVOURS[flavour] or []
    if flavour not in archetypes.catalogue():
        raise ProseError(
            f"no such flavour {flavour!r} — one of {', '.join(flavours())}")
    try:
        archetypes.load(flavour).bind(params)
    except archetypes.ArchetypeError as bad:
        raise ProseError(str(bad)) from bad
    return [sys.executable, str(AGENTS / "archetype_agent.py"), flavour,
            json.dumps(params or {}, sort_keys=True)]


def _text(value: Any) -> dict:
    """An MCP tool result. Everything comes back as text, including JSON —
    the model reads it either way, and a shape is easier to keep stable."""
    body = value if isinstance(value, str) else json.dumps(value, sort_keys=True)
    return {"content": [{"type": "text", "text": body}]}


def _log_eval(wire: Wire, pane: Any, script: str) -> None:
    """Every `browser_eval`, on stderr and in the log directory if one is set.

    The ref tools exist to make this call rare. This line is how anyone finds
    out whether they did: an eval that survives them is a gap in them, and the
    script the model wrote says *which* gap — so it is recorded verbatim
    rather than counted. Reading a week of these is how the next set of tools
    gets chosen.

    Unconditional on stderr rather than behind `PROSE_FRAME`, because a
    fallback nobody sees is a fallback nobody fixes. It is one line per call
    and the calls are supposed to be rare; if they are not, that is the
    finding.
    """
    print(f"[prose] browser_eval pane={pane}: {script}", file=sys.stderr)

    directory = os.environ.get("PROSE_LOG_DIR")
    if not directory:
        return
    entry = {
        "at": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "session": wire.session,
        "pane": pane,
        "script": script,
    }
    try:
        path = Path(directory)
        path.mkdir(parents=True, exist_ok=True)
        with (path / "browser-eval.jsonl").open("a") as log:
            log.write(json.dumps(entry, sort_keys=True) + "\n")
    except OSError as bad:
        # A log that breaks the pane is worse than no log.
        print(f"[prose] could not write the eval log: {bad}", file=sys.stderr)


def definitions(wire: Wire, asker: Asker | None = None,
                omit: tuple[str, ...] | list[str] = ()
                ) -> list[tuple[str, str, dict, Callable]]:
    """Every tool, as `(name, description, schema, handler)`.

    `omit` drops tools by their plain name before anything is built. A denied
    tool that is still *registered* costs its schema in context on every turn
    and gives the model something to try and be refused for; dropping it is
    cheaper and clearer, and the refusal it would have produced is a paragraph
    of prompt instead.

    The descriptions are what the model reasons over, so each one says what the
    call *costs* as well as what it does. That is not decoration: the difference
    between a parent that waits and a parent that polls is whether it believed
    the description.

    `asker` is shared with the permission callback so that a model question and
    a permission prompt cannot both be outstanding — see `asking.Asker`. One is
    made here when nobody supplies one, which is what keeps `tool_names()`
    working against `_Unbound`.
    """
    asking = asker or Asker(wire)

    async def ask(args: dict) -> dict:
        # Through the shared `Asker` rather than straight at the wire, so a
        # permission prompt raised by a parallel tool call cannot land on top
        # of this one. A question is answered by a person, so there is no
        # useful timeout — `asking.PATIENCE` is a day.
        if os.environ.get("PROSE_AUTOMATION_RUN"):
            raise ProseError(
                "an unattended automation cannot wait for a user answer; "
                "return a useful failure instead")
        return _text(await asking.ask(
            prompt=args["prompt"],
            choices=args.get("choices") or None,
            placeholder=args.get("placeholder")))

    async def spawn(args: dict) -> dict:
        command = argv(args.get("flavour") or "prose", args.get("params"))
        inherited = {
            key: value for key in (
                "PROSE_AUTOMATION_RUN", "PROSE_AUTOMATION_DEFINITION",
                "PROSE_AUTOMATION_MAX_RUNTIME")
            if (value := os.environ.get(key))
        }
        created = await wire.call(
            "pane.create",
            {
                "from": wire.pane,
                "axis": args.get("axis", "row"),
                "kind": "agent",
                "command": command,
                "cwd": args.get("cwd"),
                "title": args.get("title"),
                "env": inherited,
            },
        )
        pane = created.get("pane")
        if pane is None:
            raise ProseError("prose did not hand back a pane")
        wire.notify("pane.send", {"pane": pane, "text": args["task"]})
        return _text(created)

    async def experts(_args: dict) -> dict:
        # Pulled rather than pushed. Parameters and return schemas are far too
        # much to carry in `prose_spawn`'s own schema on every turn of every
        # pane, and they are only needed in the sentence before a spawn.
        return _text([
            {
                "flavour": archetype.name,
                "description": archetype.description,
                "parameters": archetype.parameters,
                "returns": archetype.returns,
            }
            for _, archetype in sorted(archetypes.catalogue().items())
        ])

    async def check_archetype(args: dict) -> dict:
        # Local, and needing no wire: an archetype is a file, and the whole
        # point of checking one is doing it *before* the file exists. So this
        # takes the text rather than a path, and the write card is raised on
        # something that has already come back clean.
        from .permissions import allowance

        text, name = args["text"], args["name"]
        problems = archetypes.lint(text, name)
        found = {
            "ok": not problems,
            "problems": problems,
            "existing": [{"name": other.name, "description": other.description}
                         for _, other in sorted(archetypes.catalogue().items())],
            "roots": [str(root) for root in archetypes.roots()],
        }
        if not problems:
            # The surface the child will **really** have, which is not what its
            # `allow:` line says: `allowed_tools` only auto-approves, and
            # `loop.serve` registers every prose tool this does not deny. An
            # author reading their own header cannot see either of those, and
            # guide §7 asks for exactly this — the effective options, after the
            # MCP server and its names have been added.
            allowed, denied = allowance(archetypes.parse(text, name))
            plain = [name.rsplit("__", 1)[-1] for name in denied]
            found["effective"] = {
                "unattended": allowed,
                "denied": denied,
                "registered": [reachable.rsplit("__", 1)[-1]
                               for reachable in tool_names(omit=plain)],
            }
        return _text(found)

    async def focus(args: dict) -> dict:
        # A notification, like `prose_close`: `SessionRegistry`'s `.focusPane`
        # arm does not acknowledge the request the way `pane.send` and
        # `pane.answer` do, so a `call` here would wait out the whole timeout
        # for a reply that is never coming.
        wire.notify("pane.focus", {"pane": args["pane"]})
        return _text({"ok": True})

    async def read(args: dict) -> dict:
        return _text(await wire.call("pane.read", {
            "pane": args["pane"],
            "since": args.get("since", 0),
            "block": args.get("block"),
            "fidelity": args.get("fidelity", "summary"),
            "kinds": args.get("kinds") or [],
            "match": args.get("match"),
            "limit": args.get("limit"),
        }))

    async def wait(args: dict) -> dict:
        timeout = int(args.get("timeout_ms", 120_000))
        return _text(await wire.call(
            "pane.read",
            {
                "pane": args["pane"],
                "since": args.get("since", 0),
                "until": args.get("until") or ["turn", "ask", "exit"],
                "timeout": timeout,
                "fidelity": args.get("fidelity", "summary"),
            },
            # Outlive the park, or the client gives up on an answer that is
            # still coming and the pane is left waiting on nobody.
            timeout=timeout / 1000 + 30,
        ))

    async def send(args: dict) -> dict:
        return _text(await wire.call("pane.send", {"pane": args["pane"], "text": args["text"]}))

    async def answer(args: dict) -> dict:
        return _text(await wire.call("pane.answer", {
            "pane": args["pane"],
            "text": args.get("text", ""),
            "escalate": bool(args.get("escalate", False)),
        }))

    async def interrupt(args: dict) -> dict:
        return _text(await wire.call("pane.interrupt", {"pane": args["pane"]}))

    async def close(args: dict) -> dict:
        wire.notify("pane.close", {"pane": args["pane"]})
        return _text({"ok": True})

    async def result(args: dict) -> dict:
        wire.notify("result", {"session": wire.session, "value": args.get("value")})
        return _text({"ok": True})

    def require_interactive() -> None:
        if os.environ.get("PROSE_AUTOMATION_RUN"):
            raise ProseError(
                "an unattended automation cannot create or change durable schedules")

    async def schedule(args: dict) -> dict:
        require_interactive()
        proposal = {
            "title": args["title"],
            "task": {
                "prompt": args["task"],
                "flavour": args.get("flavour", "prose"),
                "params": args.get("params") or {},
                "cwd": args.get("cwd"),
            },
            "trigger": args["trigger"],
            "policy": args.get("policy") or {},
        }
        trigger = json.dumps(args["trigger"], sort_keys=True)
        approved = await asking.ask(
            prompt=f"Create automation {args['title']!r} with trigger {trigger}?",
            choices=["Create automation", "Cancel"])
        if approved != "Create automation":
            raise ProseError("the user cancelled the automation")
        return _text(await wire.call("automation.create", {"definition": proposal}))

    async def schedules(args: dict) -> dict:
        require_interactive()
        return _text(await wire.call(
            "automation.list", {"include_runs": bool(args.get("include_runs", True))}))

    async def change_schedule(args: dict) -> dict:
        require_interactive()
        action = args["action"]
        label = action.replace("_", " ")
        approved = await asking.ask(
            prompt=f"{label.capitalize()} automation {args['id']}?",
            choices=[label.capitalize(), "Cancel"])
        if approved != label.capitalize():
            raise ProseError("the user cancelled the change")
        return _text(await wire.call("automation.change", {
            "id": args["id"], "action": action}))

    async def emit_event(args: dict) -> dict:
        require_interactive()
        event = {
            "external_id": args["external_id"],
            "source": args["source"],
            "type": args["type"],
            "subject": args.get("subject"),
            "payload": args.get("payload"),
        }
        approved = await asking.ask(
            prompt=(f"Emit {args['source']}.{args['type']} event "
                    f"{args['external_id']!r}?"),
            choices=["Emit event", "Cancel"])
        if approved != "Emit event":
            raise ProseError("the user cancelled the event")
        return _text(await wire.call("automation.emit", {"event": event}))

    async def browser_open(args: dict) -> dict:
        """A page opens **above** the pilot reading it.

        The default is a column split placed `before`, so the pane the person
        is meant to look at takes the top of the column and the agent
        narrating it sits underneath, the full width of the page rather than
        squeezed into a second column. The model does not choose this and is
        not asked to: it is a layout decision, and one it has no way to see
        the result of.
        """
        return _text(await wire.call("pane.create", {
            "from": wire.pane,
            "axis": args.get("axis", "column"),
            "placement": args.get("placement", "before"),
            "kind": "browser",
            "url": args["url"],
        }))

    async def browser_navigate(args: dict) -> dict:
        return _text(await wire.call("browser.navigate", {
            "pane": args["pane"], "url": args["url"]}))

    async def browser_text(args: dict) -> dict:
        return _text(await wire.call("browser.text", {
            "pane": args["pane"],
            "selector": args.get("selector"),
            "limit": args.get("limit", 4000),
        }))

    async def browser_eval(args: dict) -> dict:
        _log_eval(wire, args.get("pane"), args["script"])
        return _text(await wire.call("browser.eval", {
            "pane": args["pane"], "script": args["script"]}))

    async def browser_elements(args: dict) -> dict:
        return _text(await wire.call("browser.elements", {
            "pane": args["pane"],
            "limit": args.get("limit"),
            "wait_for": args.get("wait_for"),
            "timeout_ms": args.get("timeout_ms"),
        }))

    async def browser_find(args: dict) -> dict:
        return _text(await wire.call("browser.find", {
            "pane": args["pane"], "text": args["text"],
            "limit": args.get("limit")}))

    async def browser_click(args: dict) -> dict:
        return _text(await wire.call("browser.click", {
            "pane": args["pane"], "ref": args["ref"]}))

    async def browser_type(args: dict) -> dict:
        return _text(await wire.call("browser.type", {
            "pane": args["pane"],
            "ref": args["ref"],
            "text": args["text"],
            "enter": bool(args.get("enter", False)),
        }))

    async def browser_select(args: dict) -> dict:
        return _text(await wire.call("browser.select", {
            "pane": args["pane"], "ref": args["ref"], "option": args["option"]}))

    async def browser_key(args: dict) -> dict:
        return _text(await wire.call("browser.key", {
            "pane": args["pane"], "ref": args.get("ref"), "key": args["key"]}))

    async def browser_scroll(args: dict) -> dict:
        return _text(await wire.call("browser.scroll", {
            "pane": args["pane"], "ref": args.get("ref"),
            "to": args.get("to"), "by": args.get("by")}))

    async def browser_back(args: dict) -> dict:
        return _text(await wire.call("browser.back", {"pane": args["pane"]}))

    async def browser_forward(args: dict) -> dict:
        return _text(await wire.call("browser.forward", {"pane": args["pane"]}))

    async def browser_snapshot(args: dict) -> dict:
        return _text(await wire.call("browser.snapshot", {"pane": args["pane"]}))

    async def browser_console(args: dict) -> dict:
        return _text(await wire.call("browser.console", {
            "pane": args["pane"],
            "since": args.get("since", 0),
            "level": args.get("level"),
            "limit": args.get("limit"),
        }))

    async def browser_network(args: dict) -> dict:
        return _text(await wire.call("browser.network", {
            "pane": args["pane"],
            "since": args.get("since", 0),
            "failures_only": bool(args.get("failures_only", False)),
            "limit": args.get("limit"),
        }))

    pane = {"type": "integer", "description": "The pane id."}
    every = [
        ("prose_ask",
         "Ask the user a question and wait for the answer. Offer `choices` for "
         "buttons, `placeholder` for a typed answer, or both — they are not "
         "exclusive. Only one question may be outstanding at a time.",
         {"type": "object",
          "properties": {
              "prompt": {"type": "string"},
              "choices": {"type": "array", "items": {"type": "string"}},
              "placeholder": {"type": "string"},
          },
          "required": ["prompt"]},
         ask),

        ("prose_spawn",
         "Split this pane and start a subagent in the new one with `task`. "
         "Returns its pane and session at once — the child is still starting, "
         "so follow with prose_wait rather than sleeping. `flavour` picks what "
         "sort of agent to open; everything but 'prose' and 'code' is a "
         "specialist that already knows its job and costs you none of your own "
         "context to run:\n\n"
         + catalogue_lines() +
         "\n\nMatch the request against those descriptions before deciding to "
         "do a job yourself — a specialist exists because that work does not "
         "belong in your context. Some take `params`; call prose_archetypes to "
         "see what one takes and what shape its result has before spawning it.",
         {"type": "object",
          "properties": {
              "task": {"type": "string"},
              "flavour": {"type": "string", "enum": flavours()},
              "params": {"type": "object",
                         "description": "values for the archetype's declared "
                                        "parameters. See prose_archetypes."},
              "axis": {"type": "string", "enum": ["row", "column"]},
              "cwd": {"type": "string"},
              "title": {"type": "string"},
          },
          "required": ["task"]},
         spawn),

        ("prose_archetypes",
         "What each specialist flavour takes and returns. Costs one call and "
         "saves reading a transcript: an archetype's own instructions never "
         "enter your context, so this is the only way to see its parameters "
         "and the JSON shape its prose_result will have. Call it before "
         "spawning one you have not used in this conversation.",
         {"type": "object", "properties": {}},
         experts),

        ("prose_archetype_check",
         "Check the text of an archetype definition before writing it, and see "
         "the tool surface it would really have. Returns `problems` (empty "
         "means deployable), `effective.registered` — which is not what the "
         "`allow:` line says, because that list only auto-approves — plus the "
         "archetypes that already exist and where the catalogue lives. A file "
         "that fails to parse is skipped in silence at load, so this is the "
         "only way to find out.",
         {"type": "object",
          "properties": {
              "text": {"type": "string",
                       "description": "the whole file, frontmatter and body"},
              "name": {"type": "string",
                       "description": "the filename stem it will be saved as, "
                                      "which the header's `name` must match"},
          },
          "required": ["text", "name"]},
         check_archetype),

        ("prose_wait",
         "Wait until a pane's turn ends, it asks a question, or its agent "
         "exits — and get everything new since `since` back with it. This is "
         "the loop primitive: one call per turn of the child's. It returns "
         "immediately if the condition has already happened. Always pass the "
         "`cursor` from your last call as `since`.",
         {"type": "object",
          "properties": {
              "pane": pane,
              "since": {"type": "integer"},
              "until": {"type": "array", "items": {"type": "string"}},
              "timeout_ms": {"type": "integer"},
              "fidelity": {"type": "string", "enum": ["summary", "full"]},
          },
          "required": ["pane", "since"]},
         wait),

        ("prose_read",
         "Read a pane's transcript without waiting. Defaults to summaries, "
         "which are around sixteen times cheaper than the full text; each one "
         "carries `n`, the block's length, so you can tell whether reading it "
         "in full is worth it. Pass `block` to read exactly one in full.",
         {"type": "object",
          "properties": {
              "pane": pane,
              "since": {"type": "integer"},
              "block": {"type": "integer"},
              "fidelity": {"type": "string", "enum": ["summary", "full"]},
              "kinds": {"type": "array", "items": {"type": "string"}},
              "match": {"type": "string"},
              "limit": {"type": "integer"},
          },
          "required": ["pane"]},
         read),

        ("prose_send",
         "Say something to a pane, as if the user had typed it. **This is how "
         "a second errand reaches a specialist you already have open** — a "
         "pane you spawned stays alive after it returns a result, so sending "
         "to it costs one call, while spawning another costs a pane, a "
         "process and a fresh context that knows nothing about the first job.",
         {"type": "object",
          "properties": {"pane": pane, "text": {"type": "string"}},
          "required": ["pane", "text"]},
         send),

        ("prose_answer",
         "Answer the question a subagent's pane is stopped on, as a click "
         "would. Set `escalate` to decline it and let the user answer instead.",
         {"type": "object",
          "properties": {
              "pane": pane,
              "text": {"type": "string"},
              "escalate": {"type": "boolean"},
          },
          "required": ["pane"]},
         answer),

        ("prose_interrupt", "Stop a pane's turn. Its agent stays alive.",
         {"type": "object", "properties": {"pane": pane}, "required": ["pane"]},
         interrupt),

        ("prose_close", "Close a pane. Its agent is told before its socket goes.",
         {"type": "object", "properties": {"pane": pane}, "required": ["pane"]},
         close),

        ("prose_focus",
         "Bring a pane into view, without taking the keyboard from whoever is "
         "typing. For when a subagent is worth watching — not for getting "
         "attention.",
         {"type": "object", "properties": {"pane": pane}, "required": ["pane"]},
         focus),

        ("prose_result",
         "Return a value to whoever spawned this pane. Does nothing in a pane "
         "the user opened.",
         {"type": "object", "properties": {"value": {}}, "required": ["value"]},
         result),

        ("prose_schedule",
         "Propose durable agent work that runs once, on an interval, on a local "
         "calendar rule, from an event, or manually. The user must approve the "
         "resolved proposal before prose stores it. ISO dates must include an "
         "offset. Calendar weekdays are 1=Sunday through 7=Saturday.",
         {"type": "object",
          "properties": {
              "title": {"type": "string"},
              "task": {"type": "string"},
              "flavour": {"type": "string", "enum": flavours()},
              "params": {"type": "object"},
              "cwd": {"type": "string"},
              "trigger": {
                  "type": "object",
                  "description": (
                      "One of: {kind:'at',at:ISO8601}; "
                      "{kind:'interval',seconds:int,anchor?:ISO8601}; "
                      "{kind:'calendar',frequency:'daily'|'weekly'|'monthly',"
                      "hour:0..23,minute:0..59,timezone:IANA,weekdays?:[1..7],"
                      "day?:1..31}; {kind:'event',source,type,"
                      "subject_contains?}; or {kind:'manual'}."),
              },
              "policy": {
                  "type": "object",
                  "properties": {
                      "misfire": {"type": "string",
                                  "enum": ["skip", "runOnce", "catchUp"]},
                      "catch_up": {"type": "integer"},
                      "concurrency": {"type": "string",
                                      "enum": ["queue", "skipWhileRunning", "replace"]},
                      "maximum_runtime": {"type": "number"},
                      "maximum_attempts": {"type": "integer"},
                  },
              },
          },
          "required": ["title", "task", "trigger"]},
         schedule),

        ("prose_schedules",
         "List durable automations and recent occurrence history, including "
         "ids, enabled state, next fire time and run outcome.",
         {"type": "object",
          "properties": {"include_runs": {"type": "boolean"}}},
         schedules),

        ("prose_change_schedule",
         "Pause, resume, delete, or immediately run a durable automation. The "
         "user confirms the mutation before it reaches prose.",
         {"type": "object",
          "properties": {
              "id": {"type": "string"},
              "action": {"type": "string",
                         "enum": ["pause", "resume", "delete", "run_now"]},
          },
          "required": ["id", "action"]},
         change_schedule),

        ("prose_emit_event",
         "Insert one idempotent event into prose's automation inbox. Matching "
         "event schedules run once; reusing source plus external_id is ignored.",
         {"type": "object",
          "properties": {
              "external_id": {"type": "string"},
              "source": {"type": "string"},
              "type": {"type": "string"},
              "subject": {"type": "string"},
              "payload": {},
          },
          "required": ["external_id", "source", "type"]},
         emit_event),

        ("browser_open",
         "Open a browser on `url`, above this pane. You may drive only the "
         "browser panes you opened. **One is usually enough** — to read a "
         "second page, `browser_navigate` the pane you already have rather "
         "than opening another, which halves your pane every time.",
         {"type": "object",
          "properties": {"url": {"type": "string"},
                         "axis": {"type": "string", "enum": ["row", "column"]},
                         "placement": {"type": "string",
                                       "enum": ["before", "after"]}},
          "required": ["url"]},
         browser_open),

        ("browser_navigate", "Point a browser pane you opened at a URL.",
         {"type": "object",
          "properties": {"pane": pane, "url": {"type": "string"}},
          "required": ["pane", "url"]},
         browser_navigate),

        ("browser_text",
         "The page's rendered text. Narrow it with `selector` and `limit` — a "
         "whole page is easily ten thousand tokens. The reply carries "
         "`matched`: false means your selector found nothing, which is a "
         "different problem from a page that is genuinely empty.",
         {"type": "object",
          "properties": {"pane": pane, "selector": {"type": "string"},
                         "limit": {"type": "integer"}},
          "required": ["pane"]},
         browser_text),

        ("browser_eval",
         "Run JavaScript in a browser pane and get its value. **Last resort, "
         "and never for acting on a page.** Everything a person does to a "
         "page has a tool: browser_find to locate a control, browser_click, "
         "browser_type, browser_select, browser_key, browser_scroll, "
         "browser_back. Those act through refs the page itself hands out, so "
         "they cannot miss silently the way a selector you invented can — you "
         "cannot see the markup, so every selector is a guess. Use this only "
         "for a value no tool returns: a count, an attribute, something "
         "computed. If you reach for it to find or click something, the right "
         "call is browser_find. Every use is logged.",
         {"type": "object",
          "properties": {"pane": pane, "script": {"type": "string"}},
          "required": ["pane", "script"]},
         browser_eval),

        ("browser_elements",
         "The page's interactive elements, numbered: every link, button, "
         "field and control, with its role and the name a person would read "
         "off the screen. **Reach for this before acting on any page.** It is "
         "around two hundred tokens — a fraction of a screenshot — and the "
         "refs it returns are what browser_click, browser_type, "
         "browser_select, browser_key and browser_scroll take, so you never "
         "have to invent a CSS selector. Check `total`: if the list came back "
         "`truncated`, the page has more controls than were shown and "
         "browser_find is how you reach them — not a bigger limit. The list "
         "belongs to the page as it is now, so after anything that navigates "
         "or redraws, take it again. "
         "**Pass `wait_for` or `timeout_ms` when the page is still changing** "
         "— after a click that opens a menu, filters a list or changes a "
         "route without loading a new page. It returns as soon as the text in "
         "`wait_for` is on the page, or as soon as the page stops mutating, "
         "and it returns *immediately* if that is already true. That is how "
         "you wait for something that is not a navigation; never poll with "
         "browser_eval.",
         {"type": "object",
          "properties": {"pane": pane,
                         "limit": {"type": "integer",
                                   "description": "most elements to list, default 200"},
                         "wait_for": {"type": "string",
                                      "description": "text to wait for on the page before "
                                                     "listing; omit to wait only for the page "
                                                     "to stop changing"},
                         "timeout_ms": {"type": "integer",
                                        "description": "how long to wait, default 10000"}},
          "required": ["pane"]},
         browser_elements),

        ("browser_find",
         "The interactive elements whose name or link target contains `text`, "
         "numbered the same way browser_elements numbers them. **This is how "
         "you act on a long page.** An article with a thousand links answers "
         "browser_elements with two hundred lines of site navigation and none "
         "of them the one you want; this searches the whole page and returns "
         "the few that match, with refs you can click straight away. Matching "
         "is case-insensitive and on any part of the name, so a word or two "
         "of what you saw in the text is enough.",
         {"type": "object",
          "properties": {"pane": pane, "text": {"type": "string"},
                         "limit": {"type": "integer",
                                   "description": "most matches to return, default 40"}},
          "required": ["pane", "text"]},
         browser_find),

        ("browser_click",
         "Click an element by the `ref` browser_elements gave you. Dispatches "
         "the whole pointer sequence, so components that ignore a bare click "
         "still see it. A ref from before a navigation is refused rather than "
         "acted on — take the list again.",
         {"type": "object",
          "properties": {"pane": pane, "ref": {"type": "string"}},
          "required": ["pane", "ref"]},
         browser_click),

        ("browser_type",
         "Type into a field by its `ref`, replacing what is there. Set "
         "`enter` to submit afterwards, which is usually what a search box "
         "wants. The text reaches the page the way a keystroke would, so "
         "applications that track their own state see it.",
         {"type": "object",
          "properties": {"pane": pane, "ref": {"type": "string"},
                         "text": {"type": "string"},
                         "enter": {"type": "boolean"}},
          "required": ["pane", "ref", "text"]},
         browser_type),

        ("browser_scroll",
         "Scroll a `ref` into view, or pass `to` as 'top' or 'bottom', or "
         "`by` a number of pixels — negative for up. Needed for pages that "
         "load more as you go, and before a snapshot, which only ever "
         "captures what is on screen. With a `ref` it moves whichever box "
         "that element actually scrolls in, so a list inside a page scrolls "
         "rather than the page behind it. The reply carries `moved` and "
         "`at_end`: `moved: 0` with `at_end: true` means there is no more, "
         "which is when to stop rather than to scroll again.",
         {"type": "object",
          "properties": {"pane": pane, "ref": {"type": "string"},
                         "to": {"type": "string", "enum": ["top", "bottom"]},
                         "by": {"type": "integer",
                                "description": "pixels to scroll, negative for up"}},
          "required": ["pane"]},
         browser_scroll),

        ("browser_console",
         "What the page printed: its console, its uncaught errors and its "
         "unhandled rejections. **This is how you tell a broken site from a "
         "wrong selector.** When a click does nothing, a list never arrives "
         "or a form will not submit, read this before trying the same thing "
         "again — a page throwing on every render will not start working "
         "because you found a better ref. Defaults to warnings and errors, "
         "which is almost always what you want; pass level 'all' only when "
         "you are following an application's own logging. `since` takes the "
         "`cursor` from the last reply and returns only what is new, so "
         "checking repeatedly is cheap. A `dropped` count means the page "
         "said more than was kept.",
         {"type": "object",
          "properties": {"pane": pane,
                         "since": {"type": "integer",
                                   "description": "cursor from a previous reply; omit for "
                                                  "everything held"},
                         "level": {"type": "string", "enum": ["all", "info", "warn", "error"],
                                   "description": "lowest level to return, default warn"},
                         "limit": {"type": "integer",
                                   "description": "most lines to return, newest kept, "
                                                  "default 50"}},
          "required": ["pane"]},
         browser_console),

        ("browser_network",
         "The requests the page made — every fetch and XHR, the main "
         "document's own status code, and any image or script that failed to "
         "load. **Read this when a page looks empty or half-rendered.** A "
         "list that never appeared is usually a request that 401'd or 500'd, "
         "and no amount of waiting or re-listing elements will show you "
         "that. Pass failures_only to get just the requests that did not "
         "come back 2xx, which is the usual question. `since` takes the "
         "`cursor` from the last reply, the same way browser_console does.",
         {"type": "object",
          "properties": {"pane": pane,
                         "since": {"type": "integer",
                                   "description": "cursor from a previous reply; omit for "
                                                  "everything held"},
                         "failures_only": {"type": "boolean",
                                           "description": "only requests that failed or "
                                                          "returned 4xx/5xx"},
                         "limit": {"type": "integer",
                                   "description": "most requests to return, newest kept, "
                                                  "default 50"}},
          "required": ["pane"]},
         browser_network),

        ("browser_select",
         "Choose an option in a dropdown by its `ref` and the option's "
         "visible label. A `<select>` cannot be operated by clicking — the "
         "menu it opens is drawn by the platform, outside the page — so this "
         "is the only way to set one. It also handles the ARIA spelling, "
         "where the options are elements in a listbox. If the label does not "
         "match, the error lists the options there actually are.",
         {"type": "object",
          "properties": {"pane": pane, "ref": {"type": "string"},
                         "option": {"type": "string",
                                    "description": "the option's visible label"}},
          "required": ["pane", "ref", "option"]},
         browser_select),

        ("browser_key",
         "Press one key: escape, tab, enter, arrowup, arrowdown, arrowleft, "
         "arrowright, backspace, delete, space, home, end, pageup, pagedown. "
         "Omit `ref` to press it wherever the focus is, which is what "
         "dismissing a dialog with escape means. This is how you work a "
         "menu, an autocomplete or a modal — none of which a click can "
         "close.",
         {"type": "object",
          "properties": {"pane": pane,
                         "ref": {"type": "string",
                                 "description": "element to focus first; omit for "
                                                "wherever focus already is"},
                         "key": {"type": "string"}},
          "required": ["pane", "key"]},
         browser_key),

        ("browser_back",
         "Go back one page in the pane's history. After a link that turned "
         "out to be wrong, this is how you return — you may not know the URL "
         "you came from. A navigation, so follow it with prose_wait like any "
         "other.",
         {"type": "object", "properties": {"pane": pane}, "required": ["pane"]},
         browser_back),

        ("browser_forward",
         "Go forward one page in the pane's history, undoing a browser_back.",
         {"type": "object", "properties": {"pane": pane}, "required": ["pane"]},
         browser_forward),

        ("browser_snapshot",
         "Write a PNG of a browser pane and return its path — not the image. "
         "Last resort: you then have to Read that path, which costs around "
         "1,500 tokens, so do it only when the page's appearance is the actual "
         "question. It captures what is on screen and nothing else, so "
         "browser_scroll first if what you want is further down.",
         {"type": "object", "properties": {"pane": pane}, "required": ["pane"]},
         browser_snapshot),
    ]
    return [entry for entry in every if entry[0] not in set(omit)]


def qualify(names: tuple[str, ...] | list[str], prefix: str = "prose") -> list[str]:
    """Archetype files name prose's tools plainly — `browser_text`, not
    `mcp__prose__browser_text`.

    The SDK recognises only the namespaced spelling, and a name it does not
    recognise is **ignored rather than refused** — so without this an archetype
    would have an allowance it appears to have and does not, with nothing
    anywhere saying so. Names that are not prose's own pass through untouched,
    which is what lets the same lists carry `Read` and `Bash`.
    """
    prose = {name.rsplit("__", 1)[-1]: name for name in tool_names(prefix)}
    return [prose.get(name, name) for name in names]


def tool_names(prefix: str = "prose", omit: tuple[str, ...] | list[str] = ()
               ) -> list[str]:
    """What these are called once the SDK has namespaced them, which is what
    `allowed_tools` has to be given.

    Defaults to the whole catalogue, because `qualify` translates names against
    it and has to be able to see a tool in order to namespace it — including
    one this pane will not be given.
    """
    return [f"mcp__{prefix}__{name}"
            for name, _, _, _ in definitions(_Unbound(), omit=omit)]


class _Unbound:
    """A stand-in, so the names can be listed without a live connection."""

    session = 0
    pane = None

    def call(self, *_args, **_kwargs):  # pragma: no cover - never invoked
        raise ProseError("not connected")

    def notify(self, *_args, **_kwargs):  # pragma: no cover - never invoked
        raise ProseError("not connected")


def mcp_server(wire: Wire, name: str = "prose", asker: Asker | None = None,
               omit: tuple[str, ...] | list[str] = ()):
    """The tools above, as an in-process MCP server for the Agent SDK.

    The only thing here that imports the SDK, so everything else stays usable
    and testable without it.
    """
    from claude_agent_sdk import create_sdk_mcp_server, tool

    built = []
    for tool_name, description, schema, handler in definitions(
            wire, asker=asker, omit=omit):
        built.append(tool(tool_name, description, schema)(handler))
    return create_sdk_mcp_server(name=name, tools=built)
