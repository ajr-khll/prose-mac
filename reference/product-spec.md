# prose — product specification

A complete description of what prose is and how it behaves, written from the source as it
stands on the `agent-panes` branch. It is the input to a Swift implementation plan: everything
here is a requirement or an observed behaviour, not an implementation instruction.

Point values are **points at 1.0× zoom**. The development display is 1× (2560×1440), so one
point is one screen pixel there and every number below was measured as well as declared.

---

## 1. What the product is

An **agent multiplexer**. Many agent sessions run side by side; each one is a tab in an
Arc-style vertical strip down the left, and each tab tiles its content area into a tree of
panes. A pane is either an **agent pane** (prose's own chat frontend — a transcript plus a
composer, not a terminal) or a **browser pane**.

Agents are separate processes. prose spawns them, hands each one a socket address and a
session token, and carries line-delimited JSON-RPC between them and their panes. prose has no
idea what a turn is, what a tool is, or what any agent is for; it allocates panes, carries
bytes, and reaps processes.

Two consequences shape everything:

- **prose is a host, not an agent.** The presentation vocabulary (§10) is deliberately generic.
  A coding agent's `Bash(cargo test)` and a research agent's `Searching 40 sources` are the
  same activity row with different text.
- **An agent may be newer than the app.** Any unknown method, unknown event kind, or malformed
  line is *ignored, never an error*, so the two sides can ship independently.

### Current build state (important)

The committed shell — window, sidebar, tabs, zoom, tiling, dividers — is finished, measured,
and has been run on macOS and Linux. The agent-pane work (`agent.rs`, `composer.rs`,
`transcript.rs`, `protocol.rs`, `host.rs`) is uncommitted and **does not currently compile**:
6 errors, all mechanical (two stale call signatures, a `Sum<Pixels>` bound, a missing
workspace method, one non-`Send` future). So §§7–11 describe a *design that has been written
out in full and unit-tested in its pure parts*, not a shipped behaviour. The pure logic has
70 passing tests across composer (17), protocol (16), transcript (13), workspace (12), split
(11), assets (1).

---

## 2. Window and chrome

| | |
|---|---|
| Initial size | 1100 × 720, centred on the active display |
| Minimum size | 480 × 360 |
| Title | "Prose" |
| App id | `prose` |
| Windows | Exactly one. No multi-window, no window restoration, no persistence of any kind |

**macOS**: the titlebar is transparent and prose draws its own chrome under it. Traffic lights
are positioned explicitly at **(17, 13)** (top-left of the close button). The window background
is *blurred* — macOS blurs whatever is behind the window, and prose paints one translucent dark
wash over that. The green button is forced back to **Zoom** (fill the screen, keep the menu
bar) rather than Enter Full Screen, by clearing `NSWindowCollectionBehaviorFullScreenPrimary`
and `…Auxiliary` and setting `…FullScreenNone`; this also disables the Window-menu item and its
shortcut.

**Linux**: server-side decorations (the desktop environment draws its own title bar above
prose), and the window background is plain transparent rather than blurred.

These are the only two platform differences in chrome, and both are expressed as runtime
`cfg!` branches rather than conditional compilation, so both arms always type-check.

---

## 3. The scaling model

**Points scale; pixels don't.** Every dimension is a point value that reaches the view tree as
a rem, and one number per window (the rem size) resolves them all. Changing that number
rescales the entire UI — that is the whole zoom feature.

- `BASE_REM = 16` — the pixel size of one rem at 1.0×.
- Zoom is a **fixed ladder**, not a multiplier, so repeated zooming lands on the same sizes
  every time and never drifts off 1.0: `[0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]`, starting
  at index 2 (= 1.0×). Stepping clamps at both ends rather than wrapping.
- The rem size is set to `BASE_REM × zoom` at the moment the zoom changes, and is window state
  that persists until changed again. It is not re-applied per frame.

**Four things stay in real pixels** because they must line up with something prose does not
control:

1. Window bounds, minimum size, and traffic-light position.
2. **The header row — fixed 40px at every zoom.** macOS draws the traffic lights at a size that
   ignores prose's zoom, so the row that shares their line, and the sidebar toggle in it, must
   too. A toggle that scaled would drift off the lights and at 2.0× would overflow the top of
   the window.
3. The drag-resize delta: pointer positions arrive in real pixels but the sidebar's resting
   width is stored in points, so the delta is divided by zoom.
4. The sidebar resize handle, which straddles the divider — all its terms must share one space.

A Swift port needs the same split: one scale factor applied to a point-based layout, with an
explicitly unscaled band across the top of the window.

---

## 4. Colour

The whole app is one translucent plane with a single accent. There is no light mode; nothing
adapts to the system appearance.

Values are `#RRGGBB` with an optional trailing alpha byte.

### Surface
| Token | Value | Use |
|---|---|---|
| `window_bg` | `#1C1C20CC` | The single wash over the system blur. The alpha byte is the "how see-through is the app" knob |
| `divider` | `#FFFFFF14` | Hairline between sidebar and content |
| `divider_active` | `#9AA2FF99` | The same hairline while hovered or dragged |
| `separator` | `#FFFFFF14` | The soft line above the settings row |
| `text` | `#E2E2E6` | Default text |

### Tabs
| Token | Value | Use |
|---|---|---|
| `tab_hover_bg` | `#FFFFFF08` | Row hover wash |
| `tab_active_bg` | `#8F98FF14` | Selected row's wash — a blue cast, not a neutral grey |
| `tab_active_border` | `#9AA2FF3D` | Selected row's border |
| `chip_bg` | `#FFFFFF08` | The rounded square holding the `>` glyph |
| `chip_active_bg` | `#9AA2FF33` | …when selected |
| `chevron` | `#8A8A92` | The `>` glyph |
| `chevron_active` | `#8F9BFF` | …when selected. Pushed further into the blue than the reference, so the selected tab reads at a glance |
| `rename_bg` | `#00000059` | The inline rename field |
| `rename_border` | `#9AA2FF8A` | …its border |

### Panes
| Token | Value | Use |
|---|---|---|
| `pane_bg` | `#FFFFFF08` | A pane's plane, slightly proud of the window wash so the tiling reads where two panes meet |
| `pane_border` | `#FFFFFF14` | Resting border |
| `pane_active_border` | `#9AA2FF5C` | Focus ring |
| `pane_header_bg` | `#FFFFFF08` | Header strip |
| `pane_title` | `#8A8A92` | Pane title and kind icon |
| `pane_placeholder` | `#6A6A72` | Body text in an empty pane |

### Inside an agent pane
| Token | Value | Use |
|---|---|---|
| `user_bubble_bg` | `#FFFFFF0D` | The user's own messages |
| `activity_label` | `#B4B4BC` | An activity's label |
| `activity_detail` | `#7A7A82` | Its subtitle, and the pane header's status text |
| `activity_running` | `#8F9BFF` | Status dot, running |
| `activity_ok` | `#5F8F6A` | Status dot, succeeded |
| `activity_error` | `#C06A6A` | Status dot, failed |
| `code_bg` | `#00000040` | Code attachment |
| `code_border` | `#FFFFFF0F` | …its border |
| `code_text` | `#C8C8D0` | …its text |
| `notice_text` | `#C08A6A` | A failed turn, or the agent's process going away |
| `ask_border` | `#9AA2FF52` | The card the agent stops to ask a question with |
| `ask_bg` | `#8F98FF14` | …its wash |
| `choice_bg` | `#FFFFFF0F` | An answer button |
| `choice_hover_bg` | `#9AA2FF33` | …hovered |
| `choice_chosen_bg` | `#9AA2FF47` | …the answer that was given |
| `composer_bg` | `#00000038` | The input box |
| `composer_border` | `#FFFFFF14` | …its border |
| `composer_border_active` | `#9AA2FF5C` | *Declared but never applied — see §13* |
| `composer_placeholder` | `#6A6A72` | Placeholder text |
| `caret` | `#9AA2FF` | The caret |
| `selection_bg` | `#9AA2FF47` | Selected text |

### Icon buttons
| Token | Value |
|---|---|
| `icon` | `#8A8A92` |
| `icon_hover` | `#E2E2E6` |
| `icon_hover_bg` | `#FFFFFF14` |

### The rules behind the palette

- **One accent means one thing.** The periwinkle `#9AA2FF` family is "this is the active one" —
  the selected tab's border and chip, the focused pane's ring, the caret, the text selection,
  the ask card, the live divider. Nothing else is ever blue.
- **State is carried by the smallest element that can carry it.** An activity's success or
  failure is a 5pt dot, not a recoloured row, because a row that changed colour wholesale would
  pull the eye away from the prose around it.
- **The user's messages are set apart by a card, not by a colour**, so a long prompt stays as
  readable as the reply to it.
- **Borders are permanent and only ever recolour.** Tab rows carry a transparent 1pt border and
  panes carry a real one, so selecting or focusing changes a colour instead of adding a line and
  shifting contents by a pixel.
- **Colour is blended, not switched.** See the selection highlight, §6.3.

---

## 5. Dimensions

All in points unless marked *px*.

### Sidebar
| Name | Value |
|---|---|
| Resting width | 240 |
| Minimum / maximum drag width | 180 / 420 |
| Header height | **40 px** (fixed at every zoom) |
| Footer height | 32 |
| Resize handle width | 6 |
| Row inset from left edge | 7 |
| Row inset from right edge | 10.5 (`7 × 1.5`), so the strip is not crowded against the divider |
| Row padding (horizontal) | 7 |
| Row border | 1 (permanent, transparent when unselected) |
| Row height | 30 (border box — the border is inside it) |
| Row gap | 2 |
| Row pitch | 32 (`height + gap`) — the distance the highlight travels for one row |
| Row corner radius | 7 |
| Chip size / radius | 22 / 7 |
| Chevron glyph | 11 |
| Close glyph / hit box | 12 / 16 (`glyph + 4`) |
| Icon-button glyph / hit box | 14 / 22 |
| Header button cap | 32 px — the largest the fixed header row can hold |
| Body text size | 13 |
| Footer separator inset from divider | 6 |

### Derived columns
- `TRAILING_CENTER_FROM_RIGHT = 10.5 + 1 + 7 + 8 = 26.5` — one column for everything hanging
  off the right of the sidebar. At 240 wide that is **x = 213.5**: the header's `+` and every
  tab's `×` share it.
- `LEADING_CENTER_FROM_LEFT = 7 + 1 + 7 + 11 = 26` — the matching column on the left, shared by
  the tab chips and (on macOS) the settings icon.
- Sidebar toggle centre x: **98** on macOS (clear of the traffic lights), `LEADING_CENTER_FROM_LEFT`
  = 26 elsewhere, where the corner is prose's own and a gap would just be a hole.
- Settings centre x: `LEADING_CENTER_FROM_LEFT` on macOS, `× 0.75` = 19.5 on Linux.

### Panes
| Name | Value |
|---|---|
| Content header height | **40 px** (fixed, level with the sidebar header) |
| Gutter between panes, and around the tiling | 8 |
| Pane corner radius | 8 |
| Pane border | 1 (permanent) |
| Pane header height | 26 |
| Pane header horizontal padding | 8 |
| Pane kind icon | 12 |
| Minimum pane width / height | 160 / 96 |

Three invariants are compile-time assertions, not tests — breaking one fails the build:

1. `PANE_GAP ≥ RESIZE_HANDLE` — the gutter must clear the sidebar's grab strip. The original
   reason was that a browser pane would be a native view painted over everything, which a
   narrower gutter would let cover part of the strip and swallow the drag. **That reason is
   retired**: in AppKit the browser pane is an ordinary subview and z-order is normal. The
   constant stays because the gutter should clear the strip anyway.
2. `PANE_MIN_HEIGHT > PANE_HEADER_HEIGHT` — a pane dragged to its minimum must still show the
   header its buttons live in.
3. `PANE_MIN_WIDTH > CLOSE_BOX × 6 + PANE_HEADER_PADDING_X × 2` — and be wide enough for the
   buttons that header carries. Six, not three: a browser pane's header also holds back,
   forward and reload, and it is the widest header that has to fit.
4. `BUTTON_SIZE ≤ CONTENT_HEADER_HEIGHT` — the toggle has to fit the row reserved for it.

### Inside an agent pane
| Name | Value |
|---|---|
| Transcript / composer margin | 10 |
| Gap between blocks | 10 |
| Line height | 1.45 × text size (= 18.85 at 1.0×). Looser than default, because a pane is narrow and wrapped text needs the air |
| User bubble padding | 9 horizontal, 6 vertical; radius 7 |
| Activity dot / gap after it | 5 / 7 |
| Code padding / radius / text size | 8 / 6 / 12 |
| Ask card padding / radius | 9 / 7 |
| Choice button height / padding-x / radius | 24 / 9 / 6 |
| Composer padding | 8 horizontal, 6 vertical; radius 8; border 1 |
| Composer maximum height | 8 lines, then it scrolls instead |
| Caret width | 1.5 |
| Stream repaint coalescing | 16 ms |

### Measured acceptance criteria (at 1.0×)

Re-measure these after any layout change. The display is 1×, so measurement — not eyeballing —
is the check; eyeball comparisons have missed real bugs twice.

| Thing | Expected |
|---|---|
| Header `+` and every tab `×` | share centre x **213.5** |
| Sidebar width / divider position | **240** |
| Footer separator right end | **233** (6pt short of the divider) |
| Toggle centre | **(97.5, 19.5)** — on the traffic lights' line |
| At 2.0×: divider | **480**, traffic lights unmoved |
| Gutter around the tiling, and between any two panes | **8** on all four sides |
| First pane's top border | **48** (40px header + 8pt gutter) |

---

## 6. The sidebar

Three stacked sections in a fixed-width column: header, scrolling tab list, footer. A 1pt
`divider` hairline sits to its right, outside it.

### 6.1 Collapse

Toggling the sidebar animates its width between the resting width and 0 over **180 ms**,
ease-out cubic (`1 − (1 − t)³` — quick to leave, gentle to settle, which is what makes a panel
feel like it has weight).

The contents **do not reflow**. The panel is an `overflow: hidden` box of the animated width,
containing a child pinned at its full resting width and offset by `width − resting`, so the
sidebar *slides away to the left* rather than squeezing. When width reaches 0 the sidebar and
its divider are not rendered at all.

The **toggle button is anchored to the window, not to the panel**, so it holds its place beside
the traffic lights whether the panel is out or in. Once the panel has gone the toggle is over
the content area, which is why the content header insets itself (§7.1).

### 6.2 Header

40px tall, fixed. Holds only the new-tab `+` button, right-aligned onto the shared `×` column.
Its right padding is `TRAILING_CENTER_FROM_RIGHT × zoom − BUTTON_SIZE × scale / 2`, all in real
pixels — a scaled padding would not agree with an unscaled button.

The button grows with zoom only as far as the fixed row can hold it:
`scale = min(zoom, 32 / 22)` ≈ 1.4545, which bites above roughly 1.45×. Its *centre* still
rides the scaled `×` column, so the two stay aligned.

### 6.3 The tab list and its sliding selection

A scrolling column, inset 7 left and 10.5 right, rows gapped by 2.

**The selection is one element, not a per-row border.** The selected tab's border and blue wash
are a single absolutely-positioned box in the list, rendered *before* the rows so it sits behind
them. It animates its `top` between row offsets (`index × 32`) over **140 ms**, ease-out cubic —
quicker than the sidebar, because a selection should feel like a response, not like scenery.

Each row then derives a **nearness** from how close the highlight currently is:

```
nearness(index) = 1 − clamp(|highlightTop − index × ROW_PITCH| / ROW_PITCH, 0, 1)
```

and blends its own accent colours by it — chip background `chip_bg → chip_active_bg`, chevron
`chevron → chevron_active`. So the blue travels *with* the box rather than snapping on once it
lands. Deriving it from the live offset rather than a remembered from/to pair is what keeps an
interrupted slide correct: the colours simply follow the highlight wherever it is.

A row's hover wash is suppressed once `nearness ≥ 0.5`, since hovering a row the highlight has
nearly reached would only muddy the blue.

**Every selection change goes through one function.** Clicks, arrow keys, opening a tab and
closing one all funnel there, so none of them can bypass the animation. A highlight can only
travel *between* two rows: arriving from nowhere or leaving for nowhere is a cut, not a slide.

When a tab is closed, the highlight's current position is read *before* the rows below shift up
under it, so the slide starts from where the user could see it.

### 6.4 A tab row

Left to right, 4pt gaps, inside a 30pt row with 7pt padding and a 7pt radius:

1. **The console chip** — a 22pt rounded square (radius 7) holding an 11pt `>` chevron. Borrowed
   from the reference's terminal-prompt motif. Both colours blended by nearness.
2. **The title** — 13pt, ellipsised to one line. It is *not* laid out as a simple flexed text
   node; it is a `flex: 1; min-width: 0; overflow: hidden` wrapper containing a full-width
   clamped line. (In gpui this was required to make the ellipsis appear at all; in Swift it is
   simply the correct way to size it.)
3. **The close `×`** — a 16pt hit box around a 12pt glyph, radius 4, glyph brightening on hover
   of the button itself rather than of the row. **Always visible**, matching the reference, not
   hover-revealed.

Interaction:

- Single click anywhere in the row selects the tab (and commits any rename in progress).
- Double click on the **title** starts a rename; a single click on the title is left alone so it
  bubbles up to the row.
- Clicking `×` closes the tab and must not fall through to also select it.

### 6.5 Renaming

A deliberately minimal inline editor: a string buffer, a caret pinned to the end, and nothing
else — no selection, no clipboard, no IME. (This is the one place where a Swift port gets a
free upgrade: an `NSTextField` covers all of it.)

- Field: height 20 (`ROW_HEIGHT − 10`), padding-x 4, radius 4, `rename_bg`, 1pt `rename_border`,
  overflow hidden. The caret is a 1pt × 15pt bar of `text` colour drawn immediately after the
  buffer.
- **Enter** commits, **Escape** cancels, **Backspace** deletes one character, printable
  characters append. Any keystroke carrying control/platform/function modifiers is ignored, as
  is any character that is a control character.
- **Clicking away commits** — leaving is treated as keeping, because a field that stayed open
  but deaf to the keyboard would be worse.
- An **empty or whitespace-only name abandons the edit** rather than committing, since a row
  with no title would have nothing to click on.
- Starting a rename also selects that tab.
- While a rename is in progress, the rename field owns the keyboard entirely; the workspace's
  own key handling is suppressed.

### 6.6 Footer

A full-width 1pt `separator` hairline, inset 6pt from the right so it does not meet the vertical
divider in a hard corner, then a 32pt row holding the settings button, left-padded so the button
centres on `settings_center_x`. **The settings button does nothing** — there is nowhere for
settings to go yet.

---

## 7. The content area

Everything right of the divider: a fixed chrome row, then the tiling.

### 7.1 Content header

40px tall, fixed at every zoom for the same reason the sidebar's is — it has to stay level with
the traffic-light row across the divider. It shows the **active tab's title**, ellipsised, at
12pt in `pane_title` grey.

Its left padding is `content_header_inset(sidebarWidth, zoom) + 8`, where

```
contentLeft = sidebarWidth > 0 ? (sidebarWidth + 1) × zoom : 0
inset       = max(0, toggleCentreX + BUTTON_SIZE/2 + DIVIDER_GAP − contentLeft)
```

This clears the window-anchored toggle once the sidebar has slid away. The divider hairline is
counted only while the panel is out at all, so the gap does not shift with zoom after it has
gone. Note the inset arithmetic is in real pixels (the toggle does not zoom) while the 8pt
gutter added to it is a point value — deliberate, and worth preserving.

It also keeps the toggle clear of every pane. The original reason — that a browser pane would
be a native view painted over everything and would swallow the toggle's clicks — no longer
applies, since the web view is an ordinary clipped subview. Keeping the toggle clear of the
panes is still right on its own terms.

### 7.2 Tiling

**The pane tree is pure; only the renderer knows about pixels.** Each tab owns a binary tree
whose leaves are pane ids. One function walks it into a list of `(paneId, unitRect)` where both
axes run 0…1, and *that function is the single answer to where a pane is* — the tiling, the
divider grab strips, and the keyboard's focus movement all read it, so they cannot disagree.

Layout: the tiling is an absolutely-positioned stack, each pane placed at its fractional rect.
The 8pt gutter is split in half twice — 4pt of padding on a wrapper *around* the tiling, and 4pt
on each pane cell — so the margin around the outside matches the gap between any two panes.

> It must be a wrapper rather than padding on the tiling itself: absolutely positioned children
> lay out against their container's border box, so padding there would move nothing. A Swift
> port doing manual frame arithmetic can simply inset each rect by 4 and the container by 4.

The content area records its own pixel size each frame, because a divider drag arrives in
pixels and only layout knows how big the area actually is.

### 7.3 The split tree

- A tab starts as a single leaf filling the area.
- **Split** replaces the target leaf with a split node holding the old leaf and a new one, at
  **fraction 0.5**. Row = side by side (vertical divider); Column = stacked (horizontal
  divider). Splitting a pane that is not in this tab is a no-op that reports failure.
- **Close** collapses the split holding the target into its *other* child, so freed space closes
  up rather than leaving a gap. Focus lands on the **first leaf of the survivor**. Closing the
  last remaining pane empties the tree, which is the signal to **close the tab too**.
- **Dividers** are derived from the same walk: each split yields its id, axis, the region it
  divides, and a zero-thickness line in unit space. The renderer gives the line its thickness.
- **Directional focus** (`neighbour(from, direction)`) is worked out **from the laid-out
  rectangles, not by walking the tree** — "the pane to my left" is a question about the screen,
  and a few nested splits in, the tree sibling and the visual neighbour stop being the same
  pane. Candidates are those lying wholly on that side with a shared edge greater than slack;
  **nearest wins, ties go to the longest shared edge**. No neighbour means focus stays put
  (no wrapping).
- Fractional arithmetic uses a slack of `1e-4` when comparing edges that ought to touch, because
  rounding accumulates as the tree deepens.

### 7.4 Divider drags

Each divider gets an invisible grab strip 6pt thick, centred on the line (pulled back by half
its thickness so it straddles rather than starts at it), with a 1pt hairline down its middle
that is **invisible until hovered**, then `divider_active`. Cursor is col-resize or row-resize
by axis.

Dragging sets the split's fraction from the pointer delta as a fraction of *that split's own
region* (not the whole tab):

```
fraction = clamp(startFraction + delta / parentPx,  minPx/parentPx,  1 − minPx/parentPx)
```

with `minPx = PANE_MIN_WIDTH or PANE_MIN_HEIGHT, scaled by zoom`. If the region is too small to
hold two minimums, the fraction pins to **0.5** rather than returning something outside 0…1 and
inverting the panes.

Unlike the sidebar drag there is no zoom to divide out here: the pointer and the recorded
content bounds are both already in real pixels, and only the minimum is a point measurement.

### 7.5 Sidebar drags

The sidebar's own grab strip is the same shape: 6pt wide, centred on the divider at
`width + 0.5`, absolutely positioned over everything so it can straddle the line without taking
part in layout. Its hairline lights up on hover *and stays lit for the whole drag*, so the
sidebar advertises that its edge can be moved.

Dragging sets `restingWidth = clamp(startWidth + delta/zoom, 180, 420)`, cancels any collapse
animation in flight (direct manipulation must not fight an animation), and forces the sidebar
open.

**Both drags share one guard**: the button can be released outside the window, where no mouse-up
arrives, so the next mouse-move without the left button held ends the drag.

---

## 8. A pane

A rounded 8pt frame, `pane_bg`, with a **permanent** 1pt border that is `pane_border` normally
and `pane_active_border` when the pane is focused — recoloured, never added, so focusing cannot
shift contents by a pixel. Contents are clipped to the radius.

### Header (26pt, padding-x 8, 4pt gaps, `pane_header_bg`)

1. **Kind icon**, 12pt, `pane_title` grey — a bot for an agent pane, a globe for a browser pane.
2. **Title** — what the agent calls itself, falling back to "Agent" / "Browser". 12pt,
   `pane_title`.
3. **A flexible spacer.**
4. **Status** (agent panes only) — `thinking…` while a turn is running, otherwise the agent's
   status field values joined with ` · `. 11pt, `activity_detail`. Nothing when there is neither.
5. **Back**, **forward**, **reload/stop** (browser panes only) — three more of the same hit
   boxes, before the three below. Back and forward dim to 35% rather than disappearing when
   there is nowhere to go, so the header keeps its shape as a page gains and loses history.
   Reload is one button, not two: its glyph is a cross while the page is loading and a
   clockwise arrow otherwise, since which action is wanted is never ambiguous.
6. **Split-right**, **split-down**, **close** — three 16pt hit boxes with 12pt glyphs, radius 4,
   hover background `icon_hover_bg`, glyph brightening to `icon_hover`.

> Two layout traps worth carrying across as *design* rather than as workarounds: the title and
> the status are sized to their text with a spacer doing the pushing, never flexed. In gpui a
> flexed text child measured against a pane that had no width on its first pass and the result
> was cached, so every title in the window truncated to the same few characters. A Swift port
> should still prefer intrinsic sizing plus a spacer here — it is also simply what the design
> wants, since the status must never be squeezed out by a long title.

Header buttons are sized in **points**, unlike the window-chrome buttons, because nothing in a
pane header has to line up with the traffic lights — these are content and should grow with
zoom.

The header is the one part of a pane guaranteed to still take a click whatever the body is
doing — which is why the browser controls live there rather than beside the URL field, and
why the loading hairline is drawn along its bottom edge rather than over the page.

### Body

An agent pane renders its own transcript and composer (§9).

A browser pane renders a **URL field**, then any **failure**, then the page:

- The URL field is a single line, styled like the composer and sized by the `address_*`
  tokens. It does not wrap; a long URL scrolls sideways. Enter loads, Escape hands the
  keyboard back to the tab strip, Cmd+L focuses it and selects everything in it.
- A bare host gets a scheme. Loopback, `.local`, and any name with a port but no dot get
  `http://`, because those are dev servers; everything else gets `https://`. Only `http`,
  `https`, `file` and `about` are accepted as *typed* schemes — anything else is treated as a
  host instead, which is both what makes `localhost:3000` work (a scheme is
  indistinguishable from a host with a port) and what keeps `javascript:` out of the field.
  Nothing is handed to a search engine; text that is not a URL says so.
- A failure — an unloadable address, a refused connection, a bad certificate, a web content
  process that died — is one line in `notice_text` under the field, cleared by the next page
  that commits.
- The page itself fills the rest. Until something **commits**, prose covers it with an opaque
  `page_base`: an empty `WKWebView` draws its own white page, and a load that fails never
  uncovers it. A pane that has been asked for nothing still shows a centred `No page yet` in
  `pane_placeholder`.

### Interaction

Clicking anywhere in a pane focuses it, and focus moves *into the field* where there is one, so
the caret lands where the typing will go: an agent pane's composer, or a browser pane's URL
field when it has no page yet. A browser pane that **has** a page takes nothing — the content
area holds the keyboard on its behalf, which is what leaves the plain arrows moving pane focus
(§12). Clicking the page itself focuses it through the responder chain, and the pane focuses
because the page did.

Stepping focus with the keyboard does the same thing as clicking. It must not merely recolour
the border and leave the keyboard in the pane being left.

Split and close buttons stop propagation, so clicking close does not also focus the pane that
was just closed.

---

## 9. The agent pane

A vertical stack: a scrolling transcript that takes the remaining height, and a composer pinned
below it. Margins are 10pt on both, and blocks are gapped by 10pt. Line height is 1.45×.

### 9.1 Scroll and follow

The transcript **follows the newest block** by default. Any scroll-wheel event clears follow —
any scroll is the user saying they want to read something other than the bottom, and streaming
must not yank the view away. Follow is re-armed by: sending a message, an `ask` arriving, or a
notice arriving.

### 9.2 Streaming and repaint coalescing

An agent can emit tokens far faster than the display can show them. Rather than throttling by
dropping notifications — which risks losing the last one and leaving a half-drawn word on screen
— an event schedules **a single repaint 16 ms out**, and further events land in the same one.
Something always renders within a frame of the last event, and the cost stays flat however fast
the stream runs or however many panes are streaming at once.

Two things bypass coalescing and repaint immediately, because both are the agent asking the user
to do something: an **ask**, and a **notice**.

### 9.3 Blocks

An empty transcript shows `No session yet` in `pane_placeholder`.

**User message** — full-width card: `user_bubble_bg`, radius 7, padding 9 × 6. No colour change
to the text.

**Agent message** — plain prose in `text`, no card, no decoration. **Markdown *structure* is
deliberately not parsed**: headings, bullet and numbered lists, tables, block quotes and fenced
code blocks are rendered as the characters the agent typed. Code arrives as its own attachment
event with its own type; inventing a second path for fenced blocks inside prose would mean two
ways to say the same thing. *prose renders paragraphs; structure is the agent's to declare.*

**Inline emphasis is drawn**, which is a narrower thing: `**strong**`, `*emphasis*`,
`` `code spans` ``, `~~strikethrough~~` and links become styling rather than punctuation. The
model emits them in the first sentence of almost every reply, so the alternative was not prose
without emphasis but prose with its asterisks showing. Three rules make it safe to do while a
message is still streaming:

- **A message containing a fence is not parsed at all.** With block syntax off, the parser reads
  a fence as one long inline code span — language tag glued to the first line, newlines
  flattened — which is worse than the literal backticks. Fenced text renders exactly as before.
- **Underscores are never emphasis.** `__init__.py` is legal strong emphasis by CommonMark's
  rules, and a pane discussing code would eat four characters of a filename. `*emphasis*` is the
  spelling that works; `_emphasis_` renders as typed.
- **A parse that fails yields the original characters.** Every message is malformed markdown
  while it streams — an opening `**` arrives well before its partner — so the degraded path is
  every message in the pane on its way past.

A code span takes the attachment's monospaced face, `code_text` and `code_bg`, one point smaller
than the prose around it. A link is underlined in the prose colour and **never takes the
accent**: §4's first rule is that the green means "this is the active one".

**Activity** — a baseline-aligned row at 12pt with a 7pt gap: a 5pt circular dot coloured
`activity_running` / `activity_ok` / `activity_error`, the label in `activity_label`, then an
optional detail in `activity_detail`.

**Attachment** — if its type is `code`: a full-width block, radius 6, `code_bg`, 1pt
`code_border`, 8pt padding, monospaced (`SF Mono` on macOS), 12pt, `code_text`. Any other type,
including one this build has never heard of, renders as **plain prose rather than vanishing** —
the same forgiveness the parser applies.

**Thinking** — the agent reasoning rather than speaking. A disclosure line reading `Thinking`
while it streams and `Thought` once it has closed, in `thinking_label`; the reasoning itself 12pt
in `thinking_text`, indented 10pt. It **opens itself while it streams** — a turn in flight is the
one time reasoning is the most interesting thing on screen — and folds away as the turn ends,
because it is not what the reader came back for once there is an answer above it. It is kept, not
discarded: what an agent thought is the most useful thing in a pane when the answer is wrong.

**Notice** — a failed turn or the agent's process going away: 12pt in `notice_text`.

**Ask card** — full width, `ask_bg`, 1pt `ask_border`, radius 7, 9pt padding, 9pt internal gaps,
prompt text first. Then, independently:

- *If it has choices*: a wrapping row of buttons, 7pt gaps. Each is 24pt tall, 9pt padding-x,
  radius 6, 12pt text, `choice_bg`, hovering to `choice_hover_bg` with a pointer cursor. Once
  answered, the chosen button takes `choice_chosen_bg`, **all buttons remain visible** so the
  choice stays legible, and none of them hover or take a click any more.
- *If it was answered by typing*: the answer in `activity_detail` beneath the buttons. An answer
  that matches a choice is not repeated — the lit button already says it.

**Choices and a typed answer are not exclusive.** A question may carry buttons, a free-text
answer, or both; they are two ways of answering one question rather than two kinds of question,
and an agent offering three options and a way to say something else should not have to choose
between drawing the buttons and being answerable in words. The composer always does the typing
half — see §9.5 — so the card never draws a placeholder of its own.

### 9.4 The composer

A rounded 8pt box, `composer_bg`, 1pt `composer_border`, padding 8 × 6, with a text cursor. It
grows with its content from **one line to eight**, then scrolls. Empty, it shows `Ask anything…`
in `composer_placeholder` — or, while a question is outstanding, that question's `placeholder`,
falling back to `Answer…`. The composer is where an ask's placeholder is drawn, because it is
where the answer is typed.

The caret is a **1.5pt filled bar** of `caret` colour, painted only while the field is focused.
**It does not blink.** Selected text is drawn as a background run *on the shaped line* rather
than as a separate quad, so it follows text around a wrap correctly.

> The current implementation hand-writes the whole text stack: shaping each newline-separated
> line, stacking the rows, caching where every row landed so clicks and vertical arrows have
> something to hit-test, cutting style runs at selection and IME-composition boundaries, and
> implementing the platform input protocol with UTF-16 ↔ UTF-8 conversion at the edge. On the
> Swift side essentially all of this is `NSTextView`. The behaviours below are the requirement;
> the machinery is not.

### 9.5 Sending

**Enter** sends. **Shift+Enter** inserts a newline. An empty composer sends nothing.

If **any** question is outstanding, Enter **answers that question** instead of starting a new
turn — the reply resolves the agent's pending request rather than arriving as a fresh message.
This holds whether or not the question also offers choices. Otherwise the text is appended to the
transcript as a user message and sent.

A click and a keystroke racing cannot both land: answering resolves the first *unanswered*
question, so the second arrival finds nothing pending and is treated as an ordinary message.

Only **one question can be outstanding at a time**; an agent that asks twice before being
answered gets the first one answered first.

### 9.6 Text editing semantics

Offsets are UTF-8 byte indices everywhere except at the platform boundary. Every offset arriving
from outside is snapped to the nearest character boundary at or before it, so no edit can slice a
multi-byte character in half.

| Key | Behaviour |
|---|---|
| Enter / Shift+Enter | Send / newline |
| Backspace | Delete selection, else one `char` before the caret |
| Alt+Backspace | Delete back to the start of the previous word |
| Delete | Delete selection, else one character after the caret |
| ← / → | Move one character. **With a selection, a plain arrow collapses to its near edge** rather than moving |
| Alt+← / Alt+→ | Move by word |
| ↑ / ↓ | Move one **visual** line, using the previous frame's layout, since "the line above" is a question about wrapping, not about the buffer. Stepping off either end goes to that end of the buffer |
| Shift + any of the above | Extend from a fixed anchor, so extension works in both directions |
| Cmd/Ctrl+A | Select all. The only modified keystroke the composer claims — everything else bubbles to the workspace |
| Escape | Interrupt the turn if one is running; otherwise **hand the keyboard back to the tab strip** |

Word classes are `space`, `word` (alphanumeric or `_`) and `punctuation`, each its own class, so
`foo.bar` steps in three moves the way every other field on the platform does.

Deletion is by `char`, not by grapheme cluster — splitting a family emoji into its parts is
wrong, but it was judged not worth a segmentation dependency yet. *Swift gets this right for
free; take it.*

**Pointer**: mouse-down focuses the field and places the caret at the nearest offset (Shift
extends); dragging extends the selection; the same released-outside-the-window guard as the
other drags applies.

**IME**: composition text is marked and underlined and is not committed until the IME says so.
The candidate window is positioned over the start of the text being composed. The selection the
IME requests is relative to the text *it* is inserting, counted in UTF-16 units of that string —
not of the buffer.

**The transcript itself is not selectable.** There is no way to copy an agent's reply today.

---

## 10. The agent protocol

Line-delimited **JSON-RPC 2.0**, one object per line, over a Unix domain socket. A `method` with
`params` is a **request** when it carries an `id` and a **notification** when it does not.

### The rule that matters most

**An unknown method, an unknown event kind, or a malformed line is ignored, never an error.**
The agent is written separately and will grow vocabulary faster than the host does; refusing to
parse a line prose does not recognise would mean the two sides could never be released
independently. Every unknown thing becomes "nothing" and the connection carries on. This covers
blank lines, malformed JSON, responses to requests never sent, and methods from a newer agent.

`id` may be a number or a string, and is echoed back exactly as sent rather than normalised.

### Agent → prose

| Method | Params | Meaning |
|---|---|---|
| `hello` | `session`, `token`, `name?` | Binds a connection to the session prose handed it. **Must be the first line**; anything before it is dropped. Requires an `id` so it can be answered |
| `event` | `session`, `event` | Something to draw — the bulk of all traffic |
| `pane.create` | `from`, `axis` (`row`\|`column`), `placement?` (`after`\|`before`), `command[]`, `cwd?`, `env{}`, `title?` | Split `from` and start `command` in the new pane |
| `pane.close` | `pane` | |
| `pane.focus` | `pane` | Bring a pane into view |
| `pane.title` | `pane`, `title` | |
| `ask` | `session`, `prompt`, `choices[]`, `placeholder?` | Stop and ask the user. **Must carry an `id`** — a notification `ask` is dropped, since the agent would otherwise wait forever for a reply it never asked for. `choices` and `placeholder` are independent: either, both, or neither |
| `message` | `to`, `text` | Say something to another session — a parent talking to a subagent |
| `result` | `session`, `value` | This session's return value, routed to whoever spawned it |
| `pane.read` | `pane`, `since?`, `until?[]`, `timeout?`, `fidelity?`, `kinds?[]`, `match?`, `block?`, `limit?` | Read a pane's transcript. **Must carry an `id`.** See *Reading a pane* below |
| `pane.send` | `pane`, `text` | As `message`, addressed by pane rather than by session |
| `pane.answer` | `pane`, `text?`, `escalate?` | Answer the question that pane is stopped on, exactly as a click or Enter would. A no-op if nothing is pending |
| `pane.interrupt` | `pane` | Escape, on someone else's behalf |
| `browser.navigate` | `pane`, `url` | Loads a URL, through the same path the address field uses |
| `browser.text` | `pane`, `selector?`, `limit?` | The page's rendered text — `innerText`, not markup, because what an agent wants is what a reader would see. **Must carry an `id`.** `limit` is in characters and clamps in prose, so a heavy page costs the asking agent a bounded amount |
| `browser.eval` | `pane`, `script` | **Must carry an `id`.** The script's value, or `null` where it is not representable as JSON or the script threw |
| `browser.snapshot` | `pane`, `path?` | **Must carry an `id`.** Writes a PNG and replies `{path}` — never the bytes |

`hello`'s reply carries `{ok, pane, session}`. **The pane matters**: everything an
agent addresses is named by pane, and the environment hands it only a session — without this it has
no way to learn which pane it is drawing in, and so cannot split itself.

`pane.create`'s `command` is optional. Omitted, the new pane runs whatever prose runs by default,
so an agent asking for a subagent need not hard-code prose's own configuration. Its reply carries
`{pane, session}`.

`pane.create`'s `placement` says which side of `from` the new pane lands on. It defaults to
`after` — right of, or below — which is what `Cmd+D` does and what every split did before the
option existed. `before` exists for the one pair with a settled reading order: a browser pane
opens *above* the pilot driving it, so the page takes the top of the column and the agent
narrating it sits underneath at the page's full width. An unrecognised value reads as `after`
rather than failing the call; placement is a preference about tidiness, and losing a pane over a
misspelling would be a poor trade.

`pane.create` also takes `kind` — `agent` (the default) or `browser` — and, for a browser, a `url`
to open it on. A `kind` this build does not recognise **drops the call**: it is the one field where
defaulting would be worse than refusing, because the agent would get a pane of the wrong sort under
a title it chose and be none the wiser.

### Browser panes

**An agent may drive only a browser pane it opened.** A pane the user opened is not the agent's to
run script in — a page the user typed a password into is exactly the page an agent talked into it
by a prompt injection would want to read.

The mechanism is the containment rule, not a second one: a browser pane an agent creates is given a
session parented to that agent's, with no process behind it, so the same descendant walk guards it.
A user-created browser pane has no session at all, so nothing resolves and nobody may drive it.

Selectors and scripts are **data in the script prose builds**, never text spliced into it. An agent
chooses the selector, and an agent can be talked into choosing a badly-formed one by a page it has
just read.

`browser.snapshot` answers with a path rather than bytes, deliberately. A pane-sized PNG is on the
order of 1,500 tokens once base64-encoded, every call, on a line-delimited wire — so reading one
stays a decision the agent makes on purpose once it has established that the page's *appearance* is
the question.

### Containment

**A session may act on its own pane, or on any pane belonging to a session descended from it**,
walked through the parent link `pane.create` establishes. Everything above is checked against that
rule, not just `event` and `ask`: pane ids are small and sequential and an agent can see its own, so
without it any agent could close, retitle or read any pane in the window by guessing an integer.

A refused **request** is answered with `-32000` and a reason. A refused **notification** is dropped,
which is the same treatment everything else prose declines to act on gets.

The rule is one-directional. A child may not message its parent; the upward channel is `result`,
which arrives as `child.result` and is routed by the parent link rather than addressed by the child.

### Reading a pane

`pane.read` is how a parent supervises a subagent, and it is **read and wait in one call**. With no
`timeout` it answers at once. With a `timeout` and a non-empty `until` — `turn`, `ask` or `exit` —
it parks until one of those happens and then answers, returning *why it woke* together with
everything that changed since `since`. One request per turn of the child's, rather than a poll.

> **It is level-triggered against `since`, never edge-triggered.** A child that finishes before its
> parent gets round to asking must be reported at once, not waited on: the event that would have
> woken the read happened before the read existed, and a fast child is the common case.

The reply is `{reason, cursor, blocks, running, status?, truncated?}`. `cursor` is a monotone stamp
to pass as the next `since`; it advances past blocks that were filtered out, so a filtered read does
not rescan them. It is **not** a block count — a delta or a resolving activity changes a block
without adding one.

`fidelity` is `summary` (the default) or `full`. A summary is one object per block: `i` its index,
`n` its length, and for prose a `head` of the first 80 characters. Activities, asks and notices are
small and go out whole at either fidelity; **thinking summarises to a bare count with no preview**.
`block` reads one block, by index, in full — the zoom a summary earned.

Blocks are addressed by **index**, not id: notices have no id and user messages use an empty one.
Indices are stable because blocks are only ever appended or mutated in place, never removed.

A reply is capped at 32 KB whatever `limit` says, and sets `truncated`. A child that attaches five
megabytes would otherwise cost its parent everything in one call, and the parent cannot know that
before it asks.

### Event kinds (inside `event`)

| `kind` | Fields | Effect |
|---|---|---|
| `message.start` | `id`, `role` | Opens a block. Role `user`, `thinking`, or **anything else means the agent** — the common case and the safer assumption for a role we do not know. `thinking` opens a reasoning block, which streams through the same `delta` and `message.end`; a build that has never heard of it renders the reasoning as prose rather than erroring |
| `delta` | `id`, `text` | Appends to that block |
| `message.end` | `id` | Stops its streaming state |
| `activity` | `id`, `label`, `detail?`, `state` (`ok`\|`error`\|anything = running), `category?` | Adds or updates a labelled step. `category` — `tool`, `skill`, `search`, `wait`, or anything later — says what *sort* of step, so telling a skill from a tool is not a matter of sniffing `label`. A skill's 5pt mark is drawn as a ring rather than a disc; every other category, known or not, draws the disc. Like `detail`, a resolving update keeps the category it had |
| `attachment` | `id`, `type` (default `text`), `language?`, `text` | Adds a block |
| `turn` | `state` (`started`\|`failed`\|anything = ended), `error?` | Starts/ends the turn |
| `status` | `fields{}` | Merges free-form key/values into the pane header. Ordered, so the header does not reshuffle between frames |

### prose → agent

| Method / shape | Meaning |
|---|---|
| `message` — `session`, `text` | The user typed something |
| `interrupt` — `session` | Escape, mid-turn |
| `closed` — `session` | The pane is gone; shut down |
| `child.result` — `session`, `from`, `value` | A subagent this session spawned has finished |
| *(response)* `{id, result}` | A reply to something the agent asked for |
| `child.ask` — `session`, `from`, `pane`, `prompt`, `choices[]`, `placeholder` | A subagent this session spawned has stopped to ask something. Answer it with `pane.answer`, or decline with `escalate` and let the user have it |
| *(response)* `{id, error: {code: -32000, message}}` | A refusal, with a reason the agent can log |

### Diagnostics

`PROSE_LOG_DIR` names a directory to write every line to, in both directions, one JSON object per
line: `{at, dir, session, line}`. Off unless set. It supersedes `PROSE_FRAME=1`, which forwarded the
agent's stderr and so showed what an agent *said* it was doing rather than what it put on the wire.
Lines are logged **before** parsing, so the ones prose could not understand are in it too — those
being the ones worth having. Session tokens are redacted.

It is **not** a read path. A parent reads a subagent with `pane.read`, which answers in reduced
blocks against a cursor; a log is a second rendering that would drift from the reducer, costs an
unbounded number of tokens to grep, and cannot say "wake me when something happens". What a log is
good at is the thing a cursor cannot do: saying what happened *before* the bug, after the fact,
from outside the process.

### Supervised questions

A question from a session **with a parent** reaches that parent first, as `child.ask`. The card is
still drawn in the child's pane — the user seeing what is being decided is worth more than being
asked to decide it — but while the parent holds it the buttons take no clicks and the composer does
not claim Enter. The card says which pane is answering.

The parent answers with `pane.answer`, or hands it back with `escalate`. Either way, and after a
grace of 60 seconds in case the parent has crashed or wandered off, the question becomes an
ordinary one and the user answers it. A session with **no** parent is unchanged: its questions have
always gone straight to the user.

A click and an answer racing cannot both land, for the same reason two answers cannot: answering
resolves the first *unanswered* question.

### The transcript reducer

Folding events into drawable blocks is **total**: every event does something sensible whatever
state it arrives in, because a half-written agent will do all of these and none may crash.

- A **delta for a block nobody opened is dropped** — opening one implicitly would be friendlier
  but would hide the bug from whoever is writing the agent.
- An **activity arrives twice**, once when it starts and again when it resolves; the second
  updates the row in place rather than adding a duplicate. A resolving update carrying no detail
  **keeps the detail it had**, so "Searching / 40 sources" does not lose its subtitle on the way
  to being ticked off.
- When a **turn ends, anything still streaming is closed**, so a stray caret does not blink
  forever at the bottom of the pane.
- A turn's `error` string is appended as a notice block.
- Message blocks are searched **from the end**, since the one being streamed into is almost
  always the last.

---

## 11. The host: processes and the socket

### Why a socket rather than a pipe

An agent may ask prose to open a pane and run a **subagent** in it, and that subagent is a
process of its own. Over a stdio pipe it could only reach prose by having its parent relay every
line. A socket means any process prose spawned can talk to prose directly, using the session
token it was handed in its environment — which is what makes subagents-in-panes fall out of the
design instead of needing plumbing.

### Setup

- A directory `$TMPDIR/prose-<pid>/` is created **mode 0700**, and `agents.sock` is bound inside
  it, so nothing else on the machine can reach it. The directory is removed on exit (best
  effort — a stale socket in a temp dir is harmless, but leaving one per run is untidy).
- **If the socket cannot be opened, the app still runs.** Panes render, they just stay empty. A
  window with no agents is worth more than refusing to open at all.

### Sessions

A session is reserved for a pane *before* its view exists, because the view must be told which
session it is. Each carries: the pane id, a token, a weak handle to the view, an optional parent
session, an outbound queue (`None` until the agent says hello), a backlog, and the child process
task.

A process is spawned with:

| Variable | Meaning |
|---|---|
| `PROSE_SOCKET` | Where to connect |
| `PROSE_SESSION` | Which session it is |
| `PROSE_TOKEN` | Proof it is the process prose spawned for that pane |

plus any `env` the caller asked for, in the tab's working directory (a subagent inherits the
directory of the agent that asked for it unless it says otherwise). The default command is
`agents/.venv/bin/python3 agents/pane_agent.py`, overridable with the `PROSE_AGENT` environment
variable — a whole command line rather than a path, so an agent can be `python3 -m something`
without a wrapper script. Both halves are searched for rather than spelled relatively: beside the
executable, in a bundle's `Resources`, then up towards a source checkout. A bare `python3` has no
Agent SDK in it, so the virtual environment is not optional; `Scripts/setup-agents.sh` builds it.

`agents/echo_agent.py` is still there and is what the tests run: it has no model behind it, so it
exercises the whole wire for free.

The child is spawned **kill-on-drop**: if prose goes away for any reason, no agent outlives it.

### Handshake and authorisation

The first line on a connection must be a `hello` request naming a session and its token. It is
accepted only if both match a reserved session; otherwise the connection is answered with a
failure and closed. After that:

- **An agent may only draw in a pane it owns** — an `event` or `ask` whose `session` differs
  from the connection's session is dropped (an `ask` gets an explicit "not your session"
  failure). Without this, a session could scribble in any other pane by guessing an id.
- Anything addressed to a session **before it connects is queued and delivered on its hello**.
  A subagent is spawned and told something in the same breath often enough that dropping those
  lines would be a race the agent author could not win.

### Lifecycle

- Closing a pane sends `closed` to its agent *first*, then drops everything that keeps it alive
  — so the agent is told rather than simply having its socket close under it.
- Closing a tab closes every session in it.
- Turning an agent pane into a browser pane ends its session, since nothing is left to draw its
  output.
- When a child exits, its pane gets a notice: `agent finished`, `agent exited (<status>)`, or a
  wait error. **The pane is not closed** — a pane vanishing out from under whoever was reading
  it is worse than one that says what happened.
- A `result` from a session is routed to its parent as `child.result`, if it has one.

---

## 12. Input reference

### Focus model

Two keyboard owners decide where the **plain** arrow keys go, because once a pane holds a caret
it cannot also drive the tab strip:

- **The tab strip** — plain ↑/↓ move the tab selection; Enter starts a rename.
- **The content area** — plain arrows move pane focus. This is the case for a browser pane
  showing a page: it has a URL field, but the field only holds the keyboard while it is being
  typed in, and Escape gives it back.
- **An agent pane's composer** — plain arrows are text navigation; Escape gives the keyboard
  back to the strip.

Clicking a pane moves focus into it (into its composer where there is one).

### Global (either side of the divider)

| Keys | Action |
|---|---|
| Cmd/Ctrl + `=` or `+` | Zoom in one rung |
| Cmd/Ctrl + `-` or `_` | Zoom out one rung |
| Cmd/Ctrl + `0` | Reset to 1.0× |
| Cmd/Ctrl + `D` | Split the focused pane right |
| Cmd/Ctrl + Shift + `D` | Split the focused pane down |
| Cmd/Ctrl + `W` | Close the focused pane (closing a tab's last pane closes the tab) |
| Cmd/Ctrl + `T` | Turn the focused pane into a browser pane |
| Cmd/Ctrl + `R` | Reload the focused browser pane, or stop it loading |
| Cmd/Ctrl + `L` | Focus its URL field and select what is in it |
| Cmd/Ctrl + `[` / `]` | Back and forward |
| Cmd/Ctrl + ↑ / ↓ | Move the tab selection, from either side, so it never depends on where focus happens to be |
| Cmd/Ctrl + Alt + ↑↓←→ | Move pane focus |

Both shifted and unshifted spellings of the zoom keys are accepted, since a keyboard may report
either. `Cmd` on macOS, `Ctrl` elsewhere.

> Note this differs from the older `CLAUDE.md`, which documents plain Cmd+arrows for pane focus.
> The Alt modifier was added when the composer claimed the plain arrows. **The code above is
> authoritative.**

### Notes for a Swift port

All input is handled in a single key-down handler with a flat match — there is no keymap, no
action table and no key-binding system, *deliberately*, because a keymap's context predicates
fought the inline rename field. A Swift port has a real responder chain and can use it, but the
requirement to preserve is: **the rename field and the composer must be able to take the plain
arrow keys, Enter and Escape without the window's own shortcuts intercepting them.**

Printable characters never reach the key handler in the composer — they arrive through the
platform text-input protocol, which is also what makes the IME and system paste work.

---

## 13. What is not built

1. ~~**The browser pane is a label.**~~ **Built.** In gpui the approach would have been a
   `WKWebView` added as a sibling over the renderer's view, re-framed every paint from a canvas
   element's bounds, with a Y flip, painting above every other element, with no rounded corners
   or clipping, stealing first responder on click. In AppKit it is an ordinary subview and every
   one of those costs is zero — measured, not assumed, by `BrowserPaneTests`. This was the
   single strongest reason the port was considered, and it held.

   The other half of it is built too: `browser.navigate`, `browser.text`, `browser.eval` and
   `browser.snapshot` are in the protocol, and an agent may open a browser pane and drive the one
   it opened. What is **still** missing is the return path — there is no `WKScriptMessageHandler`,
   so a page cannot post events back into a transcript, and prose has no "the page finished
   loading" event for an agent to park on. Reading a page an agent has just opened therefore means
   asking again until the text arrives, rather than waiting once.
2. **The settings button does nothing.**
3. **Transcript text cannot be selected or copied.**
4. **No markdown *structure*** — by design, see §9.3. Inline emphasis is rendered; headings,
   lists, tables and fences are not.
5. **No persistence.** Tabs, pane layouts, transcripts and window size are all lost on quit.
6. **No tab reordering**, no drag-and-drop of panes, no tab overflow handling beyond scrolling.
7. **`composer_border_active` is declared and never applied** — the composer does not currently
   show a focus ring, though the colour for it exists and the focused state is computed and then
   discarded. Treat the focus ring as intended-but-missing.
8. **The footer separator disappears at 0.8× zoom.** A 1pt hairline becomes 0.8px and rounds
   away. The fix is flooring hairlines at one real pixel. Deferred by choice.
9. **The tiling's pointer and keyboard paths have never been driven by hand** — an agent cannot
   inject input on this machine (no Accessibility permission), so splitting, divider dragging
   and directional focus are covered by unit tests and measurement only.
10. **The agent-pane branch does not compile** (§1).

---

## 14. Architecture, for whoever plans the port

### What is pure, and should stay pure

About 2.4k lines carry no UI framework at all and are covered by unit tests that need no window.
These are the parts a port should translate rather than redesign:

| Concern | What it decides |
|---|---|
| **Split tree** | Tiling, dividers, divider clamping, directional focus |
| **Protocol** | Parsing and serialising every line on the wire |
| **Transcript** | Folding events into drawable blocks |
| **Composer buffer** | The string, the selection, word boundaries, UTF-16 conversion |

Plus a handful of free functions worth keeping as pure logic: zoom stepping, tab-selection
stepping, slide interpolation, nearness blending, and the content-header inset.

The composer buffer is the one piece a Swift port can largely *discard* rather than translate,
since `NSTextView` owns that behaviour — but its **semantics** (§9.6) are the acceptance
criteria for whatever replaces it.

### State ownership

One object owns all of it: the tab list, which tab is active, the id counters, the two focus
owners, the content area's measured bounds, the sidebar's open state and resting width and
slide, the drag in progress (one slot — only one drag can run at a time and both kinds end the
same way), the rename in progress, the selection slide, and the zoom rung.

Each **tab** owns its title, its split tree, its panes, **which of its panes is focused** (kept
per tab, so switching away and back returns you to where you were, and closing a tab takes its
focus state with it), and its working directory.

Each **agent pane** owns its own transcript, composer, focus, scroll position, follow flag, and
pending repaint — so a streaming delta notifies only that pane and leaves the sidebar and every
other pane alone. This is a real performance property, not an accident of structure.

### Animation invariant worth carrying over

There are exactly two animations — the sidebar collapse (180 ms) and the selection slide
(140 ms) — and both are driven by reading elapsed time against a start instant, not by a
retained animator. In gpui this forced a structural split: a **pure read** used by event
handlers, and a **read-plus-request-next-frame** used only while rendering, because requesting
a frame outside a render pass crashed the app. Swift's animation system removes that hazard
entirely, but the underlying requirement survives: **an animation must be interruptible
mid-flight and must resume from wherever it currently is**, which is what makes an interrupted
selection slide and its travelling colour stay correct.

### Assets

Nine Lucide icons (ISC), vendored and embedded so the binary is self-contained:
`panel-left`, `chevron-right`, `x`, `plus`, `settings`, `bot`, `globe`, `columns-2`, `rows-2`.

### Reference material in this repo

- `reference/demo.png` — the screenshot every dimension was measured from, captured at ~1.55×
  (derived from the traffic lights, whose real size is known). Divide pixel distances there by
  that before treating them as points.
- `reference/ui-zoom-plan.md` — the approved plan the zoom work followed.
- `CLAUDE.md` — conventions, and a catalogue of gpui traps that a Swift port makes irrelevant.
  Its keyboard section is out of date; §12 here supersedes it.
