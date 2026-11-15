import Foundation
import YorozuWire

struct Pairing: Codable, Equatable {
    var pairing: QrPayload
    var identity: PhoneIdentity
    var relayKnows = false
    var paired = false
    var pairedAt: Date?
    var unversionedWire: Bool?

    private static let account = "pairing"
    private static let oldAccount = "pairing-v3"
    static let unpairedAccount = "pairing-unpaired"

    static func load(storage: any PairingStorage = KeychainPairingStorage(),
                     state: PairingMigration.State = .shared) throws -> Pairing? {
        if let data = try storage.load(account) {
            do { return try JSONDecoder().decode(Pairing.self, from: data) }
            catch {
                guard state.legacyFallback, try storage.load(unpairedAccount) == nil,
                      let old = try storage.load(oldAccount) else { throw error }
                return try JSONDecoder().decode(Pairing.self, from: old)
            }
        }
        guard state.legacyFallback, try storage.load(unpairedAccount) == nil,
              let data = try storage.load(oldAccount) else { return nil }
        return try JSONDecoder().decode(Pairing.self, from: data)
    }

    func save(storage: any PairingStorage = KeychainPairingStorage()) throws {
        try storage.save(JSONEncoder().encode(self), account: Self.account)
        try storage.clear(Self.unpairedAccount)
    }

    static func remove(storage: any PairingStorage = KeychainPairingStorage()) throws {
        var failure: (any Error)?
        for account in [account, oldAccount] {
            do { try storage.clear(account) }
            catch { if failure == nil { failure = error } }
        }
        // Persist unpair intent even when a pairing item could not be deleted.
        try storage.save(Data([1]), account: unpairedAccount)
        if let failure { throw failure }
    }
}
