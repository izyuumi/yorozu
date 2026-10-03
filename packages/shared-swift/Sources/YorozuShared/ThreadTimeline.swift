import Foundation
import Observation

/// Observation belongs to one thread. Typing or background agent traffic must not rebuild
/// every open transcript, and repeated view reads must not regroup unchanged tool history.
@MainActor @Observable
final class ThreadTimeline {
    var storedEvents: [YorozuEvent] = [] {
        didSet {
            let hidden = Set(storedEvents.flatMap { event -> [String] in
                if case .threadRewound(let data) = event.payload { return data.hiddenEventIds ?? [] }
                return []
            })
            visibleEvents = storedEvents.filter { event in
                if case .turnChanges(let data) = event.payload, hidden.contains(data.turnEventId) { return false }
                return event.payload.kind != .threadRewound && !hidden.contains(event.id)
            }
            cachedRows = nil
            withdrawalState = nil
        }
    }
    private var visibleEvents: [YorozuEvent] = []
    var events: [YorozuEvent] {
        get { visibleEvents }
        set { storedEvents = newValue }
    }
    @ObservationIgnored private var cachedRows: (generating: Bool, activeEventId: String?, excluding: Set<String>, rows: [ChatRow])?
    @ObservationIgnored private var withdrawalState: (ids: Set<String>, replies: Set<String>, stops: Set<String>, legacyTargets: Set<String>)?

    /// Each visible row asks whether Remove is available. Index terminal events once per
    /// timeline change instead of scanning the whole history again for every old message.
    func isUnfinishedMessage(id: String, completionID: String?) -> Bool {
        let source = events
        if withdrawalState == nil {
            var replies: Set<String> = []
            var stops: Set<String> = []
            var legacyTargets: Set<String> = []
            for event in source {
                if case .stopStatus(let status) = event.payload, status.status != .requested, status.status != .unknown {
                    stops.insert(status.targetEventId)
                }
                if case .message(let reply) = event.payload, reply.role == .agent, reply.done == true {
                    replies.insert(event.id)
                    if event.id.hasSuffix(":final") {
                        let base = event.id.dropLast(":final".count)
                        // Preserve legacy suffix matching even for message IDs with colons.
                        for colon in base.indices where base[colon] == ":" {
                            legacyTargets.insert(String(base[base.index(after: colon)...]))
                        }
                    }
                }
            }
            withdrawalState = (Set(source.map(\.id)), replies, stops, legacyTargets)
        }
        guard let state = withdrawalState else { return false }
        return state.ids.contains(id) && !state.stops.contains(id) && !state.legacyTargets.contains(id) &&
            !(completionID.map { state.replies.contains($0) } ?? false)
    }

    func rows(generating: Bool, activeEventId: String? = nil, excluding: Set<String> = []) -> [ChatRow] {
        // Read the observable input even on a cache hit, so SwiftUI tracks this thread.
        let source = events
        if let cachedRows, cachedRows.generating == generating, cachedRows.activeEventId == activeEventId,
           cachedRows.excluding == excluding { return cachedRows.rows }
        let rows = chatRows(from: source.filter { !excluding.contains($0.id) }, generating: generating,
                            activeEventId: activeEventId)
        cachedRows = (generating, activeEventId, excluding, rows)
        return rows
    }
}
