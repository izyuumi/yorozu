import SwiftUI

/// The work the main agent did between one message and the next, as one row.
///
/// Running, it is a single live line — a spinner and what is happening right now — that
/// replaces itself as the work moves on. Finished, it collapses to "N steps · 2m" and opens on a
/// tap to the whole trace: thoughts, tool runs and delegations in order. The reply prose sits
/// below it on its own, which is what keeps a long turn from reading as a stack.
public struct WorkRowView: View {
    private let work: TurnWork
    @State private var expanded: Bool

    public init(work: TurnWork) {
        self.work = work
        _expanded = State(initialValue: false)
    }

    @ViewBuilder public var body: some View {
        if let liveProgress {
            ProgressCardView(card: liveProgress, activity: work.running ? work.activity : nil)
        } else {
            activity
        }
    }

    private var activity: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                Divider().overlay(YorozuPalette.rule)
                ForEach(work.entries) { entry in
                    switch entry {
                    case .thought(let event):
                        if case .thought(let data) = event.payload {
                            Text(data.text)
                                .font(.callout)
                                .fontDesign(.serif)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    case .tools(let activities): ToolGroupView(activities: activities)
                    case .delegation(let card): DelegationCardView(card: card)
                    case .progress(let event):
                        if case .progressCard(let card) = event.payload { ProgressCardView(card: card) }
                    }
                }
            }
            .padding(.top, LayoutMetrics.inner)
        } label: {
            HStack(spacing: LayoutMetrics.inner) {
                YorozuMark(dimension: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(work.running ? "IN PROGRESS" : "ACTIVITY")
                        .font(.caption2.weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(work.running ? YorozuPalette.vermilion : YorozuPalette.sage)
                    Text(summary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(YorozuPalette.ink)
                        .lineLimit(2)
                }
                Spacer(minLength: LayoutMetrics.inner)
                if work.running { ProgressView().controlSize(.small).tint(YorozuPalette.vermilion) }
            }
            .frame(minHeight: controlTarget)
            .accessibilityLabel(summary)
        }
        .buttonStyle(.plain)
        .yorozuPaperCard(padding: LayoutMetrics.stack)
    }

    /// A live structured progress report is already the best summary of the work. Showing the
    /// generic disclosure above it repeats the same status and nests paper cards three deep.
    private var liveProgress: ProgressCardData? {
        work.entries.reversed().compactMap { entry in
            guard case .progress(let event) = entry,
                  case .progressCard(let card) = event.payload,
                  card.running else { return nil }
            return card
        }.first
    }

    /// Live: what is happening now. Settled: how much happened and how long it took — or, for
    /// work that ran no tools, the last thing it said it was doing.
    private var summary: String {
        if work.running { return work.status ?? String(localized: "Working…") }
        if work.steps == 0, let status = work.status { return status }
        var parts = [work.steps == 1 ? String(localized: "1 step") : String(localized: "\(work.steps) steps")]
        if work.duration >= .seconds(1) {
            parts.append(work.duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow)))
        }
        if work.failed > 0 { parts.append(String(localized: "\(work.failed) failed")) }
        return parts.joined(separator: " · ")
    }
}
