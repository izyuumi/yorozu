import Foundation
import Testing

@testable import YorozuShared

@Test func onlyABareWebUrlIsWorthPreviewing() {
    #expect(firstLink(in: "have a look at https://example.com/a it is good")?.absoluteString
        == "https://example.com/a")
    // The first one, when there are several: one row under a bubble, not a wall of them.
    #expect(firstLink(in: "https://one.example https://two.example")?.host == "one.example")
    // A Markdown link is already drawn as a link, and code is being quoted rather than linked to.
    #expect(firstLink(in: "see [the docs](https://example.com/docs)") == nil)
    #expect(firstLink(in: "run `curl https://example.com`") == nil)
    #expect(firstLink(in: "```\nhttps://example.com\n```") == nil)
    #expect(firstLink(in: "<https://example.com>") == nil)
    // But a bare URL after a Markdown one still counts.
    #expect(firstLink(in: "[docs](https://a.example) and https://b.example")?.host == "b.example")
    // Nothing to preview.
    #expect(firstLink(in: "no links here") == nil)
    #expect(firstLink(in: "mail me at hi@example.com") == nil)
}

@MainActor
@Test func aPreviewIsFetchedOnceAndReadBackFromDiskNextLaunch() async {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = URL(string: "https://example.com/post")!

    let fetches = Counter()
    let store = LinkPreviewStore(directory: directory) { _ in
        fetches.bump()
        return LinkPreview(title: "A post", host: "example.com", icon: Data([1, 2, 3]))
    }

    // Nothing is known until it has been asked for, and a body never blocks on the asking.
    #expect(store.cached(url) == nil)
    await store.load(url)
    #expect(store.cached(url)?.title == "A post")
    #expect(store.cached(url)?.icon == Data([1, 2, 3]))
    // Asking again is free: memory answers it.
    await store.load(url)
    #expect(fetches.count == 1)

    // A second launch over the same directory reads the file rather than the network.
    let relaunched = LinkPreviewStore(directory: directory) { _ in
        Issue.record("went to the network for a link already on disk")
        return nil
    }
    await relaunched.load(url)
    #expect(relaunched.cached(url)?.host == "example.com")
    // The file is named by the hash of the URL, not by the URL: the caches directory is not
    // sealed, and a listing of the links somebody was sent is a transcript of its own.
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
    #expect(files.count == 1)
    #expect(files.allSatisfy { !$0.contains("example") })
}

@MainActor
@Test func aLinkThatCannotBeReadLeavesNoRowAndIsNotAskedTwice() async {
    let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = URL(string: "https://gone.example")!

    let fetches = Counter()
    let store = LinkPreviewStore(directory: directory) { _ in
        fetches.bump()
        return nil
    }

    await store.load(url)
    await store.load(url)
    // No row is drawn, and a dead link is not re-fetched on every scroll.
    #expect(store.cached(url) == nil)
    #expect(fetches.count == 1)
    #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.path())) == nil)
}

/// A counter the fetch closure can reach from wherever it is called.
private final class Counter: @unchecked Sendable {
    private(set) var count = 0
    func bump() { count += 1 }
}
