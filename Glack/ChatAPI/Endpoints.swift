import Foundation

enum ChatEndpoint {
    static let base = URL(string: "https://chat.googleapis.com/v1")!
    static let peopleBase = URL(string: "https://people.googleapis.com/v1")!
    static let adminBase = URL(string: "https://admin.googleapis.com/admin/directory/v1")!

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

    /// People API — batch directory listing for the current user's Workspace org.
    /// Requires the `https://www.googleapis.com/auth/directory.readonly` scope.
    /// Repeats `sources` to capture both org members (DOMAIN_PROFILE) and
    /// shared directory contacts (DOMAIN_CONTACT).
    static func listDirectoryPeople(pageToken: String? = nil, pageSize: Int = 1000) -> URL {
        var comps = URLComponents(url: peopleBase.appendingPathComponent("people:listDirectoryPeople"),
                                  resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"),
            URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"),
            URLQueryItem(name: "readMask", value: "names,photos,emailAddresses,metadata"),
            URLQueryItem(name: "pageSize", value: String(pageSize)),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        comps.queryItems = items
        return comps.url!
    }

    /// People API — `people:batchGet` resolves a known list of user resource
    /// names (e.g. derived from message senders / space members) into profile
    /// info. Up to 50 resource names per call. Useful when listDirectoryPeople
    /// returns empty because of admin sharing settings.
    static func peopleBatchGet(resourceNames: [String]) -> URL {
        var comps = URLComponents(url: peopleBase.appendingPathComponent("people:batchGet"),
                                  resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "personFields", value: "names,photos,emailAddresses,metadata"),
        ]
        for rn in resourceNames {
            items.append(URLQueryItem(name: "resourceNames", value: rn))
        }
        comps.queryItems = items
        return comps.url!
    }

    /// Admin SDK Directory API — list every user in the signed-in admin's
    /// Workspace customer. Requires `admin.directory.user.readonly` scope
    /// AND the signed-in user must be a Workspace admin. Returns ALL fields
    /// (name, email, photo URL) without the privacy stripping People API does.
    static func adminListUsers(pageToken: String? = nil, maxResults: Int = 500) -> URL {
        var comps = URLComponents(url: adminBase.appendingPathComponent("users"),
                                  resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "customer", value: "my_customer"),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
            URLQueryItem(name: "projection", value: "full"),
        ]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        comps.queryItems = items
        return comps.url!
    }
}
