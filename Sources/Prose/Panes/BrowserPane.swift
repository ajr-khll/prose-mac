//  The browser pane: a real `WKWebView` in a pane body.
//
//  This is the file plan §2 is about. In gpui the plan was to add a sibling
//  `NSView` over the renderer's single Metal view, re-frame it every paint from
//  a canvas element's bounds, flip the Y because gpui does not override
//  `isFlipped`, and accept that it paints above every other element, has no
//  rounded corners or clipping, and steals first responder on click.
//
//  In AppKit a `WKWebView` is just a view, so every one of those costs is zero,
//  and `BrowserPaneTests` measures each of them rather than asserting it.
//
//  What this file started as was deliberately the *unremarkable* version — a
//  representable that hands back a view and nothing else — because proving plan
//  §2's claim needed nothing more. What it is now is the rest of it: a
//  `WKWebView` alone is not a browser, and every one of the gaps read as a hang
//  rather than as something unfinished. A bad address, a failed load, a dead web
//  process, a `target="_blank"` link and a JS dialog all used to produce the same
//  thing — a blank pane and no explanation.
//
//  What plan §2 calls the real prize — `browser.navigate` / `eval` / `snapshot`
//  on the agent protocol — is still **not** here. That decision was deferred, and
//  the parser drops unknown methods, so an agent that sends one today is ignored
//  rather than answered.

import AppKit
import Observation
import ProseCore
import SwiftUI
import WebKit

/// Why what was typed in the URL field could not be turned into a page.
enum AddressFailure: Error, Equatable {
    /// Nothing was typed, which is not worth saying anything about.
    case empty
    /// Not a URL — and prose has no search engine to hand it to instead.
    case notAURL(String)
}

/// One pane's browser: its web view, and the handful of things the pane's
/// chrome needs to read off it.
@MainActor
@Observable
final class BrowserSession {
    let pane: PaneID

    /// What is in the URL field, which is not always what is loaded — the user
    /// may be part way through typing.
    var address = ""

    /// Whether the URL field currently has the keyboard.
    ///
    /// Read by two things that must not fight the user: the field's focus ring,
    /// and the `\.url` observation below, which otherwise overwrites a half
    /// typed address the moment a redirect lands.
    var addressFocused = false

    /// Set when the caret should move into the URL field and there was no view
    /// to move it into. Consumed when the field arrives in a window, the same
    /// fallback `wantsComposerFocus` is for the composer.
    var wantsAddressFocus = false

    /// Puts the caret in this pane's URL field, and says whether it could.
    /// Installed by the field itself; `false` means there is no view in a window
    /// yet, which is what `wantsAddressFocus` is then for.
    @ObservationIgnored var focusAddress: (() -> Bool)?

    /// KVO on `estimatedProgress`, drawn as a hairline under the pane header.
    var progress: Double = 0
    var isLoading = false

    var canGoBack = false
    var canGoForward = false

    /// Nothing has been asked for yet, so the body still shows spec §8's label.
    var hasPage = false

    /// Whether anything has ever actually arrived in this pane.
    ///
    /// Separate from `hasPage` because the two answer different questions and
    /// the gap between them is where the white rectangle lived: a web view that
    /// has been asked for a page but has not received one yet draws WebKit's own
    /// empty white page, and `underPageBackgroundColor` does not govern that —
    /// it governs the rubber-band past a page's edges. So until something
    /// commits, prose covers the view with its own plane, and a load that fails
    /// outright never uncovers it.
    var hasPainted = false

    /// What went wrong, in words, or nil while nothing has.
    ///
    /// Until this existed a failed load left a blank web view and wrote one line
    /// to stderr under `PROSE_FRAME=1`, so a 404, a refused connection and a bad
    /// certificate were indistinguishable from the app having hung. Drawn in
    /// `Palette.noticeText`, which is the colour the transcript gives its own
    /// "something went wrong" block (spec §9.3), so the two read as one kind of
    /// event rather than two.
    var failure: String?

    /// How many navigations have finished in this pane, successfully or not.
    ///
    /// **This is the pane's clock.** A browser pane has no transcript, so a
    /// waiting read has nothing to measure "since" against — and without one,
    /// a wait is edge-triggered and a page that loaded before the wait was
    /// placed hangs the waiter forever. Counting loads gives `pane.read` the
    /// same level-triggered cursor it has for an agent pane: satisfied when
    /// the count has moved past what the caller last saw.
    ///
    /// A failed load increments it too. "The page finished trying" is the
    /// event an agent is waiting for; a counter that only moved on success
    /// would hang on every 404.
    var loads = 0

    /// What the page has said about itself: its console, and the requests it
    /// made. Fed by `PageMonitorHandler`, read by `browser.console` and
    /// `browser.network`.
    ///
    /// **Deliberately not observed.** A page can log in a loop, and an
    /// `@Observable` buffer would invalidate the pane's view on every line —
    /// so this is storage an agent pulls from, never something the window
    /// redraws for.
    @ObservationIgnored private(set) var log = PageLog()

    @ObservationIgnored let webView: PaneWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let navigation = NavigationDelegate()
    @ObservationIgnored private let ui = UIDelegate()
    @ObservationIgnored private let monitor = PageMonitorHandler()

    /// What the page calls itself. Routed to the same setter an agent's
    /// `pane.title` will use, so the header has one way of being named rather
    /// than two.
    @ObservationIgnored var onTitle: ((String?) -> Void)?

    /// A click landed in the page. plan §2 says taking first responder is the
    /// correct behaviour rather than something to fight, so prose leans on it:
    /// the pane focuses *because* the web view was focused.
    @ObservationIgnored var onFocus: (() -> Void)?

    /// A navigation finished, so any read parked on this pane can be answered.
    /// Installed by the workspace, which is the only thing holding the
    /// registry the parked reads live in.
    @ObservationIgnored var onLoad: (() -> Void)?

    /// Escape in the URL field hands the keyboard back to the tab strip, the
    /// same way the composer's does (spec §12). Without it a browser pane was a
    /// one-way trip for the plain arrow keys.
    @ObservationIgnored var onResignToTabStrip: (() -> Void)?

    init(pane: PaneID) {
        self.pane = pane

        let configuration = WKWebViewConfiguration()
        // Per-pane ephemeral sessions, so two panes can be logged into the same
        // site as different users — a genuine product feature for an agent
        // multiplexer (plan §2), and one line.
        configuration.websiteDataStore = .nonPersistent()
        // The ref list an agent acts through, put in before the page's own
        // scripts run and re-injected by WebKit on every navigation — which is
        // what makes a stale ref impossible rather than merely unlikely.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: PageScript.source, injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        // The console and request log, patched into the page before its own
        // code runs — installed after the ref script only because the two are
        // independent, and at document start for the same reason: a console
        // patched later misses the errors thrown during startup, which are
        // the ones worth having.
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: PageMonitor.source, injectionTime: .atDocumentStart,
                forMainFrameOnly: true))
        configuration.userContentController.add(monitor, name: PageMonitor.handlerName)

        webView = PaneWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = navigation
        webView.uiDelegate = ui

        // The page's own plane, for the moment before a page has painted and for
        // the rubber-band past its edges. WebKit's default is white, which
        // flashed on every load against prose's dark translucent window and was
        // the most visible thing wrong with the pane.
        //
        // `pageBase` rather than `paneBG`, and `Palette` says why: WebKit
        // composites this against its own white backing, not against the
        // window, so the pane's 3%-white wash left the flash where it was.
        webView.underPageBackgroundColor = NSColor(Color(Palette.pageBase))

        // Two-finger swipe back and forward. Muscle memory on this platform, and
        // a property rather than a feature to build.
        webView.allowsBackForwardNavigationGestures = true

        // Weakly, and through a mutation rather than a reference: the content
        // controller retains its handlers and the web view retains the
        // controller, so a handler holding this session would be a cycle —
        // and `PageMonitor`'s header is the reason it is handed a `PageLog`
        // to change rather than the session itself.
        monitor.apply = { [weak self] change in
            guard let self else { return }
            change(&self.log)
        }
        // The one thing the page cannot see about itself: a 404 or a 500 on
        // the main document still renders, so the status code has to come
        // from the navigation delegate.
        navigation.didRespond = { [weak self] url, status in
            self?.log.append(
                kind: "document", method: "GET", url: url, status: status, ms: nil,
                error: nil)
        }

        navigation.didSettle = { [weak self] title in
            self?.onTitle?(title?.isEmpty == false ? title : nil)
        }
        navigation.didFail = { [weak self] message in
            self?.failure = message
        }
        navigation.didPaint = { [weak self] in
            self?.hasPainted = true
        }
        navigation.didLoad = { [weak self] in
            guard let self else { return }
            self.loads += 1
            self.onLoad?()
        }
        // A dialog prose answered on the page's behalf is neither a load
        // failure nor nothing, so it goes where the load failures go: into the
        // pane, in words, for whoever comes back to it.
        navigation.didDecline = { [weak self] why in self?.failure = why }
        ui.didDecline = { [weak self] why in self?.failure = why }
        // A web content process that went away leaves the pane showing a corpse.
        // Reloading is the only useful answer, and saying so is the honest one.
        navigation.didDie = { [weak self] in
            self?.failure = "the web content process went away — reloading"
            self?.webView.reload()
        }
        webView.onFocus = { [weak self] in self?.onFocus?() }

        // `estimatedProgress`, `canGoBack` and `canGoForward` are KVO
        // properties on `WKWebView` — the loading hairline and the two history
        // buttons cost an observation each and nothing more.
        observations = [
            webView.observe(\.estimatedProgress, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { self.progress = view.estimatedProgress }
            },
            webView.observe(\.isLoading, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { self.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { self.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.initial, .new]) { view, _ in
                MainActor.assumeIsolated { self.canGoForward = view.canGoForward }
            },
            webView.observe(\.url, options: [.new]) { view, _ in
                MainActor.assumeIsolated {
                    // Not while the user is typing in it. A redirect or a slow
                    // background navigation landing mid-word used to replace
                    // what had been typed so far, which is the field fighting
                    // the person using it.
                    guard !self.addressFocused, let url = view.url else { return }
                    self.address = url.absoluteString
                }
            },
            // plan §2 says the navigation delegate drives the title, and it is
            // *nearly* right: `didFinish` fires before `webView.title` has been
            // populated, so the delegate alone leaves a page called nothing.
            // Measured, not guessed — the title arrives afterwards, so it needs
            // an observation like the rest. The delegate still matters for the
            // failure cases, where there is a title to clear rather than set.
            webView.observe(\.title, options: [.new]) { view, _ in
                MainActor.assumeIsolated {
                    self.onTitle?(view.title?.isEmpty == false ? view.title : nil)
                }
            },
        ]
    }

    /// Loads whatever is in the URL field, or says why it cannot.
    func go() {
        switch Self.resolve(address) {
        case .failure(.empty):
            // An empty field is not a mistake to report back.
            return
        case .failure(.notAURL(let text)):
            // prose has no opinion about search and inventing one is not this
            // step's job — but swallowing the input without a word was worse.
            failure = "\(text) is not a URL, and prose has no search engine"
        case .success(let url):
            failure = nil
            hasPage = true

            if url.isFileURL {
                // WKWebView refuses a file: URL through `load(_:)` — it has to
                // be told which directory the page is allowed to read from.
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: url))
            }
        }
    }

    /// The schemes prose will load straight from the URL field.
    ///
    /// Everything else is treated as a host instead, which fixes two things with
    /// one rule. A URL scheme is a letter followed by letters, digits, `+`, `-`
    /// or `.`, so `localhost:3000` is *indistinguishable* from a scheme — and
    /// the old code, which accepted whatever `URL(string:)` gave a scheme to,
    /// therefore never loaded a dev server on any port. The same rule keeps
    /// `javascript:` and `data:` out of an address bar, where they do not belong.
    private static let loadableSchemes: Set<String> = ["http", "https", "file", "about"]

    static func resolve(_ text: String) -> Result<URL, AddressFailure> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           loadableSchemes.contains(scheme)
        {
            return .success(url)
        }

        // No scheme prose will load, so what was typed is a host and a path.
        let scheme = isLocal(trimmed) ? "http" : "https"
        guard let url = URL(string: "\(scheme)://\(trimmed)"), url.host != nil else {
            return .failure(.notAURL(trimmed))
        }
        return .success(url)
    }

    /// Whether a host is one that is almost certainly being served over plain
    /// HTTP, and so should not be handed a `https://` that cannot complete.
    ///
    /// This matters more here than it would in a general browser: the panes next
    /// to this one hold agents editing a web app, so "point the browser pane at
    /// my dev server" is the first thing anyone does with it.
    private static func isLocal(_ address: String) -> Bool {
        let authority = address.prefix { $0 != "/" }
        let host = authority.prefix { $0 != ":" }.lowercased()

        if host == "localhost" || host == "127.0.0.1" { return true }
        if host.hasSuffix(".local") { return true }
        // A name with no dot but a port is a machine on this network rather than
        // a site: `https://dev:8080` has nowhere to get a certificate from.
        return !host.contains(".") && authority.contains(":")
    }

    /// Hand the keyboard back to the content area.
    ///
    /// Arriving on a page *by keyboard* should not put the caret in the page:
    /// spec §12 gives the plain arrows to the content area for browser panes,
    /// and whatever held the keyboard before — another pane's composer, another
    /// page — has to let go for that to be true. Clicking a page still focuses
    /// it, which is the responder chain doing its own work.
    func releaseKeyboard() {
        webView.window?.makeFirstResponder(nil)
    }

    // MARK: - Driven by an agent (spec §10)

    /// Loads a URL the way the address field would, so an agent and a user end
    /// up going through exactly one path into the page.
    func navigate(to url: String) {
        address = url
        go()
    }

    /// The page's rendered text — `innerText`, not markup, because what an
    /// agent wants is what a reader would see.
    ///
    /// `limit` is in characters and clamps on this side of the wire, so a page
    /// that is megabytes of text costs the asking agent a bounded amount rather
    /// than whatever the page happens to weigh.
    func text(selector: String?, limit: Int?, then answer: @escaping (JSONValue) -> Void) {
        let target = selector.map { "document.querySelector(\($0.javaScriptQuoted))" }
            ?? "document.body"
        // `matched` separately from the text, because the three ways this comes
        // back empty are three different problems and used to be one symptom:
        // a selector that found nothing, a page that has not rendered yet, and
        // an element that genuinely holds no text. An agent told only "" tries
        // all three fixes in turn, every time.
        let script = """
            (() => {
              const node = \(target);
              if (!node) return { matched: false, text: "" };
              return { matched: true, text: node.innerText ?? "" };
            })()
            """
        webView.evaluateJavaScript(script) { [weak self] value, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                var fields: [String: JSONValue] = [
                    "url": .string(self.webView.url?.absoluteString ?? self.address),
                    "title": .string(self.webView.title ?? ""),
                ]
                if let error {
                    fields["text"] = .string("")
                    fields["matched"] = .bool(false)
                    fields["error"] = .string(error.localizedDescription)
                } else {
                    let result = value as? [String: Any]
                    var text = (result?["text"] as? String) ?? ""
                    if let limit, text.count > limit {
                        text = String(text.prefix(limit))
                        fields["truncated"] = .bool(true)
                    }
                    fields["text"] = .string(text)
                    fields["matched"] = .bool((result?["matched"] as? Bool) ?? false)
                }
                answer(.object(fields))
            }
        }
    }

    /// Runs a script and hands back whatever it evaluated to. A value that is
    /// not representable as JSON comes back as `null` — see `JSONValue(any:)`.
    func evaluate(_ script: String, then answer: @escaping (JSONValue) -> Void) {
        webView.evaluateJavaScript(script) { value, error in
            MainActor.assumeIsolated {
                // A throw is reported, not flattened to `null`. This used to
                // answer `.null` either way on the grounds that a throw is not
                // a failure *of the pane* — true, but it leaves the one caller
                // that matters unable to tell a broken script from a value
                // that is genuinely null, which is a debugging loop with no
                // exit.
                guard let error else {
                    answer(JSONValue(any: value))
                    return
                }
                answer(.object(["error": .string(error.localizedDescription)]))
            }
        }
    }

    /// Writes a PNG and hands back its path.
    ///
    /// **Never the bytes.** A pane-sized screenshot is around 1,500 tokens once
    /// base64-encoded, every call, on a line-delimited wire — so an agent reads
    /// the file only once it has decided the page's *appearance* is the
    /// question, rather than paying for that on the off chance.
    func snapshot(to path: String?, then answer: @escaping (JSONValue) -> Void) {
        let destination =
            path
            ?? FileManager.default.temporaryDirectory
                .appendingPathComponent("prose-snapshot-\(UUID().uuidString).png").path

        webView.takeSnapshot(with: nil) { image, _ in
            MainActor.assumeIsolated {
                guard let image,
                      let data = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: data),
                      let png = bitmap.representation(using: .png, properties: [:]),
                      (try? png.write(to: URL(fileURLWithPath: destination))) != nil
                else {
                    answer(.object(["error": .string("could not take a snapshot")]))
                    return
                }
                answer(.object(["path": .string(destination)]))
            }
        }
    }

    /// The interactive elements, numbered, with their roles and the names a
    /// person would read off the screen.
    ///
    /// Reach for this before `browser_text` when the question is what to *do*
    /// with a page: it is around two hundred tokens against a screenshot's
    /// fifteen hundred, and unlike either a screenshot or the rendered text it
    /// can be acted on directly.
    ///
    /// With `waitFor` or `timeoutMs`, it waits for the page to settle before
    /// listing — see `PageScript.settle`. That pairing is deliberate: the
    /// reason an agent waits on a page is almost always that it is about to
    /// act on it again, so the wait and the list it needs afterwards are one
    /// call rather than two, and a poll is never the cheaper option.
    func elements(
        limit: Int?, waitFor: String? = nil, timeoutMs: Int? = nil,
        then answer: @escaping (JSONValue) -> Void
    ) {
        let cap = max(1, limit ?? 200)
        guard waitFor != nil || timeoutMs != nil else {
            run(PageScript.call("scan(\(cap))"), then: answer)
            return
        }

        var arguments: [String: Any] = ["timeout": timeoutMs ?? 10_000, "cap": cap]
        // WebKit will not marshal a Swift `nil`, and the script distinguishes
        // "wait for this text" from "wait for quiet" by null.
        arguments["expect"] = waitFor ?? NSNull()

        webView.callAsyncJavaScript(
            PageScript.awaitingScan, arguments: arguments, in: nil, in: .page
        ) { result in
            MainActor.assumeIsolated {
                switch result {
                case .success(let value): answer(JSONValue(any: value))
                case .failure(let error):
                    answer(.object(["error": .string(error.localizedDescription)]))
                }
            }
        }
    }

    /// The interactive elements whose name or link target contains `text`.
    ///
    /// The answer to a long page. An article with nine hundred links answers
    /// `elements` with two hundred lines of site chrome, none of them the one
    /// that was wanted — which is the most reliable way there is to make an
    /// agent give up on refs and write a script instead.
    func find(text: String, limit: Int?, then answer: @escaping (JSONValue) -> Void) {
        run(
            PageScript.call("find(\(text.javaScriptQuoted), \(max(1, limit ?? 40)))"),
            then: answer)
    }

    func click(ref: String, then answer: @escaping (JSONValue) -> Void) {
        run(PageScript.call("click(\(ref.javaScriptQuoted))"), then: answer)
    }

    func select(ref: String, option: String, then answer: @escaping (JSONValue) -> Void) {
        run(
            PageScript.call("select(\(ref.javaScriptQuoted), \(option.javaScriptQuoted))"),
            then: answer)
    }

    func key(ref: String?, key: String, then answer: @escaping (JSONValue) -> Void) {
        let target = ref.map(\.javaScriptQuoted) ?? "null"
        run(PageScript.call("key(\(target), \(key.javaScriptQuoted))"), then: answer)
    }

    func type(
        ref: String, text: String, enter: Bool, then answer: @escaping (JSONValue) -> Void
    ) {
        run(
            PageScript.call(
                "type(\(ref.javaScriptQuoted), \(text.javaScriptQuoted), \(enter))"),
            then: answer)
    }

    func scroll(
        ref: String?, to: String?, by: Int? = nil,
        then answer: @escaping (JSONValue) -> Void
    ) {
        let target = ref.map(\.javaScriptQuoted) ?? "null"
        let amount = by.map(String.init) ?? "null"
        run(
            PageScript.call("scroll(\(target), \(to?.javaScriptQuoted ?? "null"), \(amount))"),
            then: answer)
    }

    /// Runs one of the page script's calls and answers with what it returned.
    ///
    /// Unlike `evaluate`, a thrown script here is an **error rather than a
    /// null**: these scripts are prose's own, so a throw is a defect worth
    /// seeing rather than a value worth reporting.
    private func run(_ script: String, then answer: @escaping (JSONValue) -> Void) {
        webView.evaluateJavaScript(script) { value, error in
            MainActor.assumeIsolated {
                if let error {
                    answer(.object(["error": .string(error.localizedDescription)]))
                    return
                }
                answer(JSONValue(any: value))
            }
        }
    }

    /// What the page has printed since `since`, at `level` or worse.
    ///
    /// Synchronous, unlike every other call on this side of the pane: the
    /// entries are already here. Nothing has to be asked of the web content
    /// process, which is the point — a pilot checking whether a page is
    /// broken should not pay a round trip to find out.
    func console(since: Int, level: ConsoleLevel, limit: Int) -> JSONValue {
        log.console(since: since, level: level, limit: limit)
    }

    /// The requests the page has made since `since`, or only the failed ones.
    func network(since: Int, failuresOnly: Bool, limit: Int) -> JSONValue {
        log.network(since: since, failuresOnly: failuresOnly, limit: limit)
    }

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }

    /// Back and forward for an agent, which unlike the toolbar has to be told
    /// when there was nowhere to go.
    ///
    /// Worth being tools at all because the alternative is not
    /// `browser_navigate` — an agent does not necessarily know the URL it came
    /// from — it is `browser_eval("history.back()")`, which is the fallback
    /// this whole pass exists to remove.
    func step(back: Bool, then answer: @escaping (JSONValue) -> Void) {
        guard back ? webView.canGoBack : webView.canGoForward else {
            answer(
                .object([
                    "ok": .bool(false),
                    "error": .string(
                        back ? "nothing to go back to" : "nothing to go forward to"),
                ]))
            return
        }
        if back { webView.goBack() } else { webView.goForward() }
        // The navigation has only started. `prose_wait(until: ["loaded"])` is
        // what says it finished, exactly as after `browser_navigate`.
        answer(.object(["ok": .bool(true), "navigating": .bool(true)]))
    }

    /// Reload, or abandon a load in progress — one button, because which of the
    /// two is wanted is never ambiguous: it is whichever one `isLoading` is not.
    func reloadOrStop() {
        if isLoading {
            webView.stopLoading()
        } else {
            webView.reload()
        }
    }
}

/// The web view itself.
///
/// Two overrides, and both of them are plan §2's claims made concrete rather
/// than worked around.
final class PaneWebView: WKWebView {
    /// How many times AppKit has resized any web view in this process.
    ///
    /// gpui's plan required re-framing the native view from a canvas element's
    /// bounds *every paint*. This counter exists so the claim that AppKit does
    /// not can be checked: it should move when the window or a divider moves
    /// and stay perfectly still otherwise.
    nonisolated(unsafe) static var frameChanges = 0

    var onFocus: (() -> Void)?

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        Self.frameChanges += 1
    }

    /// Clicking a page takes first responder, which is correct: the caret and
    /// the keyboard belong to the page now. The pane wants to know, so it can
    /// become the focused pane at the same time — that is the responder chain
    /// doing the work, not prose fighting it.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }
}

/// Forwards the navigation lifecycle. A separate object because `@Observable`
/// and `NSObject` conformance do not need to be the same class.
@MainActor
private final class NavigationDelegate: NSObject, WKNavigationDelegate {
    var didSettle: ((String?) -> Void)?
    /// A load that did not happen, in words — or nil to say one did.
    var didFail: ((String?) -> Void)?
    /// Something the page asked for that was answered without asking the user,
    /// because the pane was not on screen to ask on.
    var didDecline: ((String) -> Void)?
    /// Something arrived, so there is a page worth showing.
    var didPaint: (() -> Void)?
    /// The web content process went away.
    var didDie: (() -> Void)?
    /// The main document's URL and HTTP status.
    ///
    /// The only part of the network the page cannot report on itself: a 404
    /// or a 500 arrives with a body and renders like any other page, so
    /// without this a pilot reading a server's error page has no way to know
    /// that is what it is looking at.
    var didRespond: ((String, Int) -> Void)?
    /// One navigation reached its end, successfully or not.
    ///
    /// Deliberately **not** fired from `didCommit`: the body's text is not
    /// there yet at commit, which is exactly the gap the forty-iteration poll
    /// in `echo_agent.browse` was working around. A waiter woken at commit
    /// would read an empty page and be no better off.
    var didLoad: (() -> Void)?

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        // Something arrived, so whatever went wrong last time no longer has.
        didFail?(nil)
        didPaint?()
        didSettle?(webView.title)
    }

    /// Always allows, and only listens on the way past.
    ///
    /// Implementing this at all changes nothing about what loads — `.allow`
    /// is what WebKit does when the method is absent — but it is the one
    /// place the main document's status code is visible.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
    ) {
        if navigationResponse.isForMainFrame,
           let http = navigationResponse.response as? HTTPURLResponse
        {
            didRespond?(http.url?.absoluteString ?? "", http.statusCode)
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The page usually names itself somewhere between commit and finish, so
        // the header is asked again once it has settled.
        didSettle?(webView.title)
        didLoad?()
    }

    func webView(
        _ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error
    ) {
        report(error)
        didSettle?(nil)
        // A failure ends the navigation as surely as a success does. A waiter
        // that only woke on success would hang on every 404 and every dead
        // host, which is the case it is most needed for.
        didLoad?()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: any Error
    ) {
        report(error)
        didSettle?(nil)
        didLoad?()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        didDie?()
    }

    /// A server asking who you are.
    ///
    /// WebKit's documented behaviour when this method is *not* implemented is to
    /// reject the protection space outright, so an HTTP basic-auth page — a
    /// staging server, a router, a local tool — was one more blank pane with no
    /// explanation.
    ///
    /// Server **trust** is deliberately not answered here. Accepting a
    /// certificate prose could not verify would make the address bar a lie, so a
    /// bad or self-signed certificate falls through to the default handling and
    /// fails the navigation. What changed for that case is the other half: the
    /// failure is now words in the pane rather than a line on stderr, so the
    /// user is told the certificate is the reason instead of seeing nothing.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (
            URLSession.AuthChallengeDisposition, URLCredential?
        ) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        guard method == NSURLAuthenticationMethodHTTPBasic
            || method == NSURLAuthenticationMethodHTTPDigest
            || method == NSURLAuthenticationMethodNTLM
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // A second prompt for the same realm means the first answer was wrong,
        // which is worth saying rather than asking again identically.
        let realm = challenge.protectionSpace.realm ?? challenge.protectionSpace.host
        let retry = challenge.previousFailureCount > 0

        CredentialPrompt.ask(
            realm: realm, retry: retry, over: webView,
            declined: { [weak self] why in self?.didDecline?(why) }
        ) { credential in
            guard let credential else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            completionHandler(.useCredential, credential)
        }
    }

    /// A page that fails to load says so **in the pane**, and also on stderr
    /// under `PROSE_FRAME=1` — the probe harness reads failures without a screen
    /// (`BrowserProbe`), so both paths are wanted rather than one replacing the
    /// other.
    private func report(_ error: any Error) {
        // A load the user themselves interrupted is not a failure to report.
        let cocoa = error as NSError
        guard !(cocoa.domain == NSURLErrorDomain && cocoa.code == NSURLErrorCancelled) else {
            didFail?(nil)
            return
        }

        didFail?(cocoa.localizedDescription)
        guard ProcessInfo.processInfo.environment["PROSE_FRAME"] == "1" else { return }
        FileHandle.standardError.write(Data("PROSE_NAV_ERROR \(error)\n".utf8))
    }
}

/// Where a page's dialog can be put, if anywhere.
///
/// A page runs whether or not anyone is looking at it: the panes of a tab that
/// is not on screen are torn down, so their web views are in no window, while
/// their pages keep loading, keep running script and keep asking for things.
/// The old answer to that was `runModal()`, which let a page nobody could see
/// stop every pane in the app — including the one being typed in — with a
/// dialog that did not say which pane it came from.
///
/// So a dialog with nowhere to go is declined on the page's behalf and reported
/// into its own pane, where the user finds it when they come back to it.
enum PageDialog {
    /// On the pane's own window, which is the only surface prose has for one.
    case sheet(NSWindow)
    /// Answered without being shown, and what to tell the pane.
    case declined(String)

    /// `asking` completes "this page asked …", so it reads as one sentence in
    /// the pane: "asked to show a message", "asked for a sign-in".
    @MainActor
    static func venue(over webView: WKWebView, asking: String) -> PageDialog {
        guard let window = webView.window else {
            return .declined("this page asked \(asking) while its pane was hidden, so prose said no")
        }
        return .sheet(window)
    }
}

/// Asking for a username and a password, because a server did.
enum CredentialPrompt {
    @MainActor
    static func ask(
        realm: String, retry: Bool, over webView: WKWebView,
        declined: @escaping @MainActor (String) -> Void,
        then finish: @escaping @MainActor (URLCredential?) -> Void
    ) {
        let window: NSWindow
        switch PageDialog.venue(over: webView, asking: "for a sign-in") {
        case .sheet(let pane):
            window = pane
        case .declined(let why):
            // Cancelling fails the navigation, which is the honest outcome: the
            // page cannot be fetched without credentials nobody was asked for.
            declined(why)
            finish(nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = retry ? "That was not accepted by \(realm)" : "\(realm) wants a sign-in"
        alert.informativeText = "Kept only for this pane's session, like everything else it stores."
        alert.addButton(withTitle: "Sign In")
        alert.addButton(withTitle: "Cancel")

        let user = NSTextField(frame: NSRect(x: 0, y: 26, width: 260, height: 22))
        user.placeholderString = "Username"
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        password.placeholderString = "Password"

        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 48))
        fields.addSubview(user)
        fields.addSubview(password)
        alert.accessoryView = fields

        let answer: @MainActor (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else {
                finish(nil)
                return
            }
            finish(
                URLCredential(
                    user: user.stringValue, password: password.stringValue, persistence: .forSession
                )
            )
        }

        alert.beginSheetModal(for: window, completionHandler: answer)
    }
}

/// The page asking prose for something: a new window, a dialog, a file.
///
/// A `WKWebView` with no `WKUIDelegate` answers every one of these by doing
/// nothing at all, which is why a `target="_blank"` link read as the app having
/// hung. None of what is below is clever; it is the default that should have
/// been there.
@MainActor
private final class UIDelegate: NSObject, WKUIDelegate {
    /// A dialog answered without being shown, and why — see `PageDialog`.
    var didDecline: ((String) -> Void)?

    /// A page asking for a new window gets this one.
    ///
    /// A pane *is* the window here, so there is nowhere else to put it, and the
    /// alternative — returning nil, which is what happens with no delegate —
    /// drops the navigation silently. Opening a fresh pane for it is the fancier
    /// answer and can wait until an agent can ask for a pane.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable () -> Void
    ) {
        let alert = Self.alert(message)
        alert.addButton(withTitle: "OK")
        present(alert, over: webView, asking: "to show a message") { _ in completionHandler() }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        let alert = Self.alert(message)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        // Declined reads as Cancel, which is the answer a page gets from a user
        // who closes a dialog without choosing.
        present(alert, over: webView, asking: "a yes-or-no question") {
            completionHandler($0 == .alertFirstButtonReturn)
        }
    }

    func webView(
        _ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?, initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable (String?) -> Void
    ) {
        let alert = Self.alert(prompt)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field

        present(alert, over: webView, asking: "for some text") { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(
        _ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping @MainActor @Sendable ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection

        switch PageDialog.venue(over: webView, asking: "for a file") {
        case .sheet(let window):
            panel.beginSheetModal(for: window) { response in
                completionHandler(response == .OK ? panel.urls : nil)
            }
        case .declined(let why):
            didDecline?(why)
            completionHandler(nil)
        }
    }

    /// A page's dialog, named as one.
    ///
    /// The page's own text is the *informative* half rather than the heading, so
    /// a page cannot dress its message up as something prose is saying.
    private static func alert(_ message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = "The page says:"
        alert.informativeText = message
        return alert
    }

    /// As a sheet on the pane's window, or not at all.
    ///
    /// A sheet is window-modal and prose has exactly one window, so a dialog
    /// from a pane on screen does hold up the panes beside it until it is
    /// answered. That is the price of answering a page honestly, and it is
    /// bounded by a click. What it must never be is a page nobody can see doing
    /// it — see `PageDialog`, which is where that is decided.
    private func present(
        _ alert: NSAlert, over webView: WKWebView, asking: String,
        then finish: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        switch PageDialog.venue(over: webView, asking: asking) {
        case .sheet(let window):
            alert.beginSheetModal(for: window, completionHandler: finish)
        case .declined(let why):
            didDecline?(why)
            // The second button is Cancel wherever there are two; an alert has
            // only OK and ignores the response entirely.
            finish(.alertSecondButtonReturn)
        }
    }
}

/// An ordinary child view.
///
/// This is the whole of plan §2's headline: no re-framing, no Y flip, no
/// z-order special case, no clipping workaround. `makeNSView` hands back the
/// view the session already owns, so navigating does not rebuild it.
///
/// `updateNSView` has one job, and it is the job every other representable in
/// this app has: re-apply the value that depends on the zoom. Prose scales every
/// dimension it draws through `Metrics`, and a page that stayed at 1× while its
/// own pane's chrome grew was the zoom visibly failing to reach the content.
struct WebViewHost: NSViewRepresentable {
    let session: BrowserSession
    let zoom: Double

    func makeNSView(context: Context) -> PaneWebView { session.webView }

    func updateNSView(_ view: PaneWebView, context: Context) {
        view.pageZoom = zoom
    }
}

/// A browser pane's body: the URL field, anything that went wrong, then the page.
struct BrowserPaneBody: View {
    let session: BrowserSession

    @Environment(\.metrics) private var m

    var body: some View {
        VStack(spacing: 0) {
            AddressField(session: session, metrics: m)
                .frame(height: AddressField.height(at: m.px(.textSize)))
                .padding(.horizontal, m.px(.addressPaddingX))
                .padding(.vertical, m.px(.addressPaddingY))
                .background(
                    RoundedRectangle(cornerRadius: m.px(.addressRadius))
                        .fill(Color(Palette.addressBG))
                        .overlay(
                            RoundedRectangle(cornerRadius: m.px(.addressRadius))
                                .strokeBorder(
                                    Color(
                                        session.addressFocused
                                            ? Palette.addressBorderActive : Palette.addressBorder
                                    ),
                                    lineWidth: m.px(.addressBorder)
                                )
                        )
                )
                .padding(m.px(.transcriptPadding))

            if let failure = session.failure {
                // One line, in the colour the transcript gives a notice, so a
                // browser failure and an agent's read as the same kind of event.
                Text(failure)
                    .font(m.font(.secondaryTextSize))
                    .foregroundStyle(Color(Palette.noticeText))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, m.px(.transcriptPadding))
                    .padding(.bottom, m.px(.transcriptPadding))
            }

            if session.hasPage {
                WebViewHost(session: session, zoom: m.zoom)
                    // Covered until a page commits, and *stays* covered if the
                    // load fails — the failure above is then the only thing in
                    // the pane, rather than a line of orange text over a white
                    // rectangle. The view itself is hosted the whole time:
                    // WebKit needs to be in a window to make progress, so this
                    // hides it rather than withholding it.
                    .overlay {
                        if !session.hasPainted {
                            Color(Palette.pageBase)
                                // It hides the page; it must never take a click
                                // away from it. Without this the cover claims
                                // the pointer for as long as a load lasts, and
                                // a page that never commits is unreachable for
                                // good — the web view only becomes first
                                // responder if a click gets through to it, and
                                // that is what makes a page typeable at all.
                                .allowsHitTesting(false)
                        }
                    }
            } else {
                // spec §8's label, kept: a pane that has been asked for nothing
                // has nothing to show.
                Text(PaneKind.browser.placeholder)
                    .font(m.font(.textSize))
                    .foregroundStyle(Color(Palette.panePlaceholder))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}
