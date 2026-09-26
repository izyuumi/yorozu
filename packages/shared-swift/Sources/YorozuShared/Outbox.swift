import Foundation

/// A message typed with nowhere to send it: the transport has not paired yet, or it has and the
/// Mac behind the relay is asleep. It waits here instead of being lost, is persisted with the
/// rest of the thread cache, and goes out in the order it was typed the moment the link is back.
///
/// The event is kept whole — id, timestamp and all — so a flush re-sends exactly what would have
/// gone out at the time. The runtime keys on the id, so a message that did land before the
/// connection dropped is deduped rather than said twice.
public struct OutboxItem: Codable, Equatable, Sendable, Identifiable {
    public var event: YorozuEvent
    /// Attempts that have failed. Three of them is where the queue stops trying by itself and
    /// starts asking: a message that will not go is the user's to retry or to let go.
    public var tries: Int
    /// Set before the first socket attempt. Until a host receipt arrives, delivery is uncertain.
    public var attemptedAt: Date?

    public init(event: YorozuEvent, tries: Int = 0, attemptedAt: Date? = nil) {
        self.event = event
        self.tries = tries
        self.attemptedAt = attemptedAt
    }

    public var id: String { event.id }

    /// When it was typed, which is the event's own timestamp.
    public var queuedAt: Date { Date(timeIntervalSince1970: Double(event.ts) / 1000) }

    public var status: OutboxStatus {
        tries >= Outbox.maxTries ? .failed : attemptedAt == nil ? .queued : .confirming
    }
}

/// What a bubble says until host acceptance is confirmed.
public enum OutboxStatus: String, Sendable, Equatable {
    case queued, confirming, failed

    /// The caption under the bubble.
    public var label: String {
        switch self {
        case .queued: String(localized: "Waiting to send")
        case .confirming: String(localized: "Confirming delivery…")
        case .failed: String(localized: "Not sent")
        }
    }

    public var symbol: String {
        switch self {
        case .queued: "clock"
        case .confirming: "arrow.up.circle"
        case .failed: "exclamationmark.circle"
        }
    }
}

/// The queue's rules, kept out of the model so they can be checked without one.
public enum Outbox {
    public static let maxTries = 3
    /// How long a message is worth sending by itself. Past that it is not dropped — the bubble
    /// is in the transcript and has to say something honest — but it stops being sent on a
    /// reconnect two days later and waits to be retried by hand.
    public static let life: TimeInterval = 48 * 60 * 60

    /// Housekeeping over a queue, applied whenever it is read or written. Pure, so the clock
    /// is an argument rather than something a test has to move.
    public static func pruned(_ items: [OutboxItem], now: Date = Date()) -> [OutboxItem] {
        let aged = items.map { item -> OutboxItem in
            guard now.timeIntervalSince(item.queuedAt) > life else { return item }
            var item = item
            item.tries = max(item.tries, maxTries)
            return item
        }
        return aged
    }
}
