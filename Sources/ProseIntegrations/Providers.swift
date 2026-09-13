import Foundation

/// What prose knows about each of the five providers.
///
/// One table rather than five classes, because at this layer they genuinely
/// are the same shape: an authorize endpoint, a token endpoint, the scopes to
/// ask for, and how to read an account name out of whatever the token response
/// happened to look like. The differences that are *not* the same shape — how
/// Linear's GraphQL differs from GitHub's REST — live in the request builders,
/// not here.
///
/// Scopes are deliberately the narrowest set that makes the archetype's job
/// possible, and read-only wherever the archetype is read-only. A scope asked
/// for "in case" is a scope a person grants forever.
public struct Provider: Sendable {
    public var id: String
    public var displayName: String
    public var authorizeURL: URL
    public var tokenURL: URL
    public var scopes: [String]
    public var extraAuthorizeParameters: [String: String]
    /// Where the account's human-readable name hides in the token response.
    /// Providers disagree entirely, so each one names its own path.
    public var accountNamePath: [String]
    /// Whether the provider requires a confidential client. PKCE covers the
    /// rest, and a secret in a desktop app is not a secret.
    public var needsClientSecret: Bool

    public static let catalogue: [String: Provider] = [
        "slack": Provider(
            id: "slack",
            displayName: "Slack",
            authorizeURL: URL(string: "https://slack.com/oauth/v2/authorize")!,
            tokenURL: URL(string: "https://slack.com/api/oauth.v2.access")!,
            // User-token reads only. No `chat:write` here: sending is a
            // prepare/commit path and the scope for it is granted separately,
            // so a read-only connection cannot be talked into posting.
            scopes: ["channels:read", "channels:history", "groups:read",
                     "groups:history", "im:read", "im:history", "users:read",
                     "search:read"],
            // Slack splits bot and user tokens; prose wants the user's own
            // view, which is what `user_scope` asks for.
            extraAuthorizeParameters: ["user_scope": "channels:history,search:read"],
            accountNamePath: ["team", "name"],
            needsClientSecret: true),

        "google": Provider(
            id: "google",
            displayName: "Google Workspace",
            authorizeURL: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenURL: URL(string: "https://oauth2.googleapis.com/token")!,
            scopes: ["https://www.googleapis.com/auth/gmail.readonly",
                     "https://www.googleapis.com/auth/calendar.readonly",
                     "https://www.googleapis.com/auth/drive.readonly",
                     "https://www.googleapis.com/auth/userinfo.email"],
            // Without `access_type=offline` Google issues no refresh token at
            // all, and the connection silently dies in an hour. `prompt=consent`
            // forces one to be re-issued when reconnecting an account that has
            // already granted.
            extraAuthorizeParameters: ["access_type": "offline",
                                       "prompt": "consent"],
            accountNamePath: ["email"],
            needsClientSecret: true),

        "linear": Provider(
            id: "linear",
            displayName: "Linear",
            authorizeURL: URL(string: "https://linear.app/oauth/authorize")!,
            tokenURL: URL(string: "https://api.linear.app/oauth/token")!,
            scopes: ["read"],
            extraAuthorizeParameters: [:],
            accountNamePath: ["organization", "name"],
            needsClientSecret: true),

        "github": Provider(
            id: "github",
            displayName: "GitHub",
            authorizeURL: URL(string: "https://github.com/login/oauth/authorize")!,
            tokenURL: URL(string: "https://github.com/login/oauth/access_token")!,
            scopes: ["repo", "read:org", "read:user"],
            extraAuthorizeParameters: [:],
            accountNamePath: ["login"],
            needsClientSecret: true),

        "notion": Provider(
            id: "notion",
            displayName: "Notion",
            authorizeURL: URL(string: "https://api.notion.com/v1/oauth/authorize")!,
            tokenURL: URL(string: "https://api.notion.com/v1/oauth/token")!,
            scopes: [],
            // Notion has no scope model: a person picks which pages the
            // integration can see during the consent flow itself, which is
            // why `owner=user` matters — it is what makes that picker appear.
            extraAuthorizeParameters: ["owner": "user"],
            accountNamePath: ["workspace_name"],
            needsClientSecret: true),
    ]

    /// The provider set an archetype may declare. Kept in step with
    /// `apps.PROVIDERS` on the Python side; `IntegrationBrokerTests` asserts
    /// the two agree, because a provider in one and not the other is a tool
    /// that exists and can never succeed.
    public static var known: [String] { catalogue.keys.sorted() }

    /// Reads the account name out of a token response, falling back to the
    /// provider's own name rather than to an empty row.
    public func accountName(from response: Data) -> String {
        let parsed = (try? JSONSerialization.jsonObject(with: response))
            as? [String: Any] ?? [:]
        return accountName(from: parsed)
    }

    func accountName(from response: [String: Any]) -> String {
        var cursor: Any = response
        for key in accountNamePath {
            guard let level = cursor as? [String: Any], let next = level[key] else {
                return displayName
            }
            cursor = next
        }
        return (cursor as? String) ?? displayName
    }
}
