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
    
    /// Display a native macOS notification for incoming chat messages
    public func notifyIncomingMessage(sender: String, content: String) {
        self.lastNotification = (sender: sender, content: content)
        
        guard Bundle.main.bundleIdentifier != nil else { return }
        
        let notificationContent = UNMutableNotificationContent()
        notificationContent.title = sender
        notificationContent.body = content
        notificationContent.sound = UNNotificationSound.default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: notificationContent,
            trigger: nil // Deliver immediately
        )
        
        UNUserNotificationCenter.current().add(request)
        
        // Play system tink sound
        NSSound.beep()
    }
    
    public func notifyIncomingMessage(senderName: String, messageText: String) {
        notifyIncomingMessage(sender: senderName, content: messageText)
    }

    
    /// Play sound effect for sending a message
    public func playSendSound() {
        NSSound(named: NSSound.Name("Pop"))?.play()
    }
    
    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }
}
