import CryptoKit
import Foundation

/// X25519 -> HKDF-SHA256 -> ChaCha20-Poly1305, plus Ed25519 for relay frame signatures.
/// Mirrored by packages/shared/src/crypto.ts (node:crypto); fixtures/ proves they interoperate.
public enum YorozuCrypto {
    /// Part of the wire contract: both languages must feed HKDF these exact bytes.
    static let hkdfSalt = Data("yorozu-v1".utf8)
    static let hkdfInfo = Data("yorozu-session".utf8)
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

    public enum CryptoError: Error {
        case malformed(String)
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

    /// 32-byte symmetric key. Both peers derive the same one from opposite halves.
    public static func deriveSessionKey(myPriv: Data, theirPub: Data) throws -> SymmetricKey {
        let priv = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: myPriv)
        let pub = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: theirPub)
        return try priv.sharedSecretFromKeyAgreement(with: pub)
            .hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: hkdfSalt,
                sharedInfo: hkdfInfo,
                outputByteCount: 32
            )
    }

    public static func seal(key: SymmetricKey, plaintext: Data) throws -> SealedBox {
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return SealedBox(nonce: Data(box.nonce), ciphertext: box.ciphertext + box.tag)
    }

    /// Throws if the tag does not verify.
    public static func open(key: SymmetricKey, nonce: Data, ciphertext: Data) throws -> Data {
        guard ciphertext.count >= tagBytes else { throw CryptoError.malformed("ciphertext too short") }
        let split = ciphertext.index(ciphertext.endIndex, offsetBy: -tagBytes)
        let box = try ChaChaPoly.SealedBox(
            nonce: ChaChaPoly.Nonce(data: nonce),
            ciphertext: ciphertext[..<split],
            tag: ciphertext[split...]
        )
        return try ChaChaPoly.open(box, using: key)
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
