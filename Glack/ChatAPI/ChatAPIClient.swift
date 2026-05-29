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
