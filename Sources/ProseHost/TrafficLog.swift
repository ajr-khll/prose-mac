//  Every line, on disk, when someone asks for it.
//
//  Debugging a misbehaving agent otherwise means `PROSE_FRAME=1` and reading
//  stderr, which shows what the agent *said it was doing* rather than what it
//  actually put on the wire. This writes the wire itself: one JSON object per
//  line, per session, in and out.
//
//  # Not the read path
//
//  This is deliberately **not** how a parent reads a subagent — that is
//  `pane.read`, which answers in reduced blocks against a cursor. A log is a
//  second rendering of the same events and would drift from the reducer beside
//  it; grepping one costs an unbounded number of tokens for an unshaped answer;
//  and it cannot say "wake me when something happens", so reading one means
//  polling. See `TranscriptRead.swift`.
//
//  What a log is genuinely good at is the thing a cursor cannot do: telling you
//  what happened *before* the bug, after the fact, from outside the process.
//  So it is off unless `PROSE_LOG_DIR` names somewhere to write.

import Foundation
import ProseCore

/// Writes the traffic for one run, if asked to.
public final class TrafficLog: @unchecked Sendable {
    /// `nil` unless `PROSE_LOG_DIR` is set, which is the switch.
    public static let shared: TrafficLog? = {
        guard let directory = ProcessInfo.processInfo.environment["PROSE_LOG_DIR"],
              !directory.isEmpty
        else { return nil }
        return TrafficLog(directory: directory)
    }()

    private let directory: String
    /// Its own queue: a log that made the main actor wait on a disk would be a
    /// worse problem than the one it was opened to diagnose.
    private let queue = DispatchQueue(label: "prose.traffic-log", qos: .utility)
    private var handle: FileHandle?

    init(directory: String) {
        self.directory = directory
    }

    /// A session token, wherever one appears in a line.
    ///
    /// Tokens are 32 random bytes and the only thing standing between an agent
    /// and any other agent's pane, so they do not go in a file someone might
    /// reasonably paste into a bug report. Only `hello` carries one, but the
    /// pattern is matched rather than the method, so a later call that carries
    /// one is covered without anyone having to remember this.
    private static let token = try? NSRegularExpression(
        pattern: #""token"\s*:\s*"[^"]*""#)

    /// One line, as it crossed. `direction` is `in` or `out`.
    public func record(_ direction: String, session: SessionID?, line: String) {
        let stamp = Date().timeIntervalSince1970
        let line = Self.redacted(line)
        queue.async { [weak self] in
            guard let self else { return }
            // The line is already JSON, so it goes in as a string rather than
            // being parsed and re-encoded — a log that reformats what it
            // records cannot be used to answer "what exactly was sent".
            let entry: [String: JSONValue] = [
                "at": .double(stamp),
                "dir": .string(direction),
                "session": session.map { JSONValue.int(Int64($0)) } ?? .null,
                "line": .string(line),
            ]
            self.append(JSONValue.object(entry).line())
        }
    }

    private static func redacted(_ line: String) -> String {
        guard let token else { return line }
        return token.stringByReplacingMatches(
            in: line, range: NSRange(line.startIndex..., in: line),
            withTemplate: #""token":"…""#)
    }

    private func append(_ text: String) {
        if handle == nil { handle = Self.open(in: directory) }
        guard let handle, let data = (text + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    private static func open(in directory: String) -> FileHandle? {
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        // Named for the run, not the session: interleaving is the point, since
        // what usually matters is what a parent and its child were doing to
        // each other at the same moment.
        let path = (directory as NSString)
            .appendingPathComponent("prose-\(getpid()).ndjson")
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return nil }
        // Appended to rather than truncated: a run that crashes and is started
        // again should not erase the evidence from the run that crashed.
        _ = try? handle.seekToEnd()
        return handle
    }
}
