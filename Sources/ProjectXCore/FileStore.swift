import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// The visible file store (#316): `<root>/<YYYY-MM>/<YYYY-MM-DD_HHMMSS>_<sanitized name>` in the Mac's local time, `_2`,
/// `_3`… before the extension on a clash. Live root `~/Yorozu/files`; `<data root>/files` under `PROJECTX_DATA` and in
/// fixture mode. Directories are 0700, files 0600. Files are kept until the user deletes them in Finder.
public struct FileStore: Sendable {
    public let root: URL
    /// Owner decision: at most 10 files per message, each at most 50 MB.
    public static let maxFiles = 10
    public static let maxBytes: Int64 = 50 * 1024 * 1024

    /// Refuses a root inside a git checkout or worktree (any ancestor holding `.git`), so files never land in a repo.
    public init(root: URL) throws {
        let fm = FileManager.default
        var dir = root.standardizedFileURL
        // Resolve symlinks on the nearest existing ancestor; the root itself may not exist yet.
        var missing: [String] = []
        while !fm.fileExists(atPath: dir.path), dir.path != "/" { missing.insert(dir.lastPathComponent, at: 0); dir.deleteLastPathComponent() }
        var resolved = dir.resolvingSymlinksInPath(); for c in missing { resolved.appendPathComponent(c, isDirectory: true) }
        var probe = resolved
        while true {
            if fm.fileExists(atPath: probe.appendingPathComponent(".git").path) { throw ProjectError.blocked("The file store can't be inside a git checkout or worktree (\(probe.path)).") }
            if probe.path == "/" { break }
            probe.deleteLastPathComponent()
        }
        try fm.createDirectory(at: resolved, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.root = resolved
    }

    /// Copies a file the user attached; the row has no owner yet (`Store` sets it).
    public func store(_ file: PendingFile) throws -> Attachment {
        try copy(file.url, name: file.name, mime: file.mime.isEmpty ? Self.mime(for: file.name) : file.mime)
    }
    /// Copies a file a worker returned (any readable path; `~` is expanded).
    public func adopt(path: String) throws -> Attachment {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return try copy(url, name: url.lastPathComponent, mime: Self.mime(for: url.lastPathComponent))
    }
    public func url(for a: Attachment) -> URL { root.appendingPathComponent(a.path, isDirectory: false) }
    public func exists(_ a: Attachment) -> Bool { FileManager.default.isReadableFile(atPath: url(for: a).path) }
    /// Removes a copy no row owns (a failed send or a result that was not delivered).
    func remove(_ a: Attachment) { try? FileManager.default.removeItem(at: url(for: a)) }

    private func copy(_ source: URL, name: String, mime: String) throws -> Attachment {
        let fm = FileManager.default, src = source.resolvingSymlinksInPath()
        let values = try? src.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true, fm.isReadableFile(atPath: src.path) else { throw ProjectError.invalid("“\(name)” is missing or unreadable.") }
        guard Int64(values?.fileSize ?? 0) <= Self.maxBytes else { throw ProjectError.invalid("“\(name)” is over 50 MB.") }
        let now = Date(), month = Self.format(now, "yyyy-MM"), stamp = Self.format(now, "yyyy-MM-dd_HHmmss")
        let dir = root.appendingPathComponent(month, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let clean = Self.sanitize(name)
        for n in 1...10_000 {
            let file = Self.fileName(stamp: stamp, name: clean, suffix: n == 1 ? "" : "_\(n)")
            let dest = dir.appendingPathComponent(file, isDirectory: false)
            do { try fm.copyItem(at: src, to: dest) } catch CocoaError.fileWriteFileExists { continue }
            do {
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
                let (bytes, sha) = try Self.digest(dest)
                guard bytes <= Self.maxBytes else { throw ProjectError.invalid("“\(name)” is over 50 MB.") } // grew while copying
                return Attachment(path: month + "/" + file, name: name, mime: mime, bytes: bytes, sha256: sha, created: now.timeIntervalSince1970)
            } catch { try? fm.removeItem(at: dest); throw error }
        }
        throw ProjectError.blocked("Too many files named “\(name)” this second.")
    }

    /// No `/`, `:` or control characters; Unicode kept; never empty or a dot name.
    static func sanitize(_ name: String) -> String {
        let s = String(String.UnicodeScalarView(name.unicodeScalars.map { $0 == "/" || $0 == ":" || $0.properties.generalCategory == .control ? "_" : $0 }))
            .trimmingCharacters(in: .whitespaces)
        return s.isEmpty || s.allSatisfy({ $0 == "." }) ? "file" : s
    }
    /// `<stamp>_<stem><suffix><.ext>` within APFS's 255 UTF-8 bytes: the stem is cut on a character boundary, and a long
    /// extension (over 32 bytes) counts as stem.
    static func fileName(stamp: String, name: String, suffix: String) -> String {
        let ext = (name as NSString).pathExtension, keepExt = !ext.isEmpty && ext.utf8.count <= 32 && ext.utf8.count + 1 < name.utf8.count
        var stem = keepExt ? String(name.dropLast(ext.count + 1)) : name
        let tail = suffix + (keepExt ? "." + ext : ""), budget = 255 - stamp.utf8.count - 1 - tail.utf8.count
        while stem.utf8.count > budget { stem.removeLast() }
        return stamp + "_" + stem + tail
    }
    static func mime(for name: String) -> String {
        UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType ?? "application/octet-stream"
    }
    private static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = .current; f.dateFormat = pattern
        return f.string(from: date)
    }
    private static func digest(_ url: URL) throws -> (Int64, String) {
        let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
        var hasher = SHA256(), bytes: Int64 = 0
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk); bytes += Int64(chunk.count) }
        return (bytes, hasher.finalize().map { String(format: "%02x", $0) }.joined())
    }
}
