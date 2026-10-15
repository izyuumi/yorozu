import Foundation

/// The plaintext of every v3 transport box: `{"kind": …, "data": {…}}` (docs/ios-relay-contract.md, "Envelope").
/// An unknown kind, or a known kind whose data does not decode, is `.unknown` and ignored, so later kinds and
/// optional fields never break an older peer. Mirrors plugins/openclaw-yorozu/src/envelope.ts.
public enum V3Event: Equatable, Sendable {
    case peerInfo(V3PeerInfo)
    case message(V3Message)
    case delivered(V3MessageRef)
    case runStarted(V3MessageRef)
    case typing(V3Typing)
    case reply(V3Reply)
    case error(V3ErrorInfo)
    case tool(V3Tool)
    /// `conv_list`: `conversations` nil is the client's request, otherwise the plugin's answer.
    case convList(V3ConvList)
    /// `history`, client -> plugin: one page of a conversation.
    case historyRequest(V3HistoryRequest)
    /// `history`, plugin -> the asking client: that page.
    case history(V3History)
    case readCursor(V3ReadCursor)
    case foreground(V3Foreground)
    case cronList(V3CronList)
    case upload(V3Upload)
    case uploadAck(V3UploadAck)
    case download(V3Download)
    case chunk(V3Chunk)
    case unknown(kind: String, data: JSONValue?)

    public var kind: String {
        switch self {
        case .peerInfo: "peer_info"
        case .message: "message"
        case .delivered: "delivered"
        case .runStarted: "run_started"
        case .typing: "typing"
        case .reply: "reply"
        case .error: "error"
        case .tool: "tool"
        case .convList: "conv_list"
        case .historyRequest, .history: "history"
        case .readCursor: "read_cursor"
        case .foreground: "foreground"
        case .cronList: "cron_list"
        case .upload: "upload"
        case .uploadAck: "upload_ack"
        case .download: "download"
        case .chunk: "chunk"
        case .unknown(let kind, _): kind
        }
    }

    /// Lowercase UUID, the only spelling of a `convId` or `messageId`: OpenClaw lowercases session keys.
    public static func isId(_ value: String) -> Bool {
        value.utf8.count == 36 && value.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$",
            options: .regularExpression) != nil
    }

    /// A fresh `convId` or `messageId`.
    public static func newId() -> String { UUID().uuidString.lowercased() }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public struct V3PeerInfo: Codable, Equatable, Sendable {
    public static let protocolVersion = 3

    public var protocolMin: Int
    public var protocolMax: Int
    /// The sender's app or plugin version, diagnostic only.
    public var app: String
    /// Client: the device model ("iPhone 17 Pro"). Host: the Mac's name.
    public var name: String?
    /// Optional features this side speaks; a later kind is sent only to a peer that lists its capability.
    public var capabilities: [String]
    /// Plugin: the largest attachment it takes or sends, in bytes (`mediaMaxMb`, #430).
    public var mediaMaxBytes: Int?

    public init(app: String, name: String? = nil, capabilities: [String] = [],
        protocolMin: Int = V3PeerInfo.protocolVersion, protocolMax: Int = V3PeerInfo.protocolVersion,
        mediaMaxBytes: Int? = nil) {
        self.protocolMin = protocolMin
        self.protocolMax = protocolMax
        self.app = app
        self.name = name
        self.capabilities = capabilities
        self.mediaMaxBytes = mediaMaxBytes
    }

    /// The highest protocol both ranges hold, or nil: the peers cannot talk ("update required").
    public func negotiate(with peer: V3PeerInfo) -> Int? {
        let version = min(protocolMax, peer.protocolMax)
        return version >= max(protocolMin, peer.protocolMin) ? version : nil
    }
}

/// Client -> plugin: a user message for one conversation.
public struct V3Message: Codable, Equatable, Sendable {
    public var convId: String
    /// Made by the client; the plugin answers `delivered` and `run_started` with it and drops a repeat.
    public var messageId: String
    public var text: String
    /// Files uploaded (`upload`, every one `done`) before this message went (#430).
    public var attachments: [V3Attachment]?

    public init(convId: String, messageId: String, text: String, attachments: [V3Attachment]? = nil) {
        self.convId = convId
        self.messageId = messageId
        self.text = text
        self.attachments = attachments
    }
}

/// Plugin -> clients: `delivered` (received and decrypted) or `run_started` (the agent run began: read).
public struct V3MessageRef: Codable, Equatable, Sendable {
    public var convId: String
    public var messageId: String

    public init(convId: String, messageId: String) {
        self.convId = convId
        self.messageId = messageId
    }
}

/// Plugin -> clients: the agent is (still) working on a conversation, or has stopped.
public struct V3Typing: Codable, Equatable, Sendable {
    public var convId: String
    public var active: Bool

    public init(convId: String, active: Bool) {
        self.convId = convId
        self.active = active
    }
}

/// Plugin -> clients: one whole reply message (one chunk of a long reply).
public struct V3Reply: Codable, Equatable, Sendable {
    public var convId: String
    /// Made by the plugin.
    public var messageId: String
    public var text: String
    /// Epoch milliseconds, plugin clock.
    public var ts: Int64
    /// Files the agent sent with this reply, announced only: each device downloads one on request (#430).
    public var attachments: [V3Attachment]?

    public init(convId: String, messageId: String, text: String, ts: Int64, attachments: [V3Attachment]? = nil) {
        self.convId = convId
        self.messageId = messageId
        self.text = text
        self.ts = ts
        self.attachments = attachments
    }
}

/// Either way: something the sender could not do. `code` is machine-readable; `message` is English for logs.
public struct V3ErrorInfo: Codable, Equatable, Sendable {
    public var code: String
    public var message: String
    public var convId: String?
    public var messageId: String?
    /// The transfer it is about: `too_large` for an upload, `not_found` for a download (#430).
    public var attachmentId: String?

    public init(code: String, message: String, convId: String? = nil, messageId: String? = nil, attachmentId: String? = nil) {
        self.code = code
        self.message = message
        self.convId = convId
        self.messageId = messageId
        self.attachmentId = attachmentId
    }
}

// MARK: Attachments (#430)

/// A file in a `message` or `reply`. `id` (a lowercase UUID, made by the side that has the bytes) names its transfer.
public struct V3Attachment: Codable, Equatable, Sendable, Identifiable {
    /// Peers that list this in `capabilities` speak the attachment kinds and fields.
    public static let capability = "attachments"
    /// Raw bytes per `upload` or `chunk`: a sealed box of one stays far under the relay's 1 MiB frame.
    public static let chunkBytes = 160 * 1024
    /// OpenClaw's `mediaMaxMb` default, until the plugin's `peer_info` says otherwise.
    public static let defaultMaxBytes = 8 * 1024 * 1024

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
}

/// Client -> plugin: chunk `index` of `count` of a file this client sends; `data` is base64.
public struct V3Upload: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var name: String
    public var mime: String
    public var size: Int
    public var index: Int
    public var count: Int
    public var data: String

    public init(attachmentId: String, name: String, mime: String, size: Int, index: Int, count: Int, data: String) {
        self.attachmentId = attachmentId
        self.name = name
        self.mime = mime
        self.size = size
        self.index = index
        self.count = count
        self.data = data
    }
}

/// Plugin -> the uploading client: chunk `index` arrived; `done` once the whole file is stored.
public struct V3UploadAck: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var index: Int
    public var done: Bool

    public init(attachmentId: String, index: Int, done: Bool) {
        self.attachmentId = attachmentId
        self.index = index
        self.done = done
    }
}

/// Client -> plugin: send chunk `index` of an attachment.
public struct V3Download: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var index: Int

    public init(attachmentId: String, index: Int) {
        self.attachmentId = attachmentId
        self.index = index
    }
}

/// Plugin -> the requesting client: chunk `index` of `count`; `data` is base64.
public struct V3Chunk: Codable, Equatable, Sendable {
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

/// Plugin -> clients: one tool call of the run answering `messageId`, for a collapsed row. Updates of one call share
/// `callId` (OpenClaw's tool call id, not a UUID); the last status wins.
public struct V3Tool: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case running, done, failed }

    public var convId: String
    /// The user message whose run made the call.
    public var messageId: String
    public var callId: String
    /// The tool's name, as the agent calls it ("exec", "web_search").
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

/// `conv_list`. Asked with `conversations` nil; answered with the owner's Yorozu conversations, newest first.
public struct V3ConvList: Codable, Equatable, Sendable {
    public var conversations: [V3ConvSummary]?

    public init(conversations: [V3ConvSummary]? = nil) { self.conversations = conversations }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One malformed row drops that row, not the list.
        conversations = try c.decodeIfPresent([Lossy<V3ConvSummary>].self, forKey: .conversations)?
            .compactMap(\.value).filter { V3Event.isId($0.convId) }
    }
}

public struct V3ConvSummary: Codable, Equatable, Sendable {
    public var convId: String
    /// Epoch ms of the session's last change.
    public var updatedAt: Int64
    /// The transcript's newest event seq: a client whose last page carried this `rev` has nothing newer to fetch.
    public var rev: Int

    public init(convId: String, updatedAt: Int64, rev: Int) {
        self.convId = convId
        self.updatedAt = updatedAt
        self.rev = rev
    }
}

/// Client -> plugin: one page of a conversation's transcript. `before`/`after` are item seqs; neither: the newest page.
public struct V3HistoryRequest: Codable, Equatable, Sendable {
    public var convId: String
    public var before: Int?
    public var after: Int?

    public init(convId: String, before: Int? = nil, after: Int? = nil) {
        self.convId = convId
        self.before = before
        self.after = after
    }
}

/// Plugin -> the asking client: the request's fields again, the page oldest first, and whether another page lies
/// further the same way (`more`).
public struct V3History: Codable, Equatable, Sendable {
    public var convId: String
    public var before: Int?
    public var after: Int?
    public var items: [V3HistoryItem]
    public var more: Bool
    public var rev: Int

    public init(convId: String, before: Int? = nil, after: Int? = nil, items: [V3HistoryItem], more: Bool, rev: Int) {
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
        // An item of a kind this client does not know, or a malformed one, is skipped.
        items = try c.decode([Lossy<V3HistoryItem>].self, forKey: .items).compactMap(\.value)
            .filter { V3Event.isId($0.id) }
        more = try c.decode(Bool.self, forKey: .more)
        rev = try c.decode(Int.self, forKey: .rev)
    }
}

/// One transcript item. Items of one transcript event share its `seq`. `id`: the client's `messageId` for a user
/// message, the user message's for its run's `tools` row, the transcript's (or one derived from it) otherwise.
public struct V3HistoryItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case user, agent, tools, reset }
    public struct Call: Codable, Equatable, Sendable {
        public var callId: String
        public var name: String
        public var status: V3Tool.Status
    }

    public var kind: Kind
    public var id: String
    public var seq: Int
    /// Epoch ms, Gateway clock.
    public var ts: Int64
    public var text: String?
    public var tools: [Call]?
    /// `user` and `agent`: the files the live `message` or `reply` carried, that the plugin still holds (#430).
    public var attachments: [V3Attachment]?

    public init(kind: Kind, id: String, seq: Int, ts: Int64, text: String? = nil, tools: [Call]? = nil,
        attachments: [V3Attachment]? = nil) {
        self.kind = kind
        self.id = id
        self.seq = seq
        self.ts = ts
        self.text = text
        self.tools = tools
        self.attachments = attachments
    }
}

/// Decodes to nil instead of failing the whole array.
private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Both ways: a conversation's read state, the same on every device (#429). Replies up to and including the one at `ts`
/// (the reply's own plugin-clock `ts`; `messageId` is that reply) are read, later ones unread. `unread` is Mark as
/// Unread: the conversation counts as unread whatever the cursor says, until a read clears it. The plugin keeps the
/// cursor forward-only, sends the merged one to every device, and every stored one to a device whose session opens.
public struct V3ReadCursor: Codable, Equatable, Sendable {
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

/// Client -> plugin: the conversation on this device's screen while the app is in the foreground, or nil (#431). The
/// plugin sends no push for a reply in it to this device while its session lasts.
public struct V3Foreground: Codable, Equatable, Sendable {
    public var convId: String?

    public init(convId: String?) { self.convId = convId }
}

/// The Crons tab (#432). Client -> plugin: empty, a request. Plugin -> that client: `jobs`, or `error` when the
/// plugin cannot read the cron store.
public struct V3CronList: Codable, Equatable, Sendable {
    public var jobs: [V3CronJob]?
    public var error: String?

    public init(jobs: [V3CronJob]? = nil, error: String? = nil) {
        self.jobs = jobs
        self.error = error
    }
}

/// One cron job of the configured agent. Times are epoch milliseconds.
public struct V3CronJob: Codable, Equatable, Sendable, Identifiable {
    public struct Delivery: Codable, Equatable, Sendable {
        /// Always "yorozu": the plugin names only deliveries into a Yorozu conversation.
        public var channel: String
        /// The conversation's `convId`.
        public var threadId: String
    }

    public var id: String
    public var name: String
    public var enabled: Bool
    /// OpenClaw's schedule object as stored (`kind` plus its fields).
    public var schedule: JSONValue
    /// The plugin's English wording of `schedule`.
    public var scheduleText: String
    public var nextRunAt: Int64?
    public var lastRunAt: Int64?
    /// "ok", "error" or "skipped".
    public var lastStatus: String?
    public var lastError: String?
    public var delivery: Delivery?

    /// The conversation the job delivers into, if it is a well-formed Yorozu one.
    public var convId: String? { delivery.flatMap { $0.channel == "yorozu" && V3Event.isId($0.threadId) ? $0.threadId : nil } }
}

extension V3Event: Codable {
    private enum Keys: String, CodingKey { case kind, data }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        func data<T: Decodable>(_: T.Type) -> T? { try? c.decode(T.self, forKey: .data) }
        let ids = { (conv: String, message: String) in V3Event.isId(conv) && V3Event.isId(message) }
        let files = { (list: [V3Attachment]?) in (list ?? []).allSatisfy { V3Event.isId($0.id) && $0.size >= 0 } }
        let part = { (id: String, index: Int, count: Int) in V3Event.isId(id) && index >= 0 && index < count }
        switch kind {
        case "peer_info":
            if let v = data(V3PeerInfo.self) { self = .peerInfo(v); return }
        case "message":
            if let v = data(V3Message.self), ids(v.convId, v.messageId), files(v.attachments) { self = .message(v); return }
        case "delivered":
            if let v = data(V3MessageRef.self), ids(v.convId, v.messageId) { self = .delivered(v); return }
        case "run_started":
            if let v = data(V3MessageRef.self), ids(v.convId, v.messageId) { self = .runStarted(v); return }
        case "typing":
            if let v = data(V3Typing.self), V3Event.isId(v.convId) { self = .typing(v); return }
        case "reply":
            if let v = data(V3Reply.self), ids(v.convId, v.messageId), files(v.attachments) { self = .reply(v); return }
        case "error":
            if let v = data(V3ErrorInfo.self) { self = .error(v); return }
        case "tool":
            if let v = data(V3Tool.self), ids(v.convId, v.messageId) { self = .tool(v); return }
        case "conv_list":
            if let v = data(V3ConvList.self) { self = .convList(v); return }
        case "history":
            if let v = data(V3History.self), V3Event.isId(v.convId) { self = .history(v); return }
            if let v = data(V3HistoryRequest.self), V3Event.isId(v.convId) { self = .historyRequest(v); return }
        case "read_cursor":
            if let v = data(V3ReadCursor.self), ids(v.convId, v.messageId) { self = .readCursor(v); return }
        case "foreground":
            if let v = data(V3Foreground.self), v.convId.map(V3Event.isId) ?? true { self = .foreground(v); return }
        case "cron_list":
            if let v = data(V3CronList.self) { self = .cronList(v); return }
        case "upload":
            if let v = data(V3Upload.self), part(v.attachmentId, v.index, v.count) { self = .upload(v); return }
        case "upload_ack":
            if let v = data(V3UploadAck.self), part(v.attachmentId, v.index, v.index + 1) { self = .uploadAck(v); return }
        case "download":
            if let v = data(V3Download.self), part(v.attachmentId, v.index, v.index + 1) { self = .download(v); return }
        case "chunk":
            if let v = data(V3Chunk.self), part(v.attachmentId, v.index, v.count) { self = .chunk(v); return }
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
        case .error(let v): try c.encode(v, forKey: .data)
        case .tool(let v): try c.encode(v, forKey: .data)
        case .convList(let v): try c.encode(v, forKey: .data)
        case .historyRequest(let v): try c.encode(v, forKey: .data)
        case .history(let v): try c.encode(v, forKey: .data)
        case .readCursor(let v): try c.encode(v, forKey: .data)
        case .foreground(let v): try c.encode(v, forKey: .data)
        case .cronList(let v): try c.encode(v, forKey: .data)
        case .upload(let v): try c.encode(v, forKey: .data)
        case .uploadAck(let v): try c.encode(v, forKey: .data)
        case .download(let v): try c.encode(v, forKey: .data)
        case .chunk(let v): try c.encode(v, forKey: .data)
        case .unknown(_, let v): try c.encodeIfPresent(v, forKey: .data)
        }
    }
}
