import Foundation

/// Shape of fixtures/<source>-vectors.json. Every field is base64url except `source` and `qr`.
/// Written by YorozuFixtureGen, read by the TypeScript suite (and vice versa).
public struct Vectors: Codable, Equatable, Sendable {
    public var source: String
    public var alicePriv: String
    public var alicePub: String
    public var bobPriv: String
    public var bobPub: String
    /// deriveSessionKey(alicePriv, bobPub).
    public var sessionKey: String
    /// deriveChannelKeys(alicePriv, bobPub, mac).send: alice is the Mac, bob the device.
    public var channelMacToDevice: String
    /// deriveChannelKeys(alicePriv, bobPub, mac).recv.
    public var channelDeviceToMac: String
    /// The seq inside `channelCiphertext`: ``seq``.
    public var channelSeq: Int
    /// A `ChannelEnvelope` of ``seq`` and ``event``, sealed by the Mac under `channelMacToDevice`.
    public var channelNonce: String
    public var channelCiphertext: String
    public var nonce: String
    public var plaintext: String
    public var ciphertext: String
    public var signPriv: String
    public var signPub: String
    /// Ed25519 signature over the plaintext bytes.
    public var signature: String
    /// Encoded QrPayload, verbatim.
    public var qr: String

    public init(
        source: String,
        alicePriv: String,
        alicePub: String,
        bobPriv: String,
        bobPub: String,
        sessionKey: String,
        channelMacToDevice: String,
        channelDeviceToMac: String,
        channelSeq: Int,
        channelNonce: String,
        channelCiphertext: String,
        nonce: String,
        plaintext: String,
        ciphertext: String,
        signPriv: String,
        signPub: String,
        signature: String,
        qr: String
    ) {
        self.source = source
        self.alicePriv = alicePriv
        self.alicePub = alicePub
        self.bobPriv = bobPriv
        self.bobPub = bobPub
        self.sessionKey = sessionKey
        self.channelMacToDevice = channelMacToDevice
        self.channelDeviceToMac = channelDeviceToMac
        self.channelSeq = channelSeq
        self.channelNonce = channelNonce
        self.channelCiphertext = channelCiphertext
        self.nonce = nonce
        self.plaintext = plaintext
        self.ciphertext = ciphertext
        self.signPriv = signPriv
        self.signPub = signPub
        self.signature = signature
        self.qr = qr
    }

    /// The one string both generators seal, so a mismatch is readable in test output.
    public static let plaintextString = "yorozu cross-language vector"

    /// The one envelope both generators seal on the live channel. Mirrors `VECTOR_SEQ` and
    /// `VECTOR_EVENT` in vectors.ts field for field: the JSON either side writes must read as
    /// exactly this on the other.
    public static let seq = 7
    public static let event = YorozuEvent(
        id: "vector-event",
        threadId: "vector-thread",
        ts: 1_700_000_000_000,
        agentId: "mac",
        payload: .message(MessageData(role: .agent, text: plaintextString, done: true))
    )

    /// fixtures/ lives at the repo root, outside this package, so locate it from the source path.
    public static func path(source: String, from file: StaticString = #filePath) -> URL {
        var url = URL(fileURLWithPath: "\(file)")
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appending(path: "fixtures/\(source)-vectors.json")
    }
}
