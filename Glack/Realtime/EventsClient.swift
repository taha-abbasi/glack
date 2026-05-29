import Foundation

/// HTTP REST client for the Google Workspace Events API. Used to create a
/// long-lived subscription that listens to Chat events on every space the
/// authenticated user belongs to and publishes them to our Pub/Sub topic.
///
/// We only need: create, get, delete. Renewal happens by re-creating after
/// expiry (subscriptions live ~7 days by default; we re-create on each
/// fresh sign-in, which dominates real usage).
actor EventsClient {
    static let shared = EventsClient()

    private let session: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let base = URL(string: "https://workspaceevents.googleapis.com/v1")!

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    /// Create a subscription that watches Chat events for every space the
    /// authenticated user belongs to and delivers them to the named Pub/Sub
    /// topic. The wildcard `spaces/-` target is the one-subscription pattern
    /// — Workspace Events scopes it to the calling user's membership. The
    /// `users/me/spaces/-` and `users/{id}/spaces/-` patterns are both
    /// rejected (Chat API conventions don't apply here).
    ///
    /// Workspace Events wraps the new subscription in a long-running
    /// `Operation`; we unwrap `response` to extract the real Subscription.
    func createSubscription(pubsubTopic: String) async throws -> EventSubscription {
        let body = CreateSubscriptionBody(
            targetResource: "//chat.googleapis.com/spaces/-",
            eventTypes: Self.eventTypes,
            payloadOptions: PayloadOptions(includeResource: true),
            notificationEndpoint: NotificationEndpoint(pubsubTopic: pubsubTopic)
        )
        let url = base.appendingPathComponent("subscriptions")
        let req = try await makeRequest(url: url, method: "POST", body: body)
        let op: OperationEnvelope<EventSubscription> = try await send(req)
        guard let sub = op.response else {
            throw EventsError.http(status: 500, body: "Subscription operation returned without response payload")
        }
        return sub
    }

    /// Delete a subscription by its full resource name.
    func deleteSubscription(name: String) async throws {
        let url = base.appendingPathComponent(name)
        let req = try await makeRequest(url: url, method: "DELETE", body: Optional<EmptyBody>.none)
        // 200/204 success expected; any 2xx is fine.
        let (_, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300 ~= status), status != 404 {
            throw EventsError.http(status: status, body: "delete failed")
        }
    }

    /// Look up an existing subscription. 404 surfaces as `EventsError.notFound`.
    func getSubscription(name: String) async throws -> EventSubscription {
        let url = base.appendingPathComponent(name)
        let req = try await makeRequest(url: url, method: "GET", body: Optional<EmptyBody>.none)
        return try await send(req)
    }

    private func makeRequest<B: Encodable>(url: URL, method: String, body: B?) async throws -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        let token = try await Session.shared.accessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try encoder.encode(body)
        }
        return req
    }

    private func send<T: Decodable>(_ req: URLRequest) async throws -> T {
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard 200..<300 ~= status else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if status == 404 { throw EventsError.notFound }
            if status == 409, let name = Self.extractConflictingSubscription(body) {
                throw EventsError.alreadyExists(conflictingSubscription: name)
            }
            throw EventsError.http(status: status, body: body)
        }
        return try decoder.decode(T.self, from: data)
    }

    /// Pull the conflicting subscription name out of a 409 error body. The
    /// API embeds it at `error.details[].metadata.current_subscription`.
    private static func extractConflictingSubscription(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = json["error"] as? [String: Any],
              let details = err["details"] as? [[String: Any]] else { return nil }
        for d in details {
            if let meta = d["metadata"] as? [String: Any],
               let current = meta["current_subscription"] as? String, !current.isEmpty {
                return current
            }
        }
        return nil
    }

    /// The complete set of Chat event types we want pushed to Pub/Sub.
    /// Coverage matches what the local DB models: messages, reactions,
    /// memberships, spaces.
    static let eventTypes: [String] = [
        "google.workspace.chat.message.v1.created",
        "google.workspace.chat.message.v1.updated",
        "google.workspace.chat.message.v1.deleted",
        "google.workspace.chat.reaction.v1.created",
        "google.workspace.chat.reaction.v1.deleted",
        "google.workspace.chat.membership.v1.created",
        "google.workspace.chat.membership.v1.updated",
        "google.workspace.chat.membership.v1.deleted",
        "google.workspace.chat.space.v1.updated",
    ]
}

// MARK: - DTOs

enum EventsError: LocalizedError {
    case http(status: Int, body: String)
    case notFound
    /// 409 ALREADY_EXISTS — Workspace Events allows at most one subscription
    /// per (target_resource, user). The conflicting subscription's resource
    /// name is included so the caller can delete it and retry.
    case alreadyExists(conflictingSubscription: String)

    var errorDescription: String? {
        switch self {
        case .http(let status, let body):
            return "Workspace Events HTTP \(status): \(body.prefix(500))"
        case .notFound:
            return "Workspace Events subscription not found"
        case .alreadyExists(let name):
            return "Workspace Events subscription already exists: \(name)"
        }
    }
}

private struct CreateSubscriptionBody: Encodable {
    let targetResource: String
    let eventTypes: [String]
    let payloadOptions: PayloadOptions
    let notificationEndpoint: NotificationEndpoint
}

private struct PayloadOptions: Encodable {
    let includeResource: Bool
}

private struct NotificationEndpoint: Encodable {
    let pubsubTopic: String
}

struct EventSubscription: Decodable {
    let name: String
    let targetResource: String?
    let eventTypes: [String]?
    let state: String?
    let expireTime: String?
}

/// Workspace Events LROs come back wrapped in this envelope. For our
/// create/delete operations the response is synchronous (`done: true` on
/// first call), so we just unwrap `response`.
struct OperationEnvelope<T: Decodable>: Decodable {
    let name: String?
    let done: Bool?
    let response: T?
}
