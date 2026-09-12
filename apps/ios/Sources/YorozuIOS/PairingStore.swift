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
        /// Set once the relay has accepted this device. From then on the phone rejoins by
        /// signing the connect nonce, so `pairing.token` — one-time, and long burnt — is not
        /// sent again and is not kept either.
        ///
        /// Optional rather than defaulted: a synthesized `Codable` has no fallback for a missing
        /// key, and absent is what a pairing stored before this existed looks like — which is
        /// exactly a pairing whose token has not been redeemed yet.
        var paired: Bool?
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

    /// Records that the relay knows this device, and drops the spent token with it. Best effort:
    /// failing to persist it costs a re-pair, not the running connection.
    static func markPaired() {
        guard var stored = load(), stored.paired != true else { return }
        stored.paired = true
        stored.pairing.token = ""
        try? save(stored)
    }
}
