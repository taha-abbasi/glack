import Foundation

enum ChatEndpoint {
    static let base = URL(string: "https://chat.googleapis.com/v1")!

    static func listSpaces(pageToken: String? = nil, pageSize: Int = 1000) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("spaces"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        comps.queryItems = items
        return comps.url!
    }

    static func listMessages(spaceID: String, pageToken: String? = nil, pageSize: Int = 100, orderBy: String = "createTime desc") -> URL {
        // spaceID is "spaces/AAAAAAAAAA"
        var comps = URLComponents(url: base.appendingPathComponent("\(spaceID)/messages"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "orderBy", value: orderBy),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        comps.queryItems = items
        return comps.url!
    }

    static func listMembers(spaceID: String, pageToken: String? = nil, pageSize: Int = 100) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("\(spaceID)/members"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "showInvited", value: "false"),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        comps.queryItems = items
        return comps.url!
    }

    static func spaceReadState(spaceID: String, currentUser: String = "users/me") -> URL {
        base.appendingPathComponent("\(currentUser)/spaces/\(spaceID.replacingOccurrences(of: "spaces/", with: ""))/spaceReadState")
    }
}
