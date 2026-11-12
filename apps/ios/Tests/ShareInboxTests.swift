import Foundation
import Testing
import YorozuWire

/// The share inbox across an unpair: what the extension left pending belongs to the host it was shared for.
@Suite struct ShareInboxTests {
    let container: URL

    init() throws {
        container = FileManager.default.temporaryDirectory.appending(path: "yorozu-shareinbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
    }

    @Test func sharesPendingAtUnpairAreNeverHandedToALaterHost() throws {
        defer { try? FileManager.default.removeItem(at: container) }
        try ShareInbox.$testContainer.withValue(container) {
            let messageId = UUID().uuidString.lowercased()
            #expect(WireEvent.isId(messageId))
            let directory = try #require(ShareInbox.directory)
            #expect(directory.path.hasPrefix(container.path))
            let folder = directory.appending(path: messageId, directoryHint: .isDirectory)

            try ShareInbox.write(text: "for the first host", file: nil, convId: nil, messageId: messageId)
            #expect(ShareInbox.pending().map(\.folder.lastPathComponent) == [messageId])
            #expect(ShareInbox.pending().map { $0.folder.resolvingSymlinksInPath() } == [folder.resolvingSymlinksInPath()])
            #expect(FileManager.default.fileExists(atPath: folder.resolvingSymlinksInPath().path))

            ShareInbox.clear()

            #expect(ShareInbox.pending().isEmpty)
            #expect(!FileManager.default.fileExists(atPath: folder.resolvingSymlinksInPath().path))
        }
    }
}
