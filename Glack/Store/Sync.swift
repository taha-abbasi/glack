import Foundation
import GRDB
import Observation

/// Admin SDK returns base64 in the URL-safe variant (uses `-` and `_`
/// instead of `+` and `/`). Standard `Data(base64Encoded:)` won't decode it.
extension Data {
    init?(base64URLEncoded s: String) {
        var fixed = s.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        while fixed.count % 4 != 0 { fixed.append("=") }
        guard let data = Data(base64Encoded: fixed) else { return nil }
        self = data
    }
}

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
        await syncSections()
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
        await resolveBotNames()
        lastSyncedAt = Date()
    }

    func refreshAll() async {
        await syncSpaces()
        await syncSections()
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

    /// Delete a message authored by the signed-in user. Marks `deletedAt`
    /// locally so the row vanishes immediately (the observer filters it
    /// out); if the API call fails, restores the row. On success drops the
    /// row entirely. `force=true` is destructive — sends only when the
    /// caller has explicitly confirmed deleting thread replies.
    func deleteMessage(messageName: String, force: Bool = false) async throws {
        let now = Date()
        try await Database.shared.write { db in
            try db.execute(
                sql: "UPDATE message SET deletedAt = ? WHERE id = ?",
                arguments: [now, messageName]
            )
        }
        do {
            try await ChatAPIClient.shared.deleteMessage(messageName: messageName, force: force)
            try await Database.shared.write { db in
                try MessageRecord.deleteOne(db, key: messageName)
            }
            Log.sync.info("deleteMessage \(messageName, privacy: .public) ok force=\(force ? "true" : "false", privacy: .public)")
        } catch {
            try? await Database.shared.write { db in
                try db.execute(
                    sql: "UPDATE message SET deletedAt = NULL WHERE id = ?",
                    arguments: [messageName]
                )
            }
            Log.sync.error("deleteMessage \(messageName, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    /// Add a Unicode emoji reaction to a message and refresh the visible
    /// space so the summary chip strip updates without waiting on the
    /// 30-second poll.
    func addReaction(messageName: String, unicode: String) async {
        do {
            _ = try await ChatAPIClient.shared.addUnicodeReaction(messageName: messageName, unicode: unicode)
            // The space-id is the messageName's first two segments.
            let spaceID = messageName.split(separator: "/").prefix(2).joined(separator: "/")
            await syncRecentMessages(spaceID: spaceID, pageSize: 25)
        } catch {
            Log.sync.error("addReaction(\(unicode, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func encodeReactions(_ summaries: [GEmojiReactionSummary]?) -> String? {
        guard let s = summaries, !s.isEmpty,
              let data = try? JSONEncoder().encode(s),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    /// Send a plain-text message with optimistic local insert, optionally
    /// as a reply in an existing thread. Writes a `pending-{uuid}` row
    /// immediately so the UI updates without waiting on the network; on
    /// success swaps it for the server's canonical row; on failure removes
    /// the temp row and rethrows so the caller can restore the composer.
    func sendMessage(spaceID: String, text: String, threadName: String? = nil) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tempID = "pending-\(UUID().uuidString)"
        let now = Date()
        let me = Session.shared.currentUserID
        let optimistic = MessageRecord(
            id: tempID,
            spaceId: spaceID,
            senderId: me,
            senderName: nil,
            text: text,
            textPlain: text,
            createdAt: now,
            updatedAt: nil,
            threadId: threadName,
            deletedAt: nil,
            attachmentCount: 0,
            rawJson: nil,
            reactionsJson: nil
        )
        try await Database.shared.write { db in
            var r = optimistic
            try r.insert(db)
        }
        do {
            let server = try await ChatAPIClient.shared.sendMessage(spaceID: spaceID, text: text, threadName: threadName)
            try await Database.shared.write { db in
                try MessageRecord.deleteOne(db, key: tempID)
                var record = MessageRecord(
                    id: server.name,
                    spaceId: spaceID,
                    senderId: server.sender?.name,
                    senderName: server.sender?.displayName,
                    text: server.text ?? server.argumentText ?? server.formattedText,
                    textPlain: Self.plainText(from: server),
                    createdAt: APIDate.parse(server.createTime) ?? now,
                    updatedAt: APIDate.parse(server.lastUpdateTime),
                    threadId: server.thread?.name,
                    deletedAt: APIDate.parse(server.deleteTime),
                    attachmentCount: server.attachment?.count ?? 0,
                    rawJson: nil,
                    reactionsJson: Self.encodeReactions(server.emojiReactionSummaries)
                )
                try record.save(db)
            }
            Log.sync.info("sendMessage to \(spaceID, privacy: .public) succeeded")
        } catch {
            try? await Database.shared.write { db in
                try MessageRecord.deleteOne(db, key: tempID)
            }
            Log.sync.error("sendMessage to \(spaceID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
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
            let me = Session.shared.currentUserID
            let viewing = Session.shared.currentlyViewingSpaceID
            // Collect newly-arrived, notify-worthy messages — bound by
            // `lastSyncedAt` so the first-ever sync after sign-in doesn't
            // dump a notification per backfilled message.
            let cutoff = lastSyncedAt
            struct NewMessage { let id: String; let senderName: String?; let senderID: String?; let text: String }
            let newOnes: [NewMessage] = try await Database.shared.write { db -> [NewMessage] in
                var collected: [NewMessage] = []
                // Snapshot existing IDs so we can detect inserts vs upserts
                // without doing N queries.
                let existingIDs: Set<String> = try Set(
                    String.fetchAll(db,
                                    sql: "SELECT id FROM message WHERE spaceId = ?",
                                    arguments: [spaceID])
                )
                var insertedCount = 0
                var insertedFromOthers = 0
                for m in messages {
                    if APIDate.parse(m.deleteTime) != nil {
                        try MessageRecord.deleteOne(db, key: m.name)
                        continue
                    }
                    let isNew = !existingIDs.contains(m.name)
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
                        deletedAt: nil,
                        attachmentCount: m.attachment?.count ?? 0,
                        rawJson: nil,
                        reactionsJson: Self.encodeReactions(m.emojiReactionSummaries)
                    )
                    try record.save(db)
                    if isNew {
                        insertedCount += 1
                        let fromMe = (m.sender?.name == me)
                        let isViewing = (spaceID == viewing)
                        let createdAt = APIDate.parse(m.createTime) ?? Date()
                        // Notify when: new row, not from me, not the open space,
                        // and arrived after lastSyncedAt (so initial backfill
                        // doesn't carpet-bomb the user).
                        if !fromMe, !isViewing, cutoff == nil || createdAt > (cutoff ?? .distantPast) {
                            insertedFromOthers += 1
                            collected.append(NewMessage(
                                id: m.name,
                                senderName: m.sender?.displayName,
                                senderID: m.sender?.name,
                                text: record.textPlain ?? record.text ?? ""
                            ))
                        }
                    }
                }
                if insertedFromOthers > 0 {
                    try db.execute(
                        sql: "UPDATE space SET unreadCount = unreadCount + ? WHERE id = ?",
                        arguments: [insertedFromOthers, spaceID]
                    )
                }
                if let newest = messages.compactMap({ APIDate.parse($0.createTime) }).max() {
                    try db.execute(
                        sql: "UPDATE space SET lastActivityAt = MAX(COALESCE(lastActivityAt, 0), ?) WHERE id = ?",
                        arguments: [newest, spaceID]
                    )
                }
                return collected
            }
            // Fire notifications outside the DB write transaction.
            if !newOnes.isEmpty {
                await postNotifications(for: newOnes.map { ($0.id, $0.senderName, $0.senderID, $0.text) },
                                        spaceID: spaceID)
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Post UN notifications for newly-arrived messages. Looks up the space
    /// display name + a richer sender name from local DB before firing.
    private func postNotifications(for messages: [(id: String, senderName: String?, senderID: String?, text: String)],
                                   spaceID: String) async {
        // Resolve space title + sender names from local DB for prettier copy.
        let spaceTitle: String? = try? await Database.shared.read { db in
            try String.fetchOne(db,
                                sql: "SELECT displayName FROM space WHERE id = ? LIMIT 1",
                                arguments: [spaceID])
        }
        for msg in messages {
            let resolvedSender: String? = try? await Database.shared.read { db -> String? in
                guard let sid = msg.senderID else { return msg.senderName }
                return try String.fetchOne(db,
                                           sql: "SELECT displayName FROM user WHERE id = ? LIMIT 1",
                                           arguments: [sid]) ?? msg.senderName
            }
            let title = resolvedSender ?? msg.senderName ?? "New message"
            let subtitle = spaceTitle?.isEmpty == false ? spaceTitle : nil
            let body = String(msg.text.prefix(280))
            await NotificationManager.shared.postMessage(
                messageID: msg.id,
                title: title,
                subtitle: subtitle,
                body: body
            )
        }
    }

    /// Clear unread state on a space. Called from the UI when the user opens
    /// the conversation.
    func markRead(spaceID: String) async {
        try? await Database.shared.write { db in
            try db.execute(
                sql: "UPDATE space SET unreadCount = 0, lastReadAt = ? WHERE id = ?",
                arguments: [Date(), spaceID]
            )
        }
    }

    /// Pull the user's sidebar section structure: system sections
    /// (DEFAULT_DIRECT_MESSAGES / DEFAULT_SPACES / DEFAULT_APPS) plus any
    /// custom sections they've created. Spaces get assigned to sections via
    /// the section_item table — same multi-section UI Chat web app renders.
    private func syncSections() async {
        do {
            Log.sync.info("syncSections() — fetching sections + items")
            let sections = try await ChatAPIClient.shared.listAllSections(userResource: "users/me")
            Log.sync.info("got \(sections.count) sections")

            // The wildcard `sections/-/items` endpoint returns HTTP 500
            // (Google API bug, confirmed 2026-05). Fetch items per section
            // in parallel instead.
            let itemsBySection: [(String, [GSectionItem])] = try await withThrowingTaskGroup(of: (String, [GSectionItem]).self) { group in
                for s in sections {
                    group.addTask {
                        let items = try await ChatAPIClient.shared.listSectionItems(sectionName: s.name)
                        return (s.name, items)
                    }
                }
                var out: [(String, [GSectionItem])] = []
                for try await result in group { out.append(result) }
                return out
            }
            let totalItems = itemsBySection.reduce(0) { $0 + $1.1.count }
            Log.sync.info("got \(totalItems) section items across \(sections.count) sections")

            try await Database.shared.write { db in
                // Replace strategy: wipe + rewrite. Sections + items are small
                // and may have been reordered server-side.
                try db.execute(sql: "DELETE FROM section_item")
                try db.execute(sql: "DELETE FROM section")
                for s in sections {
                    let isSystem = (s.type ?? "") != "CUSTOM_SECTION"
                    var record = SectionRecord(
                        id: s.name,
                        displayName: s.displayName,
                        sectionType: isSystem ? "SYSTEM" : "CUSTOM",
                        systemSectionType: isSystem ? s.type : nil,
                        sortOrder: s.sortOrder ?? 0
                    )
                    try record.insert(db)
                }
                for (sectionName, items) in itemsBySection {
                    for (idx, item) in items.enumerated() {
                        guard let space = item.space else { continue }
                        var record = SectionItemRecord(
                            sectionId: sectionName,
                            spaceId: space,
                            sortOrder: idx
                        )
                        try record.insert(db)
                    }
                }
            }
        } catch {
            Log.sync.error("syncSections failed: \(error.localizedDescription, privacy: .public)")
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
    /// if we should fall back to People API.
    ///
    /// Admin SDK gives us authoritative names + emails for the whole org, but
    /// its `thumbnailPhotoUrl` is the *Workspace directory* photo (admins set
    /// these explicitly — usually defaults to a silhouette). For real
    /// personal profile photos we layer People API photos on top, dropping
    /// any flagged `default: true`.
    private func syncViaAdminDirectory() async -> Bool {
        do {
            Log.sync.info("syncViaAdminDirectory() — trying admin path")
            let users = try await ChatAPIClient.shared.listAdminUsers()
            Log.sync.info("Admin Directory returned \(users.count) users")
            guard !users.isEmpty else { return false }
            // Persist Admin SDK data — names + emails. Leave photoUrl=nil so the
            // People API pass can fill in only real (non-default) photos.
            try await Database.shared.write { db in
                let now = Date()
                for u in users where u.suspended != true {
                    let chatID = "users/\(u.id)"
                    var record = UserRecord(
                        id: chatID,
                        displayName: u.name?.fullName,
                        givenName: u.name?.givenName,
                        familyName: u.name?.familyName,
                        photoUrl: nil,
                        email: u.primaryEmail,
                        lastSyncedAt: now
                    )
                    try record.save(db)
                }
            }
            // Second pass: enrich with real photos via People API batchGet.
            // (isDefault filter already drops Google's silhouettes.)
            await enrichPhotosFromPeopleAPI(userIDs: users.map { "users/\($0.id)" })
            return true
        } catch {
            Log.sync.info("Admin Directory not usable: \(error.localizedDescription, privacy: .public) — falling back to People API")
            return false
        }
    }

    /// Resolve real Workspace photos per-user via Admin SDK's `users.photos.get`
    /// endpoint, which returns the user's actual photo as inline base64 bytes
    /// (not a URL). This is the only path that surfaces the photo Workspace
    /// web apps render — People API silhouettes a non-self user's profile
    /// photo regardless of project location or sources/readMask combo.
    ///
    /// We decode the base64 and save as a PNG in Application Support, then
    /// store a `file://` URL in user.photoUrl so CachedAvatar loads from disk.
    private func enrichPhotosFromPeopleAPI(userIDs: [String]) async {
        guard !userIDs.isEmpty else { return }
        let recordsByID: [String: UserRecord] = (try? await Database.shared.read { db in
            try UserRecord.fetchAll(db).reduce(into: [String: UserRecord]()) { acc, r in acc[r.id] = r }
        }) ?? [:]
        let photosDir = (try? Self.photosDirectory()) ?? URL(fileURLWithPath: "/tmp")

        var resolved = 0
        for userID in userIDs {
            guard recordsByID[userID] != nil else { continue }
            // Admin SDK userKey: numeric id (strip our `users/` prefix) OR email.
            let userKey = userID.replacingOccurrences(of: "users/", with: "")
            do {
                guard let photo = try await ChatAPIClient.shared.adminUserPhoto(userKey: userKey),
                      let b64 = photo.photoData,
                      let data = Data(base64URLEncoded: b64) else { continue }
                let ext = (photo.mimeType ?? "image/png").contains("jpeg") ? "jpg" : "png"
                let file = photosDir.appendingPathComponent("\(userKey).\(ext)")
                try data.write(to: file)
                try await Database.shared.write { db in
                    if var r = try UserRecord.fetchOne(db, key: userID) {
                        r.photoUrl = file.absoluteString
                        try r.update(db)
                    }
                }
                resolved += 1
            } catch {
                Log.sync.error("adminUserPhoto(\(userKey, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        Log.sync.info("photo enrichment: resolved \(resolved)/\(userIDs.count) real photos via Admin SDK users.photos.get")
    }

    /// Chat API doesn't expose bot identities via user-auth member listings —
    /// `sender.displayName` is empty even for bot senders. This walks each
    /// singleUserBotDm space's oldest messages looking for the bot's
    /// self-introduction ("Welcome to X", "Thanks for chatting with X", etc.)
    /// and stores the extracted name on the bot's user row so the sidebar
    /// can render "Google Drive" instead of "App 7205".
    private func resolveBotNames() async {
        do {
            // (botUserID, oldestText) pairs across all bot DMs. Order by
            // createdAt ASC so we prioritize the bot's welcome/intro message
            // over later notifications (which often lack the bot's own name).
            let samples = try await Database.shared.read { db -> [(String, String)] in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT m.senderId, m.text
                    FROM message m
                    JOIN space s ON s.id = m.spaceId
                    JOIN member mb ON mb.spaceId = s.id
                    WHERE s.singleUserBotDm = 1
                      AND m.senderId IS NOT NULL
                      AND m.text IS NOT NULL
                      AND m.senderId = mb.userId
                    ORDER BY m.createdAt ASC
                """)
                return rows.compactMap { row in
                    guard let id: String = row["senderId"],
                          let text: String = row["text"] else { return nil }
                    return (id, text)
                }
            }
            // For each bot, try every sample text until one yields a name —
            // welcome message might not be in our local backfill yet, but a
            // later notification might still mention the bot name.
            var nameByBot: [String: String] = [:]
            for (id, text) in samples {
                guard nameByBot[id] == nil, !text.isEmpty else { continue }
                if let name = Self.extractBotName(from: text) {
                    nameByBot[id] = name
                }
            }
            let resolvedNames: [(String, String)] = nameByBot.map { ($0.key, $0.value) }
            try await Database.shared.write { db in
                for (botID, name) in resolvedNames {
                    if var record = try UserRecord.fetchOne(db, key: botID) {
                        guard record.displayName?.isEmpty ?? true else { continue }
                        record.displayName = name
                        try record.update(db)
                    } else {
                        var fresh = UserRecord(
                            id: botID, displayName: name,
                            givenName: nil, familyName: nil,
                            photoUrl: nil, email: nil,
                            lastSyncedAt: Date()
                        )
                        try fresh.insert(db)
                    }
                }
            }
            if !resolvedNames.isEmpty {
                Log.sync.info("resolved \(resolvedNames.count) bot name(s) from welcome messages")
            }
        } catch {
            Log.sync.error("resolveBotNames failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func extractBotName(from text: String) -> String? {
        // Patterns ordered by specificity. First match wins.
        let patterns: [String] = [
            #"Welcome to (?:the )?([A-Za-z0-9 .'-]+?) (?:app|bot)"#,  // "Welcome to the Google Drive app!" OR "Welcome to Polly!"
            #"Thanks for chatting with ([A-Za-z0-9 .'-]+)[!.]"#,       // "Thanks for chatting with GIPHY!"
            #"(?:Hi|Hello|Greetings)[!,]?\s*I'?m\s+([A-Za-z0-9 .'-]+?)[!.,]"#, // "Hi, I'm Calendly!"
            #"I'?m\s+(.+?),\s+(?:your|the)"#,                          // "I'm Meet, your meeting helper"
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { continue }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, range: range),
                  match.numberOfRanges >= 2,
                  let r = Range(match.range(at: 1), in: text) else { continue }
            var name = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Title-case common all-caps names (GIPHY → Giphy).
            if name == name.uppercased() && name.count > 1 {
                name = name.lowercased().capitalized
            }
            // Tighten — drop trailing fluff like " app".
            if let appRange = name.range(of: " app$", options: [.regularExpression, .caseInsensitive]) {
                name = String(name[..<appRange.lowerBound])
            }
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// `~/Library/Application Support/Glack/avatars/` — created on first use.
    private static func photosDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Glack/avatars")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
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
