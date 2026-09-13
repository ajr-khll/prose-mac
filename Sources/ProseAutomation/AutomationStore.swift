import Foundation
import ProseCore
import SQLite3

public struct StoredAutomation: Equatable, Identifiable, Sendable {
    public var definition: AutomationDefinition
    public var nextFireAt: Date?

    public var id: UUID { definition.id }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The single durable writer for automation state. Every operation that can
/// create work is a SQLite transaction; actor isolation prevents two callers
/// sharing this connection from interleaving their transactions.
public actor AutomationStore {
    // SQLite is opened FULLMUTEX and every operation is still actor-isolated.
    // `nonisolated(unsafe)` exists only so deinit may close the opaque C handle;
    // no callable method exposes or touches it outside the actor.
    nonisolated(unsafe) private var database: OpaquePointer?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(url: URL) throws {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970

        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        var opened: OpaquePointer?
        guard sqlite3_open_v2(url.path, &opened, flags, nil) == SQLITE_OK else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(opened)
            throw AutomationError.storage("could not open automation store: \(message)")
        }
        database = opened
        do {
            try Self.bootstrap(opened)
        } catch {
            sqlite3_close(opened)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    private static func bootstrap(_ database: OpaquePointer?) throws {
        func execute(_ sql: String) throws {
            guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
                let message = database.map { String(cString: sqlite3_errmsg($0)) }
                    ?? "database closed"
                throw AutomationError.storage(message)
            }
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=5000")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS automations (
                id TEXT PRIMARY KEY,
                revision INTEGER NOT NULL,
                enabled INTEGER NOT NULL,
                definition TEXT NOT NULL,
                next_fire REAL,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """)
        try execute(
            """
            CREATE INDEX IF NOT EXISTS automations_due
            ON automations(enabled, next_fire)
            """)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS events (
                source TEXT NOT NULL,
                external_id TEXT NOT NULL,
                received_at REAL NOT NULL,
                event TEXT NOT NULL,
                PRIMARY KEY(source, external_id)
            )
            """)
        try execute(
            """
            CREATE TABLE IF NOT EXISTS runs (
                id TEXT PRIMARY KEY,
                automation_id TEXT NOT NULL,
                occurrence_key TEXT NOT NULL,
                scheduled_at REAL NOT NULL,
                state TEXT NOT NULL,
                attempt INTEGER NOT NULL DEFAULT 0,
                definition TEXT NOT NULL,
                event TEXT,
                started_at REAL,
                finished_at REAL,
                lease_owner TEXT,
                lease_until REAL,
                result TEXT,
                error TEXT,
                UNIQUE(automation_id, occurrence_key),
                FOREIGN KEY(automation_id) REFERENCES automations(id) ON DELETE CASCADE
            )
            """)
        try execute(
            """
            CREATE INDEX IF NOT EXISTS runs_claimable
            ON runs(state, scheduled_at)
            """)
    }

    // MARK: Definitions

    @discardableResult
    public func create(_ definition: AutomationDefinition, now: Date = Date()) throws
        -> StoredAutomation
    {
        try definition.validate()
        let next = try initialNext(for: definition.trigger, now: now)
        let json = try encode(definition)
        try statement(
            """
            INSERT INTO automations
                (id, revision, enabled, definition, next_fire, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            [.text(definition.id.uuidString), .integer(Int64(definition.revision)),
             .integer(definition.enabled ? 1 : 0), .text(json), .date(next),
             .double(definition.createdAt.timeIntervalSince1970),
             .double(definition.updatedAt.timeIntervalSince1970)]) { statement in
                guard sqlite3_step(statement) == SQLITE_DONE else { try fail() }
            }
        return StoredAutomation(definition: definition, nextFireAt: next)
    }

    public func list() throws -> [StoredAutomation] {
        try queryAutomations(
            "SELECT definition, next_fire FROM automations ORDER BY created_at DESC", [])
    }

    public func get(_ id: UUID) throws -> StoredAutomation {
        guard let item = try queryAutomations(
            "SELECT definition, next_fire FROM automations WHERE id = ?", [.text(id.uuidString)]
        ).first else { throw AutomationError.notFound }
        return item
    }

    public func setEnabled(_ id: UUID, enabled: Bool, now: Date = Date()) throws
        -> StoredAutomation
    {
        var item = try get(id)
        item.definition.enabled = enabled
        item.definition.revision += 1
        item.definition.updatedAt = now
        if enabled, item.nextFireAt == nil {
            item.nextFireAt = try initialNext(for: item.definition.trigger, now: now)
        }
        let json = try encode(item.definition)
        let changed = try statement(
            """
            UPDATE automations
            SET revision = ?, enabled = ?, definition = ?, next_fire = ?, updated_at = ?
            WHERE id = ?
            """,
            [.integer(Int64(item.definition.revision)), .integer(enabled ? 1 : 0), .text(json),
             .date(item.nextFireAt), .double(now.timeIntervalSince1970), .text(id.uuidString)]) {
                statement -> Int32 in
                let result = sqlite3_step(statement)
                guard result == SQLITE_DONE else { try fail() }
                return sqlite3_changes(database)
            }
        guard changed == 1 else { throw AutomationError.notFound }
        return item
    }

    public func delete(_ id: UUID) throws {
        let changed = try statement(
            "DELETE FROM automations WHERE id = ?", [.text(id.uuidString)]) { statement -> Int32 in
                guard sqlite3_step(statement) == SQLITE_DONE else { try fail() }
                return sqlite3_changes(database)
            }
        guard changed == 1 else { throw AutomationError.notFound }
    }

    // MARK: Producing occurrences

    /// Reconciles everything due at `now`, including work missed while prose
    /// was not running. Occurrence insertion and advancing `next_fire` share a
    /// transaction, so a crash can repeat neither half on its own.
    @discardableResult
    public func reconcile(now: Date = Date()) throws -> [AutomationRun] {
        let due = try queryAutomations(
            """
            SELECT definition, next_fire FROM automations
            WHERE enabled = 1 AND next_fire IS NOT NULL AND next_fire <= ?
            ORDER BY next_fire
            """, [.double(now.timeIntervalSince1970)])
        var created: [AutomationRun] = []
        for item in due {
            guard let nextFire = item.nextFireAt else { continue }
            try transaction {
                let schedule = try dueOccurrences(
                    trigger: item.definition.trigger, nextFire: nextFire, now: now,
                    policy: item.definition.policy.misfire)
                for instant in schedule.occurrences {
                    if let run = try enqueue(
                        item.definition,
                        occurrenceKey: "time:\(microseconds(instant))",
                        scheduledAt: instant,
                        event: nil)
                    { created.append(run) }
                }
                try statement(
                    "UPDATE automations SET next_fire = ? WHERE id = ?",
                    [.date(schedule.next), .text(item.definition.id.uuidString)]) { statement in
                        guard sqlite3_step(statement) == SQLITE_DONE else { try fail() }
                    }
            }
        }
        return created
    }

    @discardableResult
    public func runNow(_ id: UUID, now: Date = Date()) throws -> AutomationRun? {
        let definition = try get(id).definition
        return try transaction {
            try enqueue(
                definition,
                occurrenceKey: "manual:\(UUID().uuidString.lowercased())",
                scheduledAt: now,
                event: nil)
        }
    }

    /// Inserts an external event exactly once, and creates one occurrence per
    /// matching enabled automation in the same transaction.
    @discardableResult
    public func ingest(_ event: AutomationEvent) throws -> [AutomationRun] {
        guard !event.source.isEmpty, !event.externalID.isEmpty, !event.type.isEmpty else {
            throw AutomationError.invalid("an event needs source, external id and type")
        }
        return try transaction {
            let inserted = try statement(
                "INSERT OR IGNORE INTO events(source, external_id, received_at, event) VALUES (?, ?, ?, ?)",
                [.text(event.source), .text(event.externalID),
                 .double(event.receivedAt.timeIntervalSince1970), .text(try encode(event))]) {
                    statement -> Bool in
                    guard sqlite3_step(statement) == SQLITE_DONE else { try fail() }
                    return sqlite3_changes(database) == 1
                }
            guard inserted else { return [] }

            let definitions = try queryAutomations(
                "SELECT definition, next_fire FROM automations WHERE enabled = 1", [])
            var runs: [AutomationRun] = []
            for item in definitions {
                guard case .event(let trigger) = item.definition.trigger,
                      trigger.matches(event)
                else { continue }
                if let run = try enqueue(
                    item.definition,
                    occurrenceKey: "event:\(event.source):\(event.externalID)",
                    scheduledAt: event.occurredAt,
                    event: event)
                { runs.append(run) }
            }
            return runs
        }
    }

    // MARK: Claiming and finishing

    public func claimNext(
        owner: String,
        now: Date = Date(),
        leaseFor: TimeInterval = 60
    ) throws -> AutomationRun? {
        try transaction {
            let rows = try queryRuns(
                """
                SELECT id, automation_id, occurrence_key, scheduled_at, state, attempt,
                       definition, event, started_at, finished_at, result, error
                FROM runs WHERE state = 'queued' AND scheduled_at <= ?
                ORDER BY scheduled_at, id LIMIT 1
                """, [.double(now.timeIntervalSince1970)])
            guard var run = rows.first else { return nil }
            let changed = try statement(
                """
                UPDATE runs SET state = 'running', attempt = attempt + 1,
                    started_at = ?, lease_owner = ?, lease_until = ?
                WHERE id = ? AND state = 'queued'
                """,
                [.double(now.timeIntervalSince1970), .text(owner),
                 .double(now.addingTimeInterval(leaseFor).timeIntervalSince1970),
                 .text(run.id.uuidString)]) { statement -> Int32 in
                    guard sqlite3_step(statement) == SQLITE_DONE else { try fail() }
                    return sqlite3_changes(database)
                }
            guard changed == 1 else { return nil }
            run.state = .running
            run.attempt += 1
            run.startedAt = now
            return run
        }
    }

    public func heartbeat(
        _ id: UUID,
        owner: String,
        now: Date = Date(),
        leaseFor: TimeInterval = 60
    ) throws -> Bool {
        try statement(
            """
            UPDATE runs SET lease_until = ?
            WHERE id = ? AND state = 'running' AND lease_owner = ?
            """,
            [.double(now.addingTimeInterval(leaseFor).timeIntervalSince1970),
             .text(id.uuidString), .text(owner)]) { statement -> Bool in
                guard sqlite3_step(statement) == SQLITE_DONE else { try fail() }
                return sqlite3_changes(database) == 1
            }
    }

    public func finish(
        _ id: UUID,
        state: RunState,
        result: String? = nil,
        error: String? = nil,
        now: Date = Date()
    ) throws {
        guard state.isTerminal else {
            throw AutomationError.invalid("a finished run needs a terminal state")
        }
        let changed = try statement(
            """
            UPDATE runs SET state = ?, finished_at = ?, result = ?, error = ?,
                            lease_owner = NULL, lease_until = NULL
            WHERE id = ? AND state IN ('queued', 'running')
            """,
            [.text(state.rawValue), .double(now.timeIntervalSince1970), .optionalText(result),
             .optionalText(error), .text(id.uuidString)]) { statement -> Int32 in
                guard sqlite3_step(statement) == SQLITE_DONE else { try fail() }
                return sqlite3_changes(database)
            }
        guard changed == 1 else { throw AutomationError.conflict }
    }

    /// A crashed owner leaves a lease, not an immortal `running` row. Runs with
    /// attempts left return to the queue; exhausted ones fail terminally.
    @discardableResult
    public func recoverExpired(now: Date = Date()) throws -> Int {
        let expired = try queryRuns(
            """
            SELECT id, automation_id, occurrence_key, scheduled_at, state, attempt,
                   definition, event, started_at, finished_at, result, error
            FROM runs
            WHERE state = 'running' AND lease_until IS NOT NULL AND lease_until < ?
            """, [.double(now.timeIntervalSince1970)])
        var count = 0
        for run in expired {
            let retry = run.attempt < run.definition.policy.maximumAttempts
            try statement(
                """
                UPDATE runs SET state = ?, finished_at = ?, error = ?,
                                lease_owner = NULL, lease_until = NULL
                WHERE id = ? AND state = 'running'
                """,
                [.text(retry ? RunState.queued.rawValue : RunState.failed.rawValue),
                 retry ? .null : .double(now.timeIntervalSince1970),
                 .text(retry ? "worker lease expired; retrying" : "worker lease expired"),
                 .text(run.id.uuidString)]) { statement in
                    guard sqlite3_step(statement) == SQLITE_DONE else { try fail() }
                }
            count += 1
        }
        return count
    }

    public func history(automation id: UUID? = nil, limit: Int = 100) throws -> [AutomationRun] {
        let bounded = max(1, min(limit, 500))
        let columns =
            """
            SELECT id, automation_id, occurrence_key, scheduled_at, state, attempt,
                   definition, event, started_at, finished_at, result, error
            FROM runs
            """
        if let id {
            return try queryRuns(
                columns + " WHERE automation_id = ? ORDER BY scheduled_at DESC LIMIT ?",
                [.text(id.uuidString), .integer(Int64(bounded))])
        }
        return try queryRuns(
            columns + " ORDER BY scheduled_at DESC LIMIT ?", [.integer(Int64(bounded))])
    }

    // MARK: Queue policy

    private func enqueue(
        _ definition: AutomationDefinition,
        occurrenceKey: String,
        scheduledAt: Date,
        event: AutomationEvent?
    ) throws -> AutomationRun? {
        let active = try activeRunCount(definition.id)
        switch definition.policy.concurrency {
        case .skipWhileRunning where active > 0:
            return nil
        case .replace where active > 0:
            try statement(
                """
                UPDATE runs SET state = 'cancelled', finished_at = ?,
                                error = 'replaced by a newer occurrence'
                WHERE automation_id = ? AND state IN ('queued', 'running')
                """,
                [.double(scheduledAt.timeIntervalSince1970), .text(definition.id.uuidString)]) {
                    statement in
                    guard sqlite3_step(statement) == SQLITE_DONE else { try fail() }
                }
        default:
            break
        }

        let run = AutomationRun(
            automationID: definition.id,
            occurrenceKey: occurrenceKey,
            scheduledAt: scheduledAt,
            definition: definition,
            event: event)
        let encodedEvent = try event.map { try encode($0) }
        let changed = try statement(
            """
            INSERT OR IGNORE INTO runs
                (id, automation_id, occurrence_key, scheduled_at, state, attempt, definition, event)
            VALUES (?, ?, ?, ?, 'queued', 0, ?, ?)
            """,
            [.text(run.id.uuidString), .text(definition.id.uuidString), .text(occurrenceKey),
             .double(scheduledAt.timeIntervalSince1970), .text(try encode(definition)),
             .optionalText(encodedEvent)]) { statement -> Bool in
                guard sqlite3_step(statement) == SQLITE_DONE else { try fail() }
                return sqlite3_changes(database) == 1
            }
        return changed ? run : nil
    }

    private func activeRunCount(_ id: UUID) throws -> Int {
        try statement(
            "SELECT count(*) FROM runs WHERE automation_id = ? AND state IN ('queued', 'running')",
            [.text(id.uuidString)]) { statement in
                guard sqlite3_step(statement) == SQLITE_ROW else { try fail() }
                return Int(sqlite3_column_int64(statement, 0))
            }
    }

    // MARK: SQLite

    private enum Binding {
        case null
        case integer(Int64)
        case double(Double)
        case text(String)

        static func date(_ date: Date?) -> Binding {
            date.map { .double($0.timeIntervalSince1970) } ?? .null
        }

        static func optionalText(_ text: String?) -> Binding { text.map(Binding.text) ?? .null }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { try fail() }
    }

    private func statement<T>(
        _ sql: String,
        _ bindings: [Binding],
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &prepared, nil) == SQLITE_OK,
              let prepared
        else { try fail() }
        defer { sqlite3_finalize(prepared) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch binding {
            case .null: sqlite3_bind_null(prepared, index)
            case .integer(let value): sqlite3_bind_int64(prepared, index, value)
            case .double(let value): sqlite3_bind_double(prepared, index, value)
            case .text(let value):
                sqlite3_bind_text(prepared, index, value, -1, sqliteTransient)
            }
            guard result == SQLITE_OK else { try fail() }
        }
        return try body(prepared)
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func fail() throws -> Never {
        let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "database closed"
        throw AutomationError.storage(message)
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw AutomationError.storage("could not encode automation data")
        }
        return text
    }

    private func decode<T: Decodable>(_ type: T.Type, _ text: String) throws -> T {
        guard let data = text.data(using: .utf8) else {
            throw AutomationError.storage("automation data was not UTF-8")
        }
        do { return try decoder.decode(type, from: data) }
        catch { throw AutomationError.storage("could not decode automation data: \(error)") }
    }

    private func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, column)
        else { return nil }
        return String(cString: pointer)
    }

    private func date(_ statement: OpaquePointer, _ column: Int32) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
    }

    private func queryAutomations(_ sql: String, _ bindings: [Binding]) throws
        -> [StoredAutomation]
    {
        try statement(sql, bindings) { statement in
            var values: [StoredAutomation] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let json = text(statement, 0) else { try fail() }
                    values.append(StoredAutomation(
                        definition: try decode(AutomationDefinition.self, json),
                        nextFireAt: date(statement, 1)))
                case SQLITE_DONE:
                    return values
                default:
                    try fail()
                }
            }
        }
    }

    private func queryRuns(_ sql: String, _ bindings: [Binding]) throws -> [AutomationRun] {
        try statement(sql, bindings) { statement in
            var values: [AutomationRun] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW:
                    guard let runID = text(statement, 0).flatMap(UUID.init(uuidString:)),
                          let automationID = text(statement, 1).flatMap(UUID.init(uuidString:)),
                          let occurrence = text(statement, 2),
                          let stateName = text(statement, 4),
                          let state = RunState(rawValue: stateName),
                          let definitionText = text(statement, 6)
                    else { throw AutomationError.storage("invalid run row") }
                    let event: AutomationEvent? = try text(statement, 7).map {
                        try decode(AutomationEvent.self, $0)
                    }
                    values.append(AutomationRun(
                        id: runID,
                        automationID: automationID,
                        occurrenceKey: occurrence,
                        scheduledAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                        state: state,
                        attempt: Int(sqlite3_column_int64(statement, 5)),
                        definition: try decode(AutomationDefinition.self, definitionText),
                        event: event,
                        startedAt: date(statement, 8),
                        finishedAt: date(statement, 9),
                        result: text(statement, 10),
                        error: text(statement, 11)))
                case SQLITE_DONE:
                    return values
                default:
                    try fail()
                }
            }
        }
    }

    private func initialNext(for trigger: AutomationTrigger, now: Date) throws -> Date? {
        switch trigger {
        case .at(let instant): instant
        case .interval(_, let anchor): anchor
        case .calendar: try trigger.next(after: now)
        case .event, .manual: nil
        }
    }
}

private func microseconds(_ date: Date) -> Int64 {
    Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
}
