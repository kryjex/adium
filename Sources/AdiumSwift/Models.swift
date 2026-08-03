import Foundation

public enum OnlineStatus: String, Codable, CaseIterable {
    case available = "Available"
    case away = "Away"
    case busy = "Busy"
    case offline = "Offline"
    
    public var iconName: String {
        switch self {
        case .available: return "checkmark.circle.fill"
        case .away: return "clock.fill"
        case .busy: return "minus.circle.fill"
        case .offline: return "circle"
        }
    }
}

public enum AccountProtocol: String, Codable, CaseIterable {
    case teams = "Microsoft Teams"
    case whatsapp = "WhatsApp"
    case xmpp = "XMPP / Jabber"
    case matrix = "Matrix"
    case customLibpurple = "Libpurple Plugin"
    
    public var iconName: String {
        switch self {
        case .teams: return "person.2.comm.fill"
        case .whatsapp: return "message.fill"
        case .xmpp: return "bubble.left.and.bubble.right.fill"
        case .matrix: return "network"
        case .customLibpurple: return "puzzlepiece.fill"
        }
    }
    
    public var purpleProtocolID: String {
        switch self {
        case .teams: return "prpl-eionrobb-msteams"
        case .whatsapp: return "prpl-hehoe-whatsmeow"
        case .xmpp: return "prpl-jabber"
        case .matrix: return "prpl-matrix"
        case .customLibpurple: return "prpl-custom"
        }
    }
}

public struct Account: Identifiable, Hashable, Codable {
    public let id: UUID
    public var username: String
    public var accountProtocol: AccountProtocol
    public var isConnected: Bool
    public var connectionError: String?
    
    public init(id: UUID = UUID(), username: String, accountProtocol: AccountProtocol, isConnected: Bool = false, connectionError: String? = nil) {
        self.id = id
        self.username = username
        self.accountProtocol = accountProtocol
        self.isConnected = isConnected
        self.connectionError = connectionError
    }
}

public struct Contact: Identifiable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var handle: String
    public var status: OnlineStatus
    public var customStatusMessage: String?
    public var group: String
    public var accountProtocol: AccountProtocol
    public var avatarURL: URL?
    public var accountUsername: String?
    
    public init(id: UUID = UUID(), name: String, handle: String, status: OnlineStatus, customStatusMessage: String? = nil, group: String = "General", accountProtocol: AccountProtocol = .teams, avatarURL: URL? = nil, accountUsername: String? = nil) {
        self.id = id
        self.name = name
        self.handle = handle
        self.status = status
        self.customStatusMessage = customStatusMessage
        self.group = group
        self.accountProtocol = accountProtocol
        self.avatarURL = avatarURL
        self.accountUsername = accountUsername
    }
}

public struct ChatMessage: Identifiable, Hashable, Codable {
    public let id: UUID
    public let senderName: String
    public let isFromMe: Bool
    public let text: String
    public let timestamp: Date
    
    public init(id: UUID = UUID(), senderName: String, isFromMe: Bool, text: String, timestamp: Date = Date()) {
        self.id = id
        self.senderName = senderName
        self.isFromMe = isFromMe
        self.text = text
        self.timestamp = timestamp
    }
}
