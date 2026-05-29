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

    func listMessages(spaceID: String, pageToken: String? = nil, pageSize: Int = 100, orderBy: String = "createTime desc") async throws -> GListMessagesResponse {
        let url = ChatEndpoint.listMessages(spaceID: spaceID, pageToken: pageToken, pageSize: pageSize, orderBy: orderBy)
        return try await getJSON(url)
    }

    func listMembers(spaceID: String, pageToken: String? = nil, pageSize: Int = 100) async throws -> GListMembersResponse {
        let url = ChatEndpoint.listMembers(spaceID: spaceID, pageToken: pageToken, pageSize: pageSize)
        return try await getJSON(url)
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
