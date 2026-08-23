import Foundation
import AppKit
import UniformTypeIdentifiers

public struct BackupManifest: Codable {
    public let app: String
    public let version: String
    public let createdAt: Date
    
    public init(app: String = "Fluorite", version: String = "1.0", createdAt: Date = Date()) {
        self.app = app
        self.version = version
        self.createdAt = createdAt
    }
}

public struct BackupPreferencesPayload: Codable {
    public var accounts: [Account]
    public var groups: [ContactGroup]
    public var metacontacts: [Metacontact]
    public var contacts: [Contact]
    public var showNotifications: Bool
    public var playSoundEffects: Bool
    public var launchAtLogin: Bool
    public var showOfflineContacts: Bool
    public var contactSortOrder: String?
    
    public init(
        accounts: [Account] = [],
        groups: [ContactGroup] = [],
        metacontacts: [Metacontact] = [],
        contacts: [Contact] = [],
        showNotifications: Bool = true,
        playSoundEffects: Bool = true,
        launchAtLogin: Bool = false,
        showOfflineContacts: Bool = true,
        contactSortOrder: String? = nil
    ) {
        self.accounts = accounts
        self.groups = groups
        self.metacontacts = metacontacts
        self.contacts = contacts
        self.showNotifications = showNotifications
        self.playSoundEffects = playSoundEffects
        self.launchAtLogin = launchAtLogin
        self.showOfflineContacts = showOfflineContacts
        self.contactSortOrder = contactSortOrder
    }
}

@MainActor
public final class BackupManager {
    public static let shared = BackupManager()
    private let fileManager = FileManager.default
    
    /// This is an optional custom data directory for tests.
    public var customDataDirectory: URL?
    
    /// This is the standard data directory (~/.fluorite).
    public var dataDirectory: URL {
        if let custom = customDataDirectory {
            try? fileManager.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        let userHome = fileManager.homeDirectoryForCurrentUser
        let fluoriteDir = userHome.appendingPathComponent(".fluorite", isDirectory: true)
        try? fileManager.createDirectory(at: fluoriteDir, withIntermediateDirectories: true)
        return fluoriteDir
    }
    
    public init() {}
    
    /// Export all application data, preferences, and logs to a zip file, a tar file, or a target folder.
    public func exportBackup(to destinationURL: URL) throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("AdiumBackup_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        
        // 1. Write the manifest.
        let manifest = BackupManifest()
        let manifestData = try JSONEncoder().encode(manifest)
        try manifestData.write(to: tempDir.appendingPathComponent("manifest.json"))
        
        // 2. Gather preferences and accounts. Do not include plaintext passwords.
        let bridge = PurpleBridgeService.shared
        let defaults = UserDefaults.standard
        
        let payload = BackupPreferencesPayload(
            accounts: bridge.accounts,
            groups: bridge.contactGroups,
            metacontacts: bridge.metacontacts,
            contacts: bridge.contacts,
            showNotifications: defaults.bool(forKey: "showNotifications"),
            playSoundEffects: defaults.bool(forKey: "playSoundEffects"),
            launchAtLogin: defaults.bool(forKey: "launchAtLogin"),
            showOfflineContacts: defaults.bool(forKey: "showOfflineContacts"),
            contactSortOrder: defaults.string(forKey: "contactSortOrder")
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let prefsData = try encoder.encode(payload)
        try prefsData.write(to: tempDir.appendingPathComponent("preferences.json"))
        
        // 3. Copy the chat history logs.
        let logsStaging = tempDir.appendingPathComponent("logs", isDirectory: true)
        try fileManager.createDirectory(at: logsStaging, withIntermediateDirectories: true)
        
        let sourceLogs = ChatLogStore.shared.logsDirectory
        if fileManager.fileExists(atPath: sourceLogs.path) {
            let logFiles = (try? fileManager.contentsOfDirectory(at: sourceLogs, includingPropertiesForKeys: nil)) ?? []
            for file in logFiles {
                let dest = logsStaging.appendingPathComponent(file.lastPathComponent)
                try? fileManager.copyItem(at: file, to: dest)
            }
        }
        
        // 4. Copy the data directory (~/.fluorite).
        // Sanitize files that contain plaintext credentials before you include them in the archive.
        let dataStaging = tempDir.appendingPathComponent("data", isDirectory: true)
        try fileManager.createDirectory(at: dataStaging, withIntermediateDirectories: true)

        let sourceData = dataDirectory
        if fileManager.fileExists(atPath: sourceData.path) {
            sanitizedCopyDataDirectory(from: sourceData, to: dataStaging)
        }

        // 5. Package or copy the data to destinationURL.
        // Build the new archive at a staging path first.
        // Swap the archive only when it is complete.
        // This prevents a failed operation from destroying a pre-existing backup.
        let pathLower = destinationURL.path.lowercased()
        let stagingURL = destinationURL.deletingLastPathComponent()
            .appendingPathComponent(".\(destinationURL.lastPathComponent).tmp-\(UUID().uuidString)")

        do {
            if pathLower.hasSuffix(".zip") {
                try archiveZip(sourceDir: tempDir, zipURL: stagingURL)
            } else if pathLower.hasSuffix(".tar.gz") || pathLower.hasSuffix(".tgz") || destinationURL.pathExtension.lowercased() == "gz" {
                try archiveTarGz(sourceDir: tempDir, tarURL: stagingURL)
            } else {
                // Directory copy
                try fileManager.copyItem(at: tempDir, to: stagingURL)
            }
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        }

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItem(at: destinationURL, withItemAt: stagingURL, backupItemName: nil, options: [], resultingItemURL: nil)
        } else {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
        }
    }

    /// Copy the data directory into the backup staging area recursively.
    /// Skip sensitive files anywhere in the tree.
    /// Sanitize the accounts.xml file to strip password elements.
    private func sanitizedCopyDataDirectory(from sourceDir: URL, to destDir: URL) {
        let items = (try? fileManager.contentsOfDirectory(at: sourceDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for item in items {
            let lowerName = item.lastPathComponent.lowercased()

            if lowerName.contains("pass") || lowerName.contains("secret") || lowerName.contains("keychain")
                || lowerName.hasSuffix(".key") || lowerName.contains("token") {
                continue
            }

            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }

            let dest = destDir.appendingPathComponent(item.lastPathComponent)

            if isDirectory.boolValue {
                try? fileManager.createDirectory(at: dest, withIntermediateDirectories: true)
                sanitizedCopyDataDirectory(from: item, to: dest)
            } else if lowerName == "accounts.xml" {
                sanitizeAndCopyAccountsFile(from: item, to: dest)
            } else {
                try? fileManager.copyItem(at: item, to: dest)
            }
        }
    }

    /// Strip password elements from a libpurple-style accounts.xml file.
    /// Do this before you include the file in a backup archive.
    /// This keeps plaintext credentials out of the archive.
    /// The rest of the file remains intact to keep the restore functional.
    private func sanitizeAndCopyAccountsFile(from source: URL, to dest: URL) {
        guard let data = try? Data(contentsOf: source), let xml = String(data: data, encoding: .utf8) else {
            // Do not ship the file verbatim if you cannot read and sanitize it as text.
            return
        }
        var sanitized = xml
        if let regex = try? NSRegularExpression(pattern: "<password[^>]*>.*?</password>", options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(sanitized.startIndex..., in: sanitized)
            sanitized = regex.stringByReplacingMatches(in: sanitized, options: [], range: range, withTemplate: "<password></password>")
        }
        try? sanitized.data(using: .utf8)?.write(to: dest)
    }
    
    /// Import and restore data, preferences, and logs from a backup archive or directory.
    public func importBackup(from sourceURL: URL) throws {
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("AdiumRestore_\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        defer {
            try? fileManager.removeItem(at: tempDir)
        }
        
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDir) else {
            throw NSError(domain: "BackupManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "El archivo de respaldo no existe."])
        }
        
        let extractDir: URL
        let pathLower = sourceURL.path.lowercased()
        
        if !isDir.boolValue && pathLower.hasSuffix(".zip") {
            try unarchiveZip(zipURL: sourceURL, targetDir: tempDir)
            extractDir = tempDir
        } else if !isDir.boolValue && (pathLower.hasSuffix(".tar.gz") || pathLower.hasSuffix(".tgz") || sourceURL.pathExtension.lowercased() == "gz") {
            try unarchiveTarGz(tarURL: sourceURL, targetDir: tempDir)
            extractDir = tempDir
        } else if isDir.boolValue {
            extractDir = sourceURL
        } else {
            throw NSError(domain: "BackupManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "Formato de archivo de respaldo no soportado."])
        }
        
        let prefsFile = extractDir.appendingPathComponent("preferences.json")
        guard fileManager.fileExists(atPath: prefsFile.path) else {
            throw NSError(domain: "BackupManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "El respaldo no contiene un archivo preferences.json válido."])
        }
        
        // 1. Restore the preferences and accounts.
        let prefsData = try Data(contentsOf: prefsFile)
        let payload = try JSONDecoder().decode(BackupPreferencesPayload.self, from: prefsData)
        
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        
        if let encAccounts = try? encoder.encode(payload.accounts) {
            defaults.set(encAccounts, forKey: "AdiumSavedAccounts")
        }
        if let encGroups = try? encoder.encode(payload.groups) {
            defaults.set(encGroups, forKey: "AdiumSavedGroups")
        }
        if let encMetacontacts = try? encoder.encode(payload.metacontacts) {
            defaults.set(encMetacontacts, forKey: "AdiumSavedMetacontacts")
        }
        if let encContacts = try? encoder.encode(payload.contacts) {
            defaults.set(encContacts, forKey: "AdiumSavedContacts")
        }
        
        defaults.set(payload.showNotifications, forKey: "showNotifications")
        defaults.set(payload.playSoundEffects, forKey: "playSoundEffects")
        defaults.set(payload.launchAtLogin, forKey: "launchAtLogin")
        defaults.set(payload.showOfflineContacts, forKey: "showOfflineContacts")
        if let sort = payload.contactSortOrder {
            defaults.set(sort, forKey: "contactSortOrder")
        }
        
        // Reload the bridge state.
        let bridge = PurpleBridgeService.shared
        bridge.restoreSavedAccounts()
        bridge.restoreSavedGroups()
        bridge.restoreSavedMetacontacts()
        bridge.restoreSavedContacts()
        
        // 2. Restore the chat logs.
        let logsSource = extractDir.appendingPathComponent("logs", isDirectory: true)
        if fileManager.fileExists(atPath: logsSource.path) {
            let targetLogsDir = ChatLogStore.shared.logsDirectory
            let files = (try? fileManager.contentsOfDirectory(at: logsSource, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let dest = targetLogsDir.appendingPathComponent(file.lastPathComponent)
                if fileManager.fileExists(atPath: dest.path) {
                    try? fileManager.removeItem(at: dest)
                }
                try? fileManager.copyItem(at: file, to: dest)
            }
        }
        
        // 3. Restore the data directory (~/.fluorite).
        let dataSource = extractDir.appendingPathComponent("data", isDirectory: true)
        if fileManager.fileExists(atPath: dataSource.path) {
            let targetDataDir = dataDirectory
            let files = (try? fileManager.contentsOfDirectory(at: dataSource, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let dest = targetDataDir.appendingPathComponent(file.lastPathComponent)
                if fileManager.fileExists(atPath: dest.path) {
                    try? fileManager.removeItem(at: dest)
                }
                try? fileManager.copyItem(at: file, to: dest)
            }
        }
    }
    
    // MARK: - Panel Prompts
    
    public func promptExportBackup(window: NSWindow? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let dateStr = formatter.string(from: Date())
        panel.nameFieldStringValue = "Fluorite_Backup_\(dateStr).tar.gz"
        panel.title = "Exportar Respaldo de Datos Adium"
        panel.prompt = "Guardar Respaldo"
        panel.allowedContentTypes = [.gzip, .zip]
        
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let targetURL = panel.url {
                do {
                    try self.exportBackup(to: targetURL)
                    completion(.success(targetURL))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        
        if let window = window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
    
    public func promptImportBackup(window: NSWindow? = nil, completion: @escaping (Result<URL, Error>) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Restaurar Respaldo de Datos Adium"
        panel.prompt = "Restaurar"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.gzip, .zip, .folder]
        
        let handler: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK, let sourceURL = panel.url {
                do {
                    try self.importBackup(from: sourceURL)
                    completion(.success(sourceURL))
                } catch {
                    completion(.failure(error))
                }
            }
        }
        
        if let window = window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            panel.begin(completionHandler: handler)
        }
    }
    
    // MARK: - Archive Helpers (tar & zip)
    
    private func archiveTarGz(sourceDir: URL, tarURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-czf", tarURL.path, "-C", sourceDir.path, "."]
        try task.run()
        task.waitUntilExit()
        
        if task.terminationStatus != 0 {
            throw NSError(domain: "BackupManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "Error al crear archivo tar.gz (exit code: \(task.terminationStatus))"])
        }
    }
    
    private func unarchiveTarGz(tarURL: URL, targetDir: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        task.arguments = ["-xzf", tarURL.path, "-C", targetDir.path]
        try task.run()
        task.waitUntilExit()
        
        if task.terminationStatus != 0 {
            throw NSError(domain: "BackupManager", code: 5, userInfo: [NSLocalizedDescriptionKey: "Error al descomprimir archivo tar.gz (exit code: \(task.terminationStatus))"])
        }
    }
    
    private func archiveZip(sourceDir: URL, zipURL: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = sourceDir
        task.arguments = ["-r", "-q", zipURL.path, "."]
        try task.run()
        task.waitUntilExit()
        
        if task.terminationStatus != 0 {
            throw NSError(domain: "BackupManager", code: 6, userInfo: [NSLocalizedDescriptionKey: "Error al crear archivo zip (exit code: \(task.terminationStatus))"])
        }
    }
    
    private func unarchiveZip(zipURL: URL, targetDir: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        task.arguments = ["-q", zipURL.path, "-d", targetDir.path]
        try task.run()
        task.waitUntilExit()
        
        if task.terminationStatus != 0 {
            throw NSError(domain: "BackupManager", code: 7, userInfo: [NSLocalizedDescriptionKey: "Error al descomprimir archivo zip (exit code: \(task.terminationStatus))"])
        }
    }
}
