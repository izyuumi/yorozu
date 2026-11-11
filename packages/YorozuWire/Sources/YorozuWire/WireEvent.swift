import Foundation

public enum WireEvent: Equatable, Sendable {
    case peerInfo(PeerInfo)
    case message(Message)
    case delivered(MessageRef)
    case runStarted(MessageRef)
    case typing(Typing)
    case reply(Reply)
    case reaction(Reaction)
    case error(ErrorInfo)
    case tool(Tool)
    case convList(ConvList)
    case historyRequest(HistoryRequest)
    case history(History)
    case readCursor(ReadCursor)
    case foreground(Foreground)
    case convPatch(ConvPatch)
    case convUpdate(ConvUpdate)
    case cronList(CronList)
    case deviceList(DeviceList)
    case devicePatch(DevicePatch)
    case pairInvite(PairInvite)
    case upload(Upload)
    case uploadAck(UploadAck)
    case uploadStatus(UploadStatus)
    case uploadState(UploadState)
    case download(Download)
    case chunk(Chunk)
    case liveActivity(ActivityReport)
    case pushToken(PushToken)
    case directHints(DirectHints)
    case unknown(kind: String, data: JSONValue?)

    public var kind: String {
        switch self {
        case .peerInfo: "peer_info"
        case .message: "message"
        case .delivered: "delivered"
        case .runStarted: "run_started"
        case .typing: "typing"
        case .reply: "reply"
        case .reaction: "reaction"
        case .error: "error"
        case .tool: "tool"
        case .convList: "conv_list"
        case .historyRequest, .history: "history"
        case .readCursor: "read_cursor"
        case .foreground: "foreground"
        case .convPatch: "conv_patch"
        case .convUpdate: "conv_update"
        case .cronList: "cron_list"
        case .deviceList: "device_list"
        case .devicePatch: "device_patch"
        case .pairInvite: "pair_invite"
        case .upload: "upload"
        case .uploadAck: "upload_ack"
        case .uploadStatus: "upload_status"
        case .uploadState: "upload_state"
        case .download: "download"
        case .chunk: "chunk"
        case .liveActivity: "live_activity"
        case .pushToken: "push_token"
        case .directHints: "direct_hints"
        case .unknown(let kind, _): kind
        }
    }

    public static func isId(_ value: String) -> Bool {
        value.utf8.count == 36 && value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: .regularExpression) != nil
    }

    public static func newId() -> String { UUID().uuidString.lowercased() }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct PeerInfo: Codable, Equatable, Sendable {
    public static let protocolVersion = 3

    public var protocolMin: Int
    public var protocolMax: Int
    public var app: String
    public var name: String?
    public var capabilities: [String]
    public var mediaMaxBytes: Int?
    public var agent: String?
    public var hostVersion: String?

    public init(app: String, name: String? = nil, capabilities: [String] = [],
        protocolMin: Int = PeerInfo.protocolVersion, protocolMax: Int = PeerInfo.protocolVersion,
        mediaMaxBytes: Int? = nil) {
        self.protocolMin = protocolMin
        self.protocolMax = protocolMax
        self.app = app
        self.name = name
        self.capabilities = capabilities
        self.mediaMaxBytes = mediaMaxBytes
    }

    public func negotiate(with peer: PeerInfo) -> Int? {
        let version = min(protocolMax, peer.protocolMax)
        return version >= max(protocolMin, peer.protocolMin) ? version : nil
    }
}

public struct Message: Codable, Equatable, Sendable {
    public var convId: String
    public var messageId: String
    public var text: String
    public var attachments: [Attachment]?
    public var replyTo: ReplyTo?

    public init(convId: String, messageId: String, text: String, attachments: [Attachment]? = nil, replyTo: ReplyTo? = nil) {
        self.convId = convId
        self.messageId = messageId
        self.text = text
        self.attachments = attachments
        self.replyTo = replyTo
    }
}

/// The message a `message`, `reply` or history item answers; capability `replies`.
public struct ReplyTo: Codable, Equatable, Sendable {
    public static let capability = "replies"
    public static let maxText = 2000

    public var messageId: String
    public var text: String?

    public init(messageId: String, text: String? = nil) {
        self.messageId = messageId
        self.text = text.map { String($0.prefix(Self.maxText)) }
    }
}

/// One person's reaction on a message, both ways; capability `reactions`. The plugin sets `by`.
public struct Reaction: Codable, Equatable, Sendable {
    public static let capability = "reactions"
    public static let maxEmoji = 32
    public enum By: String, Codable, Sendable { case user, agent }

    public var convId: String
    public var messageId: String
    public var emoji: String
    public var remove: Bool?
    public var by: By?

    public init(convId: String, messageId: String, emoji: String, remove: Bool = false) {
        self.convId = convId
        self.messageId = messageId
        self.emoji = emoji
        self.remove = remove ? true : nil
    }

    /// A `by` this client doesn't know reads as absent, so the reaction still decodes (and is ignored).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        convId = try c.decode(String.self, forKey: .convId)
        messageId = try c.decode(String.self, forKey: .messageId)
        emoji = try c.decode(String.self, forKey: .emoji)
        remove = try c.decodeIfPresent(Bool.self, forKey: .remove)
        by = (try? c.decodeIfPresent(String.self, forKey: .by)).flatMap(By.init(rawValue:))
    }
}

/// The reactions on a message, one emoji per person.
public struct Reactions: Codable, Equatable, Sendable {
    public var user: String?
    public var agent: String?

    public init(user: String? = nil, agent: String? = nil) {
        self.user = user
        self.agent = agent
    }
}

public struct MessageRef: Codable, Equatable, Sendable {
    public var convId: String
    public var messageId: String

    public init(convId: String, messageId: String) {
        self.convId = convId
        self.messageId = messageId
    }
}

public struct Typing: Codable, Equatable, Sendable {
    public var convId: String
    public var active: Bool

    public init(convId: String, active: Bool) {
        self.convId = convId
        self.active = active
    }
}

public struct Reply: Codable, Equatable, Sendable {
    public var convId: String
    public var messageId: String
    public var text: String
    public var ts: Int64
    public var attachments: [Attachment]?
    public var replyTo: ReplyTo?
    public var presentation: Presentation?

    public init(convId: String, messageId: String, text: String, ts: Int64, attachments: [Attachment]? = nil, replyTo: ReplyTo? = nil,
        presentation: Presentation? = nil) {
        self.convId = convId
        self.messageId = messageId
        self.text = text
        self.ts = ts
        self.attachments = attachments
        self.replyTo = replyTo
        self.presentation = presentation
    }

    /// A card this client can't read is dropped; the reply keeps the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        convId = try c.decode(String.self, forKey: .convId)
        messageId = try c.decode(String.self, forKey: .messageId)
        text = try c.decode(String.self, forKey: .text)
        ts = try c.decode(Int64.self, forKey: .ts)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments)
        replyTo = try c.decodeIfPresent(ReplyTo.self, forKey: .replyTo)
        presentation = try c.decodeIfPresent(LossyPresentation.self, forKey: .presentation)?.value
    }
}

/// A read-only card next to the text of a `reply` or an agent history item; capability `presentation`.
/// The reader is tolerant: a block of an unknown type, or one that fails a check, decodes as `.unknown` with its `alt`.
public struct Presentation: Codable, Equatable, Sendable {
    public static let capability = "presentation"
    public static let maxBytes = 64 * 1024

    public enum Tone: String, Codable, Sendable { case info, success, warning, danger, neutral }

    public enum Cell: Codable, Equatable, Sendable {
        case string(String)
        case number(Double)

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Double.self) { self = .number(v) } else { self = .string(try c.decode(String.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .number(let v): try c.encode(v)
            }
        }
    }

    public struct Table: Codable, Equatable, Sendable {
        public var caption: String?
        public var headers: [String]
        public var rows: [[Cell]]
        public var rowHeaderColumnIndex: Int?

        public init(caption: String? = nil, headers: [String], rows: [[Cell]], rowHeaderColumnIndex: Int? = nil) {
            self.caption = caption
            self.headers = headers
            self.rows = rows
            self.rowHeaderColumnIndex = rowHeaderColumnIndex
        }

        /// The row header column, when the index names one.
        public var rowHeader: Int? { rowHeaderColumnIndex.flatMap { headers.indices.contains($0) ? $0 : nil } }

        var valid: Bool {
            !headers.isEmpty && !rows.isEmpty && rows.allSatisfy { row in
                row.count == headers.count && row.allSatisfy { if case .number(let v) = $0 { v.isFinite } else { true } }
            }
        }
    }

    public struct Chart: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case pie, bar, line, area }
        public struct Segment: Codable, Equatable, Sendable {
            public var label: String
            public var value: Double
        }
        public struct Series: Codable, Equatable, Sendable {
            public var name: String
            public var values: [Double]
        }

        public var title: String?
        public var chartType: Kind
        public var segments: [Segment]?
        public var categories: [String]?
        public var series: [Series]?
        public var xLabel: String?
        public var yLabel: String?

        var valid: Bool {
            if chartType == .pie {
                guard let segments, !segments.isEmpty else { return false }
                return segments.allSatisfy { $0.value.isFinite && $0.value >= 0 }
            }
            guard let categories, let series, !categories.isEmpty, !series.isEmpty else { return false }
            return series.allSatisfy { $0.values.count == categories.count && $0.values.allSatisfy(\.isFinite) }
        }
    }

    public enum Block: Codable, Equatable, Sendable {
        case text(String)
        case context(String)
        case divider
        case table(Table, alt: String?)
        case chart(Chart, alt: String?)
        case unknown(alt: String?)

        /// The block as plain text: what draws when the block itself can't, and what assistive technology can read.
        public var alt: String? {
            switch self {
            case .text(let text), .context(let text): text
            case .divider: nil
            case .table(_, let alt), .chart(_, let alt), .unknown(let alt): alt
            }
        }

        private enum Keys: String, CodingKey { case type, text, alt }

        public init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: Keys.self)
            let alt = try? c?.decodeIfPresent(String.self, forKey: .alt)
            let text = try? c?.decodeIfPresent(String.self, forKey: .text)
            switch try? c?.decode(String.self, forKey: .type) {
            case "text": if let text, !text.isEmpty { self = .text(text); return }
            case "context": if let text, !text.isEmpty { self = .context(text); return }
            case "divider": self = .divider; return
            case "table": if let table = try? Table(from: decoder), table.valid { self = .table(table, alt: alt); return }
            case "chart": if let chart = try? Chart(from: decoder), chart.valid { self = .chart(chart, alt: alt); return }
            default: break
            }
            self = .unknown(alt: alt)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: Keys.self)
            switch self {
            case .text(let text):
                try c.encode("text", forKey: .type)
                try c.encode(text, forKey: .text)
            case .context(let text):
                try c.encode("context", forKey: .type)
                try c.encode(text, forKey: .text)
            case .divider:
                try c.encode("divider", forKey: .type)
            case .table(let table, let alt):
                try table.encode(to: encoder)
                try c.encode("table", forKey: .type)
                try c.encodeIfPresent(alt, forKey: .alt)
            case .chart(let chart, let alt):
                try chart.encode(to: encoder)
                try c.encode("chart", forKey: .type)
                try c.encodeIfPresent(alt, forKey: .alt)
            case .unknown(let alt):
                try c.encode("unknown", forKey: .type)
                try c.encodeIfPresent(alt, forKey: .alt)
            }
        }
    }

    public var title: String?
    public var tone: Tone?
    public var blocks: [Block]

    public init(title: String? = nil, tone: Tone? = nil, blocks: [Block]) {
        self.title = title
        self.tone = tone
        self.blocks = blocks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        tone = try? c.decodeIfPresent(Tone.self, forKey: .tone)
        blocks = try c.decode([Block].self, forKey: .blocks)
    }

    /// The blocks to draw: one that fell back to an empty or missing `alt` is skipped.
    public var drawn: [Block] {
        blocks.filter { if case .unknown(let alt) = $0 { alt?.isEmpty == false } else { true } }
    }

    /// False when nothing but dividers is left to draw: the bubble shows the message's text.
    public var renders: Bool { drawn.contains { $0 != .divider } }

    /// How many blocks fell back to their `alt` or were skipped.
    public var fellBack: Int { blocks.count { if case .unknown = $0 { true } else { false } } }
}

/// A card over `Presentation.maxBytes`, or one that isn't a card, decodes as nil. The decoder hands over no bytes, so
/// the size is the card's compact JSON, which is how the plugin sends it.
private struct LossyPresentation: Decodable {
    let value: Presentation?

    init(from decoder: Decoder) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let raw = try? JSONValue(from: decoder), let size = try? encoder.encode(raw).count, size <= Presentation.maxBytes else {
            value = nil
            return
        }
        value = try? Presentation(from: decoder)
    }
}

public struct ErrorInfo: Codable, Equatable, Sendable {
    public static let hashMismatch = "hash_mismatch"

    public var code: String
    public var message: String
    public var convId: String?
    public var messageId: String?
    public var attachmentId: String?

    public init(code: String, message: String, convId: String? = nil, messageId: String? = nil, attachmentId: String? = nil) {
        self.code = code
        self.message = message
        self.convId = convId
        self.messageId = messageId
        self.attachmentId = attachmentId
    }
}

public struct Attachment: Codable, Equatable, Sendable, Identifiable {
    public static let capability = "attachments"
    public static let resumeCapability = "resume"
    public static let chunkBytes = 160 * 1024
    public static let defaultMaxBytes = 128 * 1024 * 1024
    public static let maxPerMessage = 32
    public static let maxLabel = 255

    public var id: String
    public var name: String
    public var mime: String
    public var size: Int

    public init(id: String, name: String, mime: String, size: Int) {
        self.id = id
        self.name = name
        self.mime = mime
        self.size = size
    }

    public static func chunkCount(_ size: Int) -> Int { max(1, (size + chunkBytes - 1) / chunkBytes) }

    public static func wireName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let named = trimmed.isEmpty ? "file" : trimmed
        guard named.count > maxLabel else { return named }
        let ext = (named as NSString).pathExtension
        guard !ext.isEmpty, ext.count < maxLabel / 2 else { return String(named.prefix(maxLabel)) }
        return String((named as NSString).deletingPathExtension.prefix(maxLabel - ext.count - 1)) + "." + ext
    }

    public static func wireMime(_ mime: String) -> String {
        let trimmed = mime.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.count > maxLabel ? "application/octet-stream" : trimmed
    }
}

public struct Upload: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var name: String
    public var mime: String
    public var size: Int
    public var index: Int
    public var count: Int
    public var data: String
    /// The whole file's SHA-256, lowercase hex; sent only to a plugin listing `resume`.
    public var sha256: String?

    public init(attachmentId: String, name: String, mime: String, size: Int, index: Int, count: Int, data: String,
        sha256: String? = nil) {
        self.attachmentId = attachmentId
        self.name = name
        self.mime = mime
        self.size = size
        self.index = index
        self.count = count
        self.data = data
        self.sha256 = sha256
    }
}

public struct UploadAck: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var index: Int
    public var done: Bool

    public init(attachmentId: String, index: Int, done: Bool) {
        self.attachmentId = attachmentId
        self.index = index
        self.done = done
    }
}

public struct Download: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var index: Int

    public init(attachmentId: String, index: Int) {
        self.attachmentId = attachmentId
        self.index = index
    }
}

public struct Chunk: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var index: Int
    public var count: Int
    public var data: String

    public init(attachmentId: String, index: Int, count: Int, data: String) {
        self.attachmentId = attachmentId
        self.index = index
        self.count = count
        self.data = data
    }
}

public struct Tool: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case running, done, failed }

    public var convId: String
    public var messageId: String
    public var callId: String
    public var name: String
    public var status: Status

    public init(convId: String, messageId: String, callId: String, name: String, status: Status) {
        self.convId = convId
        self.messageId = messageId
        self.callId = callId
        self.name = name
        self.status = status
    }
}

public struct ConvList: Codable, Equatable, Sendable {
    public var conversations: [ConvSummary]?

    public init(conversations: [ConvSummary]? = nil) { self.conversations = conversations }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try c.decodeIfPresent([Lossy<ConvSummary>].self, forKey: .conversations)?
            .compactMap(\.value).filter { WireEvent.isId($0.convId) }
    }
}

public struct ConvSummary: Codable, Equatable, Sendable {
    public var convId: String
    public var updatedAt: Int64
    public var rev: Int

    public var title: String?
    public var archived: Bool?
    public var pinnedAt: Int64?

    public init(convId: String, updatedAt: Int64, rev: Int, title: String? = nil, archived: Bool? = nil, pinnedAt: Int64? = nil) {
        self.convId = convId
        self.updatedAt = updatedAt
        self.rev = rev
        self.title = title
        self.archived = archived
        self.pinnedAt = pinnedAt
    }
}

public struct HistoryRequest: Codable, Equatable, Sendable {
    public var convId: String
    public var before: Int?
    public var after: Int?

    public init(convId: String, before: Int? = nil, after: Int? = nil) {
        self.convId = convId
        self.before = before
        self.after = after
    }
}

public struct History: Codable, Equatable, Sendable {
    public var convId: String
    public var before: Int?
    public var after: Int?
    public var items: [HistoryItem]
    public var more: Bool
    public var rev: Int

    public init(convId: String, before: Int? = nil, after: Int? = nil, items: [HistoryItem], more: Bool, rev: Int) {
        self.convId = convId
        self.before = before
        self.after = after
        self.items = items
        self.more = more
        self.rev = rev
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        convId = try c.decode(String.self, forKey: .convId)
        before = try c.decodeIfPresent(Int.self, forKey: .before)
        after = try c.decodeIfPresent(Int.self, forKey: .after)
        items = try c.decode([Lossy<HistoryItem>].self, forKey: .items).compactMap(\.value)
            .filter { WireEvent.isId($0.id) }
        more = try c.decode(Bool.self, forKey: .more)
        rev = try c.decode(Int.self, forKey: .rev)
    }
}

public struct HistoryItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, agent, tools, reset }
    public struct Call: Codable, Equatable, Sendable {
        public var callId: String
        public var name: String
        public var status: Tool.Status
    }

    public var kind: Kind
    public var id: String
    public var seq: Int
    public var ts: Int64
    public var text: String?
    public var tools: [Call]?
    public var attachments: [Attachment]?
    public var replyTo: ReplyTo?
    public var reactions: Reactions?
    public var presentation: Presentation?

    public init(kind: Kind, id: String, seq: Int, ts: Int64, text: String? = nil, tools: [Call]? = nil,
        attachments: [Attachment]? = nil, replyTo: ReplyTo? = nil, reactions: Reactions? = nil, presentation: Presentation? = nil) {
        self.kind = kind
        self.id = id
        self.seq = seq
        self.ts = ts
        self.text = text
        self.tools = tools
        self.attachments = attachments
        self.replyTo = replyTo
        self.reactions = reactions
        self.presentation = presentation
    }

    /// A call whose status this client doesn't know is dropped, and so is a card it can't read; the item keeps the rest.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        id = try c.decode(String.self, forKey: .id)
        seq = try c.decode(Int.self, forKey: .seq)
        ts = try c.decode(Int64.self, forKey: .ts)
        text = try c.decodeIfPresent(String.self, forKey: .text)
        tools = try c.decodeIfPresent([Lossy<Call>].self, forKey: .tools)?.compactMap(\.value)
        attachments = try c.decodeIfPresent([Attachment].self, forKey: .attachments)
        replyTo = try c.decodeIfPresent(ReplyTo.self, forKey: .replyTo)
        reactions = try c.decodeIfPresent(Reactions.self, forKey: .reactions)
        presentation = try c.decodeIfPresent(LossyPresentation.self, forKey: .presentation)?.value
    }
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

public struct ReadCursor: Codable, Equatable, Sendable {
    public var convId: String
    public var messageId: String
    public var ts: Int64
    public var unread: Bool

    public init(convId: String, messageId: String, ts: Int64, unread: Bool) {
        self.convId = convId
        self.messageId = messageId
        self.ts = ts
        self.unread = unread
    }
}

public struct Foreground: Codable, Equatable, Sendable {
    public var convId: String?
    public var active: Bool?

    public init(convId: String?, active: Bool? = nil) {
        self.convId = convId
        self.active = active
    }
}

public enum Devices {
    public static let capability = "devices"
}

public struct DeviceInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var pairedAt: Int64
    public var push: Bool
    public var current: Bool
}

public struct DeviceList: Codable, Equatable, Sendable {
    public var devices: [DeviceInfo]?
    public var error: String?

    public init(devices: [DeviceInfo]? = nil, error: String? = nil) {
        self.devices = devices
        self.error = error
    }
}

public struct DevicePatch: Codable, Equatable, Sendable {
    public var id: String
    public var push: Bool?
    public var removed: Bool?

    public init(id: String, push: Bool? = nil, removed: Bool? = nil) {
        self.id = id
        self.push = push
        self.removed = removed
    }
}

public enum Invite {
    public static let capability = "invite"
}

/// #532: listed by the plugin only while its direct listener is listening; the probe and the race are in `Direct.swift`.
public enum Direct {
    public static let capability = "direct"
}

/// #532: listed by the plugin only while its relay offers `pushProxy`; a client on the direct path then sends its APNs
/// token in the session (`push_token`), and the plugin registers it at the relay for that device.
public enum PushProxy {
    public static let capability = "push-proxy"
}

/// Client → plugin, only over a direct session and only to a plugin listing `push-proxy` (#532); `token` is hex.
public struct PushToken: Codable, Equatable, Sendable {
    public var token: String

    public init(token: String) { self.token = token }
}

/// Plugin → client, only to a client listing `direct` (#532): where the plugin's direct listener can be reached, sent
/// right after the client's `peer_info` and again whenever its addresses change. Invalid addresses are dropped.
public struct DirectHints: Codable, Equatable, Sendable {
    public struct Lan: Codable, Equatable, Sendable {
        public var address: String
        public var prefix: Int

        public init(address: String, prefix: Int) {
            self.address = address
            self.prefix = prefix
        }
    }

    public struct Tailscale: Codable, Equatable, Sendable {
        public var address: String

        public init(address: String) { self.address = address }
    }

    public var port: Int
    public var lan: [Lan]
    public var tailscale: [Tailscale]
    public var magicDNS: String?

    public init(port: Int, lan: [Lan] = [], tailscale: [Tailscale] = [], magicDNS: String? = nil) {
        self.port = port
        self.lan = lan
        self.tailscale = tailscale
        self.magicDNS = magicDNS
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decode(Int.self, forKey: .port)
        guard (1...65535).contains(port) else {
            throw DecodingError.dataCorruptedError(forKey: .port, in: c, debugDescription: "port out of range")
        }
        lan = (try c.decodeIfPresent([Lossy<Lan>].self, forKey: .lan) ?? []).compactMap(\.value).filter {
            guard let bytes = Direct.ipBytes($0.address) else { return false }
            return (0...bytes.count * 8).contains($0.prefix)
        }
        tailscale = (try c.decodeIfPresent([Lossy<Tailscale>].self, forKey: .tailscale) ?? []).compactMap(\.value)
            .filter { Direct.ipBytes($0.address) != nil }
        magicDNS = (try? c.decodeIfPresent(String.self, forKey: .magicDNS)).flatMap { $0 }.flatMap(Direct.hostName)
    }
}

public struct PairInvite: Codable, Equatable, Sendable {
    public var link: String?
    public var webLink: String?
    public var fingerprint: String?
    public var expiresAt: Int64?
    public var error: String?

    public init() {}
}

/// The device's Live Activity, client → plugin; capability `liveActivityPush`, which the plugin lists only while its
/// relay can push. `pushToken` (hex) is the activity's ActivityKit token, absent once the activity ended. `jobs` is the
/// activity's whole content state with times in epoch milliseconds; `turns` maps the token of each running turn job to
/// its conversation, so the plugin can count that turn's steps and end it while the app is suspended.
public struct ActivityReport: Codable, Equatable, Sendable {
    public static let capability = "liveActivityPush"

    public struct Job: Codable, Equatable, Sendable {
        public var token: String
        public var kind: String
        public var state: String
        public var steps: Int?
        public var startedAt: Int64
        public var finishedAt: Int64?

        public init(token: String, kind: String, state: String, steps: Int? = nil, startedAt: Int64, finishedAt: Int64? = nil) {
            self.token = token
            self.kind = kind
            self.state = state
            self.steps = steps
            self.startedAt = startedAt
            self.finishedAt = finishedAt
        }
    }

    public var pushToken: String?
    public var jobs: [Job]
    public var turns: [String: String]

    public init(pushToken: String?, jobs: [Job] = [], turns: [String: String] = [:]) {
        self.pushToken = pushToken
        self.jobs = jobs
        self.turns = turns
    }
}

public struct CronList: Codable, Equatable, Sendable {
    public var jobs: [CronJob]?
    public var error: String?

    public init(jobs: [CronJob]? = nil, error: String? = nil) {
        self.jobs = jobs
        self.error = error
    }
}

public struct CronJob: Codable, Equatable, Sendable, Identifiable {
    public struct Delivery: Codable, Equatable, Sendable {
        public var channel: String
        public var threadId: String
    }

    public var id: String
    public var name: String
    public var enabled: Bool
    public var schedule: JSONValue
    public var scheduleText: String
    public var nextRunAt: Int64?
    public var lastRunAt: Int64?
    public var lastStatus: String?
    public var lastError: String?
    public var delivery: Delivery?

    public var convId: String? { delivery.flatMap { $0.channel == "yorozu" && WireEvent.isId($0.threadId) ? $0.threadId : nil } }
}

public struct ConvPatch: Codable, Equatable, Sendable {
    public var convId: String
    public var title: String?
    public var archived: Bool?
    public var pinned: Bool?
    public var deleted: Bool?

    public init(convId: String, title: String? = nil, archived: Bool? = nil, pinned: Bool? = nil, deleted: Bool? = nil) {
        self.convId = convId
        self.title = title
        self.archived = archived
        self.pinned = pinned
        self.deleted = deleted
    }
}

public struct ConvUpdate: Codable, Equatable, Sendable {
    public var convId: String
    public var title: String?
    public var archived: Bool?
    public var pinnedAt: Int64?
    public var deleted: Bool?

    public init(convId: String, title: String? = nil, archived: Bool? = nil, pinnedAt: Int64? = nil, deleted: Bool? = nil) {
        self.convId = convId
        self.title = title
        self.archived = archived
        self.pinnedAt = pinnedAt
        self.deleted = deleted
    }
}

extension WireEvent: Codable {
    private enum Keys: String, CodingKey { case kind, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        func data<T: Decodable>(_: T.Type) -> T? { try? c.decode(T.self, forKey: .data) }
        let ids = { (conv: String, message: String) in WireEvent.isId(conv) && WireEvent.isId(message) }
        let files = { (list: [Attachment]?) in (list ?? []).allSatisfy { WireEvent.isId($0.id) && $0.size >= 0 } }
        let answers = { (to: ReplyTo?) in to.map { WireEvent.isId($0.messageId) } ?? true }
        let part = { (id: String, index: Int, count: Int) in WireEvent.isId(id) && index >= 0 && index < count }
        switch kind {
        case "peer_info":
            if let v = data(PeerInfo.self) { self = .peerInfo(v); return }
        case "message":
            if let v = data(Message.self), ids(v.convId, v.messageId), files(v.attachments), answers(v.replyTo) { self = .message(v); return }
        case "delivered":
            if let v = data(MessageRef.self), ids(v.convId, v.messageId) { self = .delivered(v); return }
        case "run_started":
            if let v = data(MessageRef.self), ids(v.convId, v.messageId) { self = .runStarted(v); return }
        case "typing":
            if let v = data(Typing.self), WireEvent.isId(v.convId) { self = .typing(v); return }
        case "reply":
            if let v = data(Reply.self), ids(v.convId, v.messageId), files(v.attachments), answers(v.replyTo) { self = .reply(v); return }
        case "reaction":
            if let v = data(Reaction.self), ids(v.convId, v.messageId), !v.emoji.isEmpty, v.emoji.utf16.count <= Reaction.maxEmoji {
                self = .reaction(v); return
            }
        case "error":
            if let v = data(ErrorInfo.self) { self = .error(v); return }
        case "tool":
            if let v = data(Tool.self), ids(v.convId, v.messageId) { self = .tool(v); return }
        case "conv_list":
            if let v = data(ConvList.self) { self = .convList(v); return }
        case "history":
            if let v = data(History.self), WireEvent.isId(v.convId) { self = .history(v); return }
            if let v = data(HistoryRequest.self), WireEvent.isId(v.convId) { self = .historyRequest(v); return }
        case "read_cursor":
            if let v = data(ReadCursor.self), ids(v.convId, v.messageId) { self = .readCursor(v); return }
        case "conv_patch":
            if let v = data(ConvPatch.self), WireEvent.isId(v.convId) { self = .convPatch(v); return }
        case "conv_update":
            if let v = data(ConvUpdate.self), WireEvent.isId(v.convId) { self = .convUpdate(v); return }
        case "foreground":
            if let v = data(Foreground.self), v.convId.map(WireEvent.isId) ?? true { self = .foreground(v); return }
        case "cron_list":
            if let v = data(CronList.self) { self = .cronList(v); return }
        case "device_list":
            if let v = data(DeviceList.self) { self = .deviceList(v); return }
        case "device_patch":
            if let v = data(DevicePatch.self), !v.id.isEmpty { self = .devicePatch(v); return }
        case "pair_invite":
            if let v = data(PairInvite.self) { self = .pairInvite(v); return }
        case "upload":
            if let v = data(Upload.self), part(v.attachmentId, v.index, v.count), v.sha256.map(FileDigest.isSHA256) ?? true {
                self = .upload(v); return
            }
        case "upload_ack":
            if let v = data(UploadAck.self), part(v.attachmentId, v.index, v.index + 1) { self = .uploadAck(v); return }
        case "upload_status":
            if let v = data(UploadStatus.self), part(v.attachmentId, 0, v.count), v.size >= 0, FileDigest.isSHA256(v.sha256) {
                self = .uploadStatus(v); return
            }
        case "upload_state":
            if let v = data(UploadState.self), WireEvent.isId(v.attachmentId) { self = .uploadState(v); return }
        case "download":
            if let v = data(Download.self), part(v.attachmentId, v.index, v.index + 1) { self = .download(v); return }
        case "chunk":
            if let v = data(Chunk.self), part(v.attachmentId, v.index, v.count) { self = .chunk(v); return }
        case "live_activity":
            if let v = data(ActivityReport.self) { self = .liveActivity(v); return }
        case "push_token":
            if let v = data(PushToken.self) { self = .pushToken(v); return }
        case "direct_hints":
            if let v = data(DirectHints.self) { self = .directHints(v); return }
        default:
            break
        }
        self = .unknown(kind: kind, data: data(JSONValue.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .peerInfo(let v): try c.encode(v, forKey: .data)
        case .message(let v): try c.encode(v, forKey: .data)
        case .delivered(let v), .runStarted(let v): try c.encode(v, forKey: .data)
        case .typing(let v): try c.encode(v, forKey: .data)
        case .reply(let v): try c.encode(v, forKey: .data)
        case .reaction(let v): try c.encode(v, forKey: .data)
        case .error(let v): try c.encode(v, forKey: .data)
        case .tool(let v): try c.encode(v, forKey: .data)
        case .convList(let v): try c.encode(v, forKey: .data)
        case .historyRequest(let v): try c.encode(v, forKey: .data)
        case .history(let v): try c.encode(v, forKey: .data)
        case .readCursor(let v): try c.encode(v, forKey: .data)
        case .foreground(let v): try c.encode(v, forKey: .data)
        case .convPatch(let v): try c.encode(v, forKey: .data)
        case .convUpdate(let v): try c.encode(v, forKey: .data)
        case .cronList(let v): try c.encode(v, forKey: .data)
        case .deviceList(let v): try c.encode(v, forKey: .data)
        case .devicePatch(let v): try c.encode(v, forKey: .data)
        case .pairInvite(let v): try c.encode(v, forKey: .data)
        case .upload(let v): try c.encode(v, forKey: .data)
        case .uploadAck(let v): try c.encode(v, forKey: .data)
        case .uploadStatus(let v): try c.encode(v, forKey: .data)
        case .uploadState(let v): try c.encode(v, forKey: .data)
        case .download(let v): try c.encode(v, forKey: .data)
        case .chunk(let v): try c.encode(v, forKey: .data)
        case .liveActivity(let v): try c.encode(v, forKey: .data)
        case .pushToken(let v): try c.encode(v, forKey: .data)
        case .directHints(let v): try c.encode(v, forKey: .data)
        case .unknown(_, let v): try c.encodeIfPresent(v, forKey: .data)
        }
    }
}
