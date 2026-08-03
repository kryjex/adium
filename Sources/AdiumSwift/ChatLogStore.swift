import Foundation

public enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText = "Texto Plano (.txt)"
    case json = "JSON (.json)"
    
    public var id: String { self.rawValue }
    public var fileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .json: return "json"
        }
    }
}

@MainActor
@Observable
public final class ChatLogStore {
    public static let shared = ChatLogStore()
    private let fileManager = FileManager.default
    
    /// Optional custom logs directory for isolated unit tests
    public var customLogsDirectory: URL?
    
    public var logsDirectory: URL {
        if let custom = customLogsDirectory {
            try? fileManager.createDirectory(at: custom, withIntermediateDirectories: true)
            return custom
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let adiumLogs = appSupport.appendingPathComponent("AdiumSwift/Logs", isDirectory: true)
        try? fileManager.createDirectory(at: adiumLogs, withIntermediateDirectories: true)
        return adiumLogs
    }
    
    private func fileURL(for handle: String) -> URL {
        let safeHandle = sanitizeHandle(handle)
        return logsDirectory.appendingPathComponent("\(safeHandle).json")
    }
    
    public func sanitizeHandle(_ handle: String) -> String {
        return handle.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted).joined(separator: "_")
    }
    
    /// Save conversation history for a contact handle
    public func saveMessages(_ messages: [ChatMessage], for handle: String) {
        let fileURL = fileURL(for: handle)
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: fileURL)
        } catch {
            print("Failed to save chat log for \(handle): \(error)")
        }
    }
    
    /// Load conversation history for a contact handle
    public func loadMessages(for handle: String) -> [ChatMessage]? {
        let fileURL = fileURL(for: handle)
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode([ChatMessage].self, from: data)
        } catch {
            print("Failed to load chat log for \(handle): \(error)")
            return nil
        }
    }
    
    /// Save conversation history for a contact ID (legacy compatibility)
    public func saveMessages(_ messages: [ChatMessage], for contactID: UUID) {
        saveMessages(messages, for: contactID.uuidString)
    }
    
    /// Load conversation history for a contact ID (legacy compatibility)
    public func loadMessages(for contactID: UUID) -> [ChatMessage]? {
        loadMessages(for: contactID.uuidString)
    }
    
    /// Returns all saved contact handles / log file keys in the logs directory
    public func allLogHandles() -> [String] {
        guard let files = try? fileManager.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
    
    /// Loads all conversation logs present in the logs directory
    public func loadAllLogs() -> [String: [ChatMessage]] {
        var logs: [String: [ChatMessage]] = [:]
        for handleKey in allLogHandles() {
            if let msgs = loadMessages(for: handleKey) {
                logs[handleKey] = msgs
            }
        }
        return logs
    }
    
    /// Filter chat messages across all logs using handle, protocol, date range, and full-text search
    public func filterMessages(
        contactHandle: String? = nil,
        protocolType: AccountProtocol? = nil,
        startDate: Date? = nil,
        endDate: Date? = nil,
        searchText: String = "",
        contacts: [Contact] = []
    ) -> [(handle: String, messages: [ChatMessage])] {
        let allLogs = loadAllLogs()
        var results: [(handle: String, messages: [ChatMessage])] = []
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        for (handleKey, messages) in allLogs {
            let matchingContact = contacts.first(where: {
                sanitizeHandle($0.handle) == handleKey ||
                $0.handle.equalsIgnoringCase(handleKey) ||
                $0.id.uuidString == handleKey
            })
            
            // Filter by Contact Handle / Name
            if let targetHandle = contactHandle, !targetHandle.isEmpty, targetHandle != "ALL" {
                let safeTarget = sanitizeHandle(targetHandle)
                let matchesHandle = handleKey == safeTarget || (matchingContact?.handle.equalsIgnoringCase(targetHandle) ?? false) || (matchingContact?.displayName.equalsIgnoringCase(targetHandle) ?? false)
                if !matchesHandle {
                    continue
                }
            }
            
            // Filter by Protocol. If a protocol filter is active but we can't
            // determine which contact (and therefore protocol) this log belongs to,
            // exclude it rather than silently letting it through.
            if let targetProtocol = protocolType {
                guard let contactProto = matchingContact?.accountProtocol, contactProto == targetProtocol else {
                    continue
                }
            }

            // Filter messages within handle log
            let filteredMsgs = messages.filter { msg in
                if let start = startDate, msg.timestamp < start {
                    return false
                }
                if let end = endDate {
                    let endOfDay = Calendar.current.startOfDay(for: end).addingTimeInterval(86400)
                    if msg.timestamp >= endOfDay {
                        return false
                    }
                }
                if !trimmedQuery.isEmpty {
                    let matchesText = msg.text.localizedCaseInsensitiveContains(trimmedQuery)
                    let matchesSender = msg.senderName.localizedCaseInsensitiveContains(trimmedQuery)
                    if !matchesText && !matchesSender {
                        return false
                    }
                }
                return true
            }
            
            if !filteredMsgs.isEmpty {
                results.append((handle: handleKey, messages: filteredMsgs))
            }
        }
        
        return results.sorted { $0.handle < $1.handle }
    }
    
    /// Export conversation messages to text or JSON file
    public func exportTranscript(
        messages: [ChatMessage],
        handle: String,
        displayName: String? = nil,
        protocolType: AccountProtocol? = nil,
        format: TranscriptExportFormat,
        to destinationURL: URL
    ) throws {
        let data: Data
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(messages)
        case .plainText:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            
            var header = "=== Transcripción de Chat: \(displayName ?? handle) (\(handle)) ===\n"
            if let proto = protocolType {
                header += "Protocolo: \(proto.rawValue)\n"
            }
            header += "Total de mensajes: \(messages.count)\n"
            header += "========================================================\n\n"
            
            let lines = messages.map { msg in
                let dateStr = formatter.string(from: msg.timestamp)
                return "[\(dateStr)] \(msg.senderName): \(msg.text)"
            }
            
            let content = header + lines.joined(separator: "\n")
            guard let converted = content.data(using: .utf8) else {
                throw NSError(domain: "TranscriptExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Error al codificar texto en UTF-8"])
            }
            data = converted
        }
        
        try data.write(to: destinationURL, options: .atomic)
    }
}

private extension String {
    func equalsIgnoringCase(_ other: String) -> Bool {
        return self.caseInsensitiveCompare(other) == .orderedSame
    }
}

