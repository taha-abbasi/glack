import SwiftUI

struct ConversationView: View {
    let spaceID: String
    @Bindable var observer: MessagesObserver
    @Bindable var users: UsersObserver
    let space: SpaceRecord?
    @Binding var selectedThreadID: String?

    @State private var threadCounts = ThreadCountsObserver()

    var body: some View {
        VStack(spacing: 0) {
            messageList
            if canCompose {
                Divider()
                ComposerView(spaceID: spaceID, placeholder: composerPlaceholder)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: spaceID) {
            // Tell Sync which space is on screen so notifications are
            // suppressed for it, and clear its unread count.
            Session.shared.currentlyViewingSpaceID = spaceID
            await Sync.shared.markRead(spaceID: spaceID)
            observer.observe(spaceID: spaceID)
            threadCounts.observe(spaceID: spaceID)
            // Close any open thread when the user navigates to a new space.
            selectedThreadID = nil
            await Sync.shared.syncVisibleSpace(spaceID)
        }
        .onDisappear {
            if Session.shared.currentlyViewingSpaceID == spaceID {
                Session.shared.currentlyViewingSpaceID = nil
            }
            threadCounts.stop()
        }
    }

    @ViewBuilder
    private var messageList: some View {
        if observer.messages.isEmpty {
            ContentUnavailableView(
                "No messages yet",
                systemImage: "tray",
                description: Text("Pulling recent history…")
            )
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(observer.messages) { msg in
                            MessageRow(
                                message: msg,
                                users: users,
                                threadReplyCount: msg.threadId.flatMap { threadCounts.counts[$0] },
                                onOpenThread: { tid in selectedThreadID = tid }
                            )
                            .id(msg.id)
                            .opacity(msg.id.hasPrefix("pending-") ? 0.55 : 1.0)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                }
                .onChange(of: observer.messages.count) { _, _ in
                    if let last = observer.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
                .onAppear {
                    if let last = observer.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    /// Hide the composer in spaces the user can't write to:
    /// - DMs with apps where the user is just a recipient (singleUserBotDm)
    ///   are technically writable (you can send to Drive bot etc.), so allow
    ///   those. The Chat API rejects writes server-side when not permitted.
    private var canCompose: Bool { true }

    private var composerPlaceholder: String {
        guard let s = space else { return "Message…" }
        if let dn = s.displayName, !dn.isEmpty { return "Message \(dn)" }
        switch s.type {
        case .directMessage: return "Message"
        case .groupChat:     return "Message group"
        case .space:         return "Message space"
        case .unknown:       return "Message"
        }
    }
}
