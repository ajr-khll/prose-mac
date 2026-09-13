import Foundation

/// What a connected account is, and where the two halves of it live.
///
/// **The split is the point.** Everything in `Connection` is non-secret and
/// sits in a JSON file under Application Support, where it can be read,
/// diffed, backed up and shown in a list. The token never appears here: it
/// lives in the Keychain under `keychainAccount`, and the only code that
/// fetches one is the broker, at the moment it makes a call. So a transcript,
/// a log, a crash report or a screenshot of the Connections view cannot leak a
/// credential, because none of them ever hold one.
public struct Connection: Codable, Sendable, Equatable, Identifiable {
    /// Stable, user-chosen-ish, and the thing every `apps_*` call is scoped
    /// by. Refs embed it (`github:work:pull_request:…`) so that a ref from one
    /// account can never be resolved against another.
    public var id: String
    public var provider: String
    /// What a person would recognise: the workspace, the mailbox, the org.
    public var account: String
    /// Granted scopes, as the provider returned them rather than as we asked —
    /// a provider may narrow a request, and acting on what we *asked* for is
    /// how you get a 403 three steps into a job.
    public var scopes: [String]
    public var createdAt: Date
    public var lastUsedAt: Date?
    /// Set when a refresh failed or the provider revoked us. A connection in
    /// this state is listed rather than hidden: "reconnect Slack" is an answer
    /// an agent can give a person, and a missing row is not.
    public var needsReauth: Bool

    public init(
        id: String, provider: String, account: String, scopes: [String],
        createdAt: Date = Date(), lastUsedAt: Date? = nil, needsReauth: Bool = false
    ) {
        self.id = id
        self.provider = provider
        self.account = account
        self.scopes = scopes
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.needsReauth = needsReauth
    }

    /// Where the secret half lives. Derived rather than stored so the two
    /// halves cannot disagree about which Keychain item belongs to which row.
    public var keychainAccount: String { "\(provider):\(id)" }
}

/// The connection list, persisted as one small JSON file.
///
/// Versioned and written atomically. Atomically because this file is read at
/// launch and rewritten on every OAuth completion and token refresh, and a
/// half-written one means every pane opens with no connections and no
/// explanation; versioned because the shape will change and a future build has
/// to be able to tell "old" from "corrupt".
public actor ConnectionStore {
    private struct Document: Codable {
        var version: Int
        var connections: [Connection]
    }

    private static let currentVersion = 1

    private let url: URL
    private var connections: [Connection]

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Prose/Connections",
                                    isDirectory: true)
        try? FileManager.default.createDirectory(
            at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("connections.json")

        // A store that cannot read its file starts empty rather than throwing.
        // The failure a person can act on is "Slack is not connected", shown
        // in the view; a launch that dies on a malformed file is not.
        if let data = try? Data(contentsOf: url),
           let document = try? JSONDecoder.prose.decode(Document.self, from: data),
           document.version <= Self.currentVersion {
            self.connections = document.connections
        } else {
            self.connections = []
        }
    }

    public func all() -> [Connection] { connections }

    public func all(forProviders providers: [String]) -> [Connection] {
        let wanted = Set(providers)
        return connections.filter { wanted.contains($0.provider) }
    }

    public func connection(id: String) -> Connection? {
        connections.first { $0.id == id }
    }

    /// Adds or replaces one row and writes the file.
    public func save(_ connection: Connection) throws {
        connections.removeAll { $0.id == connection.id }
        connections.append(connection)
        try persist()
    }

    /// Forgets a connection *and* its secret. Both, or a disconnected account
    /// leaves a live token in the Keychain with nothing referencing it.
    public func remove(id: String) throws {
        guard let found = connection(id: id) else { return }
        try? Keychain.delete(account: found.keychainAccount)
        connections.removeAll { $0.id == id }
        try persist()
    }

    public func markUsed(id: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].lastUsedAt = Date()
        try? persist()
    }

    public func markNeedsReauth(id: String) {
        guard let index = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[index].needsReauth = true
        try? persist()
    }

    private func persist() throws {
        let document = Document(version: Self.currentVersion, connections: connections)
        let data = try JSONEncoder.prose.encode(document)
        // `.atomic` so a reader never sees a truncated file.
        try data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    static var prose: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var prose: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
