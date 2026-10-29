import Foundation
import YorozuWire

enum ShareInbox {
    static let appGroup = "group.to.yumi.yorozu"
    struct Share: Codable {
        var text: String
        var fileName: String?
        var convId: String?
    }
    struct Conversation: Codable, Identifiable, Hashable {
        var id: String
        var title: String
    }

    static let defaultMaxBytes = Attachment.defaultMaxBytes

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

    /// The folder is named for `messageId` and the app sends the share under that id, so a share the
    /// extension already got to the host is answered `delivered` again rather than run twice.
    static func write(text: String, file: URL?, convId: String?, messageId: String) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let folder = directory.appending(path: messageId, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let file { try FileManager.default.copyItem(at: file, to: folder.appending(path: file.lastPathComponent)) }
        try JSONEncoder().encode(Share(text: text, fileName: file?.lastPathComponent, convId: convId))
            .write(to: folder.appending(path: "share.json"), options: options)
    }

    static func pending() -> [(share: Share, folder: URL)] {
        guard let directory, let folders = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
        let dated = folders.compactMap { folder -> (Date, Share, URL)? in
            guard let data = try? Data(contentsOf: folder.appending(path: "share.json")), let share = try? JSONDecoder().decode(Share.self, from: data) else { return nil }
            return ((try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast, share, folder)
        }
        return dated.sorted { $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

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

    static func publish(_ directory: Directory) {
        guard let listFile, let data = try? JSONEncoder().encode(directory) else { return }
        if (try? Data(contentsOf: listFile)) == data { return }
        try? data.write(to: listFile, options: options)
    }

    static func published() -> Directory {
        guard let listFile, let data = try? Data(contentsOf: listFile), let directory = try? JSONDecoder().decode(Directory.self, from: data) else {
            return Directory(conversations: [], maxBytes: defaultMaxBytes)
        }
        return directory
    }

    /// Posted by the extension after it sent a share itself. The host keeps one session per device, so the
    /// extension's replaced the app's, and an app that is open reconnects.
    static let sentNotification = "to.yumi.yorozu.share-sent"

    static func announceSent() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(sentNotification as CFString), nil, nil, true)
    }

    static func clear() {
        if let listFile { try? FileManager.default.removeItem(at: listFile) }
    }
}
