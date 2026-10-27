import CryptoKit
import Foundation

public enum YorozuCrypto {
    static let hkdfSalt = Data("yorozu-v1".utf8)
    static let tagBytes = 16

    public struct Keypair: Sendable {
        public let privateKey: Data
        public let publicKey: Data
    }

    public struct SealedBox: Sendable {
        public let nonce: Data
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

    public static func generateKeypair() -> Keypair {
        let key = Curve25519.KeyAgreement.PrivateKey()
        return Keypair(privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    }

    public static func generateSigningKeypair() -> Keypair {
        let key = Curve25519.Signing.PrivateKey()
        return Keypair(privateKey: key.rawRepresentation, publicKey: key.publicKey.rawRepresentation)
    }

    public static func seal(key: SymmetricKey, plaintext: Data) throws -> SealedBox {
        let box = try ChaChaPoly.seal(plaintext, using: key)
        return SealedBox(nonce: Data(box.nonce), ciphertext: box.ciphertext + box.tag)
    }

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

    public static func threadRef(_ threadId: String) -> String {
        String(Data(SHA256.hash(data: Data(threadId.utf8))).base64URLEncodedString().prefix(8))
    }

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
