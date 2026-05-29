import SwiftUI

/// Renders Google Chat's flavored markdown into an AttributedString.
/// Supports the syntax documented at developers.google.com/workspace/chat/format-messages:
///   *bold*  _italic_  ~strike~  `code`  ```code block```
///   >quote (line-leading)   * item / - item (line-leading)
///   <url|display>  <url>  <users/{id}>
///
/// Unlike CommonMark, Chat uses single `*` for bold and single `_` for italic
/// (no double markers), and code spans use backticks identically to GFM.
@MainActor
enum ChatMarkdown {
    static func render(_ source: String, users: UsersObserver? = nil) -> AttributedString {
        var out = AttributedString("")
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        for (idx, line) in lines.enumerated() {
            out.append(renderLine(String(line), users: users))
            if idx < lines.count - 1 {
                out.append(AttributedString("\n"))
            }
        }
        return out
    }

    // MARK: - Line-level

    private static func renderLine(_ line: String, users: UsersObserver?) -> AttributedString {
        // Blockquote: lines starting with ">" render with a leading bar and
        // gray tint. Don't recurse into nested quote markers.
        if line.hasPrefix(">") {
            let body = String(line.dropFirst()).trimmingPrefix(" ")
            var q = renderInline(String(body), users: users)
            q.foregroundColor = .secondary
            var out = AttributedString("┃ ")
            out.foregroundColor = .secondary
            out.append(q)
            return out
        }
        // Bulleted list: "* item" or "- item" at line start.
        if line.hasPrefix("* ") || line.hasPrefix("- ") {
            let body = String(line.dropFirst(2))
            var bullet = AttributedString("• ")
            bullet.foregroundColor = .secondary
            bullet.append(renderInline(body, users: users))
            return bullet
        }
        return renderInline(line, users: users)
    }

    // MARK: - Inline

    /// Inline parser — single forward pass over UTF-16 characters maintaining
    /// a small stack of open marker states. Code spans suppress all other
    /// formatting (so `*not bold*` inside `` ` `` stays literal).
    private static func renderInline(_ s: String, users: UsersObserver?) -> AttributedString {
        var out = AttributedString("")
        let chars = Array(s)
        var i = 0

        // Buffer plain runs before flushing with active attrs.
        var buffer = ""
        var bold = false, italic = false, strike = false, code = false

        func flush() {
            guard !buffer.isEmpty else { return }
            var seg = AttributedString(buffer)
            if code {
                seg.font = .system(size: 13, design: .monospaced)
                seg.backgroundColor = Color.gray.opacity(0.18)
            } else {
                var traits: Font = .system(size: 13)
                if bold && italic {
                    traits = .system(size: 13, weight: .semibold).italic()
                } else if bold {
                    traits = .system(size: 13, weight: .semibold)
                } else if italic {
                    traits = .system(size: 13).italic()
                }
                seg.font = traits
                if strike { seg.strikethroughStyle = .single }
            }
            out.append(seg)
            buffer = ""
        }

        while i < chars.count {
            let c = chars[i]

            // Triple-backtick code block. Spans multiple lines, eats markers.
            if !code && i + 2 < chars.count && c == "`" && chars[i+1] == "`" && chars[i+2] == "`" {
                flush()
                if let end = findCloser(in: chars, from: i + 3, marker: "```") {
                    var block = AttributedString(String(chars[(i+3)..<end]))
                    block.font = .system(size: 12, design: .monospaced)
                    block.backgroundColor = Color.gray.opacity(0.15)
                    out.append(block)
                    i = end + 3
                    continue
                }
            }

            // Inline code span.
            if c == "`" {
                flush()
                code.toggle()
                i += 1
                continue
            }

            // Suppress all other markup inside code.
            if code {
                buffer.append(c)
                i += 1
                continue
            }

            // Bold *...* — require non-space neighbors to avoid * in "a * b".
            if c == "*", canToggle(at: i, in: chars, isOpen: !bold) {
                flush()
                bold.toggle()
                i += 1
                continue
            }
            if c == "_", canToggle(at: i, in: chars, isOpen: !italic) {
                flush()
                italic.toggle()
                i += 1
                continue
            }
            if c == "~", canToggle(at: i, in: chars, isOpen: !strike) {
                flush()
                strike.toggle()
                i += 1
                continue
            }

            // Bracketed token: <url|display>, <url>, <users/{id}>.
            if c == "<", let close = nextIndex(of: ">", in: chars, from: i + 1) {
                flush()
                let inner = String(chars[(i+1)..<close])
                if let resolved = resolveBracketToken(inner, users: users) {
                    out.append(resolved)
                    i = close + 1
                    continue
                }
            }

            buffer.append(c)
            i += 1
        }
        flush()
        return out
    }

    // MARK: - Helpers

    /// `*foo*` should toggle bold only when the marker neighbors non-whitespace
    /// on the closing side (opening) or the opening side (closing). Prevents
    /// `5 * 4 = 20` from rendering as bold.
    private static func canToggle(at i: Int, in chars: [Character], isOpen: Bool) -> Bool {
        if isOpen {
            // Opening marker: char after must be non-space, non-marker.
            guard i + 1 < chars.count else { return false }
            return !chars[i+1].isWhitespace
        } else {
            // Closing marker: char before must be non-space.
            guard i > 0 else { return false }
            return !chars[i-1].isWhitespace
        }
    }

    private static func nextIndex(of target: Character, in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == target { return i }
            i += 1
        }
        return nil
    }

    private static func findCloser(in chars: [Character], from start: Int, marker: String) -> Int? {
        let m = Array(marker)
        var i = start
        while i + m.count <= chars.count {
            if Array(chars[i..<(i+m.count)]) == m { return i }
            i += 1
        }
        return nil
    }

    /// Resolve `<users/123>`, `<https://x|click>`, or `<https://x>` into a
    /// styled AttributedString. Returns nil if the token doesn't match —
    /// the caller will then render the original `<...>` as literal text.
    private static func resolveBracketToken(_ inner: String, users: UsersObserver?) -> AttributedString? {
        // User mention: <users/{id}> or <users/all>
        if inner.hasPrefix("users/") {
            let id = inner
            let label: String
            if inner == "users/all" {
                label = "@everyone"
            } else if let name = users?.displayName(for: id), !name.isEmpty {
                label = "@\(name)"
            } else {
                label = "@user"
            }
            var seg = AttributedString(label)
            seg.font = .system(size: 13, weight: .medium)
            seg.foregroundColor = .accentColor
            return seg
        }
        // Link with display text: <url|text>
        if let bar = inner.firstIndex(of: "|") {
            let url = String(inner[..<bar])
            let display = String(inner[inner.index(after: bar)...])
            if let u = URL(string: url) {
                var seg = AttributedString(display)
                seg.link = u
                seg.foregroundColor = .accentColor
                seg.underlineStyle = .single
                return seg
            }
        }
        // Bare URL: <https://...>
        if inner.hasPrefix("http://") || inner.hasPrefix("https://") {
            if let u = URL(string: inner) {
                var seg = AttributedString(inner)
                seg.link = u
                seg.foregroundColor = .accentColor
                seg.underlineStyle = .single
                return seg
            }
        }
        return nil
    }
}

private extension Substring {
    func trimmingPrefix(_ prefix: String) -> Substring {
        hasPrefix(prefix) ? dropFirst(prefix.count) : self
    }
}
