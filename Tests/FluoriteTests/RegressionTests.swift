import Testing
import Foundation
@testable import Fluorite

/// These are regression tests for bug fixes.
/// A test will fail if its bug fix is reverted.
@Suite("Regression Tests for Recent Bug Fixes")
struct RegressionTests {

    // MARK: - 1. Backward-compatible decoding (Models.swift)

    @Test("Account decodes old-shape JSON missing the newer customOptions key")
    func testAccountDecodesOldJSONWithoutCustomOptions() throws {
        // This mimics JSON from an older build.
        let oldJSON: [String: Any] = [
            "id": UUID().uuidString,
            "username": "legacy.user@test.com",
            "accountProtocol": AccountProtocol.teams.rawValue,
            "isConnected": true
        ]
        let data = try JSONSerialization.data(withJSONObject: oldJSON)
        let decoded = try JSONDecoder().decode(Account.self, from: data)

        #expect(decoded.username == "legacy.user@test.com")
        #expect(decoded.accountProtocol == .teams)
        #expect(decoded.isConnected == true)
        #expect(decoded.connectionError == nil)
        #expect(decoded.server == nil)
        #expect(decoded.port == nil)
        #expect(decoded.resource == nil)
        #expect(decoded.useSSL == nil)
        #expect(decoded.customOptions == [:])
    }

    @Test("Account encode-decode roundtrip preserves a fully-populated value")
    func testAccountRoundtripFullyPopulated() throws {
        let account = Account(
            username: "roundtrip.user@test.com",
            accountProtocol: .xmpp,
            isConnected: true,
            connectionError: "oops",
            server: "xmpp.example.com",
            port: 5222,
            resource: "Adium",
            useSSL: true,
            customOptions: ["connect_server": "custom.example.com", "foo": "bar"]
        )
        let data = try JSONEncoder().encode(account)
        let decoded = try JSONDecoder().decode(Account.self, from: data)
        #expect(decoded == account)
    }

    @Test("Contact decodes old-shape JSON missing isBlocked/isTyping/isGroupChat/groupParticipants")
    func testContactDecodesOldJSONWithoutNewerKeys() throws {
        // This mimics JSON from an older build.
        let oldJSON: [String: Any] = [
            "id": UUID().uuidString,
            "name": "Legacy Contact",
            "handle": "legacy.contact@test.com",
            "status": OnlineStatus.available.rawValue,
            "group": "General",
            "accountProtocol": AccountProtocol.teams.rawValue
        ]
        let data = try JSONSerialization.data(withJSONObject: oldJSON)
        let decoded = try JSONDecoder().decode(Contact.self, from: data)

        #expect(decoded.name == "Legacy Contact")
        #expect(decoded.handle == "legacy.contact@test.com")
        #expect(decoded.status == .available)
        #expect(decoded.group == "General")
        #expect(decoded.accountProtocol == .teams)
        #expect(decoded.isBlocked == false)
        #expect(decoded.isTyping == false)
        #expect(decoded.isGroupChat == false)
        #expect(decoded.groupParticipants == [])
    }

    @Test("Contact encode-decode roundtrip preserves a fully-populated value")
    func testContactRoundtripFullyPopulated() throws {
        let participant = GroupParticipant(name: "Participant One", handle: "p1@test.com", status: .away, role: "Member")
        let contact = Contact(
            name: "Full Contact",
            handle: "full.contact@test.com",
            status: .busy,
            customStatusMessage: "In a meeting",
            group: "Work",
            accountProtocol: .matrix,
            avatarURL: URL(string: "https://example.com/avatar.png"),
            accountUsername: "owner@test.com",
            alias: "Buddy",
            isBlocked: true,
            metacontactID: UUID(),
            avatarData: Data([0x01, 0x02]),
            isTyping: true,
            isGroupChat: true,
            groupParticipants: [participant],
            topic: "Weekly Sync"
        )
        let data = try JSONEncoder().encode(contact)
        let decoded = try JSONDecoder().decode(Contact.self, from: data)
        #expect(decoded == contact)
    }

    // MARK: - 2. Account routing (PurpleBridgeService.resolveAccount)

    @Test("resolveAccount routes to the named account among two same-protocol accounts")
    @MainActor
    func testResolveAccountRoutesToNamedAccountAmongSameProtocol() {
        let bridge = PurpleBridgeService.shared
        let accA = Account(username: "route.a@test.com", accountProtocol: .teams)
        let accB = Account(username: "route.b@test.com", accountProtocol: .teams)
        bridge.accounts.append(contentsOf: [accA, accB])
        defer { bridge.accounts.removeAll(where: { $0.id == accA.id || $0.id == accB.id }) }

        let contactForB = Contact(name: "Routed To B", handle: "routed@test.com", status: .available, accountProtocol: .teams, accountUsername: accB.username)
        let resolved = bridge.resolveAccount(for: contactForB)
        #expect(resolved?.id == accB.id)
        #expect(resolved?.username == accB.username)
    }

    @Test("resolveAccount falls back to a protocol match when accountUsername is nil")
    @MainActor
    func testResolveAccountFallsBackToProtocolMatchWhenUsernameNil() {
        let bridge = PurpleBridgeService.shared
        let acc = Account(username: "fallback.only@test.com", accountProtocol: .xmpp)
        bridge.accounts.append(acc)
        defer { bridge.accounts.removeAll(where: { $0.id == acc.id }) }

        let contactNoUsername = Contact(name: "No Username", handle: "nouser@test.com", status: .available, accountProtocol: .xmpp, accountUsername: nil)
        let resolved = bridge.resolveAccount(for: contactNoUsername)
        #expect(resolved?.accountProtocol == .xmpp)
    }

    @Test("resolveAccount returns nil (never a wrong account) when accountUsername matches nothing")
    @MainActor
    func testResolveAccountReturnsNilForUnknownAccountUsername() {
        let bridge = PurpleBridgeService.shared
        let acc = Account(username: "real.account@test.com", accountProtocol: .teams)
        bridge.accounts.append(acc)
        defer { bridge.accounts.removeAll(where: { $0.id == acc.id }) }

        let contactWithBogusUsername = Contact(name: "Bogus", handle: "bogus@test.com", status: .available, accountProtocol: .teams, accountUsername: "nonexistent.user@test.com")
        let resolved = bridge.resolveAccount(for: contactWithBogusUsername)
        #expect(resolved == nil)
    }

    // MARK: - 3. Badge single-increment (EventManager + PurpleBridgeService.onMessageReceived)

    @Test("EventManager.triggerEvent no longer mutates the unread badge count")
    @MainActor
    func testTriggerEventDoesNotChangeUnreadCount() {
        let eventMgr = EventManager.shared
        let previousCount = eventMgr.unreadCount
        defer { eventMgr.setUnreadCount(previousCount) }

        eventMgr.setUnreadCount(11)
        eventMgr.triggerEvent(.messageReceived, title: "Badge Test", content: "Should not touch the badge")
        #expect(eventMgr.unreadCount == 11)

        eventMgr.triggerEvent(.messageSent, title: "Badge Test 2", content: "Also should not touch the badge")
        #expect(eventMgr.unreadCount == 11)
    }

    @Test("Incoming message increments the badge total by exactly one, not twice")
    @MainActor
    func testOnMessageReceivedIncrementsBadgeExactlyOnce() {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        let bridge = PurpleBridgeService.shared
        let eventMgr = EventManager.shared
        let handle = "badge.once@test.com"
        let contact = Contact(name: "Badge Once", handle: handle, status: .available, accountProtocol: .teams)
        bridge.contacts.append(contact)
        bridge.unreadCounts[contact.id] = 0
        defer {
            bridge.contacts.removeAll(where: { $0.handle == handle })
            bridge.unreadCounts.removeValue(forKey: contact.id)
        }

        // Sync the badge with the current unreadCounts totals first.
        // Other tests leave stale entries that would skew the baseline.
        bridge.markAsRead(for: contact.id)
        let baseline = eventMgr.unreadCount
        bridge.onMessageReceived(senderHandle: handle, text: "Incoming badge test", isFromMe: false)

        // The unread count of the contact must increase by one.
        // The total badge count must increase by one.
        // The triggerEvent must not increase the count again.
        #expect(eventMgr.unreadCount == baseline + 1)
    }

    // MARK: - 4. Blocking (PurpleBridgeService)

    @Test("Incoming message from a blocked contact is dropped: no in-memory message, no chat log entry")
    @MainActor
    func testBlockedContactDropsIncomingMessage() {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        let bridge = PurpleBridgeService.shared
        let handle = "blocked.incoming@test.com"
        let contact = Contact(name: "Blocked Incoming", handle: handle, status: .available, accountProtocol: .teams)
        bridge.contacts.append(contact)
        defer { bridge.contacts.removeAll(where: { $0.handle == handle }) }

        bridge.toggleBlockContact(contact.id)
        #expect(bridge.contacts.first(where: { $0.handle == handle })?.isBlocked == true)

        let spamText = "You've won a prize! Click here."
        bridge.onMessageReceived(senderHandle: handle, text: spamText, isFromMe: false)

        guard let blockedContact = bridge.contacts.first(where: { $0.handle == handle }) else {
            #expect(Bool(false), "Contact should still exist")
            return
        }
        #expect(!bridge.messages(for: blockedContact).contains(where: { $0.text == spamText }))
        #expect(store.loadMessages(for: handle)?.contains(where: { $0.text == spamText }) != true)
    }

    @Test("sendMessage refuses to send to a blocked contact; no message is appended")
    @MainActor
    func testSendMessageRefusesForBlockedContact() {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        let bridge = PurpleBridgeService.shared
        let handle = "blocked.outgoing@test.com"
        let contact = Contact(name: "Blocked Outgoing", handle: handle, status: .available, accountProtocol: .teams)
        bridge.contacts.append(contact)
        defer { bridge.contacts.removeAll(where: { $0.handle == handle }) }

        bridge.toggleBlockContact(contact.id)
        guard let blockedContact = bridge.contacts.first(where: { $0.handle == handle }) else {
            #expect(Bool(false), "Contact should still exist")
            return
        }
        #expect(blockedContact.isBlocked == true)

        let outgoingText = "Are you there?"
        bridge.sendMessage(outgoingText, to: blockedContact)

        #expect(!bridge.messages(for: blockedContact).contains(where: { $0.text == outgoingText }))
        #expect(store.loadMessages(for: handle)?.contains(where: { $0.text == outgoingText }) != true)
        // The expected text goes through t() so the test passes in every locale.
        #expect(bridge.connectionState == t("Cannot send: \(blockedContact.displayName) is blocked"))
    }

    // MARK: - 5. Metacontact re-combining

    @Test("combineContacts: re-combining a shared member dissolves the old metacontact and clears its stale reference")
    @MainActor
    func testMetacontactRecombiningDissolvesOldGroup() {
        let bridge = PurpleBridgeService.shared
        let a = Contact(name: "Recombine A", handle: "recombine.a@test.com", status: .available, accountProtocol: .teams)
        let b = Contact(name: "Recombine B", handle: "recombine.b@test.com", status: .available, accountProtocol: .whatsapp)
        let c = Contact(name: "Recombine C", handle: "recombine.c@test.com", status: .available, accountProtocol: .xmpp)
        bridge.contacts.append(contentsOf: [a, b, c])
        defer {
            let ids: Set<UUID> = [a.id, b.id, c.id]
            bridge.contacts.removeAll(where: { ids.contains($0.id) })
            bridge.metacontacts.removeAll(where: { meta in meta.contactIDs.contains(where: { ids.contains($0) }) })
        }

        let metaAB = bridge.combineContacts([a.id, b.id], name: "AB Combined")
        #expect(bridge.contacts.first(where: { $0.id == a.id })?.metacontactID == metaAB.id)
        #expect(bridge.contacts.first(where: { $0.id == b.id })?.metacontactID == metaAB.id)

        let metaBC = bridge.combineContacts([b.id, c.id], name: "BC Combined")

        // The old AB metacontact drops to a single member.
        // The system dissolves it.
        // The system clears the old metacontactID for A.
        #expect(bridge.contacts.first(where: { $0.id == a.id })?.metacontactID == nil)

        // B must belong to the new BC metacontact.
        #expect(bridge.metacontacts.first(where: { $0.id == metaBC.id })?.contactIDs.contains(b.id) == true)
        #expect(bridge.contacts.first(where: { $0.id == b.id })?.metacontactID == metaBC.id)
        #expect(!bridge.metacontacts.contains(where: { $0.id != metaBC.id && $0.contactIDs.contains(b.id) }))

        #expect(bridge.contacts.first(where: { $0.id == c.id })?.metacontactID == metaBC.id)
    }

    // MARK: - 6. renameGroup duplicate guard

    @Test("renameGroup refuses to create a duplicate when the target name already exists (case-insensitive)")
    @MainActor
    func testRenameGroupRefusesDuplicateNameCaseInsensitive() {
        let bridge = PurpleBridgeService.shared
        let groupsDefaultsKey = "AdiumSavedGroups"
        let previousGroupsData = UserDefaults.standard.object(forKey: groupsDefaultsKey)
        let previousGroups = bridge.contactGroups
        defer {
            bridge.contactGroups = previousGroups
            if let previousGroupsData {
                UserDefaults.standard.set(previousGroupsData, forKey: groupsDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: groupsDefaultsKey)
            }
        }

        let nameOne = "RenameDupOne_\(UUID().uuidString.prefix(8))"
        let nameTwo = "RenameDupTwo_\(UUID().uuidString.prefix(8))"
        bridge.createGroup(name: nameOne)
        bridge.createGroup(name: nameTwo)
        #expect(bridge.contactGroups.filter({ $0.name == nameOne }).count == 1)
        #expect(bridge.contactGroups.filter({ $0.name == nameTwo }).count == 1)

        // This renames nameOne to nameTwo with different casing.
        // The system refuses this.
        // Both original groups must exist.
        bridge.renameGroup(oldName: nameOne, newName: nameTwo.uppercased())

        #expect(bridge.contactGroups.contains(where: { $0.name == nameOne }))
        #expect(bridge.contactGroups.filter({ $0.name.caseInsensitiveCompare(nameTwo) == .orderedSame }).count == 1)
    }

    @Test("renameGroup renaming a group to its own current name is a no-op")
    @MainActor
    func testRenameGroupToSameNameIsNoOp() {
        let bridge = PurpleBridgeService.shared
        let groupsDefaultsKey = "AdiumSavedGroups"
        let previousGroupsData = UserDefaults.standard.object(forKey: groupsDefaultsKey)
        let previousGroups = bridge.contactGroups
        defer {
            bridge.contactGroups = previousGroups
            if let previousGroupsData {
                UserDefaults.standard.set(previousGroupsData, forKey: groupsDefaultsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: groupsDefaultsKey)
            }
        }

        let name = "RenameSame_\(UUID().uuidString.prefix(8))"
        bridge.createGroup(name: name)
        let countBefore = bridge.contactGroups.count

        bridge.renameGroup(oldName: name, newName: name)

        #expect(bridge.contactGroups.count == countBefore)
        #expect(bridge.contactGroups.filter({ $0.name == name }).count == 1)
    }

    // MARK: - 7. Single transfer row per outgoing send (FileTransferManager)

    @Test("sendFile never pre-appends a row; onXferNew is the single source for a transfer")
    @MainActor
    func testFileTransferSendFileDoesNotPreAppendRow() {
        let manager = FileTransferManager.shared
        let bridge = PurpleBridgeService.shared

        let previousLibpurpleLoaded = bridge.isLibpurpleLoaded
        bridge.isLibpurpleLoaded = false
        defer { bridge.isLibpurpleLoaded = previousLibpurpleLoaded }

        let contact = Contact(name: "NoPreAppend", handle: "nopre@test.com", status: .available, accountProtocol: .teams)
        let countBefore = manager.transfers.count

        // The sendFile function returns immediately.
        // It does not change the transfers.
        // This prevents an eager append of a pending row.
        manager.sendFile(to: contact, at: URL(fileURLWithPath: "/tmp/does-not-matter.txt"))
        #expect(manager.transfers.count == countBefore)

        // This simulates the real flow. Only onXferNew creates the row.
        let rawAddr = UInt.random(in: 1...UInt.max)
        manager.onXferNew(rawPointerAddr: rawAddr, who: "NoPreAppend", filename: "report.pdf", size: 1000, isIncoming: false)
        defer { manager.transfers.removeAll(where: { $0.rawPointerAddr == rawAddr }) }

        #expect(manager.transfers.filter({ $0.rawPointerAddr == rawAddr }).count == 1)
    }

    @Test("A cancelled transfer never flips back to completed on a late progress update")
    @MainActor
    func testFileTransferCancelledStateIsSticky() {
        let manager = FileTransferManager.shared
        let rawAddr = UInt.random(in: 1...UInt.max)
        manager.onXferNew(rawPointerAddr: rawAddr, who: "StickyTest", filename: "video.mp4", size: 5000, isIncoming: true)
        defer { manager.transfers.removeAll(where: { $0.rawPointerAddr == rawAddr }) }

        manager.onXferCancel(rawPointerAddr: rawAddr, byLocal: true)
        #expect(manager.transfers.first(where: { $0.rawPointerAddr == rawAddr })?.state == .cancelled)

        // A late progress update must not resurrect a complete transfer.
        manager.onXferUpdate(rawPointerAddr: rawAddr, bytesSent: 5000, totalBytes: 5000, status: 0)
        #expect(manager.transfers.first(where: { $0.rawPointerAddr == rawAddr })?.state == .cancelled)
    }

    @Test("onXferDestroyed marks a non-terminal transfer failed and clears rawPointerAddr")
    @MainActor
    func testFileTransferOnXferDestroyedMarksNonTerminalFailed() {
        let manager = FileTransferManager.shared
        let rawAddr = UInt.random(in: 1...UInt.max)
        manager.onXferNew(rawPointerAddr: rawAddr, who: "DestroyTest", filename: "img.png", size: 2000, isIncoming: true)

        guard let newItem = manager.transfers.first(where: { $0.rawPointerAddr == rawAddr }) else {
            #expect(Bool(false), "Transfer item should have been created")
            return
        }
        let itemID = newItem.id
        defer { manager.transfers.removeAll(where: { $0.id == itemID }) }

        manager.onXferUpdate(rawPointerAddr: rawAddr, bytesSent: 500, totalBytes: 2000, status: 0)
        #expect(manager.transfers.first(where: { $0.id == itemID })?.state == .transferring)

        manager.onXferDestroyed(rawPointerAddr: rawAddr)

        guard let destroyed = manager.transfers.first(where: { $0.id == itemID }) else {
            #expect(Bool(false), "Transfer item should still exist after being destroyed")
            return
        }
        #expect(destroyed.state == .failed)
        #expect(destroyed.rawPointerAddr == nil)
    }

    // MARK: - 8. Transcript filters (ChatLogStore.filterMessages)

    @Test("filterMessages end-date filter is inclusive of the entire day, not just up to the given time")
    @MainActor
    func testFilterMessagesEndDateIsInclusiveOfWholeDay() {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        // This uses a time late in the day.
        let lateInDay = startOfToday.addingTimeInterval(23 * 3600 + 59 * 60)
        let earlyTimeSameDay = startOfToday.addingTimeInterval(8 * 3600)

        let handle = "endday.alice@test.com"
        let msgLate = ChatMessage(senderName: "Alice", isFromMe: false, text: "Late night message", timestamp: lateInDay)
        store.saveMessages([msgLate], for: handle)

        let contactAlice = Contact(name: "Alice EndDay", handle: handle, status: .available, accountProtocol: .teams)

        // The end-date filter includes the whole day.
        // It includes messages from later in the same day.
        let endDateResults = store.filterMessages(endDate: earlyTimeSameDay, contacts: [contactAlice])
        let matchingHandle = endDateResults.first(where: { $0.handle == store.sanitizeHandle(handle) })
        #expect(matchingHandle != nil)
        #expect(matchingHandle?.messages.contains(where: { $0.text == "Late night message" }) == true)
    }

    @Test("filterMessages excludes a log with no matching Contact when a protocol filter is active, includes it otherwise")
    @MainActor
    func testFilterMessagesProtocolFilterExcludesUnmatchedHandle() {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        // This handle has no corresponding Contact.
        // The system cannot determine its protocol.
        let orphanHandle = "orphan.ghost@test.com"
        let msgOrphan = ChatMessage(senderName: "Ghost", isFromMe: false, text: "Orphan protocol message")
        store.saveMessages([msgOrphan], for: orphanHandle)

        let knownContact = Contact(name: "Known Contact", handle: "known.contact@test.com", status: .available, accountProtocol: .teams)

        // A protocol filter excludes a log with no known protocol.
        let protoFilteredResults = store.filterMessages(protocolType: .whatsapp, contacts: [knownContact])
        #expect(!protoFilteredResults.contains(where: { $0.handle == store.sanitizeHandle(orphanHandle) }))

        // The system includes the log if there is no filter.
        let unfilteredResults = store.filterMessages(contacts: [knownContact])
        #expect(unfilteredResults.contains(where: { $0.handle == store.sanitizeHandle(orphanHandle) }))
    }

    // MARK: - libpurple accounts.xml import

    @Test("parsePurpleAccountsXML imports known protocols and migrates the retired prpl-teams ID")
    func testParsePurpleAccountsXMLImportAndMigration() {
        let xml = """
        <?xml version='1.0' encoding='UTF-8' ?>
        <account version='1.0'>
            <account>
                <protocol>prpl-teams</protocol>
                <name>jane@example.com</name>
            </account>
            <account>
                <protocol>prpl-jabber</protocol>
                <name>jane@jabber.org/Adium</name>
            </account>
            <account>
                <protocol>prpl-unknown-thing</protocol>
                <name>ignored@example.com</name>
            </account>
        </account>
        """
        let imported = PurpleBridgeService.parsePurpleAccountsXML(xml)

        // The prpl-teams ID maps to .teams.
        // The new ID is prpl-eionrobb-msteams.
        #expect(imported.contains(where: { $0.username == "jane@example.com" && $0.accountProtocol == .teams }))
        #expect(imported.contains(where: { $0.username == "jane@jabber.org/Adium" && $0.accountProtocol == .xmpp }))
        // The system skips unknown protocol IDs.
        #expect(!imported.contains(where: { $0.username == "ignored@example.com" }))
        #expect(imported.count == 2)
    }

    @Test("parsePurpleAccountsXML deduplicates and tolerates malformed input")
    func testParsePurpleAccountsXMLEdgeCases() {
        #expect(PurpleBridgeService.parsePurpleAccountsXML("").isEmpty)
        #expect(PurpleBridgeService.parsePurpleAccountsXML("<account><name>no-protocol</name></account>").isEmpty)

        let duplicated = """
        <account><protocol>prpl-hehoe-whatsmeow</protocol><name>+51999999999</name></account>
        <account><protocol>prpl-hehoe-whatsmeow</protocol><name>+51999999999</name></account>
        """
        let imported = PurpleBridgeService.parsePurpleAccountsXML(duplicated)
        #expect(imported.count == 1)
        #expect(imported.first?.accountProtocol == .whatsapp)
    }

    // MARK: - 9. Group chat roster sync (onChatBuddyJoined/onChatBuddyLeft)

    @Test("onChatBuddyJoined adds a participant to the matching room, deduping by handle, regardless of newArrival")
    @MainActor
    func testOnChatBuddyJoinedAddsAndDedupes() {
        let bridge = PurpleBridgeService.shared
        let account = Account(username: "roster.owner@teams.com", accountProtocol: .teams)
        bridge.accounts.append(account)
        let room = bridge.joinGroupChat(channelName: "Roster Room \(UUID().uuidString.prefix(6))", account: account)
        defer {
            bridge.leaveGroupChat(room.id)
            bridge.removeAccount(account)
        }

        // The system adds initial roster items.
        bridge.onChatBuddyJoined(roomName: room.handle, buddyName: "existing.member@teams.com", newArrival: false)
        let afterInitial = bridge.contacts.first(where: { $0.id == room.id })
        #expect(afterInitial?.groupParticipants.contains(where: { $0.handle == "existing.member@teams.com" }) == true)

        // The system adds a new join.
        bridge.onChatBuddyJoined(roomName: room.handle, buddyName: "new.joiner@teams.com", newArrival: true)
        let afterJoin = bridge.contacts.first(where: { $0.id == room.id })
        #expect(afterJoin?.groupParticipants.contains(where: { $0.handle == "new.joiner@teams.com" }) == true)
        let countAfterJoin = afterJoin?.groupParticipants.count ?? 0

        // The system does not duplicate the entry.
        bridge.onChatBuddyJoined(roomName: room.handle, buddyName: "new.joiner@teams.com", newArrival: false)
        let afterDuplicate = bridge.contacts.first(where: { $0.id == room.id })
        #expect(afterDuplicate?.groupParticipants.count == countAfterJoin)
    }

    @Test("onChatBuddyLeft removes only the matching participant from the matching room")
    @MainActor
    func testOnChatBuddyLeftRemovesParticipant() {
        let bridge = PurpleBridgeService.shared
        let account = Account(username: "roster.leave.owner@teams.com", accountProtocol: .teams)
        bridge.accounts.append(account)
        let room = bridge.joinGroupChat(channelName: "Leave Room \(UUID().uuidString.prefix(6))", account: account)
        defer {
            bridge.leaveGroupChat(room.id)
            bridge.removeAccount(account)
        }

        bridge.onChatBuddyJoined(roomName: room.handle, buddyName: "staying.member@teams.com", newArrival: true)
        bridge.onChatBuddyJoined(roomName: room.handle, buddyName: "leaving.member@teams.com", newArrival: true)
        let beforeLeave = bridge.contacts.first(where: { $0.id == room.id })
        #expect(beforeLeave?.groupParticipants.contains(where: { $0.handle == "leaving.member@teams.com" }) == true)
        #expect(beforeLeave?.groupParticipants.contains(where: { $0.handle == "staying.member@teams.com" }) == true)

        bridge.onChatBuddyLeft(roomName: room.handle, buddyName: "leaving.member@teams.com")
        let afterLeave = bridge.contacts.first(where: { $0.id == room.id })
        #expect(afterLeave?.groupParticipants.contains(where: { $0.handle == "leaving.member@teams.com" }) == false)
        #expect(afterLeave?.groupParticipants.contains(where: { $0.handle == "staying.member@teams.com" }) == true)
    }

    @Test("onChatBuddyJoined/Left are no-ops for a room handle with no matching group chat Contact")
    @MainActor
    func testOnChatBuddyEventsIgnoreUnknownRoom() {
        let bridge = PurpleBridgeService.shared
        let unknownRoom = "unknown.room.\(UUID().uuidString)@conference.example.com"
        let countBefore = bridge.contacts.count

        bridge.onChatBuddyJoined(roomName: unknownRoom, buddyName: "someone@teams.com", newArrival: true)
        bridge.onChatBuddyLeft(roomName: unknownRoom, buddyName: "someone@teams.com")

        // The system does not create a new contact.
        #expect(bridge.contacts.count == countBefore)
    }

    // MARK: - 10. Custom status message persistence (PurpleBridgeService.setStatusMessage)

    @Test("setStatusMessage updates myStatusMessage, trims whitespace, and persists to UserDefaults")
    @MainActor
    func testSetStatusMessagePersistsToUserDefaults() {
        let bridge = PurpleBridgeService.shared
        let key = "AdiumStatusMessage"
        let previousValue = UserDefaults.standard.string(forKey: key)
        let previousMessage = bridge.myStatusMessage
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
            bridge.myStatusMessage = previousMessage
        }

        bridge.setStatusMessage("  En una reunión  ")
        #expect(bridge.myStatusMessage == "En una reunión")
        #expect(UserDefaults.standard.string(forKey: key) == "En una reunión")

        bridge.setStatusMessage("")
        #expect(bridge.myStatusMessage == "")
        #expect(UserDefaults.standard.string(forKey: key) == "")
    }

    // MARK: - 11. FileTransferManager.lastErrorMessage lifecycle

    @Test("sendFile without a resolvable account sets lastErrorMessage; clearError resets it")
    @MainActor
    func testFileTransferLastErrorMessageLifecycle() {
        let manager = FileTransferManager.shared
        let bridge = PurpleBridgeService.shared

        let previousLibpurpleLoaded = bridge.isLibpurpleLoaded
        bridge.isLibpurpleLoaded = true
        defer { bridge.isLibpurpleLoaded = previousLibpurpleLoaded }

        manager.clearError()
        #expect(manager.lastErrorMessage == nil)

        // No account exists for this combination.
        // The sendFile function shows an error.
        let contact = Contact(name: "No Account", handle: "no.account@test.com", status: .available, accountProtocol: .teams, accountUsername: "nonexistent.owner@test.com")
        manager.sendFile(to: contact, at: URL(fileURLWithPath: "/tmp/does-not-matter.txt"))

        #expect(manager.lastErrorMessage != nil)
        #expect(manager.lastErrorMessage?.contains("No Account") == true)

        manager.clearError()
        #expect(manager.lastErrorMessage == nil)
    }

    // MARK: - 12. Deleted accounts must stay deleted (legacy accounts.xml import guard)

    @Test("restoreSavedAccounts does not resurrect deleted accounts from accounts.xml")
    @MainActor
    func testLegacyImportDoesNotResurrectDeletedAccounts() throws {
        let bridge = PurpleBridgeService.shared
        let defaults = UserDefaults.standard
        let savedKey = "AdiumSavedAccounts"
        let flagKey = "AdiumImportedLegacyPurpleAccounts"

        let prevSaved = defaults.data(forKey: savedKey)
        let prevFlag = defaults.object(forKey: flagKey)
        let prevAccounts = bridge.accounts
        defer {
            if let prevSaved {
                defaults.set(prevSaved, forKey: savedKey)
            } else {
                defaults.removeObject(forKey: savedKey)
            }
            if prevFlag == nil { defaults.removeObject(forKey: flagKey) }
            bridge.accounts = prevAccounts
        }

        // The user deleted their last account.
        // The system saves an empty list.
        // The system must not read accounts.xml again.
        defaults.set(try JSONEncoder().encode([Account]()), forKey: savedKey)
        defaults.removeObject(forKey: flagKey)
        bridge.accounts = []

        bridge.restoreSavedAccounts()

        #expect(bridge.accounts.isEmpty)
    }

    // MARK: - 13. Duplicate contacts sharing a handle collapse into one (wrong-protocol dupes)

    @Test("dedupeContactsByHandle keeps the newest contact and preserves user customizations from the older duplicate")
    func testDedupeContactsByHandle() {
        // The Logon QR Code was in Teams.
        // It was then in WhatsApp.
        // The system merges them into one.
        let stale = Contact(
            name: "Logon QR Code", handle: "Logon QR Code", status: .available,
            accountProtocol: .teams, alias: "Vinculación WhatsApp", isBlocked: true
        )
        let fresh = Contact(
            name: "Logon QR Code", handle: "Logon QR Code", status: .available,
            accountProtocol: .whatsapp
        )
        let other = Contact(name: "Alice", handle: "alice@test.com", status: .available)

        let deduped = PurpleBridgeService.dedupeContactsByHandle([stale, other, fresh])

        #expect(deduped.count == 2)
        let merged = deduped.first(where: { $0.handle == "Logon QR Code" })
        #expect(merged?.accountProtocol == .whatsapp)
        #expect(merged?.alias == "Vinculación WhatsApp")
        #expect(merged?.isBlocked == true)
        #expect(deduped.contains(where: { $0.handle == "alice@test.com" }))
    }

    // MARK: - WhatsApp username normalization
    // purple-gowhatsapp requires "<digits>@s.whatsapp.net" as the username.
    // The app normalizes instead of patching the plugin's JID comparisons.

    @Test("canonicalUsername converts phone formats to the canonical WhatsApp JID")
    func testWhatsAppCanonicalUsername() {
        #expect(AccountProtocol.whatsapp.canonicalUsername("+34600000000") == "34600000000@s.whatsapp.net")
        #expect(AccountProtocol.whatsapp.canonicalUsername("+34 600 00 00 00") == "34600000000@s.whatsapp.net")
        #expect(AccountProtocol.whatsapp.canonicalUsername("34600000000") == "34600000000@s.whatsapp.net")
        #expect(AccountProtocol.whatsapp.canonicalUsername("34600000000@s.whatsapp.net") == "34600000000@s.whatsapp.net")
        #expect(AccountProtocol.whatsapp.canonicalUsername("   ") == "")
        // Other protocols pass through unchanged.
        #expect(AccountProtocol.teams.canonicalUsername("user@example.com") == "user@example.com")
        #expect(AccountProtocol.xmpp.canonicalUsername("+34600000000") == "+34600000000")
    }

    @Test("restoreSavedAccounts migrates a legacy WhatsApp username and its Keychain entry")
    @MainActor
    func testRestoreMigratesWhatsAppUsername() throws {
        let bridge = PurpleBridgeService.shared
        let defaults = UserDefaults.standard
        let savedAccountsKey = "AdiumSavedAccounts"
        let legacyUsername = "+34600111222"
        let canonicalUsername = "34600111222@s.whatsapp.net"
        let protoID = AccountProtocol.whatsapp.purpleProtocolID
        let oldKey = "\(legacyUsername):\(protoID)"
        let newKey = "\(canonicalUsername):\(protoID)"

        let previousData = defaults.data(forKey: savedAccountsKey)
        let previousAccounts = bridge.accounts
        defer {
            if let previousData {
                defaults.set(previousData, forKey: savedAccountsKey)
            } else {
                defaults.removeObject(forKey: savedAccountsKey)
            }
            bridge.accounts = previousAccounts
            KeychainHelper.deletePassword(for: oldKey)
            KeychainHelper.deletePassword(for: newKey)
        }

        let legacy = Account(username: legacyUsername, accountProtocol: .whatsapp)
        defaults.set(try JSONEncoder().encode([legacy]), forKey: savedAccountsKey)
        KeychainHelper.savePassword("secret-123", for: oldKey)

        bridge.restoreSavedAccounts()

        let migrated = bridge.accounts.first(where: { $0.accountProtocol == .whatsapp && $0.username == canonicalUsername })
        #expect(migrated != nil)
        #expect(!bridge.accounts.contains(where: { $0.username == legacyUsername }))
        #expect(KeychainHelper.fetchPassword(for: newKey) == "secret-123")
        #expect(KeychainHelper.fetchPassword(for: oldKey) == nil)
    }

    // MARK: - Teams meeting metadata events

    @Test("Meeting metadata JSON blobs are detected, escaped or plain")
    func meetingMetadataDetection() {
        let escaped = "{\\\"scopeId\\\":\\\"a83db5e0\\\",\\\"callId\\\":\\\"a83db5e0\\\",\\\"isDeleted\\\":false}"
        let plain = "{\"scopeId\":\"a83db5e0\",\"iCalUid\":\"0400\",\"isDeleted\":false}"
        #expect(ChatMessage(senderName: "x", isFromMe: false, text: escaped).isMeetingMetadataEvent)
        #expect(ChatMessage(senderName: "x", isFromMe: false, text: plain).isMeetingMetadataEvent)
        // A JSON object without meeting keys is user content and stays visible.
        let userJson = "{\"gcp_comsac\": 1, \"gcp_basegcp\": 2, \"other\": \"value\"}"
        #expect(!ChatMessage(senderName: "x", isFromMe: false, text: userJson).isMeetingMetadataEvent)
        #expect(!ChatMessage(senderName: "x", isFromMe: false, text: "hola {mundo}").isMeetingMetadataEvent)
        #expect(!ChatMessage(senderName: "x", isFromMe: false, text: "Call ended").isMeetingMetadataEvent)
    }

    @Test("System event senders resolve to nil for thread ids")
    @MainActor
    func threadSenderHidesLine() {
        let bridge = PurpleBridgeService.shared
        #expect(bridge.resolveSenderDisplayName("19:meeting_abc@thread.v2", in: nil) == nil)
        #expect(bridge.resolveSenderDisplayName("", in: nil) == nil)
        // An unknown person id stays visible as-is.
        #expect(bridge.resolveSenderDisplayName("orgid:ffffffff", in: nil) == "orgid:ffffffff")
    }
}
