import Foundation
import UserNotifications

/// macOS notifications for terminal cards that need the user. One per card: a newer one replaces it, and it's
/// removed once the user looks at the card.
enum Notifier {
    /// Notifications need an app bundle, which `swift run` doesn't have.
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil }

    /// macOS asks for permission the first time.
    static func post(cardID: UUID, title: String, body: String) {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: cardID.uuidString, content: content, trigger: nil))
        }
    }

    static func remove(cardID: UUID) {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [cardID.uuidString])
    }
}
