import Foundation
import Testing

@testable import YorozuShared

@Test func addingAttachmentsKeepsFilesThatFitAroundAnOversizedBatchMember() throws {
    let mb = 1024 * 1024
    let existing = try (0..<4).map { index in
        try #require(MessageAttachment(name: "existing-\(index)", mime: "text/plain", bytes: Data(count: 4 * mb)))
    }
    let picked = try [3 * mb, 2 * mb, mb].enumerated().map { index, bytes in
        try #require(MessageAttachment(name: "picked-\(index)", mime: "text/plain", bytes: Data(count: bytes)))
    }
    let result = addingAttachments(picked, to: existing)
    #expect(result.attachments.map(\.name) == ["existing-0", "existing-1", "existing-2", "existing-3", "picked-0", "picked-2"])
    #expect(result.rejectedCount == 1)
    #expect(result.attachments.reduce(0) { $0 + $1.byteCount } == 20 * mb)
}

@Test func addingAttachmentsPreservesExistingFilesAtCountLimit() throws {
    let file = try #require(MessageAttachment(name: "notes", mime: "text/plain", bytes: Data("notes".utf8)))
    let existing = Array(repeating: file, count: 9)
    let result = addingAttachments([file, file], to: existing)
    #expect(result.attachments.count == 10)
    #expect(Array(result.attachments.prefix(9)) == existing)
    #expect(result.rejectedCount == 1)
}
