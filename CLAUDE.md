# prose-swift

A native macOS rewrite of **prose**, an agent multiplexer: many agent sessions side by side, each
one a tab in an Arc-style vertical strip, each tab tiling its content area into a tree of panes. A
pane is either an **agent pane** (prose's own chat frontend — a transcript plus a composer, not a
terminal) or a **browser pane**.

The port is built. `ProseCore`, `ProseHost`, the window, tiling, both pane kinds and the agent
socket all exist and their tests pass — plan §10's build order is complete through step 6. What is
being built now is the **agent-facing surface**: the primitives prose's own agent will stand on.

## Read these first, in this order

| File | What it is |
|---|---|
| `reference/product-spec.md` | **The requirements.** What prose is and how it behaves, written from a working Rust implementation rather than from intent: every colour, every dimension, the agent protocol, the input model, and what is deliberately not built |
| `reference/swift-port-plan.md` | **The shape of the answer.** Framework choices, what the platform gives you for free, where Swift is *worse* than what it replaces, the package layout, and the build order |
| `reference/agent-guide.md` | **The contract for the agent that runs inside a pane.** The two bands, the tool surface and its token discipline, the supervision loop, and the mistakes a fresh agent makes by default. Read it before touching `Protocol.swift` |
| `reference/agent-plan.md` | **The work in progress, and why each call was made.** The plan for the agent that runs in a pane, with what a probe run of the SDK actually found recorded beside what the plan assumed — because the point of writing one down is being able to see where it was wrong |
| `reference/known-issues.md` | **What is outstanding, and what is only assumed.** Every open defect and unverified piece, with what "done" looks like for each — and a list of what is *already* fixed, so nobody re-hunts it |
| `reference/demo.png` | The screenshot every dimension was measured from, captured at ~1.55×. Divide pixel distances by that before treating them as points |

References are qualified: `spec §5` means `product-spec.md`, `plan §5` means `swift-port-plan.md`,
`guide §5` means `agent-guide.md`, `issues §5` means `known-issues.md`, and `agent-plan §5` means
`agent-plan.md`.

## Where the original lives

The Rust implementation is at `~/Documents/projects/prose`, branch `swift-port`. It is worth
reading when the spec is ambiguous — but note that its `CLAUDE.md` is a catalogue of gpui traps
that this port makes irrelevant, and its keyboard section is out of date. **The spec supersedes
it.** Note also that its agent-pane work does not compile (spec §1); the shell does.

## Start here

The port is done and the agent now runs. `agents/pane_agent.py` is a **personal
agent** on the Claude Agent SDK — not a coding agent; coding is a flavour it
spawns into a pane of its own — and it is what prose opens a pane with by
default. `reference/agent-plan.md` is the account of that work, including the
six ways the SDK glue was wrong before anyone ran it.

Set it up once with `./Scripts/setup-agents.sh`, which builds `agents/.venv`.
Without it every pane opens on `agent exited (code 1)`.

Two ideas still carry the whole design:

1. **Two bands.** Thinking, skill loads and tool activity are *harness-derived*
   and are emitted automatically from the SDK stream at zero model tokens.
   Asking, spawning, reading and waiting are *decisions*, so they are tools.
   Never make a band-A signal a tool — it costs a round-trip per indicator and
   lets the model claim to be thinking when it is not.
2. **One level-triggered, cursor-based read.** A parent supervising a subagent
   parks on a single call that returns why it woke *and* everything new since
   its cursor, as summaries. It replaces polling, and it is 16× cheaper than
   reading a turn at full fidelity. It must return immediately when the
   condition has already happened, or a fast child hangs its parent forever.

### Running the agent without a window

`agents/tests/fake_prose.py` is prose in a hundred lines: it binds a socket,
answers `hello`, sends one message and prints what comes back. It runs the real
agent with no Swift, no window and no WKWebView, and shows you the **wire**,
which is the thing that is either right or wrong.

    agents/.venv/bin/python agents/tests/fake_prose.py --prompt "say hello"
    agents/.venv/bin/python agents/tests/fake_prose.py --ask deny --prompt "..."
    agents/.venv/bin/python agents/tests/fake_prose.py --ask interrupt --prompt "..."

`agents/probe_stream.py` prints every message the SDK emits. **Write mappings
from its output, never from the documentation** — that is what the last round
got wrong, expensively.

The Python tests run under any interpreter, with no SDK installed, because
`prose_agent` imports none outside three function bodies:

    python3 -m unittest discover -s agents/tests -t agents/tests

`swift test` runs the echo agent, which has no model and costs nothing.
`PROSE_SDK_E2E=1 swift test` adds one real turn in a real pane, and costs money.

Before starting anything, read `reference/known-issues.md`. The largest open
item is now that **none of the new UI has been looked at by a human** —
`screencapture` returns black frames on this machine — and the ask card, the
thinking block and the skill ring finally have something real to draw.

## Conventions

- **Readability over efficiency.** Standing instruction, and the reason most of the original reads
  the way it does.
- **Comments explain *why*, not what.** Most functions carry a short doc comment giving the reason
  they are shaped the way they are; tricky lines carry an inline note. Match that density.
- **Every colour and dimension lives in one place** (`Palette.swift`, `Metrics.swift`). If you find
  yourself typing a number in a view, it belongs there instead.
- **Points scale, pixels don't.** Dimensions are points multiplied by the zoom rung; four things
  stay in real pixels because they must line up with the traffic lights, which ignore your zoom.
  Spec §3 lists them. Keep the two bands separable in the type system — see plan §6.1.
- **The model imports no UI framework.** `ProseCore` depends on nothing, which is what makes the
  split tree trustworthy and its tests runnable without a window. Keep the split tree holding pane
  **ids**, not view handles, even though `@Observable` removes the original reason for it.
- **Test the pure logic.** Anything that decides a layout, folds an event, or steps a selection
  gets a test.
- **Measure, don't eyeball.** The development display is 1× (2560×1440), so one screenshot pixel is
  one point. `screencapture -x -o -t png /tmp/shot.png` works. Spec §5 ends with a table of exact
  numbers to re-measure after any layout change; eyeball comparisons have missed real bugs twice.
- **An agent cannot inject input on this machine** — no Accessibility permission, so `osascript`
  keyboard and mouse injection does not work. Cover interaction logic with unit tests and ask the
  user to try the real thing. Don't report it as unverifiable.
- **Run the app as a bundle, never the bare binary.** `./Scripts/make-app.sh debug` then
  `.build/Prose.app`. `WKWebView` will not start its web content process without a bundle
  identifier, so from the raw SwiftPM product a browser pane renders nothing, silently, and
  looks like a bug in the pane.
- **Ask before committing.** Commit messages carry **no AI attribution** unless the session's own
  instructions supply an attribution line.

## Decisions the user still owes you

Plan §11 listed seven. Four are now answered: the macOS floor is 15 (`Package.swift`), transcript
selection is per-block (`.textSelection(.enabled)`), the browser pane **does** get its own
protocol methods (`guide §9`), and the no-markdown decision was **split** — inline emphasis is
rendered (`Markdown.swift`, `ProseText.swift`), structure still is not (`spec §9.3`).

Still open, and worth asking rather than assuming: whether Linux is formally dropped, whether
distribution is unsandboxed and notarised, and plan §11's nearness option.
