import CryptoKit
import Foundation
import Network

/// The direct path to the plugin's own listener (#532, capability `direct`): a probe proves the host key, then the same
/// signed frames as on the relay. Candidates come from loopback on the Mac, the plugin's `direct_hints` and Bonjour.
extension Direct {
    public static let port = 8738
    public enum Close {
        public static let unauthorized = 4101
        public static let replaced = 4102
        public static let tooLarge = 4103
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
    /// "<host[:port]>" and "<path> <host[:port]>" for the log.
    nonisolated var host: String { get }
    nonisolated var label: String { get }
    /// What the winner store keeps for a direct candidate: its URL string.
    nonisolated var key: String { get }
}

extension ConnectionLeg {
    nonisolated var host: String { "?" }
    nonisolated var label: String { "leg" }
}

extension RelayConnection: ConnectionLeg {}

/// Dials the direct candidates and the relay; the first path whose Noise session opens wins and the others are closed.
/// `RacePolicy` sets when each leg starts: last time's winner on this network kind first, the other direct candidates
/// 50 ms apart, the relay 300 ms late behind a direct winner, and at once when every direct leg has failed. One leg
/// handshakes at a time: the plugin keeps a device's newest session, so two inits in flight could leave it holding the
/// loser's. A network path change or a lost session starts a new race; nothing migrates, and the app resends its
/// unacknowledged outbox on the new session. Each race reads the stored `direct_hints`, and Bonjour results join it as
/// they come.
public actor RacingConnection {
    typealias Legs = @Sendable (_ pairing: QrPayload, _ relayKnows: Bool, _ direct: [URL])
        -> (relay: any ConnectionLeg, direct: [any ConnectionLeg])
    /// A direct leg added to the race in flight (a Bonjour result).
    typealias DirectLeg = @Sendable (_ pairing: QrPayload, _ url: URL) -> any ConnectionLeg
    /// The direct candidates for these hints, and the hints left out with why.
    typealias Candidates = @Sendable (_ hints: DirectHints?) -> (candidates: [URL], skipped: [(String, String)])
    /// Matching Bonjour results for the pairing's tag; nil while browsing is not allowed.
    typealias Browse = @Sendable (_ hostKey: Data) -> AsyncStream<URL>?
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// An app reconnect joins a healthy race this young, won or not, instead of starting another.
    static let joinWindow = Duration.seconds(10)
    static let browseTime = Duration.seconds(5)

    private var pairing: QrPayload
    private var relayKnows: Bool
    private let makeLegs: Legs
    private let makeDirect: DirectLeg
    private let candidates: Candidates
    private let hints: DirectHintStore
    private let browse: Browse?
    private let pathChanges: @Sendable () -> AsyncStream<Void>
    private let network: @Sendable () async -> String
    private let winners: any RaceWinners
    private let sleep: Sleep
    private let joinWindow: Duration

    private var continuation: AsyncStream<RelayConnection.Update>.Continuation?
    private var running = false
    private var state = RelayConnection.State.offline
    private var round = 0
    private var nextID = 0
    private var legs: [Int: any ConnectionLeg] = [:]
    private var relayID: Int?
    /// The race's direct legs in dial order.
    private var order: [Int] = []
    /// Every direct URL this race dialed or is dialing.
    private var dialed: Set<String> = []
    private var browsing: Task<Void, Never>?
    private var started: Set<Int> = []
    private var timers: [Task<Void, Never>] = []
    private var relayState: RelayConnection.State?
    private var listeners: [Task<Void, Never>] = []
    private var waiting: [Int] = []
    private var holder: Int?
    private var winner: Int?
    private var hostWasOffline = false
    /// While pairing: the relay leg joined, or `relayUnreachable` went out, this race.
    private var relayReached = false
    /// While pairing: the relay refused the code (an offline one), which the direct legs may still pair with.
    private var relayRefusal: RelayConnection.State?
    private var paths: Task<Void, Never>?
    private var again: Task<Void, Never>?
    private var pushToken: String?
    private var raceBegan = ContinuousClock.now
    private var raceNetwork = "none"
    private var sessionBegan = ContinuousClock.now
    private var quickLosses = 0

    public init(pairing: QrPayload, identity: PhoneIdentity, relayKnows: Bool, local: PeerInfo, urlSession: URLSession = .shared) throws {
        let relayURL = try RelayConnection.relayURL(pairing)
        let direct: DirectLeg = { pairing, url in
            RelayConnection(path: .direct, dial: url, pairing: pairing, identity: identity, relayKnows: true, local: local,
                urlSession: urlSession)
        }
        self.init(pairing: pairing, relayKnows: relayKnows, legs: { pairing, relayKnows, urls in
            let relay = RelayConnection(path: .relay, dial: relayURL, pairing: pairing, identity: identity, relayKnows: relayKnows,
                local: local, urlSession: urlSession)
            return (relay: relay as any ConnectionLeg, direct: urls.map { direct(pairing, $0) })
        }, direct: direct, candidates: { hints in
            #if os(macOS)
            let isMac = true
            #else
            let isMac = false
            #endif
            return DirectCandidates.plan(hints: hints, interfaces: LocalInterface.current(), isMac: isMac,
                lanAllowed: LocalNetwork.allowed, lanDenied: LocalNetwork.denied)
        }, hints: DirectHintStore(), browse: { key in LocalNetwork.usable ? Bonjour.browse(hostKey: key) : nil },
            pathChanges: RacingConnection.networkChanges, network: { await NetworkKind.shared.current() },
            winners: DefaultsRaceWinners())
    }

    init(pairing: QrPayload, relayKnows: Bool, legs: @escaping Legs, direct: @escaping DirectLeg,
        candidates: @escaping Candidates, hints: DirectHintStore, browse: Browse?,
        pathChanges: @escaping @Sendable () -> AsyncStream<Void>,
        network: @escaping @Sendable () async -> String, winners: any RaceWinners,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }, joinWindow: Duration = RacingConnection.joinWindow) {
        self.pairing = pairing
        self.relayKnows = relayKnows
        makeLegs = legs
        makeDirect = direct
        self.candidates = candidates
        self.hints = hints
        self.browse = browse
        self.pathChanges = pathChanges
        self.network = network
        self.winners = winners
        self.sleep = sleep
        self.joinWindow = joinWindow
    }

    /// Forgets which path won for this pairing room, on every network kind: for a pairing the app removes or replaces.
    public static func forgetRaceWinners(room: String) {
        DefaultsRaceWinners.forget(room: room)
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
            // A new path can change which candidates answer: always a new race.
            for await _ in changes { await self?.race() }
        }
        await race()
    }

    /// The app's reconnect (scene active, a sent share, a background wake) joins a race that began under 10 s ago, won or
    /// not: it began moments ago for the same reason (at launch the race can be won before the scene's reconnect comes).
    /// A stale race, a pause after a lost session, a relay waiting out its retry or a winner whose session is no longer
    /// open gives way to a new race.
    public func reconnect() async {
        guard running else { return await start() }
        let healthy = again == nil && (winner == nil ? relayState != .offline : state == .ready)
        if healthy, ContinuousClock.now - raceBegan < joinWindow {
            let won = winner == nil ? "in flight" : "already won"
            return connectionLog.info("reconnect joins race \(self.round, privacy: .public), \(won, privacy: .public)")
        }
        await race()
    }

    /// Permission changes can make direct candidates usable while a relay session is healthy, or while pairing (the
    /// Local Network explainer's Continue), when it always races again.
    public func raceAgain() async {
        guard running else { return }
        if let winner, winner != relayID {
            return connectionLog.info("raceAgain: already direct")
        }
        guard winner != nil || pairing.secret != nil || ContinuousClock.now - raceBegan >= .seconds(1) else { return }
        await race(preferDirect: true)
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

    /// Returns the new round, taken before any wait: a race that began during the wait has a newer one.
    @discardableResult
    private func endRace() async -> Int {
        round += 1
        let round = round
        // A race being set up counts as in flight for `reconnect`.
        raceBegan = .now
        again?.cancel()
        again = nil
        for task in listeners + timers { task.cancel() }
        listeners = []
        timers = []
        let old = legs
        legs = [:]
        relayID = nil
        order = []
        dialed = []
        stopBrowsing()
        started = []
        relayState = nil
        waiting = []
        holder = nil
        winner = nil
        hostWasOffline = false
        relayReached = false
        relayRefusal = nil
        for leg in old.values { await leg.stop() }
        return round
    }

    /// `preferDirect`: the race is for a direct path that may have come back (the host returned, permission changed), so the
    /// relay waits out the head start even after a relay win; otherwise a loopback relay can take the tie again.
    private func race(preferDirect: Bool = false) async {
        let round = await endRace()
        guard running else { return }
        let network = await network()
        guard round == self.round, running else { return }
        // Pairing races the stored hints too, which came with the QR code (#532 step 5); Bonjour waits until it paired.
        let paired = pairing.secret == nil
        let found = candidates(pairing.roomId.flatMap(hints.load(room:)))
        let (relay, direct) = makeLegs(pairing, relayKnows, found.candidates)
        raceBegan = .now
        raceNetwork = network
        dialed = Set(direct.map(\.key))
        let last = pairing.roomId.flatMap { winners.winner(room: $0, network: network) }
        var plan = RacePolicy.plan(direct: direct.map(\.key), lastWinner: last)
        if preferDirect, !plan.direct.isEmpty { plan.relay = max(plan.relay, RacePolicy.headStart) }
        let relayID = register(relay)
        self.relayID = relayID
        order = plan.direct.map { register(direct[$0.index]) }
        let starts = plan.direct.map { "\(direct[$0.index].label) at \($0.delay.ms) ms" } + ["\(relay.label) at \(plan.relay.ms) ms"]
        connectionLog.info("race \(round, privacy: .public) on \(network, privacy: .public), last winner \(last ?? "none", privacy: .public): \(starts.joined(separator: ", "), privacy: .public)")
        if !found.skipped.isEmpty {
            let skipped = found.skipped.map { "\($0.0) (\($0.1))" }.joined(separator: ", ")
            connectionLog.info("race \(round, privacy: .public) skipped \(skipped, privacy: .public)")
        }
        set(.connecting)
        for (id, start) in zip(order, plan.direct) { schedule(id, after: start.delay) }
        schedule(relayID, after: plan.relay)
        if paired { startBrowsing(round) }
    }

    /// Bonjour runs alongside the race until a session opens, the race ends or 5 s pass.
    private func startBrowsing(_ round: Int) {
        guard let key = Data(base64URLEncoded: pairing.macPubkey), key.count == 32,
              let results = browse?(key) else { return }
        connectionLog.info("race \(round, privacy: .public) browsing Bonjour")
        let time = Self.browseTime
        browsing = Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    for await url in results { await self?.add(url, round) }
                }
                group.addTask { try? await Task.sleep(for: time) }
                await group.next()
                group.cancelAll()
            }
        }
    }

    private func stopBrowsing() {
        browsing?.cancel()
        browsing = nil
    }

    /// A Bonjour result joins the race in flight as one more direct leg, unless the race already dials its URL.
    private func add(_ url: URL, _ round: Int) {
        guard round == self.round, running, winner == nil, dialed.insert(url.absoluteString).inserted else { return }
        let leg = makeDirect(pairing, url)
        let id = register(leg)
        order.append(id)
        connectionLog.info("race \(round, privacy: .public) adds \(leg.label, privacy: .public) from Bonjour")
        launch(id, round)
    }

    /// The plugin's addresses: kept for the next race. On the relay, hints that name a candidate this race did not dial
    /// start a new race at once; a direct winner just keeps them.
    private func received(_ new: DirectHints, from id: Int) {
        guard let room = pairing.roomId else { return }
        hints.save(new, room: room)
        guard id == relayID, pairing.secret == nil,
              candidates(new).candidates.contains(where: { !dialed.contains($0.absoluteString) }) else { return }
        connectionLog.info("race \(self.round, privacy: .public): new direct hints on the relay, racing again")
        rerace(after: .zero, preferDirect: true)
    }

    private func register(_ leg: any ConnectionLeg) -> Int {
        let id = nextID
        nextID += 1
        legs[id] = leg
        return id
    }

    private func schedule(_ id: Int, after delay: Duration) {
        guard delay > .zero else { return launch(id, round) }
        let round = round
        let sleep = sleep
        timers.append(Task { [weak self] in
            do { try await sleep(delay) } catch { return }
            await self?.launch(id, round)
        })
    }

    /// Happy Eyeballs: a failed direct leg starts the next pending one at once, and once every direct leg has failed the
    /// relay starts without waiting out its head start. A failed relay never holds back a direct leg.
    private func hurry() {
        guard winner == nil else { return }
        if let next = order.first(where: { legs[$0] != nil && !started.contains($0) }) { return launch(next, round) }
        if order.allSatisfy({ legs[$0] == nil }), let relayID { launch(relayID, round) }
    }

    private func launch(_ id: Int, _ round: Int) {
        guard round == self.round, winner == nil, let leg = legs[id], started.insert(id).inserted else { return }
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
            let won = winner != id
            if id == winner, id == relayID, hostWasOffline {
                hostWasOffline = false
                if !candidates(pairing.roomId.flatMap(hints.load(room:))).candidates.isEmpty {
                    connectionLog.info("race \(round, privacy: .public): host back on the relay, racing again for direct")
                    rerace(after: .zero, preferDirect: true)
                }
            }
            if winner != id {
                let label = legs[id]?.label ?? "leg"
                connectionLog.info("race \(round, privacy: .public) won by \(label, privacy: .public) after \((ContinuousClock.now - self.raceBegan).ms, privacy: .public) ms")
                winner = id
                holder = id
                waiting = []
                for timer in timers { timer.cancel() }
                timers = []
                stopBrowsing()
                if let room = pairing.roomId, let leg = legs[id] {
                    winners.record(id == relayID ? RacePolicy.relayKey : leg.key, room: room, network: raceNetwork)
                }
                let losers = legs.filter { $0.key != id }
                for key in losers.keys { legs[key] = nil }
                for leg in losers.values { await leg.stop() }
                guard round == self.round else { return }
                pairing.secret = nil
            }
            sessionBegan = .now
            set(.ready)
            if won {
                continuation?.yield(.route(id == relayID ? .relay : DirectRoute.of(legs[id].flatMap { URL(string: $0.key) })))
            }
            continuation?.yield(.sessionOpen(peer))
        case .state(let new):
            let refused = if case .pairingFailed = new { true } else { false }
            if id == relayID, pairing.secret != nil, !relayReached, refused || new == .offline {
                relayReached = true
                continuation?.yield(.relayUnreachable)
            }
            // The relay doesn't know an offline code; the direct legs may still pair with it (#532 step 5).
            if id == relayID, refused, pairing.secret != nil, order.contains(where: { legs[$0] != nil }), let leg = legs[id] {
                connectionLog.info("race \(round, privacy: .public): the relay refused the pairing code, direct legs go on")
                relayRefusal = new
                relayState = new
                legs[id] = nil
                waiting.removeAll { $0 == id }
                if holder == id {
                    holder = nil
                    await next()
                }
                return await leg.stop()
            }
            switch new {
            case .updateRequired, .unpaired, .pairingFailed:
                return await fail(new)
            default:
                break
            }
            if id == winner {
                if id == relayID, new == .hostOffline { hostWasOffline = true }
                // A direct winner is lost on any state but ready; a relay winner only when its socket closes (it rides
                // out a host going offline on the same socket). Either way the next race may find the other path.
                let lost = id == relayID ? new == .offline : new != .ready
                guard lost, let leg = legs[id] else { return set(new) }
                let lived = ContinuousClock.now - sessionBegan
                quickLosses = RacePolicy.quickLosses(after: quickLosses, lived: lived)
                let pause = RacePolicy.pause(quickLosses: quickLosses)
                connectionLog.info("\(leg.label, privacy: .public) session lost (\(String(describing: new), privacy: .public)) after \(lived.ms, privacy: .public) ms, quick losses \(self.quickLosses, privacy: .public); racing again in \(String(describing: pause), privacy: .public)")
                legs[id] = nil
                winner = nil
                holder = nil
                set(.connecting)
                rerace(after: pause)
                return await leg.stop()
            }
            if id == relayID {
                relayState = new
                if winner == nil { set(new) }
            }
            // `.ready` comes just before `.sessionOpen`; the holder keeps its turn through both.
            if new != .handshaking && new != .ready {
                waiting.removeAll { $0 == id }
                if holder == id {
                    holder = nil
                    await next()
                }
            }
            if new == .offline && id != relayID {
                legs[id] = nil
                if let relayRefusal, winner == nil, order.allSatisfy({ legs[$0] == nil }) { return await fail(relayRefusal) }
                hurry()
            }
        case .event(.directHints(let new)):
            guard id == winner else { return }
            continuation?.yield(update)
            received(new, from: id)
        case .accepted, .event:
            if id == winner { continuation?.yield(update) }
        case .relayJoined:
            relayKnows = true
            relayReached = true
            continuation?.yield(update)
        case .route, .relayUnreachable:
            break
        }
    }

    /// A terminal state: the racer stops.
    private func fail(_ final: RelayConnection.State) async {
        running = false
        paths?.cancel()
        await endRace()
        set(final)
    }

    private func rerace(after pause: Duration, preferDirect: Bool = false) {
        guard again == nil else { return }
        let round = round
        let sleep = sleep
        again = Task { [weak self] in
            if pause > .zero {
                do { try await sleep(pause) } catch { return }
            }
            guard !Task.isCancelled else { return }
            await self?.rerace(round, preferDirect: preferDirect)
        }
    }

    private func rerace(_ round: Int, preferDirect: Bool) async {
        guard round == self.round, running else { return }
        await race(preferDirect: preferDirect)
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
