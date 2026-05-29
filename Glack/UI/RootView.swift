import SwiftUI

struct RootView: View {
    @State private var session = Session.shared

    var body: some View {
        Group {
            switch session.state {
            case .unknown:
                BootstrapView()
            case .signedOut, .signingIn:
                SignInView(session: session)
            case .signedIn(let email, _):
                SignedInView(session: session, email: email)
            }
        }
        .task { await session.bootstrap() }
    }
}

private struct BootstrapView: View {
    var body: some View {
        ProgressView("Restoring session…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SignInView: View {
    let session: Session

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
            Text("Welcome to Glack")
                .font(.largeTitle).bold()
            Text("Sign in with your Google account to load your Chat spaces.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button {
                Task { await session.signIn() }
            } label: {
                Label("Sign in with Google", systemImage: "person.crop.circle.badge.checkmark")
                    .frame(minWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(session.isSigningIn)

            if session.isSigningIn {
                ProgressView().controlSize(.small)
            }
            if let err = session.lastError {
                Text(err)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 480)
                    .textSelection(.enabled)
            }
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SignedInView: View {
    let session: Session
    let email: String?

    @State private var spacesObserver = SpacesObserver()
    @State private var messagesObserver = MessagesObserver()
    @State private var usersObserver = UsersObserver()
    @State private var membersObserver = MembersObserver()
    @State private var sectionsObserver = SectionsObserver()
    @State private var unreadObserver = UnreadObserver()
    @State private var sync = Sync.shared
    @State private var selectedSpaceID: String?
    @State private var selectedThreadID: String?
    @State private var paletteOpen: Bool = false
    @State private var searchOpen: Bool = false

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                SidebarView(
                    observer: spacesObserver,
                    sections: sectionsObserver,
                    users: usersObserver,
                    members: membersObserver,
                    unread: unreadObserver,
                    currentUserID: session.currentUserID,
                    selection: $selectedSpaceID
                )
                Divider()
                footer
            }
            .frame(minWidth: 240)
            .navigationTitle("Glack")
        } detail: {
            if let id = selectedSpaceID {
                HStack(spacing: 0) {
                    ConversationView(
                        spaceID: id,
                        observer: messagesObserver,
                        users: usersObserver,
                        space: spacesObserver.spaces.first(where: { $0.id == id }),
                        selectedThreadID: $selectedThreadID
                    )
                    if let threadID = selectedThreadID {
                        Divider()
                        ThreadView(
                            threadID: threadID,
                            spaceID: id,
                            users: usersObserver,
                            isOpen: Binding(
                                get: { selectedThreadID != nil },
                                set: { if !$0 { selectedThreadID = nil } }
                            )
                        )
                        .frame(width: 380)
                    }
                }
                .navigationTitle(detailTitle(for: id))
            } else {
                ContentUnavailableView(
                    "Pick a conversation",
                    systemImage: "sidebar.left",
                    description: detailDescription
                )
            }
        }
        .task {
            spacesObserver.start()
            sectionsObserver.start()
            usersObserver.start()
            membersObserver.start()
            unreadObserver.start()
            sync.start()
            await NotificationManager.shared.requestAuthorizationIfNeeded()
        }
        .onChange(of: selectedSpaceID) { _, new in
            if let id = new {
                Task { await sync.markRead(spaceID: id) }
            }
        }
        .onDisappear {
            sync.stop()
            spacesObserver.stop()
            sectionsObserver.stop()
            usersObserver.stop()
            membersObserver.stop()
            messagesObserver.stop()
            unreadObserver.stop()
        }
        .background(
            ZStack {
                Button("Open command palette") { paletteOpen = true }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Search messages") { searchOpen = true }
                    .keyboardShortcut("f", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        )
        .sheet(isPresented: $paletteOpen) {
            CommandPaletteView(
                spacesObserver: spacesObserver,
                usersObserver: usersObserver,
                membersObserver: membersObserver,
                currentUserID: session.currentUserID,
                selectedSpaceID: $selectedSpaceID,
                isPresented: $paletteOpen
            )
        }
        .sheet(isPresented: $searchOpen) {
            SearchView(
                usersObserver: usersObserver,
                spacesObserver: spacesObserver,
                membersObserver: membersObserver,
                currentUserID: session.currentUserID,
                selectedSpaceID: $selectedSpaceID,
                isPresented: $searchOpen
            )
        }
    }

    private var detailDescription: Text {
        if sync.isRunning && spacesObserver.spaces.isEmpty {
            return Text("Loading your spaces from Google Chat…")
        }
        return Text("Choose a DM or space from the sidebar.")
    }

    private func detailTitle(for spaceID: String) -> String {
        spacesObserver.spaces.first(where: { $0.id == spaceID }).map(name(of:)) ?? ""
    }

    private func name(of space: SpaceRecord) -> String {
        if let dn = space.displayName, !dn.isEmpty { return dn }
        switch space.type {
        case .directMessage: return "Direct Message"
        case .groupChat:     return "Group Chat"
        default:             return space.id
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(email ?? "Signed in").font(.system(size: 11)).lineLimit(1)
                Text(syncStatus).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button {
                Task { await session.signOut() }
            } label: {
                Image(systemName: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.plain)
            .help("Sign out")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
    }

    private var syncStatus: String {
        if let err = sync.lastError { return "Sync error — see logs" }
        if let last = sync.lastSyncedAt {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return "Synced \(f.localizedString(for: last, relativeTo: Date()))"
        }
        return sync.isRunning ? "Syncing…" : "Idle"
    }
}

#Preview {
    RootView()
}
