import Foundation
import Security

/// Helper utility for managing account passwords securely in the macOS Keychain.
public enum KeychainHelper: Sendable {
    public static let defaultService = "com.adiumswift.keychain"
    
    /// Save password to Keychain for a specific account key.
    @discardableResult
    public static func savePassword(_ password: String, for accountKey: String, service: String = defaultService) -> Bool {
        guard let data = password.data(using: .utf8) else { return false }
        
        // Remove existing item before adding
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
    
    /// Fetch password from Keychain for a specific account key.
    public static func fetchPassword(for accountKey: String, service: String = defaultService) -> String? {
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
    
    /// Delete password from Keychain for a specific account key.
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
