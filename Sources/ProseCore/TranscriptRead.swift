//  Reading someone else's transcript, cheaply.
//
//  A parent supervising a subagent needs to know what happened in its pane
//  without paying for every word of it. That is this file: a query, a cursor,
//  and two fidelities.
//
//  # Why this is not a log
//
//  The obvious design is a text log per pane that a parent greps and tails. It
//  loses four ways. It is a second source of truth that drifts from the reducer
//  next door, so a bug in the log stops matching the bug on screen. Its cost is
//  unbounded and unshaped — `tail -n 200` spends tokens on prose nobody asked
//  for. It cannot say "wake me when something happens", so the parent polls.
//  And `grep` is a poor index over blocks that are already typed: "the
//  activities that failed" is a filter here and a regex guess there.
//
//  What a parent actually asks is *"what changed since I last looked, and was
//  any of it worth reading in full"*. That is two stages, and the saving is the
//  whole point of the file:
//
//      a representative turn, read in full      ≈ 14,120 chars ≈ 3,530 tokens
//      the same turn, summarised                ≈    885 chars ≈   220 tokens
//      summarised, then one block read in full  ≈              ≈   820 tokens
//
//  Sixteen times cheaper to scan, four times cheaper even when the scan leads
//  to a full read — and in the common case the summary is the whole answer.
//  A thinking block summarises to a character count with no preview at all,
//  which is the single largest part of that: it is usually the biggest block in
//  a turn and almost never the one the parent needs.

import Foundation

/// How much of each block to send back.
public enum Fidelity: String, Sendable, Hashable {
    /// One line per block: what kind it is, how big it is, and enough of it to
    /// decide whether to ask for the rest.
    case summary
    /// Everything.
    case full
}

/// Why a read came back.
///
/// `now` is what a plain read returns — it did not wait for anything, so
/// nothing woke it.
public enum WaitReason: String, Sendable, Hashable {
    case now
    /// A turn ended, one way or another.
    case turn
    /// The pane is stopped on a question.
    case ask
    /// Its agent's process went away.
    case exit
    /// The pane was closed while someone was waiting on it.
    case closed
    /// A browser pane finished loading a page, or failed to.
    ///
    /// The only reason that belongs to a pane with no agent behind it, which
    /// is why `ParkedRead.target` is optional: there is no session whose
    /// progress this is. The cursor it counts against is the pane's load
    /// count, not a transcript clock — see `Workspace.satisfied(_:_:)`.
    case loaded
    /// Nothing happened in time.
    case timeout
}

/// What to read, and whether to wait for it.
public struct ReadQuery: Sendable, Equatable {
    /// Read everything stamped after this. Thread the `cursor` from the last
    /// reply; starting from 0 every time is paying twice for the same tokens.
    public var since: Int
    /// One block, by index, at full fidelity. Ignores every other filter —
    /// this is the zoom that a summary earned.
    public var block: Int?
    public var fidelity: Fidelity
    /// Block kinds to keep, by their `k` name. Empty keeps everything.
    public var kinds: [String]
    /// A regular expression over each block's text. The one thing a log was
    /// genuinely better at, bought back for about five lines.
    public var match: String?
    public var limit: Int?
    /// Conditions to park on. Empty means do not wait.
    public var until: [WaitReason]
    /// Milliseconds. Zero is a plain read.
    public var timeout: Int

    public init(
        since: Int = 0,
        block: Int? = nil,
        fidelity: Fidelity = .summary,
        kinds: [String] = [],
        match: String? = nil,
        limit: Int? = nil,
        until: [WaitReason] = [],
        timeout: Int = 0
    ) {
        self.since = since
        self.block = block
        self.fidelity = fidelity
        self.kinds = kinds
        self.match = match
        self.limit = limit
        self.until = until
        self.timeout = timeout
    }

    /// Whether this query wants to be parked rather than answered at once.
    public var waits: Bool { timeout > 0 && !until.isEmpty }
}

extension Transcript {
    /// How much of one block's prose a summary previews.
    static let headLength = 80

    /// The ceiling on one reply, in bytes.
    ///
    /// **Not negotiable by `limit`.** A child that attaches a five megabyte
    /// file would otherwise blow its parent's context in a single call, and the
    /// parent has no way to know that in advance — the whole point of asking is
    /// that it does not yet know what is there.
    static let replyBudget = 32 * 1024

    /// Answers a read.
    ///
    /// The envelope carries `cursor` whether or not anything matched, so a
    /// parent that filters everything out still moves forward instead of
    /// rescanning the same blocks on its next call.
    public func read(_ query: ReadQuery, reason: WaitReason = .now) -> JSONValue {
        var fields: [String: JSONValue] = [
            "reason": .string(reason.rawValue),
            "running": .bool(isRunning),
        ]
        if !status.isEmpty {
            fields["status"] = .object(status.mapValues { JSONValue.string($0) })
        }

        // The zoom. One block, in full, and none of the scanning filters apply
        // — the caller already knows which one it wants.
        if let index = query.block {
            fields["cursor"] = .int(Int64(clock))
            guard blocks.indices.contains(index) else {
                fields["blocks"] = .array([])
                return .object(fields)
            }
            fields["blocks"] = .array([encode(index, blocks[index], .full)])
            return .object(fields)
        }

        let expression = query.match.flatMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }

        var out: [JSONValue] = []
        var spent = 0
        var cursor = query.since
        var truncated = false

        for (index, block) in changed(since: query.since) {
            if !query.kinds.isEmpty, !query.kinds.contains(Self.kind(of: block)) {
                // Skipped, but still *seen*: the cursor moves past a block the
                // caller asked not to be shown, or the next read rescans it.
                cursor = seqs[index]
                continue
            }
            if let expression, !Self.matches(block, expression) {
                cursor = seqs[index]
                continue
            }
            if let limit = query.limit, out.count >= limit {
                truncated = true
                break
            }

            let encoded = encode(index, block, query.fidelity)
            let size = encoded.line().utf8.count
            // Stop *before* going over, and leave the cursor on the last block
            // that fitted, so the next read resumes exactly here.
            if spent + size > Self.replyBudget, !out.isEmpty {
                truncated = true
                break
            }

            out.append(encoded)
            spent += size
            cursor = seqs[index]
        }

        // Nothing was held back, so the caller is caught up with the clock
        // rather than with the last block that happened to match.
        if !truncated { cursor = clock }

        fields["cursor"] = .int(Int64(cursor))
        fields["blocks"] = .array(out)
        if truncated { fields["truncated"] = .bool(true) }
        return .object(fields)
    }

    // MARK: - Encoding

    /// The `k` name a block goes out under, which is also what `kinds` filters
    /// on. Roles are flattened into it: a caller asking for the agent's prose
    /// should not have to ask for messages and then sort them.
    static func kind(of block: Block) -> String {
        switch block {
        case .message(_, let role, _, _):
            switch role {
            case .user: "user"
            // A thinking role never reaches a message block — the fold gives it
            // its own — so this is only the degraded path for a build that read
            // a role it did not know.
            case .agent, .thinking: "agent"
            }
        case .thinking: "thinking"
        case .activity: "act"
        case .attachment: "att"
        case .ask: "ask"
        case .notice: "notice"
        }
    }

    /// The text a `match` is tested against — what a reader would have read.
    private static func matches(_ block: Block, _ expression: NSRegularExpression) -> Bool {
        let haystack: String = switch block {
        case .message(_, _, let text, _): text
        case .thinking(_, let text, _, _): text
        case .activity(_, let label, let detail, _, _): label + " " + (detail ?? "")
        case .attachment(let attachment): attachment.text
        case .ask(_, let prompt, let choices, _, let answer, let secret, _):
            // A secret answer is already stored masked, but `match` would
            // otherwise let a reader confirm a credential by guessing at it
            // one substring at a time.
            ([prompt] + choices + [secret ? "" : (answer ?? "")]).joined(separator: " ")
        case .notice(let message): message
        }
        let range = NSRange(haystack.startIndex..., in: haystack)
        return expression.firstMatch(in: haystack, range: range) != nil
    }

    private func encode(_ index: Int, _ block: Block, _ fidelity: Fidelity) -> JSONValue {
        var fields: [String: JSONValue] = [
            "i": .int(Int64(index)),
            "k": .string(Self.kind(of: block)),
        ]

        switch block {
        case .message(_, _, let text, let streaming):
            if streaming { fields["streaming"] = .bool(true) }
            switch fidelity {
            case .full:
                fields["text"] = .string(text)
            case .summary:
                // `n` is what tells a reader whether zooming is worth it, so it
                // is the count of the *whole* block, not of the preview.
                fields["n"] = .int(Int64(text.count))
                if !text.isEmpty {
                    fields["head"] = .string(String(text.prefix(Self.headLength)))
                }
            }

        case .thinking(_, let text, let streaming, _):
            // **No head, at either fidelity that scans.** Reasoning is usually
            // the largest block in a turn and the one a supervising parent least
            // often needs, so a summary says only how much there was. `full` —
            // which is what a deliberate zoom asks for — still gives it whole.
            if streaming { fields["streaming"] = .bool(true) }
            switch fidelity {
            case .full: fields["text"] = .string(text)
            case .summary: fields["n"] = .int(Int64(text.count))
            }

        case .activity(_, let label, let detail, let state, let category):
            // An activity is already a summary of something, so there is no
            // shorter form of it and nothing is truncated at either fidelity.
            fields["label"] = .string(label)
            if let detail { fields["detail"] = .string(detail) }
            if let category { fields["category"] = .string(category) }
            let name: String = switch state {
            case .running: "running"
            case .ok: "ok"
            case .error: "error"
            }
            fields["state"] = .string(name)

        case .attachment(let attachment):
            fields["type"] = .string(attachment.kind)
            if let language = attachment.language { fields["lang"] = .string(language) }
            switch fidelity {
            case .full: fields["text"] = .string(attachment.text)
            case .summary: fields["n"] = .int(Int64(attachment.text.count))
            }

        case .ask(_, let prompt, let choices, let placeholder, let answer, let secret, _):
            // **Always full.** An ask is small, and it is the thing a
            // supervising parent most needs to act on — summarising it would
            // force a second call to do anything useful.
            fields["prompt"] = .string(prompt)
            if !choices.isEmpty { fields["choices"] = .array(choices.map { .string($0) }) }
            if let placeholder { fields["placeholder"] = .string(placeholder) }
            // The answer is already masked in the block. Said again here
            // because this is the copy a *parent* reads, and a parent asking
            // its child for the token it was just given is the one path where
            // a credential would cross a pane boundary.
            fields["answer"] = answer.map { JSONValue.string($0) } ?? .null
            if secret { fields["secret"] = .bool(true) }

        case .notice(let message):
            // Always full, for the same reason, and always small anyway.
            fields["text"] = .string(message)
        }

        return .object(fields)
    }
}
