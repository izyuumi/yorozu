import CryptoKit
import Foundation

/// The code an unpaired Mac shows for a paired iPhone or iPad to scan (owner, 2026-10-27; docs/ios-relay-contract.md,
/// "Pairing from another device"). It names a one-time mailbox on the relay and the Mac's X25519 key: the scanning
/// device asks its host for a `pair_invite`, seals the link to that key and drops it in the mailbox, where the Mac
/// opens it and pairs as with any link, after the fingerprint check.
public struct DeviceCode: Equatable, Sendable {
    public var relayUrl: String
    /// The mailbox id: 16 random bytes, base64url.
    public var box: String
    /// The Mac's X25519 public key for this code, base64url, 32 bytes.
    public var key: String
    /// The Mac's name, shown in "Add … ?".
    public var name: String

    public init(relayUrl: String, box: String, key: String, name: String) {
        self.relayUrl = relayUrl
        self.box = box
        self.key = key
        self.name = name
    }

    /// The relay a fresh Mac waits on before it knows its host's: the plugin's default too.
    public static let defaultRelay = "wss://relay.yumi.to"
    /// The page the code opens, and the universal link the phone app claims; the code is in the fragment.
    public static let page = "https://yorozu.yumi.to/add"

    /// A fresh code and the private key that opens what is dropped for it.
    public static func make(name: String, relayUrl: String = defaultRelay) -> (code: DeviceCode, privateKey: Data) {
        let pair = YorozuCrypto.generateKeypair()
        var box = Data(count: 16)
        _ = box.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let code = DeviceCode(relayUrl: relayUrl, box: box.base64URLEncodedString(),
            key: pair.publicKey.base64URLEncodedString(), name: name)
        return (code, pair.privateKey)
    }

    public var link: String {
        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "v", value: "1"),
            URLQueryItem(name: "relay", value: relayUrl),
            URLQueryItem(name: "box", value: box),
            URLQueryItem(name: "key", value: key),
            URLQueryItem(name: "name", value: name),
        ]
        return "\(Self.page)#\(components.percentEncodedQuery ?? "")"
    }

    /// The mailbox: the Mac waits on it as a WebSocket (`wss`), the scanning device posts to it (`https`).
    public func mailbox(websocket: Bool) -> URL? {
        guard var components = URLComponents(string: relayUrl) else { return nil }
        if !websocket { components.scheme = components.scheme == "ws" ? "http" : "https" }
        components.path = "/mailbox/\(box)"
        components.query = nil
        return components.url
    }

    /// Takes the code's web link; nil for anything else, including a pairing code from a host.
    public static func decode(_ text: String) -> DeviceCode? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let web = URLComponents(string: text), web.scheme?.lowercased() == "https",
              web.host?.lowercased() == URLComponents(string: page)?.host,
              web.path == "/add" || web.path == "/add/", web.percentEncodedQuery == nil,
              let fragment = web.percentEncodedFragment,
              let items = URLComponents(string: "x:?\(fragment)")?.queryItems
        else { return nil }
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard query["v"] == "1", let relay = query["relay"], QrPayload.isAcceptableRelayUrl(relay),
              let box = query["box"], Data(base64URLEncoded: box)?.count == 16,
              let key = query["key"], Data(base64URLEncoded: key)?.count == 32
        else { return nil }
        let name = String((query["name"] ?? "").prefix(64)).trimmingCharacters(in: .whitespacesAndNewlines)
        return DeviceCode(relayUrl: relay, box: box, key: key, name: name.isEmpty ? "Mac" : name)
    }

    /// The scanning device's half: `link` sealed to the code's key, as the mailbox carries it. base64url of the sender's
    /// ephemeral X25519 key (32) ‖ nonce (12) ‖ ChaCha20-Poly1305 ciphertext and tag; the key comes from HKDF-SHA256
    /// over the shared secret, salted with both public keys.
    public func seal(_ link: String) throws -> String {
        guard let keyData = Data(base64URLEncoded: key) else { throw YorozuCrypto.CryptoError.malformed("key") }
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: keyData))
        let sender = ephemeral.publicKey.rawRepresentation
        let sealed = try YorozuCrypto.seal(key: Self.letterKey(shared, sender: sender, recipient: keyData),
            plaintext: Data(link.utf8))
        return (sender + sealed.nonce + sealed.ciphertext).base64URLEncodedString()
    }

    /// The Mac's half: the link sealed in `letter`. Throws if it was not sealed to this key.
    public static func open(_ letter: String, privateKey: Data) throws -> String {
        guard let bytes = Data(base64URLEncoded: letter), bytes.count > 32 + 12 else {
            throw YorozuCrypto.CryptoError.malformed("letter")
        }
        let me = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey)
        let sender = bytes.prefix(32)
        let shared = try me.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: sender))
        let plain = try YorozuCrypto.open(key: letterKey(shared, sender: sender, recipient: me.publicKey.rawRepresentation),
            nonce: bytes.dropFirst(32).prefix(12), ciphertext: bytes.dropFirst(44))
        guard let link = String(data: plain, encoding: .utf8) else { throw YorozuCrypto.CryptoError.malformed("letter") }
        return link
    }

    private static func letterKey(_ shared: SharedSecret, sender: Data, recipient: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: sender + recipient,
            sharedInfo: Data("yorozu-device-code".utf8), outputByteCount: 32)
    }
}
