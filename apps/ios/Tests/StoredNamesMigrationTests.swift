import Foundation
import Testing

/// A throwaway defaults suite whose writes stay in its volatile domain, never in ~/Library.
private final class VolatileDefaults: UserDefaults {
    let suite = "stored-names-tests-\(UUID().uuidString)"
    init() { super.init(suiteName: suite)! }
    override func bool(forKey key: String) -> Bool { volatileDomain(forName: suite)[key] as? Bool ?? false }
    override func set(_ value: Any?, forKey key: String) {
        var domain = volatileDomain(forName: suite)
        domain[key] = value
        setVolatileDomain(domain, forName: suite)
    }
    deinit { removeVolatileDomain(forName: suite) }
}

private final class MigrationFixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "stored-names-\(UUID().uuidString)").resolvingSymlinksInPath()
    let defaults = VolatileDefaults()
    var store: StoredNames { StoredNames(root: root, completion: defaults) }
    deinit { try? FileManager.default.removeItem(at: root) }
    func url(_ path: String) -> URL { root.appending(path: path) }
    func write(_ path: String, _ contents: String) throws {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }
    func contents(_ path: String) -> String? { try? String(contentsOf: url(path), encoding: .utf8) }
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: url(path).path) }
}

private final class FaultFiles: StoredNamesFileOperations {
    enum Operation: CaseIterable { case copy, move, remove, size, create }
    let base = StoredNamesFileManager()
    var before: (Operation, URL, URL?) throws -> Void = { _, _, _ in }
    var copyOverride: ((URL, URL) throws -> Void)?
    func exists(_ url: URL) -> Bool { base.exists(url) }
    func files(_ directory: URL) throws -> [URL] { try base.files(directory) }
    func size(_ url: URL) throws -> Int64 { try before(.size, url, nil); return try base.size(url) }
    func createDirectory(_ url: URL) throws { try before(.create, url, nil); try base.createDirectory(url) }
    func copy(_ source: URL, to destination: URL) throws {
        try before(.copy, source, destination)
        if let copyOverride { try copyOverride(source, destination) }
        else { try base.copy(source, to: destination) }
    }
    func move(_ source: URL, to destination: URL) throws { try before(.move, source, destination); try base.move(source, to: destination) }
    func remove(_ url: URL) throws { try before(.remove, url, nil); try base.remove(url) }
}

struct StoredNamesMigrationTests {
    @Test(arguments: StoredNames.Name.allCases) func oldOnlyDirectoriesMigrate(name: StoredNames.Name) throws {
        let fixture = MigrationFixture(), store = fixture.store
        try fixture.write("\(name.rawValue)-v3/nested/file", "complete contents")
        #expect(store.migrate(name))
        #expect(!fixture.exists("\(name.rawValue)-v3"))
        #expect(!fixture.exists(".\(name.rawValue)-v3-staging"))
        #expect(fixture.contents("\(name.rawValue)/nested/file") == "complete contents")
        #expect(store.read("nested/file", in: name) == Data("complete contents".utf8))
        // A fresh resolver sees the recorded completion too.
        #expect(fixture.store.isComplete(name))
        #expect(fixture.store.legacyDirectory(name) == nil)
    }

    @Test(arguments: FaultFiles.Operation.allCases) fileprivate func partialFailureLosesNothingAndRetries(operation: FaultFiles.Operation) throws {
        let fixture = MigrationFixture(), store = fixture.store, files = FaultFiles()
        for index in 0..<3 { try fixture.write("Conversations-v3/\(index).json", "full \(index)") }
        var calls = 0
        files.before = { op, _, _ in
            guard op == operation else { return }
            calls += 1
            if calls == 2 { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(!store.migrate(.conversations, files: files))
        #expect(!store.isComplete(.conversations))
        for index in 0..<3 {
            let old = fixture.contents("Conversations-v3/\(index).json")
            let new = fixture.contents("Conversations/\(index).json")
            #expect(old == "full \(index)" || new == "full \(index)")
            #expect(new == nil || new == "full \(index)")
        }
        #expect(store.migrate(.conversations))
        #expect(!fixture.exists("Conversations-v3"))
        for index in 0..<3 { #expect(fixture.contents("Conversations/\(index).json") == "full \(index)") }
    }

    @Test func crashAfterCommitBeforeDeleteRetriesSafely() throws {
        let fixture = MigrationFixture(), store = fixture.store, files = FaultFiles()
        try fixture.write("Attachments-v3/id/file", "whole file")
        files.before = { op, url, _ in
            if op == .remove && url.path.hasSuffix("/Attachments-v3/id/file") { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(!store.migrate(.attachments, files: files))
        #expect(fixture.contents("Attachments/id/file") == "whole file")
        #expect(fixture.contents("Attachments-v3/id/file") == "whole file")
        #expect(store.migrate(.attachments))
        #expect(!fixture.exists("Attachments-v3"))
        #expect(fixture.contents("Attachments/id/file") == "whole file")
    }

    @Test(arguments: [true, false]) func crashMidCopyClearsTruncatedStaging(copyThrows: Bool) throws {
        let fixture = MigrationFixture(), store = fixture.store, files = FaultFiles()
        try fixture.write("Attachments-v3/id/file", "whole file")
        files.copyOverride = { _, destination in
            try Data("truncated".utf8).write(to: destination)
            if copyThrows { throw CocoaError(.fileWriteUnknown) }
        }
        #expect(!store.migrate(.attachments, files: files))
        #expect(fixture.exists(".Attachments-v3-staging/id/file"))
        #expect(!fixture.exists("Attachments/id/file"))
        #expect(fixture.contents("Attachments-v3/id/file") == "whole file")
        #expect(store.migrate(.attachments))
        #expect(!fixture.exists(".Attachments-v3-staging"))
        #expect(fixture.contents("Attachments/id/file") == "whole file")
    }

    @Test func mergeKeepsNewAndResolverReadsOldUntilComplete() throws {
        let fixture = MigrationFixture(), store = fixture.store
        try fixture.write("Conversations-v3/conflict.json", "old")
        try fixture.write("Conversations-v3/old-only.json", "legacy")
        try fixture.write("Conversations/conflict.json", "new contents have different size")
        try fixture.write("Conversations/new-only.json", "current")
        #expect(store.legacyDirectory(.conversations)?.path == fixture.url("Conversations-v3").path)
        #expect(store.fileNames(.conversations) == ["conflict.json", "old-only.json", "new-only.json"])
        #expect(store.read("old-only.json", in: .conversations) == Data("legacy".utf8))
        #expect(store.read("conflict.json", in: .conversations) == Data("new contents have different size".utf8))
        #expect(store.local("old-only.json", in: .conversations) == fixture.url("Conversations-v3/old-only.json"))
        #expect(store.migrate(.conversations))
        #expect(fixture.contents("Conversations/conflict.json") == "new contents have different size")
        #expect(fixture.contents("Conversations/old-only.json") == "legacy")
        #expect(!fixture.exists("Conversations-v3"))
        #expect(store.legacyDirectory(.conversations) == nil)
        let files = FaultFiles()
        files.before = { _, _, _ in Issue.record("Completed migration touched files") }
        #expect(store.migrate(.conversations, files: files))
        #expect(fixture.contents("Conversations/conflict.json") == "new contents have different size")
    }

    @Test func noOldDataCreatesNothingAndRecordsCompletion() {
        let fixture = MigrationFixture(), store = fixture.store
        for name in StoredNames.Name.allCases {
            #expect(store.migrate(name))
            #expect(store.isComplete(name))
            #expect(store.legacyDirectory(name) == nil)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.path))
    }

    @Test func deletesAndWipesDuringCopyCannotResurrectFiles() throws {
        for wipe in [false, true] {
            let fixture = MigrationFixture(), store = fixture.store, files = FaultFiles()
            try fixture.write("Attachments-v3/id/file", "whole file")
            files.before = { op, _, _ in
                if op == .copy { try store.remove(wipe ? nil : "id", in: .attachments) }
            }
            #expect(!store.migrate(.attachments, files: files))
            #expect(!fixture.exists("Attachments/id/file"))
            #expect(!fixture.exists("Attachments-v3/id/file"))
            #expect(store.migrate(.attachments))
            #expect(store.local("id/file", in: .attachments) == nil)
        }
    }
    @Test func deletionAfterCopyDiscardsStagingBeforeCommit() throws {
        let fixture = MigrationFixture(), store = fixture.store, files = FaultFiles()
        try fixture.write("Attachments-v3/id/file", "whole file")
        files.before = { op, url, _ in
            if op == .size && url == fixture.url(".Attachments-v3-staging/id/file") {
                try store.remove("id", in: .attachments)
            }
        }
        #expect(store.migrate(.attachments, files: files))
        #expect(!fixture.exists("Attachments/id/file"))
        #expect(!fixture.exists(".Attachments-v3-staging"))
    }

    @Test func concurrentNewFileWinsAtAtomicMove() throws {
        let fixture = MigrationFixture(), store = fixture.store, files = FaultFiles()
        try fixture.write("Attachments-v3/id/file", "old")
        files.before = { op, _, destination in
            if op == .move, let destination { try Data("new longer contents".utf8).write(to: destination) }
        }
        #expect(store.migrate(.attachments, files: files))
        #expect(fixture.contents("Attachments/id/file") == "new longer contents")
        #expect(!fixture.exists("Attachments-v3"))
    }

    @Test func conversationCacheReadsMergesWritesAndDeletesDuringMigration() throws {
        let fixture = MigrationFixture(), store = fixture.store
        let id = "00000000-0000-4000-8000-000000000001"
        let legacy = Conversation(id: id, createdAt: 1, updatedAt: 1, title: "legacy")
        try fixture.write("Conversations-v3/\(id).json", String(decoding: JSONEncoder().encode(legacy), as: UTF8.self))
        let cache = ConversationCache(storedNames: store)
        #expect(cache.loadAll() == [legacy])
        var current = legacy
        current.title = "current"
        cache.save(current)
        #expect(cache.loadAll() == [current]) // loadAll drains the serial write queue.
        #expect(fixture.contents("Conversations-v3/\(id).json")?.contains("legacy") == true)
        cache.remove(id)
        #expect(cache.loadAll().isEmpty)
        #expect(store.migrate(.conversations))
        #expect(cache.loadAll().isEmpty)
    }

}
