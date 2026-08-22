import Testing
import Foundation
@testable import AdiumSwift

/// Fase 2: new event types, per-contact mute, and the away autoreply.
@Suite("Events & Presence Tests")
struct EventsPresenceTests {

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

    @Test("Group mention matches the username local part, not short fragments")
    func testGroupMentionDetection() {
        let account = Account(username: "julio@example.com", accountProtocol: .teams)
        let accounts = [account]

        #expect(PurpleBridgeService.isGroupMention(text: "hey Julio, look at this", accounts: accounts))
        #expect(PurpleBridgeService.isGroupMention(text: "ping julio@example.com please", accounts: accounts))
        // Short local parts never match: too many false positives.
        #expect(!PurpleBridgeService.isGroupMention(text: "jo in the middle of a word", accounts: [
            Account(username: "jo@example.com", accountProtocol: .teams),
        ]))
        #expect(!PurpleBridgeService.isGroupMention(text: "nothing relevant here", accounts: accounts))
        #expect(!PurpleBridgeService.isGroupMention(text: "julio@example.com", accounts: []))
    }

    @Test("A muted contact keeps its unread badge but fires no event")
    @MainActor
    func testMutedContactSuppressesEvents() {
        withIsolatedLogs {
            let bridge = PurpleBridgeService.shared
            let events = EventManager.shared
            let baselineUnread = bridge.unreadCounts

            let contact = Contact(
                name: "Muted Peer",
                handle: "muted-peer@test.com",
                status: .available,
                accountProtocol: .teams,
                isMuted: true
            )
            bridge.contacts.append(contact)
            defer { bridge.contacts.removeAll(where: { $0.handle == "muted-peer@test.com" }) }
            let baseline = events.lastTriggeredEvent.map { "\($0.type)-\($0.title)-\($0.content)" }
            bridge.onMessageReceived(senderHandle: "muted-peer@test.com", text: "silent hello", isFromMe: false)

            // The badge still counts the message.
            #expect(bridge.unreadCounts[contact.id, default: 0] == (baselineUnread[contact.id] ?? 0) + 1)
            // No event fired: the last event pointer is untouched.
            #expect(events.lastTriggeredEvent.map { "\($0.type)-\($0.title)-\($0.content)" } == baseline)
        }
    }

    @Test("The away autoreply answers once per contact inside the cooldown")
    @MainActor
    func testAutoreplyCooldown() {
        withIsolatedLogs {
            let bridge = PurpleBridgeService.shared
            let defaults = UserDefaults.standard
            let originalEnabled = defaults.object(forKey: "AdiumAutoreplyEnabled")
            let originalStatus = bridge.myStatus
            defer {
                if let originalEnabled {
                    defaults.set(originalEnabled, forKey: "AdiumAutoreplyEnabled")
                } else {
                    defaults.removeObject(forKey: "AdiumAutoreplyEnabled")
                }
                bridge.myStatus = originalStatus
            }

            defaults.set(true, forKey: "AdiumAutoreplyEnabled")
            bridge.myStatus = .away

            let contact = Contact(
                name: "Autoreply Peer",
                handle: "autoreply-peer@test.com",
                status: .available,
                accountProtocol: .teams
            )
            bridge.contacts.append(contact)
            defer { bridge.contacts.removeAll(where: { $0.handle == "autoreply-peer@test.com" }) }

            bridge.maybeSendAutoreply(to: contact)
            bridge.maybeSendAutoreply(to: contact)

            let replies = bridge.messagesPerContact[contact.id]?.filter { $0.isFromMe && $0.text == t("I am away right now.") } ?? []
            #expect(replies.count == 1)
        }
    }
}
