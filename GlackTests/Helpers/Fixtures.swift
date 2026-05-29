import Foundation
@testable import Glack

/// Deterministic builders for test data. No randomness — predictable inputs
/// make failing tests easy to read and reproduce.
enum Fixtures {
    static let epoch = Date(timeIntervalSince1970: 0)

    static func space(
        id: String = "spaces/AAAAAAAAAA",
        type: SpaceRecord.SpaceType = .space,
        displayName: String? = "general",
        lastActivityAt: Date? = nil
    ) -> SpaceRecord {
        SpaceRecord(
            id: id,
            spaceType: type.rawValue,
            displayName: displayName,
            threaded: false,
            lastActivityAt: lastActivityAt,
            unreadCount: 0,
            lastReadAt: nil,
            backfillOldestSeenId: nil,
            backfillCompleteAt: nil,
            addedAt: epoch
        )
    }

    static func message(
        id: String = "spaces/AAAAAAAAAA/messages/MMMMMMMMMM",
        spaceID: String = "spaces/AAAAAAAAAA",
        senderName: String = "Alice",
        text: String = "hello world",
        createdAt: Date? = nil,
        threadID: String? = nil
    ) -> MessageRecord {
        MessageRecord(
            id: id,
            spaceId: spaceID,
            senderId: "users/UAAAAAAAAA",
            senderName: senderName,
            text: text,
            textPlain: text,
            createdAt: createdAt ?? epoch,
            updatedAt: nil,
            threadId: threadID,
            deletedAt: nil,
            attachmentCount: 0,
            rawJson: nil
        )
    }
}
