import Foundation
import Synchronization

struct ClipMeta: Codable, Equatable, Sendable {
    var id: UUID
    var convId: String
    var createdAt: Date
    var purpose: Purpose

    enum Purpose: String, Codable, Sendable {
        case insert, send
    }
}

enum ClipProtection: Equatable, Sendable {
    case whileOpen, complete
}

final class ClipStore: Sendable {
    private let directory: URL
    private let protection: @Sendable (URL, ClipProtection) throws -> Void
    private let lock = NSLock()

    init(directory: URL, protection: @escaping @Sendable (URL, ClipProtection) throws -> Void) {
        self.directory = directory
        self.protection = protection
    }

    func begin(_ meta: ClipMeta) throws -> ClipWriter {
        try lock.withLock {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let pcm = url(meta.id, extension: "pcm")
            let json = url(meta.id, extension: "json")
            guard !FileManager.default.fileExists(atPath: pcm.path),
                  !FileManager.default.fileExists(atPath: json.path) else {
                throw CocoaError(.fileWriteFileExists)
            }
            try Data().write(to: pcm, options: .withoutOverwriting)
            do {
                try protection(pcm, .whileOpen)
                let writer = try ClipWriter(url: pcm)
                try JSONEncoder().encode(meta).write(to: json, options: .atomic)
                try protection(json, .whileOpen)
                return writer
            } catch {
                try? FileManager.default.removeItem(at: json)
                try? FileManager.default.removeItem(at: pcm)
                throw error
            }
        }
    }

    func pending() -> [ClipMeta] {
        lock.withLock {
            metadata().filter { FileManager.default.fileExists(atPath: url($0.id, extension: "pcm").path) }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }

    func samples(_ id: UUID) throws -> [Float] {
        try lock.withLock {
            let data = try Data(contentsOf: url(id, extension: "pcm"))
            return data.withUnsafeBytes { bytes in
                stride(from: 0, to: data.count - data.count % 4, by: 4).map { offset in
                    Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self)))
                }
            }
        }
    }

    func seal(_ id: UUID) throws {
        try lock.withLock {
            try protection(url(id, extension: "pcm"), .complete)
            try protection(url(id, extension: "json"), .complete)
        }
    }

    func delete(_ id: UUID) {
        lock.withLock { remove(id) }
    }

    func purge(olderThan cutoff: Date) {
        lock.withLock {
            for meta in metadata() where meta.createdAt < cutoff {
                remove(meta.id)
            }
        }
    }

    private func remove(_ id: UUID) {
        try? FileManager.default.removeItem(at: url(id, extension: "json"))
        try? FileManager.default.removeItem(at: url(id, extension: "pcm"))
    }

    private func metadata() -> [ClipMeta] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { file in
            guard file.pathExtension == "json",
                  let data = try? Data(contentsOf: file),
                  let meta = try? JSONDecoder().decode(ClipMeta.self, from: data),
                  UUID(uuidString: file.deletingPathExtension().lastPathComponent) == meta.id else { return nil }
            return meta
        }
    }

    private func url(_ id: UUID, extension ext: String) -> URL {
        directory.appendingPathComponent("\(id).\(ext)")
    }
}

/// Every append reaches the file at once, so a crash or jetsam keeps it; `fsync` runs at most every
/// `syncInterval` (the tap delivers about ten chunks a second) and on close.
final class ClipWriter: Sendable {
    static let syncInterval: TimeInterval = 1

    private let file: FileHandle
    /// The last `fsync`; the lock also keeps appends whole.
    private let synced = Mutex(Date.distantPast)

    fileprivate init(url: URL) throws {
        file = try FileHandle(forWritingTo: url)
    }

    func append(_ samples: [Float]) throws {
        try synced.withLock { last in
            let data = samples.map { $0.bitPattern.littleEndian }.withUnsafeBytes { Data($0) }
            try file.write(contentsOf: data)
            let now = Date()
            guard now.timeIntervalSince(last) >= Self.syncInterval else { return }
            try file.synchronize()
            last = now
        }
    }

    func close() throws {
        try synced.withLock { _ in
            try file.synchronize()
            try file.close()
        }
    }
}
