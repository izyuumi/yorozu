import CryptoKit
import Foundation
import Testing
@testable import YorozuWire

struct UnversionedWireTests {
    let ts: Int64 = 1_700_000_000_000
    let room = "wire-test-room"
    let host = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
    let signing = try! Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
    let device = try! Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 3, count: 32))

    var identity: PhoneIdentity {
        PhoneIdentity(signingPrivateKey: signing.rawRepresentation, signingPublicKey: signing.publicKey.rawRepresentation,
            sessionPrivateKey: device.rawRepresentation, sessionPublicKey: device.publicKey.rawRepresentation)
    }

    func handshake(_ format: Wire.Format) throws -> ClientHandshake {
        try ClientHandshake(identity: identity,
            pairing: QrPayload(v: 3, relayUrl: "wss://relay.test", macPubkey: host.publicKey.rawRepresentation.base64URLEncodedString(),
                token: "", roomId: room), format: format, now: Date(timeIntervalSince1970: Double(ts) / 1000),
            ephemeral: Data(repeating: 4, count: 32))
    }

    func responder(_ format: Wire.Format) throws -> NoiseIKHandshake {
        try NoiseIKHandshake(role: .responder, staticKey: host.rawRepresentation,
            prologue: Wire.prologue(roomId: room, deviceSigningKey: identity.signingPublicKey, format: format),
            ephemeral: Data(repeating: 5, count: 32))
    }

    @Test(arguments: [Wire.Format.legacy, .unversioned])
    func framesAndPrologues(_ format: Wire.Format) throws {
        let frames: [Frame] = [
            .handshakeInit(deviceSigningKey: Data(repeating: 1, count: 32), message: Data(repeating: 2, count: 96), format: format),
            .handshakeResponse(sid: Data(repeating: 3, count: 8), message: Data(repeating: 4, count: 48), format: format),
            .transport(sid: Data(repeating: 5, count: 8), counter: 42, ciphertext: Data(repeating: 6, count: 16), format: format),
        ]
        // Fixed legacy encodings, independent of the frame encoder.
        let legacyHex = ["0301" + String(repeating: "01", count: 32) + String(repeating: "02", count: 96),
            "0302" + String(repeating: "03", count: 8) + String(repeating: "04", count: 48),
            "0303" + String(repeating: "05", count: 8) + "2a00000000000000" + String(repeating: "06", count: 16)]
        for (index, frame) in frames.enumerated() {
            #expect(try Frame(bytes: frame.bytes) == frame)
            #expect(try Frame(payload: frame.payload) == frame)
            #expect(frame.bytes.first == (format == .legacy ? 3 : UInt8(0x11 + index)))
            let hex = frame.bytes.map { String(format: "%02x", $0) }.joined()
            let expected = format == .legacy ? legacyHex[index] : String(format: "%02x", 0x11 + index) + legacyHex[index].dropFirst(4)
            #expect(hex == expected)
            for length in 0..<frame.bytes.count {
                #expect(throws: Wire.Failure.self) { try Frame(bytes: Data(frame.bytes.prefix(length))) }
            }
        }
        let prologue = Wire.prologue(roomId: "room", deviceSigningKey: Data([0xff]), format: format)
        #expect(String(decoding: prologue, as: UTF8.self) == (format == .legacy ? "yorozu-v3|room|_w" : "yorozu|room|_w"))
        #expect(Wire.prologue(roomId: "room", deviceSigningKey: Data([0xff])) == Data("yorozu-v3|room|_w".utf8))
    }

    @Test(arguments: [Wire.Format.legacy, .unversioned])
    func fullHandshakeAndSessionBinding(_ format: Wire.Format) throws {
        let client = try handshake(format)
        #expect(client.frame.format == format)
        let other: Wire.Format = format == .legacy ? .unversioned : .legacy
        guard case .handshakeInit(_, let message, _) = client.frame else { throw Wire.Failure.malformed("not an init") }
        var host = try responder(format)
        #expect(try JSONDecoder().decode(HandshakePayload.self, from: host.readMessage(message)) == HandshakePayload(ts: ts))
        let answer = try host.writeMessage(Data())
        #expect(throws: Wire.Failure.malformed("wrong wire format")) {
            try client.finish(.handshakeResponse(sid: client.sid, message: answer, format: other))
        }
        var session = try client.finish(.handshakeResponse(sid: client.sid, message: answer, format: format))
        var remote = try host.split(sid: client.sid, format: format)
        #expect(session.format == format)
        #expect(session.handshakeHash == remote.handshakeHash)
        let sealed = try session.seal(Data("client box".utf8))
        #expect(sealed.format == format)
        #expect(try remote.open(sealed) == Data("client box".utf8))
        let box = try remote.seal(.peerInfo(PeerInfo(app: "test")))
        guard case .transport(let sid, let counter, let ciphertext, _) = box else { throw Wire.Failure.malformed("not a box") }
        let mixed = Frame.transport(sid: sid, counter: counter, ciphertext: ciphertext, format: other)
        #expect(throws: Wire.Failure.malformed("wrong wire format")) { try session.open(mixed) }
        #expect(throws: Wire.Failure.malformed("wrong wire format")) { try session.openEvent(mixed) }
        #expect(try session.openEvent(box) == .peerInfo(PeerInfo(app: "test")))
    }

    @Test func capabilityAndTimeoutPolicy() {
        #expect(UnversionedWire.capability == "unversioned-wire")
        #expect(Wire.Format(unversionedWire: false) == .legacy)
        #expect(Wire.Format(unversionedWire: true) == .unversioned)
        for format in [Wire.Format.legacy, .unversioned] {
            #expect(format.afterHandshakeTimeout(onRelay: true, awaitingResponse: true) == .legacy)
            #expect(format.afterHandshakeTimeout(onRelay: true, awaitingResponse: false) == format)
            #expect(format.afterHandshakeTimeout(onRelay: false, awaitingResponse: true) == format)
        }
    }

    @Test func crossSideVector() throws {
        let client = try handshake(.unversioned)
        guard case .handshakeInit(_, let message, _) = client.frame else { throw Wire.Failure.malformed("not an init") }
        var host = try responder(.unversioned)
        _ = try host.readMessage(message)
        let response = Frame.handshakeResponse(sid: client.sid, message: try host.writeMessage(Data()), format: .unversioned)
        let url = try #require(Bundle.module.url(forResource: "unversioned-wire", withExtension: "json", subdirectory: "Fixtures"))
        let fixture = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))
        #expect(client.frame.bytes.map { String(format: "%02x", $0) }.joined() == fixture["initHex"])
        #expect(response.bytes.map { String(format: "%02x", $0) }.joined() == fixture["responseHex"])
        let hex = Array(try #require(fixture["responseHex"]))
        let bytes = try Data(stride(from: 0, to: hex.count, by: 2).map { index in
            try #require(UInt8(String(hex[index..<index + 2]), radix: 16))
        })
        #expect(try client.finish(Frame(bytes: bytes)).handshakeHash == host.handshakeHash)
    }
}
