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
        case threadRename = "thread_rename"
        case threadPin = "thread_pin"
        case interrupt
        case syncRequest = "sync_request"
        case syncDelta = "sync_delta"
        case deviceList = "device_list"
        case deviceRemove = "device_remove"
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
        case threadRename(ThreadRenameData)
        case threadPin(ThreadPinData)
        case interrupt(InterruptData)
        case syncRequest(SyncRequestData)
        case syncDelta(SyncDeltaData)
        case deviceList(DeviceListData)
        case deviceRemove(DeviceRemoveData)

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
            case .threadRename: .threadRename
            case .threadPin: .threadPin
            case .interrupt: .interrupt
            case .syncRequest: .syncRequest
            case .syncDelta: .syncDelta
            case .deviceList: .deviceList
            case .deviceRemove: .deviceRemove
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
        case .threadRename: payload = .threadRename(try c.decode(ThreadRenameData.self, forKey: .data))
        case .threadPin: payload = .threadPin(try c.decode(ThreadPinData.self, forKey: .data))
        case .interrupt: payload = .interrupt(try c.decode(InterruptData.self, forKey: .data))
        case .syncRequest: payload = .syncRequest(try c.decode(SyncRequestData.self, forKey: .data))
        case .syncDelta: payload = .syncDelta(try c.decode(SyncDeltaData.self, forKey: .data))
        case .deviceList: payload = .deviceList(try c.decode(DeviceListData.self, forKey: .data))
        case .deviceRemove: payload = .deviceRemove(try c.decode(DeviceRemoveData.self, forKey: .data))
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
        case .threadRename(let d): try c.encode(d, forKey: .data)
        case .threadPin(let d): try c.encode(d, forKey: .data)
        case .interrupt(let d): try c.encode(d, forKey: .data)
        case .syncRequest(let d): try c.encode(d, forKey: .data)
        case .syncDelta(let d): try c.encode(d, forKey: .data)
        case .deviceList(let d): try c.encode(d, forKey: .data)
        case .deviceRemove(let d): try c.encode(d, forKey: .data)
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
    /// Declaration order is the order the card shows the four buttons in.
    public enum Answer: String, Codable, Sendable, CaseIterable { case yes, no, never, discuss }
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

/// Renames `threadId` from the base fields. A title the user chose: auto-titling leaves it alone.
public struct ThreadRenameData: Codable, Equatable, Sendable {
    public var title: String
    public init(title: String) { self.title = title }
}

public struct ThreadSummary: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    /// Empty until the runtime auto-titles the thread or the user renames it.
    public var title: String
    public var archived: Bool
    /// When the thread was last written to, epoch milliseconds. What the lists order on.
    public var lastActivity: Double
    /// One line of the newest message in the thread, whoever said it, for a row's preview.
    /// Nil in a thread nothing has been said in yet, so a row draws nothing rather than a blank.
    public var lastMessage: String?
    /// Pinned threads lead the phone's list.
    public var pinned: Bool

    public init(
        id: String,
        title: String,
        archived: Bool,
        lastActivity: Double,
        lastMessage: String? = nil,
        pinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.archived = archived
        self.lastActivity = lastActivity
        self.lastMessage = lastMessage
        self.pinned = pinned
    }

    /// Hand-written only to tolerate a runtime older than the last two fields: both were added
    /// after v1 shipped, and a cached list written before them must still read back.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        archived = try c.decode(Bool.self, forKey: .archived)
        lastActivity = try c.decode(Double.self, forKey: .lastActivity)
        lastMessage = try c.decodeIfPresent(String.self, forKey: .lastMessage)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    /// What a list draws: an untitled thread is one the runtime has not named yet.
    public var displayTitle: String { title.isEmpty ? "New chat" : title }

    /// ``lastActivity`` as a date, which is what a row formats relative to now.
    public var lastActivityDate: Date { Date(timeIntervalSince1970: lastActivity / 1000) }
}

public struct ThreadListData: Codable, Equatable, Sendable {
    public var threads: [ThreadSummary]
    public init(threads: [ThreadSummary]) { self.threads = threads }
}

/// Archives `threadId` from the base fields, or brings it back when ``archived`` is false.
/// The flag is optional because the frame meant "archive" before unarchiving existed, and a
/// phone from then still sends `{}`.
public struct ThreadArchiveData: Codable, Equatable, Sendable {
    public var archived: Bool?
    public init(archived: Bool? = nil) { self.archived = archived }
}

/// Pins or unpins `threadId` from the base fields.
public struct ThreadPinData: Codable, Equatable, Sendable {
    public var pinned: Bool
    public init(pinned: Bool) { self.pinned = pinned }
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

/// One device this Mac is paired with, as the Devices tab lists them. Public keys only: they
/// are identifiers here, and the short form of ``pub`` is what the user sees.
public struct DeviceInfo: Codable, Equatable, Sendable, Identifiable {
    /// How the device reaches the runtime.
    public enum Via: String, Codable, Sendable { case relay, local }
    /// X25519 public key, base64url. What the sidecar seals for, and the device's identity.
    public var pub: String
    /// Ed25519 key the relay knows the device by, when it announced one. A different key from
    /// ``pub`` and not derivable from it, so revoking at the relay needs it carried here.
    public var signingPub: String?
    public var via: Via
    /// Epoch milliseconds the runtime last heard from it.
    public var lastSeen: Double
    public var online: Bool

    public var id: String { pub }

    /// Enough of the key to tell two devices apart, which is all a list needs.
    public var shortId: String { String(pub.prefix(8)) }

    public init(pub: String, signingPub: String? = nil, via: Via, lastSeen: Double, online: Bool) {
        self.pub = pub
        self.signingPub = signingPub
        self.via = via
        self.lastSeen = lastSeen
        self.online = online
    }
}

public struct DeviceListData: Codable, Equatable, Sendable {
    public var devices: [DeviceInfo]
    public init(devices: [DeviceInfo]) { self.devices = devices }
}

/// Forget a device: dropped from the runtime's `devices.json`, and the relay is told to revoke
/// it so it cannot rejoin against the nonce either. Answered with a fresh `device_list`.
public struct DeviceRemoveData: Codable, Equatable, Sendable {
    public var pub: String
    public init(pub: String) { self.pub = pub }
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

    /// The one parser for every way a pairing arrives: the QR, a pasted string, a tapped
    /// `yorozu://` link, or the JSON form older codes carried. Throws on anything that is
    /// not a v1 payload.
    public static func decode(_ text: String) throws -> QrPayload {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("yorozu:") { return try decodePairingString(text) }
        let payload = try JSONDecoder().decode(QrPayload.self, from: Data(text.utf8))
        guard payload.v == 1 else {
            throw YorozuCrypto.CryptoError.malformed("not a Yorozu v1 QR payload")
        }
        return payload
    }

    /// `yorozu://pair?v=1&relay=<urlencoded>&key=<base64url>&token=<base64url>`, the compact
    /// form the Mac shows for copying and encodes in the QR.
    private static func decodePairingString(_ text: String) throws -> QrPayload {
        func malformed() -> Error {
            YorozuCrypto.CryptoError.malformed("not a Yorozu v1 pairing string")
        }
        /// Base64url, unpadded, is the only thing the keys and the token are ever spelled in.
        /// The same check `decodePairingString` makes in TypeScript, so neither side accepts a
        /// code the other would refuse.
        func base64Url(_ value: String?) throws -> String {
            let alphabet = CharacterSet(
                charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
            )
            guard let value, !value.isEmpty, value.unicodeScalars.allSatisfy(alphabet.contains) else {
                throw malformed()
            }
            return value
        }
        let items = URLComponents(string: text)?.queryItems ?? []
        let query = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        guard query["v"] == "1", let relayUrl = query["relay"], !relayUrl.isEmpty else {
            throw malformed()
        }
        return QrPayload(
            relayUrl: relayUrl,
            macPubkey: try base64Url(query["key"]),
            token: try base64Url(query["token"]),
            roomId: query["room"].flatMap { $0.isEmpty ? nil : $0 }
        )
    }
}
