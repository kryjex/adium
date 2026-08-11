import Foundation
import CLibpurple
import AppKit

/// This service coordinates messaging protocols.
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
    public var connectionState: String = t("No accounts")
    public var myStatus: OnlineStatus = .available
    /// This text shows a custom status.
    /// The system saves this in UserDefaults.
    /// The system applies this to libpurple when the status changes.
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

    /// This contains addresses of active libpurple request handles.
    /// The UI shows these requests as an NSAlert.
    /// onRequestClose removes these addresses.
    /// This stops a queued response from firing into a bad handle.
    private var pendingRequestAddrs: Set<UInt> = []


    /// This shows if an account has a connection error.
    public var hasAccountError: Bool {
        accounts.contains(where: { !$0.isConnected && $0.connectionError != nil })
    }
    
    /// This provides an error summary for disconnected accounts.
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

    /// This sets the user status in the bridge and libpurple.
    /// This includes the custom status message.
    public func setUserStatus(_ status: OnlineStatus) {
        self.myStatus = status
        if isLibpurpleLoaded {
            _ = adium_purple_set_user_status(purpleStatusId(for: status), myStatusMessage)
        }
    }

    /// This updates the custom status message.
    /// This applies the new message and current status to libpurple.
    /// The system saves this to UserDefaults.
    public func setStatusMessage(_ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.myStatusMessage = trimmed
        UserDefaults.standard.set(trimmed, forKey: savedStatusMessageKey)
        if isLibpurpleLoaded {
            _ = adium_purple_set_user_status(purpleStatusId(for: myStatus), trimmed)
        }
    }
    
    /// This reconnects all accounts.
    public func reconnectAccounts() {
        self.connectionState = t("Reconnecting accounts...")
        for i in 0..<accounts.count {
            accounts[i].connectionError = nil
        }
        if isLibpurpleLoaded {
            for acc in accounts {
                let accountKey = "\(acc.username):\(acc.accountProtocol.purpleProtocolID)"
                let password = KeychainHelper.fetchPassword(for: accountKey) ?? ""
                // You must apply options after the account exists in libpurple.
                // The two calls go through g_idle_add in order.
                // The do_set_account_option function will fail if applied first.
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
    
    /// This saves accounts metadata to UserDefaults.
    private func saveAccountsToDefaults() {
        if let encoded = try? JSONEncoder().encode(accounts) {
            UserDefaults.standard.set(encoded, forKey: savedAccountsKey)
        }
    }
    
    /// This restores accounts metadata from UserDefaults.
    /// Usernames saved by older builds normalize on load.
    /// The Keychain entry moves to the new key when the username changes.
    public func restoreSavedAccounts() {
        if let data = UserDefaults.standard.data(forKey: savedAccountsKey),
           let saved = try? JSONDecoder().decode([Account].self, from: data) {
            var migrated = saved
            var changed = false
            for idx in migrated.indices {
                let canonical = migrated[idx].accountProtocol.canonicalUsername(migrated[idx].username)
                guard canonical != migrated[idx].username else { continue }
                let protoID = migrated[idx].accountProtocol.purpleProtocolID
                let oldKey = "\(migrated[idx].username):\(protoID)"
                let newKey = "\(canonical):\(protoID)"
                if let password = KeychainHelper.fetchPassword(for: oldKey) {
                    KeychainHelper.savePassword(password, for: newKey)
                    KeychainHelper.deletePassword(for: oldKey)
                }
                migrated[idx].username = canonical
                changed = true
            }
            self.accounts = migrated
            if changed {
                saveAccountsToDefaults()
            }
        }
        // This imports from libpurple only on the first run.
        // Re-importing restores deleted accounts from old accounts.xml entries.
        if accounts.isEmpty,
           UserDefaults.standard.data(forKey: savedAccountsKey) == nil,
           !UserDefaults.standard.bool(forKey: legacyImportDoneKey) {
            importAccountsFromLibpurple()
        }
    }

    /// These are libpurple protocol IDs that map to an AccountProtocol.
    /// These include old IDs from previous builds.
    nonisolated static let importableProtocolIDs: [String: AccountProtocol] = [
        "prpl-eionrobb-msteams": .teams,
        "prpl-teams": .teams,
        "prpl-hehoe-whatsmeow": .whatsapp,
        "prpl-adium-whatsapp": .whatsapp,
        "prpl-jabber": .xmpp,
        "prpl-matrix": .matrix
    ]

    /// This imports accounts from accounts.xml one time.
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

    /// This parses the account entries in accounts.xml.
    /// This keeps only the protocols that map.
    nonisolated static func parsePurpleAccountsXML(_ xml: String) -> [Account] {
        var result: [Account] = []
        for block in xml.components(separatedBy: "</account>") {
            guard let protocolID = firstTagContent("protocol", in: block),
                  let name = firstTagContent("name", in: block),
                  let mapped = importableProtocolIDs[protocolID],
                  !name.isEmpty else { continue }
            let canonical = mapped.canonicalUsername(name)
            if !result.contains(where: { $0.username == canonical && $0.accountProtocol == mapped }) {
                result.append(Account(username: canonical, accountProtocol: mapped))
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
        // The default group names localize once at creation time.
        // After that, they are user data and follow renames, not the locale.
        if contactGroups.isEmpty {
            self.contactGroups = [
                ContactGroup(name: "General", isExpanded: true),
                ContactGroup(name: t("Work"), isExpanded: true),
                ContactGroup(name: t("Friends"), isExpanded: true)
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
        // Do not create a second group with an existing name.
        // Two ContactGroup entries with the same name cause errors in the UI.
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

        // A contact can belong to a different metacontact.
        // The code detaches the contact from the old metacontact first.
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

    /// This removes a contact from a metacontact.
    /// This deletes the metacontact if it has fewer than 2 members.
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
            // The plugin filters out WhatsApp channel and story chats.
            // The code drops chats that were saved before the filter existed.
            let filtered = saved.filter {
                !$0.handle.hasSuffix("@newsletter") && $0.handle != "status@broadcast"
            }
            self.contacts = Self.dedupeContactsByHandle(filtered)
            if self.contacts.count != saved.count {
                saveContactsToDefaults()
            }
        }
    }

    /// The system keys chat logs by handle.
    /// Two contacts with the same handle are the same conversation.
    /// This keeps the newest contact.
    /// This keeps user-set fields from the older contact.
    nonisolated static func dedupeContactsByHandle(_ contacts: [Contact]) -> [Contact] {
        var byHandle: [String: Contact] = [:]
        var order: [String] = []
        for contact in contacts {
            if var kept = byHandle[contact.handle] {
                // The new contact replaces the old contact.
                // The code preserves custom fields on the old contact.
                var newer = contact
                if newer.alias == nil { newer.alias = kept.alias }
                if newer.avatarData == nil { newer.avatarData = kept.avatarData }
                if newer.metacontactID == nil { newer.metacontactID = kept.metacontactID }
                newer.isBlocked = newer.isBlocked || kept.isBlocked
                kept = newer
                byHandle[contact.handle] = kept
            } else {
                byHandle[contact.handle] = contact
                order.append(contact.handle)
            }
        }
        return order.compactMap { byHandle[$0] }
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

    /// This finds the account for a contact.
    /// This uses the accountUsername and protocol to find the account.
    /// This falls back to protocol-only match if accountUsername is absent.
    /// This does not guess across accounts to prevent errors.
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
            // "require_tls" only works for XMPP.
            // Other protocols negotiate TLS automatically.
            if account.accountProtocol == .xmpp {
                _ = adium_purple_set_account_bool_option(username, protoID, "require_tls", useSSL)
            }
        }
        if account.accountProtocol == .whatsapp {
            // AnimatedImageView renders WebP itself; gdk-pixbuf often cannot.
            _ = adium_purple_set_account_bool_option(username, protoID, "inline-webp", true)
            // The contact filter in restoreSavedContacts assumes the plugin
            // drops channel (newsletter) chats.
            _ = adium_purple_set_account_bool_option(username, protoID, "ignore-newsletters", true)
        }
        if account.accountProtocol == .teams {
            // A fresh account has no last_message_timestamp, and the plugin
            // then fetches offline history "since now": the first login shows
            // no messages, and the self-chat (48:notes) has no other fetch
            // path. Zero makes the first sweep pull the last page of every
            // conversation regardless of age. Later logins keep the marker
            // the plugin maintains.
            _ = adium_purple_seed_account_int_option(username, protoID, "last_message_timestamp", 0)
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
    
    /// This connects a new account via libpurple.
    /// The username normalizes to the protocol's canonical form first.
    public func connectAccount(username rawUsername: String, protocolType: AccountProtocol, password: String, server: String? = nil, port: Int? = nil, resource: String? = nil, useSSL: Bool? = nil) {
        let username = protocolType.canonicalUsername(rawUsername)
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
            // This adds the account before it applies options.
            // do_set_account_option uses purple_accounts_find.
            // purple_accounts_find returns NULL until do_add_account runs.
            _ = adium_purple_add_account(username, protocolType.purpleProtocolID, fetchedPassword)
            if let acc = accounts.first(where: { $0.username == username && $0.accountProtocol == protocolType }) {
                applyAccountOptions(acc)
            }
            if let statusCStr = adium_purple_get_status_info() {
                self.connectionState = String(cString: statusCStr)
            }
        }
    }
    
    /// This removes an account and disconnects it from libpurple.
    /// Pass deleteChatLogs to also delete the saved transcripts of its contacts.
    public func removeAccount(_ account: Account, deleteChatLogs: Bool = false) {
        self.accounts.removeAll(where: { $0.id == account.id })
        saveAccountsToDefaults()

        let accountKey = "\(account.username):\(account.accountProtocol.purpleProtocolID)"
        KeychainHelper.deletePassword(for: accountKey)

        let removedContacts = self.contacts.filter { $0.accountProtocol == account.accountProtocol && ($0.accountUsername == nil || $0.accountUsername == account.username) }
        self.contacts.removeAll(where: { $0.accountProtocol == account.accountProtocol && ($0.accountUsername == nil || $0.accountUsername == account.username) })
        saveContactsToDefaults()

        if deleteChatLogs {
            let store = ChatLogStore.shared
            // Do not delete a log that a remaining contact (another account) still uses.
            let remainingHandles = Set(self.contacts.map { store.sanitizeHandle($0.handle) })
            for contact in removedContacts {
                messagesPerContact.removeValue(forKey: contact.id)
                let safeHandle = store.sanitizeHandle(contact.handle)
                if !remainingHandles.contains(safeHandle) {
                    store.deleteLog(for: contact.handle)
                }
                // Legacy logs keyed by contact UUID.
                store.deleteLog(for: contact.id.uuidString)
            }
        }
        
        if isLibpurpleLoaded {
            // This removes all protocol-ID variants from accounts.xml.
            // This prevents the legacy import from restoring old accounts.
            var idsToRemove = Set(
                Self.importableProtocolIDs.filter { $0.value == account.accountProtocol }.map(\.key)
            )
            idsToRemove.insert(account.accountProtocol.purpleProtocolID)
            for protocolID in idsToRemove {
                _ = adium_purple_remove_account(account.username, protocolID)
            }
        }
        
        if accounts.isEmpty {
            self.connectionState = t("No accounts")
        }
    }
    
    /// This finds all libpurple plugin .so files in the app paths.
    private func discoverPluginPaths() -> [String] {
        var foundPlugins: [String: String] = [:] // filename -> full path
        let fileManager = FileManager.default

        // 1. Find in App Bundle Contents/PlugIns directory.
        let bundlePlugInsDir = Bundle.main.bundlePath + "/Contents/PlugIns"
        if fileManager.fileExists(atPath: bundlePlugInsDir),
           let contents = try? fileManager.contentsOfDirectory(atPath: bundlePlugInsDir) {
            for file in contents where file.hasSuffix(".so") {
                let fullPath = (bundlePlugInsDir as NSString).appendingPathComponent(file)
                foundPlugins[file] = fullPath
            }
        }

        // 2. Find in Development Plugins directory.
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

        // 3. Find in the user plugins directory (~/.adium-swift/plugins).
        // Installed-by-user plugins land here, outside the app bundle.
        let userPluginsDir = PluginManager.userPluginsDirectory.path
        if fileManager.fileExists(atPath: userPluginsDir),
           let contents = try? fileManager.contentsOfDirectory(atPath: userPluginsDir) {
            for file in contents where file.hasSuffix(".so") {
                if foundPlugins[file] == nil {
                    let fullPath = (userPluginsDir as NSString).appendingPathComponent(file)
                    foundPlugins[file] = fullPath
                }
            }
        }

        return Array(foundPlugins.values)
    }

    /// This initializes the libpurple C core and loads dynamic plugins.
    public func initializeLibpurpleCore() {
        let pluginsSearchDir = Bundle.main.bundlePath + "/Contents/PlugIns"
        let userHome = FileManager.default.homeDirectoryForCurrentUser.path
        let userDir = userHome + "/.adium-swift"
        
        // 1. Set event callbacks from C to Swift.
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
            PurpleBridgeService.handleBuddyRemovedCallback,
            PurpleBridgeService.handleNotifyMessageCallback
        )

        adium_purple_set_chat_callbacks(
            PurpleBridgeService.handleChatJoinedCallback,
            PurpleBridgeService.handleChatLeftCallback,
            PurpleBridgeService.handleChatMessageCallback,
            PurpleBridgeService.handleChatBuddyJoinedCallback,
            PurpleBridgeService.handleChatBuddyLeftCallback,
            PurpleBridgeService.handleChatListedCallback,
            PurpleBridgeService.handleChatUnlistedCallback
        )

        // 2. Initialize libpurple core.
        let success = adium_purple_init(pluginsSearchDir, userDir)
        
        if success {
            self.isLibpurpleLoaded = true
            
            // Start GLib background socket event loop.
            adium_purple_start_event_loop()
            
            // This finds and loads all available plugin .so files.
            // A plugin the user disabled stays on disk but does not load:
            // the disable flow cannot unload a live libpurple 2 plugin, so it
            // applies at the next launch instead.
            let discoveredPlugins = discoverPluginPaths()
            PluginManager.shared.refreshInstalled(discoveredPaths: discoveredPlugins)
            var loadedPluginNames: [String] = []
            for pluginPath in discoveredPlugins {
                let pluginFileName = (pluginPath as NSString).lastPathComponent
                if PluginManager.shared.isDisabled(filename: pluginFileName) {
                    continue
                }
                _ = adium_purple_load_plugin(pluginPath)
                loadedPluginNames.append(pluginFileName)
            }
            if !loadedPluginNames.isEmpty {
                self.activePluginName = loadedPluginNames.joined(separator: ", ")
            }
            
            // This reconnects saved accounts with passwords from Keychain.
            // This adds the account before it applies options.
            for acc in accounts {
                let accountKey = "\(acc.username):\(acc.accountProtocol.purpleProtocolID)"
                let password = KeychainHelper.fetchPassword(for: accountKey) ?? ""
                _ = adium_purple_add_account(acc.username, acc.accountProtocol.purpleProtocolID, password)
                applyAccountOptions(acc)
            }
            
            // This emits loaded accounts and buddies from libpurple.
            adium_purple_load_accounts()
            
            if let statusCStr = adium_purple_get_status_info() {
                self.connectionState = String(cString: statusCStr)
            } else {
                self.connectionState = t("Active (\(self.activePluginName))")
            }
        } else {
            self.connectionState = t("Libpurple initialization error")
        }
    }
    
    // MARK: - Tabbed Messaging Operations
    
    public func openTab(for contactID: UUID) {
        if !openTabIDs.contains(contactID) {
            openTabIDs.append(contactID)
        }
        activeTabID = contactID
        markAsRead(for: contactID)
        ensureGroupChatJoined(contactID)
    }

    /// Listed chats have no libpurple conversation until they join.
    /// Joining loads the roster and the recent history.
    private func ensureGroupChatJoined(_ contactID: UUID) {
        guard let contact = contacts.first(where: { $0.id == contactID }),
              contact.isGroupChat,
              !joinedChatRooms.contains(contact.handle),
              let username = contact.accountUsername else { return }
        _ = adium_purple_join_chat(username, contact.accountProtocol.purpleProtocolID, contact.handle)
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
            role: "owner"
        )

        let groupContact = Contact(
            name: trimmedName,
            handle: trimmedName,
            status: .available,
            customStatusMessage: topic ?? t("Group / Channel"),
            group: t("Groups"),
            accountProtocol: account.accountProtocol,
            accountUsername: account.username,
            isGroupChat: true,
            groupParticipants: [selfParticipant],
            topic: topic
        )
        
        createGroup(name: t("Groups"))
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
    
    /// This retrieves messages for a contact.
    /// This loads from ChatLogStore if not cached.
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
            connectionState = t("Cannot send: \(contact.displayName) is blocked")
            return
        }

        let account = resolveAccount(for: contact)
        if isLibpurpleLoaded && account == nil {
            connectionState = t("Could not send message: no account found for \(contact.displayName)")
            return
        }

        let newMsg = ChatMessage(senderName: "Me", isFromMe: true, text: text)
        recordLocalSend(contactID: contact.id, text: text)
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
    
    // MARK: - Teams Calls (WebView bypass)

    /// These handles wait for a /call URL from purple-teams.
    /// onMessageReceived opens the call window when the URL arrives.
    private var pendingCallRequests: [String: Date] = [:]
    private let pendingCallTimeout: TimeInterval = 15

    /// This starts or joins a Teams call for a conversation.
    /// Thread handles ("19:...") produce the meetup-join URL directly.
    /// Buddy handles go through the plugin's /call command.
    /// The plugin resolves the buddy to its chat thread and writes the URL back.
    public func startTeamsCall(for contact: Contact) {
        if let url = TeamsCallLink.meetingURL(forThreadHandle: contact.handle) {
            TeamsCallWindowController.shared.open(url: url)
            return
        }
        guard isLibpurpleLoaded, let account = resolveAccount(for: contact) else {
            connectionState = t("Could not start the call with \(contact.displayName)")
            return
        }
        pendingCallRequests[contact.handle] = Date()
        _ = adium_purple_exec_command(account.username, contact.accountProtocol.purpleProtocolID, contact.handle, "call", contact.isGroupChat)
    }

    /// This opens the call window if this message answers a pending /call.
    private func handlePendingCallResponse(contactHandle: String, text: String) {
        guard let requestedAt = pendingCallRequests[contactHandle],
              Date().timeIntervalSince(requestedAt) < pendingCallTimeout,
              let url = TeamsCallLink.meetingURL(in: text) else {
            return
        }
        pendingCallRequests.removeValue(forKey: contactHandle)
        TeamsCallWindowController.shared.open(url: url)
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
                EventManager.shared.triggerEvent(.contactOnline, title: contacts[idx].displayName, content: t("Is now online"), contactID: contacts[idx].id)
            } else if oldStatus != .offline && parsedStatus == .offline {
                EventManager.shared.triggerEvent(.contactOffline, title: contacts[idx].displayName, content: t("Has disconnected"), contactID: contacts[idx].id)
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
                EventManager.shared.triggerEvent(.contactOnline, title: newContact.displayName, content: t("Is now online"), contactID: newContact.id)
            }
        }
        saveContactsToDefaults()
    }
    
    func onMessageReceived(senderHandle: String, text: String, isFromMe: Bool, protocolId: String? = nil, accountUsername: String? = nil, image: Data? = nil, timestamp: Int64 = 0, isSystem: Bool = false) {
        var contact = contacts.first(where: { $0.handle == senderHandle && (protocolId == nil || $0.accountProtocol.purpleProtocolID == protocolId) })

        // A contact with this handle can exist under the wrong protocol.
        // The code keys chat logs by handle.
        // A contact with the same handle is the same conversation.
        // This reassigns it instead of creating a duplicate.
        if contact == nil, let pid = protocolId,
           let matchedProto = AccountProtocol.allCases.first(where: { $0.purpleProtocolID == pid }),
           let idx = contacts.firstIndex(where: { $0.handle == senderHandle }) {
            contacts[idx].accountProtocol = matchedProto
            if let accountUsername {
                contacts[idx].accountUsername = accountUsername
            }
            saveContactsToDefaults()
            contact = contacts[idx]
        }

        // An unknown sender still needs a placeholder Contact so the message has somewhere to attach.
        if contact == nil {
            var defaultProto = AccountProtocol.teams
            if let pid = protocolId, let matchedProto = AccountProtocol.allCases.first(where: { $0.purpleProtocolID == pid }) {
                defaultProto = matchedProto
            } else if let firstProto = accounts.first?.accountProtocol {
                defaultProto = firstProto
            }
            let defaultUsername = accountUsername ?? accounts.first?.username
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

        // Drop messages from blocked contacts.
        // This stops log entries, chat history, and events.
        if !isFromMe && c.isBlocked {
            return
        }

        handlePendingCallResponse(contactHandle: c.handle, text: text)

        let senderName = isFromMe ? "Me" : c.displayName
        // timestamp 0 means libpurple did not carry a message time.
        let msgDate = timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : Date()
        let newMsg = ChatMessage(senderName: senderName, isFromMe: isFromMe, text: text, timestamp: msgDate, imageData: image, isSystemEvent: isSystem)

        if isFromMe && isLocalSendEcho(contactID: c.id, text: text) {
            return
        }
        var msgs = messagesPerContact[c.id] ?? (ChatLogStore.shared.loadMessages(for: c.handle) ?? [])
        // This skips duplicate signals within 3 seconds.
        if let last = msgs.last, last.isFromMe == isFromMe, last.text == text, abs(Date().timeIntervalSince(last.timestamp)) < 3.0 {
            return
        }
        if isHistoryDuplicate(newMsg, in: msgs, timestamp: timestamp) {
            return
        }
        msgs.append(newMsg)
        messagesPerContact[c.id] = msgs
        
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
            if !isConnected && statusMsg != "Disconnected" {
                accounts[idx].connectionError = statusMsg
            } else if isConnected {
                accounts[idx].connectionError = nil
            }
            saveAccountsToDefaults()
        }
        if !isConnected {
            // The prpl does not reliably emit chat-left on disconnect.
            // A stale entry here would block the rejoin after a reconnect.
            let accountRooms = contacts.filter { $0.isGroupChat && $0.accountUsername == username }.map(\.handle)
            joinedChatRooms.subtract(accountRooms)
        }
        self.connectionState = "\(username): \(statusMsg)"
    }

    // MARK: - Group Chat (MUC) Live Events

    // Rooms with a live libpurple conversation. Listed chats outside this
    // set need a join before messages can flow.
    private var joinedChatRooms: Set<String> = []

    /// The server replays recent history on every join. A stored message
    /// with the same time, direction, and text is the same message.
    /// Live messages (timestamp 0) never match here; the 3-second window
    /// in the caller handles those.
    private func isHistoryDuplicate(_ msg: ChatMessage, in msgs: [ChatMessage], timestamp: Int64) -> Bool {
        guard timestamp > 0 else { return false }
        let norm = Self.normalizedMessageText(msg.text)
        // Own messages store the local send time and the raw text, while the
        // replay carries the server time and server-rendered HTML. The wider
        // window and the normalized text absorb that skew.
        let window: TimeInterval = msg.isFromMe ? 15.0 : 1.5
        return msgs.suffix(200).contains {
            guard $0.isFromMe == msg.isFromMe,
                  abs($0.timestamp.timeIntervalSince(msg.timestamp)) < window else { return false }
            if norm.isEmpty {
                // A pure image message normalizes to "". The img id changes
                // between replays, so compare the image bytes instead.
                if let data = msg.imageData { return $0.imageData == data }
                return $0.text == msg.text
            }
            return Self.normalizedMessageText($0.text) == norm
        }
    }

    // Echoes of an own send come back with server-rendered HTML, so an
    // exact-text comparison fails. Each local send records its normalized
    // text here; SEND-flagged bridge deliveries within the window match
    // against it. Messages sent from another device have no entry and
    // pass through.
    private var recentLocalSends: [(contactID: UUID, normalizedText: String, sentAt: Date)] = []
    private let localSendEchoWindow: TimeInterval = 60

    /// Reduce a message to comparable plain text: tags out, basic
    /// entities decoded, whitespace collapsed.
    static func normalizedMessageText(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        for (entity, ch) in [("&nbsp;", " "), ("&quot;", "\""), ("&apos;", "'"), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
            t = t.replacingOccurrences(of: entity, with: ch)
        }
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func recordLocalSend(contactID: UUID, text: String) {
        let now = Date()
        recentLocalSends.removeAll { now.timeIntervalSince($0.sentAt) > localSendEchoWindow }
        recentLocalSends.append((contactID, Self.normalizedMessageText(text), now))
    }

    /// True when a SEND-flagged bridge delivery is the echo of a send this
    /// app already appended locally. The entry stays until it expires:
    /// protocols can echo the same send more than once.
    private func isLocalSendEcho(contactID: UUID, text: String) -> Bool {
        let norm = Self.normalizedMessageText(text)
        // A pure image echo normalizes to "". An empty match would collide
        // with any other image; let the history dedupe handle those.
        guard !norm.isEmpty else { return false }
        let now = Date()
        return recentLocalSends.contains {
            $0.contactID == contactID && $0.normalizedText == norm
                && now.timeIntervalSince($0.sentAt) <= localSendEchoWindow
        }
    }

    /// A chat exists in the libpurple buddy list but is not joined yet.
    /// Group chats and Teams meeting chats arrive through this path.
    func onChatListed(roomName: String, title: String, username: String, protocolId: String) {
        let proto = AccountProtocol.allCases.first(where: { $0.purpleProtocolID == protocolId })
        let displayTitle = title.isEmpty ? roomName : title
        let isMeeting = roomName.hasPrefix("19:meeting_")
        let groupName = isMeeting ? t("Meetings") : t("Groups")

        // The account is part of the key. Two accounts can list the same room id.
        if let idx = contacts.firstIndex(where: {
            $0.isGroupChat && $0.handle == roomName
                && (username.isEmpty || $0.accountUsername == nil || $0.accountUsername == username)
        }) {
            // A later pass carries the real title once the plugin resolves it.
            if displayTitle != roomName && contacts[idx].name != displayTitle {
                contacts[idx].name = displayTitle
                saveContactsToDefaults()
            }
            return
        }

        let newContact = Contact(
            name: displayTitle,
            handle: roomName,
            status: .available,
            customStatusMessage: isMeeting ? t("Meeting") : t("Group / Channel"),
            group: groupName,
            accountProtocol: proto ?? .teams,
            accountUsername: username.isEmpty ? nil : username,
            isGroupChat: true
        )
        createGroup(name: groupName)
        contacts.append(newContact)
        saveContactsToDefaults()
    }

    func onChatUnlisted(roomName: String, username: String, protocolId: String) {
        // A joined chat stays open even when the plugin drops the list entry.
        guard !joinedChatRooms.contains(roomName) else { return }
        let before = contacts.count
        contacts.removeAll(where: {
            $0.isGroupChat && $0.handle == roomName
                && (username.isEmpty || $0.accountUsername == nil || $0.accountUsername == username)
        })
        if contacts.count != before {
            saveContactsToDefaults()
        }
    }

    func onChatJoined(roomName: String, username: String, protocolId: String) {
        joinedChatRooms.insert(roomName)
        let proto = AccountProtocol.allCases.first(where: { $0.purpleProtocolID == protocolId })
        // libpurple can normalize the room name.
        // The code reconciles the contact handle to the libpurple room name.
        // This routes incoming chat messages back to the contact.
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
                customStatusMessage: t("Group / Channel"),
                group: t("Groups"),
                accountProtocol: proto ?? .teams,
                accountUsername: username,
                isGroupChat: true
            )
            createGroup(name: t("Groups"))
            contacts.append(newContact)
            saveContactsToDefaults()
        }
    }

    func onChatLeft(roomName: String, username: String, protocolId: String) {
        // leaveGroupChat() removes the local contact when the user leaves.
        // This fires for the libpurple side or when the server kicks the user.
        // There is no UI for kicks yet.
        joinedChatRooms.remove(roomName)
    }

    /// Map a raw protocol sender id to a display name. Teams system events
    /// arrive with "8:orgid:<uuid>", "orgid:<uuid>", or the thread id as the
    /// sender. Returns nil when the sender is the thread itself: the event
    /// has no person to attribute and the UI hides the sender line.
    func resolveSenderDisplayName(_ sender: String, in chat: Contact?) -> String? {
        if sender.isEmpty { return nil }
        if sender.contains("@thread") || sender == chat?.handle { return nil }
        var handle = sender
        if handle.hasPrefix("8:") { handle.removeFirst(2) }
        // Contacts carry the resolved profile name. Participants can still
        // hold the raw roster id, so they only count with a real name.
        if let known = contacts.first(where: { !$0.isGroupChat && ($0.handle == handle || $0.handle == sender) }) {
            return known.displayName
        }
        if let participant = chat?.groupParticipants.first(where: {
            ($0.handle == handle || $0.handle == sender) && $0.displayName != $0.handle
        }) {
            return participant.displayName
        }
        return sender
    }

    func onChatMessage(roomName: String, sender: String, text: String, isFromMe: Bool, timestamp: Int64 = 0, isSystem: Bool = false) {
        guard let c = contacts.first(where: { $0.isGroupChat && $0.handle == roomName }) else { return }
        if !isFromMe && c.isBlocked { return }

        let senderName = isFromMe ? "Me" : (sender.isEmpty ? c.displayName : sender)
        // timestamp 0 means libpurple did not carry a message time.
        let msgDate = timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : Date()
        let newMsg = ChatMessage(senderName: senderName, isFromMe: isFromMe, text: text, timestamp: msgDate, isSystemEvent: isSystem)
        if newMsg.isMeetingMetadataEvent { return }

        if isFromMe && isLocalSendEcho(contactID: c.id, text: text) {
            return
        }
        var msgs = messagesPerContact[c.id] ?? (ChatLogStore.shared.loadMessages(for: c.handle) ?? [])
        if let last = msgs.last, last.isFromMe == isFromMe, last.text == text, abs(Date().timeIntervalSince(last.timestamp)) < 3.0 {
            return
        }
        if isHistoryDuplicate(newMsg, in: msgs, timestamp: timestamp) {
            return
        }
        msgs.append(newMsg)
        messagesPerContact[c.id] = msgs

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

    /// This fires for each occupant of a joined chat.
    /// This applies to the initial roster and later joins.
    /// This matches the room by handle.
    /// This removes duplicates by participant handle.
    func onChatBuddyJoined(roomName: String, buddyName: String, newArrival: Bool) {
        guard let idx = contacts.firstIndex(where: { $0.isGroupChat && $0.handle == roomName }) else { return }
        // The roster delivers raw protocol ids. A known contact provides
        // the profile name.
        let stripped = buddyName.hasPrefix("8:") ? String(buddyName.dropFirst(2)) : buddyName
        let knownName = contacts.first(where: { !$0.isGroupChat && ($0.handle == stripped || $0.handle == buddyName) })?.displayName
        if let pIdx = contacts[idx].groupParticipants.firstIndex(where: { $0.handle == buddyName }) {
            // A participant stored with the raw id gets the name once known.
            if let knownName, contacts[idx].groupParticipants[pIdx].name == buddyName {
                contacts[idx].groupParticipants[pIdx].name = knownName
                saveContactsToDefaults()
            }
            return
        }
        let participant = GroupParticipant(name: knownName ?? buddyName, handle: buddyName, status: .available)
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
    
    private static let handleMessageCallback: adium_purple_on_message_cb = { senderHandle, messageText, isFromMe, isSystem, protocolId, accountUsername, timestamp, imageData, imageSize in
        guard let senderHandle = senderHandle, let messageText = messageText else { return }
        let hStr = String(cString: senderHandle)
        let mStr = String(cString: messageText)
        let pStr = protocolId != nil ? String(cString: protocolId!) : ""
        let uStr = accountUsername != nil ? String(cString: accountUsername!) : ""

        let data = imageData != nil && imageSize > 0 ? Data(bytes: imageData!, count: imageSize) : nil

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onMessageReceived(senderHandle: hStr, text: mStr, isFromMe: isFromMe, protocolId: pStr.isEmpty ? nil : pStr, accountUsername: uStr.isEmpty ? nil : uStr, image: data, timestamp: timestamp, isSystem: isSystem)
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

        // Modal dialogs are acceptable here.
        // PurpleBridgeService is MainActor.
        // libpurple runs its own thread.
        // This modal does not block network I/O.
        let response = alert.runModal()

        // libpurple can close this request before the user responds.
        // This drops the response if the request is closed.
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

    func onNotifyMessage(type: Int32, title: String, primary: String, secondary: String) {
        let alert = NSAlert()
        alert.alertStyle = type == 0 ? .critical : (type == 1 ? .warning : .informational)
        alert.messageText = primary.isEmpty ? title : primary
        if !secondary.isEmpty {
            alert.informativeText = secondary
        }
        alert.addButton(withTitle: t("OK"))
        alert.runModal()
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

    private static let handleChatMessageCallback: adium_purple_on_chat_message_cb = { roomName, sender, messageText, isFromMe, isSystem, timestamp in
        guard let roomName = roomName, let messageText = messageText else { return }
        let rStr = String(cString: roomName)
        let sStr = sender != nil ? String(cString: sender!) : ""
        let mStr = String(cString: messageText)

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onChatMessage(roomName: rStr, sender: sStr, text: mStr, isFromMe: isFromMe, timestamp: timestamp, isSystem: isSystem)
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

    private static let handleChatListedCallback: adium_purple_on_chat_listed_cb = { roomName, title, groupName, username, protocolId in
        guard let roomName = roomName else { return }
        let rStr = String(cString: roomName)
        let tStr = title != nil ? String(cString: title!) : ""
        let uStr = username != nil ? String(cString: username!) : ""
        let pStr = protocolId != nil ? String(cString: protocolId!) : ""

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onChatListed(roomName: rStr, title: tStr, username: uStr, protocolId: pStr)
        }
    }

    private static let handleChatUnlistedCallback: adium_purple_on_chat_unlisted_cb = { roomName, username, protocolId in
        guard let roomName = roomName else { return }
        let rStr = String(cString: roomName)
        let uStr = username != nil ? String(cString: username!) : ""
        let pStr = protocolId != nil ? String(cString: protocolId!) : ""

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onChatUnlisted(roomName: rStr, username: uStr, protocolId: pStr)
        }
    }

    private static let handleNotifyMessageCallback: adium_purple_on_notify_message_cb = { type, title, primary, secondary in
        let tStr = title != nil ? String(cString: title!) : ""
        let pStr = primary != nil ? String(cString: primary!) : ""
        let sStr = secondary != nil ? String(cString: secondary!) : ""

        DispatchQueue.main.async {
            PurpleBridgeService.shared.onNotifyMessage(type: type, title: tStr, primary: pStr, secondary: sStr)
        }
    }
}

public struct RequestHandleWrapper: @unchecked Sendable {
    public let rawPointer: UnsafeMutableRawPointer
    public init(_ rawPointer: UnsafeMutableRawPointer) {
        self.rawPointer = rawPointer
    }
}
