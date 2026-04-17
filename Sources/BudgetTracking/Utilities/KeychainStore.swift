import Foundation
import Security

/// Thin wrapper around the macOS Keychain for storing short string secrets
/// (API keys, tokens, shared secrets) under generic-password items keyed
/// by account name.
///
/// Values stored here are encrypted by the OS, protected by the user's
/// login credentials, and survive app deletion (so the user does not
/// lose their API keys when reinstalling). UserDefaults is fine for
/// non-sensitive preferences but never for anything that grants access
/// to an external system.
enum KeychainStore {

    /// Save a value under `key`. If a value already exists under this
    /// key it is replaced. A nil or empty value deletes the entry
    /// entirely so the UI can round-trip to "unset".
    static func set(_ value: String?, forKey key: String) {
        guard let value, !value.isEmpty else {
            delete(forKey: key)
            return
        }
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Read a value previously stored under `key`. Returns nil if the
    /// key does not exist or the stored data is not UTF-8 decodable.
    static func get(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Remove the value stored under `key`. No-op if it is already gone.
    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
