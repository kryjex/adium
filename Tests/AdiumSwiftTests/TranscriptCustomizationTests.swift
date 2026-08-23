import Testing
import Foundation
@testable import AdiumSwift

/// Fase 4: transcript export/import. Fase 6: emoticon packs and sound sets.
@Suite("Transcript Export/Import & Customization Tests")
struct TranscriptExportImportTests {

    @MainActor
    private func makeIsolatedLogs() -> (ChatLogStore, URL) {
        let store = ChatLogStore.shared
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("TestLogs_\(UUID().uuidString)")
        store.customLogsDirectory = temp
        return (store, temp)
    }
    @MainActor
    func testHTMLExportEscapesAndShapes() throws {
        let (store, temp) = makeIsolatedLogs()
        defer { try? FileManager.default.removeItem(at: temp) }

        let messages = [
            ChatMessage(senderName: "Eve <script>", isFromMe: false,
                        text: "hello & <b>bold</b>"),
            ChatMessage(senderName: "Me", isFromMe: true, text: "hi there"),
        ]
        let target = temp.appendingPathComponent("out.html")
        try store.exportTranscript(
            messages: messages, handle: "peer@test", displayName: "Peer",
            protocolType: .teams, format: .html, to: target
        )

        let html = try String(contentsOf: target, encoding: .utf8)
        #expect(html.contains("<!DOCTYPE html>"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("hello &amp; &lt;b&gt;bold&lt;/b&gt;"))
        #expect(!html.contains("<b>bold</b>"))
        // Day separators and both alignment classes appear.
        #expect(html.contains(#"class="day""#))
        #expect(html.contains(#"class="msg me""#))
        #expect(html.contains(#"class="msg them""#))
    }

    @Test("Classic .chatlog XML imports with direction and alias mapping")
    @MainActor
    func testClassicChatlogImport() throws {
        let (store, logsTemp) = makeIsolatedLogs()
        let bundleTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("peer@test.com.chatlog")
        try FileManager.default.createDirectory(at: bundleTemp, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: logsTemp)
            try? FileManager.default.removeItem(at: bundleTemp)
        }

        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <chat xmlns="http://adiumx.com/chatlog/" account="me@test.com" service="XMPP" type="IM">
        <message sender="me@test.com" time="2007-04-17T22:10:33-0500"><div><span style="color: red">hola</span></div></message>
        <message sender="peer@test.com" alias="Pepe" time="2007-04-17T22:11:00-0500">qué tal</message>
        </chat>
        """
        let xmlURL = bundleTemp.appendingPathComponent("peer@test.com.xml")
        try xml.data(using: .utf8)!.write(to: xmlURL)

        let summary = try ClassicLogImporter.importLogs(from: bundleTemp, into: store)

        #expect(summary.perHandle.count == 1)
        #expect(summary.perHandle.first?.handle == "peer@test.com")
        #expect(summary.perHandle.first?.imported == 2)
        #expect(summary.skippedFiles == 0)

        let imported = try #require(store.loadMessages(for: "peer@test.com"))
        #expect(imported.count == 2)
        // The account sender maps to an own message; the alias becomes the name.
        #expect(imported.first(where: { $0.text == "hola" })?.isFromMe == true)
        #expect(imported.first(where: { $0.text == "qué tal" })?.senderName == "Pepe")
        #expect(imported.first(where: { $0.text == "qué tal" })?.isFromMe == false)
        // HTML inside the message body does not leak tags into the stored text.
        #expect(imported.first(where: { $0.text == "hola" })?.text == "hola")

        // A re-import must not duplicate anything.
        _ = try ClassicLogImporter.importLogs(from: bundleTemp, into: store)
        #expect(store.loadMessages(for: "peer@test.com")?.count == 2)
    }

    @Test("A custom emoticon pack overrides built-in shortcuts")
    func testCustomEmoticonPackOverrides() {
        let defaults = UserDefaults.standard
        let original = defaults.data(forKey: "AdiumCustomEmoticons")
        defer {
            if let original {
                defaults.set(original, forKey: "AdiumCustomEmoticons")
            } else {
                defaults.removeObject(forKey: "AdiumCustomEmoticons")
            }
        }

        // Without a pack the smiley keeps its built-in emoji.
        let builtin = RichTextFormatter.activeEmoticonMap[":-)"]
        #expect(builtin != nil && builtin != "🫠")

        let pack = try! JSONEncoder().encode([":-)": "🫠"])
        defaults.set(pack, forKey: "AdiumCustomEmoticons")

        #expect(RichTextFormatter.activeEmoticonMap[":-)"] == "🫠")
        // Built-in entries the pack does not touch survive.
        #expect(RichTextFormatter.activeEmoticonMap[":-D"] == RichTextFormatter.emoticonMap[":-D"])
        #expect(RichTextFormatter.replaceEmoticons(in: "nice work :-) ") == "nice work 🫠 ")
    }

    @Test("Classic sound keys map per event type")
    func testClassicSoundKeyMapping() {
        #expect(EventManager.classicSoundKey(for: .messageReceived) == "Message Received")
        #expect(EventManager.classicSoundKey(for: .groupMention) == "Message Received")
        #expect(EventManager.classicSoundKey(for: .contactOnline) == "Contact Sign On")
        #expect(EventManager.classicSoundKey(for: .transferCompleted) == "File Transfer Complete")
        #expect(EventManager.classicSoundKey(for: .accountConnected) == nil)
    }
}
