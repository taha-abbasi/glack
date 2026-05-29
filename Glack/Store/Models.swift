import Foundation
import GRDB

struct SpaceRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "space"

    enum SpaceType: String, Codable {
        case directMessage = "DIRECT_MESSAGE"
        case space = "SPACE"
        case groupChat = "GROUP_CHAT"
        case unknown = "SPACE_TYPE_UNSPECIFIED"
    }

    var id: String
    var spaceType: String
    var displayName: String?
    var threaded: Bool
    var lastActivityAt: Date?
    var unreadCount: Int
    var lastReadAt: Date?
    var backfillOldestSeenId: String?
    var backfillCompleteAt: Date?
    var addedAt: Date

    var type: SpaceType { SpaceType(rawValue: spaceType) ?? .unknown }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let spaceType = Column(CodingKeys.spaceType)
        static let displayName = Column(CodingKeys.displayName)
        static let lastActivityAt = Column(CodingKeys.lastActivityAt)
        static let unreadCount = Column(CodingKeys.unreadCount)
        static let lastReadAt = Column(CodingKeys.lastReadAt)
    }
}

struct MessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "message"

    var id: String
    var spaceId: String
    var senderId: String?
    var senderName: String?
    var text: String?
    var textPlain: String?
    var createdAt: Date
    var updatedAt: Date?
    var threadId: String?
    var deletedAt: Date?
    var attachmentCount: Int
    var rawJson: String?

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let spaceId = Column(CodingKeys.spaceId)
        static let senderId = Column(CodingKeys.senderId)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let threadId = Column(CodingKeys.threadId)
        static let deletedAt = Column(CodingKeys.deletedAt)
    }
}

struct MemberRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "member"

    var spaceId: String
    var userId: String
    var displayName: String?
    var avatarUrl: String?

    enum Columns {
        static let spaceId = Column(CodingKeys.spaceId)
        static let userId = Column(CodingKeys.userId)
        static let displayName = Column(CodingKeys.displayName)
    }
}
