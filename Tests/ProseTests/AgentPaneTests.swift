import AppKit
import ProseCore
import SwiftUI
import Testing

@testable import Prose

/// The agent pane's own rules: spec §9.5's sending, spec §9.1's follow, and the
/// composer behaviours prose actually wrote.
///
/// What is deliberately *not* tested is everything `NSTextView` inherits —
/// word movement, grapheme deletion, visual-line arrows, IME, the UTF-16
/// boundary. Those are Apple's, and a test here would be testing AppKit.
@MainActor
@Suite("Agent pane")
struct AgentPaneTests {
    private func session() -> AgentSession {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        return workspace.agent(pane)!
    }

    // MARK: - spec §9.5, sending

    @Test("Enter sends, and an empty composer sends nothing")
    func sendingAndEmptySends() {
        let agent = session()

        agent.send("   ")
        #expect(agent.transcript.isEmpty, "whitespace is not a message")
        #expect(agent.outbox.isEmpty)

        agent.send("hello")
        #expect(agent.transcript.blocks.count == 1)
        #expect(agent.outbox.count == 1)
    }

    @Test("what the user sent lands in the transcript and on the wire")
    func sendingRecordsBothSides() throws {
        let agent = session()
        agent.send("  summarise this  ")

        guard case .message(_, let role, let text, _)? = agent.transcript.blocks.first else {
            Issue.record("expected a user message, got \(agent.transcript.blocks)")
            return
        }
        #expect(role == .user)
        #expect(text == "summarise this", "trimmed on the way in")

        guard case .message(_, let sent)? = agent.outbox.first else {
            Issue.record("expected a message on the wire")
            return
        }
        #expect(sent == "summarise this")
    }

    @Test("Enter answers an outstanding free-text question instead of starting a turn")
    func enterAnswersAPendingAsk() {
        // The reply resolves the agent's pending request rather than arriving
        // as a fresh message (spec §9.5), so there is no user block.
        let agent = session()
        agent.ask(id: .number(7), prompt: "Which one?", choices: [], placeholder: nil)
        #expect(agent.isAnsweringByTyping)

        agent.send("the second")

        #expect(agent.transcript.blocks.count == 1, "no new user message")
        #expect(agent.transcript.pendingAsk == nil)
        guard case .reply(let id, _)? = agent.outbox.last else {
            Issue.record("expected a reply, got \(agent.outbox)")
            return
        }
        #expect(id == .number(7))
    }

    @Test("a question with choices can still be answered by typing")
    func choicesAlsoClaimEnter() {
        // Choices and a typed answer are two ways of answering one question,
        // not two kinds of question (spec §9.5). An agent offering three
        // options and a way to say something else should not have to pick
        // between drawing the buttons and being answerable in words.
        let agent = session()
        agent.ask(id: .number(1), prompt: "Which?", choices: ["a", "b"], placeholder: "or say why")
        #expect(agent.isAnsweringByTyping)

        agent.send("neither, actually")

        #expect(agent.transcript.pendingAsk == nil, "the typed answer resolved it")
        #expect(agent.transcript.blocks.count == 1, "no new user message")
        guard case .reply(let id, let value)? = agent.outbox.last else {
            Issue.record("expected a reply, got \(agent.outbox)")
            return
        }
        #expect(id == .number(1))
        #expect(value["answer"]?.string == "neither, actually")
    }

    @Test("a click and a typed answer cannot both land")
    func firstAnswerWins() {
        // `answerAsk` only ever finds an *unanswered* ask, so whichever of the
        // two arrives first resolves the card and the other is a no-op. That is
        // what makes offering both safe.
        let agent = session()
        agent.ask(id: .number(2), prompt: "Which?", choices: ["a", "b"], placeholder: "or say why")

        agent.answer("a")
        let after = agent.outbox.count
        agent.send("b")

        #expect(agent.outbox.count == after + 1, "the second answer became a message, not a reply")
        guard case .message = agent.outbox.last else {
            Issue.record("expected a message, got \(agent.outbox)")
            return
        }
    }

    @Test("the composer says what it will do while a question is outstanding")
    func placeholderFollowsTheAsk() {
        let agent = session()
        #expect(agent.composerPlaceholder == "Ask anything…")

        agent.ask(id: .number(3), prompt: "Which?", choices: [], placeholder: "row or column")
        #expect(agent.composerPlaceholder == "row or column")

        agent.send("row")
        #expect(agent.composerPlaceholder == "Ask anything…", "and back again once answered")
    }

    @Test("clicking a choice answers the card")
    func clickingAChoice() {
        let agent = session()
        agent.ask(id: .text("ask-7"), prompt: "Which?", choices: ["a", "b"], placeholder: nil)

        agent.answer("b")
        #expect(agent.transcript.pendingAsk == nil)
        guard case .reply(let id, let value)? = agent.outbox.last else {
            Issue.record("expected a reply")
            return
        }
        #expect(id == .text("ask-7"))
        #expect(value["answer"]?.string == "b")
    }

    @Test("only one question is outstanding at a time, oldest first")
    func oldestQuestionFirst() {
        let agent = session()
        agent.ask(id: .number(1), prompt: "first", choices: [], placeholder: nil)
        agent.ask(id: .number(2), prompt: "second", choices: [], placeholder: nil)

        agent.send("x")
        agent.send("y")

        let ids: [RequestID] = agent.outbox.compactMap {
            if case .reply(let id, _) = $0 { return id }
            return nil
        }
        #expect(ids == [.number(1), .number(2)])
    }

    // MARK: - Escape

    @Test("Escape interrupts a running turn")
    func escapeInterrupts() {
        let agent = session()
        agent.apply(.turn(state: .started, error: nil))

        #expect(agent.interrupt(), "there was a turn to interrupt")
        guard case .interrupt? = agent.outbox.last else {
            Issue.record("expected an interrupt on the wire")
            return
        }
    }

    @Test("Escape with no turn running hands the keyboard back instead")
    func escapeResigns() {
        let agent = session()
        #expect(!agent.interrupt(), "nothing to interrupt, so the caller resigns")
        #expect(agent.outbox.isEmpty)
    }

    @Test("Escape hands the keyboard to the tab strip through the pane body")
    func escapeReachesTheTabStrip() {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        let agent = workspace.agent(pane)!
        workspace.focusPane(pane)
        #expect(workspace.keyboardOwner == .content)

        // What `AgentPaneBody` installs, and what the composer calls when
        // `cancelOperation` finds no turn to interrupt.
        agent.onResignToTabStrip = { workspace.keyboardOwner = .tabStrip }
        agent.onResignToTabStrip?()

        #expect(workspace.keyboardOwner == .tabStrip)
    }

    // MARK: - spec §9.1, follow

    @Test("a stream does not yank the view away from someone reading")
    func streamingDoesNotReArmFollow() {
        let agent = session()
        agent.follow = false

        agent.apply(.messageStart(id: "m", role: .agent))
        agent.apply(.delta(id: "m", text: "hello"))
        agent.apply(.turn(state: .ended, error: nil))

        #expect(!agent.follow, "any scroll is the user saying they want to read something else")
    }

    @Test("follow is re-armed by sending, by an ask and by a notice")
    func followIsReArmed() {
        // The three things spec §9.1 names, and only those.
        let sending = session()
        sending.follow = false
        sending.send("hello")
        #expect(sending.follow)

        let asking = session()
        asking.follow = false
        asking.ask(id: .number(1), prompt: "?", choices: [], placeholder: nil)
        #expect(asking.follow)

        let notifying = session()
        notifying.follow = false
        notifying.notice("agent exited (code 1)")
        #expect(notifying.follow)
    }

    @Test("every change bumps the revision, including a delta")
    func revisionTracksDeltas() {
        // Follow-the-bottom watches this rather than the block count: a
        // streaming message grows without the list changing length.
        let agent = session()
        agent.apply(.messageStart(id: "m", role: .agent))
        let before = agent.revision

        agent.apply(.delta(id: "m", text: "more"))
        #expect(agent.revision > before)
        #expect(agent.transcript.blocks.count == 1, "and the list did not change length")
    }

    // MARK: - The pane

    @Test("clicking a pane moves the caret into its composer")
    func clickingAimsTheComposer() {
        // spec §8: focus moves *into* the agent's composer where there is one,
        // so the caret lands where the typing will go.
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        let agent = workspace.agent(pane)!
        #expect(!agent.wantsComposerFocus)

        workspace.focusPane(pane)
        #expect(agent.wantsComposerFocus)
    }

    @Test("an agent pane's conversation ends when it becomes a browser pane")
    func becomingABrowserEndsTheSession() {
        let workspace = Workspace()
        let pane = workspace.activeTab!.panes[0].id
        workspace.agent(pane)!.send("hello")

        workspace.setPaneKind(pane, .browser)
        #expect(workspace.agent(pane) == nil, "nothing is left to draw its output")

        // And turning it back gives it a fresh one rather than the old
        // transcript.
        workspace.setPaneKind(pane, .agent)
        #expect(workspace.agent(pane)?.transcript.isEmpty == true)
    }

    @Test("the pane header shows thinking, then the agent's own status fields")
    func headerStatus() {
        let agent = session()
        // Nothing when there is neither (spec §8).
        #expect(agent.transcript.statusInOrder.isEmpty)
        #expect(!agent.transcript.isRunning)

        agent.apply(.status(fields: ["model": "sonnet", "cost": "$1"]))
        // Ordered, so the header does not reshuffle between frames.
        #expect(agent.transcript.statusInOrder.map(\.value) == ["$1", "sonnet"])

        agent.apply(.turn(state: .started, error: nil))
        #expect(agent.transcript.isRunning, "thinking… wins while a turn runs")
    }

    // MARK: - Supervised questions

    @Test("a supervised question is visible but not the user's to answer")
    func supervisedAsksAreInert() {
        let agent = session()
        agent.ask(id: .number(1), prompt: "Which?", choices: ["a"], placeholder: "or say why",
                  supervisor: 7)

        #expect(agent.supervisedAsk == 7)
        #expect(!agent.isAnsweringByTyping, "Enter still starts a turn")
        #expect(
            agent.composerPlaceholder == "Ask anything…",
            "and the composer does not offer to answer something it cannot")
        #expect(agent.transcript.pendingAsk != nil, "but it is drawn, and still outstanding")
    }

    @Test("typing while a parent decides sends a message, it does not answer")
    func typingDoesNotStealASupervisedAnswer() {
        let agent = session()
        agent.ask(id: .number(1), prompt: "Which?", choices: [], placeholder: nil, supervisor: 7)

        agent.send("row")

        #expect(agent.transcript.pendingAsk != nil, "still the parent's to answer")
        guard case .message = agent.outbox.last else {
            Issue.record("expected a message, got \(agent.outbox)")
            return
        }
    }

    @Test("escalating hands the question back to the user")
    func escalationMakesItOrdinary() {
        // What a parent declining looks like, and what it running out of time
        // looks like — one path, because they are the same event.
        let agent = session()
        agent.ask(id: .number(1), prompt: "Which?", choices: ["a"], placeholder: "or say why",
                  supervisor: 7)

        #expect(agent.escalateAsk())
        #expect(agent.supervisedAsk == nil)
        #expect(agent.isAnsweringByTyping, "now Enter answers it")
        #expect(agent.composerPlaceholder == "or say why")

        agent.send("neither")
        #expect(agent.transcript.pendingAsk == nil)
    }

    @Test("escalating an unsupervised or answered question does nothing")
    func escalationIsTotal() {
        let agent = session()
        #expect(!agent.escalateAsk(), "nothing pending")

        agent.ask(id: .number(1), prompt: "Which?", choices: [], placeholder: nil)
        #expect(!agent.escalateAsk(), "already the user's")

        agent.answer("a")
        #expect(!agent.escalateAsk(), "and answered questions stay answered")
    }

    @Test("a parent answering resolves the card exactly as a click would")
    func theParentCanAnswer() {
        let agent = session()
        agent.ask(id: .number(9), prompt: "Which?", choices: ["a", "b"], placeholder: nil,
                  supervisor: 7)

        agent.answer("b")

        #expect(agent.transcript.pendingAsk == nil)
        guard case .reply(let id, let value)? = agent.outbox.last else {
            Issue.record("expected a reply, got \(agent.outbox)")
            return
        }
        #expect(id == .number(9))
        #expect(value["answer"]?.string == "b")
    }
}

/// The composer, driven through a real `NSTextView` in an off-screen window.
///
/// The same technique the browser tests use: `NSHostingView` builds the tree it
/// would build on screen, so the text view is real, its layout manager is real,
/// and none of it needs a display.
@MainActor
@Suite("Composer")
struct ComposerTests {
    private func hosted() throws -> Hosted { try hostComposer() }

    @Test("the composer is a real NSTextView in the pane")
    func itIsARealTextView() throws {
        let host = try hosted()
        #expect(host.textView.isEditable)
        #expect(!host.textView.isRichText, "prose renders paragraphs; structure is the agent's")
    }

    /// Return, as a real key event.
    ///
    /// These three go through `keyDown` rather than calling `doCommand` with a
    /// selector, and that is the whole point of them. The previous versions
    /// poked the selector each case was *believed* to produce — and the belief
    /// was wrong: Shift+Return does not produce `insertNewlineIgnoringFieldEditor:`,
    /// it produces plain `insertNewline:`, so the composer sent the message
    /// while its own hint row promised a newline. A test that names the selector
    /// cannot catch that, because it is the mapping that is wrong. Driving the
    /// key event exercises AppKit's real binding table.
    private func pressReturn(_ host: Hosted, _ flags: NSEvent.ModifierFlags) throws {
        // `interpretKeyEvents` routes through the view's input context, and a
        // view only has one while it is first responder. Without this the key
        // event is swallowed and every expectation below fails identically,
        // which says nothing about the binding under test.
        #expect(host.window.makeFirstResponder(host.textView), "the composer took the keyboard")

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: host.window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                keyCode: 36
            )
        )
        host.textView.keyDown(with: event)
    }

    @Test("Enter sends and clears")
    func enterSends() throws {
        let host = try hosted()
        host.textView.string = "hello"

        try pressReturn(host, [])

        #expect(host.agent.transcript.blocks.count == 1)
        #expect(host.textView.string.isEmpty, "the composer empties on send")
    }

    @Test("Shift+Enter inserts a newline rather than sending")
    func shiftEnterInsertsANewline() throws {
        let host = try hosted()
        host.textView.string = "first"
        host.textView.setSelectedRange(NSRange(location: 5, length: 0))

        try pressReturn(host, [.shift])

        #expect(host.agent.transcript.isEmpty, "nothing was sent")
        #expect(host.textView.string == "first\n", "the newline went in at the caret")
    }

    /// AppKit binds Option+Return to `insertNewlineIgnoringFieldEditor:`, which
    /// already means "a newline whatever Return would otherwise do". It is not
    /// in spec §9.5, but it must not send.
    @Test("Option+Enter also inserts a newline")
    func optionEnterInsertsANewline() throws {
        let host = try hosted()
        host.textView.string = "first"
        host.textView.setSelectedRange(NSRange(location: 5, length: 0))

        try pressReturn(host, [.option])

        #expect(host.agent.transcript.isEmpty, "nothing was sent")
        #expect(host.textView.string.contains("\n"))
    }

    @Test("the caret is 1.5pt at 1.0× and does not blink")
    func theCaretIsWideAndStill() throws {
        let host = try hosted()
        // Converted rather than compared across CGFloat and Double: `#expect`
        // decomposes the comparison and the implicit bridge does not survive
        // the macro expansion, so the two sides disagree while their bit
        // patterns are identical.
        #expect(Double(host.textView.caretWidth) == Points.caretWidth.value)

        // Passing false means the blink timer is never restarted, so the caret
        // is drawn once and stays. Calling it with `true` must change nothing.
        host.textView.updateInsertionPointStateAndRestartTimer(true)
        #expect(Double(host.textView.caretWidth) == Points.caretWidth.value)
    }

    @Test("selected text is drawn on the shaped line, not as a separate quad")
    func selectionIsAnAttribute() throws {
        let host = try hosted()
        let background = host.textView.selectedTextAttributes[.backgroundColor] as? NSColor
        #expect(background != nil, "one attribute is what makes selection follow a wrap")
    }

    /// The **box**, which is `boxHeight` and not `intrinsicContentSize`.
    ///
    /// It used to read the latter, because the two were the same number — the
    /// document reported the capped height. That is exactly what stopped a long
    /// prompt from scrolling, so the two are now different things and this test
    /// wants the one that sizes the box. See `LongPromptTests` for the other.
    @Test("the box grows with its content and stops at eight lines")
    func growthStopsAtEightLines() throws {
        let host = try hosted()
        let oneLine = host.textView.boxHeight

        host.textView.string = Array(repeating: "line", count: 4).joined(separator: "\n")
        host.textView.didChangeText()
        let fourLines = host.textView.boxHeight
        #expect(fourLines > oneLine, "it grew with its content")

        host.textView.string = Array(repeating: "line", count: 40).joined(separator: "\n")
        host.textView.didChangeText()
        let manyLines = host.textView.boxHeight

        #expect(manyLines <= host.textView.maximumHeight)
        #expect(manyLines < fourLines * 8, "past eight lines it scrolls instead of growing")
    }

    @Test("the focus ring uses the colour spec §13.7 said was never applied")
    func focusRingIsApplied() throws {
        let host = try hosted()
        #expect(!host.agent.composerFocused)

        #expect(host.window.makeFirstResponder(host.textView))
        #expect(host.agent.composerFocused, "which is what selects composer_border_active")
    }

    /// The placeholder has to sit exactly where the first character will.
    ///
    /// It used to be a SwiftUI overlay padded to `composerPaddingX`, which put
    /// it 5pt left of the text — the `lineFragmentPadding` a text container adds
    /// on its own — and on a baseline of its own. The caret is always at the
    /// real origin, so it struck through the placeholder's first letter, and
    /// typing moved the text sideways from where the placeholder had been.
    @Test("the placeholder is where the first character will be")
    func placeholderSitsOnTheText() throws {
        let host = try hosted()
        let view = host.textView
        let container = try #require(view.textContainer)
        let manager = try #require(view.layoutManager)

        #expect(view.string.isEmpty)
        #expect(!view.placeholder.isEmpty, "an empty composer says something")

        // Where the view actually draws it.
        let drawn = view.placeholderOrigin

        // Where AppKit actually puts the first glyph of real text.
        view.string = view.placeholder
        view.didChangeText()
        manager.ensureLayout(for: container)
        let glyph = manager.boundingRect(
            forGlyphRange: NSRange(location: 0, length: 1), in: container
        )
        let typed = NSPoint(
            x: glyph.minX + view.textContainerOrigin.x,
            y: glyph.minY + view.textContainerOrigin.y
        )

        #expect(
            abs(Double(drawn.x) - Double(typed.x)) < 0.5,
            "the placeholder does not shift sideways when typed into")
        #expect(
            abs(Double(drawn.y) - Double(typed.y)) < 0.5,
            "nor onto a different baseline")
    }

    /// spec §5's 1.45 is baseline to baseline — 18.85 at 1.0× — applied
    /// between lines rather than around them.
    ///
    /// Both of the other readings make the box too tall. `lineHeightMultiple`
    /// scales the font's natural line height, not its point size, so 1.45 gives
    /// 23.2. Pinning min/max line height to 18.85 gets the number right but
    /// AppKit puts the extra 2.85 above the line, which on a one-line composer
    /// is a gap over the text and none under it.
    @Test("1.45 is the distance between lines, not padding around one")
    func lineHeightIsBetweenLines() throws {
        let host = try hosted()
        let view = host.textView
        let container = try #require(view.textContainer)
        let manager = try #require(view.layoutManager)

        let font = try #require(view.font)
        let natural = Double(manager.defaultLineHeight(for: font))
        let pitch = Double(font.pointSize) * Metrics.lineHeight

        // One line keeps its natural height, so it sits centred in the
        // composer's own padding rather than under a band of leading.
        view.string = "one"
        view.didChangeText()
        manager.ensureLayout(for: container)
        let single = Double(manager.usedRect(for: container).height)
        #expect(
            abs(single - natural) < 0.5,
            "one line measured \(single), its natural height is \(natural)")

        // The caret spans that line and nothing more.
        let caret = manager.boundingRect(
            forGlyphRange: NSRange(location: 0, length: 1), in: container)
        #expect(Double(caret.height) <= natural + 0.5, "the caret is one line tall")

        // A second line starts 18.85 below the first.
        view.string = "one\ntwo"
        view.didChangeText()
        manager.ensureLayout(for: container)
        let measured = Double(manager.usedRect(for: container).height) - single
        #expect(
            abs(measured - pitch) < 0.5,
            "the next line starts \(measured) below, spec §5 wants \(pitch)")
    }
}

/// The welcome state, and the two routes into the composer that are not the
/// keyboard.
///
/// The welcome screen is the first thing in the app that is *only* a look —
/// there is no new model behind it, just a pane deciding what to put above its
/// composer. What is worth testing is the part that is not a look: that the
/// suggestion and the `send ↵` button reach the text view at all, and that the
/// pane leaves the welcome state when it should.
@MainActor
@Suite("Welcome state")
struct WelcomeStateTests {
    private func hosted() throws -> Hosted { try hostComposer() }

    /// Which state a pane is in is the transcript being empty and nothing else,
    /// so there is no second source of truth to drift.
    @Test("a fresh pane is in the welcome state, and sending leaves it")
    func sendingLeavesWelcome() throws {
        let agent = try hosted().agent
        #expect(agent.transcript.isEmpty)

        agent.send("hello")
        #expect(!agent.transcript.isEmpty, "a sent message ends the welcome state")
    }

    /// The suggestion fills the composer rather than sending it — a suggestion
    /// that submitted itself would be a button pretending to be a prompt.
    @Test("the suggestion puts its text in the composer without sending it")
    func suggestionFillsWithoutSending() throws {
        let host = try hosted()
        let agent = host.agent
        let view = host.textView
        let text = "Give me a tour of this project"

        let fill = try #require(agent.setComposerText, "the composer installed no way to fill it")
        fill(text)

        #expect(view.string == text)
        #expect(agent.transcript.isEmpty, "filling the composer must not send")
        #expect(agent.outbox.isEmpty, "nor put anything on the wire")
    }

    /// The caret lands where typing would have left it, so the next keystroke
    /// extends the suggestion instead of replacing it.
    @Test("and leaves the caret at the end of it")
    func suggestionLeavesCaretAtEnd() throws {
        let host = try hosted()
        let agent = host.agent
        let view = host.textView
        let text = "Give me a tour"

        agent.setComposerText?(text)

        #expect(view.selectedRange().location == (text as NSString).length)
        #expect(view.selectedRange().length == 0, "the text is a starting point, not a selection")
    }

    /// The button and Enter are the same action, so they go through the same
    /// closure rather than each having their own idea of what sending means.
    @Test("the send button sends what is in the composer, and empties it")
    func sendButtonSends() throws {
        let host = try hosted()
        let agent = host.agent
        let view = host.textView
        agent.setComposerText?("ship it")

        let submit = try #require(agent.submitComposer, "the composer installed no way to send")
        submit()

        #expect(agent.outbox.count == 1)
        #expect(view.string.isEmpty, "the composer is cleared, as Enter would leave it")
    }

    /// An empty composer sends nothing — the button is disabled for it, but the
    /// rule lives in `send` rather than in the view that draws the button.
    @Test("and sends nothing when the composer is empty")
    func sendButtonIgnoresEmpty() throws {
        let agent = try hosted().agent
        agent.submitComposer?()
        #expect(agent.outbox.isEmpty)
    }
}


/// A window with a real workspace in it, and the composer's `NSTextView`.
///
/// File-scope because three suites want it: the composer's own behaviour, the
/// welcome state, and what a prompt longer than the box does. Each one needs a
/// composer that is genuinely in a window — first responder, laid out, with a
/// live scroll view — because every bug they cover lived in that plumbing
/// rather than in a value.
@MainActor
struct Hosted {
    let workspace: Workspace
    let window: NSWindow
    let agent: AgentSession
    let textView: ComposerTextView
}

@MainActor
func hostComposer() throws -> Hosted {
    let workspace = Workspace()
    let pane = workspace.activeTab!.panes[0].id
    let agent = try #require(workspace.agent(pane))

    let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
        styleMask: [.titled, .resizable], backing: .buffered, defer: false
    )
    window.contentView = NSHostingView(rootView: WorkspaceView().environment(workspace))
    window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
    window.orderBack(nil)
    for _ in 0..<4 {
        _ = NSApplication.shared
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    let view = try #require(Tests_composerViews(in: window.contentView!).first)
    return Hosted(workspace: workspace, window: window, agent: agent, textView: view)
}

/// Every composer text view under `view`, in tree order.
///
/// File-scope rather than a method on one suite, because two suites host a
/// window and have to reach into it for the `NSTextView` the composer wraps.
@MainActor
private func Tests_composerViews(in view: NSView) -> [ComposerTextView] {
    (view as? ComposerTextView).map { [$0] } ?? view.subviews.flatMap(Tests_composerViews(in:))
}

/// A long prompt: what happens past the composer's eight-line cap.
///
/// People paste very large prompts into an agent, so this is the ordinary case
/// rather than an edge one. Everything here was broken at once and for three
/// separate reasons, which is why it gets its own suite: the document reported a
/// capped height, the view's `maxSize` would not let it grow, and nothing kept
/// the caret in view.
@MainActor
@Suite("A prompt past the cap")
struct LongPromptTests {
    /// Twenty lines, which is comfortably past eight at any zoom.
    private func filled() throws -> Hosted {
        let host = try hostComposer()
        host.textView.string = (1...20).map { "line \($0)" }.joined(separator: "\n")
        host.textView.didChangeText()
        host.window.layoutIfNeeded()
        return host
    }

    @Test("the box stops growing at eight lines")
    func theBoxStopsAtEight() throws {
        let host = try filled()
        #expect(host.textView.boxHeight == host.textView.maximumHeight)
    }

    /// The cap is eight lines as the composer lays them out — the first at its
    /// natural height, each one after a full pitch below — not eight pitches.
    @Test("and eight lines is exactly what the cap is")
    func theCapIsEightLines() throws {
        let host = try hostComposer()
        let view = host.textView
        let font = try #require(view.font)
        let manager = try #require(view.layoutManager)

        view.string = (1...Metrics.composerMaxLines).map(String.init).joined(separator: "\n")
        view.didChangeText()

        let eight = view.contentHeight
        #expect(
            abs(eight - view.maximumHeight) < 0.5,
            "eight lines measure \(eight), the cap is \(view.maximumHeight)"
        )
        // And nine do not fit, so the cap is a ceiling rather than a coincidence.
        view.string += "\n9"
        view.didChangeText()
        #expect(view.contentHeight > view.maximumHeight)
        _ = (font, manager)
    }

    /// The bug itself. A document that reports a capped height gives the scroll
    /// view nothing to scroll, and the text past the cap is laid out below the
    /// frame where it cannot be reached at all.
    @Test("but the text keeps growing, so there is something to scroll")
    func theDocumentKeepsGrowing() throws {
        let host = try filled()
        let view = host.textView

        #expect(
            view.contentHeight > view.maximumHeight,
            "twenty lines need more than eight lines' worth of height"
        )
        #expect(
            view.intrinsicContentSize.height == view.contentHeight,
            "the document reports its real height, not the capped one"
        )
        #expect(
            view.frame.height > host.textView.enclosingScrollView!.contentView.bounds.height,
            "the document is taller than the clip, which is what makes it scrollable"
        )
    }

    /// And the symptom: typing at the end of a long prompt must stay visible.
    @Test("and the caret stays visible when typing past the cap")
    func theCaretStaysVisible() throws {
        let host = try filled()
        let view = host.textView
        let manager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)

        // Type one more character at the very end, as a person would.
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("!", replacementRange: view.selectedRange())
        host.window.layoutIfNeeded()

        manager.ensureLayout(for: container)
        let last = NSRange(location: (view.string as NSString).length - 1, length: 1)
        let caret = manager.boundingRect(forGlyphRange: last, in: container)

        #expect(
            view.visibleRect.intersects(caret),
            "the character just typed is at \(caret), visible is \(view.visibleRect)"
        )
    }
}

/// Where the `›` sits relative to the text beside it.
@MainActor
@Suite("Prompt glyph")
struct PromptGlyphTests {
    /// The number handed to SwiftUI as the composer's baseline has to be the one
    /// the text is really laid out on, or the glyph lines up with nothing.
    ///
    /// Held against the first glyph's own baseline rather than recomputed the
    /// same way and agreeing with itself.
    @Test("the baseline handed to the layout is the one the text sits on")
    func theBaselineIsTheRealOne() throws {
        let host = try hostComposer()
        let view = host.textView
        let manager = try #require(view.layoutManager)
        let container = try #require(view.textContainer)

        view.string = "Hg"
        view.didChangeText()
        manager.ensureLayout(for: container)

        // The glyph's origin is its baseline, given relative to its line
        // fragment; the fragment is placed relative to the container.
        let fragment = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
        let measured =
            fragment.origin.y
            + manager.location(forGlyphAt: 0).y
            + view.textContainerOrigin.y

        let handed = Composer.firstBaseline(at: try #require(view.font).pointSize)

        #expect(
            abs(handed - measured) < 0.5,
            "handed \(handed) to the layout, the text sits on \(measured)"
        )
    }

    /// And it stays on the first line, so a prompt that has grown to eight lines
    /// does not drag the glyph down the box with it.
    @Test("and it does not move as the box grows")
    func theBaselineIsFixedToTheFirstLine() throws {
        let host = try hostComposer()
        let size = try #require(host.textView.font).pointSize
        let oneLine = Composer.firstBaseline(at: size)

        host.textView.string = (1...20).map(String.init).joined(separator: "\n")
        host.textView.didChangeText()

        #expect(Composer.firstBaseline(at: size) == oneLine)
    }
}

/// Keys whose meaning prose decides rather than AppKit, driven as real events.
///
/// Every bug in this suite was a routing bug — the right edit existed and the
/// key never reached it — so asserting on selectors would prove nothing. These
/// go through `keyDown` and AppKit's own binding table.
@MainActor
@Suite("Composer keys")
struct ComposerKeyTests {
    private func press(
        _ host: Hosted, _ keyCode: UInt16, _ characters: String,
        _ flags: NSEvent.ModifierFlags
    ) throws {
        #expect(host.window.makeFirstResponder(host.textView), "the composer took the keyboard")
        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: host.window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode
            )
        )
        host.textView.keyDown(with: event)
    }

    /// Delete is keyCode 51 — the one above Return, not forward-delete.
    private func pressDelete(_ host: Hosted, _ flags: NSEvent.ModifierFlags) throws {
        try press(host, 51, "\u{8}", flags)
    }

    /// macOS binds Cmd+Delete to `noop:` in a text view, so this is prose's own
    /// edit rather than an inherited one.
    @Test("Cmd+Delete deletes back to the start of the line")
    func commandDeleteClearsTheLine() throws {
        let host = try hostComposer()
        host.textView.string = "hello there world"
        host.textView.setSelectedRange(NSRange(location: 17, length: 0))

        try pressDelete(host, [.command])

        #expect(host.textView.string.isEmpty, "the whole line went")
    }

    /// It is the *line*, not the whole buffer — a prompt of several lines keeps
    /// the ones the caret is not on.
    @Test("and only that line, not the ones above it")
    func commandDeleteKeepsEarlierLines() throws {
        let host = try hostComposer()
        host.textView.string = "first line\nsecond line"
        host.textView.setSelectedRange(NSRange(location: 22, length: 0))

        try pressDelete(host, [.command])

        #expect(host.textView.string == "first line\n")
    }

    /// The two neighbouring bindings still belong to AppKit, and must not have
    /// been captured on the way past.
    @Test("plain and Option+Delete are left to AppKit")
    func otherDeletesAreUntouched() throws {
        let host = try hostComposer()
        host.textView.string = "hello there world"
        host.textView.setSelectedRange(NSRange(location: 17, length: 0))

        try pressDelete(host, [])
        #expect(host.textView.string == "hello there worl", "plain Delete takes one character")

        try pressDelete(host, [.option])
        #expect(host.textView.string == "hello there ", "Option+Delete takes the word")
    }
}

/// Which region the keyboard is aimed at, and what Return means there.
@MainActor
@Suite("Tab strip keys")
struct TabStripKeyTests {
    /// The bug: `.onKeyPress(.return)` matches the key and ignores the
    /// modifiers, so Shift+Enter — which spec §9.5 says inserts a newline —
    /// opened the tab rename field instead.
    ///
    /// The state it needs is ordinary: Escape in a composer with no turn running
    /// hands the keyboard back to the strip (spec §9.6), and a cold launch
    /// starts there, so this was reachable without doing anything unusual.
    @Test("Escape with no turn running gives the keyboard back to the strip")
    func escapeResigns() throws {
        let host = try hostComposer()
        #expect(!host.agent.transcript.isRunning)

        host.textView.cancelOperation(nil)

        #expect(
            host.workspace.keyboardOwner == .tabStrip,
            "this is the state in which Return means rename"
        )
    }

    /// The regression itself, driven through the window so SwiftUI's own
    /// `.onKeyPress` handler is the thing under test.
    ///
    /// Sent with `sendEvent` rather than called on a view, because the handler
    /// belongs to a SwiftUI modifier and there is no object to poke directly.
    private func sendReturn(_ host: Hosted, _ flags: NSEvent.ModifierFlags) throws {
        // The strip owns the keyboard, and nothing inside the content area holds
        // first responder — which is the state a cold launch and an Escape both
        // leave the window in.
        host.workspace.keyboardOwner = .tabStrip
        host.window.makeFirstResponder(host.window.contentView)

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: host.window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                keyCode: 36
            )
        )
        host.window.sendEvent(event)
        CFRunLoopRunInMode(.defaultMode, 0.05, false)
    }

    /// An AppKit text view consumes the click that gives it first responder,
    /// so the pane's outer SwiftUI tap gesture cannot be the only thing that
    /// changes keyboard ownership. If it is, the workspace sees this plain
    /// Return first and opens the tab rename field instead of letting the
    /// composer send.
    @Test("Return sends when the composer took focus directly")
    func focusedComposerClaimsReturn() throws {
        let host = try hostComposer()
        host.workspace.keyboardOwner = .tabStrip
        host.textView.string = "hello"

        #expect(host.window.makeFirstResponder(host.textView))
        #expect(
            host.workspace.keyboardOwner == .content,
            "the workspace follows the control that actually has the caret"
        )

        let event = try #require(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: host.window.windowNumber, context: nil,
                characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false,
                keyCode: 36
            )
        )
        host.window.sendEvent(event)
        CFRunLoopRunInMode(.defaultMode, 0.05, false)

        #expect(host.workspace.rename == nil)
        #expect(host.agent.transcript.blocks.count == 1)
        #expect(host.textView.string.isEmpty)
    }

    @Test("Shift+Return does not start a rename")
    func shiftReturnDoesNotRename() throws {
        let host = try hostComposer()
        try sendReturn(host, [.shift])

        #expect(
            host.workspace.rename == nil,
            "Shift+Enter is a newline (spec §9.5), never a rename"
        )
    }

    /// And in that state a rename is what an *unmodified* Return starts.
    @Test("a rename starts and can be abandoned")
    func renameRoundTrips() throws {
        let host = try hostComposer()
        let active = try #require(host.workspace.active)

        host.workspace.beginRename(active)
        #expect(host.workspace.rename?.tab == active)

        host.workspace.cancelRename()
        #expect(host.workspace.rename == nil)
    }
}
