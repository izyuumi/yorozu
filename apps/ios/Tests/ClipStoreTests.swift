import Foundation
import Testing

@Suite struct ClipStoreTests {
    @Test func roundTripSurvivesReopeningBeforeClose() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipStore(directory: directory, protection: { _, _ in })
        let meta = ClipMeta(id: UUID(), convId: "conversation", createdAt: Date(timeIntervalSince1970: 20), purpose: .insert)
        let writer = try store.begin(meta)
        try writer.append([0, 1, -0.5])
        let reopened = ClipStore(directory: directory, protection: { _, _ in })
        #expect(reopened.pending() == [meta])
        #expect(try reopened.samples(meta.id) == [0, 1, -0.5])
        try writer.append([0.25])
        try writer.close()
        #expect(try reopened.samples(meta.id) == [0, 1, -0.5, 0.25])
        let pcm = directory.appendingPathComponent("\(meta.id).pcm")
        #expect(try Data(contentsOf: pcm) == Data([0, 0, 0, 0, 0, 0, 128, 63, 0, 0, 0, 191, 0, 0, 128, 62]))
    }
}

extension ClipStoreTests {
    @Test func pendingIgnoresStraysAndSortsOldestFirst() throws {
        try withStore { directory, store in
            let newer = makeMeta(at: 30, purpose: .send)
            let older = makeMeta(at: 10)
            try store.begin(newer).close()
            try store.begin(older).close()
            let stray = makeMeta(at: 0)
            try JSONEncoder().encode(stray).write(to: directory.appendingPathComponent("\(stray.id).json"))
            try Data([0, 0, 0, 0]).write(to: directory.appendingPathComponent("\(UUID()).pcm"))
            try Data("broken".utf8).write(to: directory.appendingPathComponent("\(UUID()).json"))
            let mismatched = makeMeta(at: 1)
            let otherID = UUID()
            try JSONEncoder().encode(mismatched).write(to: directory.appendingPathComponent("\(otherID).json"))
            try Data().write(to: directory.appendingPathComponent("\(otherID).pcm"))
            #expect(store.pending() == [older, newer])
        }
    }

    @Test func protectionCoversBothFiles() throws {
        let recorder = ProtectionRecorder()
        try withStore(protection: { url, protection in recorder.record(url, protection) }) { _, store in
            let meta = makeMeta(at: 10)
            try store.begin(meta).close()
            #expect(recorder.entries == [
                .init(name: "\(meta.id).pcm", protection: .whileOpen),
                .init(name: "\(meta.id).json", protection: .whileOpen),
            ])
            try store.seal(meta.id)
            #expect(Array(recorder.entries.suffix(2)) == [
                .init(name: "\(meta.id).pcm", protection: .complete),
                .init(name: "\(meta.id).json", protection: .complete),
            ])
        }
    }

    @Test(arguments: [1, 2, 3])
    func truncatedTrailingFloatIsDropped(trailingBytes: Int) throws {
        try withStore { directory, store in
            let meta = makeMeta(at: 10)
            let writer = try store.begin(meta)
            try writer.append([0.5, -1])
            try writer.close()
            let file = try FileHandle(forWritingTo: directory.appendingPathComponent("\(meta.id).pcm"))
            try file.seekToEnd()
            try file.write(contentsOf: Data(repeating: 255, count: trailingBytes))
            try file.close()
            #expect(try store.samples(meta.id) == [0.5, -1])
        }
    }

    @Test func deleteIsIdempotent() throws {
        try withStore { directory, store in
            let meta = makeMeta(at: 10)
            try store.begin(meta).close()
            store.delete(meta.id)
            store.delete(meta.id)
            #expect(store.pending().isEmpty)
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            #expect(throws: (any Error).self) { try store.samples(meta.id) }
        }
    }

    @Test func purgeKeepsClipsAtCutoffAndNewer() throws {
        try withStore { directory, store in
            let old = makeMeta(at: 9)
            let boundary = makeMeta(at: 10)
            let newer = makeMeta(at: 11)
            for meta in [old, boundary, newer] { try store.begin(meta).close() }
            store.purge(olderThan: Date(timeIntervalSince1970: 10))
            store.purge(olderThan: Date(timeIntervalSince1970: 10))
            #expect(store.pending() == [boundary, newer])
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(old.id).pcm").path))
            #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(old.id).json").path))
        }
    }
}

private func makeMeta(at seconds: Double, purpose: ClipMeta.Purpose = .insert) -> ClipMeta {
    ClipMeta(id: UUID(), convId: "conversation", createdAt: Date(timeIntervalSince1970: seconds), purpose: purpose)
}

private func withStore(
    protection: @escaping @Sendable (URL, ClipProtection) throws -> Void = { _, _ in },
    _ body: (URL, ClipStore) throws -> Void
) throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory, ClipStore(directory: directory, protection: protection))
}

// The synchronous protection callback can arrive from any thread.
private final class ProtectionRecorder: @unchecked Sendable {
    struct Entry: Equatable {
        var name: String
        var protection: ClipProtection
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []
    var entries: [Entry] { lock.withLock { recorded } }

    func record(_ url: URL, _ protection: ClipProtection) {
        lock.withLock { recorded.append(Entry(name: url.lastPathComponent, protection: protection)) }
    }
}

extension ClipStoreTests {
    @Test func duplicateBeginCannotOverwriteRecoverableAudio() throws {
        try withStore { _, store in
            let meta = makeMeta(at: 10)
            let writer = try store.begin(meta)
            try writer.append([0.5])
            try writer.close()
            #expect(throws: (any Error).self) { try store.begin(meta) }
            #expect(store.pending() == [meta])
            #expect(try store.samples(meta.id) == [0.5])
        }
    }

    @Test(arguments: ["pcm", "json"])
    func failedProtectionLeavesNoUnprotectedClip(failingExtension: String) throws {
        try withStore(protection: { url, _ in
            if url.pathExtension == failingExtension { throw CocoaError(.fileWriteNoPermission) }
        }) { directory, store in
            #expect(throws: (any Error).self) { try store.begin(makeMeta(at: 10)) }
            #expect(store.pending().isEmpty)
            let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(files.isEmpty)
        }
    }

    @Test func concurrentAppendsKeepEveryChunkIntact() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ClipStore(directory: directory, protection: { _, _ in })
        let meta = makeMeta(at: 10)
        let writer = try store.begin(meta)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<16 {
                group.addTask { try writer.append([Float(index), Float(index)]) }
            }
            try await group.waitForAll()
        }
        try writer.close()
        let samples = try store.samples(meta.id)
        #expect(samples.count == 32)
        #expect(samples.sorted() == (0..<16).flatMap { [Float($0), Float($0)] })
        for offset in stride(from: 0, to: samples.count - 1, by: 2) {
            #expect(samples[offset] == samples[offset + 1])
        }
        #expect(throws: (any Error).self) { try writer.append([1]) }
    }
}
