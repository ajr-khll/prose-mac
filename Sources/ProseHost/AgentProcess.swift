//  Spawning an agent, and making sure it does not outlive prose.
//
//  plan §6.4 flags this as one of very few places where Rust's ownership was
//  buying a safety property for free: `Command::kill_on_drop(true)` meant that
//  if prose died for any reason, no agent outlived it. `Foundation.Process`
//  does **not** terminate its child on dealloc, so the same guarantee has to be
//  assembled from three parts — `deinit`, the app terminating cleanly, and the
//  crash path.

import Foundation
import ProseCore

public final class AgentProcess: @unchecked Sendable {
    private let process = Process()
    private var terminated = false

    /// Every process prose has spawned and not yet reaped.
    ///
    /// Static because the crash path has no object to ask: an `atexit` handler
    /// and a signal handler run with nothing but globals.
    private static let liveLock = NSLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: AgentProcess] = [:]

    /// The same set again, as bare pids.
    ///
    /// A signal handler may only call async-signal-safe functions: taking a
    /// lock is not one, and neither is anything that can allocate or trap. So
    /// the crash path reads a plain C array and calls `kill`, and nothing else.
    /// A stale entry costs an `ESRCH` that nobody reads; a missed one costs an
    /// agent outliving prose for as long as it takes to notice its socket has
    /// gone. Both are better than trapping inside a handler.
    private static let trackedLimit = 256
    nonisolated(unsafe) private static var tracked =
        UnsafeMutablePointer<pid_t>.allocate(capacity: trackedLimit)
    nonisolated(unsafe) private static var trackedInitialised = false

    /// What prose runs when nothing says otherwise.
    ///
    /// A whole command line rather than a path, so an agent can be
    /// `python3 -m something` without a wrapper script (spec §11). Note that
    /// `PROSE_AGENT` is split on spaces, so no path inside it may contain one.
    public static var defaultCommand: [String] {
        if let override = ProcessInfo.processInfo.environment["PROSE_AGENT"], !override.isEmpty {
            return override.split(separator: " ").map(String.init)
        }
        return [interpreter, resolveAgentFile("pane_agent.py") ?? "agents/pane_agent.py"]
    }

    /// The Python that has the Agent SDK in it.
    ///
    /// `Scripts/setup-agents.sh` builds `agents/.venv`, and that virtual
    /// environment is the only place `claude_agent_sdk` exists — a bare
    /// `python3` raises `ModuleNotFoundError` on the first import and the pane
    /// opens on `agent exited (code 1)` with nothing saying why. The fallback
    /// is still a bare `python3`, because `echo_agent.py` imports nothing but
    /// the standard library and must keep working before anyone has run setup.
    public static var interpreter: String {
        resolveAgentFile(".venv/bin/python3") ?? "python3"
    }

    /// Resolves the same fixed flavour namespace `prose_spawn` exposes. A
    /// stored automation never contains argv; at execution time it names one
    /// of prose's own entry points or an archetype file that exists now.
    public static func command(flavour: String, parameters: JSONValue = .object([:])) -> [String]? {
        switch flavour {
        case "prose":
            return []
        case "code":
            return [interpreter, resolveAgentFile("code_agent.py") ?? "agents/code_agent.py"]
        default:
            let valid = flavour.range(
                of: #"^[a-z0-9][a-z0-9-]{0,63}$"#, options: .regularExpression) != nil
            guard valid,
                  resolveAgentFile("archetypes/\(flavour).md") != nil,
                  let entry = resolveAgentFile("archetype_agent.py")
            else { return nil }
            return [interpreter, entry, flavour, parameters.line()]
        }
    }

    /// Where something under `agents/` actually is, if it can be found.
    ///
    /// Spec §11 writes the default command with a relative path, which only
    /// resolves when prose was started from the repository. Double-clicked, or
    /// launched with `open`, the working directory is `/` and every pane opens
    /// on `agent exited (code 2)`. Since these files are prose's own rather
    /// than the user's, prose looks for them — beside the executable, inside a
    /// bundle's Resources, then up towards a source checkout — and falls back
    /// to the relative spelling only if they are nowhere. An explicit
    /// `PROSE_AGENT`, or a `command` from an agent, is still taken exactly as
    /// written.
    ///
    /// `agents/prose_agent/skills.py` walks the same ladder from the Python
    /// side, to find the bundled skills. The two must stay in step.
    public static func resolveAgentFile(_ relative: String) -> String? {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        var directory = binary.deletingLastPathComponent()

        var candidates = [
            directory.appendingPathComponent("agents/\(relative)"),
            // .app/Contents/MacOS/prose → .app/Contents/Resources/agents/…
            directory.deletingLastPathComponent()
                .appendingPathComponent("Resources/agents/\(relative)"),
        ]
        // Then up towards a checkout: .build/Prose.app/Contents/MacOS is five
        // levels below the package root, and a test bundle's MacOS directory
        // is seven.
        for _ in 0..<8 {
            candidates.append(directory.appendingPathComponent("agents/\(relative)"))
            directory = directory.deletingLastPathComponent()
        }
        // And finally where the relative spelling would have pointed, which is
        // what makes this work under `swift test` — those run from the package
        // root, and the built binary is further down than the ladder reaches
        // in some configurations.
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("agents/\(relative)"))

        return candidates.first { FileManager.default.isReadableFile(atPath: $0.path) }?.path
    }

    /// Called when the child exits, with the notice its pane should show.
    public var onExit: (@Sendable (String) -> Void)?

    public init(
        command: [String],
        cwd: URL,
        environment: [String: String],
        socket: String,
        session: SessionID,
        token: String
    ) {
        let argv = command.isEmpty ? Self.defaultCommand : command
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.currentDirectoryURL = cwd

        var inherited = ProcessInfo.processInfo.environment
        for (key, value) in environment { inherited[key] = value }
        // The three things an agent needs to reach prose and prove who it is.
        inherited["PROSE_SOCKET"] = socket
        inherited["PROSE_SESSION"] = String(session)
        inherited["PROSE_TOKEN"] = token
        process.environment = inherited
    }

    /// Forwards the agent's stderr when `PROSE_FRAME=1` is set.
    ///
    /// An agent that fails to start says why on stderr and then exits, and
    /// without this the only symptom is a pane that stays empty.
    private func forwardDiagnostics() {
        guard ProcessInfo.processInfo.environment["PROSE_FRAME"] == "1" else { return }
        let pipe = Pipe()
        process.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            FileHandle.standardError.write(Data("AGENT ".utf8) + data)
        }
    }

    public func start() throws {
        forwardDiagnostics()
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            Self.forget(self)
            // spec §11: the pane gets a notice and is **not** closed.
            let notice: String
            switch process.terminationReason {
            case .exit where process.terminationStatus == 0: notice = "agent finished"
            case .exit: notice = "agent exited (code \(process.terminationStatus))"
            case .uncaughtSignal: notice = "agent exited (signal \(process.terminationStatus))"
            @unknown default: notice = "agent exited"
            }
            self.onExit?(notice)
        }

        try process.run()
        Self.remember(self)
    }

    public func terminate() {
        guard !terminated, process.isRunning else { return }
        terminated = true
        process.terminate()
    }

    deinit {
        // The first of plan §6.4's three parts.
        if !terminated && process.isRunning { process.terminate() }
    }

    // MARK: - The crash path

    private static func remember(_ process: AgentProcess) {
        liveLock.lock()
        defer { liveLock.unlock() }
        live[ObjectIdentifier(process)] = process

        if !trackedInitialised {
            tracked.initialize(repeating: 0, count: trackedLimit)
            trackedInitialised = true
        }
        let pid = process.process.processIdentifier
        for slot in 0..<trackedLimit where tracked[slot] == 0 {
            tracked[slot] = pid
            return
        }
    }

    private static func forget(_ process: AgentProcess) {
        liveLock.lock()
        defer { liveLock.unlock() }
        live[ObjectIdentifier(process)] = nil

        guard trackedInitialised else { return }
        let pid = process.process.processIdentifier
        for slot in 0..<trackedLimit where tracked[slot] == pid { tracked[slot] = 0 }
    }

    /// What the crash path runs. Nothing here allocates, locks or can trap.
    private static func killTracked() {
        guard trackedInitialised else { return }
        for slot in 0..<trackedLimit {
            let pid = tracked[slot]
            if pid > 0 { kill(pid, SIGTERM) }
        }
    }

    /// Kills everything prose spawned. Safe to call more than once.
    public static func terminateAll() {
        liveLock.lock()
        let processes = Array(live.values)
        liveLock.unlock()
        for process in processes { process.terminate() }
    }

    /// The third part: `atexit` for a clean-ish exit, and handlers for the
    /// signals that would otherwise take prose down without unwinding.
    ///
    /// A signal handler may call almost nothing, so these re-raise the signal
    /// after killing the children rather than trying to do anything clever.
    public static func installCrashHandlers() {
        atexit { AgentProcess.killTracked() }

        // A signal-terminated process runs no `atexit` handlers, so everything
        // that has to happen on the way out has to happen here too — the
        // children, and the socket directory they were reaching prose on.
        for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
            signal(signalNumber) { number in
                AgentProcess.killTracked()
                AgentSocket.cleanUpTracked()
                signal(number, SIG_DFL)
                raise(number)
            }
        }
    }
}
