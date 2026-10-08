import CryptoKit
import Foundation
import os
import SystemConfiguration
import YorozuWire

/// What the pair sheet shows.
struct RelayStatus: Sendable {
    var state = "Connecting to the relay…"
    /// The pairing link (QR and copy), while the sheet has asked for one and the relay has minted it.
    var link: String?
    var devices: [RelayDeviceStatus] = []
}

/// The Mac half of the v1 relay (packages/runtime/src/serve.ts `connect()`), without legacy boxes, the
/// direct path or notify; the phone half is `RelayClient`. Registers this Mac's room, mints pairing
/// codes, admits a phone only with proof it read one, and exchanges sealed `ChannelEnvelope`s with each
/// paired phone. The wire contract is docs/ios-relay-contract.md.
actor RelayHost {
    /// `FrameBody` and the relay envelope are private in RelayClient.swift; these are the same shapes.
    private struct FrameBody: Codable { var t: String; var pub, spub, proof, n, c: String? }
    private struct Inbound: Decodable { var type: String; var nonce, payload, token: String?; var seq: Int? }
    private struct Frame: Encodable { var payload, sig: String }
    private struct Batch: Encodable { var type = "frame"; var frames: [Frame] }
    /// A paired phone. `compatibility` starts from the result on file (`RelayDevice.served`) and each
    /// claim replaces it; only a `.compatible` phone is served. A `hello` keeps a `.compatible` result
    /// and runs the exchange again, so the boxes the relay replays after a buffered `hello` still land.
    /// `accepted` is the channel seq accepted in memory, for ordering; `record.counter.recv` on file
    /// moves only once a frame has been handled, so a frame lost to a quit is accepted again on replay.
    private struct Peer { var record: RelayDevice; let keys: (send: SymmetricKey, recv: SymmetricKey); var compatibility: PeerCompatibility?; var accepted: Int }
    /// A box from a phone with no result yet, with the relay seq it came with, if replayed.
    private typealias Held = (relay: Int?, channel: Int, event: YorozuEvent)

    nonisolated let status: AsyncStream<RelayStatus>
    private let statusOut: AsyncStream<RelayStatus>.Continuation
    private let backend: any RelayBackend
    private let identity: PhoneIdentity
    private let relayURL: String
    /// base64url sha256 of our Ed25519 key: the relay pins the room to that key.
    private let room: String
    private let file: URL
    private var peers: [String: Peer] = [:]
    /// Phones whose sealed frame opened since this socket registered. The relay reports no presence,
    /// so a phone stays online until this socket drops.
    private var online: Set<String> = []
    private var main = ThreadSummary.main(0)
    private var state = RelayStatus().state
    private var link: String?
    private var pairing = false
    /// Secrets behind the last few codes minted, newest last. Only here and in the QR; never the relay.
    private var secrets: [String] = []
    private var socket: URLSessionWebSocketTask?
    private var registered = false
    /// The first replayed seq on this socket that could not be recorded; the ack is cumulative, so
    /// nothing from it on is acked and the relay brings it again on the next registration.
    private var ackLimit: Int?
    /// Boxes from phones with no peer-info result yet, in arrival order, at most 64 a phone: a
    /// compatible claim passes them to the backend, any other result drops them. Unacked until then.
    private var held: [String: [Held]] = [:]
    /// The newest relay seq seen on this socket: what a release acks up to.
    private var lastRelaySeq: Int?
    /// Counts sockets, so an ack still queued for an old one is never sent on the next.
    private var generation = 0
    /// Phone events reach the backend one at a time in arrival order, off the receive path, and a
    /// replayed frame's ack takes its turn behind them: it leaves only once the Engine has stored or
    /// refused every replayed frame up to it.
    private var tail: Task<Void, Never>?
    private var pongDue = false
    private var retry: Double = 2
    private var loop: Task<Void, Never>?
    /// Events waiting for `pace`, in send order; `paced` marks chunk frames.
    private var outbox: [(pub: String, event: YorozuEvent, paced: Bool)] = []
    private var pacer: Task<Void, Never>?
    /// The token bucket every sealed frame is charged against (`afford`).
    private var credit = (bytes: RelayHost.byteRate, frames: RelayHost.frameRate, at: ContinuousClock.now)
    private static let byteRate = 524_288.0, frameRate = 30.0
    private static let log = Logger(subsystem: "to.yumi.yorozu", category: "relay")

    init(backend: any RelayBackend, relayURL: String, devicesFile: URL) throws {
        identity = try RelayKeys.loadOrCreate()
        self.backend = backend; self.relayURL = relayURL; file = devicesFile
        let (stream, continuation) = AsyncStream<RelayStatus>.makeStream(); status = stream; statusOut = continuation
        room = Data(SHA256.hash(data: identity.signingPublicKey)).base64URLEncodedString()
        // The relay remembers 16 devices a room, and the announce names every one of them.
        for var record in try RelayDeviceFile.load(devicesFile).prefix(16) {
            guard let pub = Data(base64URLEncoded: record.pub),
                  let keys = try? YorozuCrypto.deriveChannelKeys(myPriv: identity.sessionPrivateKey, theirPub: pub, role: .mac) else { continue }
            // A result for another host protocol is dropped; the phone's next claim decides.
            let served = record.served
            if served == nil { record.compatible = nil }
            peers[record.pub] = Peer(record: record, keys: keys, compatibility: served, accepted: record.counter.recv)
        }
    }

    func start() {
        guard loop == nil else { return }
        publish()
        loop = Task { await run() }
    }

    func stop() {
        loop?.cancel(); pacer?.cancel(); socket?.cancel(with: .goingAway, reason: nil); statusOut.finish()
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
        online.remove(pub)
        outbox.removeAll { $0.pub == pub }
        release(pub, serve: false)
        announce()
        if registered { send(["type": "revoke", "pubkey": peer.record.signingPub]) }
        publish()
    }

    /// Names a phone on this Mac; blank goes back to the name the phone sends.
    func rename(_ pub: String, label: String?) {
        guard let before = peers[pub] else { return }
        let label = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        peers[pub]?.record.label = label?.isEmpty == false ? label : nil
        do { try persist() } catch { peers[pub] = before; state = error.localizedDescription }
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
            // Held boxes went unacked and unaccepted, so the relay brings them again on this socket.
            socket = ws; generation += 1; ackLimit = nil; held = [:]; lastRelaySeq = nil; pongDue = false
            ws.resume()
            let heartbeat = Task { await self.heartbeat(ws) }
            do {
                while true { if case .string(let text) = try await ws.receive() { receive(text) } }
            } catch {}
            heartbeat.cancel(); ws.cancel()
            socket = nil; registered = false; online = []
            // Frames are never buffered for a phone: it catches up after it redials.
            outbox = []
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
            // A replayed frame carries the relay's buffer seq, and the ack is cumulative: acked only once
            // handled, after every frame before it. One that can never be handled (not a frame, unknown
            // key, malformed, a replayed channel seq, a phone that must update) is acked too, or it would
            // replay for ever. A held box holds back acks from its seq on until its phone's claim.
            if let seq = message.seq { lastRelaySeq = seq }
            do {
                if let raw = message.payload.flatMap(Data.init(base64URLEncoded:)),
                   let body = try? JSONDecoder().decode(FrameBody.self, from: raw) { try frame(body, relay: message.seq) }
            } catch {
                if let seq = message.seq, ackLimit == nil { ackLimit = seq }
            }
            if let seq = message.seq { queueAck(seq) }
        default:
            break
        }
    }

    /// Behind every phone event already queued, so it leaves only once they are handled.
    private func queueAck(_ seq: Int) {
        let previous = tail, socket = generation
        tail = Task { await previous?.value; self.ack(seq, socket: socket) }
    }

    private func ack(_ seq: Int, socket: Int) {
        let limit = ([ackLimit] + held.values.joined().map(\.relay)).compactMap { $0 }.min()
        if socket == generation, limit.map({ seq < $0 }) ?? true { send(["type": "ack", "seq": seq]) }
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

    /// Throws when the device list could not be written for a `hello`; that holds back the ack.
    private func frame(_ body: FrameBody, relay: Int?) throws {
        if body.t == "hello" { return try hello(body) }
        guard body.t == "box", let nonce = body.n.flatMap(Data.init(base64URLEncoded:)),
              let ciphertext = body.c.flatMap(Data.init(base64URLEncoded:)) else { return }
        // Frames carry no sender: whichever paired key opens one names its device.
        for (pub, peer) in peers {
            guard let plain = try? YorozuCrypto.open(key: peer.keys.recv, nonce: nonce, ciphertext: ciphertext) else { continue }
            // Malformed or replayed: dropped.
            guard let envelope = try? ChannelEnvelope.decode(plain), envelope.seq > peer.accepted else { return }
            // Written with the counter once the frame is handled.
            peers[pub]?.record.lastSeen = Date()
            if online.insert(pub).inserted { publish() }
            // Before its claim, a phone with no result on file is not served yet: its box waits here,
            // unaccepted. Past 64 boxes one is dropped.
            if peer.compatibility == nil, !Self.isClaim(envelope.event) {
                if held[pub, default: []].count < 64 { held[pub, default: []].append((relay, envelope.seq, envelope.event)) }
                return
            }
            peers[pub]?.accepted = envelope.seq
            return received(envelope.event, from: pub, channel: envelope.seq)
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
        // A `.compatible` phone stays served until its next claim says otherwise.
        var served: PeerCompatibility?
        if case .compatible? = known?.compatibility { served = known?.compatibility }
        peers[pub] = Peer(record: record, keys: keys, compatibility: served, accepted: known?.accepted ?? record.counter.recv)
        if known?.record.signingPub != spub {
            do { try persist() } catch { peers[pub] = known; throw error }
            announce()
        }
        // A code is for one phone: the next one gets a fresh code.
        if proved { secrets = []; link = nil; if pairing { send(["type": "mint"]) } }
        publish()
        // Its assembler starts afresh and it catches up from its cursor, so frames still waiting for it are moot.
        outbox.removeAll { $0.pub == pub }
        // The first sealed event; the phone answers it with its peer-info claim.
        restartExchange([pub])
    }

    /// When the relay replaces a stale socket of ours it tells no phone we were gone, so a phone can
    /// still be `.paired` with live updates lost (or, after a restart, unserved) and never say hello
    /// again. The step-1 list once more restarts its exchange, and its next `.paired` catches up from
    /// before the gap.
    private func rehandshake() { restartExchange(Array(peers.keys)) }

    /// Seals the step-1 list without peer info, the only list that restarts a ready `RelayClient`; a
    /// phone already served stays served, so the frames the relay replays meanwhile still land.
    private func restartExchange(_ pubs: [String]) {
        let served = pubs.map { ($0, peers[$0]?.compatibility) }
        for pub in pubs { peers[pub]?.compatibility = nil }
        handshake(pubs.map { ($0, .control(.threadList(ThreadListData(threads: [main], peerInfoSupported: true)))) })
        for (pub, compatibility) in served { peers[pub]?.compatibility = compatibility }
    }

    private static func isClaim(_ event: YorozuEvent) -> Bool {
        switch event.payload {
        case .threadList(let list): list.peerInfo != nil || list.peerInfoSupported != nil || list.peerInfoError != nil || list.peerInfoReplyTo != nil
        // A thread list that did not decode is a malformed claim.
        case .unknown("thread_list", _): true
        default: false
        }
    }

    private func received(_ event: YorozuEvent, from pub: String, channel: Int) {
        var handled: YorozuEvent?
        if Self.isClaim(event) {
            if case .threadList(let list) = event.payload {
                let valid = (1...128).contains(event.id.utf8.count) && list.peerInfoError == nil && list.peerInfoReplyTo == nil
                claim(valid ? list.peerInfo : nil, id: event.id, from: pub)
            } else {
                claim(nil, id: event.id, from: pub)
            }
        } else if case .compatible = peers[pub]?.compatibility {
            handled = event
        }
        // Off this actor's receive path, so hellos and claims never queue behind the Engine. The
        // counter on file moves only after the Engine is done with the frame.
        let previous = tail
        tail = Task {
            await previous?.value
            if case .deviceRemove(let remove)? = handled?.payload {
                // A phone can remove only itself; no reply.
                if remove.pub == pub { self.removeDevice(pub) }
            } else if let handled {
                // A new request supersedes chunk sets still waiting for this phone; it catches up from its cursor.
                if case .syncRequest = handled.payload { self.outbox.removeAll { $0.pub == pub && $0.paced } }
                self.deliver(await self.backend.handle(handled).map { (pub, $0) })
            }
            self.commit(channel, for: pub)
        }
    }

    private func commit(_ channel: Int, for pub: String) {
        guard let recv = peers[pub]?.record.counter.recv, channel > recv else { return }
        peers[pub]?.record.counter.recv = channel
        // A failed write only means a replay of this frame is accepted again; the Engine drops duplicates.
        try? persist()
    }

    /// Ends a phone's wait for its claim: its held boxes take the normal path (`serve`) or are dropped,
    /// and acks go out again up to the newest relay seq once they are through.
    private func release(_ pub: String, serve: Bool) {
        guard let boxes = held.removeValue(forKey: pub) else { return }
        if serve { for box in boxes { received(box.event, from: pub, channel: box.channel) } }
        if let lastRelaySeq { queueAck(lastRelaySeq) }
    }

    /// Step 3 of the handshake: the reply names the claim it answers and carries this host's peer info,
    /// or `peerInfoError` for a phone that must update (and is served nothing else).
    private func claim(_ info: PeerInfoData?, id: String, from pub: String) {
        guard let before = peers[pub] else { return }
        let result = PeerInfoData.local.compatibility(with: info)
        peers[pub]?.compatibility = result == .legacy ? .updateRequired("Invalid peer information.") : result
        // Kept on file with the phone's model name; a phone that sends none keeps the one it had.
        if case .compatible(let version, let capabilities) = result {
            peers[pub]?.record.compatible = .init(version: version, capabilities: capabilities, hostProtocol: PeerInfoData.local.protocolMax)
            if let name = info?.computerName { peers[pub]?.record.name = name }
        } else {
            peers[pub]?.record.compatible = nil
        }
        // A failed write keeps the result for this run only.
        if peers[pub]?.record != before.record {
            do { try persist(); publish() } catch { peers[pub]?.record = before.record }
        }
        handshake([(pub, .control(.threadList(ThreadListData(threads: [main], peerInfoReplyTo: String(id.prefix(128))))))])
        // Boxes held for this claim are served after the reply, or dropped for a phone that must update.
        if case .compatible = result { release(pub, serve: true) } else { release(pub, serve: false) }
    }

    /// Handshake thread lists leave at once, ahead of any frames waiting for the phone, so a long chunk set
    /// never runs out the phone's handshake deadline. Sealing order is still wire order: waiting frames are
    /// sealed only when `pace` sends them. Charged against the bucket, which may go below zero for them.
    private func handshake(_ items: [(String, YorozuEvent)]) {
        guard registered else { return }
        let stamped = items.compactMap { pub, event in peers[pub].map { (pub, stamp(event, for: $0)) } }
        for (_, event) in stamped { _ = afford(event, force: true) }
        transmit(stamped)
    }

    /// Sends each event to its phone: whole when its encoding fits `ChunkData.budget`, else as a chunk set,
    /// and through `pace` whenever the bucket cannot cover it now. A phone with frames still waiting gets
    /// everything after them in order behind them. Thread lists are stamped now, with the phone's handshake
    /// state at this moment.
    private func deliver(_ items: [(String, YorozuEvent)]) {
        guard registered else { return }
        var now: [(String, YorozuEvent)] = []
        for (pub, event) in items {
            guard let peer = peers[pub] else { continue }
            let event = stamp(event, for: peer)
            let parts: [YorozuEvent]
            do { parts = try event.chunked() } catch {
                // The bridge caps records well below this; nothing else gets this large.
                Self.log.error("event \(event.id, privacy: .public) too large to send: \(error.localizedDescription, privacy: .public)")
                continue
            }
            if parts.count == 1 && !outbox.contains(where: { $0.pub == pub }) && afford(event) { now.append((pub, event)) }
            else { outbox += parts.map { (pub, $0, parts.count > 1) } }
        }
        transmit(now)
        if !outbox.isEmpty && pacer == nil { pacer = Task { await pace() } }
    }

    /// Every sealed frame (about 16/9 of the encoded event) is charged once against a bucket of 512 KiB and
    /// 30 frames a second across all phones, since every frame counts against every phone's 2 MiB relay
    /// window. True, and charged, when the bucket covers it (or `force`).
    private func afford(_ event: YorozuEvent, force: Bool = false) -> Bool {
        let now = ContinuousClock.now, elapsed = credit.at.duration(to: now) / .seconds(1)
        credit = (min(Self.byteRate, credit.bytes + elapsed * Self.byteRate), min(Self.frameRate, credit.frames + elapsed * Self.frameRate), now)
        let cost = Self.cost(event)
        guard force || (credit.bytes >= cost && credit.frames >= 1) else { return false }
        credit.bytes -= cost; credit.frames -= 1
        return true
    }

    private static func cost(_ event: YorozuEvent) -> Double { Double((try? JSONEncoder().encode(event).count) ?? ChunkData.budget) * 16 / 9 }

    /// Sends waiting frames in order as the bucket allows.
    private func pace() async {
        while registered, !outbox.isEmpty {
            var batch: [(String, YorozuEvent)] = []
            while let first = outbox.first, afford(first.event) { batch.append((first.pub, first.event)); outbox.removeFirst() }
            transmit(batch)
            guard let first = outbox.first else { break }
            let wait = max(0.01, (Self.cost(first.event) - credit.bytes) / Self.byteRate, (1 - credit.frames) / Self.frameRate)
            try? await Task.sleep(for: .seconds(wait))
        }
        pacer = nil
    }

    /// Seals each event for its phone and sends them as `frame` batches of at most 16 frames and about
    /// 900 KB (the relay takes 1 MiB a message). Counters are written before anything leaves.
    private func transmit(_ items: [(String, YorozuEvent)]) {
        guard registered, !items.isEmpty else { return }
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
    private func stamp(_ event: YorozuEvent, for peer: Peer) -> YorozuEvent {
        guard case .threadList(var list) = event.payload else { return event }
        var event = event
        list.peerInfoSupported = true
        switch peer.compatibility {
        case .updateRequired(let reason)?: list.peerInfoError = reason
        case .some: list.peerInfo = hostInfo
        case nil: break
        }
        event.payload = .threadList(list)
        return event
    }

    private func seal(_ event: YorozuEvent, for peer: inout Peer) throws -> Frame {
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
        let devices = peers.values.map(\.record).sorted { $0.pairedAt < $1.pairedAt }.map {
            RelayDeviceStatus(pub: $0.pub, name: $0.name, label: $0.label, pairedAt: $0.pairedAt, online: online.contains($0.pub), lastSeen: $0.lastSeen)
        }
        statusOut.yield(RelayStatus(state: state, link: link, devices: devices))
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
