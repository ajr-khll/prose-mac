//  Every colour the app uses.
//
//  Ported from the first half of `theme.rs`, and split from `Metrics.swift`
//  because colours have no zoom dependency and dimensions have nothing else
//  (plan §9).
//
//  # The rules behind the palette (spec §4)
//
//  - **One accent means one thing.** The phosphor green `#4FBD83` family is "this is
//    the active one" — the selected tab's border and chip, the focused pane's
//    ring, the caret, the text selection, the ask card, the live divider.
//    Nothing else is ever green.
//  - **State is carried by the smallest element that can carry it.** An
//    activity's success or failure is a 5pt dot, not a recoloured row, because a
//    row that changed colour wholesale would pull the eye away from the prose
//    around it.
//  - **The user's messages are set apart by a card, not by a colour**, so a long
//    prompt stays as readable as the reply to it.
//  - **Borders are permanent and only ever recolour.** Tab rows carry a
//    transparent 1pt border and panes carry a real one, so selecting or focusing
//    changes a colour instead of adding a line and shifting contents by a pixel.
//  - **Colour is blended, not switched.** See `mix`, and the sliding selection
//    it serves (spec §6.3).
//
//  The whole app is one translucent plane with a single accent. There is no
//  light mode; nothing adapts to the system appearance.

/// A colour, as straight (non-premultiplied) components running 0 to 1.
///
/// Its own type rather than `SwiftUI.Color` or `NSColor`, because this target
/// imports no UI framework — that is the property that makes the model
/// trustworthy and its tests runnable without a window. The app converts at the
/// view boundary, which is one initialiser.
public struct RGBA: Sendable, Hashable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    /// `0xRRGGBB`, opaque.
    public init(rgb hex: UInt32) {
        self.init(
            r: Double((hex >> 16) & 0xFF) / 255,
            g: Double((hex >> 8) & 0xFF) / 255,
            b: Double(hex & 0xFF) / 255
        )
    }

    /// `0xRRGGBBAA`. The trailing alpha byte is how the palette is written down
    /// in spec §4, so the constants below can be read straight off it.
    public init(rgba hex: UInt32) {
        self.init(
            r: Double((hex >> 24) & 0xFF) / 255,
            g: Double((hex >> 16) & 0xFF) / 255,
            b: Double((hex >> 8) & 0xFF) / 255,
            a: Double(hex & 0xFF) / 255
        )
    }
}

/// Blends `from` into `to`, with `t` running 0 to 1.
///
/// The sliding selection uses it to carry a row's accent colours along with the
/// highlight, so the green arrives with the box rather than snapping on once it
/// lands. `t` comes from `nearness`.
public func mix(_ from: RGBA, _ to: RGBA, _ t: Double) -> RGBA {
    let t = min(max(t, 0), 1)
    func blend(_ from: Double, _ to: Double) -> Double { from + (to - from) * t }

    return RGBA(
        r: blend(from.r, to.r),
        g: blend(from.g, to.g),
        b: blend(from.b, to.b),
        a: blend(from.a, to.a)
    )
}

public enum Palette {
    // MARK: - Surface

    /// The single translucent plane the whole window is painted with. macOS
    /// blurs whatever is behind the window and this dark wash sits on top of
    /// that blur. The alpha byte (`cc`, 80%) is the knob for "how see-through is
    /// the app".
    public static let windowBG = RGBA(rgba: 0x1C1C_20CC)

    /// Hairline between the sidebar and the content area.
    public static let divider = RGBA(rgba: 0xFFFF_FF14)

    /// The same hairline while it is hovered or being dragged, so the sidebar
    /// advertises that its edge can be moved.
    public static let dividerActive = RGBA(rgba: 0x4FBD_8399)

    /// The soft line above the settings row.
    public static let separator = RGBA(rgba: 0xFFFF_FF14)

    // MARK: - Text

    public static let text = RGBA(rgb: 0xE2E2E6)

    // MARK: - Tabs

    public static let tabHoverBG = RGBA(rgba: 0xFFFF_FF08)

    /// The selected tab carries a green cast rather than a neutral grey one —
    /// but a *quieter* one than the rest of the accent family.
    ///
    /// The accent still means "this is the active one" (the rules above stand);
    /// what changed is how loudly the tab strip says it. A caret or a 1pt focus
    /// ring is a few pixels and needs full saturation to register at all, while
    /// the selection is the largest tinted area in the window — at that size
    /// the same green reads as a green panel rather than as a highlight.
    /// These four are the accent pulled halfway to its own grey: same hue, same
    /// alpha, less shout. The rest of the family is untouched.
    public static let tabActiveBG = RGBA(rgba: 0x78AF_9214)

    public static let tabActiveBorder = RGBA(rgba: 0x7FB5_973D)

    /// The rounded square holding the `>` glyph at the head of every tab.
    public static let chipBG = RGBA(rgba: 0xFFFF_FF08)
    public static let chipActiveBG = RGBA(rgba: 0x7FB5_9733)

    public static let chevron = RGBA(rgb: 0x8A8A92)

    /// The chevron keeps more of the green than the wash behind it: it is the
    /// smallest part of the row, so it is what carries the state once the wash
    /// has stopped trying to.
    public static let chevronActive = RGBA(rgb: 0x62B78D)

    // MARK: - Renaming a tab

    public static let renameBG = RGBA(rgba: 0x0000_0059)
    public static let renameBorder = RGBA(rgba: 0x4FBD_838A)

    // MARK: - Panes

    /// A pane's own plane, sitting slightly proud of the window wash so the
    /// tiling reads even where two panes meet.
    public static let paneBG = RGBA(rgba: 0xFFFF_FF08)

    public static let paneBorder = RGBA(rgba: 0xFFFF_FF14)

    /// The focus ring. Deliberately the same green as `tabActiveBorder`, so
    /// "this is the active one" means one colour everywhere in the app.
    public static let paneActiveBorder = RGBA(rgba: 0x4FBD_835C)

    public static let paneHeaderBG = RGBA(rgba: 0xFFFF_FF08)
    public static let paneTitle = RGBA(rgb: 0x8A8A92)

    /// Body text in a pane that has nothing in it yet.
    public static let panePlaceholder = RGBA(rgb: 0x6A6A72)

    /// What a web page sits on before it has painted, and what shows past its
    /// edges when it is rubber-banded.
    ///
    /// **Opaque, where every other surface colour here is a wash** — and that is
    /// the whole reason it exists rather than reusing `paneBG`. `paneBG` is 3%
    /// white designed to sit on the window's blur, but WebKit composites its
    /// under-page colour against its own white backing rather than against the
    /// window, so handing it `paneBG` left the white flash exactly where it was
    /// with a 3% tint on it. This is the same plane worked out in advance:
    /// `windowBG`'s `#1C1C20` with `paneBG`'s 3% white composited over it.
    public static let pageBase = RGBA(rgb: 0x2323_27)

    // MARK: - Inside an agent pane

    /// The user's own messages, set apart from the agent's by a card rather than
    /// by a colour, so a long prompt stays as readable as the reply to it.
    public static let userBubbleBG = RGBA(rgba: 0xFFFF_FF0D)

    /// An activity's label — a tool call, a retrieval, a wait. Dimmer than prose
    /// because these are what the agent did, not what it said.
    public static let activityLabel = RGBA(rgb: 0xB4B4BC)

    /// Its subtitle, and the pane header's status text.
    public static let activityDetail = RGBA(rgb: 0x7A7A82)

    /// Reasoning. The disclosure line sits with the other labels; the reasoning
    /// itself is dimmer still, because it is below prose in the reading order
    /// even when it is open.
    public static let thinkingLabel = RGBA(rgb: 0x7A7A82)
    public static let thinkingText = RGBA(rgb: 0x6E6E76)

    /// The dot at the head of an activity row, which is the only thing that says
    /// whether the step is still going, finished or broken.
    ///
    /// A running step is **grey rather than the accent**, which is the one place
    /// the swap from periwinkle to green could not be literal. The old pair read
    /// as two different things because they were two different hues — a blue dot
    /// turning green. Both green, they are one hue at two saturations, and at
    /// 5pt that is not a distinction. Grey turning green keeps it, and costs
    /// only that a running step no longer carries the accent — which it has not
    /// earned yet anyway.
    public static let activityRunning = RGBA(rgb: 0x7A7A7A)
    public static let activityOK = RGBA(rgb: 0x5F8F6A)
    public static let activityError = RGBA(rgb: 0xC06A6A)

    /// Code and other monospaced attachments.
    public static let codeBG = RGBA(rgba: 0x0000_0040)
    public static let codeBorder = RGBA(rgba: 0xFFFF_FF0F)
    public static let codeText = RGBA(rgb: 0xC8C8D0)

    /// A failed turn, or the agent's process going away.
    public static let noticeText = RGBA(rgb: 0xC08A6A)

    /// The card the agent stops the conversation with. Carries the same
    /// green as the focus ring, because it is asking for the user's
    /// attention.
    public static let askBorder = RGBA(rgba: 0x4FBD_8352)
    public static let askBG = RGBA(rgba: 0x4FBD_8314)

    public static let choiceBG = RGBA(rgba: 0xFFFF_FF0F)
    public static let choiceHoverBG = RGBA(rgba: 0x4FBD_8333)

    /// The answer the user gave, once the card has been resolved.
    public static let choiceChosenBG = RGBA(rgba: 0x4FBD_8347)

    // MARK: - The composer

    public static let composerBG = RGBA(rgba: 0x0000_0038)
    public static let composerBorder = RGBA(rgba: 0xFFFF_FF14)

    /// spec §13.7 records this as declared and never applied — the composer has
    /// no focus ring today even though the colour and the focused state both
    /// exist. plan §3 closes it on the way past: it becomes a border keyed off
    /// the `NSTextView`'s first-responder state.
    public static let composerBorderActive = RGBA(rgba: 0x4FBD_835C)

    public static let composerPlaceholder = RGBA(rgb: 0x6A6A72)

    /// The `\u{203A}` at the head of the composer. The accent, because it marks
    /// where the caret is — the one thing in a pane that is about to act.
    public static let prompt = RGBA(rgb: 0x4FBD83)

    /// The row inside the box: the model on the left, `send \u{21B5}` on the right.
    /// A step under prose, like everything else that is chrome rather than
    /// conversation.
    public static let composerFoot = RGBA(rgb: 0x8A8A92)

    /// The keyboard hints below the box, a step under that again.
    public static let composerHint = RGBA(rgb: 0x6A6A72)

    // MARK: - The welcome state

    /// The wordmark, filled with a halftone of this rather than painted flat.
    public static let wordmark = RGBA(rgb: 0x4FBD83)

    /// The line under it — `What are we working on?`.
    public static let greeting = RGBA(rgb: 0xE2E2E6)

    /// The `//` before the suggestion, and the suggestion itself.
    public static let suggestionMark = RGBA(rgb: 0x4FBD83)
    public static let suggestion = RGBA(rgb: 0x8A8A92)
    public static let suggestionHover = RGBA(rgb: 0xE2E2E6)

    // MARK: - A browser pane's URL field

    /// The composer's colours under the URL field's own names, for the reason
    /// `addressPaddingX` carries in `Metrics`: they match today because both are
    /// a text field in a pane body, not because they are one control.
    public static let addressBG = RGBA(rgba: 0x0000_0038)
    public static let addressBorder = RGBA(rgba: 0xFFFF_FF14)
    public static let addressBorderActive = RGBA(rgba: 0x4FBD_835C)
    public static let addressPlaceholder = RGBA(rgb: 0x6A6A72)

    public static let caret = RGBA(rgb: 0x4FBD83)

    /// Selected text. Drawn as a background run on the shaped line rather than
    /// as a quad, so it follows the text around a wrap without any arithmetic
    /// here.
    public static let selectionBG = RGBA(rgba: 0x4FBD_8347)

    // MARK: - Icon buttons

    public static let icon = RGBA(rgb: 0x8A8A92)
    public static let iconHover = RGBA(rgb: 0xE2E2E6)
    public static let iconHoverBG = RGBA(rgba: 0xFFFF_FF14)
}
