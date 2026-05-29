import Foundation

/// Pure name-resolution for a space — shared by SidebarRow, CommandPalette,
/// and detail title rendering so they stay consistent. MainActor-isolated
/// because it reads from @Observable observers that live on the main actor.
@MainActor
enum SpaceDisplay {
    /// The rendered display name for a space, applying the same fallback
    /// chain as the sidebar: server-provided displayName → bot stub → member
    /// names → type label.
    static func name(
        for space: SpaceRecord,
        users: UsersObserver,
        members: MembersObserver,
        currentUserID: String?
    ) -> String {
        if let dn = space.displayName, !dn.isEmpty { return dn }
        let others = otherMemberIDs(space: space, members: members, currentUserID: currentUserID)
        if space.singleUserBotDm == true {
            if let id = others.first { return "App \(String(id.suffix(4)))" }
            return "App"
        }
        if !others.isEmpty {
            let parts: [String] = others.map { id in
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

    /// One-line subtitle for palette rows ("Direct message", "🤖 AI Native space", etc.).
    static func subtitle(for space: SpaceRecord) -> String {
        if space.singleUserBotDm == true { return "App" }
        switch space.type {
        case .directMessage: return "Direct message"
        case .groupChat:     return "Group chat"
        case .space:         return space.threaded ? "Space" : "Conversation"
        case .unknown:       return ""
        }
    }

    static func otherMemberIDs(
        space: SpaceRecord,
        members: MembersObserver,
        currentUserID: String?
    ) -> [String] {
        let all = members.membersBySpace[space.id] ?? []
        guard let me = currentUserID else { return all }
        return all.filter { $0 != me }
    }
}
