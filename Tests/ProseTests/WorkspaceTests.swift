import SwiftUI
import ProseCore
import Testing

@testable import Prose

@MainActor
@Suite("Workspace")
struct WorkspaceTests {
    /// A workspace with `count` tabs, the last one selected.
    private func workspace(tabs count: Int) -> Workspace {
        let workspace = Workspace()
        // `init` opens one tab, so the rest are added on top of it.
        for _ in 1..<count { workspace.newTab() }
        return workspace
    }

    @Test("a new tab is selected as it opens")
    func newTabIsSelected() {
        let workspace = workspace(tabs: 3)
        #expect(workspace.tabs.count == 3)
        #expect(workspace.active == workspace.tabs.last?.id)
    }

    @Test("closing the selected tab falls back to the row that took its place")
    func closingSelectedFallsForward() {
        let workspace = workspace(tabs: 3)
        let middle = workspace.tabs[1].id
        workspace.select(middle)

        workspace.close(middle)
        // The tab that slid up into the gap, so focus lands where the eye is.
        #expect(workspace.active == workspace.tabs[1].id)
        #expect(workspace.tabs.count == 2)
    }

    @Test("closing the last row falls back to the new last row")
    func closingTheEndFallsBack() {
        let workspace = workspace(tabs: 3)
        let last = workspace.tabs[2].id
        workspace.select(last)

        workspace.close(last)
        #expect(workspace.active == workspace.tabs.last?.id)
    }

    @Test("closing an unselected tab leaves the selection alone")
    func closingAnotherTabKeepsSelection() {
        let workspace = workspace(tabs: 3)
        let selected = workspace.tabs[2].id
        workspace.select(selected)

        workspace.close(workspace.tabs[0].id)
        #expect(workspace.active == selected)
    }

    @Test("closing the only tab leaves nothing selected")
    func closingTheOnlyTab() {
        let workspace = workspace(tabs: 1)
        workspace.close(workspace.tabs[0].id)

        #expect(workspace.tabs.isEmpty)
        #expect(workspace.active == nil)
        // And no highlight, because a highlight with no row is a cut, not a
        // slide (spec §6.3).
        #expect(workspace.selectionOffset == nil)
    }

    @Test("renaming a tab also selects it")
    func renamingSelects() {
        let workspace = workspace(tabs: 3)
        let first = workspace.tabs[0].id
        workspace.select(workspace.tabs[2].id)

        workspace.beginRename(first)
        #expect(workspace.active == first)
        #expect(workspace.rename?.tab == first)
        #expect(workspace.rename?.buffer == workspace.tabs[0].title, "starts from the current name")
    }

    @Test("committing a rename keeps the trimmed name")
    func commitKeepsTheName() {
        let workspace = workspace(tabs: 1)
        let tab = workspace.tabs[0].id

        workspace.beginRename(tab)
        workspace.rename?.buffer = "  research  "
        workspace.commitRename()

        #expect(workspace.tabs[0].title == "research")
        #expect(workspace.rename == nil)
    }

    @Test("an empty or whitespace-only name abandons the edit")
    func blankNameIsAbandoned() {
        // A row with no title would have nothing to click on (spec §6.5).
        for blank in ["", "   ", "\t\n"] {
            let workspace = workspace(tabs: 1)
            let before = workspace.tabs[0].title

            workspace.beginRename(workspace.tabs[0].id)
            workspace.rename?.buffer = blank
            workspace.commitRename()

            #expect(workspace.tabs[0].title == before, "buffer was \(blank.debugDescription)")
            #expect(workspace.rename == nil)
        }
    }

    @Test("escape discards the edit")
    func cancelDiscards() {
        let workspace = workspace(tabs: 1)
        workspace.beginRename(workspace.tabs[0].id)
        workspace.rename?.buffer = "discarded"
        workspace.cancelRename()

        #expect(workspace.tabs[0].title == "untitled")
        #expect(workspace.rename == nil)
    }

    @Test("selecting another tab commits the rename in progress")
    func selectingCommits() {
        // Leaving is treated as keeping, because a field that stayed open but
        // deaf to the keyboard would be worse.
        let workspace = workspace(tabs: 2)
        workspace.beginRename(workspace.tabs[0].id)
        workspace.rename?.buffer = "kept"

        workspace.select(workspace.tabs[1].id)

        #expect(workspace.tabs[0].title == "kept")
        #expect(workspace.rename == nil)
    }

    @Test("closing a tab being renamed drops the edit with it")
    func closingDropsTheRename() {
        let workspace = workspace(tabs: 2)
        let tab = workspace.tabs[0].id
        workspace.beginRename(tab)

        workspace.close(tab)
        #expect(workspace.rename == nil)
    }

    @Test("dragging the sidebar clamps to its minimum and maximum")
    func sidebarDragClamps() {
        let workspace = workspace(tabs: 1)

        workspace.resizeSidebar(to: 300)
        #expect(workspace.sidebarRestingWidth == 300)

        workspace.resizeSidebar(to: 20)
        #expect(workspace.sidebarRestingWidth == .sidebarMinWidth)

        workspace.resizeSidebar(to: 9000)
        #expect(workspace.sidebarRestingWidth == .sidebarMaxWidth)
    }

    @Test("dragging the edge forces the panel open")
    func draggingReopensTheSidebar() {
        // Direct manipulation must not fight a collapse in flight (spec §7.5).
        let workspace = workspace(tabs: 1)
        workspace.toggleSidebar()
        #expect(!workspace.sidebarOpen)

        workspace.resizeSidebar(to: 300)
        #expect(workspace.sidebarOpen)
    }

    @Test("the zoom rungs clamp and reset to exactly 1.0×")
    func zoomRungs() {
        let workspace = workspace(tabs: 1)
        #expect(workspace.metrics.zoom == 1.0)

        workspace.zoom(by: 1)
        #expect(workspace.metrics.zoom == 1.1)

        for _ in 0..<20 { workspace.zoom(by: 1) }
        #expect(workspace.metrics.zoom == 2.0, "held down, it rests at the top rung")

        workspace.resetZoom()
        #expect(workspace.metrics.zoom == 1.0)
    }

    @Test("the highlight sits on the selected row")
    func highlightTracksSelection() {
        let workspace = workspace(tabs: 3)
        workspace.select(workspace.tabs[0].id)
        #expect(workspace.selectionOffset == rowOffset(0))

        workspace.step(1)
        #expect(workspace.selectionOffset == rowOffset(1))

        // Clamped at the end of the strip rather than wrapping.
        workspace.step(1)
        workspace.step(1)
        #expect(workspace.selectionOffset == rowOffset(2))
    }
}
