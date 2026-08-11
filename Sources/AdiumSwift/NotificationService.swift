import Foundation
import UserNotifications
import AppKit

@MainActor
public final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = NotificationService()
    
    public private(set) var lastNotification: (sender: String, content: String)?
    
    private override init() {
        super.init()
        setupNotifications()
    }
    
    public func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }
    
    /// Display a native macOS notification for incoming chat messages.
    /// The playSound parameter mirrors the triggering EventRule.
    /// This prevents a double sound effect.
    public func notifyIncomingMessage(sender: String, content: String, playSound: Bool = true) {
        self.lastNotification = (sender: sender, content: content)

        guard Bundle.main.bundleIdentifier != nil else { return }

        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = sender
        notificationContent.body = content
        notificationContent.sound = playSound ? UNNotificationSound.default : nil

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notificationContent,
            trigger: nil // Deliver the notification immediately.
        )

        UNUserNotificationCenter.current().add(request)
    }

    public func notifyIncomingMessage(senderName: String, messageText: String) {
        notifyIncomingMessage(sender: senderName, content: messageText)
    }

    
    /// Play a sound effect when you send a message.
    public func playSendSound() {
        EventManager.shared.playSound(named: EventManager.shared.rules[.messageSent]?.soundName ?? "Pop")
    }
    
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}

