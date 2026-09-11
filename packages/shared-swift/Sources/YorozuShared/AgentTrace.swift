import Foundation

/// Turning a thread's raw events into what the chat renders: one inline card per delegation,
/// and the main agent's own tool activity. Pure functions, so the views stay dumb and the
/// grouping is testable on its own. See docs/spec-v1.html section 3.

/// One delegation's worth of events, as the thread draws it.
public struct DelegationCard: Identifiable, Equatable, Sendable {
    /// The specialist's name, which is also the title on the card.
    public var agentId: String
    /// Id of the delegation's first event. Cards are grouped per delegation rather than per
    /// agent, so the same specialist called twice is two cards.
    public var startEventId: String
    /// Its thoughts, tool calls, results and final message, in arrival order.
    public var events: [YorozuEvent]
    /// Set by the specialist's last message; until then the card is still running.
    public var done: Bool

    public var id: String { startEventId }

    public init(agentId: String, startEventId: String, events: [YorozuEvent], done: Bool) {
        self.agentId = agentId
        self.startEventId = startEventId
        self.events = events
        self.done = done
    }
}

/// Groups the events a delegated agent emitted into one card per delegation.
///
/// A delegated event is one carrying a `parentAgentId` — that, not the agent's name, is what
/// the runtime tags a specialist's events with, and it can never catch the phone's own.
public func delegationCards(from events: [YorozuEvent]) -> [DelegationCard] {
    var cards: [DelegationCard] = []
    /// The still-running card per agent: a finished one is closed, so the next event from that
    /// agent starts a fresh card rather than reopening the old one.
    var running: [String: Int] = [:]

    for event in events {
        guard event.parentAgentId != nil else { continue }
        let index: Int
        if let open = running[event.agentId] {
            index = open
        } else {
            cards.append(
                DelegationCard(
                    agentId: event.agentId,
                    startEventId: event.id,
                    events: [],
                    done: false
                )
            )
            index = cards.count - 1
            running[event.agentId] = index
        }
        cards[index].events.append(event)
        if case .message(let data) = event.payload, data.done == true {
            cards[index].done = true
            running[event.agentId] = nil
        }
    }
    return cards
}

/// The main agent's own trace: what it thought and which tools it ran, in order. Its replies
/// are messages in the thread, so they are not repeated here.
public func mainTrace(from events: [YorozuEvent]) -> [YorozuEvent] {
    events.filter { event in
        guard event.parentAgentId == nil else { return false }
        switch event.payload {
        case .thought, .toolCall, .toolResult: return true
        default: return false
        }
    }
}

/// One line of the thread: a message bubble, a delegation card in the place the delegation
/// started, or an approval card waiting to be answered. Everything else an agent emitted lives
/// behind its card.
public enum ChatRow: Identifiable, Equatable, Sendable {
    case message(YorozuEvent)
    case delegation(DelegationCard)
    case approval(YorozuEvent)

    public var id: String {
        switch self {
        case .message(let event): event.id
        case .delegation(let card): card.id
        case .approval(let event): event.id
        }
    }
}

/// The thread in render order.
public func chatRows(from events: [YorozuEvent]) -> [ChatRow] {
    let cards = delegationCards(from: events)
    let byStart = Dictionary(cards.map { ($0.startEventId, $0) }, uniquingKeysWith: { first, _ in first })

    var rows: [ChatRow] = []
    for event in events {
        if let card = byStart[event.id] {
            rows.append(.delegation(card))
        } else if event.parentAgentId == nil, case .message = event.payload {
            rows.append(.message(event))
        } else if case .approvalCard = event.payload {
            // Approval cards are never folded away: one raised inside a delegation still has to
            // reach the thread, because nothing happens until the user answers it.
            rows.append(.approval(event))
        }
    }
    return rows
}

extension ToolCallData {
    /// One short line for a trace row — `path=/tmp/x, depth=2` — clipped so a pasted file
    /// cannot push the row off the screen.
    public var argsSummary: String {
        let body = args
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.compact)" }
            .joined(separator: ", ")
        return body.count > 80 ? "\(body.prefix(80))…" : body
    }
}

extension JSONValue {
    /// Compact one-line rendering, for trace rows rather than for the wire.
    public var compact: String {
        switch self {
        case .null: "null"
        case .bool(let value): String(value)
        // Wire data, so no assumption that it fits an Int: NaN and the huge stay as doubles.
        case .number(let value):
            value.rounded() == value && value.magnitude < 1e15 ? String(Int(value)) : String(value)
        case .string(let value): value
        case .array(let values): "[\(values.map(\.compact).joined(separator: ", "))]"
        case .object(let values): "{\(values.keys.sorted().joined(separator: ", "))}"
        }
    }
}
