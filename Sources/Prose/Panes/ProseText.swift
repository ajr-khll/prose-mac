//  Prose, with its inline emphasis drawn rather than spelled out.
//
//  `Markdown.inline` decides *what* the runs are; this decides what they look
//  like. The split is the usual one — the parse is a pure question about a
//  string and is tested without a window, while a font and a colour need the
//  zoom rung and the palette, which only exist here.
//
//  Nothing below invents a value: the emphasis styles are the base font asking
//  for its own bold and italic, and the two colours a code span uses are the
//  ones the code *attachment* already uses (spec §9.3), so there is one way for
//  code to look and not two.

import ProseCore
import SwiftUI

/// A paragraph of prose from either side of the conversation.
///
/// Replaces a bare `Text` wherever the text came from an agent or from the
/// composer — which is to say wherever markdown might be in it.
struct ProseText: View {
    let text: String
    /// The size the surrounding prose is set at. A code span inside it is
    /// derived from this rather than fixed, so an inline span in 12pt reasoning
    /// stays smaller than the reasoning, exactly as it does in 13pt prose.
    var size: Points = .textSize
    var colour: RGBA = Palette.text

    @Environment(\.metrics) private var m

    var body: some View {
        Text(styled)
            .font(m.font(size))
            .foregroundStyle(Color(colour))
    }

    /// Walks the parsed runs and turns each intent into something drawable.
    ///
    /// The ranges are collected before anything is applied: mutating an
    /// `AttributedString` while iterating its own runs is not sound, and the
    /// runs shift underneath you as attributes merge.
    private var styled: AttributedString {
        var attributed = Markdown.inline(text)
        var edits: [(Range<AttributedString.Index>, AttributeContainer)] = []

        for run in attributed.runs {
            let intent = run.inlinePresentationIntent ?? []
            var container = AttributeContainer()

            // Emphasis is the base font asking for a variant, so it follows the
            // zoom and the surrounding size without being told either.
            var font = m.font(size)
            if intent.contains(.stronglyEmphasized) { font = font.bold() }
            if intent.contains(.emphasized) { font = font.italic() }

            if intent.contains(.code) {
                // The one place a span stops taking the surrounding font: it
                // takes the attachment's monospaced face, its colour and its
                // wash instead. The wash is drawn tight to the glyphs — an
                // inline run has nowhere to put padding — so it reads as a
                // shade behind the code rather than as the block's card.
                font = .system(size: m.px(size - .codeSpanDrop), design: .monospaced)
                container.foregroundColor = Color(Palette.codeText)
                container.backgroundColor = Color(Palette.codeBG)
            }

            container.font = font
            if intent.contains(.strikethrough) { container.strikethroughStyle = .single }

            // A link is underlined and keeps the colour of the prose around it.
            // **It is not given the accent**: spec §4's first rule is that the
            // green means "this is the active one" and nothing else ever wears
            // it, and a URL in a sentence is not the active anything.
            if run.link != nil { container.underlineStyle = .single }

            edits.append((run.range, container))
        }

        for (range, container) in edits {
            attributed[range].mergeAttributes(container)
        }
        return attributed
    }
}
