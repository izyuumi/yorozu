import CryptoKit
import Foundation
import Security

/// The one key the notification service extension needs: the paired Mac's `PushPreview` key, derived by the app and kept in
/// the Keychain group the two share (`YorozuNotificationKeychainAccessGroup` in both Info.plists). The pairing's private keys
/// stay in the app's own group; the extension can open preview boxes and nothing else.
enum PreviewKeychain {
    /// Not v1's `to.yumi.yorozu.notification-preview` (same bundle id, same group): a v1 key left behind is never read.
    private static let service = "to.yumi.yorozu.v2.push-preview"
    private static let account = "host"

    private static var query: [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "YorozuNotificationKeychainAccessGroup") as? String else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
    }

    /// App: replaces the stored key. Readable after the first unlock, so a push to a locked phone still opens.
    static func save(_ key: SymmetricKey) {
        guard let query else { return }
        let values: [String: Any] = [kSecValueData as String: key.withUnsafeBytes { Data($0) },
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, values as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
    }

    /// Extension: the key, or nil (no pairing, before the first unlock, entitlement missing).
    static func load() -> SymmetricKey? {
        guard var query else { return nil }
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// App: Remove host.
    static func clear() {
        guard let query else { return }
        SecItemDelete(query as CFDictionary)
    }
}
