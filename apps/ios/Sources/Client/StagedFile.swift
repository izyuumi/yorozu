import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One file staged in the composer, in its own folder under `Application Support/Drafts/files/` (#405: a draft and its files
/// survive a relaunch). Encoded by folder and file name, so it still resolves when iOS moves the app's container.
struct StagedFile: Identifiable, Equatable, Sendable, Codable {
    struct Variant: Equatable, Sendable, Codable {
        var url: URL
        var name: String
        var mime: String
        var bytes: Int
        var sha256: String

        var size: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }

        private enum CodingKeys: String, CodingKey { case file, name, mime, bytes, sha256 }
        /// `folder` is filled in by the enclosing file, which knows where its folder is now.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = StagedFile.drafts.appending(path: try c.decode(String.self, forKey: .file))
            name = try c.decode(String.self, forKey: .name)
            mime = try c.decode(String.self, forKey: .mime)
            bytes = try c.decode(Int.self, forKey: .bytes)
            sha256 = try c.decode(String.self, forKey: .sha256)
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            // Relative to the drafts folder: `<folder>/<file>`.
            try c.encode(url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent, forKey: .file)
            try c.encode(name, forKey: .name)
            try c.encode(mime, forKey: .mime)
            try c.encode(bytes, forKey: .bytes)
            try c.encode(sha256, forKey: .sha256)
        }
        init(url: URL, name: String, mime: String, bytes: Int, sha256: String) {
            self.url = url; self.name = name; self.mime = mime; self.bytes = bytes; self.sha256 = sha256
        }
    }

    private enum CodingKeys: String, CodingKey { case id, file, original, sendOriginal }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        file = try c.decode(Variant.self, forKey: .file)
        original = try c.decodeIfPresent(Variant.self, forKey: .original)
        sendOriginal = try c.decodeIfPresent(Bool.self, forKey: .sendOriginal) ?? false
        folder = Self.drafts.appending(path: id.uuidString, directoryHint: .isDirectory)
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(file, forKey: .file)
        try c.encodeIfPresent(original, forKey: .original)
        try c.encode(sendOriginal, forKey: .sendOriginal)
    }
    init(id: UUID, file: Variant, original: Variant? = nil, sendOriginal: Bool = false, folder: URL) {
        self.id = id; self.file = file; self.original = original; self.sendOriginal = sendOriginal; self.folder = folder
    }
    /// The file is still there (a draft restored after a relaunch).
    var exists: Bool { FileManager.default.fileExists(atPath: chosen.url.path) }

    let id: UUID
    /// What is sent by default: an image reduced to ``imageMaxPixels`` when it needed it, anything else as picked.
    var file: Variant
    /// The image as picked, when `file` is a reduced copy and the original is within the limit: "Send original".
    var original: Variant?
    var sendOriginal = false
    let folder: URL

    var chosen: Variant { sendOriginal ? original ?? file : file }
    var isImage: Bool { file.mime.hasPrefix("image/") }

    func discard() { try? FileManager.default.removeItem(at: folder) }

    static let drafts = clientSupportDirectory.appending(path: "Drafts/files", directoryHint: .isDirectory)

    /// Removes staged files no saved draft refers to (left by a crash or a discarded composer); `keeping` are the ids
    /// the drafts hold, which always stay. The old `tmp/Drafts` folder goes too.
    static func prune(keeping: Set<UUID>) {
        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory.appending(path: "Drafts", directoryHint: .isDirectory))
        let folders = (try? FileManager.default.contentsOfDirectory(at: drafts, includingPropertiesForKeys: nil)) ?? []
        for folder in folders where UUID(uuidString: folder.lastPathComponent).map(keeping.contains) != true {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    /// Every staged file, with no draft left to keep them (Remove host).
    static func clearAll() { try? FileManager.default.removeItem(at: drafts) }

    enum Refusal: Error {
        case unreadable, tooLarge
    }

    /// The long edge a staged image is reduced to (#316): more than any vision model reads an image at.
    static let imageMaxPixels = 2048
    /// Where a re-encode stops being visible.
    static let jpegQuality: CGFloat = 0.85
    /// Image types sent as they are when small enough. HEIC and TIFF are re-encoded whatever their size:
    /// a model on the other end may not read HEIC, and an uncompressed TIFF is megabytes of picture.
    private static let sendableImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// Moves a picked file (a temporary copy) into its own draft folder, reduces an image, and hashes what may
    /// be sent. Blocking: call off the main actor.
    static func stage(_ source: URL, name: String) throws -> StagedFile {
        let id = UUID()
        let folder = drafts.appending(path: id.uuidString, directoryHint: .isDirectory)
        try makeProtectedDirectory(drafts)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let name = safeFileName(name)
            let target = folder.appending(path: name)
            try FileManager.default.moveItem(at: source, to: target)
            let type = UTType(filenameExtension: target.pathExtension)
            let mime = type?.preferredMIMEType ?? "application/octet-stream"
            let bytes = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            var original = Variant(url: target, name: name, mime: mime, bytes: bytes, sha256: "")
            if type?.conforms(to: .image) == true {
                guard let image = CGImageSourceCreateWithURL(target as CFURL, nil), CGImageSourceGetCount(image) > 0 else {
                    throw Refusal.unreadable
                }
                let reducedURL = folder.appending(path: ".reduced.jpg")
                if reduce(image, mime: mime, to: reducedURL) {
                    let reducedBytes = try reducedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard reducedBytes <= AttachmentLimits.maxBytes else { throw Refusal.tooLarge }
                    // The name follows the bytes: a `.heic` that is now a JPEG says so.
                    let reduced = Variant(url: reducedURL, name: "\((name as NSString).deletingPathExtension).jpg", mime: "image/jpeg",
                                          bytes: reducedBytes, sha256: try sha256Hex(of: reducedURL))
                    if bytes <= AttachmentLimits.maxBytes { original.sha256 = try sha256Hex(of: target) }
                    return StagedFile(id: id, file: reduced, original: bytes <= AttachmentLimits.maxBytes ? original : nil, folder: folder)
                }
            }
            guard bytes <= AttachmentLimits.maxBytes else { throw Refusal.tooLarge }
            original.sha256 = try sha256Hex(of: target)
            return StagedFile(id: id, file: original, folder: folder)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// Writes a JPEG at most ``imageMaxPixels`` on its long edge, upright, when the image is longer than
    /// that or of a type not sent as it is. ImageIO decodes, resizes and applies the EXIF orientation in
    /// one step, without the full-size bitmap.
    private static func reduce(_ source: CGImageSource, mime: String, to url: URL) -> Bool {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        let longEdge = max(width, height)
        guard !sendableImageTypes.contains(mime) || longEdge > imageMaxPixels else { return false }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: min(longEdge, imageMaxPixels),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// The draft as a `.txt` file: "Send as Text File" for a draft over the message limit.
    static func textFile(_ text: String) throws -> StagedFile {
        let source = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try Data(text.utf8).write(to: source)
        return try stage(source, name: String(localized: "attachment.textFileName", defaultValue: "Message.txt"))
    }
}
