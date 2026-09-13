import Foundation
import ProseCore

/// The host side of `integration.call`.
///
/// Everything a pane is not allowed to decide for itself is decided here: which
/// provider it may reach, which connection, whether a token is still good, and
/// whether a prepared change is still the change a person approved. The pane
/// sends the provider set its archetype declared, and this refuses anything
/// outside it — the pane's copy of that list is a convenience, not the
/// authority, because a compromised pane would send whatever list it liked.
///
/// **Why previews live here and not in the agent.** `apps_prepare` returns an
/// id; `apps_commit` sends nothing but that id. If the preview lived in the
/// pane, a model could hold two of them and commit the one a person did not
/// read. Here, the id resolves to an immutable record with the arguments
/// already hashed, so the text on the card and the bytes on the wire cannot
/// come apart.
public actor IntegrationBroker {
    private let connections: ConnectionStore
    private let previews: PreviewStore

    /// How a sign-in reaches the user's screen. Injected so this target links
    /// no AppKit and a test can run the whole broker without a browser.
    private let openURL: @Sendable (URL) -> Void

    public init(
        connections: ConnectionStore = ConnectionStore(),
        openURL: @escaping @Sendable (URL) -> Void
    ) {
        self.connections = connections
        self.previews = PreviewStore()
        self.openURL = openURL
    }

    public enum Failure: Error, LocalizedError {
        case unknownOperation(String)
        case providerNotAllowed(String, held: [String])
        case unknownProvider(String)
        case notConnected(String)
        case noSuchConnection(String)
        case noSuchPreview(String)
        case previewExpired
        case targetMoved(String)
        case credentialRejected(String, String)
        case providerRefused(String, String)
        case badRef(String)
        case notImplemented(String)

        public var errorDescription: String? {
            switch self {
            case .unknownOperation(let name):
                return "no such integration operation \(name)"
            case .providerNotAllowed(let provider, let held):
                return "this pane holds \(held.joined(separator: ", ")) and not \(provider)"
            case .unknownProvider(let provider):
                return "prose does not broker \(provider)"
            case .notConnected(let provider):
                return """
                    \(provider) is not connected. Ask the person to connect it \
                    in prose's Connections view — this is a question for them, \
                    not something to retry.
                    """
            case .noSuchConnection(let id):
                return "no connection \(id)"
            case .noSuchPreview(let id):
                return "no prepared change \(id) — prepare it again"
            case .previewExpired:
                return "that prepared change has expired; prepare it again"
            case .targetMoved(let detail):
                // Never rebased silently: the person approved a specific
                // before-and-after, and the before has changed.
                return """
                    the target changed since you prepared this (\(detail)). \
                    Prepare again so the person sees the new text before \
                    approving it.
                    """
            case .credentialRejected(let provider, let why):
                return """
                    \(provider) rejected the credential (\(why)). It has \
                    expired or been revoked — ask the person to connect \
                    \(provider) again with apps_connect. Retrying the same \
                    call will not help.
                    """
            case .providerRefused(let provider, let why):
                return "\(provider) refused the request: \(why)"
            case .badRef(let ref):
                return """
                    \(ref) is not a ref this pane can resolve. Refs come \
                    from apps_search and look like \
                    `github:<connection>:issue:<id>` — do not construct one.
                    """
            case .notImplemented(let what):
                return """
                    \(what) is not built yet. Report it in `failed` — the \
                    connection and the credential are fine, the provider slice \
                    is what is missing.
                    """
            }
        }
    }

    /// The one entry point `Host` calls.
    public func call(
        operation: String, providers: [String], arguments: JSONValue
    ) async throws -> JSONValue {
        // Validated against prose's own catalogue first: a pane sending a
        // provider nobody brokers is a bug or an attempt, and either way it
        // must not reach a lookup.
        for provider in providers where Provider.catalogue[provider] == nil {
            throw Failure.unknownProvider(provider)
        }

        switch operation {
        case "connections":
            return await listConnections(providers: providers)
        case "capabilities":
            let provider = try require(arguments["provider"]?.string, providers)
            return try await capabilities(provider: provider)
        case "search":
            let provider = try require(arguments["provider"]?.string, providers)
            return try await search(provider: provider, arguments: arguments)
        case "get":
            let ref = arguments["ref"]?.string ?? ""
            let provider = try require(ref.split(separator: ":").first.map(String.init),
                                       providers)
            return try await get(provider: provider, ref: ref, arguments: arguments)
        case "prepare":
            let provider = try require(arguments["provider"]?.string, providers)
            return try await prepare(provider: provider, arguments: arguments)
        case "commit":
            return try await commit(preview: arguments["preview"]?.string ?? "")
        case "connect":
            return try await connect(arguments: arguments)
        case "cancel":
            await previews.remove(arguments["preview"]?.string ?? "")
            return .object(["cancelled": .bool(true)])
        default:
            throw Failure.unknownOperation(operation)
        }
    }

    /// The provider check, in the one place every operation passes through.
    private func require(_ provider: String?, _ held: [String]) throws -> String {
        guard let provider, !provider.isEmpty else {
            throw Failure.unknownProvider("(none given)")
        }
        guard held.contains(provider) else {
            throw Failure.providerNotAllowed(provider, held: held)
        }
        return provider
    }

    // MARK: - Operations

    private func listConnections(providers: [String]) async -> JSONValue {
        let rows = await connections.all(forProviders: providers)
        let listed = rows.map { row -> JSONValue in
            .object([
                "connection": .string(row.id),
                "provider": .string(row.provider),
                "account": .string(row.account),
                "scopes": .array(row.scopes.map(JSONValue.string)),
                "needs_reauth": .bool(row.needsReauth),
                "last_used": row.lastUsedAt.map { .string(ISO8601DateFormatter().string(from: $0)) } ?? .null,
            ])
        }
        // The providers with nothing connected are named explicitly. A model
        // that sees an empty list cannot tell "not connected" from "no results",
        // and the two need completely different responses from it.
        let connected = Set(rows.map(\.provider))
        let missing = providers.filter { !connected.contains($0) }
        return .object([
            "connections": .array(listed),
            "not_connected": .array(missing.map(JSONValue.string)),
            "hint": missing.isEmpty
                ? .null
                : .string("""
                    \(missing.joined(separator: ", ")) \
                    \(missing.count == 1 ? "is" : "are") not connected. That is \
                    a question for the person — they connect an account in \
                    prose's Connections view — and not something to retry.
                    """),
        ])
    }

    private func capabilities(provider: String) async throws -> JSONValue {
        _ = try await live(provider: provider)
        return ProviderCapabilities.describe(provider)
    }

    /// Sign in, from the pane that needs it.
    ///
    /// The person has already seen a card and handed over the credential by
    /// the time this runs — `apps_connect` asks before it calls — so what is
    /// left here is to check the credential actually works and store it. It is
    /// checked by calling the provider's own "who am I": a typo fails now,
    /// with the provider's words, rather than three steps into a job.
    private func connect(arguments: JSONValue) async throws -> JSONValue {
        let provider = arguments["provider"]?.string ?? ""
        guard let known = Provider.catalogue[provider] else {
            throw Failure.unknownProvider(provider)
        }

        let token: Keychain.Token
        if arguments["kind"]?.string == "oauth" {
            let client = Keychain.ClientCredentials(
                clientID: arguments["client_id"]?.string ?? "",
                clientSecret: arguments["client_secret"]?.string)
            try Keychain.saveClient(client, provider: provider)
            let outcome = try await OAuthFlow().run(
                .init(provider: provider,
                      authorizeURL: known.authorizeURL,
                      tokenURL: known.tokenURL,
                      clientID: client.clientID,
                      clientSecret: known.needsClientSecret ? client.clientSecret : nil,
                      scopes: known.scopes,
                      extraAuthorizeParameters: known.extraAuthorizeParameters),
                openURL: openURL)
            token = outcome.token
        } else {
            token = Keychain.Token(
                accessToken: arguments["secret"]?.string ?? "",
                scopes: known.scopes)
        }

        let account = try await ProviderRequests.identify(
            provider: provider, token: token.accessToken)

        let connection = Connection(
            id: "\(provider)_\(UUID().uuidString.prefix(8).lowercased())",
            provider: provider, account: account, scopes: token.scopes)
        try Keychain.save(token, account: connection.keychainAccount)
        // One connection per provider for now: reconnecting replaces rather
        // than accumulating, which is what a person means by "reconnect".
        for existing in await connections.all(forProviders: [provider]) {
            try await connections.remove(id: existing.id)
        }
        try await connections.save(connection)

        return .object([
            "connected": .bool(true),
            "connection": .string(connection.id),
            "provider": .string(provider),
            "account": .string(account),
        ])
    }

    private func search(provider: String, arguments: JSONValue) async throws -> JSONValue {
        let (connection, token) = try await live(provider: provider)
        let rows = try await ProviderReads.search(
            provider: provider, connection: connection, token: token,
            kind: arguments["kind"]?.string ?? defaultKind(provider),
            filters: arguments["filters"] ?? .null,
            // Capped as well as defaulted: a model that asks for a thousand
            // rows is usually missing a filter, and the pane pays either way.
            limit: min(arguments["limit"]?.int.map(Int.init) ?? 20, 50))
        await connections.markUsed(id: connection.id)
        return .object([
            "connection": .string(connection.id),
            "results": .array(rows.map(\.json)),
            "count": .int(Int64(rows.count)),
        ])
    }

    private func get(provider: String, ref: String,
                     arguments: JSONValue) async throws -> JSONValue {
        let (connection, token) = try await live(provider: provider)
        // The ref names the connection it came from. Resolving it against a
        // different one would let a ref read out of another pane's transcript
        // reach this pane's account.
        let named = ref.split(separator: ":").dropFirst().first.map(String.init)
        guard named == connection.id else {
            throw Failure.badRef(ref)
        }
        let answer = try await ProviderReads.get(
            provider: provider, connection: connection, token: token, ref: ref)
        await connections.markUsed(id: connection.id)
        return answer
    }

    /// What a search means when the model did not say. Every provider has one
    /// obvious answer, and making `kind` required would cost a round-trip to
    /// `apps_capabilities` for the common case.
    private func defaultKind(_ provider: String) -> String {
        switch provider {
        case "slack": return "message"
        case "github": return "issue"
        case "linear": return "issue"
        case "notion": return "page"
        case "google": return "email"
        default: return ""
        }
    }

    private func prepare(provider: String, arguments: JSONValue) async throws -> JSONValue {
        _ = try await live(provider: provider)
        // Phase 3/4. Writing is the half that needs per-operation schemas and
        // a version check per provider, and a half-built one that sends
        // something is worse than one that refuses.
        throw Failure.notImplemented("changes to \(provider)")
    }

    private func commit(preview id: String) async throws -> JSONValue {
        guard let record = await previews.get(id) else { throw Failure.noSuchPreview(id) }
        guard record.expiresAt > Date() else {
            await previews.remove(id)
            throw Failure.previewExpired
        }
        throw Failure.notImplemented("committing \(record.operation)")
    }

    // MARK: - Credentials

    /// The connection to use for one provider, with a token that is good now.
    ///
    /// Refresh happens here rather than at call sites so that every path gets
    /// it and none of them has to remember. A refresh that fails marks the row
    /// `needsReauth` instead of throwing something opaque: "reconnect Slack" is
    /// an instruction a person can follow.
    private func live(provider: String) async throws -> (Connection, String) {
        let rows = await connections.all(forProviders: [provider])
        guard let connection = rows.first(where: { !$0.needsReauth }) ?? rows.first else {
            throw Failure.notConnected(provider)
        }
        guard let token = try Keychain.load(account: connection.keychainAccount) else {
            await connections.markNeedsReauth(id: connection.id)
            throw Failure.notConnected(provider)
        }
        if token.isExpired {
            guard let refreshed = try await refresh(token, for: connection) else {
                await connections.markNeedsReauth(id: connection.id)
                throw Failure.notConnected(provider)
            }
            try Keychain.save(refreshed, account: connection.keychainAccount)
            return (connection, refreshed.accessToken)
        }
        return (connection, token.accessToken)
    }

    private func refresh(
        _ token: Keychain.Token, for connection: Connection
    ) async throws -> Keychain.Token? {
        guard let refreshToken = token.refreshToken,
              let provider = Provider.catalogue[connection.provider],
              let client = try Keychain.loadClient(provider: connection.provider)
        else { return nil }

        var form = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": client.clientID,
        ]
        if let secret = client.clientSecret { form["client_secret"] = secret }

        var post = URLRequest(url: provider.tokenURL)
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        post.setValue("application/json", forHTTPHeaderField: "Accept")
        post.httpBody = OAuthFlow.formEncoded(form).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: post)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = parsed["access_token"] as? String
        else { return nil }

        return Keychain.Token(
            accessToken: access,
            // Providers that rotate refresh tokens send a new one; those that
            // do not send none, and the old one stays valid. Dropping it in
            // the second case would break the connection on the next refresh.
            refreshToken: parsed["refresh_token"] as? String ?? refreshToken,
            expiresAt: (parsed["expires_in"] as? Double).map { Date().addingTimeInterval($0) },
            scopes: token.scopes)
    }

    // MARK: - Signing in

    /// Runs a sign-in and stores the result. Called from the Connections view,
    /// never from a pane: an agent cannot start an OAuth flow, because a
    /// consent screen that appears without a person having asked for it is
    /// exactly the thing a person would click through.
    public func connect(provider id: String) async throws -> Connection {
        guard let provider = Provider.catalogue[id] else {
            throw Failure.unknownProvider(id)
        }
        guard let client = try Keychain.loadClient(provider: id) else {
            throw OAuthFlow.Failure.noClientRegistration(provider.displayName)
        }

        let outcome = try await OAuthFlow().run(
            .init(provider: id,
                  authorizeURL: provider.authorizeURL,
                  tokenURL: provider.tokenURL,
                  clientID: client.clientID,
                  clientSecret: provider.needsClientSecret ? client.clientSecret : nil,
                  scopes: provider.scopes,
                  extraAuthorizeParameters: provider.extraAuthorizeParameters),
            openURL: openURL)

        let connection = Connection(
            id: "\(id)_\(UUID().uuidString.prefix(8).lowercased())",
            provider: id,
            account: provider.accountName(from: outcome.rawResponse),
            scopes: outcome.token.scopes)

        try Keychain.save(outcome.token, account: connection.keychainAccount)
        try await connections.save(connection)
        return connection
    }

    public func disconnect(id: String) async throws {
        try await connections.remove(id: id)
    }

    public func listAll() async -> [Connection] {
        await connections.all()
    }
}

/// Prepared-but-uncommitted changes, in memory for the life of the app.
///
/// Not persisted on purpose. A preview is a promise about the state of a
/// remote resource *right now*; one that survived a restart would be making
/// that promise about a world it stopped watching, and the expiry is what
/// keeps the window short enough for the promise to hold.
actor PreviewStore {
    struct Record: Sendable {
        var id: String
        var session: UInt64
        var connection: String
        var operation: String
        var target: String?
        var argumentsHash: String
        var baseVersion: String?
        var preview: String
        var risk: String
        var expiresAt: Date
    }

    private var records: [String: Record] = [:]

    func put(_ record: Record) { records[record.id] = record }
    func get(_ id: String) -> Record? { records[id] }
    func remove(_ id: String) { records.removeValue(forKey: id) }
}
