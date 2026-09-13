//  The single owner of the shell's state (spec §14).
//
//  In the Rust original this held the tab list, the focus owners, the content
//  area's measured bounds, the drag in progress, the rename, the selection
//  slide and the zoom rung. Step 2 builds the shell only, so what is here is
//  the tab list, the sidebar, the rename and the zoom; the tiling, the panes
//  and their focus arrive with step 3 and belong in this same object.
//
//  The two animations are *not* state here. gpui drove them by reading elapsed
//  time against a start instant, which forced a pure-read / read-and-request
//  split; SwiftUI interpolates instead, so the sidebar's slide and the
//  selection's slide are `withAnimation` at the mutation site and nothing is
//  stored (plan §7).

import Observation
import ProseCore
import ProseHost
import SwiftUI

/// An inline rename in progress.
///
/// spec §6.5 describes a deliberately minimal editor — a buffer, a caret pinned
/// to the end, no selection, clipboard or IME — because gpui had no text field
/// to lean on. plan §4 retires all of that: a SwiftUI `TextField` is the whole
/// feature, so this is just which tab is being renamed and the buffer it holds.
struct Rename: Equatable {
    let tab: Tab.ID
    var buffer: String
}

/// Which of the two keyboard owners the plain arrow keys belong to (spec §12).
///
/// Once a pane can hold a caret it cannot also drive the tab strip, so the
/// choice has to be explicit. The Rust original asked gpui which focus handle
/// was current; here it is a field, because SwiftUI's focus system is about
/// which control has the keyboard and this is about which *region* does.
enum KeyboardOwner {
    /// Plain ↑/↓ move the tab selection; Enter starts a rename.
    case tabStrip
    /// Plain arrows move pane focus. This is the case for browser panes, which
    /// have no field of their own.
    case content
}

// plan §8: all UI state lives on the main actor, which is spec §14's single
// owner made explicit. The session registry sits beside it and hands lines
// across the boundary; nothing below ever leaves this one.
//
// The registry is `@MainActor` rather than the `actor` plan §8 proposed — the
// coalescing it was meant to buy moved one layer down into `Connection`, and a
// serialized context with no suspension points is what makes parking a request
// safe to check and install in one step. `SessionRegistry.swift` explains it.
@MainActor
@Observable
final class Workspace {
    private(set) var tabs: [Tab] = []
    private(set) var active: Tab.ID?
    var rename: Rename?

    /// Which rung of the zoom ladder the UI is drawn at.
    private(set) var zoomStep = Metrics.defaultZoomStep

    /// Whether the panel is out. The width animates between the resting width
    /// and zero; the contents do not reflow (spec §6.1).
    private(set) var sidebarOpen = true

    /// The width the sidebar returns to when revealed. A point measurement, so
    /// it is the same 240 at every zoom and the divider lands at 240 × zoom.
    private(set) var sidebarRestingWidth = Points.sidebarWidth

    private var nextTabID: UInt64 = 0
    private var nextPaneID: PaneID = 0

    /// Where the plain arrow keys go.
    var keyboardOwner: KeyboardOwner = .tabStrip

    /// Bumped whenever the keyboard has to come back to the workspace's own
    /// region — the view `WorkspaceView` hangs `onMoveCommand` on.
    ///
    /// `keyboardOwner` says which region the arrows are *aimed* at; this is how
    /// the region gets them at all. Leaving a pane by dropping first responder
    /// hands the keyboard to the `NSWindow`, which is the end of the responder
    /// chain and answers to nothing, so Escape and a tab switch both used to
    /// leave the arrows reaching nobody. A counter rather than a flag because
    /// the same handback can be asked for twice running and the second one
    /// still has to be heard.
    private(set) var keyboardReclaim = 0

    /// Bring the keyboard back to the region `keyboardOwner` names, out of
    /// whatever pane view is holding it.
    func reclaimKeyboard() {
        keyboardReclaim += 1
    }

    /// Escape from a composer or a URL field: the plain arrows go back to the
    /// tab strip (spec §12), and so does the keyboard itself.
    func resignToTabStrip() {
        keyboardOwner = .tabStrip
        reclaimKeyboard()
    }

    /// The pane a user has asked to close and not yet confirmed, which is what
    /// `WorkspaceView` puts an alert up for.
    ///
    /// State rather than an `NSAlert` raised at the call site, so the question
    /// "is a close pending, and on which pane" is testable without a window —
    /// and so the two ways of asking (Cmd+W and the pane header's ×) cannot
    /// drift apart.
    var paneCloseRequest: PaneID?

    /// One browser per browser pane, each with its own ephemeral session.
    ///
    /// Kept beside the panes rather than inside them for the same reason the
    /// split tree holds ids: `Pane` stays a value, and a `WKWebView` is very
    /// much not one.
    private var browsers: [PaneID: BrowserSession] = [:]

    /// One conversation per agent pane, kept beside the panes for the same
    /// reason the browsers are.
    private var agents: [PaneID: AgentSession] = [:]

    /// The socket every agent connects back on, and the table of who owns what.
    /// `socket` is nil when it could not be opened, which is a state the app
    /// runs in rather than refuses to launch in (spec §11).
    @ObservationIgnored var socket: AgentSocket?
    @ObservationIgnored let registry = SessionRegistry()
    /// Why there are no agents, if there are none.
    var hostFailure: String?

    /// Whether this workspace runs agents.
    ///
    /// Default off, which is backwards for the real app and right for
    /// everything else: the app opts in at its single call site, while a
    /// hundred tests that only care about tabs and panes would otherwise each
    /// open a socket and spawn a Python process.
    enum Hosting {
        case disabled
        case enabled
    }

    init(hosting: Hosting = .disabled) {
        // Before any pane exists, because opening one reserves a session on it
        // (spec §11) — and because the socket has nothing to do with a window,
        // which is what lets prose run its agents whether or not one is up yet.
        if hosting == .enabled { startHost() }

        // One tab to start in. Each one will run its own agent, so opening
        // three on launch would start three processes before the user had asked
        // for any.
        newTab()
        // A measurement affordance, not product behaviour: an agent cannot
        // inject a Cmd+= into this window, so spec §5's acceptance table at
        // 2.0× has to be reachable from a cold launch.
        let environment = ProcessInfo.processInfo.environment
        if let step = environment["PROSE_ZOOM_STEP"].flatMap(Int.init),
           Metrics.zoomSteps.indices.contains(step)
        {
            zoomStep = step
        }
        // Likewise for the collapsed sidebar: spec §7.1's content-header inset
        // only does anything once the panel has gone, and the toggle it clears
        // cannot be clicked from here.
        if environment["PROSE_SIDEBAR"] == "closed" {
            sidebarOpen = false
        }
        // And likewise for the tiling: "the gutter between any two panes" needs
        // two panes, and the only ways to make one are a click and a Cmd+D.
        // `PROSE_SPLIT=row,column` reproduces the three-pane figure the split
        // tests are written against — a tall left pane and a stacked pair.
        for axis in environment["PROSE_SPLIT"]?.split(separator: ",") ?? [] {
            guard let pane = focusedPane else { break }
            switch axis {
            case "row": splitPane(pane, .row)
            case "column": splitPane(pane, .column)
            default: break
            }
        }
        // And a browser pane with a page in it, because the whole of plan §2's
        // claim is about what a real WKWebView costs once it is on screen.
        if let address = environment["PROSE_BROWSER"], let pane = focusedPane {
            setPaneKind(pane, .browser)
            browser(pane)?.address = address
            // Deferred rather than loaded here: this runs while the `@State`
            // that holds the workspace is being initialised, which is before
            // the app has finished launching and before the web view is in a
            // window. A user loads a page long after both.
            let session = browser(pane)
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(500))
                session?.go()

                guard environment["PROSE_PROBE"] == "1", let view = session?.webView else { return }
                try? await Task.sleep(for: .seconds(3))
                BrowserProbe.run(
                    view,
                    // Where the tiling put this pane's top edge, and the header
                    // that has to stay visible above the page.
                    paneTop: Pixels.contentHeaderHeight.value + Points.paneGap.value * self.metrics.zoom,
                    headerHeight: self.metrics.px(.paneHeaderHeight)
                )
                if let path = environment["PROSE_SNAPSHOT"], let window = view.window {
                    BrowserProbe.snapshot(window, to: path)
                }
            }

            // plan §2 says a click taking first responder is correct rather
            // than something to fight, and prose leans on it — the pane focuses
            // *because* the web view did. An agent cannot click, so this drives
            // the same responder path from the other end to prove it is wired.
            if environment["PROSE_FOCUS_WEB"] == "1" {
                let session = browser(pane)
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    guard let view = session?.webView else { return }
                    view.window?.makeFirstResponder(view)
                }
            }
        }

        // One of every block spec §9.3 describes, in the focused pane. The
        // transcript is fed by an agent from step 6; until then this is the
        // only way to see a message, an activity, a code attachment, a notice
        // and an ask card at once — and it goes through `Transcript.apply`, so
        // it exercises step 1's reducer rather than drawing around it.
        if environment["PROSE_TRANSCRIPT"] == "demo", let pane = focusedPane {
            agent(pane)?.demo()
        }

        // Splitting hands the keyboard to the content area; a cold launch
        // should still start with the strip owning it.
        keyboardOwner = .tabStrip
    }

    var metrics: Metrics { Metrics(step: zoomStep) }

    var activeTab: Tab? {
        tabs.first { $0.id == active }
    }

    func index(of tab: Tab.ID) -> Int? {
        tabs.firstIndex { $0.id == tab }
    }

    /// Where the selection highlight rests, or `nil` when nothing is selected.
    /// A highlight can only travel *between* two rows: arriving from nowhere is
    /// a cut, not a slide (spec §6.3).
    var selectionOffset: Points? {
        active.flatMap(index(of:)).map(rowOffset)
    }

    // MARK: - Tabs

    func newTab() {
        let tab = Tab(id: nextTabID, title: "untitled", firstPane: nextPaneID)
        openAgent(nextPaneID)
        spawnAgent(for: nextPaneID)
        nextTabID += 1
        nextPaneID += 1
        tabs.append(tab)
        select(tab.id)
    }

    /// Every selection change goes through here — clicks, arrow keys, opening a
    /// tab and closing one — so none of them can bypass the animation (spec
    /// §6.3). Selecting also commits any rename in progress, because leaving a
    /// field is treated as keeping it.
    func select(_ tab: Tab.ID) {
        commitRename()
        // Clicking a row, or stepping the strip, is the strip asking for the
        // keyboard back — and asking in earnest: the outgoing tab's panes are
        // torn down, taking first responder with them, so without this the
        // strip owns arrows that reach nothing.
        resignToTabStrip()
        withAnimation(.easeOut(duration: Self.selectionSlide)) {
            active = tab
        }
    }

    func step(_ offset: Int) {
        guard let next = nextSelection(tabs.map(\.id), active: active, offset: offset) else {
            return
        }
        select(next)
    }

    func close(_ tab: Tab.ID) {
        guard let index = index(of: tab) else { return }
        if rename?.tab == tab { rename = nil }
        // Closing a tab closes every session in it.
        for pane in tabs[index].panes {
            endSession(for: pane.id)
            browsers[pane.id] = nil
            agents[pane.id] = nil
        }
        tabs.remove(at: index)

        guard active == tab else { return }
        // The row that took its place, or the last one if it was the end of the
        // strip. Nothing left means nothing selected.
        active = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
    }

    // MARK: - Renaming

    /// Starting a rename also selects that tab (spec §6.5).
    func beginRename(_ tab: Tab.ID) {
        guard let existing = tabs.first(where: { $0.id == tab }) else { return }
        select(tab)
        rename = Rename(tab: tab, buffer: existing.title)
    }

    /// Enter commits, and so does clicking away — leaving is treated as
    /// keeping, because a field that stayed open but deaf to the keyboard would
    /// be worse. An empty or whitespace-only name abandons the edit instead,
    /// since a row with no title would have nothing to click on.
    func commitRename() {
        guard let rename else { return }
        self.rename = nil

        let trimmed = rename.buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = index(of: rename.tab) else { return }
        tabs[index].title = trimmed
    }

    func cancelRename() {
        rename = nil
    }

    // MARK: - Panes

    /// The pane the split shortcuts and the arrow keys act on.
    var focusedPane: PaneID? { activeTab?.focused }

    /// Which tab holds `pane`. Searched across every tab rather than just the
    /// active one, because from step 6 an agent may split, close or rename a
    /// pane the user is not currently looking at.
    private func tabIndex(holding pane: PaneID) -> Int? {
        tabs.firstIndex { $0.pane(pane) != nil }
    }

    private var activeIndex: Int? {
        active.flatMap(index(of:))
    }

    /// Puts a fresh pane beside `pane` and focuses it, which is what splitting
    /// is for. From step 6 the new pane runs an agent; for now it is a frame
    /// with a placeholder in it.
    /// Splits a pane and starts an agent in the new one, returning its id.
    ///
    /// **One door for both routes in**: the user's Cmd+D and an agent's
    /// `pane.create`. They differ only in what the new agent is — a child of
    /// the one that asked for it, possibly with a command and a directory of
    /// its own — so those are parameters rather than a second path. Splitting
    /// here and spawning again at the call site is what gave an agent-created
    /// pane *two* processes and two sessions, one of them parentless, and left
    /// which one answered for the pane up to dictionary order.
    @discardableResult
    func splitPane(
        _ pane: PaneID, _ axis: ProseCore.Axis, placement: Placement = .after,
        kind: PaneKind = .agent,
        parent: SessionID? = nil, command: [String] = [], cwd: URL? = nil,
        environment: [String: String] = [:], url: String? = nil
    ) -> PaneID? {
        guard let tab = tabIndex(holding: pane) else { return nil }
        let new = nextPaneID
        guard tabs[tab].layout.split(pane, axis, new, placement) else { return nil }
        nextPaneID += 1

        tabs[tab].panes.append(Pane(id: new, kind: kind, title: nil))
        switch kind {
        case .agent:
            openAgent(new)
            spawnAgent(
                for: new, parent: parent, command: command, cwd: cwd, environment: environment)
        case .browser:
            openBrowser(new)
            // **A session with no process behind it.** A browser pane an agent
            // opened is that agent's to drive, and the way prose says so is the
            // same parent link every other pane is checked against — so it is
            // reserved here even though nothing will ever say hello on it. A
            // pane the *user* opened gets no session and is therefore nobody's
            // to drive, which is the containment that matters.
            if let parent, socket != nil {
                _ = registry.reserve(pane: new, parent: parent)
            }
            if let url { browser(new)?.navigate(to: url) }
        }
        // Through `focusPane` rather than by setting `focused` here, because
        // splitting has exactly the same obligation clicking and stepping have:
        // it must move the keyboard and not merely recolour a border (spec §8).
        // Setting the field by hand left the caret in the pane that was split,
        // so the first thing typed after a Cmd+D went to the wrong pane.
        focusPane(new)
        return new
    }

    /// Asks before closing, which is what every *user* route to closing a pane
    /// goes through.
    ///
    /// An agent's `pane.close` does not: it deliberately calls `closePane`
    /// straight through, because a pane asking to close itself has already made
    /// the decision and there would be nobody at the keyboard to answer.
    func requestClosePane(_ pane: PaneID) {
        guard tabIndex(holding: pane) != nil else { return }
        paneCloseRequest = pane
    }

    func confirmClosePane() {
        guard let pane = paneCloseRequest else { return }
        paneCloseRequest = nil
        closePane(pane)
    }

    func cancelClosePane() {
        paneCloseRequest = nil
    }

    /// Closes `pane`, giving its space back to its sibling. Closing a tab's
    /// last pane closes the tab, because it has nothing left to show — and
    /// closing the last tab leaves the window standing on an empty strip, since
    /// spec §2 gives prose exactly one window and quitting on an empty
    /// workspace would make Cmd+W a quit by another route.
    func closePane(_ pane: PaneID) {
        guard let tab = tabIndex(holding: pane) else { return }
        let tabID = tabs[tab].id

        // Before the pane is dropped, so the agent is told rather than simply
        // having its socket close under it (spec §11).
        endSession(for: pane)
        // And the same courtesy for a browser pane, which has no session for
        // `endSession` to reach: anyone parked on it is told now rather than
        // waiting out a timeout against a pane that no longer exists.
        if browsers[pane] != nil { registry.closed(pane: pane) }

        if paneCloseRequest == pane { paneCloseRequest = nil }

        let inheritsFocus = tabs[tab].layout.close(pane)
        tabs[tab].panes.removeAll { $0.id == pane }
        tabs[tab].focused = inheritsFocus
        browsers[pane] = nil
        agents[pane] = nil

        guard let inheritsFocus else {
            close(tabID)
            return
        }
        // The pane that held the keyboard has just gone, taking its first
        // responder with it, so the survivor has to be given the keyboard as
        // well as the ring — the same obligation splitting and stepping have.
        focusPane(inheritsFocus)
    }

    /// Clicking anywhere in a pane makes it the focused one, which is what the
    /// arrow keys and the split shortcuts act on.
    ///
    /// Each tab remembers its own focused pane, but there is one keyboard and it
    /// belongs to the tab on screen. A pane in any other tab therefore takes the
    /// ring and nothing else: an agent splitting or focusing a pane two tabs
    /// away used to repoint the plain arrows at the content area and leave an
    /// unspent claim on a composer nobody could see, which was then redeemed the
    /// moment the user opened that tab.
    func focusPane(_ pane: PaneID) {
        guard let tab = tabIndex(holding: pane) else { return }
        tabs[tab].focused = pane
        guard tabs[tab].id == active else { return }
        handKeyboard(to: pane)
    }

    /// An agent's `pane.focus`: **bring a pane into view** (spec §14's protocol
    /// table), which is a different act from clicking one.
    ///
    /// It shows the pane — selecting its tab if that is what it takes — and
    /// stops there. The keyboard is the user's: an agent that could move the
    /// caret could take it out of the middle of a sentence being typed in
    /// another pane, and in a window holding a dozen agent sessions that is not
    /// a rare event. So the ring moves, the tab moves, and first responder does
    /// not.
    func revealPane(_ pane: PaneID) {
        guard let tab = tabIndex(holding: pane) else { return }
        if tabs[tab].id != active { select(tabs[tab].id) }
        tabs[tab].focused = pane
    }

    /// Moves pane focus to whichever pane lies that way, or stays put at the
    /// edge of the tab — no wrapping.
    ///
    /// The answer comes from `Split.neighbour`, which works it out from the
    /// laid-out rectangles rather than by walking the tree: "the pane to my
    /// left" is a question about the screen, and a few nested splits in, the
    /// tree sibling and the visual neighbour stop being the same pane (spec §7.3).
    func stepPaneFocus(_ direction: ProseCore.Direction) {
        guard let tab = activeIndex,
              let from = tabs[tab].focused,
              let next = tabs[tab].layout.neighbour(from, direction)
        else { return }
        tabs[tab].focused = next
        // This used to move the focus ring and nothing else, so Cmd+Alt+arrow
        // recoloured a border while the keyboard stayed behind in the pane the
        // user had just left.
        handKeyboard(to: next)

        // Arriving by keyboard is not the same as arriving by click, and this is
        // the one place the two differ. A click has already put first responder
        // somewhere on the way in — the page, the URL field — whereas stepping
        // leaves it behind in the pane being left. So a browser pane showing a
        // page takes the keyboard *out* of wherever it was: spec §12 gives the
        // plain arrows to the content area for browser panes, and they only get
        // there if nothing else is holding them.
        if let browser = browsers[next], browser.hasPage {
            browser.releaseKeyboard()
            // Out of the page and *into* the content area, not into the window.
            // Releasing alone left the plain arrows with nowhere to land, so
            // the one keystroke that moved onto a page was the last one that
            // moved anywhere.
            reclaimKeyboard()
        }
    }

    /// Puts the caret in the field a newly focused pane has, if it has one.
    ///
    /// - An agent pane wants it in the composer, so the caret lands where the
    ///   typing will go (spec §8).
    /// - A browser pane with no page yet has only its URL field to offer, which
    ///   is also what makes a click on a pane that has just been created land
    ///   somewhere useful.
    /// - A browser pane **with** a page is left alone, and that is load-bearing
    ///   rather than an omission. This runs on the way *out* of
    ///   `PaneWebView.becomeFirstResponder` — the pane focuses because the page
    ///   did (plan §2) — so anything done to first responder here undoes the
    ///   click that caused it. Taking the keyboard back at this point made the
    ///   page impossible to type into at all, and the URL field with it.
    private func handKeyboard(to pane: PaneID) {
        keyboardOwner = .content

        // Asked of the view directly, and only left as a request when there is
        // no view to ask — a pane that has just been split into existence. A
        // request left in state does not reliably arrive: the pane bodies are
        // values holding one reference each, so focus moving between two panes
        // changes nothing SwiftUI can see and the subtree is never re-entered.
        if let agent = agents[pane], agent.focusComposer?() != true {
            agent.wantsComposerFocus = true
        }

        if let browser = browsers[pane], !browser.hasPage, browser.focusAddress?() != true {
            browser.wantsAddressFocus = true
        }
    }

    /// Cmd+L: the URL field of the focused pane, if it is a browser pane.
    ///
    /// It has to work when the pane is **empty**, which is exactly when the
    /// field is wanted, so it asks rather than assuming — and goes through the
    /// same door a click does, so the two cannot drift apart.
    func focusAddressBar() {
        guard let browser = focusedBrowser else { return }
        if browser.focusAddress?() != true { browser.wantsAddressFocus = true }
    }

    /// Swaps what a pane is showing.
    ///
    /// Turning an agent pane into a browser one ends its session (spec §11), so
    /// from step 6 this also tells the agent to shut down. There are no sessions
    /// yet; what it loses today is the title the agent had given it.
    func setPaneKind(_ pane: PaneID, _ kind: PaneKind) {
        guard let tab = tabIndex(holding: pane),
              let index = tabs[tab].panes.firstIndex(where: { $0.id == pane }),
              tabs[tab].panes[index].kind != kind
        else { return }

        tabs[tab].panes[index].kind = kind
        tabs[tab].panes[index].title = nil

        switch kind {
        case .browser:
            // Turning an agent pane into a browser one ends its session, since
            // nothing is left to draw its output (spec §11).
            endSession(for: pane)
            agents[pane] = nil
            openBrowser(pane)
        case .agent:
            // Its page, its history and its ephemeral cookie jar all go with it.
            browsers[pane] = nil
            openAgent(pane)
            spawnAgent(for: pane)
        }
    }

    /// What `pane` is browsing, if it is a browser pane.
    func browser(_ pane: PaneID) -> BrowserSession? { browsers[pane] }

    /// The browser the browser chords act on, if the focused pane is one.
    /// Reload, Cmd+L and the history chords are all no-ops otherwise.
    var focusedBrowser: BrowserSession? { focusedPane.flatMap { browsers[$0] } }

    /// The conversation in `pane`, if it is an agent pane.
    func agent(_ pane: PaneID) -> AgentSession? { agents[pane] }

    private func openAgent(_ pane: PaneID) {
        let session = AgentSession(pane: pane)
        // A click into the composer is reported by the text view itself: the
        // pane's outer SwiftUI gesture never sees a click AppKit consumed.
        session.onFocus = { [weak self] in self?.focusPane(pane) }
        agents[pane] = session
    }

    /// Creates the session up front rather than lazily from a view body, which
    /// would be a mutation in the middle of a view update.
    private func openBrowser(_ pane: PaneID) {
        let session = BrowserSession(pane: pane)
        // The page names the pane, through the same setter an agent's
        // `pane.title` will use once the protocol grows one.
        session.onTitle = { [weak self] title in self?.setPaneTitle(pane, title) }
        // And a click in the page makes this the focused pane.
        session.onFocus = { [weak self] in self?.focusPane(pane) }
        // A finished navigation answers anything parked on this pane. The
        // counter has already been incremented by the time this runs, so a
        // waiter woken here sees a cursor that has genuinely moved.
        session.onLoad = { [weak self] in self?.registry.progressed(pane, .loaded) }
        // Escape in the URL field gives the plain arrow keys back to the strip,
        // exactly as it does from the composer (spec §12). Without this a
        // browser pane was somewhere the keyboard could go and not come back.
        session.onResignToTabStrip = { [weak self] in self?.resignToTabStrip() }
        browsers[pane] = session
    }

    /// What a pane calls itself. `nil` falls the header back to the kind's own
    /// name (spec §8).
    func setPaneTitle(_ pane: PaneID, _ title: String?) {
        guard let tab = tabIndex(holding: pane),
              let index = tabs[tab].panes.firstIndex(where: { $0.id == pane })
        else { return }
        tabs[tab].panes[index].title = title
    }

    // MARK: - Divider drags

    /// The fraction a split is resting at, read when a drag starts so the whole
    /// gesture is measured from one place rather than accumulating per frame.
    func fraction(of split: SplitID) -> Double? {
        activeTab?.layout.fraction(of: split)
    }

    /// spec §7.4's rule: the pointer delta is read as a fraction of *that
    /// split's own region*, not of the whole tab, and clamped so neither side
    /// drops below a pane's minimum. A region too small to hold two minimums
    /// pins to 0.5 rather than returning something outside 0…1 and inverting
    /// the panes — that last part lives in ProseCore's `clampedFraction`.
    ///
    /// Unlike the sidebar drag there is no zoom to divide out: the pointer and
    /// the tiling's measured size are both already in real pixels, and only the
    /// minimum is a point measurement, which the caller scales.
    func resizeDivider(
        _ split: SplitID,
        startFraction: Double,
        delta: Double,
        parentPx: Double,
        minPx: Double
    ) {
        guard parentPx > 0, let tab = activeIndex else { return }
        let raw = startFraction + delta / parentPx
        tabs[tab].layout.setFraction(split, clampedFraction(raw, parentPx: parentPx, minPx: minPx))
    }

    // MARK: - The sidebar

    func toggleSidebar() {
        withAnimation(.easeOut(duration: Self.sidebarSlide)) {
            sidebarOpen.toggle()
        }
    }

    /// Dragging the sidebar's edge. Cancels any collapse in flight — direct
    /// manipulation must not fight an animation — and forces the panel open.
    func resizeSidebar(to width: Points) {
        sidebarRestingWidth = min(max(width, .sidebarMinWidth), .sidebarMaxWidth)
        sidebarOpen = true
    }

    // MARK: - Zoom

    func zoom(by steps: Int) {
        zoomStep = nextZoomStep(zoomStep, steps)
    }

    func resetZoom() {
        zoomStep = Metrics.defaultZoomStep
    }

    // MARK: - Animation

    /// spec §6.1 and §6.3's two durations, as seconds, which is the unit
    /// SwiftUI's curves take. Ease-out cubic in gpui; `.easeOut` here, which is
    /// the same shape — quick to leave, gentle to settle.
    static let sidebarSlide = Metrics.sidebarSlide.seconds
    static let selectionSlide = Metrics.selectionSlide.seconds
}

extension Duration {
    /// SwiftUI's animations are specified in seconds.
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
