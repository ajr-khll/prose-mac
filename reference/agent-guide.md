# prose — the agent guide

**The contract for the agent that runs inside a pane.** If you are building prose's agent, this is
your document. `product-spec.md` §10 remains the single source of truth for the wire itself; this
guide describes the *client's* view of it and the discipline that keeps an agent cheap.

References are qualified: `spec §10` means `product-spec.md`, `plan §5` means `swift-port-plan.md`,
`guide §4` means this file.

---

## Build state (important)

Everything below works today unless it is marked **(planned)**. Two agents
exercise it: `agents/echo_agent.py` has no model behind it and is what
`EndToEndTests` runs unmocked over a real socket, and `agents/pane_agent.py` is
the real one — a personal agent on the Claude Agent SDK, and what prose opens a
pane with by default.

| Landed | Planned |
|---|---|
| socket, `hello` — which answers with your own **pane** | a page-load event to park on, so reading a page an agent just opened does not mean asking again (§9) |
| `event`, including `role:"thinking"` and `activity.category` | `WKScriptMessageHandler`, the page-to-prose return path |
| `ask`, with choices **and** free text, in any combination | |
| `pane.read` — read and wait in one call, level-triggered | |
| `pane.send` / `pane.answer` / `pane.interrupt`, and `child.ask` | |
| `pane.create`, with `kind` and `url`, replying `{pane, session}` | |
| `browser.navigate` / `text` / `eval` / `snapshot` | |
| descendant containment on every pane-addressed call | |
| **the Agent SDK binding** — band A off the real stream, streamed | |
| **permission prompts as ask cards**, answerable by a parent | |
| **skills**, as a bundled plugin plus whatever the workspace has | |

`agents/prose_agent/` is the client §5's tables describe, and it has now been run
end to end. `harness.py` and `loop.py` — written against documentation and never
executed — turned out to be wrong in six ways, one of which was that the harness
emitted nothing at all. `reference/agent-plan.md` is the account of what was
actually true; read it before trusting anything here that looks like it was
written from the SDK's docs rather than from its behaviour.

**Two things to run rather than reason about.** `agents/probe_stream.py` prints
every message the SDK emits, which is how the mapping was written and how it
should be rewritten when the SDK moves. `agents/tests/fake_prose.py` is prose in
a hundred lines — it runs the real agent with no Swift, no window and no
WKWebView, and shows you the wire.

## 1. What prose already gives you

A pane, and a socket to it that is **already open and already authenticated**. You do not build a
transport, a renderer, a scrollback, a markdown pipeline, or a way to be interrupted.

What arrives for free, once you are connected:

- **A transcript that folds itself.** You emit events; prose reduces them into drawable blocks and
  redraws on a 16 ms cadence. You never send a repaint, never diff, never re-send history.
- **A composer**, with its own IME, undo, history and focus rules. The user's typing reaches you as
  one `message` notification per send.
- **Interrupt.** Escape mid-turn arrives as `interrupt`. You are expected to stop; nothing is
  force-killed.
- **A lifecycle.** When the pane closes you get `closed` *before* your socket goes, so you can shut
  down rather than discovering it through a broken pipe.
- **Subagents as a first-class thing.** A pane you create gets its own process, its own session and
  its own socket connection. It talks to prose directly, not through you.

What you do build: a model loop, and the judgement about when to spend tokens.

---

## 2. The two bands, and the one rule

Everything you might want to express falls into exactly one of two bands.

**Band A — harness-derived.** Thinking, skill loads, tool calls, turn boundaries, model and cost.
You already know all of it from the SDK's own stream. These are facts about your runtime.

**Band B — model-facing tools.** Asking, spawning, reading, waiting, answering, interrupting,
driving a browser. These are *decisions*, so they are tools.

> ### The rule
>
> **Never make a Band A signal a tool.**
>
> A `show_thinking()` tool costs a full inference round-trip for every indicator, and it lets the
> model claim to be thinking when it is not. Emitted by the harness from the stream it is already
> reading, the same indicator costs **zero model tokens and cannot lie.**

This is the rule most likely to be broken by someone adding a feature in a hurry, which is why it
comes before either catalogue. If you find yourself writing a tool whose only effect is to tell the
user what you are doing, it belongs in §4 instead.

---

## 3. The wire

Line-delimited JSON-RPC 2.0, one object per line, over a Unix domain socket. See spec §10 for the
message tables; what matters on the client side is this:

**Three environment variables**, set on every process prose spawns:

| | |
|---|---|
| `PROSE_SOCKET` | path to connect to |
| `PROSE_SESSION` | the session id you are |
| `PROSE_TOKEN` | proof you are it |

**`hello` must be your first line**, and it must carry an `id` so it can be answered. Anything you
send before it is dropped — not refused, dropped. Send `name` with it; it becomes the pane's title.

**Read the reply.** It is `{ok, pane, session}`, and `pane` is the only way you learn which pane you
are drawing in — the environment hands you a session, and everything you address is addressed by
pane. You cannot split yourself without it.

**You may act on your own pane and on any pane descended from yours**, and nothing else. A pane you
asked prose to create is a descendant; a pane in another agent's tab is not. A refused request comes
back as `-32000` with a reason; a refused notification is simply dropped.

**Anything prose said to you before you connected is queued and delivered on your hello.** You
cannot lose the first message by being slow to start, which is a race the agent author cannot win
and so was closed on the host side.

### What the ignore-unknown rule means for you

Spec §10's governing rule is that prose ignores an unknown method, an unknown event kind or a
malformed line rather than erroring. Read from your side, that is a licence:

**You may emit a richer vocabulary than the prose build you are talking to.** A newer event kind
degrades to nothing rather than breaking the connection. Two consequences worth internalising:

- Sending a new kind is safe, but **silent**. If something does not appear, you will get no error —
  check the kind against §4 before assuming a bug in prose.
- One unknown field does **not** cost you the rest of the line. `activity` with a `category` prose
  has never heard of still draws as an activity.

The exception: `attachment` keeps its `type` as a free string precisely so a type prose does not
know renders as plain text rather than vanishing. It is the one extension point that *degrades
visibly* instead of silently.

---

## 4. Band A — the automatic mapping

**You write none of this by hand.** `prose_agent/harness.py` observes the SDK stream and emits it.
The table is here so you can tell what the user is seeing, and so the mapping can be checked.

| Claude Agent SDK stream event | prose event | What the user sees |
|---|---|---|
| thinking block start / delta | `message.start {role:"thinking"}`, then `delta` | dimmed collapsible block; folds to a one-line `thought for 4s` row once the real answer begins |
| skill invoked | `activity {category:"skill", label:"Skill", detail:‹name›, state:"running"}` then the same id with `state:"ok"` | a labelled row that resolves in place |
| `tool_use` begins | `activity {category:"tool", label:"Bash(swift test)", state:"running"}` | 5pt dot + label |
| `tool_result` | `activity`, **same id**, `state:"ok"` or `"error"`, `detail:‹short summary›` | the dot resolves in place |
| text block start / delta / stop | `message.start {role:"agent"}` / `delta` / `message.end` | prose |
| query begins | `turn {state:"started"}` | header reads `thinking…` |
| query ends | `turn {state:"ended"}` | header returns to status fields |
| query errors | `turn {state:"failed", error:‹message›}` | the error is appended as a notice block |
| model, usage, cost | `status {fields:{model, cost, …}}` | header fields, joined with ` · ` |

### Three things that go wrong here

**Reuse the activity id between `tool_use` and `tool_result`, or you get two rows.** prose upserts
an activity by id — the second arrival updates the first in place. A fresh id on the result appends
a duplicate that never resolves. This is the single most common Band A bug.

**A resolving update that omits `detail` keeps the detail it had.** That is deliberate, so
"Searching / 40 sources" does not lose its subtitle on the way to being ticked off. If you *want*
to clear a detail, send an empty string, not `null`.

**A delta for a block nobody opened is dropped.** prose will not implicitly open a message block for
you, because doing so would hide the bug from you. Always `message.start` first.

### Markdown

**prose renders no markdown structure.** It renders paragraphs; structure is yours to declare.
Headings, bullet and numbered lists, tables and block quotes appear as the characters you typed.
Emit code as an `attachment {type:"code", language:…}`, not as a fenced block inside prose — a
fence in a message still renders as literal backticks, and a message containing one has no
emphasis parsed at all.

**Inline emphasis inside a paragraph does render**: `**strong**`, `*emphasis*`, `` `code` ``,
`~~strikethrough~~` and `[links](url)`. Two things to know. Use `*emphasis*` rather than
`_emphasis_` — underscores are left as typed, deliberately, so `__init__.py` survives being
written down. And emphasis is not a way to smuggle structure back in: a paragraph of bold
phrases separated by full stops is the list you were asked not to write.

---

## 5. Band B — the tool surface

These are the tools the model sees. The **token discipline** column is the point of this table.

### Conversation

| Tool | Signature | Returns | Token discipline |
|---|---|---|---|
| `prose_ask` | `(prompt, choices?, placeholder?)` | `{answer}` | Blocks until answered. **One outstanding at a time** — a second ask while one is pending is an error, not a queue. Supply `choices` *and* `placeholder` for buttons plus a free-text answer; they are orthogonal, not exclusive |
| `prose_result` | `(value)` | — | Your session's return value, routed to whoever spawned you. A root session's result goes nowhere; that is fine |

### Subagents

| Tool | Signature | Returns | Token discipline |
|---|---|---|---|
| `prose_spawn` | `(task, flavour?, params?, axis?, cwd?, title?)` | `{pane, session}` | Returns **immediately** — the child is still starting. Follow with `prose_wait`, never a sleep. `cwd` defaults to yours. `flavour` is `prose` (another agent like you), `code` (a coding agent, with the preset's file and shell conventions), or an **archetype** — §5.1. Always a name from a fixed table, never a command line |
| `prose_read` | `(pane, since?, fidelity?, kinds?, match?, block?, limit?)` | `{cursor, blocks, running, status, truncated}` | Defaults to `fidelity:"summary"`. **Always thread `since` from the last cursor you were given.** Use `block:` to pull exactly one block at full fidelity after a summary told you it was worth it |
| `prose_wait` | `(pane, since, until?, timeout?)` | `{reason, cursor, blocks, …}` | **The loop primitive.** Returns the new blocks too, so wait-then-read is one call and not two. Returns immediately if the condition already happened |
| `prose_send` | `(pane, text)` | `{ok}` | Non-blocking. Pair with `prose_wait` |
| `prose_answer` | `(pane, text?, escalate?)` | `{ok}` | Answers a child's pending question on its behalf. `escalate:true` declines it and hands it to the human |
| `prose_interrupt` | `(pane)` | `{ok}` | Stops a child's turn. The child stays alive |
| `prose_close` | `(pane)` | `{ok}` | The child is told `closed` before its socket goes |
| `prose_focus` | `(pane)` | `{ok}` | Brings a pane into view **without** stealing the keyboard from whoever is typing. A notification, not a request: prose does not answer `pane.focus`, so a call would wait out its whole timeout |
| `prose_archetypes` | `()` | `[{flavour, description, parameters, returns}]` | What each specialist takes and returns. **Pull, not push**: an archetype's parameters and return schema are far too much to carry in `prose_spawn`'s schema on every turn of every pane, and are wanted only in the sentence before a spawn |

### 5.1 Archetypes — a specialist per pane

`flavour` names one of `agents/archetypes/*.md`: a Markdown file whose body is a
system prompt and whose header is an allowance — the tools that agent may use,
the skills it carries, the model it runs on, the parameters it takes and the
JSON shape its `prose_result` will have. Adding an expert is adding a file.

**Why not a skill?** A skill loads instructions into *this* agent's context, in
this pane, mid-turn. An archetype is a different agent in a different pane, with
its own context window, its own allowance and its own transcript. So the test is
not how specialised the instructions are, it is: does this need a context window
you do not want to spend, or a permission set you do not want to hold? Either
one means an archetype; neither means a skill.

**The parent names one; it never writes one.** `FLAVOURS` already refuses to let
a model choose an argv, because a model that can choose an argv has a shell. A
model that could write its child's system prompt and pick its tools has the same
thing by a longer route. So a parent supplies a name and *values* for declared
parameters, never prose that lands in a system prompt.

**Where the words sit is the whole argument.** The parent carries one line per
archetype. The child carries the body — as much precise instruction as the job
deserves. If the parent could author that prompt, the instructions would have to
be in the parent's context in order to be written, and the saving would be gone.
`returns` runs the same asymmetry backwards: the parent gets a typed value, not
a transcript.

Two things here are not obvious. `allow` and `deny` are **not symmetrical** —
`allowed_tools` auto-approves rather than restricting, so `allow` is what raises
no card, and `deny` is what actually makes a tool unreachable. And `spawns` is
off unless asked for, because a narrow expert that can spawn a wide one has
everything it was denied, one pane away — which descendant containment does not
catch, since the child is a perfectly legitimate descendant.

### Browser

**These are not given to an agent that can spawn.** A personal or coding pane holds none of the
fourteen below; `pane_agent.py` and `code_agent.py` pass `permissions.NO_BROWSER` as part of
`disallowed_tools`, and `loop.serve` then leaves them out of the MCP server entirely, so they cost
nothing in context and cannot be attempted. A browser errand goes to
`prose_spawn(flavour="browser-pilot", params={"scope": …})`, whose pane holds the full set.

The reason is measured rather than tidy. While a general agent held these, one asked to walk
Wikipedia went straight to `browser_eval` with a guessed CSS selector, got `null` twice and had to
be interrupted — with `browser_elements` unused in the same tool list. The prompt had argued for
delegating *and* explained how to drive a browser; the cheap path was one call and delegating was
three, and the cheap path won. So the capability was removed rather than argued about again.

The same walk then found the *second* half of it, in the pilot that was supposed to be the fix.
Refs were there and the pilot still wrote traversal scripts, because the ref surface had holes:
no way to search a page whose element list truncated at 200 of 1,100, no `<select>`, no key but
Enter, no scrolling anything but the window, no way back, nothing inside a shadow root, and —
the expensive one — no way to wait for a change that was not a navigation, so the only way to
watch a page was to poll it with a script. **A capability the refs lack is not a prompt problem.**
An agent that cannot do a thing through a tool will do it through a script, and it is right to.
Closing the holes is what the table below is; `browser_eval` is logged so the next one shows up
as data rather than as a hunch.

What follows is therefore the pilot's surface, and the `code` and `prose` flavours reach it only
through a pane.

| Tool | Signature | Returns | Token discipline |
|---|---|---|---|
| `browser_open` | `(url, axis?, placement?)` | `{pane}` | Opens **above** you by default (`column`/`before`), so the page is the top of the column and you are underneath at its full width. Only panes you open this way are drivable by you — see §9. **Open one and keep it**: a second page is `browser_navigate`, since every open halves your pane |
| `browser_navigate` | `(pane, url)` | `{ok}` | |
| `browser_text` | `(pane, selector?, limit?)` | `{url, title, text, matched, truncated?}` | Use `selector` and `limit`; a whole page is easily 10k tokens. **`matched: false` means the selector found nothing** — a different problem from an empty page, and the two used to be one symptom |
| `browser_elements` | `(pane, limit?, wait_for?, timeout_ms?)` | `{generation, total, truncated, elements, waited?}` | **Reach for this before acting.** Every link, button and field, numbered, with role and accessible name. ~200 tokens, and its refs are what the acting tools take, so no selector is ever invented. With `wait_for` or `timeout_ms` it waits for the page to settle first — see §5.1 |
| `browser_find` | `(pane, text, limit?)` | `{total, matched, elements}` | **The answer to a long page.** Searches every actionable element's name and href, returns the few that match with refs already assigned. A `truncated` element list is a cue to call this, not to raise `limit` |
| `browser_click` | `(pane, ref)` | `{ok, clicked, url, navigating?}` | Dispatches the whole pointer sequence, not a bare `.click()` — components that listen for `pointerdown` ignore the latter. `navigating` is the href it is about to follow, so a followed link is distinguishable from a button that did nothing |
| `browser_type` | `(pane, ref, text, enter?)` | `{ok, value}` | Through the native value setter, so React and Vue see it. Assigning `value` directly shows the text and tells the application nothing, which looks exactly like a typo |
| `browser_select` | `(pane, ref, option)` | `{ok, selected, value?}` | A `<select>` cannot be clicked open — its menu is drawn by the platform, outside the page — so this is the only way to set one. Handles the ARIA listbox spelling too. A miss lists the options that exist |
| `browser_key` | `(pane, key, ref?)` | `{ok, key, on}` | One named key: `escape`, `tab`, `enter`, the arrows, `pageup`/`pagedown`, and so on. No `ref` means at the focus, which is what dismissing a dialog means |
| `browser_scroll` | `(pane, ref?, to?, by?)` | `{ok, top, height, moved, at_end}` \| `{ok, at}` | A ref into view, or `top`/`bottom`, or `by` pixels. With a ref it moves the box that element actually scrolls in, not the window behind it. `moved: 0` with `at_end` is "there is no more" |
| `browser_back` / `browser_forward` | `(pane)` | `{ok, navigating}` or `{ok: false, error}` | Session history. Needed because after a wrong turn you may not know the URL you came from, and the alternative is `history.back()` in an eval |
| `browser_console` | `(pane, since?, level?, limit?)` | `{entries, cursor, dropped?}` | **The difference between a broken site and a wrong selector.** `console.*`, uncaught errors and unhandled rejections, collected in the page from document start so a startup throw is not missed. Defaults to `warn` and worse, because a chatty page's `log` is the largest pile of tokens here and almost never the answer. `since` takes the last `cursor` |
| `browser_network` | `(pane, since?, failures_only?, limit?)` | `{entries, cursor, dropped?}` | Every `fetch` and XHR the page started, the main document's own status code, and any subresource that failed. **Read it when a page is empty or half-rendered**: that is usually a request that 401'd, not a page that needs more waiting. `failures_only` is the usual question |
| `browser_eval` | `(pane, script)` | the script's value | **Last resort, never for finding or acting.** Every call is logged to stderr and to `$PROSE_LOG_DIR/browser-eval.jsonl`; a log full of traversal scripts is read as a missing tool. For a computed value only. Not-JSON-representable comes back `null` |
| `browser_snapshot` | `(pane)` | `{path}` | **Last resort.** Returns a path, never bytes. Reading that file is a separate, deliberate ~1,500-token decision — make it only when the page's *appearance* is the question |

---

## 6. The supervision loop

This is the section to copy. It threads the cursor explicitly, because that is the part that goes
wrong.

```python
# Spawn, then supervise. Never sleep; never re-read from zero.
child = await prose_spawn(task="Port the split tree tests to swift-testing.",
                          axis="row", title="split tests")
pane, cursor = child["pane"], 0

while True:
    # One call: parks until something happens, and brings back everything
    # new since `cursor` as summaries. Returns immediately if it already has.
    w = await prose_wait(pane, since=cursor, until=["turn", "ask", "exit"],
                         timeout=120_000)
    cursor = w["cursor"]

    for b in w["blocks"]:
        if b["k"] == "act" and b.get("state") == "error":
            detail = await prose_read(pane, block=b["i"])   # zoom, only now
            ...

    if w["reason"] == "ask":
        # It is stopped on a question addressed to you first (§8).
        await prose_answer(pane, text="Use the unscaled reading.")

    elif w["reason"] == "turn":
        # A turn ended. The last agent message is the thing to read.
        ...
        break

    elif w["reason"] in ("exit", "closed", "timeout"):
        break
```

Three properties of that loop worth stating:

- **`cursor` is threaded, never reset.** Each pass costs only what is new.
- **Nothing is read at full fidelity until a summary justified it.** The `prose_read(block=…)` call
  happens inside a branch, not before one.
- **There is no `sleep` and no poll.** Every iteration is blocked on `prose_wait`, which is the only
  thing in the loop that takes time.

`agents/echo_agent.py`'s `supervise()` is this loop in twenty lines of Python, against the real
socket. Read it if anything here is ambiguous — it is what the end-to-end test actually runs.

---

## 7. The token budget

### The arithmetic

One representative child turn — a 120-character user message, a 9,000-character thinking block, six
activities, an 1,800-character code attachment and a 400-character text one, a 2,400-character
reply, and a turn end:

| Read as | Cost |
|---|---|
| `fidelity:"full"` | ≈ 14,120 chars ≈ **3,530 tokens** |
| `fidelity:"summary"` | ≈ 885 chars ≈ **220 tokens** — **16× cheaper** |
| summary + one zoom into the reply | ≈ **820 tokens** — still 4× cheaper |

In the common case the summary is enough and you stay at 220. **That ratio is the entire reason the
read is two-stage.**

### What a summary block looks like

`i` is the block's index — its address for a zoom. `n` is its character count, which is what tells
you whether zooming is worth it.

```jsonc
{"i":0,"k":"user",     "n":120,  "head":"Port the split tree tests…"}
{"i":1,"k":"thinking", "n":9014}                            // no head, ever
{"i":2,"k":"act",      "label":"Bash(swift test)","detail":"95 passed","state":"ok","category":"tool"}
{"i":3,"k":"act",      "label":"Skill","detail":"swift-testing","state":"ok","category":"skill"}
{"i":4,"k":"att",      "type":"code","lang":"swift","n":1840}
{"i":5,"k":"agent",    "n":2400, "head":"All eleven split tests pass. The one that…"}
{"i":6,"k":"ask",      "prompt":"Which reading of §7.1?","choices":["Unscaled","Scaled"],"answer":null}
{"i":7,"k":"notice",   "text":"agent exited (code 2)"}
```

- **Thinking summarises to a character count with no preview at all.** You almost never need a
  child's chain of thought, and it is usually the largest block in the turn. This is the single
  biggest saving in the design.
- **Activities are already summaries** — full and summary are identical for them, no truncation.
- **Asks and notices are always full.** Both are small, and both are the things you most need to act
  on.

### The cap

A reply is capped at **~32 KB regardless of `limit`**, truncated, with `"truncated": true` set. A
child that attaches a 5 MB file would otherwise blow your context in a single call, and you have no
way to know in advance. If you see `truncated`, narrow with `kinds`, `match` or `limit` — do not
retry the same call.

### Addressing

Blocks are addressed by **index, not id**: notices have no id and user messages use an empty one.
The index is stable because blocks are only ever appended or mutated in place, never removed.

---

## 8. Ask semantics

**One question outstanding at a time.** prose answers the first unanswered ask it finds; a second
concurrent ask is a bug on your side, not a queue.

**Choices and free text are orthogonal.** Send `choices` for buttons, `placeholder` for a
typed answer, both for both. Once answered, every button stays visible and the chosen one is marked
— the card is a record, not a form that disappears.

**You are writing for two readers.** The prompt appears on a card a human is looking at, even when
a parent agent answers it. Write it so both can act on it.

### A child's question reaches you before the human

If you spawned a pane, its asks route to **you** first, as a `child.ask` notification, and surface
through `prose_wait(until=["ask"])`. The card is drawn in the child's pane immediately but inert,
naming you as its supervisor, so the human can see what is being decided without being asked to
decide it.

- `prose_answer(pane, text=…)` resolves it as if the human had clicked.
- `prose_answer(pane, escalate=True)` declines, and the card goes live for the human.
- Doing nothing does the same, after a timeout.

**Whoever answers first wins**, and that is safe by construction — the transcript resolves the first
*unanswered* ask and ignores a second answer. A root session (no parent) is unaffected: its
questions go straight to the human, as they always have.

---

## 9. Browser panes (planned)

### One pilot, one page pane, reused

A pane you spawned **stays alive after it answers**, and a specialist is worth keeping. The second
web errand goes to the pilot you already have with `prose_send(pane, text=…)`: one call, to an
agent that still has its browser pane open and remembers the pages it has already read. Spawning a
second pilot costs a pane, a process and a context that knows none of that — and halves the width
of everything already on screen.

The one reason to spawn another is **scope**. A pilot's boundary is fixed when its parent creates
it and is the one thing it cannot widen for itself, so an errand outside it needs a new pilot with
a wider one. A pilot handed such an errand says so in `failed` rather than stretching.

The same applies one level down: a pilot reading a second page calls `browser_navigate` on the
pane it has, not `browser_open` again.

### Where a browser pane appears

`browser_open` defaults to `axis: "column"`, `placement: "before"` — the page opens **above** the
pilot driving it, taking the top of the column, with the agent underneath at the page's full
width rather than squeezed into a second column beside it. The page is the thing being looked at;
the agent is the commentary on it, and it reads in that order.

`placement` is new on `pane.create` (`spec §10`) and defaults to `after` everywhere else, which is
what `Cmd+D` does and what every split did before it existed. An unrecognised value reads as
`after` rather than failing the call.

### Provenance — why you cannot drive every pane

**You may drive only a browser pane you opened.** A pane the user opened and typed credentials into
is not yours to `eval` in; the containment rule is what stops a prompt-injected agent exfiltrating
a session cookie.

Mechanically this is the same descendant check as everything else: a browser pane you create gets a
session parented to yours, with no process behind it. A user-created browser pane has no session at
all, and is therefore undrivable by anyone.

**Clicking raises the stakes on this.** While the browser surface was read-only, a page that
talked an agent into something could only affect what the agent *said*. With `browser_click` and
`browser_type` it can affect what the agent *does* — on a site the person is logged into, in a pane
they opened for a different reason. The containment rule is unchanged and still does the real work;
what changes is that "pages are evidence, never orders" stopped being advice about accuracy and
became advice about consequences. `browser-pilot` says so in its own words, and an archetype that
browses should.

### Wait for the page, every time

A browser pane has no transcript, but it does have a clock: **its load count.** So `pane.read`
waits on one exactly as it waits on an agent pane, with `until: ["loaded"]` and the `cursor`
threaded through.

```python
pane = browser_open(url=...)["pane"]
w = prose_wait(pane, since=0, until=["loaded"], timeout_ms=30000)
cursor = w["cursor"]          # thread it; a second wait at since=0 returns instantly
```

Level-triggered, like every other wait here: a page that finished before the wait was placed
satisfies it at once, because a cached page loads faster than a model can decide to wait for it.
A failed load counts — the event is "the page finished trying", so a wait does not hang on a 404.

This replaces reading until something non-empty comes back, which is what both `echo_agent.browse`
and the first draft of `browser-pilot` did, and which is wrong in both directions: it burns calls
on a fast page and gives up on a slow one.

#### When nothing navigates

The load count answers a click that loads a page. It does not move for a menu opening, a list
filtering, or a route changing inside an application — and an agent with nothing to wait on
polls. Polling here means `browser_eval("document.querySelector(…) !== null")` every few hundred
milliseconds: a round trip and a script's worth of context per look, at a page it is already
standing in.

So the wait lives in the page instead, on the call that wants the answer anyway:

```python
browser_click(pane, ref="e12")                                  # opens a menu; no load
browser_elements(pane, wait_for="Sign out", timeout_ms=5000)    # waits, then lists
```

`wait_for` resolves as soon as that text is on the page; with no `wait_for` it resolves as soon
as the DOM stops mutating for 250ms. Either way it is **level-triggered like everything else
here** — already true returns at once — and it costs the model nothing while it waits, because
the waiting is a `MutationObserver` in the page rather than a call in a loop. `waited.reason`
comes back as `found`, `quiet` or `timeout`.

### Reach for the cheapest thing that answers the question

1. **`browser_elements`** — what is actionable, numbered. ~200 tokens, and the only way to act
   without inventing a selector you cannot check.
2. **`browser_text`** — rendered text, with `selector` and `limit`. Check `matched`.
3. **`browser_console`** and **`browser_network`** — when the page is not behaving, before
   trying the same thing a second time. Both are cursor-based and neither costs a round trip
   into the page, because the entries are already on prose's side by the time you ask. They are
   the only tools here that answer *why nothing happened*, and the failure they catch is the one
   that otherwise turns into a retry loop: a page throwing on every render, or a request that
   401'd behind an empty list.
4. **`browser_eval`** — when none of those carries it, and never to find or act. Logged every
   call. An error comes back as `{error}` rather than `null`, so a broken script is
   distinguishable from a value that is genuinely null.
5. **`browser_snapshot`** then `Read` on the path — only when *appearance* is the question. It
   returns a path, not bytes, specifically so that spending ~1,500 image tokens stays a separate
   decision you have to make on purpose. Scroll first: it captures the viewport and nothing else.

### Refs go stale loudly

`browser_elements` numbers the page as it is *now*. The list lives in the page's own JavaScript
context, so a navigation destroys it and a ref from the previous page is refused with a sentence
saying so — never acted on as whatever now occupies that index. `generation` covers the softer
case, a same-page re-render. Re-list after anything that navigates or redraws.

---

## 10. Failure modes

Each of these is a shape you will actually receive. None of them is an exception you can ignore.

| What happened | How it reaches you | What to do |
|---|---|---|
| Your pane was closed | `closed` notification | Shut down. Your socket goes immediately after |
| A child's process exited | `prose_wait` returns `reason:"exit"`; a notice appears in its pane | The pane is **not** closed — read the notice for the status |
| A child you were waiting on was closed | `prose_wait` returns `reason:"closed"` | Stop waiting on that pane. It is gone |
| Nothing happened in time | `prose_wait` returns `reason:"timeout"` with the cursor unchanged | Decide: wait again, prod it with `prose_send`, or give up. Do **not** immediately re-wait with the same timeout in a loop |
| A read was too big | `truncated: true` | Narrow with `kinds`, `match` or `limit`. Do not retry unchanged |
| The user pressed Escape | `interrupt` notification | Stop the turn. Emit `turn {state:"ended"}`; you will not be killed |
| A child never connected | Waits still work; its transcript is empty but for a notice | Anything you sent it was queued and will arrive if it ever connects |
| A child died mid-turn | `reason:"exit"`, with its last block still marked streaming | prose closes dangling streams at turn end; read the notice for why |
| You asked about a pane that is not yours | JSON-RPC error `-32000` | You may only act on your own pane and its descendants |

---

## 11. Anti-patterns

Stated flatly, because these are what an agent does by default if nobody says otherwise.

- **Polling instead of waiting.** `prose_read` in a loop with a sleep costs a turn every iteration.
  `prose_wait` costs one call for the whole wait. This is the largest single waste available to you.
- **Re-reading from cursor 0.** Thread the cursor. Re-reading history you have already seen is
  paying twice for the same tokens.
- **`fidelity:"full"` by default.** 16× the cost, for information you usually discard. Summary
  first, zoom on evidence.
- **Snapshotting instead of reading text.** A screenshot to find out what a page *says* is about
  1,500 tokens to answer a question `browser_text` answers for 50.
- **Announcing thinking as a message.** Do not emit "Let me think about this…" as prose. Thinking is
  Band A; it is already being shown.
- **Asking the human what you could have answered.** If you spawned the child and you know the
  answer, answer it. Escalate when it is genuinely the human's call — not as a default.
- **Opening a second reader on the socket.** See §12. This deadlocks, and it deadlocks quietly.
- **Sleeping after `prose_spawn`.** The child may take 20 ms or 2 s to connect. `prose_wait` already
  handles both; a sleep gets one of them wrong.

---

## 12. Hello world

```python
from prose_agent import run
from claude_agent_sdk import ClaudeAgentOptions

run(ClaudeAgentOptions(
    system_prompt="You supervise subagents in prose.",
    allowed_tools=["prose_ask", "prose_spawn", "prose_read", "prose_wait"],
))
```

What those five lines silently set up:

1. Connects to `PROSE_SOCKET` and sends `hello` with `PROSE_SESSION` / `PROSE_TOKEN`, then drains
   anything prose queued for you while you were starting.
2. Installs the Band A harness on the SDK stream — thinking, skills, tool activity, turn boundaries
   and status all start flowing, automatically, at zero model tokens.
3. Registers the Band B tools as an **in-process** MCP server, so a tool call is one line out and
   one line back on the socket you already hold. No subprocess, no second handshake.
4. Pumps prose's notifications — `message`, `interrupt`, `closed`, `child.result`, `child.ask` —
   into the client loop.

### The one thing to get right in the client

> **Only one thing may read the socket.**
>
> Both the SDK's loop and every MCP tool handler need traffic from it, so `wire.py` owns a **single
> reader task that demultiplexes**: JSON-RPC responses resolve a future keyed by `id`;
> notifications go on an async queue the agent loop consumes.
>
> A second reader does not error — it *steals lines*, and whichever consumer was supposed to get
> them hangs. `agents/echo_agent.py` reads the stream with a single-consumer `for` loop, which is
> correct for an echo agent and would deadlock the instant a tool handler also wanted to read.
> If you are writing a client from scratch rather than using `prose_agent`, this is the thing that
> will cost you a day.
