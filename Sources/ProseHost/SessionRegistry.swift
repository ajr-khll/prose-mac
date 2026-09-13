//  The session table: who owns which pane, what token proves it, and what is
//  owed to an agent that has not connected yet.
//
//  This is the security boundary (plan §8), and it is deliberately in a target
//  with no UI framework so the handshake can be tested without a window.
//
//  # Where the concurrency went
//
//  plan §8 proposed an `actor` here with the coalescing inside it. The
//  coalescing moved one layer down instead, into `Connection`, which is where
//  the plan's own reasoning points: *"the actor hop is not free — a fast agent
//  doing one `await MainActor.run` per token is the real cost, not the
//  drawing."* Batching below the hop is what makes that true, and it also puts
//  parsing off the main actor. What is left here is the session table, which is
//  read and written by the same UI that owns the panes, so it lives on the main
//  actor with them rather than behind a second one.

import Foundation
import ProseCore

/// What the host hands to the UI. Everything here has already been checked:
/// the connection said hello, its token matched, and it is only ever talking
/// about a pane it owns.
public enum HostEvent: Sendable {
    /// Something to draw.
    case event(session: SessionID, event: Event)
    /// The agent stopped to ask the user something.
    case ask(
        session: SessionID, id: RequestID, prompt: String, choices: [String], placeholder: String?
    )
    /// A failed turn, or the agent's process going away.
    case notice(session: SessionID, message: String)
    /// The agent named itself in its `hello`.
    case named(session: SessionID, name: String)

    case createPane(
        request: RequestID?, from: PaneID, axis: SplitAxis, placement: SplitPlacement,
        kind: PaneKindWire, command: [String],
        cwd: String?, env: [String: String], title: String?, url: String?, parent: SessionID
    )
    case closePane(PaneID)
    case focusPane(PaneID)
    case setTitle(pane: PaneID, title: String)

    /// A read arrived. The workspace owns the transcript, so it decides whether
    /// the query is already satisfied — and parks it if not.
    case readPane(request: RequestID, requester: SessionID, pane: PaneID, query: ReadQuery)

    /// A parked read is owed its answer now, for this reason.
    case answerRead(
        request: RequestID, requester: SessionID, pane: PaneID, query: ReadQuery,
        reason: WaitReason
    )

    case sendToPane(pane: PaneID, text: String)
    case answerPane(pane: PaneID, text: String, escalate: Bool)
    case interruptPane(pane: PaneID)

    /// Driving a browser pane. Each carries the request it owes an answer on,
    /// because every one of them finishes asynchronously inside WebKit.
    case browser(request: RequestID?, requester: SessionID, pane: PaneID, call: BrowserCall)
}

/// What an agent asked a browser pane to do.
public enum BrowserCall: Sendable, Equatable {
    case navigate(url: String)
    case text(selector: String?, limit: Int?)
    case eval(script: String)
    case snapshot(path: String?)
    case elements(limit: Int?, waitFor: String?, timeoutMs: Int?)
    case find(text: String, limit: Int?)
    case click(ref: String)
    case type(ref: String, text: String, enter: Bool)
    case select(ref: String, option: String)
    case key(ref: String?, key: String)
    case scroll(ref: String?, to: String?, by: Int?)
    case history(back: Bool)
    case console(since: Int, level: String?, limit: Int?)
    case network(since: Int, failuresOnly: Bool, limit: Int?)
}

/// A read that is waiting for something to happen in someone else's pane.
///
/// Held as data rather than as a suspended continuation: the registry is the
/// only thing that knows which connection owes what, and a table can be walked
/// on close, on disconnect and on quit — three paths a continuation would have
/// to be reachable from anyway.
struct ParkedRead {
    let request: RequestID
    /// Who asked, and therefore who the reply goes to.
    let requester: SessionID
    let pane: PaneID
    /// The session whose progress this is waiting on, or `nil` when the thing
    /// being waited on is the *pane* rather than an agent — a browser pane has
    /// no session, and `.loaded` is its only reason.
    let target: SessionID?
    let query: ReadQuery
    /// Cancelled the moment the read is answered, so a timeout cannot fire
    /// after the fact and answer the same request twice.
    let timer: Task<Void, Never>
}

/// One reserved pane's worth of agent.
struct Session {
    let pane: PaneID
    let token: String
    /// Who spawned this one, so a `result` can be routed back as `child.result`.
    let parent: SessionID?
    /// `nil` until the agent says hello.
    var connection: Connection?
    /// Anything addressed to this session before it connects. A subagent is
    /// spawned and told something in the same breath often enough that dropping
    /// those lines would be a race the agent author could not win (spec §11).
    var backlog: [Outgoing] = []
    var process: AgentProcess?
    var name: String?
}

@MainActor
public final class SessionRegistry {
    private var sessions: [SessionID: Session] = [:]
    private var bound: [ObjectIdentifier: SessionID] = [:]
    private var nextID: SessionID = 1

    /// Reads waiting on something to happen. See `ParkedRead`.
    private var parked: [ParkedRead] = []

    /// Where checked traffic goes.
    public var onEvent: ((HostEvent) -> Void)?

    public init() {}

    // MARK: - Reserving

    /// Reserves a session for a pane *before* its view exists, because the view
    /// must be told which session it is (spec §11).
    public func reserve(pane: PaneID, parent: SessionID? = nil) -> (id: SessionID, token: String) {
        let id = nextID
        nextID += 1
        let token = Self.makeToken()
        sessions[id] = Session(pane: pane, token: token, parent: parent)
        return (id, token)
    }

    /// 32 bytes of randomness, hex encoded. The only thing standing between an
    /// agent and any other agent's pane, so it is not a counter.
    private static func makeToken() -> String {
        (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    public func pane(of session: SessionID) -> PaneID? { sessions[session]?.pane }

    /// Who spawned this session, if anyone. A root pane has no parent, and its
    /// questions have always gone straight to the user.
    public func parent(of session: SessionID) -> SessionID? { sessions[session]?.parent }
    public func session(for pane: PaneID) -> SessionID? {
        sessions.first { $0.value.pane == pane }?.key
    }

    public func attach(_ process: AgentProcess, to session: SessionID) {
        sessions[session]?.process = process
    }

    // MARK: - Authorization

    /// How far up a parent chain to walk before giving up. A cycle cannot
    /// happen — `reserve` only ever names an existing session as a parent, so
    /// the chain is acyclic by construction — but a corrupted table must not
    /// spin forever inside the security check of all places.
    private static let maxAncestry = 64

    /// **A session may act on its own pane, or on any pane belonging to a
    /// session descended from it.**
    ///
    /// This is the whole containment rule. Without it a session could close,
    /// retitle or scribble in any pane in the window by guessing a small
    /// integer, because pane ids are sequential and an agent can see its own.
    ///
    /// A pane with no session at all — a browser pane the *user* opened — is
    /// nobody's to act on, which is what stops an agent driving a page the user
    /// typed credentials into.
    func mayAct(_ session: SessionID, onPane pane: PaneID) -> Bool {
        guard let target = self.session(for: pane) else { return false }
        return mayAct(session, onSession: target)
    }

    /// The same rule, for the calls that name a session rather than a pane.
    ///
    /// Deliberately one-directional: a child may not message its parent. The
    /// upward channel is `result`, which arrives as `child.result` and is
    /// routed by the parent link rather than addressed by the child.
    func mayAct(_ session: SessionID, onSession target: SessionID) -> Bool {
        var current: SessionID? = target
        var depth = 0
        while let id = current, depth < Self.maxAncestry {
            if id == session { return true }
            current = sessions[id]?.parent
            depth += 1
        }
        return false
    }

    // MARK: - The handshake

    /// Takes a batch of lines from one connection.
    ///
    /// **The first line on a connection must be a `hello` request naming a
    /// session and its token.** Anything before it is dropped, and a hello that
    /// does not match a reserved session is answered with a failure and the
    /// connection is closed.
    public func receive(_ batch: [Incoming], from connection: Connection) {
        for incoming in batch { receive(incoming, from: connection) }
    }

    private func receive(_ incoming: Incoming, from connection: Connection) {
        let key = ObjectIdentifier(connection)

        guard let session = bound[key] else {
            guard case .request(let id, .hello(let claimed, let token, let name)) = incoming else {
                // Anything before hello is dropped rather than answered: a
                // connection that has not identified itself is owed nothing.
                return
            }
            guard let reserved = sessions[claimed], reserved.token == token else {
                connection.send(.failure(id: id, message: "unknown session or token"))
                connection.close()
                return
            }

            // **A session that already has a live connection is not up for
            // grabs.** Without this, a second process holding the same token
            // would silently replace the first in the table, and the agent that
            // was there would stop receiving `message`, `interrupt` and
            // `closed` with no error anywhere to say why.
            //
            // Refused rather than accepted read-only: a secondary connection
            // would need its replies routed back to *it* rather than to the
            // session, and request ids are only unique per connection. That is
            // the piece to build when a second front door earns its place.
            guard reserved.connection == nil else {
                connection.send(.failure(id: id, message: "session already connected"))
                connection.close()
                return
            }

            bound[key] = claimed
            connection.session = claimed
            sessions[claimed]?.connection = connection
            sessions[claimed]?.name = name
            // **The pane comes back with the handshake.** Everything an agent
            // addresses — splitting, reading, closing — is named by pane, and
            // until this it had no way to learn its own: the environment hands
            // it a session, and no call turns one into the other.
            connection.send(
                .reply(
                    id: id,
                    result: .object([
                        "ok": .bool(true),
                        "pane": .int(Int64(reserved.pane)),
                        "session": .int(Int64(claimed)),
                    ])))

            // Everything said to this session while it was still starting up.
            let backlog = sessions[claimed]?.backlog ?? []
            sessions[claimed]?.backlog = []
            for line in backlog { connection.send(line) }

            if let name { onEvent?(.named(session: claimed, name: name)) }
            return
        }

        handle(incoming, from: session, on: connection)
    }

    /// A second hello on a bound connection is ignored, as is anything naming a
    /// session this connection does not own.
    private func handle(_ incoming: Incoming, from session: SessionID, on connection: Connection) {
        let request: RequestID? = {
            if case .request(let id, _) = incoming { return id }
            return nil
        }()
        let call: Call = {
            switch incoming {
            case .request(_, let call): call
            case .notification(let call): call
            }
        }()

        switch call {
        case .hello:
            // Already bound. Saying it twice is not an error, it is nothing.
            break

        case .event(let claimed, let event):
            // **An agent may only draw in a pane it owns.** Without this, a
            // session could scribble in any other pane by guessing an id.
            guard claimed == session else { return }
            onEvent?(.event(session: session, event: event))

        case .ask(let claimed, let prompt, let choices, let placeholder):
            guard let id = request else {
                // A notification `ask` is dropped: the agent would otherwise
                // wait forever for a reply it never asked for.
                return
            }
            guard claimed == session else {
                connection.send(.failure(id: id, message: "not your session"))
                return
            }
            onEvent?(
                .ask(
                    session: session, id: id, prompt: prompt, choices: choices,
                    placeholder: placeholder
                )
            )

        case .createPane(let from, let axis, let placement, let kind, let command, let cwd,
                         let env, let title, let url):
            // You may only split a pane you are allowed to touch — otherwise an
            // agent could graft a subagent into another agent's tab.
            guard mayAct(session, onPane: from) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .createPane(
                    request: request, from: from, axis: axis, placement: placement, kind: kind,
                    command: command, cwd: cwd, env: env, title: title, url: url, parent: session
                )
            )

        case .closePane(let pane):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(.closePane(pane))

        case .focusPane(let pane):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(.focusPane(pane))

        case .setTitle(let pane, let title):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(.setTitle(pane: pane, title: title))

        case .message(let to, let text):
            // A parent talking to a subagent. Queued if it has not connected.
            guard mayAct(session, onSession: to) else {
                refuse(request, on: connection, "not your session")
                return
            }
            send(.message(session: to, text: text), to: to)

        case .readPane(let pane, let query):
            // A read with no id has nowhere to go. Dropped rather than acted
            // on, for the same reason a notification `ask` is.
            guard let request else { return }
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(.readPane(request: request, requester: session, pane: pane, query: query))

        case .sendToPane(let pane, let text):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(.sendToPane(pane: pane, text: text))
            acknowledge(request, on: connection)

        case .answerPane(let pane, let text, let escalate):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(.answerPane(pane: pane, text: text, escalate: escalate))
            acknowledge(request, on: connection)

        case .interruptPane(let pane):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(.interruptPane(pane: pane))
            acknowledge(request, on: connection)

        // **Provenance, not politeness.** A browser pane an agent opened gets a
        // session parented to that agent's, with no process behind it, so the
        // same descendant walk that guards every other pane guards this one. A
        // pane the *user* opened has no session at all and is therefore nobody's
        // to drive — which is what stops an agent running script in a page the
        // user typed a password into.
        case .browserNavigate(let pane, let url):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane, call: .navigate(url: url)))

        case .browserText(let pane, let selector, let limit):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane,
                    call: .text(selector: selector, limit: limit)))

        case .browserEval(let pane, let script):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane, call: .eval(script: script)))

        case .browserSnapshot(let pane, let path):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane, call: .snapshot(path: path)))

        // Every arm repeats `mayAct` deliberately: the guard is per-case, and
        // a new case that forgets it is an authorization hole rather than a
        // bug — which is why these are written out rather than folded.
        case .browserElements(let pane, let limit, let waitFor, let timeoutMs):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane,
                    call: .elements(limit: limit, waitFor: waitFor, timeoutMs: timeoutMs)))

        case .browserFind(let pane, let text, let limit):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane,
                    call: .find(text: text, limit: limit)))

        case .browserSelect(let pane, let ref, let option):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane,
                    call: .select(ref: ref, option: option)))

        case .browserKey(let pane, let ref, let key):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane,
                    call: .key(ref: ref, key: key)))

        case .browserHistory(let pane, let back):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane, call: .history(back: back)))

        case .browserClick(let pane, let ref):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane, call: .click(ref: ref)))

        case .browserType(let pane, let ref, let text, let enter):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane,
                    call: .type(ref: ref, text: text, enter: enter)))

        case .browserScroll(let pane, let ref, let to, let by):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane,
                    call: .scroll(ref: ref, to: to, by: by)))

        case .browserConsole(let pane, let since, let level, let limit):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane,
                    call: .console(since: since, level: level, limit: limit)))

        case .browserNetwork(let pane, let since, let failuresOnly, let limit):
            guard mayAct(session, onPane: pane) else {
                refuse(request, on: connection, "not your pane")
                return
            }
            onEvent?(
                .browser(
                    request: request, requester: session, pane: pane,
                    call: .network(since: since, failuresOnly: failuresOnly, limit: limit)))

        case .result(let claimed, let value):
            guard claimed == session else { return }
            // Routed to whoever spawned this one, if it has a parent.
            guard let parent = sessions[session]?.parent else { return }
            send(.childResult(session: parent, from: session, value: value), to: parent)
        }
    }

    // MARK: - Sending

    /// Turns a refused call down.
    ///
    /// A request is owed an answer — an agent blocked on one it will never get
    /// is worse than an agent told no. A notification is dropped silently,
    /// which is spec §10's rule for everything prose declines to act on.
    private func refuse(_ request: RequestID?, on connection: Connection, _ message: String) {
        guard let request else { return }
        connection.send(.failure(id: request, message: message))
    }

    /// Answers a request that did what it asked and has nothing to report.
    private func acknowledge(_ request: RequestID?, on connection: Connection) {
        guard let request else { return }
        connection.send(.reply(id: request, result: .object(["ok": .bool(true)])))
    }

    // MARK: - Parked reads

    /// Holds a read until something happens in `pane`, or until it times out.
    ///
    /// Called by the workspace, which is the only thing that can tell whether
    /// the query is satisfied already — and **it must check that first.** A
    /// child that finishes in fifty milliseconds, before its parent's model
    /// gets round to asking, would otherwise be waited on forever: the event
    /// that would have woken the read happened before the read existed.
    /// `target` is the session whose progress will wake this, or `nil` to wait
    /// on the pane itself. **The caller resolves it**, because only the
    /// workspace can tell an agent pane from a browser pane — the registry
    /// used to guess with `session(for:)` and answered `.closed` for every
    /// browser pane, which is not a hang but a lie, and worse for it.
    public func park(
        request: RequestID, requester: SessionID, pane: PaneID, target: SessionID?,
        query: ReadQuery
    ) {

        // Detached rather than a plain `Task`: this timer outlives the call
        // that started it by design, and a task that inherits nothing — not
        // cancellation, not task-locals — cannot be ended early by whatever
        // happened to be running when the read arrived.
        // Cancelling this task is how every other path stops the timeout
        // firing — `answer` cancels it the moment the read is satisfied, so a
        // timer that has already lost the race cannot answer the same request
        // a second time.
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(query.timeout))
            guard !Task.isCancelled else { return }
            self?.wake(request: request, reason: .timeout)
        }

        parked.append(
            ParkedRead(
                request: request, requester: requester, pane: pane, target: target,
                query: query, timer: timer))
    }

    /// Something happened in `session`. Answers every read parked on it that
    /// was waiting for this.
    ///
    /// Called by the workspace after it has folded the event, so that a read
    /// woken by a turn ending sees the blocks that turn produced.
    public func progress(_ session: SessionID, _ reason: WaitReason) {
        let woken = parked.filter { $0.target == session && $0.query.until.contains(reason) }
        for read in woken { answer(read, reason) }
    }

    /// Something happened in a pane that has no session — today only a browser
    /// pane finishing a load. Answers every read parked on the pane itself.
    public func progressed(_ pane: PaneID, _ reason: WaitReason) {
        let woken = parked.filter {
            $0.target == nil && $0.pane == pane && $0.query.until.contains(reason)
        }
        for read in woken { answer(read, reason) }
    }

    /// Answers one parked read by its request id — the timeout path, which
    /// knows which read fired but nothing about why.
    private func wake(request: RequestID, reason: WaitReason) {
        guard let read = parked.first(where: { $0.request == request }) else { return }
        answer(read, reason)
    }

    private func answer(_ read: ParkedRead, _ reason: WaitReason) {
        read.timer.cancel()
        parked.removeAll { $0.request == read.request && $0.requester == read.requester }
        onEvent?(
            .answerRead(
                request: read.request, requester: read.requester, pane: read.pane,
                query: read.query, reason: reason))
    }

    /// Sends to a session, or holds it until the agent says hello.
    public func send(_ outgoing: Outgoing, to session: SessionID) {
        guard var entry = sessions[session] else { return }
        if let connection = entry.connection {
            connection.send(outgoing)
            return
        }

        // **A reply is never worth queueing.** A notification still makes sense
        // whenever it arrives, but an answer belongs to the process that asked
        // the question: after a disconnect and a fresh hello this session is a
        // *new* process with its own id counter, so a held reply on id 7 would
        // land on whatever that process happens to call request 7.
        switch outgoing {
        case .reply, .failure: return
        case .message, .interrupt, .closed, .childResult, .childAsk: break
        }

        entry.backlog.append(outgoing)
        sessions[session] = entry
    }

    /// A pane with no session went away. Answers everything parked on it.
    ///
    /// `close(_ session:)` covers agent panes; this is its twin for a browser
    /// pane, which has no session to key on. Without it a pilot waiting for a
    /// page in a pane the user just closed waits out its whole timeout.
    public func closed(pane: PaneID) {
        for read in parked where read.target == nil && read.pane == pane {
            answer(read, .closed)
        }
    }

    /// Closing a pane tells its agent *first*, then drops everything that keeps
    /// it alive — so the agent is told rather than simply having its socket
    /// close under it (spec §11).
    public func close(_ session: SessionID) {
        guard let entry = sessions[session] else { return }

        // **Waiters first.** A parent parked on a child that is being closed
        // would otherwise block until its timeout with the pane already gone,
        // and a parent blocked in its model loop is a pane that has stopped
        // responding for a reason nothing on screen explains.
        for read in parked where read.target == session { answer(read, .closed) }

        entry.connection?.send(.closed(session: session))
        entry.connection?.close()
        entry.process?.terminate()

        if let connection = entry.connection {
            bound[ObjectIdentifier(connection)] = nil
        }
        sessions[session] = nil
    }

    /// A connection went away without its pane being closed. The session stays
    /// — spec §11 is explicit that **the pane is not closed**, because a pane
    /// vanishing out from under whoever was reading it is worse than one that
    /// says what happened.
    public func disconnected(_ connection: Connection) {
        let key = ObjectIdentifier(connection)
        guard let session = bound[key] else { return }
        bound[key] = nil
        sessions[session]?.connection = nil

        // Reads *this* session was waiting on are dropped rather than answered:
        // the process that asked is gone, so there is nobody to answer, and a
        // held timer would fire into an empty connection much later.
        for read in parked where read.requester == session { read.timer.cancel() }
        parked.removeAll { $0.requester == session }
    }

    /// The connection bound to a session, for tests that need to simulate one
    /// going away without closing the socket underneath it.
    func connectionForTesting(_ session: SessionID) -> Connection? {
        sessions[session]?.connection
    }

    /// Every session, so quitting can shut them all down.
    public var all: [SessionID] { Array(sessions.keys) }

    public func terminateAll() {
        for read in parked { read.timer.cancel() }
        parked.removeAll()
        for (_, session) in sessions { session.process?.terminate() }
    }
}
