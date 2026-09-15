import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The long edge a staged photo is reduced to. A modern phone camera is four times this on its
/// long edge and well over the per-file cap as HEIC, so without this a photo taken today is
/// simply refused — which is the bug this exists to fix, not a quality setting anyone asked for.
/// Comfortably more than any vision model reads an image at.
public let imageMaxPixels = 2048

/// Where a re-encode stops being visible. The share extension has used 0.8 for the same reason.
public let imageJpegQuality: CGFloat = 0.85

/// Image types worth sending as they are, when they are small enough. Everything else is
/// re-encoded whatever its size: HEIC because a model on the other end may not read it, TIFF
/// because an uncompressed screenshot is megabytes of a picture that JPEGs to a fraction of it.
private let sendableImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

/// A photo reduced to something worth sending, or nil when the bytes are already fine as they
/// are — or are not an image this platform can read, which a file named `.png` that is not one
/// is a thing a phone can hand over.
///
/// Two things earn a re-encode: being longer than ``imageMaxPixels`` on the long edge, and being
/// a type the other end cannot be relied on to read — HEIC, which is what an iPhone camera
/// writes, and TIFF, which is what a screenshot pasted on a Mac arrives as and which is
/// enormous for its size. Anything already small and web-readable is left exactly as it
/// arrived: a PNG screenshot stays a lossless PNG rather than a JPEG of itself.
///
/// ImageIO rather than UIKit or AppKit, so the composer on both platforms shares one path and
/// this stays testable without a view: `CGImageSourceCreateThumbnailAtIndex` does the decode,
/// the resize and the EXIF rotation in one step, and never holds the full-size bitmap.
public func downscaledForSending(_ data: Data, mime: String) -> (data: Data, mime: String, ext: String)? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }

    let longEdge = max(width, height)
    guard !sendableImageTypes.contains(mime) || longEdge > imageMaxPixels else { return nil }

    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        // Applies the EXIF orientation, so a photo taken sideways is sent the way up it was
        // taken rather than rotated by a tag the other end may ignore.
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(longEdge, imageMaxPixels),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        return nil
    }

    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        out, UTType.jpeg.identifier as CFString, 1, nil
    ) else { return nil }
    CGImageDestinationAddImage(
        destination,
        image,
        [kCGImageDestinationLossyCompressionQuality: imageJpegQuality] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else { return nil }
    return (out as Data, "image/jpeg", "jpg")
}

/// Stages one picked file: a photo is reduced first and the cap is checked on what would
/// actually be sent, so a phone photo fits instead of being refused for a size it no longer has.
///
/// The single funnel both pickers and the paste handler go through, which is why the cap lives
/// here rather than in each of them.
public func attachmentForSending(name: String, mime: String, bytes: Data) -> MessageAttachment? {
    guard mime.hasPrefix("image/"), let smaller = downscaledForSending(bytes, mime: mime) else {
        return MessageAttachment(name: name, mime: mime, bytes: bytes)
    }
    // The name follows the bytes: a `.heic` that is now a JPEG would otherwise tell a text-only
    // model, and whoever reads the export, the wrong thing about what it is.
    let renamed = "\((name as NSString).deletingPathExtension).\(smaller.ext)"
    return MessageAttachment(name: renamed, mime: smaller.mime, bytes: smaller.data)
}
