import Foundation
import YorozuWire

struct Pairing: Codable, Equatable {
    var pairing: QrPayload
    var identity: PhoneIdentity
    var relayKnows = false
    var paired = false
    var pairedAt: Date?

    private static let account = "pairing-v3"

    static func load() throws -> Pairing? {
        guard let data = try Keychain.loadRequired(account) else { return nil }
        return try JSONDecoder().decode(Pairing.self, from: data)
    }

    func save() throws { try Keychain.save(JSONEncoder().encode(self), account: Self.account) }

    static func remove() throws { try Keychain.clearRequired(account) }
}

struct Conversation: Codable, Identifiable, Equatable {
    let id: String
    var createdAt: Int64
    var updatedAt: Int64
    var items: [ChatItem] = []
    var oldestSeq: Int?
    var newestSeq: Int?
    var complete: Bool?
    var rev: Int?
    var read: V3ReadCursor?
    var readPending: Bool?
    var title: String?
    var archived: Bool?
    var pinnedAt: Int64?

    var readUpTo: Int64 {
        guard let read else { return .min }
        return max(read.ts, items.first { $0.id == read.messageId }?.ts ?? .min)
    }

    var withoutStrayErrors: Conversation {
        let ids = Set(items.map(\.id))
        var conversation = self
        conversation.items.removeAll { $0.kind == .error && !ids.contains(String($0.id.dropFirst("error:".count))) }
        if conversation.items.count < items.count, let newest = conversation.items.map(\.ts).max() {
            conversation.updatedAt = newest
        }
        return conversation
    }

    var unreadCount: Int {
        let after = readUpTo
        return max(items.count { $0.kind == .agent && $0.ts > after }, read?.unread == true ? 1 : 0)
    }

    var needsAttention: Bool {
        let after = readUpTo
        return items.contains { $0.kind == .error && $0.ts > after }
    }

    var latestReply: ChatItem? { items.filter { $0.kind == .agent }.max { $0.ts < $1.ts } }

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let first = (items.first { $0.kind == .user } ?? items.first { $0.kind == .agent })?.summary ?? ""
        let line = first.split(separator: "\n").lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        return line ?? String(localized: "New Conversation")
    }

    var lastText: String {
        let text = items.last { $0.kind == .user || $0.kind == .agent }?.summary ?? ""
        let plain = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        return plain.map { String($0.characters) } ?? text
    }

    mutating func merge(_ incoming: [ChatItem]) {
        let seqs = incoming.compactMap(\.seq)
        if let low = seqs.min(), let high = seqs.max() {
            let ids = Set(incoming.map(\.id))
            items.removeAll { item in item.seq.map { (low...high).contains($0) } == true && !ids.contains(item.id) }
        }
        for var item in incoming {
            guard let seq = item.seq else { continue }
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            func lowerBound() -> Int { items.lastIndex { ($0.seq ?? .max) < seq }.map { $0 + 1 } ?? 0 }
            let from = lowerBound()
            if let i = items.firstIndex(where: { $0.id == item.id }) ?? (item.kind == .agent ? items[from...].firstIndex(where: {
                $0.seq == nil && $0.kind == .agent && $0.text.trimmingCharacters(in: .whitespacesAndNewlines) == text
            }) : nil) {
                let old = items.remove(at: i)
                if item.kind == .user { item.status = max(old.status ?? .read, .read) }
                if item.kind == .tools { item.tools = ToolCall.union(old.tools ?? [], item.tools ?? []) }
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

    let id: String
    var kind: Kind
    var text: String
    var ts: Int64
    var status: SendStatus?
    var tools: [ToolCall]?
    var attachments: [ChatAttachment]?
    var seq: Int?

    var summary: String {
        text.isEmpty ? attachments?.first.map { "📎 \($0.name)" } ?? "" : text
    }
}

struct ChatAttachment: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var mime: String
    var size: Int
    var uploaded: Bool?
    var failure: String?

    var wire: V3Attachment { V3Attachment(id: id, name: name, mime: mime, size: size) }

    static func list(_ files: [V3Attachment]?, uploaded: Bool? = nil) -> [ChatAttachment]? {
        guard let files, !files.isEmpty else { return nil }
        return files.filter { V3Event.isId($0.id) }
            .map { ChatAttachment(id: $0.id, name: $0.name, mime: $0.mime, size: $0.size, uploaded: uploaded) }
    }
    var isImage: Bool { mime.hasPrefix("image/") }
}

extension ChatItem {
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

enum SendStatus: Int, Codable, Comparable {
    case queued
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

final class ConversationCache: Sendable {
    private let directory = clientSupportDirectory.appending(path: "Conversations-v3", directoryHint: .isDirectory)
    private let queue = DispatchQueue(label: "yorozu.v3.cache")

    func loadAll() -> [Conversation] {
        queue.sync {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap {
                (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(Conversation.self, from: $0) }?.withoutStrayErrors
            }
        }
    }

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
