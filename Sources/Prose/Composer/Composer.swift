//  The composer: an `NSTextView` in a representable.
//
//  This is the file plan §3 is about. `composer.rs` is 585 lines that shape
//  each newline-separated line, stack the rows, cache where every row landed so
//  clicks and vertical arrows have something to hit-test, cut style runs at
//  selection and IME-composition boundaries, and implement the platform input
//  protocol with UTF-8 ↔ UTF-16 conversion at the edge. None of that is here,
//  because `NSTextView` already is it.
//
//  What *is* here is only the handful of behaviours AppKit cannot guess:
//  Enter sends, Escape interrupts, the caret is 1.5pt and does not blink, and
//  the box grows to eight lines and then scrolls. Everything else in spec §9.6
//  — word movement, grapheme-cluster deletion, visual-line arrows, selection
//  extension from an anchor, Cmd+A, IME marked text and its candidate window,
//  the UTF-16 boundary, pointer selection, and the released-outside-the-window
//  guard — is inherited and appears nowhere below.

import AppKit
import ProseCore
import SwiftUI

/// The text view itself.
final class ComposerTextView: NSTextView {
    var onSend: (() -> Void)?
    var onEscape: (() -> Void)?
    var onFocusChange: ((Bool) -> Void)?

    /// The caret's width in pixels at the current zoom, and its colour.
    var caretWidth: CGFloat = Points.caretWidth.value
    var caretColor: NSColor = NSColor(Color(Palette.caret))

    /// How tall the box may grow before it scrolls instead.
    var maximumHeight: CGFloat = .greatestFiniteMagnitude

    /// Whether what is being typed is a credential, and so is drawn as bullets.
    ///
    /// `NSTextView` has no `isSecure` — that is `NSSecureTextField`, which is
    /// single-line and would mean swapping the whole composer out for one
    /// question. So the storage keeps the real characters, which is what
    /// `text` and therefore the answer read, and only the *drawing* is
    /// replaced. `NSLayoutManager` asks its delegate for a replacement glyph,
    /// which is the seam that exists for exactly this.
    var masksInput: Bool = false {
        didSet {
            guard masksInput != oldValue else { return }
            // A mask that turns on after something is typed has to repaint
            // what is already there.
            layoutManager?.invalidateDisplay(
                forCharacterRange: NSRange(location: 0, length: string.count))
            needsDisplay = true
        }
    }

    /// What an empty composer says, and in what colour (spec §9.4).
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var placeholderColor = NSColor(Color(Palette.composerPlaceholder)) {
        didSet { needsDisplay = true }
    }

    // MARK: - spec §9.4, the placeholder

    /// Drawn by the text view rather than laid over it.
    ///
    /// The obvious way is a `Text` in a SwiftUI overlay, and it was how this
    /// started — but then two different systems each decide where the first
    /// character goes, and they do not agree. AppKit puts the first glyph at
    /// the container origin *plus `lineFragmentPadding`*, a 5pt inset a text
    /// container adds on its own, and lays the baseline out under a 1.45 line
    /// height. An overlay padded to `composerPaddingX` lands 5pt to the left of
    /// that and on a different baseline, so the placeholder sat where the typed
    /// text would not, and the caret — which is always at the real origin —
    /// struck through the first letter.
    ///
    /// Drawing it here removes the disagreement rather than tuning it away:
    /// same origin, same font, same paragraph style, so the placeholder is by
    /// construction exactly where the first character will be.
    ///
    /// The origin is a property rather than a local so a test can hold it
    /// against the first glyph's, instead of recomputing it and agreeing with
    /// itself.
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
                // The same 1.45 line height the typed text gets, so the
                // placeholder's baseline is the baseline it replaces.
                .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default,
            ]
        )
    }

    // MARK: - spec §9.5, sending

    /// The key event currently being interpreted, for as long as that lasts.
    ///
    /// `doCommand(by:)` is handed a selector and nothing else, and the modifier
    /// that separates "send" from "newline" **is not in the selector** — see
    /// there. AppKit's own answer to this is `NSApp.currentEvent`, which is only
    /// set for events that came through `NSApplication.sendEvent(_:)`: true in
    /// the running app, false for anything driving the view directly, which is
    /// every test of this behaviour. Stashing it here works in both.
    private var interpreting: NSEvent?

    override func keyDown(with event: NSEvent) {
        interpreting = event
        defer { interpreting = nil }

        // Cmd+Delete deletes back to the start of the line.
        //
        // macOS has **no standard binding for it in a text view** — measured,
        // not assumed: it arrives as `noop:`, where Option+Delete arrives as
        // `deleteWordBackward:`. Every other text box on the machine does this,
        // because every app that offers it implements it itself, so prose has
        // to as well. Cocoa already has the edit; only the key is missing.
        //
        // Handled before `super` rather than in `doCommand`, because there is no
        // selector to match on — `noop:` is what everything unbound arrives as,
        // and matching it would claim keys that are not this one.
        if isDeleteToStartOfLine(event) {
            deleteToBeginningOfLine(nil)
            return
        }

        super.keyDown(with: event)
    }

    /// Cmd+Delete, and nothing else.
    ///
    /// Marked text is excluded: while an input method is composing, Delete
    /// belongs to the candidate being built and taking it would break the
    /// composition (spec §9.6's inherited IME behaviour).
    private func isDeleteToStartOfLine(_ event: NSEvent) -> Bool {
        guard !hasMarkedText() else { return false }

        let held = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        return held == .command && event.keyCode == Self.deleteKeyCode
    }

    /// The Delete key that sits above Return, which sends `deleteBackward:`.
    /// Not the forward-delete key.
    private static let deleteKeyCode: UInt16 = 51

    /// Enter sends and Shift+Enter inserts a newline (spec §9.5).
    ///
    /// **Both arrive as `insertNewline:`.** This file used to claim that AppKit
    /// mapped Shift+Return to `insertNewlineIgnoringFieldEditor:` and could
    /// therefore ignore the modifier flags entirely; it does not, and the result
    /// was that Shift+Enter sent the message while the composer's own hint row
    /// said it would newline. Measured against a real key event rather than
    /// reasoned about: plain and shifted Return both produce `insertNewline:`,
    /// and only *Option*+Return produces the `IgnoringFieldEditor` variant.
    ///
    /// So the modifier has to be read off the event, which is what
    /// `interpreting` is for. The check stays here rather than in `keyDown`
    /// because an input method composing marked text consumes Return itself and
    /// never reaches `doCommand` — intercepting earlier would break confirming a
    /// candidate with Return, which is spec §9.6's inherited IME behaviour.
    override func doCommand(by selector: Selector) {
        guard selector == #selector(insertNewline(_:)) else {
            // Option+Return arrives as `insertNewlineIgnoringFieldEditor:` and
            // already means "a newline, whatever Return would otherwise do", so
            // it needs nothing from us.
            super.doCommand(by: selector)
            return
        }

        if interpreting?.modifierFlags.contains(.shift) == true {
            insertNewlineIgnoringFieldEditor(nil)
        } else {
            onSend?()
        }
    }

    /// Escape interrupts a running turn; otherwise it hands the keyboard back
    /// to the tab strip (spec §9.6).
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    // MARK: - spec §9.4, the caret

    /// A 1.5pt filled bar rather than the system's hairline, wide enough to see
    /// against prose at every zoom and narrow enough not to read as a selected
    /// character.
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        var wide = rect
        wide.size.width = caretWidth
        super.drawInsertionPoint(in: wide, color: caretColor, turnedOn: flag)
    }

    /// **It does not blink.** Passing `false` means the blink timer is never
    /// restarted, so the caret is drawn once and stays.
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(false)
    }

    // MARK: - spec §9.4, growth

    /// How tall the text actually is, floored at one line.
    ///
    /// **Uncapped**, and that is the point of it being separate from
    /// `boxHeight`. This view is the scroll view's document, and a document has
    /// to be as tall as its contents or there is nothing for the scroll view to
    /// scroll — the cap belongs to the box, not to the text inside it.
    var contentHeight: CGFloat {
        guard let container = textContainer, let manager = layoutManager else {
            return oneLine
        }
        manager.ensureLayout(for: container)
        // An empty buffer lays out as nothing, but the box is still one line.
        return max(manager.usedRect(for: container).height, oneLine)
    }

    /// How tall the **box** should be: the content, up to eight lines (spec
    /// §9.4). Past that the transcript has given up too much of the pane to be
    /// worth reading, so the box stops and the text scrolls inside it.
    var boxHeight: CGFloat { min(contentHeight, maximumHeight) }

    /// One line of the composer's own face, spacing aside.
    private var oneLine: CGFloat {
        let face = font ?? .systemFont(ofSize: Points.textSize.value)
        return layoutManager?.defaultLineHeight(for: face) ?? face.pointSize
    }

    /// The document's size, which is the uncapped one.
    ///
    /// This used to return `min(height, maximumHeight)`, and that single `min`
    /// was half the bug: it told the scroll view its document was never taller
    /// than eight lines, so past that the text laid out below the frame and
    /// vanished — no scrolling, because as far as AppKit knew there was nothing
    /// to scroll to. What SwiftUI needs is the capped number, and that is
    /// `boxHeight`, read where the box is actually sized.
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: contentHeight)
    }

    override func didChangeText() {
        super.didChangeText()
        invalidateIntrinsicContentSize()
        // Past the cap the caret can sit below the visible part of the box, and
        // then typing goes somewhere the user cannot see — which is the whole
        // complaint. Keeping the caret in view is the last part of the fix.
        scrollRangeToVisible(selectedRange())
        // The placeholder appears and disappears with the first and last
        // character, and neither is a layout change AppKit would redraw for.
        needsDisplay = true
    }


    // MARK: - Focus

    /// Called when this view arrives in a window, which is the moment a pane
    /// that was asked for the keyboard before it existed can finally take it.
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

/// Puts the composer in SwiftUI.
struct Composer: NSViewRepresentable {
    let session: AgentSession
    let metrics: Metrics

    /// What the empty composer says it will do. Passed in rather than read off
    /// the session inside `updateNSView`, because that is not a `body` and does
    /// not establish observation — SwiftUI has to see the *value* change to
    /// know the view needs updating at all.
    let placeholder: String

    /// Whether the outstanding question is asking for a credential.
    ///
    /// Passed as a value for the same reason `placeholder` is: `updateNSView`
    /// is not a `body` and establishes no observation, so SwiftUI has to see
    /// this change to know the view needs updating at all. When it is set the
    /// text view echoes bullets — an `NSTextView` has no `isSecure`, so it is
    /// done in `ComposerTextView` rather than had for free.
    let secret: Bool

    /// How tall one line of the composer's font is, spacing aside.
    ///
    /// spec §5's 1.45 is the distance *between* lines, so it says nothing about
    /// how tall a single one is — that comes from the font, and both the text
    /// view and the box it sits in have to agree on it.
    static func lineHeight(at size: CGFloat) -> CGFloat {
        NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: size))
    }

    /// Where the first line's baseline sits, measured down from the top of the
    /// box.
    ///
    /// The `\u{203A}` beside the composer is a SwiftUI `Text` at a larger size,
    /// and a representable has no baseline SwiftUI can discover — so unless it
    /// is handed one, an `HStack` can only line the two up by their *tops*,
    /// which puts them on different baselines the moment the two sizes differ.
    /// That is what made the glyph sit above where typing starts.
    ///
    /// Measured rather than derived from the font: the typesetter's baseline is
    /// 13.0 at 13pt where the ascender is 12.57, and it is the typesetter's that
    /// the text is actually laid out on.
    static func firstBaseline(at size: CGFloat) -> CGFloat {
        NSLayoutManager().defaultBaselineOffset(for: .systemFont(ofSize: size))
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 1 explicitly: `intrinsicContentSize` is read off the layout
        // manager's used rect (plan §3), and the TextKit 2 stack a bare
        // NSTextView gets by default has no `layoutManager` to ask.
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        // A text container insets its own text by 5pt unless told not to, which
        // would put the first character 13pt from the box's edge where spec §5
        // says 8. The composer's padding is stated once, in SwiftUI, so this
        // has to contribute nothing.
        container.lineFragmentPadding = 0
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)

        let view = ComposerTextView(frame: .zero, textContainer: container)
        // The seam that makes masking possible without touching the storage.
        manager.delegate = view
        view.delegate = context.coordinator
        view.isRichText = false
        view.isEditable = true
        view.allowsUndo = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        // `isVerticallyResizable` grows the view *within its min/max*, and
        // `maxSize` defaults to **the frame it was built with** — which above is
        // `.zero`. That was the other half of the bug: the view could not grow
        // past eight lines because it could not grow at all, and what looked
        // like growth up to that point was the scroll view stretching its
        // document to fill the clip. Measured, not assumed: a text view built at
        // 400×20 reports `maxSize` (400, 20).
        view.minSize = .zero
        view.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )

        // spec §9.4: selected text is drawn as a background run *on the shaped
        // line* rather than as a separate quad, so it follows text around a
        // wrap correctly. One attribute.
        view.selectedTextAttributes = [
            .backgroundColor: NSColor(Color(Palette.selectionBG))
        ]

        let submit = { [weak view] in
            guard let view else { return }
            session.send(view.string)
            view.string = ""
            view.didChangeText()
        }
        view.onSend = submit

        // The two routes into this text view that are not the keyboard: the
        // `send \u{21B5}` button, and the suggestion under the welcome screen.
        // Both go through the view for the same reason `focusComposer` does —
        // the string lives here, not in the session.
        session.submitComposer = submit
        session.setComposerText = { [weak view] text in
            guard let view else { return }
            view.string = text
            // The caret goes to the end, as it would if the text had been
            // typed; a suggestion is a starting point to edit, not a selection.
            view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            view.didChangeText()
        }
        view.onEscape = { [weak view] in
            // Interrupt a running turn; otherwise give the keyboard back to the
            // tab strip (spec §9.6).
            if session.interrupt() { return }
            view?.window?.makeFirstResponder(nil)
            session.onResignToTabStrip?()
        }
        view.onFocusChange = { focused in
            session.composerFocused = focused
            // Like the browser's address field, the embedded AppKit text view
            // consumes its own click, so the pane-level SwiftUI tap gesture is
            // not a reliable way to learn that the keyboard moved here.
            if focused { session.onFocus?() }
        }

        // The direct line the workspace uses to put the caret here, rather than
        // leaving a request in state and trusting SwiftUI to notice it. It does
        // not: `AgentPaneBody` is a value holding a single reference, so a pane
        // gaining focus leaves it equal to what it was, the subtree is pruned,
        // and `updateNSView` below is never reached. Measured — clicking one
        // agent pane while another's composer held the keyboard moved the ring
        // and left the caret behind, which is spec §8's one rule about focus.
        //
        // Answering `false` when there is no window is what keeps the flag
        // meaningful: a pane split into existence is asked for the keyboard
        // before it has a view, and that request has to survive until it does.
        session.focusComposer = { [weak view] in
            guard let view, let window = view.window else { return false }
            if window.firstResponder !== view { window.makeFirstResponder(view) }
            return true
        }
        // And the other half: a request made before this view existed waits in
        // `wantsComposerFocus` until the view arrives in a window, which is
        // what a split is — the pane is asked for the keyboard at the moment it
        // is created, which is before there is anything to give it to.
        view.onEnterWindow = {
            guard session.wantsComposerFocus else { return }
            // Cleared only if it worked. Having a window is the one thing
            // `focusComposer` checks and entering one is why this hook ran, so
            // the answer here is all but always yes — the exception is a view
            // already on its way out, and a request kept is harmless where a
            // request dropped would strand the caret. `Workspace.focusPane`
            // re-arms on the same answer; this is the other half of it.
            if session.focusComposer?() == true { session.wantsComposerFocus = false }
        }

        let scroll = NSScrollView()
        scroll.documentView = view
        scroll.drawsBackground = false
        // Overlay scrollers float over the text rather than taking width from
        // it, so this costs the layout nothing and is the only thing telling a
        // user with a long prompt that there is more of it above.
        scroll.scrollerStyle = .overlay
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none

        context.coordinator.textView = view
        apply(metrics, to: view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ComposerTextView else { return }
        apply(metrics, to: view)
        view.masksInput = secret
        // Focus is deliberately *not* chased here. A redraw is not an
        // event about the keyboard: a request read on one left the caret being
        // pulled back out of whatever the user had moved to since, and a request
        // read on a redraw that happened not to come never arrived at all. The
        // two real events have their own hooks — `focusComposer` for a view that
        // exists, `onEnterWindow` for one that has just appeared.
    }

    /// Dimensions are points and so change with the zoom; re-applied rather
    /// than captured, because there is no rem size to rescale them all.
    private func apply(_ metrics: Metrics, to view: ComposerTextView) {
        let size = metrics.px(.textSize)
        let paragraph = NSMutableParagraphStyle()
        // spec §5's 1.45 is the distance from one baseline to the next — 18.85
        // at 1.0× — so it is applied *between* lines and not around them.
        //
        // The two ways of asking for it that do not work, both tried:
        // `lineHeightMultiple` scales the font's natural line height rather
        // than its point size, and 13pt system text is naturally 16pt a line,
        // so 1.45 there gives 23.2. Pinning `minimum`/`maximumLineHeight` to
        // 18.85 gets the number right but AppKit adds the extra 2.85 entirely
        // *above* the line, which on a one-line composer is a gap over the text
        // and nothing under it — measured, 11pt above and 5 below. Either way
        // the box reads as too tall, and the caret, which is always the whole
        // line fragment, stands taller than the text beside it.
        //
        // Spacing leaves the first line its natural height and puts the
        // difference between lines, where the air was wanted: one line is 16pt
        // and sits centred in its padding, and every line after it starts
        // 18.85 below the one before.
        paragraph.lineSpacing = size * Metrics.lineHeight - Self.lineHeight(at: size)

        view.font = .systemFont(ofSize: size)
        view.textColor = NSColor(Color(Palette.text))
        view.defaultParagraphStyle = paragraph
        view.typingAttributes = [
            .font: NSFont.systemFont(ofSize: size),
            .foregroundColor: NSColor(Color(Palette.text)),
            .paragraphStyle: paragraph,
        ]
        view.caretWidth = metrics.px(.caretWidth)
        view.placeholder = placeholder
        // Eight lines as the composer itself lays them out: the first keeps its
        // natural height and each one after starts `size * lineHeight` below the
        // one before (see `paragraph.lineSpacing` above). Multiplying the pitch
        // by eight instead — which is what this did — over-counts by the
        // difference between a line's natural height and its pitch, and left the
        // box a few points taller than the eight lines spec §9.4 asks for.
        view.maximumHeight =
            Self.lineHeight(at: size)
            + size * Metrics.lineHeight * Double(Metrics.composerMaxLines - 1)
        view.invalidateIntrinsicContentSize()

        session.composerHeight = view.boxHeight
    }

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: AgentSession
        weak var textView: ComposerTextView?

        init(session: AgentSession) {
            self.session = session
        }

        func textDidChange(_ notification: Notification) {
            guard let view = textView else { return }
            session.composerIsEmpty = view.string.isEmpty
            session.composerHeight = view.boxHeight
        }
    }
}


/// Masking, done by swapping glyphs rather than characters.
///
/// The text storage keeps exactly what was typed — which is what `string`, the
/// answer and the undo stack all read — and only the glyphs handed to the
/// typesetter are replaced. That is why paste, select-all, delete and undo all
/// behave normally while the field is masked: none of them ever see a bullet.
///
/// The alternative, keeping a shadow copy of the real text and displaying
/// bullets, has to intercept every way characters can arrive. This has to
/// intercept none of them.
extension ComposerTextView: @MainActor NSLayoutManagerDelegate {
    // Layout runs on the main actor with the view it is laying out, which the
    // protocol predates saying.
    nonisolated func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        // Zero means "you decide", which is the normal path and has to stay
        // the cheap one: this is called for every layout of every keystroke.
        guard MainActor.assumeIsolated({ masksInput }), glyphRange.length > 0
        else { return 0 }

        var bullet: CGGlyph = 0
        var character: UniChar = 0x2022  // •
        guard CTFontGetGlyphsForCharacters(font, &character, &bullet, 1) else {
            return 0
        }

        let masked = [CGGlyph](repeating: bullet, count: glyphRange.length)
        let unchanged = Array(
            UnsafeBufferPointer(start: properties, count: glyphRange.length))
        let indexes = Array(
            UnsafeBufferPointer(start: characterIndexes, count: glyphRange.length))

        masked.withUnsafeBufferPointer { glyphBuffer in
            unchanged.withUnsafeBufferPointer { propertyBuffer in
                indexes.withUnsafeBufferPointer { indexBuffer in
                    layoutManager.setGlyphs(
                        glyphBuffer.baseAddress!,
                        properties: propertyBuffer.baseAddress!,
                        characterIndexes: indexBuffer.baseAddress!,
                        font: font,
                        forGlyphRange: glyphRange)
                }
            }
        }
        return glyphRange.length
    }
}
