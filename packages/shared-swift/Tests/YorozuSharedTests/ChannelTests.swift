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
    let reloaded = ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: peer).load()
    #expect(reloaded == ChannelCounter(send: 4, recv: 7))
}

/// New keys mean new channel keys, and a fresh pair rightly starts from zero.
@Test func storeKeysByPeer() throws {
    let (defaults, suite) = try freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let own = YorozuCrypto.generateKeypair().publicKey
    let peer = YorozuCrypto.generateKeypair().publicKey
    let other = YorozuCrypto.generateKeypair().publicKey
    try ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: peer)
        .save(ChannelCounter(send: 4, recv: 7))
    #expect(ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: other).load() == ChannelCounter())
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
    #expect(store.load() == ChannelCounter())
    #expect(ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: other).load() == ChannelCounter(send: 1, recv: 1))
}

/// A counter that starts over is survivable; a crash on launch is not.
@Test func storeReadsGarbageAsZero() throws {
    let (defaults, suite) = try freshDefaults()
    defer { defaults.removePersistentDomain(forName: suite) }
    let own = YorozuCrypto.generateKeypair().publicKey
    let peer = YorozuCrypto.generateKeypair().publicKey
    let key = "yorozu.channel.\(own.base64URLEncodedString()).\(peer.base64URLEncodedString())"
    defaults.set(Data("nope".utf8), forKey: key)
    #expect(ChannelCounterStore(defaults: defaults, ownPub: own, peerPub: peer).load() == ChannelCounter())
}
