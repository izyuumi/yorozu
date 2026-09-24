import Testing
import Foundation
import YorozuShared

@Test func pairingDoesNotSucceedBeforeFreshBaselineArrives() {
    let progress = DevicePairingProgress()
    let existing = DeviceInfo(pub: "existing", via: .relay, lastSeen: 1, online: true)
    #expect(progress.baseline == nil)
    #expect(!progress.newlyPaired(in: [existing]))
}

private actor DeviceSnapshotTransport: ChatTransport {
    private let stream: AsyncStream<TransportUpdate>
    private let continuation: AsyncStream<TransportUpdate>.Continuation
    init() { (stream, continuation) = AsyncStream.makeStream() }
    func connect() -> AsyncStream<TransportUpdate> { stream }
    func send(_ event: YorozuEvent) {}
    func close() { continuation.finish() }
    func yield(_ event: YorozuEvent) { continuation.yield(.event(event)) }
}

@MainActor
@Test func emptyDeviceSnapshotStillEstablishesFreshness() async throws {
    let transport = DeviceSnapshotTransport()
    let model = ChatModel(transport: transport)
    model.start()
    defer { model.close() }
    #expect(model.deviceListRevision == 0)
    for expectedRevision in 1...2 {
        await transport.yield(YorozuEvent(id: "devices-\(expectedRevision)", threadId: "", ts: 1,
            agentId: "main", payload: .deviceList(DeviceListData(devices: []))))
        for _ in 0..<100 {
            if model.deviceListRevision == expectedRevision { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.deviceListRevision == expectedRevision)
        #expect(model.devices.isEmpty)
    }
}

@Test func pairingDetectsFastNewDeviceWithoutMovingBaseline() {
    var progress = DevicePairingProgress()
    let existing = DeviceInfo(pub: "existing", via: .relay, lastSeen: 1, online: true)
    let local = DeviceInfo(pub: "local", via: .local, lastSeen: 1, online: true)
    let newcomer = DeviceInfo(pub: "new", via: .relay, lastSeen: 2, online: true)
    progress.establishBaseline([existing, local])
    #expect(!progress.newlyPaired(in: [existing, local]))
    // No delay between snapshots: a fast scanner must still count as a successful pair.
    progress.establishBaseline([existing, local, newcomer])
    #expect(progress.newlyPaired(in: [existing, local, newcomer]))
}

@Test func pairingIgnoresNewLocalConnectionsButAcceptsFirstRelayDevice() {
    var progress = DevicePairingProgress()
    progress.establishBaseline([])
    let local = DeviceInfo(pub: "local", via: .local, lastSeen: 1, online: true)
    #expect(!progress.newlyPaired(in: [local]))
    let first = DeviceInfo(pub: "first", via: .relay, lastSeen: 2, online: true)
    #expect(progress.newlyPaired(in: [local, first]))
}
