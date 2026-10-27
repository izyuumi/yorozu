import CryptoKit
import Foundation

public enum WireV3 {
    public static let version: UInt8 = 3
    public static let protocolName = "Noise_IK_25519_ChaChaPoly_SHA256"
    public static let sidBytes = 8
    public static let maxCounter: UInt64 = 9_007_199_254_740_991

    public enum Failure: Error, Equatable, Sendable {
        case malformed(String)
        case otherSession
        case replay
        case decrypt
    }

    public static func prologue(roomId: String, deviceSigningKey: Data) -> Data {
        Data("yorozu-v3|\(roomId)|\(deviceSigningKey.base64URLEncodedString())".utf8)
    }
}

enum Noise {
    static func hkdf(_ ck: Data, _ ikm: Data) -> (Data, Data) {
        let temp = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: ck))))
        let one = Data(HMAC<SHA256>.authenticationCode(for: Data([1]), using: temp))
        let two = Data(HMAC<SHA256>.authenticationCode(for: one + Data([2]), using: temp))
        return (one, two)
    }

    static func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        try ChaChaPoly.Nonce(data: Data(count: 4) + withUnsafeBytes(of: n.littleEndian) { Data($0) })
    }

    static func encrypt(_ key: SymmetricKey, _ n: UInt64, _ ad: Data, _ plaintext: Data) throws -> Data {
        let box = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce(n), authenticating: ad)
        return box.ciphertext + box.tag
    }

    static func decrypt(_ key: SymmetricKey, _ n: UInt64, _ ad: Data, _ ciphertext: Data) throws -> Data {
        let c = Data(ciphertext)
        guard c.count >= 16 else { throw WireV3.Failure.decrypt }
        do {
            let box = try ChaChaPoly.SealedBox(nonce: nonce(n), ciphertext: c.prefix(c.count - 16), tag: c.suffix(16))
            return try ChaChaPoly.open(box, using: key, authenticating: ad)
        } catch {
            throw WireV3.Failure.decrypt
        }
    }

    static func dh(_ priv: Curve25519.KeyAgreement.PrivateKey, _ pub: Data) throws -> Data {
        try priv.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: pub)).withUnsafeBytes { Data($0) }
    }
}

struct NoiseSymmetricState {
    var ck: Data
    var h: Data
    var k: SymmetricKey?
    var n: UInt64 = 0

    init(protocolName: String) {
        let name = Data(protocolName.utf8)
        h = name.count <= 32 ? name + Data(count: 32 - name.count) : Data(SHA256.hash(data: name))
        ck = h
    }

    mutating func mixHash(_ data: Data) { h = Data(SHA256.hash(data: h + data)) }

    mutating func mixKey(_ ikm: Data) {
        let (ck, k) = Noise.hkdf(ck, ikm)
        self.ck = ck
        self.k = SymmetricKey(data: k)
        n = 0
    }

    mutating func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let k else { mixHash(plaintext); return plaintext }
        let c = try Noise.encrypt(k, n, h, plaintext)
        n += 1
        mixHash(c)
        return c
    }

    mutating func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let k else { mixHash(ciphertext); return ciphertext }
        let p = try Noise.decrypt(k, n, h, ciphertext)
        n += 1
        mixHash(ciphertext)
        return p
    }
}

public struct NoiseIKHandshake {
    public enum Role: Sendable { case initiator, responder }

    public let role: Role
    private let s: Curve25519.KeyAgreement.PrivateKey
    private var e: Curve25519.KeyAgreement.PrivateKey?
    private let fixedEphemeral: Data?
    public private(set) var remoteStatic: Data?
    private var re: Data?
    private var state: NoiseSymmetricState
    private var step = 0

    public init(role: Role, staticKey: Data, remoteStatic: Data? = nil, prologue: Data, ephemeral: Data? = nil) throws {
        self.role = role
        s = try .init(rawRepresentation: staticKey)
        fixedEphemeral = ephemeral
        self.remoteStatic = remoteStatic
        state = NoiseSymmetricState(protocolName: WireV3.protocolName)
        state.mixHash(prologue)
        let responderStatic = role == .initiator ? remoteStatic : s.publicKey.rawRepresentation
        guard let responderStatic, responderStatic.count == 32 else { throw WireV3.Failure.malformed("responder static key") }
        state.mixHash(responderStatic)
    }

    public var handshakeHash: Data { state.h }

    public mutating func writeMessage(_ payload: Data) throws -> Data {
        guard step == (role == .initiator ? 0 : 1) else { throw WireV3.Failure.malformed("handshake out of order") }
        let e = try fixedEphemeral.map { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: $0) }
            ?? Curve25519.KeyAgreement.PrivateKey()
        self.e = e
        let epub = e.publicKey.rawRepresentation
        state.mixHash(epub)
        var out = epub
        if role == .initiator {
            guard let rs = remoteStatic else { throw WireV3.Failure.malformed("responder static key") }
            state.mixKey(try Noise.dh(e, rs))
            out += try state.encryptAndHash(s.publicKey.rawRepresentation)
            state.mixKey(try Noise.dh(s, rs))
        } else {
            guard let re, let rs = remoteStatic else { throw WireV3.Failure.malformed("handshake out of order") }
            state.mixKey(try Noise.dh(e, re))
            state.mixKey(try Noise.dh(e, rs))
        }
        out += try state.encryptAndHash(payload)
        step += 1
        return out
    }

    public mutating func readMessage(_ message: Data) throws -> Data {
        guard step == (role == .responder ? 0 : 1) else { throw WireV3.Failure.malformed("handshake out of order") }
        let m = Data(message)
        let minimum = role == .responder ? 32 + 48 + 16 : 32 + 16
        guard m.count >= minimum, m.count <= 65_535 else { throw WireV3.Failure.malformed("handshake message length") }
        let re = m.prefix(32)
        self.re = re
        state.mixHash(re)
        var rest = m.dropFirst(32)
        if role == .responder {
            state.mixKey(try Noise.dh(s, re))
            let rs = try state.decryptAndHash(Data(rest.prefix(48)))
            rest = rest.dropFirst(48)
            remoteStatic = rs
            state.mixKey(try Noise.dh(s, rs))
        } else {
            guard let e else { throw WireV3.Failure.malformed("handshake out of order") }
            state.mixKey(try Noise.dh(e, re))
            state.mixKey(try Noise.dh(s, re))
        }
        let payload = try state.decryptAndHash(Data(rest))
        step += 1
        return payload
    }

    public func split(sid: Data) throws -> V3Session {
        guard step == 2 else { throw WireV3.Failure.malformed("handshake not finished") }
        let (k1, k2) = Noise.hkdf(state.ck, Data())
        let (send, recv) = role == .initiator ? (k1, k2) : (k2, k1)
        return V3Session(sid: sid, handshakeHash: state.h, sendKey: send, recvKey: recv)
    }
}

public enum V3Frame: Equatable, Sendable {
    case handshakeInit(deviceSigningKey: Data, message: Data)
    case handshakeResponse(sid: Data, message: Data)
    case transport(sid: Data, counter: UInt64, ciphertext: Data)

    public var sid: Data {
        switch self {
        case .handshakeInit(_, let message): Data(message.prefix(WireV3.sidBytes))
        case .handshakeResponse(let sid, _), .transport(let sid, _, _): sid
        }
    }

    public var bytes: Data {
        switch self {
        case .handshakeInit(let key, let message): Data([WireV3.version, 1]) + key + message
        case .handshakeResponse(let sid, let message): Data([WireV3.version, 2]) + sid + message
        case .transport(let sid, let counter, let ciphertext):
            Data([WireV3.version, 3]) + sid + withUnsafeBytes(of: counter.littleEndian) { Data($0) } + ciphertext
        }
    }

    public var payload: String { bytes.base64URLEncodedString() }

    public init(bytes raw: Data) throws {
        let b = Data(raw)
        let sid = WireV3.sidBytes
        guard b.count >= 2, b[0] == WireV3.version else { throw WireV3.Failure.malformed("not a v3 frame") }
        let body = Data(b.dropFirst(2))
        switch b[1] {
        case 1 where body.count >= 32 + 96 && body.count <= 32 + 65_535:
            self = .handshakeInit(deviceSigningKey: body.prefix(32), message: Data(body.dropFirst(32)))
        case 2 where body.count >= sid + 48 && body.count <= sid + 65_535:
            self = .handshakeResponse(sid: body.prefix(sid), message: Data(body.dropFirst(sid)))
        case 3 where body.count >= sid + 8 + 16:
            let counter = body.dropFirst(sid).prefix(8).reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
            guard counter <= WireV3.maxCounter else { throw WireV3.Failure.malformed("counter out of range") }
            self = .transport(sid: body.prefix(sid), counter: counter, ciphertext: Data(body.dropFirst(sid + 8)))
        default:
            throw WireV3.Failure.malformed("bad v3 frame")
        }
    }

    public init(payload: String) throws {
        guard let bytes = Data(base64URLEncoded: payload) else { throw WireV3.Failure.malformed("payload is not base64url") }
        try self.init(bytes: bytes)
    }
}

public struct V3Session: Sendable {
    public let sid: Data
    public let handshakeHash: Data
    private let sendKey: SymmetricKey
    private let recvKey: SymmetricKey
    public private(set) var sendCounter: UInt64 = 0
    public private(set) var lastReceived: UInt64?

    init(sid: Data, handshakeHash: Data, sendKey: Data, recvKey: Data) {
        self.sid = sid
        self.handshakeHash = handshakeHash
        self.sendKey = SymmetricKey(data: sendKey)
        self.recvKey = SymmetricKey(data: recvKey)
    }

    public mutating func seal(_ plaintext: Data) throws -> V3Frame {
        guard sendCounter <= WireV3.maxCounter else { throw WireV3.Failure.malformed("session exhausted") }
        let counter = sendCounter
        let ciphertext = try Noise.encrypt(sendKey, counter, Data(), plaintext)
        sendCounter += 1
        return .transport(sid: sid, counter: counter, ciphertext: ciphertext)
    }

    public mutating func open(_ frame: V3Frame) throws -> Data {
        guard case .transport(let sid, let counter, let ciphertext) = frame else { throw WireV3.Failure.malformed("not a transport frame") }
        guard sid == self.sid else { throw WireV3.Failure.otherSession }
        if let lastReceived, counter <= lastReceived { throw WireV3.Failure.replay }
        let plaintext = try Noise.decrypt(recvKey, counter, Data(), ciphertext)
        lastReceived = counter
        return plaintext
    }

    public mutating func seal(_ event: V3Event) throws -> V3Frame { try seal(event.encoded()) }

    public mutating func openEvent(_ frame: V3Frame) throws -> V3Event {
        try JSONDecoder().decode(V3Event.self, from: open(frame))
    }
}

public struct V3HandshakePayload: Codable, Equatable, Sendable {
    public var ts: Int64
    public var proof: String?

    public init(ts: Int64, proof: String? = nil) {
        self.ts = ts
        self.proof = proof
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct V3ClientHandshake {
    public let frame: V3Frame
    private let noise: NoiseIKHandshake

    public init(identity: PhoneIdentity, pairing: QrPayload, now: Date = Date(), ephemeral: Data? = nil) throws {
        guard let roomId = pairing.roomId, let hostKey = Data(base64URLEncoded: pairing.macPubkey), hostKey.count == 32 else {
            throw WireV3.Failure.malformed("pairing lacks room or host key")
        }
        var noise = try NoiseIKHandshake(role: .initiator, staticKey: identity.sessionPrivateKey, remoteStatic: hostKey,
            prologue: WireV3.prologue(roomId: roomId, deviceSigningKey: identity.signingPublicKey), ephemeral: ephemeral)
        let proof = pairing.secret.map {
            YorozuCrypto.helloProof(secret: $0, pub: identity.sessionPublicKey.base64URLEncodedString(),
                spub: identity.signingPublicKey.base64URLEncodedString())
        }
        let payload = try V3HandshakePayload(ts: Int64(now.timeIntervalSince1970 * 1000), proof: proof).encoded()
        frame = .handshakeInit(deviceSigningKey: identity.signingPublicKey, message: try noise.writeMessage(payload))
        self.noise = noise
    }

    public var sid: Data { frame.sid }

    public func finish(_ response: V3Frame) throws -> V3Session {
        guard case .handshakeResponse(let sid, let message) = response else { throw WireV3.Failure.malformed("not a handshake response") }
        guard sid == self.sid else { throw WireV3.Failure.otherSession }
        var noise = noise
        _ = try noise.readMessage(message)
        return try noise.split(sid: sid)
    }
}
