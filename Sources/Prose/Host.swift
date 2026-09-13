//  Where the socket meets the panes.
//
//  `ProseHost` knows about sessions, tokens and processes; `Workspace` knows
//  about panes and transcripts. This is the seam: it opens the socket, spawns
//  agents, and turns checked `HostEvent`s into transcript and pane changes.

import AppKit
import Foundation
import ProseCore
import ProseHost
import SwiftUI

extension Workspace {
    /// The directory to tidy away on exit. Static and a plain string, because
    /// `atexit` has no object to ask and no actor to hop to.
    nonisolated(unsafe) static var directoryToClean: String?

    /// Opens the socket and starts accepting agents.
    ///
    /// **If the socket cannot be opened the app still runs**: panes render,
    /// they just stay empty (spec §11). A window with no agents is worth more
    /// than refusing to open at all, so this reports the failure into the
    /// panes rather than throwing out of launch.
    func startHost() {
        AgentProcess.installCrashHandlers()

        do {
            let socket = try AgentSocket()
            self.socket = socket
            // Removed on exit, best effort: a stale socket in a temp directory
            // is harmless, but leaving one per run is untidy (spec §11).
            // Removed on exit, best effort (spec §11). Registered by the
            // socket itself, because an `atexit` closure written here would
            // inherit this type's main-actor isolation and trap on the way out.
            socket.removeOnExit()
            Self.directoryToClean = socket.directory
            registry.onEvent = { [weak self] event in self?.handle(event) }

            let registry = self.registry
            socket.accept { connection in
                connection.onIncoming = { batch in
                    Task { @MainActor in registry.receive(batch, from: connection) }
                }
                connection.onClose = {
                    Task { @MainActor in registry.disconnected(connection) }
                }
            }
        } catch {
            hostFailure = "no agent socket: \(error)"
        }
    }

    /// Reserves a session for `pane` and starts the default agent in it.
    func spawnAgent(for pane: PaneID, parent: SessionID? = nil, command: [String] = [],
                    cwd: URL? = nil, environment: [String: String] = [:]) {
        guard socket != nil, let agent = agent(pane) else { return }

        let reserved = registry.reserve(pane: pane, parent: parent)
        agent.session = reserved.id
        agent.onOutgoing = { [weak self] outgoing in
            self?.registry.send(outgoing, to: reserved.id)
        }

        let process = AgentProcess(
            command: command,
            cwd: cwd ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
            environment: environment,
            socket: socket!.path,
            session: reserved.id,
            token: reserved.token
        )
        // When a child exits its pane gets a notice and is **not** closed — a
        // pane vanishing out from under whoever was reading it is worse than
        // one that says what happened (spec §11).
        process.onExit = { [weak self] notice in
            Task { @MainActor in
                guard let self else { return }
                self.agent(pane)?.markExited()
                self.agent(pane)?.notice(notice)
                // Anyone parked on this child is owed the news.
                self.registry.progress(reserved.id, .exit)
            }
        }

        do {
            try process.start()
            registry.attach(process, to: reserved.id)
        } catch {
            agent.notice("could not start the agent: \(error.localizedDescription)")
        }
    }

    /// Checked traffic, on the main actor.
    private func handle(_ event: HostEvent) {
        switch event {
        case .event(let session, let event):
            agentFor(session)?.apply(event)
            // **After** the fold, not before: a read woken by a turn ending
            // must see the blocks that turn produced, or a parent learns that
            // something finished and then has to ask again what it was.
            if case .turn(let state, _) = event, state != .started {
                registry.progress(session, .turn)
            }

        case .ask(let session, let id, let prompt, let choices, let placeholder):
            // A subagent's question goes to whoever spawned it first. The card
            // is drawn either way — the user seeing what is being decided is
            // worth more than being asked to decide it — but while a parent
            // holds it, it takes no clicks and does not claim Enter.
            let parent = registry.parent(of: session)
            let supervisor = parent.flatMap { registry.pane(of: $0) }
            agentFor(session)?.ask(
                id: id, prompt: prompt, choices: choices, placeholder: placeholder,
                supervisor: supervisor)

            if let parent, let pane = registry.pane(of: session) {
                registry.send(
                    .childAsk(
                        session: parent, from: session, pane: pane, prompt: prompt,
                        choices: choices, placeholder: placeholder),
                    to: parent)
                escalate(pane, after: Self.supervisionGrace)
            }
            registry.progress(session, .ask)

        case .notice(let session, let message):
            agentFor(session)?.notice(message)

        case .named(let session, let name):
            guard let pane = registry.pane(of: session) else { return }
            setPaneTitle(pane, name)

        case .createPane(let request, let from, let axis, let placement, let kind, let command,
                         let cwd, let env, let title, let url, let parent):
            // The one door for both the user's Cmd+D and an agent's
            // `pane.create`, so neither can end up with a pane the other could
            // not have made. A subagent runs where the agent that asked for it
            // runs, unless it said otherwise.
            guard
                let new = splitPane(
                    from, axis == .row ? .row : .column,
                    placement: placement == .before ? .before : .after,
                    kind: kind == .browser ? .browser : .agent, parent: parent, command: command,
                    cwd: cwd.map { URL(fileURLWithPath: $0) }, environment: env, url: url)
            else {
                if let request { registry.send(.failure(id: request, message: "no such pane"), to: parent) }
                return
            }
            if let title { setPaneTitle(new, title) }
            if let request {
                // **Both ids, not just the pane.** The pane is what the agent
                // addresses panes with; the session is what `message` and
                // `result` are routed by. Handing back only the pane left a
                // parent unable to say anything to the child it had just asked
                // for, which is the whole point of spawning one.
                var result: [String: JSONValue] = ["pane": .int(Int64(new))]
                if let session = registry.session(for: new) {
                    result["session"] = .int(Int64(session))
                }
                registry.send(.reply(id: request, result: .object(result)), to: parent)
            }

        case .closePane(let pane):
            closePane(pane)

        case .focusPane(let pane):
            // Bring it into view, without taking the keyboard off whoever is
            // typing — see `revealPane`.
            revealPane(pane)

        case .setTitle(let pane, let title):
            setPaneTitle(pane, title)

        case .readPane(let request, let requester, let pane, let query):
            // A plain read is answered where it stands.
            guard query.waits else {
                reply(to: request, from: pane, query: query, reason: .now, for: requester)
                return
            }
            // A browser pane has no agent and no transcript, but it does have
            // a clock — its load count — so it can be waited on like anything
            // else. This used to fall through to the `.closed` arm below,
            // which told a pilot its perfectly healthy pane was gone.
            if let browser = browser(pane) {
                if let reason = satisfied(query, browser) {
                    reply(to: request, from: pane, query: query, reason: reason, for: requester)
                    return
                }
                registry.park(
                    request: request, requester: requester, pane: pane, target: nil, query: query)
                return
            }
            guard let agent = agent(pane) else {
                reply(to: request, from: pane, query: query, reason: .closed, for: requester)
                return
            }
            // A waiting read is parked only if what it waits for has not
            // happened yet. That check is the difference between a supervision
            // loop and a hang — see `satisfied(_:_:)`.
            if let reason = satisfied(query, agent) {
                reply(to: request, from: pane, query: query, reason: reason, for: requester)
                return
            }
            registry.park(
                request: request, requester: requester, pane: pane, target: agent.session,
                query: query)

        case .answerRead(let request, let requester, let pane, let query, let reason):
            reply(to: request, from: pane, query: query, reason: reason, for: requester)

        case .sendToPane(let pane, let text):
            // Through the session rather than the socket, so the pane shows
            // what it was told exactly as it would show the user typing it.
            agent(pane)?.send(text)

        case .answerPane(let pane, let text, let escalate):
            if escalate {
                agent(pane)?.escalateAsk()
            } else {
                agent(pane)?.answer(text)
            }

        case .interruptPane(let pane):
            agent(pane)?.interrupt()

        case .browser(let request, let requester, let pane, let call):
            drive(pane, call, request: request, for: requester)
        }
    }

    /// Runs one browser call and answers it when WebKit does.
    ///
    /// Every one of these finishes asynchronously inside the web content
    /// process, so the reply is sent from the completion rather than returned —
    /// which is also why each carries the request id it owes an answer on.
    private func drive(
        _ pane: PaneID, _ call: BrowserCall, request: RequestID?, for requester: SessionID
    ) {
        guard let browser = browser(pane) else {
            if let request {
                registry.send(.failure(id: request, message: "not a browser pane"), to: requester)
            }
            return
        }

        let answer: (JSONValue) -> Void = { [weak self] value in
            guard let request else { return }
            self?.registry.send(.reply(id: request, result: value), to: requester)
        }

        switch call {
        case .navigate(let url):
            browser.navigate(to: url)
            answer(.object(["ok": .bool(true)]))
        case .text(let selector, let limit):
            browser.text(selector: selector, limit: limit, then: answer)
        case .eval(let script):
            browser.evaluate(script, then: answer)
        case .snapshot(let path):
            browser.snapshot(to: path, then: answer)
        case .elements(let limit, let waitFor, let timeoutMs):
            browser.elements(limit: limit, waitFor: waitFor, timeoutMs: timeoutMs, then: answer)
        case .find(let text, let limit):
            browser.find(text: text, limit: limit, then: answer)
        case .click(let ref):
            browser.click(ref: ref, then: answer)
        case .type(let ref, let text, let enter):
            browser.type(ref: ref, text: text, enter: enter, then: answer)
        case .select(let ref, let option):
            browser.select(ref: ref, option: option, then: answer)
        case .key(let ref, let key):
            browser.key(ref: ref, key: key, then: answer)
        case .scroll(let ref, let to, let by):
            browser.scroll(ref: ref, to: to, by: by, then: answer)
        case .history(let back):
            browser.step(back: back, then: answer)
        case .console(let since, let level, let limit):
            // An unknown level reads as `warn` rather than refusing the call.
            // The whole wire treats an unrecognised value that way, and the
            // cost of being wrong here is a few extra lines rather than a
            // failed read.
            answer(
                browser.console(
                    since: since, level: level.flatMap(ConsoleLevel.init(rawValue:)) ?? .warn,
                    limit: limit ?? 50))
        case .network(let since, let failuresOnly, let limit):
            answer(
                browser.network(since: since, failuresOnly: failuresOnly, limit: limit ?? 50))
        }
    }

    /// How long a parent has to answer its child's question before the user
    /// gets it.
    ///
    /// A parent is usually a model in the middle of a turn, so this is patient
    /// — but it is finite, because a parent that has crashed or wandered off
    /// must not leave a question nobody is allowed to answer sitting in a pane.
    static let supervisionGrace: Duration = .seconds(60)

    /// Hands a pane's supervised question back to the user once the grace has
    /// passed. A no-op if it was answered or already escalated, which is what
    /// makes it safe to start one per question and never cancel it.
    private func escalate(_ pane: PaneID, after grace: Duration) {
        Task { [weak self] in
            try? await Task.sleep(for: grace)
            self?.agent(pane)?.escalateAsk()
        }
    }

    /// Why a waiting read should be answered now, or `nil` to park it.
    ///
    /// **Level-triggered against the cursor, never edge-triggered.** A child
    /// that finished before its parent got round to asking must not be waited
    /// on: the event that would have woken the read happened before the read
    /// existed, and a fast child is the common case rather than an edge one.
    func satisfied(_ query: ReadQuery, _ agent: AgentSession) -> WaitReason? {
        let transcript = agent.transcript
        if query.until.contains(.ask), transcript.pendingAsk != nil { return .ask }
        if query.until.contains(.exit), agent.exited { return .exit }
        // Something happened since they last looked, and nothing is running now
        // — which is what "a turn ended" looks like from the outside.
        if query.until.contains(.turn), transcript.clock > query.since, !transcript.isRunning {
            return .turn
        }
        return nil
    }

    /// Why a read waiting on a *browser* pane should be answered now.
    ///
    /// The same level-triggered rule as its twin above, against a different
    /// clock: a browser pane has no transcript, so `since` counts finished
    /// navigations rather than transcript entries. A page that finished
    /// loading before the wait was placed satisfies it immediately — which is
    /// the whole point, because a cached page loads faster than a model can
    /// decide to wait for it.
    func satisfied(_ query: ReadQuery, _ browser: BrowserSession) -> WaitReason? {
        if query.until.contains(.loaded), browser.loads > query.since { return .loaded }
        return nil
    }

    /// Encodes a read and sends it back to whoever asked.
    private func reply(
        to request: RequestID, from pane: PaneID, query: ReadQuery, reason: WaitReason,
        for requester: SessionID
    ) {
        if let browser = browser(pane) {
            // No transcript to read, so the answer is the pane's state: where
            // it is, what it is called, and the load count to thread back as
            // `since` next time. `blocks` is present and empty so that one
            // shape comes back from `pane.read` whatever it was pointed at.
            registry.send(
                .reply(
                    id: request,
                    result: .object([
                        "reason": .string(reason.rawValue),
                        "cursor": .int(Int64(browser.loads)),
                        "blocks": .array([]),
                        "url": .string(browser.webView.url?.absoluteString ?? browser.address),
                        "title": .string(browser.webView.title ?? ""),
                        "loading": .bool(browser.isLoading),
                        "failed": browser.failure.map(JSONValue.string) ?? .null,
                    ])),
                to: requester)
            return
        }
        guard let agent = agent(pane) else {
            // The pane went away. Say so rather than time out: a parent that
            // knows its child is gone can do something about it.
            registry.send(
                .reply(
                    id: request,
                    result: .object([
                        "reason": .string(WaitReason.closed.rawValue),
                        "cursor": .int(Int64(query.since)),
                        "blocks": .array([]),
                    ])),
                to: requester)
            return
        }
        registry.send(
            .reply(id: request, result: agent.transcript.read(query, reason: reason)),
            to: requester)
    }

    private func agentFor(_ session: SessionID) -> AgentSession? {
        registry.pane(of: session).flatMap(agent)
    }

    /// Closing a pane closes its session, which tells the agent first.
    func endSession(for pane: PaneID) {
        guard let session = registry.session(for: pane) else { return }
        registry.close(session)
    }
}
