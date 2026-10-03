import SwiftUI

/// The work the main agent did between one message and the next, as one row.
///
/// Running, it shows elapsed time and what is happening right now. Finished, it collapses to "Worked for 2m" and opens on a
/// tap to the whole trace: thoughts, tool runs and delegations in order. The reply prose sits
/// below it on its own, which is what keeps a long turn from reading as a stack.
public struct WorkRowView: View {
    private let work: TurnWork
    private let quiet: Bool
    @Environment(\.locale) private var locale
    @State private var expanded: Bool

    public init(work: TurnWork, quiet: Bool = false) {
        self.work = work
        self.quiet = quiet
        _expanded = State(initialValue: work.running)
    }

    public var body: some View {
        Group {
            if quiet {
                VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                    ForEach(work.entries) { entry in
                        if case .progress(let event) = entry, case .progressCard(let card) = event.payload {
                            ProgressCardView(card: card)
                        } else if case .delegation(let card) = entry {
                            Text(card.agentId).font(.scaled(.caption)).foregroundStyle(.secondary)
                            Text(card.done
                                ? locale.secretaryText("Task ended", "タスク終了")
                                : locale.secretaryText("Working", "作業中"))
                                .font(.scaled(.caption)).foregroundStyle(.secondary)
                            ForEach(card.events, id: \.id) { event in
                                if case .message(let message) = event.payload, !message.text.isEmpty {
                                    Text(message.text).textSelection(.enabled)
                                }
                            }
                            if card.done, !card.events.contains(where: {
                                if case .message(let message) = $0.payload { return !message.text.isEmpty && message.done == true }
                                return false
                            }) {
                                Text(locale.secretaryText("No result was reported.", "結果は報告されていません。"))
                                    .font(.scaled(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if work.stopStatus != nil { Text(work.label()).font(.scaled(.caption)).foregroundStyle(.secondary) }
                    if !failedTools.isEmpty {
                        Label(locale.secretaryText("Some tool actions did not complete. Technical details are available from More.", "一部のツール操作が完了しませんでした。「その他」から技術的な詳細を確認できます。"), systemImage: "exclamationmark.triangle")
                            .font(.scaled(.caption)).foregroundStyle(.secondary)
                    }
                }
            } else if let liveProgress {
                VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
                    WorkDurationLabel(work: work)
                        .font(.scaled(.caption))
                        .foregroundStyle(.secondary)
                    ProgressCardView(card: liveProgress, activity: work.activity)
                    ForEach(failedTools) { ToolRowView(activity: $0, active: work.running) }
                }
            } else {
                activity
            }
        }
        .onChange(of: work.running) { _, running in expanded = running }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: LayoutMetrics.tight) {
            disclosure
            if !expanded {
                ForEach(failedTools) { ToolRowView(activity: $0, active: work.running) }
            }
        }
    }

    private var disclosure: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: LayoutMetrics.inner) {
                Divider().overlay(YorozuPalette.rule)
                ForEach(work.entries) { entry in
                    switch entry {
                    case .thought(let thought): ReasoningView(thought: thought)
                    case .tools(let activities): ToolGroupView(activities: activities, active: work.running)
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
                    Text(work.running ? SecretaryUI.localized("IN PROGRESS") : SecretaryUI.localized("ACTIVITY"))
                        .font(.scaled(.caption2).weight(.semibold))
                        .tracking(0.8)
                        .foregroundStyle(work.running ? YorozuPalette.vermilion : YorozuPalette.sage)
                    WorkDurationLabel(work: work)
                        .font(.scaled(.subheadline).weight(.medium))
                        .foregroundStyle(YorozuPalette.ink)
                    if work.running, let status = work.status {
                        Text(status)
                            .font(.scaled(.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: LayoutMetrics.inner)
                if work.running { ProgressView().controlSize(.small).tint(YorozuPalette.vermilion) }
            }
            .frame(minHeight: controlTarget)
            .contentShape(.rect)
            .onTapGesture { withAnimation(.snappy) { expanded.toggle() } }
        }
        .buttonStyle(.plain)
        .yorozuPaperCard(padding: LayoutMetrics.stack)
    }

    private var failedTools: [ToolActivity] {
        work.entries.flatMap { entry -> [ToolActivity] in
            switch entry {
            case .tools(let activities): return activities
            case .delegation(let card): return toolActivities(from: card.events)
            default: return []
            }
        }.filter { [.failed, .denied].contains($0.status(active: work.running)) }
    }

    /// A live structured progress report is already the best summary of the work. Showing the
    /// generic disclosure above it repeats the same status and nests paper cards three deep.
    private var liveProgress: ProgressCardData? {
        guard work.running else { return nil }
        return work.entries.reversed().compactMap { entry -> ProgressCardData? in
            guard case .progress(let event) = entry,
                  case .progressCard(let card) = event.payload,
                  card.running else { return nil }
            return card
        }.first
    }
}

/// Only this text ticks; event grouping and the transcript never observe a clock.
private struct WorkDurationLabel: View {
    let work: TurnWork

    var body: some View {
        if work.running {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(work.label(at: context.date)).monospacedDigit()
            }
        } else {
            Text(work.label())
        }
    }
}

struct ReasoningView: View {
    let thought: ReasoningActivity
    @State private var expanded: Bool
    @AppStorage(ReplyFont.key) private var replyFont = ReplyFont.sans

    init(thought: ReasoningActivity) {
        self.thought = thought
        _expanded = State(initialValue: thought.running)
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(thought.text)
                .font(.scaled(.callout))
                .fontDesign(replyFont.design)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(thought.label)
                .font(.scaled(.caption))
                .foregroundStyle(.secondary)
        }
        .onChange(of: thought.running) { _, running in expanded = running }
    }
}
