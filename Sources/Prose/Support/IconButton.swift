//  A bare icon in a square hit area that lights up on hover.
//
//  Ported from `ui.rs`. Nine vendored Lucide SVGs, `rust-embed`, an
//  `AssetSource` and the "an Svg does not inherit text_color" trap all collapse
//  into SF Symbols (plan §4), so the only thing left worth sharing is the
//  geometry and the hover wash.

import ProseCore
import SwiftUI

struct IconButton: View {
    let symbol: String
    /// How much the button grows with the UI zoom. Content buttons pass the
    /// zoom straight through; buttons in the fixed header row pass less,
    /// because that row cannot grow with them; the sidebar toggle passes 1 and
    /// does not scale at all. Sizing here is in real pixels rather than points
    /// precisely so a caller can opt out of scaling, which is the whole reason
    /// this takes a scale instead of reading the environment.
    var scale: Double = 1
    let action: () -> Void

    @State private var hovering = false

    private var size: CGFloat { Points.buttonSize.value * scale }
    private var glyph: CGFloat { Points.buttonIconSize.value * scale }
    private var radius: CGFloat { Points.buttonRadius.value * scale }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: glyph))
                .foregroundStyle(Color(hovering ? Palette.iconHover : Palette.icon))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Color(hovering ? Palette.iconHoverBG : .transparent))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension RGBA {
    /// Fully transparent. Borders and washes are permanent and only ever
    /// recolour (spec §4), so "off" has to be a colour rather than an absence.
    static let transparent = RGBA(r: 0, g: 0, b: 0, a: 0)
}
