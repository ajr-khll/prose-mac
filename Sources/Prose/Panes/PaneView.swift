//  One pane: the frame around whatever a tab is showing, plus the header strip
//  that names it and carries its buttons.
//
//  The body is still a placeholder. An agent pane's transcript and composer are
//  step 5 and a browser pane's `WKWebView` is step 4; what is here is spec §8's
//  chrome, which both of them will sit inside.

import ProseCore
import SwiftUI

struct PaneView: View {
    let pane: Pane
    /// Recolours the border rather than adding one — the border is permanent so
    /// that focusing a pane cannot shift its contents by a pixel, the same
    /// trick the tab rows use for the sliding selection.
    let focused: Bool

    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m

    /// The browser behind a browser pane, if this is one.
    private var browser: BrowserSession? {
        pane.kind == .browser ? workspace.browser(pane.id) : nil
    }

    private var agent: AgentSession? {
        pane.kind == .agent ? workspace.agent(pane.id) : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneHeader(pane: pane, browser: browser, agent: agent)
            body(for: pane)
        }
        .background(Color(Palette.paneBG))
        .clipShape(RoundedRectangle(cornerRadius: m.px(.paneRadius)))
        .overlay(
            RoundedRectangle(cornerRadius: m.px(.paneRadius))
                .strokeBorder(
                    Color(focused ? Palette.paneActiveBorder : Palette.paneBorder),
                    lineWidth: m.px(.paneBorder)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: m.px(.paneRadius)))
        // Clicking anywhere in a pane makes it the focused one, which is what
        // the arrow keys and the split shortcuts act on. The header's own
        // buttons are `Button`s and consume their taps, so closing a pane does
        // not also focus the one that was just closed.
        .onTapGesture { workspace.focusPane(pane.id) }
    }

    @ViewBuilder
    private func body(for pane: Pane) -> some View {
        if let browser {
            BrowserPaneBody(session: browser)
        } else if let agent {
            AgentPaneBody(session: agent)
        } else {
            Text(pane.kind.placeholder)
                .font(m.font(.textSize))
                .foregroundStyle(Color(Palette.panePlaceholder))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 26pt, padding-x 8, 4pt gaps.
///
/// The header is the one part of a pane guaranteed to still take a click once a
/// browser pane's page is a real view inside it.
private struct PaneHeader: View {
    let pane: Pane
    let browser: BrowserSession?
    let agent: AgentSession?

    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m

    var body: some View {
        HStack(spacing: m.px(.tabGap)) {
            Image(systemName: pane.kind.symbol)
                .font(m.font(.paneIconSize))
                .foregroundStyle(Color(Palette.paneTitle))

            // Sized to its text with the spacer below doing the pushing, never
            // flexed. In gpui a flexed title measured against a pane that had no
            // width on its first pass and the result was cached, so every title
            // in the window truncated to the same few characters. SwiftUI does
            // not have that bug, but the design wants this anyway: the status
            // must never be squeezed out by a long title (spec §8).
            Text(pane.displayTitle)
                .font(m.font(.contentHeaderTextSize))
                .foregroundStyle(Color(Palette.paneTitle))
                .lineLimit(1)
                .fixedSize()

            Spacer(minLength: 0)

            // spec §8: `thinking…` while a turn is running, otherwise the
            // agent's status field values joined with ` · `. Nothing when there
            // is neither. Sized to its text like the title, never flexed, so a
            // long title cannot squeeze it out.
            if let status {
                Text(status)
                    .font(m.font(.statusTextSize))
                    .foregroundStyle(Color(Palette.activityDetail))
                    .lineLimit(1)
                    .fixedSize()
            }

            // Three more header buttons, matching the three that are already
            // there (plan §2). `canGoBack` and `canGoForward` are KVO
            // properties, so keeping them right costs an observation each.
            if let browser {
                PaneHeaderButton(symbol: "chevron.left", enabled: browser.canGoBack) {
                    browser.goBack()
                }
                PaneHeaderButton(symbol: "chevron.right", enabled: browser.canGoForward) {
                    browser.goForward()
                }
                // One button rather than two, because which of reload and stop
                // is wanted is never ambiguous — it is whichever one the page is
                // not already doing. It is also the only header button whose
                // glyph changes, which is what makes a load visible in a pane
                // too small to show the hairline moving.
                PaneHeaderButton(
                    symbol: browser.isLoading ? "xmark" : "arrow.clockwise",
                    enabled: browser.hasPage
                ) {
                    browser.reloadOrStop()
                }
            }

            PaneHeaderButton(symbol: "rectangle.split.2x1") {
                workspace.splitPane(pane.id, .row)
            }
            PaneHeaderButton(symbol: "rectangle.split.1x2") {
                workspace.splitPane(pane.id, .column)
            }
            // The same question Cmd+W asks, since a click here is just as easy
            // to make by accident as the chord is.
            PaneHeaderButton(symbol: "xmark") {
                workspace.requestClosePane(pane.id)
            }
        }
        .padding(.horizontal, m.px(.paneHeaderPaddingX))
        .frame(height: m.px(.paneHeaderHeight))
        .frame(maxWidth: .infinity)
        .background(Color(Palette.paneHeaderBG))
        .overlay(alignment: .bottomLeading) { loadingHairline }
    }

    private var status: String? {
        guard let agent else { return nil }
        if agent.transcript.isRunning { return "thinking…" }
        let fields = agent.transcript.statusInOrder.map(\.value)
        return fields.isEmpty ? nil : fields.joined(separator: " · ")
    }

    /// `estimatedProgress` as a hairline along the bottom of the header.
    ///
    /// In `activity_running` because that is already the app's word for "this
    /// is happening" (spec §4's one-accent rule), and on the header rather than
    /// over the page because the header is the part of a pane that is always
    /// prose's.
    @ViewBuilder
    private var loadingHairline: some View {
        if let browser, browser.isLoading {
            GeometryReader { geometry in
                Rectangle()
                    .fill(Color(Palette.activityRunning))
                    .frame(width: geometry.size.width * browser.progress)
            }
            .frame(height: m.px(.hairline))
        }
    }
}

/// A bare icon in a square hit area.
///
/// Sized in **points** rather than the real pixels `IconButton` uses, because
/// nothing in a pane header has to line up with the traffic lights — these are
/// content and should grow with the zoom (spec §8).
private struct PaneHeaderButton: View {
    let symbol: String
    /// A history button with nowhere to go dims rather than disappearing, so
    /// the header keeps its shape as a page gains and loses history — the same
    /// reason every border in the app is permanent and only recolours (spec §4).
    var enabled = true
    let action: () -> Void

    @Environment(\.metrics) private var m
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(m.font(.closeSize))
                .foregroundStyle(Color(hovering && enabled ? Palette.iconHover : Palette.icon))
                .opacity(enabled ? 1 : 0.35)
                .frame(width: m.px(.closeBox), height: m.px(.closeBox))
                .background(
                    RoundedRectangle(cornerRadius: m.px(.smallRadius))
                        .fill(Color(hovering && enabled ? Palette.iconHoverBG : .transparent))
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
    }
}
