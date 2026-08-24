import Foundation
import AppKit
import UserNotifications

public enum FluoriteEventType: String, Codable, CaseIterable, Identifiable {
    case messageReceived = "messageReceived"
    case messageSent = "messageSent"
    case contactOnline = "contactOnline"
    case contactOffline = "contactOffline"
    case accountConnected = "accountConnected"
    case accountDisconnected = "accountDisconnected"
    case transferCompleted = "transferCompleted"
    case transferFailed = "transferFailed"
    case groupMention = "groupMention"
    case messageSendError = "messageSendError"

    public var id: String { rawValue }

    /// This is the localized text for the events UI.
    /// The raw value stays stable because it persists in the rules storage.
    public var displayName: String {
        switch self {
        case .messageReceived: return t("Message Received")
        case .messageSent: return t("Message Sent")
        case .contactOnline: return t("Contact Online")
        case .contactOffline: return t("Contact Offline")
        case .accountConnected: return t("Account Connected")
        case .accountDisconnected: return t("Account Disconnected")
        case .transferCompleted: return t("File Transfer Completed")
        case .transferFailed: return t("File Transfer Failed")
        case .groupMention: return t("Mention in Group Chat")
        case .messageSendError: return t("Message Send Error")
        }
    }

    public var defaultSoundName: String {
        switch self {
        case .messageReceived: return "Tink"
        case .messageSent: return "Pop"
        case .contactOnline: return "Glass"
        case .contactOffline: return "Basso"
        case .accountConnected: return "Purr"
        case .accountDisconnected: return "Basso"
        case .transferCompleted: return "Hero"
        case .transferFailed: return "Basso"
        case .groupMention: return "Ping"
        case .messageSendError: return "Sosumi"
        }
    }
}

public struct EventRule: Codable, Equatable, Identifiable {
    public var eventType: FluoriteEventType
    public var playSound: Bool
    public var soundName: String
    public var bounceDock: Bool
    public var updateBadge: Bool
    public var showNotification: Bool
    
    public var id: String { eventType.rawValue }
    
    public init(
        eventType: FluoriteEventType,
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
    
    public var rules: [FluoriteEventType: EventRule] = [:]
    public private(set) var unreadCount: Int = 0
    public private(set) var lastTriggeredEvent: (type: FluoriteEventType, title: String, content: String)?
    
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
        
        // This ensures default rules for all event types.
        for eventType in FluoriteEventType.allCases {
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
                case .accountConnected:
                    defaultRule = EventRule(eventType: .accountConnected, playSound: true, soundName: "Purr", bounceDock: false, updateBadge: false, showNotification: true)
                case .accountDisconnected:
                    defaultRule = EventRule(eventType: .accountDisconnected, playSound: true, soundName: "Basso", bounceDock: false, updateBadge: false, showNotification: true)
                case .transferCompleted:
                    defaultRule = EventRule(eventType: .transferCompleted, playSound: true, soundName: "Hero", bounceDock: false, updateBadge: false, showNotification: true)
                case .transferFailed:
                    defaultRule = EventRule(eventType: .transferFailed, playSound: true, soundName: "Basso", bounceDock: false, updateBadge: false, showNotification: true)
                case .groupMention:
                    // A mention behaves like a received message: badge and
                    // bounce included. The caller owns the unread count.
                    defaultRule = EventRule(eventType: .groupMention, playSound: true, soundName: "Ping", bounceDock: true, updateBadge: true, showNotification: true)
                case .messageSendError:
                    defaultRule = EventRule(eventType: .messageSendError, playSound: true, soundName: "Sosumi", bounceDock: false, updateBadge: false, showNotification: true)
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
    
    public func triggerEvent(_ eventType: FluoriteEventType, title: String, content: String, contactID: UUID? = nil) {
        lastTriggeredEvent = (type: eventType, title: title, content: content)
        
        let rule = rules[eventType] ?? EventRule(eventType: eventType)
        
        // 1. Play sound. An installed classic .AdiumSoundset overrides
        // the built-in system sounds per event.
        if rule.playSound {
            if let file = Self.customSoundFile(for: eventType),
               let sound = NSSound(contentsOf: file, byReference: false) {
                sound.play()
            } else {
                playSound(named: rule.soundName)
            }
        }
        
        // 2. Bounce dock
        if rule.bounceDock {
            bounceDockIcon()
        }
        
        // 3. Update badge. The code does not handle this here.
        // The caller calculates the unread total.
        // The caller sets the total with EventManager.setUnreadCount.
        // This prevents a double count on the badge.
        // EventManager.setUnreadCount is the single source of truth for the count.

        // 4. Show macOS notification
        if rule.showNotification {
            NotificationService.shared.notifyIncomingMessage(sender: title, content: content, playSound: rule.playSound)
        }
    }

    // MARK: - Classic Sound Sets

    /// This is where installed .AdiumSoundset folders live, copied out of
    /// the user's pick so the app survives the original moving away.
    nonisolated public static func soundSetsRoot() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Fluorite/SoundSets", isDirectory: true)
    }

    nonisolated public static func activeSoundSetName() -> String? {
        UserDefaults.standard.string(forKey: "AdiumSoundSet")
    }

    /// This copies a .AdiumSoundset folder into the app support tree and
    /// makes it active. Sounds.plist maps classic event names to files.
    public static func installSoundSet(from url: URL) throws {
        guard url.lastPathComponent.lowercased().hasSuffix(".adiumsoundset") else {
            throw NSError(domain: "SoundSet", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Not an .AdiumSoundset folder"])
        }
        let root = soundSetsRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        UserDefaults.standard.set(url.lastPathComponent, forKey: "AdiumSoundSet")
    }

    public static func clearSoundSet() {
        UserDefaults.standard.removeObject(forKey: "AdiumSoundSet")
    }

    /// This maps an app event to its classic Adium sound key.
    nonisolated static func classicSoundKey(for eventType: FluoriteEventType) -> String? {
        switch eventType {
        case .messageReceived, .groupMention: return "Message Received"
        case .messageSent: return "Message Sent"
        case .contactOnline: return "Contact Sign On"
        case .contactOffline: return "Contact Sign Off"
        case .transferCompleted: return "File Transfer Complete"
        case .transferFailed: return "File Transfer Failed"
        case .messageSendError: return "Error"
        case .accountConnected, .accountDisconnected: return nil
        }
    }

    nonisolated private static func customSoundFile(for eventType: FluoriteEventType) -> URL? {
        guard let name = activeSoundSetName(),
              let key = classicSoundKey(for: eventType) else { return nil }
        let plist = soundSetsRoot()
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent("Sounds.plist")
        guard let dict = NSDictionary(contentsOf: plist) else { return nil }
        let fileName: String?
        switch dict[key] {
        case let file as String: fileName = file
        case let entry as [String: Any]: fileName = (entry["Sound"] ?? entry["File"]) as? String
        default: fileName = nil
        }
        guard let fileName else { return nil }
        let file = plist.deletingLastPathComponent().appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
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
