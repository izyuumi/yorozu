import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers
import YorozuWire

// Attachments (#316), the phone's half: what a file looks like on a message, how the outbox keeps
// a message's files until the Mac has them, and the cache of thumbnails and opened files.

/// One file on a message or a worker event: the wire's descriptor (id, name, mime, bytes, sha256).
struct AttachmentInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    /// The Mac's attachment id once stored; a local id while the message waits in the outbox.
    var id: String
    var name: String
    var mime: String
    var bytes: Int
    var sha256: String?

    var isImage: Bool { mime.hasPrefix("image/") }
    var size: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    /// "PDF document", "JPEG image": the system's name for the type.
    var typeName: String { UTType(mimeType: mime)?.localizedDescription ?? mime }

    /// The cache's key: the content hash when known, so a file sent from this phone is already
    /// cached under the descriptor the Mac sends back.
    var cacheKey: String {
        (sha256 ?? id).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }
}

/// The owner's limits (#316 Decisions): 50 MB per file, 10 files per message.
enum AttachmentLimits {
    static let maxBytes = 50 * 1024 * 1024
    static let maxCount = 10
    /// The Mac's capability for attachments in contract 0.7.
    // WIRE: the capability name the reworked YorozuWire advertises.
    static let capability = "attachments-v1"
}

// WIRE: descriptors on messages and worker events. Map the reworked YorozuWire descriptor
// (id, name, mime, bytes, sha256) here; until then nothing on the wire carries one.
extension MessageData {
    var attachmentInfos: [AttachmentInfo] { [] }
}

// WIRE: see `MessageData.attachmentInfos`. Sub-chat images (intermediate images a worker shares).
extension WorkerEventData {
    var attachmentInfos: [AttachmentInfo] { [] }
}

// MARK: Transport

enum AttachmentKind: String, Sendable {
    case thumbnail, full
}

/// One file to upload: its descriptor and the protected copy in the outbox.
struct UploadFile: Sendable {
    let info: AttachmentInfo
    let url: URL
}

enum AttachmentTransportError: LocalizedError, Equatable {
    /// No live session with a Mac that takes attachments. The outbox tries again on the next one.
    case notAvailable
    /// The Mac no longer has the file (`attachment-unavailable`).
    case unavailable
    /// The Mac refused the message for good: Not delivered, with this reason.
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .notAvailable: String(localized: "Attachments aren’t available right now.")
        case .unavailable: String(localized: "File no longer available")
        case .rejected(let reason): reason
        }
    }
}

/// How attachments travel between the phone and the Mac, on whichever path is live (relay or direct).
protocol AttachmentTransport: Sendable {
    /// Uploads `message` (a user `message` event, its text possibly empty) with its files, each from
    /// `resumeFrom[i]`. Calls `progress(index, nextOffset)` each time the Mac confirms a chunk, and
    /// returns once the Mac has stored the message and every file. Throws `.rejected` when the Mac
    /// refuses it for good; any other error leaves it for the next live session.
    func upload(messageID: String, message: YorozuEvent, files: [UploadFile], resumeFrom: [Int],
                progress: @escaping @Sendable (_ index: Int, _ nextOffset: Int) async -> Void) async throws

    /// Downloads one attachment's thumbnail or full file to `to`, reporting `progress` from 0 to 1.
    /// Throws `.unavailable` when the Mac no longer has the file.
    func download(attachmentID: String, kind: AttachmentKind, to: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws
}

// WIRE: replace with a conformance over `RelayClient` (resumable `attachment_chunk` upload answered by
// `attachment_progress.nextOffset`, idempotent `attachment_commit`, `attachment_download_request` for
// the thumbnail or the full file), and build it in `PhoneModel.connect`.
struct UnwiredAttachmentTransport: AttachmentTransport {
    func upload(messageID: String, message: YorozuEvent, files: [UploadFile], resumeFrom: [Int],
                progress: @escaping @Sendable (Int, Int) async -> Void) async throws {
        throw AttachmentTransportError.notAvailable
    }

    func download(attachmentID: String, kind: AttachmentKind, to: URL,
                  progress: @escaping @Sendable (Double) -> Void) async throws {
        throw AttachmentTransportError.notAvailable
    }
}

// MARK: Files on disk

/// A folder in `Application Support`, encrypted at rest like `ProtectedFile` and excluded from backup.
func protectedFolder(_ name: String) -> URL {
    URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
}

func makeProtectedDirectory(_ url: URL) throws {
    guard !FileManager.default.fileExists(atPath: url.path) else { return }
    try FileManager.default.createDirectory(
        at: url, withIntermediateDirectories: true,
        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
    var url = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try url.setResourceValues(values)
}

/// The SHA-256 of a file, hex, read in pieces so a 50 MB file never sits in memory whole.
func sha256Hex(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let piece = try handle.read(upToCount: 1 << 20), !piece.isEmpty { hash.update(data: piece) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// A name safe as one path component.
func safeFileName(_ name: String) -> String {
    let cleaned = String(name.map { $0 == "/" || $0 == ":" || $0.isNewline ? "_" : $0 }).trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty || cleaned.hasPrefix(".") ? "file" + cleaned : cleaned
}

/// The outbox's copies of a message's files, `Application Support/Uploads/<message>/<index>`, and the
/// per-file upload offsets beside them, fsynced so a relaunch resumes where the Mac last confirmed.
enum UploadStore {
    static let root = protectedFolder("Uploads")

    static func folder(_ messageId: String) -> URL { root.appending(path: safeFileName(messageId), directoryHint: .isDirectory) }
    static func url(_ messageId: String, _ index: Int) -> URL { folder(messageId).appending(path: "\(index)") }
    private static func offsetsFile(_ messageId: String) -> URL { folder(messageId).appending(path: "offsets.json") }

    /// Moves each draft's chosen file into the outbox (one volume, so no copy) and returns the descriptors.
    static func store(_ drafts: [DraftFile], for messageId: String) throws -> [AttachmentInfo] {
        try makeProtectedDirectory(root)
        try makeProtectedDirectory(folder(messageId))
        do {
            return try drafts.enumerated().map { index, draft in
                let chosen = draft.chosen
                let target = url(messageId, index)
                try FileManager.default.moveItem(at: chosen.url, to: target)
                try FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                draft.discard()
                return AttachmentInfo(id: UUID().uuidString, name: chosen.name, mime: chosen.mime, bytes: chosen.bytes, sha256: chosen.sha256)
            }
        } catch {
            remove(messageId)
            throw error
        }
    }

    static func offsets(_ messageId: String, count: Int) -> [Int] {
        let saved = (try? Data(contentsOf: offsetsFile(messageId))).flatMap { try? JSONDecoder().decode([Int].self, from: $0) } ?? []
        return saved.count == count ? saved : Array(repeating: 0, count: count)
    }

    /// Written whole, then fsynced: an offset the Mac confirmed survives a force quit.
    static func setOffsets(_ messageId: String, _ offsets: [Int]) {
        let file = offsetsFile(messageId)
        do {
            try JSONEncoder().encode(offsets).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let handle = try FileHandle(forUpdating: file)
            defer { try? handle.close() }
            try handle.synchronize()
        } catch {
            // A lost offset only means resending from the previous one.
        }
    }

    static func exists(_ messageId: String, count: Int) -> Bool {
        (0..<count).allSatisfy { FileManager.default.fileExists(atPath: url(messageId, $0).path) }
    }

    static func remove(_ messageId: String) { try? FileManager.default.removeItem(at: folder(messageId)) }
    static func wipe() { try? FileManager.default.removeItem(at: root) }
}

// MARK: Cache

/// Thumbnails and opened files, `Application Support/Files/<key>/`, protected like the mirror cache
/// and wiped with it. Thumbnails download when a message shows; full files when tapped.
@MainActor
@Observable
final class AttachmentFiles {
    private(set) var thumbnails: [String: UIImage] = [:]
    /// A full file's download progress, 0 to 1, by cache key.
    private(set) var progress: [String: Double] = [:]
    /// Files the Mac no longer has: "File no longer available".
    private(set) var missing: Set<String> = []

    @ObservationIgnored var transport: any AttachmentTransport = UnwiredAttachmentTransport()
    /// Files still in the outbox, shown from there until the Mac has them.
    @ObservationIgnored private var local: [String: URL] = [:]
    @ObservationIgnored private var loading: Set<String> = []

    private static let root = protectedFolder("Files")
    /// The long edge a thumbnail is decoded at: sharp at three times a two-column grid on a phone.
    private static let thumbnailPixels = 600

    func register(_ url: URL, for info: AttachmentInfo) { local[info.cacheKey] = url }

    /// After the Mac stored a message from this phone: its outbox copies become cached full files.
    func adopt(_ infos: [AttachmentInfo], from messageId: String) {
        for (index, info) in infos.enumerated() {
            let source = UploadStore.url(messageId, index)
            let target = fullURL(info)
            local[info.cacheKey] = nil
            guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { continue }
            try? makeProtectedDirectory(Self.root)
            try? makeProtectedDirectory(folder(info))
            try? FileManager.default.moveItem(at: source, to: target)
        }
    }

    /// The thumbnail of an image, from the outbox copy, the cached file or a download.
    func loadThumbnail(_ info: AttachmentInfo) async {
        let key = info.cacheKey
        guard info.isImage, thumbnails[key] == nil, !missing.contains(key), !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        let candidates = [local[key], fullURL(info), thumbnailURL(info)].compactMap { $0 }
        var source = candidates.first { FileManager.default.fileExists(atPath: $0.path) }
        if source == nil {
            guard await fetch(info, .thumbnail, to: thumbnailURL(info), tracked: false) else { return }
            source = thumbnailURL(info)
        }
        guard let source else { return }
        let pixels = Self.thumbnailPixels
        let image = await Task.detached { downsample(source, maxPixels: pixels) }.value
        thumbnails[key] = image
    }

    /// The full file, downloading it first (with `progress`) unless it is cached or still in the outbox.
    func open(_ info: AttachmentInfo) async -> URL? {
        let key = info.cacheKey
        if let url = local[key], FileManager.default.fileExists(atPath: url.path) { return url }
        let target = fullURL(info)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        guard progress[key] == nil, !missing.contains(key) else { return nil }
        return await fetch(info, .full, to: target, tracked: true) ? target : nil
    }

    func wipe() {
        thumbnails = [:]
        progress = [:]
        missing = []
        local = [:]
        try? FileManager.default.removeItem(at: Self.root)
    }

    /// Downloads into a temporary file and moves it into place only once whole.
    private func fetch(_ info: AttachmentInfo, _ kind: AttachmentKind, to target: URL, tracked: Bool) async -> Bool {
        let key = info.cacheKey
        let partial = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        if tracked { progress[key] = 0 }
        defer {
            if tracked { progress[key] = nil }
            try? FileManager.default.removeItem(at: partial)
        }
        do {
            try await transport.download(attachmentID: info.id, kind: kind, to: partial) { [weak self] value in
                guard tracked else { return }
                Task { @MainActor in if self?.progress[key] != nil { self?.progress[key] = value } }
            }
            try makeProtectedDirectory(Self.root)
            try makeProtectedDirectory(folder(info))
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.moveItem(at: partial, to: target)
            return true
        } catch AttachmentTransportError.unavailable {
            missing.insert(key)
            return false
        } catch {
            return false
        }
    }

    private func folder(_ info: AttachmentInfo) -> URL { Self.root.appending(path: info.cacheKey, directoryHint: .isDirectory) }
    private func fullURL(_ info: AttachmentInfo) -> URL { folder(info).appending(path: safeFileName(info.name)) }
    private func thumbnailURL(_ info: AttachmentInfo) -> URL { folder(info).appending(path: ".thumbnail") }
}

/// Decodes an image file at most `maxPixels` on its long edge, upright, without the full bitmap.
func downsample(_ url: URL, maxPixels: Int) -> UIImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init(cgImage:))
}
