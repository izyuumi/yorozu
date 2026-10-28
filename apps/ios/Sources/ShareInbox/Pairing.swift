import Foundation
import YorozuWire

struct Pairing: Codable, Equatable {
    var pairing: QrPayload
    var identity: PhoneIdentity
    var relayKnows = false
    var paired = false
    var pairedAt: Date?

    private static let account = "pairing"
    private static let oldAccount = "pairing-v3"  // moved to `account` on first load; the fallback goes in 0.11

    static func load() throws -> Pairing? {
        if let data = try Keychain.loadRequired(account) { return try JSONDecoder().decode(Pairing.self, from: data) }
        guard let data = try Keychain.loadRequired(oldAccount) else { return nil }
        let pairing = try JSONDecoder().decode(Pairing.self, from: data)
        if (try? pairing.save()) != nil { try? Keychain.clearRequired(oldAccount) }
        return pairing
    }

    func save() throws { try Keychain.save(JSONEncoder().encode(self), account: Self.account) }

    static func remove() throws {
        try Keychain.clearRequired(account)
        try Keychain.clearRequired(oldAccount)
    }
}
