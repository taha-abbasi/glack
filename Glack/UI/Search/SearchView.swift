import AppKit
import SwiftUI

/// ⌘F local search over the cached message store. Type to query (debounced
/// ~120ms), arrow keys to navigate, Enter to jump to the message's space.
struct SearchView: View {
    @Bindable var usersObserver: UsersObserver
    @Bindable var spacesObserver: SpacesObserver
    @Bindable var membersObserver: MembersObserver
    let currentUserID: String?
    @Binding var selectedSpaceID: String?
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var results: [MessageSearch.Result] = []
    @State private var highlightedIndex: Int = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var lastSearchedQuery: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            resultsBody
        }
        .frame(width: 620, height: 480)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, new in
            scheduleSearch(new)
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search messages…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($fieldFocused)
                .onSubmit { commit() }
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
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var resultsBody: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyHint("Search local message history", "Type to search across every space, DM, and thread synced to this device.")
        } else if results.isEmpty && !lastSearchedQuery.isEmpty {
            emptyHint("No matches", "Try a shorter or different term.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { idx, result in
                            row(for: result, isHighlighted: idx == highlightedIndex)
                                .id(result.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    highlightedIndex = idx
                                    commit()
                                }
                                .onHover { hovering in
                                    if hovering { highlightedIndex = idx }
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: highlightedIndex) { _, new in
                    if let id = results[safe: new]?.id {
                        withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }

    private func row(for result: MessageSearch.Result, isHighlighted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(senderName(for: result))
                    .font(.system(size: 13, weight: .semibold))
                Text("·").foregroundStyle(.tertiary)
                Text(spaceName(for: result))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(timeString(result.createdAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            Text(highlightedSnippet(result.snippet))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.accentColor.opacity(0.18) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }

    private func emptyHint(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13))
            Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Helpers

    private func scheduleSearch(_ q: String) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = []
            highlightedIndex = 0
            lastSearchedQuery = ""
            return
        }
        searchTask = Task {
            // Debounce so we don't query on every keystroke.
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let hits = await MessageSearch.search(trimmed)
            if Task.isCancelled { return }
            await MainActor.run {
                self.results = hits
                self.highlightedIndex = 0
                self.lastSearchedQuery = trimmed
            }
        }
    }

    private func commit() {
        guard let result = results[safe: highlightedIndex] else { return }
        selectedSpaceID = result.spaceID
        isPresented = false
    }

    private func senderName(for r: MessageSearch.Result) -> String {
        if let id = r.senderID, let name = usersObserver.displayName(for: id), !name.isEmpty {
            return name
        }
        if let id = r.senderID { return "Member \(String(id.suffix(4)))" }
        return "Unknown"
    }

    private func spaceName(for r: MessageSearch.Result) -> String {
        if let dn = r.spaceDisplayName, !dn.isEmpty { return dn }
        if let space = spacesObserver.spaces.first(where: { $0.id == r.spaceID }) {
            return SpaceDisplay.name(for: space,
                                     users: usersObserver,
                                     members: membersObserver,
                                     currentUserID: currentUserID)
        }
        return r.spaceID
    }

    private func timeString(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    /// Parse the SQLite snippet (with our custom «BEGIN»/«END» tokens) into
    /// an AttributedString with bold runs for each match.
    private func highlightedSnippet(_ raw: String) -> AttributedString {
        var out = AttributedString("")
        var remaining = raw[...]
        while let beginRange = remaining.range(of: "«BEGIN»") {
            // The plain prefix before the match
            let prefix = String(remaining[..<beginRange.lowerBound])
            out.append(AttributedString(prefix))
            let afterBegin = remaining[beginRange.upperBound...]
            guard let endRange = afterBegin.range(of: "«END»") else {
                out.append(AttributedString(String(afterBegin)))
                return out
            }
            let matched = String(afterBegin[..<endRange.lowerBound])
            var bold = AttributedString(matched)
            bold.font = .system(size: 12, weight: .semibold)
            bold.foregroundColor = .primary
            out.append(bold)
            remaining = afterBegin[endRange.upperBound...]
        }
        out.append(AttributedString(String(remaining)))
        return out
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
