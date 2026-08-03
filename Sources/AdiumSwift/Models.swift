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
    
    public var sortPriority: Int {
        switch self {
        case .available: return 0
        case .away: return 1
        case .busy: return 2
        case .offline: return 3
        }
    }
}

public enum AccountProtocol: String, Codable, CaseIterable, Sendable {
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

public enum ContactSortOrder: String, Codable, CaseIterable {
    case name = "Alfabetico"
    case status = "Por Estado"
}

public struct ContactGroup: Identifiable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var isExpanded: Bool
    
    public init(id: UUID = UUID(), name: String, isExpanded: Bool = true) {
        self.id = id
        self.name = name
        self.isExpanded = isExpanded
    }
}

public struct Metacontact: Identifiable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var contactIDs: [UUID]
    public var primaryContactID: UUID?
    public var group: String
    public var avatarData: Data?
    
    public init(
        id: UUID = UUID(),
        name: String,
        contactIDs: [UUID] = [],
        primaryContactID: UUID? = nil,
        group: String = "General",
        avatarData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.contactIDs = contactIDs
        self.primaryContactID = primaryContactID
        self.group = group
        self.avatarData = avatarData
    }
}

public struct Account: Identifiable, Hashable, Codable {
    public let id: UUID
    public var username: String
    public var accountProtocol: AccountProtocol
    public var isConnected: Bool
    public var connectionError: String?
    
    // Advanced options per service
    public var server: String?
    public var port: Int?
    public var resource: String?
    public var useSSL: Bool?
    public var customOptions: [String: String]
    
    public init(
        id: UUID = UUID(),
        username: String,
        accountProtocol: AccountProtocol,
        isConnected: Bool = false,
        connectionError: String? = nil,
        server: String? = nil,
        port: Int? = nil,
        resource: String? = nil,
        useSSL: Bool? = nil,
        customOptions: [String: String] = [:]
    ) {
        self.id = id
        self.username = username
        self.accountProtocol = accountProtocol
        self.isConnected = isConnected
        self.connectionError = connectionError
        self.server = server
        self.port = port
        self.resource = resource
        self.useSSL = useSSL
        self.customOptions = customOptions
    }

    // Custom decoding for backward compatibility: `customOptions` was added after this
    // struct was first persisted, so JSON written by older builds lacks the key. Without
    // this, decoding throws keyNotFound and callers using `try?` silently drop all saved
    // accounts.
    enum CodingKeys: String, CodingKey {
        case id, username, accountProtocol, isConnected, connectionError, server, port, resource, useSSL, customOptions
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        username = try container.decode(String.self, forKey: .username)
        accountProtocol = try container.decode(AccountProtocol.self, forKey: .accountProtocol)
        isConnected = try container.decode(Bool.self, forKey: .isConnected)
        connectionError = try container.decodeIfPresent(String.self, forKey: .connectionError)
        server = try container.decodeIfPresent(String.self, forKey: .server)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        resource = try container.decodeIfPresent(String.self, forKey: .resource)
        useSSL = try container.decodeIfPresent(Bool.self, forKey: .useSSL)
        customOptions = try container.decodeIfPresent([String: String].self, forKey: .customOptions) ?? [:]
    }
}

public struct GroupParticipant: Identifiable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var handle: String
    public var status: OnlineStatus
    public var role: String?
    public var avatarData: Data?
    
    public var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return trimmedName
        }
        return handle
    }
    
    public init(
        id: UUID = UUID(),
        name: String,
        handle: String,
        status: OnlineStatus = .available,
        role: String? = nil,
        avatarData: Data? = nil
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.status = status
        self.role = role
        self.avatarData = avatarData
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
    
    // Advanced contact fields
    public var alias: String?
    public var isBlocked: Bool
    public var metacontactID: UUID?
    public var avatarData: Data?
    public var isTyping: Bool
    
    // Group chat fields
    public var isGroupChat: Bool
    public var groupParticipants: [GroupParticipant]
    public var topic: String?
    
    public var displayName: String {
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed = trimmedAlias, !trimmed.isEmpty {
            return trimmed
        }
        return name
    }
    
    public init(
        id: UUID = UUID(),
        name: String,
        handle: String,
        status: OnlineStatus,
        customStatusMessage: String? = nil,
        group: String = "General",
        accountProtocol: AccountProtocol = .teams,
        avatarURL: URL? = nil,
        accountUsername: String? = nil,
        alias: String? = nil,
        isBlocked: Bool = false,
        metacontactID: UUID? = nil,
        avatarData: Data? = nil,
        isTyping: Bool = false,
        isGroupChat: Bool = false,
        groupParticipants: [GroupParticipant] = [],
        topic: String? = nil
    ) {
        self.id = id
        self.name = name
        self.handle = handle
        self.status = status
        self.customStatusMessage = customStatusMessage
        self.group = group
        self.accountProtocol = accountProtocol
        self.avatarURL = avatarURL
        self.accountUsername = accountUsername
        self.alias = alias
        self.isBlocked = isBlocked
        self.metacontactID = metacontactID
        self.avatarData = avatarData
        self.isTyping = isTyping
        self.isGroupChat = isGroupChat
        self.groupParticipants = groupParticipants
        self.topic = topic
    }

    // Custom decoding for backward compatibility: `isBlocked`, `isTyping`, `isGroupChat`
    // and `groupParticipants` were added after this struct was first persisted. Without
    // this, decoding JSON saved by an older build throws keyNotFound and callers using
    // `try?` silently wipe out all saved contacts (and old backups fail to import).
    enum CodingKeys: String, CodingKey {
        case id, name, handle, status, customStatusMessage, group, accountProtocol, avatarURL, accountUsername
        case alias, isBlocked, metacontactID, avatarData, isTyping
        case isGroupChat, groupParticipants, topic
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        handle = try container.decode(String.self, forKey: .handle)
        status = try container.decode(OnlineStatus.self, forKey: .status)
        customStatusMessage = try container.decodeIfPresent(String.self, forKey: .customStatusMessage)
        group = try container.decode(String.self, forKey: .group)
        accountProtocol = try container.decode(AccountProtocol.self, forKey: .accountProtocol)
        avatarURL = try container.decodeIfPresent(URL.self, forKey: .avatarURL)
        accountUsername = try container.decodeIfPresent(String.self, forKey: .accountUsername)
        alias = try container.decodeIfPresent(String.self, forKey: .alias)
        isBlocked = try container.decodeIfPresent(Bool.self, forKey: .isBlocked) ?? false
        metacontactID = try container.decodeIfPresent(UUID.self, forKey: .metacontactID)
        avatarData = try container.decodeIfPresent(Data.self, forKey: .avatarData)
        isTyping = try container.decodeIfPresent(Bool.self, forKey: .isTyping) ?? false
        isGroupChat = try container.decodeIfPresent(Bool.self, forKey: .isGroupChat) ?? false
        groupParticipants = try container.decodeIfPresent([GroupParticipant].self, forKey: .groupParticipants) ?? []
        topic = try container.decodeIfPresent(String.self, forKey: .topic)
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

