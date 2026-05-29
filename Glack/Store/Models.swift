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

    // v2 — Daily-Standup-style classification signals.
    var spaceHistoryState: String?
    var spaceUri: String?
    var externalUserAllowed: Bool?
    var singleUserBotDm: Bool?
    var importMode: Bool?
    var adminInstalled: Bool?
    var predefinedPermissionSettings: String?
    var accessState: String?
    var membershipCountHumans: Int?
    var membershipCountGroups: Int?

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
    var reactionsJson: String?

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let spaceId = Column(CodingKeys.spaceId)
        static let senderId = Column(CodingKeys.senderId)
        static let createdAt = Column(CodingKeys.createdAt)
        static let updatedAt = Column(CodingKeys.updatedAt)
        static let threadId = Column(CodingKeys.threadId)
        static let deletedAt = Column(CodingKeys.deletedAt)
    }

    /// Decoded reaction summaries for this message. Returns [] when none or
    /// when the JSON column is missing/malformed — never throws.
    var reactions: [GEmojiReactionSummary] {
        guard let json = reactionsJson, !json.isEmpty,
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([GEmojiReactionSummary].self, from: data)) ?? []
    }
}

struct UserRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "user"

    var id: String                  // "users/{numeric-id}"
    var displayName: String?
    var givenName: String?
    var familyName: String?
    var photoUrl: String?
    var email: String?
    var lastSyncedAt: Date

    var bestDisplayName: String {
        if let dn = displayName, !dn.isEmpty { return dn }
        if let gn = givenName, !gn.isEmpty {
            if let fn = familyName, !fn.isEmpty { return "\(gn) \(fn)" }
            return gn
        }
        return email ?? id
    }

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let displayName = Column(CodingKeys.displayName)
        static let email = Column(CodingKeys.email)
    }
}

struct SectionRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable, Hashable {
    static let databaseTableName = "section"

    var id: String                       // "users/me/sections/{id}"
    var displayName: String?
    var sectionType: String?
    var systemSectionType: String?
    var sortOrder: Int

    enum SystemType: String {
        case directMessages = "DEFAULT_DIRECT_MESSAGES"
        case spaces         = "DEFAULT_SPACES"
        case apps           = "DEFAULT_APPS"
    }

    var systemType: SystemType? { systemSectionType.flatMap(SystemType.init(rawValue:)) }

    /// What to render as the section's header in the sidebar.
    var displayLabel: String {
        if let dn = displayName, !dn.isEmpty { return dn }
        switch systemType {
        case .directMessages: return "Direct Messages"
        case .spaces:         return "Spaces"
        case .apps:           return "Apps"
        case .none:           return "Other"
        }
    }
}

struct SectionItemRecord: Codable, FetchableRecord, MutablePersistableRecord, Hashable {
    static let databaseTableName = "section_item"

    var sectionId: String
    var spaceId: String
    var sortOrder: Int
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
