import Foundation

/// This returns the localized text for a key.
/// All user-facing strings must go through this function.
/// The key is the English text. The translations live in
/// scripts/l10n/<lang>.json and generate Resources/<lang>.lproj/Localizable.strings.
/// Interpolated values become format specifiers in the key
/// (String -> %@, Int -> %lld).
public func t(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: AppLanguage.bundle)
}

/// This is one language the app ships.
/// The name is an endonym, so it is not localized.
public struct AppLanguageOption: Identifiable, Hashable, Sendable {
    public let code: String
    public let name: String
    public var id: String { code }
}

public enum AppLanguage {
    /// An empty value follows the system language.
    public static let defaultsKey = "AdiumLanguage"

    public static let options: [AppLanguageOption] = [
        AppLanguageOption(code: "en", name: "English"),
        AppLanguageOption(code: "es", name: "Español"),
        AppLanguageOption(code: "de", name: "Deutsch"),
        AppLanguageOption(code: "sv", name: "Svenska"),
        AppLanguageOption(code: "nb", name: "Norsk (bokmål)"),
        AppLanguageOption(code: "it", name: "Italiano"),
        AppLanguageOption(code: "fr", name: "Français"),
        AppLanguageOption(code: "ru", name: "Русский")
    ]

    /// The locale that matches the chosen UI language.
    /// Date and number formatters use this so day names follow the UI.
    public static let locale: Locale = {
        let code = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        return code.isEmpty ? .current : Locale(identifier: code)
    }()

    /// The bundle resolves once at launch.
    /// A language change applies after a restart.
    static let bundle: Bundle = {
        let code = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        guard !code.isEmpty,
              let path = Bundle.module.path(forResource: code, ofType: "lproj"),
              let languageBundle = Bundle(path: path) else {
            return .module
        }
        return languageBundle
    }()
}
