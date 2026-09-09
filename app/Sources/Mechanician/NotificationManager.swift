import Foundation
import AppKit
import UserNotifications

/// Pure focus policy shared by conversation alerts and deterministic multi-window tests. The
/// event's owning conversation is the input; whichever bridge happened to receive the daemon frame
/// is deliberately irrelevant. A conversation is watched only when the app is active and a key
/// workspace window is displaying that exact id.
enum ConversationNotificationPolicy {
    static func isActivelyWatched(
        _ conversationID: UUID?,
        applicationIsActive: Bool,
        keyWindowConversationIDs: [UUID]
    ) -> Bool {
        guard applicationIsActive, let conversationID else { return false }
        return keyWindowConversationIDs.contains(conversationID)
    }

    static func shouldNotify(
        for conversationID: UUID?,
        applicationIsActive: Bool,
        keyWindowConversationIDs: [UUID]
    ) -> Bool {
        !isActivelyWatched(
            conversationID,
            applicationIsActive: applicationIsActive,
            keyWindowConversationIDs: keyWindowConversationIDs)
    }
}

/// Native notifications for agent events (turn done, approval needed, a question asked, workflow
/// finished). Callers gate on `AgentBridge.isActivelyWatched(_:)`, so it fires whenever you're not
/// looking at that conversation — including when Mechanician is frontmost but you're on a DIFFERENT
/// tab/window. macOS suppresses banners for a foreground app unless a delegate says otherwise, so we
/// set `UNUserNotificationCenterDelegate` and force `.banner` in `willPresent`. An unbundled
/// `swift run` process has no notification identity, so notification delivery is a no-op there.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    /// XCTest and other host executables may synthesize a bundle identifier without having a real
    /// application bundle. Calling `current()` there raises an Objective-C exception rather than a
    /// Swift error, so require both pieces of notification identity.
    private var available: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }
    private var enabled: Bool { UserDefaults.standard.object(forKey: "notificationsEnabled") as? Bool ?? true }

    private override init() {
        super.init()
        configure()
    }

    /// The notification-center delegate must exist before application launch finishes so a click
    /// that cold-launches Mechanician is routed to its conversation/window instead of being lost.
    func configure() {
        if available { UNUserNotificationCenter.current().delegate = self }
    }

    func requestAuthorization() {
        guard available else { return }
        configure()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Post a notification (unless disabled). Callers decide WHEN it's warranted — they gate on
    /// `AgentBridge.isActivelyWatched(_:)`, which is stricter than "is the app frontmost": switching
    /// to another tab/window of Mechanician still notifies. Uses UNUserNotificationCenter in the
    /// packaged app. Never fall back to `osascript`: macOS attributes those banners to Script Editor,
    /// so clicking one can open the wrong application.
    func notify(
        title: String,
        body: String,
        openWindowID: String? = nil,
        conversationID: UUID? = nil,
        completion: (@MainActor (Error?) -> Void)? = nil
    ) {
        guard enabled else {
            completion?(nil)
            return
        }
        guard available else {
            completion?(NotificationDeliveryError.bundleIdentityUnavailable)
            return
        }
        configure()
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let w = openWindowID { content.userInfo["openWindow"] = w }
        if let conversationID { content.userInfo["conversationID"] = conversationID.uuidString }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { error in
            guard let completion else { return }
            Task { @MainActor in completion(error) }
        }
    }

    // Present the banner even when Mechanician is frontmost — the "you're on another tab/window"
    // case. Without this, macOS silently drops a notification posted by a foreground app, which is
    // why cross-tab pings never showed. (Callers already ensured you're NOT watching the sender.)
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    // Click-through: conversation alerts restore their exact workspace window; utility alerts open
    // their named singleton scene. Without this handler clicking a banner just activated the app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let target = userInfo["openWindow"] as? String
        let conversationID = (userInfo["conversationID"] as? String).flatMap(UUID.init(uuidString:))
        Task { @MainActor in
            if let conversationID {
                ActiveWorkspace.shared.open(.conversation(conversationID))
            } else if let target {
                NSApp.activate(ignoringOtherApps: true)
                openAppWindowWhenReady(id: target)
            }
            completionHandler()
        }
    }

}

private enum NotificationDeliveryError: LocalizedError {
    case bundleIdentityUnavailable

    var errorDescription: String? {
        "Native notifications require an application bundle identity."
    }
}
