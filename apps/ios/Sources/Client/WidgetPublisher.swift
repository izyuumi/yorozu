import Foundation
#if os(iOS)
import WidgetKit
#endif

extension WidgetSnapshot {
    /// The app's view of the conversations: titles, pins and `Conversation.unreadCount`, and the latest
    /// reply's first line only when `previews` is on. Archived conversations stay out of the rows but
    /// count toward the total, as on the app badge.
    init(conversations: [Conversation], previews: Bool, accent: String?, live: Bool, seen: [String] = []) {
        let shown = conversations.filter { $0.archived != true }
        let rows = shown.map { conversation in
            Row(id: conversation.id, title: conversation.displayTitle, pinned: conversation.pinnedAt != nil,
                unread: conversation.unreadCount, lastReplyAt: conversation.latestReply.map { Self.date($0.ts) },
                updatedAt: Self.date(conversation.updatedAt))
        }
        let pinOrder = Dictionary(uniqueKeysWithValues: shown.map { ($0.id, $0.pinnedAt ?? 0) })
        let pinned = rows.filter(\.pinned).sorted { (pinOrder[$0.id] ?? 0, $0.id) > (pinOrder[$1.id] ?? 0, $1.id) }
        let latest = previews
            ? shown.compactMap { conversation in conversation.latestReply.map { (conversation.id, $0) } }.max { $0.1.ts < $1.1.ts }
            : nil
        self.init(rows: Self.ordered(pinned + rows.filter { !$0.pinned }),
            unread: conversations.reduce(0) { $0 + $1.unreadCount },
            preview: latest.flatMap { convId, item in
                let text = Self.clip(item.summary)
                return text.isEmpty ? nil : Preview(convId: convId, text: text)
            },
            accent: accent, live: live, seen: seen)
    }

    private static func date(_ ms: Int64) -> Date { Date(timeIntervalSince1970: TimeInterval(ms) / 1000) }
}

enum WidgetPublisher {
    /// Writes the snapshot when its bytes changed (the notification service may have counted a reply the
    /// app has since loaded, so the file, not a copy in memory, is the comparison) and asks WidgetKit to
    /// redraw. iPhone and iPad only: the Mac app is signed without the App Group.
    static func publish(_ snapshot: WidgetSnapshot) {
        #if os(iOS)
        var stored = snapshot
        stored.seen = WidgetStore.read()?.seen ?? []
        guard WidgetStore.write(stored) else { return }
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    static func clear() {
        #if os(iOS)
        guard WidgetStore.remove() else { return }
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
