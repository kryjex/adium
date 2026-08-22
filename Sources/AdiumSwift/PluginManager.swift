import Foundation
import CryptoKit
import CLibpurple

/// One row in the plugin catalog. This is a libpurple protocol plugin the
/// user can install without a rebuild.
public struct PluginCatalogEntry: Codable, Identifiable, Hashable, Sendable {
    public let id: String                    // "purple-teams"
    public let name: String                  // "Microsoft Teams"
    public let filename: String              // "libteams.so"
    public let protocolId: String?           // "prpl-eionrobb-msteams"
    public let description: [String: String] // language code -> text, "en" always present
    public let version: String
    public let binaryUrl: URL?               // nil until CI publishes binaries
    public let sha256: String?               // required when binaryUrl is set
    public let sourceUrl: URL
    public let license: String

    public init(
        id: String,
        name: String,
        filename: String,
        protocolId: String?,
        description: [String: String],
        version: String,
        binaryUrl: URL?,
        sha256: String?,
        sourceUrl: URL,
        license: String
    ) {
        self.id = id
        self.name = name
        self.filename = filename
        self.protocolId = protocolId
        self.description = description
        self.version = version
        self.binaryUrl = binaryUrl
        self.sha256 = sha256
        self.sourceUrl = sourceUrl
        self.license = license
    }

    /// This picks the AppLanguage override first, then the system language,
    /// then falls back to "en". A catalog entry always ships an "en" text.
    public var localizedDescription: String {
        let override = UserDefaults.standard.string(forKey: AppLanguage.defaultsKey) ?? ""
        if !override.isEmpty, let text = description[override] {
            return text
        }
        if let systemCode = Locale.preferredLanguages.first.map({ String($0.prefix(2)) }),
           let text = description[systemCode] {
            return text
        }
        return description["en"] ?? ""
    }
}

/// This is the top-level shape of plugins.json in the catalog repository.
public struct PluginCatalog: Codable, Sendable {
    public let catalogVersion: Int
    public let plugins: [PluginCatalogEntry]
}

/// This manages the optional protocol plugins: which ones are installed,
/// which ones are enabled, and the catalog of plugins available to install.
@MainActor
@Observable
public final class PluginManager {
    public static let shared = PluginManager()

    public struct InstalledPlugin: Identifiable, Hashable {
        public let id: String        // the .so filename, e.g. "libteams.so"
        public var name: String      // catalog name when matched, else the filename
        public var path: String
        public var isEnabled: Bool
        public var isBundled: Bool   // true when inside the app bundle (cannot be removed, only disabled)
        /// Only plugins in the managed user directory can be uninstalled.
        /// Bundled plugins are read-only, and ~/.purple/plugins belongs
        /// to other libpurple clients.
        public var canUninstall: Bool {
            path.hasPrefix(PluginManager.userPluginsDirectory.path + "/")
        }
        public var catalogEntryID: String?
    }

    public var installed: [InstalledPlugin] = []
    public var catalog: [PluginCatalogEntry] = []
    public var needsRestart: Bool = false            // true after a disable (unload applies on relaunch)
    public var lastCatalogError: String?             // localized, for the UI banner

    private static let disabledDefaultsKey = "AdiumDisabledPlugins"
    private static let installedVersionsDefaultsKey = "AdiumInstalledPluginVersions"
    private static let catalogCacheFilename = "plugins-catalog-cache.json"
    // The catalog lives in its own curated repository next to the app repo.
    private static let remoteCatalogURL = URL(
        string: "https://raw.githubusercontent.com/kryjex/adium-plugins-catalog/main/plugins.json"
    )!

    /// This is ~/.adium-swift/plugins. Installed plugins land here, outside the app bundle.
    nonisolated public static var userPluginsDirectory: URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".adium-swift", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }


    /// This is ~/.purple/plugins. Other libpurple clients (Pidgin) install
    /// their plugins here. AdiumSwift loads these files but never writes
    /// to this directory.
    nonisolated public static var purplePluginsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".purple", isDirectory: true)
            .appendingPathComponent("plugins", isDirectory: true)
    }

    private let fileManager = FileManager.default
    private let session: URLSession

    /// This tracks whether the bundled catalog JSON decoded at launch.
    /// loadCatalog() only reports an error when this also failed.
    private var bundledCatalogLoaded = false

    public init(session: URLSession = .shared) {
        self.session = session
        loadBundledCatalog()
    }

    private func loadBundledCatalog() {
        guard let url = Bundle.module.url(forResource: "plugins-catalog", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let entries = (try? JSONDecoder().decode(PluginCatalog.self, from: data))?.plugins else {
            return
        }
        catalog = entries
        bundledCatalogLoaded = true
    }

    // MARK: - Installed plugins

    /// This rebuilds `installed` from the given discovered .so paths.
    /// It matches each filename against the catalog to fill in a display name.
    public func refreshInstalled(discoveredPaths: [String]) {
        let disabled = disabledFilenames()
        let bundlePlugInsDir = Bundle.main.bundlePath + "/Contents/PlugIns"
        var byFilename: [String: PluginCatalogEntry] = [:]
        for entry in catalog {
            byFilename[entry.filename] = entry
        }

        var seen = Set<String>()
        var result: [InstalledPlugin] = []
        for path in discoveredPaths {
            let filename = (path as NSString).lastPathComponent
            guard !seen.contains(filename) else { continue }
            seen.insert(filename)
            let entry = byFilename[filename]
            result.append(InstalledPlugin(
                id: filename,
                name: entry?.name ?? filename,
                path: path,
                isEnabled: !disabled.contains(filename),
                isBundled: path.hasPrefix(bundlePlugInsDir),
                catalogEntryID: entry?.id
            ))
        }
        installed = result
    }

    public func isDisabled(filename: String) -> Bool {
        disabledFilenames().contains(filename)
    }

    /// This enables or disables a plugin by filename.
    /// Enabling a plugin that libpurple has not loaded yet loads it live.
    /// Disabling only marks it for the next launch: libpurple 2 protocol
    /// plugins with live accounts cannot unload safely at runtime.
    public func setEnabled(_ enabled: Bool, filename: String) {
        var disabled = disabledFilenames()

        if enabled {
            disabled.remove(filename)
            persistDisabled(disabled)
            if let idx = installed.firstIndex(where: { $0.id == filename }) {
                installed[idx].isEnabled = true
                _ = adium_purple_load_plugin(installed[idx].path)
            }
        } else {
            disabled.insert(filename)
            persistDisabled(disabled)
            needsRestart = true
            if let idx = installed.firstIndex(where: { $0.id == filename }) {
                installed[idx].isEnabled = false
            }
        }
    }

    private func disabledFilenames() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.disabledDefaultsKey) ?? [])
    }

    private func persistDisabled(_ set: Set<String>) {
        UserDefaults.standard.set(Array(set), forKey: Self.disabledDefaultsKey)
    }

    // MARK: - Catalog

    /// This loads the plugin catalog. The bundled JSON is already in
    /// `catalog` from init. A successful remote fetch replaces it and
    /// refreshes the on-disk cache. A network failure never blocks the UI:
    /// it falls back to the cache, then keeps the bundled data.
    public func loadCatalog() async {
        lastCatalogError = nil

        do {
            let (data, response) = try await session.data(from: Self.remoteCatalogURL)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            let entries = try JSONDecoder().decode(PluginCatalog.self, from: data).plugins
            catalog = entries
            try? fileManager.createDirectory(at: dataDirectory(), withIntermediateDirectories: true)
            try? data.write(to: catalogCacheURL())
            return
        } catch {
            // The remote fetch failed. Fall through to the cache.
        }

        if let cached = try? Data(contentsOf: catalogCacheURL()),
           let entries = (try? JSONDecoder().decode(PluginCatalog.self, from: cached))?.plugins {
            catalog = entries
            return
        }

        if !bundledCatalogLoaded {
            lastCatalogError = t("Could not load the plugin catalog. Check your connection and try again.")
        }
    }

    private func dataDirectory() -> URL {
        fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".adium-swift", isDirectory: true)
    }

    private func catalogCacheURL() -> URL {
        dataDirectory().appendingPathComponent(Self.catalogCacheFilename)
    }

    // MARK: - Install

    /// This downloads a plugin binary, verifies its checksum, and loads it live.
    /// It refuses to run when the catalog entry has no published binary yet.
    @discardableResult
    public func install(_ entry: PluginCatalogEntry) async -> Bool {
        guard let binaryUrl = entry.binaryUrl, let expectedSha = entry.sha256 else {
            lastCatalogError = t("This plugin has no downloadable binary yet.")
            return false
        }

        let downloadedURL: URL
        let response: URLResponse
        do {
            (downloadedURL, response) = try await session.download(from: binaryUrl)
        } catch {
            lastCatalogError = t("The plugin download failed. Check your connection and try again.")
            return false
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? fileManager.removeItem(at: downloadedURL)
            lastCatalogError = t("The plugin download failed. Check your connection and try again.")
            return false
        }

        guard let data = try? Data(contentsOf: downloadedURL) else {
            try? fileManager.removeItem(at: downloadedURL)
            lastCatalogError = t("The plugin download failed. Check your connection and try again.")
            return false
        }

        guard Self.sha256Matches(data: data, expectedHex: expectedSha) else {
            try? fileManager.removeItem(at: downloadedURL)
            lastCatalogError = t("The downloaded plugin failed the checksum check.")
            return false
        }

        let destination = Self.userPluginsDirectory.appendingPathComponent(entry.filename)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.moveItem(at: downloadedURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: downloadedURL)
            lastCatalogError = t("Could not install the plugin file.")
            return false
        }

        removeQuarantine(at: destination)
        _ = adium_purple_load_plugin(destination.path)

        var versions = installedVersions()
        versions[entry.filename] = entry.version
        persistInstalledVersions(versions)

        var disabled = disabledFilenames()
        disabled.remove(entry.filename)
        persistDisabled(disabled)

        var paths = Set(installed.map { $0.path })
        paths.insert(destination.path)
        refreshInstalled(discoveredPaths: Array(paths))

        return true
    }

    // MARK: - Local install / uninstall

    /// This copies a local .so file into the user plugins directory, strips
    /// the quarantine flag, and loads it live. The source file stays in place.
    @discardableResult
    public func installLocalPlugin(from source: URL) async -> Bool {
        guard source.pathExtension.lowercased() == "so" else {
            lastCatalogError = t("Only .so plugin files are supported.")
            return false
        }

        let destination = Self.userPluginsDirectory.appendingPathComponent(source.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        do {
            try fileManager.copyItem(at: source, to: destination)
        } catch {
            lastCatalogError = t("Could not install the plugin file.")
            return false
        }

        removeQuarantine(at: destination)
        _ = adium_purple_load_plugin(destination.path)

        var disabled = disabledFilenames()
        disabled.remove(destination.lastPathComponent)
        persistDisabled(disabled)

        var paths = Set(installed.map { $0.path })
        paths.insert(destination.path)
        refreshInstalled(discoveredPaths: Array(paths))
        return true
    }

    /// This deletes a user-installed plugin file. libpurple keeps the loaded
    /// code mapped until relaunch, so this sets needsRestart like a disable.
    @discardableResult
    public func uninstall(filename: String) -> Bool {
        guard let idx = installed.firstIndex(where: { $0.id == filename }),
              installed[idx].canUninstall else {
            return false
        }

        do {
            try fileManager.removeItem(atPath: installed[idx].path)
        } catch {
            lastCatalogError = t("Could not remove the plugin file.")
            return false
        }

        var versions = installedVersions()
        versions.removeValue(forKey: filename)
        persistInstalledVersions(versions)

        var disabled = disabledFilenames()
        disabled.remove(filename)
        persistDisabled(disabled)

        let remaining = installed.filter { $0.id != filename }.map { $0.path }
        refreshInstalled(discoveredPaths: remaining)
        needsRestart = true
        return true
    }

    /// A download from the network carries a quarantine flag. Gatekeeper
    /// would otherwise block libpurple from dlopen-ing it.
    private func removeQuarantine(at url: URL) {
        removexattr(url.path, "com.apple.quarantine", 0)
    }

    /// This computes the SHA-256 of `data` and compares it to `expectedHex`
    /// case-insensitively. Internal, not private, so tests can call it directly.
    nonisolated static func sha256Matches(data: Data, expectedHex: String) -> Bool {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return hex.caseInsensitiveCompare(expectedHex) == .orderedSame
    }

    // MARK: - Version tracking

    private func installedVersions() -> [String: String] {
        (UserDefaults.standard.dictionary(forKey: Self.installedVersionsDefaultsKey) as? [String: String]) ?? [:]
    }

    private func persistInstalledVersions(_ versions: [String: String]) {
        UserDefaults.standard.set(versions, forKey: Self.installedVersionsDefaultsKey)
    }

    /// This compares the catalog version against the version install() last
    /// recorded for this filename. An unknown installed version is not
    /// flagged as outdated: the plugin may predate version tracking.
    public func installedVersionOutdated(for entry: PluginCatalogEntry) -> Bool {
        guard let installedVersion = installedVersions()[entry.filename] else { return false }
        return installedVersion != entry.version
    }
}
