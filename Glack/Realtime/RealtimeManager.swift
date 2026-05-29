import Foundation

/// Orchestrates the realtime pipeline:
///   1. Ensure the Pub/Sub topic + subscription exist in the GCP project.
///   2. Ensure the Chat service account is granted publisher on the topic.
///   3. Create a Workspace Events subscription targeting all the user's
///      Chat spaces with delivery to that Pub/Sub topic.
///   4. Run a tight pull loop against the Pub/Sub subscription, processing
///      each event into the local DB.
///
/// All of this runs concurrent with the existing 30-second poll. The poll
/// remains as a safety net — if Workspace Events delivery falls behind or
/// we lose a few events to a transient failure, the next poll backfills.
@MainActor
@Observable
final class RealtimeManager {
    static let shared = RealtimeManager()

    private(set) var isRunning: Bool = false
    private(set) var lastEventAt: Date?
    private(set) var lastError: String?

    private var loopTask: Task<Void, Never>?
    private var subscriptionResourceName: String?

    // Configurable, but project-specific. Read from BuildConfig if you ever
    // want to ship for multiple projects.
    private let projectID = "glack-497804"
    private let topicID = "glack-chat-events"
    private let subscriptionID = "glack-chat-events-sub"

    /// Persisted name of the most recently created Workspace Events
    /// subscription. Stored so we can delete it on sign-out even after a
    /// process restart.
    private let storedEventSubKey = "Glack.WorkspaceEventsSubscription"

    func start() {
        guard !isRunning else { return }
        isRunning = true
        loopTask = Task { [weak self] in
            await self?.runPipeline()
        }
    }

    func stop() async {
        isRunning = false
        loopTask?.cancel()
        loopTask = nil
        // Best-effort delete of the live subscription so it doesn't keep
        // pushing events after we're gone. Topic + Pub/Sub subscription are
        // project-level resources and persist across sessions.
        if let name = subscriptionResourceName ?? UserDefaults.standard.string(forKey: storedEventSubKey) {
            do {
                try await EventsClient.shared.deleteSubscription(name: name)
                UserDefaults.standard.removeObject(forKey: storedEventSubKey)
                Log.sync.info("RealtimeManager: deleted event sub \(name, privacy: .public)")
            } catch {
                Log.sync.error("RealtimeManager: delete sub failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        subscriptionResourceName = nil
    }

    private func runPipeline() async {
        do {
            let subscription = try await ensureInfrastructure()
            Log.sync.info("RealtimeManager: pull loop starting on \(subscription, privacy: .public)")
            await pullLoop(subscription: subscription)
        } catch {
            await MainActor.run {
                self.lastError = error.localizedDescription
                self.isRunning = false
            }
            Log.sync.error("RealtimeManager pipeline failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Idempotent project + subscription setup. Returns the Pub/Sub pull
    /// subscription name. Recreates the Workspace Events subscription on
    /// every start so we always begin with a known-fresh expiry.
    private func ensureInfrastructure() async throws -> String {
        // 1. Topic
        let topicName = try await PubSubClient.shared.ensureTopic(project: projectID, topic: topicID)
        // 2. Chat service account → publisher on topic
        try await PubSubClient.shared.grantChatPublisher(project: projectID, topic: topicID)
        // 3. Pull subscription
        let subscriptionName = try await PubSubClient.shared.ensureSubscription(
            project: projectID, subscription: subscriptionID, topic: topicID
        )
        // 4. Workspace Events subscription. Tear down any previous one we
        //    saved so we don't accumulate; user can have at most ~25 per
        //    quota and we definitely don't want stale ones.
        if let prev = UserDefaults.standard.string(forKey: storedEventSubKey) {
            try? await EventsClient.shared.deleteSubscription(name: prev)
        }
        let sub = try await EventsClient.shared.createSubscription(pubsubTopic: topicName)
        await MainActor.run {
            self.subscriptionResourceName = sub.name
        }
        UserDefaults.standard.set(sub.name, forKey: storedEventSubKey)
        Log.sync.info("RealtimeManager: created event sub \(sub.name, privacy: .public)")
        return subscriptionName
    }

    /// Repeated pull → process → ack loop. The Pub/Sub REST `returnImmediately`
    /// flag is set so each call returns straight away; we throttle quiet
    /// intervals to ~1s. Quiet intervals are common (typing pauses), and
    /// 1s gives <2s perceived latency end-to-end for an actual event.
    private func pullLoop(subscription: String) async {
        let quietSleep: UInt64 = 1_000_000_000  // 1s
        var backoff: UInt64 = 500_000_000        // 500ms initial backoff on error

        while !Task.isCancelled {
            do {
                let messages = try await PubSubClient.shared.pull(subscription: subscription, maxMessages: 50)
                if messages.isEmpty {
                    try? await Task.sleep(nanoseconds: quietSleep)
                    backoff = 500_000_000
                    continue
                }
                await MainActor.run { self.lastEventAt = Date() }
                for m in messages {
                    await EventProcessor.process(m)
                }
                let ackIds = messages.map(\.ackId)
                try await PubSubClient.shared.acknowledge(subscription: subscription, ackIds: ackIds)
                backoff = 500_000_000
            } catch {
                Log.sync.error("RealtimeManager pull error: \(error.localizedDescription, privacy: .public)")
                // Exponential backoff, capped at 30s
                try? await Task.sleep(nanoseconds: backoff)
                backoff = min(backoff * 2, 30_000_000_000)
            }
        }
    }
}
