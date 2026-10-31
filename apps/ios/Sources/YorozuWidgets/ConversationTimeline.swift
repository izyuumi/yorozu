import AppIntents
import WidgetKit

/// A conversation as the widget's configuration offers it: read from the App Group snapshot, never
/// from the app's store, so picking one works without launching the app.
struct WidgetConversationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Conversation"
    static let defaultQuery = WidgetConversationQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title.isEmpty ? String(localized: "New Conversation") : title)")
    }
}

struct WidgetConversationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WidgetConversationEntity] {
        let rows = WidgetStore.read()?.rows ?? []
        return identifiers.compactMap { id in rows.first { $0.id == id }.map { WidgetConversationEntity(id: $0.id, title: $0.title) } }
    }

    func suggestedEntities() async throws -> [WidgetConversationEntity] {
        (WidgetStore.read()?.rows ?? []).map { WidgetConversationEntity(id: $0.id, title: $0.title) }
    }
}

struct ConversationsConfiguration: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Conversations"
    static let description = IntentDescription("Choose the conversations to show. Without a choice, pinned conversations come first, then the most recent.")

    @Parameter(title: "Conversations")
    var conversations: [WidgetConversationEntity]?
}

struct ConversationsEntry: TimelineEntry {
    let date: Date
    /// Nil while unpaired, in demo mode, or before the app first ran.
    let snapshot: WidgetSnapshot?
    var chosen: [String] = []

    /// The chosen conversations first, in the order picked, then pinned and recent ones.
    var rows: [WidgetSnapshot.Row] {
        let all = snapshot?.rows ?? []
        let picked = chosen.compactMap { id in all.first { $0.id == id } }
        return picked + all.filter { row in !chosen.contains(row.id) }
    }

    static let placeholder = ConversationsEntry(date: .now, snapshot: WidgetSnapshot(
        rows: [
            .init(id: "a", title: String(localized: "Trip planning"), pinned: true, unread: 2, lastReplyAt: .now.addingTimeInterval(-300), updatedAt: .now),
            .init(id: "b", title: String(localized: "Weekly groceries"), pinned: false, unread: 0, lastReplyAt: .now.addingTimeInterval(-3600), updatedAt: .now),
            .init(id: "c", title: String(localized: "Fix the build"), pinned: false, unread: 0, lastReplyAt: .now.addingTimeInterval(-86_400), updatedAt: .now),
        ],
        unread: 2))
}

/// Entries every quarter hour keep the relative times fresh; the app and the notification service
/// reload the timeline whenever the snapshot changes.
func quarterHourTimeline(_ entry: (Date) -> ConversationsEntry) -> Timeline<ConversationsEntry> {
    let now = Date.now
    return Timeline(entries: (0..<16).map { entry(now.addingTimeInterval(TimeInterval($0) * 15 * 60)) }, policy: .atEnd)
}

struct ConversationsProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> ConversationsEntry { .placeholder }

    func snapshot(for configuration: ConversationsConfiguration, in context: Context) async -> ConversationsEntry {
        context.isPreview && WidgetStore.read() == nil ? .placeholder : entry(configuration, at: .now)
    }

    func timeline(for configuration: ConversationsConfiguration, in context: Context) async -> Timeline<ConversationsEntry> {
        quarterHourTimeline { entry(configuration, at: $0) }
    }

    private func entry(_ configuration: ConversationsConfiguration, at date: Date) -> ConversationsEntry {
        ConversationsEntry(date: date, snapshot: WidgetStore.read(), chosen: configuration.conversations?.map(\.id) ?? [])
    }
}

struct UnreadProvider: TimelineProvider {
    func placeholder(in context: Context) -> ConversationsEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (ConversationsEntry) -> Void) {
        completion(context.isPreview && WidgetStore.read() == nil ? .placeholder : ConversationsEntry(date: .now, snapshot: WidgetStore.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ConversationsEntry>) -> Void) {
        let snapshot = WidgetStore.read()
        completion(quarterHourTimeline { ConversationsEntry(date: $0, snapshot: snapshot) })
    }
}
