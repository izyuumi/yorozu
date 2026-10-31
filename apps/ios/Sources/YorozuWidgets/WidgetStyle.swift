import SwiftUI
import WidgetKit

extension WidgetSnapshot {
    var tint: Color { accent.flatMap(Accent.init(rawValue:))?.tint ?? Accent.vermilion.tint }
}

extension WidgetSnapshot.Row {
    var name: String { title.isEmpty ? String(localized: "New Conversation") : title }
}

enum WidgetText {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    /// "5 min. ago", against the entry's date so each quarter-hour entry reads right.
    static func relative(_ date: Date, to now: Date) -> String {
        now.timeIntervalSince(date) < 60 ? String(localized: "now") : formatter.localizedString(for: date, relativeTo: now)
    }

    static func unread(_ count: Int) -> String { String(localized: "\(count) unread") }

    static func newReplies(_ count: Int) -> String { String(localized: "\(count) new replies") }

    static func rowLabel(_ row: WidgetSnapshot.Row, now: Date) -> String {
        var parts = [row.name]
        if row.pinned { parts.append(String(localized: "Pinned")) }
        if row.unread > 0 { parts.append(unread(row.unread)) }
        if let reply = row.lastReplyAt { parts.append(relative(reply, to: now)) }
        return parts.joined(separator: ", ")
    }
}

/// Unread dot or pin, tinted in full color and accented when the system tints the widget.
struct RowMark: View {
    let row: WidgetSnapshot.Row
    let tint: Color

    var body: some View {
        Group {
            if row.unread > 0 {
                Circle().fill(tint).frame(width: 8, height: 8)
            } else if row.pinned {
                Image(systemName: "pin.fill").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            } else {
                Color.clear.frame(width: 8, height: 8)
            }
        }
        .frame(width: 10)
        .widgetAccentable()
        .accessibilityHidden(true)
    }
}
