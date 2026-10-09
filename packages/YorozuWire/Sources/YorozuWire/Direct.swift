import Foundation

/// One JSON text frame on the direct path (docs/ios-relay-contract.md, "Direct path"):
///
/// 1. Mac -> phone on connect: `nonce`.
/// 2. phone -> Mac: `join` — the room, the phone's Ed25519 key, its ``DirectProof/signJoin(priv:room:macNonce:)``
///    signature and a fresh phone nonce.
/// 3. Mac -> phone: `joined` — the Mac's Ed25519 key and ``DirectProof/signJoined(priv:room:phoneNonce:)``.
/// 4. Both ways after `joined`: `frame`, carrying exactly the signed `{payload, sig}` the relay carries.
/// 5. Phone heartbeat: `ping` every 10 s, answered by `pong` with the same `t`.
///
/// Binary strings are base64url without padding. Decoding is strict: an unknown `type` throws.
public enum DirectMessage: Codable, Equatable, Sendable {
    case nonce(String)
    case join(room: String, pub: String, sig: String, nonce: String)
    case joined(pub: String, sig: String)
    /// `payload`: base64url frame-body JSON (`{t:"hello"…}` or `{t:"box",n,c}`); `sig`: the sender's Ed25519
    /// signature over the `payload` string's UTF-8, as on the relay.
    case frame(payload: String, sig: String)
    /// `t`: epoch ms when sent.
    case ping(t: Int)
    case pong(t: Int)

    /// The largest message either end takes, as on the relay.
    public static let maxBytes = 1_048_576
    /// The Mac's default listener port.
    public static let defaultPort = 8738

    private struct Frame: Codable, Equatable { var payload: String; var sig: String }
    private enum CodingKeys: String, CodingKey { case type, nonce, room, pub, sig, frame, t }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "nonce": self = .nonce(try c.decode(String.self, forKey: .nonce))
        case "join":
            self = .join(room: try c.decode(String.self, forKey: .room), pub: try c.decode(String.self, forKey: .pub),
                         sig: try c.decode(String.self, forKey: .sig), nonce: try c.decode(String.self, forKey: .nonce))
        case "joined": self = .joined(pub: try c.decode(String.self, forKey: .pub), sig: try c.decode(String.self, forKey: .sig))
        case "frame":
            let frame = try c.decode(Frame.self, forKey: .frame)
            self = .frame(payload: frame.payload, sig: frame.sig)
        case "ping": self = .ping(t: try c.decode(Int.self, forKey: .t))
        case "pong": self = .pong(t: try c.decode(Int.self, forKey: .t))
        case let other:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown direct message \(other)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .nonce(let nonce):
            try c.encode("nonce", forKey: .type); try c.encode(nonce, forKey: .nonce)
        case .join(let room, let pub, let sig, let nonce):
            try c.encode("join", forKey: .type); try c.encode(room, forKey: .room); try c.encode(pub, forKey: .pub)
            try c.encode(sig, forKey: .sig); try c.encode(nonce, forKey: .nonce)
        case .joined(let pub, let sig):
            try c.encode("joined", forKey: .type); try c.encode(pub, forKey: .pub); try c.encode(sig, forKey: .sig)
        case .frame(let payload, let sig):
            try c.encode("frame", forKey: .type); try c.encode(Frame(payload: payload, sig: sig), forKey: .frame)
        case .ping(let t):
            try c.encode("ping", forKey: .type); try c.encode(t, forKey: .t)
        case .pong(let t):
            try c.encode("pong", forKey: .type); try c.encode(t, forKey: .t)
        }
    }

    /// The JSON text to send.
    public func text() throws -> String { String(decoding: try JSONEncoder().encode(self), as: UTF8.self) }

    /// Nil for anything that is not a well-formed direct message or is over ``maxBytes``.
    public static func decode(_ text: String) -> DirectMessage? {
        guard text.utf8.count <= maxBytes else { return nil }
        return try? JSONDecoder().decode(DirectMessage.self, from: Data(text.utf8))
    }
}

/// WebSocket close codes on the direct path.
public enum DirectCloseCode: Int, Sendable {
    /// The Mac is going to sleep.
    case sleeping = 4000
    /// The join did not verify, or came from an unknown key.
    case unauthorized = 4001
    /// A newer session for this device took the route.
    case superseded = 4002
    /// A message over ``DirectMessage/maxBytes``.
    case tooLarge = 4003
}
