import Foundation

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

public struct QrPayload: Codable, Equatable, Sendable {
    public var v: Int
    public var relayUrl: String
    public var macPubkey: String
    public var token: String
    public var roomId: String?
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

    public static let link = "https://yorozu.yumi.to/pair"

    public var fingerprint: String {
        let hex = (Data(base64URLEncoded: macPubkey) ?? Data()).prefix(8).map { String(format: "%02X", $0) }
        return stride(from: 0, to: hex.count, by: 2).map { hex[$0..<min($0 + 2, hex.count)].joined() }.joined(separator: " ")
    }

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

    private static func decodePairingString(_ text: String) throws -> QrPayload {
        func malformed() -> Error {
            YorozuCrypto.CryptoError.malformed(String(localized: "not a Yorozu v1 pairing string"))
        }
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
        // A link without `v` is the current wire's: the plugin stops sending `v=3` once every client reads it so.
        guard let v = query["v"].map({ ["1": 1, "3": 3][$0] }) ?? 3, let relayUrl = query["relay"], isAcceptableRelayUrl(relayUrl) else {
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
