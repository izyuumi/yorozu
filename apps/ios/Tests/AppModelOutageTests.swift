import Foundation
import Testing
import YorozuWire

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
        model.setActive(true)
        model.setActive(false)
        await transport.emit(.state(.offline))
        #expect(await settled { model.outage == .offline })
    }

    @Test func anOfflineDuringTheBackgroundDrainIsAnOutage() async throws {
        let (model, transport) = try await opened()
        model.setActive(true)
        model.setActive(false)
        _ = model.enterBackground()
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
        model.setActive(true)
        model.setActive(false)
        let visit = model.enterBackground()
        model.prewarm()
        model.setActive(false)
        model.resume()
        model.setActive(true)
        model.suspend(visit: visit)

        try await Task.sleep(for: .milliseconds(600))
        #expect(await transport.stops == 0)
        #expect(model.active)
    }

    @Test func anOutageAfterTheOwnStopAndAReturnIsRecorded() async throws {
        let (model, transport) = try await ownStop()
        model.prewarm()
        model.resume()
        model.setActive(true)
        await transport.emit(.state(.connecting))
        await transport.emit(.state(.offline))
        #expect(await settled { model.outage == .offline })

        await transport.emit(.state(.ready))
        #expect(await settled { model.outage == nil })
    }

    private func ownStop() async throws -> (AppModel, ScriptedTransport) {
        let (model, transport) = try await opened()
        model.setActive(true)
        model.setActive(false)
        let visit = model.enterBackground()
        model.suspend(visit: visit)
        try #require(await stops(transport, reach: 1))
        try #require(await settled { model.state == .offline })
        return (model, transport)
    }
}
