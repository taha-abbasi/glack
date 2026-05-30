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
    /// Optional autocomplete state — set by ComposerView, mutated by
    /// Coordinator as the user types `:foo` patterns. When nil, no
    /// autocomplete UI runs.
    var autocompleteState: EmojiAutocompleteState? = nil

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
        // Critical: refresh the Coordinator's captured parent on every
        // update so its `onSubmit` / `onHeightChange` / `autocompleteState`
        // closures point at the latest ComposerView struct. Without this,
        // switching spaces (or threads, or any owning view re-create) leaves
        // the Coordinator holding the ORIGINAL parent — Enter would route
        // sends to whichever spaceID was open when the view first rendered,
        // not the currently visible one. (Same class of bug as the sticky-
        // thread `.id(threadID)` fix, but on the NSViewRepresentable side.)
        context.coordinator.parent = self

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

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        weak var textView: NSTextView?
        /// Guard against re-entrance — calling `didChangeText()` from an
        /// autoformat path would otherwise trigger this notification again.
        private var isAutoformatting = false

        init(_ parent: RichTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.attributedText = NSAttributedString(attributedString: tv.attributedString())
            reportHeight()
            if !isAutoformatting {
                applyAutoformat(tv: tv)
            }
            updateAutocomplete(tv: tv)
        }

        /// Detect the current `:prefix` the user is typing (if any) and
        /// push it into the shared autocomplete state. Walks at most ~32
        /// chars back from the caret looking for the opening `:`; any
        /// whitespace or non-alphanumeric breaks the pattern.
        private func updateAutocomplete(tv: NSTextView) {
            guard let state = parent.autocompleteState else { return }
            let sel = tv.selectedRange()
            guard sel.length == 0 else { state.dismiss(); return }
            let ns = tv.string as NSString
            let caret = sel.location
            guard caret > 0, caret <= ns.length else { state.dismiss(); return }
            var i = caret - 1
            while i >= 0, (caret - i) < 32 {
                let c = ns.substring(with: NSRange(location: i, length: 1))
                if c == ":" {
                    let prefix = ns.substring(with: NSRange(location: i + 1, length: caret - i - 1))
                    state.update(prefix: prefix)
                    return
                }
                if c == " " || c == "\n" || c == "\t" {
                    state.dismiss()
                    return
                }
                i -= 1
            }
            state.dismiss()
        }

        /// Replace `:prefix` immediately before the caret with the picked
        /// emoji + a trailing space. Called both from keyboard commit
        /// (Tab/Enter) and from clicking a popup row.
        func commitAutocomplete(entry: EmojiCatalog.Entry) {
            guard let tv = textView, let storage = tv.textStorage,
                  let state = parent.autocompleteState, let prefix = state.prefix else { return }
            let sel = tv.selectedRange()
            let prefixLen = (prefix as NSString).length
            let removeLen = prefixLen + 1  // +1 for the leading ":"
            let removeRange = NSRange(location: sel.location - removeLen, length: removeLen)
            guard removeRange.location >= 0 else { state.dismiss(); return }
            let replacement = entry.emoji + " "
            guard tv.shouldChangeText(in: removeRange, replacementString: replacement) else {
                state.dismiss(); return
            }
            let attrs = tv.typingAttributes
            storage.replaceCharacters(in: removeRange,
                                       with: NSAttributedString(string: replacement, attributes: attrs))
            tv.didChangeText()
            let newCaret = removeRange.location + (replacement as NSString).length
            tv.setSelectedRange(NSRange(location: newCaret, length: 0))
            state.dismiss()
        }

        /// Slack-style typing autoformat. Fires on every text change; cheap
        /// (just checks the last character + walks back at most ~30 chars).
        ///   `*foo* ` → **foo**           (bold)
        ///   `_foo_ ` → _foo_             (italic)
        ///   `~foo~ ` → ~foo~             (strikethrough)
        ///   `` `foo` `` → `foo`           (inline code)
        ///   `:smile:` → 😀                (emoji shortcode, no space needed)
        /// Skips entirely inside code-block paragraphs (those markers stay
        /// literal there).
        private func applyAutoformat(tv: NSTextView) {
            guard !RichTextFormatting.isInsideCodeBlock(tv) else { return }
            guard let storage = tv.textStorage else { return }
            let sel = tv.selectedRange()
            guard sel.length == 0, sel.location >= 2, sel.location <= storage.length else { return }
            let ns = storage.string as NSString
            let justTyped = ns.substring(with: NSRange(location: sel.location - 1, length: 1))

            isAutoformatting = true
            defer { isAutoformatting = false }

            switch justTyped {
            case " ":
                tryMarkerAutoformat(tv: tv, storage: storage, ns: ns, caretLocation: sel.location)
            case ":":
                tryEmojiAutoformat(tv: tv, storage: storage, ns: ns, caretLocation: sel.location)
            default:
                break
            }
        }

        /// Detects `*X*`, `_X_`, `~X~`, `` `X` `` immediately before the
        /// just-typed space. Wraps X with the corresponding attributes and
        /// removes the markers.
        private func tryMarkerAutoformat(tv: NSTextView, storage: NSTextStorage,
                                         ns: NSString, caretLocation: Int) {
            let closerLoc = caretLocation - 2  // char before the space
            guard closerLoc >= 0 else { return }
            let closer = ns.substring(with: NSRange(location: closerLoc, length: 1))

            enum Marker { case bold, italic, strike, code }
            let kind: Marker
            switch closer {
            case "*": kind = .bold
            case "_": kind = .italic
            case "~": kind = .strike
            case "`": kind = .code
            default: return
            }

            // Walk back to find the matching opening marker, bounded so we
            // don't scan the whole document.
            var i = closerLoc - 1
            var openerLoc: Int? = nil
            while i >= 0, (closerLoc - i) < 64 {
                let c = ns.substring(with: NSRange(location: i, length: 1))
                if c == closer { openerLoc = i; break }
                if c == " " || c == "\n" || c == "\t" { return }
                i -= 1
            }
            guard let opener = openerLoc, closerLoc - opener > 1 else { return }
            let contentRange = NSRange(location: opener + 1, length: closerLoc - opener - 1)
            let content = ns.substring(with: contentRange)
            guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return }

            // Apply attributes
            let baseFont = RichTextEditor.defaultFont
            let codeFont = RichTextEditor.codeFont
            let mgr = NSFontManager.shared
            storage.beginEditing()
            switch kind {
            case .bold:
                storage.enumerateAttribute(.font, in: contentRange, options: []) { val, sub, _ in
                    let f = (val as? NSFont) ?? baseFont
                    storage.addAttribute(.font, value: mgr.convert(f, toHaveTrait: .boldFontMask), range: sub)
                }
            case .italic:
                storage.enumerateAttribute(.font, in: contentRange, options: []) { val, sub, _ in
                    let f = (val as? NSFont) ?? baseFont
                    storage.addAttribute(.font, value: mgr.convert(f, toHaveTrait: .italicFontMask), range: sub)
                }
            case .strike:
                storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: contentRange)
            case .code:
                storage.addAttribute(.font, value: codeFont, range: contentRange)
                storage.addAttribute(.backgroundColor, value: NSColor.gray.withAlphaComponent(0.18), range: contentRange)
            }
            // Delete markers — closer first so the opener's offset is still
            // valid when we delete it.
            storage.deleteCharacters(in: NSRange(location: closerLoc, length: 1))
            storage.deleteCharacters(in: NSRange(location: opener, length: 1))
            storage.endEditing()
            tv.didChangeText()

            // After removing two markers, the caret has shifted by -2.
            tv.setSelectedRange(NSRange(location: caretLocation - 2, length: 0))
            // Reset typing attrs so subsequent typing doesn't inherit the
            // auto-applied style.
            tv.typingAttributes = [.font: baseFont, .foregroundColor: NSColor.labelColor]
        }

        /// Detects `:name:` immediately before the caret and expands to the
        /// matching Unicode emoji. Trigger is the just-typed closing colon
        /// — no extra space needed. Looks up against the bundled
        /// EmojiCatalog so any of the ~250 shortcodes work (`:smile:`,
        /// `:thumbsup:`, `:tada:`, etc).
        private func tryEmojiAutoformat(tv: NSTextView, storage: NSTextStorage,
                                        ns: NSString, caretLocation: Int) {
            let closingColonLoc = caretLocation - 1  // the colon we just typed
            // Walk back to find the opening colon, bounded
            var i = closingColonLoc - 1
            var openingLoc: Int? = nil
            while i >= 0, (closingColonLoc - i) < 32 {
                let c = ns.substring(with: NSRange(location: i, length: 1))
                if c == ":" { openingLoc = i; break }
                if c == " " || c == "\n" || c == "\t" { return }
                i -= 1
            }
            guard let opening = openingLoc, closingColonLoc - opening > 1 else { return }
            let nameRange = NSRange(location: opening + 1, length: closingColonLoc - opening - 1)
            let name = ns.substring(with: nameRange).lowercased()
            // Lookup
            let allEntries = EmojiCatalog.categories.flatMap(\.entries)
            guard let entry = allEntries.first(where: { $0.name == name }) else { return }
            // Replace :name: with the emoji
            let fullRange = NSRange(location: opening, length: (closingColonLoc - opening) + 1)
            let replacement = NSAttributedString(string: entry.emoji, attributes: tv.typingAttributes)
            storage.beginEditing()
            storage.replaceCharacters(in: fullRange, with: replacement)
            storage.endEditing()
            tv.didChangeText()
            let newCaret = opening + (entry.emoji as NSString).length
            tv.setSelectedRange(NSRange(location: newCaret, length: 0))
        }

        /// Intercept the Return key:
        ///   * Shift+Return                                    → newline (default)
        ///   * Return inside a code-block, line is empty       → exit the block
        ///   * Return inside a code-block, line has content    → newline (stay)
        ///   * Return on a line that is exactly ```            → enter code-block mode
        ///   * Plain Return otherwise                          → send
        func textView(_ tv: NSTextView, doCommandBy selector: Selector) -> Bool {
            // Autocomplete intercepts come FIRST — when the popup is open
            // the arrow keys / Tab / Enter / Esc drive its selection
            // rather than the editor.
            if let state = parent.autocompleteState, state.isActive {
                switch selector {
                case #selector(NSResponder.moveDown(_:)):
                    state.moveSelection(by: 1); return true
                case #selector(NSResponder.moveUp(_:)):
                    state.moveSelection(by: -1); return true
                case #selector(NSResponder.insertTab(_:)),
                     #selector(NSResponder.insertNewline(_:)):
                    if let entry = state.matches[safe: state.selectedIndex] {
                        commitAutocomplete(entry: entry)
                    }
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    state.dismiss(); return true
                default:
                    break
                }
            }

            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if NSEvent.modifierFlags.contains(.shift) { return false }
            if RichTextFormatting.isInsideCodeBlock(tv) {
                if RichTextFormatting.exitCodeBlockIfOnEmptyLine(tv) { return true }
                return false
            }
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

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
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
