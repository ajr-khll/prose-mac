# prose-swift

A native macOS rewrite of [prose](https://github.com/ajr-khll/prose), an **agent multiplexer**:
many agent sessions running side by side, each one a tab, each tab tiled into a tree of panes that
are either an agent chat frontend or a browser.

**The port is built.** The window, the tab strip, tiling, both pane kinds, the transcript reducer
and the agent socket all exist, with tests. Current work is the agent-facing surface — the
primitives prose's own agent will stand on.

- [`reference/product-spec.md`](reference/product-spec.md) — what the product is and how it
  behaves, written from a working Rust implementation: colours, dimensions, the line-delimited
  JSON-RPC agent protocol, the input model, and what is deliberately left unbuilt.
- [`reference/swift-port-plan.md`](reference/swift-port-plan.md) — a SwiftUI shell with AppKit at
  three points (`WKWebView`, `NSTextView`, `NSWindow`), what the platform gives you for free, where
  Swift is worse than what it replaces, and the order to build it in.
- [`reference/agent-guide.md`](reference/agent-guide.md) — the contract for the agent that runs
  inside a pane: the tool surface, what each call costs, and the mistakes a fresh agent makes by
  default.
- [`CLAUDE.md`](CLAUDE.md) — conventions, and where to start.

The short version of why: in gpui a browser pane meant an opaque native surface floating above the
renderer, re-framed every paint, with no clipping and no corner radius. In AppKit it is an ordinary
subview — and a *scriptable* one, which puts `browser.navigate` and `browser.eval` one method away
in the agent protocol. That, plus roughly half the code ceasing to exist because the platform
already ships it.
