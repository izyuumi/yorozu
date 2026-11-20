import Foundation

struct WidgetSnapshot: Codable, Equatable, Sendable {
    struct Row: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var title: String
        var pinned: Bool
        var unread: Int
        var lastReplyAt: Date?
        var updatedAt: Date
    }

    struct Preview: Codable, Equatable, Sendable {
        var convId: String
        var text: String
    }

    static let rowLimit = 12
    static let previewLimit = 120
    static let seenLimit = 16

    var rows: [Row]
    var unread: Int
    var preview: Preview?
    var accent: String?
    var live: Bool
    var seen: [String]

    init(rows: [Row] = [], unread: Int = 0, preview: Preview? = nil, accent: String? = nil, live: Bool = false, seen: [String] = []) {
        self.rows = rows
        self.unread = unread
        self.preview = preview
        self.accent = accent
        self.live = live
        self.seen = seen
    }

    var latest: Row? { rows.filter { $0.lastReplyAt != nil }.max { ($0.lastReplyAt ?? .distantPast) < ($1.lastReplyAt ?? .distantPast) } }

    static func ordered(_ rows: [Row]) -> [Row] {
        let pinned = rows.filter(\.pinned)
        let rest = rows.filter { !$0.pinned }.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        return Array((pinned + rest).prefix(rowLimit))
    }

    static func clip(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? ""
        return line.count > previewLimit ? String(line.prefix(previewLimit - 1)) + "…" : line
    }

    mutating func receive(convId: String, title: String?, body: String, event: String, at date: Date, previews: Bool) -> Bool {
        guard !live, !seen.contains(event) else { return false }
        seen = Array((seen + [event]).suffix(Self.seenLimit))
        if let index = rows.firstIndex(where: { $0.id == convId }) {
            rows[index].unread += 1
            rows[index].lastReplyAt = date
            rows[index].updatedAt = date
        } else {
            let name = title.flatMap { $0.isEmpty ? nil : $0 } ?? ""
            rows.append(Row(id: convId, title: name, pinned: false, unread: 1, lastReplyAt: date, updatedAt: date))
        }
        rows = Self.ordered(rows)
        unread += 1
        preview = previews ? Preview(convId: convId, text: Self.clip(body)) : nil
        return true
    }
}

enum WidgetStore {
    static let appGroup = "group.to.yumi.yorozu"
    static let fileName = "WidgetSnapshot.json"
    static let previewsKey = "widgetPreviews"
    static let widgetKind = "to.yumi.yorozu.conversations"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
    static var previews: Bool { defaults?.bool(forKey: previewsKey) ?? false }

    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appending(path: fileName)
    }

    static func read(from url: URL? = url) -> WidgetSnapshot? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func encode(_ snapshot: WidgetSnapshot) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(snapshot)
    }

    @discardableResult
    static func write(_ snapshot: WidgetSnapshot, to url: URL? = url) -> Bool {
        guard let url, let data = encode(snapshot) else { return false }
        if (try? Data(contentsOf: url)) == data { return false }
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtectionUntilFirstUserAuthentication)
        #endif
        do { try data.write(to: url, options: options) } catch { return false }
        return true
    }

    @discardableResult
    static func update(at url: URL? = url, _ change: (inout WidgetSnapshot) -> Bool) -> Bool {
        guard var snapshot = read(from: url) else { return false }
        guard change(&snapshot) else { return false }
        return write(snapshot, to: url)
    }

    @discardableResult
    static func remove(at url: URL? = url) -> Bool {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
