import Foundation
import Testing
@testable import YorozuShared

@Test func peerCapabilitiesDriveCompatibilityWithoutVersionComparisons() {
    let local = PeerInfoData(appVersion: "1.0")
    #expect(local.compatibility(with: nil) == .legacy)
    #expect(local.compatibility(with: PeerInfoData(appVersion: "99.0-beta")) ==
        .compatible(version: 1, capabilities: ["peer-info", "host-name", "channel-sequence",
            "admission-status-v1", "admission-expiry-v1", "exact-stop-v1", "offline-approval-v1", "thread-search-v1", "attachment-chunks-v1"]))
    if case .updateRequired = local.compatibility(with: PeerInfoData(appVersion: "1.0", protocolMin: 2, protocolMax: 3)) {} else {
        Issue.record("Disjoint protocols must require an update")
    }
    if case .updateRequired = local.compatibility(with: PeerInfoData(appVersion: "1.0", capabilities: ["peer-info"], requiredCapabilities: [])) {} else {
        Issue.record("Required replay protection cannot be downgraded")
    }
    let oldHost = PeerInfoData(appVersion: "old", capabilities: ["peer-info", "host-name", "channel-sequence",
        "admission-status-v1", "admission-expiry-v1"])
    if case .updateRequired = PeerInfoData.local.compatibility(with: oldHost) {} else {
        Issue.record("New client must require exact-run Stop")
    }
    let upgradedHost = PeerInfoData(appVersion: "new", requiredCapabilities: ["channel-sequence", "exact-stop-v1", "offline-approval-v1"])
    if case .updateRequired = oldHost.compatibility(with: upgradedHost) {} else {
        Issue.record("Old client must update before its Stop button can claim success")
    }
}

@Test func peerSchemaBoundsUTF8FieldsAndRejectsMalformedClaims() throws {
    let data = try JSONEncoder().encode(PeerInfoData(appVersion: "1.0", computerName: "仕事用 Mac"))
    let base = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(try JSONDecoder().decode(PeerInfoData.self, from: data).computerName == "仕事用 Mac")
    let invalid: [[String: Any]] = [
        ["appVersion": String(repeating: "a", count: 65)], ["appVersion": "v1\nforged"],
        ["computerName": String(repeating: "猫", count: 86)], ["computerName": NSNull()],
        ["protocolMin": 0], ["protocolMin": 2], ["protocolMax": 65_536], ["protocolMax": 1.5],
        ["capabilities": ["peer-info", "peer-info"]], ["capabilities": ["bad capability"]], ["capabilities": ["peer-info\n"]],
        ["requiredCapabilities": ["unadvertised"]], ["capabilities": (0..<33).map { "cap-\($0)" }],
    ]
    for change in invalid {
        let bad = base.merging(change) { _, new in new }
        #expect(throws: (any Error).self) { try JSONDecoder().decode(PeerInfoData.self, from: JSONSerialization.data(withJSONObject: bad)) }
    }
}

private final class PeerCounters: ChannelCounterStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var counter = ChannelCounter()
    func load() throws -> ChannelCounter? { lock.withLock { counter } }
    func save(_ value: ChannelCounter) throws { lock.withLock { counter = value } }
    func clear() throws { lock.withLock { counter = ChannelCounter() } }
}

private struct PeerWire {
    let identity = PhoneIdentity.generate()
    let mac = YorozuCrypto.generateKeypair()
    let counters = PeerCounters()
    func client() throws -> RelayClient {
        try RelayClient(pairing: QrPayload(relayUrl: "ws://127.0.0.1:1", macPubkey: mac.publicKey.base64URLEncodedString(), token: "t", roomId: "r"),
            identity: identity, counters: counters)
    }
    func frame(_ list: ThreadListData, seq: Int, tamper: Bool = false) throws -> String {
        let event = YorozuEvent(id: "greeting", threadId: "", ts: 1, agentId: "main", payload: .threadList(list))
        var plain = try ChannelEnvelope(seq: seq, event: event).encoded()
        if tamper {
            var json = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
            var eventJSON = try #require(json["event"] as? [String: Any])
            eventJSON["data"] = ["threads": [], "peerInfo": ["appVersion": String(repeating: "x", count: 65)]]
            json["event"] = eventJSON
            plain = try JSONSerialization.data(withJSONObject: json)
        }
        let key = try YorozuCrypto.deriveChannelKeys(myPriv: mac.privateKey, theirPub: identity.sessionPublicKey, role: .mac).send
        let box = try YorozuCrypto.seal(key: key, plaintext: plain)
        return try JSONSerialization.data(withJSONObject: ["t": "box", "n": box.nonce.base64URLEncodedString(), "c": box.ciphertext.base64URLEncodedString()]).base64URLEncodedString()
    }
}

@Test func peerNameRequiresAuthenticatedNegotiationAndCannotCrossHostKeys() async throws {
    let wire = PeerWire(), otherWire = PeerWire()
    let client = try wire.client(), other = try otherWire.client()
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfoSupported: true), seq: 1))
    let info = PeerInfoData(appVersion: "2.0", computerName: "Office Mac")
    let response = try wire.frame(ThreadListData(threads: [], peerInfo: info, peerInfoReplyTo: await client.peerInfoRequestID), seq: 2)
    await client.acceptFrame(response)
    await other.acceptFrame(response)
    #expect(await client.peerInfo?.computerName == "Office Mac")
    #expect(await other.peerInfo == nil)
    #expect(try wire.counters.load()?.recv == 2)
    #expect(try otherWire.counters.load()?.recv == 0)
}

@Test func peerMismatchAndMalformedClaimStopOnlyAffectedConnection() async throws {
    for malformed in [false, true] {
        let wire = PeerWire(), healthyWire = PeerWire()
        let client = try wire.client(), healthy = try healthyWire.client()
        await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfoSupported: true), seq: 1))
        let info = PeerInfoData(appVersion: "future", protocolMin: 2, protocolMax: 3)
        await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: info, peerInfoReplyTo: await client.peerInfoRequestID), seq: 2, tamper: malformed))
        if case .updateRequired = await client.compatibility {} else { Issue.record("Incompatible peer remained enabled") }
        // Later metadata must not rescue an incompatible connection or change its counters.
        await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: .local), seq: 3))
        #expect(await client.peerInfo == nil)
        #expect(try wire.counters.load()?.recv == 2)
        await healthy.acceptFrame(try healthyWire.frame(ThreadListData(threads: [], peerInfoSupported: true), seq: 1))
        await healthy.acceptFrame(try healthyWire.frame(ThreadListData(threads: [], peerInfo: .local,
            peerInfoReplyTo: await healthy.peerInfoRequestID), seq: 2))
        if case .compatible = await healthy.compatibility {} else { Issue.record("Healthy host did not negotiate") }
        #expect(try healthyWire.counters.load()?.recv == 2)
    }
}

@Test func replayedMalformedPeerClaimCannotDisableCompatibleConnection() async throws {
    let wire = PeerWire(), client = try wire.client()
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfoSupported: true), seq: 1))
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: .local, peerInfoReplyTo: await client.peerInfoRequestID), seq: 2))
    await client.acceptFrame(try wire.frame(ThreadListData(threads: []), seq: 1, tamper: true))
    if case .compatible = await client.compatibility {} else { Issue.record("Replayed invalid claim disabled connection") }
    #expect(try wire.counters.load()?.recv == 2)
}


@Test func peerRequirementSurvivesRestartWithoutResettingCounters() async throws {
    let wire = PeerWire()
    let first = try wire.client()
    await first.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfoSupported: true), seq: 10))
    await first.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: .local, peerInfoReplyTo: await first.peerInfoRequestID), seq: 11))
    #expect(try wire.counters.load()?.peerInfoRequired == true)
    await first.close()
    let reopened = try wire.client()
    // A captured old greeting cannot negotiate away the security requirement after relaunch.
    let event = YorozuEvent(id: "old", threadId: "", ts: 1, agentId: "main", payload: .threadList(ThreadListData(threads: [])))
    let key = try YorozuCrypto.deriveSessionKey(myPriv: wire.mac.privateKey, theirPub: wire.identity.sessionPublicKey)
    let box = try YorozuCrypto.seal(key: key, plaintext: JSONEncoder().encode(event))
    let frame = try JSONSerialization.data(withJSONObject: ["t": "box", "n": box.nonce.base64URLEncodedString(), "c": box.ciphertext.base64URLEncodedString()]).base64URLEncodedString()
    await reopened.acceptFrame(frame)
    #expect(try wire.counters.load()?.recv == 11)
    await #expect(throws: (any Error).self) { try await reopened.send(event) }
    // The current host negotiates again; the counters keep increasing under the same keys.
    await reopened.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfoSupported: true), seq: 12))
    await reopened.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: .local, peerInfoReplyTo: await reopened.peerInfoRequestID), seq: 13))
    if case .compatible = await reopened.compatibility {} else { Issue.record("Fresh negotiation did not reconnect") }
    #expect(try wire.counters.load()?.recv == 13)
}

private struct PeerReceiveTransport: ChatTransport {
    let client: RelayClient
    func connect() async -> AsyncStream<TransportUpdate> { await client.makeUpdateStream() }
    func send(_ event: YorozuEvent) async throws { try await client.send(event) }
    func close() async { await client.close() }
}

@MainActor
@Test func peerNegotiationPreservesRelayPresenceAndEnablesOutboxDelivery() async throws {
    let wire = PeerWire(), client = try wire.client()
    let model = ChatModel(transport: PeerReceiveTransport(client: client))
    model.start()
    // Give ChatModel's reader a stream before delivering the relay's ordered control frames.
    for _ in 0..<20 { await Task.yield() }
    try await client.handle("{\"type\":\"joined\",\"ownerOnline\":true}")
    for _ in 0..<300 where !model.ownerOnline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(model.ownerOnline)
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfoSupported: true), seq: 1))
    #expect(!model.canDeliver)
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: .local, peerInfoReplyTo: await client.peerInfoRequestID), seq: 2))
    for _ in 0..<300 where !model.canDeliver { try await Task.sleep(for: .milliseconds(1)) }
    #expect(model.state == .paired)
    #expect(model.ownerOnline)
    #expect(model.canDeliver)
    await model.shutdown()
}

@MainActor
@Test func returningHostRequiresFreshAuthenticatedReply() async throws {
    let wire = PeerWire(), client = try wire.client()
    let model = ChatModel(transport: PeerReceiveTransport(client: client))
    model.start()
    for _ in 0..<20 { await Task.yield() }
    try await client.handle("{\"type\":\"joined\",\"ownerOnline\":true}")
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfoSupported: true), seq: 1))
    let oldRequest = try #require(await client.peerInfoRequestID)
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: .local, peerInfoReplyTo: oldRequest), seq: 2))
    for _ in 0..<300 where !model.canDeliver { try await Task.sleep(for: .milliseconds(1)) }
    #expect(model.canDeliver)

    try await client.handle("{\"type\":\"owner\",\"online\":false}")
    for _ in 0..<300 where model.state != .joined { try await Task.sleep(for: .milliseconds(1)) }
    #expect(!model.canDeliver)
    try await client.handle("{\"type\":\"owner\",\"online\":true}")
    for _ in 0..<300 where !model.ownerOnline { try await Task.sleep(for: .milliseconds(1)) }
    #expect(model.state == .joined)
    #expect(!model.canDeliver)

    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: .local, peerInfoReplyTo: oldRequest), seq: 3))
    #expect(!model.canDeliver)
    let newRequest = try #require(await client.peerInfoRequestID)
    #expect(newRequest != oldRequest)
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: .local, peerInfoReplyTo: newRequest), seq: 4))
    for _ in 0..<300 where !model.canDeliver { try await Task.sleep(for: .milliseconds(1)) }
    #expect(model.canDeliver)
    await model.shutdown()
}


@Test func peerMetadataBeforeHelloOnRejoinStartsFreshNegotiation() async throws {
    let wire = PeerWire(), client = try wire.client()
    // Host can broadcast its retained metadata before processing the new hello.
    let info = PeerInfoData(appVersion: "2.0", computerName: "Office Mac")
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: info, peerInfoError: "Previous client needed an update."), seq: 10))
    #expect(await client.peerInfo == nil)
    if case .updateRequired = await client.compatibility { Issue.record("Stale connection claim blocked rejoin") }
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: info, peerInfoError: "Still from the old connection."), seq: 11))
    #expect(await client.peerInfo == nil)
    if case .updateRequired = await client.compatibility { Issue.record("Second stale claim blocked rejoin") }
    await client.acceptFrame(try wire.frame(ThreadListData(threads: [], peerInfo: info, peerInfoReplyTo: await client.peerInfoRequestID), seq: 12))
    #expect(await client.peerInfo?.computerName == "Office Mac")
    if case .compatible = await client.compatibility {} else { Issue.record("New exchange did not complete") }
    #expect(try wire.counters.load()?.recv == 12)
}
