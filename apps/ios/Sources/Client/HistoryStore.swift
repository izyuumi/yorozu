import Foundation
import SQLite3

/// The client's copy of the host's whole history (#405): every record the host sent, one row each, upserted as they arrive,
/// with a full-text index over message and worker-step text for offline search, and the sync state beside them (`meta`).
/// One SQLite file per pairing in `Application Support/History/`, under the same file protection as the pairing; a file
/// another pairing left is wiped, never read. Writes run in order on one queue, a transaction per batch.
final class HistoryStore: @unchecked Sendable {
    /// One record as the host sent it, `json` its wire payload. `text` is what search indexes.
    struct Record: Sendable {
        var kind: String
        var id: String
        var seq: Int
        var ts: Int
        var thread: String?
        var topic: String?
        var text: String?
        var json: Data
    }

    struct Key: Hashable, Sendable {
        var kind: String
        var id: String
    }

    /// A search hit: a message (`kind` `message`) or a worker step (`event`), newest first.
    struct Hit: Sendable, Equatable {
        var kind: String
        var id: String
        var thread: String?
        var topic: String?
        var ts: Int
        var snippet: String
    }

    static let schema = 1
    private let queue = DispatchQueue(label: "yorozu.history")
    private var db: OpaquePointer?
    /// The trigram tokenizer (SQLite 3.34+) matches inside words and any script; without it search scans with LIKE.
    private var trigram = false
    private let folder: URL

    /// Opens (or creates) the store for `owner`, the pairing's session key; another owner's file is removed first.
    /// `adopt`: a Repair of the same host, whose file becomes the new identity's.
    init(owner: String, adopt: Bool = false) {
        folder = clientSupportDirectory.appending(path: "History", directoryHint: .isDirectory)
        queue.sync {
            open()
            if let held = metaString("owner"), (held != owner && !adopt) || metaString("schema") != String(Self.schema) {
                close()
                try? FileManager.default.removeItem(at: folder)
                open()
            }
            setMeta("owner", Data(owner.utf8))
            setMeta("schema", Data(String(Self.schema).utf8))
        }
    }

    deinit { queue.sync { close() } }

    private var file: URL { folder.appending(path: "history.sqlite") }

    private func open() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: folder.path) {
            #if os(iOS)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            #else
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            #endif
            var url = folder
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
        }
        var flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        #if os(iOS)
        flags |= SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
        #endif
        guard sqlite3_open_v2(file.path, &db, flags, nil) == SQLITE_OK else { close(); return }
        exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
        exec("""
            CREATE TABLE IF NOT EXISTS records(kind TEXT NOT NULL, id TEXT NOT NULL, seq INTEGER NOT NULL, ts INTEGER NOT NULL,
              thread TEXT, topic TEXT, text TEXT, json BLOB NOT NULL, PRIMARY KEY(kind,id));
            CREATE INDEX IF NOT EXISTS records_ts ON records(ts);
            CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value BLOB);
            """)
        // The index is made once; a SQLite without trigram makes none and search uses LIKE.
        if exec("CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(text, content='records', content_rowid='rowid', tokenize='trigram')") {
            trigram = true
            exec("""
                CREATE TRIGGER IF NOT EXISTS records_ai AFTER INSERT ON records WHEN new.text IS NOT NULL BEGIN
                  INSERT INTO search(rowid,text) VALUES (new.rowid,new.text); END;
                CREATE TRIGGER IF NOT EXISTS records_ad AFTER DELETE ON records WHEN old.text IS NOT NULL BEGIN
                  INSERT INTO search(search,rowid,text) VALUES ('delete',old.rowid,old.text); END;
                CREATE TRIGGER IF NOT EXISTS records_au AFTER UPDATE OF text ON records BEGIN
                  INSERT INTO search(search,rowid,text) SELECT 'delete',old.rowid,old.text WHERE old.text IS NOT NULL;
                  INSERT INTO search(rowid,text) SELECT new.rowid,new.text WHERE new.text IS NOT NULL; END;
                """)
        }
    }

    private func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Prepares, binds (`String`, `Int`, `Data` or nil) and steps `sql`, calling `row` for each result row.
    @discardableResult
    private func run(_ sql: String, _ args: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        guard let db else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        for (i, arg) in args.enumerated() {
            let index = Int32(i + 1)
            switch arg {
            case let value as String: sqlite3_bind_text(statement, index, value, -1, Self.transient)
            case let value as Int: sqlite3_bind_int64(statement, index, Int64(value))
            case let value as Data: _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
            default: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row?(statement)
            case SQLITE_DONE: return true
            default: return false
            }
        }
    }

    private static func string(_ s: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(s, column).map { String(cString: $0) }
    }

    private static func data(_ s: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(s, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(s, column)))
    }

    private func metaString(_ key: String) -> String? { metaData(key).map { String(decoding: $0, as: UTF8.self) } }

    private func metaData(_ key: String) -> Data? {
        var out: Data?
        run("SELECT value FROM meta WHERE key=?", [key]) { out = Self.data($0, 0) }
        return out
    }

    @discardableResult
    private func setMeta(_ key: String, _ value: Data?) -> Bool {
        if let value { return run("INSERT INTO meta(key,value) VALUES (?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value]) }
        return run("DELETE FROM meta WHERE key=?", [key])
    }

    // MARK: Reading

    /// Every record, oldest first: what the client draws its mirror from at launch, before any network request.
    func loadAll() -> [Record] {
        queue.sync {
            var out: [Record] = []
            run("SELECT kind,id,seq,ts,thread,topic,json FROM records ORDER BY ts,rowid") { s in
                out.append(Record(kind: Self.string(s, 0) ?? "", id: Self.string(s, 1) ?? "", seq: Int(sqlite3_column_int64(s, 2)),
                                  ts: Int(sqlite3_column_int64(s, 3)), thread: Self.string(s, 4), topic: Self.string(s, 5), json: Self.data(s, 6)))
            }
            return out
        }
    }

    var isEmpty: Bool {
        queue.sync {
            var count = 0
            run("SELECT COUNT(*) FROM records") { count = Int(sqlite3_column_int64($0, 0)) }
            return count == 0
        }
    }

    func meta<Value: Decodable>(_ key: String, as type: Value.Type) -> Value? {
        queue.sync { metaData(key).flatMap { try? JSONDecoder().decode(type, from: $0) } }
    }

    // MARK: Writing

    /// One transaction: records upserted (a row only moves forward to a record whose `seq` is not lower, unless `force`),
    /// records removed, and meta values set (nil removes). Runs after earlier writes, off the caller. All or nothing: the
    /// first failure (a full disk, an I/O error) rolls the whole batch back, so the sync cursor in `meta` never runs ahead
    /// of the records; `done` hears whether it committed.
    func write(upserts: [Record], deletes: [Key] = [], meta: [String: Data?] = [:], force: Bool = false, done: @escaping @Sendable (Bool) -> Void = { _ in }) {
        guard !upserts.isEmpty || !deletes.isEmpty || !meta.isEmpty else { return done(true) }
        queue.async { [self] in
            guard exec("BEGIN IMMEDIATE") else { return done(false) }
            var ok = true
            for r in upserts where ok {
                ok = run("""
                    INSERT INTO records(kind,id,seq,ts,thread,topic,text,json) VALUES (?,?,?,?,?,?,?,?)
                    ON CONFLICT(kind,id) DO UPDATE SET seq=excluded.seq,ts=excluded.ts,thread=excluded.thread,topic=excluded.topic,
                      text=excluded.text,json=excluded.json WHERE \(force ? "1" : "excluded.seq>=records.seq")
                    """, [r.kind, r.id, r.seq, r.ts, r.thread, r.topic, r.text, r.json])
            }
            for key in deletes where ok { ok = run("DELETE FROM records WHERE kind=? AND id=?", [key.kind, key.id]) }
            for (key, value) in meta where ok { ok = setMeta(key, value) }
            if ok, exec("COMMIT") { return done(true) }
            exec("ROLLBACK")
            done(false)
        }
    }

    /// Waits for the writes queued so far (a background wake saves before iOS suspends the app).
    func drain() { queue.sync {} }

    /// Removes the file: Remove host and a new pairing.
    func wipe() {
        queue.sync {
            close()
            try? FileManager.default.removeItem(at: folder)
        }
    }

    // MARK: Search

    /// Newest first over message and worker-step text, offline. Terms of 3+ characters match the trigram index (AND, each a
    /// quoted phrase); a shorter term, or a SQLite without trigram, scans with LIKE. At most `limit` hits.
    func search(_ query: String, limit: Int = 200) -> [Hit] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init).prefix(16)
        guard !terms.isEmpty else { return [] }
        return queue.sync {
            var hits: [Hit] = []
            let fts = trigram && terms.allSatisfy { $0.count >= 3 }
            let sql: String, args: [Any?]
            if fts {
                let match = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " ")
                sql = "SELECT r.kind,r.id,r.thread,r.topic,r.ts,r.text FROM search JOIN records r ON r.rowid=search.rowid WHERE search MATCH ? ORDER BY r.ts DESC LIMIT ?"
                args = [match, limit]
            } else {
                let likes = terms.map { "%" + $0.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%" }
                sql = "SELECT kind,id,thread,topic,ts,text FROM records WHERE text IS NOT NULL AND " + Array(repeating: "text LIKE ? ESCAPE '\\'", count: likes.count).joined(separator: " AND ") + " ORDER BY ts DESC LIMIT ?"
                args = likes + [limit]
            }
            run(sql, args) { s in
                hits.append(Hit(kind: Self.string(s, 0) ?? "", id: Self.string(s, 1) ?? "", thread: Self.string(s, 2), topic: Self.string(s, 3),
                                ts: Int(sqlite3_column_int64(s, 4)), snippet: Self.snippet(Self.string(s, 5) ?? "", term: terms[0])))
            }
            return hits
        }
    }

    /// About 80 characters around the first match, on one line, with "…" at the cuts.
    private static func snippet(_ text: String, term: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        guard let r = flat.range(of: term, options: .caseInsensitive) else { return String(flat.prefix(80)) }
        let start = flat.index(r.lowerBound, offsetBy: -24, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: 56, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start == flat.startIndex ? "" : "…") + flat[start..<end] + (end == flat.endIndex ? "" : "…")
    }
}
