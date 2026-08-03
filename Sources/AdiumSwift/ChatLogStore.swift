import Foundation

@MainActor
public final class ChatLogStore {
    public static let shared = ChatLogStore()
    private let fileManager = FileManager.default
    
    private var logsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let adiumLogs = appSupport.appendingPathComponent("AdiumSwift/Logs", isDirectory: true)
        try? fileManager.createDirectory(at: adiumLogs, withIntermediateDirectories: true)
        return adiumLogs
    }
    
    private func fileURL(for handle: String) -> URL {
        let safeHandle = handle.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-")).inverted).joined(separator: "_")
        return logsDirectory.appendingPathComponent("\(safeHandle).json")
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
}
