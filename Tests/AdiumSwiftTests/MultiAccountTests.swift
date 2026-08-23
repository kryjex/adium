import Testing
import Foundation
@testable import AdiumSwift

/// Fase 1: with two accounts of the same protocol, rooms and chat messages
/// must route by the owning account, not by room or handle name alone.
@Suite("Multi-Account Routing Tests")
struct MultiAccountTests {

    /// This redirects chat log writes to a temp directory for the test body.
    @MainActor
    private func withIsolatedLogs(_ body: () -> Void) {
        let store = ChatLogStore.shared
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = temp
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: temp)
        }
        body()
    }

    @Test("A room joined by one account is not joined for a second account")
    @MainActor
    func testJoinedRoomsArePerAccount() {
        let bridge = PurpleBridgeService.shared
        let proto = AccountProtocol.teams.purpleProtocolID
        let room = "multiaccount-room@test"

        // Start and end from a clean slate for both accounts.
        bridge.onChatLeft(roomName: room, username: "a@test", protocolId: proto)
        bridge.onChatLeft(roomName: room, username: "b@test", protocolId: proto)
        defer {
            bridge.onChatLeft(roomName: room, username: "a@test", protocolId: proto)
            bridge.onChatLeft(roomName: room, username: "b@test", protocolId: proto)
        }

        bridge.onChatJoined(roomName: room, username: "a@test", protocolId: proto)

        #expect(bridge.isChatJoined(username: "a@test", protocolId: proto, roomName: room))
        #expect(!bridge.isChatJoined(username: "b@test", protocolId: proto, roomName: room))
    }

    @Test("A chat message lands on the owning account's contact")
    @MainActor
    func testChatMessageRoutesByAccount() {
        withIsolatedLogs {
            let bridge = PurpleBridgeService.shared
            let proto = AccountProtocol.teams.purpleProtocolID
            let room = "shared-room@test"

            let contactA = Contact(
                name: "Shared Room A",
                handle: room,
                status: .available,
                accountProtocol: .teams,
                accountUsername: "a@test",
                isGroupChat: true
            )
            let contactB = Contact(
                name: "Shared Room B",
                handle: room,
                status: .available,
                accountProtocol: .teams,
                accountUsername: "b@test",
                isGroupChat: true
            )
            bridge.contacts.append(contactA)
            bridge.contacts.append(contactB)
            defer { bridge.contacts.removeAll(where: { $0.handle == room }) }

            bridge.onChatMessage(
                roomName: room, username: "b@test", protocolId: proto,
                sender: "peer@test", text: "hello B", isFromMe: false
            )

            #expect(bridge.messagesPerContact[contactB.id]?.contains(where: { $0.text == "hello B" }) == true)
            #expect(bridge.messagesPerContact[contactA.id]?.contains(where: { $0.text == "hello B" }) != true)

            // A callback without an account still routes by room name.
            bridge.onChatMessage(
                roomName: room, username: "", protocolId: "",
                sender: "peer@test", text: "legacy hello", isFromMe: false
            )
            let ours = bridge.messagesPerContact.filter { $0.key == contactA.id || $0.key == contactB.id }
            #expect(ours.values.flatMap { $0 }.contains(where: { $0.text == "legacy hello" }))
        }
    }

    @Test("By Activity sorts unread first, then by last message date")
    @MainActor
    func testCompareContactsByActivity() {
        let bridge = PurpleBridgeService.shared
        let list = ContactListView(selectedContactID: .constant(nil))

        let old = Contact(name: "Old Activity", handle: "old@test", status: .available, accountProtocol: .teams)
        let recent = Contact(name: "Recent Activity", handle: "recent@test", status: .available, accountProtocol: .teams)
        let unread = Contact(name: "Unread Activity", handle: "unread@test", status: .available, accountProtocol: .teams)

        let originalDates = bridge.lastActivityDates
        let originalUnread = bridge.unreadCounts
        defer {
            bridge.lastActivityDates = originalDates
            bridge.unreadCounts = originalUnread
        }

        bridge.lastActivityDates = [
            old.id: Date(timeIntervalSinceNow: -3600),
            recent.id: Date(),
        ]
        bridge.unreadCounts = [unread.id: 1]

        // Unread beats any recency.
        #expect(list.compareContacts(unread, recent, order: .byActivity))
        #expect(!list.compareContacts(recent, unread, order: .byActivity))
        // Then the most recent message wins.
        #expect(list.compareContacts(recent, old, order: .byActivity))
        #expect(!list.compareContacts(old, recent, order: .byActivity))
    }

    @Test("IRC channels get the # prefix on join")
    @MainActor
    func testIRCChannelNormalization() {
        let bridge = PurpleBridgeService.shared
        let account = Account(username: "chatter", accountProtocol: .irc)

        let joined = bridge.joinGroupChat(channelName: "fase3", account: account)
        #expect(joined.handle == "#fase3")
        defer {
            bridge.closeTab(joined.id)
            bridge.contacts.removeAll(where: { $0.handle == "#fase3" })
        }

        // An explicit prefix passes through unchanged.
        let explicit = bridge.joinGroupChat(channelName: "&local", account: account)
        #expect(explicit.handle == "&local")
        defer {
            bridge.closeTab(explicit.id)
            bridge.contacts.removeAll(where: { $0.handle == "&local" })
        }
    }
}
