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
        // A separate table: older builds insert two values into memoryJobs and must keep working on this database.
        migration.registerMigration("memory-job-reasons") { db in try db.execute(sql: "CREATE TABLE memoryJobReasons(messageID TEXT PRIMARY KEY, reason TEXT NOT NULL)") }
        // Nullable: older builds insert messages through GRDB records, which name their columns.
        migration.registerMigration("message-notice") { db in try db.execute(sql: "ALTER TABLE messages ADD COLUMN notice TEXT") }
        // External-content trigram index over bodies; triggers keep it in sync with every build's inserts.
        migration.registerMigration("message-search") { db in try db.execute(sql: """
            CREATE VIRTUAL TABLE messageSearch USING fts5(body, content='messages', content_rowid='rowid', tokenize='trigram');
            CREATE TRIGGER messageSearch_ai AFTER INSERT ON messages BEGIN INSERT INTO messageSearch(rowid,body) VALUES (new.rowid,new.body); END;
            CREATE TRIGGER messageSearch_ad AFTER DELETE ON messages BEGIN INSERT INTO messageSearch(messageSearch,rowid,body) VALUES ('delete',old.rowid,old.body); END;
            CREATE TRIGGER messageSearch_au AFTER UPDATE OF body ON messages BEGIN INSERT INTO messageSearch(messageSearch,rowid,body) VALUES ('delete',old.rowid,old.body); INSERT INTO messageSearch(rowid,body) VALUES (new.rowid,new.body); END;
            INSERT INTO messageSearch(messageSearch) VALUES ('rebuild');
            """) }
        // #313. Additive: older builds insert named columns (new ones are nullable or defaulted) and their writes fire the
        // same triggers. Existing user messages count as routed, so history is never routed again.
        // Change sequence: one global counter; every insert and update stamps the row with the next value, in the same
        // statement. The update trigger skips its own stamp (only `seq` changed); nothing else ever writes `seq`.
        migration.registerMigration("sync-r1") { db in
            var sql = """
            ALTER TABLE messages ADD COLUMN readAt DOUBLE; UPDATE messages SET readAt=created WHERE role='user';
            CREATE TABLE changeSeq(id INTEGER PRIMARY KEY CHECK(id=1), value INTEGER NOT NULL); INSERT INTO changeSeq VALUES (1,0);
            CREATE TABLE readCursor(threadID TEXT PRIMARY KEY, messageID TEXT NOT NULL, seq INTEGER NOT NULL DEFAULT 0);
            CREATE VIRTUAL TABLE eventSearch USING fts5(body, content='events', content_rowid='rowid', tokenize='trigram');
            CREATE TRIGGER eventSearch_ai AFTER INSERT ON events BEGIN INSERT INTO eventSearch(rowid,body) VALUES (new.rowid,new.body); END;
            CREATE TRIGGER eventSearch_ad AFTER DELETE ON events BEGIN INSERT INTO eventSearch(eventSearch,rowid,body) VALUES ('delete',old.rowid,old.body); END;
            CREATE TRIGGER eventSearch_au AFTER UPDATE OF body ON events BEGIN INSERT INTO eventSearch(eventSearch,rowid,body) VALUES ('delete',old.rowid,old.body); INSERT INTO eventSearch(rowid,body) VALUES (new.rowid,new.body); END;
            INSERT INTO eventSearch(eventSearch) VALUES ('rebuild');
            """
            for t in Self.synced {
                if t != "readCursor" { sql += "ALTER TABLE \(t) ADD COLUMN seq INTEGER NOT NULL DEFAULT 0;" }
                let stamp = "UPDATE changeSeq SET value=value+1; UPDATE \(t) SET seq=(SELECT value FROM changeSeq) WHERE rowid=new.rowid;"
                // The final touch stamps existing rows with distinct values, so paging by seq never splits a tie.
                sql += """
                CREATE TRIGGER \(t)_seq_ai AFTER INSERT ON \(t) BEGIN \(stamp) END;
                CREATE TRIGGER \(t)_seq_au AFTER UPDATE ON \(t) WHEN new.seq IS old.seq BEGIN \(stamp) END;
                CREATE INDEX \(t)_seq ON \(t)(seq); UPDATE \(t) SET seq=0;
                """
            }
            try db.execute(sql: sql)
        }
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
    static let synced = ["topics","messages","work","events","amendments","readCursor"]
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
    @discardableResult public func message(role: String, body: String, topic: String? = nil, task: String? = nil, replyTo: String? = nil, kind: String = "conversation", id: String = identifier(), notice: Notice? = nil) throws -> Message {
        let m = Message(id: id, role: role, body: body, topicID: topic, taskID: task, replyTo: replyTo, kind: kind, created: Date().timeIntervalSince1970, notice: notice)
        try db.write { try m.insert($0) }; return m
    }
    /// Newest first over message bodies and sub-chat worker event bodies (results are `result` messages; a superseded
    /// answer is an event). Terms of 3+ characters match the trigram indexes (AND, each a quoted phrase); a shorter term
    /// cannot match trigrams, so such a query scans bodies with LIKE. Snippets are plain text with "…" at cuts.
    public func search(_ query: String, limit: Int, offset: Int = 0) throws -> (hits: [SearchHit], total: Int) {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init).prefix(16)
        guard !terms.isEmpty else { return ([],0) }
        let limit = max(1,min(limit,500)), offset = max(0,min(offset,10_000))
        let fts = terms.allSatisfy { $0.count >= 3 }
        let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"",with: "\"\"") + "\"" }.joined(separator: " ")
        let like = terms.map { "%" + $0.replacingOccurrences(of: "\\",with: "\\\\").replacingOccurrences(of: "%",with: "\\%").replacingOccurrences(of: "_",with: "\\_") + "%" }
        let filter = Array(repeating: "t.body LIKE ? ESCAPE '\\'",count: like.count).joined(separator: " AND ")
        func cut(_ body: String) -> String {
            guard let r = body.range(of: terms[0],options: .caseInsensitive) else { return String(body.prefix(48)) }
            let start = body.index(r.lowerBound,offsetBy: -12,limitedBy: body.startIndex) ?? body.startIndex, end = body.index(r.upperBound,offsetBy: 36,limitedBy: body.endIndex) ?? body.endIndex
            return (start == body.startIndex ? "" : "…") + body[start..<end] + (end == body.endIndex ? "" : "…")
        }
        return try db.read { db in
            var hits: [SearchHit] = []; var total = 0
            for (table,index,columns) in [("messages","messageSearch","t.topicID AS topic,t.taskID AS task"),("events","eventSearch","(SELECT topicID FROM work WHERE id=t.taskID) AS topic,t.taskID AS task")] {
                let (from,args): (String,StatementArguments) = fts ? ("\(index) JOIN \(table) t ON t.rowid=\(index).rowid WHERE \(index) MATCH ?",[match]) : ("\(table) t WHERE \(filter)",StatementArguments(like))
                let rows = try Row.fetchAll(db,sql: "SELECT t.id,t.created,t.body,\(columns)\(fts ? ",snippet(\(index),0,'','','…',48) AS s" : "") FROM \(from) ORDER BY t.created DESC,t.rowid DESC LIMIT \(offset + limit)",arguments: args)
                hits += rows.map { row in
                    SearchHit(topicID: row["topic"],taskID: row["task"],messageID: table == "messages" ? row["id"] : nil,eventID: table == "events" ? row["id"] : nil,snippet: fts ? row["s"] : cut(row["body"]),created: row["created"])
                }
                total += try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM \(from)",arguments: args) ?? 0
            }
            return (Array(hits.sorted { $0.created > $1.created }.dropFirst(offset).prefix(limit)),total)
        }
    }
    public func message(id: String) throws -> Message? { try db.read { try Message.fetchOne($0,key: id) } }
    public func topic(id: String) throws -> Topic? { try db.read { try Topic.fetchOne($0,key: id) } }
    /// Stamps the start of routing once (`readAt`); false when it had already started or the message is unknown.
    public func startRouting(_ id: String) throws -> Bool {
        try db.write { db in try db.execute(sql: "UPDATE messages SET readAt=? WHERE id=? AND readAt IS NULL",arguments: [Date().timeIntervalSince1970,id]); return db.changesCount > 0 }
    }
    /// User messages whose routing never started, oldest first. Older builds never set `readAt`, so a message they
    /// already answered, filed in a topic or delegated counts as routed.
    public func unrouted() throws -> [Message] {
        try db.read { try Message.fetchAll($0,sql: "SELECT * FROM messages m WHERE role='user' AND readAt IS NULL AND topicID IS NULL AND NOT EXISTS (SELECT 1 FROM messages r WHERE r.replyTo=m.id) AND NOT EXISTS (SELECT 1 FROM work w WHERE w.messageID=m.id) ORDER BY created,rowid") }
    }
    /// Moves a thread's read cursor forward to `message` in timeline order; false when that is not newer or unknown.
    public func markRead(thread: String, message: String) throws -> Bool {
        try db.write { db in
            guard try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM messages WHERE id=?",arguments: [message]) == 1,
                  try Int.fetchOne(db,sql: "SELECT COUNT(*) FROM readCursor c JOIN messages m ON m.id=c.messageID JOIN messages n ON n.id=? WHERE c.threadID=? AND (m.created,m.rowid)>=(n.created,n.rowid)",arguments: [message,thread]) == 0 else { return false }
            try db.execute(sql: "INSERT INTO readCursor(threadID,messageID) VALUES (?,?) ON CONFLICT(threadID) DO UPDATE SET messageID=excluded.messageID",arguments: [thread,message]); return true
        }
    }
    public func readCursor(thread: String) throws -> String? { try db.read { try String.fetchOne($0,sql: "SELECT messageID FROM readCursor WHERE threadID=?",arguments: [thread]) } }
    /// History window (#313 open question 1, the union): the newest 500 messages plus every message of the last 30 days,
    /// that is every message created at or after `start`. Work: created in it, the task of a windowed message, or
    /// unsuppressed active or uncertain (so it can still be stopped or retried). Topics: created in it or used by
    /// windowed messages or work. Events and amendments: those of windowed work. Read cursors: always.
    private static func scope(_ table: String) -> String {
        let s = "(SELECT s FROM w)"
        let work = "(created>=\(s) OR id IN (SELECT taskID FROM messages WHERE created>=\(s)) OR (suppressed=0 AND state IN ('queued','working','amendment_pending','cancellation_requested','uncertain')))"
        switch table {
        case "messages": return "created>=\(s)"
        case "work": return work
        case "events", "amendments": return "taskID IN (SELECT id FROM work WHERE \(work))"
        case "topics": return "(created>=\(s) OR id IN (SELECT topicID FROM messages WHERE created>=\(s)) OR id IN (SELECT topicID FROM work WHERE \(work)))"
        default: return "1"
        }
    }
    /// Rows of the window changed after `seq`, at most `limit` (1–1000), in sequence order.
    public func changes(after seq: Int64, limit: Int = 200) throws -> ChangePage {
        let limit = max(1,min(limit,1000)), now = Date().timeIntervalSince1970
        return try db.read { db in
            let nth = try Double.fetchOne(db,sql: "SELECT created FROM messages ORDER BY created DESC,rowid DESC LIMIT 1 OFFSET 499")
            let start = min(now - 30 * 86400,nth ?? 0)
            var all: [Change] = []
            for t in Self.synced {
                for row in try Row.fetchAll(db,sql: "WITH w(s) AS (SELECT ?) SELECT * FROM \(t) WHERE seq>? AND \(Self.scope(t)) ORDER BY seq LIMIT ?",arguments: [start,seq,limit + 1]) {
                    all.append(Change(seq: row["seq"],record: try Self.record(t,row)))
                }
            }
            all.sort { $0.seq < $1.seq }
            return ChangePage(changes: Array(all.prefix(limit)),more: all.count > limit,latest: try Int64.fetchOne(db,sql: "SELECT value FROM changeSeq") ?? 0)
        }
    }
    private static func record(_ table: String,_ row: Row) throws -> Change.Record {
        switch table {
        case "topics": return .topic(try Topic(row: row))
        case "messages": return .message(try Message(row: row))
        case "work": return .work(try Work(row: row))
        case "events": return .event(try WorkerEvent(row: row))
        case "amendments": return .amendment(try Amendment(row: row))
        default: return .readCursor(try ReadCursor(row: row))
        }
    }
    /// Up to `before` older and `after` newer messages (each ≤ 500) around one message, in timeline order, inside or
    /// outside the window; nil for an unknown id.
    public func page(around id: String, before: Int = 50, after: Int = 50) throws -> [Change]? {
        try db.read { db in
            guard let at = try Row.fetchOne(db,sql: "SELECT created,rowid FROM messages WHERE id=?",arguments: [id]) else { return nil }
            let c: Double = at[0], r: Int64 = at[1]
            let older = try Row.fetchAll(db,sql: "SELECT * FROM messages WHERE (created,rowid)<(?,?) ORDER BY created DESC,rowid DESC LIMIT ?",arguments: [c,r,max(0,min(before,500))])
            let newer = try Row.fetchAll(db,sql: "SELECT * FROM messages WHERE (created,rowid)>=(?,?) ORDER BY created,rowid LIMIT ?",arguments: [c,r,max(0,min(after,500)) + 1])
            return try (older.reversed() + newer).map { Change(seq: $0["seq"],record: try Self.record("messages",$0)) }
        }
    }
    /// Assign only the newly received, previously unrouted message. Never migrate an old exchange.
    public func assign(message: String, topic: String) throws {
        try db.write { try $0.execute(sql: "UPDATE messages SET topicID=? WHERE id=? AND topicID IS NULL", arguments: [topic,message]) }
    }
    public func insertWork(_ work: Work) throws {
        try db.write { db in
            // One active task per (topic, executor id; NULL = thinking): a long coding run never blocks thinking work in the same topic.
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
    /// `definite`: the Gateway reported how the run ended (e.g. an overflow), so it is failed, not uncertain.
    public func failWork(_ id: String,error: String,definite: Bool = false) throws -> Work? {
        try db.write { db in
            guard var w = try Work.fetchOne(db,key: id), !w.suppressed else { return nil }
            // Bounded to 1,000 UTF-8 bytes on a character boundary: an uncertain row may outlive many routing turns.
            var bounded = error.prefix(1000); while bounded.utf8.count > 1000 { bounded.removeLast() }
            w.state = w.runID == nil || definite ? "failed" : "uncertain"; w.error = String(bounded); try w.update(db); return w
        }
    }
    public func retireForRetry(_ id: String) throws {
        try db.write { db in
            guard var w = try Work.fetchOne(db,key: id), !w.suppressed, ["failed","uncertain"].contains(w.state) else { throw ProjectError.blocked("Work changed during reconciliation; no retry dispatched.") }
            w.suppressed = true; w.state = "failed"; try w.update(db)
        }
    }
    /// Binds the data directory to its run mode on the first send, so live harnesses can be switched over the same data
    /// (#318). Bodies written before #318 hold the harness's display name; they read as their mode. Offline never binds.
    public func bindRuntime(_ mode: RuntimeMode) throws {
        guard mode != .offline else { return }
        let legacy = ["Configured OpenClaw · live acceptance unverified": RuntimeMode.live.rawValue, "Synthetic fixture · NOT a live model": RuntimeMode.fixture.rawValue]
        try db.write { db in
            if let old = try String.fetchOne(db,sql: "SELECT body FROM receipts WHERE id='runtime-binding'"), (legacy[old] ?? old) != mode.rawValue { throw ProjectError.blocked("This workspace belongs to a different harness mode. Use a separate data directory; fixture sessions are not live sessions.") }
            try db.execute(sql: "INSERT OR IGNORE INTO receipts VALUES ('runtime-binding','runtime',?,?)",arguments: [mode.rawValue,Date().timeIntervalSince1970])
        }
    }
    public func updateWork(_ value: Work) throws { try db.write { try value.update($0) } }
    public func work(_ id: String) throws -> Work { try db.read { db in guard let w = try Work.fetchOne(db, key: id) else { throw ProjectError.invalid("Unknown work.") }; return w } }
    public func event(_ event: WorkerEvent) throws { try db.write { try event.insert($0, onConflict: .ignore) } }
    /// The live harness id (`Harness.id`) this data folder last ran on; nil before #318, which means OpenClaw.
    public func lastHarness() throws -> String? { try db.read { try String.fetchOne($0,sql: "SELECT body FROM receipts WHERE id='harness-kind'") } }
    public func recordHarness(_ id: String) throws { try db.write { try $0.execute(sql: "INSERT OR REPLACE INTO receipts VALUES ('harness-kind','harness',?,?)",arguments: [id,Date().timeIntervalSince1970]) } }
    public func requestReceipt(_ value: RequestReceipt) throws { try receipt(kind: "request",body: encoded(value)) }
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
    /// `from`: deliver only if the work is still in that state and unsuppressed, else nothing (a concurrent reconcile won).
    public func finish(task: String, output: WorkerOutput, requeue: Bool = false, from state: String? = nil) throws -> (reply: Message?, followUp: Work?) {
        try db.write { db in
            if let state { guard let w = try Work.fetchOne(db,key: task), w.state == state, !w.suppressed else { return (nil,nil) } }
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
                try Message(id: identifier(),role: "assistant",body: "The task finished without confirming your latest change. Its answer is in the sub-chat.",topicID: w.topicID,taskID: task,replyTo: w.messageID,kind: kind,created: Date().timeIntervalSince1970,notice: Notice(.amendmentUnconfirmed)).insert(db)
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
    /// `reason`: why an `error_no_replay` job failed, already bounded and screened by the caller.
    public func markMemory(_ id: String, state: String, reason: String? = nil) throws {
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO memoryJobs VALUES (?,?)", arguments: [id,state])
            if let reason { try db.execute(sql: "INSERT OR REPLACE INTO memoryJobReasons VALUES (?,?)", arguments: [id,reason]) }
        }
    }
}
