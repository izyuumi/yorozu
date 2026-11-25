import Foundation
import Testing
import YorozuWire

@MainActor
final class ModelHarness {
    @MainActor final class Transports {
        var asked = 0
        var fails = true
        var scripted: ScriptedTransport?

        func make() throws -> any ClientTransport {
            asked += 1
            if fails { throw CocoaError(.featureUnsupported) }
            return scripted ?? IdleTransport()
        }
    }

    let storage = MemoryPairingStorage()
    let migration = PairingMigration.State()
    let transports = Transports()
    let cache: ConversationCache
    let convId = WireEvent.newId()

    var scripted: ScriptedTransport? { transports.scripted }

    init() throws {
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

    func store(paired: Bool) throws -> Pairing {
        let json = #"{"pairing":{"v":3,"relayUrl":"wss://relay.test","macPubkey":"key","token":"","roomId":"room-\#(convId)"},"identity":{"signingPrivateKey":"","signingPublicKey":"","sessionPrivateKey":"","sessionPublicKey":""},"relayKnows":true,"paired":\#(paired)}"#
        let pairing = try JSONDecoder().decode(Pairing.self, from: Data(json.utf8))
        try pairing.save(storage: storage)
        cache.save(Conversation(id: convId, createdAt: 1, updatedAt: 1))
        return pairing
    }

    func seed(_ conversations: [Conversation]) {
        for conversation in conversations { cache.save(conversation) }
    }

    func makeModel(demo: Bool = false) -> AppModel {
        AppModel(demo: demo, storage: storage, migration: migration, cache: cache,
            transport: { [transports] _, _ in try transports.make() }, shares: { [] }, notifications: {})
    }

    func settled(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    func openFirstSession(capabilities: [String] = []) async throws -> AppModel {
        let transport = ScriptedTransport()
        await transport.emit(.state(.ready))
        await transport.emit(.sessionOpen(PeerInfo(app: "test", capabilities: capabilities)))
        transports.fails = false
        transports.scripted = transport
        let model = makeModel()
        let opened = await settled { model.hostInfo != nil }
        try #require(opened)
        return model
    }

    func stored() -> Pairing? { try? Pairing.load(storage: storage, state: migration) }
}
