/// Writes fixtures/swift-vectors.json, the test vectors the TypeScript suite decrypts.
/// Run with `swift run --package-path packages/shared-swift YorozuFixtureGen`.
import CryptoKit
import Foundation
import YorozuShared

let alice = YorozuCrypto.generateKeypair()
let bob = YorozuCrypto.generateKeypair()
let signer = YorozuCrypto.generateSigningKeypair()

let sessionKey = try YorozuCrypto.deriveSessionKey(myPriv: alice.privateKey, theirPub: bob.publicKey)
let channel = try YorozuCrypto.deriveChannelKeys(myPriv: alice.privateKey, theirPub: bob.publicKey, role: .mac)
let plaintext = Data(Vectors.plaintextString.utf8)
let sealed = try YorozuCrypto.seal(key: sessionKey, plaintext: plaintext)
let channelBox = try YorozuCrypto.seal(
    key: channel.send,
    plaintext: try ChannelEnvelope(seq: Vectors.seq, event: Vectors.event).encoded()
)

let qr = QrPayload(
    relayUrl: "wss://relay.yumi.to",
    macPubkey: alice.publicKey.base64URLEncodedString(),
    token: Data((0..<16).map { _ in UInt8.random(in: .min ... .max) }).base64URLEncodedString()
)

let vectors = Vectors(
    source: "swift",
    alicePriv: alice.privateKey.base64URLEncodedString(),
    alicePub: alice.publicKey.base64URLEncodedString(),
    bobPriv: bob.privateKey.base64URLEncodedString(),
    bobPub: bob.publicKey.base64URLEncodedString(),
    sessionKey: sessionKey.withUnsafeBytes { Data($0) }.base64URLEncodedString(),
    channelMacToDevice: channel.send.withUnsafeBytes { Data($0) }.base64URLEncodedString(),
    channelDeviceToMac: channel.recv.withUnsafeBytes { Data($0) }.base64URLEncodedString(),
    channelSeq: Vectors.seq,
    channelNonce: channelBox.nonce.base64URLEncodedString(),
    channelCiphertext: channelBox.ciphertext.base64URLEncodedString(),
    nonce: sealed.nonce.base64URLEncodedString(),
    plaintext: plaintext.base64URLEncodedString(),
    ciphertext: sealed.ciphertext.base64URLEncodedString(),
    signPriv: signer.privateKey.base64URLEncodedString(),
    signPub: signer.publicKey.base64URLEncodedString(),
    signature: try YorozuCrypto.signFrame(priv: signer.privateKey, data: plaintext)
        .base64URLEncodedString(),
    qr: try qr.encoded()
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let path = Vectors.path(source: "swift")
try (encoder.encode(vectors) + Data("\n".utf8)).write(to: path)
print("wrote \(path.path)")
