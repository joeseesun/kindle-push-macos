import AppKit
import UserNotifications

/// Tells the user a long job ended when they have gone elsewhere. Translations take hours;
/// nobody watches the window that long, and a bounce in the Dock is easy to miss.
enum Notify {
    /// Asked when the first translation starts, when the reason for it is plain.
    static func ask() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @MainActor static func post(_ title: String, _ body: String) {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
