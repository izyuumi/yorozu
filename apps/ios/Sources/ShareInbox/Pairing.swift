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

    static func load(storage: any PairingStorage = KeychainPairingStorage(),
                     state: PairingMigration.State = .shared) throws -> Pairing? {
        if let data = try storage.load(account) {
            do { return try JSONDecoder().decode(Pairing.self, from: data) }
            catch {
                guard state.legacyFallback, let old = try storage.load(oldAccount) else { throw error }
                return try JSONDecoder().decode(Pairing.self, from: old)
            }
        }
        guard state.legacyFallback, let data = try storage.load(oldAccount) else { return nil }
        return try JSONDecoder().decode(Pairing.self, from: data)
    }

    func save() throws { try Keychain.save(JSONEncoder().encode(self), account: Self.account) }

    static func remove() throws {
        try Keychain.clearRequired(account)
        try Keychain.clearRequired(oldAccount)
    }
}
