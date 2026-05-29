import AppKit
import SwiftUI

/// Lightweight composer for thread replies. Same rich-text editing as the
/// main composer, but on send it includes `threadName` so the Chat API
/// attaches the reply to the open thread. Kept as a separate view so the
/// state (attributed text, send state) is isolated from the conversation's
/// main composer.
struct ThreadComposerView: View {
    let spaceID: String
    let threadName: String

    @State private var attributedText: NSAttributedString = NSAttributedString()
    @State private var isSending: Bool = false
    @State private var sendError: String?
    @State private var measuredHeight: CGFloat = 22
    @State private var emojiOpen: Bool = false

    private let minHeight: CGFloat = 22
    private let maxHeight: CGFloat = 140

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
                inputRow
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.gray.opacity(0.3), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .task(id: threadName) {
            attributedText = NSAttributedString()
            sendError = nil
        }
    }

    @ViewBuilder
    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            editor
            Button {
                Task { await send() }
            } label: {
                if isSending {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!canSend || isSending)
            .help("Reply (⌘↩)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var editor: some View {
        ZStack(alignment: .topLeading) {
            if attributedText.length == 0 {
                Text("Reply in thread…")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .allowsHitTesting(false)
            }
            RichTextEditor(
                attributedText: $attributedText,
                placeholder: "Reply in thread…",
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
            try await Sync.shared.sendMessage(spaceID: spaceID, text: markdown, threadName: threadName)
        } catch {
            attributedText = snapshot
            sendError = "Couldn't reply: \(error.localizedDescription)"
        }
        isSending = false
    }
}
