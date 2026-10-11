import Foundation

/// What the share extension hands the app: one folder per share in the App Group, holding `share.json` and at most
/// one file. The extension only writes; the app sends each share through its outbox and removes it. The extension
/// holds no pairing, keys or socket (v1's design): the app is the one device in the room.
enum ShareInbox {
    static let appGroup = "group.to.yumi.yorozu"
    struct Share: Codable { var text: String; var fileName: String? }

    static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: "ShareInbox", directoryHint: .isDirectory)
    }

    /// Writes one share; `file` is copied in (the extension's own copy goes when it ends).
    static func write(text: String, file: URL?) throws {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let folder = directory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let file { try FileManager.default.copyItem(at: file, to: folder.appending(path: file.lastPathComponent)) }
        try JSONEncoder().encode(Share(text: text, fileName: file?.lastPathComponent)).write(to: folder.appending(path: "share.json"))
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
}
