"""The connector surface, tested with nothing installed and nothing connected.

Everything here is a decision made before the wire: which providers a pane
holds, which tools that gets it, and which of them may run without a person
seeing a card. The broker's own checks are the ones that matter in the end, but
these are the ones that can be wrong silently.
"""

from __future__ import annotations

import asyncio
import json
import unittest

import support  # noqa: F401 - puts `prose_agent` on the path
from prose_agent import apps
from prose_agent.archetypes import Archetype
from prose_agent.permissions import allowance
from prose_agent.wire import ProseError


def one(archetype: Archetype) -> tuple[list[str], list[str]]:
    return allowance(archetype)


def built(**fields) -> Archetype:
    return Archetype(name=fields.pop("name", "specialist"),
                     description="Use when testing.",
                     body="x" * 700, **fields)


class TheProviderSet(unittest.TestCase):
    def test_a_typo_is_refused_rather_than_dropped(self) -> None:
        """The failure this whole surface is arranged against is a specialist
        that looks equipped and is not."""
        with self.assertRaises(ProseError) as caught:
            apps.providers(["slak"])
        self.assertIn("slak", str(caught.exception))
        self.assertIn("slack", str(caught.exception))

    def test_duplicates_collapse_and_order_is_kept(self) -> None:
        self.assertEqual(apps.providers(["slack", "google", "slack"]),
                         ("slack", "google"))


class WhatTheToolsSee(unittest.TestCase):
    """The provider set is closed over, so the schema itself is narrow — the
    model cannot name a provider this pane does not hold, and does not spend
    tokens reading about ones it cannot reach."""

    def surface(self, providers):
        return {name: (schema, handler) for name, _, schema, handler
                in apps.definitions(apps._Unbound(), providers)}

    def test_the_enum_is_this_panes_providers_only(self) -> None:
        schema, _ = self.surface(("github", "notion"))["apps_search"]
        self.assertEqual(schema["properties"]["provider"]["enum"],
                         ["github", "notion"])

    def test_a_provider_outside_the_set_is_refused_before_the_wire(self) -> None:
        """`_Unbound.call` raises if it is ever reached, so a refusal that
        names the provider proves nothing was sent."""
        _, search = self.surface(("github", "notion"))["apps_search"]
        with self.assertRaises(ProseError) as caught:
            asyncio.run(search({"provider": "slack", "connection": "c",
                                "kind": "message"}))
        self.assertIn("no slack access", str(caught.exception))
        self.assertNotIn("not connected", str(caught.exception))

    def test_a_ref_borrowed_from_another_pane_is_refused_too(self) -> None:
        """`apps_get` takes a ref rather than a provider, so the check has to
        read the prefix — otherwise a ref copied out of another transcript is
        the way around the provider set."""
        _, get = self.surface(("github",))["apps_get"]
        with self.assertRaises(ProseError):
            asyncio.run(get({"ref": "slack:work:message:123"}))

    def test_commit_takes_only_a_preview_id(self) -> None:
        """The arguments stop being an input at prepare. That is what makes the
        text a person approved and the text that gets sent the same text."""
        schema, _ = self.surface(("slack",))["apps_commit"]
        self.assertEqual(set(schema["properties"]), {"preview"})


class EveryAnswerHasAnEnvelope(unittest.TestCase):
    """An MCP result is `{"content": [...]}`. A handler returning a bare dict
    is not an error — the SDK emits **nothing**, which reaches the model as
    "completed with no output" and cannot be told apart from a tool that ran
    and found nothing.

    That shipped: every `apps_*` call in a live pane came back empty, refusals
    included, so the agent could not even see that GitHub was unconnected. It
    asked the person what was going on, which was the right instinct and the
    only reason it was caught. Checked for every tool at once rather than one
    by one, because the next tool added here will forget the same thing.
    """

    class Wire:
        session = 0

        async def call(self, method, params, timeout=60.0):
            return {"ok": True}

    class Asker:
        async def ask(self, prompt, choices=None, placeholder=None,
                      secret=False):
            return "a-token"

    def test_every_handler_returns_a_content_envelope(self) -> None:
        arguments = {
            "apps_connections": {},
            "apps_connect": {"provider": "github"},
            "apps_capabilities": {"provider": "github"},
            "apps_search": {"provider": "github", "connection": "c",
                            "kind": "issue"},
            "apps_get": {"ref": "github:c:issue:a/b#1"},
            "apps_prepare": {"provider": "github", "connection": "c",
                             "operation": "issue.create", "arguments": {}},
            "apps_commit": {"preview": "preview_1"},
            "apps_cancel": {"preview": "preview_1"},
        }
        built = apps.definitions(self.Wire(), ("github",), asker=self.Asker())
        self.assertEqual(len(built), len(arguments), "a tool has no case here")

        for name, _, _, handler in built:
            answer = asyncio.run(handler(arguments[name]))
            self.assertIn("content", answer, f"{name} returns no envelope")
            self.assertTrue(answer["content"], f"{name} returns empty content")
            self.assertEqual(answer["content"][0]["type"], "text", name)

    def test_a_declined_connect_is_still_an_envelope(self) -> None:
        """The path that returns early, which is the one that skips the
        wrapper by hand rather than by forgetting it."""
        class Declines:
            async def ask(self, prompt, choices=None, placeholder=None,
                          secret=False):
                return ""

        built = {name: fn for name, _, _, fn
                 in apps.definitions(self.Wire(), ("github",), asker=Declines())}
        answer = asyncio.run(built["apps_connect"]({"provider": "github"}))
        self.assertIn("content", answer)
        self.assertIn("connected", answer["content"][0]["text"])


class WhoGetsThem(unittest.TestCase):
    def test_an_archetype_without_integrations_gets_no_connector_tools(self) -> None:
        allowed, _ = one(built(allow=("apps_search", "prose_result")))
        self.assertNotIn("mcp__apps__apps_search", allowed)

    def test_commit_is_never_auto_approved_however_the_file_asks(self) -> None:
        """The one tool here that changes something other people can see. v1
        buys that with a person, so `allow: apps_commit` is dropped rather than
        honoured."""
        allowed, _ = one(built(allow=("apps_search", "apps_commit"),
                               integrations=("slack",)))
        self.assertIn("mcp__apps__apps_search", allowed)
        self.assertNotIn("mcp__apps__apps_commit", allowed)

    def test_prepare_stays_unattended(self) -> None:
        """It writes nothing remote, and making it ask would put the card
        before the preview text exists — which is the one thing the card is
        for."""
        allowed, _ = one(built(allow=("apps_prepare",), integrations=("slack",)))
        self.assertIn("mcp__apps__apps_prepare", allowed)

    def test_names_are_namespaced_or_they_mean_nothing(self) -> None:
        """The SDK ignores an unrecognised name rather than refusing it, so a
        bare `apps_search` in `allow:` would read as an allowance and be none."""
        allowed, _ = one(built(allow=("apps_search",), integrations=("slack",)))
        self.assertEqual(allowed, ["mcp__apps__apps_search"])


class ConnectingFromThePane(unittest.TestCase):
    """Being unconnected is a thing an archetype can fix, which is the whole
    difference between "ask for information and get it" and "ask for
    information and be told to go and configure something"."""

    class Recorder:
        """An `Asker` that answers, and remembers what it was asked."""

        def __init__(self, answer: str) -> None:
            self.answer = answer
            self.prompts: list[str] = []
            self.secrets: list[bool] = []

        async def ask(self, prompt, choices=None, placeholder=None,
                      secret=False):
            self.prompts.append(prompt)
            self.secrets.append(secret)
            return self.answer

    class Broker:
        """A wire that records the call instead of making it."""

        session = 0

        def __init__(self) -> None:
            self.calls: list[dict] = []

        async def call(self, method, params, timeout=60.0):
            self.calls.append(params)
            return {"connected": True, "account": "Acme"}

    def connect(self, providers, answer):
        asker = self.Recorder(answer)
        wire = self.Broker()
        handler = {name: fn for name, _, _, fn
                   in apps.definitions(wire, providers, asker=asker)}["apps_connect"]

        def run(args):
            # Through the envelope, the way the model reads it — asserting on
            # the dict a handler builds would not have caught the bug this
            # whole file now guards.
            return json.loads(asyncio.run(handler(args))["content"][0]["text"])

        return asker, wire, run

    def test_a_token_provider_asks_for_a_token_and_says_where(self) -> None:
        """The card carries the instructions, so nobody has to go and find
        which page of GitHub's settings makes one."""
        asker, wire, connect = self.connect(("github",), "ghp_abc")
        answer = connect({"provider": "github"})

        self.assertTrue(answer["connected"])
        self.assertIn("github.com/settings/tokens", asker.prompts[0])
        self.assertEqual(wire.calls[0]["arguments"]["kind"], "token")
        self.assertEqual(wire.calls[0]["arguments"]["secret"], "ghp_abc")

    def test_google_runs_the_browser_flow_instead(self) -> None:
        """It is the one provider with no personal-token path."""
        asker, wire, connect = self.connect(("google",), "client-id client-secret")
        connect({"provider": "google"})

        self.assertIn("browser", asker.prompts[0])
        self.assertEqual(wire.calls[0]["arguments"]["kind"], "oauth")
        self.assertEqual(wire.calls[0]["arguments"]["client_id"], "client-id")
        self.assertEqual(wire.calls[0]["arguments"]["client_secret"], "client-secret")

    def test_declining_is_an_answer_rather_than_an_error(self) -> None:
        """An empty answer means they said no. Nothing is sent, and the
        archetype gets something it can put in `failed`."""
        _, wire, connect = self.connect(("slack",), "")
        answer = connect({"provider": "slack"})

        self.assertFalse(answer["connected"])
        self.assertEqual(wire.calls, [])

    def test_a_provider_this_pane_does_not_hold_cannot_be_connected(self) -> None:
        """Otherwise `apps_connect` is the way around the provider set: a
        Slack pane could acquire GitHub by asking for it."""
        _, wire, connect = self.connect(("slack",), "token")
        with self.assertRaises(ProseError):
            connect({"provider": "github"})
        self.assertEqual(wire.calls, [])

    def test_the_credential_card_is_marked_secret(self) -> None:
        """It shipped unmarked, and a GitHub token with `repo` scope was
        echoed into a transcript and then into a screenshot. The composer
        masks its input and the transcript keeps dots only when this is set."""
        asker, _, connect = self.connect(("github",), "ghp_abc")
        connect({"provider": "github"})
        self.assertEqual(asker.secrets, [True])

        asker, _, connect = self.connect(("google",), "id secret")
        connect({"provider": "google"})
        self.assertEqual(asker.secrets, [True],
                         "the OAuth card carries a client secret too")

    def test_every_provider_says_how_to_authenticate(self) -> None:
        """A provider missing from the table would raise a KeyError inside the
        handler, which reaches the model as a crash rather than a sentence."""
        for provider in apps.PROVIDERS:
            kind, where = apps.AUTHENTICATION[provider]
            self.assertIn(kind, ("token", "oauth"))
            self.assertTrue(where.strip())


class TheBundledPair(unittest.TestCase):
    """`workflow` and `deployment` spent a while in `reference/`, unreadable by
    `roots()` and written against tools nobody had built. These are the
    properties that were wrong then."""

    def load(self, name: str) -> Archetype:
        from prose_agent import archetypes

        return archetypes.load(name)

    def test_both_are_in_the_catalogue(self) -> None:
        from prose_agent.tools import flavours

        self.assertIn("workflow", flavours())
        self.assertIn("deployment", flavours())

    def test_they_describe_themselves_to_the_parent(self) -> None:
        from prose_agent.tools import catalogue_lines

        described = catalogue_lines()
        self.assertIn("- workflow:", described)
        self.assertIn("- deployment:", described)

    def test_the_providers_are_split_and_do_not_overlap(self) -> None:
        """Two panes rather than one is the whole routing rule: a single pane
        holding all five would be one credential set and one transcript for
        work that has nothing to do with itself."""
        workflow = set(self.load("workflow").integrations)
        deployment = set(self.load("deployment").integrations)
        self.assertEqual(workflow, {"slack", "google", "linear"})
        self.assertEqual(deployment, {"github", "notion"})
        self.assertFalse(workflow & deployment)

    def test_neither_may_spawn(self) -> None:
        """A pane holding a workspace credential that can open panes hands that
        credential's reach to something with no declaration at all."""
        for name in ("workflow", "deployment"):
            self.assertFalse(self.load(name).spawns)

    def test_every_tool_they_name_exists(self) -> None:
        """The regression: both named `prose_handoff_create`, which does not
        exist, and an unrecognised name is ignored rather than refused."""
        from prose_agent.tools import tool_names as prose_names

        for name in ("workflow", "deployment"):
            archetype = self.load(name)
            real = {n.rsplit("__", 1)[-1]
                    for n in apps.tool_names(archetype.integrations)}
            real |= {n.rsplit("__", 1)[-1] for n in prose_names()}
            for named in archetype.allow:
                if named.startswith(("apps_", "prose_", "browser_")):
                    self.assertIn(named, real, f"{name} names a missing tool")

    def test_the_parent_is_told_it_holds_none_of_this(self) -> None:
        """Routing only happens if the parent knows there is no other way."""
        from prose_agent.prompt import SYSTEM

        self.assertIn("HOLD NO SLACK", SYSTEM)
        for named in ("workflow", "deployment"):
            self.assertIn(named, SYSTEM)


if __name__ == "__main__":
    unittest.main()
