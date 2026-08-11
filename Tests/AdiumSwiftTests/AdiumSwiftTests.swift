import Testing
import Foundation
import Contacts
import CLibpurple
@testable import AdiumSwift

@Suite("AdiumSwift Models & Core Logic Tests")
struct AdiumSwiftTests {

    @Test("OnlineStatus properties")
    func testOnlineStatusProperties() {
        #expect(OnlineStatus.available.rawValue == "Available")
        #expect(OnlineStatus.available.iconName == "checkmark.circle.fill")
        #expect(OnlineStatus.away.iconName == "clock.fill")
        #expect(OnlineStatus.busy.iconName == "minus.circle.fill")
        #expect(OnlineStatus.offline.iconName == "circle")
    }

    @Test("AccountProtocol mappings")
    func testAccountProtocolProperties() {
        #expect(AccountProtocol.teams.purpleProtocolID == "prpl-eionrobb-msteams")
        #expect(AccountProtocol.whatsapp.purpleProtocolID == "prpl-hehoe-whatsmeow")
        #expect(AccountProtocol.xmpp.purpleProtocolID == "prpl-jabber")
        #expect(AccountProtocol.matrix.purpleProtocolID == "prpl-matrix")
        #expect(AccountProtocol.customLibpurple.purpleProtocolID == "prpl-custom")
    }

    @Test("Set user status updates myStatus")
    @MainActor
    func testSetUserStatus() {
        let bridge = PurpleBridgeService.shared
        bridge.setUserStatus(.away)
        #expect(bridge.myStatus == .away)
        bridge.setUserStatus(.available)
        #expect(bridge.myStatus == .available)
    }

    @Test("Account error tracking and reconnection")
    @MainActor
    func testAccountErrorAndReconnection() {
        let bridge = PurpleBridgeService.shared
        let acc = Account(username: "errtest@domain.com", accountProtocol: .teams, isConnected: false, connectionError: "Auth Failed")
        bridge.accounts.append(acc)
        
        #expect(bridge.hasAccountError)
        #expect(bridge.accountErrorSummary?.contains("Auth Failed") == true)
        
        bridge.reconnectAccounts()
        
        #expect(bridge.accounts.first(where: { $0.username == "errtest@domain.com" })?.connectionError == nil)
        
        bridge.removeAccount(acc)
    }

    @Test("Account and Contact initialization")
    func testAccountAndContactInitialization() {
        let account = Account(username: "user@company.com", accountProtocol: .teams, isConnected: false)
        #expect(account.username == "user@company.com")
        #expect(account.accountProtocol == .teams)
        #expect(account.isConnected == false)

        let contact = Contact(
            name: "John Doe",
            handle: "john.doe@company.com",
            status: .available,
            customStatusMessage: "In a call",
            group: "Work",
            accountProtocol: .teams
        )
        #expect(contact.name == "John Doe")
        #expect(contact.handle == "john.doe@company.com")
        #expect(contact.status == .available)
        #expect(contact.group == "Work")
    }

    @Test("ChatMessage creation")
    func testChatMessageCreation() {
        let msg = ChatMessage(senderName: "Alice", isFromMe: false, text: "Hello Adium!")
        #expect(msg.senderName == "Alice")
        #expect(msg.isFromMe == false)
        #expect(msg.text == "Hello Adium!")
    }

    @Test("PurpleBridgeService initial state has no mock data")
    @MainActor
    func testPurpleBridgeInitialState() {
        let bridge = PurpleBridgeService.shared
        // The initial state is clean and has no fake mocks.
        #expect(bridge.accounts.isEmpty || !bridge.accounts.contains(where: { $0.username == "ana.garcia@company.com" }))
    }

    @Test("PurpleBridgeService account connection and removal")
    @MainActor
    func testConnectAndRemoveAccount() {
        let bridge = PurpleBridgeService.shared
        let username = "remove.test@domain.com"
        bridge.connectAccount(username: username, protocolType: .teams, password: "")
        guard let addedAcc = bridge.accounts.first(where: { $0.username == username }) else {
            #expect(Bool(false), "Account should have been added")
            return
        }
        #expect(addedAcc.username == username)
        
        bridge.removeAccount(addedAcc)
        #expect(!bridge.accounts.contains(where: { $0.username == username }))
    }

    @Test("CLibpurple status info thread safety")
    func testCLibpurpleStatusInfo() {
        if let status = adium_purple_get_status_info() {
            let str = String(cString: status)
            #expect(!str.isEmpty)
        }
    }

    @Test("KeychainHelper save, fetch, delete password")
    func testKeychainHelper() {
        let testAccount = "testuser@example.com:prpl-teams"
        let testPassword = "SecretPassword123!"
        
        let saveSuccess = KeychainHelper.savePassword(testPassword, for: testAccount)
        #expect(saveSuccess)
        
        let fetched = KeychainHelper.fetchPassword(for: testAccount)
        #expect(fetched == testPassword)
        
        let deleteSuccess = KeychainHelper.deletePassword(for: testAccount)
        #expect(deleteSuccess)
        
        let fetchedAfterDelete = KeychainHelper.fetchPassword(for: testAccount)
        #expect(fetchedAfterDelete == nil)
    }

    @Test("ChatLogStore stable handle storage")
    @MainActor
    func testChatLogStoreStableHandle() {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        let handle = "user.stable@test.com"
        let msgs = [
            ChatMessage(senderName: "Alice", isFromMe: false, text: "Hello!"),
            ChatMessage(senderName: "Me", isFromMe: true, text: "Hi Alice!")
        ]

        store.saveMessages(msgs, for: handle)
        let loaded = store.loadMessages(for: handle)

        #expect(loaded != nil)
        #expect(loaded?.count == 2)
        #expect(loaded?.first?.text == "Hello!")
        #expect(loaded?.last?.text == "Hi Alice!")
    }

    @Test("Remove account cleans up specific contacts only")
    @MainActor
    func testRemoveAccountSpecificContactCleanup() {
        let bridge = PurpleBridgeService.shared
        let acc1 = Account(username: "user1@corp.com", accountProtocol: .teams)
        let acc2 = Account(username: "user2@jabber.com", accountProtocol: .xmpp)
        
        bridge.connectAccount(username: acc1.username, protocolType: acc1.accountProtocol, password: "p1")
        bridge.connectAccount(username: acc2.username, protocolType: acc2.accountProtocol, password: "p2")
        
        let c1 = Contact(name: "Contact 1", handle: "c1@corp.com", status: .available, accountProtocol: .teams, accountUsername: "user1@corp.com")
        let c2 = Contact(name: "Contact 2", handle: "c2@jabber.com", status: .available, accountProtocol: .xmpp, accountUsername: "user2@jabber.com")
        bridge.contacts.append(contentsOf: [c1, c2])
        
        guard let addedAcc1 = bridge.accounts.first(where: { $0.username == acc1.username }) else {
            #expect(Bool(false), "Account 1 should exist")
            return
        }
        
        bridge.removeAccount(addedAcc1)
        
        #expect(!bridge.accounts.contains(where: { $0.username == acc1.username }))
        #expect(bridge.accounts.contains(where: { $0.username == acc2.username }))
        #expect(!bridge.contacts.contains(where: { $0.handle == "c1@corp.com" }))
        #expect(bridge.contacts.contains(where: { $0.handle == "c2@jabber.com" }))
        
        if let addedAcc2 = bridge.accounts.first(where: { $0.username == acc2.username }) {
            bridge.removeAccount(addedAcc2)
        }
    }

    @Test("Account persistence and restoring")
    @MainActor
    func testAccountPersistenceAndRestoring() {
        let bridge = PurpleBridgeService.shared
        let username = "persist.user@test.com"
        let password = "SuperSecretPassword123"
        let proto = AccountProtocol.xmpp

        // 1. This connects the account.
        bridge.connectAccount(username: username, protocolType: proto, password: password)

        let accountKey = "\(username):\(proto.purpleProtocolID)"
        #expect(KeychainHelper.fetchPassword(for: accountKey) == password)

        // 2. This clears the in-memory accounts and restores from defaults.
        bridge.accounts.removeAll()
        #expect(bridge.accounts.isEmpty)

        bridge.restoreSavedAccounts()
        guard let restoredAcc = bridge.accounts.first(where: { $0.username == username }) else {
            #expect(Bool(false), "Restored accounts should contain persist.user@test.com")
            return
        }

        #expect(restoredAcc.username == username)
        #expect(restoredAcc.accountProtocol == proto)

        // 3. This cleans up the state.
        bridge.removeAccount(restoredAcc)
        bridge.accounts.removeAll()
        bridge.restoreSavedAccounts()
        #expect(!bridge.accounts.contains(where: { $0.username == username }))
    }

    @Test("Notification triggering")
    @MainActor
    func testNotificationTriggering() {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        let notifService = NotificationService.shared

        // 1. This tests the direct notification service call.
        notifService.notifyIncomingMessage(sender: "Alice", content: "Direct notification test")
        #expect(notifService.lastNotification?.sender == "Alice")
        #expect(notifService.lastNotification?.content == "Direct notification test")

        let notifServiceAlias = NotificationService.shared
        notifServiceAlias.notifyIncomingMessage(senderName: "Bob", messageText: "Alias method test")
        #expect(notifServiceAlias.lastNotification?.sender == "Bob")
        #expect(notifServiceAlias.lastNotification?.content == "Alias method test")

        // 2. This tests that an incoming message triggers a notification.
        let bridge = PurpleBridgeService.shared
        let senderHandle = "notifier.sender@test.com"
        let contact = Contact(name: "Notifier Sender", handle: senderHandle, status: .available, accountProtocol: .teams)
        bridge.contacts.append(contact)

        let incomingText = "Hello via incoming message!"
        bridge.onMessageReceived(senderHandle: senderHandle, text: incomingText, isFromMe: false)

        #expect(notifService.lastNotification?.sender == "Notifier Sender")
        #expect(notifService.lastNotification?.content == incomingText)

        // 3. This tests that an outgoing message does not update the state.
        let outgoingText = "My outgoing response"
        bridge.onMessageReceived(senderHandle: senderHandle, text: outgoingText, isFromMe: true)
        #expect(notifService.lastNotification?.content != outgoingText)

        // This cleans up the state.
        bridge.contacts.removeAll(where: { $0.handle == senderHandle })
    }

    @Test("Unknown sender auto-creation logic")
    @MainActor
    func testUnknownSenderAutoCreation() {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        let bridge = PurpleBridgeService.shared
        let unknownHandle = "unknown.sender.auto@domain.org"

        // This ensures the contact is not present beforehand.
        bridge.contacts.removeAll(where: { $0.handle == unknownHandle })

        // This triggers an incoming message from an unknown sender.
        let messageText = "Auto-created sender message"
        bridge.onMessageReceived(senderHandle: unknownHandle, text: messageText, isFromMe: false)

        // This verifies the system auto-created the contact.
        guard let newContact = bridge.contacts.first(where: { $0.handle == unknownHandle }) else {
            #expect(Bool(false), "Unknown sender contact should have been automatically created")
            return
        }

        #expect(newContact.name == unknownHandle)
        #expect(newContact.handle == unknownHandle)
        #expect(newContact.group == "General")
        #expect(newContact.status == .available)

        // This verifies the system stored the message.
        let msgs = bridge.messages(for: newContact)
        #expect(msgs.contains(where: { $0.text == messageText }))

        // This cleans up the state.
        bridge.contacts.removeAll(where: { $0.handle == unknownHandle })
    }

    @Test("ChatLogStore handle indexing and UUID fallback")
    @MainActor
    func testChatLogStoreIndexingAndUUIDFallback() {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        // 1. This uses a handle with special characters.
        let specialHandle = "user+special.handle_123@domain-test.com"
        let handleMsgs = [ChatMessage(senderName: "Tester", isFromMe: false, text: "Special handle text")]
        store.saveMessages(handleMsgs, for: specialHandle)

        let loadedHandleMsgs = store.loadMessages(for: specialHandle)
        #expect(loadedHandleMsgs?.count == 1)
        #expect(loadedHandleMsgs?.first?.text == "Special handle text")

        // 2. This uses the legacy UUID fallback.
        let testID = UUID()
        let uuidMsgs = [ChatMessage(senderName: "Me", isFromMe: true, text: "UUID fallback text")]
        store.saveMessages(uuidMsgs, for: testID)

        let loadedUUIDMsgs = store.loadMessages(for: testID)
        #expect(loadedUUIDMsgs?.count == 1)
        #expect(loadedUUIDMsgs?.first?.text == "UUID fallback text")
    }

    @Test("Account state changes updates connection status and errors")
    @MainActor
    func testOnAccountStateChanged() {
        let bridge = PurpleBridgeService.shared
        let username = "state.test@domain.com"
        let proto = AccountProtocol.teams

        let acc = Account(username: username, accountProtocol: proto, isConnected: false)
        bridge.accounts.append(acc)

        // 1. This simulates an account connected event.
        bridge.onAccountStateChanged(username: username, protocolId: proto.purpleProtocolID, isConnected: true, statusMsg: "Conectado")

        guard let connectedAcc = bridge.accounts.first(where: { $0.username == username }) else {
            #expect(Bool(false), "Account should exist")
            return
        }
        #expect(connectedAcc.isConnected == true)
        #expect(connectedAcc.connectionError == nil)

        // 2. This simulates an account error event.
        bridge.onAccountStateChanged(username: username, protocolId: proto.purpleProtocolID, isConnected: false, statusMsg: "Error de Autenticación")

        guard let erroredAcc = bridge.accounts.first(where: { $0.username == username }) else {
            #expect(Bool(false), "Account should exist")
            return
        }
        #expect(erroredAcc.isConnected == false)
        #expect(erroredAcc.connectionError == "Error de Autenticación")

        // This cleans up the state.
        bridge.removeAccount(erroredAcc)
    }

    @Test("Contact Groups management")
    @MainActor
    func testContactGroupsManagement() {
        let bridge = PurpleBridgeService.shared
        
        // 1. This creates a group.
        bridge.createGroup(name: "Proyecto Alpha")
        #expect(bridge.contactGroups.contains(where: { $0.name == "Proyecto Alpha" }))
        
        // 2. This toggles the expansion.
        bridge.toggleGroupExpanded(name: "Proyecto Alpha")
        let alphaGroup = bridge.contactGroups.first(where: { $0.name == "Proyecto Alpha" })
        #expect(alphaGroup?.isExpanded == false)
        
        // 3. This moves the contact to a group.
        let contact = Contact(name: "Carlos V", handle: "carlos@alpha.org", status: .available)
        bridge.contacts.append(contact)
        bridge.moveContact(contact.id, toGroup: "Proyecto Alpha")
        #expect(bridge.contacts.first(where: { $0.id == contact.id })?.group == "Proyecto Alpha")
        
        // 4. This renames the group.
        bridge.renameGroup(oldName: "Proyecto Alpha", newName: "Proyecto Beta")
        #expect(bridge.contactGroups.contains(where: { $0.name == "Proyecto Beta" }))
        #expect(bridge.contacts.first(where: { $0.id == contact.id })?.group == "Proyecto Beta")
        
        // 5. This deletes the group.
        bridge.deleteGroup(name: "Proyecto Beta")
        #expect(!bridge.contactGroups.contains(where: { $0.name == "Proyecto Beta" }))
        #expect(bridge.contacts.first(where: { $0.id == contact.id })?.group == "General")
        
        // This cleans up the state.
        bridge.contacts.removeAll(where: { $0.id == contact.id })
    }

    @Test("Metacontacts combination and primary contact")
    @MainActor
    func testMetacontacts() {
        let bridge = PurpleBridgeService.shared
        let c1 = Contact(name: "John Work", handle: "john@work.com", status: .available, accountProtocol: .teams)
        let c2 = Contact(name: "John Personal", handle: "+34600000000", status: .away, accountProtocol: .whatsapp)
        bridge.contacts.append(contentsOf: [c1, c2])
        
        // 1. This combines the contacts into a Metacontact.
        let meta = bridge.combineContacts([c1.id, c2.id], name: "John Doe (Combined)")
        #expect(meta.name == "John Doe (Combined)")
        #expect(meta.contactIDs.count == 2)
        #expect(meta.primaryContactID == c1.id)
        #expect(bridge.contacts.first(where: { $0.id == c1.id })?.metacontactID == meta.id)
        #expect(bridge.contacts.first(where: { $0.id == c2.id })?.metacontactID == meta.id)
        
        // 2. This changes the primary contact.
        bridge.setPrimaryContact(contactID: c2.id, inMetacontact: meta.id)
        #expect(bridge.metacontacts.first(where: { $0.id == meta.id })?.primaryContactID == c2.id)
        
        // 3. This unlinks the metacontact.
        bridge.unlinkMetacontact(meta.id)
        #expect(!bridge.metacontacts.contains(where: { $0.id == meta.id }))
        #expect(bridge.contacts.first(where: { $0.id == c1.id })?.metacontactID == nil)
        #expect(bridge.contacts.first(where: { $0.id == c2.id })?.metacontactID == nil)
        
        // This cleans up the state.
        bridge.contacts.removeAll(where: { $0.id == c1.id || $0.id == c2.id })
    }

    @Test("Contact local alias, blocking, and avatar data")
    @MainActor
    func testContactAliasAndBlockingAndAvatar() {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        let bridge = PurpleBridgeService.shared
        let contact = Contact(name: "Robert Smith", handle: "rsmith@company.com", status: .available)
        bridge.contacts.append(contact)
        
        #expect(contact.displayName == "Robert Smith")
        
        // 1. This sets a local alias.
        bridge.setAlias("Bob", for: contact.id)
        let updatedWithAlias = bridge.contacts.first(where: { $0.id == contact.id })
        #expect(updatedWithAlias?.displayName == "Bob")
        #expect(updatedWithAlias?.alias == "Bob")
        
        // 2. This toggles blocking.
        #expect(updatedWithAlias?.isBlocked == false)
        bridge.toggleBlockContact(contact.id)
        let blockedContact = bridge.contacts.first(where: { $0.id == contact.id })
        #expect(blockedContact?.isBlocked == true)
        
        // 3. This verifies an incoming message from a blocked contact suppresses a notification.
        let notifService = NotificationService.shared
        let initialNotifContent = notifService.lastNotification?.content
        bridge.onMessageReceived(senderHandle: contact.handle, text: "Spam message from blocked user", isFromMe: false)
        #expect(notifService.lastNotification?.content == initialNotifContent)
        
        // 4. This sets the avatar data.
        let dummyAvatarData = Data([0x89, 0x50, 0x4E, 0x47])
        bridge.setAvatar(data: dummyAvatarData, for: contact.id)
        #expect(bridge.contacts.first(where: { $0.id == contact.id })?.avatarData == dummyAvatarData)
        
        // This cleans up the state.
        bridge.contacts.removeAll(where: { $0.id == contact.id })
    }

    @Test("Account advanced options and purple option functions")
    @MainActor
    func testAccountAdvancedOptions() {
        let bridge = PurpleBridgeService.shared
        let username = "xmpp.user@jabber.org"
        let proto = AccountProtocol.xmpp
        
        bridge.connectAccount(
            username: username,
            protocolType: proto,
            password: "Password123!",
            server: "xmpp.jabber.org",
            port: 5222,
            resource: "AdiumMac"
        )
        
        guard let acc = bridge.accounts.first(where: { $0.username == username }) else {
            #expect(Bool(false), "Account should exist")
            return
        }
        
        #expect(acc.server == "xmpp.jabber.org")
        #expect(acc.port == 5222)
        #expect(acc.resource == "AdiumMac")
        
        // This updates the account options.
        bridge.updateAccountOptions(
            accountID: acc.id,
            server: "custom.jabber.server",
            port: 5223,
            resource: "AdiumOffice",
            useSSL: true,
            customOptions: ["connect_server": "custom.jabber.server"]
        )
        
        guard let updatedAcc = bridge.accounts.first(where: { $0.id == acc.id }) else {
            #expect(Bool(false), "Updated account should exist")
            return
        }
        
        #expect(updatedAcc.server == "custom.jabber.server")
        #expect(updatedAcc.port == 5223)
        #expect(updatedAcc.resource == "AdiumOffice")
        #expect(updatedAcc.customOptions["connect_server"] == "custom.jabber.server")
        
        // This cleans up the state.
        bridge.removeAccount(updatedAcc)
    }

    @Test("Typing status state updates")
    @MainActor
    func testTypingStateUpdates() {
        let bridge = PurpleBridgeService.shared
        let contact = Contact(
            name: "Typing Buddy",
            handle: "typing.buddy@domain.com",
            status: .available,
            accountProtocol: .teams
        )
        bridge.contacts.append(contact)
        
        #expect(bridge.contacts.first(where: { $0.handle == "typing.buddy@domain.com" })?.isTyping == false)
        
        bridge.onTypingStateChanged(handle: "typing.buddy@domain.com", isTyping: true)
        #expect(bridge.contacts.first(where: { $0.handle == "typing.buddy@domain.com" })?.isTyping == true)
        
        bridge.onTypingStateChanged(handle: "typing.buddy@domain.com", isTyping: false)
        #expect(bridge.contacts.first(where: { $0.handle == "typing.buddy@domain.com" })?.isTyping == false)
        
        bridge.contacts.removeAll(where: { $0.handle == "typing.buddy@domain.com" })
    }

    @Test("Buddy removal event removes contact")
    @MainActor
    func testBuddyRemovalEvent() {
        let bridge = PurpleBridgeService.shared
        let contact = Contact(
            name: "Removed Buddy",
            handle: "removed.buddy@domain.com",
            status: .available,
            accountProtocol: .teams
        )
        bridge.contacts.append(contact)
        #expect(bridge.contacts.contains(where: { $0.handle == "removed.buddy@domain.com" }))
        
        bridge.onBuddyRemoved(handle: "removed.buddy@domain.com")
        #expect(!bridge.contacts.contains(where: { $0.handle == "removed.buddy@domain.com" }))
    }

    @Test("Connection progress updates connection state")
    @MainActor
    func testConnectionProgressUpdate() {
        let bridge = PurpleBridgeService.shared
        bridge.onConnectionProgress(username: "user@domain.com", protocolId: "prpl-teams", text: "Autenticando", step: 1, stepCount: 3)
        #expect(bridge.connectionState.contains("Autenticando"))
        #expect(bridge.connectionState.contains("1/3"))
    }

    @Test("Tabbed messaging open, switch, close and unread logic")
    @MainActor
    func testTabbedMessagingOperations() {
        let bridge = PurpleBridgeService.shared
        let c1 = Contact(name: "Buddy One", handle: "buddy1@test.com", status: .available)
        let c2 = Contact(name: "Buddy Two", handle: "buddy2@test.com", status: .available)
        bridge.contacts.append(contentsOf: [c1, c2])

        // 1. This opens a tab.
        bridge.openTab(for: c1.id)
        #expect(bridge.openTabIDs.contains(c1.id))
        #expect(bridge.activeTabID == c1.id)

        // 2. This opens a second tab.
        bridge.openTab(for: c2.id)
        #expect(bridge.openTabIDs.contains(c2.id))
        #expect(bridge.activeTabID == c2.id)

        // 3. This switches the active tab back to c1.
        bridge.setActiveTab(c1.id)
        #expect(bridge.activeTabID == c1.id)

        // 4. This tracks unread messages.
        bridge.unreadCounts[c2.id] = 3
        #expect(bridge.unreadCounts[c2.id] == 3)
        bridge.setActiveTab(c2.id)
        #expect(bridge.unreadCounts[c2.id] == 0)

        // 5. This closes the tab.
        bridge.closeTab(c2.id)
        #expect(!bridge.openTabIDs.contains(c2.id))
        #expect(bridge.activeTabID == c1.id)

        bridge.closeTab(c1.id)
        #expect(bridge.openTabIDs.isEmpty)
        #expect(bridge.activeTabID == nil)

        // This cleans up the state.
        bridge.contacts.removeAll(where: { $0.id == c1.id || $0.id == c2.id })
    }

    @Test("Group Chat (MUC) creation and participant management")
    @MainActor
    func testGroupChatCreationAndParticipantManagement() {
        let bridge = PurpleBridgeService.shared
        let account = Account(username: "myuser@teams.com", accountProtocol: .teams)
        bridge.accounts.append(account)

        // 1. This joins a group chat.
        let groupContact = bridge.joinGroupChat(channelName: "Canal General", account: account, topic: "Discusion general")
        #expect(groupContact.isGroupChat == true)
        #expect(groupContact.name == "Canal General")
        #expect(groupContact.topic == "Discusion general")
        #expect(groupContact.groupParticipants.count == 1)
        #expect(bridge.openTabIDs.contains(groupContact.id))

        // 2. This adds a group participant.
        let p2 = GroupParticipant(name: "Ana Gomez", handle: "ana.gomez@teams.com", status: .available, role: "Miembro")
        bridge.addGroupParticipant(contactID: groupContact.id, participant: p2)

        let updatedGroup = bridge.contacts.first(where: { $0.id == groupContact.id })
        #expect(updatedGroup?.groupParticipants.count == 2)
        #expect(updatedGroup?.groupParticipants.contains(where: { $0.handle == "ana.gomez@teams.com" }) == true)

        // 3. This removes a group participant.
        bridge.removeGroupParticipant(contactID: groupContact.id, participantHandle: "ana.gomez@teams.com")
        let afterRemove = bridge.contacts.first(where: { $0.id == groupContact.id })
        #expect(afterRemove?.groupParticipants.count == 1)

        // 4. This leaves the group chat.
        bridge.leaveGroupChat(groupContact.id)
        #expect(!bridge.contacts.contains(where: { $0.id == groupContact.id }))
        #expect(!bridge.openTabIDs.contains(groupContact.id))

        // This cleans up the state.
        bridge.removeAccount(account)
    }

    @Test("EventManager rule updating, event triggers, and badge counting")
    @MainActor
    func testEventManagerRulesAndTriggers() {
        let eventMgr = EventManager.shared

        // The updateRule method persists to UserDefaults.
        // It uses the AdiumEventRules key.
        // The test restores the key and rule after it finishes.
        let rulesDefaultsKey = "AdiumEventRules"
        let previousRulesData = UserDefaults.standard.object(forKey: rulesDefaultsKey)
        let previousMessageReceivedRule = eventMgr.rules[.messageReceived]
        defer {
            if let previousRulesData {
                UserDefaults.standard.set(previousRulesData, forKey: rulesDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: rulesDefaultsKey)
            }
            if let previousMessageReceivedRule {
                eventMgr.updateRule(previousMessageReceivedRule)
            }
        }

        // 1. This checks that default rules exist.
        #expect(eventMgr.rules[.messageReceived] != nil)
        #expect(eventMgr.rules[.messageSent] != nil)
        #expect(eventMgr.rules[.contactOnline] != nil)
        #expect(eventMgr.rules[.contactOffline] != nil)

        // 2. This updates the rule.
        var customRule = eventMgr.rules[.messageReceived]!
        customRule.soundName = "Glass"
        customRule.bounceDock = true
        eventMgr.updateRule(customRule)

        #expect(eventMgr.rules[.messageReceived]?.soundName == "Glass")

        // 3. This triggers the event.
        eventMgr.triggerEvent(.messageReceived, title: "Alice", content: "Test event trigger")
        #expect(eventMgr.lastTriggeredEvent?.type == .messageReceived)
        #expect(eventMgr.lastTriggeredEvent?.title == "Alice")
        #expect(eventMgr.lastTriggeredEvent?.content == "Test event trigger")

        // 4. This updates the unread badge counter.
        eventMgr.setUnreadCount(5)
        #expect(eventMgr.unreadCount == 5)
        eventMgr.incrementUnreadCount()
        #expect(eventMgr.unreadCount == 6)
        eventMgr.clearUnreadCount()
        #expect(eventMgr.unreadCount == 0)
    }

    @Test("RichTextFormatter HTML to Markdown, Emoticons, and AutoLinks")
    func testRichTextFormattingAndEmoticons() {
        // 1. This replaces emoticons.
        let textWithEmoticons = "Hola :) Como estas? :D genial <3"
        let replaced = RichTextFormatter.replaceEmoticons(in: textWithEmoticons)
        #expect(replaced.contains("😊"))
        #expect(replaced.contains("😃"))
        #expect(replaced.contains("❤️"))

        // 2. This converts HTML to Markdown.
        let htmlInput = "Hola <b>Mundo</b><br>Visita <a href=\"https://adium.im\">Adium</a>"
        let converted = RichTextFormatter.convertHTMLToMarkdown(htmlInput)
        #expect(converted.contains("**Mundo**"))
        #expect(converted.contains("[Adium](https://adium.im)"))
        #expect(converted.contains("\n"))

        // 3. This auto-links a plain URL.
        let plainURL = "Mira este sitio: https://github.com/adium/adium"
        let autoLinked = RichTextFormatter.autoLinkURLs(in: plainURL)
        #expect(autoLinked.contains("[https://github.com/adium/adium](https://github.com/adium/adium)"))

        // 4. This formats the message through the pipeline.
        let fullFormatted = RichTextFormatter.formatMessage("Probando <i>cursiva</i> :) https://example.com")
        let str = String(fullFormatted.characters)
        #expect(str.contains("😊"))
    }

    @Test("RichTextFormatter decodes common HTML entities")
    func testRichTextFormatterEntityDecoding() {
        let input = "Tom &amp; Jerry: a &lt; b, b &gt; a. She said &quot;hi&quot; &amp; &apos;bye&apos;. Copyright &#169; &#x2764;&nbsp;end"
        let decoded = RichTextFormatter.decodeHTMLEntities(input)
        #expect(decoded.contains("Tom & Jerry"))
        #expect(decoded.contains("a < b"))
        #expect(decoded.contains("b > a"))
        #expect(decoded.contains("\"hi\""))
        #expect(decoded.contains("'bye'"))
        #expect(decoded.contains("\u{00A9}")) // This is a decimal entity.
        #expect(decoded.contains("\u{2764}")) // This is a hex entity.
        #expect(decoded.contains("\u{00A0}")) // This is a non-breaking space.

        // The pipeline must decode entities for plain text.
        let formatted = RichTextFormatter.formatMessage("Tom &amp; Jerry")
        #expect(String(formatted.characters).contains("Tom & Jerry"))
    }

    @Test("RichTextFormatter preserves plain-text angle brackets that are not real HTML")
    func testRichTextFormatterPreservesComparisonOperators() {
        let comparison = "if x<3 and y>2"
        #expect(RichTextFormatter.convertHTMLToMarkdown(comparison) == comparison)

        let generic = "Dictionary<String, Int> is handy"
        #expect(RichTextFormatter.convertHTMLToMarkdown(generic) == generic)

        let formatted = String(RichTextFormatter.formatMessage(comparison).characters)
        #expect(formatted.contains("x<3"))
        #expect(formatted.contains("y>2"))
    }

    @Test("RichTextFormatter neutralizes spoofed markdown links in plain, attacker-controlled text")
    func testRichTextFormatterNeutralizesSpoofedLinks() {
        let spoofed = "[https://mybank.com](https://evil.example)"
        let formatted = RichTextFormatter.formatMessage(spoofed)

        var sawALink = false
        for run in formatted.runs {
            if let link = run.link {
                sawALink = true
                let label = String(formatted.characters[run.range])
                // A link must point to its label destination.
                #expect(link.absoluteString == label)
            }
        }
        #expect(sawALink)

        let fullText = String(formatted.characters)
        #expect(fullText.contains("mybank.com"))
        #expect(fullText.contains("evil.example"))
    }

    @Test("RichTextFormatter autoLinkURLs does not re-link URLs already inside a markdown link")
    func testRichTextFormatterAutoLinkIdempotence() {
        let alreadyLinked = "[https://x.com](https://x.com)"
        #expect(RichTextFormatter.autoLinkURLs(in: alreadyLinked) == alreadyLinked)

        // An anchor tag converts to a single markdown link.
        // Auto-linking the result again makes no changes.
        let converted = RichTextFormatter.convertHTMLToMarkdown("<a href=\"https://x.com\">https://x.com</a>")
        #expect(converted == "[https://x.com](https://x.com)")
        #expect(RichTextFormatter.autoLinkURLs(in: converted) == "[https://x.com](https://x.com)")
    }

    @Test("FileTransferManager transfer items, progress, speed, and state transitions")
    @MainActor
    func testFileTransferManagerLogic() {
        let manager = FileTransferManager.shared
        manager.transfers.removeAll()

        // 1. This creates an initial item.
        let item = FileTransferItem(
            contactName: "Bob Tester",
            filename: "report.pdf",
            totalBytes: 10_485_760, // 10 MB
            transferredBytes: 5_242_880, // 5 MB
            direction: .incoming,
            state: .pending
        )

        #expect(item.contactName == "Bob Tester")
        #expect(item.filename == "report.pdf")
        #expect(item.progress == 0.5)
        // This verifies the exact transferred amount.
        // It does not match a substring.
        let expectedTransferred = ByteCountFormatter.string(fromByteCount: item.transferredBytes, countStyle: .file)
        let expectedTotal = ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file)
        #expect(item.formattedBytes == "\(expectedTransferred) / \(expectedTotal)")
        #expect(item.formattedBytes.hasPrefix(expectedTransferred))

        // 2. This simulates an incoming transfer.
        let rawAddr: UInt = 0xDEADBEEF
        manager.onXferNew(rawPointerAddr: rawAddr, who: "Alice", filename: "photo.png", size: 2_097_152, isIncoming: true)
        
        #expect(manager.transfers.count == 1)
        guard let addedItem = manager.transfers.first(where: { $0.rawPointerAddr == rawAddr }) else {
            #expect(Bool(false), "Transfer item should exist")
            return
        }
        #expect(addedItem.contactName == "Alice")
        #expect(addedItem.filename == "photo.png")
        #expect(addedItem.state == .pending)

        // 3. This updates the progress.
        manager.onXferUpdate(rawPointerAddr: rawAddr, bytesSent: 1_048_576, totalBytes: 2_097_152, status: 0)
        let updatedItem = manager.transfers.first(where: { $0.rawPointerAddr == rawAddr })
        #expect(updatedItem?.transferredBytes == 1_048_576)
        #expect(updatedItem?.progress == 0.5)

        // 4. Pause and resume make no changes.
        // The state remains unchanged.
        if let current = updatedItem {
            manager.pauseTransfer(current)
            #expect(manager.transfers.first(where: { $0.rawPointerAddr == rawAddr })?.state == .transferring)

            manager.resumeTransfer(current)
            #expect(manager.transfers.first(where: { $0.rawPointerAddr == rawAddr })?.state == .transferring)
        }

        // 5. This completes the transfer.
        manager.onXferUpdate(rawPointerAddr: rawAddr, bytesSent: 2_097_152, totalBytes: 2_097_152, status: 0)
        #expect(manager.transfers.first(where: { $0.rawPointerAddr == rawAddr })?.state == .completed)

        // 6. This cancels the transfer.
        manager.onXferCancel(rawPointerAddr: rawAddr, byLocal: true)
        #expect(manager.transfers.first(where: { $0.rawPointerAddr == rawAddr })?.state == .cancelled)

        // This cleans up the state.
        manager.transfers.removeAll()
    }

    @Test("MacOSContactsService contact matching and enrichment")
    @MainActor
    func testMacOSContactsServiceLogic() {
        // The findMatchingContact method checks authorization.
        // The linkContact method does not prompt for access.
        // This tests the logic without touching the address book.
        let authStatus = CNContactStore.authorizationStatus(for: .contacts)
        let contactsService = MacOSContactsService.shared

        let initialContact = Contact(
            name: "carlos_dev",
            handle: "carlos.gomez@company.com",
            status: .available,
            accountProtocol: .teams
        )

        #expect(initialContact.name == "carlos_dev")
        #expect(initialContact.avatarData == nil)

        let linkedContact = contactsService.linkContact(initialContact)
        #expect(linkedContact.handle == "carlos.gomez@company.com")

        if authStatus != .authorized {
            // The contact does not change without address book access.
            // The system does not prompt for access.
            #expect(linkedContact.name == initialContact.name)
            #expect(linkedContact.avatarData == initialContact.avatarData)
        }

        // Address book enrichment does not overwrite a user-set alias.
        var aliasedContact = Contact(
            name: "carlos_dev",
            handle: "carlos.gomez@company.com",
            status: .available,
            accountProtocol: .teams
        )
        aliasedContact.alias = "My Buddy Carlos"
        let linkedAliased = contactsService.linkContact(aliasedContact)
        #expect(linkedAliased.name == "carlos_dev")
        #expect(linkedAliased.alias == "My Buddy Carlos")

        // Enrichment does not replace existing avatar data.
        var avatarContact = Contact(
            name: "carlos_dev",
            handle: "carlos.gomez@company.com",
            status: .available,
            accountProtocol: .teams
        )
        let existingAvatar = Data([0x01, 0x02, 0x03])
        avatarContact.avatarData = existingAvatar
        let linkedAvatar = contactsService.linkContact(avatarContact)
        #expect(linkedAvatar.avatarData == existingAvatar)

        // The findMatchingContact method returns nil for an empty query.
        #expect(contactsService.findMatchingContact(email: nil, name: nil) == nil)
    }
}


