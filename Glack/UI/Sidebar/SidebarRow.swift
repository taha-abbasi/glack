import SwiftUI

struct SidebarRow: View {
    let space: SpaceRecord
    @Bindable var users: UsersObserver
    @Bindable var members: MembersObserver
    let currentUserID: String?

    var body: some View {
        HStack(spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 0) {
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var avatar: some View {
        let otherIDs = otherMemberIDs
        let photo = (isDMLike && otherIDs.count == 1) ? users.photoURL(for: otherIDs.first) : nil
        CachedAvatar(url: photo) { defaultAvatar }
            .frame(width: 22, height: 22)
            .clipShape(Circle())
    }

    private var defaultAvatar: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.18))
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var icon: String {
        switch space.type {
        case .directMessage:  return "person.crop.circle"
        case .groupChat:      return "person.2"
        case .space, .unknown:
            return space.threaded ? "number" : "bubble.left.and.bubble.right"
        }
    }

    private var displayName: String {
        if let dn = space.displayName, !dn.isEmpty { return dn }
        // No server-provided name — derive from members for DMs / group chats.
        let otherIDs = otherMemberIDs
        if !otherIDs.isEmpty {
            // Prefer real People-API-resolved names when available.
            let realNames = otherIDs.compactMap { users.displayName(for: $0) }
            if realNames.count == otherIDs.count {
                return realNames.joined(separator: ", ")
            }
            // Mixed (some known, some not) or all unknown — show "Member XXXX"
            // for unresolved using last 4 chars of their user ID so each DM
            // is at least distinguishable.
            let parts: [String] = otherIDs.map { id in
                if let n = users.displayName(for: id), !n.isEmpty { return n }
                return "Member \(String(id.suffix(4)))"
            }
            return parts.joined(separator: ", ")
        }
        switch space.type {
        case .directMessage: return "Direct Message"
        case .groupChat:     return "Group Chat"
        default:             return space.id
        }
    }

    /// Members of this space EXCLUDING the current user.
    private var otherMemberIDs: [String] {
        let all = members.membersBySpace[space.id] ?? []
        guard let me = currentUserID else { return all }
        return all.filter { $0 != me }
    }

    /// Treat unthreaded spaces the same as DMs for avatar/name purposes —
    /// that matches Google Chat's web UI ("Conversations" behave like DMs).
    private var isDMLike: Bool {
        switch space.type {
        case .directMessage, .groupChat: return true
        case .space: return !space.threaded
        case .unknown: return false
        }
    }
}
