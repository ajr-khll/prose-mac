//  What a pane has to show: a flat list of blocks, built by folding the events
//  an agent sends into it.
//
//  Pure, like `Split.swift` and `Protocol.swift`. The renderer walks
//  `Transcript` and draws; it never decides what belongs in one. Keeping the
//  fold here means a whole conversation can be replayed and asserted on without
//  a window.
//
//  The reducer is **total**: every event does something sensible whatever state
//  it arrives in (spec §10). A delta for a block that was never opened, an end
//  for a block that already ended, an activity that resolves twice — all of
//  these are things a half-written agent will do, and none of them may trap.

/// One drawable thing.
public enum Block: Sendable, Equatable {
    /// Prose, from either side. Grows by delta while `streaming`.
    case message(id: String, role: Role, text: String, streaming: Bool)

    /// The agent reasoning. Grows by delta like a message, and folds itself
    /// away once the turn's real answer begins.
    ///
    /// **Deliberately not a `.message` with a different role.** Three things
    /// need somewhere to live that a message has no room for. `hasConversation`
    /// counts any message, so reasoning would take a pane out of its welcome
    /// state before the agent had said a word. `collapsed` cannot sit in the
    /// view, because the transcript's `ForEach` is keyed on array offset and
    /// every block appended above would shift it. And a fold that cannot tell
    /// reasoning from prose cannot treat the two differently anywhere else —
    /// which is exactly what a parent reading a summary needs it to do.
    case thinking(id: String, text: String, streaming: Bool, collapsed: Bool)

    /// A labelled step: a tool call, a retrieval, a wait. `category` says which
    /// sort, when the agent bothered to say.
    case activity(
        id: String, label: String, detail: String?, state: ActivityState, category: String?)

    case attachment(Attachment)

    /// The agent stopped to ask the user something. Holds the JSON-RPC id it
    /// must be answered on, which is what makes the card resolve the agent's
    /// pending request rather than just recording a click.
    case ask(
        id: RequestID,
        prompt: String,
        choices: [String],
        placeholder: String?,
        answer: String?,
        /// Whether what is typed here is a credential.
        ///
        /// Set, the field masks its input and the transcript records a row of
        /// dots rather than the answer. The real text still reaches the agent
        /// — it asked for a token because it needs one — but a transcript is
        /// scrolled back through, screenshotted and pasted into conversations,
        /// and a credential that got into one is a credential to revoke.
        secret: Bool,
        /// The pane deciding this, when it is not the user's to decide yet.
        ///
        /// A question from a subagent goes to whoever spawned it first. The
        /// card is drawn either way — seeing what is being decided is worth
        /// more than being asked to decide it — but while this is set it takes
        /// no clicks and does not claim Enter. Cleared when the parent declines
        /// or runs out of time, at which point it becomes an ordinary question.
        supervisor: PaneID?
    )

    /// A failed turn, or the agent's process going away.
    case notice(message: String)
}

/// A struct rather than a class: the container the app wraps this in becomes
/// `@Observable` (plan §5), and keeping the fold itself a value means a
/// transcript can be copied, replayed and compared in a test with no lifetime
/// to think about.
public struct Transcript: Sendable {
    public private(set) var blocks: [Block] = []

    /// A monotone sequence number per block, index-aligned with `blocks`.
    ///
    /// **`blocks.count` is not a cursor.** A delta mutates a block in place
    /// without changing the count, and `upsertActivity` rewrites an *earlier*
    /// index — so "everything after block 5" would silently miss an activity
    /// resolving at block 3. Stamping each touched index with a rising clock is
    /// what makes "everything that changed since you last looked" answerable,
    /// which is what a supervising parent actually asks.
    public private(set) var seqs: [Int] = []

    /// Rises on every change. Handed out as the cursor to read from next time.
    public private(set) var clock = 0

    /// Whether a turn is in flight, which is what decides between a spinner and
    /// a prompt, and what Escape interrupts.
    public private(set) var isRunning = false

    /// Whether either side has actually said anything yet.
    ///
    /// **Deliberately not `isEmpty`.** A pane whose agent could not be started
    /// has a notice in it and is, from the user's point of view, still a pane
    /// where nothing has happened — and `agent exited` arrives within a moment
    /// of the pane opening, so keying the welcome state off emptiness meant the
    /// wordmark was replaced by an almost-blank transcript before the user had
    /// touched anything. Measured, not reasoned about: it is what the first run
    /// of the welcome screen actually did.
    public var hasConversation: Bool {
        blocks.contains { block in
            if case .message = block { true } else { false }
        }
    }

    /// Free-form key/values from `status` events, drawn in the pane header.
    public private(set) var status: [String: String] = [:]

    public init() {}

    public var isEmpty: Bool { blocks.isEmpty }

    /// The status fields in a fixed order, so the pane header does not reshuffle
    /// itself between frames. Rust used a `BTreeMap` for this; a Swift
    /// `Dictionary` has no order of its own, so the guarantee lives here — the
    /// one place that hands the fields to a view.
    public var statusInOrder: [(key: String, value: String)] {
        status.sorted { $0.key < $1.key }
    }

    /// The question the user still owes an answer to, if any. Only one can be
    /// outstanding at a time — an agent that asks twice before being answered
    /// gets the first one answered first.
    public var pendingAsk: Block? {
        blocks.first { block in
            if case .ask(_, _, _, _, let answer, _, _) = block { return answer == nil }
            return false
        }
    }

    // MARK: - Folding events

    public mutating func apply(_ event: Event) {
        switch event {
        case .messageStart(let id, let role):
            if role == .thinking {
                append(.thinking(id: id, text: "", streaming: true, collapsed: false))
            } else {
                append(.message(id: id, role: role, text: "", streaming: true))
            }

        case .delta(let id, let chunk):
            // A delta for a block nobody opened is dropped. Opening one
            // implicitly would be friendlier but would also hide the bug from
            // whoever is writing the agent.
            guard let index = streamableIndex(id) else { return }
            switch blocks[index] {
            case .message(let id, let role, let text, let streaming):
                replace(
                    index,
                    with: .message(id: id, role: role, text: text + chunk, streaming: streaming))
            case .thinking(let id, let text, let streaming, let collapsed):
                replace(
                    index,
                    with: .thinking(
                        id: id, text: text + chunk, streaming: streaming, collapsed: collapsed))
            default: return
            }

        case .messageEnd(let id):
            guard let index = streamableIndex(id) else { return }
            switch blocks[index] {
            case .message(let id, let role, let text, _):
                replace(index, with: .message(id: id, role: role, text: text, streaming: false))
            case .thinking(let id, let text, _, let collapsed):
                replace(
                    index, with: .thinking(id: id, text: text, streaming: false, collapsed: collapsed))
            default: return
            }

        case .activity(let id, let label, let detail, let state, let category):
            upsertActivity(id: id, label: label, detail: detail, state: state, category: category)

        case .attachment(let attachment):
            append(.attachment(attachment))

        case .turn(let state, let error):
            isRunning = state == .started
            // Anything still streaming when a turn ends never got its
            // `message.end`. Closing it here keeps a stray caret from blinking
            // forever at the bottom of the pane.
            if !isRunning { finishStreaming() }
            if let error { append(.notice(message: error)) }

        case .status(let fields):
            status.merge(fields) { _, new in new }
        }
    }

    // MARK: - Things that are not events

    /// Records what the user just sent, so it appears above the reply.
    public mutating func pushUser(_ text: String) {
        append(
            // The user's own messages need no id: nothing streams into them.
            .message(id: "", role: .user, text: text, streaming: false)
        )
    }

    public mutating func pushAsk(
        id: RequestID,
        prompt: String,
        choices: [String],
        placeholder: String?,
        secret: Bool = false,
        supervisor: PaneID? = nil
    ) {
        append(
            .ask(
                id: id, prompt: prompt, choices: choices, placeholder: placeholder,
                answer: nil, secret: secret, supervisor: supervisor)
        )
    }

    /// Hands the outstanding question back to the user.
    ///
    /// What a parent declining looks like, and what running out of time looks
    /// like — they are the same thing, so they are one path.
    @discardableResult
    public mutating func escalateAsk() -> Bool {
        let pending = blocks.firstIndex { block in
            if case .ask(_, _, _, _, let answer, _, let supervisor) = block {
                return answer == nil && supervisor != nil
            }
            return false
        }
        guard let index = pending,
              case .ask(let id, let prompt, let choices, let placeholder, _, let secret, _) =
                blocks[index]
        else { return false }

        replace(
            index,
            with: .ask(
                id: id, prompt: prompt, choices: choices, placeholder: placeholder,
                answer: nil, secret: secret, supervisor: nil))
        return true
    }

    /// Marks the outstanding question answered and hands back the id it has to
    /// be replied to on, or `nil` if nothing was pending.
    @discardableResult
    public mutating func answerAsk(_ text: String) -> RequestID? {
        let pending = blocks.firstIndex { block in
            if case .ask(_, _, _, _, let answer, _, _) = block { return answer == nil }
            return false
        }
        guard let index = pending,
              case .ask(let id, let prompt, let choices, let placeholder, _, let secret,
                        let supervisor) = blocks[index]
        else { return nil }

        replace(
            index,
            with: .ask(
                id: id,
                prompt: prompt,
                choices: choices,
                placeholder: placeholder,
                // What the *agent* gets is returned from this function and is
                // untouched; this is only what the transcript keeps.
                answer: secret ? String(repeating: "•", count: 8) : text,
                secret: secret,
                supervisor: supervisor
            )
        )
        return id
    }

    public mutating func pushNotice(_ message: String) {
        isRunning = false
        finishStreaming()
        append(.notice(message: message))
    }

    // MARK: - Helpers

    /// Appends a block and stamps it.
    ///
    /// Every append goes through here rather than touching `blocks` directly,
    /// so the two arrays cannot drift apart — an unstamped block would be
    /// invisible to every reader forever, which is a far quieter bug than a
    /// crash would be.
    private mutating func append(_ block: Block) {
        blocks.append(block)
        clock += 1
        seqs.append(clock)
    }

    /// Replaces a block in place and stamps it, so a change that does not grow
    /// the transcript is still something a reader can notice.
    private mutating func replace(_ index: Int, with block: Block) {
        blocks[index] = block
        clock += 1
        seqs[index] = clock
    }

    /// Every block changed at or after `cursor`, oldest first.
    ///
    /// Indices are returned alongside, because an index is a block's address:
    /// notices have no id and user messages use an empty one, so ids cannot be
    /// used to point at one. The index is stable because blocks are only ever
    /// appended or mutated in place — **nothing is ever removed.** A future
    /// `clear` would break that, and would have to bump a generation number.
    public func changed(since cursor: Int) -> [(index: Int, block: Block)] {
        seqs.indices
            .filter { seqs[$0] > cursor }
            .map { (index: $0, block: blocks[$0]) }
    }

    /// The block this id streams into — a message or a thinking block — searched
    /// from the end, because the one being streamed into is almost always the
    /// last. Ids are the agent's to keep distinct; prose does not scope them by
    /// kind, so a `delta` reaches whichever it opened.
    private func streamableIndex(_ id: String) -> Int? {
        blocks.lastIndex { block in
            switch block {
            case .message(let existing, _, _, _): existing == id
            case .thinking(let existing, _, _, _): existing == id
            default: false
            }
        }
    }

    /// An activity arrives once when it starts and again when it resolves, so
    /// the second one updates the row in place rather than adding a duplicate.
    private mutating func upsertActivity(
        id: String,
        label: String,
        detail: String?,
        state: ActivityState,
        category: String?
    ) {
        let existing = blocks.lastIndex { block in
            if case .activity(let existing, _, _, _, _) = block { return existing == id }
            return false
        }

        guard let index = existing,
              case .activity(_, _, let existingDetail, _, let existingCategory) = blocks[index]
        else {
            append(
                .activity(id: id, label: label, detail: detail, state: state, category: category))
            return
        }

        // A resolving update that carries no detail keeps the one it had, so
        // "Searching / 40 sources" does not lose its subtitle on the way to
        // being ticked off.
        replace(
            index,
            with: .activity(
                id: id,
                label: label,
                detail: detail ?? existingDetail,
                // Kept for the same reason the detail is: a resolving update
                // says what happened, not what sort of step it was.
                state: state,
                category: category ?? existingCategory
            )
        )
    }

    private mutating func finishStreaming() {
        for (index, block) in blocks.enumerated() {
            switch block {
            case .message(let id, let role, let text, true):
                replace(index, with: .message(id: id, role: role, text: text, streaming: false))
            case .thinking(let id, let text, true, _):
                // Folded away as it closes. Reasoning is worth showing while it
                // is the only thing happening and worth keeping afterwards, but
                // it is not what the reader came back for once there is an
                // answer above it.
                replace(index, with: .thinking(id: id, text: text, streaming: false, collapsed: true))
            default: continue
            }
        }
    }

    /// Opens or closes the thinking block at `index`. A no-op on anything else,
    /// so a stale index from a view cannot corrupt the fold.
    public mutating func toggleThinking(at index: Int) {
        guard blocks.indices.contains(index),
              case .thinking(let id, let text, let streaming, let collapsed) = blocks[index]
        else { return }
        replace(index, with: .thinking(id: id, text: text, streaming: streaming, collapsed: !collapsed))
    }
}
