import Foundation
import Security
import YorozuShared

/// The pairing survives reinstall-free restarts in the Keychain: it holds the phone's private
/// keys, so it must never reach `UserDefaults` or a plain file.
enum PairingStore {
    struct Stored: Codable {
        var pairing: QrPayload
        var identity: PhoneIdentity
    }

    private static let service = "to.yumi.yorozu.ios"
    private static let account = "pairing"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load() -> Stored? {
        var query = self.query
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
            let data = item as? Data
        else { return nil }
        return try? JSONDecoder().decode(Stored.self, from: data)
    }

    static func save(_ stored: Stored) throws {
        let data = try JSONEncoder().encode(stored)
        SecItemDelete(query as CFDictionary)
        var attributes = query
        attributes[kSecValueData as String] = data
        // Pairing is only ever used while the user is present; no backup to another device.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}
