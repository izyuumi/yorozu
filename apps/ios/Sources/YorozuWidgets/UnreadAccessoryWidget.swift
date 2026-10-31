import SwiftUI
import WidgetKit

/// Lock Screen accessories: the unread count, or the latest reply's conversation with it.
struct UnreadAccessoryWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "to.yumi.yorozu.unread", provider: UnreadProvider()) { entry in
            UnreadAccessoryView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Unread Replies")
        .description("How many replies you haven't read, and where the latest one is.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct UnreadAccessoryView: View {
    let entry: ConversationsEntry
    /// Set only to draw a family outside WidgetKit (screenshots); otherwise the system's.
    var size: WidgetFamily?
    @Environment(\.widgetFamily) private var systemFamily
    private var family: WidgetFamily { size ?? systemFamily }

    private var unread: Int { entry.snapshot?.unread ?? 0 }
    private var latest: WidgetSnapshot.Row? { entry.snapshot?.latest }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        default: inline
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            if unread > 0 {
                VStack(spacing: 0) {
                    Image(systemName: "bubble.left.fill").font(.system(size: 11))
                    Text("\(min(unread, 99))")
                        .font(.system(.title3, design: .rounded).weight(.semibold).monospacedDigit())
                        .minimumScaleFactor(0.6)
                }
            } else {
                Image(systemName: "bubble.left.and.text.bubble.right").font(.title3)
            }
        }
        .widgetAccentable()
        .widgetURL(link)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(unread > 0 ? WidgetText.unread(unread) : String(localized: "Yorozu, no unread replies"))
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.fill").font(.caption2)
                Text(unread > 0 ? WidgetText.unread(unread) : String(localized: "No unread replies"))
                    .font(.caption.weight(.semibold))
            }
            .widgetAccentable()
            if let latest {
                Text(latest.name)
                    .font(.headline)
                    .lineLimit(2)
                    .privacySensitive()
            } else {
                Text("Yorozu").font(.headline)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(link)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var inline: some View {
        if unread > 0, let latest {
            Text(String(localized: "\(WidgetText.newReplies(unread)), latest: \(latest.name)"))
                .privacySensitive()
                .widgetURL(link)
        } else {
            Label(unread > 0 ? WidgetText.unread(unread) : String(localized: "Yorozu"), systemImage: "bubble.left")
        }
    }

    private var link: URL? { latest.map { WidgetLink.conversation($0.id).url } }
}
