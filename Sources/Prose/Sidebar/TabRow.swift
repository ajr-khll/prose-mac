//  One entry in the vertical tab strip: the console chip, the title, the close
//  button — and, while it is being renamed, a field in place of the title.

import ProseCore
import SwiftUI

struct TabRow: View {
    let tab: Tab
    /// How near the sliding selection highlight is to this row, 1 on it and 0 a
    /// row or more away. The highlight itself is drawn by the list, behind the
    /// whole strip; a row only tints its own accents by how close the green has
    /// got, so the colour arrives with the box instead of after it.
    let nearness: Double

    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m
    @State private var hovering = false

    private var renaming: Bool { workspace.rename?.tab == tab.id }

    var body: some View {
        HStack(spacing: m.px(.tabGap)) {
            consoleChip

            if renaming {
                RenameField(tab: tab.id)
            } else {
                title
            }

            closeButton
        }
        // The border is inside the row's own box, so the row occupies exactly
        // the same rectangle as the highlight that slides over it and nothing
        // shifts by a pixel when one arrives.
        .padding(.horizontal, m.px(.rowPaddingX + .rowBorder))
        .frame(height: m.px(.rowHeight))
        .background(
            RoundedRectangle(cornerRadius: m.px(.rowRadius))
                .fill(Color(hoverWash))
        )
        .contentShape(RoundedRectangle(cornerRadius: m.px(.rowRadius)))
        .onHover { hovering = $0 }
        .onTapGesture { workspace.select(tab.id) }
    }

    /// Hovering a row the highlight has nearly reached would only muddy the
    /// green, so the hover wash gives way once the two are close.
    private var hoverWash: RGBA {
        hovering && nearness < 0.5 ? Palette.tabHoverBG : .transparent
    }

    /// The rounded square with the `>` glyph, borrowed from the reference's
    /// terminal-prompt motif. Both its colours are blended by `nearness` so they
    /// travel with the highlight.
    ///
    /// `nearness` arrives already at its destination — it is computed from the
    /// model, which changes the instant a tab is selected — so the colours are
    /// given the highlight's own curve and duration to get there. The two start
    /// together and take the same time, which is what keeps the green with the
    /// box instead of letting it land first.
    ///
    /// plan §7's option 2 is to interpolate the offset itself and rebuild the
    /// strip from it every frame, which tracks the box exactly, including over
    /// rows a long jump crosses. It was tried here: rebuilding every row *and
    /// the glass behind them* sixty times a second made switching tabs visibly
    /// slow. Matching the curve costs nothing instead, because SwiftUI
    /// interpolates the colour in the render tree without running this again.
    private var consoleChip: some View {
        RoundedRectangle(cornerRadius: m.px(.chipRadius))
            .fill(Color(mix(Palette.chipBG, Palette.chipActiveBG, nearness)))
            .frame(width: m.px(.chipSize), height: m.px(.chipSize))
            .overlay {
                Image(systemName: "chevron.right")
                    .font(m.font(.chevronSize))
                    .foregroundStyle(Color(mix(Palette.chevron, Palette.chevronActive, nearness)))
            }
            .animation(.easeOut(duration: Metrics.selectionSlide.seconds), value: nearness)
    }

    /// A double click turns the title into a field. A single click on it still
    /// selects the row, so the title is not a hole in the row's own hit area.
    private var title: some View {
        Text(tab.title)
            .font(m.font(.textSize))
            .foregroundStyle(Color(Palette.text))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { workspace.beginRename(tab.id) }
            .onTapGesture { workspace.select(tab.id) }
    }

    /// Always visible, matching the reference, rather than hover-revealed. The
    /// glyph brightens on hover of the button itself, not of the row.
    private var closeButton: some View {
        CloseButton { workspace.close(tab.id) }
    }
}

private struct CloseButton: View {
    let action: () -> Void

    @Environment(\.metrics) private var m
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(m.font(.closeSize))
                .foregroundStyle(Color(hovering ? Palette.iconHover : Palette.icon))
                .frame(width: m.px(.closeBox), height: m.px(.closeBox))
                .background(
                    RoundedRectangle(cornerRadius: m.px(.smallRadius))
                        .fill(Color(hovering ? Palette.iconHoverBG : .transparent))
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// The inline rename.
///
/// spec §6.5 describes a string buffer, a caret pinned to the end and nothing
/// else — no selection, no clipboard, no IME — and calls this "the one place
/// where a Swift port gets a free upgrade". This is that upgrade: a `TextField`
/// covers all of it, and Enter, Escape and click-away are three modifiers.
private struct RenameField: View {
    let tab: Tab.ID

    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var workspace = workspace

        TextField(
            "",
            text: Binding(
                get: { workspace.rename?.buffer ?? "" },
                set: { workspace.rename?.buffer = $0 }
            )
        )
        .textFieldStyle(.plain)
        .font(m.font(.textSize))
        .foregroundStyle(Color(Palette.text))
        .focused($focused)
        .onSubmit { workspace.commitRename() }
        .onExitCommand { workspace.cancelRename() }
        .onAppear { focused = true }
        // Clicking anywhere else takes focus away, which would leave the field
        // open but deaf to the keyboard. Treat leaving as keeping.
        .onChange(of: focused) { _, focused in
            if !focused { workspace.commitRename() }
        }
        .padding(.horizontal, m.px(.renamePaddingX))
        .frame(maxWidth: .infinity)
        .frame(height: m.px(.renameHeight))
        .background(
            RoundedRectangle(cornerRadius: m.px(.smallRadius))
                .fill(Color(Palette.renameBG))
                .overlay(
                    RoundedRectangle(cornerRadius: m.px(.smallRadius))
                        .strokeBorder(Color(Palette.renameBorder), lineWidth: m.px(.hairline))
                )
        )
    }
}
