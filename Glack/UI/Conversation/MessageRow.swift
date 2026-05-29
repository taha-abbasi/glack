import SwiftUI

struct MessageRow: View {
    let message: MessageRecord
    @Bindable var users: UsersObserver

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
                Text(renderedText)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if message.attachmentCount > 0 {
                    Label("\(message.attachmentCount) attachment\(message.attachmentCount == 1 ? "" : "s")",
                          systemImage: "paperclip")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

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
                    // No display name available — show a neutral person icon
                    // rather than the first digit of the user ID (ugly + not
                    // distinguishing).
                    Image(systemName: "person.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
    }

    /// The actual person name we know, OR nil if we don't.
    /// Returning nil tells initialsAvatar to use a neutral icon instead of
    /// pretending we know the person.
    private var resolvedName: String? {
        if let n = users.displayName(for: message.senderId), !n.isEmpty { return n }
        if let s = message.senderName, !s.isEmpty { return s }
        return nil
    }

    private var senderDisplayName: String {
        if let n = resolvedName { return n }
        // Last 4 chars of the user ID — keeps the identity distinguishable
        // across messages from the same person without looking like a bug.
        if let id = message.senderId {
            let tail = String(id.suffix(4))
            return "Member \(tail)"
        }
        return "Unknown"
    }

    /// Resolve `<users/{id}>` mention syntax to `@DisplayName` where we have a name cached.
    private var renderedText: String {
        guard var s = message.text else { return "" }
        for (id, user) in users.users {
            guard let name = user.displayName, !name.isEmpty else { continue }
            let mentionToken = "<\(id)>"  // "<users/{id}>"
            s = s.replacingOccurrences(of: mentionToken, with: "@\(name)")
        }
        return s
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: message.createdAt)
    }
}
