import CryptoKit
import Foundation

/// Signing in: a tab in the person's own browser, and a loopback listener
/// waiting for the redirect.
///
/// **Why the system browser and not a window we draw.** Google explicitly
/// rejects embedded webviews for OAuth and documents the installed-app flow as
/// system-browser-plus-loopback; Slack and GitHub tolerate a webview but the
/// reason not to use one holds anyway. In the person's own browser they can
/// see the address bar, they are already signed in, their password manager
/// works, and their second factor works. In a webview we drew, they are typing
/// a workspace password into a window whose provenance they cannot check, and
/// we could read it.
///
/// **Why PKCE always.** The loopback redirect is a URL any local process can
/// race us to listen on, so an authorization code alone is not enough to trust.
/// The verifier never leaves this process, so a code intercepted on the way
/// back cannot be exchanged by whoever intercepted it.
public struct OAuthFlow: Sendable {
    public struct Request: Sendable {
        public var provider: String
        public var authorizeURL: URL
        public var tokenURL: URL
        public var clientID: String
        public var clientSecret: String?
        public var scopes: [String]
        /// Providers differ on whether extra authorize parameters are needed —
        /// Google wants `access_type=offline` to issue a refresh token at all,
        /// Slack distinguishes user from bot scopes. Kept as a dictionary so a
        /// provider slice can say so without this file knowing about it.
        public var extraAuthorizeParameters: [String: String]

        public init(
            provider: String, authorizeURL: URL, tokenURL: URL, clientID: String,
            clientSecret: String? = nil, scopes: [String],
            extraAuthorizeParameters: [String: String] = [:]
        ) {
            self.provider = provider
            self.authorizeURL = authorizeURL
            self.tokenURL = tokenURL
            self.clientID = clientID
            self.clientSecret = clientSecret
            self.scopes = scopes
            self.extraAuthorizeParameters = extraAuthorizeParameters
        }
    }

    public enum Failure: Error, LocalizedError {
        case noClientRegistration(String)
        case listenerFailed(String)
        case deniedByUser(String)
        case stateMismatch
        case exchangeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .noClientRegistration(let provider):
                return """
                    \(provider) has no app registration yet. Register an OAuth \
                    app with \(provider), then add its client ID in \
                    Connections — prose ships no shared client secret on \
                    purpose, so every install is its own identity and its own \
                    revocation.
                    """
            case .listenerFailed(let why):
                return "could not listen for the redirect: \(why)"
            case .deniedByUser(let why):
                return "sign-in was declined: \(why)"
            case .stateMismatch:
                // Either a stale tab from an earlier attempt or somebody else
                // hitting the loopback port. Both are refusals, not retries.
                return "the redirect did not match this sign-in attempt"
            case .exchangeFailed(let why):
                return "the provider refused the authorization code: \(why)"
            }
        }
    }

    /// One completed sign-in: what to store, and what to call the account.
    public struct Outcome: Sendable {
        public var token: Keychain.Token
        /// The token response as it arrived, kept as bytes rather than as a
        /// parsed dictionary so this stays `Sendable` — `[String: Any]` is
        /// not, and the only reader is `Provider.accountName(from:)`, which
        /// knows where its own provider hides the workspace name.
        public var rawResponse: Data

        public init(token: Keychain.Token, rawResponse: Data) {
            self.token = token
            self.rawResponse = rawResponse
        }
    }

    public init() {}

    /// Runs the whole dance: listen, open the tab, wait, exchange.
    ///
    /// `openURL` is injected rather than calling `NSWorkspace` directly, which
    /// keeps this target free of AppKit and lets a test drive the flow without
    /// a browser opening on somebody's screen.
    public func run(
        _ request: Request,
        openURL: @Sendable (URL) -> Void,
        timeout: Duration = .seconds(300)
    ) async throws -> Outcome {
        let verifier = Self.randomURLSafe(64)
        let challenge = Self.challenge(for: verifier)
        let state = Self.randomURLSafe(32)

        let listener = try LoopbackListener()
        defer { listener.stop() }
        let redirect = listener.redirectURI

        var components = URLComponents(url: request.authorizeURL,
                                       resolvingAgainstBaseURL: false)!
        var query = components.queryItems ?? []
        query += [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: request.clientID),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        if !request.scopes.isEmpty {
            query.append(.init(name: "scope", value: request.scopes.joined(separator: " ")))
        }
        for (key, value) in request.extraAuthorizeParameters.sorted(by: { $0.key < $1.key }) {
            query.append(.init(name: key, value: value))
        }
        components.queryItems = query

        openURL(components.url!)

        let redirected = try await listener.waitForRedirect(timeout: timeout)
        guard redirected.state == state else { throw Failure.stateMismatch }
        if let error = redirected.error { throw Failure.deniedByUser(error) }
        guard let code = redirected.code else {
            throw Failure.deniedByUser("no authorization code came back")
        }

        return try await exchange(request, code: code, verifier: verifier,
                                  redirectURI: redirect)
    }

    private func exchange(
        _ request: Request, code: String, verifier: String, redirectURI: String
    ) async throws -> Outcome {
        var form: [String: String] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirectURI,
            "client_id": request.clientID,
            "code_verifier": verifier,
        ]
        // Present only for providers that require a confidential client. With
        // PKCE the public-client flow is preferred, and a secret sitting in a
        // desktop app is not really a secret.
        if let secret = request.clientSecret { form["client_secret"] = secret }

        var post = URLRequest(url: request.tokenURL)
        post.httpMethod = "POST"
        post.setValue("application/x-www-form-urlencoded",
                      forHTTPHeaderField: "Content-Type")
        post.setValue("application/json", forHTTPHeaderField: "Accept")
        post.httpBody = Self.formEncoded(form).data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: post)
        guard let http = response as? HTTPURLResponse else {
            throw Failure.exchangeFailed("no response")
        }
        let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard http.statusCode == 200, parsed["error"] == nil else {
            // The provider's own message, not ours: "bad_redirect_uri" tells a
            // person what to fix and "sign-in failed" does not.
            let why = (parsed["error_description"] as? String)
                ?? (parsed["error"] as? String)
                ?? "HTTP \(http.statusCode)"
            throw Failure.exchangeFailed(why)
        }
        guard let access = parsed["access_token"] as? String else {
            throw Failure.exchangeFailed("no access token in the response")
        }

        let expiry = (parsed["expires_in"] as? Double).map {
            Date().addingTimeInterval($0)
        }
        let granted = (parsed["scope"] as? String)?
            .split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init) ?? request.scopes

        return Outcome(
            token: Keychain.Token(
                accessToken: access,
                refreshToken: parsed["refresh_token"] as? String,
                expiresAt: expiry,
                scopes: granted),
            rawResponse: data)
    }

    // MARK: - PKCE

    static func randomURLSafe(_ bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return Data(buffer).base64URLEncoded
    }

    static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncoded
    }

    static func formEncoded(_ fields: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return fields.sorted { $0.key < $1.key }.map { key, value in
            let safe = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
            return "\(key)=\(safe)"
        }.joined(separator: "&")
    }
}

extension Data {
    /// base64url, which is what PKCE and JWTs use: no padding, and two
    /// characters swapped so the value survives being put in a URL.
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
