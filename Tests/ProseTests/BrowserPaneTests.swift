import AppKit
import Network
import ProseCore
import SwiftUI
import Testing
import WebKit

@testable import Prose

/// plan §2's claims, checked against a real view hierarchy.
///
/// The port's whole rationale rests on "in AppKit every one of those costs is
/// zero", so the costs are measured rather than taken on trust. The pane is
/// hosted in an **off-screen window**: `NSHostingView` builds the same tree it
/// would on screen, the `WKWebView` becomes a real subview with a real frame,
/// and none of it needs a display — which also means these run in CI, and on a
/// locked machine.
/// **Serialized.** Every test here drives a real `WKWebView` by turning the
/// main run loop by hand, and Swift Testing runs a suite's tests in parallel by
/// default — so without this they pump *each other's* loads, and a wait for one
/// page is satisfied by somebody else's. That presents as an intermittent nil
/// where an answer should be, which is a bad afternoon to debug.
@MainActor
@Suite("Browser pane", .serialized)
struct BrowserPaneTests {
    /// A workspace whose second pane is a browser, hosted in a window the size
    /// the real one launches at.
    private struct Hosted {
        let workspace: Workspace
        let window: NSWindow
        let webView: PaneWebView
        let pane: PaneID
    }

    private func hosted() throws -> Hosted {
        let workspace = Workspace()
        let first = workspace.activeTab!.panes[0].id
        workspace.splitPane(first, .row)
        let browserPane = workspace.activeTab!.focused!
        workspace.setPaneKind(browserPane, .browser)
        let session = try #require(workspace.browser(browserPane))

        // A pane nobody has asked for a page shows spec §8's label instead of
        // an empty page, so the body has to have been asked for something
        // before there is a web view in the tree to make claims about.
        session.hasPage = true
        session.webView.loadHTMLString(
            "<html><body style='background:#ff2d55'></body></html>", baseURL: nil
        )

        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: Pixels.windowWidth.value, height: Pixels.windowHeight.value
            ),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(
            rootView: WorkspaceView().environment(workspace)
        )
        // Off the edge of every display, so nothing appears in front of anyone.
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        settle(window)

        return Hosted(
            workspace: workspace, window: window, webView: session.webView, pane: browserPane
        )
    }

    /// SwiftUI applies state changes on the run loop, so a hierarchy assertion
    /// has to let it get there first.
    private func settle(_ window: NSWindow) {
        for _ in 0..<4 {
            pump(0.05)
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    /// Runs the main run loop for a moment.
    ///
    /// WebKit does its loading over IPC and gets nowhere unless the run loop is
    /// actually turning, which under `swift test` it is not: there is no
    /// `NSApplication` running one. Touching `NSApplication.shared` sets the
    /// app object up, and `CFRunLoopRunInMode` turns the loop by hand.
    private func pump(_ seconds: Double) {
        _ = NSApplication.shared
        CFRunLoopRunInMode(.defaultMode, seconds, false)
    }

    /// Turns the run loop until `condition` holds, or gives up.
    private func wait(upTo seconds: Double, for condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { pump(0.05) }
    }

    /// Every `PaneWebView` under a view, however deep.
    private func webViews(in view: NSView) -> [PaneWebView] {
        (view as? PaneWebView).map { [$0] } ?? view.subviews.flatMap(webViews(in:))
    }

    @Test("the web view is an ordinary subview, not an overlay")
    func itIsAnOrdinarySubview() throws {
        let host = try hosted()
        let found = webViews(in: host.window.contentView!)
        let webView = host.webView

        #expect(found.count == 1, "exactly one web view, inside the pane that owns it")
        #expect(found.first === webView)
        // In gpui this had to be a sibling of the renderer's single Metal view,
        // added to the window rather than to anything prose drew. Here it has a
        // superview inside the pane.
        #expect(webView.superview != nil)
    }

    @Test("an ancestor layer clips the page")
    func thePageIsClipped() throws {
        // gpui: "no rounded corners or clipping". The pane's 8pt radius is a
        // `.clipShape`, which becomes a mask on a layer above the web view.
        let webView = try hosted().webView

        var clipped = false
        var view: NSView? = webView
        while let current = view {
            if let layer = current.layer,
               layer.mask != nil || layer.masksToBounds || layer.cornerRadius > 0
            {
                clipped = true
                break
            }
            view = current.superview
        }
        #expect(clipped, "nothing in the chain clips the page")
    }

    @Test("the pane header is not covered by the page")
    func theHeaderSurvives() throws {
        // gpui: "paints above every other element". If that were still true the
        // header — the one part of a pane guaranteed to take a click (spec §8) —
        // would be underneath the page.
        let host = try hosted()
        let metrics = host.workspace.metrics

        let frame = host.webView.convert(host.webView.bounds, to: nil)
        let topFromWindowTop = host.window.frame.height - frame.maxY

        // The tiling puts the pane's top border at the content header plus one
        // gutter, and the pane header sits inside that.
        let paneTop = Pixels.contentHeaderHeight.value + metrics.px(.paneGap)
        let headerBottom = paneTop + metrics.px(.paneHeaderHeight)

        #expect(
            topFromWindowTop >= headerBottom,
            "the page starts at \(topFromWindowTop), the header ends at \(headerBottom)"
        )
    }

    @Test("the page does not need re-framing when nothing moves")
    func noReframingWhileIdle() throws {
        // gpui's plan was to re-frame the native view from a canvas element's
        // bounds *every paint*. If AppKit did the same, this counter would
        // climb on its own.
        let host = try hosted()
        host.window.contentView?.layoutSubtreeIfNeeded()

        let settled = PaneWebView.frameChanges
        for _ in 0..<5 { host.window.contentView?.layoutSubtreeIfNeeded() }

        #expect(
            PaneWebView.frameChanges == settled,
            "re-laying out an unchanged window resized the page \(PaneWebView.frameChanges - settled) times"
        )
    }

    @Test("resizing the window does re-frame it, without prose doing the arithmetic")
    func resizingReframesIt() throws {
        // The other half of the same claim: prose contains no frame arithmetic
        // for the page at all, so if AppKit did not do it the view would simply
        // never move.
        let host = try hosted()
        let before = host.webView.frame

        host.window.setContentSize(NSSize(width: 1400, height: 900))
        settle(host.window)

        #expect(host.webView.frame.width > before.width, "the page grew with its pane on its own")
    }

    @Test("taking first responder focuses the pane rather than fighting it")
    func firstResponderFocusesThePane() throws {
        // plan §2: "steals first responder on click → that is the correct
        // behaviour. The pane also gets the click via the responder chain."
        let host = try hosted()

        // Focus something else first, so the change is real.
        let other = host.workspace.activeTab!.panes.first { $0.id != host.pane }!.id
        host.workspace.focusPane(other)
        #expect(host.workspace.focusedPane == other)

        #expect(host.window.makeFirstResponder(host.webView))
        #expect(host.workspace.focusedPane == host.pane, "the pane focused because the page did")
    }

    @Test("clicking the page leaves the keyboard in the page")
    func theClickIsNotUndone() throws {
        // The regression this exists for: `PaneWebView.becomeFirstResponder`
        // tells the workspace to focus the pane, so anything the workspace then
        // does to first responder happens *inside* the click that caused it.
        // Handing the keyboard back out to the content area there made the page
        // impossible to type into — every click focused it and unfocused it
        // again in the same breath.
        let host = try hosted()

        // Focus the agent pane first, so the change is real — and let it settle,
        // because focusing it only *asks* for the composer and the composer
        // takes the keyboard on the next layout. Without this the request is
        // still pending and lands after the click below, which is the harness
        // stealing first responder rather than prose.
        let other = host.workspace.activeTab!.panes.first { $0.id != host.pane }!.id
        host.workspace.focusPane(other)
        settle(host.window)

        #expect(host.window.makeFirstResponder(host.webView))
        settle(host.window)

        #expect(host.workspace.focusedPane == host.pane, "the pane focused because the page did")
        #expect(
            holdsTheKeyboard(host.webView, in: host.window),
            "the page took first responder and the workspace took it straight back"
        )
    }

    @Test("stepping onto a page does hand the keyboard back to the content area")
    func steppingOntoAPageReleasesIt() throws {
        // The other side of the same coin, and why the two paths are not one
        // function: arriving by keyboard leaves first responder behind in the
        // pane being left, so a browser pane showing a page has to take it out
        // of there — spec §12 gives the plain arrows to the content area.
        let host = try hosted()
        host.workspace.focusPane(host.pane)
        #expect(host.window.makeFirstResponder(host.webView))

        let other = host.workspace.activeTab!.panes.first { $0.id != host.pane }!.id
        host.workspace.focusPane(other)
        host.workspace.stepPaneFocus(.right)
        settle(host.window)

        #expect(host.workspace.focusedPane == host.pane)
        #expect(
            !holdsTheKeyboard(host.webView, in: host.window),
            "the plain arrows have to reach the content area to keep moving panes"
        )
    }

    /// Whether the web view, or anything WebKit put inside it, is the window's
    /// first responder. The responder is an inner content view rather than the
    /// `WKWebView` itself, so identity alone is not the question.
    private func holdsTheKeyboard(_ webView: PaneWebView, in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView else { return false }
        return responder === webView || responder.isDescendant(of: webView)
    }

    @Test("a click in the middle of the page reaches the page")
    func thePageIsHitTestable() throws {
        // The other way a pane can be impossible to type into: `PaneView` puts
        // an `onTapGesture` over the whole pane so that clicking anywhere
        // focuses it, and a SwiftUI gesture over an `NSViewRepresentable` can
        // swallow the click the web view needs in order to become first
        // responder. An agent cannot click on this machine, but hit testing is
        // ordinary AppKit and answers the same question: if the view under the
        // point is not the page, no click can ever reach it.
        let host = try hosted()

        let middle = host.webView.convert(
            NSPoint(x: host.webView.bounds.midX, y: host.webView.bounds.midY), to: nil
        )
        let hit = try #require(host.window.contentView?.hitTest(middle))

        var chain: [String] = []
        var walk: NSView? = hit
        while let current = walk, chain.count < 6 {
            chain.append("\(type(of: current))")
            walk = current.superview
        }
        #expect(
            hit === host.webView || hit.isDescendant(of: host.webView),
            "under the middle of the page: \(chain.joined(separator: " < "))"
        )
    }

    @Test("each pane gets its own ephemeral session")
    func ephemeralSessionsArePerPane() throws {
        let workspace = Workspace()
        let first = workspace.activeTab!.panes[0].id
        workspace.splitPane(first, .row)
        let second = workspace.activeTab!.focused!

        workspace.setPaneKind(first, .browser)
        workspace.setPaneKind(second, .browser)

        let a = try #require(workspace.browser(first))
        let b = try #require(workspace.browser(second))

        #expect(!a.webView.configuration.websiteDataStore.isPersistent)
        #expect(!b.webView.configuration.websiteDataStore.isPersistent)
        #expect(
            a.webView.configuration.websiteDataStore !== b.webView.configuration.websiteDataStore,
            "two panes logged into the same site are two different users"
        )
    }

    @Test("closing a browser pane takes its session with it")
    func closingDropsTheSession() {
        let workspace = Workspace()
        let first = workspace.activeTab!.panes[0].id
        workspace.splitPane(first, .row)
        let second = workspace.activeTab!.focused!
        workspace.setPaneKind(second, .browser)
        #expect(workspace.browser(second) != nil)

        workspace.closePane(second)
        #expect(workspace.browser(second) == nil)
    }

    @Test("turning a browser pane back into an agent pane ends its session")
    func revertingDropsTheSession() {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        #expect(workspace.browser(pane) != nil)

        workspace.setPaneKind(pane, .agent)
        #expect(workspace.browser(pane) == nil)
    }

    // MARK: - The URL field

    /// What `resolve` produced, as a string, so a table of cases reads as one.
    private func resolved(_ text: String) -> String? {
        try? BrowserSession.resolve(text).get().absoluteString
    }

    @Test("a bare host gets a scheme, and nonsense is left alone")
    func addressResolution() throws {
        #expect(resolved("example.com") == "https://example.com")
        #expect(resolved("https://example.com/x") == "https://example.com/x")
        #expect(resolved("  example.com  ") == "https://example.com")
        #expect(try #require(BrowserSession.resolve("file:///tmp/a.html").get()).isFileURL)

        // Not handed to a search engine: prose has no opinion about search and
        // inventing one is not this step's job. It does have to *say* so, which
        // is the difference between `.empty` and `.notAURL`.
        #expect(BrowserSession.resolve("") == .failure(.empty))
        #expect(BrowserSession.resolve("   ") == .failure(.empty))
        #expect(BrowserSession.resolve("what is swift") == .failure(.notAURL("what is swift")))
    }

    @Test("a dev server is reachable, which is the whole point of the pane")
    func devServersResolve() {
        // The bug this is written against: a URL scheme is a letter followed by
        // letters, digits, `+`, `-` or `.`, so `localhost:3000` parses as the
        // *scheme* `localhost`. Trusting `URL(string:)` about what a scheme is
        // therefore meant no dev server on any port ever loaded.
        #expect(resolved("localhost:3000") == "http://localhost:3000")
        #expect(resolved("localhost:3000/api/x") == "http://localhost:3000/api/x")
        #expect(resolved("127.0.0.1:8080") == "http://127.0.0.1:8080")
        #expect(resolved("localhost") == "http://localhost")

        // A name with no dot but a port is a machine on this network, and
        // `https://dev:8080` has nowhere to get a certificate from.
        #expect(resolved("dev:8080") == "http://dev:8080")
        #expect(resolved("mini.local") == "http://mini.local")

        // Everything else is still HTTPS. A site typed without a scheme should
        // not be quietly downgraded.
        #expect(resolved("example.com:8443") == "https://example.com:8443")
        #expect(resolved("http://example.com") == "http://example.com")
    }

    @Test("an address bar does not run scripts")
    func onlyLoadableSchemes() {
        // These parse as perfectly good URLs with schemes, which is exactly why
        // they need excluding by name rather than by parsing.
        #expect(resolved("javascript:alert(1)") == nil)
        #expect(resolved("data:text/html,<b>x</b>") == nil)
    }

    // MARK: - Saying what went wrong

    @Test("an address that is not a URL says so instead of doing nothing")
    func aBadAddressIsReported() throws {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        let session = try #require(workspace.browser(pane))

        session.address = "what is swift"
        session.go()

        #expect(session.failure != nil, "a swallowed address is indistinguishable from a hang")
        #expect(!session.hasPage, "nothing was loaded, so the placeholder stands")

        // An empty field is not a mistake worth reporting back.
        session.failure = nil
        session.address = "   "
        session.go()
        #expect(session.failure == nil)
    }

    @Test("a good address clears the last failure and shows the page")
    func aGoodAddressClearsIt() throws {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        let session = try #require(workspace.browser(pane))

        session.failure = "something from before"
        session.address = "example.com"
        session.go()

        #expect(session.failure == nil)
        #expect(session.hasPage, "the body swaps from spec §8's label to the page")
    }

    @Test("an empty web view is covered until a page actually arrives")
    func theWhiteRectangleIsCovered() throws {
        // WebKit draws its own empty *white* page between being asked for a URL
        // and receiving one, and `underPageBackgroundColor` does not govern that
        // — it governs the rubber-band past a page's edges. So the two states
        // are tracked apart, and a load that never commits never uncovers the
        // view.
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        let session = try #require(workspace.browser(pane))

        session.address = "example.com"
        session.go()
        #expect(session.hasPage, "a page has been asked for")
        #expect(!session.hasPainted, "but nothing has arrived, so prose's plane covers it")
    }

    // MARK: - The keyboard

    @Test("focusing a pane with no page puts the caret in its URL field")
    func anEmptyBrowserPaneAsksForTheField() throws {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        let session = try #require(workspace.browser(pane))

        session.wantsAddressFocus = false
        workspace.focusPane(pane)
        #expect(session.wantsAddressFocus, "there is nowhere else in the pane for it to go")
        #expect(workspace.keyboardOwner == .content)
    }

    @Test("focusing a pane that has a page leaves the caret out of the URL field")
    func aLoadedBrowserPaneDoesNot() throws {
        // spec §12 gives the plain arrows to the content area for browser panes.
        // Yanking the caret into the URL bar on every click would take them back
        // — and would fight the click that focused the page in the first place.
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        let session = try #require(workspace.browser(pane))
        session.hasPage = true

        session.wantsAddressFocus = false
        workspace.focusPane(pane)
        #expect(!session.wantsAddressFocus)
    }

    @Test("stepping focus hands over the keyboard, not just the border")
    func steppingFocusMovesTheKeyboard() throws {
        // This moved the focus ring and nothing else, so Cmd+Alt+arrow
        // recoloured a border while the keyboard stayed behind in the pane the
        // user had just left.
        let workspace = Workspace()
        let first = workspace.activeTab!.panes[0].id
        workspace.splitPane(first, .row)
        let second = workspace.activeTab!.focused!
        workspace.setPaneKind(second, .browser)
        let session = try #require(workspace.browser(second))

        workspace.focusPane(first)
        session.wantsAddressFocus = false
        workspace.keyboardOwner = .tabStrip

        workspace.stepPaneFocus(.right)
        #expect(workspace.focusedPane == second)
        #expect(workspace.keyboardOwner == .content)
        #expect(session.wantsAddressFocus)
    }

    @Test("Escape in the URL field gives the arrow keys back to the tab strip")
    func escapeReturnsToTheTabStrip() throws {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        let session = try #require(workspace.browser(pane))

        workspace.focusPane(pane)
        #expect(workspace.keyboardOwner == .content)

        session.onResignToTabStrip?()
        #expect(workspace.keyboardOwner == .tabStrip, "a browser pane is not a one-way trip")
    }

    // MARK: - The header's buttons

    @Test("reload is offered only once there is something to reload")
    func reloadFollowsThePage() throws {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        let session = try #require(workspace.browser(pane))

        // `hasPage` is what the header's enabled flag reads, and the history
        // buttons stay dim until a page gives them somewhere to go.
        #expect(!session.hasPage)
        #expect(!session.canGoBack)
        #expect(!session.canGoForward)

        session.address = "example.com"
        session.go()
        #expect(session.hasPage)
    }

    @Test("the URL field is not overwritten while it is being typed in")
    func typingIsNotStomped() throws {
        // The `\.url` observation writes the loaded address back into the
        // field. A redirect landing mid-word used to replace what had been
        // typed so far, which is the field fighting the person using it.
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        let session = try #require(workspace.browser(pane))

        session.addressFocused = true
        session.address = "half-typed"
        session.webView.loadHTMLString("<html></html>", baseURL: URL(string: "https://elsewhere.test"))
        #expect(session.address == "half-typed")
    }

    // Two things are deliberately *not* tested here: that a real page load ends,
    // and that `estimatedProgress` reaches 1. Both were written and both fail
    // under `swift test` — a load started in the test runner stalls at
    // provisional (progress 0.1) and never commits, while the same load in a
    // standalone program with a running `NSApplication` finishes in under a
    // second. The runner will not carry WebKit's IPC, so those two assertions
    // would be testing the harness rather than prose. They are checked instead
    // by `PROSE_PROBE=1` against the running app, which prints the title and
    // the frame counter off the live view tree.
    //
    // What that experiment *did* establish is in `BrowserSession`: `didFinish`
    // fires before `webView.title` is populated, so plan §2's "navigation
    // delegate drives the title" needs a `\.title` observation beside it.

    @Test("the page names the pane")
    func theTitleReachesTheHeader() throws {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        let session = try #require(workspace.browser(pane))

        // Until something says otherwise, spec §8's fallback stands.
        #expect(workspace.activeTab!.pane(pane)!.displayTitle == "Browser")

        session.onTitle?("Corner Test Page")
        #expect(workspace.activeTab!.pane(pane)!.displayTitle == "Corner Test Page")

        // And a page that names itself nothing falls back rather than showing
        // an empty header.
        session.onTitle?(nil)
        #expect(workspace.activeTab!.pane(pane)!.displayTitle == "Browser")
    }

    // MARK: - Driving the page

    /// Waits the way a page load has to be waited for.
    ///
    /// **Not `pump`.** `CFRunLoopRunInMode` drives layout, which is all the
    /// geometry tests above need — but a page never gets past ten percent
    /// under it. Measured, not guessed: `progress` sits at 0.1, `didCommit`
    /// never fires and `evaluateJavaScript` never answers, for as long as you
    /// care to spin. WebKit's replies come back through Swift concurrency, and
    /// awaiting is what lets them land. Everything below is therefore `async`.
    private func settle(upTo seconds: Double, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Loads a page into the hosted pane and waits for the load to register.
    private func load(_ hosted: Hosted, _ html: String) async throws -> BrowserSession {
        let session = try #require(hosted.workspace.browser(hosted.pane))
        // `hosted()` starts a load of its own. Let it land before counting, or
        // the wait below is satisfied by *that* navigation and every assertion
        // afterwards runs against the previous page — which is precisely the
        // confusion this whole change exists to remove, reproduced in the test
        // for it.
        await settle(upTo: 10) { session.loads > 0 && !session.webView.isLoading }

        let before = session.loads
        session.webView.loadHTMLString(html, baseURL: URL(string: "https://example.test/"))
        await settle(upTo: 10) { session.loads > before }
        return session
    }

    /// Runs one of the session's driving calls and returns what it answered.
    private func answer(
        _ run: (@escaping (JSONValue) -> Void) -> Void
    ) async -> JSONValue? {
        var result: JSONValue?
        run { result = $0 }
        await settle(upTo: 10) { result != nil }
        return result
    }

    @Test("a finished navigation moves the pane's clock")
    func loadsCount() async throws {
        let hosted = try hosted()
        let session = try await load(hosted, "<html><body><p>one</p></body></html>")
        let after = session.loads
        #expect(after > 0, "a page that loaded should have been counted")

        _ = try await load(hosted, "<html><body><p>two</p></body></html>")
        #expect(session.loads > after, "and a second navigation counts again")
    }

    @Test("a wait placed after the page loaded is answered at once")
    func waitingIsLevelTriggered() async throws {
        // The rule that keeps a fast child from hanging its parent, applied to
        // a fast page: the load happened before anyone asked to wait for it,
        // and an edge-triggered wait would park forever.
        let hosted = try hosted()
        let session = try await load(hosted, "<html><body><p>here already</p></body></html>")

        let query = ReadQuery(since: 0, until: [.loaded], timeout: 30_000)
        #expect(hosted.workspace.satisfied(query, session) == .loaded)

        // And threading the cursor means the same wait does not fire twice.
        let threaded = ReadQuery(since: session.loads, until: [.loaded], timeout: 30_000)
        #expect(hosted.workspace.satisfied(threaded, session) == nil)
    }

    @Test("a failed load still ends the wait")
    func failuresCountToo() async throws {
        // "The page finished trying" is the event being waited on. A counter
        // that only moved on success would hang on every 404 and every dead
        // host, which is the case a wait is most needed for.
        let hosted = try hosted()
        let session = try await load(hosted, "<html><body>first</body></html>")
        let before = session.loads

        session.webView.load(URLRequest(url: URL(string: "https://invalid.invalid.test/")!))
        await settle(upTo: 30) { session.loads > before }
        #expect(session.loads > before, "a load that failed is still a load that ended")
    }

    @Test("the page lists what can be acted on, by the name a person would read")
    func elementsAreListed() async throws {
        let hosted = try hosted()
        let session = try await load(hosted, """
            <html><body>
              <a href="/guide">Docs</a>
              <button aria-label="Search the docs">X</button>
              <input type="text" placeholder="Search docs">
              <button disabled>Sign in</button>
              <div>not interactive</div>
              <span style="display:none"><button>hidden</button></span>
            </body></html>
            """)

        let result = await answer { session.elements(limit: 50, then: $0) }
        guard case .object(let fields)? = result,
              case .array(let elements)? = fields["elements"]
        else { Issue.record("no element list: \(String(describing: result))"); return }

        let names = elements.compactMap { element -> String? in
            guard case .object(let e) = element else { return nil }
            return e["name"]?.string
        }
        #expect(names.contains("Docs"))
        #expect(names.contains("Search the docs"), "aria-label beats the text inside it")
        #expect(names.contains("Search docs"), "a placeholder names a field with no label")
        #expect(!names.contains("hidden"), "nothing invisible is offered")
        #expect(elements.count == 4, "the plain div is not actionable: \(names)")
    }

    @Test("typing reaches an application that tracks its own state")
    func typingGoesThroughTheNativeSetter() async throws {
        // Assigning `el.value` is invisible to a framework that has patched
        // the property — the field shows the text and the application never
        // learns of it. This page records what it was *told*, not what it
        // displays, which is the same distinction.
        let hosted = try hosted()
        let session = try await load(hosted, """
            <html><body>
              <input id="field" type="text">
              <script>
                window.heard = "";
                document.getElementById('field')
                        .addEventListener('input', (e) => { window.heard = e.target.value; });
              </script>
            </body></html>
            """)

        _ = await answer { session.elements(limit: 10, then: $0) }
        let typed = await answer {
            session.type(ref: "e1", text: "archetypes", enter: false, then: $0)
        }
        guard case .object(let fields)? = typed else {
            Issue.record("no answer: \(String(describing: typed))"); return
        }
        #expect(fields["error"] == nil, "typing failed: \(fields)")

        let heard = await answer { session.evaluate("window.heard", then: $0) }
        #expect(
            heard?.string == "archetypes",
            "the page never heard it: \(String(describing: heard))")
    }

    @Test("clicking reaches a component that listens for the pointer, not the click")
    func clickingDispatchesThePointerSequence() async throws {
        let hosted = try hosted()
        let session = try await load(hosted, """
            <html><body>
              <button id="b">Go</button>
              <script>
                window.saw = [];
                const b = document.getElementById('b');
                for (const kind of ['pointerdown', 'mousedown', 'click']) {
                  b.addEventListener(kind, () => window.saw.push(kind));
                }
              </script>
            </body></html>
            """)

        _ = await answer { session.elements(limit: 10, then: $0) }
        _ = await answer { session.click(ref: "e1", then: $0) }

        let saw = await answer { session.evaluate("window.saw.join(',')", then: $0) }
        let sequence = saw?.string ?? ""
        #expect(sequence.contains("pointerdown"), "a bare .click() would miss this: \(sequence)")
        #expect(sequence.contains("click"))
    }

    @Test("a ref from before a navigation is refused rather than acted on")
    func staleRefsAreRefused() async throws {
        let hosted = try hosted()
        let session = try await load(hosted, "<html><body><button>First</button></body></html>")
        _ = await answer { session.elements(limit: 10, then: $0) }

        // A different page, where e1 is a different button entirely.
        _ = try await load(hosted, "<html><body><button>Second</button></body></html>")

        let clicked = await answer { session.click(ref: "e1", then: $0) }
        guard case .object(let fields)? = clicked else {
            Issue.record("no answer: \(String(describing: clicked))"); return
        }
        // The list lives in the page's own JS context, which the navigation
        // destroyed — so this cannot click the wrong button, only report.
        #expect(fields["clicked"] == nil, "it acted on a stale ref: \(fields)")
        #expect(fields["error"] != nil, "and it should say why: \(fields)")
    }

    @Test("a selector that matches nothing says so, rather than reading as empty")
    func aMissedSelectorIsNotAnEmptyPage() async throws {
        let hosted = try hosted()
        let session = try await load(hosted, "<html><body><main>the text</main></body></html>")

        let found = await answer { session.text(selector: "main", limit: 100, then: $0) }
        #expect(found?.object?["matched"]?.bool == true)
        #expect(found?.object?["text"]?.string?.contains("the text") == true)

        let missed = await answer { session.text(selector: ".nope", limit: 100, then: $0) }
        #expect(missed?.object?["matched"]?.bool == false, "the three empty cases are different")
        #expect(missed?.object?["text"]?.string == "")
    }

    @Test("a script that throws is an error, not a null")
    func aThrowIsReported() async throws {
        let hosted = try hosted()
        let session = try await load(hosted, "<html><body></body></html>")

        let thrown = await answer { session.evaluate("throw new Error('nope')", then: $0) }
        #expect(thrown?.object?["error"] != nil, "a broken script must be distinguishable")

        let genuinelyNull = await answer { session.evaluate("null", then: $0) }
        #expect(genuinelyNull == JSONValue.null)
    }

    // MARK: - The gaps that sent an agent back to a script
    //
    // Each of these is a thing a page genuinely requires that a ref could not
    // do, and every one of them was found the same way: by watching a pilot
    // reach for `browser_eval` to do it. They are tests rather than a note in
    // the prompt because a capability the refs lack cannot be prompted away.

    @Test("a link past the list's limit is still reachable, and still clickable")
    func findReachesPastTheLimit() async throws {
        let hosted = try hosted()
        // The shape of an encyclopedia article: a great deal of chrome, and
        // the one link that was wanted a long way down it.
        let filler = (1...300).map { "<a href='/n\($0)'>Item \($0)</a>" }.joined()
        let session = try await load(
            hosted, "<html><body>\(filler)<a href='/wiki/Philosophy'>Philosophy</a></body></html>")

        let listed = await answer { session.elements(limit: 20, then: $0) }
        #expect(listed?.object?["truncated"]?.bool == true, "the page is longer than the list")
        #expect((listed?.object?["total"]?.number ?? 0) > 300, "and it says how much longer")

        let found = await answer { session.find(text: "philosophy", limit: 10, then: $0) }
        let matches = try #require(found?.object?["elements"]?.array)
        #expect(matches.count == 1, "one link matches, out of 301: \(matches)")

        // The point of the whole exercise: the ref it hands back works, even
        // though the element was never shown in a list.
        let ref = try #require(matches.first?.object?["ref"]?.string)
        let clicked = await answer { session.click(ref: ref, then: $0) }
        #expect(clicked?.object?["clicked"]?.string == "Philosophy")
        #expect(
            clicked?.object?["navigating"]?.string?.contains("/wiki/Philosophy") == true,
            "a followed link must be distinguishable from a button that did nothing")
    }

    @Test("find matches a link by its target as well as its words")
    func findMatchesHrefs() async throws {
        let hosted = try hosted()
        let session = try await load(
            hosted, "<html><body><a href='/wiki/Philosophy'>the love of wisdom</a></body></html>")

        let found = await answer { session.find(text: "wiki/phil", limit: 10, then: $0) }
        #expect(found?.object?["matched"]?.number == 1, "the words on the page are not the only handle")
    }

    @Test("a dropdown can be set, which no click can do")
    func selectingAnOption() async throws {
        let hosted = try hosted()
        let session = try await load(
            hosted,
            """
            <html><body>
              <select id="s">
                <option value="a">Alpha</option>
                <option value="b">Beta</option>
              </select>
              <script>
                window.changes = 0;
                document.getElementById('s').addEventListener('change', () => window.changes++);
              </script>
            </body></html>
            """)

        _ = await answer { session.elements(limit: 10, then: $0) }
        let chosen = await answer { session.select(ref: "e1", option: "Beta", then: $0) }
        #expect(chosen?.object?["selected"]?.string == "Beta")

        let value = await answer { session.evaluate("document.getElementById('s').value", then: $0) }
        #expect(value?.string == "b")
        // Through the native setter, so an application listening for `change`
        // learns of it — the same trap `type` has.
        let changes = await answer { session.evaluate("window.changes", then: $0) }
        #expect(changes?.number == 1, "a select nobody was told about is the confusing failure")
    }

    @Test("a dropdown that does not match says what it does offer")
    func selectingNothingListsTheOptions() async throws {
        let hosted = try hosted()
        let session = try await load(
            hosted,
            "<html><body><select><option>Alpha</option><option>Beta</option></select></body></html>")

        _ = await answer { session.elements(limit: 10, then: $0) }
        let missed = await answer { session.select(ref: "e1", option: "Gamma", then: $0) }
        let error = try #require(missed?.object?["error"]?.string)
        #expect(error.contains("Alpha") && error.contains("Beta"), "a miss must be recoverable")
    }

    @Test("escape reaches the page, at the focus, with no ref at all")
    func pressingAKey() async throws {
        let hosted = try hosted()
        let session = try await load(
            hosted,
            """
            <html><body><input id="f">
              <script>
                window.keys = [];
                document.addEventListener('keydown', (e) => window.keys.push(e.key));
              </script>
            </body></html>
            """)

        _ = await answer { session.elements(limit: 10, then: $0) }
        _ = await answer { session.key(ref: "e1", key: "escape", then: $0) }
        // No ref: wherever the focus now is, which is what dismissing a dialog
        // means and what only a real keypress used to be able to do.
        _ = await answer { session.key(ref: nil, key: "arrowdown", then: $0) }

        let keys = await answer { session.evaluate("window.keys.join(',')", then: $0) }
        #expect(keys?.string == "Escape,ArrowDown", "got \(keys?.string ?? "nothing")")
    }

    @Test("an unknown key is refused with the ones that exist")
    func anUnknownKeyIsRefused() async throws {
        let hosted = try hosted()
        let session = try await load(hosted, "<html><body><input></body></html>")

        _ = await answer { session.elements(limit: 10, then: $0) }
        let refused = await answer { session.key(ref: "e1", key: "meta+q", then: $0) }
        #expect(refused?.object?["error"]?.string?.contains("escape") == true)
    }

    @Test("scrolling by an amount moves the box the element is in, not the window")
    func scrollingAnInnerBox() async throws {
        let hosted = try hosted()
        // An application shell: the document is exactly the viewport, and the
        // thing that scrolls is a div inside it. Scrolling the window here
        // does nothing whatsoever, silently.
        let rows = (1...200).map { "<p>row \($0)</p>" }.joined()
        let session = try await load(
            hosted,
            """
            <html><body style="margin:0;height:100vh;overflow:hidden">
              <div id="list" style="height:200px;overflow-y:auto">\(rows)</div>
            </body></html>
            """)

        _ = await answer { session.elements(limit: 10, then: $0) }
        let moved = await answer { session.scroll(ref: nil, to: nil, by: 400, then: $0) }
        #expect(moved?.object?["moved"]?.number == 400, "the inner list is the page's real scroller")
        #expect(moved?.object?["at_end"]?.bool == false)

        let toEnd = await answer { session.scroll(ref: nil, to: "bottom", by: nil, then: $0) }
        #expect(toEnd?.object?["at_end"]?.bool == true)

        // The end of a list has to be legible, or an agent pages forever.
        let again = await answer { session.scroll(ref: nil, to: nil, by: 400, then: $0) }
        #expect(again?.object?["moved"]?.number == 0)
        #expect(again?.object?["at_end"]?.bool == true)
    }

    @Test("a button inside a shadow root is listed and clickable")
    func shadowRootsAreReached() async throws {
        let hosted = try hosted()
        let session = try await load(
            hosted,
            """
            <html><body>
              <div id="host"></div>
              <script>
                window.hit = false;
                const root = document.getElementById('host').attachShadow({ mode: 'open' });
                root.innerHTML = '<button>Inside</button>';
                root.querySelector('button').addEventListener('click', () => window.hit = true);
              </script>
            </body></html>
            """)

        let found = await answer { session.find(text: "Inside", limit: 5, then: $0) }
        let matches = try #require(found?.object?["elements"]?.array)
        // `querySelectorAll` stops at the boundary, so this used to be a page
        // with nothing on it — which reads to an agent as a page worth
        // scripting.
        #expect(matches.count == 1, "the shadow boundary hid this: \(matches)")

        let ref = try #require(matches.first?.object?["ref"]?.string)
        _ = await answer { session.click(ref: ref, then: $0) }
        let hit = await answer { session.evaluate("window.hit", then: $0) }
        #expect(hit?.bool == true)
    }

    @Test("waiting for a change that is not a navigation returns when it happens")
    func waitingWithoutALoad() async throws {
        let hosted = try hosted()
        // Nothing here loads a page, so the pane's load counter never moves
        // and `prose_wait` has nothing to count. This is the case that used to
        // leave polling as the only option.
        let session = try await load(
            hosted,
            """
            <html><body><div id="out"></div>
              <script>
                setTimeout(() => {
                  document.getElementById('out').textContent = 'Results are ready';
                }, 400);
              </script>
            </body></html>
            """)

        let listed = await answer {
            session.elements(limit: 20, waitFor: "Results are ready", timeoutMs: 5000, then: $0)
        }
        let waited = try #require(listed?.object?["waited"]?.object)
        #expect(waited["reason"]?.string == "found", "waited: \(waited)")
        // And it listed the page afterwards, which is why the wait lives on
        // this call rather than on one of its own.
        #expect(listed?.object?["elements"] != nil)
    }

    @Test("a wait for something already true returns at once")
    func waitingForTextIsLevelTriggered() async throws {
        let hosted = try hosted()
        let session = try await load(hosted, "<html><body><p>Already here</p></body></html>")

        let listed = await answer {
            session.elements(limit: 20, waitFor: "Already here", timeoutMs: 5000, then: $0)
        }
        let waited = try #require(listed?.object?["waited"]?.object)
        // The rule the whole read path is built on: a condition that happened
        // before the wait was placed must not wait for it to happen again.
        #expect(waited["reason"]?.string == "found")
        #expect((waited["elapsed_ms"]?.number ?? 9_999) < 250, "it waited anyway: \(waited)")
    }

    @Test("a wait for something that never comes times out rather than hanging")
    func waitingGivesUp() async throws {
        let hosted = try hosted()
        let session = try await load(hosted, "<html><body><p>quiet</p></body></html>")

        let listed = await answer {
            session.elements(limit: 20, waitFor: "never appears", timeoutMs: 600, then: $0)
        }
        #expect(listed?.object?["waited"]?.object?["reason"]?.string == "timeout")
        // A timed-out wait still lists the page: a partly-rendered page often
        // has the answer, and the archetype tells the pilot to look anyway.
        #expect(listed?.object?["elements"] != nil)
    }

    @Test("back reports that there was nowhere to go")
    func historyWithNoHistory() async throws {
        let hosted = try hosted()
        let session = try await load(hosted, "<html><body><p>one</p></body></html>")

        let forward = await answer { session.step(back: false, then: $0) }
        #expect(forward?.object?["ok"]?.bool == false)
        #expect(forward?.object?["error"] != nil, "an agent has to know it did not move")
    }

    // MARK: - What the page says about itself

    @Test("the page's console reaches the pane, at the level it was logged")
    func consoleIsCaptured() async throws {
        let hosted = try hosted()
        let session = try await load(
            hosted,
            """
            <html><body><script>
              console.log('chatter');
              console.warn('deprecated thing');
              console.error('the real problem');
            </script></body></html>
            """)
        await settle(upTo: 10) { session.log.console.count >= 3 }

        // The default a pilot gets: the trouble, without the chatter.
        let bad = session.console(since: 0, level: .warn, limit: 50)
        let texts = (bad["entries"]?.array ?? []).compactMap { $0["text"]?.string }
        #expect(texts == ["deprecated thing", "the real problem"])

        let all = session.console(since: 0, level: .log, limit: 50)
        #expect((all["entries"]?.array ?? []).count == 3, "and `all` really does include it")
    }

    @Test("an uncaught error is captured with where it was thrown")
    func uncaughtErrorsAreCaptured() async throws {
        // The case the whole surface exists for: a page that throws on load
        // looks, from outside, exactly like one whose controls are elsewhere.
        let hosted = try hosted()
        let session = try await load(
            hosted,
            "<html><body><script>null.someProperty;</script></body></html>")
        await settle(upTo: 10) { !session.log.console.isEmpty }

        let entries = session.console(since: 0, level: .error, limit: 50)["entries"]?.array ?? []
        #expect(!entries.isEmpty, "an uncaught TypeError should have been recorded")
        #expect(entries[0]["at"]?.string != nil, "with a source location, which console.log lacks")
    }

    @Test("an unhandled rejection is an error rather than silence")
    func rejectionsAreCaptured() async throws {
        let hosted = try hosted()
        let session = try await load(
            hosted,
            "<html><body><script>Promise.reject(new Error('nope'));</script></body></html>")
        await settle(upTo: 10) { !session.log.console.isEmpty }

        let texts = (session.console(since: 0, level: .error, limit: 50)["entries"]?.array ?? [])
            .compactMap { $0["text"]?.string }
        #expect(texts.contains { $0.contains("unhandled rejection") && $0.contains("nope") })
    }

    @Test("a subresource that fails to load is a network entry, not a console line")
    func failedSubresourcesAreRecorded() async throws {
        // `error` on an <img> does not bubble, so this only works from a
        // capture-phase listener — the one detail that makes it work at all.
        let hosted = try hosted()
        let session = try await load(
            hosted,
            "<html><body><img src='https://example.test/missing.png'></body></html>")
        await settle(upTo: 10) { !session.log.network.isEmpty }

        let failed = session.network(since: 0, failuresOnly: true, limit: 50)
        let entries = failed["entries"]?.array ?? []
        #expect(entries.contains { $0["url"]?.string?.hasSuffix("missing.png") == true })
        #expect(entries.contains { $0["error"]?.string?.contains("img") == true })
    }

    @Test("a fetch the page makes is recorded with its status")
    func fetchIsRecorded() async throws {
        let server = try TinyServer()
        defer { server.stop() }

        let hosted = try hosted()
        let session = try #require(hosted.workspace.browser(hosted.pane))
        await settle(upTo: 10) { session.loads > 0 && !session.webView.isLoading }

        let before = session.loads
        session.navigate(to: server.url("/page"))
        await settle(upTo: 15) { session.loads > before }
        // Two fetches the page starts on load, one of which 404s.
        await settle(upTo: 15) { session.log.network.count >= 3 }

        let all = session.network(since: 0, failuresOnly: false, limit: 50)
        let entries = all["entries"]?.array ?? []

        // The main document's own status, which the page cannot see about
        // itself — a 404 or a 500 renders like anything else.
        #expect(entries.contains { $0["kind"]?.string == "document" && $0["status"]?.int == 200 })
        #expect(
            entries.contains { $0["url"]?.string?.hasSuffix("/ok") == true
                && $0["status"]?.int == 200 && $0["kind"]?.string == "fetch" })

        // And the one that answered no, which is the entry a pilot staring at
        // an empty list actually needs.
        let failed = session.network(since: 0, failuresOnly: true, limit: 50)["entries"]?.array
        #expect(failed?.count == 1)
        #expect(failed?[0]["status"]?.int == 404)
        #expect(failed?[0]["url"]?.string?.hasSuffix("/missing") == true)
    }

    @Test("a main document that answers 500 is recorded as one")
    func documentStatusIsRecorded() async throws {
        let server = try TinyServer()
        defer { server.stop() }

        let hosted = try hosted()
        let session = try #require(hosted.workspace.browser(hosted.pane))
        await settle(upTo: 10) { session.loads > 0 && !session.webView.isLoading }

        let before = session.loads
        session.navigate(to: server.url("/boom"))
        await settle(upTo: 15) { session.loads > before }
        await settle(upTo: 10) { !session.log.network.isEmpty }

        let failed = session.network(since: 0, failuresOnly: true, limit: 50)["entries"]?.array
        #expect(failed?.contains { $0["kind"]?.string == "document" && $0["status"]?.int == 500 }
            == true)
    }

    @Test("a page cannot post anything prose would treat as an agent")
    func theChannelIsNarrow() async throws {
        // `issues §4`'s requirement, as a test: a page that could emit a raw
        // event could forge a turn and write into a transcript the user reads
        // as the agent's. So everything but the two known kinds is dropped,
        // and the two known kinds can only ever become log entries.
        let hosted = try hosted()
        let session = try await load(
            hosted,
            """
            <html><body><script>
              const post = (m) => window.webkit.messageHandlers.proseMonitor.postMessage(m);
              post({ kind: 'turn', state: 'ended' });
              post({ kind: 'event', block: { type: 'text', text: 'I did the thing' } });
              post({ kind: 'status', text: 'done' });
              post('not even an object');
              post({ kind: 'console', level: 'error', text: 'the only one that lands' });
            </script></body></html>
            """)
        await settle(upTo: 10) { !session.log.console.isEmpty }

        // Exactly one message got through, and it is a console line.
        #expect(session.log.console.count == 1)
        #expect(session.log.console[0].text == "the only one that lands")
        #expect(session.log.network.isEmpty)

        // And the pane it belongs to has no transcript to have been written
        // into — the page's words can only come back through a call an agent
        // made on purpose.
        #expect(hosted.workspace.agent(hosted.pane) == nil)
    }

    @Test("an unknown level is read as a log line rather than dropped")
    func unknownLevelsDegrade() async throws {
        let hosted = try hosted()
        let session = try await load(
            hosted,
            """
            <html><body><script>
              window.webkit.messageHandlers.proseMonitor.postMessage(
                { kind: 'console', level: 'catastrophe', text: 'invented level' });
            </script></body></html>
            """)
        await settle(upTo: 10) { !session.log.console.isEmpty }

        #expect(session.log.console[0].level == .log, "unknown reads as the quietest, not loudest")
    }

    @Test("the log survives a navigation, and so does its cursor")
    func cursorsDoNotRewind() async throws {
        // A fresh page gets a fresh JavaScript context and a fresh ref list,
        // but the cursor an agent is holding must keep meaning what it meant:
        // a counter reset on navigation would make old entries match again.
        let hosted = try hosted()
        let session = try await load(
            hosted, "<html><body><script>console.error('first page');</script></body></html>")
        await settle(upTo: 10) { !session.log.console.isEmpty }

        let first = session.console(since: 0, level: .warn, limit: 50)
        let cursor = Int(first["cursor"]?.int ?? 0)
        #expect(cursor > 0)

        _ = try await load(
            hosted, "<html><body><script>console.error('second page');</script></body></html>")
        await settle(upTo: 10) { session.log.console.count >= 2 }

        let next = session.console(since: cursor, level: .warn, limit: 50)
        let texts = (next["entries"]?.array ?? []).compactMap { $0["text"]?.string }
        #expect(texts == ["second page"], "the cursor still means what it meant")
    }
}

/// What a page's dialogs may do to the panes around them.
///
/// A page runs whether or not anyone is looking at it, and a pane in a tab that
/// is not on screen has no window. The answer to a dialog from one used to be
/// `runModal()` — an application-modal alert raised on behalf of something
/// invisible, over the pane the user was typing in.
@MainActor
@Suite("Page dialogs")
struct PageDialogTests {
    @Test("a dialog goes on the pane's own window when the pane is on screen")
    func aVisiblePaneGetsASheet() throws {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.setPaneKind(pane, .browser)
        let session = try #require(workspace.browser(pane))
        session.hasPage = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        window.contentView = NSHostingView(rootView: WorkspaceView().environment(workspace))
        window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
        window.orderBack(nil)
        for _ in 0..<4 {
            _ = NSApplication.shared
            CFRunLoopRunInMode(.defaultMode, 0.05, false)
            window.layoutIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
        }

        guard case .sheet(let host) = PageDialog.venue(over: session.webView, asking: "anything")
        else {
            Issue.record("a pane on screen has a window to put a sheet on")
            return
        }
        #expect(host === window)
    }

    @Test("a dialog from a pane nobody is looking at is answered rather than shown")
    func ahiddenPaneIsDeclined() throws {
        // Its tab is not the active one, so its views are gone and its web view
        // is in no window — while the page carries on running.
        let session = BrowserSession(pane: 0)
        session.hasPage = true

        guard case .declined(let why) = PageDialog.venue(
            over: session.webView, asking: "to show a message"
        ) else {
            Issue.record("nothing to show it on, so it must not be shown")
            return
        }
        #expect(why.contains("hidden"), "and the pane says so: \(why)")
    }

    // Deliberately no end-to-end test of a hidden page actually raising one.
    // A page whose view has left the window is suspended hard enough by WebKit
    // that it could not be provoked into calling `alert()` under `swift test`,
    // so what is pinned above is the decision itself: there is no longer any
    // path from a dialog to `runModal()`, whatever WebKit decides to run.
}

/// Four canned responses on a loopback port.
///
/// Two things in the network surface cannot be tested without a real server:
/// the **main document's status code**, which arrives through
/// `WKNavigationDelegate` rather than through the page, and a **fetch that
/// answers 404**, which is a different entry from one that never connected.
/// Pointing the pane at a name that does not resolve exercises neither — it
/// produces a DNS failure, which is the case that already worked.
///
/// Deliberately the smallest thing that serves those four responses: one
/// connection per request, `Connection: close`, no keep-alive and no
/// concurrency, because the alternative is a dependency and a fixture
/// directory for something a page's whole purpose here is to 404.
final class TinyServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "prose.tests.tiny-server")
    let port: UInt16

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)

        // `.any` means "pick one", so the port is not known until the
        // listener is ready — and a URL built before then points at 0.
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.answer(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port else {
            listener.cancel()
            throw TinyServerError.neverStarted
        }
        port = bound.rawValue
    }

    func url(_ path: String) -> String { "http://127.0.0.1:\(port)\(path)" }

    func stop() { listener.cancel() }

    private enum TinyServerError: Error { case neverStarted }

    /// Reads one request line and writes one response.
    private static func answer(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
            let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"

            let (status, type, body) = Self.route(path)
            let response = """
                HTTP/1.1 \(status)\r
                Content-Type: \(type)\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func route(_ path: String) -> (String, String, String) {
        switch path {
        case "/page":
            // One request that succeeds and one that does not, both started
            // by the page itself, which is the traffic `browser_network`
            // exists to show.
            return (
                "200 OK", "text/html",
                """
                <html><body>page
                <script>
                  fetch('/ok').then(() => fetch('/missing'));
                </script>
                </body></html>
                """
            )
        case "/ok":
            return ("200 OK", "application/json", "{\"ok\":true}")
        case "/missing":
            return ("404 Not Found", "application/json", "{\"error\":\"nope\"}")
        case "/boom":
            // A server error that still renders, which is precisely why the
            // page cannot report this one about itself.
            return ("500 Internal Server Error", "text/html", "<html><body>oh dear</body></html>")
        default:
            return ("404 Not Found", "text/plain", "no")
        }
    }
}
