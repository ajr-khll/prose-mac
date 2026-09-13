//  Stepping the tab selection, and the curve the two animations run on.
//
//  The last of spec §14's "handful of free functions worth keeping as pure
//  logic". They are small, and each one is a place a port silently drifts.

// MARK: - Stepping the strip

/// Which tab `offset` rows away from the current one should be selected.
///
/// Clamps at both ends rather than wrapping, so holding an arrow key comes to
/// rest at the top or bottom of the strip.
///
/// Generic over the id rather than taking the app's `Tab`, because the only
/// thing this decision needs is the order the ids are in — which is what keeps
/// it here, in a target with no window to put a tab strip in.
public func nextSelection<ID: Equatable>(_ tabs: [ID], active: ID?, offset: Int) -> ID? {
    if tabs.isEmpty { return nil }
    let last = tabs.count - 1

    let index: Int
    if let active, let current = tabs.firstIndex(of: active) {
        index = min(max(current + offset, 0), last)
    } else if offset > 0 {
        // With nothing selected, the first step lands on whichever end the
        // selection is travelling away from.
        index = 0
    } else {
        index = last
    }
    return tabs[index]
}

// MARK: - The slide

/// Ease-out cubic: quick to leave, gentle to settle, which is what makes a panel
/// feel like it has weight.
public func easeOutCubic(_ progress: Double) -> Double {
    let remaining = 1 - min(max(progress, 0), 1)
    return 1 - remaining * remaining * remaining
}

/// Eased position between `from` and `to`.
///
/// Both animations — the 180ms sidebar collapse and the 140ms selection slide —
/// run on this curve. In the Rust original this was read against an elapsed
/// instant every frame; in Swift the framework interpolates instead (plan §7),
/// so what survives here is the *definition* of the curve rather than the
/// machinery that drove it. Clamped at both ends, because a late frame must not
/// push the panel past its destination.
public func slide(from: Points, to: Points, progress: Double) -> Points {
    from + (to - from) * easeOutCubic(progress)
}
