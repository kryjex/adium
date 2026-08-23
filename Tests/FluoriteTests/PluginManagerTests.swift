import Testing
import Foundation
@testable import Fluorite

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
        let data = Data("libpurple plugin test payload".utf8)
        let correctHex = "d9f3aa4d010ce8d5c0b766abfdb3ca7879a422e450336df217d53a6deefbf6fa"
        let wrongHex = String(repeating: "0", count: 64)

        #expect(PluginManager.sha256Matches(data: data, expectedHex: correctHex))
        // A mixed-case hex string must still match: the comparison is case-insensitive.
        #expect(PluginManager.sha256Matches(data: data, expectedHex: correctHex.uppercased()))
        #expect(!PluginManager.sha256Matches(data: data, expectedHex: wrongHex))
    }

    @Test("refreshInstalled marks only user-directory plugins as uninstallable")
    @MainActor
    func testInstalledOriginFlags() {
        let manager = PluginManager.shared
        let original = manager.installed
        defer { manager.installed = original }

        let home = NSHomeDirectory()
        let userPath = home + "/.fluorite/plugins/libuser-test.so"
        let purplePath = home + "/.purple/plugins/libpidgin-test.so"

        manager.refreshInstalled(discoveredPaths: [userPath, purplePath])

        #expect(manager.installed.count == 2)
        for plugin in manager.installed {
            // Neither path is inside the app bundle.
            #expect(!plugin.isBundled)
            if plugin.path == userPath {
                #expect(plugin.canUninstall)
            } else {
                // ~/.purple/plugins is external: loadable but not removable.
                #expect(!plugin.canUninstall)
            }
        }
    }

    @Test("installLocalPlugin rejects non-.so files before touching the disk")
    @MainActor
    func testInstallLocalPluginRejectsWrongExtension() async {
        let manager = PluginManager.shared
        let originalError = manager.lastCatalogError
        defer { manager.lastCatalogError = originalError }

        let installed = await manager.installLocalPlugin(
            from: URL(fileURLWithPath: "/tmp/not-a-plugin.txt")
        )

        #expect(!installed)
        #expect(manager.lastCatalogError != nil)
    }
}
