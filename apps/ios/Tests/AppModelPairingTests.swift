import Foundation
import Testing
import YorozuWire

private actor IdleTransport: ClientTransport {
    func updates() -> AsyncStream<RelayConnection.Update> { AsyncStream { $0.finish() } }
    func start() {}
    func reconnect() {}
    func stop() {}
    func registerPush(deviceToken: String) {}
    func send(_ event: WireEvent) -> Bool { false }
    func send(_ message: Message) -> Bool { false }
    func raceAgain() {}
}

/// Yields what a test scripts; updates yielded before `updates()` is subscribed wait for it.
private actor ScriptedTransport: ClientTransport {
    private var continuation: AsyncStream<RelayConnection.Update>.Continuation?
    private var waiting: [RelayConnection.Update] = []

    func emit(_ update: RelayConnection.Update) {
        if let continuation { continuation.yield(update) } else { waiting.append(update) }
    }

    func updates() -> AsyncStream<RelayConnection.Update> {
        let (stream, continuation) = AsyncStream<RelayConnection.Update>.makeStream()
        for update in waiting { continuation.yield(update) }
        waiting = []
        self.continuation = continuation
        return stream
    }

    func start() {}
    func reconnect() {}
    func stop() {}
    func registerPush(deviceToken: String) {}
    func send(_ event: WireEvent) -> Bool { false }
    func send(_ message: Message) -> Bool { false }
    func raceAgain() {}
}

@MainActor
@Suite struct AppModelPairingTests {
    @MainActor private final class Transports {
        var asked = 0
        var fails = true
        var scripted: ScriptedTransport?

        func make() throws -> any ClientTransport {
            asked += 1
            if fails { throw CocoaError(.featureUnsupported) }
            return scripted ?? IdleTransport()
        }
    }

    private let storage = MemoryPairingStorage()
    private let migration = PairingMigration.State()
    private let transports = Transports()
    private let cache: ConversationCache
    private let convId = WireEvent.newId()

    init() throws {
        // Fail before AppModel can reach an app-owned support directory or the App Group.
        let bundleID = try #require(Bundle.main.bundleIdentifier)
        try #require(!bundleID.hasPrefix("to.yumi.yorozu"))
        try #require(!clientSupportDirectory.path.contains("to.yumi.yorozu"))
        let environment = ProcessInfo.processInfo.environment
        let home = try #require(environment["HOME"])
        try #require(home == environment["CFFIXED_USER_HOME"])
        try #require(URL(fileURLWithPath: home).lastPathComponent.hasPrefix("YorozuTests-"))
        let suite = "YorozuTests-\(UUID().uuidString)"
        let root = URL(fileURLWithPath: home).appending(path: suite, directoryHint: .isDirectory)
        let completion = try #require(UserDefaults(suiteName: suite))
        cache = ConversationCache(storedNames: StoredNames(root: root, completion: completion))
    }

    private func store(paired: Bool) throws -> Pairing {
        let json = #"{"pairing":{"v":3,"relayUrl":"wss://relay.test","macPubkey":"key","token":"","roomId":"room-\#(convId)"},"identity":{"signingPrivateKey":"","signingPublicKey":"","sessionPrivateKey":"","sessionPublicKey":""},"relayKnows":true,"paired":\#(paired)}"#
        let pairing = try JSONDecoder().decode(Pairing.self, from: Data(json.utf8))
        try pairing.save(storage: storage)
        cache.save(Conversation(id: convId, createdAt: 1, updatedAt: 1))
        return pairing
    }

    private func makeModel() -> AppModel {
        AppModel(demo: false, storage: storage, migration: migration, cache: cache,
            transport: { [transports] _, _ in try transports.make() }, shares: { [] }, notifications: {})
    }

    @Test(arguments: [true, false]) func aFailedConnectKeepsTheStoredPairing(paired: Bool) throws {
        let pairing = try store(paired: paired)
        let model = makeModel()
        #expect(transports.asked == 1)
        #expect(try Pairing.load(storage: storage, state: migration) == pairing)
        #expect(model.pairing == pairing)
        #expect(model.conversations[convId] != nil)
        #expect(cache.loadAll().map(\.id) == [convId])
        #expect(model.pairingError != nil)

        model.resume()
        #expect(transports.asked == 2)
        #expect(try Pairing.load(storage: storage, state: migration) == pairing)

        transports.fails = false
        model.resume()
        #expect(transports.asked == 3)
        #expect(model.pairingError == nil)
    }

    @Test func anUnreadablePairingIsReadAgainOnResume() throws {
        let pairing = try store(paired: true)
        transports.fails = false
        storage.failLoad = true
        let model = makeModel()
        #expect(model.pairing == nil)
        #expect(model.pairingError != nil)

        model.resume()
        #expect(model.pairing == nil)
        #expect(model.pairingError != nil)
        #expect(transports.asked == 0)

        storage.failLoad = false
        model.resume()
        #expect(model.pairing == pairing)
        #expect(model.pairingError == nil)
        #expect(model.conversations[convId] != nil)
        #expect(transports.asked == 1)
    }

    /// The listen task applies updates on its own turns of the main actor.
    private func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    /// A model over the stored pairing whose transport is ready and has opened its first session.
    private func openFirstSession() async throws -> AppModel {
        let transport = ScriptedTransport()
        await transport.emit(.state(.ready))
        await transport.emit(.sessionOpen(PeerInfo(app: "test")))
        transports.fails = false
        transports.scripted = transport
        let model = makeModel()
        let opened = await settled { model.hostInfo != nil }
        try #require(opened)
        return model
    }

    private func stored() -> Pairing? { try? Pairing.load(storage: storage, state: migration) }

    @Test func aFailedPairedSaveIsSurfacedAndRetried() async throws {
        let pairing = try store(paired: false)
        storage.failSave = true
        let model = try await openFirstSession()
        #expect(model.pairing?.paired == true)
        #expect(try Pairing.load(storage: storage, state: migration) == pairing)
        #expect(model.pairingError != nil)

        storage.failSave = false
        model.resume()
        let retried = await settled { stored()?.paired == true }
        #expect(retried)
        #expect(stored() == model.pairing)
        #expect(model.pairingError == nil)
    }

    @Test(arguments: [RelayConnection.State.unpaired, .pairingFailed("refused")])
    func aHostRefusalAfterARetriedPairedSaveKeepsThePairing(refusal: RelayConnection.State) async throws {
        _ = try store(paired: false)
        storage.failSave = true
        let first = try await openFirstSession()
        storage.failSave = false
        first.resume()
        _ = await settled { stored()?.paired == true }

        // The next launch reads what storage holds, and the host refuses it.
        let transport = ScriptedTransport()
        await transport.emit(.state(refusal))
        transports.scripted = transport
        let relaunched = makeModel()
        _ = await settled { relaunched.state == refusal || relaunched.pairing == nil }
        #expect(relaunched.state == refusal)
        #expect(relaunched.pairing?.paired == true)
        #expect(stored()?.paired == true)
        #expect(cache.loadAll().map(\.id) == [convId])
    }
}
