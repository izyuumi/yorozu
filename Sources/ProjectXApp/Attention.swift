import AppKit
import ProjectXCore
import UserNotifications

/// What needs the owner's eyes on the Mac (#311): the menu-bar dot and macOS notifications for results, failures and
/// questions on the main timeline (`Message.alert`, shared with phone pushes). Notification text is fixed and never carries message content (open question 3).
///
/// The popover drives what counts as seen: it calls `seen(upTo:)` for the newest message it has shown and keeps
/// `popoverAtBottom` true while it is open and scrolled to the newest message; nothing is posted then (open question 4).
/// The main read cursor counts too (#313): a message at or before it is seen, so reading on the phone clears the dot and
/// the delivered notifications for what it read.
/// A tapped notification calls `open(messageID:)`: the host shows the popover and `focusMessageID` names the message to scroll to.
@MainActor final class AttentionCenter: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = AttentionCenter()

    /// Unseen result, failure and question ids, oldest first; the dot shows while it is not empty.
    @Published private(set) var unseen: [String] = []
    /// The message the popover should scroll to; the popover sets it back to nil once it has.
    @Published var focusMessageID: String?
    /// Set by the popover while it is shown and scrolled to the newest message; the host clears it when the popover closes.
    var popoverAtBottom = false { didSet { if popoverAtBottom { seenThrough = max(seenThrough, newest); refresh() } } }
    /// `[notifications] enabled` and destination, read at each post; the host wires it to the config.
    var notificationsEnabled: () -> Bool = { true }
    /// The main thread's synced read cursor; the host sets it from each poll.
    var readCursor: String? { didSet { if readCursor != oldValue { applyCursor(); refresh() } } }
    /// Shows the popover; set by the host.
    var onOpen: (() -> Void)?

    private var messages: [Message] = []
    /// Everything created at or before this is seen. Starts at launch: older messages never raise the dot or a notification.
    private var seenThrough = Date().timeIntervalSince1970
    private var notifiedThrough = Date().timeIntervalSince1970
    private var newest: Double { messages.last?.created ?? 0 }
    private var authorization: Task<Bool,Never>?

    override private init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func ingest(_ snapshot: Snapshot) {
        messages = snapshot.messages
        applyCursor()
        if popoverAtBottom { seenThrough = max(seenThrough, newest) }
        for m in messages where m.created > notifiedThrough && m.created > seenThrough { if let r = m.alert { post(m.id, r) } }
        notifiedThrough = max(notifiedThrough, newest)
        refresh()
    }

    /// The popover has shown everything up to and including this message.
    func seen(upTo messageID: String) {
        guard let m = messages.first(where: { $0.id == messageID }), m.created > seenThrough else { return }
        seenThrough = m.created; refresh()
    }

    /// Opens the popover at a message (a tapped notification).
    func open(messageID: String) {
        onOpen?()
        focusMessageID = messageID
        seen(upTo: messageID)
    }

    /// Forward only, like the cursor; a cursor not in the snapshot yet applies on the ingest that brings it.
    private func applyCursor() {
        guard let readCursor, let m = messages.first(where: { $0.id == readCursor }) else { return }
        seenThrough = max(seenThrough, m.created)
    }

    private func refresh() {
        let next = messages.filter { $0.created > seenThrough && $0.alert != nil }.map(\.id)
        let cleared = Set(unseen).subtracting(next)
        if !cleared.isEmpty { UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: Array(cleared)) }
        if next != unseen { unseen = next }
    }

    /// Asks for permission the first time a notification would be posted.
    private func post(_ id: String, _ reason: Message.Alert) {
        guard notificationsEnabled() else { return }
        let content = UNMutableNotificationContent()
        switch reason {
        case .result: content.body = String(localized: "Yorozu replied", comment: "Mac notification for a new answer; never includes message content")
        case .failure: content.body = String(localized: "A task failed", comment: "Mac notification for a failure; never includes message content")
        case .question: content.body = String(localized: "Yorozu has a question", comment: "Mac notification for a question; never includes message content")
        }
        content.sound = .default
        content.userInfo = ["messageID": id]
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        let ask = authorization ?? Task { (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false }
        authorization = ask
        Task { if await ask.value { try? await UNUserNotificationCenter.current().add(request) } }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let id = response.notification.request.content.userInfo["messageID"] as? String else { return }
        await open(messageID: id)
    }

    /// The app is active while the popover is open; a notification posted then (popover scrolled up) still shows.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
