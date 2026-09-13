//  The panes themselves, plus a grab strip over every divider.
//
//  A tab's panes are laid out by walking its split tree into fractions of this
//  area and placing each pane by hand, rather than by mirroring the tree in
//  nested stacks. plan §6.5 is firm about this and spec §7.2 says why: it keeps
//  one pure function — `Split.rects()` — as the single answer to where a pane
//  is, which the dividers, the keyboard's focus movement and (later) a browser
//  pane's native view all need too. Nested `HStack`s would be a second answer,
//  and two answers can disagree.

import ProseCore
import SwiftUI

/// The coordinate space a divider drag is measured in. Named rather than local,
/// because the strip itself moves as the fraction changes and a translation
/// measured against a moving frame chases its own tail.
private let tilingSpace = "prose.tiling"

struct Tiling: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m

    /// Half the gutter here and half on each pane cell, so the margin around
    /// the outside of the tiling matches the gap between any two panes.
    ///
    /// gpui needed a *wrapper* rather than padding on the tiling itself, since
    /// an absolutely positioned child lays out against its container's border
    /// box and padding there would have moved nothing. spec §7.2 notes that a
    /// port doing manual frame arithmetic can simply inset instead, which is
    /// what this is: the container is inset by half, and each cell insets
    /// itself by the other half.
    private var half: CGFloat { m.px(.paneGap / 2) }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            ZStack(alignment: .topLeading) {
                if let tab = workspace.activeTab {
                    ForEach(tab.placed(), id: \.pane.id) { pane, rect in
                        PaneView(pane: pane, focused: tab.focused == pane.id)
                            .frame(
                                width: max(0, rect.w * size.width - half * 2),
                                height: max(0, rect.h * size.height - half * 2)
                            )
                            .offset(
                                x: rect.x * size.width + half,
                                y: rect.y * size.height + half
                            )
                    }

                    // After the panes, so a strip is never buried under the
                    // pane it divides.
                    ForEach(tab.layout.dividers(), id: \.split) { divider in
                        DividerStrip(divider: divider, tiling: size)
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .coordinateSpace(.named(tilingSpace))
        }
        .padding(half)
    }
}

/// An invisible strip centred on a divider, with a hairline down the middle of
/// it that is invisible until hovered — the same shape as the sidebar's resize
/// handle, and for the same reason: the line itself is too thin to hit.
private struct DividerStrip: View {
    let divider: ProseCore.Divider
    /// The tiling's own pixel size. A drag reads the pointer in real pixels and
    /// has to turn that into a fraction of *this split's* region, so it needs
    /// to know how big the area actually is.
    ///
    /// gpui had to record this from a canvas element every frame because only
    /// layout knew it; a `GeometryReader` hands it straight to the strip, so the
    /// workspace stores no content bounds at all.
    let tiling: CGSize

    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m

    @State private var hovering = false
    @State private var startFraction: Double?

    private var thickness: CGFloat { m.px(.resizeHandle) }
    private var lit: Bool { hovering || startFraction != nil }

    var body: some View {
        let line = divider.line
        let horizontal = divider.axis == .row

        // The strip has to straddle the line rather than start at it, so it is
        // pulled back by half its own thickness.
        let width = horizontal ? thickness : line.w * tiling.width
        let height = horizontal ? line.h * tiling.height : thickness
        let x = horizontal ? line.x * tiling.width - thickness / 2 : line.x * tiling.width
        let y = horizontal ? line.y * tiling.height : line.y * tiling.height - thickness / 2

        Rectangle()
            .fill(Color(.transparent))
            .frame(width: max(0, width), height: max(0, height))
            .overlay(alignment: horizontal ? .leading : .top) {
                Rectangle()
                    .fill(Color(lit ? Palette.dividerActive : .transparent))
                    .frame(
                        width: horizontal ? m.px(.hairline) : nil,
                        height: horizontal ? nil : m.px(.hairline)
                    )
                    .offset(
                        x: horizontal ? m.px(.resizeHandle / 2 - 0.5) : 0,
                        y: horizontal ? 0 : m.px(.resizeHandle / 2 - 0.5)
                    )
            }
            .contentShape(Rectangle())
            .offset(x: x, y: y)
            .onHover { hovering = $0 }
            .pointerStyle(horizontal ? .columnResize : .rowResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(tilingSpace))
                    .onChanged { value in
                        // Read once, so the whole gesture is measured from
                        // where it started rather than accumulating per frame.
                        let start = startFraction ?? workspace.fraction(of: divider.split)
                        guard let start else { return }
                        startFraction = start

                        workspace.resizeDivider(
                            divider.split,
                            startFraction: start,
                            delta: horizontal ? value.translation.width : value.translation.height,
                            parentPx: horizontal
                                ? divider.area.w * tiling.width
                                : divider.area.h * tiling.height,
                            // The only point measurement in the sum, so the only
                            // one that has to be scaled.
                            minPx: m.px(horizontal ? .paneMinWidth : .paneMinHeight)
                        )
                    }
                    // AppKit always delivers this, even when the button is
                    // released outside the window (plan §4).
                    .onEnded { _ in startFraction = nil }
            )
    }
}
