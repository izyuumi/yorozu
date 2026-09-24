import CryptoKit
import Foundation
import Testing

@testable import YorozuShared

@Test func bothPeersDeriveTheSameSessionKey() throws {
    let mac = YorozuCrypto.generateKeypair()
    let phone = YorozuCrypto.generateKeypair()
    #expect(mac.privateKey.count == 32)
    #expect(mac.publicKey.count == 32)
    let a = try YorozuCrypto.deriveSessionKey(myPriv: mac.privateKey, theirPub: phone.publicKey)
    let b = try YorozuCrypto.deriveSessionKey(myPriv: phone.privateKey, theirPub: mac.publicKey)
    #expect(a == b)
}

/// The two directions must never share a key, or the relay could reflect a box back to its
/// sender; and each end's send key must be the other end's recv key, or nothing would open.
@Test func channelKeysAreDirectionalAndMirrorAcrossTheExchange() throws {
    let mac = YorozuCrypto.generateKeypair()
    let phone = YorozuCrypto.generateKeypair()
    let macSide = try YorozuCrypto.deriveChannelKeys(
        myPriv: mac.privateKey, theirPub: phone.publicKey, role: .mac)
    let phoneSide = try YorozuCrypto.deriveChannelKeys(
        myPriv: phone.privateKey, theirPub: mac.publicKey, role: .device)
    let session = try YorozuCrypto.deriveSessionKey(myPriv: mac.privateKey, theirPub: phone.publicKey)
    #expect(macSide.send != macSide.recv)
    #expect(macSide.send != session)
    #expect(macSide.recv != session)
    #expect(macSide.send == phoneSide.recv)
    #expect(macSide.recv == phoneSide.send)
}

@Test func sealThenOpenRoundTrips() throws {
    let key = SymmetricKey(size: .bits256)
    let plaintext = Data("hello from the Mac".utf8)
    let sealed = try YorozuCrypto.seal(key: key, plaintext: plaintext)
    #expect(sealed.nonce.count == 12)
    #expect(sealed.ciphertext.count == plaintext.count + 16)
    #expect(try YorozuCrypto.open(key: key, nonce: sealed.nonce, ciphertext: sealed.ciphertext) == plaintext)
}

@Test func openRejectsATamperedCiphertext() throws {
    let key = SymmetricKey(size: .bits256)
    let sealed = try YorozuCrypto.seal(key: key, plaintext: Data("transfer 10".utf8))
    var tampered = sealed.ciphertext
    tampered[tampered.startIndex] ^= 1
    #expect(throws: (any Error).self) {
        try YorozuCrypto.open(key: key, nonce: sealed.nonce, ciphertext: tampered)
    }
}

@Test func relayFramesVerifyOnlyUnderTheMatchingKey() throws {
    let signer = YorozuCrypto.generateSigningKeypair()
    let other = YorozuCrypto.generateSigningKeypair()
    let frame = Data("join room".utf8)
    let signature = try YorozuCrypto.signFrame(priv: signer.privateKey, data: frame)
    #expect(YorozuCrypto.verifyFrame(pub: signer.publicKey, data: frame, signature: signature))
    #expect(!YorozuCrypto.verifyFrame(pub: other.publicKey, data: frame, signature: signature))
}

/// Fixed vectors, byte-identical in crypto.test.ts: the relay routes on `threadRef` and the
/// runtime checks `helloProof`, so both languages must agree on them to the character.
@Test func referencesAndProofsAreSpelledTheSameInBothLanguages() {
    #expect(YorozuCrypto.threadRef("home") == "TqFAWIFQ")
    #expect(
        YorozuCrypto.helloProof(secret: "secret", pub: "pub", spub: "spub")
            == "MFvwTalbqCws08QSHDUcxRUlQi2EJlN53U9I-hoq_U0"
    )
}

@Test func base64UrlRoundTripsRawKeys() {
    let key = YorozuCrypto.generateKeypair().publicKey
    #expect(Data(base64URLEncoded: key.base64URLEncodedString()) == key)
}

@Test func notificationPreviewOpensOnlyValidUtf8UnderTheMatchingKey() throws {
    let key = SymmetricKey(size: .bits256)
    let other = SymmetricKey(size: .bits256)
    let sealed = try YorozuCrypto.seal(key: key, plaintext: Data("秘密の返事".utf8))
    let nonce = sealed.nonce.base64URLEncodedString()
    let ciphertext = sealed.ciphertext.base64URLEncodedString()
    // A bare string is a preview from before the object existed: all body, about no card.
    let opened = NotificationPreview.decrypt(nonce: nonce, ciphertext: ciphertext, key: key)
    #expect(opened?.body == "秘密の返事")
    #expect(opened?.event == nil)
    #expect(opened?.quick == false)
    #expect(NotificationPreview.decrypt(nonce: nonce, ciphertext: ciphertext, key: other) == nil)
    #expect(NotificationPreview.decrypt(nonce: "bad", ciphertext: ciphertext, key: key) == nil)
}

@Test func notificationPreviewPayloadDecodesOnlyItsWireShape() {
    let payload = NotificationPreviewPayload(userInfo: [
        "preview": ["n": "nonce", "c": "ciphertext"],
    ])
    #expect(payload?.nonce == "nonce")
    #expect(payload?.ciphertext == "ciphertext")
    #expect(NotificationPreviewPayload(userInfo: ["preview": ["n": "nonce"]]) == nil)
    #expect(NotificationPreviewPayload(userInfo: ["preview": "not-an-object"]) == nil)
}
