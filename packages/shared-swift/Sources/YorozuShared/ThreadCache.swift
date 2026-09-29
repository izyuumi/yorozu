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

    /// Staged and pending files, each sealed once under the hash of its contents. The records
    /// naming them change with every retry date and upload offset, and are written on the main
    /// actor: megabytes of unchanged file must not be re-encoded and rewritten each time.
    private final class Files: @unchecked Sendable {
        let lock = NSLock()
        /// Content already hashed, so a save finds its file by comparing, not by hashing.
        var known: [(data: String, name: String)] = []
        /// Files each record names. Nothing is swept until both records have been seen.
        var named: [String: Set<String>] = [:]
        var swept: Set<String>?
    }
    private let files = Files()
    private static let fileReference = "yorozu-file-v1:"

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

    public func agents() -> [AgentDescriptor]? { read([AgentDescriptor].self, from: "agents") }
    public func save(agents: [AgentDescriptor]) { write(agents, to: "agents") }

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
        var used: Set<String> = []
        let outbox = (read([OutboxItem].self, from: "outbox") ?? []).map { $0.mappingFiles { loaded($0, &used) } }
        keep(used, for: "outbox")
        return outbox
    }

    public func save(outbox: [OutboxItem]) {
        try? savePending(outbox)
    }

    public struct StashedDraft: Codable, Sendable, Identifiable {
        public var id: String = UUID().uuidString
        public var text: String
        public var attachments: [MessageAttachment]
    }

    public struct ComposerState: Codable, Sendable {
        var drafts: [String: String]
        var attachments: [String: [MessageAttachment]]
        var threads: [ThreadSummary]
        var knownThreads: [ThreadSummary]?
        var openThread: String?
        var stashes: [String: [StashedDraft]]? = nil
        var readingPositions: [String: ReadingPosition]? = nil
        /// Prepared composer send. Outbox presence decides whether this draft was committed.
        var preparedSend: [String: String]? = nil
        var restoredWithdrawals: Set<String>? = nil
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
        var used: Set<String> = []
        var composer = read(ComposerState.self, from: "composer")
        if let attachments = composer?.attachments {
            composer?.attachments = attachments.mapValues { $0.map { loaded($0, &used) } }
        }
        if let stashes = composer?.stashes {
            composer?.stashes = stashes.mapValues { drafts in
                drafts.map { draft in
                    var draft = draft
                    draft.attachments = draft.attachments.map { loaded($0, &used) }
                    return draft
                }
            }
        }
        keep(used, for: "composer")
        return composer
    }

    public func save(composer: ComposerState) throws {
        var composer = composer
        var used: Set<String> = []
        composer.attachments = try composer.attachments.mapValues { try $0.map { try stored($0, &used) } }
        composer.stashes = try composer.stashes?.mapValues { drafts in
            try drafts.map { draft in
                var draft = draft
                draft.attachments = try draft.attachments.map { try stored($0, &used) }
                return draft
            }
        }
        try writeRequired(composer, to: "composer")
        keep(used, for: "composer")
    }

    /// Text changes far more often than staged file bytes. Keep it and the send marker in a
    /// small sealed record so a keystroke never rewrites every attachment in the composer.
    struct DraftState: Codable, Sendable {
        var drafts: [String: String]
        var preparedSend: [String: String]
        var threads: [ThreadSummary]
        var openThread: String?
        /// The model and effort last chosen for each agent, which a new thread starts on.
        var lastRun: [String: RunChoice]?
    }

    func draftState() -> DraftState? {
        read(DraftState.self, from: "drafts")
    }

    func save(draftState: DraftState) throws {
        try writeRequired(draftState, to: "drafts")
    }

    public func savePending(_ outbox: [OutboxItem]) throws {
        var used: Set<String> = []
        try writeRequired(outbox.map { try $0.mappingFiles { try stored($0, &used) } }, to: "outbox")
        keep(used, for: "outbox")
    }

    /// The file is written before the record that names it, and swept only after a record
    /// stops naming it, so a crash between the two leaves nothing a record cannot find.
    private func stored(_ file: MessageAttachment, _ used: inout Set<String>) throws -> MessageAttachment {
        guard !file.data.isEmpty, !file.isDeferred, !file.data.hasPrefix(Self.fileReference) else { return file }
        let name: String
        if let known = files.lock.withLock({ files.known.first { $0.data == file.data }?.name }) {
            name = known
        } else {
            name = "file-" + SHA256.hash(data: Data(file.data.utf8)).map { String(format: "%02x", $0) }.joined()
            files.lock.withLock { files.known.append((file.data, name)) }
        }
        if !FileManager.default.fileExists(atPath: url(name).path) {
            try seal(Data(file.data.utf8), to: name)
        }
        used.insert(name)
        var file = file
        file.data = Self.fileReference + name
        return file
    }

    private func loaded(_ file: MessageAttachment, _ used: inout Set<String>) -> MessageAttachment {
        guard file.data.hasPrefix(Self.fileReference) else { return file }
        let name = String(file.data.dropFirst(Self.fileReference.count))
        used.insert(name)
        guard let plain = open(name) else { return file }
        var file = file
        file.data = String(decoding: plain, as: UTF8.self)
        files.lock.withLock { files.known.append((file.data, name)) }
        return file
    }

    private func keep(_ used: Set<String>, for record: String) {
        let kept: Set<String>? = files.lock.withLock {
            files.named[record] = used
            guard files.named.count == 2 else { return nil }
            let kept = files.named.values.reduce(into: Set<String>()) { $0.formUnion($1) }
            guard kept != files.swept else { return nil }
            files.swept = kept
            files.known.removeAll { !kept.contains($0.name) }
            return kept
        }
        guard let kept, let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where name.hasPrefix("file-") && !kept.contains(String(name.dropLast(4))) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
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
        try seal(JSONEncoder().encode(value), to: name)
    }

    private func seal(_ plain: Data, to name: String) throws {
        let sealed = try AES.GCM.seal(plain, using: key).combined!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try sealed.write(to: url(name), options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        open(name).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }

    private func open(_ name: String) -> Data? {
        guard let raw = try? Data(contentsOf: url(name)),
            let box = try? AES.GCM.SealedBox(combined: raw)
        else { return nil }
        return try? AES.GCM.open(box, using: key)
    }
}

private extension OutboxItem {
    func mappingFiles(_ change: (MessageAttachment) throws -> MessageAttachment) rethrows -> OutboxItem {
        guard case .message(var message) = event.payload, !message.attachments.isEmpty else { return self }
        var item = self
        message.attachments = try message.attachments.map(change)
        item.event.payload = .message(message)
        return item
    }
}

/// A model and effort chosen together; nil for either is the provider's default.
struct RunChoice: Codable, Equatable, Sendable {
    var model: String?
    var effort: ReasoningEffort?
}
