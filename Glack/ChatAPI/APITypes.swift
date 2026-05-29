import Foundation

// MARK: - API response types (DTOs)
// These mirror the Google Chat REST API exactly; mapping to GRDB records
// happens in ChatAPIClient.

struct GSpace: Decodable {
    let name: String                  // "spaces/AAAAAAAAAA"
    let displayName: String?
    let spaceType: String?            // "SPACE" | "GROUP_CHAT" | "DIRECT_MESSAGE"
    let spaceThreadingState: String?  // "THREADED_MESSAGES" | "GROUPED_MESSAGES"
    let createTime: String?
    let lastActiveTime: String?
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
