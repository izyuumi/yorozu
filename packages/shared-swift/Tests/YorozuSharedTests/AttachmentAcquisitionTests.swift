import Foundation
import Testing

@testable import YorozuShared

@Test func attachmentReadFailuresAreReportedWithoutDiscardingReadableFiles() {
    var staged: [MessageAttachment] = []
    var failures: [String] = []
    var limited = false
    stageAttachments([
        (name: "notes.txt", mime: "text/plain", bytes: Data("notes".utf8)),
        (name: "broken.png", mime: "image/png", bytes: Data("broken".utf8)),
    ], remaining: 10, onPick: { staged = $0 }, onTooLarge: { limited = true }, onFailure: { failures.append($0) })
    #expect(staged.map(\.name) == ["notes.txt"])
    #expect(failures.count == 1)
    #expect(!limited)
}

@MainActor @Test func attachmentAcquisitionRetriesOnlyFailedSources() async throws {
    enum ReadFailure: Error { case unavailable }
    var goodReads = 0
    var nilReads = 0
    var thrownReads = 0
    let sources = [
        AttachmentSource(name: "ready.txt", mime: "text/plain", load: {
            goodReads += 1
            return Data("ready".utf8)
        }),
        AttachmentSource(name: "cloud.txt", mime: "text/plain", load: {
            nilReads += 1
            return nilReads == 1 ? nil : Data("cloud".utf8)
        }),
        AttachmentSource(name: "locked.txt", mime: "text/plain", load: {
            thrownReads += 1
            if thrownReads == 1 { throw ReadFailure.unavailable }
            return Data("unlocked".utf8)
        }),
    ]
    let first = try await AttachmentAcquisition.load(sources)
    #expect(first.picks.map(\.name) == ["ready.txt"])
    #expect(first.picks.first?.bytes == Data("ready".utf8))
    #expect(first.failed.map(\.name) == ["cloud.txt", "locked.txt"])
    let retry = try await AttachmentAcquisition.load(first.failed)
    #expect(retry.picks.map(\.name) == ["cloud.txt", "locked.txt"])
    #expect(retry.failed.isEmpty)
    #expect(goodReads == 1)
    #expect(nilReads == 2)
    #expect(thrownReads == 2)
}

@MainActor @Test func attachmentAcquisitionCancellationIsNotAReadFailure() async {
    var laterWasRead = false
    let sources = [
        AttachmentSource(name: "cancelled.txt", mime: "text/plain", load: { throw CancellationError() }),
        AttachmentSource(name: "later.txt", mime: "text/plain", load: {
            laterWasRead = true
            return Data("later".utf8)
        }),
    ]
    do {
        _ = try await AttachmentAcquisition.load(sources)
        Issue.record("Cancellation must propagate without becoming a retry alert")
    } catch is CancellationError {
        #expect(!laterWasRead)
    } catch {
        Issue.record("Unexpected failure: \(error)")
    }
}

@Test func attachmentFailuresUseOneReportAndKeepCountLimit() {
    var staged: [MessageAttachment] = []
    var reports: [String] = []
    var legacyAlerts = 0
    stageAttachments([
        (name: "ready.txt", mime: "text/plain", bytes: Data("ready".utf8)),
        (name: "broken.png", mime: "image/png", bytes: Data("broken".utf8)),
        (name: "extra.txt", mime: "text/plain", bytes: Data("extra".utf8)),
        (name: "over-limit.txt", mime: "text/plain", bytes: Data("overflow".utf8)),
    ], remaining: 2, onPick: { staged = $0 }, onTooLarge: { legacyAlerts += 1 }, onFailure: { reports.append($0) })
    #expect(staged.map(\.name) == ["ready.txt", "extra.txt"])
    #expect(reports.count == 1)
    #expect(legacyAlerts == 0)
}

@Test func attachmentEmptyConversionAndCorruptPasteReportFailure() {
    var reports: [String] = []
    var pickCalls = 0
    stageAttachments([], remaining: 10, onPick: { _ in pickCalls += 1 }, onTooLarge: {}, onFailure: { reports.append($0) })
    #expect(reports.count == 1)
    stagePastedImage(PastedImage(bytes: Data("broken".utf8)), onPick: { _ in pickCalls += 1 }, onTooLarge: {}, onFailure: { reports.append($0) })
    #expect(reports.count == 2)
    #expect(pickCalls == 0)
}

@MainActor @Test func cancelledAttachmentReadNeverReturnsBytesToAnotherDraft() async {
    var resumeRead: CheckedContinuation<Data?, Never>?
    let task = Task { @MainActor in
        try await AttachmentAcquisition.load([
            AttachmentSource(name: "slow.txt", mime: "text/plain", load: {
                await withCheckedContinuation { resumeRead = $0 }
            }),
        ])
    }
    // A cloud file read can finish after SwiftUI cancels the old thread's task.
    while resumeRead == nil { await Task.yield() }
    task.cancel()
    resumeRead?.resume(returning: Data("old thread file".utf8))
    do {
        _ = try await task.value
        Issue.record("A cancelled read must not return bytes for staging into a replacement draft")
    } catch is CancellationError {
        // The production acquisition boundary rejects the late result.
    } catch {
        Issue.record("Unexpected failure: \(error)")
    }
}
