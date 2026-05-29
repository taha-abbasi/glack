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
            case .signedIn(let email):
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
                ProgressView()
                    .controlSize(.small)
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

    var body: some View {
        NavigationSplitView {
            List {
                Section("Direct Messages") {
                    Text("No DMs yet")
                        .foregroundStyle(.secondary)
                }
                Section("Spaces") {
                    Text("Loading spaces…")
                        .foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign out", role: .destructive) {
                        Task { await session.signOut() }
                    }
                }
            }
            .navigationTitle("Glack")
            .frame(minWidth: 220)
        } detail: {
            ContentUnavailableView(
                "Signed in" + (email.map { " as \($0)" } ?? ""),
                systemImage: "checkmark.circle",
                description: Text("Spaces and message sync land in Phase 2.")
            )
        }
    }
}

#Preview {
    RootView()
}
