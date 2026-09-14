import SwiftUI

/// Delegated-agent trace UI: a collapsed inline card, plus a full-page renderer for callers that
/// need one. Shared so the Mac's local chat draws the same UI. The main agent's own tool use is
/// drawn in the thread itself, as grouped rows; see ``ToolGroupView``.

/// What a trace page shows. Pushed by value, so the page re-reads the live event list rather
/// than the snapshot the link was built from.
public enum TraceTarget: Hashable, Sendable {
    /// The main agent's own thoughts and tool calls.
    case main
    /// One delegation, keyed the way ``DelegationCard`` groups them.
    case delegation(agentId: String, startEventId: String)

    public var title: String {
        switch self {
        case .main: "Working"
        case .delegation(let agentId, _): agentId
        }
    }

    /// This target's rows out of a thread's events.
    public func rows(in events: [YorozuEvent]) -> [YorozuEvent] {
        switch self {
        case .main:
            mainTrace(from: events)
        case .delegation(_, let startEventId):
            delegationCards(from: events).first { $0.startEventId == startEventId }?.events ?? []
        }
    }
}

extension View {
    /// Attach once inside a navigation stack: every trace link below it pushes a page that
    /// keeps streaming, because `events` is read again whenever the source view updates.
    public func agentTraceDestination(
        events: @escaping () -> [YorozuEvent]
    ) -> some View {
        navigationDestination(for: TraceTarget.self) { target in
            AgentTraceView(target: target, events: target.rows(in: events()))
        }
    }
}

/// Inline card for one delegation: its status stays visible while its trace starts collapsed.
public struct DelegationCardView: View {
    private let card: DelegationCard
    @State private var expanded = false

    public init(card: DelegationCard) {
        self.card = card
    }

    public var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(traceEntries(from: card.events)) { entry in
                    switch entry {
                    case .tools(let activities):
                        ToolGroupView(activities: activities)
                    case .other(let event):
                        TraceRow(event: event)
                    }
                }
            }
            .padding(.top, 8)
            .padding(.leading, 26)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.clock")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.agentId)
                        .font(.subheadline.weight(.semibold))
                    Text(card.done ? "\(String(localized: "Done")) · \(card.events.count)" : String(localized: "Running…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if card.done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .buttonStyle(.plain)
        .accessibilityHint(expanded ? String(localized: "Hides the trace") : String(localized: "Shows the trace"))
    }
}

/// One agent's thoughts, tool calls and results in order. Live: the list is handed in afresh
/// every time the thread's events change.
public struct AgentTraceView: View {
    private let target: TraceTarget
    private let events: [YorozuEvent]

    public init(target: TraceTarget, events: [YorozuEvent]) {
        self.target = target
        self.events = events
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                if events.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                // Tool use arrives already grouped, so an unbroken run of it is one row that
                // opens rather than one row per call and per result.
                ForEach(traceEntries(from: events)) { entry in
                    switch entry {
                    case .tools(let activities):
                        ToolGroupView(activities: activities)
                    case .other(let event):
                        TraceRow(event: event)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(target.title)
    }
}

/// Everything in a trace that is not tool use: what the agent thought, and what it said.
private struct TraceRow: View {
    let event: YorozuEvent

    var body: some View {
        switch event.payload {
        case .thought(let data):
            row("brain", "thinking", data.text)
        case .message(let data):
            row("text.bubble", "reply", data.text)
        default:
            // Nothing else belongs in a trace; approvals, questions and progress have their
            // own cards in the thread itself.
            EmptyView()
        }
    }

    private func row(_ symbol: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.medium))
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
