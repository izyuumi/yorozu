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

/// Persists a ``ChannelCounter`` so a relaunch neither reuses a `seq` it already sent nor
/// accepts one it already saw. Keyed by both X25519 public keys: new keys on either side mean
/// new channel keys, and a fresh pair rightly starts from zero.
public struct ChannelCounterStore: Sendable {
    /// `UserDefaults` is documented thread-safe; the SDK just does not spell it `Sendable`.
    nonisolated(unsafe) private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults, ownPub: Data, peerPub: Data) {
        self.defaults = defaults
        self.key = "yorozu.channel.\(ownPub.base64URLEncodedString()).\(peerPub.base64URLEncodedString())"
    }

    /// Zero when nothing is stored, or when what is stored cannot be read. Starting over is
    /// survivable — the Mac drops our boxes as replays until `send` climbs past what it last
    /// took, and takes nothing older than what we last accepted as new — where refusing to
    /// launch is not.
    public func load() -> ChannelCounter {
        guard let data = defaults.data(forKey: key),
            let counter = try? JSONDecoder().decode(ChannelCounter.self, from: data)
        else { return ChannelCounter() }
        return counter
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
