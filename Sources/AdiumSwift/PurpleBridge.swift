import Foundation
import CLibpurple

/// Bridge service responsible for coordinating messaging protocols (including libpurple + purple-teams).
@MainActor
@Observable
public final class PurpleBridgeService {
    public static let shared = PurpleBridgeService()
    
    private let savedAccountsKey = "AdiumSavedAccounts"
    
    public var isLibpurpleLoaded: Bool = false
    public var activePluginName: String = "purple-teams"
    public var connectionState: String = "Sin cuentas"
    public var myStatus: OnlineStatus = .available
    
    public var accounts: [Account] = []
    public var contacts: [Contact] = []
    public var messagesPerContact: [UUID: [ChatMessage]] = [:]
    
    /// Indicates whether any configured account encountered a connection error
    public var hasAccountError: Bool {
        accounts.contains(where: { !$0.isConnected && $0.connectionError != nil })
    }
    
    /// Consolidated error message summary for disconnected accounts
    public var accountErrorSummary: String? {
        let errors = accounts.compactMap { acc -> String? in
            guard let err = acc.connectionError, !acc.isConnected else { return nil }
            return "\(acc.username): \(err)"
        }
        return errors.isEmpty ? nil : errors.joined(separator: "; ")
    }
    
    /// Set overall user presence status in bridge and libpurple
    public func setUserStatus(_ status: OnlineStatus) {
        self.myStatus = status
        if isLibpurpleLoaded {
            let statusId: String
            switch status {
            case .available: statusId = "available"
            case .away: statusId = "away"
            case .busy: statusId = "busy"
            case .offline: statusId = "offline"
            }
            _ = adium_purple_set_user_status(statusId)
        }
    }
    
    /// Reconnect all configured accounts
    public func reconnectAccounts() {
        self.connectionState = "Reconectando cuentas..."
        for i in 0..<accounts.count {
            accounts[i].connectionError = nil
        }
        if isLibpurpleLoaded {
            for acc in accounts {
                let accountKey = "\(acc.username):\(acc.accountProtocol.purpleProtocolID)"
                let password = KeychainHelper.fetchPassword(for: accountKey) ?? ""
                _ = adium_purple_add_account(acc.username, acc.accountProtocol.purpleProtocolID, password)
            }
            if let statusCStr = adium_purple_get_status_info() {
                self.connectionState = String(cString: statusCStr)
            }
        }
    }
    
    private init() {
        restoreSavedAccounts()
    }
    
    /// Save accounts metadata to UserDefaults for persistence
    private func saveAccountsToDefaults() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: savedAccountsKey)
        }
    }
    
    /// Restore accounts metadata from UserDefaults
    public func restoreSavedAccounts() {
        guard let data = UserDefaults.standard.data(forKey: savedAccountsKey),
              let saved = try? JSONDecoder().decode([Account].self, from: data) else {
            return
        }
        self.accounts = saved
    }
    
    /// Connect a new account via libpurple (e.g. Teams, XMPP)
    public func connectAccount(username: String, protocolType: AccountProtocol, password: String) {
        let accountKey = "\(username):\(protocolType.purpleProtocolID)"
        if !password.isEmpty {
            KeychainHelper.savePassword(password, for: accountKey)
        }
        
        if !accounts.contains(where: { $0.username == username && $0.accountProtocol == protocolType }) {
            let newAccount = Account(username: username, accountProtocol: protocolType, isConnected: false)
            self.accounts.append(newAccount)
            saveAccountsToDefaults()
        }
        
        if isLibpurpleLoaded {
            let fetchedPassword = password.isEmpty ? (KeychainHelper.fetchPassword(for: accountKey) ?? "") : password
            _ = adium_purple_add_account(username, protocolType.purpleProtocolID, fetchedPassword)
            if let statusCStr = adium_purple_get_status_info() {
                self.connectionState = String(cString: statusCStr)
            }
        }
    }
    
    /// Remove an account and disconnect it from libpurple
    public func removeAccount(_ account: Account) {
        self.accounts.removeAll(where: { $0.id == account.id })
        saveAccountsToDefaults()
        
        let accountKey = "\(account.username):\(account.accountProtocol.purpleProtocolID)"
        KeychainHelper.deletePassword(for: accountKey)
        
        self.contacts.removeAll(where: { $0.accountProtocol == account.accountProtocol && ($0.accountUsername == nil || $0.accountUsername == account.username) })
        
        if isLibpurpleLoaded {
            _ = adium_purple_remove_account(account.username, account.accountProtocol.purpleProtocolID)
        }
        
        if accounts.isEmpty {
            self.connectionState = "Sin cuentas"
        }
    }
    
    /// Discovers all available libpurple plugin `.so` files from the App Bundle PlugIns path and local Plugins directory.
    private func discoverPluginPaths() -> [String] {
        var foundPlugins: [String: String] = [:] // filename -> full path
        let fileManager = FileManager.default

        // 1. App Bundle Contents/PlugIns directory
        let bundlePlugInsDir = Bundle.main.bundlePath + "/Contents/PlugIns"
        if fileManager.fileExists(atPath: bundlePlugInsDir),
           let contents = try? fileManager.contentsOfDirectory(atPath: bundlePlugInsDir) {
            for file in contents where file.hasSuffix(".so") {
                let fullPath = (bundlePlugInsDir as NSString).appendingPathComponent(file)
                foundPlugins[file] = fullPath
            }
        }

        // 2. Development Plugins directory (e.g. ./Plugins/purple-teams/libteams.so, ./Plugins/purple-whatsapp/libwhatsapp.so)
        let currentDir = fileManager.currentDirectoryPath
        let searchDirs = [
            "Plugins",
            (currentDir as NSString).appendingPathComponent("Plugins")
        ]
        
        for searchDir in searchDirs {
            if fileManager.fileExists(atPath: searchDir),
               let subdirs = try? fileManager.contentsOfDirectory(atPath: searchDir) {
                for subdir in subdirs {
                    let pluginSubdir = (searchDir as NSString).appendingPathComponent(subdir)
                    var isDir: ObjCBool = false
                    if fileManager.fileExists(atPath: pluginSubdir, isDirectory: &isDir), isDir.boolValue {
                        if let files = try? fileManager.contentsOfDirectory(atPath: pluginSubdir) {
                            for file in files where file.hasSuffix(".so") {
                                if foundPlugins[file] == nil {
                                    let fullPath = (pluginSubdir as NSString).appendingPathComponent(file)
                                    foundPlugins[file] = fullPath
                                }
                            }
                        }
                    }
                }
            }
        }

        return Array(foundPlugins.values)
    }
    
    /// Initialize libpurple C core and load dynamic plugins (.so / .dylib / purple-teams / purple-whatsapp)
    public func initializeLibpurpleCore() {
        let pluginsSearchDir = Bundle.main.bundlePath + "/Contents/PlugIns"
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let userDir = userHome + "/.adium-swift"
        
        // 1. Set event callbacks from C -> Swift
        adium_purple_set_event_callbacks(
            PurpleBridgeService.handleContactCallback,
            PurpleBridgeService.handleMessageCallback,
            PurpleBridgeService.handleStatusCallback,
            PurpleBridgeService.handleAccountStateCallback
        )
        
        // 2. Initialize Libpurple Core
        let success = adium_purple_init(pluginsSearchDir, userDir)
        
        if success {
            self.isLibpurpleLoaded = true
            
            // Start GLib background socket event loop
            adium_purple_start_event_loop()
            
            // Dynamic discovery and loading of all available plugin .so files
            let discoveredPlugins = discoverPluginPaths()
            var loadedPluginNames: [String] = []
            for pluginPath in discoveredPlugins {
                _ = adium_purple_load_plugin(pluginPath)
                let pluginFileName = (pluginPath as NSString).lastPathComponent
                loadedPluginNames.append(pluginFileName)
            }
            if !loadedPluginNames.isEmpty {
                self.activePluginName = loadedPluginNames.joined(separator: ", ")
            }
            
            // Re-connect saved accounts with passwords from Keychain
            for acc in accounts {
                let accountKey = "\(acc.username):\(acc.accountProtocol.purpleProtocolID)"
                let password = KeychainHelper.fetchPassword(for: accountKey) ?? ""
                _ = adium_purple_add_account(acc.username, acc.accountProtocol.purpleProtocolID, password)
            }
            
            // Emit loaded accounts & buddies from libpurple
            adium_purple_load_accounts()
            
            if let statusCStr = adium_purple_get_status_info() {
                self.connectionState = String(cString: statusCStr)
            } else {
                self.connectionState = "Activo (\(self.activePluginName))"
            }
        } else {
            self.connectionState = "Error de Inicialización Libpurple"
        }
    }
    
    /// Retrieve messages for a contact, loading from ChatLogStore if not cached
    public func messages(for contact: Contact) -> [ChatMessage] {
        if let cached = messagesPerContact[contact.id] {
            return cached
        }
        let loaded = ChatLogStore.shared.loadMessages(for: contact.handle) ?? []
        messagesPerContact[contact.id] = loaded
        return loaded
    }
    
    public func sendMessage(_ text: String, to contact: Contact) {
        let newMsg = ChatMessage(senderName: "Me", isFromMe: true, text: text)
        if messagesPerContact[contact.id] != nil {
            messagesPerContact[contact.id]?.append(newMsg)
        } else {
            var existing = ChatLogStore.shared.loadMessages(for: contact.handle) ?? []
            existing.append(newMsg)
            messagesPerContact[contact.id] = existing
        }
        
        if let updatedMsgs = messagesPerContact[contact.id] {
            ChatLogStore.shared.saveMessages(updatedMsgs, for: contact.handle)
        }
        
        if isLibpurpleLoaded {
            let account = accounts.first(where: { $0.accountProtocol == contact.accountProtocol })
            _ = adium_purple_send_message(account?.username, contact.accountProtocol.purpleProtocolID, contact.handle, text)
            if let statusCStr = adium_purple_get_status_info() {
                self.connectionState = String(cString: statusCStr)
            }
        }
    }
    
    // MARK: - Handlers for Live Events from Libpurple
    
    func onContactUpdated(name: String, handle: String, statusId: String, statusName: String, group: String, protocolId: String) {
        let parsedStatus: OnlineStatus
        switch statusId.lowercased() {
        case "available", "online": parsedStatus = .available
        case "away": parsedStatus = .away
        case "busy", "dnd": parsedStatus = .busy
        default: parsedStatus = .offline
        }
        
        let proto = AccountProtocol.allCases.first(where: { $0.purpleProtocolID == protocolId }) ?? .teams
        let matchingAccount = accounts.first(where: { $0.accountProtocol == proto })
        
        if let idx = contacts.firstIndex(where: { $0.handle == handle }) {
            contacts[idx].name = name
            contacts[idx].status = parsedStatus
            contacts[idx].customStatusMessage = statusName
            contacts[idx].group = group
            if contacts[idx].accountUsername == nil {
                contacts[idx].accountUsername = matchingAccount?.username
            }
        } else {
            let newContact = Contact(
                name: name,
                handle: handle,
                status: parsedStatus,
                customStatusMessage: statusName,
                group: group,
                accountProtocol: proto,
                accountUsername: matchingAccount?.username
            )
            contacts.append(newContact)
        }
    }
    
    func onMessageReceived(senderHandle: String, text: String, isFromMe: Bool) {
        var contact = contacts.first(where: { $0.handle == senderHandle })
        
        // Handling Unknown Senders: create a new Contact on-the-fly if not found
        if contact == nil {
            let defaultProto = accounts.first?.accountProtocol ?? .teams
            let defaultUsername = accounts.first?.username
            let newContact = Contact(
                name: senderHandle,
                handle: senderHandle,
                status: .available,
                customStatusMessage: nil,
                group: "General",
                accountProtocol: defaultProto,
                accountUsername: defaultUsername
            )
            contacts.append(newContact)
            contact = newContact
        }
        
        guard let c = contact else { return }
        let senderName = isFromMe ? "Me" : c.name
        let newMsg = ChatMessage(senderName: senderName, isFromMe: isFromMe, text: text)
        
        if messagesPerContact[c.id] != nil {
            // Deduplicate: if last message was sent from me with identical text within 3 seconds, skip duplicate signal
            if let last = messagesPerContact[c.id]?.last, last.isFromMe == isFromMe, last.text == text, abs(Date().timeIntervalSince(last.timestamp)) < 3.0 {
                return
            }
            messagesPerContact[c.id]?.append(newMsg)
        } else {
            var existing = ChatLogStore.shared.loadMessages(for: c.handle) ?? []
            if let last = existing.last, last.isFromMe == isFromMe, last.text == text, abs(Date().timeIntervalSince(last.timestamp)) < 3.0 {
                return
            }
            existing.append(newMsg)
            messagesPerContact[c.id] = existing
        }
        
        if let updatedMsgs = messagesPerContact[c.id] {
            ChatLogStore.shared.saveMessages(updatedMsgs, for: c.handle)
        }
        
        if !isFromMe {
            NotificationService.shared.notifyIncomingMessage(sender: c.name, content: text)
        }
    }
    
    func onAccountStateChanged(username: String, protocolId: String, isConnected: Bool, statusMsg: String) {
        let proto = AccountProtocol.allCases.first(where: { $0.purpleProtocolID == protocolId })
        if let idx = accounts.firstIndex(where: { $0.username == username && (proto == nil || $0.accountProtocol == proto) }) {
            accounts[idx].isConnected = isConnected
            if !isConnected && statusMsg != "Desconectado" {
                accounts[idx].connectionError = statusMsg
            } else if isConnected {
                accounts[idx].connectionError = nil
            }
            saveAccountsToDefaults()
        }
        self.connectionState = "\(username): \(statusMsg)"
    }
    
    // MARK: - C Callback Definitions
    
    private static let handleContactCallback: adium_purple_on_contact_cb = { name, handle, statusId, statusName, group, protocolId in
        guard let name = name, let handle = handle, let statusId = statusId, let statusName = statusName, let group = group, let protocolId = protocolId else { return }
        let nStr = String(cString: name)
        let hStr = String(cString: handle)
        let sIdStr = String(cString: statusId)
        let sNameStr = String(cString: statusName)
        let gStr = String(cString: group)
        let pStr = String(cString: protocolId)
        
        DispatchQueue.main.async {
            PurpleBridgeService.shared.onContactUpdated(name: nStr, handle: hStr, statusId: sIdStr, statusName: sNameStr, group: gStr, protocolId: pStr)
        }
    }
    
    private static let handleMessageCallback: adium_purple_on_message_cb = { senderHandle, messageText, isFromMe in
        guard let senderHandle = senderHandle, let messageText = messageText else { return }
        let hStr = String(cString: senderHandle)
        let mStr = String(cString: messageText)
        
        DispatchQueue.main.async {
            PurpleBridgeService.shared.onMessageReceived(senderHandle: hStr, text: mStr, isFromMe: isFromMe)
        }
    }
    
    private static let handleStatusCallback: adium_purple_on_status_cb = { statusText in
        guard let statusText = statusText else { return }
        let sStr = String(cString: statusText)
        
        DispatchQueue.main.async {
            PurpleBridgeService.shared.connectionState = sStr
        }
    }
    
    private static let handleAccountStateCallback: adium_purple_on_account_state_cb = { username, protocolId, isConnected, statusMsg in
        guard let username = username, let protocolId = protocolId, let statusMsg = statusMsg else { return }
        let uStr = String(cString: username)
        let pStr = String(cString: protocolId)
        let sStr = String(cString: statusMsg)
        
        DispatchQueue.main.async {
            PurpleBridgeService.shared.onAccountStateChanged(username: uStr, protocolId: pStr, isConnected: isConnected, statusMsg: sStr)
        }
    }
}

