import Foundation

/// HTTP REST client for Google Cloud Pub/Sub. We only need a tiny slice:
/// idempotent topic + subscription creation, a Publisher IAM binding for
/// the Chat backend service account, pull, and acknowledge.
///
/// All operations use the signed-in user's OAuth token with the `pubsub`
/// scope, so any project where they have Pub/Sub permissions works.
actor PubSubClient {
    static let shared = PubSubClient()

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - Topic

    /// Idempotently create a Pub/Sub topic. Returns the topic's full
    /// resource name. `topic` is the short ID — e.g., `glack-chat-events`.
    @discardableResult
    func ensureTopic(project: String, topic: String) async throws -> String {
        let name = "projects/\(project)/topics/\(topic)"
        let url = URL(string: "https://pubsub.googleapis.com/v1/\(name)")!
        // GET first; if 404, create.
        do {
            let _: TopicResponse = try await get(url)
            return name
        } catch PubSubError.http(let status, _) where status == 404 {
            // Create. Pub/Sub uses PUT with an empty body for the create op.
            let _: TopicResponse = try await put(url, body: EmptyBody())
            return name
        }
    }

    /// Grant `chat-api-push@system.gserviceaccount.com` publisher rights on
    /// the topic so the Workspace Events backend can deliver to it. Reads
    /// the current IAM policy, appends the binding if missing, sets it
    /// back. Idempotent.
    func grantChatPublisher(project: String, topic: String) async throws {
        let resource = "projects/\(project)/topics/\(topic)"
        let getURL = URL(string: "https://pubsub.googleapis.com/v1/\(resource):getIamPolicy")!
        let setURL = URL(string: "https://pubsub.googleapis.com/v1/\(resource):setIamPolicy")!
        let member = "serviceAccount:chat-api-push@system.gserviceaccount.com"
        let role = "roles/pubsub.publisher"

        let policy: IamPolicy = try await get(getURL)
        var bindings = policy.bindings ?? []
        if let idx = bindings.firstIndex(where: { $0.role == role }) {
            if bindings[idx].members.contains(member) { return }  // already bound
            bindings[idx].members.append(member)
        } else {
            bindings.append(IamBinding(role: role, members: [member]))
        }
        let body = SetIamPolicyBody(policy: IamPolicy(version: policy.version, bindings: bindings, etag: policy.etag))
        let _: IamPolicy = try await post(setURL, body: body)
    }

    // MARK: - Subscription

    /// Idempotently create a pull subscription on the given topic. Returns
    /// the subscription's full resource name.
    @discardableResult
    func ensureSubscription(project: String, subscription: String, topic: String,
                            ackDeadlineSeconds: Int = 30) async throws -> String {
        let name = "projects/\(project)/subscriptions/\(subscription)"
        let url = URL(string: "https://pubsub.googleapis.com/v1/\(name)")!
        do {
            let _: SubscriptionResponse = try await get(url)
            return name
        } catch PubSubError.http(let status, _) where status == 404 {
            let body = CreateSubscriptionBody(
                topic: "projects/\(project)/topics/\(topic)",
                ackDeadlineSeconds: ackDeadlineSeconds
            )
            let _: SubscriptionResponse = try await put(url, body: body)
            return name
        }
    }

    /// Pull up to `maxMessages` messages from the subscription. Returns
    /// immediately even when the subscription is empty — callers should
    /// throttle their own loop.
    func pull(subscription: String, maxMessages: Int = 50) async throws -> [PubSubMessage] {
        let url = URL(string: "https://pubsub.googleapis.com/v1/\(subscription):pull")!
        let body = PullBody(maxMessages: maxMessages, returnImmediately: true)
        let resp: PullResponse = try await post(url, body: body)
        return resp.receivedMessages ?? []
    }

    /// Acknowledge a batch of ackIds — Pub/Sub then stops redelivering them.
    func acknowledge(subscription: String, ackIds: [String]) async throws {
        guard !ackIds.isEmpty else { return }
        let url = URL(string: "https://pubsub.googleapis.com/v1/\(subscription):acknowledge")!
        let body = AckBody(ackIds: ackIds)
        // The acknowledge endpoint returns an empty body on success.
        let _: EmptyBody = try await post(url, body: body)
    }

    // MARK: - HTTP

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        try await authorize(&req)
        return try await send(req)
    }

    private func put<B: Encodable, T: Decodable>(_ url: URL, body: B) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        try await authorize(&req)
        return try await send(req)
    }

    private func post<B: Encodable, T: Decodable>(_ url: URL, body: B) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try encoder.encode(body)
        try await authorize(&req)
        return try await send(req)
    }

    private func authorize(_ req: inout URLRequest) async throws {
        let token = try await Session.shared.accessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw PubSubError.http(status: status, body: body)
        }
        if T.self == EmptyBody.self {
            return EmptyBody() as! T  // swiftlint:disable:this force_cast
        }
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - DTOs

enum PubSubError: LocalizedError {
    case http(status: Int, body: String)
    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "Pub/Sub HTTP \(status): \(body.prefix(500))"
        }
    }
}

struct EmptyBody: Codable {}

private struct TopicResponse: Decodable {
    let name: String
}

private struct SubscriptionResponse: Decodable {
    let name: String
    let topic: String?
}

private struct CreateSubscriptionBody: Encodable {
    let topic: String
    let ackDeadlineSeconds: Int
}

private struct PullBody: Encodable {
    let maxMessages: Int
    let returnImmediately: Bool
}

struct PullResponse: Decodable {
    let receivedMessages: [PubSubMessage]?
}

struct PubSubMessage: Decodable {
    let ackId: String
    let message: PubSubInnerMessage
}

struct PubSubInnerMessage: Decodable {
    let data: String?            // base64
    let messageId: String?
    let publishTime: String?
    let attributes: [String: String]?
}

private struct AckBody: Encodable {
    let ackIds: [String]
}

private struct IamPolicy: Codable {
    let version: Int?
    var bindings: [IamBinding]?
    let etag: String?
}

private struct IamBinding: Codable {
    let role: String
    var members: [String]
}

private struct SetIamPolicyBody: Encodable {
    let policy: IamPolicy
}
