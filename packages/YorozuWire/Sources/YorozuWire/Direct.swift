import CryptoKit
import Foundation
import Network

/// The direct path to the plugin's own listener (#532, capability `direct`): a probe proves the host key, then the same
/// signed frames as on the relay. This step dials only the Gateway on this Mac, over loopback.
extension Direct {
    public static let port = 8738
    public enum Close {
        public static let unauthorized = 4101
        public static let replaced = 4102
        public static let tooLarge = 4103
    }

    /// Where the client dials directly: the Gateway on this Mac; nothing on iPhone and iPad yet.
    public static var candidates: [URL] {
        #if os(macOS)
        ["ws://127.0.0.1:\(port)", "ws://[::1]:\(port)"].compactMap { URL(string: $0) }
        #else
        []
        #endif
    }

    public static func newNonce() -> String {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URLEncodedString()
    }

    static func probeText(room: String, nonce: String) -> Data { Data("yorozu-direct|\(room)|\(nonce)".utf8) }

    /// The listener's answer holds only if its key is the room's (the room id is its hash) and it signed this nonce.
    public static func verifyProbe(room: String, nonce: String, pubkey: String, sig: String) -> Bool {
        guard let key = Data(base64URLEncoded: pubkey), key.count == 32, let signature = Data(base64URLEncoded: sig),
              Data(SHA256.hash(data: key)).base64URLEncodedString() == room else { return false }
        return YorozuCrypto.verifyFrame(pub: key, data: probeText(room: room, nonce: nonce), signature: signature)
    }
}

/// One path of a race: a `RelayConnection` to the relay or to a direct candidate.
protocol ConnectionLeg: Actor {
    func updates() -> AsyncStream<RelayConnection.Update>
    /// The leg calls `ready` when it could send its init, and waits for `grant`.
    func gate(_ ready: @escaping @Sendable () -> Void)
    /// Sends the init if the leg is still waiting for it.
    func grant() -> Bool
    func start()
    func stop()
    func registerPush(deviceToken: String)
    @discardableResult func send(_ message: Message) -> Bool
    @discardableResult func send(_ event: WireEvent) -> Bool
}

extension RelayConnection: ConnectionLeg {}

/// Dials the direct candidates and the relay together; the first path whose Noise session opens wins and the others are
/// closed. One leg handshakes at a time: the plugin keeps a device's newest session, so two inits in flight could leave
/// it holding the loser's. A network path change or a lost direct session starts a new race; nothing migrates, and the
/// app resends its unacknowledged outbox on the new session.
public actor RacingConnection {
    typealias Legs = @Sendable (_ pairing: QrPayload, _ relayKnows: Bool) -> (relay: any ConnectionLeg, direct: [any ConnectionLeg])

    private var pairing: QrPayload
    private var relayKnows: Bool
    private let makeLegs: Legs
    private let pathChanges: @Sendable () -> AsyncStream<Void>
    private let pause: Duration

    private var continuation: AsyncStream<RelayConnection.Update>.Continuation?
    private var running = false
    private var state = RelayConnection.State.offline
    private var round = 0
    private var nextID = 0
    private var legs: [Int: any ConnectionLeg] = [:]
    private var relayID: Int?
    private var listeners: [Task<Void, Never>] = []
    private var waiting: [Int] = []
    private var holder: Int?
    private var winner: Int?
    private var paths: Task<Void, Never>?
    private var again: Task<Void, Never>?
    private var pushToken: String?

    public init(pairing: QrPayload, identity: PhoneIdentity, relayKnows: Bool, local: PeerInfo, urlSession: URLSession = .shared) throws {
        let relayURL = try RelayConnection.relayURL(pairing)
        self.init(pairing: pairing, relayKnows: relayKnows, legs: { pairing, relayKnows in
            let relay = RelayConnection(path: .relay, dial: relayURL, pairing: pairing, identity: identity, relayKnows: relayKnows,
                local: local, urlSession: urlSession)
            // Offline pairing is #532 step 5: until the first session opens the device pairs over the relay.
            let direct: [any ConnectionLeg] = pairing.secret == nil ? Direct.candidates.map {
                RelayConnection(path: .direct, dial: $0, pairing: pairing, identity: identity, relayKnows: true, local: local,
                    urlSession: urlSession)
            } : []
            return (relay: relay as any ConnectionLeg, direct: direct)
        }, pathChanges: RacingConnection.networkChanges)
    }

    init(pairing: QrPayload, relayKnows: Bool, legs: @escaping Legs, pathChanges: @escaping @Sendable () -> AsyncStream<Void>,
        pause: Duration = .seconds(1)) {
        self.pairing = pairing
        self.relayKnows = relayKnows
        makeLegs = legs
        self.pathChanges = pathChanges
        self.pause = pause
    }

    public func updates() -> AsyncStream<RelayConnection.Update> {
        let (stream, continuation) = AsyncStream<RelayConnection.Update>.makeStream()
        self.continuation = continuation
        return stream
    }

    public func start() async {
        guard !running else { return }
        running = true
        let changes = pathChanges()
        paths = Task { [weak self] in
            for await _ in changes { await self?.reconnect() }
        }
        await race()
    }

    public func reconnect() async {
        guard running else { return await start() }
        await race()
    }

    public func stop() async {
        running = false
        paths?.cancel()
        paths = nil
        await endRace()
        set(.offline)
    }

    public func registerPush(deviceToken: String) async {
        pushToken = deviceToken
        for leg in legs.values { await leg.registerPush(deviceToken: deviceToken) }
    }

    @discardableResult
    public func send(_ message: Message) async -> Bool {
        guard let winner, let leg = legs[winner] else { return false }
        return await leg.send(message)
    }

    @discardableResult
    public func send(_ event: WireEvent) async -> Bool {
        guard let winner, let leg = legs[winner] else { return false }
        return await leg.send(event)
    }

    private func endRace() async {
        round += 1
        again?.cancel()
        again = nil
        for listener in listeners { listener.cancel() }
        listeners = []
        let old = legs
        legs = [:]
        relayID = nil
        waiting = []
        holder = nil
        winner = nil
        for leg in old.values { await leg.stop() }
    }

    private func race() async {
        await endRace()
        guard running else { return }
        let (relay, direct) = makeLegs(pairing, relayKnows)
        add(relay, relay: true)
        for leg in direct { add(leg, relay: false) }
    }

    private func add(_ leg: any ConnectionLeg, relay: Bool) {
        let id = nextID
        nextID += 1
        legs[id] = leg
        if relay { relayID = id }
        let round = round
        let token = pushToken
        listeners.append(Task { [weak self] in
            let updates = await leg.updates()
            await leg.gate { [weak self] in Task { await self?.ready(id, round) } }
            if let token { await leg.registerPush(deviceToken: token) }
            await leg.start()
            for await update in updates {
                guard let self else { return }
                await self.receive(update, from: id, round)
            }
        })
    }

    private func ready(_ id: Int, _ round: Int) async {
        guard round == self.round, legs[id] != nil else { return }
        if holder == nil || holder == id || winner == id {
            await give(id)
        } else if !waiting.contains(id) {
            waiting.append(id)
        }
    }

    private func give(_ id: Int) async {
        holder = id
        guard await legs[id]?.grant() != true else { return }
        if holder == id { holder = nil }
        await next()
    }

    private func next() async {
        while holder == nil, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard let leg = legs[id] else { continue }
            holder = id
            if await leg.grant() { return }
            if holder == id { holder = nil }
        }
    }

    private func receive(_ update: RelayConnection.Update, from id: Int, _ round: Int) async {
        guard round == self.round, legs[id] != nil else { return }
        switch update {
        case .sessionOpen(let peer):
            if winner != id {
                winner = id
                holder = id
                waiting = []
                let losers = legs.filter { $0.key != id }
                for key in losers.keys { legs[key] = nil }
                for leg in losers.values { await leg.stop() }
                guard round == self.round else { return }
                pairing.secret = nil
            }
            set(.ready)
            continuation?.yield(.sessionOpen(peer))
        case .state(let new):
            switch new {
            case .updateRequired, .unpaired, .pairingFailed:
                running = false
                paths?.cancel()
                await endRace()
                return set(new)
            default:
                break
            }
            if id == winner {
                guard id != relayID, new != .ready else { return set(new) }
                // The direct session is gone: race again, after a pause so a socket that keeps closing cannot spin.
                legs[id] = nil
                winner = nil
                holder = nil
                set(.connecting)
                return rerace()
            }
            if id == relayID && winner == nil { set(new) }
            // `.ready` comes just before `.sessionOpen`; the holder keeps its turn through both.
            if new != .handshaking && new != .ready {
                waiting.removeAll { $0 == id }
                if holder == id {
                    holder = nil
                    await next()
                }
            }
            if new == .offline && id != relayID { legs[id] = nil }
        case .accepted, .event:
            if id == winner { continuation?.yield(update) }
        case .relayJoined:
            relayKnows = true
            continuation?.yield(update)
        }
    }

    private func rerace() {
        guard again == nil else { return }
        let pause = pause
        let round = round
        again = Task { [weak self] in
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            await self?.rerace(round)
        }
    }

    private func rerace(_ round: Int) async {
        guard round == self.round, running else { return }
        await race()
    }

    private func set(_ new: RelayConnection.State) {
        guard new != state else { return }
        state = new
        continuation?.yield(.state(new))
    }

    /// Each change of the network path the system reports, after the first.
    static let networkChanges: @Sendable () -> AsyncStream<Void> = {
        AsyncStream { continuation in
            let watch = Task {
                var last: String?
                for await path in NWPathMonitor() {
                    let now = "\(path.status) \(path.availableInterfaces.map(\.name))"
                    if let last, last != now { continuation.yield() }
                    last = now
                }
            }
            continuation.onTermination = { _ in watch.cancel() }
        }
    }
}
