import Foundation
import ProseCore
import ProseHost
import Testing

@testable import Prose

/// The whole thing, through a real socket and a real agent process.
///
/// spec §11 recorded that `agents/echo_agent.py` did not exist, "which means
/// nothing on the agent side has ever been run end to end". This is that run:
/// a `Workspace` opens the socket, spawns the Python agent, the agent connects
/// and says hello, and a message typed into the composer comes back as a turn
/// folded into the transcript by step 1's reducer.
///
/// Nothing here is mocked. If this passes, prose works.
@MainActor
@Suite("End to end", .serialized)
struct EndToEndTests {
    /// Every test in this suite runs the **echo** agent, never the real one.
    ///
    /// `AgentProcess.defaultCommand` names `pane_agent.py`, which is a Claude
    /// session: six tests spawning several panes each, on every `swift test`,
    /// would mean the suite has a bill and a rate limit. The echo agent is the
    /// only agent that exercises the whole wire for free, which is why it was
    /// not retired when the real one landed — so it is pinned here rather than
    /// left to whatever the environment happens to say.
    ///
    /// `Workspace(hosting: .enabled)` spawns during `init`, so this has to
    /// have run before the first one is constructed. A static initialiser is
    /// how a swift-testing suite gets a before-anything hook.
    private static let pinned: Void = {
        let echo = AgentProcess.resolveAgentFile("echo_agent.py") ?? "agents/echo_agent.py"
        setenv("PROSE_AGENT", "python3 \(echo)", 1)
    }()

    init() { Self.pinned }

    /// Yields the main actor until `condition` holds — the host's work is
    /// enqueued there, so a test that blocked would prevent it.
    private func wait(upTo seconds: Double, for condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    @Test("an agent connects, says hello, and names its pane")
    func theAgentConnects() async throws {
        let workspace = Workspace(hosting: .enabled)
        defer { workspace.socket?.remove() }

        let pane = try #require(workspace.activeTab?.panes.first?.id)
        #expect(workspace.socket != nil, "the socket opened")
        #expect(workspace.hostFailure == nil)

        // `hello` carries a name, and the pane takes it (spec §8, §10).
        await wait(upTo: 15) { workspace.activeTab?.pane(pane)?.title != nil }
        #expect(workspace.activeTab?.pane(pane)?.displayTitle == "echo")
    }

    /// The real agent, in a real pane, spending real money.
    ///
    /// **Off unless `PROSE_SDK_E2E=1`.** Everything else in this suite is free
    /// because the echo agent has no model behind it; this one starts a Claude
    /// session, so it cannot be something `swift test` does by default. What it
    /// buys is the one thing the Python tests cannot: that the band-A mapping
    /// survives the whole round trip — SDK stream to `Events` to the socket to
    /// `parseEvent` to the reducer to a drawable block.
    ///
    /// It asserts only what is stable. **Never assert on what the model said**;
    /// assert that it said something.
    /// The browser pilot, walking real pages, with every call it makes on disk.
    ///
    /// **Off unless `PROSE_BROWSER_E2E=1`**, for the same reason as the test
    /// below it: there is a model behind this one. It exists because the
    /// question it answers cannot be answered any other way — not "do the
    /// browser tools work", which `BrowserPaneTests` settles for free, but
    /// *which tool the model actually reaches for* when it wants something
    /// from a page. That is a fact about the model and the descriptions
    /// together, and the only instrument for it is a real errand.
    ///
    /// So this asserts almost nothing and **records everything**:
    /// `PROSE_LOG_DIR` turns on the traffic log, which is every line either
    /// way, and the eval log, which is every script the pilot wrote. Read
    /// those; the expectations here only catch the run having failed to
    /// happen at all.
    @Test("the browser pilot walks real pages",
          .enabled(if: ProcessInfo.processInfo.environment["PROSE_BROWSER_E2E"] == "1"))
    func theBrowserPilotWalks() async throws {
        let interpreter = AgentProcess.interpreter
        let script = try #require(AgentProcess.resolveAgentFile("archetype_agent.py"))
        // **No spaces.** `AgentProcess.defaultCommand` splits `PROSE_AGENT`
        // on spaces and execs the pieces directly — there is no shell here to
        // honour a quote, so a pretty-printed parameter object arrives as four
        // arguments and the archetype opens with none of them.
        let parameters = #"{"scope":"https://en.wikipedia.org","budget":30}"#
        setenv("PROSE_AGENT", "\(interpreter) \(script) browser-pilot \(parameters)", 1)
        defer { Self.pinned }

        // Where the evidence lands. Named by the run so two goes at the same
        // errand can be compared rather than concatenated.
        let logs =
            ProcessInfo.processInfo.environment["PROSE_LOG_DIR"]
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("prose-pilot-\(Int(Date().timeIntervalSince1970))").path
        setenv("PROSE_LOG_DIR", logs, 1)
        print("pilot logs: \(logs)")

        let workspace = Workspace(hosting: .enabled)
        defer { workspace.socket?.remove() }

        let pane = try #require(workspace.activeTab?.panes.first?.id)
        let agent = try #require(workspace.agent(pane))
        await wait(upTo: 60) { workspace.activeTab?.pane(pane)?.title != nil }

        agent.send(
            """
            Open Michael Bublé's Wikipedia page and click links until you \
            reach the article on Philosophy. Report the path you took.
            """)

        // Generous: this is a walk of several pages, each with a model turn
        // between them. The condition is the turn ending, not the answer
        // being right — whether it *arrived* is a question for the log.
        await wait(upTo: 900) {
            !agent.transcript.isRunning && agent.transcript.clock > 2
        }

        #expect(!agent.transcript.isRunning, "the walk never finished")
        #expect(
            workspace.activeTab?.panes.contains { workspace.browser($0.id) != nil } == true,
            "the pilot never opened a browser pane, so nothing was measured")
    }

    @Test("the SDK agent runs a real turn in a pane",
          .enabled(if: ProcessInfo.processInfo.environment["PROSE_SDK_E2E"] == "1"))
    func theRealAgentRunsATurn() async throws {
        let interpreter = AgentProcess.interpreter
        let agentScript = try #require(AgentProcess.resolveAgentFile("pane_agent.py"))
        setenv("PROSE_AGENT", "\(interpreter) \(agentScript)", 1)
        // Back to the echo agent, whatever happens — a leaked override would
        // quietly make every later test in this process cost money.
        defer { Self.pinned }

        let workspace = Workspace(hosting: .enabled)
        defer { workspace.socket?.remove() }

        let pane = try #require(workspace.activeTab?.panes.first?.id)
        let agent = try #require(workspace.agent(pane))

        await wait(upTo: 60) { workspace.activeTab?.pane(pane)?.title != nil }
        agent.send("Reply with the single word: ready.")

        // A turn that started and then stopped running is the whole condition;
        // how long the model takes is not this test's business.
        await wait(upTo: 180) {
            agent.transcript.blocks.contains {
                if case .message(_, .agent, let text, _) = $0 { return !text.isEmpty }
                return false
            } && !agent.transcript.isRunning
        }

        let blocks = agent.transcript.blocks
        let said = blocks.compactMap { block -> String? in
            if case .message(_, .agent, let text, _) = block { return text }
            return nil
        }
        #expect(said.contains { !$0.isEmpty }, "the agent said nothing at all")
        #expect(!agent.transcript.isRunning, "the turn never ended")

        // Band A, which nothing on the echo path can prove: the model and the
        // skill count both come off the SDK's own stream at no model cost.
        #expect(agent.transcript.status["model"]?.isEmpty == false,
                "no model reached the header")
        #expect(agent.transcript.status["skills"]?.isEmpty == false,
                "the init message never arrived, so no skills loaded")

        // A notice means the turn failed — most likely no credentials.
        let notices = blocks.compactMap { block -> String? in
            if case .notice(let message) = block { return message }
            return nil
        }
        #expect(notices.isEmpty, "the turn left a notice: \(notices)")
    }

    @Test("a message comes back as a real turn")
    func aRealTurnRenders() async throws {
        let workspace = Workspace(hosting: .enabled)
        defer { workspace.socket?.remove() }

        let pane = try #require(workspace.activeTab?.panes.first?.id)
        let agent = try #require(workspace.agent(pane))

        // Wait for the handshake, so the message is not merely queued.
        await wait(upTo: 15) { workspace.activeTab?.pane(pane)?.title != nil }

        agent.send("hello from the composer")
        await wait(upTo: 15) {
            agent.transcript.blocks.contains {
                if case .attachment = $0 { return true } else { return false }
            }
        }

        let blocks = agent.transcript.blocks

        // The user's own message, first.
        guard case .message(_, let role, let sent, _)? = blocks.first else {
            Issue.record("expected the user's message first, got \(blocks)")
            return
        }
        #expect(role == .user)
        #expect(sent == "hello from the composer")

        // An activity that arrived twice and resolved in place rather than
        // appearing twice — step 1's reducer rule, exercised over a real wire.
        let activities = blocks.compactMap { block -> (String, ActivityState)? in
            if case .activity(_, let label, _, let state, _) = block { return (label, state) }
            return nil
        }
        #expect(activities.count == 1, "one row, updated in place")
        #expect(activities.first?.0 == "Read")
        #expect(activities.first?.1 == .ok)

        // The streamed reply, reassembled from deltas.
        let agentText = blocks.compactMap { block -> String? in
            if case .message(_, .agent, let text, _) = block { return text }
            return nil
        }
        #expect(agentText.first?.contains("You said: hello from the composer") == true)

        // And the code attachment.
        let code = blocks.compactMap { block -> ProseCore.Attachment? in
            if case .attachment(let attachment) = block { return attachment }
            return nil
        }
        #expect(code.first?.kind == "code")
        #expect(code.first?.text.contains("hello from the composer") == true)

        // The turn ended, so nothing is still streaming and the header is no
        // longer saying `thinking…`.
        await wait(upTo: 5) { !agent.transcript.isRunning }
        #expect(!agent.transcript.isRunning)
        let stillStreaming = blocks.contains {
            if case .message(_, _, _, let streaming) = $0 { return streaming } else { return false }
        }
        #expect(!stillStreaming || !agent.transcript.isRunning)
    }

    @Test("status fields from the agent reach the pane header")
    func statusReachesTheHeader() async throws {
        let workspace = Workspace(hosting: .enabled)
        defer { workspace.socket?.remove() }

        let pane = try #require(workspace.activeTab?.panes.first?.id)
        let agent = try #require(workspace.agent(pane))
        await wait(upTo: 15) { workspace.activeTab?.pane(pane)?.title != nil }

        agent.send("status please")
        await wait(upTo: 15) { !agent.transcript.statusInOrder.isEmpty }

        #expect(agent.transcript.status["model"] == "echo")
    }

    @Test("closing a pane tells its agent and reaps the process")
    func closingReapsTheAgent() async throws {
        let workspace = Workspace(hosting: .enabled)
        defer { workspace.socket?.remove() }

        let first = try #require(workspace.activeTab?.panes.first?.id)
        workspace.splitPane(first, .row)
        let second = try #require(workspace.activeTab?.focused)
        await wait(upTo: 15) { workspace.activeTab?.pane(second)?.title != nil }

        #expect(workspace.registry.session(for: second) != nil)
        workspace.closePane(second)
        #expect(workspace.registry.session(for: second) == nil, "the session went with the pane")
    }

    @Test("the app still runs when the socket cannot be opened")
    func noSocketIsNotFatal() async throws {
        // spec §11: panes render, they just stay empty. A window with no agents
        // is worth more than refusing to open at all.
        let workspace = Workspace(hosting: .enabled)
        defer { workspace.socket?.remove() }

        // Whether or not the socket opened, the shell is intact.
        #expect(workspace.tabs.count == 1)
        #expect(workspace.activeTab?.panes.count == 1)
        #expect(workspace.activeTab?.placed().count == 1)
    }

    @Test("a parent spawns a subagent, waits on it, and reads what it did")
    func supervisionRunsEndToEnd() async throws {
        // The whole design in one run, unmocked: two real processes, a real
        // socket, a real split. The parent asks prose for a pane, sends its
        // child a task, parks on `pane.read` until the child's turn ends, and
        // reports how many blocks came back.
        let workspace = Workspace(hosting: .enabled)
        defer { workspace.socket?.remove() }

        let parent = try #require(workspace.activeTab?.panes.first?.id)
        await wait(upTo: 15) { workspace.agent(parent)?.session != nil }

        workspace.agent(parent)?.send("spawn hello from the parent")

        // The split happens because the *agent* asked for it.
        await wait(upTo: 30) { (workspace.activeTab?.panes.count ?? 0) > 1 }
        #expect(workspace.activeTab?.panes.count == 2, "the subagent got a pane")

        let child = try #require(workspace.activeTab?.panes.map(\.id).first { $0 != parent })
        #expect(workspace.agent(child) != nil, "and a session of its own")

        // The child ran the task it was sent — proof `pane.send` reached it.
        await wait(upTo: 30) {
            workspace.agent(child)?.transcript.blocks.contains {
                if case .message(_, .agent, let text, _) = $0 {
                    return text.contains("hello from the parent")
                }
                return false
            } ?? false
        }

        // And the parent's wait came back, which is the part that would hang
        // if `pane.read` were edge-triggered.
        await wait(upTo: 30) {
            workspace.agent(parent)?.transcript.blocks.contains {
                if case .message(_, .agent, let text, _) = $0 { return text.contains("child woke on") }
                return false
            } ?? false
        }

        let reported = workspace.agent(parent)?.transcript.blocks.compactMap { block -> String? in
            if case .message(_, .agent, let text, _) = block, text.contains("child woke on") {
                return text
            }
            return nil
        }.first
        let summary = try #require(reported, "the parent never reported on its child")
        #expect(summary.contains("'turn'"), "it woke because the turn ended: \(summary)")
        #expect(!summary.contains("with 0 blocks"), "and it got the child's work with it")
    }

    @Test("an agent opens a browser pane and reads the page back")
    func browserDrivenByAnAgent() async throws {
        // plan §11.4, answered: the browser pane is a surface an agent drives,
        // not only one a user reads. Two processes, a real WKWebView, and a
        // real page — the agent asks for the pane, prose loads it, and the text
        // comes back over the same socket everything else does.
        let page = FileManager.default.temporaryDirectory
            .appendingPathComponent("prose-e2e-\(UUID().uuidString).html")
        try "<html><body><h1>the split tree holds</h1></body></html>".write(
            to: page, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: page) }

        let workspace = Workspace(hosting: .enabled)
        defer { workspace.socket?.remove() }

        let agentPane = try #require(workspace.activeTab?.panes.first?.id)
        await wait(upTo: 30) { workspace.agent(agentPane)?.session != nil }

        workspace.agent(agentPane)?.send("browse \(page.absoluteString)")

        await wait(upTo: 30) { (workspace.activeTab?.panes.count ?? 0) > 1 }
        let browserPane = try #require(
            workspace.activeTab?.panes.first { $0.id != agentPane })
        #expect(browserPane.kind == .browser, "the agent asked for a browser, and got one")
        #expect(workspace.browser(browserPane.id) != nil)

        await wait(upTo: 30) {
            workspace.agent(agentPane)?.transcript.blocks.contains {
                if case .message(_, .agent, let text, _) = $0 { return text.contains("page says:") }
                return false
            } ?? false
        }

        let reported = workspace.agent(agentPane)?.transcript.blocks.compactMap { block -> String? in
            if case .message(_, .agent, let text, _) = block, text.contains("page says:") {
                return text
            }
            return nil
        }.first
        let said = try #require(reported, "the agent never reported on the page")
        #expect(said.contains("the split tree holds"), "it read the rendered text: \(said)")
    }
}

