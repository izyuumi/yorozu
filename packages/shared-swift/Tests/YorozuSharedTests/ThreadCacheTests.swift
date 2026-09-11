import CryptoKit
import Foundation
import Testing

@testable import YorozuShared

private func temporaryCache(key: SymmetricKey = SymmetricKey(size: .bits256)) -> ThreadCache {
    ThreadCache(
        directory: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yorozu-cache-\(UUID().uuidString)"),
        key: key
    )
}

private func message(_ id: String, _ text: String, thread: String = "home") -> YorozuEvent {
    YorozuEvent(
        id: id,
        threadId: thread,
        ts: 1,
        agentId: "main",
        payload: .message(MessageData(role: .agent, text: text))
    )
}

@Test func theCacheRoundTripsThreadsAndEvents() throws {
    let key = SymmetricKey(size: .bits256)
    let cache = temporaryCache(key: key)
    let threads = [
        ThreadSummary(id: "home", title: "Home", archived: false, pinned: true),
        ThreadSummary(id: "t2", title: "Groceries", archived: false, pinned: false),
    ]
    cache.save(threads: threads)
    cache.save(events: [message("e1", "hi"), message("e2", "there")], threadId: "home")
    cache.save(events: [message("e3", "milk", thread: "t2")], threadId: "t2")

    #expect(cache.threads() == threads)
    #expect(cache.events(threadId: "home").map(\.id) == ["e1", "e2"])
    #expect(cache.lastSeen() == ["home": "e2", "t2": "e3"])
    // A reader built fresh over the same files sees the same thing: nothing is held in memory.
    #expect(ThreadCache(directory: cache.directory, key: key).events(threadId: "t2").count == 1)
}

@Test func theCacheIsEncryptedAtRestAndUnreadableWithAnotherKey() throws {
    let cache = temporaryCache()
    cache.save(events: [message("e1", "the secret is 1234")], threadId: "home")

    let files = try FileManager.default.contentsOfDirectory(
        at: cache.directory,
        includingPropertiesForKeys: nil
    )
    let raw = try #require(files.first.map { try Data(contentsOf: $0) })
    #expect(!String(decoding: raw, as: UTF8.self).contains("1234"))

    // A wrong key — a reinstall that lost the Keychain item — reads as empty, never garbage.
    let other = ThreadCache(directory: cache.directory, key: SymmetricKey(size: .bits256))
    #expect(other.events(threadId: "home").isEmpty)
    #expect(other.threads().isEmpty)
}

@Test func missingFilesReadAsEmpty() {
    let cache = temporaryCache()
    #expect(cache.threads().isEmpty)
    #expect(cache.events(threadId: "never-written").isEmpty)
    #expect(cache.lastSeen().isEmpty)
}
