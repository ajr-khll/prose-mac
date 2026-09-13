import ProseCore
import Testing

@testable import Prose

/// The cursor and the bound, without a page.
///
/// `PageLog` is the part of the console and network surface that is pure —
/// what gets kept, what gets filtered, what the cursor comes back as, and
/// what an agent is told it missed. None of it needs a `WKWebView`, so none
/// of these tests take one; the ones that do live in `BrowserPaneTests`,
/// which is serialized because a real web view has to be.
@Suite("Page log")
struct PageLogTests {
    /// Reaches into the reply the way an agent would.
    private func entries(_ value: JSONValue) -> [JSONValue] {
        value["entries"]?.array ?? []
    }

    private func texts(_ value: JSONValue) -> [String] {
        entries(value).compactMap { $0["text"]?.string }
    }

    private func cursor(_ value: JSONValue) -> Int {
        Int(value["cursor"]?.int ?? -1)
    }

    @Test("the default level hides the chatter and keeps the trouble")
    func levelIsAFloor() {
        var log = PageLog()
        log.append(level: .log, text: "render 1", at: nil)
        log.append(level: .info, text: "connected", at: nil)
        log.append(level: .warn, text: "deprecated", at: nil)
        log.append(level: .error, text: "boom", at: nil)

        // The default a pilot gets, and the reason for it: a page's own
        // `console.log` is the largest pile of tokens available and almost
        // never the answer.
        #expect(texts(log.console(since: 0, level: .warn, limit: 50)) == ["deprecated", "boom"])
        #expect(texts(log.console(since: 0, level: .error, limit: 50)) == ["boom"])
        #expect(texts(log.console(since: 0, level: .log, limit: 50)).count == 4)
    }

    @Test("a threaded cursor returns only what is new")
    func cursorThreads() {
        var log = PageLog()
        log.append(level: .error, text: "first", at: nil)

        let one = log.console(since: 0, level: .warn, limit: 50)
        #expect(texts(one) == ["first"])

        // Nothing has happened, so the same cursor comes back empty rather
        // than repeating the line — which is the whole reason an agent can
        // afford to check this between every action.
        let again = log.console(since: cursor(one), level: .warn, limit: 50)
        #expect(texts(again).isEmpty)
        #expect(cursor(again) == cursor(one))

        log.append(level: .error, text: "second", at: nil)
        #expect(texts(log.console(since: cursor(one), level: .warn, limit: 50)) == ["second"])
    }

    @Test("a cursor moves past lines the filter rejected")
    func cursorDoesNotStall() {
        // The bug this guards: if the cursor only advanced to the last
        // *returned* entry, a page logging steadily at `log` while erroring
        // once would make every later call re-examine the whole backlog.
        var log = PageLog()
        log.append(level: .error, text: "seen", at: nil)
        let first = log.console(since: 0, level: .warn, limit: 50)

        for i in 0..<20 { log.append(level: .log, text: "noise \(i)", at: nil) }
        log.append(level: .error, text: "new", at: nil)

        let second = log.console(since: cursor(first), level: .warn, limit: 50)
        #expect(texts(second) == ["new"])
        #expect(cursor(second) == 22, "the cursor is the entry's own sequence, not a count")
    }

    @Test("a limit keeps the newest, and says how many it dropped")
    func limitKeepsTheNewest() {
        var log = PageLog()
        for i in 1...10 { log.append(level: .error, text: "e\(i)", at: nil) }

        let reply = log.console(since: 0, level: .warn, limit: 3)
        // Newest, because a reader asking mid-errand wants what just
        // happened — and told about the rest rather than left to assume it
        // has seen everything.
        #expect(texts(reply) == ["e8", "e9", "e10"])
        #expect(reply["dropped"]?.int == 7)
        #expect(cursor(reply) == 10)
    }

    @Test("what the ring pushed out is counted, not hidden")
    func overflowIsReported() {
        var log = PageLog()
        for i in 1...(PageLog.capacity + 30) { log.append(level: .error, text: "e\(i)", at: nil) }

        #expect(log.console.count == PageLog.capacity, "the buffer stays bounded")

        let reply = log.console(since: 0, level: .warn, limit: 1000)
        #expect(reply["dropped"]?.int == 30)
        // And a reader already past the discarded ones is not told it missed
        // anything, because it did not.
        let caughtUp = log.console(since: 40, level: .warn, limit: 1000)
        #expect(caughtUp["dropped"] == nil)
    }

    @Test("a long message is clamped rather than sent whole")
    func textIsClamped() {
        var log = PageLog()
        log.append(level: .error, text: String(repeating: "x", count: 5_000), at: nil)
        let text = texts(log.console(since: 0, level: .warn, limit: 1))[0]
        #expect(text.count == PageLog.textLimit, "a minified stack trace is not worth 5k tokens")
    }

    @Test("failures_only covers both ways a request goes wrong")
    func failuresAreBothKinds() {
        var log = PageLog()
        log.append(kind: "fetch", method: "GET", url: "/ok", status: 200, ms: 4, error: nil)
        log.append(kind: "fetch", method: "GET", url: "/gone", status: 404, ms: 3, error: nil)
        log.append(kind: "fetch", method: "POST", url: "/dead", status: nil, ms: 2, error: "refused")
        log.append(kind: "document", method: "GET", url: "/", status: 500, ms: nil, error: nil)

        let all = log.network(since: 0, failuresOnly: false, limit: 50)
        #expect(entries(all).count == 4)

        // A 404 answered and a request that never arrived are different
        // facts, and a pilot asking "what went wrong" wants both.
        let bad = log.network(since: 0, failuresOnly: true, limit: 50)
        let urls = entries(bad).compactMap { $0["url"]?.string }
        #expect(urls == ["/gone", "/dead", "/"])
    }

    @Test("a request with no response carries no status at all")
    func absentStatusIsAbsent() {
        var log = PageLog()
        log.append(kind: "fetch", method: "GET", url: "/dead", status: nil, ms: 1, error: "refused")

        let entry = entries(log.network(since: 0, failuresOnly: false, limit: 1))[0]
        // Not zero, and not null: the key is missing, so "never reached
        // anything" cannot be misread as "answered 0".
        #expect(entry["status"] == nil)
        #expect(entry["error"]?.string == "refused")
    }

    @Test("the two buffers keep separate cursors")
    func cursorsAreIndependent() {
        // They are handed to different tools and threaded separately, so a
        // shared counter would make one tool's cursor skip the other's
        // entries — silently, and only on a busy page.
        var log = PageLog()
        log.append(level: .error, text: "one", at: nil)
        log.append(kind: "fetch", method: "GET", url: "/a", status: 200, ms: 1, error: nil)
        log.append(level: .error, text: "two", at: nil)

        #expect(cursor(log.console(since: 0, level: .warn, limit: 50)) == 2)
        #expect(cursor(log.network(since: 0, failuresOnly: false, limit: 50)) == 1)
    }
}
