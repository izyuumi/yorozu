import Foundation
import Testing
@testable import YorozuWire

/// The pairing link's direct hints and the hello proof (#532 step 5: offline pairing).
struct PairingTests {
    let key = Data(repeating: 7, count: 32).base64URLEncodedString()
    let base = "yorozu://pair?v=3&relay=wss://relay.example/ws&key=\(Data(repeating: 7, count: 32).base64URLEncodedString())&token=tok&room=room&secret=sec"

    @Test func hintsRoundTrip() throws {
        let hints = DirectHints(port: 8738, lan: [.init(address: "192.168.1.5", prefix: 24), .init(address: "fd00::5", prefix: 64)],
            tailscale: [.init(address: "100.100.1.2"), .init(address: "fd7a:115c:a1e0::1")])
        let payload = QrPayload(v: 3, relayUrl: "wss://relay.example/ws", macPubkey: key, token: "tok", roomId: "room", secret: "sec",
            hints: hints)
        let link = try payload.encoded()
        #expect(link.contains("lan=192.168.1.5/24,fd00::5/64"))
        #expect(link.contains("ts=100.100.1.2,fd7a:115c:a1e0::1"))
        #expect(try QrPayload.decode(link) == payload)
        let web = "\(QrPayload.link)#\(try #require(link.split(separator: "?", maxSplits: 1).last))"
        #expect(try QrPayload.decode(web).hints == hints)
    }

    @Test func thePluginsLinkDecodes() throws {
        let decoded = try QrPayload.decode("\(base)&port=8738&lan=10.0.0.4/16,fd00::5/64&ts=100.100.1.2")
        #expect(decoded.hints == DirectHints(port: 8738, lan: [.init(address: "10.0.0.4", prefix: 16), .init(address: "fd00::5", prefix: 64)],
            tailscale: [.init(address: "100.100.1.2")]))
        #expect(try QrPayload.decode("\(base)&port=9000").hints == DirectHints(port: 9000))
    }

    @Test func invalidEntriesAreDroppedAndTheListsCapped() throws {
        let lan = "nope/24,10.0.0.1/33,fe80::1%25en0/64,10.0.0.2,10.0.0.3/8,10.0.0.4/8,10.0.0.5/8,10.0.0.6/8,10.0.0.7/8"
        let decoded = try QrPayload.decode("\(base)&port=8738&lan=\(lan)&ts=host,,100.64.0.1,100.64.0.2,100.64.0.3")
        #expect(decoded.hints?.lan.map(\.address) == ["10.0.0.3", "10.0.0.4", "10.0.0.5", "10.0.0.6"])
        #expect(decoded.hints?.tailscale.map(\.address) == ["100.64.0.1", "100.64.0.2"])
        let many = DirectHints(port: 8738, lan: (1...6).map { .init(address: "10.0.0.\($0)", prefix: 8) },
            tailscale: (1...3).map { .init(address: "100.64.0.\($0)") })
        let capped = try QrPayload.decode(QrPayload(v: 3, relayUrl: "wss://relay.example/ws", macPubkey: key, token: "tok",
            roomId: "room", hints: many).encoded())
        #expect(capped.hints?.lan.count == QrPayload.maxLAN)
        #expect(capped.hints?.tailscale.count == QrPayload.maxTailscale)
        for port in ["0", "70000", "x", ""] {
            #expect(try QrPayload.decode("\(base)&port=\(port)&lan=10.0.0.3/8").hints == nil)
        }
    }

    @Test func oldLinksAndStoredPairingsWithoutHintsStillDecode() throws {
        let decoded = try QrPayload.decode(base)
        #expect(decoded.hints == nil)
        #expect(decoded.secret == "sec")
        let stored = #"{"v":3,"relayUrl":"wss://relay.example/ws","macPubkey":"\#(key)","token":"tok","roomId":"room"}"#
        #expect(try JSONDecoder().decode(QrPayload.self, from: Data(stored.utf8)).hints == nil)
        let withBadEntry = #"{"v":3,"relayUrl":"r","macPubkey":"k","token":"t","hints":{"port":8738,"lan":[{"address":"nope","prefix":1}]}}"#
        #expect(try JSONDecoder().decode(QrPayload.self, from: Data(withBadEntry.utf8)).hints == DirectHints(port: 8738))
    }

    /// The init a pairing sends, on the relay or the direct path, proves the QR's secret; a paired device's doesn't.
    @Test func aPairingsInitCarriesTheProof() throws {
        let host = YorozuCrypto.generateKeypair()
        let identity = PhoneIdentity.generate()
        func payload(_ secret: String?) throws -> HandshakePayload {
            let pairing = QrPayload(v: 3, relayUrl: "wss://relay.example/ws", macPubkey: host.publicKey.base64URLEncodedString(),
                token: "tok", roomId: "room", secret: secret)
            guard case .handshakeInit(_, let message) = try ClientHandshake(identity: identity, pairing: pairing).frame else {
                throw Wire.Failure.malformed("not an init")
            }
            var responder = try NoiseIKHandshake(role: .responder, staticKey: host.privateKey,
                prologue: Wire.prologue(roomId: "room", deviceSigningKey: identity.signingPublicKey))
            return try JSONDecoder().decode(HandshakePayload.self, from: responder.readMessage(message))
        }
        #expect(try payload("sec").proof == YorozuCrypto.helloProof(secret: "sec", pub: identity.sessionPublicKey.base64URLEncodedString(),
            spub: identity.signingPublicKey.base64URLEncodedString()))
        #expect(try payload(nil).proof == nil)
    }
}
