import Foundation
import Testing

@testable import YorozuShared

/// A directory standing in for the App Group container, which is what lets this run in a test
/// bundle holding no entitlement at all. Everything in ``ShareBox`` takes its directory for
/// exactly this reason.
private func box(_ body: (URL) throws -> Void) throws {
    let directory = URL.temporaryDirectory.appending(path: "share-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

@Test func aShareSurvivesTheContainer() throws {
    try box { directory in
        let payload = SharePayload(
            threadId: "kitanoya",
            text: "Worth reading\n\nhttps://example.com/a?b=c#d",
            attachment: MessageAttachment(name: "Shared.jpg", mime: "image/jpeg", bytes: Data([0xFF, 0xD8, 0xFF]))
        )
        let token = try ShareBox.write(payload, in: directory)
        #expect(ShareBox.take(token: token, in: directory) == payload)
    }
}

@Test func aShareIsSentOnce() throws {
    try box { directory in
        let token = try ShareBox.write(SharePayload(text: "once"), in: directory)
        #expect(ShareBox.take(token: token, in: directory) != nil)
        // The second open of the same URL — an extension's `open` and the foreground drain
        // racing each other — must not say it twice.
        #expect(ShareBox.take(token: token, in: directory) == nil)
    }
}

@Test func aNewChatShareCarriesNoThread() throws {
    try box { directory in
        let token = try ShareBox.write(SharePayload(text: "new"), in: directory)
        #expect(ShareBox.take(token: token, in: directory)?.threadId == nil)
    }
}

/// The token arrives from a URL any app on the phone can open, so it is a file name only if it
/// looks like the one that was written.
@Test func aTokenThatIsNotOneIsRefused() throws {
    try box { directory in
        let secret = directory.deletingLastPathComponent().appending(path: "elsewhere.json")
        try Data("{}".utf8).write(to: secret)
        defer { try? FileManager.default.removeItem(at: secret) }

        for token in ["../elsewhere", "", "elsewhere", "/etc/passwd"] {
            #expect(ShareBox.take(token: token, in: directory) == nil)
        }
        // And it is still there: a refused token reads nothing and deletes nothing.
        #expect(FileManager.default.fileExists(atPath: secret.path))
    }
}

@Test func everythingWaitingDrainsOldestFirst() throws {
    try box { directory in
        for text in ["first", "second", "third"] {
            try ShareBox.write(SharePayload(text: text), in: directory)
            // Creation dates are what the order is read from, and a file system that keeps them
            // to the second would otherwise make this a coin toss.
            Thread.sleep(forTimeInterval: 0.02)
        }
        #expect(ShareBox.takeAll(in: directory).map(\.text) == ["first", "second", "third"])
        #expect(ShareBox.takeAll(in: directory).isEmpty)
    }
}

/// The picker's thread list lives in the same directory and is not a share: draining must step
/// over it, or the titles vanish the first time anything is shared.
@Test func theThreadListIsNotDrainedAsAShare() throws {
    try box { directory in
        ShareBox.save(
            threads: [ThreadSummary(id: "a", title: "Kitanoya", archived: false, lastActivity: 0)],
            in: directory
        )
        try ShareBox.write(SharePayload(text: "hi"), in: directory)

        #expect(ShareBox.takeAll(in: directory).count == 1)
        #expect(ShareBox.threads(in: directory) == [ShareThread(id: "a", title: "Kitanoya")])
    }
}

/// An untitled thread is "New chat" in the picker for the same reason it is everywhere else.
@Test func anUntitledThreadIsNamedInThePicker() throws {
    try box { directory in
        ShareBox.save(
            threads: [ThreadSummary(id: "a", title: "", archived: false, lastActivity: 0)],
            in: directory
        )
        #expect(ShareBox.threads(in: directory).first?.title == "New chat")
    }
}

@Test func anEmptyContainerHasNothingInIt() throws {
    try box { directory in
        #expect(ShareBox.takeAll(in: directory).isEmpty)
        #expect(ShareBox.threads(in: directory).isEmpty)
        #expect(ShareBox.take(token: UUID().uuidString, in: directory) == nil)
    }
}

@Test func unpairingEmptiesTheContainer() throws {
    try box { directory in
        try ShareBox.write(SharePayload(text: "hi"), in: directory)
        ShareBox.save(threads: [], in: directory)
        ShareBox.clear(in: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

