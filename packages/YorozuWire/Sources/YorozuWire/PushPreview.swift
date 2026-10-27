import CryptoKit
import Foundation

public struct PushPreview: Codable, Equatable, Sendable {
    public static let capability = "push-preview-v1"
    public static let maxPlaintextBytes = 256
    static let keyInfo = Data("yorozu-push-preview/mac->device".utf8)

    public var cls: String
    public var event: String
    public var body: String
    public var title: String?
    public var convId: String?

    enum CodingKeys: String, CodingKey { case cls = "c", event = "e", body = "b", title = "t", convId = "v" }

    public init(cls: String, event: String, body: String, title: String? = nil, convId: String? = nil) {
        self.cls = cls; self.event = event; self.body = body; self.title = title; self.convId = convId
    }

    public static func key(myPriv: Data, theirPub: Data) throws -> SymmetricKey {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myPriv)
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPub)
        return try priv.sharedSecretFromKeyAgreement(with: pub)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: YorozuCrypto.hkdfSalt, sharedInfo: keyInfo, outputByteCount: 32)
    }

    public func plaintext() -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var copy = self
        while true {
            guard let data = try? encoder.encode(copy) else { return nil }
            if data.count <= Self.maxPlaintextBytes { return copy.body.isEmpty ? nil : data }
            var chars = Array(copy.body.hasSuffix("…") ? String(copy.body.dropLast()) : copy.body)
            guard chars.count > 1 else { return nil }
            chars.removeLast(min(chars.count - 1, max(1, (data.count - Self.maxPlaintextBytes) / 4)))
            copy.body = String(chars).trimmingCharacters(in: .whitespaces) + "…"
        }
    }

    public func seal(key: SymmetricKey) -> (n: String, c: String)? {
        guard let plaintext = plaintext(), let box = try? YorozuCrypto.seal(key: key, plaintext: plaintext) else { return nil }
        return (box.nonce.base64URLEncodedString(), box.ciphertext.base64URLEncodedString())
    }

    public static func open(userInfo: [AnyHashable: Any], key: SymmetricKey) -> PushPreview? {
        guard let box = userInfo["preview"] as? [String: Any], let n = box["n"] as? String, let c = box["c"] as? String,
              let nonce = Data(base64URLEncoded: n), nonce.count == 12,
              let ciphertext = Data(base64URLEncoded: c), ciphertext.count <= maxPlaintextBytes + YorozuCrypto.tagBytes,
              let plaintext = try? YorozuCrypto.open(key: key, nonce: nonce, ciphertext: ciphertext),
              let preview = try? JSONDecoder().decode(PushPreview.self, from: plaintext), !preview.body.isEmpty
        else { return nil }
        return preview
    }
}
