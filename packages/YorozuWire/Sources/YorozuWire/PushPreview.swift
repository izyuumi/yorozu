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
