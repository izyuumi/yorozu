import Foundation
import Testing
import YorozuWire

@MainActor
@Suite struct AppModelPairingTests {
    private let harness: ModelHarness

    init() throws {
        harness = try ModelHarness()
    }

    private var storage: MemoryPairingStorage { harness.storage }
    private var migration: PairingMigration.State { harness.migration }
    private var transports: ModelHarness.Transports { harness.transports }
    private var cache: ConversationCache { harness.cache }
    private var convId: String { harness.convId }

    private func store(paired: Bool) throws -> Pairing { try harness.store(paired: paired) }
    private func makeModel() -> AppModel { harness.makeModel() }
    private func settled(_ condition: () -> Bool) async -> Bool { await harness.settled(condition) }
    private func openFirstSession() async throws -> AppModel { try await harness.openFirstSession() }
    private func stored() -> Pairing? { harness.stored() }

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
