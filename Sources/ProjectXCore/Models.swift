import Foundation
import GRDB

public struct Topic: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "topics"
    public var id: String; public var label: String; public var sessionKey: String; public var created: Double
}
public struct Message: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "messages"
    public var id: String; public var role: String; public var body: String; public var topicID: String?
    public var taskID: String?; public var replyTo: String?; public var kind: String; public var created: Double
}
public struct Work: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "work"
    public var id: String; public var topicID: String; public var messageID: String; public var instruction: String
    public var state: String; public var revision: Int; public var runID: String?; public var controllerKey: String?
    public var sessionReady: Bool; public var suppressed: Bool; public var result: String?; public var error: String?
    public var outputRevision: Int?; public var created: Double
    /// nil = thinking worker; "claude" (Claude Code) or "codex" = coding worker in its own managed worktree.
    public var executor: String? = nil
    public var active: Bool { ["queued", "working", "amendment_pending", "cancellation_requested"].contains(state) }
}
public struct WorkerEvent: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "events"
    public var id: String; public var taskID: String; public var kind: String; public var body: String; public var created: Double
}
public struct Amendment: Codable, FetchableRecord, PersistableRecord, Identifiable, Sendable {
    public static let databaseTableName = "amendments"
    public var id: String; public var taskID: String; public var messageID: String; public var revision: Int
    public var instruction: String; public var state: String
}
public struct Snapshot: Sendable {
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
    /// "N older interrupted tasks omitted" once the routing trim compacts blocking work.
    public var omitted: String? = nil
    enum CodingKeys: String, CodingKey { case message, recent, topics, work, latestTopic, memory, sourceMessageID, omitted }
}
public struct WorkerInput: Codable, Sendable {
    public var policy: String; public var topic: Topic; public var work: Work; public var current: Message
    public var history: [Message]; public var memory: [MemoryHit]
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
