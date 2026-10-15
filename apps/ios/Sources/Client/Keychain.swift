import Foundation
import Security

/// Private keys stay in the app's Keychain. Updating an item must never delete its previous
/// value before the write succeeds.
enum Keychain {
    /// The client app's own, on iPhone, iPad and Mac (#419).
    private static let service = "to.yumi.yorozu.ios"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            // Never iCloud Keychain: the keys stay on this device (#415).
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    static func loadRequired(_ account: String) throws -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return data
    }

    static func save(_ data: Data, account: String) throws {
        // This device only. After first unlock rather than `WhenUnlocked`: a silent push (#431) reconnects and
        // handshakes in the background, while the phone may be locked, and needs the keys for that.
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(account)
            attributes.merge(values) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
            // Another writer may have created it between the lookup and insertion.
            if status == errSecDuplicateItem {
                status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
            }
        }
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func clearRequired(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

