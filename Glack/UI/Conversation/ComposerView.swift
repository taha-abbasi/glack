import AppKit
import SwiftUI

/// Slack-style message composer pinned to the bottom of a conversation.
/// Enter sends, Shift+Enter inserts a newline, ⌘↩ also sends.
///
/// Uses an NSTextView-backed RichTextEditor (not SwiftUI's plain-text
/// TextEditor) so formatting actions render LIVE in the editor — clicking
/// Bold actually bolds the selection on the spot, the way Slack does.
struct ComposerView: View {
    let spaceID: String
    let placeholder: String

    @State private var attributedText: NSAttributedString = NSAttributedString()
    @State private var isSending: Bool = false
    @State private var sendError: String?
    @State private var measuredHeight: CGFloat = 22
    @State private var emojiOpen: Bool = false

    private let minHeight: CGFloat = 22
    private let maxHeight: CGFloat = 160

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let err = sendError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
                    .lineLimit(2)
            }
            VStack(spacing: 0) {
                ComposerFormatting(openEmojiPicker: { emojiOpen.toggle() })
                    .popover(isPresented: $emojiOpen, arrowEdge: .bottom) {
                        EmojiPicker { emoji in
                            emojiOpen = false
                            ComposerInsertion.insertAtCursor(emoji)
                        }
                    }
                Divider().opacity(0.4)
                composerInputRow
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .task(id: spaceID) {
            // Reset composer when switching conversations.
            attributedText = NSAttributedString()
            sendError = nil
        }
    }

    @ViewBuilder
    private var composerInputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            editor
            Button {
                Task { await send() }
            } label: {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend || isSending)
            .help("Send (⌘↩)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if attributedText.length == 0 {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }

            RichTextEditor(
                attributedText: $attributedText,
                placeholder: placeholder,
                minHeight: minHeight,
                maxHeight: maxHeight,
                onSubmit: { Task { await send() } },
                onHeightChange: { measuredHeight = $0 }
            )
            .disabled(isSending)
        }
        .frame(height: max(minHeight, min(maxHeight, measuredHeight)))
    }

    private var canSend: Bool {
        !attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() async {
        let snapshot = NSAttributedString(attributedString: attributedText)
        let markdown = AttributedChatMarkdown.serialize(snapshot)
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isSending = true
        sendError = nil
        attributedText = NSAttributedString()
        do {
            try await Sync.shared.sendMessage(spaceID: spaceID, text: markdown)
        } catch {
            // Restore the original styled draft so the user doesn't lose work.
            attributedText = snapshot
            sendError = "Couldn't send: \(error.localizedDescription)"
        }
        isSending = false
    }
}
