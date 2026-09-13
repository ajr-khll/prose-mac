import Testing

@testable import ProseCore

/// Eleven of the twelve tests from `workspace.rs`, which is where the free
/// functions and the dimensions they read were covered.
///
/// The twelfth — `settling_a_running_slide_reads_it_without_needing_a_window` —
/// does **not** come across. It guarded a gpui crash: `request_animation_frame`
/// asked the window which view was being drawn, so interrupting a slide from an
/// event handler aborted the app, and the fix was a `settle` / `advance` split
/// with `settle` as the pure read. plan §4 and §7 delete that split outright,
/// because SwiftUI retargets a running animation from its current value by
/// construction. Testing it here would be testing a workaround that no longer
/// exists; what survives is `slide`, the curve, which two tests below cover.
@Suite("Metrics and the free functions")
struct MetricsTests {
    @Test("arrow keys walk the strip and stop at the ends")
    func arrowKeysWalkTheStrip() {
        let tabs = [0, 1, 2]

        #expect(nextSelection(tabs, active: 0, offset: 1) == 1)
        #expect(nextSelection(tabs, active: 1, offset: -1) == 0)
        // Clamped, not wrapped.
        #expect(nextSelection(tabs, active: 0, offset: -1) == 0)
        #expect(nextSelection(tabs, active: 2, offset: 1) == 2)
    }

    @Test("stepping with no selection lands on an end")
    func steppingWithNoSelection() {
        let tabs = [0, 1, 2]

        #expect(nextSelection(tabs, active: nil, offset: 1) == 0)
        #expect(nextSelection(tabs, active: nil, offset: -1) == 2)
        #expect(nextSelection([Int](), active: nil, offset: 1) == nil)
    }

    @Test("the slide runs from end to end and never overshoots")
    func slideRunsEndToEnd() {
        #expect(slide(from: 0, to: 240, progress: 0) == 0)
        #expect(slide(from: 0, to: 240, progress: 1) == 240)

        // Eased out, so it is already past halfway at the midpoint.
        let middle = slide(from: 0, to: 240, progress: 0.5)
        #expect(middle > 120 && middle < 240, "midpoint was \(middle)")

        // A late frame must not push the panel past its destination.
        #expect(slide(from: 0, to: 240, progress: 1.4) == 240)
    }

    @Test("collapsing reverses from wherever the panel currently is")
    func collapsingReverses() {
        #expect(slide(from: 240, to: 0, progress: 0) == 240)
        #expect(slide(from: 240, to: 0, progress: 1) == 0)
    }

    @Test("the zoom ladder clamps at both ends and resets to exactly one")
    func zoomLadderClamps() {
        let `default` = Metrics.defaultZoomStep
        let last = Metrics.zoomSteps.count - 1

        #expect(Metrics.zoomSteps[`default`] == 1.0)
        #expect(nextZoomStep(`default`, 1) == `default` + 1)
        #expect(nextZoomStep(`default`, -1) == `default` - 1)
        // Held down, it comes to rest at an end rather than wrapping round.
        #expect(nextZoomStep(last, 1) == last)
        #expect(nextZoomStep(0, -1) == 0)
        // And the ladder is ordered, so a step up is always a step bigger.
        #expect(zip(Metrics.zoomSteps, Metrics.zoomSteps.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test("the toggle dodges the traffic lights and still fits the sidebar")
    func toggleDodgesTheTrafficLights() {
        // Pushed right of the chips' column to clear the lights the system draws
        // over our transparent titlebar. The Rust test had a second arm for
        // Linux, where there are no lights to dodge and the toggle shared the
        // chips' column; Linux is formally dropped, so that arm goes with it.
        #expect(Points.toggleCenterX > Points.leadingCenterFromLeft)

        // It still has to stay inside the sidebar and clear of its left edge.
        let leftEdge = Points.toggleCenterX - Points.buttonSize / 2
        #expect(leftEdge > .zero, "toggle starts at \(leftEdge)")
        #expect(Points.toggleCenterX < Points.sidebarMinWidth)
    }

    @Test("the settings button shares the chips' column")
    func settingsButtonSharesTheChipsColumn() {
        // Same story as the toggle: the Rust version tucked this a quarter
        // closer to the corner on Linux, and that arm is gone.
        #expect(Points.settingsCenterX == Points.leadingCenterFromLeft)

        // It still has to fit: the button is centred here, not hanging off.
        let leftEdge = Points.settingsCenterX - Points.buttonSize / 2
        #expect(leftEdge > .zero, "settings button starts at \(leftEdge)")
    }

    @Test("header buttons grow only as far as the fixed row can hold them")
    func headerButtonsAreCapped() {
        // Below the cap a header button scales like anything else.
        #expect(Metrics.headerButtonScale(0.8) == 0.8)
        #expect(Metrics.headerButtonScale(1.0) == 1.0)
        #expect(Metrics.headerButtonScale(1.25) == 1.25)

        // Above it the button stops growing, so it cannot outgrow the row it
        // shares with the traffic lights.
        let cap = Pixels.headerButtonMax.value / Points.buttonSize.value
        #expect(Metrics.headerButtonScale(2.0) == cap)
        #expect(Points.buttonSize.value * Metrics.headerButtonScale(2.0) <= Pixels.headerButtonMax.value)

        // The whole ladder has to fit the row, at every rung.
        for zoom in Metrics.zoomSteps {
            let button = Points.buttonSize.value * Metrics.headerButtonScale(zoom)
            #expect(button < Pixels.headerHeight.value, "\(zoom)x button was \(button)")
        }
    }

    @Test("nearness peaks on the highlighted row and fades over one row")
    func nearnessPeaksOnItsRow() {
        let secondRow = rowOffset(1)

        // Parked on row 1: full tint there, none on its neighbours.
        #expect(nearness(secondRow, 1) == 1)
        #expect(nearness(secondRow, 0) == 0)
        #expect(nearness(secondRow, 2) == 0)
        // Rows further away never go negative.
        #expect(nearness(secondRow, 9) == 0)
        // Nothing selected means no row is tinted at all.
        #expect(nearness(nil, 1) == 0)
    }

    @Test("nearness splits the tint between the rows a slide is crossing")
    func nearnessSplitsBetweenRows() {
        // Halfway from row 0 to row 1, both should be tinted halfway.
        let halfway = rowOffset(0) + Points.rowPitch / 2

        #expect(nearness(halfway, 0) == 0.5)
        #expect(nearness(halfway, 1) == 0.5)
        // And the pair always sums to a whole row's worth of green.
        #expect(nearness(halfway, 0) + nearness(halfway, 1) == 1)
    }

    @Test("the content header keeps the sidebar toggle clear of every pane")
    func contentHeaderClearsTheToggle() {
        // The row is the same height as the sidebar's, so the two stay level
        // across the divider and the toggle has somewhere to sit at any zoom.
        // That it is big enough to hold the toggle is one of the four invariants
        // below, since neither constant depends on anything at runtime.
        #expect(Pixels.contentHeaderHeight == Pixels.headerHeight)

        // Panel out: the toggle is over the sidebar, so the content area owes it
        // nothing.
        #expect(
            contentHeaderInset(sidebarWidth: .sidebarWidth, zoom: 1) == .zero,
            "a full-width sidebar already holds the toggle"
        )

        // Panel away: the toggle comes to rest over the content area instead,
        // and the header has to start clear of it.
        let collapsed = contentHeaderInset(sidebarWidth: .zero, zoom: 1)
        #expect(
            collapsed > Pixels.unscaled(.toggleCenterX + .buttonSize / 2),
            "header started at \(collapsed), under the toggle"
        )

        // The toggle does not zoom, so neither may the gap that clears it —
        // zooming in only ever moves the panel further out of its way.
        for zoom in Metrics.zoomSteps {
            #expect(
                contentHeaderInset(sidebarWidth: .zero, zoom: zoom) == collapsed,
                "the gap moved at \(zoom)x"
            )
            #expect(contentHeaderInset(sidebarWidth: .sidebarWidth, zoom: zoom) == .zero)
        }
    }
}

/// spec §5's four invariants, which in Rust were `const _: () = assert!(...)`:
/// breaking one failed the build rather than a test run.
///
/// Swift has no clean equivalent over computed constants, so plan §6.2 moves
/// them here and notes the downgrade out loud — "cannot be compiled wrong"
/// becomes "cannot be released wrong". They are one case, and they assert
/// nothing at runtime that was not already true at compile time; if this suite
/// ever fails, a dimension moved without its neighbours.
@Suite("Metrics invariants")
struct MetricsInvariantTests {
    @Test("the dimensions that have to agree with each other still do")
    func invariantsHold() {
        // 1. The gutter clears the sidebar's grab strip. plan §2 retires the
        //    original reason (a native browser overlay swallowing the drag);
        //    the relationship is kept because the tiling was measured with it.
        #expect(Points.paneGap >= Points.resizeHandle)

        // 2. A pane dragged to its minimum must still show the header its
        //    buttons live in, or it can be shrunk to the point of being unusable.
        #expect(Points.paneMinHeight > Points.paneHeaderHeight)

        // 3. And it must still be wide enough for the buttons that header
        //    carries. Six, not three: a browser pane's header also holds back,
        //    forward and reload, and it is the widest header that has to fit.
        #expect(Points.paneMinWidth > Points.closeBox * 6 + Points.paneHeaderPaddingX * 2)

        // 4. The sidebar toggle has to fit the row the content area reserves for
        //    it. This one crosses the two bands: the button is a point
        //    measurement read in the fixed header's pixel space (spec §3).
        #expect(Pixels.unscaled(.buttonSize) <= Pixels.contentHeaderHeight)
    }
}
