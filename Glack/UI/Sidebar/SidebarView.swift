import SwiftUI

struct SidebarView: View {
    @Bindable var observer: SpacesObserver
    @Bindable var sections: SectionsObserver
    @Bindable var users: UsersObserver
    @Bindable var members: MembersObserver
    @Bindable var unread: UnreadObserver
    let currentUserID: String?
    @Binding var selection: String?

    var body: some View {
        VStack(spacing: 0) {
            DirectoryAccessNudge(users: users, members: members, currentUserID: currentUserID)
            listBody
        }
    }

    private var listBody: some View {
        List(selection: $selection) {
            // Prefer the user's Chat-API section organization (matches what
            // they see in the Chat web app — custom sections + DMs/Spaces/Apps
            // in the order they've arranged). Falls back to a static split if
            // sections haven't synced yet (e.g. first launch before the new
            // scope is granted).
            if !sections.groups.isEmpty {
                ForEach(sections.groups) { group in
                    if !group.spaces.isEmpty {
                        Section(group.section.displayLabel) {
                            ForEach(group.spaces) { space in
                                SidebarRow(space: space, users: users,
                                           members: members,
                                           unreadCount: unread.perSpace[space.id] ?? 0,
                                           currentUserID: currentUserID)
                                    .tag(space.id as String?)
                            }
                        }
                    }
                }
            } else {
                fallbackSections
            }
        }
        .listStyle(.sidebar)
    }

    /// Static grouping used while Chat-API sections haven't arrived yet —
    /// or as a graceful fallback if the user denies the section scope.
    @ViewBuilder
    private var fallbackSections: some View {
        let groups = staticGrouped(observer.spaces)

        Section("Direct Messages") {
            if groups.dms.isEmpty {
                Text("No DMs").foregroundStyle(.secondary).font(.footnote)
            } else {
                ForEach(groups.dms) { space in
                    SidebarRow(space: space, users: users, members: members,
                               unreadCount: unread.perSpace[space.id] ?? 0,
                               currentUserID: currentUserID)
                        .tag(space.id as String?)
                }
            }
        }
        Section("Spaces") {
            if groups.spaces.isEmpty {
                Text("No spaces").foregroundStyle(.secondary).font(.footnote)
            } else {
                ForEach(groups.spaces) { space in
                    SidebarRow(space: space, users: users, members: members,
                               unreadCount: unread.perSpace[space.id] ?? 0,
                               currentUserID: currentUserID)
                        .tag(space.id as String?)
                }
            }
        }
        if !groups.apps.isEmpty {
            Section("Apps") {
                ForEach(groups.apps) { space in
                    SidebarRow(space: space, users: users, members: members,
                               unreadCount: unread.perSpace[space.id] ?? 0,
                               currentUserID: currentUserID)
                        .tag(space.id as String?)
                }
            }
        }
    }

    private struct StaticGrouped {
        var dms: [SpaceRecord]
        var spaces: [SpaceRecord]
        var apps: [SpaceRecord]
    }

    private func staticGrouped(_ all: [SpaceRecord]) -> StaticGrouped {
        var dms: [SpaceRecord] = []
        var spaces: [SpaceRecord] = []
        var apps: [SpaceRecord] = []
        for s in all {
            if s.singleUserBotDm == true { apps.append(s); continue }
            switch s.type {
            case .directMessage, .groupChat:
                dms.append(s)
            case .space:
                if s.threaded { spaces.append(s) } else { dms.append(s) }
            case .unknown:
                spaces.append(s)
            }
        }
        return StaticGrouped(dms: dms, spaces: spaces, apps: apps)
    }
}
