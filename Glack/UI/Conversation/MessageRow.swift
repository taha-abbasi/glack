import AppKit
import SwiftUI

struct MessageRow: View {
    let message: MessageRecord
    @Bindable var users: UsersObserver
    /// Number of messages in this row's thread (parent + replies). When > 1,
    /// the row shows a "View thread" affordance. Nil = caller doesn't track
    /// thread counts (thread side panel itself, search results, etc.).
    var threadReplyCount: Int? = nil
    /// Callback fired when the user clicks "View thread" — opens the side
    /// panel scoped to this row's threadId.
    var onOpenThread: ((String) -> Void)? = nil

    @State private var rowHovering: Bool = false
    @State private var toolbarHovering: Bool = false
    @State private var pickerOpen: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var deleteError: String?
    @State private var isEditing: Bool = false
    @State private var editDraft: String = ""
    @State private var editError: String?
    @FocusState private var editFocused: Bool

    private var isOwnMessage: Bool {
        guard let me = Session.shared.currentUserID, let sid = message.senderId else { return false }
        return me == sid
    }

    private var hasThreadReplies: Bool {
        (threadReplyCount ?? 0) > 1
    }

    /// True when the cursor is over either the row or the floating toolbar,
    /// OR when a popover/dialog/alert anchored to the toolbar is open. The
    /// toolbar (and any view attached to it, like the delete confirmation
    /// dialog) must stay mounted while the user is interacting with one of
    /// these — otherwise the dialog flashes and disappears the moment the
    /// menu closes and the cursor leaves the row.
    private var hovering: Bool {
        rowHovering || toolbarHovering || pickerOpen || showDeleteConfirm || deleteError != nil
    }

    /// Deep link to this message in Chat web — used by the "Copy link"
    /// menu item. Format: `https://chat.google.com/room/{spaceId}/{messageId}`
    /// matches what Chat web's "Copy link" produces.
    private var chatWebLink: String {
        let spaceID = message.spaceId.replacingOccurrences(of: "spaces/", with: "")
        let messageBase = message.id.replacingOccurrences(of: "spaces/\(spaceID)/messages/", with: "")
        return "https://chat.google.com/room/\(spaceID)/\(messageBase)"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(senderDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                    Text(timeString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if isEditing {
                    editEditor
                } else {
                    Text(renderedBody)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if let _ = message.updatedAt {
                        Text("(edited)")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                if message.attachmentCount > 0 {
                    Label("\(message.attachmentCount) attachment\(message.attachmentCount == 1 ? "" : "s")",
                          systemImage: "paperclip")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !message.reactions.isEmpty {
                    reactionStrip
                }
                threadAffordance
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            rowHovering
                ? Color.primary.opacity(0.04)
                : Color.clear
        )
        .contentShape(Rectangle())
        .overlay(alignment: .topTrailing) {
            if hovering && !message.id.hasPrefix("pending-") {
                hoverToolbar
                    .padding(.trailing, 8)
                    .onHover { toolbarHovering = $0 }
            }
        }
        .onHover { hover in
            withAnimation(.easeOut(duration: 0.08)) { rowHovering = hover }
        }
    }

    // MARK: - Reaction strip

    private var reactionStrip: some View {
        HStack(spacing: 4) {
            ForEach(Array(message.reactions.enumerated()), id: \.offset) { _, summary in
                ReactionChip(summary: summary, messageID: message.id)
            }
        }
        .padding(.top, 2)
    }

    // MARK: - Hover toolbar

    private var hoverToolbar: some View {
        HStack(spacing: 0) {
            // Reaction picker
            Button {
                pickerOpen.toggle()
            } label: {
                Image(systemName: "face.smiling")
                    .font(.system(size: 13))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .buttonStyle(.plain)
            .help("Add reaction")
            .popover(isPresented: $pickerOpen, arrowEdge: .top) {
                EmojiPicker { emoji in
                    pickerOpen = false
                    Task { await Sync.shared.addReaction(messageName: message.id, unicode: emoji) }
                }
            }

            // Reply in thread — only meaningful when the message is part of
            // a thread (threadId != nil ⟹ the space supports threads).
            if let tid = message.threadId, let cb = onOpenThread {
                Divider().frame(height: 16)
                Button {
                    cb(tid)
                } label: {
                    Image(systemName: "arrowshape.turn.up.left")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .help("Reply in thread")
            }

            // Overflow menu — Copy text + Copy link always; Edit + Delete on own messages only.
            Divider().frame(height: 16)
            Menu {
                Button {
                    let text = message.textPlain ?? message.text ?? ""
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy message text", systemImage: "doc.on.doc")
                }
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(chatWebLink, forType: .string)
                } label: {
                    Label("Copy link to message", systemImage: "link")
                }
                if isOwnMessage {
                    Divider()
                    Button {
                        editDraft = message.text ?? message.textPlain ?? ""
                        isEditing = true
                    } label: {
                        Label("Edit message", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("Delete message", systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More actions")
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
        .confirmationDialog(
            hasThreadReplies ? "Delete this message and its replies?" : "Delete this message?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let force = hasThreadReplies
                Task {
                    do {
                        try await Sync.shared.deleteMessage(messageName: message.id, force: force)
                    } catch {
                        deleteError = "Couldn't delete: \(error.localizedDescription)"
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if hasThreadReplies {
                Text("This will also delete \(threadReplyCount! - 1) thread \(threadReplyCount! - 1 == 1 ? "reply" : "replies"). This can't be undone.")
            } else {
                Text("This can't be undone.")
            }
        }
        .alert("Delete failed", isPresented: Binding(
            get: { deleteError != nil },
            set: { if !$0 { deleteError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deleteError ?? "")
        }
    }

    // MARK: - Avatar / name / time

    @ViewBuilder
    private var avatar: some View {
        CachedAvatar(url: users.photoURL(for: message.senderId)) { initialsAvatar }
            .frame(width: 28, height: 28)
            .clipShape(Circle())
    }

    private var initialsAvatar: some View {
        Circle()
            .fill(Color.secondary.opacity(0.18))
            .frame(width: 28, height: 28)
            .overlay {
                if let resolved = resolvedName {
                    Text(initials(from: resolved))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
    }

    private var resolvedName: String? {
        if let n = users.displayName(for: message.senderId), !n.isEmpty { return n }
        if let s = message.senderName, !s.isEmpty { return s }
        return nil
    }

    private var senderDisplayName: String {
        if let n = resolvedName { return n }
        if let id = message.senderId {
            let tail = String(id.suffix(4))
            return "Member \(tail)"
        }
        return "Unknown"
    }

    /// Apply Chat markdown over the raw text. Mentions are resolved inside
    /// the parser via the `users` observer.
    private var renderedBody: AttributedString {
        ChatMarkdown.render(message.text ?? "", users: users)
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    /// Inline editor that replaces the message text when the user picks
    /// Edit from the ⋯ menu. Enter saves, Esc cancels, Shift+Enter inserts
    /// a newline — matches Slack's edit affordance. Uses SwiftUI TextField
    /// (axis: .vertical) rather than the rich RichTextEditor to keep the
    /// edit small and lightweight.
    @ViewBuilder
    private var editEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("Edit message", text: $editDraft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...8)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.accentColor.opacity(0.5), lineWidth: 1)
                )
                .focused($editFocused)
                .onKeyPress(keys: [.return]) { press in
                    if press.modifiers.contains(.shift) { return .ignored }
                    Task { await commitEdit() }
                    return .handled
                }
                .onKeyPress(.escape) {
                    cancelEdit()
                    return .handled
                }
                .onAppear { editFocused = true }
            HStack(spacing: 8) {
                Text("Esc to cancel · Return to save")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { cancelEdit() }
                    .controlSize(.small)
                Button("Save") {
                    Task { await commitEdit() }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(editDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          || editDraft == (message.text ?? ""))
            }
            if let err = editError {
                Text(err).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
    }

    private func commitEdit() async {
        let newText = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newText.isEmpty, newText != (message.text ?? "") else {
            cancelEdit()
            return
        }
        editError = nil
        do {
            try await Sync.shared.editMessage(messageName: message.id, newText: newText)
            isEditing = false
        } catch {
            editError = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func cancelEdit() {
        isEditing = false
        editDraft = ""
        editError = nil
    }

    /// "View thread · N replies" link, shown when this row's thread has
    /// more than just the parent. Tapping calls back into the parent view
    /// to open the thread side panel.
    @ViewBuilder
    private var threadAffordance: some View {
        if let count = threadReplyCount, count > 1, let threadID = message.threadId, let cb = onOpenThread {
            Button {
                cb(threadID)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.system(size: 10, weight: .medium))
                    Text("\(count - 1) repl\(count == 2 ? "y" : "ies")")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor.opacity(0.10))
                )
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
        }
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: message.createdAt)
    }
}

/// Single reaction chip — hover lightens the background and switches the
/// cursor to pointer to communicate clickability.
private struct ReactionChip: View {
    let summary: GEmojiReactionSummary
    let messageID: String

    @State private var hovering: Bool = false

    private var label: String {
        summary.emoji.unicode ?? summary.emoji.customEmoji?.emojiName ?? "?"
    }

    var body: some View {
        Button {
            if let u = summary.emoji.unicode {
                Task { await Sync.shared.addReaction(messageName: messageID, unicode: u) }
            }
        } label: {
            HStack(spacing: 4) {
                Text(label).font(.system(size: 12))
                Text("\(summary.reactionCount ?? 1)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(
                    hovering ? Color.primary.opacity(0.18) : Color.primary.opacity(0.08)
                )
            )
        }
        .buttonStyle(.plain)
        .onHover { hover in
            withAnimation(.easeOut(duration: 0.08)) { hovering = hover }
            if hover { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
        .help("React with \(label)")
    }
}
