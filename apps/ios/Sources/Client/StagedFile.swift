import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One file staged in the composer, in its own folder under `tmp/Drafts/`.
struct StagedFile: Identifiable, Equatable, Sendable {
    struct Variant: Equatable, Sendable {
        var url: URL
        var name: String
        var mime: String
        var bytes: Int
        var sha256: String

        var size: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    }

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

    static let drafts = FileManager.default.temporaryDirectory.appending(path: "Drafts", directoryHint: .isDirectory)

    /// Drafts do not outlive the app.
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
