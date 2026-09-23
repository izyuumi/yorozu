import Foundation
import Testing

@testable import YorozuShared

/// Decrypts the vectors TypeScript generated. The mirror of this test lives in
/// packages/shared/src/interop.test.ts and reads fixtures/swift-vectors.json.
@Test func swiftOpensTypeScriptVectors() throws {
    let url = Vectors.path(source: "ts")
    let vectors = try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    #expect(vectors.source == "ts")

    func bytes(_ text: String) throws -> Data {
        try #require(Data(base64URLEncoded: text))
    }

    // Same session key from the other half of the exchange.
    let key = try YorozuCrypto.deriveSessionKey(
        myPriv: bytes(vectors.bobPriv),
        theirPub: bytes(vectors.alicePub)
    )
    #expect(key.withUnsafeBytes { Data($0) } == (try bytes(vectors.sessionKey)))

    // Alice is the Mac, so the device's send key is her recv key and vice versa.
    let channel = try YorozuCrypto.deriveChannelKeys(
        myPriv: bytes(vectors.bobPriv),
        theirPub: bytes(vectors.alicePub),
        role: .device
    )
    #expect(channel.send.withUnsafeBytes { Data($0) } == (try bytes(vectors.channelDeviceToMac)))
    #expect(channel.recv.withUnsafeBytes { Data($0) } == (try bytes(vectors.channelMacToDevice)))

    // A live-channel box the TypeScript Mac sealed opens under the device's recv key, and its
    // envelope reads as the same seq and event TypeScript put in it — field names and integer
    // encoding included. Under the device's send key, as if reflected, or under the preview
    // key, it does not open.
    #expect(vectors.channelSeq == Vectors.seq)
    let envelope = try ChannelEnvelope.decode(
        try YorozuCrypto.open(
            key: channel.recv,
            nonce: bytes(vectors.channelNonce),
            ciphertext: bytes(vectors.channelCiphertext)
        )
    )
    #expect(envelope == ChannelEnvelope(seq: Vectors.seq, event: Vectors.event))
    #expect(throws: (any Error).self) {
        try YorozuCrypto.open(
            key: channel.send,
            nonce: bytes(vectors.channelNonce),
            ciphertext: bytes(vectors.channelCiphertext)
        )
    }
    #expect(throws: (any Error).self) {
        try YorozuCrypto.open(
            key: key,
            nonce: bytes(vectors.channelNonce),
            ciphertext: bytes(vectors.channelCiphertext)
        )
    }

    let opened = try YorozuCrypto.open(
        key: key,
        nonce: bytes(vectors.nonce),
        ciphertext: bytes(vectors.ciphertext)
    )
    #expect(opened == (try bytes(vectors.plaintext)))
    #expect(String(decoding: opened, as: UTF8.self) == Vectors.plaintextString)

    #expect(
        YorozuCrypto.verifyFrame(
            pub: try bytes(vectors.signPub),
            data: opened,
            signature: try bytes(vectors.signature)
        )
    )

    let qr = try QrPayload.decode(vectors.qr)
    #expect(qr.v == 1)
    #expect(qr.macPubkey == vectors.alicePub)
}
