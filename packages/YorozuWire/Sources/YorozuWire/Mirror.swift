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
    /// The topic this sub-chat was attached to (#348); absent when none. Older phones ignore it.
    public var attachedTo: String?
    /// `threads-v1` (owner, 2026-10-13): `secretary` or `user` (New chat), when it was archived (epoch ms), the main-timeline
    /// message a secretary-started thread came from, and `deleted` on the tombstone of a deleted thread, whose messages,
    /// tasks and steps the phone drops. Older phones ignore them.
    public var origin: String?
    public var archivedAt: Int?
    public var sourceMessageId: String?
    public var deleted: Bool?
    public init(id: String, label: String, created: Int, seq: Int, attachedTo: String? = nil, origin: String? = nil, archivedAt: Int? = nil,
                sourceMessageId: String? = nil, deleted: Bool? = nil) {
        self.origin = origin
        self.archivedAt = archivedAt
        self.sourceMessageId = sourceMessageId
        self.deleted = deleted
        self.id = id
        self.label = label
        self.created = created
        self.seq = seq
        self.attachedTo = attachedTo
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
    /// `history-v1` (#405): long text fields the host cut to send this record; the client fetches each whole with
    /// `text_request` before it counts its history as complete.
    public var truncated: [String]? = nil
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
    /// `history-v1` (#405): long text fields the host cut to send this record; the client fetches each whole with
    /// `text_request` before it counts its history as complete.
    public var truncated: [String]? = nil
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

/// `worker_event` (Mac -> phone, upsert by `seq`): one step of a task's activity. Only `files` changes after
/// insert: images a worker shared are attached after the event is stored, and that re-stamps its `seq`.
public struct WorkerEventData: Codable, Equatable, Sendable {
    public var id: String
    public var taskId: String
    public var kind: String
    public var body: String
    public var created: Int
    public var seq: Int
    /// 0.7 `attachments-v1`: descriptors of the images the worker shared in this step. Never bytes.
    public var files: [AttachmentDescriptor]?
    /// `history-v1` (#405): long text fields the host cut to send this record; the client fetches each whole with
    /// `text_request` before it counts its history as complete.
    public var truncated: [String]? = nil
    public init(id: String, taskId: String, kind: String, body: String, created: Int, seq: Int, files: [AttachmentDescriptor]? = nil) {
        self.id = id
        self.taskId = taskId
        self.kind = kind
        self.body = body
        self.created = created
        self.seq = seq
        self.files = files
    }
}

/// `read_state` (both directions): the newest message seen in a thread. Held by the Mac, forward-only;
/// `seq` is set by the Mac only.
public struct ReadStateData: Codable, Equatable, Sendable {
    /// Mark as Read and Unread from a client (owner, 2026-10-14): a host without it ignores `unread`.
    public static let marksCapability = "read-marks-v1"
    public var threadId: String
    public var messageId: String
    public var seq: Int?
    /// `history-v1` (owner, 2026-10-14): Mark as Unread. Client -> host: `true` marks the chat unread (the cursor stays;
    /// `messageId` is a message of that chat), `false` is an explicit read (Mark as Read, or opening the chat) that also
    /// clears it; absent is an automatic read, which clears it only by moving the cursor. Host -> client: the flag as held.
    public var unread: Bool?
    public init(threadId: String, messageId: String, seq: Int? = nil, unread: Bool? = nil) {
        self.threadId = threadId
        self.messageId = messageId
        self.seq = seq
        self.unread = unread
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

/// `readiness` (Mac -> phone, `readiness-v1`): whether the Mac can answer, after each handshake and on every
/// change. `count` is the items that need attention (warning or blocking); `title` and `fix` are user-facing.
public struct ReadinessData: Codable, Equatable, Sendable {
    public static let capability = "readiness-v1"
    public enum State: String, Codable, Sendable { case ready, attention, blocked }
    public struct Item: Codable, Equatable, Sendable {
        public enum Severity: String, Codable, Sendable { case ok, warning, blocking }
        public var id: String
        public var title: String
        public var severity: Severity
        public var fix: String?
        public init(id: String, title: String, severity: Severity, fix: String? = nil) {
            self.id = id
            self.title = title
            self.severity = severity
            self.fix = fix
        }
    }
    public var state: State
    public var count: Int
    public var items: [Item]
    public init(state: State, count: Int, items: [Item]) {
        self.state = state
        self.count = count
        self.items = items
    }
}

/// `job_list` (Mac -> phone, `jobs-v1`): every scheduled job, after each compatible handshake and on every change (#319).
public struct JobListData: Codable, Equatable, Sendable {
    public static let capability = "jobs-v1"
    public struct Job: Codable, Equatable, Sendable, Identifiable {
        public var id: String
        public var name: String
        /// The Mac's plain-words description; its first line is the schedule in words. nil until written.
        public var summary: String?
        /// The schedule in words, written by the Mac: the summary's first line, or the cron text until a summary exists.
        public var schedule: String?
        /// Epoch ms; nil while paused, retired or unscheduled.
        public var nextRun: Int?
        public var lastRun: Int?
        /// The last finished run: `done`, `failed`, `stopped` or `uncertain`, as text so a new value still decodes.
        public var lastResult: String?
        public var lastNotable: Bool?
        /// `running`, `paused`, `needsApproval`, `needsAttention`, `finished` (a one-shot that ran) or `idle`, as text so a new state still decodes.
        public var state: String
        /// The job's sub-chat; nil until the Mac has bound one.
        public var topicId: String?
        public init(id: String, name: String, summary: String?, schedule: String? = nil, nextRun: Int?, lastRun: Int?, lastResult: String?,
                    lastNotable: Bool?, state: String, topicId: String?) {
            self.id = id
            self.name = name
            self.summary = summary
            self.schedule = schedule
            self.nextRun = nextRun
            self.lastRun = lastRun
            self.lastResult = lastResult
            self.lastNotable = lastNotable
            self.state = state
            self.topicId = topicId
        }
    }
    public var jobs: [Job]
    public init(jobs: [Job]) { self.jobs = jobs }
}

/// `job_control` (phone -> Mac, `jobs-v1`): one action on one job. Answered with `admission_status` for the
/// event's id: `accepted`, or `rejected` with a user-facing `reason`.
public struct JobControlData: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case pause, resume, runNow = "run_now", delete }
    public var jobId: String
    public var action: Action
    public init(jobId: String, action: Action) {
        self.jobId = jobId
        self.action = action
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

// MARK: Threads (`threads-v1`, owner 2026-10-13)

/// One row of the thread list (`threads_page`): a sub-chat of either origin. `state` is its current task's Mac work state
/// as text (the newest active or uncertain task, else the newest; nil without work); `unread` counts messages from Yorozu
/// typed or answered in it past its read cursor. Times are epoch ms.
public struct ThreadData: Codable, Equatable, Sendable, Identifiable {
    public static let capability = "threads-v1"
    /// #405: full history (`SyncRequestData.full`), the row summary below, `ThreadsPageData.main`, Stop and Delete and
    /// `MessageData.truncated`.
    public static let historyCapability = "history-v1"
    /// The Main chat's row id in `ThreadsPageData.main`.
    public static let mainId = "main"
    public var id: String
    public var name: String
    /// `secretary` or `user`, as text so a new origin still decodes.
    public var origin: String
    public var sourceMessageId: String?
    public var summary: String?
    public var created: Int
    public var lastActivity: Int
    public var archivedAt: Int?
    public var state: String?
    public var lastMessageId: String?
    public var unread: Int
    /// `history-v1` (#405): the last visible message (progress acknowledgments never count), which orders the list,
    /// newest first: its time (epoch ms), its text as a short excerpt, its notice (rendered in the reader's language) and
    /// whether the user wrote it. Absent on a thread with no visible message (then `created` orders it).
    public var lastMessageAt: Int?
    public var preview: String?
    public var previewNotice: NoticeData?
    public var previewUser: Bool?
    /// `history-v1`: an unanswered question, a pending approval or a blocker needs the user (the orange dot); it clears
    /// only when that is resolved, never by reading. `running`: work is running (the spinner), independent of the dots.
    public var attention: Bool?
    public var running: Bool?
    /// `history-v1`: work not in a final state (running, uncertain, or a stop not yet confirmed), so Delete stops it first.
    public var openWork: Bool?
    /// `history-v1`: Mark as Unread is on; the chat reads as unread whatever `unread` counts.
    public var markedUnread: Bool?
    public init(id: String, name: String, origin: String, sourceMessageId: String?, summary: String?, created: Int, lastActivity: Int,
                archivedAt: Int?, state: String?, lastMessageId: String?, unread: Int, lastMessageAt: Int? = nil, preview: String? = nil,
                previewNotice: NoticeData? = nil, previewUser: Bool? = nil, attention: Bool? = nil, running: Bool? = nil, openWork: Bool? = nil, markedUnread: Bool? = nil) {
        self.openWork = openWork
        self.markedUnread = markedUnread
        self.id = id
        self.name = name
        self.origin = origin
        self.sourceMessageId = sourceMessageId
        self.summary = summary
        self.created = created
        self.lastActivity = lastActivity
        self.archivedAt = archivedAt
        self.state = state
        self.lastMessageId = lastMessageId
        self.unread = unread
        self.lastMessageAt = lastMessageAt
        self.preview = preview
        self.previewNotice = previewNotice
        self.previewUser = previewUser
        self.attention = attention
        self.running = running
    }

    /// The list's order (#405): newest last visible message first, then the id, so rows never trade places on a tie.
    public var sortKey: (Int, String) { (lastMessageAt ?? created, id) }
    public static func newestFirst(_ a: ThreadData, _ b: ThreadData) -> Bool { a.sortKey > b.sortKey }
}

/// `threads_request` (phone -> Mac): one page of the thread list, newest activity first. `after` is the previous page's
/// `next` (Show more); absent for the first page. `archived` lists the archived threads instead. `limit` 1–200, default 30.
public struct ThreadsRequestData: Codable, Equatable, Sendable {
    public var requestId: String
    public var archived: Bool?
    public var after: String?
    public var limit: Int?
    public init(requestId: String, archived: Bool? = nil, after: String? = nil, limit: Int? = nil) {
        self.requestId = requestId
        self.archived = archived
        self.after = after
        self.limit = limit
    }
}

/// `threads_page` (Mac -> phone): the answer. `next` is set while more threads remain; `error` is user-facing.
public struct ThreadsPageData: Codable, Equatable, Sendable {
    public var requestId: String
    public var threads: [ThreadData]
    public var next: String?
    public var error: String?
    /// `history-v1` (#405): the Main chat's row (id `main`) on the first page of the active list while the host's Main
    /// chat is on; absent while it is off. The client sorts it in with the threads, never pinned.
    public var main: ThreadData?
    public init(requestId: String, threads: [ThreadData], next: String? = nil, error: String? = nil, main: ThreadData? = nil) {
        self.main = main
        self.requestId = requestId
        self.threads = threads
        self.next = next
        self.error = error
    }
}

/// `thread_control` (phone -> Mac): rename, archive, unarchive or delete one thread. A thread is created by its first
/// message (`MessageData.newThread`). Answered with `thread_control_result`; a replayed `requestId` gets its first answer.
public struct ThreadControlData: Codable, Equatable, Sendable {
    /// `stopAndDelete` (`history-v1`, #405): stop the thread's running work, wait for each stop to be confirmed, then
    /// delete; refused, with the chat kept, when a stop cannot be confirmed.
    public enum Action: String, Codable, Sendable { case rename, archive, unarchive, delete, stopAndDelete = "stop_and_delete" }
    public var requestId: String
    public var threadId: String
    public var action: Action
    /// `rename` only: 1–80 characters.
    public var name: String?
    public init(requestId: String, threadId: String, action: Action, name: String? = nil) {
        self.requestId = requestId
        self.threadId = threadId
        self.action = action
        self.name = name
    }
}

/// `thread_control_result` (Mac -> phone). `reason` is the Mac's user-facing refusal.
public struct ThreadControlResultData: Codable, Equatable, Sendable {
    public var requestId: String
    public var threadId: String
    public var accepted: Bool
    public var reason: String?
    public init(requestId: String, threadId: String, accepted: Bool, reason: String? = nil) {
        self.requestId = requestId
        self.threadId = threadId
        self.accepted = accepted
        self.reason = reason
    }
}

/// `deleted` (host -> client, a record inside `sync_delta`, `history-v1`): a record removed for good. The client removes it
/// from its store and search and keeps no later copy of it.
public struct DeletedData: Codable, Equatable, Sendable {
    /// `message`, `task`, `worker_event` or `amendment`.
    public var kind: String
    public var id: String
    public var seq: Int
    public init(kind: String, id: String, seq: Int) { self.kind = kind; self.id = id; self.seq = seq }
}

// MARK: Host settings (`host-settings-v1`, #405)

/// `host_settings` (both ways): host-wide settings every client shares. Host -> client after each compatible handshake and
/// on every change; client -> host to change one (`mainChat`), answered by the next host -> client value.
public struct HostSettingsData: Codable, Equatable, Sendable {
    public static let capability = "host-settings-v1"
    /// The global Main chat and its cross-topic routing workflow (owner, 2026-10-14): off unless turned on.
    public var mainChat: Bool
    /// The Main chat's row like any chat's (#405): its name (nil: the default), whether it is archived, and the time up to
    /// which its own history was deleted (epoch ms): a client drops the Main chat's unfiled messages up to then that no task
    /// or change refers to, as the host did, and never keeps them again.
    public var mainName: String?
    public var mainArchived: Bool?
    public var mainClearedAt: Int?
    /// Host -> the client that asked for a change, only: why it was not applied (user-facing). Never cached.
    public var error: String?
    /// Client -> host: names a change; host -> that client: the answer to it, with the value then in force.
    public var requestId: String?
    public init(mainChat: Bool, mainName: String? = nil, mainArchived: Bool? = nil, mainClearedAt: Int? = nil, error: String? = nil, requestId: String? = nil) {
        self.mainChat = mainChat; self.mainName = mainName; self.mainArchived = mainArchived; self.mainClearedAt = mainClearedAt; self.error = error
        self.requestId = requestId
    }
}

// MARK: Oversized record text (`history-v1`, #405)

/// `text_request` (client -> host): the next slice of one long text field of a record the host sent cut
/// (`MessageData.truncated`, or a `task`, `amendment` or `worker_event` whose field was cut). The client fetches the
/// whole text this way before it counts its history as complete. Answered with `text_slice`.
public struct TextRequestData: Codable, Equatable, Sendable {
    /// The record kind (`message`, `task`, `amendment`, `worker_event`), its id and the field (`text`, `instruction`,
    /// `result`, `error`, `body`).
    public var kind: String
    public var id: String
    public var field: String
    /// A byte offset into the field's UTF-8.
    public var offset: Int
    public init(kind: String, id: String, field: String, offset: Int) {
        self.kind = kind
        self.id = id
        self.field = field
        self.offset = offset
    }
}

/// `text_slice` (host -> client): up to `TextSliceData.bytes` of the field's UTF-8 from `offset`, base64; `total` is the
/// field's whole length and `seq` the record's sequence, so a slice of an older version is dropped. `error` when the
/// record or field is gone.
public struct TextSliceData: Codable, Equatable, Sendable {
    public static let bytes = 163_840
    public var kind: String
    public var id: String
    public var field: String
    public var offset: Int
    public var total: Int
    public var seq: Int
    public var data: String
    public var error: String?
    public init(kind: String, id: String, field: String, offset: Int, total: Int, seq: Int, data: String, error: String? = nil) {
        self.kind = kind
        self.id = id
        self.field = field
        self.offset = offset
        self.total = total
        self.seq = seq
        self.data = data
        self.error = error
    }
}
