//  What the page says about itself: its console, and the requests it makes.
//
//  `issues §3` named this the next thing to build, and the reason is a single
//  question a pilot could not previously answer: **is this site broken, or is
//  my selector wrong?** Both look identical from outside — a click that
//  changed nothing, a list that never arrived — and an agent that cannot tell
//  them apart retries the wrong half forever. The console and the network are
//  where the difference is written down.
//
//  `WKWebView` gives neither for free. There is no console API and no request
//  log, so both have to be collected *inside* the page and posted out, which
//  is `issues §4`'s `WKScriptMessageHandler` — built here because this is the
//  first thing that needs it.
//
//  # The page is not allowed to speak as prose
//
//  `issues §4` says the security requirement is the whole design rather than a
//  footnote: a page that could emit a raw `event` could forge a `turn` or a
//  `status` and write into a transcript the user reads as the agent's. So the
//  channel is built so that saying those things is not *possible* rather than
//  not permitted:
//
//  - The handler's only output is a `PageLog` entry. It holds no session, no
//    registry and no transcript, and there is no path from a `PageLog` into
//    `HostEvent` — the page's words can only ever come back as the answer to a
//    `browser.console` or `browser.network` call an agent made on purpose.
//  - Every field is re-read and re-typed on this side. A message is a
//    dictionary of whatever the page felt like sending; what survives is a
//    level from a fixed set, a string clamped to `Limits.text`, and integers.
//    Nothing is forwarded as it arrived.
//  - An unrecognised `kind` is dropped. Adding a new one is a decision made
//    here, not something a page can do by sending it.
//
//  # Why the requests are collected in the page rather than at the delegate
//
//  `WKNavigationDelegate` sees the main document and nothing else — no image,
//  no stylesheet, and in particular no `fetch`, which is where an application
//  actually breaks. Patching `fetch` and `XMLHttpRequest` sees exactly the
//  traffic the page's own code started, which is the traffic worth a line.
//  The main document's status code is the one thing the page cannot observe
//  (a 500 still renders), so that one *does* come from the delegate — see
//  `BrowserSession`'s `didRespond`.

import Foundation
import ProseCore
import WebKit

/// One line the page printed.
struct ConsoleEntry: Equatable {
    let seq: Int
    let level: ConsoleLevel
    let text: String
    /// `file:line`, when the page gave one. Uncaught errors do; `console.log`
    /// does not.
    let at: String?
}

/// How bad a console line claims to be.
///
/// Ranked rather than free-form because the whole point of the filter is to
/// let a pilot ask for "warnings and worse" — which is the default, because a
/// chatty page's `console.log` is the single largest pile of tokens in this
/// file and almost never the answer.
enum ConsoleLevel: String, Comparable, CaseIterable {
    case log
    case info
    case warn
    case error

    var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// One request the page made, once it finished.
struct NetworkEntry: Equatable {
    let seq: Int
    /// `fetch`, `xhr`, `resource` — an image or script the page failed to load
    /// — or `document`, the main frame's own response.
    let kind: String
    let method: String
    let url: String
    /// Absent when the request never got a response at all, which is a
    /// different fact from a response that was a 500.
    let status: Int?
    let ms: Int?
    /// Set when it failed, in whatever words the page had.
    let error: String?

    /// Whether this is one of the entries a pilot asking for trouble wants.
    ///
    /// A request with no status did not complete; a 4xx or 5xx completed and
    /// said no. Both are failures to a reader, so `failures_only` covers both
    /// rather than making an agent know the difference before it can ask.
    var failed: Bool {
        if error != nil { return true }
        guard let status else { return true }
        return status >= 400
    }
}

/// Everything one pane's page has said, bounded.
///
/// Two ring buffers with a cursor each, which is the same shape `pane.read`
/// gives a transcript and for the same reason: an agent calls this repeatedly
/// while it works, and a reply that repeats what it already read costs tokens
/// to no purpose. `since` is exclusive, and the reply carries the cursor to
/// pass next time.
///
/// **Overflow is reported, never hidden.** A page that logs in a loop will
/// push older lines out; a reader that is told `dropped: 40` knows it is
/// looking at a window, while one silently handed the tail believes it has
/// seen everything. That difference is the whole reason for `oldest`.
struct PageLog {
    /// How many of each to keep. Bounded because a page can log without end,
    /// and generous because the interesting line is usually the first one — a
    /// buffer too small loses the original error and keeps its consequences.
    static let capacity = 250

    /// How much of one message to keep. A minified stack trace is thousands of
    /// characters and its first line is the part anybody reads.
    static let textLimit = 400

    private(set) var console: [ConsoleEntry] = []
    private(set) var network: [NetworkEntry] = []

    /// Next sequence number per buffer. Never reset — not even by a
    /// navigation, because a cursor an agent is holding must not start
    /// matching entries again after a page load.
    private var nextConsole = 1
    private var nextNetwork = 1

    mutating func append(level: ConsoleLevel, text: String, at: String?) {
        console.append(
            ConsoleEntry(
                seq: nextConsole, level: level, text: String(text.prefix(Self.textLimit)),
                at: at.map { String($0.prefix(Self.textLimit)) }))
        nextConsole += 1
        if console.count > Self.capacity { console.removeFirst(console.count - Self.capacity) }
    }

    mutating func append(
        kind: String, method: String, url: String, status: Int?, ms: Int?, error: String?
    ) {
        network.append(
            NetworkEntry(
                seq: nextNetwork, kind: kind, method: method,
                url: String(url.prefix(Self.textLimit)), status: status, ms: ms,
                error: error.map { String($0.prefix(Self.textLimit)) }))
        nextNetwork += 1
        if network.count > Self.capacity { network.removeFirst(network.count - Self.capacity) }
    }

    /// The console lines after `since` at `level` or worse, newest last.
    ///
    /// `limit` keeps the **newest** matches rather than the oldest: a reader
    /// asking mid-errand wants what just happened. The cursor is therefore the
    /// last entry's, and anything skipped to honour the limit is counted into
    /// `dropped` alongside what the ring lost, so the two ways of missing a
    /// line read the same to whoever gets the reply.
    func console(since: Int, level: ConsoleLevel, limit: Int) -> JSONValue {
        let matching = console.filter { $0.seq > since && $0.level >= level }
        let kept = Array(matching.suffix(max(1, limit)))

        var fields: [String: JSONValue] = [
            "entries": .array(
                kept.map { entry in
                    var line: [String: JSONValue] = [
                        "seq": .int(Int64(entry.seq)),
                        "level": .string(entry.level.rawValue),
                        "text": .string(entry.text),
                    ]
                    if let at = entry.at { line["at"] = .string(at) }
                    return .object(line)
                })
        ]
        fields["cursor"] = .int(Int64(kept.last?.seq ?? since))
        let missed = lost(console, since: since) + (matching.count - kept.count)
        if missed > 0 { fields["dropped"] = .int(Int64(missed)) }
        return .object(fields)
    }

    /// The requests after `since`, optionally only the ones that went wrong.
    func network(since: Int, failuresOnly: Bool, limit: Int) -> JSONValue {
        let matching = network.filter { $0.seq > since && (!failuresOnly || $0.failed) }
        let kept = Array(matching.suffix(max(1, limit)))

        var fields: [String: JSONValue] = [
            "entries": .array(
                kept.map { entry in
                    var line: [String: JSONValue] = [
                        "seq": .int(Int64(entry.seq)),
                        "kind": .string(entry.kind),
                        "method": .string(entry.method),
                        "url": .string(entry.url),
                    ]
                    if let status = entry.status { line["status"] = .int(Int64(status)) }
                    if let ms = entry.ms { line["ms"] = .int(Int64(ms)) }
                    if let error = entry.error { line["error"] = .string(error) }
                    return .object(line)
                })
        ]
        fields["cursor"] = .int(Int64(kept.last?.seq ?? since))
        let missed = lost(network, since: since) + (matching.count - kept.count)
        if missed > 0 { fields["dropped"] = .int(Int64(missed)) }
        return .object(fields)
    }

    /// How many entries between the caller's cursor and the oldest one still
    /// held were pushed out of the ring.
    private func lost(_ entries: [ConsoleEntry], since: Int) -> Int {
        guard let oldest = entries.first else { return 0 }
        return max(0, oldest.seq - since - 1)
    }

    private func lost(_ entries: [NetworkEntry], since: Int) -> Int {
        guard let oldest = entries.first else { return 0 }
        return max(0, oldest.seq - since - 1)
    }
}

/// The script that makes a page report itself.
///
/// Injected at document start so that it is in place before the page's own
/// code runs — a console patch installed afterwards misses exactly the errors
/// that happen during startup, which are the ones worth having.
enum PageMonitor {
    /// The handler name the page posts to. Distinct from the ref script's
    /// `window.__prose`, because these are two unrelated pieces of machinery
    /// that happen to share a page.
    static let handlerName = "proseMonitor"

    static let source = #"""
    (() => {
      if (window.__proseMonitor) return;
      window.__proseMonitor = true;

      const CAP = 400;

      // A dictionary with no undefined members: WebKit marshals a missing key
      // as an absent one and an `undefined` value as null, and the Swift side
      // distinguishes "no status" from "status 0".
      const clean = (fields) => {
        const out = {};
        for (const key in fields) {
          if (fields[key] !== undefined && fields[key] !== null) out[key] = fields[key];
        }
        return out;
      };

      const post = (fields) => {
        try {
          window.webkit.messageHandlers.proseMonitor.postMessage(clean(fields));
        } catch (e) {
          // A frame with no handler attached. Nothing to do and nowhere to
          // say it — reporting a reporting failure to the console we are
          // patching is a loop.
        }
      };

      const render = (value) => {
        if (typeof value === 'string') return value;
        if (value instanceof Error) {
          // The message goes in front of the stack rather than being left to
          // it. JavaScriptCore's `stack` is **frames only** — unlike V8's it
          // does not repeat the message — so `stack || name + message` threw
          // away the one part of an error anybody reads, on every page.
          const head = value.name + ': ' + value.message;
          return value.stack ? head + '\n' + value.stack : head;
        }
        try { return JSON.stringify(value); } catch (e) { return String(value); }
      };
      const join = (args) => Array.from(args).map(render).join(' ').slice(0, CAP);

      // `debug` is folded into `log`: the distinction matters to a developer
      // reading a devtools pane and not to an agent deciding whether a page
      // is broken.
      const LEVELS = { log: 'log', debug: 'log', info: 'info', warn: 'warn', error: 'error' };
      for (const name in LEVELS) {
        const original = console[name];
        if (typeof original !== 'function') continue;
        console[name] = function (...args) {
          post({ kind: 'console', level: LEVELS[name], text: join(args) });
          return original.apply(this, args);
        };
      }

      // Capture phase, because a failed <img> or <script> fires an `error`
      // event that does not bubble — the one place where listening on window
      // without capture silently sees nothing.
      window.addEventListener('error', (event) => {
        const target = event.target;
        if (target && target !== window && target.tagName) {
          const url = target.src || target.href;
          if (url) {
            post({
              kind: 'network', type: 'resource', method: 'GET', url: String(url),
              error: target.tagName.toLowerCase() + ' failed to load',
            });
          }
          return;
        }
        post({
          kind: 'console', level: 'error',
          text: String(event.message || 'uncaught error').slice(0, CAP),
          at: event.filename ? event.filename + ':' + event.lineno : undefined,
        });
      }, true);

      window.addEventListener('unhandledrejection', (event) => {
        post({
          kind: 'console', level: 'error',
          text: ('unhandled rejection: ' + render(event.reason)).slice(0, CAP),
        });
      });

      const absolute = (url) => {
        try { return new URL(url, document.baseURI).href; } catch (e) { return String(url); }
      };

      const fetch0 = window.fetch;
      if (typeof fetch0 === 'function') {
        window.fetch = function (input, init) {
          const started = Date.now();
          const url = absolute(
            typeof input === 'string' ? input : (input && input.url) || '');
          const method = String(
            (init && init.method) || (input && input.method) || 'GET').toUpperCase();
          return fetch0.apply(this, arguments).then((response) => {
            post({
              kind: 'network', type: 'fetch', method, url,
              status: response.status, ms: Date.now() - started,
            });
            return response;
          }, (error) => {
            // A rejected fetch has no status at all, which is what tells a
            // reader the request never reached anything.
            post({
              kind: 'network', type: 'fetch', method, url, ms: Date.now() - started,
              error: String((error && error.message) || error),
            });
            throw error;
          });
        };
      }

      const open0 = XMLHttpRequest.prototype.open;
      const send0 = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__proseNote = {
          method: String(method || 'GET').toUpperCase(), url: absolute(url),
        };
        return open0.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function () {
        const note = this.__proseNote;
        if (note) {
          const started = Date.now();
          // `loadend` rather than `load`, because it is the one event that
          // fires for a success, an abort and a network error alike.
          this.addEventListener('loadend', () => {
            post({
              kind: 'network', type: 'xhr', method: note.method, url: note.url,
              status: this.status || undefined, ms: Date.now() - started,
              error: this.status ? undefined : 'no response',
            });
          });
        }
        return send0.apply(this, arguments);
      };
    })();
    """#
}

/// Receives what the page posts, and turns it into log entries or nothing.
///
/// A separate object for the same reason the navigation delegate is one: the
/// session is `@Observable` and this has to be an `NSObject`. It holds the
/// session weakly through a closure, because `WKUserContentController` retains
/// its handlers and the controller belongs to the web view the session owns.
@MainActor
final class PageMonitorHandler: NSObject, WKScriptMessageHandler {
    /// Called with a mutation to apply. Deliberately not given the session
    /// itself — see this file's header.
    var apply: ((@escaping (inout PageLog) -> Void) -> Void)?

    func userContentController(
        _ controller: WKUserContentController, didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any] else { return }

        // An unknown `kind` is dropped rather than guessed at. This switch is
        // the whole list of things a page is able to make prose do.
        switch body["kind"] as? String {
        case "console":
            let level = ConsoleLevel(rawValue: body["level"] as? String ?? "") ?? .log
            let text = body["text"] as? String ?? ""
            let at = body["at"] as? String
            guard !text.isEmpty else { return }
            apply? { $0.append(level: level, text: text, at: at) }

        case "network":
            guard let url = body["url"] as? String, !url.isEmpty else { return }
            let kind = body["type"] as? String ?? "fetch"
            let method = body["method"] as? String ?? "GET"
            let status = (body["status"] as? NSNumber).map(\.intValue)
            let ms = (body["ms"] as? NSNumber).map(\.intValue)
            let error = body["error"] as? String
            apply? {
                $0.append(
                    kind: kind, method: method, url: url, status: status, ms: ms, error: error)
            }

        default:
            return
        }
    }
}
