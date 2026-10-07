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
    case invalid(String), blocked(String), conflict(String), uncertain(String), offline
    public var errorDescription: String? {
        switch self { case .invalid(let s), .blocked(let s), .conflict(let s), .uncertain(let s): return s
        case .offline: return "Offline mode: message saved; no model was called. Live Gateway integration has not been verified." }
    }
}
public struct Decision: Codable, Sendable {
    public var action: String; public var topicID: String?; public var newTopic: String?; public var taskID: String?
    public var instruction: String?; public var reply: String?; public var memoryID: String?
    public init(action: String, topicID: String? = nil, newTopic: String? = nil, taskID: String? = nil, instruction: String? = nil, reply: String? = nil, memoryID: String? = nil) {
        self.action = action; self.topicID = topicID; self.newTopic = newTopic; self.taskID = taskID; self.instruction = instruction; self.reply = reply; self.memoryID = memoryID
    }
}
public struct RoutingInput: Codable, Sendable {
    public var policy: String; public var message: String; public var recent: [Message]; public var topics: [Topic]
    public var work: [Work]; public var latestTopic: String?; public var memory: [MemoryHit]
    public var sourceMessageID: String? = nil
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
public enum StreamUpdate: Sendable { case handle(RunHandle), event(WorkerEvent) }
public func identifier() -> String { UUID().uuidString.lowercased() }
public func encoded<T: Encodable>(_ value: T) throws -> String { String(decoding: try JSONEncoder().encode(value), as: UTF8.self) }
