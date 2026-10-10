import AppKit
import CryptoKit
import Foundation
import Network
import os
import ProjectXCore
import SystemConfiguration
import YorozuWire

/// What the pair sheet and Settings › Connection show.
struct RelayStatus: Sendable {
    var state = String(localized: "Connecting to the relay…")
    /// The pairing link (QR and copy), while the sheet has asked for one and the relay has minted it.
    var link: String?
    /// The key of the client device that paired while the sheet showed, so the sheet can say so.
    var justPaired: String?
    var devices: [RelayDeviceStatus] = []
    var direct = DirectStatus()
}

/// The direct listener as Settings › Connection shows it.
struct DirectStatus: Sendable, Equatable {
    enum Listener: Sendable, Equatable { case off, starting, listening, failed(String) }
    var listener = Listener.off
    var port = DirectMessage.defaultPort
    /// What `hostInfo` advertises while listening, LAN first.
    var candidates: [Address] = []
    /// The last connection refused before it named a paired phone (unpaired key, wrong interface, no join).
    var lastRefusal: String?
    struct Address: Sendable, Equatable, Hashable { var host: String; var kind: DirectKind }
}

/// The Mac half of the v1 relay (packages/runtime/src/serve.ts `connect()`), without legacy boxes or
/// sealed previews; the phone half is `RelayClient`. Registers this Mac's room, mints pairing codes, admits a phone
/// only with proof it read one, and exchanges sealed `ChannelEnvelope`s with each paired phone. The wire
/// contract is docs/ios-relay-contract.md. Paired phones may also reach it directly (#315): a WebSocket
/// listener on Wi-Fi/Ethernet and `utun` interfaces carries the same signed frames once the phone's join
/// proves its paired key, and each phone's route follows its latest authenticated `hello`. `notify` wakes
/// paired phones through the relay's APNs path (#320) with a class, two opaque refs and, for phones that take
/// `push-preview-v1`, the message's excerpt sealed for each phone (`PushPreview`); never content in the clear.
actor RelayHost {
    /// `FrameBody` and the relay envelope are private in RelayClient.swift; these are the same shapes.
    private struct FrameBody: Codable { var t: String; var pub, spub, proof, n, c: String? }
    private struct Inbound: Decodable { var type: String; var nonce, payload, token, state: String?; var seq: Int? }
    /// When this Mac was last registered at the relay and when it last sent a back-online notify (#320).
    private struct Online: Codable { var seen: Date; var notified: Date? }
    private struct Frame: Codable { var payload, sig: String }
    private struct Batch: Encodable { var type = "frame"; var frames: [Frame] }
    /// Where a phone's frames go: the path of its latest authenticated `hello`.
    private enum Route: Equatable { case relay, direct(Int) }
    /// A paired phone. `compatibility` starts from the result on file (`RelayDevice.served`) and each
    /// claim replaces it; only a `.compatible` phone is served. A `hello` keeps a `.compatible` result
    /// and runs the exchange again, so the boxes the relay replays after a buffered `hello` still land.
    /// `accepted` is the channel seq accepted in memory, for ordering; `record.counter.recv` on file
    /// moves only once a frame has been handled, so a frame lost to a quit is accepted again on replay.
    private struct Peer { var record: RelayDevice; let keys: (send: SymmetricKey, recv: SymmetricKey); var compatibility: PeerCompatibility?; var accepted: Int; var route = Route.relay }
    /// A direct WebSocket. `kind` is known once it is ready, `nonce` (ours, in `joined`) once its probe named
    /// this room, `signer` (the phone's paired Ed25519 key) once its join verified; `heard` is when its last
    /// message arrived, `helloAt` when its last `hello` did.
    private struct Link {
        let connection: NWConnection; var kind: DirectKind?; var nonce = ""; var signer: String?
        var heard = ContinuousClock.now; var helloAt: ContinuousClock.Instant?
    }
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
    /// The Mac's readiness (#317): sent to each phone that takes `readiness-v1` after its claim, and on every change.
    private var readiness: ReadinessData?
    /// The job list (#319): sent to each phone that takes `jobs-v1` after its claim, and on every change.
    private var jobs: JobListData?
    private var state = RelayStatus().state
    private var link: String?
    private var justPaired: String?
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

    // Push (#320).
    /// `[notifications]` on with destination `phones`.
    private var alerts: Bool
    private typealias Notify = (at: Date, cls: String, data: Data)
    /// Notifies waiting for a registration, newest last: at most 20, sent only within 24 h.
    private var heldNotifies: [Notify] = []
    /// Notifies sent since the last `pong`: a socket half-open after sleep may have lost them, so the next
    /// registration sends them again.
    private var unponged: [Notify] = []
    /// `relay-online.json` beside the device file.
    private let onlineFile: URL
    private var lastOnline: Online?

    // Direct path (#315).
    private var direct: Config.Direct
    private var listener: NWListener?
    /// Counts listeners, so callbacks from a cancelled one are ignored.
    private var listenerGeneration = 0
    private var listenerState = DirectStatus.Listener.off
    private var listenerRetry: Double = 2
    private var listenerRestart: Task<Void, Never>?
    private var links: [Int: Link] = [:]
    private var nextLink = 0
    private var lastRefusal: String?
    /// The last direct problem per phone (X25519 key), for diagnostics.
    private var directErrors: [String: String] = [:]
    private var sweeper: Task<Void, Never>?
    private var sleepWatch: Task<Void, Never>?
    /// Between `willSleep` and `didWake`: every new direct connection is closed with 4000.
    private var asleep = false
    private var pathMonitor: NWPathMonitor?
    /// Keeps App Nap off while the host runs; idle sleep is still allowed (Keep Mac awake is separate).
    private var activity: (any NSObjectProtocol)?
    private static let queue = DispatchQueue(label: "to.yumi.yorozu.direct")
    /// Connections that have not joined yet, at most; more are cancelled on arrival.
    private static let maxPending = 8, maxLinks = 24

    init(backend: any RelayBackend, relayURL: String, devicesFile: URL, direct: Config.Direct, alerts: Bool) throws {
        identity = try RelayKeys.loadOrCreate()
        self.backend = backend; self.relayURL = relayURL; file = devicesFile; self.direct = direct; self.alerts = alerts
        onlineFile = devicesFile.deletingLastPathComponent().appendingPathComponent("relay-online.json")
        lastOnline = try? JSONDecoder().decode(Online.self, from: Data(contentsOf: onlineFile))
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
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Yorozu serves client devices")
        publish()
        loop = Task { await run() }
        restartListener()
        sweeper = Task { [weak self] in
            while !Task.isCancelled { try? await Task.sleep(for: .seconds(5)); await self?.sweep() }
        }
        sleepWatch = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.willSleepNotification) { await self?.sleeping(true) }
                }
                group.addTask {
                    for await _ in NSWorkspace.shared.notificationCenter.notifications(named: NSWorkspace.didWakeNotification) { await self?.sleeping(false) }
                }
            }
        }
        // Advertised addresses follow the network.
        let monitor = NWPathMonitor(); pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in Task { await self?.publish() } }
        monitor.start(queue: Self.queue)
    }

    func stop() {
        if registered { markOnline() }
        loop?.cancel(); pacer?.cancel(); socket?.cancel(with: .goingAway, reason: nil)
        sweeper?.cancel(); sleepWatch?.cancel(); pathMonitor?.cancel(); listenerRestart?.cancel()
        listenerGeneration += 1; listener?.cancel(); listener = nil
        for id in links.keys { drop(id, nil) }
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        statusOut.finish()
    }

    /// `[direct]` changed: the listener restarts on the new port, or stops, closing its links.
    func setDirect(_ direct: Config.Direct) {
        guard direct != self.direct else { return }
        self.direct = direct
        guard loop != nil else { return }
        for id in links.keys { drop(id, nil) }
        restartListener()
    }

    /// `[notifications]` changed: off drops the held notifies.
    func setAlerts(_ on: Bool) { alerts = on; if !on { heldNotifies = []; unponged = [] } }

    /// Wakes paired phones through the relay (#320) with `type`, `class`, `threadRef`, `eventRef` and, when `excerpt` is not
    /// empty, `previews`: the excerpt sealed once per served phone that takes `push-preview-v1`, keyed by its Ed25519 key. The
    /// relay drops this socket on a class other than `reply`, `failed`, `approval` or `done`, or a malformed preview. Held
    /// while unregistered.
    func notify(_ alert: Message.Alert, threadID: String, eventID: String, excerpt: String) {
        let cls = switch alert { case .result: "reply"; case .failure: "failed"; case .question: "approval" }
        notify(cls, threadID: threadID, eventID: eventID, excerpt: excerpt)
    }

    private func notify(_ cls: String, threadID: String, eventID: String, excerpt: String = "") {
        guard alerts, !peers.isEmpty else { return }
        let eventRef = YorozuCrypto.threadRef(eventID)
        var body: [String: Any] = ["type": "notify", "class": cls, "threadRef": YorozuCrypto.threadRef(threadID), "eventRef": eventRef]
        let preview = PushPreview(cls: cls, event: eventRef, body: excerpt)
        let previews = excerpt.isEmpty ? [:] : peers.reduce(into: [String: [String: String]]()) { out, entry in
            let (pub, peer) = entry
            guard takes(PushPreview.capability, pub), peer.record.signingPub.count == 43, let raw = Data(base64URLEncoded: pub),
                  let key = try? PushPreview.key(myPriv: identity.sessionPrivateKey, theirPub: raw),
                  let box = preview.seal(key: key) else { return }
            out[peer.record.signingPub] = ["n": box.n, "c": box.c]
        }
        if !previews.isEmpty { body["previews"] = previews }
        guard let data = try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys) else { return }
        let held: Notify = (Date(), cls, data)
        if registered { sendNotify(held) } else { heldNotifies = Array((heldNotifies + [held]).suffix(20)) }
    }

    /// The JSON holds the class, two 8-character refs and sealed boxes the relay cannot open, so it is logged whole.
    private func sendNotify(_ held: Notify) {
        Self.log.debug("notify \(String(decoding: held.data, as: UTF8.self), privacy: .public)")
        unponged.append(held)
        send(held.data)
    }

    /// On each registration, after `announce`: the held and unponged notifies from the last 24 h (latest 20), only the newest
    /// of each class, and `done` (Mac back online) when no registration was seen for 10 minutes, the app's own downtime
    /// included, and none went out in the last hour.
    private func registeredAlerts() {
        let now = Date()
        var classes = Set<String>()
        let due = (unponged + heldNotifies).suffix(20).filter { now.timeIntervalSince($0.at) < 86_400 }.reversed().filter { classes.insert($0.cls).inserted }
        unponged = []; heldNotifies = []
        if alerts, !peers.isEmpty { for held in due.reversed() { sendNotify(held) } }
        if let last = lastOnline, now.timeIntervalSince(last.seen) >= 600, last.notified.map({ now.timeIntervalSince($0) >= 3600 }) ?? true, alerts, !peers.isEmpty {
            notify("done", threadID: main.id, eventID: UUID().uuidString)
            lastOnline?.notified = now
        }
        markOnline()
    }

    /// Written on each registration, pong and stop while registered, so a quit or a short drop stays below the threshold.
    private func markOnline() {
        lastOnline = Online(seen: Date(), notified: lastOnline?.notified)
        try? JSONEncoder().encode(lastOnline).write(to: onlineFile, options: .atomic)
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

    /// A new readiness goes to every served phone that takes it now; each handshake sends the latest again.
    func publishReadiness(_ readiness: ReadinessData) {
        guard readiness != self.readiness else { return }
        self.readiness = readiness
        deliver(peers.keys.filter { takes(ReadinessData.capability, $0) }.map { ($0, .control(.readiness(readiness))) })
    }

    /// A changed job list goes to every served phone that takes it now; each handshake sends the latest again.
    func publishJobs(_ jobs: JobListData) {
        guard jobs != self.jobs else { return }
        self.jobs = jobs
        deliver(peers.keys.filter { takes(JobListData.capability, $0) }.map { ($0, .control(.jobList(jobs))) })
    }

    private func takes(_ capability: String, _ pub: String) -> Bool {
        if case .compatible(_, let capabilities)? = peers[pub]?.compatibility { capabilities.contains(capability) } else { false }
    }

    /// Job-only messages (#319) reach only phones that take `jobs-v1`; any other phone would show them in its main chat.
    private func strip(_ event: YorozuEvent, for pub: String) -> YorozuEvent {
        guard case .syncDelta(var delta) = event.payload, !takes(JobListData.capability, pub) else { return event }
        delta.events.removeAll { if case .message(let m) = $0.payload { Message.jobOnlyKinds.contains(m.kind ?? "") } else { false } }
        var event = event
        event.payload = .syncDelta(delta)
        return event
    }

    /// A fresh one-time code for the pair sheet. Minted again after each phone pairs, until `endPairing`.
    func mintPairing() {
        pairing = true; link = nil; justPaired = nil; publish()
        if registered { send(["type": "mint"]) }
    }

    /// The sheet closed: no more codes. Secrets already minted stay until a phone pairs, so a phone
    /// that scanned just before the sheet closed still gets in.
    func endPairing() { pairing = false; link = nil; justPaired = nil; publish() }

    /// Forgets a phone here and at the relay: it has to pair again.
    func removeDevice(_ pub: String) {
        guard let peer = peers.removeValue(forKey: pub) else { return }
        do { try persist() } catch { peers[pub] = peer; state = error.localizedDescription; return publish() }
        online.remove(pub); directErrors[pub] = nil
        for (id, link) in links where link.signer == peer.record.signingPub { drop(id, .unauthorized) }
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
        guard var dial = URLComponents(string: relayURL) else { state = String(localized: "Bad relay URL: \(relayURL)"); return publish() }
        // The relay routes on the room before it reads anything, so it goes in the URL too.
        dial.queryItems = (dial.queryItems ?? []) + [URLQueryItem(name: "room", value: room)]
        guard let url = dial.url else { state = String(localized: "Bad relay URL: \(relayURL)"); return publish() }
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
            // Phones on a direct route stay online.
            socket = nil; registered = false; online = online.filter { peers[$0]?.route != .relay }
            // Frames are never buffered for a phone: it catches up after it redials.
            outbox = []
            state = String(localized: "Relay offline, retrying…"); publish()
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
            registeredAlerts()
            if pairing { send(["type": "mint"]) }
            rehandshake()
            state = String(localized: "Connected"); publish()
        case "token":
            guard pairing, let token = message.token else { return }
            newCode(token)
        case "pong":
            pongDue = false; unponged = []
            if registered { markOnline() }
        case "state":
            // `notify rate limit` (60 a minute): that wake-up is lost, the frames are not.
            Self.log.notice("relay state: \(message.state ?? "", privacy: .public)")
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

    /// Throws when the device list could not be written for a `hello`; that holds back the ack. `from` is the
    /// phone a direct link already proved, so its box is opened with that phone's key alone.
    private func frame(_ body: FrameBody, relay: Int?, from: String? = nil) throws {
        if body.t == "hello" {
            if let pub = body.pub, case .direct(let id)? = peers[pub]?.route {
                // A hello the relay buffered while this Mac was away is older than a live direct link: it leaves the route alone.
                if relay != nil { return }
                // So is a live relay hello overtaken by the direct link's own (make-before-break): one within
                // 2 s of the direct hello, from a link still heard since, would otherwise supersede it.
                if let link = links[id], let at = link.helloAt, at.duration(to: .now) < .seconds(2), link.heard >= at { return }
            }
            return try hello(body, route: .relay)
        }
        guard body.t == "box", let nonce = body.n.flatMap(Data.init(base64URLEncoded:)),
              let ciphertext = body.c.flatMap(Data.init(base64URLEncoded:)) else { return }
        // Frames carry no sender: whichever paired key opens one names its device.
        for (pub, peer) in peers where from == nil || pub == from {
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

    /// `route` is the path it came on; a hello on another path than the phone's route moves the route and
    /// closes the direct link it leaves.
    private func hello(_ body: FrameBody, route: Route) throws {
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
        if case .direct(let old)? = known?.route, known?.route != route { drop(old, .superseded) }
        peers[pub] = Peer(record: record, keys: keys, compatibility: served, accepted: known?.accepted ?? record.counter.recv, route: route)
        if known?.record.signingPub != spub {
            do { try persist() } catch {
                peers[pub] = known
                if case .direct(let id)? = known?.route, links[id] == nil { peers[pub]?.route = .relay }
                throw error
            }
            announce()
        }
        // A code is for one phone: the next one gets a fresh code.
        if proved { secrets = []; link = nil; if pairing { justPaired = pub; send(["type": "mint"]) } }
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
    private func rehandshake() { restartExchange(peers.filter { $0.value.route == .relay }.map(\.key)) }

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
                self.deliver(await self.backend.handle(handled, from: pub).map { (pub, $0) })
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
        peers[pub]?.compatibility = result == .legacy ? .updateRequired(String(localized: "Invalid peer information.")) : result
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
        if let readiness, takes(ReadinessData.capability, pub) { deliver([(pub, .control(.readiness(readiness)))]) }
        if let jobs, takes(JobListData.capability, pub) { deliver([(pub, .control(.jobList(jobs)))]) }
    }

    /// Handshake thread lists leave at once, ahead of any frames waiting for the phone, so a long chunk set
    /// never runs out the phone's handshake deadline. Sealing order is still wire order: waiting frames are
    /// sealed only when `pace` sends them. Charged against the bucket, which may go below zero for them.
    private func handshake(_ items: [(String, YorozuEvent)]) {
        let stamped = items.compactMap { pub, event in peers[pub].flatMap { reachable($0) ? (pub, stamp(event, for: $0)) : nil } }
        for (pub, event) in stamped where peers[pub]?.route == .relay { _ = afford(event, force: true) }
        transmit(stamped)
    }

    /// Sends each event to its phone: whole when its encoding fits `ChunkData.budget`, else as a chunk set,
    /// and through `pace` whenever the bucket cannot cover it now. A phone with frames still waiting gets
    /// everything after them in order behind them. Thread lists are stamped now, with the phone's handshake
    /// state at this moment. A phone on a direct route gets its frames on its link at once, whatever the relay's
    /// state; one on the relay route only while this Mac is registered there.
    private func deliver(_ items: [(String, YorozuEvent)]) {
        var now: [(String, YorozuEvent)] = []
        for (pub, event) in items {
            guard let peer = peers[pub], reachable(peer) else { continue }
            // A phone keeps at most two download requests in flight; past two chunks already waiting for it, one is
            // dropped and its request times out and comes again, so downloads never pile up behind the bucket.
            if case .attachmentDownloadChunk = event.payload,
               outbox.lazy.filter({ if $0.pub == pub, case .attachmentDownloadChunk = $0.event.payload { true } else { false } }).count >= 2 { continue }
            let event = stamp(strip(event, for: pub), for: peer)
            let parts: [YorozuEvent]
            do { parts = try event.chunked() } catch {
                // The bridge caps records well below this; nothing else gets this large.
                Self.log.error("event \(event.id, privacy: .public) too large to send: \(error.localizedDescription, privacy: .public)")
                continue
            }
            if peer.route != .relay { now += parts.map { (pub, $0) }; continue }
            if parts.count == 1 && !outbox.contains(where: { $0.pub == pub }) && afford(event) { now.append((pub, event)) }
            else { outbox += parts.map { (pub, $0, parts.count > 1) } }
        }
        transmit(now)
        if registered, !outbox.isEmpty, pacer == nil { pacer = Task { await pace() } }
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
    /// 900 KB (the relay takes 1 MiB a message), or one frame a message on a direct link. Counters are written
    /// before anything leaves.
    private func transmit(_ items: [(String, YorozuEvent)]) {
        var frames: [Frame] = [], direct: [(NWConnection, Frame)] = []
        for (pub, event) in items {
            guard var peer = peers[pub], reachable(peer) else { continue }
            var link: NWConnection?
            if case .direct(let id) = peer.route { link = links[id]?.connection }
            guard let frame = try? seal(event, for: &peer) else { continue }
            peers[pub] = peer
            if let link { direct.append((link, frame)) } else { frames.append(frame) }
        }
        guard !(frames.isEmpty && direct.isEmpty), (try? persist()) != nil else { return }
        for (link, frame) in direct { if let text = try? DirectMessage.frame(payload: frame.payload, sig: frame.sig).text() { link.sendText(Data(text.utf8)) } }
        guard !frames.isEmpty else { return }
        var batch: [Frame] = [], bytes = 0
        for frame in frames {
            let size = frame.payload.utf8.count + frame.sig.utf8.count + 24
            if !batch.isEmpty && (batch.count == 16 || bytes + size > 900_000) { send(batch); batch = []; bytes = 0 }
            batch.append(frame); bytes += size
        }
        send(batch)
    }

    /// A direct route always has its link (`drop` moves the route back); the relay route needs a registration.
    private func reachable(_ peer: Peer) -> Bool { peer.route != .relay || registered }

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
        // `direct-v1` and the candidates only with `[direct] enabled`; none while the listener is not up (#315).
        if direct.enabled {
            let candidates = advertised.map(\.candidate)
            if !candidates.isEmpty { info.directCandidates = candidates }
            if !info.isValid { info.directCandidates = nil }
        } else {
            info.capabilities.removeAll { $0 == DirectCandidate.capability }
        }
        return info
    }

    /// The addresses a phone may dial, only while the listener is up.
    private var advertised: [(candidate: DirectCandidate, kind: DirectKind)] {
        listenerState == .listening ? DirectInterfaces.candidates(port: direct.port) : []
    }

    /// The relay replaces its known set with this list, so it is always the whole list.
    private func announce() {
        if registered { send(["type": "devices", "devices": peers.values.map(\.record.signingPub)]) }
    }

    private func persist() throws { try RelayDeviceFile.save(peers.values.map(\.record), to: file) }

    private func publish() {
        let devices = peers.values.sorted { $0.record.pairedAt < $1.record.pairedAt }.map { peer in
            let r = peer.record
            var route: DirectKind?
            if case .direct(let id) = peer.route { route = links[id]?.kind }
            return RelayDeviceStatus(pub: r.pub, name: r.name, label: r.label, pairedAt: r.pairedAt, online: online.contains(r.pub), lastSeen: r.lastSeen,
                                     route: route, directError: directErrors[r.pub])
        }
        let direct = DirectStatus(listener: listenerState, port: self.direct.port,
                                  candidates: advertised.map { .init(host: $0.candidate.host, kind: $0.kind) }, lastRefusal: lastRefusal)
        statusOut.yield(RelayStatus(state: state, link: link, justPaired: justPaired, devices: devices, direct: direct))
    }

    // MARK: Direct path (#315)

    /// A fresh listener on `[direct] port`, or none while `[direct] enabled` is false. A failed one is
    /// started again after 2 s, doubling to 60 s.
    private func restartListener() {
        listenerRestart?.cancel(); listenerRestart = nil
        listenerGeneration += 1; listener?.cancel(); listener = nil
        guard direct.enabled else { listenerState = .off; return publish() }
        let generation = listenerGeneration
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true; ws.maximumMessageSize = DirectMessage.maxBytes
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        parameters.prohibitedInterfaceTypes = [.loopback]
        parameters.allowLocalEndpointReuse = true
        do {
            guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: direct.port)) else { throw ProjectError.invalid("Invalid port \(direct.port).") }
            let listener = try NWListener(using: parameters, on: port)
            listener.stateUpdateHandler = { [weak self] state in Task { await self?.listenerChanged(state, generation: generation) } }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return connection.cancel() }
                Task { await self.accept(connection, generation: generation) }
            }
            self.listener = listener; listenerState = .starting
            listener.start(queue: Self.queue)
        } catch {
            listenerFailed(error.localizedDescription)
        }
        publish()
    }

    private func listenerChanged(_ state: NWListener.State, generation: Int) {
        guard generation == listenerGeneration else { return }
        switch state {
        case .ready: listenerState = .listening; listenerRetry = 2; publish()
        case .waiting(let error): listenerState = .failed(error.localizedDescription); publish()
        case .failed(let error): listener?.cancel(); listener = nil; listenerFailed(error.localizedDescription); publish()
        default: break
        }
    }

    private func listenerFailed(_ reason: String) {
        listenerState = .failed(reason)
        let wait = listenerRetry; listenerRetry = min(listenerRetry * 2, 60)
        Self.log.error("direct listener failed: \(reason, privacy: .public); retrying in \(wait) s")
        listenerRestart = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            if !Task.isCancelled { await self?.restartListener() }
        }
    }

    /// At most `maxPending` connections wait for a join, each for 10 s from here.
    private func accept(_ connection: NWConnection, generation: Int) {
        guard generation == listenerGeneration, direct.enabled, links.count < Self.maxLinks,
              links.values.filter({ $0.signer == nil }).count < Self.maxPending else { return connection.cancel() }
        let id = nextLink; nextLink += 1
        links[id] = Link(connection: connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: Task { await self?.ready(id) }
            case .failed(let error): Task { await self?.drop(id, nil, error: error.localizedDescription) }
            case .waiting, .cancelled: Task { await self?.drop(id, nil) }
            default: break
            }
        }
        connection.start(queue: Self.queue)
        Task {
            try? await Task.sleep(for: .seconds(10))
            if links[id] != nil, links[id]?.signer == nil { refuse(id, String(localized: "A connection sent no valid join within 10 seconds.")) }
        }
    }

    /// Only private addresses on Wi-Fi/Ethernet and `utun` interfaces: anything else (loopback, public, AWDL,
    /// bridges) is closed unheard. Asleep, every connection is closed with 4000. The phone speaks first.
    private func ready(_ id: Int) {
        guard let connection = links[id]?.connection else { return }
        if asleep { return drop(id, .sleeping) }
        let path = connection.currentPath
        guard let kind = DirectInterfaces.kind(local: path?.localEndpoint, interface: path?.availableInterfaces.first?.type) else {
            return refuse(id, String(localized: "Refused a connection on an interface other than Wi-Fi, Ethernet or VPN."))
        }
        links[id]?.kind = kind; links[id]?.heard = .now
        Task { await read(id) }
    }

    /// One message at a time, in order, until the link closes.
    private func read(_ id: Int) async {
        while let connection = links[id]?.connection {
            guard let data = try? await connection.receiveText() else { break }
            guard links[id] != nil else { return }
            guard data.count <= DirectMessage.maxBytes else { return drop(id, .tooLarge, error: String(localized: "A message was larger than 1 MiB.")) }
            links[id]?.heard = .now
            message(data, on: id)
        }
        drop(id, nil)
    }

    private func message(_ data: Data, on id: Int) {
        guard let link = links[id] else { return }
        guard let message = try? JSONDecoder().decode(DirectMessage.self, from: data) else {
            return link.signer == nil ? refuse(id, String(localized: "A connection sent something other than a probe and a join.")) : drop(id, .unauthorized, error: String(localized: "The client device sent a malformed message."))
        }
        guard let signer = link.signer else {
            switch message {
            case .probe(let room, let nonce) where link.nonce.isEmpty: return probe(room: room, phoneNonce: nonce, on: id)
            case .join(let room, let pub, let sig) where !link.nonce.isEmpty: return join(room: room, pub: pub, sig: sig, on: id)
            default: return refuse(id, String(localized: "A connection sent something other than a probe and a join."))
            }
        }
        switch message {
        case .ping(let t): sendDirect(.pong(t: t), on: id)
        case .frame(let payload, let sig):
            guard let sig = Data(base64URLEncoded: sig), let key = Data(base64URLEncoded: signer),
                  YorozuCrypto.verifyFrame(pub: key, data: Data(payload.utf8), signature: sig),
                  let raw = Data(base64URLEncoded: payload), let body = try? JSONDecoder().decode(FrameBody.self, from: raw) else {
                return drop(id, .unauthorized, error: String(localized: "A frame's signature did not verify."))
            }
            directFrame(body, signer: signer, on: id)
        case .probe, .join, .joined, .pong: break
        }
    }

    /// The phone's probe names this room and a nonce: the Mac proves its key first, over that nonce, and sends
    /// a nonce of its own for the join. A probe for another room is closed unanswered.
    private func probe(room probeRoom: String, phoneNonce: String, on id: Int) {
        guard probeRoom == room, Data(base64URLEncoded: phoneNonce)?.count == 32 else {
            return refuse(id, String(localized: "Refused a probe for another Mac."))
        }
        guard let proof = try? DirectProof.signJoined(priv: identity.signingPrivateKey, room: room, phoneNonce: phoneNonce) else { return drop(id, nil) }
        let nonce = DirectProof.newNonce()
        links[id]?.nonce = nonce
        sendDirect(.joined(pub: identity.signingPublicKey.base64URLEncodedString(), sig: proof.base64URLEncodedString(), nonce: nonce), on: id)
    }

    /// The phone proves it holds a paired Ed25519 key, signing this room and our `joined` nonce. Unknown keys
    /// are refused: a phone pairs over the relay only.
    private func join(room joinRoom: String, pub signer: String, sig: String, on id: Int) {
        guard let nonce = links[id]?.nonce, joinRoom == room, let sig = Data(base64URLEncoded: sig) else {
            return refuse(id, String(localized: "Refused a malformed join."))
        }
        guard let pub = peers.first(where: { $0.value.record.signingPub == signer })?.key, let key = Data(base64URLEncoded: signer) else {
            return refuse(id, String(localized: "Refused a key that is not paired with this host."))
        }
        guard DirectProof.verifyJoin(pub: key, room: room, macNonce: nonce, signature: sig) else {
            directErrors[pub] = String(localized: "Its join signature did not verify.")
            return drop(id, .unauthorized)
        }
        links[id]?.signer = signer
        publish()
    }

    /// The peer is the one the join proved, never a trial decryption. Its `hello` must name that same key.
    private func directFrame(_ body: FrameBody, signer: String, on id: Int) {
        guard let pub = peers.first(where: { $0.value.record.signingPub == signer })?.key else { return drop(id, .unauthorized) }
        if body.t == "hello" {
            guard body.spub == signer, body.pub == pub else {
                return drop(id, .unauthorized, error: String(localized: "Its hello named another key than its join."))
            }
            links[id]?.helloAt = .now
            // The key is already on file, so nothing is written and nothing throws.
            try? hello(body, route: .direct(id))
            return
        }
        // Never acked to the relay; a replayed seq is dropped like any other.
        try? frame(body, relay: nil, from: pub)
    }

    /// Joined links silent for more than 30 s are dropped (the phone pings every 10 s).
    private func sweep() {
        let now = ContinuousClock.now
        for (id, link) in links where link.signer != nil && link.heard.duration(to: now) > .seconds(30) {
            drop(id, nil, error: String(localized: "Its direct link went silent for more than 30 seconds."))
        }
    }

    /// The Mac is going to sleep: phones move to the relay, which keeps their messages until it wakes, and new
    /// connections are closed with 4000 until `didWake`.
    private func sleeping(_ asleep: Bool) {
        self.asleep = asleep
        guard asleep else { return }
        for id in links.keys { drop(id, .sleeping, error: String(localized: "The host went to sleep.")) }
    }

    /// Closes a connection that never named a paired phone.
    private func refuse(_ id: Int, _ reason: String) {
        lastRefusal = reason
        Self.log.info("direct: \(reason, privacy: .public)")
        drop(id, .unauthorized)
    }

    /// Closes a link (with `code`, else at once). A phone routed over it goes back to the relay route;
    /// `error` becomes its last direct error.
    private func drop(_ id: Int, _ code: DirectCloseCode?, error: String? = nil) {
        guard let link = links.removeValue(forKey: id) else { return }
        if let code { link.connection.close(code) } else { link.connection.cancel() }
        for (pub, peer) in peers where peer.route == .direct(id) { peers[pub]?.route = .relay; online.remove(pub) }
        if let error, let signer = link.signer, let pub = peers.first(where: { $0.value.record.signingPub == signer })?.key { directErrors[pub] = error }
        publish()
    }

    private func sendDirect(_ message: DirectMessage, on id: Int) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        links[id]?.connection.sendText(data)
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
