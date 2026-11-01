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

    @Test func loopbackIsTheOnlyCandidate() {
        #if os(macOS)
        #expect(Direct.candidates.map(\.absoluteString) == ["ws://127.0.0.1:8738", "ws://[::1]:8738"])
        #else
        #expect(Direct.candidates.isEmpty)
        #endif
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

/// Every leg each race made, newest race last.
actor Races {
    private(set) var rounds: [(relay: FakeLeg, direct: [FakeLeg])] = []
    func add(_ round: (relay: FakeLeg, direct: [FakeLeg])) { rounds.append(round) }
    var last: (relay: FakeLeg, direct: [FakeLeg])? { rounds.last }
    var count: Int { rounds.count }
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
    let pairing = QrPayload(v: 3, relayUrl: "wss://relay.test", macPubkey: "", token: "", roomId: "room")
    let races = Races()
    let seen = Seen()
    let changes = AsyncStream<Void>.makeStream()
    let winners = MemoryWinners()
    let sleeps = Sleeps()

    /// Waits a hundredth of the policy's delays unless `sleep` says otherwise.
    func racer(direct: Int = 1, sleep: RacingConnection.Sleep? = nil) async -> RacingConnection {
        let races = races
        let racer = RacingConnection(pairing: pairing, relayKnows: true, legs: { _, _ in
            let round = (relay: FakeLeg("relay"), direct: (0..<direct).map { FakeLeg("direct\($0)") })
            Task { await races.add(round) }
            return (relay: round.relay as any ConnectionLeg, direct: round.direct.map { $0 as any ConnectionLeg })
        }, pathChanges: { [changes] in changes.stream }, network: { "wifi" }, winners: winners,
            sleep: sleep ?? { try await Task.sleep(for: $0 / 100) })
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
}
