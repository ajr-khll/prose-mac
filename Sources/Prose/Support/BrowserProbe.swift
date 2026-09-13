//  Checking plan §2's claims instead of asserting them.
//
//  plan §2 is the port's headline: it says that putting a `WKWebView` in a pane
//  costs nothing in AppKit, where in gpui it cost re-framing every paint, a Y
//  flip, broken z-order, no clipping and a first-responder fight. That is a load
//  of claims to take on trust, and if any of them is wrong the rationale for the
//  whole port is weaker than written.
//
//  So `PROSE_PROBE=1` walks the real view and layer tree a few seconds after
//  launch and prints what it finds. It is a measurement affordance like
//  PROSE_FRAME and PROSE_ZOOM_STEP, and it exists because three of the four
//  claims are properties of the hierarchy rather than of the pixels — which
//  means they can be checked without a screen.

import AppKit
import WebKit

enum BrowserProbe {
    /// Prints what the web view's place in the hierarchy actually is.
    @MainActor
    static func run(_ webView: WKWebView, paneTop: CGFloat, headerHeight: CGFloat) {
        func say(_ line: String) {
            print("PROBE \(line)")
            fflush(stdout)
        }

        guard let window = webView.window else {
            say("FAIL web view is not in a window")
            return
        }

        // 1. Geometry. The frame is in window coordinates, so it can be checked
        //    against where the tiling put the pane.
        let frame = webView.convert(webView.bounds, to: nil)
        let topFromWindowTop = window.frame.height - frame.maxY
        say("webview frame in window: \(frame)")
        say("webview top, measured from the window's top: \(topFromWindowTop)")
        say(
            topFromWindowTop >= paneTop + headerHeight
                ? "PASS header is not covered: the page starts below it"
                : "FAIL the page overlaps the pane header"
        )

        // 2. Clipping. SwiftUI's `.clipShape` becomes a mask on a layer above
        //    the web view; gpui could not clip a native overlay at all.
        var clipped = false
        var view: NSView? = webView
        var depth = 0
        while let current = view, depth < 12 {
            let layer = current.layer
            let mask = layer?.mask != nil
            let masks = layer?.masksToBounds ?? false
            let radius = layer?.cornerRadius ?? 0
            if mask || masks || radius > 0 { clipped = true }
            say(
                "  ancestor \(depth) \(type(of: current)) mask=\(mask) masksToBounds=\(masks) cornerRadius=\(radius)"
            )
            view = current.superview
            depth += 1
        }
        say(
            clipped
                ? "PASS an ancestor layer clips the page"
                : "FAIL nothing in the chain clips the page"
        )

        // 3. Z-order. A native overlay in gpui painted above every element prose
        //    drew. Here the web view is an ordinary subview, so it has siblings
        //    and a position among them.
        if let parent = webView.superview {
            let index = parent.subviews.firstIndex(of: webView).map(String.init) ?? "?"
            say("z-order: subview \(index) of \(parent.subviews.count) in \(type(of: parent))")
        }

        // 4. Whether it is flipped, which is what forced gpui's Y flip.
        say("isFlipped: \(webView.isFlipped) — parent \(webView.superview?.isFlipped ?? false)")

        // 5. Who actually has the keyboard.
        //
        //    `PROSE_FOCUS_WEB=1` drives the responder path a click would, and
        //    the interesting part is what holds first responder *after* the
        //    workspace has reacted to it. It reacted by taking the keyboard
        //    straight back once, which made the page impossible to type into,
        //    and that is not visible in any of the geometry above.
        if let responder = window.firstResponder as? NSView {
            let holds = responder === webView || responder.isDescendant(of: webView)
            say(
                holds
                    ? "PASS the page holds the keyboard"
                    : "FAIL first responder is \(type(of: responder)), not the page"
            )
        } else {
            say("first responder: \(String(describing: window.firstResponder))")
        }

        say("title: \(webView.title ?? "nil")")
        say("frameChanges so far: \(PaneWebView.frameChanges)")
    }

    /// Renders the window's AppKit tree to a PNG without going through the
    /// display, so there is *something* to look at when the screen is locked
    /// and `screencapture` cannot run. Web content is drawn out of process and
    /// may well not appear; that is worth knowing either way.
    @MainActor
    static func snapshot(_ window: NSWindow, to path: String) {
        guard let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
        print("PROBE wrote \(path)")
        fflush(stdout)
    }
}
