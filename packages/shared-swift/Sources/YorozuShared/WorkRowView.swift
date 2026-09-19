import SwiftUI

/// The work the main agent did between one message and the next, as one row.
///
/// Running, it is a single live line — a spinner and what is happening right now — that
/// replaces itself as the work moves on. Finished, it collapses to "N steps · 2m" and opens on a
/// tap to the whole trace: thoughts, tool runs and delegations in order. The reply prose sits
/// below it on its own, which is what keeps a long turn from reading as a stack.
public struct WorkRowView: View {
    private let work: TurnWork
    @State private var expanded = false

    public init(work: TurnWork) {
        self.work = work
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: LayoutMetrics.inner) {
                    if work.running {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Image(systemName: work.failed > 0 ? "exclamationmark.triangle" : "checkmark.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.numericText())
                    Spacer(minLength: 0)
                }
                .frame(minHeight: controlTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary)
            .accessibilityHint(expanded ? String(localized: "Hides the work") : String(localized: "Shows the work"))

            if expanded {
                VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                    ForEach(work.entries) { entry in
                        switch entry {
                        case .thought(let event):
                            if case .thought(let data) = event.payload {
                                Text(data.text)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        case .tools(let activities):
                            ToolGroupView(activities: activities)
                        case .delegation(let card):
                            DelegationCardView(card: card)
                        case .progress(let event):
                            if case .progressCard(let card) = event.payload {
                                ProgressCardView(card: card)
                            }
                        }
                    }
                }
                .padding(.leading, LayoutMetrics.gutter)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy, value: work.status)
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
