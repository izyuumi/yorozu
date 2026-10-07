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
    text.range(of: #"(?i)(-----BEGIN .*PRIVATE KEY|\b(?:sk-|ghp_|github_pat_|xox[baprs]-)[A-Za-z0-9_-]{12,}|\b(?:password|api.?key|access.?token|recovery.?code|otp)\s*[:=]\s*\S+)"#, options: .regularExpression) != nil
}

/// Only relative UUID Markdown paths are accepted. Filesystem descriptors prevent symlink traversal.
/// Advisory flock serializes app writers; CAS detects stale reads. External editors must cooperate
/// for a formal no-race guarantee (no filesystem CAS exists for uncooperative replacements).
public actor MemoryStore {
    public let root: URL
    private let index: DatabaseQueue
    public init(dataRoot: URL) throws {
        root = dataRoot.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ProjectError.blocked("Memory root cannot be a symlink.") }
        index = try DatabaseQueue(path: dataRoot.appendingPathComponent("memory-index.sqlite").path)
        try index.write { db in
            try db.execute(sql: "CREATE TABLE IF NOT EXISTS discovery(id TEXT PRIMARY KEY,title TEXT NOT NULL,summary TEXT NOT NULL,path TEXT UNIQUE NOT NULL); CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(id UNINDEXED,title,summary)")
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
    private func bytes(_ parent: Int32, _ name: String) throws -> Data? {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if fd < 0 && errno == ENOENT { return nil }
        guard fd >= 0 else { throw ProjectError.blocked("Unsafe memory file.") }; defer { close(fd) }
        var st = stat(); guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1, st.st_size <= 12000 else { throw ProjectError.blocked("Unsafe or oversized memory file.") }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try h.readToEnd() ?? Data()
        guard data.count <= 12000 else { throw ProjectError.invalid("Memory exceeds limit.") }; return data
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
        try scoped { fd in try parent(fd,path,create: true) { dir,name in
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
            let data = Data(try doc.markdown.utf8); guard data.count <= 12000 else { throw ProjectError.invalid("Preserved lineage exceeds memory limit.") }
            try rebuildLocked() // malformed unrelated files fail before mutation
            if let existing = try index.read({ try String.fetchOne($0, sql: "SELECT path FROM discovery WHERE id=?", arguments: [doc.metadata.id]) }), existing != path { throw ProjectError.invalid("Memory ID belongs to another path.") }
            let temporary = ".projectx-" + identifier() + ".tmp"
            let out = openat(dir,temporary,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,0o600)
            guard out >= 0 else { throw ProjectError.blocked("Cannot create memory temporary file.") }
            defer { close(out); unlinkat(dir,temporary,0) }
            try FileHandle(fileDescriptor: out,closeOnDealloc: false).write(contentsOf: data)
            guard fsync(out) == 0 else { throw ProjectError.blocked("Memory sync failed before replacement.") }
            guard try bytes(dir,name).map(digest) == expectedSHA256 else { throw ProjectError.conflict("Memory changed during write; nothing overwritten.") }
            guard renameat(dir,temporary,dir,name) == 0 else { throw ProjectError.blocked("Atomic memory replacement failed.") }
            _ = fsync(dir)
            do { try rebuildLocked(); return MemoryWriteResult(path: path,sha256: digest(data),indexed: true) }
            catch { return MemoryWriteResult(path: path,sha256: digest(data),indexed: false) } // never replay a real write
        } }
    }
    @discardableResult public func rebuild() throws -> Int { try scoped { _ in try rebuildLocked() } }
    @discardableResult private func rebuildLocked() throws -> Int {
        var rows: [(String,String,String,String)] = []; var ids = Set<String>()
        guard let enumeration = FileManager.default.enumerator(at: root,includingPropertiesForKeys: [.isSymbolicLinkKey,.isRegularFileKey]) else { throw ProjectError.blocked("Cannot enumerate memory.") }
        for case let url as URL in enumeration {
            let attributes = try url.resourceValues(forKeys: [.isSymbolicLinkKey,.isRegularFileKey])
            guard attributes.isSymbolicLink != true else { throw ProjectError.blocked("Memory symlink refused.") }
            guard url.pathExtension == "md" else { continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            let fd = open(root.path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW); guard fd >= 0 else { throw ProjectError.blocked("Memory root changed.") }; defer { close(fd) }
            let data = try parent(fd,relative) { try bytes($0,$1) }
            guard let data else { continue }
            let doc = try MemoryDocument.parse(String(decoding: data,as: UTF8.self))
            guard doc.metadata.id + ".md" == url.lastPathComponent, ids.insert(doc.metadata.id).inserted else { throw ProjectError.invalid("Duplicate or mismatched memory identity.") }
            // Only discovery data lives in this disposable DB.
            rows.append((doc.metadata.id,doc.metadata.title,String(doc.body.prefix(200)),relative))
        }
        try index.write { db in
            try db.execute(sql: "DELETE FROM discovery; DELETE FROM search")
            for row in rows {
                try db.execute(sql: "INSERT INTO discovery VALUES (?,?,?,?)", arguments: [row.0,row.1,row.2,row.3])
                try db.execute(sql: "INSERT INTO search(id,title,summary) VALUES (?,?,?)", arguments: [row.0,row.1,row.2])
            }
        }; return rows.count
    }
    public func search(_ query: String, limit: Int = 8) throws -> [MemoryHit] {
        let terms = query.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 3 }.prefix(24)
        let paths: [String] = try index.read { db in
            if terms.isEmpty { return try String.fetchAll(db, sql: "SELECT path FROM discovery ORDER BY id LIMIT ?", arguments: [min(8,max(1,limit))]) }
            let match = terms.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
            return try String.fetchAll(db, sql: "SELECT d.path FROM search s JOIN discovery d ON d.id=s.id WHERE search MATCH ? ORDER BY bm25(search),d.id LIMIT ?", arguments: [match,min(8,max(1,limit))])
        }
        var hits: [MemoryHit] = []; var size = 0
        for path in paths {
            let value = try read(path: path); let doc = try MemoryDocument.parse(value.markdown)
            size += value.markdown.utf8.count; if size > 10000 { break }
            hits.append(MemoryHit(id: doc.metadata.id,title: doc.metadata.title,path: path,sha256: value.sha256,document: doc))
        }; return hits
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
