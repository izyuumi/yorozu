import CryptoKit
import Foundation

/// The phone's offline copy of what it has already seen: the thread list and one file per
/// thread, AES-GCM sealed under a key its owner keeps in the Keychain. The files themselves
/// live in Application Support, which is readable by anything that reaches the container, so
/// the encryption — not the location — is what protects them.
///
/// A cache is only ever a cache: an unreadable, tampered or stale file reads back as empty
/// rather than throwing, and the next `sync_delta` fills the gap.
public struct ThreadCache: Sendable {
    public let directory: URL
    private let key: SymmetricKey

    public init(directory: URL, key: SymmetricKey) {
        self.directory = directory
        self.key = key
    }

    public func threads() -> [ThreadSummary] {
        read([ThreadSummary].self, from: "threads") ?? []
    }

    public func save(threads: [ThreadSummary]) {
        write(threads, to: "threads")
    }

    /// The threads holding a reply that arrived while they were closed. Sealed like the rest:
    /// which threads are unread is as much of a leak as what is in them.
    public func unread() -> Set<String> {
        read(Set<String>.self, from: "unread") ?? []
    }

    public func save(unread: Set<String>) {
        write(unread, to: "unread")
    }

    public func events(threadId: String) -> [YorozuEvent] {
        read([YorozuEvent].self, from: name(threadId)) ?? []
    }

    public func save(events: [YorozuEvent], threadId: String) {
        write(events, to: name(threadId))
    }

    /// Last event id held per thread: exactly what `sync_request` carries.
    public func lastSeen() -> [String: String] {
        var seen: [String: String] = [:]
        for thread in threads() {
            if let last = events(threadId: thread.id).last { seen[thread.id] = last.id }
        }
        return seen
    }

    /// Percent-encoding keeps a thread id a file name without needing to be reversible.
    private func name(_ threadId: String) -> String {
        "thread-" + (threadId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "unnamed")
    }

    private func url(_ name: String) -> URL {
        directory.appendingPathComponent("\(name).bin")
    }

    private func write(_ value: some Encodable, to name: String) {
        guard let plain = try? JSONEncoder().encode(value),
            let sealed = try? AES.GCM.seal(plain, using: key).combined
        else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? sealed.write(to: url(name), options: .atomic)
    }

    private func read<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let raw = try? Data(contentsOf: url(name)),
            let box = try? AES.GCM.SealedBox(combined: raw),
            let plain = try? AES.GCM.open(box, using: key)
        else { return nil }
        return try? JSONDecoder().decode(type, from: plain)
    }
}
