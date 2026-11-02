import ActivityKit
import SwiftUI
import WidgetKit

/// The app's one Live Activity: one line per job, at most three, then "+N more", each opening its conversation.
/// Only needs-you takes the accent. Stale, timers hide and a line says when it last updated. Labels come from
/// the device's `ActivityLabels`, never from the activity's state; titles only while previews are on.
struct YorozuActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: YorozuActivityAttributes.self) { context in
            JobList(state: context.state, stale: context.isStale)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let compact = YorozuJobs.compact(context.state.jobs)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.bottom) {
                    JobList(state: context.state, stale: context.isStale)
                }
            } compactLeading: {
                ActivityMark()
            } compactTrailing: {
                CompactValue(compact: compact, stale: context.isStale)
            } minimal: {
                ActivityMark()
                    .overlay(alignment: .topTrailing) {
                        if compact == .needsYou {
                            Circle().fill(ActivityStyle.tint)
                                .frame(width: 6, height: 6)
                                .overlay(Circle().stroke(.black, lineWidth: 1.5))
                                .padding(3)
                                .accessibilityLabel(Text("Needs you"))
                        }
                    }
            }
        }
    }
}

enum ActivityStyle {
    static var tint: Color { WidgetStore.read()?.tint ?? Accent.vermilion.tint }
    static let rows = 3
    static let rowHeight: CGFloat = 36
    static let icon: CGFloat = 15
    static let gap: CGFloat = 10
    /// Wide enough for "1:02:14", so a timer never stretches its row.
    static let timer: CGFloat = 64
    static let compactTimer: CGFloat = 48
    /// The compact island's "needs you" glyph, large enough to read at a glance.
    static let compactIcon: CGFloat = 17
    /// Hours and minutes without AM/PM: "9:41".
    static let time = Date.FormatStyle().hour(.defaultDigits(amPM: .omitted)).minute(.twoDigits)

    /// The title of a job whose conversation title may not show.
    static func generic(_ kind: YorozuJob.Kind) -> String {
        switch kind {
        case .turn, .needsYou: String(localized: "Conversation")
        case .recording: String(localized: "Recording")
        case .transcribing: String(localized: "Transcribing")
        }
    }

    static func link(_ entry: ActivityLabels.Entry?) -> URL? {
        entry?.convId.map { WidgetLink.conversation($0).url }
    }
}

/// The Yorozu mark, as on the Lock Screen launchers.
struct ActivityMark: View {
    var body: some View {
        Image("YorozuMark")
            .resizable()
            .scaledToFit()
            .foregroundStyle(.white)
            .accessibilityLabel(Text(verbatim: "Yorozu"))
    }
}

/// The compact trailing item; stale, a single job's timer gives way to a plain working glyph.
struct CompactValue: View {
    let compact: YorozuJobs.Compact
    let stale: Bool

    var body: some View {
        Group {
            switch compact {
            case .needsYou:
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.system(size: ActivityStyle.compactIcon, weight: .semibold))
                    .foregroundStyle(ActivityStyle.tint)
                    .accessibilityLabel(Text("Needs you"))
            case .timer(let start) where !stale:
                Text(timerInterval: start...Date.distantFuture, countsDown: false)
                    .multilineTextAlignment(.trailing)
                    .frame(width: ActivityStyle.compactTimer, alignment: .trailing)
            case .timer:
                Image(systemName: "ellipsis").foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Working"))
            case .count(let running):
                Text(running, format: .number)
            case .done:
                Image(systemName: "checkmark").foregroundStyle(.secondary)
                    .accessibilityLabel(Text("Done"))
            }
        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
    }
}

/// Up to three rows, then one caption: "+N more" and, stale, when it last updated.
struct JobList: View {
    let state: YorozuActivityState
    let stale: Bool

    var body: some View {
        let labels = ActivityLabelsStore.read()
        let previews = WidgetStore.previews
        let shown = YorozuJobs.sorted(state.jobs).prefix(ActivityStyle.rows)
        let more = state.jobs.count - shown.count
        let caption = [
            more > 0 ? String(localized: "+\(more) more") : nil,
            stale ? state.lastUpdate.map { String(localized: "Not updated since \($0.formatted(ActivityStyle.time))") } : nil,
        ].compactMap { $0 }
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { job in
                JobRow(job: job, entry: labels.entries[job.token], previews: previews, stale: stale)
            }
            if !caption.isEmpty {
                Text(verbatim: caption.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, ActivityStyle.icon + ActivityStyle.gap)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One line: the state icon, the conversation title or a generic one, and one trailing value.
/// A token without a label opens the app.
struct JobRow: View {
    let job: YorozuJob
    let entry: ActivityLabels.Entry?
    let previews: Bool
    let stale: Bool

    var body: some View {
        let row = HStack(spacing: ActivityStyle.gap) {
            JobIcon(job: job)
                .font(.footnote.weight(.semibold))
                .frame(width: ActivityStyle.icon)
            Text(entry?.label(previews: previews) ?? ActivityStyle.generic(job.kind))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .privacySensitive()
            Spacer(minLength: 0)
            JobValue(job: job, stale: stale).font(.subheadline)
        }
        .frame(minHeight: ActivityStyle.rowHeight)
        .accessibilityElement(children: .combine)
        if let url = ActivityStyle.link(entry) { Link(destination: url) { row } } else { row }
    }
}

/// Grey for every state but needs-you, which takes the accent.
struct JobIcon: View {
    let job: YorozuJob

    var body: some View {
        let (name, label): (String, LocalizedStringResource) = switch (job.state, job.kind) {
        case (.done, _): ("checkmark", "Done")
        case (.failed, _): ("exclamationmark.triangle", "Failed")
        case (.running, .needsYou): ("exclamationmark.circle.fill", "Needs you")
        case (.running, .turn): ("ellipsis", "Working")
        case (.running, .recording): ("mic", "Recording")
        case (.running, .transcribing): ("waveform", "Transcribing")
        }
        Image(systemName: name)
            .foregroundStyle(job.state == .running && job.kind == .needsYou ? AnyShapeStyle(ActivityStyle.tint) : AnyShapeStyle(.secondary))
            .accessibilityLabel(Text(label))
    }
}

/// Review, a live timer (hidden when stale), the finish time, or Failed.
struct JobValue: View {
    let job: YorozuJob
    let stale: Bool

    var body: some View {
        switch (job.state, job.kind) {
        case (.running, .needsYou):
            Text("Review")
                .fontWeight(.semibold)
                .foregroundStyle(ActivityStyle.tint)
        case (.running, _):
            if !stale {
                Text(timerInterval: job.startedAt...Date.distantFuture, countsDown: false)
                    .fontWeight(.semibold)
                    .monospacedDigit()
                    .multilineTextAlignment(.trailing)
                    .frame(width: ActivityStyle.timer, alignment: .trailing)
            }
        case (.done, _):
            Text(job.finishedAt ?? job.startedAt, format: ActivityStyle.time)
                .foregroundStyle(.secondary)
        case (.failed, _):
            Text("Failed").foregroundStyle(.secondary)
        }
    }
}
