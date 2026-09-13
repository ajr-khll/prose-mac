//  Bridging ProseCore's framework-free dimensions and colours into SwiftUI.
//
//  ProseCore imports no UI framework, which is what makes it testable without a
//  window — so the conversion has to happen somewhere, and this is the one
//  place it does. Every colour and dimension in the app still comes from
//  `Palette` and `Points`; nothing below invents a value.

import ProseCore
import SwiftUI

extension Color {
    /// A palette colour, in the sRGB space the hex values were measured in.
    init(_ rgba: RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

extension CGFloat {
    /// A fixed dimension, which the zoom never touches (spec §3).
    init(_ pixels: Pixels) { self.init(pixels.value) }
}

// MARK: - Metrics in the environment

/// The zoom rung, read by every view that needs a dimension.
///
/// plan §6.1: gpui resolved the whole tree against one rem size per window and
/// Swift has no equivalent, so the scale travels down the environment instead
/// and each view resolves its own points. The compensation is that `Points`
/// cannot be drawn without passing through `Metrics.resolve`, so a dimension
/// that forgets to scale does not compile.
private struct MetricsKey: EnvironmentKey {
    static let defaultValue = Metrics()
}

extension EnvironmentValues {
    var metrics: Metrics {
        get { self[MetricsKey.self] }
        set { self[MetricsKey.self] = newValue }
    }
}

extension Metrics {
    /// Points to the CGFloat they are drawn at.
    func px(_ points: Points) -> CGFloat { resolve(points).value }

    /// A scaled font. Text scales correctly this way and stays sharp, which is
    /// the property `.scaleEffect` would have lost (plan §6.1).
    func font(_ points: Points) -> Font { .system(size: px(points)) }
}
