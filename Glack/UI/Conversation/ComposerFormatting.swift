import AppKit
import SwiftUI

/// WYSIWYG formatting toolbar above the rich composer. Each button toggles
/// font traits, paragraph styles, or character attributes on the underlying
/// NSTextView so the formatting renders LIVE in the composer the way Slack /
/// Chat web do — not by inserting markdown markers.
///
/// All formatting actions delegate to RichTextFormatting (the same helpers
/// the keyboard-shortcut handler in TaggedTextView calls), so toolbar +
/// hotkeys are guaranteed to behave identically. Tooltips include the
/// shortcut so users discover them naturally.
struct ComposerFormatting: View {
    var openEmojiPicker: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            ToolbarButton(systemName: "bold", help: "Bold  ⌘B") {
                act { RichTextFormatting.toggleTrait(.boldFontMask, on: $0) }
            }
            ToolbarButton(systemName: "italic", help: "Italic  ⌘I") {
                act { RichTextFormatting.toggleTrait(.italicFontMask, on: $0) }
            }
            ToolbarButton(systemName: "strikethrough", help: "Strikethrough  ⌘⇧X") {
                act { RichTextFormatting.toggleStrikethrough(on: $0) }
            }
            divider
            ToolbarButton(systemName: "list.bullet", help: "Bulleted list  ⌘⇧8") {
                act { RichTextFormatting.toggleLinePrefix("• ", secondary: false, on: $0) }
            }
            divider
            ToolbarButton(systemName: "text.quote", help: "Block quote  ⌘⇧9") {
                act { RichTextFormatting.toggleLinePrefix("▎ ", secondary: true, on: $0) }
            }
            ToolbarButton(systemName: "link", help: "Insert link  ⌘⇧U") {
                act { RichTextFormatting.insertLink(on: $0) }
            }
            divider
            ToolbarButton(systemName: "chevron.left.forwardslash.chevron.right", help: "Code  ⌘⇧C") {
                act { RichTextFormatting.toggleInlineCode(on: $0) }
            }
            ToolbarButton(systemName: "curlybraces", help: "Code block  ⌘⌥⇧C") {
                act { RichTextFormatting.toggleCodeBlock(on: $0) }
            }
            Spacer(minLength: 0)
            ToolbarButton(systemName: "face.smiling", help: "Emoji") { openEmojiPicker() }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
    }

    private var divider: some View {
        Divider().frame(height: 14).padding(.horizontal, 4)
    }

    /// Run a formatting action against the composer's editor and put focus
    /// back on it so the user can keep typing.
    private func act(_ op: (NSTextView) -> Void) {
        guard let tv = ComposerEditing.findEditor() else { return }
        op(tv)
        tv.window?.makeFirstResponder(tv)
    }
}

/// Cross-view helper: locate the composer's editable NSTextView (the one
/// tagged by RichTextEditor) regardless of current focus. Used by the
/// formatting toolbar and the emoji picker.
enum ComposerEditing {
    static func findEditor() -> NSTextView? {
        for window in NSApp.windows {
            if let tv = walk(window.contentView) { return tv }
        }
        return nil
    }

    private static func walk(_ view: NSView?) -> NSTextView? {
        guard let view else { return nil }
        if let tv = view as? TaggedTextView, tv.glackEditorTag { return tv }
        for sub in view.subviews {
            if let tv = walk(sub) { return tv }
        }
        return nil
    }
}

/// Helper for inserting an emoji at the current caret position with the
/// editor's typing attributes preserved.
enum ComposerInsertion {
    static func insertAtCursor(_ s: String) {
        guard let tv = ComposerEditing.findEditor(), let storage = tv.textStorage else { return }
        let range = tv.selectedRange()
        guard tv.shouldChangeText(in: range, replacementString: s) else { return }
        let attrs = tv.typingAttributes
        storage.replaceCharacters(in: range, with: NSAttributedString(string: s, attributes: attrs))
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: range.location + (s as NSString).length, length: 0))
        tv.window?.makeFirstResponder(tv)
    }
}

/// Toolbar button with hover background, pointer cursor, and a non-blocking
/// custom tooltip. See memory/swiftui-popover-tooltip-eats-clicks — popovers
/// would eat the dismissal click and the button below would never fire.
private struct ToolbarButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var hovering = false
    @State private var tipVisible = false
    @State private var tipTask: Task<Void, Never>?

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .frame(width: 28, height: 24)
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovering ? Color.primary.opacity(0.10) : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover in
            withAnimation(.easeOut(duration: 0.08)) { hovering = hover }
            tipTask?.cancel()
            if hover {
                NSCursor.pointingHand.set()
                tipTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    guard !Task.isCancelled, hovering else { return }
                    withAnimation(.easeIn(duration: 0.08)) { tipVisible = true }
                }
            } else {
                NSCursor.arrow.set()
                withAnimation(.easeOut(duration: 0.08)) { tipVisible = false }
            }
        }
        .overlay(alignment: .top) {
            if tipVisible {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.black.opacity(0.85))
                    )
                    .fixedSize()
                    .offset(y: 30)
                    .allowsHitTesting(false)
                    .zIndex(100)
            }
        }
    }
}
