import SwiftUI

/// The drill-down: an inline card per delegation, a collapsed row for the main agent's own
/// tool use, and the trace page both push. Shared so the Mac's local chat draws the same ones.

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

/// Inline card for one delegation: who is working, whether they still are, and a way in.
public struct DelegationCardView: View {
    private let card: DelegationCard

    public init(card: DelegationCard) {
        self.card = card
    }

    public var body: some View {
        NavigationLink(value: TraceTarget.delegation(agentId: card.agentId, startEventId: card.startEventId)) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.clock")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.agentId)
                        .font(.subheadline.weight(.semibold))
                    Text(card.done ? "done · \(card.events.count) steps" : "running…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if card.done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

/// The main agent's own tool use, collapsed to one line under the latest message and
/// expanding into the same trace page. Renders nothing until it has actually done something.
public struct MainActivityRow: View {
    private let events: [YorozuEvent]

    /// Takes the whole thread; it picks its own rows out of it.
    public init(events: [YorozuEvent]) {
        self.events = events
    }

    public var body: some View {
        let trace = mainTrace(from: events)
        if let last = trace.last {
            NavigationLink(value: TraceTarget.main) {
                HStack(spacing: 8) {
                    if case .toolCall = last.payload {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "wrench.and.screwdriver").font(.caption)
                    }
                    Text(working(last))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// A tool call is still in flight; anything else is the last thing that happened.
    private func working(_ event: YorozuEvent) -> String {
        switch event.payload {
        case .toolCall(let data): "working… \(data.name)"
        case .toolResult(let data): "\(data.name(in: events)) \(data.ok ? "done" : "failed")"
        default: "working…"
        }
    }
}

extension ToolResultData {
    /// A result carries only its call id, so the name comes from the call it answers.
    fileprivate func name(in events: [YorozuEvent]) -> String {
        for event in events {
            if case .toolCall(let call) = event.payload, call.callId == callId { return call.name }
        }
        return "tool"
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
        List {
            if events.isEmpty {
                Text("Nothing yet.").foregroundStyle(.secondary)
            }
            ForEach(events, id: \.id) { TraceRow(event: $0) }
        }
        .navigationTitle(target.title)
    }
}

private struct TraceRow: View {
    let event: YorozuEvent

    var body: some View {
        switch event.payload {
        case .thought(let data):
            row("brain", "thinking", data.text)
        case .toolCall(let data):
            row("wrench.and.screwdriver", data.name, data.argsSummary)
        case .toolResult(let data):
            row(data.ok ? "checkmark.circle" : "exclamationmark.triangle", data.ok ? "result" : "failed", data.output)
        case .message(let data):
            row("text.bubble", "reply", data.text)
        default:
            // Nothing else belongs in a trace; approvals and thread events have their own UI.
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
    }
}
