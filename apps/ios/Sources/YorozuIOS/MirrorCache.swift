import Foundation
import YorozuWire

/// The phone's copy of the Mac's history window (docs/ios-relay-contract.md#history-window), one
/// JSON file in `Application Support/Mirror/`. iOS file protection (`completeUntilFirstUserAuthentication`,
/// like the pairing's Keychain item) encrypts it at rest; the directory is excluded from backup.
/// A cache is only a cache: an unreadable or foreign file loads as nothing and catch-up refills it.
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
    }

    static let shared = MirrorCache()

    private let directory: URL
    private let file: URL
    /// Writes and wipes run in order, off the main actor.
    private let queue = DispatchQueue(label: "yorozu.mirror-cache")

    private init() {
        directory = URL.applicationSupportDirectory.appending(path: "Mirror", directoryHint: .isDirectory)
        file = directory.appending(path: "mirror.json")
    }

    func load(owner: String) -> Snapshot? {
        queue.sync {
            guard let data = try? Data(contentsOf: file),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
                  snapshot.version == Snapshot.currentVersion, snapshot.owner == owner else { return nil }
            return snapshot
        }
    }

    func save(_ snapshot: Snapshot) {
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
                try JSONEncoder().encode(snapshot)
                    .write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                // The next save tries again; a missing cache only costs a longer catch-up.
            }
        }
    }

    func wipe() {
        queue.async { [directory] in try? FileManager.default.removeItem(at: directory) }
    }
}
