import Foundation
import SwiftUI
import Testing

@testable import YorozuShared

/// What both apps show before a link replaces a pairing, and what the chat lets a tapped
/// link do. Pure functions, so tested as tables.

@Test func aKeyFingerprintIsItsFirstEightBytesAsHexPairs() throws {
    // 32 bytes counting up, as a Mac X25519 key is spelled: base64url, unpadded.
    let key = Data((0..<32).map(UInt8.init)).base64URLEncodedString()
    #expect(QrPayload.fingerprint(ofBase64URLKey: key) == "00 01 02 03 04 05 06 07")
    #expect(QrPayload.fingerprint(ofBase64URLKey: Data([0xde, 0xad, 0xbe, 0xef, 0x00, 0xff, 0x10, 0x7f, 0x42]).base64URLEncodedString())
        == "de ad be ef 00 ff 10 7f")
    // Too short to be a key, or not base64url at all: nothing to compare, so nothing shown.
    #expect(QrPayload.fingerprint(ofBase64URLKey: Data([1, 2, 3]).base64URLEncodedString()) == nil)
    #expect(QrPayload.fingerprint(ofBase64URLKey: "not base64!") == nil)
    #expect(QrPayload.fingerprint(ofBase64URLKey: "") == nil)

    let payload = try QrPayload.decode("yorozu://pair?v=1&relay=wss%3A%2F%2Frelay.yumi.to%3A443&key=\(key)&token=t")
    #expect(payload.macKeyFingerprint == "00 01 02 03 04 05 06 07")
    #expect(payload.relayHost == "relay.yumi.to")
}

@Test func onlyTheWebAndMailOpenFromAMessage() {
    func decide(_ text: String) -> ChatLinkDecision { ChatLinkPolicy.decision(for: URL(string: text)!) }
    #expect(decide("https://example.com/a?b=c") == .open)
    #expect(decide("http://example.com") == .open)
    #expect(decide("HTTPS://EXAMPLE.COM") == .open)
    #expect(decide("mailto:someone@example.com") == .open)
    // A pairing code is not opened, it is asked about.
    #expect(decide("yorozu://pair?v=1&relay=wss%3A%2F%2Fr&key=AAA&token=t") == .pairing)
    #expect(decide("YOROZU://PAIR?v=1") == .pairing)
    // Every other yorozu host is an app-internal link that a reply has no business sending.
    #expect(decide("yorozu://thread/abc") == .discard)
    #expect(decide("yorozu://share?token=x") == .discard)
    #expect(decide("yorozu://nonsense") == .discard)
    // Nothing else opens: the reply is untrusted text.
    #expect(decide("tel:+15555550100") == .discard)
    #expect(decide("sms:+15555550100") == .discard)
    #expect(decide("file:///etc/passwd") == .discard)
    #expect(decide("javascript:alert(1)") == .discard)
    #expect(decide("ftp://example.com") == .discard)
    #expect(decide("x-apple.systempreferences:com.apple.preference") == .discard)
    #expect(decide("http:relative") == .discard)
}

@MainActor
@Test func theTimelineActionRoutesAPairingCodeAndDropsTheRest() {
    var pairing: [URL] = []
    let action = OpenURLAction.chatLinks { pairing.append($0) }
    let code = URL(string: "yorozu://pair?v=1&relay=wss%3A%2F%2Fr&key=AAA&token=t")!
    action(code)
    #expect(pairing == [code])
    // A discarded link never reaches the hook.
    action(URL(string: "yorozu://thread/abc")!)
    action(URL(string: "tel:+15555550100")!)
    #expect(pairing == [code])
}

@MainActor
@Test func withNowhereToAskAPairingCodeIsDroppedLikeTheRest() {
    let action = OpenURLAction.chatLinks(onPairingLink: nil)
    // Nothing to observe but that it does not crash and does not reach the system: the result
    // is `.discarded`, which `OpenURLAction` swallows. The policy test covers the decision.
    action(URL(string: "yorozu://pair?v=1&relay=wss%3A%2F%2Fr&key=AAA&token=t")!)
}
