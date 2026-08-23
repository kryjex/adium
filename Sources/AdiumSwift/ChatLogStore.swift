import Foundation

public enum TranscriptExportFormat: String, CaseIterable, Identifiable, Sendable {
    case plainText = "txt"
    case json = "json"
    case html = "html"

    public var id: String { self.rawValue }
    public var fileExtension: String { self.rawValue }

    /// This is the localized text for menus.
    /// The raw value stays stable because it names the file extension.
    public var displayName: String {
        switch self {
        case .plainText: return t("Plain Text (.txt)")
        case .json: return t("JSON (.json)")
        case .html: return t("HTML (.html)")
        }
    }
}

@MainActor
@Observable
public final class ChatLogStore {
    public static let shared = ChatLogStore()
    private let fileManager = FileManager.default
    
    /// This is an optional custom logs directory for isolated unit tests.
    public var customLogsDirectory: URL?

    /// Bumped on every save/delete. Views read it (via allLogHandles) so
    /// Observation re-renders them when log files change on disk.
    public private(set) var revision: Int = 0
    
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
    
    /// Save the conversation history for a contact handle.
    public func saveMessages(_ messages: [ChatMessage], for handle: String) {
        let fileURL = fileURL(for: handle)
        do {
            let data = try JSONEncoder().encode(messages)
            try data.write(to: fileURL)
            revision += 1
        } catch {
            print("Failed to save chat log for \(handle): \(error)")
        }
    }

    /// Delete the saved conversation history for a contact handle.
    @discardableResult
    public func deleteLog(for handle: String) -> Bool {
        let fileURL = fileURL(for: handle)
        guard fileManager.fileExists(atPath: fileURL.path) else { return false }
        do {
            try fileManager.removeItem(at: fileURL)
            revision += 1
            return true
        } catch {
            print("Failed to delete chat log for \(handle): \(error)")
            return false
        }
    }
    
    /// Load the conversation history for a contact handle.
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
    
    /// Save the conversation history for a contact ID for legacy compatibility.
    public func saveMessages(_ messages: [ChatMessage], for contactID: UUID) {
        saveMessages(messages, for: contactID.uuidString)
    }
    
    /// Load the conversation history for a contact ID for legacy compatibility.
    public func loadMessages(for contactID: UUID) -> [ChatMessage]? {
        loadMessages(for: contactID.uuidString)
    }
    
    /// Return all saved contact handles in the logs directory.
    public func allLogHandles() -> [String] {
        _ = revision
        guard let files = try? fileManager.contentsOfDirectory(at: logsDirectory, includingPropertiesForKeys: nil) else {
            return []
        }
        return files
            .filter { $0.pathExtension.lowercased() == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
    }
    
    /// Load all conversation logs in the logs directory.
    public func loadAllLogs() -> [String: [ChatMessage]] {
        var logs: [String: [ChatMessage]] = [:]
        for handleKey in allLogHandles() {
            if let msgs = loadMessages(for: handleKey) {
                logs[handleKey] = msgs
            }
        }
        return logs
    }
    
    /// Filter chat messages across all logs. Use handle, protocol, date range, and full-text search.
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
            
            // Filter by contact handle or name.
            if let targetHandle = contactHandle, !targetHandle.isEmpty, targetHandle != "ALL" {
                let safeTarget = sanitizeHandle(targetHandle)
                let matchesHandle = handleKey == safeTarget || (matchingContact?.handle.equalsIgnoringCase(targetHandle) ?? false) || (matchingContact?.displayName.equalsIgnoringCase(targetHandle) ?? false)
                if !matchesHandle {
                    continue
                }
            }
            
            // Filter by protocol.
            // Exclude the log if a protocol filter is active but you cannot determine the contact.
            if let targetProtocol = protocolType {
                guard let contactProto = matchingContact?.accountProtocol, contactProto == targetProtocol else {
                    continue
                }
            }

            // Filter messages within the handle log.
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
    
    /// Export conversation messages to a text file or a JSON file.
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
        case .html:
            data = Self.htmlDocument(
                messages: messages,
                handle: handle,
                displayName: displayName,
                protocolType: protocolType
            )
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            data = try encoder.encode(messages)
        case .plainText:
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .medium
            
            var header = t("=== Chat Transcript: \(displayName ?? handle) (\(handle)) ===") + "\n"
            if let proto = protocolType {
                header += t("Protocol: \(proto.rawValue)") + "\n"
            }
            header += t("Total messages: \(messages.count)") + "\n"
            header += "========================================================\n\n"
            
            let lines = messages.map { msg in
                let dateStr = formatter.string(from: msg.timestamp)
                return "[\(dateStr)] \(msg.senderName): \(msg.text)"
            }
            
            let content = header + lines.joined(separator: "\n")
            guard let converted = content.data(using: .utf8) else {
                throw NSError(domain: "TranscriptExport", code: 1, userInfo: [NSLocalizedDescriptionKey: t("Could not encode the text as UTF-8")])
            }
            data = converted
        }

        try data.write(to: destinationURL, options: .atomic)
    }

    nonisolated static func htmlEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// This sniffs the image data format for an inline data URI.
    nonisolated private static func imageDataKind(_ data: Data) -> String? {
        guard data.count > 4 else { return nil }
        let bytes = [UInt8](data.prefix(4))
        if bytes.elementsEqual([0x89, 0x50, 0x4E, 0x47]) { return "image/png" }
        if bytes[0] == 0xFF && bytes[1] == 0xD8 { return "image/jpeg" }
        if bytes.elementsEqual([0x47, 0x49, 0x46]) { return "image/gif" }
        return nil
    }

    /// This builds a standalone HTML transcript: one style block, a day
    /// separator per calendar day, own messages right-aligned. Images ride
    /// along as base64 data URIs.
    nonisolated private static func htmlDocument(
        messages: [ChatMessage],
        handle: String,
        displayName: String?,
        protocolType: AccountProtocol?
    ) -> Data {
        let dayFormatter = DateFormatter()
        dayFormatter.dateStyle = .full
        let timeFormatter = DateFormatter()
        timeFormatter.timeStyle = .medium

        var body = ""
        var currentDay: String?
        for msg in messages {
            let day = dayFormatter.string(from: msg.timestamp)
            if day != currentDay {
                currentDay = day
                body += "<div class=\"day\">\(htmlEscaped(day))</div>\n"
            }
            if msg.isSystemEvent {
                body += "<div class=\"system\">\(htmlEscaped(msg.text)) · \(timeFormatter.string(from: msg.timestamp))</div>\n"
                continue
            }
            var imageTag = ""
            if let image = msg.imageData, let kind = imageDataKind(image) {
                imageTag = " <img src=\"data:\(kind);base64,\(image.base64EncodedString())\" alt=\"image\" />"
            }
            let text = htmlEscaped(msg.text).replacingOccurrences(of: "\n", with: "<br />")
            body += "<div class=\"msg \(msg.isFromMe ? "me" : "them")\"><span class=\"meta\">\(htmlEscaped(msg.senderName)) · \(timeFormatter.string(from: msg.timestamp))</span><div class=\"text\">\(text)\(imageTag)</div></div>\n"
        }

        let title = htmlEscaped("\(displayName ?? handle) (\(handle))")
        let protoLine = protocolType.map { "<p id=\"proto\">\(htmlEscaped($0.rawValue))</p>" } ?? ""
        let countLine = htmlEscaped(t("Total messages: \(messages.count)"))
        let html = """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <title>\(title)</title>
        <style>
        body { font-family: -apple-system, Helvetica, sans-serif; font-size: 13px; color: #1d1d1f; background: #f5f5f7; margin: 0; padding: 24px; }
        h1 { font-size: 16px; margin: 0 0 4px; }
        #proto, #count { color: #6e6e73; margin: 0 0 16px; font-size: 11px; }
        .day { text-align: center; font-size: 11px; color: #6e6e73; margin: 18px 0 10px; border-bottom: 1px solid #d2d2d7; padding-bottom: 4px; }
        .msg { max-width: 70%; margin: 6px 0; }
        .msg.me { margin-left: auto; }
        .meta { display: block; font-size: 10px; color: #6e6e73; margin-bottom: 2px; }
        .msg.me .meta { text-align: right; }
        .text { background: #e9e9eb; border-radius: 12px; padding: 8px 12px; overflow-wrap: break-word; }
        .msg.me .text { background: #0a84ff; color: #ffffff; }
        .system { text-align: center; color: #6e6e73; font-size: 11px; font-style: italic; margin: 8px 0; }
        img { max-width: 280px; max-height: 280px; border-radius: 8px; display: block; margin-top: 4px; }
        </style>
        </head>
        <body>
        <h1>\(title)</h1>
        \(protoLine)
        <p id="count">\(countLine)</p>
        \(body)
        </body>
        </html>
        """
        return Data(html.utf8)
    }
}

private extension String {
    func equalsIgnoringCase(_ other: String) -> Bool {
        return self.caseInsensitiveCompare(other) == .orderedSame
    }
}

