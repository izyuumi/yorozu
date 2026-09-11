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

@Test func base64UrlRoundTripsRawKeys() {
    let key = YorozuCrypto.generateKeypair().publicKey
    #expect(Data(base64URLEncoded: key.base64URLEncodedString()) == key)
}
