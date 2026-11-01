import Foundation
import OSLog

protocol StoredNamesFileOperations {
    func exists(_ url: URL) -> Bool
    func files(_ directory: URL) throws -> [URL]
    func size(_ url: URL) throws -> Int64
    func createDirectory(_ url: URL) throws
    func copy(_ source: URL, to destination: URL) throws
    func move(_ source: URL, to destination: URL) throws
    func remove(_ url: URL) throws
}

struct StoredNamesFileManager: StoredNamesFileOperations {
    func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    func files(_ directory: URL) throws -> [URL] {
        var failure: Error?
        guard let enumerator = FileManager.default.enumerator(at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey],
            errorHandler: { _, error in failure = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        var files: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            // Do not follow links or delete an old tree containing unhandled entries.
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            if values.isRegularFile == true { files.append(url) }
            else if values.isDirectory != true { throw CocoaError(.fileReadUnknown) }
        }
        if let failure { throw failure }
        return files.sorted { $0.path < $1.path }
    }
    func size(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { throw CocoaError(.fileReadUnknown) }
        return size.int64Value
    }
    func createDirectory(_ url: URL) throws {
        #if os(iOS)
        let attributes: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
        #else
        let attributes: [FileAttributeKey: Any] = [:]
        #endif
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: attributes)
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
    func copy(_ source: URL, to destination: URL) throws { try FileManager.default.copyItem(at: source, to: destination) }
    func move(_ source: URL, to destination: URL) throws { try FileManager.default.moveItem(at: source, to: destination) }
    func remove(_ url: URL) throws { try FileManager.default.removeItem(at: url) }
}

/// Shared by the background migration and foreground reads/deletes. Copies happen outside the lock;
/// committing and deleting share it so a wipe cannot resurrect a staged file.
final class StoredNames: @unchecked Sendable {
    enum Name: String, CaseIterable { case conversations = "Conversations", attachments = "Attachments" }
    static let shared = StoredNames(root: clientSupportDirectory, completion: .standard)
    let root: URL
    private let completion: UserDefaults
    private let lock = NSLock()
    private let migrationLock = NSLock()

    init(root: URL, completion: UserDefaults) {
        self.root = root.resolvingSymlinksInPath()
        self.completion = completion
    }

    func isComplete(_ name: Name) -> Bool { completion.bool(forKey: "yorozu.storedNames.\(name.rawValue)") }
    func directory(_ name: Name) -> URL { root.appending(path: name.rawValue, directoryHint: .isDirectory) }
    func legacyDirectory(_ name: Name) -> URL? {
        isComplete(name) ? nil : root.appending(path: "\(name.rawValue)-v3", directoryHint: .isDirectory)
    }

    /// Old-first listing + new-first reads also cover a file committed between the two listings.
    func fileNames(_ name: Name) -> Set<String> {
        let legacy = legacyDirectory(name)
        var names = Set<String>()
        for directory in [legacy, self.directory(name)].compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            names.formUnion(files.map(\.lastPathComponent))
        }
        return names
    }

    func read(_ relative: String, in name: Name) -> Data? {
        lock.withLock {
            if let data = try? Data(contentsOf: directory(name).appending(path: relative)) { return data }
            return legacyDirectory(name).flatMap { try? Data(contentsOf: $0.appending(path: relative)) }
        }
    }

    func local(_ relative: String, in name: Name) -> URL? {
        lock.withLock {
            for directory in [directory(name), legacyDirectory(name)].compactMap({ $0 }) {
                let url = directory.appending(path: relative)
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
            return nil
        }
    }

    func remove(_ relative: String? = nil, in name: Name) throws {
        try lock.withLock {
            // Old first: if deletion fails, retain the new copy too rather than resurrecting old data.
            for directory in [legacyDirectory(name), directory(name)].compactMap({ $0 }) {
                let url = relative.map { directory.appending(path: $0) } ?? directory
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            }
        }
    }

    @discardableResult
    func migrate(_ name: Name, files: any StoredNamesFileOperations = StoredNamesFileManager()) -> Bool {
        migrationLock.lock()
        defer { migrationLock.unlock() }
        guard !isComplete(name) else { return true }
        let logger = Logger(subsystem: "to.yumi.yorozu", category: "Migration")
        let old = root.appending(path: "\(name.rawValue)-v3", directoryHint: .isDirectory)
        let staging = root.appending(path: ".\(name.rawValue)-v3-staging", directoryHint: .isDirectory)
        var moved = 0, kept = 0, failed = 0
        var bytes: Int64 = 0
        do {
            // No old directory: no filesystem changes, including creation of the new directory.
            guard files.exists(old) else {
                completion.set(true, forKey: "yorozu.storedNames.\(name.rawValue)")
                logger.info("\(name.rawValue, privacy: .public): 0 files, 0 bytes; complete")
                return true
            }
            if files.exists(staging) { try files.remove(staging) }
            let pending = try files.files(old)
            for file in pending { bytes += try files.size(file) }
            logger.info("\(name.rawValue, privacy: .public): \(pending.count, privacy: .public) files, \(bytes, privacy: .public) bytes to move")
            for source in pending {
                do {
                    let sourcePath = source.resolvingSymlinksInPath().path
                    guard sourcePath.hasPrefix(old.path + "/") else { throw CocoaError(.fileReadUnknown) }
                    let relative = String(sourcePath.dropFirst(old.path.count + 1))
                    let destination = directory(name).appending(path: relative)
                    let staged = staging.appending(path: relative)
                    let alreadyNew = try lock.withLock {
                        guard files.exists(source) else { return true }
                        if files.exists(destination) {
                            _ = try files.size(destination)
                            try files.remove(source)
                            kept += 1
                            return true
                        }
                        return false
                    }
                    if alreadyNew { continue }
                    let size = try files.size(source)
                    try files.createDirectory(staged.deletingLastPathComponent())
                    try files.copy(source, to: staged)
                    guard try files.size(staged) == size else { throw CocoaError(.fileReadCorruptFile) }
                    try lock.withLock {
                        guard files.exists(source) else { try files.remove(staged); return }
                        try files.createDirectory(destination.deletingLastPathComponent())
                        if files.exists(destination) {
                            _ = try files.size(destination)
                            try files.remove(staged)
                            kept += 1
                        } else {
                            do { try files.move(staged, to: destination) }
                            catch {
                                // moveItem never overwrites: a concurrent writer may have won the name.
                                guard files.exists(destination) else { throw error }
                                _ = try files.size(destination)
                                if files.exists(staged) { try files.remove(staged) }
                                kept += 1
                                try files.remove(source)
                                return
                            }
                            guard files.exists(destination), try files.size(destination) == size else {
                                throw CocoaError(.fileReadCorruptFile)
                            }
                            moved += 1
                        }
                        try files.remove(source)
                    }
                } catch { failed += 1 }
            }
            try lock.withLock {
                guard failed == 0 else { return }
                if files.exists(old) {
                    guard try files.files(old).isEmpty else { throw CocoaError(.fileWriteUnknown) }
                    try files.remove(old)
                }
                if files.exists(staging) { try files.remove(staging) }
                completion.set(true, forKey: "yorozu.storedNames.\(name.rawValue)")
            }
        } catch { failed += 1 }
        let outcome = isComplete(name) ? "complete" : "retry"
        logger.info("\(name.rawValue, privacy: .public): moved \(moved, privacy: .public), kept-new \(kept, privacy: .public), failed \(failed, privacy: .public), \(bytes, privacy: .public) bytes; \(outcome, privacy: .public)")
        return isComplete(name)
    }
}
