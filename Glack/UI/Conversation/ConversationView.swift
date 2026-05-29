import SwiftUI

struct ConversationView: View {
    let spaceID: String
    @Bindable var observer: MessagesObserver
    @Bindable var users: UsersObserver

    var body: some View {
        VStack(spacing: 0) {
            if observer.messages.isEmpty {
                ContentUnavailableView(
                    "No messages yet",
                    systemImage: "tray",
                    description: Text("Pulling recent history…")
                )
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(observer.messages) { msg in
                                MessageRow(message: msg, users: users)
                                    .id(msg.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: spaceID) {
            observer.observe(spaceID: spaceID)
            await Sync.shared.syncVisibleSpace(spaceID)
        }
    }
}
