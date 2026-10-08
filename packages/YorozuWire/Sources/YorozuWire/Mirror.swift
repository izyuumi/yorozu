import Foundation

// Contract 0.7 payloads (docs/ios-relay-contract.md). Times are epoch milliseconds; `seq` is the
// Mac's change sequence of the row, and a receiver keeps a record only over one with a lower `seq`.

/// An app notice: a stable code rendered in the reader's language, with its parameters.
public struct NoticeData: Codable, Equatable, Sendable {
    public var code: String
    public var params: [String: String]
    public init(code: String, params: [String: String] = [:]) {
        self.code = code
        self.params = params
    }
}

/// `topic` (Mac -> phone, upsert): one sub-chat.
public struct TopicData: Codable, Equatable, Sendable {
    public var id: String
    public var label: String
    public var created: Int
    public var seq: Int
    public init(id: String, label: String, created: Int, seq: Int) {
        self.id = id
        self.label = label
        self.created = created
        self.seq = seq
    }
}

/// `task` (Mac -> phone, upsert): one unit of delegated work. `state` and `executor` are the
/// Mac's strings (`docs/architecture.md`), kept as text so a new value still decodes.
public struct TaskData: Codable, Equatable, Sendable {
    public var id: String
    public var topicId: String
    public var messageId: String
    public var instruction: String
    /// nil = thinking worker; otherwise the coding worker's name (`claude`, `codex`).
    public var executor: String?
    public var state: String
    public var revision: Int
    public var suppressed: Bool
    public var error: String?
    public var result: String?
    public var created: Int
    public var seq: Int
    public init(id: String, topicId: String, messageId: String, instruction: String, executor: String?, state: String,
                revision: Int, suppressed: Bool, error: String?, result: String?, created: Int, seq: Int) {
        self.id = id
        self.topicId = topicId
        self.messageId = messageId
        self.instruction = instruction
        self.executor = executor
        self.state = state
        self.revision = revision
        self.suppressed = suppressed
        self.error = error
        self.result = result
        self.created = created
        self.seq = seq
    }
}

/// `amendment` (Mac -> phone, upsert): a change to a task's instruction.
public struct AmendmentData: Codable, Equatable, Sendable {
    public var id: String
    public var taskId: String
    public var messageId: String
    public var revision: Int
    public var instruction: String
    public var state: String
    public var seq: Int
    public init(id: String, taskId: String, messageId: String, revision: Int, instruction: String, state: String, seq: Int) {
        self.id = id
        self.taskId = taskId
        self.messageId = messageId
        self.revision = revision
        self.instruction = instruction
        self.state = state
        self.seq = seq
    }
}

/// `worker_event` (Mac -> phone, insert-only): one step of a task's activity.
public struct WorkerEventData: Codable, Equatable, Sendable {
    public var id: String
    public var taskId: String
    public var kind: String
    public var body: String
    public var created: Int
    public var seq: Int
    public init(id: String, taskId: String, kind: String, body: String, created: Int, seq: Int) {
        self.id = id
        self.taskId = taskId
        self.kind = kind
        self.body = body
        self.created = created
        self.seq = seq
    }
}

/// `read_state` (both directions): the newest message seen in a thread. Held by the Mac, forward-only;
/// `seq` is set by the Mac only.
public struct ReadStateData: Codable, Equatable, Sendable {
    public var threadId: String
    public var messageId: String
    public var seq: Int?
    public init(threadId: String, messageId: String, seq: Int? = nil) {
        self.threadId = threadId
        self.messageId = messageId
        self.seq = seq
    }
}

/// `task_control` (phone -> Mac): Stop or Retry one task, without the secretary.
public struct TaskControlData: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case stop, retry }
    public var requestId: String
    public var taskId: String
    public var action: Action
    public init(requestId: String, taskId: String, action: Action) {
        self.requestId = requestId
        self.taskId = taskId
        self.action = action
    }
}

/// `task_control_result` (Mac -> phone): what a `task_control` did. `text` is user-facing;
/// `messageId` is the acknowledgment or failure message it posted, if any.
public struct TaskControlResultData: Codable, Equatable, Sendable {
    public var requestId: String
    public var taskId: String
    public var accepted: Bool
    public var text: String
    public var notice: NoticeData?
    public var messageId: String?
    public init(requestId: String, taskId: String, accepted: Bool, text: String, notice: NoticeData? = nil, messageId: String? = nil) {
        self.requestId = requestId
        self.taskId = taskId
        self.accepted = accepted
        self.text = text
        self.notice = notice
        self.messageId = messageId
    }
}

/// `search_request` (phone -> Mac): full-history search, main timeline and sub-chats.
public struct SearchRequestData: Codable, Equatable, Sendable {
    public var requestId: String
    public var query: String
    public var offset: Int?
    public init(requestId: String, query: String, offset: Int? = nil) {
        self.requestId = requestId
        self.query = query
        self.offset = offset
    }
}

/// One search hit: a message (`messageId`) or a sub-chat worker event (`eventId` with `taskId`).
public struct SearchHitData: Codable, Equatable, Sendable {
    public var threadId: String
    public var topicId: String?
    public var taskId: String?
    public var messageId: String?
    public var eventId: String?
    public var snippet: String
    public var created: Int
    public init(threadId: String, topicId: String? = nil, taskId: String? = nil, messageId: String? = nil,
                eventId: String? = nil, snippet: String, created: Int) {
        self.threadId = threadId
        self.topicId = topicId
        self.taskId = taskId
        self.messageId = messageId
        self.eventId = eventId
        self.snippet = snippet
        self.created = created
    }
}

/// `search_result` (Mac -> phone). `nextOffset` is set while more hits remain; `error` is user-facing.
public struct SearchResultData: Codable, Equatable, Sendable {
    public var requestId: String
    public var hits: [SearchHitData]
    public var total: Int
    public var nextOffset: Int?
    public var error: String?
    public init(requestId: String, hits: [SearchHitData], total: Int, nextOffset: Int? = nil, error: String? = nil) {
        self.requestId = requestId
        self.hits = hits
        self.total = total
        self.nextOffset = nextOffset
        self.error = error
    }
}

/// `page_request` (phone -> Mac): the page around one message, inside or outside the history window.
/// Answered with a `sync_delta` carrying the same `requestId`.
public struct PageRequestData: Codable, Equatable, Sendable {
    public var requestId: String
    public var threadId: String
    public var messageId: String
    public init(requestId: String, threadId: String, messageId: String) {
        self.requestId = requestId
        self.threadId = threadId
        self.messageId = messageId
    }
}

/// `chunk` (Mac -> phone): one ordered slice of an event whose JSON encoding exceeds ``budget``.
/// `data` is base64 of up to ``slice`` bytes of that encoding; `id` names the set.
public struct ChunkData: Codable, Equatable, Sendable {
    public var id: String
    public var index: Int
    public var count: Int
    public var data: String
    public init(id: String, index: Int, count: Int, data: String) {
        self.id = id
        self.index = index
        self.count = count
        self.data = data
    }

    /// The largest event encoding sent whole: 256 KiB.
    public static let budget = 262_144
    /// Raw bytes per chunk, so its base64 `data` is exactly ``budget``.
    public static let slice = 196_608
    /// The most chunks one set may have (48 MiB of encoded event).
    public static let maxCount = 256
}

extension YorozuEvent {
    /// This event alone when its encoding fits ``ChunkData/budget``, else its ordered `chunk` events.
    /// Send a set's chunks back to back, never interleaved with another set to the same phone.
    public func chunked() throws -> [YorozuEvent] {
        let bytes = try JSONEncoder().encode(self)
        guard bytes.count > ChunkData.budget else { return [self] }
        let count = (bytes.count + ChunkData.slice - 1) / ChunkData.slice
        guard count <= ChunkData.maxCount else {
            throw EncodingError.invalidValue(self, .init(codingPath: [], debugDescription: "Event too large to chunk"))
        }
        let set = UUID().uuidString
        return (0..<count).map { i in
            let part = bytes[(i * ChunkData.slice)..<min(bytes.count, (i + 1) * ChunkData.slice)]
            return YorozuEvent(id: UUID().uuidString, threadId: threadId, ts: ts, agentId: agentId,
                               payload: .chunk(ChunkData(id: set, index: i, count: count, data: part.base64EncodedString())))
        }
    }
}

/// Reassembles `chunk` events in order (phone side). A chunk that does not continue the current set
/// drops it; a set restarts at index 0.
public struct ChunkAssembler: Sendable {
    private var id: String?
    private var count = 0
    private var next = 0
    private var bytes = Data()

    public init() {}

    /// The whole event once the last chunk of its set arrived; nil while incomplete or on a bad chunk.
    public mutating func add(_ chunk: ChunkData) -> YorozuEvent? {
        if chunk.index == 0 { id = chunk.id; count = chunk.count; next = 0; bytes = Data() }
        guard chunk.id == id, chunk.index == next, chunk.count == count, (2...ChunkData.maxCount).contains(chunk.count), chunk.index < chunk.count,
              let part = Data(base64Encoded: chunk.data), !part.isEmpty, part.count <= ChunkData.slice else {
            self = ChunkAssembler()
            return nil
        }
        bytes.append(part)
        next += 1
        guard next == chunk.count else { return nil }
        defer { self = ChunkAssembler() }
        guard let event = try? JSONDecoder().decode(YorozuEvent.self, from: bytes) else { return nil }
        if case .chunk = event.payload { return nil }
        return event
    }
}
