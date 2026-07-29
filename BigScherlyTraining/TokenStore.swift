import Foundation
import Security

/// Secure storage for the auth token.
///
/// Replaces the previous `UserDefaults` storage, which is readable from an
/// unencrypted device backup. Items are written with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, meaning the token:
///   • is never included in an iCloud or iTunes backup,
///   • never syncs to another device,
///   • is unreadable until the device has been unlocked once after boot.
///
/// Add this file to the main app target.
enum TokenStore {

    private static let service = "com.ncbproductions.bigscherlytraining"
    private static let account = "auth-token"
    private static let legacyDefaultsKey = "bst_token"

    // MARK: Public API

    static func save(_ token: String) {
        guard let data = token.data(using: .utf8) else { return }

        // Remove any existing item first — SecItemUpdate can't change accessibility.
        SecItemDelete(baseQuery() as CFDictionary)

        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(attrs as CFDictionary, nil)
        #if DEBUG
        if status != errSecSuccess { print("TokenStore.save failed: \(status)") }
        #endif
    }

    static func load() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecSuccess, let data = item as? Data,
           let token = String(data: data, encoding: .utf8) {
            return token
        }

        // One-time migration: an older build stored the token in UserDefaults.
        // Move it into the Keychain and scrub the insecure copy so existing
        // users are not forced to log in again.
        if let legacy = UserDefaults.standard.string(forKey: legacyDefaultsKey), !legacy.isEmpty {
            save(legacy)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
            UserDefaults.standard.synchronize()
            return legacy
        }

        return nil
    }

    static func clear() {
        SecItemDelete(baseQuery() as CFDictionary)
        // Belt and braces: make sure no stale insecure copy survives a logout.
        UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
    }

    // MARK: Private

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String:       kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
