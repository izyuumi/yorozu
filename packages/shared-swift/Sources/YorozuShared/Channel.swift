import Foundation

/// What a live-channel box carries: the event and where it stands in its sender's order.
/// `seq` is inside the ciphertext, so the relay can neither read nor rewrite it, and a receiver
/// that remembers the last one it accepted can tell a replayed box from a fresh one. Mirrors
/// `ChannelEnvelope` in packages/shared/src/channel.ts.
public struct ChannelEnvelope: Codable, Equatable, Sendable {
    /// Starts at 1 and only ever grows within one (peer, direction).
    public var seq: Int
    public var event: YorozuEvent

    public init(seq: Int, event: YorozuEvent) {
        self.seq = seq
        self.event = event
    }

    /// The largest `seq` either end accepts: JavaScript's `Number.MAX_SAFE_INTEGER`, so both
    /// languages agree on the whole domain. Mirrors `MAX_SEQ` in channel.ts.
    public static let maxSeq = 9_007_199_254_740_991

    /// Throws on a `seq` that could never have been sent — missing, not an integer, below 1 or
    /// past ``maxSeq`` — so a malformed frame and a replayed one end up in the same place:
    /// dropped. The event is decoded by ``YorozuEvent``'s own decoder, which is what decides
    /// whether its `kind` and `data` make sense; decrypting is not what makes it trusted.
    public static func decode(_ data: Data) throws -> ChannelEnvelope {
        let envelope = try JSONDecoder().decode(ChannelEnvelope.self, from: data)
        guard (1...maxSeq).contains(envelope.seq) else {
            throw YorozuCrypto.CryptoError.malformed("envelope seq out of range")
        }
        return envelope
    }

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }
}

/// Both directions of one peer's sequence numbers: the last `seq` we sent and the last we
/// accepted. Kept apart because the two sides count independently.
public struct ChannelCounter: Codable, Equatable, Sendable {
    public var send: Int
    public var recv: Int

    public init(send: Int = 0, recv: Int = 0) {
        self.send = send
        self.recv = recv
    }

    /// The `seq` for the next box out; the first is 1.
    public mutating func next() -> Int {
        send += 1
        return send
    }

    /// True, and remembered, only for a `seq` beyond the last accepted one. Equal or lower is
    /// a replay, or a reordering old enough that treating it as one costs nothing.
    public mutating func accept(_ seq: Int) -> Bool {
        guard seq > recv else { return false }
        recv = seq
        return true
    }
}

/// Where a ``ChannelCounter`` lives between launches. Whatever holds it must live exactly as
/// long as the identity it counts for: the counter is what tells a replay from a fresh box, so
/// keys that survive without it are keys the peer will drop everything from as a replay — and
/// keys that are dropped must take it with them, or a re-pair under the same keys would start
/// numbering from where the old one left off.
///
/// The apps keep it inside the pairing record in the Keychain, next to the identity, which is
/// what a reinstall on iOS keeps. ``ChannelCounterStore`` is the `UserDefaults` fallback for a
/// caller that passes nothing; a reinstall loses it.
public protocol ChannelCounterStorage: Sendable {
    /// The counter as last saved, or nil when none has been. Throws when something is stored
    /// but cannot be read: a counter that starts over is not survivable — every box out is a
    /// replay to the peer until `send` climbs past what it last took, and every box in is dropped
    /// as new when it should have been a replay — so the caller is told rather than left to start
    /// from zero.
    func load() throws -> ChannelCounter?
    /// Must have written the counter through before returning: a `seq` handed out after this
    /// call is one a relaunch will not hand out again. Throws only if it could not, and the
    /// caller must then not send or accept.
    func save(_ counter: ChannelCounter) throws
    /// Forgets the counter, for when the pairing itself is dropped.
    func clear() throws
}

/// The `UserDefaults` ``ChannelCounterStorage``: keyed by both X25519 public keys, so new keys
/// on either side — which mean new channel keys — rightly start from zero. A fallback for
/// callers that pass ``RelayClient`` nothing better; it does not survive an iOS reinstall, so
/// the apps store the counter with the identity instead.
public struct ChannelCounterStore: ChannelCounterStorage {
    /// `UserDefaults` is documented thread-safe; the SDK just does not spell it `Sendable`.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, ownPub: Data, peerPub: Data) {
        self.defaults = defaults
        self.key = "yorozu.channel.\(ownPub.base64URLEncodedString()).\(peerPub.base64URLEncodedString())"
    }

    /// Nil when nothing is stored. What is stored but cannot be read throws: see
    /// ``ChannelCounterStorage/load()`` for why zero would be the wrong answer.
    public func load() throws -> ChannelCounter? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(ChannelCounter.self, from: data)
        } catch {
            throw YorozuCrypto.CryptoError.malformed("stored channel counter is unreadable")
        }
    }

    /// Writes the counter through before returning: `UserDefaults.set` updates the in-process
    /// store synchronously, so a `seq` handed out after this call is one a relaunch will not
    /// hand out again. Throws only if the counter cannot be encoded, and the caller must then
    /// not send: a `seq` that went out unrecorded is one a relaunch would reuse.
    public func save(_ counter: ChannelCounter) throws {
        defaults.set(try JSONEncoder().encode(counter), forKey: key)
    }

    /// Forgets the counter for this pairing. For when the pairing itself is dropped: the
    /// record would otherwise outlive the keys it belongs to.
    public func clear() {
        defaults.removeObject(forKey: key)
    }
}
