import Foundation
import Testing
import YorozuWire

@MainActor
@Suite struct AppModelSyncTests {
    private let harness: ModelHarness

    init() throws {
        harness = try ModelHarness()
        _ = try harness.store(paired: true)
    }

    private func historyRequests(_ transport: ScriptedTransport) async -> [WireEvent] {
        await transport.sent.filter {
            if case .historyRequest = $0 { return true }
            return false
        }
    }

    private func sent(_ request: WireEvent, over transport: ScriptedTransport) async -> Bool {
        for _ in 0..<100 {
            if await transport.sent.contains(request) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @Test func aLateHistoryAnswerIsAppliedWithoutAdvancingTheNextRequest() async throws {
        let ids = [harness.convId, WireEvent.newId(), WireEvent.newId()]
        harness.seed(ids.map { Conversation(id: $0, createdAt: 1, updatedAt: 1, rev: 1) })
        let transport = ScriptedTransport()
        await transport.setSendResult(true)
        harness.transports.fails = false
        harness.transports.scripted = transport
        await transport.emit(.state(.ready))
        await transport.emit(.sessionOpen(PeerInfo(app: "test")))
        let model = harness.makeModel()
        defer { model.unpair() }

        try #require(await sent(.convList(ConvList()), over: transport))
        let summaries = ids.map { ConvSummary(convId: $0, updatedAt: 1, rev: 1, title: "Synced") }
        await transport.emit(.event(.convList(ConvList(conversations: summaries))))
        try #require(await harness.settled { model.conversations[ids[0]]?.title == "Synced" })

        let requests = ids.map { WireEvent.historyRequest(HistoryRequest(convId: $0)) }
        model.open(ids[0])
        model.open(ids[1])
        try #require(await sent(requests[0], over: transport))

        await transport.emit(.event(.error(ErrorInfo(code: "internal", message: "History unavailable"))))
        try #require(await sent(requests[1], over: transport))
        model.open(ids[2])
        await transport.emit(.event(.history(History(convId: ids[0], items: [], more: false, rev: 2))))
        try #require(await harness.settled { model.conversations[ids[0]]?.rev == 2 })
        try await Task.sleep(for: .milliseconds(100))
        #expect(await historyRequests(transport) == Array(requests.prefix(2)))

        await transport.emit(.event(.history(History(convId: ids[1], items: [], more: false, rev: 2))))
        try #require(await sent(requests[2], over: transport))
        #expect(await historyRequests(transport) == requests)
    }
}
