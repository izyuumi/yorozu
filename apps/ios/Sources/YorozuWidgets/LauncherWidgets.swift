import SwiftUI
import WidgetKit

/// Lock Screen launcher: a new conversation with voice input started, or the voice setup when the model isn't ready.
struct TalkLauncherWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Launcher.talk.kind, provider: LauncherProvider()) { _ in
            LauncherView(launcher: .talk).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Talk to Yorozu")
        .description("Opens a new conversation in Yorozu and starts voice input.")
        .supportedFamilies([.accessoryCircular])
    }
}

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

/// One entry that never changes: the launchers show no data.
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
            LauncherGlyph(badge: launcher.badge).padding(11)
        }
        .widgetAccentable()
        .widgetURL(launcher.link.url)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(launcher == .talk ? String(localized: "Talk to Yorozu") : String(localized: "Ask in Yorozu"))
    }
}

/// The Yorozu mark with a badge cut into its lower right, so the two launchers differ at a glance in one colour.
struct LauncherGlyph: View {
    let badge: String

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let mark = side * 0.8
            let disc = side * 0.5
            let gap = side * 0.06
            let corner = side - disc / 2
            ZStack {
                Image("YorozuMark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: mark, height: mark)
                    .position(x: mark / 2, y: mark / 2)
                Circle()
                    .frame(width: disc + 2 * gap, height: disc + 2 * gap)
                    .position(x: corner, y: corner)
                    .blendMode(.destinationOut)
                Circle()
                    .frame(width: disc, height: disc)
                    .position(x: corner, y: corner)
                Image(systemName: badge)
                    .font(.system(size: disc * 0.5, weight: .bold))
                    .position(x: corner, y: corner)
                    .blendMode(.destinationOut)
            }
            .frame(width: side, height: side)
            .compositingGroup()
        }
    }
}
