import SwiftUI
import AppKit

private let dismissalKey = "glack.directoryNudge.dismissed"

/// Detects when Workspace "External Directory Sharing" is set to Restricted
/// (the default) — symptom is: we have many members across spaces but the
/// People-API-resolved user table has names for none of them (except possibly
/// the signed-in user themselves). When detected, surfaces a small banner
/// that explains the situation and deep-links the admin to the setting.
struct DirectoryAccessNudge: View {
    @Bindable var users: UsersObserver
    @Bindable var members: MembersObserver
    let currentUserID: String?

    @State private var dismissed: Bool = UserDefaults.standard.bool(forKey: dismissalKey)
    @State private var showSheet: Bool = false

    var body: some View {
        if shouldShow {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "person.text.rectangle")
                    .foregroundStyle(.tint)
                    .font(.system(size: 13))
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Coworker names are hidden")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Your Workspace admin can enable name sharing.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Button("Show me how") { showSheet = true }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                        .padding(.top, 2)
                }
                Spacer(minLength: 4)
                Button {
                    dismissed = true
                    UserDefaults.standard.set(true, forKey: dismissalKey)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.accentColor.opacity(0.08))
            .overlay(alignment: .bottom) {
                Rectangle().fill(.separator).frame(height: 0.5)
            }
            .sheet(isPresented: $showSheet) {
                DirectoryAccessSheet(
                    isPresented: $showSheet,
                    onDismissForever: {
                        dismissed = true
                        UserDefaults.standard.set(true, forKey: dismissalKey)
                    }
                )
            }
        }
    }

    /// Heuristic: at least 3 colleagues exist in member rows, but we've
    /// resolved zero names for them via People API. That's the signature of
    /// Restricted external sharing.
    private var shouldShow: Bool {
        guard !dismissed else { return false }
        let allMemberIDs = Set(members.membersBySpace.values.flatMap { $0 })
        let othersIDs = allMemberIDs.filter { $0 != currentUserID }
        guard othersIDs.count >= 3 else { return false }
        let namedOthers = othersIDs.filter { users.displayName(for: $0) != nil }
        return namedOthers.isEmpty
    }
}

private struct DirectoryAccessSheet: View {
    @Binding var isPresented: Bool
    let onDismissForever: () -> Void

    @State private var copied: Bool = false
    @State private var copiedAdminBrief: Bool = false

    /// Glack's OAuth Client ID — admins paste this into the App Access Control
    /// "Add app" dialog to find Glack and grant it trust.
    private let clientID = "173541745839-ku7jaiqjl5s6agat5o2g92s6dguo9ris.apps.googleusercontent.com"

    /// Universal URL — works for any signed-in Workspace admin regardless of
    /// their org's customer ID (Google auto-resolves to the right org).
    private let adminURL = URL(string: "https://admin.google.com/ac/owl/list?tab=apps")!

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            Text("Google Workspace requires admins to explicitly trust third-party apps before they can read your team's directory (names + emails). A Workspace admin can grant Glack this access from the App Access Control page in under a minute. The setting is per-organization and applies to everyone the moment it's saved.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 12) {
                Text("If you're a Workspace admin").font(.headline)
                clientIDBox
                VStack(alignment: .leading, spacing: 8) {
                    step(1, "Click **Open App Access Control** below")
                    step(2, "Click **Configure new app** → **OAuth App Name Or Client ID**")
                    step(3, "Paste the Client ID → search → select **Glack**")
                    step(4, "Choose **Trusted: Can access all Google services** → **Continue** → **Finish**")
                    step(5, "Names + photos appear in Glack within ~1 minute. No sign-out needed.")
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Not an admin?").font(.headline)
                Text("Send your Workspace admin the steps above with one click.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(adminBriefText, forType: .string)
                    copiedAdminBrief = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copiedAdminBrief = false }
                } label: {
                    Label(copiedAdminBrief ? "Copied — paste into Slack/email" : "Copy instructions for your admin",
                          systemImage: copiedAdminBrief ? "checkmark.circle.fill" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            Button {
                NSWorkspace.shared.open(adminURL)
            } label: {
                Label("Open App Access Control", systemImage: "arrow.up.right.square")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)

            HStack {
                Button("Don't show again") {
                    onDismissForever()
                    isPresented = false
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .font(.callout)
                Spacer()
                Button("Close") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "person.text.rectangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text("Show coworkers' names in Glack")
                    .font(.title3.bold())
                Text("Workspace admin setting · ~1 minute · One-time per org")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var clientIDBox: some View {
        HStack(spacing: 8) {
            Text(clientID)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(clientID, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
            } label: {
                Label(copied ? "Copied" : "Copy Client ID",
                      systemImage: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
        }
    }

    private var adminBriefText: String {
        """
        Hey — I'd like to use Glack (a macOS Google Chat client) and it needs admin approval to show coworkers' names. Could you do this when you have a minute?

        1. Open https://admin.google.com/ac/owl/list?tab=apps
        2. Click "Configure new app" → "OAuth App Name Or Client ID"
        3. Paste this Client ID and search:
           \(clientID)
        4. Select Glack → "Trusted: Can access all Google services" → Continue → Finish

        Takes about a minute. Thanks!
        """
    }

    @ViewBuilder
    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n).")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
            Text(.init(text))  // LocalizedStringKey enables **bold**
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
