import Foundation

/// The share extension and the app, through the App Group (#430). The extension holds no pairing, keys or socket (v1's
/// design): it only writes. Each share is a folder with `share.json` and at most one file; the app sends it into the
/// chosen conversation (or a new one) through its outbox, the next time it is open. The share stays until the host
/// acknowledges delivery, so a suspended app or lost socket can import it again with the same message ID. The app keeps a
/// short list of its conversations here, newest first, for the extension's picker. Everything is written with Data
/// Protection `complete`.
enum ShareInbox {
    static let appGroup = "group.to.yumi.yorozu"
    struct Share: Codable {
        var text: String
        var fileName: String?
        /// The conversation to send into; nil starts a new one.
        var convId: String?
    }
    /// One row of the extension's picker.
    struct Conversation: Codable, Identifiable, Hashable {
        var id: String
        var title: String
    }

    /// The host's attachment limit as the app last knew it; the extension refuses larger files up front.
    static let defaultMaxBytes = 8 * 1024 * 1024

    private static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    static var directory: URL? { container?.appending(path: "ShareInbox", directoryHint: .isDirectory) }
    private static var listFile: URL? { container?.appending(path: "ShareConversations.json") }

    private static var options: Data.WritingOptions {
        #if os(iOS)
        [.atomic, .completeFileProtection]
        #else
        [.atomic]
        #endif
    }

    /// Writes one share; `file` is copied in (the extension's own copy goes when it ends).
    static func write(text: String, file: URL?, convId: String?) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let folder = directory.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let file { try FileManager.default.copyItem(at: file, to: folder.appending(path: file.lastPathComponent)) }
        try JSONEncoder().encode(Share(text: text, fileName: file?.lastPathComponent, convId: convId))
            .write(to: folder.appending(path: "share.json"), options: options)
    }

    /// The waiting shares, oldest first, with their folders.
    static func pending() -> [(share: Share, folder: URL)] {
        guard let directory, let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        let dated = folders.compactMap { folder -> (Date, Share, URL)? in
            guard let data = try? Data(contentsOf: folder.appending(path: "share.json")), let share = try? JSONDecoder().decode(Share.self, from: data) else { return nil }
            return ((try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast, share, folder)
        }
        return dated.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    /// Only a host `delivered` or `run_started` acknowledgement retires a share. Old folders used uppercase UUIDs.
    static func finish(messageId: String) {
        guard let directory, UUID(uuidString: messageId) != nil else { return }
        let folder = directory.appending(path: messageId, directoryHint: .isDirectory)
        let legacy = directory.appending(path: messageId.uppercased(), directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: folder)
        if legacy != folder { try? FileManager.default.removeItem(at: legacy) }
    }

    struct Directory: Codable {
        var conversations: [Conversation]
        var maxBytes: Int
    }

    /// The app's side: its newest conversations and the host's limit, for the extension.
    static func publish(_ directory: Directory) {
        guard let listFile, let data = try? JSONEncoder().encode(directory) else { return }
        if (try? Data(contentsOf: listFile)) == data { return }
        try? data.write(to: listFile, options: options)
    }

    /// The extension's side; empty before the app has run once paired.
    static func published() -> Directory {
        guard let listFile, let data = try? Data(contentsOf: listFile), let directory = try? JSONDecoder().decode(Directory.self, from: data) else {
            return Directory(conversations: [], maxBytes: defaultMaxBytes)
        }
        return directory
    }

    /// Unpaired: nothing about the old host's conversations stays behind.
    static func clear() {
        if let listFile { try? FileManager.default.removeItem(at: listFile) }
    }
}
