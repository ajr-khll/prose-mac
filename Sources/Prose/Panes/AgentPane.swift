//  An agent pane: a scrolling transcript that takes the remaining height, and a
//  composer pinned below it.
//
//  The transcript itself is step 1's — `ProseCore.Transcript`, a total reducer
//  over protocol events with thirteen tests and no window. What is here is the
//  part that has to know about a pane: follow-the-bottom, sending, and drawing.

import Observation
import ProseCore
import SwiftUI

/// One pane's conversation.
///
/// From step 6 this is what a session's incoming lines are folded into and what
/// the composer's outgoing ones leave from. Until then it is driven by the user
/// and by `PROSE_TRANSCRIPT`.
@MainActor
@Observable
final class AgentSession {
    let pane: PaneID
    private(set) var transcript = Transcript()

    /// Bumped on every change to the transcript, including a delta that leaves
    /// the block count alone. Follow-the-bottom watches this rather than the
    /// blocks themselves: a streaming message grows without the list changing
    /// length, and the view still has to chase it.
    private(set) var revision = 0

    /// spec §9.1: the transcript follows the newest block by default. Any
    /// scroll is the user saying they want to read something other than the
    /// bottom, and streaming must not yank the view away.
    var follow = true

    /// The composer's own state, reported back out of AppKit so SwiftUI can
    /// draw the placeholder, the focus ring and the box's height.
    var composerIsEmpty = true
    var composerFocused = false
    var composerHeight: CGFloat = 0

    /// Set when the caret should move into the composer and there was no view
    /// to move it into — a pane that has just been split into existence is
    /// asked for the keyboard before its composer exists. Consumed when that
    /// composer arrives in a window, and nowhere else.
    ///
    /// Every other route goes through `focusComposer` instead, because state
    /// alone does not arrive: see the note where it is installed.
    var wantsComposerFocus = false

    /// Puts the caret in this pane's composer, and says whether it could.
    ///
    /// Installed by the composer itself while it exists. `false` means there is
    /// no view in a window to take the keyboard, which is what `wantsComposerFocus`
    /// is then for.
    @ObservationIgnored var focusComposer: (() -> Bool)?

    /// Sends whatever is in this pane's composer, as Enter would, and puts text
    /// into it, as typing would.
    ///
    /// Both installed by the composer alongside `focusComposer`, and for the
    /// same reason: the text lives in an `NSTextView`, so the `send \u{21B5}`
    /// button and the suggestion under the welcome screen have no other way to
    /// reach it. Nil when there is no composer in a window.
    @ObservationIgnored var submitComposer: (() -> Void)?
    @ObservationIgnored var setComposerText: ((String) -> Void)?

    /// The composer took first responder directly, usually because it was
    /// clicked. An AppKit text view consumes that click before `PaneView`'s
    /// SwiftUI tap gesture sees it, so this is what keeps the pane and keyboard
    /// ownership in step with the control that actually has the caret.
    @ObservationIgnored var onFocus: (() -> Void)?

    /// Escape with no turn running hands the keyboard back to the tab strip.
    @ObservationIgnored var onResignToTabStrip: (() -> Void)?

    /// Which session draws here, once one has been reserved.
    @ObservationIgnored var session: SessionID?

    /// Where an `Outgoing` goes. Nil until the host wires it up, which is also
    /// the state the app runs in when the socket could not be opened.
    @ObservationIgnored var onOutgoing: ((Outgoing) -> Void)?

    /// Everything prose has put on the wire, kept for the tests — the host is
    /// the thing that actually sends.
    private(set) var outbox: [Outgoing] = []

    private func put(_ outgoing: Outgoing) {
        outbox.append(outgoing)
        onOutgoing?(outgoing)
    }

    init(pane: PaneID) {
        self.pane = pane
    }

    // MARK: - spec §9.5, sending

    /// Enter. An empty composer sends nothing.
    ///
    /// If a question with **no choices** is outstanding, this answers that
    /// question instead of starting a new turn — the reply resolves the agent's
    /// pending request rather than arriving as a fresh message.
    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isAnsweringByTyping, let id = transcript.answerAsk(trimmed) {
            put(.reply(id: id, result: .object(["answer": .string(trimmed)])))
        } else {
            transcript.pushUser(trimmed)
            put(.message(session: session ?? 0, text: trimmed))
        }
        // Sending re-arms follow (spec §9.1).
        follow = true
        revision += 1
    }

    /// Whether the composer is doing double duty for an outstanding question
    /// (spec §9.5).
    ///
    /// **Any** outstanding ask claims Enter, including one that also offers
    /// buttons. Choices and a typed answer are two ways of answering the same
    /// question, not two kinds of question: an agent that offers three options
    /// and a way to say something else should not have to choose between
    /// drawing the buttons and being answerable in words. Whichever arrives
    /// first resolves the card — `answerAsk` only ever finds an *unanswered*
    /// one, so a click and a keystroke racing cannot both land.
    var isAnsweringByTyping: Bool {
        transcript.pendingAsk != nil && supervisedAsk == nil
    }

    /// What the composer offers to do, which is a different question while a
    /// question is outstanding.
    ///
    /// Lives here rather than in the view because the text view draws its own
    /// placeholder (see `ComposerTextView.draw(_:)`), so it has to arrive as a
    /// value the composer is handed rather than something overlaid on it.
    var composerPlaceholder: String {
        guard isAnsweringByTyping,
              case .ask(_, _, _, let placeholder, _, _)? = transcript.pendingAsk
        else { return "Ask anything…" }
        return placeholder ?? "Answer…"
    }

    /// A click on one of an ask card's buttons.
    func answer(_ choice: String) {
        guard let id = transcript.answerAsk(choice) else { return }
        put(.reply(id: id, result: .object(["answer": .string(choice)])))
        follow = true
        revision += 1
    }

    /// Escape. Returns whether there was a turn to interrupt; if not, the
    /// caller hands the keyboard back to the tab strip.
    @discardableResult
    func interrupt() -> Bool {
        guard transcript.isRunning else { return false }
        put(.interrupt(session: session ?? 0))
        return true
    }

    // MARK: - Incoming

    /// An event from the agent. Does **not** re-arm follow: a stream must not
    /// yank the view away from someone reading further up.
    func apply(_ event: Event) {
        transcript.apply(event)
        revision += 1
    }

    /// The agent stopped to ask something. Re-arms follow and, from step 5's
    /// §9.2, bypasses repaint coalescing — both because this is the agent
    /// asking the user to do something.
    func ask(
        id: RequestID, prompt: String, choices: [String], placeholder: String?,
        supervisor: PaneID? = nil
    ) {
        transcript.pushAsk(
            id: id, prompt: prompt, choices: choices, placeholder: placeholder,
            supervisor: supervisor)
        follow = true
        revision += 1
    }

    /// Hands a supervised question back to the user, because the pane that was
    /// deciding it declined or ran out of time. Answers whether there was one.
    @discardableResult
    func escalateAsk() -> Bool {
        guard transcript.escalateAsk() else { return false }
        follow = true
        revision += 1
        return true
    }

    /// The pane deciding the outstanding question, when it is not the user's to
    /// decide yet. Drives both the card and whether Enter is claimed.
    var supervisedAsk: PaneID? {
        guard case .ask(_, _, _, _, let answer, let supervisor)? = transcript.pendingAsk,
              answer == nil
        else { return nil }
        return supervisor
    }

    /// A failed turn, or the agent's process going away. Re-arms follow for the
    /// same reason.
    /// Whether the agent's process has gone away.
    ///
    /// Kept apart from the notice it also writes, because a notice is also what
    /// a failed turn leaves behind — and a parent waiting on `exit` means the
    /// process, not a bad turn.
    private(set) var exited = false

    /// Opens or closes a thinking block. Addressed by index, which is what the
    /// transcript view has and what the block has no id-free alternative to.
    func toggleThinking(at index: Int) {
        transcript.toggleThinking(at: index)
        revision += 1
    }

    func markExited() {
        exited = true
    }

    func notice(_ message: String) {
        transcript.pushNotice(message)
        follow = true
        revision += 1
    }
}

/// The pane body.
///
/// Two states, and they are the same layout rather than two: **before the
/// transcript has anything in it the composer sits in the middle of the pane
/// under the wordmark, and afterwards it is pinned under a transcript.** What
/// changes between them is what is above the composer and how much space is
/// below it — the composer itself is one view in both, never rebuilt.
///
/// That is load-bearing, not tidiness. The text is owned by an `NSTextView`
/// inside a representable; if the two states held two composers, SwiftUI would
/// tear one down and build the other on the first message, and the caret would
/// be left behind at exactly the moment the user is mid-conversation.
struct AgentPaneBody: View {
    let session: AgentSession

    @Environment(Workspace.self) private var workspace
    @Environment(\.metrics) private var m

    /// The welcome state is "nothing has been said in this pane yet", which is
    /// a property of the transcript rather than a flag of its own — so a pane
    /// that is cleared comes back here, which is right.
    ///
    /// See `Transcript.hasConversation` for why this is not `isEmpty`.
    private var isWelcome: Bool { !session.transcript.hasConversation }

    var body: some View {
        VStack(spacing: 0) {
            if isWelcome {
                Spacer(minLength: 0)
                welcome
            } else {
                TranscriptView(session: session)
            }

            composer

            if isWelcome {
                // Unequal to the spacer above, so the column sits above the
                // pane's centre. See `Points.welcomeLift`.
                Spacer(minLength: 0)
                Color.clear.frame(height: m.px(.welcomeLift))
            }
        }
        // The welcome column is the width of the composer, so both are clamped
        // by the same frame rather than each choosing for itself.
        .frame(maxWidth: m.px(.welcomeWidth))
        .frame(maxWidth: .infinity)
        .animation(.easeOut(duration: 0.18), value: isWelcome)
        .onAppear {
            session.onResignToTabStrip = { workspace.resignToTabStrip() }
        }
    }

    // MARK: - The welcome state

    /// The wordmark and the line under it.
    ///
    /// The wordmark is centred over the column while the greeting is flush with
    /// the composer's leading edge — the demo's arrangement, and it works
    /// because the logo is an object and the greeting is the start of a
    /// sentence the composer finishes.
    private var welcome: some View {
        VStack(alignment: .leading, spacing: 0) {
            // `GeometryReader` rather than a fixed size: `Points.paneMinWidth`
            // is 160 and the nominal wordmark sets about 200pt wide, so in a
            // narrow pane it has to come down or it is simply clipped.
            GeometryReader { pane in
                Wordmark(size: min(m.px(.wordmarkSize), pane.size.width * 0.26))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .frame(height: m.px(.wordmarkSize) * 1.2)
            .padding(.bottom, m.px(.wordmarkGap))

            Text("What are we working on?")
                .font(m.font(.textSize))
                .foregroundStyle(Color(Palette.greeting))
                .padding(.bottom, m.px(.greetingGap))

            notices
        }
        .padding(.horizontal, m.px(.transcriptPadding))
    }

    /// Anything the pane needs to say before the conversation starts.
    ///
    /// Almost always one thing — that the agent could not be started — and it
    /// has to appear *here* rather than waiting for a transcript, because a pane
    /// with no agent behind it never gets one. Without this the welcome screen
    /// would cheerfully invite a message that has nowhere to go.
    @ViewBuilder
    private var notices: some View {
        let messages = session.transcript.blocks.compactMap { block -> String? in
            if case .notice(let message) = block { message } else { nil }
        }

        if !messages.isEmpty {
            VStack(alignment: .leading, spacing: m.px(.composerFootGap)) {
                ForEach(messages, id: \.self) { message in
                    Text(message)
                        .font(m.font(.secondaryTextSize))
                        .foregroundStyle(Color(Palette.noticeText))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.bottom, m.px(.greetingGap))
        }
    }

    /// A starting point, for a pane that has none.
    ///
    /// It fills the composer rather than sending, so the user gets to edit it —
    /// a suggestion that submitted itself would be a button pretending to be a
    /// prompt.
    private var suggestion: some View {
        HStack(spacing: m.px(.promptGlyphGap)) {
            Text("//")
                .foregroundStyle(Color(Palette.suggestionMark))

            SuggestionButton(text: "Give me a tour of this project") { text in
                session.setComposerText?(text)
                _ = session.focusComposer?()
            }
        }
        .font(m.font(.secondaryTextSize))
        .padding(.top, m.px(.suggestionGap))
    }

    // MARK: - The composer

    /// The box, the rows that belong to it, and — in the welcome state — the
    /// suggestion under them.
    ///
    /// The demo puts the model and the send affordance *inside* the box and the
    /// keyboard hints *outside* it. The split is meaningful rather than
    /// decorative: inside is what this message will be sent as, outside is how
    /// to send it.
    private var composer: some View {
        VStack(alignment: .leading, spacing: 0) {
            box
            hints
            if isWelcome { suggestion }
        }
        .padding(m.px(.transcriptPadding))
    }

    /// A **square** box that grows with its content from one line to eight.
    private var box: some View {
        // Measured here rather than inside the alignment guide below. The guide's
        // closure is not main-actor isolated, and this reaches `NSLayoutManager`
        // — which is AppKit, and must not be touched off the main actor even
        // though SwiftUI happens to call the guide there today.
        let promptBaseline = Composer.firstBaseline(at: m.px(.textSize))

        return VStack(alignment: .leading, spacing: m.px(.composerFootGap)) {
            // Baselines, not tops. The glyph is set larger than the text it
            // sits beside, so aligning the two boxes' tops leaves them on
            // different lines — see `Composer.firstBaseline(at:)`.
            HStack(alignment: .firstTextBaseline, spacing: m.px(.promptGlyphGap)) {
                Text("\u{203A}")
                    .font(m.font(.promptGlyphSize))
                    .foregroundStyle(Color(Palette.prompt))

                Composer(
                    session: session, metrics: m,
                    placeholder: session.composerPlaceholder
                )
                    // The floor is what the box is before the text view has
                    // measured itself, so it has to be a real line: 1.45 × the
                    // text size is taller than the line the view returns and
                    // left the box 3pt of slack, while the bare text size is
                    // shorter and clipped the descenders. One line of the
                    // actual font is neither.
                    .frame(
                        height: max(
                            session.composerHeight,
                            Composer.lineHeight(at: m.px(.textSize))
                        )
                    )
                    // A representable reports no baseline of its own, so the
                    // one the text is actually laid out on is handed over.
                    // Fixed to the *first* line, so a box that has grown to
                    // eight lines does not drag the glyph down with it.
                    .alignmentGuide(.firstTextBaseline) { _ in promptBaseline }
            }

            foot
        }
        .padding(.horizontal, m.px(.composerPaddingX))
        .padding(.vertical, m.px(.composerPaddingY))
        .background(
            RoundedRectangle(cornerRadius: m.px(.composerRadius))
                .fill(Color(Palette.composerBG))
                .overlay(
                    RoundedRectangle(cornerRadius: m.px(.composerRadius))
                        // spec §13.7 lists this as declared and never applied —
                        // the focused state was computed and then discarded.
                        // plan §3 said to fix it on the way past.
                        .strokeBorder(
                            Color(
                                session.composerFocused
                                    ? Palette.composerBorderActive : Palette.composerBorder
                            ),
                            lineWidth: m.px(.composerBorder)
                        )
                )
        )
        // The placeholder is not overlaid here: the text view draws it, so that
        // it and the typed text cannot land in different places. See
        // `ComposerTextView.draw(_:)`.
    }

    /// Inside the box: what this message will be sent as, and how to send it.
    ///
    /// The demo reads `build  default agent`. Neither half is invented here —
    /// the model is whatever the agent last reported in a `status` event, and
    /// the demo's `build` has no counterpart at all, because the protocol has no
    /// notion of a mode (spec §7). A pane with no agent behind it says so.
    private var foot: some View {
        HStack(spacing: 0) {
            Text(session.transcript.status["model"] ?? "no agent")

            Spacer(minLength: m.px(.composerFootGap))

            Button { session.submitComposer?() } label: {
                HStack(spacing: m.px(.composerFootGap)) {
                    Text("send")
                    Text("\u{21B5}").foregroundStyle(Color(Palette.text))
                }
            }
            .buttonStyle(.plain)
            // Enter is the real affordance and it is always there; this is the
            // same action for a pointer, so it dims under the same condition
            // rather than staying live over an empty box.
            .disabled(session.composerIsEmpty)
        }
        .font(m.font(.secondaryTextSize))
        .foregroundStyle(Color(Palette.composerFoot))
        .lineLimit(1)
    }

    /// Outside the box: how to send, and what Escape means *right now* — it
    /// interrupts a running turn and otherwise gives the keyboard back to the
    /// tab strip (spec §9.6), so the hint says which.
    private var hints: some View {
        HStack(spacing: 0) {
            Text(session.isAnsweringByTyping ? "enter answer" : "enter send")
            Text("  \u{00B7}  shift+enter newline")

            Spacer(minLength: m.px(.composerFootGap))

            Text(session.transcript.isRunning ? "esc interrupt" : "esc unfocus")
        }
        .font(m.font(.secondaryTextSize))
        .foregroundStyle(Color(Palette.composerHint))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.top, m.px(.composerHintPaddingY))
    }
}

/// A suggestion that lights up under the pointer, so it reads as something to
/// click rather than as a caption.
private struct SuggestionButton: View {
    let text: String
    let action: (String) -> Void

    @State private var hovering = false

    var body: some View {
        Button { action(text) } label: {
            Text("\u{201C}\(text)\u{201D}")
                .foregroundStyle(Color(hovering ? Palette.suggestionHover : Palette.suggestion))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension AgentSession {
    /// One of every block in spec §9.3, for `PROSE_TRANSCRIPT=demo`.
    ///
    /// A measurement affordance, like the others: spec §5's table has to be
    /// re-measured after any layout change and an agent cannot type. Every line
    /// below goes through the same `Transcript.apply` a real agent's events
    /// would, so what appears is the reducer's output rather than a mock-up.
    func demo() {
        apply(.status(fields: ["model": "sonnet", "cost": "$0.02"]))
        apply(.turn(state: .started, error: nil))

        transcript.pushUser("Summarise what changed in the port this week.")
        revisionBump()

        apply(.messageStart(id: "m1", role: .agent))
        apply(.delta(id: "m1", text: "The split tree, the transcript reducer and the "))
        apply(.delta(id: "m1", text: "protocol all came across with their tests. "))
        apply(.delta(id: "m1", text: "The browser pane is a real WKWebView now."))
        apply(.messageEnd(id: "m1"))

        apply(.messageStart(id: "t1", role: .thinking))
        apply(.delta(id: "t1", text: "The split tree is the part most likely to have drifted, "))
        apply(.delta(id: "t1", text: "so check its tests before anything else."))
        apply(.messageEnd(id: "t1"))

        apply(
            .activity(
                id: "a1", label: "Searching", detail: "40 sources", state: .running,
                category: "search"))
        apply(
            .activity(
                id: "a2", label: "Bash(swift test)", detail: "95 passed", state: .ok,
                category: "tool"))
        apply(
            .activity(
                id: "a3", label: "Skill", detail: "swift-testing", state: .ok, category: "skill"))
        apply(
            .activity(
                id: "a4", label: "Bash(swift build)", detail: nil, state: .error, category: "tool"))

        apply(
            .attachment(
                Attachment(
                    id: "x1", kind: "code", language: "swift",
                    text: "public func clampedFraction(\n    _ raw: Double,\n    parentPx: Double,\n    minPx: Double\n) -> Double"
                )
            )
        )
        // A type this build has never heard of renders as plain prose rather
        // than vanishing.
        apply(.attachment(Attachment(id: "x2", kind: "spreadsheet", language: nil, text: "a,b,c")))

        apply(.turn(state: .ended, error: nil))
        notice("agent exited (code 1)")
        ask(id: .number(1), prompt: "Which reading of spec §7.1 should the header take?",
            choices: ["Unscaled", "Scaled"], placeholder: "or say which line you mean")
    }

    /// `pushUser` is on the transcript rather than on this object, so the
    /// revision has to be bumped by hand when the demo uses it directly.
    private func revisionBump() {
        follow = true
    }
}
