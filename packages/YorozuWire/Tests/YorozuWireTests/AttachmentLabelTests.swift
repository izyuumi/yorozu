import Foundation
import Testing
@testable import YorozuWire

/// The name and type an attachment travels under, and how many chunks it takes.
struct AttachmentLabelTests {
    @Test func emptyNameBecomesFile() {
        #expect(Attachment.wireName("") == "file")
        #expect(Attachment.wireName(" \n\t ") == "file")
        #expect(Attachment.wireName("  notes.txt\n") == "notes.txt")
    }

    @Test func nameAtTheLimitIsKept() {
        let name = String(repeating: "a", count: Attachment.maxLabel - 4) + ".txt"
        #expect(Attachment.wireName(name) == name)
    }

    @Test func longNameKeepsItsExtension() {
        let name = String(repeating: "a", count: 296) + ".txt"
        #expect(name.count == 300)
        let wire = Attachment.wireName(name)
        #expect(wire.count == Attachment.maxLabel)
        #expect(wire == String(repeating: "a", count: Attachment.maxLabel - 4) + ".txt")
        // Only the last extension counts; the rest is stem and gets cut.
        let archive = Attachment.wireName(String(repeating: "b", count: 300) + ".tar.gz")
        #expect(archive == String(repeating: "b", count: Attachment.maxLabel - 3) + ".gz")
    }

    @Test func overLongExtensionIsCutWithTheName() {
        // The extension is kept only when shorter than half the limit.
        let half = Attachment.maxLabel / 2
        let kept = String(repeating: "a", count: 300) + "." + String(repeating: "x", count: half - 1)
        #expect(Attachment.wireName(kept)
            == String(repeating: "a", count: Attachment.maxLabel - half) + "." + String(repeating: "x", count: half - 1))
        let cut = String(repeating: "a", count: 200) + "." + String(repeating: "x", count: half)
        #expect(Attachment.wireName(cut) == String(cut.prefix(Attachment.maxLabel)))
        let allExtension = "a." + String(repeating: "x", count: 300)
        #expect(Attachment.wireName(allExtension) == String(allExtension.prefix(Attachment.maxLabel)))
        // No extension at all: a plain cut.
        #expect(Attachment.wireName(String(repeating: "a", count: 300)) == String(repeating: "a", count: Attachment.maxLabel))
    }

    @Test func mimeFallsBackToOctetStream() {
        #expect(Attachment.wireMime("") == "application/octet-stream")
        #expect(Attachment.wireMime("  \n") == "application/octet-stream")
        #expect(Attachment.wireMime(" image/png\n") == "image/png")
        let longest = "x/" + String(repeating: "a", count: Attachment.maxLabel - 2)
        #expect(Attachment.wireMime(longest) == longest)
        #expect(Attachment.wireMime(longest + "a") == "application/octet-stream")
    }

    @Test func chunkCountIsAtLeastOne() {
        let chunk = Attachment.chunkBytes
        #expect(Attachment.chunkCount(0) == 1)
        #expect(Attachment.chunkCount(1) == 1)
        #expect(Attachment.chunkCount(chunk) == 1)
        #expect(Attachment.chunkCount(chunk + 1) == 2)
        #expect(Attachment.chunkCount(3 * chunk) == 3)
    }
}
