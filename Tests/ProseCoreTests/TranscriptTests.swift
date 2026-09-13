import Testing

@testable import ProseCore

/// The thirteen tests from `transcript.rs`. Most of them exist to pin down the
/// reducer's totality (spec §10) rather than its happy path, so they are the
/// part of this port least worth rewriting.
@Suite("Transcript")
struct TranscriptTests {
    private func start(_ id: String) -> Event {
        .messageStart(id: id, role: .agent)
    }

    private func delta(_ id: String, _ text: String) -> Event {
        .delta(id: id, text: text)
    }

    private func activity(
        _ id: String, _ label: String, _ state: ActivityState, _ category: String? = nil
    ) -> Event {
        .activity(id: id, label: label, detail: nil, state: state, category: category)
    }

    /// The text of the one message block, for the streaming tests.
    private func onlyMessage(_ transcript: Transcript) throws -> (String, Bool) {
        guard transcript.blocks.count == 1,
              case .message(_, _, let text, let streaming) = transcript.blocks[0]
        else {
            Issue.record("expected one message block, got \(transcript.blocks)")
            throw ExpectationFailure()
        }
        return (text, streaming)
    }

    private struct ExpectationFailure: Error {}

    @Test("deltas accumulate into the block they name")
    func deltasAccumulate() throws {
        var transcript = Transcript()
        transcript.apply(start("b1"))
        transcript.apply(delta("b1", "hel"))
        transcript.apply(delta("b1", "lo"))

        #expect(try onlyMessage(transcript) == ("hello", true))

        transcript.apply(.messageEnd(id: "b1"))
        #expect(try onlyMessage(transcript) == ("hello", false))
    }

    @Test("two blocks stream independently and in order")
    func blocksStreamIndependently() throws {
        var transcript = Transcript()
        transcript.apply(start("a"))
        transcript.apply(start("b"))
        // Out of order on purpose: the older block is not the last one.
        transcript.apply(delta("b", "second"))
        transcript.apply(delta("a", "first"))

        guard transcript.blocks.count == 2,
              case .message(_, _, let first, _) = transcript.blocks[0],
              case .message(_, _, let second, _) = transcript.blocks[1]
        else {
            Issue.record("expected two messages, got \(transcript.blocks)")
            throw ExpectationFailure()
        }
        #expect(first == "first")
        #expect(second == "second")
    }

    @Test("a delta for a block that was never opened is dropped")
    func deltaForAnUnopenedBlock() {
        // A half-written agent will do this. It must not trap and it must not
        // silently invent a block, which would hide the mistake.
        var transcript = Transcript()
        transcript.apply(delta("ghost", "hello"))

        #expect(transcript.isEmpty)
    }

    @Test("ending a block twice or ending an unknown one is harmless")
    func endingTwiceIsHarmless() throws {
        var transcript = Transcript()
        transcript.apply(start("b1"))
        transcript.apply(.messageEnd(id: "b1"))
        transcript.apply(.messageEnd(id: "b1"))
        transcript.apply(.messageEnd(id: "nope"))

        #expect(try onlyMessage(transcript) == ("", false))
    }

    @Test("an activity resolves in place rather than appearing twice")
    func activityResolvesInPlace() throws {
        var transcript = Transcript()
        transcript.apply(activity("a1", "Searching", .running))
        transcript.apply(activity("a1", "Searched", .ok))

        guard transcript.blocks.count == 1,
              case .activity(_, let label, _, let state, _) = transcript.blocks[0]
        else {
            Issue.record("expected exactly one row, got \(transcript.blocks)")
            throw ExpectationFailure()
        }
        #expect(label == "Searched")
        #expect(state == .ok)
    }

    @Test("resolving an activity keeps a detail it no longer repeats")
    func resolvingKeepsTheDetail() throws {
        var transcript = Transcript()
        transcript.apply(
            .activity(id: "a1", label: "Searching", detail: "40 sources", state: .running, category: nil)
        )
        transcript.apply(activity("a1", "Searching", .ok))

        guard case .activity(_, _, let detail, _, _)? = transcript.blocks.first else {
            Issue.record("expected one row")
            throw ExpectationFailure()
        }
        #expect(detail == "40 sources")
    }

    @Test("a turn flips the running flag and closes anything still streaming")
    func turnClosesStreamingBlocks() throws {
        var transcript = Transcript()
        #expect(!transcript.isRunning)

        transcript.apply(.turn(state: .started, error: nil))
        #expect(transcript.isRunning)

        transcript.apply(start("b1"))
        transcript.apply(.turn(state: .ended, error: nil))

        #expect(!transcript.isRunning)
        // The agent never sent `message.end`, but the turn is over, so nothing
        // should still be drawing a caret.
        #expect(try onlyMessage(transcript) == ("", false))
    }

    @Test("a failed turn leaves a notice behind")
    func failedTurnLeavesANotice() {
        var transcript = Transcript()
        transcript.apply(.turn(state: .failed, error: "rate limited"))

        #expect(!transcript.isRunning)
        #expect(transcript.blocks == [.notice(message: "rate limited")])
    }

    @Test("status fields merge rather than replace")
    func statusFieldsMerge() {
        var transcript = Transcript()
        transcript.apply(.status(fields: ["model": "a", "cost": "$1"]))
        transcript.apply(.status(fields: ["cost": "$2"]))

        #expect(transcript.status["model"] == "a", "untouched key survives")
        #expect(transcript.status["cost"] == "$2", "and the new one wins")
    }

    @Test("asking stays pending until it is answered")
    func askStaysPending() {
        var transcript = Transcript()
        transcript.pushAsk(id: .number(7), prompt: "Which one?", choices: ["a", "b"], placeholder: nil)

        #expect(transcript.pendingAsk != nil)

        let id = transcript.answerAsk("a")
        #expect(id == .number(7), "the id to reply on")
        #expect(transcript.pendingAsk == nil)

        // And a second answer has nothing left to resolve.
        let again = transcript.answerAsk("b")
        #expect(again == nil)
    }

    @Test("two questions are answered oldest first")
    func questionsAnsweredOldestFirst() {
        var transcript = Transcript()
        transcript.pushAsk(id: .number(1), prompt: "first", choices: [], placeholder: nil)
        transcript.pushAsk(id: .number(2), prompt: "second", choices: [], placeholder: nil)

        let first = transcript.answerAsk("x")
        let second = transcript.answerAsk("y")
        #expect(first == .number(1))
        #expect(second == .number(2))
    }

    @Test("a notice stops the spinner")
    func noticeStopsTheSpinner() throws {
        // This is how a pane reports its agent dying, and a pane left spinning
        // after its process is gone would be a lie.
        var transcript = Transcript()
        transcript.apply(.turn(state: .started, error: nil))
        transcript.apply(start("b1"))

        transcript.pushNotice("agent exited (code 1)")

        #expect(!transcript.isRunning)
        guard transcript.blocks.count == 2,
              case .message(_, _, _, let streaming) = transcript.blocks[0],
              case .notice = transcript.blocks[1]
        else {
            Issue.record("expected a message and a notice, got \(transcript.blocks)")
            throw ExpectationFailure()
        }
        #expect(!streaming)
    }

    @Test("the user's own message lands above the reply")
    func userMessageLandsFirst() throws {
        var transcript = Transcript()
        transcript.pushUser("hello")
        transcript.apply(start("b1"))
        transcript.apply(delta("b1", "hi"))

        guard transcript.blocks.count == 2,
              case .message(_, let first, _, _) = transcript.blocks[0],
              case .message(_, let second, _, _) = transcript.blocks[1]
        else {
            Issue.record("expected two messages")
            throw ExpectationFailure()
        }
        #expect(first == .user)
        #expect(second == .agent)
    }

    // MARK: - Reasoning

    @Test("thinking opens a block of its own, not a message")
    func thinkingIsNotAMessage() throws {
        var transcript = Transcript()
        transcript.apply(.messageStart(id: "t1", role: .thinking))
        transcript.apply(delta("t1", "weighing it up"))

        guard case .thinking(_, let text, let streaming, let collapsed)? = transcript.blocks.first
        else {
            Issue.record("expected a thinking block, got \(transcript.blocks)")
            throw ExpectationFailure()
        }
        #expect(text == "weighing it up", "it streams through the same deltas")
        #expect(streaming)
        #expect(!collapsed, "open while it is the only thing happening")
    }

    @Test("a turn ending closes reasoning and folds it away")
    func thinkingCollapsesWithTheTurn() throws {
        var transcript = Transcript()
        transcript.apply(.turn(state: .started, error: nil))
        transcript.apply(.messageStart(id: "t1", role: .thinking))
        transcript.apply(delta("t1", "still going"))
        transcript.apply(.turn(state: .ended, error: nil))

        guard case .thinking(_, _, let streaming, let collapsed)? = transcript.blocks.first else {
            Issue.record("expected a thinking block")
            throw ExpectationFailure()
        }
        #expect(!streaming, "closed like any other dangling block")
        #expect(collapsed, "and folded, since there is an answer above it now")
    }

    @Test("reasoning can be opened and closed again")
    func thinkingToggles() throws {
        var transcript = Transcript()
        transcript.apply(.messageStart(id: "t1", role: .thinking))
        transcript.apply(.messageEnd(id: "t1"))

        transcript.toggleThinking(at: 0)
        guard case .thinking(_, _, _, let collapsed)? = transcript.blocks.first else {
            Issue.record("expected a thinking block")
            throw ExpectationFailure()
        }
        #expect(collapsed)

        transcript.toggleThinking(at: 0)
        #expect(transcript.blocks.first != nil)
    }

    @Test("toggling anything else, or nothing, is a no-op")
    func toggleIsTotal() {
        // A view holds an index, and an index can go stale between a click and
        // the fold seeing it.
        var transcript = Transcript()
        transcript.apply(start("m1"))
        let before = transcript.blocks

        transcript.toggleThinking(at: 0)
        transcript.toggleThinking(at: 99)
        #expect(transcript.blocks == before)
    }

    @Test("a category survives a resolving update, like a detail")
    func categoryIsKept() throws {
        var transcript = Transcript()
        transcript.apply(activity("a1", "Skill", .running, "skill"))
        transcript.apply(activity("a1", "Skill", .ok))

        guard case .activity(_, _, _, let state, let category)? = transcript.blocks.first else {
            Issue.record("expected one row")
            throw ExpectationFailure()
        }
        #expect(state == .ok)
        #expect(category == "skill", "resolving says what happened, not what sort of step it was")
    }
}

/// `hasConversation`, which is what the agent pane's welcome state keys off.
@Suite("Has conversation")
struct HasConversationTests {
    @Test("a fresh transcript has none")
    func freshHasNone() {
        #expect(!Transcript().hasConversation)
    }

    /// The case this property exists for: an agent that fails to start pushes a
    /// notice within a moment of the pane opening, and that must not count as
    /// the conversation having begun.
    @Test("a notice alone is not a conversation")
    func noticeIsNotConversation() {
        var transcript = Transcript()
        transcript.pushNotice("agent exited (code 2)")

        #expect(!transcript.isEmpty, "the notice is in the transcript")
        #expect(!transcript.hasConversation, "but nothing has been said")
    }

    /// Nor is anything else the agent does on its own behalf.
    @Test("nor is an activity or an attachment")
    func activityIsNotConversation() {
        var transcript = Transcript()
        transcript.apply(.activity(id: "a1", label: "Searching", detail: nil, state: .running, category: nil))
        transcript.apply(
            .attachment(Attachment(id: "x1", kind: "code", language: "swift", text: "let x = 1"))
        )

        #expect(!transcript.hasConversation)
    }

    @Test("a message from either side is")
    func messageIsConversation() {
        var fromUser = Transcript()
        fromUser.pushUser("hello")
        #expect(fromUser.hasConversation)

        var fromAgent = Transcript()
        fromAgent.apply(.messageStart(id: "m1", role: .agent))
        fromAgent.apply(.delta(id: "m1", text: "hello"))
        #expect(fromAgent.hasConversation, "an agent that speaks first also starts one")
    }

    @Test("reasoning alone does not count as a conversation")
    func thinkingDoesNotLeaveTheWelcomeScreen() {
        // The measured reason `hasConversation` is not `isEmpty` applies here
        // too: if reasoning counted, every turn would take a pane out of its
        // welcome state before the agent had said a word.
        var transcript = Transcript()
        transcript.apply(.messageStart(id: "t1", role: .thinking))
        transcript.apply(.delta(id: "t1", text: "hm"))
        #expect(!transcript.hasConversation)

        transcript.apply(.messageStart(id: "m1", role: .agent))
        #expect(transcript.hasConversation, "but prose does")
    }
}
