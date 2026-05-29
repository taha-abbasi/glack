import SwiftUI

/// Side panel that opens to the right of the conversation when the user
/// clicks "Replies (N)" on a message. Shows the parent + every reply in
/// the thread, with a scoped composer at the bottom that posts back into
/// the same thread via `messageReplyOption=REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD`.
struct ThreadView: View {
    let threadID: String        // "spaces/X/threads/T"
    let spaceID: String
    @Bindable var users: UsersObserver
    @Binding var isOpen: Bool

    @State private var observer = ThreadMessagesObserver()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messageList
            Divider()
            ThreadComposerView(spaceID: spaceID, threadName: threadID)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .task(id: threadID) {
            observer.observe(threadID: threadID)
            // Pull a fresh listMessages page for the thread's space so
            // the observer reflects the latest replies.
            await Sync.shared.syncVisibleSpace(spaceID)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Thread")
                    .font(.system(size: 13, weight: .semibold))
                Text(replyCountText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                isOpen = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(6)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close thread")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private var replyCountText: String {
        let total = observer.messages.count
        if total == 0 { return "Loading replies…" }
        if total == 1 { return "Start a reply" }
        return "\(total - 1) repl\(total == 2 ? "y" : "ies")"
    }

    @ViewBuilder
    private var messageList: some View {
        if observer.messages.isEmpty {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(observer.messages) { msg in
                            MessageRow(message: msg, users: users)
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
}
