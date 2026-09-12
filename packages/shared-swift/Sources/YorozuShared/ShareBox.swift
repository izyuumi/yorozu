import Foundation

/// What the share extension hands over. Everything the main app needs to send the share and
/// nothing it could work out for itself: which thread it belongs in, what to say, and the file
/// if one was shared.
public struct SharePayload: Codable, Equatable, Sendable {
    /// The thread to send into, or nil for "New chat" — which the app turns into a draft, so a
    /// share that is never replied to leaves the same nothing behind that backing out of a draft
    /// does.
    public var threadId: String?
    /// The message as the extension composed it: the note the user typed, then the shared text
    /// or URL under it. Empty only when the share is an image and nothing was typed.
    public var text: String
    public var attachment: MessageAttachment?

    public init(threadId: String? = nil, text: String, attachment: MessageAttachment? = nil) {
        self.threadId = threadId
        self.text = text
        self.attachment = attachment
    }
}

/// The App Group container, which is the whole of the conversation between the share extension
/// and the app. The extension writes a ``SharePayload`` here and opens `yorozu://share?token=`;
/// the app — which owns the relay socket and the outbox — reads it and sends it.
///
/// It is a drop box and not a queue: the app drains everything in it whenever it comes to the
/// foreground, so a share whose URL open was swallowed still arrives, just later. That is also
/// why nothing here is a secret the extension needs the Keychain for.
///
/// Every entry point takes its directory rather than finding one, so the round trip can be
/// tested in a temporary directory by something holding no App Group entitlement at all.
public enum ShareBox {
    public static let appGroup = "group.to.yumi.yorozu"

    /// The shared directory, or nil in a process without the entitlement.
    public static func directory(group: String = appGroup) -> URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appending(path: "Share")
    }

    /// Writes one share and returns the token that names it, which is what goes in the URL.
    /// The token is a file name and not a credential: anything that could guess it already
    /// holds the App Group entitlement and could read the directory outright.
    @discardableResult
    public static func write(_ payload: SharePayload, in directory: URL) throws -> String {
        let token = UUID().uuidString
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(payload).write(
            to: directory.appending(path: "\(token).json"),
            // Both ends of this run in the foreground with the phone unlocked, so the strictest
            // protection class is also a free one.
            options: [.atomic, .completeFileProtection]
        )
        return token
    }

    /// Reads the share a token names and removes it, so a share is sent once however many times
    /// the URL is opened.
    ///
    /// The token arrives from a URL any app on the phone can open, so it is checked to be the
    /// shape this wrote rather than joined onto a path as it came: `../` in a file name would
    /// otherwise read and delete whatever it pointed at.
    public static func take(token: String, in directory: URL) -> SharePayload? {
        guard UUID(uuidString: token) != nil else { return nil }
        return take(at: directory.appending(path: "\(token).json"))
    }

    /// Every share waiting, oldest first, removed as they are read. What the app drains on the
    /// way to the foreground: the tapped one, plus any whose URL never landed.
    public static func takeAll(in directory: URL) -> [SharePayload] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey]
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != threadsFile }
            .sorted { created($0) < created($1) }
            .compactMap { take(at: $0) }
    }

    private static func take(at url: URL) -> SharePayload? {
        let payload = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode(SharePayload.self, from: $0)
        }
        // Removed either way: a file that will not decode is one this version cannot send, and
        // leaving it there means trying it again on every foreground forever.
        try? FileManager.default.removeItem(at: url)
        return payload
    }

    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private static let threadsFile = "threads.json"

    /// The thread list the extension's picker offers. Written by the app because the extension
    /// cannot read the encrypted thread cache — it has no Keychain access group, deliberately —
    /// and would have nothing to name a thread with otherwise.
    ///
    /// Only the id and the title, and only of the few threads the picker shows: this file is
    /// plaintext in a second container, so what goes in it is the least that makes the picker
    /// work rather than everything that would fit.
    public static func save(threads: [ThreadSummary], in directory: URL) {
        guard let data = try? JSONEncoder().encode(threads.map(ShareThread.init)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Not `completeFileProtection` like a share: the app writes this whenever a thread list
        // arrives, which happens in the background with the screen locked.
        try? data.write(
            to: directory.appending(path: threadsFile),
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
    }

    public static func threads(in directory: URL) -> [ShareThread] {
        let url = directory.appending(path: threadsFile)
        return (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([ShareThread].self, from: $0)
        } ?? []
    }

    /// Unpairing empties this too. The thread titles and anything half-shared are as much the
    /// pairing's as the cache is, and ``CacheStore`` does not reach in here.
    public static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// A thread as the share sheet needs to know it: enough to name it and to send into it.
public struct ShareThread: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    public init(_ thread: ThreadSummary) {
        self.init(id: thread.id, title: thread.displayTitle)
    }
}
