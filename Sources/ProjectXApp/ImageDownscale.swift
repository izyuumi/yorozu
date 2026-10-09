import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Images are sent at most this long on their long edge unless the user picks "Send original" (#316). Ported from v1's
/// `ImageDownscale.swift` on `main`: comfortably more than any vision model reads an image at.
let imageMaxPixels = 2048
/// Where a re-encode stops being visible.
let imageJpegQuality: CGFloat = 0.85
/// Image types worth sending as they are when small enough. Anything else is re-encoded whatever its size: HEIC because the
/// model may not read it, TIFF because a pasted screenshot is megabytes that JPEG to a fraction.
private let sendableImageTypes: Set<String> = ["image/png", "image/jpeg", "image/gif", "image/webp"]

/// The image at `url` reduced for sending, or nil when it is already fine as it is (small and web-readable, so a PNG
/// screenshot stays a lossless PNG) or is not an image ImageIO can read. `CGImageSourceCreateThumbnailAtIndex` decodes,
/// resizes and applies the EXIF orientation in one step without holding the full-size bitmap.
func downscaledForSending(_ url: URL, mime: String) -> (data: Data, mime: String, ext: String)? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let width = properties[kCGImagePropertyPixelWidth] as? Int,
          let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let longEdge = max(width, height)
    guard !sendableImageTypes.contains(mime) || longEdge > imageMaxPixels else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        // Applies the EXIF orientation, so a photo taken sideways goes the way up it was taken.
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(longEdge, imageMaxPixels),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let out = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: imageJpegQuality] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return (out as Data, "image/jpeg", "jpg")
}
