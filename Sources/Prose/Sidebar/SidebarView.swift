//  The Arc-style vertical tab strip down the left of the window.
//
//  Three stacked sections in a fixed-width column: a header that shares its row
//  with the macOS traffic lights, the scrolling tab list, and a footer holding
//  settings. The 1pt divider hairline sits to its right, outside it, and is
//  drawn by the root view.

import ProseCore
import SwiftUI

struct SidebarView: View {
    /// This frame's animated width, which is narrower than the resting width
    /// while the panel is sliding.
    let width: CGFloat

    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m

    private var resting: CGFloat { m.px(workspace.sidebarRestingWidth) }

    var body: some View {
        VStack(spacing: 0) {
            SidebarHeader()
            TabList()
            SidebarFooter()
        }
        // The contents do not reflow. The panel is a clipped box of the
        // animated width holding a child pinned at the full resting width and
        // offset by `width - resting`, so the sidebar *slides away to the left*
        // rather than squeezing (spec §6.1).
        .frame(width: resting, alignment: .leading)
        .offset(x: width - resting)
        .frame(width: width, alignment: .leading)
        .clipped()
    }
}

/// 40px tall and fixed at every zoom, because macOS draws the traffic lights in
/// this row at a size that ignores prose's zoom. Holds only the new-tab `+`,
/// right-aligned onto the shared `×` column; the reveal toggle is drawn by the
/// root view so that it stays beside the lights while this panel moves.
private struct SidebarHeader: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m

    var body: some View {
        IconButton(symbol: "plus", scale: m.headerButtonScale) {
            workspace.newTab()
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Both terms in real pixels: a scaled padding would not agree with an
        // unscaled button, and the button's *centre* has to keep riding the
        // scaled `×` column so the two stay aligned (spec §6.2).
        .padding(
            .trailing,
            Points.trailingCenterFromRight.value * m.zoom
                - Points.buttonSize.value * m.headerButtonScale / 2
        )
        .frame(height: CGFloat(Pixels.headerHeight))
    }
}

/// A scrolling column, inset 7 left and 10.5 right, rows gapped by 2.
private struct TabList: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m

    var body: some View {
        ScrollView(.vertical) {
            ZStack(alignment: .topLeading) {
                // Rendered before the rows so it sits behind them, and absolute
                // so it takes no part in the column's flow and does not disturb
                // the gap.
                if let offset = workspace.selectionOffset {
                    highlight.offset(y: m.px(offset))
                }

                VStack(spacing: m.px(.rowGap)) {
                    ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                        TabRow(tab: tab, nearness: nearness(workspace.selectionOffset, index))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.never)
        .padding(.leading, m.px(.rowInsetLeft))
        .padding(.trailing, m.px(.rowInsetRight))
        .frame(maxHeight: .infinity)
    }

    /// The selected tab's border and wash, lifted out of the rows so there is
    /// one of it for the whole strip and it can slide between them.
    ///
    /// On macOS 26 it is a pane of Liquid Glass, tinted rather than filled. The
    /// material suits what this element already was — a single thing that
    /// slides over the rows — because glass refracts what it passes over
    /// instead of covering it, so a title stays legible underneath and the
    /// highlight reads as something laid on the strip rather than painted into
    /// it. Below 26 it stays the flat fill, which is also what spec §5's
    /// acceptance measurements were taken against.
    private var highlight: some View {
        let shape = RoundedRectangle(cornerRadius: m.px(.rowRadius))

        return Group {
            if #available(macOS 26.0, *) {
                shape
                    .fill(.clear)
                    // Tinting keeps the accent's meaning while letting the
                    // material carry the depth the flat wash had to imply.
                    .glassEffect(.regular.tint(Color(Palette.tabActiveBG)), in: shape)
            } else {
                shape.fill(Color(Palette.tabActiveBG))
            }
        }
        .overlay(
            shape.strokeBorder(Color(Palette.tabActiveBorder), lineWidth: m.px(.rowBorder))
        )
        .frame(maxWidth: .infinity)
        .frame(height: m.px(.rowHeight))
    }
}

/// A full-width hairline inset from the divider, then the settings row.
private struct SidebarFooter: View {
    @Environment(\.metrics) private var m

    var body: some View {
        VStack(spacing: 0) {
            // Stops short of the vertical divider so the two lines do not meet
            // in a hard corner.
            Rectangle()
                .fill(Color(Palette.separator))
                .frame(height: m.px(.hairline))
                .padding(.trailing, m.px(.dividerGap))

            // The settings button does nothing — there is nowhere for settings
            // to go yet (spec §6.6, spec §13.2).
            IconButton(symbol: "gearshape", scale: m.zoom) {}
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, m.px(.settingsCenterX - .buttonSize / 2))
                .frame(height: m.px(.footerHeight))
        }
    }
}
