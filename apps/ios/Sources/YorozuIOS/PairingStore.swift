import Foundation
import Security
import YorozuShared

/// The one place this app talks to the Keychain. Everything it holds is a secret the phone
/// must not leak to `UserDefaults` or a plain file: the pairing's private keys, and the key
/// the local thread cache is encrypted with.
enum Keychain {
    private static let service = "to.yumi.yorozu.ios"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func save(_ data: Data, account: String) throws {
        SecItemDelete(query(account) as CFDictionary)
        var attributes = query(account)
        attributes[kSecValueData as String] = data
        // Only ever used while the user is present; no backup to another device.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }

    static func clear(_ account: String) {
        SecItemDelete(query(account) as CFDictionary)
    }
}

/// The pairing survives restarts in the Keychain: it holds the phone's private keys.
enum PairingStore {
    struct Stored: Codable {
        var pairing: QrPayload
        var identity: PhoneIdentity
    }

    private static let account = "pairing"

    static func load() -> Stored? {
        Keychain.load(account).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
    }

    static func save(_ stored: Stored) throws {
        try Keychain.save(JSONEncoder().encode(stored), account: account)
    }

    static func clear() {
        Keychain.clear(account)
    }
}
