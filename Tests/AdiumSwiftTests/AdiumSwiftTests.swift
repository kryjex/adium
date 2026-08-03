import Testing
import Foundation
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
        // Clean initial state, no fake mocks
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

        // 1. Connect account (persists to UserDefaults & Keychain)
        bridge.connectAccount(username: username, protocolType: proto, password: password)

        let accountKey = "\(username):\(proto.purpleProtocolID)"
        #expect(KeychainHelper.fetchPassword(for: accountKey) == password)

        // 2. Clear in-memory accounts array and restore from saved defaults
        bridge.accounts.removeAll()
        #expect(bridge.accounts.isEmpty)

        bridge.restoreSavedAccounts()
        guard let restoredAcc = bridge.accounts.first(where: { $0.username == username }) else {
            #expect(Bool(false), "Restored accounts should contain persist.user@test.com")
            return
        }

        #expect(restoredAcc.username == username)
        #expect(restoredAcc.accountProtocol == proto)

        // 3. Clean up
        bridge.removeAccount(restoredAcc)
        bridge.accounts.removeAll()
        bridge.restoreSavedAccounts()
        #expect(!bridge.accounts.contains(where: { $0.username == username }))
    }

    @Test("Notification triggering")
    @MainActor
    func testNotificationTriggering() {
        let notifService = NotificationService.shared
        
        // 1. Test direct notification service call
        notifService.notifyIncomingMessage(sender: "Alice", content: "Direct notification test")
        #expect(notifService.lastNotification?.sender == "Alice")
        #expect(notifService.lastNotification?.content == "Direct notification test")

        let notifServiceAlias = NotificationService.shared
        notifServiceAlias.notifyIncomingMessage(senderName: "Bob", messageText: "Alias method test")
        #expect(notifServiceAlias.lastNotification?.sender == "Bob")
        #expect(notifServiceAlias.lastNotification?.content == "Alias method test")

        // 2. Test incoming message triggers notification via PurpleBridgeService
        let bridge = PurpleBridgeService.shared
        let senderHandle = "notifier.sender@test.com"
        let contact = Contact(name: "Notifier Sender", handle: senderHandle, status: .available, accountProtocol: .teams)
        bridge.contacts.append(contact)

        let incomingText = "Hello via incoming message!"
        bridge.onMessageReceived(senderHandle: senderHandle, text: incomingText, isFromMe: false)

        #expect(notifService.lastNotification?.sender == "Notifier Sender")
        #expect(notifService.lastNotification?.content == incomingText)

        // 3. Test outgoing message (isFromMe: true) does NOT update incoming notification state
        let outgoingText = "My outgoing response"
        bridge.onMessageReceived(senderHandle: senderHandle, text: outgoingText, isFromMe: true)
        #expect(notifService.lastNotification?.content != outgoingText)

        // Cleanup
        bridge.contacts.removeAll(where: { $0.handle == senderHandle })
    }

    @Test("Unknown sender auto-creation logic")
    @MainActor
    func testUnknownSenderAutoCreation() {
        let bridge = PurpleBridgeService.shared
        let unknownHandle = "unknown.sender.auto@domain.org"

        // Ensure contact is not present beforehand
        bridge.contacts.removeAll(where: { $0.handle == unknownHandle })

        // Trigger incoming message from unknown sender
        let messageText = "Auto-created sender message"
        bridge.onMessageReceived(senderHandle: unknownHandle, text: messageText, isFromMe: false)

        // Verify contact was auto-created on-the-fly
        guard let newContact = bridge.contacts.first(where: { $0.handle == unknownHandle }) else {
            #expect(Bool(false), "Unknown sender contact should have been automatically created")
            return
        }

        #expect(newContact.name == unknownHandle)
        #expect(newContact.handle == unknownHandle)
        #expect(newContact.group == "General")
        #expect(newContact.status == .available)

        // Verify message was stored
        let msgs = bridge.messages(for: newContact)
        #expect(msgs.contains(where: { $0.text == messageText }))

        // Cleanup
        bridge.contacts.removeAll(where: { $0.handle == unknownHandle })
    }

    @Test("ChatLogStore handle indexing and UUID fallback")
    @MainActor
    func testChatLogStoreIndexingAndUUIDFallback() {
        let store = ChatLogStore.shared

        // 1. Handle indexing with special characters
        let specialHandle = "user+special.handle_123@domain-test.com"
        let handleMsgs = [ChatMessage(senderName: "Tester", isFromMe: false, text: "Special handle text")]
        store.saveMessages(handleMsgs, for: specialHandle)

        let loadedHandleMsgs = store.loadMessages(for: specialHandle)
        #expect(loadedHandleMsgs?.count == 1)
        #expect(loadedHandleMsgs?.first?.text == "Special handle text")

        // 2. Legacy UUID fallback indexing
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

        // 1. Simulate account connected event
        bridge.onAccountStateChanged(username: username, protocolId: proto.purpleProtocolID, isConnected: true, statusMsg: "Conectado")

        guard let connectedAcc = bridge.accounts.first(where: { $0.username == username }) else {
            #expect(Bool(false), "Account should exist")
            return
        }
        #expect(connectedAcc.isConnected == true)
        #expect(connectedAcc.connectionError == nil)

        // 2. Simulate account error event
        bridge.onAccountStateChanged(username: username, protocolId: proto.purpleProtocolID, isConnected: false, statusMsg: "Error de Autenticación")

        guard let erroredAcc = bridge.accounts.first(where: { $0.username == username }) else {
            #expect(Bool(false), "Account should exist")
            return
        }
        #expect(erroredAcc.isConnected == false)
        #expect(erroredAcc.connectionError == "Error de Autenticación")

        // Cleanup
        bridge.removeAccount(erroredAcc)
    }
}

