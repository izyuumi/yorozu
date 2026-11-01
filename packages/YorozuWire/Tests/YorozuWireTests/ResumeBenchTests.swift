import Foundation
import Testing
@testable import YorozuWire

/// The real sender against the plugin's real spool in a node process, killed at 50 % and 99 % and restarted
/// on the same spool. Run with `YOROZU_RESUME_BENCH=1 swift test --filter ResumeBench`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YOROZU_RESUME_BENCH"] == "1"), .serialized)
struct ResumeBenchTests {
    static let size = 100 * 1024 * 1024
    static let window = 4
    static let scenarios: [[Double]] = [[0.5], [0.99], [0.5, 0.99]]

    struct Failure: Error, CustomStringConvertible { var description: String }

    final class Receiver: @unchecked Sendable {
        let process = Process()
        let input = Pipe()
        let events: AsyncStream<WireEvent>

        init(spool: URL) throws {
            let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "plugins/openclaw-yorozu/test/receiver.ts")
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["node", script.path, spool.path]
            process.standardInput = input
            process.standardOutput = output
            let (events, feed) = AsyncStream<WireEvent>.makeStream()
            self.events = events
            try process.run()
            let reader = output.fileHandleForReading
            Task.detached {
                do {
                    for try await line in reader.bytes.lines {
                        if let event = try? JSONDecoder().decode(WireEvent.self, from: Data(line.utf8)) { feed.yield(event) }
                    }
                } catch {}
                feed.finish()
            }
        }

        func send(_ event: WireEvent) throws {
            try input.fileHandleForWriting.write(contentsOf: try event.encoded() + Data([0x0a]))
        }

        func kill() {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }

        func finish() {
            try? input.fileHandleForWriting.close()
            process.waitUntilExit()
        }
    }

    @Test func killAndResume() async throws {
        signal(SIGPIPE, SIG_IGN)
        let root = FileManager.default.temporaryDirectory.appending(path: "yorozu-resume-bench-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appending(path: "file.bin")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let writer = try FileHandle(forWritingTo: file)
        var block = Data(count: 1 << 20)
        for _ in 0..<(Self.size >> 20) {
            block.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            try writer.write(contentsOf: block)
        }
        try writer.close()
        let sha256 = try FileDigest.sha256(of: file)

        for kills in Self.scenarios {
            for resume in [false, true] {
                let label = kills.map { "\(Int($0 * 100))%" }.joined(separator: "+")
                let run = root.appending(path: "\(label)-\(resume ? "on" : "off")")
                let sent = try await upload(file, sha256: sha256, resume: resume, kills: kills, spool: run.appending(path: "spool"))
                let stored = try FileManager.default.contentsOfDirectory(at: run.appending(path: "stored"), includingPropertiesForKeys: nil)
                #expect(stored.count == 1)
                #expect(try stored.first.map(FileDigest.sha256(of:)) == sha256)
                let mb = { (bytes: Int) in String(format: "%.1f MB", Double(bytes) / 1_048_576) }
                print("kill at \(label), resume \(resume ? "on " : "off"): file \(mb(Self.size)), sent \(mb(sent)) (\(sent) B), "
                    + "re-sent \(mb(sent - Self.size)) (\(sent - Self.size) B)")
                if resume { #expect(sent - Self.size <= kills.count * 2 * Self.window * Attachment.chunkBytes) }
            }
        }
    }

    private func upload(_ file: URL, sha256: String, resume: Bool, kills: [Double], spool: URL) async throws -> Int {
        let id = WireEvent.newId()
        let reader = try FileHandle(forReadingFrom: file)
        defer { try? reader.close() }
        var sender = UploadSender(size: Self.size, window: Self.window)
        var kills = kills
        var receiver = try Receiver(spool: spool)
        session: while true {
            var events = receiver.events.makeAsyncIterator()
            if resume {
                try receiver.send(.uploadStatus(UploadStatus(attachmentId: id, size: Self.size, count: sender.count, sha256: sha256)))
                guard case .uploadState(let state)? = await events.next() else { throw Failure(description: "no upload_state") }
                if state.done { break session }
                sender.resume(have: state.have)
            } else {
                sender.restart()
            }
            sending: while true {
                while let index = sender.next() {
                    let range = sender.range(of: index)
                    try reader.seek(toOffset: UInt64(range.lowerBound))
                    let data = try reader.read(upToCount: range.count) ?? Data()
                    try receiver.send(.upload(Upload(attachmentId: id, name: "file.bin", mime: "application/octet-stream",
                        size: Self.size, index: index, count: sender.count, data: data.base64EncodedString(),
                        sha256: resume ? sha256 : nil)))
                }
                switch await events.next() {
                case .uploadAck(let ack)?:
                    if ack.done { break session }
                    sender.ack(ack.index)
                    if let kill = kills.first, sender.progress >= kill {
                        kills.removeFirst()
                        receiver.kill()
                        break sending
                    }
                case .error(let error)?: throw Failure(description: "\(error.code): \(error.message)")
                case nil: throw Failure(description: "the receiver quit")
                default: continue
                }
            }
            receiver = try Receiver(spool: spool)
        }
        receiver.finish()
        return sender.bytesSent
    }
}
