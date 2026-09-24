import Foundation

/// What the share extension hands over. Everything the main app needs to send the share and
/// nothing it could work out for itself: which thread it belongs in, what to say, and the file
/// if one was shared.
public struct SharePayload: Codable, Equatable, Sendable {
    /// Required for routing. Nil only when decoding a share from the single-host version;
    /// migration must bind it to that original host before a second host can be added.
    public var hostID: HostID?
    /// The thread to send into, or nil for "New chat" — which the app turns into a draft, so a
    /// share that is never replied to leaves the same nothing behind that backing out of a draft
    /// does.
    public var threadId: String?
    /// The message as the extension composed it: the note the user typed, then the shared text
    /// or URL under it. Empty only when the share is an image and nothing was typed.
    public var text: String
    public var attachment: MessageAttachment?

    public init(hostID: HostID? = nil, threadId: String? = nil, text: String, attachment: MessageAttachment? = nil) {
        self.hostID = hostID
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

    /// Every matching share, oldest first, removed as it is read. A destination whose model
    /// is unavailable stays queued until it can be routed, including during migration/repair.
    public static func takeAll(
        in directory: URL, matching predicate: (SharePayload) -> Bool = { _ in true }
    ) -> [SharePayload] {
        payloadFiles(in: directory)
            .sorted { created($0) < created($1) }
            .compactMap { take(at: $0, matching: predicate) }
    }

    private static func take(
        at url: URL, matching predicate: (SharePayload) -> Bool = { _ in true }
    ) -> SharePayload? {
        let payload = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode(SharePayload.self, from: $0)
        }
        if let payload, !predicate(payload) { return nil }
        // Removed either way: a file that will not decode is one this version cannot send, and
        // leaving it there means trying it again on every foreground forever.
        try? FileManager.default.removeItem(at: url)
        return payload
    }

    private static func created(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private static let threadsFile = "threads.json"

    /// One atomic snapshot supplies both host choices and host-qualified thread destinations.
    public static func save(hosts: [ShareHost], threads: [ShareThread], in directory: URL) {
        save(ShareDestinations(hosts: hosts, threads: threads), in: directory)
    }

    /// Legacy writer retained for fixtures. Production publishes host-qualified destinations.
    public static func save(threads: [ThreadSummary], in directory: URL) {
        save(ShareDestinations(hosts: [], threads: threads.map(ShareThread.init)), in: directory)
    }

    public static func destinations(in directory: URL) -> ShareDestinations {
        guard let data = try? Data(contentsOf: directory.appending(path: threadsFile)) else {
            return ShareDestinations(hosts: [], threads: [])
        }
        if let snapshot = try? JSONDecoder().decode(ShareDestinations.self, from: data) { return snapshot }
        // Old arrays decode, but their destinations remain unroutable until explicit migration.
        let legacy = (try? JSONDecoder().decode([ShareThread].self, from: data)) ?? []
        return ShareDestinations(hosts: [], threads: legacy)
    }

    public static func hosts(in directory: URL) -> [ShareHost] { destinations(in: directory).hosts }
    public static func threads(in directory: URL) -> [ShareThread] { destinations(in: directory).threads }

    /// Bind old queued shares and picker rows only to the known original pairing. Call before
    /// adding another host, never as a fallback when receiving a hostless share later.
    @discardableResult
    public static func migrateLegacy(to host: ShareHost, in directory: URL) -> Bool {
        for file in payloadFiles(in: directory) {
            guard let data = try? Data(contentsOf: file),
                  var payload = try? JSONDecoder().decode(SharePayload.self, from: data),
                  payload.hostID == nil else { continue }
            payload.hostID = host.id
            do { try JSONEncoder().encode(payload).write(to: file, options: [.atomic, .completeFileProtection]) }
            catch { return false }
        }
        var snapshot = destinations(in: directory)
        if !snapshot.hosts.contains(where: { $0.id == host.id }) { snapshot.hosts.append(host) }
        snapshot.threads = snapshot.threads.map { thread in
            guard thread.hostID == nil else { return thread }
            var owned = thread
            owned.hostID = host.id
            owned.hostLabel = host.label
            return owned
        }
        return save(snapshot, in: directory)
    }

    /// Remove only one host's published labels and queued content. Other hosts keep their data.
    public static func clear(hostID: HostID, in directory: URL) {
        for file in payloadFiles(in: directory) {
            guard let data = try? Data(contentsOf: file),
                  let payload = try? JSONDecoder().decode(SharePayload.self, from: data),
                  payload.hostID == hostID else { continue }
            try? FileManager.default.removeItem(at: file)
        }
        var snapshot = destinations(in: directory)
        snapshot.hosts.removeAll { $0.id == hostID }
        snapshot.threads.removeAll { $0.hostID == hostID }
        save(snapshot, in: directory)
    }

    public static func clear(in directory: URL) {
        try? FileManager.default.removeItem(at: directory)
    }

    @discardableResult
    private static func save(_ snapshot: ShareDestinations, in directory: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(snapshot).write(
                to: directory.appending(path: threadsFile),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
            )
            return true
        } catch { return false }
    }

    private static func payloadFiles(in directory: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.creationDateKey]
        )) ?? []).filter {
            $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil
        }
    }
}

public struct ShareHost: Codable, Equatable, Sendable, Identifiable {
    public var id: HostID
    public var label: String

    public init(id: HostID, label: String) {
        self.id = id
        self.label = label
    }
}

public struct ShareDestinations: Codable, Equatable, Sendable {
    public var hosts: [ShareHost]
    public var threads: [ShareThread]

    public init(hosts: [ShareHost], threads: [ShareThread]) {
        self.hosts = hosts
        self.threads = threads
    }
}

/// Only the names and destination IDs the share sheet needs, never the encrypted chat cache.
public struct ShareThread: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var hostID: HostID?
    public var hostLabel: String?

    public var destination: HostThreadID? {
        hostID.map { HostThreadID(hostID: $0, threadID: id) }
    }

    public init(id: String, title: String, hostID: HostID? = nil, hostLabel: String? = nil) {
        self.id = id
        self.title = title
        self.hostID = hostID
        self.hostLabel = hostLabel
    }

    public init(_ thread: ThreadSummary) {
        self.init(id: thread.id, title: thread.displayTitle)
    }
}
