import Foundation
import ImageIO
import Observation
import OSLog
import UniformTypeIdentifiers
import YorozuWire

enum AttachmentFiles {
    static let directory = clientDirectory("Attachments")

    static func url(_ attachment: ChatAttachment) -> URL {
        directory.appending(path: attachment.id, directoryHint: .isDirectory).appending(path: safeName(attachment.name))
    }

    static func local(_ attachment: ChatAttachment) -> URL? {
        let url = url(attachment)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    static func write(_ data: Data, for attachment: ChatAttachment) throws { try write(data, to: url(attachment)) }

    /// A file of the transfer's own next to the attachment (`.upload.json`, `.download.part`, …).
    static func sidecar(_ name: String, of attachment: ChatAttachment) -> URL {
        url(attachment).deletingLastPathComponent().appending(path: name)
    }

    static func save<T: Encodable>(_ value: T, as name: String, of attachment: ChatAttachment) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? write(data, to: sidecar(name, of: attachment))
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String, of attachment: ChatAttachment) -> T? {
        (try? Data(contentsOf: sidecar(name, of: attachment))).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    static func discard(_ names: String..., of attachment: ChatAttachment) {
        for name in names { try? FileManager.default.removeItem(at: sidecar(name, of: attachment)) }
    }

    /// An empty file, protected like the attachments, replacing any there.
    static func create(_ url: URL) throws {
        try makeDirectory(url.deletingLastPathComponent())
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private static func write(_ data: Data, to url: URL) throws {
        try makeDirectory(url.deletingLastPathComponent())
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try data.write(to: url, options: options)
    }

    static func remove(_ attachment: ChatAttachment) {
        try? FileManager.default.removeItem(at: url(attachment).deletingLastPathComponent())
    }

    static func wipe() { try? FileManager.default.removeItem(at: directory) }

    static func safeName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "file" + cleaned : cleaned
    }

    private static func makeDirectory(_ url: URL) throws {
        let root = !FileManager.default.fileExists(atPath: directory.path)
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        if root {
            var top = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? top.setResourceValues(values)
        }
    }
}

enum AttachmentStaging {
    enum Failure: LocalizedError {
        case tooLarge(name: String, size: Int, limit: Int)
        case unreadable(name: String)

        var errorDescription: String? {
            switch self {
            case .tooLarge(let name, let size, let limit):
                String(localized: "“\(name)” is \(Self.format(size)). Yorozu sends files up to \(Self.format(limit)).")
            case .unreadable(let name):
                String(localized: "Couldn’t read “\(name)”.")
            }
        }

        static func format(_ bytes: Int) -> String {
            ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
        }
    }

    static func stage(file url: URL, limit: Int) throws -> ChatAttachment {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let name = url.lastPathComponent
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { throw Failure.unreadable(name: name) }
        guard size <= limit else { throw Failure.tooLarge(name: name, size: size, limit: limit) }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw Failure.unreadable(name: name) }
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        return try stage(data: data, name: name, mime: mime, limit: limit)
    }

    static func stage(image data: Data, name: String, limit: Int) throws -> ChatAttachment {
        let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap { CGImageSourceGetType($0) as String? }
        if let type, type == UTType.jpeg.identifier || type == UTType.png.identifier || type == UTType.gif.identifier {
            let mime = UTType(type)?.preferredMIMEType ?? "image/jpeg"
            let ext = UTType(type)?.preferredFilenameExtension ?? "jpg"
            let named = (name as NSString).pathExtension.isEmpty ? "\(name).\(ext)" : name
            return try stage(data: data, name: named, mime: mime, limit: limit)
        }
        guard let jpeg = jpeg(data) else { throw Failure.unreadable(name: name) }
        let base = (name as NSString).deletingPathExtension
        return try stage(data: jpeg, name: (base.isEmpty ? "Photo" : base) + ".jpg", mime: "image/jpeg", limit: limit)
    }

    static func stage(data: Data, name: String, mime: String, limit: Int) throws -> ChatAttachment {
        guard data.count <= limit else { throw Failure.tooLarge(name: name, size: data.count, limit: limit) }
        let attachment = ChatAttachment(id: WireEvent.newId(), name: AttachmentFiles.safeName(name), mime: mime, size: data.count)
        try AttachmentFiles.write(data, for: attachment)
        return attachment
    }

    private static func jpeg(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 4096,
              ] as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

@MainActor @Observable
final class Transfers {
    private(set) var progress: [String: Double] = [:]
    private(set) var failures: [String: String] = [:]

    enum Outcome { case ack(index: Int, done: Bool), state(UploadState), chunk(Chunk), refused(code: String, message: String), lost }

    @ObservationIgnored var send: (WireEvent) async -> Bool = { _ in false }
    /// The host's `peer_info` lists `resume`: uploads ask what it holds and carry the file's SHA-256.
    @ObservationIgnored var resumable = false
    @ObservationIgnored private var inbox: [String: [Outcome]] = [:]
    @ObservationIgnored private var waiters: [String: CheckedContinuation<Outcome, Never>] = [:]
    @ObservationIgnored private var wanted: [ChatAttachment] = []
    @ObservationIgnored private var downloading = false

    static let uploadWindow = 4
    static let downloadWindow = 2
    static let ackTimeout: Duration = .seconds(30)
    static let ledgerEvery = 16
    static let ledgerInterval: Duration = .seconds(1)
    static let uploadLedger = ".upload.json"
    static let downloadLedger = ".download.json"
    static let downloadPart = ".download.part"
    private static let log = Logger(subsystem: "to.yumi.yorozu", category: "Transfers")

    func receive(_ event: WireEvent) {
        switch event {
        case .uploadAck(let ack): deliver(.ack(index: ack.index, done: ack.done), to: ack.attachmentId)
        case .uploadState(let state): deliver(.state(state), to: state.attachmentId)
        case .chunk(let chunk): deliver(.chunk(chunk), to: chunk.attachmentId)
        case .error(let error):
            if let id = error.attachmentId { deliver(.refused(code: error.code, message: error.message), to: id) }
        default: break
        }
    }

    func sessionLost() {
        inbox = [:]
        for (_, waiter) in waiters { waiter.resume(returning: .lost) }
        waiters = [:]
    }

    private func deliver(_ outcome: Outcome, to id: String) {
        if let waiter = waiters.removeValue(forKey: id) { waiter.resume(returning: outcome) } else { inbox[id, default: []].append(outcome) }
    }

    private func next(_ id: String) async -> Outcome {
        if var queued = inbox[id], !queued.isEmpty {
            let first = queued.removeFirst()
            inbox[id] = queued
            return first
        }
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: Self.ackTimeout)
            guard !Task.isCancelled else { return }
            self?.deliver(.lost, to: id)
        }
        defer { timeout.cancel() }
        return await withCheckedContinuation { waiters[id] = $0 }
    }

    enum UploadResult { case stored, refused(String), interrupted }

    func upload(_ attachment: ChatAttachment) async -> UploadResult {
        guard let url = AttachmentFiles.local(attachment), let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            return .refused(String(localized: "The file is no longer on this device."))
        }
        let id = attachment.id
        inbox[id] = nil
        progress[id] = 0
        defer { progress[id] = nil; inbox[id] = nil }
        var sender = UploadSender(size: data.count, window: Self.uploadWindow)
        var ledger: UploadLedger?
        if resumable {
            ledger = await uploadLedger(attachment, at: url, size: data.count)
            if let known = ledger {
                let status = UploadStatus(attachmentId: id, size: data.count, count: sender.count, sha256: known.sha256)
                guard await send(.uploadStatus(status)) else { return .interrupted }
                switch await held(id) {
                case .state(let state):
                    if state.done {
                        AttachmentFiles.discard(Self.uploadLedger, of: attachment)
                        return .stored
                    }
                    let lacked = known.acked.ranges.joined().filter { !state.have.contains($0) }.count
                    if lacked > 0 { Self.log.info("upload resumes; the host lacks \(lacked) of \(known.acked.covered) acked chunks") }
                    sender.resume(have: state.have)
                    progress[id] = sender.progress
                case .refused(_, let why):
                    AttachmentFiles.discard(Self.uploadLedger, of: attachment)
                    return .refused(why)
                default: return .interrupted
                }
            }
        }
        var restarted = false, unsaved = 0, savedAt = ContinuousClock.now
        func persist() {
            guard var known = ledger else { return }
            known.acked = sender.acked
            ledger = known
            AttachmentFiles.save(known, as: Self.uploadLedger, of: attachment)
            (unsaved, savedAt) = (0, .now)
        }
        persist()
        while true {
            while let index = sender.next() {
                let upload = Upload(attachmentId: id, name: attachment.wire.name, mime: attachment.wire.mime, size: data.count,
                    index: index, count: sender.count, data: data.subdata(in: sender.range(of: index)).base64EncodedString(),
                    sha256: ledger?.sha256)
                guard await send(.upload(upload)) else { persist(); return .interrupted }
            }
            switch await self.next(id) {
            case .ack(let index, let done):
                if done {
                    AttachmentFiles.discard(Self.uploadLedger, of: attachment)
                    return .stored
                }
                sender.ack(index)
                progress[id] = sender.progress
                unsaved += 1
                if unsaved >= Self.ledgerEvery || ContinuousClock.now - savedAt >= Self.ledgerInterval { persist() }
            case .refused(let code, let why):
                // The host dropped what it had; start over once, with the hash read again.
                if code == ErrorInfo.hashMismatch, ledger != nil, !restarted,
                   let sha256 = await Self.sha256(of: url) {
                    restarted = true
                    ledger = UploadLedger(attachmentId: id, size: data.count, sha256: sha256)
                    sender.restart()
                    progress[id] = 0
                    persist()
                    continue
                }
                AttachmentFiles.discard(Self.uploadLedger, of: attachment)
                return .refused(why)
            case .lost:
                persist()
                return .interrupted
            case .chunk, .state: break
            }
        }
    }

    private func held(_ id: String) async -> Outcome {
        while true {
            switch await next(id) {
            case .ack, .chunk: continue
            case let outcome: return outcome
            }
        }
    }

    /// The saved ledger when it is for this file, else a new one with the file's SHA-256.
    private func uploadLedger(_ attachment: ChatAttachment, at url: URL, size: Int) async -> UploadLedger? {
        if let saved = AttachmentFiles.load(UploadLedger.self, from: Self.uploadLedger, of: attachment),
           saved.attachmentId == attachment.id, saved.size == size, FileDigest.isSHA256(saved.sha256) { return saved }
        return await Self.sha256(of: url).map { UploadLedger(attachmentId: attachment.id, size: size, sha256: $0) }
    }

    private nonisolated static func sha256(of url: URL) async -> String? {
        await Task.detached(priority: .utility) { try? FileDigest.sha256(of: url) }.value
    }

    func fetch(_ attachment: ChatAttachment) {
        guard AttachmentFiles.local(attachment) == nil, progress[attachment.id] == nil,
              !wanted.contains(where: { $0.id == attachment.id }) else { return }
        failures[attachment.id] = nil
        wanted.append(attachment)
        progress[attachment.id] = 0
        pumpDownloads()
    }

    func resumeDownloads() { pumpDownloads() }

    private func pumpDownloads() {
        guard !downloading, !wanted.isEmpty else { return }
        downloading = true
        Task {
            while let attachment = wanted.first {
                let finished = await download(attachment)
                if !finished { break }
                wanted.removeFirst()
            }
            downloading = false
        }
    }

    /// What a download holds so far in `.download.part`; `count` is known from the first chunk.
    private struct DownloadLedger: Codable {
        var size: Int
        var count: Int?
        var have = ChunkRanges()
    }

    private func download(_ attachment: ChatAttachment) async -> Bool {
        let id = attachment.id
        inbox[id] = nil
        let part = AttachmentFiles.sidecar(Self.downloadPart, of: attachment)
        let damaged = String(localized: "The file arrived damaged.")
        let fail = { (why: String) -> Bool in
            self.failures[id] = why
            self.progress[id] = nil
            AttachmentFiles.discard(Self.downloadPart, Self.downloadLedger, of: attachment)
            return true
        }
        var ledger = AttachmentFiles.load(DownloadLedger.self, from: Self.downloadLedger, of: attachment)
            .flatMap { $0.size == attachment.size && FileManager.default.fileExists(atPath: part.path) ? $0 : nil }
            ?? DownloadLedger(size: attachment.size)
        let handle: FileHandle
        do {
            if ledger.have.covered == 0 { try AttachmentFiles.create(part) }
            handle = try FileHandle(forUpdating: part)
        } catch { return fail(error.localizedDescription) }
        defer { try? handle.close() }
        if let count = ledger.count { progress[id] = Double(ledger.have.covered) / Double(count) }
        var asked = Set<Int>(), unsaved = 0, savedAt = ContinuousClock.now
        func persist() {
            try? handle.synchronize()
            AttachmentFiles.save(ledger, as: Self.downloadLedger, of: attachment)
            (unsaved, savedAt) = (0, .now)
        }
        while true {
            let count = ledger.count ?? 1
            while asked.count < Self.downloadWindow,
                  let index = (0..<count).first(where: { !ledger.have.contains($0) && !asked.contains($0) }) {
                guard await send(.download(Download(attachmentId: id, index: index))) else { persist(); return false }
                asked.insert(index)
            }
            switch await self.next(id) {
            case .chunk(let chunk):
                asked.remove(chunk.index)
                guard let bytes = Data(base64Encoded: chunk.data), ledger.count.map({ $0 == chunk.count }) ?? true,
                      chunk.index == chunk.count - 1 || bytes.count == Attachment.chunkBytes else { return fail(damaged) }
                do {
                    try handle.seek(toOffset: UInt64(chunk.index * Attachment.chunkBytes))
                    try handle.write(contentsOf: bytes)
                } catch { return fail(error.localizedDescription) }
                ledger.count = chunk.count
                ledger.have.insert(chunk.index)
                progress[id] = Double(ledger.have.covered) / Double(chunk.count)
                guard ledger.have.covered == chunk.count else {
                    unsaved += 1
                    if unsaved >= Self.ledgerEvery || ContinuousClock.now - savedAt >= Self.ledgerInterval { persist() }
                    continue
                }
                do {
                    try handle.synchronize()
                    let length = try handle.seekToEnd()
                    guard attachment.size == 0 || length == UInt64(attachment.size) else { return fail(damaged) }
                    try FileManager.default.moveItem(at: part, to: AttachmentFiles.url(attachment))
                } catch { return fail(error.localizedDescription) }
                AttachmentFiles.discard(Self.downloadLedger, of: attachment)
                progress[id] = nil
                return true
            case .refused(_, let why): return fail(why)
            case .lost:
                persist()
                return false
            case .ack, .state: break
            }
        }
    }
}
