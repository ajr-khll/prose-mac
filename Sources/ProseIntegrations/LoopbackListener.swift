import Foundation
import Network

/// A one-shot HTTP listener on `127.0.0.1`, which is where the browser tab
/// comes back to.
///
/// Deliberately tiny and deliberately not a web server. It accepts one
/// connection, reads one request line, answers with one page and stops. It
/// speaks just enough HTTP to satisfy a browser following a redirect, because
/// anything more is a network-facing surface running inside a desktop app for
/// the ninety seconds a sign-in takes.
///
/// Bound to the loopback interface only, so nothing off the machine can reach
/// it, and to port 0 so the OS picks a free one — a fixed port would collide
/// with a second prose, and worse, would let another local process squat it
/// between sign-ins. The consequence is that the redirect URI changes every
/// time, which most providers allow for loopback precisely because of this.
final class LoopbackListener: @unchecked Sendable {
    struct Redirect: Sendable {
        var code: String?
        var state: String?
        var error: String?
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "prose.oauth.loopback")
    private var continuation: CheckedContinuation<Redirect, Error>?
    private var finished = false
    private let lock = NSLock()

    let port: UInt16

    var redirectURI: String { "http://127.0.0.1:\(port)/callback" }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = false

        listener = try NWListener(using: parameters, on: .any)
        listener.start(queue: queue)

        // `NWListener` assigns the port asynchronously. Waiting is ugly but the
        // alternative is handing out a redirect URI before we know it, and the
        // wait is microseconds in practice.
        var waited = 0
        while listener.port?.rawValue == nil, waited < 2000 {
            usleep(1000)
            waited += 1
        }
        guard let assigned = listener.port?.rawValue else {
            listener.cancel()
            throw OAuthFlow.Failure.listenerFailed("no port was assigned")
        }
        port = assigned
    }

    func waitForRedirect(timeout: Duration) async throws -> Redirect {
        let waiting = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Redirect, Error>) in
                lock.lock()
                self.continuation = continuation
                lock.unlock()

                listener.newConnectionHandler = { [weak self] connection in
                    self?.handle(connection)
                }
            }
        }

        // A person who opens the tab and then goes to lunch must not leave a
        // listener bound forever, and the pane that asked is parked on this.
        let deadline = Task {
            try await Task.sleep(for: timeout)
            self.finish(.failure(OAuthFlow.Failure.deniedByUser(
                "the sign-in was not completed in time")))
        }
        defer { deadline.cancel() }

        return try await waiting.value
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) {
            [weak self] data, _, _, _ in
            guard let self else { return }
            let request = String(data: data ?? Data(), encoding: .utf8) ?? ""
            let redirect = Self.parse(requestLine: request)

            let body = Self.page(for: redirect)
            let response = """
                HTTP/1.1 200 OK\r
                Content-Type: text/html; charset=utf-8\r
                Content-Length: \(body.utf8.count)\r
                Connection: close\r
                \r
                \(body)
                """
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
            self.finish(.success(redirect))
        }
    }

    /// Pulls the query off `GET /callback?code=…&state=… HTTP/1.1`.
    static func parse(requestLine request: String) -> Redirect {
        guard let line = request.split(separator: "\r\n").first,
              let path = line.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://127.0.0.1\(path)")
        else { return Redirect(code: nil, state: nil, error: "malformed redirect") }

        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value
        }
        // `error_description` is the one a person can act on; `error` alone is
        // often just `access_denied`.
        let error = value("error").map { code in
            value("error_description").map { "\(code): \($0)" } ?? code
        }
        return Redirect(code: value("code"), state: value("state"), error: error)
    }

    /// What the tab shows. Plain, self-contained, and it says to come back to
    /// prose — a blank page leaves a person wondering whether it worked.
    static func page(for redirect: Redirect) -> String {
        let worked = redirect.error == nil && redirect.code != nil
        let heading = worked ? "Connected" : "Sign-in failed"
        let detail = worked
            ? "You can close this tab and go back to prose."
            : (redirect.error ?? "No authorization code came back.")
        return """
            <!doctype html><meta charset="utf-8">
            <title>prose — \(heading)</title>
            <style>
              body { font: 15px -apple-system, system-ui, sans-serif;
                     display: grid; place-content: center; height: 100vh;
                     margin: 0; text-align: center; color: #1d1d1f;
                     background: #f5f5f7; }
              @media (prefers-color-scheme: dark) {
                body { color: #f5f5f7; background: #1d1d1f; }
              }
              h1 { font-size: 17px; font-weight: 600; margin: 0 0 6px; }
              p { margin: 0; opacity: .7; max-width: 32em; }
            </style>
            <h1>\(heading)</h1>
            <p>\(detail)</p>
            """
    }

    private func finish(_ outcome: Result<Redirect, Error>) {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return }
        finished = true
        self.continuation = nil
        lock.unlock()
        continuation.resume(with: outcome)
    }

    func stop() {
        listener.cancel()
    }
}
