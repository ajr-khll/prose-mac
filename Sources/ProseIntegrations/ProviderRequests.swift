import Foundation
import ProseCore

/// The per-provider half: what a search is, what a get is, and how to tell
/// whether a credential works.
///
/// One file rather than five, because the shape really is shared — build a
/// request, send it, map the response onto `ref`/`title`/`url`/`updated_at` —
/// and the differences are three or four lines each. Splitting it into five
/// types would mean five copies of the mapping and one place to forget.
///
/// **Everything returned here is data, not instruction.** A Slack message or a
/// GitHub issue body is written by other people, and the archetype's prompt
/// says so; this layer's contribution is to keep it bounded, so a long thread
/// cannot fill a context window and a "summary" is always a `summary`.
enum ProviderRequests {
    /// How long a body may be before it comes back cut, with its real length
    /// beside it. The point of a connector pane is that the raw material stays
    /// in it, so this is deliberately small.
    static let bodyLimit = 2000

    struct Resource {
        var ref: String
        var kind: String
        var title: String
        var url: String?
        var updatedAt: String?
        var author: String?
        var summary: String

        var json: JSONValue {
            .object([
                "ref": .string(ref),
                "kind": .string(kind),
                "title": .string(title),
                "url": url.map(JSONValue.string) ?? .null,
                "updated_at": updatedAt.map(JSONValue.string) ?? .null,
                "author": author.map(JSONValue.string) ?? .null,
                "summary": .string(summary),
            ])
        }
    }

    // MARK: - Sending

    /// One authenticated call. Every provider request goes through here, so
    /// there is one place that knows a 401 means "reconnect" rather than
    /// "retry" — which is the distinction an agent gets wrong otherwise.
    static func send(
        _ request: URLRequest, token: String, provider: String
    ) async throws -> [String: Any] {
        var authorised = request
        authorised.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        authorised.setValue("application/json", forHTTPHeaderField: "Accept")
        if provider == "notion" {
            // Notion refuses anything without a pinned API version.
            authorised.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        }
        if provider == "github" {
            authorised.setValue("application/vnd.github+json",
                                forHTTPHeaderField: "Accept")
        }

        let (data, response) = try await URLSession.shared.data(for: authorised)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        if status == 401 || status == 403 {
            throw IntegrationBroker.Failure.credentialRejected(
                provider, (parsed["message"] as? String) ?? "HTTP \(status)")
        }
        guard (200..<300).contains(status) else {
            throw IntegrationBroker.Failure.providerRefused(
                provider,
                (parsed["message"] as? String)
                    ?? (parsed["error"] as? String)
                    ?? "HTTP \(status)")
        }
        // Slack answers 200 with `{"ok": false}`, which is the one provider
        // where a successful HTTP status means nothing on its own.
        if provider == "slack", (parsed["ok"] as? Bool) == false {
            throw IntegrationBroker.Failure.providerRefused(
                provider, (parsed["error"] as? String) ?? "slack said no")
        }
        return parsed
    }

    static func get(_ url: String) -> URLRequest {
        URLRequest(url: URL(string: url)!)
    }

    static func post(_ url: String, body: [String: Any]) -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func bounded(_ text: String) -> String {
        guard text.count > bodyLimit else { return text }
        return String(text.prefix(bodyLimit))
            + "\n\n[cut — \(text.count) characters in full]"
    }

    // MARK: - Verifying a pasted credential

    /// Calls the provider's own "who am I" endpoint.
    ///
    /// Run at connect time so a typo in a pasted token fails immediately, with
    /// the provider's own words, rather than three steps into a job. It also
    /// supplies the account name, which is what a person recognises the
    /// connection by in a list.
    static func identify(provider: String, token: String) async throws -> String {
        switch provider {
        case "slack":
            let answer = try await send(get("https://slack.com/api/auth.test"),
                                        token: token, provider: provider)
            return (answer["team"] as? String) ?? "Slack"
        case "github":
            let answer = try await send(get("https://api.github.com/user"),
                                        token: token, provider: provider)
            return (answer["login"] as? String) ?? "GitHub"
        case "linear":
            let answer = try await graphql(
                "{ viewer { name } organization { name } }",
                token: token)
            let organisation = (answer["organization"] as? [String: Any])?["name"] as? String
            return organisation ?? "Linear"
        case "notion":
            let answer = try await send(get("https://api.notion.com/v1/users/me"),
                                        token: token, provider: provider)
            let bot = answer["bot"] as? [String: Any]
            let workspace = bot?["workspace_name"] as? String
            return workspace ?? (answer["name"] as? String) ?? "Notion"
        case "google":
            let answer = try await send(
                get("https://www.googleapis.com/oauth2/v2/userinfo"),
                token: token, provider: provider)
            return (answer["email"] as? String) ?? "Google"
        default:
            throw IntegrationBroker.Failure.unknownProvider(provider)
        }
    }

    /// Linear is GraphQL-only, so it gets the one helper it needs.
    static func graphql(_ query: String, token: String,
                        variables: [String: Any] = [:]) async throws -> [String: Any] {
        var request = post("https://api.linear.app/graphql",
                           body: ["query": query, "variables": variables])
        // Linear's personal API keys go in `Authorization` *without* `Bearer`,
        // unlike its OAuth tokens. Sending the wrong one is a 400 that says
        // nothing useful, so it is special-cased here rather than discovered.
        if token.hasPrefix("lin_api_") {
            request.setValue(token, forHTTPHeaderField: "Authorization")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            guard (200..<300).contains(status) else {
                throw IntegrationBroker.Failure.credentialRejected(
                    "linear", "HTTP \(status)")
            }
            return (parsed["data"] as? [String: Any]) ?? [:]
        }
        let parsed = try await send(request, token: token, provider: "linear")
        return (parsed["data"] as? [String: Any]) ?? [:]
    }
}
