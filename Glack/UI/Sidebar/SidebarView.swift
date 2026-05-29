import SwiftUI

struct SidebarView: View {
    @Bindable var observer: SpacesObserver
    @Bindable var users: UsersObserver
    @Bindable var members: MembersObserver
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
            let groups = grouped(observer.spaces)

            Section("Direct Messages") {
                if groups.dms.isEmpty {
                    Text("No DMs").foregroundStyle(.secondary).font(.footnote)
                } else {
                    ForEach(groups.dms) { space in
                        SidebarRow(space: space, users: users, members: members, currentUserID: currentUserID)
                            .tag(space.id as String?)
                    }
                }
            }

            Section("Spaces") {
                if groups.spaces.isEmpty {
                    Text("No spaces").foregroundStyle(.secondary).font(.footnote)
                } else {
                    ForEach(groups.spaces) { space in
                        SidebarRow(space: space, users: users, members: members, currentUserID: currentUserID)
                            .tag(space.id as String?)
                    }
                }
            }

            if !groups.apps.isEmpty {
                Section("Apps") {
                    ForEach(groups.apps) { space in
                        SidebarRow(space: space, users: users, members: members, currentUserID: currentUserID)
                            .tag(space.id as String?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private struct Grouped {
        var dms: [SpaceRecord]
        var spaces: [SpaceRecord]
        var apps: [SpaceRecord]
    }

    /// Slack-style grouping that matches Google Chat's own web UI.
    ///
    /// Google's web app puts unthreaded "Conversations" in the DM section
    /// even when they have a name and `spaceType: SPACE` (e.g. Meet-created
    /// conversations like "Daily Standup - May 21"). The single signal that
    /// distinguishes a real Space from a Conversation in user-auth API
    /// responses is `threaded` — threaded=true is a room/channel; threaded=false
    /// is a conversation. Member counts don't work as a heuristic in small
    /// teams (every space has 3 members in a 3-person org).
    private func grouped(_ all: [SpaceRecord]) -> Grouped {
        var dms: [SpaceRecord] = []
        var spaces: [SpaceRecord] = []
        var apps: [SpaceRecord] = []
        for s in all {
            // 1:1 bot DMs (Giphy, Google Drive, etc.) go in the Apps section
            // matching Google Chat's own web UI.
            if s.singleUserBotDm == true {
                apps.append(s)
                continue
            }
            switch s.type {
            case .directMessage, .groupChat:
                dms.append(s)
            case .space:
                if s.threaded { spaces.append(s) } else { dms.append(s) }
            case .unknown:
                spaces.append(s)
            }
        }
        return Grouped(dms: dms, spaces: spaces, apps: apps)
    }
}
