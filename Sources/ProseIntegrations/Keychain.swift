import Foundation
import Security

/// The secret half of a connection.
///
/// Small on purpose. Everything here is four calls to `SecItem*` with one
/// service name, and nothing else in the project touches `Security` — so if
/// you want to know every place a provider token can be read from, it is this
/// file and the two functions below.
///
/// Tokens are stored as one JSON blob per connection rather than as separate
/// items for access token, refresh token and expiry. A refresh rewrites all
/// three together, and three items mean three writes that can half-fail,
/// leaving an access token that has expired beside a refresh token that has
/// already been spent.
public enum Keychain {
    /// One service for all of prose's items, so a person can find them in
    /// Keychain Access by searching one word, and `delete` cannot reach
    /// anything that is not ours.
    public static let service = "com.prose.integrations"

    public struct Token: Codable, Sendable, Equatable {
        public var accessToken: String
        public var refreshToken: String?
        public var expiresAt: Date?
        /// Kept because a refresh that returns a *narrower* grant than the one
        /// stored is a scope change a person should be told about, and the
        /// only way to notice is to have the old one.
        public var scopes: [String]

        public init(accessToken: String, refreshToken: String? = nil,
                    expiresAt: Date? = nil, scopes: [String] = []) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.expiresAt = expiresAt
            self.scopes = scopes
        }

        /// Treated as expired a minute early, because the call that uses it
        /// has to cross a network after this check.
        public var isExpired: Bool {
            guard let expiresAt else { return false }
            return expiresAt.timeIntervalSinceNow < 60
        }
    }

    public enum Failure: Error, LocalizedError {
        case status(OSStatus)
        case malformed

        public var errorDescription: String? {
            switch self {
            case .status(let code):
                let message = SecCopyErrorMessageString(code, nil) as String?
                return message ?? "keychain error \(code)"
            case .malformed:
                return "the stored credential could not be read"
            }
        }
    }

    public static func save(_ token: Token, account: String) throws {
        let data = try JSONEncoder.prose.encode(token)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Update if it is there, add if it is not. `SecItemAdd` on an existing
        // account fails with `errSecDuplicateItem`, and a refresh is an update
        // far more often than it is a first write.
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            // Not synchronised to iCloud, and readable only when the Mac is
            // unlocked: a workspace token is not something to replicate.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(insert as CFDictionary, nil)
            guard added == errSecSuccess else { throw Failure.status(added) }
        } else if status != errSecSuccess {
            throw Failure.status(status)
        }
    }

    public static func load(account: String) throws -> Token? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure.status(status) }
        guard let data = item as? Data else { throw Failure.malformed }
        return try JSONDecoder.prose.decode(Token.self, from: data)
    }

    public static func delete(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.status(status)
        }
    }

    // MARK: - The app registration a person supplies once

    /// A provider's OAuth client credentials, which are *not* shipped in the
    /// bundle.
    ///
    /// The plan is explicit that embedding a shared Slack, Notion or Linear
    /// client secret — or a GitHub App private key — in the `.app` is not an
    /// acceptable shortcut, because every copy of prose would then share one
    /// identity and one revocation. So each person registers their own app
    /// once and the credentials land here, under a separate account name from
    /// any connection so the two can never collide.
    public struct ClientCredentials: Codable, Sendable, Equatable {
        public var clientID: String
        public var clientSecret: String?

        public init(clientID: String, clientSecret: String? = nil) {
            self.clientID = clientID
            self.clientSecret = clientSecret
        }
    }

    private static func clientAccount(_ provider: String) -> String {
        "client:\(provider)"
    }

    public static func saveClient(_ credentials: ClientCredentials,
                                  provider: String) throws {
        let data = try JSONEncoder.prose.encode(credentials)
        let token = Token(accessToken: String(data: data, encoding: .utf8) ?? "")
        try save(token, account: clientAccount(provider))
    }

    public static func loadClient(provider: String) throws -> ClientCredentials? {
        guard let stored = try load(account: clientAccount(provider)),
              let data = stored.accessToken.data(using: .utf8) else { return nil }
        return try? JSONDecoder.prose.decode(ClientCredentials.self, from: data)
    }
}
