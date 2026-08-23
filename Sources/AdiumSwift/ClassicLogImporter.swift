import Foundation

/// This imports the XML chat logs of the classic Adium
/// (~/Library/Application Support/Adium 2.0/Users/Default/Logs/...).
/// A .chatlog bundle holds one .xml file: a <chat> root carrying the
/// account attribute, and <message> children with sender, alias, and
/// time attributes. This mirrors what AIXMLChatlogConverter reads.
@MainActor
public enum ClassicLogImporter {

    public struct ImportSummary {
        public let perHandle: [(handle: String, imported: Int)]
        public let skippedFiles: Int
    }

    /// This imports one .chatlog bundle, one .xml file, or every chatlog
    /// found under a picked folder.
    public static func importLogs(from url: URL, into store: ChatLogStore) throws -> ImportSummary {
        var xmlFiles: [URL] = []
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
            if url.pathExtension.lowercased() == "chatlog" {
                xmlFiles = findXMLBundles(in: url)
            } else {
                xmlFiles = findChatlogsRecursive(root: url, limit: 500)
            }
        } else {
            xmlFiles = [url]
        }

        var importedByHandle: [String: Int] = [:]
        var skipped = 0
        for xml in xmlFiles {
            do {
                let parsed = try ParsedChatlog.load(at: xml)
                guard !parsed.messages.isEmpty else {
                    skipped += 1
                    continue
                }
                let existing = store.loadMessages(for: parsed.handle) ?? []
                let merged = merge(existing: existing, incoming: parsed.messages)
                store.saveMessages(merged, for: parsed.handle)
                importedByHandle[parsed.handle, default: 0] += parsed.messages.count
            } catch {
                skipped += 1
            }
        }
        return ImportSummary(
            perHandle: importedByHandle.map { (handle: $0.key, imported: $0.value) }
                .sorted { $0.handle < $1.handle },
            skippedFiles: skipped
        )
    }

    /// This appends incoming logs to the stored ones and drops duplicates
    /// by timestamp, direction, and text, so a re-import does not double.
    nonisolated static func merge(existing: [ChatMessage], incoming: [ChatMessage]) -> [ChatMessage] {
        var result = existing
        var seen = Set(existing.map(Self.dedupeKey))
        for msg in incoming.sorted(by: { $0.timestamp < $1.timestamp }) {
            if seen.insert(Self.dedupeKey(msg)).inserted {
                result.append(msg)
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    nonisolated private static func dedupeKey(_ msg: ChatMessage) -> String {
        "\(msg.timestamp.timeIntervalSince1970)|\(msg.isFromMe)|\(msg.senderName)|\(msg.text)"
    }

    private static func findXMLBundles(in bundleDir: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: bundleDir, includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension.lowercased() == "xml" } ?? []
    }

    private static func findChatlogsRecursive(root: URL, limit: Int) -> [URL] {
        var found: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey]
        )
        while let next = enumerator?.nextObject() as? URL, found.count < limit {
            let ext = next.pathExtension.lowercased()
            if ext == "xml", next.deletingLastPathComponent().pathExtension.lowercased() == "chatlog" {
                found.append(next)
            } else if ext == "xml" {
                found.append(next)
            }
        }
        return found
    }
}

/// This parses one classic Adium chatlog XML file.
struct ParsedChatlog {
    let handle: String
    let messages: [ChatMessage]

    /// The contact handle comes from the .chatlog folder name, falling
    /// back to the XML file stem.
    static func load(at xmlURL: URL) throws -> ParsedChatlog {
        let folder = xmlURL.deletingLastPathComponent()
        let rawHandle: String
        if folder.pathExtension.lowercased() == "chatlog" {
            rawHandle = folder.deletingPathExtension().lastPathComponent
        } else {
            rawHandle = xmlURL.deletingPathExtension().lastPathComponent
        }
        let parser = XMLParser(contentsOf: xmlURL)
        let delegate = Delegate()
        parser?.delegate = delegate
        guard let parser, parser.parse() else {
            throw NSError(domain: "ClassicLogImporter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: xmlURL.lastPathComponent])
        }
        return ParsedChatlog(handle: rawHandle, messages: delegate.messages)
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var messages: [ChatMessage] = []
        private var account = ""
        private var currentSender = ""
        private var currentAlias = ""
        private var currentTime: Date?
        private var buffer = ""
        private var insideMessage = false

        private let timeFormats: [DateFormatter] = [
            {
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZZZ"
                f.locale = Locale(identifier: "en_US_POSIX")
                return f
            }(),
        ]

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            switch elementName.lowercased() {
            case "chat":
                account = attributeDict["account"] ?? ""
            case "message":
                insideMessage = true
                currentSender = attributeDict["sender"] ?? ""
                currentAlias = attributeDict["alias"] ?? ""
                currentTime = nil
                buffer = ""
                let rawTime = attributeDict["time"] ?? ""
                for formatter in timeFormats {
                    if let date = formatter.date(from: rawTime) {
                        currentTime = date
                        break
                    }
                }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if insideMessage { buffer += string }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            if insideMessage, let text = String(data: CDATABlock, encoding: .utf8) {
                buffer += text
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard elementName.lowercased() == "message" else { return }
            defer {
                insideMessage = false
                buffer = ""
            }
            let loweredSender = currentSender.lowercased()
            let loweredAccount = account.lowercased()
            let isFromMe = !loweredAccount.isEmpty
                && (loweredSender == loweredAccount || loweredSender.hasSuffix(loweredAccount))
            let text = RichTextFormatter.decodeHTMLEntities(buffer)
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty || currentTime != nil else { return }
            messages.append(ChatMessage(
                senderName: currentAlias.isEmpty ? currentSender : currentAlias,
                isFromMe: isFromMe,
                text: text,
                timestamp: currentTime ?? Date(),
                isSystemEvent: false
            ))
        }
    }
}
