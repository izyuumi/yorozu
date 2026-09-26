import CryptoKit
import Foundation

/// The phone's offline copy of what it has already seen: the thread list and one file per
/// thread, AES-GCM sealed under a key its owner keeps in the Keychain. The files themselves
/// live in Application Support, which is readable by anything that reaches the container, so
/// the encryption — not the location — is what protects them.
///
/// A cache is only ever a cache: an unreadable, tampered or stale file reads back as empty
/// rather than throwing, and the next `sync_delta` fills the gap.
public struct ThreadCache: Sendable {
    public let directory: URL
    private let key: SymmetricKey

    private struct Snapshot: Codable {
        var events: [YorozuEvent]
        var lastSeen: String?
        var historyCursor: String?
        var historyLoaded: Bool?
    }

    public init(directory: URL, key: SymmetricKey) {
        self.directory = directory
        self.key = key
    }

    /// Copies a legacy cache without decrypting or rewriting it. The caller first preserves
    /// its existing key and only removes the source after committing the new pairing record.
    /// A crash before that commit can retry safely; a conflicting destination is never lost.
    public static func migrateLegacyDirectory(from source: URL, to destination: URL) throws {
        let files = FileManager.default
        guard source.standardizedFileURL != destination.standardizedFileURL,
            files.fileExists(atPath: source.path) else { return }
        if files.fileExists(atPath: destination.path) {
            let names = try files.contentsOfDirectory(atPath: source.path)
            guard names.allSatisfy({ name in
                let original = source.appendingPathComponent(name)
                let migrated = destination.appendingPathComponent(name)
                return files.contentsEqual(atPath: original.path, andPath: migrated.path)
            }) else { throw CocoaError(.fileWriteFileExists) }
            return
        }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".migrating-\(UUID().uuidString)")
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: source, to: staging)
        try files.moveItem(at: staging, to: destination)
    }

    public func threads() -> [ThreadSummary] {
        read([ThreadSummary].self, from: "threads") ?? []
    }

    public func save(threads: [ThreadSummary]) {
        write(threads, to: "threads")
    }

    /// Last authenticated identity details, for an offline host label. Negotiated permission
    /// is deliberately not cached: every live channel negotiates compatibility again.
    public func peerInfo() -> PeerInfoData? { read(PeerInfoData.self, from: "peer-info") }
    public func save(peerInfo: PeerInfoData) { write(peerInfo, to: "peer-info") }

    // Unread was once kept here, as the set of threads a reply had arrived in while this device
    // had them closed. It is the runtime's now — see `thread_read` — so that reading on one
    // device clears the dot on the other. An `unread.bin` left by an older build is simply
    // never read again.

    /// Messages typed while there was nowhere to send them, oldest first. Sealed like the rest:
    /// a message waiting to go out is as much of a secret as one that went.
    public func outbox() -> [OutboxItem] {
        read([OutboxItem].self, from: "outbox") ?? []
    }

    public func save(outbox: [OutboxItem]) {
        write(outbox, to: "outbox")
    }

    public struct ComposerState: Codable, Sendable {
        var drafts: [String: String]
        var attachments: [String: [MessageAttachment]]
        var threads: [ThreadSummary]
        var knownThreads: [ThreadSummary]?
        var openThread: String?
        var readingPositions: [String: ReadingPosition]? = nil
        /// Prepared composer send. Outbox presence decides whether this draft was committed.
        var preparedSend: [String: String]? = nil
    }

    /// Stable transcript row and its distance from the viewport's top edge.
    public struct ReadingPosition: Codable, Sendable, Equatable {
        public let rowID: String
        public let distanceFromTop: Double

        public init(rowID: String, distanceFromTop: Double) {
            self.rowID = rowID
            self.distanceFromTop = distanceFromTop
        }
    }

    public func composer() -> ComposerState? {
        read(ComposerState.self, from: "composer")
    }

    public func save(composer: ComposerState) throws {
        try writeRequired(composer, to: "composer")
    }

    public func savePending(_ outbox: [OutboxItem]) throws {
        try writeRequired(outbox, to: "outbox")
    }

    public func events(threadId: String) -> [YorozuEvent] {
        read(Snapshot.self, from: name(threadId))?.events
            ?? read([YorozuEvent].self, from: name(threadId)) ?? []
    }

    public func save(
        events: [YorozuEvent], threadId: String, lastSeen: String? = nil,
        historyCursor: String? = nil, historyLoaded: Bool = false
    ) {
        // Keep the replay cursor and the events it covers in one atomic encrypted write.
        write(Snapshot(events: events, lastSeen: lastSeen, historyCursor: historyCursor,
                       historyLoaded: historyLoaded), to: name(threadId))
    }

    public func historyState(threadId: String) -> (cursor: String?, loaded: Bool) {
        let snapshot = read(Snapshot.self, from: name(threadId))
        return (snapshot?.historyCursor, snapshot?.historyLoaded == true)
    }

    /// Last replayed event per thread. A newer live or optimistic event does not prove that
    /// all history before it arrived. Legacy arrays have no checkpoint and safely replay once.
    public func lastSeen() -> [String: String] {
        var seen: [String: String] = [:]
        for thread in threads() {
            if let last = read(Snapshot.self, from: name(thread.id))?.lastSeen { seen[thread.id] = last }
        }
        return seen
    }

    /// Percent-encoding keeps a thread id a file name without needing to be reversible.
    private func name(_ threadId: String) -> String {
        "thread-" + (threadId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "unnamed")
    }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).bin")
    }

    private func write(_ value: some Encodable, to name: String) {
        try? writeRequired(value, to: name)
    }

    private func writeRequired(_ value: some Encodable, to name: String) throws {
        let plain = try JSONEncoder().encode(value)
        let sealed = try AES.GCM.seal(plain, using: key).combined!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try sealed.write(to: url(name), options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let raw = try? Data(contentsOf: url(name)),
            let box = try? AES.GCM.SealedBox(combined: raw),
            let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return try? JSONDecoder().decode(type, from: plain)
    }
}
