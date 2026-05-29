import Foundation
import GRDB
import Observation

/// Pulls spaces + recent messages from the Chat API into the local DB.
/// Phase 2 scope: snapshot on launch, recent page per space, periodic re-sync.
@MainActor
@Observable
final class Sync {
    static let shared = Sync()

    private(set) var isRunning: Bool = false
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?

    private var pollTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard pollTask == nil else { return }
        Log.sync.info("Sync.start()")
        isRunning = true
        pollTask = Task { [weak self] in
            // First snapshot immediately, then every 30s.
            await self?.fullSnapshot()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.refreshAll()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
    }

    // MARK: - One-shot operations

    func fullSnapshot() async {
        await syncSpaces()
        // Pull a recent page for each space so the UI has something immediately.
        // Phase 2b will deepen this into full backfill with rate limiting.
        let spaceIDs = (try? await Database.shared.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM space ORDER BY lastActivityAt DESC NULLS LAST")
        }) ?? []
        for id in spaceIDs {
            await syncRecentMessages(spaceID: id, pageSize: 50)
            await syncMembers(spaceID: id)
        }
        lastSyncedAt = Date()
    }

    func refreshAll() async {
        await syncSpaces()
        let spaceIDs = (try? await Database.shared.read { db in
            try String.fetchAll(db, sql: "SELECT id FROM space")
        }) ?? []
        for id in spaceIDs {
            await syncRecentMessages(spaceID: id, pageSize: 25)
        }
        lastSyncedAt = Date()
    }

    func syncVisibleSpace(_ spaceID: String) async {
        await syncRecentMessages(spaceID: spaceID, pageSize: 50)
        await syncMembers(spaceID: spaceID)
    }

    // MARK: - Per-resource syncs

    private func syncSpaces() async {
        do {
            Log.sync.info("syncSpaces() — calling listAllSpaces")
            let spaces = try await ChatAPIClient.shared.listAllSpaces()
            Log.sync.info("syncSpaces() — got \(spaces.count) spaces")
            try await Database.shared.write { db in
                let now = Date()
                for s in spaces {
                    var record = SpaceRecord(
                        id: s.name,
                        spaceType: s.spaceType ?? "SPACE_TYPE_UNSPECIFIED",
                        displayName: s.displayName,
                        threaded: (s.spaceThreadingState ?? "") == "THREADED_MESSAGES",
                        lastActivityAt: APIDate.parse(s.lastActiveTime),
                        unreadCount: 0,
                        lastReadAt: nil,
                        backfillOldestSeenId: nil,
                        backfillCompleteAt: nil,
                        addedAt: now
                    )
                    // Upsert: keep our locally-tracked unreadCount/lastReadAt/backfill state.
                    if let existing = try SpaceRecord.fetchOne(db, key: s.name) {
                        record.unreadCount = existing.unreadCount
                        record.lastReadAt = existing.lastReadAt
                        record.backfillOldestSeenId = existing.backfillOldestSeenId
                        record.backfillCompleteAt = existing.backfillCompleteAt
                        record.addedAt = existing.addedAt
                    }
                    try record.save(db)
                }
            }
            lastError = nil
        } catch {
            Log.sync.error("syncSpaces failed: \(error.localizedDescription, privacy: .public)")
            lastError = error.localizedDescription
        }
    }

    private func syncRecentMessages(spaceID: String, pageSize: Int) async {
        do {
            let resp = try await ChatAPIClient.shared.listMessages(
                spaceID: spaceID, pageToken: nil, pageSize: pageSize, orderBy: "createTime desc"
            )
            let messages = resp.messages ?? []
            try await Database.shared.write { db in
                for m in messages {
                    var record = MessageRecord(
                        id: m.name,
                        spaceId: spaceID,
                        senderId: m.sender?.name,
                        senderName: m.sender?.displayName,
                        text: m.text ?? m.argumentText ?? m.formattedText,
                        textPlain: Self.plainText(from: m),
                        createdAt: APIDate.parse(m.createTime) ?? Date(),
                        updatedAt: APIDate.parse(m.lastUpdateTime),
                        threadId: m.thread?.name,
                        deletedAt: APIDate.parse(m.deleteTime),
                        attachmentCount: m.attachment?.count ?? 0,
                        rawJson: nil
                    )
                    try record.save(db)
                }
                // Bump space.lastActivityAt from messages we just saw (in case
                // the spaces endpoint lags).
                if let newest = messages.compactMap({ APIDate.parse($0.createTime) }).max() {
                    try db.execute(
                        sql: "UPDATE space SET lastActivityAt = MAX(COALESCE(lastActivityAt, 0), ?) WHERE id = ?",
                        arguments: [newest, spaceID]
                    )
                }
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func syncMembers(spaceID: String) async {
        do {
            let resp = try await ChatAPIClient.shared.listMembers(spaceID: spaceID)
            try await Database.shared.write { db in
                for m in resp.memberships ?? [] {
                    guard let userRef = m.member, let userID = userRef.name else { continue }
                    var record = MemberRecord(
                        spaceId: spaceID,
                        userId: userID,
                        displayName: userRef.displayName,
                        avatarUrl: nil
                    )
                    try record.save(db)
                }
            }
        } catch {
            // Membership listing can 403 in some spaces (e.g. Google's "Welcome" spaces);
            // not worth surfacing to the user. Just swallow per-space.
        }
    }

    nonisolated private static func plainText(from m: GMessage) -> String {
        let raw = m.text ?? m.argumentText ?? m.formattedText ?? ""
        // Phase 2 normalization: strip Google's mention syntax <users/X> → @ + sender name when present.
        // Phase 2b will do deeper normalization.
        return raw
            .replacingOccurrences(of: "<users/", with: "@")
            .replacingOccurrences(of: ">", with: "")
    }
}
