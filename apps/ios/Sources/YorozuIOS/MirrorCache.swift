import Foundation
import YorozuWire

/// The phone's copy of the Mac's history window (docs/ios-relay-contract.md#history-window), one
/// JSON file in `Application Support/Mirror/`. A cache is only a cache: an unreadable or foreign
/// file loads as nothing and catch-up refills it.
final class MirrorCache: Sendable {
    struct Snapshot: Codable, Sendable {
        static let currentVersion = 1
        var version = currentVersion
        /// The phone's own session key (base64url): a file left by another pairing is never read.
        var owner: String
        /// `latestSeq` of the last reply page applied whole.
        var cursor: Int?
        var readCursor: ReadStateData?
        var messages: [PhoneModel.Bubble]
        var topics: [TopicData]
        var tasks: [TaskData]
        var amendments: [AmendmentData]
        var workerEvents: [WorkerEventData]
        /// Filled with `jobs-v1`, so it holds job-only messages (#319). Optional so an older cache still loads.
        var jobs: Bool?
    }

    static let shared = MirrorCache()

    private let file = ProtectedFile(folder: "Mirror", name: "mirror.json")

    func load(owner: String) -> Snapshot? {
        file.load(Snapshot.self).flatMap { $0.version == Snapshot.currentVersion && $0.owner == owner ? $0 : nil }
    }

    func save(_ snapshot: Snapshot) { file.save(snapshot) }
    func wipe() { file.wipe() }
}

/// One JSON file in its own `Application Support` folder. iOS file protection
/// (`completeUntilFirstUserAuthentication`, like the pairing's Keychain item) encrypts it at rest
/// and keeps it readable in the background after the first unlock; the folder is excluded from backup.
final class ProtectedFile: Sendable {
    private let directory: URL
    private let file: URL
    /// Writes and wipes run in order, off the main actor.
    private let queue: DispatchQueue

    init(folder: String, name: String) {
        directory = URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory)
        file = directory.appending(path: name)
        queue = DispatchQueue(label: "yorozu.file.\(folder)")
    }

    func load<Value: Decodable>(_ type: Value.Type) -> Value? {
        queue.sync {
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
    }

    func save<Value: Encodable & Sendable>(_ value: Value) {
        queue.async { [directory, file] in
            do {
                if !FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true,
                        attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
                    var url = directory
                    var values = URLResourceValues()
                    values.isExcludedFromBackup = true
                    try url.setResourceValues(values)
                }
                try JSONEncoder().encode(value)
                    .write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                // The next save tries again.
            }
        }
    }

    func wipe() {
        queue.async { [directory] in try? FileManager.default.removeItem(at: directory) }
    }
}
