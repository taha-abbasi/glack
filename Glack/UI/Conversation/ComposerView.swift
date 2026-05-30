import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var pendingAttachments: [PendingAttachment] = []
    @State private var dragHighlighted: Bool = false
    @State private var autocompleteState = EmojiAutocompleteState()

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
                if !pendingAttachments.isEmpty {
                    attachmentChipsRow
                    Divider().opacity(0.4)
                }
                composerInputRow
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(dragHighlighted ? Color.accentColor : Color.gray.opacity(0.3),
                            lineWidth: dragHighlighted ? 1.5 : 0.5)
            )
            .overlay(alignment: .topLeading) {
                // Floating emoji autocomplete popup. Anchored to the top-left
                // of the composer wrapper and offset upward so it sits ABOVE
                // the composer like Slack's. Click → commit via the editor's
                // commitAutocomplete path.
                if autocompleteState.isActive {
                    EmojiAutocompletePopup(state: autocompleteState) { entry in
                        autocompleteState.selectedIndex = autocompleteState.matches.firstIndex { $0.id == entry.id } ?? 0
                        // Commit via the editor — finds the underlying NSTextView
                        // and replaces the `:prefix` with the emoji.
                        if let tv = ComposerEditing.findEditor() {
                            commitEmojiViaEditor(tv: tv, entry: entry)
                        }
                    }
                    .offset(y: -popupOffset(for: autocompleteState.matches.count))
                    .padding(.leading, 10)
                    .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
        .onDrop(of: [.fileURL], isTargeted: $dragHighlighted) { providers in
            handleDroppedItems(providers)
            return true
        }
        .task(id: spaceID) {
            // Reset composer when switching conversations.
            attributedText = NSAttributedString()
            sendError = nil
            pendingAttachments = []
        }
    }

    @ViewBuilder
    private var composerInputRow: some View {
        HStack(alignment: .bottom, spacing: 8) {
            Button {
                pickFiles()
            } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Attach file")
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
    private var attachmentChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(pendingAttachments) { a in
                    AttachmentChip(attachment: a) {
                        pendingAttachments.removeAll { $0.id == a.id }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
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
                onHeightChange: { measuredHeight = $0 },
                autocompleteState: autocompleteState
            )
            .disabled(isSending)
        }
        .frame(height: max(minHeight, min(maxHeight, measuredHeight)))
    }

    private var canSend: Bool {
        let hasText = !attributedText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReadyAttachment = pendingAttachments.contains { if case .uploaded = $0.state { return true } else { return false } }
        return hasText || hasReadyAttachment
    }

    /// Pixel height of the autocomplete popup — varies with row count
    /// (each row ~30pt + ~22pt footer + ~4pt padding).
    private func popupOffset(for matchCount: Int) -> CGFloat {
        let rowHeight: CGFloat = 30
        let footer: CGFloat = 22
        let padding: CGFloat = 8
        return CGFloat(matchCount) * rowHeight + footer + padding
    }

    /// Click-to-commit pathway — locate the editor's NSTextView and call
    /// into RichTextEditor.Coordinator's existing commit logic via a
    /// direct replace. (Coordinator's commitAutocomplete is private to
    /// itself; the duplicated logic here is small.)
    private func commitEmojiViaEditor(tv: NSTextView, entry: EmojiCatalog.Entry) {
        guard let storage = tv.textStorage, let prefix = autocompleteState.prefix else { return }
        let sel = tv.selectedRange()
        let removeLen = (prefix as NSString).length + 1
        guard sel.location - removeLen >= 0 else { return }
        let removeRange = NSRange(location: sel.location - removeLen, length: removeLen)
        let replacement = entry.emoji + " "
        guard tv.shouldChangeText(in: removeRange, replacementString: replacement) else { return }
        let attrs = tv.typingAttributes
        storage.replaceCharacters(in: removeRange,
                                   with: NSAttributedString(string: replacement, attributes: attrs))
        tv.didChangeText()
        let newCaret = removeRange.location + (replacement as NSString).length
        tv.setSelectedRange(NSRange(location: newCaret, length: 0))
        autocompleteState.dismiss()
        tv.window?.makeFirstResponder(tv)
    }

    // MARK: - File picking

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.canCreateDirectories = false
        panel.message = "Choose files to attach"
        panel.begin { result in
            guard result == .OK else { return }
            for url in panel.urls {
                Task { await upload(url) }
            }
        }
    }

    private func handleDroppedItems(_ providers: [NSItemProvider]) {
        for p in providers {
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in await upload(url) }
            }
        }
    }

    /// Upload one file. Adds a chip immediately in `.uploading` state so the
    /// user sees progress; updates to `.uploaded` with the resourceName on
    /// success or `.failed` with the error on failure.
    @MainActor
    private func upload(_ url: URL) async {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let attachment = PendingAttachment(
            fileURL: url,
            filename: url.lastPathComponent,
            sizeBytes: size,
            state: .uploading
        )
        pendingAttachments.append(attachment)
        do {
            let resourceName = try await ChatAPIClient.shared.uploadAttachment(spaceID: spaceID, fileURL: url)
            if let i = pendingAttachments.firstIndex(where: { $0.id == attachment.id }) {
                pendingAttachments[i].state = .uploaded(resourceName: resourceName)
            }
        } catch {
            if let i = pendingAttachments.firstIndex(where: { $0.id == attachment.id }) {
                pendingAttachments[i].state = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Send

    private func send() async {
        let snapshot = NSAttributedString(attributedString: attributedText)
        let markdown = AttributedChatMarkdown.serialize(snapshot)
        let resourceNames: [String] = pendingAttachments.compactMap {
            if case .uploaded(let name) = $0.state { return name } else { return nil }
        }
        let hasText = !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard hasText || !resourceNames.isEmpty else { return }
        isSending = true
        sendError = nil
        attributedText = NSAttributedString()
        let attachmentsSnapshot = pendingAttachments
        pendingAttachments = []
        do {
            try await Sync.shared.sendMessage(
                spaceID: spaceID,
                text: markdown,
                attachmentResourceNames: resourceNames
            )
        } catch {
            // Restore the styled draft AND the attachment chips so the user
            // doesn't lose their work.
            attributedText = snapshot
            pendingAttachments = attachmentsSnapshot
            sendError = "Couldn't send: \(error.localizedDescription)"
        }
        isSending = false
    }
}

// MARK: - Pending-attachment model + chip

struct PendingAttachment: Identifiable {
    let id: UUID = UUID()
    let fileURL: URL
    let filename: String
    let sizeBytes: Int
    var state: State

    enum State {
        case uploading
        case uploaded(resourceName: String)
        case failed(String)
    }
}

private struct AttachmentChip: View {
    let attachment: PendingAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(attachment.filename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(secondaryLine)
                    .font(.system(size: 10))
                    .foregroundStyle(stateColor)
                    .lineLimit(1)
            }
            stateAccessory
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(3)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(borderColor, lineWidth: 0.5)
        )
        .frame(maxWidth: 280, alignment: .leading)
    }

    private var icon: String {
        let ext = attachment.fileURL.pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "pdf": return "doc.richtext"
        case "mp4", "mov": return "video"
        case "mp3", "wav", "m4a": return "waveform"
        case "zip": return "doc.zipper"
        default: return "doc"
        }
    }

    private var secondaryLine: String {
        switch attachment.state {
        case .uploading: return "Uploading… · \(formatBytes(attachment.sizeBytes))"
        case .uploaded:  return formatBytes(attachment.sizeBytes)
        case .failed(let why): return "Failed: \(why)"
        }
    }

    private var stateColor: Color {
        switch attachment.state {
        case .uploading: return .secondary
        case .uploaded:  return .secondary
        case .failed:    return .red
        }
    }

    private var borderColor: Color {
        switch attachment.state {
        case .uploaded:  return Color.green.opacity(0.4)
        case .failed:    return Color.red.opacity(0.6)
        case .uploading: return Color.gray.opacity(0.3)
        }
    }

    @ViewBuilder
    private var stateAccessory: some View {
        switch attachment.state {
        case .uploading:
            ProgressView().controlSize(.small).scaleEffect(0.7)
        case .uploaded:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.red)
        }
    }

    private func formatBytes(_ b: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(b))
    }
}
