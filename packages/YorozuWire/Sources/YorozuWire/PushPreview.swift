import CryptoKit
import Foundation

/// A push's words, sealed by the Mac for one phone (docs/ios-relay-contract.md, "Sealed previews"). The relay carries the box
/// in the `notify`'s `previews` map under the phone's Ed25519 key and puts it in that phone's APNs payload as `preview {n, c}`
/// with `mutable-content: 1`; the phone's notification service extension opens it. The relay and APNs see only the box.
///
/// The key is its own HKDF output from the pairing's X25519 agreement, never a channel key, so a preview box can never be
/// taken for a channel frame or the other way round. Each box has a fresh random 96-bit nonce (`ChaChaPoly.seal`).
public struct PushPreview: Codable, Equatable, Sendable {
    /// Peer-info capability: the phone can open previews. The Mac seals only for phones that negotiated it.
    public static let capability = "push-preview-v1"
    /// The relay refuses a box over 256 bytes of plaintext (and drops the Mac's socket with "bad notify").
    public static let maxPlaintextBytes = 256
    static let keyInfo = Data("yorozu-push-preview/mac->device".utf8)

    /// The relay class (`reply`, `failed`, `approval`); the phone titles the alert from its own strings for it.
    public var cls: String
    /// `YorozuCrypto.threadRef` of the message: the phone shows the box only on the push whose `event` it names.
    public var event: String
    /// The excerpt, already plain text.
    public var body: String

    enum CodingKeys: String, CodingKey { case cls = "c", event = "e", body = "b" }

    public init(cls: String, event: String, body: String) { self.cls = cls; self.event = event; self.body = body }

    /// Both ends derive the same key from opposite halves of the pairing.
    public static func key(myPriv: Data, theirPub: Data) throws -> SymmetricKey {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myPriv)
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPub)
        return try priv.sharedSecretFromKeyAgreement(with: pub)
            .hkdfDerivedSymmetricKey(using: SHA256.self, salt: YorozuCrypto.hkdfSalt, sharedInfo: keyInfo, outputByteCount: 32)
    }

    /// The JSON plaintext, the body cut (with "…") until the whole fits `maxPlaintextBytes`; nil when not even one character fits.
    public func plaintext() -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var copy = self
        while true {
            guard let data = try? encoder.encode(copy) else { return nil }
            if data.count <= Self.maxPlaintextBytes { return copy.body.isEmpty ? nil : data }
            var chars = Array(copy.body.hasSuffix("…") ? String(copy.body.dropLast()) : copy.body)
            guard chars.count > 1 else { return nil }
            // A character can be far more than 4 bytes (flags, ZWJ emoji, escaped controls): never remove them all.
            chars.removeLast(min(chars.count - 1, max(1, (data.count - Self.maxPlaintextBytes) / 4)))
            copy.body = String(chars).trimmingCharacters(in: .whitespaces) + "…"
        }
    }

    /// `n` and `c` as the relay takes them: base64url nonce (12 bytes) and ciphertext plus tag.
    public func seal(key: SymmetricKey) -> (n: String, c: String)? {
        guard let plaintext = plaintext(), let box = try? YorozuCrypto.seal(key: key, plaintext: plaintext) else { return nil }
        return (box.nonce.base64URLEncodedString(), box.ciphertext.base64URLEncodedString())
    }

    /// The preview in an APNs payload's `preview {n, c}`, or nil when it is missing, malformed or does not open under `key`.
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
