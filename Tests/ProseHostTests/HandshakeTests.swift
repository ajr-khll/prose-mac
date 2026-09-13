import Foundation
import ProseCore
import Testing

@testable import ProseHost

/// The handshake and the session table — spec §11's security boundary.
///
/// These drive a real socket: a listener is opened in a temporary directory and
/// a plain `AF_UNIX` client connects to it, so what is tested is the bytes on
/// the wire rather than a mock of them.
@MainActor
// Serialised: every test here drives a real socket and waits on the main
// actor, and ten of them racing for it turned into spurious timeouts rather
// than into a faster run.
@Suite("Handshake", .serialized)
struct HandshakeTests {
    /// Thrown when a helper cannot go on, so the failure is recorded once
    /// rather than cascading into every assertion after it.
    private struct ExpectationFailure: Error {}

    /// A registry with a real listener in front of it, and a client socket.
    @MainActor
    private final class Harness {
        let socket: AgentSocket
        let registry: SessionRegistry
        var events: [HostEvent] = []

        init() throws {
            // Its own directory: the default is named after the pid, which is
            // exactly right for an app that opens one socket and exactly wrong
            // for a suite that opens ten in parallel.
            socket = try AgentSocket(name: HandshakeTests.uniqueName())
            registry = SessionRegistry()
            let registry = self.registry
            socket.accept { connection in
                connection.onIncoming = { batch in
                    Task { @MainActor in registry.receive(batch, from: connection) }
                }
                connection.onClose = {
                    Task { @MainActor in registry.disconnected(connection) }
                }
            }
        }

        nonisolated deinit { socket.remove() }
    }

    /// A raw client, so the test speaks the same protocol an agent does.
    ///
    /// Reading happens on its own queue rather than on the calling thread: the
    /// registry runs on the main actor, so a test that blocked the main thread
    /// waiting for a reply would be waiting for something that cannot happen.
    private final class Client: @unchecked Sendable {
        private let descriptor: Int32
        private let lock = NSRecursiveLock()
        private var lines: [String] = []
        private var pending = Data()
        private var reader: DispatchSourceRead?

        init(path: String) throws {
            descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            var noSignal: Int32 = 1
            setsockopt(
                descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal,
                socklen_t(MemoryLayout<Int32>.size))

            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            withUnsafeMutablePointer(to: &address.sun_path) { raw in
                raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { target in
                    for (index, byte) in bytes.enumerated() { target[index] = CChar(byte) }
                    target[bytes.count] = 0
                }
            }
            let size = socklen_t(MemoryLayout<sockaddr_un>.size)
            let ok = withUnsafePointer(to: &address) { raw in
                raw.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, size)
                }
            }
            guard ok == 0 else { throw HostError.socket(errno) }

            let queue = DispatchQueue(label: "test.client")
            let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
            source.setEventHandler { [weak self] in self?.drain() }
            reader = source
            source.resume()
        }

        private func drain() {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return }

            lock.withLock {
                pending.append(contentsOf: buffer[0..<count])
                while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = pending[pending.startIndex..<end]
                    pending.removeSubrange(pending.startIndex...end)
                    if let text = String(data: Data(line), encoding: .utf8) { lines.append(text) }
                }
            }
        }

        func send(_ line: String) {
            let data = Data((line + "\n").utf8)
            _ = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        }

        /// One line, or nil if nothing arrived in time.
        ///
        /// `await`s rather than blocking: the registry runs on the main actor
        /// and so does the test, so a test that blocked would be waiting for
        /// work it is itself preventing from running.
        ///
        /// The timeout is generous on purpose. These tests assert *that* a
        /// reply arrives, never how quickly — and every suite that drives a
        /// real socket is competing for the one main actor the registry runs
        /// on, so a tight bound here measures how busy the machine is rather
        /// than whether the handshake works. At six seconds it failed roughly
        /// one full run in three.
        func readLine(timeout: TimeInterval = 20) async -> String? {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                // `withLock` rather than lock/unlock: the bare pair is
                // unavailable from an async context, because a suspension while
                // holding a lock is a deadlock waiting to happen.
                let next = lock.withLock { lines.isEmpty ? nil : lines.removeFirst() }
                if let next { return next }
                try? await Task.sleep(for: .milliseconds(20))
            }
            return nil
        }

        deinit {
            reader?.cancel()
            Darwin.close(descriptor)
        }
    }

    /// A short unique directory name.
    ///
    /// Short on purpose: `sun_path` is 104 bytes on macOS and `$TMPDIR` is
    /// already ~52 of them, so a UUID does not fit — which is the same reason
    /// `AgentSocket` checks the length rather than assuming it.
    static func uniqueName() -> String {
        "prose-t" + String(UInt32.random(in: 0..<0xFFFF_FFFF), radix: 16)
    }

    /// Yields the main actor so the registry's hops can land.
    private func settle(_ seconds: Double = 0.3) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    @Test("a hello with the right token is accepted and answered")
    func helloIsAccepted() async throws {
        let harness = try Harness()
        let reserved = harness.registry.reserve(pane: 7)
        harness.registry.onEvent = { harness.events.append($0) }

        let client = try Client(path: harness.socket.path)
        client.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(reserved.id),"token":"\#(reserved.token)","name":"echo"}}"#
        )

        let reply = try #require(await client.readLine(), "the handshake owes a reply")
        #expect(reply.contains("\"result\""))
        #expect(!reply.contains("\"error\""))

        await settle()
        #expect(harness.events.contains { if case .named(_, let name) = $0 { return name == "echo" } else { return false } })
    }

    @Test("a hello with the wrong token is refused and the connection closed")
    func helloWithABadTokenIsRefused() async throws {
        let harness = try Harness()
        let reserved = harness.registry.reserve(pane: 7)

        let client = try Client(path: harness.socket.path)
        client.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(reserved.id),"token":"guessed"}}"#
        )

        let reply = try #require(await client.readLine())
        #expect(reply.contains("-32000"), "a refusal, with a reason the agent can log")
        // And then the socket goes: an agent that cannot prove who it is gets
        // no second chance on the same connection.
        #expect(await client.readLine(timeout: 1) == nil)
    }

    @Test("anything before hello is dropped")
    func trafficBeforeHelloIsDropped() async throws {
        let harness = try Harness()
        let reserved = harness.registry.reserve(pane: 7)
        harness.registry.onEvent = { harness.events.append($0) }

        let client = try Client(path: harness.socket.path)
        client.send(
            #"{"method":"event","params":{"session":\#(reserved.id),"event":{"kind":"message.start","id":"m","role":"agent"}}}"#
        )
        await settle()

        #expect(harness.events.isEmpty, "a connection that has not identified itself is owed nothing")
    }

    @Test("an agent may only draw in the pane it owns")
    func drawingIsScopedToItsOwnSession() async throws {
        // Without this, a session could scribble in any other pane by guessing
        // an id (spec §11).
        let harness = try Harness()
        let mine = harness.registry.reserve(pane: 1)
        let theirs = harness.registry.reserve(pane: 2)
        harness.registry.onEvent = { harness.events.append($0) }

        let client = try Client(path: harness.socket.path)
        client.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(mine.id),"token":"\#(mine.token)"}}"#
        )
        _ = await client.readLine()

        client.send(
            #"{"method":"event","params":{"session":\#(theirs.id),"event":{"kind":"message.start","id":"m","role":"agent"}}}"#
        )
        client.send(
            #"{"method":"event","params":{"session":\#(mine.id),"event":{"kind":"message.start","id":"ok","role":"agent"}}}"#
        )
        await settle()

        let drawn: [SessionID] = harness.events.compactMap {
            if case .event(let session, _) = $0 { return session }
            return nil
        }
        #expect(drawn == [mine.id], "the other session's event was dropped")
    }

    @Test("an ask for someone else's session gets an explicit refusal")
    func askForAnotherSessionIsRefused() async throws {
        let harness = try Harness()
        let mine = harness.registry.reserve(pane: 1)
        let theirs = harness.registry.reserve(pane: 2)

        let client = try Client(path: harness.socket.path)
        client.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(mine.id),"token":"\#(mine.token)"}}"#
        )
        _ = await client.readLine()

        client.send(
            #"{"jsonrpc":"2.0","id":9,"method":"ask","params":{"session":\#(theirs.id),"prompt":"?"}}"#
        )
        let reply = try #require(await client.readLine())
        #expect(reply.contains("not your session"))
    }

    @Test("a notification ask is dropped rather than left pending")
    func notificationAskIsDropped() async throws {
        // The agent would otherwise wait forever for a reply it never asked
        // for (spec §10).
        let harness = try Harness()
        let mine = harness.registry.reserve(pane: 1)
        harness.registry.onEvent = { harness.events.append($0) }

        let client = try Client(path: harness.socket.path)
        client.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(mine.id),"token":"\#(mine.token)"}}"#
        )
        _ = await client.readLine()
        client.send(#"{"method":"ask","params":{"session":\#(mine.id),"prompt":"?"}}"#)
        await settle()

        #expect(!harness.events.contains { if case .ask = $0 { return true } else { return false } })
    }

    @Test("anything said before an agent connects is queued and delivered on hello")
    func backlogSurvivesUntilHello() async throws {
        // A subagent is spawned and told something in the same breath often
        // enough that dropping those lines would be a race the agent author
        // could not win (spec §11).
        let harness = try Harness()
        let reserved = harness.registry.reserve(pane: 1)

        harness.registry.send(.message(session: reserved.id, text: "before you were born"), to: reserved.id)

        let client = try Client(path: harness.socket.path)
        client.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(reserved.id),"token":"\#(reserved.token)"}}"#
        )

        _ = await client.readLine()  // the handshake reply
        let backlog = try #require(await client.readLine(), "the queued line should follow it")
        #expect(backlog.contains("before you were born"))
    }

    @Test("a result is routed to the session that spawned it")
    func resultReachesTheParent() async throws {
        let harness = try Harness()
        let parent = harness.registry.reserve(pane: 1)
        let child = harness.registry.reserve(pane: 2, parent: parent.id)

        let parentClient = try Client(path: harness.socket.path)
        parentClient.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(parent.id),"token":"\#(parent.token)"}}"#
        )
        _ = await parentClient.readLine()

        let childClient = try Client(path: harness.socket.path)
        childClient.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(child.id),"token":"\#(child.token)"}}"#
        )
        _ = await childClient.readLine()
        childClient.send(
            #"{"method":"result","params":{"session":\#(child.id),"value":{"answer":42}}}"#
        )

        let routed = try #require(await parentClient.readLine())
        #expect(routed.contains("child.result"))
        #expect(routed.contains("42"))
    }

    @Test("closing a session tells the agent before the socket goes")
    func closeIsAnnounced() async throws {
        let harness = try Harness()
        let reserved = harness.registry.reserve(pane: 1)

        let client = try Client(path: harness.socket.path)
        client.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(reserved.id),"token":"\#(reserved.token)"}}"#
        )
        _ = await client.readLine()

        harness.registry.close(reserved.id)
        let farewell = try #require(await client.readLine())
        #expect(farewell.contains("\"closed\""), "told, rather than having its socket close under it")
    }

    // MARK: - Containment (spec §11)

    /// Says hello and swallows the `{"ok":true}`, so a test can get on with
    /// what it is actually asserting.
    private func connect(_ harness: Harness, as reserved: (id: SessionID, token: String))
        async throws -> Client
    {
        let client = try Client(path: harness.socket.path)
        client.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(reserved.id),"token":"\#(reserved.token)"}}"#
        )
        _ = await client.readLine()
        return client
    }

    @Test("a second connection cannot steal a live session")
    func aLiveSessionIsNotUpForGrabs() async throws {
        // Two processes holding the same token is not a handover. Before this
        // was checked, the second silently replaced the first in the table and
        // the agent that was there stopped receiving `message`, `interrupt` and
        // `closed`, with nothing anywhere to say why.
        let harness = try Harness()
        let reserved = harness.registry.reserve(pane: 7)
        let first = try await connect(harness, as: reserved)

        let second = try Client(path: harness.socket.path)
        second.send(
            #"{"jsonrpc":"2.0","id":9,"method":"hello","params":{"session":\#(reserved.id),"token":"\#(reserved.token)"}}"#
        )

        let reply = try #require(await second.readLine(), "the intruder is owed an answer")
        #expect(reply.contains("\"error\""))

        // And the original still owns the outbound queue.
        harness.registry.send(.message(session: reserved.id, text: "still yours"), to: reserved.id)
        let delivered = try #require(await first.readLine())
        #expect(delivered.contains("still yours"))
    }

    @Test("an agent may not touch a pane it does not own")
    func panesAreNotGuessable() async throws {
        // Pane ids are small and sequential, and an agent can see its own.
        let harness = try Harness()
        let mine = harness.registry.reserve(pane: 1)
        _ = harness.registry.reserve(pane: 2)
        harness.registry.onEvent = { harness.events.append($0) }

        let client = try await connect(harness, as: mine)
        client.send(#"{"jsonrpc":"2.0","id":2,"method":"pane.close","params":{"pane":2}}"#)

        let reply = try #require(await client.readLine(), "a refused request is still owed an answer")
        #expect(reply.contains("\"error\""))
        #expect(!harness.events.contains { if case .closePane = $0 { return true } else { return false } })
    }

    @Test("a parent may act on its child's pane")
    func descendantsAreReachable() async throws {
        let harness = try Harness()
        let parent = harness.registry.reserve(pane: 1)
        _ = harness.registry.reserve(pane: 2, parent: parent.id)
        harness.registry.onEvent = { harness.events.append($0) }

        let client = try await connect(harness, as: parent)
        client.send(#"{"jsonrpc":"2.0","method":"pane.title","params":{"pane":2,"title":"child"}}"#)

        await settle()
        #expect(
            harness.events.contains {
                if case .setTitle(let pane, let title) = $0 { return pane == 2 && title == "child" }
                return false
            })
    }

    @Test("a grandchild is reachable but a sibling is not")
    func ancestryIsWalkedNotGuessed() async throws {
        let harness = try Harness()
        let parent = harness.registry.reserve(pane: 1)
        let child = harness.registry.reserve(pane: 2, parent: parent.id)
        _ = harness.registry.reserve(pane: 3, parent: child.id)   // grandchild
        _ = harness.registry.reserve(pane: 4)                     // a root of its own
        harness.registry.onEvent = { harness.events.append($0) }

        let client = try await connect(harness, as: parent)
        client.send(#"{"jsonrpc":"2.0","method":"pane.focus","params":{"pane":3}}"#)
        client.send(#"{"jsonrpc":"2.0","method":"pane.focus","params":{"pane":4}}"#)

        await settle()
        let focused = harness.events.compactMap { if case .focusPane(let p) = $0 { return p } else { return PaneID?.none } }
        #expect(focused == [3], "the grandchild, and nothing else")
    }

    @Test("a reply is never held for a session that is not connected")
    func repliesAreNotBacklogged() async throws {
        // A notification still makes sense whenever it arrives. An answer
        // belongs to the process that asked the question — and after a fresh
        // hello this session is a *new* process with its own id counter, so a
        // held reply on id 7 would land on whatever it calls request 7.
        let harness = try Harness()
        let reserved = harness.registry.reserve(pane: 7)

        harness.registry.send(.reply(id: .number(7), result: .object(["stale": .bool(true)])), to: reserved.id)
        harness.registry.send(.message(session: reserved.id, text: "kept"), to: reserved.id)

        let client = try Client(path: harness.socket.path)
        client.send(
            #"{"jsonrpc":"2.0","id":1,"method":"hello","params":{"session":\#(reserved.id),"token":"\#(reserved.token)"}}"#
        )
        _ = await client.readLine()   // the handshake's own reply

        let delivered = try #require(await client.readLine(), "the backlog is still delivered")
        #expect(delivered.contains("kept"))
        #expect(!delivered.contains("stale"))
    }

    // MARK: - Parked reads (their lifetime, which is the part that bites)

    /// The reason a parked read was answered, if it has been.
    private func answered(_ harness: Harness) -> WaitReason? {
        for event in harness.events {
            if case .answerRead(_, _, _, _, let reason) = event { return reason }
        }
        return nil
    }

    /// A parent connected, with a child parked on. Returns both sessions.
    private func supervising(_ harness: Harness, timeout: Int = 60_000) async throws
        -> (parent: SessionID, child: SessionID, client: Client)
    {
        let parent = harness.registry.reserve(pane: 1)
        let child = harness.registry.reserve(pane: 2, parent: parent.id)
        harness.registry.onEvent = { harness.events.append($0) }

        let client = try await connect(harness, as: parent)
        client.send(
            #"{"jsonrpc":"2.0","id":5,"method":"pane.read","params":{"pane":2,"until":["turn"],"timeout":\#(timeout)}}"#
        )
        await settle()
        // The workspace decides whether to park; here there is none, so the
        // test parks it by hand exactly as `Host` would.
        guard case .readPane(let request, let requester, let pane, let query)? =
            harness.events.first(where: { if case .readPane = $0 { return true } else { return false } })
        else {
            Issue.record("expected the read to reach the workspace, got \(harness.events)")
            throw ExpectationFailure()
        }
        // `target` is the child's session: the workspace resolves this from the
        // pane in `Host.readPane`, and there is no workspace here.
        harness.registry.park(
            request: request, requester: requester, pane: pane, target: child.id, query: query)
        return (parent.id, child.id, client)
    }

    @Test("a parked read is answered when its child makes progress")
    func progressWakesAParkedRead() async throws {
        let harness = try Harness()
        let supervised = try await supervising(harness)

        #expect(answered(harness) == nil, "nothing has happened yet")
        harness.registry.progress(supervised.child, .turn)
        #expect(answered(harness) == .turn)
    }

    @Test("a wait for one thing is not woken by another")
    func onlyTheRequestedConditionWakes() async throws {
        let harness = try Harness()
        let supervised = try await supervising(harness)

        harness.registry.progress(supervised.child, .ask)
        #expect(answered(harness) == nil, "this read asked about turns")
    }

    @Test("closing a pane answers whoever was waiting on it")
    func closeDoesNotOrphanAWaiter() async throws {
        // Otherwise the parent blocks until its timeout with the pane already
        // gone — and a parent blocked in its model loop is a pane that has
        // stopped responding for a reason nothing on screen explains.
        let harness = try Harness()
        let supervised = try await supervising(harness)

        harness.registry.close(supervised.child)
        #expect(answered(harness) == .closed)
    }

    @Test("a parked read times out rather than waiting forever")
    func parkedReadsExpire() async throws {
        let harness = try Harness()
        // Held, not discarded: letting the client go closes its socket, and a
        // requester that has gone away has its parked reads dropped rather than
        // answered — which is the *next* test, not this one.
        let supervised = try await supervising(harness, timeout: 120)

        await settle(0.5)
        #expect(answered(harness) == .timeout)
        withExtendedLifetime(supervised.client) {}
    }

    @Test("a read parked by a session that goes away is dropped, not answered")
    func disconnectDropsTheWaiter() async throws {
        // There is nobody left to answer, and a timer still holding the request
        // would fire into a dead connection much later.
        let harness = try Harness()
        let supervised = try await supervising(harness, timeout: 200)

        harness.registry.disconnected(harness.registry.connectionForTesting(supervised.parent)!)
        await settle(0.5)
        #expect(answered(harness) == nil, "dropped rather than answered")
    }

    @Test("the socket directory is private and is removed on exit")
    func theDirectoryIsPrivate() async throws {
        let socket = try AgentSocket(name: HandshakeTests.uniqueName())
        let attributes = try FileManager.default.attributesOfItem(atPath: socket.directory)
        let permissions = attributes[.posixPermissions] as? NSNumber

        #expect(permissions?.int16Value == 0o700, "nothing else on the machine can reach it")
        #expect(FileManager.default.fileExists(atPath: socket.path))

        socket.remove()
        #expect(!FileManager.default.fileExists(atPath: socket.directory))
    }
}
