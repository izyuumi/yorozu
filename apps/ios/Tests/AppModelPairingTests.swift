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

@MainActor
@Suite struct AppModelPairingTests {
    @MainActor private final class Transports {
        var asked = 0
        var fails = true

        func make() throws -> any ClientTransport {
            asked += 1
            if fails { throw CocoaError(.featureUnsupported) }
            return IdleTransport()
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
            transport: { [transports] _, _ in try transports.make() }, shares: { [] })
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
}
