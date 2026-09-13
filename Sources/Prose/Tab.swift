//  One entry in the vertical tab strip, and the panes it holds.

import ProseCore

/// What a pane is showing.
enum PaneKind: Sendable, Hashable {
    case agent
    case browser

    /// spec §8 asks for a bot here. SF Symbols has no bot — plan §4's symbol
    /// list quietly omits it, which is the eight-of-nine giveaway — so this is
    /// the one icon the port substitutes rather than translates. `cpu` is the
    /// nearest neutral machine glyph; `sparkles` would import an "AI feature"
    /// connotation prose deliberately avoids, since prose hosts agents it knows
    /// nothing about.
    var symbol: String {
        switch self {
        case .agent: "cpu"
        case .browser: "globe"
        }
    }

    /// What the header falls back to when nothing has named itself.
    var title: String {
        switch self {
        case .agent: "Agent"
        case .browser: "Browser"
        }
    }

    /// What the body says until there is something real to put in it.
    var placeholder: String {
        switch self {
        case .agent: "No session yet"
        case .browser: "No page yet"
        }
    }
}

/// What a pane is actually showing.
///
/// The split tree stores nothing but `PaneID`s — this is the other half of a
/// pane, kept beside it rather than in it, which is what lets all of
/// `Split.swift` stay pure and testable without a window.
struct Pane: Identifiable, Equatable {
    let id: PaneID
    var kind: PaneKind
    /// What the agent calls itself, once one says so. Until then the header
    /// falls back to the kind's own name (spec §8).
    var title: String?

    var displayTitle: String { title ?? kind.title }
}

struct Tab: Identifiable {
    let id: UInt64
    var title: String

    /// How this tab's panes are tiled. Holds ids only, so all of its geometry
    /// stays pure; what each pane actually is lives in `panes` beside it.
    var layout: Split

    var panes: [Pane]

    /// Which pane the keyboard is acting on. Kept per tab rather than on the
    /// workspace, so switching away and back returns to where you were — and so
    /// that closing a tab takes its focus state with it.
    var focused: PaneID?

    /// A new tab opens as a single pane filling the content area.
    init(id: UInt64, title: String, firstPane: PaneID) {
        self.id = id
        self.title = title
        layout = Split(firstPane)
        panes = [Pane(id: firstPane, kind: .agent, title: nil)]
        focused = firstPane
    }

    func pane(_ id: PaneID) -> Pane? {
        panes.first { $0.id == id }
    }

    /// Where each pane sits, paired with what it is showing. A pane in the
    /// layout but missing from `panes` has nothing to draw.
    func placed() -> [(pane: Pane, rect: UnitRect)] {
        layout.rects().compactMap { id, rect in
            pane(id).map { ($0, rect) }
        }
    }
}
