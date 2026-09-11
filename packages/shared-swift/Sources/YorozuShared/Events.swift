import Foundation

/// Wire events exchanged between Mac, phone and relay. See docs/spec-v1.html sections 3, 7, 8.
///
/// JSON shape is `{ id, threadId, ts, agentId, parentAgentId?, kind, data }`, identical to
/// `YorozuEvent` in packages/shared/src/events.ts.
public struct YorozuEvent: Codable, Equatable, Sendable {
    public var id: String
    public var threadId: String
    /// Epoch milliseconds.
    public var ts: Int
    public var agentId: String
    /// Set when the emitting agent was delegated to by another.
    public var parentAgentId: String?
    public var payload: Payload

    public init(
        id: String,
        threadId: String,
        ts: Int,
        agentId: String,
        parentAgentId: String? = nil,
        payload: Payload
    ) {
        self.id = id
        self.threadId = threadId
        self.ts = ts
        self.agentId = agentId
        self.parentAgentId = parentAgentId
        self.payload = payload
    }

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case message, thought
        case toolCall = "tool_call"
        case toolResult = "tool_result"
        case approvalCard = "approval_card"
        case approvalAnswer = "approval_answer"
        case threadCreate = "thread_create"
        case threadList = "thread_list"
        case threadArchive = "thread_archive"
        case interrupt
        case syncRequest = "sync_request"
        case syncDelta = "sync_delta"
    }

    public enum Payload: Equatable, Sendable {
        case message(MessageData)
        case thought(ThoughtData)
        case toolCall(ToolCallData)
        case toolResult(ToolResultData)
        case approvalCard(ApprovalCardData)
        case approvalAnswer(ApprovalAnswerData)
        case threadCreate(ThreadCreateData)
        case threadList(ThreadListData)
        case threadArchive(ThreadArchiveData)
        case interrupt(InterruptData)
        case syncRequest(SyncRequestData)
        case syncDelta(SyncDeltaData)

        public var kind: Kind {
            switch self {
            case .message: .message
            case .thought: .thought
            case .toolCall: .toolCall
            case .toolResult: .toolResult
            case .approvalCard: .approvalCard
            case .approvalAnswer: .approvalAnswer
            case .threadCreate: .threadCreate
            case .threadList: .threadList
            case .threadArchive: .threadArchive
            case .interrupt: .interrupt
            case .syncRequest: .syncRequest
            case .syncDelta: .syncDelta
            }
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, threadId, ts, agentId, parentAgentId, kind, data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        threadId = try c.decode(String.self, forKey: .threadId)
        ts = try c.decode(Int.self, forKey: .ts)
        agentId = try c.decode(String.self, forKey: .agentId)
        parentAgentId = try c.decodeIfPresent(String.self, forKey: .parentAgentId)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .message: payload = .message(try c.decode(MessageData.self, forKey: .data))
        case .thought: payload = .thought(try c.decode(ThoughtData.self, forKey: .data))
        case .toolCall: payload = .toolCall(try c.decode(ToolCallData.self, forKey: .data))
        case .toolResult: payload = .toolResult(try c.decode(ToolResultData.self, forKey: .data))
        case .approvalCard: payload = .approvalCard(try c.decode(ApprovalCardData.self, forKey: .data))
        case .approvalAnswer: payload = .approvalAnswer(try c.decode(ApprovalAnswerData.self, forKey: .data))
        case .threadCreate: payload = .threadCreate(try c.decode(ThreadCreateData.self, forKey: .data))
        case .threadList: payload = .threadList(try c.decode(ThreadListData.self, forKey: .data))
        case .threadArchive: payload = .threadArchive(try c.decode(ThreadArchiveData.self, forKey: .data))
        case .interrupt: payload = .interrupt(try c.decode(InterruptData.self, forKey: .data))
        case .syncRequest: payload = .syncRequest(try c.decode(SyncRequestData.self, forKey: .data))
        case .syncDelta: payload = .syncDelta(try c.decode(SyncDeltaData.self, forKey: .data))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(threadId, forKey: .threadId)
        try c.encode(ts, forKey: .ts)
        try c.encode(agentId, forKey: .agentId)
        try c.encodeIfPresent(parentAgentId, forKey: .parentAgentId)
        try c.encode(payload.kind, forKey: .kind)
        switch payload {
        case .message(let d): try c.encode(d, forKey: .data)
        case .thought(let d): try c.encode(d, forKey: .data)
        case .toolCall(let d): try c.encode(d, forKey: .data)
        case .toolResult(let d): try c.encode(d, forKey: .data)
        case .approvalCard(let d): try c.encode(d, forKey: .data)
        case .approvalAnswer(let d): try c.encode(d, forKey: .data)
        case .threadCreate(let d): try c.encode(d, forKey: .data)
        case .threadList(let d): try c.encode(d, forKey: .data)
        case .threadArchive(let d): try c.encode(d, forKey: .data)
        case .interrupt(let d): try c.encode(d, forKey: .data)
        case .syncRequest(let d): try c.encode(d, forKey: .data)
        case .syncDelta(let d): try c.encode(d, forKey: .data)
        }
    }
}

public struct MessageData: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case user, agent }
    public var role: Role
    public var text: String
    /// Set on the last message a delegated agent emits, so the phone's inline card for that
    /// delegation stops spinning. A flag rather than a kind of its own: the final message is
    /// already the thing that ends a delegation.
    public var done: Bool?
    public init(role: Role, text: String, done: Bool? = nil) {
        self.role = role
        self.text = text
        self.done = done
    }
}

public struct ThoughtData: Codable, Equatable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

public struct ToolCallData: Codable, Equatable, Sendable {
    public var callId: String
    public var name: String
    public var args: [String: JSONValue]
    public init(callId: String, name: String, args: [String: JSONValue]) {
        self.callId = callId
        self.name = name
        self.args = args
    }
}

public struct ToolResultData: Codable, Equatable, Sendable {
    public var callId: String
    public var ok: Bool
    public var output: String
    public init(callId: String, ok: Bool, output: String) {
        self.callId = callId
        self.ok = ok
        self.output = output
    }
}

/// Pending external action awaiting a Yes / No / Never / Discuss answer.
public struct ApprovalCardData: Codable, Equatable, Sendable {
    public var actionId: String
    /// e.g. "send-message", "purchase", "delete-file".
    public var actionClass: String
    public var target: String
    public var amount: Double?
    public init(actionId: String, actionClass: String, target: String, amount: Double? = nil) {
        self.actionId = actionId
        self.actionClass = actionClass
        self.target = target
        self.amount = amount
    }
}

public struct ApprovalAnswerData: Codable, Equatable, Sendable {
    public enum Answer: String, Codable, Sendable { case yes, no, never, discuss }
    public var actionId: String
    public var answer: Answer
    public init(actionId: String, answer: Answer) {
        self.actionId = actionId
        self.answer = answer
    }
}

public struct ThreadCreateData: Codable, Equatable, Sendable {
    public var title: String?
    public init(title: String? = nil) { self.title = title }
}

public struct ThreadSummary: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var archived: Bool
    public var pinned: Bool
    public init(id: String, title: String, archived: Bool, pinned: Bool) {
        self.id = id
        self.title = title
        self.archived = archived
        self.pinned = pinned
    }
}

public struct ThreadListData: Codable, Equatable, Sendable {
    public var threads: [ThreadSummary]
    public init(threads: [ThreadSummary]) { self.threads = threads }
}

/// Archives `threadId` from the base fields; carries nothing of its own.
public struct ThreadArchiveData: Codable, Equatable, Sendable {
    public init() {}
}

/// The user pressed stop: cancel the turn running in `threadId` and every agent it
/// delegated to. Carries nothing of its own.
public struct InterruptData: Codable, Equatable, Sendable {
    public init() {}
}

/// Last event id the device already holds, per thread.
public struct SyncRequestData: Codable, Equatable, Sendable {
    public var lastSeen: [String: String]
    public init(lastSeen: [String: String]) { self.lastSeen = lastSeen }
}

public struct SyncDeltaData: Codable, Equatable, Sendable {
    public var events: [YorozuEvent]
    public init(events: [YorozuEvent]) { self.events = events }
}

/// Arbitrary JSON, for tool arguments the schema cannot know ahead of time.
public enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

/// Payload carried by a pairing QR code.
public struct QrPayload: Codable, Equatable, Sendable {
    public var v: Int
    public var relayUrl: String
    /// Mac X25519 public key, base64url, 32 raw bytes. Used for the session key agreement.
    public var macPubkey: String
    /// One-time relay join token.
    public var token: String
    /// Relay room to join: base64url sha256 of the Mac's Ed25519 relay key, which is a
    /// different key from `macPubkey` and so cannot be derived from it.
    public var roomId: String?

    public init(v: Int = 1, relayUrl: String, macPubkey: String, token: String, roomId: String? = nil) {
        self.v = v
        self.relayUrl = relayUrl
        self.macPubkey = macPubkey
        self.token = token
        self.roomId = roomId
    }

    public func encoded() throws -> String {
        String(decoding: try JSONEncoder().encode(self), as: UTF8.self)
    }

    /// Parses an untrusted QR string. Throws on anything that is not a v1 payload.
    public static func decode(_ text: String) throws -> QrPayload {
        let payload = try JSONDecoder().decode(QrPayload.self, from: Data(text.utf8))
        guard payload.v == 1 else {
            throw YorozuCrypto.CryptoError.malformed("not a Yorozu v1 QR payload")
        }
        return payload
    }
}
