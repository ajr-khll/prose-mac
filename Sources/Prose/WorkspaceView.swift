//  The root view: sidebar, a hairline divider, and the content area.

import ProseCore
import SwiftUI

struct WorkspaceView: View {
    @Environment(Workspace.self) private var workspace

    /// The keyboard, when it is the workspace's own rather than a pane's.
    ///
    /// spec §12's two owners are both *this* view — which one has the arrows is
    /// `keyboardOwner`, below. What this is for is having them at all: a pane
    /// that gives the keyboard up gives it to the window unless somebody takes
    /// it, and the window is the end of the responder chain.
    @FocusState private var region: Bool

    var body: some View {
        let m = workspace.metrics
        // The panel's width this frame. Both this and the divider animate from
        // the same state, so at rest collapsed neither is drawn at all.
        let panelWidth: CGFloat = workspace.sidebarOpen ? m.px(workspace.sidebarRestingWidth) : 0
        let dividerWidth: CGFloat = workspace.sidebarOpen ? m.px(.hairline) : 0
        let sidebarPoints: Points = workspace.sidebarOpen ? workspace.sidebarRestingWidth : .zero

        HStack(spacing: 0) {
            SidebarView(width: panelWidth)

            Rectangle()
                .fill(Color(Palette.divider))
                .frame(width: dividerWidth)

            ContentArea(sidebarWidth: sidebarPoints)
                // Without this the content area's intrinsic width would stop it
                // shrinking below its contents when the sidebar is dragged wider.
                .frame(minWidth: 0)
        }
        .background {
            // macOS blurs what is behind the window; prose paints one
            // translucent wash over that (spec §4).
            WindowBlur().overlay(Color(Palette.windowBG))
        }
        .overlay(alignment: .topLeading) { SidebarToggle() }
        .overlay(alignment: .topLeading) { SidebarResizeHandle(width: panelWidth) }
        .background(WindowChrome())
        .environment(\.metrics, m)
        .font(m.font(.textSize))
        .foregroundStyle(Color(Palette.text))
        .frame(
            minWidth: CGFloat(Pixels.windowMinWidth),
            minHeight: CGFloat(Pixels.windowMinHeight)
        )
        // spec §12's two keyboard owners. Which one holds the plain arrow keys
        // is a property of the workspace rather than of SwiftUI's focus system,
        // because the question is which *region* the keyboard is aimed at, not
        // which control has it — and from step 5 a focused agent pane will hold
        // a real first responder inside the content area.
        .focusable()
        .focusEffectDisabled()
        .focused($region)
        // Every route out of a pane — Escape, a tab switch, stepping onto a
        // page — asks for the keyboard back here rather than dropping it.
        .onChange(of: workspace.keyboardReclaim) { region = true }
        .onMoveCommand { direction in
            switch workspace.keyboardOwner {
            case .tabStrip:
                switch direction {
                case .up: workspace.step(-1)
                case .down: workspace.step(1)
                default: break
                }
            case .content:
                // A browser pane has no field of its own, so the content area
                // holds the keyboard on its behalf and the plain arrows move
                // between panes.
                switch direction {
                case .up: workspace.stepPaneFocus(.up)
                case .down: workspace.stepPaneFocus(.down)
                case .left: workspace.stepPaneFocus(.left)
                case .right: workspace.stepPaneFocus(.right)
                @unknown default: break
                }
            }
        }
        // spec §12 has Cmd+W close the focused pane outright. prose asks first:
        // a pane holds a live agent session and its whole transcript, neither of
        // which comes back, and the chord sits one key away from Cmd+Q. Bound to
        // the workspace rather than raised at each call site so the menu item
        // and the pane header's × put up the same alert.
        .alert(
            "Close this pane?",
            isPresented: Binding(
                get: { workspace.paneCloseRequest != nil },
                // Only ever set by SwiftUI dismissing the alert itself, which
                // is a cancel — the buttons below clear the request first.
                set: { if !$0 { workspace.cancelClosePane() } }
            )
        ) {
            Button("Cancel", role: .cancel) { workspace.cancelClosePane() }
            Button("Close Pane", role: .destructive) { workspace.confirmClosePane() }
        } message: {
            Text("Its agent is ended and its transcript is discarded. This cannot be undone.")
        }
        // spec §12 gives the tab strip the **plain** keys — `Enter starts a
        // rename` sits in a list of what the unmodified keys do, and the port's
        // note under it says the composer must be able to take Enter without
        // the window's own shortcuts intercepting it.
        //
        // `.onKeyPress(.return)` matches the key and ignores the modifiers, so
        // Shift+Enter renamed a tab. That is reachable without doing anything
        // odd: Escape in a composer with no turn running hands the keyboard back
        // to the strip (spec §9.6), and a cold launch starts there too — so the
        // next Shift+Enter, meant as a newline, opened a rename field instead.
        .onKeyPress(keys: [.return], phases: .down) { press in
            // `.isEmpty` would be wrong: a keyboard can report caps lock or the
            // numeric pad in here, and neither makes this a different key.
            let held = press.modifiers.intersection([.shift, .command, .option, .control])
            guard held.isEmpty,
                workspace.keyboardOwner == .tabStrip,
                let active = workspace.active
            else {
                return .ignored
            }
            workspace.beginRename(active)
            return .handled
        }
    }
}

/// Anchored to the window rather than to the panel, so it holds its place
/// beside the traffic lights whether the panel is out or in.
///
/// It is window chrome, so it does not zoom at all: the traffic lights beside
/// it are drawn by macOS at a fixed size, and a button that grew would both
/// dwarf them and slide off their centre line. Pinning only the centre would not
/// save it — at 2.0× a 44px button centred on the lights would overflow the top
/// of the window.
private struct SidebarToggle: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        IconButton(symbol: "sidebar.left", scale: 1) {
            workspace.toggleSidebar()
        }
        .offset(
            x: Points.toggleCenterX.value - Points.buttonSize.value / 2,
            y: (Pixels.headerHeight.value - Points.buttonSize.value) / 2
        )
    }
}

/// An invisible strip straddling the divider, pulled back by half its thickness
/// so it straddles the line rather than starting at it. The hairline underneath
/// lights up on hover and stays lit for the length of a drag, so the sidebar
/// advertises that its edge can be moved.
private struct SidebarResizeHandle: View {
    let width: CGFloat

    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m
    @State private var hovering = false
    @State private var dragging = false
    @State private var widthAtDragStart: Points?

    var body: some View {
        let lit = hovering || dragging

        Rectangle()
            .fill(Color(.transparent))
            .frame(width: m.px(.resizeHandle))
            .frame(maxHeight: .infinity)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(Color(lit ? Palette.dividerActive : .transparent))
                    .frame(width: m.px(.hairline))
                    .offset(x: m.px(.resizeHandle / 2 - 0.5))
            }
            .contentShape(Rectangle())
            .offset(x: width + m.px(0.5 - .resizeHandle / 2))
            .onHover { hovering = $0 }
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        let start = widthAtDragStart ?? workspace.sidebarRestingWidth
                        widthAtDragStart = start
                        // The pointer arrives in real pixels but the resting
                        // width is stored in points, so the delta is divided by
                        // the zoom (spec §3).
                        workspace.resizeSidebar(
                            to: start + Points(value.translation.width / m.zoom)
                        )
                    }
                    // AppKit always delivers this, even when the button is
                    // released outside the window, so the original's shared
                    // "next move without the button held ends the drag" guard
                    // is gone (plan §4).
                    .onEnded { _ in
                        dragging = false
                        widthAtDragStart = nil
                    }
            )
            // The handle is only there while the panel is.
            .opacity(width > 0 ? 1 : 0)
            .allowsHitTesting(width > 0)
    }
}
