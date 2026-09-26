import Foundation
import Testing

@testable import YorozuShared

private let sampleEvent = YorozuEvent(
    id: "e1",
    threadId: "home",
    ts: 1,
    agentId: "main",
    payload: .message(MessageData(role: .user, text: "hi", attachments: []))
)

/// The good envelope as a mutable JSON object, so a test can break one field and nothing else.
private func envelopeJSON() throws -> [String: Any] {
    let data = try ChannelEnvelope(seq: 1, event: sampleEvent).encoded()
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test func envelopeRoundTrips() throws {
    let envelope = ChannelEnvelope(seq: 1, event: sampleEvent)
    #expect(try ChannelEnvelope.decode(envelope.encoded()) == envelope)
}

/// The TypeScript side reads exactly these two keys; anything extra would be a wire change.
@Test func envelopeCarriesOnlySeqAndEvent() throws {
    #expect(Set(try envelopeJSON().keys) == ["seq", "event"])
}

/// A seq that could never have been sent is a malformed frame, dropped like a replay.
@Test func envelopeRejectsSeqBelowOne() throws {
    var json = try envelopeJSON()
    json["seq"] = 0
    #expect(throws: (any Error).self) {
        try ChannelEnvelope.decode(JSONSerialization.data(withJSONObject: json))
    }
}

@Test func envelopeRejectsMissingSeq() throws {
    var json = try envelopeJSON()
    json.removeValue(forKey: "seq")
    #expect(throws: (any Error).self) {
        try ChannelEnvelope.decode(JSONSerialization.data(withJSONObject: json))
    }
}

@Test func envelopeRejectsNonIntegerSeq() throws {
    var json = try envelopeJSON()
    json["seq"] = 1.5
    #expect(throws: (any Error).self) {
        try ChannelEnvelope.decode(JSONSerialization.data(withJSONObject: json))
    }
}

/// TypeScript's `Number.isSafeInteger` bound, so a seq one side accepts the other does too.
@Test func envelopeRejectsSeqPastTheSafeInteger() throws {
    var json = try envelopeJSON()
    json["seq"] = ChannelEnvelope.maxSeq + 1
    #expect(throws: (any Error).self) {
        try ChannelEnvelope.decode(JSONSerialization.data(withJSONObject: json))
    }
    json["seq"] = ChannelEnvelope.maxSeq
    #expect(try ChannelEnvelope.decode(JSONSerialization.data(withJSONObject: json)).seq == ChannelEnvelope.maxSeq)
}

/// A field neither side knows yet is not a reason to drop the box.
@Test func envelopeIgnoresExtraFields() throws {
    var json = try envelopeJSON()
    json["later"] = "field"
    #expect(try ChannelEnvelope.decode(JSONSerialization.data(withJSONObject: json)).seq == 1)
}

/// Decrypting is not what makes the event trusted: one that is not an event is refused.
@Test func envelopeRejectsAnEventThatIsNotOne() throws {
    var json = try envelopeJSON()
    json["event"] = ["id": "e1", "kind": "not-a-kind"]
    #expect(throws: (any Error).self) {
        try ChannelEnvelope.decode(JSONSerialization.data(withJSONObject: json))
    }
}

/// Exactly what `encodeEnvelope` in channel.ts writes, key order and integer spelling included.
@Test func envelopeDecodesTypeScriptSpelling() throws {
    let text = """
        {"seq":42,"event":{"id":"e1","threadId":"home","ts":1,"agentId":"main","kind":"message","data":{"role":"user","text":"hi"}}}
        """
    let envelope = try ChannelEnvelope.decode(Data(text.utf8))
    #expect(envelope == ChannelEnvelope(seq: 42, event: sampleEvent))
}

@Test func counterNumbersFromOne() {
    var counter = ChannelCounter()
    #expect(counter.next() == 1)
    #expect(counter.next() == 2)
}

/// Equal or lower is a replay; only strictly higher advances.
@Test func counterAcceptsOnlyHigherSeq() {
    // Assigned first: `#expect` cannot call a mutating method inline.
    var counter = ChannelCounter()
    let first = counter.accept(1)
    let equal = counter.accept(1)
    let lower = counter.accept(0)
    let higher = counter.accept(3)
    let skipped = counter.accept(2)
    #expect(first)
    #expect(!equal)
    #expect(!lower)
    #expect(higher)
    #expect(!skipped)
    #expect(counter.recv == 3)
}

private func freshDefaults() throws -> (UserDefaults, String) {
    let suite = "yorozu.tests.channel.\(UUID().uuidString)"
    return (try #require(UserDefaults(suiteName: suite)), suite)
}

/// A relaunch builds a new store; it must see what the old one wrote.
@Test func storePersistsAcrossInstances() throws {
    let (defaults, suite) = try freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let own = YorozuCrypto.generateKeypair().publicKey
    let peer = YorozuCrypto.generateKeypair().publicKey
    try ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: peer)
        .save(ChannelCounter(send: 4, recv: 7))
    let reloaded = try ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: peer).load()
    #expect(reloaded == ChannelCounter(send: 4, recv: 7))
}

/// New keys mean new channel keys, and a fresh pair rightly starts from nothing.
@Test func storeKeysByPeer() throws {
    let (defaults, suite) = try freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let own = YorozuCrypto.generateKeypair().publicKey
    let peer = YorozuCrypto.generateKeypair().publicKey
    let other = YorozuCrypto.generateKeypair().publicKey
    try ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: peer)
        .save(ChannelCounter(send: 4, recv: 7))
    #expect(try ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: other).load() == nil)
}

/// Dropping the pairing drops its counters; another pairing's are untouched.
@Test func storeClearsOnlyItsOwnPairing() throws {
    let (defaults, suite) = try freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let own = YorozuCrypto.generateKeypair().publicKey
    let peer = YorozuCrypto.generateKeypair().publicKey
    let other = YorozuCrypto.generateKeypair().publicKey
    let store = ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: peer)
    try store.save(ChannelCounter(send: 4, recv: 7))
    try ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: other).save(ChannelCounter(send: 1, recv: 1))
    store.clear()
    #expect(try store.load() == nil)
    #expect(try ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: other).load() == ChannelCounter(send: 1, recv: 1))
}

/// A counter that starts over is not survivable — the Mac drops every box as a replay — so a
/// stored counter that cannot be read is an error, not a zero.
@Test func storeRefusesGarbage() throws {
    let (defaults, suite) = try freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let own = YorozuCrypto.generateKeypair().publicKey
    let peer = YorozuCrypto.generateKeypair().publicKey
    let key = "yorozu.channel.\(own.base64URLEncodedString()).\(peer.base64URLEncodedString())"
    defaults.set(Data("nope".utf8), forKey: key)
    #expect(throws: (any Error).self) {
        try ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: peer).load()
    }
}

// MARK: - ChannelCounterStorage through RelayClient

/// A storage the tests can look into: what the apps' Keychain-backed ones do, in memory.
private final class MemoryCounterStorage: ChannelCounterStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ChannelCounter?
    private var loadError: (any Error)?
    private(set) var saves = 0

    init(_ stored: ChannelCounter? = nil, loadError: (any Error)? = nil) {
        self.stored = stored
        self.loadError = loadError
    }

    var value: ChannelCounter? { lock.withLock { stored } }

    func load() throws -> ChannelCounter? {
        try lock.withLock {
            if let loadError { throw loadError }
            return stored
        }
    }

    func save(_ counter: ChannelCounter) throws {
        lock.withLock { stored = counter; saves += 1 }
    }

    func clear() throws {
        lock.withLock { stored = nil }
    }
}

private func relayClient(counters: any ChannelCounterStorage) throws -> (RelayClient, PhoneIdentity, YorozuCrypto.Keypair) {
    let mac = YorozuCrypto.generateKeypair()
    let identity = PhoneIdentity.generate()
    let pairing = QrPayload(
        relayUrl: "ws://127.0.0.1:1",
        macPubkey: mac.publicKey.base64URLEncodedString(),
        token: "t",
        roomId: "r"
    )
    return (try RelayClient(pairing: pairing, identity: identity, counters: counters), identity, mac)
}

private func greet(_ client: RelayClient, identity: PhoneIdentity, mac: YorozuCrypto.Keypair,
                   storage: MemoryCounterStorage, legacy: Bool = false, seq: Int = 1) async throws {
    let key = try legacy
        ? YorozuCrypto.deriveSessionKey(myPriv: mac.privateKey, theirPub: identity.sessionPublicKey)
        : YorozuCrypto.deriveChannelKeys(myPriv: mac.privateKey, theirPub: identity.sessionPublicKey, role: .mac).send
    func accept(_ list: ThreadListData, at number: Int) async throws {
        let greeting = YorozuEvent(id: "greeting-\(number)", threadId: "", ts: 1, agentId: "main",
            payload: .threadList(list))
        let plain = try legacy ? JSONEncoder().encode(greeting) : ChannelEnvelope(seq: number, event: greeting).encoded()
        let box = try YorozuCrypto.seal(key: key, plaintext: plain)
        let body = try JSONSerialization.data(withJSONObject: [
            "t": "box", "n": box.nonce.base64URLEncodedString(),
            "c": box.ciphertext.base64URLEncodedString(),
        ])
        await client.acceptFrame(body.base64URLEncodedString())
    }
    let priorSend = storage.value?.send ?? 0
    try await accept(ThreadListData(threads: [], peerInfoSupported: !legacy), at: seq)
    guard !legacy else { return }
    for _ in 0..<100 where (storage.value?.send ?? 0) == priorSend {
        try? await Task.sleep(for: .milliseconds(1))
    }
    let requestID = try #require(await client.peerInfoRequestID)
    try await accept(ThreadListData(threads: [], peerInfo: .local, peerInfoReplyTo: requestID), at: seq + 1)
}

/// The counter the client numbers from is the one the storage holds, and every number it
/// hands out is in the storage before the box is anywhere else — here, before `send` fails on
/// a socket that was never dialled.
@Test func relayClientNumbersFromTheStoredCounterAndSavesBeforeSending() async throws {
    let storage = MemoryCounterStorage(ChannelCounter(send: 41, recv: 7))
    let (client, identity, mac) = try relayClient(counters: storage)
    try await greet(client, identity: identity, mac: mac, storage: storage, seq: 8)
    await #expect(throws: (any Error).self) { try await client.send(sampleEvent) }
    #expect(storage.value == ChannelCounter(send: 43, recv: 9, peerInfoRequired: true))
    #expect(storage.saves == 5)
}

/// Nothing stored is a fresh pairing: the first box out is 1.
@Test func relayClientStartsFromOneWithEmptyStorage() async throws {
    let storage = MemoryCounterStorage()
    let (client, identity, mac) = try relayClient(counters: storage)
    try await greet(client, identity: identity, mac: mac, storage: storage)
    await #expect(throws: (any Error).self) { try await client.send(sampleEvent) }
    #expect(storage.value == ChannelCounter(send: 2, recv: 2, peerInfoRequired: true))
}

@Test func legacyMacGreetingLetsNewClientSendWithoutNumberedEnvelope() async throws {
    let storage = MemoryCounterStorage()
    let (client, identity, mac) = try relayClient(counters: storage)
    // Before the greeting, no request can be sent in the wrong wire format.
    await #expect(throws: (any Error).self) { try await client.send(sampleEvent) }
    #expect(storage.saves == 0)
    try await greet(client, identity: identity, mac: mac, storage: storage, legacy: true)
    await #expect(throws: (any Error).self) { try await client.send(sampleEvent) }
    #expect(storage.saves == 0)
}

@Test func upgradedMacMovesExistingPairingToNumberedChannel() async throws {
    let storage = MemoryCounterStorage()
    let (client, identity, mac) = try relayClient(counters: storage)
    try await greet(client, identity: identity, mac: mac, storage: storage, legacy: true)
    let renewed = try RelayClient(pairing: QrPayload(relayUrl: "ws://127.0.0.1:1",
        macPubkey: mac.publicKey.base64URLEncodedString(), token: "t", roomId: "r"),
        identity: identity, counters: storage)
    try await greet(renewed, identity: identity, mac: mac, storage: storage)
    await #expect(throws: (any Error).self) { try await renewed.send(sampleEvent) }
    #expect(storage.value == ChannelCounter(send: 2, recv: 2, peerInfoRequired: true))
}

/// Storage that cannot be read is refused at construction rather than silently started over.
@Test func relayClientRefusesUnreadableStorage() {
    let storage = MemoryCounterStorage(loadError: YorozuCrypto.CryptoError.malformed("unreadable"))
    #expect(throws: (any Error).self) { try relayClient(counters: storage) }
}

// MARK: - The pairing record the apps keep the counter in

/// Field for field what `PairingStore.Stored` (iOS) and `MacPairingStore.Stored` (Mac) declare:
/// a synthesized `Codable` with `counters` optional, so a record written before the counter
/// moved in still decodes. The apps' own types cannot be imported into this package's tests,
/// so the declaration is mirrored here and the JSON is what those apps wrote.
private struct StoredPairingRecord: Codable, Equatable {
    var pairing: QrPayload
    var identity: PhoneIdentity
    var paired: Bool?
    var pairedAt: Date?
    var counters: ChannelCounter?
}

private let identityJSON = """
    {"signingPrivateKey":"AA==","signingPublicKey":"AQ==","sessionPrivateKey":"Ag==","sessionPublicKey":"Aw=="}
    """

/// A record from before `counters` existed decodes with none, and a client built from it
/// starts from one rather than refusing the pairing.
@Test func pairingRecordWithoutCountersDecodes() throws {
    let text = """
        {"pairing":{"v":1,"relayUrl":"ws://127.0.0.1:1","macPubkey":"AAA","token":"","roomId":"r"},
         "identity":\(identityJSON),"paired":true,"pairedAt":0}
        """
    let record = try JSONDecoder().decode(StoredPairingRecord.self, from: Data(text.utf8))
    #expect(record.counters == nil)
    #expect(record.paired == true)
    #expect(record.identity.sessionPublicKey == Data([3]))
}

/// The oldest shape of all — no `paired`, no `pairedAt` — decodes too.
@Test func pairingRecordFromBeforePairedDecodes() throws {
    let text = """
        {"pairing":{"v":1,"relayUrl":"ws://127.0.0.1:1","macPubkey":"AAA","token":"t"},
         "identity":\(identityJSON)}
        """
    let record = try JSONDecoder().decode(StoredPairingRecord.self, from: Data(text.utf8))
    #expect(record.counters == nil)
    #expect(record.paired == nil)
}

/// Counters written into the record come back as written, and the rest of the record with them.
@Test func pairingRecordRoundTripsCounters() throws {
    var record = try JSONDecoder().decode(
        StoredPairingRecord.self,
        from: Data("""
            {"pairing":{"v":1,"relayUrl":"ws://127.0.0.1:1","macPubkey":"AAA","token":"t"},
             "identity":\(identityJSON)}
            """.utf8)
    )
    record.counters = ChannelCounter(send: 12, recv: 34)
    let reloaded = try JSONDecoder().decode(StoredPairingRecord.self, from: JSONEncoder().encode(record))
    #expect(reloaded == record)
    #expect(reloaded.counters == ChannelCounter(send: 12, recv: 34))
}
