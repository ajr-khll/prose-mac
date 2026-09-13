//  Every dimension the shell uses, measured off `reference/demo.png`.
//
//  The reference screenshot was captured at roughly 1.55x (derived from the
//  macOS traffic lights, whose real size is known), so pixel distances measured
//  there are divided by that before being written down here as points.
//
//  Ported from the second half of `theme.rs`. Colours live in `Palette.swift`:
//  they have no zoom dependency and dimensions have nothing else (plan §9).
//
//  # Points scale; pixels don't
//
//  gpui resolved the whole UI against one number per window — the rem size —
//  and changing that number *was* the zoom feature. Swift has no equivalent
//  (plan §6.1): `@ScaledMetric` is tied to Dynamic Type and `.scaleEffect`
//  rasterises text at the wrong size. So the discipline `theme::pt()` imposed
//  by convention is imposed here by the type system instead: a scalable
//  dimension is `Points` and only becomes drawable by passing through
//  `Metrics.resolve`, while the four things spec §3 keeps in real pixels are
//  `Pixels` from the start and never meet the zoom at all.

// MARK: - The two bands

/// A dimension that grows with the zoom. Reads as a pixel count at 1.0x, so the
/// constants below keep the values they were measured at.
public struct Points: Sendable, Hashable, Comparable, AdditiveArithmetic,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral
{
    public var value: Double

    public init(_ value: Double) { self.value = value }
    public init(integerLiteral value: Int) { self.value = Double(value) }
    public init(floatLiteral value: Double) { self.value = value }

    public static let zero = Points(0)

    public static func < (a: Points, b: Points) -> Bool { a.value < b.value }
    public static func + (a: Points, b: Points) -> Points { Points(a.value + b.value) }
    public static func - (a: Points, b: Points) -> Points { Points(a.value - b.value) }
    public static func * (a: Points, b: Double) -> Points { Points(a.value * b) }
    public static func / (a: Points, b: Double) -> Points { Points(a.value / b) }
}

/// A dimension in real pixels, which the zoom never touches.
///
/// spec §3 lists exactly four of these, and every one of them is here because
/// it has to line up with something prose does not control — chiefly the macOS
/// traffic lights, which are drawn at a size that ignores prose's zoom.
public struct Pixels: Sendable, Hashable, Comparable, AdditiveArithmetic,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral
{
    public var value: Double

    public init(_ value: Double) { self.value = value }
    public init(integerLiteral value: Int) { self.value = Double(value) }
    public init(floatLiteral value: Double) { self.value = value }

    public static let zero = Pixels(0)

    public static func < (a: Pixels, b: Pixels) -> Bool { a.value < b.value }
    public static func + (a: Pixels, b: Pixels) -> Pixels { Pixels(a.value + b.value) }
    public static func - (a: Pixels, b: Pixels) -> Pixels { Pixels(a.value - b.value) }
    public static func * (a: Pixels, b: Double) -> Pixels { Pixels(a.value * b) }
    public static func / (a: Pixels, b: Double) -> Pixels { Pixels(a.value / b) }

    /// Reads a point measurement as a pixel one, deliberately skipping the zoom.
    ///
    /// This is the seam spec §3 describes rather than a way round the types: the
    /// sidebar toggle is a point-sized button that sits in the fixed header row,
    /// so its size and its column are measured in points but resolved in pixels.
    /// It should appear only in the cases spec §3 lists — if a view reaches for
    /// it, the dimension almost certainly wanted `Metrics.resolve` instead.
    public static func unscaled(_ points: Points) -> Pixels { Pixels(points.value) }
}

// MARK: - The zoom ladder

/// The zoom rung the window is drawn at, and the one number every point
/// dimension is resolved against.
public struct Metrics: Sendable, Equatable {
    /// A fixed ladder rather than a multiplier, so repeated zooming lands on the
    /// same sizes every time and never drifts off 1.0.
    public static let zoomSteps: [Double] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5, 1.75, 2.0]

    /// The rung that is exactly 1.0x, which is where launch and Cmd+0 both sit.
    public static let defaultZoomStep = 2

    public var step: Int

    public init(step: Int = Metrics.defaultZoomStep) {
        self.step = step
    }

    public var zoom: Double { Self.zoomSteps[step] }

    /// Points to the pixels they are drawn at.
    ///
    /// gpui had `BASE_REM = 16` here because a point reached the element tree as
    /// a rem and the window resolved them all at once. There is no rem in Swift
    /// and no window-wide knob to put one in, so the multiplication happens per
    /// dimension instead — the regression plan §6.1 describes, and the reason
    /// this type exists rather than a bare `Double`.
    public func resolve(_ points: Points) -> Pixels {
        Pixels(points.value * zoom)
    }

    /// How much a button in the header may grow with the zoom.
    ///
    /// The traffic-light row cannot grow with it, so a button sharing that row
    /// is capped to what still fits. Bites above roughly 1.45x. The ratio
    /// crosses the two bands on purpose — it is asking how many times a point
    /// measurement fits inside a pixel one.
    public static func headerButtonScale(_ zoom: Double) -> Double {
        min(zoom, Pixels.headerButtonMax.value / Points.buttonSize.value)
    }

    public var headerButtonScale: Double { Self.headerButtonScale(zoom) }
}

/// Which rung of the zoom ladder is `steps` away from `step`. Clamps rather
/// than wraps, so holding Cmd+= comes to rest at the largest size instead of
/// snapping back to the smallest.
public func nextZoomStep(_ step: Int, _ steps: Int) -> Int {
    let last = Metrics.zoomSteps.count - 1
    return min(max(step + steps, 0), last)
}

// MARK: - Fixed dimensions, in real pixels

extension Pixels {
    // -- The window -----------------------------------------------------

    public static let windowWidth: Pixels = 1100
    public static let windowHeight: Pixels = 720
    public static let windowMinWidth: Pixels = 480
    public static let windowMinHeight: Pixels = 360

    /// The macOS traffic lights, positioned by us because the titlebar is
    /// transparent. This is the top-left of the close button.
    public static let trafficLights: (x: Pixels, y: Pixels) = (17, 13)

    // -- The header row -------------------------------------------------

    /// Tall enough to clear the traffic lights and give the toggle room to
    /// breathe.
    ///
    /// This row is window chrome, not content: macOS draws the traffic lights in
    /// it at a size that ignores our zoom, so the row keeps a fixed height at
    /// every zoom and everything in it stays on the lights' centre line. A
    /// toggle that scaled would drift off the lights, and at 2.0x would overflow
    /// the top of the window.
    public static let headerHeight: Pixels = 40

    /// The content area's own chrome row, above the panes. Fixed for the same
    /// reason, so the two stay level across the divider.
    public static let contentHeaderHeight: Pixels = headerHeight

    /// The largest button the fixed header row can hold without crowding it.
    public static let headerButtonMax: Pixels = 32
}

// MARK: - Scalable dimensions, in points

extension Points {
    // -- The sidebar ----------------------------------------------------

    public static let sidebarWidth: Points = 240
    public static let sidebarMinWidth: Points = 180
    public static let sidebarMaxWidth: Points = 420

    /// Invisible grab strip centred on the divider, wide enough to hit
    /// comfortably. A point measurement because it straddles the divider, and
    /// spec §3 requires all of that strip's terms to share one space.
    public static let resizeHandle: Points = 6

    public static let footerHeight: Points = 32

    /// Horizontal inset of a row from the sidebar's left edge.
    public static let rowInsetLeft: Points = 7
    /// Half again as much on the right, so the strip is not crowded against the
    /// vertical divider.
    public static let rowInsetRight = rowInsetLeft * 1.5
    /// Padding inside a row, between its edge and the chip or close button.
    public static let rowPaddingX: Points = 7
    /// Rows carry a permanent 1pt border so selection does not shift them.
    public static let rowBorder: Points = 1
    public static let rowHeight: Points = 30
    public static let rowGap: Points = 2
    public static let rowRadius: Points = 7
    /// Top edge to top edge, which is the distance the selection highlight
    /// travels for one row. Rows size as border boxes, so the border is already
    /// inside `rowHeight`.
    public static let rowPitch = rowHeight + rowGap

    public static let chipSize: Points = 22
    public static let chipRadius: Points = 7

    public static let chevronSize: Points = 11
    public static let closeSize: Points = 12
    /// Hit area around the close glyph.
    public static let closeBox = closeSize + 4
    public static let buttonIconSize: Points = 14
    /// Hit area around a bare icon, so small glyphs stay comfortably clickable.
    public static let buttonSize: Points = 22
    /// The hover wash behind an icon button.
    public static let buttonRadius: Points = 5

    /// Between a row's chip, its title and its close button.
    public static let tabGap: Points = 4
    /// The close button's hover box, and the inline rename field.
    public static let smallRadius: Points = 4

    /// The inline rename field, which sits inside a row and so is shorter
    /// than it. spec §6.5: `ROW_HEIGHT - 10`.
    public static let renameHeight = rowHeight - 10
    public static let renamePaddingX: Points = 4

    /// A 1pt rule. spec §13.8 records that this rounds away to nothing at 0.8x
    /// zoom and that flooring hairlines at one real pixel is the deferred fix;
    /// the port inherits both the hairline and the open bug.
    public static let hairline: Points = 1

    public static let textSize: Points = 13
    /// The content header's title, and anything else set a step below prose.
    public static let contentHeaderTextSize = textSize - 1

    /// Everything in a transcript that is not prose: activity rows, notices and
    /// choice buttons. spec §9.3 gives all three as 12pt — they are what the
    /// agent *did*, set a step under what it said.
    public static let secondaryTextSize = textSize - 1

    /// The pane header's status text, a step under that again (spec §8).
    public static let statusTextSize = textSize - 2

    /// How far the footer's separator stops short of the vertical divider, so
    /// the two lines do not meet in a hard corner.
    public static let dividerGap: Points = 6

    // -- Derived columns ------------------------------------------------

    /// One column for everything that hangs off the right of the sidebar: the
    /// header's `+` and every tab's `×` share this centre line.
    public static let trailingCenterFromRight = rowInsetRight + rowBorder + rowPaddingX + closeBox / 2

    /// The matching column on the left, shared by the tab chips and the
    /// settings icon in the footer.
    public static let leadingCenterFromLeft = rowInsetLeft + rowBorder + rowPaddingX + chipSize / 2

    /// Where the sidebar toggle sits, measured from the sidebar's left edge.
    ///
    /// Far enough right to clear the traffic lights, which the system draws on
    /// top of our transparent titlebar. The Rust original chose between this and
    /// the chips' column with a runtime `cfg!`, because on Linux that corner was
    /// prose's own and the gap would have been a hole; Linux is formally dropped
    /// in the Swift port, so only the macOS arm survives.
    public static let toggleCenterX: Points = 98

    /// Where the settings button sits, measured from the sidebar's left edge.
    /// It shares the chips' column.
    public static let settingsCenterX = leadingCenterFromLeft

    // -- Panes ----------------------------------------------------------
    //
    // Four relationships between the constants below are load-bearing, and in
    // Rust they were `const _: () = assert!(...)` — breaking one failed the
    // build. Swift has no equivalent over computed constants, so they live in
    // `MetricsInvariantTests` instead (plan §6.2). That is a real downgrade,
    // from "cannot be compiled wrong" to "cannot be released wrong", and it is
    // recorded here so the intent survives next to the numbers it is about.

    /// The gutter between two panes, and between a pane and the content edge.
    ///
    /// Must be at least as wide as `resizeHandle`. The original reason was that
    /// a browser pane would be a native view painted over everything the
    /// renderer drew, and a narrower gutter would let it cover part of the
    /// sidebar's grab strip and eat the drag. plan §2 retires that reason — in
    /// AppKit a `WKWebView` is an ordinary subview with normal z-order — but the
    /// gutter is kept, because 8 against a 6pt strip is also simply the spacing
    /// the tiling was measured at.
    public static let paneGap: Points = 8

    public static let paneRadius: Points = 8
    /// Panes carry a permanent border so focusing one recolours it rather than
    /// adding a line and shifting the contents by a pixel.
    public static let paneBorder: Points = 1
    public static let paneHeaderHeight: Points = 26
    public static let paneHeaderPaddingX: Points = 8

    /// Smallest a pane may be dragged to. Big enough that the pane it shrinks
    /// still shows its own header, so there is always something left to grab.
    public static let paneMinWidth: Points = 160
    public static let paneMinHeight: Points = 96

    /// The icon at the head of a pane, naming what kind of pane it is.
    public static let paneIconSize: Points = 12

    // -- Inside an agent pane -------------------------------------------

    /// The margin around the transcript and around the composer below it.
    public static let transcriptPadding: Points = 10
    /// Between any two blocks in the transcript.
    public static let blockGap: Points = 10

    public static let bubblePaddingX: Points = 9
    public static let bubblePaddingY: Points = 6
    public static let bubbleRadius: Points = 7

    /// The status dot at the head of an activity row, and the gap after it.
    public static let activityDot: Points = 5

    /// A skill's mark is a ring rather than a disc, at the same 5pt across.
    /// Half the dot would read as a hairline at 1.0×; a third of it keeps a
    /// visible hole without the ring thickening into a disc.
    public static let activityRing: Points = 1.5

    /// How far reasoning is set in from the prose it accompanies.
    public static let thinkingIndent: Points = 10
    public static let activityGap: Points = 7

    public static let codePadding: Points = 8
    public static let codeRadius: Points = 6
    /// Code is set a little smaller than prose: a monospaced face at the same
    /// point size reads as larger, and a pane has no width to spare.
    public static let codeTextSize = textSize - 1
    /// How far a code *span* drops below the prose it sits inside, for the same
    /// reason. Written as a drop rather than a size because a span appears in
    /// 13pt prose and in 12pt reasoning, and has to stay smaller than both.
    public static let codeSpanDrop: Points = 1

    public static let askPadding: Points = 9
    public static let askRadius: Points = 7
    public static let choicePaddingX: Points = 9
    public static let choiceHeight: Points = 24
    public static let choiceRadius: Points = 6

    public static let composerPaddingX: Points = 12
    public static let composerPaddingY: Points = 10

    /// **Square.** `prose-ui-demo` sets `border-radius: 0` on the composer while
    /// leaving every other box rounded, and it is the strongest single thing
    /// about that screen: one hard-edged rectangle in a window of soft ones,
    /// which is where the caret is.
    public static let composerRadius: Points = 0
    public static let composerBorder: Points = 1

    /// The `\u{203A}` before the composer's first character, and the gap after it.
    public static let promptGlyphSize: Points = 17
    public static let promptGlyphGap: Points = 12

    /// The row inside the box, under the text: the model, and `send \u{21B5}`.
    public static let composerFootGap: Points = 10

    /// The keyboard hints below the box, outside it.
    public static let composerHintPaddingY: Points = 12

    // -- The welcome state ----------------------------------------------
    //
    // What an agent pane shows before its transcript has anything in it: the
    // wordmark, a greeting, and the composer sitting in the middle of the pane
    // rather than pinned under a transcript.
    //
    // Every measurement here is `prose-ui-demo`'s own, scaled by 13/14 — its
    // prose is 14px and ours is 13pt.

    /// How wide the welcome column is allowed to get before it stops growing.
    /// The demo's `.start` is 720px; a pane narrower than this simply uses its
    /// own width.
    public static let welcomeWidth: Points = 670

    /// Nominal cap for the wordmark. It shrinks with the pane below this —
    /// see `Wordmark`, which takes a size rather than deciding one, so that a
    /// 160pt-wide pane does not get a 200pt-wide logo.
    public static let wordmarkSize: Points = 88

    /// The halftone the wordmark is filled with: a square grid of dots, which
    /// is what `background-clip: text` over a repeating radial-gradient comes
    /// to. The pitch does **not** scale with the type size — in the demo it is a
    /// 4px background on text ten times that, and the mismatch is the effect.
    public static let wordmarkDotPitch: Points = 4
    public static let wordmarkDotRadius: Points = 1.55

    /// The two offset copies behind and in front of it, which is where the
    /// chromatic-aberration look comes from. Down-left behind, up-right in front.
    public static let wordmarkBehindOffset: Points = 7
    public static let wordmarkFrontOffset: Points = 5

    /// How far the wordmark leans. The demo's `skewX(-6deg)`, in radians at the
    /// point of use.
    public static let wordmarkSkewDegrees: Double = -6

    /// Under the wordmark, and under the greeting below that.
    public static let wordmarkGap: Points = 33
    public static let greetingGap: Points = 21

    /// Between the composer's hint row and the suggestion under it.
    public static let suggestionGap: Points = 19

    /// How far above the pane's centre the welcome column sits.
    ///
    /// Dead-centre looks low, because the wordmark is visually heavier than the
    /// hint rows under it and the eye splits the difference. The demo reaches
    /// the same place with `padding-bottom` on a centred flex column.
    public static let welcomeLift: Points = 48

    // MARK: - A browser pane's URL field

    /// The same numbers as the composer today, and deliberately its own names.
    /// The two boxes look alike because they are both a text field in a pane
    /// body, not because they are the same control — and while they shared a
    /// token, retuning the composer silently retuned the URL bar.
    public static let addressPaddingX: Points = 8
    public static let addressPaddingY: Points = 6
    public static let addressRadius: Points = 8
    public static let addressBorder: Points = 1

    /// The caret. Wide enough to see against prose at every zoom, narrow enough
    /// not to read as a selected character.
    public static let caretWidth: Points = 1.5
}

// MARK: - Ratios and durations

extension Metrics {
    /// Multiplied by the font size to get one line of prose. Looser than the
    /// platform default, because a pane is narrow and wrapped text needs the air.
    public static let lineHeight: Double = 1.45

    /// How tall the composer may grow before it starts scrolling instead. Past
    /// this the transcript has given up too much of the pane to be worth reading.
    public static let composerMaxLines = 8

    /// How long the sidebar takes to slide out of, or back into, view.
    public static let sidebarSlide = Duration.milliseconds(180)

    /// How long the selection highlight takes to reach its new row. Quicker than
    /// the sidebar: a selection should feel like a response, not like scenery.
    public static let selectionSlide = Duration.milliseconds(140)

    /// How long after the last streamed event a pane waits before repainting.
    ///
    /// SwiftUI already coalesces drawing to the display refresh, so the repaint
    /// half of this is now free — but plan §8 keeps the window and moves it down
    /// a layer, because the cost that remains is the hop to the main actor, not
    /// the drawing.
    public static let repaintCoalesce = Duration.milliseconds(16)

    /// The monospaced face for code attachments.
    public static let monoFont = "SF Mono"
}

// MARK: - Derived layout

/// The top edge of the row at `index`, measured from the top of the strip.
public func rowOffset(_ index: Int) -> Points {
    Points.rowPitch * Double(index)
}

/// How close the highlight at `offset` is to the row at `index`: 1 when it is
/// sitting on the row, falling to 0 once it is a full row away. Rows blend their
/// accent colours by this, so the green travels with the box.
///
/// Deriving it from the live offset rather than from a remembered from/to pair
/// means an interrupted slide stays correct: the colours simply follow the
/// highlight wherever it happens to be.
public func nearness(_ offset: Points?, _ index: Int) -> Double {
    guard let offset else { return 0 }
    let rowsAway = abs((offset - rowOffset(index)).value) / Points.rowPitch.value
    return 1 - min(max(rowsAway, 0), 1)
}

/// How far the content area must inset its header so the sidebar toggle never
/// comes to rest on top of it.
///
/// The toggle is anchored to the window rather than to the sidebar, so once the
/// panel slides away it ends up over the content area instead. The answer is in
/// real pixels, like the toggle itself: that button does not zoom, so neither
/// can the gap that clears it. Zero whenever the panel is still wide enough to
/// hold it.
public func contentHeaderInset(sidebarWidth: Points, zoom: Double) -> Pixels {
    // The panel and its one-point hairline are both point measurements, so both
    // scale — but the hairline is only drawn while the panel is out at all, and
    // counting it once the panel has gone would shift this gap with the zoom.
    let contentLeft: Pixels =
        sidebarWidth > .zero ? Pixels((sidebarWidth.value + 1) * zoom) : .zero

    let toggleRight = Pixels.unscaled(.toggleCenterX + .buttonSize / 2)

    return max(toggleRight + Pixels.unscaled(.dividerGap) - contentLeft, .zero)
}
