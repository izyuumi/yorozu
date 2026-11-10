import Foundation
import Testing
@testable import YorozuWire

/// What `Frame(bytes:)` and `Session.open` refuse, in both wire formats.
struct FrameSessionRejectionTests {
    static let formats: [Wire.Format] = [.legacy, .unversioned]
    let sid = Data(repeating: 7, count: Wire.sidBytes)

    /// Two ends of one session: each side's send key is the other's receive key.
    func pair(_ format: Wire.Format) -> (sender: Session, receiver: Session) {
        let a = Data(repeating: 1, count: 32), b = Data(repeating: 2, count: 32)
        return (Session(sid: sid, handshakeHash: Data(), sendKey: a, recvKey: b, format: format),
            Session(sid: sid, handshakeHash: Data(), sendKey: b, recvKey: a, format: format))
    }

    func head(_ type: UInt8, _ format: Wire.Format) -> Data {
        format == .legacy ? Data([Wire.version, type]) : Data([0x10 + type])
    }

    func counterBytes(_ counter: UInt64) -> Data { withUnsafeBytes(of: counter.littleEndian) { Data($0) } }

    // MARK: Session.open

    @Test(arguments: formats)
    func repeatedOrLowerCounterIsReplay(_ format: Wire.Format) throws {
        var (sender, receiver) = pair(format)
        let frames = try (0..<3).map { try sender.seal(Data("m\($0)".utf8)) }
        #expect(receiver.lastReceived == nil)
        #expect(try receiver.open(frames[0]) == Data("m0".utf8))
        #expect(throws: Wire.Failure.replay) { try receiver.open(frames[0]) }
        // A gap is accepted; the skipped counter is then behind the window.
        #expect(try receiver.open(frames[2]) == Data("m2".utf8))
        #expect(throws: Wire.Failure.replay) { try receiver.open(frames[1]) }
        #expect(throws: Wire.Failure.replay) { try receiver.open(frames[2]) }
        #expect(receiver.lastReceived == 2)
    }

    @Test(arguments: formats)
    func anotherSidIsOtherSession(_ format: Wire.Format) throws {
        var (sender, receiver) = pair(format)
        guard case .transport(_, let counter, let ciphertext, _) = try sender.seal(Data("hi".utf8)) else {
            Issue.record("not a transport frame"); return
        }
        let other = Frame.transport(sid: Data(repeating: 8, count: Wire.sidBytes), counter: counter, ciphertext: ciphertext, format: format)
        #expect(throws: Wire.Failure.otherSession) { try receiver.open(other) }
        #expect(receiver.lastReceived == nil)
    }

    @Test(arguments: formats)
    func frameInTheOtherFormatIsRefused(_ format: Wire.Format) throws {
        var (sender, receiver) = pair(format)
        guard case .transport(let sid, let counter, let ciphertext, _) = try sender.seal(Data("hi".utf8)) else {
            Issue.record("not a transport frame"); return
        }
        let other: Wire.Format = format == .legacy ? .unversioned : .legacy
        #expect(throws: Wire.Failure.malformed("wrong wire format")) {
            try receiver.open(.transport(sid: sid, counter: counter, ciphertext: ciphertext, format: other))
        }
        #expect(receiver.lastReceived == nil)
        #expect(try receiver.open(.transport(sid: sid, counter: counter, ciphertext: ciphertext, format: format)) == Data("hi".utf8))
    }

    @Test(arguments: formats)
    func handshakeFrameIsNotOpened(_ format: Wire.Format) {
        var receiver = pair(format).receiver
        #expect(throws: Wire.Failure.malformed("not a transport frame")) {
            try receiver.open(.handshakeResponse(sid: sid, message: Data(count: 48), format: format))
        }
    }

    @Test(arguments: formats)
    func failedDecryptLeavesLastReceived(_ format: Wire.Format) throws {
        var (sender, receiver) = pair(format)
        let first = try sender.seal(Data("m0".utf8)), second = try sender.seal(Data("m1".utf8))
        guard case .transport(let sid, let counter, let ciphertext, _) = second else { Issue.record("not a transport frame"); return }
        var tampered = ciphertext
        tampered[tampered.startIndex] ^= 1

        // Before anything was received.
        #expect(throws: Wire.Failure.decrypt) {
            try receiver.open(.transport(sid: sid, counter: counter, ciphertext: tampered, format: format))
        }
        #expect(receiver.lastReceived == nil)

        #expect(try receiver.open(first) == Data("m0".utf8))
        #expect(throws: Wire.Failure.decrypt) {
            try receiver.open(.transport(sid: sid, counter: counter, ciphertext: tampered, format: format))
        }
        // A forged high counter and a ciphertext shorter than the tag move nothing either.
        #expect(throws: Wire.Failure.decrypt) {
            try receiver.open(.transport(sid: sid, counter: 99, ciphertext: ciphertext, format: format))
        }
        #expect(throws: Wire.Failure.decrypt) {
            try receiver.open(.transport(sid: sid, counter: 100, ciphertext: Data(count: 15), format: format))
        }
        #expect(receiver.lastReceived == 0)
        // So the genuine frame with that counter still opens.
        #expect(try receiver.open(second) == Data("m1".utf8))
        #expect(receiver.lastReceived == 1)
    }

    // MARK: Frame(bytes:)

    @Test(arguments: formats)
    func counterAboveMaxIsRefused(_ format: Wire.Format) throws {
        let tail = Data(repeating: 6, count: 16)
        let atMax = head(3, format) + sid + counterBytes(Wire.maxCounter) + tail
        #expect(try Frame(bytes: atMax) == .transport(sid: sid, counter: Wire.maxCounter, ciphertext: tail, format: format))
        for counter in [Wire.maxCounter + 1, UInt64.max] {
            #expect(throws: Wire.Failure.malformed("counter out of range")) {
                try Frame(bytes: head(3, format) + sid + counterBytes(counter) + tail)
            }
        }
    }

    @Test(arguments: formats)
    func bodyLengthLimitsPerType(_ format: Wire.Format) throws {
        // (type, shortest body, longest body or nil)
        let limits: [(UInt8, Int, Int?)] = [
            (1, 32 + 96, 32 + 65_535),
            (2, Wire.sidBytes + 48, Wire.sidBytes + 65_535),
            (3, Wire.sidBytes + 8 + 16, nil),
        ]
        for (type, shortest, longest) in limits {
            #expect(throws: Wire.Failure.malformed("bad frame")) { try Frame(bytes: head(type, format) + Data(count: shortest - 1)) }
            #expect(throws: Wire.Failure.malformed("bad frame")) { try Frame(bytes: head(type, format)) }
            _ = try Frame(bytes: head(type, format) + Data(count: shortest))
            if let longest {
                _ = try Frame(bytes: head(type, format) + Data(count: longest))
                #expect(throws: Wire.Failure.malformed("bad frame")) { try Frame(bytes: head(type, format) + Data(count: longest + 1)) }
            }
        }
    }

    @Test func unknownHeadByteIsRefused() {
        let body = Data(count: 200)
        for first: UInt8 in [0x00, 0x01, 0x02, 0x04, 0x10, 0x14, 0x7b, 0xff] {
            #expect(throws: Wire.Failure.malformed("not a wire frame")) { try Frame(bytes: Data([first]) + body) }
        }
        #expect(throws: Wire.Failure.malformed("not a wire frame")) { try Frame(bytes: Data()) }
        // A lone version byte has no type.
        #expect(throws: Wire.Failure.malformed("not a wire frame")) { try Frame(bytes: Data([Wire.version])) }
        // A legacy head with a type nobody defines.
        for type: UInt8 in [0, 4, 0x11, 0xff] {
            #expect(throws: Wire.Failure.malformed("bad frame")) { try Frame(bytes: Data([Wire.version, type]) + body) }
        }
        #expect(throws: Wire.Failure.malformed("payload is not base64url")) { try Frame(payload: "not base64url!") }
    }

    @Test(arguments: formats)
    func bytesRoundTrip(_ format: Wire.Format) throws {
        var sender = pair(format).sender
        let ciphertext = Data((0..<40).map { UInt8($0) })
        let frames: [Frame] = [
            .handshakeInit(deviceSigningKey: Data(repeating: 1, count: 32), message: Data((0..<96).map { UInt8($0) }), format: format),
            .handshakeResponse(sid: sid, message: Data((0..<48).map { UInt8($0) }), format: format),
            .transport(sid: sid, counter: 0x0102_0304_0506, ciphertext: ciphertext, format: format),
            try sender.seal(Data()),
        ]
        for frame in frames {
            let back = try Frame(bytes: frame.bytes)
            #expect(back == frame)
            #expect(back.format == format)
            #expect(back.bytes == frame.bytes)
            #expect(back.sid == frame.sid)
            // Parsing does not depend on the buffer starting at index 0.
            #expect(try Frame(bytes: (Data([0xaa]) + frame.bytes).dropFirst()) == frame)
        }
        // The same frame in the other format is a different frame.
        let other: Wire.Format = format == .legacy ? .unversioned : .legacy
        #expect(try Frame(bytes: frames[2].bytes) != .transport(sid: sid, counter: 0x0102_0304_0506, ciphertext: ciphertext, format: other))
    }
}
