import CryptoKit
import Foundation

/// X25519 and Ed25519 keys, ChaCha20-Poly1305 boxes and Ed25519 relay frame signatures; the v3 handshake is WireV3.
/// Mirrored by packages/shared/src/crypto.ts (node:crypto); fixtures/ proves they interoperate.
public enum YorozuCrypto {
    /// Part of the wire contract (sealed previews): both languages must feed HKDF these exact bytes.
    static let hkdfSalt = Data("yorozu-v1".utf8)
    static let tagBytes = 16

    public struct Keypair: Sendable {
        /// Raw 32-byte scalar.
        public let privateKey: Data
        /// Raw 32-byte point.
        public let publicKey: Data
    }

    public struct SealedBox: Sendable {
        /// 12 bytes.
        public let nonce: Data
        /// Ciphertext followed by the 16-byte Poly1305 tag.
        public let ciphertext: Data
    }

    public enum CryptoError: LocalizedError {
        case malformed(String)

        public var errorDescription: String? {
            switch self {
            case .malformed(let reason): reason
            }
        }
    }

    /// X25519 keypair for the session key agreement.
    public static func generateKeypair() -> Keypair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return Keypair(privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    }

    /// Ed25519 keypair for signing relay frames.
    public static func generateSigningKeypair() -> Keypair {
        let key = Curve25519.Signing.PrivateKey()
        return Keypair(privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    }

    public static func seal(key: SymmetricKey, plaintext: Data) throws -> SealedBox {
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return SealedBox(nonce: Data(box.nonce), ciphertext: box.ciphertext + box.tag)
    }

    /// Throws if the tag does not verify.
    public static func open(key: SymmetricKey, nonce: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= tagBytes else { throw CryptoError.malformed(String(localized: "ciphertext too short")) }
        let split = ciphertext.index(ciphertext.endIndex, offsetBy: -tagBytes)
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: nonce),
            ciphertext: ciphertext[..<split],
            tag: ciphertext[split...]
        )
        return try ChaChaPoly.open(box, using: key)
    }

    /// The opaque id a push payload names a thread by. Mirrors `threadRef` in
    /// packages/shared/src/crypto.ts, which is what the Mac stamps on a `notify`.
    ///
    /// The relay and APNs see this and never the thread id, so resolving it back to a thread —
    /// to route a tapped notification — is something only a paired phone can do, by hashing the
    /// ids it already holds.
    public static func threadRef(_ threadId: String) -> String {
        String(Data(SHA256.hash(data: Data(threadId.utf8))).base64URLEncodedString().prefix(8))
    }

    /// What the first `hello` carries to prove this phone read the QR: a hash over the QR's
    /// secret and both announced keys. The relay sees the proof and the keys, never the secret,
    /// and a proof for one pair of keys says nothing about any other. Mirrors `helloProof` in
    /// packages/shared/src/crypto.ts.
    public static func helloProof(secret: String, pub: String, spub: String) -> String {
        Data(SHA256.hash(data: Data("\(secret).\(pub).\(spub)".utf8))).base64URLEncodedString()
    }

    public static func signFrame(priv: Data, data: Data) throws -> Data {
        try Curve25519.Signing.PrivateKey(rawRepresentation: priv).signature(for: data)
    }

    public static func verifyFrame(pub: Data, data: Data, signature: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: pub) else { return false }
        return key.isValidSignature(signature, for: data)
    }
}

extension Data {
    public init?(base64URLEncoded text: String) {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        s += String(repeating: "=", count: (4 - s.count % 4) % 4)
        self.init(base64Encoded: s)
    }

    public func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
