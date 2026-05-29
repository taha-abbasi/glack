import AppKit
import Foundation
import UserNotifications

/// Wraps UNUserNotificationCenter for Glack. Requests permission on first
/// run, posts message-arrival notifications, and plays an in-app sound when
/// a notification fires while Glack is in the foreground (since the system
/// only plays a sound for background notifications).
@MainActor
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    private var authorized: Bool = false
    private var didRequest: Bool = false

    /// Slack's web/desktop "knock" sound is custom and proprietary; the closest
    /// stock macOS chime is "Funk" — a short, friendly notification ping.
    /// In-app foreground notifications play this via NSSound; background
    /// notifications use UNNotificationSound.default so users can customize
    /// it in System Settings → Notifications. (Refinements: bundle a true
    /// CC0 "knock" sound and reference via UNNotificationSound(named:).)
    private let inAppSoundName = "Funk"

    private override init() {
        super.init()
        center.delegate = self
    }

    /// Ask for notification permission. Idempotent — does nothing after the
    /// first call. Call once per session, after sign-in succeeds.
    func requestAuthorizationIfNeeded() async {
        if didRequest { return }
        didRequest = true
        do {
            authorized = try await center.requestAuthorization(options: [.alert, .badge, .sound])
            Log.app.info("notification permission: \(self.authorized ? "granted" : "denied", privacy: .public)")
        } catch {
            Log.app.error("notification permission error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Post a notification for a new chat message.
    /// - parameters:
    ///   - messageID:   `spaces/X/messages/Y` (used as the notification ID)
    ///   - title:       header line — typically sender name
    ///   - subtitle:    secondary line — typically space name
    ///   - body:        message preview (plain-text)
    func postMessage(messageID: String, title: String, subtitle: String?, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle, !subtitle.isEmpty { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        content.userInfo = ["messageID": messageID]
        // Dedupe: identifier == messageID — re-posting replaces.
        let req = UNNotificationRequest(identifier: messageID, content: content, trigger: nil)
        center.add(req) { error in
            if let error {
                Log.app.error("postNotification(\(messageID, privacy: .public)) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        // If we're in the foreground, also fire the in-app chime — the system
        // does not play notification sound when the app is active.
        if NSApp.isActive {
            NSSound(named: inAppSoundName)?.play()
        }
    }

    /// Set the dock badge to the unread total. Pass 0 to clear.
    func updateDockBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// Show the banner + play sound even when Glack is in the foreground —
    /// the system default suppresses both, which makes new-message alerts
    /// invisible while the app is active.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .badge])
    }
}
