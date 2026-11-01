import CryptoKit
import Foundation

/// Chunk indices as sorted, merged, half-open ranges; on the wire `[[start, end], …]`.
public struct ChunkRanges: Codable, Equatable, Sendable {
    public private(set) var ranges: [Range<Int>] = []

    public init() {}

    public init(_ ranges: [Range<Int>]) {
        for range in ranges { insert(range) }
    }

    public init(from decoder: Decoder) throws {
        let pairs = try decoder.singleValueContainer().decode([[Int]].self)
        guard pairs.allSatisfy({ $0.count == 2 && $0[0] >= 0 && $0[0] <= $0[1] }) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad chunk range"))
        }
        self.init(pairs.map { $0[0]..<$0[1] })
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(ranges.map { [$0.lowerBound, $0.upperBound] })
    }

    public mutating func insert(_ index: Int) { insert(index..<(index + 1)) }

    public mutating func insert(_ range: Range<Int>) {
        guard !range.isEmpty else { return }
        var merged = range
        var kept: [Range<Int>] = []
        for r in ranges {
            if r.upperBound < merged.lowerBound || r.lowerBound > merged.upperBound {
                kept.append(r)
            } else {
                merged = min(r.lowerBound, merged.lowerBound)..<max(r.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        ranges = kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    public func contains(_ index: Int) -> Bool { ranges.contains { $0.contains(index) } }

    /// The indices in `0..<count` not covered, ascending.
    public func missing(count: Int) -> [Int] { (0..<count).filter { !contains($0) } }

    public var covered: Int { ranges.reduce(0) { $0 + $1.count } }
}

/// Capability `resume`: which chunks of an upload the plugin already holds.
public struct UploadStatus: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var size: Int
    public var count: Int
    public var sha256: String

    public init(attachmentId: String, size: Int, count: Int, sha256: String) {
        self.attachmentId = attachmentId
        self.size = size
        self.count = count
        self.sha256 = sha256
    }
}

/// The answer to `upload_status`; `done` when the plugin already stored the attachment.
public struct UploadState: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var done: Bool
    public var have: ChunkRanges

    public init(attachmentId: String, done: Bool, have: ChunkRanges = ChunkRanges()) {
        self.attachmentId = attachmentId
        self.done = done
        self.have = have
    }
}

public enum FileDigest {
    public static func isSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// The file's SHA-256 as lowercase hex, read 1 MiB at a time.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1 << 20), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Which chunk an upload sends next: the ones the receiver lacks, `window` in flight, in index order.
/// Used by the app's uploads and the share extension alike.
public struct UploadSender: Sendable {
    public let size: Int
    public let count: Int
    public let window: Int
    public private(set) var acked = ChunkRanges()
    public private(set) var bytesSent = 0
    private var queue: [Int] = []
    private var inFlight: Set<Int> = []

    public init(size: Int, window: Int, have: ChunkRanges = ChunkRanges()) {
        self.size = size
        self.count = Attachment.chunkCount(size)
        self.window = window
        resume(have: have)
    }

    /// A new session: the receiver holds `have` and nothing is in flight. With every chunk held but the upload
    /// not stored, the last chunk goes again so the receiver assembles it.
    public mutating func resume(have: ChunkRanges) {
        acked = have
        inFlight = []
        let missing = have.missing(count: count)
        queue = (missing.isEmpty ? [count - 1] : missing).reversed()
    }

    /// Start over from chunk 0 (the receiver dropped what it had).
    public mutating func restart() { resume(have: ChunkRanges()) }

    /// The next chunk to send, counted as sent; `nil` while the window is full or nothing is left.
    public mutating func next() -> Int? {
        guard inFlight.count < window, let index = queue.popLast() else { return nil }
        inFlight.insert(index)
        bytesSent += range(of: index).count
        return index
    }

    public mutating func ack(_ index: Int) {
        inFlight.remove(index)
        acked.insert(index)
    }

    public func range(of index: Int) -> Range<Int> {
        (index * Attachment.chunkBytes)..<min(size, (index + 1) * Attachment.chunkBytes)
    }

    public var progress: Double { Double(acked.covered) / Double(count) }
}

/// What the app keeps per attachment upload so a resume survives a relaunch.
public struct UploadLedger: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var size: Int
    public var sha256: String
    public var acked: ChunkRanges

    public init(attachmentId: String, size: Int, sha256: String, acked: ChunkRanges = ChunkRanges()) {
        self.attachmentId = attachmentId
        self.size = size
        self.sha256 = sha256
        self.acked = acked
    }
}
