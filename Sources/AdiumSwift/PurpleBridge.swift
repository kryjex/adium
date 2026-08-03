import Foundation
import CLibpurple
import AppKit

/// Bridge service responsible for coordinating messaging protocols (including libpurple + purple-teams).
@MainActor
@Observable
public final class PurpleBridgeService {
    public static let shared = PurpleBridgeService()
    
    private let savedAccountsKey = "AdiumSavedAccounts"
    private let savedGroupsKey = "AdiumSavedGroups"
    private let savedMetacontactsKey = "AdiumSavedMetacontacts"
    private let savedContactsKey = "AdiumSavedContacts"
    private let savedStatusMessageKey = "AdiumStatusMessage"
    private let legacyImportDoneKey = "AdiumImportedLegacyPurpleAccounts"

    public var isLibpurpleLoaded: Bool = false
    public var activePluginName: String = "purple-teams"
    public var connectionState: String = "Sin cuentas"
    public var myStatus: OnlineStatus = .available
    /// Custom status text shown alongside `myStatus` (e.g. "En una reunión"). Persisted in
    /// UserDefaults and re-applied to libpurple whenever the status or the message changes.
    public var myStatusMessage: String = ""
    
    public var accounts: [Account] = []
    public var contacts: [Contact] = []
    public var contactGroups: [ContactGroup] = []
    public var metacontacts: [Metacontact] = []
    public var messagesPerContact: [UUID: [ChatMessage]] = [:]
    
    // MARK: - Tab & Unread State
    public var openTabIDs: [UUID] = []
    public var activeTabID: UUID? = nil
    public var unreadCounts: [UUID: Int] = [:]

    /// Addresses of in-flight libpurple request handles currently shown as an NSAlert.
    /// Removed by onRequestClose so a respond queued after libpurple already closed the
    /// request (e.g. the account disconnected while the alert was still up) is dropped
    /// instead of firing into a stale/reused handle.
    private var pendingRequestAddrs: Set<UInt> = []


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
    
    private func purpleStatusId(for status: OnlineStatus) -> String {
        switch status {
        case .available: return "available"
        case .away: return "away"
        case .busy: return "busy"
        case .offline: return "offline"
        }
    }

    /// Set overall user presence status in bridge and libpurple, carrying along whatever
    /// custom status message is currently set.
    public func setUserStatus(_ status: OnlineStatus) {
        self.myStatus = status
        if isLibpurpleLoaded {
            _ = adium_purple_set_user_status(purpleStatusId(for: status), myStatusMessage)
        }
    }

    /// Update the custom status message text and re-apply the current status (with the new
    /// message) to libpurple. Persisted to UserDefaults so it survives relaunches.
    public func setStatusMessage(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.myStatusMessage = trimmed
        UserDefaults.standard.set(trimmed, forKey: savedStatusMessageKey)
        if isLibpurpleLoaded {
            _ = adium_purple_set_user_status(purpleStatusId(for: myStatus), trimmed)
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
                // Options must be applied after the account exists in libpurple: both
                // calls funnel through g_idle_add in order, so do_set_account_option would
                // run against purple_accounts_find() == NULL (and silently drop the
                // options) if applied first.
                _ = adium_purple_add_account(acc.username, acc.accountProtocol.purpleProtocolID, password)
                applyAccountOptions(acc)
            }
            if let statusCStr = adium_purple_get_status_info() {
                self.connectionState = String(cString: statusCStr)
            }
        }
    }
    
    private init() {
        restoreSavedAccounts()
        restoreSavedGroups()
        restoreSavedMetacontacts()
        restoreSavedContacts()
        self.myStatusMessage = UserDefaults.standard.string(forKey: savedStatusMessageKey) ?? ""
    }
    
    /// Save accounts metadata to UserDefaults for persistence
    private func saveAccountsToDefaults() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: savedAccountsKey)
        }
    }
    
    /// Restore accounts metadata from UserDefaults
    public func restoreSavedAccounts() {
        if let data = UserDefaults.standard.data(forKey: savedAccountsKey),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            self.accounts = saved
        }
        // Import from libpurple only on true first run: once the Swift layer has persisted
        // its own list (even an empty one — e.g. the user deleted their last account), or the
        // one-time import already ran, re-importing would resurrect deleted accounts from
        // stale accounts.xml entries.
        if accounts.isEmpty,
           UserDefaults.standard.data(forKey: savedAccountsKey) == nil,
           !UserDefaults.standard.bool(forKey: legacyImportDoneKey) {
            importAccountsFromLibpurple()
        }
    }

    /// libpurple protocol IDs we can map back to an AccountProtocol, including
    /// retired IDs from earlier builds ("prpl-teams" never matched the real
    /// plugin ID and could never connect; "prpl-adium-whatsapp" was the stub).
    nonisolated static let importableProtocolIDs: [String: AccountProtocol] = [
        "prpl-eionrobb-msteams": .teams,
        "prpl-teams": .teams,
        "prpl-hehoe-whatsmeow": .whatsapp,
        "prpl-adium-whatsapp": .whatsapp,
        "prpl-jabber": .xmpp,
        "prpl-matrix": .matrix
    ]

    /// One-time import of accounts that exist only in libpurple's accounts.xml —
    /// accounts added before the Swift layer persisted its own account list would
    /// otherwise show up as "0 cuentas" even though libpurple still has them.
    private func importAccountsFromLibpurple() {
        defer { UserDefaults.standard.set(true, forKey: legacyImportDoneKey) }
        let accountsXML = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".adium-swift/accounts.xml")
        guard let xml = try? String(contentsOf: accountsXML, encoding: .utf8) else { return }
        let imported = Self.parsePurpleAccountsXML(xml)
        guard !imported.isEmpty else { return }
        for account in imported where !accounts.contains(where: {
            $0.username == account.username && $0.accountProtocol == account.accountProtocol
        }) {
            accounts.append(account)
        }
        saveAccountsToDefaults()
    }

    /// Parse the `<account><protocol>…</protocol><name>…</name></account>` entries of a
    /// libpurple accounts.xml, keeping only protocols we know how to map. Exposed for testing.
    nonisolated static func parsePurpleAccountsXML(_ xml: String) -> [Account] {
        var result: [Account] = []
        for block in xml.components(separatedBy: "</account>") {
            guard let protocolID = firstTagContent("protocol", in: block),
                  let name = firstTagContent("name", in: block),
                  let mapped = importableProtocolIDs[protocolID],
                  !name.isEmpty else { continue }
            if !result.contains(where: { $0.username == name && $0.accountProtocol == mapped }) {
                result.append(Account(username: name, accountProtocol: mapped))
            }
        }
        return result
    }

    private nonisolated static func firstTagContent(_ tag: String, in text: String) -> String? {
        guard let open = text.range(of: "<\(tag)>"),
              let close = text.range(of: "</\(tag)>", range: open.upperBound..<text.endIndex) else {
            return nil
        }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    // MARK: - Group Persistence & Operations
    
    private func saveGroupsToDefaults() {
        if let encoded = try? JSONEncoder().encode(contactGroups) {
            UserDefaults.standard.set(encoded, forKey: savedGroupsKey)
        }
    }
    
    public func restoreSavedGroups() {
        if let data = UserDefaults.standard.data(forKey: savedGroupsKey),
           let saved = try? JSONDecoder().decode([ContactGroup].self, from: data) {
            self.contactGroups = saved
        }
        if contactGroups.isEmpty {
            self.contactGroups = [
                ContactGroup(name: "General", isExpanded: true),
                ContactGroup(name: "Trabajo", isExpanded: true),
                ContactGroup(name: "Amigos", isExpanded: true)
            ]
        }
    }
    
    public func createGroup(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if !contactGroups.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            contactGroups.append(ContactGroup(name: trimmed, isExpanded: true))
            saveGroupsToDefaults()
        }
    }
    
    public func renameGroup(oldName: String, newName: String) {
        let trimmedNew = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedNew.isEmpty, oldName != trimmedNew else { return }
        // Refuse to create a second group with a name that already exists (case-insensitive,
        // matching createGroup's duplicate check) — two ContactGroup entries with the same
        // name break the UI's section identity.
        guard !contactGroups.contains(where: { $0.name.caseInsensitiveCompare(trimmedNew) == .orderedSame }) else { return }

        if let idx = contactGroups.firstIndex(where: { $0.name == oldName }) {
            contactGroups[idx].name = trimmedNew
            saveGroupsToDefaults()
        }
        
        for idx in contacts.indices {
            if contacts[idx].group == oldName {
                contacts[idx].group = trimmedNew
            }
        }
        saveContactsToDefaults()
        
        for idx in metacontacts.indices {
            if metacontacts[idx].group == oldName {
                metacontacts[idx].group = trimmedNew
            }
        }
        saveMetacontactsToDefaults()
    }
    
    public func deleteGroup(name: String) {
        contactGroups.removeAll(where: { $0.name == name })
        saveGroupsToDefaults()
        
        for idx in contacts.indices {
            if contacts[idx].group == name {
                contacts[idx].group = "General"
            }
        }
        saveContactsToDefaults()
        
        for idx in metacontacts.indices {
            if metacontacts[idx].group == name {
                metacontacts[idx].group = "General"
            }
        }
        saveMetacontactsToDefaults()
    }
    
    public func toggleGroupExpanded(name: String) {
        if let idx = contactGroups.firstIndex(where: { $0.name == name }) {
            contactGroups[idx].isExpanded.toggle()
            saveGroupsToDefaults()
        }
    }
    
    public func moveContact(_ contactID: UUID, toGroup groupName: String) {
        createGroup(name: groupName)
        if let idx = contacts.firstIndex(where: { $0.id == contactID }) {
            contacts[idx].group = groupName
            saveContactsToDefaults()
        }
    }
    
    // MARK: - Metacontact Persistence & Operations
    
    private func saveMetacontactsToDefaults() {
        if let encoded = try? JSONEncoder().encode(metacontacts) {
            UserDefaults.standard.set(encoded, forKey: savedMetacontactsKey)
        }
    }
    
    public func restoreSavedMetacontacts() {
        if let data = UserDefaults.standard.data(forKey: savedMetacontactsKey),
           let saved = try? JSONDecoder().decode([Metacontact].self, from: data) {
            self.metacontacts = saved
        }
    }
    
    @discardableResult
    public func combineContacts(_ contactIDs: [UUID], name: String? = nil) -> Metacontact {
        let matchingContacts = contacts.filter { contactIDs.contains($0.id) }
        let defaultName = name ?? matchingContacts.first?.displayName ?? "Metacontacto"
        let group = matchingContacts.first?.group ?? "General"

        // A contact being combined here may already belong to a different metacontact
        // (e.g. combining A+B then B+C); detach it from that old one first so it doesn't
        // end up listed under two metacontacts at once.
        for cID in contactIDs {
            detachContactFromExistingMetacontact(cID)
        }

        let meta = Metacontact(
            name: defaultName,
            contactIDs: contactIDs,
            primaryContactID: contactIDs.first,
            group: group
        )

        metacontacts.append(meta)
        saveMetacontactsToDefaults()

        for cID in contactIDs {
            if let idx = contacts.firstIndex(where: { $0.id == cID }) {
                contacts[idx].metacontactID = meta.id
            }
        }
        saveContactsToDefaults()
        return meta
    }

    /// Removes a contact from whichever metacontact currently references it (if any),
    /// dissolving that metacontact if it would be left with fewer than 2 members.
    private func detachContactFromExistingMetacontact(_ contactID: UUID) {
        guard let idx = metacontacts.firstIndex(where: { $0.contactIDs.contains(contactID) }) else { return }
        metacontacts[idx].contactIDs.removeAll(where: { $0 == contactID })
        if metacontacts[idx].primaryContactID == contactID {
            metacontacts[idx].primaryContactID = metacontacts[idx].contactIDs.first
        }
        if metacontacts[idx].contactIDs.count < 2 {
            if let remainingID = metacontacts[idx].contactIDs.first,
               let cIdx = contacts.firstIndex(where: { $0.id == remainingID }) {
                contacts[cIdx].metacontactID = nil
            }
            metacontacts.remove(at: idx)
        }
    }
    
    public func unlinkMetacontact(_ metacontactID: UUID) {
        metacontacts.removeAll(where: { $0.id == metacontactID })
        saveMetacontactsToDefaults()
        
        for idx in contacts.indices {
            if contacts[idx].metacontactID == metacontactID {
                contacts[idx].metacontactID = nil
            }
        }
        saveContactsToDefaults()
    }
    
    public func setPrimaryContact(contactID: UUID, inMetacontact metacontactID: UUID) {
        if let idx = metacontacts.firstIndex(where: { $0.id == metacontactID }) {
            metacontacts[idx].primaryContactID = contactID
            saveMetacontactsToDefaults()
        }
    }
    
    public func addContactToMetacontact(contactID: UUID, metacontactID: UUID) {
        if let idx = metacontacts.firstIndex(where: { $0.id == metacontactID }) {
            if !metacontacts[idx].contactIDs.contains(contactID) {
                metacontacts[idx].contactIDs.append(contactID)
                saveMetacontactsToDefaults()
            }
        }
        if let cIdx = contacts.firstIndex(where: { $0.id == contactID }) {
            contacts[cIdx].metacontactID = metacontactID
            saveContactsToDefaults()
        }
    }
    
    public func removeContactFromMetacontact(contactID: UUID, metacontactID: UUID) {
        if let idx = metacontacts.firstIndex(where: { $0.id == metacontactID }) {
            metacontacts[idx].contactIDs.removeAll(where: { $0 == contactID })
            if metacontacts[idx].primaryContactID == contactID {
                metacontacts[idx].primaryContactID = metacontacts[idx].contactIDs.first
            }
            if metacontacts[idx].contactIDs.isEmpty {
                metacontacts.remove(at: idx)
            }
            saveMetacontactsToDefaults()
        }
        if let cIdx = contacts.firstIndex(where: { $0.id == contactID }) {
            contacts[cIdx].metacontactID = nil
            saveContactsToDefaults()
        }
    }

    // MARK: - Contact Operations (Alias, Block, Avatar)
    
    public func saveContactsToDefaults() {
        if let encoded = try? JSONEncoder().encode(contacts) {
            UserDefaults.standard.set(encoded, forKey: savedContactsKey)
        }
    }
    
    public func restoreSavedContacts() {
        if let data = UserDefaults.standard.data(forKey: savedContactsKey),
           let saved = try? JSONDecoder().decode([Contact].self, from: data) {
            self.contacts = saved
        }
    }
    
    public func setAlias(_ alias: String?, for contactID: UUID) {
        if let idx = contacts.firstIndex(where: { $0.id == contactID }) {
            contacts[idx].alias = alias?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true ? nil : alias
            saveContactsToDefaults()
        }
    }
    
    public func toggleBlockContact(_ contactID: UUID) {
        if let idx = contacts.firstIndex(where: { $0.id == contactID }) {
            contacts[idx].isBlocked.toggle()
            saveContactsToDefaults()

            if isLibpurpleLoaded {
                let contact = contacts[idx]
                let account = resolveAccount(for: contact)
                if let account = account {
                    if contact.isBlocked {
                        _ = adium_purple_block_contact(account.username, contact.accountProtocol.purpleProtocolID, contact.handle)
                    } else {
                        _ = adium_purple_unblock_contact(account.username, contact.accountProtocol.purpleProtocolID, contact.handle)
                    }
                }
            }
        }
    }
    
    public func setAvatar(data: Data?, for contactID: UUID) {
        if let idx = contacts.firstIndex(where: { $0.id == contactID }) {
            contacts[idx].avatarData = data
            saveContactsToDefaults()
        }
    }
    
    // MARK: - Account Operations & Options

    /// Resolves the account that owns a contact: prefer an exact match on
    /// accountUsername + protocol; fall back to a protocol-only match only when the
    /// contact has no recorded accountUsername. Never guesses across accounts that
    /// disagree with a recorded accountUsername, since that would route messages/files
    /// to the wrong account.
    func resolveAccount(for contact: Contact) -> Account? {
        if let username = contact.accountUsername {
            return accounts.first(where: { $0.username == username && $0.accountProtocol == contact.accountProtocol })
        }
        return accounts.first(where: { $0.accountProtocol == contact.accountProtocol })
    }

    public func applyAccountOptions(_ account: Account) {
        guard isLibpurpleLoaded else { return }
        let username = account.username
        let protoID = account.accountProtocol.purpleProtocolID
        
        if let server = account.server, !server.isEmpty {
            _ = adium_purple_set_account_option(username, protoID, "server", server)
            _ = adium_purple_set_account_option(username, protoID, "connect_server", server)
        }
        if let port = account.port {
            _ = adium_purple_set_account_int_option(username, protoID, "port", Int32(port))
        }
        if let resource = account.resource, !resource.isEmpty {
            _ = adium_purple_set_account_option(username, protoID, "resource", resource)
        }
        if let useSSL = account.useSSL {
            // "require_tls" is only meaningful to the XMPP prpl; other protocols either
            // always negotiate TLS themselves or don't expose a comparable toggle, so
            // forwarding it there would just create a dead account option.
            if account.accountProtocol == .xmpp {
                _ = adium_purple_set_account_bool_option(username, protoID, "require_tls", useSSL)
            }
        }
        for (key, val) in account.customOptions {
            _ = adium_purple_set_account_option(username, protoID, key, val)
        }
    }
    
    public func updateAccountOptions(
        accountID: UUID,
        server: String?,
        port: Int?,
        resource: String?,
        useSSL: Bool?,
        customOptions: [String: String]
    ) {
        if let idx = accounts.firstIndex(where: { $0.id == accountID }) {
            accounts[idx].server = server
            accounts[idx].port = port
            accounts[idx].resource = resource
            accounts[idx].useSSL = useSSL
            accounts[idx].customOptions = customOptions
            saveAccountsToDefaults()
            
            applyAccountOptions(accounts[idx])
        }
    }
    
    /// Connect a new account via libpurple (e.g. Teams, XMPP)
    public func connectAccount(username: String, protocolType: AccountProtocol, password: String, server: String? = nil, port: Int? = nil, resource: String? = nil, useSSL: Bool? = nil) {
        let accountKey = "\(username):\(protocolType.purpleProtocolID)"
        if !password.isEmpty {
            KeychainHelper.savePassword(password, for: accountKey)
        }
        
        if !accounts.contains(where: { $0.username == username && $0.accountProtocol == protocolType }) {
            let newAccount = Account(
                username: username,
                accountProtocol: protocolType,
                isConnected: false,
                server: server,
                port: port,
                resource: resource,
                useSSL: useSSL
            )
            self.accounts.append(newAccount)
            saveAccountsToDefaults()
        }
        
        if isLibpurpleLoaded {
            let fetchedPassword = password.isEmpty ? (KeychainHelper.fetchPassword(for: accountKey) ?? "") : password
            // Add the account before applying options: do_set_account_option looks the
            // account up via purple_accounts_find(), which returns NULL (dropping the
            // options silently) until do_add_account has run.
            _ = adium_purple_add_account(username, protocolType.purpleProtocolID, fetchedPassword)
            if let acc = accounts.first(where: { $0.username == username && $0.accountProtocol == protocolType }) {
                applyAccountOptions(acc)
            }
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
        saveContactsToDefaults()
        
        if isLibpurpleLoaded {
            // Purge every protocol-ID variant this account may be persisted under in
            // accounts.xml, including retired IDs ("prpl-teams"): removing only the current
            // ID leaves a stale entry behind that the legacy import could resurrect.
            var idsToRemove = Set(
                Self.importableProtocolIDs.filter { $0.value == account.accountProtocol }.map(\.key)
            )
            idsToRemove.insert(account.accountProtocol.purpleProtocolID)
            for protocolID in idsToRemove {
                _ = adium_purple_remove_account(account.username, protocolID)
            }
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
        
        adium_purple_set_extended_event_callbacks(
            PurpleBridgeService.handleRequestInputCallback,
            PurpleBridgeService.handleRequestActionCallback,
            PurpleBridgeService.handleRequestCloseCallback,
            PurpleBridgeService.handleConnectionProgressCallback,
            PurpleBridgeService.handleTypingCallback,
            PurpleBridgeService.handleBuddyRemovedCallback
        )

        adium_purple_set_chat_callbacks(
            PurpleBridgeService.handleChatJoinedCallback,
            PurpleBridgeService.handleChatLeftCallback,
            PurpleBridgeService.handleChatMessageCallback,
            PurpleBridgeService.handleChatBuddyJoinedCallback,
            PurpleBridgeService.handleChatBuddyLeftCallback
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
            
            // Re-connect saved accounts with passwords from Keychain. Add the account
            // before applying options — see the note in connectAccount().
            for acc in accounts {
                let accountKey = "\(acc.username):\(acc.accountProtocol.purpleProtocolID)"
                let password = KeychainHelper.fetchPassword(for: accountKey) ?? ""
                _ = adium_purple_add_account(acc.username, acc.accountProtocol.purpleProtocolID, password)
                applyAccountOptions(acc)
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
    
    // MARK: - Tabbed Messaging Operations
    
    public func openTab(for contactID: UUID) {
        if !openTabIDs.contains(contactID) {
            openTabIDs.append(contactID)
        }
        activeTabID = contactID
        markAsRead(for: contactID)
    }
    
    public func closeTab(_ contactID: UUID) {
        openTabIDs.removeAll(where: { $0 == contactID })
        if activeTabID == contactID {
            activeTabID = openTabIDs.last
        }
    }
    
    public func setActiveTab(_ contactID: UUID?) {
        self.activeTabID = contactID
        if let id = contactID {
            if !openTabIDs.contains(id) {
                openTabIDs.append(id)
            }
            markAsRead(for: id)
        }
    }
    
    public func markAsRead(for contactID: UUID) {
        unreadCounts[contactID] = 0
        let totalUnread = unreadCounts.values.reduce(0, +)
        EventManager.shared.setUnreadCount(totalUnread)
    }
    
    // MARK: - Group Chat (MUC) Operations
    
    @discardableResult
    public func joinGroupChat(channelName: String, account: Account, topic: String? = nil) -> Contact {
        let trimmedName = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = contacts.first(where: { $0.isGroupChat && $0.name.caseInsensitiveCompare(trimmedName) == .orderedSame && $0.accountProtocol == account.accountProtocol }) {
            openTab(for: existing.id)
            return existing
        }
        
        let selfParticipant = GroupParticipant(
            name: account.username,
            handle: account.username,
            status: .available,
            role: "Propietario"
        )
        
        let groupContact = Contact(
            name: trimmedName,
            handle: trimmedName,
            status: .available,
            customStatusMessage: topic ?? "Grupo / Canal",
            group: "Grupos",
            accountProtocol: account.accountProtocol,
            accountUsername: account.username,
            isGroupChat: true,
            groupParticipants: [selfParticipant],
            topic: topic
        )
        
        createGroup(name: "Grupos")
        contacts.append(groupContact)
        saveContactsToDefaults()
        openTab(for: groupContact.id)

        if isLibpurpleLoaded {
            _ = adium_purple_join_chat(account.username, account.accountProtocol.purpleProtocolID, trimmedName)
        }

        return groupContact
    }
    
    public func leaveGroupChat(_ contactID: UUID) {
        closeTab(contactID)
        contacts.removeAll(where: { $0.id == contactID && $0.isGroupChat })
        saveContactsToDefaults()
    }
    
    public func addGroupParticipant(contactID: UUID, participant: GroupParticipant) {
        if let idx = contacts.firstIndex(where: { $0.id == contactID }) {
            if !contacts[idx].groupParticipants.contains(where: { $0.handle == participant.handle }) {
                contacts[idx].groupParticipants.append(participant)
                saveContactsToDefaults()
            }
        }
    }
    
    public func removeGroupParticipant(contactID: UUID, participantHandle: String) {
        if let idx = contacts.firstIndex(where: { $0.id == contactID }) {
            contacts[idx].groupParticipants.removeAll(where: { $0.handle == participantHandle })
            saveContactsToDefaults()
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
        if contact.isBlocked {
            connectionState = "No se puede enviar: \(contact.displayName) esta bloqueado"
            return
        }

        let account = resolveAccount(for: contact)
        if isLibpurpleLoaded && account == nil {
            connectionState = "No se pudo enviar mensaje: no se encontro una cuenta para \(contact.displayName)"
            return
        }

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

        EventManager.shared.triggerEvent(.messageSent, title: "Me", content: text, contactID: contact.id)

        if isLibpurpleLoaded, let account = account {
            if contact.isGroupChat {
                _ = adium_purple_send_chat_message(account.username, contact.accountProtocol.purpleProtocolID, contact.handle, text)
            } else {
                _ = adium_purple_send_message(account.username, contact.accountProtocol.purpleProtocolID, contact.handle, text)
            }
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
        
        createGroup(name: group)
        
        let proto = AccountProtocol.allCases.first(where: { $0.purpleProtocolID == protocolId }) ?? .teams
        let matchingAccount = accounts.first(where: { $0.accountProtocol == proto })
        
        if let idx = contacts.firstIndex(where: { $0.handle == handle }) {
            let oldStatus = contacts[idx].status
            contacts[idx].name = name
            contacts[idx].status = parsedStatus
            contacts[idx].customStatusMessage = statusName
            if contacts[idx].accountUsername == nil {
                contacts[idx].accountUsername = matchingAccount?.username
            }
            
            if oldStatus == .offline && parsedStatus != .offline {
                EventManager.shared.triggerEvent(.contactOnline, title: contacts[idx].displayName, content: "Está conectado", contactID: contacts[idx].id)
            } else if oldStatus != .offline && parsedStatus == .offline {
                EventManager.shared.triggerEvent(.contactOffline, title: contacts[idx].displayName, content: "Se ha desconectado", contactID: contacts[idx].id)
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
            if parsedStatus != .offline {
                EventManager.shared.triggerEvent(.contactOnline, title: newContact.displayName, content: "Está conectado", contactID: newContact.id)
            }
        }
        saveContactsToDefaults()
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
            saveContactsToDefaults()
            contact = newContact
        }
        
        guard let c = contact else { return }

        // Drop messages from blocked contacts entirely: no log entry, no chat history,
        // no event.
        if !isFromMe && c.isBlocked {
            return
        }

        let senderName = isFromMe ? "Me" : c.displayName
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
            if activeTabID != c.id {
                unreadCounts[c.id, default: 0] += 1
                let totalUnread = unreadCounts.values.reduce(0, +)
                EventManager.shared.setUnreadCount(totalUnread)
            }
            EventManager.shared.triggerEvent(.messageReceived, title: c.displayName, content: text, contactID: c.id)
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

    // MARK: - Group Chat (MUC) Live Events

    func onChatJoined(roomName: String, username: String, protocolId: String) {
        let proto = AccountProtocol.allCases.first(where: { $0.purpleProtocolID == protocolId })
        // libpurple/the prpl may normalize the room name we asked to join (e.g. XMPP MUC
        // JIDs); reconcile our optimistically-created Contact's handle to whatever
        // libpurple actually settled on, so incoming chat messages (tagged with that
        // handle) route back to it.
        if let idx = contacts.firstIndex(where: {
            $0.isGroupChat && $0.accountUsername == username && (proto == nil || $0.accountProtocol == proto)
                && $0.handle != roomName && (roomName.hasPrefix($0.handle) || $0.handle.hasPrefix(roomName))
        }) {
            contacts[idx].handle = roomName
            saveContactsToDefaults()
        } else if !contacts.contains(where: { $0.isGroupChat && $0.handle == roomName }) {
            let newContact = Contact(
                name: roomName,
                handle: roomName,
                status: .available,
                customStatusMessage: "Grupo / Canal",
                group: "Grupos",
                accountProtocol: proto ?? .teams,
                accountUsername: username,
                isGroupChat: true
            )
            createGroup(name: "Grupos")
            contacts.append(newContact)
            saveContactsToDefaults()
        }
    }

    func onChatLeft(roomName: String, username: String, protocolId: String) {
        // leaveGroupChat() already removes the local Contact when the user explicitly
        // leaves; this fires for the libpurple side of that (or if the server kicked us),
        // and there's no separate "kicked" UI surface to update yet.
    }

    func onChatMessage(roomName: String, sender: String, text: String, isFromMe: Bool) {
        guard let c = contacts.first(where: { $0.isGroupChat && $0.handle == roomName }) else { return }
        if !isFromMe && c.isBlocked { return }

        let senderName = isFromMe ? "Me" : (sender.isEmpty ? c.displayName : sender)
        let newMsg = ChatMessage(senderName: senderName, isFromMe: isFromMe, text: text)

        if messagesPerContact[c.id] != nil {
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
            if activeTabID != c.id {
                unreadCounts[c.id, default: 0] += 1
                let totalUnread = unreadCounts.values.reduce(0, +)
                EventManager.shared.setUnreadCount(totalUnread)
            }
            EventManager.shared.triggerEvent(.messageReceived, title: c.displayName, content: "\(senderName): \(text)", contactID: c.id)
        }
    }

    /// Fired for each occupant of a joined chat (both the initial roster, where
    /// `newArrival` is false, and later real joins, where it's true). Matches the room the
    /// same way onChatMessage does -- by handle -- and dedupes by participant handle.
    func onChatBuddyJoined(roomName: String, buddyName: String, newArrival: Bool) {
        guard let idx = contacts.firstIndex(where: { $0.isGroupChat && $0.handle == roomName }) else { return }
        guard !contacts[idx].groupParticipants.contains(where: { $0.handle == buddyName }) else { return }
        let participant = GroupParticipant(name: buddyName, handle: buddyName, status: .available)
        contacts[idx].groupParticipants.append(participant)
        saveContactsToDefaults()
    }

    func onChatBuddyLeft(roomName: String, buddyName: String) {
        guard let idx = contacts.firstIndex(where: { $0.isGroupChat && $0.handle == roomName }) else { return }
        contacts[idx].groupParticipants.removeAll(where: { $0.handle == buddyName })
        saveContactsToDefaults()
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
    
    func onTypingStateChanged(handle: String, isTyping: Bool) {
        if let idx = contacts.firstIndex(where: { $0.handle == handle }) {
            contacts[idx].isTyping = isTyping
        }
    }
    
    func onBuddyRemoved(handle: String) {
        contacts.removeAll(where: { $0.handle == handle })
        saveContactsToDefaults()
    }
    
    func onConnectionProgress(username: String, protocolId: String, text: String, step: Int, stepCount: Int) {
        self.connectionState = "\(username): \(text) (\(step)/\(stepCount))"
    }
    
    func onRequestInput(requestHandle: RequestHandleWrapper, title: String, primary: String, secondary: String, defaultValue: String, masked: Bool, hint: String) {
        let addr = UInt(bitPattern: requestHandle.rawPointer)
        pendingRequestAddrs.insert(addr)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = primary.isEmpty ? title : primary
        if !secondary.isEmpty {
            alert.informativeText = secondary
        }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancelar")

        let field: NSTextField = masked ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)) : NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        // Modal is acceptable here: PurpleBridgeService is @MainActor and libpurple runs
        // its own thread, so blocking the main thread on this alert doesn't stall network
        // I/O — only other UI interaction, same as any other app-modal dialog.
        let response = alert.runModal()

        // libpurple may have already closed this request out from under the alert (e.g.
        // account disconnected while the user was looking at it); if so, drop the response.
        guard pendingRequestAddrs.remove(addr) != nil else { return }

        if response == .alertFirstButtonReturn {
            adium_purple_request_input_respond(requestHandle.rawPointer, field.stringValue, true)
        } else {
            adium_purple_request_input_respond(requestHandle.rawPointer, nil, false)
        }
    }

    func onRequestAction(requestHandle: RequestHandleWrapper, title: String, primary: String, secondary: String, defaultAction: Int32, actionTitles: [String]) {
        let addr = UInt(bitPattern: requestHandle.rawPointer)
        pendingRequestAddrs.insert(addr)

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = primary.isEmpty ? title : primary
        if !secondary.isEmpty {
            alert.informativeText = secondary
        }
        if actionTitles.isEmpty {
            alert.addButton(withTitle: "OK")
        } else {
            for actionTitle in actionTitles {
                alert.addButton(withTitle: actionTitle)
            }
        }

        let response = alert.runModal()

        guard pendingRequestAddrs.remove(addr) != nil else { return }

        let chosenIdx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        let fallbackIdx = defaultAction >= 0 ? Int(defaultAction) : 0
        let actionIdx = (chosenIdx >= 0 && chosenIdx < actionTitles.count) ? chosenIdx : fallbackIdx
        adium_purple_request_action_respond(requestHandle.rawPointer, Int32(actionIdx))
    }

    func onRequestClose(requestHandle: RequestHandleWrapper) {
        let addr = UInt(bitPattern: requestHandle.rawPointer)
        pendingRequestAddrs.remove(addr)
    }
    
    // MARK: - Extended C Callback Definitions
    
    private static let handleRequestInputCallback: adium_purple_on_request_input_cb = { requestHandle, title, primary, secondary, defaultValue, masked, hint in
        guard let requestHandle = requestHandle else { return }
        let handleAddr = UInt(bitPattern: requestHandle)
        let tStr = title != nil ? String(cString: title!) : ""
        let pStr = primary != nil ? String(cString: primary!) : ""
        let sStr = secondary != nil ? String(cString: secondary!) : ""
        let dStr = defaultValue != nil ? String(cString: defaultValue!) : ""
        let hStr = hint != nil ? String(cString: hint!) : ""
        
        DispatchQueue.main.async {
            if let ptr = UnsafeMutableRawPointer(bitPattern: handleAddr) {
                let handleWrapper = RequestHandleWrapper(ptr)
                PurpleBridgeService.shared.onRequestInput(requestHandle: handleWrapper, title: tStr, primary: pStr, secondary: sStr, defaultValue: dStr, masked: masked, hint: hStr)
            }
        }
    }
    
    private static let handleRequestActionCallback: adium_purple_on_request_action_cb = { requestHandle, title, primary, secondary, defaultAction, actionTitles, actionCount in
        guard let requestHandle = requestHandle else { return }
        let handleAddr = UInt(bitPattern: requestHandle)
        let tStr = title != nil ? String(cString: title!) : ""
        let pStr = primary != nil ? String(cString: primary!) : ""
        let sStr = secondary != nil ? String(cString: secondary!) : ""
        
        var titles: [String] = []
        if let actionTitles = actionTitles {
            for i in 0..<Int(actionCount) {
                if let t = actionTitles[i] {
                    titles.append(String(cString: t))
                }
            }
        }
        
        DispatchQueue.main.async {
            if let ptr = UnsafeMutableRawPointer(bitPattern: handleAddr) {
                let handleWrapper = RequestHandleWrapper(ptr)
                PurpleBridgeService.shared.onRequestAction(requestHandle: handleWrapper, title: tStr, primary: pStr, secondary: sStr, defaultAction: defaultAction, actionTitles: titles)
            }
        }
    }
    
    private static let handleRequestCloseCallback: adium_purple_on_request_close_cb = { requestHandle in
        guard let requestHandle = requestHandle else { return }
        let handleAddr = UInt(bitPattern: requestHandle)
        DispatchQueue.main.async {
            if let ptr = UnsafeMutableRawPointer(bitPattern: handleAddr) {
                let handleWrapper = RequestHandleWrapper(ptr)
                PurpleBridgeService.shared.onRequestClose(requestHandle: handleWrapper)
            }
        }
    }
    
    private static let handleConnectionProgressCallback: adium_purple_on_connection_progress_cb = { username, protocolId, text, step, stepCount in
        guard let username = username, let protocolId = protocolId, let text = text else { return }
        let uStr = String(cString: username)
        let pStr = String(cString: protocolId)
        let tStr = String(cString: text)
        let s = Int(step)
        let sc = Int(stepCount)
        
        DispatchQueue.main.async {
            PurpleBridgeService.shared.onConnectionProgress(username: uStr, protocolId: pStr, text: tStr, step: s, stepCount: sc)
        }
    }
    
    private static let handleTypingCallback: adium_purple_on_typing_cb = { handle, isTyping in
        guard let handle = handle else { return }
        let hStr = String(cString: handle)
        
        DispatchQueue.main.async {
            PurpleBridgeService.shared.onTypingStateChanged(handle: hStr, isTyping: isTyping)
        }
    }
    
    private static let handleBuddyRemovedCallback: adium_purple_on_buddy_removed_cb = { handle in
        guard let handle = handle else { return }
        let hStr = String(cString: handle)

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onBuddyRemoved(handle: hStr)
        }
    }

    private static let handleChatJoinedCallback: adium_purple_on_chat_joined_cb = { roomName, username, protocolId in
        guard let roomName = roomName, let username = username, let protocolId = protocolId else { return }
        let rStr = String(cString: roomName)
        let uStr = String(cString: username)
        let pStr = String(cString: protocolId)

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onChatJoined(roomName: rStr, username: uStr, protocolId: pStr)
        }
    }

    private static let handleChatLeftCallback: adium_purple_on_chat_left_cb = { roomName, username, protocolId in
        guard let roomName = roomName, let username = username, let protocolId = protocolId else { return }
        let rStr = String(cString: roomName)
        let uStr = String(cString: username)
        let pStr = String(cString: protocolId)

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onChatLeft(roomName: rStr, username: uStr, protocolId: pStr)
        }
    }

    private static let handleChatMessageCallback: adium_purple_on_chat_message_cb = { roomName, sender, messageText, isFromMe in
        guard let roomName = roomName, let messageText = messageText else { return }
        let rStr = String(cString: roomName)
        let sStr = sender != nil ? String(cString: sender!) : ""
        let mStr = String(cString: messageText)

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onChatMessage(roomName: rStr, sender: sStr, text: mStr, isFromMe: isFromMe)
        }
    }

    private static let handleChatBuddyJoinedCallback: adium_purple_on_chat_buddy_joined_cb = { roomName, buddyName, newArrival in
        guard let roomName = roomName, let buddyName = buddyName else { return }
        let rStr = String(cString: roomName)
        let bStr = String(cString: buddyName)

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onChatBuddyJoined(roomName: rStr, buddyName: bStr, newArrival: newArrival)
        }
    }

    private static let handleChatBuddyLeftCallback: adium_purple_on_chat_buddy_left_cb = { roomName, buddyName in
        guard let roomName = roomName, let buddyName = buddyName else { return }
        let rStr = String(cString: roomName)
        let bStr = String(cString: buddyName)

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onChatBuddyLeft(roomName: rStr, buddyName: bStr)
        }
    }
}

public struct RequestHandleWrapper: @unchecked Sendable {
    public let rawPointer: UnsafeMutableRawPointer
    public init(_ rawPointer: UnsafeMutableRawPointer) {
        self.rawPointer = rawPointer
    }
}
