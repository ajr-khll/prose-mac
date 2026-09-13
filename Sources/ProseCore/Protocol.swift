//  The wire between prose and an agent: JSON-RPC 2.0, one object per line.
//
//  No UI framework here either. Parsing a line and deciding what it means is a
//  pure question, and the fixtures in `ProtocolTests` are the closest thing to
//  a specification the agent side has.
//
//  # The rule that matters most
//
//  **An unknown method, an unknown event kind, or a malformed line is ignored,
//  never an error** (spec §10). The agent is written separately and will grow
//  vocabulary faster than this file does; refusing to parse a line we do not
//  recognise would mean the two sides could never be released independently.
//  Every unknown thing becomes `nil` and the connection carries on.
//
//  That is why nothing below is a `Codable` struct. `JSONValue` absorbs the one
//  throwing step at the line boundary and everything after it is total —
//  plan §5's instruction, and shorter than the Rust it replaces.
//
//  # Direction
//
//  `Incoming` is what an agent sends us. `Outgoing` is what we send back. Both
//  travel as JSON-RPC: a `method` with `params` is a request when it carries an
//  `id` and a notification when it does not.

import Foundation

/// Prose issues these, one per pane that holds an agent.
public typealias SessionID = UInt64

/// A JSON-RPC id. The spec allows either a number or a string, and we echo back
/// whatever the agent sent rather than normalising it — an agent that asked on
/// `"ask-7"` cannot match a reply that comes back as `7`.
public enum RequestID: Sendable, Hashable {
    case number(Int64)
    case text(String)
}

// MARK: - Agent to prose

/// One parsed line from an agent.
public enum Incoming: Sendable, Equatable {
    /// A call that owes a reply on `id`.
    case request(id: RequestID, call: Call)
    /// A call that does not.
    case notification(call: Call)
}

/// What an agent asked for. Every variant names the session or pane it
/// concerns, so the host can route without looking at anything else.
public enum Call: Sendable, Equatable {
    /// Binds a freshly opened connection to the session prose handed it. Must
    /// be the first thing on a connection; anything before it is dropped.
    case hello(session: SessionID, token: String, name: String?)

    /// Something to draw. The bulk of all traffic.
    case event(session: SessionID, event: Event)

    /// Split `from` and put something in the new pane — another agent, or a
    /// browser the asking agent may then drive.
    case createPane(
        from: PaneID,
        axis: SplitAxis,
        placement: SplitPlacement,
        kind: PaneKindWire,
        command: [String],
        cwd: String?,
        env: [String: String],
        title: String?,
        url: String?
    )

    case closePane(pane: PaneID)
    case focusPane(pane: PaneID)
    case setTitle(pane: PaneID, title: String)

    /// Stop and ask the user something. Stays pending until they answer.
    case ask(session: SessionID, prompt: String, choices: [String], placeholder: String?)

    /// Say something to another session — a parent talking to a subagent.
    case message(to: SessionID, text: String)

    /// Read a pane's transcript, and optionally wait for something to happen
    /// in it first.
    ///
    /// **Read and wait are one call on purpose.** A parent supervising a child
    /// wants "tell me when it stops, and tell me what it did" — two questions
    /// that a poll loop answers by asking the first one over and over. Parked,
    /// it is one request per turn of the child's, and the reply carries the new
    /// blocks with it so nothing has to be asked for twice.
    case readPane(pane: PaneID, query: ReadQuery)

    /// Say something into a pane, addressed the way an agent addresses
    /// everything else. `message` names a session; this names a pane, which is
    /// what `pane.create` hands back.
    case sendToPane(pane: PaneID, text: String)

    /// Answer the question a pane is stopped on, as if the user had. With
    /// `escalate`, decline it instead and let the user answer.
    case answerPane(pane: PaneID, text: String, escalate: Bool)

    /// Escape, on someone else's behalf.
    case interruptPane(pane: PaneID)

    case browserNavigate(pane: PaneID, url: String)
    /// The page's rendered text. A request — the answer is the reply.
    ///
    /// Its own method rather than a script an agent has to bring, because this
    /// is the question a browser pane is asked most often and making every
    /// agent carry `document.body.innerText` to ask it is a tax on every call.
    case browserText(pane: PaneID, selector: String?, limit: Int?)
    case browserEval(pane: PaneID, script: String)
    /// Writes a PNG and replies with its path. **Never bytes on the wire** —
    /// a pane-sized screenshot is on the order of 1,500 tokens once encoded,
    /// so reading one has to stay a decision the agent makes on purpose.
    case browserSnapshot(pane: PaneID, path: String?)
    /// The page's interactive elements, numbered — see `PageScript`.
    ///
    /// `waitFor` and `timeoutMs` make it the waiting call as well as the
    /// listing one, because a page that has just changed is a page an agent
    /// is about to act on again. Without it the only way to wait for a change
    /// that is not a navigation is to poll with `browserEval`.
    case browserElements(pane: PaneID, limit: Int?, waitFor: String?, timeoutMs: Int?)
    /// The subset of those elements matching a string, for pages too long to
    /// list.
    case browserFind(pane: PaneID, text: String, limit: Int?)
    case browserClick(pane: PaneID, ref: String)
    case browserType(pane: PaneID, ref: String, text: String, enter: Bool)
    /// Choose from a `<select>` or an ARIA listbox, which no click can open.
    case browserSelect(pane: PaneID, ref: String, option: String)
    /// One named key — Escape, Tab, an arrow — at a ref or wherever focus is.
    case browserKey(pane: PaneID, ref: String?, key: String)
    case browserScroll(pane: PaneID, ref: String?, to: String?, by: Int?)
    /// Session history. `back` false means forward.
    case browserHistory(pane: PaneID, back: Bool)

    /// What the page printed. `level` is a floor, not a match, so the common
    /// case — "anything that went wrong" — is one word rather than a list.
    ///
    /// `since` is a cursor the same way `pane.read`'s is: an agent checking a
    /// page repeatedly gets what is new, not the same lines again.
    case browserConsole(pane: PaneID, since: Int, level: String?, limit: Int?)
    /// The requests the page made, with their status codes.
    ///
    /// Its own method rather than a field on `browser.console` because the
    /// two answer different questions and a pilot almost always wants one of
    /// them: the console says the page's code is unhappy, the network says
    /// the server is.
    case browserNetwork(pane: PaneID, since: Int, failuresOnly: Bool, limit: Int?)

    /// This session's return value, routed to whoever spawned it.
    case result(session: SessionID, value: JSONValue)
}

/// Which way `pane.create` splits.
///
/// Deliberately its own type rather than `Axis`, so the wire format cannot
/// drift when that enum changes.
/// What a new pane holds. A string on the wire, so an unknown kind is a
/// dropped call rather than a pane of the wrong sort.
public enum PaneKindWire: String, Sendable, Hashable {
    case agent
    case browser
}

public enum SplitAxis: String, Sendable, Hashable {
    /// Side by side.
    case row
    /// Stacked.
    case column
}

/// Which side of the splitting pane the new one lands on.
///
/// Defaults to `after` — right of, or below — which is what every split did
/// before this existed and what `Cmd+D` still does. `before` exists for the
/// one pair with a settled reading order: a browser pilot under the page it
/// drives (`guide §9`). An unknown value is read as `after` rather than
/// refused, like every other unknown thing on this wire.
public enum SplitPlacement: String, Sendable, Hashable {
    case after
    case before
}

// MARK: - The presentation vocabulary

/// Something to draw in a pane.
///
/// Shaped around **presentation**, not around agents. A coding agent's
/// `Bash(cargo test)` and a research agent's `Searching 40 sources` are the same
/// `Event.activity` row with different text — that generalisation is what lets
/// prose host an agent it knows nothing about.
public enum Event: Sendable, Equatable {
    /// A block of prose opens. Text arrives after it as deltas.
    case messageStart(id: String, role: Role)
    case delta(id: String, text: String)
    case messageEnd(id: String)

    /// Anything with a label and a spinner: a tool call, a retrieval, a wait.
    ///
    /// `category` says what *sort* of step it is — `tool`, `skill`, `search`,
    /// `wait`, or something a later agent invents. It exists so that telling a
    /// skill from a tool does not mean sniffing `label` for a magic string, and
    /// so a supervising parent can filter on it. An unknown category renders
    /// exactly as one that is absent.
    case activity(
        id: String, label: String, detail: String?, state: ActivityState, category: String?)

    case attachment(Attachment)

    case turn(state: TurnState, error: String?)

    /// Free-form key/values for the pane header — model, cost, whatever the
    /// agent thinks is worth showing.
    case status(fields: [String: String])
}

public enum Role: Sendable, Hashable {
    case user
    case agent
    /// The agent reasoning rather than speaking.
    ///
    /// Carried on `message.start` rather than as an event kind of its own, so
    /// it streams through the same `delta`/`message.end` machinery prose has —
    /// and so a build that has never heard of it falls back to `agent` and
    /// renders the reasoning as prose instead of erroring (spec §10).
    case thinking
}

public enum ActivityState: Sendable, Hashable {
    case running
    case ok
    case error
}

public enum TurnState: Sendable, Hashable {
    case started
    case ended
    case failed
}

/// A block of content that is not prose.
public struct Attachment: Sendable, Equatable {
    public var id: String
    /// `"code"` or `"text"`. Left as a string rather than an enum so that a
    /// type this version has never heard of renders as plain text instead of
    /// disappearing — the same forgiveness the rest of the file applies.
    public var kind: String
    public var language: String?
    public var text: String

    public init(id: String, kind: String, language: String?, text: String) {
        self.id = id
        self.kind = kind
        self.language = language
        self.text = text
    }
}

// MARK: - Prose to agent

/// What prose sends. Serialised by `line()`, which is the only place JSON-RPC
/// framing is written.
public enum Outgoing: Sendable, Equatable {
    /// The user typed something.
    case message(session: SessionID, text: String)
    /// Escape, mid-turn.
    case interrupt(session: SessionID)
    /// The pane is gone. Shut down.
    case closed(session: SessionID)
    /// A subagent this session spawned has finished.
    case childResult(session: SessionID, from: SessionID, value: JSONValue)

    /// A subagent this session spawned has stopped to ask something.
    ///
    /// It reaches the parent *before* the user, because a parent that spawned
    /// a child to do a job usually knows the answer and the user usually does
    /// not. The card is still drawn in the child's pane so the user can see
    /// what is being decided; it is simply not theirs to answer yet.
    case childAsk(
        session: SessionID, from: SessionID, pane: PaneID, prompt: String, choices: [String],
        placeholder: String?)
    /// A reply to something the agent asked for.
    case reply(id: RequestID, result: JSONValue)
    /// A refusal, with a reason the agent can log.
    case failure(id: RequestID, message: String)

    /// One line of JSON, without its newline.
    public func line() -> String {
        let value: JSONValue = switch self {
        case .message(let session, let text):
            notification("message", ["session": .int(Int64(session)), "text": .string(text)])

        case .interrupt(let session):
            notification("interrupt", ["session": .int(Int64(session))])

        case .closed(let session):
            notification("closed", ["session": .int(Int64(session))])

        case .childResult(let session, let from, let result):
            notification(
                "child.result",
                ["session": .int(Int64(session)), "from": .int(Int64(from)), "value": result]
            )

        case .childAsk(let session, let from, let pane, let prompt, let choices, let placeholder):
            notification(
                "child.ask",
                [
                    "session": .int(Int64(session)),
                    "from": .int(Int64(from)),
                    "pane": .int(Int64(pane)),
                    "prompt": .string(prompt),
                    "choices": .array(choices.map { .string($0) }),
                    // Always present, `null` when absent: a client reading the
                    // field does not have to tell missing from empty.
                    "placeholder": placeholder.map { JSONValue.string($0) } ?? .null,
                ]
            )

        case .reply(let id, let result):
            .object(["jsonrpc": .string("2.0"), "id": id.json, "result": result])

        case .failure(let id, let message):
            .object([
                "jsonrpc": .string("2.0"),
                "id": id.json,
                // -32000 is the JSON-RPC range reserved for application errors.
                "error": .object(["code": .int(-32000), "message": .string(message)]),
            ])
        }
        return value.line()
    }
}

private func notification(_ method: String, _ params: [String: JSONValue]) -> JSONValue {
    .object(["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)])
}

extension RequestID {
    /// Reads an id back off the wire, or `nil` for anything JSON-RPC does not
    /// allow as one.
    fileprivate init?(_ value: JSONValue) {
        switch value {
        case .int(let number): self = .number(number)
        case .string(let text): self = .text(text)
        default: return nil
        }
    }

    fileprivate var json: JSONValue {
        switch self {
        case .number(let value): .int(value)
        case .text(let value): .string(value)
        }
    }
}

// MARK: - Parsing

/// Reads one line from an agent. `nil` means "nothing here we understand",
/// which covers blank lines, malformed JSON, responses to requests we never
/// sent, and methods from a newer agent than this build.
public func parseLine(_ line: String) -> Incoming? {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

    // The only `try?` in the protocol. Everything below this point is total,
    // which is what makes spec §10's rule a property of the code rather than a
    // discipline someone has to remember.
    guard let data = trimmed.data(using: .utf8),
          let envelope = try? JSONDecoder().decode(JSONValue.self, from: data)
    else { return nil }

    guard let method = envelope["method"]?.string else { return nil }
    guard let call = parseCall(method, envelope["params"] ?? .null) else { return nil }

    // A missing or null id is a notification. An id that is present but is
    // neither a number nor a string is a malformed line, not a notification —
    // answering it would be impossible, so the whole line goes.
    switch envelope["id"] {
    case nil, .some(.null):
        return .notification(call: call)
    case .some(let raw):
        guard let id = RequestID(raw) else { return nil }
        return .request(id: id, call: call)
    }
}

private func parseCall(_ method: String, _ params: JSONValue) -> Call? {
    switch method {
    case "hello":
        guard let session = params["session"]?.unsigned,
              let token = params["token"]?.string
        else { return nil }
        return .hello(session: session, token: token, name: params["name"]?.string)

    case "event":
        guard let session = params["session"]?.unsigned,
              let raw = params["event"],
              let event = parseEvent(raw)
        else { return nil }
        return .event(session: session, event: event)

    case "pane.create":
        guard let from = params["from"]?.unsigned,
              let axisName = params["axis"]?.string,
              let axis = SplitAxis(rawValue: axisName)
        else { return nil }
        // An unrecognised `kind` is the one thing here worth dropping the call
        // over: defaulting it would hand back a pane of the wrong sort under a
        // name the agent chose, which is worse than no pane at all.
        let kind: PaneKindWire
        if let name = params["kind"]?.string {
            guard let parsed = PaneKindWire(rawValue: name) else { return nil }
            kind = parsed
        } else {
            kind = .agent
        }
        return .createPane(
            from: from,
            axis: axis,
            // Unknown, absent or misspelled all mean `after`: placement is a
            // preference about tidiness, and refusing the whole call over one
            // would cost an agent its pane for nothing.
            placement: params["placement"]?.string
                .flatMap(SplitPlacement.init(rawValue:)) ?? .after,
            kind: kind,
            // Optional: an agent spawning a subagent almost always wants
            // *another one of whatever prose runs by default*, and making it
            // name that command means hard-coding prose's own configuration
            // into every agent that wants a child.
            command: params["command"]?.stringArray ?? [],
            cwd: params["cwd"]?.string,
            env: params["env"]?.stringMap ?? [:],
            title: params["title"]?.string,
            url: params["url"]?.string
        )

    case "pane.close":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .closePane(pane: pane)

    case "pane.focus":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .focusPane(pane: pane)

    case "pane.title":
        guard let pane = params["pane"]?.unsigned,
              let title = params["title"]?.string
        else { return nil }
        return .setTitle(pane: pane, title: title)

    case "ask":
        guard let session = params["session"]?.unsigned,
              let prompt = params["prompt"]?.string
        else { return nil }
        return .ask(
            session: session,
            prompt: prompt,
            choices: params["choices"]?.stringArray ?? [],
            placeholder: params["placeholder"]?.string
        )

    case "message":
        guard let to = params["to"]?.unsigned,
              let text = params["text"]?.string
        else { return nil }
        return .message(to: to, text: text)

    case "pane.read":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .readPane(pane: pane, query: parseQuery(params))

    case "pane.send":
        guard let pane = params["pane"]?.unsigned,
              let text = params["text"]?.string
        else { return nil }
        return .sendToPane(pane: pane, text: text)

    case "pane.answer":
        guard let pane = params["pane"]?.unsigned else { return nil }
        let escalate = params["escalate"]?.bool ?? false
        // Declining needs no text; answering does. Neither is an error, so a
        // bare `pane.answer` is read as a decline rather than dropped.
        guard let text = params["text"]?.string else {
            return escalate ? .answerPane(pane: pane, text: "", escalate: true) : nil
        }
        return .answerPane(pane: pane, text: text, escalate: escalate)

    case "pane.interrupt":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .interruptPane(pane: pane)

    case "browser.navigate":
        guard let pane = params["pane"]?.unsigned,
              let url = params["url"]?.string
        else { return nil }
        return .browserNavigate(pane: pane, url: url)

    case "browser.text":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .browserText(
            pane: pane, selector: params["selector"]?.string,
            limit: params["limit"]?.int.map(Int.init))

    case "browser.eval":
        guard let pane = params["pane"]?.unsigned,
              let script = params["script"]?.string
        else { return nil }
        return .browserEval(pane: pane, script: script)

    case "browser.snapshot":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .browserSnapshot(pane: pane, path: params["path"]?.string)

    case "browser.elements":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .browserElements(
            pane: pane, limit: params["limit"]?.int.map(Int.init),
            waitFor: params["wait_for"]?.string,
            timeoutMs: params["timeout_ms"]?.int.map(Int.init))

    case "browser.find":
        guard let pane = params["pane"]?.unsigned,
              let text = params["text"]?.string
        else { return nil }
        return .browserFind(pane: pane, text: text, limit: params["limit"]?.int.map(Int.init))

    case "browser.select":
        guard let pane = params["pane"]?.unsigned,
              let ref = params["ref"]?.string,
              let option = params["option"]?.string
        else { return nil }
        return .browserSelect(pane: pane, ref: ref, option: option)

    case "browser.key":
        guard let pane = params["pane"]?.unsigned,
              let key = params["key"]?.string
        else { return nil }
        return .browserKey(pane: pane, ref: params["ref"]?.string, key: key)

    case "browser.console":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .browserConsole(
            pane: pane, since: params["since"]?.int.map(Int.init) ?? 0,
            level: params["level"]?.string, limit: params["limit"]?.int.map(Int.init))

    case "browser.network":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .browserNetwork(
            pane: pane, since: params["since"]?.int.map(Int.init) ?? 0,
            failuresOnly: params["failures_only"]?.bool ?? false,
            limit: params["limit"]?.int.map(Int.init))

    case "browser.back":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .browserHistory(pane: pane, back: true)

    case "browser.forward":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .browserHistory(pane: pane, back: false)

    case "browser.click":
        guard let pane = params["pane"]?.unsigned,
              let ref = params["ref"]?.string
        else { return nil }
        return .browserClick(pane: pane, ref: ref)

    case "browser.type":
        guard let pane = params["pane"]?.unsigned,
              let ref = params["ref"]?.string,
              let text = params["text"]?.string
        else { return nil }
        return .browserType(
            pane: pane, ref: ref, text: text, enter: params["enter"]?.bool ?? false)

    case "browser.scroll":
        guard let pane = params["pane"]?.unsigned else { return nil }
        return .browserScroll(
            pane: pane, ref: params["ref"]?.string, to: params["to"]?.string,
            by: params["by"]?.int.map(Int.init))

    case "result":
        guard let session = params["session"]?.unsigned else { return nil }
        return .result(session: session, value: params["value"] ?? .null)

    default:
        // A method from a newer agent than this build. Dropped on purpose.
        return nil
    }
}

/// Reads a read's parameters.
///
/// Nothing here is required and nothing here can fail: every field falls back
/// to a default that makes the call mean "the cheapest useful thing". An
/// unknown `fidelity` or an unknown `until` is dropped rather than refused,
/// which is spec §10's rule applied one level down from the method name.
private func parseQuery(_ params: JSONValue) -> ReadQuery {
    let until = (params["until"]?.stringArray ?? []).compactMap(WaitReason.init(rawValue:))
    return ReadQuery(
        since: Int(params["since"]?.int ?? 0),
        block: params["block"]?.int.map(Int.init),
        fidelity: params["fidelity"]?.string.flatMap(Fidelity.init(rawValue:)) ?? .summary,
        kinds: params["kinds"]?.stringArray ?? [],
        match: params["match"]?.string,
        limit: params["limit"]?.int.map(Int.init),
        until: until,
        timeout: Int(params["timeout"]?.int ?? 0)
    )
}

private func parseEvent(_ event: JSONValue) -> Event? {
    guard let kind = event["kind"]?.string else { return nil }

    // Every event that names a block needs its id; text is optional everywhere
    // it appears, because an empty delta is a no-op rather than a mistake.
    let id = event["id"]?.string
    let text = event["text"]?.string ?? ""

    switch kind {
    case "message.start":
        guard let id else { return nil }
        let role: Role = switch event["role"]?.string {
        case "user": .user
        case "thinking": .thinking
        // Anything else is the agent talking, which is the common case and the
        // safer assumption for a role we do not know.
        default: .agent
        }
        return .messageStart(id: id, role: role)

    case "delta":
        guard let id else { return nil }
        return .delta(id: id, text: text)

    case "message.end":
        guard let id else { return nil }
        return .messageEnd(id: id)

    case "activity":
        guard let id, let label = event["label"]?.string else { return nil }
        let state: ActivityState = switch event["state"]?.string {
        case "ok": .ok
        case "error": .error
        // An activity with no state is one that has just begun.
        default: .running
        }
        return .activity(
            id: id, label: label, detail: event["detail"]?.string, state: state,
            category: event["category"]?.string)

    case "attachment":
        guard let id else { return nil }
        return .attachment(
            Attachment(
                id: id,
                kind: event["type"]?.string ?? "text",
                language: event["language"]?.string,
                text: text
            )
        )

    case "turn":
        let state: TurnState = switch event["state"]?.string {
        case "started": .started
        case "failed": .failed
        default: .ended
        }
        return .turn(state: state, error: event["error"]?.string)

    case "status":
        return .status(fields: event["fields"]?.stringMap ?? [:])

    default:
        // An event kind from a newer agent than this build.
        return nil
    }
}
