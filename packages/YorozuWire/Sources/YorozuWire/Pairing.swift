import Foundation

/// Long-lived device identity for a paired phone: the Ed25519 key the relay checks on every
/// frame, and the X25519 key the session key is agreed from. Stored as JSON by the caller
/// (the iOS app keeps it in the Keychain); `Data` codes as base64.
public struct PhoneIdentity: Codable, Equatable, Sendable {
    public var signingPrivateKey: Data
    public var signingPublicKey: Data
    public var sessionPrivateKey: Data
    public var sessionPublicKey: Data

    public init(
        signingPrivateKey: Data,
        signingPublicKey: Data,
        sessionPrivateKey: Data,
        sessionPublicKey: Data
    ) {
        self.signingPrivateKey = signingPrivateKey
        self.signingPublicKey = signingPublicKey
        self.sessionPrivateKey = sessionPrivateKey
        self.sessionPublicKey = sessionPublicKey
    }

    public static func generate() -> PhoneIdentity {
        let signing = YorozuCrypto.generateSigningKeypair()
        let session = YorozuCrypto.generateKeypair()
        return PhoneIdentity(
            signingPrivateKey: signing.privateKey,
            signingPublicKey: signing.publicKey,
            sessionPrivateKey: session.privateKey,
            sessionPublicKey: session.publicKey
        )
    }
}

/// Payload carried by a pairing QR code.
public struct QrPayload: Codable, Equatable, Sendable {
    public var v: Int
    public var relayUrl: String
    /// Host X25519 public key, base64url, 32 raw bytes. Used for the session key agreement.
    public var macPubkey: String
    /// One-time relay join token.
    public var token: String
    /// Relay room to join: base64url sha256 of the host's Ed25519 relay key, which is a
    /// different key from `macPubkey` and so cannot be derived from it.
    public var roomId: String?
    /// A host-minted secret the relay never sees: the QR goes from the host's terminal to this
    /// phone's camera. The first `hello` proves the phone holds it (``YorozuCrypto/helloProof``),
    /// which is what stops a relay from enrolling a device of its own.
    public var secret: String?

    public init(
        v: Int = 1, relayUrl: String, macPubkey: String, token: String, roomId: String? = nil,
        secret: String? = nil
    ) {
        self.v = v
        self.relayUrl = relayUrl
        self.macPubkey = macPubkey
        self.token = token
        self.roomId = roomId
        self.secret = secret
    }

    public func encoded() throws -> String {
        // v3 (docs/ios-relay-contract.md, "Pairing") keeps the v1 fields; only `v` tells a v3 code from a v1 one.
        guard v == 1 || v == 3 else { throw YorozuCrypto.CryptoError.malformed(String(localized: "not a Yorozu v1 pairing string")) }
        var components = URLComponents()
        components.scheme = "yorozu"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "v", value: String(v)),
            URLQueryItem(name: "relay", value: relayUrl),
            URLQueryItem(name: "key", value: macPubkey),
            URLQueryItem(name: "token", value: token),
        ] + (roomId.map { [URLQueryItem(name: "room", value: $0)] } ?? [])
            + (secret.map { [URLQueryItem(name: "secret", value: $0)] } ?? [])
        guard let string = components.string else {
            throw YorozuCrypto.CryptoError.malformed(String(localized: "not a Yorozu v1 pairing string"))
        }
        return string
    }

    /// The page a pairing QR opens, and the universal link the phone app claims: the same query
    /// as the `yorozu://` form, in the fragment, so a browser never sends it anywhere.
    public static let link = "https://yorozu.yumi.to/pair"

    /// The host key's first 8 bytes as uppercase hex in groups of two bytes ("3F9A 1C07 B2E4 55D0"): what both
    /// `openclaw yorozu pair` and the client's confirmation show, to compare.
    public var fingerprint: String {
        let hex = (Data(base64URLEncoded: macPubkey) ?? Data()).prefix(8).map { String(format: "%02X", $0) }
        return stride(from: 0, to: hex.count, by: 2).map { hex[$0..<min($0 + 2, hex.count)].joined() }.joined(separator: " ")
    }

    /// The one parser for every way a pairing arrives: the QR, a pasted string, a tapped
    /// `yorozu://` link or the web link the QR carries. Throws on anything that is not a v1
    /// pairing string.
    public static func decode(_ text: String) throws -> QrPayload {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let web = URLComponents(string: text), web.scheme?.lowercased() == "https",
           web.host?.lowercased() == URLComponents(string: link)?.host,
           web.path == "/pair" || web.path == "/pair/", web.percentEncodedQuery == nil,
           let fragment = web.percentEncodedFragment {
            return try decodePairingString("yorozu://pair?\(fragment)")
        }
        return try decodePairingString(text)
    }

    /// Whether a pairing code's `relay` is somewhere this device should dial at all: a `wss`
    /// URL, or a plain `ws` one only when it points back at this machine. The relay carries
    /// sealed frames, but a cleartext socket to a stranger's host still hands them the room,
    /// the device list and every reconnect — and a code is untrusted text out of a QR, a
    /// paste or a tapped link. Hosts are compared case-insensitively; `::1` arrives with or
    /// without its brackets depending on who parsed it.
    public static func isAcceptableRelayUrl(_ relay: String) -> Bool {
        guard let components = URLComponents(string: relay),
              let host = components.host?.lowercased(), !host.isEmpty
        else { return false }
        switch components.scheme?.lowercased() {
        case "wss": return true
        case "ws":
            let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            return ["localhost", "127.0.0.1", "::1"].contains(bare)
        default: return false
        }
    }

    /// `yorozu://pair?v=1&relay=<urlencoded>&key=<base64url>&token=<base64url>`, the compact
    /// form the host prints and encodes in the QR.
    private static func decodePairingString(_ text: String) throws -> QrPayload {
        func malformed() -> Error {
            YorozuCrypto.CryptoError.malformed(String(localized: "not a Yorozu v1 pairing string"))
        }
        /// Base64url, unpadded, is the only thing the keys and the token are ever spelled in.
        /// The same check `decodePairingString` makes in TypeScript, so neither side accepts a
        /// code the other would refuse.
        func base64Url(_ value: String?) throws -> String {
            let alphabet = CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
            )
            guard let value, !value.isEmpty, value.unicodeScalars.allSatisfy(alphabet.contains) else {
                throw malformed()
            }
            return value
        }
        guard let components = URLComponents(string: text), components.scheme == "yorozu", components.host == "pair" else {
            throw malformed()
        }
        let items = components.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard let v = ["1": 1, "3": 3][query["v"] ?? ""], let relayUrl = query["relay"], isAcceptableRelayUrl(relayUrl) else {
            throw malformed()
        }
        return QrPayload(
            v: v,
            relayUrl: relayUrl,
            macPubkey: try base64Url(query["key"]),
            token: try base64Url(query["token"]),
            roomId: query["room"].flatMap { $0.isEmpty ? nil : $0 },
            secret: try query["secret"].flatMap { $0.isEmpty ? nil : $0 }.map(base64Url)
        )
    }
}
