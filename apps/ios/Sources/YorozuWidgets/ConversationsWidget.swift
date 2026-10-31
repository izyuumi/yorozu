import AppIntents
import SwiftUI
import WidgetKit

struct ConversationsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: WidgetStore.widgetKind, intent: ConversationsConfiguration.self, provider: ConversationsProvider()) { entry in
            ConversationsView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Conversations")
        .description("Pinned and recent conversations, with unread replies.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ConversationsView: View {
    let entry: ConversationsEntry
    /// Set only to draw a family outside WidgetKit (screenshots); otherwise the system's.
    var size: WidgetFamily?
    @Environment(\.widgetFamily) private var systemFamily
    private var family: WidgetFamily { size ?? systemFamily }

    var body: some View {
        if let snapshot = entry.snapshot {
            content(snapshot)
        } else {
            OpenAppView(message: String(localized: "Open Yorozu to pair with your Mac."))
        }
    }

    @ViewBuilder
    private func content(_ snapshot: WidgetSnapshot) -> some View {
        let rows = Array(entry.rows.prefix(rowCount(snapshot)))
        VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 8) {
            WidgetHeader(unread: snapshot.unread, tint: snapshot.tint, showsAsk: family != .systemSmall)
            if rows.isEmpty {
                Spacer(minLength: 0)
                Text("No conversations yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            } else if family == .systemSmall, let row = rows.first {
                SmallRow(row: row, now: entry.date, tint: snapshot.tint)
                Spacer(minLength: 0)
                ForEach(rows.dropFirst()) { other in
                    HStack(spacing: 6) {
                        RowMark(row: other, tint: snapshot.tint)
                        Text(other.name).font(.caption).lineLimit(1).privacySensitive()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(WidgetText.rowLabel(other, now: entry.date))
                }
            } else {
                ForEach(rows) { row in
                    Link(destination: WidgetLink.conversation(row.id).url) {
                        ConversationRow(row: row, now: entry.date, tint: snapshot.tint,
                            preview: snapshot.preview?.convId == row.id ? snapshot.preview?.text : nil)
                    }
                    .foregroundStyle(Color.primary)
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(family == .systemSmall ? rows.first.map { WidgetLink.conversation($0.id).url } ?? WidgetLink.new.url : nil)
    }

    private func rowCount(_ snapshot: WidgetSnapshot) -> Int {
        let previewLines = snapshot.preview == nil ? 0 : 1
        return switch family {
        case .systemSmall: 3
        case .systemMedium: 3
        default: 8 - previewLines
        }
    }
}

/// "Yorozu", the unread count, and the Ask and + buttons.
private struct WidgetHeader: View {
    let unread: Int
    let tint: Color
    let showsAsk: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text("Yorozu")
                .font(.subheadline.weight(.semibold))
            if unread > 0 {
                Text("\(unread)")
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(tint))
                    .widgetAccentable()
                    .accessibilityLabel(WidgetText.unread(unread))
            }
            Spacer(minLength: 0)
            if showsAsk {
                Button(intent: AskInYorozuIntent()) {
                    Label("Ask", systemImage: "text.bubble")
                        .font(.caption.weight(.semibold))
                }
                .tint(tint)
                .widgetAccentable()
                .accessibilityLabel(Text("Ask in Yorozu"))
            }
            Button(intent: NewConversationIntent()) {
                Image(systemName: "plus")
                    .font(.caption.weight(.bold))
                    .frame(width: 14, height: 14)
            }
            .tint(tint)
            .widgetAccentable()
            .accessibilityLabel(Text("New Conversation"))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.mini)
    }
}

private struct ConversationRow: View {
    let row: WidgetSnapshot.Row
    let now: Date
    let tint: Color
    let preview: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                RowMark(row: row, tint: tint)
                Text(row.name)
                    .font(.subheadline.weight(row.unread > 0 ? .semibold : .regular))
                    .lineLimit(1)
                    .privacySensitive()
                Spacer(minLength: 4)
                if let reply = row.lastReplyAt {
                    Text(WidgetText.relative(reply, to: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            if let preview {
                Text(preview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 16)
                    .privacySensitive()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetText.rowLabel(row, now: now) + (preview.map { ", " + $0 } ?? ""))
        .privacySensitive()
    }
}

private struct SmallRow: View {
    let row: WidgetSnapshot.Row
    let now: Date
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                RowMark(row: row, tint: tint)
                if let reply = row.lastReplyAt {
                    Text(WidgetText.relative(reply, to: now))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Text(row.name)
                .font(.headline)
                .lineLimit(2)
                .privacySensitive()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WidgetText.rowLabel(row, now: now))
        .privacySensitive()
    }
}

/// Unpaired, demo mode, or never opened: the widget can only send the owner to the app.
struct OpenAppView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.title3)
                .widgetAccentable()
                .accessibilityHidden(true)
            Text("Yorozu")
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
