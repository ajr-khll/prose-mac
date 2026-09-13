"""A tool asking permission, drawn as the card prose already has.

`permission_mode="default"` means the SDK asks before anything not named in
`allowed_tools`. Somebody has to answer, and prose already has exactly the
right thing: a card with buttons *and* a text field, drawn in the pane the
agent is running in, which a supervising parent can also answer.

The decision is kept separate from the SDK's result types on purpose — `decide`
is pure and testable with nothing installed, and `__call__` is the six lines
that translate it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING, Any

from .asking import Asker
from .harness import _label
from .tools import BROWSER
from .wire import ProseError

if TYPE_CHECKING:
    from .archetypes import Archetype

#: Built-in tools a pane agent may call without asking.
#:
#: `allowed_tools` **auto-approves**; it does not restrict. So this is exactly
#: the list of calls that should not raise a card, and everything absent from
#: it falls through to `Permissions` and becomes one. Reading is free; changing
#: anything is not, which is why `Bash`, `Write`, `Edit` and `WebFetch` are
#: deliberately missing. `Skill` must be here or skills do not exist at all.
UNATTENDED = ["Read", "Glob", "Grep", "WebSearch", "Skill"]

#: Built-in tools that cannot work inside a pane, and must not be reachable.
#:
#: `Task` opens a subagent with no pane, no transcript and nothing for
#: `prose_wait` to park on. prose's answer to "delegate this" is `prose_spawn`,
#: which produces a pane a person can watch. Two mechanisms for one idea, one
#: of them invisible, is worse than one.
#:
#: `AskUserQuestion` is worse than invisible — it is **broken**. It needs an
#: interactive terminal to draw its own picker, and an SDK session has none, so
#: it returns "The user did not answer the question" the instant it is called.
#: The model then tells the person they ignored a question they were never
#: shown. Measured, not reasoned about: it is what the first pane asked to ask
#: something actually did, twice, and the wire log is why we know.
#: `prose_ask` is the tool that reaches a person here, and with this one gone
#: it is the only one.
#: Built-in tools a pane agent must not reach, and why. Three groups.
#:
#: **They route around containment.** `spec §10`'s whole authorisation model is
#: that a session may act on its own pane and on panes descended from it, and
#: nothing else. `ListAgents` and `SendMessage` address the CLI's *own*
#: cross-session registry instead, which prose knows nothing about and cannot
#: guard. Asked to list agents, a pane agent here enumerated **nineteen other
#: Claude sessions on this machine** — names, ids, busy/idle, how long they had
#: been running — and `SendMessage` would let it talk to any of them. A pane
#: agent that has just read a web page is exactly the thing that must not be
#: able to do that.
#:
#: **They start agent work with no pane.** `Task` and the whole `Task*` family.
#: No transcript, nothing for `prose_wait` to park on, nothing drawn for the
#: person. prose's answer to "do this in the background" is `prose_spawn`,
#: which produces a pane that can be watched, interrupted and supervised. Two
#: mechanisms for one idea, one of them invisible, is worse than one. The
#: family was missed the first time because this list was written from the
#: SDK's documentation rather than from the tools the CLI actually offers.
#:
#: **They need a harness prose does not have.** `AskUserQuestion` wants an
#: interactive terminal and answers itself with "the user did not answer" the
#: instant it is called — which it did, twice, to a person who was never shown
#: anything. `ScheduleWakeup` wants /loop's session infrastructure, `Monitor` a
#: background task runner whose output would go nowhere, and `RemoteTrigger`
#: and `DesignSync` a claude.ai login this process does not carry. All four
#: fail the same way: they report success having done nothing, and the model
#: relays that.
#:
#: Deliberately still reachable, behind an ask card: `Cron*` and
#: `PushNotification`, because a personal agent that can remind and notify is
#: most of the job — `CronList` answers, so they are at least wired — and
#: `EnterWorktree`/`ExitWorktree`, which are real and are what the `code`
#: flavour is for. Watch them: if one turns out to be another confident no-op,
#: it belongs in the third group.
INVISIBLE = [
    # Route around prose's containment.
    "ListAgents", "SendMessage",
    # Agent work with no pane behind it.
    "Task", "TaskCreate", "TaskGet", "TaskList", "TaskOutput", "TaskStop",
    "TaskUpdate",
    # Need a harness prose does not provide, and fail silently without it.
    "AskUserQuestion", "ScheduleWakeup", "Monitor", "RemoteTrigger", "DesignSync",
]

#: Browser tools, withheld from any pane agent that can spawn.
#:
#: **A browser task is handed to the `browser-pilot` archetype, always.** The
#: reason is not politeness about context budgets; it is that a general agent
#: holding these tools reliably drives a browser badly. Watched doing it, one
#: went straight to `browser_eval` with a guessed CSS selector, got `null`
#: twice and had to be interrupted — while `browser_elements`, which returns
#: the clickable things by ref and makes selectors unnecessary, sat unused in
#: the same tool list. The archetype's instructions forbid exactly that mistake
#: and cost the parent nothing, because they load into the pilot's pane.
#:
#: A prompt rule could not fix this, and the shape of the failure says why. The
#: cheap path was one `browser_open` away and delegating was three calls; the
#: prompt argued for both and the model took the short path. So the capability
#: goes, and the only browser in reach is one pane over.
#:
#: `loop.serve` reads this and does not *register* the tools, rather than
#: registering them and refusing the call: a denied tool still costs its schema
#: in context every turn and still invites the attempt.
#:
#: `WebFetch` is on the list for the same reason under a different name. It is
#: not a browser tool, but it is the other way a whole page arrives in the
#: parent's context, and it is what the model falls back to the moment
#: spawning looks like hard work — measured: given a Wikipedia errand it
#: reached for `browser-pilot` first, twice, and when the spawn failed it
#: fetched the page itself rather than reporting that it could not. Leaving it
#: reachable would make the rule advisory again.
#:
#: `WebSearch` deliberately stays, and unattended. A search returns result
#: lines rather than a page, so it does not carry the cost the pilot exists to
#: absorb — and finding the URL to hand the pilot is the parent's own job.
#:
#: `browser-pilot` declares the browser tools in its own `allow:` and is
#: unaffected — an archetype's lists are built by `allowance` from its file,
#: not from here. It is denied `WebFetch` too: a pilot that can fetch would
#: skip its own loop.
NO_BROWSER = list(BROWSER) + ["WebFetch"]

#: How much of an argument fits on a card before it stops being readable. The
#: activity row above it already carries the whole thing.
WIDTH = 120

#: What each tool is really asking to do, in the words a person would use.
#: Anything not here gets "use", which is vague but honest.
VERBS = {
    "Bash": "run", "Write": "write", "Edit": "edit", "NotebookEdit": "edit",
    "WebFetch": "fetch", "Read": "read", "Glob": "search", "Grep": "search",
}


@dataclass(frozen=True)
class Decision:
    allowed: bool
    #: Why not. Passed to the model verbatim, so a typed refusal is a redirect
    #: rather than a dead end.
    message: str = ""


class Permissions:
    """The `can_use_tool` callback, answered through the pane."""

    def __init__(self, asker: Asker):
        self._asker = asker
        #: What the person has said yes to for the rest of this pane's life.
        #: In memory and never written down: a grant that outlived the pane
        #: would be a settings file and an audit surface, and neither is this.
        self._always: set[str] = set()

    async def __call__(self, tool: str, arguments: dict, context: Any = None) -> Any:
        from claude_agent_sdk import PermissionResultAllow, PermissionResultDeny

        decision = await self.decide(tool, arguments or {})
        if decision.allowed:
            return PermissionResultAllow(updated_input=arguments)
        # `interrupt=False`: a refusal is something for the model to work
        # around, not a reason to tear the turn down.
        return PermissionResultDeny(message=decision.message, interrupt=False)

    async def decide(self, tool: str, arguments: dict) -> Decision:
        """Allowed or not, and why not — without touching the SDK."""
        key = grant(tool, arguments)
        if key in self._always:
            return Decision(True)

        forever = f"Allow {key} from now on"
        try:
            answer = await self._asker.ask(
                prompt=describe(tool, arguments),
                choices=["Allow once", forever, "Deny"],
                placeholder="or say why not")
        except ProseError:
            # prose has gone, or the pane has. Never fall open when the person
            # cannot be reached.
            return Decision(False, "prose could not ask anyone, so this was declined.")

        if answer == "Allow once":
            return Decision(True)
        if answer == forever:
            self._always.add(key)
            return Decision(True)
        if answer in ("Deny", ""):
            return Decision(False, "The user declined.")
        # Anything else is the text field: they typed a reason instead of
        # clicking, and the reason is more useful to the model than the
        # refusal. This is what the card's choices and placeholder being
        # orthogonal is *for*.
        return Decision(False, answer)


def grant(tool: str, arguments: dict) -> str:
    """What "from now on" would actually be granting.

    The tool's name, except for `Bash`, where it is the executable. "Allow Bash
    from now on" is `bypassPermissions` reached by a single click, and nobody
    clicking yes three times in a row means to grant that; "allow git from now
    on" is a thing a person can hold in their head. The button says this
    string, because the button text is what they are consenting to.
    """
    if tool != "Bash":
        return tool
    command = arguments.get("command")
    if not isinstance(command, str) or not command.strip():
        return "Bash"
    return f"Bash({command.split()[0]})"


def describe(tool: str, arguments: dict) -> str:
    """The question, written for two readers (guide §8).

    A person reads it at a glance; a supervising parent agent can act on it.
    The label comes from the same formatter the activity row uses, so the card
    and the row above it say the same thing about the same call.
    """
    verb = VERBS.get(tool, "use")
    detail = _label(tool, arguments)
    if detail == tool:
        return f"{tool} wants to {verb} something."
    inside = detail[len(tool) + 1:-1]
    if len(inside) > WIDTH:
        inside = inside[: WIDTH - 1] + "…"
    return f"{tool} wants to {verb}: {inside}"


def allowance(archetype: "Archetype") -> tuple[list[str], list[str]]:
    """The two tool lists one archetype runs under: `(allowed, disallowed)`.

    Kept here, away from the SDK, because this is the decision rather than the
    plumbing — which is the same reason `decide` is a separate function from
    `__call__` above.

    **The two lists are not symmetrical**, and the asymmetry is the thing to
    understand before editing an archetype. `allowed_tools` *auto-approves*; it
    does not restrict. So `allow` is the set that runs without a card, and
    everything missing from it still works — it just raises one. Only
    `disallowed_tools` makes a tool unreachable.

    Which is why `allow` **replaces** `UNATTENDED` rather than extending it. A
    browser expert that kept `Read`, `Glob` and `WebSearch` unattended could not
    be narrower than any other pane, and the point of declaring an allowance is
    that it is precise. Leaving a tool out blocks nothing; it makes the tool
    ask, and for a narrow expert reaching outside its job that is exactly the
    outcome you want — a surprise that is visible rather than silent.
    """
    from .tools import qualify

    allowed = qualify(archetype.allow) if archetype.allow else list(UNATTENDED)

    denied = list(INVISIBLE) + qualify(archetype.deny)
    if not archetype.spawns:
        # A narrow expert that can spawn a wide one has everything it was
        # denied, one pane away. Descendant containment does not catch it —
        # the child is a perfectly legitimate descendant — so the door is shut
        # here, and an archetype has to ask for spawning in writing.
        denied += qualify(["prose_spawn"])

    # Ordered de-duplication: an archetype restating a door prose already shuts
    # is a reasonable thing to write, and repeats only make a log harder to read.
    return allowed, list(dict.fromkeys(denied))
