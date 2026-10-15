import Foundation
import Security
import UIKit

// MARK: - This phone's id for 2-step sign-in (server 2.4.0, Oct 11, 2026)
// A random id made once and kept in the Keychain, "this device only": it survives app
// updates and reinstalls, but a new phone (or one restored from a backup) gets a new id,
// so it's asked for an emailed code once. The server stores only a hash of it.
enum DeviceIdentity {
    private static let service = "com.ncbproductions.bigscherlytraining"
    private static let account = "device-id"

    static var id: String {
        if let existing = load() { return existing }
        let fresh = UUID().uuidString + "-" + UUID().uuidString
        save(fresh)
        return load() ?? fresh
    }

    /// Shown in the code email and in Coach HQ ▸ Settings ("iPhone", "iPad").
    static var name: String {
        let model = UIDevice.current.model
        return model.isEmpty ? "Phone" : model
    }

    private static func baseQuery() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    private static func load() -> String? {
        var q = baseQuery()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    private static func save(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }
        SecItemDelete(baseQuery() as CFDictionary)
        var attrs = baseQuery()
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }
}
