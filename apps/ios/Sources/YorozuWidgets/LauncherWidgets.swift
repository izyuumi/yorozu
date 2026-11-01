import SwiftUI
import WidgetKit

/// Lock Screen launcher: a new conversation with the keyboard up.
struct AskLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Launcher.ask.kind, provider: LauncherProvider()) { _ in
            LauncherView(launcher: .ask).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Ask in Yorozu")
        .description("Opens a new conversation in Yorozu with the keyboard up.")
        .supportedFamilies([.accessoryCircular])
    }
}

/// One entry that never changes: the launcher shows no data.
struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry { LauncherEntry() }
    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) { completion(LauncherEntry()) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry()], policy: .never))
    }
}

struct LauncherEntry: TimelineEntry {
    let date = Date.distantPast
}

struct LauncherView: View {
    let launcher: Launcher

    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image("YorozuMark").resizable().scaledToFit().padding(11)
        }
        .widgetAccentable()
        .widgetURL(launcher.link.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "Ask in Yorozu"))
    }
}
