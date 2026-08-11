import Testing
import Foundation
@testable import AdiumSwift

@Suite("Transcript Viewer & Data Backup Tests")
struct TranscriptAndBackupTests {
    
    @Test("ChatLogStore transcript filtering by handle, protocol, date, and query")
    @MainActor
    func testChatLogStoreFiltering() throws {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir
        
        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }
        
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let lastWeek = Calendar.current.date(byAdding: .day, value: -7, to: now)!
        
        let msg1 = ChatMessage(id: UUID(), senderName: "Alice", isFromMe: false, text: "Hola AdiumSwift!", timestamp: lastWeek)
        let msg2 = ChatMessage(id: UUID(), senderName: "Me", isFromMe: true, text: "Reunión confirmada para mañana.", timestamp: yesterday)
        let msg3 = ChatMessage(id: UUID(), senderName: "Bob", isFromMe: false, text: "Enviando archivo de proyecto.", timestamp: now)
        
        store.saveMessages([msg1, msg2], for: "alice@teams.com")
        store.saveMessages([msg3], for: "bob@whatsapp.com")
        
        let contactAlice = Contact(name: "Alice Smith", handle: "alice@teams.com", status: .available, accountProtocol: .teams)
        let contactBob = Contact(name: "Bob Jones", handle: "bob@whatsapp.com", status: .available, accountProtocol: .whatsapp)
        let contacts = [contactAlice, contactBob]
        
        // 1. This filters by handle.
        let handleResults = store.filterMessages(contactHandle: "alice@teams.com", contacts: contacts)
        #expect(handleResults.count == 1)
        #expect(handleResults.first?.handle == store.sanitizeHandle("alice@teams.com"))
        #expect(handleResults.first?.messages.count == 2)
        
        // 2. This filters by protocol.
        let protoResults = store.filterMessages(protocolType: .whatsapp, contacts: contacts)
        #expect(protoResults.count == 1)
        #expect(protoResults.first?.handle == store.sanitizeHandle("bob@whatsapp.com"))
        
        // 3. This filters by date range.
        let dateResults = store.filterMessages(startDate: yesterday.addingTimeInterval(-60), contacts: contacts)
        let totalDateMsgs = dateResults.flatMap { $0.messages }
        #expect(totalDateMsgs.count == 2) // This includes msg2 and msg3.
        
        // 4. This searches for text.
        let searchResults = store.filterMessages(searchText: "Reunión", contacts: contacts)
        #expect(searchResults.count == 1)
        #expect(searchResults.first?.messages.first?.text.contains("Reunión") == true)
    }
    
    @Test("ChatLogStore transcript exporting to text and JSON")
    @MainActor
    func testTranscriptExporting() throws {
        let store = ChatLogStore.shared
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestExport_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? FileManager.default.removeItem(at: tempDir)
        }
        
        let msgs = [
            ChatMessage(senderName: "Alice", isFromMe: false, text: "Prueba de exportación 1"),
            ChatMessage(senderName: "Me", isFromMe: true, text: "Respuesta de exportación 2")
        ]
        
        // This exports to TXT.
        let txtURL = tempDir.appendingPathComponent("export.txt")
        try store.exportTranscript(messages: msgs, handle: "alice@teams.com", displayName: "Alice Smith", protocolType: .teams, format: .plainText, to: txtURL)
        
        #expect(FileManager.default.fileExists(atPath: txtURL.path))
        let txtContent = try String(contentsOf: txtURL)
        // The expected header goes through t() so the test passes in every locale.
        let expectedHeader = t("=== Chat Transcript: \("Alice Smith") (\("alice@teams.com")) ===")
        #expect(txtContent.contains(expectedHeader))
        #expect(txtContent.contains("Prueba de exportación 1"))
        #expect(txtContent.contains("Respuesta de exportación 2"))
        
        // This exports to JSON.
        let jsonURL = tempDir.appendingPathComponent("export.json")
        try store.exportTranscript(messages: msgs, handle: "alice@teams.com", displayName: "Alice Smith", protocolType: .teams, format: .json, to: jsonURL)
        
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        let jsonData = try Data(contentsOf: jsonURL)
        let decodedMsgs = try JSONDecoder().decode([ChatMessage].self, from: jsonData)
        #expect(decodedMsgs.count == 2)
        #expect(decodedMsgs.first?.text == "Prueba de exportación 1")
    }
    
    @Test("ChatLogStore deleteLog removes the log file and bumps the revision")
    @MainActor
    func testDeleteLogRemovesFile() throws {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir

        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        store.saveMessages([ChatMessage(senderName: "Alice", isFromMe: false, text: "Hola")], for: "alice@teams.com")
        store.saveMessages([ChatMessage(senderName: "Bob", isFromMe: false, text: "Hey")], for: "bob@whatsapp.com")
        #expect(store.allLogHandles().count == 2)

        let revisionBefore = store.revision
        #expect(store.deleteLog(for: "alice@teams.com") == true)
        #expect(store.revision > revisionBefore)

        let handles = store.allLogHandles()
        #expect(handles == [store.sanitizeHandle("bob@whatsapp.com")])
        #expect(store.loadMessages(for: "alice@teams.com") == nil)

        // Deleting a log that does not exist reports false.
        #expect(store.deleteLog(for: "alice@teams.com") == false)
    }

    @Test("removeAccount with deleteChatLogs deletes only that account's logs and keeps shared handles")
    @MainActor
    func testRemoveAccountDeletesChatLogs() throws {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir

        let bridge = PurpleBridgeService.shared
        let accountA = Account(username: "owner.a@teams.com", accountProtocol: .teams)
        let accountB = Account(username: "owner.b@whatsapp.com", accountProtocol: .whatsapp)
        bridge.accounts.append(contentsOf: [accountA, accountB])

        let mine = Contact(name: "Mine", handle: "delete.me@test.com", status: .available, accountProtocol: .teams, accountUsername: accountA.username)
        let other = Contact(name: "Other", handle: "keep.me@test.com", status: .available, accountProtocol: .whatsapp, accountUsername: accountB.username)
        let sharedMine = Contact(name: "Shared A", handle: "shared@test.com", status: .available, accountProtocol: .teams, accountUsername: accountA.username)
        let sharedOther = Contact(name: "Shared B", handle: "shared@test.com", status: .available, accountProtocol: .whatsapp, accountUsername: accountB.username)
        bridge.contacts.append(contentsOf: [mine, other, sharedMine, sharedOther])

        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
            bridge.contacts.removeAll(where: { [other.id, sharedOther.id].contains($0.id) })
            bridge.removeAccount(accountB)
        }

        let msg = ChatMessage(senderName: "X", isFromMe: false, text: "Hola")
        store.saveMessages([msg], for: mine.handle)
        store.saveMessages([msg], for: mine.id.uuidString) // Legacy UUID-keyed log.
        store.saveMessages([msg], for: other.handle)
        store.saveMessages([msg], for: sharedMine.handle)
        bridge.messagesPerContact[mine.id] = [msg]

        bridge.removeAccount(accountA, deleteChatLogs: true)

        // The logs of the removed account are gone, including the legacy one.
        #expect(store.loadMessages(for: mine.handle) == nil)
        #expect(store.loadMessages(for: mine.id.uuidString) == nil)
        #expect(bridge.messagesPerContact[mine.id] == nil)

        // The other account's log survives.
        #expect(store.loadMessages(for: other.handle) != nil)

        // A handle still used by a remaining contact keeps its log.
        #expect(store.loadMessages(for: "shared@test.com") != nil)
    }

    @Test("removeAccount without deleteChatLogs keeps the transcripts")
    @MainActor
    func testRemoveAccountKeepsChatLogsByDefault() throws {
        let store = ChatLogStore.shared
        let tempLogsDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = tempLogsDir

        let bridge = PurpleBridgeService.shared
        let account = Account(username: "keeper@teams.com", accountProtocol: .teams)
        bridge.accounts.append(account)
        let contact = Contact(name: "Keep Logs", handle: "keep.logs@test.com", status: .available, accountProtocol: .teams, accountUsername: account.username)
        bridge.contacts.append(contact)

        defer {
            store.customLogsDirectory = nil
            try? FileManager.default.removeItem(at: tempLogsDir)
        }

        store.saveMessages([ChatMessage(senderName: "X", isFromMe: false, text: "Hola")], for: contact.handle)

        bridge.removeAccount(account)

        #expect(store.loadMessages(for: contact.handle) != nil)
    }

    @Test("BackupManager tar.gz export and import workflow")
    @MainActor
    func testBackupManagerTarGzWorkflow() throws {
        let backupManager = BackupManager.shared
        let store = ChatLogStore.shared
        let bridge = PurpleBridgeService.shared
        
        let tempTestDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestBackup_\(UUID().uuidString)")
        let tempLogsDir = tempTestDir.appendingPathComponent("logs")
        let tempDataDir = tempTestDir.appendingPathComponent("data")
        let archiveURL = tempTestDir.appendingPathComponent("backup.tar.gz")
        
        try FileManager.default.createDirectory(at: tempLogsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDataDir, withIntermediateDirectories: true)
        
        store.customLogsDirectory = tempLogsDir
        backupManager.customDataDirectory = tempDataDir
        
        defer {
            store.customLogsDirectory = nil
            backupManager.customDataDirectory = nil
            try? FileManager.default.removeItem(at: tempTestDir)
        }
        
        // This sets up the state.
        let testAccount = Account(username: "backup.user@teams.com", accountProtocol: .teams, isConnected: true)
        let testContact = Contact(name: "Backup Contact", handle: "backup.contact@teams.com", status: .available, accountProtocol: .teams)
        let testGroup = ContactGroup(name: "Test Group")
        
        bridge.accounts = [testAccount]
        bridge.contacts = [testContact]
        bridge.contactGroups = [testGroup]
        
        let msg = ChatMessage(senderName: "Backup Contact", isFromMe: false, text: "Mensaje de respaldo importante.")
        store.saveMessages([msg], for: "backup.contact@teams.com")
        
        // This exports the backup.
        try backupManager.exportBackup(to: archiveURL)
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        
        // This changes the current state.
        bridge.accounts = []
        bridge.contacts = []
        bridge.contactGroups = []
        
        // This imports the backup.
        try backupManager.importBackup(from: archiveURL)

        // This asserts the presence of specific fixtures.
        // It does not assert absolute counts.
        // The bridge and store are shared.
        // Other tests run concurrently.
        #expect(bridge.accounts.contains(where: { $0.username == "backup.user@teams.com" }))
        #expect(bridge.contacts.contains(where: { $0.name == "Backup Contact" && $0.handle == "backup.contact@teams.com" }))
        #expect(bridge.contactGroups.contains(where: { $0.name == "Test Group" }))

        let restoredMsgs = store.loadMessages(for: "backup.contact@teams.com")
        #expect(restoredMsgs?.contains(where: { $0.text == "Mensaje de respaldo importante." }) == true)
    }
    
    @Test("BackupManager zip export and import workflow")
    @MainActor
    func testBackupManagerZipWorkflow() throws {
        let backupManager = BackupManager.shared
        let store = ChatLogStore.shared
        let bridge = PurpleBridgeService.shared
        
        let tempTestDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestZipBackup_\(UUID().uuidString)")
        let tempLogsDir = tempTestDir.appendingPathComponent("logs")
        let tempDataDir = tempTestDir.appendingPathComponent("data")
        let archiveURL = tempTestDir.appendingPathComponent("backup.zip")
        
        try FileManager.default.createDirectory(at: tempLogsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDataDir, withIntermediateDirectories: true)
        
        store.customLogsDirectory = tempLogsDir
        backupManager.customDataDirectory = tempDataDir
        
        defer {
            store.customLogsDirectory = nil
            backupManager.customDataDirectory = nil
            try? FileManager.default.removeItem(at: tempTestDir)
        }
        
        let testAccount = Account(username: "zip.user@whatsapp.com", accountProtocol: .whatsapp)
        bridge.accounts = [testAccount]
        
        let msg = ChatMessage(senderName: "Zip Test", isFromMe: true, text: "Zip backup content.")
        store.saveMessages([msg], for: "zip.user@whatsapp.com")
        
        // This exports to ZIP.
        try backupManager.exportBackup(to: archiveURL)
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        
        bridge.accounts = []
        
        // This imports the ZIP.
        try backupManager.importBackup(from: archiveURL)
        #expect(bridge.accounts.contains(where: { $0.username == "zip.user@whatsapp.com" }))
        let msgs = store.loadMessages(for: "zip.user@whatsapp.com")
        #expect(msgs?.contains(where: { $0.text == "Zip backup content." }) == true)
    }

    @Test("BackupManager preserves the previous backup file when the archiver fails")
    @MainActor
    func testBackupManagerPreservesPriorBackupOnArchiveFailure() throws {
        // Root bypasses POSIX permission checks.
        // This test uses POSIX permissions to force the archiver to fail.
        // This skips the test in that environment.
        guard getuid() != 0 else { return }

        let backupManager = BackupManager.shared
        let store = ChatLogStore.shared

        let tempTestDir = FileManager.default.temporaryDirectory.appendingPathComponent("TestBackupFailure_\(UUID().uuidString)")
        let tempLogsDir = tempTestDir.appendingPathComponent("logs")
        let tempDataDir = tempTestDir.appendingPathComponent("data")
        let destDir = tempTestDir.appendingPathComponent("dest", isDirectory: true)
        let archiveURL = destDir.appendingPathComponent("backup.tar.gz")

        try FileManager.default.createDirectory(at: tempLogsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempDataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        store.customLogsDirectory = tempLogsDir
        backupManager.customDataDirectory = tempDataDir

        defer {
            store.customLogsDirectory = nil
            backupManager.customDataDirectory = nil
            // This restores write permissions before cleanup.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destDir.path)
            try? FileManager.default.removeItem(at: tempTestDir)
        }

        // This writes a previous backup at the destination path.
        let previousBackupContent = Data("PREVIOUS_BACKUP_CONTENT".utf8)
        try previousBackupContent.write(to: archiveURL)

        // This makes the destination directory read-only.
        // This simulates a failure.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destDir.path)

        do {
            try backupManager.exportBackup(to: archiveURL)
            #expect(Bool(false), "exportBackup should have thrown when the archiver could not write its staging file")
        } catch {
            // Archiving failed as expected.
        }

        // This restores write permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destDir.path)

        // The failed export must not change the previous backup.
        // It must not delete the previous backup.
        let survivingContent = try Data(contentsOf: archiveURL)
        #expect(survivingContent == previousBackupContent)
    }
}
