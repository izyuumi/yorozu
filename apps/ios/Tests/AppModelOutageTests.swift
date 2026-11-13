import Foundation
import Testing
import YorozuWire

/// The outage banner follows why the transport went offline, not whether the app is in front (#677, CO1).
@MainActor
@Suite struct AppModelOutageTests {
    private let harness: ModelHarness

    init() throws {
        harness = try ModelHarness()
    }

    private func settled(_ condition: () -> Bool) async -> Bool { await harness.settled(condition) }

    private func opened() async throws -> (AppModel, ScriptedTransport) {
        _ = try harness.store(paired: true)
        let model = try await harness.openFirstSession()
        return (model, try #require(harness.scripted))
    }

    private func stops(_ transport: ScriptedTransport, reach count: Int) async -> Bool {
        for _ in 0..<100 where await transport.stops != count { try? await Task.sleep(for: .milliseconds(10)) }
        return await transport.stops == count
    }

    @Test func anOfflineWhileInactiveIsAnOutage() async throws {
        let (model, transport) = try await opened()
        model.setActive(true) // RootView initial onChange: .active.
        model.setActive(false) // RootView initial-enabled onChange: .inactive from .active.
        await transport.emit(.state(.offline))
        #expect(await settled { model.outage == .offline })
    }

    @Test func anOfflineDuringTheBackgroundDrainIsAnOutage() async throws {
        let (model, transport) = try await opened()
        model.setActive(true) // RootView initial onChange: .active.
        model.setActive(false) // RootView initial-enabled onChange: .inactive from .active.
        _ = model.enterBackground() // RootView onChange: .background; the drain runs before suspend(visit:).
        await transport.emit(.state(.offline))
        #expect(await settled { model.outage == .offline })
    }

    @Test func theAppsOwnStopIsNotAnOutage() async throws {
        let (model, _) = try await ownStop()
        #expect(model.state == .offline)
        #expect(model.outage == nil)
    }

    @Test func aQuickReturnNeverStopsTheTransport() async throws {
        let (model, transport) = try await opened()
        model.setActive(true) // RootView initial onChange: .active.
        model.setActive(false) // RootView initial-enabled onChange: .inactive from .active.
        let visit = model.enterBackground() // RootView onChange: .background; hold the drain before suspend(visit:).
        model.prewarm() // RootView onChange: .inactive from .background.
        model.setActive(false) // RootView initial-enabled onChange: .inactive from .background.
        model.resume() // RootView onChange: .active.
        model.setActive(true) // RootView initial-enabled onChange: .active.
        model.suspend(visit: visit) // RootView .background handler: held drain finishes after the return to .active.

        try await Task.sleep(for: .milliseconds(600))
        #expect(await transport.stops == 0)
        #expect(model.active)
    }

    @Test func anOutageAfterTheOwnStopAndAReturnIsRecorded() async throws {
        let (model, transport) = try await ownStop()
        model.prewarm() // RootView onChange: .inactive from .background.
        model.resume() // RootView onChange: .active.
        model.setActive(true) // RootView initial-enabled onChange: .active.
        await transport.emit(.state(.connecting))
        await transport.emit(.state(.offline))
        #expect(await settled { model.outage == .offline })

        await transport.emit(.state(.ready))
        #expect(await settled { model.outage == nil })
    }

    /// A model whose transport the app stopped on suspend, with the stop's `.offline` applied.
    private func ownStop() async throws -> (AppModel, ScriptedTransport) {
        let (model, transport) = try await opened()
        model.setActive(true) // RootView initial onChange: .active.
        model.setActive(false) // RootView initial-enabled onChange: .inactive from .active.
        let visit = model.enterBackground() // RootView onChange: .background.
        model.suspend(visit: visit) // RootView .background handler: the drain finishes in the same visit.
        try #require(await stops(transport, reach: 1))
        try #require(await settled { model.state == .offline })
        return (model, transport)
    }
}
