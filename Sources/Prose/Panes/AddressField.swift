//  A browser pane's URL field.
//
//  This started as a bare SwiftUI `TextField`, and the two things wrong with
//  that were the two things the composer had already solved next door. It drew
//  the *system* caret and the *system* selection highlight, both of which are
//  green — and `Palette`'s first rule is that one accent means one thing and
//  nothing else in the app is ever green. And it had no way to give the keyboard
//  back: the composer's Escape hands the plain arrow keys to the tab strip
//  (spec §12), and a browser pane was a one-way trip without it.
//
//  So it is an `NSTextView` shaped like a field, for the same reason
//  `Composer` is one. Most of what is below is the composer's answer applied to
//  a single line; where the two genuinely differ — wrapping, Enter, what Escape
//  means — the difference carries a note.

import AppKit
import ProseCore
import SwiftUI

/// The text view itself.
final class AddressTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    var caretWidth: CGFloat = Points.caretWidth.value
    var caretColor: NSColor = NSColor(Color(Palette.caret))

    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var placeholderColor = NSColor(Color(Palette.addressPlaceholder)) {
        didSet { needsDisplay = true }
    }

    /// Drawn by the text view rather than laid over it, for the reason spelled
    /// out at length in `ComposerTextView.draw(_:)`: an overlay and AppKit each
    /// decide where the first character goes and they do not agree, so the
    /// placeholder lands where the typed text will not.
    var placeholderOrigin: NSPoint {
        var origin = textContainerOrigin
        origin.x += textContainer?.lineFragmentPadding ?? 0
        return origin
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard string.isEmpty, !placeholder.isEmpty else { return }
        (placeholder as NSString).draw(
            at: placeholderOrigin,
            withAttributes: [
                .font: font ?? .systemFont(ofSize: Points.textSize.value),
                .foregroundColor: placeholderColor,
            ]
        )
    }

    /// Enter loads, Escape leaves.
    ///
    /// Matched by *selector* rather than by reading modifier flags, the way the
    /// composer does it — AppKit has already decided what the key means by the
    /// time it gets here.
    override func doCommand(by selector: Selector) {
        if selector == #selector(insertNewline(_:)) {
            onSubmit?()
            return
        }
        super.doCommand(by: selector)
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    /// A 1.5pt filled bar in prose's accent, and it does not blink — the same
    /// caret the composer draws, for the same reason.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var wide = rect
        wide.size.width = caretWidth
        super.drawInsertionPoint(in: wide, color: caretColor, turnedOn: flag)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(false)
    }

    override func didChangeText() {
        super.didChangeText()
        // The placeholder appears and disappears with the first and last
        // character, and neither is a layout change AppKit would redraw for.
        needsDisplay = true
    }

    /// Called when this view arrives in a window — see the composer's.
    var onEnterWindow: (() -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onEnterWindow?() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocusChange?(true) }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onFocusChange?(false) }
        return resigned
    }
}

/// Puts the URL field in SwiftUI.
struct AddressField: NSViewRepresentable {
    let session: BrowserSession
    let metrics: Metrics

    /// How tall one line of the field's font is.
    ///
    /// Deliberately the composer's answer rather than a second one: it is the
    /// same question about the same font, and two answers can disagree.
    static func height(at size: CGFloat) -> CGFloat {
        Composer.lineHeight(at: size)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1, matching the composer — and here because a field that
        // scrolls sideways needs a container that does not track the view's
        // width, which is a thing to say to a layout manager.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(
            size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        )
        // The one real difference from the composer: a URL does not wrap. It
        // runs off the end of the field and the field scrolls to follow the
        // caret, which is what every address bar does and what makes a long URL
        // editable at all in 26pt of height.
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)

        let view = AddressTextView(frame: .zero, textContainer: container)
        view.delegate = context.coordinator
        view.isRichText = false
        view.isEditable = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = false
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )

        // spec §9.4's selection colour. Prose's accent, not the system's — the
        // whole reason this is an `NSTextView` and not a `TextField`.
        view.selectedTextAttributes = [
            .backgroundColor: NSColor(Color(Palette.selectionBG))
        ]

        view.onSubmit = { session.go() }
        view.onEscape = { [weak view] in
            // Unlike the composer's Escape there is no turn to interrupt, so
            // this is only the second half: drop first responder and give the
            // plain arrow keys back to the tab strip (spec §12).
            view?.window?.makeFirstResponder(nil)
            session.onResignToTabStrip?()
        }
        // The direct line the workspace and Cmd+L use, for the reason spelled
        // out where the composer installs its own: a request left in state
        // reaches this view only if SwiftUI happens to re-render the pane.
        session.focusAddress = { [weak view] in
            guard let view, let window = view.window else { return false }
            if window.firstResponder !== view {
                window.makeFirstResponder(view)
                // Arriving by Cmd+L means replacing the address, not editing it.
                view.selectAll(nil)
            }
            return true
        }
        view.onEnterWindow = {
            guard session.wantsAddressFocus else { return }
            // Cleared only if it worked — see the same hook in `Composer`.
            if session.focusAddress?() == true { session.wantsAddressFocus = false }
        }
        view.onFocusChange = { focused in
            session.addressFocused = focused
            // Typing in a pane's URL bar makes it the focused pane, the same way
            // clicking its page does. The tap gesture on `PaneView` never sees
            // this click — the text view consumes it.
            if focused { session.onFocus?() }
        }

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.verticalScrollElasticity = .none
        scroll.horizontalScrollElasticity = .none

        context.coordinator.textView = view
        apply(metrics, to: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? AddressTextView else { return }
        apply(metrics, to: view)

        // The address changed underneath the field — a navigation landed, or an
        // agent pointed the pane somewhere. Guarded on inequality so that
        // echoing the user's own typing back does not move their caret.
        if view.string != session.address {
            view.string = session.address
            view.didChangeText()
        }

        // Cmd+L and a click on a page-less pane are handled by `focusAddress`,
        // and a request that arrived before this view did by `onEnterWindow`.
        // Neither is a redraw, so neither is read here — see the composer.
    }

    /// Dimensions are points and so change with the zoom; re-applied rather
    /// than captured, because there is no rem size to rescale them all.
    private func apply(_ metrics: Metrics, to view: AddressTextView) {
        let size = metrics.px(.textSize)

        view.font = .systemFont(ofSize: size)
        view.textColor = NSColor(Color(Palette.text))
        view.typingAttributes = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor(Color(Palette.text)),
        ]
        view.caretWidth = metrics.px(.caretWidth)
        view.placeholder = "Enter a URL…"
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: BrowserSession
        weak var textView: AddressTextView?

        init(session: BrowserSession) {
            self.session = session
        }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            // A pasted URL can arrive with a trailing newline attached, and a
            // field that cannot hold one should not pretend to.
            let flat = view.string.replacingOccurrences(of: "\n", with: "")
            if flat != view.string { view.string = flat }
            session.address = flat
        }
    }
}
