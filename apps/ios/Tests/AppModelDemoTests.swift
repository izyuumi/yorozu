import Foundation
import Testing
import YorozuWire

@MainActor
@Suite struct AppModelDemoTests {
    private let harness: ModelHarness

    init() throws {
        harness = try ModelHarness()
    }

    @Test func leavingLaunchDemoMigratesLegacyPairing() throws {
        let pairing = try harness.store(paired: true)
        harness.storage.items["pairing-v3"] = harness.storage.items.removeValue(forKey: "pairing")
        let model = harness.makeModel(demo: true)
        #expect(model.isDemo)
        #expect(harness.transports.asked == 0)

        model.exitDemo()

        #expect(!model.isDemo)
        #expect(model.pairing == pairing)
        #expect(model.paired)
        #expect(harness.storage.items["pairing"] != nil)
        #expect(harness.storage.items["pairing-v3"] == nil)
        #expect(model.conversations[harness.convId] != nil)
        #expect(harness.transports.asked == 1)
    }

    @Test func leavingLaunchDemoLoadsCurrentPairing() throws {
        let pairing = try harness.store(paired: true)
        let model = harness.makeModel(demo: true)
        #expect(harness.transports.asked == 0)

        model.exitDemo()

        #expect(!model.isDemo)
        #expect(model.pairing == pairing)
        #expect(model.conversations[harness.convId] != nil)
        #expect(harness.transports.asked == 1)
    }

    @Test func leavingDemoEnteredFromLiveRestoresSnapshot() throws {
        let pairing = try harness.store(paired: true)
        let model = harness.makeModel()
        #expect(harness.transports.asked == 1)
        let live = model.conversations

        model.enterDemo()
        #expect(model.isDemo)
        #expect(model.pairing == nil)
        harness.seed([Conversation(id: WireEvent.newId(), createdAt: 2, updatedAt: 2)])

        model.exitDemo()

        #expect(!model.isDemo)
        #expect(model.pairing == pairing)
        #expect(model.conversations == live)
        #expect(harness.stored() == pairing)
        #expect(harness.transports.asked == 2)
    }
}
