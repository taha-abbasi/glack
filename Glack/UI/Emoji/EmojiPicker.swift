import SwiftUI

/// Categorized Unicode emoji picker with search. Used by the reactions
/// popover and (later) the composer's emoji button.
struct EmojiPicker: View {
    let onPick: (String) -> Void

    @State private var query: String = ""
    @State private var selectedCategory: String = EmojiCatalog.categories.first!.id
    @FocusState private var searchFocused: Bool

    private let columns = Array(repeating: GridItem(.fixed(28), spacing: 4), count: 8)

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            content
            if query.isEmpty {
                Divider()
                categoryBar
            }
        }
        .frame(width: 280, height: 320)
        .background(.regularMaterial)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search emoji", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($searchFocused)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            if !query.isEmpty {
                let results = EmojiCatalog.search(query)
                if results.isEmpty {
                    Text("No matches")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(results) { entry in
                            emojiButton(entry)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            } else if let cat = EmojiCatalog.categories.first(where: { $0.id == selectedCategory }) {
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(cat.entries) { entry in
                        emojiButton(entry)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 6)
            }
        }
    }

    private func emojiButton(_ entry: EmojiCatalog.Entry) -> some View {
        Button {
            onPick(entry.emoji)
        } label: {
            Text(entry.emoji)
                .font(.system(size: 18))
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .help(":\(entry.name):")
    }

    private var categoryBar: some View {
        HStack(spacing: 0) {
            ForEach(EmojiCatalog.categories) { cat in
                Button {
                    selectedCategory = cat.id
                } label: {
                    Image(systemName: cat.symbol)
                        .font(.system(size: 12))
                        .foregroundStyle(selectedCategory == cat.id ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.plain)
                .help(cat.title)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
    }
}
