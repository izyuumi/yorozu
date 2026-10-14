import Foundation
#if canImport(UIKit)
import UIKit
#endif
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
        /// The draft this message was sent from and that draft's edit time (#405): a draft still saved with that time after a
        /// crash is the sent one, and goes when the outbox loads, so it is never sent twice.
        var draftKey: String?
        var draftStamp: Int?

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
    /// The unsent reminder (#405): when the one scheduled fires (epoch ms), and the latest fire time already passed, which
    /// covers every message due by then. Optional so an older file still loads.
    var reminderAt: Int?
    var reminderCovered: Int?
    /// Drafts sent but not yet removed from disk (key → the sent revision's edit time), kept until their removal is written.
    var consumed: [String: Int]?

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

/// The local notifications (#314, #405). None ever includes message content.
enum LocalNotices {
    private static var center: UNUserNotificationCenter { .current() }
    private static let waitingId = "outbox-waiting"
    private static let reminderId = "outbox-unsent"

    /// Settings › Unsent reminder (#405): minutes after Send with no receipt from the host; 0 is Off. On this device only.
    static let reminderKey = "unsentReminderMinutes"
    static let reminderChoices = [0, 15, 30, 60, 120, 360]
    static var reminderMinutes: Int {
        get { UserDefaults.standard.object(forKey: reminderKey) as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: reminderKey) }
    }

    /// One reminder for every message the host has not received by its time, grouped; scheduled with the system, so it
    /// fires while the app is suspended and with no network. `count` messages are past their reminder age then.
    /// `done` hears whether the system took it.
    static func scheduleReminder(at ms: Int, count: Int, done: @escaping @Sendable (Bool) -> Void = { _ in }) {
        let content = UNMutableNotificationContent()
        content.body = String(localized: "\(count) messages haven't reached your host yet. They'll go once it's back online.")
        content.sound = .default
        content.threadIdentifier = reminderId
        let delay = max(1, Double(ms) / 1000 - Date().timeIntervalSince1970)
        center.add(UNNotificationRequest(identifier: reminderId, content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false))) { done($0 == nil) }
    }

    /// No message waits for the host any more (or reminders are off): nothing pending, and a shown one goes.
    static func cancelReminder(delivered: Bool) {
        center.removePendingNotificationRequests(withIdentifiers: [reminderId])
        if delivered { center.removeDeliveredNotifications(withIdentifiers: [reminderId]) }
    }

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

    /// At its 24-hour deadline (`at`, epoch ms, from Send), identified by the message id; canceled once the host has it.
    static func scheduleExpiry(_ id: String, at ms: Int) {
        let content = UNMutableNotificationContent()
        content.body = String(localized: "A message didn't reach your host within 24 hours, so it wasn't sent. Open Yorozu to resend it.")
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, Double(ms) / 1000 - Date().timeIntervalSince1970), repeats: false)
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
    #if os(iOS)
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
    #else
    // A Mac app is not suspended in the background: nothing to ask for.
    init(_ name: String, onExpiry: @escaping @MainActor () -> Void = {}) {}
    func end() {}
    #endif
}
