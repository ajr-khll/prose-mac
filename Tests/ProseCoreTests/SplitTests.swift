import Testing

@testable import ProseCore

/// The eleven tests from `split.rs`, ported rather than reinvented: they are the
/// accumulated answer to what the tiling must do, and the port is only trusted
/// once they say the same things about the Swift tree.
@Suite("Split tree")
struct SplitTests {
    /// Left pane full height, right pane split into top and bottom.
    ///
    /// ```text
    ///   +-----+-----+
    ///   |     |  1  |
    ///   |  0  +-----+
    ///   |     |  2  |
    ///   +-----+-----+
    /// ```
    private func threePanes() -> Split {
        var split = Split(0)
        split.split(0, .row, 1)
        split.split(1, .column, 2)
        return split
    }

    @Test("splitting a leaf puts both panes where the one was")
    func splittingALeaf() {
        var split = Split(0)
        let ok = split.split(0, .row, 1)
        #expect(ok)

        let rects = split.rects()
        #expect(rects.map(\.0) == [0, 1])
        #expect(rects[0].1 == UnitRect(x: 0, y: 0, w: 0.5, h: 1))
        #expect(rects[1].1 == UnitRect(x: 0.5, y: 0, w: 0.5, h: 1))
    }

    /// A browser pilot sits under the page it is driving, so a split has to be
    /// able to put the newcomer *first*.
    @Test("placing before puts the new pane above or left of its target")
    func placingBefore() {
        var split = Split(0)
        let ok = split.split(0, .column, 1, .before)
        #expect(ok)

        let rects = split.rects()
        let placed = Dictionary(uniqueKeysWithValues: rects)
        // 1 took the top half; 0, which was split, kept the bottom.
        #expect(placed[1] == UnitRect(x: 0, y: 0, w: 1, h: 0.5))
        #expect(placed[0] == UnitRect(x: 0, y: 0.5, w: 1, h: 0.5))
    }

    @Test("placing after is the default and is unchanged")
    func placingAfter() {
        var before = Split(0)
        var byDefault = Split(0)
        before.split(0, .column, 1, .after)
        byDefault.split(0, .column, 1)
        #expect(before.rects().map(\.0) == byDefault.rects().map(\.0))
        #expect(byDefault.rects().first?.0 == 0, "the target stays first")
    }

    /// The two panes share the space evenly whichever order they are in —
    /// placement moves the newcomer, it does not resize anybody.
    @Test("placement does not change the fraction")
    func placementKeepsTheFraction() {
        var before = Split(0)
        var after = Split(0)
        before.split(0, .row, 1, .before)
        after.split(0, .row, 1, .after)
        #expect(before.rects().map(\.1.w).sorted() == after.rects().map(\.1.w).sorted())
        #expect(before.dividers().count == after.dividers().count)
    }

    @Test("placing before works at depth, not just on the root")
    func placingBeforeNested() {
        var split = threePanes()
        let ok = split.split(2, .column, 3, .before)
        #expect(ok)

        let placed = Dictionary(uniqueKeysWithValues: split.rects())
        let three = try! #require(placed[3])
        let two = try! #require(placed[2])
        #expect(three.y < two.y, "3 sits above the pane it split")
        #expect(three.x == two.x && three.w == two.w, "and is aligned with it")
    }

    @Test("splitting a pane that is not here changes nothing")
    func splittingAnAbsentPane() {
        var split = Split(0)
        let ok = split.split(9, .row, 1)
        #expect(!ok)

        let rects = split.rects()
        #expect(rects.count == 1)
        #expect(rects[0].0 == 0)
        #expect(rects[0].1 == .full)
    }

    @Test("nested splits still tile the whole area")
    func nestedSplitsTileTheArea() {
        let rects = threePanes().rects()
        #expect(rects.count == 3)

        let area = rects.reduce(0.0) { $0 + $1.1.w * $1.1.h }
        #expect(abs(area - 1) < 1e-5, "panes covered \(area) of the tab")

        for (pane, rect) in rects {
            #expect(
                rect.x >= 0 && rect.y >= 0 && rect.x + rect.w <= 1 && rect.y + rect.h <= 1,
                "pane \(pane) escaped the tab at \(rect)"
            )
        }
    }

    @Test("closing a pane gives its whole parent to the sibling")
    func closingGivesSpaceBack() {
        var split = threePanes()

        // Pane 2 goes, so pane 1 should grow back into the full right column
        // rather than leaving a hole where 2 was.
        let focus = split.close(2)
        #expect(focus == 1)

        let rects = split.rects()
        #expect(rects.map(\.0) == [0, 1])
        #expect(rects[0].1 == UnitRect(x: 0, y: 0, w: 0.5, h: 1))
        #expect(rects[1].1 == UnitRect(x: 0.5, y: 0, w: 0.5, h: 1))
    }

    @Test("closing the last pane empties the tab")
    func closingTheLastPane() {
        var split = Split(0)
        let focus = split.close(0)
        #expect(focus == nil)
        #expect(split.rects().isEmpty)
        #expect(split.dividers().isEmpty)
    }

    @Test("every split offers exactly one divider to grab")
    func oneDividerPerSplit() throws {
        let dividers = threePanes().dividers()
        #expect(dividers.count == 2)

        let vertical = try #require(dividers.first { $0.axis == .row }, "the left/right split")
        // A vertical line: no width, full height, halfway across.
        #expect(vertical.line.x == 0.5)
        #expect(vertical.line.w == 0)
        #expect(vertical.line.h == 1)

        let horizontal = try #require(dividers.first { $0.axis == .column }, "the top/bottom split")
        // It only spans the right column, not the whole tab.
        #expect(horizontal.line.x == 0.5)
        #expect(horizontal.line.w == 0.5)
        #expect(horizontal.line.h == 0)
    }

    @Test("a divider cannot be dragged past a pane's minimum")
    func dividerRespectsMinimums() {
        let min = 160.0
        #expect(clampedFraction(0.01, parentPx: 800, minPx: min) == min / 800)
        #expect(clampedFraction(0.99, parentPx: 800, minPx: min) == 1 - min / 800)
        #expect(clampedFraction(0.5, parentPx: 800, minPx: min) == 0.5)

        // Too narrow to hold two minimums: splitting the difference is the only
        // answer that keeps the fraction inside 0...1 and the panes in order.
        #expect(clampedFraction(0.1, parentPx: 200, minPx: min) == 0.5)
        #expect(clampedFraction(0.1, parentPx: 0, minPx: min) == 0.5)
    }

    @Test("moving focus sideways picks the pane that shares the most edge")
    func focusPicksTheLongestSharedEdge() {
        let split = threePanes()

        // From the tall left pane, both right-hand panes are adjacent and share
        // half its edge each; the tie is broken consistently rather than by
        // whichever happened to be visited first.
        #expect(split.neighbour(0, .right) == 1)
        #expect(split.neighbour(1, .left) == 0)
        #expect(split.neighbour(2, .left) == 0)

        #expect(split.neighbour(1, .down) == 2)
        #expect(split.neighbour(2, .up) == 1)
    }

    @Test("focus stops at the edge of the tab")
    func focusStopsAtTheEdge() {
        let split = threePanes()
        #expect(split.neighbour(0, .left) == nil)
        #expect(split.neighbour(0, .up) == nil)
        #expect(split.neighbour(1, .right) == nil)
        #expect(split.neighbour(2, .down) == nil)
    }

    @Test("focus never steps to a pane that only touches at a corner")
    func focusIgnoresDiagonalNeighbours() {
        let split = threePanes()

        // Pane 2 sits below-right of nothing: moving up from the left pane must
        // not jump diagonally into the right column.
        #expect(split.neighbour(0, .down) == nil)
        #expect(split.neighbour(2, .right) == nil)
    }

    @Test("dragging a divider moves only the split it belongs to")
    func draggingMovesOneSplit() throws {
        var split = threePanes()
        let dividers = split.dividers()
        let vertical = try #require(dividers.first { $0.axis == .row }, "the left/right split")

        split.setFraction(vertical.split, 0.25)
        #expect(split.fraction(of: vertical.split) == 0.25)

        let left = try #require(split.rects().first { $0.0 == 0 }).1
        #expect(left.w == 0.25)

        // The nested top/bottom split is untouched by its parent moving.
        let horizontal = try #require(dividers.first { $0.axis == .column }, "the top/bottom split")
        #expect(split.fraction(of: horizontal.split) == 0.5)
    }
}
