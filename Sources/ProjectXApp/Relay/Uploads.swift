import CoreGraphics
import Foundation
import ImageIO
import os
import QuickLookThumbnailing
import UniformTypeIdentifiers
import YorozuWire

/// Phone uploads waiting for their commit (docs/ios-relay-contract.md, "Attachments"), translated from v1's
/// `attachment-upload.ts`: `<root>/<device>/<message>/<index>-<sha256>.part`, directories 0700 and files 0600. Each chunk
/// is checked against what is staged and fsynced before its `nextOffset` goes back; a file is hashed once complete and
/// dropped if the hash is wrong. Staging survives relaunches on both sides, so an upload resumes from what is on disk.
/// Caps: one complete message (10 × 50 MB) and a second, at most 64 messages; staging untouched for 48 h is pruned.
/// Not thread-safe: `EngineBridge` calls it from its actor.
struct UploadStaging {
    enum Assembly { case ready([URL]), missing(index: Int, offset: Int), failed(String) }

    let root: URL
    private var lastPrune = Date.distantPast
    static let maxStagedBytes = 2 * Int64(MessageAttachment.maxTotalBytes), maxMessages = 64
    static let staleAfter: TimeInterval = 48 * 3600
    private static let log = Logger(subsystem: "to.yumi.yorozu", category: "relay")

    init(root: URL) { self.root = root }

    /// The staged size of file `index` after this chunk, or a reason.
    mutating func chunk(_ c: AttachmentChunkData, device: String) -> (nextOffset: Int, reason: String?) {
        guard Self.isDevice(device), AttachmentDescriptor.isID(c.messageId), (0..<MessageAttachment.maxCount).contains(c.index),
              (1...MessageAttachment.maxBytes).contains(c.totalBytes), AttachmentDescriptor.isHash(c.sha256),
              (0...c.totalBytes).contains(c.offset), c.data.utf8.count <= (MessageAttachment.chunkBytes + 2) / 3 * 4,
              let bytes = Data(base64Encoded: c.data), bytes.count <= MessageAttachment.chunkBytes, c.offset + bytes.count <= c.totalBytes
        else { return (0, AttachmentReason.invalid) }
        let folder = self.folder(device, c.messageId)
        guard c.deadline > Int(Date().timeIntervalSince1970 * 1000) else { remove(device: device, message: c.messageId); return (0, AttachmentReason.expired) }
        prune()
        let fm = FileManager.default, file = folder.appendingPathComponent("\(c.index)-\(c.sha256).part")
        do {
            if !fm.fileExists(atPath: file.path) {
                let (staged, messages) = usage()
                guard staged + Int64(c.totalBytes) <= Self.maxStagedBytes,
                      fm.fileExists(atPath: folder.path) || messages < Self.maxMessages else { return (0, AttachmentReason.storageFull) }
                try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                // Another version of this file (the phone re-encoded it) starts over.
                for other in try fm.contentsOfDirectory(atPath: folder.path) where other.hasPrefix("\(c.index)-") { try? fm.removeItem(at: folder.appendingPathComponent(other)) }
                guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forUpdating: file)
            defer { try? handle.close() }
            let size = Int(try handle.seekToEnd())
            // A status query, or a chunk past what is staged: the phone continues from here.
            guard !bytes.isEmpty, c.offset <= size, size <= c.totalBytes else {
                if size > c.totalBytes { try handle.truncate(atOffset: 0); return (0, nil) }
                return (size, nil)
            }
            if c.offset < size {
                try handle.seek(toOffset: UInt64(c.offset))
                let overlap = try handle.read(upToCount: min(bytes.count, size - c.offset)) ?? Data()
                // The phone is the source: different bytes replace what was staged from there on.
                if overlap != bytes.prefix(overlap.count) { try handle.truncate(atOffset: UInt64(c.offset)) }
            }
            try handle.seek(toOffset: UInt64(c.offset))
            try handle.write(contentsOf: bytes)
            try handle.synchronize()
            let next = max(size, c.offset + bytes.count)
            if next == c.totalBytes, (try? AttachmentDescriptor.digest(of: file))?.sha256 != c.sha256 {
                try? fm.removeItem(at: file)
                return (0, AttachmentReason.corrupt)
            }
            return (next, nil)
        } catch {
            Self.log.error("upload staging failed: \(error.localizedDescription, privacy: .public)")
            return (0, AttachmentReason.storageFailed)
        }
    }

    /// The staged files of a commit, in order, once each is complete (hashed when its last chunk landed).
    func assemble(_ files: [AttachmentDescriptor], device: String, message: String) -> Assembly {
        let fm = FileManager.default, folder = self.folder(device, message)
        var urls: [URL] = []
        for (index, d) in files.enumerated() {
            let file = folder.appendingPathComponent("\(index)-\(d.sha256).part")
            if d.bytes == 0, !fm.fileExists(atPath: file.path) {
                do { try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
                catch { return .failed(AttachmentReason.storageFailed) }
                guard fm.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return .failed(AttachmentReason.storageFailed) }
            }
            guard let size = (try? fm.attributesOfItem(atPath: file.path))?[.size] as? Int else { return .missing(index: index, offset: 0) }
            if size > d.bytes { try? fm.removeItem(at: file); return .missing(index: index, offset: 0) }
            if size < d.bytes { return .missing(index: index, offset: size) }
            urls.append(file)
        }
        return .ready(urls)
    }

    func remove(device: String, message: String) {
        guard Self.isDevice(device), AttachmentDescriptor.isID(message) else { return }
        try? FileManager.default.removeItem(at: folder(device, message))
    }

    /// At most every 10 minutes: message folders whose newest file is older than 48 h, then empty device folders.
    mutating func prune() {
        guard Date().timeIntervalSince(lastPrune) > 600 else { return }
        lastPrune = Date()
        let fm = FileManager.default, cutoff = Date().addingTimeInterval(-Self.staleAfter)
        for device in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            let messages = (try? fm.contentsOfDirectory(at: device, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for message in messages {
                let dates = ([message] + ((try? fm.contentsOfDirectory(at: message, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []))
                    .compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }
                if (dates.max() ?? .distantPast) < cutoff { try? fm.removeItem(at: message) }
            }
            if (try? fm.contentsOfDirectory(atPath: device.path))?.isEmpty == true { try? fm.removeItem(at: device) }
        }
    }

    /// Bytes staged and message folders, across devices.
    private func usage() -> (bytes: Int64, messages: Int) {
        let fm = FileManager.default
        var bytes: Int64 = 0, messages = 0
        for device in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            for message in (try? fm.contentsOfDirectory(at: device, includingPropertiesForKeys: nil)) ?? [] {
                messages += 1
                for file in (try? fm.contentsOfDirectory(at: message, includingPropertiesForKeys: [.fileSizeKey])) ?? [] {
                    bytes += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                }
            }
        }
        return (bytes, messages)
    }

    private func folder(_ device: String, _ message: String) -> URL {
        root.appendingPathComponent(device, isDirectory: true).appendingPathComponent(message, isDirectory: true)
    }

    /// A device key is base64url: safe as a folder name.
    private static func isDevice(_ s: String) -> Bool { s.range(of: #"^[A-Za-z0-9_-]{1,64}\z"#, options: .regularExpression) != nil }
}

/// Small JPEG previews of attachments for phones, cached as `<root>/<attachment id>.jpg` (the id names an immutable
/// file). Images go through ImageIO (EXIF orientation applied), anything else through QuickLookThumbnailing; transparency
/// is flattened onto white.
enum Thumbnails {
    static let maxPixels = 512

    static func jpeg(for source: URL, id: String, in root: URL) async -> URL? {
        let file = root.appendingPathComponent("\(id).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let image = await image(for: source), let data = encode(image) else { return nil }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: file, options: .atomic)
            return file
        } catch { return nil }
    }

    private static func image(for source: URL) async -> CGImage? {
        if UTType(filenameExtension: source.pathExtension)?.conforms(to: .image) == true || source.pathExtension.isEmpty,
           let src = CGImageSourceCreateWithURL(source as CFURL, nil),
           let image = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                                                    kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary) {
            return image
        }
        let request = QLThumbnailGenerator.Request(fileAt: source, size: CGSize(width: maxPixels, height: maxPixels), scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }

    private static func encode(_ image: CGImage) -> Data? {
        let w = image.width, h = image.height
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let flat = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, flat, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
