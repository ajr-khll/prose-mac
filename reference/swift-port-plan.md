# prose in Swift — how the port should be shaped

Companion to `reference/product-spec.md`. The spec says *what prose does*; this says *what Swift
does with it*, and in particular where Swift hands you behaviour you are currently writing by hand.

---

## 0. The verdict

Port it, and target **macOS 15+, SwiftUI for the shell, AppKit dropped in at exactly three
places**: the pane body (`WKWebView`), the composer (`NSTextView`), and the window chrome
(`NSWindow` traffic-light and collection-behaviour tweaks).

Two things make the case, and they are different in kind:

1. **The browser pane stops being a research project.** spec §13.1 calls this "the single strongest
   reason the port is being considered", and it is right, but it undersells it — see plan §2.
2. **Roughly half the code stops existing.** Not rewritten smaller: *deleted*, because the
   platform already ships it. The text stack, the icon embedding, the asset source, the
   drag-release guard, the animation frame-request split, the UTF-8↔UTF-16 boundary, the
   markdown-free text shaping, the transcript hit-testing cache. All of it is AppKit's problem
   and has been since roughly 1994.

What you *lose* is Linux and the rem-size zoom trick. Both are addressed in plan §6.

---

## 1. Framework choice: SwiftUI shell, AppKit where it earns it

The temptation is to go all-AppKit because the killer feature is a `WKWebView`. Don't. A
`WKWebView` inside `NSViewRepresentable` inside a SwiftUI pane is an ordinary child view with
real clipping and real corner radius — you pay nothing for the SwiftUI wrapper and you get
declarative state for the other 90% of the app.

| Surface | Use | Why |
|---|---|---|
| Window, scene, menus | SwiftUI `Window` scene | `Window` (not `WindowGroup`) is *exactly one window* and removes the New Window menu item — spec §2, for free |
| Titlebar, traffic lights, green-button zoom | AppKit, via a tiny `NSViewRepresentable` that reaches `window` | No SwiftUI API for `standardWindowButton(_:)` positioning or `collectionBehavior` |
| Background blur | `NSVisualEffectView` (`.underWindowBackground`) | Replaces the hand-painted translucent wash |
| Sidebar, tabs, headers, chrome | SwiftUI | Where the declarative win is largest and the layout is simplest |
| Tiling | SwiftUI, but with **manual frame arithmetic** from `Split.rects()` | See plan §6.5 — do not express the tiling as nested `HStack`/`VStack` |
| Transcript | SwiftUI `ScrollView` + `LazyVStack` | Scroll-to-bottom, follow, and per-block text selection |
| Composer | **`NSTextView`** in `NSViewRepresentable` | plan §3 |
| Browser pane body | **`WKWebView`** in `NSViewRepresentable` | plan §2 |
| Model, protocol, split tree, transcript reducer | Plain Swift, zero framework imports | plan §5 |

Target **macOS 15** as the floor. It buys `.pointerStyle(.columnResize)` / `.rowResize` for the
divider strips (today's `col-resize`/`row-resize` cursors), `ScrollPosition` for follow-the-bottom,
and `.restorationBehavior(.disabled)` for the spec's "no window restoration". macOS 26 adds
nicer text APIs but nothing here depends on them.

**The app cannot be sandboxed.** It spawns arbitrary agent command lines and binds a socket in
`$TMPDIR`. That means Developer ID + notarisation and direct distribution, not the Mac App Store.
Decide that now, because it also means `WKWebView` needs no entitlement gymnastics.

---

## 2. The browser pane — the headline

In gpui the plan (spec §13.1) was: add a sibling `NSView` over the renderer's single Metal view, re-frame
it every paint from a `canvas()` element's bounds, flip the Y because gpui doesn't override
`isFlipped`, and accept that it paints above every other element, has no rounded corners, no
clipping, and steals first responder on click.

In AppKit **every one of those costs is zero**, because a `WKWebView` is just a view:

| gpui cost | In AppKit |
|---|---|
| Re-frame every paint from a canvas element | It's a subview. Autolayout or the parent's `layout()` positions it |
| Y flip | Put it in a flipped container, or don't care — the parent handles it |
| Paints above every gpui element | Normal z-order. A pane header drawn after it is *above* it |
| No rounded corners, no clipping | `wantsLayer`, `layer.cornerRadius = 8`, `masksToBounds` — or SwiftUI `.clipShape` |
| Steals first responder on click | That is the correct behaviour. The pane also gets the click via the responder chain |
| `PANE_GAP ≥ RESIZE_HANDLE` compile assert, added so a native overlay couldn't swallow the sidebar drag | **No longer load-bearing.** Keep the constant, drop the reason |

And then the part that isn't in the spec at all, because gpui made it unthinkable: a `WKWebView` is
not just a rectangle that shows a page, it is a **scriptable object with delegates**. Almost free,
the moment you have one:

- `WKNavigationDelegate` → `webView.title` drives the pane header's title (spec §8 wants "what the
  agent calls itself, falling back to Browser" — now it's the page title, which is better).
- `estimatedProgress` (KVO) → a loading hairline in the pane header.
- `canGoBack` / `canGoForward` → two more header buttons, matching the three that are already there.
- `WKWebsiteDataStore.nonPersistent()` → per-pane ephemeral sessions, so two panes can be logged
  into the same site as different users. That is a genuine product feature for an agent multiplexer.
- `evaluateJavaScript` and `WKScriptMessageHandler` → **the agent protocol grows a browser.**

That last one is the real prize. spec §10's agent→prose table is one method away from letting an agent
drive a browser pane it opened:

```
browser.navigate   pane, url
browser.eval       pane, script            (a request — the result is the response)
browser.snapshot   pane                    (takes a WKWebView snapshot, returns it)
```

and `WKScriptMessageHandler` gives the reverse direction — the page posting events back into the
transcript. None of that is buildable on top of "an opaque native surface floating above the
renderer". All of it is a weekend on top of `WKWebView`. **This alone probably justifies the port**,
independent of any code you delete.

---

## 3. The composer — delete `composer.rs` and most of `agent.rs`

spec §9.4 already concedes this: *"On the Swift side essentially all of this is `NSTextView`."* It is
worth being specific about how completely true that is, because it's 585 lines plus the majority of
`agent.rs`'s 1125.

| spec §9.6 requirement | What you write |
|---|---|
| Backspace / Delete / Alt+Backspace | Nothing |
| ←/→, Alt+←/→, selection collapse to near edge | Nothing |
| ↑/↓ by **visual** line, using the previous frame's layout | Nothing — and note this is the requirement that forced the row-position cache |
| Shift+anything extends from a fixed anchor | Nothing |
| Cmd+A | Nothing |
| Delete by grapheme cluster, not by `char` | Nothing. The spec flags this as a known wrong; Swift's `String` is grapheme-clustered |
| UTF-8 ↔ UTF-16 at the platform edge, snapping to char boundaries | Nothing. Offsets stay inside AppKit; the model only ever sees a `String` |
| IME marked text, underline, no commit until the IME says so | Nothing |
| IME candidate window over the composition start | Nothing — `firstRect(forCharacterRange:)` is implemented |
| Selection drawn *on the shaped line* so it follows a wrap | Nothing — `selectedTextAttributes[.backgroundColor] = selection_bg` |
| Mouse-down places caret, Shift extends, drag extends | Nothing |
| "released outside the window" guard | **Nothing.** AppKit always delivers the mouse-up |

What you *do* write, and it's small:

- **Enter sends, Shift+Enter newlines.** Subclass `NSTextView`, override `doCommandBySelector(_:)`:
  `insertNewline:` → send; `insertNewlineIgnoringFieldEditor:` → `super`. AppKit already maps
  Shift+Return to the second selector, so you never look at modifier flags.
- **Escape.** `cancelOperation(_:)` → interrupt the turn if one is running, else resign first
  responder back to the tab strip.
- **The non-blinking 1.5pt caret.** Override `drawInsertionPoint(in:color:turnedOn:)` and fill a
  widened rect; override `updateInsertionPointStateAndRestartTimer(_:)` to call
  `super.updateInsertionPointStateAndRestartTimer(false)` so it never blinks.
- **Grow 1→8 lines then scroll.** Report `intrinsicContentSize` from the layout manager's used rect,
  capped at `8 × lineHeight + padding`, and let the enclosing scroll view take over above that.
- **`composer_border_active`.** spec §13.7 lists the focus ring as intended-but-missing. It's now a
  `.border` keyed off `isFirstResponder` — fix it on the way past.

**One semantic you should deliberately drop**: spec §9.6's three-class word boundaries (`space` / `word` /
`punctuation`, so `foo.bar` steps in three). AppKit's own word movement differs slightly. The stated
*goal* of that rule was "the way every other field on the platform does" — so take the platform's
answer and delete the rule. If measurement later says AppKit is wrong for code-ish text, override
`moveWordForward:` / `moveWordBackward:` then, not now.

---

## 4. What else you stop writing from scratch

| Today | In Swift | Deleted |
|---|---|---|
| Nine Lucide SVGs, `rust-embed`, `assets.rs`, `AssetSource`, and the "`Svg` doesn't inherit `text_color`" trap | **SF Symbols.** `sidebar.left`, `chevron.right`, `xmark`, `plus`, `gearshape`, `globe`, `rectangle.split.2x1`, `rectangle.split.1x2` | `assets.rs`, the dependency, the whole icon-colour class of bug |
| The rename field: a `String`, a caret pinned to the end, no selection/clipboard/IME | `TextField` + `.focused` + `onSubmit` + `.onExitCommand` | spec §6.5's entire "deliberately minimal editor" caveat |
| `.truncate()` doesn't work under `flex_1`; use a `flex_1 min_w(0) overflow_hidden` wrapper around a `w_full` `text_ellipsis().line_clamp(1)` | `.lineLimit(1).truncationMode(.tail)` | The workaround *and* its twin in the pane header |
| "A pane's title must not be `flex_1`" — the measure cache trap | Intrinsic sizing + `Spacer()`, which is what the design wanted anyway | The trap; **keep the design** |
| `Styled` has `invisible()` but no `visible()`; animate `text_color` from transparent | `.opacity` | — |
| Two drags share one guard: no mouse-up arrives outside the window, so the next move without the button ends it | `DragGesture` always delivers `.onEnded` | The guard, in both drag sites |
| `request_animation_frame` panics outside a render pass → the `settle()` / `advance()` split, and *every event-path method takes no `Window` at all* so it can't reach it | `withAnimation` | The structural split **and** the `SIGABRT` it was preventing |
| Transcript text can't be selected or copied (spec §13.3) | `.textSelection(.enabled)` | An open item, closed |
| One `Entity`, because `ElementInputHandler::new` takes one and a text field therefore can't be a plain struct — and the resulting "only panes become entities, and the split tree keeps `PaneId`s not handles" design | `@Observable` classes nest freely | The constraint. **Keep the design** — see plan §5 |
| Per-pane repaint isolation, engineered so a streaming delta doesn't invalidate the sidebar | `@Observable` tracks per-property reads; a `Transcript` mutation invalidates only views that read it | The engineering; you keep the property |

Estimated line count: **~7.0k Rust → ~3.5–4k Swift.** That is a guess from the module table, not a
measurement, but the shape of it is safe: `split.rs` and `transcript.rs` come across at full size,
`protocol.rs` roughly halves, `theme.rs` roughly halves, and `composer.rs` plus most of `agent.rs`
go to zero.

---

## 5. What translates unchanged — and must stay pure

spec §14 already identifies ~2.4k lines with no UI framework in them. **Port these first, with their
tests, before you open a window.** They are the part of the app that is actually specified, and they
will compile and pass in a command-line Swift package with nothing else built.

| Rust | Swift | Notes |
|---|---|---|
| `split.rs` (640) | ~1:1 | `enum Node { case leaf(PaneId); indirect case split(SplitId, Axis, CGFloat, Node, Node) }`. A value type, so undo/persistence later is free. The 11 tests port mechanically |
| `transcript.rs` (496) | ~1:1 | The reducer stays a pure function over blocks; the *container* becomes `@Observable`. Keep `apply(_:)` total — spec §10's "every event does something sensible whatever state it arrives in" is the whole contract |
| `protocol.rs` (682) | ~350 | See below |
| `composer.rs` (585) | **0** | plan §3. Its spec §9.6 semantics remain the acceptance criteria for the `NSTextView` |
| zoom stepping, tab-selection stepping, slide interpolation, nearness, content-header inset | free functions, unchanged | Small, tested, and each one is a place a port silently drifts |

**The one thing to get right in `protocol.rs`:** spec §10's rule is *"an unknown method, an unknown event
kind, or a malformed line is ignored, never an error."* `Codable` throws by default and that fights
the rule. Don't decorate `Codable` with `try?` everywhere. Decode into a permissive
`enum JSONValue: Decodable` once, then hand-map to `Incoming` with `decodeIfPresent`-shaped lookups
that return `nil` rather than throwing. One `try?` at the line boundary, everything below it total.
That is both shorter than the Rust and closer to the stated rule.

**Keep the `PaneId`-not-handle design** even though `@Observable` removes the reason for it. The
reason it was worth having was never gpui's entity system — it is that `split.rs` has no framework
import and eleven tests that need no window. That property is the whole reason the split tree is
trustworthy, and it survives only if you keep the tree holding ids.

---

## 6. Where Swift is worse, and what to do

### 6.1 Zoom — the one real regression

gpui's `set_rem_size` is a single number per window that rescales the entire tree. **Swift has no
equivalent.** `@ScaledMetric` is tied to Dynamic Type, not a free knob, and `.scaleEffect` rasterises
text at the wrong size.

Do the obvious thing and accept it: put a `Metrics` value in the environment and read every dimension
through it.

```swift
struct Metrics: Sendable {
    var scale: CGFloat = 1.0                       // the zoom rung
    func pt(_ v: CGFloat) -> CGFloat { v * scale } // points → resolved
    var text: CGFloat { pt(13) }
    var rowHeight: CGFloat { pt(30) }
    // …every constant from theme.rs lands here as a computed property
}
```

This is **exactly the discipline `theme::pt()` already imposes**, so it is close to a wash in
practice — the cost is that it's a convention rather than something the framework enforces. Two
things make it stick: put the *unscaled* constants in a separate namespace (`Fixed.headerHeight = 40`)
so the type system tells you which band you're in, and keep the four unscaled cases from spec §3 of the
spec exactly as they are — the 40px header rows, the window bounds, the drag deltas, the resize
handle. Nothing in Swift changes why those must not scale, because the traffic lights still ignore
your zoom.

Text scales correctly here (`Font.system(size: m.text)`) and stays sharp, which is the property
`.scaleEffect` would have lost.

### 6.2 Compile-time invariants become tests

spec §5's four `const _: () = assert!(...)` checks — `PANE_GAP ≥ RESIZE_HANDLE` and friends — have no
clean Swift equivalent over computed constants. Move them into a single `MetricsInvariantTests` case.
This is a genuine downgrade from "breaking one fails the build" to "breaking one fails a test run";
it is small, and worth noting in the file next to the constants so the intent survives.

(One of the four, `PANE_GAP ≥ RESIZE_HANDLE`, exists only because a native browser overlay could
swallow the sidebar drag. plan §2 kills that reason. Keep the assert, rewrite its comment.)

### 6.3 Linux goes away

The spec says the shell has been run on both macOS and Linux, and every platform difference is a
runtime `cfg!` so both arms type-check. A Swift port ends that, permanently. spec §13.1 notes Linux
"has no path here at all" for the browser anyway, so the cross-platform story was already going to
break at the feature that matters most — but this should be a decision someone makes out loud, not
something discovered in month two.

### 6.4 Kill-on-drop is not free

`Command::kill_on_drop(true)` is doing real work in `host.rs`: if prose dies for any reason, no agent
outlives it. `Foundation.Process` does **not** terminate its child on dealloc. You need all three of:

- `terminate()` in the session's `deinit` and on explicit close,
- `NSApplicationDelegate.applicationWillTerminate` sweeping the session table,
- a `signal`/`atexit` handler for the crash path, or a `dispatch_source` process watchdog.

This is one of very few places where Rust's ownership was buying a safety property for free. Budget
for it and test it by `kill -9`-ing the app.

### 6.5 Measured layout needs manual arithmetic, not stacks

spec §5's acceptance criteria are exact numbers (`213.5`, `240`, `233`, `(97.5, 19.5)`, `48`). SwiftUI's
stack layout is predictable but not *arithmetic* — a `Spacer` plus padding will land near those
numbers, not on them. For the two places the numbers are load-bearing:

- **The trailing/leading columns** (`TRAILING_CENTER_FROM_RIGHT = 26.5`, `LEADING_CENTER_FROM_LEFT = 26`)
  — keep them as explicit padding computed from the same constants, exactly as today. They already
  are arithmetic; don't let a `Spacer` take over.
- **The tiling** — do not express it as nested `HStack`/`VStack` with `.layoutPriority`. Take
  `Split.rects()`, inset each unit rect by 4 and the container by 4 (spec §7.2's note: a Swift port doing
  manual frame arithmetic can simply inset, because the wrapper-vs-padding trap is a gpui artefact),
  and place with `.frame(width:height:).position(x:y:)` inside a `GeometryReader`, or a custom
  `Layout`. This keeps `rects()` as "the single answer to where a pane is", which spec §7.2 correctly
  identifies as the property that stops the tiling, the divider strips and directional focus from
  disagreeing.

Measurement stays the check, and the method is unchanged: 1× display, `screencapture -x -o -t png`,
measure don't eyeball.

### 6.6 Transcript selection is per-block, not continuous

`.textSelection(.enabled)` gives you selection and Cmd+C inside each block. Dragging a selection
*across* blocks in a `LazyVStack` does not join up. If continuous whole-transcript selection turns
out to matter, that is an `NSTextView`-backed transcript with an attributed string, which is a much
bigger commitment — so ship per-block first and see whether anyone asks.

---

## 7. Animations — better, with one thing to watch

spec §14's invariant is *"an animation must be interruptible mid-flight and must resume from wherever it
currently is"*, which is what keeps an interrupted selection slide and its travelling colour correct.
SwiftUI retargets a running animation from its current value by construction, so the invariant holds
for free and the `settle()` / `advance()` split disappears entirely.

The 180ms sidebar collapse is a plain `withAnimation(.easeOut(duration: 0.18))` on the width, with
the spec §6.1 structure preserved: an `overflow: hidden` box of the animated width containing a child
pinned at the full resting width and offset by `width − resting`, so the panel **slides away rather
than squeezing**. In SwiftUI that's a `.frame(width: animated).clipped()` around a
`.frame(width: resting, alignment: .leading).offset(x: animated - resting)`.

**The one thing to watch is nearness.** spec §6.3 derives each row's colour from the *live* highlight
offset, so the blue travels with the box. SwiftUI won't hand you a mid-flight interpolated value by
default. Two options:

1. **Animate each row's colours with the same 140ms curve** as the highlight's offset. Both retarget
   together on interruption, so adjacent moves look identical to today. The difference: on a
   multi-row jump, rows the highlight *passes over* no longer light up in transit. Simpler, and
   arguably what you want.
2. **Keep nearness exactly.** Drive the offset through a custom `Animatable` `ViewModifier` on the
   list container whose `animatableData` is the highlight top; SwiftUI interpolates it and the
   modifier's body sees the current value, which you pass down to the rows as a plain parameter.
   Every row re-renders per frame, which at tab-strip scale is nothing.

Start with (1). Go to (2) if the long-jump case reads wrong. Do **not** try to do it with a `Timer`
and elapsed-time math — that's porting the gpui workaround, not the requirement.

---

## 8. The host, in Swift concurrency

`host.rs` is 599 lines of smol tasks, and spec §1 records that the uncommitted branch is currently failing
partly on "one non-`Send` future". Swift's actor model makes that class of problem declarative rather
than a fight:

```
@MainActor  final class Workspace      // all UI state, spec §14's single owner
actor       SessionRegistry            // the session table, tokens, backlogs, outbound queues
            AsyncStream<String>        // one per connection, lines in
```

- **The listener.** `NWListener` with `NWParameters` whose `requiredLocalEndpoint` is
  `NWEndpoint.unix(path:)` is the idiomatic route — *verify that against the SDK before committing
  to it*; the bulletproof fallback is a plain `socket(AF_UNIX, SOCK_STREAM, 0)` + `bind` + `listen`
  driven by `DispatchSource.makeReadSource`. Either way, keep spec §11's properties: directory mode
  `0700`, removed on exit best-effort, and **if the socket cannot be opened the app still runs**
  with empty panes.
- **The handshake.** Unchanged, and it's the security boundary: first line must be `hello` with a
  matching session and token; an `event` or `ask` whose `session` differs from the connection's is
  dropped. Put this in the actor, not in a view.
- **Backlogs.** spec §11's "anything addressed to a session before it connects is queued and delivered on
  its hello" is an `AsyncStream` continuation you don't yield to until hello lands, or just an array.
  Keep it — it closes a race the agent author cannot win.
- **Sessions are `Sendable` ids, views are `@MainActor`.** The weak-handle-to-the-view field in spec §11's
  session struct becomes a `@MainActor` closure or a `WeakBox<AgentPaneModel>`; the actor never
  touches the view, it hands lines across the boundary.

### Stream coalescing: move it, don't delete it

spec §9.2 schedules a single repaint 16ms out and lets further events land in the same one. SwiftUI
already coalesces view invalidation to the display refresh, so the *repaint* half of this is now
free — but **the actor hop is not**. A fast agent doing one `await MainActor.run` per token is the
real cost, not the drawing.

So keep the 16ms window, but move it down a layer: accumulate deltas in the connection actor and
flush to the main actor on a 16ms cadence. spec §9.2's two exceptions survive unchanged and for the same
reason — an **ask** and a **notice** bypass coalescing and go straight across, because both are the
agent asking the user to do something.

---

## 9. Suggested package layout

A SwiftPM package with the model as its own target is what keeps spec §5's purity honest — the
`ProseCore` target simply cannot import SwiftUI, because it doesn't depend on it.

```
Prose/
  Package.swift
  Sources/
    ProseCore/                 # no SwiftUI, no AppKit. The ~2.4k lines from spec §14
      Split.swift              #   from split.rs, 1:1, with its 11 tests
      Transcript.swift         #   from transcript.rs
      Protocol.swift           #   from protocol.rs, ~half the size
      Metrics.swift            #   from theme.rs: dimensions + the zoom ladder
      Palette.swift            #   from theme.rs: colours (see note below)
    ProseHost/                 # Foundation + Network only
      SessionRegistry.swift    #   the actor, the socket, the handshake
      AgentProcess.swift       #   Process + the kill-on-exit machinery of plan §6.4
    Prose/                     # the app
      ProseApp.swift           #   Window scene, NSWindow tweaks, NSVisualEffectView
      Workspace.swift          #   @Observable, spec §14's single owner
      Sidebar/                 #   Header, TabList, TabRow, Footer
      Content/                 #   ContentHeader, Tiling, DividerStrip
      Panes/                   #   PaneChrome, AgentPane, BrowserPane
      Composer/                #   the NSTextView subclass + representable
  Tests/
    ProseCoreTests/            #   the 70 existing tests, ported
```

`Palette` is worth splitting from `Metrics`: colours have no zoom dependency, dimensions have
nothing else. Both come out of today's `theme.rs`, and spec §4's rule — *"one accent means one thing"* —
is worth restating at the top of `Palette.swift` so it survives the port.

---

## 10. Migration order

No incremental path exists — it's a rewrite — but there is a low-risk order that keeps something
working and verifiable at every step.

1. **`ProseCore` + its tests, with no app.** Port `split.rs`, `transcript.rs`, `protocol.rs` and the
   free functions, and get the 70 tests green in a package that has never opened a window. This is
   the part that is actually specified, it is the part a port silently drifts on, and it proves the
   spec is complete before you have spent anything on UI.
2. **The window and the shell.** `Window` scene, `NSVisualEffectView`, traffic lights at (17,13),
   green-button zoom, sidebar with its 180ms collapse and sliding selection, tabs, rename, zoom
   rungs. Stop and **re-measure spec §5's acceptance table** — every number in it, at 1.0× and 2.0×.
3. **The tiling.** Manual frames from `rects()`, divider strips with `.pointerStyle`, drags,
   directional focus. This is where spec §13.9 gets closed: the pointer and keyboard paths have never
   been driven by hand, and now a human can do it in five minutes.
4. **The browser pane.** Before the agent pane, deliberately — it's the cheapest large win, it's a
   `WKWebView` in a representable plus a URL field, and it makes the port visibly worth it while the
   agent work is still in pieces.
5. **The agent pane.** `NSTextView` composer first against a stub transcript, then wire spec §9's blocks,
   follow-on-scroll, and the ask card.
6. **The host.** The actor, the socket, the handshake, process spawning, plan §6.4's kill machinery. And
   write the echo agent — spec §11 notes `agents/echo_agent.py` is the default command and **no such
   script exists in the repo**, which means nothing on the agent side has ever been run end to end.

Step 6 is the one with unknowns in it. Steps 1–5 are translation and assembly.

---

## 11. Decide these before starting

1. **Linux, formally dropped?** (plan §6.3.) It runs there today.
2. **macOS 15 floor, or 14?** 14 costs you `.pointerStyle` (fall back to `NSCursor` + tracking
   areas), `ScrollPosition`, and `.restorationBehavior`. All have workarounds; none are free.
3. **Unsandboxed + notarised direct distribution**, confirmed? It follows from spawning arbitrary
   agent commands, but it rules out the App Store.
4. **Does the browser pane get its own protocol methods now?** (plan §2.) If yes, spec them into
   `product-spec.md` spec §10 before writing `Protocol.swift`, so the core target is written once.
5. ~~**Keep the no-markdown decision?**~~ **Answered: split it.** Inline emphasis is rendered
   (`Markdown.swift`, `ProseText.swift`); structure is not. `AttributedString(markdown:)` made the
   inline half nearly free, and the structural half was never really about cost — it is that code
   already has a path, and a fence would be a second one. The two traps found by running the
   parser rather than reading about it are in spec §9.3.
6. **Per-block transcript selection now, continuous later?** (plan §6.6.)
7. **Nearness: option (1) or (2)?** (plan §7.) Recommend (1), revisit on sight.
