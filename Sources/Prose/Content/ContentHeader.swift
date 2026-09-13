//  The content area's chrome row, level with the sidebar's header and the
//  traffic lights.
//
//  Step 2 builds this row and nothing below it. The tiling, the dividers and
//  the panes are step 3, and `Split.rects()` is already waiting in ProseCore
//  for them.

import ProseCore
import SwiftUI

struct ContentArea: View {
    /// The sidebar's resting width in points, or zero once it has collapsed.
    /// The header insets itself against this so the window-anchored toggle is
    /// never covered.
    let sidebarWidth: Points

    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m

    var body: some View {
        VStack(spacing: 0) {
            ContentHeader(sidebarWidth: sidebarWidth)
            Tiling()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ContentHeader: View {
    let sidebarWidth: Points

    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m

    var body: some View {
        Text(workspace.activeTab?.title ?? "")
            .font(m.font(.contentHeaderTextSize))
            .foregroundStyle(Color(Palette.paneTitle))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, m.px(.paneGap))
            .padding(.leading, leadingInset)
            // 40px and fixed at every zoom for the same reason the sidebar's
            // header is: it has to stay level with the traffic-light row across
            // the divider.
            .frame(height: CGFloat(Pixels.contentHeaderHeight))
    }

    /// spec §7.1's inset, plus the 8pt gutter.
    ///
    /// The spec flags the mixed arithmetic as deliberate and worth preserving:
    /// the inset is in real pixels because the toggle it clears does not zoom,
    /// and the gutter added to it is a point measurement used unscaled. The
    /// original reads `px(content_header_inset(..) + PANE_GAP)`, so the gutter
    /// does not scale here either — `Pixels.unscaled` makes that visible rather
    /// than silent.
    private var leadingInset: CGFloat {
        let inset = contentHeaderInset(sidebarWidth: sidebarWidth, zoom: m.zoom)
        return CGFloat(inset + Pixels.unscaled(.paneGap))
    }
}
