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
    public static let maxBytes: Int64 = 50_000_000 // decimal, as Finder counts; the wire's MessageAttachment.maxBytes matches
    /// Folders (relative to home) never copied from, whoever names the file: keys, credentials and Yorozu's own state.
    /// `~/Library/Application Support/<bundle id>` and the data root are added per store.
    static let deniedFolders: Set = [".ssh", ".gnupg", "Library/Keychains", ".appstoreconnect", ".openclaw", ".hermes", ".aws", ".config/gh"]
    /// Private-key file names: these extensions, and `id_*` with no extension (`id_rsa`, `id_ed25519`).
    static let deniedExtensions: Set = ["pem", "p8", "key"]
    /// Resolved, lowercased (APFS is case-insensitive by default) folders refused, and the ones inside them still allowed:
    /// the store itself and the phone upload staging (`<support>/uploads`, files Yorozu wrote from a paired phone).
    private let denied: [String], allowed: [String]

    /// Refuses a root inside a git checkout or worktree (any ancestor holding `.git`), so files never land in a repo.
    /// `dataRoot` (the app's private state) joins the folders it never copies from.
    public init(root: URL, dataRoot: URL? = nil, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        let support = home.appendingPathComponent("Library/Application Support/" + (Bundle.main.bundleIdentifier ?? "to.yumi.yorozu"), isDirectory: true)
        let key = { (u: URL) in u.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() }
        denied = (Self.deniedFolders.map { home.appendingPathComponent($0, isDirectory: true) } + [support] + (dataRoot.map { [$0] } ?? [])).map(key)
        let uploads = key(support.appendingPathComponent("uploads", isDirectory: true))
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
        allowed = [key(resolved), uploads]
    }

    /// Copies a file the user attached; the row has no owner yet (`Store` sets it).
    public func store(_ file: PendingFile) throws -> Attachment {
        try copy(file.url, name: file.name, mime: file.mime.isEmpty ? Self.mime(for: file.name) : file.mime, guarded: false) // the user chose this file
    }
    /// Copies a file a worker returned (any readable path outside private folders and key files; `~` is expanded): a
    /// worker can be prompt-injected into naming one, and a copy syncs to the phone.
    public func adopt(path: String) throws -> Attachment {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return try copy(url, name: url.lastPathComponent, mime: Self.mime(for: url.lastPathComponent), guarded: true)
    }
    public func url(for a: Attachment) -> URL { root.appendingPathComponent(a.path, isDirectory: false) }
    public func exists(_ a: Attachment) -> Bool { FileManager.default.isReadableFile(atPath: url(for: a).path) }
    /// Removes a copy no row owns (a failed send or a result that was not delivered).
    func remove(_ a: Attachment) { try? FileManager.default.removeItem(at: url(for: a)) }

    private func copy(_ source: URL, name: String, mime: String, guarded: Bool) throws -> Attachment {
        let fm = FileManager.default, src = source.resolvingSymlinksInPath()
        guard !guarded || (!refuses(source) && !refuses(src) && !Self.isKeyName(name)) else { throw ProjectError.blocked("“\(name)” is in a private folder or looks like a key, so Yorozu won't copy it.") }
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

    /// A private-key name, or a path under a denied folder (compared on the given and the resolved path).
    func refuses(_ url: URL) -> Bool {
        if Self.isKeyName(url.lastPathComponent) { return true }
        let path = url.standardizedFileURL.path.lowercased(), under = { (dir: String) in path == dir || path.hasPrefix(dir + "/") }
        return denied.contains(where: under) && !allowed.contains(where: under)
    }
    static func isKeyName(_ name: String) -> Bool {
        let name = name.lowercased(), ext = (name as NSString).pathExtension
        return deniedExtensions.contains(ext) || (name.hasPrefix("id_") && ext.isEmpty)
    }
    /// No `/`, `:` or control characters; Unicode kept; never empty or a dot name.
    public static func sanitize(_ name: String) -> String {
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
