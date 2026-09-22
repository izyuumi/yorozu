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

/// Everything the main agent did between one message and the next, as one row. While it runs
/// the row is a single live status line; when it is over the row collapses to how many steps
/// it took and how long, and opens to the full trace — thoughts, tool runs and delegations in
/// the order they happened. Cards that need a person stay outside it.
public struct TurnWork: Identifiable, Equatable, Sendable {
    /// What the trace is made of, in order.
    public enum Entry: Identifiable, Equatable, Sendable {
        case thought(YorozuEvent)
        /// An unbroken run of the main agent's tool calls, drawn as one group.
        case tools([ToolActivity])
        case delegation(DelegationCard)
        /// The newest revision of a progress card the job reported.
        case progress(YorozuEvent)

        public var id: String {
            switch self {
            case .thought(let event): event.id
            case .tools(let activities): "tools-\(activities.first?.callId ?? "")"
            case .delegation(let card): "delegation-\(card.id)"
            case .progress(let event): event.id
            }
        }
    }

    /// Id of the first event in the work, which is what the row is keyed on.
    public var startEventId: String
    public var entries: [Entry]
    /// Epoch milliseconds of the first and latest event in it.
    public var startedAt: Int
    public var lastAt: Int
    /// Whether the turn this work belongs to is still running. Set by the caller: the events
    /// alone cannot tell "paused" from "finished".
    public var running: Bool

    public var id: String { "work-\(startEventId)" }

    public init(startEventId: String, entries: [Entry], startedAt: Int, lastAt: Int, running: Bool) {
        self.startEventId = startEventId
        self.entries = entries
        self.startedAt = startedAt
        self.lastAt = lastAt
        self.running = running
    }

    /// Tool calls, counting a delegation's own as well: what "N steps" counts.
    public var steps: Int {
        entries.reduce(0) { count, entry in
            switch entry {
            case .tools(let activities): count + activities.count
            case .delegation(let card): count + toolActivities(from: card.events).count
            default: count
            }
        }
    }

    public var failed: Int {
        entries.reduce(0) { count, entry in
            guard case .tools(let activities) = entry else { return count }
            return count + activities.filter { !$0.running && !$0.ok }.count
        }
    }

    /// Wall time between the first and latest event, never negative.
    public var duration: Duration { .milliseconds(max(0, lastAt - startedAt)) }

    /// The one line shown while the work runs: what is happening right now. A progress card's
    /// title wins when there is one, because it was written to be read; otherwise the newest
    /// thought, running tool or running delegation.
    public var status: String? { status(includingProgress: true) }

    /// What the agent is doing right now, never a progress card's title: the line a live card
    /// carries under its steps, which only move when the agent reports them.
    public var activity: String? { status(includingProgress: false) }

    private func status(includingProgress: Bool) -> String? {
        for entry in entries.reversed() {
            switch entry {
            case .progress(let event):
                if includingProgress, case .progressCard(let card) = event.payload {
                    guard let percent = card.percent else { return card.title }
                    return "\(card.title) · \(Int(percent.rounded()))%"
                }
            case .thought(let event):
                if case .thought(let data) = event.payload, !data.text.isEmpty { return data.text }
            case .tools(let activities):
                if let live = activities.last(where: { $0.running }) ?? activities.last { return live.name }
            case .delegation(let card):
                return card.agentId
            }
        }
        return nil
    }
}

/// One line of the thread: a message bubble, the work the main agent did between messages,
/// or a card waiting to be answered. What a specialist did lives behind the work row.
public enum ChatRow: Identifiable, Equatable, Sendable {
    case message(YorozuEvent)
    case work(TurnWork)
    case approval(YorozuEvent)
    /// A rule Yorozu is offering, not one it has applied.
    case proposal(YorozuEvent)
    case question(YorozuEvent)

    public var id: String {
        switch self {
        case .message(let event): event.id
        case .work(let work): work.id
        case .approval(let event): event.id
        case .proposal(let event): event.id
        case .question(let event): event.id
        }
    }
}

/// The thread in render order.
///
/// - Parameter generating: whether a turn is running in this thread. The last work row is
///   live while it is, and settled once it is not; the events alone cannot say which.
public func chatRows(from events: [YorozuEvent], generating: Bool = false) -> [ChatRow] {
    // A final reply is the turn's terminator, even when a reconnect replays tool activity
    // after that reply reached this client. Keep user-message boundaries intact, but render
    // each completed main-agent reply after every other event in its turn.
    var ordered: [YorozuEvent] = []
    var turn: [YorozuEvent] = []
    func closeTurn() {
        ordered.append(contentsOf: turn.filter { event in
            guard event.parentAgentId == nil,
                case .message(let data) = event.payload
            else { return true }
            return data.role != .agent || data.done != true
        })
        ordered.append(contentsOf: turn.filter { event in
            guard event.parentAgentId == nil,
                case .message(let data) = event.payload
            else { return false }
            return data.role == .agent && data.done == true
        })
        turn.removeAll(keepingCapacity: true)
    }
    for event in events {
        if case .message(let data) = event.payload, data.role == .user {
            closeTurn()
            ordered.append(event)
        } else {
            turn.append(event)
        }
    }
    closeTurn()

    // Progress revisions keep unique transport IDs, so an offline client's cursor cannot
    // skip an update. Only the newest revision of each card belongs in the timeline.
    var latestProgress: [String: String] = [:]
    for event in events {
        if case .progressCard(let data) = event.payload { latestProgress[data.cardId] = event.id }
    }
    let cards = delegationCards(from: events)
    let byStart = Dictionary(cards.map { ($0.startEventId, $0) }, uniquingKeysWith: { first, _ in first })

    let activities = Dictionary(
        toolActivities(from: mainTrace(from: events)).map { ($0.callId, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    var rows: [ChatRow] = []
    var transientStatus: YorozuEvent?
    /// The work row being filled: everything the main agent does between one message and the
    /// next lands in it, so a long turn reads as one line rather than a stack.
    var work: TurnWork?
    /// The run of tool use being filled inside it, so the next call in an unbroken run joins
    /// it rather than starting a second group under the first.
    var open: [ToolActivity] = []
    func closeTools() {
        if !open.isEmpty { work?.entries.append(.tools(open)) }
        open = []
    }
    func touch(_ event: YorozuEvent) {
        var current = work ?? TurnWork(startEventId: event.id, entries: [], startedAt: event.ts, lastAt: event.ts, running: false)
        current.lastAt = max(current.lastAt, event.ts)
        work = current
    }
    func add(_ entry: TurnWork.Entry, at event: YorozuEvent) {
        closeTools()
        touch(event)
        work?.entries.append(entry)
    }
    func closeWork() {
        closeTools()
        if let done = work { rows.append(.work(done)) }
        work = nil
    }

    for event in ordered {
        if case .thought(let data) = event.payload,
            event.parentAgentId == nil,
            data.transient == true
        {
            transientStatus = event
            continue
        }
        // Any substantive event supersedes startup/lifecycle chrome. User messages occur
        // before those statuses, so they do not clear a status that has not arrived yet.
        transientStatus = nil
        // A specialist's tool use belongs to its card, so only the main agent's own is
        // grouped here. Results are already folded into the call they answered.
        if event.parentAgentId == nil {
            switch event.payload {
            case .toolCall(let data):
                if let activity = activities[data.callId] {
                    touch(event)
                    open.append(activity)
                }
                continue
            case .toolResult:
                if work != nil { touch(event) }
                continue
            default:
                break
            }
        }

        if let card = byStart[event.id] { add(.delegation(card), at: event) }
        switch event.payload {
        case .thought where event.parentAgentId == nil:
            add(.thought(event), at: event)
        case .message where event.parentAgentId == nil:
            closeWork()
            rows.append(.message(event))
        // Cards that need a person are never folded away, wherever they were raised: one put
        // up inside a delegation still has to reach the thread, because the agent is parked
        // on it and nothing happens until it is answered. The work row closes on them, so the
        // card sits below the work that led to it.
        case .approvalCard:
            closeWork()
            rows.append(.approval(event))
        case .ruleProposal:
            closeWork()
            rows.append(.proposal(event))
        case .questionCard:
            closeWork()
            rows.append(.question(event))
        // A progress card is only ever read, and while the work runs its title is the status
        // line, so it belongs inside the work rather than beside it.
        case .progressCard:
            if case .progressCard(let data) = event.payload, latestProgress[data.cardId] == event.id {
                add(.progress(event), at: event)
            }
        default:
            break
        }
    }
    closeWork()
    // The turn is still going: the last work row is live, whichever row that is. Nothing after
    // a reply can be live — the reply ended it — and a turn with no work yet has no row.
    if generating, let last = rows.indices.last, case .work(var live) = rows[last] {
        live.running = true
        rows[last] = .work(live)
    }
    if let transientStatus {
        rows.append(.work(TurnWork(
            startEventId: transientStatus.id,
            entries: [.thought(transientStatus)],
            startedAt: transientStatus.ts,
            lastAt: transientStatus.ts,
            running: true
        )))
    }
    return rows
}

/// One short line for a trace row — `path=/tmp/x, depth=2` — clipped so a pasted file cannot
/// push the row off the screen.
func argsLine(_ args: [String: JSONValue]) -> String {
    let body = args
        .sorted { $0.key < $1.key }
        .map { "\($0.key)=\($0.value.compact)" }
        .joined(separator: ", ")
    return body.count > 80 ? "\(body.prefix(80))…" : body
}

extension ToolCallData {
    /// See ``argsLine(_:)``.
    public var argsSummary: String { argsLine(args) }
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


/// One tool call and the result that answered it, which is what a trace row draws. A call
/// still in flight has no result yet — that, not a flag, is what "running" means here.
public struct ToolActivity: Identifiable, Equatable, Sendable {
    public var callId: String
    public var name: String
    public var args: [String: JSONValue]
    /// Epoch milliseconds of the call, and of the result once it landed.
    public var startedAt: Int
    public var finishedAt: Int?
    public var output: String?
    public var ok: Bool
    /// Whether ``output`` is only the head of the result, the rest being on the Mac.
    public var truncated: Bool

    public var id: String { callId }
    public var running: Bool { finishedAt == nil }

    public init(
        callId: String,
        name: String,
        args: [String: JSONValue],
        startedAt: Int,
        finishedAt: Int? = nil,
        output: String? = nil,
        ok: Bool = true,
        truncated: Bool = false
    ) {
        self.callId = callId
        self.name = name
        self.args = args
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.output = output
        self.ok = ok
        self.truncated = truncated
    }

    /// How long the tool took. Nil while it is still running, and never negative: the two
    /// stamps are made on the same machine, but a clock that stepped back is not a reason to
    /// draw "-2s".
    public var duration: Duration? {
        guard let finishedAt else { return nil }
        return .milliseconds(max(0, finishedAt - startedAt))
    }

    /// SF Symbol for the tool's family, so a trace is skimmable without reading the names.
    public var symbol: String {
        // Claude Code's and Codex's own tools, by the names they give them.
        switch name {
        case "Bash": return "terminal"
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit": return "doc"
        case "Glob", "Grep": return "magnifyingglass"
        case "WebFetch", "WebSearch": return "globe"
        case "Task", "Agent": return "person.badge.clock"
        case "TodoWrite": return "list.bullet"
        case "AskUserQuestion": return "questionmark.bubble"
        default: break
        }
        if name.hasPrefix("browser") || name == "fetch" || name == "web_search" { return "globe" }
        if name.hasPrefix("fs_") { return "doc" }
        if name.hasPrefix("calendar") || name.hasPrefix("reminders") { return "calendar" }
        if name.hasPrefix("mail") || name == "email" { return "envelope" }
        if name == "request_permission" { return "hand.raised" }
        if name == "ask_user" { return "questionmark.bubble" }
        if name == "report_progress" { return "list.bullet" }
        if name == "shell" { return "terminal" }
        if name.hasPrefix("screen") || name.hasPrefix("input_") { return "cursorarrow.rays" }
        if name == "delegate" { return "person.badge.clock" }
        if name == "remember" || name == "read_transcripts" { return "brain" }
        if name.hasSuffix("schedule") { return "clock" }
        return "wrench.and.screwdriver"
    }

    /// One short line under the name. See ``argsLine(_:)``.
    public var argsSummary: String { argsLine(args) }

    /// Every argument, one per line, for the expanded row. Long values are kept whole: the
    /// expansion is where somebody has asked to see the thing in full.
    public var argsDetail: String {
        args.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.compact)" }.joined(separator: "\n")
    }
}

/// Pairs each tool call in a trace with the result that answered it, in call order. A result
/// whose call is not in the same list is dropped: it belongs to a trace this is not.
public func toolActivities(from events: [YorozuEvent]) -> [ToolActivity] {
    var activities: [ToolActivity] = []
    var index: [String: Int] = [:]
    for event in events {
        switch event.payload {
        case .toolCall(let data):
            index[data.callId] = activities.count
            activities.append(
                ToolActivity(callId: data.callId, name: data.name, args: data.args, startedAt: event.ts)
            )
        case .toolResult(let data):
            guard let at = index[data.callId] else { continue }
            activities[at].finishedAt = event.ts
            activities[at].output = data.output
            activities[at].ok = data.ok
            activities[at].truncated = data.truncated == true
        default:
            continue
        }
    }
    return activities
}

/// One row of a trace page: a run of tool calls, collapsed into a single group, or one of the
/// other things an agent emitted. Consecutive tool use is one group, so a turn that ran eight
/// commands is one line saying so rather than sixteen.
public enum TraceEntry: Identifiable, Equatable, Sendable {
    case tools([ToolActivity])
    case other(YorozuEvent)

    public var id: String {
        switch self {
        case .tools(let activities): activities.first?.callId ?? "tools"
        case .other(let event): event.id
        }
    }
}

/// A trace in render order: runs of tool activity grouped, everything else left alone.
public func traceEntries(from events: [YorozuEvent]) -> [TraceEntry] {
    let activities = Dictionary(
        toolActivities(from: events).map { ($0.callId, $0) },
        uniquingKeysWith: { first, _ in first }
    )
    var entries: [TraceEntry] = []
    /// The group being filled, so the next call in an unbroken run joins it.
    var open: [ToolActivity] = []
    func close() {
        if !open.isEmpty { entries.append(.tools(open)) }
        open = []
    }

    for event in events {
        switch event.payload {
        case .toolCall(let data):
            if let activity = activities[data.callId] { open.append(activity) }
        case .toolResult:
            // Already folded into the call it answered; it never breaks a run on its own.
            continue
        default:
            close()
            entries.append(.other(event))
        }
    }
    close()
    return entries
}

/// A unified diff found in a tool's output, so an edit reads as an edit rather than as a wall
/// of text with stray plus signs in it.
public struct UnifiedDiff: Equatable, Sendable {
    public struct Line: Identifiable, Equatable, Sendable {
        public enum Kind: Sendable { case added, removed, meta, context }
        /// The line's own index in the diff: two identical context lines are still two lines.
        public var id: Int
        public var text: String
        public var kind: Kind
    }

    public var lines: [Line]
    public var added: Int
    public var removed: Int

    /// `+12 −3`, the count a collapsed row shows.
    public var counts: String { "+\(added) −\(removed)" }
}

/// Reads `text` as a unified diff, or returns nil when it is not one.
///
/// A hunk header is what decides it: `+` and `-` at the start of a line are ordinary enough in
/// ordinary output, and `@@ … @@` is not. The file headers are optional, because plenty of
/// tools print the hunks alone.
public func unifiedDiff(in text: String) -> UnifiedDiff? {
    let raw = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard raw.contains(where: { $0.hasPrefix("@@") && $0.dropFirst(2).contains("@@") }) else {
        return nil
    }
    var lines: [UnifiedDiff.Line] = []
    var added = 0
    var removed = 0
    for (index, line) in raw.enumerated() {
        let kind: UnifiedDiff.Line.Kind
        // The file headers come first and are marked with three of the character, so they are
        // tested before the single-character add and remove.
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@") {
            kind = .meta
        } else if line.hasPrefix("+") {
            kind = .added
            added += 1
        } else if line.hasPrefix("-") {
            kind = .removed
            removed += 1
        } else {
            kind = .context
        }
        lines.append(UnifiedDiff.Line(id: index, text: line, kind: kind))
    }
    return UnifiedDiff(lines: lines, added: added, removed: removed)
}
