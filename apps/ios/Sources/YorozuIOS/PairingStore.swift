import Foundation
import Security
import YorozuWire

/// Private keys stay in the app's Keychain. Updating an item must never delete its previous
/// value before the write succeeds.
enum Keychain {
    private static let service = "to.yumi.yorozu.ios"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
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

/// The one host this phone is paired with, replaced in one atomic Keychain update. Its own account,
/// so v1's `pairings` record is never read: a v2 phone pairs afresh. The synchronous lock covers
/// each complete read-modify-write: the relay actor's counter saves and the main actor's `paired`
/// update must not overwrite each other.
enum PairingStore {
    struct Stored: Codable {
        var pairing: QrPayload
        var identity: PhoneIdentity
        var paired: Bool?
        var pairedAt: Date?
        var counters: ChannelCounter?
    }

    private static let account = "pairings-v2"
    private static let lock = NSRecursiveLock()

    fileprivate static func synchronized<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    /// Startup must distinguish no pairing from inaccessible or damaged pairing data.
    static func loadRequired() throws -> Stored? {
        try synchronized {
            guard let data = try Keychain.loadRequired(account) else { return nil }
            return try JSONDecoder().decode(Stored.self, from: data)
        }
    }

    /// Replaces whatever was stored: a new pairing is a new identity with fresh counters.
    static func save(_ stored: Stored) throws {
        try synchronized { try Keychain.save(JSONEncoder().encode(stored), account: account) }
    }

    static func remove() throws {
        try synchronized { try Keychain.clearRequired(account) }
    }

    static func markPaired(expectedIdentity: Data) {
        try? update(expectedIdentity: expectedIdentity) { stored in
            if stored.paired != true {
                stored.paired = true
                stored.pairedAt = Date()
                stored.pairing.token = ""
            }
        }
    }

    /// Only the pairing that owns `expectedIdentity`: a relay left over from a replaced pairing
    /// cannot write into its successor.
    fileprivate static func update(expectedIdentity: Data, _ work: (inout Stored) throws -> Void) throws {
        try synchronized {
            guard var stored = try loadRequired(), stored.identity.sessionPublicKey == expectedIdentity else {
                throw PairingCounterStorage.NoPairing()
            }
            try work(&stored)
            try save(stored)
        }
    }
}

/// The host's counters live alongside its private keys. A removed/repaired connection cannot
/// update the replacement identity through a counter-store instance retained by its old relay.
struct PairingCounterStorage: ChannelCounterStorage {
    struct NoPairing: Error {}

    let ownPublicKey: Data

    func load() throws -> ChannelCounter? {
        try PairingStore.synchronized {
            guard let stored = try PairingStore.loadRequired() else { return nil }
            guard stored.identity.sessionPublicKey == ownPublicKey else { throw NoPairing() }
            return stored.counters
        }
    }

    func save(_ counter: ChannelCounter) throws {
        try PairingStore.update(expectedIdentity: ownPublicKey) { $0.counters = counter }
    }

    func clear() throws {
        try PairingStore.synchronized {
            guard try PairingStore.loadRequired() != nil else { return }
            // Counters can disappear only with their keys: remove() does both atomically.
            throw YorozuCrypto.CryptoError.malformed(String(localized: "remove the pairing to clear channel counters"))
        }
    }
}
