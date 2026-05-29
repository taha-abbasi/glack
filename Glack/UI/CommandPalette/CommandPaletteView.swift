import SwiftUI

/// Cmd-K "jump to" palette. Filters every space (DM, group, space, app) by
/// substring against its rendered display name, ordered by recent activity
/// when the query is empty. Slack's ⌘K behavior.
struct CommandPaletteView: View {
    @Bindable var spacesObserver: SpacesObserver
    @Bindable var usersObserver: UsersObserver
    @Bindable var membersObserver: MembersObserver
    let currentUserID: String?
    @Binding var selectedSpaceID: String?
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var highlightedIndex: Int = 0
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsList
        }
        .frame(width: 560, height: 420)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, _ in highlightedIndex = 0 }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Jump to a conversation…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($fieldFocused)
                .onSubmit { commitSelection() }
                .onKeyPress(.downArrow) {
                    highlightedIndex = min(highlightedIndex + 1, results.count - 1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    highlightedIndex = max(highlightedIndex - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    isPresented = false
                    return .handled
                }
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if results.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, space in
                            row(for: space, isHighlighted: idx == highlightedIndex)
                                .id(space.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    highlightedIndex = idx
                                    commitSelection()
                                }
                                .onHover { hovering in
                                    if hovering { highlightedIndex = idx }
                                }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: highlightedIndex) { _, new in
                if let id = results[safe: new]?.id {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    private func row(for space: SpaceRecord, isHighlighted: Bool) -> some View {
        let name = SpaceDisplay.name(for: space,
                                     users: usersObserver,
                                     members: membersObserver,
                                     currentUserID: currentUserID)
        let subtitle = SpaceDisplay.subtitle(for: space)
        let others = SpaceDisplay.otherMemberIDs(space: space,
                                                 members: membersObserver,
                                                 currentUserID: currentUserID)
        let photo = (space.type == .directMessage && others.count == 1)
            ? usersObserver.photoURL(for: others.first) : nil
        return HStack(spacing: 10) {
            CachedAvatar(url: photo) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.18))
                    Image(systemName: icon(for: space))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 13))
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No conversations loaded yet" : "No matches")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func icon(for space: SpaceRecord) -> String {
        if space.singleUserBotDm == true { return "puzzlepiece.extension.fill" }
        switch space.type {
        case .directMessage:  return "person.crop.circle"
        case .groupChat:      return "person.2"
        case .space, .unknown:
            return space.threaded ? "number" : "bubble.left.and.bubble.right"
        }
    }

    private var results: [SpaceRecord] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let all = spacesObserver.spaces
        let scored: [(SpaceRecord, Double)] = all.compactMap { space in
            let name = SpaceDisplay.name(for: space,
                                         users: usersObserver,
                                         members: membersObserver,
                                         currentUserID: currentUserID)
            if q.isEmpty {
                return (space, Self.recencyScore(space))
            }
            let lname = name.lowercased()
            guard lname.contains(q) else { return nil }
            let exact = (lname == q) ? 1000.0 : 0
            let prefix = lname.hasPrefix(q) ? 500.0 : 0
            return (space, exact + prefix + Self.recencyScore(space))
        }
        return scored.sorted { $0.1 > $1.1 }.map(\.0)
    }

    private static func recencyScore(_ space: SpaceRecord) -> Double {
        guard let t = space.lastActivityAt else { return 0 }
        // Recency in days, negated and clamped so newer = higher score.
        let days = Date().timeIntervalSince(t) / 86_400
        return max(0, 365 - days)
    }

    private func commitSelection() {
        guard let space = results[safe: highlightedIndex] else { return }
        selectedSpaceID = space.id
        isPresented = false
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
