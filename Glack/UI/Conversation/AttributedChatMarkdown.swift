import AppKit
import Foundation

/// Custom NSAttributedString key marking a run as part of a code-block
/// paragraph. Used purely as a layout-time signal; on serialization the
/// flagged paragraphs are wrapped in ``` ``` fences.
extension NSAttributedString.Key {
    static let glackParagraphKind = NSAttributedString.Key("glackParagraphKind")
}

enum GlackParagraphKind: String {
    case codeBlock
}

/// Converts the composer's NSAttributedString into Chat-flavored markdown
/// the REST API accepts (developers.google.com/workspace/chat/format-messages).
///
///   * bold     → *text*       (font has bold trait)
///   * italic   → _text_       (font has italic trait)
///   * strike   → ~text~       (.strikethroughStyle > 0)
///   * code     → `text`       (monospaced font, no codeBlock kind)
///   * link     → <url|text>   (.link)
///   * code block paragraph → ```\ntext\n```
///   * "• item" line → "* item"
///   * "▎ text" line  → ">text"
///
/// Runs whose font carries both bold and italic emit `*_text_*` (nested).
enum AttributedChatMarkdown {
    static func serialize(_ s: NSAttributedString) -> String {
        let raw = s.string
        // Split into paragraphs by newline so we can apply line-leading and
        // paragraph-kind transforms independently of inline runs.
        let lines = raw.components(separatedBy: "\n")
        var out: [String] = []
        var lineStart = 0  // utf16 offset into `s`

        var i = 0
        while i < lines.count {
            let line = lines[i]
            let lineEnd = lineStart + (line as NSString).length
            let lineRange = NSRange(location: lineStart, length: lineEnd - lineStart)

            // Detect code-block paragraph by the custom attribute on the
            // first character of the line.
            if isCodeBlock(s, at: lineStart) {
                // Greedy: collect consecutive code-block lines.
                var blockLines: [String] = [line]
                var cursor = i + 1
                var cursorStart = lineEnd + 1  // +1 for the newline
                while cursor < lines.count, isCodeBlock(s, at: cursorStart) {
                    blockLines.append(lines[cursor])
                    cursorStart += (lines[cursor] as NSString).length + 1
                    cursor += 1
                }
                out.append("```")
                out.append(contentsOf: blockLines)
                out.append("```")
                lineStart = cursorStart
                i = cursor
                continue
            }

            // Inline-render the line, then translate the line-leading
            // bullet/quote visual markers to Chat syntax.
            var rendered = renderInline(s, in: lineRange)
            if rendered.hasPrefix("• ") {
                rendered = "* " + String(rendered.dropFirst(2))
            } else if rendered.hasPrefix("▎ ") {
                rendered = ">" + String(rendered.dropFirst(2))
            }
            out.append(rendered)
            lineStart = lineEnd + 1
            i += 1
        }

        // Trim trailing empty lines so a stray Return at the end doesn't
        // send a blank tail.
        while let last = out.last, last.isEmpty {
            out.removeLast()
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Inline

    private static func renderInline(_ s: NSAttributedString, in range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var output = ""
        s.enumerateAttributes(in: range, options: []) { attrs, subRange, _ in
            let text = (s.string as NSString).substring(with: subRange)
            output += wrap(text, attrs: attrs)
        }
        return output
    }

    private static func wrap(_ text: String, attrs: [NSAttributedString.Key: Any]) -> String {
        // Links short-circuit: emit `<url|text>` and skip inline emphasis.
        if let url = attrs[.link] as? URL {
            return "<\(url.absoluteString)|\(text)>"
        }
        if let urlStr = attrs[.link] as? String, !urlStr.isEmpty {
            return "<\(urlStr)|\(text)>"
        }

        // Skip emphasis on whitespace-only runs — `* *` is not valid bold.
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return text
        }

        var prefix = ""
        var suffix = ""

        let font = attrs[.font] as? NSFont
        if let font {
            let traits = NSFontManager.shared.traits(of: font)
            if traits.contains(.boldFontMask) {
                prefix += "*"; suffix = "*" + suffix
            }
            if traits.contains(.italicFontMask) {
                prefix += "_"; suffix = "_" + suffix
            }
            // Inline code (monospaced font but not a code-block paragraph).
            let kind = attrs[.glackParagraphKind] as? String
            if isMonospaced(font), kind != GlackParagraphKind.codeBlock.rawValue {
                prefix += "`"; suffix = "`" + suffix
            }
        }
        if let strike = attrs[.strikethroughStyle] as? Int, strike > 0 {
            prefix += "~"; suffix = "~" + suffix
        }
        return prefix + text + suffix
    }

    private static func isMonospaced(_ font: NSFont) -> Bool {
        font.isFixedPitch || (font.familyName?.contains("Mono") ?? false)
            || (font.familyName?.contains("Menlo") ?? false)
    }

    private static func isCodeBlock(_ s: NSAttributedString, at location: Int) -> Bool {
        guard location < s.length else { return false }
        let v = s.attribute(.glackParagraphKind, at: location, effectiveRange: nil) as? String
        return v == GlackParagraphKind.codeBlock.rawValue
    }
}
