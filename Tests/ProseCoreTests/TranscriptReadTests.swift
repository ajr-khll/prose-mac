import Testing

@testable import ProseCore

/// Reading someone else's transcript — the primitive a supervising parent
/// stands on, and the one place in the port where token cost is a correctness
/// property rather than a nicety.
@Suite("Transcript reading")
struct TranscriptReadTests {
    /// A transcript with one turn's worth of everything in it.
    private func turn() -> Transcript {
        var t = Transcript()
        t.pushUser("Port the split tree tests to swift-testing.")
        t.apply(.turn(state: .started, error: nil))
        t.apply(.activity(id: "a1", label: "Bash(swift test)", detail: nil, state: .running, category: nil))
        t.apply(.activity(id: "a1", label: "Bash(swift test)", detail: "95 passed", state: .ok, category: nil))
        t.apply(.messageStart(id: "m1", role: .agent))
        t.apply(.delta(id: "m1", text: "All eleven split tests pass."))
        t.apply(.messageEnd(id: "m1"))
        t.apply(.attachment(Attachment(id: "x1", kind: "code", language: "swift", text: "let a = 1")))
        t.apply(.turn(state: .ended, error: nil))
        return t
    }

    private func blocks(_ value: JSONValue) -> [JSONValue] {
        value["blocks"]?.array ?? []
    }

    // MARK: - The cursor

    @Test("an activity resolving in place still moves the cursor")
    func inPlaceChangesAreVisible() {
        // This is why `blocks.count` cannot be the cursor. The second activity
        // rewrites an *earlier* index without growing the transcript, so a
        // count-based cursor would report nothing had happened.
        var t = Transcript()
        t.apply(.activity(id: "a1", label: "Searching", detail: "40 sources", state: .running, category: nil))
        t.apply(.messageStart(id: "m1", role: .agent))
        let mark = t.clock

        t.apply(.activity(id: "a1", label: "Searching", detail: nil, state: .ok, category: nil))

        #expect(t.blocks.count == 2, "nothing was appended")
        #expect(t.clock > mark, "but something changed")
        let changed = t.changed(since: mark)
        #expect(changed.count == 1)
        #expect(changed.first?.index == 0, "the activity, at its original index")
    }

    @Test("a delta moves the cursor without moving the block")
    func deltasAreVisible() {
        var t = Transcript()
        t.apply(.messageStart(id: "m1", role: .agent))
        let mark = t.clock
        t.apply(.delta(id: "m1", text: "hello"))

        #expect(t.changed(since: mark).count == 1)
        #expect(t.changed(since: t.clock).isEmpty, "and nothing is newer than now")
    }

    @Test("a read hands back a cursor that catches the reader up")
    func cursorCatchesUp() {
        let t = turn()
        let first = t.read(ReadQuery())
        #expect(Int(first["cursor"]?.int ?? -1) == t.clock)

        let second = t.read(ReadQuery(since: Int(first["cursor"]!.int!)))
        #expect(blocks(second).isEmpty, "a second read costs nothing")
    }

    // MARK: - Fidelity

    @Test("a summary previews prose and counts it, rather than sending it")
    func summaryPreviews() throws {
        var t = Transcript()
        let long = String(repeating: "word ", count: 200)
        t.apply(.messageStart(id: "m1", role: .agent))
        t.apply(.delta(id: "m1", text: long))
        t.apply(.messageEnd(id: "m1"))

        let block = try #require(blocks(t.read(ReadQuery())).first)
        #expect(block["k"]?.string == "agent")
        #expect(Int(block["n"]?.int ?? 0) == long.count)
        #expect(block["head"]?.string?.count == Transcript.headLength)
        #expect(block["text"] == nil, "the body is exactly what a summary leaves out")
    }

    @Test("a zoom brings back one block in full and ignores the filters")
    func zoomIsAddressedByIndex() throws {
        let t = turn()
        // Index, not id: notices have no id and user messages use an empty one,
        // so an index is the only address every block has.
        let read = t.read(ReadQuery(since: 999, block: 2, kinds: ["notice"]))
        let block = try #require(blocks(read).first)
        #expect(block["i"]?.int == 2)
        #expect(block["text"]?.string == "All eleven split tests pass.")
    }

    @Test("an out-of-range zoom is empty rather than a crash")
    func zoomIsTotal() {
        #expect(blocks(turn().read(ReadQuery(block: 99))).isEmpty)
    }

    @Test("an activity is the same at either fidelity")
    func activitiesAreAlreadySummaries() {
        let t = turn()
        let summary = blocks(t.read(ReadQuery(fidelity: .summary, kinds: ["act"])))
        let full = blocks(t.read(ReadQuery(fidelity: .full, kinds: ["act"])))
        #expect(summary == full)
    }

    @Test("an ask is always full, because it is what the parent must act on")
    func asksAreNeverSummarised() throws {
        var t = Transcript()
        t.pushAsk(id: .number(1), prompt: "Which axis?", choices: ["row", "column"], placeholder: nil)

        let block = try #require(blocks(t.read(ReadQuery())).first)
        #expect(block["prompt"]?.string == "Which axis?")
        #expect(block["choices"]?.stringArray == ["row", "column"])
        #expect(block["answer"] == .null)
    }

    @Test("reasoning summarises to a bare count, with no preview at all")
    func thinkingHasNoHead() throws {
        // The single largest saving in the read, and the reason a distinct
        // block kind earns its keep: reasoning is usually the biggest thing in
        // a turn and the thing a supervising parent least often needs.
        var t = Transcript()
        t.apply(.messageStart(id: "t1", role: .thinking))
        t.apply(.delta(id: "t1", text: String(repeating: "reasoning ", count: 500)))
        t.apply(.messageEnd(id: "t1"))

        let summary = try #require(blocks(t.read(ReadQuery())).first)
        #expect(summary["k"]?.string == "thinking")
        #expect(summary["n"]?.int == 5000)
        #expect(summary["head"] == nil, "not even a preview")
        #expect(summary["text"] == nil)

        // A deliberate zoom still gives it whole — it is hidden from the scan,
        // not withheld.
        let zoomed = try #require(blocks(t.read(ReadQuery(block: 0))).first)
        #expect(zoomed["text"]?.string?.count == 5000)
    }

    @Test("an activity's category rides along in the summary")
    func categoryIsSummarised() throws {
        var t = Transcript()
        t.apply(
            .activity(id: "a1", label: "Skill", detail: "swift-testing", state: .ok, category: "skill"))

        let block = try #require(blocks(t.read(ReadQuery())).first)
        #expect(block["category"]?.string == "skill")
    }

    // MARK: - Filtering

    @Test("kinds filter, and the cursor still moves past what was skipped")
    func filteringDoesNotStrandTheCursor() {
        let t = turn()
        let read = t.read(ReadQuery(kinds: ["act"]))
        #expect(blocks(read).count == 1)
        #expect(
            Int(read["cursor"]?.int ?? -1) == t.clock,
            "a filtered-out block is still seen, or the next read rescans it")
    }

    @Test("match searches what a reader would have read")
    func matchIsTheOneThingALogWasBetterAt() {
        let t = turn()
        #expect(blocks(t.read(ReadQuery(match: "eleven"))).count == 1)
        #expect(blocks(t.read(ReadQuery(match: "ELEVEN"))).count == 1, "case-insensitively")
        #expect(blocks(t.read(ReadQuery(match: "nothing here"))).isEmpty)
    }

    @Test("a malformed match is ignored rather than refused")
    func matchIsTotal() {
        // spec §10's rule, one level down from the method name: a bad pattern
        // is an agent bug, and dropping the whole read would tell it less than
        // an unfiltered answer does.
        #expect(!blocks(turn().read(ReadQuery(match: "[unclosed"))).isEmpty)
    }

    // MARK: - The ceiling

    @Test("a limit truncates and leaves the cursor on the last block that fitted")
    func limitIsResumable() {
        let t = turn()
        let first = t.read(ReadQuery(limit: 2))
        #expect(blocks(first).count == 2)
        #expect(first["truncated"] == .bool(true))

        let second = t.read(ReadQuery(since: Int(first["cursor"]!.int!)))
        #expect(blocks(second).count == blocks(t.read(ReadQuery())).count - 2, "and it resumes")
    }

    @Test("one enormous attachment cannot blow the reader's context")
    func theBudgetIsNotNegotiable() {
        // A child that attaches five megabytes would otherwise cost its parent
        // everything in a single call, and the parent cannot know in advance.
        var t = Transcript()
        t.pushUser("go")
        for index in 0..<8 {
            t.apply(
                .attachment(
                    Attachment(
                        id: "x\(index)", kind: "text", language: nil,
                        text: String(repeating: "x", count: 100_000))))
        }

        let read = t.read(ReadQuery(fidelity: .full))
        #expect(read["truncated"] == .bool(true))
        #expect(read.line().utf8.count < Transcript.replyBudget * 2, "capped, not merely flagged")
        #expect(!blocks(read).isEmpty, "and at least one block always comes back")
    }

    // MARK: - The saving this whole design exists for

    @Test("a summary is an order of magnitude cheaper than the full turn")
    func theRatioHolds() {
        var t = Transcript()
        t.pushUser("Port the split tree tests.")
        // Thinking is the biggest block in a real turn and the one a parent
        // least often needs, which is why it summarises to a bare count.
        t.apply(.messageStart(id: "m1", role: .agent))
        t.apply(.delta(id: "m1", text: String(repeating: "reasoning ", count: 900)))
        t.apply(.messageEnd(id: "m1"))
        t.apply(.attachment(Attachment(id: "x1", kind: "code", language: "swift", text: String(repeating: "let a = 1\n", count: 180))))

        let full = t.read(ReadQuery(fidelity: .full)).line().utf8.count
        let summary = t.read(ReadQuery(fidelity: .summary)).line().utf8.count

        #expect(summary * 10 < full, "the two-stage read has to actually pay for itself")
    }
}
