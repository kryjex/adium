import Testing
import Foundation
@testable import AdiumSwift

/// Regression tests for a batch of bug fixes. Each test is written to FAIL if its
/// corresponding fix were reverted.
@Suite("Regression Tests for Recent Bug Fixes")
struct RegressionTests {

    // MARK: - 1. Backward-compatible decoding (Models.swift)

    @Test("Account decodes old-shape JSON missing the newer customOptions key")
    func testAccountDecodesOldJSONWithoutCustomOptions() throws {
        // Mimics JSON persisted by a build that predates `customOptions`.
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
        // Mimics JSON persisted by a build that predates the blocking/typing/group-chat fields.
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

        let baseline = eventMgr.unreadCount
        bridge.onMessageReceived(senderHandle: handle, text: "Incoming badge test", isFromMe: false)

        // The contact's own unread count must have moved by exactly one...
        #expect(bridge.unreadCounts[contact.id] == 1)
        // ...and that single increment must be reflected exactly once in the badge total,
        // not doubled by triggerEvent additionally incrementing it.
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
        #expect(bridge.connectionState.contains("bloqueado"))
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

        // The old AB metacontact dropped to a single member (A) once B left, so it must be
        // dissolved entirely.
        #expect(!bridge.metacontacts.contains(where: { $0.id == metaAB.id }))
        // A's stale metacontactID pointing at the now-dissolved AB metacontact must be cleared.
        #expect(bridge.contacts.first(where: { $0.id == a.id })?.metacontactID == nil)

        // B must belong to exactly the new BC metacontact -- never left listed under the old one.
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

        // Rename nameOne to nameTwo's name but with different casing -- must be refused, both
        // original groups must still exist exactly once.
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

        // With libpurple not loaded, sendFile must return immediately without ever touching
        // `transfers` -- guards against a regression where sendFile used to eagerly append a
        // "pending" row itself before libpurple's xfer-new callback fires.
        manager.sendFile(to: contact, at: URL(fileURLWithPath: "/tmp/does-not-matter.txt"))
        #expect(manager.transfers.count == countBefore)

        // Simulate the real flow: libpurple's onXferNew is the ONLY thing that creates the row.
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

        // A late progress update reporting the transfer as fully complete must NOT resurrect it.
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
        // Late in the day (23:59), well after an early-morning "end date" filter value.
        let lateInDay = startOfToday.addingTimeInterval(23 * 3600 + 59 * 60)
        let earlyTimeSameDay = startOfToday.addingTimeInterval(8 * 3600)

        let handle = "endday.alice@test.com"
        let msgLate = ChatMessage(senderName: "Alice", isFromMe: false, text: "Late night message", timestamp: lateInDay)
        store.saveMessages([msgLate], for: handle)

        let contactAlice = Contact(name: "Alice EndDay", handle: handle, status: .available, accountProtocol: .teams)

        // Filtering with an end-date set to any time within the SAME day must still include a
        // message timestamped later that same day -- end-date filtering is inclusive through the
        // whole calendar day, not just up to the exact clock time given.
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

        // This log's handle has NO corresponding Contact in the `contacts` list passed to
        // filterMessages, so its protocol can never be determined.
        let orphanHandle = "orphan.ghost@test.com"
        let msgOrphan = ChatMessage(senderName: "Ghost", isFromMe: false, text: "Orphan protocol message")
        store.saveMessages([msgOrphan], for: orphanHandle)

        let knownContact = Contact(name: "Known Contact", handle: "known.contact@test.com", status: .available, accountProtocol: .teams)

        // With a protocol filter active, a log we can't attribute to any protocol must be
        // excluded rather than silently let through.
        let protoFilteredResults = store.filterMessages(protocolType: .whatsapp, contacts: [knownContact])
        #expect(!protoFilteredResults.contains(where: { $0.handle == store.sanitizeHandle(orphanHandle) }))

        // With no protocol filter at all, that same log must still be included.
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

        // The retired "prpl-teams" ID (which never matched the real plugin) must map to .teams,
        // whose purpleProtocolID is the working "prpl-eionrobb-msteams".
        #expect(imported.contains(where: { $0.username == "jane@example.com" && $0.accountProtocol == .teams }))
        #expect(imported.contains(where: { $0.username == "jane@jabber.org/Adium" && $0.accountProtocol == .xmpp }))
        // Unknown protocol IDs are skipped, never guessed.
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
            bridge.contacts.removeAll(where: { $0.id == room.id })
            bridge.removeAccount(account)
        }

        // Initial roster population arrives with newArrival == false; must still be added.
        bridge.onChatBuddyJoined(roomName: room.handle, buddyName: "existing.member@teams.com", newArrival: false)
        let afterInitial = bridge.contacts.first(where: { $0.id == room.id })
        #expect(afterInitial?.groupParticipants.contains(where: { $0.handle == "existing.member@teams.com" }) == true)

        // A later, genuine join (newArrival == true) is also added.
        bridge.onChatBuddyJoined(roomName: room.handle, buddyName: "new.joiner@teams.com", newArrival: true)
        let afterJoin = bridge.contacts.first(where: { $0.id == room.id })
        #expect(afterJoin?.groupParticipants.contains(where: { $0.handle == "new.joiner@teams.com" }) == true)
        let countAfterJoin = afterJoin?.groupParticipants.count ?? 0

        // Re-announcing the same handle (e.g. duplicate roster event) must not duplicate the entry.
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
            bridge.contacts.removeAll(where: { $0.id == room.id })
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

        // No crash and no new contact accidentally created for the unknown room.
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

        // No account exists for this protocol/username combination, so resolveAccount fails
        // and sendFile must surface an error instead of silently dropping the request.
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

        // The user deleted their last account: the Swift layer has persisted an EMPTY list.
        // Even with the one-time-import flag cleared, an existing (possibly stale)
        // ~/.adium-swift/accounts.xml must NOT repopulate the account list.
        defaults.set(try JSONEncoder().encode([Account]()), forKey: savedKey)
        defaults.removeObject(forKey: flagKey)
        bridge.accounts = []

        bridge.restoreSavedAccounts()

        #expect(bridge.accounts.isEmpty)
    }
}
