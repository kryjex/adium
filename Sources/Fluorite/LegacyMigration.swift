import Foundation

/// This moves data left behind by the app's former name (AdiumSwift) to
/// its current paths, once. It runs before any other service touches disk
/// or UserDefaults, so nothing reads an empty new location while real data
/// still sits at the old one.
enum LegacyMigration {

    private static let migratedKey = "FluoriteMigratedFromAdiumSwift"

    static func runOnce() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        defer { defaults.set(true, forKey: migratedKey) }

        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        moveIfNeeded(
            from: home.appendingPathComponent(".adium-swift", isDirectory: true),
            to: home.appendingPathComponent(".fluorite", isDirectory: true),
            fm: fm
        )

        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        moveIfNeeded(
            from: appSupport.appendingPathComponent("AdiumSwift", isDirectory: true),
            to: appSupport.appendingPathComponent("Fluorite", isDirectory: true),
            fm: fm
        )
    }

    /// This moves the old directory in place, only when the old one exists
    /// and the new one does not -- never overwrites data a fresh install
    /// already wrote at the new path.
    private static func moveIfNeeded(from old: URL, to new: URL, fm: FileManager) {
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }
}
