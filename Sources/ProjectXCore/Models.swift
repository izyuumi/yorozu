import Foundation
import GRDB

public struct Topic: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "topics"
    public var id: String; public var label: String; public var sessionKey: String; public var created: Double
}
public struct Message: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "messages"
    public var id: String; public var role: String; public var body: String; public var topicID: String?
    public var taskID: String?; public var replyTo: String?; public var kind: String; public var created: Double
    /// App-written notices: a stable code rendered at display time; `body` keeps the English text for 0.6 phones and older builds.
    public var notice: Notice? = nil
    /// When routing of a user message started (`Engine.route`); nil = never started. Never sent to a model.
    public var readAt: Double? = nil
}
public struct Work: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "work"
    public var id: String; public var topicID: String; public var messageID: String; public var instruction: String
    public var state: String; public var revision: Int; public var runID: String?; public var controllerKey: String?
    public var sessionReady: Bool; public var suppressed: Bool; public var result: String?; public var error: String?
    public var outputRevision: Int?; public var created: Double
    /// nil = thinking worker; otherwise the id of a coding executor the harness advertises (`Harness.executors`).
    public var executor: String? = nil
    public var active: Bool { ["queued", "working", "amendment_pending", "cancellation_requested"].contains(state) }
}
public struct WorkerEvent: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "events"
    public var id: String; public var taskID: String; public var kind: String; public var body: String; public var created: Double
}
public struct Amendment: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable, Equatable {
    public static let databaseTableName = "amendments"
    public var id: String; public var taskID: String; public var messageID: String; public var revision: Int
    public var instruction: String; public var state: String
}
/// The last message seen in a thread; it only moves forward (`Store.markRead`).
public struct ReadCursor: Codable, FetchableRecord, Sendable, Equatable { public var threadID: String; public var messageID: String }
/// One row with the change sequence of its last insert or update (`changeSeq`, bumped by triggers).
public struct Change: Sendable {
    public enum Record: Sendable { case topic(Topic), message(Message), work(Work), event(WorkerEvent), amendment(Amendment), readCursor(ReadCursor) }
    public var seq: Int64; public var record: Record
}
/// Changes in sequence order. Apply a prefix and continue after its last `seq`; with `more` false, `latest` is the next cursor.
public struct ChangePage: Sendable { public var changes: [Change]; public var more: Bool; public var latest: Int64 }
/// A message hit (`messageID`, `topicID` when filed in a topic) or a sub-chat worker event (`eventID`, `taskID`, `topicID`).
public struct SearchHit: Sendable, Equatable {
    public var threadID = "main"; public var topicID: String?; public var taskID: String?; public var messageID: String?; public var eventID: String?
    public var snippet: String; public var created: Double
}
/// What a Stop or Retry control did; `text` is the posted acknowledgment or failure, or a short status when none was posted.
public struct TaskOutcome: Sendable, Equatable {
    public var accepted: Bool; public var text: String; public var notice: Notice?; public var messageID: String?
}
public struct Snapshot: Sendable, Equatable {
    public var topics: [Topic] = []; public var messages: [Message] = []; public var work: [Work] = []; public var events: [WorkerEvent] = []
    public var amendments: [Amendment] = []
    public init() {}
}
public enum ProjectError: Error, LocalizedError, Sendable {
    /// `overflow`: the model's context window was exceeded; retrying unchanged would fail the same way.
    case invalid(String), blocked(String), conflict(String), uncertain(String), overflow(String), offline
    public var errorDescription: String? {
        switch self { case .invalid(let s), .blocked(let s), .conflict(let s), .uncertain(let s), .overflow(let s): return s
        case .offline: return "Offline mode: message saved; no model was called. Live Gateway integration has not been verified." }
    }
}
/// Stored as JSON `{code, params}` in `messages.notice`. Raw error text goes only into `params["error"]`.
public struct Notice: Codable, Sendable, Equatable {
    public var code: String; public var params: [String:String]
    public init(_ code: Code, _ params: [String:String] = [:]) { self.code = code.rawValue; self.params = params }
    public enum Code: String, Sendable {
        case question, questionTopic = "question_topic", questionTask = "question_task" // kind `conversation` (clarify) or `question`
        case routingFailed = "routing_failed", offline, taskFailed = "task_failed", taskOverflow = "task_overflow"
        case interruptedByRestart = "interrupted_by_restart", compactionFailed = "compaction_failed", memorySkipped = "memory_skipped"
        case retryRunning = "retry_running", retryNotAllowed = "retry_not_allowed", correctionBlocked = "correction_blocked"
        case earlierStoppedWithChange = "earlier_stopped_with_change", earlierFinishedChange = "earlier_finished_change", earlierRunning = "earlier_running", earlierUnknown = "earlier_unknown"
        case changeQueued = "change_queued", changeSent = "change_sent", changeHeld = "change_held", changeAfterFinish = "change_after_finish"
        case notRunning = "not_running", stopped, stopping, moved, movedStopping = "moved_stopping", correctionSaved = "correction_saved", earlierRetired = "earlier_retired"
        case memoryForgotten = "memory_forgotten", amendmentUnconfirmed = "amendment_unconfirmed"
        case closedTooLong = "closed_too_long", taskControlFailed = "task_control_failed" // unrouted > 24 h at launch; Stop/Retry control error (params error)
        case configInvalid = "config_invalid", settingsChanged = "settings_changed" // config.toml (#312): params file/line/key/reason; keys
        // Typed harness failures (#318, `HarnessError`); params error.
        case harnessBusy = "harness_busy", runInterrupted = "run_interrupted", approvalRequested = "approval_requested", modelMismatch = "model_mismatch", harnessNotReady = "harness_not_ready"
    }
}
/// A harness failure with its own notice code. Context overflow stays `ProjectError.overflow` (`task_overflow`) and a
/// failed compaction a `compaction_failed` notice. Each reports how the run ended, so the work fails rather than going uncertain.
public enum HarnessError: Error, LocalizedError, Sendable {
    /// The harness refused the run for load (e.g. HTTP 429); nothing ran.
    case busy(String)
    /// The run ended without an answer, e.g. a harness restart.
    case interrupted(String)
    /// The harness asked for a per-step approval Yorozu does not give; the step was denied.
    case approvalRequested(String)
    /// The harness served another model than the one set; its output was not used.
    case modelMismatch(String)
    /// The harness or the executor cannot run this yet (not installed, not set up, not offered).
    case notReady(String)
    public var errorDescription: String? {
        switch self { case .busy(let s), .interrupted(let s), .approvalRequested(let s), .modelMismatch(let s), .notReady(let s): return s }
    }
    public var code: Notice.Code {
        switch self { case .busy: .harnessBusy; case .interrupted: .runInterrupted; case .approvalRequested: .approvalRequested; case .modelMismatch: .modelMismatch; case .notReady: .harnessNotReady }
    }
}
/// An error that is posted as a coded notice (kind `failure`, or `question` when the secretary must ask the user).
public struct NoticeError: LocalizedError, Sendable {
    public var notice: Notice; public var kind: String; public var errorDescription: String?
    public init(_ code: Notice.Code, _ text: String, kind: String = "failure") { notice = Notice(code); self.kind = kind; errorDescription = text }
}
public struct Decision: Codable, Sendable {
    public var action: String; public var topicID: String?; public var newTopic: String?; public var taskID: String?
    public var instruction: String?; public var reply: String?; public var memoryID: String?; public var executor: String?
    public init(action: String, topicID: String? = nil, newTopic: String? = nil, taskID: String? = nil, instruction: String? = nil, reply: String? = nil, memoryID: String? = nil, executor: String? = nil) {
        self.action = action; self.topicID = topicID; self.newTopic = newTopic; self.taskID = taskID; self.instruction = instruction; self.reply = reply; self.memoryID = memoryID; self.executor = executor
    }
}
/// The secretary's slim view: only the fields routing needs, never database records. Long text is excerpted by bytes.
public struct RoutingInput: Codable, Sendable {
    public struct TopicView: Codable, Sendable { public var id: String; public var label: String }
    public struct MessageView: Codable, Sendable { public var role: String; public var topicID: String?; public var taskID: String?; public var kind: String; public var body: String }
    public struct WorkView: Codable, Sendable { public var id: String; public var topicID: String; public var state: String; public var executor: String?; public var instruction: String; public var error: String? }
    public struct MemoryView: Codable, Sendable { public var id: String; public var title: String; public var excerpt: String }
    /// Instructions, printed once above the context data and never encoded into it.
    public var policy: String = ""; public var message: String; public var recent: [MessageView]; public var topics: [TopicView]
    public var work: [WorkView]; public var latestTopic: String?; public var memory: [MemoryView]
    public var sourceMessageID: String? = nil
    /// "N older interrupted tasks and M less active topics omitted" once the routing trim drops blocking work or topics.
    public var omitted: String? = nil
    enum CodingKeys: String, CodingKey { case message, recent, topics, work, latestTopic, memory, sourceMessageID, omitted }
}
/// `history`: only topic conversation the worker's session has not seen. `followUp`: the amendments a follow-up turn adds;
/// the thinking session already holds the earlier turn, so it gets only these.
public struct WorkerInput: Codable, Sendable {
    public struct Turn: Codable, Sendable { public var role: String; public var body: String }
    public struct Note: Codable, Sendable { public var path: String; public var title: String; public var attribution: String; public var epistemicStatus: String; public var body: String }
    public var policy: String; public var topic: Topic; public var work: Work; public var current: Message
    public var history: [Turn]; public var memory: [Note]; public var followUp: String? = nil
    /// What a thinking session is sent: slim views, never database records or harness session/controller keys (the topic
    /// is only `{id, label}`). The history bound measures this.
    public var wire: String { get throws {
        struct Wire: Encodable { var policy: String; var topic: [String:String]; var revision: Int; var instruction: String; var current: [String:String]; var history: [Turn]; var memory: [Note] }
        return try encoded(Wire(policy: policy,topic: ["id": topic.id,"label": topic.label],revision: work.revision,instruction: work.instruction,current: ["id": current.id,"body": current.body],history: history,memory: memory))
    } }
}
public struct WorkerOutput: Codable, Sendable {
    public var text: String; public var appliedRevision: Int
    public init(text: String, appliedRevision: Int = 0) { self.text = text; self.appliedRevision = appliedRevision }
}
public struct RunHandle: Codable, Sendable {
    public var sessionKey: String; public var controllerKey: String; public var runID: String
    public init(sessionKey: String, controllerKey: String, runID: String) { self.sessionKey = sessionKey; self.controllerKey = controllerKey; self.runID = runID }
}
public enum RunStatus: Sendable { case running, stopped, completed(WorkerOutput), unknown }
/// `notice`: a short failure note for the main timeline (e.g. a failed compaction), outside the task's result.
public enum StreamUpdate: Sendable { case handle(RunHandle), event(WorkerEvent), notice(String) }
/// The one cap on a raw model run's final prompt, in UTF-8 bytes. Every raw-run budget measures against it.
public let rawPromptCap = 20_000
public func identifier() -> String { UUID().uuidString.lowercased() }
public func encoded<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
