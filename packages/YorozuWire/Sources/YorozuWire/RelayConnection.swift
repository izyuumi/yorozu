import Foundation
import os

let connectionLog = Logger(subsystem: "to.yumi.yorozu", category: "Connection")

extension Duration {
    var ms: Int64 { components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000 }
}

public actor RelayConnection {
    public enum State: Equatable, Sendable {
        case offline
        case connecting
        case hostOffline
        case handshaking
        case ready
        case updateRequired
        case pairingFailed(String)
        case unpaired
    }

    public enum Update: Sendable {
        case state(State)
        case event(WireEvent)
        case accepted(messageId: String)
        case relayJoined
        case sessionOpen(PeerInfo)
    }

    /// A relay, or the plugin's direct listener (#532): a probe instead of `join`, no relay buffer, flow control or push.
    enum Path: Sendable { case relay, direct }

    private let path: Path
    private var pairing: QrPayload
    private let identity: PhoneIdentity
    private let local: PeerInfo
    private let urlSession: URLSession
    private let dial: URL
    private var relayKnows: Bool
    private var triedAsKnown = false
    private var probeNonce: String?
    private var ready: (@Sendable () -> Void)?
    private var awaitingGrant = false
    private var granted = false
    private var hostCapabilities: [String] = []

    private var continuation: AsyncStream<Update>.Continuation?
    private var running = false
    private var generation = 0
    private var socket: URLSessionWebSocketTask?
    private var hostOnline = false
    private var handshake: ClientHandshake?
    private var session: Session?
    private var peerReady = false
    private var state = State.offline
    private var sentSigs: [String: String] = [:]
    private var attempt = 0
    private var flowControl = false
    private var lastFlowAck = 0
    private var framesSinceAck = 0
    private var retry: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var pongDeadline: Task<Void, Never>?
    private var handshakeDeadline: Task<Void, Never>?
    private var pushToken: String?
    private var joined = false
    /// "<path> <host[:port]>" for the log: never the query, which holds the room id.
    nonisolated let host: String
    nonisolated let label: String
    private var dialed = ContinuousClock.now
    private var socketOpen = false

    static let pingInterval: Duration = .seconds(25)
    static let pongTimeout: Duration = .seconds(10)
    static let handshakeTimeout: Duration = .seconds(15)

    public init(pairing: QrPayload, identity: PhoneIdentity, relayKnows: Bool, local: PeerInfo,
        urlSession: URLSession = .shared) throws {
        self.init(path: .relay, dial: try RelayConnection.relayURL(pairing), pairing: pairing, identity: identity, relayKnows: relayKnows,
            local: local, urlSession: urlSession)
    }

    init(path: Path, dial: URL, pairing: QrPayload, identity: PhoneIdentity, relayKnows: Bool, local: PeerInfo,
        urlSession: URLSession) {
        self.path = path
        self.pairing = pairing
        self.identity = identity
        self.relayKnows = relayKnows
        self.local = local
        self.urlSession = urlSession
        self.dial = dial
        host = Self.hostPort(dial)
        label = "\(path) \(host)"
    }

    static func hostPort(_ url: URL) -> String {
        let host = url.host(percentEncoded: false) ?? "?"
        let shown = host.contains(":") ? "[\(host)]" : host
        return url.port.map { "\(shown):\($0)" } ?? shown
    }

    static func relayURL(_ pairing: QrPayload) throws -> URL {
        guard pairing.v == 3, let room = pairing.roomId, QrPayload.isAcceptableRelayUrl(pairing.relayUrl),
              var components = URLComponents(string: pairing.relayUrl) else {
            throw Wire.Failure.malformed("not a pairing for this app")
        }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "room", value: room)]
        guard let dial = components.url else { throw Wire.Failure.malformed("relay URL") }
        return dial
    }

    /// Hands the decision to send the init to a race (`RacingConnection`): `ready` is called when the leg could.
    func gate(_ ready: @escaping @Sendable () -> Void) {
        self.ready = ready
    }

    func grant() -> Bool {
        guard awaitingGrant, let socket, hostOnline, session == nil else { return false }
        awaitingGrant = false
        granted = true
        beginHandshake(on: socket)
        return true
    }

    public func updates() -> AsyncStream<Update> {
        let (stream, continuation) = AsyncStream<Update>.makeStream()
        self.continuation = continuation
        return stream
    }

    public func start() {
        guard !running else { return }
        running = true
        attempt = 0
        connect()
    }

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

    public func registerPush(deviceToken: String) {
        pushToken = deviceToken
        if path == .direct { return sendPushToken() }
        if joined, let socket { send(["type": "push", "deviceToken": deviceToken], on: socket) }
    }

    private func sendPushToken() {
        guard path == .direct, let pushToken, hostCapabilities.contains(PushProxy.capability) else { return }
        send(.pushToken(PushToken(token: pushToken)))
    }

    @discardableResult
    public func send(_ message: Message) -> Bool {
        guard state == .ready, var session, let socket else { return false }
        guard let frame = try? session.seal(.message(message)) else { return false }
        self.session = session
        guard let sig = transmit(frame, on: socket) else { return false }
        sentSigs[sig] = message.messageId
        return true
    }

    @discardableResult
    public func send(_ event: WireEvent) -> Bool {
        guard state == .ready, var session, let socket, let frame = try? session.seal(event) else { return false }
        self.session = session
        return transmit(frame, on: socket) != nil
    }

    private func connect() {
        drop()
        retry?.cancel()
        retry = nil
        generation += 1
        joined = false
        let gen = generation
        let task = urlSession.webSocketTask(with: dial)
        task.maximumMessageSize = 4 << 20
        socket = task
        dialed = .now
        socketOpen = false
        set(.connecting)
        task.resume()
        if path == .direct {
            let nonce = Direct.newNonce()
            probeNonce = nonce
            send(["type": "probe", "nonce": nonce], on: task)
        }
        Task { await self.receive(task, gen) }
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) async {
        while true {
            do {
                let message = try await task.receive()
                guard gen == generation else { return }
                if !socketOpen {
                    // URLSession reports no open without a delegate; the first message proves it.
                    socketOpen = true
                    connectionLog.info("\(self.label, privacy: .public): socket open after \((ContinuousClock.now - self.dialed).ms, privacy: .public) ms")
                }
                if case .string(let text) = message { handle(text) }
            } catch {
                guard gen == generation else { return }
                let reason = task.closeReason.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let ms = (ContinuousClock.now - dialed).ms
                if task.closeCode != .invalid {
                    connectionLog.info("\(self.label, privacy: .public): closed \(task.closeCode.rawValue, privacy: .public) \(reason) after \(ms, privacy: .public) ms")
                } else {
                    let ns = error as NSError
                    connectionLog.error("\(self.label, privacy: .public): failed \(ns.domain, privacy: .public) \(ns.code, privacy: .public) after \(ms, privacy: .public) ms")
                }
                return closed(reason: reason)
            }
        }
    }

    private func drop() {
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        generation += 1
        endSession()
        hostOnline = false
        probeNonce = nil
        granted = false
        sentSigs = [:]
        pinger?.cancel()
        pongDeadline?.cancel()
        pongDeadline = nil
    }

    private func endSession() {
        awaitingGrant = false
        handshake = nil
        session = nil
        peerReady = false
        handshakeDeadline?.cancel()
        handshakeDeadline = nil
    }

    private func closed(reason: String) {
        drop()
        guard running else { return }
        // A direct leg does not redial: its race decides what comes next.
        if path == .direct {
            running = false
            return set(.offline)
        }
        switch reason {
        case "revoked":
            return terminal(.unpaired)
        case "unknown device" where relayKnows:
            return terminal(.unpaired)
        case "unknown token", "expired token", "unknown device":
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

    private func transmit(_ frame: Frame, on socket: URLSessionWebSocketTask) -> String? {
        let payload = frame.payload
        guard let sig = try? YorozuCrypto.signFrame(priv: identity.signingPrivateKey, data: Data(payload.utf8))
            .base64URLEncodedString() else { return nil }
        send(["type": "frame", "payload": payload, "sig": sig], on: socket)
        return sig
    }

    private func send(_ message: [String: String], on socket: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    private func handle(_ text: String) {
        guard let socket,
              let message = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let type = message["type"] as? String else { return }
        // A direct listener is nobody until its probe answer proves the room's key, and never a relay: it gets no join
        // signature over a nonce of its choosing.
        if path == .direct {
            guard hostOnline || type == "probe" else { return }
            guard !["nonce", "joined", "owner"].contains(type) else { return }
        }
        switch type {
        case "probe":
            guard path == .direct, let nonce = probeNonce, let room = pairing.roomId else { return }
            probeNonce = nil
            guard let pubkey = message["pubkey"] as? String, let sig = message["sig"] as? String,
                  Direct.verifyProbe(room: room, nonce: nonce, pubkey: pubkey, sig: sig) else {
                connectionLog.error("\(self.label, privacy: .public): probe rejected after \((ContinuousClock.now - self.dialed).ms, privacy: .public) ms")
                return closed(reason: "")
            }
            connectionLog.info("\(self.label, privacy: .public): probe verified")
            hostOnline = true
            startPings(on: socket)
            handshakeWhenGranted(on: socket)
        case "nonce":
            guard let nonce = message["nonce"] as? String else { return }
            join(nonce: nonce, on: socket)
        case "joined":
            if !relayKnows {
                relayKnows = true
                continuation?.yield(.relayJoined)
            }
            attempt = 0
            joined = true
            if let pushToken { send(["type": "push", "deviceToken": pushToken], on: socket) }
            flowControl = message["flowControl"] as? Bool == true
            lastFlowAck = 0
            framesSinceAck = 0
            startPings(on: socket)
            hostOnline = message["ownerOnline"] as? Bool == true
            if hostOnline { handshakeWhenGranted(on: socket) } else { set(.hostOffline) }
            send(["type": "owner"], on: socket)
        case "owner":
            let online = message["online"] as? Bool == true
            if online && !hostOnline {
                hostOnline = true
                handshakeWhenGranted(on: socket)
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

    private func ping(on socket: URLSessionWebSocketTask) {
        guard socket === self.socket, pongDeadline == nil else { return }
        pongDeadline = Task {
            try? await Task.sleep(for: Self.pongTimeout)
            guard !Task.isCancelled, socket === self.socket else { return }
            connectionLog.error("\(self.label, privacy: .public): failed, no pong")
            self.pongDeadline = nil
            self.closed(reason: "")
        }
        send(["type": "ping"], on: socket)
    }

    private func handshakeWhenGranted(on socket: URLSessionWebSocketTask) {
        guard let ready, !granted else { return beginHandshake(on: socket) }
        endSession()
        awaitingGrant = true
        set(.handshaking)
        ready()
    }

    private func beginHandshake(on socket: URLSessionWebSocketTask) {
        endSession()
        guard let hs = try? ClientHandshake(identity: identity, pairing: pairing) else { return }
        handshake = hs
        set(.handshaking)
        _ = transmit(hs.frame, on: socket)
        connectionLog.info("\(self.label, privacy: .public): handshake granted, init sent")
        handshakeDeadline = Task {
            try? await Task.sleep(for: Self.handshakeTimeout)
            guard !Task.isCancelled, socket === self.socket, self.hostOnline, !self.peerReady else { return }
            connectionLog.error("\(self.label, privacy: .public): handshake timed out")
            // Nothing buffers on the direct path: a handshake that got no answer fails the leg.
            if self.path == .direct { return self.closed(reason: "") }
            self.beginHandshake(on: socket)
        }
    }

    private func frame(_ payload: String, on socket: URLSessionWebSocketTask) {
        guard let frame = try? Frame(payload: payload) else { return }
        switch frame {
        case .handshakeResponse:
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

    private func receive(_ event: WireEvent) {
        guard peerReady else {
            guard case .peerInfo(let peer) = event else {
                if case .error(let error) = event, error.code == "update_required" { stopForUpdate() }
                return
            }
            guard local.negotiate(with: peer) != nil else { return stopForUpdate() }
            peerReady = true
            handshakeDeadline?.cancel()
            handshakeDeadline = nil
            pairing.secret = nil
            hostCapabilities = peer.capabilities
            connectionLog.info("\(self.label, privacy: .public): session open after \((ContinuousClock.now - self.dialed).ms, privacy: .public) ms")
            set(.ready)
            continuation?.yield(.sessionOpen(peer))
            return sendPushToken()
        }
        if case .error(let error) = event, error.code == "update_required" { return stopForUpdate() }
        continuation?.yield(.event(event))
    }

    private func stopForUpdate() {
        drop()
        terminal(.updateRequired)
    }
}
