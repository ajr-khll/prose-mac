import Foundation
import Testing

@testable import ProseCore
@testable import ProseIntegrations

/// The broker's refusals, which are the part that has to be right before any
/// of it touches a network. Everything here runs with no connection, no
/// Keychain item and no provider.
@Suite("The broker refuses before it reaches anything")
struct IntegrationBrokerTests {
    private func broker() -> IntegrationBroker {
        // A temporary store per test, so nothing here can see or disturb the
        // real Application Support file.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prose-tests-\(UUID().uuidString)")
        return IntegrationBroker(
            connections: ConnectionStore(directory: directory),
            openURL: { _ in Issue.record("no sign-in should start here") })
    }

    @Test("a provider the pane does not hold is refused")
    func providerOutsideTheSet() async throws {
        await #expect(throws: IntegrationBroker.Failure.self) {
            try await broker().call(
                operation: "capabilities",
                providers: ["github", "notion"],
                arguments: .object(["provider": .string("slack")]))
        }
    }

    @Test("a provider prose does not broker at all is refused first")
    func providerNobodyBrokers() async throws {
        await #expect(throws: IntegrationBroker.Failure.self) {
            try await broker().call(
                operation: "connections",
                providers: ["jira"],
                arguments: .null)
        }
    }

    @Test("an unknown operation is refused rather than ignored")
    func unknownOperation() async throws {
        await #expect(throws: IntegrationBroker.Failure.self) {
            try await broker().call(
                operation: "execute", providers: ["slack"], arguments: .null)
        }
    }

    @Test("a ref borrowed from another provider cannot be read")
    func refFromAnotherProvider() async throws {
        // `apps_get` takes a ref, not a provider, so the prefix is the only
        // thing standing between a pane and a resource it may not reach.
        await #expect(throws: IntegrationBroker.Failure.self) {
            try await broker().call(
                operation: "get",
                providers: ["github"],
                arguments: .object(["ref": .string("slack:work:message:1")]))
        }
    }

    @Test("listing says which providers are not connected, and why")
    func notConnectedIsNotEmpty() async throws {
        // An empty list cannot be told from "no results", and the two need
        // completely different behaviour from an agent.
        let answer = try await broker().call(
            operation: "connections",
            providers: ["slack", "google", "linear"],
            arguments: .null)

        #expect(answer["connections"]?.array?.isEmpty == true)
        #expect(answer["not_connected"]?.stringArray?.sorted()
            == ["google", "linear", "slack"])
        #expect(answer["hint"]?.string?.contains("not connected") == true)
    }

    @Test("a capability nobody built is named as unavailable, not offered")
    func unbuiltCapabilitiesAreNamed() async throws {
        // Advertising an operation the broker would refuse is the same failure
        // as an archetype naming a tool that does not exist. Reads are built;
        // writes are not, and they are named rather than quietly missing.
        let described = ProviderCapabilities.describe("linear")
        #expect(described["operations"]?.array?.isEmpty == true)
        #expect(described["unavailable"]?.stringArray?.contains("issue.update") == true)
        #expect(described["kinds"]?.stringArray?.contains("issue") == true)
    }
}

@Suite("Reading maps a provider onto one shape")
struct ProviderReadTests {
    @Test("a ref names its connection, so one cannot be read against another")
    func refsCarryTheirConnection() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prose-tests-\(UUID().uuidString)")
        let store = ConnectionStore(directory: directory)
        try await store.save(Connection(id: "github_a", provider: "github",
                                        account: "acme", scopes: []))
        let broker = IntegrationBroker(connections: store, openURL: { _ in })

        // The connection exists and the provider is held, so the only thing
        // that can refuse this is the mismatched connection segment.
        await #expect(throws: IntegrationBroker.Failure.self) {
            try await broker.call(
                operation: "get", providers: ["github"],
                arguments: .object(["ref": .string("github:someone_else:issue:a/b#1")]))
        }
    }

    @Test("a ref with the wrong number of segments is refused, not guessed at")
    func malformedRef() async throws {
        let connection = Connection(id: "c", provider: "github",
                                    account: "a", scopes: [])
        await #expect(throws: IntegrationBroker.Failure.self) {
            try await ProviderReads.get(provider: "github", connection: connection,
                                        token: "t", ref: "github:c:issue")
        }
    }

    @Test("a long body comes back cut, with its real length")
    func bodiesAreBounded() {
        // The point of a connector pane is that the raw material stays in it.
        let long = String(repeating: "x", count: 5000)
        let bounded = ProviderRequests.bounded(long)
        #expect(bounded.count < long.count)
        #expect(bounded.contains("5000 characters in full"))

        let short = "a thread"
        #expect(ProviderRequests.bounded(short) == short)
    }

    @Test("Notion's title is hunted rather than read from a fixed key")
    func notionTitles() {
        // A database row and a page put it under different property names.
        let page: [String: Any] = [
            "properties": ["Name": ["title": [["plain_text": "Runbook"]]]],
        ]
        #expect(ProviderReads.notionTitle(page) == "Runbook")
        #expect(ProviderReads.notionTitle(["id": "abc"]) == "abc")
    }

    @Test("a Notion block yields its text whatever kind it is")
    func notionBlocks() {
        let paragraph: [String: Any] = [
            "type": "paragraph",
            "paragraph": ["rich_text": [["plain_text": "hello"]]],
        ]
        #expect(ProviderReads.notionText(paragraph) == "hello")
        // A divider has no text, and must not become an empty line.
        #expect(ProviderReads.notionText(["type": "divider", "divider": [:]]) == nil)
    }

    @Test("reads are offered and writes are named as unavailable")
    func capabilitiesMatchWhatIsBuilt() {
        // Advertising a capability the broker would refuse is the same failure
        // as an archetype naming a tool that does not exist.
        for provider in Provider.known {
            let described = ProviderCapabilities.describe(provider)
            let unavailable = described["unavailable"]?.stringArray ?? []
            #expect(!unavailable.contains("search"), "\(provider) still hides search")
            #expect(!unavailable.contains("get"))
            #expect(!unavailable.isEmpty, "\(provider) claims writes work")
            #expect(described["notes"]?.string?.contains("Reading") == true)
        }
    }
}

@Suite("The two sides agree about which providers exist")
struct ProviderCatalogueTests {
    @Test("Swift's catalogue matches the Python surface")
    func catalogueMatchesPython() throws {
        // A provider in one list and not the other is a tool that exists and
        // can never succeed. The Python side is the one an archetype's
        // `integrations:` line is validated against.
        let python = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("agents/prose_agent/apps.py"),
            encoding: .utf8)

        guard let line = python.split(separator: "\n")
            .first(where: { $0.hasPrefix("PROVIDERS = ") })
        else {
            Issue.record("apps.py no longer declares PROVIDERS")
            return
        }
        let declared = line
            .replacingOccurrences(of: "PROVIDERS = (", with: "")
            .replacingOccurrences(of: ")", with: "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty }

        #expect(declared.sorted() == Provider.known)
    }

    @Test("every provider asks for narrow scopes and knows its account field")
    func scopesAndAccountPaths() {
        for id in Provider.known {
            let provider = Provider.catalogue[id]!
            #expect(!provider.accountNamePath.isEmpty, "\(id) cannot name its account")
            // Notion is the one with no scope model — a person picks pages
            // during consent instead — so it is allowed an empty list.
            if id != "notion" {
                #expect(!provider.scopes.isEmpty, "\(id) asks for no scopes")
            }
        }
    }

    @Test("an account name falls back rather than coming back empty")
    func accountNameFallback() {
        let slack = Provider.catalogue["slack"]!
        #expect(slack.accountName(from: ["team": ["name": "Acme"]]) == "Acme")
        #expect(slack.accountName(from: [:]) == "Slack")
    }
}

@Suite("PKCE and the loopback redirect")
struct OAuthTests {
    @Test("the challenge is the SHA-256 of the verifier, base64url")
    func challengeIsCorrect() {
        // The canonical example from RFC 7636 appendix B.
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        #expect(OAuthFlow.challenge(for: verifier)
            == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("a verifier is long enough and URL-safe")
    func verifierShape() {
        let verifier = OAuthFlow.randomURLSafe(64)
        #expect(verifier.count >= 43)
        #expect(!verifier.contains("+"))
        #expect(!verifier.contains("/"))
        #expect(!verifier.contains("="))
    }

    @Test("the redirect query is read off the request line")
    func parsesRedirect() {
        let parsed = LoopbackListener.parse(
            requestLine: "GET /callback?code=abc&state=xyz HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
        #expect(parsed.code == "abc")
        #expect(parsed.state == "xyz")
        #expect(parsed.error == nil)
    }

    @Test("a denial carries the provider's own description")
    func parsesDenial() {
        // "access_denied" alone tells a person nothing they can act on.
        let parsed = LoopbackListener.parse(
            requestLine: "GET /callback?error=access_denied&error_description=User%20said%20no HTTP/1.1\r\n")
        #expect(parsed.code == nil)
        #expect(parsed.error?.contains("access_denied") == true)
        #expect(parsed.error?.contains("User said no") == true)
    }

    @Test("the page says what happened either way")
    func redirectPage() {
        let good = LoopbackListener.page(for: .init(code: "c", state: "s", error: nil))
        #expect(good.contains("Connected"))
        #expect(good.contains("close this tab"))

        let bad = LoopbackListener.page(for: .init(code: nil, state: "s", error: "nope"))
        #expect(bad.contains("Sign-in failed"))
        #expect(bad.contains("nope"))
    }

    @Test("form encoding escapes what a secret can contain")
    func formEncoding() {
        let encoded = OAuthFlow.formEncoded(["a": "x y+z/w", "b": "1"])
        #expect(encoded == "a=x%20y%2Bz%2Fw&b=1")
    }
}

@Suite("Connections keep their secret out of the file")
struct ConnectionStoreTests {
    private func store() -> ConnectionStore {
        ConnectionStore(directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prose-tests-\(UUID().uuidString)"))
    }

    @Test("a saved connection comes back, and survives a reload")
    func roundTrip() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prose-tests-\(UUID().uuidString)")
        let first = ConnectionStore(directory: directory)
        try await first.save(Connection(
            id: "slack_a1", provider: "slack", account: "Acme",
            scopes: ["channels:read"]))

        let reloaded = ConnectionStore(directory: directory)
        let rows = await reloaded.all()
        #expect(rows.count == 1)
        #expect(rows.first?.account == "Acme")
    }

    @Test("the Codable shape has nowhere to put a token")
    func noSecretsInTheFile() throws {
        // The guarantee is structural, not a habit: a screenshot of this file,
        // a backup of it or a crash report containing it holds no credential.
        let encoded = try JSONEncoder.prose.encode(Connection(
            id: "slack_a1", provider: "slack", account: "Acme", scopes: ["x"]))
        let text = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!text.lowercased().contains("token"))
        #expect(!text.lowercased().contains("secret"))
    }

    @Test("the keychain account is derived, so the halves cannot disagree")
    func keychainAccountIsDerived() {
        let connection = Connection(
            id: "slack_a1", provider: "slack", account: "Acme", scopes: [])
        #expect(connection.keychainAccount == "slack:slack_a1")
    }

    @Test("a token about to expire counts as expired")
    func expiryHasMargin() {
        // The call that uses it still has to cross a network.
        let soon = Keychain.Token(
            accessToken: "x", expiresAt: Date().addingTimeInterval(30))
        #expect(soon.isExpired)

        let fine = Keychain.Token(
            accessToken: "x", expiresAt: Date().addingTimeInterval(3600))
        #expect(!fine.isExpired)

        // No expiry at all means the provider issues non-expiring tokens.
        #expect(!Keychain.Token(accessToken: "x").isExpired)
    }

    @Test("filtering by provider is what a pane's set means")
    func filtersByProvider() async throws {
        let store = store()
        try await store.save(Connection(id: "slack_a", provider: "slack",
                                        account: "A", scopes: []))
        try await store.save(Connection(id: "github_b", provider: "github",
                                        account: "B", scopes: []))

        let workflow = await store.all(forProviders: ["slack", "google", "linear"])
        #expect(workflow.map(\.id) == ["slack_a"])
    }
}
