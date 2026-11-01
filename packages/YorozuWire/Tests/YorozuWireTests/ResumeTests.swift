import CryptoKit
import Foundation
import Testing
@testable import YorozuWire

struct ChunkRangesTests {
    @Test func insertMergesAndSorts() {
        var ranges = ChunkRanges()
        for index in [5, 0, 2, 1, 6, 9, 2] { ranges.insert(index) }
        #expect(ranges.ranges == [0..<3, 5..<7, 9..<10])
        #expect(ranges.covered == 6)
        #expect(ranges.contains(6) && !ranges.contains(7))
        #expect(ranges.missing(count: 11) == [3, 4, 7, 8, 10])
        ranges.insert(3..<5)
        #expect(ranges.ranges == [0..<7, 9..<10])
    }

    @Test func codesAsPairs() throws {
        let ranges = ChunkRanges([5..<7, 0..<3])
        #expect(String(decoding: try JSONEncoder().encode(ranges), as: UTF8.self) == "[[0,3],[5,7]]")
        let decoded = try JSONDecoder().decode(ChunkRanges.self, from: Data("[[5,7],[0,2],[1,3]]".utf8))
        #expect(decoded.ranges == [0..<3, 5..<7])
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ChunkRanges.self, from: Data("[[3,1]]".utf8)) }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ChunkRanges.self, from: Data("[[-1,2]]".utf8)) }
    }
}

/// The plugin's spool in memory: holds received chunks, checks the SHA-256 on assembly.
final class FakeReceiver {
    let size: Int
    var have = ChunkRanges()
    var chunks: [Int: Data] = [:]
    var stored: Data?
    var corruptNext = false

    init(size: Int) { self.size = size }

    var state: UploadState { UploadState(attachmentId: "", done: stored != nil, have: stored == nil ? have : ChunkRanges()) }

    enum Answer: Equatable { case ack(done: Bool), mismatch }

    func receive(_ index: Int, _ data: Data, sha256: String?) -> Answer {
        guard stored == nil else { return .ack(done: true) }
        chunks[index] = data
        have.insert(index)
        guard have.covered == Attachment.chunkCount(size) else { return .ack(done: false) }
        var file = (0..<Attachment.chunkCount(size)).reduce(into: Data()) { $0.append(chunks[$1]!) }
        if corruptNext, !file.isEmpty {
            corruptNext = false
            file[0] ^= 0xff
        }
        if let sha256, SHA256.hash(data: file).hex != sha256 {
            (have, chunks) = (ChunkRanges(), [:])
            return .mismatch
        }
        stored = file
        return .ack(done: true)
    }
}

extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

/// Drives one session: chunks sent go on the wire in order, each answered when it arrives. A kill drops what is
/// still on the wire once `progress` reaches the fraction.
enum Transmission {
    enum End: Equatable { case stored, killed, mismatch }

    static func run(_ sender: inout UploadSender, file: Data, sha256: String?, into receiver: FakeReceiver,
        killAt: Double? = nil) -> (end: End, sent: Int) {
        var wire: [Int] = []
        var sent = 0
        while true {
            while let index = sender.next() {
                wire.append(index)
                sent += 1
            }
            guard !wire.isEmpty else { return (.killed, sent) }
            let index = wire.removeFirst()
            switch receiver.receive(index, file.subdata(in: sender.range(of: index)), sha256: sha256) {
            case .ack(done: true): return (.stored, sent)
            case .mismatch: return (.mismatch, sent)
            case .ack(done: false):
                sender.ack(index)
                if let killAt, sender.progress >= killAt { return (.killed, sent) }
            }
        }
    }
}

struct UploadSenderTests {
    static let size = 100 * Attachment.chunkBytes - 123
    static let file = Data((0..<size).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    static let sha256 = SHA256.hash(data: file).hex
    var file: Data { Self.file }
    var sha256: String { Self.sha256 }
    var count: Int { Attachment.chunkCount(Self.size) }

    @Test(arguments: [0.5, 0.99])
    func aResumeSendsOnlyWhatTheReceiverLacks(killAt: Double) {
        let receiver = FakeReceiver(size: Self.size)
        var sender = UploadSender(size: Self.size, window: 4)
        let first = Transmission.run(&sender, file: file, sha256: sha256, into: receiver, killAt: killAt)
        #expect(first.end == .killed)
        let held = receiver.state.have
        #expect(held.covered == sender.acked.covered)
        sender.resume(have: held)
        let second = Transmission.run(&sender, file: file, sha256: sha256, into: receiver)
        #expect(second.end == .stored)
        #expect(second.sent == count - held.covered)
        #expect(first.sent + second.sent - count <= sender.window)
        #expect(receiver.stored == file)
        #expect(sender.bytesSent - Self.size <= sender.window * Attachment.chunkBytes)
    }

    @Test(arguments: [0.5, 0.99])
    func withoutResumeEverythingGoesAgain(killAt: Double) {
        let receiver = FakeReceiver(size: Self.size)
        var sender = UploadSender(size: Self.size, window: 4)
        let first = Transmission.run(&sender, file: file, sha256: nil, into: receiver, killAt: killAt)
        sender.restart()
        let second = Transmission.run(&sender, file: file, sha256: nil, into: receiver)
        #expect(second.end == .stored)
        #expect(second.sent == count)
        #expect(first.sent >= Int(Double(count) * killAt))
    }

    @Test func everyChunkHeldButNotStoredSendsTheLastAgain() {
        let receiver = FakeReceiver(size: Self.size)
        let ranges = UploadSender(size: Self.size, window: 1)
        for index in 0..<count {
            receiver.chunks[index] = file.subdata(in: ranges.range(of: index))
            receiver.have.insert(index)
        }
        var sender = UploadSender(size: Self.size, window: 4, have: receiver.have)
        let run = Transmission.run(&sender, file: file, sha256: sha256, into: receiver)
        #expect(run.end == .stored)
        #expect(run.sent == 1)
    }

    @Test func aHashMismatchRestartsFromZero() {
        let receiver = FakeReceiver(size: Self.size)
        receiver.corruptNext = true
        var sender = UploadSender(size: Self.size, window: 4)
        let first = Transmission.run(&sender, file: file, sha256: sha256, into: receiver)
        #expect(first.end == .mismatch)
        #expect(first.sent == count)
        #expect(receiver.state.have.covered == 0)
        sender.restart()
        #expect(sender.acked.covered == 0)
        let second = Transmission.run(&sender, file: file, sha256: sha256, into: receiver)
        #expect(second.end == .stored)
        #expect(second.sent == count)
        #expect(receiver.stored == file)
        #expect(sender.bytesSent == 2 * Self.size)
    }

    @Test func aSmallFileIsOneChunk() {
        var sender = UploadSender(size: 0, window: 4)
        #expect(sender.count == 1)
        #expect(sender.next() == 0)
        #expect(sender.next() == nil)
        #expect(sender.range(of: 0) == 0..<0)
    }
}

struct ResumeWireTests {
    let id = "0b5f2c1e-8d4a-4c3e-9f1a-2b3c4d5e6f70"
    let sha = String(repeating: "ab", count: 32)

    private func roundTrip(_ event: WireEvent) throws -> WireEvent {
        try JSONDecoder().decode(WireEvent.self, from: event.encoded())
    }

    private func decode(_ json: String) throws -> WireEvent { try JSONDecoder().decode(WireEvent.self, from: Data(json.utf8)) }

    @Test func uploadStatusRoundTrips() throws {
        let event = WireEvent.uploadStatus(UploadStatus(attachmentId: id, size: 10, count: 1, sha256: sha))
        #expect(try roundTrip(event) == event)
        #expect(String(decoding: try event.encoded(), as: UTF8.self)
            == #"{"data":{"attachmentId":"\#(id)","count":1,"sha256":"\#(sha)","size":10},"kind":"upload_status"}"#)
    }

    @Test func uploadStateRoundTrips() throws {
        let event = WireEvent.uploadState(UploadState(attachmentId: id, done: false, have: ChunkRanges([0..<3, 7..<9])))
        #expect(try roundTrip(event) == event)
        #expect(String(decoding: try event.encoded(), as: UTF8.self).contains(#""have":[[0,3],[7,9]]"#))
        #expect(try decode(#"{"kind":"upload_state","data":{"attachmentId":"\#(id)","done":true,"have":[]}}"#)
            == .uploadState(UploadState(attachmentId: id, done: true)))
    }

    @Test func uploadCarriesSha256OnlyWhenSet() throws {
        let plain = Upload(attachmentId: id, name: "a", mime: "b", size: 1, index: 0, count: 1, data: "AA==")
        #expect(!String(decoding: try WireEvent.upload(plain).encoded(), as: UTF8.self).contains("sha256"))
        var hashed = plain
        hashed.sha256 = sha
        #expect(try roundTrip(.upload(hashed)) == .upload(hashed))
    }

    @Test func badFramesBecomeUnknown() throws {
        let badSha = #"{"kind":"upload_status","data":{"attachmentId":"\#(id)","size":1,"count":1,"sha256":"ABC"}}"#
        #expect(try decode(badSha).kind == "upload_status")
        guard case .unknown = try decode(badSha) else { Issue.record("accepted a bad sha256"); return }
        let badId = #"{"kind":"upload_state","data":{"attachmentId":"x","done":false,"have":[]}}"#
        guard case .unknown = try decode(badId) else { Issue.record("accepted a bad id"); return }
        let badRange = #"{"kind":"upload_state","data":{"attachmentId":"\#(id)","done":false,"have":[[2]]}}"#
        guard case .unknown = try decode(badRange) else { Issue.record("accepted a bad range"); return }
        let upperSha = #"{"kind":"upload","data":{"attachmentId":"\#(id)","name":"a","mime":"b","size":1,"index":0,"count":1,"data":"AA==","sha256":"\#(sha.uppercased())"}}"#
        guard case .unknown = try decode(upperSha) else { Issue.record("accepted an uppercase sha256"); return }
    }
}

struct FileDigestTests {
    private func digest(of data: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        return try FileDigest.sha256(of: url)
    }

    @Test func knownVectors() throws {
        #expect(try digest(of: Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(try digest(of: Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func streamsAcrossReads() throws {
        let data = Data((0..<(3 << 20) + 17).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        #expect(try digest(of: data) == SHA256.hash(data: data).hex)
        #expect(FileDigest.isSHA256(try digest(of: data)))
    }
}
