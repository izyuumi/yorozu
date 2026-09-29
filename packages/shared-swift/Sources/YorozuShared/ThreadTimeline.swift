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
        }
    }
    private var visibleEvents: [YorozuEvent] = []
    var events: [YorozuEvent] {
        get { visibleEvents }
        set { storedEvents = newValue }
    }
    @ObservationIgnored private var cachedRows: (generating: Bool, activeEventId: String?, rows: [ChatRow])?

    func rows(generating: Bool, activeEventId: String? = nil) -> [ChatRow] {
        // Read the observable input even on a cache hit, so SwiftUI tracks this thread.
        let source = events
        if let cachedRows, cachedRows.generating == generating, cachedRows.activeEventId == activeEventId { return cachedRows.rows }
        let rows = chatRows(from: source, generating: generating, activeEventId: activeEventId)
        cachedRows = (generating, activeEventId, rows)
        return rows
    }
}
