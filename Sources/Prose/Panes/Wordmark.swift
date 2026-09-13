//  The `prose` wordmark: heavy serif italic, leaning, filled with a halftone.
//
//  `prose-ui-demo` draws it with `background-clip: text` over a repeating
//  radial-gradient, in three layers whose offsets give it the smeared,
//  misregistered look of something printed badly on purpose. SwiftUI has no
//  `background-clip: text`, but it has `.mask`, which is the same idea from the
//  other side: draw the dots, then let the letterforms decide which of them
//  survive.

import ProseCore
import SwiftUI

/// The logo, at whatever size it is handed.
///
/// It takes a size rather than choosing one because a pane can be 160pt wide
/// (`Points.paneMinWidth`) and the nominal size is 76 — which sets about 200pt
/// of text. The caller measures; this draws. See `AgentPaneBody.welcome`.
struct Wordmark: View {
    let size: CGFloat

    @Environment(\.metrics) private var m

    /// The three layers, back to front, as `opacity` / `offset` / dot pitch.
    ///
    /// The middle one is the wordmark proper and sits at full strength; the
    /// other two are the same letterforms nudged off it. The demo's back layer
    /// uses a slightly *coarser* grid (5px against 4px) as well as a lower
    /// opacity, which is what stops the two from moiring into a third pattern
    /// where they overlap.
    private var layers: [(opacity: Double, offset: CGSize, pitch: CGFloat)] {
        let behind = m.px(.wordmarkBehindOffset)
        let front = m.px(.wordmarkFrontOffset)
        let pitch = m.px(.wordmarkDotPitch)

        return [
            (0.32, CGSize(width: -behind, height: behind), pitch * 1.25),
            (1.00, .zero, pitch),
            (0.58, CGSize(width: front, height: -front * 0.6), pitch),
        ]
    }

    var body: some View {
        ZStack {
            ForEach(Array(layers.enumerated()), id: \.offset) { _, layer in
                halftone(pitch: layer.pitch)
                    .mask(letters)
                    .opacity(layer.opacity)
                    .offset(layer.offset)
            }
        }
        // The lean. Applied to the group rather than to each layer, so the three
        // stay in register with each other while the whole thing leans.
        .transformEffect(skew)
        // `transformEffect` does not enlarge the frame it reports, so the lean
        // and the two offsets would be clipped by whatever lays this out. The
        // padding is the room they need, not decoration.
        .padding(.horizontal, size * 0.14)
        .fixedSize()
        .accessibilityLabel("prose")
    }

    /// A `skewX(-6deg)`, which is a shear in x proportional to y.
    ///
    /// Negative degrees lean the top to the *right*, because the view's y runs
    /// downward — the same sign convention CSS uses, arrived at the same way.
    private var skew: CGAffineTransform {
        let radians = Points.wordmarkSkewDegrees * .pi / 180
        return CGAffineTransform(a: 1, b: 0, c: CGFloat(tan(radians)), d: 1, tx: 0, ty: 0)
    }

    /// The letterforms themselves, used only as a mask — their colour never
    /// shows, so it is whatever is opaque.
    ///
    /// A serif face, in a window that is otherwise set in the system sans. That
    /// is the point of a wordmark: it is the one place that is allowed to not
    /// match, and the demo picks Georgia for it.
    private var letters: some View {
        Text("prose")
            .font(.custom("Georgia", fixedSize: size).weight(.black).italic())
            // The demo pulls the letters far enough together that they touch and
            // the halftone runs between them, which is most of the effect.
            .tracking(-size * 0.06)
            .foregroundStyle(.black)
    }

    /// The dot grid, drawn across whatever area the mask will cut it down to.
    ///
    /// Drawn rather than tiled from an image so the dots stay round at every
    /// zoom rung; at 76pt there are only a few hundred of them, and this is the
    /// empty state, so it is drawn once and not during a stream.
    private func halftone(pitch: CGFloat) -> some View {
        Canvas { context, canvasSize in
            let radius = m.px(.wordmarkDotRadius)
            let colour = GraphicsContext.Shading.color(Color(Palette.wordmark))

            for y in stride(from: 0.0, to: canvasSize.height, by: pitch) {
                for x in stride(from: 0.0, to: canvasSize.width, by: pitch) {
                    let dot = CGRect(
                        x: x - radius, y: y - radius, width: radius * 2, height: radius * 2
                    )
                    context.fill(Path(ellipseIn: dot), with: colour)
                }
            }
        }
        // The canvas has no size of its own — it is a fill, and the mask is what
        // gives it a shape — so it is sized to the letters it will be cut to.
        .frame(width: size * 3.2, height: size * 1.1)
    }
}
