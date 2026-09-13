# prose — known issues

Everything outstanding on the agent-facing surface, written for whoever picks it up next.

Each item says **where**, **what is actually wrong**, and **what done looks like** — because the
expensive part of inheriting a list like this is not fixing things, it is working out whether an
item is a real defect, a deliberate choice, or a note someone left in a hurry.

Ordered by what blocks the most work, not by severity.

---

## Already fixed — do not re-hunt these

The branch that added the agent surface found six defects on its way through. They are listed here
only so nobody spends an afternoon rediscovering them; all six are committed, and each has a test.

| | Was | Fixed in |
|---|---|---|
| Containment | **No authorization at all** on `message`, `pane.close`, `pane.focus`, `pane.title`, or `pane.create`'s `from`. Pane ids are small and sequential, so any agent could close any pane in the window by guessing an integer | `daaed33` |
| Addressing | A parent could not address the child it had just spawned — `pane.create` replied with a pane, `message` took a session, and nothing turned one into the other. `hello` also never told an agent its own pane | `daaed33` |
| Handshake | A second connection saying `hello` for a bound session **silently stole it**; the agent that was there stopped receiving `message`/`interrupt`/`closed` with no error anywhere | `daaed33` |
| Backlog | `send` queued JSON-RPC **replies** for a disconnected session. After a reconnect the session is a new process with its own id counter, so a held reply on id 7 lands on whatever it calls request 7 | `daaed33` |
| Spawning | `splitPane` already spawned an agent, so an agent's `pane.create` produced **two processes and two sessions** for one pane, one of them parentless — and `session(for:)` picked between them by dictionary order. This is what made `pane.read` intermittently answer "not your pane" | `daaed33` |
| Packaging | `make-app.sh` never populated `Contents/Resources/agents`, so `AgentProcess`'s bundle lookup was dead code and a bundle moved off the build machine opened every pane on `agent exited (code 2)` | `41f6b9d` |
| Band A | **The harness drew nothing.** It dispatched on `block.type`, which no SDK content block has, so every branch compared `None` to a string | `15d8e28` |
| Turns | A message arriving mid-turn started a second turn on top of the first — two consumers of one stream — and a subagent's question did the same to its parent | `f6156e7` |
| Interrupts | Escape while a permission card was waiting threw a `CancelledError` back into the SDK's control protocol, and drew an internal diagnostic string in the pane | `12ac1be` |

---

## 1. ~~The Agent SDK glue has never been run~~ — it has now

**Where:** `agents/prose_agent/harness.py`, `agents/prose_agent/loop.py`

Closed. `agents/probe_stream.py` ran it against the installed SDK (0.2.152,
Claude Code 2.1.259) and `agents/tests/fake_prose.py` now runs the whole agent
over a real socket with no window. All four things this section said to check
are answered, and three of them were wrong in a way worse than expected:

- **`receive_response()` yields whole blocks *and* partials.** With
  `include_partial_messages=True` a `StreamEvent` carries the raw Anthropic
  stream event, and the whole `AssistantMessage` still follows — *before* that
  block's `content_block_stop`, so arrival order cannot tell them apart. The
  harness streams now and skips what it already drew. A three-sentence reply is
  85 deltas.
- **`_is_skill()` was right.** The SDK really does surface a skill as a tool
  call named `Skill`, which is also why `"Skill"` must be in `allowed_tools` for
  skills to exist at all. What was wrong was the *detail*: `_label`'s key list
  has nothing a skill call carries, so the row drew as a bare `Skill`.
- **`ResultMessage`'s fields were wrong in three ways.** `subtype` never takes
  the value `"failure"` that was being tested for, so every failed turn reported
  success; `is_error` is the reliable signal. `terminal_reason` is `completed` /
  `max_turns` / `aborted_streaming` / `aborted_tools`, never `end_turn`, so the
  old check stamped `stopped` into the header on every *good* turn. And `result`
  is a `str` — there is no `output` field.
- **`options.mcp_servers` and `allowed_tools` were spelled correctly**, but
  `allowed_tools` was only extended when already non-empty, which meant the
  prose tools fell through to permission evaluation.

The one nobody predicted: **the harness emitted nothing at all.** It dispatched
on `block.type`, and no SDK content-block dataclass has a `type` field. Every
branch compared `None` to a string. See `reference/agent-plan.md` for the whole
account.

## 2. Nothing in the UI has been looked at

**Where:** the ask card, the thinking block, the skill ring

`screencapture` returns black frames on this machine — no Screen Recording permission, the same
class of restriction as the Accessibility one `CLAUDE.md` already records. So three pieces of new
UI have unit coverage and no human has seen them:

- an ask card carrying **both** choices and a placeholder, with the composer offering to answer it
- a thinking block: open while streaming, folded to a `Thought` line as the turn ends, and
  expandable again afterwards
- a skill's activity row, drawn as a ring rather than a disc at the same 5pt

`.build/Prose.app` with `PROSE_TRANSCRIPT=demo` exercises all three; `AgentPane.demo()` is where
they come from.

**Done looks like:** spec §5's measured table re-measured after the layout change, per `CLAUDE.md`'s
"measure, don't eyeball" — eyeball comparisons have missed real bugs twice.

---

## 3. ~~There is no page-load event~~ — fixed, but the pilot has blind spots left

**Where:** `Sources/Prose/Panes/BrowserPane.swift`, `Sources/Prose/Host.swift`

**Fixed.** `BrowserSession.loads` counts finished navigations — from `didFinish` and both `didFail`
arms, deliberately not `didCommit`, where the body text is not there yet. `WaitReason.loaded` parks
on it through `pane.read` as `issues §3` asked rather than through a second `browser.wait`, and
`Workspace.satisfied(_:_:BrowserSession)` is level-triggered against the load count the same way its
twin is against the transcript clock. `echo_agent.browse` dropped its forty-iteration poll, so
`EndToEndTests` exercises the new reason over a real socket with a real `WKWebView` on every run,
for no API tokens.

Two related things were fixed with it: `park` answered **`.closed`** for any browser pane, because a
browser pane has no session and the registry guessed with `session(for:)` — a pilot waiting on a
healthy pane was told it was gone. And `pane.read` on a browser pane now answers with the pane's
state (`url`, `title`, `loading`, `failed`) rather than an empty transcript.

**And the ref surface's own holes are closed.** The pilot kept writing DOM traversal scripts after
refs existed, and the cause was mostly capability rather than prompt: an agent that cannot do a
thing through a tool does it through a script, and it is right to. `browser_find` searches a page
whose element list truncates (Michael Bublé's article lists 1,100-odd controls against a default
limit of 200, so the link you want is essentially never in the list); `browser_select` works a
`<select>`, which no click can open because its menu belongs to the platform; `browser_key` sends
Escape, Tab and the arrows; `browser_scroll` takes `by` and moves the box an element actually
scrolls in rather than the window behind it; `browser_back`/`browser_forward` replace
`history.back()` in an eval; `PageScript.gather` descends into open shadow roots, which
`querySelectorAll` will not; and `browser_elements(wait_for:)` waits **in the page**, on a
`MutationObserver`, for a change that is not a navigation — the case that previously left polling
as the only option. Every `browser_eval` is now logged to stderr and, with `PROSE_LOG_DIR` set, to
`browser-eval.jsonl`, so the next missing tool shows up as data rather than as a hunch.

`Tests/ProseTests/EndToEndTests.swift` gained `theBrowserPilotWalks`, off unless
`PROSE_BROWSER_E2E=1`, which runs the real pilot at a real errand and records every line it sends.
It asserts almost nothing on purpose: what it is for is the eval log.

**The pilot can now see the console and the network**, which was this section's next item and
the one thing that separated "this site is broken" from "my selector is wrong". Both are
collected in the page by `PageMonitor`'s script, injected at document start so a throw during
startup is not missed, and both come back through `browser_console` / `browser_network` as
cursor-based reads that cost no round trip into the page — the entries are already on prose's
side by the time an agent asks. `console.*`, uncaught errors, unhandled rejections and failed
subresources come from the page; the **main document's status code** comes from
`decidePolicyFor navigationResponse`, because a 404 or a 500 renders like any other page and is
the one thing the page cannot report about itself.

One trap worth keeping: **JavaScriptCore's `Error.stack` is frames only.** Unlike V8's it does
not repeat the message, so `stack || name + ": " + message` silently threw away the only part of
an error anybody reads. Its test caught it before it landed; the next person writing injected JS
here should assume nothing about JSC matching V8.

**What is still missing, in the order it will bite:**

- **`browser_snapshot` captures the viewport only.** `browser_scroll` makes that navigable rather
  than fixed, but there is still no full-page capture.
- **No file uploads, no downloads, no dialogs an agent can answer.** A page that opens a file
  picker stops the pilot dead.
- **Refs are main-frame only.** `WKUserScript` is injected with `forMainFrameOnly: true`, so
  anything inside an iframe — a payment field, an embedded editor — is invisible to
  `browser_elements`. Widening it means deciding what a cross-origin frame is allowed to report.
  Now the *only* remaining place refs cannot see, since shadow roots are walked.
- **`wait_for` matches the page's text, not its elements.** It is `innerText.includes`, so waiting
  for a control that carries no text — an icon button, an empty field — has to wait for quiescence
  instead. Matching element names as well would cost a scan per mutation, which is why it does not
  yet.

---

## 4. ~~A page cannot post anything back~~ — it can, through one narrow door

**Where:** `Sources/Prose/Support/PageMonitor.swift`; spec §13.1

**Built**, because §3's console and network needed it. The security requirement was the whole
design, as this section said, and the answer was to make forgery *impossible* rather than
forbidden:

- The handler's only output is a `PageLog` entry. It holds no session, no registry and no
  transcript, and there is no path from a `PageLog` into `HostEvent` — the page's words can only
  ever come back as the answer to a `browser.console` or `browser.network` call an agent made on
  purpose. Nothing a page posts reaches a transcript, so there is nothing to tag.
- Every field is re-read and re-typed on prose's side: a level from a fixed set, a string clamped
  to 400 characters, integers. Nothing is forwarded as it arrived.
- An unrecognised `kind` is dropped. `BrowserPaneTests`' "a page cannot post anything prose would
  treat as an agent" posts a `turn`, an `event` and a `status` from a real page and asserts that
  exactly one message — the `console` one — survives.

**What this does not yet do** is give a page a legitimate way to talk to its agent, which is what
spec §13.1 is actually about. That still wants a design: a page-originated message that is
*meant* to reach an agent needs a shape that stays distinguishable from the agent's own output
all the way into the transcript. The channel built here is deliberately the narrow version — a
diagnostic pipe, not a bus.

---

## 5. `prose-ctl` cannot attach to a running agent

**Where:** `agents/prose_agent/cli.py`, `Sources/ProseHost/SessionRegistry.swift` (the hello guard)

A consequence of fixing the connection steal, and the right trade for now: prose refuses a second
`hello` for a session that already has a connection, so `prose-ctl` works against a pane whose agent
has exited or a session a script reserved — not for looking over a live agent's shoulder, which is
most of what a debugging CLI is for.

**Done looks like:** replies routed **per connection** rather than per session. `SessionRegistry.send`
routes by session today, and request ids are only unique per connection, so a secondary read-only
connection needs its answers tracked against the connection that asked. The hello guard's comment
already names this as the piece to build when a second front door earns its place.

---

## 6. One session per pane is assumed, not enforced

**Where:** `Sources/ProseHost/SessionRegistry.swift:143-145`

```swift
public func session(for pane: PaneID) -> SessionID? {
    sessions.first { $0.value.pane == pane }?.key
}
```

`sessions` is a dictionary, so `first` is **arbitrary** if two sessions ever name the same pane. The
bug that made this bite is fixed (see the table above), but nothing stops it recurring, and the
failure mode is horrible: authorization silently resolving to the wrong session, intermittently,
under load. It is also a linear scan on a path that every pane-addressed call takes.

**Done looks like:** a `[PaneID: SessionID]` index maintained beside `sessions`, so the invariant is
structural rather than a thing to remember. Failing that, an assertion in `reserve` that the pane is
not already claimed.

---

## 7. Smaller things, none of them urgent

- **`tools.py` builds a fake wire to list tool names.** `tool_names()` instantiates `_Unbound` — a
  stand-in with methods that raise — purely so it can enumerate `definitions()` without a
  connection. It works and it is ugly. Splitting the name/schema table from the handlers would make
  it unnecessary.
- **One escalation timer per question, never cancelled.** `Workspace.escalate(_:after:)` in
  `Sources/Prose/Host.swift` starts a `Task` per supervised ask and lets it fire into a no-op if the
  question was already answered. That is what makes it safe, and it means a pane asking many
  questions accumulates sleeping tasks for the length of the grace. Harmless; worth knowing.
- **`Palette.thinkingLabel` and `Palette.activityDetail` are the same value** (`0x7A7A82`). Either
  the thinking disclosure should share the activity-detail token outright, or it should be its own
  colour and differ. Two names for one number is the state that rots.
- **`README.md`, `CLAUDE.md` and `Workspace.swift`'s header were all describing a repo that no
  longer existed** and have been corrected. Worth re-reading them before trusting any other prose in
  the tree that has not been touched recently.
- **An ask cannot be withdrawn.** Escape while a card is waiting abandons the agent's side, but
  nothing on the wire takes the card out of the transcript, so it sits there unanswered. Cosmetic
  rather than a hang: `Wire._dispatch` already drops a reply nobody is waiting for. The fix is an
  `ask.cancel` method, or a `withdrawn` state on the block.
- **A Finder launch has cwd `/` and no inherited environment.** `open Prose.app` gets launchd's
  environment, not your shell's, so an exported `ANTHROPIC_API_KEY` never arrives;
  `~/.config/prose/env` exists for that. `pane_agent.workspace()` handles the `/`.
- **The bundle carries no Python interpreter.** `make-app.sh` excludes `agents/.venv` — it is
  several hundred megabytes, its `bin/python3` symlinks into a framework, and its `pyvenv.cfg` holds
  an absolute path. So a bundle moved to another machine needs `Scripts/setup-agents.sh` run there.
  Belongs with plan §11's notarisation decision.
- **A link in a transcript opens the system browser.** `Text` renders the link attribute and
  SwiftUI's default `openURL` sends it to Safari — from an app whose other pane kind *is* a
  browser. Routing a click into a new browser pane, or into the focused one, is a small
  `environment(\.openURL)` override and an obvious follow-up. Nobody has decided which it should be.
- **The code-span wash has never been seen.** An inline span takes `code_bg` (black at 25%) drawn
  tight to the glyphs, with none of the block's 8pt padding or hairline border, so it may read as
  too faint or too tight at 13pt. It shares the block's token deliberately — one way for code to
  look — but it is the sort of thing that only a human looking at it can settle, and §2 applies.
- **The SDK skips a missing plugin path in silence.** `Harness` reads the `init` message and puts
  the skill count in the pane header, which detects it, but nothing prevents it.

---

## 8. Decisions still open

Plan §11 listed seven. Four are answered (macOS 15, per-block transcript selection, the browser pane
getting its own protocol methods — yes, and the markdown decision, split: inline emphasis renders,
structure does not). Three remain, and all three are the user's:

- Is Linux formally dropped?
- **Is distribution unsandboxed and notarised — and what does the agent authenticate with?**
  These are now one question rather than two. Nothing on this machine holds an API key: no
  `ANTHROPIC_API_KEY`, no `~/.claude/.credentials.json`, no `~/.config/anthropic`. The SDK's
  bundled `claude` binary resolves credentials the way the CLI does and finds a **Claude Code
  subscription login in the macOS Keychain** (service `Claude Code-credentials`). The `init`
  message says `apiKeySource: "none"` and a `RateLimitEvent` reports five-hour and seven-day
  subscription windows, so every turn any pane takes is spending a subscription, not API credit.

  That is fine for prose as one person's own tool. It is **not** fine for a distributed one: the
  Agent SDK's terms say Anthropic "does not allow third party developers to offer claude.ai login
  or rate limits for their products, including agents built on the Claude Agent SDK", and directs
  them to API keys instead. So the day prose ships to anyone else, the agent has to take a key.

  `agents/prose_agent/credentials.py` is already that path — `ANTHROPIC_API_KEY` beats the CLI
  login in the SDK's resolution order, and `~/.config/prose/env` is where a bundled app launched
  from Finder can find one. What is missing is the decision, and the thing a first-run prose would
  have to say to somebody who has neither.
- Plan §11's nearness option, (1) or (2)?
