import Foundation
import Observation

/// Observation belongs to one thread. Typing or background agent traffic must not rebuild
/// every open transcript, and repeated view reads must not regroup unchanged tool history.
@MainActor @Observable
final class ThreadTimeline {
    var events: [YorozuEvent] = [] {
        didSet { cachedRows = nil }
    }
    @ObservationIgnored private var cachedRows: (generating: Bool, rows: [ChatRow])?

    func rows(generating: Bool) -> [ChatRow] {
        // Read the observable input even on a cache hit, so SwiftUI tracks this thread.
        let source = events
        if let cachedRows, cachedRows.generating == generating { return cachedRows.rows }
        let rows = chatRows(from: source, generating: generating)
        cachedRows = (generating, rows)
        return rows
    }
}
