import AppKit
import SwiftUI

struct SidebarRow: View {
    let space: SpaceRecord
    @Bindable var users: UsersObserver
    @Bindable var members: MembersObserver
    let unreadCount: Int
    let currentUserID: String?

    @State private var hovering: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            avatar
            VStack(alignment: .leading, spacing: 0) {
                Text(displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .font(.system(size: 13, weight: unreadCount > 0 ? .semibold : .regular))
            }
            Spacer(minLength: 0)
            if unreadCount > 0 { unreadBadge }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(hovering ? Color.primary.opacity(0.07) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hover in
            withAnimation(.easeOut(duration: 0.08)) { hovering = hover }
            if hover { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
        }
    }

    private var unreadBadge: some View {
        Text(unreadCount > 99 ? "99+" : "\(unreadCount)")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor))
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
        if space.singleUserBotDm == true { return "puzzlepiece.extension.fill" }
        switch space.type {
        case .directMessage:  return "person.crop.circle"
        case .groupChat:      return "person.2"
        case .space, .unknown:
            return space.threaded ? "number" : "bubble.left.and.bubble.right"
        }
    }

    private var displayName: String {
        SpaceDisplay.name(for: space, users: users, members: members, currentUserID: currentUserID)
    }

    /// Members of this space EXCLUDING the current user.
    private var otherMemberIDs: [String] {
        SpaceDisplay.otherMemberIDs(space: space, members: members, currentUserID: currentUserID)
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
