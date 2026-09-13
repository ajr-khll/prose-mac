import ProseCore
import Testing

@testable import Prose

/// The shell's pane decisions. The tiling arithmetic itself lives in
/// ProseCore's `Split` and is tested there; what is here is what the workspace
/// does around it — which pane takes focus, when a tab goes with its last pane,
/// and how a divider drag turns a pointer delta into a fraction.
@MainActor
@Suite("Panes")
struct PaneTests {
    /// The three-pane figure the split tests are written against: a tall left
    /// pane, and a right column split into top and bottom.
    ///
    /// ```text
    ///   +-----+-----+
    ///   |     |  1  |
    ///   |  0  +-----+
    ///   |     |  2  |
    ///   +-----+-----+
    /// ```
    private func threePanes() -> (Workspace, [PaneID]) {
        let workspace = Workspace()
        let first = workspace.activeTab!.panes[0].id
        workspace.splitPane(first, .row)
        let second = workspace.activeTab!.focused!
        workspace.splitPane(second, .column)
        let third = workspace.activeTab!.focused!
        return (workspace, [first, second, third])
    }

    @Test("a tab opens as one pane filling the content area")
    func tabStartsWithOnePane() {
        let workspace = Workspace()
        let tab = workspace.activeTab!
        #expect(tab.panes.count == 1)
        #expect(tab.focused == tab.panes[0].id)
        #expect(tab.placed().count == 1)
        #expect(tab.placed()[0].rect == .full)
    }

    @Test("splitting focuses the new pane, which is what splitting is for")
    func splittingFocusesTheNewPane() {
        let (workspace, panes) = threePanes()
        #expect(workspace.activeTab!.panes.count == 3)
        #expect(workspace.activeTab!.focused == panes[2])
        // And it hands the keyboard to the content area, so Cmd+D twice in a
        // row splits the pane that just appeared.
        #expect(workspace.keyboardOwner == .content)
    }

    @Test("splitting a pane that is not open changes nothing")
    func splittingAnAbsentPane() {
        let workspace = Workspace()
        workspace.splitPane(9999, .row)
        #expect(workspace.activeTab!.panes.count == 1)
    }

    @Test("pane ids stay unique across tabs")
    func paneIDsAreUnique() {
        let (workspace, panes) = threePanes()
        workspace.newTab()
        let fresh = workspace.activeTab!.panes[0].id
        #expect(!panes.contains(fresh))
    }

    @Test("closing a pane gives its space back and focuses the survivor")
    func closingFocusesTheSurvivor() {
        let (workspace, panes) = threePanes()
        workspace.closePane(panes[2])

        let tab = workspace.activeTab!
        #expect(tab.panes.count == 2)
        #expect(tab.focused == panes[1], "the sibling it collapsed into")
        // Pane 1 grows back into the full right column rather than leaving a
        // hole where 2 was.
        let right = tab.placed().first { $0.pane.id == panes[1] }!.rect
        #expect(right == UnitRect(x: 0.5, y: 0, w: 0.5, h: 1))
    }

    @Test("closing a tab's last pane closes the tab")
    func closingTheLastPaneClosesTheTab() {
        let workspace = Workspace()
        workspace.newTab()
        let doomed = workspace.activeTab!
        #expect(workspace.tabs.count == 2)

        workspace.closePane(doomed.panes[0].id)
        #expect(workspace.tabs.count == 1, "the tab had nothing left to show")
    }

    @Test("closing the last pane of the last tab leaves the workspace standing")
    func closingEverythingLeavesABlankSlate() {
        let workspace = Workspace()
        workspace.closePane(workspace.activeTab!.panes[0].id)

        // spec §2 gives prose exactly one window, so the end of the last tab
        // has to be a state it can sit in rather than a reason to quit.
        #expect(workspace.tabs.isEmpty)
        #expect(workspace.active == nil)
        #expect(workspace.activeTab == nil, "the content area draws nothing, and that is the state")

        // And it is a state you can leave: a new tab starts the workspace again.
        workspace.newTab()
        #expect(workspace.tabs.count == 1)
        #expect(workspace.activeTab?.panes.count == 1)
    }

    // MARK: - Confirming a close

    @Test("asking to close a pane closes nothing yet")
    func closeRequestIsNotAClose() {
        let (workspace, panes) = threePanes()
        workspace.requestClosePane(panes[2])

        #expect(workspace.paneCloseRequest == panes[2])
        #expect(workspace.activeTab!.panes.count == 3, "still there until the alert is answered")
    }

    @Test("confirming closes the pane that was asked about")
    func confirmingClosesIt() {
        let (workspace, panes) = threePanes()
        workspace.requestClosePane(panes[2])
        workspace.confirmClosePane()

        #expect(workspace.paneCloseRequest == nil)
        #expect(workspace.activeTab!.panes.count == 2)
        #expect(workspace.activeTab!.panes.contains { $0.id == panes[2] } == false)
    }

    @Test("cancelling leaves the pane alone")
    func cancellingKeepsIt() {
        let (workspace, panes) = threePanes()
        workspace.requestClosePane(panes[2])
        workspace.cancelClosePane()

        #expect(workspace.paneCloseRequest == nil)
        #expect(workspace.activeTab!.panes.count == 3)
    }

    @Test("confirming with nothing pending closes nothing")
    func confirmingNothingIsHarmless() {
        let (workspace, _) = threePanes()
        workspace.confirmClosePane()
        #expect(workspace.activeTab!.panes.count == 3)
    }

    @Test("a pane that goes away by another route takes its pending question with it")
    func closingElsewhereClearsTheRequest() {
        let (workspace, panes) = threePanes()
        workspace.requestClosePane(panes[2])

        // What an agent's `pane.close` does: straight through, no alert. The
        // question on screen is now about a pane that no longer exists.
        workspace.closePane(panes[2])
        #expect(workspace.paneCloseRequest == nil)
    }

    @Test("asking about a pane that is not open is ignored")
    func requestForAnUnknownPane() {
        let (workspace, _) = threePanes()
        workspace.requestClosePane(999)
        #expect(workspace.paneCloseRequest == nil)
    }

    @Test("directional focus reads the laid-out rectangles, not the tree")
    func directionalFocus() {
        // Panes 1 and 2 are tree siblings; pane 0 is neither's sibling, yet it
        // is the visual neighbour of both (spec §7.3).
        let (workspace, panes) = threePanes()
        workspace.focusPane(panes[2])

        workspace.stepPaneFocus(.left)
        #expect(workspace.focusedPane == panes[0])

        workspace.stepPaneFocus(.right)
        #expect(workspace.focusedPane == panes[1], "the top of the right column")

        workspace.stepPaneFocus(.down)
        #expect(workspace.focusedPane == panes[2])
    }

    @Test("focus stays put at the edge of the tab rather than wrapping")
    func focusStopsAtTheEdge() {
        let (workspace, panes) = threePanes()
        workspace.focusPane(panes[0])

        workspace.stepPaneFocus(.left)
        #expect(workspace.focusedPane == panes[0])
        workspace.stepPaneFocus(.up)
        #expect(workspace.focusedPane == panes[0])
        // And never diagonally: pane 2 only touches pane 0 at a corner.
        workspace.stepPaneFocus(.down)
        #expect(workspace.focusedPane == panes[0])
    }

    @Test("clicking a pane focuses it and aims the keyboard at the content area")
    func clickingFocuses() {
        let (workspace, panes) = threePanes()
        workspace.select(workspace.tabs[0].id)
        #expect(workspace.keyboardOwner == .tabStrip)

        workspace.focusPane(panes[0])
        #expect(workspace.focusedPane == panes[0])
        #expect(workspace.keyboardOwner == .content)
    }

    @Test("turning a pane into a browser pane swaps what it shows")
    func turningIntoABrowserPane() {
        let (workspace, panes) = threePanes()
        workspace.setPaneKind(panes[0], .browser)

        let pane = workspace.activeTab!.pane(panes[0])!
        #expect(pane.kind == .browser)
        #expect(pane.displayTitle == "Browser")
        #expect(pane.kind.placeholder == "No page yet")
    }

    @Test("a pane keeps the name an agent gave it until the kind changes")
    func titleFallsBackToTheKind() {
        let (workspace, panes) = threePanes()
        #expect(workspace.activeTab!.pane(panes[0])!.displayTitle == "Agent")

        // Turning it into a browser ends its session, so the name that session
        // gave it goes too.
        workspace.setPaneKind(panes[0], .browser)
        #expect(workspace.activeTab!.pane(panes[0])!.title == nil)
    }

    @Test("setting the kind a pane already has does nothing")
    func settingTheSameKind() {
        let (workspace, panes) = threePanes()
        workspace.setPaneKind(panes[0], .agent)
        #expect(workspace.activeTab!.pane(panes[0])!.kind == .agent)
    }

    // MARK: - Divider drags

    /// The split between the left pane and the right column.
    private func verticalSplit(_ workspace: Workspace) -> SplitID {
        workspace.activeTab!.layout.dividers().first { $0.axis == .row }!.split
    }

    @Test("dragging a divider reads the delta as a fraction of its own region")
    func draggingReadsItsOwnRegion() {
        let (workspace, _) = threePanes()
        let split = verticalSplit(workspace)

        // The vertical divider's region is the whole tab, 800px wide here.
        workspace.resizeDivider(split, startFraction: 0.5, delta: -160, parentPx: 800, minPx: 160)
        #expect(workspace.fraction(of: split) == 0.3)
    }

    @Test("a divider cannot be dragged past a pane's minimum")
    func draggingRespectsTheMinimum() {
        let (workspace, _) = threePanes()
        let split = verticalSplit(workspace)

        workspace.resizeDivider(split, startFraction: 0.5, delta: -10_000, parentPx: 800, minPx: 160)
        #expect(workspace.fraction(of: split) == 160.0 / 800.0)

        workspace.resizeDivider(split, startFraction: 0.5, delta: 10_000, parentPx: 800, minPx: 160)
        #expect(workspace.fraction(of: split) == 1 - 160.0 / 800.0)
    }

    @Test("a region too small for two minimums pins to the middle")
    func tooSmallPinsToTheMiddle() {
        // Rather than returning a fraction outside 0…1 and inverting the panes.
        let (workspace, _) = threePanes()
        let split = verticalSplit(workspace)

        workspace.resizeDivider(split, startFraction: 0.5, delta: -90, parentPx: 200, minPx: 160)
        #expect(workspace.fraction(of: split) == 0.5)
    }

    @Test("a drag against a region of no width is ignored")
    func zeroWidthRegion() {
        // The first frame after a split can measure nothing; dividing by it
        // would produce a fraction of infinity.
        let (workspace, _) = threePanes()
        let split = verticalSplit(workspace)

        workspace.resizeDivider(split, startFraction: 0.5, delta: 40, parentPx: 0, minPx: 160)
        #expect(workspace.fraction(of: split) == 0.5)
    }

    @Test("dragging one divider leaves the others alone")
    func draggingIsLocal() {
        let (workspace, _) = threePanes()
        let vertical = verticalSplit(workspace)
        let horizontal = workspace.activeTab!.layout.dividers().first { $0.axis == .column }!.split

        workspace.resizeDivider(vertical, startFraction: 0.5, delta: -200, parentPx: 800, minPx: 160)
        #expect(workspace.fraction(of: horizontal) == 0.5)
    }

    /// A pilot puts the page above itself, at the page's full width — which is
    /// two claims: `before` in the column, and the same horizontal extent.
    @Test("a browser pane placed before its opener sits above it, aligned")
    func browserAboveItsPilot() throws {
        let workspace = Workspace()
        let pilot = try #require(workspace.activeTab?.panes[0].id)
        let page = try #require(
            workspace.splitPane(pilot, .column, placement: .before, kind: .browser))

        let rects = Dictionary(uniqueKeysWithValues: workspace.activeTab!.layout.rects())
        let above = try #require(rects[page])
        let below = try #require(rects[pilot])

        #expect(above.y < below.y, "the page is on top")
        #expect(above.x == below.x && above.w == below.w, "and they share a column")
    }

    /// The default is unchanged, because every other split in the app uses it.
    @Test("splitting without a placement still puts the new pane second")
    func defaultPlacementIsAfter() throws {
        let workspace = Workspace()
        let first = try #require(workspace.activeTab?.panes[0].id)
        let second = try #require(workspace.splitPane(first, .column))

        let rects = Dictionary(uniqueKeysWithValues: workspace.activeTab!.layout.rects())
        #expect(try #require(rects[second]).y > #require(rects[first]).y)
    }
}
