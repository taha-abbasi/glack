import Foundation

/// Decodes a Pub/Sub-delivered Workspace Events payload and reconciles it
/// into the local DB. Designed to be cheap and idempotent — events can be
/// redelivered, so writes are upserts (or no-ops for unchanged rows).
enum EventProcessor {
    static func process(_ message: PubSubMessage) async {
        guard let raw = message.message.data, let data = Data(base64Encoded: raw, options: .ignoreUnknownCharacters) else {
            Log.sync.error("EventProcessor: pubsub message had no data")
            return
        }
        do {
            let envelope = try JSONDecoder().decode(CloudEventEnvelope.self, from: data)
            try await handle(envelope)
        } catch {
            // Surface as warning; ack happens regardless so we don't loop on
            // a single malformed event.
            Log.sync.error("EventProcessor: decode/process failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func handle(_ env: CloudEventEnvelope) async throws {
        let type = env.type ?? env.ceType ?? ""
        Log.sync.info("event \(type, privacy: .public)")
        switch type {
        case "google.workspace.chat.message.v1.created",
             "google.workspace.chat.message.v1.updated":
            if let m = env.data?.message {
                try await upsertMessage(m)
            }
        case "google.workspace.chat.message.v1.deleted":
            if let m = env.data?.message {
                try await deleteMessage(name: m.name)
            }
        case "google.workspace.chat.reaction.v1.created",
             "google.workspace.chat.reaction.v1.deleted":
            // Reaction events don't ship the message's full updated
            // summary array, so re-pull a small page for the affected space
            // and let syncRecentMessages overwrite the reactionsJson column.
            if let m = env.data?.message, let spaceID = extractSpaceID(messageName: m.name) {
                await Sync.shared.refreshSpace(spaceID)
            } else if let r = env.data?.reaction, let spaceID = extractSpaceID(reactionName: r.name) {
                await Sync.shared.refreshSpace(spaceID)
            }
        case "google.workspace.chat.membership.v1.created",
             "google.workspace.chat.membership.v1.updated",
             "google.workspace.chat.membership.v1.deleted":
            if let mb = env.data?.membership, let spaceID = extractSpaceID(membershipName: mb.name) {
                await Sync.shared.refreshSpace(spaceID)
            }
        case "google.workspace.chat.space.v1.updated":
            // A space-level change (name, settings) — re-pull the spaces list
            // so the sidebar reflects it.
            await Sync.shared.refreshSpaces()
        default:
            break
        }
    }

    // MARK: - Local DB writes

    private static func upsertMessage(_ m: GMessage) async throws {
        guard let spaceID = extractSpaceID(messageName: m.name) else { return }
        // Read main-actor context up front so the DB write closure (Sendable)
        // doesn't try to reach into MainActor state.
        let me = await MainActor.run { Session.shared.currentUserID }
        let viewing = await MainActor.run { Session.shared.currentlyViewingSpaceID }
        let isFromOthers = m.sender?.name != nil && m.sender?.name != me && spaceID != viewing

        // Gate the unread bump on whether this is a genuine INSERT vs an
        // upsert of an already-known row. Without this, Pub/Sub's at-least-
        // once redelivery semantics would double-count the same message —
        // a slow ack triggers redelivery, EventProcessor runs again,
        // unreadCount creeps up forever.
        let wasNewInsert: Bool = try await Database.shared.write { db -> Bool in
            // Deleted server-side → drop locally and stop.
            if APIDate.parse(m.deleteTime) != nil {
                try MessageRecord.deleteOne(db, key: m.name)
                return false
            }
            let existed = try MessageRecord.fetchOne(db, key: m.name) != nil
            var record = MessageRecord(
                id: m.name,
                spaceId: spaceID,
                senderId: m.sender?.name,
                senderName: m.sender?.displayName,
                text: m.text ?? m.argumentText ?? m.formattedText,
                textPlain: Sync.plainText(from: m),
                createdAt: APIDate.parse(m.createTime) ?? Date(),
                updatedAt: APIDate.parse(m.lastUpdateTime),
                threadId: m.thread?.name,
                deletedAt: nil,
                attachmentCount: m.attachment?.count ?? 0,
                rawJson: nil,
                reactionsJson: Sync.encodeReactions(m.emojiReactionSummaries),
                attachmentsJson: Sync.encodeAttachments(m.attachment)
            )
            try record.save(db)
            if let createdAt = APIDate.parse(m.createTime) {
                try db.execute(
                    sql: "UPDATE space SET lastActivityAt = MAX(COALESCE(lastActivityAt, 0), ?) WHERE id = ?",
                    arguments: [createdAt, spaceID]
                )
            }
            if !existed && isFromOthers {
                try db.execute(
                    sql: "UPDATE space SET unreadCount = unreadCount + 1 WHERE id = ?",
                    arguments: [spaceID]
                )
            }
            return !existed
        }
        if wasNewInsert && isFromOthers {
            await postArrivalNotification(message: m, spaceID: spaceID)
        }
    }

    private static func deleteMessage(name: String) async throws {
        try await Database.shared.write { db in
            try MessageRecord.deleteOne(db, key: name)
        }
    }

    private static func postArrivalNotification(message m: GMessage, spaceID: String) async {
        let spaceTitle: String? = try? await Database.shared.read { db in
            try String.fetchOne(db,
                                sql: "SELECT displayName FROM space WHERE id = ? LIMIT 1",
                                arguments: [spaceID])
        }
        let resolvedSender: String? = try? await Database.shared.read { db -> String? in
            guard let sid = m.sender?.name else { return m.sender?.displayName }
            return try String.fetchOne(db,
                                       sql: "SELECT displayName FROM user WHERE id = ? LIMIT 1",
                                       arguments: [sid]) ?? m.sender?.displayName
        }
        let body = (m.text ?? m.argumentText ?? m.formattedText) ?? ""
        await NotificationManager.shared.postMessage(
            messageID: m.name,
            title: resolvedSender ?? m.sender?.displayName ?? "New message",
            subtitle: spaceTitle?.isEmpty == false ? spaceTitle : nil,
            body: String(body.prefix(280))
        )
    }

    // MARK: - Resource-name parsers

    /// `spaces/X/messages/Y` → `spaces/X`
    private static func extractSpaceID(messageName: String) -> String? {
        guard let r = messageName.range(of: "/messages/") else { return nil }
        return String(messageName[..<r.lowerBound])
    }

    /// `spaces/X/messages/Y/reactions/Z` → `spaces/X`
    private static func extractSpaceID(reactionName: String) -> String? {
        extractSpaceID(messageName: reactionName)
    }

    /// `spaces/X/members/Y` → `spaces/X`
    private static func extractSpaceID(membershipName: String) -> String? {
        guard let r = membershipName.range(of: "/members/") else { return nil }
        return String(membershipName[..<r.lowerBound])
    }
}

// MARK: - CloudEvent envelope

/// Workspace Events publishes CloudEvents over Pub/Sub. The envelope has
/// `type`, `source`, and a `data` blob containing the affected resources.
/// With `payloadOptions.includeResource = true`, the resource (message,
/// reaction, etc.) is embedded inline.
struct CloudEventEnvelope: Decodable {
    let type: String?
    let ceType: String?       // older / aliased deliveries
    let source: String?
    let data: EventData?

    enum CodingKeys: String, CodingKey {
        case type
        case ceType = "ce-type"
        case source
        case data
    }
}

struct EventData: Decodable {
    let message: GMessage?
    let reaction: EventReactionRef?
    let membership: EventMembershipRef?
    let space: EventSpaceRef?
}

struct EventReactionRef: Decodable {
    let name: String       // "spaces/X/messages/Y/reactions/Z"
}

struct EventMembershipRef: Decodable {
    let name: String       // "spaces/X/members/Y"
}

struct EventSpaceRef: Decodable {
    let name: String       // "spaces/X"
}
