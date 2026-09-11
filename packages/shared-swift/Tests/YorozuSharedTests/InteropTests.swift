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
