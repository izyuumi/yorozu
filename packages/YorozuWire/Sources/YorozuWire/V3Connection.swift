import Foundation

/// The client's relay link for wire v3 (docs/ios-relay-contract.md): one relay socket at a time, a Noise IK
/// handshake on every socket and whenever the relay reports the host back online, then sealed `V3Event`s.
/// Re-dials with a capped backoff until ``stop()``. Every relay message is attacker-controlled: anything that does
/// not parse or open is dropped, never thrown.
public actor V3Connection {
    public enum State: Equatable, Sendable {
        /// Stopped, or between sockets.
        case offline
        /// Dialling or joining the relay.
        case connecting
        /// Joined; the relay says the plugin holds no socket. Messages wait for it.
        case hostOffline
        /// Joined, the init frame is out, waiting for the plugin's response and `peer_info`.
        case handshaking
        /// The session is up and both `peer_info`s are exchanged: messages may go.
        case ready
        /// No common protocol version. Stopped.
        case updateRequired
        /// The pairing code was refused (expired or already used). Stopped.
        case pairingFailed(String)
        /// The relay or the plugin no longer knows this device. Stopped.
        case unpaired
    }

    public enum Update: Sendable {
        case state(State)
        case event(V3Event)
        /// The relay's `accepted` for the frame that carried this `messageId`: ✓ sent.
        case accepted(messageId: String)
        /// The relay let this device in for the first time: the one-time token is spent.
        case relayJoined
        /// A session is up and the plugin's `peer_info` arrived. The first one also proves the pairing.
        case sessionOpen(V3PeerInfo)
    }

    private var pairing: QrPayload
    private let identity: PhoneIdentity
    private let local: V3PeerInfo
    private let urlSession: URLSession
    private let dial: URL
    /// The relay knows this device: joins sign the connect nonce instead of spending the token.
    private var relayKnows: Bool
    /// A token join failed as unknown: the token may have been spent on a socket lost before `joined`.
    private var triedAsKnown = false

    private var continuation: AsyncStream<Update>.Continuation?
    private var running = false
    /// Bumped per socket, so callbacks from an old one are ignored.
    private var generation = 0
    private var socket: URLSessionWebSocketTask?
    private var hostOnline = false
    private var handshake: V3ClientHandshake?
    private var session: V3Session?
    private var peerReady = false
    private var state = State.offline
    /// Frame signature -> messageId, for `accepted`. Per socket.
    private var sentSigs: [String: String] = [:]
    private var attempt = 0
    private var flowControl = false
    private var lastFlowAck = 0
    private var framesSinceAck = 0
    private var retry: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var pongDeadline: Task<Void, Never>?
    private var handshakeDeadline: Task<Void, Never>?

    static let pingInterval: Duration = .seconds(25)
    static let pongTimeout: Duration = .seconds(10)
    /// No response and `peer_info` within this: a new init frame (the plugin may have restarted meanwhile).
    static let handshakeTimeout: Duration = .seconds(15)

    /// `relayKnows`: the relay accepted this device before, so `pairing.token` is spent. `pairing.secret`, while
    /// present, goes into every handshake as the pairing proof; it is dropped after the first ``Update/sessionOpen(_:)``.
    public init(pairing: QrPayload, identity: PhoneIdentity, relayKnows: Bool, local: V3PeerInfo,
        urlSession: URLSession = .shared) throws {
        guard pairing.v == 3, let room = pairing.roomId, QrPayload.isAcceptableRelayUrl(pairing.relayUrl),
              var components = URLComponents(string: pairing.relayUrl) else {
            throw WireV3.Failure.malformed("not a v3 pairing")
        }
        // The relay routes the socket on the room before it reads anything.
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "room", value: room)]
        guard let dial = components.url else { throw WireV3.Failure.malformed("relay URL") }
        self.pairing = pairing
        self.identity = identity
        self.relayKnows = relayKnows
        self.local = local
        self.urlSession = urlSession
        self.dial = dial
    }

    /// One stream per connection; call once, before ``start()``.
    public func updates() -> AsyncStream<Update> {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        self.continuation = continuation
        return stream
    }

    /// Dials, and keeps re-dialling until ``stop()``.
    public func start() {
        guard !running else { return }
        running = true
        attempt = 0
        connect()
    }

    /// Drops any socket now and dials again without waiting out the backoff (the app came back to the foreground:
    /// a socket iOS suspended may be half open).
    public func reconnect() {
        guard running else { return start() }
        attempt = 0
        connect()
    }

    public func stop() {
        running = false
        drop()
        retry?.cancel()
        set(.offline)
    }

    /// Seals and sends a user message. False when no session is ready: the caller keeps it for the next one.
    @discardableResult
    public func send(_ message: V3Message) -> Bool {
        guard state == .ready, var session, let socket else { return false }
        guard let frame = try? session.seal(.message(message)) else { return false }
        self.session = session
        guard let sig = transmit(frame, on: socket) else { return false }
        sentSigs[sig] = message.messageId
        return true
    }

    // MARK: Socket

    private func connect() {
        drop()
        retry?.cancel()
        retry = nil
        generation += 1
        let gen = generation
        let task = urlSession.webSocketTask(with: dial)
        // The relay's own cap is 1 MiB per message; room for its JSON around it.
        task.maximumMessageSize = 4 << 20
        socket = task
        set(.connecting)
        task.resume()
        Task { await self.receive(task, gen) }
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) async {
        while true {
            do {
                let message = try await task.receive()
                guard gen == generation else { return }
                if case .string(let text) = message { handle(text) }
            } catch {
                guard gen == generation else { return }
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                return closed(reason: reason)
            }
        }
    }

    /// Ends the current socket and its session; no state change, no retry.
    private func drop() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        generation += 1
        endSession()
        hostOnline = false
        sentSigs = [:]
        pinger?.cancel()
        pongDeadline?.cancel()
        pongDeadline = nil
    }

    private func endSession() {
        handshake = nil
        session = nil
        peerReady = false
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
    }

    private func closed(reason: String) {
        drop()
        guard running else { return }
        switch reason {
        case "revoked":
            return terminal(.unpaired)
        case "unknown device" where relayKnows:
            return terminal(.unpaired)
        case "unknown token", "expired token", "unknown device":
            // A new device whose token the relay refused: it may have spent it on this device on a socket lost
            // before `joined`, so one join as a known device; past that the code is used up.
            if !relayKnows && !triedAsKnown && reason == "unknown token" {
                triedAsKnown = true
                return connect()
            }
            return terminal(.pairingFailed(reason))
        default:
            set(.offline)
            scheduleRetry()
        }
    }

    private func terminal(_ final: State) {
        running = false
        retry?.cancel()
        set(final)
    }

    /// 1 s, doubling to 30 s.
    private func scheduleRetry() {
        attempt += 1
        let delay = min(30, 1 << min(attempt - 1, 5))
        retry = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self.running else { return }
            self.connect()
        }
    }

    private func set(_ new: State) {
        guard new != state else { return }
        state = new
        continuation?.yield(.state(new))
    }

    /// Enqueued on the socket synchronously, so frames leave in the order they were sealed. Returns the signature.
    private func transmit(_ frame: V3Frame, on socket: URLSessionWebSocketTask) -> String? {
        let payload = frame.payload
        guard let sig = try? YorozuCrypto.signFrame(priv: identity.signingPrivateKey, data: Data(payload.utf8))
            .base64URLEncodedString() else { return nil }
        send(["type": "frame", "payload": payload, "sig": sig], on: socket)
        return sig
    }

    private func send(_ message: [String: String], on socket: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        // A failed send ends the socket, which the receive loop reports.
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    // MARK: Relay

    private func handle(_ text: String) {
        guard let socket,
              let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = message["type"] as? String else { return }
        switch type {
        case "nonce":
            guard let nonce = message["nonce"] as? String else { return }
            join(nonce: nonce, on: socket)
        case "joined":
            if !relayKnows {
                relayKnows = true
                continuation?.yield(.relayJoined)
            }
            attempt = 0
            flowControl = message["flowControl"] as? Bool == true
            lastFlowAck = 0
            framesSinceAck = 0
            startPings(on: socket)
            hostOnline = message["ownerOnline"] as? Bool == true
            if hostOnline { beginHandshake(on: socket) } else { set(.hostOffline) }
            // `joined` says presence as of when it was written; ask for the live answer.
            send(["type": "owner"], on: socket)
        case "owner":
            let online = message["online"] as? Bool == true
            if online && !hostOnline {
                // Back after being away: the plugin may have restarted and lost its sessions.
                hostOnline = true
                beginHandshake(on: socket)
            } else if !online && hostOnline {
                hostOnline = false
                endSession()
                set(.hostOffline)
            }
        case "frame":
            let payloads = (message["frames"] as? [[String: Any]])?.compactMap { $0["payload"] as? String }
                ?? [message["payload"] as? String].compactMap { $0 }
            for payload in payloads { frame(payload, on: socket) }
            if flowControl, let bytes = (message["flowBytes"] as? NSNumber)?.intValue, bytes > lastFlowAck {
                framesSinceAck += 1
                if bytes - lastFlowAck >= 256 << 10 || framesSinceAck >= 16 {
                    lastFlowAck = bytes
                    framesSinceAck = 0
                    send(["type": "flowAck", "bytes": String(bytes)], on: socket)
                }
            }
        case "accepted":
            if let sig = message["sig"] as? String, let id = sentSigs.removeValue(forKey: sig) {
                continuation?.yield(.accepted(messageId: id))
            }
        case "pong":
            pongDeadline?.cancel()
            pongDeadline = nil
        default:
            break
        }
    }

    /// The first join spends the one-time token; every later one signs the relay's connect nonce.
    private func join(nonce: String, on socket: URLSessionWebSocketTask) {
        let known = relayKnows || triedAsKnown
        let challenge = known ? nonce : pairing.token
        guard let room = pairing.roomId,
              let sig = try? YorozuCrypto.signFrame(priv: identity.signingPrivateKey, data: Data(challenge.utf8)) else { return }
        var message = [
            "type": "join",
            "roomId": room,
            "phonePubkey": identity.signingPublicKey.base64URLEncodedString(),
            "sig": sig.base64URLEncodedString(),
        ]
        if !known { message["token"] = pairing.token }
        send(message, on: socket)
    }

    private func startPings(on socket: URLSessionWebSocketTask) {
        pinger?.cancel()
        pinger = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pingInterval)
                guard !Task.isCancelled else { return }
                self.ping(on: socket)
            }
        }
    }

    /// A missed pong is the only way to tell a half-open socket from a quiet one.
    private func ping(on socket: URLSessionWebSocketTask) {
        guard socket === self.socket, pongDeadline == nil else { return }
        pongDeadline = Task {
            try? await Task.sleep(for: Self.pongTimeout)
            guard !Task.isCancelled, socket === self.socket else { return }
            self.pongDeadline = nil
            self.closed(reason: "")
        }
        send(["type": "ping"], on: socket)
    }

    // MARK: Session

    private func beginHandshake(on socket: URLSessionWebSocketTask) {
        endSession()
        guard let hs = try? V3ClientHandshake(identity: identity, pairing: pairing) else { return }
        handshake = hs
        set(.handshaking)
        _ = transmit(hs.frame, on: socket)
        handshakeDeadline = Task {
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard !Task.isCancelled, socket === self.socket, self.hostOnline, !self.peerReady else { return }
            self.beginHandshake(on: socket)
        }
    }

    private func frame(_ payload: String, on socket: URLSessionWebSocketTask) {
        guard let frame = try? V3Frame(payload: payload) else { return }
        switch frame {
        case .handshakeResponse:
            // Other devices' responses carry other sids; a forged one fails and leaves the handshake waiting.
            guard session == nil, let handshake, var opened = try? handshake.finish(frame),
                  let hello = try? opened.seal(.peerInfo(local)) else { return }
            session = opened
            self.handshake = nil
            _ = transmit(hello, on: socket)
        case .transport:
            guard var session, let event = try? session.openEvent(frame) else { return }
            self.session = session
            receive(event)
        case .handshakeInit:
            break
        }
    }

    private func receive(_ event: V3Event) {
        guard peerReady else {
            // Nothing counts before the plugin's `peer_info`.
            guard case .peerInfo(let peer) = event else {
                if case .error(let error) = event, error.code == "update_required" { stopForUpdate() }
                return
            }
            guard local.negotiate(with: peer) != nil else { return stopForUpdate() }
            peerReady = true
            handshakeDeadline?.cancel()
            handshakeDeadline = nil
            // The plugin answered, so the proof was accepted: the secret has done its job.
            pairing.secret = nil
            set(.ready)
            continuation?.yield(.sessionOpen(peer))
            return
        }
        if case .error(let error) = event, error.code == "update_required" { return stopForUpdate() }
        continuation?.yield(.event(event))
    }

    private func stopForUpdate() {
        drop()
        terminal(.updateRequired)
    }
}
