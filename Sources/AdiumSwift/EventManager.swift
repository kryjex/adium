import Foundation
import AppKit
import UserNotifications

public enum AdiumEventType: String, Codable, CaseIterable, Identifiable {
    case messageReceived = "Mensaje Recibido"
    case messageSent = "Mensaje Enviado"
    case contactOnline = "Contacto Conectado"
    case contactOffline = "Contacto Desconectado"
    
    public var id: String { rawValue }
    
    public var defaultSoundName: String {
        switch self {
        case .messageReceived: return "Tink"
        case .messageSent: return "Pop"
        case .contactOnline: return "Glass"
        case .contactOffline: return "Basso"
        }
    }
}

public struct EventRule: Codable, Equatable, Identifiable {
    public var eventType: AdiumEventType
    public var playSound: Bool
    public var soundName: String
    public var bounceDock: Bool
    public var updateBadge: Bool
    public var showNotification: Bool
    
    public var id: String { eventType.rawValue }
    
    public init(
        eventType: AdiumEventType,
        playSound: Bool = true,
        soundName: String? = nil,
        bounceDock: Bool = false,
        updateBadge: Bool = false,
        showNotification: Bool = true
    ) {
        self.eventType = eventType
        self.playSound = playSound
        self.soundName = soundName ?? eventType.defaultSoundName
        self.bounceDock = bounceDock
        self.updateBadge = updateBadge
        self.showNotification = showNotification
    }
}

@MainActor
@Observable
public final class EventManager {
    public static let shared = EventManager()
    
    private let rulesStorageKey = "AdiumEventRules"
    private let unreadCountKey = "AdiumUnreadCount"
    
    public var rules: [AdiumEventType: EventRule] = [:]
    public private(set) var unreadCount: Int = 0
    public private(set) var lastTriggeredEvent: (type: AdiumEventType, title: String, content: String)?
    
    public static let availableSounds: [String] = [
        "Tink", "Pop", "Glass", "Basso", "Purr", "Submarine", "Sosumi", "Ping", "Hero", "Frog"
    ]
    
    private init() {
        loadRules()
    }
    
    // MARK: - Rules Persistence & Setup
    
    public func loadRules() {
        if let data = UserDefaults.standard.data(forKey: rulesStorageKey),
           let decoded = try? JSONDecoder().decode([EventRule].self, from: data) {
            for rule in decoded {
                rules[rule.eventType] = rule
            }
        }
        
        // Ensure default rules exist for all event types
        for eventType in AdiumEventType.allCases {
            if rules[eventType] == nil {
                let defaultRule: EventRule
                switch eventType {
                case .messageReceived:
                    defaultRule = EventRule(eventType: .messageReceived, playSound: true, soundName: "Tink", bounceDock: true, updateBadge: true, showNotification: true)
                case .messageSent:
                    defaultRule = EventRule(eventType: .messageSent, playSound: true, soundName: "Pop", bounceDock: false, updateBadge: false, showNotification: false)
                case .contactOnline:
                    defaultRule = EventRule(eventType: .contactOnline, playSound: true, soundName: "Glass", bounceDock: false, updateBadge: false, showNotification: true)
                case .contactOffline:
                    defaultRule = EventRule(eventType: .contactOffline, playSound: true, soundName: "Basso", bounceDock: false, updateBadge: false, showNotification: false)
                }
                rules[eventType] = defaultRule
            }
        }
    }
    
    public func saveRules() {
        let rulesArray = Array(rules.values)
        if let encoded = try? JSONEncoder().encode(rulesArray) {
            UserDefaults.standard.set(encoded, forKey: rulesStorageKey)
        }
    }
    
    public func updateRule(_ rule: EventRule) {
        rules[rule.eventType] = rule
        saveRules()
    }
    
    // MARK: - Event Triggering
    
    public func triggerEvent(_ eventType: AdiumEventType, title: String, content: String, contactID: UUID? = nil) {
        lastTriggeredEvent = (type: eventType, title: title, content: content)
        
        let rule = rules[eventType] ?? EventRule(eventType: eventType)
        
        // 1. Play Sound
        if rule.playSound {
            playSound(named: rule.soundName)
        }
        
        // 2. Dock Bounce
        if rule.bounceDock {
            bounceDockIcon()
        }
        
        // 3. Update Badge — intentionally not handled here. The caller (PurpleBridge's
        // onMessageReceived/onChatMessage) already recomputes and sets the exact unread
        // total via EventManager.setUnreadCount before calling triggerEvent; incrementing
        // again here double-counted the badge (and kept climbing even for the active tab,
        // since triggerEvent still fires for it). setUnreadCount is the single source of
        // truth for the badge count.

        // 4. macOS Notification
        if rule.showNotification {
            NotificationService.shared.notifyIncomingMessage(sender: title, content: content, playSound: rule.playSound)
        }
    }
    
    // MARK: - Event Actions
    
    public func playSound(named soundName: String) {
        if let sound = NSSound(named: NSSound.Name(soundName)) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
    
    public func bounceDockIcon() {
        let app: NSApplication? = NSApp
        app?.requestUserAttention(.informationalRequest)
    }
    
    public func setUnreadCount(_ count: Int) {
        self.unreadCount = max(0, count)
        updateDockBadge()
    }
    
    public func incrementUnreadCount() {
        self.unreadCount += 1
        updateDockBadge()
    }
    
    public func clearUnreadCount() {
        self.unreadCount = 0
        updateDockBadge()
    }
    
    private func updateDockBadge() {
        let app: NSApplication? = NSApp
        if unreadCount > 0 {
            app?.dockTile.badgeLabel = "\(unreadCount)"
        } else {
            app?.dockTile.badgeLabel = nil
        }
    }
}
