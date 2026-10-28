import Foundation
import Security

enum Keychain {
    private static let service = "to.yumi.yorozu.ios"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(query(account) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query(account)
            attributes.merge(values) { _, new in new }
            status = SecItemAdd(attributes as CFDictionary, nil)
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

