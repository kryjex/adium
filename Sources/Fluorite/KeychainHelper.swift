import Foundation
import Security

/// This utility manages account passwords securely in the macOS Keychain.
public enum KeychainHelper: Sendable {
    public static let defaultService = "com.fluorite.keychain"

    /// The service name the app used before it was renamed from AdiumSwift.
    /// `fetchPassword` falls back to this and migrates the item forward, so
    /// a rename never locks a user out of an already-saved password.
    private static let legacyService = "com.adiumswift.keychain"

    /// This saves a password to the Keychain for a specific account key.
    @discardableResult
    public static func savePassword(_ password: String, for accountKey: String, service: String = defaultService) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }

        // This removes an existing item before it adds a new one.
        deletePassword(for: accountKey, service: service)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// This fetches a password from the Keychain for a specific account key.
    /// A miss under `service` falls back to the pre-rename service; a hit
    /// there is copied forward to `service` so the next fetch skips the
    /// fallback and the legacy item can eventually be deleted.
    public static func fetchPassword(for accountKey: String, service: String = defaultService) -> String? {
        if let password = fetchRaw(for: accountKey, service: service) {
            return password
        }
        guard service == defaultService,
              let legacy = fetchRaw(for: accountKey, service: legacyService) else {
            return nil
        }
        savePassword(legacy, for: accountKey, service: service)
        return legacy
    }

    private static func fetchRaw(for accountKey: String, service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var dataTypeRef: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &dataTypeRef)

        guard status == errSecSuccess, let data = dataTypeRef as? Data else {
            return nil
        }

        return String(data: data, encoding: .utf8)
    }
    
    /// This deletes a password from the Keychain for a specific account key.
    @discardableResult
    public static func deletePassword(for accountKey: String, service: String = defaultService) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountKey
        ]
        
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
