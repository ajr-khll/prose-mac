//  The small amount of markdown a message is allowed to carry.
//
//  spec §9.3 says prose does not parse markdown, and for *structure* that still
//  stands: headings, lists, tables and fenced blocks are the agent's to declare,
//  and code arrives as an `attachment` with its own type. But the model emits
//  `**` and backtick spans in the first sentence of almost every reply — the SDK
//  probe caught it on its first run (agent-plan §"The markdown bet is confirmed
//  as a real risk") — and until now those rendered as the literal characters.
//
//  Rendering *inline* emphasis is the whole of what this file does. It adds no
//  second way to say anything the transcript could already say; it only stops
//  prose showing its own punctuation.
//
//  Parsing lives here rather than in the view for the usual reason: it is a pure
//  question about a string, so it is answerable in a test with no window. What
//  the runs are *drawn* as — which font, which colour — is the view's, and stays
//  there.

import Foundation

public enum Markdown {
    /// Inline emphasis only: `**strong**`, `*emphasis*`, `` `code` ``,
    /// `~~strikethrough~~` and links. Block syntax is left as the characters the
    /// agent typed.
    ///
    /// Three choices here are load-bearing, and two of them were found by
    /// running the parser rather than by reading about it.
    ///
    /// `.inlineOnlyPreservingWhitespace` rather than `.inlineOnly`: the plain
    /// inline mode folds every run of whitespace, including newlines, into a
    /// single space — which would weld a two-paragraph reply into one and is
    /// much worse than the asterisks it set out to fix.
    ///
    /// A failure returns the text unparsed rather than nothing. **Every
    /// streaming message is malformed markdown for as long as it is streaming**
    /// — a `**` arrives a good deal earlier than the `**` that closes it — so
    /// the degraded path here is not an edge case, it is every message in the
    /// pane on its way past. Showing the raw characters is exactly the old
    /// behaviour, which is the right thing to fall back to.
    ///
    /// And two shapes never reach the parser at all, because measuring showed it
    /// damages them: see `fenced` and `escapingUnderscores`.
    public static func inline(_ text: String) -> AttributedString {
        let plain = AttributedString(text)
        guard !fenced(text) else { return plain }

        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false,
            interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible
        )
        return (try? AttributedString(markdown: escapingUnderscores(text), options: options))
            ?? plain
    }

    /// Does this text contain a fence?
    ///
    /// If it does, none of it is parsed. With block syntax switched off the
    /// parser reads a fence as one long *inline* code span: ` ```swift\nlet x =
    /// 1\n``` ` comes back as `swift let x = 1`, with the language tag glued to
    /// the front and the newlines flattened. That is strictly worse than the
    /// literal backticks it replaces — the code stops being readable — so a
    /// message with a fence in it renders exactly as it did before.
    ///
    /// Which also keeps `guide §4` honest: a fence in prose still shows as
    /// backticks, and code still belongs in an `attachment`.
    private static func fenced(_ text: String) -> Bool {
        text.contains("```")
    }

    /// Escapes `_` outside code spans, which turns underscore emphasis off.
    ///
    /// `__init__.py` parses as strong emphasis on `init` — the opening `__` is
    /// at a word boundary and the closing one is followed by a full stop, so
    /// CommonMark is within its rights and the pane eats four characters of a
    /// filename. In a tool whose panes are full of agents discussing code that
    /// is not an edge case, and losing characters is the one thing this file
    /// must not do.
    ///
    /// Asterisks are left alone, so `**strong**` and `*emphasis*` still work:
    /// the model reaches for those far more often, and giving up the underscore
    /// spelling costs a form of emphasis that simply renders as it does today.
    ///
    /// The scan has to know about backticks because an escape *inside* a code
    /// span is not an escape — it is a backslash, printed. `x_y()` in spans
    /// would come out as `x\_y()`.
    private static func escapingUnderscores(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        var inCode = false

        for character in text {
            if character == "`" { inCode.toggle() }
            if character == "_" && !inCode { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
