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
        
        // 1. Filter by handle
        let handleResults = store.filterMessages(contactHandle: "alice@teams.com", contacts: contacts)
        #expect(handleResults.count == 1)
        #expect(handleResults.first?.handle == store.sanitizeHandle("alice@teams.com"))
        #expect(handleResults.first?.messages.count == 2)
        
        // 2. Filter by protocol (.whatsapp)
        let protoResults = store.filterMessages(protocolType: .whatsapp, contacts: contacts)
        #expect(protoResults.count == 1)
        #expect(protoResults.first?.handle == store.sanitizeHandle("bob@whatsapp.com"))
        
        // 3. Filter by Date range (since yesterday)
        let dateResults = store.filterMessages(startDate: yesterday.addingTimeInterval(-60), contacts: contacts)
        let totalDateMsgs = dateResults.flatMap { $0.messages }
        #expect(totalDateMsgs.count == 2) // msg2 and msg3
        
        // 4. Full-text search query ("Reunión")
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
        
        // Export to TXT
        let txtURL = tempDir.appendingPathComponent("export.txt")
        try store.exportTranscript(messages: msgs, handle: "alice@teams.com", displayName: "Alice Smith", protocolType: .teams, format: .plainText, to: txtURL)
        
        #expect(FileManager.default.fileExists(atPath: txtURL.path))
        let txtContent = try String(contentsOf: txtURL)
        #expect(txtContent.contains("Transcripción de Chat: Alice Smith"))
        #expect(txtContent.contains("Prueba de exportación 1"))
        #expect(txtContent.contains("Respuesta de exportación 2"))
        
        // Export to JSON
        let jsonURL = tempDir.appendingPathComponent("export.json")
        try store.exportTranscript(messages: msgs, handle: "alice@teams.com", displayName: "Alice Smith", protocolType: .teams, format: .json, to: jsonURL)
        
        #expect(FileManager.default.fileExists(atPath: jsonURL.path))
        let jsonData = try Data(contentsOf: jsonURL)
        let decodedMsgs = try JSONDecoder().decode([ChatMessage].self, from: jsonData)
        #expect(decodedMsgs.count == 2)
        #expect(decodedMsgs.first?.text == "Prueba de exportación 1")
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
        
        // Setup state
        let testAccount = Account(username: "backup.user@teams.com", accountProtocol: .teams, isConnected: true)
        let testContact = Contact(name: "Backup Contact", handle: "backup.contact@teams.com", status: .available, accountProtocol: .teams)
        let testGroup = ContactGroup(name: "Test Group")
        
        bridge.accounts = [testAccount]
        bridge.contacts = [testContact]
        bridge.contactGroups = [testGroup]
        
        let msg = ChatMessage(senderName: "Backup Contact", isFromMe: false, text: "Mensaje de respaldo importante.")
        store.saveMessages([msg], for: "backup.contact@teams.com")
        
        // Export
        try backupManager.exportBackup(to: archiveURL)
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        
        // Mutate current state
        bridge.accounts = []
        bridge.contacts = []
        bridge.contactGroups = []
        
        // Import / Restore
        try backupManager.importBackup(from: archiveURL)

        // Assert on presence of the specific fixtures rather than absolute counts: `bridge` and
        // `store` are shared singletons, so other tests running concurrently against the same
        // MainActor could otherwise make an exact-count assertion flaky/order-dependent.
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
        
        // Export to ZIP
        try backupManager.exportBackup(to: archiveURL)
        #expect(FileManager.default.fileExists(atPath: archiveURL.path))
        
        bridge.accounts = []
        
        // Import ZIP
        try backupManager.importBackup(from: archiveURL)
        #expect(bridge.accounts.contains(where: { $0.username == "zip.user@whatsapp.com" }))
        let msgs = store.loadMessages(for: "zip.user@whatsapp.com")
        #expect(msgs?.contains(where: { $0.text == "Zip backup content." }) == true)
    }

    @Test("BackupManager preserves the previous backup file when the archiver fails")
    @MainActor
    func testBackupManagerPreservesPriorBackupOnArchiveFailure() throws {
        // Root bypasses POSIX permission checks, which this test relies on to force the
        // archiver (tar) to fail while writing its staging file. Skip in that environment.
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
            // Restore write permission before cleanup so removal doesn't fail.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destDir.path)
            try? FileManager.default.removeItem(at: tempTestDir)
        }

        // Seed a "previous backup" at the destination path.
        let previousBackupContent = Data("PREVIOUS_BACKUP_CONTENT".utf8)
        try previousBackupContent.write(to: archiveURL)

        // Make the destination directory read-only so tar can't create its staging archive
        // there, simulating an archiver failure (e.g. disk full / permission error) mid-export.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: destDir.path)

        do {
            try backupManager.exportBackup(to: archiveURL)
            #expect(Bool(false), "exportBackup should have thrown when the archiver could not write its staging file")
        } catch {
            // Expected: archiving failed.
        }

        // Restore write permission so the file can be read back and cleaned up.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destDir.path)

        // The previous backup at the destination must be completely untouched by the failed
        // export attempt -- it must never be deleted before the new archive is known-good.
        let survivingContent = try Data(contentsOf: archiveURL)
        #expect(survivingContent == previousBackupContent)
    }
}
