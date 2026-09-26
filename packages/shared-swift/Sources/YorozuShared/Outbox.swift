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
    /// Consecutive transport errors; three change the caption, never stop automatic recovery.
    public var tries: Int
    /// Set before the first socket attempt. Until a host receipt arrives, delivery is uncertain.
    public var attemptedAt: Date?
    /// Persisted retry deadline; a relaunch must not turn a half-open send into a retry storm.
    public var nextAttemptAt: Date?
    /// Optional for caches written before automatic retry; counts sends even without errors.
    public var deliveryAttempts: Int?
    /// Local retry intent after the automatic-send window elapsed. Does not alter operation ID.
    public var reconfirmedAt: Date?
    /// Host evidence for a deadline-bearing message. Nil means admission is still uncertain.
    public var admissionStatus: AdmissionStatusData.Status?
    public var rejectionReason: String?
    /// A confirmed resend uses a new operation ID; keep the old bubble's disposition visible.
    public var replacementId: String?
    /// Persisted so relaunch does not flood the host with status queries.
    public var lastStatusQueryAt: Date?
    /// Correlates a host answer with the latest query, including across a relaunch.
    public var lastStatusQueryId: String?
    /// Old attempted messages lacked host-enforced deadlines. Wait out the relay buffer before
    /// offering a new ID, then require a fresh host status query.
    public var legacyHoldUntil: Date?

    public init(event: YorozuEvent, tries: Int = 0, attemptedAt: Date? = nil,
                nextAttemptAt: Date? = nil, deliveryAttempts: Int? = nil, reconfirmedAt: Date? = nil,
                admissionStatus: AdmissionStatusData.Status? = nil, rejectionReason: String? = nil,
                replacementId: String? = nil, lastStatusQueryAt: Date? = nil,
                lastStatusQueryId: String? = nil,
                legacyHoldUntil: Date? = nil) {
        self.event = event
        self.tries = tries
        self.attemptedAt = attemptedAt
        self.nextAttemptAt = nextAttemptAt
        self.deliveryAttempts = deliveryAttempts
        self.reconfirmedAt = reconfirmedAt
        self.admissionStatus = admissionStatus
        self.rejectionReason = rejectionReason
        self.replacementId = replacementId
        self.lastStatusQueryAt = lastStatusQueryAt
        self.lastStatusQueryId = lastStatusQueryId
        self.legacyHoldUntil = legacyHoldUntil
    }

    public var id: String { event.id }

    /// When it was typed, which is the event's own timestamp.
    public var queuedAt: Date { Date(timeIntervalSince1970: Double(event.ts) / 1000) }

    public var status: OutboxStatus { status(at: Date()) }

    public func status(at now: Date) -> OutboxStatus {
        if replacementId != nil { return .resent }
        if admissionStatus == .withdrawn { return .withdrawn }
        if admissionStatus == .rejected { return .rejected }
        if let legacyHoldUntil {
            return now >= legacyHoldUntil && admissionStatus == .unknown &&
                (lastStatusQueryAt ?? .distantPast) >= legacyHoldUntil ? .expired : .checking
        }
        if admissionStatus == .expired { return .expired }
        if admissionStatus == .unknown, let admissionDeadline,
           now >= admissionDeadline.addingTimeInterval(Outbox.clockLeadAllowance),
           (lastStatusQueryAt ?? .distantPast) >= admissionDeadline.addingTimeInterval(Outbox.clockLeadAllowance) {
            return .expired
        }
        if admissionDeadline != nil && isExpired(at: now) {
            return attemptedAt == nil ? .expired : .checking
        }
        if tries >= Outbox.maxTries { return attemptedAt == nil ? .failed : .unconfirmed }
        return attemptedAt == nil ? .queued : .confirming
    }

    public var admissionDeadline: Date? {
        guard case .message(let data) = event.payload, let deadline = data.admissionDeadline else { return nil }
        return Date(timeIntervalSince1970: Double(deadline) / 1000)
    }

    public func isExpired(at now: Date) -> Bool {
        if case .interrupt(let data) = event.payload, data.targetEventId != nil { return false }
        if case .approvalAnswer = event.payload { return false }
        if legacyHoldUntil != nil || admissionStatus == .expired || admissionStatus == .withdrawn { return true }
        if let admissionDeadline { return now >= admissionDeadline }
        return now.timeIntervalSince(reconfirmedAt ?? queuedAt) > Outbox.life
    }
}

/// What a bubble says until host acceptance is confirmed.
public enum OutboxStatus: String, Sendable, Equatable {
    case queued, confirming, unconfirmed, failed, checking, expired, rejected, withdrawalPending, withdrawn, resent

    /// The caption under the bubble.
    public var label: String {
        switch self {
        case .queued: String(localized: "Queued")
        case .confirming: String(localized: "Confirming delivery…")
        case .unconfirmed: String(localized: "Delivery unconfirmed")
        case .failed: String(localized: "Not sent")
        case .checking: String(localized: "Checking delivery…")
        case .expired: String(localized: "Expired · Still send?")
        case .rejected: String(localized: "Not sent")
        case .withdrawalPending: String(localized: "Withdrawal pending")
        case .withdrawn: String(localized: "Cancelled")
        case .resent: String(localized: "Reconfirmed as new message")
        }
    }

    public var symbol: String {
        switch self {
        case .queued: "clock"
        case .confirming: "arrow.up.circle"
        case .unconfirmed: "questionmark.circle"
        case .failed: "exclamationmark.circle"
        case .checking: "questionmark.circle"
        case .expired: "clock.badge.exclamationmark"
        case .rejected: "exclamationmark.circle"
        case .withdrawalPending: "hourglass"
        case .withdrawn: "xmark.circle"
        case .resent: "arrowshape.turn.up.right"
        }
    }
}

/// The queue's rules, kept out of the model so they can be checked without one.
public enum Outbox {
    public static let maxTries = 3
    /// Host accepts client timestamps this far ahead of its clock.
    public static let clockLeadAllowance: TimeInterval = 5 * 60
    /// Randomized capped retry, for both transport failures and a sent frame with no receipt.
    public static func retryDelay(after attempts: Int) -> TimeInterval {
        min(60, pow(2, Double(min(max(attempts - 1, 0), 6))) * Double.random(in: 0.8...1.2))
    }
    /// How long a message is worth sending by itself. Past that it is not dropped — the bubble
    /// is in the transcript and has to say something honest — but it stops being sent on a
    /// reconnect two days later and waits to be retried by hand.
    public static let life: TimeInterval = 48 * 60 * 60

    /// Housekeeping over a queue, applied whenever it is read or written. Pure, so the clock
    /// is an argument rather than something a test has to move.
    public static func pruned(_ items: [OutboxItem], now: Date = Date()) -> [OutboxItem] {
        let aged = items.map { item -> OutboxItem in
            if item.admissionDeadline != nil { return item }
            guard now.timeIntervalSince(item.reconfirmedAt ?? item.queuedAt) > life else { return item }
            var item = item
            item.tries = max(item.tries, maxTries)
            return item
        }
        return aged
    }
}
