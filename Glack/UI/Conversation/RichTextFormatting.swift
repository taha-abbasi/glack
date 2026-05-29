import AppKit
import Foundation

/// Shared formatting operations on the composer's NSTextView. Both the
/// toolbar buttons and the keyboard-shortcut handler in TaggedTextView
/// call into these so the two paths can't drift apart.
enum RichTextFormatting {
    // MARK: - Inline traits

    /// Toggle a font trait (bold or italic) on the selection or, when there
    /// is no selection, on the editor's typing attributes so the next keys
    /// pick it up. Uses NSFontManager, the canonical macOS path.
    static func toggleTrait(_ trait: NSFontTraitMask, on tv: NSTextView) {
        let mgr = NSFontManager.shared
        let range = tv.selectedRange()
        let baseFont = RichTextEditor.defaultFont
        if range.length > 0, let storage = tv.textStorage {
            guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
            storage.beginEditing()
            storage.enumerateAttribute(.font, in: range, options: []) { value, subRange, _ in
                let font = (value as? NSFont) ?? baseFont
                let has = mgr.traits(of: font).contains(trait)
                let newFont = has
                    ? mgr.convert(font, toNotHaveTrait: trait)
                    : mgr.convert(font, toHaveTrait: trait)
                storage.addAttribute(.font, value: newFont, range: subRange)
            }
            storage.endEditing()
            tv.didChangeText()
        } else {
            var ta = tv.typingAttributes
            let current = (ta[.font] as? NSFont) ?? baseFont
            let has = mgr.traits(of: current).contains(trait)
            let newFont = has
                ? mgr.convert(current, toNotHaveTrait: trait)
                : mgr.convert(current, toHaveTrait: trait)
            ta[.font] = newFont
            tv.typingAttributes = ta
        }
    }

    static func toggleStrikethrough(on tv: NSTextView) {
        let range = tv.selectedRange()
        if range.length > 0, let storage = tv.textStorage {
            guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
            let current = storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
            storage.beginEditing()
            if current == 0 {
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            } else {
                storage.removeAttribute(.strikethroughStyle, range: range)
            }
            storage.endEditing()
            tv.didChangeText()
        } else {
            var ta = tv.typingAttributes
            let current = ta[.strikethroughStyle] as? Int ?? 0
            if current == 0 {
                ta[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            } else {
                ta.removeValue(forKey: .strikethroughStyle)
            }
            tv.typingAttributes = ta
        }
    }

    static func toggleInlineCode(on tv: NSTextView) {
        let range = tv.selectedRange()
        let codeFont = RichTextEditor.codeFont
        let baseFont = RichTextEditor.defaultFont
        if range.length > 0, let storage = tv.textStorage {
            guard tv.shouldChangeText(in: range, replacementString: nil) else { return }
            let currentFont = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? baseFont
            let on = !isMonospaced(currentFont)
            storage.beginEditing()
            if on {
                storage.addAttribute(.font, value: codeFont, range: range)
                storage.addAttribute(.backgroundColor, value: NSColor.gray.withAlphaComponent(0.18), range: range)
            } else {
                storage.addAttribute(.font, value: baseFont, range: range)
                storage.removeAttribute(.backgroundColor, range: range)
            }
            storage.endEditing()
            tv.didChangeText()
        } else {
            var ta = tv.typingAttributes
            let currentFont = ta[.font] as? NSFont ?? baseFont
            let on = !isMonospaced(currentFont)
            ta[.font] = on ? codeFont : baseFont
            if on { ta[.backgroundColor] = NSColor.gray.withAlphaComponent(0.18) }
            else { ta.removeValue(forKey: .backgroundColor) }
            tv.typingAttributes = ta
        }
    }

    // MARK: - Paragraph styles

    static func toggleCodeBlock(on tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let paraRange = paragraphRange(in: tv)
        guard tv.shouldChangeText(in: paraRange, replacementString: nil) else { return }
        let currentKind = storage.attribute(.glackParagraphKind, at: paraRange.location, effectiveRange: nil) as? String
        let on = currentKind != GlackParagraphKind.codeBlock.rawValue
        storage.beginEditing()
        if on {
            storage.addAttribute(.font, value: RichTextEditor.codeFont, range: paraRange)
            storage.addAttribute(.backgroundColor, value: NSColor.gray.withAlphaComponent(0.15), range: paraRange)
            storage.addAttribute(.glackParagraphKind, value: GlackParagraphKind.codeBlock.rawValue, range: paraRange)
        } else {
            storage.addAttribute(.font, value: RichTextEditor.defaultFont, range: paraRange)
            storage.removeAttribute(.backgroundColor, range: paraRange)
            storage.removeAttribute(.glackParagraphKind, range: paraRange)
        }
        storage.endEditing()
        tv.didChangeText()
    }

    static func toggleLinePrefix(_ prefix: String, secondary: Bool, on tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let paraRange = paragraphRange(in: tv)
        let ns = tv.string as NSString
        let block = ns.substring(with: paraRange)
        let lines = block.components(separatedBy: "\n")
        let allHave = lines.allSatisfy { $0.isEmpty || $0.hasPrefix(prefix) }
        let new = lines.map { line -> String in
            if line.isEmpty { return line }
            if allHave { return String(line.dropFirst(prefix.count)) }
            return line.hasPrefix(prefix) ? line : prefix + line
        }.joined(separator: "\n")
        guard tv.shouldChangeText(in: paraRange, replacementString: new) else { return }
        let replacement = NSMutableAttributedString(string: new, attributes: [
            .font: RichTextEditor.defaultFont,
            .foregroundColor: secondary && !allHave ? NSColor.secondaryLabelColor : NSColor.labelColor
        ])
        storage.replaceCharacters(in: paraRange, with: replacement)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: paraRange.location, length: (new as NSString).length))
    }

    static func insertLink(on tv: NSTextView) {
        guard let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        let ns = tv.string as NSString
        let selected = range.length > 0 ? ns.substring(with: range) : "link"
        guard tv.shouldChangeText(in: range, replacementString: selected) else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: RichTextEditor.defaultFont,
            .link: "https://",
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue
        ]
        storage.replaceCharacters(in: range, with: NSAttributedString(string: selected, attributes: attrs))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location, length: (selected as NSString).length))
    }

    // MARK: - Autoformat helpers

    /// True if the caret sits inside a paragraph that's been tagged as a
    /// code block — used to make Enter insert a newline instead of sending.
    static func isInsideCodeBlock(_ tv: NSTextView) -> Bool {
        guard let storage = tv.textStorage else { return false }
        let loc = tv.selectedRange().location
        let inspect: Int
        if loc > 0 && loc <= storage.length { inspect = loc - 1 }
        else if storage.length > 0 { inspect = 0 }
        else { return false }
        let kind = storage.attribute(.glackParagraphKind, at: inspect, effectiveRange: nil) as? String
        return kind == GlackParagraphKind.codeBlock.rawValue
    }

    /// If the line at the caret is exactly ``` returns its range; the Enter
    /// handler then deletes the line and switches the editor into code-block
    /// typing attributes (Slack's well-known triple-backtick shortcut).
    static func tripleBacktickRange(_ tv: NSTextView) -> NSRange? {
        let ns = tv.string as NSString
        let lineRange = ns.lineRange(for: tv.selectedRange())
        let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
        return line == "```" ? lineRange : nil
    }

    /// Replaces the ``` trigger line with an empty paragraph that will pick
    /// up code-block styling on subsequent typed characters.
    static func enterCodeBlock(_ tv: NSTextView, replacing lineRange: NSRange) {
        guard let storage = tv.textStorage else { return }
        guard tv.shouldChangeText(in: lineRange, replacementString: "") else { return }
        storage.deleteCharacters(in: lineRange)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: lineRange.location, length: 0))
        tv.typingAttributes = [
            .font: RichTextEditor.codeFont,
            .foregroundColor: NSColor.labelColor,
            .backgroundColor: NSColor.gray.withAlphaComponent(0.15),
            .glackParagraphKind: GlackParagraphKind.codeBlock.rawValue
        ]
    }

    // MARK: - Utilities

    static func paragraphRange(in tv: NSTextView) -> NSRange {
        (tv.string as NSString).lineRange(for: tv.selectedRange())
    }

    static func isMonospaced(_ font: NSFont) -> Bool {
        font.isFixedPitch
            || (font.familyName?.contains("Mono") ?? false)
            || (font.familyName?.contains("Menlo") ?? false)
    }
}
