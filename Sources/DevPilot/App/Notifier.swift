import AppKit
import UserNotifications

/// Posts macOS notifications for workflow milestones; clicking one selects the ticket.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    var onOpenTicket: ((String) -> Void)?

    /// UserNotifications needs an app bundle; `swift run` has none.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, ticketID: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["ticketID": ticketID]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let ticketID = response.notification.request.content.userInfo["ticketID"] as? String else { return }
        await MainActor.run {
            NSApp.activate()
            onOpenTicket?(ticketID)
        }
    }
}
