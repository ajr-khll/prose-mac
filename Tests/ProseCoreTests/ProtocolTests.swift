import Foundation
import Testing

@testable import ProseCore

/// The sixteen tests from `protocol.rs`. They are the closest thing to a
/// specification the agent side has, so they are ported as fixtures rather
/// than rewritten around the Swift types.
@Suite("Protocol")
struct ProtocolTests {
    /// The event inside a line that is expected to carry one.
    private func event(of line: String) throws -> Event {
        guard case .notification(.event(_, let event))? = parseLine(line) else {
            Issue.record("expected an event, got \(String(describing: parseLine(line)))")
            throw ExpectationFailure()
        }
        return event
    }

    /// What `to_line` produced, read back as JSON so assertions can be made
    /// about the shape rather than about member order.
    private func sent(_ outgoing: Outgoing) throws -> JSONValue {
        let line = outgoing.line()
        let data = try #require(line.data(using: .utf8))
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    private struct ExpectationFailure: Error {}

    @Test("a method with an id is a request and one without is a notification")
    func requestsAndNotifications() {
        let hello = """
            {"jsonrpc":"2.0","id":1,"method":"hello",
             "params":{"session":3,"token":"t","name":"researcher"}}
            """

        #expect(
            parseLine(hello)
                == .request(
                    id: .number(1),
                    call: .hello(session: 3, token: "t", name: "researcher")
                )
        )

        let closed = #"{"jsonrpc":"2.0","method":"pane.close","params":{"pane":2}}"#
        #expect(parseLine(closed) == .notification(call: .closePane(pane: 2)))
    }

    @Test("a string id survives so it can be echoed back verbatim")
    func stringIDsSurvive() throws {
        // JSON-RPC allows either, and normalising one into the other would
        // leave the agent unable to match our reply to its request.
        let line = #"{"id":"ask-7","method":"ask","params":{"session":1,"prompt":"?"}}"#

        guard case .request(let id, _)? = parseLine(line) else {
            Issue.record("expected a request")
            throw ExpectationFailure()
        }
        #expect(id == .text("ask-7"))
    }

    @Test("an unknown method is ignored rather than failing the connection")
    func unknownMethodIsIgnored() {
        // The agent is written separately and will grow vocabulary first. If
        // this ever returns an error, the two sides can no longer ship apart.
        let line = #"{"jsonrpc":"2.0","method":"pane.wobble","params":{"pane":1}}"#
        #expect(parseLine(line) == nil)
    }

    @Test("an unknown event kind is ignored too")
    func unknownEventKindIsIgnored() {
        let line = """
            {"method":"event","params":{"session":1,
             "event":{"kind":"hologram","id":"x"}}}
            """
        #expect(parseLine(line) == nil)
    }

    @Test("rubbish lines are dropped instead of killing the connection")
    func rubbishIsDropped() {
        for line in ["", "   ", "not json", "[1,2,3]", "{}", #"{"method":"event"}"#] {
            #expect(parseLine(line) == nil, "line was \(line)")
        }
    }

    @Test("a message streams as a start then deltas then an end")
    func messageStreaming() throws {
        #expect(
            try event(
                of: """
                    {"method":"event","params":{"session":1,
                     "event":{"kind":"message.start","id":"b1","role":"agent"}}}
                    """) == .messageStart(id: "b1", role: .agent)
        )
        #expect(
            try event(
                of: """
                    {"method":"event","params":{"session":1,
                     "event":{"kind":"delta","id":"b1","text":"hel"}}}
                    """) == .delta(id: "b1", text: "hel")
        )
        #expect(
            try event(
                of: """
                    {"method":"event","params":{"session":1,
                     "event":{"kind":"message.end","id":"b1"}}}
                    """) == .messageEnd(id: "b1")
        )
    }

    @Test("an unknown role is taken to be the agent talking")
    func unknownRoleIsTheAgent() throws {
        let start = try event(
            of: """
                {"method":"event","params":{"session":1,
                 "event":{"kind":"message.start","id":"b1","role":"oracle"}}}
                """)
        #expect(start == .messageStart(id: "b1", role: .agent))
    }

    @Test("an activity defaults to running and carries an optional detail")
    func activityDefaults() throws {
        #expect(
            try event(
                of: """
                    {"method":"event","params":{"session":1,
                     "event":{"kind":"activity","id":"a1","label":"Searching"}}}
                    """)
                == .activity(id: "a1", label: "Searching", detail: nil, state: .running, category: nil)
        )

        #expect(
            try event(
                of: """
                    {"method":"event","params":{"session":1,
                     "event":{"kind":"activity","id":"a1","label":"Searching",
                              "detail":"40 sources","state":"ok"}}}
                    """)
                == .activity(id: "a1", label: "Searching", detail: "40 sources", state: .ok, category: nil)
        )
    }

    @Test("an attachment of an unfamiliar type keeps its text")
    func unfamiliarAttachmentKeepsItsText() throws {
        // It will render as plain text rather than vanishing, which is the
        // whole point of leaving `kind` a string.
        guard case .attachment(let attachment) = try event(
            of: """
                {"method":"event","params":{"session":1,
                 "event":{"kind":"attachment","id":"x1","type":"spreadsheet","text":"a,b"}}}
                """)
        else {
            Issue.record("expected an attachment")
            throw ExpectationFailure()
        }

        #expect(attachment.kind == "spreadsheet")
        #expect(attachment.text == "a,b")
        #expect(attachment.language == nil)
    }

    @Test("creating a pane carries the command prose will supervise")
    func createPaneCarriesItsCommand() throws {
        let line = """
            {"id":2,"method":"pane.create","params":{
             "from":1,"axis":"row","command":["python3","-m","worker"],
             "cwd":"/tmp","env":{"KEY":"v"},"title":"worker"}}
            """

        guard case .request(_, .createPane(let from, let axis, let placement, let kind, let command, let cwd, let env, let title, _))? =
            parseLine(line)
        else {
            Issue.record("expected a pane.create request")
            throw ExpectationFailure()
        }

        #expect(from == 1)
        #expect(axis == .row)
        #expect(placement == .after, "the default, when the field is absent")
        #expect(kind == .agent, "the default, when the field is absent")
        #expect(command == ["python3", "-m", "worker"])
        #expect(cwd == "/tmp")
        #expect(env["KEY"] == "v")
        #expect(title == "worker")
    }

    /// The one case `placement` exists for: a pilot putting the page above
    /// itself. An unknown value falls back rather than failing the call.
    @Test("a placement is read, and a nonsense one is not fatal")
    func createPaneWithPlacement() throws {
        let above = #"""
        {"id":4,"method":"pane.create","params":{"from":1,"axis":"column","placement":"before","kind":"browser","url":"http://x"}}
        """#
        guard case .request(_, .createPane(_, _, let placement, _, _, _, _, _, _))? =
            parseLine(above)
        else {
            Issue.record("expected a pane.create request")
            throw ExpectationFailure()
        }
        #expect(placement == .before)

        let nonsense = #"""
        {"id":5,"method":"pane.create","params":{"from":1,"axis":"row","placement":"sideways"}}
        """#
        guard case .request(_, .createPane(_, _, let fallback, _, _, _, _, _, _))? =
            parseLine(nonsense)
        else {
            Issue.record("a misspelled placement must not lose the pane")
            throw ExpectationFailure()
        }
        #expect(fallback == .after)
    }

    @Test("creating a pane without the optional fields still parses")
    func createPaneWithoutOptionals() throws {
        let line = """
            {"id":2,"method":"pane.create",
             "params":{"from":1,"axis":"column","command":["agent"]}}
            """

        guard case .request(_, .createPane(_, let axis, _, _, _, let cwd, let env, _, _))? = parseLine(line)
        else {
            Issue.record("expected a pane.create request")
            throw ExpectationFailure()
        }

        #expect(axis == .column)
        #expect(cwd == nil)
        #expect(env.isEmpty)
    }

    @Test("an ask without choices is a free-text question")
    func askWithoutChoices() throws {
        let line = #"{"id":9,"method":"ask","params":{"session":1,"prompt":"Which?"}}"#

        guard case .request(_, .ask(_, let prompt, let choices, _))? = parseLine(line) else {
            Issue.record("expected an ask request")
            throw ExpectationFailure()
        }

        #expect(prompt == "Which?")
        #expect(choices.isEmpty, "answered by typing rather than clicking")
    }

    @Test("what we send is valid JSON-RPC on one line")
    func outgoingIsValidJSONRPC() throws {
        let message = Outgoing.message(session: 4, text: "go")
        let value = try sent(message)

        #expect(value["jsonrpc"]?.string == "2.0")
        #expect(value["method"]?.string == "message")
        #expect(value["params"]?["session"]?.int == 4)
        #expect(value["params"]?["text"]?.string == "go")
        #expect(value["id"] == nil, "a notification owes no reply")
        #expect(!message.line().contains("\n"), "one object, one line")
    }

    @Test("a reply echoes the id it is answering")
    func replyEchoesItsID() throws {
        let reply = Outgoing.reply(id: .text("ask-7"), result: .object(["answer": .string("yes")]))
        let value = try sent(reply)

        #expect(value["id"]?.string == "ask-7")
        #expect(value["result"]?["answer"]?.string == "yes")
    }

    @Test("a failure uses the application error code")
    func failureUsesTheApplicationErrorCode() throws {
        let failure = Outgoing.failure(id: .number(3), message: "no such pane")
        let value = try sent(failure)

        #expect(value["error"]?["code"]?.int == -32000)
        #expect(value["error"]?["message"]?.string == "no such pane")
        #expect(value["result"] == nil)
    }

    @Test("a multi-line string still serialises to a single line")
    func embeddedNewlinesAreEscaped() throws {
        // Framing is by newline, so an embedded one in the payload would split
        // the message in half if it were not escaped.
        let message = Outgoing.message(session: 1, text: "first\nsecond")

        #expect(message.line().split(separator: "\n", omittingEmptySubsequences: false).count == 1)
        #expect(try sent(message)["params"]?["text"]?.string == "first\nsecond")
    }

    // MARK: - The supervision calls

    @Test("a read parses its defaults rather than requiring them")
    func readDefaults() throws {
        guard case .request(_, .readPane(let pane, let query))? =
            parseLine(#"{"jsonrpc":"2.0","id":1,"method":"pane.read","params":{"pane":4}}"#)
        else {
            Issue.record("expected a read")
            throw ExpectationFailure()
        }
        #expect(pane == 4)
        #expect(query.since == 0)
        #expect(query.fidelity == .summary, "the cheapest useful thing")
        #expect(!query.waits, "a read with no timeout does not park")
    }

    @Test("a wait is a read with a timeout and something to wait for")
    func waitIsARead() throws {
        let line = #"""
        {"jsonrpc":"2.0","id":2,"method":"pane.read","params":{"pane":4,"since":142,"until":["turn","ask","exit"],"timeout":60000,"fidelity":"full","kinds":["act"],"match":"error","limit":10}}
        """#
        guard case .request(_, .readPane(_, let query))? = parseLine(line) else {
            Issue.record("expected a read")
            throw ExpectationFailure()
        }
        #expect(query.since == 142)
        #expect(query.until == [.turn, .ask, .exit])
        #expect(query.timeout == 60_000)
        #expect(query.fidelity == .full)
        #expect(query.kinds == ["act"])
        #expect(query.match == "error")
        #expect(query.limit == 10)
        #expect(query.waits)
    }

    @Test("an unknown fidelity or wait reason is dropped, not refused")
    func unknownQueryValuesDegrade() throws {
        // spec §10's rule, one level below the method name: a newer agent's
        // vocabulary must cost it the field, never the call.
        let line = #"""
        {"jsonrpc":"2.0","id":3,"method":"pane.read","params":{"pane":4,"fidelity":"exhaustive","until":["turn","teatime"],"timeout":1000}}
        """#
        guard case .request(_, .readPane(_, let query))? = parseLine(line) else {
            Issue.record("expected a read")
            throw ExpectationFailure()
        }
        #expect(query.fidelity == .summary, "an unknown fidelity falls back")
        #expect(query.until == [.turn], "and an unknown reason is dropped on its own")
    }

    @Test("a read with no id is dropped: there is nowhere to send it")
    func aNotificationReadIsUseless() {
        // It parses — the *call* is well formed — but the registry drops it,
        // for the same reason a notification `ask` is dropped.
        guard case .notification(.readPane)? =
            parseLine(#"{"jsonrpc":"2.0","method":"pane.read","params":{"pane":4}}"#)
        else {
            Issue.record("expected a notification read")
            return
        }
    }

    @Test("the pane-addressed calls parse")
    func paneAddressedCalls() {
        #expect(
            parseLine(#"{"jsonrpc":"2.0","method":"pane.send","params":{"pane":4,"text":"go"}}"#)
                == .notification(call: .sendToPane(pane: 4, text: "go")))
        #expect(
            parseLine(#"{"jsonrpc":"2.0","method":"pane.interrupt","params":{"pane":4}}"#)
                == .notification(call: .interruptPane(pane: 4)))
        #expect(
            parseLine(#"{"jsonrpc":"2.0","method":"pane.answer","params":{"pane":4,"text":"row"}}"#)
                == .notification(call: .answerPane(pane: 4, text: "row", escalate: false)))
    }

    @Test("declining a question needs no text")
    func escalationIsAnAnswerToo() {
        // Answering needs words; handing the question back does not. A bare
        // `pane.answer` with `escalate` is a decline, not a malformed call.
        #expect(
            parseLine(#"{"jsonrpc":"2.0","method":"pane.answer","params":{"pane":4,"escalate":true}}"#)
                == .notification(call: .answerPane(pane: 4, text: "", escalate: true)))
        #expect(
            parseLine(#"{"jsonrpc":"2.0","method":"pane.answer","params":{"pane":4}}"#) == nil,
            "but neither text nor a decline is nothing at all")
    }

    // MARK: - The harness band's vocabulary

    @Test("a thinking role parses, and an unknown one still means the agent")
    func thinkingRole() throws {
        #expect(
            try event(of: #"{"jsonrpc":"2.0","method":"event","params":{"session":1,"event":{"kind":"message.start","id":"t1","role":"thinking"}}}"#)
                == .messageStart(id: "t1", role: .thinking))
        // spec §10: a role this build has never heard of is the agent talking,
        // which is the common case and the safer guess.
        #expect(
            try event(of: #"{"jsonrpc":"2.0","method":"event","params":{"session":1,"event":{"kind":"message.start","id":"m1","role":"oracle"}}}"#)
                == .messageStart(id: "m1", role: .agent))
    }

    @Test("an activity carries a category, and does without one")
    func activityCategory() throws {
        #expect(
            try event(of: #"{"jsonrpc":"2.0","method":"event","params":{"session":1,"event":{"kind":"activity","id":"a1","label":"Skill","detail":"swift-testing","state":"ok","category":"skill"}}}"#)
                == .activity(
                    id: "a1", label: "Skill", detail: "swift-testing", state: .ok,
                    category: "skill"))
        #expect(
            try event(of: #"{"jsonrpc":"2.0","method":"event","params":{"session":1,"event":{"kind":"activity","id":"a1","label":"Read","state":"ok"}}}"#)
                == .activity(id: "a1", label: "Read", detail: nil, state: .ok, category: nil))
    }

    @Test("a category this build has never heard of costs the field, not the line")
    func unknownCategoryDegrades() throws {
        // It is a free string on the wire precisely so a later agent's
        // vocabulary arrives intact rather than taking the activity with it.
        #expect(
            try event(of: #"{"jsonrpc":"2.0","method":"event","params":{"session":1,"event":{"kind":"activity","id":"a1","label":"Pondering","state":"ok","category":"divination"}}}"#)
                == .activity(
                    id: "a1", label: "Pondering", detail: nil, state: .ok, category: "divination"))
    }

    // MARK: - Browser panes

    @Test("an agent can ask for a browser pane")
    func createBrowserPane() throws {
        let line = #"""
        {"id":3,"method":"pane.create","params":{"from":1,"axis":"row","kind":"browser","url":"http://localhost:3000"}}
        """#
        guard case .request(_, .createPane(_, _, _, let kind, let command, _, _, _, let url))? =
            parseLine(line)
        else {
            Issue.record("expected a pane.create request")
            throw ExpectationFailure()
        }
        #expect(kind == .browser)
        #expect(url == "http://localhost:3000")
        #expect(command.isEmpty, "a browser pane runs nothing")
    }

    @Test("a kind this build has never heard of drops the call")
    func unknownPaneKindIsRefused() {
        // The one place defaulting would be worse than dropping: an agent that
        // asked for something prose does not have would get a pane of the wrong
        // sort, under a title it chose, and be none the wiser.
        #expect(
            parseLine(#"{"id":3,"method":"pane.create","params":{"from":1,"axis":"row","kind":"terminal"}}"#)
                == nil)
    }

    @Test("the browser calls parse")
    func browserCalls() {
        #expect(
            parseLine(#"{"jsonrpc":"2.0","id":1,"method":"browser.navigate","params":{"pane":2,"url":"https://example.com"}}"#)
                == .request(id: .number(1), call: .browserNavigate(pane: 2, url: "https://example.com")))
        #expect(
            parseLine(#"{"jsonrpc":"2.0","id":2,"method":"browser.text","params":{"pane":2,"selector":"main","limit":500}}"#)
                == .request(id: .number(2), call: .browserText(pane: 2, selector: "main", limit: 500)))
        #expect(
            parseLine(#"{"jsonrpc":"2.0","id":3,"method":"browser.text","params":{"pane":2}}"#)
                == .request(id: .number(3), call: .browserText(pane: 2, selector: nil, limit: nil)))
        #expect(
            parseLine(#"{"jsonrpc":"2.0","id":4,"method":"browser.eval","params":{"pane":2,"script":"1+1"}}"#)
                == .request(id: .number(4), call: .browserEval(pane: 2, script: "1+1")))
        #expect(
            parseLine(#"{"jsonrpc":"2.0","id":5,"method":"browser.snapshot","params":{"pane":2}}"#)
                == .request(id: .number(5), call: .browserSnapshot(pane: 2, path: nil)))
    }

    // MARK: - Reading back what a page returned

    @Test("a script's value crosses into JSON, whatever it was")
    func jsonFromAny() {
        #expect(JSONValue(any: nil) == .null)
        #expect(JSONValue(any: NSNull()) == .null)
        #expect(JSONValue(any: "text") == .string("text"))
        #expect(JSONValue(any: 7) == .int(7))
        #expect(JSONValue(any: 2.5) == .double(2.5))
        // `NSNumber` does not remember whether it was written as a boolean, so
        // the type encoding is what separates `true` from `1`.
        #expect(JSONValue(any: true) == .bool(true))
        #expect(JSONValue(any: [1, "two"]) == .array([.int(1), .string("two")]))
        #expect(JSONValue(any: ["k": 1]) == .object(["k": .int(1)]))
    }

    @Test("a value that is not representable becomes null, not an error")
    func jsonFromAnyIsTotal() {
        // A page can return anything. Total, like the rest of what faces an
        // agent: a value prose cannot describe is still a call that finished.
        #expect(JSONValue(any: Date()) == .null)
        #expect(JSONValue(any: [Date()]) == .array([.null]))
    }

    @Test("a selector is data in the script, never text spliced into it")
    func selectorsAreQuoted() {
        // An agent picks the selector, and an agent can be talked into picking
        // a bad one by a page it has just read.
        #expect("main".javaScriptQuoted == "\"main\"")
        #expect(#"a"b"#.javaScriptQuoted == #""a\"b""#)
        #expect(#"a\b"#.javaScriptQuoted == #""a\\b""#)
        #expect("a\nb".javaScriptQuoted == #""a\n b""#.replacingOccurrences(of: " ", with: ""))
    }
}

