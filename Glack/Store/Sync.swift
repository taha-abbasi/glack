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
        // Directory sync LAST — by now we have member/sender IDs to batchGet on.
        await syncDirectoryPeople()
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
        await syncDirectoryPeople()
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
                        addedAt: now,
                        spaceHistoryState: s.spaceHistoryState,
                        spaceUri: s.spaceUri,
                        externalUserAllowed: s.externalUserAllowed,
                        singleUserBotDm: s.singleUserBotDm,
                        importMode: s.importMode,
                        adminInstalled: s.adminInstalled,
                        predefinedPermissionSettings: s.predefinedPermissionSettings,
                        accessState: s.accessSettings?.accessState,
                        membershipCountHumans: s.membershipCount?.joinedDirectHumanUserCount,
                        membershipCountGroups: s.membershipCount?.joinedGroupCount
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

    private func syncDirectoryPeople() async {
        // 0) PREFERRED: Admin SDK Directory API — returns ALL fields if signed-in
        //    user is a Workspace admin. People API strips names/emails for
        //    non-self users regardless of project location, so this is the
        //    only universal-data path for admin users.
        if await syncViaAdminDirectory() {
            return
        }

        do {
            Log.sync.info("syncDirectoryPeople()")
            // 1) Try the bulk directory listing first.
            let bulk = try await ChatAPIClient.shared.listAllDirectoryPeople()
            Log.sync.info("listDirectoryPeople returned \(bulk.count) people")

            // 2) If empty (admin policy blocks bulk org listing), fall back
            //    to batchGet for every userID we've seen in messages/members.
            let people: [GPerson]
            if bulk.isEmpty {
                let knownIDs = (try? await Database.shared.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT DISTINCT senderId FROM message WHERE senderId IS NOT NULL
                        UNION
                        SELECT DISTINCT userId FROM member
                    """)
                }) ?? []
                Log.sync.info("listDirectoryPeople empty; batchGet for \(knownIDs.count) known IDs")
                people = knownIDs.isEmpty ? [] : (try await ChatAPIClient.shared.batchGetPeople(userIDs: knownIDs))
                Log.sync.info("batchGetPeople returned \(people.count) people")
            } else {
                people = bulk
            }

            try await Database.shared.write { db in
                let now = Date()
                for p in people {
                    let id = p.resourceName.replacingOccurrences(of: "people/", with: "users/")
                    let primaryName = p.names?.first
                    // Only keep real user-uploaded photos. Google serves a generic
                    // gray silhouette (~564 bytes, isDefault=true) for users with
                    // no photo set OR users whose photos aren't shared with
                    // external apps — we'd rather show initials than a fake face.
                    let primaryPhoto = p.photos?.first { $0.isDefault != true }
                    let primaryEmail = (p.emailAddresses?.first { $0.metadata?.primary == true } ?? p.emailAddresses?.first)?.value
                    var record = UserRecord(
                        id: id,
                        displayName: primaryName?.displayName,
                        givenName: primaryName?.givenName,
                        familyName: primaryName?.familyName,
                        photoUrl: primaryPhoto?.url,
                        email: primaryEmail,
                        lastSyncedAt: now
                    )
                    try record.save(db)
                }
            }
        } catch {
            Log.sync.error("syncDirectoryPeople failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Try the Admin SDK Directory API path. Returns true if we successfully
    /// populated the user table (signed-in user is a Workspace admin), false
    /// if we should fall back to People API (e.g. 403 — not an admin, or
    /// scope not yet granted via a fresh sign-in).
    private func syncViaAdminDirectory() async -> Bool {
        do {
            Log.sync.info("syncViaAdminDirectory() — trying admin path")
            let users = try await ChatAPIClient.shared.listAdminUsers()
            Log.sync.info("Admin Directory returned \(users.count) users")
            guard !users.isEmpty else { return false }
            try await Database.shared.write { db in
                let now = Date()
                for u in users where u.suspended != true {
                    let chatID = "users/\(u.id)"
                    var record = UserRecord(
                        id: chatID,
                        displayName: u.name?.fullName,
                        givenName: u.name?.givenName,
                        familyName: u.name?.familyName,
                        photoUrl: u.thumbnailPhotoUrl,
                        email: u.primaryEmail,
                        lastSyncedAt: now
                    )
                    try record.save(db)
                }
            }
            return true
        } catch {
            Log.sync.info("Admin Directory not usable: \(error.localizedDescription, privacy: .public) — falling back to People API")
            return false
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
