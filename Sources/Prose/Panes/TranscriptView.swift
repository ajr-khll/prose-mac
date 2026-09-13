//  Drawing a transcript: spec §9.1 to §9.3.
//
//  The blocks themselves are decided in ProseCore by a reducer that is total
//  over every event a half-written agent can send. Nothing here decides what
//  belongs in a transcript; it only draws what the fold produced.

import ProseCore
import SwiftUI

struct TranscriptView: View {
    let session: AgentSession

    @Environment(\.metrics) private var m
    @State private var position = ScrollPosition()

    var body: some View {
        Group {
            if session.transcript.isEmpty {
                Text(PaneKind.agent.placeholder)
                    .font(m.font(.textSize))
                    .foregroundStyle(Color(Palette.panePlaceholder))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                blocks
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var blocks: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: m.px(.blockGap)) {
                ForEach(Array(session.transcript.blocks.enumerated()), id: \.offset) { index, block in
                    BlockView(block: block, index: index, session: session)
                        // plan §6.6: selection and Cmd+C inside each block.
                        // Dragging *across* blocks does not join up; that would
                        // be an NSTextView-backed transcript, which is a much
                        // bigger commitment. spec §13.3's open item, closed as
                        // far as it goes.
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(m.px(.transcriptPadding))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($position)
        // spec §9.1: the transcript follows the newest block by default, and
        // any scroll clears follow — any scroll is the user saying they want to
        // read something other than the bottom, and streaming must not yank the
        // view away. `.animating` is prose's own scroll and does not count.
        .onScrollPhaseChange { _, phase in
            switch phase {
            case .tracking, .interacting, .decelerating: session.follow = false
            case .idle, .animating: break
            @unknown default: break
            }
        }
        .onChange(of: session.revision) {
            guard session.follow else { return }
            withAnimation { position.scrollTo(edge: .bottom) }
        }
        .onAppear { position.scrollTo(edge: .bottom) }
    }
}

/// One drawable thing (spec §9.3).
private struct BlockView: View {
    let block: Block
    /// The block's address. Collapse lives in the block rather than in this
    /// view's `@State`, because the list above is keyed on array offset and
    /// anything appended would shift a view's state onto its neighbour.
    let index: Int
    let session: AgentSession

    @Environment(\.metrics) private var m

    var body: some View {
        switch block {
        case .message(_, let role, let text, _):
            message(role: role, text: text)

        case .thinking(_, let text, let streaming, let collapsed):
            thinking(text: text, streaming: streaming, collapsed: collapsed)

        case .activity(_, let label, let detail, let state, let category):
            activity(label: label, detail: detail, state: state, category: category)

        case .attachment(let attachment):
            self.attachment(attachment)

        case .notice(let message):
            Text(message)
                .font(m.font(.secondaryTextSize))
                .foregroundStyle(Color(Palette.noticeText))

        // The placeholder is the composer's to draw (spec §9.4), not the card's.
        case .ask(_, let prompt, let choices, _, let answer, let supervisor):
            AskCard(
                prompt: prompt, choices: choices, answer: answer, supervisor: supervisor,
                session: session)
        }
    }

    /// The user's messages are set apart by a card, not by a colour, so a long
    /// prompt stays as readable as the reply to it. The agent's are plain prose.
    ///
    /// **Structure is still not parsed** (spec §9.3): a heading, a bullet or a
    /// fence is the characters the agent typed, and code arrives as its own
    /// attachment event with its own type. Only *inline* emphasis is drawn —
    /// see `Markdown.inline` for why that is not the same concession.
    @ViewBuilder
    private func message(role: Role, text: String) -> some View {
        switch role {
        case .user:
            prose(text)
                .padding(.horizontal, m.px(.bubblePaddingX))
                .padding(.vertical, m.px(.bubblePaddingY))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: m.px(.bubbleRadius))
                        .fill(Color(Palette.userBubbleBG))
                )
        // A thinking role never reaches a message block — the fold gives it one
        // of its own — so this is the degraded path, and prose is the right
        // thing to fall back to: better to read the reasoning as text than to
        // lose it (spec §10).
        case .agent, .thinking:
            prose(text)
        }
    }

    private func prose(_ text: String) -> some View {
        ProseText(text: text)
            .lineSpacing(m.px(.textSize) * (Metrics.lineHeight - 1))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A baseline-aligned row: a 5pt dot that is the only thing saying whether
    /// the step is still going, finished or broken, then the label, then an
    /// optional detail.
    private func activity(
        label: String, detail: String?, state: ActivityState, category: String?
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: m.px(.activityGap)) {
            // A skill gets a ring rather than a disc. It is the same 5pt mark in
            // the same place and the same colour — state is still the only thing
            // the mark's *colour* says (spec §9.3) — so nothing new competes
            // with the one accent, and a category prose has never heard of
            // falls back to the disc every other step draws.
            Circle()
                .strokeBorder(
                    Color(dotColour(state)),
                    lineWidth: category == "skill" ? m.px(.activityRing) : m.px(.activityDot))
                .frame(width: m.px(.activityDot), height: m.px(.activityDot))
                // A circle has no baseline of its own, so it is nudged onto the
                // text's rather than centred on the line box.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] }

            Text(label)
                .foregroundStyle(Color(Palette.activityLabel))

            if let detail {
                Text(detail)
                    .foregroundStyle(Color(Palette.activityDetail))
            }
        }
        .font(m.font(.secondaryTextSize))
    }

    /// Reasoning: shown while it is the only thing happening, folded to a line
    /// once there is an answer above it.
    ///
    /// Dimmer than prose and one indent in, because it is the agent working
    /// rather than the agent talking — and it stays *readable*, not hidden:
    /// what an agent thought is the most useful thing in a pane when the answer
    /// is wrong.
    private func thinking(text: String, streaming: Bool, collapsed: Bool) -> some View {
        VStack(alignment: .leading, spacing: m.px(.activityGap)) {
            Button {
                session.toggleThinking(at: index)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: m.px(.activityGap)) {
                    Text(collapsed ? "\u{203A}" : "\u{2039}")
                        .font(m.font(.secondaryTextSize))
                    Text(streaming ? "Thinking" : "Thought")
                        .font(m.font(.secondaryTextSize))
                }
                .foregroundStyle(Color(Palette.thinkingLabel))
            }
            .buttonStyle(.plain)
            // A turn in flight is the one time reasoning is the most
            // interesting thing on screen, so it opens itself and needs no
            // pointer to say it can be closed again.
            .pointerStyle(.link)

            if !collapsed, !text.isEmpty {
                ProseText(
                    text: text, size: .secondaryTextSize, colour: Palette.thinkingText
                )
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, m.px(.thinkingIndent))
            }
        }
    }

    private func dotColour(_ state: ActivityState) -> RGBA {
        switch state {
        case .running: Palette.activityRunning
        case .ok: Palette.activityOK
        case .error: Palette.activityError
        }
    }

    /// Code gets a monospaced block. **Any other type, including one this build
    /// has never heard of, renders as plain prose rather than vanishing** — the
    /// same forgiveness the parser applies.
    @ViewBuilder
    private func attachment(_ attachment: Attachment) -> some View {
        if attachment.kind == "code" {
            Text(attachment.text)
                .font(.system(size: m.px(.codeTextSize), design: .monospaced))
                .foregroundStyle(Color(Palette.codeText))
                .fixedSize(horizontal: false, vertical: true)
                .padding(m.px(.codePadding))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: m.px(.codeRadius))
                        .fill(Color(Palette.codeBG))
                        .overlay(
                            RoundedRectangle(cornerRadius: m.px(.codeRadius))
                                .strokeBorder(Color(Palette.codeBorder), lineWidth: m.px(.hairline))
                        )
                )
        } else {
            prose(attachment.text)
        }
    }
}

/// The card the agent stops the conversation with.
private struct AskCard: View {
    let prompt: String
    let choices: [String]
    let answer: String?
    /// Set while a parent pane is deciding this — see `Block.ask`.
    let supervisor: PaneID?
    let session: AgentSession

    @Environment(\.metrics) private var m

    var body: some View {
        VStack(alignment: .leading, spacing: m.px(.askPadding)) {
            ProseText(text: prompt)
                .fixedSize(horizontal: false, vertical: true)

            // Choices and a typed answer are not exclusive (spec §9.5): a
            // question may offer buttons, a free-text answer, or both. The
            // composer always does the typing half — it draws the placeholder
            // and Enter answers there — so the card's whole job is the buttons
            // and the record of what was chosen.
            if !choices.isEmpty {
                WrappingRow(spacing: m.px(.activityGap)) {
                    ForEach(choices, id: \.self) { choice in
                        ChoiceButton(
                            label: choice,
                            chosen: answer == choice,
                            // Once answered, **all buttons remain visible** so
                            // the choice stays legible, and none of them hover
                            // or take a click any more. A question a parent is
                            // still deciding reads the same way: visible, so
                            // the user can see what is being decided, and not
                            // theirs to click yet.
                            resolved: answer != nil || supervisor != nil
                        ) {
                            session.answer(choice)
                        }
                    }
                }
            }

            if answer == nil, let supervisor {
                Text("pane \(supervisor) is answering")
                    .font(m.font(.secondaryTextSize))
                    .foregroundStyle(Color(Palette.panePlaceholder))
            }

            // A typed answer has no button to light up, so the card has to say
            // it. One that matches a choice does not, or it would be shown
            // twice — once lit and once again underneath.
            if let answer, !choices.contains(answer) {
                Text(answer)
                    .font(m.font(.secondaryTextSize))
                    .foregroundStyle(Color(Palette.activityDetail))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(m.px(.askPadding))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: m.px(.askRadius))
                .fill(Color(Palette.askBG))
                .overlay(
                    RoundedRectangle(cornerRadius: m.px(.askRadius))
                        .strokeBorder(Color(Palette.askBorder), lineWidth: m.px(.hairline))
                )
        )
    }
}

private struct ChoiceButton: View {
    let label: String
    let chosen: Bool
    let resolved: Bool
    let action: () -> Void

    @Environment(\.metrics) private var m
    @State private var hovering = false

    private var wash: RGBA {
        if chosen { return Palette.choiceChosenBG }
        if hovering && !resolved { return Palette.choiceHoverBG }
        return Palette.choiceBG
    }

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(m.font(.secondaryTextSize))
                .foregroundStyle(Color(Palette.text))
                .padding(.horizontal, m.px(.choicePaddingX))
                .frame(height: m.px(.choiceHeight))
                .background(
                    RoundedRectangle(cornerRadius: m.px(.choiceRadius)).fill(Color(wash))
                )
        }
        .buttonStyle(.plain)
        .disabled(resolved)
        .onHover { hovering = $0 }
    }
}

/// A row of buttons that wraps.
///
/// spec §9.3 asks for "a wrapping row of buttons, 7pt gaps"; SwiftUI's stacks
/// do not wrap, so this is the one place the port writes a `Layout`. It is the
/// whole of it: measure each button, break when the next one would not fit.
private struct WrappingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = wrap(subviews, into: width)
        let height = rows.reduce(0.0) { $0 + $1.height } + spacing * Double(max(0, rows.count - 1))
        return CGSize(width: width == .infinity ? rows.map(\.width).max() ?? 0 : width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in wrap(subviews, into: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func wrap(_ subviews: Subviews, into width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if next > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
