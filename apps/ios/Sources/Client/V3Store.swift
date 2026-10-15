import Foundation
import YorozuWire

// Wire v3's local state (#425): the pairing in the Keychain, and a cache of conversations on disk. The Gateway
// transcript is the source of truth (#415); `history` pages (#427) fill this cache from it.

/// One pairing with the OpenClaw plugin, in one Keychain item (`Keychain`: this device only, never synced). Its own
/// account, apart from v2's `pairings-v2`: every device pairs again for v3.
struct V3Pairing: Codable, Equatable {
    var pairing: QrPayload
    var identity: PhoneIdentity
    /// The relay accepted this device once: the one-time token is spent.
    var relayKnows = false
    /// The plugin answered a handshake: the device is on its allowlist and the QR's secret is dropped.
    var paired = false
    var pairedAt: Date?

    private static let account = "pairing-v3"

    static func load() throws -> V3Pairing? {
        guard let data = try Keychain.loadRequired(account) else { return nil }
        return try JSONDecoder().decode(V3Pairing.self, from: data)
    }

    func save() throws { try Keychain.save(JSONEncoder().encode(self), account: Self.account) }

    static func remove() throws { try Keychain.clearRequired(account) }
}

/// One conversation: a thread session `agent:<agent>:yorozu:direct:owner:thread:<id>` on the Gateway.
struct Conversation: Codable, Identifiable, Equatable {
    let id: String
    var createdAt: Int64
    /// The latest item's arrival: the list's order.
    var updatedAt: Int64
    /// Transcript order (see `merge`): items from `history` carry their transcript `seq`; live ones are appended
    /// in arrival order, so a reply never sorts above the message it answers across two clocks, until a page holding
    /// them gives them their `seq`.
    var items: [ChatItem] = []
    /// The seq range of the transcript this cache holds without gaps; nil before the first page.
    var oldestSeq: Int?
    var newestSeq: Int?
    /// The oldest page came back without `more`: nothing older to load.
    var complete: Bool?
    /// The transcript `rev` of the last page that reached the newest item: equal to `conv_list`'s, nothing to fetch.
    var rev: Int?
    /// The read state (#429): the plugin's, or what this device set and the plugin has not answered yet.
    var read: V3ReadCursor?
    /// `read` was set here and the plugin has not sent it back: sent again on the next session.
    var readPending: Bool?
    /// The host's title (#428): the manual rename, else the generated one; nil before either.
    var title: String?
    /// Archived on the host: shown under Archived, not in the main list.
    var archived: Bool?

    /// Agent replies after the read cursor; at least 1 while marked unread.
    var unreadCount: Int {
        let after = read?.ts ?? .min
        return max(items.count { $0.kind == .agent && $0.ts > after }, read?.unread == true ? 1 : 0)
    }

    /// The newest reply by the plugin's clock: what a read moves the cursor to.
    var latestReply: ChatItem? { items.filter { $0.kind == .agent }.max { $0.ts < $1.ts } }

    /// The list's and the chat's label: the host's title, else (until the first reply makes one) the first message's
    /// first line, else "New Conversation".
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let first = (items.first { $0.kind == .user } ?? items.first { $0.kind == .agent })?.summary ?? ""
        let line = first.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line ?? String(localized: "New Conversation")
    }

    var lastText: String { items.last { $0.kind == .user || $0.kind == .agent }?.summary ?? "" }

    /// Places transcript items. An item already here (same id, or a live reply of the same text that has no seq yet)
    /// is replaced. Each goes after the last item known to be older (lower seq) and before the first one known or
    /// likely to be newer: a higher seq, or a live item with a later timestamp.
    mutating func merge(_ incoming: [ChatItem]) {
        for var item in incoming {
            guard let seq = item.seq else { continue }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            func lowerBound() -> Int { items.lastIndex { ($0.seq ?? .max) < seq }.map { $0 + 1 } ?? 0 }
            // A live reply is looked for only after the items known to be older, so a chunk repeated across replies
            // ("OK") is matched to its own reply, not to the first one of that text.
            let from = lowerBound()
            if let i = items.firstIndex(where: { $0.id == item.id }) ?? (item.kind == .agent ? items[from...].firstIndex(where: {
                $0.seq == nil && $0.kind == .agent && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
            }) : nil) {
                let old = items.remove(at: i)
                if item.kind == .user { item.status = max(old.status ?? .read, .read) }
                if item.kind == .tools { item.tools = ToolCall.union(old.tools ?? [], item.tools ?? []) }
                // Transcript pages carry no files (#430): the live item's stay.
                if item.attachments == nil { item.attachments = old.attachments }
            }
            let lower = lowerBound()
            let at = items[lower...].firstIndex { other in other.seq.map { $0 > seq } ?? (other.ts > item.ts) } ?? items.endIndex
            items.insert(item, at: at)
        }
        if let last = items.last?.ts { updatedAt = max(updatedAt, last) }
    }
}

struct ChatItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case user, agent, error, tools, reset }

    /// The messageId; `tools:<messageId>` and `error:<messageId>` for the rows about a user message's run.
    let id: String
    var kind: Kind
    var text: String
    /// Epoch ms: the client's clock for a user message, the plugin's for a reply.
    var ts: Int64
    /// A user message's mark.
    var status: SendStatus?
    /// `tools`: the run's calls, in the order they started.
    var tools: [ToolCall]?
    /// A user message's files (uploaded before the message goes) or a reply's (downloaded on request), #430.
    var attachments: [ChatAttachment]?
    /// The transcript seq, for items a `history` page brought; nil for live ones not confirmed by a page yet.
    var seq: Int?

    /// The text, or the first file's name for a message that is only files.
    var summary: String {
        text.isEmpty ? attachments?.first.map { "📎 \($0.name)" } ?? "" : text
    }
}

/// One file of a message or reply. Its bytes, once here, are in `AttachmentFiles` under `id`.
struct ChatAttachment: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var mime: String
    var size: Int
    /// A user message's file: the plugin stored it (`upload_ack {done}`), so the message may name it.
    var uploaded: Bool?
    /// Why it was not sent (the plugin refused it); such a file is left out of its message.
    var failure: String?

    var wire: V3Attachment { V3Attachment(id: id, name: name, mime: mime, size: size) }

    /// From the wire; nil for none, so a history item without files keeps the live item's.
    static func list(_ files: [V3Attachment]?, uploaded: Bool? = nil) -> [ChatAttachment]? {
        guard let files, !files.isEmpty else { return nil }
        return files.filter { V3Event.isId($0.id) }
            .map { ChatAttachment(id: $0.id, name: $0.name, mime: $0.mime, size: $0.size, uploaded: uploaded) }
    }
    var isImage: Bool { mime.hasPrefix("image/") }
}

extension ChatItem {
    /// A transcript item from a `history` page. A run's `tools` row has the live row's id, `tools:<messageId>`.
    init(_ item: V3HistoryItem) {
        switch item.kind {
        case .user:
            self.init(id: item.id, kind: .user, text: item.text ?? "", ts: item.ts, status: .read,
                attachments: ChatAttachment.list(item.attachments, uploaded: true), seq: item.seq)
        case .agent:
            self.init(id: item.id, kind: .agent, text: item.text ?? "", ts: item.ts,
                attachments: ChatAttachment.list(item.attachments), seq: item.seq)
        case .tools:
            self.init(id: "tools:\(item.id)", kind: .tools, text: "", ts: item.ts,
                tools: (item.tools ?? []).map { ToolCall(id: $0.callId, name: $0.name, status: $0.status) }, seq: item.seq)
        case .reset:
            self.init(id: "reset:\(item.id)", kind: .reset, text: "", ts: item.ts, seq: item.seq)
        }
    }
}

/// ✓ sent = relay `accepted`, ✓✓ delivered = plugin `delivered`, read = `run_started` (#415).
enum SendStatus: Int, Codable, Comparable {
    /// Not on any socket yet: waits for a session.
    case queued
    /// Sealed and on the socket; no `accepted` yet.
    case sending
    case sent
    case delivered
    case read

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct ToolCall: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var status: V3Tool.Status

    /// A page may split a run's calls, and live updates may be newer than a page: a finished status beats `running`.
    static func union(_ a: [ToolCall], _ b: [ToolCall]) -> [ToolCall] {
        var calls = a
        for call in b {
            if let i = calls.firstIndex(where: { $0.id == call.id }) {
                if call.status != .running { calls[i].status = call.status }
            } else {
                calls.append(call)
            }
        }
        return calls
    }
}

/// One JSON file per conversation, under Data Protection `complete` on iOS: unreadable while the device is locked.
/// Excluded from backup. On the Mac, files sit in the app's Application Support folder with the user account's
/// protection (FileVault); macOS has no per-file Data Protection classes for an app outside the sandbox.
final class ConversationCache: Sendable {
    private let directory = clientSupportDirectory.appending(path: "Conversations-v3", directoryHint: .isDirectory)
    private let queue = DispatchQueue(label: "yorozu.v3.cache")

    func loadAll() -> [Conversation] {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap {
                (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(Conversation.self, from: $0) }
            }
        }
    }

    /// Written in order, off the main actor. A write that fails (the device locked meanwhile) is retried by the next
    /// save of that conversation, which writes it whole.
    func save(_ conversation: Conversation) {
        guard V3Event.isId(conversation.id) else { return }
        queue.async { [directory] in
            do {
                try Self.makeDirectory(directory)
                var options: Data.WritingOptions = [.atomic]
                #if os(iOS)
                options.insert(.completeFileProtection)
                #endif
                try JSONEncoder().encode(conversation).write(to: directory.appending(path: "\(conversation.id).json"), options: options)
            } catch {}
        }
    }

    /// A conversation deleted on the host.
    func remove(_ id: String) {
        guard V3Event.isId(id) else { return }
        queue.async { [directory] in try? FileManager.default.removeItem(at: directory.appending(path: "\(id).json")) }
    }

    func wipe() {
        queue.async { [directory] in try? FileManager.default.removeItem(at: directory) }
    }

    private static func makeDirectory(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
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
}
