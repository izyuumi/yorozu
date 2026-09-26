import Foundation

/// Canonical base64url of the host's 32-byte X25519 public key. Relay addresses, room names,
/// and computer names can change without changing this identity.
public typealias HostID = String

extension QrPayload {
    public var hostID: HostID? {
        guard let key = Data(base64URLEncoded: macPubkey), key.count == 32 else { return nil }
        return key.base64URLEncodedString()
    }
}

/// A thread ID is only meaningful within its authenticated host's namespace.
public struct HostThreadID: Codable, Hashable, Sendable {
    public let hostID: HostID
    public let threadID: String

    public init(hostID: HostID, threadID: String) {
        self.hostID = hostID
        self.threadID = threadID
    }
}

public struct HostThread: Identifiable, Equatable, Sendable {
    public let id: HostThreadID
    public let thread: ThreadSummary
    public let hostLabel: String

    public init(id: HostThreadID, thread: ThreadSummary, hostLabel: String) {
        self.id = id
        self.thread = thread
        self.hostLabel = hostLabel
    }
}

@MainActor @Observable
public final class HostSession: Identifiable {
    public let id: HostID
    public let model: ChatModel
    public let relayURL: String
    public var nickname: String?
    public var pairedAt: Date?

    public init(id: HostID, model: ChatModel, relayURL: String, nickname: String? = nil, pairedAt: Date? = nil) {
        self.id = id
        self.model = model
        self.relayURL = relayURL
        self.nickname = nickname
        self.pairedAt = pairedAt
    }

    public var label: String {
        if let nickname, !nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let name = model.peerInfo?.computerName { return name }
        let fingerprint = QrPayload.fingerprint(ofBase64URLKey: id) ?? String(id.prefix(12))
        return "Mac · \(fingerprint)"
    }
}

public struct HostThreadSearchResults: Sendable {
    public let threads: [HostThread]
    public let messages: [HostThread]
    public var isEmpty: Bool { threads.isEmpty && messages.isEmpty }
}

/// Combines presentation, never transports. Every operation resolves to one existing
/// per-host ChatModel, so colliding thread IDs cannot share drafts, queues, or approvals.
@MainActor @Observable
public final class MultiHostModel {
    public private(set) var sessions: [HostSession]
    public var lastUsedHostID: HostID?
    public var foreground = false {
        didSet { for session in sessions { session.model.foreground = foreground } }
    }

    public init(sessions: [HostSession] = [], lastUsedHostID: HostID? = nil) {
        var seen: Set<HostID> = []
        self.sessions = sessions.filter { seen.insert($0.id).inserted }
        self.lastUsedHostID = lastUsedHostID
    }

    public func session(for hostID: HostID) -> HostSession? { sessions.first { $0.id == hostID } }
    public func model(for id: HostThreadID) -> ChatModel? { session(for: id.hostID)?.model }

    /// Connection identity still matters while a saved host is offline or being repaired.
    public var hasMultipleHosts: Bool { sessions.count > 1 }

    public var threads: [HostThread] {
        sessions.flatMap { session in
            session.model.threads.map {
                HostThread(id: .init(hostID: session.id, threadID: $0.id), thread: $0, hostLabel: session.label)
            }
        }.sorted {
            if $0.thread.lastActivity != $1.thread.lastActivity { return $0.thread.lastActivity > $1.thread.lastActivity }
            if $0.id.hostID != $1.id.hostID { return $0.id.hostID < $1.id.hostID }
            return $0.id.threadID < $1.id.threadID
        }
    }

    public func thread(for id: HostThreadID) -> HostThread? {
        guard let session = session(for: id.hostID),
            let thread = session.model.threads.first(where: { $0.id == id.threadID }) else { return nil }
        return HostThread(id: id, thread: thread, hostLabel: session.label)
    }

    public func messageText(for id: HostThreadID) -> String {
        (model(for: id)?.events[id.threadID] ?? []).compactMap {
            if case .message(let message) = $0.payload { return message.text }
            return nil
        }.joined(separator: "\n")
    }

    public func search(_ query: String) -> HostThreadSearchResults {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return HostThreadSearchResults(threads: [], messages: []) }
        var metadata: [HostThread] = []
        var messages: [HostThread] = []
        for row in threads {
            if threadMatches(row.thread, query: needle) || !searchRanges(in: row.hostLabel, term: needle).isEmpty {
                metadata.append(row)
            } else if !searchRanges(in: messageText(for: row.id), term: needle).isEmpty {
                messages.append(row)
            }
        }
        return HostThreadSearchResults(threads: metadata, messages: messages)
    }

    /// The caller detects duplicates before spending a code; this second check protects the
    /// live collection if two add flows complete together.
    @discardableResult public func add(_ session: HostSession) -> Bool {
        guard self.session(for: session.id) == nil else { return false }
        sessions.append(session)
        session.model.foreground = foreground
        return true
    }

    /// Await before erasing keys or files: no retiring writer may recreate a removed cache.
    @discardableResult public func remove(_ hostID: HostID) async -> HostSession? {
        guard let index = sessions.firstIndex(where: { $0.id == hostID }) else { return nil }
        let removed = sessions.remove(at: index)
        if lastUsedHostID == hostID { lastUsedHostID = sessions.first?.id }
        await removed.model.shutdown()
        return removed
    }

    public var preferredHostID: HostID? {
        if let lastUsedHostID, session(for: lastUsedHostID) != nil { return lastUsedHostID }
        return sessions.first?.id
    }

    /// Reopen only a cached thread that still belongs to the previously used host.
    public var restoredOpenThread: HostThreadID? {
        guard let hostID = preferredHostID,
              let model = session(for: hostID)?.model,
              let threadID = model.openThread,
              model.threads.contains(where: { $0.id == threadID }) else { return nil }
        return HostThreadID(hostID: hostID, threadID: threadID)
    }

    @discardableResult
    public func newDraft(on hostID: HostID? = nil, agent: ThreadAgent = .yorozu, cwd: String? = nil) -> HostThreadID? {
        guard let hostID = hostID ?? preferredHostID, let session = session(for: hostID) else { return nil }
        lastUsedHostID = hostID
        return HostThreadID(hostID: hostID, threadID: session.model.newDraft(agent: agent, cwd: cwd).id)
    }

    public var unreadCount: Int { sessions.reduce(0) { $0 + $1.model.unreadCount } }
    public func markAllRead() { for session in sessions { session.model.markAllRead() } }
    public func start() { for session in sessions { session.model.start() } }
    public func suspend() { for session in sessions { session.model.suspend() } }
    public func reconnect() { for session in sessions { session.model.reconnect() } }
}
