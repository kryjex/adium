import Testing
import Foundation
@testable import AdiumSwift

@Suite("Plugin Catalog & Manager Tests")
struct PluginManagerTests {

    /// Loads the bundled catalog JSON directly, the same way PluginManager does at launch.
    private func loadBundledEntries() throws -> [PluginCatalogEntry] {
        let url = try #require(Bundle.module.url(forResource: "plugins-catalog", withExtension: "json"))
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PluginCatalog.self, from: data).plugins
    }

    @Test("Bundled catalog JSON decodes with at least 2 entries, each with an en description")
    func testBundledCatalogDecodes() throws {
        let entries = try loadBundledEntries()
        #expect(entries.count >= 2)
        for entry in entries {
            #expect(!(entry.description["en"] ?? "").isEmpty)
        }
    }

    @Test("setEnabled/isDisabled round-trip and persist in UserDefaults")
    @MainActor
    func testDisabledSetRoundTrip() {
        let filename = "libtest-round-trip.so"
        let defaults = UserDefaults.standard
        let originalValue = defaults.array(forKey: "AdiumDisabledPlugins")

        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: "AdiumDisabledPlugins")
            } else {
                defaults.removeObject(forKey: "AdiumDisabledPlugins")
            }
        }

        let manager = PluginManager.shared

        #expect(manager.isDisabled(filename: filename) == false)

        manager.setEnabled(false, filename: filename)
        #expect(manager.isDisabled(filename: filename) == true)
        let stored = defaults.stringArray(forKey: "AdiumDisabledPlugins") ?? []
        #expect(stored.contains(filename))

        manager.setEnabled(true, filename: filename)
        #expect(manager.isDisabled(filename: filename) == false)
        let storedAfterEnable = defaults.stringArray(forKey: "AdiumDisabledPlugins") ?? []
        #expect(!storedAfterEnable.contains(filename))
    }

    @Test("localizedDescription falls back to en when the current language is missing")
    func testLocalizedDescriptionFallsBackToEnglish() {
        let defaults = UserDefaults.standard
        let originalLanguage = defaults.string(forKey: AppLanguage.defaultsKey)

        defer {
            if let originalLanguage {
                defaults.set(originalLanguage, forKey: AppLanguage.defaultsKey)
            } else {
                defaults.removeObject(forKey: AppLanguage.defaultsKey)
            }
        }

        // "de" has no entry here, so the lookup must fall back to "en".
        defaults.set("de", forKey: AppLanguage.defaultsKey)

        let entry = PluginCatalogEntry(
            id: "test-entry",
            name: "Test Plugin",
            filename: "libtest.so",
            protocolId: nil,
            description: ["en": "English fallback text"],
            version: "1.0",
            binaryUrl: nil,
            sha256: nil,
            sourceUrl: URL(string: "https://example.com")!,
            license: "GPL-3.0"
        )

        #expect(entry.localizedDescription == "English fallback text")
    }

    @Test("SHA-256 verify helper accepts a matching hash and rejects a wrong one")
    func testSHA256Verification() {
        let data = Data("AdiumSwift plugin test payload".utf8)
        let correctHex = "875a856ad0fdf04d4af06f6296f5f8cc4cb91e976899585bf99038307e8c279f"
        let wrongHex = String(repeating: "0", count: 64)

        #expect(PluginManager.sha256Matches(data: data, expectedHex: correctHex))
        // A mixed-case hex string must still match: the comparison is case-insensitive.
        #expect(PluginManager.sha256Matches(data: data, expectedHex: correctHex.uppercased()))
        #expect(!PluginManager.sha256Matches(data: data, expectedHex: wrongHex))
    }
}
