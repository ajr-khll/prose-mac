import Foundation
import Testing

@testable import ProseCore

/// What the transcript is allowed to restyle, and — more importantly — what it
/// must leave exactly as the agent typed it. Losing characters is the one
/// failure this parse is not allowed, so most of these assert on the plain text
/// rather than on the styling.
@Suite("Markdown")
struct MarkdownTests {
    /// The characters, with every attribute thrown away.
    private func plain(_ text: String) -> String {
        String(Markdown.inline(text).characters)
    }

    private func intent(_ text: String, over needle: String) -> InlinePresentationIntent? {
        let attributed = Markdown.inline(text)
        guard let range = attributed.range(of: needle) else { return nil }
        return attributed[range].inlinePresentationIntent
    }

    @Test("strong and emphasis lose their punctuation and gain an intent")
    func emphasis() {
        #expect(plain("a **b** c") == "a b c")
        #expect(intent("a **b** c", over: "b") == .stronglyEmphasized)
        #expect(plain("a *b* c") == "a b c")
        #expect(intent("a *b* c", over: "b") == .emphasized)
        #expect(intent("a ~~b~~ c", over: "b") == .strikethrough)
    }

    @Test("a code span is an intent, not an attachment")
    func codeSpan() {
        #expect(plain("call `frobnicate()` first") == "call frobnicate() first")
        #expect(intent("call `frobnicate()` first", over: "frobnicate()") == .code)
    }

    /// The streaming case, and the reason the parse may never throw away text:
    /// every message is half-written markdown on its way past.
    @Test("an unclosed delimiter stays the characters that were typed")
    func unterminated() {
        #expect(plain("a **b") == "a **b")
        #expect(plain("a `b") == "a `b")
        #expect(plain("half a *sent") == "half a *sent")
    }

    /// `.inlineOnly` would fold these into single spaces and weld the reply into
    /// one paragraph. The transcript is paragraphs; this is the whole reason for
    /// the `PreservingWhitespace` mode.
    @Test("paragraph breaks survive")
    func whitespace() {
        #expect(plain("one\n\ntwo") == "one\n\ntwo")
        #expect(plain("one\ntwo") == "one\ntwo")
    }

    /// Structure is still the agent's to declare (spec §9.3): a heading or a
    /// bullet is not markdown here, it is the characters `#` and `-`.
    @Test("block syntax is left alone")
    func blockSyntaxUntouched() {
        #expect(plain("# Heading") == "# Heading")
        #expect(plain("- one\n- two") == "- one\n- two")
        #expect(plain("1. one\n2. two") == "1. one\n2. two")
        #expect(plain("> quoted") == "> quoted")
        #expect(plain("| a | b |\n| - | - |") == "| a | b |\n| - | - |")
    }

    /// With block syntax off the parser reads a fence as one enormous inline
    /// code span, flattening the newlines and gluing the language tag to the
    /// first line. So a fenced message is not parsed at all, and renders as it
    /// always has: literal backticks, and code that can still be read.
    @Test("a fence is left entirely alone, mangling and all")
    func fencesAreNotTouched() {
        let fence = "```swift\nlet x = 1\n```"
        #expect(plain(fence) == fence)

        // Including the emphasis elsewhere in the same message: the bail-out is
        // the whole text, because half-parsing it would be harder to explain
        // than not parsing it.
        let mixed = "see **this**:\n```\ncode()\n```"
        #expect(plain(mixed) == mixed)
    }

    /// `__init__.py` is strong emphasis by CommonMark's rules — word boundary
    /// open, punctuation close — and a pane full of agents talking about code
    /// would eat filenames all day. Underscore emphasis is turned off for it.
    @Test("underscores are never emphasis")
    func underscores() {
        #expect(plain("__init__.py holds it") == "__init__.py holds it")
        #expect(plain("a _b_ c") == "a _b_ c")
        #expect(plain("snake_case_name") == "snake_case_name")
        // The escaping must not leak into code spans, where a backslash is a
        // backslash and would be printed.
        #expect(plain("call `x_y()` now") == "call x_y() now")
        #expect(plain("`__main__` and __main__") == "__main__ and __main__")
    }

    @Test("a link keeps its text and carries its URL")
    func link() throws {
        let attributed = Markdown.inline("see [the spec](https://example.com/s) for why")
        #expect(String(attributed.characters) == "see the spec for why")
        let range = try #require(attributed.range(of: "the spec"))
        #expect(attributed[range].link?.absoluteString == "https://example.com/s")
    }

    /// A URL with an underscore in it still has to survive the escaping.
    @Test("a link's URL is not damaged by the underscore escape")
    func linkWithUnderscore() throws {
        let attributed = Markdown.inline("[docs](https://example.com/a_b)")
        let range = try #require(attributed.range(of: "docs"))
        #expect(attributed[range].link?.absoluteString == "https://example.com/a_b")
    }

    @Test("prose with no markdown in it comes back identical")
    func untouched() {
        let text = "It returned 3 rows, which is what the index predicted."
        #expect(plain(text) == text)
    }
}
