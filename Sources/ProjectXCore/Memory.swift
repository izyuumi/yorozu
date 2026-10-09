import Foundation
import CryptoKit
import GRDB
import Darwin

public struct MemoryLineage: Codable, Sendable {
    public var body: String; public var sources: [String]; public var attribution: String; public var epistemicStatus: String; public var replaced: Double
}
public struct MemoryMetadata: Codable, Sendable {
    public var id: String; public var title: String; public var topicID: String?; public var sources: [String]
    public var evidence: String?; public var knowledgeType: String; public var attribution: String; public var epistemicStatus: String
    public var created: Double; public var updated: Double; public var lineage: [MemoryLineage]
    public init(id: String = identifier(), title: String, topicID: String? = nil, sources: [String] = [], evidence: String? = nil, knowledgeType: String = "generated_analysis", attribution: String = "assistant", epistemicStatus: String = "unverified") {
        self.id = id; self.title = title; self.topicID = topicID; self.sources = sources; self.evidence = evidence; self.knowledgeType = knowledgeType; self.attribution = attribution; self.epistemicStatus = epistemicStatus
        created = Date().timeIntervalSince1970; updated = created; lineage = []
    }
}
public struct MemoryDocument: Codable, Sendable {
    public var metadata: MemoryMetadata; public var body: String
    public init(metadata: MemoryMetadata, body: String) { self.metadata = metadata; self.body = body }
    public var markdown: String { get throws { try encoded(metadata) + "\n\n" + body } }
    public static func parse(_ value: String) throws -> Self {
        guard value.utf8.count <= 12000, let r = value.range(of: "\n\n") else { throw ProjectError.invalid("Invalid canonical Markdown.") }
        let meta = try JSONDecoder().decode(MemoryMetadata.self, from: Data(value[..<r.lowerBound].utf8))
        return Self(metadata: meta, body: String(value[r.upperBound...]))
    }
}
public struct MemoryHit: Codable, Sendable {
    public var id: String; public var title: String; public var path: String; public var sha256: String; public var document: MemoryDocument
}
public struct MemoryRead: Codable, Sendable { public var path: String; public var markdown: String; public var sha256: String }
public struct MemoryWriteResult: Codable, Sendable { public var path: String; public var sha256: String; public var indexed: Bool }
public struct MemoryCall: Codable, Sendable {
    public var tool: String; public var path: String?; public var query: String?; public var markdown: String?; public var expectedSHA256: String?
    public init(tool: String, path: String? = nil, query: String? = nil, markdown: String? = nil, expectedSHA256: String? = nil) { self.tool = tool; self.path = path; self.query = query; self.markdown = markdown; self.expectedSHA256 = expectedSHA256 }
}
public struct MemoryProposal: Codable, Sendable {
    public var sourceID: String; public var quote: String; public var title: String; public var body: String
    public var knowledgeType: String; public var attribution: String; public var epistemicStatus: String
    public var replacesID: String?
    public init(sourceID: String, quote: String, title: String, body: String, knowledgeType: String, attribution: String, epistemicStatus: String, replacesID: String? = nil) {
        self.sourceID = sourceID; self.quote = quote; self.title = title; self.body = body; self.knowledgeType = knowledgeType; self.attribution = attribution; self.epistemicStatus = epistemicStatus; self.replacesID = replacesID
    }
}
public func digest(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
public func sensitive(_ text: String) -> Bool {
    // Also env-style (FOO_TOKEN=), JSON keys ("token": "..."), bearer headers and AWS keys: coding output tails are stored.
    text.range(of: #"(?i)(-----BEGIN .*PRIVATE KEY|\b(?:sk-|ghp_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{12,}|\b(?:password|api.?key|access.?token|recovery.?code|otp)\s*[:=]\s*\S+|(?<![A-Za-z0-9])(?:passwd|secret|token|api.?key|authorization)["\x27]?\s*[:=]\s*["\x27]?(?:bearer\s+)?[A-Za-z0-9._~+/=-]{8,}|\bbearer\s+[A-Za-z0-9._~+/=-]{16,}|\bAKIA[0-9A-Z]{16})"#, options: .regularExpression) != nil
}

/// A memory file or folder that stops startup or a rebuild, named so the user can fix it (#317, `PlainError`).
public struct MemoryFileError: LocalizedError, Sendable {
    public var file: String, reason: String
    public var errorDescription: String? { reason + ": " + file }
}

/// Only relative UUID Markdown paths are accepted. Filesystem descriptors prevent symlink traversal.
/// Advisory flock serializes app writers; CAS detects stale reads. External editors must cooperate
/// for a formal no-race guarantee (no filesystem CAS exists for uncooperative replacements).
public actor MemoryStore {
    public let root: URL
    private let index: DatabaseQueue
    /// Relative paths of notes left out because they are oversized or unparseable: refreshed by every rebuild, extended by search.
    public private(set) var skipped: [String] = []
    /// Explicit data roots and tests keep the Markdown and its index together.
    public init(dataRoot: URL) throws {
        try self.init(root: dataRoot.appendingPathComponent("memory", isDirectory: true),index: dataRoot.appendingPathComponent("memory-index.sqlite"))
    }
    /// `root` holds the user-owned Markdown; `index` is the disposable discovery database (rebuilt every launch).
    public init(root: URL, index indexURL: URL) throws {
        self.root = root
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw MemoryFileError(file: root.path, reason: "Memory root cannot be a symlink") }
        try FileManager.default.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        index = try DatabaseQueue(path: indexURL.path)
        try index.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS discovery(id TEXT PRIMARY KEY,title TEXT NOT NULL,summary TEXT NOT NULL,path TEXT UNIQUE NOT NULL); CREATE VIRTUAL TABLE IF NOT EXISTS search_trigram USING fts5(id UNINDEXED,title,summary,tokenize='trigram')") // `search` (pre-trigram) is left for older builds sharing this cache
        }
    }
    private func scoped<T>(_ body: (Int32) throws -> T) throws -> T {
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ProjectError.blocked("Unsafe memory root.") }; defer { close(fd) }
        let lock = openat(fd, ".writer.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw ProjectError.blocked("Memory lock unavailable.") }; defer { close(lock) }
        guard flock(lock, LOCK_EX) == 0 else { throw ProjectError.blocked("Memory lock unavailable.") }; defer { flock(lock, LOCK_UN) }
        return try body(fd)
    }
    private func parent<T>(_ rootFD: Int32, _ path: String, create: Bool = false, body: (Int32, String) throws -> T) throws -> T {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), parts.count <= 5, let name = parts.last, name.hasSuffix(".md"), UUID(uuidString: String(name.dropLast(3))) != nil,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil }) else { throw ProjectError.invalid("Only relative UUID Markdown paths within memory are allowed.") }
        var fd = dup(rootFD); guard fd >= 0 else { throw ProjectError.blocked("Memory descriptor unavailable.") }; defer { close(fd) }
        for part in parts.dropLast() {
            if create { if mkdirat(fd, part, 0o700) != 0 && errno != EEXIST { throw ProjectError.blocked("Cannot create memory directory.") } }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            guard next >= 0 else { throw ProjectError.blocked("Unsafe memory directory.") }; close(fd); fd = next
        }
        return try body(fd,name)
    }
    private func bytes(_ parent: Int32, _ name: String, limit: Int = 12000) throws -> Data? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw ProjectError.blocked("Unsafe memory file.") }; defer { close(fd) }
        var st = stat(); guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_size <= limit else { throw ProjectError.blocked("Unsafe or oversized memory file.") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try h.readToEnd() ?? Data()
        guard data.count <= limit else { throw ProjectError.invalid("Memory exceeds limit.") }; return data
    }
    /// Temp file, fsync, `check`, `renameat`, fsync of the directory.
    private func replace(_ dir: Int32, _ name: String, _ data: Data, check: () throws -> Void = {}) throws {
        let temporary = ".projectx-" + identifier() + ".tmp"
        let out = openat(dir,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
        guard out >= 0 else { throw ProjectError.blocked("Cannot create memory temporary file.") }
        defer { close(out); unlinkat(dir,temporary,0) }
        try FileHandle(fileDescriptor: out,closeOnDealloc: false).write(contentsOf: data)
        guard fsync(out) == 0 else { throw ProjectError.blocked("Memory sync failed before replacement.") }
        try check()
        guard renameat(dir,temporary,dir,name) == 0 else { throw ProjectError.blocked("Atomic memory replacement failed.") }
        _ = fsync(dir)
    }
    public func read(path: String) throws -> MemoryRead {
        try scoped { fd in try parent(fd,path) { dir,name in
            guard let data = try bytes(dir,name), let text = String(data: data, encoding: .utf8), !sensitive(text) else { throw ProjectError.invalid("Memory unavailable or sensitive content withheld.") }
            return MemoryRead(path: path, markdown: text, sha256: digest(data))
        } }
    }
    private func validate(_ doc: MemoryDocument, path: String, sources: [Message]) throws {
        let m = doc.metadata
        let types = ["user_fact","user_preference","user_decision","user_belief","source_claim","generated_analysis","topic_synthesis","tentative_hypothesis"]
        guard UUID(uuidString: m.id) != nil, path.split(separator: "/").last == Substring(m.id + ".md"), !m.title.isEmpty, m.title.count <= 120,
              !doc.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, doc.body.utf8.count <= 8000,
              types.contains(m.knowledgeType), ["user","assistant","quoted_source"].contains(m.attribution), ["user_stated","unverified","tentative"].contains(m.epistemicStatus), m.sources.count <= 16,
              m.sources.allSatisfy({ id in sources.contains { $0.id == id } }), !sensitive(try doc.markdown) else { throw ProjectError.invalid("Invalid memory identity, attribution, evidence or size.") }
        if m.attribution == "user" || m.knowledgeType.hasPrefix("user_") {
            guard m.attribution == "user", m.knowledgeType.hasPrefix("user_"), m.epistemicStatus == "user_stated", let quote = m.evidence, !quote.isEmpty,
                  sources.contains(where: { m.sources.contains($0.id) && $0.role == "user" && $0.body.contains(quote) && $0.body.range(of: #"(?i)(quoted|pasted|according to|source says|article says|^>)"#, options: .regularExpression) == nil }) else { throw ProjectError.invalid("A generated or quoted claim cannot become a user belief.") }
        } else {
            guard m.epistemicStatus != "user_stated", m.knowledgeType != "source_claim" || m.attribution == "quoted_source",
                  m.knowledgeType != "generated_analysis" || m.attribution == "assistant", m.knowledgeType != "tentative_hypothesis" || m.epistemicStatus == "tentative" else { throw ProjectError.invalid("Inconsistent memory provenance.") }
        }
    }
    public func write(path: String, markdown: String, expectedSHA256: String?, sources: [Message] = []) throws -> MemoryWriteResult {
        guard !path.lowercased().hasPrefix("history/") else { throw ProjectError.invalid("Note history is not writable.") }
        return try scoped { fd in try parent(fd,path,create: true) { dir,name in
            let old = try bytes(dir,name)
            guard old.map(digest) == expectedSHA256 else { throw ProjectError.conflict("Memory changed. Read current Markdown and reconcile; nothing overwritten.") }
            var doc = try MemoryDocument.parse(markdown)
            try validate(doc,path: path,sources: sources)
            if let old {
                let previous = try MemoryDocument.parse(String(decoding: old, as: UTF8.self))
                guard previous.metadata.id == doc.metadata.id, previous.metadata.attribution == doc.metadata.attribution, previous.metadata.knowledgeType == doc.metadata.knowledgeType else { throw ProjectError.invalid("Cannot overwrite memory identity or cross attribution/type boundaries.") }
                doc.metadata.created = previous.metadata.created
                doc.metadata.lineage = previous.metadata.lineage + [MemoryLineage(body: previous.body,sources: previous.metadata.sources,attribution: previous.metadata.attribution,epistemicStatus: previous.metadata.epistemicStatus,replaced: Date().timeIntervalSince1970)]
            } else { doc.metadata.lineage = [] }
            doc.metadata.updated = Date().timeIntervalSince1970
            var moved: [MemoryLineage] = [] // oldest versions leave the note only when it would exceed its cap
            while try doc.markdown.utf8.count > 12000, !doc.metadata.lineage.isEmpty { moved.append(doc.metadata.lineage.removeFirst()) }
            let data = Data(try doc.markdown.utf8); guard data.count <= 12000 else { throw ProjectError.invalid("Memory exceeds limit.") }
            try rebuildLocked() // refreshes the id → path index for the ownership check
            if let existing = try index.read({ try String.fetchOne($0, sql: "SELECT path FROM discovery WHERE id=?", arguments: [doc.metadata.id]) }), existing != path { throw ProjectError.invalid("Memory ID belongs to another path.") }
            // History lands before the note: a crash or conflict after this leaves a duplicate entry, never a lost version.
            if !moved.isEmpty { try parent(fd,"history/" + doc.metadata.id + ".md",create: true) { hdir,hname in
                let entries = moved.map { "## Replaced \(ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: $0.replaced)))\n\n- attribution: \($0.attribution)\n- epistemicStatus: \($0.epistemicStatus)\n- sources: \($0.sources.joined(separator: ", "))\n\n\($0.body)\n\n" }
                try replace(hdir,hname,(try bytes(hdir,hname,limit: .max) ?? Data()) + Data(entries.joined().utf8))
            } }
            try replace(dir,name,data) { guard try bytes(dir,name).map(digest) == expectedSHA256 else { throw ProjectError.conflict("Memory changed during write; nothing overwritten.") } }
            do { try rebuildLocked(); return MemoryWriteResult(path: path,sha256: digest(data),indexed: true) }
            catch { return MemoryWriteResult(path: path,sha256: digest(data),indexed: false) } // never replay a real write
        } }
    }
    @discardableResult public func rebuild() throws -> Int { try scoped { _ in try rebuildLocked() } }
    @discardableResult private func rebuildLocked() throws -> Int {
        var rows: [(String,String,String,String)] = []; var ids = Set<String>(); var skip: [String] = []
        guard let enumeration = FileManager.default.enumerator(at: root,includingPropertiesForKeys: [.isSymbolicLinkKey,.isRegularFileKey]) else { throw ProjectError.blocked("Cannot enumerate memory.") }
        for case let url as URL in enumeration {
            let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey,.isRegularFileKey])
            guard attributes.isSymbolicLink != true else { throw MemoryFileError(file: url.path, reason: "Memory symlink refused") }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if relative.lowercased() == "history" { enumeration.skipDescendants(); continue } // past versions, never indexed
            guard url.pathExtension == "md" else { continue }
            let fd = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW); guard fd >= 0 else { throw ProjectError.blocked("Memory root changed.") }; defer { close(fd) }
            let doc: MemoryDocument
            do {
                guard let data = try parent(fd,relative,body: { try bytes($0,$1) }) else { continue }
                doc = try MemoryDocument.parse(String(decoding: data,as: UTF8.self))
                guard doc.metadata.id + ".md" == url.lastPathComponent else { throw ProjectError.invalid("Mismatched memory identity.") }
            } catch { skip.append(relative); continue } // oversized, unparseable or misnamed: reported, not fatal
            guard ids.insert(doc.metadata.id).inserted else { throw MemoryFileError(file: url.path, reason: "Duplicate memory identity") }
            // Only discovery data lives in this disposable DB.
            rows.append((doc.metadata.id,doc.metadata.title,String(doc.body.prefix(200)),relative))
        }
        skipped = skip
        try index.write { db in
            try db.execute(sql: "DELETE FROM discovery; DELETE FROM search_trigram")
            for row in rows {
                try db.execute(sql: "INSERT INTO discovery VALUES (?,?,?,?)", arguments: [row.0,row.1,row.2,row.3])
                try db.execute(sql: "INSERT INTO search_trigram(id,title,summary) VALUES (?,?,?)", arguments: [row.0,row.1,row.2])
            }
        }; return rows.count
    }
    public func search(_ query: String, limit: Int = 8) throws -> [MemoryHit] {
        let (phrases,short) = Self.terms(query); let limit = min(8,max(1,limit))
        let paths: [String] = try index.read { db in
            var paths = phrases.isEmpty ? [] : try String.fetchAll(db, sql: "SELECT d.path FROM search_trigram s JOIN discovery d ON d.id=s.id WHERE search_trigram MATCH ? ORDER BY bm25(search_trigram),d.id LIMIT ?", arguments: [phrases.map { "\"" + $0 + "\"" }.joined(separator: " OR "),limit])
            if !short.isEmpty, paths.count < limit { // trigram cannot match 1–2 characters: substring scan, ranked by terms matched
                let rest = try String.fetchAll(db, sql: "SELECT path FROM (SELECT path,id,\(short.map { _ in "(title||' '||summary LIKE ?)" }.joined(separator: "+")) AS n FROM discovery) WHERE n>0 ORDER BY n DESC,id LIMIT ?", arguments: StatementArguments(short.map { "%" + $0 + "%" }) + [limit + paths.count])
                paths += rest.filter { !paths.contains($0) }
            }
            return Array(paths.prefix(limit))
        }
        var hits: [MemoryHit] = []; var size = 0
        for path in paths {
            guard let value = try? read(path: path), let doc = try? MemoryDocument.parse(value.markdown) else { if !skipped.contains(path) { skipped.append(path) }; continue }
            guard size + value.markdown.utf8.count <= 10000 else { continue }; size += value.markdown.utf8.count
            hits.append(MemoryHit(id: doc.metadata.id,title: doc.metadata.title,path: path,sha256: value.sha256,document: doc))
        }; return hits
    }
    /// Words of 3+ letters or digits as they are; kana/kanji runs (unspaced) as overlapping 3-character windows, dropping all-hiragana
    /// windows of mixed runs (mostly grammar); 1–2-character kana/kanji runs (a lone hiragana is a particle and dropped) and
    /// 2-character kanji/katakana stretches between hiragana in longer runs (東京 in 東京で) go to `short`.
    static func terms(_ query: String) -> (phrases: [String], short: [String]) {
        var runs: [(text: String, cjk: Bool)] = []; var gap = true
        for c in query {
            guard c.isLetter || c.isNumber else { gap = true; continue }
            let cjk = c.unicodeScalars.first.map { $0.properties.isIdeographic || (0x3040...0x30FF).contains($0.value) } ?? false
            if !gap, runs.last?.cjk == cjk { runs[runs.count - 1].text.append(c) } else { runs.append((String(c),cjk)) }
            gap = false
        }
        let hiragana = { (s: String) in s.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) } }
        var phrases: [String] = [], short: [String] = [], seen = Set<String>()
        for run in runs {
            let c = Array(run.text)
            if !run.cjk { if c.count >= 3 { phrases.append(run.text.lowercased()) } }
            else if c.count < 3 { if !hiragana(run.text) { short.append(run.text) } } // hiragana-only 1–2 characters are grammar (の, から)
            else { phrases += (0...c.count - 3).map { String(c[$0..<$0 + 3]) }.filter { hiragana(run.text) || !hiragana($0) }
                short += run.text.split(whereSeparator: { hiragana(String($0)) }).filter { $0.count == 2 }.map(String.init) }
        }
        return (Array(phrases.filter { seen.insert($0).inserted }.prefix(64)),Array(short.filter { seen.insert($0).inserted }.prefix(16)))
    }
    public func byID(_ id: String) throws -> MemoryRead {
        guard let path = try index.read({ try String.fetchOne($0, sql: "SELECT path FROM discovery WHERE id=?", arguments: [id]) }) else { throw ProjectError.invalid("Memory not found.") }
        return try read(path: path)
    }
    public func forget(id: String, expectedSHA256: String) throws {
        try scoped { fd in
            guard let path = try index.read({ try String.fetchOne($0, sql: "SELECT path FROM discovery WHERE id=?", arguments: [id]) }) else { throw ProjectError.invalid("Memory not found.") }
            try parent(fd,path) { dir,name in
                guard try bytes(dir,name).map(digest) == expectedSHA256 else { throw ProjectError.conflict("Memory changed before forget. Nothing deleted.") }
                guard unlinkat(dir,name,0) == 0 else { throw ProjectError.blocked("Memory deletion failed.") }
            }
            // Forget includes the note's past versions.
            let history = openat(fd,"history",O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if history >= 0 { _ = unlinkat(history,id + ".md",0); close(history) }
            try rebuildLocked()
        }
    }
    public func invoke(_ call: MemoryCall, sources: [Message]) throws -> String {
        switch call.tool {
        case "memory.search": return try encoded(search(String((call.query ?? "").prefix(200))))
        case "memory.read": guard let path = call.path else { throw ProjectError.invalid("Missing relative path.") }; return try encoded(read(path: path))
        case "memory.write": guard let path = call.path, let markdown = call.markdown else { throw ProjectError.invalid("Missing Markdown/path.") }; return try encoded(write(path: path,markdown: markdown,expectedSHA256: call.expectedSHA256,sources: sources))
        default: throw ProjectError.blocked("Only scoped memory search/read/write is authorized; no generic filesystem or history edits.")
        }
    }
}
