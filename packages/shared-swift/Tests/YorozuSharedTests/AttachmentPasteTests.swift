import Foundation
import Testing

@testable import YorozuShared

@Test func pastedImageBecomesAValidatedAttachment() throws {
    let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z3S8AAAAASUVORK5CYII="
    ))
    let attachment = try #require(pastedImageAttachment(bytes: png))
    #expect(attachment.name == "pasted-image.png")
    #expect(attachment.mime == "image/png")
    #expect(attachment.bytes == png)
    #expect(pastedImageAttachment(bytes: Data("not an image".utf8)) == nil)
}

@Test func oversizedPastedImageUsesTheExistingLimitFailure() {
    var picked: MessageAttachment?
    var tooLarge = false
    stagePastedImage(
        PastedImage(bytes: Data(count: MessageAttachment.maxBytes + 1)),
        onPick: { picked = $0 },
        onTooLarge: { tooLarge = true }
    )
    #expect(picked == nil)
    #expect(tooLarge)
}

@Test func pastedImageStagesOnlyValidImages() throws {
    let png = try #require(Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Y9Z3S8AAAAASUVORK5CYII="
    ))
    var picked: MessageAttachment?
    var tooLarge = false

    stagePastedImage(
        PastedImage(bytes: png),
        onPick: { picked = $0 },
        onTooLarge: { tooLarge = true }
    )
    #expect(picked?.mime == "image/png")
    #expect(!tooLarge)

    picked = nil
    stagePastedImage(
        PastedImage(bytes: Data("not an image".utf8)),
        onPick: { picked = $0 },
        onTooLarge: { tooLarge = true }
    )
    #expect(picked == nil)
    #expect(!tooLarge)
}
