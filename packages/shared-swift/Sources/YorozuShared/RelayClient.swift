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
    /// `hello`: phone Ed25519 public key, the one the relay knows this device by. The Mac keeps
    /// it so "remove this device" can be addressed to the relay as well as to itself.
    var spub: String?
    /// `hello`, first time only: ``YorozuCrypto/helloProof`` over the QR's secret and both keys,
    /// which is what tells the Mac these keys came from a phone that read its screen and not
    /// from the relay.
    var proof: String?
    /// `box`: nonce and ciphertext, base64url.
    var n: String?
    var c: String?
}

/// The relay's own control messages. Only the envelope is ours; `payload` stays opaque to it.
private struct Inbound: Decodable {
    var type: String
    var nonce: String?
    var payload: String?
    var ownerOnline: Bool?
    var online: Bool?
}

/// Phone side of the blind relay: join a room with the one-time token from the pairing QR,
/// announce our X25519 key in one cleartext `hello` frame, then exchange sealed
/// ``YorozuEvent``s under the derived session key.
///
/// The socket is not expected to last: a phone is backgrounded, changes network and is
/// relaunched. So the token is spent exactly once — after the first accepted join the relay
/// knows this device, and every later join answers the connect nonce instead — and ``connect()``
/// keeps re-dialling with a capped backoff until ``close()``.
///
/// Transport only — it owns no UI state, so the Mac app can reuse it for its own client half.
/// Mirrors the sidecar in packages/runtime/src/serve.ts.
public actor RelayClient: ChatTransport {
    /// Spelled as nested names because this client predates ``ChatTransport`` and its callers
    /// already say `RelayClient.State`. `ownerOnline` is the relay's view of whether the room's
    /// Mac holds a live socket: frames sent while it is false are buffered and drained later.
    public typealias State = TransportState
    public typealias Update = TransportUpdate

    /// A dropped socket is retried at 1s, 2s, 4s … up to this, and reset by a join.
    private static let maxBackoff: Double = 30
    /// The relay keeps a socket that is talking; nothing else on an idle phone would.
    private static let pingInterval: Duration = .seconds(30)
    /// A ping the relay does not answer within this is a socket that is open in name only —
    /// the phone slept, the network changed — and the receive loop would never find out.
    private static let pongDeadline: Duration = .seconds(10)

    private let pairing: QrPayload
    private let identity: PhoneIdentity
    private let session: URLSession
    private let dial: URL
    private let sessionKey: SymmetricKey
    private var updates: AsyncStream<Update>.Continuation?

    /// Where this device can be woken, kept so every join can say it again. The relay files it
    /// against our signing key, so repeating it replaces the registration rather than adding a
    /// second — and a room that lost its storage heals on the next rejoin.
    private var deviceToken: String?

    private var socket: URLSessionWebSocketTask?
    /// The challenge the relay issued on this socket; a rejoin signs it.
    private var nonce = ""
    /// True once the relay has accepted this device, so later joins need no token. Seeded by
    /// the caller from whatever it persisted, and `onPaired` is how it learns to persist it.
    private var paired: Bool
    private let onPaired: (@Sendable () -> Void)?
    private var joined = false
    /// Set by ``close()``; the only thing that stops the reconnect loop.
    private var stopped = false
    private var attempt = 0
    private var loop: Task<Void, Never>?
    private var backoff: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var pongDeadline: Task<Void, Never>?

    /// Throws if the QR payload is not usable: a bad relay URL, a missing room, or a Mac
    /// public key the session key cannot be agreed from.
    ///
    /// - Parameters:
    ///   - paired: whether the relay already knows this device, so the one-time token in
    ///     `pairing` has been spent and must not be sent again.
    ///   - onPaired: called once, the first time the relay accepts this device, so the caller
    ///     can persist that fact. Called off the main actor.
    public init(
        pairing: QrPayload,
        identity: PhoneIdentity,
        paired: Bool = false,
        session: URLSession = .shared,
        onPaired: (@Sendable () -> Void)? = nil
    ) throws {
        guard let url = URL(string: pairing.relayUrl), url.scheme?.hasPrefix("ws") == true else {
            throw YorozuCrypto.CryptoError.malformed("relay URL is not a websocket URL")
        }
        guard let room = pairing.roomId else {
            throw YorozuCrypto.CryptoError.malformed("QR payload carries no room ID")
        }
        // The room ID is only carried in `join`, which is too late for a relay that has to
        // route the socket before reading it, so it also goes in the URL. Relays that route
        // on the message instead simply ignore the query.
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw YorozuCrypto.CryptoError.malformed("relay URL is not a websocket URL")
        }
        components.queryItems =
            (components.queryItems ?? []) + [URLQueryItem(name: "room", value: room)]
        guard let dial = components.url else {
            throw YorozuCrypto.CryptoError.malformed("relay URL is not a websocket URL")
        }
        guard let macPub = Data(base64URLEncoded: pairing.macPubkey) else {
            throw YorozuCrypto.CryptoError.malformed("Mac public key is not base64url")
        }
        self.pairing = pairing
        self.identity = identity
        self.session = session
        self.dial = dial
        self.paired = paired
        self.onPaired = onPaired
        self.sessionKey = try YorozuCrypto.deriveSessionKey(
            myPriv: identity.sessionPrivateKey,
            theirPub: macPub
        )
    }

    /// Dials, and keeps re-dialling after every drop, yielding every update until ``close()``.
    /// Calling it twice replaces the previous stream's continuation, so treat it as one-shot
    /// per client.
    public func connect() -> AsyncStream<Update> {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        updates = continuation
        // A client that was closed can be dialled again. The phone does exactly this: a
        // background drain hangs up so the OS can suspend it, and the next foreground connects
        // afresh rather than being left with a client that will never redial.
        stopped = false
        loop?.cancel()
        loop = Task { await self.reconnectLoop() }
        return stream
    }

    /// Dials again now instead of waiting out the backoff — the app came back to the
    /// foreground, where a socket dropped while it was suspended is worth nothing. A socket
    /// that still says it is joined is dropped too: iOS can suspend the app with the socket
    /// half-open, and from here that is indistinguishable from a healthy quiet one. One
    /// redial and a sync costs less than sitting on a dead socket until the pong deadline.
    public func reconnect() {
        guard !stopped else { return }
        attempt = 0
        backoff?.cancel()
        socket?.cancel()
    }

    public func close() {
        stopped = true
        pinger?.cancel()
        pongDeadline?.cancel()
        backoff?.cancel()
        loop?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        updates?.yield(.state(.closed))
        updates?.finish()
        updates = nil
    }

    /// One dial per pass; the pass ends when the socket does. `.closed` is deliberately not
    /// yielded between passes: the connection is not over, it is being retried.
    private func reconnectLoop() async {
        while !stopped {
            updates?.yield(.state(.connecting))
            joined = false
            nonce = ""
            let socket = session.webSocketTask(with: dial)
            self.socket = socket
            socket.resume()
            await receiveLoop(socket)
            pinger?.cancel()
            pongDeadline?.cancel()
            guard !stopped else { return }
            // 1s, 2s, 4s … capped, and back to 1s after a join that stuck.
            let delay = min(Self.maxBackoff, pow(2, Double(attempt)))
            attempt += 1
            let backoff = Task<Void, Never> { try? await Task.sleep(for: .seconds(delay)) }
            self.backoff = backoff
            await backoff.value
        }
    }

    /// The relay drops a socket that says nothing for long enough, and a phone in a quiet chat
    /// says nothing for hours. A ping is the cheapest thing that keeps it.
    ///
    /// It is a `{"type":"ping"}` message rather than a websocket ping frame because that is what
    /// the relay answers at its edge, leaving the room itself hibernated.
    ///
    /// Each ping arms a deadline that the pong disarms. A missed one cancels the socket, which
    /// ends the receive loop and lets the reconnect loop dial afresh — the only way a phone can
    /// tell a half-open socket from an idle one.
    private func startPings() {
        pinger?.cancel()
        pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled else { return }
                // A send that throws means the socket is already gone, and the receive loop is
                // the one that reports that; there is nothing useful to do with it here.
                try? await self.send(["type": "ping"])
                self.armPongDeadline()
            }
        }
    }

    private func armPongDeadline() {
        guard pongDeadline == nil else { return }
        let socket = self.socket
        pongDeadline = Task {
            try? await Task.sleep(for: Self.pongDeadline)
            guard !Task.isCancelled else { return }
            await self.pongMissed(on: socket)
        }
    }

    private func pongMissed(on socket: URLSessionWebSocketTask?) {
        pongDeadline = nil
        guard !stopped, let socket, socket === self.socket else { return }
        updates?.yield(.failed("relay stopped answering"))
        socket.cancel()
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

    /// Returns when this socket ends, so the reconnect loop can dial the next one.
    private func receiveLoop(_ socket: URLSessionWebSocketTask) async {
        while true {
            do {
                guard case .string(let text) = try await socket.receive() else { continue }
                try handle(text)
            } catch {
                // Our own cancellation is not a failure worth reporting.
                if !stopped { updates?.yield(.failed(error.localizedDescription)) }
                return
            }
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
            // The relay challenges every socket; only the Mac registers. We join.
            nonce = message.nonce ?? ""
            Task { await join() }
        case "joined":
            joined = true
            attempt = 0
            // The relay remembers this device now, so the one-time token is done with.
            if !paired {
                paired = true
                onPaired?()
            }
            startPings()
            updates?.yield(.state(.joined))
            updates?.yield(.ownerOnline(message.ownerOnline ?? false))
            // `joined` carried presence as of the instant it was written; ask again so what the
            // UI shows is the relay's live answer rather than anything either end remembered.
            Task { await requestOwner() }
            Task { await sayHello() }
            // Where to wake this device, said again: this may be a room that has never heard
            // of us — a redeployed relay, an evicted object — and there is no way to tell.
            Task { await self.sendPush() }
        case "pong":
            pongDeadline?.cancel()
            pongDeadline = nil
        case "owner":
            updates?.yield(.ownerOnline(message.online ?? false))
        case "frame":
            open(message.payload)
        default:
            break
        }
    }

    /// The first join spends the one-time token from the pairing code. Every later one signs the
    /// connect nonce instead — the same challenge the Mac answers — which is what lets the phone
    /// come back after a background, a network change or a relaunch without pairing again.
    private func join() async {
        do {
            let challenge = paired ? nonce : pairing.token
            let signature = try YorozuCrypto.signFrame(
                priv: identity.signingPrivateKey,
                data: Data(challenge.utf8)
            )
            var message = [
                "type": "join",
                "roomId": pairing.roomId ?? "",
                "phonePubkey": identity.signingPublicKey.base64URLEncodedString(),
                "sig": signature.base64URLEncodedString(),
            ]
            if !paired { message["token"] = pairing.token }
            try await send(message)
        } catch {
            updates?.yield(.failed(error.localizedDescription))
        }
    }

    /// The app's own APNs device token, which alerts are addressed to.
    public func registerPush(deviceToken: String) async {
        self.deviceToken = deviceToken
        await sendPush()
    }

    /// Where this device can be woken, said again. Nothing to say until APNs has answered with
    /// a token, and nothing to say it on until the socket has joined.
    private func sendPush() async {
        guard joined, let deviceToken else { return }
        try? await send(["type": "push", "deviceToken": deviceToken])
    }

    /// Asks the relay whether the room's Mac holds a socket right now. The reply is an ordinary
    /// `owner` message, so it lands in the same place the relay's unprompted ones do.
    private func requestOwner() async {
        try? await send(["type": "owner"])
    }

    private func sayHello() async {
        do {
            let pub = identity.sessionPublicKey.base64URLEncodedString()
            let spub = identity.signingPublicKey.base64URLEncodedString()
            // Sent every time rather than only first: the Mac may have lost `devices.json`, and
            // a `hello` it cannot verify is a phone it will not seal for. The relay saw the
            // secret's hash and nothing else, and the hash is bound to these two keys alone.
            let proof = pairing.secret.map { YorozuCrypto.helloProof(secret: $0, pub: pub, spub: spub) }
            try await sendFrame(FrameBody(t: "hello", pub: pub, spub: spub, proof: proof))
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
        guard let socket else { throw YorozuCrypto.CryptoError.malformed("not connected") }
        let data = try JSONSerialization.data(withJSONObject: message)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }
}
