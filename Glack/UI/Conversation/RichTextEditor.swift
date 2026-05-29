import AppKit
import SwiftUI

/// NSViewRepresentable wrapping an NSTextView with attributed-string editing.
/// This is the standard macOS path for WYSIWYG rich text (the same building
/// block Mail, Notes, and TextEdit use). Inline styles (bold/italic/strike/
/// code) and paragraph styles (lists, quotes, code blocks) are applied via
/// NSAttributedString attributes and rendered live as the user types.
struct RichTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    let placeholder: String
    let minHeight: CGFloat
    let maxHeight: CGFloat
    let onSubmit: () -> Void
    var onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false

        let textView = TaggedTextView()
        textView.glackEditorTag = true
        textView.isRichText = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.importsGraphics = false
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.usesInspectorBar = false
        textView.smartInsertDeleteEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.drawsBackground = false
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 0, height: 4)
        textView.font = Self.defaultFont
        textView.typingAttributes = [.font: Self.defaultFont, .foregroundColor: NSColor.labelColor]
        textView.delegate = context.coordinator
        textView.textStorage?.setAttributedString(attributedText)

        scroll.documentView = textView
        context.coordinator.textView = textView

        // Initial height report so the SwiftUI frame matches the editor.
        DispatchQueue.main.async {
            context.coordinator.reportHeight()
        }
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Only push attributedText INTO the view when an external setter
        // (send/clear/restore) actually changed it. Otherwise we'd clobber
        // the user's caret on every keystroke.
        if !textView.attributedString().isEqual(to: attributedText) {
            let selection = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributedText)
            // Restore selection if it's still in range.
            if selection.location <= attributedText.length {
                let safe = NSRange(
                    location: selection.location,
                    length: min(selection.length, attributedText.length - selection.location)
                )
                textView.setSelectedRange(safe)
            }
        }
    }

    static let defaultFont = NSFont.systemFont(ofSize: 13)
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.attributedText = NSAttributedString(attributedString: tv.attributedString())
            reportHeight()
        }

        /// Intercept the Return key:
        ///   * Shift+Return                       → newline (default)
        ///   * Return inside a code-block paragraph → newline (stay in block)
        ///   * Return on a line that is exactly ``` → enter code-block mode
        ///   * Plain Return otherwise               → send
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSEvent.modifierFlags.contains(.shift) { return false }
            if RichTextFormatting.isInsideCodeBlock(tv) { return false }
            if let range = RichTextFormatting.tripleBacktickRange(tv) {
                RichTextFormatting.enterCodeBlock(tv, replacing: range)
                return true
            }
            parent.onSubmit()
            return true
        }

        func reportHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc).height
            let inset = tv.textContainerInset.height * 2
            let h = max(parent.minHeight, min(parent.maxHeight, used + inset))
            parent.onHeightChange(h)
        }
    }
}

/// NSTextView subclass that publishes a discoverability marker so other
/// surfaces (the format toolbar, the emoji picker) can find this exact
/// view in the window hierarchy and operate on its attributed text.
///
/// Also captures Slack's documented formatting shortcuts via
/// `performKeyEquivalent(with:)` — NSTextView would otherwise route ⌘B/⌘I
/// to its built-in NSFontManager actions, which don't update our typing
/// attributes or paragraph kind the same way our toolbar does.
final class TaggedTextView: NSTextView {
    var glackEditorTag: Bool = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if mods == .command {
            switch chars {
            case "b":
                RichTextFormatting.toggleTrait(.boldFontMask, on: self)
                return true
            case "i":
                RichTextFormatting.toggleTrait(.italicFontMask, on: self)
                return true
            default: break
            }
        }
        if mods == [.command, .shift] {
            switch chars {
            case "x":
                RichTextFormatting.toggleStrikethrough(on: self)
                return true
            case "c":
                RichTextFormatting.toggleInlineCode(on: self)
                return true
            case "u":
                RichTextFormatting.insertLink(on: self)
                return true
            case "8":
                RichTextFormatting.toggleLinePrefix("• ", secondary: false, on: self)
                return true
            case "9":
                RichTextFormatting.toggleLinePrefix("▎ ", secondary: true, on: self)
                return true
            default: break
            }
        }
        if mods == [.command, .option, .shift] && chars == "c" {
            RichTextFormatting.toggleCodeBlock(on: self)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
