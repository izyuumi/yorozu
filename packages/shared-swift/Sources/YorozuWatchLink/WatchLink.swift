import Foundation

/// What the phone and the watch say to each other.
///
/// The watch holds no pairing with any Mac, no relay socket and no thread cache: it asks the
/// phone, over WatchConnectivity, and the phone does what it would have done for its own
/// composer. Nothing is pushed and nothing is kept: the watch asks while the phone is reachable
/// and holds the answer in memory.
///
/// Encryption is the system's. WatchConnectivity carries messages between a watch and the phone
/// it is paired with, encrypted end to end between the two devices, and delivers them only to
/// the same developer's app on the other side. Nothing is added on top of that here.
public enum WatchLink {
    /// The one key of every message dictionary: a request or a response, as JSON.
    public static let payloadKey = "payload"
    public static let maxTextLength = 4000

    public static func encode<T: Encodable>(_ value: T) throws -> [String: Any] {
        [payloadKey: try JSONEncoder().encode(value)]
    }

    /// Nil when the dictionary carries no payload or the payload is not a `T`.
    public static func decode<T: Decodable>(_ type: T.Type, from message: [String: Any]) -> T? {
        (message[payloadKey] as? Data).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

// MARK: - Wire

/// One row of the watch's list. Identified by host and thread together: two Macs may hold the
/// same thread id.
public struct WatchThread: Codable, Hashable, Sendable, Identifiable {
    public var host: String
    public var thread: String
    public var title: String
    public var preview: String?
    /// Set only when more than one Mac is paired, as on the phone.
    public var hostLabel: String?
    public var unread: Bool

    public var id: String { "\(host)/\(thread)" }

    public init(host: String, thread: String, title: String, preview: String?, hostLabel: String?, unread: Bool) {
        self.host = host
        self.thread = thread
        self.title = title
        self.preview = preview
        self.hostLabel = hostLabel
        self.unread = unread
    }
}

public struct WatchMessage: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var fromUser: Bool
    public var text: String
    public init(id: String, fromUser: Bool, text: String) {
        self.id = id
        self.fromUser = fromUser
        self.text = text
    }
}

public struct WatchRequest: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case threads, messages, send }
    public var kind: Kind
    /// Random per request. The phone sends a given id once, however often it is delivered.
    public var id: String
    /// Empty for `threads`, which is about no thread in particular.
    public var host: String
    public var thread: String
    public var text: String?

    public init(kind: Kind, id: String = UUID().uuidString, host: String = "", thread: String = "",
                text: String? = nil) {
        self.kind = kind
        self.id = id
        self.host = host
        self.thread = thread
        self.text = text
    }

    /// The reply as it may be sent, or nil: trimmed, not empty, not longer than a message is.
    /// The phone checks this on what it received, whatever the watch checked before sending.
    public var sendableText: String? {
        guard kind == .send, let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= WatchLink.maxTextLength else { return nil }
        return text
    }
}

public struct WatchResponse: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// A `threads` or `messages` request answered.
        case ok
        /// The Mac has the reply.
        case sent
        /// The phone has it, durably, and sends it when the Mac can be reached.
        case queued
        /// Refused: malformed, or about a thread the phone does not hold.
        case rejected
    }
    public var status: Status
    /// The newest threads, newest first.
    public var threads: [WatchThread]?
    public var messages: [WatchMessage]?
    public init(status: Status, threads: [WatchThread]? = nil, messages: [WatchMessage]? = nil) {
        self.status = status
        self.threads = threads
        self.messages = messages
    }
}
