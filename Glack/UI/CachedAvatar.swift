import SwiftUI
import AppKit
import Observation

/// SwiftUI's AsyncImage cancels in-flight fetches on every re-render — which
/// happens constantly under @Observable. The result: avatar loads fail with
/// "cancelled" before bytes ever arrive. This is a tiny URL-keyed cache that
/// loads each image exactly once and serves subsequent reads from memory.
@MainActor
@Observable
final class ImageCache {
    static let shared = ImageCache()

    private var memory: [URL: NSImage] = [:]
    private var inFlight: [URL: Task<NSImage?, Never>] = [:]

    private init() {}

    func cached(_ url: URL) -> NSImage? { memory[url] }

    func load(_ url: URL) async -> NSImage? {
        if let img = memory[url] { return img }
        if let existing = inFlight[url] { return await existing.value }

        let task = Task<NSImage?, Never> {
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                return NSImage(data: data)
            } catch {
                return nil
            }
        }
        inFlight[url] = task
        let img = await task.value
        inFlight.removeValue(forKey: url)
        if let img { memory[url] = img }
        return img
    }
}

/// Drop-in replacement for AsyncImage that doesn't cancel on re-render.
/// `.task(id: url)` only re-runs when the URL changes; cached images render
/// instantly on every subsequent appearance.
struct CachedAvatar<Fallback: View>: View {
    let url: URL?
    @ViewBuilder let fallback: () -> Fallback

    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                fallback()
            }
        }
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let cached = ImageCache.shared.cached(url) {
                Log.ui.info("CachedAvatar hit cache for \(url.absoluteString, privacy: .public)")
                image = cached
                return
            }
            Log.ui.info("CachedAvatar fetching \(url.absoluteString, privacy: .public)")
            let loaded = await ImageCache.shared.load(url)
            if loaded != nil {
                Log.ui.info("CachedAvatar loaded \(url.absoluteString, privacy: .public)")
            } else {
                Log.ui.error("CachedAvatar load returned nil for \(url.absoluteString, privacy: .public)")
            }
            image = loaded
        }
    }
}
