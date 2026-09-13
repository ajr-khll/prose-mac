import Foundation

/// Turns durable due rows into leased runs. The handler is intentionally a
/// dispatch boundary: an app can open a pane, while a launch agent can start a
/// headless run host, without putting either policy into the scheduler.
public actor AutomationScheduler {
    public typealias RunHandler = @Sendable (AutomationRun) async -> Void
    public typealias ErrorHandler = @Sendable (String) async -> Void

    private let store: AutomationStore
    private let owner: String
    private let pollInterval: Duration
    private let onRun: RunHandler
    private let onError: ErrorHandler?
    private var loop: Task<Void, Never>?

    public init(
        store: AutomationStore,
        owner: String = UUID().uuidString.lowercased(),
        pollInterval: Duration = .seconds(1),
        onRun: @escaping RunHandler,
        onError: ErrorHandler? = nil
    ) {
        self.store = store
        self.owner = owner
        self.pollInterval = pollInterval
        self.onRun = onRun
        self.onError = onError
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                do { try await Task.sleep(for: self?.pollInterval ?? .seconds(1)) }
                catch { break }
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Public for app activation, event ingestion and deterministic tests. A
    /// tick never sleeps and claims every row that was ready at its `now`.
    public func tick(now: Date = Date()) async {
        do {
            _ = try await store.recoverExpired(now: now)
            _ = try await store.reconcile(now: now)
            while let run = try await store.claimNext(owner: owner, now: now) {
                _ = try await store.heartbeat(
                    run.id,
                    owner: owner,
                    now: now,
                    leaseFor: run.definition.policy.maximumRuntime + 60)
                await onRun(run)
            }
        } catch {
            await onError?(error.localizedDescription)
        }
    }
}
