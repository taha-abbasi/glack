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

    /// POST a reaction to a message. `messageName` is the full resource name
    /// `spaces/X/messages/Y`.
    static func createReaction(messageName: String) -> URL {
        base.appendingPathComponent("\(messageName)/reactions")
    }

    /// DELETE a message you authored. With `force=true`, the API also deletes
    /// the thread replies (destructive — used only when explicitly confirmed).
    static func deleteMessage(messageName: String, force: Bool = false) -> URL {
        let path = base.appendingPathComponent(messageName)
        guard force else { return path }
        var comps = URLComponents(url: path, resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "force", value: "true")]
        return comps.url!
    }

    /// POST a new message to a space. When `threadReply` is true, the URL
    /// carries `messageReplyOption=REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD` so
    /// the message attaches to the thread named in the request body — Chat
    /// will fall back to starting a new thread if the named one is missing.
    static func createMessage(spaceID: String, threadReply: Bool = false) -> URL {
        let base = self.base.appendingPathComponent("\(spaceID)/messages")
        guard threadReply else { return base }
        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "messageReplyOption", value: "REPLY_MESSAGE_FALLBACK_TO_NEW_THREAD")
        ]
        return comps.url!
    }

    static func listMessages(spaceID: String, pageToken: String? = nil, pageSize: Int = 100, orderBy: String = "createTime desc") -> URL {
        // spaceID is "spaces/AAAAAAAAAA". showDeleted=true so we receive
        // tombstones for deletes that happened server-side and can drop
        // the corresponding local rows.
        var comps = URLComponents(url: base.appendingPathComponent("\(spaceID)/messages"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "pageSize", value: String(pageSize)),
            URLQueryItem(name: "orderBy", value: orderBy),
            URLQueryItem(name: "showDeleted", value: "true"),
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

    /// List the signed-in user's sidebar sections (system + custom).
    /// `userResource` should be a full Chat user resource like `users/{id}`.
    static func listSections(userResource: String, pageToken: String? = nil) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("\(userResource)/sections"),
                                  resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [URLQueryItem(name: "pageSize", value: "100")]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        comps.queryItems = items
        return comps.url!
    }

    /// List items in one specific section. The wildcard `sections/-/items`
    /// endpoint returns HTTP 500 (confirmed Google API bug 2026-05) — fetch
    /// per section instead. `sectionName` is the full resource name like
    /// `users/{id}/sections/{sid}`.
    static func listSectionItems(sectionName: String, pageToken: String? = nil) -> URL {
        var comps = URLComponents(url: base.appendingPathComponent("\(sectionName)/items"),
                                  resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [URLQueryItem(name: "pageSize", value: "100")]
        if let pageToken { items.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        comps.queryItems = items
        return comps.url!
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
    /// info. Up to 50 resource names per call.
    ///
    /// Explicitly requests all source types (PROFILE + CONTACT + DOMAIN_CONTACT)
    /// — with CONTACT/DOMAIN_CONTACT, Google merges the user's contacts photo
    /// (often the real one for coworkers, even when PROFILE is a silhouette).
    /// Default would be PROFILE + CONTACT but DOMAIN_CONTACT also helps for
    /// Workspace org members.
    static func peopleBatchGet(resourceNames: [String]) -> URL {
        var comps = URLComponents(url: peopleBase.appendingPathComponent("people:batchGet"),
                                  resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "personFields", value: "names,photos,emailAddresses,coverPhotos,metadata"),
            URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_PROFILE"),
            URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_CONTACT"),
            URLQueryItem(name: "sources", value: "READ_SOURCE_TYPE_DOMAIN_CONTACT"),
        ]
        for rn in resourceNames {
            items.append(URLQueryItem(name: "resourceNames", value: rn))
        }
        comps.queryItems = items
        return comps.url!
    }

    /// People API — search the Workspace directory by query (typically email
    /// or display name). Empirically returns real Workspace photos that
    /// `people:batchGet` does not, for the same users. This is what Workspace
    /// web apps (Gmail/Chat) use for org-member avatar lookups.
    static func peopleSearchDirectory(query: String) -> URL {
        var comps = URLComponents(url: peopleBase.appendingPathComponent("people:searchDirectoryPeople"),
                                  resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_PROFILE"),
            URLQueryItem(name: "sources", value: "DIRECTORY_SOURCE_TYPE_DOMAIN_CONTACT"),
            URLQueryItem(name: "readMask", value: "names,photos,emailAddresses,metadata"),
            URLQueryItem(name: "pageSize", value: "10"),
        ]
        return comps.url!
    }

    /// Admin SDK Directory API — get a single user's photo as inline base64
    /// bytes (UserPhoto.photoData). Returns the REAL user-uploaded photo,
    /// not the silhouette stripped by People API. `userKey` can be the
    /// numeric ID or primary email.
    static func adminUserPhoto(userKey: String) -> URL {
        adminBase.appendingPathComponent("users/\(userKey)/photos/thumbnail")
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
