//  Putting a string into a script without it becoming part of the script.
//
//  One function, in the model rather than beside the browser pane, because it
//  is a pure text question and the kind of thing that gets reinvented badly the
//  second time someone needs it.

import Foundation

extension String {
    /// This string as a JavaScript literal, quotes and all.
    ///
    /// An agent chooses the selector, and an agent can be talked into choosing
    /// a bad one by a page it just read — so the selector is *data* in the
    /// script prose builds, never text spliced into it. Backslash first, or it
    /// would escape the escapes added after it.
    public var javaScriptQuoted: String {
        var out = self
        out = out.replacingOccurrences(of: "\\", with: "\\\\")
        out = out.replacingOccurrences(of: "\"", with: "\\\"")
        out = out.replacingOccurrences(of: "\n", with: "\\n")
        out = out.replacingOccurrences(of: "\r", with: "\\r")
        // Line and paragraph separators are literal newlines to a JavaScript
        // parser but not to Swift, so they have to go too.
        out = out.replacingOccurrences(of: "\u{2028}", with: "\\u2028")
        out = out.replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        return "\"\(out)\""
    }
}
