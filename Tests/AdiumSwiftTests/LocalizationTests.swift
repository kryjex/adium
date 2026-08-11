import Testing
import Foundation
@testable import AdiumSwift

/// These tests keep the en and es string tables synchronized.
/// scripts/check-l10n.py covers the code-to-table direction.
@Suite("Localization")
struct LocalizationTests {

    private func stringsTable(for localization: String) throws -> [String: String] {
        let url = try #require(
            Bundle.module.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: localization),
            "Missing Localizable.strings for \(localization)"
        )
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    static let shippedLanguages = ["es", "de", "sv", "nb", "it", "fr", "ru"]

    @Test("every language table matches the en key set with no empty values", arguments: shippedLanguages)
    func testTablesAreInSync(language: String) throws {
        let en = try stringsTable(for: "en")
        let localized = try stringsTable(for: language)
        #expect(!en.isEmpty)
        #expect(Set(en.keys) == Set(localized.keys))
        let emptyValues = (Array(en.values) + Array(localized.values)).filter { $0.isEmpty }
        #expect(emptyValues.isEmpty)
    }

    @Test("t() resolves known keys in every locale")
    func testResolvesKnownKeys() {
        #expect(!t("Cancel").isEmpty)
        #expect(!t("No accounts").isEmpty)
    }
}
