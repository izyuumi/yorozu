import SwiftUI
import WidgetKit

private struct IconEntry: TimelineEntry {
    let date: Date
}

private struct IconProvider: TimelineProvider {
    func placeholder(in context: Context) -> IconEntry { IconEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (IconEntry) -> Void) {
        completion(IconEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<IconEntry>) -> Void) {
        completion(Timeline(entries: [IconEntry(date: .now)], policy: .never))
    }
}

@main
struct YorozuWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "YorozuIcon", provider: IconProvider()) { _ in
            Image("AppIconImage")
                .resizable()
                .widgetAccentedRenderingMode(.fullColor)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .containerBackground(for: .widget) { Color(.systemBackground) }
                .accessibilityLabel("Open Yorozu")
        }
        .configurationDisplayName("Yorozu")
        .description("Open Yorozu from your Home Screen.")
        .supportedFamilies([.systemSmall])
    }
}
