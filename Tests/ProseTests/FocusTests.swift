//  Where the keyboard is, which in a window holding a dozen agent sessions is
//  the difference between a multiplexer and a lottery.
//
//  spec §8 has one rule about it — focus must move *into* the pane, not merely
//  recolour its border — and spec §12 has the other: there are two keyboard
//  owners and the plain arrows belong to exactly one of them. Every test below
//  is one of those two sentences, and each exists because prose broke it.
//
//  The panes are hosted in a real off-screen window, the way the browser and
//  composer tests are: first responder is an AppKit question and there is no
//  answering it without one.

import AppKit
import ProseCore
import SwiftUI
import Testing
import WebKit

@testable import Prose

@MainActor
@Suite("Focus")
struct FocusTests {
    private struct Hosted {
        let workspace: Workspace
        let window: NSWindow
        let panes: [PaneID]
        let composers: [ComposerTextView]
    }

    private func composerViews(in view: NSView) -> [ComposerTextView] {
        (view as? ComposerTextView).map { [$0] } ?? view.subviews.flatMap(composerViews(in:))
    }

    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            _ = NSApplication.shared
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    private func window(showing workspace: Workspace) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: WorkspaceView().environment(workspace))
        // Off the edge of every display, so nothing appears in front of anyone.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        settle(window)
        return window
    }

    /// Two agent panes side by side.
    private func hosted() throws -> Hosted {
        let workspace = Workspace()
        let first = workspace.activeTab!.panes[0].id
        workspace.splitPane(first, .row)

        let window = window(showing: workspace)
        let composers = composerViews(in: window.contentView!)
        #expect(composers.count == 2, "two agent panes, two composers")
        return Hosted(
            workspace: workspace, window: window,
            panes: workspace.activeTab!.panes.map(\.id), composers: composers
        )
    }

    /// Panes are laid out left to right in the order they are listed, so a
    /// composer's position identifies its pane without the view having to know.
    private func composer(for pane: PaneID, in host: Hosted) -> ComposerTextView? {
        guard let index = host.panes.firstIndex(of: pane) else { return nil }
        return host.composers[index]
    }

    // MARK: - spec §8, focus moves into the pane

    @Test("clicking a pane takes the keyboard off the pane that had it")
    func clickingMovesTheKeyboard() throws {
        // This is the rule, and it did not hold: the request was left in state
        // for SwiftUI to notice, and moving focus between two panes changes
        // nothing SwiftUI can see, so the ring moved and the caret did not.
        let host = try hosted()
        let a = host.panes[0]
        let b = host.panes[1]

        host.workspace.focusPane(a)
        settle(host.window)
        #expect(host.window.firstResponder === composer(for: a, in: host))

        host.workspace.focusPane(b)
        settle(host.window)
        #expect(host.window.firstResponder === composer(for: b, in: host))
    }

    @Test("splitting hands the keyboard to the new pane, not just the ring")
    func splittingMovesTheKeyboard() throws {
        // A pane is asked for the keyboard at the moment it is created, which is
        // before it has a view to give it to — so this is also the test that the
        // request survives until the composer arrives in the window.
        let host = try hosted()
        let a = host.panes[0]
        host.workspace.focusPane(a)
        settle(host.window)
        #expect(host.window.firstResponder === composer(for: a, in: host))

        host.workspace.splitPane(a, .column)
        settle(host.window)

        #expect(host.workspace.focusedPane != a, "the split focused the new pane")
        // By object rather than by position: the pane list has grown and an
        // index map taken before it no longer means what it did.
        let after = composerViews(in: host.window.contentView!)
        let fresh = after.filter { composer in !host.composers.contains { $0 === composer } }
        #expect(fresh.count == 1, "one new composer")
        #expect(
            host.window.firstResponder === fresh.first,
            "typing after a split goes to the pane the split just made"
        )
    }

    @Test("closing a pane hands the keyboard to the survivor")
    func closingMovesTheKeyboard() throws {
        // The pane holding the keyboard has just gone, taking its first
        // responder with it, so the survivor needs more than the ring.
        let host = try hosted()
        let a = host.panes[0]
        let b = host.panes[1]
        host.workspace.focusPane(b)
        settle(host.window)

        host.workspace.closePane(b)
        settle(host.window)

        #expect(host.workspace.focusedPane == a)
        #expect(host.window.firstResponder === composer(for: a, in: host))
    }

    // MARK: - A request, once granted, is spent

    @Test("clicking a pane whose composer already has the keyboard changes nothing")
    func clickingAFocusedPaneIsIdempotent() throws {
        // The request used to be left standing, because it was only cleared when
        // it was acted on and there was nothing to do. It was then redeemed by
        // the next redraw in which the composer was *not* first responder.
        let host = try hosted()
        let a = host.panes[0]
        let agent = try #require(host.workspace.agent(a))

        host.workspace.focusPane(a)
        settle(host.window)
        host.workspace.focusPane(a)
        settle(host.window)

        #expect(!agent.wantsComposerFocus, "nothing to ask for: it already has the keyboard")
    }

    @Test("zooming does not pull the caret out of a page and into a composer")
    func zoomingDoesNotMoveTheKeyboard() throws {
        // What an unspent request actually cost: click an agent pane twice,
        // click into the page next door, press Cmd+= — and the caret left the
        // page. Any redraw would do it; the zoom is merely the easiest to write.
        let workspace = Workspace()
        let a = workspace.activeTab!.panes[0].id
        workspace.splitPane(a, .row)
        let b = workspace.activeTab!.focused!
        workspace.setPaneKind(b, .browser)
        let browser = try #require(workspace.browser(b))
        browser.hasPage = true
        browser.webView.loadHTMLString("<html><body>hi</body></html>", baseURL: nil)

        let window = window(showing: workspace)
        workspace.focusPane(a)
        settle(window)
        workspace.focusPane(a)
        settle(window)

        #expect(window.makeFirstResponder(browser.webView))
        settle(window)
        #expect(holdsTheKeyboard(browser.webView, in: window), "the click landed in the page")

        workspace.zoom(by: 1)
        settle(window)

        #expect(holdsTheKeyboard(browser.webView, in: window))
    }

    /// Whether the web view, or anything WebKit put inside it, is the window's
    /// first responder — the responder is an inner content view rather than the
    /// `WKWebView` itself, so identity alone is not the question.
    private func holdsTheKeyboard(_ webView: PaneWebView, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    // MARK: - spec §12, the keyboard has to land somewhere

    /// Whether anything in the view tree holds the keyboard, as opposed to the
    /// window itself — which is the end of the responder chain and answers to
    /// nothing, so the plain arrows reach no `onMoveCommand` from there.
    private func aViewHoldsTheKeyboard(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: window.contentView!)
    }

    @Test("Escape from a composer gives the keyboard to the tab strip, not the window")
    func escapeLandsOnTheStrip() throws {
        let host = try hosted()
        let a = host.panes[0]
        host.workspace.focusPane(a)
        settle(host.window)
        let view = try #require(composer(for: a, in: host))
        #expect(host.window.firstResponder === view)

        // Exactly what AppKit does with an unmodified Escape.
        view.cancelOperation(nil)
        settle(host.window)

        #expect(host.workspace.keyboardOwner == .tabStrip)
        #expect(host.window.firstResponder !== view, "the composer let go")
        #expect(
            aViewHoldsTheKeyboard(in: host.window),
            "and the arrows the strip now owns have a view to arrive at"
        )
    }

    @Test("switching tabs leaves the keyboard in the window's view tree")
    func tabSwitchLandsOnTheStrip() throws {
        // The outgoing tab's panes are torn down, taking first responder with
        // them, so this is a handback whether or not anyone asked for one.
        let host = try hosted()
        host.workspace.focusPane(host.panes[0])
        settle(host.window)

        host.workspace.newTab()
        settle(host.window)

        #expect(host.workspace.keyboardOwner == .tabStrip)
        #expect(aViewHoldsTheKeyboard(in: host.window))
    }

    @Test("stepping onto a page hands the keyboard to the content area")
    func steppingOntoAPageLandsOnTheContentArea() throws {
        // spec §8: a browser pane showing a page takes nothing, because the
        // content area holds the keyboard on its behalf — which it can only do
        // if it is actually given it. Releasing alone meant the one keystroke
        // that moved onto a page was the last one that moved anywhere.
        let workspace = Workspace()
        let a = workspace.activeTab!.panes[0].id
        workspace.splitPane(a, .row)
        let b = workspace.activeTab!.focused!
        workspace.setPaneKind(b, .browser)
        let browser = try #require(workspace.browser(b))
        browser.hasPage = true
        browser.webView.loadHTMLString("<html><body>hi</body></html>", baseURL: nil)

        let window = window(showing: workspace)
        workspace.focusPane(a)
        settle(window)

        workspace.stepPaneFocus(.right)
        settle(window)

        #expect(workspace.focusedPane == b)
        #expect(workspace.keyboardOwner == .content)
        #expect(!holdsTheKeyboard(browser.webView, in: window), "arriving by keyboard is not a click")
        #expect(
            aViewHoldsTheKeyboard(in: window),
            "the content area owns the plain arrows, so it has to be able to hear them"
        )
    }

    // MARK: - spec §12, one keyboard, and it belongs to the tab on screen

    @Test("an agent bringing a pane into view does not take the keyboard")
    func revealDoesNotTakeTheKeyboard() throws {
        // `pane.focus` means "bring a pane into view" (spec §14). It used to run
        // through the same door a click does, so an agent could take the caret
        // out of the middle of a sentence being typed in another pane.
        let host = try hosted()
        let a = host.panes[0]
        let b = host.panes[1]
        host.workspace.focusPane(a)
        settle(host.window)

        host.workspace.revealPane(b)
        settle(host.window)

        #expect(host.workspace.focusedPane == b, "the ring moved")
        #expect(
            host.window.firstResponder === composer(for: a, in: host),
            "and the keyboard did not"
        )
    }

    @Test("an agent revealing a pane in another tab brings that tab forward")
    func revealSelectsTheTab() {
        let workspace = Workspace()
        let elsewhere = workspace.activeTab!.panes[0].id
        let first = workspace.active
        workspace.newTab()
        #expect(workspace.active != first)

        workspace.revealPane(elsewhere)

        #expect(workspace.active == first, "brought into view, which is what pane.focus means")
        #expect(workspace.activeTab?.focused == elsewhere)
    }

    @Test("focusing a pane in a tab nobody is looking at moves the ring only")
    func backgroundTabKeepsItsHandsOffTheKeyboard() {
        // Each tab remembers its own focused pane, but there is one keyboard and
        // it belongs to the tab on screen. An agent splitting or focusing a pane
        // two tabs away used to repoint the plain arrows at the content area and
        // leave an unspent claim on a composer nobody could see.
        let workspace = Workspace()
        let hidden = workspace.activeTab!.panes[0].id
        workspace.newTab()
        #expect(workspace.keyboardOwner == .tabStrip)

        workspace.focusPane(hidden)
        #expect(workspace.keyboardOwner == .tabStrip)
        #expect(workspace.agent(hidden)?.wantsComposerFocus == false)

        workspace.splitPane(hidden, .row)
        #expect(workspace.keyboardOwner == .tabStrip)
    }
}
