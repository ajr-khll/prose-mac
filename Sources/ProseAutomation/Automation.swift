import Foundation
import ProseCore

public enum AutomationError: Error, Equatable, LocalizedError, Sendable {
    case invalid(String)
    case notFound
    case conflict
    case storage(String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let message), .storage(let message): message
        case .notFound: "no such automation"
        case .conflict: "the automation changed; reload it and try again"
        }
    }
}

public enum CalendarFrequency: String, Codable, CaseIterable, Sendable {
    case daily
    case weekly
    case monthly
}

public enum NonexistentTimePolicy: String, Codable, Sendable {
    case skip
    case nextValid
}

public enum RepeatedTimePolicy: String, Codable, Sendable {
    case first
    case second
}

/// A local wall-clock schedule. Weekdays use Foundation's Gregorian values:
/// Sunday is 1 and Saturday is 7.
public struct CalendarSchedule: Codable, Equatable, Sendable {
    public var frequency: CalendarFrequency
    public var hour: Int
    public var minute: Int
    public var weekdays: [Int]
    public var dayOfMonth: Int?
    public var timeZone: String
    public var nonexistentTime: NonexistentTimePolicy
    public var repeatedTime: RepeatedTimePolicy

    public init(
        frequency: CalendarFrequency,
        hour: Int,
        minute: Int,
        weekdays: [Int] = [],
        dayOfMonth: Int? = nil,
        timeZone: String = TimeZone.current.identifier,
        nonexistentTime: NonexistentTimePolicy = .nextValid,
        repeatedTime: RepeatedTimePolicy = .first
    ) {
        self.frequency = frequency
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
        self.dayOfMonth = dayOfMonth
        self.timeZone = timeZone
        self.nonexistentTime = nonexistentTime
        self.repeatedTime = repeatedTime
    }

    public func validate() throws {
        guard (0...23).contains(hour), (0...59).contains(minute) else {
            throw AutomationError.invalid("calendar hour or minute is out of range")
        }
        guard TimeZone(identifier: timeZone) != nil else {
            throw AutomationError.invalid("unknown time zone \(timeZone)")
        }
        switch frequency {
        case .daily:
            break
        case .weekly:
            guard !weekdays.isEmpty, weekdays.allSatisfy({ (1...7).contains($0) }) else {
                throw AutomationError.invalid("a weekly schedule needs weekdays from 1 through 7")
            }
        case .monthly:
            guard let dayOfMonth, (1...31).contains(dayOfMonth) else {
                throw AutomationError.invalid("a monthly schedule needs a day from 1 through 31")
            }
        }
    }

    /// The first calendar occurrence strictly after `date`.
    public func next(after date: Date) throws -> Date {
        try validate()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZone)!
        let matching: Calendar.MatchingPolicy = nonexistentTime == .skip ? .strict : .nextTime
        let repeated: Calendar.RepeatedTimePolicy = repeatedTime == .first ? .first : .last

        func candidate(_ components: DateComponents) -> Date? {
            calendar.nextDate(
                after: date,
                matching: components,
                matchingPolicy: matching,
                repeatedTimePolicy: repeated,
                direction: .forward)
        }

        let next: Date?
        switch frequency {
        case .daily:
            next = candidate(DateComponents(hour: hour, minute: minute, second: 0))
        case .weekly:
            next = Set(weekdays).compactMap {
                candidate(DateComponents(hour: hour, minute: minute, second: 0, weekday: $0))
            }.min()
        case .monthly:
            next = candidate(
                DateComponents(day: dayOfMonth, hour: hour, minute: minute, second: 0))
        }
        guard let next else {
            throw AutomationError.invalid("the calendar schedule has no future occurrence")
        }
        return next
    }
}

public struct EventTrigger: Codable, Equatable, Sendable {
    public var source: String
    public var type: String
    public var subjectContains: String?

    public init(source: String, type: String, subjectContains: String? = nil) {
        self.source = source
        self.type = type
        self.subjectContains = subjectContains
    }

    public func matches(_ event: AutomationEvent) -> Bool {
        guard event.source == source, event.type == type else { return false }
        guard let wanted = subjectContains?.lowercased(), !wanted.isEmpty else { return true }
        return event.subject?.lowercased().contains(wanted) == true
    }
}

public enum AutomationTrigger: Codable, Equatable, Sendable {
    case at(Date)
    case interval(every: TimeInterval, anchor: Date)
    case calendar(CalendarSchedule)
    case event(EventTrigger)
    case manual

    public func validate() throws {
        switch self {
        case .at:
            break
        case .interval(let every, _):
            guard every.isFinite, every >= 60 else {
                throw AutomationError.invalid("an interval must be at least 60 seconds")
            }
        case .calendar(let schedule):
            try schedule.validate()
        case .event(let trigger):
            guard !trigger.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !trigger.type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { throw AutomationError.invalid("an event trigger needs a source and type") }
        case .manual:
            break
        }
    }

    /// The first timed occurrence strictly after `date`, or nil for event and
    /// manual triggers.
    public func next(after date: Date) throws -> Date? {
        switch self {
        case .at(let instant):
            return instant > date ? instant : nil
        case .interval(let every, let anchor):
            if date < anchor { return anchor }
            let elapsed = date.timeIntervalSince(anchor)
            let steps = floor(elapsed / every) + 1
            return anchor.addingTimeInterval(steps * every)
        case .calendar(let schedule):
            return try schedule.next(after: date)
        case .event, .manual:
            return nil
        }
    }
}

public enum MisfirePolicy: Codable, Equatable, Sendable {
    case skip
    case runOnce
    case catchUp(maximum: Int)
}

public enum ConcurrencyPolicy: String, Codable, Sendable {
    case queue
    case skipWhileRunning
    case replace
}

public struct ExecutionPolicy: Codable, Equatable, Sendable {
    public var misfire: MisfirePolicy
    public var concurrency: ConcurrencyPolicy
    public var maximumRuntime: TimeInterval
    public var maximumAttempts: Int

    public init(
        misfire: MisfirePolicy = .runOnce,
        concurrency: ConcurrencyPolicy = .skipWhileRunning,
        maximumRuntime: TimeInterval = 30 * 60,
        maximumAttempts: Int = 1
    ) {
        self.misfire = misfire
        self.concurrency = concurrency
        self.maximumRuntime = maximumRuntime
        self.maximumAttempts = maximumAttempts
    }

    public func validate() throws {
        guard maximumRuntime.isFinite, (1...86_400).contains(maximumRuntime) else {
            throw AutomationError.invalid("maximum runtime must be between 1 second and 24 hours")
        }
        guard (1...10).contains(maximumAttempts) else {
            throw AutomationError.invalid("maximum attempts must be between 1 and 10")
        }
        if case .catchUp(let maximum) = misfire, !(1...100).contains(maximum) {
            throw AutomationError.invalid("catch-up maximum must be between 1 and 100")
        }
    }
}

public struct AgentTask: Codable, Equatable, Sendable {
    public var prompt: String
    public var flavour: String
    public var parameters: [String: JSONValue]
    public var workingDirectory: String?

    public init(
        prompt: String,
        flavour: String = "prose",
        parameters: [String: JSONValue] = [:],
        workingDirectory: String? = nil
    ) {
        self.prompt = prompt
        self.flavour = flavour
        self.parameters = parameters
        self.workingDirectory = workingDirectory
    }

    public func validate() throws {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 64 * 1024 else {
            throw AutomationError.invalid("the scheduled task must contain 1 to 65536 bytes")
        }
        let valid = flavour.range(of: #"^[a-z0-9][a-z0-9-]{0,63}$"#,
                                  options: .regularExpression) != nil
        guard valid else { throw AutomationError.invalid("invalid agent flavour") }
        if let workingDirectory {
            guard NSString(string: workingDirectory).isAbsolutePath else {
                throw AutomationError.invalid("the working directory must be an absolute path")
            }
        }
    }
}

public struct AutomationDefinition: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var revision: Int
    public var title: String
    public var enabled: Bool
    public var trigger: AutomationTrigger
    public var task: AgentTask
    public var policy: ExecutionPolicy
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        revision: Int = 1,
        title: String,
        enabled: Bool = true,
        trigger: AutomationTrigger,
        task: AgentTask,
        policy: ExecutionPolicy = ExecutionPolicy(),
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.revision = revision
        self.title = title
        self.enabled = enabled
        self.trigger = trigger
        self.task = task
        self.policy = policy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public func validate() throws {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 200 else {
            throw AutomationError.invalid("the automation title must contain 1 to 200 characters")
        }
        try trigger.validate()
        try task.validate()
        try policy.validate()
    }
}

public struct AutomationEvent: Codable, Equatable, Sendable {
    public var externalID: String
    public var source: String
    public var type: String
    public var occurredAt: Date
    public var receivedAt: Date
    public var subject: String?
    public var payload: JSONValue

    public init(
        externalID: String,
        source: String,
        type: String,
        occurredAt: Date,
        receivedAt: Date = Date(),
        subject: String? = nil,
        payload: JSONValue = .null
    ) {
        self.externalID = externalID
        self.source = source
        self.type = type
        self.occurredAt = occurredAt
        self.receivedAt = receivedAt
        self.subject = subject
        self.payload = payload
    }
}

public enum RunState: String, Codable, CaseIterable, Sendable {
    case queued
    case running
    case succeeded
    case failed
    case needsApproval
    case cancelled

    public var isTerminal: Bool {
        switch self {
        case .queued, .running: false
        case .succeeded, .failed, .needsApproval, .cancelled: true
        }
    }
}

public struct AutomationRun: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var automationID: UUID
    public var occurrenceKey: String
    public var scheduledAt: Date
    public var state: RunState
    public var attempt: Int
    public var definition: AutomationDefinition
    public var event: AutomationEvent?
    public var startedAt: Date?
    public var finishedAt: Date?
    public var result: String?
    public var error: String?

    public init(
        id: UUID = UUID(),
        automationID: UUID,
        occurrenceKey: String,
        scheduledAt: Date,
        state: RunState = .queued,
        attempt: Int = 0,
        definition: AutomationDefinition,
        event: AutomationEvent? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        result: String? = nil,
        error: String? = nil
    ) {
        self.id = id
        self.automationID = automationID
        self.occurrenceKey = occurrenceKey
        self.scheduledAt = scheduledAt
        self.state = state
        self.attempt = attempt
        self.definition = definition
        self.event = event
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.result = result
        self.error = error
    }
}

public struct DueOccurrences: Equatable, Sendable {
    public var occurrences: [Date]
    public var next: Date?
}

/// Applies a timed trigger's misfire policy. `nextFire` is already persisted,
/// which avoids reconstructing an interval from an imprecise app launch time.
public func dueOccurrences(
    trigger: AutomationTrigger,
    nextFire: Date,
    now: Date,
    policy: MisfirePolicy
) throws -> DueOccurrences {
    guard nextFire <= now else { return DueOccurrences(occurrences: [], next: nextFire) }

    var due: [Date] = []
    var cursor: Date? = nextFire
    let cap: Int
    switch policy {
    case .skip: cap = 0
    case .runOnce: cap = 1
    case .catchUp(let maximum): cap = maximum
    }

    while let instant = cursor, instant <= now {
        if due.count < cap { due.append(instant) }
        cursor = try trigger.next(after: instant)
        // A one-time trigger deliberately has no successor.
        if cursor == nil { break }
        // `runOnce` and `skip` need only the first future date, not every
        // missed interval. Jumping from `now` is both exact and bounded.
        if due.count >= cap, policy != .catchUp(maximum: cap) {
            cursor = try trigger.next(after: now)
            break
        }
        if due.count >= cap, case .catchUp = policy {
            cursor = try trigger.next(after: now)
            break
        }
    }
    return DueOccurrences(occurrences: due, next: cursor)
}

public extension AutomationDefinition {
    /// The JSON shape returned to an agent and used by the app's diagnostic UI.
    var json: JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "revision": .int(Int64(revision)),
            "title": .string(title),
            "enabled": .bool(enabled),
            "trigger": trigger.json,
            "task": .object([
                "prompt": .string(task.prompt),
                "flavour": .string(task.flavour),
                "params": .object(task.parameters),
                "cwd": task.workingDirectory.map(JSONValue.string) ?? .null,
            ]),
            "next": (try? trigger.next(after: Date())).flatMap { $0 }.map {
                .string(iso8601($0))
            } ?? .null,
        ])
    }
}

public extension AutomationRun {
    var json: JSONValue {
        .object([
            "id": .string(id.uuidString.lowercased()),
            "automation_id": .string(automationID.uuidString.lowercased()),
            "occurrence": .string(occurrenceKey),
            "scheduled_at": .string(iso8601(scheduledAt)),
            "state": .string(state.rawValue),
            "attempt": .int(Int64(attempt)),
            "result": result.map(JSONValue.string) ?? .null,
            "error": error.map(JSONValue.string) ?? .null,
        ])
    }
}

public extension AutomationTrigger {
    var json: JSONValue {
        switch self {
        case .at(let date):
            .object(["kind": .string("at"), "at": .string(iso8601(date))])
        case .interval(let every, let anchor):
            .object([
                "kind": .string("interval"), "seconds": .double(every),
                "anchor": .string(iso8601(anchor)),
            ])
        case .calendar(let schedule):
            .object([
                "kind": .string("calendar"),
                "frequency": .string(schedule.frequency.rawValue),
                "hour": .int(Int64(schedule.hour)),
                "minute": .int(Int64(schedule.minute)),
                "weekdays": .array(schedule.weekdays.map { .int(Int64($0)) }),
                "day": schedule.dayOfMonth.map { .int(Int64($0)) } ?? .null,
                "timezone": .string(schedule.timeZone),
                "nonexistent_time": .string(schedule.nonexistentTime.rawValue),
                "repeated_time": .string(schedule.repeatedTime.rawValue),
            ])
        case .event(let event):
            .object([
                "kind": .string("event"), "source": .string(event.source),
                "type": .string(event.type),
                "subject_contains": event.subjectContains.map(JSONValue.string) ?? .null,
            ])
        case .manual:
            .object(["kind": .string("manual")])
        }
    }
}

public func iso8601(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

public func parseISO8601(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    if let date = formatter.date(from: text) { return date }
    formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.date(from: text)
}

public extension AutomationDefinition {
    /// Strict parsing at the feature boundary. Unlike the forgiving base agent
    /// protocol, a schedule that is partly understood is dangerous, so this
    /// returns a useful validation error rather than silently defaulting fields.
    static func proposed(from value: JSONValue, now: Date = Date()) throws -> Self {
        guard let title = value["title"]?.string,
              let taskValue = value["task"],
              let prompt = taskValue["prompt"]?.string,
              let triggerValue = value["trigger"]
        else { throw AutomationError.invalid("title, task.prompt and trigger are required") }

        let task = AgentTask(
            prompt: prompt,
            flavour: taskValue["flavour"]?.string ?? "prose",
            parameters: taskValue["params"]?.object ?? [:],
            workingDirectory: taskValue["cwd"]?.string)
        let definition = AutomationDefinition(
            title: title,
            enabled: value["enabled"]?.bool ?? true,
            trigger: try AutomationTrigger.proposed(from: triggerValue, now: now),
            task: task,
            policy: try ExecutionPolicy.proposed(from: value["policy"]))
        try definition.validate()
        return definition
    }
}

private extension AutomationTrigger {
    static func proposed(from value: JSONValue, now: Date) throws -> Self {
        guard let kind = value["kind"]?.string else {
            throw AutomationError.invalid("trigger.kind is required")
        }
        switch kind {
        case "at":
            guard let text = value["at"]?.string, let date = parseISO8601(text) else {
                throw AutomationError.invalid("trigger.at must be an ISO 8601 date")
            }
            return .at(date)
        case "interval":
            guard let seconds = value["seconds"]?.number else {
                throw AutomationError.invalid("an interval trigger needs seconds")
            }
            let anchor: Date
            if let text = value["anchor"]?.string {
                guard let parsed = parseISO8601(text) else {
                    throw AutomationError.invalid("trigger.anchor must be an ISO 8601 date")
                }
                anchor = parsed
            } else {
                anchor = now.addingTimeInterval(seconds)
            }
            return .interval(every: seconds, anchor: anchor)
        case "calendar":
            guard let frequencyName = value["frequency"]?.string,
                  let frequency = CalendarFrequency(rawValue: frequencyName),
                  let hour = value["hour"]?.int.map(Int.init),
                  let minute = value["minute"]?.int.map(Int.init)
            else {
                throw AutomationError.invalid(
                    "a calendar trigger needs frequency, hour and minute")
            }
            let weekdays = value["weekdays"]?.array?.compactMap { $0.int.map(Int.init) } ?? []
            return .calendar(CalendarSchedule(
                frequency: frequency,
                hour: hour,
                minute: minute,
                weekdays: weekdays,
                dayOfMonth: value["day"]?.int.map(Int.init),
                timeZone: value["timezone"]?.string ?? TimeZone.current.identifier,
                nonexistentTime: value["nonexistent_time"]?.string
                    .flatMap(NonexistentTimePolicy.init(rawValue:)) ?? .nextValid,
                repeatedTime: value["repeated_time"]?.string
                    .flatMap(RepeatedTimePolicy.init(rawValue:)) ?? .first))
        case "event":
            guard let source = value["source"]?.string, let type = value["type"]?.string else {
                throw AutomationError.invalid("an event trigger needs source and type")
            }
            return .event(EventTrigger(
                source: source, type: type,
                subjectContains: value["subject_contains"]?.string))
        case "manual":
            return .manual
        default:
            throw AutomationError.invalid("unknown trigger kind \(kind)")
        }
    }
}

private extension ExecutionPolicy {
    static func proposed(from value: JSONValue?) throws -> Self {
        guard let value else { return ExecutionPolicy() }
        let concurrency = value["concurrency"]?.string
            .flatMap(ConcurrencyPolicy.init(rawValue:)) ?? .skipWhileRunning
        let misfire: MisfirePolicy
        switch value["misfire"]?.string ?? "runOnce" {
        case "skip": misfire = .skip
        case "runOnce": misfire = .runOnce
        case "catchUp": misfire = .catchUp(maximum: Int(value["catch_up"]?.int ?? 10))
        default: throw AutomationError.invalid("unknown misfire policy")
        }
        let policy = ExecutionPolicy(
            misfire: misfire,
            concurrency: concurrency,
            maximumRuntime: value["maximum_runtime"]?.number ?? 30 * 60,
            maximumAttempts: Int(value["maximum_attempts"]?.int ?? 1))
        try policy.validate()
        return policy
    }
}
