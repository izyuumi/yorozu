import ActivityKit
import SwiftUI
import WidgetKit

/// The app's one Live Activity: up to three jobs with "+N more", each opening its conversation. Labels come
/// from the device's `ActivityLabels`, never from the activity's state; titles only while previews are on.
struct YorozuActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: YorozuActivityAttributes.self) { context in
            JobList(jobs: context.state.jobs)
                .padding(16)
                .activityBackgroundTint(nil)
        } dynamicIsland: { context in
            let jobs = context.state.jobs
            let counts = YorozuJobs.Counts(jobs)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    ActivityMark().frame(width: 28, height: 28).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountsIndicator(counts: counts).font(.headline).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    JobList(jobs: jobs)
                }
            } compactLeading: {
                ActivityMark()
            } compactTrailing: {
                CountsIndicator(counts: counts).font(.caption.monospacedDigit().weight(.semibold))
            } minimal: {
                ActivityMark()
                    .overlay(alignment: .bottomTrailing) {
                        CountsIndicator(counts: counts)
                            .font(.system(size: 8, weight: .bold))
                            .padding(1.5)
                            .background(.black, in: Circle())
                            .offset(x: 3, y: 3)
                    }
            }
            .keylineTint(ActivityStyle.tint)
        }
    }
}

enum ActivityStyle {
    static var tint: Color { WidgetStore.read()?.tint ?? Accent.vermilion.tint }
    static let rows = 3

    static func steps(_ count: Int) -> String { String(localized: "\(count) tool steps") }

    /// The generic label for a job, used whenever no title may show.
    static func generic(_ job: YorozuJob) -> String {
        switch (job.state, job.kind) {
        case (.done, _): String(localized: "Done")
        case (.failed, _): String(localized: "Failed")
        case (.running, .turn): String(localized: "Working")
        case (.running, .recording): String(localized: "Recording")
        case (.running, .transcribing): String(localized: "Transcribing")
        case (.running, .needsYou): String(localized: "Needs you")
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
            .foregroundStyle(ActivityStyle.tint)
            .accessibilityLabel(Text(verbatim: "Yorozu"))
    }
}

/// "!" when a job needs the owner, else a mic while recording, else how many jobs run (a check when none).
struct CountsIndicator: View {
    let counts: YorozuJobs.Counts

    var body: some View {
        Group {
            if counts.needsYou > 0 {
                Text(verbatim: "!").foregroundStyle(ActivityStyle.tint)
                    .accessibilityLabel(Text("Needs you"))
            } else if counts.recording > 0 {
                PulsingSymbol(name: "mic.fill").foregroundStyle(.red)
                    .accessibilityLabel(Text("Recording"))
            } else if counts.running > 0 {
                Text("\(counts.running)").foregroundStyle(ActivityStyle.tint)
                    .accessibilityLabel(Text("Working"))
            } else {
                Image(systemName: "checkmark").foregroundStyle(ActivityStyle.tint)
                    .accessibilityLabel(Text("Done"))
            }
        }
    }
}

struct JobList: View {
    let jobs: [YorozuJob]

    var body: some View {
        let labels = ActivityLabelsStore.read()
        let previews = WidgetStore.previews
        let shown = YorozuJobs.sorted(jobs).prefix(ActivityStyle.rows)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(shown) { job in
                JobRow(job: job, entry: labels.entries[job.token], previews: previews)
            }
            if jobs.count > shown.count {
                Text("+\(jobs.count - shown.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One job: its glyph, the conversation title or a generic label, the tool steps and, while it runs, the time.
/// A token without a label opens the app.
struct JobRow: View {
    let job: YorozuJob
    let entry: ActivityLabels.Entry?
    let previews: Bool

    var body: some View {
        let title = entry?.label(previews: previews)
        let generic = ActivityStyle.generic(job)
        let detail = [title == nil ? nil : generic, job.kind == .turn && (job.steps ?? 0) > 0 ? ActivityStyle.steps(job.steps ?? 0) : nil]
            .compactMap { $0 }.joined(separator: " · ")
        let row = HStack(spacing: 10) {
            JobGlyph(job: job).font(.title3).frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(title ?? generic)
                    .font(.headline)
                    .lineLimit(1)
                    .privacySensitive()
                if !detail.isEmpty {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if !job.finished {
                Text(job.startedAt, style: .timer)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 72)
            }
        }
        .accessibilityElement(children: .combine)
        if let url = ActivityStyle.link(entry) { Link(destination: url) { row } } else { row }
    }
}

struct JobGlyph: View {
    let job: YorozuJob

    var body: some View {
        let tint = ActivityStyle.tint
        switch (job.state, job.kind) {
        case (.done, _): Image(systemName: "checkmark.circle.fill").foregroundStyle(tint)
        case (.failed, _): Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case (.running, .turn): WorkingGlyph(tint: tint)
        case (.running, .recording): PulsingSymbol(name: "mic.fill").foregroundStyle(.red)
        case (.running, .transcribing): Image(systemName: "waveform").foregroundStyle(tint)
        case (.running, .needsYou): Image(systemName: "exclamationmark.circle.fill").foregroundStyle(tint)
        }
    }
}

/// Pulses; holds still under Reduce Motion.
struct PulsingSymbol: View {
    let name: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: name).symbolEffect(.pulse, isActive: !reduceMotion)
    }
}

/// Pulses while the agent works; holds still under Reduce Motion.
struct WorkingGlyph: View {
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Image(systemName: "ellipsis.bubble.fill")
            .foregroundStyle(tint)
            .symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            .accessibilityLabel(Text("Working"))
    }
}
