import Foundation
import GRDB

/// Operational records are app-owned. Memory indexing is a separate database.
public actor Store {
    public let root: URL
    private let db: DatabaseQueue
    private var lease: Int32 = -1
    public init(root: URL, exclusive: Bool = true) throws {
        self.root = root.standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if exclusive {
            let fd = open(root.appendingPathComponent("app.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { if fd >= 0 { close(fd) }; throw ProjectError.blocked("This data directory is already open or unsafe.") }
            lease = fd
        }
        db = try DatabaseQueue(path: root.appendingPathComponent("operations.sqlite").path)
        var migration = DatabaseMigrator()
        migration.registerMigration("native-r1") { db in
            try db.execute(sql: """
            CREATE TABLE topics(id TEXT PRIMARY KEY, label TEXT NOT NULL, sessionKey TEXT UNIQUE NOT NULL, created DOUBLE NOT NULL);
            CREATE TABLE messages(id TEXT PRIMARY KEY, role TEXT NOT NULL, body TEXT NOT NULL, topicID TEXT REFERENCES topics(id), taskID TEXT, replyTo TEXT, kind TEXT NOT NULL, created DOUBLE NOT NULL);
            CREATE TABLE work(id TEXT PRIMARY KEY, topicID TEXT NOT NULL REFERENCES topics(id), messageID TEXT NOT NULL REFERENCES messages(id), instruction TEXT NOT NULL, state TEXT NOT NULL, revision INTEGER NOT NULL, runID TEXT, controllerKey TEXT, sessionReady BOOLEAN NOT NULL, suppressed BOOLEAN NOT NULL, result TEXT, error TEXT, outputRevision INTEGER, created DOUBLE NOT NULL);
            CREATE TABLE events(id TEXT PRIMARY KEY, taskID TEXT NOT NULL REFERENCES work(id), kind TEXT NOT NULL, body TEXT NOT NULL, created DOUBLE NOT NULL);
            CREATE TABLE amendments(id TEXT PRIMARY KEY, taskID TEXT NOT NULL REFERENCES work(id), messageID TEXT NOT NULL REFERENCES messages(id), revision INTEGER NOT NULL, instruction TEXT NOT NULL, state TEXT NOT NULL, UNIQUE(taskID,revision));
            CREATE TABLE receipts(id TEXT PRIMARY KEY, kind TEXT NOT NULL, body TEXT NOT NULL, created DOUBLE NOT NULL);
            CREATE TABLE memoryJobs(messageID TEXT PRIMARY KEY, state TEXT NOT NULL);
            """)
        }
        migration.registerMigration("r2-executor") { db in try db.execute(sql: "ALTER TABLE work ADD COLUMN executor TEXT") }
        try migration.migrate(db)
        // Restart never replays uncertain work or silently declares it stopped.
        try db.write { db in
            let interrupted = try Work.fetchAll(db, sql: "SELECT * FROM work WHERE state IN ('working','queued','amendment_pending','cancellation_requested')")
            // Never dispatched (no run ID): safe to queue again. Dispatched: Engine.resume() re-attaches and reports.
            for var item in interrupted {
                if item.runID == nil { item.state = item.suppressed ? "cancelled" : "queued" }
                else { item.state = "uncertain"; item.error = "App restarted while this was running." }
                try item.update(db)
            }
        }
    }
    deinit { if lease >= 0 { flock(lease, LOCK_UN); close(lease) } }
    public func snapshot() throws -> Snapshot {
        try db.read { db in
            var s = Snapshot()
            s.topics = try Topic.fetchAll(db, sql: "SELECT * FROM topics ORDER BY created,rowid")
            s.messages = try Message.fetchAll(db, sql: "SELECT * FROM messages ORDER BY created,rowid")
            s.work = try Work.fetchAll(db, sql: "SELECT * FROM work ORDER BY created,rowid")
            s.events = try WorkerEvent.fetchAll(db, sql: "SELECT * FROM events ORDER BY created,rowid")
            s.amendments = try Amendment.fetchAll(db, sql: "SELECT * FROM amendments ORDER BY rowid")
            return s
        }
    }
    public func topic(label: String, agent: String = "projectx") throws -> Topic {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.count <= 80 else { throw ProjectError.invalid("Topic label must be 1–80 characters.") }
        let id = identifier(); let t = Topic(id: id, label: label, sessionKey: "agent:\(agent):projectx:\(id)", created: Date().timeIntervalSince1970)
        try db.write { try t.insert($0) }; return t
    }
    @discardableResult public func message(role: String, body: String, topic: String? = nil, task: String? = nil, replyTo: String? = nil, kind: String = "conversation", id: String = identifier()) throws -> Message {
        let m = Message(id: id, role: role, body: body, topicID: topic, taskID: task, replyTo: replyTo, kind: kind, created: Date().timeIntervalSince1970)
        try db.write { try m.insert($0) }; return m
    }
    /// Assign only the newly received, previously unrouted message. Never migrate an old exchange.
    public func assign(message: String, topic: String) throws {
        try db.write { try $0.execute(sql: "UPDATE messages SET topicID=? WHERE id=? AND topicID IS NULL", arguments: [topic,message]) }
    }
    public func insertWork(_ work: Work) throws {
        try db.write { db in
            // One active task per (topic, worker kind): a long coding run never blocks thinking work in the same topic.
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM work WHERE topicID=? AND executor IS ? AND (state IN ('queued','working','amendment_pending','cancellation_requested','uncertain'))", arguments: [work.topicID,work.executor]) == 0 else { throw ProjectError.blocked("This topic already has active or uncertain work. Steer it or reconcile before retrying.") }
            try work.insert(db)
        }
    }
    public func startWork(_ id: String) throws -> Work? {
        try db.write { db in
            guard var w = try Work.fetchOne(db,key: id), !w.suppressed, w.state == "queued" else { return nil }
            w.state = "working"; try w.update(db); return w
        }
    }
    public func setHandle(_ id: String,handle: RunHandle) throws {
        try db.write { db in
            guard var w = try Work.fetchOne(db,key: id), !w.suppressed, w.active else { throw ProjectError.blocked("Work superseded before invocation; no further run allowed.") }
            w.runID = handle.runID; w.controllerKey = handle.controllerKey; w.sessionReady = true; try w.update(db)
        }
    }
    public func suppress(_ id: String) throws -> Work {
        try db.write { db in
            guard var w = try Work.fetchOne(db,key: id) else { throw ProjectError.invalid("Unknown work.") }
            w.suppressed = true
            w.state = w.state == "queued" && w.runID == nil ? "cancelled" : (w.active || w.state == "uncertain") ? "cancellation_requested" : "superseded"
            try w.update(db); return w
        }
    }
    /// Only an acknowledged stop changes state; restart may have turned a pending stop into 'uncertain'.
    public func cancellation(_ id: String,acknowledged: Bool) throws {
        guard acknowledged else { return }
        try db.write { try $0.execute(sql: "UPDATE work SET state='cancelled' WHERE id=? AND suppressed=1 AND state IN ('cancellation_requested','uncertain')",arguments: [id]) }
    }
    public func failWork(_ id: String,error: String) throws -> Work? {
        try db.write { db in
            guard var w = try Work.fetchOne(db,key: id), !w.suppressed else { return nil }
            w.state = w.runID == nil ? "failed" : "uncertain"; w.error = error; try w.update(db); return w
        }
    }
    public func retireForRetry(_ id: String) throws {
        try db.write { db in
            guard var w = try Work.fetchOne(db,key: id), !w.suppressed, ["failed","uncertain"].contains(w.state) else { throw ProjectError.blocked("Work changed during reconciliation; no retry dispatched.") }
            w.suppressed = true; w.state = "failed"; try w.update(db)
        }
    }
    public func bindRuntime(_ name: String) throws {
        if name == "Offline · no model calls" { return }
        try db.write { db in
            if let old = try String.fetchOne(db,sql: "SELECT body FROM receipts WHERE id='runtime-binding'"), old != name { throw ProjectError.blocked("This workspace belongs to a different harness mode. Use a separate data directory; fixture sessions are not live sessions.") }
            try db.execute(sql: "INSERT OR IGNORE INTO receipts VALUES ('runtime-binding','runtime',?,?)",arguments: [name,Date().timeIntervalSince1970])
        }
    }
    public func updateWork(_ value: Work) throws { try db.write { try value.update($0) } }
    public func work(_ id: String) throws -> Work { try db.read { db in guard let w = try Work.fetchOne(db, key: id) else { throw ProjectError.invalid("Unknown work.") }; return w } }
    public func event(_ event: WorkerEvent) throws { try db.write { try event.insert($0, onConflict: .ignore) } }
    public func gatewayReceipt(_ value: GatewayRequestReceipt) throws { try receipt(kind: "gateway-request",body: encoded(value)) }
    public func receipt(kind: String, body: String) throws { try db.write { try $0.execute(sql: "INSERT INTO receipts VALUES (?,?,?,?)", arguments: [identifier(),kind,body,Date().timeIntervalSince1970]) } }
    public func amend(task: String, message: String, instruction: String) throws -> Amendment {
        try db.write { db in
            guard var w = try Work.fetchOne(db, key: task), w.active, !w.suppressed else { throw ProjectError.blocked("Target is no longer active; no duplicate was launched.") }
            let queued = w.state == "queued" && w.runID == nil
            w.revision += 1
            if queued { w.instruction += "\nAmendment \(w.revision): " + instruction } else { w.state = "amendment_pending" }
            try w.update(db)
            let a = Amendment(id: identifier(), taskID: task, messageID: message, revision: w.revision, instruction: instruction, state: queued ? "queued_input" : "pending")
            try a.insert(db); return a
        }
    }
    /// Preserve a correction for an uncertain run without claiming active steering or dispatching.
    public func deferCorrection(task: String,message: String,instruction: String) throws -> Amendment {
        try db.write { db in
            guard var w = try Work.fetchOne(db,key: task), w.state == "uncertain", !w.suppressed else { throw ProjectError.blocked("Target changed during correction; no duplicate or steering claim made.") }
            w.revision += 1; try w.update(db)
            let a = Amendment(id: identifier(),taskID: task,messageID: message,revision: w.revision,instruction: instruction,state: "pending_reconciliation")
            try a.insert(db); return a
        }
    }
    /// Only a still-pending amendment changes; a follow-up turn that already took it as input wins.
    public func amendmentState(id: String, state: String) throws { try db.write { try $0.execute(sql: "UPDATE amendments SET state=? WHERE id=? AND state='pending'", arguments: [state,id]) } }
    /// Completion is transactional with amendment admission and correction suppression.
    @discardableResult public func complete(task: String, output: WorkerOutput) throws -> Message? {
        try db.write { try Self.complete($0,task: task,output: output) }
    }
    /// Amendments live steering did not admit (or did not confirm) become a follow-up turn of the SAME task and
    /// session, atomically with completion. Returns the work to run again, or the delivered result.
    /// `requeue` hands the follow-up to the worker queue (retry of a reconciled run) instead of the running executor.
    public func finish(task: String, output: WorkerOutput, requeue: Bool = false) throws -> (reply: Message?, followUp: Work?) {
        try db.write { db in
            if var w = try Work.fetchOne(db,key: task), !w.suppressed {
                let open = try Amendment.fetchAll(db,sql: "SELECT * FROM amendments WHERE taskID=? AND (state IN ('pending','pending_reconciliation') OR (state='accepted' AND revision>?)) ORDER BY revision",arguments: [task,output.appliedRevision])
                if !open.isEmpty {
                    for var a in open { w.instruction += "\nAmendment \(a.revision): " + a.instruction; a.state = "queued_input"; try a.update(db) }
                    // Keep the superseded answer inspectable in the sub-chat; it is not delivered as the result.
                    try WorkerEvent(id: task + ":superseded:" + identifier(),taskID: task,kind: "superseded_result",body: output.text,created: Date().timeIntervalSince1970).insert(db)
                    // A follow-up has no run until setHandle stamps one: a stale ID would let retry reconcile the superseded
                    // run, and queued work with a run ID would make a later steer treat it as live.
                    w.state = requeue ? "queued" : "working"; w.runID = nil
                    try w.update(db); return (nil,w)
                }
            }
            return (try Self.complete(db,task: task,output: output),nil)
        }
    }
    private static func complete(_ db: Database, task: String, output: WorkerOutput) throws -> Message? {
        guard var w = try Work.fetchOne(db, key: task) else { throw ProjectError.invalid("Unknown task.") }
        w.result = output.text; w.outputRevision = output.appliedRevision
        let pending = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM amendments WHERE taskID=? AND state NOT IN ('accepted','applied','queued_input')", arguments: [task]) ?? 0
        // Queued-input amendments were part of the instruction the worker answered; only live-steered ones need its echo.
        let steered = try Int.fetchOne(db, sql: "SELECT MAX(revision) FROM amendments WHERE taskID=? AND state='accepted'", arguments: [task]) ?? 0
        if w.suppressed { w.state = "superseded"; try w.update(db); return nil }
        guard output.appliedRevision >= steered, pending == 0 else { w.state = "amendment_pending"; w.error = "Result retained in sub-chat; latest amendment not confirmed."; try w.update(db)
            let kind = "amendment_unconfirmed_" + String(w.revision)
            if try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM messages WHERE taskID=? AND kind=?",arguments: [task,kind]) == 0 {
                try Message(id: identifier(),role: "assistant",body: "The task finished without confirming your latest change. Its answer is in the sub-chat.",topicID: w.topicID,taskID: task,replyTo: w.messageID,kind: kind,created: Date().timeIntervalSince1970).insert(db)
            }; return nil }
        w.state = "done"; w.error = nil; try w.update(db)
        try db.execute(sql: "UPDATE amendments SET state='applied' WHERE taskID=?", arguments: [task])
        if try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages WHERE taskID=? AND kind='result'", arguments: [task]) ?? 0 > 0 { return nil }
        let source = try Message.fetchOne(db, key: w.messageID)
        let text = "Regarding “\(String((source?.body ?? w.instruction).prefix(100)))”:\n\n\(output.text)"
        let m = Message(id: identifier(), role: "assistant", body: text, topicID: w.topicID, taskID: task, replyTo: w.messageID, kind: "result", created: Date().timeIntervalSince1970)
        try m.insert(db); return m
    }
    public func memoryProcessed(_ id: String) throws -> Bool { try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM memoryJobs WHERE messageID=?", arguments: [id]) ?? 0 > 0 } }
    public func markMemory(_ id: String, state: String) throws { try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO memoryJobs VALUES (?,?)", arguments: [id,state]) } }
}
