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
        // After first unlock, not while unlocked: the phone rejoins the relay and decrypts its
        // thread cache from the background, with the screen locked, and a `WhenUnlocked` item is
        // unreadable there. `ThisDeviceOnly` keeps the rest of the promise — the item is not in
        // any backup and cannot be restored onto another phone.
        //
        // What survives an app update is the item itself: the Keychain is not part of the app
        // container, so replacing the bundle (TestFlight, or `simctl install` over the same
        // bundle id) leaves it where it is. It stays that way as long as nothing here changes
        // the service name or starts asking for an access group — an item written without one
        // lives in the app's own group, and adding one later would look like a different item.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
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
        /// When the relay first accepted this device, which is what Settings calls "paired
        /// since". Optional for the same reason `paired` is: a pairing stored before this
        /// existed has no date, and there is none to invent for it.
        var pairedAt: Date?
        /// Where both directions of the live channel stand: the last `seq` sent and the last
        /// accepted. Kept here, next to the identity, rather than in `UserDefaults`: the
        /// Keychain is what a reinstall keeps, and a phone that kept its keys but lost its
        /// counters would number from 1 again and have the Mac drop every box as a replay.
        /// Optional for the same reason the others are: a record from before this existed has
        /// none, which is a channel that starts from nothing.
        var counters: ChannelCounter?
    }

    private static let account = "pairing"

    static func load() -> Stored? {
        Keychain.load(account).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
    }

    static func save(_ stored: Stored) throws {
        try Keychain.save(JSONEncoder().encode(stored), account: account)
    }

    /// Drops the record — keys, pairing and counters together, since they live in one item —
    /// and the counters an older build left in `UserDefaults`, which would otherwise outlive
    /// the keys they belong to.
    static func clear() {
        try? PairingCounterStorage().clearLegacy()
        Keychain.clear(account)
    }

    /// Records that the relay knows this device, and drops the spent token with it. Best effort:
    /// failing to persist it costs a re-pair, not the running connection.
    static func markPaired() {
        guard var stored = load(), stored.paired != true else { return }
        stored.paired = true
        stored.pairedAt = Date()
        stored.pairing.token = ""
        try? save(stored)
    }
}

/// The live channel's counters, kept in the pairing record in the Keychain: what
/// ``RelayClient`` is handed so a reinstall that keeps the identity keeps its place in the
/// sequence too. Each save is a read-modify-write of the record; ``RelayClient`` is an actor,
/// so its saves are serialised, and `markPaired` runs inside the same actor.
///
/// A record written by a build that kept the counters in `UserDefaults` has none here; that
/// build's counters are read once, from where it left them, so the upgrade does not restart
/// the sequence.
struct PairingCounterStorage: ChannelCounterStorage {
    struct NoPairing: Error {}

    func load() throws -> ChannelCounter? {
        guard let stored = PairingStore.load() else { return nil }
        if let counters = stored.counters { return counters }
        return try legacyStore(for: stored)?.load()
    }

    func save(_ counter: ChannelCounter) throws {
        guard var stored = PairingStore.load() else { throw NoPairing() }
        stored.counters = counter
        try PairingStore.save(stored)
        legacyStore(for: stored)?.clear()
    }

    func clear() throws {
        try clearLegacy()
        guard var stored = PairingStore.load() else { return }
        stored.counters = nil
        try PairingStore.save(stored)
    }

    /// Forgets what an older build left in `UserDefaults`, if anything.
    func clearLegacy() throws {
        guard let stored = PairingStore.load() else { return }
        legacyStore(for: stored)?.clear()
    }

    private func legacyStore(for stored: PairingStore.Stored) -> ChannelCounterStore? {
        guard let macPub = Data(base64URLEncoded: stored.pairing.macPubkey) else { return nil }
        return ChannelCounterStore(
            defaults: .standard,
            ownPub: stored.identity.sessionPublicKey,
            peerPub: macPub
        )
    }
}
