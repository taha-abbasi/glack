import Foundation

// MARK: - API response types (DTOs)
// These mirror the Google Chat REST API exactly; mapping to GRDB records
// happens in ChatAPIClient.

struct GSpace: Decodable {
    let name: String                  // "spaces/AAAAAAAAAA"
    let displayName: String?
    let spaceType: String?            // "SPACE" | "GROUP_CHAT" | "DIRECT_MESSAGE"
    let spaceThreadingState: String?  // "THREADED_MESSAGES" | "GROUPED_MESSAGES"
    let spaceHistoryState: String?    // "HISTORY_ON" | "HISTORY_OFF"
    let spaceUri: String?
    let createTime: String?
    let lastActiveTime: String?
    let externalUserAllowed: Bool?
    let singleUserBotDm: Bool?
    let importMode: Bool?
    let adminInstalled: Bool?
    let predefinedPermissionSettings: String?
    let accessSettings: GAccessSettings?
    let membershipCount: GMembershipCount?
}

struct GAccessSettings: Decodable {
    let accessState: String?
    let audience: String?
}

struct GMembershipCount: Decodable {
    let joinedDirectHumanUserCount: Int?
    let joinedGroupCount: Int?
}

struct GListSpacesResponse: Decodable {
    let spaces: [GSpace]?
    let nextPageToken: String?
}

struct GUserRef: Decodable {
    let name: String?         // "users/UUUUUUUUUU"
    let displayName: String?
    let type: String?         // "HUMAN" | "BOT"
}

struct GThread: Decodable {
    let name: String?         // "spaces/X/threads/Y"
}

struct GAttachment: Decodable {
    let name: String?
    let contentName: String?
    let contentType: String?
}

struct GMessage: Decodable {
    let name: String                  // "spaces/X/messages/Y"
    let sender: GUserRef?
    let createTime: String
    let lastUpdateTime: String?
    let deleteTime: String?
    let text: String?
    let argumentText: String?
    let formattedText: String?
    let thread: GThread?
    let attachment: [GAttachment]?
}

struct GListMessagesResponse: Decodable {
    let messages: [GMessage]?
    let nextPageToken: String?
}

struct GMembership: Decodable {
    let name: String?         // "spaces/X/members/U"
    let member: GUserRef?
    let role: String?
}

struct GListMembersResponse: Decodable {
    let memberships: [GMembership]?
    let nextPageToken: String?
}

struct GSpaceReadState: Decodable {
    let name: String?
    let lastReadTime: String?
}

// MARK: - People API DTOs

struct GPersonName: Decodable {
    let displayName: String?
    let givenName: String?
    let familyName: String?
}

struct GPersonPhoto: Decodable {
    let url: String?
    let isDefault: Bool?

    enum CodingKeys: String, CodingKey {
        case url
        case isDefault = "default"   // Google's JSON uses "default" (Swift reserved word)
    }
}

struct GPersonEmail: Decodable {
    let value: String?
    let metadata: GPersonFieldMetadata?
}

struct GPersonFieldMetadata: Decodable {
    let primary: Bool?
}

struct GPerson: Decodable {
    let resourceName: String        // "people/{numeric-id}"
    let names: [GPersonName]?
    let photos: [GPersonPhoto]?
    let emailAddresses: [GPersonEmail]?
}

struct GListDirectoryPeopleResponse: Decodable {
    let people: [GPerson]?
    let nextPageToken: String?
    let nextSyncToken: String?
}

struct GPersonResponse: Decodable {
    let httpStatusCode: Int?
    let person: GPerson?
    let requestedResourceName: String?
}

struct GBatchGetPeopleResponse: Decodable {
    let responses: [GPersonResponse]?
}

struct GSearchDirectoryPeopleResponse: Decodable {
    let people: [GPerson]?
    let nextPageToken: String?
    let totalSize: Int?
}

// MARK: - Admin SDK Directory API DTOs

struct GAdminUserName: Decodable {
    let givenName: String?
    let familyName: String?
    let fullName: String?
}

struct GAdminUser: Decodable {
    let id: String            // numeric ID, matches what People API uses
    let primaryEmail: String?
    let name: GAdminUserName?
    let thumbnailPhotoUrl: String?
    let suspended: Bool?
}

struct GAdminUsersListResponse: Decodable {
    let users: [GAdminUser]?
    let nextPageToken: String?
}

/// Admin SDK users.photos.get returns photo bytes inline (base64), not a URL.
/// Empirically this returns the *real* uploaded photo for org users — the
/// same photo Workspace web apps render — bypassing the People API silhouette.
struct GAdminUserPhoto: Decodable {
    let id: String?
    let primaryEmail: String?
    let mimeType: String?
    let width: Int?
    let height: Int?
    let photoData: String?   // base64-encoded image bytes (URL-safe variant)
}

// MARK: - Date parsing

enum APIDate {
    // ISO8601DateFormatter is documented as thread-safe; nonisolated(unsafe)
    // is the right Swift 6 escape hatch.
    nonisolated(unsafe) private static let rfc3339: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) private static let rfc3339NoFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parse(_ s: String?) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        return rfc3339.date(from: s) ?? rfc3339NoFraction.date(from: s)
    }
}
