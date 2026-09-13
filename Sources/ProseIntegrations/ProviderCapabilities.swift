import Foundation
import ProseCore

/// What `apps_capabilities` answers.
///
/// Written down here rather than fetched from each provider, because the
/// question the model is really asking is "what will *prose* let me do", and
/// that is a smaller set than what the provider's API offers. Advertising a
/// capability the broker has not implemented is the same failure as an
/// archetype naming a tool that does not exist: it looks equipped and is not.
///
/// So every kind and operation listed here must have a working path through
/// `IntegrationBroker`. Anything still unbuilt is named in `unavailable`, with
/// the reason, so an agent can put it in `failed` and let the parent route it
/// rather than retrying a wall.
enum ProviderCapabilities {
    static func describe(_ provider: String) -> JSONValue {
        .object([
            "provider": .string(provider),
            "kinds": .array(kinds(provider).map(JSONValue.string)),
            "operations": .array(operations(provider).map(JSONValue.string)),
            "unavailable": .array(unavailable(provider).map(JSONValue.string)),
            "notes": .string(notes(provider)),
        ])
    }

    private static func kinds(_ provider: String) -> [String] {
        switch provider {
        case "slack": return ["channel", "message", "thread", "user"]
        case "google": return ["email", "event", "file", "document"]
        case "linear": return ["issue", "project", "team", "comment"]
        case "github": return ["repository", "issue", "pull_request", "check", "release"]
        case "notion": return ["page", "database", "block"]
        default: return []
        }
    }

    private static func operations(_ provider: String) -> [String] {
        // Empty for every provider today: the prepare/commit paths are not
        // built, and listing an operation the broker would refuse is worse
        // than listing none. Phase 3 fills this in for `workflow`, Phase 4 for
        // `deployment`.
        []
    }

    private static func unavailable(_ provider: String) -> [String] {
        // Reading works. Writing does not yet, and naming the operations here
        // is what stops a specialist from trying: an agent that can see the
        // list refuses in `failed` instead of hunting for another route it
        // does not have.
        writeOperations(provider)
    }

    private static func writeOperations(_ provider: String) -> [String] {
        switch provider {
        case "slack": return ["message.post", "message.reply"]
        case "google": return ["email.send", "event.create", "event.update"]
        case "linear": return ["issue.create", "issue.update", "comment.create"]
        case "github": return ["issue.create", "issue.comment", "pull_request.review"]
        case "notion": return ["page.create", "page.update", "block.append"]
        default: return []
        }
    }

    private static func notes(_ provider: String) -> String {
        """
        Reading \(provider) works: apps_search for bounded rows, apps_get for \
        one of them in full. Changing anything does not yet — every operation \
        under `unavailable` refuses, so say so in `failed` rather than looking \
        for another route. You have no browser, shell or HTTP tool to fall \
        back on, and that is deliberate.

        apps_search takes `filters.query` for everything except Slack \
        channels and GitHub repositories, which list rather than search.
        """
    }
}
