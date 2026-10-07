import CryptoKit
import Foundation
import SystemConfiguration
import YorozuWire

/// What the pair sheet shows.
struct RelayStatus: Sendable {
    var state = "Connecting to the relay…"
    /// The pairing link (QR and copy), while the sheet has asked for one and the relay has minted it.
    var link: String?
    var devices: [RelayDevice] = []
}

/// The Mac half of the v1 relay (packages/runtime/src/serve.ts `connect()`), without legacy boxes, the
/// direct path or notify; the phone half is `RelayClient`. Registers this Mac's room, mints pairing
/// codes, admits a phone only with proof it read one, and exchanges sealed `ChannelEnvelope`s with each
/// paired phone. The wire contract is docs/ios-v0.6.0-contract.md.
actor RelayHost {
    /// `FrameBody` and the relay envelope are private in RelayClient.swift; these are the same shapes.
    private struct FrameBody: Codable { var t: String; var pub, spub, proof, n, c: String? }
    private struct Inbound: Decodable { var type: String; var nonce, payload, token: String?; var seq: Int? }
    private struct Frame: Encodable { var payload, sig: String }
    private struct Batch: Encodable { var type = "frame"; var frames: [Frame] }
    /// A paired phone on this run. `compatibility` is nil until its peer-info claim arrives, and only a
    /// `.compatible` phone is served: every `hello` resets it, so every reconnect runs the exchange again.
    private struct Peer { var record: RelayDevice; let keys: (send: SymmetricKey, recv: SymmetricKey); var compatibility: PeerCompatibility? }

    nonisolated let status: AsyncStream<RelayStatus>
    private let statusOut: AsyncStream<RelayStatus>.Continuation
    private let backend: any RelayBackend
    private let identity: PhoneIdentity
    private let relayURL: String
    /// base64url sha256 of our Ed25519 key: the relay pins the room to that key.
    private let room: String
    private let file: URL
    private var peers: [String: Peer] = [:]
    private var main = ThreadSummary.main(0)
    private var state = RelayStatus().state
    private var link: String?
    private var pairing = false
    /// Secrets behind the last few codes minted, newest last. Only here and in the QR; never the relay.
    private var secrets: [String] = []
    private var socket: URLSessionWebSocketTask?
    private var registered = false
    /// Set once a replayed frame on this socket could not be recorded; nothing after it is acked, so the
    /// relay brings it again.
    private var ackBlocked = false
    private var pongDue = false
    private var retry: Double = 2
    private var loop: Task<Void, Never>?

    init(backend: any RelayBackend, relayURL: String, devicesFile: URL) throws {
        identity = try RelayKeys.loadOrCreate()
        self.backend = backend; self.relayURL = relayURL; file = devicesFile
        let (stream, continuation) = AsyncStream<RelayStatus>.makeStream(); status = stream; statusOut = continuation
        room = Data(SHA256.hash(data: identity.signingPublicKey)).base64URLEncodedString()
        // The relay remembers 16 devices a room, and the announce names every one of them.
        for record in try RelayDeviceFile.load(devicesFile).prefix(16) {
            guard let pub = Data(base64URLEncoded: record.pub),
                  let keys = try? YorozuCrypto.deriveChannelKeys(myPriv: identity.sessionPrivateKey, theirPub: pub, role: .mac) else { continue }
            peers[record.pub] = Peer(record: record, keys: keys)
        }
    }

    func start() {
        guard loop == nil else { return }
        publish()
        loop = Task { await run() }
    }

    func stop() {
        loop?.cancel(); socket?.cancel(with: .goingAway, reason: nil); statusOut.finish()
    }

    /// Live updates to every phone whose peer-info exchange succeeded on this run.
    func broadcast(_ events: [YorozuEvent]) {
        let paired = peers.filter { if case .compatible = $0.value.compatibility { true } else { false } }.map(\.key)
        // Event by event, device by device: each device's seqs leave in the order they were sealed.
        deliver(events.flatMap { event in paired.map { ($0, event) } })
    }

    /// The `main` summary the handshake's thread lists carry, kept current by the bridge so the
    /// handshake never waits on the Engine.
    func setMain(_ main: ThreadSummary) { self.main = main }

    /// A fresh one-time code for the pair sheet. Minted again after each phone pairs, until `endPairing`.
    func mintPairing() {
        pairing = true; link = nil; publish()
        if registered { send(["type": "mint"]) }
    }

    /// The sheet closed: no more codes. Secrets already minted stay until a phone pairs, so a phone
    /// that scanned just before the sheet closed still gets in.
    func endPairing() { pairing = false; link = nil; publish() }

    /// Forgets a phone here and at the relay: it has to pair again.
    func removeDevice(_ pub: String) {
        guard let peer = peers.removeValue(forKey: pub) else { return }
        do { try persist() } catch { peers[pub] = peer; state = error.localizedDescription; return publish() }
        announce()
        if registered { send(["type": "revoke", "pubkey": peer.record.signingPub]) }
        publish()
    }

    // MARK: Socket

    private func run() async {
        guard var dial = URLComponents(string: relayURL) else { state = "Bad relay URL: \(relayURL)"; return publish() }
        // The relay routes on the room before it reads anything, so it goes in the URL too.
        dial.queryItems = (dial.queryItems ?? []) + [URLQueryItem(name: "room", value: room)]
        guard let url = dial.url else { state = "Bad relay URL: \(relayURL)"; return publish() }
        while !Task.isCancelled {
            let ws = URLSession.shared.webSocketTask(with: url)
            socket = ws; ackBlocked = false; pongDue = false
            ws.resume()
            let heartbeat = Task { await self.heartbeat(ws) }
            do {
                while true { if case .string(let text) = try await ws.receive() { receive(text) } }
            } catch {}
            heartbeat.cancel(); ws.cancel()
            socket = nil; registered = false
            state = "Relay offline, retrying…"; publish()
            // Doubling until a registration lands, so a relay that keeps refusing is not hammered.
            try? await Task.sleep(for: .seconds(retry))
            retry = min(retry * 2, 30)
        }
    }

    /// A `{"type":"ping"}` every 30 s (the relay's edge answers it); no pong within 10 s means a
    /// half-open socket, which is cancelled so the loop redials and registers again.
    private func heartbeat(_ ws: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            pongDue = true; send(["type": "ping"])
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled, pongDue { return ws.cancel() }
        }
    }

    private func receive(_ text: String) {
        guard let message = try? JSONDecoder().decode(Inbound.self, from: Data(text.utf8)) else { return }
        switch message.type {
        case "nonce":
            guard let nonce = message.nonce, let sig = try? YorozuCrypto.signFrame(priv: identity.signingPrivateKey, data: Data(nonce.utf8)) else { return }
            send(["type": "register", "pubkey": identity.signingPublicKey.base64URLEncodedString(), "nonceSig": sig.base64URLEncodedString()])
        case "registered":
            registered = true; retry = 2
            announce()
            if pairing { send(["type": "mint"]) }
            rehandshake()
            state = "Connected"; publish()
        case "token":
            guard pairing, let token = message.token else { return }
            newCode(token)
        case "pong":
            pongDue = false
        case "frame":
            // A replayed frame carries the relay's buffer seq, and the ack is cumulative: acked only
            // once handled. A body that is not a frame at all is acked too, or it would replay for ever.
            do {
                if let raw = message.payload.flatMap(Data.init(base64URLEncoded:)),
                   let body = try? JSONDecoder().decode(FrameBody.self, from: raw) { try frame(body) }
            } catch { if message.seq != nil { ackBlocked = true } }
            if let seq = message.seq, !ackBlocked { send(["type": "ack", "seq": seq]) }
        default:
            break
        }
    }

    private func newCode(_ token: String) {
        let secret = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64URLEncodedString()
        secrets = Array((secrets + [secret]).suffix(4))
        let payload = QrPayload(relayUrl: relayURL, macPubkey: identity.sessionPublicKey.base64URLEncodedString(), token: token, roomId: room, secret: secret)
        // The web link the QR carries, with the `yorozu://` query in its fragment so a browser never sends it.
        guard let query = (try? payload.encoded()).flatMap({ URLComponents(string: $0)?.percentEncodedQuery }) else { return }
        link = "\(QrPayload.link)#\(query)"; publish()
    }

    // MARK: Frames

    /// Throws only when a counter or the device list could not be written, which holds back the ack.
    private func frame(_ body: FrameBody) throws {
        if body.t == "hello" { return try hello(body) }
        guard body.t == "box", let nonce = body.n.flatMap(Data.init(base64URLEncoded:)),
              let ciphertext = body.c.flatMap(Data.init(base64URLEncoded:)) else { return }
        // Frames carry no sender: whichever paired key opens one names its device.
        for (pub, var peer) in peers {
            guard let plain = try? YorozuCrypto.open(key: peer.keys.recv, nonce: nonce, ciphertext: ciphertext) else { continue }
            // Malformed or replayed: dropped.
            guard let envelope = try? ChannelEnvelope.decode(plain), peer.record.counter.accept(envelope.seq) else { return }
            // Written before it is acted on, and acted on only if written.
            let before = peers[pub]; peers[pub] = peer
            do { try persist() } catch { peers[pub] = before; throw error }
            return received(envelope.event, from: pub)
        }
    }

    private func hello(_ body: FrameBody) throws {
        guard let pub = body.pub, let raw = Data(base64URLEncoded: pub),
              let keys = try? YorozuCrypto.deriveChannelKeys(myPriv: identity.sessionPrivateKey, theirPub: raw, role: .mac) else { return }
        let known = peers[pub]
        // The relay checked the frame's signature, but it could have signed it itself: keys not on file
        // get in only with proof they came from a phone that read a QR this Mac drew.
        let proved = body.spub.flatMap { spub in body.proof.map { proof in
            secrets.contains { YorozuCrypto.helloProof(secret: $0, pub: pub, spub: spub) == proof } } } ?? false
        // A known phone may say hello again without proof, but cannot move its relay identity without
        // one: `revoke` is addressed to that key.
        guard known != nil || peers.count < 16, let spub = proved ? body.spub : known?.record.signingPub else { return }
        var record = known?.record ?? RelayDevice(pub: pub, signingPub: spub, pairedAt: Date())
        record.signingPub = spub
        peers[pub] = Peer(record: record, keys: keys)
        if known?.record.signingPub != spub {
            do { try persist() } catch { peers[pub] = known; throw error }
            announce()
        }
        // A code is for one phone: the next one gets a fresh code.
        if proved { secrets = []; link = nil; if pairing { send(["type": "mint"]) } }
        publish()
        // The first sealed event; the phone answers it with its peer-info claim.
        deliver([(pub, .control(.threadList(ThreadListData(threads: [main], peerInfoSupported: true))))])
    }

    /// When the relay replaces a stale socket of ours it tells no phone we were gone, so a phone can
    /// still be `.paired` with live updates lost (or, after a restart, unserved) and never say hello
    /// again. The step-1 list once more restarts its exchange, and its next `.paired` catches up from
    /// before the gap. Sealed without peer info, the only list that restarts a ready `RelayClient`;
    /// a phone already served stays served, so the frames the relay replays now still land.
    private func rehandshake() {
        let served = peers.mapValues(\.compatibility)
        for pub in peers.keys { peers[pub]?.compatibility = nil }
        deliver(peers.keys.map { ($0, .control(.threadList(ThreadListData(threads: [main], peerInfoSupported: true)))) })
        for (pub, compatibility) in served { peers[pub]?.compatibility = compatibility }
    }

    private func received(_ event: YorozuEvent, from pub: String) {
        switch event.payload {
        case .threadList(let list) where list.peerInfo != nil || list.peerInfoSupported != nil || list.peerInfoError != nil || list.peerInfoReplyTo != nil:
            let valid = (1...128).contains(event.id.utf8.count) && list.peerInfoError == nil && list.peerInfoReplyTo == nil
            claim(valid ? list.peerInfo : nil, id: event.id, from: pub)
        case .unknown("thread_list", _):
            // A thread list that did not decode is a malformed claim.
            claim(nil, id: event.id, from: pub)
        default:
            guard case .compatible = peers[pub]?.compatibility else { return }
            // Off this actor's receive path: hellos and claims never queue behind the Engine.
            Task { self.deliver(await self.backend.handle(event).map { (pub, $0) }) }
        }
    }

    /// Step 3 of the handshake: the reply names the claim it answers and carries this host's peer info,
    /// or `peerInfoError` for a phone that must update (and is served nothing else).
    private func claim(_ info: PeerInfoData?, id: String, from pub: String) {
        let result = PeerInfoData.local.compatibility(with: info)
        peers[pub]?.compatibility = result == .legacy ? .updateRequired("Invalid peer information.") : result
        deliver([(pub, .control(.threadList(ThreadListData(threads: [main], peerInfoReplyTo: String(id.prefix(128))))))])
    }

    /// Seals each event for its phone and sends them as `frame` batches of at most 16 frames and about
    /// 900 KB (the relay takes 1 MiB a message). Counters are written before anything leaves.
    private func deliver(_ items: [(String, YorozuEvent)]) {
        guard registered else { return }
        var frames: [Frame] = []
        for (pub, event) in items {
            guard var peer = peers[pub], let frame = try? seal(event, for: &peer) else { continue }
            peers[pub] = peer; frames.append(frame)
        }
        guard !frames.isEmpty, (try? persist()) != nil else { return }
        var batch: [Frame] = [], bytes = 0
        for frame in frames {
            let size = frame.payload.utf8.count + frame.sig.utf8.count + 24
            if !batch.isEmpty && (batch.count == 16 || bytes + size > 900_000) { send(batch); batch = []; bytes = 0 }
            batch.append(frame); bytes += size
        }
        send(batch)
    }

    /// Every thread list a phone gets says this host negotiates, and once it has claimed, answers it.
    private func seal(_ event: YorozuEvent, for peer: inout Peer) throws -> Frame {
        var event = event
        if case .threadList(var list) = event.payload {
            list.peerInfoSupported = true
            switch peer.compatibility {
            case .updateRequired(let reason)?: list.peerInfoError = reason
            case .some: list.peerInfo = hostInfo
            case nil: break
            }
            event.payload = .threadList(list)
        }
        let box = try YorozuCrypto.seal(key: peer.keys.send, plaintext: ChannelEnvelope(seq: peer.record.counter.next(), event: event).encoded())
        let payload = try JSONEncoder().encode(FrameBody(t: "box", n: box.nonce.base64URLEncodedString(), c: box.ciphertext.base64URLEncodedString())).base64URLEncodedString()
        // The relay verifies this over the payload string itself.
        return Frame(payload: payload, sig: try YorozuCrypto.signFrame(priv: identity.signingPrivateKey, data: Data(payload.utf8)).base64URLEncodedString())
    }

    private var hostInfo: PeerInfoData {
        var info = PeerInfoData.local
        info.computerName = SCDynamicStoreCopyComputerName(nil, nil) as String?
        if !info.isValid { info.computerName = nil }
        return info
    }

    /// The relay replaces its known set with this list, so it is always the whole list.
    private func announce() {
        if registered { send(["type": "devices", "devices": peers.values.map(\.record.signingPub)]) }
    }

    private func persist() throws { try RelayDeviceFile.save(peers.values.map(\.record), to: file) }

    private func publish() {
        statusOut.yield(RelayStatus(state: state, link: link, devices: peers.values.map(\.record).sorted { $0.pairedAt < $1.pairedAt }))
    }

    private func send(_ frames: [Frame]) { send(try? JSONEncoder().encode(Batch(frames: frames))) }
    private func send(_ object: [String: Any]) { send(try? JSONSerialization.data(withJSONObject: object)) }
    /// Enqueued in call order; a failed send surfaces as the receive loop ending.
    private func send(_ data: Data?) {
        guard let data else { return }
        socket?.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }
}

extension YorozuEvent {
    /// A Mac -> phone event outside any thread: `threadId` "", `agentId` "main".
    static func control(_ payload: Payload) -> YorozuEvent {
        YorozuEvent(id: UUID().uuidString, threadId: "", ts: Int(Date().timeIntervalSince1970 * 1000), agentId: "main", payload: payload)
    }
}
