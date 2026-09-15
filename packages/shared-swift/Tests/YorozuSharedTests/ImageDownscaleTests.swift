import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import YorozuShared

/// A solid picture of a given size and type, which is all a resize has to be tested against.
private func picture(width: Int, height: Int, type: UTType = .png) throws -> Data {
    let context = try #require(
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    )
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let out = NSMutableData()
    let destination = try #require(
        CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil)
    )
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return out as Data
}

/// What a picture's pixels actually measure, read back from the encoded bytes.
private func size(of data: Data) throws -> (width: Int, height: Int) {
    let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
    let properties = try #require(
        CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    )
    return (
        try #require(properties[kCGImagePropertyPixelWidth] as? Int),
        try #require(properties[kCGImagePropertyPixelHeight] as? Int)
    )
}

@Test func aPhotoLongerThanTheCapIsReducedAndBecomesAJpeg() throws {
    let big = try picture(width: 4032, height: 3024)
    let smaller = try #require(downscaledForSending(big, mime: "image/png"))

    #expect(smaller.mime == "image/jpeg")
    #expect(smaller.ext == "jpg")
    // The long edge lands on the cap and the aspect ratio survives it.
    let measured = try size(of: smaller.data)
    #expect(measured.width == imageMaxPixels)
    #expect(measured.height == 1536)
}

@Test func aPictureAlreadySmallAndReadableIsLeftExactlyAsItIs() throws {
    let small = try picture(width: 800, height: 600)
    // Nil is "nothing to do", which is what keeps a lossless screenshot lossless.
    #expect(downscaledForSending(small, mime: "image/png") == nil)
    #expect(downscaledForSending(try picture(width: 800, height: 600), mime: "image/jpeg") == nil)
}

/// A pasted Mac screenshot arrives as uncompressed TIFF: small on its long edge and enormous in
/// bytes, so size alone would wave it through and the cap would then refuse it.
@Test func aTypeTheFarEndCannotReadIsReencodedWhateverItsSize() throws {
    let tiff = try picture(width: 600, height: 400, type: .tiff)
    let converted = try #require(downscaledForSending(tiff, mime: "image/tiff"))

    #expect(converted.mime == "image/jpeg")
    // Not resized — it was never too big — only re-encoded.
    let measured = try size(of: converted.data)
    #expect(measured.width == 600)
    #expect(measured.height == 400)
    #expect(converted.data.count < tiff.count)
}

@Test func stagingAPhotoRenamesItToWhatItActuallyIsNow() throws {
    let big = try picture(width: 4032, height: 3024)
    let staged = try #require(attachmentForSending(name: "IMG_0042.heic", mime: "image/heic", bytes: big))

    #expect(staged.mime == "image/jpeg")
    // The name follows the bytes, or the export and a text-only model are told the wrong thing.
    #expect(staged.name == "IMG_0042.jpg")
    #expect(staged.byteCount <= MessageAttachment.maxBytes)
}

@Test func stagingSomethingThatIsNotAPictureLeavesItAloneAndStillCapsIt() throws {
    let pdf = Data(repeating: 0x25, count: 1024)
    let staged = try #require(attachmentForSending(name: "q3.pdf", mime: "application/pdf", bytes: pdf))
    #expect(staged.name == "q3.pdf")
    #expect(staged.mime == "application/pdf")
    #expect(staged.byteCount == 1024)

    // Over the cap and not reducible, so there is nothing to send.
    let huge = Data(count: MessageAttachment.maxBytes + 1)
    #expect(attachmentForSending(name: "big.pdf", mime: "application/pdf", bytes: huge) == nil)
}
