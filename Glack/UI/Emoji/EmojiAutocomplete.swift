import AppKit
import SwiftUI

/// Live emoji-shortcode autocomplete state. Owned by ComposerView and
/// updated by RichTextEditor's Coordinator on every keystroke. The popup
/// view observes this object to render the current matches + selection.
@MainActor
@Observable
final class EmojiAutocompleteState {
    private(set) var prefix: String? = nil
    private(set) var matches: [EmojiCatalog.Entry] = []
    var selectedIndex: Int = 0

    var isActive: Bool { prefix != nil && !matches.isEmpty }

    /// Recompute matches from the bundled catalog. Caller passes the
    /// substring AFTER the `:` and BEFORE the caret — e.g., for `:ta` the
    /// prefix is `"ta"`.
    func update(prefix: String?) {
        guard let p = prefix, !p.isEmpty else {
            dismiss()
            return
        }
        // Validate: only alphanumeric + underscore are valid in shortcodes.
        // Anything else means we're not in a shortcode context anymore.
        let valid = p.unicodeScalars.allSatisfy { s in
            CharacterSet.alphanumerics.contains(s) || s == "_"
        }
        guard valid else {
            dismiss()
            return
        }
        let hits = EmojiCatalog.search(p)
        if hits.isEmpty {
            // Keep the popup open with "no matches" feel? For now just
            // dismiss — less visual noise.
            dismiss()
            return
        }
        self.prefix = p
        self.matches = Array(hits.prefix(8))
        if self.selectedIndex >= self.matches.count {
            self.selectedIndex = 0
        }
    }

    func dismiss() {
        prefix = nil
        matches = []
        selectedIndex = 0
    }

    func moveSelection(by delta: Int) {
        guard !matches.isEmpty else { return }
        let n = matches.count
        selectedIndex = ((selectedIndex + delta) % n + n) % n
    }
}

/// Floating popup rendered above the composer input when shortcode
/// autocomplete is active. Up to 8 matches; highlighted row mirrors the
/// keyboard selection state. Clicking a row commits via `onCommit`.
struct EmojiAutocompletePopup: View {
    @Bindable var state: EmojiAutocompleteState
    let onCommit: (EmojiCatalog.Entry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(state.matches.enumerated()), id: \.element.id) { idx, entry in
                Button {
                    state.selectedIndex = idx
                    onCommit(entry)
                } label: {
                    HStack(spacing: 8) {
                        Text(entry.emoji)
                            .font(.system(size: 18))
                            .frame(width: 24)
                        Text(":\(entry.name):")
                            .font(.system(size: 12))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        idx == state.selectedIndex
                            ? Color.accentColor.opacity(0.20)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { state.selectedIndex = idx }
                }
            }
            if let prefix = state.prefix {
                Divider().opacity(0.4)
                HStack {
                    Text("`:\(prefix)`  ·  ↑↓ to move  ·  ⇥ or ↩ to insert  ·  esc to dismiss")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
        }
        .frame(width: 300)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.gray.opacity(0.25), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}
