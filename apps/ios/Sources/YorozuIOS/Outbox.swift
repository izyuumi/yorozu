import Foundation
import UIKit
import UserNotifications
import YorozuWire

/// A user message's mark (#314). Forward only: Sending → Delivered → Read. Not delivered comes from a
/// refusal or the 24-hour deadline, and only Resend takes it back to Sending.
enum MarkState: String, Codable, Sendable {
    case sending, delivered, read, notDelivered

    /// Whether `new` may replace `old` without a Resend.
    static func allows(_ old: MarkState?, _ new: MarkState) -> Bool {
        switch (old, new) {
        case (nil, _): true
        case (.read?, _): false
        case (_, .notDelivered): old != .notDelivered
        // The Mac's stored copy is proof it arrived, even after a local deadline passed.
        case (.notDelivered?, let new): new == .delivered || new == .read
        case (.sending?, let new): new == .delivered || new == .read
        case (.delivered?, let new): new == .read
        }
    }
}

/// Messages the Mac has not stored yet, and the marks and times of messages not yet Read. One JSON
/// file in `Application Support/Outbox/`, protected like `MirrorCache` so a background flush can read it.
struct Outbox: Codable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var event: YorozuEvent
        /// The phone's send time (epoch ms): the event's `ts`, renewed by Resend.
        var sentAt: Int
        /// When the relay replied `accepted` (epoch ms).
        var deliveredAt: Int?
        /// The relay holds the frame until the Mac is online.
        var buffered = false
        /// The Mac has it (`receipt` or the stored copy): never sent again, kept for its times until Read.
        var stored = false
        /// Why it was not delivered.
        var reason: String?
        /// The message's files (#316): their copies wait in `UploadStore` and go up only over a live session
        /// with the Mac, never through the relay's buffer. The text waits with them, as one unit.
        var files: [AttachmentInfo]?
        /// A job's own input (#319): the job's sub-chat, where its bubble shows until the stored copy arrives.
        var topicId: String?

        var id: String { event.id }
        var deadline: Int {
            if case .message(let message) = event.payload, let deadline = message.admissionDeadline { return deadline }
            return sentAt + Outbox.lifetime
        }
    }

    /// The phone's own session key (base64url): a file left by another pairing is never read.
    var owner: String
    var items: [Item]
    var marks: [String: MarkState]

    /// The relay's buffer lifetime and every message's admission deadline: 24 h.
    static let lifetime = 86_400_000
    static let file = ProtectedFile(folder: "Outbox", name: "outbox.json")
}

/// What one user message's mark and its details show.
struct Delivery: Equatable {
    var state: MarkState
    /// A frame is on its way to the relay: the Sending mark spins.
    var inFlight: Bool
    /// In flight, or sent without `accepted` on the link that is up: the word says Sending.
    var sent: Bool
    var sentAt: Int
    /// The relay's `accepted`.
    var deliveredAt: Int?
    /// Held by the relay, not yet stored by the Mac: when the relay drops it.
    var expiresAt: Int?
    /// The Mac's `created`, once its stored copy is here.
    var receivedAt: Int?
    var readAt: Int?
    var reason: String?
    /// How many files the message carries.
    var files = 0
    /// The files' upload, 0 to 1, while it runs.
    var upload: Double?
    /// The host has it (its `receipt` or stored copy), not just the relay.
    var onHost = false

    /// The mark's step: Delivered (`MarkState`) splits into Sent (the relay's `accepted`) and Delivered (on the host).
    enum Step { case sending, sent, delivered, read, notDelivered }

    var step: Step {
        switch state {
        case .sending: .sending
        case .delivered: onHost ? .delivered : .sent
        case .read: .read
        case .notDelivered: .notDelivered
        }
    }

    /// The single symbol of the sending and failed marks.
    var symbol: String {
        state == .notDelivered ? "exclamationmark.circle" : "circle.dotted"
    }

    /// The status word VoiceOver reads after the message.
    var word: String {
        switch step {
        case .sending: sent ? String(localized: "Sending") : String(localized: "Waiting for connection")
        case .sent: String(localized: "Sent")
        case .delivered: String(localized: "Delivered")
        case .read: String(localized: "Read")
        case .notDelivered: notDelivered
        }
    }

    var notDelivered: String {
        reason.map { String(localized: "Not delivered: \($0)") } ?? String(localized: "Not delivered")
    }

    /// Received more than a minute after it was sent: the details show both times.
    var delayed: Bool { receivedAt.map { $0 - sentAt > 60_000 } ?? false }
}

/// The two local notifications (#314). Neither ever includes message content.
enum LocalNotices {
    private static var center: UNUserNotificationCenter { .current() }
    private static let waitingId = "outbox-waiting"

    /// Asked the first time a message has to wait in the outbox or the relay holds one for an away
    /// Mac; iOS shows the prompt only once.
    static func requestPermission() {
        Task { await askPermission() }
    }

    /// The same request, awaited: true when notifications are allowed. Onboarding's Allow Notifications.
    @discardableResult
    static func askPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// 24 h after the relay buffered it (`accepted` with `buffered`), identified by the message id.
    static func scheduleExpiry(_ id: String) {
        let content = UNMutableNotificationContent()
        content.body = String(localized: "A message to the host expired without being read.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(Outbox.lifetime / 1000), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }

    static func cancelExpiry(_ id: String) {
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    static func postWaiting(_ count: Int) {
        let content = UNMutableNotificationContent()
        content.body = String(localized: "\(count) messages waiting to send")
        center.add(UNNotificationRequest(identifier: waitingId, content: content, trigger: nil))
    }

    static func clearWaiting() {
        center.removeDeliveredNotifications(withIdentifiers: [waitingId])
    }
}

/// Background execution time, ended once by `end()` or by iOS's expiry (after `onExpiry`).
@MainActor
final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String, onExpiry: @escaping @MainActor () -> Void = {}) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            MainActor.assumeIsolated {
                onExpiry()
                end()
            }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
