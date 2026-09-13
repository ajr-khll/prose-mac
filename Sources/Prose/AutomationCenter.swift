import Foundation
import Observation
import ProseAutomation
import ProseCore
import ProseHost

/// The app-facing client for the durable scheduler. The store itself is an
/// actor; this main-actor object holds only presentation snapshots and the
/// closure that opens a run in the workspace.
@MainActor
@Observable
final class AutomationCenter {
    private(set) var definitions: [StoredAutomation] = []
    private(set) var runs: [AutomationRun] = []
    private(set) var lastError: String?
    private(set) var running = false

    @ObservationIgnored let store: AutomationStore
    @ObservationIgnored private var scheduler: AutomationScheduler?
    @ObservationIgnored var onRun: ((AutomationRun) -> Void)?

    init(url: URL) throws {
        store = try AutomationStore(url: url)
        scheduler = AutomationScheduler(
            store: store,
            onRun: { [weak self] run in
                await MainActor.run { self?.dispatch(run) }
            },
            onError: { [weak self] message in
                await MainActor.run { self?.lastError = message }
            })
    }

    static var liveURL: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Prose/Automation/automation.sqlite3")
    }

    func start() {
        guard !running else { return }
        running = true
        Task {
            await reload()
            await scheduler?.start()
            await scheduler?.tick()
        }
    }

    func stop() {
        running = false
        Task { await scheduler?.stop() }
    }

    func reload() async {
        do {
            async let loadedDefinitions = store.list()
            async let loadedRuns = store.history(limit: 100)
            definitions = try await loadedDefinitions
            runs = try await loadedRuns
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func create(_ proposed: JSONValue) async throws -> StoredAutomation {
        let definition = try AutomationDefinition.proposed(from: proposed)
        let stored = try await store.create(definition)
        await reload()
        await scheduler?.tick()
        return stored
    }

    func change(id: UUID, action: String) async throws -> JSONValue {
        let answer: JSONValue
        switch action {
        case "pause":
            let item = try await store.setEnabled(id, enabled: false)
            answer = item.definition.json
        case "resume":
            let item = try await store.setEnabled(id, enabled: true)
            answer = item.definition.json
        case "delete":
            try await store.delete(id)
            answer = .object(["ok": .bool(true)])
        case "run_now":
            guard let run = try await store.runNow(id) else {
                throw AutomationError.conflict
            }
            answer = run.json
            await scheduler?.tick()
        default:
            throw AutomationError.invalid("unknown automation action")
        }
        await reload()
        return answer
    }

    func ingest(_ value: JSONValue) async throws -> [AutomationRun] {
        guard let externalID = value["external_id"]?.string,
              let source = value["source"]?.string,
              let type = value["type"]?.string
        else {
            throw AutomationError.invalid("event external_id, source and type are required")
        }
        let occurred: Date
        if let text = value["occurred_at"]?.string {
            guard let parsed = parseISO8601(text) else {
                throw AutomationError.invalid("event occurred_at must be an ISO 8601 date")
            }
            occurred = parsed
        } else {
            occurred = Date()
        }
        let created = try await store.ingest(AutomationEvent(
            externalID: externalID,
            source: source,
            type: type,
            occurredAt: occurred,
            subject: value["subject"]?.string,
            payload: value["payload"] ?? .null))
        await reload()
        await scheduler?.tick()
        return created
    }

    func complete(_ id: UUID, state: RunState, error: String? = nil) {
        Task {
            do { try await store.finish(id, state: state, error: error) }
            catch AutomationError.conflict { return }
            catch { lastError = error.localizedDescription }
            await reload()
        }
    }

    private func dispatch(_ run: AutomationRun) {
        runs.removeAll { $0.id == run.id }
        runs.insert(run, at: 0)
        onRun?(run)
    }

    var json: JSONValue {
        .object([
            "automations": .array(definitions.map { item in
                var fields = item.definition.json.object ?? [:]
                fields["next_fire_at"] = item.nextFireAt.map {
                    .string(iso8601($0))
                } ?? .null
                return .object(fields)
            }),
            "runs": .array(runs.map(\.json)),
        ])
    }
}
