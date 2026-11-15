import Testing
import YorozuWire

@Suite struct OutageMemoryTests {
    @Test func aHostOutageSurvivesTheAppsOwnStop() {
        var memory = OutageMemory()
        memory.apply(.hostOffline)
        memory.appStops()
        memory.apply(.offline)
        #expect(memory.outage == .hostOffline)
        #expect(memory.link == .stoppedByApp)
    }

    @Test func reconnectingKeepsTheOutageAndReadyClearsIt() {
        var memory = OutageMemory()
        memory.apply(.offline)
        memory.apply(.connecting)
        memory.apply(.handshaking)
        #expect(memory.outage == .offline)
        memory.apply(.ready)
        #expect(memory.outage == nil)
    }

    @Test func anOfflineAfterTheAppsOwnStopIsNoOutage() {
        var memory = OutageMemory()
        memory.appStops()
        memory.apply(.offline)
        #expect(memory.outage == nil)
    }

    @Test func runningAgainRearmsTheOutage() {
        var memory = OutageMemory()
        memory.appStops()
        memory.appRuns()
        memory.apply(.offline)
        #expect(memory.outage == .offline)
    }

    @Test func resetClearsTheOutageAndRuns() {
        var memory = OutageMemory()
        memory.apply(.hostOffline)
        memory.appStops()
        memory.reset()
        #expect(memory == OutageMemory())
    }
}
