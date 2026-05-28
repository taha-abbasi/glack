import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationSplitView {
            List {
                Section("Direct Messages") {
                    Text("No DMs yet")
                        .foregroundStyle(.secondary)
                }
                Section("Spaces") {
                    Text("Sign in to load spaces")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Glack")
            .frame(minWidth: 220)
        } detail: {
            ContentUnavailableView(
                "Welcome to Glack",
                systemImage: "bubble.left.and.bubble.right",
                description: Text("Sign in with Google to load your Chat spaces.")
            )
        }
    }
}

#Preview {
    RootView()
}
