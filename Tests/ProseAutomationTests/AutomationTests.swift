import Foundation
import ProseAutomation
import ProseCore
import Testing

@Suite("Automation recurrence")
struct RecurrenceTests {
    private func date(_ text: String) -> Date {
        try! #require(parseISO8601(text))
    }

    @Test("intervals stay anchored instead of drifting from the scheduler tick")
    func anchoredInterval() throws {
        let anchor = date("2026-09-13T12:00:00Z")
        let trigger = AutomationTrigger.interval(every: 300, anchor: anchor)
        #expect(try trigger.next(after: date("2026-09-13T12:06:11Z"))
                == date("2026-09-13T12:10:00Z"))
    }

    @Test("run-once collapses missed intervals and advances into the future")
    func runOnceMisfire() throws {
        let trigger = AutomationTrigger.interval(
            every: 300, anchor: date("2026-09-13T12:00:00Z"))
        let due = try dueOccurrences(
            trigger: trigger,
            nextFire: date("2026-09-13T12:00:00Z"),
            now: date("2026-09-13T12:21:00Z"),
            policy: .runOnce)
        #expect(due.occurrences == [date("2026-09-13T12:00:00Z")])
        #expect(due.next == date("2026-09-13T12:25:00Z"))
    }

    @Test("catch-up is bounded")
    func boundedCatchUp() throws {
        let trigger = AutomationTrigger.interval(
            every: 60, anchor: date("2026-09-13T12:00:00Z"))
        let due = try dueOccurrences(
            trigger: trigger,
            nextFire: date("2026-09-13T12:00:00Z"),
            now: date("2026-09-13T14:00:00Z"),
            policy: .catchUp(maximum: 3))
        #expect(due.occurrences.count == 3)
        #expect(due.next == date("2026-09-13T14:01:00Z"))
    }

    @Test("weekly calendar rules retain their named zone")
    func weeklyCalendar() throws {
        let schedule = CalendarSchedule(
            frequency: .weekly,
            hour: 8,
            minute: 30,
            weekdays: [2],
            timeZone: "America/Los_Angeles")
        #expect(try schedule.next(after: date("2026-09-13T20:00:00Z"))
                == date("2026-09-14T15:30:00Z"))
    }

    @Test("strict DST policy skips a nonexistent local time")
    func dstSkip() throws {
        let schedule = CalendarSchedule(
            frequency: .daily,
            hour: 2,
            minute: 30,
            timeZone: "America/Los_Angeles",
            nonexistentTime: .skip)
        #expect(try schedule.next(after: date("2026-03-08T09:00:00Z"))
                == date("2026-03-09T09:30:00Z"))
    }
}

@Suite("Automation store")
struct StoreTests {
    private func date(_ text: String) -> Date { try! #require(parseISO8601(text)) }

    private func store() throws -> (AutomationStore, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("prose-automation-tests-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("automation.sqlite3")
        return (try AutomationStore(url: url), directory)
    }

    private func definition(
        trigger: AutomationTrigger,
        concurrency: ConcurrencyPolicy = .queue
    ) -> AutomationDefinition {
        AutomationDefinition(
            title: "Morning report",
            trigger: trigger,
            task: AgentTask(prompt: "Summarize the project."),
            policy: ExecutionPolicy(concurrency: concurrency))
    }

    @Test("reconciliation persists one deterministic occurrence")
    func reconcileIsIdempotent() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let instant = date("2026-09-13T12:00:00Z")
        _ = try await store.create(definition(trigger: .at(instant)), now: instant)

        #expect(try await store.reconcile(now: instant).count == 1)
        #expect(try await store.reconcile(now: instant).isEmpty)
        #expect(try await store.history().count == 1)
    }

    @Test("duplicate external events cannot create duplicate runs")
    func eventDedupe() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date("2026-09-13T12:00:00Z")
        _ = try await store.create(definition(trigger: .event(EventTrigger(
            source: "build", type: "failed", subjectContains: "main"))), now: now)
        let event = AutomationEvent(
            externalID: "build-42", source: "build", type: "failed", occurredAt: now,
            subject: "main branch")

        #expect(try await store.ingest(event).count == 1)
        #expect(try await store.ingest(event).isEmpty)
        #expect(try await store.history().count == 1)
    }

    @Test("a claimed run is not claimable twice")
    func atomicClaim() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date("2026-09-13T12:00:00Z")
        let item = try await store.create(definition(trigger: .manual), now: now)
        _ = try await store.runNow(item.id, now: now)

        let first = try #require(try await store.claimNext(owner: "one", now: now))
        #expect(first.state == .running)
        #expect(first.attempt == 1)
        #expect(try await store.claimNext(owner: "two", now: now) == nil)
    }

    @Test("an expired lease retries only within the approved attempt limit")
    func leaseRecovery() async throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = date("2026-09-13T12:00:00Z")
        var value = definition(trigger: .manual)
        value.policy.maximumAttempts = 2
        let item = try await store.create(value, now: now)
        _ = try await store.runNow(item.id, now: now)
        _ = try await store.claimNext(owner: "one", now: now, leaseFor: 10)

        #expect(try await store.recoverExpired(now: now.addingTimeInterval(11)) == 1)
        let retried = try #require(try await store.claimNext(
            owner: "two", now: now.addingTimeInterval(11), leaseFor: 10))
        #expect(retried.attempt == 2)
        #expect(try await store.recoverExpired(now: now.addingTimeInterval(22)) == 1)
        #expect(try await store.history().first?.state == .failed)
    }
}
