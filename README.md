# Prose

Prose is a spatial runtime, allowing agents to create and supervise their own workspace. Rather than abstracting away the majority of relevant information, Prose prioritises observability and user involvement in long running tasks. For complex tasks, Prose designs and deploys agent 'archetypes' specialised to that task, minimizing context pollution and delegating work broadly.

Using a multi-agent conductor architecture, a lead agent delegates tasks to specialised subagents called 'archetypes', who work in parallel and share context through persistent memory. There are agents for browser control, notification reading, etc.

<<<<<<< HEAD
- [`reference/product-spec.md`](reference/product-spec.md) — what the product is and how it
  behaves, written from a working Rust implementation: colours, dimensions, the line-delimited
  JSON-RPC agent protocol, the input model, and what is deliberately left unbuilt.
- [`reference/swift-port-plan.md`](reference/swift-port-plan.md) — a SwiftUI shell with AppKit at
  three points (`WKWebView`, `NSTextView`, `NSWindow`), what the platform gives you for free, where
  Swift is worse than what it replaces, and the order to build it in.
- [`reference/agent-guide.md`](reference/agent-guide.md) — the contract for the agent that runs
  inside a pane: the tool surface, what each call costs, and the mistakes a fresh agent makes by
  default.
- [`reference/scheduling-plan.md`](reference/scheduling-plan.md) — a staged design for durable
  one-time, recurring and event-driven agent work, including background execution, permissions,
  retries and run history.
- [`CLAUDE.md`](CLAUDE.md) — conventions, and where to start.
=======
For tasks that don't have an existing archetype, Prose can manufacture one for your specific needs. New archetypes are stored in memory and will be called upon when needed in the future
>>>>>>> 2f6a66a (new readme)

Each archetype opens its own pane in the multiplexer, providing users with a clear view of each browser search, code change, etc. Users may choose to 'background' existing panels while they are running.

## Set up Prose

Prose requires macOS 15 or newer, Swift 6, Python 3.10 or newer, and either a `claude login` session or an Anthropic API key.

```sh
cd prose-mac
./Scripts/setup-agents.sh
./Scripts/make-app.sh debug
open .build/Prose.app
```

Run Prose as an app bundle; browser panes do not work correctly from the bare SwiftPM executable. If you launch from Finder with an API key, save `ANTHROPIC_API_KEY=...` in `~/.config/prose/env` and run `chmod 600 ~/.config/prose/env`.

## How Prose selects archetypes

Whenever Prose receives a prompt, it checks its existing archetypes for a specialist suited to the task. If one exists, Prose launches or reuses it in its own pane.

If no suitable archetype exists, Prose designs, validates, and deploys a new task-specific archetype automatically. The new archetype is stored in persistent memory and becomes available for future prompts requiring the same capabilities.

## Background a panel

Select another tab or pane while an archetype is running. Its process continues in the background, and its transcript remains available when you return. Use the sidebar to return to its tab; closing the pane ends its agent and discards its transcript.

## Architecture

```text
request → check archetype memory → reuse or create archetype → specialist panes
                                      ↓
                         supervision and compact results
```

The native macOS workspace owns tabs, panes, transcripts, and browser views. Each agent runs in a separate process and communicates with Prose over authenticated, line-delimited JSON-RPC on a Unix socket.

The lead agent receives the prompt, selects or creates the necessary archetypes, delegates work across their panes, and supervises their progress without polling. Archetypes share relevant context through persistent memory and return compact results instead of entire transcripts.

Implementation details live in [reference/agent-guide.md](reference/agent-guide.md) and [reference/product-spec.md](reference/product-spec.md).
