//  The listening socket, and one connection on it.
//
//  # Why a socket rather than a pipe
//
//  An agent may ask prose to open a pane and run a **subagent** in it, and that
//  subagent is a process of its own. Over a stdio pipe it could only reach
//  prose by having its parent relay every line. A socket means any process
//  prose spawned can talk to prose directly, using the session token it was
//  handed in its environment — which is what makes subagents-in-panes fall out
//  of the design instead of needing plumbing (spec §11).
//
//  # Why POSIX rather than Network.framework
//
//  plan §8 proposed `NWListener` with an `NWEndpoint.unix(path:)` required
//  local endpoint, and told the port to *verify that against the SDK before
//  committing to it*. Verified: it fails at `.ready` with POSIX error 22,
//  `Invalid argument`. So this is the bulletproof fallback the same paragraph
//  names — `socket(AF_UNIX, SOCK_STREAM, 0)` plus `bind`, `listen`, and a
//  `DispatchSource` per descriptor.

import Foundation
import ProseCore

/// A line-delimited JSON-RPC connection to one agent process.
///
/// Reads and writes happen on `queue` and nowhere else, which is the whole of
/// this class's thread safety.
public final class Connection: @unchecked Sendable {
    private let descriptor: Int32
    private let queue: DispatchQueue
    private var reader: DispatchSourceRead?
    private var pending = Data()
    private var closed = false

    /// Parsed lines, delivered on the main actor.
    ///
    /// A batch rather than a line, because plan §8 moves spec §9.2's 16ms
    /// window *below* the main-actor hop: a fast agent doing one hop per token
    /// is the real cost, not the drawing, which SwiftUI already coalesces to
    /// the display refresh.
    public var onIncoming: (@Sendable ([Incoming]) -> Void)?
    public var onClose: (@Sendable () -> Void)?

    /// Events waiting for the next flush, and whether one is already scheduled.
    private var coalescing: [Incoming] = []
    private var flushScheduled = false

    init(descriptor: Int32) {
        self.descriptor = descriptor
        queue = DispatchQueue(label: "prose.connection.\(descriptor)")
        // Writing to a socket whose far end has gone raises SIGPIPE, whose
        // default action is to kill the process — so an agent crashing at the
        // wrong moment would take prose down with it. Per-descriptor, because
        // it is this socket's problem rather than the process's.
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        reader = source
        source.resume()
    }

    /// Which session said hello on this connection, once one has.
    ///
    /// Only the traffic log reads it, and only to label a line. Guarded by its
    /// own lock rather than hopping a queue, because it is written once from
    /// the main actor and read from the socket's queue on every line — and a
    /// debugging aid must not be the thing that introduces a data race.
    private let sessionLock = NSLock()
    private var boundSession: SessionID?

    var session: SessionID? {
        get { sessionLock.withLock { boundSession } }
        set { sessionLock.withLock { boundSession = newValue } }
    }

    public func close() {
        queue.async { [weak self] in self?.shutDown() }
    }

    private func shutDown() {
        guard !closed else { return }
        closed = true
        flush()
        reader?.cancel()
        onClose?()
    }

    // MARK: - Reading

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let count = read(descriptor, &buffer, buffer.count)

        guard count > 0 else {
            // 0 is a clean close; anything negative that is not "try again" is
            // the agent going away mid-sentence. Either way the pane is told by
            // the process watcher, not here.
            if count == 0 || (errno != EAGAIN && errno != EINTR) { shutDown() }
            return
        }

        pending.append(contentsOf: buffer[0..<count])
        deliverCompleteLines()
    }

    /// Framing is by newline, so a partial line stays in the buffer until the
    /// rest of it arrives.
    private func deliverCompleteLines() {
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<end]
            pending.removeSubrange(pending.startIndex...end)

            guard let text = String(data: Data(line), encoding: .utf8) else { continue }
            // Logged *before* parsing, so a line prose could not understand is
            // in the log too. Those are the ones worth having.
            TrafficLog.shared?.record("in", session: session, line: text)
            // Parsing happens here, off the main actor, and a line prose does
            // not understand becomes nothing at all (spec §10).
            guard let incoming = parseLine(text) else { continue }
            classify(incoming)
        }
    }

    /// Drawing can wait a frame; being asked a question cannot.
    ///
    /// spec §9.2: an event schedules a single flush 16ms out and further events
    /// land in the same one. An **ask** and a **notice** bypass it, because both
    /// are the agent asking the user to do something — and so does everything
    /// that is not an event at all, since a pane appearing or closing is not
    /// something to batch.
    private func classify(_ incoming: Incoming) {
        if case .notification(.event) = incoming {
            coalescing.append(incoming)
            scheduleFlush()
            return
        }
        // Order matters: an ask that follows a run of deltas has to arrive
        // after them, so the buffer goes out first and in the same batch.
        coalescing.append(incoming)
        flush()
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        queue.asyncAfter(deadline: .now() + .milliseconds(16)) { [weak self] in
            self?.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !coalescing.isEmpty else { return }
        let batch = coalescing
        coalescing.removeAll(keepingCapacity: true)
        onIncoming?(batch)
    }

    // MARK: - Writing

    public func send(_ outgoing: Outgoing) {
        let line = outgoing.line()
        TrafficLog.shared?.record("out", session: session, line: line)
        queue.async { [weak self] in self?.write(Data((line + "\n").utf8)) }
    }

    private func write(_ data: Data) {
        guard !closed else { return }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(descriptor, raw.baseAddress! + offset, raw.count - offset)
                if written > 0 {
                    offset += written
                } else if errno == EINTR {
                    continue
                } else {
                    // The agent has gone. The pane finds out from its process.
                    shutDown()
                    return
                }
            }
        }
    }
}

/// The listening socket and the private directory it lives in.
public final class AgentSocket: @unchecked Sendable {
    public let path: String
    public let directory: String

    private let descriptor: Int32
    private var acceptor: DispatchSourceRead?
    private let queue = DispatchQueue(label: "prose.listener")

    /// Opens `$TMPDIR/prose-<pid>/agents.sock`.
    ///
    /// Throws rather than trapping, because spec §11 is explicit that **if the
    /// socket cannot be opened the app still runs**: panes render, they just
    /// stay empty. A window with no agents is worth more than refusing to open
    /// at all.
    /// `name` is the directory under `$TMPDIR`, and defaults to the one spec
    /// §11 specifies. It is a parameter only so that two sockets can exist in
    /// one process during tests: the real app opens exactly one, and naming it
    /// after the pid is what makes it unambiguous.
    public init(name: String = "prose-\(getpid())") throws {
        let temporary = NSTemporaryDirectory()
        directory = (temporary as NSString).appendingPathComponent(name)

        // Mode 0700, so nothing else on the machine can reach the socket.
        try FileManager.default.createDirectory(
            atPath: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        path = (directory as NSString).appendingPathComponent("agents.sock")
        try? FileManager.default.removeItem(atPath: path)

        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HostError.socket(errno) }
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        // `sun_path` is 104 bytes on macOS and $TMPDIR is already long, so a
        // path that does not fit is a real possibility rather than a formality.
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(descriptor)
            throw HostError.pathTooLong(path)
        }
        withUnsafeMutablePointer(to: &address.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { target in
                for (index, byte) in bytes.enumerated() { target[index] = CChar(byte) }
                target[bytes.count] = 0
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { raw in
            raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, size) }
        }
        guard bound == 0 else {
            Darwin.close(descriptor)
            throw HostError.bind(errno)
        }
        guard listen(descriptor, 16) == 0 else {
            Darwin.close(descriptor)
            throw HostError.listen(errno)
        }
    }

    /// Starts accepting. `onConnection` is called on the listener's own queue.
    public func accept(_ onConnection: @escaping @Sendable (Connection) -> Void) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [descriptor] in
            let incoming = Darwin.accept(descriptor, nil, nil)
            guard incoming >= 0 else { return }
            let connection = Connection(descriptor: incoming)
            onConnection(connection)
            connection.start()
        }
        source.setCancelHandler { [descriptor] in Darwin.close(descriptor) }
        acceptor = source
        source.resume()
    }

    /// Best effort: a stale socket in a temp directory is harmless, but leaving
    /// one per run is untidy.
    public func remove() {
        acceptor?.cancel()
        try? FileManager.default.removeItem(atPath: directory)
    }

    /// Also tidy it away if prose exits without anyone calling `remove`.
    ///
    /// The handler lives here rather than at the call site because a closure
    /// written inside a `@MainActor` type *inherits that isolation*, and an
    /// isolated closure handed to `atexit` asserts it is on the main queue —
    /// which at exit it is not, so the process traps on its way out. This one
    /// is nonisolated and calls nothing that can trap.
    public func removeOnExit() {
        // Both paths are pre-rendered as C strings now, so the handler itself
        // allocates nothing.
        Self.directoryToClean = strdup(directory)
        Self.socketToClean = strdup(path)
        atexit { AgentSocket.cleanUpTracked() }
    }

    /// Removes the tracked directory using nothing but `unlink` and `rmdir`.
    ///
    /// Called from `atexit` and from the signal handlers, so it must not
    /// allocate, lock, or touch anything isolated. Both calls are
    /// async-signal-safe and both are allowed to fail — spec §11 asks for best
    /// effort, and a stale socket in a temp directory is harmless.
    public static func cleanUpTracked() {
        if let socket = socketToClean { unlink(socket) }
        if let directory = directoryToClean { rmdir(directory) }
    }

    nonisolated(unsafe) private static var directoryToClean: UnsafeMutablePointer<CChar>?
    nonisolated(unsafe) private static var socketToClean: UnsafeMutablePointer<CChar>?
}

public enum HostError: Error {
    case socket(Int32)
    case bind(Int32)
    case listen(Int32)
    case pathTooLong(String)
}
