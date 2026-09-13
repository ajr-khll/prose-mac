# prose's pane agent — a multi-purpose personal agent on the Claude Agent SDK

**The plan for the work in progress.** The other four reference documents describe what prose *is*;
this one describes what is being built right now and why each call was made. It is meant to be edited
as the work teaches us things — when a step lands, say what actually happened rather than deleting
the step.

## Context

`prose-swift` is done through plan §10 step 6. The window, tiling, both pane kinds, the socket, the
handshake and the whole agent-facing protocol exist and their tests pass. What does not exist is an
agent that thinks. Every pane runs `agents/echo_agent.py`, which fakes a turn.

The client meant to replace it — `agents/prose_agent/` — is written but has **never been executed
against an installed SDK** (`issues §1`). Its lower three modules (`wire`, `events`, `tools`) are
stdlib-only and exercised end to end through the echo agent, so the transport is real. Its two
SDK-facing modules (`harness.py`, `loop.py`) are a first draft written from documentation, and
**nothing anywhere calls `run()`**.

### What this agent is for

**A multi-purpose personal agent, not a coding agent.** It lives in a pane and does personal
management: research, correspondence, reading and keeping notes, tracking things, driving a browser,
and — the thing prose is actually shaped around — spawning and supervising other panes.

Coding is a *thing it can be asked to do*, not what it is. When you want a Claude Code instance, the
right answer is a **skill** that spawns a pane with a coding-flavoured agent in it — visible,
watchable, supervisable — not a coding identity baked into every pane. §5 builds the structure that
makes that, and everything like it, a directory of Markdown rather than a code change.

**Scope for this pass**: make it run, make it stream, give it a modular skill surface, and route
permission prompts to prose's ask card. The browser page-load wait (`issues §3`) is deferred; §11
says why it's the obvious next one.

---

## What is already true — do not rebuild

| | Where | State |
|---|---|---|
| Socket, handshake, containment, parked reads | `Sources/ProseHost/SessionRegistry.swift` | Works, tested |
| Every wire method incl. `pane.read`, `browser.*` | `Sources/ProseCore/Protocol.swift` | Works, tested |
| Level-triggered wait | `Workspace.satisfied(_:_:)` in `Sources/Prose/Host.swift` | Works, 7 unit tests |
| Transport + single-reader demux | `agents/prose_agent/wire.py` | Works |
| Band A emitters | `agents/prose_agent/events.py` | Works |
| 14 band-B tools + in-process MCP server | `agents/prose_agent/tools.py` | Written, never run via SDK |

SDK facts verified today that the draft was written without:

- `claude-agent-sdk` 0.2.152, `requires-python >=3.10`. The macOS arm64 wheel is tagged `py3-none`
  and is **86 MB because it bundles a native Claude Code binary** — no npm install needed.
- `ANTHROPIC_API_KEY` is not set here, and the SDK does not read `.env` files.
- `ResultMessage`: `subtype: "success"|"error"|"user_cancelled"|"timeout"`, `terminal_reason`,
  `result: dict|None`, `output: str|None`, `exit_code`.
- `allowed_tools` **auto-approves**; it does not restrict. An unlisted tool falls through to
  permission evaluation.
- `include_partial_messages=True` yields `StreamEvent(subtype="delta"|"ping")`.
- `can_use_tool(name, input, context) -> PermissionResultAllow | PermissionResultDeny`, fired only
  when permission evaluation actually reaches a prompt.
- The skill tool is literally named `Skill` — `harness._is_skill`'s guess is **correct**, and one of
  `issues §1`'s four worries is already closed.
- `setting_sources` defaults to `None`: **nothing** loads from `.claude/`.
- `plugins=[{"type":"local","path":…}]` loads skills, agents, hooks and MCP servers from an arbitrary
  directory. `skills` takes `"all"`, a list of names, or `[]`. A `SystemMessage` with
  `subtype == "init"` reports what actually loaded.

---

## Where this got to

Steps 1 through 8 are committed and both suites are green — 253 Swift tests and
63 Python ones, the latter running under the system interpreter with no SDK
installed, which is the layering property `prose_agent/__init__.py` claims.

The agent runs. `agents/tests/fake_prose.py` drives `pane_agent.py` over a real
socket with no window: it says hello, streams a reply 85 deltas at a time,
resolves its tool rows in place, and reports model, cost and tokens into the
pane header. That is the first time anything in `agents/prose_agent/` has been
executed at all.

Four things came out differently from the plan above, and the plan is left
standing rather than edited so the difference is visible.

**The skill scope is narrower.** `setting_sources=["user", "project"]` loaded
**85** skills — every one in `~/.claude/skills`, almost all of them written for
a coding terminal, each costing its description on every turn of every pane. It
is now `["project"]` alone: 17, of which 15 are Claude Code's own bundled skills
and cannot be excluded from there. Personal skills reach a pane by living in
`agents/skills/skills/` or by `$PROSE_PLUGINS`, and `agents/skills/README.md`
says so. Adding `"user"` back is one word, in `pane_agent.py`.

**Naming a tool in the prompt is not the same as telling the model to use it.**
Asked to "ask me a question", the agent wrote the question as prose — twice,
until it was told outright that a question UI existed. `prose_ask` *was* in the
prompt, but as a capability in the middle of a paragraph about subagents, and
from the model's side writing a question works: the person types back. Nothing
said why the card is better. It is now its own paragraph, early, stated as a
rule with its reason — a question in prose does not end the turn, does not wait,
and gives them nothing to press — and the same naive prompt now reaches for the
card first try, while a plain request still gets a plain answer. Both checked by
running it, because a prompt change is a behaviour change and neither reading it
nor reasoning about it is evidence.

**The system prompt is ~1,300 tokens, not the 700–900 budgeted.** Still a
fraction of the preset it replaces, and the sections it spends the extra on —
the supervision loop and the read costs — are the two the guide says an agent
gets wrong by default. Worth re-reading once there is evidence from a real pane.

**Credentials were never the blocker.** The SDK's bundled binary uses an
existing `claude login` and reports `apiKeySource: "none"`, so the first run
worked with an empty environment. `credentials.py` is still there, because
`~/.config/prose/env` is what makes a key usable when there is no CLI login, and
because a Finder launch inherits launchd's environment rather than a shell's.

**The SDK warns about the permission design, correctly.** A tool named in
`allowed_tools` is auto-approved before `can_use_tool` is consulted — which is
exactly the point, since `allowed_tools` is the list of calls that should not
raise a card. `loop._quiet` silences that one warning, with the reasoning
written down, rather than letting twenty tool names onto stderr at every pane
open and teaching whoever reads a log to ignore it.

### Risk 3 is closed, and it found two bugs

A card waiting for an answer does **not** stall the SDK's client. `fake_prose.py
--ask interrupt` leaves a permission question outstanding and presses Escape:
the interrupt lands, the turn ends `aborted_tools`, and the file the model
wanted to write is not written. So the fallback the plan held in reserve — a
short deadline and re-asking through `prose_ask` — is not needed.

Running it is what found the two things wrong in that path. `abandon` cancelled
the waiting future, so the ask came out as a `CancelledError` that
`Permissions.decide` does not catch and that went back into the SDK's control
protocol as an exception; a withdrawn question is a refusal now. And an
interrupt during a tool call returns `is_error` **and** a `result` holding
`[ede_diagnostic] result_type=user last_content_type=n/a stop_reason=tool_use`,
which is what the pane drew at somebody who had just pressed Escape. An abort is
checked before the error flag now, and a `result` that is a bracketed tag and a
run of key=value pairs is dropped.

### The live test exists and is off by default

`EndToEndTests.theRealAgentRunsATurn`, gated on `PROSE_SDK_E2E=1`. It runs the
real agent in a real pane and asserts only what is stable: that something was
said, that the turn ended, that `status["model"]` and `status["skills"]` are
non-empty, and that no notice was left behind. The skill count is the load-
bearing one — nothing on the echo path can produce it, so it proves the whole
round trip from the SDK's `init` message through `Events`, the socket,
`parseEvent` and the reducer to a drawable header field. It passes in about
three seconds.

### Still owed

**Nothing has been looked at by a human.** `issues §2` is still open, and the
ask card, the thinking block and the skill ring now finally have something real
to draw. Step 9 lists what to try. Everything else in this pass is either done
or was deliberately deferred to Step 10.

---

## What the probe found — read this before Step 3

`agents/probe_stream.py` has been run against the installed SDK (0.2.152, Claude Code 2.1.259), and
the SDK's own `types.py` read. **Most of what this plan assumed about the SDK was wrong**, and one
of the corrections is much worse than a defect.

### The harness emits nothing at all

Not "subtly wrong" — dead. **No content-block dataclass has a `type` field:**

```python
@dataclass
class TextBlock:      text: str
@dataclass
class ThinkingBlock:  thinking: str; signature: str
@dataclass
class ToolUseBlock:   id: str; name: str; input: dict
@dataclass
class ToolResultBlock: tool_use_id: str; content: str | list[dict] | None; is_error: bool | None
```

`harness._observe_block` opens with `kind = getattr(block, "type", None)` and then compares `kind`
against `"thinking"`, `"text"`, `"tool_use"`, `"tool_result"`. Every one of those is `None`, so every
branch is skipped and **not one event is ever emitted**. A pane running this agent would have shown a
turn starting, a turn ending, and nothing in between.

Dispatch on `type(block).__name__` instead, with an attribute fallback. That is still duck typing —
no SDK import, unknown classes ignored — and it is the property `harness.py`'s docstring claims.

### Every `ResultMessage` assumption was wrong

Real fields: `subtype`, `duration_ms`, `duration_api_ms`, **`is_error: bool`**, `num_turns`,
`session_id`, `stop_reason`, `total_cost_usd`, `usage`, **`result: str | None`**, `structured_output`,
`model_usage`, `permission_denials`, `errors: list[str]`, `api_error_status`, `uuid`,
`terminal_reason`, `origin`.

- `result` **is** a `str`. Defect 2 as written was wrong: there is no `output` field at all.
- `subtype` is an untyped `str`. **`is_error: bool` is the reliable signal** — use it, not a
  subtype string set, and take the message from `errors` / `result`.
- `terminal_reason`'s real values are `"completed"`, `"max_turns"`, `"aborted_streaming"`,
  `"aborted_tools"` — **not** `"end_turn"`. The existing `reason != "end_turn"` check would have
  stamped `stopped: completed` into the pane header on every single successful turn.
- `total_cost_usd` and `usage` are real, always-present fields, not "if present" guesses.

### `StreamEvent` is exactly the raw SSE event

`StreamEvent(uuid, session_id, event: dict, parent_tool_use_id)` where `event` is the raw Anthropic
stream event. The expected mapping holds verbatim: `message_start`, `content_block_start` (with
`index` and `content_block`), `content_block_delta` (`text_delta` / `thinking_delta` /
`input_json_delta`), `content_block_stop`, `message_delta`, `message_stop`.

**The whole `AssistantMessage` does still arrive** — and it arrives *before* that block's
`content_block_stop`, not after. So the skip-what-was-streamed logic is needed, and it cannot key on
"the message came last".

### Auth already works, with no key

The run succeeded with `ANTHROPIC_API_KEY` unset and `apiKeySource: "none"` — the bundled binary used
this machine's existing Claude Code credentials, and a `RateLimitEvent` reported the subscription's
five-hour window at 36%. So §2's file fallback is a convenience, not the critical path. It still gets
built, because `~/.config/prose/env` is what makes a key usable at all when there is no CLI login.

### Message types nobody documented

`HookEventMessage`, `RateLimitEvent`, `TaskStartedMessage`, and `SystemMessage(subtype="status")` all
arrive on `receive_response()`. Eight `HookEventMessage`s land before anything else. The harness must
ignore what it does not know **by default**, not by enumeration.

`ServerToolUseBlock` / `ServerToolResultBlock` are real and separate from `ToolUseBlock` — that is how
`web_search` and `web_fetch` arrive. They get `category:"search"`, which `spec §10` already lists.

### The markdown bet is confirmed as a real risk

The probe's reply contained `**` and a backtick span in the first sentence. §4.2's rule 2 has
something to beat.

**Resolved by splitting the bet, not by winning it.** The model reaches for inline emphasis in the
first sentence of nearly every reply, and a prompt rule fighting that spends tokens on every turn to
make the output worse. So prose now renders inline emphasis and still renders no structure
(`spec §9.3`); rule 2 only has to hold the line on headings, bullets, tables and fences, which the
model reaches for far less often and which the attachment path already answers. Two traps came out
of running the parser: a fence parses *worse* than it renders literally, and `__init__.py` is legal
strong emphasis.

---

## Step 1 — Packaging, hygiene, and an interpreter prose can find

Free, and verifiable on its own.

**`.gitignore`** gains a Python section (`__pycache__/`, `*.py[cod]`, `.venv/`). The seven committed
`agents/prose_agent/__pycache__/*.pyc` come out with `git rm -r --cached`. They went in because the
file had no Python section at all; `make-app.sh` already strips them from the bundle, which is the
tell that they were never meant to be tracked.

**`agents/pyproject.toml`** (new) declares the package and pins `claude-agent-sdk>=0.2.152`. One
source of truth for the dependency.

**`Scripts/setup-agents.sh`** (new, ~15 lines) creates `agents/.venv` and `pip install -e ./agents`,
then prints the installed SDK version — that print is the step's whole acceptance test. **It prefers
`python3.13` and falls back to `python3` (3.14.2 here):** 3.14 is nominally fine, but `mcp`/`anyio`
wheel availability on a just-released Python is exactly the thing that fails at the worst moment, and
`/opt/homebrew/bin/python3.13` exists on this machine.

**`Sources/ProseHost/AgentProcess.swift`** — `echoAgentPath` already implements the search ladder
(beside the binary → `../Resources/agents` → up to six levels towards a checkout). Generalise it to
`resolveAgentFile(_ relative: String) -> String?` and add `interpreter` =
`resolveAgentFile(".venv/bin/python3")` if found, else `"python3"`. The venv is the only place the
SDK exists; a bare `python3` would `ModuleNotFoundError` on import and every pane would open on
`agent exited (code 1)`. Note in the doc comment that `PROSE_AGENT` splits on spaces, so no path in
it may contain one.

**`Scripts/make-app.sh`** — `cp -R "$ROOT/agents"` would copy a several-hundred-megabyte `.venv`
whose `bin/python3` is a symlink into a framework that won't exist elsewhere. Replace the `cp -R` +
`find` pair with `rsync -a --exclude .venv --exclude __pycache__`. The bundle then ships the scripts
and the skills and no interpreter, and the search ladder finds the checkout's venv on this machine. A
relocatable, SDK-bearing bundle is a distribution question that belongs with plan §11's notarisation
decision — say so in the script's comment rather than leaving someone to find out.

---

## Step 2 — Credentials, and a pane that explains itself

`AgentProcess.init` copies `ProcessInfo.processInfo.environment` wholesale and overlays `PROSE_*`, so
the agent gets whatever prose itself was launched with. Two consequences worth stating plainly:

- **Finder does not give you your shell.** `open .build/Prose.app` inherits launchd's environment, so
  `export ANTHROPIC_API_KEY` in `~/.zshrc` never reaches the agent. Launching
  `.build/Prose.app/Contents/MacOS/prose` from a terminal does — and that is still "as a bundle" for
  `CLAUDE.md`'s purposes, because `WKWebView` wants the bundle identifier from the neighbouring
  `Info.plist`, not a particular launch path.
- **Do not use `launchctl setenv`.** That puts the key in every process on the machine until reboot.

**`agents/prose_agent/credentials.py`** (new, stdlib only, ~30 lines) — `load()` puts
`ANTHROPIC_API_KEY` in the environment if it is not already there, never overwriting:

1. Already set → return.
2. `~/.config/prose/env`, `KEY=value` lines with `#` comments. Refused with a stderr warning if the
   file is group- or world-readable — the same standard the socket directory already holds itself to
   (`spec §11`, mode 0700).
3. Nothing → leave it unset.

`CLAUDE_CODE_USE_BEDROCK` / `_VERTEX` / `_FOUNDRY` pass through untouched, being read from the same
environment.

**Failure must be loud.** `serve()` catches the SDK's authentication error and emits
`events.turn_ended("no credentials — set ANTHROPIC_API_KEY, or put it in ~/.config/prose/env")`. An
empty pane that never says why is the worst outcome available and it is one `except` away.

*(Untested possibility: the SDK's bundled binary may pick up this machine's existing Claude Code
login with no key at all. The SDK docs say third-party products shouldn't rely on claude.ai login, so
this is not the design — but if the first probe run just works with an empty environment, that is
why. Record it; don't build on it.)*

---

## Step 3 — The four harness fixes, the mailbox, and Python tests

All free and testable against fake objects, so it happens before anything touches the SDK.

### 3.1 `harness.py` — four confirmed defects

1. **`harness.py:42` tests `subtype == "failure"`; the real value is `"error"`.** Every failed turn
   currently reports success. Match the set `{"error", "user_cancelled", "timeout"}` rather than
   `!= "success"`, so a subtype added later degrades to "the turn ended" rather than "it failed".
2. **`harness.py:43` assigns `ResultMessage.result` — a `dict` — where a string is required.**
   `events.turn_ended` puts it into `error=`, and `parseEvent` reads `event["error"]?.string`, so a
   non-string there means the notice **silently vanishes**. Prefer `output`, then `terminal_reason`,
   then a literal, and coerce with `str()` at the end.
3. **`harness.py:79` passes the result summary as `label`.** I read both sides. `upsertActivity`
   keeps `detail ?? existing` and `category ?? existing` but writes `label` through unconditionally —
   and `Event.activity`'s `label` is a non-optional `String`, so `parseEvent` **drops an activity
   that has no label at all**. So the row's label cannot be preserved by omission; it must be
   resent. `Harness` keeps `self._labels: dict[str, str]` keyed by `tool_use` id, and the resolving
   update sends the remembered label with `detail=_summarise(...) or None` — `or None`, not
   `or "done"`, because omitting the detail *does* preserve what was there.
   (The Swift alternative — making `label` optional through `Event`, `Block`, `TranscriptRead.encode`
   and `TranscriptView` — is far wider for no extra benefit. Don't.)
4. **`_is_skill` needs no change.** The SDK's skill tool really is named `Skill`. Replace the "this
   is a guess" comment with the citation and strike the item from `known-issues.md`.

**One more, found while writing §5:** `_label`'s key list is
`("command","pattern","file_path","path","url","query","prompt")`, none of which a `Skill` call
carries — so a skill row would draw as a bare `Skill` with no detail, when `guide §4`'s table
promises `label:"Skill", detail:<name>`. Special-case it: for a skill, label is `"Skill"` and detail
is the skill's name from the input. That is the row that draws as a **ring rather than a disc**, and
it is currently the only UI in prose with nothing to drive it.

### 3.2 `loop.py` — three more, found while reading

5. **`allowed_tools` is only extended when already non-empty** (`loop.py:33`). Since it auto-approves,
   an unlisted `mcp__prose__prose_wait` falls through to permission evaluation — which with a
   `can_use_tool` installed becomes an ask card asking your permission for `prose_wait`, and without
   one is a hang. Make it unconditional.
6. **A new message starts a second turn on top of a live one.** `message`/`child.result`/`child.ask`
   all `await client.interrupt()` then `create_task(run(text))` without awaiting the old task, which
   is still inside `async for … receive_response()`. Two consumers of one stream, two `query()` calls
   on `session_id="default"`, `turn_ended` firing twice.
7. **A child's question destroys the parent's turn.** Same path: `child.ask` interrupts the parent
   mid-work to deliver something `prose_wait(until=["ask"])` was already going to deliver. That is
   `guide §6` inverted.

Fix 6 and 7 together with a **mailbox**: a notification appends to `pending` and starts a pump task
only if one is not already running; the pump joins queued prompts and runs them one at a time.

> **The rule this encodes: a message queues, Escape interrupts.** prose already gives the user a
> dedicated interrupt. Treating a second message as an implicit interrupt means you cannot tell a
> supervisor two things without losing the first.

Note `interrupt()` does not drain — the existing `async for … receive_response()` inside the running
task *is* the drain, iterating to the `ResultMessage` with `subtype == "user_cancelled"`. So on
interrupt the task must be left to finish, not cancelled. Keep the `CancelledError` handler for
shutdown; stop cancelling on interrupt.

### 3.3 Streaming — probe before mapping

`harness.py` emits whole blocks, so a reply lands in one lump and prose's 16 ms coalescing is
exercised only by `echo_agent.respond()`'s artificial word-at-a-time loop. A real agent that draws
worse than the echo agent is an absurd outcome, so this is worth doing properly.

**The `StreamEvent` payload shape is not documented well enough to write against, and a wrong guess
draws nothing, silently** — the most expensive failure mode available. So `agents/probe_stream.py`
(new, ~30 lines, one throwaway query) runs with `include_partial_messages=True` and prints
`type(m).__name__` and `vars(m)` for every message. **Run it, paste its output into the commit
message, then write the mapping.** It answers every open question in `issues §1` at once: whether
partials arrive at all, what the payload attribute is called, whether whole `AssistantMessage`s still
follow, what `ResultMessage` actually carries, and what the `init` message's `skills` list looks like
(§5.4).

Expected mapping, to be confirmed: `content_block_start` for `text`/`thinking` → `events.message` /
`events.thinking`; `content_block_delta` → `events.delta`; `content_block_stop` → `events.end`;
`tool_use` taken only from the whole block, never from deltas, because its input arrives as partial
JSON and cannot produce a label; `ping` ignored.

**The hazard is double emission** — the complete `AssistantMessage` arrives after its deltas.
`Harness` records streamed content-block indices in `self._streamed` and `observe` skips those
blocks. If the probe shows the SSE index and the position in `AssistantMessage.content` don't line
up, key on `(type, position)` and say so in the comment. If it shows whole messages *don't* follow,
tool inputs must be reassembled from `input_json_delta` — a real cost, and an argument for
`include_partial_messages=False`. **Make that call from the probe output, not from reasoning.**

### 3.4 Status, and the init message

Band A promises `status {fields:{model, cost, …}}` and nothing on the SDK path emits it. Add
defensively, all via `getattr`, all skipped when absent: `model` once per turn from
`AssistantMessage`; `cost`/`tokens` from `ResultMessage` (`total_cost_usd`, `usage`) if present;
`stopped` from `terminal_reason != "end_turn"`, which is already there.

**`observe` must also learn about `SystemMessage`**, which it ignores entirely today. The one with
`subtype == "init"` carries `skills`, `slash_commands` and `plugins` — see §5.4. That is the only
in-band evidence that the skill structure loaded, and it costs nothing to surface.

### 3.5 Python tests — `agents/tests/`, plain `unittest`

No Python test infrastructure exists and this work needs some. Dependency-free:
`python3 -m unittest discover -s agents/tests`.

- `test_harness.py` — fake blocks via `SimpleNamespace`, a `FakeWire` recording `event()` calls. A
  failed result emits `turn {state:"failed"}` with a **string**; `tool_result` resends the original
  label and sets `detail`; a streamed block produces `message.start` + N `delta` + one `message.end`
  and the trailing whole message adds nothing; `Skill` gets `category:"skill"`, `label:"Skill"` and
  the skill's name as `detail`.
- `test_tools.py` — `tool_names()` spells `mcp__prose__prose_wait`; every schema is `type: object`;
  `prose_focus` notifies rather than calls (§9); `prose_spawn`'s `flavour` resolves through the table
  and **refuses an unknown name** rather than passing it through.
- `test_skills.py` — §5.6.
- `test_permissions.py` — §6's decision table against a fake asker.
- `test_import.py` — `import prose_agent` succeeds with `claude_agent_sdk` unimportable. This is the
  layering property `__init__.py`'s docstring claims and nothing currently checks; the SDK imports
  are function-local in `loop.serve` and `tools.mcp_server` and it would be easy to break.

---

## Step 4 — The agent itself

### 4.1 `agents/pane_agent.py` — what `PROSE_AGENT` and `defaultCommand` name

```python
#!/usr/bin/env python3
"""The agent that runs in a prose pane."""
import os, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))   # as echo_agent.py does

from claude_agent_sdk import ClaudeAgentOptions
from prose_agent import credentials, run, skills
from prose_agent.prompt import SYSTEM

credentials.load()
run(ClaudeAgentOptions(system_prompt=SYSTEM, plugins=skills.plugins(), ...), name="claude")
```

### 4.2 The system prompt is **bespoke**, not the `claude_code` preset

The preset is wrong for this agent in ways that are structural, not stylistic, and an `append` does
not reliably beat a long confident preamble — it only makes the prompt longer and the conflict
subtler.

| The preset assumes | prose is |
|---|---|
| "an interactive CLI tool that helps users with software engineering tasks" | a multi-purpose personal agent; coding is one errand among many |
| a terminal rendering all of markdown | a transcript of paragraph blocks: inline emphasis renders, structure does not. **A fence renders as literal backticks** (`spec §9.3`); code is an `attachment` |
| terse, minimal output, no preamble | something a person reads in a pane beside other panes |
| its own narration and progress conventions | band A: thinking, tool rows and skill loads are already drawn from the stream at zero tokens, and narrating them is `guide §11`'s first anti-pattern |

It is also thousands of tokens on every turn of every pane, for an identity we then spend our own
tokens contradicting.

**`agents/prose_agent/prompt.py`** holds `SYSTEM` as a module-level string — greppable, diffable,
unit-testable, and importable by a second agent flavour (§5.5). Written as prose in the house style,
covering, in order:

1. **Who you are.** A personal agent working for one person, in one pane of prose. Broad remit:
   research, correspondence, notes, tracking, browsing, and running other panes.
2. **Where your words go.** Paragraphs in a transcript. **No markdown structure** — no headings,
   bullets, tables or fences; they render as literal characters. Inline `**bold**`, `*italics*` and
   backtick spans do render, and `_underscores_` deliberately do not. Code and long quoted material
   go out as an attachment, which the harness emits for you.
3. **You do not narrate.** Thinking, tool calls and skill loads are already on screen. Never write
   "Let me check that" — the row is already drawn.
4. **Supervising a pane**, with `guide §6`'s loop quoted verbatim: `prose_spawn` →
   `prose_wait(since=cursor)`, cursor threaded and never reset, `prose_read(block=…)` only inside a
   branch a summary justified, never a sleep and never a poll.
5. **What reading costs** (`guide §7`): summary is 16× cheaper; thinking summarises to a bare count;
   `truncated` means narrow with `kinds`/`match`/`limit`, not retry.
6. **Asking** (`guide §8`, §11): one question outstanding at a time; answer your child's question
   yourself when you know the answer; escalate when it is genuinely the human's call, not by default.
   Plus §6.3's permission caveat.
7. **Browsing** (`guide §9`): `browser_text` first, `browser_eval` when text won't carry it,
   `browser_snapshot` only when *appearance* is the question — with the token costs stated.
8. **Your skills** — one paragraph, §5.5.
9. **`prose_result` before you finish**, if you were spawned.

Budget: roughly 700–900 tokens. If a real pane still fills with backticks after this, that is
evidence to act on — not a reason to reach back for the preset, but a reason to sharpen rule 2. Say
so in the module docstring so whoever sees backticks knows what to do.

**One paragraph is appended at runtime by `serve()`**, after `hello`, because only it knows the
answer: *"Your pane is N and your session is N. Tools that take a `pane` take that number, or one
`prose_spawn` or `browser_open` handed you."* Three lines that remove a whole class of "not your
pane" errors and a wasted tool call to discover your own id. `_append_to_prompt` must handle all
three `system_prompt` shapes — `str`, `{"type":"preset","append":…}`, `{"type":"file"}` — or refuse
loudly.

### 4.3 The options, and why each

| Field | Value | Why |
|---|---|---|
| `system_prompt` | `SYSTEM` (a plain string) | §4.2 |
| `model` | `os.environ.get("PROSE_MODEL") or None` | Let the SDK's own default stand rather than pinning an id we can't verify; one env var to change it |
| `cwd` | `workspace()` — see below | A Finder launch has cwd `/`, which is not somewhere a file-touching agent should sit |
| `permission_mode` | `"default"` | The only mode that reaches `can_use_tool` |
| `can_use_tool` | `Permissions(asker, events)` | §6 |
| `setting_sources` | `["user", "project"]` | §5.1 |
| `plugins` | `skills.plugins()` | §5.2 |
| `skills` | `"all"` | §5.3 |
| `allowed_tools` | `["Read","Glob","Grep","WebSearch","Skill","TodoWrite"]` + `tool_names("prose")` | Read-only and prose's own tools run unattended |
| *(absent, deliberately)* | `Bash`, `Write`, `Edit`, `NotebookEdit`, `WebFetch` | Absent ≠ denied. Absent means **ask**, which §6 makes possible. `WebFetch` is ask-gated because a fetched page is untrusted text entering context |
| `disallowed_tools` | `["Task"]` | The SDK's own subagent tool spawns a subagent with no pane, no transcript, and nothing for `prose_wait` to park on. prose's answer to "delegate this" is `prose_spawn`, which produces a pane a human can watch. Two mechanisms for one idea, one of them invisible, is worse than one |
| `include_partial_messages` | `True` | §3.3 |
| `thinking` | `{"type":"adaptive","display":"summarized"}` | prose has a thinking block and folds it to a `Thought` line; `display` defaults to `"omitted"`, which would draw that block empty |
| `effort` | `os.environ.get("PROSE_EFFORT") or None` | One knob, no hardcoded guess |
| `max_turns` | `None` | A supervision loop is inherently many turns. A cap here is a hang waiting to happen, and Escape is the control that works |

**`workspace()`** returns `$PROSE_HOME` if set, else the inherited cwd when it is neither `/` nor
empty, else `~`. A personal agent's default home is the user's, not the repository it happens to have
been built in.

---

## Step 5 — Skills: how this agent grows without code changes

This is the structure. The SDK gives it to us; the job is to lay it out well and make it visible.

### 5.1 Three tiers, in loading order

| Tier | Where | Loaded by | For |
|---|---|---|---|
| **Bundled** | `agents/skills/` in this repo, shipped in `Contents/Resources` | `plugins=[…]` | prose's own capabilities. Version-controlled with prose, reviewed like code, namespaced `prose:<name>` |
| **Personal** | `~/.claude/skills/` | `setting_sources=["user"]` | Your own, shared with your terminal Claude Code. Nothing to configure |
| **Per-workspace** | `<cwd>/.claude/skills/` and up to the repo root | `setting_sources=["project"]` | Skills that belong to whatever you are working on |
| **Dropped in** | any directory | `$PROSE_PLUGINS`, colon-separated | A third-party plugin, tried without editing anything |

The tiers do not compete: bundled skills are namespaced `prose:` and personal ones are not, so a name
collision is impossible by construction rather than by convention.

### 5.2 The bundled plugin — `agents/skills/`

```
agents/skills/
├── .claude-plugin/
│   └── plugin.json           {"name": "prose", "description": "…", "version": "0.1.0"}
├── README.md                  how to add one — the template lives here
└── skills/
    ├── spawn-coder/SKILL.md
    └── page-digest/SKILL.md
```

**`agents/prose_agent/skills.py`** (new, ~40 lines) resolves the roots:

```python
def plugins() -> list[dict]:
    """Every plugin root to load, as the SDK wants them.

    The bundled one is found the same way the agent script is — beside the
    binary, in a bundle's Resources, then up towards a checkout — because a
    bundled app and a source tree put it in different places and neither is
    the working directory.  `$PROSE_PLUGINS` appends, colon-separated, so a
    plugin can be tried without editing anything.

    Paths are made absolute: **the SDK does not expand `~`**, and it *skips a
    path that does not exist without saying so*, which is why §5.4 checks the
    init message rather than trusting this.
    """
```

The search ladder is the same logic as `AgentProcess.resolveAgentFile` on the Swift side, reimplemented
in Python because Python is what runs here. Worth a comment naming its twin so they stay in step.

### 5.3 The options that turn it on

- `plugins=skills.plugins()` — the bundled root plus anything in `$PROSE_PLUGINS`.
- `setting_sources=["user", "project"]` — personal and per-workspace. The default `None` loads
  nothing, which would ship the skill ring with nothing to drive it.
- `skills="all"` — every discovered skill is invocable. A narrower list is a per-flavour decision
  (§5.5), not a default: this is the user's own machine and their own skills.
- `"Skill"` stays in `allowed_tools` so invoking one does not raise a permission card. The tools a
  skill *then* uses are still gated normally, and a skill can pre-approve its own with the
  `allowed-tools` frontmatter field, which the SDK honours.

### 5.4 Proving it loaded — and the slash-command surface you get free

A `SystemMessage` with `subtype == "init"` arrives near the start of the stream carrying
`data["plugins"]`, `data["skills"]` and `data["slash_commands"]`. `Harness.observe` currently ignores
`SystemMessage` entirely. Have it:

- emit `events.status(skills=str(len(skills)))` so the pane header says how many are live;
- write the names to stderr, which `PROSE_LOG_DIR` and `PROSE_FRAME=1` both capture.

This matters more than it looks: **the SDK silently skips a plugin path that does not exist**, so
without this check a typo in `plugins()` means the skills quietly are not there and nothing says so.
It is also the one piece of evidence about skills that an agent can verify without a screenshot.

**And the dispatch surface comes free.** A user-invocable skill is run by sending `/<name>` as the
prompt. prose's composer already sends whatever you type as a `message` notification, which
`_prompt()` hands straight to `client.query()`. So typing `/prose:spawn-coder` into a pane composer
**works today, with no code on either side** — the composer becomes a command line for skills without
prose knowing skills exist. Say so in the README; it is the kind of thing nobody discovers by accident.

### 5.5 The two skills that ship, and why those two

Each one exercises a different prose primitive, so the structure is proven rather than asserted.

**`prose:spawn-coder`** — the thing you asked for. Its `SKILL.md` instructs the model to
`prose_spawn(task, flavour="code", cwd=…)` and then supervise it with `guide §6`'s loop, reporting
back when the child's turn ends. It needs one mechanism behind it:

> `tools.py`'s `prose_spawn` sends only `from`/`axis`/`kind`/`cwd`/`title`, so every pane a model
> spawns runs `defaultCommand` and is another copy of this same agent. `pane.create` already takes
> `command[]` on the wire and `Workspace.spawnAgent` already honours it. Give `prose_spawn` an
> optional **`flavour`** resolved **in Python against a fixed table**, never passed through:
>
> ```python
> FLAVOURS = {"prose": None,                                   # this agent
>             "code":  [INTERPRETER, AGENTS / "code_agent.py"]}
> ```
>
> A model that can choose an arbitrary argv has a shell, and descendant containment does not cover a
> shell. An unknown flavour is an error, not a fallback.

`agents/code_agent.py` is then ten lines: the same `run(...)` with `system_prompt={"type":"preset",
"preset":"claude_code"}`, coding tools allowed, `cwd` from the task. **The identity you did not want
in every pane lives in one file that only exists inside panes that asked for it.**

**`prose:page-digest`** — open a browser pane on a URL, read it with `browser_text` and a selector,
and summarise. Exercises `browser_open` and the cheapest-thing-first order from `guide §9`, and is
the skill most likely to be used daily by a personal agent.

`SYSTEM` gets one paragraph about all of this: *"You have skills — packaged instructions that load
when they are relevant. Do not describe what a skill would do; invoke it. If the person types
`/name`, that is them invoking one directly."*

### 5.6 `agents/skills/README.md` — the template, and the tests

The README is the modular part that is not code. It carries: the frontmatter reference (`name`,
`description`, `allowed-tools`, `user-invocable`), the one rule that matters (**the `description` is
what decides whether the skill is ever used** — write it about *when to reach for this*, not what it
contains), the namespacing rule, and a complete copyable skeleton.

**`test_skills.py`** keeps the directory honest without running a model: every `skills/*/SKILL.md`
parses as YAML frontmatter plus a body; `name` matches its directory; `description` is non-empty and
under 1024 characters; `plugin.json` is valid JSON with a `name`; `skills.plugins()` returns existing
absolute paths with no `~` in them. Four cheap assertions that catch the failures that otherwise
present as "the skill silently never fires".

---

## Step 6 — Permission prompts become prose's ask card

The best fit in the design: prose already has an ask card, `ask` already takes choices *and* free
text, and a card is already drawn in the right pane. A permission prompt is just another question.

### 6.1 One asker, one lock

**`agents/prose_agent/asking.py`** — `Asker(wire)` with an `asyncio.Lock` around every
`wire.call("ask", …)`. `guide §8` is explicit that prose resolves the first *unanswered* ask and a
second concurrent one is a bug, not a queue — and **the SDK emits parallel tool calls**, so this is a
real race, not a theoretical one. `definitions(wire, asker=None)` gains the parameter and `prose_ask`
routes through it; `asker or Asker(wire)` keeps `_Unbound` and `tool_names()` working untouched.
`serve()` builds **one** `Asker` and hands the same instance to both the MCP server and the
permission callback — that shared instance is the whole mechanism and deserves the comment saying so.

Serialising rather than erroring is right: the second question is the SDK's, not the model's, so an
error would surface as a mysteriously denied tool.

### 6.2 `agents/prose_agent/permissions.py`

- Consults a session-scoped `_always: set[str]` — in memory, never persisted. A grant that outlives
  the pane is a settings file and an audit surface, and that is not this change.
- Otherwise asks, with `choices=["Allow once", f"Allow {key} from now on", "Deny"]` and
  `placeholder="or say why not"`.
- **The "from now on" key is the tool name, except for `Bash`, where it is `Bash(<first word>)`** —
  `git`, `swift`, `npm`. A blanket "allow Bash from now on" is `bypassPermissions` reached by one
  click, and nobody clicking yes three times means to grant that. Keying on the executable is the
  honest middle, and the button text must say exactly what is being granted, because the button text
  is what the person is consenting to.
- **A typed answer becomes the denial message**, passed to the model verbatim. This is the best use
  of the orthogonal card that `issues §2` says nobody has looked at: "Deny" plus *"use the test
  fixture, not the live database"* is a redirect rather than a refusal, and it costs one sentence
  instead of an interrupt and a re-prompt.
- Prompt text written for two readers (`guide §8`), reusing `harness._label` so the card and the
  activity row say the same thing: `Bash wants to run: swift test --filter Supervision`. Argument
  truncated at ~120 chars.
- `ProseError` (socket gone, prose quitting) → **deny**. Never default to allow when the human cannot
  be reached.
- On `interrupt`, cancel any outstanding ask so the callback returns a deny rather than hanging.

### 6.3 A subagent's permission prompt reaching its supervisor

A child's `ask` routes to its **parent agent** first as `child.ask`, with a 60-second escalation
grace. So a child's "may I run `curl … | sh`" can be approved by a model, and the human sees a card
that resolved itself in 200 ms.

I specced a `direct: true` flag on `ask` to bypass supervision, then changed my mind: the parent is
the only party that knows *why* the child is doing this, because the parent wrote the task. Routing
to the human first makes them a rubber stamp for decisions they have less context on than the model
asking — `guide §11`'s "asking the human what you could have answered", from the other side. And the
60-second escalation means the worst case is a delay, not an unanswered question.

**So: keep one ask path, and mitigate in the prompt.** `SYSTEM` gains: *"A question whose prompt
begins with a tool name and 'wants to' is a permission request from a subagent. Answering it commits
you to a side effect you cannot see. Answer it only when you asked that child for exactly that
thing; otherwise `prose_answer(pane, escalate=True)`."*

Be clear about what that is: **a prompt-level mitigation, not a security control.** A fully captured
supervisor ignores it. The actual boundary stays descendant containment, which already stops a child
touching anything outside its subtree. What this buys is the common case — a supervisor escalating
destructive requests it did not initiate. The alternative (a second ask path with its own containment
check, escalation timer and UI state) is the thing that would rot.

**This means the Swift protocol is untouched this pass.**

---

## Step 7 — Make it the default, and keep the tests offline

`AgentProcess.defaultCommand` returns `[interpreter, resolveAgentFile("pane_agent.py")]`, still
overridden whole by `PROSE_AGENT`.

**The single most important line in this step:** `Tests/ProseTests/EndToEndTests.swift` must pin
`PROSE_AGENT` back to the echo agent, via a suite-level `setenv("PROSE_AGENT", <echo path>, 1)` that
runs before any `Workspace(hosting: .enabled)` is constructed. Without it, six tests × every
`swift test` starts real Claude sessions and the suite has a bill.

**The echo agent is not retired.** It is the only agent that exercises the whole wire for free, and
it stays what the tests run.

---

## Step 8 — `prose_focus`

`guide §5` documents it; `tools.py` does not have it. `pane.focus` exists in `parseCall`, is
containment-checked, and lands on `Workspace.revealPane`, which already implements exactly the
promised semantics — it moves the ring and the tab and deliberately leaves first responder alone.
The whole feature is built except eight lines.

**It must use `wire.notify`, not `wire.call`.** `SessionRegistry`'s `.focusPane` arm does not call
`acknowledge(request:on:)` — unlike `sendToPane`, `answerPane` and `interruptPane`, which all do — so
a `pane.focus` sent as a request is never answered and would hang for the full 60-second timeout.
`prose_close` has the same shape; match it.

---

## Files touched

**New:** `agents/pyproject.toml`, `agents/pane_agent.py`, `agents/code_agent.py`,
`agents/probe_stream.py`, `agents/prose_agent/{credentials,prompt,skills,asking,permissions}.py`,
`agents/skills/**` (plugin manifest, README, two `SKILL.md`), `agents/tests/*`,
`Scripts/setup-agents.sh`.

**Modified:** `agents/prose_agent/{harness,loop,tools,__init__}.py`, `.gitignore`,
`Sources/ProseHost/AgentProcess.swift`, `Scripts/make-app.sh`,
`Tests/ProseTests/EndToEndTests.swift`, and the reference documents.

**Not modified:** any Swift protocol or host file. §6.3 is why.

---

## Step 9 — Verification

Three hard constraints from `CLAUDE.md`: the app runs as a bundle or `WKWebView` silently renders
nothing; an agent **cannot inject keyboard or mouse input** here; `screencapture` returns black
frames. So push everything possible below the UI and be explicit about the residue.

### Free, every `swift test`

- `python3 -m unittest discover -s agents/tests` — the harness fixes, the stream mapping, the
  permission table, the skill-directory checks, the no-SDK import property. No SDK, no network.
- `swift test` unchanged and green, with `EndToEndTests` pinned to the echo agent — which is what
  proves step 7's pin actually took.

### Costs tokens, opt-in

**`agents/tests/fake_prose.py` — prose, faked, in ~120 lines.** Binds a socket in a temp dir, sets
`PROSE_SOCKET/SESSION/TOKEN`, spawns `pane_agent.py`, answers `hello` with `{ok, pane:1, session:1}`,
sends one message, and pretty-prints every line the agent sends until `turn {state:"ended"}`.
Flags: `--prompt`, `--ask allow|deny`, `--raw`.

This is the most valuable tool in the plan. It runs the real agent with no Swift, no window and no
WKWebView, and it shows you the **wire**, which is the thing that is either right or wrong. It turns
"does `include_partial_messages` produce deltas" and "did the plugin load" into five-second questions
forever, rather than one-off probes. It is also how we test risk 3 below.

An opt-in end-to-end test gated on `.enabled(if: env["PROSE_SDK_E2E"] == "1")` asserts only cheap
stable things — a turn started and ended, one activity row resolved, one non-empty agent message,
`status["model"]` and `status["skills"]` non-empty — on a prompt like "Reply with the single word:
ready." Never assert what the model said.

### `prose-ctl` cannot help, and the plan should say so

Per `issues §5`, prose refuses a second `hello` for a bound session, so `prose-ctl` cannot attach to
a pane with a live agent — which is every pane worth inspecting. The substitute is **`PROSE_LOG_DIR`**
(`Sources/ProseHost/TrafficLog.swift`), which already exists, logs both directions, redacts tokens
and logs *before* parsing. Set it on every manual run: it leaves behind a machine-checkable record of
a session I could not watch, which closes more of the "an agent cannot see" gap than anything else
available.

### What I have to hand to you

```
./Scripts/setup-agents.sh                    # once
./Scripts/make-app.sh debug
export PROSE_LOG_DIR=/tmp/prose-log
./.build/Prose.app/Contents/MacOS/prose      # from a terminal, so the env is inherited
```

1. **Ask it something conversational that needs a web search.** Does the reply arrive progressively
   or in one lump (the streaming fix — only a human can see this); does a search row resolve in place
   keeping its label, with a detail beside it; is there a `Thought for Ns` line that expands; does
   the header show a model, a cost and a skill count; **are there any literal backticks or `##` in
   the transcript** (the bespoke-prompt bet).
2. **Type `/prose:page-digest https://…`.** This is the free slash-command surface (§5.4) and the
   skill ring — the one piece of UI in prose with nothing else to drive it. Is the row a **ring**
   rather than a disc, labelled `Skill` with the skill's name beside it?
3. **Ask it to run something needing Bash.** Card with three buttons *and* a text field. Click
   "Allow Bash(swift) from now on" → `swift build` should not ask again, `git status` should. That
   four-click sequence checks the entire grant design.
4. **Type a sentence into the card instead of clicking** — the model should receive it as the reason
   and change course.
5. **`/prose:spawn-coder` on a small task.** Second pane appears and fills; the parent shows a single
   `prose_wait` row while blocked, not a spin of repeated reads; the child's ask card names the parent
   as supervisor and takes no clicks for 60 s.
6. **Escape mid-turn** — header stops saying `thinking…`, caret stops, next message works.
7. **Screenshots of (1), (2) and (5)**, since I can't take them. `issues §2` — the ask card, the
   thinking block and the skill ring have never been looked at by a human — is finally answerable.

---

## Step 10 — Deliberately deferred

**The browser page-load wait (`issues §3`)** is the obvious next one and it is nearly free: give
`BrowserSession` a `loads` counter incremented from `didFinish`/`didFail` (not `didCommit` — the body
text isn't there yet, which is exactly what the poll works around), add `WaitReason.loaded`, branch
`.readPane` on pane kind with a `satisfied(_:_:BrowserSession)` overload, and rewrite
`echo_agent.browse()` to use it. That last line makes `EndToEndTests` exercise the new wait reason
over a real socket with a real WKWebView **for zero API tokens on every run**. `prose:page-digest`
would get materially better the day it lands.

Also out: `issues §4` (page-to-prose return path), §5 (`prose-ctl` attaching live), §6 (the
`[PaneID: SessionID]` index), §7's smaller items, and plan §11's four open decisions.

**New gaps to write into `known-issues.md` as part of this work:** there is no way to withdraw an
ask, so an interrupted permission card sits unanswered forever (cosmetic — `Wire._dispatch` already
drops an answer nobody is waiting for); a Finder launch has cwd `/` and no inherited environment; the
bundle carries no interpreter, so it is not relocatable; and the SDK skips a missing plugin path in
silence, which §5.4 detects but cannot prevent.

---

## Risks, and where I am guessing

1. **The `StreamEvent` payload shape.** The one thing I refuse to write blind. Probe first. If whole
   `AssistantMessage`s don't follow the partials, tool inputs must be reassembled from
   `input_json_delta` — a real cost, and an argument for turning streaming off. Decide from output.
2. **`ResultMessage`'s fields.** The documented set (`subtype`, `terminal_reason`, `result`,
   `output`, `exit_code`) and the set seen elsewhere (`total_cost_usd`, `usage`, `num_turns`) barely
   overlap; they may be different SDK generations. `getattr` everywhere, emit only what is present.
3. **`can_use_tool` blocking for hours.** Unknown whether the SDK dispatches it on its own task or
   serialises it with the control channel. If it serialises, a pending card could stall the client
   including `interrupt()`. Test explicitly in `fake_prose.py`: raise a permission ask, wait 10 s,
   send `interrupt`, see if it lands. Fallback is a short deadline and re-asking through `prose_ask`
   in the model's own turn — worse, but it works.
4. **The bespoke prompt.** If it doesn't hold the no-structure line, the pane fills with `##` and
   backticks. The fix is a sharper rule 2, not the preset. (Inline emphasis is no longer part of
   this risk — the renderer took that half.)
5. **Python 3.14.** If `mcp`/`anyio` lack 3.14 wheels the 3.13 preference saves us. If both fail,
   that becomes the blocking item.
6. **Credentials.** If the SDK's bundled binary doesn't find a key, the pane must say so out loud
   (§2) rather than sitting empty.
7. **The `Skill` tool's input shape** is an assumption in §3.1's fifth fix — I do not know which key
   carries the skill's name. The probe settles it in the same run as everything else; until then the
   code must fall back to a bare `Skill` label rather than a `KeyError`.
