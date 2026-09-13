//  The pane layout inside one tab: a binary tree with a pane at every leaf.
//
//  There is no UI framework in this file on purpose. The tree stores `PaneID`s
//  rather than views, so every question about geometry — where a pane sits,
//  which divider belongs to which split, what lies to the left of this pane —
//  stays a pure function that can be answered without a window.
//
//  Ported from `split.rs`. `@Observable` would let a Swift tree hold view
//  handles safely, but plan §5 is explicit that the reason to keep ids was
//  never the framework: it is that this file has no import and its tests need
//  no window.

/// A pane's identity. Stable across splitting and closing, unlike a position
/// in the tree.
public typealias PaneID = UInt64

/// A split's identity, so a divider drag knows which node it is resizing.
/// Stable while the rest of the tree changes around it, unlike a path.
public typealias SplitID = UInt64

/// Fractions accumulate rounding as the tree deepens, so edges that ought to
/// touch exactly are compared with a little room.
private let slack: Double = 1e-4

/// Which way a split lays its two children out.
public enum Axis: Sendable, Hashable {
    /// Side by side, parted by a vertical divider.
    case row
    /// Stacked, parted by a horizontal divider.
    case column
}

/// Which side of the target a new pane lands on.
///
/// Splitting has always put the new pane second — right of, or below, whatever
/// it split. That is the right default for "give me another pane", and wrong
/// for the one case where the two panes have a settled reading order: a
/// browser pilot belongs *under* the page it is driving, because the page is
/// the thing being looked at and the agent is the commentary on it.
public enum Placement: Sendable, Hashable {
    /// Right of, or below, the target. The default everything else uses.
    case after
    /// Left of, or above it.
    case before
}

/// Where to look for a neighbouring pane.
public enum Direction: Sendable, Hashable {
    case left, right, up, down

    /// The axis this direction travels along.
    fileprivate var axis: Axis {
        switch self {
        case .left, .right: .row
        case .up, .down: .column
        }
    }
}

/// A pane's share of the content area, with both axes running 0 to 1.
///
/// Unit space rather than points because the tree is resolved during layout,
/// where the pixel size of the content area is not known until the enclosing
/// view has been measured. `Double` rather than `CGFloat` so this target keeps
/// its zero imports; Swift converts between the two implicitly at the view
/// boundary, so the choice costs the renderer nothing.
public struct UnitRect: Sendable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    /// The whole content area, which is what the root node is given.
    public static let full = UnitRect(x: 0, y: 0, w: 1, h: 1)

    /// Cuts this rect in two along `axis`, `fraction` of the way across.
    fileprivate func divide(_ axis: Axis, _ fraction: Double) -> (UnitRect, UnitRect) {
        switch axis {
        case .row:
            let cut = w * fraction
            return (
                UnitRect(x: x, y: y, w: cut, h: h),
                UnitRect(x: x + cut, y: y, w: w - cut, h: h)
            )
        case .column:
            let cut = h * fraction
            return (
                UnitRect(x: x, y: y, w: w, h: cut),
                UnitRect(x: x, y: y + cut, w: w, h: h - cut)
            )
        }
    }

    /// Whether `other` lies on the `direction` side of this rect.
    fileprivate func lies(_ other: UnitRect, _ direction: Direction) -> Bool {
        switch direction {
        case .left: other.x + other.w <= x + slack
        case .right: other.x + slack >= x + w
        case .up: other.y + other.h <= y + slack
        case .down: other.y + slack >= y + h
        }
    }

    /// The clear space between this rect's `direction` edge and `other`'s near
    /// edge. Zero when they are touching.
    fileprivate func gap(_ other: UnitRect, _ direction: Direction) -> Double {
        let gap: Double = switch direction {
        case .left: x - (other.x + other.w)
        case .right: other.x - (x + w)
        case .up: y - (other.y + other.h)
        case .down: other.y - (y + h)
        }
        return max(gap, 0)
    }

    /// How much edge the two rects share across `direction`. Zero means they sit
    /// diagonally from each other rather than side by side.
    fileprivate func sharedEdge(_ other: UnitRect, _ direction: Direction) -> Double {
        let near: (Double, Double)
        let far: (Double, Double)
        switch direction.axis {
        case .row:
            near = (y, y + h)
            far = (other.y, other.y + other.h)
        case .column:
            near = (x, x + w)
            far = (other.x, other.x + other.w)
        }
        return max(min(near.1, far.1) - max(near.0, far.0), 0)
    }
}

/// The divider between a split's two children.
public struct Divider: Sendable, Equatable {
    public var split: SplitID
    public var axis: Axis
    /// The region this split divides. A drag needs it to read a pixel delta as a
    /// fraction of the right area rather than of the whole tab.
    public var area: UnitRect
    /// The line itself: zero-thickness in unit space, running the full extent of
    /// `area`. The renderer gives the grab strip its thickness in points, which
    /// a unit fraction cannot express.
    public var line: UnitRect
}

/// The tree itself.
///
/// An `indirect enum` rather than a class graph, so `Split` stays a value type
/// (plan §5) — which is what would make undo, or persisting a layout, fall out
/// later rather than needing to be built.
private indirect enum Node {
    case leaf(PaneID)
    case split(id: SplitID, axis: Axis, fraction: Double, first: Node, second: Node)
}

public struct Split: Sendable {
    /// `nil` once the last pane has closed, which is the signal to close the
    /// tab along with it.
    private var root: Node?
    private var nextID: SplitID

    /// A tab starts as a single pane filling the content area.
    public init(_ first: PaneID) {
        root = .leaf(first)
        nextID = 0
    }

    /// Where each pane sits, as fractions of the content area. The single
    /// source of truth for the layout: the dividers, the keyboard's focus
    /// movement and the renderer all read the tab's shape from here.
    public func rects() -> [(PaneID, UnitRect)] {
        var out: [(PaneID, UnitRect)] = []
        if let root { collectRects(root, .full, into: &out) }
        return out
    }

    /// Every divider, so the renderer can lay a grab strip over each one.
    public func dividers() -> [Divider] {
        var out: [Divider] = []
        if let root { collectDividers(root, .full, into: &out) }
        return out
    }

    /// Puts `newPane` beside `target`, splitting the space they now share.
    /// Returns false if `target` is not in this tab.
    @discardableResult
    public mutating func split(
        _ target: PaneID, _ axis: Axis, _ newPane: PaneID, _ placement: Placement = .after
    ) -> Bool {
        let id = nextID
        guard var node = root else { return false }
        guard splitLeaf(
            &node, target: target, split: id, axis: axis, newPane: newPane,
            placement: placement)
        else {
            return false
        }
        root = node
        nextID += 1
        return true
    }

    /// Removes `target` and gives its space back to its sibling. Returns the
    /// pane that should take focus, or `nil` if that was the last pane — at
    /// which point the tab has nothing left to show and should close too.
    @discardableResult
    public mutating func close(_ target: PaneID) -> PaneID? {
        guard var node = root else { return nil }

        if case .leaf(let pane) = node, pane == target {
            root = nil
            return nil
        }

        let focus = closeLeaf(&node, target: target)
        root = node
        return focus
    }

    /// The pane next to `from` in `direction`, or `nil` at the edge of the tab.
    ///
    /// Worked out from the laid-out rectangles rather than by walking the tree,
    /// because "the pane to my left" is a question about the screen: a few
    /// nested splits in, the tree sibling and the visual neighbour stop being
    /// the same pane. Nearest wins, and ties go to the longest shared edge.
    public func neighbour(_ from: PaneID, _ direction: Direction) -> PaneID? {
        let rects = rects()
        guard let origin = rects.first(where: { $0.0 == from })?.1 else { return nil }

        var best: (pane: PaneID, gap: Double, edge: Double)?
        for (pane, rect) in rects {
            guard pane != from,
                  origin.lies(rect, direction),
                  origin.sharedEdge(rect, direction) > slack
            else { continue }

            let candidate = (pane: pane, gap: origin.gap(rect, direction), edge: origin.sharedEdge(rect, direction))
            guard let current = best else {
                best = candidate
                continue
            }
            // Strictly better only, so an exact tie keeps the earlier pane and
            // the answer does not depend on the order the tree was walked in.
            if candidate.gap < current.gap || (candidate.gap == current.gap && candidate.edge > current.edge) {
                best = candidate
            }
        }
        return best?.pane
    }

    public func fraction(of split: SplitID) -> Double? {
        guard let root else { return nil }
        return findFraction(root, split)
    }

    public mutating func setFraction(_ split: SplitID, _ fraction: Double) {
        guard var node = root else { return }
        applyFraction(&node, split, fraction)
        root = node
    }
}

// MARK: - Walking the tree

private func collectRects(_ node: Node, _ area: UnitRect, into out: inout [(PaneID, UnitRect)]) {
    switch node {
    case .leaf(let pane):
        out.append((pane, area))
    case .split(_, let axis, let fraction, let first, let second):
        let (near, far) = area.divide(axis, fraction)
        collectRects(first, near, into: &out)
        collectRects(second, far, into: &out)
    }
}

private func collectDividers(_ node: Node, _ area: UnitRect, into out: inout [Divider]) {
    guard case .split(let id, let axis, let fraction, let first, let second) = node else { return }

    let (near, far) = area.divide(axis, fraction)
    let line: UnitRect = switch axis {
    case .row: UnitRect(x: far.x, y: area.y, w: 0, h: area.h)
    case .column: UnitRect(x: area.x, y: far.y, w: area.w, h: 0)
    }
    out.append(Divider(split: id, axis: axis, area: area, line: line))

    collectDividers(first, near, into: &out)
    collectDividers(second, far, into: &out)
}

/// Swaps the leaf holding `target` for a split of it and `newPane`.
private func splitLeaf(
    _ node: inout Node,
    target: PaneID,
    split: SplitID,
    axis: Axis,
    newPane: PaneID,
    placement: Placement
) -> Bool {
    switch node {
    case .leaf(let pane) where pane == target:
        // The only thing `placement` changes: which of the two children the
        // newcomer is. `fraction` stays 0.5, so the target keeps half its
        // space either way and nothing about the geometry depends on order.
        node = .split(
            id: split,
            axis: axis,
            fraction: 0.5,
            first: .leaf(placement == .before ? newPane : target),
            second: .leaf(placement == .before ? target : newPane)
        )
        return true

    case .leaf:
        return false

    case .split(let id, let splitAxis, let fraction, var first, var second):
        if splitLeaf(&first, target: target, split: split, axis: axis, newPane: newPane,
                     placement: placement) {
            node = .split(id: id, axis: splitAxis, fraction: fraction, first: first, second: second)
            return true
        }
        if splitLeaf(&second, target: target, split: split, axis: axis, newPane: newPane,
                     placement: placement) {
            node = .split(id: id, axis: splitAxis, fraction: fraction, first: first, second: second)
            return true
        }
        return false
    }
}

/// Collapses the split holding `target` into its other child, returning the
/// first pane of that survivor so focus has somewhere to land.
private func closeLeaf(_ node: inout Node, target: PaneID) -> PaneID? {
    guard case .split(let id, let axis, let fraction, var first, var second) = node else {
        return nil
    }

    let survivor: Node?
    if case .leaf(let pane) = first, pane == target {
        survivor = second
    } else if case .leaf(let pane) = second, pane == target {
        survivor = first
    } else {
        survivor = nil
    }

    guard let kept = survivor else {
        // Not a child of this split, so keep looking underneath it.
        if let focus = closeLeaf(&first, target: target) {
            node = .split(id: id, axis: axis, fraction: fraction, first: first, second: second)
            return focus
        }
        if let focus = closeLeaf(&second, target: target) {
            node = .split(id: id, axis: axis, fraction: fraction, first: first, second: second)
            return focus
        }
        return nil
    }

    // The survivor takes the whole split's place, so the freed space closes up
    // rather than leaving a gap where the pane used to be.
    node = kept
    return firstLeaf(kept)
}

private func firstLeaf(_ node: Node) -> PaneID {
    switch node {
    case .leaf(let pane): pane
    case .split(_, _, _, let first, _): firstLeaf(first)
    }
}

private func findFraction(_ node: Node, _ split: SplitID) -> Double? {
    guard case .split(let id, _, let fraction, let first, let second) = node else { return nil }
    if id == split { return fraction }
    return findFraction(first, split) ?? findFraction(second, split)
}

private func applyFraction(_ node: inout Node, _ split: SplitID, _ to: Double) {
    guard case .split(let id, let axis, let fraction, var first, var second) = node else { return }

    if id == split {
        node = .split(id: id, axis: axis, fraction: to, first: first, second: second)
        return
    }
    applyFraction(&first, split, to)
    applyFraction(&second, split, to)
    node = .split(id: id, axis: axis, fraction: fraction, first: first, second: second)
}

// MARK: - Divider drags

/// Keeps a dragged divider from pushing either pane below its minimum.
///
/// `parentPx` is the pixel size of the area being divided and `minPx` the
/// smallest either side may become. An area too small to hold two minimums pins
/// to the middle, rather than returning a fraction outside 0 to 1 and inverting
/// the panes.
public func clampedFraction(_ raw: Double, parentPx: Double, minPx: Double) -> Double {
    if parentPx <= minPx * 2 { return 0.5 }
    let min = minPx / parentPx
    return Swift.min(Swift.max(raw, min), 1 - min)
}
