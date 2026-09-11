import CryptoKit
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

/// Frame bodies, base64url JSON inside the relay's opaque `payload`. `hello` is the phone
/// announcing its X25519 key; everything after it is sealed. Mirrors `FrameBody` in
/// packages/runtime/src/serve.ts.
private struct FrameBody: Codable {
    var t: String
    /// `hello`: phone X25519 public key, base64url.
    var pub: String?
    /// `box`: nonce and ciphertext, base64url.
    var n: String?
    var c: String?
}

/// The relay's own control messages. Only the envelope is ours; `payload` stays opaque to it.
private struct Inbound: Decodable {
    var type: String
    var payload: String?
    var ownerOnline: Bool?
    var online: Bool?
}

/// Phone side of the blind relay: join a room with the one-time token from the pairing QR,
/// announce our X25519 key in one cleartext `hello` frame, then exchange sealed
/// ``YorozuEvent``s under the derived session key.
///
/// Transport only — it owns no UI state, so the Mac app can reuse it for its own client half.
/// Mirrors the sidecar in packages/runtime/src/serve.ts.
public actor RelayClient: ChatTransport {
    /// Spelled as nested names because this client predates ``ChatTransport`` and its callers
    /// already say `RelayClient.State`. `ownerOnline` is the relay's view of whether the room's
    /// Mac holds a live socket: frames sent while it is false are buffered and drained later.
    public typealias State = TransportState
    public typealias Update = TransportUpdate

    private let pairing: QrPayload
    private let identity: PhoneIdentity
    private let socket: URLSessionWebSocketTask
    private let sessionKey: SymmetricKey
    private var updates: AsyncStream<Update>.Continuation?

    /// Throws if the QR payload is not usable: a bad relay URL, a missing room, or a Mac
    /// public key the session key cannot be agreed from.
    public init(
        pairing: QrPayload,
        identity: PhoneIdentity,
        session: URLSession = .shared
    ) throws {
        guard let url = URL(string: pairing.relayUrl), url.scheme?.hasPrefix("ws") == true else {
            throw YorozuCrypto.CryptoError.malformed("relay URL is not a websocket URL")
        }
        guard pairing.roomId != nil else {
            throw YorozuCrypto.CryptoError.malformed("QR payload carries no room ID")
        }
        guard let macPub = Data(base64URLEncoded: pairing.macPubkey) else {
            throw YorozuCrypto.CryptoError.malformed("Mac public key is not base64url")
        }
        self.pairing = pairing
        self.identity = identity
        self.socket = session.webSocketTask(with: url)
        self.sessionKey = try YorozuCrypto.deriveSessionKey(
            myPriv: identity.sessionPrivateKey,
            theirPub: macPub
        )
    }

    /// Opens the socket and yields every update until the connection ends. Calling it twice
    /// replaces the previous stream's continuation, so treat it as one-shot per client.
    public func connect() -> AsyncStream<Update> {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        updates = continuation
        continuation.yield(.state(.connecting))
        socket.resume()
        Task { await receiveLoop() }
        return stream
    }

    public func close() {
        socket.cancel(with: .goingAway, reason: nil)
        updates?.yield(.state(.closed))
        updates?.finish()
        updates = nil
    }

    /// Seals `event` under the session key and sends it as one signed frame.
    public func send(_ event: YorozuEvent) async throws {
        let box = try YorozuCrypto.seal(key: sessionKey, plaintext: try JSONEncoder().encode(event))
        try await sendFrame(
            FrameBody(
                t: "box",
                n: box.nonce.base64URLEncodedString(),
                c: box.ciphertext.base64URLEncodedString()
            )
        )
    }

    private func receiveLoop() async {
        do {
            while true {
                guard case .string(let text) = try await socket.receive() else { continue }
                try handle(text)
            }
        } catch {
            updates?.yield(.failed(error.localizedDescription))
            updates?.yield(.state(.closed))
            updates?.finish()
            updates = nil
        }
    }

    /// Everything here is attacker-controlled; a malformed frame must not tear the client down,
    /// so per-frame decode failures are reported and skipped rather than thrown.
    private func handle(_ text: String) throws {
        guard let message = try? JSONDecoder().decode(Inbound.self, from: Data(text.utf8)) else {
            return
        }
        switch message.type {
        case "nonce":
            // The relay challenges every socket; only the Mac registers. We redeem the token.
            Task { await join() }
        case "joined":
            updates?.yield(.state(.joined))
            updates?.yield(.ownerOnline(message.ownerOnline ?? false))
            Task { await sayHello() }
        case "owner":
            updates?.yield(.ownerOnline(message.online ?? false))
        case "frame":
            open(message.payload)
        default:
            break
        }
    }

    private func join() async {
        do {
            let token = pairing.token
            let signature = try YorozuCrypto.signFrame(
                priv: identity.signingPrivateKey,
                data: Data(token.utf8)
            )
            try await send([
                "type": "join",
                "roomId": pairing.roomId ?? "",
                "token": token,
                "phonePubkey": identity.signingPublicKey.base64URLEncodedString(),
                "sig": signature.base64URLEncodedString(),
            ])
        } catch {
            updates?.yield(.failed(error.localizedDescription))
        }
    }

    private func sayHello() async {
        do {
            try await sendFrame(
                FrameBody(t: "hello", pub: identity.sessionPublicKey.base64URLEncodedString())
            )
            updates?.yield(.state(.paired))
        } catch {
            updates?.yield(.failed(error.localizedDescription))
        }
    }

    private func open(_ payload: String?) {
        guard let payload, let raw = Data(base64URLEncoded: payload),
            let body = try? JSONDecoder().decode(FrameBody.self, from: raw),
            body.t == "box",
            let nonce = body.n.flatMap({ Data(base64URLEncoded: $0) }),
            let ciphertext = body.c.flatMap({ Data(base64URLEncoded: $0) })
        else { return }
        // Several phones can be paired at once: the Mac seals a copy per device and the relay
        // broadcasts all of them, so a frame we cannot open is simply another device's and is
        // dropped without a word.
        guard let plain = try? YorozuCrypto.open(key: sessionKey, nonce: nonce, ciphertext: ciphertext)
        else { return }
        do {
            updates?.yield(.event(try JSONDecoder().decode(YorozuEvent.self, from: plain)))
        } catch {
            updates?.yield(.failed("undecodable event: \(error.localizedDescription)"))
        }
    }

    /// The relay verifies the signature over the base64url `payload` string itself.
    private func sendFrame(_ body: FrameBody) async throws {
        let payload = try JSONEncoder().encode(body).base64URLEncodedString()
        let signature = try YorozuCrypto.signFrame(
            priv: identity.signingPrivateKey,
            data: Data(payload.utf8)
        )
        try await send([
            "type": "frame",
            "payload": payload,
            "sig": signature.base64URLEncodedString(),
        ])
    }

    private func send(_ message: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
