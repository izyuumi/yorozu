import CryptoKit
import Foundation
import Security

enum PreviewKeychain {
    private static let service = "to.yumi.yorozu.v2.push-preview"
    private static let account = "host"

    private static var query: [String: Any]? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "YorozuNotificationKeychainAccessGroup") as? String else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrAccessGroup as String: group]
    }

    static func save(_ key: SymmetricKey) {
        guard let query else { return }
        let values: [String: Any] = [kSecValueData as String: key.withUnsafeBytes { Data($0) },
                                     kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        if SecItemUpdate(query as CFDictionary, values as CFDictionary) == errSecItemNotFound {
            SecItemAdd(query.merging(values) { _, new in new } as CFDictionary, nil)
        }
    }

    static func load() -> SymmetricKey? {
        guard var query else { return nil }
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    static func clear() {
        guard let query else { return }
        SecItemDelete(query as CFDictionary)
    }
}
