import Foundation

public enum V3Event: Equatable, Sendable {
    case peerInfo(V3PeerInfo)
    case message(V3Message)
    case delivered(V3MessageRef)
    case runStarted(V3MessageRef)
    case typing(V3Typing)
    case reply(V3Reply)
    case error(V3ErrorInfo)
    case tool(V3Tool)
    case convList(V3ConvList)
    case historyRequest(V3HistoryRequest)
    case history(V3History)
    case readCursor(V3ReadCursor)
    case foreground(V3Foreground)
    case convPatch(V3ConvPatch)
    case convUpdate(V3ConvUpdate)
    case cronList(V3CronList)
    case deviceList(V3DeviceList)
    case devicePatch(V3DevicePatch)
    case pairInvite(V3PairInvite)
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
        case .convPatch: "conv_patch"
        case .convUpdate: "conv_update"
        case .cronList: "cron_list"
        case .deviceList: "device_list"
        case .devicePatch: "device_patch"
        case .pairInvite: "pair_invite"
        case .upload: "upload"
        case .uploadAck: "upload_ack"
        case .download: "download"
        case .chunk: "chunk"
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

public struct V3PeerInfo: Codable, Equatable, Sendable {
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
        protocolMin: Int = V3PeerInfo.protocolVersion, protocolMax: Int = V3PeerInfo.protocolVersion,
        mediaMaxBytes: Int? = nil) {
        self.protocolMin = protocolMin
        self.protocolMax = protocolMax
        self.app = app
        self.name = name
        self.capabilities = capabilities
        self.mediaMaxBytes = mediaMaxBytes
    }

    public func negotiate(with peer: V3PeerInfo) -> Int? {
        let version = min(protocolMax, peer.protocolMax)
        return version >= max(protocolMin, peer.protocolMin) ? version : nil
    }
}

public struct V3Message: Codable, Equatable, Sendable {
    public var convId: String
    public var messageId: String
    public var text: String
    public var attachments: [V3Attachment]?

    public init(convId: String, messageId: String, text: String, attachments: [V3Attachment]? = nil) {
        self.convId = convId
        self.messageId = messageId
        self.text = text
        self.attachments = attachments
    }
}

public struct V3MessageRef: Codable, Equatable, Sendable {
    public var convId: String
    public var messageId: String

    public init(convId: String, messageId: String) {
        self.convId = convId
        self.messageId = messageId
    }
}

public struct V3Typing: Codable, Equatable, Sendable {
    public var convId: String
    public var active: Bool

    public init(convId: String, active: Bool) {
        self.convId = convId
        self.active = active
    }
}

public struct V3Reply: Codable, Equatable, Sendable {
    public var convId: String
    public var messageId: String
    public var text: String
    public var ts: Int64
    public var attachments: [V3Attachment]?

    public init(convId: String, messageId: String, text: String, ts: Int64, attachments: [V3Attachment]? = nil) {
        self.convId = convId
        self.messageId = messageId
        self.text = text
        self.ts = ts
        self.attachments = attachments
    }
}

public struct V3ErrorInfo: Codable, Equatable, Sendable {
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

public struct V3Attachment: Codable, Equatable, Sendable, Identifiable {
    public static let capability = "attachments"
    public static let chunkBytes = 160 * 1024
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

public struct V3Download: Codable, Equatable, Sendable {
    public var attachmentId: String
    public var index: Int

    public init(attachmentId: String, index: Int) {
        self.attachmentId = attachmentId
        self.index = index
    }
}

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

public struct V3Tool: Codable, Equatable, Sendable {
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

public struct V3ConvList: Codable, Equatable, Sendable {
    public var conversations: [V3ConvSummary]?

    public init(conversations: [V3ConvSummary]? = nil) { self.conversations = conversations }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        conversations = try c.decodeIfPresent([Lossy<V3ConvSummary>].self, forKey: .conversations)?
            .compactMap(\.value).filter { V3Event.isId($0.convId) }
    }
}

public struct V3ConvSummary: Codable, Equatable, Sendable {
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
        items = try c.decode([Lossy<V3HistoryItem>].self, forKey: .items).compactMap(\.value)
            .filter { V3Event.isId($0.id) }
        more = try c.decode(Bool.self, forKey: .more)
        rev = try c.decode(Int.self, forKey: .rev)
    }
}

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
    public var ts: Int64
    public var text: String?
    public var tools: [Call]?
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

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

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

public struct V3Foreground: Codable, Equatable, Sendable {
    public var convId: String?
    public var active: Bool?

    public init(convId: String?, active: Bool? = nil) {
        self.convId = convId
        self.active = active
    }
}

public enum V3Devices {
    public static let capability = "devices"
}

public struct V3DeviceInfo: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String?
    public var pairedAt: Int64
    public var push: Bool
    public var current: Bool
}

public struct V3DeviceList: Codable, Equatable, Sendable {
    public var devices: [V3DeviceInfo]?
    public var error: String?

    public init(devices: [V3DeviceInfo]? = nil, error: String? = nil) {
        self.devices = devices
        self.error = error
    }
}

public struct V3DevicePatch: Codable, Equatable, Sendable {
    public var id: String
    public var push: Bool?
    public var removed: Bool?

    public init(id: String, push: Bool? = nil, removed: Bool? = nil) {
        self.id = id
        self.push = push
        self.removed = removed
    }
}

public enum V3Invite {
    public static let capability = "invite"
}

public struct V3PairInvite: Codable, Equatable, Sendable {
    public var link: String?
    public var webLink: String?
    public var fingerprint: String?
    public var expiresAt: Int64?
    public var error: String?

    public init() {}
}

public struct V3CronList: Codable, Equatable, Sendable {
    public var jobs: [V3CronJob]?
    public var error: String?

    public init(jobs: [V3CronJob]? = nil, error: String? = nil) {
        self.jobs = jobs
        self.error = error
    }
}

public struct V3CronJob: Codable, Equatable, Sendable, Identifiable {
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

    public var convId: String? { delivery.flatMap { $0.channel == "yorozu" && V3Event.isId($0.threadId) ? $0.threadId : nil } }
}

public struct V3ConvPatch: Codable, Equatable, Sendable {
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

public struct V3ConvUpdate: Codable, Equatable, Sendable {
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
        case "conv_patch":
            if let v = data(V3ConvPatch.self), V3Event.isId(v.convId) { self = .convPatch(v); return }
        case "conv_update":
            if let v = data(V3ConvUpdate.self), V3Event.isId(v.convId) { self = .convUpdate(v); return }
        case "foreground":
            if let v = data(V3Foreground.self), v.convId.map(V3Event.isId) ?? true { self = .foreground(v); return }
        case "cron_list":
            if let v = data(V3CronList.self) { self = .cronList(v); return }
        case "device_list":
            if let v = data(V3DeviceList.self) { self = .deviceList(v); return }
        case "device_patch":
            if let v = data(V3DevicePatch.self), !v.id.isEmpty { self = .devicePatch(v); return }
        case "pair_invite":
            if let v = data(V3PairInvite.self) { self = .pairInvite(v); return }
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
        case .convPatch(let v): try c.encode(v, forKey: .data)
        case .convUpdate(let v): try c.encode(v, forKey: .data)
        case .cronList(let v): try c.encode(v, forKey: .data)
        case .deviceList(let v): try c.encode(v, forKey: .data)
        case .devicePatch(let v): try c.encode(v, forKey: .data)
        case .pairInvite(let v): try c.encode(v, forKey: .data)
        case .upload(let v): try c.encode(v, forKey: .data)
        case .uploadAck(let v): try c.encode(v, forKey: .data)
        case .download(let v): try c.encode(v, forKey: .data)
        case .chunk(let v): try c.encode(v, forKey: .data)
        case .unknown(_, let v): try c.encodeIfPresent(v, forKey: .data)
        }
    }
}
