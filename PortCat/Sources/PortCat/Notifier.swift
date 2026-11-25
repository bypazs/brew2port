import Foundation
import UserNotifications

enum NotifyID {
    static let updateAction = "UPDATE_NOW"
    static let snoozeAction = "SNOOZE"
    static let codexCategory = "CODEX_UPDATE"
    static let portsCategory = "PORTS_UPDATE"
    static let extrasCategory = "EXTRAS_UPDATE"
}

/// macOS notifications with an update button. macOS asks the user once
/// whether PortCat may notify; they can turn it off in System Settings.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called with the category when the user presses the update button.
    var onUpdate: ((String) -> Void)?
    /// Called when the user presses "Remind me tomorrow".
    var onSnooze: (() -> Void)?
    /// Called when the user clicks the notification itself.
    var onOpen: (() -> Void)?

    /// Notifications need an app bundle (they crash under `swift run`).
    private var available: Bool { Bundle.main.bundleIdentifier != nil }

    func setup() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let snooze = UNNotificationAction(identifier: NotifyID.snoozeAction, title: "Remind me tomorrow", options: [])
        func category(_ id: String, _ title: String) -> UNNotificationCategory {
            UNNotificationCategory(
                identifier: id,
                actions: [UNNotificationAction(identifier: NotifyID.updateAction, title: title, options: []), snooze],
                intentIdentifiers: [])
        }
        center.setNotificationCategories([
            category(NotifyID.codexCategory, "Update now"),
            category(NotifyID.portsCategory, "Upgrade all"),
            category(NotifyID.extrasCategory, "Update now"),
        ])
    }

    func post(id: String, title: String, body: String, category: String) {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.categoryIdentifier = category
            content.sound = .default
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.actionIdentifier
        let category = response.notification.request.content.categoryIdentifier
        Task { @MainActor in
            if action == NotifyID.updateAction {
                self.onUpdate?(category)
            } else if action == NotifyID.snoozeAction {
                self.onSnooze?()
            } else if action == UNNotificationDefaultActionIdentifier {
                self.onOpen?()
            }
        }
        completionHandler()
    }

    /// Show the banner even while PortCat is the active app.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
