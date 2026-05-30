import Foundation

enum ChatAPIError: LocalizedError {
    case http(status: Int, body: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "Chat API HTTP \(status): \(body.prefix(200))"
        case .malformedResponse:
            return "Chat API returned a response Glack couldn't decode."
        }
    }
}

actor ChatAPIClient {
    static let shared = ChatAPIClient()

    private let session: URLSession
    private let decoder: JSONDecoder

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    // MARK: - Public API

    func listAllSpaces() async throws -> [GSpace] {
        var all: [GSpace] = []
        var pageToken: String?
        repeat {
            let url = ChatEndpoint.listSpaces(pageToken: pageToken, pageSize: 1000)
            let response: GListSpacesResponse = try await getJSON(url)
            if let spaces = response.spaces { all.append(contentsOf: spaces) }
            pageToken = response.nextPageToken
        } while pageToken != nil && !pageToken!.isEmpty
        return all
    }

    func listMessages(spaceID: String, pageToken: String? = nil, pageSize: Int = 100, orderBy: String = "createTime desc", filter: String? = nil) async throws -> GListMessagesResponse {
        let url = ChatEndpoint.listMessages(spaceID: spaceID, pageToken: pageToken, pageSize: pageSize, orderBy: orderBy, filter: filter)
        return try await getJSON(url)
    }

    /// Send a plain-text message to a space, optionally as a reply in an
    /// existing thread, optionally with one or more attachments. Each
    /// attachment must already be uploaded via `uploadAttachment` so we
    /// have its `resourceName`.
    func sendMessage(spaceID: String, text: String,
                     threadName: String? = nil,
                     attachmentResourceNames: [String] = []) async throws -> GMessage {
        let url = ChatEndpoint.createMessage(spaceID: spaceID, threadReply: threadName != nil)
        let body = GMessageCreateBody(
            text: text,
            thread: threadName.map { .init(name: $0) },
            attachment: attachmentResourceNames.isEmpty ? nil : attachmentResourceNames.map {
                .init(attachmentDataRef: .init(resourceName: $0))
            }
        )
        return try await postJSON(url, body: body)
    }

    /// Upload a file's raw bytes to a space and return the
    /// `attachmentDataRef.resourceName` that `sendMessage` can attach.
    /// The Chat API uses `uploadType=media` for a single-part raw upload
    /// — Content-Type is the file MIME, body is the raw bytes.
    func uploadAttachment(spaceID: String, fileURL: URL) async throws -> String {
        let filename = fileURL.lastPathComponent
        let mime = Self.mimeType(for: fileURL)
        let data = try Data(contentsOf: fileURL)
        let url = ChatEndpoint.uploadAttachment(spaceID: spaceID, filename: filename)
        let token = try await Session.shared.accessToken()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(mime, forHTTPHeaderField: "Content-Type")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.httpBody = data
        let (responseData, resp) = try await session.upload(for: req, from: data)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else {
            let body = String(data: responseData, encoding: .utf8) ?? ""
            throw ChatAPIError.http(status: status, body: body)
        }
        let parsed = try decoder.decode(GAttachmentUploadResponse.self, from: responseData)
        guard let resourceName = parsed.attachmentDataRef.resourceName else {
            throw ChatAPIError.malformedResponse
        }
        return resourceName
    }

    /// Best-effort MIME from extension. Falls back to octet-stream.
    private static func mimeType(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png":  return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif":  return "image/gif"
        case "webp": return "image/webp"
        case "heic", "heif": return "image/heic"
        case "pdf":  return "application/pdf"
        case "mp4":  return "video/mp4"
        case "mov":  return "video/quicktime"
        case "mp3":  return "audio/mpeg"
        case "txt", "log", "md": return "text/plain"
        case "json": return "application/json"
        case "csv":  return "text/csv"
        case "zip":  return "application/zip"
        case "doc":  return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls":  return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt":  return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default:     return "application/octet-stream"
        }
    }

    /// Edit a message you authored. Returns the patched GMessage with the
    /// updated text + lastUpdateTime.
    func editMessage(messageName: String, text: String) async throws -> GMessage {
        let url = ChatEndpoint.patchMessage(messageName: messageName, updateMask: "text")
        let body = ["text": text]
        return try await patchJSON(url, body: body)
    }

    /// Update the user's read state on a space — propagates the
    /// "I have read up to T" timestamp to Chat so other clients (mobile,
    /// web) stop bolding the space + bumping its unread badge.
    func updateSpaceReadState(spaceID: String, lastReadTime: Date) async throws {
        let url = ChatEndpoint.spaceReadStateUpdate(spaceID: spaceID)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let body = ["lastReadTime": f.string(from: lastReadTime)]
        let _: GSpaceReadState = try await patchJSON(url, body: body)
    }

    /// Delete a message you authored. Pass `force: true` to also delete the
    /// thread replies (Chat returns 400 otherwise when the message has any).
    func deleteMessage(messageName: String, force: Bool = false) async throws {
        let url = ChatEndpoint.deleteMessage(messageName: messageName, force: force)
        let token = try await Session.shared.accessToken()
        var req = URLRequest(url: url)
        req.httpMethod = "DELETE"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChatAPIError.http(status: status, body: body)
        }
    }

    /// Add a Unicode emoji reaction to a message. Returns the created Reaction.
    /// `messageName` is the full resource path `spaces/X/messages/Y`.
    func addUnicodeReaction(messageName: String, unicode: String) async throws -> GReaction {
        let url = ChatEndpoint.createReaction(messageName: messageName)
        let body = GReactionCreateBody(emoji: .init(unicode: unicode))
        return try await postJSON(url, body: body)
    }

    func listMembers(spaceID: String, pageToken: String? = nil, pageSize: Int = 100) async throws -> GListMembersResponse {
        let url = ChatEndpoint.listMembers(spaceID: spaceID, pageToken: pageToken, pageSize: pageSize)
        return try await getJSON(url)
    }

    /// List the signed-in user's sidebar sections (system + custom).
    /// `userResource` must be a full Chat user resource like `users/{numeric-id}`.
    func listAllSections(userResource: String) async throws -> [GSection] {
        var all: [GSection] = []
        var pageToken: String?
        repeat {
            let url = ChatEndpoint.listSections(userResource: userResource, pageToken: pageToken)
            let response: GListSectionsResponse = try await getJSON(url)
            if let s = response.sections { all.append(contentsOf: s) }
            pageToken = response.nextPageToken
        } while pageToken != nil && !pageToken!.isEmpty
        return all
    }

    /// List items in one specific section, paginating through.
    func listSectionItems(sectionName: String) async throws -> [GSectionItem] {
        var all: [GSectionItem] = []
        var pageToken: String?
        repeat {
            let url = ChatEndpoint.listSectionItems(sectionName: sectionName, pageToken: pageToken)
            let response: GListSectionItemsResponse = try await getJSON(url)
            if let items = response.sectionItems { all.append(contentsOf: items) }
            pageToken = response.nextPageToken
        } while pageToken != nil && !pageToken!.isEmpty
        return all
    }

    /// People API: list all directory profiles in the current Workspace org.
    /// Paginates and returns every person.
    func listAllDirectoryPeople() async throws -> [GPerson] {
        var all: [GPerson] = []
        var pageToken: String?
        repeat {
            let url = ChatEndpoint.listDirectoryPeople(pageToken: pageToken)
            let response: GListDirectoryPeopleResponse = try await getJSON(url)
            if let people = response.people { all.append(contentsOf: people) }
            pageToken = response.nextPageToken
        } while pageToken != nil && !pageToken!.isEmpty
        return all
    }

    /// Admin SDK: fetch a single user's photo as inline base64 bytes.
    /// Returns nil if the user has no photo (404), or any other error.
    /// `userKey` is the numeric Google user ID or primary email.
    func adminUserPhoto(userKey: String) async throws -> GAdminUserPhoto? {
        let url = ChatEndpoint.adminUserPhoto(userKey: userKey)
        do {
            let photo: GAdminUserPhoto = try await getJSON(url)
            return photo
        } catch ChatAPIError.http(let status, _) where status == 404 {
            return nil  // user genuinely has no photo set
        }
    }

    /// People API: search Workspace directory by query (email). Returns the
    /// real Workspace photo URLs that `people:batchGet` hides — same source
    /// Gmail/Chat web apps use for org-member avatars.
    func searchDirectoryPerson(query: String) async throws -> GPerson? {
        let url = ChatEndpoint.peopleSearchDirectory(query: query)
        let response: GSearchDirectoryPeopleResponse = try await getJSON(url)
        // searchDirectory returns up to pageSize results; pick the one whose
        // primary email matches the query (case-insensitive) when possible.
        if let exact = response.people?.first(where: { p in
            (p.emailAddresses?.compactMap(\.value) ?? []).contains { $0.caseInsensitiveCompare(query) == .orderedSame }
        }) {
            return exact
        }
        return response.people?.first
    }

    /// Admin SDK Directory API: list all users in the signed-in admin's
    /// Workspace customer. Returns full data (name, email, photo) bypassing
    /// People API's privacy stripping. Throws 403 if signed-in user isn't an
    /// admin — caller should fall back to People API in that case.
    func listAdminUsers() async throws -> [GAdminUser] {
        var all: [GAdminUser] = []
        var pageToken: String?
        repeat {
            let url = ChatEndpoint.adminListUsers(pageToken: pageToken)
            let response: GAdminUsersListResponse = try await getJSON(url)
            if let users = response.users { all.append(contentsOf: users) }
            pageToken = response.nextPageToken
        } while pageToken != nil && !pageToken!.isEmpty
        return all
    }

    /// People API: resolve a specific list of user IDs (in `users/{id}` Chat
    /// format) to People profiles in batches of 50. Falls back-friendly when
    /// listDirectoryPeople returns empty.
    func batchGetPeople(userIDs: [String]) async throws -> [GPerson] {
        var collected: [GPerson] = []
        // People API uses `people/{id}` resource names. Chat uses `users/{id}`.
        let resourceNames = userIDs.map { $0.replacingOccurrences(of: "users/", with: "people/") }
        for batch in resourceNames.chunks(ofCount: 50) {
            let url = ChatEndpoint.peopleBatchGet(resourceNames: Array(batch))
            let response: GBatchGetPeopleResponse = try await getJSON(url)
            for r in response.responses ?? [] {
                if let p = r.person { collected.append(p) }
            }
        }
        return collected
    }

    // MARK: - Internal HTTP

    private func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        let token = try await Session.shared.accessToken()
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, resp) = try await session.data(for: req)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        guard 200..<300 ~= status else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChatAPIError.http(status: status, body: body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ChatAPIError.malformedResponse
        }
    }

    private func patchJSON<B: Encodable, T: Decodable>(_ url: URL, body: B) async throws -> T {
        let token = try await Session.shared.accessToken()
        var req = URLRequest(url: url)
        req.httpMethod = "PATCH"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChatAPIError.http(status: status, body: body)
        }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw ChatAPIError.malformedResponse }
    }

    private func postJSON<B: Encodable, T: Decodable>(_ url: URL, body: B) async throws -> T {
        let token = try await Session.shared.accessToken()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)

        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ChatAPIError.http(status: status, body: body)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw ChatAPIError.malformedResponse
        }
    }
}

private extension Array {
    func chunks(ofCount n: Int) -> [ArraySlice<Element>] {
        guard n > 0 else { return [] }
        var out: [ArraySlice<Element>] = []
        var i = 0
        while i < count {
            let end = Swift.min(i + n, count)
            out.append(self[i..<end])
            i = end
        }
        return out
    }
}
