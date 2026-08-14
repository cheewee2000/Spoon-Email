import Foundation
import UserNotifications
import MailCore

/// Native banners for mail that arrives while the app is running. Fed only by
/// the incremental sync pass, so old mail filling in never raises anything.
@MainActor
final class MailNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Set by AppModel — opens the thread whose banner was clicked.
    var onOpenThread: ((String, String) -> Void)?

    /// Above this, one summary banner instead of a stack of them.
    private static let individualLimit = 3

    func start() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // In a background-refresh launch this resolves against the existing
        // grant without prompting.
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// No authorization gate: the grant arrives asynchronously and a
    /// background pass can finish before it does. An unauthorized `add` is a
    /// silent no-op, which is exactly the behaviour a gate would give us.
    func post(_ items: [NewMail]) {
        guard !items.isEmpty else { return }

        if items.count > Self.individualLimit {
            let content = UNMutableNotificationContent()
            content.title = "\(items.count) new messages"
            var names: [String] = []
            for item in items where !names.contains(item.fromName) { names.append(item.fromName) }
            content.body = names.prefix(4).joined(separator: ", ")
                + (names.count > 4 ? ", and \(names.count - 4) more" : "")
            content.sound = .default
            submit(content, id: "batch-\(UUID().uuidString)")
            return
        }

        for item in items {
            let content = UNMutableNotificationContent()
            content.title = item.fromName
            content.subtitle = item.subject
            content.body = item.snippet
            content.sound = .default
            content.userInfo = ["accountId": item.accountId, "threadId": item.threadId]
            // Gmail's message id is stable, so a re-delivered message replaces
            // its own banner rather than stacking a duplicate.
            submit(content, id: "\(item.accountId)|\(item.messageId)")
        }
    }

    private func submit(_ content: UNMutableNotificationContent, id: String) {
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Banner even when the app is frontmost — the window is often on another
    /// Space or behind something else.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        if let accountId = info["accountId"] as? String,
           let threadId = info["threadId"] as? String {
            Task { @MainActor in self.onOpenThread?(accountId, threadId) }
        }
        completionHandler()
    }
}
