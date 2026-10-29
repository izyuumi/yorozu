import Foundation
import ImageIO
import Observation
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

    static func write(_ data: Data, for attachment: ChatAttachment) throws {
        let url = url(attachment)
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

    enum Outcome { case ack(index: Int, done: Bool), chunk(Chunk), refused(String), lost }

    @ObservationIgnored var send: (WireEvent) async -> Bool = { _ in false }
    @ObservationIgnored private var inbox: [String: [Outcome]] = [:]
    @ObservationIgnored private var waiters: [String: CheckedContinuation<Outcome, Never>] = [:]
    @ObservationIgnored private var wanted: [ChatAttachment] = []
    @ObservationIgnored private var downloading = false

    static let uploadWindow = 4
    static let downloadWindow = 2
    static let ackTimeout: Duration = .seconds(30)

    func receive(_ event: WireEvent) {
        switch event {
        case .uploadAck(let ack): deliver(.ack(index: ack.index, done: ack.done), to: ack.attachmentId)
        case .chunk(let chunk): deliver(.chunk(chunk), to: chunk.attachmentId)
        case .error(let error):
            if let id = error.attachmentId { deliver(.refused(error.message), to: id) }
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
        let count = Attachment.chunkCount(data.count)
        inbox[id] = nil
        progress[id] = 0
        defer { progress[id] = nil; inbox[id] = nil }
        var next = 0, inFlight = 0, acked = 0
        while true {
            while inFlight < Self.uploadWindow && next < count {
                let range = (next * Attachment.chunkBytes)..<min(data.count, (next + 1) * Attachment.chunkBytes)
                let upload = Upload(attachmentId: id, name: attachment.wire.name, mime: attachment.wire.mime, size: data.count,
                    index: next, count: count, data: data.subdata(in: range).base64EncodedString())
                guard await send(.upload(upload)) else { return .interrupted }
                next += 1
                inFlight += 1
            }
            switch await self.next(id) {
            case .ack(_, let done):
                if done { return .stored }
                inFlight -= 1
                acked += 1
                progress[id] = Double(acked) / Double(count)
            case .refused(let why): return .refused(why)
            case .lost: return .interrupted
            case .chunk: break
            }
        }
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

    private func download(_ attachment: ChatAttachment) async -> Bool {
        let id = attachment.id
        inbox[id] = nil
        var parts: [Int: Data] = [:]
        var count = 1, next = 0, inFlight = 0
        let fail = { (why: String) -> Bool in
            self.failures[id] = why
            self.progress[id] = nil
            return true
        }
        while true {
            while inFlight < Self.downloadWindow && next < count {
                guard await send(.download(Download(attachmentId: id, index: next))) else { return false }
                next += 1
                inFlight += 1
            }
            switch await self.next(id) {
            case .chunk(let chunk):
                inFlight -= 1
                guard let bytes = Data(base64Encoded: chunk.data) else { return fail(String(localized: "The file arrived damaged.")) }
                count = chunk.count
                parts[chunk.index] = bytes
                progress[id] = Double(parts.count) / Double(count)
                guard parts.count == count else { continue }
                let data = (0..<count).reduce(into: Data()) { $0.append(parts[$1] ?? Data()) }
                guard data.count == attachment.size || attachment.size == 0 else { return fail(String(localized: "The file arrived damaged.")) }
                do { try AttachmentFiles.write(data, for: attachment) } catch { return fail(error.localizedDescription) }
                progress[id] = nil
                return true
            case .refused(let why): return fail(why)
            case .lost:
                return false
            case .ack: break
            }
        }
    }
}
