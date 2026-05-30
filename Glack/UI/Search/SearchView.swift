import AppKit
import SwiftUI

/// ⌘F local search over the cached message store. Slack-style layout:
/// search field + filter chip row + avatar-rich result cards. Type to
/// query (debounced ~120ms), arrow keys to navigate, Enter to jump.
struct SearchView: View {
    @Bindable var usersObserver: UsersObserver
    @Bindable var spacesObserver: SpacesObserver
    @Bindable var membersObserver: MembersObserver
    let currentUserID: String?
    @Binding var selectedSpaceID: String?
    @Binding var isPresented: Bool

    @State private var query: String = ""
    @State private var filter: MessageSearch.Filter = .all
    @State private var results: [MessageSearch.Result] = []
    @State private var highlightedIndex: Int = 0
    @State private var searchTask: Task<Void, Never>?
    @State private var lastSearchedQuery: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            filterRow
            Divider().opacity(0.4)
            resultsBody
        }
        .frame(width: 700, height: 540)
        .background(.regularMaterial)
        .onAppear { fieldFocused = true }
        .onChange(of: query) { _, new in scheduleSearch(new, filter: filter) }
        .onChange(of: filter) { _, new in scheduleSearch(query, filter: new) }
    }

    // MARK: - Search input

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
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

    // MARK: - Filter chips

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(MessageSearch.Filter.allCases) { f in
                    filterChip(f)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func filterChip(_ f: MessageSearch.Filter) -> some View {
        let isActive = filter == f
        return Button {
            filter = f
        } label: {
            HStack(spacing: 4) {
                Image(systemName: f.systemImage)
                    .font(.system(size: 11, weight: .medium))
                Text(f.rawValue)
                    .font(.system(size: 12, weight: isActive ? .semibold : .regular))
            }
            .foregroundStyle(isActive ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(isActive ? Color.accentColor : Color.primary.opacity(0.08))
            )
        }
        .buttonStyle(.plain)
        .help(f.rawValue)
    }

    // MARK: - Results

    @ViewBuilder
    private var resultsBody: some View {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            emptyHint("Search local message history",
                      "Type to search across every space, DM, and thread synced to this device.")
        } else if results.isEmpty && !lastSearchedQuery.isEmpty {
            emptyHint("No matches", "Try a shorter or different term, or change the filter.")
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if !results.isEmpty {
                            HStack {
                                Text("\(results.count) message\(results.count == 1 ? "" : "s")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 6)
                        }
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
                    .padding(.bottom, 4)
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
        HStack(alignment: .top, spacing: 10) {
            CachedAvatar(url: usersObserver.photoURL(for: result.senderID)) {
                Circle()
                    .fill(Color.secondary.opacity(0.18))
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    )
            }
            .frame(width: 32, height: 32)
            .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(senderName(for: result))
                        .font(.system(size: 13, weight: .semibold))
                    Text("in").font(.system(size: 11)).foregroundStyle(.tertiary)
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
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if isHighlighted {
                    HStack(spacing: 4) {
                        Image(systemName: "return")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Jump to message")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                }
            }
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

    private func scheduleSearch(_ q: String, filter: MessageSearch.Filter) {
        searchTask?.cancel()
        let trimmed = q.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            results = []
            highlightedIndex = 0
            lastSearchedQuery = ""
            return
        }
        let captured = trimmed
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            if Task.isCancelled { return }
            let hits = await MessageSearch.search(captured, filter: filter, currentUserID: currentUserID)
            if Task.isCancelled { return }
            await MainActor.run {
                self.results = hits
                self.highlightedIndex = 0
                self.lastSearchedQuery = captured
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

    private func highlightedSnippet(_ raw: String) -> AttributedString {
        var out = AttributedString("")
        var remaining = raw[...]
        while let beginRange = remaining.range(of: "«BEGIN»") {
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
            bold.backgroundColor = Color.yellow.opacity(0.35)
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
