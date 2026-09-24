import Foundation
import Security
import YorozuShared

/// Private keys and cache keys stay in the app's Keychain, including while locked background
/// catch-up runs. Updating an item must never delete its previous value before the write succeeds.
enum Keychain {
    private static let service = "to.yumi.yorozu.ios"

    private static func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func load(_ account: String) -> Data? { try? loadRequired(account) }

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

    static func clear(_ account: String) { try? clearRequired(account) }

    static func clearRequired(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
    }
}

/// All pairing records are replaced in one atomic Keychain update. The synchronous lock covers
/// each complete read-modify-write: different hosts' relay actors otherwise lose one another's
/// counters, and nickname/paired callbacks must not overwrite a newer counter snapshot.
enum PairingStore {
    struct Stored: Codable {
        var pairing: QrPayload
        var identity: PhoneIdentity
        var paired: Bool?
        var pairedAt: Date?
        var counters: ChannelCounter?
        var nickname: String?

        var hostID: HostID { pairing.hostID ?? pairing.macPubkey }
    }

    private static let account = "pairings"
    private static let legacyAccount = "pairing"
    // ponytail: one lock for the small host collection; partition only if Keychain contention matters.
    private static let lock = NSRecursiveLock()

    fileprivate static func synchronized<T>(_ work: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try work()
    }

    fileprivate static func records() throws -> [HostID: Stored] {
        guard let data = try Keychain.loadRequired(account) else { return [:] }
        return try JSONDecoder().decode([HostID: Stored].self, from: data)
    }

    fileprivate static func write(_ records: [HostID: Stored]) throws {
        try Keychain.save(JSONEncoder().encode(records), account: account)
    }

    /// Copies the exact identity, counters and encrypted cache before removing the old record.
    /// Every step is retryable after interruption; a failed write leaves the original keys intact.
    @discardableResult
    static func migrateLegacy() throws -> HostID? {
        try synchronized {
            guard let data = try Keychain.loadRequired(legacyAccount) else { return nil }
            var stored = try JSONDecoder().decode(Stored.self, from: data)
            guard stored.pairing.hostID != nil else {
                throw YorozuCrypto.CryptoError.malformed("stored Mac public key is invalid")
            }
            if stored.counters == nil { stored.counters = try legacyCounters(for: stored)?.load() }
            var all = try records()
            if let current = all[stored.hostID],
               current.identity.sessionPublicKey != stored.identity.sessionPublicKey {
                throw YorozuCrypto.CryptoError.malformed("legacy pairing conflicts with existing host")
            }
            try CacheStore.migrateLegacy(to: stored.hostID)
            if var current = all[stored.hostID] {
                current.counters = current.counters ?? stored.counters
                all[stored.hostID] = current
            } else {
                all[stored.hostID] = stored
            }
            try write(all)
            try Keychain.clearRequired(legacyAccount)
            legacyCounters(for: stored)?.clear()
            return stored.hostID
        }
    }

    static var legacyHostID: HostID? {
        synchronized {
            guard let data = Keychain.load(legacyAccount),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
            return stored.pairing.hostID
        }
    }

    static func loadAll() -> [Stored] { (try? loadAllRequired()) ?? [] }

    /// Startup must distinguish an empty collection from inaccessible or damaged pairing data.
    static func loadAllRequired() throws -> [Stored] {
        try synchronized {
            try migrateLegacy()
            return try records().values.sorted { $0.hostID < $1.hostID }
        }
    }

    static func load(hostID: HostID) -> Stored? {
        synchronized {
            _ = try? migrateLegacy()
            return try? records()[hostID]
        }
    }

    static func save(_ stored: Stored) throws {
        guard stored.pairing.hostID != nil else {
            throw YorozuCrypto.CryptoError.malformed("stored Mac public key is invalid")
        }
        try synchronized {
            try migrateLegacy()
            var all = try records()
            var updated = stored
            if let current = all[stored.hostID],
               current.identity.sessionPublicKey == stored.identity.sessionPublicKey {
                // Ordinary metadata saves cannot rewind a channel while retaining its keys.
                updated.counters = current.counters ?? stored.counters
                updated.paired = current.paired ?? stored.paired
                updated.pairedAt = current.pairedAt ?? stored.pairedAt
                if updated.paired == true { updated.pairing.token = "" }
            }
            all[stored.hostID] = updated
            try write(all)
        }
    }

    static func remove(hostID: HostID) throws {
        try synchronized {
            try migrateLegacy()
            var all = try records()
            let removed = all.removeValue(forKey: hostID)
            try write(all)
            if let removed { legacyCounters(for: removed)?.clear() }
        }
    }

    static func markPaired(hostID: HostID, expectedIdentity: Data) {
        try? update(hostID: hostID) { stored in
            guard stored.identity.sessionPublicKey == expectedIdentity else {
                throw PairingCounterStorage.NoPairing()
            }
            if stored.paired != true {
                stored.paired = true
                stored.pairedAt = Date()
                stored.pairing.token = ""
            }
        }
    }

    static func updateNickname(_ nickname: String?, hostID: HostID) throws {
        let trimmed = nickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed?.count ?? 0) <= 128 else {
            throw YorozuCrypto.CryptoError.malformed("host nickname is too long")
        }
        try update(hostID: hostID) { $0.nickname = trimmed?.isEmpty == false ? trimmed : nil }
    }

    fileprivate static func update(hostID: HostID, _ work: (inout Stored) throws -> Void) throws {
        try synchronized {
            try migrateLegacy()
            var all = try records()
            guard var stored = all[hostID] else { throw PairingCounterStorage.NoPairing() }
            try work(&stored)
            all[hostID] = stored
            try write(all)
        }
    }

    fileprivate static func legacyCounters(for stored: Stored) -> ChannelCounterStore? {
        guard let macPub = Data(base64URLEncoded: stored.pairing.macPubkey) else { return nil }
        return ChannelCounterStore(
            defaults: .standard, ownPub: stored.identity.sessionPublicKey, peerPub: macPub)
    }
}

/// Each host's counters live alongside its private keys. A removed/repaired connection cannot
/// update the replacement identity through a counter-store instance retained by its old relay.
struct PairingCounterStorage: ChannelCounterStorage {
    struct NoPairing: Error {}

    let hostID: HostID
    private let ownPublicKey: Data?

    init(hostID: HostID) {
        self.hostID = hostID
        ownPublicKey = PairingStore.load(hostID: hostID)?.identity.sessionPublicKey
    }

    func load() throws -> ChannelCounter? {
        try PairingStore.synchronized {
            try PairingStore.migrateLegacy()
            guard let stored = try PairingStore.records()[hostID] else { return nil }
            guard stored.identity.sessionPublicKey == ownPublicKey else { throw NoPairing() }
            return try stored.counters ?? PairingStore.legacyCounters(for: stored)?.load()
        }
    }

    func save(_ counter: ChannelCounter) throws {
        try PairingStore.update(hostID: hostID) { stored in
            guard stored.identity.sessionPublicKey == ownPublicKey else { throw NoPairing() }
            stored.counters = counter
        }
        // Only remove the old defaults after the Keychain write has succeeded.
        try clearLegacy()
    }

    func clear() throws {
        try PairingStore.synchronized {
            guard try PairingStore.records()[hostID] != nil else { return }
            // Counters can disappear only with their keys: remove(hostID:) does both atomically.
            throw YorozuCrypto.CryptoError.malformed("remove the pairing to clear channel counters")
        }
    }

    func clearLegacy() throws {
        try PairingStore.synchronized {
            guard let stored = try PairingStore.records()[hostID] else { return }
            guard stored.identity.sessionPublicKey == ownPublicKey else { throw NoPairing() }
            PairingStore.legacyCounters(for: stored)?.clear()
        }
    }
}
