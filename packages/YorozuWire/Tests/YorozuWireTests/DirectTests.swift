import CryptoKit
import Foundation
import Testing
@testable import YorozuWire

/// The direct path (#532 step 3): the probe the client checks before its init, and the race between paths.
struct DirectProbeTests {
    let host = Curve25519.Signing.PrivateKey()
    var pubkey: String { host.publicKey.rawRepresentation.base64URLEncodedString() }
    var room: String { Data(SHA256.hash(data: host.publicKey.rawRepresentation)).base64URLEncodedString() }

    func sign(_ key: Curve25519.Signing.PrivateKey, room: String, nonce: String) throws -> String {
        try key.signature(for: Data("yorozu-direct|\(room)|\(nonce)".utf8)).base64URLEncodedString()
    }

    @Test func theRoomsKeyOverTheNonceHolds() throws {
        let nonce = Direct.newNonce()
        #expect(Data(base64URLEncoded: nonce)?.count == 32)
        #expect(Direct.verifyProbe(room: room, nonce: nonce, pubkey: pubkey, sig: try sign(host, room: room, nonce: nonce)))
    }

    @Test func aBadSignatureFails() throws {
        let nonce = Direct.newNonce()
        let other = Curve25519.Signing.PrivateKey()
        #expect(!Direct.verifyProbe(room: room, nonce: nonce, pubkey: pubkey, sig: try sign(other, room: room, nonce: nonce)))
        #expect(!Direct.verifyProbe(room: room, nonce: Direct.newNonce(), pubkey: pubkey, sig: try sign(host, room: room, nonce: nonce)))
        #expect(!Direct.verifyProbe(room: room, nonce: nonce, pubkey: pubkey, sig: "not base64url!"))
    }

    @Test func aKeyThatIsNotTheRoomsFails() throws {
        let nonce = Direct.newNonce()
        let other = Curve25519.Signing.PrivateKey()
        let otherKey = other.publicKey.rawRepresentation.base64URLEncodedString()
        // A valid signature by a key whose hash is another room: some other Gateway, or one posing as ours.
        #expect(!Direct.verifyProbe(room: room, nonce: nonce, pubkey: otherKey, sig: try sign(other, room: room, nonce: nonce)))
        #expect(!Direct.verifyProbe(room: room, nonce: nonce, pubkey: String(pubkey.dropLast(2)), sig: try sign(host, room: room, nonce: nonce)))
    }

    @Test func pushTokenRoundTrips() throws {
        let event = WireEvent.pushToken(PushToken(token: "00ab"))
        #expect(String(decoding: try event.encoded(), as: UTF8.self) == #"{"data":{"token":"00ab"},"kind":"push_token"}"#)
        #expect(try JSONDecoder().decode(WireEvent.self, from: event.encoded()) == event)
    }

}

actor FakeLeg: ConnectionLeg {
    let name: String
    private var continuation: AsyncStream<RelayConnection.Update>.Continuation?
    private var ready: (@Sendable () -> Void)?
    private var awaiting = false
    private(set) var grants = 0
    private(set) var started = false
    private(set) var stopped = false
    private(set) var sent: [String] = []

    init(_ name: String) { self.name = name }
    nonisolated var key: String { name }

    func updates() -> AsyncStream<RelayConnection.Update> {
        let (stream, continuation) = AsyncStream<RelayConnection.Update>.makeStream()
        self.continuation = continuation
        return stream
    }

    func gate(_ ready: @escaping @Sendable () -> Void) { self.ready = ready }

    func grant() -> Bool {
        guard awaiting else { return false }
        awaiting = false
        grants += 1
        return true
    }

    func start() { started = true }
    func stop() { stopped = true }
    func registerPush(deviceToken: String) {}

    func send(_ message: Message) -> Bool {
        sent.append(message.messageId)
        return true
    }

    func send(_ event: WireEvent) -> Bool { true }

    func becomeReady() {
        awaiting = true
        emit(.state(.handshaking))
        ready?()
    }

    func open() {
        emit(.state(.ready))
        emit(.sessionOpen(PeerInfo(app: name)))
    }

    func fail() { emit(.state(.offline)) }
    func accept(_ id: String) { emit(.accepted(messageId: id)) }
    func emit(_ update: RelayConnection.Update) { continuation?.yield(update) }
}

/// Every leg each race made, newest race last, and the legs Bonjour added.
actor Races {
    private(set) var rounds: [(relay: FakeLeg, direct: [FakeLeg])] = []
    private(set) var added: [FakeLeg] = []
    /// The pairing secret each race handed its legs.
    private(set) var secrets: [String?] = []
    func add(_ round: (relay: FakeLeg, direct: [FakeLeg]), secret: String? = nil) {
        rounds.append(round)
        secrets.append(secret)
    }
    func add(_ leg: FakeLeg) { added.append(leg) }
    var last: (relay: FakeLeg, direct: [FakeLeg])? { rounds.last }
    var count: Int { rounds.count }
}

/// Bonjour results the test hands the race, and whether the race stopped browsing.
actor Browser {
    let results = AsyncStream<URL>.makeStream()
    private(set) var browsed = 0
    private(set) var ended = 0

    init() {
        results.continuation.onTermination = { [weak self] _ in Task { await self?.end() } }
    }

    func began() { browsed += 1 }
    func end() { ended += 1 }
    nonisolated func find(_ url: String) { results.continuation.yield(URL(string: url)!) }
}

/// What the app saw.
actor Seen {
    private(set) var updates: [RelayConnection.Update] = []
    func add(_ update: RelayConnection.Update) { updates.append(update) }
    var opened: [String] {
        updates.compactMap { update -> String? in
            if case .sessionOpen(let peer) = update { return peer.app }
            return nil
        }
    }
    var accepted: [String] {
        updates.compactMap { update -> String? in
            if case .accepted(let id) = update { return id }
            return nil
        }
    }
    var routesAndSessions: [String] {
        updates.compactMap { update in
            switch update {
            case .route(let route): "route:\(route.rawValue)"
            case .sessionOpen(let peer): "open:\(peer.app)"
            default: nil
            }
        }
    }
    var unreachable: Int {
        updates.filter { if case .relayUnreachable = $0 { true } else { false } }.count
    }
    var states: [RelayConnection.State] {
        updates.compactMap { update -> RelayConnection.State? in
            if case .state(let state) = update { return state }
            return nil
        }
    }
}

/// The winner store, in memory.
final class MemoryWinners: RaceWinners, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: String] = [:]

    func winner(room: String, network: String) -> String? {
        lock.withLock { stored["\(room) \(network)"] }
    }

    func record(_ key: String, room: String, network: String) {
        lock.withLock { stored["\(room) \(network)"] = key }
    }
}

/// Every wait the racer asked for; each one lasts until the race is over, so nothing starts on a timer.
actor Sleeps {
    private(set) var asked: [Duration] = []
    func add(_ duration: Duration) { asked.append(duration) }

    nonisolated var never: RacingConnection.Sleep {
        { duration in
            await self.add(duration)
            try await Task.sleep(for: .seconds(3600))
        }
    }
}

struct RaceTests {
    let pairing = QrPayload(v: 3, relayUrl: "wss://relay.test", macPubkey: Data(count: 32).base64URLEncodedString(), token: "",
        roomId: "room")
    let races = Races()
    let seen = Seen()
    let changes = AsyncStream<Void>.makeStream()
    let winners = MemoryWinners()
    let sleeps = Sleeps()
    let hints = DirectHintStore(suite: "yorozu.tests.\(UUID().uuidString)")
    let browser = Browser()

    /// Waits a hundredth of the policy's delays unless `sleep` says otherwise. The candidates are `direct0`… and each
    /// stored LAN hint as `ws://<address>:<port>`.
    func racer(direct: Int = 1, sleep: RacingConnection.Sleep? = nil, joinWindow: Duration = RacingConnection.joinWindow,
        bonjour: Bool = false, network: String = "wifi", candidates makeCandidates: RacingConnection.Candidates? = nil,
        hostIsLocal: @escaping @Sendable (DirectHints?) -> Bool = { _ in true }, secret: String? = nil) async -> RacingConnection {
        var pairing = pairing
        pairing.secret = secret
        let races = races
        let browser = browser
        let legs: RacingConnection.Legs = { pairing, _, urls in
            let round = (relay: FakeLeg("relay"), direct: urls.map { FakeLeg($0.absoluteString) })
            Task { await races.add(round, secret: pairing.secret) }
            return (relay: round.relay as any ConnectionLeg, direct: round.direct.map { $0 as any ConnectionLeg })
        }
        let added: RacingConnection.DirectLeg = { _, url in
            let leg = FakeLeg(url.absoluteString)
            Task { await races.add(leg) }
            return leg
        }
        let candidates: RacingConnection.Candidates = { hints in
            let base = (0..<direct).compactMap { URL(string: "direct\($0)") }
            guard let hints else { return (candidates: base, skipped: []) }
            return (candidates: base + hints.lan.compactMap { URL(string: "ws://\($0.address):\(hints.port)") }, skipped: [])
        }
        let browse: RacingConnection.Browse = { _ in
            Task { await browser.began() }
            return browser.results.stream
        }
        let changes = changes
        let racer = RacingConnection(pairing: pairing, relayKnows: secret == nil, legs: legs, direct: added, candidates: makeCandidates ?? candidates,
            hints: hints, browse: bonjour ? browse : nil, pathChanges: { changes.stream }, network: { network }, winners: winners,
            sleep: sleep ?? { try await Task.sleep(for: $0 / 100) }, joinWindow: joinWindow, hostIsLocal: hostIsLocal)
        let updates = await racer.updates()
        let seen = seen
        Task { for await update in updates { await seen.add(update) } }
        await racer.start()
        return racer
    }

    func eventually(_ what: Comment, _ check: () async -> Bool) async {
        for _ in 0..<300 {
            if await check() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        Issue.record(what)
    }

    func round(_ n: Int) async -> (relay: FakeLeg, direct: [FakeLeg]) {
        await eventually("race \(n) started") { await races.count >= n }
        return await races.rounds[n - 1]
    }

    func started(_ legs: [FakeLeg]) async {
        for leg in legs { await eventually("\(leg.name) started") { await leg.started } }
    }

    func stopped(_ legs: [FakeLeg]) async -> Bool {
        for leg in legs {
            let stopped = await leg.stopped
            if !stopped { return false }
        }
        return true
    }

    @Test func directWinsAndTheRelayIsClosed() async {
        let racer = await racer()
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await direct[0].becomeReady()
        await eventually("direct granted") { await direct[0].grants == 1 }
        await relay.becomeReady()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await relay.grants == 0, "one handshake at a time")
        await direct[0].open()
        await eventually("direct opened") { await seen.opened == ["direct0"] }
        #expect(await seen.routesAndSessions == ["route:wifi", "open:direct0"])
        await eventually("relay closed") { await relay.stopped }
        #expect(await relay.grants == 0)
        #expect(await racer.send(Message(convId: "c", messageId: "m1", text: "hi")))
        #expect(await direct[0].sent == ["m1"])
        await direct[0].accept("m1")
        await eventually("✓ from direct") { await seen.accepted == ["m1"] }
    }

    @Test func directFailsAndTheRelayProceeds() async {
        let racer = await racer()
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await direct[0].becomeReady()
        await eventually("direct granted") { await direct[0].grants == 1 }
        await relay.becomeReady()
        await direct[0].fail()
        await eventually("relay granted once direct failed") { await relay.grants == 1 }
        await relay.open()
        await eventually("relay opened") { await seen.opened == ["relay"] }
        #expect(await seen.routesAndSessions == ["route:relay", "open:relay"])
        #expect(await seen.states.last == .ready)
        #expect(await racer.send(Message(convId: "c", messageId: "m1", text: "hi")))
        #expect(await relay.sent == ["m1"])
        #expect(await direct[0].sent.isEmpty)
    }

    @Test func aPathChangeRacesAgain() async {
        let racer = await racer()
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await relay.becomeReady()
        await relay.open()
        await eventually("relay opened") { await seen.opened == ["relay"] }
        changes.continuation.yield()
        let (relay2, direct2) = await round(2)
        await eventually("old legs closed") { await stopped([relay] + direct) }
        await started([relay2] + direct2)
        await direct2[0].becomeReady()
        await direct2[0].open()
        await eventually("direct won the new race") { await seen.opened == ["relay", "direct0"] }
        await racer.stop()
    }

    @Test func aLostDirectSessionRacesAgainAndUnackedMessagesGoOnTheNewOne() async {
        let racer = await racer()
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await direct[0].becomeReady()
        await direct[0].open()
        await eventually("direct opened") { await seen.opened == ["direct0"] }
        #expect(await racer.send(Message(convId: "c", messageId: "m1", text: "no ✓ yet")))
        await direct[0].fail()
        await eventually("connecting again") { await seen.states.last == .connecting }
        #expect(await !racer.send(Message(convId: "c", messageId: "m2", text: "between sessions")))
        let (relay2, direct2) = await round(2)
        await started([relay2] + direct2)
        await direct2[0].fail()
        await relay2.becomeReady()
        await relay2.open()
        // A new `sessionOpen` is the app's cue to resend everything without ✓ (`AppModel.pumpOutbox(resend:)`).
        await eventually("relay opened") { await seen.opened == ["direct0", "relay"] }
        #expect(await racer.send(Message(convId: "c", messageId: "m1", text: "no ✓ yet")))
        #expect(await relay2.sent == ["m1"])
        await direct[0].accept("m1")
        await relay2.accept("m1")
        await eventually("✓ only from the current session") { await seen.accepted == ["m1"] }
    }

    @Test func theFirstOfTwoDirectCandidatesWins() async {
        let racer = await racer(direct: 2)
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await direct[1].becomeReady()
        await eventually("second candidate granted") { await direct[1].grants == 1 }
        await direct[0].becomeReady()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await direct[0].grants == 0)
        await direct[1].open()
        await eventually("others closed") { await stopped([relay, direct[0]]) }
        await racer.stop()
    }

    @Test func lastTimesDirectWinnerGoesFirstAndTheRelayWaits() async {
        let racer = await racer(direct: 2, sleep: sleeps.never)
        let (relay, direct) = await round(1)
        await started([relay, direct[0]])
        #expect(await !direct[1].started, "50 ms behind the first candidate")
        await direct[0].fail()
        await started([direct[1]])
        await direct[1].becomeReady()
        await direct[1].open()
        await eventually("second candidate won") { await seen.opened == ["direct1"] }
        #expect(winners.winner(room: "room", network: "wifi") == "direct1")

        changes.continuation.yield()
        let (relay2, direct2) = await round(2)
        await started([direct2[1]])
        await eventually("relay and other candidate wait") {
            let asked = await sleeps.asked
            return asked.count == 3 && asked.suffix(2).sorted() == [.milliseconds(50), .milliseconds(300)]
        }
        #expect(await !relay2.started)
        #expect(await !direct2[0].started)
        // A relay that would be ready at once cannot win: it has not started.
        await relay2.becomeReady()
        await direct2[1].becomeReady()
        await direct2[1].open()
        await eventually("direct won again") { await seen.opened == ["direct1", "direct1"] }
        await eventually("relay closed") { await relay2.stopped }
        #expect(await relay2.grants == 0)
        await racer.stop()
    }

    @Test func aStaleDirectWinnerDoesNotHoldTheRelayBack() async {
        winners.record("direct0", room: "room", network: "wifi")
        let racer = await racer(direct: 2, sleep: sleeps.never)
        let (relay, direct) = await round(1)
        await started([direct[0]])
        #expect(await !relay.started)
        await direct[0].fail()
        await started([direct[1]])
        #expect(await !relay.started)
        await direct[1].fail()
        await started([relay])
        await relay.becomeReady()
        await relay.open()
        await eventually("relay opened") { await seen.opened == ["relay"] }
        #expect(winners.winner(room: "room", network: "wifi") == "relay")
        await racer.stop()
    }

    @Test func reconnectJoinsTheRaceInFlight() async {
        let racer = await racer()
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await racer.reconnect()
        await racer.reconnect()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == 1)
        #expect(await !relay.stopped)
        // A new network path still restarts it.
        changes.continuation.yield()
        _ = await round(2)
        await eventually("old legs closed") { await stopped([relay] + direct) }
        await racer.stop()
    }

    @Test func reconnectRightAfterTheRaceWasWonJoinsIt() async {
        let racer = await racer()
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await relay.becomeReady()
        await relay.open()
        await eventually("relay opened") { await seen.opened == ["relay"] }
        await racer.reconnect()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == 1)
        #expect(await !relay.stopped)
        #expect(await racer.send(Message(convId: "c", messageId: "m1", text: "hi")))
        await racer.stop()
    }

    @Test func reconnectAfterTheJoinWindowRacesAgain() async {
        let racer = await racer(joinWindow: .milliseconds(50))
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await relay.becomeReady()
        await relay.open()
        await eventually("relay opened") { await seen.opened == ["relay"] }
        try? await Task.sleep(for: .milliseconds(80))
        await racer.reconnect()
        _ = await round(2)
        await eventually("old legs closed") { await stopped([relay] + direct) }
        await racer.stop()
    }

    @Test func theFirstLossRacesAgainAtOnceAndTheSecondQuickOnePauses() async {
        let racer = await racer(sleep: sleeps.never)
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await direct[0].becomeReady()
        await direct[0].open()
        await eventually("direct opened") { await seen.opened == ["direct0"] }
        await direct[0].fail()
        // Every wait lasts until the race ends, so a second race at all means no pause.
        let (_, direct2) = await round(2)
        await started(direct2)
        await direct2[0].becomeReady()
        await direct2[0].open()
        await eventually("direct opened again") { await seen.opened == ["direct0", "direct0"] }
        await direct2[0].fail()
        await eventually("second quick loss pauses 1 s") { await sleeps.asked.contains(.seconds(1)) }
        #expect(await !sleeps.asked.contains { $0 >= .seconds(1) && $0 != .seconds(1) })
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == 2)
        #expect(await seen.states.last == .connecting)
        await racer.stop()
    }

    @Test func aBonjourLegAddedMidRaceCanWinAndBrowsingStops() async {
        let racer = await racer(bonjour: true)
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await eventually("browsing") { await browser.browsed == 1 }
        browser.find("ws://192.168.0.9:8738")
        await eventually("Bonjour leg added") { await races.added.count == 1 }
        let found = await races.added[0]
        await started([found])
        await found.becomeReady()
        await eventually("Bonjour leg granted") { await found.grants == 1 }
        await found.open()
        await eventually("Bonjour leg won") { await seen.opened == ["ws://192.168.0.9:8738"] }
        await eventually("others closed") { await stopped([relay] + direct) }
        await eventually("browsing stopped") { await browser.ended == 1 }
        #expect(winners.winner(room: "room", network: "wifi") == "ws://192.168.0.9:8738")
        await racer.stop()
    }

    @Test func aBonjourResultTheRaceAlreadyDialsIsNotAdded() async {
        let racer = await racer(bonjour: true)
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await eventually("browsing") { await browser.browsed == 1 }
        browser.find("direct0")
        browser.find("ws://192.168.0.9:8738")
        browser.find("ws://192.168.0.9:8738")
        await eventually("one leg added") { await races.added.count == 1 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.added.map(\.name) == ["ws://192.168.0.9:8738"])
        await racer.stop()
    }

    @Test func aBonjourResultAfterTheWinIsIgnored() async {
        let racer = await racer(bonjour: true)
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await eventually("browsing") { await browser.browsed == 1 }
        await relay.becomeReady()
        await relay.open()
        await eventually("relay opened") { await seen.opened == ["relay"] }
        await eventually("browsing stopped") { await browser.ended == 1 }
        browser.find("ws://192.168.0.9:8738")
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.added.isEmpty)
        await racer.stop()
    }

    let lanHints = DirectHints(port: 8738, lan: [.init(address: "192.168.0.9", prefix: 24)])

    @Test func hostReturningOnTheRelayRetriesStoredCandidatesWithoutLooping() async {
        hints.save(lanHints, room: "room")
        let racer = await racer(direct: 0)
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await relay.emit(.state(.hostOffline))
        for leg in direct { await leg.fail() }
        await relay.becomeReady()
        await relay.open()
        await eventually("first relay session opened") { await seen.opened == ["relay"] }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == 1, "offline before the first win is no host return")
        await relay.emit(.state(.hostOffline))
        await relay.becomeReady()
        await relay.open()
        let (relay2, direct2) = await round(2)
        #expect(direct2.map(\.name) == ["ws://192.168.0.9:8738"])
        await started([relay2] + direct2)
        for leg in direct2 { await leg.fail() }
        await relay2.becomeReady()
        await relay2.open()
        await eventually("relay won after direct failed again") { await seen.opened.count == 3 }
        await relay2.emit(.event(.directHints(lanHints)))
        await relay2.open()
        await eventually("another session on the same relay") { await seen.opened.count == 4 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == 2)
        #expect(await seen.routesAndSessions == ["route:relay", "open:relay", "open:relay", "route:relay", "open:relay", "open:relay"])
        await racer.stop()
    }

    @Test func hostReturningGivesDirectTheHeadStartAfterARelayWin() async {
        hints.save(lanHints, room: "room")
        let racer = await racer(direct: 0, sleep: sleeps.never)
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        for leg in direct { await leg.fail() }
        await relay.becomeReady()
        await relay.open()
        await eventually("relay won") { await seen.opened == ["relay"] }
        #expect(await !sleeps.asked.contains(RacePolicy.headStart), "no head start before direct ever won")
        await relay.emit(.state(.hostOffline))
        await relay.becomeReady()
        await relay.open()
        let (relay2, direct2) = await round(2)
        await started(direct2)
        await eventually("relay waits out the head start") { await sleeps.asked.contains(RacePolicy.headStart) }
        await direct2[0].becomeReady()
        await direct2[0].open()
        await eventually("back on direct") { await seen.opened.last == "ws://192.168.0.9:8738" }
        #expect(await relay2.grants == 0)
        #expect(await seen.routesAndSessions.suffix(2) == ["route:wifi", "open:ws://192.168.0.9:8738"])
        await racer.stop()
    }

    @Test(arguments: ["wired", "wifi"]) func lanWinnerReportsTheRacesNetwork(network: String) async {
        hints.save(lanHints, room: "room")
        let racer = await racer(direct: 0, network: network)
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await direct[0].becomeReady()
        await direct[0].open()
        await eventually("LAN session opened") { await seen.opened == ["ws://192.168.0.9:8738"] }
        let route = network == "wifi" ? "wifi" : "localNetwork"
        #expect(await seen.routesAndSessions == ["route:\(route)", "open:ws://192.168.0.9:8738"])
        await racer.stop()
    }

    @Test(arguments: [false, true]) func hostReturningOnAnotherMachineKeepsTheRelay(lanDenied: Bool) async {
        hints.save(lanHints, room: "room")
        let racer = await racer(direct: 0, candidates: { hints in
            let interfaces = [LocalInterface(name: "en0", address: "10.77.0.20", prefix: 24)]
            return DirectCandidates.plan(hints: hints, interfaces: interfaces, isMac: true, lanAllowed: true, lanDenied: lanDenied)
        }, hostIsLocal: { _ in false })
        let (relay, direct) = await round(1)
        #expect(direct.map(\.name) == ["ws://127.0.0.1:8738", "ws://[::1]:8738"])
        await started([relay] + direct)
        await relay.becomeReady()
        await relay.open()
        await eventually("relay opened") { await seen.opened.count == 1 }
        await relay.emit(.state(.hostOffline))
        await relay.becomeReady()
        await relay.open()
        await eventually("host returned") { await seen.opened.count == 2 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == 1)
        #expect(await !relay.stopped)
        await racer.stop()
    }

    @Test func hostReturningOnThisMacRacesAgain() async {
        hints.save(lanHints, room: "room")
        let racer = await racer(candidates: { hints in
            DirectCandidates.plan(hints: hints, interfaces: [], isMac: true, lanAllowed: false)
        }, hostIsLocal: { _ in true })
        let (relay, direct) = await round(1)
        #expect(direct.map(\.name) == ["ws://127.0.0.1:8738", "ws://[::1]:8738"])
        await started([relay] + direct)
        await relay.becomeReady()
        await relay.open()
        await eventually("relay opened") { await seen.opened.count == 1 }
        await relay.emit(.state(.hostOffline))
        await relay.becomeReady()
        await relay.open()
        let (relay2, direct2) = await round(2)
        await started([relay2] + direct2)
        for leg in direct2 { await leg.fail() }
        await relay2.becomeReady()
        await relay2.open()
        await eventually("relay reopened after the retry") { await seen.opened.count == 3 }
        await relay2.open()
        await eventually("another session on the same relay") { await seen.opened.count == 4 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == 2)
        await racer.stop()
    }

    @Test func staleHintsStillReachThisMacWithoutTheRelay() async {
        hints.save(lanHints, room: "room")
        let interfaces = [LocalInterface(name: "en0", address: "10.0.0.5", prefix: 24)]
        #expect(!DirectCandidates.hostMayBeLocal(hints.load(room: "room"), interfaces))
        let racer = await racer(network: "none", candidates: { hints in
            DirectCandidates.plan(hints: hints, interfaces: interfaces, isMac: true, lanAllowed: true)
        }, hostIsLocal: { DirectCandidates.hostMayBeLocal($0, interfaces) })
        let (relay, direct) = await round(1)
        #expect(direct.map(\.name) == ["ws://127.0.0.1:8738", "ws://[::1]:8738"])
        await started([relay] + direct)
        await relay.fail()
        await direct[0].becomeReady()
        await eventually("loopback handshake granted") { await direct[0].grants == 1 }
        await direct[0].open()
        await eventually("loopback session opened on this Mac") {
            await seen.routesAndSessions == ["route:thisMac", "open:ws://127.0.0.1:8738"]
        }
        #expect(await relay.stopped)
        #expect(await races.count == 1)
        await racer.stop()
    }

    @Test func hostReturningWithoutCandidatesKeepsTheRelay() async {
        let racer = await racer(direct: 0)
        let (relay, _) = await round(1)
        await started([relay])
        await relay.becomeReady()
        await relay.open()
        await eventually("relay opened") { await seen.opened.count == 1 }
        await relay.emit(.state(.hostOffline))
        await relay.becomeReady()
        await relay.open()
        await eventually("host returned") { await seen.opened.count == 2 }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == 1)
        #expect(await !relay.stopped)
        await racer.stop()
    }

    @Test(arguments: [false, true]) func permissionChangeRacesAgainOnlyOnTheRelay(directWins: Bool) async {
        let racer = await racer()
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        let winner = directWins ? direct[0] : relay
        await winner.becomeReady()
        await winner.open()
        await eventually("session opened") { await seen.opened.count == 1 }
        await racer.raceAgain()
        if directWins {
            #expect(await races.count == 1)
            #expect(await !winner.stopped)
        } else {
            _ = await round(2)
            await eventually("old relay stopped") { await relay.stopped }
        }
        await racer.stop()
        await racer.raceAgain()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == (directWins ? 1 : 2))
    }

    @Test func permissionChangeJoinsOnlyAYoungRaceInFlight() async {
        let racer = await racer()
        _ = await round(1)
        await racer.raceAgain()
        #expect(await races.count == 1)
        try? await Task.sleep(for: .milliseconds(1100))
        await racer.raceAgain()
        _ = await round(2)
        await racer.stop()
    }

    @Test func newHintsOnTheRelayRaceAgainWithTheirCandidate() async {
        let racer = await racer()
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await direct[0].fail()
        await relay.becomeReady()
        await relay.open()
        await eventually("relay opened") { await seen.opened == ["relay"] }
        await relay.emit(.event(.directHints(lanHints)))
        let (relay2, direct2) = await round(2)
        #expect(hints.load(room: "room") == lanHints)
        #expect(direct2.map(\.name) == ["direct0", "ws://192.168.0.9:8738"])
        await eventually("old relay closed") { await relay.stopped }
        await started([relay2] + direct2)
        for leg in direct2 { await leg.fail() }
        await relay2.becomeReady()
        await relay2.open()
        await eventually("relay opened again") { await seen.opened == ["relay", "relay"] }
        // The same hints name nothing new: no third race.
        await relay2.emit(.event(.directHints(lanHints)))
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == 2)
        await racer.stop()
    }

    @Test func newHintsOnADirectWinnerAreOnlyStored() async {
        let racer = await racer()
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await direct[0].becomeReady()
        await direct[0].open()
        await eventually("direct opened") { await seen.opened == ["direct0"] }
        await direct[0].emit(.event(.directHints(lanHints)))
        await eventually("hints stored") { hints.load(room: "room") == lanHints }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await races.count == 1)
        #expect(await !direct[0].stopped)
        await racer.stop()
    }

    // Offline pairing (#532 step 5).

    @Test func aPairingRaceDialsTheStoredHintsAndADirectWinPairs() async {
        hints.save(lanHints, room: "room")
        let racer = await racer(direct: 0, bonjour: true, secret: "sec")
        let (relay, direct) = await round(1)
        #expect(direct.map(\.name) == ["ws://192.168.0.9:8738"])
        #expect(await races.secrets == ["sec"], "the legs build their init's proof from the secret")
        await started([relay] + direct)
        await direct[0].becomeReady()
        await direct[0].open()
        await eventually("direct opened") { await seen.opened == ["ws://192.168.0.9:8738"] }
        await eventually("relay closed") { await relay.stopped }
        #expect(await browser.browsed == 0, "no Bonjour while pairing")
        changes.continuation.yield()
        _ = await round(2)
        #expect(await races.secrets == ["sec", nil], "paired: the next race carries no secret")
        await eventually("Bonjour once paired") { await browser.browsed == 1 }
        await racer.stop()
    }

    @Test func theRelayFailingWhilePairingIsReportedOncePerRace() async {
        let racer = await racer(secret: "sec")
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await relay.fail()
        await eventually("relay unreachable") { await seen.unreachable == 1 }
        await relay.emit(.state(.connecting))
        await relay.fail()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await seen.unreachable == 1)
        await racer.raceAgain()
        let (relay2, _) = await round(2)
        await started([relay2])
        await relay2.fail()
        await eventually("once more in the new race") { await seen.unreachable == 2 }
        await racer.stop()
    }

    @Test func theRelayFailingWhenPairedOrAfterJoinedIsNotReported() async {
        let racer = await racer()
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await relay.fail()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await seen.unreachable == 0)
        await racer.stop()
        let pairing = await self.racer(secret: "sec")
        let (relay2, direct2) = await round(2)
        await started([relay2] + direct2)
        await relay2.emit(.relayJoined)
        await relay2.fail()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(await seen.unreachable == 0)
        await pairing.stop()
    }

    @Test func aRelayRefusingAnOfflineCodeLeavesThePairingToDirect() async {
        let racer = await racer(secret: "sec")
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await relay.emit(.state(.pairingFailed("unknown device")))
        await eventually("relay unreachable") { await seen.unreachable == 1 }
        await eventually("relay closed") { await relay.stopped }
        #expect(await !seen.states.contains(.pairingFailed("unknown device")))
        await direct[0].becomeReady()
        await direct[0].open()
        await eventually("direct paired") { await seen.opened == ["direct0"] }
        await racer.stop()
    }

    @Test func aRefusedCodeFailsOnceTheDirectLegsFailToo() async {
        let racer = await racer(secret: "sec")
        let (relay, direct) = await round(1)
        await started([relay] + direct)
        await relay.emit(.state(.pairingFailed("unknown device")))
        await eventually("relay closed") { await relay.stopped }
        await direct[0].fail()
        await eventually("pairing failed") { await seen.states.last == .pairingFailed("unknown device") }
        await racer.raceAgain()
        #expect(await races.count == 1, "a failed pairing doesn't race again")
    }

    @Test func raceAgainWhilePairingRacesAtOnce() async {
        let racer = await racer(secret: "sec")
        _ = await round(1)
        await racer.raceAgain()
        _ = await round(2)
        #expect(await races.secrets == ["sec", "sec"])
        await racer.stop()
    }
}
